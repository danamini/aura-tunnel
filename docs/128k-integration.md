# The 128K edition

`make` builds two editions from one source tree. The 48K build is unchanged and
runs on anything. The 128K build adds what the extra hardware pays for: three
channels of AY music, and a VU console in the lower third.

```
make                               # both editions
make emu128                        # ZEsarUX --machine 128k, ZRCP port 10778
python3 tools/smoke_test.py --128  # artifacts, playlist, fps floors, AY checks
make cleanbuild                    # rm -rf build, then rebuild both from empty
```

| | `aura-tunnel` | `aura-tunnel-128` |
|---|---|---|
| Machine | 48K, runs on anything | 128K / +2 / +2A / +3 |
| Snapshot | 49,179 bytes | 131,103 bytes |
| Sound | silent | three-channel AY-3-8912 |
| Lower third | scroller | scroller + level meters |
| Frame | 69,888 T | 70,908 T |

The switch is `-DTARGET128`. The Makefile picks the 128K target up on its own
via `HAVE128 := $(shell grep -l TARGET128 src/main.asm)`, so it builds whenever
the source carries the hooks.

Two files hold everything the 128K edition adds:

- **`src/ay128.asm`** — the AY player and the console, about 290 bytes. It has
  no `ORG` of its own, deliberately: the include site picks the address, so it
  never argues with the 48K memory map.
- **`tools/gen_ay128.py`** — bakes `build/aymus.bin`, the score.

Everything else is five `IFDEF TARGET128` hooks in `src/main.asm`, all inert
when the symbol is undefined. The 48K binary comes out byte-identical with them
in place; that was checked by md5 before and after they landed.

## Memory and paging

sjasmplus already puts a 128K snapshot in the state the demo wants — `$4000` is
bank 5, `$8000` is bank 2, `$C000` is bank 0, paging port `$10`. So the whole
48K memory map ports across with nothing relocated. The only addition is a
16K page of music.

```
$4000-$5AFF  bank 5   screen                     (contended)
$5B00-$7FFF  bank 5   cold one-shot code and data
$8000-$BFFF  bank 2   hot code, stack, per-frame tables   <- ay128.asm lands here
$C000-$FFFF  bank 0   resident tables            (page 1 swaps in for music)
```

`src/ay128.asm` must land somewhere in `$8000-$BFFF`. That is page 2, which is
uncontended on every 128K model, and — more importantly — it stays mapped while
the player swaps page 1 into `$C000`.

### The rule that will bite

`AYFRAME` swaps page `MUSBANK` into `$C000` and swaps it back before it
returns. **The stack lives at `$FA00`, inside that window.** Nothing between
those two `OUT`s may push, pop, call or return. `src/ay128.asm` is written that
way and needs to stay that way.

Interrupts are already off — `MAIN` runs `di` between halts — so the IM2 table
going out with the page is harmless.

If the 128K stack is ever moved below `$C000`, this constraint disappears and
the player can be restructured freely.

## The music

`tools/gen_ay128.py` resolves the entire tune in Python — pitch, harmony, and a
separate volume envelope for each of the three voices — and emits a flat
per-frame register stream. The player is a copy loop: no sequencer, no pitch
maths, no envelope generator. Same house rule as the rest of the demo.

```
frame:  [volA][volB][volC][n]  then n x [reg, val]   (regs 0-7 only)
end:    volA = $FF  ->  rewind to the start
```

4,367 bytes for a 20.5-second loop, 4.3 bytes a frame, living in page 1 at
`$C000`. Frame 0 rewrites every register, so the loop point joins cleanly from
whatever state the last frame left behind.

The three volumes sit at a fixed offset instead of being delta-coded, for two
reasons: they change on nearly every frame anyway, since each voice carries its
own baked decay; and the console wants them, so reading them off the score is
cheaper than interrogating the chip.

The arrangement is Korobeiniki — melody on A, a bass line following the implied
harmony on B, noise percussion on C. The AY has one envelope generator shared
by all three channels, which is no use when every voice wants its own decay, so
the decays are baked as plain volume-per-frame curves and cost the Z80 nothing.

`gen_ay128.py` is separate from `gen_tables.py` on purpose. The 48K build's
beeper score was one monophonic line squeezed out of each frame's slack; this
is three voices with their own bass and percussion. They want to diverge.

**M** toggles the music. Muting parks the chip and collapses the bars but
leaves the score pointer alone, so the tune resumes mid-phrase.

## The console

Three VU bars in the scroller window, one attribute row per channel, spreading
from the centre. Unlit cells keep white ink on black paper so the scroller
reads straight across the gap; lit cells swap in the channel's paper colour.

It sits in rows 21-23 for a timing reason. The interrupt fires at the top of
the frame, and the beam does not reach the lower third until roughly 43,500
T-states later, against 14,400 for the top row. Down there a full attribute
repaint cannot be caught mid-write — which is why `MAIN` calls it last of all
and it never tears.

Note what that is and is not. Memory contention is identical across all three
screen thirds; the lower third is not faster. What it has is lead time.

### It repaints only what changed

The first version blanked all 96 cells and redrew. That cost up to 4.8k
T-states and measured a clean 4 fps off the sine scroller, the tightest scene
in the demo. A level normally moves one or two steps a frame, so the edges
alone are two to four cells — the same erase-from-what-you-know trick the dot
renderer uses. That took the typical frame under 300T and gave the 4 fps back.

The catch with incremental drawing is that other code repaints rows 21-23 from
under it. So each row remembers the level it last painted and checks one canary
cell — the centre — before trusting that memory. Anything unexpected there
forces a full repaint of that row, and the window heals within a single frame.

### Transitions: it behaves differently for each

This asymmetry is deliberate.

**Through a dissolve, the console keeps painting.** `WIPER` writes cells in
place, and `AYFRAME` runs after the renderer, so the console simply paints over
the dissolve's marks in rows 21-23. The effect is that the bottom three rows
don't dissolve — the status strip stands while everything above it changes. It
reads as intentional and it costs nothing measurable.

**Through a slide, the console stands down.** `SLIDER` shifts rows 0-23 upward
instead of writing in place. That drags the bars up with the rest of the
screen, the console paints fresh ones underneath, and the two together smear a
growing block of solid colour a third of the screen tall. Every slide looked
like that until it was caught. `AYCON` now returns immediately while
`WIPEF < 24 && TRMODE != 0`, and the bars slide away with everything else; the
canary repaints them when the new scene lands.

This is why `src/ay128.asm` depends on four symbols from `main.asm` rather than
two: `SCROLATT`, `MUSON`, and the transition state `WIPEF` / `TRMODE`.

## The five hooks

Kept here for anyone re-deriving the arrangement. All are in `src/main.asm`,
all inside `IFDEF TARGET128`.

1. **Device and constants** — `DEVICE ZXSPECTRUM128` in place of
   `ZXSPECTRUM48`, plus `PORT7FFD` (`$7FFD`), `PAGEBASE` (`$10`, ROM 1 with
   bank 0 at `$C000`) and `MUSBANK` (`1`).
2. **Boot paging** — in `START`, between `di` and `ld sp,STACK`, write
   `PAGEBASE` to the pager. Before anything pushes, because the stack is inside
   the paged window.
3. **Boot init** — `call AYINIT` after `call BRIEFSET`.
4. **The frame** — `call AYFRAME` in `MAIN`, in the slot the parked beeper used
   to occupy. It must stay last, after the renderer, for the timing reason
   above.
5. **Module and data** — `INCLUDE "src/ay128.asm"` inside the `$8000-$BFFF`
   window, and a save block that puts `build/aymus.bin` into page 1 at `$C000`
   and writes the `-128` output filenames.

## What was measured

All on the real 128K binary under ZEsarUX, not a harness.

**The music is effectively free.** Bisected by patching entry bytes to `RET` in
RAM, on the tightest scene:

| scene 5 (sine scroll) | fps |
|---|---|
| music + console | 44.8 |
| console off, music on | 48.7 |
| both off | 48.8 |

About 0.1 fps for the player. It is a copy loop and behaves like one. The 4 fps
gap was the console's first version, and the incremental rewrite closed it.

**Every scene holds**, with music and console live:

```
dot tunnel 50.0 · solid cubes 50.1 · star snake 50.0 · sine scroll 49.6
dot runner 50.0 · night train 50.1 · 3d graphs 50.1 · roto grid 50.1
```

Also verified: the Z80's decoded channel levels match the Python encoder
exactly; the score pointer stays inside the paged bank; paging is back to bank
0 by the time `AYFRAME` returns; the bars match their claimed levels; and M
mutes, freezes and resumes the score.

## Three traps, each of which cost real time

**Measure best-of-four or don't bother.** macOS App Nap throttles a
backgrounded emulator. The same binary measured 42.8 / 49.9 / 46.7 / 50.0 fps
across four runs of one scene. The noise is one-sided — it only ever looks
slower — so the maximum is the honest figure and more samples strictly help. A
1-2 fps difference from a single sample means nothing. Related: fps quantises
to 50/N, so a scene near a boundary misreports the size of a saving.

**A rebuild invalidates every address.** Symbol addresses come from the `.lst`,
which every build rewrites. Rebuild while a test is running and it reads
plausible rubbish from dead addresses, then blames the demo.
`check_listing_matches_memory()` catches this straight after smartload.

**A size assert on a dead artifact is worse than no assert.** `make` never
cleans `build/`, so when a bake is dropped its output file lingers and the
assert keeps passing — vacuously, while reading as coverage. `static_checks()`
now cross-checks every `.bin` against the `INCBIN` lines in `src/main.asm`.
`make cleanbuild` is the stronger version: a clean-room build catches a
generator deleted while something still depended on it, which an incremental
build never will. It is deliberately not part of `make test`, because it would
pull `build/` out from under a running emulator.

Two more, about the emulator itself. Reads of a running demo are **not atomic** —
comparing the console's levels against the attributes on screen needs
`enter-cpu-step` around both reads, or they come from different frames and
every sample looks broken when nothing is. And ZEsarUX **wedges**: after a long
ZRCP session, or after a few `enter-cpu-step` calls, the CPU stops and `run`,
`exit-cpu-step` and `cpu-step` all stop responding. Since `zrcp_scr.py` uses
`enter-cpu-step` for every screenshot, don't screenshot in a loop. Restarting
is faster than fighting it.

If ZRCP breakpoints ever look broken: `enable-breakpoints` must come **before**
`set-breakpoint`, or the latter returns an error with no hex payload that most
wrappers swallow silently.
