"""Emit assembler constants for the captured, relocated ROM entry context."""
import json
from pathlib import Path
import sys
from basic_graph_program import BASIC_EXIT, BASIC_PREVIEW_TICKS, LIVE_GRAPH_LINES
import textwrap
out=Path(sys.argv[1] if len(sys.argv)>1 else 'build');out.mkdir(exist_ok=True)
registers=json.loads(Path('assets/basic/registers.json').read_text())
outputs = sys.argv[2:] or ['basic-registers.asm', 'basic-listing.asm']
if 'basic-registers.asm' in outputs:
    (out/'basic-registers.asm').write_text('\n'.join(f'BASIC_{k.upper()} EQU ${v:04X}' for k,v in registers.items())+f'\nBASIC_EXIT EQU ${BASIC_EXIT:04X}\nBASIC_PREVIEW_TICKS EQU {BASIC_PREVIEW_TICKS}\n')

rows=[f'REAL BASIC - {BASIC_PREVIEW_TICKS // 50} SECOND PREVIEW']
for number,text in LIVE_GRAPH_LINES:
    rows.extend(textwrap.wrap(f'{number} {text}',width=32,break_long_words=False,break_on_hyphens=False))
assert len(rows)<=15, rows
listing=[]
for row,text in enumerate(rows):
    listing += [f'        db 0,{row},${0x46 if row==0 else 0x47:02X},{len(text)}',f'        db "{text}"']
listing.append('        db $FF')
if 'basic-listing.asm' in outputs:
    (out/'basic-listing.asm').write_text('\n'.join(listing)+'\n')
