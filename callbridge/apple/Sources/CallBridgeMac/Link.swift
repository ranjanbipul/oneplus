import Foundation

/// Control connection to the gateway, run on its own thread with automatic reconnect.
final class Link {
    static let shared = Link()

    private let lock = NSLock()
    private var wire: Wire?
    private let sender = DispatchQueue(label: "callbridge.link.send")
    private var thread: Thread?
    private var pingTimer: DispatchSourceTimer?

    // Valid while connected; read by the audio engine.
    private(set) var token: Int32 = 0
    private(set) var gatewayIP: String?
    private(set) var udp: UdpSocket?

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "callbridge.link"
        t.start()
        thread = t
    }

    func send(_ m: [String: Any]) {
        sender.async { [weak self] in
            guard let self else { return }
            guard let w = self.currentWire() else {
                ui { $0.notice = "Not connected to the gateway" }
                return
            }
            do { try w.send(m) } catch { w.close() }
        }
    }

    /// Drops the connection so the loop reconnects with fresh settings.
    func reconnect() {
        currentWire()?.close()
    }

    private func currentWire() -> Wire? {
        lock.lock()
        defer { lock.unlock() }
        return wire
    }

    private func run() {
        while true {
            do {
                try connectOnce()
            } catch {
                let msg = "\(error)"
                ui { s in
                    if !s.status.hasPrefix("Pairing") { s.status = "Not connected (\(msg))" }
                }
            }
            onDisconnected()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    private func connectOnce() throws {
        let key = Config.key
        if key.isEmpty {
            ui { $0.status = "Pairing key not set (see Settings)" }
            Thread.sleep(forTimeInterval: 2)
            return
        }
        let host = Config.host
        let ip: String
        if host.isEmpty {
            guard let gw = defaultGatewayIPv4() else { throw SocketError("no network gateway found", errno: 0) }
            ip = gw
        } else {
            ip = try resolveIPv4(host)
        }
        ui { $0.status = "Connecting to \(ip)…" }

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
            "mac": Auth.hmac(key, "c", nonce, cnonce),
            "name": Config.deviceName,
            "id": Config.clientId,
            "uport": Int(u.localPort),
        ]))
        guard let ok = try w.read() else { throw SocketError("gateway closed the connection", errno: 0) }
        guard ok["t"] as? String == "ok",
              Auth.same(ok["mac"] as? String ?? "", Auth.hmac(key, "s", nonce, cnonce)),
              let tok = (ok["token"] as? NSNumber)?.int32Value
        else {
            ui { $0.status = "Pairing key rejected by gateway" }
            Thread.sleep(forTimeInterval: 5)
            return
        }
        token = tok
        gatewayIP = ip
        lock.lock(); wire = w; lock.unlock()
        w.setReadTimeout(20)
        ui {
            $0.connected = true
            $0.status = "Connected to \(ip)"
        }
        Power.connected(true)
        send(Proto.msg("calllog_get", ["limit": 100]))
        send(Proto.msg("sms_get", ["limit": 100]))

        let timer = DispatchSource.makeTimerSource(queue: sender)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { try? w.send(Proto.msg("ping")) }
        timer.resume()
        pingTimer = timer

        while let m = try w.read() {
            DispatchQueue.main.async { Calls.onMessage(m) }
        }
    }

    private func onDisconnected() {
        Power.connected(false)
        // Stop audio before the UDP socket goes away.
        DispatchQueue.main.sync { Calls.onLinkDown() }
        lock.lock()
        let u = udp
        udp = nil
        lock.unlock()
        u?.close()
    }
}

/// Runs a UI-state mutation on the main thread.
func ui(_ f: @escaping (AppState) -> Void) {
    DispatchQueue.main.async { f(AppState.shared) }
}
