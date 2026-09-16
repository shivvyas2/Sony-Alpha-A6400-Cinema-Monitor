// Tests/CinemaAudioTests/TakeSyncTests.swift
import XCTest
import AVFoundation
@testable import CinemaAudio

final class TakeSyncTests: XCTestCase {
    func take(_ clip: Int, pressed: TimeInterval, wavSeconds: Double, outcome: TakeRecord.Outcome = .complete) -> TakeRecord {
        let stem = TakeLabel(cameraIndex: "A", reel: 1, clip: clip).fileStem
        return TakeRecord(id: stem, label: TakeLabel(cameraIndex: "A", reel: 1, clip: clip), wavPath: "audio/\(stem).wav",
                          pressedAt: Date(timeIntervalSince1970: pressed), confirmedStart: Date(timeIntervalSince1970: pressed + 0.4),
                          confirmedStop: Date(timeIntervalSince1970: pressed + 0.4 + wavSeconds - 4), prerollSeconds: 3, sampleRate: 48000,
                          channelNames: ["1"], metadata: TakeMetadata(project: "p", projectFPS: 24, scene: nil, note: nil, camera: [:]), outcome: outcome)
    }
    func clip(_ name: String, duration: Double, at: TimeInterval) -> ClipInfo {
        ClipInfo(id: URL(fileURLWithPath: "/tmp/\(name).MP4"), name: name, duration: duration, creationDate: Date(timeIntervalSince1970: at),
                 hasAudio: true, videoSize: CGSize(width: 3840, height: 2160), nominalFrameRate: 23.976)
    }

    func testEstimateUsesPrerollAndConfirmDelay() {
        // accuracy 1e-6, not 1e-9: `Date(timeIntervalSince1970:)` on this platform round-trips fractional
        // seconds with ~2.4e-8 s error (confirmed independent of this code: `Date(timeIntervalSince1970:
        // 100.4).timeIntervalSince1970` itself already returns 100.39999997615814), so 1e-9 is tighter
        // than Foundation's own Date precision here.
        XCTAssertEqual(TakeSync.estimate(take(1, pressed: 100, wavSeconds: 14)), 3.4, accuracy: 1e-6)
        var t = take(1, pressed: 100, wavSeconds: 14); t.confirmedStart = nil
        XCTAssertEqual(TakeSync.estimate(t), 3)
    }

    func testPairingByOrderAndDuration() {
        // WAV = preroll 3 + 0.4 confirm delay + clip + 1 post-roll → clip ≈ wav − 4 (tolerance max(2 s, 5 %))
        let takes = [take(1, pressed: 100, wavSeconds: 14), take(2, pressed: 200, wavSeconds: 34), take(3, pressed: 300, wavSeconds: 64), take(4, pressed: 400, wavSeconds: 8, outcome: .cameraNeverStarted)]
        let clips = [clip("C0001", duration: 10, at: 50), clip("C0002", duration: 30, at: 150), clip("C0003", duration: 5, at: 250), clip("C0004", duration: 60.5, at: 350)]
        let pairs = TakeSync.pair(clips: clips, takes: takes)
        XCTAssertEqual(pairs.map { $0.take?.label.clip }, [1, 2, nil, 3])
        XCTAssertEqual(pairs[2].status, .unpaired)
        XCTAssertEqual(pairs[3].status, .estimated)
        // accuracy 1e-6: see the note in testEstimateUsesPrerollAndConfirmDelay re: Date's fractional-second precision.
        XCTAssertEqual(pairs[3].offsetSeconds ?? -1, 3.4, accuracy: 1e-6)
    }

    func testPairingSkipsTakeWithoutWAVOnDisk() {
        // Status .missingWAV is assigned by the caller once it checks the disk; pairing itself marks .estimated.
        let pairs = TakeSync.pair(clips: [clip("C1", duration: 10, at: 1)], takes: [take(1, pressed: 0, wavSeconds: 14)])
        XCTAssertEqual(pairs[0].status, .estimated)
    }

    func testInspectFindsClipsInFolderAndReadsDuration() async throws {
        let dir = try TestMedia.tempDir("inspect")
        let clipDir = dir.appendingPathComponent("PRIVATE/M4ROOT/CLIP")
        try FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)
        try TestMedia.writeMovie(url: clipDir.appendingPathComponent("C0001.MP4"), seconds: 2)
        try TestMedia.writeMovie(url: clipDir.appendingPathComponent("C0002.MP4"), seconds: 1)
        FileManager.default.createFile(atPath: clipDir.appendingPathComponent("C0001M01.XML").path, contents: Data())
        let clips = await TakeSync.inspect([dir])
        XCTAssertEqual(clips.map(\.name).sorted(), ["C0001", "C0002"])
        let c1 = try XCTUnwrap(clips.first { $0.name == "C0001" })
        XCTAssertEqual(c1.duration, 2, accuracy: 0.05)
        XCTAssertTrue(c1.hasAudio)
        XCTAssertEqual(c1.videoSize, CGSize(width: 320, height: 180))
        XCTAssertEqual(c1.nominalFrameRate, 24, accuracy: 0.01)
    }

    func testOffsetFindsBurstAlignment() async throws {
        let dir = try TestMedia.tempDir("offset")
        let clip = dir.appendingPathComponent("C0001.MP4"), wav = dir.appendingPathComponent("A_0001_C001.wav")
        // Clip: 6 s, burst at 2.0 s. WAV: 12 s, burst at 5.5 s → clip starts 3.5 s into the WAV.
        try TestMedia.writeMovie(url: clip, seconds: 6, burstAt: 2.0)
        try TestMedia.writeWAV(url: wav, seconds: 12, amplitude: 0.3, frequency: 440, burstAt: 5.5)
        let r = try await TakeSync.offset(clip: clip, wav: wav, around: 3.0, window: 5)
        XCTAssertEqual(r.offset, 3.5, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(r.confidence, 0.9)
    }

    func testDecoderMonoAndTrackSelect() async throws {
        let dir = try TestMedia.tempDir("decode")
        let wav = dir.appendingPathComponent("t.wav")
        try TestMedia.writeWAV(url: wav, seconds: 1, channels: 2, amplitude: 0.5)
        let s = try await AudioDecoder.monoSamples(url: wav, sampleRate: 8000)
        XCTAssertEqual(s.count, 8000, accuracy: 16)
        // Stereo→mono downmix applies the −3 dB pan law: two identical 0.5 channels sum to ≈ 0.707.
        let peak = s.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.45); XCTAssertLessThan(peak, 0.75)
    }
}
