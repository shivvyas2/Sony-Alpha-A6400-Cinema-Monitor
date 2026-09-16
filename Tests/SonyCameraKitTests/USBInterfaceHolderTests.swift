import XCTest
@testable import SonyCameraKit

final class USBInterfaceHolderTests: XCTestCase {
    func testParsesKernelCreatorString() {
        let h = USBInterfaceHolder.parse(creator: "pid 28437, ptpcamerad")
        XCTAssertEqual(h, USBInterfaceHolder(pid: 28437, name: "ptpcamerad"))
    }

    func testParsesNameWithSpaces() {
        let h = USBInterfaceHolder.parse(creator: "pid 512, Imaging Edge Desktop")
        XCTAssertEqual(h?.pid, 512)
        XCTAssertEqual(h?.name, "Imaging Edge Desktop")
    }

    func testRejectsMalformedCreator() {
        XCTAssertNil(USBInterfaceHolder.parse(creator: ""))
        XCTAssertNil(USBInterfaceHolder.parse(creator: "ptpcamerad"))
        XCTAssertNil(USBInterfaceHolder.parse(creator: "pid x, ptpcamerad"))
        XCTAssertNil(USBInterfaceHolder.parse(creator: "pid 0, ptpcamerad"))
    }

    func testOnlyTheImageCaptureDaemonMayBeReleased() {
        XCTAssertTrue(USBInterfaceHolder(pid: 1, name: "ptpcamerad").isSystemPTPDaemon)
        XCTAssertFalse(USBInterfaceHolder(pid: 1, name: "Imaging Edge Desktop").isSystemPTPDaemon)
        XCTAssertFalse(USBInterfaceHolder(pid: 1, name: "CinemaHUD").isSystemPTPDaemon)
    }
}
