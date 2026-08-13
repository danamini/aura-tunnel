#!/usr/bin/env python3
"""Table generator for AURA TUNNEL (48K ZX Spectrum demo).

Everything expensive is baked here at build time, the way real demos
precalc; the Z80 only copies, pops and looks up.  Outputs (build/):

  maps.bin      tunnel maps: 3 geometries (circle/square/star) x 2 bob
                phases x 21 attr rows x 32 cols x [Ptop, Pbot].  A map
                byte is bit7 half | angle<<4 | depth.
  shadep/i0/1   colour LUT sources, cool and warm palettes: 2KB each,
                indexed (wedge<<8 | depth<<4 | ring).
  etab.bin      the LUT builder's next-texture-coordinate table.
  rainbow.bin   cyclic ink strip under the snake scroller.
  sintab.bin    sine 0..16: snake wave, letter bounce, surge speeds.
  snake.asm     generated single-pass blit code, one routine per offset.
  mustab.bin    8-bar beeper score: [wait_lo, wait_hi, halfperiods, 0]
                per step; wait loop costs 26T/iter + 35T.
  stickman.bin  8-pose articulated walk cycle, 16x40 chunky.
  ministick.bin the same poses 2x2-downsampled for the background walker.
  gpat.bin      parallax ground dash strips (fast + slow bands).
  stars.bin     48 star records [xfrac, xint, y, attr], 3 speed layers.
  yiear.bin     6 Yie Ar Kung-Fu frames + mirrors, 40x40 1-bit
                (sliced from assets/oolong-sheet.png when Pillow is present).
  cube.bin      128 perspective-projected rotation frames, 8 vertices.
  minicube.bin  32 frames of the same cube rasterized 16x16.
  cubeattr.bin  rainbow ring attrs behind the wireframe.
  g3d0/1/2.bin  hidden-line surface plots (ripple/eggbox/saddle) as
                visible-point rows [count, sx0, py|0xFF...].
"""
import math
import os
import random
import sys

out = sys.argv[1] if len(sys.argv) > 1 else "build"
os.makedirs(out, exist_ok=True)

COLS, ATTR_ROWS = 32, 21
MAPS_PER_SCENE = 2  # bob phases; the asm ping-pongs 0,1,0,1
K = 230.0  # perspective constant: smaller = tighter vanishing point


def write(name, data):
    with open(os.path.join(out, name), "wb") as f:
        f.write(bytes(data))
    print(f"  {name}: {len(data)} bytes")


# ---------------------------------------------------------------- tunnel maps
# 3 scene geometries x 4 maps with the vanishing point bobbing in a circle:
# cheap "camera wobble" -- the per-frame code just repoints SP at a map.
def r_circle(x, y):
    return math.hypot(x, y)


def r_square(x, y):
    return max(abs(x) * 0.85, abs(y))


def r_star(x, y):
    return math.hypot(x, y) / (1.0 + 0.30 * math.cos(4 * math.atan2(y, x)))


SCENES = [r_circle, r_square, r_star]

maps = bytearray()
for radius in SCENES:
    for k in range(MAPS_PER_SCENE):
        ph = 2 * math.pi * k / MAPS_PER_SCENE
        cx = 128.0 + 18.0 * math.cos(ph)   # real-pixel centre
        cy = 84.0 + 12.0 * math.sin(ph)
        for row in range(ATTR_ROWS):
            for col in range(COLS):
                for half in (0, 1):        # 0 = top half-block, 1 = bottom
                    x = (col + 0.5) * 8.0 - cx
                    y = (row * 2 + half + 0.5) * 4.0 - cy
                    r = radius(x, y)
                    d = min(15, int(K / max(r, 1.0)))
                    a = int(((math.atan2(y, x) / (2 * math.pi)) % 1.0) * 8) & 7
                    maps.append((half << 7) | (a << 4) | d)
assert len(maps) == len(SCENES) * MAPS_PER_SCENE * ATTR_ROWS * 64 == 8064
write("maps.bin", maps)

# --------------------------------------------------------------- shade tables
# Index: a2 = rotated wedge, d = spatial depth (0 outer/near .. 15 centre/far),
# d2 = scrolled texture ring.  Rings alternate colour pairs chosen by spatial
# depth band (so the tunnel darkens toward the vanishing point), a white
# pulse ring flies outward once per texture cycle, and wedge 0 is one band
# brighter -- a radar sweep that makes the rotation readable.
# Two palettes; the demo alternates them on every scene change.
PALETTES = [
    [(7, 5), (5, 4), (4, 1), (1, 0)],  # cool: white/cyan/green/blue/black
    [(7, 6), (6, 2), (2, 3), (3, 0)],  # warm: white/yellow/red/magenta/black
]

for p, bands in enumerate(PALETTES):
    shp, shi = bytearray(2048), bytearray(2048)
    for a2 in range(8):
        for d in range(16):
            for d2 in range(16):
                band = d >> 2
                b = max(0, band - (1 if a2 == 0 else 0))
                if d2 == 0:
                    c = 7  # pulse ring, all the way to the vanishing point
                else:
                    c = bands[b][(d2 >> 1) & 1]  # two-step rings: calm
                i = (a2 << 8) | (d << 4) | d2
                shp[i] = (c << 3) | 0x40
                shi[i] = c
    write(f"shadep{p}.bin", shp)
    write(f"shadei{p}.bin", shi)

# --------------------------------------------------- LUT-builder step table
write("etab.bin", bytes(((e + 0x10) & 0xF0) | ((e + 1) & 0x0F)
                        for e in range(256)))

# ------------------------------------------------------- scroller attr strip
ramp = [1, 1, 1, 5, 5, 4, 4, 7, 7, 7, 7, 4, 4, 5, 5, 1]  # blue-cyan-green-white
strip = [0x40 | ramp[(i // 2) % 16] for i in range(32)]
write("rainbow.bin", bytes(strip * 4))

# ------------------------------------------------------- scroller snake sine
write("sintab.bin", bytes(min(16, max(0, round(8 + 8 * math.sin(2 * math.pi * i / 256))))
                          for i in range(256)))

# ------------------------------------------------- snake scroller blit code
# One specialised routine per (even) vertical offset 0..16: paints a single
# 8px column of the 24-line scroller window top-to-bottom in ONE pass -
# zeros above the glyph strip, 8 glyph bytes, zeros below.  Single-pass
# means the raster can never catch a half-erased column.
# Entry: HL = glyph column (8 bytes), DE = screen column top, A = anything.
# Char-row boundaries (after lines 7 and 15): D -= 7, E += 0x20.
lines_of = []
for K in range(0, 17, 2):
    src = [f"SNK{K}:"]
    a_zero = False  # zero stores need A == 0; data stores and fixups spoil A
    for L in range(24):
        if L in (8, 16):
            src += ["        ld a,d", "        sub 7", "        ld d,a",
                    "        ld a,e", "        add a,$20", "        ld e,a"]
            a_zero = False
        if K <= L < K + 8:
            src += ["        ld a,(hl)", "        ld (de),a"]
            if L < K + 7:       # step to the next buffer line (stride 32)
                src += ["        ld a,l", "        add a,32", "        ld l,a"]
            a_zero = False
        else:
            if not a_zero:
                src.append("        xor a")
                a_zero = True
            src.append("        ld (de),a")
        if L not in (7, 15, 23):
            src.append("        inc d")
    src.append("        ret")
    lines_of.append("\n".join(src))

snake = "\n".join(lines_of) + "\nJTAB:\n" + \
    "        dw " + ", ".join(f"SNK{K}" for K in range(0, 17, 2)) + "\n"
with open(os.path.join(out, "snake.asm"), "w") as f:
    f.write(snake)
print("  snake.asm: %d variants" % len(lines_of))

# ------------------------------------------------------------ beeper music
# 32-step pattern, one step per 8 frames (0.16s; a full loop = one scene
# slot).  Each frame the demo plays one ~10.5k T-state burst of the step's
# note in its spare time.  Entry: [halfperiod_lo, halfperiod_hi, count, 0]
# where the wait loop costs 26T/iter + 35T per half-period.
NOTE_HZ = {"A3": 220, "E4": 330, "F4": 349, "G4": 392, "A4": 440,
           "B4": 494, "C5": 523, "D5": 587, "E5": 659, "F5": 698,
           "G5": 784, "A5": 880}
PATTERN = [  # Korobeiniki - the 19th-century folk melody, PD
    "E5","E5","B4","C5","D5","D5","C5","B4",   # bar 1
    "A4","A4","A4","C5","E5","E5","D5","C5",
    "B4","B4","B4","C5","D5","D5","E5","E5",   # bar 2
    "C5","C5","A4","A4","A4","A4",None,None,
    "D5","D5","D5","F5","A5","A5","G5","F5",   # bar 3
    "E5","E5","E5","C5","E5","E5","D5","C5",
    "B4","B4","B4","C5","D5","D5","E5","E5",   # bar 4
    "C5","C5","A4","A4","A4","A4",None,None,
    "E5","E5","B4","C5","D5","D5","C5","B4",   # bars 5-8: the theme
    "A4","A4","A4","C5","E5","E5","D5","C5",   # again, rounding off
    "B4","B4","B4","C5","D5","D5","E5","E5",   # with a firmer cadence
    "C5","C5","A4","A4","A4","A4",None,None,
    "D5","D5","D5","F5","A5","A5","G5","F5",
    "E5","E5","E5","C5","E5","E5","D5","C5",
    "B4","B4","C5","C5","D5","D5","E5","E5",
    "C5","C5","A4","A4","A4","A4","A4","A4"]
BURST_T = 13000

mus = bytearray()
for step in PATTERN:
    if step is None:
        mus += bytes((0, 0, 0, 0))
        continue
    half_t = 3_500_000 / (2 * NOTE_HZ[step])
    w = max(1, round((half_t - 35) / 26))
    h = max(2, int(BURST_T // (26 * w + 35)))  # bass floor: 1 full cycle
    mus += bytes((w & 255, w >> 8, min(255, h), 0))
assert len(mus) == 512
write("mustab.bin", mus)

# ------------------------------------------------------------- stick man
# 8-pose walk cycle on a 16x40 chunky-pixel grid (= 128x160 real pixels).
# Per pose, per attr row (2 chunky rows): [top cols8-15, top cols0-7,
# bot cols8-15, bot cols0-7] - the order the renderer's 16-bit shift
# register wants.  8 poses x 20 rows x 4 = 640 bytes.
SW, SH = 16, 40

def stick_pose(ph):
    g = [[0] * SW for _ in range(SH)]

    def px(x, y):
        xi, yi = int(round(x)), int(round(y))
        if 0 <= xi < SW and 0 <= yi < SH:
            g[yi][xi] = 1

    def line(x0, y0, x1, y1):
        n = max(1, int(max(abs(x1 - x0), abs(y1 - y0))) * 3)
        for i in range(n + 1):
            t = i / n
            px(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)

    def limb(x0, y0, l1, a1, l2, a2):
        # two segments; angles from straight down, +x = walking direction
        mx, my = x0 + l1 * math.sin(a1), y0 + l1 * math.cos(a1)
        line(x0, y0, mx, my)
        line(mx, my, mx + l2 * math.sin(a2), my + l2 * math.cos(a2))

    for yy in range(9):                    # head, filled
        for xx in range(4, 13):
            if (xx - 8) ** 2 + (yy - 4) ** 2 <= 6.5:
                g[yy][xx] = 1
    line(8, 8, 8, 21)                      # torso
    for pp in (ph, ph + math.pi):
        u = 0.45 * math.sin(pp + math.pi)  # arms swing opposite the legs,
        limb(8, 11, 4, u, 4, u + 0.8)      # elbows bent forward
        t = 0.35 * math.sin(pp)            # legs: knee flexes on the swing
        k = 0.9 * max(0.0, math.sin(pp + 2.3))
        limb(8, 21, 9, t, 9, t - k)
    return g

def bits(row, lo, hi):
    return sum(row[c] << (7 - i) for i, c in enumerate(range(lo, hi)))

stick = bytearray()
for pose in range(8):
    g = stick_pose(2 * math.pi * pose / 8)
    for r in range(20):
        for y in (2 * r, 2 * r + 1):
            stick.append(bits(g[y], 8, 16))
            stick.append(bits(g[y], 0, 8))
assert len(stick) == 640
write("stickman.bin", stick)

# ------------------------------------------------------- parallax ground
# Two 64-byte cyclic 512px dash strips (each doubled so a 32-byte window
# never wraps): long speed-lines for the fast band, sparse dots for the
# slow band.  Spans are (start_px, len_px).
def strip64(spans):
    bits = [0] * 512
    for st, ln in spans:
        for i in range(ln):
            bits[(st + i) % 512] = 1
    return bytes(sum(bits[8 * i + b] << (7 - b) for b in range(8))
                 for i in range(64))

fast = strip64([(0, 14), (48, 10), (110, 16), (168, 8), (230, 14),
                (296, 11), (352, 17), (420, 9), (470, 13)])
slow = strip64([(20, 3), (95, 2), (150, 4), (238, 2), (330, 3), (430, 2)])
write("gpat.bin", fast * 2 + slow * 2)

# ------------------------------------------------------------- star field
# 48 stars, three parallax layers of 16: [xfrac, xint, y, attr].  Near
# stars bright and fast, far stars dim and slow; colours mixed per layer.
rng = random.Random(1987)
LAYER_COLOURS = [
    [0x47, 0x47, 0x46, 0x45],   # near: bright white / yellow / cyan
    [0x45, 0x44, 0x43, 0x46],   # mid: bright cyan / green / magenta
    [0x07, 0x05, 0x04, 0x02],   # far: dim white / cyan / green / red
]
stars = bytearray()
for layer in LAYER_COLOURS:
    for _ in range(16):
        stars += bytes((rng.randrange(256), rng.randrange(256),
                        8 + rng.randrange(152), rng.choice(layer)))
assert len(stars) == 192
write("stars.bin", stars)

# ------------------------------------------------- mini background walker
# The stick man's distant companion: his poses 2x2 OR-downsampled to an
# 8x20 chunky grid.  Per attr row: [top byte, bottom byte] x 10 x 8 poses.
mini = bytearray()
for pose in range(8):
    g = stick_pose(2 * math.pi * pose / 8)
    m = [[1 if any(g[2*y+dy][2*x+dx] for dy in (0,1) for dx in (0,1)) else 0
          for x in range(8)] for y in range(20)]
    for r in range(10):
        for y in (2 * r, 2 * r + 1):
            mini.append(sum(m[y][b] << (7 - b) for b in range(8)))
assert len(mini) == 160
write("ministick.bin", mini)

# ------------------------------------------------------- kung-fu fighters
# Six frames of Oolong ripped from the ZX Spectrum Yie Ar Kung-Fu sheet
# (spriters-resource, assets/oolong-sheet.png; game (c) Konami - personal use).
# Normalized to 40x40, bottom-anchored, 5 bytes x 40 lines = 200 bytes a
# frame; a mirrored set follows for the opponent.
try:
    from PIL import Image
    BOXES = [(0, 3, 32, 37), (100, 2, 32, 38), (225, 3, 40, 37),
             (62, 44, 40, 31), (184, 41, 40, 34), (138, 76, 36, 36)]
    im = Image.open("assets/oolong-sheet.png").convert("RGB")
    ipx = im.load()
    def frame_bits(x0, y0, bw, bh, mirror):
        rows = []
        for y in range(40):
            sy = y - (40 - bh)
            bits = [0] * 40
            for x in range(bw):
                if 0 <= sy < bh and ipx[x0 + x, y0 + sy] == (0, 0, 0):
                    bits[x] = 1
            if mirror:
                bits = bits[::-1]
            rows.append(bytes(sum(bits[8 * i + b] << (7 - b) for b in range(8))
                              for i in range(5)))
        return b"".join(rows)
    yie = bytearray()
    for mirror in (False, True):
        for box in BOXES:
            yie += frame_bits(*box, mirror)
    assert len(yie) == 2400
    write("yiear.bin", yie)
except ImportError:
    print("  (pillow missing: keeping existing yiear.bin)")

# ------------------------------------------------------- the vector cube
# 128 baked rotation frames of a wireframe cube: tumble about two axes,
# perspective-projected in here so the Z80 never multiplies.  Per frame:
# 8 vertices x [sx, sy] = 16 bytes.  Plus a radial rainbow attr backdrop
# the spinning wireframe picks its colours from.
CUBE_HALF, CUBE_DIST, CUBE_SCALE = 15, 140, 135
cube = bytearray()
for k in range(128):
    a = 2 * math.pi * k / 128
    b = 2 * math.pi * k / 64 + 0.5
    ca, sa, cb, sb = math.cos(a), math.sin(a), math.cos(b), math.sin(b)
    for v in range(8):
        x = CUBE_HALF * (1 if v & 1 else -1)
        y = CUBE_HALF * (1 if v & 2 else -1)
        z = CUBE_HALF * (1 if v & 4 else -1)
        x, z = x * ca + z * sa, -x * sa + z * ca
        y, z = y * cb - z * sb, y * sb + z * cb
        px = round(128 + x * CUBE_SCALE / (z + CUBE_DIST))
        py = round(96 + y * CUBE_SCALE / (z + CUBE_DIST))
        # must stay inside the 64x64 off-screen raster buffer
        assert 96 <= px <= 159 and 64 <= py <= 127, (px, py)
        cube += bytes((px, py))
assert len(cube) == 2048
write("cube.bin", cube)

# Companion cubes: the same geometry rasterized small at build time -
# 64 frames of 16x16 wireframe sprites (2 bytes x 16 rows), so a spinning
# background cube costs a 32-byte blit instead of twelve Bresenham lines.
CEDGE = [(0,1),(2,3),(4,5),(6,7),(0,2),(1,3),(4,6),(5,7),(0,4),(1,5),(2,6),(3,7)]
mini = bytearray()
for k in range(32):
    a = 2 * math.pi * k / 32
    b = 2 * math.pi * k / 16 + 0.5
    ca, sa, cb, sb = math.cos(a), math.sin(a), math.cos(b), math.sin(b)
    pts = []
    for v in range(8):
        x = 6.0 * (1 if v & 1 else -1)
        y = 6.0 * (1 if v & 2 else -1)
        z = 6.0 * (1 if v & 4 else -1)
        x, z = x * ca + z * sa, -x * sa + z * ca
        y, z = y * cb - z * sb, y * sb + z * cb
        pts.append((7.5 + x * 92 / (z + 140), 7.5 + y * 92 / (z + 140)))
    g = [[0] * 16 for _ in range(16)]
    for i, j in CEDGE:
        x0, y0 = pts[i]
        x1, y1 = pts[j]
        n = max(1, int(max(abs(x1 - x0), abs(y1 - y0))) * 3)
        for t in range(n + 1):
            xx = int(round(x0 + (x1 - x0) * t / n))
            yy = int(round(y0 + (y1 - y0) * t / n))
            if 0 <= xx < 16 and 0 <= yy < 16:
                g[yy][xx] = 1
    for row in g:
        mini.append(sum(row[i] << (7 - i) for i in range(8)))
        mini.append(sum(row[8 + i] << (7 - i) for i in range(8)))
assert len(mini) == 1024
write("minicube.bin", mini)

cattr = bytearray()
RINGS = [0x47, 0x46, 0x44, 0x45, 0x43]
for row in range(21):
    for col in range(32):
        d = math.hypot((col - 15.5) * 8, (row - 11.5) * 8)
        cattr.append(RINGS[int(d / 13) % len(RINGS)])
assert len(cattr) == 672
write("cubeattr.bin", cattr)

# ------------------------------------------------------------ 3D graphs
# The classic home-computer hidden-line surface plot, baked: sample z =
# f(x,y) over a sheared grid, keep a per-column horizon, emit only the
# visible points.  Row encoding: [count, sx0, then count bytes of py or
# $FF for hidden]; x advances 3px per point; count 0 ends the graph.
def bake_graph(f, xstep=3):
    out = bytearray()
    horizon = [255] * 256
    npts = len(range(0, 141, xstep))
    for yi in range(0, 145, 5):
        sx0 = 12 + int(yi * 0.45)
        row = bytearray((npts, sx0))
        sx = sx0
        for xi in range(0, 141, xstep):
            z = max(-25.0, min(78.0, f(xi, yi)))
            py = int(148 - (z * 0.7 + yi * 0.5))
            assert 16 <= py <= 167 and 0 <= sx <= 255, (sx, py)
            if py < horizon[sx]:
                horizon[sx] = py
                row.append(py)
            else:
                row.append(255)
            sx += xstep
        out += row
    out.append(0)
    return out

def ripple(x, y):
    r = math.hypot(x - 70, y - 70)
    return 78 * math.exp(-r * r / 1400) * math.cos(r / 7.2)

def eggbox(x, y):
    return 24 * math.sin(x / 9) * math.cos(y / 9)

def saddle(x, y):
    return ((x - 70) ** 2 - (y - 70) ** 2) / 190

write("g3d0.bin", bake_graph(ripple))
write("g3d1.bin", bake_graph(eggbox, 4))
write("g3d2.bin", bake_graph(saddle, 4))

# ------------------------------------------------------- dot-flow tunnels
# The chunky tunnels' replacement: hi-res dots streaming outward along
# baked trajectories.  Per geometry: 12 angles x 32 depth steps x [x, y],
# perspective baked as an accelerating radius.  Dots are single pixels;
# the rainbow ring attrs colour them by radius.
def dot_geo(shape):
    out = bytearray()
    for ai in range(12):
        a = 2 * math.pi * ai / 12
        sc = shape(a)
        for d in range(32):
            t = d / 31.0
            r = (5 + 108 * t * t) * sc
            x = round(128 + r * math.cos(a))
            y = round(92 + r * 0.72 * math.sin(a))
            assert 4 <= x <= 251 and 4 <= y <= 183, (x, y)
            out += bytes((x, y))
    return out

dots = bytearray()
dots += dot_geo(lambda a: 1.0)                                   # tube
dots += dot_geo(lambda a: 0.72 / max(abs(math.cos(a)), abs(math.sin(a))))
dots += dot_geo(lambda a: 0.82 * (1.0 + 0.30 * math.cos(4 * a)))  # star
assert len(dots) == 2304
write("dots.bin", dots)

# --------------------------------------------- giant-letter wave columns
# One routine per vertical offset 0..13: paints a single attr COLUMN of
# the big-type scene (21 rows, stride 32, page steps baked at rows 7/15):
# backdrop above, the 8 letter rows from BBUF, backdrop below.  Letters
# sample the wave by their position in the text, so each character bobs
# whole - no tearing at screen-quarter boundaries.
# Entry: HL = ATTRS+col, IX = BBUF+col+100 (bias keeps displacements
# signed), E = backdrop colour.
bw = []
for K in range(14):
    src = [f"BW{K}:"]
    for r in range(21):
        if K <= r < K + 8:
            src.append(f"        ld a,(ix{(r-K)*32-100:+d})")
            src.append("        ld (hl),a")
        else:
            src.append("        ld (hl),e")
        if r in (7, 15):
            src.append("        inc h")
        if r < 20:
            src += ["        ld a,l", "        add a,32", "        ld l,a"]
    src.append("        ret")
    bw.append("\n".join(src))
out_bw = "\n".join(bw) + "\nBWJ:\n        dw " +     ", ".join(f"BW{K}" for K in range(14)) + "\n"
with open(os.path.join(out, "bigwave.asm"), "w") as f:
    f.write(out_bw)
print("  bigwave.asm: 14 variants")

print("tables OK")
