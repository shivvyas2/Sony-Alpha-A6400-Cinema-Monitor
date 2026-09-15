import SwiftUI
import SonyCameraKit
import CinemaUI

@main
struct CinemaHUDMobileApp: App {
    @State private var session = CameraSession()
    @State private var overlays = OverlaySettings()

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(session)
                .environment(overlays)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// Routes between the connect screen and the monitor / photo views; follows the camera's dial like the Mac app.
struct MobileRootView: View {
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
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: session.state.shootMode, initial: true) { _, dial in overlays.modeResolver.dial(dial) }
        .task {
            // Simulator convenience: CINEMAHUD_ADDRESS=127.0.0.1:8080 auto-connects to tools/camerasim.py on the Mac.
            if let addr = ProcessInfo.processInfo.environment["CINEMAHUD_ADDRESS"], session.phase == .idle {
                await session.connect(toAddress: addr)
            } else if let b = ProcessInfo.processInfo.environment["CINEMAHUD_BRIDGE"], let url = URL(string: b), session.phase == .idle {
                await session.connectBridge(url: url)
            }
        }
    }
}
