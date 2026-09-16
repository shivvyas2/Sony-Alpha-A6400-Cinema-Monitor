#if os(macOS)
import AVFoundation
import AudioToolbox
import Combine
import CoreAudio

public enum AudioInputInterruption: Equatable, Sendable {
    case deviceRemoved, configurationChanged, engineStopped(String)
}

/// Captures one Core Audio input device: keeps the last few seconds (pre-roll), meters every buffer,
/// and hands copies to subscribers (the take recorder) on a serial queue. Nothing here touches disk.
public final class AudioInput {
    public enum Error: Swift.Error, LocalizedError {
        case noChannels, deviceUnavailable(OSStatus), engine(String)
        public var errorDescription: String? {
            switch self {
            case .noChannels: return "Pick at least one input channel"
            case .deviceUnavailable(let s): return "Audio device unavailable (\(s))"
            case .engine(let m): return m
            }
        }
    }

    public let meters = MeterState()
    public private(set) var isArmed = false
    public private(set) var device: AudioDevice?
    public private(set) var channels: [Int] = []
    public private(set) var sampleRate: Double = 0
    public var onInterruption: ((AudioInputInterruption) -> Void)?
    public var channelNames: [String] {
        guard let d = device else { return (0 ..< meters.channels.count).map { "Ch \($0 + 1)" } }
        return channels.map { d.inputChannelNames.indices.contains($0 - 1) ? d.inputChannelNames[$0 - 1] : "Ch \($0)" }
    }

    private let prerollSeconds: Double
    private var ring: RingBuffer?
    private var engine: AVAudioEngine?
    private let sinkQueue = DispatchQueue(label: "CinemaHUD.audio.sinks", qos: .userInitiated)
    private var sinks: [UUID: @Sendable (AVAudioPCMBuffer) -> Void] = [:]
    private let sinkLock = NSLock()
    private var lastMeterPublish = Date.distantPast
    private var observers: [Any] = []
    private var deviceWatch: Task<Void, Never>?

    public init(prerollSeconds: Double = 3) { self.prerollSeconds = prerollSeconds }
    deinit { disarm() }

    // MARK: Arm / disarm

    public func arm(device: AudioDevice, channels: [Int]) throws {
        disarm()
        let wanted = channels.filter { $0 >= 1 && $0 <= device.inputChannelNames.count }
        guard !wanted.isEmpty else { throw Error.noChannels }
        if device.nominalSampleRate != 48000, device.supportedSampleRates.contains(48000) {
            try? AudioDevices.setNominalSampleRate(48000, on: device.id)
        }
        let engine = AVAudioEngine()
        guard let unit = engine.inputNode.audioUnit else { throw Error.engine("No input unit") }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw Error.deviceUnavailable(status) }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Error.engine("Device reports no input format") }
        configure(channels: wanted.count, sampleRate: format.sampleRate, deviceName: device.name)
        self.device = device
        self.channels = wanted
        engine.inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.process(Self.select(buffer, channels: wanted))
        }
        engine.prepare()
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw Error.engine(error.localizedDescription)
        }
        self.engine = engine
        isArmed = true
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.interrupt(.configurationChanged)
        })
        let uid = device.uid
        deviceWatch = Task { [weak self] in
            for await _ in AudioDevices.changes() {
                guard !Task.isCancelled else { return }
                if AudioDevices.device(uid: uid) == nil { await MainActor.run { self?.interrupt(.deviceRemoved) }; return }
            }
        }
    }

    public func disarm() {
        deviceWatch?.cancel(); deviceWatch = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isArmed = false
    }

    private func interrupt(_ reason: AudioInputInterruption) {
        guard isArmed else { return }
        disarm()
        onInterruption?(reason)
    }

    // MARK: Buffers

    /// Sets up the ring buffer and meters without an engine (tests, and `arm` before the tap starts).
    func configureForTesting(channels: Int, sampleRate: Double, deviceName: String) {
        configure(channels: channels, sampleRate: sampleRate, deviceName: deviceName)
    }
    private func configure(channels: Int, sampleRate: Double, deviceName: String) {
        ring = RingBuffer(channels: channels, sampleRate: sampleRate, seconds: prerollSeconds)
        self.sampleRate = sampleRate
        meters.configure(channels: channels, sampleRate: sampleRate, deviceName: deviceName)
    }

    /// Called on the audio thread with the selected channels. Copies once, then fans out off-thread.
    func process(_ buffer: AVAudioPCMBuffer) {
        ring?.write(buffer)
        let readings = MeterMath.measure(buffer)
        let now = Date()
        if now.timeIntervalSince(lastMeterPublish) >= 1.0 / 30 {
            lastMeterPublish = now
            DispatchQueue.main.async { [meters] in meters.apply(readings, at: now) }
        }
        sinkLock.lock(); let targets = Array(sinks.values); sinkLock.unlock()
        guard !targets.isEmpty, let copy = Self.copy(buffer) else { return }
        sinkQueue.async { for t in targets { t(copy) } }
    }

    public func preroll(seconds: Double) -> AVAudioPCMBuffer {
        ring?.read(lastSeconds: seconds) ?? AVAudioPCMBuffer(pcmFormat: PCMFormat.float(channels: 1, sampleRate: 48000), frameCapacity: 1)!
    }

    public func subscribe(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AnyCancellable {
        let id = UUID()
        sinkLock.lock(); sinks[id] = sink; sinkLock.unlock()
        return AnyCancellable { [weak self] in
            guard let self else { return }
            self.sinkLock.lock(); self.sinks[id] = nil; self.sinkLock.unlock()
        }
    }

    /// A new buffer holding only `channels` (1-based device channel numbers), in that order.
    public static func select(_ buffer: AVAudioPCMBuffer, channels: [Int]) -> AVAudioPCMBuffer {
        let format = PCMFormat.float(channels: channels.count, sampleRate: buffer.format.sampleRate)
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength)!
        out.frameLength = buffer.frameLength
        guard let src = buffer.floatChannelData, let dst = out.floatChannelData else { return out }
        let n = Int(buffer.frameLength)
        for (i, ch) in channels.enumerated() {
            let c = min(max(0, ch - 1), Int(buffer.format.channelCount) - 1)
            dst[i].update(from: src[c], count: n)
        }
        return out
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength), let s = buffer.floatChannelData, let d = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        for c in 0 ..< Int(buffer.format.channelCount) { d[c].update(from: s[c], count: Int(buffer.frameLength)) }
        return out
    }
}
#endif
