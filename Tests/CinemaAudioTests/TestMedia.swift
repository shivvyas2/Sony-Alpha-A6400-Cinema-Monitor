import AVFoundation

enum TestMedia {
    static func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CinemaAudioTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 24-bit WAV of a sine (or silence when amplitude is 0); `mark` adds a 50 ms noise burst at that second.
    static func writeWAV(url: URL, seconds: Double, sampleRate: Double = 48000, channels: Int = 1,
                         amplitude: Float = 0.5, frequency: Float = 440, burstAt: Double? = nil) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(seconds * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        var rng = SystemRandomNumberGenerator()
        for i in 0 ..< frames {
            var v = amplitude * sin(Float(i) * 2 * .pi * frequency / Float(sampleRate))
            if let b = burstAt, Double(i) / sampleRate >= b, Double(i) / sampleRate < b + 0.05 { v = Float.random(in: -0.9 ... 0.9, using: &rng) }
            for c in 0 ..< channels { buf.floatChannelData![c][i] = v }
        }
        try file.write(from: buf)
    }
}
