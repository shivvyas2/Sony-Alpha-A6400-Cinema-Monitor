import XCTest
import CoreGraphics
import ImageIO
@testable import SonyCameraKit

final class ShotQualityTests: XCTestCase {
    /// Boxes of many sizes on mid grey, blurred by averaging `blurX`×`blurY` pixels, plus noise; 1200×800.
    private func image(blurX: Int = 1, blurY: Int = 1, noise: Double = 0, gain: Double = 1) -> CGImage {
        let w = 1200, h = 800
        var rng = SystemRandomLike(seed: 7)
        var a = [Double](repeating: 118, count: w * h)
        for _ in 0 ..< 500 {
            let x = Int(rng.next() * Double(w - 60)), y = Int(rng.next() * Double(h - 60)), s = 12 + Int(rng.next() * 40)
            let v = rng.next() > 0.5 ? 210.0 : 35.0
            for yy in y ..< y + s { for xx in x ..< x + s { a[yy * w + xx] = v } }
        }
        // keep a quiet strip so grain has somewhere to be measured
        for y in 0 ..< h { for x in 0 ..< 200 { a[y * w + x] = 118 } }
        func box(_ n: Int, stride st: Int, lines: Int, length: Int, lineStep: Int) {
            guard n > 1 else { return }
            for l in 0 ..< lines {
                let base = l * lineStep
                let src = (0 ..< length).map { a[base + $0 * st] }
                for i in 0 ..< length {
                    let lo = max(0, i - n / 2), hi = min(length - 1, lo + n - 1)
                    a[base + i * st] = src[lo ... hi].reduce(0, +) / Double(hi - lo + 1)
                }
            }
        }
        box(blurX, stride: 1, lines: h, length: w, lineStep: w)
        box(blurY, stride: w, lines: w, length: h, lineStep: 1)
        var px = [UInt8](repeating: 0, count: w * h)
        for i in a.indices {
            let n = noise > 0 ? noise * (rng.next() + rng.next() + rng.next() + rng.next() - 2) * 1.732 : 0
            px[i] = UInt8(max(0, min(255, a[i] * gain + n)))
        }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }
    private struct SystemRandomLike { var s: UInt64; init(seed: UInt64) { s = seed }
        mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 33) / Double(1 << 31) } }

    private func q(_ i: CGImage, af: CGPoint? = nil) throws -> ShotQuality { try XCTUnwrap(ShotQualityAnalyzer.analyze(i, afPoint: af)) }

    func testSharpCleanFrameIsGoodOnAllThree() throws {
        let r = try q(image())
        XCTAssertEqual(r.blur, .sharp); XCTAssertEqual(r.exposure, .good); XCTAssertEqual(r.grain, .low)
        XCTAssertEqual(r.overall, .good)
    }

    /// The old verdict compared the AF area with the frame's own best area, so a wholly blurred frame passed.
    func testWhollyBlurredFrameIsCaught() throws {
        XCTAssertEqual(try q(image(blurX: 14, blurY: 14)).blur, .blurred)
        XCTAssertEqual(try q(image(blurX: 14, blurY: 14), af: CGPoint(x: 0.6, y: 0.5)).blur, .blurred)
    }

    func testOneDirectionalSmearIsMotion() throws {
        XCTAssertEqual(try q(image(blurX: 10)).blur, .motion)
        XCTAssertEqual(try q(image(blurY: 10)).blur, .motion)
    }

    func testUnderAndOverExposure() throws {
        let under = try q(image(gain: 0.35))
        XCTAssertEqual(under.exposure, .under); XCTAssertLessThan(under.stops, -1); XCTAssertTrue(under.exposureText.hasPrefix("UNDER"))
        XCTAssertNotEqual(try q(image(gain: 2.6)).exposure, .good)
    }

    func testGrainGrowsWithNoise() throws {
        let low = try q(image(noise: 0.5)), mid = try q(image(noise: 2.4)), high = try q(image(noise: 8))
        XCTAssertEqual(low.grain, .low); XCTAssertEqual(mid.grain, .moderate); XCTAssertEqual(high.grain, .high)
        XCTAssertEqual(high.blur, .sharp)          // noise must not read as blur, nor blur as sharp
        XCTAssertEqual(try q(image(blurX: 14, blurY: 14, noise: 8)).blur, .blurred)
    }

    func testFlatFrameSaysItCannotTell() throws {
        let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 600,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertEqual(try q(ctx.makeImage()!).blur, .unknown)
    }

    func testOrientationMapping() {
        // Camera held vertically (EXIF 6): the sensor's top-left corner shows at the top right.
        XCTAssertEqual(ShotQualityAnalyzer.displayPoint(CGPoint(x: 0, y: 0), .right), CGPoint(x: 1, y: 0))
        XCTAssertEqual(ShotQualityAnalyzer.displayPoint(CGPoint(x: 0, y: 0), .left), CGPoint(x: 0, y: 1))
        let r = ShotQualityAnalyzer.unrotate(CGRect(x: 0.8, y: 0, width: 0.2, height: 0.1), .right)
        XCTAssertEqual(r.minX, 0, accuracy: 1e-9); XCTAssertEqual(r.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(r.width, 0.1, accuracy: 1e-9); XCTAssertEqual(r.height, 0.2, accuracy: 1e-9)
    }
}
