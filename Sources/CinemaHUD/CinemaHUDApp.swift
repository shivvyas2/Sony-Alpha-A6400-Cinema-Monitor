import SwiftUI
import AppKit
import SonyCameraKit
import UniformTypeIdentifiers

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
                Button(session.reviewShot != nil && overlays.shootingMode == .photo ? "Toggle RAW / JPEG" : (session.state.isRecording ? "Stop Recording" : "Start Recording")) {
                    if session.reviewShot != nil && overlays.shootingMode == .photo { overlays.reviewShowsRAW.toggle() }
                    else { Task { await session.toggleRecording() } }
                }
                .keyboardShortcut("r", modifiers: [])
                Divider()
                Button("Disconnect") { session.disconnect() }.keyboardShortcut("d", modifiers: [.command])
                Divider()
                Button(overlays.shootingMode == .photo ? "Switch to Video Mode" : "Switch to Photo Mode") { overlays.modeResolver.toggle() }
                    .keyboardShortcut(.tab, modifiers: [])
                Button("Leave Review") { session.review(nil) }.keyboardShortcut(.escape, modifiers: []).disabled(session.reviewShot == nil)
                Button("Previous Shot") { if session.reviewShot == nil, let last = session.captures.last { session.review(last) } else { session.reviewNeighbor(-1) } }
                    .keyboardShortcut(.leftArrow, modifiers: []).disabled(session.captures.isEmpty)
                Button("Next Shot") { session.reviewNeighbor(1) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(session.reviewShot == nil)
            }
            CommandMenu("Aspect") {
                ForEach(Array(CropRatio.allCases.enumerated()), id: \.element) { i, ratio in
                    Button {
                        overlays.crop = ratio
                    } label: {
                        HStack { Text(ratio.menuTitle); if overlays.crop == ratio { Image(systemName: "checkmark") } }
                    }
                    .keyboardShortcut(KeyEquivalent(Character(i < 9 ? "\(i + 1)" : "0")), modifiers: [])
                }
                Divider()
                Picker("Rotate Display", selection: $overlays.rotation) {
                    Text("0°").tag(0); Text("90° (camera tilted right)").tag(90); Text("270° (camera tilted left)").tag(270)
                }
                Button("Cycle Rotation") { overlays.rotation = (overlays.rotation + 90) % 360; if overlays.rotation == 180 { overlays.rotation = 270 } }.keyboardShortcut("t", modifiers: [])
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
                Toggle("2× Magnify", isOn: $overlays.magnify).keyboardShortcut("x", modifiers: [])
                Picker("Scope", selection: $overlays.scope) {
                    ForEach(ScopeKind.allCases) { Text($0.title).tag($0) }
                }
                Button("Cycle Scope") { overlays.scope = overlays.scope.next }.keyboardShortcut("w", modifiers: [])
                Divider()
                Picker("Camera Picture Profile", selection: $overlays.profile) {
                    ForEach(PictureProfile.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Apply Display LUT (709 view)", isOn: $overlays.lutOn).keyboardShortcut("l", modifiers: [])
                Button("Load .cube LUT…") { loadLUT() }
                Button("Clear Custom LUT") { overlays.customLUT = nil; overlays.customLUTName = nil }.disabled(overlays.customLUT == nil)
                Divider()
                Toggle("Settings Menu", isOn: $overlays.showMenu).keyboardShortcut("n", modifiers: [])
                Divider()
                Toggle("Enhanced Upscaling (MetalFX)", isOn: $overlays.enhanced).keyboardShortcut("e", modifiers: [])
                Toggle("Detail Recovery (sharpen after upscaling)", isOn: $overlays.detail)
                Picker("Interpret Feed As", selection: $overlays.feedColorSpace) {
                    ForEach(FeedColorSpace.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Smooth Motion (adds one frame of delay)", selection: Binding(get: { session.motionFactor }, set: { session.motionFactor = $0 })) {
                    Text("Off").tag(1); Text("×2 (30 fps)").tag(2); Text("×4 (60 fps)").tag(4); Text("×8 (120 fps)").tag(8)
                }
                Button("Cycle Smooth Motion") { session.motionFactor = [1: 2, 2: 4, 4: 8][session.motionFactor] ?? 1 }.keyboardShortcut("m", modifiers: [])
                Picker("Live Denoise", selection: Binding(get: { session.denoise }, set: { session.denoise = $0 })) {
                    Text("Off").tag(Float(0)); Text("NR1 (light)").tag(Float(0.5)); Text("NR2 (strong)").tag(Float(1))
                }
                Button("Cycle Live Denoise") { session.denoise = session.denoise == 0 ? 0.5 : (session.denoise > 0.6 ? 0 : 1) }.keyboardShortcut("d", modifiers: [])
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
    case native, r16x9, r185, r200, r235, r239, r1x1, r4x5, r9x16
    var id: String { rawValue }
    var value: Double? {
        switch self {
        case .native: return nil
        case .r16x9: return 16.0 / 9.0
        case .r185: return 1.85
        case .r200: return 2.0
        case .r235: return 2.35
        case .r239: return 2.39
        case .r1x1: return 1.0
        case .r4x5: return 0.8
        case .r9x16: return 9.0 / 16.0
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
        case .r1x1: return "1:1"
        case .r4x5: return "4:5"
        case .r9x16: return "9:16"
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
        case .r1x1: return "1:1 Square (feed)"
        case .r4x5: return "4:5 Portrait (feed)"
        case .r9x16: return "9:16 Vertical (Reels / Stories / TikTok)"
        }
    }
    var next: CropRatio { let all = Self.allCases; return all[(all.firstIndex(of: self)! + 1) % all.count] }
}

extension CinemaHUDApp {
    func loadLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "cube")!]
        panel.title = "Choose a .cube LUT"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let (data, n) = try LUTBuilder.loadCube(url)
                overlays.customLUT = (data, n)
                overlays.customLUTName = url.deletingPathExtension().lastPathComponent
                overlays.lutOn = true
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
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
    /// Optional detail-recovery sharpening after upscaling (off = faithful).
    var detail = false
    /// How the camera's feed is interpreted before macOS converts it to the display's own profile.
    var feedColorSpace: FeedColorSpace = .sRGB
    var falseColor = false
    var waveform = false
    /// Project frame rate, used for shutter angle and the timecode frame counter.
    var projectFPS = 24
    /// Picture profile set on the camera body (declared here so LOG/709 can apply the right conversion).
    var profile: PictureProfile = .standard
    /// Apply the display LUT (709 view) instead of showing the log feed.
    var lutOn = true
    var customLUT: (data: Data, dimension: Int)?
    var customLUTName: String?
    var scope: ScopeKind = .none
    /// 2× centre magnification for focus checks.
    var magnify = false
    var showMenu = false
    var cameraIndex = "A"
    var reel = 1
    /// Display rotation in degrees for a camera mounted sideways (vertical shooting).
    var rotation = 0
    var modeResolver = ShootingModeResolver()
    var shootingMode: ShootingMode { modeResolver.mode }
    var reviewShowsRAW = false

    /// The LUT that should be applied to the feed right now, if any.
    var activeLUT: (data: Data, dimension: Int)? {
        guard lutOn else { return nil }
        if let customLUT { return customLUT }
        if let d = LUTBuilder.cube(for: profile) { return (d, LUTBuilder.dimension) }
        return nil
    }
}

/// Colour interpretation of the live view. The pixel values never change; the tag tells macOS which
/// transfer curve and primaries they are in, and macOS converts to the connected display's ICC profile.
enum FeedColorSpace: String, CaseIterable, Identifiable {
    case sRGB = "sRGB (camera JPEG, matches the camera's screen)"
    case rec709 = "Rec.709 video (BT.1886 gamma, grading-monitor look)"
    var id: String { rawValue }
    var short: String { self == .sRGB ? "sRGB" : "709" }
    var cgColorSpace: CGColorSpace {
        self == .sRGB ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpace(name: CGColorSpace.itur_709)!
    }
}

enum ScopeKind: String, CaseIterable, Identifiable {
    case none = "OFF", waveform = "WFM", parade = "RGB", histogram = "HIST", vector = "VEC"
    var id: String { rawValue }
    var next: ScopeKind { let a = Self.allCases; return a[(a.firstIndex(of: self)! + 1) % a.count] }
    var title: String {
        switch self { case .none: return "Off"; case .waveform: return "Luma waveform"; case .parade: return "RGB parade"; case .histogram: return "RGB histogram"; case .vector: return "Vectorscope" }
    }
}

struct ContentView: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if session.phase.isConnected {
                if overlays.shootingMode == .photo { PhotoView() } else { MonitorView() }
            } else {
                ConnectView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("CinemaHUD.devReport"))) { _ in
            print(String(format: "report: display=%.1f fps source=%.1f fps motion=x%d nr=%.1f size=%.0fx%.0f", session.fps, session.sourceFPS, session.motionFactor, session.denoise, session.frameSize.width, session.frameSize.height))
            fflush(stdout)
        }
        .onChange(of: session.state.shootMode, initial: true) { _, dial in overlays.modeResolver.dial(dial) }
        .task {
            // Dev convenience: CINEMAHUD_ADDRESS=127.0.0.1:8080 auto-connects (e.g. to tools/camerasim.py).
            DevHooks.apply(to: overlays)
            if let ov = ProcessInfo.processInfo.environment["CINEMAHUD_OVERLAYS"] {
                if ov.contains("motion8") { session.motionFactor = 8 } else if ov.contains("motion4") { session.motionFactor = 4 } else if ov.contains("motion") { session.motionFactor = 2 }
                if ov.contains("nr2") { session.denoise = 1 } else if ov.contains("nr") { session.denoise = 0.5 }
            }
            if let addr = ProcessInfo.processInfo.environment["CINEMAHUD_ADDRESS"], session.phase == .idle {
                await session.connect(toAddress: addr)
            } else if ProcessInfo.processInfo.environment["CINEMAHUD_USB"] == "1", session.phase == .idle {
                await session.connectUSB()
            }
            // Dev: exercise the same calls the strip readouts make, then print the resulting state.
            if let actions = ProcessInfo.processInfo.environment["CINEMAHUD_ACTION"], session.phase.isConnected {
                for a in actions.split(separator: ";") {
                    let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { continue }
                    let t0 = Date()
                    switch kv[0] {
                    case "shutter": await session.setShutterSpeed(kv[1])
                    case "iris": await session.setFNumber(kv[1])
                    case "iso": await session.setISO(kv[1])
                    case "ev": await session.setExposureCompensation(index: Int(kv[1]) ?? 0)
                    case "shoot": await session.takePicture()
                    default: break
                    }
                    try? await Task.sleep(for: .milliseconds(600))
                    print(String(format: "action %@=%@ -> shutter=%@ iris=%@ iso=%@ ev=%@ err=%@ (%.1fs)", kv[0], kv[1],
                                 session.state.shutterSpeed ?? "-", session.state.fNumber ?? "-", session.state.iso ?? "-",
                                 session.state.exposureCompensation?.label ?? "-", session.lastError ?? "none", Date().timeIntervalSince(t0)))
                    fflush(stdout)
                }
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
            case "detail": overlays.detail = true
            case "rec709": overlays.feedColorSpace = .rec709
            case "false": overlays.falseColor = true
            case "waveform": overlays.scope = .waveform
            case "parade": overlays.scope = .parade
            case "hist": overlays.scope = .histogram
            case "vector": overlays.scope = .vector
            case "photo": overlays.modeResolver.toggle()
            case "menu": overlays.showMenu = true
            case "magnify": overlays.magnify = true
            case "rot90": overlays.rotation = 90
            case "slog3": overlays.profile = .pp8
            case "log": overlays.lutOn = false
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
