# Shot Assist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Live exposure, focus and framing advisories with one-tap fixes in the Mac video monitor, measured by the app and phrased by Apple's on-device model where available.

**Architecture:** Three layers in `Sources/CinemaUI/Assist/`: `SceneAnalyzer` (Vision + Core Image measurements on a small copy of the frame), `AssistRules` (pure rules turning measurements + camera state into findings with real camera fixes), and `ShotAdvisor` (Foundation Models, optional, phrases at most two lines, each tied to a finding id). An `@Observable AssistController` owns timing, debounce and fix application; `AssistStrip` renders it over the picture in `MonitorView`.

**Tech Stack:** Swift 6 / SwiftUI, Core Image, Vision (`VNDetectFaceRectanglesRequest`, `VNDetectHorizonRequest`), FoundationModels (macOS 26+, behind `#if canImport`), XCTest via `swift test`.

**Spec:** `docs/superpowers/specs/2026-09-15-shot-assist-design.md`

## Global Constraints

- Minimum macOS stays `14.0` (`Resources/Info.plist` `LSMinimumSystemVersion`); `Package.swift` platforms stay `.macOS(.v14), .iOS(.v17)`.
- Foundation Models code compiles only under `#if canImport(FoundationModels)` and runs only under `if #available(macOS 26, iOS 26, *)`.
- No network access. No automatic camera changes: every fix is applied by a tap.
- Analysis runs off the main thread on a ≤ 512-px copy, at most every 250 ms, skipped while a pass is in flight. The GPU frame path (`FrameProcessor.pipeline`, `MetalFrameView`) is not touched.
- Fixes come only from `AssistRules`; the model returns text tied to finding ids and can never supply a camera value.
- Only offer a fix whose command the camera advertises: `state.supports("setIsoSpeedRate")`, `"setExposureCompensation"`, `"setShutterSpeed"`, `"setTouchAFPosition"`, `"actHalfPressShutter"`.
- Test target is `SonyCameraKitTests`, which already depends on `CinemaUI` (`@testable import CinemaUI`). Run with `swift test --filter <TestClass>`.
- Commit after every task with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Measurement and finding types, shutter-angle helper

**Files:**
- Create: `Sources/CinemaUI/Assist/AssistTypes.swift`
- Create: `Sources/CinemaUI/Assist/ShutterAngle.swift`
- Modify: `Sources/CinemaUI/HUDBars.swift:158-171` (TopStrip's private `shutterAngle` / `exposureSeconds` become calls into `ShutterAngle`)
- Test: `Tests/SonyCameraKitTests/ShutterAngleTests.swift`

**Interfaces:**
- Produces: `SceneMeasurements`, `SceneMeasurements.Face`, `FindingKind`, `Severity`, `Fix`, `Fix.Command`, `Finding`, `AdviceLine`, `ShutterAngle.seconds(_:)`, `ShutterAngle.degrees(speed:fps:)`, `ShutterAngle.label(speed:fps:)`, `ShutterAngle.nearest180(candidates:fps:)`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SonyCameraKitTests/ShutterAngleTests.swift
import XCTest
@testable import CinemaUI

final class ShutterAngleTests: XCTestCase {
    func testSecondsParsesFractionsWholeAndBulb() {
        XCTAssertEqual(ShutterAngle.seconds("1/50")!, 0.02, accuracy: 1e-9)
        XCTAssertEqual(ShutterAngle.seconds("2\"")!, 2, accuracy: 1e-9)
        XCTAssertNil(ShutterAngle.seconds("BULB"))
        XCTAssertNil(ShutterAngle.seconds("--"))
    }
    func testDegreesAndLabel() {
        XCTAssertEqual(ShutterAngle.degrees(speed: "1/50", fps: 24)!, 172.8, accuracy: 0.01)
        XCTAssertEqual(ShutterAngle.label(speed: "1/50", fps: 24), "172.8")
        XCTAssertEqual(ShutterAngle.label(speed: "1/10", fps: 24), "360+")
        XCTAssertEqual(ShutterAngle.label(speed: nil, fps: 24), "--")
    }
    func testNearest180PicksTheClosestCandidate() {
        let c = ["1/500", "1/250", "1/125", "1/60", "1/50", "1/48", "1/30"]
        XCTAssertEqual(ShutterAngle.nearest180(candidates: c, fps: 24), "1/48")
        XCTAssertEqual(ShutterAngle.nearest180(candidates: c, fps: 60), "1/125")
        XCTAssertNil(ShutterAngle.nearest180(candidates: [], fps: 24))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ShutterAngleTests`
Expected: compile error, `cannot find 'ShutterAngle' in scope`.

- [ ] **Step 3: Write the types and the helper**

```swift
// Sources/CinemaUI/Assist/AssistTypes.swift
import Foundation
import CoreGraphics

/// What the analyzer measured on the latest frame. All rects and points are normalised to the
/// displayed picture with a top-left origin, the convention `touchAF` and `FrameOverlays` use.
public struct SceneMeasurements: Sendable, Equatable {
    public struct Face: Sendable, Equatable {
        public var rect: CGRect
        public var luma: Double        // mean luma of the rect, 0–100 (IRE-like)
        public var sharpness: Double   // Laplacian variance inside the rect
        public init(rect: CGRect, luma: Double, sharpness: Double) { self.rect = rect; self.luma = luma; self.sharpness = sharpness }
        public var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    }
    public var faces: [Face] = []            // largest first
    public var afSharpness: Double = 0       // FocusAnalyzer ratio at the AF point (or centre), 0…1
    public var sharpestRegion: CGPoint = CGPoint(x: 0.5, y: 0.5)
    public var sharpestScore: Double = 0     // Laplacian variance of the sharpest tile
    public var meanLuma: Double = 0          // whole frame, 0–100
    public var blackClip: Double = 0         // fraction of pixels ≤ 2/255
    public var whiteClip: Double = 0         // fraction of pixels ≥ 253/255
    public var horizonDegrees: Double?       // nil when Vision finds no horizon
    public var timestamp = Date()
    public init() {}
}

public enum FindingKind: String, Sendable { case exposure, focus, framing, settings }
public enum Severity: Sendable, Equatable { case info, warn }

/// A camera change the operator can apply with one tap. Built only by `AssistRules`.
public struct Fix: Sendable, Equatable {
    public enum Command: Sendable, Equatable {
        case setISO(String)
        case setExposureCompensation(index: Int)
        case setShutterSpeed(String)
        case touchAF(x: Double, y: Double)
        case autofocus
    }
    public var label: String      // "EI 800 → 1600", "AF ON FACE", "1/50 → 1/48"
    public var command: Command
    public init(label: String, command: Command) { self.label = label; self.command = command }
}

public struct Finding: Sendable, Equatable, Identifiable {
    public var id: String         // stable per rule, e.g. "face-under"
    public var kind: FindingKind
    public var severity: Severity
    public var fact: String       // fallback HUD text, uppercase, ≤ 32 chars
    public var detail: String     // one sentence for the model
    public var fix: Fix?
    public init(id: String, kind: FindingKind, severity: Severity, fact: String, detail: String, fix: Fix? = nil) {
        self.id = id; self.kind = kind; self.severity = severity; self.fact = fact; self.detail = detail; self.fix = fix
    }
}

/// One HUD line: a finding's fact, or the model's phrasing of it.
public struct AdviceLine: Sendable, Equatable, Identifiable {
    public var id: String          // the finding id
    public var text: String        // uppercase, ≤ 40 chars
    public var fromModel: Bool
    public init(id: String, text: String, fromModel: Bool) { self.id = id; self.text = text; self.fromModel = fromModel }
}
```

```swift
// Sources/CinemaUI/Assist/ShutterAngle.swift
import Foundation

/// Shutter speed ⇄ shutter angle for a project frame rate. Shared by the top strip and the assist rules.
public enum ShutterAngle {
    /// Exposure time in seconds for a Sony speed string ("1/50", "2\"", "0.5"). nil for BULB / "--".
    public static func seconds(_ s: String) -> Double? {
        if s.uppercased() == "BULB" || s == "--" { return nil }
        if s.hasSuffix("\"") { return Double(s.dropLast()) }
        let p = s.split(separator: "/")
        if p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b > 0 { return a / b }
        return Double(s)
    }
    public static func degrees(speed: String?, fps: Int) -> Double? {
        guard let speed, let secs = seconds(speed) else { return nil }
        return 360.0 * Double(fps) * secs
    }
    /// "172.8", "360+" or "--" as shown in the strip.
    public static func label(speed: String?, fps: Int) -> String {
        guard let d = degrees(speed: speed, fps: fps) else { return "--" }
        return d > 360 ? "360+" : String(format: "%.1f", d)
    }
    /// The candidate whose angle is closest to 180° at `fps`.
    public static func nearest180(candidates: [String], fps: Int) -> String? {
        candidates.compactMap { c in degrees(speed: c, fps: fps).map { (c, abs($0 - 180)) } }
            .min { $0.1 < $1.1 }?.0
    }
}
```

In `HUDBars.swift`, replace TopStrip's two private helpers:

```swift
    private func shutterAngle(_ speed: String?, fps: Int) -> String { ShutterAngle.label(speed: speed, fps: fps) }
```

and delete `private func exposureSeconds(_:)` (lines 164-170).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ShutterAngleTests` then `swift build`
Expected: 3 tests pass; the package builds (TopStrip compiles against the helper).

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaUI/Assist/AssistTypes.swift Sources/CinemaUI/Assist/ShutterAngle.swift Sources/CinemaUI/HUDBars.swift Tests/SonyCameraKitTests/ShutterAngleTests.swift
git commit -m "Assist: measurement and finding types; shared shutter-angle helper

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Rules

**Files:**
- Create: `Sources/CinemaUI/Assist/AssistRules.swift`
- Test: `Tests/SonyCameraKitTests/AssistRulesTests.swift`

**Interfaces:**
- Consumes: Task 1 types; `CameraState` (`exposureMode`, `iso`, `isoCandidates`, `exposureCompensation`, `shutterSpeed`, `shutterSpeedCandidates`, `focusStatus`, `supports(_:)`), `PictureProfile`, `ShootingMode`.
- Produces: `AssistRules.skinTarget(for:)`, `AssistRules.findings(_:state:profile:projectFPS:shootingMode:) -> [Finding]`, `AssistRules.stopsLabel(_:)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SonyCameraKitTests/AssistRulesTests.swift
import XCTest
import CoreGraphics
@testable import CinemaUI
@testable import SonyCameraKit

final class AssistRulesTests: XCTestCase {
    private func manualState() -> CameraState {
        var s = CameraState()
        s.exposureMode = "Manual"
        s.iso = "800"; s.isoCandidates = ["AUTO", "100", "200", "400", "800", "1600", "3200", "6400"]
        s.shutterSpeed = "1/50"; s.shutterSpeedCandidates = ["1/500", "1/125", "1/60", "1/50", "1/48", "1/30"]
        s.exposureCompensation = ExposureCompensation(index: 0, minIndex: -9, maxIndex: 9, stepIndex: 3)
        s.availableAPIs = ["setIsoSpeedRate", "setExposureCompensation", "setShutterSpeed", "setTouchAFPosition", "actHalfPressShutter"]
        return s
    }
    private func face(luma: Double, sharpness: Double = 100, rect: CGRect = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3)) -> SceneMeasurements {
        var m = SceneMeasurements()
        m.faces = [.init(rect: rect, luma: luma, sharpness: sharpness)]
        m.sharpestRegion = CGPoint(x: 0.5, y: 0.35); m.sharpestScore = 100; m.meanLuma = 45
        return m
    }
    private func findings(_ m: SceneMeasurements, _ s: CameraState, profile: PictureProfile = .standard, fps: Int = 24, mode: ShootingMode = .video) -> [Finding] {
        AssistRules.findings(m, state: s, profile: profile, projectFPS: fps, shootingMode: mode)
    }

    func testSkinTargetsFollowProfile() {
        XCTAssertEqual(AssistRules.skinTarget(for: .standard), 55)
        XCTAssertEqual(AssistRules.skinTarget(for: .pp7), 32)
        XCTAssertEqual(AssistRules.skinTarget(for: .pp8), 41)
        XCTAssertEqual(AssistRules.skinTarget(for: .pp10), 45)
    }
    func testStopsLabelRoundsToThirds() {
        XCTAssertEqual(AssistRules.stopsLabel(1.0), "1 STOP")
        XCTAssertEqual(AssistRules.stopsLabel(1.28), "1.3 STOPS")
        XCTAssertEqual(AssistRules.stopsLabel(0.7), "0.7 STOP")
    }
    func testFaceOneStopUnderInManualOffersISO() {
        let f = findings(face(luma: 27.5), manualState())   // 27.5 is exactly one stop under 55
        let under = try! XCTUnwrap(f.first { $0.id == "face-under" })
        XCTAssertEqual(under.fact, "FACE 1 STOP UNDER")
        XCTAssertEqual(under.severity, .warn)
        XCTAssertEqual(under.fix, Fix(label: "EI 800 → 1600", command: .setISO("1600")))
    }
    func testFaceOverInApertureModeOffersEV() {
        var s = manualState(); s.exposureMode = "Aperture"
        let f = findings(face(luma: 110), s)                // one stop over
        let over = try! XCTUnwrap(f.first { $0.id == "face-over" })
        XCTAssertEqual(over.fix, Fix(label: "EV 0 → -1.0", command: .setExposureCompensation(index: -3)))
    }
    func testNoFixWhenCommandUnsupported() {
        var s = manualState(); s.availableAPIs.remove("setIsoSpeedRate")
        let under = try! XCTUnwrap(findings(face(luma: 27.5), s).first { $0.id == "face-under" })
        XCTAssertNil(under.fix)
    }
    func testSmallErrorIsNotAFinding() {
        XCTAssertNil(findings(face(luma: 45), manualState()).first { $0.id.hasPrefix("face-") })   // 0.29 stop
    }
    func testClippingOnlyWithoutFaceFinding() {
        var m = face(luma: 55); m.whiteClip = 0.05
        XCTAssertNotNil(findings(m, manualState()).first { $0.id == "highlights-clip" })
        var m2 = face(luma: 20); m2.whiteClip = 0.05
        XCTAssertNil(findings(m2, manualState()).first { $0.id == "highlights-clip" })
    }
    func testFocusMissedNeedsSoftFaceAndDistantSharpRegion() {
        var m = face(luma: 55, sharpness: 20)               // soft face (< 0.6 × 100)
        m.sharpestRegion = CGPoint(x: 0.9, y: 0.9)          // far from the face centre (0.5, 0.35)
        let miss = try! XCTUnwrap(findings(m, manualState()).first { $0.id == "focus-missed" })
        XCTAssertEqual(miss.fact, "FOCUS OFF SUBJECT")
        XCTAssertEqual(miss.fix, Fix(label: "AF ON FACE", command: .touchAF(x: 0.5, y: 0.35)))
        var near = face(luma: 55, sharpness: 20); near.sharpestRegion = CGPoint(x: 0.55, y: 0.4)
        XCTAssertNil(findings(near, manualState()).first { $0.id == "focus-missed" })
    }
    func testFocusFailedOffersAutofocus() {
        var s = manualState(); s.focusStatus = "Failed"
        let f = try! XCTUnwrap(findings(face(luma: 55), s).first { $0.id == "focus-failed" })
        XCTAssertEqual(f.fix?.command, .autofocus)
    }
    func testShutterAngleFarFrom180InVideoOnly() {
        var s = manualState(); s.shutterSpeed = "1/500"
        let f = try! XCTUnwrap(findings(face(luma: 55), s).first { $0.id == "shutter-angle" })
        XCTAssertEqual(f.fact, "SHUTTER 17°")
        XCTAssertEqual(f.fix, Fix(label: "1/500 → 1/48", command: .setShutterSpeed("1/48")))
        XCTAssertNil(findings(face(luma: 55), s, mode: .photo).first { $0.id == "shutter-angle" })
    }
    func testHorizonAndHeadroom() {
        var m = face(luma: 55, rect: CGRect(x: 0.4, y: 0.0, width: 0.2, height: 0.3)); m.horizonDegrees = 3.2
        let f = findings(m, manualState())
        XCTAssertEqual(f.first { $0.id == "horizon" }?.fact, "HORIZON 3° OFF")
        XCTAssertEqual(f.first { $0.id == "headroom" }?.fact, "TOO TIGHT ON TOP")
        var low = face(luma: 55, rect: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.3))
        low.horizonDegrees = 0.5
        XCTAssertEqual(findings(low, manualState()).first { $0.id == "headroom" }?.fact, "SUBJECT LOW IN FRAME")
    }
    func testOrderAndCap() {
        var s = manualState(); s.focusStatus = "Failed"; s.shutterSpeed = "1/500"
        var m = face(luma: 27.5, sharpness: 20, rect: CGRect(x: 0.4, y: 0.0, width: 0.2, height: 0.3))
        m.sharpestRegion = CGPoint(x: 0.9, y: 0.9); m.horizonDegrees = 5
        let ids = findings(m, s).map(\.id)
        XCTAssertEqual(ids, ["face-under", "focus-missed", "focus-failed", "shutter-angle"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AssistRulesTests`
Expected: compile error, `cannot find 'AssistRules' in scope`.

- [ ] **Step 3: Write the rules**

```swift
// Sources/CinemaUI/Assist/AssistRules.swift
import Foundation
import CoreGraphics
import SonyCameraKit

/// Turns measurements plus camera state into findings. Pure; every fix is a command the connected
/// camera advertises. Order is priority order; at most four are returned.
public enum AssistRules {
    public static let stopThreshold = 0.66
    public static let maxFindings = 4

    /// Skin-tone target (0–100) for the camera's picture profile, measured before the display LUT.
    public static func skinTarget(for profile: PictureProfile) -> Double {
        switch profile {
        case .standard: return 55
        case .pp7: return 32
        case .pp8, .pp9: return 41
        case .pp10: return 45
        }
    }

    /// "1 STOP", "1.3 STOPS", "0.7 STOP": magnitude rounded to the nearest third.
    public static func stopsLabel(_ stops: Double) -> String {
        let thirds = (abs(stops) * 3).rounded() / 3
        if abs(thirds - 1) < 0.01 { return "1 STOP" }
        let text = String(format: "%.1f", thirds)
        return thirds < 1 ? "\(text) STOP" : "\(text) STOPS"
    }

    public static func findings(_ m: SceneMeasurements, state s: CameraState, profile: PictureProfile,
                                projectFPS: Int, shootingMode: ShootingMode) -> [Finding] {
        var out: [Finding] = []
        let face = m.faces.first
        var faceFinding = false

        // Exposure on the face.
        if let face, face.luma > 0 {
            let target = skinTarget(for: profile)
            let stops = log2(face.luma / target)
            if abs(stops) >= stopThreshold {
                let under = stops < 0
                out.append(Finding(id: under ? "face-under" : "face-over", kind: .exposure, severity: .warn,
                                   fact: "FACE \(stopsLabel(stops)) \(under ? "UNDER" : "OVER")",
                                   detail: String(format: "The largest face reads %.0f; the skin target for %@ is %.0f (%.1f stops %@).",
                                                  face.luma, profile.short, target, abs(stops), under ? "under" : "over"),
                                   fix: exposureFix(stops: stops, state: s)))
                faceFinding = true
            }
        }
        if !faceFinding, m.whiteClip >= 0.02 {
            out.append(Finding(id: "highlights-clip", kind: .exposure, severity: .info, fact: "HIGHLIGHTS CLIPPING",
                               detail: String(format: "%.0f%% of pixels are clipped white.", m.whiteClip * 100)))
        }
        if !faceFinding, m.blackClip >= 0.10, m.meanLuma < 25 {
            out.append(Finding(id: "shadows-crush", kind: .exposure, severity: .info, fact: "SHADOWS CRUSHED",
                               detail: String(format: "%.0f%% of pixels are black and the frame averages %.0f.", m.blackClip * 100, m.meanLuma)))
        }

        // Focus.
        if let face, m.sharpestScore > 0, face.sharpness < 0.6 * m.sharpestScore,
           hypot(m.sharpestRegion.x - face.center.x, m.sharpestRegion.y - face.center.y) >= 0.15 {
            let fix = s.supports("setTouchAFPosition")
                ? Fix(label: "AF ON FACE", command: .touchAF(x: Double(face.center.x), y: Double(face.center.y))) : nil
            out.append(Finding(id: "focus-missed", kind: .focus, severity: .warn, fact: "FOCUS OFF SUBJECT",
                               detail: "The face is soft while a region away from it is sharp; focus is not on the subject.", fix: fix))
        }
        if s.focusStatus == "Failed" {
            out.append(Finding(id: "focus-failed", kind: .focus, severity: .warn, fact: "AF FAILED",
                               detail: "The camera reports autofocus failed.",
                               fix: s.supports("actHalfPressShutter") ? Fix(label: "AUTOFOCUS", command: .autofocus) : nil))
        }

        // Settings.
        if shootingMode == .video, let deg = ShutterAngle.degrees(speed: s.shutterSpeed, fps: projectFPS), deg < 150 || deg > 210 {
            var fix: Fix?
            if s.supports("setShutterSpeed"), let best = ShutterAngle.nearest180(candidates: s.shutterSpeedCandidates, fps: projectFPS),
               best != s.shutterSpeed, let cur = s.shutterSpeed {
                fix = Fix(label: "\(cur) → \(best)", command: .setShutterSpeed(best))
            }
            out.append(Finding(id: "shutter-angle", kind: .settings, severity: .info,
                               fact: "SHUTTER \(deg > 360 ? "360+" : String(format: "%.0f", deg))°",
                               detail: String(format: "Shutter %@ is a %.0f° angle at %d fps; 180° gives natural motion blur.", s.shutterSpeed ?? "--", deg, projectFPS),
                               fix: fix))
        }

        // Framing.
        if let h = m.horizonDegrees, abs(h) >= 1.5 {
            out.append(Finding(id: "horizon", kind: .framing, severity: .info, fact: String(format: "HORIZON %.0f° OFF", abs(h)),
                               detail: String(format: "The horizon is tilted %.1f°.", h)))
        }
        if let face {
            if face.rect.minY < 0.02 {
                out.append(Finding(id: "headroom", kind: .framing, severity: .info, fact: "TOO TIGHT ON TOP",
                                   detail: "The face touches the top edge of the frame."))
            } else if face.center.y > 0.62 {
                out.append(Finding(id: "headroom", kind: .framing, severity: .info, fact: "SUBJECT LOW IN FRAME",
                                   detail: "The face sits in the lower third with empty space above it."))
            }
        }
        return Array(out.prefix(maxFindings))
    }

    /// ISO in manual modes, exposure compensation otherwise. nil when the camera cannot do it or is already there.
    static func exposureFix(stops: Double, state s: CameraState) -> Fix? {
        let mode = s.exposureMode ?? ""
        let manual = mode.hasPrefix("Manual") || mode == "Movie M"
        if manual {
            guard s.supports("setIsoSpeedRate"), let cur = s.iso, let curISO = Double(cur) else { return nil }
            let wanted = curISO * pow(2, -stops)
            let numeric = s.isoCandidates.compactMap { c in Double(c).map { (c, $0) } }
            guard let best = numeric.min(by: { abs(log2($0.1 / wanted)) < abs(log2($1.1 / wanted)) })?.0, best != cur else { return nil }
            return Fix(label: "EI \(cur) → \(best)", command: .setISO(best))
        }
        guard s.supports("setExposureCompensation"), let ev = s.exposureCompensation else { return nil }
        let delta = Int((-stops / ev.stepEV).rounded())
        let next = max(ev.minIndex, min(ev.maxIndex, ev.index + delta))
        guard next != ev.index else { return nil }
        func label(_ i: Int) -> String {
            let v = Double(i) * ev.stepEV
            return abs(v) < 0.01 ? "0" : String(format: "%@%.1f", v > 0 ? "+" : "", v)
        }
        return Fix(label: "EV \(label(ev.index)) → \(label(next))", command: .setExposureCompensation(index: next))
    }
}
```

Note for the implementer: `ExposureCompensation` in `CameraState.swift` has `index`, `minIndex`, `maxIndex`, `stepIndex` (3 → ⅓ EV, 2 → ½ EV) and a computed `stepEV`. Check its memberwise initializer is accessible from the test; if it is not public, add `public init(index:minIndex:maxIndex:stepIndex:)` to it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AssistRulesTests`
Expected: 12 tests pass. If `testFaceOverInApertureModeOffersEV` fails on the label, check `stepEV` for `stepIndex: 3` is `1/3` (the label for index −3 must read `-1.0`).

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaUI/Assist/AssistRules.swift Tests/SonyCameraKitTests/AssistRulesTests.swift Sources/SonyCameraKit/CameraState.swift
git commit -m "Assist: rules that turn measurements into findings with camera fixes

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Debounce and line reconciliation

**Files:**
- Create: `Sources/CinemaUI/Assist/AssistDebouncer.swift`
- Test: `Tests/SonyCameraKitTests/AssistDebouncerTests.swift`

**Interfaces:**
- Consumes: `Finding`, `AdviceLine`.
- Produces: `AssistDebouncer` (`mutating func update(with:) -> [Finding]`), `AdviceLine.reconcile(model:findings:) -> [AdviceLine]`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SonyCameraKitTests/AssistDebouncerTests.swift
import XCTest
@testable import CinemaUI

final class AssistDebouncerTests: XCTestCase {
    private func f(_ id: String, fact: String = "X") -> Finding { Finding(id: id, kind: .exposure, severity: .info, fact: fact, detail: "") }

    func testFindingMustHoldTwoPassesToShow() {
        var d = AssistDebouncer()
        XCTAssertEqual(d.update(with: [f("a")]).map(\.id), [])
        XCTAssertEqual(d.update(with: [f("a")]).map(\.id), ["a"])
    }
    func testFindingMustBeAbsentTwoPassesToClear() {
        var d = AssistDebouncer()
        _ = d.update(with: [f("a")]); _ = d.update(with: [f("a")])
        XCTAssertEqual(d.update(with: []).map(\.id), ["a"])   // still shown after one miss
        XCTAssertEqual(d.update(with: []).map(\.id), [])
    }
    func testShownFindingUpdatesItsFactWhilePresent() {
        var d = AssistDebouncer()
        _ = d.update(with: [f("a", fact: "ONE")])
        XCTAssertEqual(d.update(with: [f("a", fact: "TWO")]).first?.fact, "TWO")
    }
    func testOrderFollowsCurrentFindingsThenHeldOnes() {
        var d = AssistDebouncer()
        _ = d.update(with: [f("a"), f("b")]); _ = d.update(with: [f("a"), f("b")])
        XCTAssertEqual(d.update(with: [f("b")]).map(\.id), ["b", "a"])
    }
    func testReconcileUsesModelTextForKnownIdsAndFactsOtherwise() {
        let findings = [f("a", fact: "FACT A"), f("b", fact: "FACT B"), f("c", fact: "FACT C")]
        let lines = AdviceLine.reconcile(model: [("b", "face is a stop under, open up"), ("zzz", "ignored")], findings: findings)
        XCTAssertEqual(lines, [AdviceLine(id: "a", text: "FACT A", fromModel: false),
                               AdviceLine(id: "b", text: "FACE IS A STOP UNDER, OPEN UP", fromModel: true)])
    }
    func testReconcileTruncatesLongTextAndCapsAtTwo() {
        let findings = [f("a"), f("b"), f("c")]
        let long = String(repeating: "x", count: 60)
        let lines = AdviceLine.reconcile(model: [("a", long)], findings: findings)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text.count, 40)
    }
    func testReconcileWithNoModelIsFacts() {
        let lines = AdviceLine.reconcile(model: nil, findings: [f("a", fact: "FACT A")])
        XCTAssertEqual(lines, [AdviceLine(id: "a", text: "FACT A", fromModel: false)])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AssistDebouncerTests`
Expected: compile error, `cannot find 'AssistDebouncer' in scope`.

- [ ] **Step 3: Write the debouncer and reconciliation**

```swift
// Sources/CinemaUI/Assist/AssistDebouncer.swift
import Foundation

/// A finding shows after `required` consecutive passes and clears after `required` consecutive
/// absences, so the strip does not flicker with the analyzer.
public struct AssistDebouncer: Sendable {
    public var required = 2
    private var present: [String: Int] = [:]
    private var absent: [String: Int] = [:]
    private var held: [String: Finding] = [:]
    private var order: [String] = []
    public init(required: Int = 2) { self.required = required }

    public mutating func update(with findings: [Finding]) -> [Finding] {
        let ids = Set(findings.map(\.id))
        for f in findings {
            present[f.id, default: 0] += 1
            absent[f.id] = 0
            held[f.id] = f
        }
        for id in held.keys where !ids.contains(id) {
            absent[id, default: 0] += 1
            present[id] = 0
            if absent[id]! >= required { held[id] = nil; present[id] = nil; absent[id] = nil }
        }
        // Current findings first, in rule order; then held-over ones in the order they were last seen.
        var result: [Finding] = []
        var seen = Set<String>()
        for f in findings where present[f.id, default: 0] >= required { result.append(f); seen.insert(f.id) }
        for id in order where !seen.contains(id) && !ids.contains(id) { if let f = held[id] { result.append(f); seen.insert(id) } }
        order = result.map(\.id)
        return result
    }
}

public extension AdviceLine {
    /// Lines for the first two findings: the model's text where it explained that finding, else the fact.
    static func reconcile(model: [(finding: String, text: String)]?, findings: [Finding]) -> [AdviceLine] {
        let byID = Dictionary((model ?? []).map { ($0.finding, $0.text) }, uniquingKeysWith: { a, _ in a })
        return findings.prefix(2).map { f in
            if let t = byID[f.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return AdviceLine(id: f.id, text: String(t.uppercased().prefix(40)), fromModel: true)
            }
            return AdviceLine(id: f.id, text: f.fact, fromModel: false)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AssistDebouncerTests`
Expected: 7 tests pass. `testOrderFollowsCurrentFindingsThenHeldOnes` depends on `order` carrying "a" from the previous pass; if it fails, confirm `order` is written at the end of every `update`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaUI/Assist/AssistDebouncer.swift Tests/SonyCameraKitTests/AssistDebouncerTests.swift
git commit -m "Assist: debounce findings; reconcile model lines with facts

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Scene analyzer

**Files:**
- Create: `Sources/CinemaUI/Assist/SceneAnalyzer.swift`
- Test: `Tests/SonyCameraKitTests/SceneAnalyzerTests.swift`

**Interfaces:**
- Consumes: `FocusAnalyzer.luma(of:maxLongEdge:)`, `FocusAnalyzer.sharpness(_:in:)`, `FocusAnalyzer.analyze(_:afPoint:regionFraction:tiles:maxLongEdge:)` (SonyCameraKit), `SceneMeasurements`.
- Produces: `SceneAnalyzer.measure(_ image: CGImage, afPoint: CGPoint?) -> SceneMeasurements` (synchronous, pure, testable), `SceneAnalyzer.analyze(_ frame: CIImage, afPoint: CGPoint?, done:)` (throttled, background).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SonyCameraKitTests/SceneAnalyzerTests.swift
import XCTest
import CoreGraphics
@testable import CinemaUI

final class SceneAnalyzerTests: XCTestCase {
    /// 400×300 RGB image filled by `paint`.
    private func image(_ paint: (CGContext, Int, Int) -> Void) -> CGImage {
        let w = 400, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        paint(ctx, w, h)
        return ctx.makeImage()!
    }

    func testClipFractionsAndMeanOnAGradientWithClippedBands() {
        let img = image { ctx, w, h in
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 20))          // 5 % white
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: h - h / 10, width: w, height: h / 10)) // 10 % black
        }
        let m = SceneAnalyzer.measure(img, afPoint: nil)
        XCTAssertEqual(m.whiteClip, 0.05, accuracy: 0.015)
        XCTAssertEqual(m.blackClip, 0.10, accuracy: 0.015)
        XCTAssertEqual(m.meanLuma, 47, accuracy: 6)   // 85 % mid grey (50), 5 % white, 10 % black
        XCTAssertTrue(m.faces.isEmpty)
    }

    func testSharpestRegionLandsOnTheCheckerTile() {
        let img = image { ctx, w, h in
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
            // Checkerboard in the bottom-right quarter (CGContext rows start at the bottom, so y < h/2 is the lower half).
            for y in stride(from: 0, to: h / 2, by: 6) {
                for x in stride(from: w / 2, to: w, by: 6) where ((x / 6) + (y / 6)) % 2 == 0 {
                    ctx.fill(CGRect(x: x, y: y, width: 6, height: 6))
                }
            }
        }
        let m = SceneAnalyzer.measure(img, afPoint: CGPoint(x: 0.25, y: 0.25))
        XCTAssertGreaterThan(m.sharpestRegion.x, 0.5)
        XCTAssertGreaterThan(m.sharpestRegion.y, 0.5)      // top-left origin: the lower half is y > 0.5
        XCTAssertGreaterThan(m.sharpestScore, 100)
        XCTAssertLessThan(m.afSharpness, 0.2)              // the AF point is on flat grey
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SceneAnalyzerTests`
Expected: compile error, `cannot find 'SceneAnalyzer' in scope`.

- [ ] **Step 3: Write the analyzer**

```swift
// Sources/CinemaUI/Assist/SceneAnalyzer.swift
import Foundation
import CoreImage
import CoreGraphics
import Vision
import SonyCameraKit

/// Measures the live frame for the assist rules: faces, sharpness, clipping, horizon. The
/// throttled entry point renders a ≤ 512-px copy off the main thread, like `LiveSharpnessMeter`.
public final class SceneAnalyzer: @unchecked Sendable {
    public static let maxLongEdge = 512
    public static let minInterval: TimeInterval = 0.25
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var inFlight = false
    private var last = Date.distantPast
    public init() {}

    /// Throttled: at most every `minInterval`, one pass at a time. `done` runs on the main actor.
    public func analyze(_ frame: CIImage, afPoint: CGPoint?, done: @escaping @MainActor (SceneMeasurements) -> Void) {
        guard !inFlight, Date().timeIntervalSince(last) >= Self.minInterval else { return }
        inFlight = true; last = Date()
        let ctx = context
        let scale = min(1, CGFloat(Self.maxLongEdge) / max(frame.extent.width, frame.extent.height))
        let small = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        Task.detached(priority: .utility) { [weak self] in
            defer { self?.inFlight = false }
            guard let cg = ctx.createCGImage(small, from: small.extent) else { return }
            let m = Self.measure(cg, afPoint: afPoint)
            await MainActor.run { done(m) }
        }
    }

    /// Pure measurement of one image. `afPoint` is normalised, top-left origin; nil = centre.
    public static func measure(_ image: CGImage, afPoint: CGPoint?) -> SceneMeasurements {
        var m = SceneMeasurements()
        guard let l = FocusAnalyzer.luma(of: image, maxLongEdge: maxLongEdge) else { return m }

        // Luma statistics from the grey plane.
        var sum = 0, black = 0, white = 0
        for v in l.pixels { sum += Int(v); if v <= 2 { black += 1 } else if v >= 253 { white += 1 } }
        let n = Double(l.pixels.count)
        m.meanLuma = Double(sum) / n / 2.55
        m.blackClip = Double(black) / n
        m.whiteClip = Double(white) / n

        // Sharpness: the AF-point ratio the sharpness meter already uses, and the sharpest tile.
        if let r = FocusAnalyzer.analyze(image, afPoint: afPoint, regionFraction: 0.14, tiles: 8, maxLongEdge: maxLongEdge) {
            m.afSharpness = r.ratio
            m.sharpestRegion = r.peakPoint
            m.sharpestScore = r.peakScore
        }

        // Faces and horizon from Vision (top-left origin downstream; Vision reports bottom-left).
        let faces = VNDetectFaceRectanglesRequest()
        let horizon = VNDetectHorizonRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([faces, horizon])
        let aspect = CGFloat(l.width) / CGFloat(l.height)
        m.faces = (faces.results ?? [])
            .map { obs -> SceneMeasurements.Face in
                let b = obs.boundingBox
                let rect = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                return SceneMeasurements.Face(rect: rect, luma: meanLuma(l, in: rect), sharpness: FocusAnalyzer.sharpness(l, in: rect))
            }
            .sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
        _ = aspect
        if let h = horizon.results?.first { m.horizonDegrees = Double(h.angle) * 180 / .pi }
        m.timestamp = Date()
        return m
    }

    /// Mean luma (0–100) of a normalised rect of the grey plane.
    static func meanLuma(_ l: FocusAnalyzer.Luma, in rect: CGRect) -> Double {
        let x0 = max(0, Int(rect.minX * CGFloat(l.width))), x1 = min(l.width, Int(rect.maxX * CGFloat(l.width)))
        let y0 = max(0, Int(rect.minY * CGFloat(l.height))), y1 = min(l.height, Int(rect.maxY * CGFloat(l.height)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var sum = 0
        for y in y0 ..< y1 { for x in x0 ..< x1 { sum += Int(l.pixels[y * l.width + x]) } }
        return Double(sum) / Double((x1 - x0) * (y1 - y0)) / 2.55
    }
}
```

Remove the unused `aspect` lines if the compiler warns; they are there only to make the flip explicit.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SceneAnalyzerTests`
Expected: 2 tests pass. If `testSharpestRegionLandsOnTheCheckerTile` fails on `y`, the `CGContext` origin assumption is wrong for this platform: the `FocusAnalyzer` bitmap draw puts row 0 at the top, so a checkerboard painted at `y < h/2` in the context ends up in the lower half of the picture. Adjust the test's painted region rather than the analyzer.

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaUI/Assist/SceneAnalyzer.swift Tests/SonyCameraKitTests/SceneAnalyzerTests.swift
git commit -m "Assist: scene analyzer (faces, sharpness, clipping, horizon) on a small frame copy

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Advisor prompt and Foundation Models bridge

**Files:**
- Create: `Sources/CinemaUI/Assist/AdvisorPrompt.swift`
- Create: `Sources/CinemaUI/Assist/ShotAdvisor.swift`
- Test: `Tests/SonyCameraKitTests/AdvisorPromptTests.swift`

**Interfaces:**
- Consumes: `Finding`, `SceneMeasurements`, `CameraState`, `PictureProfile`, `ShutterAngle.label(speed:fps:)`.
- Produces: `AdvisorPrompt.instructions: String`, `AdvisorPrompt.build(findings:measurements:state:profile:projectFPS:) -> String`, `ShotAdvisorAvailability` (`enum State`, `static var current: State`, `var reason: String?`), and on macOS 26+ `ShotAdvisor.advise(prompt:) async -> [(finding: String, text: String)]?`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SonyCameraKitTests/AdvisorPromptTests.swift
import XCTest
import CoreGraphics
@testable import CinemaUI
@testable import SonyCameraKit

final class AdvisorPromptTests: XCTestCase {
    func testPromptCarriesStateMeasurementsAndFindingIds() {
        var s = CameraState()
        s.exposureMode = "Manual"; s.shutterSpeed = "1/50"; s.fNumber = "2.8"; s.iso = "800"; s.focusMode = "AF-C"; s.focusStatus = "Focused"
        var m = SceneMeasurements(); m.meanLuma = 42; m.whiteClip = 0.031; m.horizonDegrees = 2.2
        m.faces = [.init(rect: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3), luma: 28, sharpness: 12)]
        let f = [Finding(id: "face-under", kind: .exposure, severity: .warn, fact: "FACE 1 STOP UNDER", detail: "The largest face reads 28; target 55."),
                 Finding(id: "horizon", kind: .framing, severity: .info, fact: "HORIZON 2° OFF", detail: "The horizon is tilted 2.2°.")]
        let p = AdvisorPrompt.build(findings: f, measurements: m, state: s, profile: .standard, projectFPS: 24)
        XCTAssertTrue(p.contains("mode=Manual"))
        XCTAssertTrue(p.contains("shutter=1/50 (172.8°)"))
        XCTAssertTrue(p.contains("iris=F2.8"))
        XCTAssertTrue(p.contains("ei=800"))
        XCTAssertTrue(p.contains("profile=STD"))
        XCTAssertTrue(p.contains("face_luma=28"))
        XCTAssertTrue(p.contains("white_clip=3%"))
        XCTAssertTrue(p.contains("horizon=2.2°"))
        XCTAssertTrue(p.contains("[face-under] The largest face reads 28; target 55."))
        XCTAssertTrue(p.contains("[horizon] The horizon is tilted 2.2°."))
        XCTAssertLessThan(p.count, 1200, "prompt must stay small for the on-device context")
    }
    func testInstructionsForbidValues() {
        XCTAssertTrue(AdvisorPrompt.instructions.contains("Never suggest values"))
    }
    func testAvailabilityReasonIsNilOnlyWhenAvailable() {
        let a = ShotAdvisorAvailability.current
        if case .available = a { XCTAssertNil(a.reason) } else { XCTAssertNotNil(a.reason) }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AdvisorPromptTests`
Expected: compile error, `cannot find 'AdvisorPrompt' in scope`.

- [ ] **Step 3: Write the prompt builder, availability and the bridge**

```swift
// Sources/CinemaUI/Assist/AdvisorPrompt.swift
import Foundation
import SonyCameraKit

/// The text the on-device model sees. Compact key=value lines; the model never sees pixels.
public enum AdvisorPrompt {
    public static let instructions = """
    You are the on-set assistant on a cinema monitor for a Sony α6400. You receive camera settings, \
    measurements of the live frame, and findings; you do not see the picture. Reply with at most two \
    lines, most important first. Each line explains one finding in at most eight words, in the clipped \
    voice of a camera assistant. Never suggest values; fixes are attached separately.
    """

    public static func build(findings: [Finding], measurements m: SceneMeasurements, state s: CameraState,
                             profile: PictureProfile, projectFPS: Int) -> String {
        var lines: [String] = []
        lines.append("camera: mode=\(s.exposureMode ?? "--") shutter=\(s.shutterSpeed ?? "--") (\(ShutterAngle.label(speed: s.shutterSpeed, fps: projectFPS))°) "
                     + "iris=F\(s.fNumber ?? "--") ei=\(s.iso ?? "--") ev=\(s.exposureCompensation?.label ?? "--") wb=\(s.whiteBalanceMode ?? "--") "
                     + "focus=\(s.focusMode ?? "--")/\(s.focusStatus ?? "--") profile=\(profile.short) fps=\(projectFPS)")
        var meas = "frame: mean_luma=\(Int(m.meanLuma.rounded())) white_clip=\(Int((m.whiteClip * 100).rounded()))% black_clip=\(Int((m.blackClip * 100).rounded()))% af_sharpness=\(String(format: "%.2f", m.afSharpness))"
        if let f = m.faces.first {
            meas += " faces=\(m.faces.count) face_luma=\(Int(f.luma.rounded())) face_x=\(String(format: "%.2f", f.center.x)) face_y=\(String(format: "%.2f", f.center.y))"
        } else { meas += " faces=0" }
        if let h = m.horizonDegrees { meas += " horizon=\(String(format: "%.1f", h))°" }
        lines.append(meas)
        lines.append("findings:")
        for f in findings { lines.append("[\(f.id)] \(f.detail)") }
        return lines.joined(separator: "\n")
    }
}

/// Whether the on-device model can be used right now, and why not.
public enum ShotAdvisorAvailability: Equatable {
    case available, appleIntelligenceOff, modelNotReady, deviceNotEligible, needsOS26

    public var reason: String? {
        switch self {
        case .available: return nil
        case .appleIntelligenceOff: return "Apple Intelligence is off in System Settings"
        case .modelNotReady: return "Apple Intelligence model is not ready yet"
        case .deviceNotEligible: return "This device does not support Apple Intelligence"
        case .needsOS26: return "Needs macOS 26 or later"
        }
    }

    public static var current: ShotAdvisorAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) { return ShotAdvisor.availability }
        #endif
        return .needsOS26
    }
}
```

```swift
// Sources/CinemaUI/Assist/ShotAdvisor.swift
#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26, iOS 26, *)
@Generable
struct AssistAdviceLine {
    @Guide(description: "The id of the finding this line explains, exactly as given in brackets")
    var finding: String
    @Guide(description: "At most eight words, the clipped voice of a camera assistant")
    var text: String
}

@available(macOS 26, iOS 26, *)
@Generable
struct AssistAdvice {
    @Guide(description: "At most two lines, most important first", .maximumCount(2))
    var lines: [AssistAdviceLine]
}

/// Phrases findings with Apple's on-device model. One fresh session per call keeps the small
/// context from filling; every failure returns nil and the HUD falls back to the findings' facts.
@available(macOS 26, iOS 26, *)
public enum ShotAdvisor {
    static var availability: ShotAdvisorAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .deviceNotEligible
        }
    }

    public static func prewarm() {
        guard availability == .available else { return }
        LanguageModelSession(instructions: AdvisorPrompt.instructions).prewarm()
    }

    /// nil when unavailable, on any error, or after `timeout` seconds.
    public static func advise(prompt: String, timeout: TimeInterval = 2) async -> [(finding: String, text: String)]? {
        guard availability == .available else { return nil }
        let session = LanguageModelSession(instructions: AdvisorPrompt.instructions)
        return await withTaskGroup(of: [(finding: String, text: String)]?.self) { group in
            group.addTask {
                do {
                    let r = try await session.respond(to: prompt, generating: AssistAdvice.self)
                    return r.content.lines.map { (finding: $0.finding, text: $0.text) }
                } catch { return nil }
            }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
#endif
```

If the compiler rejects `@Guide(description:, .maximumCount(2))`, use `@Guide(.maximumCount(2))` alone and put the sentence in the property's doc comment; if `prewarm()` does not exist on this SDK, delete the `prewarm` function and its caller in Task 6.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AdvisorPromptTests` then `swift build`
Expected: 3 tests pass; the whole package builds with the FoundationModels file compiled (the machine has the macOS 26 SDK).

- [ ] **Step 5: Commit**

```bash
git add Sources/CinemaUI/Assist/AdvisorPrompt.swift Sources/CinemaUI/Assist/ShotAdvisor.swift Tests/SonyCameraKitTests/AdvisorPromptTests.swift
git commit -m "Assist: advisor prompt, availability, and the Foundation Models bridge

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Controller, HUD strip, MonitorView integration, ASSIST button, settings line

**Files:**
- Create: `Sources/CinemaUI/Assist/AssistController.swift`
- Create: `Sources/CinemaUI/Assist/AssistStrip.swift`
- Modify: `Sources/CinemaUI/Settings.swift` (`OverlaySettings`: add `assist`)
- Modify: `Sources/CinemaUI/MonitorView.swift` (feed the controller from `reprocess`, render the strip and the pending-AF bracket)
- Modify: `Sources/CinemaUI/HUDBars.swift` (`LeftTools`: ASSIST button after CROP; `SettingsPanel` Monitor section: assist row)
- Test: `Tests/SonyCameraKitTests/AssistControllerTests.swift`

**Interfaces:**
- Consumes: everything above; `CameraSession` (`setISO`, `setExposureCompensation(index:)`, `setShutterSpeed`, `touchAF(x:y:)`, `autofocus`, `state`, `frame`, `focusCheckPoint`), `OverlaySettings` (`profile`, `projectFPS`, `shootingMode`, `hideHUD`, `rotation`), `EdgeButton`, `BracketFrame`, `Theme`.
- Produces: `AssistController` (`ingest(measurements:state:profile:projectFPS:shootingMode:)`, `lines`, `pendingAF`, `apply(_:session:)`, `visible`), `AssistStrip` view.

- [ ] **Step 1: Write the failing test for the controller's pure parts**

```swift
// Tests/SonyCameraKitTests/AssistControllerTests.swift
import XCTest
import CoreGraphics
@testable import CinemaUI
@testable import SonyCameraKit

@MainActor
final class AssistControllerTests: XCTestCase {
    private func state() -> CameraState {
        var s = CameraState(); s.exposureMode = "Manual"; s.iso = "800"; s.isoCandidates = ["400", "800", "1600"]
        s.availableAPIs = ["setIsoSpeedRate", "setTouchAFPosition"]; return s
    }
    private func under() -> SceneMeasurements {
        var m = SceneMeasurements(); m.faces = [.init(rect: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3), luma: 27.5, sharpness: 100)]
        m.sharpestScore = 100; m.sharpestRegion = CGPoint(x: 0.5, y: 0.35); return m
    }

    func testLinesAppearAfterTwoPassesAndCarryTheFix() {
        let c = AssistController(useModel: false)
        c.ingest(measurements: under(), state: state(), profile: .standard, projectFPS: 24, shootingMode: .video)
        XCTAssertTrue(c.lines.isEmpty)
        c.ingest(measurements: under(), state: state(), profile: .standard, projectFPS: 24, shootingMode: .video)
        XCTAssertEqual(c.lines.map(\.text), ["FACE 1 STOP UNDER"])
        XCTAssertEqual(c.fix(for: "face-under"), Fix(label: "EI 800 → 1600", command: .setISO("1600")))
        XCTAssertTrue(c.visible)
    }
    func testPendingAFTracksAFocusFixAndClearsWhenTheFindingGoes() {
        let c = AssistController(useModel: false)
        var m = under(); m.faces[0].luma = 55; m.faces[0].sharpness = 10; m.sharpestRegion = CGPoint(x: 0.9, y: 0.9)
        for _ in 0 ..< 2 { c.ingest(measurements: m, state: state(), profile: .standard, projectFPS: 24, shootingMode: .video) }
        XCTAssertEqual(c.pendingAF, CGPoint(x: 0.5, y: 0.35))
        for _ in 0 ..< 2 { c.ingest(measurements: SceneMeasurements(), state: state(), profile: .standard, projectFPS: 24, shootingMode: .video) }
        XCTAssertNil(c.pendingAF)
        XCTAssertTrue(c.lines.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AssistControllerTests`
Expected: compile error, `cannot find 'AssistController' in scope`.

- [ ] **Step 3: Write the controller**

```swift
// Sources/CinemaUI/Assist/AssistController.swift
import Foundation
import CoreGraphics
import SonyCameraKit

/// Owns the assist pipeline for one monitor: debounces findings, asks the on-device model to phrase
/// them when it is available, exposes the lines and the pending focus point, and applies fixes.
@MainActor @Observable
public final class AssistController {
    public private(set) var lines: [AdviceLine] = []
    public private(set) var pendingAF: CGPoint?
    public private(set) var applied: String?          // finding id shown as APPLIED for a moment
    public let availability: ShotAdvisorAvailability
    private let useModel: Bool
    private var debouncer = AssistDebouncer()
    private var findings: [Finding] = []
    private var lastSignature = ""
    private var lastModelCall = Date.distantPast
    private var generation = 0
    private var lastNonEmpty = Date.distantPast
    public static let fadeAfter: TimeInterval = 6
    public static let modelInterval: TimeInterval = 1.5

    public init(useModel: Bool = true) {
        availability = ShotAdvisorAvailability.current
        self.useModel = useModel && availability == .available
        #if canImport(FoundationModels)
        if self.useModel, #available(macOS 26, iOS 26, *) { ShotAdvisor.prewarm() }
        #endif
    }

    /// True while there are lines, and for `fadeAfter` seconds after the last one cleared.
    public var visible: Bool { !lines.isEmpty || Date().timeIntervalSince(lastNonEmpty) < Self.fadeAfter }

    public func fix(for id: String) -> Fix? { findings.first { $0.id == id }?.fix }

    public func ingest(measurements m: SceneMeasurements, state: CameraState, profile: PictureProfile, projectFPS: Int, shootingMode: ShootingMode) {
        let raw = AssistRules.findings(m, state: state, profile: profile, projectFPS: projectFPS, shootingMode: shootingMode)
        findings = debouncer.update(with: raw)
        if case .touchAF(let x, let y)? = findings.first(where: { $0.id == "focus-missed" })?.fix?.command {
            pendingAF = CGPoint(x: x, y: y)
        } else { pendingAF = nil }
        let signature = findings.map { "\($0.id):\($0.fact)" }.joined(separator: "|")
        guard signature != lastSignature else { return }
        lastSignature = signature
        lines = AdviceLine.reconcile(model: nil, findings: findings)
        if !lines.isEmpty { lastNonEmpty = Date() }
        guard useModel, !findings.isEmpty, Date().timeIntervalSince(lastModelCall) >= Self.modelInterval else { return }
        lastModelCall = Date()
        generation += 1
        let gen = generation
        let prompt = AdvisorPrompt.build(findings: findings, measurements: m, state: state, profile: profile, projectFPS: projectFPS)
        let snapshot = findings
        Task { [weak self] in
            #if canImport(FoundationModels)
            guard #available(macOS 26, iOS 26, *) else { return }
            let result = await ShotAdvisor.advise(prompt: prompt)
            guard let self, self.generation == gen, let result else { return }
            self.lines = AdviceLine.reconcile(model: result, findings: snapshot)
            #endif
        }
    }

    /// Runs the finding's fix through the session and shows APPLIED briefly.
    public func apply(_ id: String, session: CameraSession) {
        guard let fix = fix(for: id) else { return }
        Task {
            switch fix.command {
            case .setISO(let v): await session.setISO(v)
            case .setExposureCompensation(let i): await session.setExposureCompensation(index: i)
            case .setShutterSpeed(let v): await session.setShutterSpeed(v)
            case .touchAF(let x, let y): await session.touchAF(x: x, y: y); pendingAF = nil
            case .autofocus: await session.autofocus()
            }
            applied = id
            try? await Task.sleep(for: .seconds(1.5))
            if applied == id { applied = nil }
        }
    }
}
```

- [ ] **Step 4: Run the controller tests**

Run: `swift test --filter AssistControllerTests`
Expected: 2 tests pass.

- [ ] **Step 5: Add the persisted `assist` flag to `OverlaySettings`**

In `Sources/CinemaUI/Settings.swift`, after `public var showSharpnessMeter = true`:

```swift
    /// Shot assist advisories over the picture (Mac video monitor). Remembered across launches.
    public var assist: Bool = UserDefaults.standard.object(forKey: "assist") as? Bool ?? true {
        didSet { UserDefaults.standard.set(assist, forKey: "assist") }
    }
```

- [ ] **Step 6: Write the strip view**

```swift
// Sources/CinemaUI/Assist/AssistStrip.swift
import SwiftUI
import SonyCameraKit

/// One or two advisory rows over the picture. A row with a fix is a button that applies it.
struct AssistStrip: View {
    @Environment(CameraSession.self) private var session
    let controller: AssistController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(controller.lines) { line in
                let fix = controller.fix(for: line.id)
                let severity = fix == nil ? Severity.info : Severity.warn
                Button { if fix != nil { controller.apply(line.id, session: session) } } label: {
                    HStack(spacing: 6) {
                        if line.fromModel {
                            Text("AI").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(Color.black)
                                .padding(.horizontal, 3).padding(.vertical, 1).background(Theme.dim, in: RoundedRectangle(cornerRadius: 2))
                        }
                        Text(line.text).font(Theme.label(10)).tracking(1.2).foregroundStyle(severity == .warn ? Theme.warn : Theme.dim)
                        if controller.applied == line.id {
                            Text("· APPLIED").font(Theme.label(10)).tracking(1.2).foregroundStyle(Theme.ok)
                        } else if let fix {
                            Text("· \(fix.label) ↵").font(Theme.label(10)).tracking(1.2).foregroundStyle(Theme.text)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(fix == nil)
            }
        }
        .animation(.easeOut(duration: 0.2), value: controller.lines)
    }
}
```

- [ ] **Step 7: Integrate into `MonitorView`**

In `Sources/CinemaUI/MonitorView.swift`:

1. Add state next to `afFlash`:
```swift
    @State private var analyzer = SceneAnalyzer()
    @State private var assist = AssistController()
```
2. In `body`, inside the `ZStack` after `picture`, before the tools `HStack`:
```swift
                if !overlays.hideHUD, overlays.assist, assist.visible {
                    VStack { HStack { AssistStrip(controller: assist).padding(.leading, 60).padding(.top, 8); Spacer() }; Spacer() }
                }
```
3. In `picture`, after `afMarker(in: rect, layout: layout)`:
```swift
                if overlays.assist, let p = assist.pendingAF {
                    let fx = (p.x - layout.cropX) / layout.cropWidth, fy = (p.y - layout.cropY) / layout.cropHeight
                    BracketFrame().stroke(Theme.warn, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: rect.width * 0.09, height: rect.width * 0.09)
                        .position(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
                        .clipShape(Rectangle().path(in: rect)).allowsHitTesting(false)
                }
```
4. At the end of `reprocess(_:)`, after the `processed = ...` assignment and before the scope block, feed the analyzer with the colour-interpreted source rotated the way the display is:
```swift
        if overlays.assist {
            let rotated = overlays.rotation == 0 ? source : source.oriented(overlays.rotation == 90 ? .right : (overlays.rotation == 270 ? .left : .down))
            let af = session.focusCheckPoint ?? session.state.touchAFPoint.map { CGPoint(x: $0.x / 100, y: $0.y / 100) }
            let (st, prof, fps, mode) = (session.state, overlays.profile, overlays.projectFPS, overlays.shootingMode)
            analyzer.analyze(rotated, afPoint: af) { m in assist.ingest(measurements: m, state: st, profile: prof, projectFPS: fps, shootingMode: mode) }
        }
```
`source` is the local already defined in `reprocess` (`frame.matchedToWorkingSpace(...) ?? frame`). Check `CIImage.oriented(_:)` matches the app's rotation convention by comparing with how `FrameProcessor.pipeline` rotates; if the pipeline uses a different orientation mapping, copy its mapping.

- [ ] **Step 8: ASSIST button and settings row in `HUDBars.swift`**

In `LeftTools.column`, after the CROP button:
```swift
            EdgeButton(title: "ASSIST", active: overlays.assist) { ov.assist.toggle() }
```
In `SettingsPanel`, inside `section("Monitor")` after the `row("Reel")`:
```swift
                        row("Shot assist") {
                            HStack(spacing: 8) {
                                Toggle("", isOn: $ov.assist).toggleStyle(.switch).controlSize(.small).labelsHidden()
                                Text(ShotAdvisorAvailability.current.reason ?? "Apple Intelligence phrases the advice")
                                    .font(.system(size: 10)).foregroundStyle(Theme.dim)
                            }
                        }
```

- [ ] **Step 9: Build, run all tests, check the Mac app**

Run: `swift build && swift test`
Expected: builds; all tests pass (45 previous + the new ones).

Run the app against the simulator: `python3 tools/camerasim.py --port 8080 --no-ssdp &` then `swift run CinemaHUD` with `CINEMAHUD_ADDRESS=127.0.0.1:8080`. Expected: with the simulator's clipping "sun", `HIGHLIGHTS CLIPPING` appears under the top strip within a second; toggling ASSIST hides it; the shutter set to 1/500 in the strip shows `SHUTTER 17° · 1/500 → 1/48 ↵`, and clicking it changes the shutter.

- [ ] **Step 10: Commit**

```bash
git add Sources/CinemaUI/Assist/AssistController.swift Sources/CinemaUI/Assist/AssistStrip.swift Sources/CinemaUI/Settings.swift Sources/CinemaUI/MonitorView.swift Sources/CinemaUI/HUDBars.swift Tests/SonyCameraKitTests/AssistControllerTests.swift
git commit -m "Shot assist in the Mac monitor: advisories over the picture with one-tap fixes, ASSIST button

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Simulator still-photo mode and README

**Files:**
- Modify: `tools/camerasim.py:104-124` (`render_frame`) and `:264-266` (arguments)
- Modify: `README.md` (feature list and the simulator section)

**Interfaces:**
- Produces: `--photo PATH` flag on `tools/camerasim.py`.

- [ ] **Step 1: Add the flag and the photo base**

In `tools/camerasim.py`, near the top after `FONT` is defined:
```python
PHOTO = None   # PIL image served as the live view when --photo is given
```
In `render_frame`, replace the gradient loop and the sun with a photo base when one is loaded:
```python
def render_frame(t, w=1024, h=680):
    gain = exposure_gain()
    if PHOTO is not None:
        from PIL import ImageEnhance
        img = ImageEnhance.Brightness(PHOTO.resize((w, h))).enhance(gain)
        d = ImageDraw.Draw(img)
    else:
        img = Image.new("RGB", (w, h))
        d = ImageDraw.Draw(img)
        warm = max(0, min(1, (CAM.color_temp - 2500) / 7400)) if CAM.wb_mode == "Color Temperature" else 0.45
        for y in range(0, h, 4):
            k = y / h
            r = int(min(255, (40 + 120 * k) * gain * (0.8 + 0.4 * warm)))
            g = int(min(255, (60 + 90 * k) * gain))
            b = int(min(255, (110 + 60 * (1 - k)) * gain * (1.2 - 0.4 * warm)))
            d.rectangle([0, y, w, y + 4], fill=(r, g, b))
        # a bright "sun" that clips (for zebras) and a moving subject (for peaking)
        sx, sy = w * 0.78, h * 0.22
        d.ellipse([sx - 70, sy - 70, sx + 70, sy + 70], fill=(int(min(255, 250 * gain)),) * 3)
        cx = w * 0.5 + math.sin(t * 0.8) * w * 0.25
        cy = h * 0.6 + math.cos(t * 0.5) * h * 0.1
        for i in range(6):
            c = int(min(255, (90 + 25 * i) * gain))
            d.rectangle([cx - 120 + i * 20, cy - 80 + i * 14, cx + 120 - i * 20, cy + 80 - i * 14], outline=(c, c, c), width=3)
    d.text((24, h - 44), f"SIM  {CAM.shutter}  F{CAM.fnumber}  ISO {CAM.iso}  {CAM.focus_mode}", fill=(255, 255, 255), font=FONT)
    buf = io.BytesIO(); img.save(buf, "JPEG", quality=80); return buf.getvalue()
```
In the argument parser:
```python
    ap.add_argument("--photo", help="serve this JPEG/PNG as the live view (exposure gain still applies); use a photo with a face to try Shot Assist")
```
and after `args = ap.parse_args()`:
```python
    if args.photo:
        PHOTO = Image.open(args.photo).convert("RGB")
```
(`global PHOTO` inside `main` if the assignment is in a function.)

- [ ] **Step 2: Verify**

Run: `python3 tools/camerasim.py --port 8080 --no-ssdp --photo docs/images/cinemahud-hero.jpg &` then `curl -s -o /tmp/f.jpg http://127.0.0.1:8080/postview/x && sips -g pixelWidth /tmp/f.jpg`
Expected: a 3000-px-wide JPEG of the photo. Then run the Mac app against it: with the hero image (a face on the phone screen at left), lower the ISO in the strip until `FACE … UNDER · EI … ↵` appears.

- [ ] **Step 3: README**

In `README.md`, add to the feature paragraph after the scopes/LUT sentences:
```markdown
**Shot assist** (Mac, video): the monitor measures faces, focus, clipping and horizon on the live
picture and shows one or two advisories under the exposure strip — "FACE 1 STOP UNDER · EI 800 → 1600",
"FOCUS OFF SUBJECT · AF ON FACE", "SHUTTER 17° · 1/500 → 1/48" — each applied with one click. On
macOS 26 with Apple Intelligence, the on-device model phrases them (marked AI); elsewhere the plain
facts show. Nothing leaves the Mac. ASSIST in the left column turns it off.
```
In the simulator section, add `--photo photo.jpg` to the flag list with "serve a still photo as the live view (try one with a face)".

- [ ] **Step 4: Commit**

```bash
git add tools/camerasim.py README.md
git commit -m "Simulator: --photo serves a still as the live view; README: Shot assist

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage:** analyzer (Task 4), rules with every row of the spec table (Task 2), debounce (Task 3), advisor with instructions/prompt/structured output/cadence/timeout (Tasks 5, 6), strip with fix buttons, AI tag, APPLIED, fade, pending-AF bracket, ASSIST button, hideHUD, settings reason line (Task 6), availability states and macOS 14 floor (Task 5), simulator `--photo` and manual checks (Task 7). Photo mode and iOS are non-goals and untouched.
- **Placeholders:** none; every step has its code.
- **Type consistency:** `SceneMeasurements.sharpestScore` (not `sharpestRatio` as in the spec's sketch) is used in Tasks 2, 4, 6 consistently; `Fix.Command` cases match between rules, controller and tests; `ShotAdvisorAvailability.current` is what Task 5's test, Task 6's controller and the settings row call.
