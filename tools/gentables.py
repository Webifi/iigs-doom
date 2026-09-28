#!/usr/bin/env python3
"""Generate lookup tables for the 65816 math code.

recip.bin: 32768 x 16 bits, entry i = floor((2^31 - 1) / (32768 + i)).
           Used by FixedReciprocal in src/iigs/m_recip65.s.

phase.bin: SCALER_MAXS + 1 blocks of 256 bytes. Entry f of block S is the
           row k (0..SCALER_PHASEROWS - 1) of the scaler for step S whose
           fraction (k * S) & 255 is the largest one <= f, or 0xff when
           that fraction is more than 1/8 texel below f (the column is
           drawn by the exact stepping drawer then). When S is a multiple
           of 64, every fraction k * S is a multiple of 64 and a start row
           less than 64 below f gives the texels of the stepping drawer,
           so there is no limit. Used by the compiled scalers in
           src/iigs/scaler65.s.

log.bin:   32768 x 16 bits, entry n = round(log2(n) * 2048) for n = 1..32767
           and entry 0 = log2(32768) * 2048 (an index of 2 * 32768 wraps to
           0; 0 itself is never looked up). Used to compare products in
           src/iigs/p_sight65.s.

Usage: gentables.py OUTDIR
"""
import math
import os
import struct
import sys

SCALER_MAXS = 511       # steps 1..511 (8.8 texels per row)
SCALER_PHASEROWS = 52   # rows 0..51 can start a column


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    data = bytearray()
    for i in range(32768):
        data += struct.pack('<H', ((1 << 31) - 1) // (32768 + i))
    open(os.path.join(out, 'recip.bin'), 'wb').write(data)

    phase = bytearray()
    for step in range(SCALER_MAXS + 1):
        best = {}
        for k in range(SCALER_PHASEROWS):
            best.setdefault((k * step) & 255, k)
        fracs = sorted(best)
        table = bytearray(256)
        j = 0
        for f in range(256):
            while j + 1 < len(fracs) and fracs[j + 1] <= f:
                j += 1
            near = f - fracs[j] <= 32 or step % 64 == 0
            table[f] = best[fracs[j]] if near else 0xff
        phase += table
    open(os.path.join(out, 'phase.bin'), 'wb').write(phase)

    logs = bytearray(struct.pack('<H', 15 * 2048))
    for n in range(1, 32768):
        logs += struct.pack('<H', round(math.log2(n) * 2048))
    open(os.path.join(out, 'log.bin'), 'wb').write(logs)


if __name__ == '__main__':
    main()
