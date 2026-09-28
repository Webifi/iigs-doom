#!/usr/bin/env python3
"""Convert DOOM1.WAD for the Apple IIgs build of Doom8088.

This follows the map and texture conversion of jWadUtil
(https://github.com/FrenkelS/jWadUtil), but keeps full resolution
wall patches and sprites, and adds the IIgs color data:

  GSPAL      5 gamma levels x 14 palettes x 16 SHR colors (little endian $0RGB)
  gspairA.bin / gspairB.bin
             64 KB tables: index = left doom color | right doom color << 8,
             value = SHR byte (two 4-bit pixels). B is used on odd rows.

Usage: wadtool.py DOOM1.WAD OUTDIR [--flat-span]
"""

import argparse
import hashlib
import os
import struct
import sys

import gscolor
import levelimg
import levelset
import sgrid


# --------------------------------------------------------------------------
# WAD file

WAD_SPACE = 0x700000 - 0x400000   # the WAD image in RAM (MM_WAD of src/iigs/memmap.inc)


class Wad:
    def __init__(self, path):
        d = open(path, 'rb').read()
        ident, n, ofs = struct.unpack_from('<4sii', d, 0)
        if ident not in (b'IWAD', b'PWAD'):
            sys.exit(f'{path}: not a WAD file')
        self.lumps = []
        for i in range(n):
            fp, sz, nm = struct.unpack_from('<ii8s', d, ofs + 16 * i)
            self.lumps.append([nm.rstrip(b'\0').decode('ascii').upper(), d[fp:fp + sz]])

    def index(self, name):
        found = [i for i, l in enumerate(self.lumps) if l[0] == name]
        if len(found) != 1:
            raise KeyError(f'{len(found)} lumps named {name}')
        return found[0]

    def get(self, name):
        return self.lumps[self.index(name)][1]

    def set(self, name, data):
        self.lumps[self.index(name)][1] = data

    def add(self, name, data):
        self.lumps.append([name, data])

    def remove(self, name):
        """Remove the first lump with this name (DOOM1.WAD has two SW18_7)."""
        for i, l in enumerate(self.lumps):
            if l[0] == name:
                del self.lumps[i]
                return
        raise KeyError(f'no lump named {name}')

    def remove_prefix(self, prefix):
        self.lumps = [l for l in self.lumps if not l[0].startswith(prefix)]

    def between(self, start, end):
        return list(range(self.index(start) + 1, self.index(end)))

    def save(self, path):
        """Write the WAD with 16-bit lump sizes. Identical lumps are stored
        once. The IIgs uses lumps in place in RAM with 16-bit pointer
        arithmetic, so no lump may cross a 64 KB bank: lumps are placed
        first-fit into the free space of the banks."""
        header = 12 + len(self.lumps) * 16
        image = bytearray(header)
        free = []                     # (start, end) gaps inside banks
        seen = {}
        positions = []
        merged = 0

        def place(data):
            size = len(data)
            for i, (a, b) in enumerate(free):
                if b - a >= size:
                    image[a:a + size] = data
                    free[i] = (a + size, b)
                    return a
            pos = len(image)
            if (pos & 0xffff) + size > 0x10000:
                gap_end = (pos | 0xffff) + 1
                free.append((pos, gap_end))
                image.extend(bytes(gap_end - pos))
                pos = gap_end
            image.extend(data)
            return pos

        for name, data in self.lumps:
            if len(data) > 0xffff:
                sys.exit(f'lump {name} is {len(data)} bytes, more than 65535')
            if len(data) == 0:
                positions.append(0)
            elif data in seen:
                positions.append(seen[data])
                merged += 1
            else:
                pos = place(data)
                seen[data] = pos
                positions.append(pos)

        directory = bytearray()
        for (name, data), pos in zip(self.lumps, positions):
            directory += struct.pack('<IHH8s', pos, len(data), 0, name.encode('ascii'))
        image[0:12] = struct.pack('<4shhi', b'IWAD', len(self.lumps), 0, 12)
        image[12:header] = directory
        if len(image) > WAD_SPACE:
            sys.exit(f'{path}: {len(image)} bytes, more than the {WAD_SPACE} of its banks '
                     '(src/iigs/memmap.inc)')
        open(path, 'wb').write(image)
        wasted = sum(b - a for a, b in free)
        print(f'{path}: {len(self.lumps)} lumps, {merged} merged, {len(image)} bytes, {wasted} unused')


def name8(b):
    return b.split(b'\0', 1)[0].decode('ascii').upper()


# --------------------------------------------------------------------------
# Textures

def process_texture1(wad):
    old = wad.get('TEXTURE1')
    n = struct.unpack_from('<i', old, 0)[0]
    offsets = struct.unpack_from(f'<{n}i', old, 4)
    out = bytearray(struct.pack('<i', n) + b'\xff\xff\xff\xff' * n)
    newofs = []
    for off in offsets:
        nm = old[off:off + 8]
        _masked, width, height, _coldir, patchcount = struct.unpack_from('<ihhih', old, off + 8)
        newofs.append(len(out))
        out += nm + struct.pack('<hhh', width, height, patchcount)
        p = off + 22
        for _ in range(patchcount):
            ox, oy, patch, _stepdir, _cmap = struct.unpack_from('<hhhhh', old, p)
            out += struct.pack('<hhh', ox, oy, patch)
            p += 10
    struct.pack_into(f'<{n}i', out, 4, *newofs)
    wad.set('TEXTURE1', bytes(out))


def texture_names(wad):
    d = wad.get('TEXTURE1')
    n = struct.unpack_from('<i', d, 0)[0]
    offsets = struct.unpack_from(f'<{n}i', d, 4)
    return [name8(d[o:o + 8]) for o in offsets]


def process_pnames(wad):
    d = bytearray(wad.get('PNAMES'))
    for i in range(4, len(d)):
        if ord('a') <= d[i] <= ord('z'):
            d[i] &= 0xdf
    wad.set('PNAMES', bytes(d))


# --------------------------------------------------------------------------
# Maps

ML_THINGS, ML_LINEDEFS, ML_SIDEDEFS, ML_VERTEXES, ML_SEGS = 1, 2, 3, 4, 5
ML_SSECTORS, ML_NODES, ML_SECTORS, ML_BLOCKMAP = 6, 7, 8, 10
NO_INDEX = 0xffff
ML_TWOSIDED = 4
MTF_NOTSINGLE = 16
SKY = -2
MAX_FLATS = 32                          # FLATCM of src/iigs/r_bsp65.s


def s8(v):
    v &= 0xff
    return v - 256 if v >= 128 else v


class MapProcessor:
    def __init__(self, wad, flat_span, flat_lists):
        self.wad = wad
        self.flat_span = flat_span
        self.flat_lists = flat_lists
        self.grids = {}

    def lump(self, base, off):
        return self.wad.lumps[base + off][1]

    def put(self, base, off, data):
        self.wad.lumps[base + off][1] = bytes(data)

    def process(self):
        for m in range(1, 10):
            base = self.wad.index(f'E1M{m}')
            self.flats = self.flat_lists.get(m)
            self.things(base)
            self.linedefs(base)
            self.sidedefs(base)
            self.pack_sidedefs(base)
            self.segs(base)
            self.ssectors(base)
            self.sectors(base)
            self.blockmap(base)
            self.sgrid(base, m)

    def things(self, base):
        d = self.lump(base, ML_THINGS)
        out = bytearray()
        for i in range(len(d) // 10):
            x, y, angle, typ, options = struct.unpack_from('<hhhhh', d, i * 10)
            if typ in (2, 3, 4, 11) or options & MTF_NOTSINGLE:
                continue
            out += struct.pack('<hhhbb', x, y, typ, s8(angle // 45), s8(options))
        self.put(base, ML_THINGS, out)

    def vertexes(self, base):
        d = self.lump(base, ML_VERTEXES)
        return [struct.unpack_from('<hh', d, i * 4) for i in range(len(d) // 4)]

    def linedefs(self, base):
        d = self.lump(base, ML_LINEDEFS)
        vx = self.vertexes(base)
        out = bytearray()
        for i in range(len(d) // 14):
            v1, v2, flags, special, tag, s0, s1 = struct.unpack_from('<HHhhhHH', d, i * 14)
            out += struct.pack('<hhhhHHbbb', *vx[v1], *vx[v2], s0, s1, s8(flags), s8(special), s8(tag))
        self.put(base, ML_LINEDEFS, out)

    def read_lines(self, base):
        d = self.lump(base, ML_LINEDEFS)
        return [list(struct.unpack_from('<hhhhHHbbb', d, i * 15)) for i in range(len(d) // 15)]

    def read_sides(self, base):
        d = self.lump(base, ML_SIDEDEFS)
        return [struct.unpack_from('<hbbbbb', d, i * 7) for i in range(len(d) // 7)]

    def sidedefs(self, base):
        d = self.lump(base, ML_SIDEDEFS)
        names = texture_names(self.wad)

        def texnum(raw):
            n = name8(raw)
            return s8(names.index(n)) if n in names else 0

        out = bytearray()
        for i in range(len(d) // 30):
            toff, roff = struct.unpack_from('<hh', d, i * 30)
            top = d[i * 30 + 4:i * 30 + 12]
            bot = d[i * 30 + 12:i * 30 + 20]
            mid = d[i * 30 + 20:i * 30 + 28]
            sector = struct.unpack_from('<h', d, i * 30 + 28)[0]
            out += struct.pack('<hbbbbb', toff, s8(roff), texnum(top), texnum(bot), texnum(mid), s8(sector))
        self.put(base, ML_SIDEDEFS, out)

    def pack_sidedefs(self, base):
        lines = self.read_lines(base)
        sides = self.read_sides(base)
        newsides = []
        keys = {}

        def add(side, special):
            if special:
                newsides.append((side, True))
                return len(newsides) - 1
            key = (side, False)
            if key not in keys:
                newsides.append(key)
                keys[key] = len(newsides) - 1
            return keys[key]

        for ln in lines:
            front = sides[ln[4]]
            back = sides[ln[5]] if ln[5] != NO_INDEX else None
            special = ln[7] != 0
            ln[4] = add(front, special)
            ln[5] = add(back, special) if back is not None else NO_INDEX
        self.put(base, ML_LINEDEFS, b''.join(struct.pack('<hhhhHHbbb', *ln) for ln in lines))
        self.put(base, ML_SIDEDEFS, b''.join(struct.pack('<hbbbbb', *s[0]) for s in newsides))

    def segs(self, base):
        d = self.lump(base, ML_SEGS)
        vx = self.vertexes(base)
        lines = self.read_lines(base)
        sides = self.read_sides(base)
        out = bytearray()
        for i in range(len(d) // 12):
            v1, v2, angle, linedef, side, offset = struct.unpack_from('<HHhHhh', d, i * 12)
            ln = lines[linedef]
            sidenum = ln[4 + side]
            front = sides[sidenum][5]
            back = -1
            if ln[6] & ML_TWOSIDED:
                other = ln[4 + (side ^ 1)]
                if other != NO_INDEX:
                    back = sides[other][5]
            out += struct.pack('<hhhhhHHHbb', *vx[v1], *vx[v2], offset,
                               (angle + 0x4000) & 0xffff, sidenum, linedef, s8(front), s8(back))
        self.put(base, ML_SEGS, out)

    def ssectors(self, base):
        d = self.lump(base, ML_SSECTORS)
        out = bytearray()
        derived = 0
        for i in range(len(d) // 4):
            numsegs, firstseg = struct.unpack_from('<hh', d, i * 4)
            if firstseg != derived:
                sys.exit(f'subsector {i}: segs are not in order')
            derived += numsegs
            out.append(numsegs & 0xff)
        self.put(base, ML_SSECTORS, out)

    def sectors(self, base):
        d = self.lump(base, ML_SECTORS)
        out = bytearray()
        for i in range(len(d) // 26):
            fh, ch = struct.unpack_from('<hh', d, i * 26)
            fpic = d[i * 26 + 4:i * 26 + 12]
            cpic = d[i * 26 + 12:i * 26 + 20]
            light, special, tag = struct.unpack_from('<hhh', d, i * 26 + 20)
            out += struct.pack('<hh', fh, ch)
            if self.flat_span:
                out += struct.pack('<hh', self.flat_number(fpic), self.flat_number(cpic))
            else:
                out += fpic + cpic
            out += struct.pack('<bbh', s8(light), s8(special), tag)
        self.put(base, ML_SECTORS, out)

    def flat_number(self, pic):
        """The number of a flat in the sector data: its place in the flat
        list of the map (GSFLATn: its color; NUKAGE1-3 are 0-2), SKY for
        the sky. The game logic compares these numbers (the stairs), so
        each flat has its own."""
        name = name8(pic)
        if name == 'F_SKY1':
            return SKY
        if not self.flats or name not in self.flats:
            sys.exit(f'{name}: not in the flat list of the map (tools/gsview.py)')
        return self.flats.index(name)

    def sgrid(self, base, m):
        """The subsector grid of R_PointInSubsector (tools/sgrid.py) of map
        m, the lump SGRIDm; main adds it last, so no other lump moves."""
        self.grids[f'SGRID{m}'] = sgrid.lump(sgrid.read_nodes(self.lump(base, ML_NODES)),
                                             self.lump(base, ML_BLOCKMAP))

    def blockmap(self, base):
        d = self.lump(base, ML_BLOCKMAP)
        orgx, orgy, w, h = struct.unpack_from('<hhhh', d, 0)
        offsets = list(struct.unpack_from(f'<{w * h}H', d, 8))
        lists = {}
        for i, off in enumerate(offsets):
            p = off * 2 + 2
            lst = []
            while True:
                v = struct.unpack_from('<h', d, p)[0]
                if v == -1:
                    break
                lst.append(v)
                p += 2
            lists[i] = lst
        out = bytearray(struct.pack('<hhhh', orgx, orgy, w, h) + b'\xff\xff' * (w * h))
        stored = []
        order = sorted(lists.items(), key=lambda kv: len(kv[1]))[::-1]
        for i, lst in order:
            offset = None
            for prev, poff in stored:
                if len(prev) >= len(lst) and prev[len(prev) - len(lst):] == lst:
                    offset = poff + (len(prev) - len(lst))
                    break
            if offset is None:
                offset = len(out) // 2
                out += struct.pack('<h', 0)
                for v in lst:
                    out += struct.pack('<h', v)
                out += struct.pack('<h', -1)
                stored.append((lst, offset))
            offsets[i] = offset
        struct.pack_into(f'<{w * h}H', out, 8, *offsets)
        self.put(base, ML_BLOCKMAP, out)


# --------------------------------------------------------------------------
# Pictures

def decode_patch(data, playpal=None):
    w, h, lo, to = struct.unpack_from('<hhhh', data, 0)
    img = [[None] * w for _ in range(h)]
    for x in range(w):
        p = struct.unpack_from('<I', data, 8 + 4 * x)[0]
        while data[p] != 0xff:
            top = data[p]
            length = data[p + 1]
            for y in range(length):
                if 0 <= top + y < h:
                    img[top + y][x] = data[p + 3 + y]
            p += length + 4
    return w, h, img


def raw_scaled(data, dw, dh):
    w, h, img = decode_patch(data)
    out = bytearray(dw * dh)
    for y in range(dh):
        sy = y * h // dh
        for x in range(dw):
            v = img[sy][x * w // dw]
            out[y * dw + x] = v if v is not None else 0
    return bytes(out)


def raw_crop(data, dw, dh):
    w, h, img = decode_patch(data)
    out = bytearray(dw * dh)
    for y in range(min(h, dh)):
        for x in range(min(w, dw)):
            v = img[y][x]
            out[y * dw + x] = v if v is not None else 0
    return bytes(out)


def text_patch(wad, text):
    """Build a patch that spells text with the STCFN font."""
    glyphs = []
    for ch in text:
        if ch == ' ':
            glyphs.append(None)
        else:
            w, h, img = decode_patch(wad.get(f'STCFN{ord(ch):03d}'))
            glyphs.append((w, h, img))
    height = max(g[1] for g in glyphs if g)
    cols = []
    for g in glyphs:
        if g is None:
            cols += [[None] * height] * 4
            continue
        w, h, img = g
        for x in range(w):
            cols.append([img[y][x] if y < h else None for y in range(height)])
    width = len(cols)
    body = bytearray()
    offsets = []
    for col in cols:
        offsets.append(8 + 4 * width + len(body))
        y = 0
        while y < height:
            if col[y] is None:
                y += 1
                continue
            start = y
            while y < height and col[y] is not None:
                y += 1
            body += bytes([start, y - start, 0]) + bytes(col[start:y]) + b'\0'
        body += b'\xff'
    return struct.pack('<hhhh', width, height, 0, 0) + struct.pack(f'<{width}I', *offsets) + bytes(body)


# --------------------------------------------------------------------------
# Lump removal

REMOVED_PREFIXES = [
    'AMMNUM', 'APBX', 'APLS', 'BAL2', 'BOSF', 'BRDR', 'D_', 'DEMO1', 'DEMO2',
    'DPBD', 'DPITMBK', 'DSBD', 'DSITMBK', 'DMXGUS', 'GENMIDI', 'HELP1', 'IFOG',
    'MANF', 'M_DETAIL', 'M_DIS', 'M_EPI', 'M_GD', 'M_LGTTL', 'M_MSENS',
    'M_PAUSE', 'M_RDTHIS', 'M_SCRNSZ', 'M_SGTTL', 'STARMS', 'STCDROM',
    'STCFN121', 'STDISK', 'STFB', 'STKEYS3', 'STKEYS4', 'STKEYS5', 'STPB',
    'STT', 'VERTEXES', 'WIA', 'WIBP', 'WIFRGS', 'WIKILRS', 'WILV1', 'WILV2',
    'WIMINUS', 'WIMSTAR', 'WIOSTF', 'WIOSTS', 'WIP1', 'WIP2', 'WIP3', 'WIP4',
    'WIURH1', 'WIVCTMS',
]


# Status bar graphics of Doom's own layout, kept for the 320x200 layout
KEPT_320 = ['STARMS', 'STT']


def remove_unused(wad, flat_span, layout, keep_demos):
    wad.remove('CREDIT')
    wad.remove('SW18_7')
    for p in REMOVED_PREFIXES:
        if layout == 320 and p in KEPT_320:
            continue
        if keep_demos and p in ('DEMO1', 'DEMO2'):
            continue
        wad.remove_prefix(p)
    if flat_span:
        keep = {'FLOOR4_8'}
        flats = wad.between('F_START', 'F_END')
        names = [wad.lumps[i][0] for i in flats if wad.lumps[i][0] not in keep]
        for n in ['F_START', 'F_END'] + names:
            wad.remove(n)
    wad.remove_prefix('DS')


# --------------------------------------------------------------------------
# IIgs colors, see tools/gscolor.py

def read_playpals(wad):
    d = wad.get('PLAYPAL')
    return [[tuple(d[p * 768 + i * 3:p * 768 + i * 3 + 3]) for i in range(256)] for p in range(14)]


def patch_hist(data, hist, weight=1):
    w = struct.unpack_from('<h', data, 0)[0]
    for x in range(w):
        p = struct.unpack_from('<I', data, 8 + 4 * x)[0]
        while p < len(data) and data[p] != 0xff:
            length = data[p + 1]
            for b in data[p + 3:p + 3 + length]:
                hist[b] += weight
            p += length + 4


STATUS_PALS = 8                         # palettes 1-8 of src/iigs/i_viigs65.s
# Black and the light gray of the labels of the background (BULL, SHEL,
# ROKT, CELL, AMMO ...) in each status palette: without it the labels of
# some rows show pink.
STATUS_FIXED = ((0, 0, 0), (187, 187, 187))


def status_palettes(wad, pals, rounds=6):
    """GSSTAT: the palettes of the 32 status bar rows (research "load and
    audio plan" 11.6). Each row takes one of STATUS_PALS palettes, made
    from the graphics that the game can draw in the row: the background 4
    times, the others 2 or 1 times, in their places of st_stuff.c; not the
    graphics that remove_unused removes (STFB, STKEYS3-5). Free rows, as
    the pictures. The lump: the palette of each row (32 bytes), then a
    palette record for each palette."""
    base = pals[0]
    width, height = 320, 32
    rowhist = [dict() for _ in range(height)]

    def add(name, x, y, weight):
        data = wad.get(name)
        w, h, lo, to = struct.unpack_from('<hhhh', data, 0)
        img = decode_patch(data)[2]
        for yy in range(h):
            for xx in range(w):
                c = img[yy][xx]
                if c is not None and 0 <= x - lo + xx < width and 0 <= y - to + yy < height:
                    row = rowhist[y - to + yy]
                    row[c] = row.get(c, 0) + weight

    add('STBAR', 0, 0, 4)
    add('STARMS', 104, 0, 2)
    for name, data in wad.lumps:
        if data and name.startswith('STF') and not name.startswith('STFB'):
            add(name, 143, 0, 2)
    for d in range(10):
        for right in (44, 90, 221):             # ammo, health, armor
            add(f'STTNUM{d}', right - 14, 3, 2)
        for k in range(6):                      # the weapons owned
            add(f'STYSNUM{d}', 111 + (k % 3) * 12, 4 + (k // 3) * 10, 1)
            add(f'STGNUM{d}', 111 + (k % 3) * 12, 4 + (k // 3) * 10, 1)
        for k in range(4):                      # ammo and its maximum
            add(f'STYSNUM{d}', 280, 5 + 6 * k, 1)
            add(f'STYSNUM{d}', 306, 5 + 6 * k, 1)
    for k in range(3):
        add(f'STKEYS{k}', 239, 3 + 10 * k, 2)
    add('STTPRCNT', 90, 3, 2)
    add('STTPRCNT', 221, 3, 2)

    def usage(rows):
        hist = [0] * 256
        for y in rows:
            for c, n in rowhist[y].items():
                hist[c] += n
        return hist

    def palette_for(rows):
        hist = usage(rows)
        return gscolor.kmeans([(base[i], hist[i]) for i in range(256)], fixed=STATUS_FIXED)

    k = STATUS_PALS
    row_pal = [min(k - 1, y * k // height) for y in range(height)]
    spals = [palette_for([y for y in range(height) if row_pal[y] == p]) for p in range(k)]
    for _ in range(rounds):
        nearest = [[min(gscolor.dist(base[c], q) for q in pal) for pal in spals] for c in range(256)]
        row_pal = [min(range(k), key=lambda p: sum(n * nearest[c][p] for c, n in rowhist[y].items()))
                   for y in range(height)]
        spals = [palette_for([y for y in range(height) if row_pal[y] == p]) if p in row_pal else spals[p]
                 for p in range(k)]
    spals = [gscolor.align8(sp, len(STATUS_FIXED)) for sp in spals]
    rec = bytearray(row_pal)
    for p in range(k):
        rec += gscolor.palette_record(spals[p], pals, usage([y for y in range(height) if row_pal[y] == p]))
    return bytes(rec), spals, row_pal


def overlay_usage(wad, prefixes):
    hist = [0] * 256
    for name, data in wad.lumps:
        if data and name.startswith(prefixes) and len(data) > 8:
            try:
                patch_hist(data, hist)
            except (struct.error, IndexError):
                pass
    return hist


# The palettes of the text in a level (research "load and audio plan"
# 11.7), GSOVL: palette 9 for the paused menu over the view in 5 dark grays
# (MENU_GRAYS first: src/iigs/i_viigs65.s remaps the view to them), 10 for
# the message strip (black and the font), 11 for the full automap (black,
# the line colors of am_map.c, the font of the map name).
MENU_GRAYS = ((0, 0, 0), (17, 17, 17), (34, 34, 34), (51, 51, 51), (68, 68, 68))
AUTOMAP_COLORS = (23, 55, 215, 208, 175, 204, 231, 119, 252, 104)


def overlay_palettes(wad, pals):
    base = pals[0]
    font = overlay_usage(wad, ('STCFN',))
    menu = [a + b for a, b in zip(overlay_usage(wad, ('M_',)), font)]
    lines = [0] * 256
    for c in AUTOMAP_COLORS:
        lines[c] = 1
    automap = [f + 1000 * n for f, n in zip(font, lines)]
    rec = b''
    for usage, fixed, keep in ((menu, MENU_GRAYS, len(MENU_GRAYS)), (font, ((0, 0, 0),), 1),
                               (automap, ((0, 0, 0),) + tuple(base[c] for c in AUTOMAP_COLORS), 16)):
        pal = gscolor.kmeans([(base[i], usage[i]) for i in range(256)], fixed=fixed)
        if keep < 16:
            pal = gscolor.align8(pal, keep)   # (the automap keeps its order)
        rec += gscolor.palette_record(pal, pals, usage)
        print('GSOVL', ' '.join('%03X' % gscolor.word12(c) for c in pal))
    return rec


def title_weight(x, y):
    """The marine's face of TITLEPIC counts 10 times in its palettes."""
    return 10 if 100 <= x <= 144 and 68 <= y <= 105 else 1


# The level spots of the episode 1 map (lnodes of wi_lib.c): the splat and
# the "you are here" arrow go there.
WIMAP_SPOTS = ((185, 164), (148, 143), (69, 122), (209, 102), (116, 89), (166, 55), (71, 56),
               (135, 29), (71, 24))


def wimap_weight(x, y):
    """The level spots of WIMAP0 count 8 times in its palettes, so the
    buildings keep their green and blue."""
    for sx, sy in WIMAP_SPOTS:
        if sx - 24 <= x < sx + 24 and sy - 24 <= y < sy + 14:
            return 8
    return 1


def map_pointer_text(data):
    """Light lettering with dark edges against WIMAP0's earth tones."""
    data = bytearray(data)
    shades = {181: 4, 184: 82, 40: 92, 45: 0, 9: 0, 10: 0}
    width = struct.unpack_from('<h', data)[0]
    # WIURH0's lettering starts at column 17; keep the red arrow before it.
    for x in range(17, width):
        p = struct.unpack_from('<I', data, 8 + 4 * x)[0]
        while data[p] != 255:
            count = data[p + 1]
            for i in range(p + 3, p + 3 + count):
                data[i] = shades.get(data[i], data[i])
            p += count + 4
    return bytes(data)


def build_colors(wad, gsview):
    """Add GSVIEW0 (all maps), GSVIEW1..9 (each map) and GSFLAT1..9 from the
    tables of tools/gsview.py in the directory gsview, and GSSTAT, and turn
    the full screen pictures into SHR pictures. Needs the original lumps.
    Returns the flat list of each map (the flat numbers of the sector
    data)."""
    pals = read_playpals(wad)
    base = pals[0]

    flat_lists = {}
    wad.add('GSVIEW0', open(os.path.join(gsview, 'GSVIEW0.lmp'), 'rb').read())
    for m in range(1, 10):
        wad.add(f'GSVIEW{m}', open(os.path.join(gsview, f'GSVIEW{m}.lmp'), 'rb').read())
        wad.add(f'GSFLAT{m}', open(os.path.join(gsview, f'GSFLAT{m}.lmp'), 'rb').read())
        flat_lists[m] = open(os.path.join(gsview, f'GSFLAT{m}.txt')).read().split()
        if len(flat_lists[m]) > MAX_FLATS:
            sys.exit(f'GSFLAT{m}: {len(flat_lists[m])} flats, more than {MAX_FLATS}')
    wad.add('GSOVL', overlay_palettes(wad, pals))
    rec, spals, row_pal = status_palettes(wad, pals)
    wad.add('GSSTAT', rec)
    print('GSSTAT rows', ''.join('%d' % p for p in row_pal))
    for p, pal in enumerate(spals):
        print(f'GSSTAT {p}', ' '.join('%03X' % gscolor.word12(c) for c in pal))

    menus = overlay_usage(wad, ('M_',))
    inter = overlay_usage(wad, ('WI',))
    for name, overlay, weight in (('TITLEPIC', menus, title_weight), ('HELP2', None, None),
                                  ('WIMAP0', inter, wimap_weight)):
        raw = raw_crop(wad.get(name), 320, 200)
        wad.set(name, gscolor.picture(raw, base, overlay, weight, strip=name == 'TITLEPIC'))
        print(name, 'as SHR picture')
    # Keep the original art in every palette search; only the label changes.
    wad.set('WIURH0', map_pointer_text(wad.get('WIURH0')))
    return flat_lists


# --------------------------------------------------------------------------

CREDITS = ('Doom8088: Apple IIgs Edition\r\n'
           'Doom8088 by Frenkel Smeijers\r\n'
           'based on\r\n'
           'GBA PrBoom port created by doomhack')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('wad')
    ap.add_argument('outdir')
    ap.add_argument('--flat-span', action='store_true')
    ap.add_argument('--layout', type=int, choices=(240, 320), default=320,
                    help='screen layout: 240x160 of Doom8088 or 320x200 of Doom')
    ap.add_argument('--demo2', help='hex-encoded replacement for the stock DEMO2 inputs')
    ap.add_argument('--keep-demos', action='store_true',
                    help='keep DEMO1 and DEMO2 (for the timedemo tests)')
    ap.add_argument('--name', default='DOOMGS.WAD', help='the output file in OUTDIR')
    ap.add_argument('--gsview', help='the tables of tools/gsview.py (--layout 320)')
    ap.add_argument('--music-bank', help='music bank whose units join the level store')
    ap.add_argument('--store', help='write the resident WAD, the store STORE and the title '
                    'picture (tools/levelimg.py); needs --src')
    ap.add_argument('--src', help='src/iigs (info65.s, p_switch65.s) for --store')
    args = ap.parse_args()

    wad = Wad(args.wad)
    if args.demo2:
        original = wad.get('DEMO2')
        replacement = bytes.fromhex(open(args.demo2).read())
        # This recording is for the stock v1.9 E1M3 demo and NG1 logic.
        expected = '74ee530c2c35046469bafd92d0cd49ab0a5dee76872c1a91e682aef9bc4410e9'
        if hashlib.sha256(original).hexdigest() != expected:
            sys.exit('DEMO2 replacement: unexpected original recording')
        if (len(replacement) != len(original) or replacement[:13] != original[:13]
                or replacement[-1] != 0x80
                or any(replacement[i] == 0x80 for i in range(13, len(replacement) - 1, 4))):
            sys.exit('DEMO2 replacement: length, header or tic stream changed')
        wad.set('DEMO2', replacement)
    os.makedirs(args.outdir, exist_ok=True)

    flat_lists = {}
    if args.layout == 320:
        # Palettes and SHR pictures; this reads the original map lumps.
        flat_lists = build_colors(wad, args.gsview)

    process_texture1(wad)
    process_pnames(wad)
    maps = MapProcessor(wad, args.flat_span, flat_lists)
    maps.process()

    wad.add('M_ARUN', text_patch(wad, 'ALWAYS RUN'))
    wad.add('M_GAMMA', text_patch(wad, 'GAMMA'))
    wad.add('M_MOUSE', text_patch(wad, 'MOUSE'))
    wad.add('M_MSPEED', text_patch(wad, 'MOUSE SPEED'))
    wad.add('M_MMOVE', text_patch(wad, 'MOUSE MOVE'))
    wad.add('M_CTRLS', text_patch(wad, 'KEY SETUP'))
    wad.add('CREDITS', CREDITS.encode('ascii'))
    if args.layout == 320:
        # The status bar background becomes a raw 320x32 picture.
        wad.set('STBAR', raw_crop(wad.get('STBAR'), 320, 32))
    else:
        # Stand-in lumps for the 240x160 GBA layout of Doom8088.
        for i in range(10):
            wad.add(f'STGANUM{i}', wad.get(f'STTNUM{i}'))
        wad.set('TITLEPIC', raw_scaled(wad.get('TITLEPIC'), 240, 160))
        wad.set('HELP2', raw_scaled(wad.get('HELP2'), 240, 160))
        wad.set('WIMAP0', raw_scaled(wad.get('WIMAP0'), 240, 160))
        wad.set('STBAR', raw_crop(wad.get('STBAR'), 240, 32))

    remove_unused(wad, args.flat_span, args.layout, args.keep_demos)
    for name, data in maps.grids.items():
        wad.add(name, data)
    if args.store:
        save_store(wad, os.path.join(args.outdir, args.name), args.store, args.src, args.music_bank)
    else:
        wad.save(os.path.join(args.outdir, args.name))


def save_store(wad, path, store_path, srcdir, music=None):
    """The resident WAD (path), the store (store_path) and the title
    picture for the loader (path + '.PIC'): tools/levelimg.py."""
    lumps = [(nm, bytes(d)) for nm, d in wad.lumps]
    ls = levelset.LevelSets(levelset.GameWad(lumps=lumps), srcdir)
    names = [nm for nm, _ in lumps]
    sets, walls = [], []
    for m in levelset.MAPS:
        sets.append(ls.level(m))
        walls.append(ls.patches(m))
    sets.append([names.index(n) for n in levelimg.TITLE_GROUP])
    walls.append(set())
    sets.append([i for i, n in enumerate(names)
                 if n.startswith(levelimg.INTER_PREFIXES) or n in levelimg.INTER_GROUP])
    walls.append(set())
    cache = os.environ.get('B1CACHE') or os.path.join(os.path.dirname(os.path.abspath(store_path)), 'b1cache')
    image, store, report, resident, outside = levelimg.build(lumps, sets, walls, srcdir, cache, music=music)
    open(path, 'wb').write(image)
    # the resident lumps outside banks 10-12 (free areas of the table banks):
    # one file for each run, FILE@ADDR in path + '.SEG' for tools/mkdisk.py
    runs = []
    for a, data in sorted(outside.items()):
        if runs and runs[-1][0] + len(runs[-1][1]) == a:
            runs[-1][1] += data
        else:
            runs.append([a, bytearray(data)])
    segs = []
    for k, (a, data) in enumerate(runs):
        seg = f'{path}.{k}'
        open(seg, 'wb').write(data)
        segs.append(f'{seg}@0x{a:06x}')
    open(path + '.SEG', 'w').write('\n'.join(segs) + ('\n' if segs else ''))
    open(store_path, 'wb').write(store)
    # Songs plus uncompressed map units exceed the space below MUSBANK.
    # Keep the historical .RAW filename, but use B1 when music is present.
    _, rstore, _, _, _ = levelimg.build(lumps, sets, walls, srcdir, cache, raw=not bool(music),
                                        groups=(tuple(levelset.MAPS),), music=music)
    open(store_path + '.RAW', 'wb').write(rstore)
    open(path + '.PIC', 'wb').write(lumps[names.index('TITLEPIC')][1])
    print(f'{path}: {len(lumps)} lumps, {len(resident)} resident, {len(image)} bytes')
    print(f'{store_path}: {len(store)} bytes; the hard disk store {len(rstore)} bytes')
    for k, cnt, nb, end in report[:-2]:
        print(f'  set {k + 1}: {cnt} entries, {nb} window banks, the image to ${end:06X}')
    _, nu, raw, comp = report[-2]
    print(f'  {nu} units: {raw} bytes, {comp} in the store (B1)')
    _, regions, total, _ = report[-1]
    open(store_path + '.REG', 'w').write(' '.join(str(r) for r in regions) + '\n')
    print(f'  the regions of disks 1-{len(regions)}: ' + ', '.join(f'${r:06X}' for r in regions))


if __name__ == '__main__':
    main()
