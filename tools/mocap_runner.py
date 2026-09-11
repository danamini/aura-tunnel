"""Bake CMU 09_01 running joints; standard-library BVH forward kinematics.

The source file and conversion's reuse terms are in assets/mocap.
All transformations happen at build time; the Z80 reads byte coordinates.
"""
import math
from functools import lru_cache
from pathlib import Path


def matmul(a, b):
    return [[sum(a[i][k]*b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def rotate(axis, angle):
    c, s = math.cos(math.radians(angle)), math.sin(math.radians(angle))
    if axis == 'X': return [[1,0,0],[0,c,-s],[0,s,c]]
    if axis == 'Y': return [[c,0,s],[0,1,0],[-s,0,c]]
    return [[c,-s,0],[s,c,0],[0,0,1]]


def load_bvh(path):
    hierarchy, motion = Path(path).read_text().split('MOTION')
    tokens = iter(hierarchy.split())
    assert next(tokens) == 'HIERARCHY'
    nodes = []
    def node(parent, kind):
        name = next(tokens)
        if kind == 'End': name = nodes[parent]['name'] + 'End'
        idx = len(nodes)
        n = dict(name=name, parent=parent, channels=[])
        nodes.append(n)
        assert next(tokens) == '{'
        while (token := next(tokens)) != '}':
            if token == 'OFFSET': n['offset'] = [float(next(tokens)) for _ in range(3)]
            elif token == 'CHANNELS': n['channels'] = [next(tokens) for _ in range(int(next(tokens)))]
            elif token in ('JOINT', 'End'): node(idx, token)
            else: raise ValueError(token)
    assert next(tokens) == 'ROOT'
    node(None,'ROOT')
    lines = motion.strip().splitlines()
    frames = [[float(x) for x in line.split()] for line in lines[2:]]
    assert len(frames) == int(lines[0].split()[-1])
    poses = []
    for frame in frames:
        values = iter(frame); worlds=[]; points={}
        for n in nodes:
            local = [[1,0,0],[0,1,0],[0,0,1]]
            pos = list(n['offset'])
            for channel in n['channels']:
                value=next(values)
                if channel.endswith('position'): pos['XYZ'.index(channel[0])] += value
                else: local = matmul(local,rotate(channel[0],value))
            if n['parent'] is not None:
                rot, origin = worlds[n['parent']]
                pos = [origin[i]+sum(rot[i][k]*pos[k] for k in range(3)) for i in range(3)]
                local = matmul(rot,local)
            worlds.append((local,pos));points[n['name']]=pos
        poses.append(points)
    return poses


@lru_cache(maxsize=1)
def cycle():
    poses = load_bvh(Path(__file__).resolve().parents[1]/'assets/mocap/09_01.bvh')
    # Remove travel while retaining captured vertical bounce. Project along
    # the direction of travel, with a small lateral component to reveal limbs.
    dx=poses[-1]['Hips'][0]-poses[1]['Hips'][0]
    dz=poses[-1]['Hips'][2]-poses[1]['Hips'][2]
    length=math.hypot(dx,dz); dx/=length;dz/=length
    flat=[]
    for pose in poses:
        root=pose['Hips']
        flat.append({name: ((p[0]-root[0])*dx+(p[2]-root[2])*dz+
                            0.35*((p[0]-root[0])*dz-(p[2]-root[2])*dx),p[1])
                     for name,p in pose.items()})
    # Choose the closest matching complete stride, excluding the added T pose.
    keys=['LeftFoot','RightFoot','LeftHand','RightHand','LeftLeg','RightLeg']
    best=min((sum((flat[start][k][a]-flat[start+period][k][a])**2
                  for k in keys for a in (0,1)),start,period)
             for start in range(2,45) for period in range(60,96)
             if start+period<len(flat))
    _,start,period=best
    selected=flat[start:start+period]
    top=max(p['HeadEnd'][1] for p in selected)
    ground=min(p[k][1] for p in selected for k in ('LeftToeBase','RightToeBase','LeftFoot','RightFoot'))
    scale=124/(top-ground)
    return selected,scale,top,start,period


def run_pose(c, dense=False):
    poses,scale,top,_,_=cycle()
    f=(c%1)*len(poses); i=int(f); t=f-i
    points={name: (52+(v[0]*(1-t)+poses[(i+1)%len(poses)][name][0]*t)*scale,
                   8+(top-v[1]*(1-t)-poses[(i+1)%len(poses)][name][1]*t)*scale)
            for name,v in poses[i].items()}
    result=[]
    def line(a,b,n):
        for j in range(1,n+1): result.append(tuple(a[k]+(b[k]-a[k])*j/n for k in (0,1)))
    head=points['Head'];tip=points['HeadEnd']
    center=tuple((a+b)/2 for a,b in zip(head,tip))
    for j in range(8 if dense else 4):
        a=j*2*math.pi/(8 if dense else 4)
        result.append((center[0]+5*math.sin(a),center[1]+6*math.cos(a)))
    line(points['Neck1'],points['Hips'],6 if dense else 2)
    line(points['LeftArm'],points['RightArm'],4 if dense else 2)
    line(points['LeftUpLeg'],points['RightUpLeg'],4 if dense else 2)
    for side in ('Left','Right'):
        for a,b in (('UpLeg','Leg'),('Leg','Foot')):
            line(points[side+a],points[side+b],5 if dense else 2)
        result.append(points[side+'ToeBase'])
        for a,b in (('Arm','ForeArm'),('ForeArm','Hand')):
            line(points[side+a],points[side+b],5 if dense else 2)
    return result


if __name__ == '__main__':
    p,s,t,start,length=cycle()
    print(f'CMU 09_01: frames {start}..{start+length}, {length/120:.3f}s stride, scale {s:.3f}')
