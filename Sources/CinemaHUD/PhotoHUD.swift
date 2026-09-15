import SwiftUI
import SonyCameraKit
import ImageIO

/// Stills display in the idiom of the camera body's own LCD: white type on the picture, translucent
/// bands top and bottom, focus dot bottom-left, exposure across the bottom, shutter button bottom-right.
struct PhotoHUD: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    let layout: PhotoView.ImageLayout
    let liveSharpness: Double
    let afFlash: Bool
    @State private var blink = false
    @State private var thumbs = ThumbnailCache()

    private var rect: CGRect { layout.rect }

    var body: some View {
        let s = session.state
        ZStack {
            topBand(s)
            leftColumn(s)
            rightColumn(s)
            afFrame(s)
            bottomBand(s)
            focusIndicator(s)
            shutterButton(s)
            filmstrip
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in blink.toggle() }
    }

    // MARK: Bands

    private func topBand(_ s: CameraState) -> some View {
        HStack(spacing: 14) {
            modeBadge(s.exposureMode)
            if let n = s.shotsRemaining { sonyText("[ \(n) ]", 15) }
            fileFormatBadge
            if session.captures.last?.transferring == true {
                // A RAW pull shares the USB link with live view, so the picture pauses for a second or two.
                sonyText(session.captures.last?.raw == nil && session.transport == .usb ? "TRANSFERRING RAW…" : "TRANSFERRING…", 11)
                    .foregroundStyle(Theme.warn).opacity(blink ? 1 : 0.6)
            }
            Spacer()
            if let t = session.transport { sonyText(t.rawValue.uppercased(), 11).opacity(0.8) }
            battery(s.battery)
        }
        .padding(.horizontal, 12).frame(height: 30)
        .background(Color.black.opacity(0.38))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func bottomBand(_ s: CameraState) -> some View {
        HStack(spacing: 26) {
            SonyReadout(value: s.shutterSpeed ?? "--", candidates: s.shutterSpeedCandidates, enabled: s.supports("setShutterSpeed"),
                        onSelect: { v in Task { await session.setShutterSpeed(v) } },
                        onStep: { d in Task { await session.step(s.shutterSpeedCandidates, current: s.shutterSpeed, by: d) { await session.setShutterSpeed($0) } } })
            SonyReadout(value: s.fNumber.map { "F" + $0 } ?? "F--", candidates: s.fNumberCandidates, enabled: s.supports("setFNumber"),
                        format: { "F" + $0 },
                        onSelect: { v in Task { await session.setFNumber(v) } },
                        onStep: { d in Task { await session.step(s.fNumberCandidates, current: s.fNumber, by: d) { await session.setFNumber($0) } } })
            evMeter(s.exposureCompensation)
            SonyReadout(value: s.iso.map { "ISO " + $0 } ?? "ISO --", candidates: s.isoCandidates, enabled: s.supports("setIsoSpeedRate"),
                        format: { "ISO " + $0 },
                        onSelect: { v in Task { await session.setISO(v) } },
                        onStep: { d in Task { await session.step(s.isoCandidates, current: s.iso, by: d) { await session.setISO($0) } } })
            Spacer()
        }
        .padding(.leading, 150).padding(.trailing, 12).frame(height: 40)
        .background(Color.black.opacity(0.38))
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func leftColumn(_ s: CameraState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            boxed(s.focusMode ?? "AF")
            boxed(session.focusCheckPoint != nil || s.touchAFSet ? "SPOT" : "WIDE")
            boxed("S")   // single drive; the old protocol does not report drive mode
            Spacer()
        }
        .padding(.leading, 12).padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rightColumn(_ s: CameraState) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            boxed(wbLabel(s))
            boxed(overlays.profile.isLog ? overlays.profile.short : "DRO AUTO")
            Spacer()
        }
        .padding(.trailing, 12).padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    // MARK: Focus

    /// Sony's focus indicator: steady green dot = focused, blinking = failed, hollow = hunting. Plus the live
    /// sharpness bar for the AF region so focus can be seen settling before the shot.
    private func focusIndicator(_ s: CameraState) -> some View {
        HStack(spacing: 8) {
            Group {
                switch s.focusStatus {
                case "Focused": Circle().fill(Theme.ok)
                case "Failed": Circle().fill(Theme.rec).opacity(blink ? 1 : 0.15)
                case "Focusing": Circle().stroke(Color.white, lineWidth: 1.5)
                default: Circle().fill(.clear)
                }
            }
            .frame(width: 11, height: 11)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(width: 60, height: 5)
                Capsule().fill(liveSharpness >= FocusAnalyzer.inFocusRatio ? Theme.ok : (liveSharpness >= FocusAnalyzer.softRatio ? Theme.warn : Color.white))
                    .frame(width: 60 * max(0.02, min(1, liveSharpness)), height: 5)
            }
            sonyText(String(format: "%.0f", liveSharpness * 100), 10).opacity(0.75)
        }
        .padding(.leading, 12).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    private func afFrame(_ s: CameraState) -> some View {
        let p = session.focusCheckPoint ?? s.touchAFPoint.map { CGPoint(x: $0.x / 100, y: $0.y / 100) } ?? CGPoint(x: 0.5, y: 0.5)
        let fx = (p.x - layout.cropX) / layout.cropWidth, fy = (p.y - layout.cropY) / layout.cropHeight
        let size = rect.width * 0.09
        let color: Color = s.focusStatus == "Focused" ? Theme.ok : (s.focusStatus == "Failed" ? Theme.rec : .white)
        return BracketFrame().stroke(color, lineWidth: 2)
            .frame(width: size, height: size)
            .position(x: rect.width * fx, y: rect.height * fy)
            .scaleEffect(afFlash ? 1.2 : 1).animation(.easeOut(duration: 0.25), value: afFlash)
            .allowsHitTesting(false)
    }

    // MARK: Shutter, filmstrip

    private func shutterButton(_ s: CameraState) -> some View {
        Button { Task { await session.takePicture() } } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 3).frame(width: 52, height: 52)
                Circle().fill(Color.white.opacity(session.busy ? 0.4 : 0.9)).frame(width: 40, height: 40)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .disabled(!s.supports("actTakePicture"))
        .padding(.trailing, 16).padding(.bottom, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var filmstrip: some View {
        HStack(spacing: 6) {
            ForEach(session.captures.suffix(8)) { shot in
                Button { session.review(shot) } label: {
                    ZStack(alignment: .bottomTrailing) {
                        if let url = shot.primary?.url, let t = thumbs.image(for: url) {
                            Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Color.white.opacity(0.15))
                        }
                        if shot.transferring { ProgressView().controlSize(.mini).padding(3) }
                        else if shot.error != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).padding(3) }
                        else if shot.hasBoth { sonyText("RAW+J", 8).padding(3) }
                    }
                    .frame(width: 64, height: 43).clipped()
                    .overlay(Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }
        }
        .padding(.leading, 12).padding(.bottom, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    // MARK: Pieces

    private var fileFormatBadge: some View {
        let last = session.captures.last
        let text = last.map { $0.hasBoth ? "RAW+J" : ($0.raw != nil ? "RAW" : "JPEG") } ?? "--"
        return sonyText(text, 12).padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white, lineWidth: 1))
    }

    private func modeBadge(_ mode: String?) -> some View {
        let short: String = {
            switch mode {
            case "Manual": return "M"; case "Aperture": return "A"; case "Shutter": return "S"; case "Program Auto": return "P"
            case "Intelligent Auto", "Superior Auto": return "AUTO"
            default: return mode.map { String($0.prefix(4)).uppercased() } ?? "--"
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: "camera.fill").font(.system(size: 11))
            Text(short).font(.system(size: 16, weight: .heavy))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5))
    }

    private func battery(_ b: BatteryInfo?) -> some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).stroke(Color.white, lineWidth: 1.5).frame(width: 24, height: 11)
                RoundedRectangle(cornerRadius: 1).fill((b?.fraction ?? 1) < 0.15 ? Theme.rec : Color.white)
                    .frame(width: max(2, 20 * CGFloat(b?.fraction ?? 0)), height: 7).padding(.leading, 2)
            }
            sonyText(b.map { "\(Int($0.fraction * 100))%" } ?? "--%", 13)
        }
    }

    private func evMeter(_ ev: ExposureCompensation?) -> some View {
        let stops = ev.map { Double($0.index) * $0.stepEV } ?? 0
        return HStack(spacing: 6) {
            sonyText(ev?.label ?? "±0.0", 15).monospacedDigit()
            ZStack(alignment: .leading) {
                HStack(spacing: 8) {
                    ForEach(-3 ... 3, id: \.self) { i in
                        Rectangle().fill(Color.white.opacity(i == 0 ? 1 : 0.5)).frame(width: 1, height: i == 0 ? 10 : 6)
                    }
                }
                Triangle().fill(Color.white).frame(width: 7, height: 6)
                    .offset(x: CGFloat(max(-3, min(3, stops))) * 9 + 27 - 3.5, y: -10)
            }
        }
        .frame(height: 30)
    }

    private func wbLabel(_ s: CameraState) -> String {
        if s.whiteBalanceMode == "Color Temperature", let k = s.colorTemperature { return "\(k)K" }
        switch s.whiteBalanceMode {
        case "Auto WB": return "AWB"; case "Daylight": return "DAYLIGHT"; case "Cloudy": return "CLOUDY"; case "Shade": return "SHADE"
        default: return s.whiteBalanceMode.map { String($0.prefix(6)).uppercased() } ?? "WB"
        }
    }

    private func boxed(_ text: String) -> some View {
        sonyText(text, 12).padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.9), lineWidth: 1))
    }

    private func sonyText(_ text: String, _ size: CGFloat) -> some View {
        Text(text).font(.system(size: size, weight: .bold)).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 0)
    }
}

/// Exposure readout in the body's own style: bold white value, click for the list, scroll to step.
struct SonyReadout: View {
    let value: String
    var candidates: [String] = []
    var enabled = true
    var format: (String) -> String = { $0 }
    var onSelect: (String) -> Void = { _ in }
    var onStep: (Int) -> Void = { _ in }
    @State private var showPicker = false
    @State private var hover = false

    var body: some View {
        ScrollStepper(onStep: { if enabled { onStep($0) } }) {
            Button { if enabled && !candidates.isEmpty { showPicker.toggle() } } label: {
                Text(value).font(.system(size: 19, weight: .bold)).monospacedDigit()
                    .foregroundStyle(enabled ? (hover ? Theme.warn : .white) : Color.white.opacity(0.4))
                    .shadow(color: .black.opacity(0.8), radius: 1)
                    .padding(.horizontal, 4).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .onHover { hover = $0 }
            .popover(isPresented: $showPicker, arrowEdge: .top) {
                CandidatePicker(title: "", current: value, candidates: candidates, format: format) { v in showPicker = false; onSelect(v) }
            }
        }
    }
}

/// Four bracket corners, Sony's AF frame.
struct BracketFrame: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = r.width * 0.28
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x, y: y + dy * l)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + dx * l, y: y))
        }
        return p
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.closeSubpath()
        return p
    }
}

/// Small thumbnails for the filmstrip, decoded once per file off the main thread.
@Observable @MainActor
final class ThumbnailCache {
    private var images: [URL: CGImage] = [:]
    private var pending: Set<URL> = []

    func image(for url: URL) -> CGImage? {
        if let i = images[url] { return i }
        guard !pending.contains(url) else { return nil }
        pending.insert(url)
        Task.detached(priority: .utility) {
            let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160,
                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
            let img = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, opts) }
            await MainActor.run { self.pending.remove(url); if let img { self.images[url] = img } }
        }
        return nil
    }
}
