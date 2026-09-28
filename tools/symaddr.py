#!/usr/bin/env python3
"""symaddr.py ELF NAME...: the address of each symbol (hex, one line each,
in the order of the names; empty if not found). The link listing shows only
the first symbol of an assembly data block, so the scripts read the ELF."""
import struct
import sys

data = open(sys.argv[1], 'rb').read()
end = '<' if data[5] == 1 else '>'
shoff, = struct.unpack_from(end + 'I', data, 32)
shentsize, shnum = struct.unpack_from(end + 'HH', data, 46)
sections = [struct.unpack_from(end + 'IIIIIIIIII', data, shoff + i * shentsize)
            for i in range(shnum)]
found = {}
for sec in sections:
    if sec[1] != 2:                     # SHT_SYMTAB
        continue
    strtab = sections[sec[6]]
    for off in range(sec[4], sec[4] + sec[5], 16):
        name, value = struct.unpack_from(end + 'II', data, off)
        start = strtab[4] + name
        found.setdefault(data[start:data.index(b'\0', start)].decode(), value)
for name in sys.argv[2:]:
    print('%06x' % found[name] if name in found else '')
