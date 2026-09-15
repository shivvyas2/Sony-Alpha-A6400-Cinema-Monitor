import Foundation

/// Sony Camera Remote API (JSON-RPC over the camera's Wi-Fi) as a `CameraBackend`.
public final class WiFiBackend: CameraBackend, @unchecked Sendable {
    public let kind: CameraTransportKind = .wifi
    public let camera: DiscoveredCamera
    private let client: SonyCameraClient
    private let stateBox = StateBox()
    private var eventVersion = "1.0"
    let captures = CaptureBroadcaster()
    public var saveDirectory: URL = CaptureStore.defaultBase
    public func captureEvents() -> AsyncStream<CaptureEvent> { captures.stream() }

    public var displayName: String { camera.modelName.isEmpty ? camera.friendlyName : camera.modelName }

    public init(camera: DiscoveredCamera) {
        self.camera = camera
        self.client = SonyCameraClient(serviceURL: camera.serviceURL)
    }

    public func connect() async throws -> CameraState {
        var apis = try await client.getAvailableApiList()
        if apis.contains("startRecMode") {
            try? await client.startRecMode()
            apis = (try? await client.getAvailableApiList()) ?? apis
        }
        eventVersion = await client.bestEventVersion()
        var s = CameraState()
        s.availableAPIs = Set(apis)
        s.apply(event: try await client.getEvent(longPolling: false, version: eventVersion))
        stateBox.set(s)
        return s
    }

    public func disconnect() async {
        try? await client.stopLiveview()
    }

    public func stateUpdates() -> AsyncThrowingStream<CameraState, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                var failures = 0
                while !Task.isCancelled {
                    do {
                        let ev = try await client.getEvent(longPolling: true, version: eventVersion)
                        failures = 0
                        let s = stateBox.update { $0.apply(event: ev) }
                        cont.yield(s)
                    } catch let e as SonyAPIError where e.code == 2 {
                        continue   // long-poll timeout without changes
                    } catch {
                        if Task.isCancelled { return }
                        failures += 1
                        if failures > 5 { cont.finish(throwing: error); return }
                        try? await Task.sleep(for: .seconds(Double(failures)))
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func liveviewFrames() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { cont in
            let task = Task {
                do {
                    let apis = stateBox.get().availableAPIs
                    let url: URL
                    if apis.contains("startLiveviewWithSize"), let large = try? await client.startLiveview(size: "L") {
                        url = large
                    } else {
                        url = try await client.startLiveview(size: nil)
                    }
                    let streamer = StreamingTask()
                    var parser = LiveviewStreamParser()
                    for try await chunk in streamer.start(url: url) {
                        if Task.isCancelled { streamer.cancel(); break }
                        for f in parser.append(chunk) { cont.yield(f.jpeg) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func setShutterSpeed(_ v: String) async throws { try await client.setShutterSpeed(v) }
    public func setFNumber(_ v: String) async throws { try await client.setFNumber(v) }
    public func setISO(_ v: String) async throws { try await client.setIsoSpeedRate(v) }
    public func setWhiteBalance(mode: String, colorTemp: Int?) async throws { try await client.setWhiteBalance(mode: mode, colorTemp: colorTemp) }
    public func setExposureCompensation(index: Int) async throws { try await client.setExposureCompensation(index: index) }
    public func setFocusMode(_ v: String) async throws { try await client.setFocusMode(v) }
    public func setExposureMode(_ v: String) async throws { try await client.setExposureMode(v) }
    public func setShootMode(_ v: String) async throws { try await client.setShootMode(v) }
    public func autofocus() async throws {
        try await client.actHalfPressShutter()
        try? await Task.sleep(for: .milliseconds(1200))
        try? await client.cancelHalfPressShutter()
    }
    public func takePicture() async throws { _ = try await client.actTakePicture() }
    public func startMovie() async throws { try await client.startMovieRec() }
    public func stopMovie() async throws { try await client.stopMovieRec() }
    public func touchAF(x: Double, y: Double) async throws { _ = try await client.setTouchAFPosition(x: x, y: y) }
    public func cancelTouchAF() async throws { try await client.cancelTouchAFPosition() }
}

/// Small lock-protected holder so the event loop can merge deltas into a snapshot.
final class StateBox: @unchecked Sendable {
    private var state = CameraState()
    private let lock = NSLock()
    func get() -> CameraState { lock.lock(); defer { lock.unlock() }; return state }
    func set(_ s: CameraState) { lock.lock(); state = s; lock.unlock() }
    @discardableResult
    func update(_ f: (inout CameraState) -> Void) -> CameraState { lock.lock(); defer { lock.unlock() }; f(&state); return state }
}
