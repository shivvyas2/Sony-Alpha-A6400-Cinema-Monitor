import XCTest
@testable import SonyCameraKit

final class CaptureDownloaderTests: XCTestCase {
    /// PTP ObjectInfo: 52 bytes of fixed fields (ObjectFormat at byte 4) then a PTP string (u8 count incl. terminator, UTF-16LE).
    private func objectInfo(format: UInt16, name: String) -> Data {
        var d = Data(repeating: 0, count: 52)
        d[4] = UInt8(format & 0xFF); d[5] = UInt8(format >> 8)
        let units = Array(name.utf16) + [0]
        d.append(UInt8(units.count))
        for u in units { d.append(le16: u) }
        return d
    }

    func testParsesFormatAndFilename() {
        let (f, n) = CaptureDownloader.parseObjectInfo(objectInfo(format: 0xB101, name: "DSC00042.ARW"))
        XCTAssertEqual(f, 0xB101); XCTAssertEqual(n, "DSC00042.ARW")
        XCTAssertEqual(CaptureDownloader.parseObjectInfo(Data([1, 2, 3])).filename, "")
    }

    func testPendingCountFromObjectInMemory() {
        XCTAssertEqual(SonyUSBBackend.pendingCount(nil), 0)
        XCTAssertEqual(SonyUSBBackend.pendingCount(1), 0)
        XCTAssertEqual(SonyUSBBackend.pendingCount(0x8000), 1)
        XCTAssertEqual(SonyUSBBackend.pendingCount(0x8002), 2)
    }

    func testDrainsRawPlusJpegAfterWaiting() async throws {
        let counts = Counter([0, 0, 2, 1, 0])
        let queue = Counter([(0x3801, "DSC00001.JPG", Data([0xFF, 0xD8])), (0xB101, "DSC00001.ARW", Data([0x49, 0x49]))])
        let dl = CaptureDownloader(
            pending: { counts.next() ?? 0 },
            fetchNext: {
                guard let (f, n, d) = queue.next() else { throw CaptureDownloader.QueueEmpty() }
                return (self.objectInfo(format: UInt16(f), name: n), d)
            },
            pollInterval: .milliseconds(1), timeout: .seconds(1))
        let out = try await dl.run()
        XCTAssertEqual(out.map(\.filename), ["DSC00001.JPG", "DSC00001.ARW"])
        XCTAssertEqual(out.map(\.format), [0x3801, 0xB101])
        XCTAssertEqual(out[1].data, Data([0x49, 0x49]))
    }

    func testGivesUpWhenNothingArrives() async throws {
        let dl = CaptureDownloader(pending: { 0 }, fetchNext: { throw CaptureDownloader.QueueEmpty() },
                                   pollInterval: .milliseconds(1), timeout: .milliseconds(20))
        let out = try await dl.run()
        XCTAssertTrue(out.isEmpty)
    }

    func testStopsOnQueueEmptyEvenIfCountStaysHigh() async throws {
        let queue = Counter([(0x3801, "A.JPG", Data([1]))])
        let dl = CaptureDownloader(
            pending: { 1 },
            fetchNext: {
                guard let (f, n, d) = queue.next() else { throw CaptureDownloader.QueueEmpty() }
                return (self.objectInfo(format: UInt16(f), name: n), d)
            },
            pollInterval: .milliseconds(1), timeout: .milliseconds(20))
        let out = try await dl.run()
        XCTAssertEqual(out.map(\.filename), ["A.JPG"])
    }
}

/// Thread-safe sequence for closure-driven fakes.
final class Counter<T>: @unchecked Sendable {
    private var items: [T]; private let lock = NSLock()
    init(_ items: [T]) { self.items = items }
    func next() -> T? { lock.lock(); defer { lock.unlock() }; return items.isEmpty ? nil : items.removeFirst() }
}
