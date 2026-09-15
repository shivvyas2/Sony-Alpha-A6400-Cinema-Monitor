#if !os(macOS)
import SwiftUI
import SonyCameraKit

/// Common frame for every sheet: title, Done, dark list styling.
struct SheetChrome<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form { content }
                .scrollContentBackground(.hidden)
                .background(Theme.field)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(Theme.accent)
    }
}

private struct SetOnCamera: View {
    let what: String
    var body: some View {
        HStack { Text(what); Spacer(); Text("Set on camera").foregroundStyle(Theme.dim) }
    }
}

struct GuidesSheet: View {
    @Environment(OverlaySettings.self) private var overlays
    var body: some View {
        @Bindable var ov = overlays
        SheetChrome(title: "Guides") {
            Section {
                Toggle("Thirds grid", isOn: $ov.grid)
                Toggle("Centre marker", isOn: $ov.centerMarker)
                Toggle("Action / title safe", isOn: $ov.safeAreas)
                Toggle("Diagonals", isOn: $ov.diagonals)
            }
            Section("Frame lines") {
                Toggle("Show frame lines", isOn: $ov.frameGuides)
                Picker("Ratio", selection: $ov.guideRatio) { ForEach(FrameGuideRatio.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).disabled(!overlays.frameGuides)
            }
            Section("Monitor crop") {
                Picker("Crop", selection: $ov.crop) { ForEach(CropRatio.allCases) { Text($0.label).tag($0) } }
                Text("Crop trims the picture to the ratio; frame lines only draw over it.").font(.footnote).foregroundStyle(Theme.dim)
            }
            Section {
                Button("Clear all guides", role: .destructive) {
                    ov.grid = false; ov.centerMarker = false; ov.safeAreas = false; ov.diagonals = false; ov.frameGuides = false; ov.crop = .native
                }
            }
        }
    }
}

struct FocusSheet: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    let liveSharpness: Double
    @State private var wheel: CGFloat = 0
    var body: some View {
        @Bindable var ov = overlays
        let s = session.state
        SheetChrome(title: "Focus") {
            Section("Autofocus") {
                if !s.focusModeCandidates.isEmpty {
                    Picker("Mode", selection: Binding(get: { s.focusMode ?? "" }, set: { v in Task { await session.setFocusMode(v) } })) {
                        ForEach(s.focusModeCandidates, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented).disabled(!s.supports("setFocusMode"))
                } else {
                    SetOnCamera(what: "Focus mode")
                }
                HStack {
                    Button { Task { await session.autofocus() } } label: { Label("Autofocus", systemImage: "scope").frame(maxWidth: .infinity, minHeight: 36) }
                        .buttonStyle(.bordered).disabled(!s.supports("actHalfPressShutter"))
                    FocusDot(status: s.focusStatus)
                    Text(s.focusStatus ?? "").font(.footnote).foregroundStyle(Theme.dim)
                }
            }
            Section("Manual focus") {
                if session.focusDriveAvailable {
                    // Wheel: drag left/right nudges focus in fine steps, like turning the ring.
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)).frame(height: 56)
                        HStack(spacing: 0) {
                            ForEach(0 ..< 24, id: \.self) { i in
                                Rectangle().fill(Color.white.opacity(i % 6 == 0 ? 0.7 : 0.3)).frame(width: 1, height: i % 6 == 0 ? 24 : 12)
                                if i < 23 { Spacer() }
                            }
                        }
                        .padding(.horizontal, 12)
                        Text("NEAR   ◀   FOCUS RING   ▶   FAR").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.dim).offset(y: 20)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4).onChanged { g in
                        let step: CGFloat = 12
                        let delta = g.translation.width - wheel
                        if abs(delta) >= step { wheel = g.translation.width; Task { await session.focusDrive(delta > 0 ? 1 : -1) } }
                    }.onEnded { _ in wheel = 0 })
                    HStack(spacing: 8) {
                        ForEach([(-7, "◀◀◀"), (-4, "◀◀"), (-1, "◀"), (1, "▶"), (4, "▶▶"), (7, "▶▶▶")], id: \.0) { step, label in
                            Button(label) { Task { await session.focusDrive(step) } }.buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 40)
                        }
                    }
                    Text("Works in MF / DMF. Larger arrows move further.").font(.footnote).foregroundStyle(Theme.dim)
                } else {
                    Text("Manual focus drive needs USB or the Mac bridge; Sony's Wi-Fi remote API has no focus ring control.")
                        .font(.footnote).foregroundStyle(Theme.dim)
                }
            }
            Section("Focus assist") {
                Toggle("Focus peaking", isOn: $ov.peaking)
                Picker("Peaking colour", selection: $ov.peakingColor) { ForEach(PeakingColor.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).disabled(!overlays.peaking)
                Toggle("2× magnify", isOn: $ov.magnify)
                Toggle("Sharpness meter", isOn: $ov.showSharpnessMeter)
                HStack { Text("AF region sharpness"); Spacer(); SharpnessBar(ratio: liveSharpness) }
                Text("The meter scores the AF region against the sharpest part of the frame. Tap the picture to move the region.")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
        }
    }
}

struct ZoomSheet: View {
    @Environment(CameraSession.self) private var session
    var body: some View {
        SheetChrome(title: "Zoom") {
            if session.zoomAvailable {
                Section {
                    HStack { Spacer(); ZoomRocker(position: session.state.zoomPosition) { d, m in Task { await session.zoom(d, m) } }; Spacer() }
                        .padding(.vertical, 8)
                    if let f = session.state.focalLengthMM { HStack { Text("Focal length"); Spacer(); Text(String(format: "%.0f mm", f)).foregroundStyle(Theme.dim) } }
                    Text("Hold W or T to zoom, tap for one step.").font(.footnote).foregroundStyle(Theme.dim)
                }
            } else {
                Section {
                    Text(session.transport == .wifi
                         ? "The camera reports no power-zoom lens. Zoom works with power-zoom lenses such as the 16-50 mm PZ."
                         : "Zoom control is only available over the camera's Wi-Fi connection with a power-zoom lens; the USB protocol has no zoom drive.")
                        .font(.footnote).foregroundStyle(Theme.dim)
                }
            }
        }
    }
}

struct FormatSheet: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    var body: some View {
        @Bindable var ov = overlays
        let s = session.state
        SheetChrome(title: "Format") {
            Section("Stills") {
                if session.stillSizeAvailable {
                    Picker("Size and aspect", selection: Binding(get: { s.stillSize?.id ?? "" }, set: { id in
                        if let pick = s.stillSizeCandidates.first(where: { $0.id == id }) { Task { await session.setStillSize(pick) } }
                    })) {
                        ForEach(s.stillSizeCandidates) { Text($0.label).tag($0.id) }
                    }
                } else {
                    SetOnCamera(what: "Still size and aspect")
                }
            }
            Section("Movie") {
                if session.movieFileFormatAvailable {
                    Picker("File format", selection: Binding(get: { s.movieFileFormat ?? "" }, set: { v in Task { await session.setMovieFileFormat(v) } })) {
                        ForEach(s.movieFileFormatCandidates, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    SetOnCamera(what: "File format")
                }
                if session.movieQualityAvailable {
                    Picker("Quality", selection: Binding(get: { s.movieQuality ?? "" }, set: { v in Task { await session.setMovieQuality(v) } })) {
                        ForEach(s.movieQualityCandidates, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    SetOnCamera(what: "Resolution / quality")
                }
                Text(session.transport == .wifi
                     ? "Rows marked \"Set on camera\" are not exposed by this camera's remote API."
                     : "The α6400's USB protocol does not expose movie format; change it on the body.")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
            Section("Monitor") {
                Picker("Crop ratio", selection: $ov.crop) { ForEach(CropRatio.allCases) { Text($0.menuTitle).tag($0) } }
                Picker("Project frame rate", selection: $ov.projectFPS) { ForEach([24, 25, 30, 48, 50, 60], id: \.self) { Text("\($0) fps").tag($0) } }
            }
        }
    }
}
#endif
