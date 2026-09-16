// Sources/CinemaAudio/AudioDecoder.swift
import AVFoundation

/// Decodes any AVFoundation-readable audio (WAV, MP4/MOV tracks) to mono Float32 at `sampleRate`.
public enum AudioDecoder {
    public enum Error: Swift.Error { case noAudioTrack, readerFailed(String) }

    public static func monoSamples(url: URL, sampleRate: Double, trackIndex: Int? = nil) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Error.noAudioTrack }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output: AVAssetReaderOutput
        if let i = trackIndex {
            guard tracks.indices.contains(i) else { throw Error.noAudioTrack }
            output = AVAssetReaderTrackOutput(track: tracks[i], outputSettings: settings)
        } else {
            output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        }
        reader.add(output)
        guard reader.startReading() else { throw Error.readerFailed(reader.error?.localizedDescription ?? "start") }
        var out: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [Float](repeating: 0, count: length / 4)
            bytes.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            out.append(contentsOf: bytes)
        }
        if reader.status == .failed { throw Error.readerFailed(reader.error?.localizedDescription ?? "read") }
        return out
    }
}
