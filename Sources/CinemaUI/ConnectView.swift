import SwiftUI
import SonyCameraKit
import CinemaAudio
#if os(macOS)
import AppKit
#endif

public struct ConnectView: View {
    public init() {}
    @Environment(CameraSession.self) private var session
    @State private var address = ""
    @AppStorage("lastAddress") private var lastAddress = ""
    @State private var bridgeHosts: [BridgeHost] = []
    @State private var bridgeAddress = ""
    @AppStorage("lastBridge") private var lastBridge = ""
    @State private var discovery = BridgeDiscovery()

    public var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("CINEMA HUD").font(.system(size: 30, weight: .bold)).tracking(10).foregroundStyle(Theme.text)
                Text("Remote monitor for the Sony α6400").font(.system(size: 13)).foregroundStyle(Theme.dim)
            }

            AdaptiveStack(spacing: 16) {
                #if !os(macOS)
                VStack(alignment: .leading, spacing: 12) {
                    Text("MAC BRIDGE").font(Theme.label(11)).tracking(3).foregroundStyle(Theme.text)
                    Text("Connect the camera to a Mac running CinemaHUD by USB; the Mac shares it here over Wi-Fi with the same picture and controls.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                    if bridgeHosts.isEmpty {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for Macs on this network…").font(.system(size: 12)).foregroundStyle(Theme.dim) }
                    }
                    ForEach(bridgeHosts) { host in
                        Button {
                            Task {
                                if let url = try? await BridgeDiscovery.resolve(host) { lastBridge = url.absoluteString; await session.connectBridge(url: url) }
                            }
                        } label: {
                            Label(host.name, systemImage: "desktopcomputer").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.selection).foregroundStyle(.black).disabled(isBusy)
                    }
                    HStack(spacing: 8) {
                        TextField("mac-name.local:8899", text: $bridgeAddress)
                            .textFieldStyle(.roundedBorder).font(Theme.mono(12)).frame(maxWidth: 220)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Connect") { connectBridgeManual() }.disabled(isBusy || bridgeAddress.isEmpty)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(18)
                .hudPanel()
                #endif
                #if os(macOS)
                VStack(alignment: .leading, spacing: 12) {
                    Text("USB").font(Theme.label(11)).tracking(3).foregroundStyle(Theme.text)
                    step(1, "On the camera: MENU → Setup → USB Connection → PC Remote.")
                    step(2, "Connect the USB cable, then click Connect USB.")
                    Button {
                        Task { await session.connectUSB() }
                    } label: {
                        Label("Connect USB", systemImage: "cable.connector").frame(width: 150)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.selection).foregroundStyle(.black)
                    .disabled(isBusy)
                    Text("Lowest latency. Stills save to ~/Pictures/CinemaHUD when the camera's save destination is PC.")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
                .frame(width: 300, alignment: .leading)
                .padding(18)
                .hudPanel()
                #endif

                VStack(alignment: .leading, spacing: 12) {
                    Text("WI-FI").font(Theme.label(11)).tracking(3).foregroundStyle(Theme.text)
                    step(1, "On the camera: MENU → Network → Ctrl w/ Smartphone → On, then Connection.")
                    step(2, "On this Mac: join the Wi-Fi named DIRECT-xxxx:ILCE-6400.")
                    HStack(spacing: 8) {
                        Button {
                            Task { await session.discoverAndConnect() }
                        } label: {
                            Label("Discover", systemImage: "dot.radiowaves.left.and.right").frame(width: 110)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                        TextField("192.168.122.1:8080", text: $address)
                            .textFieldStyle(.roundedBorder).font(Theme.mono(12)).frame(width: 160)
                            .onSubmit { connectManual() }
                        Button("Connect") { connectManual() }.disabled(isBusy || address.isEmpty)
                    }
                    Text("Wireless, plus touch-to-focus. Same live view size as USB.")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
                .frame(width: 400, alignment: .leading)
                .padding(18)
                .hudPanel()
            }

            #if os(macOS)
            SyncTakesCard()
            #endif

            statusLine
        }
        .padding(40)
        .onAppear { if address.isEmpty { address = lastAddress }; if bridgeAddress.isEmpty { bridgeAddress = lastBridge } }
        .task {
            #if !os(macOS)
            for await hosts in discovery.hosts() { bridgeHosts = hosts }
            #endif
        }
    }

    private func connectBridgeManual() {
        var s = bridgeAddress.trimmingCharacters(in: .whitespaces)
        if !s.hasPrefix("http") { s = "http://" + s }
        if !s.dropFirst(7).contains(":") { s += ":\(Bridge.defaultPort)" }
        guard let url = URL(string: s) else { return }
        lastBridge = url.absoluteString
        Task { await session.connectBridge(url: url) }
    }

    private var isBusy: Bool {
        switch session.phase { case .discovering, .connecting: return true; default: return false }
    }

    private func connectManual() {
        lastAddress = address
        Task { await session.connect(toAddress: address) }
    }

    @ViewBuilder private var statusLine: some View {
        switch session.phase {
        case .idle: Text("Not connected").foregroundStyle(Theme.dim)
        case .discovering: HStack { ProgressView().controlSize(.small); Text("Searching for camera…") }.foregroundStyle(Theme.dim)
        case .connecting(let name): HStack { ProgressView().controlSize(.small); Text("Connecting to \(name)…") }.foregroundStyle(Theme.dim)
        case .live: Text("Connected").foregroundStyle(Theme.ok)
        case .failed(let msg): Text(msg).foregroundStyle(Theme.rec).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        #if os(macOS)
        if session.bridgeActive {
            Text("Sharing to iPhone / iPad on this network (port \(session.bridgePort))").font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
        #endif
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(Theme.mono(12, weight: .bold)).foregroundStyle(.black)
                .frame(width: 20, height: 20).background(Theme.selection, in: Circle())
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
        }
    }
}


#if os(macOS)
/// The post-shoot half of the app, on the launch screen. Sync Takes used to be reachable only from the
/// Audio menu, so someone who had just finished a shoot had no way to discover it from here.
struct SyncTakesCard: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AudioSessionController.self) private var audio: AudioSessionController?
    @State private var takeCount = 0

    private var dayFolder: URL { audio?.dayFolder ?? DayFolder.url(for: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("AFTER THE SHOOT").font(Theme.label(11)).tracking(3).foregroundStyle(Theme.text)
                Spacer()
                Text(takeCount == 0 ? "No takes recorded today" : "\(takeCount) take\(takeCount == 1 ? "" : "s") recorded today")
                    .font(.system(size: 11)).foregroundStyle(takeCount == 0 ? Theme.dim : Theme.ok)
            }

            Text("CinemaHUD records a WAV for every take. Sync Takes lines them up with the camera's clips and writes a Final Cut XML.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            AdaptiveStack(spacing: 20) {
                syncStep(1, "Copy the card's clips to this Mac.")
                syncStep(2, "Drop them on Sync Takes, then Sync All.")
                syncStep(3, "Export, then File ▸ Import ▸ XML in Final Cut Pro.")
            }

            HStack(spacing: 10) {
                Button { openWindow(id: "sync-takes") } label: {
                    Label("Sync Takes…", systemImage: "waveform.badge.plus").frame(width: 150)
                }
                .buttonStyle(.borderedProminent).tint(Theme.selection).foregroundStyle(.black)

                Button("Show Audio Folder") {
                    try? FileManager.default.createDirectory(at: dayFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dayFolder])
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 12)

                Text(dayFolder.path).font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    .lineLimit(1).truncationMode(.head)
            }
        }
        .frame(maxWidth: 752, alignment: .leading)   // (300 + 36) + (400 + 36) + 16 spacing, less this panel's own padding
        .padding(18)
        .hudPanel()
        .onAppear { countTakes() }
    }

    /// Only takes that finished cleanly can be paired, so those are the ones worth counting.
    private func countTakes() {
        takeCount = TakeLog.load(from: dayFolder).takes.filter { $0.outcome == .complete }.count
    }

    private func syncStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(Theme.mono(10, weight: .bold)).foregroundStyle(Theme.dim)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Theme.dim.opacity(0.6), lineWidth: 1))
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 230, alignment: .leading)
    }
}
#endif

/// Side by side when there is room, stacked on narrow screens (iPhone).
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: spacing) { content }
            VStack(alignment: .leading, spacing: spacing) { content }
        }
    }
}
