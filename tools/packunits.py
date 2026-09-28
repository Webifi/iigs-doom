#!/usr/bin/env python3
"""Pack data/music/*.mus into the music bank the disks already load.

The units are the converted songs: stream, pitch tables and DOC samples.
No SoundFont. An absent name, including D_INTROA, stays a zero-size slot.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import musbank


def pack(unit_dir, out_path):
    names = musbank.SONGS
    bank = bytearray(struct.pack('<H', len(names)) + bytes(8 * len(names)))
    intro = False
    for i, name in enumerate(names):
        path = os.path.join(unit_dir, name + '.mus')
        if not os.path.exists(path):
            continue
        img = open(path, 'rb').read()
        if not img:
            raise SystemExit('%s is empty' % path)
        if name == 'D_INTRO':
            intro = True
        struct.pack_into('<II', bank, 2 + 8 * i, len(bank), len(img))
        bank += img
    if not intro:
        raise SystemExit('D_INTRO.mus is required')
    open(out_path, 'wb').write(bank)
    print('%s: %d bytes' % (out_path, len(bank)))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: packunits.py UNIT_DIR OUT.bin')
    pack(sys.argv[1], sys.argv[2])
