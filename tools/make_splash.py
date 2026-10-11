"""Draws the background of the Spider-Man launch splash (original art): night sky, moon, a blocky brick skyline and
the SPIDER-MAN wordmark. The game shows Content/Splash/Splash.bmp (720x370, 24-bit) before any mod loads; the mod
renders the player's own suited minifig in game and places it in SPIDEY_BOX of this background, then writes the
result there (the original is backed up next to it first). No game art is shipped.
usage: python make_splash.py <font.ttf> <out.tga> [<preview.png>]"""
import random
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

FONT, OUT = sys.argv[1], sys.argv[2]
W, H = 720, 370
SPIDEY_BOX = (40, 20, 330, 370)          # x0, y0, x1, y1: where the mod puts the rendered minifig (bottom-aligned)
WORD_BOX = (340, 120, 700, 195)          # SPIDER-MAN
SUB_BOX = (372, 205, 668, 228)           # subtitle
random.seed(7)

img = Image.new("RGBA", (W, H))
d = ImageDraw.Draw(img)
# sky: deep navy at the top to a dusky violet near the skyline
for y in range(H):
    t = y / (H - 1)
    c = (int(10 + 40 * t), int(14 + 12 * t), int(38 + 42 * t))
    d.line([(0, y), (W, y)], fill=c + (255,))

# moon with a soft glow, behind the hero
glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
MX, MY, MR = 190, 120, 92
gd.ellipse([MX - MR - 40, MY - MR - 40, MX + MR + 40, MY + MR + 40], fill=(170, 190, 230, 90))
glow = glow.filter(ImageFilter.GaussianBlur(28))
img.alpha_composite(glow)
d.ellipse([MX - MR, MY - MR, MX + MR, MY + MR], fill=(214, 222, 236, 255))
for _ in range(9):   # craters
    cx, cy, r = MX + random.randint(-60, 60), MY + random.randint(-60, 60), random.randint(6, 16)
    if (cx - MX) ** 2 + (cy - MY) ** 2 < (MR - r) ** 2:
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(192, 202, 220, 255))

# a few stars
for _ in range(70):
    x, y = random.randint(0, W - 1), random.randint(0, 170)
    if (x - MX) ** 2 + (y - MY) ** 2 > (MR + 30) ** 2:
        v = random.randint(140, 230)
        d.point((x, y), fill=(v, v, min(255, v + 20), 255))


def skyline(base_y, hmin, hmax, colour, window, studs):
    x = -10
    while x < W:
        w = random.randint(34, 70)
        h = random.randint(hmin, hmax)
        top = base_y - h
        d.rectangle([x, top, x + w, H], fill=colour)
        if studs:   # brick studs on the roofs
            for sx in range(x + 5, x + w - 6, 12):
                d.rectangle([sx, top - 4, sx + 7, top], fill=colour)
        if window:
            for wy in range(top + 8, H - 6, 14):
                for wx in range(x + 6, x + w - 8, 11):
                    if random.random() < 0.28:
                        d.rectangle([wx, wy, wx + 4, wy + 6], fill=window)
        x += w + random.randint(0, 6)


skyline(H - 40, 70, 170, (26, 26, 48, 255), (90, 80, 60, 255), False)      # far
skyline(H - 10, 40, 120, (14, 14, 28, 255), (230, 180, 90, 255), True)      # near
# rooftop ledge the hero stands on
d.rectangle([0, H - 14, W, H], fill=(8, 8, 16, 255))


def fit_text(text, box, fill, edge):
    font = ImageFont.truetype(FONT, 200)
    tmp = Image.new("L", (6000, 400), 0)
    ImageDraw.Draw(tmp).text((20, 20), text, font=font, fill=255)
    ink = tmp.crop(tmp.getbbox())
    bw, bh = box[2] - box[0], box[3] - box[1]
    scale = min(bw / ink.width, bh / ink.height)
    mask = ink.resize((int(ink.width * scale), int(ink.height * scale)), Image.LANCZOS)
    x = box[0] + (bw - mask.width) // 2
    y = box[1] + (bh - mask.height) // 2
    if edge:
        img.paste(Image.new("RGBA", mask.size, edge), (x, y), mask.filter(ImageFilter.MaxFilter(5)))
    layer = Image.new("RGBA", mask.size)
    ld = ImageDraw.Draw(layer)
    for yy in range(mask.height):
        t = yy / max(1, mask.height - 1)
        ld.line([(0, yy), (mask.width, yy)], fill=tuple(int(a + (b - a) * t) for a, b in zip(fill[0], fill[1])) + (255,))
    img.paste(layer, (x, y), mask)


fit_text("SPIDER-MAN", WORD_BOX, ((255, 255, 255), (165, 175, 195)), (18, 22, 34, 255))
fit_text("SWINGING THROUGH GOTHAM", SUB_BOX, ((255, 80, 70), (215, 35, 35)), (18, 22, 34, 255))

with open(OUT, "wb") as f:   # 32-bit TGA, top-left origin, read byte by byte by the mod's Lua
    f.write(bytes([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, W % 256, W // 256, H % 256, H // 256, 32, 0x28]))
    r, g, b, a = img.split()
    f.write(Image.merge("RGBA", (b, g, r, a)).tobytes())
if len(sys.argv) > 3:
    prev = img.copy()
    ImageDraw.Draw(prev).rectangle(SPIDEY_BOX, outline=(255, 0, 0, 255))
    prev.save(sys.argv[3])
print("wrote", OUT)
