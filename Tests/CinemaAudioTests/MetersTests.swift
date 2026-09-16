import XCTest
import AVFoundation
@testable import CinemaAudio

final class MetersTests: XCTestCase {
    func sine(amplitude: Float, frames: Int = 4800, channels: Int = 1) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: AVAudioChannelCount(channels))!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0 ..< channels { for i in 0 ..< frames { b.floatChannelData![c][i] = amplitude * sin(Float(i) * 2 * .pi * 1000 / 48000) } }
        return b
    }

    func testFullScaleSine() {
        let r = MeterMath.measure(sine(amplitude: 1))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].peak, 0, accuracy: 0.01)
        XCTAssertEqual(r[0].rms, -3.01, accuracy: 0.05)
    }

    func testSilenceIsFloor() {
        let r = MeterMath.measure(sine(amplitude: 0, channels: 2))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].peak, MeterMath.floor)
        XCTAssertEqual(r[1].rms, MeterMath.floor)
    }

    func testClipLatchesAndHoldDecays() {
        let m = MeterState()
        m.configure(channels: 1, sampleRate: 48000, deviceName: "Test")
        let t0 = Date()
        m.apply([.init(peak: -20, rms: -26)], at: t0)
        XCTAssertEqual(m.channels[0].hold, -20)
        XCTAssertFalse(m.channels[0].clipped)
        m.apply([.init(peak: -0.05, rms: -3)], at: t0.addingTimeInterval(0.1))
        XCTAssertTrue(m.channels[0].clipped)
        XCTAssertEqual(m.channels[0].hold, -0.05)
        m.apply([.init(peak: -30, rms: -36)], at: t0.addingTimeInterval(1.0))
        XCTAssertEqual(m.channels[0].hold, -0.05, "hold keeps the peak for 1.5 s")
        m.apply([.init(peak: -30, rms: -36)], at: t0.addingTimeInterval(2.0))
        XCTAssertEqual(m.channels[0].hold, -30, "hold drops to the current peak after 1.5 s")
        XCTAssertTrue(m.channels[0].clipped, "clip stays latched")
        m.resetClip()
        XCTAssertFalse(m.channels[0].clipped)
    }

    func testApplyIgnoresChannelCountMismatch() {
        let m = MeterState()
        m.configure(channels: 2, sampleRate: 48000, deviceName: "Test")
        m.apply([.init(peak: -1, rms: -4)], at: Date())
        XCTAssertEqual(m.channels.map(\.peak), [MeterMath.floor, MeterMath.floor])
    }
}
