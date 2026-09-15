import Foundation

public enum CameraTransportKind: String, Sendable { case wifi = "Wi-Fi", usb = "USB" }

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
}

public struct UnsupportedOperation: Error, LocalizedError, Sendable {
    public let what: String
    public init(_ what: String) { self.what = what }
    public var errorDescription: String? { "\(what) is not available over this connection" }
}
