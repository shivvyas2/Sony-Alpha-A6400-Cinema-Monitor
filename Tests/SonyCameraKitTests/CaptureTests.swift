import XCTest
@testable import SonyCameraKit

final class CaptureTests: XCTestCase {
    func testKindFromObjectFormatAndName() {
        XCTAssertEqual(CapturedImage.kind(objectFormat: 0x3801, filename: "DSC00001.JPG"), .jpeg)
        XCTAssertEqual(CapturedImage.kind(objectFormat: 0xB101, filename: "DSC00001.ARW"), .raw)
        XCTAssertEqual(CapturedImage.kind(objectFormat: 0x3000, filename: "x.jpeg"), .jpeg)
        XCTAssertEqual(CapturedImage.kind(objectFormat: 0x3000, filename: "x"), .raw)
    }

    func testStoreWritesIntoDatedFolderAndNeverOverwrites() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))!
        let a = try CaptureStore.write(Data([1]), base: tmp, filename: "DSC00001.ARW", date: date)
        let b = try CaptureStore.write(Data([2]), base: tmp, filename: "DSC00001.ARW", date: date)
        XCTAssertEqual(a.deletingLastPathComponent().lastPathComponent, "2026-09-15")
        XCTAssertEqual(a.lastPathComponent, "DSC00001.ARW")
        XCTAssertEqual(b.lastPathComponent, "DSC00001-2.ARW")
        XCTAssertEqual(try Data(contentsOf: a), Data([1]))
        XCTAssertEqual(try Data(contentsOf: b), Data([2]))
    }

    func testPostviewFilenameFromURL() {
        XCTAssertEqual(WiFiBackend.postviewFilename(for: URL(string: "http://192.168.122.1:8080/postview/pict20260915_120301.JPG?x=1")!, shot: 3), "pict20260915_120301.JPG")
        XCTAssertEqual(WiFiBackend.postviewFilename(for: URL(string: "http://192.168.122.1:8080/")!, shot: 3), "capture-3.jpg")
    }

    func testBroadcasterDeliversToEveryListener() async {
        let b = CaptureBroadcaster()
        let s1 = b.stream(), s2 = b.stream()
        b.send(.finished(shotIndex: 7))
        var i1 = s1.makeAsyncIterator(), i2 = s2.makeAsyncIterator()
        let e1 = await i1.next(), e2 = await i2.next()
        XCTAssertEqual(e1, .finished(shotIndex: 7))
        XCTAssertEqual(e2, .finished(shotIndex: 7))
    }
}
