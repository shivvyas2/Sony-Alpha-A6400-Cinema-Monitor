import Foundation

/// Human names for the enumerated Sony properties that are not part of the main HUD.
public enum SonyTables {
    public struct Entry { public let code: UInt16; public let name: String; public let group: String; public let values: [Int64: String] }

    public static let driveModes: [Int64: String] = [
        1: "Single", 2: "Continuous", 0x8010: "Continuous Hi+", 0x8013: "Continuous Hi", 0x8015: "Continuous Mid", 0x8012: "Continuous Lo",
        0x8014: "Continuous Speed Priority", 0x8005: "Self-timer 2s", 0x8003: "Self-timer 5s", 0x8004: "Self-timer 10s",
        0x8008: "Self-timer 10s ×3", 0x8009: "Self-timer 10s ×5", 0x800C: "Self-timer 5s ×3", 0x800D: "Self-timer 5s ×5",
        0x800E: "Self-timer 2s ×3", 0x800F: "Self-timer 2s ×5",
        0x8337: "Bracket C 0.3EV ×3", 0x8537: "Bracket C 0.3EV ×5", 0x8937: "Bracket C 0.3EV ×9",
        0x8357: "Bracket C 0.5EV ×3", 0x8557: "Bracket C 0.5EV ×5", 0x8957: "Bracket C 0.5EV ×9",
        0x8377: "Bracket C 0.7EV ×3", 0x8577: "Bracket C 0.7EV ×5", 0x8977: "Bracket C 0.7EV ×9",
        0x8311: "Bracket C 1.0EV ×3", 0x8511: "Bracket C 1.0EV ×5", 0x8911: "Bracket C 1.0EV ×9",
        0x8321: "Bracket C 2.0EV ×3", 0x8521: "Bracket C 2.0EV ×5", 0x8331: "Bracket C 3.0EV ×3", 0x8531: "Bracket C 3.0EV ×5",
        0x8336: "Bracket S 0.3EV ×3", 0x8536: "Bracket S 0.3EV ×5", 0x8936: "Bracket S 0.3EV ×9",
        0x8356: "Bracket S 0.5EV ×3", 0x8556: "Bracket S 0.5EV ×5", 0x8956: "Bracket S 0.5EV ×9",
        0x8376: "Bracket S 0.7EV ×3", 0x8576: "Bracket S 0.7EV ×5", 0x8976: "Bracket S 0.7EV ×9",
        0x8310: "Bracket S 1.0EV ×3", 0x8510: "Bracket S 1.0EV ×5", 0x8910: "Bracket S 1.0EV ×9",
        0x8320: "Bracket S 2.0EV ×3", 0x8520: "Bracket S 2.0EV ×5", 0x8330: "Bracket S 3.0EV ×3", 0x8530: "Bracket S 3.0EV ×5",
        0x8018: "WB Bracket Lo", 0x8028: "WB Bracket Hi", 0x8019: "DRO Bracket Lo", 0x8029: "DRO Bracket Hi",
    ]
    public static let metering: [Int64: String] = [
        1: "Average", 2: "Center Weighted", 3: "Multi Spot", 4: "Center Spot",
        0x8001: "Multi", 0x8002: "Center", 0x8003: "Entire Screen Avg.", 0x8004: "Spot Standard", 0x8005: "Spot Large", 0x8006: "Highlight",
    ]
    public static let flash: [Int64: String] = [
        1: "Auto", 2: "Off", 3: "Fill", 4: "Red-eye Auto", 5: "Red-eye Fill", 6: "External Sync",
        0x10: "Rear Sync", 0x12: "Wireless", 0x13: "Slow Sync", 0x14: "Rear Curtain Sync",
        0x8001: "Slow Sync", 0x8003: "Rear Curtain Sync", 0x8004: "Wireless Sync", 0x8021: "HSS Auto", 0x8022: "HSS Fill", 0x8024: "HSS Wireless",
    ]
    public static let dro: [Int64: String] = [
        1: "Off", 2: "DRO", 0x10: "DRO+", 0x11: "DRO Lv1", 0x12: "DRO Lv2", 0x13: "DRO Lv3", 0x14: "DRO Lv4", 0x15: "DRO Lv5", 0x1F: "DRO Auto",
        0x20: "HDR Auto", 0x21: "HDR 1.0EV", 0x22: "HDR 2.0EV", 0x23: "HDR 3.0EV", 0x24: "HDR 4.0EV", 0x25: "HDR 5.0EV", 0x26: "HDR 6.0EV",
    ]
    public static let imageSize: [Int64: String] = [1: "Large", 2: "Medium", 3: "Small"]
    public static let aspect: [Int64: String] = [1: "3:2", 2: "16:9", 3: "4:3", 4: "1:1"]
    public static let focusArea: [Int64: String] = [
        1: "Wide", 2: "Zone", 3: "Center", 0x101: "Flexible Spot S", 0x102: "Flexible Spot M", 0x103: "Flexible Spot L", 0x104: "Expand Flexible Spot",
        0x201: "Tracking: Wide", 0x202: "Tracking: Zone", 0x203: "Tracking: Center", 0x204: "Tracking: Spot S", 0x205: "Tracking: Spot M",
        0x206: "Tracking: Spot L", 0x207: "Tracking: Expand Spot",
    ]
    public static let focusMetering: [Int64: String] = [
        1: "Center Spot", 2: "Multi Spot", 3: "Wide", 4: "Zone", 5: "Center", 0x8001: "Flexible Spot", 0x8003: "Expand Flexible Spot",
        0x8031: "Tracking Wide", 0x8032: "Tracking Zone", 0x8041: "Tracking Spot", 0x8042: "Tracking Expand Spot",
    ]
    public static let pictureEffect: [Int64: String] = [
        0x8000: "Off", 0x8001: "Toy Camera Normal", 0x8002: "Toy Camera Cool", 0x8003: "Toy Camera Warm", 0x8004: "Toy Camera Green", 0x8005: "Toy Camera Magenta",
        0x8010: "Pop Color", 0x8020: "Posterization B/W", 0x8021: "Posterization Color", 0x8030: "Retro Photo", 0x8040: "Soft High-key",
        0x8050: "Partial Color Red", 0x8051: "Partial Color Green", 0x8052: "Partial Color Blue", 0x8053: "Partial Color Yellow",
        0x8060: "High Contrast Mono", 0x8070: "Soft Focus Low", 0x8071: "Soft Focus Mid", 0x8072: "Soft Focus High",
        0x8080: "HDR Painting Low", 0x8081: "HDR Painting Mid", 0x8082: "HDR Painting High", 0x8090: "Rich-tone Mono",
        0x80A0: "Miniature Auto", 0x80A1: "Miniature Top", 0x80A2: "Miniature Middle (H)", 0x80A3: "Miniature Bottom",
        0x80A4: "Miniature Left", 0x80A5: "Miniature Middle (V)", 0x80A6: "Miniature Right", 0x80B0: "Watercolor",
        0x80C0: "Illustration Low", 0x80C1: "Illustration Mid", 0x80C2: "Illustration High",
    ]
    public static let onOff21: [Int64: String] = [1: "On", 2: "Off"]
    public static let offOn12: [Int64: String] = [1: "Off", 2: "On"]
    public static let stillDestination: [Int64: String] = [1: "Camera", 0x10: "PC", 0x11: "PC + Camera"]

    public static let pictureProfile: [Int64: String] = [
        0: "Off", 1: "PP1", 2: "PP2", 3: "PP3", 4: "PP4", 5: "PP5", 6: "PP6", 7: "PP7 (S-Log2)", 8: "PP8 (S-Log3)", 9: "PP9 (S-Log3)", 10: "PP10 (HLG)",
    ]

    /// Properties shown in the settings menu, in display order. Entries whose property the body
    /// does not report (e.g. Picture Profile 0xD23F on the a6400) are skipped automatically.
    public static let menu: [Entry] = [
        Entry(code: 0xD23F, name: "Picture profile", group: "Image", values: pictureProfile),
        Entry(code: 0x5013, name: "Drive mode", group: "Shooting", values: driveModes),
        Entry(code: 0x500B, name: "Metering", group: "Exposure", values: metering),
        Entry(code: 0xD201, name: "DRO / Auto HDR", group: "Exposure", values: dro),
        Entry(code: 0x5004, name: "Flash", group: "Shooting", values: flash),
        Entry(code: 0xD22C, name: "Focus area", group: "Focus", values: focusArea),
        Entry(code: 0x500C, name: "Focus area (legacy)", group: "Focus", values: focusMetering),
        Entry(code: 0xD203, name: "Image size", group: "Image", values: imageSize),
        Entry(code: 0xD211, name: "Aspect ratio", group: "Image", values: aspect),
        Entry(code: 0xD21B, name: "Picture effect", group: "Image", values: pictureEffect),
        Entry(code: 0xD231, name: "Live view exposure preview", group: "Monitor", values: onOff21),
        Entry(code: 0xD222, name: "Still save destination", group: "Shooting", values: stillDestination),
    ]

    public static func name(_ v: Int64, in table: [Int64: String]) -> String { table[v] ?? String(format: "0x%04X", v) }
}
