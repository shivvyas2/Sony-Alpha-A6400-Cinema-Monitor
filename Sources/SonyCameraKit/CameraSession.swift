import Foundation
import CoreGraphics
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

/// Main-actor façade over the camera: runs the event loop and the liveview stream,
/// exposes observable state for the UI, and offers async control actions.
@MainActor
@Observable
public final class CameraSession {
    public private(set) var phase: ConnectionPhase = .idle
    public private(set) var state = CameraState()
    public private(set) var frame: CGImage?
    public private(set) var frameSize: CGSize = .zero
    public private(set) var fps: Double = 0
    public private(set) var lastError: String?
    public private(set) var camera: DiscoveredCamera?
    public private(set) var busy = false

    private var client: SonyCameraClient?
    private var eventTask: Task<Void, Never>?
    private var liveviewTask: Task<Void, Never>?
    private var streamer: StreamingTask?
    private var liveviewURLOverride: URL?

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
        await connect(to: cam)
    }

    public func connect(toAddress text: String) async {
        var s = text.trimmingCharacters(in: .whitespaces)
        if !s.hasPrefix("http") { s = "http://" + s }
        if !s.contains(":8080") && !s.dropFirst(7).contains(":") { s += ":8080" }
        if !s.hasSuffix("/sony") { s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/sony" }
        guard let url = URL(string: s) else { phase = .failed("Bad address"); return }
        await connect(to: DiscoveredCamera(friendlyName: "Sony Camera", modelName: "", serviceURL: url))
    }

    public func connect(to cam: DiscoveredCamera) async {
        disconnect()
        camera = cam
        phase = .connecting(cam.friendlyName)
        let client = SonyCameraClient(serviceURL: cam.serviceURL)
        self.client = client
        liveviewURLOverride = nil
        do {
            var apis = try await client.getAvailableApiList()
            if apis.contains("startRecMode") {
                try? await client.startRecMode()
                apis = (try? await client.getAvailableApiList()) ?? apis
            }
            state.availableAPIs = Set(apis)
            let version = await client.bestEventVersion()
            let first = try await client.getEvent(longPolling: false, version: version)
            state.apply(event: first)
            phase = .live
            startEventLoop(version: version)
            startLiveview()
        } catch {
            phase = .failed(describe(error))
            self.client = nil
        }
    }

    public func disconnect() {
        eventTask?.cancel(); eventTask = nil
        liveviewTask?.cancel(); liveviewTask = nil
        streamer?.cancel(); streamer = nil
        if let client {
            Task { try? await client.stopLiveview() }
        }
        client = nil
        camera = nil
        frame = nil
        fps = 0
        state = CameraState()
        phase = .idle
    }

    // MARK: Event loop

    private func startEventLoop(version: String) {
        guard let client else { return }
        eventTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    let ev = try await client.getEvent(longPolling: true, version: version)
                    failures = 0
                    guard let self, !Task.isCancelled else { return }
                    self.state.apply(event: ev)
                } catch let e as SonyAPIError where e.code == 2 {
                    // "Timeout": long polling returned without changes — normal.
                    continue
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    self?.report(error)
                    if failures > 5 { self?.phase = .failed("Lost connection: \(self?.describe(error) ?? "")"); return }
                    try? await Task.sleep(for: .seconds(min(5, Double(failures))))
                }
            }
        }
    }

    // MARK: Liveview

    private func startLiveview() {
        guard let client else { return }
        liveviewTask?.cancel()
        liveviewTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                do {
                    let apis = self?.state.availableAPIs ?? []
                    let url: URL
                    if let override = self?.liveviewURLOverride {
                        url = override
                    } else if apis.contains("startLiveviewWithSize") {
                        if let large = try? await client.startLiveview(size: "L") {
                            url = large
                        } else {
                            url = try await client.startLiveview(size: nil)
                        }
                    } else {
                        url = try await client.startLiveview(size: nil)
                    }
                    attempt = 0
                    try await self?.consumeLiveview(url: url)
                } catch {
                    if Task.isCancelled { return }
                    attempt += 1
                    self?.report(error)
                    try? await Task.sleep(for: .seconds(min(5, Double(attempt))))
                }
            }
        }
    }

    private func consumeLiveview(url: URL) async throws {
        let streamer = StreamingTask()
        self.streamer = streamer
        let chunks = streamer.start(url: url)
        // Parse + decode off the main actor; only the finished CGImage hops back.
        let decoded = AsyncThrowingStream<(CGImage, Int), Error> { cont in
            let t = Task.detached(priority: .userInitiated) {
                var parser = LiveviewStreamParser()
                do {
                    for try await chunk in chunks {
                        if Task.isCancelled { break }
                        let frames = parser.append(chunk)
                        // Only decode the newest frame if we fell behind.
                        if let last = frames.last, let img = Self.decodeJPEG(last.jpeg) {
                            cont.yield((img, frames.count))
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
        var count = 0
        var window = Date()
        for try await (img, n) in decoded {
            if Task.isCancelled { break }
            frame = img
            frameSize = CGSize(width: img.width, height: img.height)
            count += n
            let elapsed = Date().timeIntervalSince(window)
            if elapsed >= 1 { fps = Double(count) / elapsed; count = 0; window = Date() }
        }
        throw CancellationError()
    }

    nonisolated static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: Controls

    private func perform(_ label: String, _ op: @escaping @Sendable (SonyCameraClient) async throws -> Void) async {
        guard let client else { return }
        busy = true
        defer { busy = false }
        do { try await op(client); lastError = nil } catch { report(error, label: label) }
    }

    public func setShutterSpeed(_ v: String) async { await perform("Shutter") { try await $0.setShutterSpeed(v) } }
    public func setFNumber(_ v: String) async { await perform("Iris") { try await $0.setFNumber(v) } }
    public func setISO(_ v: String) async { await perform("ISO") { try await $0.setIsoSpeedRate(v) } }
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
        await perform("AF") { c in
            try await c.actHalfPressShutter()
            try? await Task.sleep(for: .milliseconds(1200))
            try? await c.cancelHalfPressShutter()
        }
    }

    public func takePicture() async {
        await perform("Shoot") { c in
            _ = try await c.actTakePicture()
        }
    }

    public func toggleRecording() async {
        if state.isRecording {
            await perform("Stop REC") { try await $0.stopMovieRec() }
        } else {
            await perform("REC") { c in
                try await c.startMovieRec()
            }
        }
    }

    /// x, y in 0...1 of the liveview image.
    public func touchAF(x: Double, y: Double) async {
        await perform("Touch AF") { c in
            _ = try await c.setTouchAFPosition(x: max(0, min(100, x * 100)), y: max(0, min(100, y * 100)))
        }
    }

    public func cancelTouchAF() async { await perform("Touch AF") { try await $0.cancelTouchAFPosition() } }

    public func zoom(in direction: String, movement: String) async {
        await perform("Zoom") { try await $0.actZoom(direction: direction, movement: movement) }
    }

    // MARK: Errors

    private func report(_ error: Error, label: String? = nil) {
        let text = describe(error)
        lastError = label.map { "\($0): \(text)" } ?? text
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? SonyAPIError { return "\(e.message) (\(e.code))" }
        if error is CancellationError { return "cancelled" }
        return (error as NSError).localizedDescription
    }
}
