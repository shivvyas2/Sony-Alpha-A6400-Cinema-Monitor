import Foundation
import CoreGraphics
import CoreImage
import Metal
import Vision
import CoreVideo

/// Frame-rate multiplication and temporal noise reduction driven by dense optical flow (Vision)
/// and small Metal kernels.
///
/// * Motion (`factor` 2/4/8): between real frames A and B, synthesizes `factor - 1` frames at
///   fractional times by warping both toward t. Output is delayed by one input frame.
/// * Denoise (`denoise` > 0): each incoming frame is blended with the previous cleaned frame warped
///   along the flow; the blend weight falls to zero where the two disagree (moving edges), so grain
///   averages out while motion stays sharp.
public final class MotionInterpolator: @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let warpPipeline: MTLComputePipelineState
    private let nrPipeline: MTLComputePipelineState
    private let work = DispatchQueue(label: "cinemahud.motion", qos: .userInteractive)
    private var prev: (image: CGImage, texture: MTLTexture, time: TimeInterval)?
    private var texA: MTLTexture?, texB: MTLTexture?, texFlow: MTLTexture?, texNRPrev: MTLTexture?
    /// Ring of output textures so frames still on screen are not overwritten by the next batch.
    private var ring: [MTLTexture] = []
    private var ringIndex = 0
    /// Raw-value CIImage (no colour management) wrapping a texture; the display tags it later.
    private static let rawOptions: [CIImageOption: Any] = [.colorSpace: NSNull()]
    private var scratch: UnsafeMutableRawPointer?
    private var scratchSize = 0
    public private(set) var lastFlowMillis: Double = 0
    private var generation = 0

    /// Frame-rate multiplier: 1 = off, 2/4/8.
    public var factor = 1
    /// Temporal noise-reduction strength 0…1 (0 = off).
    public var denoise: Float = 0

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Params { float t; float strength; float threshold; float pad; };

    // Frame at fractional time t between a (t=0) and b (t=1), flow is a→b in flow-buffer pixels.
    kernel void warp_t(texture2d<float, access::sample> a [[texture(0)]],
                       texture2d<float, access::sample> b [[texture(1)]],
                       texture2d<float, access::sample> flow [[texture(2)]],
                       texture2d<float, access::write> out [[texture(3)]],
                       constant Params& p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
        uint W = out.get_width(), H = out.get_height();
        if (gid.x >= W || gid.y >= H) return;
        constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 uv = (float2(gid) + 0.5) / float2(W, H);
        float2 f = flow.sample(s, uv).xy / float2(flow.get_width(), flow.get_height());
        float4 ca = a.sample(s, uv - p.t * f);
        float4 cb = b.sample(s, uv + (1.0 - p.t) * f);
        out.write(mix(ca, cb, p.t), gid);
    }

    // Temporal NR: blend current frame with the previous cleaned frame warped forward along the flow.
    kernel void temporal_nr(texture2d<float, access::sample> cur [[texture(0)]],
                            texture2d<float, access::sample> prevClean [[texture(1)]],
                            texture2d<float, access::sample> flow [[texture(2)]],
                            texture2d<float, access::write> out [[texture(3)]],
                            constant Params& p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint W = out.get_width(), H = out.get_height();
        if (gid.x >= W || gid.y >= H) return;
        constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 uv = (float2(gid) + 0.5) / float2(W, H);
        float2 f = flow.sample(s, uv).xy / float2(flow.get_width(), flow.get_height());
        float4 c = cur.sample(s, uv);
        float4 w = prevClean.sample(s, uv - f);                 // where this pixel came from in the previous frame
        float3 d = abs(c.rgb - w.rgb);
        float diff = max(d.r, max(d.g, d.b));
        float k = p.strength * (1.0 - smoothstep(0.0, p.threshold, diff));   // trust history only where it matches
        out.write(float4(mix(c.rgb, w.rgb, k), 1.0), gid);
    }
    """

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: Self.source, options: nil),
              let fw = lib.makeFunction(name: "warp_t"), let fn = lib.makeFunction(name: "temporal_nr"),
              let wp = try? device.makeComputePipelineState(function: fw),
              let np = try? device.makeComputePipelineState(function: fn) else { return nil }
        self.device = device; self.queue = queue; warpPipeline = wp; nrPipeline = np
        warmUp()
    }

    deinit { scratch?.deallocate() }

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

    /// Drop pending state (e.g. when toggled off or the stream restarts).
    public func reset() {
        work.async { self.prev = nil; self.texNRPrev = nil; self.prevClean = nil; self.generation += 1 }
    }

    /// Feed a real frame. `emit` receives frames to display, in order, on the work queue. Outputs are
    /// raw-value CIImages: either the source picture or a GPU texture, so nothing is read back to the CPU.
    public func push(_ image: CGImage, at time: TimeInterval, emit: @escaping @Sendable (CIImage) -> Void) {
        work.async {
            let gen = self.generation
            let factor = max(1, self.factor), nr = max(0, min(1, self.denoise))
            let raw = CIImage(cgImage: image, options: Self.rawOptions)
            guard factor > 1 || nr > 0 else { emit(raw); return }
            guard let texB = self.upload(image, into: &self.texB) else { emit(raw); return }
            guard let prev = self.prev, prev.image.width == image.width, prev.image.height == image.height else {
                if nr > 0 { self.seedNR(from: texB) }
                self.prev = (image, texB, time)
                self.swapB()
                if factor == 1 { emit(raw) }
                return
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            // Flow is estimated on the raw frames; the cleaned history texture is what gets warped.
            guard let flow = self.opticalFlow(from: prev.image, to: image) else {
                self.prev = (image, texB, time); self.swapB(); emit(raw); return
            }
            // 1. Temporal NR: cleaned frame lives in `texNRPrev` (history) and is what we display / warp.
            var displayB: MTLTexture = texB
            if nr > 0, let cleaned = self.temporalNR(cur: texB, flow: flow, strength: nr) { displayB = cleaned }
            let aTexture = nr > 0 ? (self.prevClean ?? prev.texture) : prev.texture
            // 2. Motion: emit A now (one frame late), then the in-betweens on schedule.
            if factor > 1 {
                emit(self.wrap(aTexture))
                let interval = max(0.01, time - prev.time)
                var frames: [CIImage] = []
                for k in 1 ..< factor {
                    if let tex = self.warp(a: aTexture, b: displayB, flow: flow, t: Float(k) / Float(factor)) { frames.append(self.wrap(tex)) }
                }
                self.lastFlowMillis = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                for (i, f) in frames.enumerated() {
                    let delay = max(0, interval * Double(i + 1) / Double(factor) - self.lastFlowMillis / 1000)
                    self.work.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.generation == gen else { return }
                        emit(f)
                    }
                }
            } else {
                self.lastFlowMillis = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                emit(self.wrap(displayB))
            }
            // Keep the cleaned B as history for the next pair (copy: texB is recycled as the next upload target).
            if nr > 0 { self.prevClean = self.copyToRing(displayB) } else { self.prevClean = nil }
            self.prev = (image, texB, time)
            self.swapB()
        }
    }

    /// Cleaned copy of the previous frame (denoise on), used as the "A" side of interpolation.
    private var prevClean: MTLTexture?

    private func wrap(_ tex: MTLTexture) -> CIImage {
        // Texture rows are top-down; present the image bottom-up like a CGImage-backed CIImage so the
        // display's single flip lands both sources the same way up.
        (CIImage(mtlTexture: tex, options: Self.rawOptions) ?? CIImage.empty()).oriented(.downMirrored)
    }

    private func nextRing(w: Int, h: Int) -> MTLTexture? {
        if ring.isEmpty || ring[0].width != w || ring[0].height != h {
            ring = (0 ..< 12).compactMap { _ in
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
                d.usage = [.shaderWrite, .shaderRead]; d.storageMode = .private
                return device.makeTexture(descriptor: d)
            }
            ringIndex = 0
        }
        guard !ring.isEmpty else { return nil }
        let t = ring[ringIndex]; ringIndex = (ringIndex + 1) % ring.count
        return t
    }

    private func copyToRing(_ src: MTLTexture) -> MTLTexture? {
        guard let dst = nextRing(w: src.width, h: src.height), let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: src, to: dst); blit.endEncoding(); cb.commit()
        return dst
    }

    private func swapB() { let old = texA; texA = texB; texB = old }

    // MARK: GPU stages

    private func opticalFlow(from a: CGImage, to b: CGImage) -> MTLTexture? {
        let req = VNGenerateOpticalFlowRequest(targetedCGImage: b, options: [:])
        req.computationAccuracy = .low
        req.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        guard (try? VNImageRequestHandler(cgImage: a, options: [:]).perform([req])) != nil,
              let obs = req.results?.first as? VNPixelBufferObservation else { return nil }
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
        return texFlow
    }

    private struct Params { var t: Float; var strength: Float; var threshold: Float; var pad: Float = 0 }

    private func outputTexture(_ slot: inout MTLTexture?, w: Int, h: Int) -> MTLTexture? {
        if slot == nil || slot!.width != w || slot!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.shaderWrite, .shaderRead]; d.storageMode = .private
            slot = device.makeTexture(descriptor: d)
        }
        return slot
    }

    private func run(_ pipeline: MTLComputePipelineState, textures: [MTLTexture], out: MTLTexture, params: Params) -> Bool {
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(pipeline)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        enc.setTexture(out, index: textures.count)
        var p = params
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (out.width + 15) / 16, height: (out.height + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return true
    }

    private func warp(a: MTLTexture, b: MTLTexture, flow: MTLTexture, t: Float) -> MTLTexture? {
        guard let out = nextRing(w: a.width, h: a.height) else { return nil }
        return run(warpPipeline, textures: [a, b, flow], out: out, params: Params(t: t, strength: 0, threshold: 0)) ? out : nil
    }

    private func seedNR(from tex: MTLTexture) {
        guard let dst = outputTexture(&texNRPrev, w: tex.width, h: tex.height), let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: tex, to: dst); blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    }

    private func temporalNR(cur: MTLTexture, flow: MTLTexture, strength: Float) -> MTLTexture? {
        guard let prevClean = outputTexture(&texNRPrev, w: cur.width, h: cur.height), let out = nextRing(w: cur.width, h: cur.height) else { return nil }
        // strength maps to how much history is kept; threshold is the RGB difference beyond which history is ignored
        let ok = run(nrPipeline, textures: [cur, prevClean, flow], out: out, params: Params(t: 0, strength: 0.55 + 0.35 * strength, threshold: 0.10 + 0.10 * strength))
        guard ok else { return nil }
        // the cleaned frame becomes the history for the next one
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() { blit.copy(from: out, to: prevClean); blit.endEncoding(); cb.commit(); cb.waitUntilCompleted() }
        return out
    }

    private func ensureScratch(_ n: Int) {
        if scratchSize < n { scratch?.deallocate(); scratch = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 16); scratchSize = n }
    }

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
