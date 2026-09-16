// Tests/CinemaAudioTests/TakeLogTests.swift
import XCTest
@testable import CinemaAudio

final class TakeLogTests: XCTestCase {
    func record(_ stem: String, clip: Int = 3) -> TakeRecord {
        TakeRecord(id: stem, label: TakeLabel(cameraIndex: "A", reel: 1, clip: clip), wavPath: "audio/\(stem).wav",
                   pressedAt: Date(timeIntervalSince1970: 1_800_000_000), confirmedStart: Date(timeIntervalSince1970: 1_800_000_000.4),
                   confirmedStop: nil, prerollSeconds: 3, sampleRate: 48000, channelNames: ["Input 1", "Input 2"],
                   metadata: TakeMetadata(project: "CinemaHUD", projectFPS: 24, scene: "12A", note: nil, camera: ["iso": "800"]),
                   outcome: .recording)
    }

    func testLabelFileStem() {
        XCTAssertEqual(TakeLabel(cameraIndex: "A", reel: 1, clip: 3).fileStem, "A_0001_C003")
        XCTAssertEqual(TakeLabel(cameraIndex: "B", reel: 12, clip: 120).fileStem, "B_0012_C120")
    }

    func testRoundTripAndUpsert() throws {
        let dir = try TestMedia.tempDir("takelog")
        var log = TakeLog()
        log.upsert(record("A_0001_C003"))
        var r = record("A_0001_C003"); r.outcome = .interrupted("device removed"); r.confirmedStop = Date(timeIntervalSince1970: 1_800_000_010)
        log.upsert(r)
        XCTAssertEqual(log.takes.count, 1)
        try log.save(to: dir)
        let back = TakeLog.load(from: dir)
        XCTAssertEqual(back, log)
        XCTAssertEqual(back.takes[0].outcome, .interrupted("device removed"))
        XCTAssertEqual(back.takes[0].firstSampleDate, Date(timeIntervalSince1970: 1_800_000_000 - 3))
    }

    func testLoadMissingIsEmpty() throws {
        XCTAssertEqual(TakeLog.load(from: try TestMedia.tempDir("empty")).takes, [])
    }

    func testDayFolderAndUniqueNames() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))!
        XCTAssertEqual(DayFolder.dayString(date, calendar: cal), "2026-09-15")
        let base = try TestMedia.tempDir("base")
        XCTAssertEqual(DayFolder.url(for: date, base: base, calendar: cal).lastPathComponent, "2026-09-15")
        let audio = base.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        XCTAssertEqual(DayFolder.uniqueWAVName(stem: "A_0001_C003", in: audio), "A_0001_C003.wav")
        FileManager.default.createFile(atPath: audio.appendingPathComponent("A_0001_C003.wav").path, contents: Data())
        XCTAssertEqual(DayFolder.uniqueWAVName(stem: "A_0001_C003", in: audio), "A_0001_C003_2.wav")
        FileManager.default.createFile(atPath: audio.appendingPathComponent("A_0001_C003_2.wav").path, contents: Data())
        XCTAssertEqual(DayFolder.uniqueWAVName(stem: "A_0001_C003", in: audio), "A_0001_C003_3.wav")
    }
}
