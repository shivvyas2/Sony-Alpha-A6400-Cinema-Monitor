import SwiftUI
import SonyCameraKit

/// Cinema monitor layout: exposure strip above, status strip below, picture between, tools on the edges.
public struct MonitorView: View {
    public init() {}
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    @State private var processor = FrameProcessor()
    @State private var processed: CIImage?
    @State private var scope: CGImage?
    @State private var afFlash = false
    @State private var analyzer = SceneAnalyzer()
    @State private var assist = AssistController()

    public var body: some View {
        VStack(spacing: 0) {
            if !overlays.hideHUD { TopStrip() }
            ZStack {
                picture
                if !overlays.hideHUD, overlays.assist, assist.visible {
                    VStack { HStack { AssistStrip(controller: assist).padding(.leading, 60).padding(.top, 8); Spacer() }; Spacer() }
                }
                if !overlays.hideHUD {
                    HStack(spacing: 0) {
                        LeftTools().padding(.leading, 6)
                        Spacer()
                        RightTools().padding(.trailing, 6)
                    }
                    if overlays.showMenu {
                        HStack { Spacer(); SettingsPanel().padding(.trailing, 58) }
                    }
                }
            }
            if !overlays.hideHUD { BottomStrip() }
        }
        .background(Theme.field)
        .onChange(of: session.frame, initial: true) { _, f in reprocess(f) }
        .onChange(of: overlays.peaking) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.peakingColor) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.zebra) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.falseColor) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.scope) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.profile) { _, _ in updateLUT(); reprocess(session.frame) }
        .onChange(of: overlays.lutOn) { _, _ in updateLUT(); reprocess(session.frame) }
        .onChange(of: overlays.customLUTName) { _, _ in updateLUT(); reprocess(session.frame) }
        .onChange(of: overlays.rotation) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.feedColorSpace) { _, _ in reprocess(session.frame) }
        .onAppear { updateLUT() }
    }

    private var picture: some View {
        GeometryReader { geo in
            let layout = imageLayout(in: geo.size)
            let rect = layout.rect
            ZStack {
                Color.black
                if let img = processed {
                    // One GPU path for everything: Core Image chain → Metal (Lanczos or MetalFX) → colour-managed layer.
                    MetalFrameView(image: img, enhanced: overlays.enhanced, sharpen: overlays.detail ? 0.35 : 0, colorSpace: overlays.feedColorSpace.cgColorSpace)
                    .frame(width: layout.fullSize.width, height: layout.fullSize.height)
                    .position(x: rect.midX, y: rect.midY)
                    .clipShape(Rectangle().path(in: rect))
                } else {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.large)
                        Text("WAITING FOR LIVE VIEW").font(Theme.label(11)).tracking(3).foregroundStyle(Theme.dim)
                    }
                }
                FrameOverlays(rect: rect)
                if session.state.isRecording {
                    Rectangle().stroke(Theme.rec, lineWidth: 3).frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                }
                if overlays.magnify {
                    Text("2.00×").font(Theme.strip(13)).foregroundStyle(Theme.accent)
                        .position(x: rect.midX, y: rect.minY + 16)
                }
                afMarker(in: rect, layout: layout)
                if overlays.assist, let p = assist.pendingAF {
                    let fx = (p.x - layout.cropX) / layout.cropWidth, fy = (p.y - layout.cropY) / layout.cropHeight
                    BracketFrame().stroke(Theme.warn, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: rect.width * 0.09, height: rect.width * 0.09)
                        .position(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
                        .clipShape(Rectangle().path(in: rect)).allowsHitTesting(false)
                }
                Color.clear.contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    .onTapGesture { loc in
                        var x = layout.cropX + loc.x / rect.width * layout.cropWidth
                        var y = layout.cropY + loc.y / rect.height * layout.cropHeight
                        // Undo the display rotation so the camera gets sensor coordinates.
                        if overlays.rotation == 90 { (x, y) = (y, 1 - x) } else if overlays.rotation == 270 { (x, y) = (1 - y, x) }
                        flashAF()
                        Task { await session.touchAF(x: x, y: y) }
                    }
                if overlays.scope != .none, let scope, !overlays.hideHUD {
                    ScopeInset(kind: overlays.scope, image: scope)
                        .position(x: rect.minX + 60 + CGFloat(scope.width) / 2, y: rect.maxY - 18 - CGFloat(scope.height) / 2)
                }
            }
        }
    }

    private func updateLUT() { processor.lutCube = overlays.activeLUT }

    /// Builds the lazy GPU pipeline for the frame (cheap: no pixels move here) and, if a scope is on,
    /// computes it from a small GPU-downsampled tile off the main thread.
    private func reprocess(_ frame: CIImage?) {
        guard let frame else { processed = nil; scope = nil; return }
        // The frame carries raw values; interpret them as sRGB or Rec.709 (a tag, not a conversion).
        let source = frame.matchedToWorkingSpace(from: overlays.feedColorSpace.cgColorSpace) ?? frame
        let p = processor
        processed = p.pipeline(source, peaking: overlays.peaking, zebra: overlays.zebra, zebraLevel: overlays.zebraLevel,
                               falseColor: overlays.falseColor, rotation: overlays.rotation, peakingColor: overlays.peakingColor.rgb)
        if ProcessInfo.processInfo.environment["CINEMAHUD_TRACE"] == "1" { NSLog("trace: frame %@ -> processed %@ lut=%d", "\(frame.extent)", "\(processed?.extent ?? .zero)", p.lutCube != nil ? 1 : 0) }
        if overlays.assist {
            // Measure the colour-interpreted source (before LUT and effects) in display orientation.
            let rotated = overlays.rotation == 0 ? source : source.oriented(overlays.rotation == 90 ? .right : (overlays.rotation == 270 ? .left : .down))
            let sensorAF = session.focusCheckPoint ?? session.state.touchAFPoint.map { CGPoint(x: $0.x / 100, y: $0.y / 100) }
            let af = sensorAF.map { AssistController.displayPoint($0, rotation: overlays.rotation) }
            let (st, prof, fps, mode) = (session.state, overlays.profile, overlays.projectFPS, overlays.shootingMode)
            let ctl = assist
            analyzer.analyze(rotated, afPoint: af) { m in ctl.ingest(measurements: m, state: st, profile: prof, projectFPS: fps, shootingMode: mode) }
        }
        let kind = overlays.scope
        guard kind != .none else { scope = nil; return }
        // Scopes read the picture after the LUT, before effects paint on it.
        let base = p.pipeline(source, peaking: false, zebra: false, zebraLevel: 1, falseColor: false, rotation: 0, effects: false)
        Task.detached(priority: .utility) {
            let sc: CGImage?
            switch kind {
            case .none: sc = nil
            case .waveform: sc = p.waveform(base)
            case .parade: sc = p.parade(base)
            case .histogram: sc = p.histogram(base)
            case .vector: sc = p.vectorscope(base)
            }
            await MainActor.run { scope = sc }
        }
    }

    struct ImageLayout {
        var rect: CGRect
        var fullSize: CGSize
        var cropX: CGFloat, cropY: CGFloat, cropWidth: CGFloat, cropHeight: CGFloat   // fractions of the full frame
    }

    /// Native aspect of the picture as displayed (after rotation).
    private var displayedNativeAspect: CGFloat {
        let w = session.frameSize.width, h = session.frameSize.height
        guard w > 0, h > 0 else { return 3.0 / 2.0 }
        return overlays.rotation == 0 ? w / h : h / w
    }

    /// Aspect-fits the frame (or its crop: wide cinema ratios trim top/bottom, vertical social ratios trim the
    /// sides, and 2× magnification trims both) into the available size.
    private func imageLayout(in size: CGSize) -> ImageLayout {
        let native = displayedNativeAspect
        var aspect = native
        var cropH: CGFloat = 1, cropW: CGFloat = 1
        if let t = overlays.crop.value {
            let target = CGFloat(t)
            if target > native { aspect = target; cropH = native / target }        // letterbox crop
            else if target < native { aspect = target; cropW = target / native }   // pillar crop (vertical formats)
        }
        let zoom: CGFloat = overlays.magnify ? 2 : 1
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        let rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        let fullW = w / cropW * zoom, fullH = h / cropH * zoom
        let cw = cropW / zoom, ch = cropH / zoom
        return ImageLayout(rect: rect, fullSize: CGSize(width: fullW, height: fullH),
                           cropX: (1 - cw) / 2, cropY: (1 - ch) / 2, cropWidth: cw, cropHeight: ch)
    }

    private func flashAF() { afFlash = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { afFlash = false } }

    @ViewBuilder private func afMarker(in rect: CGRect, layout: ImageLayout) -> some View {
        if let p = session.state.touchAFPoint, session.state.touchAFSet {
            let color: Color = session.state.focusStatus == "Focused" ? Theme.ok : (session.state.focusStatus == "Failed" ? Theme.rec : Theme.accent)
            let fx = (CGFloat(p.x) / 100 - layout.cropX) / layout.cropWidth
            let fy = (CGFloat(p.y) / 100 - layout.cropY) / layout.cropHeight
            RoundedRectangle(cornerRadius: 2).stroke(color, lineWidth: 1.5)
                .frame(width: rect.width * 0.09, height: rect.width * 0.09)
                .position(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
                .scaleEffect(afFlash ? 1.25 : 1).animation(.easeOut(duration: 0.25), value: afFlash)
                .clipShape(Rectangle().path(in: rect))
        }
    }
}

/// Scope inset drawn over the picture, translucent like a viewfinder overlay.
struct ScopeInset: View {
    let kind: ScopeKind
    let image: CGImage
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(decorative: image, scale: 1).resizable().interpolation(.none)
                .frame(width: CGFloat(image.width), height: CGFloat(image.height))
                .opacity(0.9)
            HStack {
                Text(kind.title.uppercased()).font(Theme.label(8)).tracking(1.4)
                Spacer()
                if kind == .waveform || kind == .parade { Text("0 – 100 IRE").font(Theme.label(8)) }
            }
            .foregroundStyle(Theme.dim).frame(width: CGFloat(image.width))
        }
        .padding(5)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
        .allowsHitTesting(false)
    }
}

/// Frame lines in the viewfinder idiom: red action-safe rectangle with edge ticks, thirds, centre cross.
struct FrameOverlays: View {
    @Environment(OverlaySettings.self) private var overlays
    let rect: CGRect

    var body: some View {
        Canvas { ctx, _ in
            let thin = StrokeStyle(lineWidth: 1)
            if overlays.grid {
                let safe = rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04)
                ctx.stroke(Path(safe), with: .color(Theme.rec.opacity(0.9)), style: thin)
                var ticks = Path()
                let t: CGFloat = 10
                for (x, y, dx, dy) in [(safe.midX, safe.minY, 0.0, 1.0), (safe.midX, safe.maxY, 0.0, -1.0), (safe.minX, safe.midY, 1.0, 0.0), (safe.maxX, safe.midY, -1.0, 0.0)] {
                    ticks.move(to: CGPoint(x: x, y: y)); ticks.addLine(to: CGPoint(x: x + dx * t, y: y + dy * t))
                }
                ctx.stroke(ticks, with: .color(Theme.rec), style: StrokeStyle(lineWidth: 2))
                var thirds = Path()
                for i in 1 ..< 3 {
                    let x = safe.minX + safe.width * CGFloat(i) / 3, y = safe.minY + safe.height * CGFloat(i) / 3
                    thirds.move(to: CGPoint(x: x, y: safe.minY)); thirds.addLine(to: CGPoint(x: x, y: safe.maxY))
                    thirds.move(to: CGPoint(x: safe.minX, y: y)); thirds.addLine(to: CGPoint(x: safe.maxX, y: y))
                }
                ctx.stroke(thirds, with: .color(.white.opacity(0.16)), style: thin)
            }
            if overlays.frameGuides {
                let target = overlays.guideRatio.value, native = rect.width / rect.height
                var p = Path()
                if target >= native {
                    let h = rect.width / target
                    let top = rect.midY - h / 2, bottom = rect.midY + h / 2
                    p.move(to: CGPoint(x: rect.minX, y: top)); p.addLine(to: CGPoint(x: rect.maxX, y: top))
                    p.move(to: CGPoint(x: rect.minX, y: bottom)); p.addLine(to: CGPoint(x: rect.maxX, y: bottom))
                    ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, top - rect.minY))), with: .color(.black.opacity(0.5)))
                    ctx.fill(Path(CGRect(x: rect.minX, y: bottom, width: rect.width, height: max(0, rect.maxY - bottom))), with: .color(.black.opacity(0.5)))
                } else {
                    let w = rect.height * target
                    let left = rect.midX - w / 2, right = rect.midX + w / 2
                    p.move(to: CGPoint(x: left, y: rect.minY)); p.addLine(to: CGPoint(x: left, y: rect.maxY))
                    p.move(to: CGPoint(x: right, y: rect.minY)); p.addLine(to: CGPoint(x: right, y: rect.maxY))
                    ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: max(0, left - rect.minX), height: rect.height)), with: .color(.black.opacity(0.5)))
                    ctx.fill(Path(CGRect(x: right, y: rect.minY, width: max(0, rect.maxX - right), height: rect.height)), with: .color(.black.opacity(0.5)))
                }
                ctx.stroke(p, with: .color(.white.opacity(0.7)), style: thin)
            }
            if overlays.safeAreas {
                ctx.stroke(Path(rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.05)), with: .color(.white.opacity(0.5)), style: thin)
                ctx.stroke(Path(rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.10)), with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            if overlays.diagonals {
                var d = Path()
                d.move(to: CGPoint(x: rect.minX, y: rect.minY)); d.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                d.move(to: CGPoint(x: rect.maxX, y: rect.minY)); d.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                ctx.stroke(d, with: .color(.white.opacity(0.25)), style: thin)
            }
            if overlays.centerMarker {
                var p = Path()
                let c = CGPoint(x: rect.midX, y: rect.midY), s: CGFloat = 12, gap: CGFloat = 4
                p.move(to: CGPoint(x: c.x - s, y: c.y)); p.addLine(to: CGPoint(x: c.x - gap, y: c.y))
                p.move(to: CGPoint(x: c.x + gap, y: c.y)); p.addLine(to: CGPoint(x: c.x + s, y: c.y))
                p.move(to: CGPoint(x: c.x, y: c.y - s)); p.addLine(to: CGPoint(x: c.x, y: c.y - gap))
                p.move(to: CGPoint(x: c.x, y: c.y + gap)); p.addLine(to: CGPoint(x: c.x, y: c.y + s))
                ctx.stroke(p, with: .color(.white.opacity(0.85)), style: thin)
            }
        }
        .allowsHitTesting(false)
    }
}
