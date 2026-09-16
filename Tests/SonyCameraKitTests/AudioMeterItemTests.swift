#if os(macOS)
import XCTest
@testable import CinemaUI

final class AudioMeterItemTests: XCTestCase {
    func testFraction() {
        XCTAssertEqual(MeterScale.fraction(-60), 0)
        XCTAssertEqual(MeterScale.fraction(0), 1)
        XCTAssertEqual(MeterScale.fraction(-30), 0.5, accuracy: 1e-6)
        XCTAssertEqual(MeterScale.fraction(-90), 0)
        XCTAssertEqual(MeterScale.fraction(3), 1)
    }
}
#endif
