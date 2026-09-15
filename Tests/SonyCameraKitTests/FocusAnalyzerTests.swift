import XCTest
import CoreGraphics
@testable import SonyCameraKit

final class FocusAnalyzerTests: XCTestCase {
    /// 400×300: left half is a 6-px checkerboard (sharp), right half is flat grey (no detail).
    private func testImage() -> CGImage {
        let w = 400, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        for y in stride(from: 0, to: h, by: 6) {
            for x in stride(from: 0, to: w / 2, by: 6) where ((x / 6) + (y / 6)) % 2 == 0 {
                ctx.fill(CGRect(x: x, y: y, width: 6, height: 6))
            }
        }
        return ctx.makeImage()!
    }

    func testSharpRegionScoresFarAboveFlatRegion() throws {
        let l = try XCTUnwrap(FocusAnalyzer.luma(of: testImage(), maxLongEdge: 400))
        let sharp = FocusAnalyzer.sharpness(l, in: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.6))
        let flat = FocusAnalyzer.sharpness(l, in: CGRect(x: 0.6, y: 0.2, width: 0.3, height: 0.6))
        XCTAssertGreaterThan(sharp, 100)
        XCTAssertLessThan(flat, 1)
    }

    func testVerdictThresholds() {
        XCTAssertEqual(FocusAnalyzer.verdict(region: 90, peak: 100), .inFocus)
        XCTAssertEqual(FocusAnalyzer.verdict(region: 50, peak: 100), .soft)
        XCTAssertEqual(FocusAnalyzer.verdict(region: 10, peak: 100), .missed)
        XCTAssertEqual(FocusAnalyzer.verdict(region: 0, peak: 0), .missed)
    }

    func testAnalyzeFindsFocusOnTheLeftAndMissOnTheRight() throws {
        let img = testImage()
        let hit = try XCTUnwrap(FocusAnalyzer.analyze(img, afPoint: CGPoint(x: 0.25, y: 0.5)))
        XCTAssertEqual(hit.verdict, .inFocus)
        XCTAssertLessThan(hit.peakPoint.x, 0.5)
        let miss = try XCTUnwrap(FocusAnalyzer.analyze(img, afPoint: CGPoint(x: 0.8, y: 0.5)))
        XCTAssertEqual(miss.verdict, .missed)
        XCTAssertLessThan(miss.ratio, 0.05)
        XCTAssertLessThan(miss.peakPoint.x, 0.5)   // tells the user where focus actually landed
    }

    func testLumaRespectsTopLeftOrigin() throws {
        // Dark top row, light elsewhere: row 0 of the luma plane must be the dark one.
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 7, width: 8, height: 1))   // CG y-up: top row
        let l = try XCTUnwrap(FocusAnalyzer.luma(of: ctx.makeImage()!, maxLongEdge: 8))
        XCTAssertLessThan(l.pixels[0], 10)
        XCTAssertGreaterThan(l.pixels[7 * 8], 240)
    }
}
