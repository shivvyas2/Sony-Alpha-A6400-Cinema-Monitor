import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Observation

public enum ConnectionPhase: Sendable, Equatable {
    case idle
    case discovering
    case connecting(String)
    case live
    case failed(String)

    public var isConnected: Bool { self == .live }
}

/// Main-actor façade over whichever backend is connected: runs the state and liveview loops,
/// exposes observable state for the UI, and offers async control actions.
@MainActor
@Observable
public final class CameraSession {
    public private(set) var phase: ConnectionPhase = .idle
    public private(set) var state = CameraState()
    /// Generic settings for the menu (drive, metering, DRO, …), refreshed with the state.
    public private(set) var settings: [CameraSetting] = []
    /// Latest picture as a raw-value Core Image (no colour management applied yet; the display tags it).
    public private(set) var frame: CIImage?
    public private(set) var frameSize: CGSize = .zero
    public private(set) var fps: Double = 0
    /// Frames per second actually arriving from the camera (before any interpolation).
    public private(set) var sourceFPS: Double = 0
    /// Number of recordings started this session.
    public private(set) var takes = 0
    /// Frame-rate multiplier for synthesized in-between frames: 1 = off, 2, 4 or 8. Adds one frame of delay.
    public var motionFactor = 1 { didSet { interpolator?.factor = motionFactor; if motionFactor == 1 && denoise == 0 { interpolator?.reset() } } }
    public var smoothMotion: Bool { get { motionFactor > 1 } set { motionFactor = newValue ? 2 : 1 } }
    /// Temporal noise reduction strength 0…1 (0 = off).
    public var denoise: Float = 0 { didSet { interpolator?.denoise = denoise; if motionFactor == 1 && denoise == 0 { interpolator?.reset() } } }
    public private(set) var lastError: String?
    public private(set) var cameraName: String = ""
    public private(set) var transport: CameraTransportKind?
    public private(set) var busy = false
    /// Shots taken this session, oldest first. Files stay on disk; the list resets on the next launch.
    public private(set) var shotLog = ShotLog()
    public var captures: [CapturedShot] { shotLog.shots }
    /// The shot being reviewed full-screen (photo mode). nil = live view.
    public var reviewShot: CapturedShot?
    /// Where the user last clicked to check focus (fractions of the frame), used when the transport has no touch AF.
    public var focusCheckPoint: CGPoint?
    @ObservationIgnored private var captureTask: Task<Void, Never>?

    private var backend: CameraBackend?
    private var eventTask: Task<Void, Never>?
    private var liveviewTask: Task<Void, Never>?
    @ObservationIgnored private var interpolator: MotionInterpolator? = MotionInterpolator()
    @ObservationIgnored private var displayCount = 0
    @ObservationIgnored private var displayWindow = Date()
    @ObservationIgnored private var sourceCount = 0
    @ObservationIgnored private var sourceWindow = Date()

    public init() {}

    // MARK: Connection

    public func discoverAndConnect() async {
        phase = .discovering
        lastError = nil
        let found = await SSDPDiscovery.discover(timeout: 3)
        guard let cam = found.first else {
            phase = .failed("No camera found. Join the camera's DIRECT-xxxx Wi-Fi and put it in “Ctrl w/ Smartphone”.")
            return
        }
        await connect(WiFiBackend(camera: cam))
    }

    public func connect(toAddress text: String) async {
        var s = text.trimmingCharacters(in: .whitespaces)
        if !s.hasPrefix("http") { s = "http://" + s }
        if !s.contains(":8080") && !s.dropFirst(7).contains(":") { s += ":8080" }
        if !s.hasSuffix("/sony") { s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/sony" }
        guard let url = URL(string: s) else { phase = .failed("Bad address"); return }
        await connect(WiFiBackend(camera: DiscoveredCamera(friendlyName: "Sony Camera", modelName: "", serviceURL: url)))
    }

    public func connectUSB() async {
        lastError = nil
        let devices = SonyUSBBackend.availableDevices()
        guard let dev = devices.first(where: \.isSony) ?? devices.first else {
            phase = .failed("No camera on USB. On the camera: MENU → Setup → USB Connection → PC Remote, then connect the cable.")
            return
        }
        await connect(SonyUSBBackend(device: dev))
    }

    public func connect(_ backend: CameraBackend) async {
        disconnect()
        self.backend = backend
        transport = backend.kind
        phase = .connecting(await backend.displayName)
        do {
            state = try await backend.connect()
            settings = await backend.settings()
            cameraName = await backend.displayName
            phase = .live
            startStateLoop()
            startLiveview()
            startCaptureLoop()
        } catch {
            phase = .failed(describe(error))
            await backend.disconnect()
            self.backend = nil
        }
    }

    public func disconnect() {
        eventTask?.cancel(); eventTask = nil
        liveviewTask?.cancel(); liveviewTask = nil
        captureTask?.cancel(); captureTask = nil
        reviewShot = nil
        if let backend { Task { await backend.disconnect() } }
        backend = nil
        transport = nil
        cameraName = ""
        frame = nil
        fps = 0
        state = CameraState()
        phase = .idle
    }

    // MARK: Loops

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

    private func startStateLoop() {
        guard let backend else { return }
        eventTask = Task { [weak self] in
            do {
                for try await s in backend.stateUpdates() {
                    guard let self, !Task.isCancelled else { return }
                    let wasRecording = self.state.isRecording
                    self.state = s
                    if !wasRecording && s.isRecording { self.takes += 1 }
                    let list = await backend.settings()
                    if list != self.settings { self.settings = list }
                }
                guard let self, !Task.isCancelled else { return }
                await self.reconnect(after: nil)
            } catch {
                guard let self, !Task.isCancelled else { return }
                await self.reconnect(after: error)
            }
        }
    }

    /// Connection dropped (Wi-Fi hiccup, cable bump): rebuild the session on the same backend,
    /// retrying with backoff for a while before giving up.
    private func reconnect(after error: Error?) async {
        guard let backend else { return }
        liveviewTask?.cancel(); liveviewTask = nil
        let reason = error.map { describe($0) } ?? "stream ended"
        lastError = "Reconnecting: \(reason)"
        for attempt in 1 ... 10 {
            phase = .connecting(cameraName.isEmpty ? "camera" : cameraName)
            try? await Task.sleep(for: .seconds(min(5, Double(attempt))))
            if Task.isCancelled { return }
            await backend.disconnect()
            if let s = try? await backend.connect() {
                state = s
                lastError = nil
                phase = .live
                startStateLoop()
                startLiveview()
                return
            }
        }
        phase = .failed("Lost connection: \(reason)")
    }

    private func startLiveview() {
        guard let backend else { return }
        liveviewTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                do {
                    try await self?.consume(backend.liveviewFrames())
                    attempt = 0
                } catch {
                    if Task.isCancelled { return }
                    attempt += 1
                    self?.report(error)
                    try? await Task.sleep(for: .seconds(min(5, Double(attempt))))
                }
            }
        }
    }

    private func consume(_ frames: AsyncThrowingStream<Data, Error>) async throws {
        // Decode off the main actor; only the finished CGImage hops back.
        let decoded = AsyncThrowingStream<CGImage, Error>(bufferingPolicy: .bufferingNewest(1)) { cont in
            let t = Task.detached(priority: .userInitiated) {
                do {
                    for try await jpeg in frames {
                        if Task.isCancelled { break }
                        if let img = Self.decodeJPEG(jpeg) { cont.yield(img) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
        interpolator?.reset()
        for try await img in decoded {
            if Task.isCancelled { break }
            sourceCount += 1
            let elapsed = Date().timeIntervalSince(sourceWindow)
            if elapsed >= 1 { sourceFPS = Double(sourceCount) / elapsed; sourceCount = 0; sourceWindow = Date() }
            if motionFactor > 1 || denoise > 0, let interpolator {
                interpolator.push(img, at: CFAbsoluteTimeGetCurrent()) { out in
                    Task { @MainActor [weak self] in self?.display(out) }
                }
            } else {
                display(CIImage(cgImage: img, options: [.colorSpace: NSNull()]))
            }
        }
        throw CancellationError()
    }

    private func display(_ img: CIImage) {
        frame = img
        frameSize = img.extent.size
        displayCount += 1
        let elapsed = Date().timeIntervalSince(displayWindow)
        if elapsed >= 1 { fps = Double(displayCount) / elapsed; displayCount = 0; displayWindow = Date() }
    }

    nonisolated static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: Controls

    private func perform(_ label: String, _ op: @escaping @Sendable (CameraBackend) async throws -> Void) async {
        guard let backend else { return }
        busy = true
        defer { busy = false }
        do { try await op(backend); lastError = nil } catch { report(error, label: label) }
    }

    public func setShutterSpeed(_ v: String) async { await perform("Shutter") { try await $0.setShutterSpeed(v) } }
    public func setFNumber(_ v: String) async { await perform("Iris") { try await $0.setFNumber(v) } }
    public func setISO(_ v: String) async { await perform("ISO") { try await $0.setISO(v) } }
    public func setFocusMode(_ v: String) async { await perform("Focus") { try await $0.setFocusMode(v) } }
    public func setExposureMode(_ v: String) async { await perform("Mode") { try await $0.setExposureMode(v) } }
    public func setShootMode(_ v: String) async { await perform("Shoot mode") { try await $0.setShootMode(v) } }
    public func setWhiteBalance(mode: String, colorTemp: Int?) async {
        await perform("WB") { try await $0.setWhiteBalance(mode: mode, colorTemp: colorTemp) }
    }
    public func setExposureCompensation(index: Int) async {
        await perform("EV") { try await $0.setExposureCompensation(index: index) }
    }
    public func stepExposureCompensation(_ delta: Int) async {
        guard let ev = state.exposureCompensation else { return }
        let next = max(ev.minIndex, min(ev.maxIndex, ev.index + delta))
        if next != ev.index { await setExposureCompensation(index: next) }
    }

    /// Step a candidate list relative to the current value (e.g. scroll wheel on a readout).
    public func step(_ candidates: [String], current: String?, by delta: Int, apply: (String) async -> Void) async {
        guard !candidates.isEmpty else { return }
        let idx = candidates.firstIndex(of: current ?? "") ?? 0
        let next = max(0, min(candidates.count - 1, idx + delta))
        if next != idx { await apply(candidates[next]) }
    }

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
    public func toggleRecording() async {
        if state.isRecording { await perform("Stop REC") { try await $0.stopMovie() } }
        else { await perform("REC") { try await $0.startMovie() } }
    }
    /// x, y in 0...1 of the liveview image.
    public func touchAF(x: Double, y: Double) async {
        focusCheckPoint = CGPoint(x: x, y: y)
        await perform("Touch AF") { try await $0.touchAF(x: max(0, min(100, x * 100)), y: max(0, min(100, y * 100))) }
    }
    public func cancelTouchAF() async { await perform("Touch AF") { try await $0.cancelTouchAF() } }
    public func setSetting(_ id: String, _ value: String) async { await perform("Setting") { try await $0.setSetting(id: id, value: value) } }
    /// Nudge manual focus: negative = near, positive = far, |steps| = size (1 fine … 7 coarse).
    public func focusDrive(_ steps: Int) async { await perform("Focus") { try await $0.focusDrive(steps: steps) } }
    public func press(_ button: CameraButton) async { await perform(button.rawValue) { try await $0.press(button) } }

    // MARK: Errors

    private func report(_ error: Error, label: String? = nil) {
        let text = describe(error)
        lastError = label.map { "\($0): \(text)" } ?? text
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? SonyAPIError { return "\(e.message) (\(e.code))" }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        if error is CancellationError { return "cancelled" }
        return (error as NSError).localizedDescription
    }
}
