import Foundation

public struct SonyAPIError: Error, LocalizedError, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let method: String
    public init(code: Int, message: String, method: String) {
        self.code = code; self.message = message; self.method = method
    }
    public var errorDescription: String? { "\(method): \(message) (\(code))" }

    public static let notAvailableNow = 1
    public static let illegalArgument = 3
    public static let illegalRequest = 5
    public static let noSuchMethod = 12
    public static let shootingFail = 40400
    public static let cameraNotReady = 40401
}

/// Thin JSON-RPC client for the Sony Camera Remote API "camera" service.
public actor SonyCameraClient {
    public let endpoint: URL
    private let session: URLSession
    private var nextID = 1
    private var versions: [String: [String]] = [:]

    public init(serviceURL: URL, session: URLSession? = nil) {
        // serviceURL is e.g. http://192.168.122.1:8080/sony ; the camera service lives at /camera
        self.endpoint = serviceURL.appendingPathComponent("camera")
        if let session { self.session = session } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public static func encodeRequest(method: String, params: [JSON], id: Int, version: String) throws -> Data {
        try JSON.object(["method": .string(method), "params": .array(params),
                         "id": .number(Double(id)), "version": .string(version)]).encoded()
    }

    /// Performs a call and returns the `result` array (or `results` for getVersions-style methods).
    @discardableResult
    public func call(_ method: String, _ params: [JSON] = [], version: String = "1.0", timeout: TimeInterval = 15) async throws -> JSON {
        let id = nextID; nextID += 1
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try Self.encodeRequest(method: method, params: params, id: id, version: version)
        let (data, _) = try await session.data(for: req)
        let json = try JSON.parse(data)
        if let err = json["error"].array, err.count >= 2, let code = err[0].int {
            throw SonyAPIError(code: code, message: err[1].string ?? "error", method: method)
        }
        if !json["result"].isNull { return json["result"] }
        if !json["results"].isNull { return json["results"] }
        return .array([])
    }

    // MARK: - Typed helpers

    public func getAvailableApiList() async throws -> [String] {
        try await call("getAvailableApiList")[0].stringArray
    }

    public func getMethodTypes(version: String = "1.0") async throws -> JSON {
        try await call("getMethodTypes", [.string(version)])
    }

    /// Highest supported version of `getEvent`, cached.
    public func bestEventVersion() async -> String {
        if let v = versions["getEvent"] { return v.last ?? "1.0" }
        var found: [String] = ["1.0"]
        if let list = try? await call("getVersions").array?.first?.stringArray {
            let supported = list.filter { ["1.0", "1.1", "1.2", "1.3"].contains($0) }.sorted()
            if !supported.isEmpty { found = supported }
        }
        versions["getEvent"] = found
        return found.last ?? "1.0"
    }

    public func getEvent(longPolling: Bool, version: String) async throws -> JSON {
        try await call("getEvent", [.bool(longPolling)], version: version, timeout: longPolling ? 60 : 15)
    }

    public func startRecMode() async throws { try await call("startRecMode") }
    public func stopRecMode() async throws { try await call("stopRecMode") }

    public func startLiveview(size: String?) async throws -> URL {
        let result: JSON
        if let size {
            result = try await call("startLiveviewWithSize", [.string(size)])
        } else {
            result = try await call("startLiveview")
        }
        guard let s = result[0].string, let url = URL(string: s) else {
            throw SonyAPIError(code: -1, message: "bad liveview URL", method: "startLiveview")
        }
        return url
    }
    public func stopLiveview() async throws { try await call("stopLiveview") }

    public func setShutterSpeed(_ v: String) async throws { try await call("setShutterSpeed", [.string(v)]) }
    public func setFNumber(_ v: String) async throws { try await call("setFNumber", [.string(v)]) }
    public func setIsoSpeedRate(_ v: String) async throws { try await call("setIsoSpeedRate", [.string(v)]) }
    public func setExposureCompensation(index: Int) async throws { try await call("setExposureCompensation", [.number(Double(index))]) }
    public func setFocusMode(_ v: String) async throws { try await call("setFocusMode", [.string(v)]) }
    public func setExposureMode(_ v: String) async throws { try await call("setExposureMode", [.string(v)]) }
    public func setShootMode(_ v: String) async throws { try await call("setShootMode", [.string(v)]) }
    public func setWhiteBalance(mode: String, colorTemp: Int?) async throws {
        try await call("setWhiteBalance", [.string(mode), .bool(colorTemp != nil), .number(Double(colorTemp ?? 0))])
    }
    public func actHalfPressShutter() async throws { try await call("actHalfPressShutter") }
    public func cancelHalfPressShutter() async throws { try await call("cancelHalfPressShutter") }
    public func actTakePicture() async throws -> [String] { try await call("actTakePicture")[0].stringArray }
    /// "Original" makes the postview the full-size JPEG instead of a 2M proxy.
    public func setPostviewImageSize(_ size: String) async throws { try await call("setPostviewImageSize", [.string(size)]) }
    /// Polled after `actTakePicture` answers 40403 (still capturing); returns the postview URLs once ready.
    public func awaitTakePicture() async throws -> [String] { try await call("awaitTakePicture")[0].stringArray }
    public func startMovieRec() async throws { try await call("startMovieRec") }
    public func stopMovieRec() async throws { try await call("stopMovieRec") }
    /// x, y are percentages 0...100 of the liveview image.
    public func setTouchAFPosition(x: Double, y: Double) async throws -> Bool {
        let r = try await call("setTouchAFPosition", [.number(x), .number(y)])
        return r[0]["AFResult"].bool ?? false
    }
    public func cancelTouchAFPosition() async throws { try await call("cancelTouchAFPosition") }
    public func actZoom(direction: String, movement: String) async throws {
        try await call("actZoom", [.string(direction), .string(movement)])
    }
    public func setStillSize(aspect: String, size: String) async throws { try await call("setStillSize", [.string(aspect), .string(size)]) }
    public func getSupportedStillSize() async throws -> [StillSize] { StillSize.list(from: try await call("getSupportedStillSize")[0]) }
    public func setMovieQuality(_ v: String) async throws { try await call("setMovieQuality", [.string(v)]) }
    public func getSupportedMovieQuality() async throws -> [String] { try await call("getSupportedMovieQuality")[0].stringArray }
    public func setMovieFileFormat(_ v: String) async throws { try await call("setMovieFileFormat", [.string(v)]) }
    public func getSupportedMovieFileFormat() async throws -> [String] { try await call("getSupportedMovieFileFormat")[0].stringArray }
}
