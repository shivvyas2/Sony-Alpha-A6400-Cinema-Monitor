import Foundation
import CoreImage
import CoreGraphics
import Vision
import SonyCameraKit

/// Measures the live frame for the assist rules: faces, sharpness, clipping, horizon. The
/// throttled entry point renders a ≤ 512-px copy off the main thread, like `LiveSharpnessMeter`.
public final class SceneAnalyzer: @unchecked Sendable {
    public static let maxLongEdge = 512
    public static let minInterval: TimeInterval = 0.25
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var inFlight = false
    private var last = Date.distantPast
    public init() {}

    /// Throttled: at most every `minInterval`, one pass at a time. `done` runs on the main actor.
    public func analyze(_ frame: CIImage, afPoint: CGPoint?, done: @escaping @MainActor (SceneMeasurements) -> Void) {
        guard !inFlight, Date().timeIntervalSince(last) >= Self.minInterval else { return }
        inFlight = true; last = Date()
        let ctx = context
        let scale = min(1, CGFloat(Self.maxLongEdge) / max(frame.extent.width, frame.extent.height))
        let small = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        Task.detached(priority: .utility) { [weak self] in
            let m = ctx.createCGImage(small, from: small.extent).map { Self.measure($0, afPoint: afPoint) }
            await MainActor.run {
                self?.inFlight = false
                if let m { done(m) }
            }
        }
    }

    /// Pure measurement of one image. `afPoint` is normalised, top-left origin; nil = centre.
    public static func measure(_ image: CGImage, afPoint: CGPoint?) -> SceneMeasurements {
        var m = SceneMeasurements()
        guard let l = FocusAnalyzer.luma(of: image, maxLongEdge: maxLongEdge) else { return m }

        // Luma statistics from the grey plane.
        var sum = 0, black = 0, white = 0
        for v in l.pixels { sum += Int(v); if v <= 2 { black += 1 } else if v >= 253 { white += 1 } }
        let n = Double(l.pixels.count)
        m.meanLuma = Double(sum) / n / 2.55
        m.blackClip = Double(black) / n
        m.whiteClip = Double(white) / n

        // Sharpness: the AF-point ratio the sharpness meter already uses, and the sharpest tile.
        if let r = FocusAnalyzer.analyze(image, afPoint: afPoint, regionFraction: 0.14, tiles: 8, maxLongEdge: maxLongEdge) {
            m.afSharpness = r.ratio
            m.sharpestRegion = r.peakPoint
            m.sharpestScore = r.peakScore
        }

        // Faces and horizon from Vision. Vision reports bottom-left-origin rects; flip once here so
        // everything downstream is top-left like the rest of the app.
        let faces = VNDetectFaceRectanglesRequest()
        let horizon = VNDetectHorizonRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([faces, horizon])
        m.faces = (faces.results ?? [])
            .map { obs -> SceneMeasurements.Face in
                let b = obs.boundingBox
                let rect = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                return SceneMeasurements.Face(rect: rect, luma: meanLuma(l, in: rect), sharpness: FocusAnalyzer.sharpness(l, in: rect))
            }
            .sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
        if let h = horizon.results?.first { m.horizonDegrees = Double(h.angle) * 180 / .pi }
        m.timestamp = Date()
        return m
    }

    /// Mean luma (0–100) of a normalised rect of the grey plane.
    static func meanLuma(_ l: FocusAnalyzer.Luma, in rect: CGRect) -> Double {
        let x0 = max(0, Int(rect.minX * CGFloat(l.width))), x1 = min(l.width, Int(rect.maxX * CGFloat(l.width)))
        let y0 = max(0, Int(rect.minY * CGFloat(l.height))), y1 = min(l.height, Int(rect.maxY * CGFloat(l.height)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var sum = 0
        for y in y0 ..< y1 { for x in x0 ..< x1 { sum += Int(l.pixels[y * l.width + x]) } }
        return Double(sum) / Double((x1 - x0) * (y1 - y0)) / 2.55
    }
}
