#!/usr/bin/env python3
"""Dump the ZX Spectrum screen from a running ZEsarUX (ZRCP) to a PNG.

Usage: zrcp_scr.py out.png [--wait-scene N] [--scene-addr 0xNNNN] [--port P]

Renders the 6912-byte screen (no border) at 1x. Pure stdlib (zlib PNG).
"""
import socket
import struct
import sys
import time
import zlib

PORT = 10777
SCENE_ADDR = 0x8B65

PALETTE = [  # normal, then bright
    (0, 0, 0), (0, 0, 215), (215, 0, 0), (215, 0, 215),
    (0, 215, 0), (0, 215, 215), (215, 215, 0), (215, 215, 215),
    (0, 0, 0), (0, 0, 255), (255, 0, 0), (255, 0, 255),
    (0, 255, 0), (0, 255, 255), (255, 255, 0), (255, 255, 255),
]


def zrcp(cmd, port=None):
    port = PORT if port is None else port   # resolved per call, not at def

    s = socket.create_connection(("localhost", port), timeout=5)
    s.recv(4096)  # banner
    s.sendall((cmd + "\n").encode())
    time.sleep(0.15)
    data = b""
    s.settimeout(1.5)
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
            if b"command>" in data[-40:]:
                break
    except socket.timeout:
        pass
    s.close()
    txt = data.decode("ascii", "replace")
    lines = [l.strip() for l in txt.replace("command>", "").splitlines()]
    return "".join(l for l in lines if l and all(c in "0123456789ABCDEFabcdef" for c in l))


def read_mem(addr, length):
    out = b""
    while length:
        n = min(length, 1024)
        for _ in range(5):  # ZRCP reads can come back short: retry
            h = zrcp(f"read-memory {addr} {n}")
            if len(h) >= n * 2:
                break
            time.sleep(0.2)
        else:
            raise IOError(f"short read at {addr:#x}")
        out += bytes.fromhex(h[:n * 2])
        addr += n
        length -= n
    return out


def scr_to_rgb(scr):
    px = [[(0, 0, 0)] * 256 for _ in range(192)]
    for y in range(192):
        base = ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2)
        for cx in range(32):
            bits = scr[base + cx]
            attr = scr[6144 + (y // 8) * 32 + cx]
            ink, paper = attr & 7, (attr >> 3) & 7
            if attr & 0x40:
                ink += 8
                paper += 8
            for b in range(8):
                px[y][cx * 8 + b] = PALETTE[ink if bits & (0x80 >> b) else paper]
    return px


def write_png(path, px):
    h, w = len(px), len(px[0])
    raw = b"".join(b"\x00" + b"".join(bytes(p) for p in row) for row in px)
    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6))
           + chunk(b"IEND", b""))
    with open(path, "wb") as output:
        output.write(png)


def main():
    global PORT
    out = sys.argv[1]
    args = sys.argv[2:]
    if "--port" in args:        # documented since day one, never actually
        PORT = int(args[args.index("--port") + 1])   # parsed - every dump
    if "--wait-scene" in args:  # silently went to whatever sits on 10777
        want = int(args[args.index("--wait-scene") + 1])
        addr = SCENE_ADDR
        if "--scene-addr" in args:
            addr = int(args[args.index("--scene-addr") + 1], 0)
        for _ in range(300):
            cur = read_mem(addr, 1)[0]
            if cur == want:
                time.sleep(0.6)  # settle a couple of frames into the scene
                break
            time.sleep(0.4)
        else:
            sys.exit(f"scene {want} never seen (last={cur})")
    zrcp("enter-cpu-step")  # freeze the emulator: atomic, tear-free dump
    try:
        scr = read_mem(0x4000, 6912)
    finally:
        zrcp("exit-cpu-step")
    write_png(out, scr_to_rgb(scr))
    print("wrote", out)


if __name__ == "__main__":
    main()
