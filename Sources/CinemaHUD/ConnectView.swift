import SwiftUI
import SonyCameraKit

struct ConnectView: View {
    @Environment(CameraSession.self) private var session
    @State private var address = ""
    @AppStorage("lastAddress") private var lastAddress = ""

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("CINEMA HUD").font(Theme.mono(28, weight: .bold)).tracking(8).foregroundStyle(Theme.amber)
                Text("SONY α6400 REMOTE MONITOR").font(Theme.label(11)).tracking(3).foregroundStyle(Theme.dim)
            }

            VStack(alignment: .leading, spacing: 10) {
                step(1, "On the camera: MENU → Network → Ctrl w/ Smartphone → On, then Connection.")
                step(2, "On this Mac: join the Wi-Fi named DIRECT-xxxx:ILCE-6400 (password shown on the camera).")
                step(3, "Click Discover. If discovery fails, enter the address manually (default 192.168.122.1:8080).")
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(18)
            .hudPanel()

            HStack(spacing: 12) {
                Button {
                    Task { await session.discoverAndConnect() }
                } label: {
                    Label("Discover", systemImage: "dot.radiowaves.left.and.right").frame(width: 130)
                }
                .buttonStyle(.borderedProminent).tint(Theme.amber).foregroundStyle(.black)
                .disabled(isBusy)

                TextField("192.168.122.1:8080", text: $address)
                    .textFieldStyle(.roundedBorder).font(Theme.mono(13)).frame(width: 220)
                    .onSubmit { connectManual() }
                Button("Connect") { connectManual() }.disabled(isBusy || address.isEmpty)
            }

            statusLine
        }
        .padding(40)
        .onAppear { if address.isEmpty { address = lastAddress } }
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
        case .live: Text("Connected").foregroundStyle(Theme.focusOK)
        case .failed(let msg): Text(msg).foregroundStyle(Theme.rec).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(Theme.mono(12, weight: .bold)).foregroundStyle(.black)
                .frame(width: 20, height: 20).background(Theme.amber, in: Circle())
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
        }
    }
}
