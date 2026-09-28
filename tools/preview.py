#!/usr/bin/env python3
"""Render an SHR picture lump (see tools/gscolor.py) to a PNG, 640x400.

Usage: preview.py WADFILE LUMPNAME OUT.png
"""
import struct
import sys
import zlib

sys.path.insert(0, __file__.rsplit('/', 1)[0])
import wadtool


def write_png(path, w, h, rows):
    raw = b''.join(b'\0' + bytes(r) for r in rows)

    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    open(path, 'wb').write(png)


def main():
    wad = wadtool.Wad(sys.argv[1])
    rec = wad.get(sys.argv[2])
    pixels, scb = rec[:32000], rec[32000:32200]
    pals = [[struct.unpack_from('<H', rec, 32200 + (p * 16 + i) * 2)[0] for i in range(16)] for p in range(16)]
    rows = []
    for y in range(200):
        pal = pals[scb[y]]
        row = []
        for x in range(320):
            b = pixels[y * 160 + x // 2]
            n = b >> 4 if x % 2 == 0 else b & 15
            c = pal[n]
            rgb = (((c >> 8) & 15) * 17, ((c >> 4) & 15) * 17, (c & 15) * 17)
            row += rgb * 2
        rows.append(row)
        rows.append(row)
    write_png(sys.argv[3], 640, 400, rows)


if __name__ == '__main__':
    main()
