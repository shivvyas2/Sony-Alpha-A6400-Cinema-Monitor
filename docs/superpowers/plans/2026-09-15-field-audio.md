# Field Audio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** CinemaHUD records a Core Audio interface (Focusrite Scarlett) to a 48 kHz 24-bit WAV per camera take, meters it in the HUD, drives Logic Pro by MTC/MMC, and after the shoot pairs camera clips with WAVs by waveform, writing synced `.mov` files and an FCPXML that Final Cut Pro and Resolve import already in sync.

**Architecture:** A new SwiftPM target `CinemaAudio` (Foundation, AVFoundation, CoreAudio, CoreMIDI, Accelerate; no camera or UI dependency) holds four units: `AudioInput` (devices, engine, meters, 3 s pre-roll ring buffer), `TakeRecorder` (WAV + `takes.json`), `LogicTransport` (virtual MIDI source, MTC + MMC), `TakeSync`/`TakeExport` (pairing, cross-correlation, `.mov` mux, FCPXML). `CameraSession` publishes one new value, `recordingEvent`; `CinemaUI` adds an `AudioSessionController`, an AUDIO item in the bottom strip, and a Sync Takes window; the app adds an Audio menu.

**Tech Stack:** Swift 5.9 toolchain syntax (Swift 6.2 compiler), SwiftPM, AVAudioEngine, AVAudioFile, Core Audio HAL, CoreMIDI, Accelerate vDSP, AVMutableComposition/AVAssetExportSession, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-15-field-audio-design.md`

## Global Constraints

- Minimum macOS 14.0 (`LSMinimumSystemVersion` 14.0); iOS 17 for the shared modules. Every Core Audio HAL and AppKit use in `CinemaAudio`/`CinemaUI` is inside `#if os(macOS)` so the iOS app still builds.
- `CinemaAudio` depends on no other package target. Nothing in it imports SonyCameraKit or SwiftUI.
- WAV: 48 kHz (or the device's rate when 48 kHz is unsupported), 24-bit signed integer PCM, little-endian, interleaved; one file per take.
- File names come from the HUD clip label: `"\(cameraIndex)_\(reel %04d)_C\(clip %03d)"`, e.g. `A_0001_C003`.
- Day folder: `~/Movies/CinemaHUD/<yyyy-MM-dd>/` with `audio/` and `synced/` subfolders and `takes.json`.
- Pre-roll 3 s before the REC press; post-roll 1 s after the camera reports stopped; a take the camera never confirms within 5 s is aborted (file deleted, log entry kept with `outcome`).
- No writes on the audio thread. Meters publish at 30 Hz on the main actor. The frame path in `MonitorView`/`FrameProcessor` is not touched.
- Colour: `Theme.rec` only for recording/clipping, `Theme.warn` for warnings, `Theme.text`/`Theme.dim` otherwise.
- Commits: end every commit message with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Work on branch `field-audio` in the worktree `/Users/shivvyas/Cinema/.claude/worktrees/field-audio`. Run all commands from there. Never use bare `git stash`.
- Run tests with `swift test --filter CinemaAudioTests` (fast) and the full `swift test` before each commit that touches SonyCameraKit or CinemaUI.

---

## File structure

**Create (CinemaAudio target)**
- `Sources/CinemaAudio/RingBuffer.swift` — fixed-length per-channel Float32 ring buffer; `write(_:)`, `read(lastSeconds:)`.
- `Sources/CinemaAudio/Meters.swift` — `MeterMath` (pure dBFS maths) and `MeterState` (@Observable, hold/clip logic).
- `Sources/CinemaAudio/BroadcastWave.swift` — RIFF chunk walker, `bext` + `iXML` writer/reader, RIFF size fix-up.
- `Sources/CinemaAudio/TakeLog.swift` — `TakeLabel`, `TakeMetadata`, `TakeRecord`, `TakeLog` (JSON), `DayFolder`.
- `Sources/CinemaAudio/MIDIMessages.swift` — `MTCRate`, `MIDIMessages` byte builders, `MTCSequencer` (pure quarter-frame scheduler).
- `Sources/CinemaAudio/Correlation.swift` — envelope + normalised cross-correlation + confidence (pure Accelerate).
- `Sources/CinemaAudio/AudioDecoder.swift` — any AVAsset audio → mono Float32 at a given rate.
- `Sources/CinemaAudio/TakeSync.swift` — `ClipInfo`, `TakePair`, `inspect`, `pair`, `estimate`, `offset`.
- `Sources/CinemaAudio/FCPXML.swift` — FCPXML 1.11 string builder.
- `Sources/CinemaAudio/TakeExport.swift` — trimmed WAV, `.mov` with swapped audio.
- `Sources/CinemaAudio/AudioDevices.swift` — macOS HAL device list, channel names, sample rate, change stream.
- `Sources/CinemaAudio/AudioInput.swift` — macOS AVAudioEngine capture; `process(buffer:time:)` is the testable core.
- `Sources/CinemaAudio/TakeRecorder.swift` — take lifecycle → WAV + `takes.json`.
- `Sources/CinemaAudio/LogicTransport.swift` — CoreMIDI virtual source, MTC timer, MMC.
- `Tests/CinemaAudioTests/*.swift` — one file per unit above, plus `TestMedia.swift` (synthetic WAV/movie makers).

**Create (CinemaUI, macOS only)**
- `Sources/CinemaUI/Audio/AudioSessionController.swift` — owns input, recorder, transport; persists choices; reacts to `recordingEvent`.
- `Sources/CinemaUI/Audio/AudioMeterItem.swift` — the AUDIO bottom-strip item.
- `Sources/CinemaUI/Audio/SyncTakesView.swift` — the Sync Takes window content.

**Modify**
- `Package.swift` — add `CinemaAudio` + `CinemaAudioTests`, `CinemaUI` depends on `CinemaAudio`, linker-embedded Info.plist for `CinemaHUD`.
- `Resources/Info.plist` — `NSMicrophoneUsageDescription`.
- `Sources/SonyCameraKit/CameraSession.swift` — `RecordingEvent` + `recordingEvent`.
- `Sources/CinemaUI/HUDBars.swift` — AUDIO item in `BottomStrip.rightItems`; Audio section in the settings panel.
- `Sources/CinemaHUD/CinemaHUDApp.swift` — Audio menu, Sync Takes window, controller in the environment.
- `README.md` — Field audio section, Logic settings, Final Cut import, hardware verification list.

---

### Task 1: Scaffold the CinemaAudio target, tests, and microphone plist

**Files:**
- Modify: `Package.swift`
- Modify: `Resources/Info.plist`
- Create: `Sources/CinemaAudio/CinemaAudio.swift`
- Create: `Tests/CinemaAudioTests/ScaffoldTests.swift`

**Interfaces:**
- Produces: the module name `CinemaAudio` and test target `CinemaAudioTests` every later task uses.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CinemaAudioTests/ScaffoldTests.swift
import XCTest
@testable import CinemaAudio

final class ScaffoldTests: XCTestCase {
    func testModuleVersion() {
        XCTAssertEqual(CinemaAudio.version, "1")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter CinemaAudioTests 2>&1 | tail -5`
Expected: build error, `no such module 'CinemaAudio'`.

- [ ] **Step 3: Add the targets and the plist entry**

Replace `Package.swift` with:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CinemaHUD",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SonyCameraKit", targets: ["SonyCameraKit"]),
        .library(name: "CinemaAudio", targets: ["CinemaAudio"]),
        .library(name: "CinemaUI", targets: ["CinemaUI"]),
        .executable(name: "CinemaHUD", targets: ["CinemaHUD"]),
        .executable(name: "usbprobe", targets: ["usbprobe"]),
    ],
    targets: [
        .target(name: "SonyCameraKit"),
        .target(name: "CinemaAudio"),
        .target(name: "CinemaUI", dependencies: ["SonyCameraKit", "CinemaAudio"]),
        .executableTarget(
            name: "CinemaHUD",
            dependencies: ["SonyCameraKit", "CinemaUI", "CinemaAudio"],
            linkerSettings: [
                // Embed Info.plist in the bare executable so `swift run` builds can use the microphone
                // (macOS terminates a process that touches the mic without NSMicrophoneUsageDescription).
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"])
            ]
        ),
        .executableTarget(name: "usbprobe", dependencies: ["SonyCameraKit"]),
        .testTarget(name: "SonyCameraKitTests", dependencies: ["SonyCameraKit", "CinemaUI"]),
        .testTarget(name: "CinemaAudioTests", dependencies: ["CinemaAudio"]),
    ]
)
```

Create `Sources/CinemaAudio/CinemaAudio.swift`:

```swift
/// Field audio for CinemaHUD: interface capture, take recording, Logic transport, take sync.
public enum CinemaAudio {
    public static let version = "1"
}
```

In `Resources/Info.plist`, after the `NSLocalNetworkUsageDescription` string element, add:

```xml
    <key>NSMicrophoneUsageDescription</key>
    <string>CinemaHUD records your audio interface alongside the camera's video.</string>
```

- [ ] **Step 4: Run the tests and the app build**

Run: `swift test --filter CinemaAudioTests 2>&1 | tail -3`
Expected: `Executed 1 test, with 0 failures`.

Run: `swift build --product CinemaHUD 2>&1 | tail -2 && otool -s __TEXT __info_plist "$(swift build --product CinemaHUD --show-bin-path)/CinemaHUD" | head -3`
Expected: `Build complete`, and the otool output shows a `__info_plist` section (non-empty hex lines).

- [ ] **Step 5: Commit**

```bash
git add Package.swift Resources/Info.plist Sources/CinemaAudio/CinemaAudio.swift Tests/CinemaAudioTests/ScaffoldTests.swift
git commit -m "Field audio: CinemaAudio target, tests, microphone usage string

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: RingBuffer (pre-roll)

**Files:**
- Create: `Sources/CinemaAudio/RingBuffer.swift`
- Test: `Tests/CinemaAudioTests/RingBufferTests.swift`

**Interfaces:**
- Produces: `final class RingBuffer { init(channels: Int, sampleRate: Double, seconds: Double); func write(_ buffer: AVAudioPCMBuffer); func read(lastSeconds: Double) -> AVAudioPCMBuffer; var format: AVAudioFormat }`. Buffers are non-interleaved Float32 (`AVAudioFormat(standardFormatWithSampleRate:channels:)`).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CinemaAudioTests/RingBufferTests.swift
import XCTest
import AVFoundation
@testable import CinemaAudio

final class RingBufferTests: XCTestCase {
    /// A buffer whose channel c sample i is Float(start + i) + c * 1000.
    func ramp(_ format: AVAudioFormat, start: Int, frames: Int) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0 ..< Int(format.channelCount) {
            for i in 0 ..< frames { b.floatChannelData![c][i] = Float(start + i) + Float(c) * 1000 }
        }
        return b
    }

    func testReadReturnsLastSecondsInOrderAcrossWrap() {
        let rb = RingBuffer(channels: 2, sampleRate: 100, seconds: 3)      // capacity 300 frames
        var pos = 0
        for _ in 0 ..< 10 { rb.write(ramp(rb.format, start: pos, frames: 50)); pos += 50 }   // 500 frames written
        let out = rb.read(lastSeconds: 3)
        XCTAssertEqual(out.frameLength, 300)
        XCTAssertEqual(out.floatChannelData![0][0], 200)       // frames 200…499
        XCTAssertEqual(out.floatChannelData![0][299], 499)
        XCTAssertEqual(out.floatChannelData![1][0], 1200)
    }

    func testReadBeforeFullReturnsOnlyWhatWasWritten() {
        let rb = RingBuffer(channels: 1, sampleRate: 100, seconds: 3)
        rb.write(ramp(rb.format, start: 0, frames: 120))
        let out = rb.read(lastSeconds: 3)
        XCTAssertEqual(out.frameLength, 120)
        XCTAssertEqual(out.floatChannelData![0][119], 119)
    }

    func testRequestLongerThanCapacityIsClamped() {
        let rb = RingBuffer(channels: 1, sampleRate: 100, seconds: 1)
        rb.write(ramp(rb.format, start: 0, frames: 250))
        XCTAssertEqual(rb.read(lastSeconds: 10).frameLength, 100)
        XCTAssertEqual(rb.read(lastSeconds: 0.5).frameLength, 50)
        XCTAssertEqual(rb.read(lastSeconds: 0.5).floatChannelData![0][0], 200)
    }

    func testWriteLargerThanCapacityKeepsTail() {
        let rb = RingBuffer(channels: 1, sampleRate: 100, seconds: 1)
        rb.write(ramp(rb.format, start: 0, frames: 1000))
        let out = rb.read(lastSeconds: 1)
        XCTAssertEqual(out.frameLength, 100)
        XCTAssertEqual(out.floatChannelData![0][0], 900)
        XCTAssertEqual(out.floatChannelData![0][99], 999)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter RingBufferTests 2>&1 | tail -3`
Expected: compile error `cannot find 'RingBuffer' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CinemaAudio/RingBuffer.swift
import AVFoundation

/// Fixed-length per-channel Float32 history of the input, so a take can start before the REC press.
/// `write` is called from the audio tap, `read` from the recorder; both are short and lock-guarded.
public final class RingBuffer {
    public let format: AVAudioFormat
    public let capacity: Int
    private var storage: [[Float]]
    private var head = 0            // next write index
    private var filled = 0          // frames valid (≤ capacity)
    private let lock = NSLock()

    public init(channels: Int, sampleRate: Double, seconds: Double) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        capacity = max(1, Int(sampleRate * seconds))
        storage = Array(repeating: [Float](repeating: 0, count: capacity), count: channels)
    }

    public func write(_ buffer: AVAudioPCMBuffer) {
        guard let src = buffer.floatChannelData else { return }
        let channels = min(storage.count, Int(buffer.format.channelCount))
        var frames = Int(buffer.frameLength)
        var srcOffset = 0
        if frames > capacity { srcOffset = frames - capacity; frames = capacity }   // only the tail can survive
        lock.lock(); defer { lock.unlock() }
        var remaining = frames
        var offset = srcOffset
        while remaining > 0 {
            let n = min(remaining, capacity - head)
            for c in 0 ..< channels {
                storage[c].withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.advanced(by: head).update(from: src[c].advanced(by: offset), count: n)
                }
            }
            head = (head + n) % capacity
            offset += n; remaining -= n
        }
        filled = min(capacity, filled + frames)
    }

    /// The most recent `lastSeconds` of audio (clamped to what is stored), oldest frame first.
    public func read(lastSeconds: Double) -> AVAudioPCMBuffer {
        lock.lock(); defer { lock.unlock() }
        let want = min(filled, max(0, Int(lastSeconds * format.sampleRate)))
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, want)))!
        out.frameLength = AVAudioFrameCount(want)
        guard want > 0, let dst = out.floatChannelData else { return out }
        let start = (head - want + capacity) % capacity
        let first = min(want, capacity - start)
        for c in 0 ..< storage.count {
            storage[c].withUnsafeBufferPointer { s in
                dst[c].update(from: s.baseAddress!.advanced(by: start), count: first)
                if want > first { dst[c].advanced(by: first).update(from: s.baseAddress!, count: want - first) }
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter RingBufferTests 2>&1 | tail -3`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaAudio/RingBuffer.swift Tests/CinemaAudioTests/RingBufferTests.swift
git commit -m "Field audio: pre-roll ring buffer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Meters

**Files:**
- Create: `Sources/CinemaAudio/Meters.swift`
- Test: `Tests/CinemaAudioTests/MetersTests.swift`

**Interfaces:**
- Produces: `enum MeterMath { static func measure(_ buffer: AVAudioPCMBuffer) -> [MeterMath.Reading]; static func dBFS(_ linear: Float) -> Float; static let floor: Float = -60 }`, `struct MeterMath.Reading: Equatable { var peak: Float; var rms: Float }` (dBFS), and `@Observable final class MeterState { struct Channel: Equatable { var peak, rms, hold: Float; var clipped: Bool }; private(set) var channels: [Channel]; private(set) var sampleRate: Double; private(set) var deviceName: String; func configure(channels: Int, sampleRate: Double, deviceName: String); func apply(_ readings: [MeterMath.Reading], at now: Date); func resetClip() }`. Hold time 1.5 s, clip threshold −0.1 dBFS.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CinemaAudioTests/MetersTests.swift
import XCTest
import AVFoundation
@testable import CinemaAudio

final class MetersTests: XCTestCase {
    func sine(amplitude: Float, frames: Int = 4800, channels: Int = 1) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: AVAudioChannelCount(channels))!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0 ..< channels { for i in 0 ..< frames { b.floatChannelData![c][i] = amplitude * sin(Float(i) * 2 * .pi * 1000 / 48000) } }
        return b
    }

    func testFullScaleSine() {
        let r = MeterMath.measure(sine(amplitude: 1))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].peak, 0, accuracy: 0.01)
        XCTAssertEqual(r[0].rms, -3.01, accuracy: 0.05)
    }

    func testSilenceIsFloor() {
        let r = MeterMath.measure(sine(amplitude: 0, channels: 2))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].peak, MeterMath.floor)
        XCTAssertEqual(r[1].rms, MeterMath.floor)
    }

    func testClipLatchesAndHoldDecays() {
        let m = MeterState()
        m.configure(channels: 1, sampleRate: 48000, deviceName: "Test")
        let t0 = Date()
        m.apply([.init(peak: -20, rms: -26)], at: t0)
        XCTAssertEqual(m.channels[0].hold, -20)
        XCTAssertFalse(m.channels[0].clipped)
        m.apply([.init(peak: -0.05, rms: -3)], at: t0.addingTimeInterval(0.1))
        XCTAssertTrue(m.channels[0].clipped)
        XCTAssertEqual(m.channels[0].hold, -0.05)
        m.apply([.init(peak: -30, rms: -36)], at: t0.addingTimeInterval(1.0))
        XCTAssertEqual(m.channels[0].hold, -0.05, "hold keeps the peak for 1.5 s")
        m.apply([.init(peak: -30, rms: -36)], at: t0.addingTimeInterval(2.0))
        XCTAssertEqual(m.channels[0].hold, -30, "hold drops to the current peak after 1.5 s")
        XCTAssertTrue(m.channels[0].clipped, "clip stays latched")
        m.resetClip()
        XCTAssertFalse(m.channels[0].clipped)
    }

    func testApplyIgnoresChannelCountMismatch() {
        let m = MeterState()
        m.configure(channels: 2, sampleRate: 48000, deviceName: "Test")
        m.apply([.init(peak: -1, rms: -4)], at: Date())
        XCTAssertEqual(m.channels.map(\.peak), [MeterMath.floor, MeterMath.floor])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MetersTests 2>&1 | tail -3`
Expected: compile error `cannot find 'MeterMath' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CinemaAudio/Meters.swift
import AVFoundation
import Accelerate
import Observation

public enum MeterMath {
    public struct Reading: Equatable, Sendable {
        public var peak: Float   // dBFS
        public var rms: Float    // dBFS
        public init(peak: Float, rms: Float) { self.peak = peak; self.rms = rms }
    }
    public static let floor: Float = -60

    public static func dBFS(_ linear: Float) -> Float {
        guard linear > 0 else { return floor }
        return max(floor, 20 * log10(linear))
    }

    /// Peak and RMS per channel of a non-interleaved Float32 buffer.
    public static func measure(_ buffer: AVAudioPCMBuffer) -> [Reading] {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        let n = vDSP_Length(buffer.frameLength)
        return (0 ..< Int(buffer.format.channelCount)).map { c in
            var peak: Float = 0, rms: Float = 0
            vDSP_maxmgv(data[c], 1, &peak, n)
            vDSP_rmsqv(data[c], 1, &rms, n)
            return Reading(peak: dBFS(peak), rms: dBFS(rms))
        }
    }
}

/// What the HUD draws. Updated on the main actor at ≤ 30 Hz by `AudioInput`.
@Observable
public final class MeterState {
    public struct Channel: Equatable, Sendable {
        public var peak: Float = MeterMath.floor
        public var rms: Float = MeterMath.floor
        public var hold: Float = MeterMath.floor
        public var clipped = false
    }
    public static let holdSeconds: TimeInterval = 1.5
    public static let clipThreshold: Float = -0.1

    public private(set) var channels: [Channel] = []
    public private(set) var sampleRate: Double = 0
    public private(set) var deviceName = ""
    @ObservationIgnored private var holdSince: [Date] = []

    public init() {}

    public func configure(channels: Int, sampleRate: Double, deviceName: String) {
        self.channels = Array(repeating: Channel(), count: channels)
        holdSince = Array(repeating: .distantPast, count: channels)
        self.sampleRate = sampleRate
        self.deviceName = deviceName
    }

    public func apply(_ readings: [MeterMath.Reading], at now: Date) {
        guard readings.count == channels.count else { return }
        for i in readings.indices {
            var ch = channels[i]
            ch.peak = readings[i].peak
            ch.rms = readings[i].rms
            if ch.peak >= ch.hold || now.timeIntervalSince(holdSince[i]) > Self.holdSeconds {
                ch.hold = ch.peak
                holdSince[i] = now
            }
            if ch.peak >= Self.clipThreshold { ch.clipped = true }
            channels[i] = ch
        }
    }

    public func resetClip() {
        for i in channels.indices { channels[i].clipped = false }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter MetersTests 2>&1 | tail -3`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaAudio/Meters.swift Tests/CinemaAudioTests/MetersTests.swift
git commit -m "Field audio: meter maths and meter state

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: BroadcastWave (bext + iXML chunks)

**Files:**
- Create: `Sources/CinemaAudio/BroadcastWave.swift`
- Create: `Tests/CinemaAudioTests/TestMedia.swift`
- Test: `Tests/CinemaAudioTests/BroadcastWaveTests.swift`

**Interfaces:**
- Produces:
  - `struct BroadcastWave.Bext: Equatable { var description, originator, originatorReference: String; var originationDate: String /* yyyy-mm-dd */; var originationTime: String /* hh:mm:ss */; var timeReference: UInt64; var codingHistory: String }`
  - `enum BroadcastWave { static func finalize(url: URL, bext: Bext, ixml: String) throws; static func chunks(url: URL) throws -> [Chunk]; static func readBext(url: URL) throws -> Bext?; static func readIXML(url: URL) throws -> String?; struct Chunk { var id: String; var offset: Int; var size: Int } }`
  - `static func ixml(project: String, scene: String?, take: Int, tape: String, fileUID: String, fps: Int, trackNames: [String]) -> String`
  - `static func timeReference(for date: Date, sampleRate: Double, calendar: Calendar = .current) -> UInt64` (samples since local midnight).
  - `TestMedia.writeWAV(url:seconds:sampleRate:channels:amplitude:frequency:) throws` used by later tests.

- [ ] **Step 1: Write the test helper and failing tests**

```swift
// Tests/CinemaAudioTests/TestMedia.swift
import AVFoundation

enum TestMedia {
    static func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CinemaAudioTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 24-bit WAV of a sine (or silence when amplitude is 0); `mark` adds a 50 ms noise burst at that second.
    static func writeWAV(url: URL, seconds: Double, sampleRate: Double = 48000, channels: Int = 1,
                         amplitude: Float = 0.5, frequency: Float = 440, burstAt: Double? = nil) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(seconds * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        var rng = SystemRandomNumberGenerator()
        for i in 0 ..< frames {
            var v = amplitude * sin(Float(i) * 2 * .pi * frequency / Float(sampleRate))
            if let b = burstAt, Double(i) / sampleRate >= b, Double(i) / sampleRate < b + 0.05 { v = Float.random(in: -0.9 ... 0.9, using: &rng) }
            for c in 0 ..< channels { buf.floatChannelData![c][i] = v }
        }
        try file.write(from: buf)
    }
}
```

```swift
// Tests/CinemaAudioTests/BroadcastWaveTests.swift
import XCTest
import AVFoundation
@testable import CinemaAudio

final class BroadcastWaveTests: XCTestCase {
    func testFinalizeAppendsChunksAndKeepsFileReadable() throws {
        let dir = try TestMedia.tempDir("bwf")
        let url = dir.appendingPathComponent("A_0001_C001.wav")
        try TestMedia.writeWAV(url: url, seconds: 1)
        let bext = BroadcastWave.Bext(description: "A_0001_C001", originator: "CinemaHUD", originatorReference: "ref",
                                      originationDate: "2026-09-15", originationTime: "14:03:20", timeReference: 2_428_800_000,
                                      codingHistory: "A=PCM,F=48000,W=24,M=mono,T=CinemaHUD")
        let ixml = BroadcastWave.ixml(project: "CinemaHUD", scene: "12A", take: 3, tape: "0001", fileUID: "uid", fps: 24, trackNames: ["Input 1"])
        try BroadcastWave.finalize(url: url, bext: bext, ixml: ixml)

        let chunks = try BroadcastWave.chunks(url: url)
        XCTAssertTrue(chunks.contains { $0.id == "fmt " })
        XCTAssertTrue(chunks.contains { $0.id == "data" })
        XCTAssertTrue(chunks.contains { $0.id == "bext" })
        XCTAssertTrue(chunks.contains { $0.id == "iXML" })

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        let header = try Data(contentsOf: url)[4 ..< 8].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(UInt32(littleEndian: header)), size - 8, "RIFF size covers the new chunks")

        XCTAssertEqual(try BroadcastWave.readBext(url: url), bext)
        let back = try XCTUnwrap(BroadcastWave.readIXML(url: url))
        XCTAssertTrue(back.contains("<TAKE>3</TAKE>"))
        XCTAssertTrue(back.contains("<TAPE>0001</TAPE>"))
        XCTAssertTrue(back.contains("<NAME>Input 1</NAME>"))
        XCTAssertTrue(back.contains("<TIMECODE_RATE>24/1</TIMECODE_RATE>"))

        let reopened = try AVAudioFile(forReading: url)
        XCTAssertEqual(reopened.length, 48000)
    }

    func testTimeReferenceIsSamplesSinceMidnight() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 14, minute: 3, second: 20))!
        XCTAssertEqual(BroadcastWave.timeReference(for: date, sampleRate: 48000, calendar: cal), UInt64((14 * 3600 + 3 * 60 + 20) * 48000))
    }

    func testFinalizeTwiceReplacesChunks() throws {
        let dir = try TestMedia.tempDir("bwf2")
        let url = dir.appendingPathComponent("x.wav")
        try TestMedia.writeWAV(url: url, seconds: 0.1)
        let b1 = BroadcastWave.Bext(description: "one", originator: "CinemaHUD", originatorReference: "", originationDate: "2026-09-15", originationTime: "00:00:00", timeReference: 1, codingHistory: "")
        var b2 = b1; b2.description = "two"; b2.timeReference = 2
        try BroadcastWave.finalize(url: url, bext: b1, ixml: "<BWFXML/>")
        try BroadcastWave.finalize(url: url, bext: b2, ixml: "<BWFXML><X/></BWFXML>")
        XCTAssertEqual(try BroadcastWave.chunks(url: url).filter { $0.id == "bext" }.count, 1)
        XCTAssertEqual(try BroadcastWave.readBext(url: url)?.description, "two")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter BroadcastWaveTests 2>&1 | tail -3`
Expected: compile error `cannot find 'BroadcastWave' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CinemaAudio/BroadcastWave.swift
import Foundation

/// Adds Broadcast Wave (`bext`) and `iXML` chunks to a finished WAV so editors see timecode and scene/take.
public enum BroadcastWave {
    public struct Bext: Equatable, Sendable {
        public var description: String        // ≤ 256 ASCII
        public var originator: String         // ≤ 32
        public var originatorReference: String // ≤ 32
        public var originationDate: String    // "yyyy-mm-dd"
        public var originationTime: String    // "hh:mm:ss"
        public var timeReference: UInt64      // samples since midnight
        public var codingHistory: String
        public init(description: String, originator: String, originatorReference: String, originationDate: String,
                    originationTime: String, timeReference: UInt64, codingHistory: String) {
            self.description = description; self.originator = originator; self.originatorReference = originatorReference
            self.originationDate = originationDate; self.originationTime = originationTime
            self.timeReference = timeReference; self.codingHistory = codingHistory
        }
    }
    public struct Chunk: Equatable { public var id: String; public var offset: Int; public var size: Int }   // offset = start of the 8-byte header

    public enum Error: Swift.Error { case notRIFF, truncated }

    // MARK: Reading

    public static func chunks(url: URL) throws -> [Chunk] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 12, String(decoding: data[0 ..< 4], as: UTF8.self) == "RIFF",
              String(decoding: data[8 ..< 12], as: UTF8.self) == "WAVE" else { throw Error.notRIFF }
        var out: [Chunk] = []
        var pos = 12
        while pos + 8 <= data.count {
            let id = String(decoding: data[pos ..< pos + 4], as: UTF8.self)
            let size = Int(le32(data, pos + 4))
            out.append(Chunk(id: id, offset: pos, size: size))
            pos += 8 + size + (size & 1)
        }
        return out
    }

    public static func readBext(url: URL) throws -> Bext? {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard let c = try chunks(url: url).first(where: { $0.id == "bext" }), c.size >= 602 else { return nil }
        let p = c.offset + 8
        func str(_ off: Int, _ len: Int) -> String {
            let s = data[p + off ..< p + off + len]
            return String(decoding: s.prefix { $0 != 0 }, as: UTF8.self)
        }
        let low = UInt64(le32(data, p + 338)), high = UInt64(le32(data, p + 342))
        return Bext(description: str(0, 256), originator: str(256, 32), originatorReference: str(288, 32),
                    originationDate: str(320, 10), originationTime: str(330, 8),
                    timeReference: (high << 32) | low, codingHistory: str(602, c.size - 602))
    }

    public static func readIXML(url: URL) throws -> String? {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard let c = try chunks(url: url).first(where: { $0.id == "iXML" }) else { return nil }
        let body = data[c.offset + 8 ..< c.offset + 8 + c.size]
        return String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: Writing

    /// Appends (or replaces) `bext` and `iXML` and fixes the RIFF size. Call after the audio file is closed.
    public static func finalize(url: URL, bext: Bext, ixml: String) throws {
        var data = try Data(contentsOf: url)
        guard data.count >= 12 else { throw Error.notRIFF }
        // Drop existing bext/iXML chunks so finalize is idempotent.
        var kept = Data(data[0 ..< 12])
        for c in try chunks(url: url) where c.id != "bext" && c.id != "iXML" {
            let end = min(data.count, c.offset + 8 + c.size + (c.size & 1))
            kept.append(data[c.offset ..< end])
        }
        data = kept
        data.append(chunk("bext", bextBody(bext)))
        data.append(chunk("iXML", Data(ixml.utf8)))
        var riffSize = UInt32(data.count - 8).littleEndian
        data.replaceSubrange(4 ..< 8, with: Data(bytes: &riffSize, count: 4))
        try data.write(to: url, options: .atomic)
    }

    static func bextBody(_ b: Bext) -> Data {
        var d = Data()
        d.append(fixed(b.description, 256)); d.append(fixed(b.originator, 32)); d.append(fixed(b.originatorReference, 32))
        d.append(fixed(b.originationDate, 10)); d.append(fixed(b.originationTime, 8))
        d.append(le32Data(UInt32(truncatingIfNeeded: b.timeReference))); d.append(le32Data(UInt32(truncatingIfNeeded: b.timeReference >> 32)))
        var version = UInt16(1).littleEndian; d.append(Data(bytes: &version, count: 2))
        d.append(Data(count: 64))          // UMID
        d.append(Data(count: 10))          // loudness fields (unset)
        d.append(Data(count: 180))         // reserved
        d.append(Data(b.codingHistory.utf8))
        return d
    }

    /// iXML with the fields Final Cut and Resolve read: project, scene, take, tape (reel), track names, frame rate.
    public static func ixml(project: String, scene: String?, take: Int, tape: String, fileUID: String, fps: Int, trackNames: [String]) -> String {
        let tracks = trackNames.enumerated().map {
            "<TRACK><CHANNEL_INDEX>\($0.offset + 1)</CHANNEL_INDEX><INTERLEAVE_INDEX>\($0.offset + 1)</INTERLEAVE_INDEX><NAME>\(escape($0.element))</NAME></TRACK>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <BWFXML><IXML_VERSION>1.5</IXML_VERSION><PROJECT>\(escape(project))</PROJECT><SCENE>\(escape(scene ?? ""))</SCENE><TAKE>\(take)</TAKE><TAPE>\(escape(tape))</TAPE><CIRCLED>FALSE</CIRCLED><FILE_UID>\(escape(fileUID))</FILE_UID><SPEED><MASTER_SPEED>\(fps)/1</MASTER_SPEED><CURRENT_SPEED>\(fps)/1</CURRENT_SPEED><TIMECODE_RATE>\(fps)/1</TIMECODE_RATE><TIMECODE_FLAG>NDF</TIMECODE_FLAG></SPEED><TRACK_LIST><TRACK_COUNT>\(trackNames.count)</TRACK_COUNT>\(tracks)</TRACK_LIST></BWFXML>
        """
    }

    public static func timeReference(for date: Date, sampleRate: Double, calendar: Calendar = .current) -> UInt64 {
        let midnight = calendar.startOfDay(for: date)
        return UInt64(max(0, date.timeIntervalSince(midnight)) * sampleRate)
    }

    // MARK: Bytes

    private static func chunk(_ id: String, _ body: Data) -> Data {
        var d = Data(id.utf8)
        d.append(le32Data(UInt32(body.count)))
        d.append(body)
        if body.count & 1 == 1 { d.append(0) }
        return d
    }
    private static func fixed(_ s: String, _ len: Int) -> Data {
        var d = Data(s.utf8.prefix(len)); d.append(Data(count: len - d.count)); return d
    }
    private static func le32Data(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
    private static func le32(_ d: Data, _ at: Int) -> UInt32 {
        UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
    }
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter BroadcastWaveTests 2>&1 | tail -3`
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaAudio/BroadcastWave.swift Tests/CinemaAudioTests/TestMedia.swift Tests/CinemaAudioTests/BroadcastWaveTests.swift
git commit -m "Field audio: Broadcast Wave bext and iXML chunks

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Take models and the take log

**Files:**
- Create: `Sources/CinemaAudio/TakeLog.swift`
- Test: `Tests/CinemaAudioTests/TakeLogTests.swift`

**Interfaces:**
- Produces:
  - `struct TakeLabel: Codable, Equatable, Sendable { var cameraIndex: String; var reel: Int; var clip: Int; var fileStem: String }` (`fileStem` = `"A_0001_C003"`).
  - `struct TakeMetadata: Codable, Equatable, Sendable { var project: String; var projectFPS: Int; var scene: String?; var note: String?; var camera: [String: String] }`.
  - `struct TakeRecord: Codable, Equatable, Sendable, Identifiable { var id: String; var label: TakeLabel; var wavPath: String; var pressedAt: Date; var confirmedStart: Date?; var confirmedStop: Date?; var prerollSeconds: Double; var sampleRate: Double; var channelNames: [String]; var metadata: TakeMetadata; var outcome: Outcome; enum Outcome: Codable, Equatable, Sendable { case recording, complete, cameraNeverStarted, interrupted(String), writeFailed(String) } }` plus computed `var firstSampleDate: Date` (= pressedAt − prerollSeconds).
  - `struct TakeLog: Codable, Equatable { var takes: [TakeRecord]; static func load(from folder: URL) -> TakeLog; func save(to folder: URL) throws; mutating func upsert(_:) ; static let fileName = "takes.json" }`.
  - `enum DayFolder { static func url(for date: Date, base: URL? = nil) -> URL; static func dayString(_ date: Date) -> String; static func uniqueWAVName(stem: String, in audioFolder: URL) -> String }`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CinemaAudioTests/TakeLogTests.swift
import XCTest
@testable import CinemaAudio

final class TakeLogTests: XCTestCase {
    func record(_ stem: String, clip: Int = 3) -> TakeRecord {
        TakeRecord(id: stem, label: TakeLabel(cameraIndex: "A", reel: 1, clip: clip), wavPath: "audio/\(stem).wav",
                   pressedAt: Date(timeIntervalSince1970: 1_800_000_000), confirmedStart: Date(timeIntervalSince1970: 1_800_000_000.4),
                   confirmedStop: nil, prerollSeconds: 3, sampleRate: 48000, channelNames: ["Input 1", "Input 2"],
                   metadata: TakeMetadata(project: "CinemaHUD", projectFPS: 24, scene: "12A", note: nil, camera: ["iso": "800"]),
                   outcome: .recording)
    }

    func testLabelFileStem() {
        XCTAssertEqual(TakeLabel(cameraIndex: "A", reel: 1, clip: 3).fileStem, "A_0001_C003")
        XCTAssertEqual(TakeLabel(cameraIndex: "B", reel: 12, clip: 120).fileStem, "B_0012_C120")
    }

    func testRoundTripAndUpsert() throws {
        let dir = try TestMedia.tempDir("takelog")
        var log = TakeLog()
        log.upsert(record("A_0001_C003"))
        var r = record("A_0001_C003"); r.outcome = .interrupted("device removed"); r.confirmedStop = Date(timeIntervalSince1970: 1_800_000_010)
        log.upsert(r)
        XCTAssertEqual(log.takes.count, 1)
        try log.save(to: dir)
        let back = TakeLog.load(from: dir)
        XCTAssertEqual(back, log)
        XCTAssertEqual(back.takes[0].outcome, .interrupted("device removed"))
        XCTAssertEqual(back.takes[0].firstSampleDate, Date(timeIntervalSince1970: 1_800_000_000 - 3))
    }

    func testLoadMissingIsEmpty() throws {
        XCTAssertEqual(TakeLog.load(from: try TestMedia.tempDir("empty")).takes, [])
    }

    func testDayFolderAndUniqueNames() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))!
        XCTAssertEqual(DayFolder.dayString(date, calendar: cal), "2026-09-15")
        let base = try TestMedia.tempDir("base")
        XCTAssertEqual(DayFolder.url(for: date, base: base, calendar: cal).lastPathComponent, "2026-09-15")
        let audio = base.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        XCTAssertEqual(DayFolder.uniqueWAVName(stem: "A_0001_C003", in: audio), "A_0001_C003.wav")
        FileManager.default.createFile(atPath: audio.appendingPathComponent("A_0001_C003.wav").path, contents: Data())
        XCTAssertEqual(DayFolder.uniqueWAVName(stem: "A_0001_C003", in: audio), "A_0001_C003_2.wav")
        FileManager.default.createFile(atPath: audio.appendingPathComponent("A_0001_C003_2.wav").path, contents: Data())
        XCTAssertEqual(DayFolder.uniqueWAVName(stem: "A_0001_C003", in: audio), "A_0001_C003_3.wav")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TakeLogTests 2>&1 | tail -3`
Expected: compile error `cannot find 'TakeRecord' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CinemaAudio/TakeLog.swift
import Foundation

public struct TakeLabel: Codable, Equatable, Sendable {
    public var cameraIndex: String
    public var reel: Int
    public var clip: Int
    public init(cameraIndex: String, reel: Int, clip: Int) { self.cameraIndex = cameraIndex; self.reel = reel; self.clip = clip }
    /// "A_0001_C003" — the HUD's clip label with the space replaced, safe as a file name.
    public var fileStem: String { String(format: "%@_%04d_C%03d", cameraIndex, reel, clip) }
}

public struct TakeMetadata: Codable, Equatable, Sendable {
    public var project: String
    public var projectFPS: Int
    public var scene: String?
    public var note: String?
    public var camera: [String: String]
    public init(project: String, projectFPS: Int, scene: String?, note: String?, camera: [String: String]) {
        self.project = project; self.projectFPS = projectFPS; self.scene = scene; self.note = note; self.camera = camera
    }
}

public struct TakeRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: Codable, Equatable, Sendable {
        case recording, complete, cameraNeverStarted, interrupted(String), writeFailed(String)
    }
    public var id: String                 // file stem (unique per day folder)
    public var label: TakeLabel
    public var wavPath: String            // relative to the day folder
    public var pressedAt: Date
    public var confirmedStart: Date?
    public var confirmedStop: Date?
    public var prerollSeconds: Double
    public var sampleRate: Double
    public var channelNames: [String]
    public var metadata: TakeMetadata
    public var outcome: Outcome

    public init(id: String, label: TakeLabel, wavPath: String, pressedAt: Date, confirmedStart: Date?, confirmedStop: Date?,
                prerollSeconds: Double, sampleRate: Double, channelNames: [String], metadata: TakeMetadata, outcome: Outcome) {
        self.id = id; self.label = label; self.wavPath = wavPath; self.pressedAt = pressedAt; self.confirmedStart = confirmedStart
        self.confirmedStop = confirmedStop; self.prerollSeconds = prerollSeconds; self.sampleRate = sampleRate
        self.channelNames = channelNames; self.metadata = metadata; self.outcome = outcome
    }

    /// Wall-clock time of the WAV's first sample.
    public var firstSampleDate: Date { pressedAt.addingTimeInterval(-prerollSeconds) }
}

public struct TakeLog: Codable, Equatable {
    public static let fileName = "takes.json"
    public var takes: [TakeRecord] = []
    public init() {}

    public static func load(from folder: URL) -> TakeLog {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return TakeLog() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(TakeLog.self, from: data)) ?? TakeLog()
    }

    public func save(to folder: URL) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try enc.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public mutating func upsert(_ record: TakeRecord) {
        if let i = takes.firstIndex(where: { $0.id == record.id }) { takes[i] = record } else { takes.append(record) }
    }
}

public enum DayFolder {
    public static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    /// ~/Movies/CinemaHUD/<yyyy-MM-dd> (or `base`/<day> when given).
    public static func url(for date: Date, base: URL? = nil, calendar: Calendar = .current) -> URL {
        let root = base ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("CinemaHUD")
        return root.appendingPathComponent(dayString(date, calendar: calendar))
    }
    /// "<stem>.wav", or "<stem>_2.wav", "<stem>_3.wav" … when the name is taken.
    public static func uniqueWAVName(stem: String, in audioFolder: URL) -> String {
        var name = "\(stem).wav", n = 1
        while FileManager.default.fileExists(atPath: audioFolder.appendingPathComponent(name).path) {
            n += 1; name = "\(stem)_\(n).wav"
        }
        return name
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TakeLogTests 2>&1 | tail -3`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaAudio/TakeLog.swift Tests/CinemaAudioTests/TakeLogTests.swift
git commit -m "Field audio: take records, take log and day folder

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: MIDI messages and the MTC sequencer

**Files:**
- Create: `Sources/CinemaAudio/MIDIMessages.swift`
- Test: `Tests/CinemaAudioTests/MIDIMessagesTests.swift`

**Interfaces:**
- Produces:
  - `enum MTCRate: UInt8 { case fps24 = 0, fps25 = 1, fps30drop = 2, fps30 = 3; init(projectFPS: Int); var framesPerSecond: Int }`.
  - `struct Timecode: Equatable { var h, m, s, f: Int; init(date: Date, fps: Int, calendar: Calendar = .current) }`.
  - `enum MIDIMessages { static func mtcFullFrame(_ tc: Timecode, rate: MTCRate) -> [UInt8]; static func mtcQuarterFrame(index: Int, _ tc: Timecode, rate: MTCRate) -> [UInt8]; static let mmcRecordStrobe, mmcStop, mmcPlay: [UInt8] }`.
  - `final class MTCSequencer { init(rate: MTCRate, clock: @escaping () -> Date, calendar: Calendar = .current); func next() -> [UInt8]; func reset() }` — each call emits the next quarter frame; on index 0 it samples the clock; after a gap > 2 frames or every 10 s it emits a full frame instead and restarts at index 0.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CinemaAudioTests/MIDIMessagesTests.swift
import XCTest
@testable import CinemaAudio

final class MIDIMessagesTests: XCTestCase {
    let tc = Timecode(h: 1, m: 2, s: 3, f: 4)

    func testRateMapping() {
        XCTAssertEqual(MTCRate(projectFPS: 24), .fps24)
        XCTAssertEqual(MTCRate(projectFPS: 25), .fps25)
        XCTAssertEqual(MTCRate(projectFPS: 30), .fps30)
        XCTAssertEqual(MTCRate(projectFPS: 60), .fps30)
        XCTAssertEqual(MTCRate.fps25.framesPerSecond, 25)
    }

    func testFullFrame() {
        // hours byte = rate << 5 | hours; 24 fps → rate 0
        XCTAssertEqual(MIDIMessages.mtcFullFrame(tc, rate: .fps24), [0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x01, 0x02, 0x03, 0x04, 0xF7])
        XCTAssertEqual(MIDIMessages.mtcFullFrame(tc, rate: .fps30)[5], 0x61)
    }

    func testQuarterFrames() {
        let q = (0 ..< 8).map { MIDIMessages.mtcQuarterFrame(index: $0, tc, rate: .fps25) }
        XCTAssertEqual(q, [[0xF1, 0x04], [0xF1, 0x10], [0xF1, 0x23], [0xF1, 0x30], [0xF1, 0x42], [0xF1, 0x50], [0xF1, 0x61], [0xF1, 0x72]])
        // 0x72: index 7 nibble = (rate 1 << 1) | hours high bit 0 = 0b0010
    }

    func testMMC() {
        XCTAssertEqual(MIDIMessages.mmcRecordStrobe, [0xF0, 0x7F, 0x7F, 0x06, 0x06, 0xF7])
        XCTAssertEqual(MIDIMessages.mmcStop, [0xF0, 0x7F, 0x7F, 0x06, 0x01, 0xF7])
        XCTAssertEqual(MIDIMessages.mmcPlay, [0xF0, 0x7F, 0x7F, 0x06, 0x02, 0xF7])
    }

    func testTimecodeFromDate() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 1, minute: 2, second: 3, nanosecond: 500_000_000))!
        XCTAssertEqual(Timecode(date: d, fps: 24, calendar: cal), Timecode(h: 1, m: 2, s: 3, f: 12))
    }

    func testSequencerEmitsFullFrameThenQuarterFramesAndResyncsAfterGap() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var now = cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 1, minute: 2, second: 3))!
        let seq = MTCSequencer(rate: .fps24, clock: { now }, calendar: cal)
        XCTAssertEqual(seq.next()[0], 0xF0, "first message is a full frame")
        // The sequencer samples the clock at index 0; 01:02:03:00 → frames low nibble 0.
        XCTAssertEqual(seq.next(), [0xF1, 0x00])
        for i in 1 ..< 8 { XCTAssertEqual(seq.next()[1] >> 4, UInt8(i)) }
        now = now.addingTimeInterval(1.0)                       // gap of 24 frames
        XCTAssertEqual(seq.next()[0], 0xF0, "resync with a full frame after a gap")
        XCTAssertEqual(seq.next(), [0xF1, 0x00])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MIDIMessagesTests 2>&1 | tail -3`
Expected: compile error `cannot find 'MTCRate' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CinemaAudio/MIDIMessages.swift
import Foundation

public enum MTCRate: UInt8, Sendable {
    case fps24 = 0, fps25 = 1, fps30drop = 2, fps30 = 3
    public init(projectFPS: Int) {
        switch projectFPS { case 24: self = .fps24; case 25: self = .fps25; default: self = .fps30 }
    }
    public var framesPerSecond: Int { self == .fps25 ? 25 : (self == .fps24 ? 24 : 30) }
}

public struct Timecode: Equatable, Sendable {
    public var h: Int, m: Int, s: Int, f: Int
    public init(h: Int, m: Int, s: Int, f: Int) { self.h = h; self.m = m; self.s = s; self.f = f }
    /// Time of day at `fps`, the same numbers the HUD's TC readout shows.
    public init(date: Date, fps: Int, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        h = c.hour ?? 0; m = c.minute ?? 0; s = c.second ?? 0
        f = Int(Double(c.nanosecond ?? 0) / 1e9 * Double(fps))
    }
}

public enum MIDIMessages {
    public static func mtcFullFrame(_ tc: Timecode, rate: MTCRate) -> [UInt8] {
        [0xF0, 0x7F, 0x7F, 0x01, 0x01, UInt8(rate.rawValue << 5) | UInt8(tc.h & 0x1F), UInt8(tc.m), UInt8(tc.s), UInt8(tc.f), 0xF7]
    }
    /// Quarter frame `index` (0…7) for `tc`: F1 followed by (index << 4 | nibble).
    public static func mtcQuarterFrame(index: Int, _ tc: Timecode, rate: MTCRate) -> [UInt8] {
        let nibble: Int
        switch index {
        case 0: nibble = tc.f & 0x0F
        case 1: nibble = (tc.f >> 4) & 0x01
        case 2: nibble = tc.s & 0x0F
        case 3: nibble = (tc.s >> 4) & 0x03
        case 4: nibble = tc.m & 0x0F
        case 5: nibble = (tc.m >> 4) & 0x03
        case 6: nibble = tc.h & 0x0F
        default: nibble = ((tc.h >> 4) & 0x01) | (Int(rate.rawValue) << 1)
        }
        return [0xF1, UInt8(index << 4 | nibble)]
    }
    public static let mmcRecordStrobe: [UInt8] = [0xF0, 0x7F, 0x7F, 0x06, 0x06, 0xF7]
    public static let mmcStop: [UInt8] = [0xF0, 0x7F, 0x7F, 0x06, 0x01, 0xF7]
    public static let mmcPlay: [UInt8] = [0xF0, 0x7F, 0x7F, 0x06, 0x02, 0xF7]
}

/// Decides what to send on each MTC tick (4 × fps per second). Pure: the caller owns the timer.
public final class MTCSequencer {
    public let rate: MTCRate
    private let clock: () -> Date
    private let calendar: Calendar
    private var index = -1            // -1 = send a full frame next
    private var current = Timecode(h: 0, m: 0, s: 0, f: 0)
    private var lastSample: Date?
    private var lastFull: Date?
    public static let fullFrameInterval: TimeInterval = 10

    public init(rate: MTCRate, clock: @escaping () -> Date, calendar: Calendar = .current) {
        self.rate = rate; self.clock = clock; self.calendar = calendar
    }

    public func reset() { index = -1; lastSample = nil; lastFull = nil }

    public func next() -> [UInt8] {
        let now = clock()
        if index == -1 || index == 0 {
            // A quarter-frame sequence spans two frames; if the clock jumped (timer stall, sleep) resync.
            let frame = 1.0 / Double(rate.framesPerSecond)
            let gap = lastSample.map { now.timeIntervalSince($0) - 2 * frame } ?? 0
            let stale = lastFull.map { now.timeIntervalSince($0) > Self.fullFrameInterval } ?? true
            if index == -1 || gap > 2 * frame || stale {
                current = Timecode(date: now, fps: rate.framesPerSecond, calendar: calendar)
                lastSample = now; lastFull = now; index = 0
                return MIDIMessages.mtcFullFrame(current, rate: rate)
            }
            current = Timecode(date: now, fps: rate.framesPerSecond, calendar: calendar)
            lastSample = now
        }
        let msg = MIDIMessages.mtcQuarterFrame(index: index, current, rate: rate)
        index = (index + 1) % 8
        return msg
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter MIDIMessagesTests 2>&1 | tail -3`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaAudio/MIDIMessages.swift Tests/CinemaAudioTests/MIDIMessagesTests.swift
git commit -m "Field audio: MTC and MMC message builders, quarter-frame sequencer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Correlation (envelope + normalised cross-correlation)

**Files:**
- Create: `Sources/CinemaAudio/Correlation.swift`
- Test: `Tests/CinemaAudioTests/CorrelationTests.swift`

**Interfaces:**
- Produces: `enum Correlation { static func envelope(_ x: [Float], window: Int, hop: Int) -> [Float]; static func bestLag(a: [Float], b: [Float], lags: ClosedRange<Int>, minOverlap: Int? = nil) -> Match?; struct Match: Equatable { var lag: Int; var score: Float; var confidence: Double } }`. Semantics: `b[i] ≈ a[i + lag]`, so `lag` is where `b` (the camera clip) starts inside `a` (the WAV). Confidence = z-score of the peak against all other lags divided by 10, clamped to 0…1.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CinemaAudioTests/CorrelationTests.swift
import XCTest
@testable import CinemaAudio

final class CorrelationTests: XCTestCase {
    func noise(_ n: Int, seed: UInt64) -> [Float] {
        var s = seed
        return (0 ..< n).map { _ in s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: s >> 11) % 2000) / 1000 - 1 }
    }

    func testEnvelopeLengthAndValue() {
        let x = [Float](repeating: 0.5, count: 1000)
        let e = Correlation.envelope(x, window: 100, hop: 10)
        XCTAssertEqual(e.count, 91)
        XCTAssertEqual(e[0], 0.5, accuracy: 1e-4)
        XCTAssertEqual(Correlation.envelope([Float](repeating: 0, count: 50), window: 100, hop: 10).count, 0)
    }

    func testFindsKnownLag() throws {
        let a = noise(5000, seed: 1)
        let b = Array(a[1234 ..< 4000])
        let m = try XCTUnwrap(Correlation.bestLag(a: a, b: b, lags: -2000 ... 2000))
        XCTAssertEqual(m.lag, 1234)
        XCTAssertGreaterThan(m.score, 0.99)
        XCTAssertGreaterThanOrEqual(m.confidence, 0.9)
    }

    func testFindsNegativeLagWithPartialOverlap() throws {
        let a = noise(3000, seed: 2)
        var b = noise(500, seed: 3); b.append(contentsOf: a[0 ..< 2500])   // b starts 500 before a
        let m = try XCTUnwrap(Correlation.bestLag(a: a, b: b, lags: -1000 ... 1000))
        XCTAssertEqual(m.lag, -500)
    }

    func testUncorrelatedIsLowConfidence() throws {
        let m = try XCTUnwrap(Correlation.bestLag(a: noise(5000, seed: 4), b: noise(3000, seed: 5), lags: -1000 ... 1000))
        XCTAssertLessThan(m.confidence, 0.5)
    }

    func testEmptyRangeOrSignalsReturnsNil() {
        XCTAssertNil(Correlation.bestLag(a: [], b: [1, 2], lags: 0 ... 1))
        XCTAssertNil(Correlation.bestLag(a: noise(100, seed: 6), b: noise(100, seed: 7), lags: 500 ... 600))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CorrelationTests 2>&1 | tail -3`
Expected: compile error `cannot find 'Correlation' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CinemaAudio/Correlation.swift
import Accelerate

/// Waveform alignment: a coarse RMS envelope makes the search cheap and robust to different mics,
/// then a normalised cross-correlation finds where the clip's audio sits inside the WAV.
public enum Correlation {
    public struct Match: Equatable, Sendable {
        public var lag: Int
        public var score: Float        // normalised correlation at the peak, −1…1
        public var confidence: Double  // 0…1
    }

    /// RMS over `window` samples every `hop` samples.
    public static func envelope(_ x: [Float], window: Int, hop: Int) -> [Float] {
        guard x.count >= window, window > 0, hop > 0 else { return [] }
        let n = (x.count - window) / hop + 1
        var out = [Float](repeating: 0, count: n)
        x.withUnsafeBufferPointer { p in
            for i in 0 ..< n { vDSP_rmsqv(p.baseAddress!.advanced(by: i * hop), 1, &out[i], vDSP_Length(window)) }
        }
        return out
    }

    /// Best lag such that b[i] ≈ a[i + lag]. Both signals are mean-removed. Lags whose overlap is
    /// shorter than `minOverlap` (default half of b) are skipped.
    public static func bestLag(a: [Float], b: [Float], lags: ClosedRange<Int>, minOverlap: Int? = nil) -> Match? {
        guard !a.isEmpty, !b.isEmpty else { return nil }
        let a = centred(a), b = centred(b)
        let need = minOverlap ?? max(1, b.count / 2)
        // Prefix sums of squares give per-lag norms in O(1).
        let a2 = prefixSquares(a), b2 = prefixSquares(b)
        var scores: [(lag: Int, score: Float)] = []
        scores.reserveCapacity(lags.count)
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for lag in lags {
                    let i0 = max(0, -lag)                       // first b index
                    let i1 = min(b.count, a.count - lag)        // one past last b index
                    let n = i1 - i0
                    guard n >= need else { continue }
                    var dot: Float = 0
                    vDSP_dotpr(pb.baseAddress!.advanced(by: i0), 1, pa.baseAddress!.advanced(by: i0 + lag), 1, &dot, vDSP_Length(n))
                    let na = a2[i0 + lag + n] - a2[i0 + lag], nb = b2[i1] - b2[i0]
                    let denom = (na * nb).squareRoot()
                    scores.append((lag, denom > 0 ? dot / denom : 0))
                }
            }
        }
        guard let best = scores.max(by: { $0.score < $1.score }) else { return nil }
        // z-score of the peak against every other lag outside a small exclusion zone.
        let exclusion = max(3, lags.count / 200)
        let rest = scores.filter { abs($0.lag - best.lag) > exclusion }.map(\.score)
        var confidence = 1.0
        if rest.count > 8 {
            let mean = rest.reduce(0, +) / Float(rest.count)
            let variance = rest.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(rest.count)
            let sigma = max(variance.squareRoot(), 1e-6)
            confidence = min(1, max(0, Double((best.score - mean) / sigma) / 10))
        }
        return Match(lag: best.lag, score: best.score, confidence: confidence)
    }

    private static func centred(_ x: [Float]) -> [Float] {
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
        var neg = -mean
        var out = [Float](repeating: 0, count: x.count)
        vDSP_vsadd(x, 1, &neg, &out, 1, vDSP_Length(x.count))
        return out
    }
    private static func prefixSquares(_ x: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: x.count + 1)
        var acc: Float = 0
        for i in x.indices { acc += x[i] * x[i]; out[i + 1] = acc }
        return out
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter CorrelationTests 2>&1 | tail -3`
Expected: `Executed 5 tests, with 0 failures`. If `testUncorrelatedIsLowConfidence` is flaky, the seeds are fixed so it is deterministic; a failure means the z-score divisor is wrong, not the data.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaAudio/Correlation.swift Tests/CinemaAudioTests/CorrelationTests.swift
git commit -m "Field audio: envelope and normalised cross-correlation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: AudioDecoder and TakeSync (inspect, pair, estimate, offset)

**Files:**
- Create: `Sources/CinemaAudio/AudioDecoder.swift`
- Create: `Sources/CinemaAudio/TakeSync.swift`
- Modify: `Tests/CinemaAudioTests/TestMedia.swift` (add `writeMovie`)
- Test: `Tests/CinemaAudioTests/TakeSyncTests.swift`

**Interfaces:**
- Consumes: `Correlation.envelope/bestLag` (Task 7), `TakeRecord` (Task 5).
- Produces:
  - `enum AudioDecoder { static func monoSamples(url: URL, sampleRate: Double, trackIndex: Int? = nil) async throws -> [Float] }` — all audio tracks mixed to mono unless `trackIndex` picks one.
  - `struct ClipInfo: Sendable, Equatable, Identifiable { let id: URL; var url: URL { id }; var name: String; var duration: Double; var creationDate: Date?; var hasAudio: Bool; var videoSize: CGSize; var nominalFrameRate: Double }`.
  - `struct TakePair: Identifiable, Equatable, Sendable { var id: String { clip.id.path }; var clip: ClipInfo; var take: TakeRecord?; var offsetSeconds: Double?; var confidence: Double?; var status: Status; enum Status: Equatable, Sendable { case unpaired, estimated, synced, lowConfidence, missingWAV, exported(URL), failed(String) } }`.
  - `enum TakeSync { static let lowConfidence = 0.5; static func inspect(_ urls: [URL]) async -> [ClipInfo]; static func pair(clips: [ClipInfo], takes: [TakeRecord]) -> [TakePair]; static func estimate(_ take: TakeRecord) -> Double; static func offset(clip: URL, wav: URL, around estimate: Double, window: Double = 10) async throws -> (offset: Double, confidence: Double) }`.
  - `TestMedia.writeMovie(url: URL, seconds: Double, size: CGSize = CGSize(width: 320, height: 180), fps: Int = 24, burstAt: Double? = nil) throws` — H.264 video of a moving bar plus a 48 kHz stereo 16-bit LPCM tone track with an optional noise burst.

- [ ] **Step 1: Add the movie maker to TestMedia**

Append to `Tests/CinemaAudioTests/TestMedia.swift` inside `enum TestMedia`:

```swift
    /// A short H.264 .mp4 with a 440 Hz stereo LPCM tone (16-bit) and an optional 50 ms noise burst.
    static func writeMovie(url: URL, seconds: Double, size: CGSize = CGSize(width: 320, height: 180), fps: Int = 24, burstAt: Double? = nil) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "TestMedia", code: 1) }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(fps))
        for i in 0 ..< frames {
            while !video.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt32.self)
            let stride = CVPixelBufferGetBytesPerRow(pb!) / 4
            let bar = i * Int(size.width) / max(1, frames)
            for y in 0 ..< Int(size.height) { for x in 0 ..< Int(size.width) { base[y * stride + x] = abs(x - bar) < 8 ? 0xFFFFFFFF : 0xFF202020 } }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        video.markAsFinished()

        // Audio in 4800-frame chunks.
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let total = Int(seconds * 48000)
        var rng = SystemRandomNumberGenerator()
        var pos = 0
        while pos < total {
            let n = min(4800, total - pos)
            var bytes = [Int16](repeating: 0, count: n * 2)
            for i in 0 ..< n {
                let t = Double(pos + i) / 48000
                var v = 0.5 * sin(2 * .pi * 440 * t)
                if let b = burstAt, t >= b, t < b + 0.05 { v = Double.random(in: -0.9 ... 0.9, using: &rng) }
                bytes[i * 2] = Int16(v * 32767); bytes[i * 2 + 1] = bytes[i * 2]
            }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 4, blockAllocator: nil, customBlockSource: nil,
                                               offsetToData: 0, dataLength: n * 4, flags: 0, blockBufferOut: &block)
            bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: n * 4) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: n,
                presentationTimeStamp: CMTime(value: CMTimeValue(pos), timescale: 48000), packetDescriptions: nil, sampleBufferOut: &sample)
            while !audio.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            audio.append(sample!)
            pos += n
        }
        audio.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if let e = writer.error { throw e }
    }
```

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/CinemaAudioTests/TakeSyncTests.swift
import XCTest
import AVFoundation
@testable import CinemaAudio

final class TakeSyncTests: XCTestCase {
    func take(_ clip: Int, pressed: TimeInterval, wavSeconds: Double, outcome: TakeRecord.Outcome = .complete) -> TakeRecord {
        let stem = TakeLabel(cameraIndex: "A", reel: 1, clip: clip).fileStem
        return TakeRecord(id: stem, label: TakeLabel(cameraIndex: "A", reel: 1, clip: clip), wavPath: "audio/\(stem).wav",
                          pressedAt: Date(timeIntervalSince1970: pressed), confirmedStart: Date(timeIntervalSince1970: pressed + 0.4),
                          confirmedStop: Date(timeIntervalSince1970: pressed + 0.4 + wavSeconds - 4), prerollSeconds: 3, sampleRate: 48000,
                          channelNames: ["1"], metadata: TakeMetadata(project: "p", projectFPS: 24, scene: nil, note: nil, camera: [:]), outcome: outcome)
    }
    func clip(_ name: String, duration: Double, at: TimeInterval) -> ClipInfo {
        ClipInfo(id: URL(fileURLWithPath: "/tmp/\(name).MP4"), name: name, duration: duration, creationDate: Date(timeIntervalSince1970: at),
                 hasAudio: true, videoSize: CGSize(width: 3840, height: 2160), nominalFrameRate: 23.976)
    }

    func testEstimateUsesPrerollAndConfirmDelay() {
        XCTAssertEqual(TakeSync.estimate(take(1, pressed: 100, wavSeconds: 14)), 3.4, accuracy: 1e-9)
        var t = take(1, pressed: 100, wavSeconds: 14); t.confirmedStart = nil
        XCTAssertEqual(TakeSync.estimate(t), 3)
    }

    func testPairingByOrderAndDuration() {
        // WAV = preroll 3 + 0.4 confirm delay + clip + 1 post-roll → clip ≈ wav − 4 (tolerance max(2 s, 5 %))
        let takes = [take(1, pressed: 100, wavSeconds: 14), take(2, pressed: 200, wavSeconds: 34), take(3, pressed: 300, wavSeconds: 64), take(4, pressed: 400, wavSeconds: 8, outcome: .cameraNeverStarted)]
        let clips = [clip("C0001", duration: 10, at: 50), clip("C0002", duration: 30, at: 150), clip("C0003", duration: 5, at: 250), clip("C0004", duration: 60.5, at: 350)]
        let pairs = TakeSync.pair(clips: clips, takes: takes)
        XCTAssertEqual(pairs.map { $0.take?.label.clip }, [1, 2, nil, 3])
        XCTAssertEqual(pairs[2].status, .unpaired)
        XCTAssertEqual(pairs[3].status, .estimated)
        XCTAssertEqual(pairs[3].offsetSeconds ?? -1, 3.4, accuracy: 1e-9)
    }

    func testPairingSkipsTakeWithoutWAVOnDisk() {
        // Status .missingWAV is assigned by the caller once it checks the disk; pairing itself marks .estimated.
        let pairs = TakeSync.pair(clips: [clip("C1", duration: 10, at: 1)], takes: [take(1, pressed: 0, wavSeconds: 14)])
        XCTAssertEqual(pairs[0].status, .estimated)
    }

    func testInspectFindsClipsInFolderAndReadsDuration() async throws {
        let dir = try TestMedia.tempDir("inspect")
        let clipDir = dir.appendingPathComponent("PRIVATE/M4ROOT/CLIP")
        try FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)
        try TestMedia.writeMovie(url: clipDir.appendingPathComponent("C0001.MP4"), seconds: 2)
        try TestMedia.writeMovie(url: clipDir.appendingPathComponent("C0002.MP4"), seconds: 1)
        FileManager.default.createFile(atPath: clipDir.appendingPathComponent("C0001M01.XML").path, contents: Data())
        let clips = await TakeSync.inspect([dir])
        XCTAssertEqual(clips.map(\.name).sorted(), ["C0001", "C0002"])
        let c1 = try XCTUnwrap(clips.first { $0.name == "C0001" })
        XCTAssertEqual(c1.duration, 2, accuracy: 0.05)
        XCTAssertTrue(c1.hasAudio)
        XCTAssertEqual(c1.videoSize, CGSize(width: 320, height: 180))
        XCTAssertEqual(c1.nominalFrameRate, 24, accuracy: 0.01)
    }

    func testOffsetFindsBurstAlignment() async throws {
        let dir = try TestMedia.tempDir("offset")
        let clip = dir.appendingPathComponent("C0001.MP4"), wav = dir.appendingPathComponent("A_0001_C001.wav")
        // Clip: 6 s, burst at 2.0 s. WAV: 12 s, burst at 5.5 s → clip starts 3.5 s into the WAV.
        try TestMedia.writeMovie(url: clip, seconds: 6, burstAt: 2.0)
        try TestMedia.writeWAV(url: wav, seconds: 12, amplitude: 0.3, frequency: 440, burstAt: 5.5)
        let r = try await TakeSync.offset(clip: clip, wav: wav, around: 3.0, window: 5)
        XCTAssertEqual(r.offset, 3.5, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(r.confidence, 0.9)
    }

    func testDecoderMonoAndTrackSelect() async throws {
        let dir = try TestMedia.tempDir("decode")
        let wav = dir.appendingPathComponent("t.wav")
        try TestMedia.writeWAV(url: wav, seconds: 1, channels: 2, amplitude: 0.5)
        let s = try await AudioDecoder.monoSamples(url: wav, sampleRate: 8000)
        XCTAssertEqual(s.count, 8000, accuracy: 16)
        XCTAssertEqual(s.map(abs).max() ?? 0, 0.5, accuracy: 0.02)
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --filter TakeSyncTests 2>&1 | tail -3`
Expected: compile error `cannot find 'TakeSync' in scope`.

- [ ] **Step 4: Implement the decoder**

```swift
// Sources/CinemaAudio/AudioDecoder.swift
import AVFoundation

/// Decodes any AVFoundation-readable audio (WAV, MP4/MOV tracks) to mono Float32 at `sampleRate`.
public enum AudioDecoder {
    public enum Error: Swift.Error { case noAudioTrack, readerFailed(String) }

    public static func monoSamples(url: URL, sampleRate: Double, trackIndex: Int? = nil) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Error.noAudioTrack }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output: AVAssetReaderOutput
        if let i = trackIndex {
            guard tracks.indices.contains(i) else { throw Error.noAudioTrack }
            output = AVAssetReaderTrackOutput(track: tracks[i], outputSettings: settings)
        } else {
            output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        }
        reader.add(output)
        guard reader.startReading() else { throw Error.readerFailed(reader.error?.localizedDescription ?? "start") }
        var out: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [Float](repeating: 0, count: length / 4)
            bytes.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            out.append(contentsOf: bytes)
        }
        if reader.status == .failed { throw Error.readerFailed(reader.error?.localizedDescription ?? "read") }
        return out
    }
}
```

- [ ] **Step 5: Implement TakeSync**

```swift
// Sources/CinemaAudio/TakeSync.swift
import AVFoundation
import CoreGraphics

public struct ClipInfo: Sendable, Equatable, Identifiable {
    public let id: URL
    public var url: URL { id }
    public var name: String
    public var duration: Double
    public var creationDate: Date?
    public var hasAudio: Bool
    public var videoSize: CGSize
    public var nominalFrameRate: Double
    public init(id: URL, name: String, duration: Double, creationDate: Date?, hasAudio: Bool, videoSize: CGSize, nominalFrameRate: Double) {
        self.id = id; self.name = name; self.duration = duration; self.creationDate = creationDate
        self.hasAudio = hasAudio; self.videoSize = videoSize; self.nominalFrameRate = nominalFrameRate
    }
}

public struct TakePair: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case unpaired, estimated, synced, lowConfidence, missingWAV, exported(URL), failed(String)
    }
    public var id: String { clip.id.path }
    public var clip: ClipInfo
    public var take: TakeRecord?
    public var offsetSeconds: Double?
    public var confidence: Double?
    public var status: Status
    public init(clip: ClipInfo, take: TakeRecord?, offsetSeconds: Double?, confidence: Double?, status: Status) {
        self.clip = clip; self.take = take; self.offsetSeconds = offsetSeconds; self.confidence = confidence; self.status = status
    }
}

public enum TakeSync {
    public static let lowConfidence = 0.5
    public static let postRollSeconds = 1.0
    static let clipExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Files or folders (a card's PRIVATE/M4ROOT/CLIP is walked); clips sorted by creation date then name.
    public static func inspect(_ urls: [URL]) async -> [ClipInfo] {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if clipExtensions.contains(f.pathExtension.lowercased()) { files.append(f) }
                }
            } else if clipExtensions.contains(url.pathExtension.lowercased()) { files.append(url) }
        }
        var clips: [ClipInfo] = []
        for f in files { if let c = try? await info(for: f) { clips.append(c) } }
        return clips.sorted {
            let a = $0.creationDate ?? .distantPast, b = $1.creationDate ?? .distantPast
            return a == b ? $0.name < $1.name : a < b
        }
    }

    static func info(for url: URL) async throws -> ClipInfo {
        let asset = AVURLAsset(url: url)
        let (duration, creation) = try await asset.load(.duration, .creationDate)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var size = CGSize.zero, fps = 0.0
        if let v = video {
            let (natural, transform, rate) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            size = natural.applying(transform); size = CGSize(width: abs(size.width), height: abs(size.height)); fps = Double(rate)
        }
        return ClipInfo(id: url, name: url.deletingPathExtension().lastPathComponent, duration: duration.seconds,
                        creationDate: try await creation?.load(.dateValue), hasAudio: !audio.isEmpty, videoSize: size, nominalFrameRate: fps)
    }

    /// Where clip time 0 is expected inside the WAV, from the take log alone.
    public static func estimate(_ take: TakeRecord) -> Double {
        take.prerollSeconds + (take.confirmedStart.map { $0.timeIntervalSince(take.pressedAt) } ?? 0)
    }

    /// Walk clips and completed takes in time order; a clip takes the next take whose WAV length fits it.
    public static func pair(clips: [ClipInfo], takes: [TakeRecord]) -> [TakePair] {
        let candidates = takes.filter { $0.outcome == .complete }.sorted { $0.pressedAt < $1.pressedAt }
        var next = 0
        return clips.map { clip in
            guard next < candidates.count else { return TakePair(clip: clip, take: nil, offsetSeconds: nil, confidence: nil, status: .unpaired) }
            let t = candidates[next]
            let wavSeconds = (t.confirmedStop ?? t.pressedAt).timeIntervalSince(t.firstSampleDate) + postRollSeconds
            let expected = wavSeconds - estimate(t) - postRollSeconds
            let tolerance = max(2, 0.05 * clip.duration)
            if abs(clip.duration - expected) <= tolerance {
                next += 1
                return TakePair(clip: clip, take: t, offsetSeconds: estimate(t), confidence: nil, status: .estimated)
            }
            return TakePair(clip: clip, take: nil, offsetSeconds: nil, confidence: nil, status: .unpaired)
        }
    }

    /// Sample-accurate offset of the clip inside the WAV: coarse 1 ms envelope search around `estimate`,
    /// then a raw 48 kHz search within ±50 ms of the coarse result.
    public static func offset(clip: URL, wav: URL, around estimate: Double, window: Double = 10) async throws -> (offset: Double, confidence: Double) {
        let coarseRate = 8000.0, hop = 8, win = 160        // 1 ms envelope steps, 20 ms RMS windows
        async let a8 = AudioDecoder.monoSamples(url: wav, sampleRate: coarseRate)
        async let b8 = AudioDecoder.monoSamples(url: clip, sampleRate: coarseRate)
        let ea = Correlation.envelope(try await a8, window: win, hop: hop)
        let eb = Correlation.envelope(try await b8, window: win, hop: hop)
        let centre = Int(estimate * 1000)
        let span = Int(window * 1000)
        guard let coarse = Correlation.bestLag(a: ea, b: eb, lags: (centre - span) ... (centre + span)) else {
            throw AudioDecoder.Error.noAudioTrack
        }
        let fineRate = 48000.0
        async let a48 = AudioDecoder.monoSamples(url: wav, sampleRate: fineRate)
        async let b48 = AudioDecoder.monoSamples(url: clip, sampleRate: fineRate)
        let a = try await a48
        let b = Array(try await b48.prefix(Int(10 * fineRate)))
        let c = coarse.lag * Int(fineRate) / 1000
        let fine = Correlation.bestLag(a: a, b: b, lags: (c - 2400) ... (c + 2400), minOverlap: min(b.count, Int(fineRate)))
        let lag = fine?.lag ?? c
        return (Double(lag) / fineRate, coarse.confidence)
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter TakeSyncTests 2>&1 | tail -3`
Expected: `Executed 6 tests, with 0 failures`. `testOffsetFindsBurstAlignment` takes a few seconds (two decodes at 48 kHz and a 4801-lag fine search).

- [ ] **Step 7: Commit**

```bash
git add Sources/CinemaAudio/AudioDecoder.swift Sources/CinemaAudio/TakeSync.swift Tests/CinemaAudioTests/TestMedia.swift Tests/CinemaAudioTests/TakeSyncTests.swift
git commit -m "Field audio: audio decoder, clip inspection, take pairing and waveform offset

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: FCPXML builder

**Files:**
- Create: `Sources/CinemaAudio/FCPXML.swift`
- Test: `Tests/CinemaAudioTests/FCPXMLTests.swift`

**Interfaces:**
- Consumes: `TakePair`, `ClipInfo` (Task 8).
- Produces: `enum FCPXML { static func document(pairs: [TakePair], syncedFolder: URL, projectFPS: Int, eventName: String) -> String; static func rational(_ seconds: Double, fps: Int) -> String }`. For a pair with `status == .exported(wavURL)` (set by Task 10's export) the sync-clip references `wavURL`; other pairs are plain `asset-clip`s.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CinemaAudioTests/FCPXMLTests.swift
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter FCPXMLTests 2>&1 | tail -3`
Expected: compile error `cannot find 'FCPXML' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CinemaAudio/FCPXML.swift
import Foundation
import CoreGraphics

/// FCPXML 1.11 for Final Cut Pro (File ▸ Import ▸ XML) and Resolve. Each exported pair becomes a
/// sync-clip: the camera clip on the storyline with its own audio muted, the trimmed WAV connected on
/// lane −1 at offset 0 (the WAV already starts with the clip).
public enum FCPXML {
    public static func rational(_ seconds: Double, fps: Int) -> String {
        let frames = Int((seconds * Double(fps)).rounded())
        return frames == 0 ? "0s" : "\(frames)/\(fps)s"
    }

    public static func document(pairs: [TakePair], syncedFolder: URL, projectFPS: Int, eventName: String) -> String {
        var resources: [String] = []
        var items: [String] = []
        var nextID = 1
        func id() -> String { defer { nextID += 1 }; return "r\(nextID)" }

        // One format per distinct picture size.
        var formats: [String: String] = [:]    // "WxH" → id
        for p in pairs {
            let key = "\(Int(p.clip.videoSize.width))x\(Int(p.clip.videoSize.height))"
            if formats[key] == nil {
                let f = id(); formats[key] = f
                resources.append("<format id=\"\(f)\" frameDuration=\"1/\(projectFPS)s\" width=\"\(Int(p.clip.videoSize.width))\" height=\"\(Int(p.clip.videoSize.height))\"/>")
            }
        }

        for p in pairs {
            let key = "\(Int(p.clip.videoSize.width))x\(Int(p.clip.videoSize.height))"
            let format = formats[key]!
            let dur = rational(p.clip.duration, fps: projectFPS)
            let name = escape(p.clip.name)
            let clipID = id()
            resources.append("<asset id=\"\(clipID)\" name=\"\(name)\" start=\"0s\" duration=\"\(dur)\" hasVideo=\"1\" format=\"\(format)\" hasAudio=\"\(p.clip.hasAudio ? 1 : 0)\" audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\"><media-rep kind=\"original-media\" src=\"\(fileURL(p.clip.url))\"/></asset>")
            if case .exported(let wav) = p.status {
                let wavID = id()
                let wavName = escape(wav.deletingPathExtension().lastPathComponent)
                resources.append("<asset id=\"\(wavID)\" name=\"\(wavName)\" start=\"0s\" duration=\"\(dur)\" hasAudio=\"1\" audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\"><media-rep kind=\"original-media\" src=\"\(fileURL(wav))\"/></asset>")
                items.append("""
                <sync-clip name="\(name)" offset="0s" duration="\(dur)" format="\(format)" tcFormat="NDF">
                    <asset-clip ref="\(clipID)" offset="0s" name="\(name)" duration="\(dur)" tcFormat="NDF" audioRole="dialogue"/>
                    <asset-clip ref="\(wavID)" lane="-1" offset="0s" name="\(wavName)" duration="\(dur)" audioRole="dialogue"/>
                    <sync-source sourceID="storyline"><audio-role-source role="dialogue.dialogue-1" active="0"/></sync-source>
                    <sync-source sourceID="connected"><audio-role-source role="dialogue.dialogue-1"/></sync-source>
                </sync-clip>
                """)
            } else {
                items.append("<asset-clip ref=\"\(clipID)\" offset=\"0s\" name=\"\(name)\" duration=\"\(dur)\" format=\"\(format)\" tcFormat=\"NDF\" audioRole=\"dialogue\"/>")
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
            <resources>
                \(resources.joined(separator: "\n        "))
            </resources>
            <library>
                <event name="\(escape(eventName))">
                    \(items.joined(separator: "\n            "))
                </event>
            </library>
        </fcpxml>
        """
    }

    static func fileURL(_ url: URL) -> String { escape(url.standardizedFileURL.absoluteString) }
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter FCPXMLTests 2>&1 | tail -3`
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaAudio/FCPXML.swift Tests/CinemaAudioTests/FCPXMLTests.swift
git commit -m "Field audio: FCPXML 1.11 with synced clips for Final Cut and Resolve

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: TakeExport (trimmed WAV, .mov with swapped audio)

**Files:**
- Create: `Sources/CinemaAudio/TakeExport.swift`
- Test: `Tests/CinemaAudioTests/TakeExportTests.swift`

**Interfaces:**
- Consumes: `BroadcastWave` (Task 4), `TakeRecord` (Task 5), `AudioDecoder` (Task 8).
- Produces:
  - `enum TakeExport { static func trimmedWAV(wav: URL, offset: Double, duration: Double, take: TakeRecord?, to: URL) throws; static func movie(clip: URL, wav: URL, offset: Double, to: URL) async throws; static func outputs(for clip: ClipInfo, take: TakeRecord, in syncedFolder: URL) -> (wav: URL, mov: URL) }`.
  - Trimmed WAV: same rate/channels/24-bit as the source; silence-padded when the source is short; when `take` is given, `bext` is written with `timeReference` = source first-sample reference + `offset × rate` and iXML from the take.
  - Movie: video passthrough, audio track 1 = WAV from `offset` for the clip's duration, audio track 2 = the clip's own audio; `.mov` container.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CinemaAudioTests/TakeExportTests.swift
import XCTest
import AVFoundation
@testable import CinemaAudio

final class TakeExportTests: XCTestCase {
    func take() -> TakeRecord {
        TakeRecord(id: "A_0001_C001", label: TakeLabel(cameraIndex: "A", reel: 1, clip: 1), wavPath: "audio/A_0001_C001.wav",
                   pressedAt: Date(timeIntervalSince1970: 1_800_000_003), confirmedStart: nil, confirmedStop: nil, prerollSeconds: 3,
                   sampleRate: 48000, channelNames: ["Input 1"], metadata: TakeMetadata(project: "CinemaHUD", projectFPS: 24, scene: "1", note: nil, camera: [:]),
                   outcome: .complete)
    }

    func testTrimmedWAVStartsAtOffsetAndShiftsTimeReference() throws {
        let dir = try TestMedia.tempDir("trim")
        let src = dir.appendingPathComponent("A_0001_C001.wav"), out = dir.appendingPathComponent("out.wav")
        try TestMedia.writeWAV(url: src, seconds: 5, amplitude: 0.2, burstAt: 2.0)
        let t = take()
        let ref = BroadcastWave.timeReference(for: t.firstSampleDate, sampleRate: 48000)
        try BroadcastWave.finalize(url: src, bext: .init(description: "A_0001_C001", originator: "CinemaHUD", originatorReference: "", originationDate: "2027-01-15", originationTime: "00:00:00", timeReference: ref, codingHistory: ""), ixml: "<BWFXML/>")
        try TakeExport.trimmedWAV(wav: src, offset: 1.5, duration: 2, take: t, to: out)
        let f = try AVAudioFile(forReading: out)
        XCTAssertEqual(f.length, 96000)
        XCTAssertEqual(f.fileFormat.sampleRate, 48000)
        XCTAssertEqual(f.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
        let bext = try XCTUnwrap(BroadcastWave.readBext(url: out))
        XCTAssertEqual(bext.timeReference, ref + UInt64(1.5 * 48000))
        XCTAssertTrue(try XCTUnwrap(BroadcastWave.readIXML(url: out)).contains("<TAKE>1</TAKE>"))
        let samples = try awaitSamples(out)
        let peakAt = Double(samples.indices.max { abs(samples[$0]) < abs(samples[$1]) }!) / 48000
        XCTAssertEqual(peakAt, 0.5, accuracy: 0.06, "burst at 2.0 s in the source lands at 0.5 s")
    }

    func testTrimmedWAVPadsWithSilence() throws {
        let dir = try TestMedia.tempDir("pad")
        let src = dir.appendingPathComponent("s.wav"), out = dir.appendingPathComponent("o.wav")
        try TestMedia.writeWAV(url: src, seconds: 1)
        try TakeExport.trimmedWAV(wav: src, offset: 0.5, duration: 2, take: nil, to: out)
        XCTAssertEqual(try AVAudioFile(forReading: out).length, 96000)
    }

    func testMovieHasPassthroughVideoAndTwoAudioTracks() async throws {
        let dir = try TestMedia.tempDir("mov")
        let clip = dir.appendingPathComponent("C0001.MP4"), wav = dir.appendingPathComponent("w.wav"), out = dir.appendingPathComponent("C0001_synced.mov")
        try TestMedia.writeMovie(url: clip, seconds: 3, burstAt: 1.0)
        try TestMedia.writeWAV(url: wav, seconds: 8, amplitude: 0.2, burstAt: 3.0)
        try await TakeExport.movie(clip: clip, wav: wav, offset: 2.0, to: out)
        let asset = AVURLAsset(url: out)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 2)
        let desc = try await video[0].load(.formatDescriptions).first
        XCTAssertEqual(desc.map { CMFormatDescriptionGetMediaSubType($0) }, kCMVideoCodecType_H264, "video is passed through")
        XCTAssertEqual(try await asset.load(.duration).seconds, 3, accuracy: 0.05)
        let track1 = try await AudioDecoder.monoSamples(url: out, sampleRate: 48000, trackIndex: 0)
        let peakAt = Double(track1.indices.max { abs(track1[$0]) < abs(track1[$1]) }!) / 48000
        XCTAssertEqual(peakAt, 1.0, accuracy: 0.06, "WAV burst at 3.0 s with offset 2.0 lands at 1.0 s")
    }

    func testOutputNames() {
        let c = ClipInfo(id: URL(fileURLWithPath: "/card/C0007.MP4"), name: "C0007", duration: 1, creationDate: nil, hasAudio: true, videoSize: .zero, nominalFrameRate: 24)
        let o = TakeExport.outputs(for: c, take: take(), in: URL(fileURLWithPath: "/day/synced"))
        XCTAssertEqual(o.wav.path, "/day/synced/A_0001_C001.wav")
        XCTAssertEqual(o.mov.path, "/day/synced/C0007_synced.mov")
    }

    private func awaitSamples(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: b)
        return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TakeExportTests 2>&1 | tail -3`
Expected: compile error `cannot find 'TakeExport' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CinemaAudio/TakeExport.swift
import AVFoundation

public enum TakeExport {
    public enum Error: Swift.Error, LocalizedError {
        case noVideoTrack, exportFailed(String)
        public var errorDescription: String? {
            switch self { case .noVideoTrack: return "The clip has no video track"; case .exportFailed(let s): return "Export failed: \(s)" }
        }
    }

    public static func outputs(for clip: ClipInfo, take: TakeRecord, in syncedFolder: URL) -> (wav: URL, mov: URL) {
        (syncedFolder.appendingPathComponent("\(take.label.fileStem).wav"),
         syncedFolder.appendingPathComponent("\(clip.name)_synced.mov"))
    }

    /// The WAV from `offset` for `duration` seconds, silence-padded, same format, with bext/iXML rewritten.
    public static func trimmedWAV(wav: URL, offset: Double, duration: Double, take: TakeRecord?, to out: URL) throws {
        let src = try AVAudioFile(forReading: wav)
        let rate = src.fileFormat.sampleRate
        let channels = src.processingFormat.channelCount
        var settings = src.fileFormat.settings
        settings[AVLinearPCMBitDepthKey] = 24; settings[AVLinearPCMIsFloatKey] = false; settings[AVLinearPCMIsNonInterleaved] = false
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        // The AVAudioFile must be released (closed) before the chunks are appended, so the copy runs in its own scope.
        func writeSamples() throws {
            let dst = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
            let total = Int(duration * rate)
            let start = Int(offset * rate)
            var written = 0
            let chunk = 48000
            while written < total {
                let n = min(chunk, total - written)
                let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
                buf.frameLength = AVAudioFrameCount(n)                     // zero-filled = silence
                let pos = start + written
                if pos >= 0, pos < Int(src.length) {
                    src.framePosition = AVAudioFramePosition(pos)
                    let avail = min(n, Int(src.length) - pos)
                    let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(avail))!
                    try src.read(into: part, frameCount: AVAudioFrameCount(avail))
                    for c in 0 ..< Int(channels) { buf.floatChannelData![c].update(from: part.floatChannelData![c], count: Int(part.frameLength)) }
                }
                try dst.write(from: buf)
                written += n
            }
        }
        try writeSamples()
        let ref = (try? BroadcastWave.readBext(url: wav)?.timeReference) ?? 0
        let ixml = (try? BroadcastWave.readIXML(url: wav)) ?? "<BWFXML/>"
        let shifted = ref + UInt64(max(0, offset) * rate)
        let stem = out.deletingPathExtension().lastPathComponent
        let day = take.map { DayFolder.dayString($0.firstSampleDate) } ?? DayFolder.dayString(Date())
        let bext = BroadcastWave.Bext(description: stem, originator: "CinemaHUD", originatorReference: take?.id ?? "", originationDate: day,
                                      originationTime: originationTime(shifted, rate: rate), timeReference: shifted,
                                      codingHistory: "A=PCM,F=\(Int(rate)),W=24,M=\(channels == 1 ? "mono" : "stereo"),T=CinemaHUD")
        try BroadcastWave.finalize(url: out, bext: bext, ixml: ixml)
    }

    static func originationTime(_ samplesSinceMidnight: UInt64, rate: Double) -> String {
        let s = Int(Double(samplesSinceMidnight) / rate)
        return String(format: "%02d:%02d:%02d", s / 3600 % 24, s / 60 % 60, s % 60)
    }

    /// Video passthrough + WAV (track 1, from `offset`) + the clip's own audio (track 2), as .mov.
    public static func movie(clip: URL, wav: URL, offset: Double, to out: URL) async throws {
        let clipAsset = AVURLAsset(url: clip), wavAsset = AVURLAsset(url: wav)
        guard let video = try await clipAsset.loadTracks(withMediaType: .video).first else { throw Error.noVideoTrack }
        let duration = try await clipAsset.load(.duration)
        let comp = AVMutableComposition()
        let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)
        v.preferredTransform = try await video.load(.preferredTransform)

        if let wavTrack = try await wavAsset.loadTracks(withMediaType: .audio).first {
            let a1 = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            let wavDuration = try await wavAsset.load(.duration)
            let start = CMTime(seconds: max(0, offset), preferredTimescale: 48000)
            let available = CMTimeSubtract(wavDuration, start)
            let take = CMTimeMinimum(duration, available)
            if take > .zero { try a1.insertTimeRange(CMTimeRange(start: start, duration: take), of: wavTrack, at: .zero) }
            if take < duration { a1.insertEmptyTimeRange(CMTimeRange(start: take, duration: CMTimeSubtract(duration, take))) }
        }
        if let camAudio = try await clipAsset.loadTracks(withMediaType: .audio).first {
            let a2 = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try a2.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: camAudio, at: .zero)
        }

        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw Error.exportFailed("no session") }
        session.outputURL = out
        session.outputFileType = .mov
        session.metadata = try await clipAsset.load(.metadata)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.exportAsynchronously { c.resume() } }
        if session.status != .completed { throw Error.exportFailed(session.error?.localizedDescription ?? "\(session.status.rawValue)") }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TakeExportTests 2>&1 | tail -3`
Expected: `Executed 4 tests, with 0 failures`. Passthrough export accepts LPCM audio into a QuickTime container. If the movie test fails with an export error, print `session.error` and `session.supportedFileTypes` in the test before changing anything; the usual cause is a missing `outputFileType` or an output file that already exists.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaAudio/TakeExport.swift Tests/CinemaAudioTests/TakeExportTests.swift
git commit -m "Field audio: trimmed WAV and passthrough .mov with the interface audio

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: AudioDevices (macOS Core Audio HAL)

**Files:**
- Create: `Sources/CinemaAudio/AudioDevices.swift`
- Test: `Tests/CinemaAudioTests/AudioDevicesTests.swift`

**Interfaces:**
- Produces (all inside `#if os(macOS)`):
  - `struct AudioDevice: Identifiable, Hashable, Sendable { let id: AudioDeviceID; let uid: String; let name: String; let inputChannelNames: [String]; let nominalSampleRate: Double; let supportedSampleRates: [Double]; var shortName: String }` (`shortName` = first two words, uppercased, e.g. "SCARLETT 2I2").
  - `enum AudioDevices { static func inputs() -> [AudioDevice]; static func device(uid: String) -> AudioDevice?; static func setNominalSampleRate(_ rate: Double, on id: AudioDeviceID) throws; static func changes() -> AsyncStream<Void>; enum Error: Swift.Error { case osStatus(OSStatus) } }`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CinemaAudioTests/AudioDevicesTests.swift
#if os(macOS)
import XCTest
import CoreAudio
@testable import CinemaAudio

final class AudioDevicesTests: XCTestCase {
    func testInputsAreWellFormed() {
        for d in AudioDevices.inputs() {
            XCTAssertFalse(d.name.isEmpty)
            XCTAssertFalse(d.uid.isEmpty)
            XCTAssertGreaterThan(d.inputChannelNames.count, 0)
            XCTAssertGreaterThan(d.nominalSampleRate, 0)
            XCTAssertEqual(AudioDevices.device(uid: d.uid)?.id, d.id)
        }
    }

    func testShortName() {
        let d = AudioDevice(id: 1, uid: "u", name: "Scarlett 2i2 USB", inputChannelNames: ["1"], nominalSampleRate: 48000, supportedSampleRates: [48000])
        XCTAssertEqual(d.shortName, "SCARLETT 2I2")
        XCTAssertEqual(AudioDevice(id: 1, uid: "u", name: "MacBook Pro Microphone", inputChannelNames: ["1"], nominalSampleRate: 48000, supportedSampleRates: []).shortName, "MACBOOK PRO")
    }

    func testSettingRateOnBogusDeviceThrows() {
        XCTAssertThrowsError(try AudioDevices.setNominalSampleRate(48000, on: AudioDeviceID(0xFFFF_FFF0)))
    }

    func testChangesStreamCanBeCancelled() async {
        let task = Task { for await _ in AudioDevices.changes() { break } }
        task.cancel()
        _ = await task.result
    }
}
#endif
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter AudioDevicesTests 2>&1 | tail -3`
Expected: compile error `cannot find 'AudioDevices' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CinemaAudio/AudioDevices.swift
#if os(macOS)
import CoreAudio
import Foundation

public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannelNames: [String]
    public let nominalSampleRate: Double
    public let supportedSampleRates: [Double]
    public init(id: AudioDeviceID, uid: String, name: String, inputChannelNames: [String], nominalSampleRate: Double, supportedSampleRates: [Double]) {
        self.id = id; self.uid = uid; self.name = name; self.inputChannelNames = inputChannelNames
        self.nominalSampleRate = nominalSampleRate; self.supportedSampleRates = supportedSampleRates
    }
    /// "SCARLETT 2I2" — what fits in the HUD strip.
    public var shortName: String { name.split(separator: " ").prefix(2).joined(separator: " ").uppercased() }
}

public enum AudioDevices {
    public enum Error: Swift.Error { case osStatus(OSStatus) }

    public static func inputs() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard let ids: [AudioDeviceID] = array(AudioObjectID(kAudioObjectSystemObject), &addr) else { return [] }
        return ids.compactMap { device($0) }
    }

    public static func device(uid: String) -> AudioDevice? { inputs().first { $0.uid == uid } }

    static func device(_ id: AudioDeviceID) -> AudioDevice? {
        let channels = inputChannelCount(id)
        guard channels > 0 else { return nil }
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var ratesAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard let name: String = string(id, &nameAddr), let uid: String = string(id, &uidAddr) else { return nil }
        let rate: Double = scalar(id, &rateAddr) ?? 0
        let ranges: [AudioValueRange] = array(id, &ratesAddr) ?? []
        let rates = Set(ranges.flatMap { [$0.mMinimum, $0.mMaximum] }).sorted()
        let names = (1 ... channels).map { ch -> String in
            var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyElementName, mScope: kAudioObjectPropertyScopeInput, mElement: AudioObjectPropertyElement(ch))
            let n: String? = string(id, &a)
            return (n?.isEmpty == false) ? n! : "Ch \(ch)"
        }
        return AudioDevice(id: id, uid: uid, name: name, inputChannelNames: names, nominalSampleRate: rate, supportedSampleRates: rates)
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func setNominalSampleRate(_ rate: Double, on id: AudioDeviceID) throws {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = rate
        let status = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
        guard status == noErr else { throw Error.osStatus(status) }
    }

    /// Fires when devices are added or removed. Finishes when the consumer stops iterating.
    public static func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in continuation.yield(()) }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.global(qos: .utility), block)
            continuation.onTermination = { _ in
                var a = addr
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.global(qos: .utility), block)
            }
        }
    }

    // MARK: HAL helpers

    private static func scalar<T>(_ id: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> T? {
        var size = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutablePointer<T>.allocate(capacity: 1); defer { p.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, p) == noErr else { return nil }
        return p.pointee
    }
    private static func string(_ id: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> String? {
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }
    private static func array<T>(_ id: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> [T]? {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<T>.size
        var out = [T](unsafeUninitializedCapacity: count) { buf, n in
            n = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf.baseAddress!) == noErr ? count : 0
        }
        if out.count != count { out = [] }
        return out
    }
}
#endif
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter AudioDevicesTests 2>&1 | tail -3`
Expected: `Executed 4 tests, with 0 failures`. On a Mac with no input device at all the first test passes trivially.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaAudio/AudioDevices.swift Tests/CinemaAudioTests/AudioDevicesTests.swift
git commit -m "Field audio: Core Audio input device list, channel names, sample rate, change stream

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: AudioInput (engine, ring buffer, meters, subscriptions)

**Files:**
- Create: `Sources/CinemaAudio/AudioInput.swift`
- Test: `Tests/CinemaAudioTests/AudioInputTests.swift`

**Interfaces:**
- Consumes: `RingBuffer` (Task 2), `MeterMath`/`MeterState` (Task 3), `AudioDevice`/`AudioDevices` (Task 11).
- Produces (macOS):
  - `enum AudioInputInterruption: Equatable, Sendable { case deviceRemoved, configurationChanged, engineStopped(String) }`.
  - `final class AudioInput { init(prerollSeconds: Double = 3); let meters: MeterState; private(set) var isArmed: Bool; private(set) var device: AudioDevice?; private(set) var channels: [Int]; private(set) var sampleRate: Double; var channelNames: [String]; func arm(device: AudioDevice, channels: [Int]) throws; func disarm(); func preroll(seconds: Double) -> AVAudioPCMBuffer; func subscribe(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AnyCancellable; var onInterruption: ((AudioInputInterruption) -> Void)?; static func select(_ buffer: AVAudioPCMBuffer, channels: [Int]) -> AVAudioPCMBuffer }`.
  - Internal for tests: `func configureForTesting(channels: Int, sampleRate: Double, deviceName: String)` and `func process(_ buffer: AVAudioPCMBuffer)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CinemaAudioTests/AudioInputTests.swift
#if os(macOS)
import XCTest
import AVFoundation
import Combine
@testable import CinemaAudio

final class AudioInputTests: XCTestCase {
    func tone(_ format: AVAudioFormat, frames: Int, amplitude: Float) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0 ..< Int(format.channelCount) { for i in 0 ..< frames { b.floatChannelData![c][i] = amplitude * (Float(c) + 1) * sin(Float(i) * 0.1) } }
        return b
    }

    func testSelectPicksChannelsInOrder() {
        let f = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 4)!
        let src = tone(f, frames: 10, amplitude: 0.1)
        let out = AudioInput.select(src, channels: [3, 1])
        XCTAssertEqual(out.format.channelCount, 2)
        XCTAssertEqual(out.frameLength, 10)
        XCTAssertEqual(out.floatChannelData![0][5], src.floatChannelData![2][5])
        XCTAssertEqual(out.floatChannelData![1][5], src.floatChannelData![0][5])
    }

    /// Thread-safe frame counter for the @Sendable sink.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func add(_ v: Int) { lock.lock(); n += v; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testProcessFeedsPrerollSubscribersAndMeters() {
        let input = AudioInput(prerollSeconds: 1)
        input.configureForTesting(channels: 2, sampleRate: 1000, deviceName: "Test")
        let received = Counter()
        let sub = input.subscribe { received.add(Int($0.frameLength)) }
        let f = AVAudioFormat(standardFormatWithSampleRate: 1000, channels: 2)!
        for _ in 0 ..< 5 { input.process(tone(f, frames: 300, amplitude: 0.5)) }
        let pre = input.preroll(seconds: 1)
        XCTAssertEqual(pre.frameLength, 1000)
        let exp = expectation(description: "sink and meters")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(received.value, 1500)
        XCTAssertEqual(input.meters.channels.count, 2)
        XCTAssertGreaterThan(input.meters.channels[1].peak, input.meters.channels[0].peak, "channel 2 is louder")
        XCTAssertEqual(input.channelNames, ["Ch 1", "Ch 2"])
        sub.cancel()
        input.process(tone(f, frames: 100, amplitude: 0.5))
        let exp2 = expectation(description: "after cancel"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp2.fulfill() }
        wait(for: [exp2], timeout: 1)
        XCTAssertEqual(received.value, 1500, "cancelled sink gets nothing")
    }

    func testArmWithUnknownDeviceThrowsAndStaysDisarmed() {
        let input = AudioInput()
        let bogus = AudioDevice(id: 0xFFFF_FFF0, uid: "none", name: "None", inputChannelNames: ["1"], nominalSampleRate: 48000, supportedSampleRates: [48000])
        XCTAssertThrowsError(try input.arm(device: bogus, channels: [1]))
        XCTAssertFalse(input.isArmed)
    }
}
#endif
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter AudioInputTests 2>&1 | tail -3`
Expected: compile error `cannot find 'AudioInput' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CinemaAudio/AudioInput.swift
#if os(macOS)
import AVFoundation
import AudioToolbox
import Combine
import CoreAudio

public enum AudioInputInterruption: Equatable, Sendable {
    case deviceRemoved, configurationChanged, engineStopped(String)
}

/// Captures one Core Audio input device: keeps the last few seconds (pre-roll), meters every buffer,
/// and hands copies to subscribers (the take recorder) on a serial queue. Nothing here touches disk.
public final class AudioInput {
    public enum Error: Swift.Error, LocalizedError {
        case noChannels, deviceUnavailable(OSStatus), engine(String)
        public var errorDescription: String? {
            switch self {
            case .noChannels: return "Pick at least one input channel"
            case .deviceUnavailable(let s): return "Audio device unavailable (\(s))"
            case .engine(let m): return m
            }
        }
    }

    public let meters = MeterState()
    public private(set) var isArmed = false
    public private(set) var device: AudioDevice?
    public private(set) var channels: [Int] = []
    public private(set) var sampleRate: Double = 0
    public var onInterruption: ((AudioInputInterruption) -> Void)?
    public var channelNames: [String] {
        guard let d = device else { return (0 ..< meters.channels.count).map { "Ch \($0 + 1)" } }
        return channels.map { d.inputChannelNames.indices.contains($0 - 1) ? d.inputChannelNames[$0 - 1] : "Ch \($0)" }
    }

    private let prerollSeconds: Double
    private var ring: RingBuffer?
    private var engine: AVAudioEngine?
    private let sinkQueue = DispatchQueue(label: "CinemaHUD.audio.sinks", qos: .userInitiated)
    private var sinks: [UUID: @Sendable (AVAudioPCMBuffer) -> Void] = [:]
    private let sinkLock = NSLock()
    private var lastMeterPublish = Date.distantPast
    private var observers: [Any] = []
    private var deviceWatch: Task<Void, Never>?

    public init(prerollSeconds: Double = 3) { self.prerollSeconds = prerollSeconds }
    deinit { disarm() }

    // MARK: Arm / disarm

    public func arm(device: AudioDevice, channels: [Int]) throws {
        disarm()
        let wanted = channels.filter { $0 >= 1 && $0 <= device.inputChannelNames.count }
        guard !wanted.isEmpty else { throw Error.noChannels }
        if device.nominalSampleRate != 48000, device.supportedSampleRates.contains(48000) {
            try? AudioDevices.setNominalSampleRate(48000, on: device.id)
        }
        let engine = AVAudioEngine()
        guard let unit = engine.inputNode.audioUnit else { throw Error.engine("No input unit") }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw Error.deviceUnavailable(status) }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Error.engine("Device reports no input format") }
        configure(channels: wanted.count, sampleRate: format.sampleRate, deviceName: device.name)
        self.device = device
        self.channels = wanted
        engine.inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.process(Self.select(buffer, channels: wanted))
        }
        engine.prepare()
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw Error.engine(error.localizedDescription)
        }
        self.engine = engine
        isArmed = true
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.interrupt(.configurationChanged)
        })
        let uid = device.uid
        deviceWatch = Task { [weak self] in
            for await _ in AudioDevices.changes() {
                guard !Task.isCancelled else { return }
                if AudioDevices.device(uid: uid) == nil { await MainActor.run { self?.interrupt(.deviceRemoved) }; return }
            }
        }
    }

    public func disarm() {
        deviceWatch?.cancel(); deviceWatch = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isArmed = false
    }

    private func interrupt(_ reason: AudioInputInterruption) {
        guard isArmed else { return }
        disarm()
        onInterruption?(reason)
    }

    // MARK: Buffers

    /// Sets up the ring buffer and meters without an engine (tests, and `arm` before the tap starts).
    func configureForTesting(channels: Int, sampleRate: Double, deviceName: String) {
        configure(channels: channels, sampleRate: sampleRate, deviceName: deviceName)
    }
    private func configure(channels: Int, sampleRate: Double, deviceName: String) {
        ring = RingBuffer(channels: channels, sampleRate: sampleRate, seconds: prerollSeconds)
        self.sampleRate = sampleRate
        meters.configure(channels: channels, sampleRate: sampleRate, deviceName: deviceName)
    }

    /// Called on the audio thread with the selected channels. Copies once, then fans out off-thread.
    func process(_ buffer: AVAudioPCMBuffer) {
        ring?.write(buffer)
        let readings = MeterMath.measure(buffer)
        let now = Date()
        if now.timeIntervalSince(lastMeterPublish) >= 1.0 / 30 {
            lastMeterPublish = now
            DispatchQueue.main.async { [meters] in meters.apply(readings, at: now) }
        }
        sinkLock.lock(); let targets = Array(sinks.values); sinkLock.unlock()
        guard !targets.isEmpty, let copy = Self.copy(buffer) else { return }
        sinkQueue.async { for t in targets { t(copy) } }
    }

    public func preroll(seconds: Double) -> AVAudioPCMBuffer {
        ring?.read(lastSeconds: seconds) ?? AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: 1)!
    }

    public func subscribe(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AnyCancellable {
        let id = UUID()
        sinkLock.lock(); sinks[id] = sink; sinkLock.unlock()
        return AnyCancellable { [weak self] in
            guard let self else { return }
            self.sinkLock.lock(); self.sinks[id] = nil; self.sinkLock.unlock()
        }
    }

    /// A new buffer holding only `channels` (1-based device channel numbers), in that order.
    public static func select(_ buffer: AVAudioPCMBuffer, channels: [Int]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: AVAudioChannelCount(channels.count))!
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength)!
        out.frameLength = buffer.frameLength
        guard let src = buffer.floatChannelData, let dst = out.floatChannelData else { return out }
        let n = Int(buffer.frameLength)
        for (i, ch) in channels.enumerated() {
            let c = min(max(0, ch - 1), Int(buffer.format.channelCount) - 1)
            dst[i].update(from: src[c], count: n)
        }
        return out
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength), let s = buffer.floatChannelData, let d = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        for c in 0 ..< Int(buffer.format.channelCount) { d[c].update(from: s[c], count: Int(buffer.frameLength)) }
        return out
    }
}
#endif
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter AudioInputTests 2>&1 | tail -3`
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Manual check with a real device (record the result in the commit message)**

Create `Sources/CinemaAudio/` nothing; instead run from a scratch script:

```bash
cat > /tmp/audioprobe.swift <<'EOF'
import CinemaAudio
import Foundation
for d in AudioDevices.inputs() { print(d.id, d.uid, d.name, d.inputChannelNames, d.nominalSampleRate, d.supportedSampleRates) }
EOF
swift build 2>&1 | tail -1
swiftc -I "$(swift build --show-bin-path)/Modules" -L "$(swift build --show-bin-path)" -lCinemaAudio /tmp/audioprobe.swift -o /tmp/audioprobe 2>&1 | tail -2 && /tmp/audioprobe
```

Expected: the Scarlett (if plugged in) and the built-in microphone are listed with channel names and rates. If `swiftc` linking fails, skip this step: the unit tests cover the code paths that do not need hardware, and Task 16 exercises the real device through the app.

- [ ] **Step 6: Commit**

```bash
git add Sources/CinemaAudio/AudioInput.swift Tests/CinemaAudioTests/AudioInputTests.swift
git commit -m "Field audio: AVAudioEngine input with pre-roll, meters and subscribers

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: TakeRecorder (WAV per take + takes.json)

**Files:**
- Create: `Sources/CinemaAudio/TakeRecorder.swift`
- Test: `Tests/CinemaAudioTests/TakeRecorderTests.swift`

**Interfaces:**
- Consumes: `AudioInput` (Task 12), `TakeLog`/`TakeRecord`/`DayFolder` (Task 5), `BroadcastWave` (Task 4).
- Produces (macOS):
  - `final class TakeRecorder { static let prerollSeconds = 3.0; static let postRollSeconds = 1.0; init(input: AudioInput, dayFolder: URL, postRoll: Double = TakeRecorder.postRollSeconds); private(set) var current: TakeRecord?; private(set) var log: TakeLog; var onChange: ((TakeRecord) -> Void)?; func begin(label: TakeLabel, metadata: TakeMetadata, pressedAt: Date) throws; func cameraStarted(at: Date); func cameraStopped(at: Date); func abort(reason: TakeRecord.Outcome); var isRecording: Bool }`.
  - `onChange` is called on the main queue after every log change (the UI reads `current`/`log`).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CinemaAudioTests/TakeRecorderTests.swift
#if os(macOS)
import XCTest
import AVFoundation
@testable import CinemaAudio

final class TakeRecorderTests: XCTestCase {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    func buffer(frames: Int, amplitude: Float = 0.3) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0 ..< 2 { for i in 0 ..< frames { b.floatChannelData![c][i] = amplitude * sin(Float(i) * 0.05) } }
        return b
    }
    func metadata() -> TakeMetadata { TakeMetadata(project: "CinemaHUD", projectFPS: 24, scene: "3", note: nil, camera: ["iso": "800"]) }

    func settle(_ seconds: Double = 0.3) {
        let e = expectation(description: "settle"); DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }; wait(for: [e], timeout: seconds + 2)
    }

    func testCompleteTakeWritesWAVWithPrerollAndLog() throws {
        let dir = try TestMedia.tempDir("rec")
        let input = AudioInput(prerollSeconds: 3)
        input.configureForTesting(channels: 2, sampleRate: 48000, deviceName: "Scarlett 2i2 USB")
        for _ in 0 ..< 10 { input.process(buffer(frames: 48000)) }        // 10 s of history; ring keeps 3 s
        let rec = TakeRecorder(input: input, dayFolder: dir, postRoll: 0)
        let t0 = Date()
        try rec.begin(label: TakeLabel(cameraIndex: "A", reel: 1, clip: 1), metadata: metadata(), pressedAt: t0)
        XCTAssertTrue(rec.isRecording)
        XCTAssertEqual(rec.current?.prerollSeconds, 3)
        for _ in 0 ..< 4 { input.process(buffer(frames: 24000)) }         // 2 s live
        settle()
        rec.cameraStarted(at: t0.addingTimeInterval(0.4))
        rec.cameraStopped(at: t0.addingTimeInterval(2.4))
        settle(0.5)
        XCTAssertFalse(rec.isRecording)
        XCTAssertNil(rec.current)
        let log = TakeLog.load(from: dir)
        XCTAssertEqual(log.takes.count, 1)
        let take = log.takes[0]
        XCTAssertEqual(take.id, "A_0001_C001")
        XCTAssertEqual(take.outcome, .complete)
        XCTAssertEqual(take.wavPath, "audio/A_0001_C001.wav")
        XCTAssertEqual(take.channelNames, ["Ch 1", "Ch 2"])
        XCTAssertEqual(take.confirmedStart, t0.addingTimeInterval(0.4))
        let wav = dir.appendingPathComponent(take.wavPath)
        let file = try AVAudioFile(forReading: wav)
        XCTAssertEqual(file.length, 3 * 48000 + 2 * 48000, "3 s pre-roll + 2 s live")
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        let bext = try XCTUnwrap(BroadcastWave.readBext(url: wav))
        XCTAssertEqual(bext.description, "A_0001_C001")
        XCTAssertEqual(bext.timeReference, BroadcastWave.timeReference(for: t0.addingTimeInterval(-3), sampleRate: 48000))
        XCTAssertTrue(try XCTUnwrap(BroadcastWave.readIXML(url: wav)).contains("<SCENE>3</SCENE>"))
    }

    func testAbortDeletesFileKeepsLogEntry() throws {
        let dir = try TestMedia.tempDir("abort")
        let input = AudioInput(prerollSeconds: 1)
        input.configureForTesting(channels: 1, sampleRate: 48000, deviceName: "Test")
        input.process(buffer(frames: 4800))
        let rec = TakeRecorder(input: input, dayFolder: dir, postRoll: 0)
        try rec.begin(label: TakeLabel(cameraIndex: "A", reel: 1, clip: 2), metadata: metadata(), pressedAt: Date())
        settle(0.2)
        rec.abort(reason: .cameraNeverStarted)
        settle(0.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio/A_0001_C002.wav").path))
        XCTAssertEqual(TakeLog.load(from: dir).takes.first?.outcome, .cameraNeverStarted)
        XCTAssertNil(rec.current)
    }

    func testSecondTakeWithSameLabelGetsSuffix() throws {
        let dir = try TestMedia.tempDir("dup")
        let input = AudioInput(prerollSeconds: 1)
        input.configureForTesting(channels: 1, sampleRate: 48000, deviceName: "Test")
        let rec = TakeRecorder(input: input, dayFolder: dir, postRoll: 0)
        for _ in 0 ..< 2 {
            try rec.begin(label: TakeLabel(cameraIndex: "A", reel: 1, clip: 5), metadata: metadata(), pressedAt: Date())
            rec.cameraStarted(at: Date()); rec.cameraStopped(at: Date())
            settle(0.3)
        }
        let log = TakeLog.load(from: dir)
        XCTAssertEqual(log.takes.map(\.wavPath), ["audio/A_0001_C005.wav", "audio/A_0001_C005_2.wav"])
        XCTAssertEqual(log.takes.map(\.id), ["A_0001_C005", "A_0001_C005_2"])
    }

    func testBeginWhileRecordingThrows() throws {
        let dir = try TestMedia.tempDir("busy")
        let input = AudioInput(prerollSeconds: 1)
        input.configureForTesting(channels: 1, sampleRate: 48000, deviceName: "Test")
        let rec = TakeRecorder(input: input, dayFolder: dir, postRoll: 0)
        try rec.begin(label: TakeLabel(cameraIndex: "A", reel: 1, clip: 1), metadata: metadata(), pressedAt: Date())
        XCTAssertThrowsError(try rec.begin(label: TakeLabel(cameraIndex: "A", reel: 1, clip: 2), metadata: metadata(), pressedAt: Date()))
        rec.abort(reason: .cameraNeverStarted)
        settle(0.2)
    }
}
#endif
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TakeRecorderTests 2>&1 | tail -3`
Expected: compile error `cannot find 'TakeRecorder' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CinemaAudio/TakeRecorder.swift
#if os(macOS)
import AVFoundation
import Combine

/// One WAV per camera take, opened on the REC press with pre-roll and closed after the camera stops.
/// All file work happens on `queue`; the audio thread only hands buffers to `AudioInput`.
public final class TakeRecorder {
    public static let prerollSeconds = 3.0
    public static let postRollSeconds = 1.0

    public enum Error: Swift.Error, LocalizedError {
        case busy, notArmed
        public var errorDescription: String? { self == .busy ? "A take is already recording" : "No audio input is armed" }
    }

    public private(set) var current: TakeRecord?
    public private(set) var log: TakeLog
    public var onChange: ((TakeRecord) -> Void)?
    public var isRecording: Bool { current != nil }

    private let input: AudioInput
    private let dayFolder: URL
    private let postRoll: Double
    private let queue = DispatchQueue(label: "CinemaHUD.audio.takes", qos: .userInitiated)
    private var file: AVAudioFile?
    private var subscription: AnyCancellable?
    private var writeError: String?

    public init(input: AudioInput, dayFolder: URL, postRoll: Double = TakeRecorder.postRollSeconds) {
        self.input = input; self.dayFolder = dayFolder; self.postRoll = postRoll
        log = TakeLog.load(from: dayFolder)
    }

    public func begin(label: TakeLabel, metadata: TakeMetadata, pressedAt: Date) throws {
        guard current == nil else { throw Error.busy }
        guard input.sampleRate > 0 else { throw Error.notArmed }
        let audioFolder = dayFolder.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        let name = DayFolder.uniqueWAVName(stem: label.fileStem, in: audioFolder)
        let url = audioFolder.appendingPathComponent(name)
        let pre = input.preroll(seconds: Self.prerollSeconds)
        let channels = Int(pre.format.channelCount)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: input.sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        writeError = nil
        let prerollSeconds = Double(pre.frameLength) / input.sampleRate
        let record = TakeRecord(id: url.deletingPathExtension().lastPathComponent, label: label, wavPath: "audio/\(name)",
                                pressedAt: pressedAt, confirmedStart: nil, confirmedStop: nil, prerollSeconds: prerollSeconds,
                                sampleRate: input.sampleRate, channelNames: input.channelNames, metadata: metadata, outcome: .recording)
        current = record
        queue.async { [weak self] in self?.write(pre) }
        subscription = input.subscribe { [weak self] buffer in
            self?.queue.async { self?.write(buffer) }
        }
        update(record)
    }

    public func cameraStarted(at date: Date) {
        guard var r = current else { return }
        r.confirmedStart = date
        current = r
        update(r)
    }

    public func cameraStopped(at date: Date) {
        guard var r = current else { return }
        r.confirmedStop = date
        current = r
        let delay = postRoll
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.close(outcome: .complete) }
    }

    public func abort(reason: TakeRecord.Outcome) {
        guard current != nil else { return }
        queue.async { [weak self] in self?.close(outcome: reason, deleteFile: true) }
    }

    // MARK: Queue-side

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let file, writeError == nil else { return }
        do { try file.write(from: buffer) } catch {
            writeError = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.abortAfterWriteFailure(error.localizedDescription) }
        }
    }

    private func abortAfterWriteFailure(_ message: String) {
        queue.async { [weak self] in self?.close(outcome: .writeFailed(message), deleteFile: false) }
    }

    private func close(outcome: TakeRecord.Outcome, deleteFile: Bool = false) {
        DispatchQueue.main.sync { subscription?.cancel(); subscription = nil }
        guard var r = DispatchQueue.main.sync(execute: { current }) else { return }
        file = nil                                             // closes the WAV
        let url = dayFolder.appendingPathComponent(r.wavPath)
        let finalizeFile: Bool
        switch outcome { case .complete, .interrupted: finalizeFile = true; default: finalizeFile = false }
        if deleteFile {
            try? FileManager.default.removeItem(at: url)
        } else if finalizeFile {
            let first = r.firstSampleDate
            let bext = BroadcastWave.Bext(description: r.id, originator: "CinemaHUD", originatorReference: r.id,
                                          originationDate: DayFolder.dayString(first),
                                          originationTime: Self.clock(first), timeReference: BroadcastWave.timeReference(for: first, sampleRate: r.sampleRate),
                                          codingHistory: "A=PCM,F=\(Int(r.sampleRate)),W=24,M=\(r.channelNames.count == 1 ? "mono" : "stereo"),T=CinemaHUD")
            let ixml = BroadcastWave.ixml(project: r.metadata.project, scene: r.metadata.scene, take: r.label.clip,
                                          tape: String(format: "%04d", r.label.reel), fileUID: r.id, fps: r.metadata.projectFPS, trackNames: r.channelNames)
            try? BroadcastWave.finalize(url: url, bext: bext, ixml: ixml)
        }
        r.outcome = outcome
        DispatchQueue.main.sync {
            current = nil
            update(r)
        }
    }

    private func update(_ record: TakeRecord) {
        log.upsert(record)
        try? log.save(to: dayFolder)
        onChange?(record)
    }

    private static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
#endif
```

Note for the implementer: `close` runs on `queue` and hops to the main queue with `sync` for the two state touches; `begin`/`cameraStarted`/`cameraStopped`/`abort` must be called on the main queue (the controller in Task 16 does). Never call `close` from the main queue.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TakeRecorderTests 2>&1 | tail -3`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaAudio/TakeRecorder.swift Tests/CinemaAudioTests/TakeRecorderTests.swift
git commit -m "Field audio: take recorder writes a WAV per take with pre-roll and logs it

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: LogicTransport (CoreMIDI virtual source, MTC timer, MMC)

**Files:**
- Create: `Sources/CinemaAudio/LogicTransport.swift`
- Test: `Tests/CinemaAudioTests/LogicTransportTests.swift`

**Interfaces:**
- Consumes: `MTCRate`, `MTCSequencer`, `MIDIMessages` (Task 6).
- Produces (macOS): `final class LogicTransport { init(sourceName: String = "CinemaHUD", send: (([UInt8]) -> Void)? = nil) throws; private(set) var isRunning: Bool; private(set) var rate: MTCRate?; func startTimecode(rate: MTCRate, clock: @escaping () -> Date); func stopTimecode(); func recordStrobe(); func stop(); func play() }`. With `send` nil the transport creates a MIDI client and a virtual source named `sourceName` and sends through CoreMIDI; tests inject `send`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CinemaAudioTests/LogicTransportTests.swift
#if os(macOS)
import XCTest
@testable import CinemaAudio

final class LogicTransportTests: XCTestCase {
    func testTimerSendsQuarterFramesAtFourTimesFPS() throws {
        var sent: [[UInt8]] = []
        let lock = NSLock()
        let t = try LogicTransport(send: { m in lock.lock(); sent.append(m); lock.unlock() })
        t.startTimecode(rate: .fps24, clock: { Date() })
        XCTAssertTrue(t.isRunning)
        XCTAssertEqual(t.rate, .fps24)
        let e = expectation(description: "ticks"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { e.fulfill() }; wait(for: [e], timeout: 2)
        t.stopTimecode()
        XCTAssertFalse(t.isRunning)
        lock.lock(); let snapshot = sent; lock.unlock()
        XCTAssertEqual(snapshot.first?.first, 0xF0, "starts with a full frame")
        XCTAssertGreaterThanOrEqual(snapshot.count, 36, "≥ 75 % of the 48 messages expected in 0.5 s at 96 Hz")
        XCTAssertTrue(snapshot.dropFirst().allSatisfy { $0[0] == 0xF1 || $0[0] == 0xF0 })
        let e2 = expectation(description: "quiet"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { e2.fulfill() }; wait(for: [e2], timeout: 1)
        lock.lock(); XCTAssertEqual(sent.count, snapshot.count, "nothing after stop"); lock.unlock()
    }

    func testTransportMessages() throws {
        var sent: [[UInt8]] = []
        let t = try LogicTransport(send: { sent.append($0) })
        t.recordStrobe(); t.stop(); t.play()
        XCTAssertEqual(sent, [MIDIMessages.mmcRecordStrobe, MIDIMessages.mmcStop, MIDIMessages.mmcPlay])
    }

    func testRealSourceCanBeCreated() throws {
        let t = try LogicTransport(sourceName: "CinemaHUD Test")
        t.recordStrobe()          // must not crash without a receiver
        t.stop()
    }
}
#endif
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter LogicTransportTests 2>&1 | tail -3`
Expected: compile error `cannot find 'LogicTransport' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CinemaAudio/LogicTransport.swift
#if os(macOS)
import CoreMIDI
import Foundation

/// A virtual MIDI source Logic can chase: MIDI Timecode at the project rate plus MMC record/stop.
public final class LogicTransport {
    public enum Error: Swift.Error { case midi(OSStatus) }

    public private(set) var isRunning = false
    public private(set) var rate: MTCRate?

    private let send: ([UInt8]) -> Void
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "CinemaHUD.mtc", qos: .userInteractive)

    public init(sourceName: String = "CinemaHUD", send: (([UInt8]) -> Void)? = nil) throws {
        if let send { self.send = send; return }
        var client = MIDIClientRef(), source = MIDIEndpointRef()
        var status = MIDIClientCreateWithBlock(sourceName as CFString, &client) { _ in }
        guard status == noErr else { throw Error.midi(status) }
        status = MIDISourceCreate(client, sourceName as CFString, &source)
        guard status == noErr else { MIDIClientDispose(client); throw Error.midi(status) }
        self.client = client; self.source = source
        self.send = { bytes in
            var list = MIDIPacketList()
            var packet = MIDIPacketListInit(&list)
            packet = MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
            MIDIReceived(source, &list)
        }
    }

    deinit {
        stopTimecode()
        if source != 0 { MIDIEndpointDispose(source) }
        if client != 0 { MIDIClientDispose(client) }
    }

    public func startTimecode(rate: MTCRate, clock: @escaping () -> Date) {
        stopTimecode()
        self.rate = rate
        let sequencer = MTCSequencer(rate: rate, clock: clock)
        let interval = 1.0 / (4.0 * Double(rate.framesPerSecond))
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(200))
        t.setEventHandler { [send] in send(sequencer.next()) }
        t.resume()
        timer = t
        isRunning = true
    }

    public func stopTimecode() {
        timer?.cancel(); timer = nil
        isRunning = false
    }

    public func recordStrobe() { send(MIDIMessages.mmcRecordStrobe) }
    public func stop() { send(MIDIMessages.mmcStop) }
    public func play() { send(MIDIMessages.mmcPlay) }
}
#endif
```

`MIDIReceived` and `MIDIPacketListAdd` are deprecated in favour of the UMP event-list API but still work on macOS 14–26; the deprecation warnings are accepted (UMP would need MIDI 2.0 packet encoding for no benefit here).

- [ ] **Step 4: Run the tests**

Run: `swift test --filter LogicTransportTests 2>&1 | tail -3`
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaAudio/LogicTransport.swift Tests/CinemaAudioTests/LogicTransportTests.swift
git commit -m "Field audio: virtual MIDI source sending MTC and MMC for Logic

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 15: CameraSession.recordingEvent

**Files:**
- Modify: `Sources/SonyCameraKit/CameraSession.swift` (properties near line 33; `startStateLoop` at ~176–195; `toggleRecording` at ~392)
- Test: `Tests/SonyCameraKitTests/RecordingEventTests.swift`

**Interfaces:**
- Produces: `public enum RecordingEvent: Equatable, Sendable { case pressed(Date), started(Date), stopped(Date); static func transition(wasRecording: Bool, isRecording: Bool, at: Date) -> RecordingEvent? }` and `CameraSession.recordingEvent: RecordingEvent?` (observable). Task 16 observes it with `onChange`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SonyCameraKitTests/RecordingEventTests.swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter RecordingEventTests 2>&1 | tail -3`
Expected: compile error `cannot find 'RecordingEvent' in scope`.

- [ ] **Step 3: Implement**

Add above `@Observable public final class CameraSession` in `CameraSession.swift`:

```swift
/// Recording milestones for anything that runs alongside the camera (the field audio recorder):
/// the REC press on the Mac, and the body's own confirmed start and stop.
public enum RecordingEvent: Equatable, Sendable {
    case pressed(Date), started(Date), stopped(Date)

    public static func transition(wasRecording: Bool, isRecording: Bool, at date: Date) -> RecordingEvent? {
        switch (wasRecording, isRecording) {
        case (false, true): return .started(date)
        case (true, false): return .stopped(date)
        default: return nil
        }
    }
}
```

Add the property after `public private(set) var takes = 0`:

```swift
    /// Latest recording milestone (see `RecordingEvent`). Observers use `onChange` on this value.
    public private(set) var recordingEvent: RecordingEvent?
```

In `startStateLoop`, replace

```swift
                    if !wasRecording && s.isRecording { self.takes += 1 }
```

with

```swift
                    if !wasRecording && s.isRecording { self.takes += 1 }
                    if let e = RecordingEvent.transition(wasRecording: wasRecording, isRecording: s.isRecording, at: Date()) { self.recordingEvent = e }
```

Replace `toggleRecording`:

```swift
    public func toggleRecording() async {
        if state.isRecording { await perform("Stop REC") { try await $0.stopMovie() } }
        else {
            recordingEvent = .pressed(Date())
            await perform("REC") { try await $0.startMovie() }
        }
    }
```

- [ ] **Step 4: Run the full test suite**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass (`with 0 failures`).

- [ ] **Step 5: Commit**

```bash
git add Sources/SonyCameraKit/CameraSession.swift Tests/SonyCameraKitTests/RecordingEventTests.swift
git commit -m "CameraSession: publish recording milestones (pressed, started, stopped)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 16: AudioSessionController (CinemaUI, macOS)

**Files:**
- Create: `Sources/CinemaUI/Audio/AudioSessionController.swift`
- Test: `Tests/SonyCameraKitTests/AudioSessionControllerTests.swift`

**Interfaces:**
- Consumes: `AudioInput`, `AudioDevices`, `AudioDevice`, `TakeRecorder`, `TakeLabel`, `TakeMetadata`, `TakeRecord`, `LogicTransport`, `MTCRate`, `DayFolder`, `MeterState` (CinemaAudio); `RecordingEvent`, `CameraState` (SonyCameraKit).
- Produces (macOS):
  - `@Observable public final class AudioSessionController { enum Permission { case unknown, granted, denied }; private(set) var permission: Permission; private(set) var devices: [AudioDevice]; private(set) var selectedDeviceUID: String?; private(set) var selectedChannels: [Int]; var sendTimecode: Bool; var scene: String; var note: String; var projectFPS: Int; private(set) var isArmed: Bool; private(set) var armError: String?; private(set) var interruption: String?; var meters: MeterState; private(set) var currentTake: TakeRecord?; private(set) var takes: [TakeRecord]; private(set) var transportRunning: Bool; let dayFolder: URL; init(base: URL? = nil, defaults: UserDefaults = .standard); func refreshDevices(); func arm(deviceUID: String?, channels: [Int]) async; func setChannels(_:) async; func disarm(); func handle(_ event: RecordingEvent, label: TakeLabel, metadata: TakeMetadata); func resetClip(); var selectedDevice: AudioDevice? }`
  - `static func label(for event: RecordingEvent, takes: Int, cameraIndex: String, reel: Int) -> TakeLabel`
  - `static func metadata(state: CameraState, projectFPS: Int, scene: String, note: String) -> TakeMetadata`
  - `static let confirmTimeout: TimeInterval = 5`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SonyCameraKitTests/AudioSessionControllerTests.swift
#if os(macOS)
import XCTest
import CinemaAudio
@testable import SonyCameraKit
@testable import CinemaUI

final class AudioSessionControllerTests: XCTestCase {
    func testLabelUsesNextTakeOnPressAndCurrentTakeOnStart() {
        let t = Date()
        XCTAssertEqual(AudioSessionController.label(for: .pressed(t), takes: 2, cameraIndex: "A", reel: 1).fileStem, "A_0001_C003")
        XCTAssertEqual(AudioSessionController.label(for: .started(t), takes: 3, cameraIndex: "A", reel: 1).fileStem, "A_0001_C003")
        XCTAssertEqual(AudioSessionController.label(for: .stopped(t), takes: 3, cameraIndex: "B", reel: 7).fileStem, "B_0007_C003")
        XCTAssertEqual(AudioSessionController.label(for: .started(t), takes: 0, cameraIndex: "A", reel: 1).clip, 1, "never below 1")
    }

    func testMetadataSnapshot() {
        var s = CameraState()
        s.shutterSpeed = "1/50"; s.fNumber = "2.8"; s.iso = "800"; s.focusMode = "MF"; s.exposureMode = "Manual"; s.whiteBalanceMode = "Daylight"
        let m = AudioSessionController.metadata(state: s, projectFPS: 25, scene: "12A", note: "wide")
        XCTAssertEqual(m.project, "CinemaHUD")
        XCTAssertEqual(m.projectFPS, 25)
        XCTAssertEqual(m.scene, "12A")
        XCTAssertEqual(m.note, "wide")
        XCTAssertEqual(m.camera, ["shutter": "1/50", "iris": "2.8", "iso": "800", "focus": "MF", "mode": "Manual", "wb": "Daylight"])
        XCTAssertNil(AudioSessionController.metadata(state: CameraState(), projectFPS: 24, scene: "", note: "").scene, "empty scene is nil")
    }

    @MainActor func testPersistsChoicesAndIgnoresEventsWhenDisarmed() throws {
        let suite = "AudioSessionControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let c = AudioSessionController(base: base, defaults: defaults)
        XCTAssertFalse(c.isArmed)
        c.sendTimecode = true; c.scene = "5"; c.note = "n"
        c.handle(.pressed(Date()), label: TakeLabel(cameraIndex: "A", reel: 1, clip: 1), metadata: TakeMetadata(project: "CinemaHUD", projectFPS: 24, scene: nil, note: nil, camera: [:]))
        XCTAssertNil(c.currentTake)
        let again = AudioSessionController(base: base, defaults: defaults)
        XCTAssertTrue(again.sendTimecode)
        XCTAssertEqual(again.scene, "5")
        XCTAssertEqual(again.dayFolder.lastPathComponent, DayFolder.dayString(Date()))
    }
}
#endif
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter AudioSessionControllerTests 2>&1 | tail -3`
Expected: compile error `cannot find 'AudioSessionController' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CinemaUI/Audio/AudioSessionController.swift
#if os(macOS)
import AVFoundation
import Foundation
import Observation
import CinemaAudio
import SonyCameraKit

/// Owns the field-audio pieces for the Mac app: the armed input, the take recorder, the Logic
/// transport, and the user's choices. The view feeds it `RecordingEvent`s; it never calls the camera.
@Observable
@MainActor
public final class AudioSessionController {
    public enum Permission: Equatable { case unknown, granted, denied }
    public static let confirmTimeout: TimeInterval = 5

    public private(set) var permission: Permission = .unknown
    public private(set) var devices: [AudioDevice] = []
    public private(set) var selectedDeviceUID: String?
    public private(set) var selectedChannels: [Int] = [1, 2]
    public var sendTimecode = false { didSet { defaults.set(sendTimecode, forKey: Keys.mtc); updateTransport() } }
    public var scene = "" { didSet { defaults.set(scene, forKey: Keys.scene) } }
    public var note = ""
    public var projectFPS = 24 { didSet { if projectFPS != oldValue { updateTransport() } } }
    public private(set) var isArmed = false
    public private(set) var armError: String?
    public private(set) var interruption: String?
    public private(set) var currentTake: TakeRecord?
    public private(set) var takes: [TakeRecord] = []
    public private(set) var transportRunning = false
    public let dayFolder: URL
    public var meters: MeterState { input.meters }
    public var selectedDevice: AudioDevice? { selectedDeviceUID.flatMap { uid in devices.first { $0.uid == uid } } }
    public var mtcRate: MTCRate { MTCRate(projectFPS: projectFPS) }

    @ObservationIgnored private let input = AudioInput(prerollSeconds: TakeRecorder.prerollSeconds)
    @ObservationIgnored private var recorder: TakeRecorder
    @ObservationIgnored private var transport: LogicTransport?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var confirmTimer: Task<Void, Never>?
    @ObservationIgnored private var deviceWatch: Task<Void, Never>?
    private enum Keys { static let device = "audio.deviceUID", channels = "audio.channels", mtc = "audio.mtc", scene = "audio.scene" }

    public init(base: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dayFolder = DayFolder.url(for: Date(), base: base)
        recorder = TakeRecorder(input: input, dayFolder: dayFolder)
        selectedDeviceUID = defaults.string(forKey: Keys.device)
        if let ch = defaults.array(forKey: Keys.channels) as? [Int], !ch.isEmpty { selectedChannels = ch }
        sendTimecode = defaults.bool(forKey: Keys.mtc)
        scene = defaults.string(forKey: Keys.scene) ?? ""
        takes = recorder.log.takes
        recorder.onChange = { [weak self] r in
            guard let self else { return }
            self.currentTake = self.recorder.current
            self.takes = self.recorder.log.takes
            if case .writeFailed(let m) = r.outcome { self.interruption = "Write failed: \(m)" }
        }
        input.onInterruption = { [weak self] reason in
            guard let self else { return }
            Task { @MainActor in self.interrupted(reason) }
        }
        refreshDevices()
        deviceWatch = Task { [weak self] in
            for await _ in AudioDevices.changes() {
                guard let self else { return }
                await MainActor.run { self.refreshDevices(); self.reArmIfDeviceReturned() }
            }
        }
    }

    // MARK: Devices and arming

    public func refreshDevices() { devices = AudioDevices.inputs() }

    /// Picks (and persists) a device and channels, asks for microphone permission once, and arms.
    public func arm(deviceUID: String?, channels: [Int]) async {
        selectedDeviceUID = deviceUID
        defaults.set(deviceUID, forKey: Keys.device)
        selectedChannels = channels
        defaults.set(channels, forKey: Keys.channels)
        armError = nil; interruption = nil
        guard let uid = deviceUID else { disarm(); return }
        refreshDevices()
        guard let device = devices.first(where: { $0.uid == uid }) else { armError = "Device not connected"; disarm(); return }
        if permission != .granted {
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            permission = ok ? .granted : .denied
            guard ok else { armError = "Microphone access denied"; return }
        }
        do {
            try input.arm(device: device, channels: channels)
            isArmed = true
            updateTransport()
        } catch {
            armError = error.localizedDescription
            isArmed = false
        }
    }

    public func setChannels(_ channels: [Int]) async { await arm(deviceUID: selectedDeviceUID, channels: channels) }

    public func disarm() {
        if recorder.isRecording { recorder.abort(reason: .interrupted("disarmed")) }
        input.disarm()
        isArmed = false
        updateTransport()
    }

    private func interrupted(_ reason: AudioInputInterruption) {
        isArmed = false
        switch reason {
        case .deviceRemoved: interruption = "Audio device removed"
        case .configurationChanged: interruption = "Audio configuration changed"
        case .engineStopped(let m): interruption = m
        }
        if recorder.isRecording { recorder.abort(reason: .interrupted(interruption ?? "interrupted")) }
        updateTransport()
    }

    private func reArmIfDeviceReturned() {
        guard !isArmed, interruption == "Audio device removed", let uid = selectedDeviceUID, devices.contains(where: { $0.uid == uid }) else { return }
        Task { await arm(deviceUID: uid, channels: selectedChannels) }
    }

    // MARK: Logic transport

    private func updateTransport() {
        if sendTimecode && isArmed {
            if transport == nil { transport = try? LogicTransport() }
            transport?.startTimecode(rate: mtcRate, clock: { Date() })
            transportRunning = transport?.isRunning ?? false
        } else {
            transport?.stopTimecode()
            transportRunning = false
        }
    }

    // MARK: Recording events

    public func handle(_ event: RecordingEvent, label: TakeLabel, metadata: TakeMetadata) {
        guard isArmed else { return }
        switch event {
        case .pressed(let t):
            guard !recorder.isRecording else { return }
            begin(label: label, metadata: metadata, pressedAt: t)
        case .started(let t):
            if !recorder.isRecording { begin(label: label, metadata: metadata, pressedAt: t) }   // started on the body
            recorder.cameraStarted(at: t)
            confirmTimer?.cancel(); confirmTimer = nil
            meters.resetClip()
        case .stopped(let t):
            guard recorder.isRecording else { return }
            recorder.cameraStopped(at: t)
            transport?.stop()
        }
    }

    private func begin(label: TakeLabel, metadata: TakeMetadata, pressedAt: Date) {
        do {
            try recorder.begin(label: label, metadata: metadata, pressedAt: pressedAt)
            interruption = nil
            transport?.recordStrobe()
            confirmTimer?.cancel()
            confirmTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.confirmTimeout))
                guard !Task.isCancelled, let self, self.recorder.isRecording, self.recorder.current?.confirmedStart == nil else { return }
                self.recorder.abort(reason: .cameraNeverStarted)
                self.interruption = "Camera never started; take discarded"
                self.transport?.stop()
            }
        } catch {
            interruption = error.localizedDescription
        }
    }

    public func resetClip() { meters.resetClip() }

    // MARK: Pure helpers

    /// The HUD's clip label: the next take on a press, the current take once the body confirms.
    nonisolated public static func label(for event: RecordingEvent, takes: Int, cameraIndex: String, reel: Int) -> TakeLabel {
        let clip: Int
        switch event { case .pressed: clip = takes + 1; case .started, .stopped: clip = takes }
        return TakeLabel(cameraIndex: cameraIndex, reel: reel, clip: max(1, clip))
    }

    nonisolated public static func metadata(state: CameraState, projectFPS: Int, scene: String, note: String) -> TakeMetadata {
        var cam: [String: String] = [:]
        cam["shutter"] = state.shutterSpeed; cam["iris"] = state.fNumber; cam["iso"] = state.iso
        cam["focus"] = state.focusMode; cam["mode"] = state.exposureMode; cam["wb"] = state.whiteBalanceMode
        return TakeMetadata(project: "CinemaHUD", projectFPS: projectFPS, scene: scene.isEmpty ? nil : scene, note: note.isEmpty ? nil : note, camera: cam)
    }
}
#endif
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter AudioSessionControllerTests 2>&1 | tail -3`
Expected: `Executed 3 tests, with 0 failures`. If `CameraState()` has no public empty initialiser, use the same construction the existing `CameraStateTests.swift` uses.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaUI/Audio/AudioSessionController.swift Tests/SonyCameraKitTests/AudioSessionControllerTests.swift
git commit -m "Field audio: session controller wiring input, recorder and Logic transport to recording events

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 17: AUDIO item in the bottom strip and the settings panel section

**Files:**
- Create: `Sources/CinemaUI/Audio/AudioMeterItem.swift`
- Modify: `Sources/CinemaUI/HUDBars.swift` (`BottomStrip.rightItems` at ~289–311; settings panel `section("Monitor")` block at ~458–470)
- Test: `Tests/SonyCameraKitTests/AudioMeterItemTests.swift`

**Interfaces:**
- Consumes: `AudioSessionController` (Task 16), `MeterState`, `MeterMath.floor`.
- Produces: `struct AudioMeterItem: View` (macOS) and `enum MeterScale { static func fraction(_ dB: Float) -> CGFloat }` (0 at −60 dBFS, 1 at 0 dBFS, clamped).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SonyCameraKitTests/AudioMeterItemTests.swift
#if os(macOS)
import XCTest
@testable import CinemaUI

final class AudioMeterItemTests: XCTestCase {
    func testFraction() {
        XCTAssertEqual(MeterScale.fraction(-60), 0)
        XCTAssertEqual(MeterScale.fraction(0), 1)
        XCTAssertEqual(MeterScale.fraction(-30), 0.5, accuracy: 1e-6)
        XCTAssertEqual(MeterScale.fraction(-90), 0)
        XCTAssertEqual(MeterScale.fraction(3), 1)
    }
}
#endif
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter AudioMeterItemTests 2>&1 | tail -3`
Expected: compile error `cannot find 'MeterScale' in scope`.

- [ ] **Step 3: Implement the item**

```swift
// Sources/CinemaUI/Audio/AudioMeterItem.swift
#if os(macOS)
import SwiftUI
import CinemaAudio

enum MeterScale {
    /// 0 at −60 dBFS (the meter floor), 1 at 0 dBFS.
    static func fraction(_ dB: Float) -> CGFloat {
        CGFloat(min(1, max(0, (dB - MeterMath.floor) / -MeterMath.floor)))
    }
}

/// Bottom-strip item: source, rate, one bar per channel, take dot, MTC tag. Hidden until armed.
struct AudioMeterItem: View {
    @Environment(AudioSessionController.self) private var audio: AudioSessionController?

    var body: some View {
        if let audio, audio.isArmed || audio.interruption != nil {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("AUDIO").font(Theme.label(9)).tracking(1.2).foregroundStyle(Theme.dim)
                if audio.isArmed {
                    Text(audio.selectedDevice?.shortName ?? audio.meters.deviceName.uppercased()).font(Theme.strip(13)).foregroundStyle(Theme.text)
                    Text("\(Int(audio.meters.sampleRate / 1000))k").font(Theme.label(9)).foregroundStyle(Theme.dim)
                    HStack(spacing: 3) {
                        ForEach(audio.meters.channels.indices, id: \.self) { i in MeterBar(channel: audio.meters.channels[i]) }
                    }
                    if audio.currentTake != nil { Text("●").font(Theme.label(9)).foregroundStyle(Theme.rec) }
                    if audio.transportRunning { Text("MTC \(audio.mtcRate.framesPerSecond)").font(Theme.label(9)).foregroundStyle(Theme.accent) }
                } else {
                    Text("AUDIO LOST").font(Theme.strip(13)).foregroundStyle(Theme.warn)
                }
            }
            .padding(.horizontal, 10)
            .help(audio.interruption ?? audio.armError ?? "Audio interface armed")
        }
    }
}

struct MeterBar: View {
    var channel: MeterState.Channel
    private let width: CGFloat = 22, height: CGFloat = 8

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.14))
            Rectangle().fill(channel.clipped ? Theme.rec : Theme.text).frame(width: width * MeterScale.fraction(channel.rms))
            Rectangle().fill(channel.clipped ? Theme.rec : Theme.text).frame(width: 1).offset(x: max(0, width * MeterScale.fraction(channel.hold) - 1))
        }
        .frame(width: width, height: height)
        .accessibilityLabel("Audio level \(Int(channel.rms)) dBFS")
    }
}
#endif
```

- [ ] **Step 4: Add the item to the strip and a section to the settings panel**

In `HUDBars.swift`, `BottomStrip.rightItems`, before the line `if let m = s.recordableMinutes { item("MEDIA", …` insert:

```swift
            #if os(macOS)
            AudioMeterItem()
            #endif
```

In the settings panel, after the `section("Monitor") { … }` block (it ends with the `row("Reel") { … }` line and the closing `}`), insert:

```swift
                    #if os(macOS)
                    AudioSettingsSection()
                    #endif
```

And add at the bottom of `AudioMeterItem.swift` (inside the `#if os(macOS)`):

```swift
/// Settings-panel rows for the audio interface; the Audio menu offers the same choices.
struct AudioSettingsSection: View {
    @Environment(AudioSessionController.self) private var audio: AudioSessionController?

    var body: some View {
        if let audio {
            @Bindable var a = audio
            VStack(alignment: .leading, spacing: 6) {
                Text("AUDIO").font(Theme.label()).tracking(1.6).foregroundStyle(Theme.accent).padding(.horizontal, 12)
                HStack {
                    Text("Input").font(.system(size: 12)).foregroundStyle(Theme.text)
                    Spacer()
                    Picker("", selection: Binding(get: { audio.selectedDeviceUID ?? "" }, set: { uid in Task { await audio.arm(deviceUID: uid.isEmpty ? nil : uid, channels: audio.selectedChannels) } })) {
                        Text("None").tag("")
                        ForEach(audio.devices) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden().frame(maxWidth: 170).controlSize(.small)
                }
                .padding(.horizontal, 12)
                if let d = audio.selectedDevice {
                    HStack {
                        Text("Channels").font(.system(size: 12)).foregroundStyle(Theme.text)
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(Array(d.inputChannelNames.prefix(8).enumerated()), id: \.offset) { i, name in
                                let ch = i + 1
                                Toggle("\(ch)", isOn: Binding(get: { audio.selectedChannels.contains(ch) }, set: { on in
                                    var c = Set(audio.selectedChannels); if on { c.insert(ch) } else { c.remove(ch) }
                                    Task { await audio.setChannels(c.sorted()) }
                                })).toggleStyle(.button).controlSize(.mini).help(name)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                HStack {
                    Text("Send timecode to Logic").font(.system(size: 12)).foregroundStyle(Theme.text)
                    Spacer()
                    Toggle("", isOn: $a.sendTimecode).toggleStyle(.switch).controlSize(.small)
                }
                .padding(.horizontal, 12)
                if let e = audio.armError ?? audio.interruption {
                    Text(e).font(.system(size: 10)).foregroundStyle(Theme.warn).padding(.horizontal, 12)
                }
            }
        }
    }
}
```

- [ ] **Step 5: Build and run the tests**

Run: `swift build 2>&1 | grep -E "error|Compiling CinemaUI|Build complete" | tail -3 && swift test --filter AudioMeterItemTests 2>&1 | tail -3`
Expected: `Build complete`, `Executed 1 test, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/CinemaUI/Audio/AudioMeterItem.swift Sources/CinemaUI/HUDBars.swift Tests/SonyCameraKitTests/AudioMeterItemTests.swift
git commit -m "HUD: AUDIO item with per-channel meters, and an Audio section in the settings panel

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 18: Audio menu, Sync Takes window, app wiring

**Files:**
- Create: `Sources/CinemaUI/Audio/SyncTakesView.swift`
- Modify: `Sources/CinemaHUD/CinemaHUDApp.swift` (App struct at lines 17–32; `.commands { … }` block; `ContentView` at ~131–140)
- Test: `Tests/SonyCameraKitTests/SyncTakesModelTests.swift`

**Interfaces:**
- Consumes: `AudioSessionController` (Task 16), `TakeSync`, `TakeExport`, `FCPXML`, `TakePair`, `TakeRecord`, `TakeLog` (CinemaAudio).
- Produces (macOS):
  - `@Observable @MainActor public final class SyncTakesModel { var dayFolder: URL; private(set) var takes: [TakeRecord]; private(set) var pairs: [TakePair]; private(set) var busy: Bool; private(set) var message: String?; var projectFPS: Int; init(dayFolder: URL); func reloadTakes(); func load(_ urls: [URL]) async; func setTake(_ take: TakeRecord?, for pairID: String); func syncAll() async; func exportAll() async; static func markMissing(_ pairs: [TakePair], dayFolder: URL) -> [TakePair] }`
  - `public struct SyncTakesView: View` and `public struct AudioSceneView: View`.
  - `struct AudioCommands: Commands` in the app target.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SonyCameraKitTests/SyncTakesModelTests.swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SyncTakesModelTests 2>&1 | tail -3`
Expected: compile error `cannot find 'SyncTakesModel' in scope`.

- [ ] **Step 3: Implement the model and views**

```swift
// Sources/CinemaUI/Audio/SyncTakesView.swift
#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CinemaAudio

@Observable
@MainActor
public final class SyncTakesModel {
    public var dayFolder: URL { didSet { reloadTakes() } }
    public private(set) var takes: [TakeRecord] = []
    public private(set) var pairs: [TakePair] = []
    public private(set) var busy = false
    public private(set) var message: String?
    public var projectFPS = 24

    public init(dayFolder: URL) { self.dayFolder = dayFolder; reloadTakes() }

    public func reloadTakes() { takes = TakeLog.load(from: dayFolder).takes }

    /// Inspect dropped files/folders, pair them with this day's takes, flag missing WAVs.
    public func load(_ urls: [URL]) async {
        busy = true; defer { busy = false }
        message = nil
        let clips = await TakeSync.inspect(urls)
        guard !clips.isEmpty else { message = "No clips found (looking for .MP4 / .MOV)"; return }
        pairs = Self.markMissing(TakeSync.pair(clips: clips, takes: takes), dayFolder: dayFolder)
    }

    public func setTake(_ take: TakeRecord?, for pairID: String) {
        guard let i = pairs.firstIndex(where: { $0.id == pairID }) else { return }
        pairs[i].take = take
        pairs[i].offsetSeconds = take.map(TakeSync.estimate)
        pairs[i].confidence = nil
        pairs[i].status = take == nil ? .unpaired : .estimated
        pairs = Self.markMissing(pairs, dayFolder: dayFolder)
    }

    /// Run the waveform search for every pair that has a take and a WAV, four at a time.
    public func syncAll() async {
        busy = true; defer { busy = false }
        let folder = dayFolder
        enum Outcome { case ok(offset: Double, confidence: Double), failed(String) }
        let work = pairs.indices.filter { pairs[$0].take != nil && pairs[$0].status != .missingWAV }
        for batch in stride(from: 0, to: work.count, by: 4).map({ Array(work[$0 ..< min($0 + 4, work.count)]) }) {
            await withTaskGroup(of: (Int, Outcome).self) { group in
                for i in batch {
                    let take = pairs[i].take!
                    let wav = folder.appendingPathComponent(take.wavPath)
                    let clip = pairs[i].clip.url
                    let estimate = pairs[i].offsetSeconds ?? TakeSync.estimate(take)
                    group.addTask {
                        do {
                            let r = try await TakeSync.offset(clip: clip, wav: wav, around: estimate)
                            return (i, .ok(offset: r.offset, confidence: r.confidence))
                        } catch {
                            return (i, .failed(error.localizedDescription))
                        }
                    }
                }
                for await (i, outcome) in group {
                    switch outcome {
                    case .ok(let offset, let confidence):
                        pairs[i].confidence = confidence
                        if confidence >= TakeSync.lowConfidence {
                            pairs[i].offsetSeconds = offset
                            pairs[i].status = .synced
                        } else {
                            pairs[i].offsetSeconds = TakeSync.estimate(pairs[i].take!)
                            pairs[i].status = .lowConfidence
                        }
                    case .failed(let message):
                        pairs[i].status = .failed(message)
                    }
                }
            }
        }
    }

    /// Trimmed WAV + synced .mov per pair, then the FCPXML for the day.
    public func exportAll() async {
        busy = true; defer { busy = false }
        let synced = dayFolder.appendingPathComponent("synced")
        try? FileManager.default.createDirectory(at: synced, withIntermediateDirectories: true)
        for i in pairs.indices {
            guard let take = pairs[i].take, let offset = pairs[i].offsetSeconds, pairs[i].status != .missingWAV else { continue }
            let src = dayFolder.appendingPathComponent(take.wavPath)
            let out = TakeExport.outputs(for: pairs[i].clip, take: take, in: synced)
            do {
                try TakeExport.trimmedWAV(wav: src, offset: offset, duration: pairs[i].clip.duration, take: take, to: out.wav)
                try await TakeExport.movie(clip: pairs[i].clip.url, wav: src, offset: offset, to: out.mov)
                pairs[i].status = .exported(out.wav)
            } catch {
                pairs[i].status = .failed(error.localizedDescription)
            }
        }
        let day = dayFolder.lastPathComponent
        let xml = FCPXML.document(pairs: pairs, syncedFolder: synced, projectFPS: projectFPS, eventName: "CinemaHUD \(day)")
        let xmlURL = synced.appendingPathComponent("CinemaHUD_\(day).fcpxml")
        do {
            try xml.write(to: xmlURL, atomically: true, encoding: .utf8)
            message = "Exported to \(synced.path)"
            NSWorkspace.shared.activateFileViewerSelecting([xmlURL])
        } catch {
            message = "Could not write FCPXML: \(error.localizedDescription)"
        }
    }

    public static func markMissing(_ pairs: [TakePair], dayFolder: URL) -> [TakePair] {
        pairs.map { p in
            var p = p
            if let t = p.take, !FileManager.default.fileExists(atPath: dayFolder.appendingPathComponent(t.wavPath).path) { p.status = .missingWAV }
            return p
        }
    }
}

public struct SyncTakesView: View {
    @Environment(AudioSessionController.self) private var audio: AudioSessionController?
    @State private var model: SyncTakesModel

    public init(dayFolder: URL) { _model = State(initialValue: SyncTakesModel(dayFolder: dayFolder)) }

    public var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(model.dayFolder.path).font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.head)
                Button("Choose Day Folder…") { chooseDayFolder() }.controlSize(.small)
                Spacer()
                Button("Choose Clips…") { chooseClips() }.controlSize(.small)
                Button("Sync All") { Task { await model.syncAll() } }.disabled(model.busy || model.pairs.isEmpty).controlSize(.small)
                Button("Export") { Task { await model.exportAll() } }.disabled(model.busy || !model.pairs.contains { $0.offsetSeconds != nil }).controlSize(.small).keyboardShortcut(.defaultAction)
            }
            if model.pairs.isEmpty {
                ContentUnavailableView("Drop the card's clips here", systemImage: "waveform.badge.plus",
                                       description: Text("Drag the CLIP folder from the SD card, or choose files. Takes come from \(model.dayFolder.lastPathComponent)/takes.json."))
            } else {
                Table(model.pairs) {
                    TableColumn("Clip") { Text($0.clip.name) }
                    TableColumn("Take") { p in
                        Picker("", selection: Binding(get: { p.take?.id ?? "" }, set: { id in model.setTake(model.takes.first { $0.id == id }, for: p.id) })) {
                            Text("—").tag("")
                            ForEach(model.takes.filter { $0.outcome == .complete }) { Text($0.id).tag($0.id) }
                        }.labelsHidden()
                    }
                    TableColumn("Duration") { Text(String(format: "%.1f s", $0.clip.duration)) }
                    TableColumn("Offset") { p in Text(p.offsetSeconds.map { String(format: "%.3f s", $0) } ?? "—") }
                    TableColumn("Confidence") { p in Text(p.confidence.map { String(format: "%.0f %%", $0 * 100) } ?? "—") }
                    TableColumn("Status") { p in Text(statusText(p.status)).foregroundStyle(statusColor(p.status)) }
                }
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.message ?? "").font(.system(size: 11)).foregroundStyle(Theme.dim)
                Spacer()
            }
        }
        .padding(14)
        .frame(minWidth: 760, minHeight: 420)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) { urls.append(u) }
                }
                await model.load(urls)
            }
            return true
        }
        .onAppear { if let fps = audio?.projectFPS { model.projectFPS = fps } }
    }

    private func chooseClips() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .folder]
        panel.title = "Choose camera clips or the card's CLIP folder"
        if panel.runModal() == .OK { Task { await model.load(panel.urls) } }
    }
    private func chooseDayFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = model.dayFolder.deletingLastPathComponent()
        panel.title = "Choose the day folder (contains takes.json)"
        if panel.runModal() == .OK, let u = panel.url { model.dayFolder = u }
    }
    private func statusText(_ s: TakePair.Status) -> String {
        switch s {
        case .unpaired: return "No take"; case .estimated: return "Estimated"; case .synced: return "Synced"
        case .lowConfidence: return "Low confidence (estimate used)"; case .missingWAV: return "WAV missing"
        case .exported: return "Exported"; case .failed(let m): return "Failed: \(m)"
        }
    }
    private func statusColor(_ s: TakePair.Status) -> Color {
        switch s { case .synced, .exported: return Theme.ok; case .lowConfidence, .missingWAV, .failed: return Theme.warn; default: return Theme.dim }
    }
}

/// Tiny window for the scene and a note, written into each take's iXML and takes.json.
public struct AudioSceneView: View {
    @Environment(AudioSessionController.self) private var audio: AudioSessionController?
    public init() {}
    public var body: some View {
        if let audio {
            @Bindable var a = audio
            Form {
                TextField("Scene", text: $a.scene)
                TextField("Note", text: $a.note)
            }
            .padding(14).frame(width: 320)
        }
    }
}
#endif
```

- [ ] **Step 4: Wire the app**

In `CinemaHUDApp.swift`:

1. Add `@State private var audio = AudioSessionController()` after `@State private var overlays = OverlaySettings()`.
2. In the `WindowGroup` content, after `.environment(overlays)` add `.environment(audio)`.
3. After the `.commands { … }` block's closing brace of the `WindowGroup` (i.e. as further scenes in `body`), add:

```swift
        Window("Sync Takes", id: "sync-takes") {
            SyncTakesView(dayFolder: audio.dayFolder).environment(audio).preferredColorScheme(.dark)
        }
        Window("Scene & Note", id: "audio-scene") {
            AudioSceneView().environment(audio).preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
```

4. Inside `.commands { … }`, after `CommandMenu("Overlays") { … }`, add `AudioCommands(audio: audio)`.
5. Add at file scope:

```swift
struct AudioCommands: Commands {
    let audio: AudioSessionController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Audio") {
            Menu("Input") {
                Button("None") { Task { await audio.arm(deviceUID: nil, channels: audio.selectedChannels) } }
                Divider()
                ForEach(audio.devices) { d in
                    Button(d.name) { Task { await audio.arm(deviceUID: d.uid, channels: audio.selectedChannels) } }
                }
                Divider()
                Button("Refresh Devices") { audio.refreshDevices() }
            }
            .disabled(audio.permission == .denied)
            if audio.permission == .denied {
                Button("Microphone access denied — Open Privacy Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            }
            Menu("Channels") {
                if let d = audio.selectedDevice {
                    ForEach(Array(d.inputChannelNames.prefix(8).enumerated()), id: \.offset) { i, name in
                        let ch = i + 1
                        Toggle("\(ch)  \(name)", isOn: Binding(get: { audio.selectedChannels.contains(ch) }, set: { on in
                            var c = Set(audio.selectedChannels); if on { c.insert(ch) } else { c.remove(ch) }
                            Task { await audio.setChannels(c.sorted()) }
                        }))
                    }
                } else {
                    Text("Choose an input first")
                }
            }
            Toggle("Send Timecode to Logic (MTC + MMC)", isOn: Binding(get: { audio.sendTimecode }, set: { audio.sendTimecode = $0 }))
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Reset Clip Indicators") { audio.resetClip() }
            Button("Scene & Note…") { openWindow(id: "audio-scene") }
            Divider()
            Button("Sync Takes…") { openWindow(id: "sync-takes") }.keyboardShortcut("y", modifiers: [.command])
            Button("Show Audio Folder") {
                try? FileManager.default.createDirectory(at: audio.dayFolder, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([audio.dayFolder])
            }
        }
    }
}
```

6. In `ContentView`, add after `@Environment(OverlaySettings.self) private var overlays`:

```swift
    @Environment(AudioSessionController.self) private var audio
```

and add these modifiers after `.onChange(of: session.state.shootMode, initial: true) { … }`:

```swift
        .onChange(of: session.recordingEvent) { _, event in
            guard let event else { return }
            audio.handle(event,
                         label: AudioSessionController.label(for: event, takes: session.takes, cameraIndex: overlays.cameraIndex, reel: overlays.reel),
                         metadata: AudioSessionController.metadata(state: session.state, projectFPS: overlays.projectFPS, scene: audio.scene, note: audio.note))
        }
        .onChange(of: overlays.projectFPS, initial: true) { _, fps in audio.projectFPS = fps }
```

- [ ] **Step 5: Build, test, and try the app**

Run: `swift build 2>&1 | grep -E "error|Build complete" | tail -3 && swift test 2>&1 | tail -3`
Expected: `Build complete`, all tests pass.

Run the app against the simulator, arm the built-in microphone, and check the strip:

```bash
python3 tools/camerasim.py & SIM=$!
sleep 1
CINEMAHUD_ADDRESS=127.0.0.1:8080 CINEMAHUD_WINDOW=1400x800 swift run CinemaHUD
kill $SIM
```

In the app: Audio ▸ Input ▸ MacBook Pro Microphone. macOS asks for microphone access (the embedded plist makes this work from `swift run`). Expected: the AUDIO item appears in the bottom strip with "MACBOOK PRO 48k" and moving bars; press R: a "●" appears, `~/Movies/CinemaHUD/<today>/audio/A_0001_C001.wav` is created, and after stopping (R again) `takes.json` lists it as complete. ⌘Y opens Sync Takes. Fix anything that does not match before committing.

- [ ] **Step 6: Commit**

```bash
git add Sources/CinemaUI/Audio/SyncTakesView.swift Sources/CinemaHUD/CinemaHUDApp.swift Tests/SonyCameraKitTests/SyncTakesModelTests.swift
git commit -m "Field audio: Audio menu, Sync Takes window with waveform sync and export, app wiring

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 19: README, iOS build check, DMG, final verification

**Files:**
- Modify: `README.md` (after the "### Live view quality and frame rate" section, before "### Verified on hardware")

- [ ] **Step 1: Document the feature**

Insert into `README.md`:

```markdown
### Field audio (Mac)

The α6400 has no headphone jack and records 16-bit sound from its own preamps. CinemaHUD can be the
sound recorder instead: **Audio ▸ Input** picks any Core Audio interface (a Focusrite Scarlett, for
example), **Audio ▸ Channels** picks up to eight inputs, and the bottom strip shows the source, its
rate and a level bar per channel (red = clipped since the last take; **Audio ▸ Reset Clip Indicators**).
Phantom power is a hardware switch on the interface; the app cannot see or set it.

Every take is recorded to `~/Movies/CinemaHUD/<yyyy-MM-dd>/audio/<camera>_<reel>_C<clip>.wav`
(48 kHz, 24-bit) with 3 s of pre-roll before the REC press and 1 s after the body stops, whether REC
was pressed in the app or on the camera. The WAV carries Broadcast Wave timecode (time of day, the
same numbers as the TC readout) and iXML scene/take metadata (**Audio ▸ Scene & Note…**). `takes.json`
in the day folder lists every take with its timestamps.

**Logic Pro.** **Audio ▸ Send Timecode to Logic** (⇧⌘M) publishes a virtual MIDI source named
"CinemaHUD" that sends MIDI Timecode at the project frame rate and MMC record/stop on every take.
In Logic: File ▸ Project Settings ▸ Synchronization ▸ Sync Mode = **MTC** with the same frame rate;
Settings ▸ MIDI ▸ Sync ▸ **Listen to MMC Input** on; and "CinemaHUD" enabled under MIDI inputs.
Logic then starts recording on REC and its regions sit at the same timecode as the WAVs.

**Sync Takes (⌘Y).** After the shoot, drop the card's `PRIVATE/M4ROOT/CLIP` folder (or individual
clips) on the window. The app pairs each clip with a take by order and length, then **Sync All** finds
the exact offset by cross-correlating the clip's own audio against the WAV (feeding the interface's
line out into the camera's mic input makes this bulletproof; the built-in mic usually works too).
**Export** writes, into `<day>/synced/`: a trimmed WAV that starts with the clip, a `.mov` with the
video untouched and the interface audio as track 1 (camera audio kept as track 2), and
`CinemaHUD_<day>.fcpxml`. In Final Cut Pro, File ▸ Import ▸ XML brings in an event with every clip
already synced (camera audio muted, WAV connected); Resolve imports the same file.
Rows marked "Low confidence" use the estimate from the take log; check them in the editor.
```

Add to the "### Verified on hardware" section a new list, exactly as follows (the implementer fills in ✔ / pending after actually testing; never mark something verified that was not run):

```markdown
Field audio: arm a Scarlett 2i2 (meters follow input) — pending; REC on the α6400 produces a WAV of
clip length + ~4 s — pending; Logic 11 chases MTC and records on REC — pending; Sync Takes on a real
card gives "Synced" rows — pending; Final Cut Pro imports the FCPXML with clips in sync — pending.
```

- [ ] **Step 2: Build the iOS app to prove CinemaAudio compiles for iOS**

Run: `xcodebuild -project iOS/CinemaHUDMobile.xcodeproj -scheme CinemaHUDMobile -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | grep -E "error|BUILD" | tail -5`
Expected: `** BUILD SUCCEEDED **`. If the scheme name differs, run `xcodebuild -list -project iOS/CinemaHUDMobile.xcodeproj` and use the listed scheme. Any `#if os(macOS)` gap shows up here as an error naming a HAL or AppKit symbol; wrap that file's contents.

- [ ] **Step 3: Full verification**

Run: `swift test 2>&1 | tail -3 && scripts/build-dmg.sh 2>&1 | tail -2`
Expected: all tests pass; `✔ build/CinemaHUD.dmg (...)`. Open the built app from `build/CinemaHUD.app`, arm the microphone once to confirm the bundled app also prompts for permission and meters.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "README: field audio, Logic setup, Sync Takes and Final Cut import

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 5: Hand back**

Do not merge or bump the version. Report to the user: what was built, the test count, the three hardware checks still pending (Scarlett, Logic, Final Cut import), and the branch name `field-audio`. The release process is a separate step.
