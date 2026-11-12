import Darwin
import Foundation

struct SocketError: Error, CustomStringConvertible {
    let description: String
    init(_ what: String, errno code: Int32 = errno) {
        description = code == 0 ? what : "\(what): \(String(cString: strerror(code)))"
    }
}

private func makeAddr(_ ip: String, _ port: UInt16) throws -> sockaddr_in {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    guard inet_pton(AF_INET, ip, &a.sin_addr) == 1 else { throw SocketError("bad IPv4 address \(ip)", errno: 0) }
    return a
}

private func setTimeout(_ fd: Int32, _ option: Int32, seconds: Double) {
    var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
}

/// Resolves a host name or literal to an IPv4 address string.
func resolveIPv4(_ host: String) throws -> String {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, nil, &hints, &res)
    guard rc == 0, let first = res else { throw SocketError("cannot resolve \(host): \(String(cString: gai_strerror(rc)))", errno: 0) }
    defer { freeaddrinfo(res) }
    var sin = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count))
    return String(cString: buf)
}

/// The IPv4 default-route gateway. When the Mac uses the OnePlus 8 as its hotspot or USB
/// tether, this is the phone, which is where the gateway app listens.
func defaultGatewayIPv4() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/sbin/route")
    p.arguments = ["-n", "get", "default"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, parts[0] == "gateway", (try? makeAddr(parts[1], 0)) != nil { return parts[1] }
    }
    return nil
}

/// Line-delimited JSON over a blocking TCP socket. Reads happen on one thread; sends are locked.
final class Wire {
    private let fd: Int32
    private var buf = [UInt8]()
    private var pos = 0
    private let sendLock = NSLock()
    private var closed = false

    init(connectTo ip: String, port: UInt16, timeout: Double) throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw SocketError("socket") }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = try makeAddr(ip, port)
        // Non-blocking connect so it can time out.
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { let e = errno; Darwin.close(s); throw SocketError("connect", errno: e) }
            var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let n = poll(&p, 1, Int32(timeout * 1000))
            if n <= 0 { Darwin.close(s); throw SocketError("connect timed out", errno: 0) }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { Darwin.close(s); throw SocketError("connect", errno: err) }
        }
        _ = fcntl(s, F_SETFL, flags)
        fd = s
    }

    func setReadTimeout(_ seconds: Double) { setTimeout(fd, SO_RCVTIMEO, seconds: seconds) }

    /// Returns nil on end of stream; throws on error, timeout or oversized input.
    func read() throws -> [String: Any]? {
        var line = [UInt8]()
        while true {
            if pos == buf.count {
                var chunk = [UInt8](repeating: 0, count: 8192)
                let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if n == 0 { return nil }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError(errno == EAGAIN ? "gateway stopped responding" : "read", errno: errno == EAGAIN ? 0 : errno)
                }
                buf = Array(chunk[0..<n])
                pos = 0
            }
            if let nl = buf[pos...].firstIndex(of: 0x0A) {
                line.append(contentsOf: buf[pos..<nl])
                pos = nl + 1
                break
            }
            line.append(contentsOf: buf[pos...])
            pos = buf.count
            if line.count > Proto.maxLine { throw SocketError("line too long", errno: 0) }
        }
        let obj = try JSONSerialization.jsonObject(with: Data(line))
        guard let dict = obj as? [String: Any] else { throw SocketError("not a JSON object", errno: 0) }
        return dict
    }

    func send(_ m: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: m)
        data.append(0x0A)
        sendLock.lock()
        defer { sendLock.unlock() }
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError("send")
                }
                off += n
            }
        }
    }

    /// Unblocks a pending read; safe to call from any thread.
    func close() {
        sendLock.lock()
        defer { sendLock.unlock() }
        if closed { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

/// A UDP socket bound to an ephemeral local port, used for both directions of call audio.
final class UdpSocket {
    let fd: Int32
    let localPort: UInt16

    init() throws {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw SocketError("udp socket") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { let e = errno; Darwin.close(s); throw SocketError("udp bind", errno: e) }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        fd = s
        localPort = UInt16(bigEndian: bound.sin_port)
        setTimeout(fd, SO_RCVTIMEO, seconds: 0.5)
    }

    func send(_ bytes: [UInt8], to ip: String, port: UInt16) {
        guard var addr = try? makeAddr(ip, port) else { return }
        bytes.withUnsafeBytes { raw in
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Returns the datagram length, 0 on timeout, or -1 if the socket is closed.
    func receive(into buf: inout [UInt8]) -> Int {
        let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if n >= 0 { return n }
        return (errno == EAGAIN || errno == EINTR) ? 0 : -1
    }

    func close() { Darwin.close(fd) }
}
