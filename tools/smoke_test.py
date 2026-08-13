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
from zrcp_scr import read_mem, zrcp  # noqa: E402

PORT = 10777
LST = "build/aura-tunnel.lst"

ARTIFACTS = {
    "build/aura-tunnel.sna": 49179,
    "build/aura-tunnel.tap": None,      # size varies with code changes
    "build/maps.bin": 8064,
    "build/mustab.bin": 512,
    "build/cube.bin": 2048,
    "build/minicube.bin": 1024,
    "build/stickman.bin": 640,
    "build/ministick.bin": 160,
    "build/yiear.bin": 2400,
    "build/stars.bin": 192,
}

# scene id -> (name, minimum acceptable fps)
SCENES = {
    0: ("tunnel", 49.0),
    3: ("vector cube", 49.0),
    4: ("star snake", 49.0),
    5: ("big type", 49.0),
    6: ("sunset run", 47.0),   # concedes ~4% on bass-note frames
    8: ("dojo", 49.0),
    10: ("3d graphs", 48.0),   # act two stalls 2 frames per surface wipe
}

PLAYLIST = {9, 0, 4, 1, 5, 2, 6, 3, 7, 10, 8}


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


def static_checks():
    for path, want in ARTIFACTS.items():
        if not os.path.exists(path):
            fail(f"missing {path}")
        got = os.path.getsize(path)
        if want is not None and got != want:
            fail(f"{path}: {got} bytes, expected {want}")
    print(f"ok: {len(ARTIFACTS)} build artifacts present and sized")


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

    zrcp("smartload " + os.path.abspath("build/aura-tunnel.sna"))
    time.sleep(2)

    def f16():
        d = read_mem(frames_a, 2)
        return d[0] | (d[1] << 8)

    def fps():
        # Best of three wall-clock samples: macOS may throttle the
        # backgrounded emulator (App Nap), which only ever slows the
        # reading - the max is the honest figure.
        best = 0.0
        for _ in range(3):
            time.sleep(0.6)
            a, t0 = f16(), time.time()
            time.sleep(1.6)
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
        zrcp(f"write-memory {seq_a} " + " ".join([str(sc)] * 14))
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

    zrcp("smartload " + os.path.abspath("build/aura-tunnel.sna"))
    print("ok: emulator restored to a clean boot")


def main():
    static_checks()
    if emulator_reachable():
        live_checks()
    else:
        print("skip: no ZEsarUX on port 10777 - live checks not run")
        print("      (launch with: make emu)")
    print("SMOKE TEST PASSED")


if __name__ == "__main__":
    main()
