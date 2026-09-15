#!/usr/bin/env python3
"""Renders the CinemaHUD app icon in a Liquid Glass style.

Outputs (in design/icon/):
  AppIcon-iOS-1024.png     opaque square, full bleed (App Store / iOS asset catalog)
  AppIcon-macOS-1024.png   squircle-masked with transparency (macOS)
  layer-background.png, layer-glass.png, layer-symbol.png   for Apple Icon Composer
"""
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 1024
OUT = sys.argv[1] if len(sys.argv) > 1 else "design/icon"
os.makedirs(OUT, exist_ok=True)

def radial(size, inner, outer, center=(0.5, 0.42), power=1.0):
    """Radial gradient RGBA image from inner colour at center to outer colour at the corners."""
    img = Image.new("RGBA", (size, size))
    px = img.load()
    cx, cy = center[0] * size, center[1] * size
    maxd = math.hypot(max(cx, size - cx), max(cy, size - cy))
    for y in range(size):
        for x in range(size):
            t = min(1.0, (math.hypot(x - cx, y - cy) / maxd) ** power)
            px[x, y] = tuple(int(inner[i] + (outer[i] - inner[i]) * t) for i in range(4))
    return img

def rounded_mask(size, radius, box=None):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle(box or [0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m

def squircle_mask(size):
    # Apple's continuous-corner squircle (superellipse, n ≈ 5) as the macOS icon shape
    m = Image.new("L", (size, size), 0)
    px = m.load()
    r = size / 2.0
    for y in range(size):
        for x in range(size):
            u, v = abs((x + 0.5 - r) / r), abs((y + 0.5 - r) / r)
            px[x, y] = 255 if (u ** 5 + v ** 5) <= 1.0 else 0
    return m.filter(ImageFilter.GaussianBlur(1.2))

# ---------- background: deep blue-violet night falling to black, faint horizon glow ----------
bg = radial(S, (52, 62, 140, 255), (7, 8, 16, 255), center=(0.5, 0.32), power=0.8)
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse([-200, 560, S + 200, 1180], fill=(150, 70, 170, 120))
gd.ellipse([-100, 700, 600, 1300], fill=(40, 140, 190, 90))
glow = glow.filter(ImageFilter.GaussianBlur(120))
bg = Image.alpha_composite(bg, glow)
# subtle top-light
top = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(top).ellipse([120, -260, S - 120, 260], fill=(255, 255, 255, 40))
bg = Image.alpha_composite(bg, top.filter(ImageFilter.GaussianBlur(90)))

# ---------- glass slab: a 16:9 monitor plate, frosted, with rim light and liquid sheen ----------
box = [136, 246, S - 136, S - 246]          # 752 x 532
slab_r = 96
slab_mask = rounded_mask(S, slab_r, box)

# frosted refraction: blurred + brightened copy of the background inside the slab
frost = bg.filter(ImageFilter.GaussianBlur(26))
frost = ImageChops.add(frost, Image.new("RGBA", (S, S), (26, 28, 40, 0)))
# body tint (white 12% → 4% top to bottom)
tint = Image.new("RGBA", (S, S), (0, 0, 0, 0))
tp = tint.load()
for y in range(box[1], box[3] + 1):
    a = int(58 - 34 * (y - box[1]) / (box[3] - box[1]))
    for x in range(box[0], box[2] + 1):
        tp[x, y] = (255, 255, 255, a)
glass = Image.alpha_composite(frost, tint)

# liquid sheen: a soft, tilted highlight lobe across the upper part
sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(sheen)
sd.ellipse([box[0] - 80, box[1] - 260, box[2] - 120, box[1] + 230], fill=(255, 255, 255, 120))
sd.ellipse([box[0] + 40, box[1] + 10, box[0] + 420, box[1] + 130], fill=(255, 255, 255, 70))
sheen = sheen.filter(ImageFilter.GaussianBlur(48))
glass = Image.alpha_composite(glass, sheen)
# bottom inner shadow (depth)
shade = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shade).rounded_rectangle([box[0], box[3] - 140, box[2], box[3] + 40], radius=slab_r, fill=(0, 0, 0, 70))
glass = Image.alpha_composite(glass, shade.filter(ImageFilter.GaussianBlur(40)))

# rim light: 1.5px bright edge, stronger at top-left, plus a thin dark edge at bottom-right
rim = Image.new("RGBA", (S, S), (0, 0, 0, 0))
rd = ImageDraw.Draw(rim)
for i, a in [(0, 200), (1, 120), (2, 60)]:
    rd.rounded_rectangle([box[0] + i, box[1] + i, box[2] - i, box[3] - i], radius=slab_r - i, outline=(255, 255, 255, a), width=1)
rim_grad = Image.new("L", (S, S), 0)
rp = rim_grad.load()
for y in range(S):
    for x in range(S):
        rp[x, y] = int(255 * max(0.15, 1 - ((x / S) * 0.55 + (y / S) * 0.75)))
rim.putalpha(ImageChops.multiply(rim.split()[3], rim_grad))
glass = Image.alpha_composite(glass, rim)

glass_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
glass_layer.paste(glass, (0, 0), slab_mask)
# drop shadow under the slab
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([box[0] + 6, box[1] + 30, box[2] + 6, box[3] + 34], radius=slab_r, fill=(0, 0, 0, 150))
shadow = shadow.filter(ImageFilter.GaussianBlur(34))

# ---------- symbol: white glass viewfinder brackets + 3D REC bead ----------
sym = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(sym)
w = 22           # stroke
L = 118          # bracket arm length
ax, ay, bx, by = box[0] + 96, box[1] + 84, box[2] - 96, box[3] - 84
for (x, y, dx, dy) in [(ax, ay, 1, 1), (bx, ay, -1, 1), (ax, by, 1, -1), (bx, by, -1, -1)]:
    d.rounded_rectangle([min(x, x + dx * L), y - w / 2, max(x, x + dx * L), y + w / 2], radius=w / 2, fill=(255, 255, 255, 255))
    d.rounded_rectangle([x - w / 2, min(y, y + dy * L), x + w / 2, max(y, y + dy * L)], radius=w / 2, fill=(255, 255, 255, 255))
# centre marker (small cross with a gap)
cx, cy = S / 2, S / 2
g, s_ = 26, 74
for (x0, y0, x1, y1) in [(cx - s_, cy, cx - g, cy), (cx + g, cy, cx + s_, cy), (cx, cy - s_, cx, cy - g), (cx, cy + g, cx, cy + s_)]:
    d.line([(x0, y0), (x1, y1)], fill=(255, 255, 255, 235), width=10)
# glassify the white strokes: gradient alpha (brighter top) + inner bevel highlight
sym_a = sym.split()[3]
grad = Image.new("L", (S, S), 0)
gp = grad.load()
for y in range(S):
    v = int(255 * (0.78 + 0.22 * (1 - y / S)))
    for x in range(S):
        gp[x, y] = v
sym.putalpha(ImageChops.multiply(sym_a, grad))
bevel = sym_a.filter(ImageFilter.GaussianBlur(3))
bevel = ImageChops.subtract(sym_a, ImageChops.offset(bevel, 0, 4))
bevel_img = Image.new("RGBA", (S, S), (255, 255, 255, 0)); bevel_img.putalpha(bevel.point(lambda v: min(255, v * 2)))
sym = Image.alpha_composite(sym, bevel_img)
# soft shadow under the strokes
sym_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0)); sym_shadow.putalpha(sym_a.point(lambda v: v * 120 // 255))
sym_shadow = ImageChops.offset(sym_shadow.filter(ImageFilter.GaussianBlur(10)), 0, 10)

# REC bead: 3D red sphere, bottom-right inside the brackets
bead = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bcx, bcy, br = bx - 100, by - 96, 68
bpx = bead.load()
for y in range(int(bcy - br) - 2, int(bcy + br) + 3):
    for x in range(int(bcx - br) - 2, int(bcx + br) + 3):
        dx, dy = (x - bcx) / br, (y - bcy) / br
        r2 = dx * dx + dy * dy
        if r2 <= 1.0:
            z = math.sqrt(1 - r2)
            # lighting from top-left
            n_l = max(0.0, (-0.45 * dx - 0.6 * dy + 0.66 * z))
            spec = max(0.0, (-0.35 * dx - 0.55 * dy + 0.76 * z)) ** 40
            base = (232, 34, 44)
            col = tuple(min(255, int(base[i] * (0.35 + 0.75 * n_l) + 255 * spec * 0.9)) for i in range(3))
            edge = 255 if r2 < 0.94 else int(255 * (1 - (r2 - 0.94) / 0.06))
            bpx[x, y] = (*col, edge)
bead_glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(bead_glow).ellipse([bcx - br * 1.7, bcy - br * 1.7, bcx + br * 1.7, bcy + br * 1.7], fill=(255, 40, 50, 120))
bead_glow = bead_glow.filter(ImageFilter.GaussianBlur(40))
bead_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(bead_shadow).ellipse([bcx - br, bcy - br + 16, bcx + br, bcy + br + 18], fill=(0, 0, 0, 140))
bead_shadow = bead_shadow.filter(ImageFilter.GaussianBlur(16))

symbol_layer = Image.alpha_composite(Image.alpha_composite(Image.alpha_composite(Image.alpha_composite(sym_shadow, sym), bead_glow), bead_shadow), bead)

# ---------- compose ----------
full = Image.alpha_composite(bg, shadow)
full = Image.alpha_composite(full, glass_layer)
full = Image.alpha_composite(full, symbol_layer)

ios = full.convert("RGB")                       # App Store icons must be opaque, no alpha
ios.save(f"{OUT}/AppIcon-iOS-1024.png")
mac = full.copy(); mac.putalpha(squircle_mask(S))
mac.save(f"{OUT}/AppIcon-macOS-1024.png")
bg.convert("RGB").save(f"{OUT}/layer-background.png")
glass_layer.save(f"{OUT}/layer-glass.png")
symbol_layer.save(f"{OUT}/layer-symbol.png")
print("wrote", os.listdir(OUT))
