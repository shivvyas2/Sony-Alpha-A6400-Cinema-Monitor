#if !os(macOS)
import SwiftUI
import SonyCameraKit

enum MobileMetrics {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static var target: CGFloat { isPad ? 52 : 44 }
    static var railWidth: CGFloat { isPad ? 72 : 60 }
    /// Width of the side panel that replaces bottom sheets in landscape: a narrow column over the
    /// picture's right edge, like a cinema monitor's menu list, so most of the feed stays in view.
    static var panelWidth: CGFloat { isPad ? 260 : 220 }
}

/// Non-nil while a sheet's content is hosted in the landscape side panel; calling it closes the panel.
/// Sheet views use it to swap their navigation-bar chrome for a compact header and to dismiss.
struct MobilePanelDismissKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var mobilePanelDismiss: (() -> Void)? {
        get { self[MobilePanelDismissKey.self] }
        set { self[MobilePanelDismissKey.self] = newValue }
    }
}

/// Translucent column over the picture's right edge in landscape, in the idiom of a cinema monitor's
/// menu list: the live feed stays visible around and through it. Hosts the same content the bottom
/// sheets show in portrait, restyled compact (small type, plain rows, ON/OFF toggles).
struct MobilePanel<Content: View>: View {
    let onClose: () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        content
            .environment(\.mobilePanelDismiss, onClose)
            .environment(\.defaultMinListRowHeight, 34)
            .font(.system(size: 13))
            .dynamicTypeSize(.small)
            .controlSize(.small)
            .toggleStyle(MobilePanelToggleStyle())
            .frame(width: MobileMetrics.panelWidth)
            .background(Theme.field.opacity(0.78))
            .overlay(Rectangle().stroke(Theme.panelLine, lineWidth: 1))
            .tint(Theme.accent)
    }
}

/// Title row for panel content: small tracked label, thin rule, and a close mark.
struct MobilePanelHeader: View {
    let title: String
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.uppercased()).font(Theme.label(10)).tracking(2.5).foregroundStyle(Theme.text)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.dim)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.leading, 12).padding(.trailing, 2).frame(height: 34)
            Rectangle().fill(Theme.panelLine).frame(height: 1)
        }
    }
}

/// Toggle drawn as a label with an ON / OFF pill on the right, as on a monitor menu.
struct MobilePanelToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label.foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Text(configuration.isOn ? "ON" : "OFF").font(Theme.label(9)).tracking(1.2)
                    .foregroundStyle(configuration.isOn ? Color.black : Theme.dim)
                    .frame(width: 38, height: 20)
                    .background(configuration.isOn ? Theme.accent : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Rail / deck button: SF Symbol over a tiny tracked label. Orange when active, like the Mac's edge buttons.
struct MobileToolButton: View {
    let icon: String
    let label: String
    var active = false
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: MobileMetrics.isPad ? 20 : 17, weight: .semibold))
                Text(label).font(.system(size: 8.5, weight: .bold)).tracking(0.6).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(active ? Color.black : Theme.text)
            .frame(width: MobileMetrics.target + 4, height: MobileMetrics.target)
            .background(active ? Theme.accent : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// Exposure readout: tap opens a candidate sheet, vertical drag steps like a dial.
struct MobileReadout: View {
    let label: String
    let value: String
    var enabled = true
    var accent: Color = Theme.text
    var onStep: (Int) -> Void = { _ in }
    var onTap: () -> Void = {}
    var body: some View {
        ScrollStepper(onStep: { if enabled { onStep($0) } }) {
            Button(action: { if enabled { onTap() } }) {
                VStack(spacing: 2) {
                    Text(label).font(Theme.label(9)).tracking(1.2).foregroundStyle(Theme.dim)
                    Text(value).font(Theme.strip(MobileMetrics.isPad ? 20 : 17)).foregroundStyle(enabled ? accent : Theme.faint).lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(minWidth: MobileMetrics.isPad ? 76 : 58, minHeight: MobileMetrics.target)
                .padding(.horizontal, MobileMetrics.isPad ? 8 : 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// VIDEO | PHOTO, in the monitor's monochrome idiom.
struct ModeSwitch: View {
    let mode: ShootingMode
    let onChange: (ShootingMode) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(ShootingMode.allCases, id: \.self) { m in
                Button { onChange(m) } label: {
                    Text(m.rawValue).font(.system(size: 11, weight: .bold)).tracking(1.2)
                        .foregroundStyle(m == mode ? Color.black : Theme.text)
                        .frame(width: 66, height: 30)
                        .background(m == mode ? Theme.text : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
    }
}

/// Candidate list for a readout, presented as a bottom sheet.
struct MobileCandidateSheet: View {
    let title: String
    let current: String
    let candidates: [String]
    var format: (String) -> String = { $0 }
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePanelDismiss) private var panelDismiss
    var body: some View {
        if let panelDismiss {
            VStack(spacing: 0) {
                MobilePanelHeader(title: title, onClose: panelDismiss)
                column { onPick($0); panelDismiss() }
            }
        } else {
            NavigationStack {
                list { onPick($0); dismiss() }
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func list(pick: @escaping (String) -> Void) -> some View {
        ScrollViewReader { proxy in
            List(candidates, id: \.self) { c in
                Button { pick(c) } label: {
                    HStack {
                        Text(format(c)).font(Theme.mono(16, weight: c == current ? .semibold : .regular)).foregroundStyle(Theme.text)
                        Spacer()
                        if c == current { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                    .frame(minHeight: 44)
                }
                .listRowBackground(Theme.panel)
                .id(c)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.field)
            .onAppear { if candidates.contains(current) { proxy.scrollTo(current, anchor: .center) } }
        }
    }

    /// Panel mode: a column of values with the current one filled, like a monitor's value list.
    private func column(pick: @escaping (String) -> Void) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(candidates, id: \.self) { c in
                        Button { pick(c) } label: {
                            Text(format(c)).font(Theme.mono(15, weight: c == current ? .semibold : .regular))
                                .foregroundStyle(c == current ? Color.black : Theme.text)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(c == current ? Theme.accent : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(c)
                    }
                }
                .padding(8)
            }
            .onAppear { if candidates.contains(current) { proxy.scrollTo(current, anchor: .center) } }
        }
    }
}

struct RecordButton: View {
    let recording: Bool
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 3).frame(width: 60, height: 60)
                RoundedRectangle(cornerRadius: recording ? 5 : 24).fill(Theme.rec).frame(width: recording ? 26 : 48, height: recording ? 26 : 48)
                    .animation(.easeInOut(duration: 0.15), value: recording)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(recording ? "Stop recording" : "Start recording")
    }
}

struct ShutterButton: View {
    var enabled = true
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 3).frame(width: 60, height: 60)
                Circle().fill(Color.white.opacity(busy ? 0.4 : 0.92)).frame(width: 48, height: 48)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .accessibilityLabel("Take picture")
    }
}

/// W ◀ ▶ T rocker: hold to zoom continuously, tap for one step; position bar between.
struct ZoomRocker: View {
    let position: Int?
    var enabled = true
    let onZoom: (ZoomDirection, ZoomMovement) -> Void
    @State private var held: ZoomDirection?
    var body: some View {
        HStack(spacing: 10) {
            key("W", .out)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2)).frame(height: 6)
                Capsule().fill(Theme.text).frame(width: max(6, 120 * CGFloat(position ?? 0) / 100), height: 6)
            }
            .frame(width: 120)
            key("T", .in)
        }
        .opacity(enabled ? 1 : 0.35)
    }
    private func key(_ title: String, _ dir: ZoomDirection) -> some View {
        Text(title).font(.system(size: 16, weight: .heavy)).foregroundStyle(held == dir ? Color.black : Theme.text)
            .frame(width: MobileMetrics.target, height: MobileMetrics.target)
            .background(held == dir ? Theme.accent : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if enabled, held == nil { held = dir; onZoom(dir, .start) } }
                    .onEnded { _ in
                        guard enabled else { return }
                        held = nil
                        onZoom(dir, .stop)
                    }
            )
            .simultaneousGesture(TapGesture().onEnded { if enabled { onZoom(dir, .oneShot) } })
    }
}

/// Sony's focus dot: green = focused, blinking red = failed, hollow = hunting.
struct FocusDot: View {
    let status: String?
    @State private var blink = false
    var body: some View {
        Group {
            switch status {
            case "Focused": Circle().fill(Theme.ok)
            case "Failed": Circle().fill(Theme.rec).opacity(blink ? 1 : 0.15)
            case "Focusing": Circle().stroke(Color.white, lineWidth: 1.5)
            default: Circle().fill(.clear)
            }
        }
        .frame(width: 11, height: 11)
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in blink.toggle() }
    }
}

struct SharpnessBar: View {
    let ratio: Double
    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(width: 60, height: 5)
                Capsule().fill(ratio >= FocusAnalyzer.inFocusRatio ? Theme.ok : (ratio >= FocusAnalyzer.softRatio ? Theme.warn : Color.white))
                    .frame(width: 60 * max(0.02, min(1, ratio)), height: 5)
            }
            Text(String(format: "%.0f", ratio * 100)).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// This session's shots; tap to review.
struct MobileFilmstrip: View {
    @Environment(CameraSession.self) private var session
    @State private var thumbs = ThumbnailCache()
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(session.captures.suffix(12)) { shot in
                    Button { session.review(shot) } label: {
                        ZStack(alignment: .bottomTrailing) {
                            if let url = shot.primary?.url, let t = thumbs.image(for: url) {
                                Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Rectangle().fill(Color.white.opacity(0.15))
                            }
                            if shot.transferring { ProgressView().controlSize(.mini).padding(3) }
                            else if shot.hasBoth { Text("RAW+J").font(.system(size: 8, weight: .bold)).foregroundStyle(.white).padding(3) }
                        }
                        .frame(width: 64, height: 43).clipped()
                        .overlay(Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 43)
    }
}
#endif
