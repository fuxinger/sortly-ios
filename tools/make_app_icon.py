"""Draws the SORTLY app icon (light, dark and tinted appearance) at 1024 px.

Loose photos fan into one neat stack: the front card shows a landscape with a warm sun.
Rendered at 4x and scaled down for clean edges. Run: python3 tools/make_app_icon.py <out_dir>
"""
import math
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096  # supersampled canvas
OUT = 1024

def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))

def vertical_gradient(size, top, bottom):
    w, h = size
    img = Image.new("RGBA", size)
    px = img.load()
    for y in range(h):
        c = lerp(top, bottom, y / (h - 1))
        for x in range(w):
            px[x, y] = c
    return img

def gradient_fast(size, top, bottom):
    # 1-pixel-wide gradient stretched: fast and smooth
    col = Image.new("RGBA", (1, 256))
    for y in range(256):
        col.putpixel((0, y), lerp(top, bottom, y / 255))
    return col.resize(size, Image.BICUBIC)

def rounded_mask(size, box, radius, angle=0, center=None):
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle(box, radius=radius, fill=255)
    if angle:
        m = m.rotate(angle, resample=Image.BICUBIC, center=center)
    return m

def card(canvas, box, radius, fill, angle=0, shadow=0.0, shadow_offset=(0, 40)):
    cx = (box[0] + box[2]) / 2
    cy = (box[1] + box[3]) / 2
    if shadow > 0:
        sh = rounded_mask(canvas.size, (box[0] + shadow_offset[0], box[1] + shadow_offset[1], box[2] + shadow_offset[0], box[3] + shadow_offset[1]), radius, angle, (cx, cy + shadow_offset[1]))
        sh = sh.filter(ImageFilter.GaussianBlur(70))
        shadow_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        shadow_layer.putalpha(sh.point(lambda v: int(v * shadow)))
        canvas.alpha_composite(shadow_layer)
    m = rounded_mask(canvas.size, box, radius, angle, (cx, cy))
    if isinstance(fill, Image.Image):
        layer = fill
    else:
        layer = Image.new("RGBA", canvas.size, fill)
    alpha = Image.new("L", canvas.size, 0)
    alpha.paste(m, (0, 0))
    base_alpha = layer.getchannel("A")
    combined = Image.composite(base_alpha, Image.new("L", canvas.size, 0), alpha)
    layer = layer.copy()
    layer.putalpha(combined)
    canvas.alpha_composite(layer)

def draw_icon(style):
    if style == "light":
        bg = gradient_fast((S, S), (32, 178, 170, 255), (10, 92, 104, 255))
        back1, back2 = (255, 255, 255, 70), (255, 255, 255, 130)
        frame = (255, 255, 255, 255)
        sky_top, sky_bottom = (186, 236, 232, 255), (236, 250, 248, 255)
        far, near = (79, 170, 166, 255), (14, 110, 118, 255)
        sun = (255, 196, 64, 255)
        shadow = 0.35
    elif style == "dark":
        bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        back1, back2 = (52, 199, 190, 70), (52, 199, 190, 130)
        frame = (34, 46, 50, 255)
        sky_top, sky_bottom = (22, 70, 76, 255), (30, 96, 100, 255)
        far, near = (52, 170, 165, 255), (90, 214, 204, 255)
        sun = (255, 196, 64, 255)
        shadow = 0.6
    else:  # tinted: grayscale, the system applies the tint
        bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        back1, back2 = (255, 255, 255, 60), (255, 255, 255, 115)
        frame = (235, 235, 235, 255)
        sky_top, sky_bottom = (90, 90, 90, 255), (120, 120, 120, 255)
        far, near = (175, 175, 175, 255), (255, 255, 255, 255)
        sun = (255, 255, 255, 255)
        shadow = 0.5

    canvas = bg.copy()
    if style == "light":
        # soft light from the top left
        glow = Image.new("L", (S, S), 0)
        ImageDraw.Draw(glow).ellipse((-S * 0.35, -S * 0.45, S * 0.75, S * 0.55), fill=45)
        glow = glow.filter(ImageFilter.GaussianBlur(500))
        light = Image.new("RGBA", (S, S), (255, 255, 255, 0))
        light.putalpha(glow)
        canvas.alpha_composite(light)

    w, h = 2560, 1880          # front card
    x0, y0 = (S - w) // 2, 1300
    r = 300
    # loose photos behind, fanning in
    card(canvas, (x0 + 120, y0 - 330, x0 + w - 120, y0 + h - 330), r, back1, angle=7)
    card(canvas, (x0 + 60, y0 - 170, x0 + w - 60, y0 + h - 170), r, back2, angle=-4)
    # front photo with frame
    card(canvas, (x0, y0, x0 + w, y0 + h), r, frame, shadow=shadow)
    inset = 130
    ix0, iy0, ix1, iy1 = x0 + inset, y0 + inset, x0 + w - inset, y0 + h - inset
    photo = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sky = gradient_fast((ix1 - ix0, iy1 - iy0), sky_top, sky_bottom)
    photo.paste(sky, (ix0, iy0))
    d = ImageDraw.Draw(photo)
    sr = 230
    sx, sy = ix0 + 560, iy0 + 520
    d.ellipse((sx - sr, sy - sr, sx + sr, sy + sr), fill=sun)
    base = iy1
    d.polygon([(ix0 - 50, base), (ix0 + 980, iy0 + 640), (ix0 + 1700, base)], fill=far)
    d.polygon([(ix0 + 700, base), (ix0 + 1620, iy0 + 470), (ix1 + 60, iy0 + 1180), (ix1 + 60, base)], fill=near)
    inner = rounded_mask((S, S), (ix0, iy0, ix1, iy1), r - inset + 40)
    photo.putalpha(Image.composite(photo.getchannel("A"), Image.new("L", (S, S), 0), inner))
    canvas.alpha_composite(photo)
    return canvas.resize((OUT, OUT), Image.LANCZOS)

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    draw_icon("light").convert("RGB").save(f"{out}/AppIcon-1024.png")  # App Store icon: no alpha
    draw_icon("dark").save(f"{out}/AppIcon-Dark-1024.png")
    draw_icon("tinted").convert("LA").save(f"{out}/AppIcon-Tinted-1024.png")
    print("icons written to", out)
