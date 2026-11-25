import Foundation

/// Client side of the bridge: talks to a Mac running CinemaHUD instead of the camera directly.
public final class BridgeBackend: CameraBackend, @unchecked Sendable {
    public let kind: CameraTransportKind = .bridge
    public let baseURL: URL
    private var session: URLSession
    private var last: BridgeState?
    private let lock = NSLock()
    private let captures = CaptureBroadcaster()
    public var saveDirectory: URL = CaptureStore.defaultBase
    private var shotTask: Task<Void, Never>?
    private var wantsShots = false
    private let defaults: UserDefaults
    private static let seenKey = "bridgeShotsReceived"

    public var displayName: String { lock.withLock { last?.cameraName } ?? baseURL.host ?? "Mac" }
    /// What the Mac itself is connected through (USB / Wi-Fi).
    public var bridgedTransport: String { lock.withLock { last?.transport } ?? "" }

    public init(baseURL: URL, defaults: UserDefaults = .standard) {
        self.baseURL = baseURL
        self.defaults = defaults
        session = Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = .infinity
        return URLSession(configuration: cfg)
    }

    private var current: URLSession { lock.withLock { session } }

    public func connect() async throws -> CameraState {
        let (data, resp) = try await current.data(from: baseURL.appendingPathComponent("state"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UnsupportedOperation("The Mac has no camera connected") }
        let s = try JSONDecoder().decode(BridgeState.self, from: data)
        lock.withLock { last = s }
        if lock.withLock({ wantsShots }) { startFollowing() }
        return s.cameraState
    }

    /// `connect` may follow on the same backend (CameraSession.reconnect), so a fresh URLSession is put in place.
    public func disconnect() async {
        let (task, old) = lock.withLock { () -> (Task<Void, Never>?, URLSession) in
            defer { shotTask = nil; session = Self.makeSession() }
            return (shotTask, session)
        }
        task?.cancel()
        old.invalidateAndCancel()
    }

    // MARK: Photos

    public func captureEvents() -> AsyncStream<CaptureEvent> {
        let stream = captures.stream()
        lock.withLock { wantsShots = true }
        startFollowing()
        return stream
    }

    private func startFollowing() {
        lock.withLock { if shotTask == nil { shotTask = Task { [weak self] in await self?.followShots() } } }
    }

    /// Copies every JPEG the Mac has this session, each one once: those from before this device connected, the new
    /// ones as they land, and after a drop whatever was missed.
    private func followShots() async {
        var wait = 1.0, toldOld = false
        while !Task.isCancelled {
            let streamer = StreamingTask()
            do {
                var buffer = Data()
                for try await chunk in streamer.start(url: baseURL.appendingPathComponent("shots")) {
                    if Task.isCancelled { break }
                    if streamer.statusCode == 404 { break }
                    buffer.append(chunk)
                    while let r = buffer.range(of: Data("\n\n".utf8)) {
                        let event = String(decoding: buffer[buffer.startIndex ..< r.lowerBound], as: UTF8.self)
                        buffer.removeSubrange(buffer.startIndex ..< r.upperBound)
                        if event == ": ready" { wait = 1; continue }
                        guard event.hasPrefix("data: "), let s = try? JSONDecoder().decode(BridgeShot.self, from: Data(event.dropFirst(6).utf8)) else { continue }
                        if !received.contains(s.id.uuidString) { await fetch(s) }
                        if Task.isCancelled { break }
                    }
                }
            } catch {}
            let old = streamer.statusCode == 404
            streamer.cancel()
            if Task.isCancelled { return }
            if old {
                if !toldOld { toldOld = true; captures.send(.failed(shotIndex: -1, message: "Update CinemaHUD on the Mac to receive photos")) }
                wait = 30
            }
            try? await Task.sleep(for: .seconds(wait))
            wait = min(30, wait * 2)
        }
    }

    /// Ids of photos this device already has, kept across launches so nothing lands in Photos twice.
    private var received: [String] {
        get { defaults.stringArray(forKey: Self.seenKey) ?? [] }
        set { defaults.set(Array(newValue.suffix(1000)), forKey: Self.seenKey) }
    }

    private func fetch(_ s: BridgeShot) async {
        for attempt in 1 ... 3 {
            do {
                let (data, resp) = try await current.data(from: baseURL.appendingPathComponent("shot/\(s.id.uuidString)"))
                guard (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw URLError(.badServerResponse) }
                let name = (s.filename as NSString).lastPathComponent
                let file = try CaptureStore.write(data, base: saveDirectory, filename: name, date: s.takenAt)
                received.append(s.id.uuidString)
                captures.send(.image(CapturedImage(url: file, kind: .jpeg, filename: name, takenAt: s.takenAt, shotIndex: s.shotIndex, id: s.id, catchUp: s.replay)))
                captures.send(.finished(shotIndex: s.shotIndex))
                return
            } catch {
                if Task.isCancelled { return }
                if attempt == 3 { captures.send(.failed(shotIndex: -1, message: "Photo transfer from the Mac failed: \(error.localizedDescription)")); return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // Endless responses go through the delegate-based StreamingTask: URLSession's async `bytes(from:)`
    // never delivers the response for a body with no end.

    public func stateUpdates() -> AsyncThrowingStream<CameraState, Error> {
        AsyncThrowingStream { cont in
            let streamer = StreamingTask()
            let task = Task {
                do {
                    var buffer = Data()
                    for try await chunk in streamer.start(url: baseURL.appendingPathComponent("events")) {
                        if Task.isCancelled { streamer.cancel(); break }
                        buffer.append(chunk)
                        while let r = buffer.range(of: Data("\n\n".utf8)) {
                            let event = String(decoding: buffer[buffer.startIndex ..< r.lowerBound], as: UTF8.self)
                            buffer.removeSubrange(buffer.startIndex ..< r.upperBound)
                            for line in event.split(separator: "\n") where line.hasPrefix("data: ") {
                                if let s = try? JSONDecoder().decode(BridgeState.self, from: Data(line.dropFirst(6).utf8)) {
                                    lock.withLock { last = s }
                                    cont.yield(s.cameraState)
                                }
                            }
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel(); streamer.cancel() }
        }
    }

    public func liveviewFrames() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { cont in
            let streamer = StreamingTask()
            let task = Task {
                do {
                    var parser = MultipartJPEGParser()
                    for try await chunk in streamer.start(url: baseURL.appendingPathComponent("stream")) {
                        if Task.isCancelled { streamer.cancel(); break }
                        for f in parser.append(chunk) { cont.yield(f) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel(); streamer.cancel() }
        }
    }

    public func settings() async -> [CameraSetting] { lock.withLock { last?.cameraSettings } ?? [] }

    // MARK: Commands

    @discardableResult
    private func send(_ cmd: BridgeCommand) async throws -> BridgeReply {
        var req = URLRequest(url: baseURL.appendingPathComponent("cmd"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(cmd)
        let (data, _) = try await current.data(for: req)
        let reply = try JSONDecoder().decode(BridgeReply.self, from: data)
        if !reply.ok { throw UnsupportedOperation(reply.error ?? cmd.op) }
        return reply
    }

    public func setShutterSpeed(_ v: String) async throws { try await send(.init(op: "setShutterSpeed", value: v)) }
    public func setFNumber(_ v: String) async throws { try await send(.init(op: "setFNumber", value: v)) }
    public func setISO(_ v: String) async throws { try await send(.init(op: "setISO", value: v)) }
    public func setWhiteBalance(mode: String, colorTemp: Int?) async throws { try await send(.init(op: "setWhiteBalance", value: mode, index: colorTemp)) }
    public func setExposureCompensation(index: Int) async throws { try await send(.init(op: "setExposureCompensation", index: index)) }
    public func setFocusMode(_ v: String) async throws { try await send(.init(op: "setFocusMode", value: v)) }
    public func setExposureMode(_ v: String) async throws { try await send(.init(op: "setExposureMode", value: v)) }
    public func setShootMode(_ v: String) async throws { try await send(.init(op: "setShootMode", value: v)) }
    public func autofocus() async throws { try await send(.init(op: "autofocus")) }
    public func takePicture() async throws { try await send(.init(op: "takePicture")) }
    public func startMovie() async throws { try await send(.init(op: "startMovie")) }
    public func stopMovie() async throws { try await send(.init(op: "stopMovie")) }
    public func touchAF(x: Double, y: Double) async throws { try await send(.init(op: "touchAF", x: x, y: y)) }
    public func cancelTouchAF() async throws { try await send(.init(op: "cancelTouchAF")) }
    public func setSetting(id: String, value: String) async throws { try await send(.init(op: "setSetting", value: id, value2: value)) }
    public func focusDrive(steps: Int) async throws { try await send(.init(op: "focusDrive", index: steps)) }
    public func press(_ button: CameraButton) async throws { try await send(.init(op: "press", value: button.rawValue)) }
    public func zoom(_ direction: ZoomDirection, _ movement: ZoomMovement) async throws { try await send(.init(op: "zoom", value: direction.rawValue, value2: movement.rawValue)) }
    public func setStillSize(_ s: StillSize) async throws { try await send(.init(op: "setStillSize", value: s.aspect, value2: s.size)) }
    public func setMovieQuality(_ v: String) async throws { try await send(.init(op: "setMovieQuality", value: v)) }
    public func setMovieFileFormat(_ v: String) async throws { try await send(.init(op: "setMovieFileFormat", value: v)) }
}

/// Splits a multipart/x-mixed-replace stream into JPEG payloads using Content-Length headers.
struct MultipartJPEGParser {
    private var buffer = Data()
    mutating func append(_ d: Data) -> [Data] {
        buffer.append(d)
        var out: [Data] = []
        while true {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { break }
            let head = String(decoding: buffer[buffer.startIndex ..< headerEnd.lowerBound], as: UTF8.self)
            guard let lenLine = head.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let len = Int(lenLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) else {
                buffer.removeSubrange(buffer.startIndex ..< headerEnd.upperBound); continue
            }
            let start = headerEnd.upperBound
            guard buffer.count - (start - buffer.startIndex) >= len else { break }
            out.append(Data(buffer[start ..< start + len]))
            buffer.removeSubrange(buffer.startIndex ..< start + len)
        }
        return out
    }
}
