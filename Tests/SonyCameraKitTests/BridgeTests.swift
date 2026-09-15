import XCTest
@testable import SonyCameraKit

final class BridgeTests: XCTestCase {
    func testBridgeStateCarriesFormatAndZoom() throws {
        var st = CameraState()
        st.stillSize = StillSize(aspect: "3:2", size: "L")
        st.stillSizeCandidates = [StillSize(aspect: "3:2", size: "L"), StillSize(aspect: "16:9", size: "M")]
        st.movieQuality = "PS"; st.movieQualityCandidates = ["PS", "HQ"]
        st.movieFileFormat = "XAVC S"; st.movieFileFormatCandidates = ["MP4", "XAVC S"]
        st.zoomPosition = 42
        let b = BridgeState(state: st, settings: [], transport: .usb, cameraName: "a6400")
        let data = try JSONEncoder().encode(b)
        let back = try JSONDecoder().decode(BridgeState.self, from: data).cameraState
        XCTAssertEqual(back.stillSize, st.stillSize)
        XCTAssertEqual(back.stillSizeCandidates, st.stillSizeCandidates)
        XCTAssertEqual(back.movieQuality, "PS"); XCTAssertEqual(back.movieQualityCandidates, ["PS", "HQ"])
        XCTAssertEqual(back.movieFileFormat, "XAVC S"); XCTAssertEqual(back.movieFileFormatCandidates, ["MP4", "XAVC S"])
        XCTAssertEqual(back.zoomPosition, 42)
    }

    func testStateCommandAndStreamRoundTrip() async throws {
        let frames = Broadcaster<Data>()
        let states = Broadcaster<BridgeState>()
        var st = CameraState(); st.shutterSpeed = "1/50"; st.iso = "800"; st.cameraStatus = "IDLE"
        let bridgeState = BridgeState(state: st, settings: [CameraSetting(id: "0x5013", name: "Drive", group: "Shooting", current: "Single", candidates: ["Single"], settable: true)],
                                      transport: .usb, cameraName: "ILCE-6400")
        let received = Broadcaster<BridgeCommand>()
        let server = BridgeServer(name: "test", frames: frames, states: states, state: { bridgeState },
                                  handler: { cmd in received.send(cmd); return BridgeReply(ok: true) })
        try server.start(port: 18899)
        try await Task.sleep(for: .milliseconds(300))

        let client = BridgeBackend(baseURL: URL(string: "http://127.0.0.1:18899")!)
        let s = try await client.connect()
        XCTAssertEqual(s.shutterSpeed, "1/50")
        XCTAssertEqual(s.iso, "800")
        let settingName = await client.settings().first?.name
        XCTAssertEqual(settingName, "Drive")
        XCTAssertEqual(client.bridgedTransport, "USB")

        // command
        let cmdStream = received.stream()
        try await client.setISO("1600")
        var it = cmdStream.makeAsyncIterator()
        let got = await it.next()
        XCTAssertEqual(got?.op, "setISO"); XCTAssertEqual(got?.value, "1600")

        // stream: subscribe, then publish three frames
        let jpeg = Data([0xFF, 0xD8]) + Data(repeating: 0x11, count: 30_000) + Data([0xFF, 0xD9])
        let collected = Task { () -> [Data] in
            var out: [Data] = []
            for try await f in client.liveviewFrames() { out.append(f); if out.count == 3 { break } }
            return out
        }
        try await Task.sleep(for: .milliseconds(500))
        for _ in 0 ..< 3 { frames.send(jpeg); try await Task.sleep(for: .milliseconds(50)) }
        let result = try await withTimeout(seconds: 5) { try await collected.value }
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.first, jpeg)

        // events
        // The event feed replays the current state first, then pushes changes.
        let events = Task { () -> String? in
            for try await s in client.stateUpdates() where s.iso == "3200" { return s.iso }
            return nil
        }
        try await Task.sleep(for: .milliseconds(300))
        var st2 = st; st2.iso = "3200"
        states.send(BridgeState(state: st2, settings: [], transport: .usb, cameraName: "ILCE-6400"))
        let iso = try await withTimeout(seconds: 5) { try await events.value }
        XCTAssertEqual(iso, "3200")
        server.stop()
    }

    private func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask { try await Task.sleep(for: .seconds(seconds)); throw URLError(.timedOut) }
            let r = try await g.next()!
            g.cancelAll()
            return r
        }
    }
}
