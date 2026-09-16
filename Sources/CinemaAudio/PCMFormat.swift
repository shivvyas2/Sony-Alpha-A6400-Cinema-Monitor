import AVFoundation

/// Non-interleaved Float32 PCM for any channel count. `standardFormatWithSampleRate:channels:` returns
/// nil above two channels on current SDKs, so wider layouts use a discrete channel layout tag.
enum PCMFormat {
    static func float(channels: Int, sampleRate: Double) -> AVAudioFormat {
        let n = AVAudioChannelCount(max(1, channels))
        if n <= 2, let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: n) { return f }
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | n)!
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
    }
}
