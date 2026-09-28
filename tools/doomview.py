#!/usr/bin/env python3
"""A small Doom 3D view renderer for the color study. Pure Python.

It renders one view of a map of DOOM1.WAD at the IIgs view size (160 x 168
Doom pixels, low detail: horizontal projection 80, vertical 160, center
row 84). It does not apply light. For each pixel it keeps:
  C  the Doom color (texel) before light; for planes the flat texel
  S  for plane pixels the solid color of the flat (tools/wadtool.py
     average_color, as the IIgs build), else the same as C
  L  the sector light (0-255)
  K  the kind: WALL, PLANE, SPRITE, BRIGHT (full bright sprite, sky), PSPR
  D  the wall contrast step: -1 (wall along x), +1 (wall along y), 0
  Z  the depth (distance along the view direction, map units)
shade() then applies a light model:
  'doom' Doom's light: sector light and distance fade (r_main.c
         R_InitLightTables, scalelight and zlight, low detail)
  'iigs' the IIgs build now: sector light only (src/iigs/r_bsp65.s
         R_LoadColorMap, cm = ((256 - L') >> 2) - 24, L' = L -+ 16)
"""
import math
import os
import re
import struct

W, H = 160, 168
CX, CY = 80, 84
PROJX, PROJY = 80.0, 160.0
NEAR = 1.0
INF = 1e30

WALL, PLANE, SPRITE, BRIGHT, PSPR = 0, 1, 2, 3, 4

ML_DONTPEGTOP, ML_DONTPEGBOTTOM, ML_TWOSIDED = 8, 16, 4
HANGING = {49, 50, 51, 52, 53, 59, 60, 61, 62, 63}


def name8(b):
    return b.split(b'\0')[0].decode('ascii', 'replace').upper()


class Wad:
    def __init__(self, path):
        d = open(path, 'rb').read()
        _, n, off = struct.unpack_from('<4sii', d, 0)
        self.lumps = []
        for i in range(n):
            fp, sz, nm = struct.unpack_from('<ii8s', d, off + 16 * i)
            self.lumps.append((name8(nm), d[fp:fp + sz]))
        self.byname = {}
        for i, (nm, _) in enumerate(self.lumps):
            self.byname.setdefault(nm, i)

    def get(self, name):
        return self.lumps[self.byname[name]][1]

    def index(self, name):
        return self.byname[name]

    def between(self, a, b):
        i, j = self.index(a), self.index(b)
        return [self.lumps[k] for k in range(i + 1, j)]


def decode_patch(data):
    """Columns of a patch: list of dict row -> color; and w, h, lo, to."""
    w, h, lo, to = struct.unpack_from('<hhhh', data, 0)
    cols = []
    for x in range(w):
        p = struct.unpack_from('<I', data, 8 + 4 * x)[0]
        col = {}
        while data[p] != 0xff:
            top, length = data[p], data[p + 1]
            for y in range(length):
                col[top + y] = data[p + 3 + y]
            p += length + 4
        cols.append(col)
    return w, h, lo, to, cols


class Resources:
    def __init__(self, wadpath, infopath):
        self.wad = wad = Wad(wadpath)
        pp = wad.get('PLAYPAL')
        self.playpals = [[tuple(pp[p * 768 + i * 3:p * 768 + i * 3 + 3]) for i in range(256)]
                         for p in range(14)]
        self.pal = self.playpals[0]
        cm = wad.get('COLORMAP')
        self.colormap = [cm[i * 256:(i + 1) * 256] for i in range(34)]
        self.flats = {nm: d for nm, d in wad.between('F_START', 'F_END') if len(d) == 4096}
        self._patches = {}
        self._textures = None
        self.sprites = {}
        for nm, d in wad.between('S_START', 'S_END'):
            if not d:
                continue
            self.sprites.setdefault((nm[:4], nm[4], nm[5]), (nm, False))
            if len(nm) == 8:
                self.sprites.setdefault((nm[:4], nm[6], nm[7]), (nm, True))
        self.read_info(infopath)

    def patch(self, name):
        if name not in self._patches:
            self._patches[name] = decode_patch(self.wad.get(name))
        return self._patches[name]

    def textures(self):
        """name -> (width, height, columns (list of lists, None = hole))."""
        if self._textures is not None:
            return self._textures
        wad = self.wad
        pn = wad.get('PNAMES')
        pnames = [name8(pn[4 + 8 * i:12 + 8 * i]) for i in range(struct.unpack_from('<i', pn, 0)[0])]
        out = {}
        for lump in ('TEXTURE1', 'TEXTURE2'):
            if lump not in wad.byname:
                continue
            t = wad.get(lump)
            n = struct.unpack_from('<i', t, 0)[0]
            for off in struct.unpack_from(f'<{n}i', t, 4):
                tname = name8(t[off:off + 8])
                w, h = struct.unpack_from('<hh', t, off + 12)
                count = struct.unpack_from('<h', t, off + 20)[0]
                cols = [[None] * h for _ in range(w)]
                for j in range(count):
                    ox, oy, pi = struct.unpack_from('<hhh', t, off + 22 + 10 * j)
                    try:
                        pw, ph, _, _, pcols = self.patch(pnames[pi])
                    except KeyError:
                        continue
                    for px in range(pw):
                        x = ox + px
                        if 0 <= x < w:
                            for py, c in pcols[px].items():
                                y = oy + py
                                if 0 <= y < h:
                                    cols[x][y] = c
                out[tname] = (w, h, cols)
        self._textures = out
        return out

    def read_info(self, path):
        """The sprite names, the states and the thing types of
        src/iigs/info65.s (path: the directory src/iigs)."""
        src = open(os.path.join(path, 'info65.s')).read()
        body = src[src.index('sprnames:'):src.index('states:')]
        self.sprnames = re.findall(r'\w{4}', ''.join(re.findall(r'"(\w+)"', body)))
        self.states = {}
        for sm in re.finditer(r'STATE\s+CONST_SPR_(\w+),\s*(FULLBRIGHT \+ )?(\d+),[^;]*;\s*(S_\w+)', src):
            frame = int(sm.group(3)) + (0x8000 if sm.group(2) else 0)
            self.states[sm.group(4)] = (sm.group(1), frame)
        self.things = {}
        for mm in re.finditer(r';\s*(MT_\w+)\n(.*?)\.space\s+INFO_SIZE', src, re.S):
            fields = {}
            for line in mm.group(2).split('\n'):
                if ';' in line:
                    value, name = line.split(';', 1)
                    fields[name.strip()] = value.replace('.word', '').replace('.long', '').replace(
                        '.byte', '').strip()
            try:
                ednum = int(fields['doomednum'])
            except (KeyError, ValueError):
                continue
            spawn = fields['spawnstate'].replace('CONST_', '')
            height = int(re.match(r'(\d+)', fields['height']).group(1))
            shadow = 'MF_SHADOW' in mm.group(2)
            if ednum > 0 and spawn in self.states:
                spr, frame = self.states[spawn]
                self.things[ednum] = (spr, frame & 0x7fff, bool(frame & 0x8000), height, shadow)

    def flat_color_table(self, mapname):
        """The solid color of each flat, as tools/wadtool.py average_color:
        the RMS mean of the texels, then the nearest Doom color that no
        other flat of the map took yet (in the order the sectors use them)."""
        base = self.wad.index(mapname)
        sec = self.wad.lumps[base + 8][1]
        pal = self.pal
        available = {i: pal[i] for i in range(256)}
        colors = {}
        for i in range(len(sec) // 26):
            for o in (4, 12):
                fname = name8(sec[i * 26 + o:i * 26 + o + 8])
                if fname in colors or fname == 'F_SKY1' or fname.startswith('NUKAGE'):
                    continue
                src = self.flats[fname]
                n = len(src)
                r = int(math.sqrt(sum(pal[b][0] ** 2 for b in src) // n))
                g = int(math.sqrt(sum(pal[b][1] ** 2 for b in src) // n))
                b = int(math.sqrt(sum(pal[b][2] ** 2 for b in src) // n))
                best = min(available, key=lambda k: (available[k][0] - r) ** 2 +
                           (available[k][1] - g) ** 2 + (available[k][2] - b) ** 2)
                del available[best]
                colors[fname] = best
        colors['NUKAGE'] = 122
        return colors


class Map:
    def __init__(self, res, name):
        wad = res.wad
        base = wad.index(name)
        L = lambda k: wad.lumps[base + k][1]
        d = L(4)
        self.verts = [struct.unpack_from('<hh', d, i * 4) for i in range(len(d) // 4)]
        d = L(2)
        self.lines = [struct.unpack_from('<hhhhhhh', d, i * 14) for i in range(len(d) // 14)]
        d = L(3)
        self.sides = []
        for i in range(len(d) // 30):
            xo, yo = struct.unpack_from('<hh', d, i * 30)
            up, lo, mid = (name8(d[i * 30 + o:i * 30 + o + 8]) for o in (4, 12, 20))
            sec = struct.unpack_from('<h', d, i * 30 + 28)[0]
            self.sides.append((xo, yo, up, lo, mid, sec))
        d = L(8)
        self.sectors = []
        for i in range(len(d) // 26):
            fh, ch = struct.unpack_from('<hh', d, i * 26)
            fp, cp = name8(d[i * 26 + 4:i * 26 + 12]), name8(d[i * 26 + 12:i * 26 + 20])
            light, special, tag = struct.unpack_from('<hhh', d, i * 26 + 20)
            self.sectors.append([fh, ch, fp, cp, light])
        d = L(5)
        self.segs = [struct.unpack_from('<hhhhhh', d, i * 12) for i in range(len(d) // 12)]
        d = L(6)
        self.ssectors = [struct.unpack_from('<hh', d, i * 4) for i in range(len(d) // 4)]
        d = L(7)
        self.nodes = [struct.unpack_from('<hhhh8h HH', d, i * 28) for i in range(len(d) // 28)]
        d = L(1)
        self.things = [struct.unpack_from('<hhhhh', d, i * 10) for i in range(len(d) // 10)]
        # the sector of each subsector
        self.ss_sector = []
        for cnt, first in self.ssectors:
            v1, v2, ang, li, side, off = self.segs[first]
            line = self.lines[li]
            self.ss_sector.append(self.sides[line[5 + side]][5])

    def point_subsector(self, x, y):
        n = len(self.nodes) - 1
        while True:
            nx, ny, ndx, ndy = self.nodes[n][:4]
            side = 0 if (y - ny) * ndx < ndy * (x - nx) else 1
            child = self.nodes[n][12 + side]
            if child & 0x8000:
                return child & 0x7fff
            n = child

    def point_sector(self, x, y):
        return self.ss_sector[self.point_subsector(x, y)]


class View:
    """The render of one view, without light."""

    def __init__(self, res, mp, flatcolors, x, y, angle_deg, z=None, things=True, weapon='PISG',
                 skill_bit=2, doom_sky=True):
        self.res, self.mp = res, mp
        self.vx, self.vy = float(x), float(y)
        a = math.radians(angle_deg)
        self.angle = a
        self.ca, self.sa = math.cos(a), math.sin(a)
        sec = mp.sectors[mp.point_sector(x, y)]
        self.vz = float(z) if z is not None else sec[0] + 41.0
        self.player_light = sec[4]
        n = W * H
        self.C = [0] * n
        self.S = [0] * n
        self.L = [0] * n
        self.K = [0] * n
        self.D = [0] * n
        self.Z = [INF] * n
        self.ZS = [INF] * n
        self.ceilclip = [-1] * W
        self.floorclip = [H] * W
        self.open_cols = W
        self.masked = []
        self.flatcolors = flatcolors
        self.tex = res.textures()
        self.sky = self.tex.get('SKY1')
        self.render_bsp(len(mp.nodes) - 1)
        if things:
            self.add_things(skill_bit)
        self.draw_masked()
        if weapon:
            self.draw_weapon(weapon)

    # ---- BSP
    def render_bsp(self, n):
        stack = [n]
        mp = self.mp
        while stack and self.open_cols > 0:
            n = stack.pop()
            if n & 0x8000:
                self.render_subsector(n & 0x7fff)
                continue
            node = mp.nodes[n]
            nx, ny, ndx, ndy = node[:4]
            side = 0 if (self.vy - ny) * ndx < ndy * (self.vx - nx) else 1
            # push the far side first so the near side pops first
            stack.append(node[12 + (side ^ 1)])
            stack.append(node[12 + side])

    def render_subsector(self, ss):
        cnt, first = self.mp.ssectors[ss]
        for i in range(first, first + cnt):
            self.render_seg(self.mp.segs[i])

    def to_view(self, px, py):
        dx, dy = px - self.vx, py - self.vy
        return dx * self.ca + dy * self.sa, dx * self.sa - dy * self.ca

    def render_seg(self, seg):
        mp = self.mp
        v1i, v2i, ang, li, side, off = seg
        x1, y1 = mp.verts[v1i]
        x2, y2 = mp.verts[v2i]
        ex, ey = x2 - x1, y2 - y1
        # back face: the viewer must be on the right of v1 -> v2
        if ex * (self.vy - y1) - ey * (self.vx - x1) >= 0:
            return
        f1, s1 = self.to_view(x1, y1)
        f2, s2 = self.to_view(x2, y2)
        if f1 < NEAR and f2 < NEAR:
            return
        if f1 < NEAR:
            t = (NEAR - f1) / (f2 - f1)
            s1 += t * (s2 - s1)
            f1 = NEAR
        elif f2 < NEAR:
            t = (NEAR - f2) / (f1 - f2)
            s2 += t * (s1 - s2)
            f2 = NEAR
        sx1 = CX + s1 / f1 * PROJX
        sx2 = CX + s2 / f2 * PROJX
        if sx1 >= sx2:
            return
        xa = max(0, math.ceil(sx1 - 0.5))
        xb = min(W - 1, math.ceil(sx2 - 0.5) - 1)
        if xa > xb:
            return
        ceilclip, floorclip = self.ceilclip, self.floorclip
        if all(ceilclip[x] >= floorclip[x] - 1 for x in range(xa, xb + 1)):
            return
        line = mp.lines[li]
        lv1, lv2, flags = line[0], line[1], line[2]
        sd = mp.sides[line[5 + side]]
        front = mp.sectors[sd[5]]
        back = None
        if flags & ML_TWOSIDED and line[5 + (side ^ 1)] != -1:
            back = mp.sectors[mp.sides[line[5 + (side ^ 1)]][5]]
        # the contrast step of Doom (v1, v2 of the seg)
        dstep = -1 if y1 == y2 else (1 if x1 == x2 else 0)
        light = front[4]
        vz = self.vz
        fc, ff = front[1], front[0]
        seglen = math.hypot(ex, ey)
        u0 = off + sd[0]
        tex = self.tex
        sky_ceiling = front[3] == 'F_SKY1'
        markceiling = fc > vz or sky_ceiling
        markfloor = ff < vz
        top_tex = bot_tex = mid_tex = m = None
        worldtop = fc
        if back is None:
            mid_tex = tex.get(sd[4])
            if mid_tex:
                mid_ref = (ff + mid_tex[1] if flags & ML_DONTPEGBOTTOM else fc) + sd[1]
        else:
            bc, bf = back[1], back[0]
            if sky_ceiling and back[3] == 'F_SKY1':
                worldtop = bc
            if bc < worldtop:
                top_tex = tex.get(sd[2])
                if top_tex:
                    top_ref = (fc if flags & ML_DONTPEGTOP else bc + top_tex[1]) + sd[1]
            if bf > ff:
                bot_tex = tex.get(sd[3])
                if bot_tex:
                    bot_ref = (fc if flags & ML_DONTPEGBOTTOM else bf) + sd[1]
            m = tex.get(sd[4])
            if m:
                mref = (max(ff, bf) + m[1] if flags & ML_DONTPEGBOTTOM else min(fc, bc)) + sd[1]
        ox, oy = x1 - self.vx, y1 - self.vy
        ca, sa = self.ca, self.sa
        zends = []
        for xe in (xa, xb):
            t = (xe + 0.5 - CX) / PROJX
            ddx, ddy = ca + t * sa, sa - t * ca
            dd = ex * ddy - ddx * ey
            zends.append(max(NEAR, (ex * oy - ox * ey) / dd) if dd else NEAR)
        self.zseg = 2.0 / (1.0 / zends[0] + 1.0 / zends[1])
        C, S, Lb, K, D, Z = self.C, self.S, self.L, self.K, self.D, self.Z
        fcol = self.flatcolors
        for x in range(xa, xb + 1):
            ct, fb = ceilclip[x], floorclip[x]
            if ct >= fb - 1:
                continue
            t = (x + 0.5 - CX) / PROJX
            dx, dy = ca + t * sa, sa - t * ca
            det = ex * dy - dx * ey
            if det == 0:
                continue
            z = (ex * oy - ox * ey) / det
            mpos = (dx * oy - dy * ox) / det
            if z < NEAR:
                z = NEAR
            k = PROJY / z
            iscale = z / PROJY
            u = u0 + mpos * seglen
            topfrac = CY - (worldtop - vz) * k
            botfrac = CY - (ff - vz) * k
            yl = math.ceil(topfrac)
            if yl < ct + 1:
                yl = ct + 1
            if markceiling:
                top, bottom = ct + 1, min(yl - 1, fb - 1)
                if top <= bottom:
                    self.plane_rows(x, top, bottom, front, True, dx, dy)
            yh = math.floor(botfrac)
            if yh >= fb:
                yh = fb - 1
            if markfloor:
                top, bottom = max(yh + 1, ct + 1), fb - 1
                if top <= bottom:
                    self.plane_rows(x, top, bottom, front, False, dx, dy)
            if back is None:
                if mid_tex:
                    self.wall_rows(x, yl, yh, mid_tex, u, mid_ref, z, iscale, light, dstep)
                ceilclip[x], floorclip[x] = H, -1
                self.open_cols -= 1
                continue
            if top_tex:
                mid = math.floor(CY - (bc - vz) * k)
                if mid >= fb:
                    mid = fb - 1
                if mid >= yl:
                    self.wall_rows(x, yl, mid, top_tex, u, top_ref, z, iscale, light, dstep)
                    ceilclip[x] = mid
                else:
                    ceilclip[x] = yl - 1
            elif markceiling:
                ceilclip[x] = yl - 1
            if bot_tex:
                mid = math.ceil(CY - (bf - vz) * k)
                if mid <= ceilclip[x]:
                    mid = ceilclip[x] + 1
                if mid <= yh:
                    self.wall_rows(x, mid, yh, bot_tex, u, bot_ref, z, iscale, light, dstep)
                    floorclip[x] = mid
                else:
                    floorclip[x] = yh + 1
            elif markfloor:
                floorclip[x] = yh + 1
            if m:
                self.masked.append((z, x, m, u, mref, iscale, ceilclip[x], floorclip[x], light, dstep, self.zseg))
            if ceilclip[x] >= floorclip[x] - 1:
                self.open_cols -= 1

    def wall_rows(self, x, y0, y1, tex, u, ref, z, iscale, light, dstep):
        w, h, cols = tex
        col = cols[int(math.floor(u)) % w]
        C, S, Lb, K, D, Z = self.C, self.S, self.L, self.K, self.D, self.Z
        vz = self.vz
        tm = ref - vz
        for y in range(y0, y1 + 1):
            v = tm + (y - CY) * iscale
            c = col[int(math.floor(v)) % h]
            if c is None:
                c = 0
            i = y * W + x
            C[i] = S[i] = c
            Lb[i] = light
            K[i] = WALL
            D[i] = dstep
            Z[i] = z
            self.ZS[i] = self.zseg

    def plane_rows(self, x, y0, y1, sec, ceiling, dx, dy):
        C, S, Lb, K, D, Z = self.C, self.S, self.L, self.K, self.D, self.Z
        pic = sec[3] if ceiling else sec[2]
        h = sec[1] if ceiling else sec[0]
        light = sec[4]
        vz = self.vz
        if pic == 'F_SKY1':
            sky = self.sky
            if sky:
                sw, sh, scol = sky
                # r_sky.c: column (viewangle + xtoviewangle) >> 22, texturemid 100
                ang = (self.angle - math.atan((x + 0.5 - CX) / PROJX)) % (2 * math.pi)
                col = scol[int(ang / (2 * math.pi) * 1024) % sw]
                for y in range(y0, y1 + 1):
                    c = col[(100 + y - CY) % sh]
                    i = y * W + x
                    C[i] = S[i] = c if c is not None else 0
                    Lb[i] = 255
                    K[i] = BRIGHT
                    D[i] = 0
                    Z[i] = INF
            return
        flat = self.res.flats.get(pic)
        solid = self.flatcolors.get('NUKAGE' if pic.startswith('NUKAGE') else pic, 0)
        dh = h - vz
        for y in range(y0, y1 + 1):
            dyr = (y + 0.5 - CY)
            if dyr == 0:
                continue
            z = -dh * PROJY / dyr
            if z <= 0:
                z = 1e-3
            wx = self.vx + z * dx
            wy = self.vy + z * dy
            i = y * W + x
            C[i] = flat[((int(math.floor(-wy)) & 63) << 6) + (int(math.floor(wx)) & 63)] if flat else solid
            S[i] = solid
            Lb[i] = light
            K[i] = PLANE
            D[i] = 0
            Z[i] = z

    # ---- things, masked walls, weapon
    def add_things(self, skill_bit):
        res, mp = self.res, self.mp
        for tx, ty, tang, ttype, tflags in mp.things:
            # starts, deathmatch starts, teleport landings (no sprite in the game)
            if ttype in (1, 2, 3, 4, 11, 14) or not (tflags & skill_bit) or tflags & 16:
                continue
            info = res.things.get(ttype)
            if not info:
                continue
            spr, frame, bright, height, shadow = info
            if shadow:
                continue
            f, s = self.to_view(tx, ty)
            if f < 4:
                continue
            sec = mp.sectors[mp.point_sector(tx, ty)]
            letter = chr(ord('A') + frame)
            ang_to = math.degrees(math.atan2(ty - self.vy, tx - self.vx))
            rot = int(((ang_to - tang + 202.5) % 360) // 45) + 1
            lump = res.sprites.get((spr, letter, '0')) or res.sprites.get((spr, letter, str(rot)))
            if not lump:
                continue
            tz = sec[1] - height if ttype in HANGING else sec[0]
            self.masked.append((f, 'sprite', lump, s, tz, sec[4], bright))

    def draw_masked(self):
        self.masked.sort(key=lambda it: -it[0])
        for it in self.masked:
            if it[1] == 'sprite':
                self.draw_sprite(*it)
            else:
                self.draw_masked_col(*it)

    def draw_masked_col(self, z, x, tex, u, ref, iscale, ctop, fbot, light, dstep, zseg):
        w, h, cols = tex
        col = cols[int(math.floor(u)) % w]
        tm = ref - self.vz
        C, S, Lb, K, D, Z = self.C, self.S, self.L, self.K, self.D, self.Z
        for y in range(max(0, ctop + 1), min(H - 1, fbot - 1) + 1):
            v = tm + (y - CY) * iscale
            if v < 0 or v >= h:
                continue
            c = col[int(v)]
            i = y * W + x
            if c is None or Z[i] < z:
                continue
            C[i] = S[i] = c
            Lb[i] = light
            K[i] = WALL
            D[i] = dstep
            Z[i] = z
            self.ZS[i] = zseg

    def draw_sprite(self, f, _, lump, s, tz, light, bright):
        name, flip = lump
        w, h, lo, to, cols = self.res.patch(name)
        xs = PROJX / f
        left = s - lo
        x1 = math.ceil(CX + left * xs - 0.5)
        x2 = math.ceil(CX + (left + w) * xs - 0.5) - 1
        tm = tz + to - self.vz
        iscale = f / PROJY
        C, S, Lb, K, D, Z = self.C, self.S, self.L, self.K, self.D, self.Z
        for x in range(max(0, x1), min(W - 1, x2) + 1):
            u = int(math.floor((x + 0.5 - CX) / xs - left))
            if not 0 <= u < w:
                continue
            col = cols[w - 1 - u if flip else u]
            if not col:
                continue
            y0 = math.ceil(CY - tm / iscale)
            for y in range(max(0, y0), H):
                v = int(math.floor(tm + (y - CY) * iscale))
                if v >= h:
                    break
                c = col.get(v)
                if c is None:
                    continue
                i = y * W + x
                if Z[i] < f:
                    continue
                C[i] = S[i] = c
                Lb[i] = light
                K[i] = BRIGHT if bright else SPRITE
                D[i] = 0
                Z[i] = f

    def draw_weapon(self, spr):
        name, flip = self.res.sprites[(spr, 'A', '0')]
        w, h, lo, to, cols = self.res.patch(name)
        # r_things.c R_DrawPSprite: sx 1, sy WEAPONTOP 32, pspritescale 0.5
        # (low detail), one texel per row, BASEYCENTER 100
        tx = 1 - 160 - lo
        x1 = math.floor(CX + tx * 0.5)
        tm = 100.5 - (32 - to)
        C, S, Lb, K, D, Z = self.C, self.S, self.L, self.K, self.D, self.Z
        for x in range(max(0, x1), min(W, x1 + math.ceil(w * 0.5))):
            u = int((x - x1) * 2)
            if not 0 <= u < w:
                continue
            col = cols[u]
            for y in range(H):
                v = int(math.floor(tm + (y - CY)))
                c = col.get(v)
                if c is None:
                    continue
                i = y * W + x
                C[i] = S[i] = c
                Lb[i] = self.player_light
                K[i] = PSPR
                D[i] = 0
                Z[i] = 0.0


# ---- light models

def doom_level(light, kind, dstep, z):
    """Colormap number of Doom (r_main.c), low detail, extralight 0."""
    if kind == BRIGHT:
        return 0
    lightnum = light >> 4
    if kind == WALL:
        lightnum += dstep
    lightnum = max(0, min(15, lightnum))
    startmap = (15 - lightnum) * 4
    if kind == PLANE:
        j = min(127, int(z) >> 4)
        level = startmap - (160 // (j + 1)) // 2
    elif kind == PSPR:
        level = startmap - 47 // 2
    else:
        j = min(47, int(2560.0 / max(z, 1e-3)))
        level = startmap - j // 2
    return max(0, min(31, level))


PLANE_SHIFT = 10


def fast_level(light, kind, dstep, z, zs):
    """No per-column or per-row work: walls take the depth of their seg,
    sprites their own depth, floors and ceilings startmap - PLANE_SHIFT."""
    if kind == BRIGHT:
        return 0
    lightnum = light >> 4
    if kind == WALL:
        lightnum += dstep
    lightnum = max(0, min(15, lightnum))
    startmap = (15 - lightnum) * 4
    if kind == PLANE:
        level = startmap - PLANE_SHIFT
    elif kind == PSPR:
        level = startmap - 47 // 2
    else:
        j = min(47, int(2560.0 / max(zs if kind == WALL else z, 1e-3)))
        level = startmap - j // 2
    return max(0, min(31, level))


def iigs_level(light, kind, dstep, z):
    """Colormap number of the IIgs build (src/iigs/r_bsp65.s R_LoadColorMap)."""
    if kind == BRIGHT:
        return 0
    if kind == WALL:
        light += 16 * dstep
    cm = ((256 - light) >> 2) - 24
    return max(0, min(31, cm))


def shade(view, res, model='doom', solid=False, level_fn=None):
    fn = level_fn or {'doom': doom_level, 'iigs': iigs_level}[model]
    cmap = res.colormap
    src = view.S if solid else view.C
    out = bytearray(W * H)
    for i in range(W * H):
        out[i] = cmap[fn(view.L[i], view.K[i], view.D[i], view.Z[i])][src[i]]
    return out
