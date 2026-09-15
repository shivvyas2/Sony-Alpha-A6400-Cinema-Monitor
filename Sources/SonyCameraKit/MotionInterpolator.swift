import Foundation
import CoreGraphics
import Metal
import Vision
import CoreVideo

/// Doubles the frame rate by synthesizing a midpoint frame between consecutive real frames:
/// dense optical flow (Vision) between A and B, then a GPU warp of both toward the middle.
/// Output is delayed by one input frame, because the midpoint needs B before it can be drawn.
public final class MotionInterpolator: @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let work = DispatchQueue(label: "cinemahud.motion", qos: .userInteractive)
    private var prev: (image: CGImage, texture: MTLTexture, time: TimeInterval)?
    private var texA: MTLTexture?, texB: MTLTexture?, texFlow: MTLTexture?, texOut: MTLTexture?
    private var scratch: UnsafeMutableRawPointer?
    private var scratchSize = 0
    public private(set) var lastFlowMillis: Double = 0
    private var generation = 0

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void midpoint(texture2d<float, access::sample> a [[texture(0)]],
                         texture2d<float, access::sample> b [[texture(1)]],
                         texture2d<float, access::sample> flow [[texture(2)]],
                         texture2d<float, access::write> out [[texture(3)]],
                         uint2 gid [[thread_position_in_grid]]) {
        uint W = out.get_width(), H = out.get_height();
        if (gid.x >= W || gid.y >= H) return;
        constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 uv = (float2(gid) + 0.5) / float2(W, H);
        float2 f = flow.sample(s, uv).xy;                       // displacement in flow-buffer pixels
        float2 fn = f / float2(flow.get_width(), flow.get_height());
        float4 ca = a.sample(s, uv - 0.5 * fn);
        float4 cb = b.sample(s, uv + 0.5 * fn);
        out.write(0.5 * (ca + cb), gid);
    }
    """

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: Self.source, options: nil),
              let fn = lib.makeFunction(name: "midpoint"),
              let pipeline = try? device.makeComputePipelineState(function: fn) else { return nil }
        self.device = device; self.queue = queue; self.pipeline = pipeline
        warmUp()
    }

    /// Vision's optical-flow model takes a few seconds to load on first use; do it off the critical path.
    private func warmUp() {
        work.async {
            let w = 256, h = 160
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  let img = ctx.makeImage() else { return }
            let req = VNGenerateOpticalFlowRequest(targetedCGImage: img, options: [:])
            req.computationAccuracy = .low
            try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        }
    }

    deinit { scratch?.deallocate() }

    /// Drop pending state (e.g. when toggled off or the stream restarts).
    public func reset() {
        work.async { self.prev = nil; self.generation += 1 }
    }

    /// Feed a real frame. `emit` receives frames to display, in order, on the work queue.
    public func push(_ image: CGImage, at time: TimeInterval, emit: @escaping @Sendable (CGImage) -> Void) {
        work.async {
            let gen = self.generation
            guard let texB = self.upload(image, into: &self.texB) else { emit(image); return }
            guard let prev = self.prev, prev.image.width == image.width, prev.image.height == image.height else {
                self.prev = (image, texB, time)
                self.swapB()
                return
            }
            let interval = max(0.01, time - prev.time)
            emit(prev.image)                                    // real frame A, one frame late
            let t0 = CFAbsoluteTimeGetCurrent()
            let mid = self.midpoint(a: prev.texture, aImage: prev.image, b: texB, bImage: image)
            self.lastFlowMillis = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            self.prev = (image, texB, time)
            self.swapB()
            guard let mid else { return }
            let delay = max(0, interval / 2 - self.lastFlowMillis / 1000)
            self.work.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation == gen else { return }
                emit(mid)
            }
        }
    }

    /// texB becomes the new "A" texture; recycle the old one as the next upload target.
    private func swapB() { let old = texA; texA = texB; texB = old }

    private func midpoint(a: MTLTexture, aImage: CGImage, b: MTLTexture, bImage: CGImage) -> CGImage? {
        // 1. Optical flow A → B
        let req = VNGenerateOpticalFlowRequest(targetedCGImage: bImage, options: [:])
        req.computationAccuracy = .low
        req.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cgImage: aImage, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results?.first as? VNPixelBufferObservation else { return nil }
        let pb = obs.pixelBuffer
        let fw = CVPixelBufferGetWidth(pb), fh = CVPixelBufferGetHeight(pb)
        if texFlow == nil || texFlow!.width != fw || texFlow!.height != fh {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: fw, height: fh, mipmapped: false)
            d.usage = [.shaderRead]; d.storageMode = .managed
            texFlow = device.makeTexture(descriptor: d)
        }
        guard let texFlow else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(pb) {
            texFlow.replace(region: MTLRegionMake2D(0, 0, fw, fh), mipmapLevel: 0, withBytes: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)

        // 2. Warp both frames to the midpoint
        let w = a.width, h = a.height
        if texOut == nil || texOut!.width != w || texOut!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.shaderWrite, .shaderRead]; d.storageMode = .managed
            texOut = device.makeTexture(descriptor: d)
        }
        guard let texOut, let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(a, index: 0); enc.setTexture(b, index: 1); enc.setTexture(texFlow, index: 2); enc.setTexture(texOut, index: 3)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        if let blit = cb.makeBlitCommandEncoder() { blit.synchronize(resource: texOut); blit.endEncoding() }
        cb.commit()
        cb.waitUntilCompleted()

        // 3. Read back as CGImage
        let bpr = w * 4
        ensureScratch(bpr * h)
        guard let scratch else { return nil }
        texOut.getBytes(scratch, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes: scratch, count: bpr * h) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func ensureScratch(_ n: Int) {
        if scratchSize < n { scratch?.deallocate(); scratch = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 16); scratchSize = n }
    }

    /// CGImage → BGRA8 texture, reusing `slot` when the size matches.
    private func upload(_ image: CGImage, into slot: inout MTLTexture?) -> MTLTexture? {
        let w = image.width, h = image.height, bpr = w * 4
        if slot == nil || slot!.width != w || slot!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead]; d.storageMode = .managed
            slot = device.makeTexture(descriptor: d)
        }
        guard let tex = slot else { return nil }
        ensureScratch(bpr * h)
        guard let scratch else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: scratch, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: scratch, bytesPerRow: bpr)
        return tex
    }
}
