import CryptoKit
import Foundation

/// CallBridge wire protocol; mirrors callbridge/proto/.../Proto.kt.
enum Proto {
    static let controlPort: UInt16 = 8765
    static let audioPort: UInt16 = 8766
    static let sampleRate = 16000
    static let frameSamples = sampleRate / 50 // 20 ms
    static let audioHeader = 8
    static let audioPacket = audioHeader + frameSamples * 2
    static let maxLine = 256 * 1024

    static let idle = "idle"
    static let ringing = "ringing"
    static let dialing = "dialing"
    static let active = "active"

    static func msg(_ type: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var m = fields
        m["t"] = type
        return m
    }

    /// [token:int32 le][seq:int32 le][frameSamples x int16 le]
    static func packAudio(token: Int32, seq: Int32, pcm: UnsafeBufferPointer<Int16>) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: audioPacket)
        out.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: token.littleEndian, toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: seq.littleEndian, toByteOffset: 4, as: Int32.self)
            for i in 0..<frameSamples {
                raw.storeBytes(of: pcm[i].littleEndian, toByteOffset: audioHeader + i * 2, as: Int16.self)
            }
        }
        return out
    }

    /// Returns the sequence number, or nil if the packet is malformed or the token is wrong.
    static func unpackAudio(_ data: UnsafeRawBufferPointer, token: Int32, into pcm: inout [Int16]) -> Int32? {
        guard data.count == audioPacket else { return nil }
        let t = Int32(littleEndian: data.loadUnaligned(fromByteOffset: 0, as: Int32.self))
        guard t == token else { return nil }
        let seq = Int32(littleEndian: data.loadUnaligned(fromByteOffset: 4, as: Int32.self))
        for i in 0..<frameSamples {
            pcm[i] = Int16(littleEndian: data.loadUnaligned(fromByteOffset: audioHeader + i * 2, as: Int16.self))
        }
        return seq
    }
}

enum Auth {
    static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// HMAC-SHA256 over each part followed by a NUL byte, keyed by the trimmed, upper-cased key.
    static func hmac(_ key: String, _ parts: String...) -> String {
        let k = SymmetricKey(data: Data(key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().utf8))
        var h = HMAC<SHA256>(key: k)
        for p in parts {
            h.update(data: Data(p.utf8))
            h.update(data: Data([0]))
        }
        return Data(h.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time string comparison.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
