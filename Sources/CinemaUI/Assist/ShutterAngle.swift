import Foundation

/// Shutter speed ⇄ shutter angle for a project frame rate. Shared by the top strip and the assist rules.
public enum ShutterAngle {
    /// Exposure time in seconds for a Sony speed string ("1/50", "2\"", "0.5"). nil for BULB / "--".
    public static func seconds(_ s: String) -> Double? {
        if s.uppercased() == "BULB" || s == "--" { return nil }
        if s.hasSuffix("\"") { return Double(s.dropLast()) }
        let p = s.split(separator: "/")
        if p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b > 0 { return a / b }
        return Double(s)
    }
    public static func degrees(speed: String?, fps: Int) -> Double? {
        guard let speed, let secs = seconds(speed) else { return nil }
        return 360.0 * Double(fps) * secs
    }
    /// "172.8", "360+" or "--" as shown in the strip.
    public static func label(speed: String?, fps: Int) -> String {
        guard let d = degrees(speed: speed, fps: fps) else { return "--" }
        return d > 360 ? "360+" : String(format: "%.1f", d)
    }
    /// The candidate whose angle is closest to 180° at `fps`.
    public static func nearest180(candidates: [String], fps: Int) -> String? {
        candidates.compactMap { c in degrees(speed: c, fps: fps).map { (c, abs($0 - 180)) } }
            .min { $0.1 < $1.1 }?.0
    }
}
