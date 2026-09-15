import XCTest
import CoreGraphics
@testable import CinemaUI
@testable import SonyCameraKit

final class AssistRulesTests: XCTestCase {
    private func manualState() -> CameraState {
        var s = CameraState()
        s.exposureMode = "Manual"
        s.iso = "800"; s.isoCandidates = ["AUTO", "100", "200", "400", "800", "1600", "3200", "6400"]
        s.shutterSpeed = "1/50"; s.shutterSpeedCandidates = ["1/500", "1/125", "1/60", "1/50", "1/48", "1/30"]
        s.exposureCompensation = ExposureCompensation(index: 0, minIndex: -9, maxIndex: 9, stepIndex: 3)
        s.availableAPIs = ["setIsoSpeedRate", "setExposureCompensation", "setShutterSpeed", "setTouchAFPosition", "actHalfPressShutter"]
        return s
    }
    private func face(luma: Double, sharpness: Double = 100, rect: CGRect = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3)) -> SceneMeasurements {
        var m = SceneMeasurements()
        m.faces = [.init(rect: rect, luma: luma, sharpness: sharpness)]
        m.sharpestRegion = CGPoint(x: 0.5, y: 0.35); m.sharpestScore = 100; m.meanLuma = 45
        return m
    }
    private func findings(_ m: SceneMeasurements, _ s: CameraState, profile: PictureProfile = .standard, fps: Int = 24, mode: ShootingMode = .video) -> [Finding] {
        AssistRules.findings(m, state: s, profile: profile, projectFPS: fps, shootingMode: mode)
    }

    func testSkinTargetsFollowProfile() {
        XCTAssertEqual(AssistRules.skinTarget(for: .standard), 55)
        XCTAssertEqual(AssistRules.skinTarget(for: .pp7), 32)
        XCTAssertEqual(AssistRules.skinTarget(for: .pp8), 41)
        XCTAssertEqual(AssistRules.skinTarget(for: .pp10), 45)
    }
    func testStopsLabelRoundsToThirds() {
        XCTAssertEqual(AssistRules.stopsLabel(1.0), "1 STOP")
        XCTAssertEqual(AssistRules.stopsLabel(1.28), "1.3 STOPS")
        XCTAssertEqual(AssistRules.stopsLabel(0.7), "0.7 STOP")
    }
    func testFaceOneStopUnderInManualOffersISO() throws {
        let f = findings(face(luma: 27.5), manualState())   // 27.5 is exactly one stop under 55
        let under = try XCTUnwrap(f.first { $0.id == "face-under" })
        XCTAssertEqual(under.fact, "FACE 1 STOP UNDER")
        XCTAssertEqual(under.severity, .warn)
        XCTAssertEqual(under.fix, Fix(label: "EI 800 → 1600", command: .setISO("1600")))
    }
    func testFaceOverInApertureModeOffersEV() throws {
        var s = manualState(); s.exposureMode = "Aperture"
        let f = findings(face(luma: 110), s)                // one stop over
        let over = try XCTUnwrap(f.first { $0.id == "face-over" })
        XCTAssertEqual(over.fix, Fix(label: "EV 0 → -1.0", command: .setExposureCompensation(index: -3)))
    }
    func testNoFixWhenCommandUnsupported() throws {
        var s = manualState(); s.availableAPIs.remove("setIsoSpeedRate")
        let under = try XCTUnwrap(findings(face(luma: 27.5), s).first { $0.id == "face-under" })
        XCTAssertNil(under.fix)
    }
    func testSmallErrorIsNotAFinding() {
        XCTAssertNil(findings(face(luma: 45), manualState()).first { $0.id.hasPrefix("face-") })   // 0.29 stop
    }
    func testClippingOnlyWithoutFaceFinding() {
        var m = face(luma: 55); m.whiteClip = 0.05
        XCTAssertNotNil(findings(m, manualState()).first { $0.id == "highlights-clip" })
        var m2 = face(luma: 20); m2.whiteClip = 0.05
        XCTAssertNil(findings(m2, manualState()).first { $0.id == "highlights-clip" })
    }
    func testFocusMissedNeedsSoftFaceAndDistantSharpRegion() throws {
        var m = face(luma: 55, sharpness: 20)               // soft face (< 0.6 × 100)
        m.sharpestRegion = CGPoint(x: 0.9, y: 0.9)          // far from the face centre (0.5, 0.35)
        let miss = try XCTUnwrap(findings(m, manualState()).first { $0.id == "focus-missed" })
        XCTAssertEqual(miss.fact, "FOCUS OFF SUBJECT")
        XCTAssertEqual(miss.fix, Fix(label: "AF ON FACE", command: .touchAF(x: 0.5, y: 0.35)))
        var near = face(luma: 55, sharpness: 20); near.sharpestRegion = CGPoint(x: 0.55, y: 0.4)
        XCTAssertNil(findings(near, manualState()).first { $0.id == "focus-missed" })
    }
    func testFocusFailedOffersAutofocus() throws {
        var s = manualState(); s.focusStatus = "Failed"
        let f = try XCTUnwrap(findings(face(luma: 55), s).first { $0.id == "focus-failed" })
        XCTAssertEqual(f.fix?.command, .autofocus)
    }
    func testShutterAngleFarFrom180InVideoOnly() throws {
        var s = manualState(); s.shutterSpeed = "1/500"
        let f = try XCTUnwrap(findings(face(luma: 55), s).first { $0.id == "shutter-angle" })
        XCTAssertEqual(f.fact, "SHUTTER 17°")
        XCTAssertEqual(f.fix, Fix(label: "1/500 → 1/48", command: .setShutterSpeed("1/48")))
        XCTAssertTrue(f.detail.contains("narrower"), "the model must be told which way the angle is off")
        var slow = s; slow.shutterSpeed = "1/30"
        let wide = try XCTUnwrap(findings(face(luma: 55), slow).first { $0.id == "shutter-angle" })
        XCTAssertEqual(wide.fact, "SHUTTER 288°")
        XCTAssertTrue(wide.detail.contains("wider"))
        XCTAssertNil(findings(face(luma: 55), s, mode: .photo).first { $0.id == "shutter-angle" })
    }
    func testHorizonAndHeadroom() {
        var m = face(luma: 55, rect: CGRect(x: 0.4, y: 0.0, width: 0.2, height: 0.3)); m.horizonDegrees = 3.2
        let f = findings(m, manualState())
        XCTAssertEqual(f.first { $0.id == "horizon" }?.fact, "HORIZON 3° OFF")
        XCTAssertEqual(f.first { $0.id == "headroom" }?.fact, "TOO TIGHT ON TOP")
        var low = face(luma: 55, rect: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.3))
        low.horizonDegrees = 0.5
        XCTAssertEqual(findings(low, manualState()).first { $0.id == "headroom" }?.fact, "SUBJECT LOW IN FRAME")
    }
    func testOrderAndCap() {
        var s = manualState(); s.focusStatus = "Failed"; s.shutterSpeed = "1/500"
        var m = face(luma: 27.5, sharpness: 20, rect: CGRect(x: 0.4, y: 0.0, width: 0.2, height: 0.3))
        m.sharpestRegion = CGPoint(x: 0.9, y: 0.9); m.horizonDegrees = 5
        let ids = findings(m, s).map(\.id)
        XCTAssertEqual(ids, ["face-under", "focus-missed", "focus-failed", "shutter-angle"])
    }
}
