import Foundation
import CoreGraphics
import ImageIO
import Vision

/// What the captured file itself looks like: blur, exposure and grain, measured on its real pixels.
/// Advisory: a blurred background or a night scene can be deliberate.
public struct ShotQuality: Sendable, Equatable {
    public enum Level: Sendable, Equatable { case good, caution, bad, unknown }
    public enum Blur: String, Sendable { case sharp = "SHARP", soft = "SOFT", focusMissed = "FOCUS MISSED", motion = "MOTION", blurred = "BLURRED", unknown = "NO DETAIL" }
    public enum Exposure: String, Sendable { case good = "GOOD", under = "UNDER", over = "OVER", clipped = "CLIPPED" }
    public enum Grain: String, Sendable { case low = "LOW", moderate = "MEDIUM", high = "HIGH", unknown = "--" }

    public var blur: Blur
    public var exposure: Exposure
    public var grain: Grain
    /// Edge width (px at `ShotQualityAnalyzer.edgeLongEdge`) of the sharpest part of the frame.
    public var edgeWidth: Double?
    /// Edge width on the subject (AF point, else the largest face), when it has edges to measure.
    public var subjectEdgeWidth: Double?
    /// Subject edges are as crisp as a sharp frame's; nil when there was nothing to measure on the subject.
    public var subjectSharp: Bool?
    /// Average brightness against a mid-grey rendering, in stops. Approximate: reflected-light average.
    public var stops: Double
    public var shadowClip: Double
    public var highlightClip: Double
    /// Noise standard deviation in 8-bit levels, from the smoothest patches at 100 %.
    public var noise: Double?

    public var blurLevel: Level {
        switch blur { case .sharp: return .good; case .soft: return .caution; case .focusMissed, .motion, .blurred: return .bad; case .unknown: return .unknown }
    }
    public var exposureLevel: Level {
        switch exposure { case .good: return .good; case .clipped: return .caution; case .under, .over: return abs(stops) >= 2 || highlightClip > 0.1 ? .bad : .caution }
    }
    public var grainLevel: Level {
        switch grain { case .low: return .good; case .moderate: return .caution; case .high: return .bad; case .unknown: return .unknown }
    }
    /// The worst of the three, for a one-dot summary.
    public var overall: Level {
        let all = [blurLevel, exposureLevel, grainLevel]
        return all.contains(.bad) ? .bad : (all.contains(.caution) ? .caution : .good)
    }
    public var exposureText: String {
        switch exposure {
        case .good: return "GOOD"
        case .under: return String(format: "UNDER ≈%.1f", abs(stops))
        case .over: return highlightClip > 0.03 && stops < ShotQualityAnalyzer.overStops ? String(format: "HIGHLIGHTS %.0f%%", highlightClip * 100) : String(format: "OVER ≈%.1f", abs(stops))
        case .clipped: return String(format: "HIGHLIGHTS %.0f%%", highlightClip * 100)
        }
    }
}

/// Pure measurements; call off the main thread. A 24 MP JPEG takes well under a second.
public enum ShotQualityAnalyzer {
    public static let edgeLongEdge = 3000
    // Edge widths are in pixels at `edgeLongEdge`.
    static let sharpWidth = 3.0, softWidth = 5.0
    // Calibrated on 57 α6400 JPEGs (ISO 100–6400): undegraded frames stay under |0.32|, 12–30 px of movement lands above 0.5.
    static let motionSkew = 0.5
    static let underStops = -1.0, overStops = 1.6
    static let moderateNoise = 1.6, highNoise = 3.2

    /// `afPoint` is in the sensor's (unrotated) frame, top-left origin. nil = the subject is the largest face, if any.
    public static func analyze(url: URL, afPoint: CGPoint?) -> ShotQuality? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let o = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32
        return analyze(img, afPoint: afPoint, orientation: o.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up)
    }

    public static func analyze(_ image: CGImage, afPoint: CGPoint?, orientation: CGImagePropertyOrientation = .up) -> ShotQuality? {
        guard let full = FocusAnalyzer.luma(of: image, maxLongEdge: max(image.width, image.height)),
              let l = FocusAnalyzer.luma(of: image, maxLongEdge: edgeLongEdge) else { return nil }
        let (noise, noiseKnown) = noiseSigma(full)

        let subject: CGRect? = afPoint.map { FocusAnalyzer.regionRect(around: $0, fraction: 0.12, aspect: CGFloat(l.width) / CGFloat(l.height)) }
            ?? largestFace(image, orientation: orientation)
        // Grain left after the downscale chops edges into fragments; smooth it out before measuring them.
        let left = noise * Double(l.width) / Double(full.width)
        let smooth = left >= 1.5
        let edges = smooth ? edgeMap(smoothed(l), noise: left / 3) : edgeMap(l, noise: left)
        let blur = verdict(edges, subject: subject, allowance: smooth ? 1.2 : 0)

        let e = exposure(l)
        return ShotQuality(blur: blur.verdict, exposure: e.verdict,
                           grain: !noiseKnown ? .unknown : (noise >= highNoise ? .high : (noise >= moderateNoise ? .moderate : .low)),
                           edgeWidth: blur.frame, subjectEdgeWidth: blur.subject,
                           subjectSharp: blur.subject.map { $0 <= sharpWidth + (smooth ? 1.2 : 0) },
                           stops: e.stops, shadowClip: e.shadow, highlightClip: e.highlight, noise: noiseKnown ? noise : nil)
    }

    // MARK: Blur

    static let tilesX = 12, tilesY = 12
    /// Edge widths are binned in quarter pixels.
    static let bins = 64
    struct Tile {
        var h = [Int](repeating: 0, count: ShotQualityAnalyzer.bins), v = [Int](repeating: 0, count: ShotQualityAnalyzer.bins)
        mutating func add(_ t: Tile) { for i in h.indices { h[i] += t.h[i]; v[i] += t.v[i] } }
    }

    /// 3×3 box.
    static func smoothed(_ l: FocusAnalyzer.Luma) -> FocusAnalyzer.Luma {
        var out = l
        let w = l.width
        l.pixels.withUnsafeBufferPointer { p in
            out.pixels.withUnsafeMutableBufferPointer { o in
                for y in 1 ..< l.height - 1 {
                    for x in 1 ..< w - 1 {
                        let i = y * w + x
                        let a = Int(p[i - w - 1]) + Int(p[i - w]) + Int(p[i - w + 1])
                        let b = Int(p[i - 1]) + Int(p[i]) + Int(p[i + 1])
                        let c = Int(p[i + w - 1]) + Int(p[i + w]) + Int(p[i + w + 1])
                        o[i] = UInt8((a + b + c + 4) / 9)
                    }
                }
            }
        }
        return out
    }

    /// Widths of strong edges along rows (h) and columns (v), as one histogram per tile. An edge is a monotonic run of
    /// pixels; its width is total contrast ÷ steepest step, so gentle shading around a crisp edge does not widen it.
    static func edgeMap(_ l: FocusAnalyzer.Luma, noise: Double) -> [Tile] {
        var tiles = Array(repeating: Tile(), count: tilesX * tilesY)
        // Only edges that clearly rise out of the noise count; grain makes short fake ones.
        let contrast = max(36, Int(noise * 10))
        let w = l.width, h = l.height
        l.pixels.withUnsafeBufferPointer { p in
            func scan(count: Int, length: Int, step: Int, at: (Int) -> Int, add: (Int, Int, Int) -> Void) {
                for line in stride(from: 1, to: count - 1, by: 2) {
                    let base = at(line)
                    var start = 0, dir = 0, steepest = 0
                    var prev = Int(p[base]), run0 = prev
                    for i in 1 ..< length {
                        let cur = Int(p[base + i * step])
                        let d = cur - prev
                        let s = d > 0 ? 1 : (d < 0 ? -1 : 0)
                        if s != dir {
                            let c = abs(prev - run0)
                            if dir != 0, c >= contrast { add(line, (start + i - 1) / 2, min(bins - 1, c * 4 / max(1, steepest))) }
                            start = i - 1; run0 = prev; dir = s; steepest = 0
                        }
                        steepest = max(steepest, abs(d))
                        prev = cur
                    }
                }
            }
            scan(count: h, length: w, step: 1, at: { $0 * w }) { y, x, bin in
                tiles[min(tilesY - 1, y * tilesY / h) * tilesX + min(tilesX - 1, x * tilesX / w)].h[bin] += 1
            }
            scan(count: w, length: h, step: w, at: { $0 }) { x, y, bin in
                tiles[min(tilesY - 1, y * tilesY / h) * tilesX + min(tilesX - 1, x * tilesX / w)].v[bin] += 1
            }
        }
        return tiles
    }

    /// Width in pixels below which `fraction` of the edges fall; nil with too few edges to tell.
    static func percentile(_ hist: [Int], _ fraction: Double, minimum: Int = 30) -> Double? {
        let n = hist.reduce(0, +)
        guard n >= minimum else { return nil }
        var seen = 0
        for (i, c) in hist.enumerated() {
            seen += c
            if Double(seen) >= Double(n) * fraction { return Double(i) / 4 }
        }
        return nil
    }

    /// `allowance`: extra width every edge has because the plane was smoothed first.
    static func verdict(_ tiles: [Tile], subject: CGRect?, allowance: Double = 0) -> (verdict: ShotQuality.Blur, frame: Double?, subject: Double?) {
        // Movement smears only the edges it crosses, so a tile is as sharp as its worse axis.
        func width(_ t: Tile) -> Double? {
            let a = percentile(t.h, 0.25), b = percentile(t.v, 0.25)
            return [a, b].compactMap { $0 }.max()
        }
        func axes(_ t: Tile) -> Double? {
            guard let a = percentile(t.h, 0.25), let b = percentile(t.v, 0.25) else { return nil }
            return log2(a / b)
        }
        let scored = tiles.compactMap { t in width(t).map { (width: $0, tile: t) } }.sorted { $0.width < $1.width }
        guard scored.count >= 2 else { return (.unknown, nil, nil) }
        // Sharpest part of the frame: mean of the best 8 % of tiles (at least two), so one odd tile does not decide.
        let k = max(2, scored.count / 12)
        let frame = scored.prefix(k).map(\.width).reduce(0, +) / Double(k)
        // Every part of the frame stretched the same way = movement.
        let ratios = scored.compactMap { axes($0.tile) }.sorted()
        let skew = ratios.count >= 12 ? ratios[ratios.count / 2] : 0

        var subjectWidth: Double?
        if let r = subject {
            var sum = Tile()
            for ty in 0 ..< tilesY { for tx in 0 ..< tilesX {
                let c = CGRect(x: CGFloat(tx) / CGFloat(tilesX), y: CGFloat(ty) / CGFloat(tilesY), width: 1 / CGFloat(tilesX), height: 1 / CGFloat(tilesY))
                let o = c.intersection(r)
                guard !o.isNull, o.width * o.height > c.width * c.height * 0.25 else { continue }
                let t = tiles[ty * tilesX + tx]
                sum.add(t)
            } }
            subjectWidth = width(sum)
        }

        if abs(skew) > motionSkew { return (.motion, frame, subjectWidth) }
        if frame > softWidth + allowance { return (.blurred, frame, subjectWidth) }
        if let s = subjectWidth, s > softWidth + allowance, s > frame * 1.8 { return (.focusMissed, frame, s) }
        if frame > sharpWidth + allowance { return (.soft, frame, subjectWidth) }
        return (.sharp, frame, subjectWidth)
    }

    /// Largest face, in the unrotated image's fractions (top-left origin).
    static func largestFace(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGRect? {
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([req])
        guard let b = (req.results ?? []).map(\.boundingBox).filter({ $0.width > 0.04 }).max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return unrotate(CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), orientation)
    }

    /// Sensor-frame point → displayed (EXIF-rotated) point, both as fractions from the top left.
    public static func displayPoint(_ p: CGPoint, _ o: CGImagePropertyOrientation) -> CGPoint {
        switch o {
        case .right: return CGPoint(x: 1 - p.y, y: p.x)
        case .left: return CGPoint(x: p.y, y: 1 - p.x)
        case .down: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        default: return p
        }
    }

    static func unrotate(_ r: CGRect, _ o: CGImagePropertyOrientation) -> CGRect {
        switch o {
        case .right: return CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
        case .left: return CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
        case .down: return CGRect(x: 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)
        default: return r
        }
    }

    // MARK: Exposure

    static func exposure(_ l: FocusAnalyzer.Luma) -> (verdict: ShotQuality.Exposure, stops: Double, shadow: Double, highlight: Double) {
        var hist = [Int](repeating: 0, count: 256)
        for v in l.pixels { hist[Int(v)] += 1 }
        let n = Double(l.pixels.count)
        var logSum = 0.0
        for (i, c) in hist.enumerated() where c > 0 {
            logSum += log2(max(linear(i), 0.002)) * Double(c)
        }
        let average = logSum / n - log2(0.13)
        let shadow = Double(hist[0 ... 2].reduce(0, +)) / n, highlight = Double(hist[253 ... 255].reduce(0, +)) / n
        var p98 = 255, acc = 0
        for i in stride(from: 255, through: 0, by: -1) { acc += hist[i]; if Double(acc) >= n * 0.02 { p98 = i; break } }
        // How far the exposure could open before more than 2 % of the frame clips. A dark picture with bright
        // lamps in it (night, low key) has no such room and is not called underexposed.
        let headroom = -log2(max(linear(p98), 0.002))
        if average <= underStops, headroom >= 1 { return (.under, -min(headroom, -average), shadow, highlight) }
        if average >= overStops { return (.over, average, shadow, highlight) }
        if highlight > 0.03 { return (.clipped, average, shadow, highlight) }
        return (.good, average, shadow, highlight)
    }

    static func linear(_ v: Int) -> Double {
        let s = Double(v) / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }

    // MARK: Grain

    /// Noise of the smoothest mid-tone patches at full resolution (Immerkær's operator cancels edges and gradients).
    static func noiseSigma(_ l: FocusAnalyzer.Luma) -> (sigma: Double, known: Bool) {
        let block = 24, w = l.width, h = l.height
        guard w > block * 4, h > block * 4 else { return (0, false) }
        let stepX = max(block, w / 60), stepY = max(block, h / 40)
        var sigmas: [Double] = []
        l.pixels.withUnsafeBufferPointer { p in
            for y0 in stride(from: 1, to: h - block - 1, by: stepY) {
                for x0 in stride(from: 1, to: w - block - 1, by: stepX) {
                    var sum = 0, acc = 0
                    for y in y0 ..< y0 + block {
                        let r = y * w
                        for x in x0 ..< x0 + block {
                            let i = r + x
                            sum += Int(p[i])
                            let corners = Int(p[i - w - 1]) + Int(p[i - w + 1]) + Int(p[i + w - 1]) + Int(p[i + w + 1])
                            let sides = Int(p[i - w]) + Int(p[i + w]) + Int(p[i - 1]) + Int(p[i + 1])
                            acc += abs(corners - 2 * sides + 4 * Int(p[i]))
                        }
                    }
                    let mean = sum / (block * block)
                    guard mean > 24, mean < 225 else { continue }
                    sigmas.append((Double.pi / 2).squareRoot() * Double(acc) / Double(6 * block * block))
                }
            }
        }
        guard sigmas.count >= 12 else { return (0, false) }
        sigmas.sort()
        return (sigmas[sigmas.count / 5], true)
    }
}
