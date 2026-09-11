#!/usr/bin/env python3
"""Regenerate the ROM entry context using SkoolKit; run from the repo root.

Generated assets contain program, system-variable and stack bytes, no ROM image.
The entry is captured at the first USR, then relocated to E000 with a bounded
stack at E7FF. ROM errors/BREAK enter the demo's data-restoration path.
"""
import sys,subprocess,json
from pathlib import Path
sys.path.insert(0,'tools')
from basic_graph_program import LIVE_LINES, BASIC_EXIT, program,tape
from skoolkit.snapshot import Snapshot
from skoolkit.simutils import from_snapshot
from skoolkit.ccmiosimulator import CCMIOSimulator
lines=LIVE_LINES
p=Path('/private/tmp/live-basic.tap');p.write_bytes(tape(program(lines)))
subprocess.run([str(Path(sys.executable).parent/'tap2sna.py'),'-c','cmio=1','--start','32768',str(p),'/private/tmp/live-basic.z80'],check=True)
snap=Snapshot.get('/private/tmp/live-basic.z80');sim=from_snapshot(CCMIOSimulator,snap);m=sim.memory
word=lambda a:m[a]+256*m[a+1]
def put(a,v):m[a]=v&255;m[a+1]=v>>8
prog,end,top=word(23635),word(23653),word(23730)
delta=0xE000-prog;ds=0xE7FF-top
progdata=bytes(m[a] for a in range(prog,end));stack=bytearray(m[a] for a in range(snap.sp,top+1))
for a in (23627,23629,23635,23637,23641,23643,23645,23647,23649,23651,23653):
 v=word(a)
 if prog<=v<=end:put(a,v+delta)
put(23613,word(23613)+ds);put(23730,0xE7FF)
# ROM error/BREAK returns to the same restoration path as successful completion.
i=word(23613)-(snap.sp+ds);stack[i:i+2]=BASIC_EXIT.to_bytes(2,'little')
# Black paper, green ink; no FLASH. Permanent/temporary attributes and border.
m[23693]=4;m[23695]=4;m[23624]=0
context=bytes(m[a] for a in range(0x5C00,prog))
registers={k:getattr(snap,k) for k in ('a','f','bc','de','hl','a2','f2','bc2','de2','hl2','ix','iy')}
for k,v in registers.items():
 if k not in ('a','f','a2','f2') and prog<=v<=end:registers[k]=v+delta
registers['sp']=snap.sp+ds
out=Path('assets/basic');out.mkdir(exist_ok=True)
for name,data in [('context',context),('program',progdata),('stack',stack)]:
 (out/(name+'.bin')).write_bytes(data);print(name,len(data))
(out/'registers.json').write_text(json.dumps(registers,indent=2)+'\n')
