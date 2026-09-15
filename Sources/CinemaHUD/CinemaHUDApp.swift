import SwiftUI
import AppKit
import SonyCameraKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DevHooks.applyWindowSize()
        DevHooks.scheduleSnapshot()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CinemaHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = CameraSession()
    @State private var overlays = OverlaySettings()

    var body: some Scene {
        WindowGroup("CinemaHUD") {
            ContentView()
                .environment(session)
                .environment(overlays)
                .frame(minWidth: 960, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Camera") {
                Button("Autofocus") { Task { await session.autofocus() } }.keyboardShortcut(.space, modifiers: [])
                Button("Take Picture") { Task { await session.takePicture() } }.keyboardShortcut(.return, modifiers: [])
                Button(session.state.isRecording ? "Stop Recording" : "Start Recording") { Task { await session.toggleRecording() } }
                    .keyboardShortcut("r", modifiers: [])
                Divider()
                Button("Disconnect") { session.disconnect() }.keyboardShortcut("d", modifiers: [.command])
            }
            CommandMenu("Aspect") {
                ForEach(Array(CropRatio.allCases.enumerated()), id: \.element) { i, ratio in
                    Button {
                        overlays.crop = ratio
                    } label: {
                        HStack { Text(ratio.menuTitle); if overlays.crop == ratio { Image(systemName: "checkmark") } }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
                }
                Divider()
                Text("Crop a scope ratio to fill an ultrawide monitor. Use View › Enter Full Screen (⌃⌘F).")
            }
            CommandMenu("Overlays") {
                Toggle("Thirds Grid", isOn: $overlays.grid).keyboardShortcut("g", modifiers: [])
                Toggle("Frame Guides 2.39:1", isOn: $overlays.frameGuides).keyboardShortcut("f", modifiers: [])
                Toggle("Center Marker", isOn: $overlays.centerMarker).keyboardShortcut("c", modifiers: [])
                Toggle("Focus Peaking", isOn: $overlays.peaking).keyboardShortcut("p", modifiers: [])
                Toggle("Zebras", isOn: $overlays.zebra).keyboardShortcut("z", modifiers: [])
                Toggle("False Color", isOn: $overlays.falseColor).keyboardShortcut("v", modifiers: [])
                Toggle("Waveform Scope", isOn: $overlays.waveform).keyboardShortcut("w", modifiers: [])
                Divider()
                Toggle("Enhanced Upscaling (MetalFX)", isOn: $overlays.enhanced).keyboardShortcut("e", modifiers: [])
                Toggle("Smooth Motion (interpolated ×2, adds one frame of delay)", isOn: Binding(get: { session.smoothMotion }, set: { session.smoothMotion = $0 })).keyboardShortcut("m", modifiers: [])
                Divider()
                Picker("Project Frame Rate", selection: $overlays.projectFPS) {
                    ForEach([24, 25, 30, 48, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Toggle("Hide HUD", isOn: $overlays.hideHUD).keyboardShortcut("h", modifiers: [])
            }
        }
    }
}

/// Aspect crop applied to the live view. Cropping to a cinema ratio lets the frame fill an
/// ultrawide (21:9) monitor edge to edge instead of letterboxing a 3:2 or 16:9 feed.
enum CropRatio: String, CaseIterable, Identifiable {
    case native, r16x9, r185, r200, r235, r239
    var id: String { rawValue }
    var value: Double? {
        switch self {
        case .native: return nil
        case .r16x9: return 16.0 / 9.0
        case .r185: return 1.85
        case .r200: return 2.0
        case .r235: return 2.35
        case .r239: return 2.39
        }
    }
    var label: String {
        switch self {
        case .native: return "NATIVE"
        case .r16x9: return "16:9"
        case .r185: return "1.85"
        case .r200: return "2.00"
        case .r235: return "2.35"
        case .r239: return "2.39"
        }
    }
    var menuTitle: String {
        switch self {
        case .native: return "Native (no crop)"
        case .r16x9: return "16:9"
        case .r185: return "1.85:1 Flat"
        case .r200: return "2.00:1 Univisium"
        case .r235: return "2.35:1 Scope"
        case .r239: return "2.39:1 Scope"
        }
    }
    var next: CropRatio { let all = Self.allCases; return all[(all.firstIndex(of: self)! + 1) % all.count] }
}

@Observable
final class OverlaySettings {
    var grid = true
    var frameGuides = false
    var centerMarker = true
    var peaking = false
    var zebra = false
    var hideHUD = false
    var zebraLevel: Double = 0.95
    var crop: CropRatio = .native
    /// MetalFX spatial upscaling of the live view to the display resolution.
    var enhanced = false
    var falseColor = false
    var waveform = false
    /// Project frame rate, used for shutter angle and the timecode frame counter.
    var projectFPS = 24
}

struct ContentView: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if session.phase.isConnected {
                MonitorView()
            } else {
                ConnectView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("CinemaHUD.devReport"))) { _ in
            print(String(format: "report: display=%.1f fps source=%.1f fps motion=%@ size=%.0fx%.0f", session.fps, session.sourceFPS, session.smoothMotion ? "on" : "off", session.frameSize.width, session.frameSize.height))
            fflush(stdout)
        }
        .task {
            // Dev convenience: CINEMAHUD_ADDRESS=127.0.0.1:8080 auto-connects (e.g. to tools/camerasim.py).
            DevHooks.apply(to: overlays)
            if ProcessInfo.processInfo.environment["CINEMAHUD_OVERLAYS"]?.contains("motion") == true { session.smoothMotion = true }
            if let addr = ProcessInfo.processInfo.environment["CINEMAHUD_ADDRESS"], session.phase == .idle {
                await session.connect(toAddress: addr)
            } else if ProcessInfo.processInfo.environment["CINEMAHUD_USB"] == "1", session.phase == .idle {
                await session.connectUSB()
            }
        }
    }
}


/// Development-only hooks driven by environment variables (used by scripts/ and the simulator workflow):
///   CINEMAHUD_ADDRESS=host:port     auto-connect
///   CINEMAHUD_WINDOW=WxH            resize the window
///   CINEMAHUD_SNAPSHOT=/path.png    render the window to a PNG after ~4s
///   CINEMAHUD_QUIT=1                quit after the snapshot
///   CINEMAHUD_OVERLAYS=peaking,zebra,grid,guides,crop=2.39,hidehud
enum DevHooks {
    static let env = ProcessInfo.processInfo.environment

    static func applyWindowSize() {
        guard let spec = env["CINEMAHUD_WINDOW"] else { return }
        let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let w = NSApp.windows.first else { return }
            w.setContentSize(NSSize(width: parts[0], height: parts[1]))
            w.center()
            // Let `screencapture -l` reach the window from any Space, and publish its id for scripts.
            w.collectionBehavior.insert(.canJoinAllSpaces)
            if let path = env["CINEMAHUD_WINDOWID_FILE"] { try? "\(w.windowNumber)".write(toFile: path, atomically: true, encoding: .utf8) }
        }
    }

    static func apply(to overlays: OverlaySettings) {
        guard let spec = env["CINEMAHUD_OVERLAYS"] else { return }
        for tok in spec.lowercased().split(separator: ",") {
            switch tok {
            case "peaking": overlays.peaking = true
            case "zebra": overlays.zebra = true
            case "grid": overlays.grid = true
            case "nogrid": overlays.grid = false
            case "guides": overlays.frameGuides = true
            case "hidehud": overlays.hideHUD = true
            case "enhanced": overlays.enhanced = true
            case "false": overlays.falseColor = true
            case "waveform": overlays.waveform = true
            case "motion": NotificationCenter.default.post(name: .init("CinemaHUD.devMotion"), object: nil)
            default:
                if tok.hasPrefix("crop=") {
                    let v = tok.dropFirst(5)
                    overlays.crop = CropRatio.allCases.first { $0.label.lowercased() == v } ?? .native
                }
            }
        }
    }

    static func scheduleSnapshot() {
        guard let path = env["CINEMAHUD_SNAPSHOT"] else { return }
        let delay = Double(env["CINEMAHUD_SNAPSHOT_DELAY"] ?? "") ?? 4.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let win = NSApp.windows.first, let view = win.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            NotificationCenter.default.post(name: .init("CinemaHUD.devReport"), object: nil)
            if env["CINEMAHUD_QUIT"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) } }
        }
    }
}
