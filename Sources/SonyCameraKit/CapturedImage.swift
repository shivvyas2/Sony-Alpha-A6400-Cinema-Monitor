import Foundation

/// One file the camera handed over after a shot. A RAW+JPEG shot produces two of these with the same `shotIndex`.
public struct CapturedImage: Sendable, Identifiable, Equatable, Hashable {
    public enum Kind: String, Sendable { case jpeg = "JPEG", raw = "RAW" }
    public let id: UUID
    public let url: URL
    public let kind: Kind
    public let filename: String
    public let takenAt: Date
    public let shotIndex: Int

    public init(url: URL, kind: Kind, filename: String, takenAt: Date, shotIndex: Int, id: UUID = UUID()) {
        self.id = id; self.url = url; self.kind = kind; self.filename = filename; self.takenAt = takenAt; self.shotIndex = shotIndex
    }

    /// PTP ObjectFormat 0x3801 is EXIF/JPEG. Sony ARW comes with a vendor code, so anything else that is not
    /// named like a JPEG is treated as RAW.
    public static func kind(objectFormat: UInt16, filename: String) -> Kind {
        if objectFormat == 0x3801 { return .jpeg }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ext == "jpg" || ext == "jpeg" ? .jpeg : .raw
    }
}

public enum CaptureEvent: Sendable, Equatable {
    case image(CapturedImage)
    /// Every file for this shot has been delivered.
    case finished(shotIndex: Int)
    /// Nothing more will arrive for this shot; `message` is user-readable. `shotIndex` -1 = no shot was ever logged.
    case failed(shotIndex: Int, message: String)
}

/// Where captured files go on disk: `<base>/yyyy-MM-dd/<camera filename>`, never overwriting.
public enum CaptureStore {
    public static var defaultBase: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("CinemaHUD")
    }

    public static func directory(base: URL, date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return base.appendingPathComponent(f.string(from: date), isDirectory: true)
    }

    public static func uniqueURL(in dir: URL, filename: String, fileManager: FileManager = .default) -> URL {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = dir.appendingPathComponent(filename)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    @discardableResult
    public static func write(_ data: Data, base: URL, filename: String, date: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        let dir = directory(base: base, date: date)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = uniqueURL(in: dir, filename: filename, fileManager: fileManager)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Fan-out of capture events to any number of listeners. Backends own one; the session subscribes.
public final class CaptureBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<CaptureEvent>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<CaptureEvent> {
        let id = UUID()
        return AsyncStream { cont in
            lock.lock(); continuations[id] = cont; lock.unlock()
            cont.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }

    public func send(_ event: CaptureEvent) {
        lock.lock(); let targets = Array(continuations.values); lock.unlock()
        for c in targets { c.yield(event) }
    }

    private func remove(_ id: UUID) { lock.lock(); continuations[id] = nil; lock.unlock() }
}
