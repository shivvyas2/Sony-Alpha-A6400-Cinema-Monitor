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

    func process(_ image: CGImage, peaking: Bool, zebra: Bool, zebraLevel: Double) -> CGImage? {
        guard peaking || zebra else { return image }
        let src = CIImage(cgImage: image)
        var out = src
        if zebra { out = applyZebra(to: out, source: src, level: zebraLevel) }
        if peaking { out = applyPeaking(to: out, source: src) }
        return context.createCGImage(out, from: src.extent)
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
