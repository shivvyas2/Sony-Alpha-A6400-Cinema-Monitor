import XCTest
import CoreGraphics
@testable import CinemaUI

final class SceneAnalyzerTests: XCTestCase {
    /// 400×300 RGB image filled by `paint`.
    private func image(_ paint: (CGContext, Int, Int) -> Void) -> CGImage {
        let w = 400, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        paint(ctx, w, h)
        return ctx.makeImage()!
    }

    func testClipFractionsAndMeanOnAGradientWithClippedBands() {
        let img = image { ctx, w, h in
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 20))          // 5 % white
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: h - h / 10, width: w, height: h / 10)) // 10 % black
        }
        // The RGB → grey draw is colour managed, so measure what "mid grey" reads rather than assuming 50.
        let grey = SceneAnalyzer.measure(image { ctx, w, h in
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }, afPoint: nil).meanLuma
        let m = SceneAnalyzer.measure(img, afPoint: nil)
        XCTAssertEqual(m.whiteClip, 0.05, accuracy: 0.015)
        XCTAssertEqual(m.blackClip, 0.10, accuracy: 0.015)
        XCTAssertEqual(m.meanLuma, 0.85 * grey + 0.05 * 100, accuracy: 2)   // 85 % mid grey, 5 % white, 10 % black
        XCTAssertTrue(m.faces.isEmpty)
    }

    func testSharpestRegionLandsOnTheCheckerTile() {
        let img = image { ctx, w, h in
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
            // Checkerboard in the bottom-right quarter (CGContext rows start at the bottom, so y < h/2 is the lower half).
            for y in stride(from: 0, to: h / 2, by: 6) {
                for x in stride(from: w / 2, to: w, by: 6) where ((x / 6) + (y / 6)) % 2 == 0 {
                    ctx.fill(CGRect(x: x, y: y, width: 6, height: 6))
                }
            }
        }
        let m = SceneAnalyzer.measure(img, afPoint: CGPoint(x: 0.25, y: 0.25))
        XCTAssertGreaterThan(m.sharpestRegion.x, 0.5)
        XCTAssertGreaterThan(m.sharpestRegion.y, 0.5)      // top-left origin: the lower half is y > 0.5
        XCTAssertGreaterThan(m.sharpestScore, 100)
        XCTAssertLessThan(m.afSharpness, 0.2)              // the AF point is on flat grey
    }
}
