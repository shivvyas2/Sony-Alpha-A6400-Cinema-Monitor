import SwiftUI
import SonyCameraKit

/// One or two advisory rows over the picture. A row with a fix is a button that applies it.
struct AssistStrip: View {
    @Environment(CameraSession.self) private var session
    @Environment(OverlaySettings.self) private var overlays
    let controller: AssistController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(controller.lines) { line in
                let fix = controller.fix(for: line.id)
                let severity = controller.severity(for: line.id)
                Button { if fix != nil { controller.apply(line.id, session: session, rotation: overlays.rotation, monitor: overlays) } } label: {
                    HStack(spacing: 6) {
                        if line.fromModel {
                            Text("AI").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(Color.black)
                                .padding(.horizontal, 3).padding(.vertical, 1).background(Theme.dim, in: RoundedRectangle(cornerRadius: 2))
                        }
                        Text(line.text).font(Theme.label(10)).tracking(1.2).foregroundStyle(severity == .warn ? Theme.warn : Theme.dim)
                        if controller.applied == line.id {
                            Text("· APPLIED").font(Theme.label(10)).tracking(1.2).foregroundStyle(Theme.ok)
                        } else if let fix {
                            Text("· \(fix.label) ↵").font(Theme.label(10)).tracking(1.2).foregroundStyle(Theme.text)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(fix == nil)
            }
        }
        .animation(.easeOut(duration: 0.2), value: controller.lines)
    }
}
