import Foundation
import CoreGraphics
import SonyCameraKit

/// Turns measurements plus camera state into findings. Pure; every fix is a command the connected
/// camera advertises. Order is priority order; at most four are returned.
public enum AssistRules {
    public static let stopThreshold = 0.66
    public static let maxFindings = 4

    /// Skin-tone target (0–100) for the camera's picture profile, measured before the display LUT.
    public static func skinTarget(for profile: PictureProfile) -> Double {
        switch profile {
        case .standard: return 55
        case .pp7: return 32
        case .pp8, .pp9: return 41
        case .pp10: return 45
        }
    }

    /// "1 STOP", "1.3 STOPS", "0.7 STOP": magnitude rounded to the nearest third.
    public static func stopsLabel(_ stops: Double) -> String {
        let thirds = (abs(stops) * 3).rounded() / 3
        if abs(thirds - 1) < 0.01 { return "1 STOP" }
        let text = String(format: "%.1f", thirds)
        return thirds < 1 ? "\(text) STOP" : "\(text) STOPS"
    }

    public static func findings(_ m: SceneMeasurements, state s: CameraState, profile: PictureProfile,
                                projectFPS: Int, shootingMode: ShootingMode, mist: Double = 0) -> [Finding] {
        var out: [Finding] = []
        let face = m.faces.first
        var faceFinding = false

        // Exposure on the face.
        if let face, face.luma > 0 {
            let target = skinTarget(for: profile)
            let stops = log2(face.luma / target)
            if abs(stops) >= stopThreshold {
                let under = stops < 0
                out.append(Finding(id: under ? "face-under" : "face-over", kind: .exposure, severity: .warn,
                                   fact: "FACE \(stopsLabel(stops)) \(under ? "UNDER" : "OVER")",
                                   detail: String(format: "The largest face reads %.0f; the skin target for %@ is %.0f (%.1f stops %@).",
                                                  face.luma, profile.short, target, abs(stops), under ? "under" : "over"),
                                   fix: exposureFix(stops: stops, state: s)))
                faceFinding = true
            }
        }
        if !faceFinding, m.whiteClip >= 0.02 {
            out.append(Finding(id: "highlights-clip", kind: .exposure, severity: .info, fact: "HIGHLIGHTS CLIPPING",
                               detail: String(format: "%.0f%% of pixels are clipped white.", m.whiteClip * 100)))
        }
        if !faceFinding, m.blackClip >= 0.10, m.meanLuma < 25 {
            out.append(Finding(id: "shadows-crush", kind: .exposure, severity: .info, fact: "SHADOWS CRUSHED",
                               detail: String(format: "%.0f%% of pixels are black and the frame averages %.0f.", m.blackClip * 100, m.meanLuma)))
        }

        // Focus.
        if let face, m.sharpestScore > 0, face.sharpness < 0.6 * m.sharpestScore,
           hypot(m.sharpestRegion.x - face.center.x, m.sharpestRegion.y - face.center.y) >= 0.15 {
            let fix = s.supports("setTouchAFPosition")
                ? Fix(label: "AF ON FACE", command: .touchAF(x: Double(face.center.x), y: Double(face.center.y))) : nil
            out.append(Finding(id: "focus-missed", kind: .focus, severity: .warn, fact: "FOCUS OFF SUBJECT",
                               detail: "The face is soft while a region away from it is sharp; focus is not on the subject.", fix: fix))
        }
        if s.focusStatus == "Failed" {
            out.append(Finding(id: "focus-failed", kind: .focus, severity: .warn, fact: "AF FAILED",
                               detail: "The camera reports autofocus failed.",
                               fix: s.supports("actHalfPressShutter") ? Fix(label: "AUTOFOCUS", command: .autofocus) : nil))
        }

        // Settings.
        if shootingMode == .video, let deg = ShutterAngle.degrees(speed: s.shutterSpeed, fps: projectFPS), deg < 150 || deg > 210 {
            var fix: Fix?
            if s.supports("setShutterSpeed"), let best = ShutterAngle.nearest180(candidates: s.shutterSpeedCandidates, fps: projectFPS),
               best != s.shutterSpeed, let cur = s.shutterSpeed {
                fix = Fix(label: "\(cur) → \(best)", command: .setShutterSpeed(best))
            }
            out.append(Finding(id: "shutter-angle", kind: .settings, severity: .info,
                               fact: "SHUTTER \(deg > 360 ? "360+" : String(format: "%.0f", deg))°",
                               detail: String(format: "Shutter %@ is a %.0f° angle at %d fps, %@ the 180° norm; %@.", s.shutterSpeed ?? "--", deg, projectFPS,
                                              deg < 180 ? "much narrower than" : "much wider than",
                                              deg < 180 ? "motion will look choppy and strobed" : "motion will smear"),
                               fix: fix))
        }

        // Framing.
        if let h = m.horizonDegrees, abs(h) >= 1.5 {
            out.append(Finding(id: "horizon", kind: .framing, severity: .info, fact: String(format: "HORIZON %.0f° OFF", abs(h)),
                               detail: String(format: "The horizon is tilted %.1f°.", h)))
        }
        if let face {
            if face.rect.minY < 0.02 {
                out.append(Finding(id: "headroom", kind: .framing, severity: .info, fact: "TOO TIGHT ON TOP",
                                   detail: "The face touches the top edge of the frame."))
            } else if face.center.y > 0.62 {
                out.append(Finding(id: "headroom", kind: .framing, severity: .info, fact: "SUBJECT LOW IN FRAME",
                                   detail: "The face sits in the lower third with empty space above it."))
            }
        }
        // Look: only when nothing is wrong, in video, with a person in frame. Suggestions toward a
        // softer, more cinematic image; the mist one is a monitor-side preview, not a camera change.
        if shootingMode == .video, let face, !out.contains(where: { $0.severity == .warn }) {
            if let cur = s.fNumber, let f = Double(cur), f >= 5.6, s.supports("setFNumber"),
               let widest = s.fNumberCandidates.compactMap({ c in Double(c).map { (c, $0) } }).min(by: { $0.1 < $1.1 }), widest.1 < f {
                out.append(Finding(id: "dof", kind: .look, severity: .info, fact: "OPEN UP FOR SOFT BACKGROUND",
                                   detail: String(format: "Iris F%@ with a person in frame keeps the background sharp; a wider iris gives shallow, cinematic depth of field.", cur),
                                   fix: Fix(label: "F\(cur) → F\(widest.0)", command: .setFNumber(widest.0))))
            }
            if mist == 0 {
                out.append(Finding(id: "mist", kind: .look, severity: .info, fact: "TRY MIST FOR A SOFTER LOOK",
                                   detail: "The picture is clean and sharp; the monitor's mist look adds halation around highlights and softens skin, as a diffusion filter would.",
                                   fix: Fix(label: "MIST ON", command: .monitorMist(0.5))))
            }
            _ = face
        }
        return Array(out.prefix(maxFindings))
    }

    /// ISO in manual modes, exposure compensation otherwise. nil when the camera cannot do it or is already there.
    static func exposureFix(stops: Double, state s: CameraState) -> Fix? {
        let mode = s.exposureMode ?? ""
        let manual = mode.hasPrefix("Manual") || mode == "Movie M"
        if manual {
            guard s.supports("setIsoSpeedRate"), let cur = s.iso, let curISO = Double(cur) else { return nil }
            let wanted = curISO * pow(2, -stops)
            let numeric = s.isoCandidates.compactMap { c in Double(c).map { (c, $0) } }
            guard let best = numeric.min(by: { abs(log2($0.1 / wanted)) < abs(log2($1.1 / wanted)) })?.0, best != cur else { return nil }
            return Fix(label: "EI \(cur) → \(best)", command: .setISO(best))
        }
        guard s.supports("setExposureCompensation"), let ev = s.exposureCompensation else { return nil }
        let delta = Int((-stops / ev.stepEV).rounded())
        let next = max(ev.minIndex, min(ev.maxIndex, ev.index + delta))
        guard next != ev.index else { return nil }
        func label(_ i: Int) -> String {
            let v = Double(i) * ev.stepEV
            return abs(v) < 0.01 ? "0" : String(format: "%@%.1f", v > 0 ? "+" : "", v)
        }
        return Fix(label: "EV \(label(ev.index)) → \(label(next))", command: .setExposureCompensation(index: next))
    }
}
