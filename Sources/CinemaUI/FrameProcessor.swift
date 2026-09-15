import CoreImage
import CoreGraphics
import Foundation

/// Applies focus peaking and zebra overlays to a liveview frame using Core Image.
final class FrameProcessor: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let stripes: CIImage

    init() {
        let gen = CIFilter(name: "CIStripesGenerator")!
        gen.setValue(CIVector(x: 0, y: 0), forKey: "inputCenter")
        gen.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
        gen.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")
        gen.setValue(6, forKey: "inputWidth")
        gen.setValue(0.1, forKey: "inputSharpness")
        stripes = gen.outputImage!.transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
    }

    /// Active display LUT (built-in log conversion or a loaded .cube); nil = show the feed as-is.
    var lutCube: (data: Data, dimension: Int)? {
        didSet {
            guard let lutCube, let f = CIFilter(name: "CIColorCubeWithColorSpace") else { lutFilter = nil; return }
            f.setValue(lutCube.dimension, forKey: "inputCubeDimension")
            f.setValue(lutCube.data, forKey: "inputCubeData")
            // Log curves and .cube LUTs are defined on the camera's encoded code values, so the cube must see
            // sRGB-encoded input rather than Core Image's linear working space.
            f.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
            lutFilter = f
        }
    }
    private var lutFilter: CIFilter?

    /// GPU pipeline: LUT → (false colour, zebra, peaking) → rotation, as a lazy CIImage that the Metal
    /// renderer draws directly. Nothing is read back to the CPU.
    func pipeline(_ image: CIImage, peaking: Bool, zebra: Bool, zebraLevel: Double, falseColor: Bool = false, rotation: Int = 0, effects: Bool = true,
                  peakingColor: (Double, Double, Double) = (1, 0.15, 0.1)) -> CIImage {
        var src = image
        if let lutFilter {
            lutFilter.setValue(src, forKey: kCIInputImageKey)
            if let o = lutFilter.outputImage { src = o }
        }
        var out = src
        if effects {
            if falseColor { out = applyFalseColor(to: out) }
            if zebra { out = applyZebra(to: out, source: src, level: zebraLevel) }
            if peaking { out = applyPeaking(to: out, source: src, color: peakingColor) }
        }
        if rotation != 0 {
            let o: CGImagePropertyOrientation = rotation == 90 ? .right : (rotation == 270 ? .left : .up)
            out = out.oriented(o)
        }
        return out
    }

    /// CPU-side result of the pipeline (used by tests and tethered saving), not by the live display.
    func process(_ image: CGImage, peaking: Bool, zebra: Bool, zebraLevel: Double, falseColor: Bool = false) -> CGImage? {
        guard peaking || zebra || falseColor || lutFilter != nil else { return image }
        let out = pipeline(CIImage(cgImage: image), peaking: peaking, zebra: zebra, zebraLevel: zebraLevel, falseColor: falseColor)
        return context.createCGImage(out, from: out.extent)
    }

    // MARK: False color (exposure bands, ARRI-style ordering: purple → blue → grey → green → pink → yellow → orange → red)

    private lazy var falseColorCube: CIFilter? = {
        let n = 32
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0 ..< n { for g in 0 ..< n { for r in 0 ..< n {
            let rf = Float(r) / Float(n - 1), gf = Float(g) / Float(n - 1), bf = Float(b) / Float(n - 1)
            let y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
            let c = Self.band(y)
            data[i] = c.0; data[i + 1] = c.1; data[i + 2] = c.2; data[i + 3] = 1
            i += 4
        } } }
        guard let f = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        f.setValue(n, forKey: "inputCubeDimension")
        f.setValue(Data(bytes: data, count: data.count * MemoryLayout<Float>.size), forKey: "inputCubeData")
        f.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")   // bands are defined on the encoded signal
        return f
    }()

    /// IRE bands: <2.5 purple (crushed), <8 blue, 8–38 grey ramp, 38–46 green (mid grey 18%), 46–52 grey,
    /// 52–58 pink (skin), 58–90 grey ramp, 90–97 yellow, 97–99 orange, >99 red (clipped).
    private static func band(_ y: Float) -> (Float, Float, Float) {
        let ire = y * 100
        switch ire {
        case ..<2.5: return (0.45, 0.10, 0.65)
        case ..<8: return (0.15, 0.30, 0.90)
        case ..<38: let t = (ire - 8) / 30; return (0.15 + 0.30 * t, 0.15 + 0.30 * t, 0.15 + 0.30 * t)
        case ..<46: return (0.20, 0.75, 0.30)
        case ..<52: return (0.50, 0.50, 0.50)
        case ..<58: return (0.95, 0.55, 0.70)
        case ..<90: let t = (ire - 58) / 32; return (0.55 + 0.30 * t, 0.55 + 0.30 * t, 0.55 + 0.30 * t)
        case ..<97: return (0.95, 0.90, 0.20)
        case ..<99: return (1.00, 0.55, 0.10)
        default: return (1.00, 0.10, 0.10)
        }
    }

    private func applyFalseColor(to image: CIImage) -> CIImage {
        guard let f = falseColorCube else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        return f.outputImage ?? image
    }

    // MARK: Scopes

    /// Small RGBA sample of an image for the scopes: the GPU downsamples, only 256×96 pixels come back.
    private func samples(_ image: CIImage, w: Int = 256, h: Int = 96) -> [UInt8]? {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            context.render(scaled, toBitmap: buf.baseAddress!, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        // Core Image renders bottom-up into the bitmap; flip rows so y = 0 is the top.
        var flipped = [UInt8](repeating: 0, count: px.count)
        for y in 0 ..< h { flipped.replaceSubrange(y * w * 4 ..< (y + 1) * w * 4, with: px[(h - 1 - y) * w * 4 ..< (h - y) * w * 4]) }
        return flipped
    }

    private func samples(_ image: CGImage, w: Int = 256, h: Int = 96) -> [UInt8]? { samples(CIImage(cgImage: image), w: w, h: h) }

    private func makeImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func histogram(_ image: CIImage, width: Int = 256, height: Int = 128) -> CGImage? { histogram(samples: samples(image), width: width, height: height) }
    func parade(_ image: CIImage, width: Int = 300, height: Int = 128) -> CGImage? { parade(samples: samples(image), width: width, height: height) }
    func vectorscope(_ image: CIImage, size: Int = 160) -> CGImage? { vectorscope(samples: samples(image), size: size) }
    func waveform(_ image: CIImage, width: Int = 256, height: Int = 128) -> CGImage? { waveform(samples: samples(image), width: width, height: height) }

    /// RGB histogram: three overlaid channel histograms, 256 bins, log-scaled height.
    func histogram(_ image: CGImage, width: Int = 256, height: Int = 128) -> CGImage? { histogram(samples: samples(image), width: width, height: height) }
    private func histogram(samples px: [UInt8]?, width: Int, height: Int) -> CGImage? {
        guard let px else { return nil }
        var bins = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var i = 0
        while i < px.count { bins[0][Int(px[i])] += 1; bins[1][Int(px[i + 1])] += 1; bins[2][Int(px[i + 2])] += 1; i += 4 }
        let peak = max(1, bins.flatMap { $0 }.max() ?? 1)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for x in 0 ..< width {
            let b = x * 256 / width
            let heights = (0 ..< 3).map { c in Int(log(1 + Double(bins[c][b])) / log(1 + Double(peak)) * Double(height - 1)) }
            for y in 0 ..< height {
                let o = ((height - 1 - y) * width + x) * 4
                let grat = x % (width / 4) == 0
                if grat { out[o] = 50; out[o + 1] = 50; out[o + 2] = 50 }
                if y <= heights[0] { out[o] = 235 }
                if y <= heights[1] { out[o + 1] = 235 }
                if y <= heights[2] { out[o + 2] = 235 }
                out[o + 3] = 255
            }
        }
        return makeImage(out, width: width, height: height)
    }

    /// RGB parade: three waveforms side by side, one per channel.
    func parade(_ image: CGImage, width: Int = 300, height: Int = 128) -> CGImage? { parade(samples: samples(image), width: width, height: height) }
    private func parade(samples px: [UInt8]?, width: Int, height: Int) -> CGImage? {
        guard let px else { return nil }
        let sw = 256, sh = 96, third = width / 3
        var counts = [UInt16](repeating: 0, count: width * height)
        for y in 0 ..< sh { for x in 0 ..< sw {
            let i = (y * sw + x) * 4
            for c in 0 ..< 3 {
                let col = c * third + x * third / sw
                let row = min(height - 1, Int((1 - Double(px[i + c]) / 255) * Double(height - 1)))
                counts[row * width + col] &+= 1
            }
        } }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0 ..< width * height {
            let o = i * 4, row = i / width, col = i % width
            let grat = row == 0 || row == height / 2 || row == height - 1 || col % third == 0
            if grat { out[o] = 50; out[o + 1] = 50; out[o + 2] = 50 }
            let c = counts[i]
            if c > 0 {
                let v = UInt8(min(255, 100 + Int(c) * 50))
                switch col / third { case 0: out[o] = v; case 1: out[o + 1] = v; default: out[o + 2] = v }
            }
            out[o + 3] = 255
        }
        return makeImage(out, width: width, height: height)
    }

    /// Vectorscope: chroma (Cb, Cr) plot with 75% colour targets.
    func vectorscope(_ image: CGImage, size: Int = 160) -> CGImage? { vectorscope(samples: samples(image), size: size) }
    private func vectorscope(samples px: [UInt8]?, size: Int) -> CGImage? {
        guard let px else { return nil }
        var counts = [UInt16](repeating: 0, count: size * size)
        let c = Double(size) / 2, r = Double(size) / 2 - 2
        var i = 0
        while i < px.count {
            let R = Double(px[i]) / 255, G = Double(px[i + 1]) / 255, B = Double(px[i + 2]) / 255
            let cb = -0.1146 * R - 0.3854 * G + 0.5 * B      // BT.709, range ±0.5
            let cr = 0.5 * R - 0.4542 * G - 0.0458 * B
            let x = Int(c + cb * 2 * r), y = Int(c - cr * 2 * r)
            if x >= 0, x < size, y >= 0, y < size { counts[y * size + x] &+= 1 }
            i += 4
        }
        var out = [UInt8](repeating: 0, count: size * size * 4)
        // graticule: circle + crosshair + 75% targets
        func plot(_ x: Int, _ y: Int, _ v: UInt8) { if x >= 0, x < size, y >= 0, y < size { let o = (y * size + x) * 4; out[o] = v; out[o + 1] = v; out[o + 2] = v } }
        for a in stride(from: 0.0, to: 360, by: 0.5) { plot(Int(c + r * cos(a * .pi / 180)), Int(c + r * sin(a * .pi / 180)), 60) }
        for t in 0 ..< size { plot(t, Int(c), 40); plot(Int(c), t, 40) }
        let targets: [(String, Double, Double, Double)] = [("R", 0.75, 0, 0), ("Yl", 0.75, 0.75, 0), ("G", 0, 0.75, 0), ("Cy", 0, 0.75, 0.75), ("B", 0, 0, 0.75), ("Mg", 0.75, 0, 0.75)]
        for (_, R, G, B) in targets {
            let cb = -0.1146 * R - 0.3854 * G + 0.5 * B, cr = 0.5 * R - 0.4542 * G - 0.0458 * B
            let tx = Int(c + cb * 2 * r), ty = Int(c - cr * 2 * r)
            for dx in -3 ... 3 { plot(tx + dx, ty - 3, 140); plot(tx + dx, ty + 3, 140) }
            for dy in -3 ... 3 { plot(tx - 3, ty + dy, 140); plot(tx + 3, ty + dy, 140) }
        }
        for i in 0 ..< size * size {
            let o = i * 4
            let n = counts[i]
            if n > 0 { let v = UInt8(min(255, 110 + Int(n) * 40)); out[o] = v / 2; out[o + 1] = v; out[o + 2] = v / 2 }
            out[o + 3] = 255
        }
        return makeImage(out, width: size, height: size)
    }

    // MARK: Waveform scope

    /// Luma waveform: x = image column, y = luma. Returns a small RGBA image with a graticule at 0/50/100 IRE.
    func waveform(_ image: CGImage, width: Int = 256, height: Int = 128) -> CGImage? { waveform(samples: samples(image), width: width, height: height) }
    private func waveform(samples pixels: [UInt8]?, width: Int, height: Int) -> CGImage? {
        guard let pixels else { return nil }
        let sw = 256, sh = 96
        var counts = [UInt16](repeating: 0, count: width * height)
        for y in 0 ..< sh {
            for x in 0 ..< sw {
                let i = (y * sw + x) * 4
                let luma = (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
                let col = x * width / sw
                let row = min(height - 1, Int((1 - luma) * Double(height - 1)))
                counts[row * width + col] &+= 1
            }
        }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0 ..< width * height {
            let c = counts[i]
            let o = i * 4
            let row = i / width
            let grat = row == 0 || row == height / 2 || row == height - 1 || row == height * 3 / 10
            if grat { out[o] = 60; out[o + 1] = 60; out[o + 2] = 60; out[o + 3] = 255 } else { out[o + 3] = 255 }
            if c > 0 {
                let v = min(255, 90 + Int(c) * 55)
                out[o] = UInt8(v / 3); out[o + 1] = UInt8(v); out[o + 2] = UInt8(v / 2); out[o + 3] = 255
            }
        }
        return makeImage(out, width: width, height: height)
    }

    private func luminanceMask(_ src: CIImage, threshold: Double) -> CIImage? {
        guard let mono = CIFilter(name: "CIColorMonochrome"), let thr = CIFilter(name: "CIColorThreshold") else { return nil }
        mono.setValue(src, forKey: kCIInputImageKey)
        mono.setValue(CIColor(red: 1, green: 1, blue: 1), forKey: kCIInputColorKey)
        mono.setValue(1.0, forKey: kCIInputIntensityKey)
        thr.setValue(mono.outputImage, forKey: kCIInputImageKey)
        thr.setValue(threshold, forKey: "inputThreshold")
        return thr.outputImage
    }

    private func applyZebra(to base: CIImage, source: CIImage, level: Double) -> CIImage {
        let linear = pow((level + 0.055) / 1.055, 2.4)
        guard let mask = luminanceMask(source, threshold: linear),
              let mult = CIFilter(name: "CIMultiplyCompositing"),
              let over = CIFilter(name: "CISourceOverCompositing") else { return base }
        mult.setValue(stripes.cropped(to: source.extent), forKey: kCIInputImageKey)
        mult.setValue(mask, forKey: kCIInputBackgroundImageKey)
        guard let pattern = mult.outputImage else { return base }
        // white stripes where clipping → tint slightly warm so they read against bright areas
        let tinted = pattern.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.9, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.6, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.1, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        ])
        over.setValue(tinted, forKey: kCIInputImageKey)
        over.setValue(base, forKey: kCIInputBackgroundImageKey)
        return over.outputImage ?? base
    }

    private func applyPeaking(to base: CIImage, source: CIImage, color: (Double, Double, Double)) -> CIImage {
        guard let edges = CIFilter(name: "CIEdges"), let over = CIFilter(name: "CISourceOverCompositing") else { return base }
        edges.setValue(source, forKey: kCIInputImageKey)
        edges.setValue(4.0, forKey: kCIInputIntensityKey)
        guard let e = edges.outputImage,
              let mask = luminanceMask(e, threshold: 0.35) else { return base }
        let tinted = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: color.0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: color.1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: color.2, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        ])
        over.setValue(tinted, forKey: kCIInputImageKey)
        over.setValue(base, forKey: kCIInputBackgroundImageKey)
        return over.outputImage ?? base
    }
}
