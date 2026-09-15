import XCTest
@testable import SonyCameraKit

final class ShotLogTests: XCTestCase {
    private func img(_ shot: Int, _ kind: CapturedImage.Kind) -> CapturedImage {
        CapturedImage(url: URL(fileURLWithPath: "/tmp/\(shot).\(kind == .jpeg ? "JPG" : "ARW")"), kind: kind,
                      filename: "DSC\(shot).\(kind == .jpeg ? "JPG" : "ARW")", takenAt: Date(timeIntervalSince1970: 100), shotIndex: shot)
    }
    private var exposure: ExposureSnapshot {
        var s = CameraState(); s.shutterSpeed = "1/250"; s.fNumber = "2.8"; s.iso = "400"
        return ExposureSnapshot(state: s)
    }

    func testGroupsJpegAndRawOfTheSameShot() {
        var log = ShotLog()
        let first = log.apply(.image(img(1, .jpeg)), exposure: exposure, afPoint: CGPoint(x: 0.3, y: 0.6))
        guard case .newShot(let shot) = first else { return XCTFail("expected newShot, got \(first)") }
        XCTAssertEqual(shot.id, 1); XCTAssertNotNil(shot.jpeg); XCTAssertNil(shot.raw); XCTAssertTrue(shot.transferring)
        XCTAssertEqual(shot.afPoint, CGPoint(x: 0.3, y: 0.6))
        XCTAssertEqual(shot.exposure.summary, "1/250   F2.8   ISO 400")

        let second = log.apply(.image(img(1, .raw)), exposure: exposure, afPoint: nil)
        guard case .updated(let both) = second else { return XCTFail("expected updated") }
        XCTAssertTrue(both.hasBoth); XCTAssertEqual(log.shots.count, 1)

        let done = log.apply(.finished(shotIndex: 1), exposure: exposure, afPoint: nil)
        guard case .updated(let finished) = done else { return XCTFail("expected updated") }
        XCTAssertFalse(finished.transferring)
    }

    func testFailureMarksShotOrIsIgnoredWhenNothingArrived() {
        var log = ShotLog()
        XCTAssertEqual(log.apply(.failed(shotIndex: 9, message: "nope"), exposure: exposure, afPoint: nil), .none)
        _ = log.apply(.image(img(2, .raw)), exposure: exposure, afPoint: nil)
        let r = log.apply(.failed(shotIndex: 2, message: "cable"), exposure: exposure, afPoint: nil)
        guard case .updated(let s) = r else { return XCTFail("expected updated") }
        XCTAssertEqual(s.error, "cable"); XCTAssertFalse(s.transferring); XCTAssertEqual(s.primary?.kind, .raw)
    }

    func testNeighborNavigation() {
        var log = ShotLog()
        for i in 1 ... 3 { _ = log.apply(.image(img(i, .jpeg)), exposure: exposure, afPoint: nil) }
        XCTAssertEqual(log.neighbor(of: 2, offset: -1)?.id, 1)
        XCTAssertEqual(log.neighbor(of: 2, offset: 1)?.id, 3)
        XCTAssertNil(log.neighbor(of: 3, offset: 1))
        XCTAssertNil(log.neighbor(of: 42, offset: 1))
    }
}
