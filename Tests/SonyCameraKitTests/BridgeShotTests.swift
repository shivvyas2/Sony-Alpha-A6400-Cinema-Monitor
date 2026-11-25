import XCTest
@testable import SonyCameraKit

final class BridgeShotTests: XCTestCase {
    private let port: UInt16 = 18933
    private func file(_ name: String, _ bytes: Int) throws -> CapturedImage {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data(repeating: 0xAB, count: bytes).write(to: u)
        return CapturedImage(url: u, kind: .jpeg, filename: name, takenAt: Date(), shotIndex: 1)
    }

    func testNewShotsReachTheClientOldOnesAndOtherPathsDoNot() async throws {
        let shelf = BridgeShotShelf()
        shelf.add(try file("OLD.JPG", 100))
        let st = BridgeState(state: CameraState(), settings: [], transport: .usb, cameraName: "a6400")
        let server = BridgeServer(name: "t", frames: Broadcaster<Data>(), states: Broadcaster<BridgeState>(), shots: shelf,
                                  state: { st }, handler: { _ in BridgeReply(ok: true) })
        try server.start(port: port); defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let client = BridgeBackend(baseURL: base)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        client.saveDirectory = dir
        _ = try await client.connect()
        let events = client.captureEvents()
        try await Task.sleep(for: .milliseconds(600))
        shelf.add(try file("../DSC0421.JPG", 3_000_000))

        let first = try await withThrowingTaskGroup(of: CaptureEvent?.self) { g in
            g.addTask { for await e in events { return e }; return nil }
            g.addTask { try await Task.sleep(for: .seconds(6)); return nil }
            let r = try await g.next()!; g.cancelAll(); return r
        }
        guard case .image(let img)? = first else { return XCTFail("no image: \(String(describing: first))") }
        XCTAssertEqual(img.filename, "DSC0421.JPG")                       // not the old shot, and no path tricks
        XCTAssertTrue(img.url.path.hasPrefix(dir.path))
        XCTAssertEqual(try Data(contentsOf: img.url).count, 3_000_000)

        for bad in ["shot/\(UUID().uuidString)", "shot/..%2f..%2fetc%2fpasswd"] {
            let (_, resp) = try await URLSession.shared.data(from: URL(string: base.absoluteString + "/" + bad)!)
            XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 404)
        }
        await client.disconnect()
    }

    @MainActor func testShotNumbersStayUniqueAcrossReconnects() {
        let e = CaptureEvent.image(CapturedImage(url: URL(fileURLWithPath: "/tmp/a.jpg"), kind: .jpeg, filename: "a.jpg", takenAt: Date(), shotIndex: 1))
        guard case .image(let moved) = e.offset(by: 7) else { return XCTFail() }
        XCTAssertEqual(moved.shotIndex, 8)
        XCTAssertEqual(CaptureEvent.failed(shotIndex: -1, message: "x").offset(by: 7), .failed(shotIndex: -1, message: "x"))
        XCTAssertEqual(CaptureEvent.finished(shotIndex: 1).offset(by: 7), .finished(shotIndex: 8))
    }
}

final class WiFiShotClaimTests: XCTestCase {
    func testShotFromBeforeTheConnectionIsNotNew() {
        let b = WiFiBackend(camera: DiscoveredCamera(friendlyName: "c", modelName: "", serviceURL: URL(string: "http://127.0.0.1:9/sony")!))
        let old = URL(string: "http://c/old.jpg")!, new = URL(string: "http://c/new.jpg")!
        b.ignore([old])
        XCTAssertNil(b.claim([old]))
        XCTAssertEqual(b.claim([old, new])?.urls, [new])
        XCTAssertNil(b.claim([new]))
    }
}
