#if !os(macOS)
import SwiftUI
import SonyCameraKit

struct MobileSettingsView: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var ov = overlays
        NavigationStack {
            Form {
                Section("Connection") {
                    HStack { Text("Camera"); Spacer(); Text(session.cameraName.isEmpty ? "—" : session.cameraName).foregroundStyle(Theme.dim) }
                    HStack { Text("Transport"); Spacer(); Text(session.transport?.rawValue ?? "—").foregroundStyle(Theme.dim) }
                    Button("Disconnect", role: .destructive) { session.disconnect(); dismiss() }
                }
                Section("Display") {
                    Picker("Interpret feed as", selection: $ov.feedColorSpace) { ForEach(FeedColorSpace.allCases) { Text($0.short).tag($0) } }
                    Toggle("Enhanced upscaling (MetalFX)", isOn: $ov.enhanced)
                    Toggle("Detail recovery", isOn: $ov.detail)
                    Picker("Smooth motion", selection: Binding(get: { session.motionFactor }, set: { session.motionFactor = $0 })) {
                        Text("Off").tag(1); Text("×2").tag(2); Text("×4").tag(4); Text("×8").tag(8)
                    }
                    Picker("Live denoise", selection: Binding(get: { session.denoise }, set: { session.denoise = $0 })) {
                        Text("Off").tag(Float(0)); Text("NR1").tag(Float(0.5)); Text("NR2").tag(Float(1))
                    }
                    Picker("Camera picture profile", selection: $ov.profile) { ForEach(PictureProfile.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("Apply display LUT (709 view)", isOn: $ov.lutOn).disabled(!(overlays.profile.isLog || overlays.customLUT != nil))
                    Toggle("Hide HUD", isOn: $ov.hideHUD)
                }
                Section("Guides") {
                    Toggle("Thirds grid", isOn: $ov.grid)
                    Toggle("Centre marker", isOn: $ov.centerMarker)
                    Toggle("Action / title safe", isOn: $ov.safeAreas)
                    Toggle("Diagonals", isOn: $ov.diagonals)
                    Toggle("Frame lines", isOn: $ov.frameGuides)
                    Picker("Frame line ratio", selection: $ov.guideRatio) { ForEach(FrameGuideRatio.allCases) { Text($0.label).tag($0) } }
                }
                Section("Focus assist") {
                    Toggle("Focus peaking", isOn: $ov.peaking)
                    Picker("Peaking colour", selection: $ov.peakingColor) { ForEach(PeakingColor.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("Sharpness meter", isOn: $ov.showSharpnessMeter)
                    HStack { Text("Zebra level"); Spacer(); Text("\(Int(overlays.zebraLevel * 100)) IRE").foregroundStyle(Theme.dim) }
                    Slider(value: $ov.zebraLevel, in: 0.7 ... 1.0, step: 0.05)
                }
                Section("Captures") {
                    HStack { Text("This session"); Spacer(); Text("\(session.captures.count) shots").foregroundStyle(Theme.dim) }
                    Text("Files the camera hands over are saved in the Files app under CinemaHUD. Over the Mac bridge, files stay on the Mac in ~/Pictures/CinemaHUD.")
                        .font(.footnote).foregroundStyle(Theme.dim)
                }
                Section("About") {
                    HStack { Text("CinemaHUD"); Spacer(); Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").foregroundStyle(Theme.dim) }
                    Text("Independent remote monitor for Sony α cameras. Not affiliated with Sony.").font(.footnote).foregroundStyle(Theme.dim)
                    NavigationLink("Privacy Policy") { LegalPageView(title: "Privacy Policy", text: LegalText.privacyPolicy) }
                    NavigationLink("Terms of Use") { LegalPageView(title: "Terms of Use", text: LegalText.termsOfUse) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.field)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
        .tint(Theme.accent)
    }
}
#endif
