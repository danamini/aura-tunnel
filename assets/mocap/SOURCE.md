# Running capture

CMU Graphics Lab Motion Capture Database, subject 09, clip 01 (`run`).
Source: https://mocap.cs.cmu.edu/
BVH conversion by Bruce Hahne (2010), mirrored at:
https://github.com/una-dinosauria/cmu-mocap/blob/master/data/009/09_01.bvh

`READMEFIRST.txt` is the conversion's original documentation and includes its
usage rights. The data and conversion may be reused without additional restrictions.

The data used in this project was obtained from mocap.cs.cmu.edu.
The database was created with funding from NSF EIA-0196217.

`tools/mocap_runner.py` computes world-space joints from the BVH hierarchy,
removes horizontal travel, chooses a matching full stride, and projects it into
2D. The build samples 12 hero poses and 8 smaller poses. Only the resulting byte
coordinates are included in the Spectrum binaries; no BVH parsing runs there.
