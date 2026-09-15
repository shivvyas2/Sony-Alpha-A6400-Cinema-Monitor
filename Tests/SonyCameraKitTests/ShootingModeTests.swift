import XCTest
@testable import SonyCameraKit

final class ShootingModeTests: XCTestCase {
    func testFollowsTheDial() {
        var r = ShootingModeResolver()
        XCTAssertEqual(r.mode, .video)
        r.dial("still"); XCTAssertEqual(r.mode, .photo)
        r.dial("movie"); XCTAssertEqual(r.mode, .video)
        r.dial(nil); XCTAssertEqual(r.mode, .video)   // unknown keeps the last mode
    }

    func testOverrideHoldsUntilTheDialMoves() {
        var r = ShootingModeResolver()
        r.dial("movie")
        r.toggle(); XCTAssertEqual(r.mode, .photo); XCTAssertTrue(r.overridden)
        r.dial("movie"); XCTAssertEqual(r.mode, .photo)      // same dial position: override stays
        r.dial("still"); XCTAssertEqual(r.mode, .photo); XCTAssertFalse(r.overridden)
        r.dial("movie"); XCTAssertEqual(r.mode, .video)
    }
}
