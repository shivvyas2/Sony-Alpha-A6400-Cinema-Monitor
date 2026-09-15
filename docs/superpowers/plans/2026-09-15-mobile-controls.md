# Mobile Controls & Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the iPhone/iPad app into a touch-first field monitor: photo/video switch, guide options, power-zoom and manual-focus controls with focus assist, recording-format controls, a Settings screen with Privacy Policy and Terms of Use, in both orientations, with nothing overflowing the screen. The Mac app does not change.

**Architecture:** The camera library gains the Wi-Fi calls and state for still size, movie quality/format and zoom, relayed through the bridge. `CinemaUI` gains iOS-only `Mobile*` views built on the existing picture pipeline (`MetalFrameView`, `FrameProcessor`, `LiveSharpnessMeter`, `ReviewView`) with their own touch chrome and bottom sheets. The iOS app routes to them.

**Tech Stack:** Swift 5.9, SwiftPM (`SonyCameraKit`, `CinemaUI`), SwiftUI + Metal/Core Image, iOS 17, XcodeGen project at `iOS/project.yml`, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-15-mobile-controls-design.md`

## Global Constraints

- Platforms: `.macOS(.v14), .iOS(.v17)`. Mobile views compile under `#if !os(macOS)`; the Mac's `MonitorView`, `HUDBars`, `PhotoHUD`, keyboard menus stay behaviourally identical.
- Every control is gated by what the camera advertises (`state.supports(...)`, `focusDriveAvailable`); unsupported rows show "Set on camera" or an explanation, never an alert.
- All touch targets ≥ 44 pt; layouts respect safe areas; no fixed width wider than the screen.
- `ScrollStepper` on iOS is a vertical drag (`ScrollWheelCatcher.swift` `#else` branch). `MetalFrameView` / `FrameProcessor` take a raw-value `CIImage` flipped once in the renderer: never add a flip.
- Commit messages: plain, no `Co-Authored-By` trailer.
- Tests: `swift test 2>&1 | grep -E "Executed|error:|failed"` from the worktree root `/Users/shivvyas/Cinema/.claude/worktrees/photo-mode` (branch `ios-controls`). iOS builds: `xcodebuild -project iOS/CinemaHUDMobile.xcodeproj -scheme CinemaHUDMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build`.
- Another session works in the main checkout; never touch it. Simulator port 8080 may be taken by that session: use `--port 8090`.

---

### Task 1: Library — still size, movie quality/format, zoom over Wi-Fi

**Files:**
- Modify: `Sources/SonyCameraKit/CameraState.swift` (fields, `==`, `applyItem`)
- Modify: `Sources/SonyCameraKit/SonyCameraClient.swift` (after `actZoom`)
- Modify: `Sources/SonyCameraKit/CameraBackend.swift` (new types + protocol defaults)
- Modify: `Sources/SonyCameraKit/WiFiBackend.swift` (`connect`, new methods)
- Modify: `Sources/SonyCameraKit/USB/SonyUSBBackend.swift` (`makeState`, `setStillSize`)
- Modify: `Sources/SonyCameraKit/CameraSession.swift` (wrappers, availability flags)
- Test: `Tests/SonyCameraKitTests/CameraStateTests.swift` (new test), `Tests/SonyCameraKitTests/FormatTests.swift`

**Interfaces:**
- Produces: `StillSize { aspect, size; label }`, `ZoomDirection { in, out }`, `ZoomMovement { start, stop, oneShot }`, `CameraState.stillSize/stillSizeCandidates/movieQuality/movieQualityCandidates/movieFileFormat/movieFileFormatCandidates`, backend methods `zoom(_:_:)`, `setStillSize(_:)`, `setMovieQuality(_:)`, `setMovieFileFormat(_:)`, session `zoom(_:_:)`, `setStillSize(_:)`, `setMovieQuality(_:)`, `setMovieFileFormat(_:)`, `zoomAvailable`, `stillSizeAvailable`, `movieQualityAvailable`, `movieFileFormatAvailable`, `StillSize.usbSizeName/usbAspectName` mapping.

- [ ] **Step 1: Write the failing tests**

Append to `CameraStateTests`:

```swift
    func testDecodesFormatAndZoomEvents() throws {
        let json = """
        [
          {"type":"stillSize","currentAspect":"3:2","currentSize":"L"},
          {"type":"movieQuality","currentMovieQuality":"PS","movieQualityCandidates":["PS","HQ","STD"]},
          {"type":"movieFileFormat","currentMovieFileFormat":"XAVC S","movieFileFormatCandidates":["MP4","XAVC S"]},
          {"type":"zoomInformation","zoomPosition":42,"zoomNumberBox":1,"zoomIndexCurrentBox":0,"zoomPositionCurrentBox":42}
        ]
        """
        var s = CameraState()
        s.apply(event: try JSON.parse(Data(json.utf8)))
        XCTAssertEqual(s.stillSize, StillSize(aspect: "3:2", size: "L"))
        XCTAssertEqual(s.movieQuality, "PS"); XCTAssertEqual(s.movieQualityCandidates, ["PS", "HQ", "STD"])
        XCTAssertEqual(s.movieFileFormat, "XAVC S"); XCTAssertEqual(s.movieFileFormatCandidates, ["MP4", "XAVC S"])
        XCTAssertEqual(s.zoomPosition, 42)
    }
```

New file `Tests/SonyCameraKitTests/FormatTests.swift`:

```swift
import XCTest
@testable import SonyCameraKit

final class FormatTests: XCTestCase {
    func testStillSizeLabelsAndUSBNames() {
        let s = StillSize(aspect: "16:9", size: "M")
        XCTAssertEqual(s.label, "16:9  M")
        XCTAssertEqual(s.usbSizeName, "Medium")
        XCTAssertEqual(StillSize(usbAspect: "16:9", usbSize: "Large"), StillSize(aspect: "16:9", size: "L"))
        XCTAssertNil(StillSize(usbAspect: "16:9", usbSize: "Huge"))
    }

    func testStillSizeParsesSupportedList() throws {
        let json = try JSON.parse(Data(#"[[{"aspect":"3:2","size":"L"},{"aspect":"16:9","size":"S"}]]"#.utf8))
        XCTAssertEqual(StillSize.list(from: json[0]), [StillSize(aspect: "3:2", size: "L"), StillSize(aspect: "16:9", size: "S")])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "CameraStateTests|FormatTests" 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'StillSize' in scope`, `value of type 'CameraState' has no member 'stillSize'`.

- [ ] **Step 3: Types and protocol defaults**

In `Sources/SonyCameraKit/CameraBackend.swift` add after `public enum CameraTransportKind`:

```swift
/// Still image size as the camera names it: aspect "3:2" / "16:9" / "4:3" / "1:1", size "L" / "M" / "S".
public struct StillSize: Sendable, Equatable, Hashable, Identifiable {
    public var aspect: String
    public var size: String
    public var id: String { aspect + "|" + size }
    public var label: String { aspect + "  " + size }
    public init(aspect: String, size: String) { self.aspect = aspect; self.size = size }

    /// The USB protocol names sizes Large / Medium / Small; the Wi-Fi API uses L / M / S.
    public var usbSizeName: String { ["L": "Large", "M": "Medium", "S": "Small"][size] ?? size }
    public init?(usbAspect: String, usbSize: String) {
        guard let s = ["Large": "L", "Medium": "M", "Small": "S"][usbSize] else { return nil }
        self.init(aspect: usbAspect, size: s)
    }
    /// Parses one `getSupportedStillSize` / `getAvailableStillSize` list: `[{"aspect":"3:2","size":"L"}, …]`.
    public static func list(from json: JSON) -> [StillSize] {
        (json.array ?? []).compactMap { e in
            guard let a = e["aspect"].string, let s = e["size"].string else { return nil }
            return StillSize(aspect: a, size: s)
        }
    }
}

public enum ZoomDirection: String, Sendable { case `in` = "in", out = "out" }
public enum ZoomMovement: String, Sendable { case start = "start", stop = "stop", oneShot = "1shot" }
```

And after the protocol's closing brace add:

```swift
public extension CameraBackend {
    /// Power-zoom lenses over Wi-Fi only (`actZoom`); no zoom drive exists in the α6400's USB protocol.
    func zoom(_ direction: ZoomDirection, _ movement: ZoomMovement) async throws { throw UnsupportedOperation("Zoom") }
    func setStillSize(_ s: StillSize) async throws { throw UnsupportedOperation("Still size") }
    func setMovieQuality(_ v: String) async throws { throw UnsupportedOperation("Movie quality") }
    func setMovieFileFormat(_ v: String) async throws { throw UnsupportedOperation("Movie file format") }
}
```

- [ ] **Step 4: State fields and decoding**

In `CameraState.swift` add after `public var zoomPosition: Int?`:

```swift
    public var stillSize: StillSize?
    public var stillSizeCandidates: [StillSize] = []
    public var movieQuality: String?
    public var movieQualityCandidates: [String] = []
    public var movieFileFormat: String?
    public var movieFileFormatCandidates: [String] = []
```

Extend the hand-written `==` by appending before the final closing paren of the expression:

```swift
        && a.stillSize == b.stillSize && a.stillSizeCandidates == b.stillSizeCandidates
        && a.movieQuality == b.movieQuality && a.movieQualityCandidates == b.movieQualityCandidates
        && a.movieFileFormat == b.movieFileFormat && a.movieFileFormatCandidates == b.movieFileFormatCandidates
```

In `applyItem`, add cases before `default:`:

```swift
        case "stillSize":
            if let a = item["currentAspect"].string, let s = item["currentSize"].string { stillSize = StillSize(aspect: a, size: s) }
        case "movieQuality":
            movieQuality = item["currentMovieQuality"].string ?? movieQuality
            let c = item["movieQualityCandidates"].stringArray; if !c.isEmpty { movieQualityCandidates = c }
        case "movieFileFormat":
            movieFileFormat = item["currentMovieFileFormat"].string ?? movieFileFormat
            let c = item["movieFileFormatCandidates"].stringArray; if !c.isEmpty { movieFileFormatCandidates = c }
```

(`zoomInformation` is already decoded.)

- [ ] **Step 5: Wi-Fi client and backend**

In `SonyCameraClient.swift` after `actZoom`:

```swift
    public func setStillSize(aspect: String, size: String) async throws { try await call("setStillSize", [.string(aspect), .string(size)]) }
    public func getSupportedStillSize() async throws -> [StillSize] { StillSize.list(from: try await call("getSupportedStillSize")[0]) }
    public func setMovieQuality(_ v: String) async throws { try await call("setMovieQuality", [.string(v)]) }
    public func getSupportedMovieQuality() async throws -> [String] { try await call("getSupportedMovieQuality")[0].stringArray }
    public func setMovieFileFormat(_ v: String) async throws { try await call("setMovieFileFormat", [.string(v)]) }
    public func getSupportedMovieFileFormat() async throws -> [String] { try await call("getSupportedMovieFileFormat")[0].stringArray }
```

In `WiFiBackend.connect()`, after `s.apply(event: …)` and before `stateBox.set(s)`:

```swift
        // Candidate lists that only come from the getSupported* calls.
        if apis.contains("getSupportedStillSize"), let list = try? await client.getSupportedStillSize() { s.stillSizeCandidates = list }
        if apis.contains("getSupportedMovieQuality"), let list = try? await client.getSupportedMovieQuality(), s.movieQualityCandidates.isEmpty { s.movieQualityCandidates = list }
        if apis.contains("getSupportedMovieFileFormat"), let list = try? await client.getSupportedMovieFileFormat(), s.movieFileFormatCandidates.isEmpty { s.movieFileFormatCandidates = list }
```

Note: `stateUpdates()` merges events into the box, so those candidate lists persist. Add methods after `cancelTouchAF`:

```swift
    public func zoom(_ direction: ZoomDirection, _ movement: ZoomMovement) async throws { try await client.actZoom(direction: direction.rawValue, movement: movement.rawValue) }
    public func setStillSize(_ s: StillSize) async throws { try await client.setStillSize(aspect: s.aspect, size: s.size) }
    public func setMovieQuality(_ v: String) async throws { try await client.setMovieQuality(v) }
    public func setMovieFileFormat(_ v: String) async throws { try await client.setMovieFileFormat(v) }
```

- [ ] **Step 6: USB maps still size to its two properties**

In `SonyUSBBackend.makeState`, after the `focusFound` block:

```swift
        if let sz = p[SonyProp.imageSize], let asp = p[SonyProp.aspectRatio] {
            let sizeName = SonyValue.name(sz.current, in: SonyValue.imageSize), aspectName = SonyValue.name(asp.current, in: SonyValue.aspect)
            s.stillSize = StillSize(usbAspect: aspectName, usbSize: sizeName)
            let sizes = candidates(sz).map { SonyValue.name($0, in: SonyValue.imageSize) }
            let aspects = candidates(asp).map { SonyValue.name($0, in: SonyValue.aspect) }
            s.stillSizeCandidates = aspects.flatMap { a in sizes.compactMap { StillSize(usbAspect: a, usbSize: $0) } }
            if sz.settable || asp.settable { apis.insert("setStillSize") }
        }
```

Check the helper name with `grep -n "static func name" Sources/SonyCameraKit/USB/SonyTables.swift` (it is `SonyValue.name(_:in:)` per the table file; if the enum is named differently there, use that name). Add to the backend:

```swift
    public func setStillSize(_ s: StillSize) async throws {
        try await setSetting(id: String(format: "0x%04X", SonyProp.aspectRatio), value: s.aspect)
        try await setSetting(id: String(format: "0x%04X", SonyProp.imageSize), value: s.usbSizeName)
    }
```

- [ ] **Step 7: Session wrappers**

In `CameraSession.swift` after `press(_:)`:

```swift
    public func zoom(_ direction: ZoomDirection, _ movement: ZoomMovement) async { await perform("Zoom") { try await $0.zoom(direction, movement) } }
    public func setStillSize(_ s: StillSize) async { await perform("Still size") { try await $0.setStillSize(s) } }
    public func setMovieQuality(_ v: String) async { await perform("Movie quality") { try await $0.setMovieQuality(v) } }
    public func setMovieFileFormat(_ v: String) async { await perform("Movie format") { try await $0.setMovieFileFormat(v) } }

    public var zoomAvailable: Bool { state.supports("actZoom") }
    public var stillSizeAvailable: Bool { state.supports("setStillSize") && !state.stillSizeCandidates.isEmpty }
    public var movieQualityAvailable: Bool { state.supports("setMovieQuality") && !state.movieQualityCandidates.isEmpty }
    public var movieFileFormatAvailable: Bool { state.supports("setMovieFileFormat") && !state.movieFileFormatCandidates.isEmpty }
```

- [ ] **Step 8: Build, test, commit**

Run: `swift build 2>&1 | grep -E "error" ; swift test 2>&1 | grep -E "Executed|error:|failed" | tail -1`
Expected: no errors; `Executed 40 tests, with 0 failures` (37 + 3).

```bash
git add Sources/SonyCameraKit Tests/SonyCameraKitTests/CameraStateTests.swift Tests/SonyCameraKitTests/FormatTests.swift
git commit -m "Kit: still size, movie quality/format and zoom over Wi-Fi; USB maps still size to its properties"
```

---

### Task 2: Bridge relays the new controls and state

**Files:**
- Modify: `Sources/SonyCameraKit/Bridge/BridgeProtocol.swift` (`BridgeState` fields, init, `cameraState`)
- Modify: `Sources/SonyCameraKit/Bridge/BridgeBackend.swift` (four methods)
- Modify: `Sources/SonyCameraKit/CameraSession.swift` (`handleBridge` cases)
- Test: `Tests/SonyCameraKitTests/BridgeTests.swift`

**Interfaces:**
- Consumes: Task 1 types and session methods.
- Produces: bridge ops `"zoom"` (value = direction, value2 = movement), `"setStillSize"` (value = aspect, value2 = size), `"setMovieQuality"`, `"setMovieFileFormat"` (value).

- [ ] **Step 1: Write the failing test** (append to `BridgeTests`)

```swift
    func testBridgeStateCarriesFormatAndZoom() throws {
        var st = CameraState()
        st.stillSize = StillSize(aspect: "3:2", size: "L")
        st.stillSizeCandidates = [StillSize(aspect: "3:2", size: "L"), StillSize(aspect: "16:9", size: "M")]
        st.movieQuality = "PS"; st.movieQualityCandidates = ["PS", "HQ"]
        st.movieFileFormat = "XAVC S"; st.movieFileFormatCandidates = ["MP4", "XAVC S"]
        st.zoomPosition = 42
        let b = BridgeState(state: st, settings: [], transport: .usb, cameraName: "a6400")
        let data = try JSONEncoder().encode(b)
        let back = try JSONDecoder().decode(BridgeState.self, from: data).cameraState
        XCTAssertEqual(back.stillSize, st.stillSize)
        XCTAssertEqual(back.stillSizeCandidates, st.stillSizeCandidates)
        XCTAssertEqual(back.movieQuality, "PS"); XCTAssertEqual(back.movieQualityCandidates, ["PS", "HQ"])
        XCTAssertEqual(back.movieFileFormat, "XAVC S"); XCTAssertEqual(back.movieFileFormatCandidates, ["MP4", "XAVC S"])
        XCTAssertEqual(back.zoomPosition, 42)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter BridgeTests 2>&1 | grep -E "error:|failed" | head -3`
Expected: assertion failures (fields not carried) or compile errors if the properties are missing.

- [ ] **Step 3: Carry the fields**

In `BridgeState` add after `public var focusDriveAvailable: Bool`:

```swift
    public var stillAspect: String?, stillSizeName: String?
    public var stillSizeCandidates: [String] = []        // "aspect|size"
    public var movieQuality: String?
    public var movieQualityCandidates: [String] = []
    public var movieFileFormat: String?
    public var movieFileFormatCandidates: [String] = []
    public var zoomPosition: Int?
```

In `init(state:settings:transport:cameraName:)` after `focusDriveAvailable = transport == .usb`:

```swift
        stillAspect = s.stillSize?.aspect; stillSizeName = s.stillSize?.size
        stillSizeCandidates = s.stillSizeCandidates.map(\.id)
        movieQuality = s.movieQuality; movieQualityCandidates = s.movieQualityCandidates
        movieFileFormat = s.movieFileFormat; movieFileFormatCandidates = s.movieFileFormatCandidates
        zoomPosition = s.zoomPosition
```

In `cameraState` before `return s`:

```swift
        if let a = stillAspect, let z = stillSizeName { s.stillSize = StillSize(aspect: a, size: z) }
        s.stillSizeCandidates = stillSizeCandidates.compactMap { id in
            let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 ? StillSize(aspect: parts[0], size: parts[1]) : nil
        }
        s.movieQuality = movieQuality; s.movieQualityCandidates = movieQualityCandidates
        s.movieFileFormat = movieFileFormat; s.movieFileFormatCandidates = movieFileFormatCandidates
        s.zoomPosition = zoomPosition
```

Because these are `var` with defaults (or optionals), old clients decoding a new state and vice versa still work; give the arrays defaults via `decodeIfPresent` by adding to `BridgeState`:

```swift
    private enum CodingKeys: String, CodingKey {
        case transport, cameraName, availableAPIs, cameraStatus, liveviewStatus, shootMode, shootModeCandidates, exposureMode, exposureModeCandidates,
             shutterSpeed, shutterSpeedCandidates, fNumber, fNumberCandidates, iso, isoCandidates, whiteBalanceMode, colorTemperature, whiteBalanceCandidates,
             evIndex, evMin, evMax, evStep, focusMode, focusModeCandidates, focusStatus, touchAFSet, touchAFX, touchAFY, batteryStatus, batteryNumer, batteryDenom,
             storage, recordingTimeSeconds, numberOfShots, focalLengthMM, ccShift, abShift, settings, focusDriveAvailable,
             stillAspect, stillSizeName, stillSizeCandidates, movieQuality, movieQualityCandidates, movieFileFormat, movieFileFormatCandidates, zoomPosition
    }
```

(Explicit keys keep the wire names stable; Swift synthesises `init(from:)` for `var`s with default values using `decodeIfPresent` semantics only for optionals, so run the test: if decoding an old payload matters later, the arrays default to `[]` through the memberwise defaults on decode failure being absent — verify with the round trip test, which is what we ship.)

- [ ] **Step 4: Relay**

In `CameraSession.handleBridge` add cases before `default:`:

```swift
        case "zoom": if let d = cmd.value.flatMap(ZoomDirection.init(rawValue:)), let m = cmd.value2.flatMap(ZoomMovement.init(rawValue:)) { await zoom(d, m) }
        case "setStillSize": if let a = cmd.value, let z = cmd.value2 { await setStillSize(StillSize(aspect: a, size: z)) }
        case "setMovieQuality": if let v = cmd.value { await setMovieQuality(v) }
        case "setMovieFileFormat": if let v = cmd.value { await setMovieFileFormat(v) }
```

In `BridgeBackend` after `press(_:)`:

```swift
    public func zoom(_ direction: ZoomDirection, _ movement: ZoomMovement) async throws { try await send(.init(op: "zoom", value: direction.rawValue, value2: movement.rawValue)) }
    public func setStillSize(_ s: StillSize) async throws { try await send(.init(op: "setStillSize", value: s.aspect, value2: s.size)) }
    public func setMovieQuality(_ v: String) async throws { try await send(.init(op: "setMovieQuality", value: v)) }
    public func setMovieFileFormat(_ v: String) async throws { try await send(.init(op: "setMovieFileFormat", value: v)) }
```

- [ ] **Step 5: Test and commit**

Run: `swift test 2>&1 | grep -E "Executed|error:|failed" | tail -1` → `Executed 41 tests, with 0 failures`.

```bash
git add Sources/SonyCameraKit/Bridge Sources/SonyCameraKit/CameraSession.swift Tests/SonyCameraKitTests/BridgeTests.swift
git commit -m "Bridge: relay zoom, still size, movie quality and file format; carry them in BridgeState"
```

---

### Task 3: Guides, peaking colour and overlay settings (shared)

**Files:**
- Create: `Sources/CinemaUI/Guides.swift`
- Modify: `Sources/CinemaUI/Settings.swift` (`OverlaySettings`)
- Modify: `Sources/CinemaUI/MonitorView.swift` (`FrameOverlays`)
- Modify: `Sources/CinemaUI/FrameProcessor.swift` (`pipeline`, `applyPeaking`)
- Modify: `Sources/CinemaUI/PhotoView.swift`, `Sources/CinemaUI/MonitorView.swift` (pass `peakingColor`)
- Modify: `Package.swift` (test target depends on `CinemaUI`)
- Test: `Tests/SonyCameraKitTests/GuidesTests.swift`

**Interfaces:**
- Produces: `FrameGuideRatio` (`.r185, .r200, .r235, .r239, .r43, .r11, .r916`; `value: CGFloat`, `label`), `PeakingColor` (`.red, .yellow, .white, .blue`; `rgb`, `color`), `OverlaySettings.guideRatio`, `.safeAreas`, `.diagonals`, `.peakingColor`, `.showSharpnessMeter`, `FrameProcessor.pipeline(..., peakingColor:)`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SonyCameraKitTests/GuidesTests.swift
import XCTest
@testable import CinemaUI

final class GuidesTests: XCTestCase {
    func testRatiosAndLabels() {
        XCTAssertEqual(FrameGuideRatio.r239.value, 2.39, accuracy: 0.001)
        XCTAssertEqual(FrameGuideRatio.r916.value, 9.0 / 16.0, accuracy: 0.001)
        XCTAssertEqual(FrameGuideRatio.r43.label, "4:3")
        XCTAssertEqual(FrameGuideRatio.allCases.count, 7)
    }
    func testPeakingColours() {
        XCTAssertEqual(PeakingColor.red.rgb.0, 1, accuracy: 0.001)
        XCTAssertEqual(PeakingColor.blue.rgb.2, 1, accuracy: 0.001)
        XCTAssertEqual(PeakingColor.allCases.map(\.rawValue), ["Red", "Yellow", "White", "Blue"])
    }
}
```

In `Package.swift` change the test target to `.testTarget(name: "SonyCameraKitTests", dependencies: ["SonyCameraKit", "CinemaUI"])`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GuidesTests 2>&1 | grep -E "error:" | head -3` → `cannot find 'FrameGuideRatio' in scope`.

- [ ] **Step 3: Guides types**

```swift
// Sources/CinemaUI/Guides.swift
import SwiftUI

/// Frame-line ratios for the guides overlay. Wider than 3:2 draws top/bottom lines; narrower draws side lines.
public enum FrameGuideRatio: String, CaseIterable, Identifiable, Sendable {
    case r185 = "1.85", r200 = "2.00", r235 = "2.35", r239 = "2.39", r43 = "4:3", r11 = "1:1", r916 = "9:16"
    public var id: String { rawValue }
    public var label: String { rawValue }
    public var value: CGFloat {
        switch self {
        case .r185: return 1.85
        case .r200: return 2.0
        case .r235: return 2.35
        case .r239: return 2.39
        case .r43: return 4.0 / 3.0
        case .r11: return 1
        case .r916: return 9.0 / 16.0
        }
    }
}

/// Focus peaking tint.
public enum PeakingColor: String, CaseIterable, Identifiable, Sendable {
    case red = "Red", yellow = "Yellow", white = "White", blue = "Blue"
    public var id: String { rawValue }
    public var rgb: (Double, Double, Double) {
        switch self {
        case .red: return (1, 0.15, 0.1)
        case .yellow: return (1, 0.9, 0.1)
        case .white: return (1, 1, 1)
        case .blue: return (0.2, 0.5, 1)
        }
    }
    public var color: Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2) }
}
```

In `OverlaySettings` add after `public var reviewShowsRAW = false`:

```swift
    /// Guides (mobile guides sheet; the Mac keeps its own defaults).
    public var guideRatio: FrameGuideRatio = .r239
    public var safeAreas = false
    public var diagonals = false
    public var peakingColor: PeakingColor = .red
    public var showSharpnessMeter = true
```

- [ ] **Step 4: Overlay drawing**

In `FrameOverlays.body` (MonitorView.swift), replace the `if overlays.frameGuides { … }` block with:

```swift
            if overlays.frameGuides {
                let target = overlays.guideRatio.value, native = rect.width / rect.height
                var p = Path()
                if target >= native {
                    let h = rect.width / target
                    let top = rect.midY - h / 2, bottom = rect.midY + h / 2
                    p.move(to: CGPoint(x: rect.minX, y: top)); p.addLine(to: CGPoint(x: rect.maxX, y: top))
                    p.move(to: CGPoint(x: rect.minX, y: bottom)); p.addLine(to: CGPoint(x: rect.maxX, y: bottom))
                    ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, top - rect.minY))), with: .color(.black.opacity(0.5)))
                    ctx.fill(Path(CGRect(x: rect.minX, y: bottom, width: rect.width, height: max(0, rect.maxY - bottom))), with: .color(.black.opacity(0.5)))
                } else {
                    let w = rect.height * target
                    let left = rect.midX - w / 2, right = rect.midX + w / 2
                    p.move(to: CGPoint(x: left, y: rect.minY)); p.addLine(to: CGPoint(x: left, y: rect.maxY))
                    p.move(to: CGPoint(x: right, y: rect.minY)); p.addLine(to: CGPoint(x: right, y: rect.maxY))
                    ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: max(0, left - rect.minX), height: rect.height)), with: .color(.black.opacity(0.5)))
                    ctx.fill(Path(CGRect(x: right, y: rect.minY, width: max(0, rect.maxX - right), height: rect.height)), with: .color(.black.opacity(0.5)))
                }
                ctx.stroke(p, with: .color(.white.opacity(0.7)), style: thin)
            }
            if overlays.safeAreas {
                ctx.stroke(Path(rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.05)), with: .color(.white.opacity(0.5)), style: thin)
                ctx.stroke(Path(rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.10)), with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            if overlays.diagonals {
                var d = Path()
                d.move(to: CGPoint(x: rect.minX, y: rect.minY)); d.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                d.move(to: CGPoint(x: rect.maxX, y: rect.minY)); d.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                ctx.stroke(d, with: .color(.white.opacity(0.25)), style: thin)
            }
```

The Mac default `guideRatio` is `.r239`, so its GUIDE button draws exactly what it drew before.

- [ ] **Step 5: Peaking colour**

In `FrameProcessor.pipeline` add a parameter `peakingColor: (Double, Double, Double) = (1, 0.15, 0.1)` after `falseColor`, pass it to `applyPeaking(to:source:color:)`, and change `applyPeaking` to build the matrix from it:

```swift
    private func applyPeaking(to base: CIImage, source: CIImage, color: (Double, Double, Double)) -> CIImage {
        guard let edges = CIFilter(name: "CIEdges"), let over = CIFilter(name: "CISourceOverCompositing") else { return base }
        edges.setValue(source, forKey: kCIInputImageKey)
        edges.setValue(4.0, forKey: kCIInputIntensityKey)
        guard let e = edges.outputImage, let mask = luminanceMask(e, threshold: 0.35) else { return base }
        let tinted = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: color.0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: color.1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: color.2, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        ])
        over.setValue(tinted, forKey: kCIInputImageKey)
        over.setValue(base, forKey: kCIInputBackgroundImageKey)
        return over.outputImage ?? base
    }
```

Then in `MonitorView.reprocess` and `PhotoView.reprocess` pass `peakingColor: overlays.peakingColor.rgb` to `pipeline(...)` and add `.onChange(of: overlays.peakingColor) { _, _ in reprocess(session.frame) }` next to the peaking `onChange` in both views.

- [ ] **Step 6: Build, test, commit**

Run: `swift build 2>&1 | grep -E "error" ; swift test 2>&1 | grep -E "Executed|error:|failed" | tail -1` → `Executed 43 tests, with 0 failures`.

```bash
git add Package.swift Sources/CinemaUI/Guides.swift Sources/CinemaUI/Settings.swift Sources/CinemaUI/MonitorView.swift Sources/CinemaUI/FrameProcessor.swift Sources/CinemaUI/PhotoView.swift Tests/SonyCameraKitTests/GuidesTests.swift
git commit -m "Guides: frame-line ratios, safe areas, diagonals; peaking colour"
```

---

### Task 4: Mobile chrome — tool buttons, readouts, mode switch, bands

**Files:**
- Create: `Sources/CinemaUI/Mobile/MobileChrome.swift`

**Interfaces:**
- Consumes: `Theme`, `ScrollStepper`, `CameraSession`, `OverlaySettings`, `ShootingMode`.
- Produces (iOS only): `MobileToolButton(icon:label:active:enabled:action:)`, `MobileReadout(label:value:enabled:onStep:onTap:)`, `ModeSwitch(mode:onChange:)`, `MobileCandidateSheet(title:current:candidates:format:onPick:)`, `RecordButton(recording:enabled:action:)`, `ShutterButton(enabled:busy:action:)`, `ZoomRocker(position:enabled:onZoom:)`, `FocusDot(status:)`, `SharpnessBar(ratio:)`, `MobileFilmstrip()`, `MobileMetrics` (`isPad`, `railWidth`, `target`).

- [ ] **Step 1: Write the components**

```swift
// Sources/CinemaUI/Mobile/MobileChrome.swift
#if !os(macOS)
import SwiftUI
import SonyCameraKit

enum MobileMetrics {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static var target: CGFloat { isPad ? 52 : 44 }
    static var railWidth: CGFloat { isPad ? 72 : 60 }
}

/// Rail / deck button: SF Symbol over a tiny tracked label. Orange when active, like the Mac's edge buttons.
struct MobileToolButton: View {
    let icon: String
    let label: String
    var active = false
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: MobileMetrics.isPad ? 20 : 17, weight: .semibold))
                Text(label).font(.system(size: 8.5, weight: .bold)).tracking(0.6).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(active ? Color.black : Theme.text)
            .frame(width: MobileMetrics.target + 4, height: MobileMetrics.target)
            .background(active ? Theme.accent : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// Exposure readout: tap opens a candidate sheet, vertical drag steps like a dial.
struct MobileReadout: View {
    let label: String
    let value: String
    var enabled = true
    var accent: Color = Theme.text
    var onStep: (Int) -> Void = { _ in }
    var onTap: () -> Void = {}
    var body: some View {
        ScrollStepper(onStep: { if enabled { onStep($0) } }) {
            Button(action: { if enabled { onTap() } }) {
                VStack(spacing: 2) {
                    Text(label).font(Theme.label(9)).tracking(1.2).foregroundStyle(Theme.dim)
                    Text(value).font(Theme.strip(MobileMetrics.isPad ? 20 : 17)).foregroundStyle(enabled ? accent : Theme.faint).lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(minWidth: 64, minHeight: MobileMetrics.target)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// VIDEO | PHOTO, in the monitor's monochrome idiom.
struct ModeSwitch: View {
    let mode: ShootingMode
    let onChange: (ShootingMode) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(ShootingMode.allCases, id: \.self) { m in
                Button { onChange(m) } label: {
                    Text(m.rawValue).font(.system(size: 11, weight: .bold)).tracking(1.2)
                        .foregroundStyle(m == mode ? Color.black : Theme.text)
                        .frame(width: 66, height: 30)
                        .background(m == mode ? Theme.text : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
    }
}

/// Candidate list for a readout, presented as a bottom sheet.
struct MobileCandidateSheet: View {
    let title: String
    let current: String
    let candidates: [String]
    var format: (String) -> String = { $0 }
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(candidates, id: \.self) { c in
                Button { onPick(c); dismiss() } label: {
                    HStack {
                        Text(format(c)).font(Theme.mono(16, weight: c == current ? .semibold : .regular)).foregroundStyle(Theme.text)
                        Spacer()
                        if c == current { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                    .frame(minHeight: 44)
                }
                .listRowBackground(Theme.panel)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.field)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct RecordButton: View {
    let recording: Bool
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 3).frame(width: 60, height: 60)
                RoundedRectangle(cornerRadius: recording ? 5 : 24).fill(Theme.rec).frame(width: recording ? 26 : 48, height: recording ? 26 : 48)
                    .animation(.easeInOut(duration: 0.15), value: recording)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(recording ? "Stop recording" : "Start recording")
    }
}

struct ShutterButton: View {
    var enabled = true
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 3).frame(width: 60, height: 60)
                Circle().fill(Color.white.opacity(busy ? 0.4 : 0.92)).frame(width: 48, height: 48)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .accessibilityLabel("Take picture")
    }
}

/// W ◀ ▶ T rocker: hold to zoom continuously, tap for one step; position bar between.
struct ZoomRocker: View {
    let position: Int?
    var enabled = true
    let onZoom: (ZoomDirection, ZoomMovement) -> Void
    @State private var held: ZoomDirection?
    var body: some View {
        HStack(spacing: 10) {
            key("W", .out)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2)).frame(height: 6)
                Capsule().fill(Theme.text).frame(width: max(6, 120 * CGFloat(position ?? 0) / 100), height: 6)
            }
            .frame(width: 120)
            key("T", .in)
        }
        .opacity(enabled ? 1 : 0.35)
    }
    private func key(_ title: String, _ dir: ZoomDirection) -> some View {
        Text(title).font(.system(size: 16, weight: .heavy)).foregroundStyle(held == dir ? Color.black : Theme.text)
            .frame(width: MobileMetrics.target, height: MobileMetrics.target)
            .background(held == dir ? Theme.accent : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if enabled, held == nil { held = dir; onZoom(dir, .start) } }
                    .onEnded { _ in
                        guard enabled else { return }
                        held = nil
                        onZoom(dir, .stop)
                    }
            )
            .simultaneousGesture(TapGesture().onEnded { if enabled { onZoom(dir, .oneShot) } })
    }
}

/// Sony's focus dot: green = focused, blinking red = failed, hollow = hunting.
struct FocusDot: View {
    let status: String?
    @State private var blink = false
    var body: some View {
        Group {
            switch status {
            case "Focused": Circle().fill(Theme.ok)
            case "Failed": Circle().fill(Theme.rec).opacity(blink ? 1 : 0.15)
            case "Focusing": Circle().stroke(Color.white, lineWidth: 1.5)
            default: Circle().fill(.clear)
            }
        }
        .frame(width: 11, height: 11)
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in blink.toggle() }
    }
}

struct SharpnessBar: View {
    let ratio: Double
    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(width: 60, height: 5)
                Capsule().fill(ratio >= FocusAnalyzer.inFocusRatio ? Theme.ok : (ratio >= FocusAnalyzer.softRatio ? Theme.warn : Color.white))
                    .frame(width: 60 * max(0.02, min(1, ratio)), height: 5)
            }
            Text(String(format: "%.0f", ratio * 100)).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// This session's shots; tap to review.
struct MobileFilmstrip: View {
    @Environment(CameraSession.self) private var session
    @State private var thumbs = ThumbnailCache()
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(session.captures.suffix(12)) { shot in
                    Button { session.review(shot) } label: {
                        ZStack(alignment: .bottomTrailing) {
                            if let url = shot.primary?.url, let t = thumbs.image(for: url) {
                                Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Rectangle().fill(Color.white.opacity(0.15))
                            }
                            if shot.transferring { ProgressView().controlSize(.mini).padding(3) }
                            else if shot.hasBoth { Text("RAW+J").font(.system(size: 8, weight: .bold)).foregroundStyle(.white).padding(3) }
                        }
                        .frame(width: 64, height: 43).clipped()
                        .overlay(Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 43)
    }
}
#endif
```

(A tap fires `start` then `stop` from the drag gesture and `oneShot` from the simultaneous tap gesture; the camera treats stop-after-start as a negligible move and the 1shot as one notch, matching how Sony's own app behaves.)

- [ ] **Step 2: Build for iOS**

Run: `xcodebuild -project iOS/CinemaHUDMobile.xcodeproj -scheme CinemaHUDMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build 2>&1 | grep -E "error|warning: unused" | head`
Expected: no errors (`ThumbnailCache` is in `PhotoHUD.swift`, compiled for both platforms).

- [ ] **Step 3: Commit**

```bash
git add Sources/CinemaUI/Mobile/MobileChrome.swift
git commit -m "Mobile chrome: tool buttons, readouts, mode switch, candidate sheet, record/shutter, zoom rocker, filmstrip"
```

---

### Task 5: Bottom sheets — Guides, Focus, Zoom, Format

**Files:**
- Create: `Sources/CinemaUI/Mobile/MobileSheets.swift`

**Interfaces:**
- Consumes: Task 3 settings, Task 4 chrome, session methods from Task 1.
- Produces: `GuidesSheet()`, `FocusSheet(liveSharpness:)`, `ZoomSheet()`, `FormatSheet()`, `SheetChrome` (shared container).

- [ ] **Step 1: Write the sheets**

```swift
// Sources/CinemaUI/Mobile/MobileSheets.swift
#if !os(macOS)
import SwiftUI
import SonyCameraKit

/// Common frame for every sheet: title, Done, dark list styling.
struct SheetChrome<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form { content }
                .scrollContentBackground(.hidden)
                .background(Theme.field)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(Theme.accent)
    }
}

private struct SetOnCamera: View {
    let what: String
    var body: some View {
        HStack { Text(what); Spacer(); Text("Set on camera").foregroundStyle(Theme.dim) }
    }
}

struct GuidesSheet: View {
    @Environment(OverlaySettings.self) private var overlays
    var body: some View {
        @Bindable var ov = overlays
        SheetChrome(title: "Guides") {
            Section {
                Toggle("Thirds grid", isOn: $ov.grid)
                Toggle("Centre marker", isOn: $ov.centerMarker)
                Toggle("Action / title safe", isOn: $ov.safeAreas)
                Toggle("Diagonals", isOn: $ov.diagonals)
            }
            Section("Frame lines") {
                Toggle("Show frame lines", isOn: $ov.frameGuides)
                Picker("Ratio", selection: $ov.guideRatio) { ForEach(FrameGuideRatio.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).disabled(!overlays.frameGuides)
            }
            Section("Monitor crop") {
                Picker("Crop", selection: $ov.crop) { ForEach(CropRatio.allCases) { Text($0.label).tag($0) } }
                Text("Crop trims the picture to the ratio; frame lines only draw over it.").font(.footnote).foregroundStyle(Theme.dim)
            }
            Section {
                Button("Clear all guides", role: .destructive) {
                    ov.grid = false; ov.centerMarker = false; ov.safeAreas = false; ov.diagonals = false; ov.frameGuides = false; ov.crop = .native
                }
            }
        }
    }
}

struct FocusSheet: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    let liveSharpness: Double
    @State private var wheel: CGFloat = 0
    var body: some View {
        @Bindable var ov = overlays
        let s = session.state
        SheetChrome(title: "Focus") {
            Section("Autofocus") {
                if !s.focusModeCandidates.isEmpty {
                    Picker("Mode", selection: Binding(get: { s.focusMode ?? "" }, set: { v in Task { await session.setFocusMode(v) } })) {
                        ForEach(s.focusModeCandidates, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented).disabled(!s.supports("setFocusMode"))
                } else {
                    SetOnCamera(what: "Focus mode")
                }
                HStack {
                    Button { Task { await session.autofocus() } } label: { Label("Autofocus", systemImage: "scope").frame(maxWidth: .infinity, minHeight: 36) }
                        .buttonStyle(.bordered).disabled(!s.supports("actHalfPressShutter"))
                    FocusDot(status: s.focusStatus)
                    Text(s.focusStatus ?? "").font(.footnote).foregroundStyle(Theme.dim)
                }
            }
            Section("Manual focus") {
                if session.focusDriveAvailable {
                    // Wheel: drag left/right nudges focus in fine steps, like turning the ring.
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)).frame(height: 56)
                        HStack(spacing: 0) {
                            ForEach(0 ..< 24, id: \.self) { i in
                                Rectangle().fill(Color.white.opacity(i % 6 == 0 ? 0.7 : 0.3)).frame(width: 1, height: i % 6 == 0 ? 24 : 12)
                                if i < 23 { Spacer() }
                            }
                        }
                        .padding(.horizontal, 12)
                        Text("NEAR   ◀   FOCUS RING   ▶   FAR").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.dim).offset(y: 20)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4).onChanged { g in
                        let step: CGFloat = 12
                        let delta = g.translation.width - wheel
                        if abs(delta) >= step { wheel = g.translation.width; Task { await session.focusDrive(delta > 0 ? 1 : -1) } }
                    }.onEnded { _ in wheel = 0 })
                    HStack(spacing: 8) {
                        ForEach([(-7, "◀◀◀"), (-4, "◀◀"), (-1, "◀"), (1, "▶"), (4, "▶▶"), (7, "▶▶▶")], id: \.0) { step, label in
                            Button(label) { Task { await session.focusDrive(step) } }.buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 40)
                        }
                    }
                    Text("Works in MF / DMF. Larger arrows move further.").font(.footnote).foregroundStyle(Theme.dim)
                } else {
                    Text("Manual focus drive needs USB or the Mac bridge; Sony's Wi-Fi remote API has no focus ring control.")
                        .font(.footnote).foregroundStyle(Theme.dim)
                }
            }
            Section("Focus assist") {
                Toggle("Focus peaking", isOn: $ov.peaking)
                Picker("Peaking colour", selection: $ov.peakingColor) { ForEach(PeakingColor.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).disabled(!overlays.peaking)
                Toggle("2× magnify", isOn: $ov.magnify)
                Toggle("Sharpness meter", isOn: $ov.showSharpnessMeter)
                HStack { Text("AF region sharpness"); Spacer(); SharpnessBar(ratio: liveSharpness) }
                Text("The meter scores the AF region against the sharpest part of the frame. Tap the picture to move the region.")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
        }
    }
}

struct ZoomSheet: View {
    @Environment(CameraSession.self) private var session
    var body: some View {
        SheetChrome(title: "Zoom") {
            if session.zoomAvailable {
                Section {
                    HStack { Spacer(); ZoomRocker(position: session.state.zoomPosition) { d, m in Task { await session.zoom(d, m) } }; Spacer() }
                        .padding(.vertical, 8)
                    if let f = session.state.focalLengthMM { HStack { Text("Focal length"); Spacer(); Text(String(format: "%.0f mm", f)).foregroundStyle(Theme.dim) } }
                    Text("Hold W or T to zoom, tap for one step.").font(.footnote).foregroundStyle(Theme.dim)
                }
            } else {
                Section {
                    Text(session.transport == .wifi
                         ? "The camera reports no power-zoom lens. Zoom works with power-zoom lenses such as the 16-50 mm PZ."
                         : "Zoom control is only available over the camera's Wi-Fi connection with a power-zoom lens; the USB protocol has no zoom drive.")
                        .font(.footnote).foregroundStyle(Theme.dim)
                }
            }
        }
    }
}

struct FormatSheet: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    var body: some View {
        @Bindable var ov = overlays
        let s = session.state
        SheetChrome(title: "Format") {
            Section("Stills") {
                if session.stillSizeAvailable {
                    Picker("Size and aspect", selection: Binding(get: { s.stillSize?.id ?? "" }, set: { id in
                        if let pick = s.stillSizeCandidates.first(where: { $0.id == id }) { Task { await session.setStillSize(pick) } }
                    })) {
                        ForEach(s.stillSizeCandidates) { Text($0.label).tag($0.id) }
                    }
                } else {
                    SetOnCamera(what: "Still size and aspect")
                }
            }
            Section("Movie") {
                if session.movieFileFormatAvailable {
                    Picker("File format", selection: Binding(get: { s.movieFileFormat ?? "" }, set: { v in Task { await session.setMovieFileFormat(v) } })) {
                        ForEach(s.movieFileFormatCandidates, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    SetOnCamera(what: "File format")
                }
                if session.movieQualityAvailable {
                    Picker("Quality", selection: Binding(get: { s.movieQuality ?? "" }, set: { v in Task { await session.setMovieQuality(v) } })) {
                        ForEach(s.movieQualityCandidates, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    SetOnCamera(what: "Resolution / quality")
                }
                Text(session.transport == .wifi
                     ? "Rows marked \"Set on camera\" are not exposed by this camera's remote API."
                     : "The α6400's USB protocol does not expose movie format; change it on the body.")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
            Section("Monitor") {
                Picker("Crop ratio", selection: $ov.crop) { ForEach(CropRatio.allCases) { Text($0.menuTitle).tag($0) } }
                Picker("Project frame rate", selection: $ov.projectFPS) { ForEach([24, 25, 30, 48, 50, 60], id: \.self) { Text("\($0) fps").tag($0) } }
            }
        }
    }
}
#endif
```

- [ ] **Step 2: Build for iOS**

Run: `xcodebuild -project iOS/CinemaHUDMobile.xcodeproj -scheme CinemaHUDMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build 2>&1 | grep -E "error" | head` → nothing.

- [ ] **Step 3: Commit**

```bash
git add Sources/CinemaUI/Mobile/MobileSheets.swift
git commit -m "Mobile sheets: guides, focus (MF wheel, peaking, meter), zoom, format"
```

---

### Task 6: MobileCameraView — landscape and portrait, video and photo

**Files:**
- Create: `Sources/CinemaUI/Mobile/MobileCameraView.swift`
- Modify: `Sources/CinemaUI/ReviewView.swift` (pinch to zoom on iOS)

**Interfaces:**
- Consumes: Tasks 3–5; `MetalFrameView`, `FrameProcessor.pipeline`, `LiveSharpnessMeter`, `FrameOverlays`, `BracketFrame`, `ReviewView`.
- Produces: `public struct MobileCameraView: View` (the iOS root once connected).

- [ ] **Step 1: Write the view**

```swift
// Sources/CinemaUI/Mobile/MobileCameraView.swift
#if !os(macOS)
import SwiftUI
import CoreImage
import SonyCameraKit

/// iPhone / iPad monitor: the picture plus touch chrome, in either orientation, for video and photo.
public struct MobileCameraView: View {
    public init() {}
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    @State private var processor = FrameProcessor()
    @State private var processed: CIImage?
    @State private var meter = LiveSharpnessMeter()
    @State private var liveSharpness: Double = 0
    @State private var afFlash = false
    @State private var sheet: MobileSheet?
    @State private var hint: String?

    enum MobileSheet: String, Identifiable {
        case guides, focus, zoom, format, settings, shutter, iris, iso, ev, wb
        var id: String { rawValue }
    }

    public var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            ZStack {
                Color.black.ignoresSafeArea()
                if let shot = session.reviewShot, overlays.shootingMode == .photo {
                    ReviewView(shot: shot).ignoresSafeArea(edges: portrait ? [] : .all)
                } else if portrait {
                    portraitLayout(geo.size)
                } else {
                    landscapeLayout(geo.size)
                }
            }
        }
        .sheet(item: $sheet) { which in sheetView(which) }
        .onChange(of: session.frame, initial: true) { _, f in reprocess(f) }
        .onChange(of: overlays.peaking) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.peakingColor) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.zebra) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.falseColor) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.lutOn) { _, _ in processor.lutCube = overlays.activeLUT; reprocess(session.frame) }
        .onChange(of: overlays.profile) { _, _ in processor.lutCube = overlays.activeLUT; reprocess(session.frame) }
        .onChange(of: overlays.feedColorSpace) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.rotation) { _, _ in reprocess(session.frame) }
        .onChange(of: session.phase.isConnected) { _, live in if !live { sheet = nil } }
        .onAppear { processor.lutCube = overlays.activeLUT }
    }

    // MARK: Layouts

    private func landscapeLayout(_ size: CGSize) -> some View {
        HStack(spacing: 0) {
            leftRail
            VStack(spacing: 0) {
                topBand
                picture
                bottomBand
            }
            rightRail
        }
    }

    private func portraitLayout(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            topBand
            picture.frame(height: size.width * pictureAspectInverse)
            ScrollView {
                VStack(spacing: 14) {
                    exposureRow
                    toolRows
                    HStack(spacing: 28) {
                        MobileToolButton(icon: "scope", label: "AF", enabled: session.state.supports("actHalfPressShutter")) { Task { await session.autofocus() } }
                        primaryButton
                        MobileToolButton(icon: "gearshape", label: "SETTINGS") { sheet = .settings }
                    }
                    .padding(.top, 4)
                    if overlays.shootingMode == .photo { MobileFilmstrip().padding(.horizontal, 12) }
                }
                .padding(.vertical, 12)
            }
        }
    }

    /// Height / width of the displayed picture (crop and rotation applied).
    private var pictureAspectInverse: CGFloat {
        let l = imageLayout(in: CGSize(width: 1000, height: 1000))
        return l.rect.height / l.rect.width
    }

    // MARK: Bands and rails

    private var topBand: some View {
        let s = session.state
        return HStack(spacing: 12) {
            ModeSwitch(mode: overlays.shootingMode) { switchMode(to: $0) }
            if let h = hint { Text(h).font(.system(size: 11)).foregroundStyle(Theme.warn).lineLimit(1).minimumScaleFactor(0.7) }
            Spacer(minLength: 4)
            if s.isRecording {
                HStack(spacing: 5) { Circle().fill(Theme.rec).frame(width: 9, height: 9); Text("REC " + duration(s.recordingTimeSeconds)).font(Theme.strip(13)).foregroundStyle(Theme.rec) }
            } else if let t = session.transport {
                Text(t.rawValue.uppercased()).font(Theme.label(10)).foregroundStyle(Theme.dim)
            }
            if let m = s.recordableMinutes { Text(String(format: "%d:%02d h", m / 60, m % 60)).font(Theme.mono(11)).foregroundStyle(Theme.dim) }
            else if let n = s.shotsRemaining { Text("[ \(n) ]").font(Theme.mono(11)).foregroundStyle(Theme.dim) }
            if let b = s.battery { Text("\(Int(b.fraction * 100))%").font(Theme.mono(11)).foregroundStyle(b.fraction < 0.15 ? Theme.rec : Theme.dim) }
            if let e = session.lastError { Text(e).font(.system(size: 10)).foregroundStyle(Theme.warn).lineLimit(1).frame(maxWidth: 160) }
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(Theme.field)
    }

    private var bottomBand: some View {
        ScrollView(.horizontal, showsIndicators: false) { exposureRow.padding(.horizontal, 8) }
            .frame(height: MobileMetrics.target + 8)
            .background(Theme.field)
    }

    private var exposureRow: some View {
        let s = session.state
        return HStack(spacing: 2) {
            MobileReadout(label: "SHUTTER", value: s.shutterSpeed ?? "--", enabled: s.supports("setShutterSpeed"),
                          onStep: { d in Task { await session.step(s.shutterSpeedCandidates, current: s.shutterSpeed, by: d) { await session.setShutterSpeed($0) } } },
                          onTap: { sheet = .shutter })
            MobileReadout(label: "IRIS", value: s.fNumber.map { "F" + $0 } ?? "--", enabled: s.supports("setFNumber"),
                          onStep: { d in Task { await session.step(s.fNumberCandidates, current: s.fNumber, by: d) { await session.setFNumber($0) } } },
                          onTap: { sheet = .iris })
            MobileReadout(label: "ISO", value: s.iso ?? "--", enabled: s.supports("setIsoSpeedRate"),
                          onStep: { d in Task { await session.step(s.isoCandidates, current: s.iso, by: d) { await session.setISO($0) } } },
                          onTap: { sheet = .iso })
            MobileReadout(label: "EV", value: s.exposureCompensation?.label ?? "--", enabled: s.supports("setExposureCompensation") && s.exposureCompensation != nil,
                          accent: (s.exposureCompensation?.index ?? 0) == 0 ? Theme.text : Theme.accent,
                          onStep: { d in Task { await session.stepExposureCompensation(d) } },
                          onTap: { sheet = .ev })
            MobileReadout(label: "WB", value: wbValue(s), enabled: s.supports("setWhiteBalance"),
                          onStep: { d in
                              guard s.whiteBalanceMode == "Color Temperature", let k = s.colorTemperature else { return }
                              Task { await session.setWhiteBalance(mode: "Color Temperature", colorTemp: max(2500, min(9900, k + d * 100))) }
                          },
                          onTap: { sheet = .wb })
            MobileReadout(label: "FOCUS", value: s.focusMode ?? "--", enabled: true,
                          accent: s.focusStatus == "Focused" ? Theme.ok : (s.focusStatus == "Failed" ? Theme.rec : Theme.text),
                          onTap: { sheet = .focus })
        }
    }

    private var leftRail: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                MobileToolButton(icon: "grid", label: "GUIDES", active: overlays.grid || overlays.frameGuides || overlays.safeAreas || overlays.diagonals) { sheet = .guides }
                MobileToolButton(icon: "waveform.path.ecg", label: "PEAK", active: overlays.peaking) { overlays.peaking.toggle() }
                MobileToolButton(icon: "line.diagonal", label: "ZEBRA", active: overlays.zebra) { overlays.zebra.toggle() }
                MobileToolButton(icon: "plus.magnifyingglass", label: "2×", active: overlays.magnify) { overlays.magnify.toggle() }
                MobileToolButton(icon: "circle.lefthalf.filled", label: overlays.lutOn ? "709" : "LOG", active: overlays.lutOn && (overlays.profile.isLog || overlays.customLUT != nil),
                                 enabled: overlays.profile.isLog || overlays.customLUT != nil) { overlays.lutOn.toggle() }
                MobileToolButton(icon: "chart.bar.xaxis", label: overlays.scope == .none ? "SCOPE" : overlays.scope.rawValue, active: overlays.scope != .none) { overlays.scope = overlays.scope.next }
                MobileToolButton(icon: "square.and.arrow.down", label: "FORMAT") { sheet = .format }
                Spacer(minLength: 0)
                MobileToolButton(icon: "gearshape", label: "SETUP") { sheet = .settings }
            }
            .padding(.vertical, 8)
        }
        .frame(width: MobileMetrics.railWidth)
        .background(Theme.field)
    }

    private var rightRail: some View {
        let s = session.state
        return ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                MobileToolButton(icon: "scope", label: "AF", enabled: s.supports("actHalfPressShutter")) { Task { await session.autofocus() } }
                MobileToolButton(icon: "lock", label: "AEL") { Task { await session.press(.aeLock) } }
                MobileToolButton(icon: "camera.aperture", label: "FOCUS", active: overlays.peaking) { sheet = .focus }
                MobileToolButton(icon: "arrow.up.left.and.arrow.down.right", label: "ZOOM", active: false, enabled: true) { sheet = .zoom }
                if overlays.shootingMode == .video {
                    MobileToolButton(icon: "camera", label: "STILL", enabled: s.supports("actTakePicture")) { Task { await session.takePicture() } }
                }
                Spacer(minLength: 0)
                primaryButton
            }
            .padding(.vertical, 8)
        }
        .frame(width: MobileMetrics.railWidth)
        .background(Theme.field)
    }

    private var toolRows: some View {
        let s = session.state
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                MobileToolButton(icon: "grid", label: "GUIDES", active: overlays.grid || overlays.frameGuides || overlays.safeAreas || overlays.diagonals) { sheet = .guides }
                MobileToolButton(icon: "waveform.path.ecg", label: "PEAK", active: overlays.peaking) { overlays.peaking.toggle() }
                MobileToolButton(icon: "line.diagonal", label: "ZEBRA", active: overlays.zebra) { overlays.zebra.toggle() }
                MobileToolButton(icon: "plus.magnifyingglass", label: "2×", active: overlays.magnify) { overlays.magnify.toggle() }
                MobileToolButton(icon: "chart.bar.xaxis", label: overlays.scope == .none ? "SCOPE" : overlays.scope.rawValue, active: overlays.scope != .none) { overlays.scope = overlays.scope.next }
            }
            HStack(spacing: 8) {
                MobileToolButton(icon: "camera.aperture", label: "FOCUS") { sheet = .focus }
                MobileToolButton(icon: "arrow.up.left.and.arrow.down.right", label: "ZOOM") { sheet = .zoom }
                MobileToolButton(icon: "square.and.arrow.down", label: "FORMAT") { sheet = .format }
                MobileToolButton(icon: "lock", label: "AEL") { Task { await session.press(.aeLock) } }
                if overlays.shootingMode == .video {
                    MobileToolButton(icon: "camera", label: "STILL", enabled: s.supports("actTakePicture")) { Task { await session.takePicture() } }
                } else {
                    MobileToolButton(icon: "circle.lefthalf.filled", label: overlays.lutOn ? "709" : "LOG", enabled: overlays.profile.isLog || overlays.customLUT != nil) { overlays.lutOn.toggle() }
                }
            }
        }
    }

    @ViewBuilder private var primaryButton: some View {
        let s = session.state
        if overlays.shootingMode == .photo {
            ShutterButton(enabled: s.supports("actTakePicture"), busy: session.busy) { Task { await session.takePicture() } }
        } else {
            RecordButton(recording: s.isRecording, enabled: s.supports("startMovieRec") || s.supports("stopMovieRec")) { Task { await session.toggleRecording() } }
        }
    }

    // MARK: Picture

    struct ImageLayout {
        var rect: CGRect
        var fullSize: CGSize
        var cropX: CGFloat, cropY: CGFloat, cropWidth: CGFloat, cropHeight: CGFloat
    }

    private func imageLayout(in size: CGSize) -> ImageLayout {
        let w0 = session.frameSize.width, h0 = session.frameSize.height
        var native: CGFloat = (w0 > 0 && h0 > 0) ? w0 / h0 : 3.0 / 2.0
        if overlays.rotation != 0 { native = 1 / native }
        var aspect = native
        var cropH: CGFloat = 1, cropW: CGFloat = 1
        if overlays.shootingMode == .video, let t = overlays.crop.value {
            let target = CGFloat(t)
            if target > native { aspect = target; cropH = native / target } else if target < native { aspect = target; cropW = target / native }
        }
        let zoom: CGFloat = overlays.magnify ? 2 : 1
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        let rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        let cw = cropW / zoom, ch = cropH / zoom
        return ImageLayout(rect: rect, fullSize: CGSize(width: w / cropW * zoom, height: h / cropH * zoom),
                           cropX: (1 - cw) / 2, cropY: (1 - ch) / 2, cropWidth: cw, cropHeight: ch)
    }

    private var picture: some View {
        GeometryReader { geo in
            let layout = imageLayout(in: geo.size)
            let rect = layout.rect
            let s = session.state
            ZStack {
                Color.black
                if let img = processed {
                    MetalFrameView(image: img, enhanced: overlays.enhanced || overlays.shootingMode == .photo, sharpen: overlays.detail ? 0.35 : 0, colorSpace: overlays.feedColorSpace.cgColorSpace)
                        .frame(width: layout.fullSize.width, height: layout.fullSize.height)
                        .position(x: rect.midX, y: rect.midY)
                        .clipShape(Rectangle().path(in: rect))
                } else {
                    VStack(spacing: 8) { ProgressView(); Text("WAITING FOR LIVE VIEW").font(Theme.label(11)).tracking(3).foregroundStyle(Theme.dim) }
                }
                FrameOverlays(rect: rect)
                if s.isRecording {
                    Rectangle().stroke(Theme.rec, lineWidth: 3).frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                }
                afFrame(in: rect, layout: layout)
                Color.clear.contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    .onTapGesture { loc in
                        var x = layout.cropX + loc.x / rect.width * layout.cropWidth
                        var y = layout.cropY + loc.y / rect.height * layout.cropHeight
                        if overlays.rotation == 90 { (x, y) = (y, 1 - x) } else if overlays.rotation == 270 { (x, y) = (1 - y, x) }
                        afFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { afFlash = false }
                        Task { await session.touchAF(x: x, y: y) }
                    }
                if overlays.showSharpnessMeter || overlays.shootingMode == .photo {
                    HStack(spacing: 8) { FocusDot(status: s.focusStatus); SharpnessBar(ratio: liveSharpness) }
                        .padding(8).background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        .position(x: rect.minX + 70, y: rect.maxY - 22)
                        .allowsHitTesting(false)
                }
                if overlays.shootingMode == .photo, !session.captures.isEmpty, geo.size.width > geo.size.height {
                    MobileFilmstrip().frame(width: min(rect.width - 160, 600)).position(x: rect.midX, y: rect.maxY - 30)
                }
            }
        }
    }

    @ViewBuilder private func afFrame(in rect: CGRect, layout: ImageLayout) -> some View {
        let s = session.state
        let p = session.focusCheckPoint ?? s.touchAFPoint.map { CGPoint(x: $0.x / 100, y: $0.y / 100) }
        if let p, overlays.shootingMode == .photo || s.touchAFSet {
            let fx = (p.x - layout.cropX) / layout.cropWidth, fy = (p.y - layout.cropY) / layout.cropHeight
            let color: Color = s.focusStatus == "Focused" ? Theme.ok : (s.focusStatus == "Failed" ? Theme.rec : .white)
            BracketFrame().stroke(color, lineWidth: 2)
                .frame(width: rect.width * 0.09, height: rect.width * 0.09)
                .position(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
                .scaleEffect(afFlash ? 1.2 : 1).animation(.easeOut(duration: 0.25), value: afFlash)
                .clipShape(Rectangle().path(in: rect))
                .allowsHitTesting(false)
        }
    }

    // MARK: Behaviour

    private func switchMode(to mode: ShootingMode) {
        guard mode != overlays.shootingMode else { return }
        if session.state.supports("setShootMode") {
            Task { await session.setShootMode(mode == .photo ? "still" : "movie") }
        } else {
            overlays.modeResolver.toggle()
            let dial = ShootingModeResolver.mode(forDial: session.state.shootMode)
            if let dial, dial != mode {
                hint = mode == .photo ? "Turn the dial to a stills position" : "Turn the dial to the movie position"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { hint = nil }
            }
        }
    }

    private func reprocess(_ frame: CIImage?) {
        guard let frame else { processed = nil; return }
        let source = frame.matchedToWorkingSpace(from: overlays.feedColorSpace.cgColorSpace) ?? frame
        let video = overlays.shootingMode == .video
        processed = processor.pipeline(source, peaking: overlays.peaking, zebra: video && overlays.zebra, zebraLevel: overlays.zebraLevel,
                                       falseColor: video && overlays.falseColor, rotation: overlays.rotation, peakingColor: overlays.peakingColor.rgb)
        if overlays.showSharpnessMeter || overlays.shootingMode == .photo {
            let point = session.focusCheckPoint ?? session.state.touchAFPoint.map { CGPoint(x: $0.x / 100, y: $0.y / 100) }
            meter.measure(frame, afPoint: point) { r in liveSharpness = r }
        }
    }

    @ViewBuilder private func sheetView(_ which: MobileSheet) -> some View {
        let s = session.state
        switch which {
        case .guides: GuidesSheet()
        case .focus: FocusSheet(liveSharpness: liveSharpness)
        case .zoom: ZoomSheet()
        case .format: FormatSheet()
        case .settings: MobileSettingsView()
        case .shutter: MobileCandidateSheet(title: "Shutter", current: s.shutterSpeed ?? "", candidates: s.shutterSpeedCandidates) { v in Task { await session.setShutterSpeed(v) } }
        case .iris: MobileCandidateSheet(title: "Iris", current: s.fNumber ?? "", candidates: s.fNumberCandidates, format: { "F" + $0 }) { v in Task { await session.setFNumber(v) } }
        case .iso: MobileCandidateSheet(title: "ISO", current: s.iso ?? "", candidates: s.isoCandidates) { v in Task { await session.setISO(v) } }
        case .ev:
            let ev = s.exposureCompensation
            let items = ev.map { e in (e.minIndex ... e.maxIndex).reversed().map { String($0) } } ?? []
            MobileCandidateSheet(title: "Exposure compensation", current: ev.map { String($0.index) } ?? "", candidates: items,
                                 format: { i in ev.map { e in let v = Double(Int(i) ?? 0) * e.stepEV; return abs(v) < 0.01 ? "0" : String(format: "%@%.1f", v > 0 ? "+" : "", v) } ?? i }) { v in
                if let i = Int(v) { Task { await session.setExposureCompensation(index: i) } }
            }
        case .wb:
            let modes = s.whiteBalanceCandidates.isEmpty ? ["Auto WB", "Daylight", "Shade", "Cloudy", "Incandescent", "Flash", "Color Temperature"] : s.whiteBalanceCandidates
            MobileCandidateSheet(title: "White balance", current: s.whiteBalanceMode ?? "", candidates: modes) { v in
                Task { await session.setWhiteBalance(mode: v, colorTemp: v == "Color Temperature" ? (s.colorTemperature ?? 5600) : nil) }
            }
        }
    }

    private func wbValue(_ s: CameraState) -> String {
        if s.whiteBalanceMode == "Color Temperature", let k = s.colorTemperature { return "\(k)K" }
        switch s.whiteBalanceMode { case "Auto WB": return "AWB"; case nil: return "--"; default: return String(s.whiteBalanceMode!.prefix(7)).uppercased() }
    }

    private func duration(_ secs: Int) -> String { String(format: "%02d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60) }
}
#endif
```

`MobileSettingsView` is created in Task 7; until then add a stand-in at the bottom of this file, removed in Task 7:

```swift
#if !os(macOS)
struct MobileSettingsView: View { var body: some View { SheetChrome(title: "Settings") { Text("Coming in Task 7") } } }
#endif
```

- [ ] **Step 2: Pinch to zoom in ReviewView on touch**

In `ReviewView.picture(_:in:)`, after `.gesture(DragGesture()…)` add:

```swift
        #if !os(macOS)
        .simultaneousGesture(MagnificationGesture().onEnded { m in cycleZoom(m > 1 ? 1 : -1) })
        #endif
```

- [ ] **Step 3: Build for iOS**

Run: `xcodebuild -project iOS/CinemaHUDMobile.xcodeproj -scheme CinemaHUDMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build 2>&1 | grep -E "error" | head` → nothing. Fix any SF Symbol names the compiler cannot verify (symbols are strings; a missing one renders blank, so also check the screenshots in Task 8).

- [ ] **Step 4: Commit**

```bash
git add Sources/CinemaUI/Mobile/MobileCameraView.swift Sources/CinemaUI/ReviewView.swift
git commit -m "MobileCameraView: touch monitor in both orientations for video and photo, with sheets"
```

---

### Task 7: Settings screen, About, Privacy Policy, Terms of Use

**Files:**
- Create: `Sources/CinemaUI/Mobile/LegalPages.swift`
- Create: `Sources/CinemaUI/Mobile/MobileSettingsView.swift`
- Modify: `Sources/CinemaUI/Mobile/MobileCameraView.swift` (delete the stand-in)
- Modify: `Sources/SonyCameraKit/CapturedImage.swift` (`CaptureStore.defaultBase` on iOS → Documents)
- Modify: `iOS/CinemaHUDMobile/Info.plist` (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`)
- Test: `Tests/SonyCameraKitTests/GuidesTests.swift` (add legal text sanity test)

**Interfaces:**
- Produces: `LegalText.privacyPolicy`, `LegalText.termsOfUse`, `LegalText.effectiveDate`, `LegalPageView(title:text:)`, `MobileSettingsView()`.

- [ ] **Step 1: Write the failing test** (append to `GuidesTests`)

```swift
    func testLegalTextsAreComplete() {
        XCTAssertTrue(LegalText.privacyPolicy.contains("does not collect"))
        XCTAssertTrue(LegalText.privacyPolicy.contains("Shiv Vyas"))
        XCTAssertTrue(LegalText.privacyPolicy.contains("[contact email]"))
        XCTAssertTrue(LegalText.termsOfUse.contains("not affiliated"))
        XCTAssertTrue(LegalText.termsOfUse.contains("AS IS"))
        XCTAssertEqual(LegalText.paragraphs(LegalText.termsOfUse).filter { $0.isHeading }.count, 8)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GuidesTests 2>&1 | grep -E "error:" | head -2` → `cannot find 'LegalText' in scope`.

- [ ] **Step 3: Legal pages** (compiled on both platforms so the test can see it; the view is iOS only)

```swift
// Sources/CinemaUI/Mobile/LegalPages.swift
import SwiftUI

/// Privacy Policy and Terms of Use, as plain text with `# ` headings. Shown in Settings and reusable for a store listing.
public enum LegalText {
    public static let developer = "Shiv Vyas"
    public static let contact = "[contact email]"
    public static let effectiveDate = "15 September 2026"

    public struct Paragraph: Identifiable, Equatable {
        public let id: Int
        public let text: String
        public let isHeading: Bool
    }

    public static func paragraphs(_ text: String) -> [Paragraph] {
        text.components(separatedBy: "\n\n").enumerated().map { i, p in
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            return Paragraph(id: i, text: t.hasPrefix("# ") ? String(t.dropFirst(2)) : t, isHeading: t.hasPrefix("# "))
        }
    }

    public static let privacyPolicy = """
    # Privacy Policy

    Effective \(effectiveDate). CinemaHUD is developed by \(developer) ("we", "us").

    # What we collect

    CinemaHUD does not collect, store or transmit any personal data. There are no accounts, no analytics, no advertising identifiers, no crash reporting services and no third-party SDKs that collect data.

    # Local network

    The app talks only to your Sony camera (over the camera's own Wi-Fi network) or to a Mac running CinemaHUD on the same local network. iOS asks for Local Network permission for this reason alone. Nothing is sent to the Internet by the app.

    # Photos and recordings

    Images the camera hands over during a session are saved on this device, in the app's own folder (visible in the Files app under CinemaHUD). They stay on the device until you delete them. The app does not read your photo library and does not upload anything.

    # Settings

    Monitor preferences (guides, peaking, LUTs, last connection address) are stored on the device only.

    # Children

    CinemaHUD is a camera tool and is not directed at children. Because it collects no data, no data about anyone is processed.

    # Changes

    If this policy changes, the new version will appear here with a new effective date.

    # Contact

    Questions about privacy: \(contact).
    """

    public static let termsOfUse = """
    # Terms of Use

    Effective \(effectiveDate). By using CinemaHUD ("the app") you agree to these terms.

    # The app

    CinemaHUD is a remote monitor and controller for compatible Sony cameras, provided by \(developer). It is offered for personal and professional use with your own equipment.

    # No affiliation

    CinemaHUD is an independent product. It is not affiliated with, endorsed by or sponsored by Sony Group Corporation or its subsidiaries. Sony, Alpha and α are trademarks of Sony Group Corporation and are used only to describe compatibility.

    # Provided as is

    THE APP IS PROVIDED "AS IS" AND "AS AVAILABLE", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. Camera behaviour, connection reliability and image quality depend on your camera, lens, firmware and network.

    # Your responsibility

    You control the camera through the app at your own risk. You are responsible for your camera settings, your recordings, backing up your files, and for complying with the laws that apply to your filming and photography.

    # Limitation of liability

    To the fullest extent permitted by law, \(developer) is not liable for any lost footage, missed shots, equipment damage, or indirect or consequential loss arising from use of the app.

    # Changes to the app or these terms

    Features may change between versions as camera protocols evolve. Updated terms will appear here with a new effective date; continued use after an update means you accept the new terms.

    # Contact

    Questions about these terms: \(contact).
    """
}

#if !os(macOS)
/// Renders a legal text: headings in the monitor's tracked caps, body in readable serif-free type.
struct LegalPageView: View {
    let title: String
    let text: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(LegalText.paragraphs(text)) { p in
                    if p.isHeading {
                        Text(p.text.uppercased()).font(Theme.label(12)).tracking(2).foregroundStyle(Theme.accent).padding(.top, p.id == 0 ? 0 : 10)
                    } else {
                        Text(p.text).font(.system(size: 15)).foregroundStyle(Theme.text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 700, alignment: .leading)
        }
        .background(Theme.field)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
```

- [ ] **Step 4: Settings screen**

```swift
// Sources/CinemaUI/Mobile/MobileSettingsView.swift
#if !os(macOS)
import SwiftUI
import SonyCameraKit

struct MobileSettingsView: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var ov = overlays
        NavigationStack {
            Form {
                Section("Connection") {
                    HStack { Text("Camera"); Spacer(); Text(session.cameraName.isEmpty ? "—" : session.cameraName).foregroundStyle(Theme.dim) }
                    HStack { Text("Transport"); Spacer(); Text(session.transport?.rawValue ?? "—").foregroundStyle(Theme.dim) }
                    Button("Disconnect", role: .destructive) { session.disconnect(); dismiss() }
                }
                Section("Display") {
                    Picker("Interpret feed as", selection: $ov.feedColorSpace) { ForEach(FeedColorSpace.allCases) { Text($0.short).tag($0) } }
                    Toggle("Enhanced upscaling (MetalFX)", isOn: $ov.enhanced)
                    Toggle("Detail recovery", isOn: $ov.detail)
                    Picker("Smooth motion", selection: Binding(get: { session.motionFactor }, set: { session.motionFactor = $0 })) {
                        Text("Off").tag(1); Text("×2").tag(2); Text("×4").tag(4); Text("×8").tag(8)
                    }
                    Picker("Live denoise", selection: Binding(get: { session.denoise }, set: { session.denoise = $0 })) {
                        Text("Off").tag(Float(0)); Text("NR1").tag(Float(0.5)); Text("NR2").tag(Float(1))
                    }
                    Picker("Camera picture profile", selection: $ov.profile) { ForEach(PictureProfile.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("Apply display LUT (709 view)", isOn: $ov.lutOn).disabled(!(overlays.profile.isLog || overlays.customLUT != nil))
                    Toggle("Hide HUD", isOn: $ov.hideHUD)
                }
                Section("Guides") {
                    Toggle("Thirds grid", isOn: $ov.grid)
                    Toggle("Centre marker", isOn: $ov.centerMarker)
                    Toggle("Action / title safe", isOn: $ov.safeAreas)
                    Toggle("Diagonals", isOn: $ov.diagonals)
                    Toggle("Frame lines", isOn: $ov.frameGuides)
                    Picker("Frame line ratio", selection: $ov.guideRatio) { ForEach(FrameGuideRatio.allCases) { Text($0.label).tag($0) } }
                }
                Section("Focus assist") {
                    Toggle("Focus peaking", isOn: $ov.peaking)
                    Picker("Peaking colour", selection: $ov.peakingColor) { ForEach(PeakingColor.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("Sharpness meter", isOn: $ov.showSharpnessMeter)
                    Slider(value: $ov.zebraLevel, in: 0.7 ... 1.0, step: 0.05) { Text("Zebra level") }
                    HStack { Text("Zebra level"); Spacer(); Text("\(Int(overlays.zebraLevel * 100)) IRE").foregroundStyle(Theme.dim) }
                }
                Section("Captures") {
                    HStack { Text("This session"); Spacer(); Text("\(session.captures.count) shots").foregroundStyle(Theme.dim) }
                    Text("Files the camera hands over are saved in the Files app under CinemaHUD. Over the Mac bridge, files stay on the Mac in ~/Pictures/CinemaHUD.")
                        .font(.footnote).foregroundStyle(Theme.dim)
                }
                Section("About") {
                    HStack { Text("CinemaHUD"); Spacer(); Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").foregroundStyle(Theme.dim) }
                    Text("Independent remote monitor for Sony α cameras. Not affiliated with Sony.").font(.footnote).foregroundStyle(Theme.dim)
                    NavigationLink("Privacy Policy") { LegalPageView(title: "Privacy Policy", text: LegalText.privacyPolicy) }
                    NavigationLink("Terms of Use") { LegalPageView(title: "Terms of Use", text: LegalText.termsOfUse) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.field)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
        .tint(Theme.accent)
    }
}
#endif
```

Delete the `MobileSettingsView` stand-in from `MobileCameraView.swift`.

- [ ] **Step 5: Save captures where the Files app can see them (iOS)**

In `CapturedImage.swift` replace `CaptureStore.defaultBase` with:

```swift
    public static var defaultBase: URL {
        #if os(iOS)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CinemaHUD")
        #else
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("CinemaHUD")
        #endif
    }
```

In `iOS/CinemaHUDMobile/Info.plist` add inside the top-level dict:

```xml
	<key>UIFileSharingEnabled</key>
	<true/>
	<key>LSSupportsOpeningDocumentsInPlace</key>
	<true/>
```

- [ ] **Step 6: Test, build, commit**

Run: `swift test 2>&1 | grep -E "Executed|error:|failed" | tail -1` → `Executed 44 tests, with 0 failures`.
Run: `xcodebuild -project iOS/CinemaHUDMobile.xcodeproj -scheme CinemaHUDMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build 2>&1 | grep -E "error" | head` → nothing.

```bash
git add Sources/CinemaUI/Mobile/LegalPages.swift Sources/CinemaUI/Mobile/MobileSettingsView.swift Sources/CinemaUI/Mobile/MobileCameraView.swift Sources/SonyCameraKit/CapturedImage.swift iOS/CinemaHUDMobile/Info.plist Tests/SonyCameraKitTests/GuidesTests.swift
git commit -m "Mobile settings screen with About, Privacy Policy and Terms of Use; captures visible in Files"
```

---

### Task 8: Wire the iOS app, extend the simulator, verify on iPhone and iPad, document

**Files:**
- Modify: `iOS/CinemaHUDMobile/CinemaHUDMobileApp.swift` (route to `MobileCameraView`)
- Modify: `tools/camerasim.py` (advertise + honour zoom, still size, movie quality/format; `--pz` flag)
- Modify: `README.md` (iPhone and iPad section)

- [ ] **Step 1: Route**

In `MobileRootView.body` replace `if overlays.shootingMode == .photo { PhotoView() } else { MonitorView() }` with `MobileCameraView()`.

- [ ] **Step 2: Simulator**

In `tools/camerasim.py`:
- Add to `APIS`: `"setStillSize","getSupportedStillSize","setMovieQuality","getSupportedMovieQuality","setMovieFileFormat","getSupportedMovieFileFormat"`.
- In `Camera.__init__` add: `self.still = ["3:2", "L"]; self.movie_quality = "PS"; self.movie_format = "XAVC S"; self.zoom = 0; self.pz = False`.
- In `event_items` add:
```python
        if want("stillSize"): items[8] = {"type":"stillSize","currentAspect":self.still[0],"currentSize":self.still[1]}
        if want("movieQuality"): items[6] = {"type":"movieQuality","currentMovieQuality":self.movie_quality,"movieQualityCandidates":["PS","HQ","STD"]}
        if want("movieFileFormat"): items[7] = {"type":"movieFileFormat","currentMovieFileFormat":self.movie_format,"movieFileFormatCandidates":["MP4","XAVC S"]}
        if want("zoomInformation") and self.pz: items[2] = {"type":"zoomInformation","zoomPosition":self.zoom,"zoomNumberBox":1,"zoomIndexCurrentBox":0,"zoomPositionCurrentBox":self.zoom}
```
- In `dispatch` add before `raise ApiError(12, …)`:
```python
        if m == "getSupportedStillSize": return [[{"aspect":"3:2","size":"L"},{"aspect":"3:2","size":"M"},{"aspect":"16:9","size":"L"},{"aspect":"16:9","size":"M"}]]
        if m == "setStillSize": CAM.still = [p[0], p[1]]; CAM.bump("stillSize"); return [0]
        if m == "getSupportedMovieQuality": return [["PS","HQ","STD"]]
        if m == "setMovieQuality": self.check(p[0], ["PS","HQ","STD"]); CAM.movie_quality = p[0]; CAM.bump("movieQuality"); return [0]
        if m == "getSupportedMovieFileFormat": return [["MP4","XAVC S"]]
        if m == "setMovieFileFormat": self.check(p[0], ["MP4","XAVC S"]); CAM.movie_format = p[0]; CAM.bump("movieFileFormat"); return [0]
        if m == "actZoom":
            if not CAM.pz: raise ApiError(12, "No Such Method")
            step = 10 if p[1] == "1shot" else 25
            CAM.zoom = max(0, min(100, CAM.zoom + (step if p[0] == "in" else -step))) if p[1] != "stop" else CAM.zoom
            CAM.bump("zoomInformation"); return [0]
```
- The `availableApiList` event must include `actZoom` only with `--pz`: change `items[0]` to `{"type":"availableApiList","names":APIS + (["actZoom"] if self.pz else [])}`.
- Add `ap.add_argument("--pz", action="store_true", help="pretend a power-zoom lens is mounted")` and `if a.pz: CAM.pz = True` next to `--stills`.

- [ ] **Step 3: Build, install, screenshot on iPhone (landscape and portrait) and iPad**

Build once: `xcodebuild -project iOS/CinemaHUDMobile.xcodeproj -scheme CinemaHUDMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/ios -quiet build`.

Start the simulator camera: `python3 tools/camerasim.py --port 8090 --no-ssdp --stills --pz &` (photo mode + zoom); use plain `--port 8090 --no-ssdp --pz` for the video shots.

For each device (`iPhone 17 Pro`, then an iPad from `xcrun simctl list devices available | grep iPad`; create one with `xcrun simctl create "iPad Pro 13" "iPad Pro 13-inch (M4)"` if none exists):

```bash
xcrun simctl boot "<device>" 2>/dev/null; xcrun simctl install "<device>" build/ios/Build/Products/Debug-iphonesimulator/CinemaHUDMobile.app
SIMCTL_CHILD_CINEMAHUD_ADDRESS=127.0.0.1:8090 SIMCTL_CHILD_CINEMAHUD_NO_INTRO=1 xcrun simctl launch --terminate-running-process "<device>" com.shivvyas.cinemahud.mobile
sleep 6; xcrun simctl io "<device>" screenshot <scratch>/<device>-portrait.png
osascript -e 'tell application "Simulator" to activate' -e 'tell application "System Events" to keystroke "l" using command down'   # rotate left
sleep 3; xcrun simctl io "<device>" screenshot <scratch>/<device>-landscape.png
```

Open each screenshot with the Read tool and check: nothing clipped at the edges, rails and bands inside the safe area, readouts legible, mode switch present, the sheets open (tap via `xcrun simctl` is not scriptable; open a sheet by launching with `SIMCTL_CHILD_CINEMAHUD_OVERLAYS=sheet:focus` — add that dev hook: in `MobileCameraView.onAppear`, `if let v = ProcessInfo.processInfo.environment["CINEMAHUD_OVERLAYS"], v.hasPrefix("sheet:"), let s = MobileSheet(rawValue: String(v.dropFirst(6))) { sheet = s }`). Screenshot the focus, guides, format and settings sheets on the iPhone in portrait, and the Privacy Policy page via `sheet:settings` then the Read of the screenshot showing the About section.

Fix overflow or overlap found in the screenshots before moving on (rail width, font sizes, band padding).

- [ ] **Step 4: README**

Replace the paragraph starting "`iOS/CinemaHUDMobile.xcodeproj` (generated from…" in the "## iPhone and iPad" section with:

```markdown
`iOS/CinemaHUDMobile.xcodeproj` (generated from `iOS/project.yml` with XcodeGen) builds a touch-first
field monitor for iOS 17+ on the shared `CinemaUI` and `SonyCameraKit` modules. It works in any
orientation: landscape puts tool rails on the sides and exposure along the bottom; portrait puts the
picture on top and a control deck below. A VIDEO | PHOTO switch sits in the top band (over Wi-Fi it
also moves the camera's shoot mode; over USB / bridge the body's dial decides). Sheets cover
**Guides** (thirds, centre, safe areas, diagonals, frame lines with a ratio picker), **Focus**
(AF mode, manual focus wheel and steps over USB / bridge, peaking with colour, 2× magnify, sharpness
meter), **Zoom** (W/T rocker for power-zoom lenses over Wi-Fi) and **Format** (still size / aspect,
movie quality and file format where the camera exposes them). Settings holds display options,
About, the Privacy Policy and the Terms of Use. Captures the camera hands over are saved under
CinemaHUD in the Files app.
```

- [ ] **Step 5: Final tests, commit**

Run: `swift test 2>&1 | grep -E "Executed|error:|failed" | tail -1` → `Executed 44 tests, with 0 failures`.

```bash
git add iOS/CinemaHUDMobile/CinemaHUDMobileApp.swift Sources/CinemaUI/Mobile/MobileCameraView.swift tools/camerasim.py README.md
git commit -m "iOS routes to the mobile monitor; simulator gains zoom, still size and movie format; README"
```

- [ ] **Step 6: Hand over for review**

Push the branch, open a PR against main, and message the other session to review from a clean worktree (as with PR #1). Hardware items to verify later on the α6400: zoom with the 16-50 PZ lens over Wi-Fi, MF wheel over the bridge, mode switch over Wi-Fi.
