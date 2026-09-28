#!/usr/bin/env python3
"""Compare back buffer dumps build/tic_N.bin with REF/tic_N.bin (REF: the
first argument, default build/ref). Prints the differing bytes in the view
and in the status bar for each tic."""
import glob
import os
import sys

ref = sys.argv[1] if len(sys.argv) > 1 else 'build/ref'
for path in sorted(glob.glob(ref + '/tic_*.bin'), key=lambda p: int(p.split('_')[-1][:-4])):
    new = 'build/' + os.path.basename(path)
    if not os.path.exists(new):
        print(os.path.basename(path), 'missing')
        continue
    a, b = open(path, 'rb').read(), open(new, 'rb').read()
    view = sum(1 for i in range(168 * 160) if a[i] != b[i])
    status = sum(1 for i in range(168 * 160, 200 * 160) if a[i] != b[i])
    print(f'{os.path.basename(path):12} view {view:5} bytes differ, status bar {status:5}')
