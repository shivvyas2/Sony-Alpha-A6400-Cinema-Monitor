#if os(macOS)
import XCTest
import CinemaAudio
@testable import SonyCameraKit
@testable import CinemaUI

final class AudioSessionControllerTests: XCTestCase {
    func testLabelUsesNextTakeOnPressAndCurrentTakeOnStart() {
        let t = Date()
        XCTAssertEqual(AudioSessionController.label(for: .pressed(t), takes: 2, cameraIndex: "A", reel: 1).fileStem, "A_0001_C003")
        XCTAssertEqual(AudioSessionController.label(for: .started(t), takes: 3, cameraIndex: "A", reel: 1).fileStem, "A_0001_C003")
        XCTAssertEqual(AudioSessionController.label(for: .stopped(t), takes: 3, cameraIndex: "B", reel: 7).fileStem, "B_0007_C003")
        XCTAssertEqual(AudioSessionController.label(for: .started(t), takes: 0, cameraIndex: "A", reel: 1).clip, 1, "never below 1")
    }

    func testMetadataSnapshot() {
        var s = CameraState()
        s.shutterSpeed = "1/50"; s.fNumber = "2.8"; s.iso = "800"; s.focusMode = "MF"; s.exposureMode = "Manual"; s.whiteBalanceMode = "Daylight"
        let m = AudioSessionController.metadata(state: s, projectFPS: 25, scene: "12A", note: "wide")
        XCTAssertEqual(m.project, "CinemaHUD")
        XCTAssertEqual(m.projectFPS, 25)
        XCTAssertEqual(m.scene, "12A")
        XCTAssertEqual(m.note, "wide")
        XCTAssertEqual(m.camera, ["shutter": "1/50", "iris": "2.8", "iso": "800", "focus": "MF", "mode": "Manual", "wb": "Daylight"])
        XCTAssertNil(AudioSessionController.metadata(state: CameraState(), projectFPS: 24, scene: "", note: "").scene, "empty scene is nil")
    }

    @MainActor func testPersistsChoicesAndIgnoresEventsWhenDisarmed() throws {
        let suite = "AudioSessionControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let c = AudioSessionController(base: base, defaults: defaults)
        XCTAssertFalse(c.isArmed)
        c.sendTimecode = true; c.scene = "5"; c.note = "n"
        c.handle(.pressed(Date()), label: TakeLabel(cameraIndex: "A", reel: 1, clip: 1), metadata: TakeMetadata(project: "CinemaHUD", projectFPS: 24, scene: nil, note: nil, camera: [:]))
        XCTAssertNil(c.currentTake)
        let again = AudioSessionController(base: base, defaults: defaults)
        XCTAssertTrue(again.sendTimecode)
        XCTAssertEqual(again.scene, "5")
        XCTAssertEqual(again.dayFolder.lastPathComponent, DayFolder.dayString(Date()))
    }
}
#endif
