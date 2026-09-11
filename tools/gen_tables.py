#!/usr/bin/env python3
"""Table generator for AURA TUNNEL (48K/128K ZX Spectrum demo).

Everything expensive is baked here at build time, the way real demos
precalc; the Z80 only copies, pops and looks up.  Outputs (build/):

  rainbow.bin   cyclic ink strip under the snake scroller.
  sintab.bin    sine 0..16: snake wave, scroller wave, surge speeds.
  snake.asm     generated single-pass blit code, one routine per offset.
  gpat.bin      cyclic dash strips - the runner's floor and the train's
                scenery both ride these.
  stars.bin     48 star records [xfrac, xint, y, attr], 3 speed layers.
  yiear.bin     6 Yie Ar Kung-Fu frames + mirrors, 40x40 1-bit
                (sliced from assets/oolong-sheet.png when Pillow is present).
  cubebig.bin   32 poses of a solid dither-shaded cube, 32x32.
  minicube.bin  the same, 16x16, for the corner companions.
  cubeattr.bin  rainbow ring attrs behind the cubes.
  g3d0/1/2.bin  hidden-line surface plots (ripple/eggbox/saddle) as
                visible-point rows [count, sx0, py|0xFF...].
  dots.bin      dot-flow tunnel trajectories, 3 geometries.
  roto.bin      roto grid: 64 angles x 8 zooms x [A, B, DX, DY].
  bitmask.bin   one page of $80>>(x&7), for single-pixel plots.
  dbltab.bin    x with every bit doubled: the scroller's font scaler.
  bigscr.asm    the scroller's 8 baked column-descent variants.
  runner.bin    12 full-cycle poses, 64 points each; companion has 8 x 28
                and half size, off real running gait kinematics.

The 128K edition's AY score is baked separately by tools/gen_ay128.py.
"""
import math
import os
import random
import sys

out = sys.argv[1] if len(sys.argv) > 1 else "build"
os.makedirs(out, exist_ok=True)

COLS, ATTR_ROWS = 32, 21


CFACE = [(0,1,3,2), (4,6,7,5), (0,4,5,1), (2,3,7,6), (0,2,6,4), (1,5,7,3)]
FNORM = [(0,0,-1), (0,0,1), (0,-1,0), (0,1,0), (-1,0,0), (1,0,0)]
LIGHT = (-0.42, -0.57, -0.71)           # the sun, over your left shoulder
BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


def shade_of(nx, ny, nz, ca, sa, cb, sb):
    """A rotated face normal -> 0 if it points away, else dither level 1-7."""
    x, z = nx * ca + nz * sa, -nx * sa + nz * ca
    y, z = ny * cb - z * sb, ny * sb + z * cb
    if z > -0.02:
        return 0
    d = x * LIGHT[0] + y * LIGHT[1] + z * LIGHT[2]
    return 1 + min(6, max(0, int((d + 1.0) * 3.5)))


def write(name, data):
    with open(os.path.join(out, name), "wb") as f:
        f.write(bytes(data))
    print(f"  {name}: {len(data)} bytes")


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
CUBE_HALF, CUBE_DIST, CUBE_SCALE = 15, 140, 78


# Companion cubes: the same geometry rasterized small at build time, and
# now SOLID - each visible face scan-filled through the same Bayer matrix
# the big cube's Z80 filler uses, so a background cube costs a 32-byte
# blit and still matches the shading of the one being filled live.
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
    for f, (nx, ny, nz) in enumerate(FNORM):
        lev = shade_of(nx, ny, nz, ca, sa, cb, sb)
        if not lev:
            continue                        # facing away
        quad = [pts[i] for i in CFACE[f]]
        ys = [q[1] for q in quad]
        for sy in range(max(0, int(min(ys))), min(16, int(max(ys)) + 1)):
            xs = []
            for i in range(4):              # where the scanline crosses
                x0, y0 = quad[i]            #   each edge of the face
                x1, y1 = quad[(i + 1) & 3]
                if (y0 <= sy < y1) or (y1 <= sy < y0):
                    xs.append(x0 + (x1 - x0) * (sy - y0) / (y1 - y0))
            if len(xs) < 2:
                continue
            for sx in range(max(0, int(round(min(xs)))),
                            min(16, int(round(max(xs))) + 1)):
                if BAYER[sy & 3][sx & 3] < lev * 2:
                    g[sy][sx] = 1
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
            r = (5 + 104 * t * t) * sc
            x = round(128 + r * math.cos(a))
            y = round(92 + r * 0.72 * math.sin(a))
            assert 4 <= x <= 251 and 4 <= y <= 183, (x, y)
            out += bytes((x, y))
    return out

dots = bytearray()
dots += dot_geo(lambda a: 1.0)                                   # tube
assert len(dots) == 768
write("dots.bin", dots)

# --------------------------------------------------------- roto grid
# The top-down rotating plane, one table driving both its layers: 64
# angles x 8 zoom levels x [A, B, DX, DY].  A and B (8.8 signed) are the
# attribute rotozoom's per-column texel steps; DX and DY (9.7 signed,
# so the accumulator's integer part spans 0..511 and a point that leaves
# the screen is caught by one carry) step the hi-res dot lattice.  Dot
# spacing is the grid pitch itself, so the dots land on the tiles'
# corners however the plane turns.
ROTA, ROTZ = 64, 8

def s16(v):
    v = int(round(v)) & 0xFFFF
    return bytes((v & 255, v >> 8))

roto = bytearray()
for zi in range(ROTZ):
    S = 64.0 + zi * 4.0                 # grid pitch / dot spacing, pixels
    z = 128.0 / S                       # texels per attribute cell
    for ai in range(ROTA):
        th = 2 * math.pi * ai / ROTA
        roto += s16(math.cos(th) * z * 256)     # A:  u step per column
        roto += s16(math.sin(th) * z * 256)     # B:  v step per column (negated)
        roto += s16(math.cos(th) * S * 128)     # DX: lattice step per i
        roto += s16(math.sin(th) * S * 128)     # DY
assert len(roto) == ROTA * ROTZ * 8 == 4096
write("roto.bin", roto)

# One page of pixel masks, so a plot can fetch $80>>(x&7) with a single
# ld a,(de) instead of an indexed add.
masks = bytes(0x80 >> i for i in range(8))
trails = bytes(v for i in range(8) for v in ((0xfc00 >> i) >> 8, (0xfc00 >> i) & 255))
write("bitmask.bin", masks + trails + bytes(232))

# ------------------------------------------------- hi-res sine scroller
# The big scroller, rebuilt in pixels.  Letters are the ROM font scaled
# x4 into a 32x32 bitmap (two passes of a bit-doubling table), fed one
# PIXEL a frame into a 32-row buffer, then painted column by column with
# every column at its own height off a travelling sine.  Nothing here
# touches an attribute, so nothing here can be blocky in the old way.
#
# DBLTAB[x] is x with every bit doubled - 8 pixels in, 16 out.
dbl = bytearray()
for x in range(256):
    v = 0
    for b in range(8):
        if x & (1 << b):
            v |= 3 << (2 * b)
    dbl += bytes((v & 255, v >> 8))
assert len(dbl) == 512
write("dbltab.bin", dbl[1::2] + dbl[0::2])

# One descent routine per start-scanline phase: 34 writes down a single
# screen column - a blank guard row, the 32 buffer rows, another guard -
# with every scanline step, third crossing and buffer page break baked in
# rather than tested.  Entry: HL = buffer column, DE = screen address of
# the guard row above the letter.
sd = []
ROWS = 24
for P in range(8):
    src = [f"SD{P}:", "        xor a", "        ld (de),a"]
    for r in range(ROWS + 2):
        y = P + r
        if r:                                   # not the top guard row
            src.append("        ld a,(hl)" if r <= ROWS else "        xor a")
            src.append("        ld (de),a")
        if r == ROWS + 1:
            break
        if 1 <= r <= ROWS - 1:                  # walk down the buffer column
            src += ["        ld a,l", "        add a,32", "        ld l,a"]
            if r % 8 == 0:
                src.append("        inc h")
        if y % 8 == 7:                          # off the end of a char row
            src += ["        ld a,d", "        sub 7", "        ld d,a",
                    "        ld a,e", "        add a,32", "        ld e,a",
                    f"        jr nc,.n{r}", "        ld a,d",
                    "        add a,8", "        ld d,a", f".n{r}:"]
        else:
            src.append("        inc d")
    src.append("        ret")
    sd.append("\n".join(src))
out_sd = "\n".join(sd) + "\nSDJ:\n        dw " + ", ".join(f"SD{P}" for P in range(8)) + "\n"
with open(os.path.join(out, "bigscr.asm"), "w") as f:
    f.write(out_sd)
print(f"  bigscr.asm: 8 descent variants")

# ------------------------------------------------------------ dot runner
# Captured joint trajectories, converted and projected only at build time.
from mocap_runner import run_pose

# Emit pose addresses and counts with the data; no hand-written stride maths.
hero = bytearray()
small = bytearray()
index = ["RUNPOSES:"]
for half, data, label in ((1, hero, "RUNDAT"), (2, small, "RUNSMALL")):
    for pose in range(12 if half == 1 else 8):
        pts = run_pose(pose / (12.0 if half == 1 else 8.0), dense=half == 1)
        index.append(f"        dw {label}+{len(data)}")
        index.append(f"        db {len(pts)}")
        for x, y in pts:
            xi, yi = int(round(x/half)), int(round(y/half))
            assert 0 <= xi <= 95 and 0 <= yi <= 140, (xi, yi, pose)
            data += bytes((xi, yi))
write("runner.bin", hero)
write("runner-small.bin", small)
with open(os.path.join(out, "runner-index.asm"), "w") as f:
    f.write("\n".join(index) + "\nRUNPHASE:\n        db " + ",".join(str(i*12//32) for i in range(32)) + "\n")

# --------------------------------------------------- Driller-style cubes
# Freescape drew solid faces filled with ordered dither, which is how you
# get shading out of one bit per pixel.  Baked per rotation frame: the
# six faces' shade levels, 0 where the face points away from us and 1-7
# by how squarely it faces the light.  The Z80 fills the visible ones as
# convex quads, so one 2KB vertex table drives a cube at any size.


# Eight levels of a 4x4 ordered dither, as four byte-wide rows each.  The
# byte repeats every 4 pixels so a span can be filled with whole bytes.


# ------------------------------------------------- baked Driller cubes
# The live scanline filler was correct but cost ~90k T-states a frame -
# more than the 69,888 there are.  So the cubes get baked like everything
# else here: each visible face scan-filled through the Bayer matrix at
# build time, leaving the Z80 a flat sprite blit that also self-erases.
def bake_cube(size, frames, radius):
    out = bytearray()
    wb = (size + 7) // 8
    for k in range(frames):
        a = 2 * math.pi * k / frames
        b = 2 * math.pi * k / (frames // 2) + 0.5
        ca, sa, cb, sb = math.cos(a), math.sin(a), math.cos(b), math.sin(b)
        c = (size - 1) / 2.0
        pts = []
        for v in range(8):
            x = radius * (1 if v & 1 else -1)
            y = radius * (1 if v & 2 else -1)
            z = radius * (1 if v & 4 else -1)
            x, z = x * ca + z * sa, -x * sa + z * ca
            y, z = y * cb - z * sb, y * sb + z * cb
            pts.append((c + x * 92 / (z + 140), c + y * 92 / (z + 140)))
        g = [[0] * (wb * 8) for _ in range(size)]
        for f, (nx, ny, nz) in enumerate(FNORM):
            lev = shade_of(nx, ny, nz, ca, sa, cb, sb)
            if not lev:
                continue
            quad = [pts[i] for i in CFACE[f]]
            ys = [q[1] for q in quad]
            for sy in range(max(0, int(min(ys))), min(size, int(max(ys)) + 1)):
                xs = []
                for i in range(4):
                    x0, y0 = quad[i]
                    x1, y1 = quad[(i + 1) & 3]
                    if (y0 <= sy < y1) or (y1 <= sy < y0):
                        xs.append(x0 + (x1 - x0) * (sy - y0) / (y1 - y0))
                if len(xs) < 2:
                    continue
                for sx in range(max(0, int(round(min(xs)))),
                                min(size, int(round(max(xs))) + 1)):
                    if BAYER[sy & 3][sx & 3] < lev * 2:
                        g[sy][sx] = 1
        for row in g:
            for byte in range(wb):
                out.append(sum(row[byte * 8 + i] << (7 - i) for i in range(8)))
    assert len(out) == frames * size * wb
    return out

write("cubebig.bin", bake_cube(32, 32, 14.5))

print("tables OK")

write("rowlo.bin", [((y & 0x38) << 2) for y in range(256)])
write("rowhi.bin", [0x40 | (y & 7) | ((y & 0xc0) >> 3) for y in range(256)])
