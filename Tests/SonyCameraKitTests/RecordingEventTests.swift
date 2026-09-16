import XCTest
@testable import SonyCameraKit

final class RecordingEventTests: XCTestCase {
    func testTransitions() {
        let t = Date()
        XCTAssertEqual(RecordingEvent.transition(wasRecording: false, isRecording: true, at: t), .started(t))
        XCTAssertEqual(RecordingEvent.transition(wasRecording: true, isRecording: false, at: t), .stopped(t))
        XCTAssertNil(RecordingEvent.transition(wasRecording: true, isRecording: true, at: t))
        XCTAssertNil(RecordingEvent.transition(wasRecording: false, isRecording: false, at: t))
    }

    @MainActor func testSessionStartsWithNoEvent() {
        XCTAssertNil(CameraSession().recordingEvent)
    }
}
