import SwiftUI
import CoreImage
import SonyCameraKit

/// Stills mode: the live view fills the window (MetalFX always on), Sony-style overlays on top,
/// and the real capture takes over for review after each shot.
public struct PhotoView: View {
    public init() {}
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    @State private var processor = FrameProcessor()
    @State private var processed: CIImage?
    @State private var afFlash = false
    @State private var liveSharpness: Double = 0
    @State private var meter = LiveSharpnessMeter()

    public var body: some View {
        ZStack {
            Color.black
            if let shot = session.reviewShot {
                ReviewView(shot: shot)
            } else {
                livePicture
            }
        }
        .onChange(of: session.frame, initial: true) { _, f in reprocess(f) }
        .onChange(of: overlays.peaking) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.feedColorSpace) { _, _ in reprocess(session.frame) }
    }

    struct ImageLayout {
        var rect: CGRect          // where the picture sits in the view
        var fullSize: CGSize      // size of the (possibly magnified) picture
        var cropX: CGFloat, cropY: CGFloat, cropWidth: CGFloat, cropHeight: CGFloat
    }

    /// Aspect-fit, no cinema crops; 2× magnify trims both axes around the centre.
    func photoLayout(in size: CGSize) -> ImageLayout {
        let w0 = session.frameSize.width, h0 = session.frameSize.height
        let aspect = (w0 > 0 && h0 > 0) ? w0 / h0 : 3.0 / 2.0
        let zoom: CGFloat = overlays.magnify ? 2 : 1
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        let rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        return ImageLayout(rect: rect, fullSize: CGSize(width: w * zoom, height: h * zoom),
                           cropX: (1 - 1 / zoom) / 2, cropY: (1 - 1 / zoom) / 2, cropWidth: 1 / zoom, cropHeight: 1 / zoom)
    }

    private var livePicture: some View {
        GeometryReader { geo in
            let layout = photoLayout(in: geo.size)
            let rect = layout.rect
            ZStack {
                if let img = processed {
                    MetalFrameView(image: img, enhanced: true, sharpen: overlays.detail ? 0.35 : 0, colorSpace: overlays.feedColorSpace.cgColorSpace)
                        .frame(width: layout.fullSize.width, height: layout.fullSize.height)
                        .position(x: rect.midX, y: rect.midY)
                        .clipShape(Rectangle().path(in: rect))
                } else {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.large)
                        Text("WAITING FOR LIVE VIEW").font(Theme.label(11)).tracking(3).foregroundStyle(Theme.dim)
                    }
                }
                Color.clear.contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    .onTapGesture { loc in
                        let x = layout.cropX + loc.x / rect.width * layout.cropWidth
                        let y = layout.cropY + loc.y / rect.height * layout.cropHeight
                        afFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { afFlash = false }
                        Task { await session.touchAF(x: x, y: y) }
                    }
                if !overlays.hideHUD {
                    PhotoHUD(layout: layout, liveSharpness: liveSharpness, afFlash: afFlash)
                }
            }
        }
    }

    /// Same lazy GPU chain as the monitor (colour tag + optional peaking), plus the live sharpness meter.
    private func reprocess(_ frame: CIImage?) {
        guard let frame else { processed = nil; return }
        let source = frame.matchedToWorkingSpace(from: overlays.feedColorSpace.cgColorSpace) ?? frame
        processed = processor.pipeline(source, peaking: overlays.peaking, zebra: false, zebraLevel: 1, falseColor: false, rotation: 0)
        let point = session.focusCheckPoint ?? session.state.touchAFPoint.map { CGPoint(x: $0.x / 100, y: $0.y / 100) }
        meter.measure(frame, afPoint: point) { r in liveSharpness = r }
    }
}

/// Renders the live frame small on the GPU and scores the AF region, at most a few times a second.
@MainActor
final class LiveSharpnessMeter {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var inFlight = false
    private var last = Date.distantPast

    func measure(_ frame: CIImage, afPoint: CGPoint?, done: @escaping @MainActor (Double) -> Void) {
        guard !inFlight, Date().timeIntervalSince(last) > 0.15 else { return }
        inFlight = true; last = Date()
        let ctx = context
        let scale = min(1, 512 / max(frame.extent.width, frame.extent.height))
        let small = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        Task.detached(priority: .utility) {
            let ratio = ctx.createCGImage(small, from: small.extent).map { FocusAnalyzer.liveRatio($0, afPoint: afPoint) } ?? 0
            await MainActor.run { self.inFlight = false; done(ratio) }
        }
    }
}
