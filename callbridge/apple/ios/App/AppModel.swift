import AVFoundation
import CallBridgeCore
import Foundation
import Observation
import UIKit

/// App state and the gateway connection. Main thread only.
@Observable
final class AppModel {
    static let shared = AppModel()

    var connected = false
    var status = "Starting…"
    var notice: String?
    var call = CallInfo()
    /// This iPhone placed or answered the current call.
    var mine = false
    var muted = false
    var callStarted: Date?
    var callLog: [LogItem] = []
    var sms: [SmsItem] = []
    var dialText = ""
    var tab = Tab.dial
    var pushStatus = "Waiting for Apple push registration"

    enum Tab: Hashable { case dial, recents, messages, settings }

    var inCall: Bool { call.state != Proto.idle }

    @ObservationIgnored let link: GatewayLink
    @ObservationIgnored let audio = CallAudio()
    /// An answer requested (from CallKit) before the link was up.
    @ObservationIgnored private var pendingAnswer = false
    @ObservationIgnored private var pendingDial: DispatchWorkItem?

    private init() {
        link = GatewayLink {
            LinkConfig(key: Settings.key, host: Settings.host, name: Settings.deviceName, clientId: Settings.clientId)
        }
        link.onStatus = { [unowned self] s in
            if s == "Not connected to the gateway" { notice = s } else { status = s }
        }
        link.onConnected = { [unowned self] up in
            connected = up
            if up {
                refresh()
                registerPush()
                if pendingAnswer {
                    pendingAnswer = false
                    link.send(Proto.msg("answer"))
                }
            } else if inCall {
                onCall(CallInfo())
            }
        }
        link.onMessage = { [unowned self] in onMessage($0) }
        link.willDisconnect = { [unowned self] in audio.stopAndWait() }
        audio.onError = { [unowned self] in notice = $0 }
    }

    func start() { link.start() }

    /// While the app is in the background the gateway reaches it by push, so the link is
    /// closed then (unless a call needs it): a suspended app cannot keep a socket alive, and
    /// the gateway only pushes to devices that are not connected.
    func enterBackground() {
        if !inCall && !CallManager.shared.hasCall { link.stop() }
    }

    /// Sends this iPhone's push tokens to the gateway.
    func registerPush() {
        guard connected else { return }
        let p = PushRegistry.shared
        guard p.voipToken != nil || p.alertToken != nil else { return }
        link.send(Proto.msg("push_register", [
            "voip": p.voipToken ?? "",
            "alert": p.alertToken ?? "",
            "topic": Bundle.main.bundleIdentifier ?? "",
            "sandbox": PushRegistry.sandbox,
        ]))
    }

    // MARK: commands (from the UI or CallKit)

    func dialFromUI(_ raw: String) {
        let number = dialable(raw)
        guard !number.isEmpty else { return }
        guard connected else { notice = "Not connected to the gateway"; return }
        guard !inCall else { notice = "Line busy"; return }
        CallManager.shared.startOutgoing(number)
    }

    /// CallKit started an outgoing call.
    func sendDial(_ number: String) {
        mine = true
        muted = false
        audio.muted = false
        link.send(Proto.msg("dial", ["number": number]))
        let w = DispatchWorkItem { [unowned self] in
            if call.state == Proto.idle {
                notice = "The gateway did not start the call"
                mine = false
                CallManager.shared.endFailed()
            }
        }
        pendingDial = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }

    /// CallKit answered the ringing call. The app may have just been launched for it, so the
    /// link may still be connecting.
    func sendAnswer() {
        mine = true
        muted = false
        audio.muted = false
        if connected { link.send(Proto.msg("answer")) } else { pendingAnswer = true; link.start() }
    }

    func sendHangup() {
        pendingAnswer = false
        link.send(Proto.msg("hangup"))
    }

    func sendDtmf(_ digits: String) {
        for d in digits { link.send(Proto.msg("dtmf", ["digit": String(d)])) }
    }

    func setMuted(_ on: Bool) {
        muted = on
        audio.muted = on
    }

    func sendSms(to: String, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, !text.isEmpty else { return }
        link.send(Proto.msg("sms_send", ["id": UUID().uuidString, "to": to, "body": text]))
    }

    func refresh() {
        link.send(Proto.msg("calllog_get", ["limit": 100]))
        link.send(Proto.msg("sms_get", ["limit": 100]))
    }

    // MARK: audio

    /// Starts call audio when CallKit has activated the audio session and the gateway is
    /// bridging this iPhone.
    func updateAudio() {
        let want = CallManager.shared.audioSessionActive && call.state == Proto.active && call.bridged
        if want, !audio.running, let udp = link.udp, let ip = link.gatewayIP {
            audio.muted = muted
            audio.start(udp: udp, ip: ip, token: link.token)
        } else if !want, audio.running {
            audio.stop()
        }
    }

    // MARK: gateway messages

    private func onMessage(_ m: [String: Any]) {
        switch m["t"] as? String {
        case "call":
            onCall(CallInfo(message: m))
        case "calllog":
            callLog = items(m).map { LogItem($0) }
        case "sms":
            sms = items(m).map { SmsItem($0) }
        case "sms_in":
            // The gateway pushes a notification only to devices that are not connected.
            sms.insert(SmsItem(incoming: m), at: 0)
        case "sms_sent":
            if m["ok"] as? Bool == true {
                notice = "SMS sent"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.link.send(Proto.msg("sms_get", ["limit": 100]))
                }
            } else {
                notice = "SMS failed: \(m["error"] as? String ?? "unknown error")"
            }
        case "push_status":
            let ok = m["ok"] as? Bool ?? false
            pushStatus = ok ? "On" : "Off: \(m["msg"] as? String ?? "gateway cannot send pushes")"
        case "error":
            notice = m["msg"] as? String
            if pendingDial != nil && call.state == Proto.idle {
                pendingDial?.cancel()
                pendingDial = nil
                mine = false
                CallManager.shared.endFailed()
            }
        default:
            break
        }
    }

    private func onCall(_ new: CallInfo) {
        let old = call
        call = new
        if new.state != Proto.idle {
            pendingDial?.cancel()
            pendingDial = nil
        }
        switch new.state {
        case Proto.ringing:
            if new.incoming && old.state != Proto.ringing { CallManager.shared.reportIncoming(new.number) }
        case Proto.active:
            if new.bridged {
                if old.state != Proto.active || callStarted == nil { callStarted = Date() }
                CallManager.shared.gatewayConnected()
            } else {
                // Answered on the OnePlus 8 itself or on another companion device.
                mine = false
                CallManager.shared.gatewayAnsweredElsewhere()
            }
        case Proto.idle:
            CallManager.shared.gatewayEnded(wasRinging: old.state == Proto.ringing)
            mine = false
            muted = false
            callStarted = nil
            pendingAnswer = false
            if UIApplication.shared.applicationState == .background { enterBackground() }
        default:
            break
        }
        updateAudio()
    }
}

/// Persistent settings.
enum Settings {
    private static let d = UserDefaults.standard

    static var key: String {
        get { d.string(forKey: "key") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), forKey: "key") }
    }

    /// Gateway host; empty means "the default-route gateway".
    static var host: String {
        get { d.string(forKey: "host") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "host") }
    }

    static var clientId: String {
        if let id = d.string(forKey: "clientId") { return id }
        let id = UUID().uuidString.lowercased()
        d.set(id, forKey: "clientId")
        return id
    }

    static var deviceName: String { UIDevice.current.name }
}
