#!/usr/bin/env python3
"""Smoke test for AURA TUNNEL.

Static checks always run: build artifacts exist with the expected sizes.
If a ZEsarUX instance with ZRCP is reachable (see README: make emu), the
live checks also run: the demo boots, the playlist cycles through every
scene, and each heavy scene holds its frame-rate floor.

Exit code 0 = pass.  Run via `make test`.
"""
import os
import re
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import zrcp_scr  # noqa: E402
from zrcp_scr import read_mem, zrcp  # noqa: E402

PORT = 10777
LST = "build/aura-tunnel.lst"
SNA = "build/aura-tunnel.sna"
IS128 = False

ARTIFACTS = {
    "build/aura-tunnel.sna": 49179,
    "build/aura-tunnel.tap": None,      # size varies with code changes
    "build/roto.bin": 4096,
    "build/dbltab.bin": 512,
    "build/cubebig.bin": 4096,  # dither-shaded solid cube, baked per
                                # rotation - the wireframe renderer and
                                # its vertex tables are gone entirely
    "build/minicube.bin": 1024,
    "build/runner.bin": 1536,   # 12 poses x 64 points x 2 coordinates
    "build/runner-small.bin": 448,  # 8 poses x 28 points x 2 coordinates
    "build/yiear.bin": 2400,
    "build/stars.bin": 192,
}

# The 128K edition adds AY music and the lower-third console; everything
# else about the test is shared.  `--128` switches the whole run over.
ARTIFACTS_128 = {
    "build/aura-tunnel-128.sna": 131103,   # 128K snapshot: header + 8 banks
    "build/aura-tunnel-128.tap": None,
    "build/aymus.bin": 10997,               # the baked AY register stream
}


def use_128k():
    global PORT, LST, SNA, IS128
    PORT = zrcp_scr.PORT = 10778           # clear of the 48K emulator
    LST = "build/aura-tunnel-128.lst"
    SNA = "build/aura-tunnel-128.sna"
    IS128 = True
    ARTIFACTS.update(ARTIFACTS_128)

# scene id -> (name, minimum acceptable fps)
SCENES = {
    0: ("dot tunnel", 49.0),
    3: ("solid cubes", 49.0),  # Driller-style dither-shaded, baked sprites
    4: ("star snake", 49.0),
    5: ("sine scroll", 47.5),  # 24 rows shifted and repainted every frame
    6: ("dot runner", 47.0),   # hi-res dot skeleton + companion
    8: ("night train", 49.0),  # Yie Ar bout on a moving flatbed
    10: ("3d graphs", 48.0),   # act two stalls on each surface wipe
    11: ("roto grid", 49.0),
}

PLAYLIST = {9, 0, 11, 4, 5, 3, 6, 7, 10, 8}


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def sym(pattern):
    """Fetch a symbol's address from the current listing - never hardcode:
    addresses move with every build."""
    for line in open(LST):
        if re.search(pattern, line):
            return int(line.split()[1], 16)
    fail(f"symbol {pattern!r} not found in {LST}")


def seqlen():
    """How many playlist slots there are.

    Pinning a scene works by filling the whole of SEQ with one id.  Fill fewer
    slots than there are and the demo escapes the pin at the first untouched
    one, halfway through a measurement, which reads as a mystery frame-rate
    dip.  So take the count from the source rather than hardcoding it - the
    playlist grows whenever a scene is given a longer slot.
    """
    return sym(r"SEQEND:") - sym(r"SEQ:    db")


def check_listing_matches_memory():
    """Prove the loaded binary is the one this listing describes.

    Every address in this file comes from the .lst, and the .lst is rewritten
    by every build.  Rebuild while the test is running - easy to do when two
    people share the repo - and the addresses silently start pointing at the
    wrong places.  The failures that causes are baffling: reads return
    plausible-looking rubbish and the test blames the demo.  So sample some
    code from the listing and check it is actually there.
    """
    checked = 0
    for line in open(LST):
        m = re.match(r"^\s*\S+\s+([0-9A-F]{4})\s+((?:[0-9A-F]{2} ){4,})", line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        if addr < 0x8000:           # sample the always-mapped code region
            continue
        want = bytes.fromhex(m.group(2).replace(" ", ""))
        got = read_mem(addr, len(want))
        if got != want:
            fail(f"{LST} does not describe the loaded binary "
                 f"(${addr:04X}: expected {want.hex(' ')}, found {got.hex(' ')})"
                 f"\n      Something rebuilt since this .sna was made. "
                 f"Re-run `make` and try again.")
        checked += 1
        if checked == 6:
            break
    print(f"ok: listing matches the loaded binary ({checked} samples)")


def static_checks():
    for path, want in ARTIFACTS.items():
        if not os.path.exists(path):
            fail(f"missing {path}")
        got = os.path.getsize(path)
        if want is not None and got != want:
            fail(f"{path}: {got} bytes, expected {want}")
    print(f"ok: {len(ARTIFACTS)} build artifacts present and sized")

    # `make` never cleans build/, so a table that is one refactor out of date
    # keeps happily asserting the size of a file nothing includes any more.
    # The source is the authority on what is actually part of the demo.
    src = open("src/main.asm").read()
    stale = [p for p in ARTIFACTS
             if p.endswith(".bin") and p not in src]
    if stale:
        fail("these are checked but no longer INCBINed by src/main.asm - "
             "stale leftovers in build/, drop them from ARTIFACTS:\n      "
             + ", ".join(sorted(stale)))
    print(f"ok: every checked .bin is still part of the build")


def emulator_reachable():
    try:
        s = socket.create_connection(("localhost", PORT), timeout=2)
        s.close()
        return True
    except OSError:
        return False


def live_checks():
    frames_a = sym(r"FRAMES: dw 0")
    scene_a = sym(r"SCENE:  db")
    seq_a = sym(r"SEQ:    db")

    zrcp("smartload " + os.path.abspath(SNA))
    time.sleep(2)
    check_listing_matches_memory()

    # The AY checks go first, while the emulator is fresh.  They are quick and
    # order-independent, and ZEsarUX reliably wedges partway through the
    # frame-rate sweep - so anything left until afterwards never gets to run.
    if IS128:
        ay_checks()

    def f16():
        d = read_mem(frames_a, 2)
        return d[0] | (d[1] << 8)

    def fps():
        # Best of four wall-clock samples: macOS App Nap throttles the
        # backgrounded emulator, which only ever slows the reading - so the
        # noise is one-sided and the max is the honest figure.  Four rather
        # than three because the same binary measured 42.8 / 49.9 / 46.7 /
        # 50.0 across four runs of one scene; below that, a 1-2 fps
        # difference means nothing at all.
        best = 0.0
        for _ in range(4):
            time.sleep(0.4)
            a, t0 = f16(), time.time()
            time.sleep(1.9)
            b, t1 = f16(), time.time()
            best = max(best, ((b - a) & 0xFFFF) / (t1 - t0))
        return best

    # 1. the playlist visits every scene
    seen = set()
    deadline = time.time() + 180
    while time.time() < deadline and not PLAYLIST <= seen:
        seen.add(read_mem(scene_a, 1)[0])
        time.sleep(1.0)
    if not PLAYLIST <= seen:
        fail(f"playlist incomplete after 180s: saw {sorted(seen)}")
    print(f"ok: playlist visited all {len(PLAYLIST)} scenes")

    # 2. every heavy scene holds its frame-rate floor (pin via SEQ in RAM)
    for sc, (name, floor) in SCENES.items():
        zrcp(f"write-memory {seq_a} " + " ".join([str(sc)] * seqlen()))
        for _ in range(120):
            if read_mem(scene_a, 1)[0] == sc:
                break
            time.sleep(0.4)
        else:
            fail(f"never reached scene {sc} ({name})")
        time.sleep(4.0)  # settle past title card and transitions
        r = fps()
        status = "ok" if r >= floor else "FAIL"
        print(f"{status}: {name} {r:.1f} fps (floor {floor})")
        if r < floor:
            fail(f"{name} below its frame-rate floor")

    zrcp("smartload " + os.path.abspath(SNA))
    print("ok: emulator restored to a clean boot")


def ay_checks():
    """128K only: prove the music plays and the console tracks it.

    Neither of these shows up in the frame-rate probe - a stalled stream
    pointer and a console painting the wrong cells both hold 50 fps quite
    happily.  Worth testing directly.
    """
    ayptr_a = sym(r"AYPTR:")
    aybar_a = sym(r"AYBAR:")
    muson_a = sym(r"MUSON:")
    frames_a = sym(r"FRAMES: dw 0")

    def ptr():
        d = read_mem(ayptr_a, 2)
        return d[0] | (d[1] << 8)

    # 0. is the demo even running?  ZEsarUX wedges after a long ZRCP session -
    #    the CPU stops and every read returns stale bytes.  Without this check
    #    a wedged emulator looks exactly like a stalled music player, and the
    #    test blames the demo for the tooling's problem.
    f0 = read_mem(frames_a, 2)
    time.sleep(0.8)
    if read_mem(frames_a, 2) == f0:
        fail("the demo is not running - its frame counter is frozen.\n"
             "      ZEsarUX has most likely wedged (it does this after a long\n"
             "      ZRCP session, and `run` will not revive it).  Restart the\n"
             "      emulator and re-run; this is not a fault in the demo.")

    # 1. the score is advancing, and staying inside the paged music bank
    p0 = ptr()
    time.sleep(1.0)
    p1 = ptr()
    if p0 == p1:
        fail("AY stream pointer is not advancing - the player has stalled")
    for p in (p0, p1):
        if not 0xC000 <= p <= 0xFFFF:
            fail(f"AY stream pointer ${p:04X} is outside the paged bank")
    print("ok: AY score advancing inside the music page")

    # 2. every bar matches the level it claims to have painted.  The CPU has
    #    to be frozen for this: read the levels and the attributes in two
    #    separate round-trips of a running demo and they come from different
    #    frames, which makes every sample look broken when nothing is.
    wipef_a = sym(r"WIPEF:")
    trmode_a = sym(r"TRMODE: db")
    checked = 0
    for _ in range(12):
        zrcp("enter-cpu-step")
        try:
            bar = read_mem(aybar_a, 9)       # 3 x [level, attr, painted]
            attrs = read_mem(0x5AA0, 96)     # the scroller window, rows 21-23
            sliding = (read_mem(wipef_a, 1)[0] < 24
                       and read_mem(trmode_a, 1)[0] != 0)
        finally:
            zrcp("exit-cpu-step")
        if sliding:
            # The console stands down through a slide on purpose - SLIDER
            # shifts the bars away and nothing repaints them until the new
            # scene lands.  "Screen matches painted level" is only an
            # invariant outside a slide, so this sample proves nothing.
            time.sleep(0.3)
            continue
        checked += 1
        for ch in range(3):
            attr, painted = bar[ch * 3 + 1], bar[ch * 3 + 2]
            row = attrs[ch * 32:(ch + 1) * 32]
            lit = [i for i, v in enumerate(row) if v == attr]
            want = list(range(16 - painted, 16 + painted)) if painted else []
            if lit != want:
                fail(f"console row {21 + ch}: {len(lit)} cells lit, "
                     f"expected {len(want)} for level {painted}")
        if checked == 4:
            break
        time.sleep(0.3)
    if not checked:
        fail("never caught the console outside a slide - cannot verify it")
    print(f"ok: console bars match the AY levels exactly ({checked} samples)")

    # 3. M parks the chip and freezes the score where it stands
    zrcp(f"write-memory {muson_a} 0")
    time.sleep(0.6)
    muted = ptr()
    time.sleep(0.6)
    if ptr() != muted:
        fail("muted, but the score kept running")
    if any(read_mem(aybar_a, 9)[c * 3] for c in range(3)):
        fail("muted, but the console still shows levels")
    zrcp(f"write-memory {muson_a} 1")
    time.sleep(0.6)
    if ptr() == muted:
        fail("unmuted, but the score did not resume")
    print("ok: M mutes the AY, freezes the score, and resumes it")


def main():
    global PORT
    if "--128" in sys.argv[1:]:
        use_128k()
        print("target: 128K edition (AY music + lower-third console)")
    if "--port" in sys.argv[1:]:        # two emulators can be up at once
        PORT = zrcp_scr.PORT = int(sys.argv[sys.argv.index("--port") + 1])
    static_checks()
    if emulator_reachable():
        live_checks()
    else:
        print(f"skip: no ZEsarUX on port {PORT} - live checks not run")
        print(f"      (launch with: make {'emu128' if IS128 else 'emu'})")
    print("SMOKE TEST PASSED")


if __name__ == "__main__":
    main()
