import XCTest
@testable import SonyCameraKit

final class LiveviewStreamParserTests: XCTestCase {
    let jpegA = Data([0xFF, 0xD8, 0x01, 0x02, 0x03, 0xFF, 0xD9])
    let jpegB = Data([0xFF, 0xD8, 0x09, 0x08, 0xFF, 0xD9])

    func testSingleFrame() {
        var p = LiveviewStreamParser()
        let pkt = LiveviewStreamParser.packet(type: 1, sequence: 7, timestamp: 1234, payload: jpegA)
        let frames = p.append(pkt)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].sequence, 7)
        XCTAssertEqual(frames[0].timestamp, 1234)
        XCTAssertEqual(frames[0].jpeg, jpegA)
    }

    func testFrameSplitAcrossChunksAndPadding() {
        var p = LiveviewStreamParser()
        let pkt = LiveviewStreamParser.packet(type: 1, sequence: 1, timestamp: 0, payload: jpegA, padding: 3)
            + LiveviewStreamParser.packet(type: 1, sequence: 2, timestamp: 0, payload: jpegB, padding: 1)
        var all: [LiveviewFrame] = []
        for i in stride(from: 0, to: pkt.count, by: 5) {
            all += p.append(pkt[i ..< min(i + 5, pkt.count)])
        }
        XCTAssertEqual(all.map(\.sequence), [1, 2])
        XCTAssertEqual(all.map(\.jpeg), [jpegA, jpegB])
    }

    func testFrameInfoPacketsAreSkippedAndGarbageIsResynced() {
        var p = LiveviewStreamParser()
        var data = Data([0x00, 0x11, 0x22])   // junk before the first packet
        data += LiveviewStreamParser.packet(type: 2, sequence: 1, timestamp: 0, payload: Data(repeating: 0xAB, count: 16))
        data += LiveviewStreamParser.packet(type: 1, sequence: 2, timestamp: 99, payload: jpegB)
        let frames = p.append(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].sequence, 2)
        XCTAssertEqual(frames[0].jpeg, jpegB)
        XCTAssertEqual(p.droppedBytes, 3)
    }

    func testLargePayloadSizeUsesThreeBytes() {
        var p = LiveviewStreamParser()
        let big = Data(repeating: 0x5A, count: 70_000)
        let frames = p.append(LiveviewStreamParser.packet(type: 1, sequence: 3, timestamp: 0, payload: big))
        XCTAssertEqual(frames.first?.jpeg.count, 70_000)
    }
}
