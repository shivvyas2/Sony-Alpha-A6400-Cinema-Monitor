import XCTest
@testable import CinemaAudio

final class FCPXMLTests: XCTestCase {
    func clip(_ name: String, duration: Double) -> ClipInfo {
        ClipInfo(id: URL(fileURLWithPath: "/Volumes/CARD/PRIVATE/M4ROOT/CLIP/\(name).MP4"), name: name, duration: duration, creationDate: nil,
                 hasAudio: true, videoSize: CGSize(width: 3840, height: 2160), nominalFrameRate: 23.976)
    }

    func testRational() {
        XCTAssertEqual(FCPXML.rational(2.0, fps: 24), "48/24s")
        XCTAssertEqual(FCPXML.rational(10.02, fps: 25), "251/25s")
        XCTAssertEqual(FCPXML.rational(0, fps: 24), "0s")
    }

    func testDocumentStructure() throws {
        let synced = URL(fileURLWithPath: "/Users/me/Movies/CinemaHUD/2026-09-15/synced")
        let wav = synced.appendingPathComponent("A_0001_C001.wav")
        let pairs = [
            TakePair(clip: clip("C0001", duration: 10), take: nil, offsetSeconds: 3.4, confidence: 0.95, status: .exported(wav)),
            TakePair(clip: clip("C0002", duration: 5), take: nil, offsetSeconds: nil, confidence: nil, status: .unpaired),
        ]
        let xml = FCPXML.document(pairs: pairs, syncedFolder: synced, projectFPS: 24, eventName: "CinemaHUD 2026-09-15")
        let doc = try XMLDocument(xmlString: xml, options: [])
        let root = try XCTUnwrap(doc.rootElement())
        XCTAssertEqual(root.name, "fcpxml")
        XCTAssertEqual(root.attribute(forName: "version")?.stringValue, "1.11")
        XCTAssertEqual(try doc.nodes(forXPath: "//resources/format").count, 1)
        XCTAssertEqual(try doc.nodes(forXPath: "//resources/format/@width").first?.stringValue, "3840")
        XCTAssertEqual(try doc.nodes(forXPath: "//resources/format/@frameDuration").first?.stringValue, "1/24s")
        XCTAssertEqual(try doc.nodes(forXPath: "//resources/asset").count, 3, "two clips + one WAV")
        XCTAssertEqual(try doc.nodes(forXPath: "//resources/asset/media-rep[@kind='original-media']").count, 3)
        XCTAssertEqual(try doc.nodes(forXPath: "//event/@name").first?.stringValue, "CinemaHUD 2026-09-15")
        XCTAssertEqual(try doc.nodes(forXPath: "//event/sync-clip").count, 1)
        XCTAssertEqual(try doc.nodes(forXPath: "//event/sync-clip/asset-clip").count, 2)
        XCTAssertEqual(try doc.nodes(forXPath: "//event/sync-clip/asset-clip[@lane='-1']/@offset").first?.stringValue, "0s")
        XCTAssertEqual(try doc.nodes(forXPath: "//event/sync-clip/sync-source[@sourceID='storyline']/audio-role-source/@active").first?.stringValue, "0")
        XCTAssertEqual(try doc.nodes(forXPath: "//event/asset-clip").count, 1, "the unpaired clip is a plain asset-clip")
        XCTAssertTrue(xml.contains("file:///Volumes/CARD/PRIVATE/M4ROOT/CLIP/C0001.MP4"))
        XCTAssertTrue(xml.contains("file:///Users/me/Movies/CinemaHUD/2026-09-15/synced/A_0001_C001.wav"))
    }

    func testNamesAreEscaped() throws {
        var c = clip("C0001", duration: 1); c.name = "A & B <x>"
        let xml = FCPXML.document(pairs: [TakePair(clip: c, take: nil, offsetSeconds: nil, confidence: nil, status: .unpaired)],
                                  syncedFolder: URL(fileURLWithPath: "/tmp"), projectFPS: 24, eventName: "E")
        XCTAssertNoThrow(try XMLDocument(xmlString: xml, options: []))
        XCTAssertTrue(xml.contains("A &amp; B &lt;x&gt;"))
    }
}
