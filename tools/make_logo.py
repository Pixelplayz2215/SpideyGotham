"""Draws the SPIDER-MAN wordmark the mod puts on the main-menu logo in place of the word BATMAN (original art).

The game's logo (2048x512) is read from the player's own install at run time; the mod erases the BATMAN word and
draws this overlay in its place, so no game art is shipped. Layout and colours were measured from that logo:
  word box      x 614-1950, cap height y 150-405 (the DC emblem and its swoosh sit above, y < 172)
  letter fill   chrome: near white at the top fading to blue-grey at the bottom, thin dark edge
usage: python make_logo.py <font.ttf> <out.tga> [<game logo.tga> <preview.png>]"""
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

FONT, OUT = sys.argv[1], sys.argv[2]
W, H = 2048, 512
X0, X1, Y0, Y1 = 618, 1946, 152, 404           # target box for the letters
TEXT = "SPIDER-MAN"

# render big, then fit the ink exactly into the box (the original's letters are wide and fill it edge to edge)
font = ImageFont.truetype(FONT, 400)
tmp = Image.new("L", (4000, 700), 0)
ImageDraw.Draw(tmp).text((50, 50), TEXT, font=font, fill=255)
ink = tmp.crop(tmp.getbbox())
mask = ink.resize((X1 - X0, Y1 - Y0), Image.LANCZOS)

# chrome fill: top -> bottom gradient sampled from the original letters
stops = [(0.00, (255, 255, 255)), (0.45, (238, 241, 246)), (0.70, (196, 203, 214)), (1.00, (150, 160, 178))]


def chrome(t):
    for (ta, ca), (tb, cb) in zip(stops, stops[1:]):
        if ta <= t <= tb:
            k = (t - ta) / (tb - ta)
            return tuple(round(a + (b - a) * k) for a, b in zip(ca, cb))
    return stops[-1][1]


fill = Image.new("RGBA", (X1 - X0, Y1 - Y0))
fd = ImageDraw.Draw(fill)
for y in range(Y1 - Y0):
    fd.line([(0, y), (X1 - X0, y)], fill=chrome(y / (Y1 - Y0 - 1)) + (255,))
letters = Image.new("RGBA", (X1 - X0, Y1 - Y0), (0, 0, 0, 0))
letters.paste(fill, (0, 0), mask)

# thin dark edge around the letters, like the original
edge = mask.filter(ImageFilter.MaxFilter(7))
out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
dark = Image.new("RGBA", (X1 - X0, Y1 - Y0), (18, 22, 34, 255))
out.paste(dark, (X0, Y0), edge)
out.alpha_composite(letters, (X0, Y0))
# uncompressed 32-bit TGA, top-left origin: the mod's Lua reads it byte by byte (BGRA after an 18-byte header)
with open(OUT, "wb") as f:
    f.write(bytes([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, W % 256, W // 256, H % 256, H // 256, 32, 0x28]))
    r, g, b, a = out.split()
    f.write(Image.merge("RGBA", (b, g, r, a)).tobytes())

if len(sys.argv) > 4:   # dev preview on top of the player's logo, with BATMAN erased the same way the mod does it
    logo = Image.open(sys.argv[3]).convert("RGBA")
    px = logo.load()
    for y in range(140, 414):
        for x in range(600, 1994):
            if y < 172 and 1150 <= x <= 1410:   # keep the DC emblem
                continue
            px[x, y] = (0, 0, 0, 0)
    logo.alpha_composite(out)
    bg = Image.new("RGBA", logo.size, (24, 26, 34, 255))
    bg.alpha_composite(logo)
    bg.resize((1024, 256), Image.LANCZOS).save(sys.argv[4])
