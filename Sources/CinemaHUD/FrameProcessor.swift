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

    func process(_ image: CGImage, peaking: Bool, zebra: Bool, zebraLevel: Double, falseColor: Bool = false) -> CGImage? {
        guard peaking || zebra || falseColor else { return image }
        let src = CIImage(cgImage: image)
        var out = src
        if falseColor { out = applyFalseColor(to: out) }
        if zebra { out = applyZebra(to: out, source: src, level: zebraLevel) }
        if peaking { out = applyPeaking(to: out, source: src) }
        return context.createCGImage(out, from: src.extent)
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
        guard let f = CIFilter(name: "CIColorCube") else { return nil }
        f.setValue(n, forKey: "inputCubeDimension")
        f.setValue(Data(bytes: data, count: data.count * MemoryLayout<Float>.size), forKey: "inputCubeData")
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

    // MARK: Waveform scope

    /// Luma waveform: x = image column, y = luma. Returns a small RGBA image with a graticule at 0/50/100 IRE.
    func waveform(_ image: CGImage, width: Int = 256, height: Int = 128) -> CGImage? {
        let sw = 256, sh = 96
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 0, count: sw * sh * 4)
        guard let ctx = CGContext(data: &pixels, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
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
        let data = Data(out)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
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
        guard let mask = luminanceMask(source, threshold: level),
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

    private func applyPeaking(to base: CIImage, source: CIImage) -> CIImage {
        guard let edges = CIFilter(name: "CIEdges"), let over = CIFilter(name: "CISourceOverCompositing") else { return base }
        edges.setValue(source, forKey: kCIInputImageKey)
        edges.setValue(4.0, forKey: kCIInputIntensityKey)
        guard let e = edges.outputImage,
              let mask = luminanceMask(e, threshold: 0.35) else { return base }
        let red = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.15, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.1, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        ])
        over.setValue(red, forKey: kCIInputImageKey)
        over.setValue(base, forKey: kCIInputBackgroundImageKey)
        return over.outputImage ?? base
    }
}
