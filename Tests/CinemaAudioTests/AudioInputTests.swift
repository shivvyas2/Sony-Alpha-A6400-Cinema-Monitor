#if os(macOS)
import XCTest
import AVFoundation
import Combine
@testable import CinemaAudio

final class AudioInputTests: XCTestCase {
    func tone(_ format: AVAudioFormat, frames: Int, amplitude: Float) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0 ..< Int(format.channelCount) { for i in 0 ..< frames { b.floatChannelData![c][i] = amplitude * (Float(c) + 1) * sin(Float(i) * 0.1) } }
        return b
    }

    func testSelectPicksChannelsInOrder() {
        // AVAudioFormat(standardFormatWithSampleRate:channels:) only succeeds for 1-2 channels on this SDK;
        // use the shared PCMFormat helper for the 4-channel source buffer.
        let f = PCMFormat.float(channels: 4, sampleRate: 48000)
        let src = tone(f, frames: 10, amplitude: 0.1)
        let out = AudioInput.select(src, channels: [3, 1])
        XCTAssertEqual(out.format.channelCount, 2)
        XCTAssertEqual(out.frameLength, 10)
        XCTAssertEqual(out.floatChannelData![0][5], src.floatChannelData![2][5])
        XCTAssertEqual(out.floatChannelData![1][5], src.floatChannelData![0][5])
    }

    func testSelectFourOutputChannels() {
        let f = PCMFormat.float(channels: 6, sampleRate: 48000)
        let src = tone(f, frames: 10, amplitude: 0.1)
        let out = AudioInput.select(src, channels: [6, 5, 2, 1])
        XCTAssertEqual(out.format.channelCount, 4)
        XCTAssertFalse(out.format.isInterleaved)
        XCTAssertEqual(out.frameLength, 10)
        XCTAssertEqual(out.floatChannelData![0][5], src.floatChannelData![5][5])
        XCTAssertEqual(out.floatChannelData![1][5], src.floatChannelData![4][5])
        XCTAssertEqual(out.floatChannelData![2][5], src.floatChannelData![1][5])
        XCTAssertEqual(out.floatChannelData![3][5], src.floatChannelData![0][5])
    }

    /// Thread-safe frame counter for the @Sendable sink.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func add(_ v: Int) { lock.lock(); n += v; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testProcessFeedsPrerollSubscribersAndMeters() {
        let input = AudioInput(prerollSeconds: 1)
        input.configureForTesting(channels: 2, sampleRate: 1000, deviceName: "Test")
        let received = Counter()
        let sub = input.subscribe { received.add(Int($0.frameLength)) }
        let f = AVAudioFormat(standardFormatWithSampleRate: 1000, channels: 2)!
        for _ in 0 ..< 5 { input.process(tone(f, frames: 300, amplitude: 0.5)) }
        let pre = input.preroll(seconds: 1)
        XCTAssertEqual(pre.frameLength, 1000)
        let exp = expectation(description: "sink and meters")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(received.value, 1500)
        XCTAssertEqual(input.meters.channels.count, 2)
        XCTAssertGreaterThan(input.meters.channels[1].peak, input.meters.channels[0].peak, "channel 2 is louder")
        XCTAssertEqual(input.channelNames, ["Ch 1", "Ch 2"])
        sub.cancel()
        input.process(tone(f, frames: 100, amplitude: 0.5))
        let exp2 = expectation(description: "after cancel"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp2.fulfill() }
        wait(for: [exp2], timeout: 1)
        XCTAssertEqual(received.value, 1500, "cancelled sink gets nothing")
    }

    func testArmWithUnknownDeviceThrowsAndStaysDisarmed() {
        let input = AudioInput()
        let bogus = AudioDevice(id: 0xFFFF_FFF0, uid: "none", name: "None", inputChannelNames: ["1"], nominalSampleRate: 48000, supportedSampleRates: [48000])
        XCTAssertThrowsError(try input.arm(device: bogus, channels: [1]))
        XCTAssertFalse(input.isArmed)
    }
}
#endif
