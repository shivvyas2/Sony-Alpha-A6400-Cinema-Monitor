import SwiftUI

enum Theme {
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.16)
    static let rec = Color(red: 1.0, green: 0.2, blue: 0.2)
    static let dim = Color.white.opacity(0.55)
    static let panel = Color.black.opacity(0.55)
    static let focusOK = Color(red: 0.35, green: 1.0, blue: 0.5)

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func label(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
}

extension View {
    func hudPanel(_ radius: CGFloat = 6) -> some View {
        self.background(Theme.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(.white.opacity(0.08)))
    }
}
