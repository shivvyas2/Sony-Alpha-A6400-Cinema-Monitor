import CoreGraphics

/// Where the review screen's parts go on a phone. `size` is the safe area, `header` the bar at its top.
/// The picture and the 100 % crop share the rest: stacked in portrait, side by side in landscape; a picture that fills
/// the screen (a vertical shot held upright) gets the crop as an inset instead.
struct ReviewLayout: Equatable {
    /// Everything below the header: where a zoomed picture may go.
    var viewport: CGRect
    /// The whole picture, fitted.
    var picture: CGRect
    /// The crop with its caption bar.
    var loupe: CGRect
    var loupeOverPicture = false

    static let caption: CGFloat = 26
    private static let gap: CGFloat = 8, minSide: CGFloat = 130

    init(size: CGSize, aspect: CGFloat, header: CGFloat) {
        viewport = CGRect(x: 0, y: header, width: size.width, height: max(1, size.height - header))
        let gap = Self.gap
        let fit = Self.fit(aspect, in: viewport.size)
        if size.height > size.width {
            let room = viewport.height - fit.height - gap * 2
            if room >= Self.minSide + Self.caption {
                let w = viewport.width - gap * 2
                let h = min(room, w + Self.caption)
                // Picture and crop as one block, in the middle of whatever is left.
                let top = viewport.minY + max(0, (viewport.height - fit.height - h - gap * 2) / 2)
                picture = CGRect(x: (viewport.width - fit.width) / 2, y: top, width: fit.width, height: fit.height)
                loupe = CGRect(x: gap, y: picture.maxY + gap, width: w, height: h)
                return
            }
        } else {
            // Give the crop a column; the picture gives up at most a sixth of its width for it.
            var pic = fit
            let wanted = max(Self.minSide, min(viewport.width * 0.3, viewport.height))
            let short = wanted + gap * 2 - (viewport.width - fit.width)
            if short > 0 {
                let w = max(fit.width - short, fit.width * 5 / 6)
                pic = CGSize(width: w, height: w / aspect)
            }
            let side = viewport.width - pic.width - gap * 2
            if side >= Self.minSide {
                let w = min(side, viewport.height * 1.2)
                let h = min(viewport.height - gap * 2, w + Self.caption)
                let left = max(0, (viewport.width - pic.width - w - gap * 2) / 2)
                picture = CGRect(x: left, y: viewport.minY + (viewport.height - pic.height) / 2, width: pic.width, height: pic.height)
                loupe = CGRect(x: picture.maxX + gap, y: viewport.midY - h / 2, width: w, height: h)
                return
            }
        }
        picture = CGRect(x: viewport.midX - fit.width / 2, y: viewport.midY - fit.height / 2, width: fit.width, height: fit.height)
        let w = min(viewport.width, viewport.height) * 0.42
        let h = w * 2 / 3 + Self.caption
        loupe = CGRect(x: picture.maxX - w - gap, y: picture.maxY - h - gap, width: w, height: h)
        loupeOverPicture = true
    }

    static func fit(_ aspect: CGFloat, in size: CGSize) -> CGSize {
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGSize(width: w, height: h)
    }

    /// A picture larger than the viewport keeps it covered; a smaller one stays inside it.
    static func clamped(center c: CGPoint, shown: CGSize, in vp: CGRect) -> CGPoint {
        func axis(_ v: CGFloat, _ length: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            let a = lo + length / 2, b = hi - length / 2
            return min(max(v, min(a, b)), max(a, b))
        }
        return CGPoint(x: axis(c.x, shown.width, vp.minX, vp.maxX), y: axis(c.y, shown.height, vp.minY, vp.maxY))
    }

    static func center(_ c: CGPoint, zoomedBy k: CGFloat, around p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + (c.x - p.x) * k, y: p.y + (c.y - p.y) * k)
    }
}
