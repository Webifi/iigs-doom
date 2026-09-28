#!/usr/bin/env python3
"""The lumps that each map needs at run time (the level set), from the game
WAD of tools/wadtool.py and the thing tables of src/iigs/info65.s.

A level set is:
  - the map lumps (the map name lump and the 9 after it), SGRIDn, GSVIEWn,
    GSFLATn;
  - the patches of the wall textures of its sides, with the other texture
    of each switch (p_switch65.s) and the frames of the animated slime
    (SLADRIP1-3, p_spec65.s), and SKY1 (every map of episode 1 has sky);
  - the sprite lumps of every thing type that can be in the map: its map
    things (all skills), what they fire and drop, and the types of any map
    (the player, the weapons, puffs, blood, fog, rockets). Of the player's
    sprite only the frames that other things show (the dead player and
    the gibs of E1M3 and others).
The other lumps are shared (always in memory).

Usage: levelset.py WAD SRCDIR     prints the sizes of the sets.
"""

import os
import re
import struct
import sys

MAPS = range(1, 10)
MAP_LUMPS = 10                  # E1Mn and THINGS..BLOCKMAP
WEAPON_SPRITES = ('PUNG', 'PISG', 'PISF', 'SHTG', 'SHTF', 'CHGG', 'CHGF', 'MISG', 'MISF',
                  'SAWG', 'PLSG', 'PLSF', 'BFGG', 'BFGF')
# Thing types of any map: the player, what every weapon makes, the fog of
# teleports; rockets also come from the rocket cheat of p_tick65.s.
GLOBAL_TYPES = ('MT_PLAYER', 'MT_PUFF', 'MT_BLOOD', 'MT_TFOG', 'MT_ROCKET')
# P_KillMobj (p_inter65.s) drops, the missiles of the attacks (p_enemy65.s)
DROPS = {'MT_POSSESSED': 'MT_CLIP', 'MT_SHOTGUY': 'MT_SHOTGUN', 'MT_CHAINGUY': 'MT_CHAINGUN'}
MISSILES = {'MT_TROOP': 'MT_TROOPSHOT', 'MT_BRUISER': 'MT_BRUISERSHOT', 'MT_CYBORG': 'MT_ROCKET'}
SLIME = ('SLADRIP1', 'SLADRIP2', 'SLADRIP3')
SKY = 'SKY1'
# In single player the player's own sprite is never drawn: its thing is at
# the view point (tz = 0, R_ProjectSprite rejects it). Other things that use
# its sprite (MT_MISC62 the dead player, MT_MISC68-69 the gibs) keep their
# frames.
NOT_DRAWN = ('PLAY',)
PLAYER = 'MT_PLAYER'


def name8(b):
    return b.split(b'\0', 1)[0].decode('ascii').upper()


class GameWad:
    """The WAD of tools/wadtool.py (16-bit sizes, lumps may share data)."""

    def __init__(self, path=None, lumps=None):
        if lumps is not None:
            # [(name, data)]: the lumps of tools/wadtool.py before its save
            self.data = b''.join(d for _, d in lumps)
            self.lumps = []
            fp = 0
            for nm, d in lumps:
                self.lumps.append((nm, fp, len(d)))
                fp += len(d)
        else:
            d = open(path, 'rb').read()
            self.data = d
            n, _, ofs = struct.unpack_from('<hhi', d, 4)
            self.lumps = []
            for i in range(n):
                fp, sz, _, nm = struct.unpack_from('<IHH8s', d, ofs + 16 * i)
                self.lumps.append((name8(nm), fp, sz))
        self.names = [l[0] for l in self.lumps]

    def index(self, name, start=0):
        return self.names.index(name, start)

    def get(self, i):
        _, fp, sz = self.lumps[i]
        return self.data[fp:fp + sz]

    def between(self, a, b):
        return range(self.index(a) + 1, self.index(b))


class Info:
    """The states and thing types of src/iigs/info65.s."""

    def __init__(self, srcdir):
        src = open(os.path.join(srcdir, 'info65.s')).read()
        body = src[src.index('sprnames:'):src.index('states:')]
        self.sprnames = re.findall(r'\w{4}', ''.join(re.findall(r'"(\w+)"', body)))
        self.states = {}
        for m in re.finditer(r'STATE\s+CONST_SPR_(\w+),\s*(?:FULLBRIGHT\s*\+\s*)?(\d+),[^;]*?,\s*CONST_(S_\w+)'
                             r'\s*;\s*(S_\w+)', src):
            self.states[m.group(4)] = (m.group(1), m.group(3), int(m.group(2)))
        self.types = {}
        for m in re.finditer(r';\s*(MT_\w+)\n(.*?)\.space\s+INFO_SIZE', src, re.S):
            fields = {}
            for line in m.group(2).split('\n'):
                if ';' in line:
                    value, name = line.split(';', 1)
                    fields[name.strip()] = re.sub(r'\.(word|long|byte)', '', value).strip()
            self.types[m.group(1)] = fields
        self.by_ednum = {}
        for mt, f in self.types.items():
            try:
                ed = int(f['doomednum'])
            except (KeyError, ValueError):
                continue
            if ed > 0:
                self.by_ednum[ed] = mt

    def frames_of(self, mt):
        """The (sprite, frame) of all states that thing type mt can reach."""
        out = set()
        f = self.types[mt]
        for k in ('spawnstate', 'seestate', 'painstate', 'meleestate', 'missilestate',
                  'deathstate', 'xdeathstate', 'raisestate'):
            s = f.get(k, '0').replace('CONST_', '')
            seen = set()
            while s in self.states and s not in seen and s != 'S_NULL':
                seen.add(s)
                spr, nxt, frame = self.states[s]
                out.add((spr, frame))
                s = nxt
        return out

    def sprites_of(self, mt):
        """The sprites of all states that thing type mt can reach."""
        return set(spr for spr, _ in self.frames_of(mt))


class Textures:
    def __init__(self, wad):
        pn = wad.get(wad.index('PNAMES'))
        n = struct.unpack_from('<i', pn, 0)[0]
        pnames = [name8(pn[4 + 8 * i:12 + 8 * i]) for i in range(n)]
        t = wad.get(wad.index('TEXTURE1'))
        n = struct.unpack_from('<i', t, 0)[0]
        self.names = []
        self.patches = {}
        for off in struct.unpack_from(f'<{n}i', t, 4):
            tn = name8(t[off:off + 8])
            count = struct.unpack_from('<h', t, off + 12)[0]
            ps = []
            for j in range(count):
                _, _, p = struct.unpack_from('<hhh', t, off + 14 + 6 * j)
                ps.append(pnames[p])
            self.names.append(tn)
            self.patches[tn] = ps


def switch_pairs(srcdir):
    src = open(os.path.join(srcdir, 'p_switch65.s')).read()
    body = src[src.index('swnames:'):src.index('swnames_end:')]
    names = re.findall(r'"(\w+)"', body)
    pairs = {}
    for a, b in zip(names[0::2], names[1::2]):
        pairs[a] = b
        pairs[b] = a
    return pairs


class LevelSets:
    def __init__(self, wad, srcdir):
        self.wad = wad
        self.info = Info(srcdir)
        self.tex = Textures(wad)
        self.switch = switch_pairs(srcdir)
        spr = [i for i in wad.between('S_START', 'S_END') if wad.lumps[i][2]]
        self.sprite_lumps = {}
        for i in spr:
            self.sprite_lumps.setdefault(wad.names[i][:4], []).append(i)
        self.patch_lumps = {wad.names[i]: i for i in wad.between('P_START', 'P_END')
                            if wad.lumps[i][2]}

    def map_lumps(self, m):
        w = self.wad
        base = w.index(f'E1M{m}')
        out = list(range(base, base + MAP_LUMPS))
        for nm in (f'SGRID{m}', f'GSVIEW{m}', f'GSFLAT{m}'):
            out.append(w.index(nm))
        return out

    def textures(self, m):
        w = self.wad
        base = w.index(f'E1M{m}')
        sides = w.get(base + 3)
        tnames = self.tex.names
        used = set()
        for i in range(len(sides) // 7):
            _, _, top, bot, mid, _ = struct.unpack_from('<hbbbbb', sides, i * 7)
            for t in (top, bot, mid):
                if t > 0:
                    used.add(tnames[t])
        for t in list(used):
            if t in self.switch:
                used.add(self.switch[t])
            if t in SLIME:
                used.update(SLIME)
        used.add(SKY)
        return used

    def patches(self, m):
        out = set()
        for t in self.textures(m):
            for p in self.tex.patches[t]:
                if p in self.patch_lumps:
                    out.add(self.patch_lumps[p])
        return out

    def thing_types(self, m):
        w = self.wad
        th = w.get(w.index(f'E1M{m}') + 1)
        types = set(GLOBAL_TYPES)
        for i in range(len(th) // 8):
            _, _, typ, _, _ = struct.unpack_from('<hhhbb', th, i * 8)
            mt = self.info.by_ednum.get(typ)
            if mt:
                types.add(mt)
        for mt in list(types):
            for extra in (DROPS.get(mt), MISSILES.get(mt)):
                if extra and extra in self.info.types:
                    types.add(extra)
        return types

    def sprites(self, m):
        fams = set(WEAPON_SPRITES)
        frames = set()                  # the frames of NOT_DRAWN sprites to keep
        for mt in self.thing_types(m):
            fams |= self.info.sprites_of(mt)
            if mt != PLAYER:
                frames |= set(fr for fr in self.info.frames_of(mt) if fr[0] in NOT_DRAWN)
        fams -= set(NOT_DRAWN)
        out = set()
        for f in fams:
            out.update(self.sprite_lumps.get(f, []))
        for spr, frame in frames:
            letter = chr(ord('A') + frame)
            for i in self.sprite_lumps.get(spr, []):
                nm = self.wad.names[i]
                if nm[4] == letter or (len(nm) >= 8 and nm[6] == letter):
                    out.add(i)
        return out, fams

    def level(self, m):
        spr, fams = self.sprites(m)
        return sorted(set(self.map_lumps(m)) | self.patches(m) | spr)


def main():
    wad = GameWad(sys.argv[1])
    ls = LevelSets(wad, sys.argv[2])
    per = {}
    allmap = set()
    for m in MAPS:
        lumps = ls.level(m)
        per[m] = lumps
        allmap |= set(lumps)
    size = lambda idx: sum(sz for fp, sz in {(wad.lumps[i][1], wad.lumps[i][2]) for i in idx})
    shared = [i for i in range(len(wad.lumps)) if i not in allmap]
    print(f'shared lumps: {len(shared)}, {size(shared):,} bytes')
    for m in MAPS:
        ml = ls.map_lumps(m)
        pt = ls.patches(m)
        sp, fams = ls.sprites(m)
        print(f'E1M{m}: map {size(ml):7,}  walls {size(pt):8,} ({len(pt)})  sprites {size(sp):8,} '
              f'({len(fams)} families)  total {size(per[m]):9,} = {size(per[m]) / 65536:.2f} banks')


if __name__ == '__main__':
    main()


def patch_info(wad, i):
    """width, the column offsets of patch lump i."""
    d = wad.get(i)
    w = struct.unpack_from('<h', d, 0)[0]
    return w, [struct.unpack_from('<I', d, 8 + 4 * x)[0] for x in range(w)], d


def texture_defs(wad):
    """name -> (width, height, [(originx, originy, patch name)])"""
    pn = wad.get(wad.index('PNAMES'))
    n = struct.unpack_from('<i', pn, 0)[0]
    pnames = [name8(pn[4 + 8 * i:12 + 8 * i]) for i in range(n)]
    t = wad.get(wad.index('TEXTURE1'))
    n = struct.unpack_from('<i', t, 0)[0]
    out = {}
    for off in struct.unpack_from(f'<{n}i', t, 4):
        tn = name8(t[off:off + 8])
        w, h, count = struct.unpack_from('<hhh', t, off + 8)
        ps = [struct.unpack_from('<hhh', t, off + 14 + 6 * j) for j in range(count)]
        out[tn] = (w, h, [(ox, oy, pnames[p]) for ox, oy, p in ps])
    return out


def column_bytes(wad, ls, m, textures=None):
    """The column memory of R_MakeLevelColumns (src/iigs/r_data65.s) for the
    textures of map m: a table of (widthmask + 1) * 4 bytes for each, and a
    composed column of height bytes for each column of an overlapped
    texture that is not one full post of one patch. Allocations do not
    cross a bank (columnAlloc); the start is COLDIR + 0x400."""
    defs = texture_defs(wad)
    texs = textures if textures is not None else ls.textures(m)
    pos = 0x400
    def alloc(n):
        nonlocal pos
        if (pos & 0xffff) + n > 0x10000:
            pos = (pos | 0xffff) + 1
        a = pos
        pos += n
        return a
    for tn in sorted(texs, key=lambda t: ls.tex.names.index(t)):
        if tn == SKY:
            continue
        w, h, ps = defs[tn]
        wm = 1
        while wm * 2 <= w:
            wm *= 2
        alloc(wm * 4)
        pinfo = []
        for ox, oy, p in ps:
            if p in ls.patch_lumps:
                pw, cofs, d = patch_info(wad, ls.patch_lumps[p])
                pinfo.append((ox, oy, pw, cofs, d))
            else:
                pinfo.append((ox, oy, 0, [], b''))
        overlapped = any(a[0] < b[0] + b[2] and b[0] < a[0] + a[2]
                         for i, a in enumerate(pinfo) for b in pinfo[i + 1:])
        if not overlapped:
            continue
        for xc in range(wm):
            covers = [(ox, oy, pw, cofs, d) for ox, oy, pw, cofs, d in pinfo if 0 <= xc - ox < pw]
            if len(covers) == 1:
                ox, oy, pw, cofs, d = covers[0]
                c = cofs[xc - ox]
                if oy == 0 and d[c] == 0 and d[c + 1] >= h and d[c + d[c + 1] + 4] == 0xff:
                    continue
            alloc(h)
    return pos
