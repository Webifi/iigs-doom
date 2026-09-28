#!/usr/bin/env python3
"""The resident WAD and the level store (src/iigs/memmap.inc, the level
loader src/iigs/w_level65.s).

The game keeps in memory only the lumps that every map needs (the resident
WAD at MM_WAD: status bar, fonts, menus, palettes, demos). Each map loads
its own lumps (tools/levelset.py) into the level window at its start, the
title and intermission pictures load when they show. Their data is in the
store: each lump once. An 8 MB IIgs loads the store at boot at STORE_BASE
and copies from it; a 4 MB IIgs reads it from the disks.

The directory of the resident WAD holds every lump, in the order of the
game WAD (the game uses lump numbers). A lump that is not in memory points
to a placeholder: an empty patch (width 0), so that a stray read draws
nothing.

A set (a map, a picture group) is an image of window banks, the same on
every IIgs. Its data comes in units: a sprite family, the wall patches
that the same maps use, the map lumps of a map, a picture group (split at
UNIT_MAX bytes). A unit is its lumps one after the other, the same in
every set; the store holds it compressed (tools/b1.py), and the loader
decodes it into its place in the window. No unit crosses a bank, a unit
with wall patches ends at least OVERREAD bytes before the end of its bank
(the texel reads of a short texture go up to 127 bytes past a column
start), and every other byte of the image banks is zero. So no read
leaves its bank, and the frames do not depend on which physical banks hold
the image or on the set before.

Store layout (little endian):
  0   "DOOMST", u16 set count
  8   per set (SETREC bytes): u32 store offset of its entries, u16 entry
      count, u8 window banks, u8 its disk, u16 the end of the image in
      its last bank (colmem starts there; 0: in the next bank), u16 the
      sum of the words of its entries (the loader finds a changed disk)
  entries (ENTRY bytes): u16 lump, UNIT or FILL, u8 window bank index |
      0x80 (else an absolute bank), u16 offset, u24 store address, u16
      length. UNIT: the unit to that address, its stream at the store
      address (u16 the unit's length, then B1), length = the stream's
      bytes. UNIT_RAW: the same with the unit's bytes in place of B1.
      FILL: zeros (length 0: 64 KB). A lump: the directory entry of the
      lump gets the address (its data comes with its unit).
  Song entries follow the FILLs and do not extend the image or W_COLSTART:
      $FFE0+i: select bank song slot i, absolute staging address.
      $FFFC: B1 song chunk; $FFF9: raw boundary-byte chunk.
      $FFFB: complete unit, address = staging start, source = total size.
      $FFF7: common-set preload of a compressed VICTOR chunk into a
      static zone block on 4 MB (address = cache index, source = stream).
      $FFF6/$FFF5: cached B1/raw chunk (source = cache index).
      Only the selected music is decoded on 4 MB; musLoad follows runSet.
      VICTOR stays compressed in at most 80 KB of the 256 KB zone so it
      needs neither another map-disk copy nor a finale swap.
      The penultimate set assembles MUSBANK ($6A0000) on 8 MB, using
      UNIT/UNIT_RAW to a temporary bank and $FFF8 RAM copies (source,
      destination, length) into the bank's original song offsets.
  the streams of the units, each in one bank
"""

import copy
import functools
import os
import re
import struct

import b1

BANK = 0x10000
RES_BASE = 0x100000             # MM_WAD
RES_END = 0x130000              # banks 10-12
STORE_BASE = 0x400000
OVERREAD = 128
SETREC = 12
ENTRY = 10
FILL = 0xffff
UNIT = 0xfffe
UNIT_RAW = 0xfffd                       # (a unit as it is: the hard disk store)
GROUPS = ((1, 2, 3), (4, 5, 6), (7, 8, 9))  # final4: play order, 2 swaps; 6-8 do not fit one disk
UNIT_MAX = 0xbc00                       # 47 KB: a stream fits SCRATCH_IN of
                                        #   src/iigs/w_level65.s (48 KB)
READ_MAX = 0xc000                       # streamIn of src/iigs/w_level65.s: the
READ_GAP = 1024                         #   streams of the units of a set that
                                        #   follow in the store (at most
                                        #   READ_GAP bytes apart) come in one
                                        #   read of at most READ_MAX bytes
STREAM_MAX = 0xc000
PLACEHOLDER = struct.pack('<hhhh', 0, 0, 0, 0)
# Lumps the game never reads (PLAYPAL, ENDOOM: the loader and wadtool use
# them; DP*: PC speaker sounds) and patches no map of episode 1 uses.
UNUSED = ('PLAYPAL', 'ENDOOM', 'W31_1', 'COMP03_9')
UNUSED_PREFIXES = ('DP',)
NOT_DRAWN = ('PLAY',)                   # tools/levelset.py
TITLE_GROUP = ('TITLEPIC',)
INTER_PREFIXES = ('WI',)
INTER_GROUP = ('HELP2', 'FLOOR4_8')
# The cache of the ZipGS and TransWarp GS holds a byte at slot address &
# $7FFF (32 KB, direct mapped). HOT_FILE (from the bus model profiles of the
# demos and recorded play sessions) gives, for each profiled map, the reads a
# frame of its lumps (half the fight frames, half the whole run or session)
# and, for each slot page of 256 bytes, the reads a frame of the code and the
# other data (not the level window) in the fight frames. A lump with
# SPLIT_MIN reads or more is a unit of its own, and plan_search orders the
# units of each set so that its lumps meet the least reads on their slot
# pages.
HOT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'levelhot.txt')
SPLIT_MIN = 400                         # a lump with this many reads a frame
                                        #   is a unit of its own


def free_areas(srcdir):
    """The FREE lines of src/iigs/memmap.inc: [(start, end)]."""
    out = []
    for line in open(os.path.join(srcdir, 'memmap.inc')):
        m = re.match(r';;; FREE \$([0-9A-F]{6})-\$([0-9A-F]{6})( \(|$)', line.strip())
        if m:
            out.append((int(m.group(1), 16), int(m.group(2), 16) + 1))
    return out


def spritelump(lumps, i):
    names = [nm for nm, _ in lumps]
    return names.index('S_START') < i < names.index('S_END')


def unused(name):
    return name in UNUSED or name.startswith(UNUSED_PREFIXES + NOT_DRAWN)


def reads(spans):
    """The reads of streamIn for the streams [(store address, length)] of
    a set's units in the order of the entries (the store order)."""
    n, bs, be = 0, None, None
    for a, ln in sorted(spans):
        if bs is None or a < be or a > be + READ_GAP or a + ln - bs > READ_MAX:
            n += 1
            bs, be = a, a + ln
        else:
            be = a + ln
    return n


def store_order(mine, owns, size, key, start):
    """The units mine in the order for the store region of a disk (from
    start): each set's units (owns) in the fewest reads of streamIn (a read
    after a decode waits for the disk to turn). The units that the same sets
    need are a group; the groups by a descent of moves, each kept when the
    reads of all the sets fall (a first-fit packing from start, as the
    store's)."""
    groups = {}
    for u in mine:
        sig = tuple(j for j, own in enumerate(owns) if u in own)
        groups.setdefault(sig, []).append(u)
    for g in groups.values():
        g.sort(key=key)
    # the start: the sets with the most bytes as the high bits of a
    # reflected Gray code of the signature
    tot = [sum(size[u] for u in own if u in mine) for own in owns]
    rank = sorted(range(len(owns)), key=lambda j: -tot[j])

    def gray(sig):
        b = 0
        for j in sig:
            b |= 1 << (len(owns) - 1 - rank.index(j))
        n, m = 0, b
        while m:                        # the index of b in the Gray code
            n ^= m
            m >>= 1
        return n
    order = sorted(groups, key=gray)

    def cost(order):
        pk = Packer(start, start + 64 * BANK)
        at = {}
        for sig in order:
            for u in groups[sig]:
                at[u] = pk.place(size[u])
        return sum(reads([(at[u], size[u]) for u in own if u in mine]) for own in owns)
    best = cost(order)
    better = True
    while better:
        better = False
        for i in range(len(order)):
            for j in range(len(order)):
                if i == j:
                    continue
                o2 = list(order)
                g = o2.pop(i)
                o2.insert(j, g)
                c = cost(o2)
                if c < best:
                    best, order, better = c, o2, True
    return [u for sig in order for u in groups[sig]]


class Packer:
    """First fit into banks from base: no item crosses a bank; a wall item
    leaves OVERREAD bytes before the end of its bank. extra: more areas
    (start, end) for items that do not fit up to limit."""

    def __init__(self, base, limit, extra=()):
        self.base = base
        self.limit = limit
        self.free = []                  # (start, end) of each bank with room
        self.end = base
        self.extra = list(extra)

    def clone(self):
        """A copy (the lists of tuples copied, as deepcopy does, faster)."""
        c = Packer.__new__(Packer)
        c.base, c.limit, c.end = self.base, self.limit, self.end
        c.free, c.extra = list(self.free), list(self.extra)
        return c

    def place(self, size, wall=False, tail=0):
        need = size + max(OVERREAD if wall else 0, tail)
        if need > BANK:
            raise ValueError(f'a lump of {size} bytes does not fit a bank')
        for i, (a, b) in enumerate(self.free):
            if b - a >= need:
                self.free[i] = (a + size, b)
                return a
        a = self.end
        if (a & 0xffff) + need > BANK:
            a = (a | 0xffff) + 1
        if a + need <= self.limit:
            if a != self.end:
                self.free.append((self.end, a))
            self.end = a + size
            return a
        for i, (a, b) in enumerate(self.extra):
            if b - a >= need:
                self.extra[i] = (a + size, b)
                return a
        raise ValueError(f'a lump of {size} bytes: no room from ${self.base:06X}')


def read_hot(path=HOT_FILE):
    """(the load of the 128 slot pages, {map: {lump name: reads a frame}}),
    or (None, {}) without the file."""
    if not os.path.exists(path):
        return None, {}
    load, hot = None, {}
    for line in open(path):
        f = line.split()
        if not f or f[0].startswith('#'):
            continue
        if f[0] == 'load':
            load = [int(x) for x in f[1:]]
        else:
            hot[int(f[0][3:])] = {nm: int(w) for nm, w in (t.split(':') for t in f[1:])}
    return load, hot


def page_load(a, size):
    """[(slot page, bytes)] of the bytes [a, a + size) (a tuple: the same
    for the same slot address and size, kept)."""
    return _page_load(a & 0x7fff, size)


@functools.lru_cache(maxsize=None)
def _page_load(a, size):
    out = []
    while size > 0:
        n = min(size, 0x100 - (a & 0xff))
        out.append((((a & 0x7fff) >> 8), n))
        a += n
        size -= n
    return tuple(out)


def seg_costs(ad, segs, load, W0):
    """{(unit, offset): the load on the slot pages of each hot lump (load[p]
    + W0[p] + the other hot lumps, per byte, times its weight per byte)}
    of the layout ad ({unit: address})."""
    W = list(W0)
    pl = []
    for u, a in ad.items():
        sg = segs.get(u)
        if not sg:
            continue
        for off, n, w in sg:
            ps = page_load(a + off, n)
            pl.append(((u, off), ps, w / n))
            for p, m in ps:
                W[p] += m * w / n
    out = {}
    for key, ps, wb in pl:
        c = 0
        for p, m in ps:
            c += m * wb * (load[p] + W[p] - m * wb)
        out[key] = c
    return out


def plan_search(base, own, sizes, walls, segs, load, W0, limit, ref, iters=12000, seed=1):
    """The first-fit packing (after the units of base, a Packer) of the
    units own in an order that gives their hot lumps (segs) the least load
    on their slot pages: random swaps (seeded: the same image each build)
    in the order of the largest first. A swap is kept when the image ends
    no later than limit and the pair (the load over the old layout's load
    of each hot lump, ref: {(unit, offset): load}; the total load) falls.
    Returns {unit: address}."""
    import random
    rnd = random.Random(seed)
    order = sorted(own, key=lambda u: (-sizes[u], u))

    def pack(order):
        img = base.clone()
        ad = {}
        for u in order:
            ad[u] = img.place(sizes[u], wall=walls[u], tail=1)
        return ad, max(a + sizes[u] for u, a in ad.items()) if ad else 0

    def split(c):
        """(the load that passes the old one, the total load)."""
        return (sum(max(0.0, c[k] - ref.get(k, c[k])) for k in c), sum(c.values()))
    ad, end = pack(order)
    best = split(seg_costs(ad, segs, load, W0))
    hot = [i for i, u in enumerate(order) if segs.get(u)]
    # first no hot lump over its old load, then the least total load with
    # none over it
    for _ in range(iters if hot else 0):
        i = rnd.choice(hot)
        j = rnd.randrange(len(order))
        if i == j:
            continue
        order[i], order[j] = order[j], order[i]
        ad2, end2 = pack(order)
        sc = split(seg_costs(ad2, segs, load, W0)) if end2 <= limit else None
        if sc is not None and (sc[0] < best[0] - 1e-6 or (sc[0] <= best[0] + 1e-9 and sc[1] < best[1] - 1e-6)):
            best, ad = sc, ad2
            hot = [k for k, u in enumerate(order) if segs.get(u)]
        else:
            order[i], order[j] = order[j], order[i]
    return ad


def make_units(lumps, sets_of, walls_of, hotnames=()):
    """The units: [(key, [lump indices], wall)]. A sprite lump goes to its
    family (the 4 letters), a wall patch to the patches of the same maps,
    another lump of a map to the lumps of the same maps (the map lumps:
    one map), a picture set is its own group, a hot lump (hotnames) a unit
    of its own; each group split at UNIT_MAX bytes in lump order."""
    nmaps = len(sets_of) - 2
    maps_of = {}
    for k in range(nmaps):
        for i in sets_of[k]:
            maps_of.setdefault(i, set()).add(k)
    groups = {}
    for k, s in enumerate(sets_of):
        for i in s:
            if not lumps[i][1]:
                continue
            if k >= nmaps:
                key = ('p', k)
            elif lumps[i][0] in hotnames:
                key = ('H', i)          # (the lump alone)
            elif spritelump(lumps, i):
                key = ('s', lumps[i][0][:4])
            elif any(i in walls_of[m] for m in maps_of[i]):
                key = ('w', tuple(sorted(maps_of[i])))
            else:
                key = ('o', tuple(sorted(maps_of[i])))
            groups.setdefault(key, set()).add(i)
    walls = set()
    for k in range(nmaps):
        walls |= set(walls_of[k])
    units = []
    for key in sorted(groups, key=str):
        cur, size = [], 0
        for i in sorted(groups[key]):
            n = len(lumps[i][1])
            if cur and size + n > UNIT_MAX:
                units.append((key, cur, key[0] == 'w'))
                cur, size = [], 0
            cur.append(i)
            size += n
        if cur:
            units.append((key, cur, key[0] == 'w' or (key[0] == 'H' and cur[0] in walls)))
    return units


def build(lumps, sets_of, walls_of, srcdir, cache=None, raw=False, groups=None, music=None):
    """lumps: [(name, data)] in directory order. sets_of: the lump indices
    of each set (a list: the maps 1-9, then the groups), walls_of: the wall
    patches of each set. cache: the directory of tools/b1.py. Returns
    (resident image bytes, store bytes, a report, the resident lumps, the
    lumps outside banks 10-12). raw: the units as they are (UNIT_RAW, the
    store of a hard disk: it reads faster than B1 decodes). groups: the
    maps of each level disk (GROUPS)."""
    groups = groups or GROUPS
    n = len(lumps)
    in_set = set()
    for s in sets_of:
        in_set |= set(s)
    resident = [i for i in range(n)
                if i not in in_set and lumps[i][1] and not unused(lumps[i][0])]

    # the resident WAD
    header = 12 + 16 * n
    res = Packer(RES_BASE, RES_END, free_areas(srcdir))
    res.end = RES_BASE + header
    placeholder = res.place(len(PLACEHOLDER))
    pos = [placeholder] * n
    seen = {}
    for i in sorted(resident, key=lambda i: (-len(lumps[i][1]), i)):
        data = lumps[i][1]
        if data not in seen:
            seen[data] = res.place(len(data))
        pos[i] = seen[data]
    image = bytearray(res.end - RES_BASE)
    image[placeholder - RES_BASE:placeholder - RES_BASE + len(PLACEHOLDER)] = PLACEHOLDER
    outside = {}                        # the lumps in the free areas: (start: data)
    for data, a in seen.items():
        if RES_BASE <= a < res.end:
            image[a - RES_BASE:a - RES_BASE + len(data)] = data
        else:
            outside[a] = data
    directory = bytearray()
    for (name, data), a in zip(lumps, pos):
        filepos = (a - RES_BASE) & 0xffffffff
        size = len(data) if a != placeholder or not data else 0
        directory += struct.pack('<IHH8s', filepos, len(data), 0, name.encode('ascii'))
    image[0:12] = struct.pack('<4shhi', b'IWAD', n, 0, 12)
    image[12:header] = directory

    # the units: each lump with data of the sets in one unit
    load, hot = read_hot()
    nmaps = len(sets_of) - 2
    names = [nm for nm, _ in lumps]
    # the weight of each hot lump in each map: its own, else the mean of the
    # profiled maps that have it (the maps without a profile)
    mean = {}
    for m, h in hot.items():
        for nm, w in h.items():
            mean.setdefault(nm, []).append(w)
    mean = {nm: sum(v) / len(v) for nm, v in mean.items()}
    weight = []
    for k in range(nmaps):
        h = hot.get(k + 1)
        wk = {}
        for i in sets_of[k]:
            nm = names[i]
            if h is not None:
                if nm in h:
                    wk[i] = h[nm]
            elif nm in mean:
                wk[i] = mean[nm]
        weight.append(wk)
    # (the map lumps stay in their unit: it keeps them together, and the
    # search still weighs their load)
    MAPLUMPS = ('THINGS', 'LINEDEFS', 'SIDEDEFS', 'VERTEXES', 'SEGS', 'SSECTORS', 'NODES',
                'SECTORS', 'REJECT', 'BLOCKMAP')
    units = make_units(lumps, sets_of, walls_of,
                       set(nm for nm in mean if nm not in MAPLUMPS and mean[nm] >= SPLIT_MIN) if load else ())
    unit_of = {}
    for u, (key, ls, wall) in enumerate(units):
        for i in ls:
            unit_of[i] = u
    need = [set(unit_of[i] for i in s if lumps[i][1]) for s in sets_of]
    common = set.intersection(*need[:nmaps]) if nmaps else set()
    blobs = []                          # (image, {lump: offset}) of each unit
    for key, ls, wall in units:
        img = bytearray()
        at = {}
        where = {}
        for i in ls:
            data = lumps[i][1]
            if data not in where:
                where[data] = len(img)
                img += data
            at[i] = where[data]
        blobs.append((bytes(img), at))
    streams = []
    for img, _ in blobs:
        enc = struct.pack('<H', len(img)) + (img if raw else b1.compress(img, cache))
        if len(enc) > STREAM_MAX and not raw:
            raise ValueError(f'a unit stream of {len(enc)} bytes: more than {STREAM_MAX}')
        streams.append(enc)

    # the common units, which every map needs: they load once (the first
    # W_LoadSet) into the first window banks and stay there; every set
    # places its other units after them. The common set is the last set.
    base = Packer(0, 64 * BANK)
    caddr = {}
    for u in sorted(common, key=lambda u: (-len(blobs[u][0]), u)):
        # a unit ends before its bank end (the decoder's end offset), a
        # wall unit OVERREAD bytes before it
        caddr[u] = base.place(len(blobs[u][0]), wall=units[u][2], tail=1)

    def uweight(u, k):
        """The weight of unit u in map k (a hot unit: its lump's)."""
        if units[u][0][0] != 'H':
            return 0
        return weight[k].get(units[u][1][0], 0)
    plan = {}                           # map k: {unit: address} (the planner)
    if load:
        sizes = {u: len(blobs[u][0]) for u in range(len(units))}
        walls = {u: units[u][2] for u in range(len(units))}

        def segs_of(us, wmap):
            """{unit: [(offset, size, weight)]} of the hot lumps of the units."""
            out = {}
            for u in us:
                for i in units[u][1]:
                    w = wmap(i)
                    if w:
                        out.setdefault(u, []).append((blobs[u][1][i], len(lumps[i][1]), w))
            return out
        # the old layout (the units of make_units without hot lumps, first
        # fit): the load of each hot lump there, and the end of each map
        ounits = make_units(lumps, sets_of, walls_of)
        ounit_of = {}
        for u, (key, ls, wall) in enumerate(ounits):
            for i in ls:
                ounit_of[i] = u
        oneed = [set(ounit_of[i] for i in s if lumps[i][1]) for s in sets_of]
        ocommon = set.intersection(*oneed[:nmaps])
        oblob = []
        for key, ls, wall in ounits:
            at, where, n = {}, {}, 0
            for i in ls:
                if lumps[i][1] not in where:
                    where[lumps[i][1]] = n
                    n += len(lumps[i][1])
                at[i] = where[lumps[i][1]]
            oblob.append((n, at))
        obase = Packer(0, 64 * BANK)
        oad = {}
        for u in sorted(ocommon, key=lambda u: (-oblob[u][0], u)):
            oad[u] = obase.place(oblob[u][0], wall=ounits[u][2], tail=1)

        def old_layout(k):
            img = copy.deepcopy(obase)
            ad = dict(oad)
            for u in sorted(oneed[k] - ocommon, key=lambda u: (-oblob[u][0], u)):
                ad[u] = img.place(oblob[u][0], wall=ounits[u][2], tail=1)
            lump_at = {i: ad[ounit_of[i]] + oblob[ounit_of[i]][1][i] for i in sets_of[k] if lumps[i][1]}
            return lump_at, max(a + oblob[u][0] for u, a in ad.items())

        def lump_costs(lump_at, wk):
            """{lump: its load} of the hot lumps (wk: {lump: weight}) at lump_at."""
            W = [0.0] * 128
            pl = {}
            for i, w in wk.items():
                if i in lump_at:
                    pl[i] = (page_load(lump_at[i], len(lumps[i][1])), w / len(lumps[i][1]))
                    for p, m in pl[i][0]:
                        W[p] += m * pl[i][1]
            return {i: sum(m * wb * (load[p] + W[p] - m * wb) for p, m in ps) for i, (ps, wb) in pl.items()}
        # the common units: the search with the weights of all maps
        allw = {}
        for k in range(nmaps):
            for i, w in weight[k].items():
                allw[i] = allw.get(i, 0) + w
        clump = {i: oad[ounit_of[i]] + oblob[ounit_of[i]][1][i] for u in ocommon for i in ounits[u][1]}
        cref = lump_costs(clump, {i: w for i, w in allw.items() if i in clump})
        csg = segs_of(common, lambda i: allw.get(i, 0))
        cref2 = {}
        for u, lst in csg.items():
            for off, n, w in lst:
                i = next(i for i in units[u][1] if blobs[u][1][i] == off)
                if i in cref:
                    cref2[(u, off)] = cref[i]
        cend = max(a + oblob[u][0] for u, a in oad.items())
        caddr = plan_search(Packer(0, 64 * BANK), common, sizes, walls, csg, load, [0.0] * 128, cend, cref2,
                            iters=8000, seed=99)
        # base: the Packer after the common units in that order (the maps
        # fill its free bank tails as before)
        base = Packer(0, 64 * BANK)
        for u in sorted(caddr, key=lambda u: caddr[u]):
            if base.place(len(blobs[u][0]), wall=units[u][2], tail=1) != caddr[u]:
                raise ValueError('the common units do not pack again the same way')
        # each map: the search
        for k in range(nmaps):
            wk = weight[k]
            lump_at, oend = old_layout(k)
            ref = lump_costs(lump_at, wk)
            W = [0.0] * 128
            for u, sg in segs_of(common, lambda i: wk.get(i, 0)).items():
                for off, n, w in sg:
                    for p, m in page_load(caddr[u] + off, n):
                        W[p] += m * w / n
            own = need[k] - common
            sg = segs_of(own, lambda i: wk.get(i, 0))
            # (ref by the key of seg_costs: (unit, offset) of each hot lump)
            ref2 = {}
            for u, lst in sg.items():
                for off, n, w in lst:
                    i = next(i for i in units[u][1] if blobs[u][1][i] == off)
                    if i in ref:
                        ref2[(u, off)] = ref[i]
            plan[k] = plan_search(base, own, sizes, walls, sg, load, W, oend, ref2, seed=k + 1)

    def set_entries(lumpset, own, img, fixed, disk, planned=None):
        """The entries: UNIT for the units own (placed after the units
        fixed in img, or at their planned addresses; their streams on the
        disk), each lump of lumpset, FILL for every other byte of the image
        banks. Returns (entries, window banks, the end in the last bank)."""
        uaddr = dict(fixed)
        if planned is not None:
            uaddr.update(planned)
        else:
            for u in sorted(own, key=lambda u: (-len(blobs[u][0]), u)):
                uaddr[u] = img.place(len(blobs[u][0]), wall=units[u][2], tail=1)
        ents = []
        for u in sorted(own, key=lambda u: saddr[(u, disk)]):
            ents.append((UNIT_RAW if raw else UNIT, uaddr[u], saddr[(u, disk)], len(streams[u])))
        for i in lumpset:
            if lumps[i][1]:
                u = unit_of[i]
                ents.append((i, uaddr[u] + blobs[u][1][i], 0, 0))
            else:
                ents.append((i, 0, 0, 0))       # a marker lump (E1Mn)
        used = {}
        for u, a in uaddr.items():
            used.setdefault(a >> 16, []).append((a & 0xffff, (a & 0xffff) + len(blobs[u][0])))
        nbanks = (max(used) + 1) if used else 0
        endlast = 0
        for b in range(nbanks):
            pos = 0
            for a0, a1 in sorted(used.get(b, [])):
                if a0 > pos:
                    ents.append((FILL, (b << 16) | pos, 0, a0 - pos))
                pos = max(pos, a1)
            if pos < BANK:
                ents.append((FILL, (b << 16) | pos, 0, BANK - pos))
            if b == nbanks - 1:
                endlast = pos % BANK
        return ents, nbanks, endlast

    # the sets and their disks (GROUPS: the maps of each level disk): the
    # maps; the title (disk 1); the intermission set on the first level
    # disk and a copy on each other one (the loader takes the copy on the
    # disk of the map before); the common set (disk 1)
    nmapsets = len(sets_of) - 2
    title, inter = sets_of[nmapsets], sets_of[nmapsets + 1]
    all_sets = []                       # (lumps, own units, image, fixed, disk, planned)
    for k in range(nmapsets):
        g = next(j for j, grp in enumerate(groups) if k + 1 in grp)
        all_sets.append((sets_of[k], need[k] - common, copy.deepcopy(base), caddr, 2 + g, plan.get(k)))
    # (the picture sets from bank 0: the loader puts them after the common
    # units, or at the end of the window when they stay there)
    all_sets.append((title, need[nmapsets] - common, Packer(0, 64 * BANK), {}, 1, None))
    for g in range(len(groups)):
        all_sets.append((inter, need[nmapsets + 1] - common, Packer(0, 64 * BANK), {}, 2 + g, None))
    all_sets.append(([], common, Packer(0, 64 * BANK), {}, 1, caddr if load else None))
    # One boot-only set reconstructs MUSBANK on 8 MB from the same streams.
    # Keep common last: the loader finds it from the set count.
    bootset = len(all_sets) - 1
    all_sets.insert(bootset, ([], set(), Packer(0, 64 * BANK), {}, 1, None))
    songs = {}
    bankhead = b''
    if music:
        bank = open(music, 'rb').read()
        count, = struct.unpack_from('<H', bank)
        if count != 13 or len(bank) > 0x160000:
            raise ValueError('music bank must have 13 slots and fit $6A-$7F')
        bankhead = bank[:2 + count * 8]
        for i in range(count):
            off, size = struct.unpack_from('<II', bank, 2 + i * 8)
            if not size:
                continue
            data = bank[off:off + size]
            if len(data) != size or size > 0x18000:
                raise ValueError('invalid song image')
            # Split at bank and decoder boundaries for both staging and bank.
            chunks = []
            pos = 0
            while pos < size:
                n = min(UNIT_MAX, size-pos, (BANK-1-(pos % BANK)) or 1)
                if i == 10:
                    # The boot loader reuses these streams at $2A8000.
                    n = min(n, BANK - ((0x8000 + pos) % BANK))
                part = data[pos:pos+n]
                israw = n == 1
                enc = struct.pack('<H', n) + (part if israw else b1.compress(part, cache))
                if len(enc) > STREAM_MAX:
                    raise ValueError('song stream exceeds loader scratch')
                chunks.append((pos, enc, israw))
                pos += n
            songs[i] = (off, data, chunks)
    def songs_for(k):
        if k < nmapsets:
            return [k] if k in songs else []
        if k == nmapsets:
            return [10] if 10 in songs else []
        if nmapsets < k < bootset:
            return [i for i in (9, 11) if i in songs]
        return []
    # VICTOR is kept compressed in the 4 MB zone: one boot-disk copy,
    # no finale swap. It is 73,760 bytes with final3 (the zone is 256 KB).
    cached = 11
    def disk_songs(d):
        ids = {i for k, t in enumerate(all_sets) if t[4] == d for i in songs_for(k) if i != cached}
        if d == 1 and cached in songs:
            ids.add(cached)
        return sorted(ids)
    nsets = len(all_sets)

    # the store: the set records, then each disk's region: the streams of
    # its sets' units (maps, sprites, walls, pictures), each in one bank,
    # and their entry lists. A unit that sets of two disks need is in both.
    store = Packer(STORE_BASE, STORE_BASE + 64 * BANK)
    store.end = STORE_BASE + 8 + SETREC * nsets
    kinds = {'m': 0, 'o': 0, 's': 1, 'H': 1, 'w': 2, 'p': 3}
    disks = sorted(set(t[4] for t in all_sets))
    regions = []                        # the store offset of each disk's region
    saddr = {}                          # (unit, disk) -> store address
    songaddr = {}
    songdata = {}
    bootents = []
    bootsongs = set()
    set_recs = [None] * nsets
    offs = [None] * nsets
    entry_bytes = [None] * nsets
    report = [None] * nsets
    for d in disks:
        if d != disks[0]:
            store.end = (store.end + 511) & ~511
        store.free = []
        regions.append(store.end - STORE_BASE)
        mine = set()
        owns = []
        for lumpset, own, img, fixed, sd, planned in all_sets:
            if sd == d:
                mine |= own
                owns.append(own)
        order = store_order(mine, owns, {u: len(streams[u]) for u in mine},
                             lambda u: (kinds[units[u][0][0]], min(units[u][1])), store.end)
        pieces = [(('u', u), streams[u]) for u in order]
        pieces += [(('s', i, pos), enc) for i in disk_songs(d)
                   for pos, enc, israw in songs[i][2]]
        # The last map disk is tight. Compare the streaming order with
        # largest-first packing, keeping whichever wastes fewer bank tails.
        candidates = [pieces]
        if True:
            candidates.append(sorted(pieces, key=lambda t: (-len(t[1]), t[0])))
        layouts = []
        for ps in candidates:
            test = store.clone()
            at = {}
            for key, enc in ps:
                if key[:2] == ('s', 10):
                    # Boot segments start on disk blocks. Reserve the padding
                    # too, so their final block never contains another stream.
                    a = test.place(len(enc) + 511)
                    at[key] = (a + 511) & ~511
                else:
                    at[key] = test.place(len(enc))
            layouts.append((test.end, test, at))
        _, store, at = min(layouts, key=lambda t: t[0])
        for u in order:
            saddr[u, d] = at['u', u]
        for i in disk_songs(d):
            off, data, chunks = songs[i]
            for pos, enc, israw in chunks:
                a = at['s', i, pos]
                songaddr[i, d, pos] = a
                songdata[a] = enc
                if i not in bootsongs:
                    bootents.append((UNIT_RAW if israw else UNIT, 0x3e0000, a, len(enc)))
                    bootents.append((0xfff8, 0x6a0000 + off + pos, 0x3e0000,
                                     struct.unpack_from('<H', enc)[0]))
            bootsongs.add(i)
        for k, (lumpset, own, img, fixed, sd, planned) in enumerate(all_sets):
            if sd != d:
                continue
            ents, nbanks, endlast = set_entries(lumpset, own, img, fixed, d, planned)
            # Song records are outside the image, after its FILL entries.
            # $FFE0+i selects a song; $FFFC chunks decode it; $FFFB loads it.
            for i in songs_for(k):
                stage = (0x2a + nbanks) * BANK if k < nmapsets else 0x3e0000
                if k < nmapsets and stage + len(songs[i][1]) > 0x3e0000:
                    raise ValueError(f'map {k+1}: song staging exceeds $3E0000')
                ents.append((0xffe0 + i, stage, 0, 0))
                for ci, (pos, enc, israw) in enumerate(songs[i][2]):
                    if i == cached:
                        ents.append((0xfff5 if israw else 0xfff6, stage + pos, ci, len(enc)))
                    else:
                        ents.append((0xfff9 if israw else 0xfffc, stage + pos, songaddr[i, d, pos], len(enc)))
                ents.append((0xfffb, stage, len(songs[i][1]), 0))
            if k == nsets - 1 and cached in songs:
                if len(songs[cached][2]) > 8 or sum(len(enc) for _, enc, _ in songs[cached][2]) > 0x14000:
                    raise ValueError('cached VICTOR exceeds the 80 KB zone budget')
                for ci, (pos, enc, israw) in enumerate(songs[cached][2]):
                    ents.append((0xfff7, ci, songaddr[cached, 1, pos], len(enc)))
            set_recs[k] = (len(ents), nbanks, endlast, d)
            eb = bytearray()
            for i, a, sa, ln in ents:
                bnk = (a >> 16) | (0 if 0xffe0 <= i <= 0xfffc else 0x80)
                if ln == BANK:
                    ln = 0                      # (a fill of a whole empty bank: 0 = 64 KB)
                eb += struct.pack('<HBH', i, bnk, a & 0xffff) + (sa & 0xffffff).to_bytes(3, 'little') + \
                    struct.pack('<H', ln)
            entry_bytes[k] = eb
            offs[k] = store.place(len(eb))      # (a list in one bank)
            report[k] = (k, len(ents), nbanks, (nbanks - 1) * BANK + endlast if endlast else nbanks * BANK)
    # The boot-only entry list may reference streams on any disk: it runs
    # only after the whole store is in RAM. Its own bytes live on the last
    # disk, keeping regions contiguous (the record itself is in the header).
    if bankhead:
        enc = struct.pack('<H', len(bankhead)) + bankhead
        a = store.place(len(enc))
        songdata[a] = enc
        bootents.insert(0, (UNIT_RAW, 0x6a0000, a, len(enc)))
    eb = bytearray()
    for i, a, sa, ln in bootents:
        eb += struct.pack('<HBH', i, a >> 16, a & 0xffff) + sa.to_bytes(3, 'little') + struct.pack('<H', ln)
    entry_bytes[bootset] = eb
    offs[bootset] = store.place(max(2, len(eb)))
    set_recs[bootset] = (len(bootents), 0, 0, disks[-1])
    report[bootset] = (bootset, len(bootents), 0, 0)
    total = store.end - STORE_BASE
    if STORE_BASE + total > 0x6a0000:
        raise ValueError('level store overlaps MUSBANK at $6A0000')
    st = bytearray(total)
    st[0:8] = b'DOOMST' + struct.pack('<H', nsets)
    for k, ((cnt, nb, endlast, d), a) in enumerate(zip(set_recs, offs)):
        csum = sum(struct.unpack('<%dH' % (len(entry_bytes[k]) // 2), entry_bytes[k])) & 0xffff
        struct.pack_into('<IHBBHH', st, 8 + SETREC * k, a - STORE_BASE, cnt, nb, d, endlast, csum)
    for (u, d), a in saddr.items():
        st[a - STORE_BASE:a - STORE_BASE + len(streams[u])] = streams[u]
    for a, enc in songdata.items():
        st[a - STORE_BASE:a - STORE_BASE + len(enc)] = enc
    for eb, a in zip(entry_bytes, offs):
        st[a - STORE_BASE:a - STORE_BASE + len(eb)] = eb
    raw = sum(len(b[0]) for b in blobs)
    report.append(('units', len(units), raw, sum(len(x) for x in streams)))
    report.append(('regions', regions, total, 0))
    return bytes(image), bytes(st), report, resident, outside
