# CinemaHUD Field Audio — interface recording, meters, Logic transport and take sync

Date: 2026-09-15

## Goal

The α6400 has no headphone jack and records 16-bit audio from its own preamps. CinemaHUD on the
Mac becomes the sound recorder: it captures a Focusrite Scarlett (or any Core Audio input) to a
48 kHz 24-bit WAV for every take, shows per-channel meters and the audio source in the HUD, can
drive Logic Pro's transport and timecode so Logic records the same take in sync, and after the
shoot pairs each camera clip with its WAV, finds the exact offset from the waveform, and writes
a `.mov` with the interface audio swapped in plus an FCPXML that Final Cut Pro (and Resolve)
import with every clip already synchronised.

Version one is the Mac app. The audio module has no AppKit or camera dependency so the iPhone
viewfinder can meter later.

## Facts that shape the design

- **The camera never sends the video file to the Mac.** Over PTP and the Wi-Fi API the Mac only
  receives the 1024×680 monitor stream and stills. Audio recorded on the Mac and video recorded on
  the card meet at import time, so sync must be recoverable from the files alone.
- **The camera's clock cannot be set or read precisely from the Mac.** Timecode-only sync is not
  reliable. The camera's own audio track (its built-in mic, or the interface's line out fed into
  the 3.5 mm mic input) is always present in the XAVC S file as 48 kHz LPCM, and waveform
  cross-correlation against it gives sample-accurate offsets.
- **Recording state is polled.** `CameraSession.startStateLoop` sees `state.isRecording` flip
  some hundreds of milliseconds after the body starts. The REC press (`toggleRecording`) is
  earlier than the true start; the confirmed transition is later. A pre-roll ring buffer makes the
  WAV cover both, and the sync step trims it.
- **Scarlett interfaces are class-compliant USB audio.** macOS exposes them through Core Audio
  with channel names; phantom power state is not reported by class-compliant devices, so the app
  cannot show or set it.
- **Logic Pro can chase MIDI Timecode and obey MIDI Machine Control** from any CoreMIDI source.
  Logic has no API that exposes its output to another app; the app meters the interface directly
  (Core Audio allows several clients on one device).
- **Final Cut Pro imports FCPXML** with `sync-clip` elements and reads Broadcast Wave (`bext`)
  timecode and iXML scene/take metadata from WAV files. Resolve imports the same FCPXML.
- **Microphone access needs a usage string in an Info.plist.** The DMG build is a bundle; the
  development build is a bare SwiftPM executable that macOS terminates on first microphone access
  unless an Info.plist is embedded in the binary.
- **The HUD's clip label** is `"\(cameraIndex)_\(reel, %04d)  C\(clip, %03d)"` (`HUDBars.swift`),
  where the clip number is `session.takes` (+1 while standing by). Audio files use the same label.
- **Timecode in the HUD** is time-of-day at `overlays.projectFPS`. MTC and the WAV `bext` time
  reference carry the same time-of-day so the take log, Logic's region and the WAV agree.

## Non-goals

- Capturing Logic's output (use Logic as recorder, chased by the app's MTC, or route it through a
  third-party virtual device the user picks like any other input).
- Playback or headphone monitoring through the Mac (the operator listens on the interface).
- iOS. Editing offsets by ear. Multi-camera pairing. Re-encoding video.
- Reading the camera's timecode track from the clip. It is written to the FCPXML only if
  AVFoundation reports it; it is never used for the offset.

## Architecture

New SwiftPM target `CinemaAudio` (depends on Foundation, AVFoundation, CoreAudio, CoreMIDI,
Accelerate; no SonyCameraKit, no SwiftUI). `CinemaUI` adds the HUD meter, the Audio menu items and
the Sync Takes window. `CameraSession` gains one observable value; nothing in the audio module calls
the camera.

```
Core Audio device ──▶ AudioInput ──▶ ring buffer (3 s) ──▶ TakeRecorder ──▶ A_0001_C003.wav + takes.json
                         │                                      ▲
                         ├──▶ MeterState (30 Hz) ──▶ HUD        │ REC press / confirmed start / stop
                         │                                      │ (CameraSession.recordingEvents)
                         └──▶ (rate, channels) ──▶ LogicTransport ──▶ virtual MIDI source "CinemaHUD" (MTC + MMC)

card clips + takes.json ──▶ TakeSync.pair ──▶ TakeSync.offset (cross-correlation) ──▶ TakeExport ──▶ synced/*.mov, *.wav, CinemaHUD_<date>.fcpxml
```

### 1. `AudioInput` (CinemaAudio)

```swift
public struct AudioDevice: Identifiable, Sendable, Equatable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String            // "Scarlett 2i2 USB"
    public let inputChannelNames: [String]   // ["Input 1", "Input 2"], from kAudioObjectPropertyElementName, falling back to "Ch n"
    public let nominalSampleRate: Double
    public let supportedSampleRates: [Double]
}

public enum AudioDevices {
    public static func inputs() -> [AudioDevice]
    public static func setNominalSampleRate(_ rate: Double, on id: AudioDeviceID) throws
    /// Fires on device add/remove and default-input change (kAudioHardwarePropertyDevices).
    public static func changes() -> AsyncStream<Void>
}

@Observable public final class MeterState {
    public struct Channel: Equatable { public var peak: Float; public var rms: Float; public var hold: Float; public var clipped: Bool }   // dBFS
    public private(set) var channels: [Channel]
    public private(set) var sampleRate: Double
    public private(set) var deviceName: String
    public func resetClip()
}

public final class AudioInput {
    public init()
    public var meters: MeterState { get }
    public private(set) var isArmed: Bool
    /// Starts the engine on `device` with `channels` (indices into the device's input channels, 1…8).
    /// Sets the device to 48 kHz when it supports it, otherwise records at its current rate.
    public func arm(device: AudioDevice, channels: [Int]) throws
    public func disarm()
    /// Returns the last `seconds` of audio (≤ 3 s) up to now — the pre-roll for a take.
    public func preroll(seconds: Double) -> AVAudioPCMBuffer
    /// Every buffer after the call, delivered on a serial queue, until the returned handle is cancelled.
    public func subscribe(_ sink: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) -> AnyCancellable
    public var onInterruption: ((AudioInputInterruption) -> Void)?   // device removed, sample rate changed, engine config change
}
```

- Engine: `AVAudioEngine`, `inputNode` tap of 512 frames, tap format = device format restricted
  to the chosen channels with an `AVAudioMixerNode` channel map when the selection is a subset.
- Ring buffer: fixed 3 s × channels × Float32, single-writer (tap) / single-reader (`preroll`)
  guarded by a lock taken only in `preroll`; the tap writes with atomic index publication.
- Meters: per buffer, `vDSP_maxmgv` for peak and `vDSP_rmsqv` for RMS per channel; converted to
  dBFS (−∞ shown as −60); peak hold decays after 1.5 s; `clipped` latches at ≥ −0.1 dBFS until
  `resetClip()` (the HUD resets it on REC start). Published to `MeterState` on the main actor at
  30 Hz by coalescing, never per buffer.
- `subscribe` sinks receive the same `AVAudioPCMBuffer` copied once onto a serial `DispatchQueue`
  (`qos: .userInitiated`); the audio thread does no allocation beyond the copy and no file I/O.
- Interruptions: `AVAudioEngineConfigurationChange` and the device-removed notification stop the
  engine, set `isArmed = false`, and call `onInterruption` with a reason. The UI shows the reason
  in the AUDIO item and offers re-arm; if the same device UID reappears, the app re-arms itself.

### 2. `TakeRecorder` (CinemaAudio)

```swift
public struct TakeLabel: Sendable, Equatable { public var cameraIndex: String; public var reel: Int; public var clip: Int
    public var fileStem: String }        // "A_0001_C003"

public struct TakeMetadata: Sendable, Codable, Equatable {
    public var project: String           // "CinemaHUD"
    public var projectFPS: Int
    public var scene: String?            // free text from the Audio menu, optional
    public var note: String?
    public var camera: [String: String]  // shutter, iris, iso, wb, focus mode, exposure mode — whatever is known
}

public struct TakeRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: String                // fileStem
    public var label: TakeLabel
    public var wavPath: String           // relative to the day folder
    public var pressedAt: Date           // REC press on the Mac
    public var confirmedStart: Date?     // camera reported MovieRecording
    public var confirmedStop: Date?
    public var prerollSeconds: Double    // audio in the file before pressedAt
    public var sampleRate: Double
    public var channelNames: [String]
    public var metadata: TakeMetadata
    public var outcome: Outcome          // .complete, .cameraNeverStarted, .interrupted(reason), .writeFailed(reason)
}

public struct TakeLog: Codable, Equatable { public var takes: [TakeRecord]; static func load(dayFolder:); func save(to:) }

public final class TakeRecorder {
    public init(input: AudioInput, dayFolder: URL)     // ~/Movies/CinemaHUD/<yyyy-MM-dd>
    public func begin(label: TakeLabel, metadata: TakeMetadata, pressedAt: Date) throws
    public func cameraStarted(at: Date)
    public func cameraStopped(at: Date)               // closes the file 1 s later, finalises bext/iXML, appends to takes.json
    public func abort(reason: TakeRecord.Outcome)     // e.g. camera never started (5 s timeout) — file deleted, log entry kept with outcome
    public private(set) var current: TakeRecord?
}
```

- `begin` writes `input.preroll(seconds: 3)` first, then subscribes to live buffers. Files:
  `<dayFolder>/audio/<fileStem>.wav`, 48 kHz (or the device rate) 24-bit signed integer PCM,
  channel count = armed channels. If `<fileStem>.wav` exists (same clip number after a
  reconnect), the name gets `_2`, `_3`.
- The file is written with `AVAudioFile` (`.wav`, `AVLinearPCMBitDepthKey: 24`); `bext` and
  `iXML` chunks are appended after close by `BroadcastWave.finalize(url:bext:ixml:)`, which
  rewrites the RIFF size. `bext`: `Description` = fileStem, `Originator` = "CinemaHUD",
  `OriginationDate/Time` = local time of the first sample, `TimeReference` = samples since local
  midnight at the file's sample rate for the first sample (so the WAV's BWF timecode equals the
  HUD/MTC time-of-day at that instant), `Version` = 1, `CodingHistory` = "A=PCM,F=48000,W=24,M=stereo,T=CinemaHUD".
  `iXML`: `PROJECT`, `SCENE`, `TAKE` (clip number), `TAPE` (reel `%04d`), `CIRCLED` = FALSE,
  `FILE_UID`, `SPEED/TIMECODE_RATE` = projectFPS, `TRACK_LIST` with one `TRACK` per channel
  carrying `NAME` from the device.
- `takes.json` is rewritten atomically after every change; a take with a failed write keeps its
  entry with `outcome` so the sync step can explain a missing WAV.

### 3. Session integration (SonyCameraKit + CinemaUI)

- `CameraSession` gains `public private(set) var recordingEvent: RecordingEvent?` where
  `enum RecordingEvent: Equatable { case pressed(Date), started(Date), stopped(Date) }`.
  `toggleRecording` sets `.pressed(now)` before calling the backend when starting;
  `startStateLoop` sets `.started(now)` on the false→true transition (where `takes` is already
  incremented) and `.stopped(now)` on true→false. Existing behaviour is unchanged; the value is
  a stream the UI observes with `onChange`.
- `AudioSessionController` (CinemaUI, `@Observable`, one per app): owns `AudioInput`,
  `TakeRecorder`, `LogicTransport`; persists the chosen device UID, channels, MTC on/off and the
  scene text in `UserDefaults`; observes `recordingEvent` and `overlays` for the label:
  - `.pressed(t)` with an armed input → `recorder.begin(label: current HUD label, …, pressedAt: t)`
    and `transport.recordStrobe()`; starts a 5 s timer for `abort(.cameraNeverStarted)`.
  - `.started(t)` → `recorder.cameraStarted(at: t)`, cancel the timer, `meters.resetClip()`.
  - `.stopped(t)` → `recorder.cameraStopped(at: t)`, `transport.stop()`.
  - A take that started on the body (no `.pressed`) begins at `.started(t)` with `pressedAt = t`
    and the same 3 s pre-roll, so body-triggered takes are covered too.
- Day folder: `~/Movies/CinemaHUD/<yyyy-MM-dd>/`, created on first arm.

### 4. HUD and menus (CinemaUI, Mac)

- Bottom strip gains an `AUDIO` item after `MEDIA`, only while armed: device short name (first
  two words, e.g. "SCARLETT 2i2"), rate as "48k", then one 22×8 pt bar per channel: RMS fill in
  `Theme.text`, a 1 pt peak-hold tick, the whole bar `Theme.rec` while `clipped`. While a take is
  open the bar row is followed by "●" in `Theme.rec`; on an interruption the item reads
  `AUDIO LOST` in `Theme.warn`. When MTC is on, a trailing `MTC 24` tag. Fits in ≤ 220 pt.
- New `CommandMenu("Audio")`: `Input ▸` (device list, refreshed on `AudioDevices.changes()`,
  "None" disarms), `Channels ▸` (checkmarks, 1…8), `Send Timecode to Logic (MTC + MMC)` toggle
  with ⇧⌘M, `Reset Clip Indicators`, `Scene…` (a small sheet with scene and note text),
  `Sync Takes…` with ⌘Y, `Show Audio Folder` (reveals the day folder). Menu items are disabled
  with a tooltip when microphone permission was denied.
- The Settings panel (`overlays.showMenu`) shows the same input/channel pickers so the mobile-style
  panel stays complete; both write the same controller.

### 5. `LogicTransport` (CinemaAudio)

```swift
public enum MTCRate: UInt8 { case fps24 = 0, fps25 = 1, fps30drop = 2, fps30 = 3; init(projectFPS: Int) }   // 24→24, 25→25, everything else→30 nd
public enum MIDIMessages {
    public static func mtcFullFrame(h: Int, m: Int, s: Int, f: Int, rate: MTCRate) -> [UInt8]     // F0 7F 7F 01 01 hh mm ss ff F7
    public static func mtcQuarterFrames(h: Int, m: Int, s: Int, f: Int, rate: MTCRate) -> [[UInt8]] // eight F1 nx messages
    public static let mmcRecordStrobe: [UInt8]   // F0 7F 7F 06 06 F7
    public static let mmcStop: [UInt8]           // F0 7F 7F 06 01 F7
    public static let mmcPlay: [UInt8]           // F0 7F 7F 06 02 F7
}
public final class LogicTransport {
    public init(sourceName: String = "CinemaHUD") throws   // MIDISourceCreate on a client; errors are surfaced, not fatal
    public func startTimecode(rate: MTCRate, clock: @escaping () -> Date)   // full frame, then quarter frames from a DispatchSourceTimer at 4×fps with leeway 200 µs
    public func stopTimecode()
    public func recordStrobe(); public func stop()
    public private(set) var isRunning: Bool
}
```

- Quarter frames are derived from the time-of-day clock each tick (no accumulated drift); a
  full-frame message is re-sent every 10 s and whenever the timer detects a gap > 2 frames.
- The transport starts when MTC is toggled on and an input is armed, and stops on disarm. Record
  strobe/stop follow the session events in §3 regardless of whether MTC is running.
- README documents Logic's three settings: File ▸ Project Settings ▸ Synchronization ▸ Sync Mode
  = MTC and frame rate = project; Settings ▸ MIDI ▸ Sync ▸ "Listen to MMC Input"; the input
  "CinemaHUD" enabled in MIDI inputs.

### 6. `TakeSync` and `TakeExport` (CinemaAudio)

```swift
public struct ClipInfo: Sendable, Equatable, Identifiable {   // from AVAsset
    public let id: URL; public var duration: Double; public var creationDate: Date?; public var hasAudio: Bool; public var timecodeStart: String?
}
public struct TakePair: Identifiable, Equatable {
    public var id: String; public var clip: ClipInfo; public var take: TakeRecord?
    public var offsetSeconds: Double?      // WAV time at which clip time 0 lies; positive = trim WAV
    public var confidence: Double?         // 0…1 peak prominence
    public var status: Status              // .unpaired, .estimated, .synced, .lowConfidence, .missingWAV, .exported(URL), .failed(String)
}
public enum TakeSync {
    public static func inspect(_ urls: [URL]) async -> [ClipInfo]                 // accepts files or folders; walks PRIVATE/M4ROOT/CLIP
    public static func pair(clips: [ClipInfo], takes: [TakeRecord]) -> [TakePair]  // order + duration match, see below
    public static func estimate(_ pair: TakePair) -> Double?                       // from takes.json: prerollSeconds + (confirmedStart − pressedAt)
    public static func offset(clip: URL, wav: URL, around estimate: Double, window: Double = 10) async throws -> (offset: Double, confidence: Double)
}
public enum TakeExport {
    public static func trimmedWAV(wav: URL, offset: Double, duration: Double, to: URL) throws
    public static func movie(clip: URL, wav: URL, offset: Double, to: URL) async throws            // passthrough video + WAV track 1 + camera audio track 2
    public static func fcpxml(pairs: [TakePair], dayFolder: URL, projectFPS: Int) -> String
}
```

- **Pairing:** clips sorted by creation date, takes with `outcome == .complete` by `pressedAt`.
  Walk both in order; a clip matches the next take when
  `|clipDuration − (wavDuration − prerollSeconds − 1)| ≤ max(2 s, 5 %)`; otherwise the clip is
  `.unpaired` and the take is skipped for the next clip. The table lets the user pick any take
  for a row from a popup; re-pairing re-runs the offset.
- **Offset:** both sources decoded with `AVAssetReader` / `AVAudioFile` to mono Float32 at
  8 kHz (average of channels), converted to an envelope (absolute value, 20 ms RMS), mean-removed.
  Cross-correlation with `vDSP` FFT over the window `estimate ± 10 s`; `confidence` = peak /
  (mean + 3 σ of the rest), mapped to 0…1 with 1.0 at ratio ≥ 8. Result below 0.5 →
  `.lowConfidence` and the estimate is used for export; ≥ 0.5 → `.synced` with the measured
  offset refined to sample accuracy by a second correlation at 48 kHz over ±50 ms. A clip without
  an audio track → `.estimated`.
- **Export** (per pair, into `<dayFolder>/synced/`): `<stem>.wav` = the WAV trimmed to start at
  `offset` for `clipDuration` (24-bit, bext `TimeReference` shifted accordingly, iXML copied);
  `<clipBaseName>_synced.mov` built with `AVMutableComposition`: video track inserted from the
  clip unchanged, audio track 1 from the trimmed WAV, audio track 2 from the clip's own audio;
  exported with `AVAssetExportPresetPassthrough`, creation date and the clip's `tmcd` track
  copied when present. If the clip is longer than the WAV, the WAV is padded with silence and the
  row shows a warning.
- **FCPXML** (version 1.11): one `resources` block with a `format` for the project FPS and clip
  size read from the asset, an `asset` per clip and per trimmed WAV; an `event` named
  `CinemaHUD <yyyy-MM-dd>` holding one `sync-clip` per pair: the video `asset-clip` and, as a
  connected `audio` with `offset` 0 (the WAV is already trimmed), the WAV, with `audioRole`
  "dialogue". Unpaired clips are added as plain `asset-clip`s. File:
  `<dayFolder>/synced/CinemaHUD_<yyyy-MM-dd>.fcpxml`. Final Cut: File ▸ Import ▸ XML.
- **Sync Takes window** (CinemaUI, `Window("Sync Takes")`): drop zone / "Choose Clips…" button;
  table columns Clip, Take (popup), Duration, Offset, Confidence, Status; "Sync All" runs pairing
  and offsets concurrently (≤ 4 at a time); "Export" writes the outputs and the FCPXML, then
  reveals the folder. Progress per row; errors inline in Status. The window works without the
  camera connected.

### 7. Permissions, build and availability

- `Resources/Info.plist` gains `NSMicrophoneUsageDescription` ("CinemaHUD records your audio
  interface alongside the camera's video."). The `CinemaHUD` executable target adds
  `linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker",
  "__info_plist", "-Xlinker", "Resources/Info.plist"])]` so `swift run` builds carry the same
  plist (unsafeFlags are permitted for the root package). The DMG script is unchanged.
- Permission is requested on first arm via `AVCaptureDevice.requestAccess(for: .audio)`; denied →
  the AUDIO menu items disable with the reason and a "Open Privacy Settings" item.
- Minimum macOS stays 14.0. `AVAudioEngine`, CoreMIDI, `AVAssetExportSession` passthrough and
  `vDSP` are all available there.
- CPU budget: metering ≤ 1 % of a core; the WAV writer queue is off the main and audio threads;
  MTC timer at 96–120 Hz sends 1-byte-payload messages. The frame path is untouched.

## Testing

- `AudioMetersTests`: a full-scale sine → peak 0 dBFS, RMS −3.01 dBFS; silence → −60 floor; a
  1.0-sample burst latches `clipped`; hold decays after 1.5 s of simulated time.
- `RingBufferTests`: write 5 s of a ramp, `preroll(3)` returns exactly the last 3 s in order across
  the wrap point; a request longer than the buffer is clamped.
- `BroadcastWaveTests`: write a 1 s file, finalise with bext/iXML, re-open with `AVAudioFile`
  (still valid), parse chunks: RIFF size correct, `TimeReference` = expected samples since
  midnight, iXML contains TAKE/TAPE/TRACK names.
- `TakeLogTests`: round trip of `TakeLog` JSON; duplicate stem naming; outcome persistence.
- `MIDIMessagesTests`: full frame and the eight quarter frames for 01:02:03:04 at 24 fps match the
  MTC spec bytes (including the rate bits in the hours nibble); MMC bytes.
- `TakeSyncTests`: pairing on synthetic durations (exact, tolerance edge, a skipped take, an extra
  clip); `offset` on two synthetic 48 kHz signals (noise burst + tone) with a known 1.234 s shift
  returns it within ±0.5 ms and confidence ≥ 0.9; uncorrelated noise → confidence < 0.5.
- `FCPXMLTests`: output parses with `XMLDocument`, has `fcpxml@version="1.11"`, one `sync-clip` per
  synced pair with the WAV as a connected `audio`, a plain `asset-clip` for an unpaired clip.
- `TakeExportTests`: build a 2 s test movie (generated frames) with a tone track, export with a WAV
  offset; the result has two audio tracks, video passthrough (same codec and frame count), and the
  WAV track's first sample is the expected one.
- Manual, recorded in the README's hardware section: arm a Scarlett 2i2, meters follow input;
  REC on the α6400 produces a WAV whose length = clip + ~4 s; Logic 11 chases MTC and records on
  REC; Sync Takes on a real card yields `.synced` rows with confidence ≥ 0.9 when the line out feeds
  the camera mic and ≥ 0.5 with the built-in mic; Final Cut imports the FCPXML with clips in sync.
