import SwiftUI
import SonyCameraKit
import ImageIO

/// Decodes a capture: a 2048-px proxy to show at once, then the full image. ARW goes through ImageIO's RAW support.
enum ReviewDecoder {
    /// Both images come out upright (EXIF rotation applied), so zooming in never turns a vertical shot on its side.
    struct Source {
        private let src: CGImageSource
        private let longEdge: Int
        let orientation: CGImagePropertyOrientation

        init?(url: URL) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            self.src = src
            orientation = (props?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
            longEdge = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }

        func proxy() -> CGImage? { render(2048) }
        func full() -> CGImage? {
            orientation == .up ? CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                : (longEdge > 0 ? render(longEdge) : nil)
        }
        private func render(_ size: Int) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size,
                                                         kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
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
    @State private var shownID: CapturedImage.ID?
    @State private var loupeCenter = CGPoint(x: 0.5, y: 0.5)
    /// AF point in the upright picture.
    @State private var afPoint: CGPoint?
    /// 1 = the whole picture, otherwise how many times larger than that.
    @State private var scale: CGFloat = 1
    /// Where the zoomed picture's middle is; nil = its place in the layout.
    @State private var center: CGPoint?
    @State private var gestureStart: (scale: CGFloat, center: CGPoint)?
    @State private var pinching = false
    @State private var failed = false

    private var current: CapturedImage? { overlays.reviewShowsRAW ? (shot.raw ?? shot.jpeg) : (shot.jpeg ?? shot.raw) }

    var body: some View {
        GeometryReader { geo in
            // Phones: the header takes two rows and the crop shares the space with the picture.
            let phone = min(geo.size.width, geo.size.height) < 500
            let portrait = geo.size.height > geo.size.width
            let layout = self.layout(geo.size, phone: phone, portrait: portrait)
            ZStack(alignment: .topLeading) {
                Color.black
                if let img = image {
                    picture(img, layout)
                } else if failed {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark").font(.system(size: 40)).foregroundStyle(Theme.dim)
                        Text("Cannot decode \(current?.filename ?? "file")").font(Theme.mono(12)).foregroundStyle(Theme.dim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Zoomed in on a phone the picture itself is the crop, and gets the whole screen.
                if scale == 1 || !phone {
                    if let full, let report { loupe(full, report: report, rect: layout.loupe, phone: phone) }
                    else if image != nil, phone, !layout.loupeOverPicture { loupePlaceholder(layout.loupe) }
                }
                Group { if phone && portrait { phoneHeader(layout) } else { header(layout, phone: phone) } }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(alignment: .top) { if phone { Color.black.opacity(0.6).frame(height: layout.viewport.minY) } }
                if overlays.qualityCheck {
                    // Portrait has a row for it; elsewhere it lies on the picture's corner.
                    let on = scale > 1 ? layout.viewport : (layout.picture.width < 300 && !layout.loupeOverPicture ? layout.loupe : layout.picture)
                    let at = !phone ? CGPoint(x: 12, y: 38) : (portrait ? CGPoint(x: 2, y: 66) : CGPoint(x: on.minX + 8, y: on.minY + 8))
                    QualityOverlay(quality: session.quality[shot.id], compact: phone)
                        .frame(maxWidth: phone && !portrait ? on.width - 16 : geo.size.width - 4, alignment: .leading)
                        .offset(x: at.x, y: at.y)
                }
            }
            .onChange(of: geo.size) { _, _ in fitPicture() }
        }
        .onAppear { load() }
        .onChange(of: current?.url) { _, _ in load() }
    }

    private var image: CGImage? { scale > 1 ? (full ?? proxy) : (proxy ?? full) }

    private func layout(_ size: CGSize, phone: Bool, portrait: Bool) -> ReviewLayout {
        let aspect = image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1.5
        if phone {
            // Portrait keeps a row for the check strip; in landscape it lies over the picture's corner.
            return ReviewLayout(size: size, aspect: aspect, header: portrait ? (overlays.qualityCheck ? 96 : 60) : 36)
        }
        var l = ReviewLayout(size: size, aspect: aspect, header: 0)
        let fit = ReviewLayout.fit(aspect, in: size)
        l.picture = CGRect(x: (size.width - fit.width) / 2, y: (size.height - fit.height) / 2, width: fit.width, height: fit.height)
        let w: CGFloat = 360, h: CGFloat = 240 + ReviewLayout.caption
        l.loupe = CGRect(x: loupeCenter.x > 0.5 ? 16 : size.width - w - 16, y: size.height - h - 16, width: w, height: h)
        l.loupeOverPicture = true
        return l
    }

    // MARK: Picture

    private func picture(_ img: CGImage, _ layout: ReviewLayout) -> some View {
        let fit = layout.picture
        let shown = CGSize(width: fit.width * scale, height: fit.height * scale)
        let mid = scale == 1 ? CGPoint(x: fit.midX, y: fit.midY) : (center ?? CGPoint(x: fit.midX, y: fit.midY))
        return ZStack {
            Image(decorative: img, scale: 1).resizable().interpolation(percent(layout) >= 100 ? .none : .high)
                .frame(width: shown.width, height: shown.height)
                .position(mid)
            if let report, scale == 1 {
                // where the image is actually sharpest, so a MISSED verdict says where focus went
                Rectangle().stroke(Theme.warn, lineWidth: 1.5).frame(width: fit.width / CGFloat(report.tiles), height: fit.height / CGFloat(report.tiles))
                    .position(x: fit.minX + fit.width * report.peakPoint.x, y: fit.minY + fit.height * report.peakPoint.y)
                BracketFrame().stroke(verdict(report).color, lineWidth: 2)
                    .frame(width: fit.width * 0.12, height: fit.width * 0.12)
                    .position(x: fit.minX + fit.width * loupeCenter.x, y: fit.minY + fit.height * loupeCenter.y)
            }
        }
        .clipShape(Rectangle().path(in: layout.viewport))
        .contentShape(Rectangle().path(in: layout.viewport))
        .contentShape(.accessibility, Rectangle().path(in: layout.viewport.insetBy(dx: 0, dy: 20)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo")
        .accessibilityIdentifier("reviewPicture")
        .onTapGesture(count: 2) { loc in
            withAnimation(.easeOut(duration: 0.2)) {
                if scale > 1 { fitPicture() } else { zoom(to: actualPixels(layout), around: loc, layout) }
            }
        }
        .onTapGesture { loc in
            guard scale == 1 else { return }
            loupeCenter = CGPoint(x: min(1, max(0, (loc.x - fit.minX) / fit.width)), y: min(1, max(0, (loc.y - fit.minY) / fit.height)))
        }
        .gesture(DragGesture().onChanged { v in
            guard scale > 1, !pinching else { return }
            let from = gestureStart?.center ?? mid
            if gestureStart == nil { gestureStart = (scale, from) }
            center = ReviewLayout.clamped(center: CGPoint(x: from.x + v.translation.width, y: from.y + v.translation.height), shown: shown, in: layout.viewport)
        }.onEnded { _ in if !pinching { gestureStart = nil } })
        #if !os(macOS)
        .simultaneousGesture(MagnifyGesture(minimumScaleDelta: 0.01).onChanged { v in
            if !pinching { pinching = true; gestureStart = (scale, mid) }
            guard let start = gestureStart else { return }
            let to = min(max(start.scale * v.magnification, 1), maxScale(layout))
            let c = ReviewLayout.center(start.center, zoomedBy: to / start.scale, around: v.startLocation)
            scale = to
            center = ReviewLayout.clamped(center: c, shown: CGSize(width: fit.width * to, height: fit.height * to), in: layout.viewport)
        }.onEnded { _ in
            pinching = false; gestureStart = nil
            if scale < 1.02 { withAnimation(.easeOut(duration: 0.15)) { fitPicture() } }
        })
        #endif
        .background(ScrollStepper(onStep: { d in step(d, layout) }) { Color.clear })
    }

    /// Image pixels per screen pixel, in percent.
    private func percent(_ layout: ReviewLayout) -> Int {
        guard let width = full?.width ?? proxy?.width, width > 0 else { return 0 }
        return Int((layout.picture.width * scale * displayScale / CGFloat(width) * 100).rounded())
    }
    private func actualPixels(_ layout: ReviewLayout) -> CGFloat {
        guard let width = full?.width ?? proxy?.width else { return 1 }
        return max(1, CGFloat(width) / displayScale / layout.picture.width)
    }
    private func maxScale(_ layout: ReviewLayout) -> CGFloat { actualPixels(layout) * 2 }

    private func fitPicture() { scale = 1; center = nil; gestureStart = nil; pinching = false }

    private func zoom(to new: CGFloat, around p: CGPoint, _ layout: ReviewLayout) {
        let from = center ?? CGPoint(x: layout.picture.midX, y: layout.picture.midY)
        let c = ReviewLayout.center(from, zoomedBy: new / scale, around: p)
        scale = new
        center = ReviewLayout.clamped(center: c, shown: CGSize(width: layout.picture.width * new, height: layout.picture.height * new), in: layout.viewport)
    }

    /// Scroll wheel: fit, 100 %, 200 %.
    private func step(_ delta: Int, _ layout: ReviewLayout) {
        let one = actualPixels(layout)
        let next: CGFloat = delta > 0 ? (scale < one - 0.01 ? one : one * 2) : (scale > one + 0.01 ? one : 1)
        if next <= 1 { fitPicture() } else { zoom(to: next, around: CGPoint(x: layout.viewport.midX, y: layout.viewport.midY), layout) }
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

    private func loupe(_ img: CGImage, report: FocusReport, rect: CGRect, phone: Bool) -> some View {
        let size = CGSize(width: rect.width, height: rect.height - ReviewLayout.caption)
        let cropW = min(img.width, Int(size.width * displayScale)), cropH = min(img.height, Int(size.height * displayScale))
        let cx = Int(CGFloat(img.width) * loupeCenter.x), cy = Int(CGFloat(img.height) * loupeCenter.y)
        let crop = CGRect(x: max(0, min(img.width - cropW, cx - cropW / 2)), y: max(0, min(img.height - cropH, cy - cropH / 2)), width: cropW, height: cropH)
        let v = verdict(report)
        return VStack(alignment: .leading, spacing: 0) {
            if let c = img.cropping(to: crop) {
                Image(decorative: c, scale: displayScale).interpolation(.none)
                    .frame(width: size.width, height: size.height).clipped()
                    .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(v.text).font(.system(size: phone ? 13 : 15, weight: .heavy)).foregroundStyle(v.color).lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
                if rect.width >= 180 {
                    Text(String(format: "%.0f%% of peak", report.ratio * 100)).font(Theme.mono(phone ? 10 : 11)).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                Text("100%").font(Theme.label(9)).tracking(1.2).foregroundStyle(Theme.dim).fixedSize()
            }
            .padding(.horizontal, 8).frame(width: rect.width, height: ReviewLayout.caption)
            .background(Color.black.opacity(0.75))
        }
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }

    /// Holds the crop's place until the full-size file is here.
    private func loupePlaceholder(_ rect: CGRect) -> some View {
        Rectangle().stroke(Color.white.opacity(0.25), lineWidth: 1)
            .overlay {
                if shot.error == nil {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(current?.isPreview == true ? "RECEIVING FULL SIZE" : "LOADING").font(Theme.label(9)).tracking(1.2).foregroundStyle(Theme.dim)
                    }
                }
            }
            .frame(width: rect.width, height: rect.height - ReviewLayout.caption)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }

    // MARK: Header

    private func header(_ layout: ReviewLayout, phone: Bool) -> some View {
        HStack(spacing: 12) {
            liveButton
            Text(current?.filename ?? "").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            kindBadge
            if !phone, let full { Text(String(full.width) + "×" + String(full.height)).font(Theme.mono(12)).foregroundStyle(Theme.dim).lineLimit(1) }
            Text(shot.exposure.summary).font(Theme.mono(12)).foregroundStyle(.white).lineLimit(1).layoutPriority(phone ? 1 : 0)
            Spacer(minLength: 4)
            if shot.transferring { Text(shot.raw == nil && current?.isPreview == false ? "TRANSFERRING RAW…" : "TRANSFERRING…").font(Theme.label(10)).tracking(1.5).foregroundStyle(Theme.warn).lineLimit(1) }
            if let e = shot.error { Text(e).font(Theme.mono(11)).foregroundStyle(Theme.warn).lineLimit(1) }
            zoomAndCount(layout)
            saveAndExport
        }
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 12).frame(height: phone ? 36 : 32)
        .background(phone ? Color.clear : Color.black.opacity(0.6))
    }

    /// Portrait phone: names and actions on one row, the exposure on the next.
    private func phoneHeader(_ layout: ReviewLayout) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                liveButton
                Text(current?.filename ?? "").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                kindBadge
                Spacer(minLength: 4)
                export
            }
            .frame(height: 36)
            HStack(spacing: 10) {
                Text(shot.exposure.summary).font(Theme.mono(12)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if let e = shot.error { Text(e).font(Theme.mono(10)).foregroundStyle(Theme.warn).lineLimit(1) }
                saveMark
                zoomAndCount(layout)
            }
            .frame(height: 24)
        }
        .padding(.horizontal, 12)
    }

    private var liveButton: some View {
        Button { session.review(nil) } label: { Text("◀ LIVE").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).fixedSize().frame(height: 32).contentShape(Rectangle()) }
            .buttonStyle(.plain).focusEffectDisabled()
    }

    private func zoomAndCount(_ layout: ReviewLayout) -> some View {
        HStack(spacing: 10) {
            Text(scale == 1 ? "FIT" : "\(percent(layout))%").font(Theme.label(10)).tracking(1.5).foregroundStyle(Theme.dim)
            Text("\(session.captures.firstIndex(where: { $0.id == shot.id }).map { $0 + 1 } ?? 0)/\(session.captures.count)").font(Theme.mono(12)).foregroundStyle(Theme.dim)
        }
        .fixedSize()
    }

    private var saveAndExport: some View {
        HStack(spacing: 12) { saveMark; export }.fixedSize()
    }

    @ViewBuilder private var saveMark: some View {
        #if !os(macOS)
        if let img = current, img.kind == .jpeg, !img.isPreview { PhotoSaveMark(image: img) }
        #endif
    }

    /// The system share menu: Photos, Lightroom, Instagram, AirDrop, whatever is installed.
    @ViewBuilder private var export: some View {
        if let img = current, !img.isPreview {
            ShareLink(item: img.url) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .bold))
                    Text("EXPORT").font(.system(size: 11, weight: .heavy))
                }
                .foregroundStyle(.white).frame(height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .fixedSize()
        } else if shot.error == nil {
            ProgressView().controlSize(.mini)
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
        full = nil; report = nil; failed = false
        if shownID != img.id {                 // else the full file taking over from its preview: nothing moves
            shownID = img.id
            proxy = nil
            fitPicture()
            afPoint = shot.afPoint
            loupeCenter = shot.afPoint ?? CGPoint(x: 0.5, y: 0.5)
        }
        let url = img.url, isPreview = img.isPreview, sensorAF = shot.afPoint, before = loupeCenter
        Task.detached(priority: .userInitiated) {
            let source = ReviewDecoder.Source(url: url)
            guard let source, let small = source.proxy() else { await MainActor.run { if decodingURL == url { failed = proxy == nil } }; return }
            let af = sensorAF.map { ShotQualityAnalyzer.displayPoint($0, source.orientation) }
            // A newer shot may have replaced this one while it decoded.
            await MainActor.run {
                guard decodingURL == url else { return }
                let untouched = loupeCenter == before && loupeCenter == (sensorAF ?? CGPoint(x: 0.5, y: 0.5))
                proxy = small; afPoint = af
                if untouched { loupeCenter = af ?? CGPoint(x: 0.5, y: 0.5) }
            }
            if isPreview { return }
            let big = source.full() ?? small
            let r = FocusAnalyzer.analyze(big, afPoint: af)
            await MainActor.run { if decodingURL == url { full = big; report = r } }
        }
    }
}
