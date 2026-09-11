# Demo delivery status

Updated 11 September 2026. This document records the current native Spectrum
build. The separate Spectrum Aura browser visualiser is outside this workstream.

## Implemented

- Restore the preferred 50 FPS big scroller: one pixel per render, original
  two-step sine phase, about 31 seconds in both editions. Keep the 128K band low.
- Restore the original roto rotation/zoom from `7d91635`, including white dots.
  Retain complete-pose copying at about 25 FPS. The historical table digest is
  protected by a regression test.
- Correct the central cube's half-speed phase using the full frame counter,
  removing alternating jumps and detached rows. Preserve the white dithered
  hero and four moving companions.
- Fix the starfield title entrance/exit slowdown; check all three title phases.
- Add three independently paced CMU motion-capture runners, original 32×24
  scrolling lettering, clipped star trails and a wider bending dot tunnel.
- Keep the small scroller moving at two pixels per frame with its larger satellite.
- Clock 128K AY music from IM2 and expand the arrangement to four sections.
  Make the meter strip opaque and reserve its rows through transitions.
- Correct the briefing cursor mask and graph caption overlap.
- Replace the staged BASIC speed claim with actual ROM execution. Show its
  generated source listing, stop after 750 interrupts (15 seconds), restore
  borrowed memory, and continue to precalculated Z80 plots. AY continues in 128K.
- Preserve the fight scene's rendering and sequence placement, as requested.

The rejected faster 25 FPS scroller, experimental roto trajectory/bounce and
full-length in-demo BASIC calculation are no longer the intended behavior.
Implementation details live in the [README](../README.md),
[128K notes](128k-integration.md) and [BASIC notes](../assets/basic/README.md).

## Verification

The 13 runtime tests execute both snapshots with SkoolKit 10.1, interrupts and
ULA contention. They cover timing, cube alignment and scanout, complete roto
poses, visible scroller travel, starfield title phases, stale star pixels,
level-meter contents, music cadence, and BASIC timeout/restoration.

The bounded BASIC interlude measured 15.09 seconds on 48K and 15.11 seconds on
128K, including entry work. Roto measures about 25 FPS; the precalculated
graph scene averages about 48.3 FPS, and the other sampled animated scenes
measure about 50 FPS. These are
simulation results, not physical hardware measurements.

The full standalone corrected BASIC benchmark measured 557,027,926 T-states,
159.150836 simulated seconds, for 1,363 candidate evaluations (8.5642/sec).
Candidate evaluations are not a count of lit pixels. The demo deliberately shows
only a short preview; it does not display the full benchmark result as a live rate.

Closing verification passed: all 13 runtime tests and both editions’ static
artifact checks. An empty-directory build matched both SNA and TAP outputs
byte for byte. Deleting the generated BASIC listing and rebuilding also passed.
Reproduce the checks using the build/test commands in the README.

## Remaining acceptance and limits

- Daniel's visual UAT remains the acceptance step for movement, pacing and audio.
  The latest requested viewing edition is **128K**. Do not switch to 48K merely
  because earlier notes requested it.
- The reported 48K display/loading issue was not reproduced with the current
  snapshot in simulation. If it recurs, identify the loaded artifact and whether
  it is SNA or TAP before changing the renderer.
- TAP loading and physical hardware have not been verified for this revision.
- BASIC error/BREAK exits route through restoration, but the runtime regression
  specifically verifies the normal timed preview path.

## Deferred projects

No standalone demo project has been started. After acceptance of the combined
show, select scenes and controls with Daniel. A standalone runner can explore a
solid articulated body and later player control with its own memory budget.
These are future options, not unfinished requirements of the current demo.
