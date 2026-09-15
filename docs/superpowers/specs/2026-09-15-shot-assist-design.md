# CinemaHUD Shot Assist — live exposure, focus and framing advice on the Mac

Date: 2026-09-15

## Goal

While shooting, the monitor tells the operator in one or two short lines what is wrong with the
shot and offers a one-tap fix: "FACE 1 STOP UNDER · EI 800 → 1600", "FOCUS BEHIND SUBJECT · AF ON
FACE", "HORIZON 3° OFF". The measurements come from the app itself (Vision + Core Image); Apple's
on-device language model phrases and prioritises them where it is available. Nothing leaves the
Mac. Version one is the Mac video monitor (`MonitorView`); the analysis and rules live in the
shared module so the iPhone / iPad viewfinder can adopt them next.

## Facts that shape the design

- **Apple's on-device model is text-only on macOS 26.** The Foundation Models framework
  (`SystemLanguageModel.default`, `LanguageModelSession`, `@Generable` structured output) ships with
  macOS 26 / iOS 26 and requires Apple Intelligence on an M-series Mac. Image attachments and a
  Private Cloud Compute model arrive with macOS 27, which Apple's documentation still marks as beta
  on this date. The model therefore cannot look at the picture in version one; the app measures,
  the model explains.
- **The context window is small** (`model.contextSize`, on the order of 4,000 tokens) and the
  session throws `LanguageModelError.contextSizeExceeded` when it fills. Requests must be one-shot
  and compact.
- **Availability has three states** the UI must handle: `.available`,
  `.unavailable(.appleIntelligenceNotEnabled)`, `.unavailable(.modelNotReady)`; plus the whole
  framework is absent on macOS 14 and 15, which the app still supports (`LSMinimumSystemVersion`
  14.0).
- **Measurement code already exists** and is reused, not duplicated: `FocusAnalyzer.liveRatio`
  (SonyCameraKit) and `LiveSharpnessMeter` (CinemaUI/PhotoView.swift) for sharpness at a point;
  `FrameProcessor.samples` and its histogram for luma statistics; `CameraState` for shutter,
  iris, ISO, EV, WB, exposure mode, focus mode and status, AF point, focal length;
  `OverlaySettings` for project FPS and picture profile.
- **Skin-tone targets depend on the picture profile.** Display-referred (Rec.709 / Standard) skin
  sits around 55 IRE; S-Log2 skin around 32 IRE; S-Log3 around 41 IRE; HLG around 45 IRE. The
  analyzer measures the camera's own feed before the display LUT, so the target follows
  `overlays.profile`.
- **Which control fixes exposure depends on the exposure mode.** In Manual (M / Movie M) the app
  changes ISO; in P / A / S it changes exposure compensation. Only commands the connected camera
  advertises (`state.supports(...)`) may be offered.
- **The frame path is on the GPU and must stay untouched.** Analysis runs on a 512-px copy on a
  background task, at most 4 Hz, skipping when a pass is in flight — the same pattern as
  `LiveSharpnessMeter`.

## Non-goals

- Automatic changes to the camera. Every change is a tap.
- Composition critique from an image model (macOS 27); cloud models; anything networked.
- Photo mode (`PhotoView`) and the iOS layouts. They get the feature after the Mac version works.
- Tool calling / "ask the monitor" conversations.
- Replacing the existing sharpness meter, scopes, false colour or zebras. Assist reads what they
  read; it does not draw over them.

## Architecture

Three layers in `Sources/CinemaUI/Assist/`, each testable alone:

```
frame + camera state ──▶ SceneAnalyzer ──▶ SceneMeasurements
                                              │
                          camera state ───────┼──▶ AssistRules ──▶ [Finding] (facts + fixes)
                                              │                        │
                                              └──▶ ShotAdvisor (Foundation Models, optional)
                                                                       │
                                                                       ▼
                                                              [AdviceLine] ──▶ AssistStrip (HUD)
```

`ShotAdvisor` is optional: when the model is unavailable, the strip shows the findings' own text.
Fixes always come from `AssistRules`, never from the model.

### 1. `SceneAnalyzer` (shared, Core Image + Vision)

`final class SceneAnalyzer` with `func analyze(_ frame: CIImage, afPoint: CGPoint?, profile:
PictureProfile, done: @escaping @MainActor (SceneMeasurements) -> Void)`. Guarded by an in-flight
flag and a 250 ms minimum interval. Downscales to 512 px on the long edge, renders one `CGImage`,
then computes:

```swift
public struct SceneMeasurements: Sendable, Equatable {
    public struct Face: Sendable, Equatable {
        public var rect: CGRect        // normalised, origin top-left, in frame coordinates
        public var luma: Double        // mean luma of the rect, 0–100 (IRE-like)
        public var sharpness: Double   // FocusAnalyzer ratio measured inside the rect
    }
    public var faces: [Face]                 // largest first
    public var afSharpness: Double           // ratio at the AF point (or centre)
    public var sharpestRegion: CGPoint       // centre of the sharpest tile on a 6×4 grid (normalised)
    public var sharpestRatio: Double
    public var meanLuma: Double              // whole frame, 0–100
    public var blackClip: Double             // fraction of pixels ≤ 2/255
    public var whiteClip: Double             // fraction of pixels ≥ 253/255
    public var horizonDegrees: Double?       // nil when Vision finds no horizon
    public var timestamp: Date
}
```

- Faces: `VNDetectFaceRectanglesRequest` on the small image. Vision's normalised rects have a
  bottom-left origin; the analyzer flips them once so everything downstream uses the app's
  top-left convention (the same one `touchAF` and `FrameOverlays` use).
- Luma: from the same RGB byte samples the scopes use (`FrameProcessor.samples`), Rec.709 weights.
- Sharpness: `FocusAnalyzer.liveRatio` over a face rect and over each grid tile; the AF-point value
  is the one `LiveSharpnessMeter` already computes, so the two never disagree.
- Horizon: `VNDetectHorizonRequest`; report `angle` in degrees; nil if the request returns nothing.
- Rotation: the analyzer receives the frame after `overlays.rotation` is applied, so faces and the
  horizon are measured in display orientation.

### 2. `AssistRules` (shared, pure functions)

```swift
public enum FindingKind: String, Sendable { case exposure, focus, framing, settings }
public enum Severity: Sendable { case info, warn }

public struct Fix: Sendable, Equatable {
    public enum Command: Sendable, Equatable {
        case setISO(String), setExposureCompensation(index: Int), setShutterSpeed(String)
        case touchAF(x: Double, y: Double), autofocus
    }
    public var label: String      // "EI 800 → 1600", "AF ON FACE", "1/50 → 1/48"
    public var command: Command
}

public struct Finding: Sendable, Equatable, Identifiable {
    public var id: String         // stable per rule, e.g. "face-under", so advice lines can reference it
    public var kind: FindingKind
    public var severity: Severity
    public var fact: String       // the fallback text, uppercase, ≤ 32 chars: "FACE 1 STOP UNDER"
    public var detail: String     // one sentence for the model: "The largest face reads 28 IRE; target 55."
    public var fix: Fix?
}

public enum AssistRules {
    public static func findings(_ m: SceneMeasurements, state: CameraState, profile: PictureProfile,
                                projectFPS: Int, shootingMode: ShootingMode) -> [Finding]
}
```

Rules, in priority order (the list is returned in this order, at most four):

| id | condition | fact | fix |
|---|---|---|---|
| `face-under` / `face-over` | largest face luma off the profile's skin target by ≥ 0.66 stop (`log2(luma/target)`) | `FACE 1 STOP UNDER` (rounded to ⅓ stop) | M mode: ISO candidate nearest the corrected value; P/A/S: EV index ± round(stops × 3); only if the command is supported |
| `highlights-clip` | `whiteClip ≥ 0.02` and no face finding | `HIGHLIGHTS CLIPPING` | none |
| `shadows-crush` | `blackClip ≥ 0.10` and no face finding and mean luma < 25 | `SHADOWS CRUSHED` | none |
| `focus-missed` | face present, face sharpness < 0.6 × sharpestRatio, and sharpest region ≥ 0.15 (normalised) from the face centre | `FOCUS OFF SUBJECT` | `touchAF` at the face centre when supported |
| `focus-failed` | `state.focusStatus == "Failed"` | `AF FAILED` | `autofocus` |
| `shutter-angle` | video mode; shutter angle for `projectFPS` outside 150–210° | `SHUTTER 45°` | `setShutterSpeed` to the candidate whose angle is nearest 180° |
| `horizon` | `abs(horizonDegrees) ≥ 1.5` | `HORIZON 3° OFF` | none |
| `headroom` | largest face top < 0.02 of frame height, or face centre y > 0.62 | `TOO TIGHT ON TOP` / `SUBJECT LOW IN FRAME` | none |

Debounce lives in the caller: a finding must hold for two consecutive analyses (≈ 0.5 s) before it
is shown, and must be absent for two before it is removed, so the strip does not flicker.

### 3. `ShotAdvisor` (Mac, Foundation Models, optional)

```swift
#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
final class ShotAdvisor {
    enum State { case available, appleIntelligenceOff, modelNotReady, unsupported }
    var state: State
    func advise(findings: [Finding], measurements: SceneMeasurements, state: CameraState,
                profile: PictureProfile, projectFPS: Int) async -> [AdviceLine]?
}
#endif

public struct AdviceLine: Sendable, Equatable, Identifiable {
    public var id: String           // the finding id it explains
    public var text: String         // ≤ 40 chars, uppercase in the HUD
}
```

- Instructions (fixed per session): "You are the on-set assistant on a cinema monitor for a Sony
  α6400. You receive measurements and findings; you do not see the picture. Reply with at most two
  lines, most important first. Each line explains one finding in at most eight words, in the
  clipped voice of a camera assistant. Never suggest values; fixes are attached separately."
- Prompt (per call, ≤ 600 tokens): camera state on one line (mode, shutter with angle, iris, EI,
  EV, WB, focus mode and status, profile, FPS), the measurements as short `key=value` pairs, then
  each finding's `id` and `detail`.
- Output: `@Generable struct Advice { @Guide(.maximumCount(2)) var lines: [Line] }` with
  `@Generable struct Line { @Guide(description: "id of the finding") var finding: String; var text: String }`.
  Lines whose `finding` is not in the input are dropped; missing lines fall back to the finding's
  `fact`.
- Cadence: called only when the debounced finding set (ids + facts) changes, and no more than once
  per 1.5 s. Prewarm the session on connect (`session.prewarm()`). Each call is a fresh
  `LanguageModelSession` (no history), so the context cannot fill; `contextSizeExceeded` is still
  caught and falls back to facts.
- If a call takes longer than 2 s, the strip shows the facts and the late answer is discarded.

### 4. `AssistStrip` and MonitorView integration

- `OverlaySettings.assist: Bool` (persisted, default true) and `EdgeButton("ASSIST")` in
  `LeftTools` below `CROP`, orange while on.
- `MonitorView` owns a `SceneAnalyzer`, the debounce, and (when available) a `ShotAdvisor`. It feeds
  the analyzer from the same `reprocess(_:)` path that feeds the sharpness meter, using the
  colour-interpreted source frame (before LUT and effects) so measurements match the camera.
- `AssistStrip` renders over the picture, top-left, 8 pt below the top strip: up to two rows,
  `Theme.label(10)` tracked text on `Color.black.opacity(0.55)` pills. A row with a fix is a
  `Button` whose label reads `FACT · FIX ↵`; tapping runs the `Fix.Command` through
  `CameraSession` (`setISO`, `setExposureCompensation(index:)`, `setShutterSpeed`, `touchAF`,
  `autofocus`) and the row shows `APPLIED` for 1.5 s. Rows fade out 6 s after the finding clears.
  Colour: `Theme.warn` for `.warn`, `Theme.dim` for `.info`; nothing red (red is recording).
- A pending `touchAF` fix draws a dashed `BracketFrame` at the proposed point in `Theme.warn` until
  applied, dismissed, or superseded.
- A small `AI` tag at the row's left edge appears only when the line came from the model, so the
  operator knows a phrased line from a rule's own fact.
- `hideHUD` hides the strip like everything else.

### 5. Availability, privacy, performance

- All processing is on device; no network access is added.
- Minimum macOS stays 14.0. `ShotAdvisor` is compiled under `#if canImport(FoundationModels)` and
  used under `if #available(macOS 26, *)`; on older systems or when `state != .available`, the
  strip shows facts and the Settings panel's Monitor section shows a one-line reason ("Apple
  Intelligence is off", "Model not ready", "Needs macOS 26").
- Budget: one analysis pass ≤ 15 ms on the background queue at ≤ 4 Hz; the model call is async
  and off the frame path; the strip is plain SwiftUI text, no per-frame layout.
- Assist state (`findings`, `advice`, `pendingFix`) lives in `MonitorView` `@State`, not in the
  session, so it resets on reconnect.

## Testing

- `AssistRulesTests` (swift test): synthetic `SceneMeasurements` + `CameraState` covering: stop
  maths at ⅓-stop rounding; ISO fix in M vs EV fix in A; no fix when the command is unsupported;
  shutter-angle suggestion picks the candidate nearest 180° at 24 and 60 fps; focus-missed needs
  both a soft face and a distant sharp region; horizon and headroom thresholds; ordering and the
  cap of four.
- `SceneAnalyzerTests`: synthetic `CGImage`s — a gradient with 5 % white clip reports
  `whiteClip ≈ 0.05`; a sharp checker tile beside a blurred one puts `sharpestRegion` on the tile;
  face detection is not asserted (no synthetic face), only that an empty `faces` array is returned
  for a gradient.
- Advice parsing: a test double for the advisor result checks that lines referencing unknown
  finding ids are dropped and that missing lines fall back to facts.
- Manual: `tools/camerasim.py --photo <path.jpg>` serves a still photo as the live view so a face
  can be checked without the camera; on the user's Mac with Apple Intelligence on, confirm the
  three availability states and one applied fix of each kind on the α6400 over USB.
