#!/usr/bin/env python3
"""Extract loader song units from either music builder's common bank format."""
import pathlib
import struct
import sys

def extract(bankpath, out):
    bank = pathlib.Path(bankpath).read_bytes()
    count, = struct.unpack_from('<H', bank)
    names = [f'D_E1M{i}' for i in range(1, 10)] + ['D_INTER', 'D_INTRO', 'D_VICTOR', 'D_INTROA']
    if count != len(names):
        raise ValueError('unsupported music bank')
    out = pathlib.Path(out)
    out.mkdir(parents=True, exist_ok=True)
    for i, name in enumerate(names):
        off, size = struct.unpack_from('<II', bank, 2 + 8*i)
        if size:
            unit = bank[off:off+size]
            if len(unit) != size:
                raise ValueError(f'{name}: truncated unit')
            (out / (name + '.mus')).write_bytes(unit)
    if not (out / 'D_INTRO.mus').exists():
        raise ValueError('D_INTRO is required for the boot title')

if __name__ == '__main__':
    extract(*sys.argv[1:])
