#!/usr/bin/env python3
"""AY score baker for AURA TUNNEL 128K.

Separate from gen_tables.py on purpose.  The 48K build's beeper score is a
single monophonic line squeezed out of each frame's slack; this is a
three-voice arrangement with its own bass and percussion, and the two want
to diverge rather than share a table.  The melody is the same 19th-century
folk tune (Korobeiniki, public domain).

Same house rule as everything else here: pay at build time.  Pitch,
harmony and all three volume envelopes are resolved in Python, and what
reaches the Z80 is a flat per-frame register stream.  The player is a copy
loop - no sequencer, no pitch maths, no envelope generator.

Output (build/):

  aymus.bin   per-frame AY register stream.  Each frame is

                  [volA][volB][volC][n]  then n x [reg, val]   (regs 0-7)

              volA = 0xFF marks the loop point.  The three channel volumes
              sit at a fixed offset rather than being delta-coded: they
              change on nearly every frame anyway (each voice carries its
              own baked decay), the player writes them unconditionally,
              and the lower-third console reads them back as its levels
              without having to interrogate the chip.
"""
import os
import sys

out = sys.argv[1] if len(sys.argv) > 1 else "build"
os.makedirs(out, exist_ok=True)

AY_CLOCK = 1_773_400            # the 128K's AY-3-8912 clock
STEP_FRAMES = 10                 # one eighth note per 10 frames = 150 BPM
SEMI = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}

# Korobeiniki, eight bars.  Melody voice, one entry per eighth note.
MELODY = [
    "E5", "E5", "B4", "C5", "D5", "D5", "C5", "B4",
    "A4", "A4", "A4", "C5", "E5", "E5", "D5", "C5",
    "B4", "B4", "B4", "C5", "D5", "D5", "E5", "E5",
    "C5", "C5", "A4", "A4", "A4", "A4", None, None,
    "D5", "D5", "D5", "F5", "A5", "A5", "G5", "F5",
    "E5", "E5", "E5", "C5", "E5", "E5", "D5", "C5",
    "B4", "B4", "B4", "C5", "D5", "D5", "E5", "E5",
    "C5", "C5", "A4", "A4", "A4", "A4", None, None,
    "E5", "E5", "B4", "C5", "D5", "D5", "C5", "B4",
    "A4", "A4", "A4", "C5", "E5", "E5", "D5", "C5",
    "B4", "B4", "B4", "C5", "D5", "D5", "E5", "E5",
    "C5", "C5", "A4", "A4", "A4", "A4", None, None,
    "D5", "D5", "D5", "F5", "A5", "A5", "G5", "F5",
    "E5", "E5", "E5", "C5", "E5", "E5", "D5", "C5",
    "B4", "B4", "C5", "C5", "D5", "D5", "E5", "E5",
    "C5", "C5", "A4", "A4", "A4", "A4", "A4", "A4"]

# Four contrasting sections. The original arrangement of Korobeiniki is
# followed by two original chip themes and a public-domain Beethoven melody.
# Ode reference: https://www.mutopiaproject.org/ftp/BeethovenLv/ode/ode-let.pdf
KOROBEINIKI = MELODY[:64]
DRIVE = """
A4 E5 A5 E5 G5 E5 C5 E5  F4 C5 F5 A5 G5 F5 E5 C5
C5 G5 C6 G5 B5 G5 E5 G5  G4 D5 G5 B5 A5 G5 E5 D5
A4 C5 E5 A5 G5 E5 D5 C5  F4 A4 C5 F5 E5 C5 A4 C5
E4 B4 E5 G5 F5 E5 D5 B4  A4 E5 C5 E5 A5 G5 E5 A4
""".split()
ODE = """
E5 E5 F5 G5 G5 F5 E5 D5  C5 C5 D5 E5 E5 D5 D5 -
E5 E5 F5 G5 G5 F5 E5 D5  C5 C5 D5 E5 D5 C5 C5 -
D5 D5 E5 C5 D5 E5 F5 E5  C5 D5 E5 F5 E5 D5 C5 D5
G4 E5 E5 F5 G5 G5 F5 E5  D5 C5 C5 D5 E5 D5 C5 C5
""".split()
NIGHT = """
E5 - B4 D5 E5 G5 - B5  A5 G5 E5 - D5 B4 A4 B4
C5 - G4 B4 C5 E5 - G5  F5 E5 C5 - B4 G4 E4 G4
A4 - E5 G5 A5 C6 B5 A5  G5 E5 D5 E5 G5 B5 A5 G5
B4 D5 F#5 A5 G5 F#5 E5 D5  E5 B4 G4 B4 E5 - - -
""".split()
SECTIONS = [("Korobeiniki", KOROBEINIKI), ("Neon Drive", DRIVE),
            ("Ode to Joy", ODE), ("Night Flight", NIGHT)]
assert all(len(notes) == 64 for _, notes in SECTIONS)
MELODY = [None if n == "-" else n for _, notes in SECTIONS for n in notes]
BASS = (["E2", "A2", "E2", "A2", "D3", "C3", "E2", "A2"]
        + ["A2", "F2", "C3", "G2", "A2", "F2", "E2", "A2"]
        + ["C3", "G2", "C3", "C3", "G2", "G2", "C3", "C3"]
        + ["E2", "E2", "C3", "C3", "A2", "A2", "B2", "E2"])

# One bass root per half-bar (8 steps), struck on every other step, so
# quarter notes walk under the melody's eighths.  The roots follow the
# melody's implied harmony: Em Am | Em Am | Dm C | Em Am, twice over.


# The AY has ONE envelope generator shared across all three channels,
# which is no use when every voice wants its own decay - so the decays are
# baked here as plain volume-per-frame curves and cost the Z80 nothing.
ENV_LEAD = [14, 14, 13, 13, 12, 12, 11, 11]
ENV_BASS = [15, 14, 13, 12, 10, 9, 8, 7, 6, 5, 4, 4, 3, 3, 2, 2]
ENV_HAT = [10, 6, 3, 1]
ENV_SNARE = [14, 11, 7, 4, 2, 1]

# Mixer, active low: tone on A and B, tone off C, noise on C alone.
MIXER = 0b00011100


def note_hz(name):
    idx = SEMI[name[0]] + (1 if "#" in name else 0)
    return 440.0 * 2 ** (((int(name[-1]) + 1) * 12 + idx - 69) / 12.0)


def ay_period(name):
    return max(1, min(4095, round(AY_CLOCK / (16.0 * note_hz(name)))))


FRAMES = len(MELODY) * STEP_FRAMES
reg = [[None] * 8 for _ in range(FRAMES)]
vol = [[0, 0, 0] for _ in range(FRAMES)]
reg[0][4] = reg[0][5] = 0       # unused ch-C tone: pinned so that frame 0
reg[0][7] = MIXER               # is a full reset and the loop joins clean


def envelope(frame, chan, curve):
    for i, v in enumerate(curve):
        if frame + i < FRAMES:
            vol[frame + i][chan] = v


for step, note in enumerate(MELODY):
    f0 = step * STEP_FRAMES
    if note is not None:                        # channel A: the melody
        p = ay_period(note)
        reg[f0][0], reg[f0][1] = p & 255, p >> 8
        envelope(f0, 0, ENV_LEAD)
    if step % 2 == 0:                           # channel B: the bass
        root = BASS[step // 8]
        # Alternate root and octave in the drive section; quieter roots at night.
        if 64 <= step < 128 and step % 4 == 2:
            root = root[:-1] + str(int(root[-1]) + 1)
        p = ay_period(root)
        reg[f0][2], reg[f0][3] = p & 255, p >> 8
        envelope(f0, 1, ENV_BASS)
    snare = (step % 16) in ((6, 14) if step >= 192 else (4, 12))              # channel C: percussion
    reg[f0][6] = 12 if snare else 3
    if step < 192 or step % 2 == 0:
        envelope(f0, 2, ENV_SNARE if snare else ENV_HAT)

stream = bytearray()
last = [None] * 8
for f in range(FRAMES):
    pairs = [(r, reg[f][r]) for r in range(8)
             if reg[f][r] is not None and reg[f][r] != last[r]]
    for r, v in pairs:
        last[r] = v
    stream += bytes(vol[f] + [len(pairs)])
    for r, v in pairs:
        stream += bytes((r, v))
stream += b"\xFF"

with open(os.path.join(out, "aymus.bin"), "wb") as f:
    f.write(bytes(stream))
print("  aymus.bin: %d bytes (%d frames, %.1fs loop, %.1f bytes/frame)"
      % (len(stream), FRAMES, FRAMES / 50.0, (len(stream) - 1) / FRAMES))
assert len(stream) <= 16384, "the stream must fit one 16K page"

import json
with open(os.path.join(out, "music.json"), "w") as f:
    json.dump({"frames": FRAMES, "duration_seconds": FRAMES / 50,
               "sections": [{"title": title, "start_frame": i*64*STEP_FRAMES}
                            for i, (title, _) in enumerate(SECTIONS)]}, f, indent=2)
