import Foundation
import SonyCameraKit

/// The text the on-device model sees. Plain sentences, because the model's language check rejects
/// terse key=value dumps as "unsupported language"; the model never sees pixels.
public enum AdvisorPrompt {
    public static let instructions = """
    You are the first assistant camera on a film set, reading a cinema monitor for a Sony a6400. You get \
    the camera settings, measurements of the live frame, and findings; you never see the picture. For each \
    finding, call it out to the operator in three to six words: what is wrong with the shot and what it \
    does to the image. Do not repeat the numbers, do not copy the finding text, and use the finding id \
    exactly as written. Never suggest values or name settings; fixes are attached separately. Examples \
    of the voice: Face buried in shadow. Skin blowing out, pull it back. Focus sitting behind the subject. \
    Shutter too fast, motion will strobe. Horizon leaning left. Losing headroom, tilt up.
    """

    public static func build(findings: [Finding], measurements m: SceneMeasurements, state s: CameraState,
                             profile: PictureProfile, projectFPS: Int) -> String {
        var lines: [String] = []
        let angle = ShutterAngle.label(speed: s.shutterSpeed, fps: projectFPS)
        lines.append("Camera: \(s.exposureMode ?? "unknown") mode, shutter \(s.shutterSpeed ?? "unknown") (\(angle) degree angle at \(projectFPS) fps), "
                     + "iris F\(s.fNumber ?? "unknown"), EI \(s.iso ?? "unknown"), exposure compensation \(s.exposureCompensation?.label ?? "0"), "
                     + "white balance \(s.whiteBalanceMode ?? "unknown"), focus \(s.focusMode ?? "unknown") reporting \(s.focusStatus ?? "unknown"), "
                     + "picture profile \(profile.short).")
        var frame = "Frame: mean luma \(Int(m.meanLuma.rounded())) of 100, \(Int((m.whiteClip * 100).rounded())) percent clipped white, "
                  + "\(Int((m.blackClip * 100).rounded())) percent crushed black, focus-point sharpness \(String(format: "%.2f", m.afSharpness)) of 1"
        if let f = m.faces.first {
            frame += ", \(m.faces.count == 1 ? "one face" : "\(m.faces.count) faces, the largest") at \(Int(f.luma.rounded())) luma near x \(String(format: "%.2f", f.center.x)) y \(String(format: "%.2f", f.center.y))"
        } else { frame += ", no faces" }
        if let h = m.horizonDegrees { frame += ", horizon tilted \(String(format: "%.1f", h)) degrees" }
        lines.append(frame + ".")
        lines.append("Findings:")
        for f in findings { lines.append("[\(f.id)] \(f.fact.capitalized): \(f.detail)") }
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
