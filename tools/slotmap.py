#!/usr/bin/env python3
"""slotmap.py ZIPPROF.bin DOOM.elf DOOM.lst [CACHE]: the cache slot map of a
model run (tests/zipbench.lua of the gsdoom research tree).

The ZipGS cache is direct mapped with 1-byte lines: the slot of a byte is
its address & (CACHE - 1), CACHE = 32768 by default, and only banks $00-$6F
are cached. For each 256-byte slot range this prints the hot code (by object
file and routine: time of its instructions) and the hot data (by bank page:
reads) that share it, and the bus reads (misses) there: two hot users of one
slot range push each other out of the cache."""
import bisect
import re
import struct
import sys

UNIT_CLK, CLK, PAGE_UNIT = 1056, 14318181.8, 16


def elf_syms(path):
    d = open(path, 'rb').read()
    e = '<' if d[5] == 1 else '>'
    shoff, = struct.unpack_from(e + 'I', d, 32)
    shentsize, shnum = struct.unpack_from(e + 'HH', d, 46)
    secs = [struct.unpack_from(e + 'IIIIIIIIII', d, shoff + i * shentsize) for i in range(shnum)]
    out = []
    for s in secs:
        if s[1] != 2:
            continue
        strtab = secs[s[6]]
        for off in range(s[4], s[4] + s[5], 16):
            nm, val = struct.unpack_from(e + 'II', d, off)
            start = strtab[4] + nm
            name = d[start:d.index(b'\0', start)].decode()
            if name and not name.startswith('.'):
                out.append((val, name))
    out.sort()
    return out


def lst_files(path):
    lst = open(path).read()
    r = []
    for m in re.finditer(r"^(\S+) in section '(\w+)'\s+placed at address (\w+)-(\w+)[^\n]*\n\((\S+)", lst, re.M):
        r.append((int(m.group(3), 16), int(m.group(4), 16), m.group(5).split('/')[-1]))
    r.sort()
    return r


def main():
    prof, elf, lst = sys.argv[1:4]
    cache = int(sys.argv[4]) if len(sys.argv) > 4 else 32768
    d = open(prof, 'rb').read()
    syms = elf_syms(elf)
    sa = [s[0] for s in syms]
    files = lst_files(lst)
    fa = [f[0] for f in files]

    def owner(addr):
        i = bisect.bisect_right(fa, addr) - 1
        f = files[i][2] if i >= 0 and files[i][0] <= addr <= files[i][1] else '?'
        j = bisect.bisect_right(sa, addr) - 1
        s = syms[j][1] if j >= 0 and (syms[j][0] >> 16) == (addr >> 16) else '?'
        return f, s

    slots = {}          # slot range (256 bytes) -> {user: [heat, bus]}
    # code: 16-byte blocks in banks $00-$05
    for p in range(0x6000):
        st, br, tm = struct.unpack_from('<3Q', d, 0x200100 + p * 24)
        if not tm:
            continue
        addr = p << 4
        f, s = owner(addr)
        key = 'code %s %s' % (f, s)
        u = slots.setdefault((addr & (cache - 1)) >> 8, {}).setdefault(key, [0, 0])
        u[0] += tm / PAGE_UNIT / CLK
        u[1] += br
    # data: 256-byte pages of the cached banks
    for p in range(0x7000):
        r, br, w, st = struct.unpack_from('<4Q', d, 0x100 + p * 32)
        if not (r or w):
            continue
        addr = p << 8
        if (addr >> 16) >= 3 and (addr >> 16) <= 5:
            continue                     # (the code reads of the code banks)
        key = 'data $%02X/%02X00' % (p >> 8, p & 0xff)
        u = slots.setdefault((addr & (cache - 1)) >> 8, {}).setdefault(key, [0, 0])
        u[0] += r
        u[1] += br
    # the ranges with the most bus reads, their users
    tot = {k: sum(u[1] for u in v.values()) for k, v in slots.items()}
    print('slot ranges of %d bytes by bus reads (misses); users: code (s of its time),'
          ' data (reads)' % 256)
    for k in sorted(tot, key=lambda k: -tot[k])[:int(sys.argv[5]) if len(sys.argv) > 5 else 40]:
        users = sorted(slots[k].items(), key=lambda kv: -kv[1][1])[:6]
        desc = '; '.join('%s %s/%d' % (n, ('%.1fs' % u[0]) if n.startswith('code') else '%d' % u[0], u[1])
                         for n, u in users)
        print('  $%04X  bus %9d  %s' % (k << 8, tot[k], desc))


if __name__ == '__main__':
    main()
