import Foundation

/// One decoded packet from the Sony liveview stream.
public struct LiveviewFrame: Sendable, Equatable {
    public let sequence: UInt16
    public let timestamp: UInt32
    public let jpeg: Data
}

/// Incremental parser for the Sony Camera Remote API liveview stream.
///
/// Packet layout:
///   Common header (8 bytes):  0xFF, payloadType, seq(2, BE), timestamp(4, BE)
///   Payload header (128):     startCode 24 35 68 79, payloadSize(3, BE), paddingSize(1), reserved…
///   Payload (payloadSize)     JPEG for type 0x01, frame-info for 0x02
///   Padding (paddingSize)
public struct LiveviewStreamParser: Sendable {
    public static let commonHeaderSize = 8
    public static let payloadHeaderSize = 128
    public static let startCode: [UInt8] = [0x24, 0x35, 0x68, 0x79]

    private var buffer: [UInt8] = []
    public private(set) var droppedBytes = 0

    public init() {}

    /// Feed bytes; returns every complete JPEG frame now available.
    public mutating func append(_ data: Data) -> [LiveviewFrame] {
        buffer.append(contentsOf: data)
        var frames: [LiveviewFrame] = []
        var cursor = 0
        let headerLen = Self.commonHeaderSize + Self.payloadHeaderSize

        while buffer.count - cursor >= headerLen {
            let b = buffer
            let p = cursor
            let validStart = b[p] == 0xFF
                && b[p + 8] == Self.startCode[0] && b[p + 9] == Self.startCode[1]
                && b[p + 10] == Self.startCode[2] && b[p + 11] == Self.startCode[3]
            if !validStart {
                cursor += 1
                droppedBytes += 1
                continue
            }
            let payloadType = b[p + 1]
            let sequence = UInt16(b[p + 2]) << 8 | UInt16(b[p + 3])
            let timestamp = UInt32(b[p + 4]) << 24 | UInt32(b[p + 5]) << 16 | UInt32(b[p + 6]) << 8 | UInt32(b[p + 7])
            let payloadSize = Int(b[p + 12]) << 16 | Int(b[p + 13]) << 8 | Int(b[p + 14])
            let paddingSize = Int(b[p + 15])
            let total = headerLen + payloadSize + paddingSize
            guard buffer.count - cursor >= total else { break }
            if payloadType == 0x01 {
                let start = p + headerLen
                frames.append(LiveviewFrame(sequence: sequence, timestamp: timestamp,
                                            jpeg: Data(b[start ..< start + payloadSize])))
            }
            cursor += total
        }
        if cursor > 0 { buffer.removeFirst(cursor) }
        return frames
    }

    public mutating func reset() { buffer.removeAll(); droppedBytes = 0 }

    /// Builds a stream packet (used by tests and the simulator).
    public static func packet(type: UInt8, sequence: UInt16, timestamp: UInt32, payload: Data, padding: Int = 0) -> Data {
        var out = Data()
        out.append(0xFF)
        out.append(type)
        out.append(UInt8(sequence >> 8)); out.append(UInt8(sequence & 0xFF))
        out.append(contentsOf: [UInt8(timestamp >> 24 & 0xFF), UInt8(timestamp >> 16 & 0xFF), UInt8(timestamp >> 8 & 0xFF), UInt8(timestamp & 0xFF)])
        var ph = [UInt8](repeating: 0, count: payloadHeaderSize)
        ph[0 ..< 4] = ArraySlice(startCode)
        let size = payload.count
        ph[4] = UInt8(size >> 16 & 0xFF); ph[5] = UInt8(size >> 8 & 0xFF); ph[6] = UInt8(size & 0xFF)
        ph[7] = UInt8(padding)
        out.append(contentsOf: ph)
        out.append(payload)
        out.append(Data(repeating: 0, count: padding))
        return out
    }
}
