import SwiftUI
import SonyCameraKit

// MARK: - Top status strip

struct TopBar: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    @State private var outputSize: CGSize = .zero
    @State private var outputFX = false

    var body: some View {
        let s = session.state
        let rec = s.isRecording
        HStack(spacing: 0) {
            // Recording state + duration
            HStack(spacing: 10) {
                Circle().fill(rec ? Theme.rec : Theme.faint).frame(width: 9, height: 9)
                Text(rec ? "REC" : "STBY").font(Theme.mono(12, weight: .bold)).foregroundStyle(rec ? Theme.rec : Theme.text)
                Text(duration(s.recordingTimeSeconds)).font(Theme.mono(15, weight: .semibold)).foregroundStyle(rec ? Theme.rec : Theme.text)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(rec ? Theme.rec.opacity(0.14) : .clear)
            divider
            // Free-running timecode
            TimelineView(.periodic(from: .now, by: 1.0 / Double(overlays.projectFPS))) { ctx in
                HStack(spacing: 8) {
                    Text("TC").font(Theme.label()).tracking(1.6).foregroundStyle(Theme.dim)
                    Text(timecode(ctx.date, fps: overlays.projectFPS)).font(Theme.mono(15, weight: .semibold)).foregroundStyle(Theme.text)
                }
            }
            .padding(.horizontal, 12)
            divider
            HStack(spacing: 8) {
                Text("TAKE").font(Theme.label()).tracking(1.6).foregroundStyle(Theme.dim)
                Text(String(format: "%03d", session.takes)).font(Theme.mono(15, weight: .semibold)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 12)
            divider
            HStack(spacing: 8) {
                Text(session.cameraName.isEmpty ? "ILCE-6400" : session.cameraName).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                Text(modeShort(s.exposureMode)).font(Theme.mono(12, weight: .bold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Color.white.opacity(0.12))
                Text(statusText(s.cameraStatus)).font(Theme.mono(11)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 8)

            if let err = session.lastError {
                Text(err).font(Theme.mono(11)).foregroundStyle(Theme.warn).lineLimit(1).padding(.horizontal, 12)
                divider
            }
            HStack(spacing: 12) {
                if overlays.enhanced, outputSize.width > 0 {
                    Text("\(outputFX ? "MFX" : "LANCZOS") \(Int(outputSize.width))×\(Int(outputSize.height))")
                        .font(Theme.mono(11)).foregroundStyle(Theme.warn)
                }
                if session.smoothMotion {
                    Text("MOTION ×2 · +\(Int(1000.0 / max(1, session.sourceFPS)))ms").font(Theme.mono(11)).foregroundStyle(Theme.warn)
                }
                Text("\(Int(session.frameSize.width))×\(Int(session.frameSize.height))").font(Theme.mono(11)).foregroundStyle(Theme.dim)
                Text(String(format: "%.0f FPS", session.fps)).font(Theme.mono(11)).foregroundStyle(Theme.dim)
                if let t = session.transport { Text(t.rawValue.uppercased()).font(Theme.mono(11)).foregroundStyle(Theme.dim) }
            }
            .padding(.horizontal, 12)
            divider
            HStack(spacing: 12) {
                if let m = s.recordableMinutes { media("\(m) MIN") } else if let n = s.shotsRemaining { media("\(n) STILLS") }
                BatteryGlyph(fraction: s.battery?.fraction ?? 0, known: s.battery != nil)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 34)
        .hudPanel()
        .onReceive(NotificationCenter.default.publisher(for: FrameRenderer.outputSizeChanged)) { n in
            if let sz = n.userInfo?["size"] as? CGSize { outputSize = sz }
            outputFX = n.userInfo?["fx"] as? Bool ?? false
        }
    }

    private var divider: some View { Rectangle().fill(Theme.panelLine).frame(width: 1, height: 34) }

    private func media(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text("MEDIA").font(Theme.label()).tracking(1.6).foregroundStyle(Theme.dim)
            Text(text).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
        }
    }

    private func duration(_ secs: Int) -> String {
        String(format: "%02d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60)
    }
    private func timecode(_ date: Date, fps: Int) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let frames = Int(Double(c.nanosecond ?? 0) / 1e9 * Double(fps))
        return String(format: "%02d:%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, frames)
    }
    private func modeShort(_ mode: String?) -> String {
        switch mode {
        case "Manual", "Movie M": return "M"
        case "Aperture", "Movie A": return "A"
        case "Shutter", "Movie S": return "S"
        case "Program Auto", "Movie P": return "P"
        case "Intelligent Auto", "Movie Auto": return "AUTO"
        case "Superior Auto": return "AUTO+"
        case nil: return "--"
        default: return mode!.uppercased()
        }
    }
    private func statusText(_ st: String) -> String {
        switch st {
        case "IDLE": return "READY"
        case "MovieRecording": return "RECORDING"
        case "StillCapturing": return "CAPTURING"
        case "MovieWaitRecStart", "MovieWaitRecStop": return "WAIT"
        case "NotReady": return "NOT READY"
        default: return st.uppercased()
        }
    }
}

struct BatteryGlyph: View {
    let fraction: Double
    let known: Bool
    var body: some View {
        let color: Color = fraction < 0.15 ? Theme.rec : (fraction < 0.35 ? Theme.warn : Theme.ok)
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    Rectangle().stroke(Theme.dim, lineWidth: 1).frame(width: 22, height: 10)
                    Rectangle().fill(color).frame(width: max(1, 18 * fraction), height: 6).padding(.leading, 2)
                }
                Rectangle().fill(Theme.dim).frame(width: 2, height: 4)
            }
            Text(known ? "\(Int(fraction * 100))%" : "--").font(Theme.mono(12, weight: .semibold)).foregroundStyle(known ? Theme.text : Theme.dim)
        }
    }
}

// MARK: - Bottom readout band

struct BottomBar: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays

    var body: some View {
        @Bindable var ov = overlays
        let s = session.state
        let fpsChoices = ["24", "25", "30", "48", "50", "60"]
        HStack(spacing: 0) {
            HUDReadout(label: "FPS", value: "\(overlays.projectFPS)", sub: "project", candidates: fpsChoices, width: 78,
                       onSelect: { v in if let f = Int(v) { ov.projectFPS = f } },
                       onStep: { d in if let i = fpsChoices.firstIndex(of: "\(ov.projectFPS)") { let n = max(0, min(fpsChoices.count - 1, i + d)); ov.projectFPS = Int(fpsChoices[n])! } })
            divider
            HUDReadout(label: "SHUTTER", value: shutterAngle(s.shutterSpeed, fps: overlays.projectFPS), sub: s.shutterSpeed ?? "",
                       candidates: s.shutterSpeedCandidates, enabled: s.supports("setShutterSpeed"), width: 118,
                       format: { "\(shutterAngle($0, fps: overlays.projectFPS))   \($0)" },
                       onSelect: { v in Task { await session.setShutterSpeed(v) } },
                       onStep: { d in Task { await session.step(s.shutterSpeedCandidates, current: s.shutterSpeed, by: d) { await session.setShutterSpeed($0) } } })
            divider
            HUDReadout(label: "EI", value: s.iso ?? "--", sub: "ISO", candidates: s.isoCandidates,
                       enabled: s.supports("setIsoSpeedRate"), width: 96,
                       onSelect: { v in Task { await session.setISO(v) } },
                       onStep: { d in Task { await session.step(s.isoCandidates, current: s.iso, by: d) { await session.setISO($0) } } })
            divider
            HUDReadout(label: "IRIS", value: s.fNumber.map { "F" + $0 } ?? "--", sub: " ", candidates: s.fNumberCandidates,
                       enabled: s.supports("setFNumber"), width: 96, format: { "F" + $0 },
                       onSelect: { v in Task { await session.setFNumber(v) } },
                       onStep: { d in Task { await session.step(s.fNumberCandidates, current: s.fNumber, by: d) { await session.setFNumber($0) } } })
            divider
            HUDReadout(label: "WB", value: wbLabel(s), sub: wbSub(s), candidates: wbCandidates(s),
                       enabled: s.supports("setWhiteBalance"), width: 104, format: wbFormat,
                       onSelect: { v in
                           if let k = Int(v) { Task { await session.setWhiteBalance(mode: "Color Temperature", colorTemp: k) } }
                           else { Task { await session.setWhiteBalance(mode: v, colorTemp: nil) } }
                       },
                       onStep: { d in
                           guard s.whiteBalanceMode == "Color Temperature", let k = s.colorTemperature else { return }
                           Task { await session.setWhiteBalance(mode: "Color Temperature", colorTemp: max(2500, min(9900, k + d * 100))) }
                       })
            divider
            HUDReadout(label: "EV", value: s.exposureCompensation?.label ?? "--", sub: " ",
                       candidates: evCandidates(s.exposureCompensation),
                       enabled: s.supports("setExposureCompensation") && s.exposureCompensation != nil, width: 78,
                       format: { String($0.split(separator: "|").first ?? "") },
                       onSelect: { v in if let i = Int(v.split(separator: "|").last ?? "") { Task { await session.setExposureCompensation(index: i) } } },
                       onStep: { d in Task { await session.stepExposureCompensation(d) } })
            divider
            HUDReadout(label: "FOCUS", value: s.focusMode ?? "--", sub: focusSub(s), candidates: s.focusModeCandidates,
                       enabled: s.supports("setFocusMode"),
                       accent: s.focusStatus == "Focused" ? Theme.ok : (s.focusStatus == "Failed" ? Theme.rec : Theme.text), width: 92,
                       onSelect: { v in Task { await session.setFocusMode(v) } },
                       onStep: { d in Task { await session.step(s.focusModeCandidates, current: s.focusMode, by: d) { await session.setFocusMode($0) } } })
        }
        .hudPanel()
    }

    private var divider: some View { Rectangle().fill(Theme.panelLine).frame(width: 1, height: 44) }

    /// Cinema shutter angle for a speed at the project frame rate (180° = 1/(2·fps)).
    private func shutterAngle(_ speed: String?, fps: Int) -> String {
        guard let speed, let secs = exposureSeconds(speed) else { return "--" }
        let angle = 360.0 * Double(fps) * secs
        if angle > 360 { return "360°+" }
        return String(format: angle.rounded() == angle ? "%.0f°" : "%.1f°", angle)
    }
    private func exposureSeconds(_ s: String) -> Double? {
        if s.uppercased() == "BULB" || s == "--" { return nil }
        if s.hasSuffix("\"") { return Double(s.dropLast()) }
        let p = s.split(separator: "/")
        if p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b > 0 { return a / b }
        return Double(s)
    }
    private func focusSub(_ s: CameraState) -> String {
        switch s.focusStatus {
        case "Focused": return "locked"
        case "Focusing": return "searching"
        case "Failed": return "no lock"
        default: return " "
        }
    }
    private func evCandidates(_ ev: ExposureCompensation?) -> [String] {
        guard let ev else { return [] }
        return (ev.minIndex ... ev.maxIndex).reversed().map { i in
            let v = Double(i) * ev.stepEV
            let label = abs(v) < 0.01 ? "0" : String(format: "%@%.1f", v > 0 ? "+" : "", v)
            return "\(label)|\(i)"
        }
    }
    private func wbLabel(_ s: CameraState) -> String {
        guard let m = s.whiteBalanceMode else { return "--" }
        if m == "Color Temperature", let k = s.colorTemperature { return "\(k)K" }
        return wbFormat(m)
    }
    private func wbSub(_ s: CameraState) -> String {
        guard let m = s.whiteBalanceMode, m != "Color Temperature" else { return "kelvin" }
        return m == "Auto WB" ? "auto" : "preset"
    }
    private func wbFormat(_ v: String) -> String {
        if Int(v) != nil { return v + "K" }
        switch v {
        case "Auto WB": return "AWB"
        case "Daylight": return "DAY"
        case "Shade": return "SHADE"
        case "Cloudy": return "CLOUD"
        case "Incandescent": return "TUNG"
        case "Fluorescent: Warm White (-1)": return "FL -1"
        case "Fluorescent: Cool White (0)": return "FL 0"
        case "Fluorescent: Day White (+1)": return "FL +1"
        case "Fluorescent: Daylight (+2)": return "FL +2"
        case "Flash": return "FLASH"
        case "Color Temperature": return "KELVIN"
        case "Custom", "Custom 1", "Custom 2", "Custom 3": return v.uppercased()
        default: return v
        }
    }
    private func wbCandidates(_ s: CameraState) -> [String] {
        var list = s.whiteBalanceCandidates.isEmpty
            ? ["Auto WB", "Daylight", "Shade", "Cloudy", "Incandescent", "Fluorescent: Warm White (-1)", "Fluorescent: Cool White (0)",
               "Fluorescent: Day White (+1)", "Fluorescent: Daylight (+2)", "Flash", "Custom 1"]
            : s.whiteBalanceCandidates.filter { $0 != "Color Temperature" }
        list += stride(from: 2500, through: 9900, by: 100).map(String.init)
        return list
    }
}

// MARK: - Right-hand tool column

struct SideTools: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays

    var body: some View {
        @Bindable var ov = overlays
        let s = session.state
        VStack(spacing: 2) {
            tool("AF", "scope", enabled: s.supports("actHalfPressShutter")) { Task { await session.autofocus() } }
            tool("STILL", "camera.aperture", enabled: s.supports("actTakePicture")) { Task { await session.takePicture() } }
            Button { Task { await session.toggleRecording() } } label: {
                VStack(spacing: 4) {
                    Circle().fill(Theme.rec).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: s.isRecording ? 2 : 0))
                    Text(s.isRecording ? "STOP" : "REC").font(Theme.label(9)).tracking(1.2)
                }
                .frame(width: 54, height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.text)
            .disabled(!(s.supports("startMovieRec") || s.supports("stopMovieRec")))
            .opacity((s.supports("startMovieRec") || s.supports("stopMovieRec")) ? 1 : 0.35)
            Rectangle().fill(Theme.panelLine).frame(width: 40, height: 1).padding(.vertical, 3)
            toggle("FRAME", "viewfinder", $ov.grid)
            toggle("GUIDE", "rectangle.ratio.16.to.9", $ov.frameGuides)
            toggle("PEAK", "waveform.path", $ov.peaking)
            toggle("ZEBRA", "line.diagonal", $ov.zebra)
            toggle("FALSE", "paintpalette", $ov.falseColor)
            toggle("SCOPE", "chart.bar.xaxis", $ov.waveform)
            Rectangle().fill(Theme.panelLine).frame(width: 40, height: 1).padding(.vertical, 3)
            toggle("ENHANCE", "sparkles", $ov.enhanced)
            toggle("MOTION", "film.stack", Binding(get: { session.smoothMotion }, set: { session.smoothMotion = $0 }))
            Button { ov.crop = ov.crop.next } label: {
                VStack(spacing: 4) {
                    Image(systemName: "crop").font(.system(size: 14, weight: .medium))
                    Text(ov.crop.label).font(Theme.label(9)).tracking(1.2)
                }
                .frame(width: 54, height: 48).contentShape(Rectangle())
                .background(ov.crop != .native ? Color.white.opacity(0.12) : .clear)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.text)
            .help("Crop to a cinema aspect ratio (keys 1–6)")
        }
        .padding(4)
        .hudPanel()
    }

    private func tool(_ title: String, _ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                Text(title).font(Theme.label(9)).tracking(1.2)
            }
            .frame(width: 54, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Theme.text).disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }

    private func toggle(_ title: String, _ icon: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                Text(title).font(Theme.label(9)).tracking(1.2)
            }
            .frame(width: 54, height: 48).contentShape(Rectangle())
            .background(on.wrappedValue ? Theme.selection : .clear)
        }
        .buttonStyle(.plain).foregroundStyle(on.wrappedValue ? Color.black : Theme.text)
    }
}
