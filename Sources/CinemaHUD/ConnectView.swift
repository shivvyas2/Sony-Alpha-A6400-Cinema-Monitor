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

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("USB").font(Theme.label(11)).tracking(3).foregroundStyle(Theme.amber)
                    step(1, "On the camera: MENU → Setup → USB Connection → PC Remote.")
                    step(2, "Connect the USB cable, then click Connect USB.")
                    Button {
                        Task { await session.connectUSB() }
                    } label: {
                        Label("Connect USB", systemImage: "cable.connector").frame(width: 150)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.amber).foregroundStyle(.black)
                    .disabled(isBusy)
                    Text("Lowest latency. Stills save to ~/Pictures/CinemaHUD when the camera's save destination is PC.")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
                .frame(width: 300, alignment: .leading)
                .padding(18)
                .hudPanel()

                VStack(alignment: .leading, spacing: 12) {
                    Text("WI-FI").font(Theme.label(11)).tracking(3).foregroundStyle(Theme.amber)
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
