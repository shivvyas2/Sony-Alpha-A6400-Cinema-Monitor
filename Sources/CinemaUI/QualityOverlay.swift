import SwiftUI
import SonyCameraKit

/// BLUR / EXPOSURE / GRAIN of a shot as one strip over the picture, in the monitor's label-and-value idiom.
struct QualityOverlay: View {
    let quality: ShotQuality?
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 10 : 16) {
            if let q = quality {
                item("BLUR", q.blur.rawValue, q.blurLevel)
                item("EXPOSURE", q.exposureText, q.exposureLevel)
                item("GRAIN", q.grain.rawValue, q.grainLevel)
            } else {
                ProgressView().controlSize(.mini)
                Text("CHECKING").font(Theme.label(9)).tracking(1.2).foregroundStyle(Theme.dim)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 10).frame(height: compact ? 26 : 30)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func item(_ label: String, _ value: String, _ level: ShotQuality.Level) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label).font(Theme.label(compact ? 8 : 9)).tracking(1).foregroundStyle(Theme.dim)
            Text(value).font(Theme.strip(compact ? 13 : 15)).foregroundStyle(Self.color(level))
        }
    }

    static func color(_ level: ShotQuality.Level) -> Color {
        switch level { case .good: return Theme.ok; case .caution: return Theme.warn; case .bad: return Theme.rec; case .unknown: return Theme.dim }
    }
}
