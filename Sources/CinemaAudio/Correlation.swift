import Accelerate

/// Waveform alignment: a coarse RMS envelope makes the search cheap and robust to different mics,
/// then a normalised cross-correlation finds where the clip's audio sits inside the WAV.
public enum Correlation {
    public struct Match: Equatable, Sendable {
        public var lag: Int
        public var score: Float        // normalised correlation at the peak, −1…1
        public var confidence: Double  // 0…1
    }

    /// RMS over `window` samples every `hop` samples.
    public static func envelope(_ x: [Float], window: Int, hop: Int) -> [Float] {
        guard x.count >= window, window > 0, hop > 0 else { return [] }
        let n = (x.count - window) / hop + 1
        var out = [Float](repeating: 0, count: n)
        x.withUnsafeBufferPointer { p in
            for i in 0 ..< n { vDSP_rmsqv(p.baseAddress!.advanced(by: i * hop), 1, &out[i], vDSP_Length(window)) }
        }
        return out
    }

    /// Best lag such that b[i] ≈ a[i + lag]. Both signals are mean-removed. Lags whose overlap is
    /// shorter than `minOverlap` (default half of b) are skipped.
    public static func bestLag(a: [Float], b: [Float], lags: ClosedRange<Int>, minOverlap: Int? = nil) -> Match? {
        guard !a.isEmpty, !b.isEmpty else { return nil }
        let a = centred(a), b = centred(b)
        let need = minOverlap ?? max(1, b.count / 2)
        // Prefix sums of squares give per-lag norms in O(1).
        let a2 = prefixSquares(a), b2 = prefixSquares(b)
        var scores: [(lag: Int, score: Float)] = []
        scores.reserveCapacity(lags.count)
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for lag in lags {
                    let i0 = max(0, -lag)                       // first b index
                    let i1 = min(b.count, a.count - lag)        // one past last b index
                    let n = i1 - i0
                    guard n >= need else { continue }
                    var dot: Float = 0
                    vDSP_dotpr(pb.baseAddress!.advanced(by: i0), 1, pa.baseAddress!.advanced(by: i0 + lag), 1, &dot, vDSP_Length(n))
                    let na = a2[i0 + lag + n] - a2[i0 + lag], nb = b2[i1] - b2[i0]
                    let denom = (na * nb).squareRoot()
                    scores.append((lag, denom > 0 ? dot / denom : 0))
                }
            }
        }
        guard let best = scores.max(by: { $0.score < $1.score }) else { return nil }
        // z-score of the peak against every other lag outside a small exclusion zone.
        let exclusion = max(3, lags.count / 200)
        let rest = scores.filter { abs($0.lag - best.lag) > exclusion }.map(\.score)
        var confidence = 1.0
        if rest.count > 8 {
            let mean = rest.reduce(0, +) / Float(rest.count)
            let variance = rest.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(rest.count)
            let sigma = max(variance.squareRoot(), 1e-6)
            confidence = min(1, max(0, Double((best.score - mean) / sigma) / 10))
        }
        return Match(lag: best.lag, score: best.score, confidence: confidence)
    }

    private static func centred(_ x: [Float]) -> [Float] {
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
        var neg = -mean
        var out = [Float](repeating: 0, count: x.count)
        vDSP_vsadd(x, 1, &neg, &out, 1, vDSP_Length(x.count))
        return out
    }
    private static func prefixSquares(_ x: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: x.count + 1)
        var acc: Float = 0
        for i in x.indices { acc += x[i] * x[i]; out[i + 1] = acc }
        return out
    }
}
