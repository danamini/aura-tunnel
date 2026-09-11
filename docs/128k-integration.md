# The 128K edition

`make all` builds the silent 48K snapshot and the 128K snapshot from the same
source. `-DTARGET128` enables AY music, level meters and a lower big-scroller
band. Both editions retain the smooth one-pixel-per-frame scroller.

See the [README](../README.md) for build, launch and test commands, and the
[delivery status](improvement-plan.md) for measured behavior and remaining UAT.

## Memory and paging

The snapshot starts with bank 5 at `$4000`, bank 2 at `$8000`, bank 0 at `$C000`
and paging value `$10`. Bank 1 stores the AY score.

```text
$4000-$5AFF  bank 5   screen
$5B00-$7FFF  bank 5   buffers, cold code and data
$8000-$BFFF  bank 2   resident code, buffers and tables, including AY player
$C000-$FFFF  bank 0   tables, stack at $FA00, IM2 table/vector
```

`AYFRAME` briefly maps bank 1 into `$C000`, reads the next music record, then
restores bank 0. The player must stay in `$8000-$BFFF`.
**No push, pop, call or return is allowed between its paging OUT instructions:**
the normal demo stack lives inside the switched window.

The IM2 handler preserves primary registers and calls the player with interrupts
disabled. Renderers must keep SP in writable RAM while interrupts are enabled;
the 128K roto painter uses alternate registers rather than borrowing SP for
arithmetic. Do not move the player, stack or paging instructions independently.

## Music

`tools/gen_ay128.py` generates a 10,997-byte register stream for a 51.2-second
loop. Pitch, harmony and per-channel volume curves are calculated at build time.
The runtime player reads this format:

```text
[volA][volB][volC][n] followed by n [register, value] pairs (registers 0–7)
volA = $FF marks the loop end
```

The first frame rewrites all relevant registers. The four sections are
Korobeiniki, original melody Neon Drive, Beethoven's Ode to Joy, and original
melody Night Flight. Channel A carries melody, B bass and C percussion.

During machine-code scenes, M mutes the chip and pauses the score pointer;
unmuting resumes from that position. Playback uses the interrupt clock rather
than the scene's render rate, so the 25 FPS roto scene does not slow the tune.

## Meter strip and scroller

`AYCON` draws three bars in attribute rows 21–23, after scene rendering.
Matching ink and paper keep bars opaque over scene pixels. It updates changed
edges, remembers the level it actually painted and checks a canary cell to
recover when another renderer has overwritten a row. Transitions reserve the
meter rows.

The large scroller uses `BANDTOP=120` on 128K (`72` on 48K), above the strip.
Both editions feed one pixel per render with the same travelling sine phase.
The lower position is a layout choice; Spectrum screen thirds do not have
different contention costs.

## Real BASIC interlude

`src/basic.asm` temporarily replaces the IM2 destination with `BASICIRQ`.
It plays one AY frame and chains to the ROM keyboard/clock handler until the
preview timer expires. Restoration reinstates the normal AY handler and the
borrowed roto data, then resumes the machine-code graph scene.

The music continues during the preview; the normal scene meter painter is not
running while the ROM owns execution. See [BASIC entry notes](../assets/basic/README.md)
for the shared program, memory relocation and benchmark.

## Verification boundaries

The runtime suite checks interrupt spacing across the playlist, opaque meter
contents, both snapshots' scene timing and timed BASIC restoration. Timing is
measured in simulated T-states with ULA contention, avoiding desktop scheduling
noise. ZEsarUX is used for visual UAT; physical 128K variants and TAP loading
remain unverified for this revision.

Live ZRCP tools use addresses from the matching assembler listing. Rebuilds can
move those addresses: load the corresponding snapshot before using the tools.
Freeze the emulator around multi-part memory reads when a consistent frame is
needed, and always resume it afterward. Live smoke tests rewrite the playlist;
reload the snapshot to return to normal UAT.
