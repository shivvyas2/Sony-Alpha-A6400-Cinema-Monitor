import SwiftUI
import SonyCameraKit

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
