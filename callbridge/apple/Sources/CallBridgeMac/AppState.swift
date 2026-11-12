import CallBridgeCore
import Foundation
import Observation

/// UI state. Only touched on the main thread.
@Observable
final class AppState {
    static let shared = AppState()

    var connected = false
    var status = "Starting…"
    var notice: String?
    var call = CallInfo()
    /// This Mac placed or answered the current call.
    var mine = false
    var muted = false
    var callStarted: Date?
    var callLog: [LogItem] = []
    var sms: [SmsItem] = []
    var dialText = ""
    var selectedTab = Tab.dial

    enum Tab: Hashable { case dial, recents, messages, settings }

    var inCall: Bool { call.state != Proto.idle }
}

/// Persistent settings.
enum Config {
    private static let d = UserDefaults.standard

    /// The app's bundle id changed from com.antigravity.callbridge.mac to
    /// com.imbine.callbridge.mac; carry the old settings over once.
    static func migrate() {
        guard d.string(forKey: "clientId") == nil,
              let old = UserDefaults(suiteName: "com.antigravity.callbridge.mac") else { return }
        for k in ["key", "host", "keepAwake", "clientId"] {
            if let v = old.object(forKey: k) { d.set(v, forKey: k) }
        }
    }

    static var key: String {
        get { d.string(forKey: "key") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), forKey: "key") }
    }

    /// Gateway host; empty means "the default-route gateway".
    static var host: String {
        get { d.string(forKey: "host") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "host") }
    }

    /// Keeps the Mac from idle-sleeping while connected, so calls can still ring.
    static var keepAwake: Bool {
        get { d.object(forKey: "keepAwake") as? Bool ?? true }
        set { d.set(newValue, forKey: "keepAwake") }
    }

    /// Stable per-install id, so the gateway lets this Mac reclaim its call after a reconnect.
    static var clientId: String {
        if let id = d.string(forKey: "clientId") { return id }
        let id = UUID().uuidString.lowercased()
        d.set(id, forKey: "clientId")
        return id
    }

    static var deviceName: String { Host.current().localizedName ?? "Mac" }
}
