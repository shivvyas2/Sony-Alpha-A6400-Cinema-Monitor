import SwiftUI
import MetalKit
import MetalFX
import MetalPerformanceShaders

/// Draws the live view through Metal. In enhanced mode the frame is upscaled with MetalFX's
/// spatial scaler (edge-aware reconstruction, no added latency); otherwise Lanczos resampling.
struct MetalFrameView: NSViewRepresentable {
    var image: CGImage?
    var enhanced: Bool
    /// Detail-recovery amount after upscaling (0 = pure reconstruction, colour and tone untouched).
    var sharpen: Float = 0
    /// Colour space the frame's values are in; the layer is tagged with it so macOS converts to the display profile.
    var colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func makeCoordinator() -> FrameRenderer { FrameRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: context.coordinator.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = false
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        v.autoResizeDrawable = true
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.layer?.isOpaque = true
        // Colour management: the frame is decoded into sRGB, so tell the compositor the layer is sRGB.
        // Without this a P3 display shows the camera's colours oversaturated.
        v.colorspace = colorSpace
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        let r = context.coordinator
        r.enhanced = enhanced
        r.sharpen = sharpen
        if r.colorSpace != colorSpace { r.colorSpace = colorSpace; r.imageDirty = true; v.colorspace = colorSpace }
        if r.image !== image { r.image = image; r.imageDirty = true }
        v.needsDisplay = true
    }
}

final class FrameRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private lazy var lanczos = MPSImageLanczosScale(device: device)
    private let metalFXSupported: Bool

    var image: CGImage?
    var imageDirty = false
    var enhanced = false
    var colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Last output size, for the HUD.
    private(set) var outputSize: CGSize = .zero
    static let outputSizeChanged = Notification.Name("CinemaHUD.outputSizeChanged")

    private var input: MTLTexture?
    private var upload: (data: UnsafeMutableRawPointer, bytesPerRow: Int, w: Int, h: Int)?
    private var scaler: MTLFXSpatialScaler?
    private var scalerOutput: MTLTexture?
    private var sharpenPipeline: MTLComputePipelineState?
    private var sharpenOutput: MTLTexture?
    /// Detail recovery after upscaling: unsharp amount (0 = off, the default: colour and tone stay untouched).
    var sharpen: Float = 0

    private static let sharpenSource = """
    #include <metal_stdlib>
    using namespace metal;
    // Edge-aware unsharp mask: boosts local contrast where there is real structure, leaves flat
    // (noisy) areas alone so grain is not amplified.
    kernel void sharpen(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float& amount [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        float4 c = src.read(gid);
        float4 sum = 0;
        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            uint2 p = uint2(clamp(int(gid.x) + dx, 0, int(W) - 1), clamp(int(gid.y) + dy, 0, int(H) - 1));
            sum += src.read(p);
        }
        float4 blur = sum / 9.0;
        float4 detail = c - blur;
        float mag = max(abs(detail.r), max(abs(detail.g), abs(detail.b)));
        float gate = smoothstep(0.01, 0.06, mag);          // ignore sub-threshold noise
        float4 o = c + detail * amount * 2.0 * gate;
        dst.write(float4(clamp(o.rgb, 0.0, 1.0), 1.0), gid);
    }
    """

    override init() {
        metalFXSupported = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        super.init()
        if let lib = try? device.makeLibrary(source: Self.sharpenSource, options: nil), let fn = lib.makeFunction(name: "sharpen") {
            sharpenPipeline = try? device.makeComputePipelineState(function: fn)
        }
    }
    deinit { upload?.data.deallocate() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let image, let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        if imageDirty || input == nil || input!.width != image.width || input!.height != image.height {
            uploadFrame(image)
            imageDirty = false
        }
        guard let input else { return }
        let dst = drawable.texture
        let useFX = enhanced && metalFXSupported && dst.width >= input.width && dst.height >= input.height
        if useFX, let scaler = spatialScaler(inW: input.width, inH: input.height, outW: dst.width, outH: dst.height),
           let out = scalerOutput {
            scaler.colorTexture = input
            scaler.outputTexture = out
            scaler.encode(commandBuffer: cb)
            var source = out
            if sharpen > 0, let sp = sharpenPipeline, let sharp = sharpenTexture(w: out.width, h: out.height), let enc = cb.makeComputeCommandEncoder() {
                enc.setComputePipelineState(sp)
                enc.setTexture(out, index: 0); enc.setTexture(sharp, index: 1)
                var amt = sharpen
                enc.setBytes(&amt, length: MemoryLayout<Float>.size, index: 0)
                enc.dispatchThreadgroups(MTLSize(width: (out.width + 15) / 16, height: (out.height + 15) / 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                enc.endEncoding()
                source = sharp
            }
            if let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: source, to: dst)
                blit.endEncoding()
            }
        } else {
            var t = MPSScaleTransform(scaleX: Double(dst.width) / Double(input.width), scaleY: Double(dst.height) / Double(input.height), translateX: 0, translateY: 0)
            withUnsafePointer(to: &t) { lanczos.scaleTransform = $0 }
            lanczos.encode(commandBuffer: cb, sourceTexture: input, destinationTexture: dst)
        }
        let newSize = CGSize(width: dst.width, height: dst.height)
        if newSize != outputSize {
            outputSize = newSize
            NotificationCenter.default.post(name: Self.outputSizeChanged, object: nil, userInfo: ["size": newSize, "fx": useFX])
        }
        cb.present(drawable)
        cb.commit()
    }

    /// CGImage → BGRA8 texture (reused; replaced in place each frame).
    private func uploadFrame(_ image: CGImage) {
        let w = image.width, h = image.height, bpr = w * 4
        if upload == nil || upload!.w != w || upload!.h != h {
            upload?.data.deallocate()
            upload = (UnsafeMutableRawPointer.allocate(byteCount: bpr * h, alignment: 16), bpr, w, h)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .managed
            input = device.makeTexture(descriptor: d)
            scaler = nil
        }
        guard let up = upload, let input else { return }
        let cs = colorSpace
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        if let ctx = CGContext(data: up.data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: info) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        input.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: up.data, bytesPerRow: bpr)
    }

    private func sharpenTexture(w: Int, h: Int) -> MTLTexture? {
        if let t = sharpenOutput, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
        sharpenOutput = device.makeTexture(descriptor: d)
        return sharpenOutput
    }

    private func spatialScaler(inW: Int, inH: Int, outW: Int, outH: Int) -> MTLFXSpatialScaler? {
        if let s = scaler, s.inputWidth == inW, s.inputHeight == inH, s.outputWidth == outW, s.outputHeight == outH { return s }
        let d = MTLFXSpatialScalerDescriptor()
        d.inputWidth = inW; d.inputHeight = inH
        d.outputWidth = outW; d.outputHeight = outH
        d.colorTextureFormat = .bgra8Unorm
        d.outputTextureFormat = .bgra8Unorm
        d.colorProcessingMode = .perceptual
        guard let s = d.makeSpatialScaler(device: device) else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: outW, height: outH, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead, .shaderWrite]
        td.storageMode = .private
        scalerOutput = device.makeTexture(descriptor: td)
        scaler = s
        return s
    }
}
