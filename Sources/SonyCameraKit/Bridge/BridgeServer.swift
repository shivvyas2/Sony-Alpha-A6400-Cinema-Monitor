import Foundation
import Network

/// Minimal HTTP server that shares the connected camera with iPhones and iPads on the local network:
///   GET  /state     JSON BridgeState
///   GET  /events    text/event-stream of BridgeState on every change (heartbeat every 5 s)
///   GET  /stream    endless byte stream of the camera's own JPEG frames, MJPEG-style framed, untouched
///   POST /cmd       JSON BridgeCommand → JSON BridgeReply
/// Advertised over Bonjour as `_cinemahud._tcp`.
public final class BridgeServer: @unchecked Sendable {
    public typealias StateProvider = @Sendable () async -> BridgeState?
    public typealias CommandHandler = @Sendable (BridgeCommand) async -> BridgeReply

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "cinemahud.bridge")
    private let frames: Broadcaster<Data>
    private let states: Broadcaster<BridgeState>
    private let state: StateProvider
    private let handler: CommandHandler
    public private(set) var port: UInt16 = 0
    public private(set) var isRunning = false
    private var connections: Set<ObjectIdentifier> = []
    private let lock = NSLock()
    public var clientCount: Int { lock.withLock { connections.count } }

    public init(name: String, frames: Broadcaster<Data>, states: Broadcaster<BridgeState>, state: @escaping StateProvider, handler: @escaping CommandHandler) {
        self.frames = frames; self.states = states; self.state = state; self.handler = handler
        self.serviceName = name
    }
    private let serviceName: String

    public func start(port: UInt16 = Bridge.defaultPort) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.service = NWListener.Service(name: serviceName, type: Bridge.serviceType)
        l.stateUpdateHandler = { [weak self] st in
            if case .ready = st { self?.port = l.port?.rawValue ?? port; self?.isRunning = true }
            if case .failed = st { self?.isRunning = false }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
    }

    public func stop() {
        listener?.cancel(); listener = nil; isRunning = false
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        lock.withLock { _ = connections.insert(id) }
        conn.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.lock.withLock { _ = self?.connections.remove(id) } }
            if case .cancelled = st { self?.lock.withLock { _ = self?.connections.remove(id) } }
        }
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let r = HTTPRequest.parse(buf) {
                Task { await self.handle(r, on: conn) }
            } else if error != nil || complete {
                conn.cancel()
            } else {
                self.readRequest(conn, buffer: buf)
            }
        }
    }

    private func handle(_ req: HTTPRequest, on conn: NWConnection) async {
        switch (req.method, req.path) {
        case ("GET", "/state"):
            let s = await state()
            send(conn, status: s == nil ? 503 : 200, type: "application/json", body: (try? JSONEncoder().encode(s)) ?? Data("{}".utf8))
        case ("POST", "/cmd"):
            guard let cmd = try? JSONDecoder().decode(BridgeCommand.self, from: req.body) else {
                send(conn, status: 400, type: "application/json", body: (try? JSONEncoder().encode(BridgeReply(ok: false, error: "bad command"))) ?? Data()); return
            }
            let reply = await handler(cmd)
            send(conn, status: 200, type: "application/json", body: (try? JSONEncoder().encode(reply)) ?? Data())
        case ("GET", "/events"):
            sendHead(conn, status: 200, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Connection": "keep-alive"])
            if let s = await state(), let d = try? JSONEncoder().encode(s) { write(conn, Data("data: ".utf8) + d + Data("\n\n".utf8)) }
            let stream = states.stream(buffering: .bufferingNewest(4))
            let heartbeat = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(5)); self.write(conn, Data(": ping\n\n".utf8)) } }
            for await s in stream {
                guard self.isOpen(conn) else { break }
                if let d = try? JSONEncoder().encode(s) { write(conn, Data("data: ".utf8) + d + Data("\n\n".utf8)) }
            }
            heartbeat.cancel(); conn.cancel()
        case ("GET", "/stream"):
            // Framed like MJPEG (boundary + Content-Length per frame) but declared as a plain byte stream:
            // Apple's URLSession special-cases multipart/x-mixed-replace and never delivers the response.
            sendHead(conn, status: 200, headers: ["Content-Type": "application/octet-stream", "Cache-Control": "no-cache", "Connection": "keep-alive"])
            for await jpeg in frames.stream(buffering: .bufferingNewest(1)) {
                guard self.isOpen(conn) else { break }
                var part = Data("--\(Bridge.streamBoundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
                part.append(jpeg); part.append(Data("\r\n".utf8))
                write(conn, part)
            }
            conn.cancel()
        case ("GET", "/"):
            send(conn, status: 200, type: "text/plain", body: Data("CinemaHUD bridge. Endpoints: /state /events /stream /cmd\n".utf8))
        default:
            send(conn, status: 404, type: "text/plain", body: Data("not found\n".utf8))
        }
    }

    private func isOpen(_ conn: NWConnection) -> Bool {
        if case .ready = conn.state { return true }
        return false
    }

    private func sendHead(_ conn: NWConnection, status: Int, headers: [String: String]) {
        var h = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nAccess-Control-Allow-Origin: *\r\n"
        for (k, v) in headers { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        write(conn, Data(h.utf8))
    }

    private func send(_ conn: NWConnection, status: Int, type: String, body: Data) {
        sendHead(conn, status: status, headers: ["Content-Type": type, "Content-Length": "\(body.count)", "Connection": "close"])
        conn.send(content: body, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func write(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in })
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    /// Returns nil until a full request (headers + declared body) is buffered.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex ..< headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let request = lines.first else { return nil }
        lines.removeFirst()
        let parts = request.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            if let i = l.firstIndex(of: ":") { headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        let body = data[bodyStart ..< bodyStart + length]
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        return HTTPRequest(method: String(parts[0]), path: path, headers: headers, body: Data(body))
    }
}
