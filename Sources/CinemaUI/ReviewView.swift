import SwiftUI
import SonyCameraKit
import ImageIO

/// Decodes a capture: a 2048-px proxy first (fast), then the full image. ARW goes through ImageIO's RAW support.
enum ReviewDecoder {
    static func decode(url: URL) -> (full: CGImage, proxy: CGImage)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let popts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let proxy = CGImageSourceCreateThumbnailAtIndex(src, 0, popts) else { return nil }
        let full = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) ?? proxy
        return (full, proxy)
    }
}

/// Auto-review after a shot: the real file, a 100 %-pixel loupe on the AF point, and a focus verdict.
struct ReviewView: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    @Environment(\.displayScale) private var displayScale
    let shot: CapturedShot

    @State private var full: CGImage?
    @State private var proxy: CGImage?
    @State private var report: FocusReport?
    @State private var decodingURL: URL?
    @State private var loupeCenter = CGPoint(x: 0.5, y: 0.5)
    @State private var zoom: CGFloat = 0          // 0 = fit, else image pixels per screen pixel (1 = 100 %, 2 = 200 %)
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var failed = false

    private var current: CapturedImage? { overlays.reviewShowsRAW ? (shot.raw ?? shot.jpeg) : (shot.jpeg ?? shot.raw) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = proxyOrFull {
                    picture(img, in: geo.size)
                } else if failed {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark").font(.system(size: 40)).foregroundStyle(Theme.dim)
                        Text("Cannot decode \(current?.filename ?? "file")").font(Theme.mono(12)).foregroundStyle(Theme.dim)
                    }
                } else {
                    ProgressView().controlSize(.large)
                }
                header
                if let full, let report { loupe(full, report: report, in: geo.size) }
            }
        }
        .onAppear { load() }
        .onChange(of: current?.url) { _, _ in load() }
        .onChange(of: shot.afPoint) { _, p in loupeCenter = p ?? CGPoint(x: 0.5, y: 0.5) }
    }

    private var proxyOrFull: CGImage? { zoom == 0 ? (proxy ?? full) : (full ?? proxy) }

    // MARK: Picture

    private func fitRect(_ img: CGImage, in size: CGSize) -> CGRect {
        let aspect = CGFloat(img.width) / CGFloat(img.height)
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func picture(_ img: CGImage, in size: CGSize) -> some View {
        let fit = fitRect(img, in: size)
        let fullWidth = CGFloat(full?.width ?? img.width)
        let scale: CGFloat = zoom == 0 ? 1 : (fullWidth / displayScale * zoom) / fit.width
        let shown = CGSize(width: fit.width * scale, height: fit.height * scale)
        return ZStack {
            Image(decorative: img, scale: 1).resizable().interpolation(zoom == 0 ? .high : .none)
                .frame(width: shown.width, height: shown.height)
                .offset(pan)
                .position(x: size.width / 2, y: size.height / 2)
            if let report, zoom == 0 {
                // where the image is actually sharpest, so a MISSED verdict says where focus went
                Rectangle().stroke(Theme.warn, lineWidth: 1.5).frame(width: fit.width / CGFloat(report.tiles), height: fit.height / CGFloat(report.tiles))
                    .position(x: fit.minX + fit.width * report.peakPoint.x, y: fit.minY + fit.height * report.peakPoint.y)
                BracketFrame().stroke(report.verdict == .inFocus ? Theme.ok : (report.verdict == .soft ? Theme.warn : Theme.rec), lineWidth: 2)
                    .frame(width: fit.width * 0.12, height: fit.width * 0.12)
                    .position(x: fit.minX + fit.width * loupeCenter.x, y: fit.minY + fit.height * loupeCenter.y)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { loc in
            guard zoom == 0 else { return }
            loupeCenter = CGPoint(x: min(1, max(0, (loc.x - fit.minX) / fit.width)), y: min(1, max(0, (loc.y - fit.minY) / fit.height)))
        }
        .gesture(DragGesture().onChanged { v in if zoom > 0 { pan = CGSize(width: v.translation.width + panStart.width, height: v.translation.height + panStart.height) } }
                              .onEnded { _ in panStart = pan })
        #if !os(macOS)
        .simultaneousGesture(MagnificationGesture().onEnded { m in cycleZoom(m > 1 ? 1 : -1) })
        #endif
        .background(ScrollStepper(onStep: { d in cycleZoom(d) }) { Color.clear })
    }

    private func cycleZoom(_ delta: Int) {
        let steps: [CGFloat] = [0, 1, 2]
        let i = steps.firstIndex(of: zoom) ?? 0
        zoom = steps[max(0, min(steps.count - 1, i + (delta > 0 ? 1 : -1)))]
        if zoom == 0 { pan = .zero; panStart = .zero }
    }

    // MARK: Loupe and verdict

    private func loupe(_ img: CGImage, report: FocusReport, in size: CGSize) -> some View {
        let loupeSize = CGSize(width: 360, height: 240)
        let cropW = Int(loupeSize.width * displayScale), cropH = Int(loupeSize.height * displayScale)
        let cx = Int(CGFloat(img.width) * loupeCenter.x), cy = Int(CGFloat(img.height) * loupeCenter.y)
        let crop = CGRect(x: max(0, min(img.width - cropW, cx - cropW / 2)), y: max(0, min(img.height - cropH, cy - cropH / 2)), width: cropW, height: cropH)
        let onLeft = loupeCenter.x > 0.5
        let color: Color = report.verdict == .inFocus ? Theme.ok : (report.verdict == .soft ? Theme.warn : Theme.rec)
        return VStack(alignment: .leading, spacing: 0) {
            if let c = img.cropping(to: crop) {
                Image(decorative: c, scale: displayScale).interpolation(.none)
                    .frame(width: loupeSize.width, height: loupeSize.height).clipped()
                    .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1))
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(report.verdict.rawValue).font(.system(size: 15, weight: .heavy)).foregroundStyle(color)
                Text(String(format: "%.0f%% of peak", report.ratio * 100)).font(Theme.mono(11)).foregroundStyle(Theme.dim)
                Spacer()
                Text("100%").font(Theme.label(9)).tracking(1.2).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 8).frame(width: loupeSize.width, height: 26)
            .background(Color.black.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: onLeft ? .bottomLeading : .bottomTrailing)
        .padding(16)
        .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Button { session.review(nil) } label: { Text("◀ LIVE").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                .buttonStyle(.plain).focusEffectDisabled()
            Text(current?.filename ?? "").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            if shot.hasBoth {
                Button { overlays.reviewShowsRAW.toggle() } label: {
                    Text(overlays.reviewShowsRAW ? "RAW" : "JPEG").font(.system(size: 11, weight: .heavy)).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Color.white, in: RoundedRectangle(cornerRadius: 2))
                }.buttonStyle(.plain).focusEffectDisabled()
            } else {
                Text(current?.kind.rawValue ?? "").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white, lineWidth: 1))
            }
            if let full { Text(String(full.width) + "×" + String(full.height)).font(Theme.mono(12)).foregroundStyle(Theme.dim) }
            Text(shot.exposure.summary).font(Theme.mono(12)).foregroundStyle(.white)
            Spacer()
            if shot.transferring { Text(shot.raw == nil ? "TRANSFERRING RAW…" : "TRANSFERRING…").font(Theme.label(10)).tracking(1.5).foregroundStyle(Theme.warn) }
            if let e = shot.error { Text(e).font(Theme.mono(11)).foregroundStyle(Theme.warn).lineLimit(1) }
            Text(zoom == 0 ? "FIT" : "\(Int(zoom * 100))%").font(Theme.label(10)).tracking(1.5).foregroundStyle(Theme.dim)
            Text("\(session.captures.firstIndex(where: { $0.id == shot.id }).map { $0 + 1 } ?? 0)/\(session.captures.count)").font(Theme.mono(12)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(Color.black.opacity(0.6))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Loading

    private func load() {
        guard let img = current else { failed = true; return }
        guard decodingURL != img.url else { return }
        decodingURL = img.url
        full = nil; proxy = nil; report = nil; failed = false
        zoom = 0; pan = .zero; panStart = .zero
        loupeCenter = shot.afPoint ?? CGPoint(x: 0.5, y: 0.5)
        let url = img.url, af = shot.afPoint
        Task.detached(priority: .userInitiated) {
            guard let d = ReviewDecoder.decode(url: url) else { await MainActor.run { failed = true }; return }
            await MainActor.run { proxy = d.proxy }
            let r = FocusAnalyzer.analyze(d.full, afPoint: af)
            await MainActor.run { full = d.full; report = r }
        }
    }
}
