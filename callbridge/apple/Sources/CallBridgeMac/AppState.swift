import Foundation
import Observation

struct CallInfo: Equatable {
    var state = Proto.idle
    var number = ""
    var incoming = false
    /// True when this Mac is the device carrying the call's audio.
    var bridged = false
}

struct LogItem: Identifiable, Hashable {
    let id = UUID()
    let number: String
    let name: String
    let type: String // in, out, missed, rejected, other
    let ts: Int64
    let dur: Int64
}

struct SmsItem: Identifiable, Hashable {
    let id = UUID()
    let addr: String
    let body: String
    let ts: Int64
    let out: Bool
}

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
