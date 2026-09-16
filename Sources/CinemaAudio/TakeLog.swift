import Foundation

public struct TakeLabel: Codable, Equatable, Sendable {
    public var cameraIndex: String
    public var reel: Int
    public var clip: Int
    public init(cameraIndex: String, reel: Int, clip: Int) { self.cameraIndex = cameraIndex; self.reel = reel; self.clip = clip }
    /// "A_0001_C003" — the HUD's clip label with the space replaced, safe as a file name.
    public var fileStem: String { String(format: "%@_%04d_C%03d", cameraIndex, reel, clip) }
}

public struct TakeMetadata: Codable, Equatable, Sendable {
    public var project: String
    public var projectFPS: Int
    public var scene: String?
    public var note: String?
    public var camera: [String: String]
    public init(project: String, projectFPS: Int, scene: String?, note: String?, camera: [String: String]) {
        self.project = project; self.projectFPS = projectFPS; self.scene = scene; self.note = note; self.camera = camera
    }
}

public struct TakeRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: Codable, Equatable, Sendable {
        case recording, complete, cameraNeverStarted, interrupted(String), writeFailed(String)
    }
    public var id: String                 // file stem (unique per day folder)
    public var label: TakeLabel
    public var wavPath: String            // relative to the day folder
    public var pressedAt: Date
    public var confirmedStart: Date?
    public var confirmedStop: Date?
    public var prerollSeconds: Double
    public var sampleRate: Double
    public var channelNames: [String]
    public var metadata: TakeMetadata
    public var outcome: Outcome

    public init(id: String, label: TakeLabel, wavPath: String, pressedAt: Date, confirmedStart: Date?, confirmedStop: Date?,
                prerollSeconds: Double, sampleRate: Double, channelNames: [String], metadata: TakeMetadata, outcome: Outcome) {
        self.id = id; self.label = label; self.wavPath = wavPath; self.pressedAt = pressedAt; self.confirmedStart = confirmedStart
        self.confirmedStop = confirmedStop; self.prerollSeconds = prerollSeconds; self.sampleRate = sampleRate
        self.channelNames = channelNames; self.metadata = metadata; self.outcome = outcome
    }

    /// Wall-clock time of the WAV's first sample.
    public var firstSampleDate: Date { pressedAt.addingTimeInterval(-prerollSeconds) }
}

private extension DateFormatter {
    static let corruptStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()
}

public struct TakeLog: Codable, Equatable {
    public static let fileName = "takes.json"
    public var takes: [TakeRecord] = []
    public init() {}

    /// ISO-8601 with milliseconds; decoding also accepts plain-second timestamps.
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plainDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let d = dateFormatter.date(from: s) ?? plainDateFormatter.date(from: s) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(s)"))
        }
        return dec
    }
    static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer(); try c.encode(dateFormatter.string(from: date))
        }
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    /// Loads `takes.json`, or an empty log when the file is missing. When it exists but fails to decode
    /// (corrupt or hand-edited), the file is moved aside to `takes.json.corrupt-<timestamp>` — rather
    /// than silently treated as empty and then overwritten by the next save, destroying the day's
    /// pairing metadata — and `onCorrupt` is called with a short message before the empty log is returned.
    public static func load(from folder: URL, onCorrupt: ((String) -> Void)? = nil) -> TakeLog {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return TakeLog() }
        let dec = Self.decoder()
        if let log = try? dec.decode(TakeLog.self, from: data) { return log }
        let stamp = DateFormatter.corruptStamp.string(from: Date())
        let movedTo = folder.appendingPathComponent("\(fileName).corrupt-\(stamp)")
        try? FileManager.default.removeItem(at: movedTo)
        try? FileManager.default.moveItem(at: url, to: movedTo)
        onCorrupt?("takes.json was unreadable and has been moved aside to \(movedTo.lastPathComponent)")
        return TakeLog()
    }

    public func save(to folder: URL) throws {
        let enc = Self.encoder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try enc.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public mutating func upsert(_ record: TakeRecord) {
        if let i = takes.firstIndex(where: { $0.id == record.id }) { takes[i] = record } else { takes.append(record) }
    }
}

public enum DayFolder {
    public static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    /// ~/Movies/CinemaHUD/<yyyy-MM-dd> (or `base`/<day> when given).
    public static func url(for date: Date, base: URL? = nil, calendar: Calendar = .current) -> URL {
        let root = base ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("CinemaHUD")
        return root.appendingPathComponent(dayString(date, calendar: calendar))
    }
    /// "<stem>.wav", or "<stem>_2.wav", "<stem>_3.wav" … when the name is taken.
    public static func uniqueWAVName(stem: String, in audioFolder: URL) -> String {
        var name = "\(stem).wav", n = 1
        while FileManager.default.fileExists(atPath: audioFolder.appendingPathComponent(name).path) {
            n += 1; name = "\(stem)_\(n).wav"
        }
        return name
    }
}
