# Pro Photo Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dial-following Photo mode to CinemaHUD that pulls every captured file (JPEG and RAW) off the camera in real time into `~/Pictures/CinemaHUD/<date>/` whether the shutter was pressed in the app or on the body, shows a Sony-body-style stills HUD with focus confirmation, and reviews the real capture at 100% with a focus verdict.

**Architecture:** The camera library gains a transport-neutral capture pipeline (a `CaptureEvent` stream from each backend fed by a continuous watcher, a `ShotLog` grouping JPEG+RAW per shot, a pure `FocusAnalyzer`) and a `ShootingModeResolver` that follows the dial. The app routes to a new `PhotoView` (live picture + `PhotoHUD`) or `ReviewView` per shot; the existing `MonitorView` video path is not touched.

**Tech Stack:** Swift 5.9, SwiftPM, SwiftUI + Metal/MetalFX + Core Image (macOS 14), ImageIO for JPEG/ARW decode, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-15-photo-mode-design.md` (plus the addition below)

**Spec addition (from the user via the other session):** shots fired with the shutter button on the camera body must transfer exactly like app-triggered shots. USB: watch `0xD215` on every state poll and drain whenever objects are queued. Wi-Fi: download new `takePictureUrl` entries from `getEvent` (`CameraState.lastPictureURLs`).

## Global Constraints

- Platform: macOS 14 (`platforms: [.macOS(.v14)]` in `Package.swift`), Swift tools 5.9.
- Do not modify: `MonitorView.swift`, `HUDBars.swift`, `HUDReadout.swift`, `Theme.swift`, `FrameProcessor.swift`, `MetalFrameView.swift`, `LUT.swift`. Video mode must look and behave exactly as before.
- Files are written to `~/Pictures/CinemaHUD/yyyy-MM-dd/` using the camera's own filename; never overwrite (suffix `-2`, `-3`, …).
- Testable logic lives in `SonyCameraKit` (the executable target cannot be imported by tests).
- Commit messages: plain, no `Co-Authored-By` trailer (user instruction).
- Run tests with `swift test 2>&1 | grep -E "Executed|error:|failed"` from the worktree root.
- Work happens in the worktree `/Users/shivvyas/Cinema/.claude/worktrees/photo-mode` on branch `worktree-photo-mode`, rebased on main `b55f3c0`. Another session edits the main checkout; never touch it.
- `CameraSession.frame` is a `CIImage?` and `MetalFrameView(image: CIImage?, enhanced:, sharpen:, colorSpace:)`; `FrameProcessor.pipeline(_:peaking:zebra:zebraLevel:falseColor:rotation:effects:) -> CIImage` builds the lazy GPU chain. `PhotoView` mirrors `MonitorView`'s calls exactly.

---

### Task 1: Capture types, file store, broadcaster, backend protocol

**Files:**
- Create: `Sources/SonyCameraKit/CapturedImage.swift`
- Modify: `Sources/SonyCameraKit/CameraBackend.swift` (protocol, after `func cancelTouchAF() async throws`)
- Modify: `Sources/SonyCameraKit/USB/SonyUSBBackend.swift` (after `public var saveDirectory: URL`)
- Modify: `Sources/SonyCameraKit/WiFiBackend.swift` (after `private var eventVersion = "1.0"`)
- Test: `Tests/SonyCameraKitTests/CaptureTests.swift`

**Interfaces:**
- Produces: `CapturedImage { id, url, kind: .jpeg|.raw, filename, takenAt, shotIndex }`, `CapturedImage.kind(objectFormat:filename:)`, `CaptureEvent { .image(CapturedImage), .finished(shotIndex:), .failed(shotIndex:message:) }`, `CaptureStore.write(_:base:filename:date:) -> URL`, `CaptureStore.defaultBase`, `CaptureBroadcaster { stream(), send(_:) }`, protocol requirement `func captureEvents() -> AsyncStream<CaptureEvent>`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SonyCameraKitTests/CaptureTests.swift
import XCTest
@testable import SonyCameraKit

final class CaptureTests: XCTestCase {
    func testKindFromObjectFormatAndName() {
        XCTAssertEqual(CapturedImage.kind(objectFormat: 0x3801, filename: "DSC00001.JPG"), .jpeg)
        XCTAssertEqual(CapturedImage.kind(objectFormat: 0xB101, filename: "DSC00001.ARW"), .raw)
        XCTAssertEqual(CapturedImage.kind(objectFormat: 0x3000, filename: "x.jpeg"), .jpeg)
        XCTAssertEqual(CapturedImage.kind(objectFormat: 0x3000, filename: "x"), .raw)
    }

    func testStoreWritesIntoDatedFolderAndNeverOverwrites() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))!
        let a = try CaptureStore.write(Data([1]), base: tmp, filename: "DSC00001.ARW", date: date)
        let b = try CaptureStore.write(Data([2]), base: tmp, filename: "DSC00001.ARW", date: date)
        XCTAssertEqual(a.deletingLastPathComponent().lastPathComponent, "2026-09-15")
        XCTAssertEqual(a.lastPathComponent, "DSC00001.ARW")
        XCTAssertEqual(b.lastPathComponent, "DSC00001-2.ARW")
        XCTAssertEqual(try Data(contentsOf: a), Data([1]))
        XCTAssertEqual(try Data(contentsOf: b), Data([2]))
    }

    func testBroadcasterDeliversToEveryListener() async {
        let b = CaptureBroadcaster()
        let s1 = b.stream(), s2 = b.stream()
        b.send(.finished(shotIndex: 7))
        var i1 = s1.makeAsyncIterator(), i2 = s2.makeAsyncIterator()
        let e1 = await i1.next(), e2 = await i2.next()
        XCTAssertEqual(e1, .finished(shotIndex: 7))
        XCTAssertEqual(e2, .finished(shotIndex: 7))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CaptureTests 2>&1 | grep -E "error:|Executed" | head`
Expected: compile errors `cannot find 'CapturedImage' in scope`, `cannot find 'CaptureStore'`, `cannot find 'CaptureBroadcaster'`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/SonyCameraKit/CapturedImage.swift
import Foundation

/// One file the camera handed over after a shot. A RAW+JPEG shot produces two of these with the same `shotIndex`.
public struct CapturedImage: Sendable, Identifiable, Equatable, Hashable {
    public enum Kind: String, Sendable { case jpeg = "JPEG", raw = "RAW" }
    public let id: UUID
    public let url: URL
    public let kind: Kind
    public let filename: String
    public let takenAt: Date
    public let shotIndex: Int

    public init(url: URL, kind: Kind, filename: String, takenAt: Date, shotIndex: Int, id: UUID = UUID()) {
        self.id = id; self.url = url; self.kind = kind; self.filename = filename; self.takenAt = takenAt; self.shotIndex = shotIndex
    }

    /// PTP ObjectFormat 0x3801 is EXIF/JPEG. Sony ARW comes with a vendor code, so anything else that is not
    /// named like a JPEG is treated as RAW.
    public static func kind(objectFormat: UInt16, filename: String) -> Kind {
        if objectFormat == 0x3801 { return .jpeg }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ext == "jpg" || ext == "jpeg" ? .jpeg : .raw
    }
}

public enum CaptureEvent: Sendable, Equatable {
    case image(CapturedImage)
    /// Every file for this shot has been delivered.
    case finished(shotIndex: Int)
    /// Nothing more will arrive for this shot; `message` is user-readable. `shotIndex` -1 = no shot was ever logged.
    case failed(shotIndex: Int, message: String)
}

/// Where captured files go on disk: `<base>/yyyy-MM-dd/<camera filename>`, never overwriting.
public enum CaptureStore {
    public static var defaultBase: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("CinemaHUD")
    }

    public static func directory(base: URL, date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return base.appendingPathComponent(f.string(from: date), isDirectory: true)
    }

    public static func uniqueURL(in dir: URL, filename: String, fileManager: FileManager = .default) -> URL {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = dir.appendingPathComponent(filename)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    @discardableResult
    public static func write(_ data: Data, base: URL, filename: String, date: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        let dir = directory(base: base, date: date)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = uniqueURL(in: dir, filename: filename, fileManager: fileManager)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Fan-out of capture events to any number of listeners. Backends own one; the session subscribes.
public final class CaptureBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<CaptureEvent>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<CaptureEvent> {
        let id = UUID()
        return AsyncStream { cont in
            lock.lock(); continuations[id] = cont; lock.unlock()
            cont.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }

    public func send(_ event: CaptureEvent) {
        lock.lock(); let targets = Array(continuations.values); lock.unlock()
        for c in targets { c.yield(event) }
    }

    private func remove(_ id: UUID) { lock.lock(); continuations[id] = nil; lock.unlock() }
}
```

In `CameraBackend.swift`, add after `func cancelTouchAF() async throws`:

```swift
    /// Files the camera hands over after each shot (app- or body-triggered), as they land on disk.
    func captureEvents() -> AsyncStream<CaptureEvent>
```

In `SonyUSBBackend.swift`, add after `public var saveDirectory: URL`:

```swift
    let captures = CaptureBroadcaster()
    public func captureEvents() -> AsyncStream<CaptureEvent> { captures.stream() }
```

In `WiFiBackend.swift`, add after `private var eventVersion = "1.0"`:

```swift
    let captures = CaptureBroadcaster()
    public var saveDirectory: URL = CaptureStore.defaultBase
    public func captureEvents() -> AsyncStream<CaptureEvent> { captures.stream() }
```

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1 | grep -E "Executed|error:|failed"`
Expected: `Executed 22 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SonyCameraKit/CapturedImage.swift Sources/SonyCameraKit/CameraBackend.swift Sources/SonyCameraKit/USB/SonyUSBBackend.swift Sources/SonyCameraKit/WiFiBackend.swift Tests/SonyCameraKitTests/CaptureTests.swift
git commit -m "Capture pipeline types: CapturedImage, CaptureEvent stream, dated file store"
```

---

### Task 2: USB — drain every queued object, whoever pressed the shutter

**Files:**
- Create: `Sources/SonyCameraKit/USB/CaptureDownloader.swift`
- Modify: `Sources/SonyCameraKit/USB/SonyUSBBackend.swift` (`stateUpdates` loop, `takePicture`, `downloadCapturedImages`)
- Test: `Tests/SonyCameraKitTests/CaptureDownloaderTests.swift`

**Interfaces:**
- Consumes: `CaptureStore.write`, `CapturedImage.kind`, `captures` (Task 1); `PTPReader.skip/u16/string`, `SonyProp.objectInMemory`, `SonyProp.capturedImageHandle`, `PTP.Response.invalidObjectHandle/accessDenied` (existing).
- Produces: `CaptureDownloader { pending, fetchNext, pollInterval, timeout, maxObjects; run() -> [Object]; static parseObjectInfo }`, `CaptureDownloader.QueueEmpty`, `SonyUSBBackend.pendingCount(_ raw: Int64?) -> Int`.

Protocol facts: Sony property `0xD215` (ObjectInMemory) reads `0x8000 + n` while `n` objects wait behind handle `0xFFFFC001`; each `GetObject` pops one; idle values are below `0x8000`. If a body reports exactly `0x8000` while ready, the drain fetches once and stops on `InvalidObjectHandle`. The state loop already reads all properties every 250 ms, so the watcher costs no extra USB traffic.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SonyCameraKitTests/CaptureDownloaderTests.swift
import XCTest
@testable import SonyCameraKit

final class CaptureDownloaderTests: XCTestCase {
    /// PTP ObjectInfo: 52 bytes of fixed fields (ObjectFormat at byte 4) then a PTP string (u8 count incl. terminator, UTF-16LE).
    private func objectInfo(format: UInt16, name: String) -> Data {
        var d = Data(repeating: 0, count: 52)
        d[4] = UInt8(format & 0xFF); d[5] = UInt8(format >> 8)
        let units = Array(name.utf16) + [0]
        d.append(UInt8(units.count))
        for u in units { d.append(le16: u) }
        return d
    }

    func testParsesFormatAndFilename() {
        let (f, n) = CaptureDownloader.parseObjectInfo(objectInfo(format: 0xB101, name: "DSC00042.ARW"))
        XCTAssertEqual(f, 0xB101); XCTAssertEqual(n, "DSC00042.ARW")
        XCTAssertEqual(CaptureDownloader.parseObjectInfo(Data([1, 2, 3])).filename, "")
    }

    func testPendingCountFromObjectInMemory() {
        XCTAssertEqual(SonyUSBBackend.pendingCount(nil), 0)
        XCTAssertEqual(SonyUSBBackend.pendingCount(1), 0)
        XCTAssertEqual(SonyUSBBackend.pendingCount(0x8000), 1)
        XCTAssertEqual(SonyUSBBackend.pendingCount(0x8002), 2)
    }

    func testDrainsRawPlusJpegAfterWaiting() async throws {
        let counts = Counter([0, 0, 2, 1, 0])
        let queue = Counter([(0x3801, "DSC00001.JPG", Data([0xFF, 0xD8])), (0xB101, "DSC00001.ARW", Data([0x49, 0x49]))])
        let dl = CaptureDownloader(
            pending: { counts.next() ?? 0 },
            fetchNext: {
                guard let (f, n, d) = queue.next() else { throw CaptureDownloader.QueueEmpty() }
                return (self.objectInfo(format: UInt16(f), name: n), d)
            },
            pollInterval: .milliseconds(1), timeout: .seconds(1))
        let out = try await dl.run()
        XCTAssertEqual(out.map(\.filename), ["DSC00001.JPG", "DSC00001.ARW"])
        XCTAssertEqual(out.map(\.format), [0x3801, 0xB101])
        XCTAssertEqual(out[1].data, Data([0x49, 0x49]))
    }

    func testGivesUpWhenNothingArrives() async throws {
        let dl = CaptureDownloader(pending: { 0 }, fetchNext: { throw CaptureDownloader.QueueEmpty() },
                                   pollInterval: .milliseconds(1), timeout: .milliseconds(20))
        let out = try await dl.run()
        XCTAssertTrue(out.isEmpty)
    }

    func testStopsOnQueueEmptyEvenIfCountStaysHigh() async throws {
        let queue = Counter([(0x3801, "A.JPG", Data([1]))])
        let dl = CaptureDownloader(
            pending: { 1 },
            fetchNext: {
                guard let (f, n, d) = queue.next() else { throw CaptureDownloader.QueueEmpty() }
                return (self.objectInfo(format: UInt16(f), name: n), d)
            },
            pollInterval: .milliseconds(1), timeout: .milliseconds(20))
        let out = try await dl.run()
        XCTAssertEqual(out.map(\.filename), ["A.JPG"])
    }
}

/// Thread-safe sequence for closure-driven fakes.
final class Counter<T>: @unchecked Sendable {
    private var items: [T]; private let lock = NSLock()
    init(_ items: [T]) { self.items = items }
    func next() -> T? { lock.lock(); defer { lock.unlock() }; return items.isEmpty ? nil : items.removeFirst() }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CaptureDownloaderTests 2>&1 | grep -E "error:|Executed" | head`
Expected: `cannot find 'CaptureDownloader' in scope`.

- [ ] **Step 3: Write the downloader**

```swift
// Sources/SonyCameraKit/USB/CaptureDownloader.swift
import Foundation

/// Pulls every object the camera queued after a shot. Transport-agnostic so it is testable with closures.
struct CaptureDownloader {
    struct QueueEmpty: Error {}
    struct Object: Equatable { var format: UInt16; var filename: String; var data: Data }

    /// Number of objects waiting in the camera (0 when none). On hardware this reads Sony property 0xD215.
    var pending: @Sendable () async throws -> Int
    /// Fetches and pops the next queued object: (ObjectInfo dataset, object bytes). Throws `QueueEmpty` when the
    /// camera answers InvalidObjectHandle / AccessDenied.
    var fetchNext: @Sendable () async throws -> (info: Data, object: Data)
    var pollInterval: Duration = .milliseconds(200)
    var timeout: Duration = .seconds(15)
    var maxObjects = 4

    /// Waits up to `timeout` for the first object, then drains the queue. Empty if nothing arrived in time.
    func run() async throws -> [Object] {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var count = try await pending()
        while count == 0, clock.now < deadline {
            try await Task.sleep(for: pollInterval)
            count = try await pending()
        }
        var out: [Object] = []
        while count > 0, out.count < maxObjects {
            let info: Data, data: Data
            do { (info, data) = try await fetchNext() } catch is QueueEmpty { break }
            let (format, name) = Self.parseObjectInfo(info)
            let fallback = "capture-\(Int(Date().timeIntervalSince1970))-\(out.count + 1)" + (format == 0x3801 ? ".JPG" : ".ARW")
            out.append(Object(format: format, filename: name.isEmpty ? fallback : name, data: data))
            count = try await pending()
        }
        return out
    }

    /// PTP ObjectInfo dataset: StorageID u32, ObjectFormat u16 (byte 4), ProtectionStatus u16, ObjectCompressedSize u32,
    /// ThumbFormat u16, ThumbCompressedSize u32, ThumbPixWidth u32, ThumbPixHeight u32, ImagePixWidth u32,
    /// ImagePixHeight u32, ImageBitDepth u32, ParentObject u32, AssociationType u16, AssociationDesc u32,
    /// SequenceNumber u32 — 52 bytes — then Filename as a PTP string.
    static func parseObjectInfo(_ data: Data) -> (format: UInt16, filename: String) {
        var rd = PTPReader(data)
        guard (try? rd.skip(4)) != nil, let format = try? rd.u16() else { return (0, "") }
        guard (try? rd.skip(46)) != nil, let name = try? rd.string() else { return (format, "") }
        return (format, name)
    }
}
```

- [ ] **Step 4: Wire the watcher into the USB backend**

Add after `private var recording = false` in `SonyUSBBackend`:

```swift
    // Capture transfer. The state loop watches 0xD215 on every poll, so shots fired on the body transfer too.
    private let captureLock = NSLock()
    private var shotCounter = 0
    private var draining = false
    private var lastEmptyDrainValue: Int64?
    private var awaitingShot: Task<Void, Never>?
```

In `stateUpdates()`, right after `var s = try await refreshState()` add:

```swift
                        checkForCapturedObjects()
```

Replace `takePicture()` and `downloadCapturedImages()` with:

```swift
    public func takePicture() async throws {
        try await controlB(SonyProp.autoFocusButton, 2, type: .uint16)
        // wait briefly for focus confirmation
        for _ in 0 ..< 15 {
            try await Task.sleep(for: .milliseconds(100))
            try? await refreshState()
            if let f = prop(SonyProp.focusFound)?.current, f == 2 || f == 3 { break }
        }
        try await controlB(SonyProp.captureButton, 2, type: .uint16)
        try await Task.sleep(for: .milliseconds(80))
        try await controlB(SonyProp.captureButton, 1, type: .uint16)
        try await controlB(SonyProp.autoFocusButton, 1, type: .uint16)
        // The watcher picks the files up; if nothing shows up the camera is not saving to the PC.
        captureLock.withLock {
            awaitingShot?.cancel()
            awaitingShot = Task { [captures] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                captures.send(.failed(shotIndex: -1, message: "No file received. On the camera set Still Img. Save Dest. to PC or PC+Camera."))
            }
        }
    }

    /// 0xD215 reads 0x8000 + n while n captured objects wait behind handle 0xFFFFC001; below 0x8000 = nothing.
    static func pendingCount(_ raw: Int64?) -> Int {
        guard let v = raw, v >= 0x8000 else { return 0 }
        return max(1, Int(v - 0x8000))
    }

    private func pendingObjectCount() async throws -> Int {
        try await refreshState()
        return Self.pendingCount(prop(SonyProp.objectInMemory)?.current)
    }

    /// Called on every state poll. Any queued object, whoever pressed the shutter, starts a drain.
    private func checkForCapturedObjects() {
        let raw = prop(SonyProp.objectInMemory)?.current
        guard Self.pendingCount(raw) > 0 else { return }
        let shot: Int? = captureLock.withLock {
            guard !draining, raw != lastEmptyDrainValue else { return nil }
            draining = true
            shotCounter += 1
            awaitingShot?.cancel(); awaitingShot = nil
            return shotCounter
        }
        guard let shot else { return }
        Task {
            await self.downloadCapturedImages(shot: shot, raw: raw)
            self.captureLock.withLock { self.draining = false }
        }
    }

    /// When the camera is set to save stills to the PC (Still Img. Save Dest. = PC / PC+Camera), the JPEG and
    /// the RAW wait in memory until fetched. Each one is written to disk and announced as it lands.
    private func downloadCapturedImages(shot: Int, raw: Int64?) async {
        guard let dev = device else { return }
        let downloader = CaptureDownloader(
            pending: { [weak self] in try await self?.pendingObjectCount() ?? 0 },
            fetchNext: {
                do {
                    let info = try await dev.transaction(PTP.Op.getObjectInfo, params: [SonyProp.capturedImageHandle])
                    let obj = try await dev.transaction(PTP.Op.getObject, params: [SonyProp.capturedImageHandle], timeout: 60)
                    return (info.data, obj.data)
                } catch let e as PTPError where e.code == PTP.Response.invalidObjectHandle || e.code == PTP.Response.accessDenied {
                    throw CaptureDownloader.QueueEmpty()
                }
            },
            timeout: .seconds(2))
        do {
            let objects = try await downloader.run()
            guard !objects.isEmpty else {
                // Stale flag: do not hammer the camera until the value changes.
                captureLock.withLock { lastEmptyDrainValue = raw }
                return
            }
            let now = Date()
            for o in objects {
                let url = try CaptureStore.write(o.data, base: saveDirectory, filename: o.filename, date: now)
                captures.send(.image(CapturedImage(url: url, kind: CapturedImage.kind(objectFormat: o.format, filename: o.filename),
                                                   filename: o.filename, takenAt: now, shotIndex: shot)))
            }
            captures.send(.finished(shotIndex: shot))
        } catch {
            captures.send(.failed(shotIndex: shot, message: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
        }
    }
```

- [ ] **Step 5: Build and run all tests**

Run: `swift build 2>&1 | grep -E "error" ; swift test 2>&1 | grep -E "Executed|error:|failed"`
Expected: no errors; `Executed 27 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SonyCameraKit/USB/CaptureDownloader.swift Sources/SonyCameraKit/USB/SonyUSBBackend.swift Tests/SonyCameraKitTests/CaptureDownloaderTests.swift
git commit -m "USB: watch ObjectInMemory on every poll and drain JPEG + RAW for app- and body-triggered shots"
```

---

### Task 3: Wi-Fi — original-size postview, event-driven download, simulator support

**Files:**
- Modify: `Sources/SonyCameraKit/SonyCameraClient.swift` (add two methods next to `actTakePicture`)
- Modify: `Sources/SonyCameraKit/WiFiBackend.swift` (`connect`, `stateUpdates`, `takePicture`)
- Modify: `tools/camerasim.py` (APIS list, `do_GET`, `dispatch`)
- Test: `Tests/SonyCameraKitTests/CaptureTests.swift` (add one test)

**Interfaces:**
- Consumes: `CaptureStore.write`, `captures`, `saveDirectory` (Task 1); `CameraState.lastPictureURLs` (existing).
- Produces: `SonyCameraClient.setPostviewImageSize(_:)`, `SonyCameraClient.awaitTakePicture() -> [String]`, `WiFiBackend.postviewFilename(for:shot:) -> String`.

- [ ] **Step 1: Write the failing test** (append to `CaptureTests`)

```swift
    func testPostviewFilenameFromURL() {
        XCTAssertEqual(WiFiBackend.postviewFilename(for: URL(string: "http://192.168.122.1:8080/postview/pict20260915_120301.JPG?x=1")!, shot: 3), "pict20260915_120301.JPG")
        XCTAssertEqual(WiFiBackend.postviewFilename(for: URL(string: "http://192.168.122.1:8080/")!, shot: 3), "capture-3.jpg")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CaptureTests 2>&1 | grep -E "error:" | head -3`
Expected: `type 'WiFiBackend' has no member 'postviewFilename'`.

- [ ] **Step 3: Client methods**

In `SonyCameraClient.swift`, after `public func actTakePicture()`:

```swift
    /// "Original" makes the postview the full-size JPEG instead of a 2M proxy.
    public func setPostviewImageSize(_ size: String) async throws { try await call("setPostviewImageSize", [.string(size)]) }
    /// Polled after `actTakePicture` answers 40403 (still capturing); returns the postview URLs once ready.
    public func awaitTakePicture() async throws -> [String] { try await call("awaitTakePicture")[0].stringArray }
```

- [ ] **Step 4: Backend**

In `WiFiBackend.connect()`, after `eventVersion = await client.bestEventVersion()`:

```swift
        if apis.contains("setPostviewImageSize") { try? await client.setPostviewImageSize("Original") }
```

In `stateUpdates()`, replace `let s = stateBox.update { $0.apply(event: ev) }` + `cont.yield(s)` with:

```swift
                        let s = stateBox.update { $0.apply(event: ev) }
                        cont.yield(s)
                        // Shots fired on the body show up here as takePictureUrl; app shots too, deduplicated below.
                        let fresh = s.lastPictureURLs.compactMap { URL(string: $0) }
                        if !fresh.isEmpty { Task { await self.download(fresh, shot: nil) } }
```

Replace `public func takePicture() async throws { _ = try await client.actTakePicture() }` with:

```swift
    private let captureLock = NSLock()
    private var shotCounter = 0
    private var claimed: Set<URL> = []

    public func takePicture() async throws {
        var urls: [String]
        do {
            urls = try await client.actTakePicture()
        } catch let e as SonyAPIError where e.code == 40403 {
            urls = []
            for _ in 0 ..< 30 {
                try await Task.sleep(for: .milliseconds(500))
                if let u = try? await client.awaitTakePicture(), !u.isEmpty { urls = u; break }
            }
        }
        let list = urls.compactMap { URL(string: $0) }
        guard !list.isEmpty else { throw SonyAPIError(code: -1, message: "camera returned no postview image", method: "actTakePicture") }
        Task { await self.download(list, shot: nil) }
    }

    static func postviewFilename(for url: URL, shot: Int) -> String {
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? "capture-\(shot).jpg" : name
    }

    /// Claims URLs not seen before and assigns them one shot index. Returns nil when everything was already handled.
    private func claim(_ urls: [URL]) -> (shot: Int, urls: [URL])? {
        captureLock.withLock {
            let fresh = urls.filter { !claimed.contains($0) }
            guard !fresh.isEmpty else { return nil }
            claimed.formUnion(fresh)
            shotCounter += 1
            return (shotCounter, fresh)
        }
    }

    /// The Camera Remote API only ever hands over the JPEG during remote shooting; RAW stays on the card.
    private func download(_ urls: [URL], shot: Int?) async {
        guard let (index, fresh) = claim(urls) else { return }
        let now = Date()
        for u in fresh {
            do {
                let (data, _) = try await URLSession.shared.data(from: u)
                let name = Self.postviewFilename(for: u, shot: index)
                let file = try CaptureStore.write(data, base: saveDirectory, filename: name, date: now)
                captures.send(.image(CapturedImage(url: file, kind: .jpeg, filename: name, takenAt: now, shotIndex: index)))
            } catch {
                captures.send(.failed(shotIndex: index, message: "Postview download failed: \(error.localizedDescription)"))
                return
            }
        }
        captures.send(.finished(shotIndex: index))
    }
```

(The `shot:` parameter is kept nil everywhere; the claim assigns indices so both paths agree.)

- [ ] **Step 5: Simulator**

Read `sed -n 97,118p tools/camerasim.py` to see whether `render_frame` returns JPEG bytes or a PIL image. In `tools/camerasim.py` add `"setPostviewImageSize","awaitTakePicture"` to the `APIS` list. In `do_GET`, before the final `else:` add (adapt the `body = …` line to what `render_frame` returns: use it directly if it is already JPEG bytes, otherwise `.save` it into a `BytesIO` as JPEG quality 90):

```python
        elif self.path.startswith("/postview/"):
            body = render_frame(time.time(), 3000, 2000)
            self.send_response(200); self.send_header("Content-Type", "image/jpeg"); self.send_header("Content-Length", str(len(body))); self.end_headers()
            self.wfile.write(body)
```

In `dispatch`, after the `actTakePicture` branch add:

```python
        if m == "setPostviewImageSize": self.check(p[0], ["Original", "2M"]); return [0]
        if m == "awaitTakePicture": return [CAM.last_pictures]
```

- [ ] **Step 6: Run tests and the simulator**

Run: `swift test 2>&1 | grep -E "Executed|error:|failed"` → `Executed 28 tests, with 0 failures`.
Run: `python3 tools/camerasim.py & sleep 1; curl -s -o /tmp/pv.jpg -w "%{http_code} %{size_download}\n" http://127.0.0.1:8080/postview/1.jpg; kill %1`
Expected: `200` and a size above 100000.

- [ ] **Step 7: Commit**

```bash
git add Sources/SonyCameraKit/SonyCameraClient.swift Sources/SonyCameraKit/WiFiBackend.swift tools/camerasim.py Tests/SonyCameraKitTests/CaptureTests.swift
git commit -m "Wi-Fi: original-size postview saved for app- and body-triggered shots; simulator serves postviews"
```

---

### Task 4: Shot log in the session (grouping JPEG + RAW, auto review)

**Files:**
- Create: `Sources/SonyCameraKit/CapturedShot.swift`
- Modify: `Sources/SonyCameraKit/CameraSession.swift` (properties after `busy`; `connect`/`disconnect`; loops; `autofocus`/`takePicture`; `touchAF`)
- Test: `Tests/SonyCameraKitTests/ShotLogTests.swift`

**Interfaces:**
- Consumes: `CaptureEvent`, `CapturedImage` (Task 1), `CameraState` (existing).
- Produces: `ExposureSnapshot { shutterSpeed, fNumber, iso, ev, focusMode; summary }`, `CapturedShot { id, jpeg, raw, takenAt, exposure, afPoint: CGPoint?, transferring, error; primary, hasBoth }`, `ShotLog { shots; apply(_:exposure:afPoint:) -> Change; shot(_:); neighbor(of:offset:) }`, session members `captures: [CapturedShot]`, `reviewShot: CapturedShot?` (settable), `focusCheckPoint: CGPoint?` (settable), `review(_:)`, `reviewNeighbor(_:)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SonyCameraKitTests/ShotLogTests.swift
import XCTest
@testable import SonyCameraKit

final class ShotLogTests: XCTestCase {
    private func img(_ shot: Int, _ kind: CapturedImage.Kind) -> CapturedImage {
        CapturedImage(url: URL(fileURLWithPath: "/tmp/\(shot).\(kind == .jpeg ? "JPG" : "ARW")"), kind: kind,
                      filename: "DSC\(shot).\(kind == .jpeg ? "JPG" : "ARW")", takenAt: Date(timeIntervalSince1970: 100), shotIndex: shot)
    }
    private var exposure: ExposureSnapshot {
        var s = CameraState(); s.shutterSpeed = "1/250"; s.fNumber = "2.8"; s.iso = "400"
        return ExposureSnapshot(state: s)
    }

    func testGroupsJpegAndRawOfTheSameShot() {
        var log = ShotLog()
        let first = log.apply(.image(img(1, .jpeg)), exposure: exposure, afPoint: CGPoint(x: 0.3, y: 0.6))
        guard case .newShot(let shot) = first else { return XCTFail("expected newShot, got \(first)") }
        XCTAssertEqual(shot.id, 1); XCTAssertNotNil(shot.jpeg); XCTAssertNil(shot.raw); XCTAssertTrue(shot.transferring)
        XCTAssertEqual(shot.afPoint, CGPoint(x: 0.3, y: 0.6))
        XCTAssertEqual(shot.exposure.summary, "1/250   F2.8   ISO 400")

        let second = log.apply(.image(img(1, .raw)), exposure: exposure, afPoint: nil)
        guard case .updated(let both) = second else { return XCTFail("expected updated") }
        XCTAssertTrue(both.hasBoth); XCTAssertEqual(log.shots.count, 1)

        let done = log.apply(.finished(shotIndex: 1), exposure: exposure, afPoint: nil)
        guard case .updated(let finished) = done else { return XCTFail("expected updated") }
        XCTAssertFalse(finished.transferring)
    }

    func testFailureMarksShotOrIsIgnoredWhenNothingArrived() {
        var log = ShotLog()
        XCTAssertEqual(log.apply(.failed(shotIndex: 9, message: "nope"), exposure: exposure, afPoint: nil), .none)
        _ = log.apply(.image(img(2, .raw)), exposure: exposure, afPoint: nil)
        let r = log.apply(.failed(shotIndex: 2, message: "cable"), exposure: exposure, afPoint: nil)
        guard case .updated(let s) = r else { return XCTFail("expected updated") }
        XCTAssertEqual(s.error, "cable"); XCTAssertFalse(s.transferring); XCTAssertEqual(s.primary?.kind, .raw)
    }

    func testNeighborNavigation() {
        var log = ShotLog()
        for i in 1 ... 3 { _ = log.apply(.image(img(i, .jpeg)), exposure: exposure, afPoint: nil) }
        XCTAssertEqual(log.neighbor(of: 2, offset: -1)?.id, 1)
        XCTAssertEqual(log.neighbor(of: 2, offset: 1)?.id, 3)
        XCTAssertNil(log.neighbor(of: 3, offset: 1))
        XCTAssertNil(log.neighbor(of: 42, offset: 1))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ShotLogTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'ShotLog' in scope`.

- [ ] **Step 3: Write the types**

```swift
// Sources/SonyCameraKit/CapturedShot.swift
import Foundation
import CoreGraphics

/// Exposure as it was when the file arrived (within a second or two of the shutter), for the review header.
public struct ExposureSnapshot: Sendable, Equatable {
    public var shutterSpeed: String?
    public var fNumber: String?
    public var iso: String?
    public var ev: String?
    public var focusMode: String?

    public init(state: CameraState) {
        shutterSpeed = state.shutterSpeed; fNumber = state.fNumber; iso = state.iso
        ev = state.exposureCompensation.flatMap { $0.index == 0 ? nil : $0.label }
        focusMode = state.focusMode
    }

    public var summary: String {
        [shutterSpeed, fNumber.map { "F" + $0 }, iso.map { "ISO " + $0 }, ev.map { "EV " + $0 }].compactMap { $0 }.joined(separator: "   ")
    }
}

/// One press of the shutter: up to one JPEG and one RAW.
public struct CapturedShot: Sendable, Equatable, Identifiable {
    public let id: Int
    public var jpeg: CapturedImage?
    public var raw: CapturedImage?
    public var takenAt: Date
    public var exposure: ExposureSnapshot
    /// AF point as fractions (0…1, top-left origin) of the frame; nil = wide area, treated as the centre.
    public var afPoint: CGPoint?
    public var transferring = true
    public var error: String?

    public init(id: Int, takenAt: Date, exposure: ExposureSnapshot, afPoint: CGPoint?) {
        self.id = id; self.takenAt = takenAt; self.exposure = exposure; self.afPoint = afPoint
    }

    public var primary: CapturedImage? { jpeg ?? raw }
    public var hasBoth: Bool { jpeg != nil && raw != nil }
}

/// This session's shots, oldest first. Groups the files of a shot by `shotIndex`.
public struct ShotLog: Sendable, Equatable {
    public private(set) var shots: [CapturedShot] = []
    public init() {}

    public enum Change: Equatable { case newShot(CapturedShot), updated(CapturedShot), none }

    public mutating func apply(_ event: CaptureEvent, exposure: ExposureSnapshot, afPoint: CGPoint?) -> Change {
        switch event {
        case .image(let img):
            if let i = shots.firstIndex(where: { $0.id == img.shotIndex }) {
                if img.kind == .jpeg { shots[i].jpeg = img } else { shots[i].raw = img }
                return .updated(shots[i])
            }
            var s = CapturedShot(id: img.shotIndex, takenAt: img.takenAt, exposure: exposure, afPoint: afPoint)
            if img.kind == .jpeg { s.jpeg = img } else { s.raw = img }
            shots.append(s)
            return .newShot(s)
        case .finished(let idx):
            guard let i = shots.firstIndex(where: { $0.id == idx }) else { return .none }
            shots[i].transferring = false
            return .updated(shots[i])
        case .failed(let idx, let message):
            guard let i = shots.firstIndex(where: { $0.id == idx }) else { return .none }
            shots[i].transferring = false
            shots[i].error = message
            return .updated(shots[i])
        }
    }

    public func shot(_ id: Int) -> CapturedShot? { shots.first { $0.id == id } }

    public func neighbor(of id: Int, offset: Int) -> CapturedShot? {
        guard let i = shots.firstIndex(where: { $0.id == id }) else { return nil }
        let j = i + offset
        return shots.indices.contains(j) ? shots[j] : nil
    }
}
```

- [ ] **Step 4: Run the log tests**

Run: `swift test --filter ShotLogTests 2>&1 | grep -E "Executed|error:|failed"`
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Session wiring**

In `CameraSession.swift` add after `public private(set) var busy = false`:

```swift
    /// Shots taken this session, oldest first. Files stay on disk; the list resets on the next launch.
    public private(set) var shotLog = ShotLog()
    public var captures: [CapturedShot] { shotLog.shots }
    /// The shot being reviewed full-screen (photo mode). nil = live view.
    public var reviewShot: CapturedShot?
    /// Where the user last clicked to check focus (fractions of the frame), used when the transport has no touch AF.
    public var focusCheckPoint: CGPoint?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
```

In `connect(_ backend:)`, after `startLiveview()` add `startCaptureLoop()`. In `disconnect()`, after `liveviewTask?.cancel(); liveviewTask = nil` add:

```swift
        captureTask?.cancel(); captureTask = nil
        reviewShot = nil
```

Add to the `// MARK: Loops` section:

```swift
    private func startCaptureLoop() {
        guard let backend else { return }
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            for await event in backend.captureEvents() {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: CaptureEvent) {
        let af = focusCheckPoint ?? state.touchAFPoint.map { CGPoint(x: $0.x / 100, y: $0.y / 100) }
        switch shotLog.apply(event, exposure: ExposureSnapshot(state: state), afPoint: af) {
        case .newShot(let shot):
            reviewShot = shot           // auto review, like the body's own display
        case .updated(let shot):
            if reviewShot?.id == shot.id { reviewShot = shot }
            if let e = shot.error { lastError = e }
        case .none:
            if case .failed(_, let message) = event { lastError = message }
        }
    }
```

Replace `autofocus()` and `takePicture()`:

```swift
    public func autofocus() async {
        reviewShot = nil
        await perform("AF") { try await $0.autofocus() }
    }
    public func takePicture() async {
        reviewShot = nil
        await perform("Shoot") { try await $0.takePicture() }
    }
    public func review(_ shot: CapturedShot?) { reviewShot = shot }
    /// Step to the previous (-1) or next (+1) shot while reviewing.
    public func reviewNeighbor(_ offset: Int) {
        guard let current = reviewShot, let n = shotLog.neighbor(of: current.id, offset: offset) else { return }
        reviewShot = n
    }
```

In `touchAF(x:y:)`, add as the first line: `focusCheckPoint = CGPoint(x: x, y: y)`.

- [ ] **Step 6: Build and run all tests**

Run: `swift build 2>&1 | grep -E "error" ; swift test 2>&1 | grep -E "Executed|error:|failed"`
Expected: no errors; `Executed 31 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Sources/SonyCameraKit/CapturedShot.swift Sources/SonyCameraKit/CameraSession.swift Tests/SonyCameraKitTests/ShotLogTests.swift
git commit -m "Session: shot log grouping JPEG+RAW per shot, auto-review of the latest capture"
```

---

### Task 5: FocusAnalyzer — sharpness score, map and verdict

**Files:**
- Create: `Sources/SonyCameraKit/FocusAnalyzer.swift`
- Test: `Tests/SonyCameraKitTests/FocusAnalyzerTests.swift`

**Interfaces:**
- Produces: `FocusVerdict { inFocus, soft, missed; rawValue "IN FOCUS"/"SOFT"/"MISSED" }`, `FocusReport { regionScore, peakScore, ratio, verdict, peakPoint: CGPoint, tiles }`, `FocusAnalyzer.Luma`, `FocusAnalyzer.luma(of:maxLongEdge:)`, `FocusAnalyzer.sharpness(_:in:)`, `FocusAnalyzer.sharpnessMap(_:tiles:)`, `FocusAnalyzer.regionRect(around:fraction:aspect:)`, `FocusAnalyzer.analyze(_:afPoint:regionFraction:tiles:maxLongEdge:) -> FocusReport?`, `FocusAnalyzer.liveRatio(_:afPoint:) -> Double`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SonyCameraKitTests/FocusAnalyzerTests.swift
import XCTest
import CoreGraphics
@testable import SonyCameraKit

final class FocusAnalyzerTests: XCTestCase {
    /// 400×300: left half is a 6-px checkerboard (sharp), right half is flat grey (no detail).
    private func testImage() -> CGImage {
        let w = 400, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        for y in stride(from: 0, to: h, by: 6) {
            for x in stride(from: 0, to: w / 2, by: 6) where ((x / 6) + (y / 6)) % 2 == 0 {
                ctx.fill(CGRect(x: x, y: y, width: 6, height: 6))
            }
        }
        return ctx.makeImage()!
    }

    func testSharpRegionScoresFarAboveFlatRegion() throws {
        let l = try XCTUnwrap(FocusAnalyzer.luma(of: testImage(), maxLongEdge: 400))
        let sharp = FocusAnalyzer.sharpness(l, in: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.6))
        let flat = FocusAnalyzer.sharpness(l, in: CGRect(x: 0.6, y: 0.2, width: 0.3, height: 0.6))
        XCTAssertGreaterThan(sharp, 100)
        XCTAssertLessThan(flat, 1)
    }

    func testVerdictThresholds() {
        XCTAssertEqual(FocusAnalyzer.verdict(region: 90, peak: 100), .inFocus)
        XCTAssertEqual(FocusAnalyzer.verdict(region: 50, peak: 100), .soft)
        XCTAssertEqual(FocusAnalyzer.verdict(region: 10, peak: 100), .missed)
        XCTAssertEqual(FocusAnalyzer.verdict(region: 0, peak: 0), .missed)
    }

    func testAnalyzeFindsFocusOnTheLeftAndMissOnTheRight() throws {
        let img = testImage()
        let hit = try XCTUnwrap(FocusAnalyzer.analyze(img, afPoint: CGPoint(x: 0.25, y: 0.5)))
        XCTAssertEqual(hit.verdict, .inFocus)
        XCTAssertLessThan(hit.peakPoint.x, 0.5)
        let miss = try XCTUnwrap(FocusAnalyzer.analyze(img, afPoint: CGPoint(x: 0.8, y: 0.5)))
        XCTAssertEqual(miss.verdict, .missed)
        XCTAssertLessThan(miss.ratio, 0.05)
        XCTAssertLessThan(miss.peakPoint.x, 0.5)   // tells the user where focus actually landed
    }

    func testLumaRespectsTopLeftOrigin() throws {
        // Dark top row, light elsewhere: row 0 of the luma plane must be the dark one.
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 7, width: 8, height: 1))   // CG y-up: top row
        let l = try XCTUnwrap(FocusAnalyzer.luma(of: ctx.makeImage()!, maxLongEdge: 8))
        XCTAssertLessThan(l.pixels[0], 10)
        XCTAssertGreaterThan(l.pixels[7 * 8], 240)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter FocusAnalyzerTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'FocusAnalyzer' in scope`.

- [ ] **Step 3: Write the analyzer**

```swift
// Sources/SonyCameraKit/FocusAnalyzer.swift
import Foundation
import CoreGraphics

public enum FocusVerdict: String, Sendable { case inFocus = "IN FOCUS", soft = "SOFT", missed = "MISSED" }

public struct FocusReport: Sendable, Equatable {
    public var regionScore: Double
    public var peakScore: Double
    public var verdict: FocusVerdict
    /// Centre of the sharpest tile, as fractions of the image (top-left origin).
    public var peakPoint: CGPoint
    public var tiles: Int
    public var ratio: Double { peakScore > 0 ? min(1, regionScore / peakScore) : 0 }
}

/// Laplacian-variance sharpness. Pure functions; safe to call off the main thread.
public enum FocusAnalyzer {
    public static let inFocusRatio = 0.70
    public static let softRatio = 0.35

    public static func verdict(region: Double, peak: Double) -> FocusVerdict {
        guard peak > 0 else { return .missed }
        let r = region / peak
        return r >= inFocusRatio ? .inFocus : (r >= softRatio ? .soft : .missed)
    }

    /// 8-bit luma plane, row 0 at the top, long edge at most `maxLongEdge` pixels.
    public struct Luma: Sendable {
        public var pixels: [UInt8]
        public var width: Int
        public var height: Int
    }

    public static func luma(of image: CGImage, maxLongEdge: Int) -> Luma? {
        let scale = min(1, Double(maxLongEdge) / Double(max(image.width, image.height)))
        let w = max(8, Int(Double(image.width) * scale)), h = max(8, Int(Double(image.height) * scale))
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            // Core Graphics draws y-up; flip so pixel row 0 is the top of the picture.
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Luma(pixels: px, width: w, height: h) : nil
    }

    /// Variance of the 3×3 Laplacian inside `rect` (fractions of the plane, top-left origin).
    public static func sharpness(_ l: Luma, in rect: CGRect) -> Double {
        let x0 = max(1, Int(rect.minX * CGFloat(l.width))), x1 = min(l.width - 1, Int(rect.maxX * CGFloat(l.width)))
        let y0 = max(1, Int(rect.minY * CGFloat(l.height))), y1 = min(l.height - 1, Int(rect.maxY * CGFloat(l.height)))
        guard x1 - x0 > 2, y1 - y0 > 2 else { return 0 }
        var sum = 0.0, sumSq = 0.0
        let n = Double((x1 - x0) * (y1 - y0))
        l.pixels.withUnsafeBufferPointer { p in
            let w = l.width
            for y in y0 ..< y1 {
                let row = y * w
                for x in x0 ..< x1 {
                    let c = Int(p[row + x])
                    let lap = Double(4 * c - Int(p[row + x - 1]) - Int(p[row + x + 1]) - Int(p[row - w + x]) - Int(p[row + w + x]))
                    sum += lap; sumSq += lap * lap
                }
            }
        }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    public static func sharpnessMap(_ l: Luma, tiles: Int) -> [[Double]] {
        let t = CGFloat(tiles)
        return (0 ..< tiles).map { row in
            (0 ..< tiles).map { col in
                sharpness(l, in: CGRect(x: CGFloat(col) / t, y: CGFloat(row) / t, width: 1 / t, height: 1 / t))
            }
        }
    }

    /// Square region of `fraction` of the width, centred on `point`, clamped inside the frame.
    public static func regionRect(around point: CGPoint, fraction: CGFloat, aspect: CGFloat) -> CGRect {
        let w = fraction, h = fraction * aspect
        return CGRect(x: min(max(0, point.x - w / 2), 1 - w), y: min(max(0, point.y - h / 2), 1 - h), width: w, height: h)
    }

    /// Full report for a captured image. `afPoint` nil = centre.
    public static func analyze(_ image: CGImage, afPoint: CGPoint?, regionFraction: CGFloat = 0.12, tiles: Int = 12, maxLongEdge: Int = 2048) -> FocusReport? {
        guard let l = luma(of: image, maxLongEdge: maxLongEdge) else { return nil }
        let p = afPoint ?? CGPoint(x: 0.5, y: 0.5)
        let region = sharpness(l, in: regionRect(around: p, fraction: regionFraction, aspect: CGFloat(l.width) / CGFloat(l.height)))
        let map = sharpnessMap(l, tiles: tiles)
        var best = -1.0, bestRow = 0, bestCol = 0
        for r in 0 ..< tiles { for c in 0 ..< tiles where map[r][c] > best { best = map[r][c]; bestRow = r; bestCol = c } }
        // Peak = mean of the top 5 % of tiles, so one noisy tile does not set the bar; never below the region itself.
        let sorted = map.flatMap { $0 }.sorted(by: >)
        let top = max(1, sorted.count / 20)
        let peak = max(region, sorted.prefix(top).reduce(0, +) / Double(top))
        return FocusReport(regionScore: region, peakScore: peak, verdict: verdict(region: region, peak: peak),
                           peakPoint: CGPoint(x: (CGFloat(bestCol) + 0.5) / CGFloat(tiles), y: (CGFloat(bestRow) + 0.5) / CGFloat(tiles)),
                           tiles: tiles)
    }

    /// Cheap live-view meter: sharpness of the AF region relative to the frame's sharpest tiles, 0…1.
    public static func liveRatio(_ image: CGImage, afPoint: CGPoint?) -> Double {
        guard let r = analyze(image, afPoint: afPoint, regionFraction: 0.14, tiles: 8, maxLongEdge: 512) else { return 0 }
        return r.ratio
    }
}
```

- [ ] **Step 4: Run the analyzer tests**

Run: `swift test --filter FocusAnalyzerTests 2>&1 | grep -E "Executed|error:|failed|XCTAssert"`
Expected: `Executed 4 tests, with 0 failures`. If `testSharpRegionScoresFarAboveFlatRegion` fails on the `> 100` bound, print the value and lower the bound to 10; the flat side must stay below 1.

- [ ] **Step 5: Commit**

```bash
git add Sources/SonyCameraKit/FocusAnalyzer.swift Tests/SonyCameraKitTests/FocusAnalyzerTests.swift
git commit -m "FocusAnalyzer: Laplacian sharpness, tile map, in-focus / soft / missed verdict"
```

---

### Task 6: Shooting mode follows the dial; route to a plain PhotoView

**Files:**
- Create: `Sources/SonyCameraKit/ShootingMode.swift`
- Create: `Sources/CinemaHUD/PhotoView.swift`
- Modify: `Sources/CinemaHUD/CinemaHUDApp.swift` (Camera menu, `OverlaySettings`, `ContentView`, `DevHooks.apply`)
- Test: `Tests/SonyCameraKitTests/ShootingModeTests.swift`

**Interfaces:**
- Consumes: `CameraState.shootMode` ("still"/"movie"), `session.frame: CIImage?`, `session.frameSize`, `FrameProcessor.pipeline(...)`, `MetalFrameView(image:enhanced:sharpen:colorSpace:)`, `overlays.feedColorSpace`, `overlays.detail`, `session.touchAF(x:y:)`, `FocusAnalyzer.liveRatio`.
- Produces: `ShootingMode { video, photo }`, `ShootingModeResolver { mode, overridden; dial(_:), toggle() }`, `OverlaySettings.modeResolver`, `OverlaySettings.shootingMode`, `PhotoView` with `PhotoView.ImageLayout` and `photoLayout(in:)` reused by Task 7, `LiveSharpnessMeter`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SonyCameraKitTests/ShootingModeTests.swift
import XCTest
@testable import SonyCameraKit

final class ShootingModeTests: XCTestCase {
    func testFollowsTheDial() {
        var r = ShootingModeResolver()
        XCTAssertEqual(r.mode, .video)
        r.dial("still"); XCTAssertEqual(r.mode, .photo)
        r.dial("movie"); XCTAssertEqual(r.mode, .video)
        r.dial(nil); XCTAssertEqual(r.mode, .video)   // unknown keeps the last mode
    }

    func testOverrideHoldsUntilTheDialMoves() {
        var r = ShootingModeResolver()
        r.dial("movie")
        r.toggle(); XCTAssertEqual(r.mode, .photo); XCTAssertTrue(r.overridden)
        r.dial("movie"); XCTAssertEqual(r.mode, .photo)      // same dial position: override stays
        r.dial("still"); XCTAssertEqual(r.mode, .photo); XCTAssertFalse(r.overridden)
        r.dial("movie"); XCTAssertEqual(r.mode, .video)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ShootingModeTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'ShootingModeResolver' in scope`.

- [ ] **Step 3: Resolver**

```swift
// Sources/SonyCameraKit/ShootingMode.swift
import Foundation

public enum ShootingMode: String, Sendable, CaseIterable { case video = "VIDEO", photo = "PHOTO" }

/// The app's mode follows the camera's mode dial. A manual toggle overrides it until the dial next moves.
public struct ShootingModeResolver: Sendable, Equatable {
    public private(set) var mode: ShootingMode
    public private(set) var overridden = false
    private var lastDial: String?

    public init(mode: ShootingMode = .video) { self.mode = mode }

    public static func mode(forDial shootMode: String?) -> ShootingMode? {
        switch shootMode {
        case "still": return .photo
        case "movie": return .video
        default: return nil
        }
    }

    /// Feed every state update. The mode changes only when the dial position actually changes.
    public mutating func dial(_ shootMode: String?) {
        guard shootMode != lastDial else { return }
        lastDial = shootMode
        if let m = Self.mode(forDial: shootMode) { mode = m; overridden = false }
    }

    public mutating func toggle() {
        mode = mode == .video ? .photo : .video
        overridden = true
    }
}
```

- [ ] **Step 4: Run resolver tests**

Run: `swift test --filter ShootingModeTests 2>&1 | grep -E "Executed|error:|failed"`
Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: App wiring**

In `OverlaySettings` (CinemaHUDApp.swift) add after `var rotation = 0`:

```swift
    var modeResolver = ShootingModeResolver()
    var shootingMode: ShootingMode { modeResolver.mode }
    var reviewShowsRAW = false
```

In the `CommandMenu("Camera")` add after the `Disconnect` button:

```swift
                Divider()
                Button(overlays.shootingMode == .photo ? "Switch to Video Mode" : "Switch to Photo Mode") { overlays.modeResolver.toggle() }
                    .keyboardShortcut(.tab, modifiers: [])
```

In `ContentView.body`, replace `MonitorView()` with:

```swift
                if overlays.shootingMode == .photo { PhotoView() } else { MonitorView() }
```

and add after the `.onReceive(...)` modifier:

```swift
        .onChange(of: session.state.shootMode, initial: true) { _, dial in overlays.modeResolver.dial(dial) }
```

In `DevHooks.apply(to:)` add a case: `case "photo": overlays.modeResolver.toggle()` (forces photo mode for screenshots). In `ContentView`'s `CINEMAHUD_ACTION` switch add `case "shoot": await session.takePicture()`.

- [ ] **Step 6: PhotoView with the live picture only**

```swift
// Sources/CinemaHUD/PhotoView.swift
import SwiftUI
import CoreImage
import SonyCameraKit

/// Stills mode: the live view fills the window (MetalFX always on), Sony-style overlays on top,
/// and the real capture takes over for review after each shot.
struct PhotoView: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    @State private var processor = FrameProcessor()
    @State private var processed: CIImage?
    @State private var afFlash = false
    @State private var liveSharpness: Double = 0
    @State private var meter = LiveSharpnessMeter()

    var body: some View {
        ZStack {
            Color.black
            if let shot = session.reviewShot {
                ReviewView(shot: shot)
            } else {
                livePicture
            }
        }
        .onChange(of: session.frame, initial: true) { _, f in reprocess(f) }
        .onChange(of: overlays.peaking) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.feedColorSpace) { _, _ in reprocess(session.frame) }
    }

    struct ImageLayout {
        var rect: CGRect          // where the picture sits in the view
        var fullSize: CGSize      // size of the (possibly magnified) picture
        var cropX: CGFloat, cropY: CGFloat, cropWidth: CGFloat, cropHeight: CGFloat
    }

    /// Aspect-fit, no cinema crops; 2× magnify trims both axes around the centre.
    func photoLayout(in size: CGSize) -> ImageLayout {
        let w0 = session.frameSize.width, h0 = session.frameSize.height
        let aspect = (w0 > 0 && h0 > 0) ? w0 / h0 : 3.0 / 2.0
        let zoom: CGFloat = overlays.magnify ? 2 : 1
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        let rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        return ImageLayout(rect: rect, fullSize: CGSize(width: w * zoom, height: h * zoom),
                           cropX: (1 - 1 / zoom) / 2, cropY: (1 - 1 / zoom) / 2, cropWidth: 1 / zoom, cropHeight: 1 / zoom)
    }

    private var livePicture: some View {
        GeometryReader { geo in
            let layout = photoLayout(in: geo.size)
            let rect = layout.rect
            ZStack {
                if let img = processed {
                    MetalFrameView(image: img, enhanced: true, sharpen: overlays.detail ? 0.35 : 0, colorSpace: overlays.feedColorSpace.cgColorSpace)
                        .frame(width: layout.fullSize.width, height: layout.fullSize.height)
                        .position(x: rect.midX, y: rect.midY)
                        .clipShape(Rectangle().path(in: rect))
                } else {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.large)
                        Text("WAITING FOR LIVE VIEW").font(Theme.label(11)).tracking(3).foregroundStyle(Theme.dim)
                    }
                }
                Color.clear.contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    .onTapGesture { loc in
                        let x = layout.cropX + loc.x / rect.width * layout.cropWidth
                        let y = layout.cropY + loc.y / rect.height * layout.cropHeight
                        afFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { afFlash = false }
                        Task { await session.touchAF(x: x, y: y) }
                    }
                if !overlays.hideHUD {
                    PhotoHUD(layout: layout, liveSharpness: liveSharpness, afFlash: afFlash)
                }
            }
        }
    }

    /// Same lazy GPU chain as the monitor (colour tag + optional peaking), plus the live sharpness meter.
    private func reprocess(_ frame: CIImage?) {
        guard let frame else { processed = nil; return }
        let source = frame.matchedToWorkingSpace(from: overlays.feedColorSpace.cgColorSpace) ?? frame
        processed = processor.pipeline(source, peaking: overlays.peaking, zebra: false, zebraLevel: 1, falseColor: false, rotation: 0)
        let point = session.focusCheckPoint ?? session.state.touchAFPoint.map { CGPoint(x: $0.x / 100, y: $0.y / 100) }
        meter.measure(frame, afPoint: point) { r in liveSharpness = r }
    }
}

/// Renders the live frame small on the GPU and scores the AF region, at most a few times a second.
@MainActor
final class LiveSharpnessMeter {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var inFlight = false
    private var last = Date.distantPast

    func measure(_ frame: CIImage, afPoint: CGPoint?, done: @escaping @MainActor (Double) -> Void) {
        guard !inFlight, Date().timeIntervalSince(last) > 0.15 else { return }
        inFlight = true; last = Date()
        let ctx = context
        let scale = min(1, 512 / max(frame.extent.width, frame.extent.height))
        let small = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        Task.detached(priority: .utility) {
            let ratio = ctx.createCGImage(small, from: small.extent).map { FocusAnalyzer.liveRatio($0, afPoint: afPoint) } ?? 0
            await MainActor.run { self.inFlight = false; done(ratio) }
        }
    }
}
```

For this task only, so the target compiles before Tasks 7 and 8 exist, add temporary stand-ins at the bottom of `PhotoView.swift`; each is deleted by the task that replaces it:

```swift
// Replaced by Task 7 (PhotoHUD.swift) and Task 8 (ReviewView.swift).
struct PhotoHUD: View {
    let layout: PhotoView.ImageLayout
    let liveSharpness: Double
    let afFlash: Bool
    var body: some View { EmptyView() }
}
struct ReviewView: View {
    let shot: CapturedShot
    var body: some View { Text(shot.primary?.filename ?? "").foregroundStyle(.white) }
}
```

- [ ] **Step 7: Build, run all tests, and check the app switches modes against the simulator**

Run: `swift build 2>&1 | grep -E "error" ; swift test 2>&1 | grep -E "Executed|error:|failed"`
Expected: no errors; `Executed 33 tests, with 0 failures`.

Run (simulator, screenshot after 4 s):
```bash
python3 tools/camerasim.py & SIM=$!; sleep 1
CINEMAHUD_ADDRESS=127.0.0.1:8080 CINEMAHUD_OVERLAYS=photo CINEMAHUD_WINDOW=1400x900 CINEMAHUD_SNAPSHOT=/tmp/photo-plain.png .build/debug/CinemaHUD & APP=$!
sleep 7; kill $APP $SIM
```
Open `/tmp/photo-plain.png` (Read tool): the live picture fills the window with no strips or edge buttons.

- [ ] **Step 8: Commit**

```bash
git add Sources/SonyCameraKit/ShootingMode.swift Sources/CinemaHUD/PhotoView.swift Sources/CinemaHUD/CinemaHUDApp.swift Tests/SonyCameraKitTests/ShootingModeTests.swift
git commit -m "Photo mode follows the mode dial (Tab overrides); PhotoView shows the live picture"
```

---

### Task 7: PhotoHUD — Sony body display, focus indicator, sharpness meter, filmstrip

**Files:**
- Create: `Sources/CinemaHUD/PhotoHUD.swift`
- Modify: `Sources/CinemaHUD/PhotoView.swift` (delete the `PhotoHUD` stand-in)

**Interfaces:**
- Consumes: `PhotoView.ImageLayout`, `session.state` (`exposureMode`, `shotsRemaining`, `battery`, `focusMode`, `focusStatus`, `touchAFSet`, `touchAFPoint`, `shutterSpeed(+Candidates)`, `fNumber(+Candidates)`, `iso(+Candidates)`, `exposureCompensation`, `whiteBalanceMode`, `colorTemperature`), `session.captures`, `session.focusCheckPoint`, `session.review(_:)`, `session.takePicture()`, `session.step(...)`, `session.busy`, `session.transport`, `ScrollStepper`, `CandidatePicker`, `Theme`, `overlays.profile`.
- Produces: `PhotoHUD(layout:liveSharpness:afFlash:)`, `SonyReadout`, `BracketFrame`, `Triangle`, `ThumbnailCache`.

- [ ] **Step 1: Write PhotoHUD**

```swift
// Sources/CinemaHUD/PhotoHUD.swift
import SwiftUI
import SonyCameraKit
import ImageIO

/// Stills display in the idiom of the camera body's own LCD: white type on the picture, translucent
/// bands top and bottom, focus dot bottom-left, exposure across the bottom, shutter button bottom-right.
struct PhotoHUD: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    let layout: PhotoView.ImageLayout
    let liveSharpness: Double
    let afFlash: Bool
    @State private var blink = false
    @State private var thumbs = ThumbnailCache()

    private var rect: CGRect { layout.rect }

    var body: some View {
        let s = session.state
        ZStack {
            topBand(s)
            leftColumn(s)
            rightColumn(s)
            afFrame(s)
            bottomBand(s)
            focusIndicator(s)
            shutterButton(s)
            filmstrip
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in blink.toggle() }
    }

    // MARK: Bands

    private func topBand(_ s: CameraState) -> some View {
        HStack(spacing: 14) {
            modeBadge(s.exposureMode)
            if let n = s.shotsRemaining { sonyText("[ \(n) ]", 15) }
            fileFormatBadge
            Spacer()
            if let t = session.transport { sonyText(t.rawValue.uppercased(), 11).opacity(0.8) }
            battery(s.battery)
        }
        .padding(.horizontal, 12).frame(height: 30)
        .background(Color.black.opacity(0.38))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func bottomBand(_ s: CameraState) -> some View {
        HStack(spacing: 26) {
            SonyReadout(value: s.shutterSpeed ?? "--", candidates: s.shutterSpeedCandidates, enabled: s.supports("setShutterSpeed"),
                        onSelect: { v in Task { await session.setShutterSpeed(v) } },
                        onStep: { d in Task { await session.step(s.shutterSpeedCandidates, current: s.shutterSpeed, by: d) { await session.setShutterSpeed($0) } } })
            SonyReadout(value: s.fNumber.map { "F" + $0 } ?? "F--", candidates: s.fNumberCandidates, enabled: s.supports("setFNumber"),
                        format: { "F" + $0 },
                        onSelect: { v in Task { await session.setFNumber(v) } },
                        onStep: { d in Task { await session.step(s.fNumberCandidates, current: s.fNumber, by: d) { await session.setFNumber($0) } } })
            evMeter(s.exposureCompensation)
            SonyReadout(value: s.iso.map { "ISO " + $0 } ?? "ISO --", candidates: s.isoCandidates, enabled: s.supports("setIsoSpeedRate"),
                        format: { "ISO " + $0 },
                        onSelect: { v in Task { await session.setISO(v) } },
                        onStep: { d in Task { await session.step(s.isoCandidates, current: s.iso, by: d) { await session.setISO($0) } } })
            Spacer()
        }
        .padding(.leading, 64).padding(.trailing, 12).frame(height: 40)
        .background(Color.black.opacity(0.38))
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func leftColumn(_ s: CameraState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            boxed(s.focusMode ?? "AF")
            boxed(session.focusCheckPoint != nil || s.touchAFSet ? "SPOT" : "WIDE")
            boxed("S")   // single drive; the old protocol does not report drive mode
            Spacer()
        }
        .padding(.leading, 12).padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rightColumn(_ s: CameraState) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            boxed(wbLabel(s))
            boxed(overlays.profile.isLog ? overlays.profile.short : "DRO AUTO")
            Spacer()
        }
        .padding(.trailing, 12).padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    // MARK: Focus

    /// Sony's focus indicator: steady green dot = focused, blinking = failed, hollow = hunting. Plus the live
    /// sharpness bar for the AF region so focus can be seen settling before the shot.
    private func focusIndicator(_ s: CameraState) -> some View {
        HStack(spacing: 8) {
            Group {
                switch s.focusStatus {
                case "Focused": Circle().fill(Theme.ok)
                case "Failed": Circle().fill(Theme.rec).opacity(blink ? 1 : 0.15)
                case "Focusing": Circle().stroke(Color.white, lineWidth: 1.5)
                default: Circle().fill(.clear)
                }
            }
            .frame(width: 11, height: 11)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(width: 60, height: 5)
                Capsule().fill(liveSharpness >= FocusAnalyzer.inFocusRatio ? Theme.ok : (liveSharpness >= FocusAnalyzer.softRatio ? Theme.warn : Color.white))
                    .frame(width: 60 * max(0.02, min(1, liveSharpness)), height: 5)
            }
            sonyText(String(format: "%.0f", liveSharpness * 100), 10).opacity(0.75)
        }
        .padding(.leading, 12).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    private func afFrame(_ s: CameraState) -> some View {
        let p = session.focusCheckPoint ?? s.touchAFPoint.map { CGPoint(x: $0.x / 100, y: $0.y / 100) } ?? CGPoint(x: 0.5, y: 0.5)
        let fx = (p.x - layout.cropX) / layout.cropWidth, fy = (p.y - layout.cropY) / layout.cropHeight
        let size = rect.width * 0.09
        let color: Color = s.focusStatus == "Focused" ? Theme.ok : (s.focusStatus == "Failed" ? Theme.rec : .white)
        return BracketFrame().stroke(color, lineWidth: 2)
            .frame(width: size, height: size)
            .position(x: rect.width * fx, y: rect.height * fy)
            .scaleEffect(afFlash ? 1.2 : 1).animation(.easeOut(duration: 0.25), value: afFlash)
            .allowsHitTesting(false)
    }

    // MARK: Shutter, filmstrip

    private func shutterButton(_ s: CameraState) -> some View {
        Button { Task { await session.takePicture() } } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 3).frame(width: 52, height: 52)
                Circle().fill(Color.white.opacity(session.busy ? 0.4 : 0.9)).frame(width: 40, height: 40)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .disabled(!s.supports("actTakePicture"))
        .padding(.trailing, 16).padding(.bottom, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var filmstrip: some View {
        HStack(spacing: 6) {
            ForEach(session.captures.suffix(8)) { shot in
                Button { session.review(shot) } label: {
                    ZStack(alignment: .bottomTrailing) {
                        if let url = shot.primary?.url, let t = thumbs.image(for: url) {
                            Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Color.white.opacity(0.15))
                        }
                        if shot.transferring { ProgressView().controlSize(.mini).padding(3) }
                        else if shot.error != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).padding(3) }
                        else if shot.hasBoth { sonyText("RAW+J", 8).padding(3) }
                    }
                    .frame(width: 64, height: 43).clipped()
                    .overlay(Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }
        }
        .padding(.leading, 12).padding(.bottom, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    // MARK: Pieces

    private var fileFormatBadge: some View {
        let last = session.captures.last
        let text = last.map { $0.hasBoth ? "RAW+J" : ($0.raw != nil ? "RAW" : "JPEG") } ?? "--"
        return sonyText(text, 12).padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white, lineWidth: 1))
    }

    private func modeBadge(_ mode: String?) -> some View {
        let short: String = {
            switch mode {
            case "Manual": return "M"; case "Aperture": return "A"; case "Shutter": return "S"; case "Program Auto": return "P"
            case "Intelligent Auto", "Superior Auto": return "AUTO"
            default: return mode.map { String($0.prefix(4)).uppercased() } ?? "--"
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: "camera.fill").font(.system(size: 11))
            Text(short).font(.system(size: 16, weight: .heavy))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5))
    }

    private func battery(_ b: BatteryInfo?) -> some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).stroke(Color.white, lineWidth: 1.5).frame(width: 24, height: 11)
                RoundedRectangle(cornerRadius: 1).fill((b?.fraction ?? 1) < 0.15 ? Theme.rec : Color.white)
                    .frame(width: max(2, 20 * CGFloat(b?.fraction ?? 0)), height: 7).padding(.leading, 2)
            }
            sonyText(b.map { "\(Int($0.fraction * 100))%" } ?? "--%", 13)
        }
    }

    private func evMeter(_ ev: ExposureCompensation?) -> some View {
        let stops = ev.map { Double($0.index) * $0.stepEV } ?? 0
        return HStack(spacing: 6) {
            sonyText(ev?.label ?? "±0.0", 15).monospacedDigit()
            ZStack(alignment: .leading) {
                HStack(spacing: 8) {
                    ForEach(-3 ... 3, id: \.self) { i in
                        Rectangle().fill(Color.white.opacity(i == 0 ? 1 : 0.5)).frame(width: 1, height: i == 0 ? 10 : 6)
                    }
                }
                Triangle().fill(Color.white).frame(width: 7, height: 6)
                    .offset(x: CGFloat(max(-3, min(3, stops))) * 9 + 27 - 3.5, y: -10)
            }
        }
        .frame(height: 30)
    }

    private func wbLabel(_ s: CameraState) -> String {
        if s.whiteBalanceMode == "Color Temperature", let k = s.colorTemperature { return "\(k)K" }
        switch s.whiteBalanceMode {
        case "Auto WB": return "AWB"; case "Daylight": return "DAYLIGHT"; case "Cloudy": return "CLOUDY"; case "Shade": return "SHADE"
        default: return s.whiteBalanceMode.map { String($0.prefix(6)).uppercased() } ?? "WB"
        }
    }

    private func boxed(_ text: String) -> some View {
        sonyText(text, 12).padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.9), lineWidth: 1))
    }

    private func sonyText(_ text: String, _ size: CGFloat) -> some View {
        Text(text).font(.system(size: size, weight: .bold)).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 0)
    }
}

/// Exposure readout in the body's own style: bold white value, click for the list, scroll to step.
struct SonyReadout: View {
    let value: String
    var candidates: [String] = []
    var enabled = true
    var format: (String) -> String = { $0 }
    var onSelect: (String) -> Void = { _ in }
    var onStep: (Int) -> Void = { _ in }
    @State private var showPicker = false
    @State private var hover = false

    var body: some View {
        ScrollStepper(onStep: { if enabled { onStep($0) } }) {
            Button { if enabled && !candidates.isEmpty { showPicker.toggle() } } label: {
                Text(value).font(.system(size: 19, weight: .bold)).monospacedDigit()
                    .foregroundStyle(enabled ? (hover ? Theme.warn : .white) : Color.white.opacity(0.4))
                    .shadow(color: .black.opacity(0.8), radius: 1)
                    .padding(.horizontal, 4).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .onHover { hover = $0 }
            .popover(isPresented: $showPicker, arrowEdge: .top) {
                CandidatePicker(title: "", current: value, candidates: candidates, format: format) { v in showPicker = false; onSelect(v) }
            }
        }
    }
}

/// Four bracket corners, Sony's AF frame.
struct BracketFrame: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = r.width * 0.28
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x, y: y + dy * l)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + dx * l, y: y))
        }
        return p
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.closeSubpath()
        return p
    }
}

/// Small thumbnails for the filmstrip, decoded once per file off the main thread.
@Observable @MainActor
final class ThumbnailCache {
    private var images: [URL: CGImage] = [:]
    private var pending: Set<URL> = []

    func image(for url: URL) -> CGImage? {
        if let i = images[url] { return i }
        guard !pending.contains(url) else { return nil }
        pending.insert(url)
        Task.detached(priority: .utility) {
            let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160,
                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
            let img = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, opts) }
            await MainActor.run { self.pending.remove(url); if let img { self.images[url] = img } }
        }
        return nil
    }
}
```

Then delete the `PhotoHUD` stand-in struct from `PhotoView.swift`.

- [ ] **Step 2: Build and screenshot against the simulator**

Run: `swift build 2>&1 | grep -E "error"` → nothing.
Run:
```bash
python3 tools/camerasim.py & SIM=$!; sleep 1
CINEMAHUD_ADDRESS=127.0.0.1:8080 CINEMAHUD_OVERLAYS=photo CINEMAHUD_WINDOW=1400x900 CINEMAHUD_SNAPSHOT=/tmp/photo-hud.png .build/debug/CinemaHUD & APP=$!
sleep 7; kill $APP $SIM
```
Open `/tmp/photo-hud.png`: top band with mode badge / shots / RAW badge / battery, left boxes AF-C SPOT|WIDE S, bottom band with 1/50 F2.8 EV meter ISO 800, focus dot + sharpness bar bottom-left, shutter button bottom-right, bracket AF frame at centre. Adjust spacing only if elements overlap.

- [ ] **Step 3: Run tests, commit**

Run: `swift test 2>&1 | grep -E "Executed|error:|failed"` → `Executed 33 tests, with 0 failures`.

```bash
git add Sources/CinemaHUD/PhotoHUD.swift Sources/CinemaHUD/PhotoView.swift
git commit -m "PhotoHUD: Sony body-style stills display, focus indicator, live sharpness meter, filmstrip"
```

---

### Task 8: ReviewView — real capture at 100%, loupe, focus verdict, keys

**Files:**
- Create: `Sources/CinemaHUD/ReviewView.swift`
- Modify: `Sources/CinemaHUD/PhotoView.swift` (delete the `ReviewView` stand-in)
- Modify: `Sources/CinemaHUD/CinemaHUDApp.swift` (Camera menu: review keys, contextual R)

**Interfaces:**
- Consumes: `CapturedShot`, `FocusAnalyzer.analyze`, `FocusReport`, `session.reviewShot`, `session.review(_:)`, `session.reviewNeighbor(_:)`, `session.captures`, `overlays.reviewShowsRAW`, `BracketFrame`, `ScrollStepper`, `Theme`.
- Produces: `ReviewView(shot:)`, `ReviewDecoder.decode(url:) -> (full: CGImage, proxy: CGImage)?`.

- [ ] **Step 1: Write ReviewView**

```swift
// Sources/CinemaHUD/ReviewView.swift
import SwiftUI
import SonyCameraKit
import ImageIO

/// Decodes a capture: a 2048-px proxy first (fast), then the full image. ARW goes through ImageIO's RAW support.
enum ReviewDecoder {
    static func decode(url: URL) -> (full: CGImage, proxy: CGImage)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let popts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let proxy = CGImageSourceCreateThumbnailAtIndex(src, 0, popts) else { return nil }
        let full = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) ?? proxy
        return (full, proxy)
    }
}

/// Auto-review after a shot: the real file, a 100 %-pixel loupe on the AF point, and a focus verdict.
struct ReviewView: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    @Environment(\.displayScale) private var displayScale
    let shot: CapturedShot

    @State private var full: CGImage?
    @State private var proxy: CGImage?
    @State private var report: FocusReport?
    @State private var decodingURL: URL?
    @State private var loupeCenter = CGPoint(x: 0.5, y: 0.5)
    @State private var zoom: CGFloat = 0          // 0 = fit, else image pixels per screen pixel (1 = 100 %, 2 = 200 %)
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var failed = false

    private var current: CapturedImage? { overlays.reviewShowsRAW ? (shot.raw ?? shot.jpeg) : (shot.jpeg ?? shot.raw) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = proxyOrFull {
                    picture(img, in: geo.size)
                } else if failed {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark").font(.system(size: 40)).foregroundStyle(Theme.dim)
                        Text("Cannot decode \(current?.filename ?? "file")").font(Theme.mono(12)).foregroundStyle(Theme.dim)
                    }
                } else {
                    ProgressView().controlSize(.large)
                }
                header
                if let full, let report { loupe(full, report: report, in: geo.size) }
            }
        }
        .onAppear { load() }
        .onChange(of: current?.url) { _, _ in load() }
        .onChange(of: shot.afPoint) { _, p in loupeCenter = p ?? CGPoint(x: 0.5, y: 0.5) }
    }

    private var proxyOrFull: CGImage? { zoom == 0 ? (proxy ?? full) : (full ?? proxy) }

    // MARK: Picture

    private func fitRect(_ img: CGImage, in size: CGSize) -> CGRect {
        let aspect = CGFloat(img.width) / CGFloat(img.height)
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func picture(_ img: CGImage, in size: CGSize) -> some View {
        let fit = fitRect(img, in: size)
        let fullWidth = CGFloat(full?.width ?? img.width)
        let scale: CGFloat = zoom == 0 ? 1 : (fullWidth / displayScale * zoom) / fit.width
        let shown = CGSize(width: fit.width * scale, height: fit.height * scale)
        return ZStack {
            Image(decorative: img, scale: 1).resizable().interpolation(zoom == 0 ? .high : .none)
                .frame(width: shown.width, height: shown.height)
                .offset(pan)
                .position(x: size.width / 2, y: size.height / 2)
            if let report, zoom == 0 {
                // where the image is actually sharpest, so a MISSED verdict says where focus went
                Rectangle().stroke(Theme.warn, lineWidth: 1.5).frame(width: fit.width / CGFloat(report.tiles), height: fit.height / CGFloat(report.tiles))
                    .position(x: fit.minX + fit.width * report.peakPoint.x, y: fit.minY + fit.height * report.peakPoint.y)
                BracketFrame().stroke(report.verdict == .inFocus ? Theme.ok : (report.verdict == .soft ? Theme.warn : Theme.rec), lineWidth: 2)
                    .frame(width: fit.width * 0.12, height: fit.width * 0.12)
                    .position(x: fit.minX + fit.width * loupeCenter.x, y: fit.minY + fit.height * loupeCenter.y)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { loc in
            guard zoom == 0 else { return }
            loupeCenter = CGPoint(x: min(1, max(0, (loc.x - fit.minX) / fit.width)), y: min(1, max(0, (loc.y - fit.minY) / fit.height)))
        }
        .gesture(DragGesture().onChanged { v in if zoom > 0 { pan = CGSize(width: v.translation.width + panStart.width, height: v.translation.height + panStart.height) } }
                              .onEnded { _ in panStart = pan })
        .background(ScrollStepper(onStep: { d in cycleZoom(d) }) { Color.clear })
    }

    private func cycleZoom(_ delta: Int) {
        let steps: [CGFloat] = [0, 1, 2]
        let i = steps.firstIndex(of: zoom) ?? 0
        zoom = steps[max(0, min(steps.count - 1, i + (delta > 0 ? 1 : -1)))]
        if zoom == 0 { pan = .zero; panStart = .zero }
    }

    // MARK: Loupe and verdict

    private func loupe(_ img: CGImage, report: FocusReport, in size: CGSize) -> some View {
        let loupeSize = CGSize(width: 360, height: 240)
        let cropW = Int(loupeSize.width * displayScale), cropH = Int(loupeSize.height * displayScale)
        let cx = Int(CGFloat(img.width) * loupeCenter.x), cy = Int(CGFloat(img.height) * loupeCenter.y)
        let crop = CGRect(x: max(0, min(img.width - cropW, cx - cropW / 2)), y: max(0, min(img.height - cropH, cy - cropH / 2)), width: cropW, height: cropH)
        let onLeft = loupeCenter.x > 0.5
        let color: Color = report.verdict == .inFocus ? Theme.ok : (report.verdict == .soft ? Theme.warn : Theme.rec)
        return VStack(alignment: .leading, spacing: 0) {
            if let c = img.cropping(to: crop) {
                Image(decorative: c, scale: displayScale).interpolation(.none)
                    .frame(width: loupeSize.width, height: loupeSize.height).clipped()
                    .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1))
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(report.verdict.rawValue).font(.system(size: 15, weight: .heavy)).foregroundStyle(color)
                Text(String(format: "%.0f%% of peak", report.ratio * 100)).font(Theme.mono(11)).foregroundStyle(Theme.dim)
                Spacer()
                Text("100%").font(Theme.label(9)).tracking(1.2).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 8).frame(width: loupeSize.width, height: 26)
            .background(Color.black.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: onLeft ? .bottomLeading : .bottomTrailing)
        .padding(16)
        .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Button { session.review(nil) } label: { Text("◀ LIVE").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                .buttonStyle(.plain).focusEffectDisabled()
            Text(current?.filename ?? "").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            if shot.hasBoth {
                Button { overlays.reviewShowsRAW.toggle() } label: {
                    Text(overlays.reviewShowsRAW ? "RAW" : "JPEG").font(.system(size: 11, weight: .heavy)).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Color.white, in: RoundedRectangle(cornerRadius: 2))
                }.buttonStyle(.plain).focusEffectDisabled()
            } else {
                Text(current?.kind.rawValue ?? "").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white, lineWidth: 1))
            }
            if let full { Text("\(full.width)×\(full.height)").font(Theme.mono(12)).foregroundStyle(Theme.dim) }
            Text(shot.exposure.summary).font(Theme.mono(12)).foregroundStyle(.white)
            Spacer()
            if shot.transferring { Text(shot.raw == nil ? "TRANSFERRING RAW…" : "TRANSFERRING…").font(Theme.label(10)).tracking(1.5).foregroundStyle(Theme.warn) }
            if let e = shot.error { Text(e).font(Theme.mono(11)).foregroundStyle(Theme.warn).lineLimit(1) }
            Text(zoom == 0 ? "FIT" : "\(Int(zoom * 100))%").font(Theme.label(10)).tracking(1.5).foregroundStyle(Theme.dim)
            Text("\(session.captures.firstIndex(where: { $0.id == shot.id }).map { $0 + 1 } ?? 0)/\(session.captures.count)").font(Theme.mono(12)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(Color.black.opacity(0.6))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Loading

    private func load() {
        guard let img = current else { failed = true; return }
        guard decodingURL != img.url else { return }
        decodingURL = img.url
        full = nil; proxy = nil; report = nil; failed = false
        zoom = 0; pan = .zero; panStart = .zero
        loupeCenter = shot.afPoint ?? CGPoint(x: 0.5, y: 0.5)
        let url = img.url, af = shot.afPoint
        Task.detached(priority: .userInitiated) {
            guard let d = ReviewDecoder.decode(url: url) else { await MainActor.run { failed = true }; return }
            await MainActor.run { proxy = d.proxy }
            let r = FocusAnalyzer.analyze(d.full, afPoint: af)
            await MainActor.run { full = d.full; report = r }
        }
    }
}
```

Delete the `ReviewView` stand-in from `PhotoView.swift`.

- [ ] **Step 2: Keys in the Camera menu**

In `CinemaHUDApp.swift`, replace

```swift
                Button(session.state.isRecording ? "Stop Recording" : "Start Recording") { Task { await session.toggleRecording() } }
                    .keyboardShortcut("r", modifiers: [])
```

with (R keeps its recording behaviour in video mode; in a photo-mode review it flips JPEG/RAW):

```swift
                Button(session.reviewShot != nil && overlays.shootingMode == .photo ? "Toggle RAW / JPEG" : (session.state.isRecording ? "Stop Recording" : "Start Recording")) {
                    if session.reviewShot != nil && overlays.shootingMode == .photo { overlays.reviewShowsRAW.toggle() }
                    else { Task { await session.toggleRecording() } }
                }
                .keyboardShortcut("r", modifiers: [])
```

Then add after the Photo/Video toggle button (Task 6):

```swift
                Button("Leave Review") { session.review(nil) }.keyboardShortcut(.escape, modifiers: []).disabled(session.reviewShot == nil)
                Button("Previous Shot") { if session.reviewShot == nil, let last = session.captures.last { session.review(last) } else { session.reviewNeighbor(-1) } }
                    .keyboardShortcut(.leftArrow, modifiers: []).disabled(session.captures.isEmpty)
                Button("Next Shot") { session.reviewNeighbor(1) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(session.reviewShot == nil)
```

- [ ] **Step 3: Build and exercise against the simulator**

Run: `swift build 2>&1 | grep -E "error"` → nothing.
Run:
```bash
python3 tools/camerasim.py & SIM=$!; sleep 1
CINEMAHUD_ADDRESS=127.0.0.1:8080 CINEMAHUD_OVERLAYS=photo CINEMAHUD_ACTION="shoot=1" CINEMAHUD_WINDOW=1400x900 CINEMAHUD_SNAPSHOT=/tmp/photo-review.png .build/debug/CinemaHUD & APP=$!
sleep 9; kill $APP $SIM; ls -la ~/Pictures/CinemaHUD/$(date +%F)/
```
Open `/tmp/photo-review.png`: the 3000×2000 simulator postview fills the view, header shows the filename, JPEG badge, size, exposure, the loupe sits in a bottom corner with a verdict, and the file is listed in today's folder.

- [ ] **Step 4: Run tests, commit**

Run: `swift test 2>&1 | grep -E "Executed|error:|failed"` → `Executed 33 tests, with 0 failures`.

```bash
git add Sources/CinemaHUD/ReviewView.swift Sources/CinemaHUD/PhotoView.swift Sources/CinemaHUD/CinemaHUDApp.swift
git commit -m "ReviewView: real capture at 100% with loupe, focus verdict, RAW/JPEG toggle, shot navigation"
```

---

### Task 9: README, final verification, hardware checklist

**Files:**
- Modify: `README.md` (new section after "### Controls"; bullet under "### Verified on hardware")

- [ ] **Step 1: Document Photo mode**

Insert after the Controls table:

```markdown
### Photo mode

Turn the mode dial to a still position and the app switches to **Photo mode** (Tab forces either mode
until the dial moves). The display follows the camera body's own LCD: mode badge, shots remaining,
RAW+J badge and battery across the top; focus mode and area on the left; shutter, aperture, EV and ISO
along the bottom (click or scroll to change). Sony's focus dot sits bottom-left, green when focus is
confirmed, and a small bar next to it shows how sharp the AF region is on the live view.

**Every shot is transferred to the Mac as it is taken**, whether you press the shutter in the app or on
the camera, and saved to `~/Pictures/CinemaHUD/<yyyy-MM-dd>/` under the camera's own filename. Over USB
both the JPEG and the RAW (ARW) arrive; on the camera set *File Format* to RAW+JPEG and
*Still Img. Save Dest.* to **PC** or **PC+Camera**. Over Wi-Fi Sony's remote API only sends the JPEG.

The moment the JPEG lands it replaces the live view for **review**: the real full-resolution image
with a 100 % loupe on the AF point and a focus verdict (IN FOCUS / SOFT / MISSED, with a marker where
the image is actually sharpest). Click to move the loupe, scroll to zoom, drag to pan, R switches
between JPEG and RAW once both are in, ← / → step through the shots, Escape returns to live view.
Return or Space fire the shutter or AF and leave review too. Thumbnails of the session's shots sit
along the bottom of the live view.
```

Under "### Verified on hardware" add: `Photo mode: RAW+JPEG transfer, body-triggered transfer, auto review and the focus verdict have been exercised against the simulator only; hardware verification pending.`

- [ ] **Step 2: Full build, tests, release binary**

Run: `swift test 2>&1 | grep -E "Executed|error:|failed"` → `Executed 33 tests, with 0 failures`.
Run: `./scripts/build-dmg.sh 2>&1 | tail -3` → `✔ build/CinemaHUD.dmg`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "README: Photo mode, real-time RAW+JPEG transfer, review"
```

- [ ] **Step 4: Hardware checklist for the user** (not automatable here; report as pending)

1. Camera: File Format RAW+JPEG, Still Img. Save Dest. PC+Camera, USB Connection PC Remote, dial on a stills mode.
2. Connect USB, confirm the app is in Photo mode; press Return, then press the shutter on the body.
3. Expect within ~3 s of each: review opens on the JPEG, header shows TRANSFERRING RAW…, then the RAW badge; two files per shot in today's folder.
4. Defocus deliberately and shoot: verdict should read MISSED with the peak marker elsewhere. Tune `FocusAnalyzer.inFocusRatio` / `softRatio` if the verdicts feel wrong.
