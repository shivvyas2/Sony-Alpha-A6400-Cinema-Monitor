import XCTest
@testable import CinemaAudio

final class MIDIMessagesTests: XCTestCase {
    let tc = Timecode(h: 1, m: 2, s: 3, f: 4)

    func testRateMapping() {
        XCTAssertEqual(MTCRate(projectFPS: 24), .fps24)
        XCTAssertEqual(MTCRate(projectFPS: 25), .fps25)
        XCTAssertEqual(MTCRate(projectFPS: 30), .fps30)
        XCTAssertEqual(MTCRate(projectFPS: 60), .fps30)
        XCTAssertEqual(MTCRate.fps25.framesPerSecond, 25)
    }

    func testFullFrame() {
        // hours byte = rate << 5 | hours; 24 fps → rate 0
        XCTAssertEqual(MIDIMessages.mtcFullFrame(tc, rate: .fps24), [0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x01, 0x02, 0x03, 0x04, 0xF7])
        XCTAssertEqual(MIDIMessages.mtcFullFrame(tc, rate: .fps30)[5], 0x61)
    }

    func testQuarterFrames() {
        let q = (0 ..< 8).map { MIDIMessages.mtcQuarterFrame(index: $0, tc, rate: .fps25) }
        XCTAssertEqual(q, [[0xF1, 0x04], [0xF1, 0x10], [0xF1, 0x23], [0xF1, 0x30], [0xF1, 0x42], [0xF1, 0x50], [0xF1, 0x61], [0xF1, 0x72]])
        // 0x72: index 7 nibble = (rate 1 << 1) | hours high bit 0 = 0b0010
    }

    func testMMC() {
        XCTAssertEqual(MIDIMessages.mmcRecordStrobe, [0xF0, 0x7F, 0x7F, 0x06, 0x06, 0xF7])
        XCTAssertEqual(MIDIMessages.mmcStop, [0xF0, 0x7F, 0x7F, 0x06, 0x01, 0xF7])
        XCTAssertEqual(MIDIMessages.mmcPlay, [0xF0, 0x7F, 0x7F, 0x06, 0x02, 0xF7])
    }

    func testTimecodeFromDate() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 1, minute: 2, second: 3, nanosecond: 500_000_000))!
        XCTAssertEqual(Timecode(date: d, fps: 24, calendar: cal), Timecode(h: 1, m: 2, s: 3, f: 12))
    }

    func testSequencerEmitsFullFrameThenQuarterFramesAndResyncsAfterGap() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var now = cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 1, minute: 2, second: 3))!
        let seq = MTCSequencer(rate: .fps24, clock: { now }, calendar: cal)
        XCTAssertEqual(seq.next()[0], 0xF0, "first message is a full frame")
        // The sequencer samples the clock at index 0; 01:02:03:00 → frames low nibble 0.
        XCTAssertEqual(seq.next(), [0xF1, 0x00])
        for i in 1 ..< 8 { XCTAssertEqual(seq.next()[1] >> 4, UInt8(i)) }
        now = now.addingTimeInterval(1.0)                       // gap of 24 frames
        XCTAssertEqual(seq.next()[0], 0xF0, "resync with a full frame after a gap")
        XCTAssertEqual(seq.next(), [0xF1, 0x00])
    }

    func testOutOfRangeValuesAreMaskedNotTrapped() {
        let bad = Timecode(h: 40, m: 70, s: -1, f: 300)
        let full = MIDIMessages.mtcFullFrame(bad, rate: .fps24)
        XCTAssertEqual(full.count, 10)
        XCTAssertEqual(full[5], 40 & 0x1F)
        XCTAssertEqual(full[6], UInt8(70 & 0x3F))
        XCTAssertEqual(full[8], UInt8(300 & 0x1F))
        XCTAssertEqual(MIDIMessages.mtcQuarterFrame(index: 9, bad, rate: .fps24)[1] >> 4, 1, "index wraps to 0…7")
    }
}
