import SwiftUI
import SonyCameraKit

struct TopBar: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    @State private var outputSize: CGSize = .zero
    @State private var outputFX = false

    var body: some View {
        let s = session.state
        HStack(spacing: 14) {
            // REC / STBY + timer
            HStack(spacing: 8) {
                Circle().fill(s.isRecording ? Theme.rec : Color.white.opacity(0.25)).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.5))
                Text(s.isRecording ? "REC" : "STBY").font(Theme.mono(13, weight: .bold)).foregroundStyle(s.isRecording ? Theme.rec : .white)
                Text(timecode(s.recordingTimeSeconds)).font(Theme.mono(15, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 7).hudPanel()

            HStack(spacing: 10) {
                Text(session.cameraName.isEmpty ? "ILCE-6400" : session.cameraName).font(Theme.mono(12, weight: .semibold))
                if let t = session.transport { Text(t.rawValue.uppercased()).font(Theme.mono(10)).foregroundStyle(Theme.amber) }
                Text(modeShort(s.exposureMode)).font(Theme.mono(12, weight: .bold)).foregroundStyle(Theme.amber)
                Text(s.shootMode?.uppercased() ?? "").font(Theme.mono(11)).foregroundStyle(Theme.dim)
                Text(statusText(s.cameraStatus)).font(Theme.mono(11)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 12).padding(.vertical, 7).hudPanel()

            Spacer()

            if let err = session.lastError {
                Text(err).font(Theme.mono(11)).foregroundStyle(Theme.rec).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6).hudPanel()
            }

            HStack(spacing: 10) {
                if overlays.enhanced, outputSize.width > 0 {
                    Text("\(outputFX ? "MFX" : "LANCZOS") \(Int(outputSize.width))×\(Int(outputSize.height))")
                        .font(Theme.mono(11)).foregroundStyle(Theme.amber)
                }
                Text("\(Int(session.frameSize.width))×\(Int(session.frameSize.height))").font(Theme.mono(11)).foregroundStyle(Theme.dim)
                Text(String(format: "%.0f FPS", session.fps)).font(Theme.mono(11)).foregroundStyle(Theme.dim)
                if let n = s.shotsRemaining { Text("\(n) STILLS").font(Theme.mono(11)).foregroundStyle(Theme.dim) }
                if let m = s.recordableMinutes { Text("\(m) MIN").font(Theme.mono(11)).foregroundStyle(Theme.dim) }
                BatteryGlyph(fraction: s.battery?.fraction ?? 0, known: s.battery != nil)
            }
            .padding(.horizontal, 12).padding(.vertical, 7).hudPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: FrameRenderer.outputSizeChanged)) { n in
            if let s = n.userInfo?["size"] as? CGSize { outputSize = s }
            outputFX = n.userInfo?["fx"] as? Bool ?? false
        }
    }

    private func timecode(_ secs: Int) -> String {
        String(format: "%02d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60)
    }
    private func modeShort(_ mode: String?) -> String {
        switch mode {
        case "Manual": return "M"
        case "Aperture": return "A"
        case "Shutter": return "S"
        case "Program Auto": return "P"
        case "Intelligent Auto": return "iA"
        case "Superior Auto": return "iA+"
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
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(0.6), lineWidth: 1).frame(width: 24, height: 11)
                RoundedRectangle(cornerRadius: 1).fill(fraction < 0.2 ? Theme.rec : (fraction < 0.4 ? Theme.amber : Theme.focusOK))
                    .frame(width: max(2, 20 * fraction), height: 7).padding(.leading, 2)
            }
            RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.6)).frame(width: 2, height: 5)
            Text(known ? "\(Int(fraction * 100))%" : "--").font(Theme.mono(11)).foregroundStyle(Theme.dim).padding(.leading, 4)
        }
    }
}

struct BottomBar: View {
    @Environment(CameraSession.self) private var session

    var body: some View {
        let s = session.state
        HStack(spacing: 4) {
            HUDReadout(label: "SHUTTER", value: s.shutterSpeed ?? "--", candidates: s.shutterSpeedCandidates,
                       enabled: s.supports("setShutterSpeed"),
                       onSelect: { v in Task { await session.setShutterSpeed(v) } },
                       onStep: { d in Task { await session.step(s.shutterSpeedCandidates, current: s.shutterSpeed, by: d) { await session.setShutterSpeed($0) } } })
            divider
            HUDReadout(label: "IRIS", value: s.fNumber.map { "F" + $0 } ?? "--", candidates: s.fNumberCandidates,
                       enabled: s.supports("setFNumber"), format: { "F" + $0 },
                       onSelect: { v in Task { await session.setFNumber(v) } },
                       onStep: { d in Task { await session.step(s.fNumberCandidates, current: s.fNumber, by: d) { await session.setFNumber($0) } } })
            divider
            HUDReadout(label: "ISO", value: s.iso ?? "--", candidates: s.isoCandidates,
                       enabled: s.supports("setIsoSpeedRate"),
                       onSelect: { v in Task { await session.setISO(v) } },
                       onStep: { d in Task { await session.step(s.isoCandidates, current: s.iso, by: d) { await session.setISO($0) } } })
            divider
            HUDReadout(label: "EV", value: s.exposureCompensation?.label ?? "--",
                       candidates: evCandidates(s.exposureCompensation),
                       enabled: s.supports("setExposureCompensation") && s.exposureCompensation != nil,
                       accent: (s.exposureCompensation?.index ?? 0) == 0 ? .white : Theme.amber,
                       onSelect: { v in if let i = Int(v.split(separator: "|").last ?? "") { Task { await session.setExposureCompensation(index: i) } } },
                       onStep: { d in Task { await session.stepExposureCompensation(d) } })
            divider
            HUDReadout(label: "WB", value: wbLabel(s), candidates: wbCandidates(s),
                       enabled: s.supports("setWhiteBalance"), format: wbFormat,
                       onSelect: { v in
                           if let k = Int(v) { Task { await session.setWhiteBalance(mode: "Color Temperature", colorTemp: k) } }
                           else { Task { await session.setWhiteBalance(mode: v, colorTemp: nil) } }
                       },
                       onStep: { d in
                           guard s.whiteBalanceMode == "Color Temperature", let k = s.colorTemperature else { return }
                           Task { await session.setWhiteBalance(mode: "Color Temperature", colorTemp: max(2500, min(9900, k + d * 100))) }
                       })
            divider
            HUDReadout(label: "FOCUS", value: s.focusMode ?? "--", candidates: s.focusModeCandidates,
                       enabled: s.supports("setFocusMode"),
                       accent: s.focusStatus == "Focused" ? Theme.focusOK : (s.focusStatus == "Failed" ? Theme.rec : .white),
                       onSelect: { v in Task { await session.setFocusMode(v) } },
                       onStep: { d in Task { await session.step(s.focusModeCandidates, current: s.focusMode, by: d) { await session.setFocusMode($0) } } })
            if !s.exposureModeCandidates.isEmpty {
                divider
                HUDReadout(label: "MODE", value: s.exposureMode ?? "--", candidates: s.exposureModeCandidates,
                           enabled: s.supports("setExposureMode"),
                           onSelect: { v in Task { await session.setExposureMode(v) } })
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .hudPanel(10)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 36) }

    /// Encodes EV candidates as "label|index" so the picker can show the label and send the index.
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
        var list = ["Auto WB", "Daylight", "Shade", "Cloudy", "Incandescent",
                    "Fluorescent: Warm White (-1)", "Fluorescent: Cool White (0)", "Fluorescent: Day White (+1)", "Fluorescent: Daylight (+2)",
                    "Flash", "Custom 1"]
        list += stride(from: 2500, through: 9900, by: 100).map(String.init)
        return list
    }
}

/// Vertical action strip on the right edge.
struct SideTools: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays

    var body: some View {
        @Bindable var ov = overlays
        let s = session.state
        VStack(spacing: 6) {
            tool("AF", "scope", enabled: s.supports("actHalfPressShutter")) { Task { await session.autofocus() } }
            tool("SHOT", "camera.aperture", enabled: s.supports("actTakePicture")) { Task { await session.takePicture() } }
            Button { Task { await session.toggleRecording() } } label: {
                VStack(spacing: 3) {
                    Circle().fill(Theme.rec).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: s.isRecording ? 2 : 0))
                    Text(s.isRecording ? "STOP" : "REC").font(Theme.label(9)).tracking(1)
                }
                .frame(width: 52, height: 46).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .disabled(!(s.supports("startMovieRec") || s.supports("stopMovieRec")))
            .opacity((s.supports("startMovieRec") || s.supports("stopMovieRec")) ? 1 : 0.4)
            Rectangle().fill(.white.opacity(0.12)).frame(width: 40, height: 1).padding(.vertical, 2)
            toggle("GRID", "grid", $ov.grid)
            toggle("GUIDE", "rectangle.ratio.16.to.9", $ov.frameGuides)
            toggle("PEAK", "waveform.path", $ov.peaking)
            toggle("ZEBRA", "line.diagonal", $ov.zebra)
            toggle("ENHANCE", "sparkles", $ov.enhanced)
            Button { ov.crop = ov.crop.next } label: {
                VStack(spacing: 3) {
                    Image(systemName: "crop").font(.system(size: 15, weight: .medium))
                    Text(ov.crop.label).font(Theme.label(9)).tracking(1)
                }
                .frame(width: 52, height: 46).contentShape(Rectangle())
                .background(ov.crop != .native ? Theme.amber.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain).foregroundStyle(ov.crop != .native ? Theme.amber : .white)
            .help("Crop to a cinema aspect ratio (keys 1–6)")
        }
        .padding(6)
        .hudPanel(10)
    }

    private func tool(_ title: String, _ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                Text(title).font(Theme.label(9)).tracking(1)
            }
            .frame(width: 52, height: 46).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.white).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }

    private func toggle(_ title: String, _ icon: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                Text(title).font(Theme.label(9)).tracking(1)
            }
            .frame(width: 52, height: 46).contentShape(Rectangle())
            .background(on.wrappedValue ? Theme.amber.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).foregroundStyle(on.wrappedValue ? Theme.amber : .white)
    }
}
