import Foundation

/// Client side of the bridge: talks to a Mac running CinemaHUD instead of the camera directly.
public final class BridgeBackend: CameraBackend, @unchecked Sendable {
    public let kind: CameraTransportKind = .bridge
    public let baseURL: URL
    private let session: URLSession
    private var last: BridgeState?
    private let lock = NSLock()
    private let captures = CaptureBroadcaster()

    public var displayName: String { lock.withLock { last?.cameraName } ?? baseURL.host ?? "Mac" }
    /// What the Mac itself is connected through (USB / Wi-Fi).
    public var bridgedTransport: String { lock.withLock { last?.transport } ?? "" }

    public init(baseURL: URL) {
        self.baseURL = baseURL
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: cfg)
    }

    public func connect() async throws -> CameraState {
        let (data, resp) = try await session.data(from: baseURL.appendingPathComponent("state"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UnsupportedOperation("The Mac has no camera connected") }
        let s = try JSONDecoder().decode(BridgeState.self, from: data)
        lock.withLock { last = s }
        return s.cameraState
    }

    public func disconnect() async { session.invalidateAndCancel() }

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

    public func captureEvents() -> AsyncStream<CaptureEvent> { captures.stream() }

    public func settings() async -> [CameraSetting] { lock.withLock { last?.cameraSettings } ?? [] }

    // MARK: Commands

    @discardableResult
    private func send(_ cmd: BridgeCommand) async throws -> BridgeReply {
        var req = URLRequest(url: baseURL.appendingPathComponent("cmd"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(cmd)
        let (data, _) = try await session.data(for: req)
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
