#!/usr/bin/env python3
"""Three Liquid-Glass icon concepts, rendered at 2x and downsampled for clean edges.
Usage: icon-concepts.py <outdir>   → concept-A.png, concept-B.png, concept-C.png, contact-sheet.png
"""
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

SS = 2            # supersample
S = 1024 * SS
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def linear_gradient(size, top, bottom, angle_deg=0):
    img = Image.new("RGBA", (size, size))
    px = img.load()
    a = math.radians(angle_deg); dx, dy = math.sin(a), math.cos(a)
    for y in range(size):
        for x in range(size):
            t = ((x / size - 0.5) * dx + (y / size - 0.5) * dy) + 0.5
            px[x, y] = lerp(top, bottom, max(0, min(1, t)))
    return img

def radial_spot(size, center, radius, color):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(img).ellipse([center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius], fill=color)
    return img.filter(ImageFilter.GaussianBlur(radius * 0.6))

def glass(bg, mask, tint=(255, 255, 255), body_alpha=(70, 30), refract=10, blur=18, rim=True, shadow=True):
    """Turns a mask into a glass element over bg: refraction, gradient tint, top highlight, inner shadow, rim."""
    size = bg.size[0]
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # refraction: the background seen through the glass, shifted and blurred
    seen = ImageChops.offset(bg, refract, refract).filter(ImageFilter.GaussianBlur(blur))
    seen = ImageChops.add(seen, Image.new("RGBA", (size, size), (18, 18, 24, 0)))
    layer.paste(seen, (0, 0), mask)
    # body tint gradient
    bbox = mask.getbbox()
    tintimg = Image.new("RGBA", (size, size), (0, 0, 0, 0)); tp = tintimg.load()
    for y in range(bbox[1], bbox[3]):
        a = int(body_alpha[0] + (body_alpha[1] - body_alpha[0]) * (y - bbox[1]) / max(1, bbox[3] - bbox[1]))
        for x in range(bbox[0], bbox[2]):
            tp[x, y] = (*tint, a)
    tintimg.putalpha(ImageChops.multiply(tintimg.split()[3], mask))
    layer = Image.alpha_composite(layer, tintimg)
    # top highlight band: mask minus mask shifted down, blurred
    hi = ImageChops.subtract(mask, ImageChops.offset(mask, 0, 14 * SS)).filter(ImageFilter.GaussianBlur(6 * SS))
    hi_img = Image.new("RGBA", (size, size), (255, 255, 255, 0)); hi_img.putalpha(hi.point(lambda v: min(255, int(v * 1.6))))
    layer = Image.alpha_composite(layer, hi_img)
    # inner shadow at the bottom edge
    lo = ImageChops.subtract(mask, ImageChops.offset(mask, 0, -18 * SS)).filter(ImageFilter.GaussianBlur(10 * SS))
    lo_img = Image.new("RGBA", (size, size), (0, 0, 0, 0)); lo_img.putalpha(lo.point(lambda v: int(v * 0.55)))
    layer = Image.alpha_composite(layer, lo_img)
    if rim:
        edge = ImageChops.subtract(mask, mask.filter(ImageFilter.MinFilter(3 * SS + 1)))
        edge_img = Image.new("RGBA", (size, size), (255, 255, 255, 0)); edge_img.putalpha(edge.point(lambda v: int(v * 0.5)))
        layer = Image.alpha_composite(layer, edge_img)
    out = bg
    if shadow:
        sh = Image.new("RGBA", (size, size), (0, 0, 0, 0)); sh.putalpha(mask.point(lambda v: int(v * 0.55)))
        sh = ImageChops.offset(sh.filter(ImageFilter.GaussianBlur(22 * SS)), 0, 26 * SS)
        out = Image.alpha_composite(out, sh)
    return Image.alpha_composite(out, layer)

def sphere(size, center, r, base=(236, 40, 48)):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0)); px = img.load()
    cx, cy = center
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
    glow = radial_spot(size, center, r * 1.9, (*base, 110))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse([cx - r, cy - r + 14 * SS, cx + r, cy + r + 16 * SS], fill=(0, 0, 0, 150))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14 * SS))
    return Image.alpha_composite(Image.alpha_composite(glow, shadow), img)

def finish(img, name):
    small = img.convert("RGB").resize((1024, 1024), Image.LANCZOS)
    small.save(f"{OUT}/{name}.png")
    return small

# ---------------- Concept A: bold viewfinder brackets, no slab ----------------
def concept_a():
    bg = linear_gradient(S, (255, 122, 40, 255), (96, 20, 120, 255), angle_deg=20)
    bg = Image.alpha_composite(bg, radial_spot(S, (S * 0.3, S * 0.2), S * 0.5, (255, 200, 120, 90)))
    bg = Image.alpha_composite(bg, radial_spot(S, (S * 0.85, S * 0.95), S * 0.55, (40, 10, 90, 160)))
    m = Image.new("L", (S, S), 0); d = ImageDraw.Draw(m)
    w, L = 74 * SS, 250 * SS
    ax, ay, bx, by = 170 * SS, 200 * SS, S - 170 * SS, S - 200 * SS
    for (x, y, dx, dy) in [(ax, ay, 1, 1), (bx, ay, -1, 1), (ax, by, 1, -1), (bx, by, -1, -1)]:
        d.rounded_rectangle([min(x, x + dx * L), y - w / 2, max(x, x + dx * L), y + w / 2], radius=w / 2, fill=255)
        d.rounded_rectangle([x - w / 2, min(y, y + dy * L), x + w / 2, max(y, y + dy * L)], radius=w / 2, fill=255)
    img = glass(bg, m, body_alpha=(120, 55), refract=14 * SS, blur=10 * SS)
    img = Image.alpha_composite(img, sphere(S, (S / 2, S / 2), 92 * SS))
    return finish(img, "concept-A")

# ---------------- Concept B: glass lens with iris and red centre ----------------
def concept_b():
    bg = linear_gradient(S, (18, 22, 40, 255), (4, 4, 8, 255), angle_deg=0)
    bg = Image.alpha_composite(bg, radial_spot(S, (S * 0.5, S * 0.25), S * 0.55, (60, 90, 200, 120)))
    bg = Image.alpha_composite(bg, radial_spot(S, (S * 0.5, S * 0.95), S * 0.5, (200, 60, 120, 70)))
    c = (S / 2, S / 2)
    # outer barrel
    m = Image.new("L", (S, S), 0); ImageDraw.Draw(m).ellipse([c[0] - 400 * SS, c[1] - 400 * SS, c[0] + 400 * SS, c[1] + 400 * SS], fill=255)
    img = glass(bg, m, tint=(200, 220, 255), body_alpha=(60, 20), refract=10 * SS, blur=24 * SS)
    # inner ring
    ring = Image.new("L", (S, S), 0); rd = ImageDraw.Draw(ring)
    rd.ellipse([c[0] - 320 * SS, c[1] - 320 * SS, c[0] + 320 * SS, c[1] + 320 * SS], fill=255)
    rd.ellipse([c[0] - 250 * SS, c[1] - 250 * SS, c[0] + 250 * SS, c[1] + 250 * SS], fill=0)
    img = glass(img, ring, body_alpha=(110, 40), refract=6 * SS, blur=8 * SS, shadow=False)
    # iris blades (dark) around a red centre
    iris = Image.new("RGBA", (S, S), (0, 0, 0, 0)); idr = ImageDraw.Draw(iris)
    idr.ellipse([c[0] - 250 * SS, c[1] - 250 * SS, c[0] + 250 * SS, c[1] + 250 * SS], fill=(8, 8, 14, 255))
    n = 9
    for k in range(n):
        a0 = k * 2 * math.pi / n
        p = [(c[0] + 250 * SS * math.cos(a0 + t), c[1] + 250 * SS * math.sin(a0 + t)) for t in (0, 0.42)]
        idr.polygon([(c[0] + 120 * SS * math.cos(a0 + 0.9), c[1] + 120 * SS * math.sin(a0 + 0.9)), p[0], p[1]], fill=(30, 32, 44, 255))
    img = Image.alpha_composite(img, iris)
    img = Image.alpha_composite(img, sphere(S, c, 118 * SS))
    # lens flare highlight
    img = Image.alpha_composite(img, radial_spot(S, (c[0] - 150 * SS, c[1] - 190 * SS), 150 * SS, (255, 255, 255, 70)))
    return finish(img, "concept-B")

# ---------------- Concept C: monitor slab with a waveform trace ----------------
def concept_c():
    bg = linear_gradient(S, (20, 40, 60, 255), (6, 8, 14, 255), angle_deg=10)
    bg = Image.alpha_composite(bg, radial_spot(S, (S * 0.2, S * 0.15), S * 0.6, (40, 160, 140, 110)))
    bg = Image.alpha_composite(bg, radial_spot(S, (S * 0.9, S * 0.9), S * 0.6, (30, 60, 160, 120)))
    box = [120 * SS, 236 * SS, S - 120 * SS, S - 236 * SS]
    m = Image.new("L", (S, S), 0); ImageDraw.Draw(m).rounded_rectangle(box, radius=90 * SS, fill=255)
    img = glass(bg, m, body_alpha=(64, 22), refract=12 * SS, blur=26 * SS)
    # waveform trace: layered green luma curve with glow, clipped to slab
    trace = Image.new("RGBA", (S, S), (0, 0, 0, 0)); td = ImageDraw.Draw(trace)
    pts = []
    x0, x1 = box[0] + 70 * SS, box[2] - 70 * SS
    for i in range(0, 400):
        t = i / 399
        x = x0 + (x1 - x0) * t
        y = box[3] - 110 * SS - (0.35 + 0.25 * math.sin(t * 6.3) + 0.18 * math.sin(t * 19 + 1.2) + 0.1 * math.sin(t * 41)) * (box[3] - box[1] - 200 * SS)
        pts.append((x, y))
    for width, alpha in [(40 * SS, 40), (18 * SS, 110), (7 * SS, 255)]:
        td.line(pts, fill=(120, 255, 170, alpha), width=width, joint="curve")
    trace = trace.filter(ImageFilter.GaussianBlur(2 * SS))
    clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0)); clipped.paste(trace, (0, 0), m)
    img = Image.alpha_composite(img, clipped)
    # REC bead top-right
    img = Image.alpha_composite(img, sphere(S, (box[2] - 110 * SS, box[1] + 110 * SS), 46 * SS))
    return finish(img, "concept-C")

a, b, c = concept_a(), concept_b(), concept_c()
sheet = Image.new("RGB", (1024 * 3 + 160, 1024 + 80), (20, 20, 22))
for i, im in enumerate([a, b, c]):
    sheet.paste(im, (40 + i * (1024 + 40), 40))
sheet.resize((sheet.width // 2, sheet.height // 2), Image.LANCZOS).save(f"{OUT}/contact-sheet.png")
print("ok")
