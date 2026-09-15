import SwiftUI
import MetalKit
import MetalFX
import MetalPerformanceShaders

/// Draws the live view through Metal. In enhanced mode the frame is upscaled with MetalFX's
/// spatial scaler (edge-aware reconstruction, no added latency); otherwise Lanczos resampling.
struct MetalFrameView: NSViewRepresentable {
    var image: CGImage?
    var enhanced: Bool

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
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        let r = context.coordinator
        r.enhanced = enhanced
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
    /// Last output size, for the HUD.
    private(set) var outputSize: CGSize = .zero
    static let outputSizeChanged = Notification.Name("CinemaHUD.outputSizeChanged")

    private var input: MTLTexture?
    private var upload: (data: UnsafeMutableRawPointer, bytesPerRow: Int, w: Int, h: Int)?
    private var scaler: MTLFXSpatialScaler?
    private var scalerOutput: MTLTexture?

    override init() {
        metalFXSupported = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        super.init()
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
            if let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: out, to: dst)
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
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        if let ctx = CGContext(data: up.data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: info) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        input.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: up.data, bytesPerRow: bpr)
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
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        scalerOutput = device.makeTexture(descriptor: td)
        scaler = s
        return s
    }
}
