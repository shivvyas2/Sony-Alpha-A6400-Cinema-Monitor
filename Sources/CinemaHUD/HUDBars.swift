import SwiftUI
import SonyCameraKit

// MARK: - Shared pieces

/// Small tracked label with a large condensed value, the viewfinder vernacular. Click for a picker,
/// scroll over it to step. Dimmed when the camera does not allow the change.
struct StripReadout: View {
    let label: String
    let value: String
    var suffix: String = ""
    var candidates: [String] = []
    var enabled: Bool = true
    var accent: Color = Theme.text
    /// Raw current value for the picker highlight when `value` is a derived display (e.g. shutter angle).
    var currentRaw: String? = nil
    var format: (String) -> String = { $0 }
    var onSelect: (String) -> Void = { _ in }
    var onStep: (Int) -> Void = { _ in }
    @State private var showPicker = false
    @State private var hover = false

    var body: some View {
        ScrollStepper(onStep: { if enabled { onStep($0) } }) {
            Button {
                if enabled && !candidates.isEmpty { showPicker.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(label).font(Theme.label(9)).tracking(1.2).foregroundStyle(hover && enabled ? Theme.accent : Theme.dim)
                    Text(value).font(Theme.strip()).foregroundStyle(enabled ? accent : Theme.faint)
                    if !suffix.isEmpty { Text(suffix).font(Theme.strip(12)).foregroundStyle(Theme.dim) }
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { hover = $0 }
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                CandidatePicker(title: label, current: currentRaw.map(format) ?? value, candidates: candidates, format: format) { v in
                    showPicker = false; onSelect(v)
                }
            }
        }
    }
}

/// Edge-column button: grey box, white text; orange when active (the viewfinder's selected state).
struct EdgeButton: View {
    let title: String
    var active = false
    var enabled = true
    var tint: Color? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 9.5, weight: .bold)).tracking(0.6)
                .foregroundStyle(active ? Color.black : (tint ?? Theme.text))
                .frame(width: 46, height: 24)
                .background(active ? Theme.accent : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

// MARK: - Top strip: exposure readouts

struct TopStrip: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays

    var body: some View {
        @Bindable var ov = overlays
        let s = session.state
        let fpsChoices = ["24", "25", "30", "48", "50", "60"]
        HStack(spacing: 2) {
            StripReadout(label: "FPS", value: String(format: "%d.000", overlays.projectFPS), candidates: fpsChoices,
                         onSelect: { v in if let f = Int(v) { ov.projectFPS = f } },
                         onStep: { d in if let i = fpsChoices.firstIndex(of: "\(ov.projectFPS)") { ov.projectFPS = Int(fpsChoices[max(0, min(fpsChoices.count - 1, i + d))])! } })
            StripReadout(label: "SHUTTER", value: shutterAngle(s.shutterSpeed, fps: overlays.projectFPS), suffix: s.shutterSpeed ?? "",
                         candidates: s.shutterSpeedCandidates, enabled: s.supports("setShutterSpeed"), currentRaw: s.shutterSpeed,
                         format: { "\(shutterAngle($0, fps: overlays.projectFPS))   \($0)" },
                         onSelect: { v in Task { await session.setShutterSpeed(v) } },
                         onStep: { d in Task { await session.step(s.shutterSpeedCandidates, current: s.shutterSpeed, by: d) { await session.setShutterSpeed($0) } } })
            StripReadout(label: "IRIS", value: s.fNumber.map { "F " + $0 } ?? "--", candidates: s.fNumberCandidates,
                         enabled: s.supports("setFNumber"), format: { "F " + $0 },
                         onSelect: { v in Task { await session.setFNumber(v) } },
                         onStep: { d in Task { await session.step(s.fNumberCandidates, current: s.fNumber, by: d) { await session.setFNumber($0) } } })
            StripReadout(label: "EI", value: s.iso ?? "--", candidates: s.isoCandidates, enabled: s.supports("setIsoSpeedRate"),
                         onSelect: { v in Task { await session.setISO(v) } },
                         onStep: { d in Task { await session.step(s.isoCandidates, current: s.iso, by: d) { await session.setISO($0) } } })
            StripReadout(label: "EV", value: s.exposureCompensation?.label ?? "--",
                         candidates: evCandidates(s.exposureCompensation),
                         enabled: s.supports("setExposureCompensation") && s.exposureCompensation != nil,
                         accent: (s.exposureCompensation?.index ?? 0) == 0 ? Theme.text : Theme.accent,
                         format: { String($0.split(separator: "|").first ?? "") },
                         onSelect: { v in if let i = Int(v.split(separator: "|").last ?? "") { Task { await session.setExposureCompensation(index: i) } } },
                         onStep: { d in Task { await session.stepExposureCompensation(d) } })
            StripReadout(label: "WB", value: wbValue(s), suffix: ccText(s), candidates: wbCandidates(s),
                         enabled: s.supports("setWhiteBalance"), format: wbFormat,
                         onSelect: { v in
                             if let k = Int(v) { Task { await session.setWhiteBalance(mode: "Color Temperature", colorTemp: k) } }
                             else { Task { await session.setWhiteBalance(mode: v, colorTemp: nil) } }
                         },
                         onStep: { d in
                             guard s.whiteBalanceMode == "Color Temperature", let k = s.colorTemperature else { return }
                             Task { await session.setWhiteBalance(mode: "Color Temperature", colorTemp: max(2500, min(9900, k + d * 100))) }
                         })
            StripReadout(label: "FOCUS", value: s.focusMode ?? "--", candidates: s.focusModeCandidates, enabled: s.supports("setFocusMode"),
                         accent: s.focusStatus == "Focused" ? Theme.ok : (s.focusStatus == "Failed" ? Theme.rec : Theme.text),
                         onSelect: { v in Task { await session.setFocusMode(v) } },
                         onStep: { d in Task { await session.step(s.focusModeCandidates, current: s.focusMode, by: d) { await session.setFocusMode($0) } } })
            Spacer(minLength: 4)
            if let err = session.lastError {
                Text(err).font(Theme.mono(10)).foregroundStyle(Theme.warn).lineLimit(1).frame(maxWidth: 320).padding(.horizontal, 6)
            }
            HStack(spacing: 6) {
                Text(overlays.profile.short).font(.system(size: 9.5, weight: .bold)).foregroundStyle(overlays.profile.isLog ? Theme.accent : Theme.dim)
                Text(modeShort(s.exposureMode)).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 5).padding(.vertical, 2).background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                Text(overlays.cameraIndex).font(.system(size: 15, weight: .bold)).foregroundStyle(Color.black)
                    .frame(width: 24, height: 24).background(Theme.text, in: RoundedRectangle(cornerRadius: 3))
            }
            .padding(.trailing, 8)
        }
        .frame(height: 34)
        .background(Theme.field)
    }

    private func shutterAngle(_ speed: String?, fps: Int) -> String {
        guard let speed, let secs = exposureSeconds(speed) else { return "--" }
        let angle = 360.0 * Double(fps) * secs
        if angle > 360 { return "360+" }
        return String(format: "%.1f", angle)
    }
    private func exposureSeconds(_ s: String) -> Double? {
        if s.uppercased() == "BULB" || s == "--" { return nil }
        if s.hasSuffix("\"") { return Double(s.dropLast()) }
        let p = s.split(separator: "/")
        if p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b > 0 { return a / b }
        return Double(s)
    }
    private func evCandidates(_ ev: ExposureCompensation?) -> [String] {
        guard let ev else { return [] }
        return (ev.minIndex ... ev.maxIndex).reversed().map { i in
            let v = Double(i) * ev.stepEV
            let label = abs(v) < 0.01 ? "0" : String(format: "%@%.1f", v > 0 ? "+" : "", v)
            return "\(label)|\(i)"
        }
    }
    private func wbValue(_ s: CameraState) -> String {
        guard let m = s.whiteBalanceMode else { return "--" }
        if m == "Color Temperature", let k = s.colorTemperature { return "\(k) K" }
        return wbFormat(m)
    }
    private func ccText(_ s: CameraState) -> String {
        guard let cc = s.ccShift else { return "" }
        let v = Double(cc) / 4          // camera steps of 0.25
        return String(format: "%@%.1f CC", v >= 0 ? "+" : "", v)
    }
    private func wbFormat(_ v: String) -> String {
        if Int(v) != nil { return v + " K" }
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
        case "Underwater Auto": return "UW"
        default: return v.uppercased()
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
}

// MARK: - Bottom strip: lens, power, clip, state, media, timecode

struct BottomStrip: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays

    var body: some View {
        let s = session.state
        let rec = s.isRecording
        HStack(spacing: 0) {
            item("FCL", s.focalLengthMM.map { String(format: "%.1fmm", $0) } ?? "--")
            item("PWR", s.battery.map { "\(Int($0.fraction * 100))%" } ?? "--",
                 tint: (s.battery?.fraction ?? 1) < 0.15 ? Theme.rec : Theme.text)
            item(nil, String(format: "%@_%04d  C%03d", overlays.cameraIndex, overlays.reel, max(1, session.takes + (rec ? 0 : 1))))
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(rec ? Theme.rec : Theme.ok).frame(width: 9, height: 9)
                Text(rec ? "REC" : "STBY").font(Theme.strip(13)).foregroundStyle(rec ? Theme.rec : Theme.ok)
                if rec { Text(duration(s.recordingTimeSeconds)).font(Theme.strip(13)).foregroundStyle(Theme.rec) }
            }
            .padding(.horizontal, 10)
            Spacer()
            if let m = s.recordableMinutes { item("MEDIA", String(format: "%d:%02d h", m / 60, m % 60)) }
            else if let n = s.shotsRemaining { item("MEDIA", "\(n)") }
            else { item("MEDIA", "--") }
            TimelineView(.periodic(from: .now, by: 1.0 / Double(overlays.projectFPS))) { ctx in
                item("TC", timecode(ctx.date, fps: overlays.projectFPS), tint: rec ? Theme.rec : Theme.text)
            }
            HStack(spacing: 8) {
                if let t = session.transport { Text(t.rawValue.uppercased()).font(Theme.label(9)).foregroundStyle(Theme.dim) }
                Text(String(format: "%.0f FPS", session.fps)).font(Theme.label(9)).foregroundStyle(Theme.dim)
                if session.smoothMotion { Text("×2").font(Theme.label(9)).foregroundStyle(Theme.accent) }
            }
            .padding(.trailing, 10)
        }
        .frame(height: 30)
        .background(Theme.field)
    }

    private func item(_ label: String?, _ value: String, tint: Color = Theme.text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let label { Text(label).font(Theme.label(9)).tracking(1.2).foregroundStyle(Theme.dim) }
            Text(value).font(Theme.strip(13)).foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
    }
    private func duration(_ secs: Int) -> String { String(format: "%02d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60) }
    private func timecode(_ date: Date, fps: Int) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let frames = Int(Double(c.nanosecond ?? 0) / 1e9 * Double(fps))
        return String(format: "%02d:%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, frames)
    }
}

// MARK: - Edge columns

struct LeftTools: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    @State private var showProfile = false

    var body: some View {
        @Bindable var ov = overlays
        VStack(spacing: 5) {
            EdgeButton(title: overlays.profile.short, active: false, tint: overlays.profile.isLog ? Theme.accent : Theme.text) { showProfile.toggle() }
                .popover(isPresented: $showProfile, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("PICTURE PROFILE ON CAMERA").font(Theme.label()).tracking(1.6).foregroundStyle(Theme.dim).padding(12)
                        Divider().overlay(Theme.panelLine)
                        ForEach(PictureProfile.allCases) { p in
                            Button { ov.profile = p; showProfile = false } label: {
                                Text(p.rawValue).font(Theme.mono(13, weight: p == overlays.profile ? .semibold : .regular))
                                    .foregroundStyle(p == overlays.profile ? Color.black : Theme.text)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(p == overlays.profile ? Theme.selection : .clear).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        Text("Set the profile in the camera menu; this tells the monitor which log curve to convert.")
                            .font(.system(size: 10)).foregroundStyle(Theme.dim).padding(12).frame(width: 260, alignment: .leading)
                    }
                    .background(Theme.panel)
                }
            EdgeButton(title: overlays.lutOn ? (overlays.customLUT != nil ? "LUT" : "709") : "LOG", active: overlays.lutOn && (overlays.profile.isLog || overlays.customLUT != nil),
                       enabled: overlays.profile.isLog || overlays.customLUT != nil) { ov.lutOn.toggle() }
            EdgeButton(title: "EXP", active: overlays.falseColor) { ov.falseColor.toggle() }
            EdgeButton(title: "PEAK", active: overlays.peaking) { ov.peaking.toggle() }
            EdgeButton(title: "ZEBRA", active: overlays.zebra) { ov.zebra.toggle() }
            EdgeButton(title: "2.00×", active: overlays.magnify) { ov.magnify.toggle() }
            Spacer().frame(height: 6)
            EdgeButton(title: "FRAME", active: overlays.grid) { ov.grid.toggle() }
            EdgeButton(title: "GUIDE", active: overlays.frameGuides) { ov.frameGuides.toggle() }
            EdgeButton(title: overlays.crop == .native ? "CROP" : overlays.crop.label, active: overlays.crop != .native) { ov.crop = ov.crop.next }
            Spacer()
            EdgeButton(title: "MENU", active: overlays.showMenu) { ov.showMenu.toggle() }
        }
        .padding(.vertical, 8)
    }
}

struct RightTools: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays

    var body: some View {
        @Bindable var ov = overlays
        let s = session.state
        let canRec = s.supports("startMovieRec") || s.supports("stopMovieRec")
        VStack(spacing: 5) {
            EdgeButton(title: overlays.scope == .none ? "SCOPE" : overlays.scope.rawValue, active: overlays.scope != .none) { ov.scope = ov.scope.next }
            EdgeButton(title: "ENH", active: overlays.enhanced) { ov.enhanced.toggle() }
            EdgeButton(title: "MOTION", active: session.smoothMotion) { session.smoothMotion.toggle() }
            Spacer().frame(height: 6)
            EdgeButton(title: "AF", enabled: s.supports("actHalfPressShutter")) { Task { await session.autofocus() } }
            EdgeButton(title: "AEL") { Task { await session.press(.aeLock) } }
            HStack(spacing: 3) {
                EdgeButton(title: "◀ NEAR", enabled: session.transport == .usb) { Task { await session.focusDrive(-2) } }
            }
            EdgeButton(title: "FAR ▶", enabled: session.transport == .usb) { Task { await session.focusDrive(2) } }
            EdgeButton(title: "STILL", enabled: s.supports("actTakePicture")) { Task { await session.takePicture() } }
            Spacer()
            Button { Task { await session.toggleRecording() } } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(s.isRecording ? Theme.rec : Color.white.opacity(0.14)).frame(width: 46, height: 34)
                    HStack(spacing: 5) {
                        Circle().fill(s.isRecording ? Color.white : Theme.rec).frame(width: 10, height: 10)
                        Text(s.isRecording ? "STOP" : "REC").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.text)
                    }
                }
            }
            .buttonStyle(.plain).disabled(!canRec).opacity(canRec ? 1 : 0.35)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Settings panel

struct SettingsPanel: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays

    var body: some View {
        @Bindable var ov = overlays
        let groups = Dictionary(grouping: session.settings, by: \.group)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CAMERA MENU").font(Theme.label()).tracking(1.6).foregroundStyle(Theme.dim)
                Spacer()
                Button { ov.showMenu = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider().overlay(Theme.panelLine)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Monitor") {
                        row("Camera picture profile") {
                            Picker("", selection: $ov.profile) { ForEach(PictureProfile.allCases) { Text($0.rawValue).tag($0) } }
                        }
                        row("Display LUT") {
                            HStack {
                                Toggle(overlays.customLUTName ?? (overlays.profile.isLog ? "Log → Rec.709" : "None needed"), isOn: $ov.lutOn).toggleStyle(.switch).controlSize(.mini)
                                    .disabled(!(overlays.profile.isLog || overlays.customLUT != nil))
                            }
                        }
                        row("Scope") { Picker("", selection: $ov.scope) { ForEach(ScopeKind.allCases) { Text($0.title).tag($0) } } }
                        row("Project frame rate") { Picker("", selection: $ov.projectFPS) { ForEach([24, 25, 30, 48, 50, 60], id: \.self) { Text("\($0) fps").tag($0) } } }
                        row("Camera index") { Picker("", selection: $ov.cameraIndex) { ForEach(["A", "B", "C", "D"], id: \.self) { Text($0).tag($0) } } }
                        row("Reel") { Stepper(value: $ov.reel, in: 1 ... 999) { Text(String(format: "%04d", overlays.reel)).font(Theme.mono(12)) } }
                    }
                    ForEach(["Exposure", "Focus", "Shooting", "Image"], id: \.self) { g in
                        if let items = groups[g], !items.isEmpty {
                            section(g) {
                                ForEach(items) { st in
                                    row(st.name) {
                                        Picker("", selection: Binding(get: { st.current }, set: { v in Task { await session.setSetting(st.id, v) } })) {
                                            ForEach(st.candidates.contains(st.current) ? st.candidates : [st.current] + st.candidates, id: \.self) { Text($0).tag($0) }
                                        }
                                        .disabled(!st.settable)
                                    }
                                }
                            }
                        }
                    }
                    if session.settings.isEmpty {
                        Text(session.transport == .wifi ? "Extra camera settings are available over USB (PC Remote)." : "No extra settings reported by the camera.")
                            .font(.system(size: 11)).foregroundStyle(Theme.dim).padding(.horizontal, 12)
                    }
                    section("Focus drive") {
                        HStack(spacing: 6) {
                            ForEach([(-7, "◀◀◀"), (-4, "◀◀"), (-1, "◀"), (1, "▶"), (4, "▶▶"), (7, "▶▶▶")], id: \.0) { step, label in
                                Button(label) { Task { await session.focusDrive(step) } }.buttonStyle(.bordered).controlSize(.small)
                                    .disabled(session.transport != .usb)
                            }
                        }
                        .padding(.horizontal, 12)
                        Text("Works in MF / DMF. Near ◀ · Far ▶, larger arrows move further.").font(.system(size: 10)).foregroundStyle(Theme.dim).padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .frame(width: 330)
        .background(Theme.panel.opacity(0.97))
        .overlay(Rectangle().fill(Theme.panelLine).frame(width: 1), alignment: .leading)
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(Theme.label()).tracking(1.6).foregroundStyle(Theme.accent).padding(.horizontal, 12)
            content()
        }
    }
    @ViewBuilder private func row<C: View>(_ name: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            Text(name).font(.system(size: 12)).foregroundStyle(Theme.text)
            Spacer()
            control().labelsHidden().frame(maxWidth: 170).controlSize(.small)
        }
        .padding(.horizontal, 12)
    }
}
