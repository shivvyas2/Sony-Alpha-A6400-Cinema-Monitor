import XCTest
import CoreGraphics
@testable import CinemaUI
@testable import SonyCameraKit

@MainActor
final class AssistControllerTests: XCTestCase {
    private func state() -> CameraState {
        var s = CameraState(); s.exposureMode = "Manual"; s.iso = "800"; s.isoCandidates = ["400", "800", "1600"]
        s.availableAPIs = ["setIsoSpeedRate", "setTouchAFPosition"]; return s
    }
    private func under() -> SceneMeasurements {
        var m = SceneMeasurements(); m.faces = [.init(rect: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3), luma: 27.5, sharpness: 100)]
        m.sharpestScore = 100; m.sharpestRegion = CGPoint(x: 0.5, y: 0.35); return m
    }

    func testLinesAppearAfterTwoPassesAndCarryTheFix() {
        let c = AssistController(useModel: false)
        c.ingest(measurements: under(), state: state(), profile: .standard, projectFPS: 24, shootingMode: .video)
        XCTAssertTrue(c.lines.isEmpty)
        c.ingest(measurements: under(), state: state(), profile: .standard, projectFPS: 24, shootingMode: .video)
        XCTAssertEqual(c.lines.map(\.text), ["FACE 1 STOP UNDER"])
        XCTAssertEqual(c.fix(for: "face-under"), Fix(label: "EI 800 → 1600", command: .setISO("1600")))
        XCTAssertTrue(c.visible)
    }
    func testPendingAFTracksAFocusFixAndClearsWhenTheFindingGoes() {
        let c = AssistController(useModel: false)
        var m = under(); m.faces[0].luma = 55; m.faces[0].sharpness = 10; m.sharpestRegion = CGPoint(x: 0.9, y: 0.9)
        for _ in 0 ..< 2 { c.ingest(measurements: m, state: state(), profile: .standard, projectFPS: 24, shootingMode: .video) }
        XCTAssertEqual(c.pendingAF, CGPoint(x: 0.5, y: 0.35))
        for _ in 0 ..< 2 { c.ingest(measurements: SceneMeasurements(), state: state(), profile: .standard, projectFPS: 24, shootingMode: .video) }
        XCTAssertNil(c.pendingAF)
        XCTAssertTrue(c.lines.isEmpty)
    }
    func testDisplayToSensorUndoesTheDisplayRotation() {
        let p = CGPoint(x: 0.2, y: 0.7)
        func near(_ a: CGPoint, _ b: CGPoint, line: UInt = #line) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9, line: line); XCTAssertEqual(a.y, b.y, accuracy: 1e-9, line: line)
        }
        near(AssistController.sensorPoint(p, rotation: 0), p)
        near(AssistController.sensorPoint(p, rotation: 90), CGPoint(x: 0.7, y: 0.8))
        near(AssistController.sensorPoint(p, rotation: 270), CGPoint(x: 0.3, y: 0.2))
        near(AssistController.sensorPoint(p, rotation: 180), CGPoint(x: 0.8, y: 0.3))
        for r in [0, 90, 180, 270] {
            let back = AssistController.displayPoint(AssistController.sensorPoint(p, rotation: r), rotation: r)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-9); XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        }
    }
}
