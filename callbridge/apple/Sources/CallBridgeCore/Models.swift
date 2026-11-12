import Foundation

public struct CallInfo: Equatable, Sendable {
    public var state = Proto.idle
    public var number = ""
    public var incoming = false
    /// True when this client is the device carrying the call's audio.
    public var bridged = false

    public init(state: String = Proto.idle, number: String = "", incoming: Bool = false, bridged: Bool = false) {
        self.state = state
        self.number = number
        self.incoming = incoming
        self.bridged = bridged
    }

    public init(message m: [String: Any]) {
        self.init(
            state: m["state"] as? String ?? Proto.idle,
            number: m["number"] as? String ?? "",
            incoming: m["incoming"] as? Bool ?? false,
            bridged: m["bridged"] as? Bool ?? false
        )
    }
}

public struct LogItem: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let number: String
    public let name: String
    public let type: String // in, out, missed, rejected, other
    public let ts: Int64
    public let dur: Int64

    public init(_ o: [String: Any]) {
        number = o["number"] as? String ?? ""
        name = o["name"] as? String ?? ""
        type = o["type"] as? String ?? "other"
        ts = int64(o["ts"])
        dur = int64(o["dur"])
    }
}

public struct SmsItem: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let addr: String
    public let body: String
    public let ts: Int64
    public let out: Bool

    public init(addr: String, body: String, ts: Int64, out: Bool) {
        self.addr = addr
        self.body = body
        self.ts = ts
        self.out = out
    }

    /// From an `sms` list item.
    public init(_ o: [String: Any]) {
        self.init(addr: o["addr"] as? String ?? "", body: o["body"] as? String ?? "", ts: int64(o["ts"]), out: o["out"] as? Bool ?? false)
    }

    /// From an `sms_in` message.
    public init(incoming m: [String: Any]) {
        self.init(addr: m["from"] as? String ?? "", body: m["body"] as? String ?? "", ts: int64(m["ts"]), out: false)
    }
}

public func items(_ m: [String: Any]) -> [[String: Any]] {
    m["items"] as? [[String: Any]] ?? []
}

func int64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }

public struct SmsThread: Identifiable, Hashable, Sendable {
    public let key: String
    public let addr: String
    public let items: [SmsItem] // newest first
    public var id: String { key }

    public init(key: String, addr: String, items: [SmsItem]) {
        self.key = key
        self.addr = addr
        self.items = items
    }

    /// Groups numbers that differ only in country prefix or formatting.
    public static func key(_ addr: String) -> String {
        let digits = addr.filter(\.isNumber)
        return digits.count >= 10 ? String(digits.suffix(10)) : (digits.isEmpty ? addr : digits)
    }

    /// Conversations, most recent first.
    public static func group(_ sms: [SmsItem]) -> [SmsThread] {
        var order = [String]()
        var groups = [String: [SmsItem]]()
        for m in sms.sorted(by: { $0.ts > $1.ts }) {
            let k = key(m.addr)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(m)
        }
        return order.map { SmsThread(key: $0, addr: groups[$0]!.first!.addr, items: groups[$0]!) }
    }
}

/// Keeps only the characters the gateway accepts in a dial string.
public func dialable(_ raw: String) -> String {
    raw.filter { $0.isNumber || "+*#".contains($0) }
}

public func shortDate(_ ms: Int64) -> String {
    let d = Date(timeIntervalSince1970: Double(ms) / 1000)
    let cal = Calendar.current
    if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    if let days = cal.dateComponents([.day], from: d, to: .now).day, days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
    return d.formatted(date: .numeric, time: .omitted)
}
