import AVFoundation
import Accelerate
import Observation

public enum MeterMath {
    public struct Reading: Equatable, Sendable {
        public var peak: Float   // dBFS
        public var rms: Float    // dBFS
        public init(peak: Float, rms: Float) { self.peak = peak; self.rms = rms }
    }
    public static let floor: Float = -60

    public static func dBFS(_ linear: Float) -> Float {
        guard linear > 0 else { return floor }
        return max(floor, 20 * log10(linear))
    }

    /// Peak and RMS per channel of a non-interleaved Float32 buffer.
    public static func measure(_ buffer: AVAudioPCMBuffer) -> [Reading] {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        let n = vDSP_Length(buffer.frameLength)
        return (0 ..< Int(buffer.format.channelCount)).map { c in
            var peak: Float = 0, rms: Float = 0
            vDSP_maxmgv(data[c], 1, &peak, n)
            vDSP_rmsqv(data[c], 1, &rms, n)
            return Reading(peak: dBFS(peak), rms: dBFS(rms))
        }
    }
}

/// What the HUD draws. Updated on the main actor at ≤ 30 Hz by `AudioInput`.
@Observable
public final class MeterState {
    public struct Channel: Equatable, Sendable {
        public var peak: Float = MeterMath.floor
        public var rms: Float = MeterMath.floor
        public var hold: Float = MeterMath.floor
        public var clipped = false
    }
    public static let holdSeconds: TimeInterval = 1.5
    public static let clipThreshold: Float = -0.1

    public private(set) var channels: [Channel] = []
    public private(set) var sampleRate: Double = 0
    public private(set) var deviceName = ""
    @ObservationIgnored private var holdSince: [Date] = []

    public init() {}

    public func configure(channels: Int, sampleRate: Double, deviceName: String) {
        self.channels = Array(repeating: Channel(), count: channels)
        holdSince = Array(repeating: .distantPast, count: channels)
        self.sampleRate = sampleRate
        self.deviceName = deviceName
    }

    public func apply(_ readings: [MeterMath.Reading], at now: Date) {
        guard readings.count == channels.count else { return }
        for i in readings.indices {
            var ch = channels[i]
            ch.peak = readings[i].peak
            ch.rms = readings[i].rms
            if ch.peak >= ch.hold || now.timeIntervalSince(holdSince[i]) > Self.holdSeconds {
                ch.hold = ch.peak
                holdSince[i] = now
            }
            if ch.peak >= Self.clipThreshold { ch.clipped = true }
            channels[i] = ch
        }
    }

    public func resetClip() {
        for i in channels.indices { channels[i].clipped = false }
    }
}
