import XCTest
@testable import CinemaUI

final class ShutterAngleTests: XCTestCase {
    func testSecondsParsesFractionsWholeAndBulb() {
        XCTAssertEqual(ShutterAngle.seconds("1/50")!, 0.02, accuracy: 1e-9)
        XCTAssertEqual(ShutterAngle.seconds("2\"")!, 2, accuracy: 1e-9)
        XCTAssertNil(ShutterAngle.seconds("BULB"))
        XCTAssertNil(ShutterAngle.seconds("--"))
    }
    func testDegreesAndLabel() {
        XCTAssertEqual(ShutterAngle.degrees(speed: "1/50", fps: 24)!, 172.8, accuracy: 0.01)
        XCTAssertEqual(ShutterAngle.label(speed: "1/50", fps: 24), "172.8")
        XCTAssertEqual(ShutterAngle.label(speed: "1/10", fps: 24), "360+")
        XCTAssertEqual(ShutterAngle.label(speed: nil, fps: 24), "--")
    }
    func testNearest180PicksTheClosestCandidate() {
        let c = ["1/500", "1/250", "1/125", "1/60", "1/50", "1/48", "1/30"]
        XCTAssertEqual(ShutterAngle.nearest180(candidates: c, fps: 24), "1/48")
        XCTAssertEqual(ShutterAngle.nearest180(candidates: c, fps: 60), "1/125")
        XCTAssertNil(ShutterAngle.nearest180(candidates: [], fps: 24))
    }
}
