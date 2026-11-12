import Foundation
import PushKit
import UIKit

/// Apple push for when the app is not running: the gateway sends a VoIP push when a call
/// starts ringing (which wakes the app into CallKit) and an alert push for each new SMS.
/// The tokens are registered with the gateway over the control link.
final class PushRegistry: NSObject, PKPushRegistryDelegate {
    static let shared = PushRegistry()

    private let voip = PKPushRegistry(queue: .main)
    private(set) var voipToken: String?
    private(set) var alertToken: String?

    func start() {
        voip.delegate = self
        voip.desiredPushTypes = [.voIP]
        UIApplication.shared.registerForRemoteNotifications()
    }

    func setAlertToken(_ data: Data) {
        alertToken = data.map { String(format: "%02x", $0) }.joined()
        AppModel.shared.registerPush()
    }

    /// Development-signed builds get their pushes from Apple's sandbox servers.
    static let sandbox: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "<key>aps-environment</key>") else { return true }
        return text[r.upperBound...].prefix(80).contains("development")
    }()

    // MARK: PKPushRegistryDelegate

    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        voipToken = credentials.token.map { String(format: "%02x", $0) }.joined()
        AppModel.shared.registerPush()
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        voipToken = nil
    }

    /// iOS requires every VoIP push to be reported to CallKit before this returns, or it stops
    /// delivering them; CallManager does that even for a call it already knows about.
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        let number = payload.dictionaryPayload["number"] as? String ?? ""
        CallManager.shared.reportIncoming(number, fromPush: true, completion: completion)
    }
}
