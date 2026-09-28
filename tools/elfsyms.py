#!/usr/bin/env python3
"""List data symbols of ELF32 object files by section with sizes."""
import struct
import sys


def syms(path):
    d = open(path, 'rb').read()
    e = '<' if d[5] == 1 else '>'
    shoff, = struct.unpack_from(e + 'I', d, 32)
    shentsize, shnum, shstrndx = struct.unpack_from(e + 'HHH', d, 46)
    sh = []
    for i in range(shnum):
        sh.append(struct.unpack_from(e + 'IIIIIIIIII', d, shoff + i * shentsize))
    shstr = sh[shstrndx]

    def name(tab, off):
        s = tab[4] + off
        return d[s:d.index(b'\0', s)].decode()
    out = []
    for s in sh:
        if s[1] == 2:  # SYMTAB
            strtab = sh[s[6]]
            for j in range(s[5] // 16):
                st_name, st_value, st_size, st_info, st_other, st_shndx = \
                    struct.unpack_from(e + 'IIIBBH', d, s[4] + j * 16)
                if st_size and 0 < st_shndx < len(sh):
                    out.append((st_size, name(shstr, sh[st_shndx][0]), name(strtab, st_name)))
    return out


rows = []
for p in sys.argv[1:]:
    for size, sec, nm in syms(p):
        rows.append((size, sec, nm, p.rsplit('/', 1)[-1]))
tot = {}
for size, sec, nm, f in rows:
    tot[sec] = tot.get(sec, 0) + size
print({k: v for k, v in tot.items() if k != 'farcode'})
for size, sec, nm, f in sorted(rows, reverse=True):
    if sec in ('near', 'znear', 'cnear', 'switch'):
        print(f'{size:6d} {sec:6s} {nm} ({f})')
