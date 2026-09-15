#if !os(macOS)
import SwiftUI
import CoreImage
import SonyCameraKit

/// iPhone / iPad monitor: the picture plus touch chrome, in either orientation, for video and photo.
public struct MobileCameraView: View {
    public init() {}
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    @State private var processor = FrameProcessor()
    @State private var processed: CIImage?
    @State private var meter = LiveSharpnessMeter()
    @State private var liveSharpness: Double = 0
    @State private var afFlash = false
    @State private var sheet: MobileSheet?
    @State private var hint: String?

    enum MobileSheet: String, Identifiable {
        case guides, focus, zoom, format, settings, shutter, iris, iso, ev, wb
        var id: String { rawValue }
    }

    public var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            ZStack {
                Color.black.ignoresSafeArea()
                if let shot = session.reviewShot, overlays.shootingMode == .photo {
                    ReviewView(shot: shot)
                } else if portrait {
                    portraitLayout(geo.size)
                } else {
                    landscapeLayout(geo.size)
                }
            }
        }
        .sheet(item: $sheet) { which in sheetView(which) }
        .onChange(of: session.frame, initial: true) { _, f in reprocess(f) }
        .onChange(of: overlays.peaking) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.peakingColor) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.zebra) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.falseColor) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.lutOn) { _, _ in processor.lutCube = overlays.activeLUT; reprocess(session.frame) }
        .onChange(of: overlays.profile) { _, _ in processor.lutCube = overlays.activeLUT; reprocess(session.frame) }
        .onChange(of: overlays.feedColorSpace) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.rotation) { _, _ in reprocess(session.frame) }
        .onChange(of: overlays.shootingMode) { _, _ in reprocess(session.frame) }
        .onChange(of: session.phase.isConnected) { _, live in if !live { sheet = nil } }
        .onAppear {
            processor.lutCube = overlays.activeLUT
            // Dev hook for screenshots: CINEMAHUD_OVERLAYS=sheet:focus opens a sheet on launch.
            if let v = ProcessInfo.processInfo.environment["CINEMAHUD_OVERLAYS"], v.hasPrefix("sheet:"), let s = MobileSheet(rawValue: String(v.dropFirst(6))) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sheet = s }
            }
        }
    }

    // MARK: Layouts

    private func landscapeLayout(_ size: CGSize) -> some View {
        HStack(spacing: 0) {
            leftRail
            VStack(spacing: 0) {
                topBand
                picture
                bottomBand
            }
            rightRail
        }
    }

    private func portraitLayout(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            topBand
            picture.frame(height: size.width * pictureAspectInverse)
            ScrollView {
                VStack(spacing: 14) {
                    ScrollView(.horizontal, showsIndicators: false) { exposureRow.padding(.horizontal, 8).frame(maxWidth: .infinity) }
                    toolRows
                    HStack(spacing: 28) {
                        MobileToolButton(icon: "scope", label: "AF", enabled: session.state.supports("actHalfPressShutter")) { Task { await session.autofocus() } }
                        primaryButton
                        MobileToolButton(icon: "gearshape", label: "SETTINGS") { sheet = .settings }
                    }
                    .padding(.top, 4)
                    if overlays.shootingMode == .photo { MobileFilmstrip().padding(.horizontal, 12) }
                }
                .padding(.vertical, 12)
            }
        }
    }

    /// Height / width of the displayed picture (crop and rotation applied).
    private var pictureAspectInverse: CGFloat {
        let l = imageLayout(in: CGSize(width: 1000, height: 1000))
        return l.rect.height / l.rect.width
    }

    // MARK: Bands and rails

    private var topBand: some View {
        let s = session.state
        return HStack(spacing: 12) {
            ModeSwitch(mode: overlays.shootingMode) { switchMode(to: $0) }
            if let h = hint { Text(h).font(.system(size: 11)).foregroundStyle(Theme.warn).lineLimit(1).minimumScaleFactor(0.7) }
            Spacer(minLength: 4)
            if s.isRecording {
                HStack(spacing: 5) { Circle().fill(Theme.rec).frame(width: 9, height: 9); Text("REC " + duration(s.recordingTimeSeconds)).font(Theme.strip(13)).foregroundStyle(Theme.rec) }
            } else if let t = session.transport {
                Text(t.rawValue.uppercased()).font(Theme.label(10)).foregroundStyle(Theme.dim)
            }
            if let m = s.recordableMinutes { Text(String(format: "%d:%02d h", m / 60, m % 60)).font(Theme.mono(11)).foregroundStyle(Theme.dim) }
            else if let n = s.shotsRemaining { Text("[ \(n) ]").font(Theme.mono(11)).foregroundStyle(Theme.dim) }
            if let b = s.battery { Text("\(Int(b.fraction * 100))%").font(Theme.mono(11)).foregroundStyle(b.fraction < 0.15 ? Theme.rec : Theme.dim) }
            if let e = session.lastError { Text(e).font(.system(size: 10)).foregroundStyle(Theme.warn).lineLimit(1).frame(maxWidth: 160) }
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 40)
        .clipped()
        .background(Theme.field)
    }

    private var bottomBand: some View {
        ScrollView(.horizontal, showsIndicators: false) { exposureRow.padding(.horizontal, 8) }
            .frame(height: MobileMetrics.target + 8)
            .background(Theme.field)
    }

    private var exposureRow: some View {
        let s = session.state
        return HStack(spacing: 2) {
            MobileReadout(label: "SHUTTER", value: s.shutterSpeed ?? "--", enabled: s.supports("setShutterSpeed"),
                          onStep: { d in Task { await session.step(s.shutterSpeedCandidates, current: s.shutterSpeed, by: d) { await session.setShutterSpeed($0) } } },
                          onTap: { sheet = .shutter })
            MobileReadout(label: "IRIS", value: s.fNumber.map { "F" + $0 } ?? "--", enabled: s.supports("setFNumber"),
                          onStep: { d in Task { await session.step(s.fNumberCandidates, current: s.fNumber, by: d) { await session.setFNumber($0) } } },
                          onTap: { sheet = .iris })
            MobileReadout(label: "ISO", value: s.iso ?? "--", enabled: s.supports("setIsoSpeedRate"),
                          onStep: { d in Task { await session.step(s.isoCandidates, current: s.iso, by: d) { await session.setISO($0) } } },
                          onTap: { sheet = .iso })
            MobileReadout(label: "EV", value: s.exposureCompensation?.label ?? "--", enabled: s.supports("setExposureCompensation") && s.exposureCompensation != nil,
                          accent: (s.exposureCompensation?.index ?? 0) == 0 ? Theme.text : Theme.accent,
                          onStep: { d in Task { await session.stepExposureCompensation(d) } },
                          onTap: { sheet = .ev })
            MobileReadout(label: "WB", value: wbValue(s), enabled: s.supports("setWhiteBalance"),
                          onStep: { d in
                              guard s.whiteBalanceMode == "Color Temperature", let k = s.colorTemperature else { return }
                              Task { await session.setWhiteBalance(mode: "Color Temperature", colorTemp: max(2500, min(9900, k + d * 100))) }
                          },
                          onTap: { sheet = .wb })
            MobileReadout(label: "FOCUS", value: s.focusMode ?? "--", enabled: true,
                          accent: s.focusStatus == "Focused" ? Theme.ok : (s.focusStatus == "Failed" ? Theme.rec : Theme.text),
                          onTap: { sheet = .focus })
        }
    }

    private var leftRail: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                MobileToolButton(icon: "grid", label: "GUIDES", active: overlays.grid || overlays.frameGuides || overlays.safeAreas || overlays.diagonals) { sheet = .guides }
                MobileToolButton(icon: "waveform.path.ecg", label: "PEAK", active: overlays.peaking) { overlays.peaking.toggle() }
                MobileToolButton(icon: "line.diagonal", label: "ZEBRA", active: overlays.zebra) { overlays.zebra.toggle() }
                MobileToolButton(icon: "plus.magnifyingglass", label: "2×", active: overlays.magnify) { overlays.magnify.toggle() }
                MobileToolButton(icon: "circle.lefthalf.filled", label: overlays.lutOn ? "709" : "LOG", active: overlays.lutOn && (overlays.profile.isLog || overlays.customLUT != nil),
                                 enabled: overlays.profile.isLog || overlays.customLUT != nil) { overlays.lutOn.toggle() }
                MobileToolButton(icon: "chart.bar.xaxis", label: overlays.scope == .none ? "SCOPE" : overlays.scope.rawValue, active: overlays.scope != .none) { overlays.scope = overlays.scope.next }
                MobileToolButton(icon: "square.and.arrow.down", label: "FORMAT") { sheet = .format }
                Spacer(minLength: 0)
                MobileToolButton(icon: "gearshape", label: "SETUP") { sheet = .settings }
            }
            .padding(.vertical, 8)
        }
        .frame(width: MobileMetrics.railWidth)
        .background(Theme.field)
    }

    private var rightRail: some View {
        let s = session.state
        return ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                MobileToolButton(icon: "scope", label: "AF", enabled: s.supports("actHalfPressShutter")) { Task { await session.autofocus() } }
                MobileToolButton(icon: "lock", label: "AEL") { Task { await session.press(.aeLock) } }
                MobileToolButton(icon: "camera.aperture", label: "FOCUS", active: overlays.peaking) { sheet = .focus }
                MobileToolButton(icon: "arrow.up.left.and.arrow.down.right", label: "ZOOM") { sheet = .zoom }
                if overlays.shootingMode == .video {
                    MobileToolButton(icon: "camera", label: "STILL", enabled: s.supports("actTakePicture")) { Task { await session.takePicture() } }
                }
                Spacer(minLength: 0)
                primaryButton
            }
            .padding(.vertical, 8)
        }
        .frame(width: MobileMetrics.railWidth)
        .background(Theme.field)
    }

    private var toolRows: some View {
        let s = session.state
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                MobileToolButton(icon: "grid", label: "GUIDES", active: overlays.grid || overlays.frameGuides || overlays.safeAreas || overlays.diagonals) { sheet = .guides }
                MobileToolButton(icon: "waveform.path.ecg", label: "PEAK", active: overlays.peaking) { overlays.peaking.toggle() }
                MobileToolButton(icon: "line.diagonal", label: "ZEBRA", active: overlays.zebra) { overlays.zebra.toggle() }
                MobileToolButton(icon: "plus.magnifyingglass", label: "2×", active: overlays.magnify) { overlays.magnify.toggle() }
                MobileToolButton(icon: "chart.bar.xaxis", label: overlays.scope == .none ? "SCOPE" : overlays.scope.rawValue, active: overlays.scope != .none) { overlays.scope = overlays.scope.next }
            }
            HStack(spacing: 8) {
                MobileToolButton(icon: "camera.aperture", label: "FOCUS") { sheet = .focus }
                MobileToolButton(icon: "arrow.up.left.and.arrow.down.right", label: "ZOOM") { sheet = .zoom }
                MobileToolButton(icon: "square.and.arrow.down", label: "FORMAT") { sheet = .format }
                MobileToolButton(icon: "lock", label: "AEL") { Task { await session.press(.aeLock) } }
                if overlays.shootingMode == .video {
                    MobileToolButton(icon: "camera", label: "STILL", enabled: s.supports("actTakePicture")) { Task { await session.takePicture() } }
                } else {
                    MobileToolButton(icon: "circle.lefthalf.filled", label: overlays.lutOn ? "709" : "LOG", enabled: overlays.profile.isLog || overlays.customLUT != nil) { overlays.lutOn.toggle() }
                }
            }
        }
    }

    @ViewBuilder private var primaryButton: some View {
        let s = session.state
        if overlays.shootingMode == .photo {
            ShutterButton(enabled: s.supports("actTakePicture"), busy: session.busy) { Task { await session.takePicture() } }
        } else {
            RecordButton(recording: s.isRecording, enabled: s.supports("startMovieRec") || s.supports("stopMovieRec")) { Task { await session.toggleRecording() } }
        }
    }

    // MARK: Picture

    struct ImageLayout {
        var rect: CGRect
        var fullSize: CGSize
        var cropX: CGFloat, cropY: CGFloat, cropWidth: CGFloat, cropHeight: CGFloat
    }

    private func imageLayout(in size: CGSize) -> ImageLayout {
        let w0 = session.frameSize.width, h0 = session.frameSize.height
        var native: CGFloat = (w0 > 0 && h0 > 0) ? w0 / h0 : 3.0 / 2.0
        if overlays.rotation != 0 { native = 1 / native }
        var aspect = native
        var cropH: CGFloat = 1, cropW: CGFloat = 1
        if overlays.shootingMode == .video, let t = overlays.crop.value {
            let target = CGFloat(t)
            if target > native { aspect = target; cropH = native / target } else if target < native { aspect = target; cropW = target / native }
        }
        let zoom: CGFloat = overlays.magnify ? 2 : 1
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        let rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        let cw = cropW / zoom, ch = cropH / zoom
        return ImageLayout(rect: rect, fullSize: CGSize(width: w / cropW * zoom, height: h / cropH * zoom),
                           cropX: (1 - cw) / 2, cropY: (1 - ch) / 2, cropWidth: cw, cropHeight: ch)
    }

    private var picture: some View {
        GeometryReader { geo in
            let layout = imageLayout(in: geo.size)
            let rect = layout.rect
            let s = session.state
            ZStack {
                Color.black
                if let img = processed {
                    MetalFrameView(image: img, enhanced: overlays.enhanced || overlays.shootingMode == .photo, sharpen: overlays.detail ? 0.35 : 0, colorSpace: overlays.feedColorSpace.cgColorSpace)
                        .frame(width: layout.fullSize.width, height: layout.fullSize.height)
                        .position(x: rect.midX, y: rect.midY)
                        .clipShape(Rectangle().path(in: rect))
                } else {
                    VStack(spacing: 8) { ProgressView(); Text("WAITING FOR LIVE VIEW").font(Theme.label(11)).tracking(3).foregroundStyle(Theme.dim) }
                }
                FrameOverlays(rect: rect)
                if s.isRecording {
                    Rectangle().stroke(Theme.rec, lineWidth: 3).frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                }
                afFrame(in: rect, layout: layout)
                Color.clear.contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    .onTapGesture { loc in
                        var x = layout.cropX + loc.x / rect.width * layout.cropWidth
                        var y = layout.cropY + loc.y / rect.height * layout.cropHeight
                        if overlays.rotation == 90 { (x, y) = (y, 1 - x) } else if overlays.rotation == 270 { (x, y) = (1 - y, x) }
                        afFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { afFlash = false }
                        Task { await session.touchAF(x: x, y: y) }
                    }
                if overlays.showSharpnessMeter || overlays.shootingMode == .photo {
                    HStack(spacing: 8) { FocusDot(status: s.focusStatus); SharpnessBar(ratio: liveSharpness) }
                        .padding(8).background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        .position(x: rect.minX + 70, y: rect.maxY - 22)
                        .allowsHitTesting(false)
                }
                if overlays.shootingMode == .photo, !session.captures.isEmpty, geo.size.width > geo.size.height {
                    MobileFilmstrip().frame(width: min(rect.width - 160, 600)).position(x: rect.midX, y: rect.maxY - 30)
                }
            }
        }
    }

    @ViewBuilder private func afFrame(in rect: CGRect, layout: ImageLayout) -> some View {
        let s = session.state
        let p = session.focusCheckPoint ?? s.touchAFPoint.map { CGPoint(x: $0.x / 100, y: $0.y / 100) }
        if let p, overlays.shootingMode == .photo || s.touchAFSet {
            let fx = (p.x - layout.cropX) / layout.cropWidth, fy = (p.y - layout.cropY) / layout.cropHeight
            let color: Color = s.focusStatus == "Focused" ? Theme.ok : (s.focusStatus == "Failed" ? Theme.rec : .white)
            BracketFrame().stroke(color, lineWidth: 2)
                .frame(width: rect.width * 0.09, height: rect.width * 0.09)
                .position(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
                .scaleEffect(afFlash ? 1.2 : 1).animation(.easeOut(duration: 0.25), value: afFlash)
                .clipShape(Rectangle().path(in: rect))
                .allowsHitTesting(false)
        }
    }

    // MARK: Behaviour

    private func switchMode(to mode: ShootingMode) {
        guard mode != overlays.shootingMode else { return }
        if session.state.supports("setShootMode") {
            Task { await session.setShootMode(mode == .photo ? "still" : "movie") }
        } else {
            overlays.modeResolver.toggle()
            let dial = ShootingModeResolver.mode(forDial: session.state.shootMode)
            if let dial, dial != mode {
                hint = mode == .photo ? "Turn the dial to a stills position" : "Turn the dial to the movie position"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { hint = nil }
            }
        }
    }

    private func reprocess(_ frame: CIImage?) {
        guard let frame else { processed = nil; return }
        let source = frame.matchedToWorkingSpace(from: overlays.feedColorSpace.cgColorSpace) ?? frame
        let video = overlays.shootingMode == .video
        processed = processor.pipeline(source, peaking: overlays.peaking, zebra: video && overlays.zebra, zebraLevel: overlays.zebraLevel,
                                       falseColor: video && overlays.falseColor, rotation: overlays.rotation, peakingColor: overlays.peakingColor.rgb)
        if overlays.showSharpnessMeter || overlays.shootingMode == .photo {
            let point = session.focusCheckPoint ?? session.state.touchAFPoint.map { CGPoint(x: $0.x / 100, y: $0.y / 100) }
            meter.measure(frame, afPoint: point) { r in liveSharpness = r }
        }
    }

    @ViewBuilder private func sheetView(_ which: MobileSheet) -> some View {
        let s = session.state
        switch which {
        case .guides: GuidesSheet()
        case .focus: FocusSheet(liveSharpness: liveSharpness)
        case .zoom: ZoomSheet()
        case .format: FormatSheet()
        case .settings: MobileSettingsView()
        case .shutter: MobileCandidateSheet(title: "Shutter", current: s.shutterSpeed ?? "", candidates: s.shutterSpeedCandidates) { v in Task { await session.setShutterSpeed(v) } }
        case .iris: MobileCandidateSheet(title: "Iris", current: s.fNumber ?? "", candidates: s.fNumberCandidates, format: { "F" + $0 }) { v in Task { await session.setFNumber(v) } }
        case .iso: MobileCandidateSheet(title: "ISO", current: s.iso ?? "", candidates: s.isoCandidates) { v in Task { await session.setISO(v) } }
        case .ev:
            let ev = s.exposureCompensation
            let items = ev.map { e in (e.minIndex ... e.maxIndex).reversed().map { String($0) } } ?? []
            MobileCandidateSheet(title: "Exposure compensation", current: ev.map { String($0.index) } ?? "", candidates: items,
                                 format: { i in
                                     guard let e = ev else { return i }
                                     let v = Double(Int(i) ?? 0) * e.stepEV
                                     return abs(v) < 0.01 ? "0" : String(format: "%@%.1f", v > 0 ? "+" : "", v)
                                 }) { v in
                if let i = Int(v) { Task { await session.setExposureCompensation(index: i) } }
            }
        case .wb:
            let modes = s.whiteBalanceCandidates.isEmpty ? ["Auto WB", "Daylight", "Shade", "Cloudy", "Incandescent", "Flash", "Color Temperature"] : s.whiteBalanceCandidates
            MobileCandidateSheet(title: "White balance", current: s.whiteBalanceMode ?? "", candidates: modes) { v in
                Task { await session.setWhiteBalance(mode: v, colorTemp: v == "Color Temperature" ? (s.colorTemperature ?? 5600) : nil) }
            }
        }
    }

    private func wbValue(_ s: CameraState) -> String {
        if s.whiteBalanceMode == "Color Temperature", let k = s.colorTemperature { return "\(k)K" }
        guard let m = s.whiteBalanceMode else { return "--" }
        return m == "Auto WB" ? "AWB" : String(m.prefix(7)).uppercased()
    }

    private func duration(_ secs: Int) -> String { String(format: "%02d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60) }
}
#endif
