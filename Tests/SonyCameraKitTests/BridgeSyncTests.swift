import XCTest
@testable import SonyCameraKit

/// Every photo the Mac has this session also ends up on the phone, through drops, late joins and relaunches.
final class BridgeSyncTests: XCTestCase {
    private var dirs: [URL] = []
    private let state = BridgeState(state: CameraState(), settings: [], transport: .usb, cameraName: "a6400")

    private func shot(_ name: String, _ index: Int) throws -> CapturedImage {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data(repeating: 1, count: 50_000).write(to: u)
        return CapturedImage(url: u, kind: .jpeg, filename: name, takenAt: Date(), shotIndex: index)
    }
    private func server(_ port: UInt16, _ shelf: BridgeShotShelf?) throws -> BridgeServer {
        let s = BridgeServer(name: "t", frames: Broadcaster<Data>(), states: Broadcaster<BridgeState>(), shots: shelf, state: { [state] in state }, handler: { _ in BridgeReply(ok: true) })
        try s.start(port: port); return s
    }
    private func client(_ port: UInt16, _ defaults: UserDefaults) -> BridgeBackend {
        let c = BridgeBackend(baseURL: URL(string: "http://127.0.0.1:\(port)")!, defaults: defaults)
        c.saveDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return c
    }
    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "bridge-\(UUID().uuidString)")! }

    private actor Inbox {
        var images: [CapturedImage] = []; var failures: [String] = []
        func add(_ e: CaptureEvent) {
            if case .image(let i) = e { images.append(i) }
            if case .failed(_, let m) = e { failures.append(m) }
        }
        var names: [String] { images.map(\.filename) }
    }
    private func collect(_ c: BridgeBackend) -> Inbox {
        let box = Inbox(), events = c.captureEvents()
        Task { for await e in events { await box.add(e) } }
        return box
    }
    private func eventually(_ seconds: Double = 8, _ check: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await check() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return await check()
    }

    func testLateJoinGetsEarlierShotsMarkedAsCatchUpAndNewOnesNot() async throws {
        let shelf = BridgeShotShelf(); shelf.add(try shot("A.JPG", 1)); shelf.add(try shot("B.JPG", 2))
        let s = try server(18941, shelf); defer { s.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let c = client(18941, freshDefaults()); _ = try await c.connect()
        let box = collect(c)
        let early = await eventually { await box.names == ["A.JPG", "B.JPG"] }
        XCTAssertTrue(early)
        shelf.add(try shot("C.JPG", 3))
        let late = await eventually { await box.names.contains("C.JPG") }
        XCTAssertTrue(late)
        let flags = await box.images.map(\.catchUp)
        XCTAssertEqual(flags, [true, true, false])
        await c.disconnect()
    }

    func testReconnectOnTheSameBackendKeepsDelivering() async throws {
        let shelf = BridgeShotShelf()
        let s = try server(18942, shelf); defer { s.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let c = client(18942, freshDefaults()); _ = try await c.connect()
        let box = collect(c)
        try await Task.sleep(for: .milliseconds(400))
        await c.disconnect()                          // what CameraSession.reconnect does
        shelf.add(try shot("WHILE_AWAY.JPG", 1))
        _ = try await c.connect()
        shelf.add(try shot("AFTER.JPG", 2))
        let ok = await eventually { Set(await box.names) == ["WHILE_AWAY.JPG", "AFTER.JPG"] }
        XCTAssertTrue(ok)
        await c.disconnect()
    }

    func testRelaunchDoesNotFetchTheSamePhotoTwice() async throws {
        let shelf = BridgeShotShelf(); shelf.add(try shot("A.JPG", 1))
        let s = try server(18943, shelf); defer { s.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let d = freshDefaults()
        let first = client(18943, d); _ = try await first.connect(); let box1 = collect(first)
        let got = await eventually { await box1.names == ["A.JPG"] }
        XCTAssertTrue(got)
        await first.disconnect()
        let second = client(18943, d); _ = try await second.connect(); let box2 = collect(second)
        try await Task.sleep(for: .milliseconds(800))
        shelf.add(try shot("B.JPG", 2))
        _ = await eventually { await box2.names.contains("B.JPG") }
        let names = await box2.names
        XCTAssertEqual(names, ["B.JPG"])
        await second.disconnect()
    }

    func testFailedDownloadIsTriedAgainOnTheNextConnection() async throws {
        let shelf = BridgeShotShelf(); let img = try shot("A.JPG", 1)
        let data = try Data(contentsOf: img.url); try FileManager.default.removeItem(at: img.url)   // 404 at first
        shelf.add(img)
        let s = try server(18944, shelf); defer { s.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let c = client(18944, freshDefaults()); _ = try await c.connect(); let box = collect(c)
        let failed = await eventually { await !box.failures.isEmpty }
        XCTAssertTrue(failed)
        try data.write(to: img.url)
        await c.disconnect(); _ = try await c.connect()
        let ok = await eventually { await box.names == ["A.JPG"] }
        XCTAssertTrue(ok)
        await c.disconnect()
    }

    func testOldMacAppIsNamedOnce() async throws {
        let s = try server(18945, nil); defer { s.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let c = client(18945, freshDefaults()); _ = try await c.connect(); let box = collect(c)
        let told = await eventually { await box.failures.contains { $0.contains("Update CinemaHUD on the Mac") } }
        XCTAssertTrue(told)
        try await Task.sleep(for: .seconds(3))
        let n = await box.failures.count
        XCTAssertEqual(n, 1)
        await c.disconnect()
    }

    @MainActor func testCatchUpShotsDoNotTakeOverTheScreen() throws {
        let session = CameraSession()
        var old = try shot("OLD.JPG", 1); old.catchUp = true
        session.handle(.image(old))
        XCTAssertNil(session.reviewShot); XCTAssertEqual(session.captures.count, 1)
        XCTAssertEqual(session.captures[0].exposure.summary, "")     // today's settings say nothing about it
        session.handle(.image(try shot("NEW.JPG", 2)))
        XCTAssertEqual(session.reviewShot?.jpeg?.filename, "NEW.JPG")
    }
}
