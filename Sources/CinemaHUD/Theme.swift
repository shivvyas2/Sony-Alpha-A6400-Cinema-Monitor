import SwiftUI

/// Monochrome monitor palette. Color is reserved for state: red = recording, green = confirmed,
/// amber = warning / enhanced. Everything else is white on black.
enum Theme {
    static let field = Color.black
    static let panel = Color(red: 0.075, green: 0.078, blue: 0.082)
    static let panelLine = Color(red: 0.19, green: 0.20, blue: 0.21)
    static let text = Color(red: 0.95, green: 0.95, blue: 0.95)
    static let dim = Color(red: 0.58, green: 0.60, blue: 0.62)
    static let faint = Color(red: 0.36, green: 0.37, blue: 0.39)
    static let rec = Color(red: 0.90, green: 0.13, blue: 0.16)
    static let ok = Color(red: 0.31, green: 0.78, blue: 0.42)
    static let warn = Color(red: 0.96, green: 0.70, blue: 0.20)
    static let selection = Color.white

    // Backwards-compatible names used across views.
    static let amber = warn
    static let focusOK = ok

    /// Big readout numerals: tabular so values don't jitter as they change.
    static func value(_ size: CGFloat = 28, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
    /// Secondary numerals (timecode, sub-values).
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
    /// Tiny tracked labels above readouts, the camera-body vernacular.
    static func label(_ size: CGFloat = 9.5) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
}

extension View {
    /// Flat monitor panel: near-black fill with a one-pixel edge, square corners.
    func hudPanel(_ radius: CGFloat = 2) -> some View {
        self.background(Theme.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.panelLine, lineWidth: 1))
    }
}
