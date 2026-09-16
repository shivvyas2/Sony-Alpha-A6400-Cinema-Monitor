#if os(macOS)
import XCTest
@testable import CinemaAudio

final class LogicTransportTests: XCTestCase {
    func testTimerSendsQuarterFramesAtFourTimesFPS() throws {
        var sent: [[UInt8]] = []
        let lock = NSLock()
        let t = try LogicTransport(send: { m in lock.lock(); sent.append(m); lock.unlock() })
        t.startTimecode(rate: .fps24, clock: { Date() })
        XCTAssertTrue(t.isRunning)
        XCTAssertEqual(t.rate, .fps24)
        let e = expectation(description: "ticks"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { e.fulfill() }; wait(for: [e], timeout: 2)
        t.stopTimecode()
        XCTAssertFalse(t.isRunning)
        lock.lock(); let snapshot = sent; lock.unlock()
        XCTAssertEqual(snapshot.first?.first, 0xF0, "starts with a full frame")
        XCTAssertGreaterThanOrEqual(snapshot.count, 36, "≥ 75 % of the 48 messages expected in 0.5 s at 96 Hz")
        XCTAssertTrue(snapshot.dropFirst().allSatisfy { $0[0] == 0xF1 || $0[0] == 0xF0 })
        let e2 = expectation(description: "quiet"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { e2.fulfill() }; wait(for: [e2], timeout: 1)
        lock.lock(); XCTAssertEqual(sent.count, snapshot.count, "nothing after stop"); lock.unlock()
    }

    func testTransportMessages() throws {
        var sent: [[UInt8]] = []
        let t = try LogicTransport(send: { sent.append($0) })
        t.recordStrobe(); t.stop(); t.play()
        XCTAssertEqual(sent, [MIDIMessages.mmcRecordStrobe, MIDIMessages.mmcStop, MIDIMessages.mmcPlay])
    }

    func testStopWaitsForInFlightTick() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var finished = false
        var isFirst = true
        let lock = NSLock()
        let t = try LogicTransport(send: { _ in
            lock.lock()
            let first = isFirst; isFirst = false
            lock.unlock()
            if first {
                started.signal()
                release.wait()                       // hold the tick until the test lets go
                lock.lock(); finished = true; lock.unlock()
            }
        })
        t.startTimecode(rate: .fps24, clock: { Date() })
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success, "a tick started")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { release.signal() }
        t.stopTimecode()                         // must block until the held tick completes
        lock.lock(); XCTAssertTrue(finished, "stopTimecode returned before the in-flight tick finished"); lock.unlock()
    }

    func testRealSourceCanBeCreated() throws {
        let t = try LogicTransport(sourceName: "CinemaHUD Test")
        t.recordStrobe()          // must not crash without a receiver
        t.stop()
    }
}
#endif
