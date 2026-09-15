import Foundation
import CoreGraphics

public enum FocusVerdict: String, Sendable { case inFocus = "IN FOCUS", soft = "SOFT", missed = "MISSED" }

public struct FocusReport: Sendable, Equatable {
    public var regionScore: Double
    public var peakScore: Double
    public var verdict: FocusVerdict
    /// Centre of the sharpest tile, as fractions of the image (top-left origin).
    public var peakPoint: CGPoint
    public var tiles: Int
    public var ratio: Double { peakScore > 0 ? min(1, regionScore / peakScore) : 0 }
}

/// Laplacian-variance sharpness. Pure functions; safe to call off the main thread.
public enum FocusAnalyzer {
    public static let inFocusRatio = 0.70
    public static let softRatio = 0.35

    public static func verdict(region: Double, peak: Double) -> FocusVerdict {
        guard peak > 0 else { return .missed }
        let r = region / peak
        return r >= inFocusRatio ? .inFocus : (r >= softRatio ? .soft : .missed)
    }

    /// 8-bit luma plane, row 0 at the top, long edge at most `maxLongEdge` pixels.
    public struct Luma: Sendable {
        public var pixels: [UInt8]
        public var width: Int
        public var height: Int
    }

    public static func luma(of image: CGImage, maxLongEdge: Int) -> Luma? {
        let scale = min(1, Double(maxLongEdge) / Double(max(image.width, image.height)))
        let w = max(8, Int(Double(image.width) * scale)), h = max(8, Int(Double(image.height) * scale))
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            // A bitmap context's first memory row is the top of the picture, so an upright draw is enough.
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Luma(pixels: px, width: w, height: h) : nil
    }

    /// Variance of the 3×3 Laplacian inside `rect` (fractions of the plane, top-left origin).
    public static func sharpness(_ l: Luma, in rect: CGRect) -> Double {
        let x0 = max(1, Int(rect.minX * CGFloat(l.width))), x1 = min(l.width - 1, Int(rect.maxX * CGFloat(l.width)))
        let y0 = max(1, Int(rect.minY * CGFloat(l.height))), y1 = min(l.height - 1, Int(rect.maxY * CGFloat(l.height)))
        guard x1 - x0 > 2, y1 - y0 > 2 else { return 0 }
        var sum = 0.0, sumSq = 0.0
        let n = Double((x1 - x0) * (y1 - y0))
        l.pixels.withUnsafeBufferPointer { p in
            let w = l.width
            for y in y0 ..< y1 {
                let row = y * w
                for x in x0 ..< x1 {
                    let c = Int(p[row + x])
                    let lap = Double(4 * c - Int(p[row + x - 1]) - Int(p[row + x + 1]) - Int(p[row - w + x]) - Int(p[row + w + x]))
                    sum += lap; sumSq += lap * lap
                }
            }
        }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    public static func sharpnessMap(_ l: Luma, tiles: Int) -> [[Double]] {
        let t = CGFloat(tiles)
        return (0 ..< tiles).map { row in
            (0 ..< tiles).map { col in
                sharpness(l, in: CGRect(x: CGFloat(col) / t, y: CGFloat(row) / t, width: 1 / t, height: 1 / t))
            }
        }
    }

    /// Square region of `fraction` of the width, centred on `point`, clamped inside the frame.
    public static func regionRect(around point: CGPoint, fraction: CGFloat, aspect: CGFloat) -> CGRect {
        let w = fraction, h = fraction * aspect
        return CGRect(x: min(max(0, point.x - w / 2), 1 - w), y: min(max(0, point.y - h / 2), 1 - h), width: w, height: h)
    }

    /// Full report for a captured image. `afPoint` nil = centre.
    public static func analyze(_ image: CGImage, afPoint: CGPoint?, regionFraction: CGFloat = 0.12, tiles: Int = 12, maxLongEdge: Int = 2048) -> FocusReport? {
        guard let l = luma(of: image, maxLongEdge: maxLongEdge) else { return nil }
        let p = afPoint ?? CGPoint(x: 0.5, y: 0.5)
        let region = sharpness(l, in: regionRect(around: p, fraction: regionFraction, aspect: CGFloat(l.width) / CGFloat(l.height)))
        let map = sharpnessMap(l, tiles: tiles)
        var best = -1.0, bestRow = 0, bestCol = 0
        for r in 0 ..< tiles { for c in 0 ..< tiles where map[r][c] > best { best = map[r][c]; bestRow = r; bestCol = c } }
        // Peak = mean of the top 5 % of tiles, so one noisy tile does not set the bar; never below the region itself.
        let sorted = map.flatMap { $0 }.sorted(by: >)
        let top = max(1, sorted.count / 20)
        let peak = max(region, sorted.prefix(top).reduce(0, +) / Double(top))
        return FocusReport(regionScore: region, peakScore: peak, verdict: verdict(region: region, peak: peak),
                           peakPoint: CGPoint(x: (CGFloat(bestCol) + 0.5) / CGFloat(tiles), y: (CGFloat(bestRow) + 0.5) / CGFloat(tiles)),
                           tiles: tiles)
    }

    /// Cheap live-view meter: sharpness of the AF region relative to the frame's sharpest tiles, 0…1.
    public static func liveRatio(_ image: CGImage, afPoint: CGPoint?) -> Double {
        guard let r = analyze(image, afPoint: afPoint, regionFraction: 0.14, tiles: 8, maxLongEdge: 512) else { return 0 }
        return r.ratio
    }
}
