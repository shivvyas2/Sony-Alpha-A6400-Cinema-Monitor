import SwiftUI
import CoreGraphics
import SonyCameraKit

/// Aspect crop applied to the live view. Cropping to a cinema ratio lets the frame fill an
/// ultrawide (21:9) monitor edge to edge instead of letterboxing a 3:2 or 16:9 feed.
public enum CropRatio: String, CaseIterable, Identifiable {
    case native, r16x9, r185, r200, r235, r239, r1x1, r4x5, r9x16
    public var id: String { rawValue }
    public var value: Double? {
        switch self {
        case .native: return nil
        case .r16x9: return 16.0 / 9.0
        case .r185: return 1.85
        case .r200: return 2.0
        case .r235: return 2.35
        case .r239: return 2.39
        case .r1x1: return 1.0
        case .r4x5: return 0.8
        case .r9x16: return 9.0 / 16.0
        }
    }
    public var label: String {
        switch self {
        case .native: return "NATIVE"
        case .r16x9: return "16:9"
        case .r185: return "1.85"
        case .r200: return "2.00"
        case .r235: return "2.35"
        case .r239: return "2.39"
        case .r1x1: return "1:1"
        case .r4x5: return "4:5"
        case .r9x16: return "9:16"
        }
    }
    public var menuTitle: String {
        switch self {
        case .native: return "Native (no crop)"
        case .r16x9: return "16:9"
        case .r185: return "1.85:1 Flat"
        case .r200: return "2.00:1 Univisium"
        case .r235: return "2.35:1 Scope"
        case .r239: return "2.39:1 Scope"
        case .r1x1: return "1:1 Square (feed)"
        case .r4x5: return "4:5 Portrait (feed)"
        case .r9x16: return "9:16 Vertical (Reels / Stories / TikTok)"
        }
    }
    public var next: CropRatio { let all = Self.allCases; return all[(all.firstIndex(of: self)! + 1) % all.count] }
}

@Observable
public final class OverlaySettings {
    public init() {}
    public var grid = true
    public var frameGuides = false
    public var centerMarker = true
    public var peaking = false
    public var zebra = false
    public var hideHUD = false
    public var zebraLevel: Double = 0.95
    public var crop: CropRatio = .native
    /// MetalFX spatial upscaling of the live view to the display resolution.
    public var enhanced = false
    /// Optional detail-recovery sharpening after upscaling (off = faithful).
    public var detail = false
    /// How the camera's feed is interpreted before macOS converts it to the display's own profile.
    public var feedColorSpace: FeedColorSpace = .sRGB
    public var falseColor = false
    public var waveform = false
    /// Project frame rate, used for shutter angle and the timecode frame counter.
    public var projectFPS = 24
    /// Picture profile set on the camera body (declared here so LOG/709 can apply the right conversion).
    public var profile: PictureProfile = .standard
    /// Apply the display LUT (709 view) instead of showing the log feed.
    public var lutOn = true
    public var customLUT: (data: Data, dimension: Int)?
    public var customLUTName: String?
    public var scope: ScopeKind = .none
    /// 2× centre magnification for focus checks.
    public var magnify = false
    public var showMenu = false
    public var cameraIndex = "A"
    public var reel = 1
    /// Display rotation in degrees for a camera mounted sideways (vertical shooting).
    public var rotation = 0
    public var modeResolver = ShootingModeResolver()
    public var shootingMode: ShootingMode { modeResolver.mode }
    public var reviewShowsRAW = false
    /// Guides (mobile guides sheet; the Mac keeps its own defaults).
    public var guideRatio: FrameGuideRatio = .r239
    public var safeAreas = false
    public var diagonals = false
    public var peakingColor: PeakingColor = .red
    public var showSharpnessMeter = true
    /// Display-only mist look (0 off, 0.5 MIST1, 1 MIST2): highlights halo and skin softens on the
    /// monitor; the camera records clean. Remembered across launches.
    public var mist: Double = UserDefaults.standard.double(forKey: "mist") {
        didSet { UserDefaults.standard.set(mist, forKey: "mist") }
    }
    /// Shot assist advisories over the picture (Mac video monitor). Remembered across launches.
    public var assist: Bool = UserDefaults.standard.object(forKey: "assist") as? Bool ?? true {
        didSet { UserDefaults.standard.set(assist, forKey: "assist") }
    }

    /// The LUT that should be applied to the feed right now, if any.
    public var activeLUT: (data: Data, dimension: Int)? {
        guard lutOn else { return nil }
        if let customLUT { return customLUT }
        if let d = LUTBuilder.cube(for: profile) { return (d, LUTBuilder.dimension) }
        return nil
    }
}

/// Colour interpretation of the live view. The pixel values never change; the tag tells macOS which
/// transfer curve and primaries they are in, and macOS converts to the connected display's ICC profile.
public enum FeedColorSpace: String, CaseIterable, Identifiable {
    case sRGB = "sRGB (camera JPEG, matches the camera's screen)"
    case rec709 = "Rec.709 video (BT.1886 gamma, grading-monitor look)"
    public var id: String { rawValue }
    public var short: String { self == .sRGB ? "sRGB" : "709" }
    public var cgColorSpace: CGColorSpace {
        self == .sRGB ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpace(name: CGColorSpace.itur_709)!
    }
}

public enum ScopeKind: String, CaseIterable, Identifiable {
    case none = "OFF", waveform = "WFM", parade = "RGB", histogram = "HIST", vector = "VEC"
    public var id: String { rawValue }
    public var next: ScopeKind { let a = Self.allCases; return a[(a.firstIndex(of: self)! + 1) % a.count] }
    public var title: String {
        switch self { case .none: return "Off"; case .waveform: return "Luma waveform"; case .parade: return "RGB parade"; case .histogram: return "RGB histogram"; case .vector: return "Vectorscope" }
    }
}

