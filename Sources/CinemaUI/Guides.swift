import SwiftUI

/// Frame-line ratios for the guides overlay. Wider than 3:2 draws top/bottom lines; narrower draws side lines.
public enum FrameGuideRatio: String, CaseIterable, Identifiable, Sendable {
    case r185 = "1.85", r200 = "2.00", r235 = "2.35", r239 = "2.39", r43 = "4:3", r11 = "1:1", r916 = "9:16"
    public var id: String { rawValue }
    public var label: String { rawValue }
    public var value: CGFloat {
        switch self {
        case .r185: return 1.85
        case .r200: return 2.0
        case .r235: return 2.35
        case .r239: return 2.39
        case .r43: return 4.0 / 3.0
        case .r11: return 1
        case .r916: return 9.0 / 16.0
        }
    }
}

/// Focus peaking tint.
public enum PeakingColor: String, CaseIterable, Identifiable, Sendable {
    case red = "Red", yellow = "Yellow", white = "White", blue = "Blue"
    public var id: String { rawValue }
    public var rgb: (Double, Double, Double) {
        switch self {
        case .red: return (1, 0.15, 0.1)
        case .yellow: return (1, 0.9, 0.1)
        case .white: return (1, 1, 1)
        case .blue: return (0.2, 0.5, 1)
        }
    }
    public var color: Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2) }
}
