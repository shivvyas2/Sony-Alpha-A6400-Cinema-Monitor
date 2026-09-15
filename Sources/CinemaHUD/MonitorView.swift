import SwiftUI
import SonyCameraKit

struct MonitorView: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    @State private var processor = FrameProcessor()
    @State private var processed: CGImage?
    @State private var afFlash = false

    var body: some View {
        GeometryReader { geo in
            let layout = imageLayout(in: geo.size)
            let rect = layout.rect
            ZStack {
                Color.black
                if let img = displayImage {
                    // Draw the full frame scaled so the cropped region exactly fills `rect`, then clip to it.
                    Image(decorative: img, scale: 1).resizable().interpolation(.high)
                        .frame(width: layout.fullSize.width, height: layout.fullSize.height)
                        .position(x: rect.midX, y: rect.midY + layout.fullOffsetY)
                        .clipShape(Rectangle().path(in: rect))
                } else {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.large)
                        Text("WAITING FOR LIVE VIEW").font(Theme.label(11)).tracking(3).foregroundStyle(Theme.dim)
                    }
                }
                FrameOverlays(rect: rect)
                afMarker(in: rect)
                Color.clear.contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    .onTapGesture { loc in
                        // Map the click through the crop back to full-frame coordinates.
                        let x = loc.x / rect.width
                        let y = (layout.cropY + loc.y / rect.height * layout.cropHeight)
                        flashAF()
                        Task { await session.touchAF(x: x, y: y) }
                    }
                if !overlays.hideHUD {
                    VStack {
                        TopBar()
                        Spacer()
                        BottomBar()
                    }
                    .padding(14)
                    SideTools().padding(.trailing, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
        }
        .onChange(of: session.frame, initial: true) { _, newFrame in reprocess(newFrame) }
        .onChange(of: overlays.peaking) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.zebra) { _, _ in reprocess(session.frame) }
    }

    private var displayImage: CGImage? { (overlays.peaking || overlays.zebra) ? processed : session.frame }

    private func reprocess(_ frame: CGImage?) {
        guard let frame, overlays.peaking || overlays.zebra else { processed = nil; return }
        let p = processor, peak = overlays.peaking, zeb = overlays.zebra, lvl = overlays.zebraLevel
        Task.detached(priority: .userInitiated) {
            let out = p.process(frame, peaking: peak, zebra: zeb, zebraLevel: lvl)
            await MainActor.run { processed = out }
        }
    }

    struct ImageLayout {
        var rect: CGRect          // where the (cropped) picture is drawn
        var fullSize: CGSize      // size of the whole frame at display scale
        var fullOffsetY: CGFloat  // vertical shift of the whole frame so the crop is centred in rect
        var cropY: CGFloat        // top of crop as a fraction of full frame height (0…1)
        var cropHeight: CGFloat   // crop height as a fraction of full frame height (0…1)
    }

    /// Aspect-fits the frame (or its cinema crop) into the available size.
    private func imageLayout(in size: CGSize) -> ImageLayout {
        let native = session.frameSize.width > 0 ? session.frameSize.width / session.frameSize.height : 3.0 / 2.0
        var cropFrac: CGFloat = 1
        var aspect = native
        if let target = overlays.crop.value, CGFloat(target) > native {
            aspect = CGFloat(target)
            cropFrac = native / aspect         // portion of the frame height that survives the crop
        }
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        let rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        let fullH = h / cropFrac
        return ImageLayout(rect: rect, fullSize: CGSize(width: w, height: fullH), fullOffsetY: 0,
                           cropY: (1 - cropFrac) / 2, cropHeight: cropFrac)
    }

    private func flashAF() { afFlash = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { afFlash = false } }

    @ViewBuilder private func afMarker(in rect: CGRect) -> some View {
        if let p = session.state.touchAFPoint, session.state.touchAFSet {
            let color: Color = session.state.focusStatus == "Focused" ? Theme.focusOK : (session.state.focusStatus == "Failed" ? Theme.rec : Theme.amber)
            let cropFrac = overlays.crop.value.map { max(1, CGFloat($0) / (session.frameSize.width > 0 ? session.frameSize.width / session.frameSize.height : 1.5)) } ?? 1
            let fullH = rect.height * cropFrac
            let top = rect.midY - fullH / 2
            RoundedRectangle(cornerRadius: 2).stroke(color, lineWidth: 1.5)
                .frame(width: rect.width * 0.09, height: rect.width * 0.09)
                .position(x: rect.minX + rect.width * p.x / 100, y: top + fullH * p.y / 100)
                .clipShape(Rectangle().path(in: rect))
                .scaleEffect(afFlash ? 1.25 : 1).animation(.easeOut(duration: 0.25), value: afFlash)
        }
    }
}

/// Grid, frame guides, center marker, drawn over the fitted image rect.
struct FrameOverlays: View {
    @Environment(OverlaySettings.self) private var overlays
    let rect: CGRect

    var body: some View {
        Canvas { ctx, _ in
            let thin = StrokeStyle(lineWidth: 1)
            if overlays.grid {
                var p = Path()
                for i in 1 ..< 3 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3, y = rect.minY + rect.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
                    p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                ctx.stroke(p, with: .color(.white.opacity(0.28)), style: thin)
            }
            if overlays.frameGuides {
                let h = rect.width / 2.39
                let top = rect.midY - h / 2, bottom = rect.midY + h / 2
                var p = Path()
                p.move(to: CGPoint(x: rect.minX, y: top)); p.addLine(to: CGPoint(x: rect.maxX, y: top))
                p.move(to: CGPoint(x: rect.minX, y: bottom)); p.addLine(to: CGPoint(x: rect.maxX, y: bottom))
                ctx.stroke(p, with: .color(Theme.amber.opacity(0.8)), style: thin)
                ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, top - rect.minY))), with: .color(.black.opacity(0.45)))
                ctx.fill(Path(CGRect(x: rect.minX, y: bottom, width: rect.width, height: max(0, rect.maxY - bottom))), with: .color(.black.opacity(0.45)))
            }
            if overlays.centerMarker {
                var p = Path()
                let c = CGPoint(x: rect.midX, y: rect.midY), s: CGFloat = 12, gap: CGFloat = 4
                p.move(to: CGPoint(x: c.x - s, y: c.y)); p.addLine(to: CGPoint(x: c.x - gap, y: c.y))
                p.move(to: CGPoint(x: c.x + gap, y: c.y)); p.addLine(to: CGPoint(x: c.x + s, y: c.y))
                p.move(to: CGPoint(x: c.x, y: c.y - s)); p.addLine(to: CGPoint(x: c.x, y: c.y - gap))
                p.move(to: CGPoint(x: c.x, y: c.y + gap)); p.addLine(to: CGPoint(x: c.x, y: c.y + s))
                ctx.stroke(p, with: .color(.white.opacity(0.8)), style: thin)
            }
        }
        .allowsHitTesting(false)
    }
}
