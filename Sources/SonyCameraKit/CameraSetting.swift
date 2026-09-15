import Foundation

/// A camera property exposed generically (drive mode, metering, DRO, …) for the settings menu.
public struct CameraSetting: Identifiable, Sendable, Equatable {
    public let id: String          // stable key, e.g. "0x5013"
    public let name: String
    public let group: String
    public var current: String
    public var candidates: [String]
    public var settable: Bool
    public init(id: String, name: String, group: String, current: String, candidates: [String], settable: Bool) {
        self.id = id; self.name = name; self.group = group; self.current = current; self.candidates = candidates; self.settable = settable
    }
}

public enum CameraButton: String, Sendable { case aeLock = "AEL", feLock = "FEL", oneShot = "ONE SHOT" }

public extension CameraBackend {
    func settings() async -> [CameraSetting] { [] }
    func setSetting(id: String, value: String) async throws { throw UnsupportedOperation("Setting \(id)") }
    /// Manual focus drive: negative = near, positive = far; magnitude 1…7 is the step size.
    func focusDrive(steps: Int) async throws { throw UnsupportedOperation("Focus drive") }
    func press(_ button: CameraButton) async throws { throw UnsupportedOperation(button.rawValue) }
}
