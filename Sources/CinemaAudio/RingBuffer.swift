import AVFoundation

/// Fixed-length per-channel Float32 history of the input, so a take can start before the REC press.
/// `write` is called from the audio tap, `read` from the recorder; both are short and lock-guarded.
public final class RingBuffer {
    public let format: AVAudioFormat
    public let capacity: Int
    private var storage: [[Float]]
    private var head = 0            // next write index
    private var filled = 0          // frames valid (≤ capacity)
    private let lock = NSLock()

    public init(channels: Int, sampleRate: Double, seconds: Double) {
        format = PCMFormat.float(channels: channels, sampleRate: sampleRate)
        capacity = max(1, Int(sampleRate * seconds))
        storage = Array(repeating: [Float](repeating: 0, count: capacity), count: channels)
    }

    public func write(_ buffer: AVAudioPCMBuffer) {
        guard let src = buffer.floatChannelData else { return }
        let channels = min(storage.count, Int(buffer.format.channelCount))
        var frames = Int(buffer.frameLength)
        var srcOffset = 0
        if frames > capacity { srcOffset = frames - capacity; frames = capacity }   // only the tail can survive
        lock.lock(); defer { lock.unlock() }
        var remaining = frames
        var offset = srcOffset
        while remaining > 0 {
            let n = min(remaining, capacity - head)
            for c in 0 ..< channels {
                storage[c].withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.advanced(by: head).update(from: src[c].advanced(by: offset), count: n)
                }
            }
            head = (head + n) % capacity
            offset += n; remaining -= n
        }
        filled = min(capacity, filled + frames)
    }

    /// The most recent `lastSeconds` of audio (clamped to what is stored), oldest frame first.
    /// The output buffer is allocated before the lock is taken so the audio-thread writer never waits on an allocation.
    public func read(lastSeconds: Double) -> AVAudioPCMBuffer {
        let requested = max(0, Int(lastSeconds * format.sampleRate))
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, min(capacity, requested))))!
        lock.lock(); defer { lock.unlock() }
        let want = min(filled, min(capacity, requested))
        out.frameLength = AVAudioFrameCount(want)
        guard want > 0, let dst = out.floatChannelData else { return out }
        let start = (head - want + capacity) % capacity
        let first = min(want, capacity - start)
        for c in 0 ..< storage.count {
            storage[c].withUnsafeBufferPointer { s in
                dst[c].update(from: s.baseAddress!.advanced(by: start), count: first)
                if want > first { dst[c].advanced(by: first).update(from: s.baseAddress!, count: want - first) }
            }
        }
        return out
    }
}
