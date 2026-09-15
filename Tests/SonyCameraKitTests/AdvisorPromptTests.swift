import XCTest
import CoreGraphics
@testable import CinemaUI
@testable import SonyCameraKit

final class AdvisorPromptTests: XCTestCase {
    func testPromptCarriesStateMeasurementsAndFindingIds() {
        var s = CameraState()
        s.exposureMode = "Manual"; s.shutterSpeed = "1/50"; s.fNumber = "2.8"; s.iso = "800"; s.focusMode = "AF-C"; s.focusStatus = "Focused"
        var m = SceneMeasurements(); m.meanLuma = 42; m.whiteClip = 0.031; m.horizonDegrees = 2.2
        m.faces = [.init(rect: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3), luma: 28, sharpness: 12)]
        let f = [Finding(id: "face-under", kind: .exposure, severity: .warn, fact: "FACE 1 STOP UNDER", detail: "The largest face reads 28; target 55."),
                 Finding(id: "horizon", kind: .framing, severity: .info, fact: "HORIZON 2° OFF", detail: "The horizon is tilted 2.2°.")]
        let p = AdvisorPrompt.build(findings: f, measurements: m, state: s, profile: .standard, projectFPS: 24)
        XCTAssertTrue(p.contains("mode=Manual"))
        XCTAssertTrue(p.contains("shutter=1/50 (172.8°)"))
        XCTAssertTrue(p.contains("iris=F2.8"))
        XCTAssertTrue(p.contains("ei=800"))
        XCTAssertTrue(p.contains("profile=STD"))
        XCTAssertTrue(p.contains("face_luma=28"))
        XCTAssertTrue(p.contains("white_clip=3%"))
        XCTAssertTrue(p.contains("horizon=2.2°"))
        XCTAssertTrue(p.contains("[face-under] The largest face reads 28; target 55."))
        XCTAssertTrue(p.contains("[horizon] The horizon is tilted 2.2°."))
        XCTAssertLessThan(p.count, 1200, "prompt must stay small for the on-device context")
    }
    func testInstructionsForbidValues() {
        XCTAssertTrue(AdvisorPrompt.instructions.contains("Never suggest values"))
    }
    func testAvailabilityReasonIsNilOnlyWhenAvailable() {
        let a = ShotAdvisorAvailability.current
        if case .available = a { XCTAssertNil(a.reason) } else { XCTAssertNotNil(a.reason) }
    }
}
