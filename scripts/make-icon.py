#!/usr/bin/env python3
"""Renders AppIcon.icns: black rounded square, amber viewfinder brackets, red REC dot."""
import os, subprocess, sys
from PIL import Image, ImageDraw
out = sys.argv[1]
iconset = out.replace(".icns", ".iconset"); os.makedirs(iconset, exist_ok=True)
def render(size):
    s = size; img = Image.new("RGBA", (s, s), (0, 0, 0, 0)); d = ImageDraw.Draw(img)
    m = s * 0.06; d.rounded_rectangle([m, m, s - m, s - m], radius=s * 0.2, fill=(14, 14, 16, 255))
    amber = (255, 184, 41, 255); w = max(2, int(s * 0.045)); L = s * 0.16; a, b = s * 0.24, s * 0.76
    for (x, y, dx, dy) in [(a, a, 1, 1), (b, a, -1, 1), (a, b, 1, -1), (b, b, -1, -1)]:
        d.line([(x, y), (x + dx * L, y)], fill=amber, width=w); d.line([(x, y), (x, y + dy * L)], fill=amber, width=w)
    r = s * 0.075; d.ellipse([s * 0.5 - r, s * 0.5 - r, s * 0.5 + r, s * 0.5 + r], fill=(255, 55, 55, 255))
    return img
for base in [16, 32, 128, 256, 512]:
    render(base).save(f"{iconset}/icon_{base}x{base}.png")
    render(base * 2).save(f"{iconset}/icon_{base}x{base}@2x.png")
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
