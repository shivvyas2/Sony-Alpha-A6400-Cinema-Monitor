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

    func testConfirmTimeoutKeepsTheTakeWhenTheCameraIsRolling() {
        // Driving the real 5 s confirm timer end-to-end would need `recorder.isRecording` to actually be
        // true, which needs `AudioSessionController.arm()` to succeed against live, permitted CoreAudio
        // hardware — every other test in this file (and AudioInputTests) avoids that for the same reason.
        // `confirmOutcome` is the pure decision `runConfirmCheckForTesting()`'s timer body switches on, so
        // it's tested directly here instead: a late `.started` (camera still rolling) keeps the take,
        // and the no-signal / already-stopped cases behave like the old unconditional abort.
        XCTAssertEqual(AudioSessionController.confirmOutcome(cameraIsRecording: true), .lateStart, "camera is rolling: treat the missed milestone as late, keep the take")
        XCTAssertEqual(AudioSessionController.confirmOutcome(cameraIsRecording: false), .neverStarted)
        XCTAssertEqual(AudioSessionController.confirmOutcome(cameraIsRecording: nil), .neverStarted, "isCameraRecording not wired up: keeps the old behaviour (abort)")
    }

    @MainActor func testConfirmCheckHookIsSafeWhenNothingIsRecording() throws {
        // `runConfirmCheckForTesting()` (the hook finding 5 asks for) must be a safe no-op outside a take,
        // exactly like the real timer's guard.
        let suite = "AudioSessionControllerTests-confirm-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let c = AudioSessionController(base: FileManager.default.temporaryDirectory.appendingPathComponent(suite), defaults: defaults)
        c.isCameraRecording = { true }
        c.runConfirmCheckForTesting()
        XCTAssertNil(c.currentTake)
        XCTAssertNil(c.interruption)
    }

    @MainActor func testDeviceRemovalArmsReturnGateOnlyForThatDevice() async throws {
        let suite = "AudioSessionControllerTests-rearm-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("uid-scarlett", forKey: "audio.deviceUID")
        let c = AudioSessionController(base: FileManager.default.temporaryDirectory.appendingPathComponent(suite), defaults: defaults)
        XCTAssertEqual(c.selectedDeviceUID, "uid-scarlett")
        let scarlett = AudioDevice(id: 0xFFFF_FFF1, uid: "uid-scarlett", name: "Scarlett 2i2 USB", inputChannelNames: ["1", "2"], nominalSampleRate: 48000, supportedSampleRates: [48000])
        let other = AudioDevice(id: 0xFFFF_FFF2, uid: "uid-other", name: "Other", inputChannelNames: ["1"], nominalSampleRate: 48000, supportedSampleRates: [48000])

        c.simulateInterruption(.deviceRemoved)          // gate opens for uid-scarlett
        c.simulateDevicesChanged([other])               // a different device returning must not trigger an arm attempt
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(c.armError, "no arm attempt for another device")

        c.simulateDevicesChanged([scarlett])            // the awaited device returns → arm attempt (fails: bogus id, no permission)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(c.armError, "Device not connected", "refreshDevices() replaces the fake list with the real HAL list before the lookup, so the fake uid is not found")
        XCTAssertFalse(c.isArmed)

        c.simulateInterruption(.configurationChanged)   // clears the gate
        let firstError = c.armError
        c.simulateDevicesChanged([scarlett])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(c.armError, firstError, "gate closed: no second attempt")
    }
}
#endif
