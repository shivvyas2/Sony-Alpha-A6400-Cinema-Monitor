#if os(macOS)
import AVFoundation
import Combine

/// One WAV per camera take, opened on the REC press with pre-roll and closed after the camera stops.
/// All file work happens on `queue`; the audio thread only hands buffers to `AudioInput`.
public final class TakeRecorder {
    public static let prerollSeconds = 3.0
    public static let postRollSeconds = 1.0

    public enum Error: Swift.Error, LocalizedError {
        case busy, notArmed
        public var errorDescription: String? { self == .busy ? "A take is already recording" : "No audio input is armed" }
    }

    public private(set) var current: TakeRecord?
    public private(set) var log: TakeLog
    public var onChange: ((TakeRecord) -> Void)?
    public var isRecording: Bool { current != nil }

    private let input: AudioInput
    private let dayFolder: URL
    private let postRoll: Double
    private let queue = DispatchQueue(label: "CinemaHUD.audio.takes", qos: .userInitiated)
    private var file: AVAudioFile?
    private var subscription: AnyCancellable?
    private var writeError: String?

    public init(input: AudioInput, dayFolder: URL, postRoll: Double = TakeRecorder.postRollSeconds) {
        self.input = input; self.dayFolder = dayFolder; self.postRoll = postRoll
        log = TakeLog.load(from: dayFolder)
    }

    public func begin(label: TakeLabel, metadata: TakeMetadata, pressedAt: Date) throws {
        guard current == nil else { throw Error.busy }
        guard input.sampleRate > 0 else { throw Error.notArmed }
        let audioFolder = dayFolder.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        let name = DayFolder.uniqueWAVName(stem: label.fileStem, in: audioFolder)
        let url = audioFolder.appendingPathComponent(name)
        let pre = input.preroll(seconds: Self.prerollSeconds)
        let channels = Int(pre.format.channelCount)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: input.sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        writeError = nil
        let prerollSeconds = Double(pre.frameLength) / input.sampleRate
        let record = TakeRecord(id: url.deletingPathExtension().lastPathComponent, label: label, wavPath: "audio/\(name)",
                                pressedAt: pressedAt, confirmedStart: nil, confirmedStop: nil, prerollSeconds: prerollSeconds,
                                sampleRate: input.sampleRate, channelNames: input.channelNames, metadata: metadata, outcome: .recording)
        current = record
        queue.async { [weak self] in self?.write(pre) }
        subscription = input.subscribe { [weak self] buffer in
            self?.queue.async { self?.write(buffer) }
        }
        update(record)
    }

    public func cameraStarted(at date: Date) {
        guard var r = current else { return }
        r.confirmedStart = date
        current = r
        update(r)
    }

    public func cameraStopped(at date: Date) {
        guard var r = current else { return }
        r.confirmedStop = date
        current = r
        let delay = postRoll
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.close(outcome: .complete) }
    }

    public func abort(reason: TakeRecord.Outcome) {
        guard current != nil else { return }
        queue.async { [weak self] in self?.close(outcome: reason, deleteFile: true) }
    }

    // MARK: Queue-side

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let file, writeError == nil else { return }
        do { try file.write(from: buffer) } catch {
            writeError = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.abortAfterWriteFailure(error.localizedDescription) }
        }
    }

    private func abortAfterWriteFailure(_ message: String) {
        queue.async { [weak self] in self?.close(outcome: .writeFailed(message), deleteFile: false) }
    }

    private func close(outcome: TakeRecord.Outcome, deleteFile: Bool = false) {
        DispatchQueue.main.sync { subscription?.cancel(); subscription = nil }
        guard var r = DispatchQueue.main.sync(execute: { current }) else { return }
        file = nil                                             // closes the WAV
        let url = dayFolder.appendingPathComponent(r.wavPath)
        let finalizeFile: Bool
        switch outcome { case .complete, .interrupted: finalizeFile = true; default: finalizeFile = false }
        if deleteFile {
            try? FileManager.default.removeItem(at: url)
        } else if finalizeFile {
            let first = r.firstSampleDate
            let bext = BroadcastWave.Bext(description: r.id, originator: "CinemaHUD", originatorReference: r.id,
                                          originationDate: DayFolder.dayString(first),
                                          originationTime: Self.clock(first), timeReference: BroadcastWave.timeReference(for: first, sampleRate: r.sampleRate),
                                          codingHistory: "A=PCM,F=\(Int(r.sampleRate)),W=24,M=\(r.channelNames.count == 1 ? "mono" : "stereo"),T=CinemaHUD")
            let ixml = BroadcastWave.ixml(project: r.metadata.project, scene: r.metadata.scene, take: r.label.clip,
                                          tape: String(format: "%04d", r.label.reel), fileUID: r.id, fps: r.metadata.projectFPS, trackNames: r.channelNames)
            try? BroadcastWave.finalize(url: url, bext: bext, ixml: ixml)
        }
        r.outcome = outcome
        DispatchQueue.main.sync {
            current = nil
            update(r)
        }
    }

    private func update(_ record: TakeRecord) {
        log.upsert(record)
        try? log.save(to: dayFolder)
        onChange?(record)
    }

    private static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
#endif
