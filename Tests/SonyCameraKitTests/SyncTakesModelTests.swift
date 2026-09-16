#if os(macOS)
import XCTest
import CinemaAudio
@testable import CinemaUI

final class SyncTakesModelTests: XCTestCase {
    func testMarkMissingFlagsPairsWhoseWAVIsAbsent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("audio"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("audio/A_0001_C001.wav").path, contents: Data())
        func take(_ stem: String) -> TakeRecord {
            TakeRecord(id: stem, label: TakeLabel(cameraIndex: "A", reel: 1, clip: 1), wavPath: "audio/\(stem).wav", pressedAt: Date(), confirmedStart: nil,
                       confirmedStop: nil, prerollSeconds: 3, sampleRate: 48000, channelNames: [], metadata: TakeMetadata(project: "p", projectFPS: 24, scene: nil, note: nil, camera: [:]), outcome: .complete)
        }
        let clip = ClipInfo(id: URL(fileURLWithPath: "/c/C1.MP4"), name: "C1", duration: 1, creationDate: nil, hasAudio: true, videoSize: .zero, nominalFrameRate: 24)
        let pairs = [
            TakePair(clip: clip, take: take("A_0001_C001"), offsetSeconds: 3, confidence: nil, status: .estimated),
            TakePair(clip: clip, take: take("A_0001_C002"), offsetSeconds: 3, confidence: nil, status: .estimated),
            TakePair(clip: clip, take: nil, offsetSeconds: nil, confidence: nil, status: .unpaired),
        ]
        let marked = SyncTakesModel.markMissing(pairs, dayFolder: dir)
        XCTAssertEqual(marked.map(\.status), [.estimated, .missingWAV, .unpaired])
    }
}
#endif
