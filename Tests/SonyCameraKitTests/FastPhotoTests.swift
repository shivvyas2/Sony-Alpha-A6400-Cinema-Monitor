import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SonyCameraKit

/// A photo shows up on the phone as early as it can: before its RAW, before its full size, before older photos.
final class FastPhotoTests: XCTestCase {
    // MARK: USB

    func testJPEGIsHandedOverBeforeTheRAWIsFetched() async throws {
        let log = Log()
        let counts = Counter([2, 1, 0]); let queue = Counter(["A.JPG", "A.ARW"])
        let dl = CaptureDownloader(
            pending: { counts.next() ?? 0 },
            fetchNext: {
                guard let n = queue.next() else { throw CaptureDownloader.QueueEmpty() }
                log.add("fetch \(n)")
                var d = Data(repeating: 0, count: 52); let u = Array(n.utf16) + [0]
                d.append(UInt8(u.count)); for c in u { d.append(le16: c) }
                return (d, Data([1]))
            },
            pollInterval: .milliseconds(1), timeout: .seconds(1))
        let n = try await dl.run { log.add("got \($0.filename)") }
        XCTAssertEqual(n, 2)
        XCTAssertEqual(log.all, ["fetch A.JPG", "got A.JPG", "fetch A.ARW", "got A.ARW"])
    }

    // MARK: Bridge

    private func jpeg(_ name: String, _ index: Int, w: Int = 3000, h: Int = 2000, orientation: Int = 1) throws -> CapturedImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for i in 0 ..< 400 { ctx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1)); ctx.fill(CGRect(x: i * 37 % w, y: i * 91 % h, width: 60, height: 60)) }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        let dst = CGImageDestinationCreateWithURL(u as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
        return CapturedImage(url: u, kind: .jpeg, filename: name, takenAt: Date(), shotIndex: index)
    }
    private func server(_ port: UInt16, _ shelf: BridgeShotShelf, frames: Broadcaster<Data> = Broadcaster<Data>()) throws -> BridgeServer {
        let st = BridgeState(state: CameraState(), settings: [], transport: .usb, cameraName: "a6400")
        let s = BridgeServer(name: "t", frames: frames, states: Broadcaster<BridgeState>(), shots: shelf, state: { st }, handler: { _ in BridgeReply(ok: true) })
        try s.start(port: port); return s
    }
    private func client(_ port: UInt16) -> BridgeBackend {
        let c = BridgeBackend(baseURL: URL(string: "http://127.0.0.1:\(port)")!, defaults: UserDefaults(suiteName: "fast-\(UUID().uuidString)")!)
        c.saveDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return c
    }
    private func eventually(_ seconds: Double = 8, _ check: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await check() { return true }; try? await Task.sleep(for: .milliseconds(30)) }
        return await check()
    }

    func testPreviewIsSmallAndKeepsTheOrientation() throws {
        let img = try jpeg("A.JPG", 1, orientation: 6)
        let data = try XCTUnwrap(BridgePreview.jpeg(for: img.url))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertEqual(p?[kCGImagePropertyPixelWidth] as? Int, 2048)
        XCTAssertEqual(p?[kCGImagePropertyPixelHeight] as? Int, 1365)
        XCTAssertEqual(p?[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertNil(BridgePreview.jpeg(for: URL(fileURLWithPath: "/nope.jpg")))
    }

    func testNewShotSendsAPreviewThenTheFullFile() async throws {
        let shelf = BridgeShotShelf(); let s = try server(18951, shelf); defer { s.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let c = client(18951); _ = try await c.connect()
        let box = Box(), events = c.captureEvents(); Task { for await e in events { box.add(e) } }
        try await Task.sleep(for: .milliseconds(400))
        let img = try jpeg("A.JPG", 1); shelf.add(img)
        let ok = await eventually { box.images.count == 2 }
        XCTAssertTrue(ok)
        XCTAssertEqual(box.images.map(\.isPreview), [true, false])
        XCTAssertEqual(Set(box.images.map(\.id)), [img.id])
        XCTAssertEqual(try Data(contentsOf: box.images[1].url), try Data(contentsOf: img.url))
        await c.disconnect()
    }

    func testOlderPhotosComeWithoutAPreview() async throws {
        let shelf = BridgeShotShelf(); shelf.add(try jpeg("OLD.JPG", 1))
        let s = try server(18952, shelf); defer { s.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let c = client(18952); _ = try await c.connect()
        let box = Box(), events = c.captureEvents(); Task { for await e in events { box.add(e) } }
        _ = await eventually { !box.images.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(box.images.map(\.isPreview), [false])
        await c.disconnect()
    }

    func testNewShotOvertakesOlderPhotos() {
        var q = BridgeFetchQueue()
        func shot(_ n: Int, replay: Bool) -> BridgeShot { BridgeShot(id: UUID(), filename: "\(n)", takenAt: Date(), shotIndex: n, replay: replay) }
        let a = shot(1, replay: true), b = shot(2, replay: true), new = shot(3, replay: false), newer = shot(4, replay: false)
        XCTAssertTrue(q.add(a)); XCTAssertTrue(q.add(b)); XCTAssertTrue(q.add(new)); XCTAssertTrue(q.add(newer))
        XCTAssertFalse(q.add(a))                                  // already waiting
        XCTAssertEqual([q.next(), q.next(), q.next(), q.next()].compactMap { $0?.shotIndex }, [3, 4, 1, 2])
        XCTAssertNil(q.next())
        XCTAssertFalse(q.add(a))                                  // still being fetched
        q.done(a.id); XCTAssertTrue(q.add(a))
    }

    /// A phone that cannot keep up gets fewer frames, not older ones.
    func testLiveViewDoesNotQueueUpForASlowPhone() async throws {
        let frames = Broadcaster<Data>(); let s = try server(18953, BridgeShotShelf(), frames: frames); defer { s.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let fd = try rawConnection(18953, "GET /stream HTTP/1.1\r\nHost: x\r\n\r\n"); defer { close(fd) }
        try await Task.sleep(for: .milliseconds(200))
        for i in 0 ..< 400 {                                       // 40 MB nobody reads yet
            frames.send(Data(String(format: "FRAME%04d", i).utf8) + Data(repeating: 0, count: 100_000))
            try await Task.sleep(for: .milliseconds(2))
        }
        var seen = 0, buf = [UInt8](repeating: 0, count: 1 << 16), total = 0
        var tv = timeval(tv_sec: 1, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; total += n }
        seen = total / 100_000
        XCTAssertGreaterThan(seen, 0)
        XCTAssertLessThan(seen, 100)
    }

    private func rawConnection(_ port: UInt16, _ text: String) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { throw URLError(.cannotConnectToHost) }
        _ = text.withCString { send(fd, $0, strlen($0), 0) }
        return fd
    }

    // MARK: Session

    func testFullFileReplacesThePreviewEvenAfterAReconnect() {
        let id = UUID(); let exp = ExposureSnapshot(state: CameraState())
        func image(_ shot: Int, preview: Bool) -> CapturedImage {
            CapturedImage(url: URL(fileURLWithPath: preview ? "/tmp/p.jpg" : "/tmp/f.jpg"), kind: .jpeg, filename: "A.JPG", takenAt: Date(), shotIndex: shot, id: id, isPreview: preview)
        }
        var log = ShotLog()
        _ = log.apply(.image(image(1, preview: true)), exposure: exp, afPoint: nil)
        XCTAssertTrue(log.shots[0].transferring)
        _ = log.apply(.failed(shotIndex: 1, message: "dropped"), exposure: exp, afPoint: nil)
        _ = log.apply(.image(image(9, preview: false)), exposure: exp, afPoint: nil)     // new numbering after a reconnect
        XCTAssertEqual(log.shots.count, 1)
        XCTAssertEqual(log.shots[0].jpeg?.isPreview, false)
        XCTAssertFalse(log.shots[0].transferring); XCTAssertNil(log.shots[0].error)
        // A preview that loses the race never replaces the real file.
        _ = log.apply(.image(image(1, preview: true)), exposure: exp, afPoint: nil)
        XCTAssertEqual(log.shots[0].jpeg?.isPreview, false)
        guard case .image(let m) = CaptureEvent.image(image(1, preview: true)).offset(by: 3) else { return XCTFail() }
        XCTAssertTrue(m.isPreview)
    }

    private final class Log: @unchecked Sendable {
        private let l = NSLock(); private var v: [String] = []
        func add(_ s: String) { l.withLock { v.append(s) } }
        var all: [String] { l.withLock { v } }
    }
    private final class Box: @unchecked Sendable {
        private let l = NSLock(); private var v: [CapturedImage] = []
        func add(_ e: CaptureEvent) { if case .image(let i) = e { l.withLock { v.append(i) } } }
        var images: [CapturedImage] { l.withLock { v } }
    }
}
