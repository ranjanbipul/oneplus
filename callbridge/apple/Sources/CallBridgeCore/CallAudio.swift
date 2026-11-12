import AVFoundation
import Foundation
import os

/// Call audio: microphone -> gateway and gateway -> speaker, 16 kHz mono PCM16 over UDP.
/// Voice processing (echo cancellation, noise suppression, AGC) is on, so a device's own
/// speaker and microphone can be used without the far party hearing themselves.
/// Microphone permission and (on iOS) the audio session are the caller's job.
public final class CallAudio: @unchecked Sendable {
    /// Called on the main thread with a user-facing message when audio cannot run.
    public var onError: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var tapCount = 0
    private let jitter = JitterBuffer()
    private var micPending = [Int16]()
    private var seq: Int32 = 0
    private var configObserver: NSObjectProtocol?
    private let state = OSAllocatedUnfairLock(initialState: Session?.none)

    /// Settable from any thread; read on the audio tap thread.
    private let mutedFlag = OSAllocatedUnfairLock(initialState: false)
    public var muted: Bool {
        get { mutedFlag.withLock { $0 } }
        set { mutedFlag.withLock { $0 = newValue } }
    }

    private struct Session {
        let udp: UdpSocket
        let ip: String
        let token: Int32
        let id = UUID()
    }

    public var running: Bool { state.withLock { $0 != nil } }

    /// Engine setup can block (device negotiation, permission checks), so it never runs on
    /// the caller's thread: everything that touches the engine runs on this queue.
    private let queue = DispatchQueue(label: "callbridge.audio", qos: .userInteractive)

    public init() {}

    /// Starts streaming to and from the gateway. No-op if already running.
    public func start(udp: UdpSocket, ip: String, token: Int32) {
        let session = Session(udp: udp, ip: ip, token: token)
        let started = state.withLock { s -> Bool in
            if s != nil { return false }
            s = session
            return true
        }
        guard started else { return }
        let t = Thread { [weak self] in self?.receiveLoop(session) }
        t.name = "callbridge.audio.rx"
        t.qualityOfService = .userInteractive
        t.start()
        queue.async { [self] in
            guard state.withLock({ $0?.id == session.id }) else { return }
            seq = 0
            micPending.removeAll()
            jitter.reset()
            do {
                try startEngine()
            } catch {
                NSLog("CallBridge: audio start failed: \(error)")
                report("Audio failed: \(error.localizedDescription)")
                return
            }
            if configObserver == nil {
                configObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
                ) { [weak self] n in
                    guard let self, let e = n.object as? AVAudioEngine else { return }
                    self.queue.async { if e === self.engine { self.scheduleRestart() } }
                }
            }
        }
    }

    public func stop() {
        let was = state.withLock { s -> Bool in
            defer { s = nil }
            return s != nil
        }
        guard was else { return }
        queue.async { [self] in
            if let o = configObserver { NotificationCenter.default.removeObserver(o) }
            configObserver = nil
            stopEngine()
        }
    }

    /// Blocks until the engine is torn down (use before the UDP socket closes).
    public func stopAndWait() {
        stop()
        queue.sync {}
    }

    private func report(_ msg: String) {
        DispatchQueue.main.async { self.onError?(msg) }
    }

    // MARK: engine

    private func startEngine() throws {
        let e = AVAudioEngine()
        let input = e.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            NSLog("CallBridge: voice processing unavailable, continuing without it: \(error)")
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw SocketError("no microphone input available", errno: 0)
        }
        let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Proto.sampleRate), channels: 1, interleaved: true)!
        // With voice processing on, macOS reports several channels; the processed voice is
        // channel 0, so convert from that alone.
        let mono = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1)!
        guard let conv = AVAudioConverter(from: mono, to: wire) else {
            throw SocketError("cannot convert microphone format \(inFormat)", errno: 0)
        }
        monoFormat = mono
        tapCount = 0
        NSLog("CallBridge: mic format \(inFormat), voice processing \(input.isVoiceProcessingEnabled)")
        converter = conv
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            self?.onMic(buf)
        }

        let playFormat = AVAudioFormat(standardFormatWithSampleRate: Double(Proto.sampleRate), channels: 1)!
        let jitter = self.jitter
        let src = AVAudioSourceNode(format: playFormat) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            jitter.read(into: out, count: Int(frameCount))
            for b in buffers.dropFirst() {
                if let d = b.mData { memcpy(d, out, Int(b.mDataByteSize)) }
            }
            return noErr
        }
        e.attach(src)
        e.connect(src, to: e.mainMixerNode, format: playFormat)
        e.prepare()
        try e.start()
        engineStarted = Date()
        engine = e
        source = src
    }

    private func stopEngine() {
        guard let e = engine else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        if let s = source { e.detach(s) }
        engine = nil
        source = nil
        converter = nil
    }

    private var engineStarted = Date.distantPast
    private var restartPending = false

    /// The engine stops itself on every configuration change. Turning voice processing on
    /// causes one right after start, which only needs the same engine started again; a later
    /// change (headphones plugged, default device switched) gets the graph rebuilt.
    private func scheduleRestart() {
        guard !restartPending else { return }
        restartPending = true
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            self.restartEngine(rebuild: Date().timeIntervalSince(self.engineStarted) > 3)
        }
    }

    private func restartEngine(rebuild: Bool) {
        guard running, let e = engine else { return }
        NSLog("CallBridge: audio configuration changed (rebuild: \(rebuild))")
        do {
            if rebuild {
                stopEngine()
                try startEngine()
            } else if !e.isRunning {
                try e.start()
            }
        } catch {
            report("Audio failed after device change: \(error.localizedDescription)")
        }
    }

    // MARK: uplink

    private func onMic(_ buf: AVAudioPCMBuffer) {
        guard let session = state.withLock({ $0 }), let conv = converter, let mono = monoFormat,
              let ch0 = buf.floatChannelData?[0],
              let monoBuf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength)
        else { return }
        monoBuf.frameLength = buf.frameLength
        memcpy(monoBuf.floatChannelData![0], ch0, Int(buf.frameLength) * MemoryLayout<Float>.size)
        let ratio = Double(Proto.sampleRate) / mono.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: cap) else { return }
        var given = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return monoBuf
        }
        tapCount += 1
        if tapCount == 1 {
            NSLog("CallBridge: mic tap #\(tapCount): \(buf.frameLength) frames in, \(out.frameLength) out, error \(String(describing: err))")
        }
        if err != nil { return }
        guard let samples = out.int16ChannelData?[0] else { return }
        micPending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
        let n = Proto.frameSamples
        let silent = muted
        let zeros = [Int16](repeating: 0, count: n)
        while micPending.count >= n {
            let frame = silent ? zeros : Array(micPending[0..<n])
            micPending.removeFirst(n)
            let packet = frame.withUnsafeBufferPointer { Proto.packAudio(token: session.token, seq: seq, pcm: $0) }
            seq &+= 1
            session.udp.send(packet, to: session.ip, port: Proto.audioPort)
        }
    }

    // MARK: downlink

    private func receiveLoop(_ session: Session) {
        var buf = [UInt8](repeating: 0, count: 2048)
        var pcm = [Int16](repeating: 0, count: Proto.frameSamples)
        var last: Int32 = -1
        while state.withLock({ $0?.id == session.id }) {
            let n = session.udp.receive(into: &buf)
            if n < 0 { break }
            if n == 0 { continue }
            let seq = buf.withUnsafeBytes { raw in
                Proto.unpackAudio(UnsafeRawBufferPointer(rebasing: raw[0..<n]), token: session.token, into: &pcm)
            }
            guard let seq else { continue }
            // Drop late or duplicated packets; accept a restart of the sequence.
            if seq <= last && last - seq < 500 { continue }
            last = seq
            jitter.write(pcm)
        }
    }
}

/// Adaptive-free, bounded jitter buffer: waits for ~60 ms before playing, plays silence on
/// underrun (then re-buffers), and drops the oldest audio when more than ~240 ms pile up.
final class JitterBuffer: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var ring = [Float](repeating: 0, count: Proto.sampleRate) // 1 s
    private var readPos = 0
    private var count = 0
    private var priming = true
    private let startLevel = Proto.frameSamples * 3
    private let maxLevel = Proto.frameSamples * 12
    private let trimLevel = Proto.frameSamples * 4

    func reset() {
        os_unfair_lock_lock(&lock)
        readPos = 0
        count = 0
        priming = true
        os_unfair_lock_unlock(&lock)
    }

    func write(_ pcm: [Int16]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let cap = ring.count
        for s in pcm {
            if count == cap { readPos = (readPos + 1) % cap; count -= 1 }
            ring[(readPos + count) % cap] = Float(s) / 32768
            count += 1
        }
        if count > maxLevel {
            let drop = count - trimLevel
            readPos = (readPos + drop) % cap
            count -= drop
        }
        if priming && count >= startLevel { priming = false }
    }

    /// Called on the real-time render thread.
    func read(into out: UnsafeMutablePointer<Float>, count n: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if priming {
            out.update(repeating: 0, count: n)
            return
        }
        let cap = ring.count
        let take = min(n, count)
        for i in 0..<take { out[i] = ring[(readPos + i) % cap] }
        readPos = (readPos + take) % cap
        count -= take
        if take < n {
            out.advanced(by: take).update(repeating: 0, count: n - take)
            priming = true
        }
    }
}
