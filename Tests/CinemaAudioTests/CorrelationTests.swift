import XCTest
@testable import CinemaAudio

final class CorrelationTests: XCTestCase {
    func noise(_ n: Int, seed: UInt64) -> [Float] {
        var s = seed
        return (0 ..< n).map { _ in s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: s >> 11) % 2000) / 1000 - 1 }
    }

    func testEnvelopeLengthAndValue() {
        let x = [Float](repeating: 0.5, count: 1000)
        let e = Correlation.envelope(x, window: 100, hop: 10)
        XCTAssertEqual(e.count, 91)
        XCTAssertEqual(e[0], 0.5, accuracy: 1e-4)
        XCTAssertEqual(Correlation.envelope([Float](repeating: 0, count: 50), window: 100, hop: 10).count, 0)
    }

    func testFindsKnownLag() throws {
        let a = noise(5000, seed: 1)
        let b = Array(a[1234 ..< 4000])
        let m = try XCTUnwrap(Correlation.bestLag(a: a, b: b, lags: -2000 ... 2000))
        XCTAssertEqual(m.lag, 1234)
        XCTAssertGreaterThan(m.score, 0.99)
        XCTAssertGreaterThanOrEqual(m.confidence, 0.9)
    }

    func testFindsNegativeLagWithPartialOverlap() throws {
        let a = noise(3000, seed: 2)
        var b = noise(500, seed: 3); b.append(contentsOf: a[0 ..< 2500])   // b starts 500 before a
        let m = try XCTUnwrap(Correlation.bestLag(a: a, b: b, lags: -1000 ... 1000))
        XCTAssertEqual(m.lag, -500)
    }

    func testUncorrelatedIsLowConfidence() throws {
        let m = try XCTUnwrap(Correlation.bestLag(a: noise(5000, seed: 4), b: noise(3000, seed: 5), lags: -1000 ... 1000))
        XCTAssertLessThan(m.confidence, 0.5)
    }

    func testEmptyRangeOrSignalsReturnsNil() {
        XCTAssertNil(Correlation.bestLag(a: [], b: [1, 2], lags: 0 ... 1))
        XCTAssertNil(Correlation.bestLag(a: noise(100, seed: 6), b: noise(100, seed: 7), lags: 500 ... 600))
    }
}
