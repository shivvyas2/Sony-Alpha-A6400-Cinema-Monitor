#!/usr/bin/env python3
"""App Store header and search-results artwork: iPad, iPhone and iPhone Duo in their Simulator chrome.

    python3 header.py <phone-chrome> <phone-mask> <tablet-chrome> <tablet-mask> <duo-chrome> <duo-mask>
                      <ipad-shot> <iphone-shot> <duo-shot> <outdir>

Writes header-3840x1646.png (the header slot takes PNG only) and search-3840x2560.jpg.
"""
import os, sys
from PIL import Image, ImageDraw, ImageFilter
from frame import ACCENT, DIM, TEXT, background, font, framed_device

Image.MAX_IMAGE_PIXELS = None


def scaled(device, height):
    k = height / device.height
    return device.resize((round(device.width * k), round(device.height * k)), Image.LANCZOS)


def shadowed(canvas, device, xy, blur):
    shadow = Image.new("RGBA", device.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 170), (0, 0), device.split()[3])
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas.paste(shadow, (xy[0], xy[1] + round(blur * 0.8)), shadow)
    canvas.paste(device, xy, device)


def compose(size, devices, title_left):
    w, h = size
    out = background(size)
    ipad, iphone, duo = devices
    if title_left:
        # Wide header: title on the left third, devices on the right.
        unit = h / 100
        draw = ImageDraw.Draw(out)
        tx = round(w * 0.06)
        draw.text((tx, h * 0.34), "Cinema Monitor HUD", font=font(round(unit * 9), 700), fill=TEXT, anchor="lm")
        draw.text((tx, h * 0.47), "A field monitor for your camera,", font=font(round(unit * 4.4), 500), fill=DIM, anchor="lm")
        draw.text((tx, h * 0.54), "on iPhone, iPad and iPhone Duo.", font=font(round(unit * 4.4), 500), fill=DIM, anchor="lm")
        draw.rounded_rectangle([tx, h * 0.62, tx + unit * 10, h * 0.62 + unit * 0.9], radius=unit * 0.45, fill=ACCENT)
        a = scaled(ipad, round(h * 0.80))
        b = scaled(iphone, round(h * 0.40))
        c = scaled(duo, round(h * 0.70))
        ax, ay = round(w * 0.44), round(h * 0.10)
        shadowed(out, a, (ax, ay), unit * 1.5)
        shadowed(out, c, (min(ax + a.width - round(c.width * 0.35), w - c.width - round(w * 0.03)), round(h * 0.24)), unit * 1.5)
        shadowed(out, b, (ax - round(b.width * 0.30), round(h * 0.55)), unit * 1.5)
    else:
        # 3:2 search result: title on top, the three devices below.
        unit = h / 100
        draw = ImageDraw.Draw(out)
        draw.text((w / 2, h * 0.08), "Cinema Monitor HUD", font=font(round(unit * 6.2), 700), fill=TEXT, anchor="mt")
        draw.text((w / 2, h * 0.17), "A field monitor for your camera, on iPhone, iPad and iPhone Duo", font=font(round(unit * 2.8), 500), fill=DIM, anchor="mt")
        a = scaled(ipad, round(h * 0.60))
        b = scaled(iphone, round(h * 0.30))
        c = scaled(duo, round(h * 0.55))
        ax, ay = (w - a.width) // 2, round(h * 0.30)
        shadowed(out, a, (ax, ay), unit * 1.2)
        shadowed(out, c, (ax + a.width - round(c.width * 0.45), round(h * 0.40)), unit * 1.2)
        shadowed(out, b, (ax - round(b.width * 0.35), round(h * 0.62)), unit * 1.2)
    return out


def main():
    pc, pm, tc, tm, dc, dm, ipad_shot, iphone_shot, duo_shot, outdir = sys.argv[1:11]
    os.makedirs(outdir, exist_ok=True)
    devices = (
        framed_device(Image.open(ipad_shot), tc, tm, "tablet"),
        framed_device(Image.open(iphone_shot), pc, pm, "phone"),
        framed_device(Image.open(duo_shot), dc, dm, "duo"),
    )
    compose((3840, 1646), devices, True).save(os.path.join(outdir, "header-3840x1646.png"), optimize=True)
    compose((3840, 2560), devices, False).save(os.path.join(outdir, "search-3840x2560.jpg"), quality=90)
    print("ok")


if __name__ == "__main__":
    main()
