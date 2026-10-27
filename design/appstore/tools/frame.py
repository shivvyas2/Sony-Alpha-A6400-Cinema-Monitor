#!/usr/bin/env python3
"""Puts App Store screenshots inside the Simulator's own device chrome and lays them out on a marketing canvas.

The chrome is Xcode's (DeviceKit .devicechrome, the artwork the Simulator window draws), rendered from its
PDFs by render-pdf.swift. The screen corners come from the device type's framebuffer mask, so the picture
is clipped exactly where the hardware display ends.

    python3 frame.py <chrome-png-dir> <mask.png> <phone|tablet|duo> <shots.json> <outdir>

shots.json: [{"src": "raw/1.png", "title": "...", "subtitle": "...", "out": "01-monitor.png"}, ...]
Screenshots are landscape; the canvas matches their pixel size (the App Store slot for that device).
"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

Image.MAX_IMAGE_PIXELS = None

# Geometry in points, from chrome.json (sizing, inputs) and measured against the composite artwork.
DEVICES = {
    "phone": {
        "scale": 3, "inset": 17, "tile": 110,
        "tiles": ("Phone TL", "Phone Top", "Phone TR", "Phone Left", "Phone Right", "Phone BL", "Phone Base", "Phone BR"),
        # (image, edge, offset along the edge from the top/left, measured from chrome.json "normal")
        "island": (125, 37, 11),  # Dynamic Island width, height, top margin
        "buttons": [("Mute BTN", "left", 180), ("Vol BTN", "left", 268), ("Vol BTN", "left", 354), ("X_Power BTN", "right", 293)],
    },
    "tablet": {
        "scale": 2, "inset": 45, "tile": 96,
        "tiles": ("iPadTL", "iPadTop", "iPadTR", "iPadLeft", "iPadRight", "iPadBL", "iPadBase", "iPadBR"),
        "buttons": [("VolBTN", "right", 100), ("VolBTN", "right", 163), ("iPadPowerBTN", "top-trailing", 74)],
    },
    # iPhone Duo: the chrome is drawn whole (hinge on the left), sized to the inner display.
    "duo": {
        "scale": 3, "inset": (26, 14, 22, 14), "composite": "PhoneComposite",
        "buttons": [("Vol BTN", "top-leading", 316), ("Vol BTN", "top-leading", 236), ("X_Power BTN", "right", 202)],
    },
}
PROTRUDE = 3      # pt a side button stands proud of the frame, as in the Simulator at rest
RING = 2          # pt of transparent margin inside each chrome tile before the metal edge

BG_TOP, BG_BOTTOM = (22, 23, 26), (4, 4, 5)
ACCENT = (245, 140, 33)   # Theme.accent
TEXT, DIM = (242, 242, 242), (150, 153, 158)
FONT = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_axes([100, 80, 400, weight])  # width, optical size (display), grade, weight
    except Exception:
        pass
    return f


def framed_device(shot, chrome_dir, mask_path, kind):
    """Returns the device (RGBA) with `shot` on its display, in the shot's orientation."""
    d = DEVICES[kind]
    s = d["scale"]
    load = lambda n: Image.open(os.path.join(chrome_dir, n + ".png")).convert("RGBA")

    # Chrome tiles describe the device upright, so build it in portrait and turn it at the end.
    landscape = shot.width > shot.height
    screen = shot.convert("RGB").rotate(-90, expand=True) if landscape else shot.convert("RGB")
    sw, sh = screen.size
    mask = Image.open(mask_path).convert("RGBA").split()[3].resize((sw, sh), Image.LANCZOS)

    il, it_, ir, ib = (v * s for v in (d["inset"] if isinstance(d["inset"], tuple) else (d["inset"],) * 4))
    pad = 12 * s
    W, H = sw + il + ir, sh + it_ + ib
    canvas = Image.new("RGBA", (W + 2 * pad, H + 2 * pad), (0, 0, 0, 0))

    # Side buttons sit under the frame, standing a few points proud of it.
    for name, edge, off in d["buttons"]:
        b = load(name)
        if edge == "left":
            canvas.alpha_composite(b, (pad + (RING - PROTRUDE) * s, pad + off * s))
        elif edge == "right":
            canvas.alpha_composite(b, (pad + W - (RING - PROTRUDE) * s - b.width, pad + off * s))
        elif edge == "top-leading":
            canvas.alpha_composite(b, (pad + off * s, pad + (RING - PROTRUDE) * s))
        else:  # top, measured from the trailing corner
            canvas.alpha_composite(b, (pad + W - off * s - b.width, pad + (RING - PROTRUDE) * s))

    if "composite" in d:
        body = load(d["composite"]).resize((W, H), Image.LANCZOS)
    else:
        tile = d["tile"] * s
        tl, top, tr, left, right, bl, base, br = (load(n) for n in d["tiles"])
        body = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        body.paste(top.resize((W - 2 * tile, tile)), (tile, 0))
        body.paste(base.resize((W - 2 * tile, tile)), (tile, H - tile))
        body.paste(left.resize((tile, H - 2 * tile)), (0, tile))
        body.paste(right.resize((tile, H - 2 * tile)), (W - tile, tile))
        interior = left.getpixel((left.width - 1, 0))
        body.paste(Image.new("RGBA", (W - 2 * tile, H - 2 * tile), interior), (tile, tile))
        for img, xy in ((tl, (0, 0)), (tr, (W - tile, 0)), (bl, (0, H - tile)), (br, (W - tile, H - tile))):
            body.paste(img, xy)
    body.paste(screen, (il, it_), mask)
    if "island" in d:
        iw, ih, top_margin = (v * s for v in d["island"])
        x0, y0 = il + (sw - iw) / 2, it_ + top_margin
        ImageDraw.Draw(body).rounded_rectangle([x0, y0, x0 + iw, y0 + ih], radius=ih / 2, fill=(0, 0, 0, 255))
    canvas.alpha_composite(body, (pad, pad))

    # Turn counter-clockwise: the device top goes left, matching UIInterfaceOrientationLandscapeRight.
    return canvas.rotate(90, expand=True) if landscape else canvas


def background(size):
    w, h = size
    bg = Image.new("RGB", size)
    px = ImageDraw.Draw(bg)
    for y in range(h):
        t = y / (h - 1)
        px.line([(0, y), (w, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)))
    # A faint warm glow behind the device, the colour of the monitor's active tools.
    glow = Image.new("L", size, 0)
    ImageDraw.Draw(glow).ellipse([w * 0.2, h * 0.35, w * 0.8, h * 1.15], fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(min(w, h) * 0.12))
    bg.paste(Image.new("RGB", size, ACCENT), (0, 0), glow.point(lambda v: round(v * 0.22)))
    return bg


def compose(shot_path, title, subtitle, chrome_dir, mask_path, kind):
    shot = Image.open(shot_path)
    size = shot.size
    w, h = size
    out = background(size)
    draw = ImageDraw.Draw(out)

    unit = h / 100  # layout in hundredths of the canvas height
    title_font, sub_font = font(round(unit * {"phone": 7.2, "duo": 5.6}.get(kind, 5.0)), 700), font(round(unit * {"phone": 3.4, "duo": 2.7}.get(kind, 2.4)), 500)
    ty = unit * {"phone": 5.5}.get(kind, 5.0)
    draw.text((w / 2, ty), title, font=title_font, fill=TEXT, anchor="mt")
    sy = ty + title_font.size * 1.22
    draw.text((w / 2, sy), subtitle, font=sub_font, fill=DIM, anchor="mt")

    device = framed_device(shot, chrome_dir, mask_path, kind)
    top = sy + sub_font.size * 2.0
    avail_h, avail_w = h - top - unit * 3.5, w * 0.92
    k = min(avail_h / device.height, avail_w / device.width)
    device = device.resize((round(device.width * k), round(device.height * k)), Image.LANCZOS)

    # Soft contact shadow so the device sits on the canvas rather than floating on it.
    shadow = Image.new("RGBA", device.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 150), (0, 0), device.split()[3])
    shadow = shadow.filter(ImageFilter.GaussianBlur(unit * 1.6))
    x = (w - device.width) // 2
    y = round(top + (avail_h - device.height) / 2)
    out.paste(shadow, (x, y + round(unit * 1.2)), shadow)
    out.paste(device, (x, y), device)
    return out


def main():
    chrome_dir, mask_path, kind, spec, outdir = sys.argv[1:6]
    os.makedirs(outdir, exist_ok=True)
    base = os.path.dirname(os.path.abspath(spec))
    for item in json.load(open(spec)):
        img = compose(os.path.join(base, item["src"]), item["title"], item["subtitle"], chrome_dir, mask_path, kind)
        img.save(os.path.join(outdir, item["out"]), optimize=True)
        print(item["out"], img.size)


if __name__ == "__main__":
    main()
