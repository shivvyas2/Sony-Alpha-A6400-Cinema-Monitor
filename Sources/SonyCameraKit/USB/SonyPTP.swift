import Foundation

/// Sony vendor property codes (PTP over USB, "PC Remote" mode).
public enum SonyProp {
    public static let whiteBalance: UInt16 = 0x5005
    public static let fNumber: UInt16 = 0x5007
    public static let focusMode: UInt16 = 0x500A
    public static let exposureMeteringMode: UInt16 = 0x500B
    public static let exposureProgramMode: UInt16 = 0x500E
    public static let exposureBias: UInt16 = 0x5010
    public static let stillCaptureMode: UInt16 = 0x5013
    public static let dRangeOptimize: UInt16 = 0xD201
    public static let imageSize: UInt16 = 0xD203
    public static let shutterSpeed: UInt16 = 0xD20D
    public static let colorTemperature: UInt16 = 0xD20F
    public static let ccFilter: UInt16 = 0xD210
    public static let abFilter: UInt16 = 0xD21C
    public static let zoom: UInt16 = 0xD214          // focal length × 1,000,000 on bodies that report it
    public static let aelButton: UInt16 = 0xD2C3
    public static let felButton: UInt16 = 0xD2C5
    public static let oneShotButton: UInt16 = 0xD2C7
    public static let aspectRatio: UInt16 = 0xD211
    public static let focusFound: UInt16 = 0xD213
    public static let objectInMemory: UInt16 = 0xD215
    public static let exposeIndex: UInt16 = 0xD216
    public static let batteryLevel: UInt16 = 0xD218
    public static let pictureEffect: UInt16 = 0xD21B
    public static let iso: UInt16 = 0xD21E
    public static let movieRecordingState: UInt16 = 0xD21D
    public static let liveViewStatus: UInt16 = 0xD221
    public static let priorityMode: UInt16 = 0xD25A
    // "Control" codes used with SetControlDeviceB (button presses)
    public static let autoFocusButton: UInt16 = 0xD2C1
    public static let captureButton: UInt16 = 0xD2C2
    public static let movieButton: UInt16 = 0xD2C8
    public static let nearFar: UInt16 = 0xD2D1

    public static let liveviewObjectHandle: UInt32 = 0xFFFF_C002
    public static let capturedImageHandle: UInt32 = 0xFFFF_C001

    public static func name(_ code: UInt16) -> String {
        switch code {
        case whiteBalance: return "WhiteBalance"
        case fNumber: return "FNumber"
        case focusMode: return "FocusMode"
        case exposureMeteringMode: return "MeteringMode"
        case exposureProgramMode: return "ExposureProgram"
        case exposureBias: return "ExposureBias"
        case stillCaptureMode: return "StillCaptureMode"
        case dRangeOptimize: return "DRO"
        case imageSize: return "ImageSize"
        case shutterSpeed: return "ShutterSpeed"
        case colorTemperature: return "ColorTemperature"
        case aspectRatio: return "AspectRatio"
        case focusFound: return "FocusFound"
        case objectInMemory: return "ObjectInMemory"
        case exposeIndex: return "ExposeIndex"
        case batteryLevel: return "BatteryLevel"
        case pictureEffect: return "PictureEffect"
        case iso: return "ISO"
        case liveViewStatus: return "LiveViewStatus"
        case movieRecordingState: return "MovieRecordingState"
        case priorityMode: return "PriorityMode"
        case autoFocusButton: return "AutoFocusButton"
        case captureButton: return "CaptureButton"
        case movieButton: return "MovieButton"
        case nearFar: return "NearFar"
        default: return String(format: "0x%04X", code)
        }
    }
}

/// One entry from Sony's GetAllDevicePropData blob.
public struct SonyPropDesc: Sendable, Equatable {
    public var code: UInt16
    public var type: PTP.DataType
    public var getSet: UInt8
    public var isEnabled: UInt8      // 0 = disabled, 1 = enabled (settable), 2 = display only
    public var current: Int64
    public var formFlag: UInt8       // 0 none, 1 range, 2 enum
    public var rangeMin: Int64 = 0, rangeMax: Int64 = 0, rangeStep: Int64 = 0
    public var enumValues: [Int64] = []       // currently selectable values
    public var enumAllValues: [Int64] = []    // second list (all values), when present
    public var settable: Bool { isEnabled == 1 }

    /// Parses the payload of GetAllDevicePropData (0x9209): u64 count then packed descriptors.
    public static func parseAll(_ data: Data) throws -> [SonyPropDesc] {
        var rd = PTPReader(data)
        let count = Int(try rd.u64())
        var out: [SonyPropDesc] = []
        while !rd.atEnd && out.count < max(count, 1) + 64 {
            guard let d = try? parseOne(&rd) else { break }
            out.append(d)
        }
        return out
    }

    static func parseOne(_ rd: inout PTPReader) throws -> SonyPropDesc {
        let code = try rd.u16()
        let rawType = try rd.u16()
        guard let type = PTP.DataType(rawValue: rawType) else { throw PTPParseError() }
        let getSet = try rd.u8()
        let isEnabled = try rd.u8()
        _ = try rd.value(of: type)                       // factory default
        let current = try rd.value(of: type) ?? 0
        let form = try rd.u8()
        var d = SonyPropDesc(code: code, type: type, getSet: getSet, isEnabled: isEnabled, current: current, formFlag: form)
        switch form {
        case 1:
            d.rangeMin = try rd.value(of: type) ?? 0
            d.rangeMax = try rd.value(of: type) ?? 0
            d.rangeStep = try rd.value(of: type) ?? 0
        case 2:
            d.enumValues = try readEnum(&rd, type: type)
            // Sony appends a second enumeration (all possible values). Only consume it if it parses
            // and what follows still looks like the start of another descriptor (or the end).
            if let n = rd.peek16(), let sz = type.byteSize, Int(n) * sz + 2 <= rd.remaining {
                let save = rd.offset
                if let second = try? readEnum(&rd, type: type), looksLikeDescriptorBoundary(rd) {
                    d.enumAllValues = second
                } else {
                    rd.offset = save
                }
            }
        default: break
        }
        return d
    }

    private static func readEnum(_ rd: inout PTPReader, type: PTP.DataType) throws -> [Int64] {
        let n = Int(try rd.u16())
        var v: [Int64] = []
        v.reserveCapacity(n)
        for _ in 0 ..< n { v.append(try rd.value(of: type) ?? 0) }
        return v
    }

    private static func looksLikeDescriptorBoundary(_ rd: PTPReader) -> Bool {
        if rd.atEnd { return true }
        guard let code = rd.peek16() else { return false }
        return (0x5000 ... 0x5FFF).contains(code) || (0xD000 ... 0xDFFF).contains(code)
    }
}

/// Value ↔ display-string conversions for the Sony properties the HUD shows.
public enum SonyValue {
    /// Shutter speeds in the order the camera's dial walks them (slow → fast), Sony-encoded.
    public static let shutterTable: [Int64] = {
        let pairs: [(Int64, Int64)] = [
            (30, 1), (25, 1), (20, 1), (15, 1), (13, 1), (10, 1), (8, 1), (6, 1), (5, 1), (4, 1), (32, 10), (25, 10),
            (2, 1), (16, 10), (13, 10), (1, 1), (8, 10), (6, 10), (5, 10), (4, 10),
            (1, 3), (1, 4), (1, 5), (1, 6), (1, 8), (1, 10), (1, 13), (1, 15), (1, 20), (1, 25), (1, 30), (1, 40), (1, 50),
            (1, 60), (1, 80), (1, 100), (1, 125), (1, 160), (1, 200), (1, 250), (1, 320), (1, 400), (1, 500), (1, 640),
            (1, 800), (1, 1000), (1, 1250), (1, 1600), (1, 2000), (1, 2500), (1, 3200), (1, 4000),
        ]
        return pairs.map { $0.0 << 16 | $0.1 }
    }()
    /// Extra shutter values the a6400 uses in movie modes (half-stop style); merged into the picker list.
    public static let movieShutterExtras: [Int64] = [(1 << 16) | 45, (1 << 16) | 90, (1 << 16) | 180, (1 << 16) | 350, (1 << 16) | 725, (1 << 16) | 1500, (1 << 16) | 3000]
    /// Exposure time in seconds for a Sony-encoded shutter value (nil for bulb / n.a.).
    public static func shutterSeconds(_ v: Int64) -> Double? {
        if v == 0 || v == 0xFFFF_FFFF { return nil }
        let num = Double((v >> 16) & 0xFFFF), den = Double(v & 0xFFFF)
        return den > 0 ? num / den : nil
    }
    /// Shutter list sorted slow → fast, including movie-mode values.
    public static let fullShutterTable: [Int64] = (shutterTable + movieShutterExtras).sorted { (shutterSeconds($0) ?? 0) > (shutterSeconds($1) ?? 0) }
    /// F-numbers ×100 in third stops. The lens limits the usable range; stepping stops at the ends.
    public static let fNumberTable: [Int64] = [100, 110, 120, 140, 160, 180, 200, 220, 250, 280, 320, 350, 400, 450, 500,
                                               560, 630, 710, 800, 900, 1000, 1100, 1300, 1400, 1600, 1800, 2000, 2200]

    /// Sony reports 0xFFFFFFFF / 0 for "not applicable in this mode".
    public static func shutter(_ v: Int64) -> String {
        if v == 0xFFFF_FFFF { return "--" }
        if v == 0 { return "BULB" }
        let num = Int((v >> 16) & 0xFFFF), den = Int(v & 0xFFFF)
        if den == 0 { return "--" }
        if den == 1 { return "\(num)\"" }
        if num == 1 { return "1/\(den)" }
        if den == 10 { return String(format: "%.1f\"", Double(num) / 10) }
        // e.g. 25/10 handled above; otherwise reduce
        return "\(num)/\(den)"
    }
    public static func fNumber(_ v: Int64) -> String {
        v <= 0 ? "--" : (v % 100 == 0 ? "\(v / 100)" : String(format: "%.1f", Double(v) / 100))
    }
    public static func iso(_ v: Int64) -> String {
        let base = v & 0x00FF_FFFF
        if base == 0 { return "--" }
        if base == 0x00FF_FFFF { return "AUTO" }
        return "\(base)"
    }
    public static func ev(_ v: Int64) -> ExposureCompensation {
        // Sony encodes in 1/1000 EV; the a6400 steps by thirds.
        let index = Int((Double(v) / 1000.0 * 3).rounded())
        return ExposureCompensation(index: index, minIndex: -15, maxIndex: 15, stepIndex: 1)
    }
    public static func evValue(index: Int) -> Int64 {
        // Sony uses 300/700/1000 for +0.3/+0.7/+1.0
        let whole = index / 3, frac = abs(index % 3)
        let fracThousandths: Int64 = frac == 0 ? 0 : (frac == 1 ? 300 : 700)
        let sign: Int64 = index < 0 ? -1 : 1
        return sign * (Int64(abs(whole)) * 1000 + fracThousandths)
    }
    public static let focusModes: [Int64: String] = [1: "MF", 2: "AF-S", 0x8004: "AF-C", 0x8005: "AF-A", 0x8006: "DMF"]
    public static let whiteBalances: [Int64: String] = [
        2: "Auto WB", 4: "Daylight", 0x8001: "Shade", 0x8002: "Cloudy", 0x8003: "Incandescent",
        0x8004: "Fluorescent: Warm White (-1)", 0x8005: "Fluorescent: Cool White (0)",
        0x8006: "Fluorescent: Day White (+1)", 0x8007: "Fluorescent: Daylight (+2)", 0x8010: "Flash",
        0x8012: "Color Temperature", 0x8020: "Custom 1", 0x8021: "Custom 2", 0x8022: "Custom 3", 0x8030: "Underwater Auto",
    ]
    public static let exposurePrograms: [Int64: String] = [
        1: "Manual", 2: "Program Auto", 3: "Aperture", 4: "Shutter",
        0x8000: "Intelligent Auto", 0x8001: "Superior Auto", 0x8011: "Portrait", 0x8012: "Sports Action",
        0x8013: "Macro", 0x8014: "Landscape", 0x8015: "Sunset", 0x8016: "Night Scene", 0x8017: "Handheld Twilight",
        0x8018: "Night Portrait", 0x8019: "Anti Motion Blur", 0x8041: "Sweep Panorama",
        0x8050: "Movie P", 0x8051: "Movie A", 0x8052: "Movie S", 0x8053: "Movie M", 0x8054: "Movie Auto",
        0x8080: "S&Q P", 0x8081: "S&Q A", 0x8082: "S&Q S", 0x8083: "S&Q M",
    ]
    public static func label(_ v: Int64, in table: [Int64: String]) -> String {
        if v == 0 { return "--" }
        return table[v] ?? String(format: "0x%04X", v)
    }
    public static func value(for label: String, in table: [Int64: String]) -> Int64? {
        table.first { $0.value == label }?.key
    }
}
