import AVFoundation
import CallKit
import Foundation

/// Mirrors the gateway's single call into CallKit, so calls ring on the lock screen, work
/// with headsets and CarPlay, and show in the Phone app's Recents. Main thread only.
final class CallManager: NSObject, CXProviderDelegate {
    static let shared = CallManager()

    private let provider: CXProvider
    private let controller = CXCallController()

    /// The CallKit call that stands for the gateway's current call.
    private struct Current {
        let uuid: UUID
        let incoming: Bool
        var answered = false
        var connected = false
    }

    private var current: Current?
    private(set) var audioSessionActive = false
    private var model: AppModel { AppModel.shared }

    override private init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.phoneNumber]
        config.includesCallsInRecents = true
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    // MARK: from the app / push

    /// Reports a ringing gateway call. It can arrive twice (VoIP push and the app's own link).
    /// A duplicate from the app's link is ignored; a duplicate VoIP push must still be
    /// reported to CallKit (iOS requires it), so it is reported and ended at once.
    func reportIncoming(_ number: String, fromPush: Bool = false, completion: (() -> Void)? = nil) {
        model.start()
        if current != nil {
            guard fromPush else { completion?(); return }
            let extra = UUID()
            provider.reportNewIncomingCall(with: extra, update: callUpdate(number)) { [weak self] _ in
                self?.provider.reportCall(with: extra, endedAt: nil, reason: .answeredElsewhere)
                completion?()
            }
            return
        }
        let uuid = UUID()
        current = Current(uuid: uuid, incoming: true)
        configureAudioSession()
        provider.reportNewIncomingCall(with: uuid, update: callUpdate(number)) { [weak self] error in
            if let error {
                NSLog("CallBridge: incoming call report failed: \(error)")
                if self?.current?.uuid == uuid { self?.current = nil }
            }
            completion?()
        }
    }

    private func callUpdate(_ number: String) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number.isEmpty ? "Unknown" : number)
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = true
        return update
    }

    var hasCall: Bool { current != nil }

    func startOutgoing(_ number: String) {
        guard current == nil else { return }
        let uuid = UUID()
        current = Current(uuid: uuid, incoming: false)
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .phoneNumber, value: number))
        controller.request(CXTransaction(action: action)) { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.model.notice = "Could not start the call: \(error.localizedDescription)"
                    if self?.current?.uuid == uuid { self?.current = nil }
                }
            }
        }
    }

    /// In-app answer and hang-up buttons go through CallKit so both stay in step.
    func answerFromUI() {
        guard let c = current, c.incoming else { model.sendAnswer(); return }
        controller.request(CXTransaction(action: CXAnswerCallAction(call: c.uuid))) { _ in }
    }

    func hangupFromUI() {
        guard let c = current else { model.sendHangup(); return }
        controller.request(CXTransaction(action: CXEndCallAction(call: c.uuid))) { _ in }
    }

    func setMutedFromUI(_ on: Bool) {
        guard let c = current else { model.setMuted(on); return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: c.uuid, muted: on))) { _ in }
    }

    func dtmfFromUI(_ digit: Character) {
        guard let c = current else { model.sendDtmf(String(digit)); return }
        controller.request(CXTransaction(action: CXPlayDTMFCallAction(call: c.uuid, digits: String(digit), type: .singleTone))) { _ in }
    }

    // MARK: from gateway call state

    func gatewayConnected() {
        guard var c = current else { return }
        if !c.incoming && !c.connected { provider.reportOutgoingCall(with: c.uuid, connectedAt: nil) }
        c.connected = true
        current = c
    }

    func gatewayAnsweredElsewhere() {
        guard let c = current, !c.answered, c.incoming else { return }
        provider.reportCall(with: c.uuid, endedAt: nil, reason: .answeredElsewhere)
        current = nil
    }

    func gatewayEnded(wasRinging: Bool) {
        guard let c = current else { return }
        let reason: CXCallEndedReason = (c.incoming && !c.answered && wasRinging) ? .unanswered : .remoteEnded
        provider.reportCall(with: c.uuid, endedAt: nil, reason: reason)
        current = nil
    }

    func endFailed() {
        guard let c = current else { return }
        provider.reportCall(with: c.uuid, endedAt: nil, reason: .failed)
        current = nil
    }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        current = nil
        audioSessionActive = false
        model.updateAudio()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureAudioSession()
        model.sendDial(action.handle.value)
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if current?.uuid == action.callUUID { current?.answered = true }
        configureAudioSession()
        model.sendAnswer()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if current?.uuid == action.callUUID { current = nil }
        model.sendHangup()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        model.setMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        model.sendDtmf(action.digits)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fail() // the gateway has no hold
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioSessionActive = true
        model.updateAudio()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audioSessionActive = false
        model.updateAudio()
    }

    /// CallKit activates the session; it must already have the call category.
    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
        } catch {
            NSLog("CallBridge: audio session setup failed: \(error)")
        }
    }
}
