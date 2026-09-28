#!/usr/bin/env python3
"""Render an SHR memory dump ($E1:2000-$E1:9FFF) to a 640x400 PNG.
Usage: shrpng.py DUMP.bin OUT.png"""
import struct
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from preview import write_png

d = open(sys.argv[1], 'rb').read()
pixels, scb, pal = d[:32000], d[0x7d00:0x7dc8], d[0x7e00:0x8000]
rows = []
for y in range(200):
    p = scb[y] & 15
    row = []
    for x in range(320):
        b = pixels[y * 160 + x // 2]
        n = b >> 4 if x % 2 == 0 else b & 15
        c = struct.unpack_from('<H', pal, (p * 16 + n) * 2)[0]
        row += [((c >> 8) & 15) * 17, ((c >> 4) & 15) * 17, (c & 15) * 17] * 2
    rows += [row, row]
write_png(sys.argv[2], 640, 400, rows)
