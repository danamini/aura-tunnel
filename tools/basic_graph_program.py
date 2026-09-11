"""One definition of the real BASIC graph, shared by seed generation and benchmarks."""
import re
import struct

# Sinclair BASIC keyword bytes; only the keywords used by this listing.
TOKENS = {'PI':167,'COS':179,'EXP':185,'USR':192,'>=':200,'THEN':203,
          'TO':204,'STEP':205,'DIM':233,'FOR':235,'LET':241,'NEXT':243,
          'PRINT':245,'PLOT':246,'IF':250,'PAUSE':242}
GRAPH_LINES = [(10,'DIM M(255)'),(15,'LET A=COS (PI/4)'),
 (20,'FOR Y=0 TO 140 STEP 5'),(30,'LET E=A*Y'),
 (40,'FOR X=0 TO 140 STEP 3'),(50,'LET C=X-70: LET D=Y-70'),
 (60,'LET Z=78*EXP (-(C*C+D*D)/1400)'),
 (70,'LET X1=X+E: LET Y1=Z+E'),
 (80,'IF Y1>=M(X1+1) THEN PLOT X1,Y1'),
 (85,'LET M(X1+1)=Y1'),(90,'NEXT X: NEXT Y')]

def tokenise(text):
    pattern='|'.join(re.escape(k) for k in sorted(TOKENS,key=len,reverse=True))
    out=bytearray(); quoted=False
    for m in re.finditer(pattern+r'|\d+|.',text):
        value=m[0]
        if value=='"': quoted=not quoted;out.extend(value.encode())
        elif quoted:out.extend(value.encode())
        elif value in TOKENS:out.append(TOKENS[value])
        elif value.isdigit():
            out.extend(value.encode()+bytes([14,0,0])+struct.pack('<H',int(value))+b'\0')
        elif value!=' ':out.extend(value.encode())
    return out+b'\r'

def program(lines):
    result=b''
    for n,text in lines:
        data=tokenise(text)
        result+=struct.pack('>H',n)+struct.pack('<H',len(data))+data
    return result

def tape(data):
    def block(raw):
        checksum=0
        for value in raw:checksum^=value
        return struct.pack('<H',len(raw)+1)+raw+bytes([checksum])
    return block(b'\0\0GRAPH     '+struct.pack('<HHH',len(data),5,len(data)))+block(b'\xff'+data)

BASIC_EXIT = 0xF800
BASIC_PREVIEW_TICKS = 15 * 50
# Scale only the live display vertically so the running source stays above it.
LIVE_GRAPH_LINES = [(n,s.replace('PLOT X1,Y1','PLOT X1,Y1/2')) for n,s in GRAPH_LINES]
LIVE_LINES = [(5,'LET Q=USR 32768')] + LIVE_GRAPH_LINES + [(100,f'LET Q=USR {BASIC_EXIT}')]
