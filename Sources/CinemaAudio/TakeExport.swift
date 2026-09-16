import AVFoundation
import Accelerate

public enum TakeExport {
    public enum Error: Swift.Error, LocalizedError {
        case noVideoTrack, exportFailed(String)
        public var errorDescription: String? {
            switch self { case .noVideoTrack: return "The clip has no video track"; case .exportFailed(let s): return "Export failed: \(s)" }
        }
    }

    public static func outputs(for clip: ClipInfo, take: TakeRecord, in syncedFolder: URL) -> (wav: URL, mov: URL) {
        (syncedFolder.appendingPathComponent("\(take.label.fileStem).wav"),
         syncedFolder.appendingPathComponent("\(clip.name)_synced.mov"))
    }

    /// The WAV from `offset` for `duration` seconds, silence-padded, same format, with bext/iXML rewritten.
    public static func trimmedWAV(wav: URL, offset: Double, duration: Double, take: TakeRecord?, to out: URL) throws {
        let src = try AVAudioFile(forReading: wav)
        let rate = src.fileFormat.sampleRate
        let channels = src.processingFormat.channelCount
        var settings = src.fileFormat.settings
        settings[AVLinearPCMBitDepthKey] = 24; settings[AVLinearPCMIsFloatKey] = false; settings[AVLinearPCMIsNonInterleaved] = false
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        // The AVAudioFile must be released (closed) before BroadcastWave.finalize runs, so the copy runs in its own scope.
        func writeSamples() throws {
            let dst = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
            let total = Int(duration * rate)
            let start = Int(offset * rate)
            var written = 0
            let chunk = 48000
            while written < total {
                let n = min(chunk, total - written)
                let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
                buf.frameLength = AVAudioFrameCount(n)
                for c in 0 ..< Int(channels) { vDSP_vclr(buf.floatChannelData![c], 1, vDSP_Length(n)) }   // explicit silence
                let pos = start + written
                if pos >= 0, pos < Int(src.length) {
                    src.framePosition = AVAudioFramePosition(pos)
                    let avail = min(n, Int(src.length) - pos)
                    let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(avail))!
                    try src.read(into: part, frameCount: AVAudioFrameCount(avail))
                    for c in 0 ..< Int(channels) { buf.floatChannelData![c].update(from: part.floatChannelData![c], count: Int(part.frameLength)) }
                }
                try dst.write(from: buf)
                written += n
            }
        }
        try writeSamples()
        let ref = (try? BroadcastWave.readBext(url: wav)?.timeReference) ?? 0
        let shifted = ref + UInt64(max(0, offset) * rate)
        // Deviation from the brief: the brief's sample copied the source WAV's iXML verbatim, but the
        // spec text says "iXML from the take" and the test asserts `<TAKE>1</TAKE>` in the output even
        // though the source WAV's iXML in the test is the bare "<BWFXML/>" placeholder (no TAKE field).
        // Build the iXML from the take's own metadata instead, falling back to the source's iXML (or the
        // placeholder) when no take is given.
        let ixml: String
        if let take {
            ixml = BroadcastWave.ixml(project: take.metadata.project, scene: take.metadata.scene, take: take.label.clip,
                                      tape: "\(take.label.cameraIndex)_\(String(format: "%04d", take.label.reel))",
                                      fileUID: take.id, fps: take.metadata.projectFPS, trackNames: take.channelNames)
        } else {
            ixml = (try? BroadcastWave.readIXML(url: wav)) ?? "<BWFXML/>"
        }
        let stem = out.deletingPathExtension().lastPathComponent
        let day = take.map { DayFolder.dayString($0.firstSampleDate) } ?? DayFolder.dayString(Date())
        let bext = BroadcastWave.Bext(description: stem, originator: "CinemaHUD", originatorReference: take?.id ?? "", originationDate: day,
                                      originationTime: originationTime(shifted, rate: rate), timeReference: shifted,
                                      codingHistory: "A=PCM,F=\(Int(rate)),W=24,M=\(channels == 1 ? "mono" : "stereo"),T=CinemaHUD")
        try BroadcastWave.finalize(url: out, bext: bext, ixml: ixml)
    }

    static func originationTime(_ samplesSinceMidnight: UInt64, rate: Double) -> String {
        let s = Int(Double(samplesSinceMidnight) / rate)
        return String(format: "%02d:%02d:%02d", s / 3600 % 24, s / 60 % 60, s % 60)
    }

    /// Video passthrough + WAV (track 1, from `offset`) + the clip's own audio (track 2), as .mov.
    public static func movie(clip: URL, wav: URL, offset: Double, to out: URL) async throws {
        let clipAsset = AVURLAsset(url: clip), wavAsset = AVURLAsset(url: wav)
        guard let video = try await clipAsset.loadTracks(withMediaType: .video).first else { throw Error.noVideoTrack }
        let duration = try await clipAsset.load(.duration)
        let comp = AVMutableComposition()
        let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)
        v.preferredTransform = try await video.load(.preferredTransform)

        if let wavTrack = try await wavAsset.loadTracks(withMediaType: .audio).first {
            let wavDuration = try await wavAsset.load(.duration)
            let wavTimescale = try await wavTrack.load(.naturalTimeScale)
            let start = CMTime(seconds: max(0, offset), preferredTimescale: wavTimescale)
            let available = CMTimeSubtract(wavDuration, start)
            // Clamp to [.zero, duration]: an offset past the WAV's end would otherwise make `available`
            // (and `take`) negative, and `insertEmptyTimeRange` with a negative start throws an uncaught
            // ObjC exception.
            let take = CMTimeMaximum(.zero, CMTimeMinimum(duration, available))
            // Deviation from the brief: when `take == .zero` (offset at or past the WAV's end) the brief's
            // structure still adds an audio track whose only content is `insertEmptyTimeRange` — i.e. no
            // real media segment at all. AVAssetExportSessionPresetPassthrough silently drops such a track
            // (confirmed empirically: the exported .mov then has 1 audio track, not 2), so the composition
            // would end up two tracks short of what the interface promises whenever offset ends up beyond
            // the WAV. Skip adding track 1 entirely in that case — the clip's own audio (track 2, below)
            // still carries the audio, and the output has 1 audio track instead of 2.
            if take > .zero {
                let a1 = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try a1.insertTimeRange(CMTimeRange(start: start, duration: take), of: wavTrack, at: .zero)
                if take < duration { a1.insertEmptyTimeRange(CMTimeRange(start: take, duration: CMTimeSubtract(duration, take))) }
            }
        }
        if let camAudio = try await clipAsset.loadTracks(withMediaType: .audio).first {
            let a2 = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try a2.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: camAudio, at: .zero)
        }

        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw Error.exportFailed("no session") }
        session.outputURL = out
        session.outputFileType = .mov
        session.metadata = try await clipAsset.load(.metadata)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.exportAsynchronously { c.resume() } }
        if session.status != .completed { throw Error.exportFailed(session.error?.localizedDescription ?? "\(session.status.rawValue)") }
    }
}
