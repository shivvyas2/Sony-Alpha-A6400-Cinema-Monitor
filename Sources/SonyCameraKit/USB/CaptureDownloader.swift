import Foundation

/// Pulls every object the camera queued after a shot. Transport-agnostic so it is testable with closures.
struct CaptureDownloader {
    struct QueueEmpty: Error {}
    struct Object: Equatable { var format: UInt16; var filename: String; var data: Data }

    /// Number of objects waiting in the camera (0 when none). On hardware this reads Sony property 0xD215.
    var pending: @Sendable () async throws -> Int
    /// Fetches and pops the next queued object: (ObjectInfo dataset, object bytes). Throws `QueueEmpty` when the
    /// camera answers InvalidObjectHandle / AccessDenied.
    var fetchNext: @Sendable () async throws -> (info: Data, object: Data)
    var pollInterval: Duration = .milliseconds(200)
    var timeout: Duration = .seconds(15)
    var maxObjects = 4

    /// Waits up to `timeout` for the first object, then drains the queue. Empty if nothing arrived in time.
    func run() async throws -> [Object] {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var count = try await pending()
        while count == 0, clock.now < deadline {
            try await Task.sleep(for: pollInterval)
            count = try await pending()
        }
        var out: [Object] = []
        while count > 0, out.count < maxObjects {
            let info: Data, data: Data
            do { (info, data) = try await fetchNext() } catch is QueueEmpty { break }
            let (format, name) = Self.parseObjectInfo(info)
            let fallback = "capture-\(Int(Date().timeIntervalSince1970))-\(out.count + 1)" + (format == 0x3801 ? ".JPG" : ".ARW")
            out.append(Object(format: format, filename: name.isEmpty ? fallback : name, data: data))
            count = try await pending()
        }
        return out
    }

    /// PTP ObjectInfo dataset: StorageID u32, ObjectFormat u16 (byte 4), ProtectionStatus u16, ObjectCompressedSize u32,
    /// ThumbFormat u16, ThumbCompressedSize u32, ThumbPixWidth u32, ThumbPixHeight u32, ImagePixWidth u32,
    /// ImagePixHeight u32, ImageBitDepth u32, ParentObject u32, AssociationType u16, AssociationDesc u32,
    /// SequenceNumber u32 — 52 bytes — then Filename as a PTP string.
    static func parseObjectInfo(_ data: Data) -> (format: UInt16, filename: String) {
        var rd = PTPReader(data)
        guard (try? rd.skip(4)) != nil, let format = try? rd.u16() else { return (0, "") }
        guard (try? rd.skip(46)) != nil, let name = try? rd.string() else { return (format, "") }
        return (format, name)
    }
}
