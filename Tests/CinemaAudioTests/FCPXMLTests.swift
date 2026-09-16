import XCTest
@testable import CinemaAudio

final class FCPXMLTests: XCTestCase {
    func clip(_ name: String, duration: Double, videoSize: CGSize = CGSize(width: 3840, height: 2160)) -> ClipInfo {
        ClipInfo(id: URL(fileURLWithPath: "/Volumes/CARD/PRIVATE/M4ROOT/CLIP/\(name).MP4"), name: name, duration: duration, creationDate: nil,
                 hasAudio: true, videoSize: videoSize, nominalFrameRate: 23.976)
    }

    func take(channelNames: [String], sampleRate: Double) -> TakeRecord {
        TakeRecord(id: "A_0001_C001", label: TakeLabel(cameraIndex: "A", reel: 1, clip: 1), wavPath: "audio/A_0001_C001.wav",
                   pressedAt: Date(), confirmedStart: nil, confirmedStop: nil, prerollSeconds: 3, sampleRate: sampleRate,
                   channelNames: channelNames, metadata: TakeMetadata(project: "CinemaHUD", projectFPS: 24, scene: nil, note: nil, camera: [:]), outcome: .complete)
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
        let xml = FCPXML.document(pairs: pairs, projectFPS: 24, eventName: "CinemaHUD 2026-09-15")
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

    func testWavAssetDerivesChannelsAndRateFromTheTake() throws {
        let synced = URL(fileURLWithPath: "/tmp/synced")
        let wav = synced.appendingPathComponent("A_0001_C001.wav")
        let t = take(channelNames: ["Boom", "Lav"], sampleRate: 96000)
        let pairs = [TakePair(clip: clip("C0001", duration: 10), take: t, offsetSeconds: 1, confidence: 0.9, status: .exported(wav))]
        let xml = FCPXML.document(pairs: pairs, projectFPS: 24, eventName: "E")
        let doc = try XMLDocument(xmlString: xml, options: [])
        let wavAsset = try XCTUnwrap(doc.nodes(forXPath: "//resources/asset[@name='A_0001_C001']").first as? XMLElement)
        XCTAssertEqual(wavAsset.attribute(forName: "audioChannels")?.stringValue, "2", "two channel names on the take")
        XCTAssertEqual(wavAsset.attribute(forName: "audioRate")?.stringValue, "96000")
    }

    func testWavAssetKeepsDefaultsWithoutATake() throws {
        let synced = URL(fileURLWithPath: "/tmp/synced")
        let wav = synced.appendingPathComponent("A_0001_C001.wav")
        let pairs = [TakePair(clip: clip("C0001", duration: 10), take: nil, offsetSeconds: 1, confidence: 0.9, status: .exported(wav))]
        let xml = FCPXML.document(pairs: pairs, projectFPS: 24, eventName: "E")
        let doc = try XMLDocument(xmlString: xml, options: [])
        let wavAsset = try XCTUnwrap(doc.nodes(forXPath: "//resources/asset[@name='A_0001_C001']").first as? XMLElement)
        XCTAssertEqual(wavAsset.attribute(forName: "audioChannels")?.stringValue, "2")
        XCTAssertEqual(wavAsset.attribute(forName: "audioRate")?.stringValue, "48000")
    }

    func testZeroSizeClipDefaultsToHD() throws {
        // A clip whose video track couldn't be read (videoSize .zero) used to emit
        // `<format width="0" height="0">`, which Final Cut may reject for the whole document.
        let pairs = [TakePair(clip: clip("C0001", duration: 3, videoSize: .zero), take: nil, offsetSeconds: nil, confidence: nil, status: .unpaired)]
        let xml = FCPXML.document(pairs: pairs, projectFPS: 24, eventName: "E")
        let doc = try XMLDocument(xmlString: xml, options: [])
        XCTAssertEqual(try doc.nodes(forXPath: "//resources/format/@width").first?.stringValue, "1920")
        XCTAssertEqual(try doc.nodes(forXPath: "//resources/format/@height").first?.stringValue, "1080")
        XCTAssertEqual(try doc.nodes(forXPath: "//event/asset-clip").count, 1, "the clip is still emitted, not dropped")
    }

    func testNamesAreEscaped() throws {
        var c = clip("C0001", duration: 1); c.name = "A & B <x>"
        let xml = FCPXML.document(pairs: [TakePair(clip: c, take: nil, offsetSeconds: nil, confidence: nil, status: .unpaired)],
                                  projectFPS: 24, eventName: "E")
        XCTAssertNoThrow(try XMLDocument(xmlString: xml, options: []))
        XCTAssertTrue(xml.contains("A &amp; B &lt;x&gt;"))
    }
}
