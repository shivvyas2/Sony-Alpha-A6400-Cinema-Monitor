import XCTest
@testable import CinemaAudio

final class ScaffoldTests: XCTestCase {
    func testModuleVersion() {
        XCTAssertEqual(CinemaAudio.version, "1")
    }
}
