import Foundation

public enum MTCRate: UInt8, Sendable {
    case fps24 = 0, fps25 = 1, fps30drop = 2, fps30 = 3
    public init(projectFPS: Int) {
        switch projectFPS { case 24: self = .fps24; case 25: self = .fps25; default: self = .fps30 }
    }
    public var framesPerSecond: Int { self == .fps25 ? 25 : (self == .fps24 ? 24 : 30) }
}

public struct Timecode: Equatable, Sendable {
    public var h: Int, m: Int, s: Int, f: Int
    public init(h: Int, m: Int, s: Int, f: Int) { self.h = h; self.m = m; self.s = s; self.f = f }
    /// Time of day at `fps`, the same numbers the HUD's TC readout shows.
    public init(date: Date, fps: Int, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        h = c.hour ?? 0; m = c.minute ?? 0; s = c.second ?? 0
        f = Int(Double(c.nanosecond ?? 0) / 1e9 * Double(fps))
    }
}

public enum MIDIMessages {
    public static func mtcFullFrame(_ tc: Timecode, rate: MTCRate) -> [UInt8] {
        [0xF0, 0x7F, 0x7F, 0x01, 0x01,
         (rate.rawValue << 5) | UInt8(tc.h & 0x1F), UInt8(tc.m & 0x3F), UInt8(tc.s & 0x3F), UInt8(tc.f & 0x1F), 0xF7]
    }
    /// Quarter frame `index` (0…7) for `tc`: F1 followed by (index << 4 | nibble).
    public static func mtcQuarterFrame(index: Int, _ tc: Timecode, rate: MTCRate) -> [UInt8] {
        let index = index & 0x07
        let nibble: Int
        switch index {
        case 0: nibble = tc.f & 0x0F
        case 1: nibble = (tc.f >> 4) & 0x01
        case 2: nibble = tc.s & 0x0F
        case 3: nibble = (tc.s >> 4) & 0x03
        case 4: nibble = tc.m & 0x0F
        case 5: nibble = (tc.m >> 4) & 0x03
        case 6: nibble = tc.h & 0x0F
        default: nibble = ((tc.h >> 4) & 0x01) | (Int(rate.rawValue) << 1)
        }
        return [0xF1, UInt8(index << 4 | nibble)]
    }
    public static let mmcRecordStrobe: [UInt8] = [0xF0, 0x7F, 0x7F, 0x06, 0x06, 0xF7]
    public static let mmcStop: [UInt8] = [0xF0, 0x7F, 0x7F, 0x06, 0x01, 0xF7]
    public static let mmcPlay: [UInt8] = [0xF0, 0x7F, 0x7F, 0x06, 0x02, 0xF7]
}

/// Decides what to send on each MTC tick (4 × fps per second). Pure: the caller owns the timer.
public final class MTCSequencer {
    public let rate: MTCRate
    private let clock: () -> Date
    private let calendar: Calendar
    private var index = -1            // -1 = send a full frame next
    private var current = Timecode(h: 0, m: 0, s: 0, f: 0)
    private var lastSample: Date?
    private var lastFull: Date?
    public static let fullFrameInterval: TimeInterval = 10

    public init(rate: MTCRate, clock: @escaping () -> Date, calendar: Calendar = .current) {
        self.rate = rate; self.clock = clock; self.calendar = calendar
    }

    public func reset() { index = -1; lastSample = nil; lastFull = nil }

    public func next() -> [UInt8] {
        let now = clock()
        if index == -1 || index == 0 {
            // A quarter-frame sequence spans two frames; if the clock jumped (timer stall, sleep) resync.
            let frame = 1.0 / Double(rate.framesPerSecond)
            let gap = lastSample.map { now.timeIntervalSince($0) - 2 * frame } ?? 0
            let stale = lastFull.map { now.timeIntervalSince($0) > Self.fullFrameInterval } ?? true
            if index == -1 || gap > 2 * frame || stale {
                current = Timecode(date: now, fps: rate.framesPerSecond, calendar: calendar)
                lastSample = now; lastFull = now; index = 0
                return MIDIMessages.mtcFullFrame(current, rate: rate)
            }
            current = Timecode(date: now, fps: rate.framesPerSecond, calendar: calendar)
            lastSample = now
        }
        let msg = MIDIMessages.mtcQuarterFrame(index: index, current, rate: rate)
        index = (index + 1) % 8
        return msg
    }
}
