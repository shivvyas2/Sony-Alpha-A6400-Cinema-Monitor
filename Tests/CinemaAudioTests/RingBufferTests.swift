import XCTest
import AVFoundation
@testable import CinemaAudio

final class RingBufferTests: XCTestCase {
    /// A buffer whose channel c sample i is Float(start + i) + c * 1000.
    func ramp(_ format: AVAudioFormat, start: Int, frames: Int) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0 ..< Int(format.channelCount) {
            for i in 0 ..< frames { b.floatChannelData![c][i] = Float(start + i) + Float(c) * 1000 }
        }
        return b
    }

    func testReadReturnsLastSecondsInOrderAcrossWrap() {
        let rb = RingBuffer(channels: 2, sampleRate: 100, seconds: 3)      // capacity 300 frames
        var pos = 0
        for _ in 0 ..< 10 { rb.write(ramp(rb.format, start: pos, frames: 50)); pos += 50 }   // 500 frames written
        let out = rb.read(lastSeconds: 3)
        XCTAssertEqual(out.frameLength, 300)
        XCTAssertEqual(out.floatChannelData![0][0], 200)       // frames 200…499
        XCTAssertEqual(out.floatChannelData![0][299], 499)
        XCTAssertEqual(out.floatChannelData![1][0], 1200)
    }

    func testReadBeforeFullReturnsOnlyWhatWasWritten() {
        let rb = RingBuffer(channels: 1, sampleRate: 100, seconds: 3)
        rb.write(ramp(rb.format, start: 0, frames: 120))
        let out = rb.read(lastSeconds: 3)
        XCTAssertEqual(out.frameLength, 120)
        XCTAssertEqual(out.floatChannelData![0][119], 119)
    }

    func testRequestLongerThanCapacityIsClamped() {
        let rb = RingBuffer(channels: 1, sampleRate: 100, seconds: 1)
        rb.write(ramp(rb.format, start: 0, frames: 250))
        XCTAssertEqual(rb.read(lastSeconds: 10).frameLength, 100)
        XCTAssertEqual(rb.read(lastSeconds: 0.5).frameLength, 50)
        XCTAssertEqual(rb.read(lastSeconds: 0.5).floatChannelData![0][0], 200)
    }

    func testWriteLargerThanCapacityKeepsTail() {
        let rb = RingBuffer(channels: 1, sampleRate: 100, seconds: 1)
        rb.write(ramp(rb.format, start: 0, frames: 1000))
        let out = rb.read(lastSeconds: 1)
        XCTAssertEqual(out.frameLength, 100)
        XCTAssertEqual(out.floatChannelData![0][0], 900)
        XCTAssertEqual(out.floatChannelData![0][99], 999)
    }
}
