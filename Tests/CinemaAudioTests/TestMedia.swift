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

    /// A short H.264 .mp4 with a 440 Hz stereo LPCM tone (16-bit) and an optional 50 ms noise burst.
    static func writeMovie(url: URL, seconds: Double, size: CGSize = CGSize(width: 320, height: 180), fps: Int = 24, burstAt: Double? = nil) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "TestMedia", code: 1) }
        writer.startSession(atSourceTime: .zero)

        // NOTE (deviation from brief): the brief's original loops polled `isReadyForMoreMediaData` in a
        // `while ... { Thread.sleep(...) }` spin from the calling thread, feeding all of the video first
        // and only then starting audio. Two independent problems showed up under real AVFoundation:
        //  1. Polling from the calling thread deadlocks when `writeMovie` runs inside an `async` test
        //     (a Swift-concurrency cooperative-pool thread) — `isReadyForMoreMediaData` never flips back
        //     to true once the writer's internal buffer fills. Apple's documented, deadlock-safe pattern
        //     is `requestMediaDataWhenReady(on:using:)` driving `append` from a callback on a dedicated
        //     serial queue, synchronized back to this (synchronous, throwing) function with a semaphore.
        //  2. Even with that fixed, writing video-to-completion before starting audio still hangs:
        //     AVAssetWriter throttles a track that gets too far ahead of its sibling track so it can
        //     interleave the container properly, and with only one track fed it stalls forever (confirmed
        //     with a debug harness — video stuck at a fixed frame count for 60+ seconds while
        //     `isReadyForMoreMediaData` stayed false and no track was progressing). Both inputs'
        //     `requestMediaDataWhenReady` callbacks are therefore registered before waiting on either
        //     semaphore, so video and audio are produced concurrently, as AVAssetWriter expects.
        // Output and the function's signature/behaviour are unchanged; only the feeding mechanism differs.
        let frames = Int(seconds * Double(fps))
        let videoQueue = DispatchQueue(label: "TestMedia.video")
        let videoDone = DispatchSemaphore(value: 0)
        var frameIndex = 0
        video.requestMediaDataWhenReady(on: videoQueue) {
            while video.isReadyForMoreMediaData {
                guard frameIndex < frames else {
                    video.markAsFinished()
                    videoDone.signal()
                    return
                }
                let i = frameIndex
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
                CVPixelBufferLockBaseAddress(pb!, [])
                let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt32.self)
                let stride = CVPixelBufferGetBytesPerRow(pb!) / 4
                let bar = i * Int(size.width) / max(1, frames)
                for y in 0 ..< Int(size.height) { for x in 0 ..< Int(size.width) { base[y * stride + x] = abs(x - bar) < 8 ? 0xFFFFFFFF : 0xFF202020 } }
                CVPixelBufferUnlockBaseAddress(pb!, [])
                adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
                frameIndex += 1
            }
        }

        // Audio in 4800-frame chunks.
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let total = Int(seconds * 48000)
        var rng = SystemRandomNumberGenerator()
        let audioQueue = DispatchQueue(label: "TestMedia.audio")
        let audioDone = DispatchSemaphore(value: 0)
        var pos = 0
        audio.requestMediaDataWhenReady(on: audioQueue) {
            while audio.isReadyForMoreMediaData {
                guard pos < total else {
                    audio.markAsFinished()
                    audioDone.signal()
                    return
                }
                let n = min(4800, total - pos)
                var bytes = [Int16](repeating: 0, count: n * 2)
                for i in 0 ..< n {
                    let t = Double(pos + i) / 48000
                    var v = 0.5 * sin(2 * .pi * 440 * t)
                    if let b = burstAt, t >= b, t < b + 0.05 { v = Double.random(in: -0.9 ... 0.9, using: &rng) }
                    bytes[i * 2] = Int16(v * 32767); bytes[i * 2 + 1] = bytes[i * 2]
                }
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 4, blockAllocator: nil, customBlockSource: nil,
                                                   offsetToData: 0, dataLength: n * 4, flags: 0, blockBufferOut: &block)
                _ = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: n * 4) }
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: n,
                    presentationTimeStamp: CMTime(value: CMTimeValue(pos), timescale: 48000), packetDescriptions: nil, sampleBufferOut: &sample)
                audio.append(sample!)
                pos += n
            }
        }
        videoDone.wait()
        audioDone.wait()

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if let e = writer.error { throw e }
    }
}
