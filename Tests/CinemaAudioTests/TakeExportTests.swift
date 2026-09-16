import XCTest
import AVFoundation
@testable import CinemaAudio

final class TakeExportTests: XCTestCase {
    func take() -> TakeRecord {
        TakeRecord(id: "A_0001_C001", label: TakeLabel(cameraIndex: "A", reel: 1, clip: 1), wavPath: "audio/A_0001_C001.wav",
                   pressedAt: Date(timeIntervalSince1970: 1_800_000_003), confirmedStart: nil, confirmedStop: nil, prerollSeconds: 3,
                   sampleRate: 48000, channelNames: ["Input 1"], metadata: TakeMetadata(project: "CinemaHUD", projectFPS: 24, scene: "1", note: nil, camera: [:]),
                   outcome: .complete)
    }

    func testTrimmedWAVStartsAtOffsetAndShiftsTimeReference() throws {
        let dir = try TestMedia.tempDir("trim")
        let src = dir.appendingPathComponent("A_0001_C001.wav"), out = dir.appendingPathComponent("out.wav")
        try TestMedia.writeWAV(url: src, seconds: 5, amplitude: 0.2, burstAt: 2.0)
        let t = take()
        let ref = BroadcastWave.timeReference(for: t.firstSampleDate, sampleRate: 48000)
        try BroadcastWave.finalize(url: src, bext: .init(description: "A_0001_C001", originator: "CinemaHUD", originatorReference: "", originationDate: "2027-01-15", originationTime: "00:00:00", timeReference: ref, codingHistory: ""), ixml: "<BWFXML/>")
        try TakeExport.trimmedWAV(wav: src, offset: 1.5, duration: 2, take: t, to: out)
        let f = try AVAudioFile(forReading: out)
        XCTAssertEqual(f.length, 96000)
        XCTAssertEqual(f.fileFormat.sampleRate, 48000)
        XCTAssertEqual(f.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
        let bext = try XCTUnwrap(BroadcastWave.readBext(url: out))
        XCTAssertEqual(bext.timeReference, ref + UInt64(1.5 * 48000))
        XCTAssertTrue(try XCTUnwrap(BroadcastWave.readIXML(url: out)).contains("<TAKE>1</TAKE>"))
        let samples = try awaitSamples(out)
        let peakAt = Double(samples.indices.max { abs(samples[$0]) < abs(samples[$1]) }!) / 48000
        XCTAssertEqual(peakAt, 0.5, accuracy: 0.06, "burst at 2.0 s in the source lands at 0.5 s")
    }

    func testTrimmedWAVPadsWithSilence() throws {
        let dir = try TestMedia.tempDir("pad")
        let src = dir.appendingPathComponent("s.wav"), out = dir.appendingPathComponent("o.wav")
        try TestMedia.writeWAV(url: src, seconds: 1)
        try TakeExport.trimmedWAV(wav: src, offset: 0.5, duration: 2, take: nil, to: out)
        XCTAssertEqual(try AVAudioFile(forReading: out).length, 96000)
    }

    func testMovieHasPassthroughVideoAndTwoAudioTracks() async throws {
        let dir = try TestMedia.tempDir("mov")
        let clip = dir.appendingPathComponent("C0001.MP4"), wav = dir.appendingPathComponent("w.wav"), out = dir.appendingPathComponent("C0001_synced.mov")
        try TestMedia.writeMovie(url: clip, seconds: 3, burstAt: 1.0)
        try TestMedia.writeWAV(url: wav, seconds: 8, amplitude: 0.2, burstAt: 3.0)
        try await TakeExport.movie(clip: clip, wav: wav, offset: 2.0, to: out)
        let asset = AVURLAsset(url: out)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 2)
        let desc = try await video[0].load(.formatDescriptions).first
        XCTAssertEqual(desc.map { CMFormatDescriptionGetMediaSubType($0) }, kCMVideoCodecType_H264, "video is passed through")
        let movieDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(movieDuration, 3, accuracy: 0.05)
        let track1 = try await AudioDecoder.monoSamples(url: out, sampleRate: 48000, trackIndex: 0)
        let peakAt = Double(track1.indices.max { abs(track1[$0]) < abs(track1[$1]) }!) / 48000
        XCTAssertEqual(peakAt, 1.0, accuracy: 0.06, "WAV burst at 3.0 s with offset 2.0 lands at 1.0 s")
    }

    func testOutputNames() {
        let c = ClipInfo(id: URL(fileURLWithPath: "/card/C0007.MP4"), name: "C0007", duration: 1, creationDate: nil, hasAudio: true, videoSize: .zero, nominalFrameRate: 24)
        let o = TakeExport.outputs(for: c, take: take(), in: URL(fileURLWithPath: "/day/synced"))
        XCTAssertEqual(o.wav.path, "/day/synced/A_0001_C001.wav")
        XCTAssertEqual(o.mov.path, "/day/synced/C0007_synced.mov")
    }

    private func awaitSamples(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: b)
        return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
    }
}
