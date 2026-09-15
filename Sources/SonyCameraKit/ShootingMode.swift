import Foundation

public enum ShootingMode: String, Sendable, CaseIterable { case video = "VIDEO", photo = "PHOTO" }

/// The app's mode follows the camera's mode dial. A manual toggle overrides it until the dial next moves.
public struct ShootingModeResolver: Sendable, Equatable {
    public private(set) var mode: ShootingMode
    public private(set) var overridden = false
    private var lastDial: String?

    public init(mode: ShootingMode = .video) { self.mode = mode }

    public static func mode(forDial shootMode: String?) -> ShootingMode? {
        switch shootMode {
        case "still": return .photo
        case "movie": return .video
        default: return nil
        }
    }

    /// Feed every state update. The mode changes only when the dial position actually changes.
    public mutating func dial(_ shootMode: String?) {
        guard shootMode != lastDial else { return }
        lastDial = shootMode
        if let m = Self.mode(forDial: shootMode) { mode = m; overridden = false }
    }

    public mutating func toggle() {
        mode = mode == .video ? .photo : .video
        overridden = true
    }
}
