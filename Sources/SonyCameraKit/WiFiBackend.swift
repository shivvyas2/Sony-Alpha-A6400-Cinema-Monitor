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
        if apis.contains("setPostviewImageSize") { try? await client.setPostviewImageSize("Original") }
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
                        // Shots fired on the body show up here as takePictureUrl; app shots too, deduplicated below.
                        let fresh = s.lastPictureURLs.compactMap { URL(string: $0) }
                        if !fresh.isEmpty { Task { await self.download(fresh) } }
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
        Task { await self.download(list) }
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
    private func download(_ urls: [URL]) async {
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
