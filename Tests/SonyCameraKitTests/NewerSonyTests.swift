import XCTest
@testable import SonyCameraKit

/// Bodies after the α6400: more property types, faster shutters, and possibly only the 3.00 protocol.
final class NewerSonyTests: XCTestCase {
    private func battery(_ d: inout Data, _ v: UInt8 = 73) {
        d.append(le16: SonyProp.batteryLevel); d.append(le16: 2); d.append(0); d.append(2)
        d.append(contentsOf: [100, v, 1, 0, 100, 1])
    }
    private func shutter(_ d: inout Data, _ values: [UInt32]) {
        d.append(le16: SonyProp.shutterSpeed); d.append(le16: 6); d.append(1); d.append(1)
        d.append(le32: values[0]); d.append(le32: values[0]); d.append(2)
        d.append(le16: UInt16(values.count)); values.forEach { d.append(le32: $0) }
    }

    func testArrayPropertyDoesNotHideTheOnesAfterIt() throws {
        var d = Data(); d.append(le64: 2)
        d.append(le16: 0xD27A); d.append(le16: 0x4002); d.append(0); d.append(2)      // array of u8
        d.append(le32: 2); d.append(contentsOf: [1, 2]); d.append(le32: 3); d.append(contentsOf: [1, 2, 3]); d.append(0)
        battery(&d)
        let list = try SonyPropDesc.parseAll(d)
        XCTAssertEqual(list.last?.code, SonyProp.batteryLevel); XCTAssertEqual(list.last?.current, 73)
    }

    func testUnknownTypeIsSkippedUpToTheNextProperty() throws {
        var d = Data(); d.append(le64: 2)
        d.append(le16: 0xD2FE); d.append(le16: 0x0033); d.append(contentsOf: [0, 1, 9, 9, 9, 9])
        battery(&d)
        let list = try SonyPropDesc.parseAll(d)
        XCTAssertEqual(list.map(\.code), [SonyProp.batteryLevel]); XCTAssertEqual(list[0].current, 73)
    }

    func testSecondListIsReadWhenAnE000PropertyFollows() throws {
        var d = Data(); d.append(le64: 2)
        shutter(&d, [0x0001_0032, 0x0001_003C])
        d.append(le16: 1); d.append(le32: 0x0001_0032)
        d.append(le16: 0xE001); d.append(le16: 2); d.append(contentsOf: [0, 1, 0, 5, 0])
        let list = try SonyPropDesc.parseAll(d)
        XCTAssertEqual(list.map(\.code), [SonyProp.shutterSpeed, 0xE001]); XCTAssertEqual(list.last?.current, 5)
    }

    func testFasterShutterThanTheA6400ComesFromTheCamerasOwnList() throws {
        var d = Data(); d.append(le64: 1)
        shutter(&d, [0x0001_0000 | 4000, 0x0001_0000 | 8000])
        let p = try XCTUnwrap(SonyPropDesc.parseAll(d).first)
        XCTAssertEqual(SonyUSBBackend.target("1/8000", in: p, format: SonyValue.shutter, table: SonyValue.fullShutterTable), 0x0001_0000 | 8000)
        // No list from the camera (α6400 in some modes): the built-in table, which still stops at 1/4000.
        var bare = p; bare.enumValues = []
        XCTAssertEqual(SonyUSBBackend.target("1/4000", in: bare, format: SonyValue.shutter, table: SonyValue.fullShutterTable), 0x0001_0000 | 4000)
        XCTAssertNil(SonyUSBBackend.target("1/8000", in: bare, format: SonyValue.shutter, table: SonyValue.fullShutterTable))
    }

    private actor FakeBody {
        var log: [(op: UInt16, params: [UInt32])] = []
        let only300: Bool
        var mode: UInt32 = 0
        init(only300: Bool) { self.only300 = only300 }
        func handle(_ op: UInt16, _ params: [UInt32]) -> Data {
            log.append((op, params))
            if op == PTP.Op.sonyGetSDIOExtDeviceInfo { mode = params[0] }
            if op == PTP.Op.sonyGetAllDevicePropData { return (only300 && mode != 0x12C) ? Data() : Data(repeating: 0, count: 64) }
            return Data()
        }
        var versions: [UInt32] { log.filter { $0.op == PTP.Op.sonyGetSDIOExtDeviceInfo }.map { $0.params[0] } }
    }

    func testOlderProtocolComesFirstAndNothingElseIsAskedWhenItWorks() async throws {
        let body = FakeBody(only300: false)
        let v = try await SonyHandshake.run(attempts: 2, wait: .zero) { op, p in await body.handle(op, p) }
        XCTAssertEqual(v, 0xC8)
        let asked = await body.versions; XCTAssertEqual(asked, [0xC8])
        let phases = await body.log.filter { $0.op == PTP.Op.sonySDIOConnect }.map { $0.params[0] }
        XCTAssertEqual(phases, [1, 2, 3])
    }

    func testBodyThatOnlySpeaks300IsAskedAgain() async throws {
        let body = FakeBody(only300: true)
        let v = try await SonyHandshake.run(attempts: 2, wait: .zero) { op, p in await body.handle(op, p) }
        XCTAssertEqual(v, 0x12C)
        let asked = await body.versions; XCTAssertEqual(asked, [0xC8, 0x12C])
    }

    func testOtherBrandsAreNamedInsteadOfBeingSentSonyCommands() {
        XCTAssertNil(USBCameraDevice(id: 1, vendorID: 0x054C, productID: 1, name: "ILCE-7M4").unsupportedReason)
        for (vid, brand) in [(0x04A9, "Canon"), (0x04B0, "Nikon"), (0x04CB, "Fujifilm")] {
            let r = USBCameraDevice(id: 1, vendorID: vid, productID: 1, name: "X").unsupportedReason
            XCTAssertTrue(r?.contains(brand) == true, "\(r ?? "nil")")
        }
    }
}
