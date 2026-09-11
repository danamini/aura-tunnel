#!/usr/bin/env python3
"""Execute both assembled snapshots with Z80/ULA contention and real interrupts.

Install tools/requirements-test.txt into a venv, then run with that Python.
No desktop emulator is modified. Optional --shots DIR exports actual screens.
"""
import argparse
from pathlib import Path
import re
import hashlib
import unittest

from skoolkit.ccmiosimulator import CCMIOSimulator
from skoolkit.pagingtracer import PagingTracer
from skoolkit.simutils import from_snapshot
from skoolkit.snapshot import Snapshot
from zrcp_scr import scr_to_rgb, write_png

ROOT = Path(__file__).resolve().parents[1]
SHOTS = None


class Tracer(PagingTracer):
    def __init__(self, simulator, snapshot):
        self.simulator = simulator
        self.out7ffd = snapshot.out7ffd
        self.outfffd = 0
        self.ay = [0] * 16
        self.outfe = self.border = 0
        self.music_ticks = []

    def write_port(self, registers, port, value, offset):
        if port & 0xC002 == 0xC000 and value == 8:
            self.music_ticks.append(registers[25] + offset)
        super().write_port(registers, port, value, offset)


class Demo:
    def __init__(self, target128=True):
        name = 'aura-tunnel-128' if target128 else 'aura-tunnel'
        listing = (ROOT/'build'/f'{name}.lst').read_text()
        self.symbols = {}
        for line in listing.splitlines():
            m = re.match(r'^\s*\d+\+?\s+([0-9A-F]{4})\s+(?:[0-9A-F]{2}\s+)*([A-Za-z][A-Za-z0-9_]*):', line)
            if m:
                self.symbols[m[2]] = int(m[1], 16)
        snap = Snapshot.get(str(ROOT/'build'/f'{name}.sna'))
        self.sim = from_snapshot(CCMIOSimulator, snap)
        self.trace = Tracer(self.sim, snap)
        self.sim.set_tracer(self.trace)
        self.main = self.symbols['MAIN']
        self.target128 = target128
        self.sim.run(stop=self.main)
        self.trace.music_ticks.clear()

    def mem(self, address, count):
        return bytes(self.sim.memory[a] for a in range(address, address+count))

    def byte(self, symbol):
        return self.sim.memory[self.symbols[symbol]]

    def word(self, symbol):
        lo, hi = self.mem(self.symbols[symbol], 2)
        return lo + hi*256

    def frame(self):
        self.sim.run(stop=self.main, interrupts=True)

    def pin(self, scene):
        for a in range(self.symbols['SEQ'], self.symbols['SEQEND']):
            self.sim.memory[a] = scene
        for _ in range(520):
            self.frame()
        assert self.byte('SCENE') == scene

    def screen(self):
        return self.mem(0x4000, 6912)

    def shot(self, name):
        if SHOTS:
            write_png(str(SHOTS/f'{name}.png'), scr_to_rgb(self.screen()))


class RuntimeTests(unittest.TestCase):
    def test_real_basic_preview_times_out_and_restores_the_demo(self):
        from basic_graph_program import LIVE_LINES, program
        expected = program(LIVE_LINES)
        self.assertEqual((ROOT/'assets/basic/program.bin').read_bytes()[:len(expected)],expected,
                         'regenerate the ROM entry context after changing the shared listing')
        for target128 in (False, True):
            demo = Demo(target128)
            for a in range(demo.symbols['SEQ'],demo.symbols['SEQEND']):
                demo.sim.memory[a] = 10
            demo.sim.run(stop=demo.symbols['BASICENTER'],interrupts=True)
            original = demo.mem(0xE000,4096)
            start = demo.sim.registers[25]
            demo.sim.run(stop=demo.symbols['BASICDONE'],interrupts=True)
            seconds = (demo.sim.registers[25]-start)/(3546900 if target128 else 3500000)
            self.assertEqual(demo.sim.memory[23610],255,'ROM BASIC reported an error')
            self.assertGreater(seconds,14.9,'the live calculation must not be skipped')
            self.assertLess(seconds,15.2)
            self.assertEqual(demo.byte('BASICTIMEDOUT'),1)
            graph_bits=0
            for y in range(128,176):
                address=0x4000+(((y&192)<<5)|((y&7)<<8)|((y&56)<<2))
                graph_bits+=sum(v.bit_count() for v in demo.mem(address,32))
            self.assertGreater(graph_bits,20,'the ROM must draw points below the listing')
            demo.shot(f'{128 if target128 else 48}-real-basic')
            demo.sim.run(stop=demo.main,interrupts=True)
            self.assertEqual(demo.mem(0xE000,4096),original)
            self.assertEqual(demo.byte('GBASICACTIVE'),0)
            self.assertEqual(demo.byte('GREALDONE'),1)
            print(f'  {128 if target128 else 48}K live ROM graph: {seconds:.2f} seconds',flush=True)

    def test_starfield_title_does_not_halve_the_frame_rate(self):
        for target128 in (False, True):
            demo = Demo(target128)
            demo.pin(7)
            demo.sim.memory[demo.symbols['TITLEF']] = 0
            for frames in (32,100,33):  # entrance, hold, exit including repair
                start = demo.sim.registers[25]
                for _ in range(frames):
                    demo.frame()
                fps = frames*(3546900 if target128 else 3500000)/(demo.sim.registers[25]-start)
                self.assertGreater(fps,49)

    def test_smooth_scroller_letter_rises_and_falls_while_crossing_screen(self):
        demo = Demo(True)
        demo.pin(5)
        for a in range(0x4000,0x5800): demo.sim.memory[a] = 0
        for a in range(0xAC00,0xAF00): demo.sim.memory[a] = 0
        for a in range(0xB200,0xB260): demo.sim.memory[a] = 0
        demo.sim.memory[0xAC00+30] = 0x80  # one visible point in the letter buffer
        demo.sim.memory[demo.symbols['BSBIT']] = 255
        for a in range(demo.symbols['FRAMES'],demo.symbols['FRAMES']+2):
            demo.sim.memory[a] = 0
        heights=[]
        for frame in range(1,181):
            demo.frame()
            x=240-frame
            ys=[]
            for y in range(120,160):
                address=0x4000+(((y&192)<<5)|((y&7)<<8)|((y&56)<<2))+(x//8)
                if demo.sim.memory[address] & (0x80>>(x%8)): ys.append(y)
            self.assertEqual(len(ys),1)
            heights.append(ys[0])
        self.assertGreaterEqual(max(heights)-min(heights),14,
                                'wave must not travel in step with the faster text')

    def test_music_is_clocked_by_interrupts_through_every_scene_and_transition(self):
        demo = Demo()
        seen = set()
        for _ in range(20*256+256):
            demo.frame()
            seen.add(demo.byte('SCENE'))
        self.assertEqual(seen, {0,3,4,5,6,7,8,9,10,11})
        ticks = demo.trace.music_ticks
        self.assertGreater(len(ticks), 5000)
        gaps = [b-a for a,b in zip(ticks, ticks[1:])]
        self.assertLess(max(gaps), 70908+250)
        self.assertGreater(min(gaps), 70908-250)
        print(f'  music: {len(ticks)} ticks, spacing {min(gaps)}..{max(gaps)} T', flush=True)

    def test_meter_strip_is_opaque_and_matches_painted_levels(self):
        demo = Demo()
        for scene in [9,0,11,4,5,3,6,7,10,8]:
            demo.pin(scene)
            for _ in range(32):
                demo.frame()
                bars = demo.mem(demo.symbols['AYBAR'], 9)
                attrs = demo.mem(0x5AA0, 96)
                for ch in range(3):
                    color, painted = bars[ch*3+1:ch*3+3]
                    want = bytes(color if 16-painted <= x < 16+painted else 0 for x in range(32))
                    self.assertEqual(attrs[ch*32:ch*32+32], want, f'scene {scene}, channel {ch}')
            demo.shot(f'128-scene-{scene}')

    def test_deep_space_leaves_no_pixels_outside_the_current_trails(self):
        demo = Demo()
        demo.pin(7)
        for _ in range(260):
            demo.frame()
            expected = bytearray(6144)
            stars = demo.mem(demo.symbols['STARDAT'], 192)
            for i in range(0,192,4):
                x,y = stars[i+1:i+3]
                for px in range(x,min(256,x+6)):
                    addr = ((y&0xC0)<<5)|((y&7)<<8)|((y&0x38)<<2)|(px>>3)
                    expected[addr] |= 0x80>>(px&7)
                if i < 16:
                    # Foreground star core, clipped at its byte boundary.
                    yy=y+1
                    addr=((yy&0xC0)<<5)|((yy&7)<<8)|((yy&0x38)<<2)|(x>>3)
                    mask=0x80>>(x&7)
                    expected[addr] |= mask | (mask>>1)
            actual = demo.mem(0x4000,6144)
            leftovers = [(i,a & ~e) for i,(a,e) in enumerate(zip(actual,expected)) if a & ~e]
            self.assertFalse(leftovers, f'stale pixels: {leftovers[:8]}')

    def test_scroller_feeds_every_column_and_restarts_at_the_first_letter(self):
        demo = Demo()
        # Call BSSET as a routine using a sentinel return address.
        def call(symbol):
            demo.sim.registers[12] = 0xF9FE
            demo.sim.memory[0xF9FE] = 0
            demo.sim.memory[0xF9FF] = 0x80
            demo.sim.run(start=demo.symbols[symbol],stop=0x8000)
        call('BSSET')
        glyph = demo.mem(0xB200,96)
        for _ in range(32):
            call('BSFEED')
        for y in range(24):
            self.assertEqual(demo.mem(0xAC00+y*32+28,4),glyph[y*4:y*4+4])
        for _ in range(60):
            call('BSFEED')
        call('BSSET')
        self.assertEqual(demo.mem(0xB200,96),glyph)

    def test_scroller_moves_and_is_visible_in_both_editions(self):
        for target128 in (False, True):
            demo = Demo(target128)
            demo.pin(5)
            step = 1
            start = demo.sim.registers[25]
            for _ in range(64):
                before = demo.mem(0xAC00,768)
                demo.frame()
                after = demo.mem(0xAC00,768)
                for row in range(24):
                    old = int.from_bytes(before[row*32:row*32+32],'big')
                    new = int.from_bytes(after[row*32:row*32+32],'big')
                    self.assertEqual(new >> step, old & ((1 << (256-step))-1))
            clock = 3546900 if target128 else 3500000
            speed = 64*step*clock/(demo.sim.registers[25]-start)
            self.assertGreater(speed,49)
            pixels = scr_to_rgb(demo.screen())
            top = 119 if target128 else 71
            self.assertTrue(any(pixel != (0,0,0)
                                for row in pixels[top:top+42] for pixel in row),
                            'scrolling bitmap must also have visible ink')

    def test_hero_motion_and_bitmap_stay_aligned(self):
        for target128 in (False, True):
            demo = Demo(target128)
            demo.pin(3)
            previous_y = demo.byte('CBY')
            for _ in range(512):
                front = demo.word('CBFRONT')
                expected = demo.mem(front, 512)
                demo.frame()
                y = demo.byte('CBY')
                self.assertLessEqual(abs(y-previous_y), 1,
                                     'hero jumps farther than its exposed-row erase')
                previous_y = y
                for row in range(56, 136):
                    address = 0x4000 + (((row&192)<<5)|((row&7)<<8)|((row&56)<<2)) + 12
                    offset = (row-y)*8
                    wanted = expected[offset:offset+8] if y <= row < y+64 else bytes(8)
                    self.assertEqual(demo.mem(address,8), wanted,
                                     f'hero row {row} contains a detached or stale strip')

    def test_48k_cube_scanout_does_not_see_erased_pixels(self):
        demo = Demo(False)
        demo.pin(3)
        for row in range(7,17):
            self.assertEqual(demo.mem(0x5800+row*32+12,8),bytes([0x47])*8)
        sim = demo.sim
        # Sample bitmap fetches at instruction boundaries across every cube
        # position/size phase. A lit pixel in both neighbouring complete
        # frames must not go blank while the beam scans the intervening draw.
        offsets = [(14335+y*224+(x//2)*8+(x%2)*2,
                    ((y&192)<<5)|((y&7)<<8)|((y&56)<<2)|x)
                   for y in range(168) for x in range(32)]
        for _ in range(256):
            before = demo.mem(0x4000,6144)
            sim.run(stop=demo.symbols['UPDATE'],interrupts=True)
            start = sim.registers[25]//69888*69888
            raster = bytearray(before)
            index = 0
            while sim.registers[24] != demo.main:
                while index < len(offsets) and start+offsets[index][0] <= sim.registers[25]:
                    address = offsets[index][1]
                    raster[address] = sim.memory[0x4000+address]
                    index += 1
                sim.run()
            after = demo.mem(0x4000,6144)
            for _,address in offsets[index:]:
                raster[address] = after[address]
            lost = sum((a&b&~seen).bit_count() for a,b,seen in zip(before,after,raster))
            self.assertEqual(lost,0,'beam caught a cube between erase and redraw')

    def test_roto_preserves_original_rotation_and_zoom_table(self):
        # Golden digest of the original 7d91635 table, before the motion rewrite.
        table = (ROOT/'build/roto.bin').read_bytes()
        self.assertEqual(hashlib.sha256(table).hexdigest(),
                         '78b7dc8d38c159da980bc6ccd95327416d9e367b3e69f4d498c48c8c5ec308fe')

    def test_48k_roto_scanout_matches_one_complete_pose(self):
        demo = Demo(False)
        demo.pin(11)
        self.assertGreater(sum(demo.mem(0x4000,6144)),0,
                           'the requested white-dot depth layer must be present')
        sim = demo.sim
        fetches=[]
        for y in range(168):
            for x in range(32):
                offset=14335+y*224+(x//2)*8+(x%2)*2
                bitmap=0x4000+(((y&192)<<5)|((y&7)<<8)|((y&56)<<2)|x)
                fetches.extend([(offset,bitmap),(offset+1,0x5800+(y//8)*32+x)])
        for _ in range(128):
            sim.run(stop=demo.symbols['UPDATE'],interrupts=True)
            start = sim.registers[25]//69888*69888
            seen=[]
            for offset,address in fetches:
                while sim.registers[25] < start+offset:
                    sim.run()
                seen.append((address,sim.memory[address]))
            sim.run(stop=demo.main)
            for address,value in seen:
                self.assertEqual(value,sim.memory[address],
                                 f'scanout saw an older pose at {address:04x}')

    def test_48k_and_128k_scenes_run_and_export_views(self):
        for target128 in (False,True):
            demo = Demo(target128)
            for scene in (0,3,4,5,6,7,8,10,11):
                demo.pin(scene)
                start = demo.sim.registers[25]
                for _ in range(256):
                    demo.frame()
                elapsed = demo.sim.registers[25]-start
                clock = 3546900 if target128 else 3500000
                fps = 256*clock/elapsed
                self.assertGreater(fps,24.8 if scene == 11 else 48,
                                   f'{target128=} {scene=}')
                print(f'  {128 if target128 else 48}K scene {scene}: {fps:.2f} simulated fps',flush=True)
                demo.shot(f'{128 if target128 else 48}-scene-{scene}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--shots',type=Path)
    args, rest = parser.parse_known_args()
    SHOTS = args.shots
    if SHOTS:
        SHOTS.mkdir(parents=True,exist_ok=True)
    unittest.main(argv=[__file__]+rest,verbosity=2)
