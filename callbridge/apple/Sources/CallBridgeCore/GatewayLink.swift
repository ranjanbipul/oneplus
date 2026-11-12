import Foundation

/// Settings a link needs to pair with the gateway.
public struct LinkConfig: Sendable {
    public var key: String
    /// Gateway host; empty means "the default-route gateway".
    public var host: String
    public var name: String
    /// Stable per-install id, so the gateway lets this client reclaim its call after a reconnect.
    public var clientId: String

    public init(key: String, host: String, name: String, clientId: String) {
        self.key = key
        self.host = host
        self.name = name
        self.clientId = clientId
    }
}

/// Control connection to the gateway, run on its own thread with automatic reconnect.
/// Callbacks are delivered on `callbackQueue`.
public final class GatewayLink: @unchecked Sendable {
    public var onStatus: ((String) -> Void)?
    public var onConnected: ((Bool) -> Void)?
    public var onMessage: (([String: Any]) -> Void)?
    /// Called on the link thread after the connection drops, before its UDP socket closes.
    /// Use it to stop anything that uses `udp` (call audio); it may block briefly.
    public var willDisconnect: (() -> Void)?

    private let config: () -> LinkConfig
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var wire: Wire?
    private let sender = DispatchQueue(label: "callbridge.link.send")
    private var thread: Thread?
    private var pingTimer: DispatchSourceTimer?
    private var running = false
    private var lastStatus = ""

    // Valid while connected; read by the audio engine.
    public private(set) var token: Int32 = 0
    public private(set) var gatewayIP: String?
    public private(set) var udp: UdpSocket?
    public private(set) var isConnected = false

    /// `config` is read before every connection attempt, so settings changes apply on reconnect.
    public init(callbackQueue: DispatchQueue = .main, config: @escaping () -> LinkConfig) {
        self.callbackQueue = callbackQueue
        self.config = config
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = true
        if thread == nil {
            let t = Thread { [weak self] in self?.run() }
            t.name = "callbridge.link"
            t.start()
            thread = t
        }
    }

    /// Disconnects and stops reconnecting until `start()` is called again.
    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
        reconnect()
    }

    public func send(_ m: [String: Any]) {
        sender.async { [weak self] in
            guard let self else { return }
            guard let w = self.currentWire() else {
                self.status("Not connected to the gateway", notice: true)
                return
            }
            do { try w.send(m) } catch { w.close() }
        }
    }

    /// Drops the connection so the loop reconnects with fresh settings.
    public func reconnect() {
        currentWire()?.close()
    }

    private func currentWire() -> Wire? {
        lock.lock()
        defer { lock.unlock() }
        return wire
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func status(_ s: String, notice: Bool = false) {
        if !notice { lastStatus = s }
        callbackQueue.async { self.onStatus?(s) }
    }

    private func run() {
        while true {
            if !isRunning() {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            do {
                try connectOnce()
            } catch {
                if !lastStatus.hasPrefix("Pairing") { status("Not connected (\(error))") }
            }
            onDisconnected()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    private func connectOnce() throws {
        let cfg = config()
        if cfg.key.isEmpty {
            status("Pairing key not set (see Settings)")
            Thread.sleep(forTimeInterval: 2)
            return
        }
        let ip: String
        if cfg.host.isEmpty {
            guard let gw = defaultGatewayIPv4() else { throw SocketError("no network gateway found", errno: 0) }
            ip = gw
        } else {
            ip = try resolveIPv4(cfg.host)
        }
        status("Connecting to \(ip)…")

        let u = try UdpSocket()
        let w: Wire
        do {
            w = try Wire(connectTo: ip, port: Proto.controlPort, timeout: 4)
        } catch {
            u.close()
            throw error
        }
        lock.lock(); udp = u; lock.unlock()
        defer {
            pingTimer?.cancel()
            pingTimer = nil
            lock.lock(); wire = nil; lock.unlock()
            w.close()
        }

        w.setReadTimeout(10)
        guard let challenge = try w.read(), let nonce = challenge["nonce"] as? String else {
            throw SocketError("gateway closed the connection", errno: 0)
        }
        let cnonce = Auth.nonce()
        try w.send(Proto.msg("auth", [
            "cnonce": cnonce,
            "mac": Auth.hmac(cfg.key, "c", nonce, cnonce),
            "name": cfg.name,
            "id": cfg.clientId,
            "uport": Int(u.localPort),
        ]))
        guard let ok = try w.read() else { throw SocketError("gateway closed the connection", errno: 0) }
        guard ok["t"] as? String == "ok",
              Auth.same(ok["mac"] as? String ?? "", Auth.hmac(cfg.key, "s", nonce, cnonce)),
              let tok = (ok["token"] as? NSNumber)?.int32Value
        else {
            status("Pairing key rejected by gateway")
            Thread.sleep(forTimeInterval: 5)
            return
        }
        token = tok
        gatewayIP = ip
        lock.lock(); wire = w; isConnected = true; lock.unlock()
        w.setReadTimeout(20)
        status("Connected to \(ip)")
        callbackQueue.async { self.onConnected?(true) }

        let timer = DispatchSource.makeTimerSource(queue: sender)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { try? w.send(Proto.msg("ping")) }
        timer.resume()
        pingTimer = timer

        while let m = try w.read() {
            if m["t"] as? String == "pong" { continue }
            callbackQueue.async { self.onMessage?(m) }
        }
    }

    private func onDisconnected() {
        let was = isConnected
        lock.lock(); isConnected = false; lock.unlock()
        willDisconnect?()
        lock.lock()
        let u = udp
        udp = nil
        lock.unlock()
        u?.close()
        if was {
            if isRunning() { status("Disconnected, retrying…") } else { status("Disconnected") }
            callbackQueue.async { self.onConnected?(false) }
        }
    }
}
