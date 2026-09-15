import XCTest
@testable import CinemaUI

final class GuidesTests: XCTestCase {
    func testRatiosAndLabels() {
        XCTAssertEqual(FrameGuideRatio.r239.value, 2.39, accuracy: 0.001)
        XCTAssertEqual(FrameGuideRatio.r916.value, 9.0 / 16.0, accuracy: 0.001)
        XCTAssertEqual(FrameGuideRatio.r43.label, "4:3")
        XCTAssertEqual(FrameGuideRatio.allCases.count, 7)
    }
    func testLegalTextsAreComplete() {
        XCTAssertTrue(LegalText.privacyPolicy.contains("does not collect"))
        XCTAssertTrue(LegalText.privacyPolicy.contains("Shiv Vyas"))
        XCTAssertTrue(LegalText.privacyPolicy.contains("shivvyas0209@gmail.com"))
        XCTAssertFalse(LegalText.privacyPolicy.contains("[contact email]"))
        XCTAssertTrue(LegalText.termsOfUse.contains("shivvyas0209@gmail.com"))
        XCTAssertTrue(LegalText.termsOfUse.contains("not affiliated"))
        XCTAssertTrue(LegalText.termsOfUse.contains("AS IS"))
        XCTAssertEqual(LegalText.paragraphs(LegalText.termsOfUse).filter { $0.isHeading }.count, 8)
    }

    func testPeakingColours() {
        XCTAssertEqual(PeakingColor.red.rgb.0, 1, accuracy: 0.001)
        XCTAssertEqual(PeakingColor.blue.rgb.2, 1, accuracy: 0.001)
        XCTAssertEqual(PeakingColor.allCases.map(\.rawValue), ["Red", "Yellow", "White", "Blue"])
    }
}
