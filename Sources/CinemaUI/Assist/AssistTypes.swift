import Foundation
import CoreGraphics

/// What the analyzer measured on the latest frame. All rects and points are normalised to the
/// displayed picture with a top-left origin, the convention `touchAF` and `FrameOverlays` use.
public struct SceneMeasurements: Sendable, Equatable {
    public struct Face: Sendable, Equatable {
        public var rect: CGRect
        public var luma: Double        // mean luma of the rect, 0–100 (IRE-like)
        public var sharpness: Double   // Laplacian variance inside the rect
        public init(rect: CGRect, luma: Double, sharpness: Double) { self.rect = rect; self.luma = luma; self.sharpness = sharpness }
        public var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    }
    public var faces: [Face] = []            // largest first
    public var afSharpness: Double = 0       // FocusAnalyzer ratio at the AF point (or centre), 0…1
    public var sharpestRegion: CGPoint = CGPoint(x: 0.5, y: 0.5)
    public var sharpestScore: Double = 0     // Laplacian variance of the sharpest tile
    public var meanLuma: Double = 0          // whole frame, 0–100
    public var blackClip: Double = 0         // fraction of pixels ≤ 2/255
    public var whiteClip: Double = 0         // fraction of pixels ≥ 253/255
    public var horizonDegrees: Double?       // nil when Vision finds no horizon
    public var timestamp = Date()
    public init() {}
}

public enum FindingKind: String, Sendable { case exposure, focus, framing, settings }
public enum Severity: Sendable, Equatable { case info, warn }

/// A camera change the operator can apply with one tap. Built only by `AssistRules`.
public struct Fix: Sendable, Equatable {
    public enum Command: Sendable, Equatable {
        case setISO(String)
        case setExposureCompensation(index: Int)
        case setShutterSpeed(String)
        case touchAF(x: Double, y: Double)
        case autofocus
    }
    public var label: String      // "EI 800 → 1600", "AF ON FACE", "1/50 → 1/48"
    public var command: Command
    public init(label: String, command: Command) { self.label = label; self.command = command }
}

public struct Finding: Sendable, Equatable, Identifiable {
    public var id: String         // stable per rule, e.g. "face-under"
    public var kind: FindingKind
    public var severity: Severity
    public var fact: String       // fallback HUD text, uppercase, ≤ 32 chars
    public var detail: String     // one sentence for the model
    public var fix: Fix?
    public init(id: String, kind: FindingKind, severity: Severity, fact: String, detail: String, fix: Fix? = nil) {
        self.id = id; self.kind = kind; self.severity = severity; self.fact = fact; self.detail = detail; self.fix = fix
    }
}

/// One HUD line: a finding's fact, or the model's phrasing of it.
public struct AdviceLine: Sendable, Equatable, Identifiable {
    public var id: String          // the finding id
    public var text: String        // uppercase, ≤ 40 chars
    public var fromModel: Bool
    public init(id: String, text: String, fromModel: Bool) { self.id = id; self.text = text; self.fromModel = fromModel }
}
