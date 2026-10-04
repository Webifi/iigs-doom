#!/usr/bin/env python3
"""Write sine.bin: finesine(x) then finecosine(x) for x =
0..8191, as 32-bit little endian values (64 KB). Used by finesine and
finecosine in src/iigs/tables65.s.

The values are 65536 * sin((i + 0.5) * 2 pi / 8192) with the fraction cut
off, except where the tables of Doom have another value (the entries of
SINE and COSINE; finecosine(x) is finesine(x + 2048) of Doom's table).

Usage: gensine.py OUT.bin
"""
import math
import struct
import sys

SINE = {
    455: 22433, 1080: 48305, 2268: 64600, 3212: 41088, 3324: 36556, 3640: 22433,
    3822: 13646, 4147: -2588, 4551: -22433, 4959: -40299, 5174: -48236, 6722: -59189,
    7111: -48305, 7140: -47307, 7170: -46251, 7328: -40299, 7396: -37550, 7420: -36556,
    7947: -12217, 8077: -5747, 8140: -2588,
}
COSINE = {
    220: 64600, 1164: 41088, 1276: 36556, 1592: 22433, 1774: 13646, 2099: -2588,
    2503: -22433, 2911: -40299, 3126: -48236, 4674: -59189, 5063: -48305, 5092: -47307,
    5122: -46251, 5280: -40299, 5348: -37550, 5372: -36556, 5899: -12217, 6029: -5747,
    6092: -2588, 6214: 3542, 6258: 5747, 6773: 30427, 6775: 30516, 6915: 36556,
    7007: 40299, 7211: 47861, 7224: 48305, 7277: 50064, 7403: 53912, 7417: 54309,
    7971: 64600,
}


def fine(i):
    return int(65536 * math.sin((i + 0.5) * 2 * math.pi / 8192))


def main():
    data = bytearray()
    for x in range(8192):
        data += struct.pack('<i', SINE.get(x, fine(x)))
    for x in range(8192):
        data += struct.pack('<i', COSINE.get(x, fine(x + 2048)))
    open(sys.argv[1], 'wb').write(data)


if __name__ == '__main__':
    main()
