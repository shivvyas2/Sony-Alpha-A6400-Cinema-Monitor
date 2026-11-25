import SwiftUI
import SonyCameraKit
import ImageIO

/// Decodes a capture: a 2048-px proxy first (fast), then the full image. ARW goes through ImageIO's RAW support.
enum ReviewDecoder {
    struct Decoded { var full: CGImage; var proxy: CGImage; var orientation: CGImagePropertyOrientation }

    /// Both images come out upright (EXIF rotation applied), so zooming in never turns a vertical shot on its side.
    static func decode(url: URL) -> Decoded? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        func render(_ size: Int) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size,
                                                         kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let proxy = render(2048) else { return nil }
        let longEdge = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let full: CGImage? = orientation == .up
            ? CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            : (longEdge > 0 ? render(longEdge) : nil)
        return Decoded(full: full ?? proxy, proxy: proxy, orientation: orientation)
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
    /// AF point in the upright picture.
    @State private var afPoint: CGPoint?
    @State private var zoom: CGFloat = 0          // 0 = fit, else image pixels per screen pixel (1 = 100 %, 2 = 200 %)
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var failed = false

    private var current: CapturedImage? { overlays.reviewShowsRAW ? (shot.raw ?? shot.jpeg) : (shot.jpeg ?? shot.raw) }

    var body: some View {
        GeometryReader { geo in
            // Phones: the header takes two rows and the loupe shares the space with the picture.
            let phone = min(geo.size.width, geo.size.height) < 500
            let portrait = geo.size.height > geo.size.width
            ZStack {
                Color.black
                if let img = proxyOrFull {
                    picture(img, in: geo.size, centerY: phone && portrait ? portraitCenterY(img, geo.size) : geo.size.height / 2)
                } else if failed {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark").font(.system(size: 40)).foregroundStyle(Theme.dim)
                        Text("Cannot decode \(current?.filename ?? "file")").font(Theme.mono(12)).foregroundStyle(Theme.dim)
                    }
                } else {
                    ProgressView().controlSize(.large)
                }
                if let full, let report { loupe(full, report: report, size: loupeSize(geo.size, phone: phone, portrait: portrait), phone: phone) }
                VStack(alignment: .leading, spacing: 6) {
                    if phone && portrait { phoneHeader } else { header }
                    if overlays.qualityCheck { QualityOverlay(quality: session.quality[shot.id], compact: phone).padding(.leading, phone && portrait ? 8 : 12) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { load() }
        .onChange(of: current?.url) { _, _ in load() }
    }

    /// Portrait phone: a landscape shot sits under the header so the loupe fits below it.
    private func portraitCenterY(_ img: CGImage, _ size: CGSize) -> CGFloat {
        let fit = fitRect(img, in: size)
        return zoom == 0 && fit.height < size.height * 0.5 ? min(size.height / 2, Self.phoneTop + fit.height / 2) : size.height / 2
    }
    private static let phoneTop: CGFloat = 108

    private func loupeSize(_ size: CGSize, phone: Bool, portrait: Bool) -> CGSize {
        guard phone else { return CGSize(width: 360, height: 240) }
        let w = portrait ? min(360, size.width - 32) : min(360, size.width * 0.34)
        return CGSize(width: w, height: w * 2 / 3)
    }

    private var proxyOrFull: CGImage? { zoom == 0 ? (proxy ?? full) : (full ?? proxy) }

    // MARK: Picture

    private func fitRect(_ img: CGImage, in size: CGSize) -> CGRect {
        let aspect = CGFloat(img.width) / CGFloat(img.height)
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func picture(_ img: CGImage, in size: CGSize, centerY: CGFloat) -> some View {
        let fit = fitRect(img, in: size).offsetBy(dx: 0, dy: centerY - size.height / 2)
        let fullWidth = CGFloat(full?.width ?? img.width)
        let scale: CGFloat = zoom == 0 ? 1 : (fullWidth / displayScale * zoom) / fit.width
        let shown = CGSize(width: fit.width * scale, height: fit.height * scale)
        return ZStack {
            Image(decorative: img, scale: 1).resizable().interpolation(zoom == 0 ? .high : .none)
                .frame(width: shown.width, height: shown.height)
                .offset(pan)
                .position(x: size.width / 2, y: centerY)
            if let report, zoom == 0 {
                // where the image is actually sharpest, so a MISSED verdict says where focus went
                Rectangle().stroke(Theme.warn, lineWidth: 1.5).frame(width: fit.width / CGFloat(report.tiles), height: fit.height / CGFloat(report.tiles))
                    .position(x: fit.minX + fit.width * report.peakPoint.x, y: fit.minY + fit.height * report.peakPoint.y)
                BracketFrame().stroke(verdict(report).color, lineWidth: 2)
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

    /// The AF area's verdict. It compares that area with the rest of the same frame, so it only holds when the frame
    /// has a sharp part at all, and only when a point was actually picked.
    private func verdict(_ report: FocusReport) -> (text: String, color: Color) {
        if let q = session.quality[shot.id], q.blurLevel == .bad { return (q.blur.rawValue, Theme.rec) }
        guard afPoint != nil else { return ("CENTER", .white) }
        if session.quality[shot.id]?.subjectSharp == true { return (FocusVerdict.inFocus.rawValue, Theme.ok) }
        switch report.verdict {
        case .inFocus: return (report.verdict.rawValue, Theme.ok)
        case .soft: return (report.verdict.rawValue, Theme.warn)
        case .missed: return (report.verdict.rawValue, Theme.rec)
        }
    }

    private func loupe(_ img: CGImage, report: FocusReport, size loupeSize: CGSize, phone: Bool) -> some View {
        let cropW = Int(loupeSize.width * displayScale), cropH = Int(loupeSize.height * displayScale)
        let cx = Int(CGFloat(img.width) * loupeCenter.x), cy = Int(CGFloat(img.height) * loupeCenter.y)
        let crop = CGRect(x: max(0, min(img.width - cropW, cx - cropW / 2)), y: max(0, min(img.height - cropH, cy - cropH / 2)), width: cropW, height: cropH)
        let onLeft = loupeCenter.x > 0.5
        let v = verdict(report)
        return VStack(alignment: .leading, spacing: 0) {
            if let c = img.cropping(to: crop) {
                Image(decorative: c, scale: displayScale).interpolation(.none)
                    .frame(width: loupeSize.width, height: loupeSize.height).clipped()
                    .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1))
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(v.text).font(.system(size: phone ? 13 : 15, weight: .heavy)).foregroundStyle(v.color).lineLimit(1)
                Text(String(format: "%.0f%% of peak", report.ratio * 100)).font(Theme.mono(phone ? 10 : 11)).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
                Text("100%").font(Theme.label(9)).tracking(1.2).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 8).frame(width: loupeSize.width, height: 26)
            .background(Color.black.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: onLeft ? .bottomLeading : .bottomTrailing)
        .padding(phone ? 8 : 16).padding(.bottom, phone ? 16 : 0)
        .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            liveButton
            Text(current?.filename ?? "").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            kindBadge
            if let full { Text(String(full.width) + "×" + String(full.height)).font(Theme.mono(12)).foregroundStyle(Theme.dim).lineLimit(1) }
            Text(shot.exposure.summary).font(Theme.mono(12)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 4)
            if shot.transferring { Text(shot.raw == nil ? "TRANSFERRING RAW…" : "TRANSFERRING…").font(Theme.label(10)).tracking(1.5).foregroundStyle(Theme.warn).lineLimit(1) }
            if let e = shot.error { Text(e).font(Theme.mono(11)).foregroundStyle(Theme.warn).lineLimit(1) }
            zoomAndCount
            saveAndExport
        }
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 12).frame(height: 32)
        .background(Color.black.opacity(0.6))
    }

    /// Portrait phone: names and actions on one row, the exposure on the next.
    private var phoneHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                liveButton
                Text(current?.filename ?? "").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                kindBadge
                Spacer(minLength: 4)
                saveAndExport
            }
            .frame(height: 36)
            HStack(spacing: 10) {
                Text(shot.exposure.summary).font(Theme.mono(12)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if let e = shot.error { Text(e).font(Theme.mono(10)).foregroundStyle(Theme.warn).lineLimit(1) }
                zoomAndCount
            }
            .frame(height: 24)
        }
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.6))
    }

    private var liveButton: some View {
        Button { session.review(nil) } label: { Text("◀ LIVE").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).fixedSize().frame(height: 32).contentShape(Rectangle()) }
            .buttonStyle(.plain).focusEffectDisabled()
    }

    private var zoomAndCount: some View {
        HStack(spacing: 10) {
            Text(zoom == 0 ? "FIT" : "\(Int(zoom * 100))%").font(Theme.label(10)).tracking(1.5).foregroundStyle(Theme.dim)
            Text("\(session.captures.firstIndex(where: { $0.id == shot.id }).map { $0 + 1 } ?? 0)/\(session.captures.count)").font(Theme.mono(12)).foregroundStyle(Theme.dim)
        }
        .fixedSize()
    }

    /// The system share menu: Photos, Lightroom, Instagram, AirDrop, whatever is installed.
    @ViewBuilder private var saveAndExport: some View {
        if let img = current {
            HStack(spacing: 12) {
                #if !os(macOS)
                if img.kind == .jpeg { PhotoSaveMark(image: img) }
                #endif
                ShareLink(item: img.url) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .bold))
                        Text("EXPORT").font(.system(size: 11, weight: .heavy))
                    }
                    .foregroundStyle(.white).frame(height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }
            .fixedSize()
        }
    }

    @ViewBuilder private var kindBadge: some View {
            if shot.hasBoth {
                Button { overlays.reviewShowsRAW.toggle() } label: {
                    Text(overlays.reviewShowsRAW ? "RAW" : "JPEG").font(.system(size: 11, weight: .heavy)).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Color.white, in: RoundedRectangle(cornerRadius: 2))
                }.buttonStyle(.plain).focusEffectDisabled()
            } else {
                Text(current?.kind.rawValue ?? "").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white, lineWidth: 1))
            }
    }

    // MARK: Loading

    private func load() {
        guard let img = current else { failed = true; return }
        guard decodingURL != img.url else { return }
        decodingURL = img.url
        full = nil; proxy = nil; report = nil; failed = false
        zoom = 0; pan = .zero; panStart = .zero
        afPoint = shot.afPoint
        loupeCenter = shot.afPoint ?? CGPoint(x: 0.5, y: 0.5)
        let url = img.url, sensorAF = shot.afPoint
        Task.detached(priority: .userInitiated) {
            guard let d = ReviewDecoder.decode(url: url) else { await MainActor.run { if decodingURL == url { failed = true } }; return }
            let af = sensorAF.map { ShotQualityAnalyzer.displayPoint($0, d.orientation) }
            // A newer shot may have replaced this one while it decoded.
            await MainActor.run {
                guard decodingURL == url else { return }
                proxy = d.proxy; afPoint = af; loupeCenter = af ?? CGPoint(x: 0.5, y: 0.5)
            }
            let r = FocusAnalyzer.analyze(d.full, afPoint: af)
            await MainActor.run { if decodingURL == url { full = d.full; report = r } }
        }
    }
}
