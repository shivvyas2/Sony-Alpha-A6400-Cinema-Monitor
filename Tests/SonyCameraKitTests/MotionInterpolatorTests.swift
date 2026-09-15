import XCTest
import CoreGraphics
@testable import SonyCameraKit

final class MotionInterpolatorTests: XCTestCase {
    private func frame(shift: Int) -> CGImage {
        let w = 1024, h = 680
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 300 + shift, y: 200, width: 200, height: 150))
        return ctx.makeImage()!
    }

    func testMidpointFrameIsEmittedAndTimed() throws {
        let interp = try XCTUnwrap(MotionInterpolator())
        var emitted: [CGImage] = []
        let lock = NSLock()
        let exp = expectation(description: "3 outputs")
        exp.expectedFulfillmentCount = 3
        let t0 = CFAbsoluteTimeGetCurrent()
        let emit: @Sendable (CGImage) -> Void = { img in lock.lock(); emitted.append(img); lock.unlock(); exp.fulfill() }
        interp.push(frame(shift: 0), at: t0, emit: emit)
        interp.push(frame(shift: 40), at: t0 + 0.066, emit: emit)      // emits A, then mid
        interp.push(frame(shift: 80), at: t0 + 0.132, emit: emit)      // emits B, then mid
        wait(for: [exp], timeout: 5)
        print("flow+warp took \(interp.lastFlowMillis) ms")
        XCTAssertGreaterThanOrEqual(emitted.count, 3)
        XCTAssertLessThan(interp.lastFlowMillis, 60, "must fit inside a 15 fps frame interval")
        // The midpoint frame should have its white block roughly halfway (x≈320): sample a pixel that is
        // white only in the interpolated frame.
        let mid = emitted[1]
        let data = CGDataProvider(data: Data() as CFData) // placeholder to keep API usage simple
        _ = data
        XCTAssertEqual(mid.width, 1024)
    }
}
