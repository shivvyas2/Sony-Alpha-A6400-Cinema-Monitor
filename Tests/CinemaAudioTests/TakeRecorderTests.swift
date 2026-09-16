#if os(macOS)
import XCTest
import AVFoundation
@testable import CinemaAudio

final class TakeRecorderTests: XCTestCase {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    func buffer(frames: Int, amplitude: Float = 0.3) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0 ..< 2 { for i in 0 ..< frames { b.floatChannelData![c][i] = amplitude * sin(Float(i) * 0.05) } }
        return b
    }
    func metadata() -> TakeMetadata { TakeMetadata(project: "CinemaHUD", projectFPS: 24, scene: "3", note: nil, camera: ["iso": "800"]) }

    func settle(_ seconds: Double = 0.3) {
        let e = expectation(description: "settle"); DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }; wait(for: [e], timeout: seconds + 2)
    }

    func testCompleteTakeWritesWAVWithPrerollAndLog() throws {
        let dir = try TestMedia.tempDir("rec")
        let input = AudioInput(prerollSeconds: 3)
        input.configureForTesting(channels: 2, sampleRate: 48000, deviceName: "Scarlett 2i2 USB")
        for _ in 0 ..< 10 { input.process(buffer(frames: 48000)) }        // 10 s of history; ring keeps 3 s
        let rec = TakeRecorder(input: input, dayFolder: dir, postRoll: 0)
        let t0 = Date()
        try rec.begin(label: TakeLabel(cameraIndex: "A", reel: 1, clip: 1), metadata: metadata(), pressedAt: t0)
        XCTAssertTrue(rec.isRecording)
        XCTAssertEqual(rec.current?.prerollSeconds, 3)
        for _ in 0 ..< 4 { input.process(buffer(frames: 24000)) }         // 2 s live
        settle()
        rec.cameraStarted(at: t0.addingTimeInterval(0.4))
        rec.cameraStopped(at: t0.addingTimeInterval(2.4))
        settle(0.5)
        XCTAssertFalse(rec.isRecording)
        XCTAssertNil(rec.current)
        let log = TakeLog.load(from: dir)
        XCTAssertEqual(log.takes.count, 1)
        let take = log.takes[0]
        XCTAssertEqual(take.id, "A_0001_C001")
        XCTAssertEqual(take.outcome, .complete)
        XCTAssertEqual(take.wavPath, "audio/A_0001_C001.wav")
        XCTAssertEqual(take.channelNames, ["Ch 1", "Ch 2"])
        // TakeLog's JSON encoding keeps millisecond precision only (Task 5), so a value that has been
        // through a save/load round-trip can be a sub-millisecond off from the in-memory Date it came
        // from; compare with the same 1 ms tolerance TakeLogTests uses for the same reason.
        XCTAssertEqual(take.confirmedStart?.timeIntervalSince1970 ?? 0, t0.addingTimeInterval(0.4).timeIntervalSince1970, accuracy: 0.001)
        let wav = dir.appendingPathComponent(take.wavPath)
        let file = try AVAudioFile(forReading: wav)
        XCTAssertEqual(file.length, 3 * 48000 + 2 * 48000, "3 s pre-roll + 2 s live")
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        let bext = try XCTUnwrap(BroadcastWave.readBext(url: wav))
        XCTAssertEqual(bext.description, "A_0001_C001")
        XCTAssertEqual(bext.timeReference, BroadcastWave.timeReference(for: t0.addingTimeInterval(-3), sampleRate: 48000))
        XCTAssertTrue(try XCTUnwrap(BroadcastWave.readIXML(url: wav)).contains("<SCENE>3</SCENE>"))
    }

    func testAbortDeletesFileKeepsLogEntry() throws {
        let dir = try TestMedia.tempDir("abort")
        let input = AudioInput(prerollSeconds: 1)
        input.configureForTesting(channels: 1, sampleRate: 48000, deviceName: "Test")
        input.process(buffer(frames: 4800))
        let rec = TakeRecorder(input: input, dayFolder: dir, postRoll: 0)
        try rec.begin(label: TakeLabel(cameraIndex: "A", reel: 1, clip: 2), metadata: metadata(), pressedAt: Date())
        settle(0.2)
        rec.abort(reason: .cameraNeverStarted)
        settle(0.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio/A_0001_C002.wav").path))
        XCTAssertEqual(TakeLog.load(from: dir).takes.first?.outcome, .cameraNeverStarted)
        XCTAssertNil(rec.current)
    }

    func testSecondTakeWithSameLabelGetsSuffix() throws {
        let dir = try TestMedia.tempDir("dup")
        let input = AudioInput(prerollSeconds: 1)
        input.configureForTesting(channels: 1, sampleRate: 48000, deviceName: "Test")
        let rec = TakeRecorder(input: input, dayFolder: dir, postRoll: 0)
        for _ in 0 ..< 2 {
            try rec.begin(label: TakeLabel(cameraIndex: "A", reel: 1, clip: 5), metadata: metadata(), pressedAt: Date())
            rec.cameraStarted(at: Date()); rec.cameraStopped(at: Date())
            settle(0.3)
        }
        let log = TakeLog.load(from: dir)
        XCTAssertEqual(log.takes.map(\.wavPath), ["audio/A_0001_C005.wav", "audio/A_0001_C005_2.wav"])
        XCTAssertEqual(log.takes.map(\.id), ["A_0001_C005", "A_0001_C005_2"])
    }

    func testBeginWhileRecordingThrows() throws {
        let dir = try TestMedia.tempDir("busy")
        let input = AudioInput(prerollSeconds: 1)
        input.configureForTesting(channels: 1, sampleRate: 48000, deviceName: "Test")
        let rec = TakeRecorder(input: input, dayFolder: dir, postRoll: 0)
        try rec.begin(label: TakeLabel(cameraIndex: "A", reel: 1, clip: 1), metadata: metadata(), pressedAt: Date())
        XCTAssertThrowsError(try rec.begin(label: TakeLabel(cameraIndex: "A", reel: 1, clip: 2), metadata: metadata(), pressedAt: Date()))
        rec.abort(reason: .cameraNeverStarted)
        settle(0.2)
    }
}
#endif
