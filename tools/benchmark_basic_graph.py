#!/usr/bin/env python3
"""Benchmark the graph with the actual 48K ROM and contended Z80 execution.

Run in the SkoolKit test environment. --corrected uses the same graph listing
as the live demo; without it, reproduce the historical listing's M(0) error.
Loading is excluded; DIM, setup, evaluations and plotting are timed. No desktop
emulator is touched. Outputs are written under build/basic-benchmark by default.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from basic_graph_program import GRAPH_LINES, program, tape
from skoolkit.snapshot import Snapshot
from skoolkit.simutils import from_snapshot
from skoolkit.ccmiosimulator import CCMIOSimulator
from skoolkit.pagingtracer import PagingTracer
from zrcp_scr import scr_to_rgb, write_png


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--corrected',action='store_true')
    parser.add_argument('--output-dir',type=Path,default=Path('build/basic-benchmark'))
    args=parser.parse_args()
    args.output_dir.mkdir(parents=True,exist_ok=True)
    lines=GRAPH_LINES if args.corrected else [(n,s.replace('M(X1+1)','M(X1)')) for n,s in GRAPH_LINES]
    data=program([(5,'LET Q=USR 32768')]+lines+[(100,'LET Q=USR 32769')])
    tap=args.output_dir/'graph.tap'; tap.write_bytes(tape(data))
    seed=args.output_dir/'start.z80'
    subprocess.run([str(Path(sys.executable).parent/'tap2sna.py'),'-c','cmio=1',
                    '--start','32768',str(tap),str(seed)],check=True)
    snapshot=Snapshot.get(str(seed)); sim=from_snapshot(CCMIOSimulator,snapshot)
    tracer=PagingTracer();tracer.simulator=sim;tracer.out7ffd=snapshot.out7ffd
    tracer.outfffd=0;tracer.ay=[0]*16;tracer.border=0;tracer.outfe=0
    sim.set_tracer(tracer)
    sim.memory[32768]=201;sim.memory[32769]=201  # RET at the start/end probes
    start=sim.registers[25]
    while sim.registers[24] not in (8,32769):
        sim.run(interrupts=True)
        if sim.registers[25]-start > 3500000*900:
            raise RuntimeError('Graph did not finish within 900 simulated seconds')
    elapsed=sim.registers[25]-start
    completed=sim.registers[24]==32769
    result={'machine':'48K','corrected':args.corrected,'completed':completed,
            'tstates':elapsed,'seconds':elapsed/3500000,
            'timing':'Includes DIM/setup, excludes tape loading; real ROM with contention'}
    if completed:
        result.update(candidate_evaluations=1363,evaluations_per_second=1363*3500000/elapsed)
    else:
        result['error_line']=sim.memory[23621]+256*sim.memory[23622]
    (args.output_dir/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    write_png(str(args.output_dir/'graph.png'),scr_to_rgb(bytes(sim.memory[a] for a in range(0x4000,0x5B00))))
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    main()
