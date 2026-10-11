"""Draws the LEGO Spider-Man print the mod puts on LEGO Batman's minifig (original art made for this mod).

The layout was measured in the running game with a 16x16 labelled grid (64 px cells, columns A-P, rows 0-15)
on the minifig's body texture page, viewed front/back/left/right with the animated face hidden:
  torso front  A-G, rows 6-10   (centre x 224)        torso back  G-L, rows 6-10 (centre x 576)
  head front   D-F, rows 14-15  (centre x 288, y 930)  head back   D-F, rows 11-13, sides B-C / G
  arms         I-K and M-O, rows 12-14                hips        O-P, rows 5-10
  legs         all columns, rows 0-3                   feet        all columns, rows 4-5
  hands        A (x<48), rows 5-10                      shoulder tops  row 15 under the arm blocks
Everything else (hands, neck, cuffs) is plain suit red; torso side panels are blue.
usage: python make_spidey_prints.py <out dir>"""
import math, os, sys
from PIL import Image, ImageDraw

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
SS = 2                                   # supersample for smooth lines
W = 1024 * SS
RED, BLUE, BLACK, WHITE, DARK_RED = (200, 20, 34, 255), (30, 62, 158, 255), (14, 14, 16, 255), (248, 248, 248, 255), (140, 10, 22, 255)


def s(v):
    return int(round(v * SS))


def clip_paste(base, layer, box):
    mask = Image.new("L", base.size, 0)
    ImageDraw.Draw(mask).rectangle([s(box[0]), s(box[1]), s(box[2]) - 1, s(box[3]) - 1], fill=255)
    alpha = Image.composite(layer.split()[3], Image.new("L", base.size, 0), mask)
    base.paste(layer, (0, 0), alpha)


def bez(p0, p1, p2, n=12):
    return [(((1 - t) ** 2) * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0], ((1 - t) ** 2) * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]) for t in [i / n for i in range(n + 1)]]


def radial_web(cx, cy, radius, spokes, rings, width, sag=0.86, start=-math.pi / 2):
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy, radius, width = s(cx), s(cy), s(radius), s(width)
    angles = [start + 2 * math.pi * i / spokes for i in range(spokes)]
    for a in angles:
        d.line([(cx, cy), (cx + radius * math.cos(a), cy + radius * math.sin(a))], fill=BLACK, width=width)
    for r in range(1, rings + 1):
        rr = radius * (r / rings) ** 1.15
        for i in range(spokes):
            a0 = angles[i]
            a1 = a0 + 2 * math.pi / spokes
            p0 = (cx + rr * math.cos(a0), cy + rr * math.sin(a0))
            p1 = (cx + rr * math.cos(a1), cy + rr * math.sin(a1))
            am = (a0 + a1) / 2
            pm = (cx + rr * sag * math.cos(am), cy + rr * sag * math.sin(am))
            d.line(bez(p0, pm, p1, 8), fill=BLACK, width=width, joint="curve")
    return layer


def mesh_web(box, step, width, sag=5):
    """Rectangular web mesh (arms, boots): verticals plus gently sagging horizontals."""
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    x0, y0, x1, y1 = box
    for x in range(x0 + step // 2, x1, step):
        d.line([(s(x), s(y0)), (s(x), s(y1))], fill=BLACK, width=s(width))
    for y in range(y0 + step // 2, y1, step):
        pts = [(s(x), s(y + sag * math.sin(math.pi * ((x - x0) % step) / step))) for x in range(x0, x1 + 1, max(2, step // 8))]
        d.line(pts, fill=BLACK, width=s(width), joint="curve")
    return layer


def spider(d, cx, cy, size, colour, flip=False):
    """Classic Spider-Man chest spider: small head, body, four bent legs per side (size = height in px)."""
    k = size / 100.0
    f = -1 if flip else 1  # flip=True turns it 180 degrees (the back of the torso is laid out upside down)
    X = lambda v: s(cx + f * v * k)
    Y = lambda v: s(cy + f * v * k)
    box = lambda x0, y0, x1, y1: [min(X(x0), X(x1)), min(Y(y0), Y(y1)), max(X(x0), X(x1)), max(Y(y0), Y(y1))]
    d.ellipse(box(-8, -36, 8, -20), fill=colour)            # head
    d.ellipse(box(-12, -24, 12, 4), fill=colour)            # thorax
    d.polygon([(X(0), Y(0)), (X(13), Y(16)), (X(9), Y(42)), (X(0), Y(52)), (X(-9), Y(42)), (X(-13), Y(16))], fill=colour)  # abdomen
    w = max(2, s(5 * k))
    legs = [((6, -16), (30, -44), (44, -22)), ((9, -10), (40, -18), (54, 4)), ((9, -4), (38, 12), (48, 38)), ((7, 2), (26, 32), (30, 60))]
    for side in (-1, 1):
        for a, b, c in legs:
            d.line([(X(side * a[0]), Y(a[1])), (X(side * b[0]), Y(b[1])), (X(side * c[0]), Y(c[1]))], fill=colour, width=w, joint="curve")


def spidey_eye(d, cx, cy, w, h, side, outline):
    """Movie-style Spidey lens: big almond, rounded near the nose, sweeping up and out to a point; thick black rim.
    side = +1 viewer-right."""
    # The face mesh folds a smile-shaped band of the decal out of sight (rows ~346-384 across decal x ~198-302,
    # its mouth area), so each lens's inner-bottom bulges round (convex, never notched) while staying just above the fold.
    # control polygon, outer tip first; Chaikin smoothing rounds every corner except the tip, so the inner edge and
    # the bottom flow into each other without a notch
    ctrl = [(0.56 * w, -0.56 * h), (0.50 * w, 0.20 * h), (0.12 * w, 0.56 * h), (-0.30 * w, 0.40 * h),
            (-0.52 * w, 0.10 * h), (-0.40 * w, -0.18 * h), (0.02 * w, -0.40 * h)]
    pts = ctrl
    for _ in range(5):
        nxt = [pts[0]]
        for i in range(len(pts)):
            (ax, ay), (bx, by) = pts[i], pts[(i + 1) % len(pts)]
            if i > 0:
                nxt.append((0.75 * ax + 0.25 * bx, 0.75 * ay + 0.25 * by))
            if (i + 1) % len(pts) != 0:
                nxt.append((0.25 * ax + 0.75 * bx, 0.25 * ay + 0.75 * by))
        pts = nxt
    poly = [(s(cx + side * x), s(cy + y)) for x, y in pts]
    d.polygon(poly, fill=BLACK)
    d.line(poly + [poly[0]], fill=BLACK, width=s(2 * outline), joint="curve")   # even-width rim, no pinching
    for x, y in poly:                                                             # round the rim's outer edge
        d.ellipse([x - s(outline), y - s(outline), x + s(outline), y + s(outline)], fill=BLACK)
    d.polygon(poly, fill=(236, 240, 244, 255))


img = Image.new("RGBA", (W, W), RED)
d = ImageDraw.Draw(img)

# legs blue on every side (rows 0-3); P rows 11-15 is the inner side of the arms (red, webbed below)
d.rectangle([0, 0, s(1024) - 1, s(256) - 1], fill=BLUE)
clip_paste(img, mesh_web((960, 704, 1024, 1024), 36, 2), (960, 704, 1024, 1024))
# torso sides and top (M-P rows 5-10) are red with webbing like the chest (player's choice); only the hips are
# blue: front hip band = P rows 6-9, back hip band = M-O row 7 and M-N row 10 (measured with colour-coded regions)
clip_paste(img, mesh_web((768, 320, 1024, 704), 20, 2), (768, 320, 1024, 704))   # finer, to match chest/back
# Probed with paired real/position-coded renders from six angles (blue must keep clear of the small torso islands,
# or it bleeds onto them at a distance):
#   torso side panels: left x 886-914, right x 916-950, both y 350-402 (tiny islands, each drawn as its own panel)
#   belt: front = P column from y 403 down; back = x 784-960, y 448-512; end faces just under the side panels,
#         x 850-952, y 403-422 (left end runs on to y 448)
#   torso back's right edge samples x 768-783 of the back band row, so that stays red
d.rectangle([s(960), s(403), s(1024) - 1, s(704) - 1], fill=BLUE)   # belt front (P column)
d.rectangle([s(784), s(448), s(960) - 1, s(512) - 1], fill=BLUE)   # belt back
d.rectangle([s(850), s(403), s(952) - 1, s(422) - 1], fill=BLUE)   # belt end faces, right and left
d.rectangle([s(850), s(403), s(880) - 1, s(448) - 1], fill=BLUE)
for x0, x1 in ((886, 916), (916, 952)):                             # side panels: the same web on both
    img.paste(RED, [s(x0), s(348), s(x1), s(403)])
    clip_paste(img, mesh_web((x0, 348, x1, 403), 15, 2, sag=3), (x0, 348, x1, 403))
d.rectangle([s(768), s(640), s(896) - 1, s(704) - 1], fill=BLUE)
# leg connector (the peg between the legs) is blue like the legs: front = N-O row 8, back = A row 12; A row 11 is
# the thin strip above the back of the belt (found with colour-coded cells rendered front and back)
for x0, y0 in ((832, 512), (896, 512), (0, 768), (0, 704)):
    d.rectangle([s(x0), s(y0), s(x0 + 64) - 1, s(y0 + 64) - 1], fill=BLUE)

# torso front: radial web from the sternum, spider centred on the chest
clip_paste(img, radial_web(224, 520, 330, 16, 7, 3), (48, 384, 432, 704))  # x<48 is the hands (column A, rows 5-10)
spider(d, 224, 500, 120, BLACK)

# torso back: radial web, black spider (texture area is upside down on the model, so drawn flipped)
clip_paste(img, radial_web(576, 520, 320, 16, 7, 3), (400, 384, 768, 704))
spider(d, 576, 515, 150, BLACK, flip=True)   # upright on the minifig, black like the front

# arms: web mesh (hands stay plain red)
clip_paste(img, mesh_web((512, 768, 704, 960), 40, 2), (512, 768, 704, 960))
clip_paste(img, mesh_web((768, 768, 960, 960), 40, 2), (768, 768, 960, 960))

# boots (row 4, x 0-996 across both feet, probed): the same web mesh on every 64 px foot cell, so both feet match
for x0 in range(0, 1024, 64):
    clip_paste(img, mesh_web((x0, 256, x0 + 64, 320), 32, 2), (x0, 256, x0 + 64, 320))

# ---- head plastic: continues the face decal's web around the sides, back and top of the head.
# Layout measured with position-coded textures rendered in base colour (face decal and body page together):
#   band 1  x 93-372, y ~710-861   right side -> back -> left side (top of the head at the top)
#   band 2  x 93-372, y 877-1010   strips beside the face decal: x 126 meets the decal's left edge (decal x 0),
#                                  x 331 its right edge (decal x 506); decal y -> band-2 y = 877 + (y - 92) * 0.376
#   seams   band 1 x 372 = band 2 x 93 (left side), band 2 x 372 = band 1 x 93 (right side),
#           band-1 y = 763.9 + (band-2 y - 910.8) * 0.986 (fitted to where drawn lines met in a render)
#   top     the head-top disk (and stud top) is a planar map: x 10-61 left to right, y 964 (back) to ~1005
#           (front, where it meets the decal's top edge at decal y 92)
# Every face web spoke that leaves the decal's side edges carries on round the head as a straight line at the same
# height; ring strands between them bow toward the face like the decal's rings. Spokes leaving the top edge carry
# on over the top of the head.
FACE_C, FACE_R, FACE_SPOKES, FACE_RINGS = (256, 330), 400, 18, 8


def face_spokes():
    return [-math.pi / 2 + 2 * math.pi * i / FACE_SPOKES for i in range(FACE_SPOKES)]


def side_latitudes():
    ys = []
    for edge in (0, 506):
        for a in face_spokes():
            c = math.cos(a)
            t = (edge - FACE_C[0]) / c if abs(c) > 1e-6 else -1
            if 0 < t <= FACE_R and 92 <= FACE_C[1] + t * math.sin(a) <= 446:
                ys.append(FACE_C[1] + t * math.sin(a))
    ys.sort()
    return [(ys[i] + ys[i + 1]) / 2 for i in range(0, len(ys) - 1, 2)]   # left/right hits pair up


def band2_y(y):
    return 877 + (y - 92) * 0.376


def band1_y(y2):
    return 763.9 + (y2 - 910.8) * 0.986


def wrap_web(box, lines, strand_xs, face_dir, width):
    """Straight lines at heights `lines` plus ring strands at `strand_xs` between them; face_dir(x) = +1/-1 says
    which way the face is from x, and the strands bow that way like the decal's rings."""
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    x0, y0, x1, y1 = box
    for y in lines:
        d.line([(s(x0), s(y)), (s(x1), s(y))], fill=BLACK, width=s(width))
    stops = [y0] + list(lines) + [y1]
    for x in strand_xs:
        for ya, yb in zip(stops, stops[1:]):
            bow = face_dir(x) * min(6, (yb - ya) * 0.18)
            d.line([(s(px), s(py)) for px, py in bez((x, ya), (x + bow, (ya + yb) / 2), (x, yb), 10)], fill=BLACK, width=s(width), joint="curve")
    return layer


img.paste(RED, [s(0), s(704), s(448), s(1024)])
lat2 = [band2_y(y) for y in side_latitudes()]
lat1 = [band1_y(y) for y in lat2 if band1_y(y) < 858]
lat1 = [lat1[0] - 34] + lat1          # the band runs on above the head's widest point, toward the top
# band 1: strands every ~35 texels (the decal's ring spacing), bowing toward whichever side of the head the face is
clip_paste(img, wrap_web((86, 708, 380, 866), lat1, range(104, 372, 26), lambda x: -1 if x < 232 else 1, 1.4),
           (86, 708, 380, 866))
# band 2 side strips (left side x 93-126, right side x 331-372): one ring strand each
clip_paste(img, wrap_web((86, 872, 130, 1014), lat2, [108], lambda x: 1, 1.4), (86, 872, 130, 1014))
clip_paste(img, wrap_web((327, 872, 380, 1014), lat2, [352], lambda x: -1, 1.4), (327, 872, 380, 1014))
# head top: the spokes leaving the decal's top edge run on over the top to the back; two rings cross them
top = Image.new("RGBA", (W, W), (0, 0, 0, 0))
td = ImageDraw.Draw(top)
for a in face_spokes():
    if math.sin(a) < -1e-6:
        x = FACE_C[0] + (92 - FACE_C[1]) / math.sin(a) * math.cos(a)
        if 0 <= x <= 506:
            tx = 10 + x / 506 * 51
            td.line([(s(tx), s(958)), (s(tx), s(1012))], fill=BLACK, width=s(0.9))
for ty in (976, 992):
    td.line([(s(px), s(py)) for px, py in bez((6, ty), (36, ty + 3), (66, ty), 12)], fill=BLACK, width=s(0.9), joint="curve")
clip_paste(img, top, (4, 956, 68, 1014))
# the back of the leg connector (A row 12) and the strip above the back of the belt (A row 11) sit in this page area
# (the connector only uses y 768-786 of its cell; y 815-832 is the inside wall of the head stud, kept red)
d.rectangle([s(0), s(768), s(64) - 1, s(800) - 1], fill=BLUE)
d.rectangle([s(0), s(704), s(64) - 1, s(768) - 1], fill=BLUE)
# a sliver of the torso's back-left edge samples texels inside the head area (x 404-448, y 716-800): give it the
# torso's fine web instead of stray head-web strokes
img.paste(RED, [s(404), s(716), s(448), s(800)])
clip_paste(img, mesh_web((404, 716, 448, 800), 12, 1.2, sag=2), (404, 716, 448, 800))

# The player hand-finished the body print (art/spidey_body.png, 2026-10-10). When that master is passed as the
# second argument it is shipped as-is and the drawing above only serves as the starting point it was made from.
if len(sys.argv) > 2 and os.path.exists(sys.argv[2]):
    Image.open(sys.argv[2]).convert("RGBA").save(os.path.join(OUT, "spidey_body.png"))
else:
    img.resize((1024, 1024), Image.LANCZOS).save(os.path.join(OUT, "spidey_body.png"))

# ---- face decal (HeadLowerUnder BC on the animated face, 512): web mask with classic eyes ----
# Measured live: this decal wraps the head front; its web centre (256, 300) lands mid-face and eyes drawn at
# 256 +/- 92, y 268 sit where LEGO eyes go. It follows the head when the minifig looks around.
W = 512 * SS
img = Image.new("RGBA", (W, W), RED)
d = ImageDraw.Draw(img)
web = radial_web(256, 330, 400, 18, 8, 3)
img.paste(web, (0, 0), web)
for side in (-1, 1):
    spidey_eye(d, 256 + side * 104, 272, 148, 134, side, 14)   # high enough that the lenses clear the face mesh's fold
img.resize((512, 512), Image.LANCZOS).save(os.path.join(OUT, "spidey_head.png"))
# ---- plain shine map (MMR): Batman's marks his metal parts (bat emblem, buckles) in red; Spidey is all plastic.
# Batman's plain-plastic pixel is linear (0, 0, 41); imported PNGs are read as sRGB, so store 255*(41/255)^(1/2.2) = 111.
Image.new("RGBA", (64, 64), (0, 0, 111, 255)).save(os.path.join(OUT, "spidey_mmr.png"))
print("wrote", OUT)
