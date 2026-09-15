import Foundation
import SonyCameraKit

/// The text the on-device model sees. Compact key=value lines; the model never sees pixels.
public enum AdvisorPrompt {
    public static let instructions = """
    You are the on-set assistant on a cinema monitor for a Sony α6400. You receive camera settings, \
    measurements of the live frame, and findings; you do not see the picture. Reply with at most two \
    lines, most important first. Each line explains one finding in at most eight words, in the clipped \
    voice of a camera assistant. Never suggest values; fixes are attached separately.
    """

    public static func build(findings: [Finding], measurements m: SceneMeasurements, state s: CameraState,
                             profile: PictureProfile, projectFPS: Int) -> String {
        var lines: [String] = []
        lines.append("camera: mode=\(s.exposureMode ?? "--") shutter=\(s.shutterSpeed ?? "--") (\(ShutterAngle.label(speed: s.shutterSpeed, fps: projectFPS))°) "
                     + "iris=F\(s.fNumber ?? "--") ei=\(s.iso ?? "--") ev=\(s.exposureCompensation?.label ?? "--") wb=\(s.whiteBalanceMode ?? "--") "
                     + "focus=\(s.focusMode ?? "--")/\(s.focusStatus ?? "--") profile=\(profile.short) fps=\(projectFPS)")
        var meas = "frame: mean_luma=\(Int(m.meanLuma.rounded())) white_clip=\(Int((m.whiteClip * 100).rounded()))% black_clip=\(Int((m.blackClip * 100).rounded()))% af_sharpness=\(String(format: "%.2f", m.afSharpness))"
        if let f = m.faces.first {
            meas += " faces=\(m.faces.count) face_luma=\(Int(f.luma.rounded())) face_x=\(String(format: "%.2f", f.center.x)) face_y=\(String(format: "%.2f", f.center.y))"
        } else { meas += " faces=0" }
        if let h = m.horizonDegrees { meas += " horizon=\(String(format: "%.1f", h))°" }
        lines.append(meas)
        lines.append("findings:")
        for f in findings { lines.append("[\(f.id)] \(f.detail)") }
        return lines.joined(separator: "\n")
    }
}

/// Whether the on-device model can be used right now, and why not.
public enum ShotAdvisorAvailability: Equatable, Sendable {
    case available, appleIntelligenceOff, modelNotReady, deviceNotEligible, needsOS26

    public var reason: String? {
        switch self {
        case .available: return nil
        case .appleIntelligenceOff: return "Apple Intelligence is off in System Settings"
        case .modelNotReady: return "Apple Intelligence model is not ready yet"
        case .deviceNotEligible: return "This device does not support Apple Intelligence"
        case .needsOS26: return "Needs macOS 26 or later"
        }
    }

    public static var current: ShotAdvisorAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) { return ShotAdvisor.availability }
        #endif
        return .needsOS26
    }
}
