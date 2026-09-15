import Foundation

public enum CameraTransportKind: String, Sendable { case wifi = "Wi-Fi", usb = "USB", bridge = "Mac" }

/// Everything `CameraSession` needs from a camera, regardless of transport.
public protocol CameraBackend: AnyObject, Sendable {
    var kind: CameraTransportKind { get }
    var displayName: String { get async }

    /// Establish the session and return the initial state.
    func connect() async throws -> CameraState
    func disconnect() async

    /// Stream of full state snapshots. Ends or throws when the connection is lost.
    func stateUpdates() -> AsyncThrowingStream<CameraState, Error>
    /// Stream of JPEG frames. Ends or throws when the connection is lost.
    func liveviewFrames() -> AsyncThrowingStream<Data, Error>

    func setShutterSpeed(_ v: String) async throws
    func setFNumber(_ v: String) async throws
    func setISO(_ v: String) async throws
    func setWhiteBalance(mode: String, colorTemp: Int?) async throws
    func setExposureCompensation(index: Int) async throws
    func setFocusMode(_ v: String) async throws
    func setExposureMode(_ v: String) async throws
    func setShootMode(_ v: String) async throws
    func autofocus() async throws
    func takePicture() async throws
    func startMovie() async throws
    func stopMovie() async throws
    /// x, y are percentages (0…100) of the frame.
    func touchAF(x: Double, y: Double) async throws
    func cancelTouchAF() async throws
    /// Files the camera hands over after each shot (app- or body-triggered), as they land on disk.
    func captureEvents() -> AsyncStream<CaptureEvent>
}

public struct UnsupportedOperation: Error, LocalizedError, Sendable {
    public let what: String
    public init(_ what: String) { self.what = what }
    public var errorDescription: String? { "\(what) is not available over this connection" }
}

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

public extension CameraBackend {
    /// Power-zoom lenses over Wi-Fi only (`actZoom`); no zoom drive exists in the α6400's USB protocol.
    func zoom(_ direction: ZoomDirection, _ movement: ZoomMovement) async throws { throw UnsupportedOperation("Zoom") }
    func setStillSize(_ s: StillSize) async throws { throw UnsupportedOperation("Still size") }
    func setMovieQuality(_ v: String) async throws { throw UnsupportedOperation("Movie quality") }
    func setMovieFileFormat(_ v: String) async throws { throw UnsupportedOperation("Movie file format") }
}
