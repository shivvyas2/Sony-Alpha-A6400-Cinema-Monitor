// Renders each PDF argument to a PNG at the given scale: render-pdf.swift <scale> <outdir> <pdf>...
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let scale = CGFloat(Double(args[1])!)
let outDir = URL(fileURLWithPath: args[2])
for path in args.dropFirst(3) {
    let url = URL(fileURLWithPath: path)
    guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else { continue }
    let box = page.getBoxRect(.mediaBox)
    let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    ctx.drawPDFPage(page)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let name = url.deletingPathExtension().lastPathComponent
    try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name + ".png"))
    print(name, box.width, box.height)
}
