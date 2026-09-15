import XCTest
@testable import SonyCameraKit

final class PTPTests: XCTestCase {
    func testContainerRoundTrip() {
        let c = PTP.Container(type: .command, code: PTP.Op.openSession, transactionID: 7, params: [1, 0xFFFFC002])
        let enc = c.encoded
        XCTAssertEqual(enc.count, 20)
        XCTAssertEqual([UInt8](enc.prefix(4)), [20, 0, 0, 0])
        let dec = PTP.Container.decode(enc)
        XCTAssertEqual(dec, c)
        XCTAssertEqual(dec?.params, [1, 0xFFFFC002])
    }

    func testDecodeTolleratesTruncatedLengthField() {
        var d = Data()
        d.append(le32: 100)   // claims 100 bytes, we only have 16
        d.append(le16: 2); d.append(le16: 0x1009); d.append(le32: 3)
        d.append(contentsOf: [1, 2, 3, 4])
        let c = PTP.Container.decode(d)
        XCTAssertEqual(c?.type, .data)
        XCTAssertEqual(c?.payload, Data([1, 2, 3, 4]))
    }

    /// Builds a Sony GetAllDevicePropData payload by hand and checks parsing, including the
    /// second enumeration list Sony appends.
    func testSonyPropDescParsing() throws {
        var d = Data()
        d.append(le64: 3)
        // ShutterSpeed: u32, settable, enum of 3 + "all" enum of 4
        d.append(le16: SonyProp.shutterSpeed); d.append(le16: PTP.DataType.uint32.rawValue); d.append(1); d.append(1)
        d.append(le32: 0x0001_0032); d.append(le32: 0x0001_0032); d.append(2)
        d.append(le16: 3); d.append(le32: 0x0001_001E); d.append(le32: 0x0001_0032); d.append(le32: 0x0001_003C)
        d.append(le16: 4); d.append(le32: 0x0002_0001); d.append(le32: 0x0001_001E); d.append(le32: 0x0001_0032); d.append(le32: 0x0001_003C)
        // FNumber: u16, display only, no form, no second enum
        d.append(le16: SonyProp.fNumber); d.append(le16: PTP.DataType.uint16.rawValue); d.append(1); d.append(2)
        d.append(le16: 280); d.append(le16: 280); d.append(0)
        // Battery: u8 range 0-100
        d.append(le16: SonyProp.batteryLevel); d.append(le16: PTP.DataType.uint8.rawValue); d.append(0); d.append(2)
        d.append(100); d.append(73); d.append(1); d.append(0); d.append(100); d.append(1)

        let list = try SonyPropDesc.parseAll(d)
        XCTAssertEqual(list.count, 3)
        let sh = list[0]
        XCTAssertEqual(sh.code, SonyProp.shutterSpeed)
        XCTAssertTrue(sh.settable)
        XCTAssertEqual(sh.current, 0x0001_0032)
        XCTAssertEqual(sh.enumValues, [0x0001_001E, 0x0001_0032, 0x0001_003C])
        XCTAssertEqual(sh.enumAllValues.count, 4)
        XCTAssertEqual(list[1].code, SonyProp.fNumber)
        XCTAssertFalse(list[1].settable)
        XCTAssertEqual(list[1].current, 280)
        XCTAssertEqual(list[2].rangeMax, 100)
        XCTAssertEqual(list[2].current, 73)

        let state = SonyUSBBackend.makeState(from: Dictionary(uniqueKeysWithValues: list.map { ($0.code, $0) }), recording: false)
        XCTAssertEqual(state.shutterSpeed, "1/50")
        XCTAssertEqual(state.shutterSpeedCandidates, ["1/30", "1/50", "1/60"])
        XCTAssertEqual(state.fNumber, "2.8")
        XCTAssertTrue(state.supports("setShutterSpeed"))
        XCTAssertFalse(state.supports("setFNumber"))
        XCTAssertEqual(state.battery?.levelNumer, 73)
    }

    func testSonyValueFormatting() {
        XCTAssertEqual(SonyValue.shutter(0x0001_0032), "1/50")
        XCTAssertEqual(SonyValue.shutter(0x0002_0001), "2\"")
        XCTAssertEqual(SonyValue.shutter(0x0019_000A), "2.5\"")
        XCTAssertEqual(SonyValue.shutter(0), "BULB")
        XCTAssertEqual(SonyValue.fNumber(280), "2.8")
        XCTAssertEqual(SonyValue.fNumber(400), "4")
        XCTAssertEqual(SonyValue.fNumber(1100), "11")
        XCTAssertEqual(SonyValue.iso(800), "800")
        XCTAssertEqual(SonyValue.iso(0xFFFFFF), "AUTO")
        XCTAssertEqual(SonyValue.ev(700).label, "+0.7")
        XCTAssertEqual(SonyValue.ev(-1000).index, -3)
        XCTAssertEqual(SonyValue.evValue(index: 2), 700)
        XCTAssertEqual(SonyValue.evValue(index: -4), -1300)
        XCTAssertEqual(SonyValue.evValue(index: 0), 0)
    }

    func testShutterTablesAndSeconds() {
        XCTAssertEqual(SonyValue.shutterSeconds(0x0001_0032), 1.0 / 50)
        XCTAssertEqual(SonyValue.shutterSeconds(0x0019_000A), 2.5)
        XCTAssertNil(SonyValue.shutterSeconds(0xFFFF_FFFF))
        XCTAssertEqual(SonyValue.shutter(0xFFFF_FFFF), "--")
        XCTAssertEqual(SonyValue.shutter(0x0001_002D), "1/45")
        let secs = SonyValue.fullShutterTable.compactMap(SonyValue.shutterSeconds)
        XCTAssertEqual(secs, secs.sorted(by: >), "slow to fast")
        XCTAssertTrue(SonyValue.fullShutterTable.contains(0x0001_005A), "movie value 1/90 present")
        XCTAssertEqual(SonyValue.fullShutterTable.first, 0x001E_0001)
        XCTAssertEqual(SonyValue.fullShutterTable.last, 0x0001_0FA0)
    }

    func testExtractJPEGFromSonyLiveviewObject() {
        let jpeg = Data([0xFF, 0xD8, 0xAA, 0xBB, 0xFF, 0xD9])
        let wrapped = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]) + jpeg + Data([0, 0])
        XCTAssertEqual(SonyUSBBackend.extractJPEG(wrapped), jpeg)
        XCTAssertNil(SonyUSBBackend.extractJPEG(Data([1, 2, 3, 4, 5])))
    }
}
