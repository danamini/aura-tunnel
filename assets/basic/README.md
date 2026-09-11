# Real ROM BASIC

The graph scene runs a 15-second preview in the Spectrum's ROM interpreter,
with a generated source listing above the plot, then resumes the precalculated
machine-code scene. The live `PLOT` height is halved to fit below the listing;
the surface calculation itself runs in BASIC.

These assets contain generated program, system-variable, register and stack
state. They do not contain a ROM image.

## Source and entry context

`tools/basic_graph_program.py` defines the shared program, tokenisation, preview
length and fixed return address. `GRAPH_LINES` is the full unscaled benchmark;
`LIVE_GRAPH_LINES` applies the display scaling. Both use `M(X1+1)` to correct
the historical listing's invalid first access to `M(0)`.

`tools/gen_basic_seed.py` captures the ROM's first USR call using SkoolKit,
relocates program/workspace to `$E000` and the stack below `$E800`, and redirects
ROM error/BREAK unwinding to the restoration routine. `DEFADD` must be relocated
along with `PROG`, `VARS`, `CH_ADD` and the calculator-stack pointers.

Regenerate from the repository root after changing the live program, using the
Python environment described in the main README:

```sh
make basic-seed PYTHON=.venv/bin/python
make all PYTHON=.venv/bin/python
make test-runtime PYTHON=.venv/bin/python
```

The displayed listing is generated from the live source during the normal build.
The runtime test checks that the captured tokenised program matches that source.

## Timed return

The first 2 KB of the roto table is backed up in `DOTS`, `BSBUF` and `BSGLY`.
Both editions use a bounded IM2 interlude that chains to the ROM keyboard/clock
handler. After 750 interrupts it restores the demo, leaving the graph unfinished.
The measured interval including entry work is 15.09 seconds on 48K and 15.11
seconds on 128K in SkoolKit simulation.

The 128K handler also plays AY music. Exit reinstates the normal AY handler on
128K or the RETI vector on 48K, restores borrowed memory and resumes the playlist.
The final BASIC USR and error/BREAK unwind use the same restoration destination.
The automated regression verifies the timed path, not every error/BREAK case.

## Full benchmark

```sh
.venv/bin/python tools/benchmark_basic_graph.py --corrected
```

The benchmark has no live listing, display scaling or preview timeout. Its CPU
time includes `DIM` and setup, excludes tape loading, and covers all 1,363
candidate evaluations. The corrected program measured 557,027,926 T-states:
159.150836 simulated seconds on 48K, or 8.5642 candidate evaluations per second.
This is not a plotted-pixel rate: the visibility condition can skip a candidate.

Outputs go to `build/basic-benchmark/`, including `result.json` and `graph.png`.
Omit `--corrected` to reproduce the historical `M(0)` error. That reproduction
is expected to report `completed: false`; it is not a successful full benchmark.
