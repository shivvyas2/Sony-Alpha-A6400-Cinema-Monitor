import XCTest
@testable import SonyCameraKit

final class FormatTests: XCTestCase {
    func testStillSizeLabelsAndUSBNames() {
        let s = StillSize(aspect: "16:9", size: "M")
        XCTAssertEqual(s.label, "16:9  M")
        XCTAssertEqual(s.usbSizeName, "Medium")
        XCTAssertEqual(StillSize(usbAspect: "16:9", usbSize: "Large"), StillSize(aspect: "16:9", size: "L"))
        XCTAssertNil(StillSize(usbAspect: "16:9", usbSize: "Huge"))
    }

    func testStillSizeParsesSupportedList() throws {
        let json = try JSON.parse(Data(#"[[{"aspect":"3:2","size":"L"},{"aspect":"16:9","size":"S"}]]"#.utf8))
        XCTAssertEqual(StillSize.list(from: json[0]), [StillSize(aspect: "3:2", size: "L"), StillSize(aspect: "16:9", size: "S")])
    }
}
