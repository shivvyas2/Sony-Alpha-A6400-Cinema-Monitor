import Foundation

/// PTP (ISO 15740) constants and container packing used over USB.
public enum PTP {
    public enum ContainerType: UInt16, Sendable { case command = 1, data = 2, response = 3, event = 4 }

    public enum Op {
        public static let getDeviceInfo: UInt16 = 0x1001
        public static let openSession: UInt16 = 0x1002
        public static let closeSession: UInt16 = 0x1003
        public static let getObjectInfo: UInt16 = 0x1008
        public static let getObject: UInt16 = 0x1009
        public static let getDevicePropDesc: UInt16 = 0x1014
        public static let getDevicePropValue: UInt16 = 0x1015
        public static let setDevicePropValue: UInt16 = 0x1016
        // Sony vendor extension
        public static let sonySDIOConnect: UInt16 = 0x9201
        public static let sonyGetSDIOExtDeviceInfo: UInt16 = 0x9202
        public static let sonyGetDevicePropDesc: UInt16 = 0x9203
        public static let sonyGetDevicePropValue: UInt16 = 0x9204
        public static let sonySetControlDeviceA: UInt16 = 0x9205   // absolute value
        public static let sonyGetControlDeviceDesc: UInt16 = 0x9206
        public static let sonySetControlDeviceB: UInt16 = 0x9207   // buttons / relative steps
        public static let sonyGetAllDevicePropData: UInt16 = 0x9209
    }

    public enum Response {
        public static let ok: UInt16 = 0x2001
        public static let generalError: UInt16 = 0x2002
        public static let sessionNotOpen: UInt16 = 0x2003
        public static let operationNotSupported: UInt16 = 0x2005
        public static let invalidObjectHandle: UInt16 = 0x2009
        public static let devicePropNotSupported: UInt16 = 0x200A
        public static let accessDenied: UInt16 = 0x200F
        public static let deviceBusy: UInt16 = 0x2019
        public static let sessionAlreadyOpen: UInt16 = 0x201E
        public static let invalidDevicePropValue: UInt16 = 0x201C
    }

    public enum DataType: UInt16, Sendable {
        case undef = 0, int8 = 1, uint8 = 2, int16 = 3, uint16 = 4, int32 = 5, uint32 = 6, int64 = 7, uint64 = 8
        case int128 = 9, uint128 = 10, string = 0xFFFF
        public var byteSize: Int? {
            switch self {
            case .int8, .uint8: return 1
            case .int16, .uint16: return 2
            case .int32, .uint32: return 4
            case .int64, .uint64: return 8
            case .int128, .uint128: return 16
            case .undef, .string: return nil
            }
        }
    }

    public struct Container: Sendable, Equatable {
        public var type: ContainerType
        public var code: UInt16
        public var transactionID: UInt32
        public var payload: Data   // params (4 bytes each) for command/response; raw bytes for data

        public init(type: ContainerType, code: UInt16, transactionID: UInt32, payload: Data = Data()) {
            self.type = type; self.code = code; self.transactionID = transactionID; self.payload = payload
        }

        public init(type: ContainerType, code: UInt16, transactionID: UInt32, params: [UInt32]) {
            var p = Data()
            for v in params { p.append(le32: v) }
            self.init(type: type, code: code, transactionID: transactionID, payload: p)
        }

        public var params: [UInt32] {
            stride(from: 0, to: payload.count - payload.count % 4, by: 4).map { payload.le32(at: $0) }
        }

        public var encoded: Data {
            var d = Data(capacity: 12 + payload.count)
            d.append(le32: UInt32(12 + payload.count))
            d.append(le16: type.rawValue)
            d.append(le16: code)
            d.append(le32: transactionID)
            d.append(payload)
            return d
        }

        /// Total length declared in a container header (needs ≥ 4 bytes).
        public static func declaredLength(_ d: Data) -> Int? { d.count >= 4 ? Int(d.le32(at: 0)) : nil }

        public static func decode(_ d: Data) -> Container? {
            guard d.count >= 12, let t = ContainerType(rawValue: d.le16(at: 4)) else { return nil }
            let len = min(Int(d.le32(at: 0)), d.count)
            return Container(type: t, code: d.le16(at: 6), transactionID: d.le32(at: 8), payload: d.subdata(in: 12 ..< max(12, len)))
        }
    }
}

public struct PTPError: Error, LocalizedError, Sendable, Equatable {
    public let code: UInt16
    public let op: UInt16
    public init(code: UInt16, op: UInt16) { self.code = code; self.op = op }
    public var errorDescription: String? {
        let name: String
        switch code {
        case PTP.Response.deviceBusy: name = "device busy"
        case PTP.Response.operationNotSupported: name = "operation not supported"
        case PTP.Response.accessDenied: name = "access denied"
        case PTP.Response.invalidDevicePropValue: name = "invalid value"
        case PTP.Response.devicePropNotSupported: name = "property not supported"
        case PTP.Response.sessionNotOpen: name = "session not open"
        default: name = "PTP error"
        }
        return String(format: "%@ (0x%04X) in op 0x%04X", name, code, op)
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func append(le16 v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func append(le32 v: UInt32) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]) }
    mutating func append(le64 v: UInt64) { append(le32: UInt32(v & 0xFFFF_FFFF)); append(le32: UInt32(v >> 32)) }

    func le16(at i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }
    func le32(at i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }
    func le64(at i: Int) -> UInt64 { UInt64(le32(at: i)) | UInt64(le32(at: i + 4)) << 32 }
}

/// Cursor for reading PTP data structures.
struct PTPReader {
    let data: Data
    var offset = 0
    init(_ d: Data) { data = d }
    var remaining: Int { data.count - offset }
    var atEnd: Bool { remaining <= 0 }

    mutating func u8() throws -> UInt8 { guard remaining >= 1 else { throw PTPParseError() }; defer { offset += 1 }; return data[data.startIndex + offset] }
    mutating func u16() throws -> UInt16 { guard remaining >= 2 else { throw PTPParseError() }; defer { offset += 2 }; return data.le16(at: offset) }
    mutating func u32() throws -> UInt32 { guard remaining >= 4 else { throw PTPParseError() }; defer { offset += 4 }; return data.le32(at: offset) }
    mutating func u64() throws -> UInt64 { guard remaining >= 8 else { throw PTPParseError() }; defer { offset += 8 }; return data.le64(at: offset) }
    mutating func skip(_ n: Int) throws { guard remaining >= n else { throw PTPParseError() }; offset += n }
    func peek16() -> UInt16? { remaining >= 2 ? data.le16(at: offset) : nil }

    /// PTP string: u8 count of UTF-16 code units (incl. terminator), then UTF-16LE.
    mutating func string() throws -> String {
        let n = Int(try u8())
        guard n > 0 else { return "" }
        guard remaining >= n * 2 else { throw PTPParseError() }
        var units: [UInt16] = []
        for _ in 0 ..< n { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    mutating func u16Array() throws -> [UInt16] {
        let n = Int(try u32())
        guard remaining >= n * 2 else { throw PTPParseError() }
        return try (0 ..< n).map { _ in try u16() }
    }

    /// Reads one value of the given data type as a signed 64-bit integer (strings become nil).
    mutating func value(of type: PTP.DataType) throws -> Int64? {
        switch type {
        case .int8: return Int64(Int8(bitPattern: try u8()))
        case .uint8: return Int64(try u8())
        case .int16: return Int64(Int16(bitPattern: try u16()))
        case .uint16: return Int64(try u16())
        case .int32: return Int64(Int32(bitPattern: try u32()))
        case .uint32: return Int64(try u32())
        case .int64: return Int64(bitPattern: try u64())
        case .uint64: return Int64(bitPattern: try u64())
        case .int128, .uint128: try skip(16); return nil
        case .string: _ = try string(); return nil
        case .undef: return nil
        }
    }
}

struct PTPParseError: Error {}

extension Data {
    /// Packs an integer as the given PTP data type, little-endian.
    static func ptpValue(_ v: Int64, as type: PTP.DataType) -> Data {
        var d = Data()
        switch type {
        case .int8, .uint8: d.append(UInt8(truncatingIfNeeded: v))
        case .int16, .uint16: d.append(le16: UInt16(truncatingIfNeeded: v))
        case .int32, .uint32: d.append(le32: UInt32(truncatingIfNeeded: v))
        case .int64, .uint64: d.append(le64: UInt64(bitPattern: v))
        default: d.append(le32: UInt32(truncatingIfNeeded: v))
        }
        return d
    }
}
