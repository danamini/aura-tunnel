#!/usr/bin/env python3
"""Original 32x24 outlined display lettering, rasterised at native resolution.

No ROM or installed font dependency. Stroke coordinates are in the final pixel
space, so diagonals and chamfered corners retain one-pixel detail.
"""
from pathlib import Path
import math
import sys

TEXT48 = "AURA TUNNEL 48K 50FPS ONE BEAM "
TEXT128 = "AURA TUNNEL 128K 50FPS ONE BEAM "
# Each polyline is a pen stroke; a blank separates independent strokes.
STROKES = {
    'A': [[(5,21),(5,8),(11,2),(20,2),(26,8),(26,21)],[(5,13),(26,13)]],
    'B': [[(6,21),(6,2),(21,2),(26,6),(26,8),(22,11),(6,11)],[(22,11),(26,15),(26,18),(22,21),(6,21)]],
    'E': [[(26,2),(6,2),(6,21),(26,21)],[(6,11),(23,11)]],
    'F': [[(6,21),(6,2),(26,2)],[(6,11),(23,11)]],
    'K': [[(6,2),(6,21)],[(26,2),(7,13)],[(16,8),(26,21)]],
    'L': [[(6,2),(6,21),(26,21)]],
    'M': [[(5,21),(5,2),(15,12),(26,2),(26,21)]],
    'N': [[(6,21),(6,2),(26,21),(26,2)]],
    'O': [[(11,2),(21,2),(26,7),(26,16),(21,21),(11,21),(6,16),(6,7),(11,2)]],
    'P': [[(6,21),(6,2),(21,2),(26,7),(26,10),(21,14),(6,14)]],
    'R': [[(6,21),(6,2),(21,2),(26,7),(26,10),(21,13),(6,13)],[(17,13),(26,21)]],
    'S': [[(26,4),(22,2),(10,2),(6,6),(6,9),(10,11),(22,12),(26,15),(26,18),(22,21),(10,21),(6,19)]],
    'T': [[(5,2),(27,2)],[(16,2),(16,21)]],
    'U': [[(6,2),(6,16),(11,21),(21,21),(26,16),(26,2)]],
    '0': [[(11,2),(21,2),(26,7),(26,16),(21,21),(11,21),(6,16),(6,7),(11,2)],[(10,17),(22,6)]],
    '1': [[(10,7),(16,2),(16,21)],[(9,21),(24,21)]],
    '2': [[(6,6),(10,2),(22,2),(26,6),(26,9),(6,21),(26,21)]],
    '4': [[(21,21),(21,2),(6,15),(27,15)]],
    '5': [[(26,2),(7,2),(6,11),(22,11),(26,15),(26,18),(22,21),(10,21),(6,18)]],
    '8': [[(10,2),(22,2),(26,6),(26,8),(22,11),(10,11),(6,8),(6,6),(10,2)],[(10,11),(6,15),(6,18),(10,21),(22,21),(26,18),(26,15),(22,11)]],
    ' ': [],
}


def glyph(char):
    pixels = [[0] * 32 for _ in range(24)]
    for path in STROKES[char]:
        for (x0, y0), (x1, y1) in zip(path, path[1:]):
            dx, dy = x1-x0, y1-y0
            for y in range(24):
                for x in range(32):
                    t = max(0, min(1, ((x-x0)*dx+(y-y0)*dy)/(dx*dx+dy*dy)))
                    if math.hypot(x-x0-t*dx, y-y0-t*dy) <= 1.15:
                        pixels[y][x] = 1
    return bytes(sum(pixels[y][x+b] << (7-b) for b in range(8))
                 for y in range(24) for x in range(0, 32, 8))


def generate(out):
    out.mkdir(parents=True, exist_ok=True)
    chars = sorted(set(TEXT48 + TEXT128))
    assert len(chars) == 21
    encoded = {char: glyph(char) for char in chars}
    for block in range(3):
        (out / f'font{block}.bin').write_bytes(b''.join(encoded[c] for c in chars[block*7:block*7+7]))
    entries = []
    for code in range(32, 91):
        i = chars.index(chr(code)) if chr(code) in chars else chars.index(' ')
        entries.append(f'FONT{i//7}+{i%7}*96')
    (out / 'font-index.asm').write_text(
        'BSFONTINDEX:\n        dw ' + ','.join(entries) + '\n'
        'BSTEXT:\n        IFDEF TARGET128\n        db "' + TEXT128 + '",0\n'
        '        ELSE\n        db "' + TEXT48 + '",0\n        ENDIF\n')
    print('  display font: 21 original glyphs, 32x24 pixels')


if __name__ == '__main__':
    generate(Path(sys.argv[1] if len(sys.argv)>1 else 'build'))
