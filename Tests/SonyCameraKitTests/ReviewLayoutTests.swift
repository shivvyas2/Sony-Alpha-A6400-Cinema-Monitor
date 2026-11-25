import XCTest
@testable import CinemaUI

/// The review screen on every phone size: header, picture and 100 % crop each get their own space.
final class ReviewLayoutTests: XCTestCase {
    // Portrait safe areas (w × h): SE, 13 mini, 15 Pro, 17 Pro Max.
    private let phones = [CGSize(width: 320, height: 548), CGSize(width: 375, height: 647), CGSize(width: 375, height: 762), CGSize(width: 393, height: 793), CGSize(width: 440, height: 894)]
    private let aspects: [CGFloat] = [1.5, 16.0 / 9, 1, 2.0 / 3]

    private func check(_ size: CGSize, _ aspect: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let l = ReviewLayout(size: size, aspect: aspect, header: size.height > size.width ? 60 : 36)
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
        let what = "\(size) aspect \(aspect): \(l)"
        XCTAssertTrue(screen.contains(l.picture), what, file: file, line: line)
        XCTAssertTrue(screen.contains(l.loupe), what, file: file, line: line)
        XCTAssertGreaterThanOrEqual(l.picture.minY, l.viewport.minY - 0.5, what, file: file, line: line)
        XCTAssertEqual(l.picture.width / l.picture.height, aspect, accuracy: 0.02, what, file: file, line: line)
        XCTAssertGreaterThanOrEqual(min(l.loupe.width, l.loupe.height), 110, what, file: file, line: line)
        if !l.loupeOverPicture { XCTAssertFalse(l.picture.insetBy(dx: 0.5, dy: 0.5).intersects(l.loupe), what, file: file, line: line) }
    }

    func testEverythingFitsOnEveryPhone() {
        for p in phones { for a in aspects { check(p, a); check(CGSize(width: max(p.height, 568), height: p.width), a) } }
    }

    func testLandscapeShotsNeverGetCoveredByTheCrop() {
        for p in phones {
            XCTAssertFalse(ReviewLayout(size: p, aspect: 1.5, header: 60).loupeOverPicture)
            if p.width >= 375 { XCTAssertFalse(ReviewLayout(size: CGSize(width: p.height + 20, height: p.width), aspect: 1.5, header: 36).loupeOverPicture, "\(p)") }
        }
    }

    func testPortraitCropIsCenteredAndUsesTheSpaceBelow() {
        let l = ReviewLayout(size: CGSize(width: 393, height: 793), aspect: 1.5, header: 60)
        XCTAssertEqual(l.loupe.midX, 393 / 2, accuracy: 0.5)
        XCTAssertLessThan(l.loupe.minY - l.picture.maxY, 24)
        XCTAssertEqual(l.picture.width, 393, accuracy: 0.5)
    }

    func testZoomKeepsThePictureOnScreen() {
        let vp = CGRect(x: 0, y: 60, width: 393, height: 733)
        let shown = CGSize(width: 2000, height: 1333)
        let far = ReviewLayout.clamped(center: CGPoint(x: 9000, y: -9000), shown: shown, in: vp)
        XCTAssertEqual(far.x - 1000, vp.minX, accuracy: 0.5)
        XCTAssertEqual(far.y + 1333 / 2, vp.maxY, accuracy: 0.5)
        // Smaller than the screen: free to sit anywhere inside it, never outside.
        let small = ReviewLayout.clamped(center: CGPoint(x: 196, y: 190), shown: CGSize(width: 393, height: 262), in: vp)
        XCTAssertEqual(small.y, 191, accuracy: 1.5)
    }

    func testPinchKeepsThePointUnderTheFingers() {
        let c = ReviewLayout.center(CGPoint(x: 200, y: 200), zoomedBy: 2, around: CGPoint(x: 250, y: 220))
        XCTAssertEqual(c, CGPoint(x: 150, y: 180))
    }
}
