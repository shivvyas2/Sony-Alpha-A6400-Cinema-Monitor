import Foundation

/// Adds Broadcast Wave (`bext`) and `iXML` chunks to a finished WAV so editors see timecode and scene/take.
public enum BroadcastWave {
    public struct Bext: Equatable, Sendable {
        public var description: String        // ≤ 256 ASCII
        public var originator: String         // ≤ 32
        public var originatorReference: String // ≤ 32
        public var originationDate: String    // "yyyy-mm-dd"
        public var originationTime: String    // "hh:mm:ss"
        public var timeReference: UInt64      // samples since midnight
        public var codingHistory: String
        public init(description: String, originator: String, originatorReference: String, originationDate: String,
                    originationTime: String, timeReference: UInt64, codingHistory: String) {
            self.description = description; self.originator = originator; self.originatorReference = originatorReference
            self.originationDate = originationDate; self.originationTime = originationTime
            self.timeReference = timeReference; self.codingHistory = codingHistory
        }
    }
    public struct Chunk: Equatable { public var id: String; public var offset: Int; public var size: Int }   // offset = start of the 8-byte header

    public enum Error: Swift.Error { case notRIFF, truncated }

    // MARK: Reading

    public static func chunks(url: URL) throws -> [Chunk] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 12, String(decoding: data[0 ..< 4], as: UTF8.self) == "RIFF",
              String(decoding: data[8 ..< 12], as: UTF8.self) == "WAVE" else { throw Error.notRIFF }
        var out: [Chunk] = []
        var pos = 12
        while pos + 8 <= data.count {
            let id = String(decoding: data[pos ..< pos + 4], as: UTF8.self)
            let size = Int(le32(data, pos + 4))
            out.append(Chunk(id: id, offset: pos, size: size))
            pos += 8 + size + (size & 1)
        }
        return out
    }

    public static func readBext(url: URL) throws -> Bext? {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard let c = try chunks(url: url).first(where: { $0.id == "bext" }), c.size >= 602 else { return nil }
        let p = c.offset + 8
        func str(_ off: Int, _ len: Int) -> String {
            let s = data[p + off ..< p + off + len]
            return String(decoding: s.prefix { $0 != 0 }, as: UTF8.self)
        }
        let low = UInt64(le32(data, p + 338)), high = UInt64(le32(data, p + 342))
        return Bext(description: str(0, 256), originator: str(256, 32), originatorReference: str(288, 32),
                    originationDate: str(320, 10), originationTime: str(330, 8),
                    timeReference: (high << 32) | low, codingHistory: str(602, c.size - 602))
    }

    public static func readIXML(url: URL) throws -> String? {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard let c = try chunks(url: url).first(where: { $0.id == "iXML" }) else { return nil }
        let body = data[c.offset + 8 ..< c.offset + 8 + c.size]
        return String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: Writing

    /// Appends (or replaces) `bext` and `iXML` and fixes the RIFF size. Call after the audio file is closed.
    public static func finalize(url: URL, bext: Bext, ixml: String) throws {
        var data = try Data(contentsOf: url)
        guard data.count >= 12 else { throw Error.notRIFF }
        // Drop existing bext/iXML chunks so finalize is idempotent.
        var kept = Data(data[0 ..< 12])
        for c in try chunks(url: url) where c.id != "bext" && c.id != "iXML" {
            let end = min(data.count, c.offset + 8 + c.size + (c.size & 1))
            kept.append(data[c.offset ..< end])
        }
        data = kept
        data.append(chunk("bext", bextBody(bext)))
        data.append(chunk("iXML", Data(ixml.utf8)))
        var riffSize = UInt32(data.count - 8).littleEndian
        data.replaceSubrange(4 ..< 8, with: Data(bytes: &riffSize, count: 4))
        try data.write(to: url, options: .atomic)
    }

    static func bextBody(_ b: Bext) -> Data {
        var d = Data()
        d.append(fixed(b.description, 256)); d.append(fixed(b.originator, 32)); d.append(fixed(b.originatorReference, 32))
        d.append(fixed(b.originationDate, 10)); d.append(fixed(b.originationTime, 8))
        d.append(le32Data(UInt32(truncatingIfNeeded: b.timeReference))); d.append(le32Data(UInt32(truncatingIfNeeded: b.timeReference >> 32)))
        var version = UInt16(1).littleEndian; d.append(Data(bytes: &version, count: 2))
        d.append(Data(count: 64))          // UMID
        d.append(Data(count: 10))          // loudness fields (unset)
        d.append(Data(count: 180))         // reserved
        d.append(Data(b.codingHistory.utf8))
        return d
    }

    /// iXML with the fields Final Cut and Resolve read: project, scene, take, tape (reel), track names, frame rate.
    public static func ixml(project: String, scene: String?, take: Int, tape: String, fileUID: String, fps: Int, trackNames: [String]) -> String {
        let tracks = trackNames.enumerated().map {
            "<TRACK><CHANNEL_INDEX>\($0.offset + 1)</CHANNEL_INDEX><INTERLEAVE_INDEX>\($0.offset + 1)</INTERLEAVE_INDEX><NAME>\(escape($0.element))</NAME></TRACK>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <BWFXML><IXML_VERSION>1.5</IXML_VERSION><PROJECT>\(escape(project))</PROJECT><SCENE>\(escape(scene ?? ""))</SCENE><TAKE>\(take)</TAKE><TAPE>\(escape(tape))</TAPE><CIRCLED>FALSE</CIRCLED><FILE_UID>\(escape(fileUID))</FILE_UID><SPEED><MASTER_SPEED>\(fps)/1</MASTER_SPEED><CURRENT_SPEED>\(fps)/1</CURRENT_SPEED><TIMECODE_RATE>\(fps)/1</TIMECODE_RATE><TIMECODE_FLAG>NDF</TIMECODE_FLAG></SPEED><TRACK_LIST><TRACK_COUNT>\(trackNames.count)</TRACK_COUNT>\(tracks)</TRACK_LIST></BWFXML>
        """
    }

    public static func timeReference(for date: Date, sampleRate: Double, calendar: Calendar = .current) -> UInt64 {
        let midnight = calendar.startOfDay(for: date)
        return UInt64(max(0, date.timeIntervalSince(midnight)) * sampleRate)
    }

    // MARK: Bytes

    private static func chunk(_ id: String, _ body: Data) -> Data {
        var d = Data(id.utf8)
        d.append(le32Data(UInt32(body.count)))
        d.append(body)
        if body.count & 1 == 1 { d.append(0) }
        return d
    }
    private static func fixed(_ s: String, _ len: Int) -> Data {
        var d = Data(s.utf8.prefix(len)); d.append(Data(count: len - d.count)); return d
    }
    private static func le32Data(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
    private static func le32(_ d: Data, _ at: Int) -> UInt32 {
        UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
    }
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
