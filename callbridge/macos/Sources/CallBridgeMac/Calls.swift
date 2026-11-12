import AppKit
import Foundation
import IOKit.pwr_mgt
import UserNotifications

/// Drives the call experience from gateway messages. Main thread only.
enum Calls {
    private static var pendingDial: DispatchWorkItem?
    private static var s: AppState { AppState.shared }

    static func dial(_ raw: String) {
        let number = raw.filter { $0.isNumber || "+*#".contains($0) }
        guard !number.isEmpty else { return }
        guard s.connected else { s.notice = "Not connected to the gateway"; return }
        guard !s.inCall else { s.notice = "Line busy"; return }
        s.mine = true
        s.muted = false
        Link.shared.send(Proto.msg("dial", ["number": number]))
        let w = DispatchWorkItem {
            if s.call.state == Proto.idle {
                s.notice = "The gateway did not start the call"
                s.mine = false
            }
        }
        pendingDial = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }

    static func answer() {
        guard s.call.state == Proto.ringing else { return }
        s.mine = true
        s.muted = false
        Ringer.stop()
        Notify.clearIncoming()
        Link.shared.send(Proto.msg("answer"))
    }

    static func hangup() {
        Ringer.stop()
        Notify.clearIncoming()
        Link.shared.send(Proto.msg("hangup"))
    }

    static func dtmf(_ digit: Character) {
        Link.shared.send(Proto.msg("dtmf", ["digit": String(digit)]))
    }

    static func toggleMute() {
        s.muted.toggle()
        AudioEngine.shared.muted = s.muted
    }

    static func sendSms(to: String, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, !text.isEmpty else { return }
        Link.shared.send(Proto.msg("sms_send", ["id": UUID().uuidString, "to": to, "body": text]))
    }

    static func refresh() {
        Link.shared.send(Proto.msg("calllog_get", ["limit": 100]))
        Link.shared.send(Proto.msg("sms_get", ["limit": 100]))
    }

    // MARK: gateway messages

    static func onMessage(_ m: [String: Any]) {
        switch m["t"] as? String {
        case "call":
            let new = CallInfo(
                state: m["state"] as? String ?? Proto.idle,
                number: m["number"] as? String ?? "",
                incoming: m["incoming"] as? Bool ?? false,
                bridged: m["bridged"] as? Bool ?? false
            )
            onCall(new)
        case "calllog":
            s.callLog = items(m).map {
                LogItem(number: $0["number"] as? String ?? "", name: $0["name"] as? String ?? "",
                        type: $0["type"] as? String ?? "other", ts: int64($0["ts"]), dur: int64($0["dur"]))
            }
        case "sms":
            s.sms = items(m).map(smsItem)
        case "sms_in":
            let item = SmsItem(addr: m["from"] as? String ?? "", body: m["body"] as? String ?? "",
                               ts: int64(m["ts"]), out: false)
            s.sms.insert(item, at: 0)
            Notify.sms(item)
        case "sms_sent":
            if m["ok"] as? Bool == true {
                s.notice = "SMS sent"
                // The phone stores the sent message a moment after accepting it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    Link.shared.send(Proto.msg("sms_get", ["limit": 100]))
                }
            } else {
                s.notice = "SMS failed: \(m["error"] as? String ?? "unknown error")"
            }
        case "error":
            s.notice = m["msg"] as? String
            if pendingDial != nil && s.call.state == Proto.idle {
                pendingDial?.cancel()
                pendingDial = nil
                s.mine = false
            }
        default:
            break
        }
    }

    /// The control link dropped: whatever call we knew about is gone from our point of view.
    static func onLinkDown() {
        s.connected = false
        if s.status.hasPrefix("Connected") { s.status = "Disconnected, retrying…" }
        if s.inCall { onCall(CallInfo()) }
    }

    private static func onCall(_ new: CallInfo) {
        let old = s.call
        s.call = new
        if new.state != Proto.idle {
            pendingDial?.cancel()
            pendingDial = nil
        }
        switch new.state {
        case Proto.ringing:
            if old.state != Proto.ringing && new.incoming {
                Ringer.start()
                Notify.incoming(new.number)
                AppWindow.bringToFront()
            }
        case Proto.dialing:
            break
        case Proto.active:
            Ringer.stop()
            Notify.clearIncoming()
            if new.bridged {
                if old.state != Proto.active || s.callStarted == nil { s.callStarted = Date() }
                AudioEngine.shared.muted = s.muted
                AudioEngine.shared.start()
            } else {
                // Answered on the phone itself or on another companion device.
                AudioEngine.shared.stop()
                s.mine = false
            }
        default: // idle
            Ringer.stop()
            Notify.clearIncoming()
            AudioEngine.shared.stop()
            if old.state == Proto.ringing && old.incoming && !s.mine { Notify.missed(old.number) }
            s.mine = false
            s.muted = false
            s.callStarted = nil
            // The call log row is written shortly after the call ends; the gateway pushes it.
        }
    }

    private static func items(_ m: [String: Any]) -> [[String: Any]] {
        m["items"] as? [[String: Any]] ?? []
    }

    private static func smsItem(_ o: [String: Any]) -> SmsItem {
        SmsItem(addr: o["addr"] as? String ?? "", body: o["body"] as? String ?? "",
                ts: int64(o["ts"]), out: o["out"] as? Bool ?? false)
    }

    private static func int64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }
}

/// Plays the system ringtone in a loop while an incoming call rings.
enum Ringer {
    private static var timer: Timer?
    private static let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true)

    static func start() {
        guard timer == nil else { return }
        sound?.play()
        timer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in
            sound?.stop()
            sound?.play()
        }
    }

    static func stop() {
        timer?.invalidate()
        timer = nil
        sound?.stop()
    }
}

/// Keeps the Mac awake: always during a call, and while connected if the user wants calls to ring.
enum Power {
    private static let lock = NSLock()
    private static var connectedAssertion: IOPMAssertionID = 0
    private static var callAssertion: IOPMAssertionID = 0

    static func connected(_ on: Bool) {
        set(&connectedAssertion, on && Config.keepAwake, "CallBridge connected: keep receiving calls")
    }

    static func inCall(_ on: Bool) {
        set(&callAssertion, on, "CallBridge call in progress")
    }

    private static func set(_ id: inout IOPMAssertionID, _ on: Bool, _ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        if on && id == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        } else if !on && id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}

/// User notifications for incoming calls, missed calls and SMS.
final class Notify: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notify()
    private static let incomingId = "incoming-call"

    static func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = shared
        let answer = UNNotificationAction(identifier: "answer", title: "Answer", options: [.foreground])
        let decline = UNNotificationAction(identifier: "decline", title: "Decline", options: [.destructive])
        let call = UNNotificationCategory(identifier: "call", actions: [answer, decline], intentIdentifiers: [])
        let callBack = UNNotificationAction(identifier: "callback", title: "Call Back", options: [.foreground])
        let missed = UNNotificationCategory(identifier: "missed", actions: [callBack], intentIdentifiers: [])
        c.setNotificationCategories([call, missed])
        c.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func incoming(_ number: String) {
        post(id: incomingId, title: "Incoming call", body: number.isEmpty ? "Unknown number" : number,
             category: "call", info: ["number": number])
    }

    static func clearIncoming() {
        let c = UNUserNotificationCenter.current()
        c.removeDeliveredNotifications(withIdentifiers: [incomingId])
        c.removePendingNotificationRequests(withIdentifiers: [incomingId])
    }

    static func missed(_ number: String) {
        post(id: UUID().uuidString, title: "Missed call", body: number.isEmpty ? "Unknown number" : number,
             category: "missed", info: ["number": number])
    }

    static func sms(_ item: SmsItem) {
        post(id: UUID().uuidString, title: item.addr, body: item.body, category: "", info: ["sms": item.addr])
    }

    private static func post(id: String, title: String, body: String, category: String, info: [String: String]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = info
        if category != "call" { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            switch action {
            case "answer": Calls.answer()
            case "decline": Calls.hangup()
            case "callback": if let n = info["number"] as? String { Calls.dial(n) }
            default:
                if info["sms"] != nil { AppState.shared.selectedTab = .messages }
                AppWindow.bringToFront()
            }
        }
        completionHandler()
    }
}
