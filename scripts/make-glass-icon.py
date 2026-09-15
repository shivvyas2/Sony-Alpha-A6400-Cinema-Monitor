#!/usr/bin/env python3
"""CinemaHUD app icon: black liquid-glass tile, glass viewfinder brackets with a red REC bead,
small condensed-bold "CHM" in pure white along the bottom. Rendered at 2x and downsampled for clean edges.

Outputs (in <outdir>, default design/icon):
  AppIcon-iOS-1024.png     opaque square, full bleed (App Store / iOS asset catalog)
  AppIcon-macOS-1024.png   squircle-masked with transparency (macOS)
  layer-background.png, layer-glass.png, layer-symbol.png   for Apple Icon Composer
  preview.png              512 px preview
"""
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops, ImageFont

SS = 2
S = 1024 * SS
OUT = sys.argv[1] if len(sys.argv) > 1 else "design/icon"
os.makedirs(OUT, exist_ok=True)
FONT = "/System/Library/Fonts/SFNS.ttf"

def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    try: f.set_variation_by_name(weight)
    except Exception: pass
    return f

def spot(center, radius, color):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(img).ellipse([center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius], fill=color)
    return img.filter(ImageFilter.GaussianBlur(radius * 0.6))

def squircle_mask(size):
    m = Image.new("L", (size, size), 0); px = m.load(); r = size / 2.0
    for y in range(size):
        for x in range(size):
            u, v = abs((x + 0.5 - r) / r), abs((y + 0.5 - r) / r)
            px[x, y] = 255 if (u ** 5 + v ** 5) <= 1.0 else 0
    return m.filter(ImageFilter.GaussianBlur(1.2))

def glass(bg, mask, tint=(255, 255, 255), body_alpha=(120, 60), refract=10, blur=12, edge_alpha=0.6):
    """Mask → glass element over bg: refraction, vertical tint, top highlight, bottom inner shadow, rim."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    seen = ImageChops.offset(bg, refract, refract).filter(ImageFilter.GaussianBlur(blur))
    seen = ImageChops.add(seen, Image.new("RGBA", (S, S), (30, 30, 34, 0)))
    layer.paste(seen, (0, 0), mask)
    bbox = mask.getbbox()
    tintimg = Image.new("RGBA", (S, S), (0, 0, 0, 0)); tp = tintimg.load()
    for y in range(bbox[1], bbox[3]):
        a = int(body_alpha[0] + (body_alpha[1] - body_alpha[0]) * (y - bbox[1]) / max(1, bbox[3] - bbox[1]))
        for x in range(bbox[0], bbox[2]):
            tp[x, y] = (*tint, a)
    tintimg.putalpha(ImageChops.multiply(tintimg.split()[3], mask))
    layer = Image.alpha_composite(layer, tintimg)
    hi = ImageChops.subtract(mask, ImageChops.offset(mask, 0, 10 * SS)).filter(ImageFilter.GaussianBlur(4 * SS))
    hi_img = Image.new("RGBA", (S, S), (255, 255, 255, 0)); hi_img.putalpha(hi.point(lambda v: min(255, int(v * 1.5))))
    layer = Image.alpha_composite(layer, hi_img)
    lo = ImageChops.subtract(mask, ImageChops.offset(mask, 0, -14 * SS)).filter(ImageFilter.GaussianBlur(8 * SS))
    lo_img = Image.new("RGBA", (S, S), (0, 0, 0, 0)); lo_img.putalpha(lo.point(lambda v: int(v * 0.5)))
    layer = Image.alpha_composite(layer, lo_img)
    edge = ImageChops.subtract(mask, mask.filter(ImageFilter.MinFilter(2 * SS + 1)))
    edge_img = Image.new("RGBA", (S, S), (255, 255, 255, 0)); edge_img.putalpha(edge.point(lambda v: int(v * edge_alpha)))
    layer = Image.alpha_composite(layer, edge_img)
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0)); sh.putalpha(mask.point(lambda v: int(v * 0.6)))
    sh = ImageChops.offset(sh.filter(ImageFilter.GaussianBlur(18 * SS)), 0, 20 * SS)
    return layer, sh

def sphere(center, r, base=(236, 40, 48)):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0)); px = img.load(); cx, cy = center
    for y in range(int(cy - r) - 2, int(cy + r) + 3):
        for x in range(int(cx - r) - 2, int(cx + r) + 3):
            dx, dy = (x - cx) / r, (y - cy) / r; r2 = dx * dx + dy * dy
            if r2 <= 1.0:
                z = math.sqrt(1 - r2)
                diff = max(0.0, -0.4 * dx - 0.6 * dy + 0.69 * z)
                spec = max(0.0, -0.3 * dx - 0.5 * dy + 0.81 * z) ** 60
                fres = (1 - z) ** 3 * 0.35
                col = tuple(min(255, int(base[i] * (0.28 + 0.8 * diff) + 255 * (spec * 0.95 + fres))) for i in range(3))
                edge = 255 if r2 < 0.985 else int(255 * (1 - (r2 - 0.985) / 0.015))
                px[x, y] = (*col, edge)
    glow = spot(center, r * 2.0, (*base, 120))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse([cx - r, cy - r + 12 * SS, cx + r, cy + r + 14 * SS], fill=(0, 0, 0, 160))
    return Image.alpha_composite(Image.alpha_composite(glow, shadow.filter(ImageFilter.GaussianBlur(12 * SS))), img)

# ---------- background: black glass, faint sheen top-left, soft vignette ----------
bg = Image.new("RGBA", (S, S), (8, 8, 10, 255))
bg = Image.alpha_composite(bg, spot((S * 0.22, S * 0.12), S * 0.7, (255, 255, 255, 26)))
bg = Image.alpha_composite(bg, spot((S * 0.9, S * 1.0), S * 0.6, (0, 0, 0, 120)))
# fine diagonal sheen band across the top (liquid highlight on black glass)
band = Image.new("RGBA", (S, S), (0, 0, 0, 0)); bd = ImageDraw.Draw(band)
bd.polygon([(0, S * 0.05), (S, -S * 0.25), (S, S * 0.02), (0, S * 0.32)], fill=(255, 255, 255, 18))
bg = Image.alpha_composite(bg, band.filter(ImageFilter.GaussianBlur(30 * SS)))

# ---------- mark: glass viewfinder brackets with the red REC bead ----------
mark = Image.new("L", (S, S), 0); md = ImageDraw.Draw(mark)
w, L = 44 * SS, 150 * SS
ax, ay, bx, by = 262 * SS, 232 * SS, S - 262 * SS, 232 * SS + 360 * SS
for (x, y, dx, dy) in [(ax, ay, 1, 1), (bx, ay, -1, 1), (ax, by, 1, -1), (bx, by, -1, -1)]:
    md.rounded_rectangle([min(x, x + dx * L), y - w / 2, max(x, x + dx * L), y + w / 2], radius=w / 2, fill=255)
    md.rounded_rectangle([x - w / 2, min(y, y + dy * L), x + w / 2, max(y, y + dy * L)], radius=w / 2, fill=255)
glass_layer, glass_shadow = glass(bg, mark, body_alpha=(170, 90), refract=8 * SS, blur=10 * SS)
bead = sphere((S / 2, (ay + by) / 2), 50 * SS)

# ---------- wordmark: small condensed bold "CHM", pure white, along the bottom ----------
word = Image.new("RGBA", (S, S), (0, 0, 0, 0)); wd = ImageDraw.Draw(word)
f_small = font(int(92 * SS), "Condensed Bold")
label = "CHM"
spacing = 6 * SS
total = sum(wd.textlength(ch, font=f_small) for ch in label) + spacing * (len(label) - 1)
x = (S - total) / 2; y = S * 0.745
for ch in label:
    wd.text((x, y), ch, font=f_small, fill=(255, 255, 255, 255))
    x += wd.textlength(ch, font=f_small) + spacing
word_layer = word

# ---------- compose ----------
full = Image.alpha_composite(bg, glass_shadow)
full = Image.alpha_composite(full, glass_layer)
full = Image.alpha_composite(full, bead)
full = Image.alpha_composite(full, word_layer)

def down(img): return img.resize((1024, 1024), Image.LANCZOS)
ios = down(full).convert("RGB"); ios.save(f"{OUT}/AppIcon-iOS-1024.png")
mac = down(full).copy(); mac.putalpha(squircle_mask(1024)); mac.save(f"{OUT}/AppIcon-macOS-1024.png")
down(bg).convert("RGB").save(f"{OUT}/layer-background.png")
down(Image.alpha_composite(glass_shadow, glass_layer)).save(f"{OUT}/layer-glass.png")
down(Image.alpha_composite(bead, word_layer)).save(f"{OUT}/layer-symbol.png")
ios.resize((512, 512), Image.LANCZOS).save(f"{OUT}/preview.png")
print("ok")
