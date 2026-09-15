import Foundation
import CoreImage

/// Camera picture profile the operator has set on the body. The app cannot switch it remotely on the
/// α6400, but it tells the monitor which log curve the feed is in so the LOG button can apply the right LUT.
public enum PictureProfile: String, CaseIterable, Identifiable {
    case standard = "Standard / PP1–PP6"
    case pp7 = "PP7 · S-Log2 / S-Gamut"
    case pp8 = "PP8 · S-Log3 / S-Gamut3.Cine"
    case pp9 = "PP9 · S-Log3 / S-Gamut3"
    case pp10 = "PP10 · HLG / BT.2020"
    public var id: String { rawValue }
    public var short: String {
        switch self { case .standard: return "STD"; case .pp7: return "SLOG2"; case .pp8, .pp9: return "SLOG3"; case .pp10: return "HLG" }
    }
    public var isLog: Bool { self != .standard }
}

/// Builds 3D LUT data for CIColorCube: either a built-in log → Rec.709 conversion or a loaded .cube file.
public enum LUTBuilder {
    public static let dimension = 33

    /// Display transform for a profile (nil for Standard, which needs none).
    public static func cube(for profile: PictureProfile) -> Data? {
        switch profile {
        case .standard: return nil
        case .pp7: return build(curve: slog2ToLinear, matrix: sGamut3ToRec709)
        case .pp8: return build(curve: slog3ToLinear, matrix: sGamut3CineToRec709)
        case .pp9: return build(curve: slog3ToLinear, matrix: sGamut3ToRec709)
        case .pp10: return build(curve: hlgToLinear, matrix: bt2020ToRec709)
        }
    }

    // MARK: Curves (Sony technical summaries; input is the full-range 0…1 code value)

    static func slog3ToLinear(_ x: Float) -> Float {
        let cv = x * 1023
        if cv >= 171.2102946929 {
            return powf(10, (cv - 420) / 261.5) * (0.18 + 0.01) - 0.01
        }
        return (cv - 95) * 0.01125000 / (171.2102946929 - 95)
    }

    static func slog2ToLinear(_ x: Float) -> Float {
        // S-Log2 is defined on legal range (64…940); the camera's live view is full range.
        let y = (x * 1023 - 64) / (940 - 64)
        if y >= 0.030001222851889303 {
            return 219 * (powf(10, (y - 0.616596 - 0.03) / 0.432699) - 0.037584) / 155 * 0.9
        }
        return (y - 0.030001222851889303) / 3.53881278538813 * 0.9
    }

    static func hlgToLinear(_ x: Float) -> Float {
        let a: Float = 0.17883277, b: Float = 0.28466892, c: Float = 0.55991073
        let e: Float = x <= 0.5 ? (x * x) / 3 : (expf((x - c) / a) + b) / 12
        return e * 0.18 / 0.2      // HLG places diffuse white at ~0.75 signal; scale so mid grey lands at 0.18
    }

    // MARK: Matrices (camera gamut → Rec.709, D65)

    static let sGamut3CineToRec709: [Float] = [1.6269474, -0.5401385, -0.0868089,
                                                -0.1785155, 1.4179409, -0.2394254,
                                                -0.0135911, -0.2467749, 1.2603661]
    static let sGamut3ToRec709: [Float] = [1.7135, -0.5686, -0.1449,
                                            -0.1493, 1.2814, -0.1321,
                                            -0.0067, -0.1024, 1.1091]
    static let bt2020ToRec709: [Float] = [1.6605, -0.5876, -0.0728,
                                           -0.1246, 1.1329, -0.0083,
                                           -0.0182, -0.1006, 1.1187]

    /// Scene-linear → display: gentle highlight roll-off, then the Rec.709 curve.
    static func linearToDisplay(_ v: Float) -> Float {
        var x = max(0, v)
        if x > 0.75 { x = 0.75 + 0.25 * (1 - expf(-(x - 0.75) / 0.25)) }   // soft knee to white
        x = min(1, x)
        return x < 0.018 ? 4.5 * x : 1.099 * powf(x, 0.45) - 0.099
    }

    private static func build(curve: (Float) -> Float, matrix m: [Float]) -> Data {
        let n = dimension
        var out = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0 ..< n { for g in 0 ..< n { for r in 0 ..< n {
            let lr = curve(Float(r) / Float(n - 1)), lg = curve(Float(g) / Float(n - 1)), lb = curve(Float(b) / Float(n - 1))
            let rr = m[0] * lr + m[1] * lg + m[2] * lb
            let gg = m[3] * lr + m[4] * lg + m[5] * lb
            let bb = m[6] * lr + m[7] * lg + m[8] * lb
            out[i] = linearToDisplay(rr); out[i + 1] = linearToDisplay(gg); out[i + 2] = linearToDisplay(bb); out[i + 3] = 1
            i += 4
        } } }
        return Data(bytes: out, count: out.count * 4)
    }

    /// Parses a .cube 3D LUT (Resolve / Adobe format). Returns cube data and its dimension.
    public static func loadCube(_ url: URL) throws -> (Data, Int) {
        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var values: [Float] = []
        var domainMin: [Float] = [0, 0, 0], domainMax: [Float] = [1, 1, 1]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            let parts = line.split(separator: " ").map(String.init)
            if parts[0] == "LUT_3D_SIZE", parts.count >= 2 { size = Int(parts[1]) ?? 0; continue }
            if parts[0] == "LUT_1D_SIZE" { throw LUTError.unsupported("1D LUTs are not supported") }
            if parts[0] == "DOMAIN_MIN", parts.count >= 4 { domainMin = parts[1...3].compactMap(Float.init); continue }
            if parts[0] == "DOMAIN_MAX", parts.count >= 4 { domainMax = parts[1...3].compactMap(Float.init); continue }
            if parts.count >= 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                let scale = { (v: Float, i: Int) -> Float in (v - domainMin[i]) / max(1e-6, domainMax[i] - domainMin[i]) }
                values += [scale(r, 0), scale(g, 1), scale(b, 2), 1]
            }
        }
        guard size >= 2, values.count == size * size * size * 4 else { throw LUTError.unsupported("Malformed .cube (expected \(size)³ entries)") }
        return (Data(bytes: values, count: values.count * 4), size)
    }

    public enum LUTError: LocalizedError {
        case unsupported(String)
        public var errorDescription: String? { if case .unsupported(let m) = self { return m }; return nil }
    }
}
