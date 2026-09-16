// Sources/CinemaAudio/TakeSync.swift
import AVFoundation
import CoreGraphics

public struct ClipInfo: Sendable, Equatable, Identifiable {
    public let id: URL
    public var url: URL { id }
    public var name: String
    public var duration: Double
    public var creationDate: Date?
    public var hasAudio: Bool
    public var videoSize: CGSize
    public var nominalFrameRate: Double
    public init(id: URL, name: String, duration: Double, creationDate: Date?, hasAudio: Bool, videoSize: CGSize, nominalFrameRate: Double) {
        self.id = id; self.name = name; self.duration = duration; self.creationDate = creationDate
        self.hasAudio = hasAudio; self.videoSize = videoSize; self.nominalFrameRate = nominalFrameRate
    }
}

public struct TakePair: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case unpaired, estimated, synced, lowConfidence, missingWAV, exported(ExportedWAV), failed(String)
    }
    public var id: String { clip.id.path }
    public var clip: ClipInfo
    public var take: TakeRecord?
    public var offsetSeconds: Double?
    public var confidence: Double?
    public var status: Status
    public init(clip: ClipInfo, take: TakeRecord?, offsetSeconds: Double?, confidence: Double?, status: Status) {
        self.clip = clip; self.take = take; self.offsetSeconds = offsetSeconds; self.confidence = confidence; self.status = status
    }
}

public enum TakeSync {
    public enum Error: Swift.Error, LocalizedError {
        case noCorrelation
        public var errorDescription: String? { "Couldn't find a matching point in the audio (no correlation)" }
    }

    public static let lowConfidence = 0.5
    public static let postRollSeconds = 1.0
    static let clipExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Files or folders (a card's PRIVATE/M4ROOT/CLIP is walked); clips sorted by creation date then name.
    public static func inspect(_ urls: [URL]) async -> [ClipInfo] {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if clipExtensions.contains(f.pathExtension.lowercased()) { files.append(f) }
                }
            } else if clipExtensions.contains(url.pathExtension.lowercased()) { files.append(url) }
        }
        var clips: [ClipInfo] = []
        for f in files { if let c = try? await info(for: f) { clips.append(c) } }
        return clips.sorted {
            let a = $0.creationDate ?? .distantPast, b = $1.creationDate ?? .distantPast
            return a == b ? $0.name < $1.name : a < b
        }
    }

    static func info(for url: URL) async throws -> ClipInfo {
        let asset = AVURLAsset(url: url)
        let (duration, creation) = try await asset.load(.duration, .creationDate)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var size = CGSize.zero, fps = 0.0
        if let v = video {
            let (natural, transform, rate) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            size = natural.applying(transform); size = CGSize(width: abs(size.width), height: abs(size.height)); fps = Double(rate)
        }
        return ClipInfo(id: url, name: url.deletingPathExtension().lastPathComponent, duration: duration.seconds,
                        creationDate: try await creation?.load(.dateValue), hasAudio: !audio.isEmpty, videoSize: size, nominalFrameRate: fps)
    }

    /// Where clip time 0 is expected inside the WAV, from the take log alone.
    public static func estimate(_ take: TakeRecord) -> Double {
        take.prerollSeconds + (take.confirmedStart.map { $0.timeIntervalSince(take.pressedAt) } ?? 0)
    }

    /// Walk clips and completed takes in time order; a clip takes the next take whose WAV length fits it.
    /// A take that matches nothing is skipped for the *next* clip, not left blocking every later one:
    /// each clip scans forward from `next` over at most the next 3 candidates (candidates with no
    /// `confirmedStop` can't produce an expected duration, so they're skipped without using up that
    /// budget) for the first one within tolerance. A match advances `next` to one past it; no match
    /// leaves `next` where it was and marks the clip `.unpaired`.
    public static func pair(clips: [ClipInfo], takes: [TakeRecord]) -> [TakePair] {
        let candidates = takes.filter { $0.outcome == .complete }.sorted { $0.pressedAt < $1.pressedAt }
        var next = 0
        return clips.map { clip in
            let tolerance = max(2, 0.05 * clip.duration)
            var i = next, scanned = 0
            while scanned < 3, i < candidates.count {
                let t = candidates[i]
                guard let stop = t.confirmedStop else { i += 1; continue }
                let wavSeconds = stop.timeIntervalSince(t.firstSampleDate) + postRollSeconds
                let expected = wavSeconds - estimate(t) - postRollSeconds
                if abs(clip.duration - expected) <= tolerance {
                    next = i + 1
                    return TakePair(clip: clip, take: t, offsetSeconds: estimate(t), confidence: nil, status: .estimated)
                }
                i += 1
                scanned += 1
            }
            return TakePair(clip: clip, take: nil, offsetSeconds: nil, confidence: nil, status: .unpaired)
        }
    }

    /// Sample-accurate offset of the clip inside the WAV: coarse 1 ms envelope search around `estimate`,
    /// then a finer envelope search at 48 kHz resolution within ±50 ms of the coarse result.
    public static func offset(clip: URL, wav: URL, around estimate: Double, window: Double = 10) async throws -> (offset: Double, confidence: Double) {
        let coarseRate = 8000.0, hop = 8, win = 160        // 1 ms envelope steps, 20 ms RMS windows
        async let a8 = AudioDecoder.monoSamples(url: wav, sampleRate: coarseRate)
        async let b8 = AudioDecoder.monoSamples(url: clip, sampleRate: coarseRate)
        let ea = Correlation.envelope(try await a8, window: win, hop: hop)
        let eb = Correlation.envelope(try await b8, window: win, hop: hop)
        let centre = Int(estimate * 1000)
        let span = Int(window * 1000)
        guard let coarse = Correlation.bestLag(a: ea, b: eb, lags: (centre - span) ... (centre + span)) else {
            throw Error.noCorrelation
        }
        // Fine stage (deviation from brief): correlating raw 48 kHz samples is ambiguous for a periodic
        // tone — a 440 Hz carrier repeats every ~109 samples at 48 kHz, so the brief's raw-sample search
        // locked onto a neighbouring cycle (confirmed empirically: fine lag consistently landed 109 or
        // 218 samples from the true alignment, with a low fine confidence of ~0.14 that the code then
        // discarded in favour of the coarse confidence). Correlating 1 ms RMS envelopes at 48 kHz
        // resolution (hop 1) keeps sample-accurate timing for the transient (the noise burst) while
        // removing the carrier's periodicity, so it can no longer lock onto a neighbouring cycle.
        let fineRate = 48000.0
        async let a48 = AudioDecoder.monoSamples(url: wav, sampleRate: fineRate)
        async let b48 = AudioDecoder.monoSamples(url: clip, sampleRate: fineRate)
        let eb48 = Correlation.envelope(Array(try await b48.prefix(Int(10 * fineRate))), window: 48, hop: 1)
        let c = coarse.lag * Int(fineRate) / 1000
        // The coarse stage already narrows the wav down to roughly where the clip starts; only decoding
        // is unavoidable (AudioDecoder always reads the whole file), but enveloping (and keeping in
        // memory) the full 48 kHz array — hundreds of MB on a 10-minute take — is not. Slice down to the
        // ±50 ms fine-search window plus a 100 ms margin either side before enveloping, then shift the
        // fine lag (which comes back relative to the slice) by the slice's start to land back in the
        // WAV's own sample domain.
        let margin = 4800   // 100 ms at 48 kHz
        let sliceStart = max(0, c - 2400 - margin)
        let sliceLength = eb48.count + 4800 + 2 * margin
        let wavSamples = try await a48
        let sliceEnd = min(wavSamples.count, sliceStart + sliceLength)
        let slice = sliceStart < sliceEnd ? Array(wavSamples[sliceStart ..< sliceEnd]) : []
        let ea48 = Correlation.envelope(slice, window: 48, hop: 1)
        let localLags = (c - 2400 - sliceStart) ... (c + 2400 - sliceStart)
        let fine = Correlation.bestLag(a: ea48, b: eb48, lags: localLags, minOverlap: min(eb48.count, Int(fineRate)))
        let lag = fine.map { $0.lag + sliceStart } ?? c
        return (Double(lag) / fineRate, coarse.confidence)
    }
}
