import XCTest
import CoreGraphics
@testable import CinemaUI

final class FrameProcessorMistTests: XCTestCase {
    /// 256×256 black with a 24-px white square in the middle.
    private func dot() -> CGImage {
        let w = 256, h = 256
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 116, y: 116, width: 24, height: 24))
        return ctx.makeImage()!
    }
    private func luma(_ img: CGImage, x: Int, y: Int) -> Int {
        var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = (y * img.width + x) * 4
        return (Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) / 3
    }

    func testMistHalosTheHighlightAndKeepsGeometry() throws {
        let p = FrameProcessor()
        let src = dot()
        let off = try XCTUnwrap(p.process(src, peaking: false, zebra: false, zebraLevel: 1, mist: 0))
        let on = try XCTUnwrap(p.process(src, peaking: false, zebra: false, zebraLevel: 1, mist: 1))
        XCTAssertEqual(on.width, src.width); XCTAssertEqual(on.height, src.height)
        // 6 px outside the square: black without mist, lit by the halo with it.
        XCTAssertEqual(luma(off, x: 146, y: 128), 0)
        XCTAssertGreaterThan(luma(on, x: 146, y: 128), 20)
        // The square itself stays bright and the far corner stays black.
        XCTAssertGreaterThan(luma(on, x: 128, y: 128), 200)
        XCTAssertEqual(luma(on, x: 10, y: 10), 0)
    }
}
