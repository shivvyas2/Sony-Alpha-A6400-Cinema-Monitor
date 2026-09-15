import XCTest
import CoreGraphics
@testable import SonyCameraKit

final class MotionInterpolatorTests: XCTestCase {
    private func frame(shift: Int, noise: Bool = false, seed: UInt64 = 1) -> CGImage {
        let w = 1024, h = 680
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 300 + shift, y: 200, width: 200, height: 150))
        if noise, let data = ctx.data {
            var rng = seed
            let p = data.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let n = Int((rng >> 33) % 41) - 20
                for c in 0 ..< 3 { p[i + c] = UInt8(max(0, min(255, Int(p[i + c]) + n))) }
            }
        }
        return ctx.makeImage()!
    }

    private func collect(_ interp: MotionInterpolator, frames: [CGImage], expected: Int, timeout: TimeInterval = 10) -> [CGImage] {
        let lock = NSLock()
        var emitted: [CGImage] = []
        let exp = expectation(description: "outputs"); exp.expectedFulfillmentCount = expected
        let t0 = CFAbsoluteTimeGetCurrent()
        for (i, f) in frames.enumerated() {
            interp.push(f, at: t0 + Double(i) * 0.066) { img in lock.lock(); emitted.append(img); lock.unlock(); exp.fulfill() }
        }
        wait(for: [exp], timeout: timeout)
        lock.lock(); defer { lock.unlock() }
        return emitted
    }

    func testDefaultIsPassThroughOnePerFrame() throws {
        let interp = try XCTUnwrap(MotionInterpolator())
        let out = collect(interp, frames: [frame(shift: 0), frame(shift: 40), frame(shift: 80)], expected: 3)
        XCTAssertEqual(out.count, 3)
    }

    func testFactor4EmitsThreeInBetweensPerPair() throws {
        let interp = try XCTUnwrap(MotionInterpolator())
        interp.factor = 4
        let out = collect(interp, frames: [frame(shift: 0), frame(shift: 40), frame(shift: 80)], expected: 8)
        XCTAssertEqual(out.count, 8)          // A, 3 mids, B, 3 mids
        print("factor 4: flow+3 warps took \(interp.lastFlowMillis) ms")
        XCTAssertLessThan(interp.lastFlowMillis, 66)
    }

    func testFactor8FitsInAFrameInterval() throws {
        let interp = try XCTUnwrap(MotionInterpolator())
        interp.factor = 8
        let out = collect(interp, frames: [frame(shift: 0), frame(shift: 40), frame(shift: 80)], expected: 16)
        XCTAssertEqual(out.count, 16)
        print("factor 8: flow+7 warps took \(interp.lastFlowMillis) ms")
        XCTAssertLessThan(interp.lastFlowMillis, 66)
    }

    private func noiseLevel(_ img: CGImage) -> Double {
        // std-dev of the grey background region (top-left 200x150), which should be flat.
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, sq = 0.0, n = 0.0
        for y in 0 ..< 150 { for x in 0 ..< 200 { let v = Double(p[(y * w + x) * 4 + 1]); sum += v; sq += v * v; n += 1 } }
        let mean = sum / n
        return (sq / n - mean * mean).squareRoot()
    }

    func testTemporalDenoiseReducesGrain() throws {
        let interp = try XCTUnwrap(MotionInterpolator())
        interp.factor = 1
        interp.denoise = 1
        let frames = (0 ..< 6).map { frame(shift: 0, noise: true, seed: UInt64($0 + 7)) }
        let before = noiseLevel(frames[5])
        let out = collect(interp, frames: frames, expected: 6)
        let after = noiseLevel(try XCTUnwrap(out.last))
        print("noise std-dev before \(before) after \(after)")
        XCTAssertLessThan(after, before * 0.7, "temporal NR should visibly reduce static grain")
    }
}
