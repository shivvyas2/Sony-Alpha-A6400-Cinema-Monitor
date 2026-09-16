import XCTest
import AVFoundation
@testable import CinemaAudio

final class BroadcastWaveTests: XCTestCase {
    func testFinalizeAppendsChunksAndKeepsFileReadable() throws {
        let dir = try TestMedia.tempDir("bwf")
        let url = dir.appendingPathComponent("A_0001_C001.wav")
        try TestMedia.writeWAV(url: url, seconds: 1)
        let bext = BroadcastWave.Bext(description: "A_0001_C001", originator: "CinemaHUD", originatorReference: "ref",
                                      originationDate: "2026-09-15", originationTime: "14:03:20", timeReference: 2_428_800_000,
                                      codingHistory: "A=PCM,F=48000,W=24,M=mono,T=CinemaHUD")
        let ixml = BroadcastWave.ixml(project: "CinemaHUD", scene: "12A", take: 3, tape: "0001", fileUID: "uid", fps: 24, trackNames: ["Input 1"])
        try BroadcastWave.finalize(url: url, bext: bext, ixml: ixml)

        let chunks = try BroadcastWave.chunks(url: url)
        XCTAssertTrue(chunks.contains { $0.id == "fmt " })
        XCTAssertTrue(chunks.contains { $0.id == "data" })
        XCTAssertTrue(chunks.contains { $0.id == "bext" })
        XCTAssertTrue(chunks.contains { $0.id == "iXML" })

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        let header = try Data(contentsOf: url)[4 ..< 8].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(UInt32(littleEndian: header)), size - 8, "RIFF size covers the new chunks")

        XCTAssertEqual(try BroadcastWave.readBext(url: url), bext)
        let back = try XCTUnwrap(BroadcastWave.readIXML(url: url))
        XCTAssertTrue(back.contains("<TAKE>3</TAKE>"))
        XCTAssertTrue(back.contains("<TAPE>0001</TAPE>"))
        XCTAssertTrue(back.contains("<NAME>Input 1</NAME>"))
        XCTAssertTrue(back.contains("<TIMECODE_RATE>24/1</TIMECODE_RATE>"))

        let reopened = try AVAudioFile(forReading: url)
        XCTAssertEqual(reopened.length, 48000)
    }

    func testTimeReferenceIsSamplesSinceMidnight() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 14, minute: 3, second: 20))!
        XCTAssertEqual(BroadcastWave.timeReference(for: date, sampleRate: 48000, calendar: cal), UInt64((14 * 3600 + 3 * 60 + 20) * Int(48000)))
    }

    func testFinalizeTwiceReplacesChunks() throws {
        let dir = try TestMedia.tempDir("bwf2")
        let url = dir.appendingPathComponent("x.wav")
        try TestMedia.writeWAV(url: url, seconds: 0.1)
        let b1 = BroadcastWave.Bext(description: "one", originator: "CinemaHUD", originatorReference: "", originationDate: "2026-09-15", originationTime: "00:00:00", timeReference: 1, codingHistory: "")
        var b2 = b1; b2.description = "two"; b2.timeReference = 2
        try BroadcastWave.finalize(url: url, bext: b1, ixml: "<BWFXML/>")
        try BroadcastWave.finalize(url: url, bext: b2, ixml: "<BWFXML><X/></BWFXML>")
        XCTAssertEqual(try BroadcastWave.chunks(url: url).filter { $0.id == "bext" }.count, 1)
        XCTAssertEqual(try BroadcastWave.readBext(url: url)?.description, "two")
    }

    func testTruncatedFileThrowsInsteadOfTrapping() throws {
        let dir = try TestMedia.tempDir("trunc")
        let url = dir.appendingPathComponent("t.wav")
        try TestMedia.writeWAV(url: url, seconds: 0.1)
        let bext = BroadcastWave.Bext(description: "t", originator: "CinemaHUD", originatorReference: "", originationDate: "2026-09-15", originationTime: "00:00:00", timeReference: 1, codingHistory: "")
        try BroadcastWave.finalize(url: url, bext: bext, ixml: "<BWFXML><PROJECT>x</PROJECT></BWFXML>")
        // Cut the tail off: iXML is the last chunk, so it becomes incomplete while bext stays whole.
        var data = try Data(contentsOf: url)
        data.removeLast(20)
        try data.write(to: url)
        XCTAssertEqual(try BroadcastWave.readBext(url: url)?.description, "t")
        XCTAssertThrowsError(try BroadcastWave.readIXML(url: url)) { error in
            guard case BroadcastWave.Error.truncated = error else { return XCTFail("expected .truncated, got \(error)") }
        }
    }
}
