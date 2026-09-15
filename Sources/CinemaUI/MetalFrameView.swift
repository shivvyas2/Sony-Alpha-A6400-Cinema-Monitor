import SwiftUI
import MetalKit
#if canImport(MetalFX)
import MetalFX
#endif
import MetalPerformanceShaders

/// Draws the live view through Metal. In enhanced mode the frame is upscaled with MetalFX's
/// spatial scaler (edge-aware reconstruction, no added latency); otherwise Lanczos resampling.
#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

struct MetalFrameView: PlatformViewRepresentable {
    /// Lazy Core Image pipeline output; rendered by the GPU straight into the renderer's texture.
    var image: CIImage?
    var enhanced: Bool
    /// Detail-recovery amount after upscaling (0 = pure reconstruction, colour and tone untouched).
    var sharpen: Float = 0
    /// Colour space the frame's values are in; the layer is tagged with it so macOS converts to the display profile.
    var colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func makeCoordinator() -> FrameRenderer { FrameRenderer() }

    #if os(macOS)
    func makeNSView(context: Context) -> MTKView { makeView(context: context) }
    func updateNSView(_ v: MTKView, context: Context) { updateView(v, context: context) }
    #else
    func makeUIView(context: Context) -> MTKView { makeView(context: context) }
    func updateUIView(_ v: MTKView, context: Context) { updateView(v, context: context) }
    #endif

    private func makeView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: context.coordinator.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = false
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        v.autoResizeDrawable = true
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Colour management: the frame is decoded into sRGB, so tell the compositor the layer is sRGB.
        // Without this a P3 display shows the camera's colours oversaturated.
        #if os(macOS)
        v.layer?.isOpaque = true
        v.colorspace = colorSpace
        #else
        v.isOpaque = true
        (v.layer as? CAMetalLayer)?.colorspace = colorSpace
        #endif
        v.delegate = context.coordinator
        return v
    }

    private func updateView(_ v: MTKView, context: Context) {
        let r = context.coordinator
        r.enhanced = enhanced
        r.sharpen = sharpen
        if r.colorSpace != colorSpace {
            r.colorSpace = colorSpace; r.imageDirty = true
            #if os(macOS)
            v.colorspace = colorSpace
            #else
            (v.layer as? CAMetalLayer)?.colorspace = colorSpace
            #endif
        }
        if r.image !== image { r.image = image; r.imageDirty = true }
        #if os(macOS)
        v.needsDisplay = true
        #else
        v.setNeedsDisplay()
        #endif
    }
}

final class FrameRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private lazy var lanczos = MPSImageLanczosScale(device: device)
    private let metalFXSupported: Bool

    var image: CIImage?
    var imageDirty = false
    var enhanced = false
    var colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "CinemaHUD.display"])
    /// Last output size, for the HUD.
    private(set) var outputSize: CGSize = .zero
    static let outputSizeChanged = Notification.Name("CinemaHUD.outputSizeChanged")

    private var input: MTLTexture?
    #if canImport(MetalFX)
    private var scaler: MTLFXSpatialScaler?
    #endif
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
        #if canImport(MetalFX)
        metalFXSupported = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        #else
        metalFXSupported = false
        #endif
        super.init()
        if let lib = try? device.makeLibrary(source: Self.sharpenSource, options: nil), let fn = lib.makeFunction(name: "sharpen") {
            sharpenPipeline = try? device.makeComputePipelineState(function: fn)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let image, let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        let iw = Int(image.extent.width.rounded()), ih = Int(image.extent.height.rounded())
        guard iw > 0, ih > 0 else { return }
        if input == nil || input!.width != iw || input!.height != ih {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: iw, height: ih, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]
            d.storageMode = .private
            input = device.makeTexture(descriptor: d)
            #if canImport(MetalFX)
            scaler = nil
            #endif
        }
        guard let input else { return }
        if imageDirty {
            // Core Image runs the whole filter chain on the GPU straight into the texture. CI images are
            // bottom-up and Metal textures top-down, so flip once here (the only place it matters).
            let flipped = image.oriented(.downMirrored)
            ciContext.render(flipped, to: input, commandBuffer: cb, bounds: flipped.extent, colorSpace: colorSpace)
            imageDirty = false
        }
        let dst = drawable.texture
        let useFX = enhanced && metalFXSupported && dst.width >= input.width && dst.height >= input.height
        #if canImport(MetalFX)
        let fxScaler = useFX ? spatialScaler(inW: input.width, inH: input.height, outW: dst.width, outH: dst.height) : nil
        #else
        let fxScaler: AnyObject? = nil
        #endif
        if useFX, fxScaler != nil, let out = scalerOutput {
            #if canImport(MetalFX)
            if let scaler = fxScaler {
                scaler.colorTexture = input
                scaler.outputTexture = out
                scaler.encode(commandBuffer: cb)
            }
            #endif
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

    private func sharpenTexture(w: Int, h: Int) -> MTLTexture? {
        if let t = sharpenOutput, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
        sharpenOutput = device.makeTexture(descriptor: d)
        return sharpenOutput
    }

    #if canImport(MetalFX)
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
    #endif
}
