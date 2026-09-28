#!/usr/bin/env python3
"""Colors of the 3D view for the Apple IIgs build.

No part of this adds work to a frame. It only makes tables.

For each map E1M1-E1M9 the selector sees what the player sees on the map
(GSVIEW0: all maps, each with the same weight):
  world     VIEWS random views of the map (tools/doomview.py): the walls,
            the floors and ceilings, the sky and the placed things as they
            stand, counted by the lit Doom color of each pixel as the game
            draws it (doomview.fast_level: one light for each seg, sprite
            and plane; a plane has one color, its GSFLAT color)
  monsters  every frame of each monster type placed in the map (walk,
            attack, pain, death, the corpse)
  weapon    the weapons the player can have on the map (from the maps
            before it, and the shotgun that shotgun guys drop), and their
            flashes, at the weapon light
  items     the items and decorations placed in the map, all their frames
            (with the dead players and the pools of blood)
  gore      the blood of hits (BLUD)
  fx        bullet puffs, imp and baron fireballs, rockets, barrel
            explosions, teleport fog, as the map has them
Sprites are lit as the game lights them: the sector light of each placed
thing (the monster sectors for blood, puffs and fireballs), at the
distances DISTANCES (weight 1 / distance); the weapon at startmap - 23.
Nothing is forced: a color family gets palette colors only when the map
shows it.

Weights: each group is a histogram of lit Doom colors with the sum 1; in
the sprite groups each share is raised to the power ALPHA_SPRITES (the
small but salient colors of a sprite, such as blood and eyes, count more);
then the group weights of CFG; each color x (1 + CHROMA x its OKLab chroma).

Color distance, OKLab x 100, split into the lightness, chroma and hue
differences: error = sqrt(dL^2 + (ERR_KC dC)^2 + (ERR_KH dH)^2); noise of two
colors side by side = sqrt(dL^2 + (NOISE_KC dC)^2 + (HUE_K dH)^2), so a hue
mix (for example green and orange for yellow) is loud noise, a lightness
step of one hue is quiet. Mixes are means in linear light.

Palette (16 colors, 12-bit $0RGB; entry 0 black, entry 1 white $DDD): a
k-means start in OKLab, then moves of one color (+-1, +-2 in a channel, or a
jump to a badly served color) while the weighted cost of the targets falls;
the cost of a target is the least of error + lam x noise over the mixes of
one color or two colors (50/50, 75/25); here the error of a large miss
counts more (d + d^2 / ERR_D0), so that no color family the map shows is
left without a palette color.

Mixes: each Doom color gets the mix of 4 palette colors (a, b, c, d by
lightness) with the least error + lam x noise (noise: the largest noise
of two of the colors); byte A = a d on even rows, byte B = c b on odd rows,
so each 2x2 block of screen pixels has all four. lam is the mean of the
noise weights of the uses of the color (LAM): walls low (a mix keeps the
texture detail), planes, sky and sprites high (a large plain area or a
small sprite detail needs a quiet mix: blood shows as red dots).

Lumps:
  GSVIEWn  14 x 16 x 2  the colors for the 14 PLAYPAL palettes, $0RGB
           256          the best pair of each Doom color (the format of
                        today, for text and patches drawn on the view)
           256          byte A of each Doom color
           256          byte B of each Doom color
  GSFLATn  N            the Doom color of each flat of the map; flats 0-2
                        are NUKAGE1-3. The sector data keeps one number
                        for each flat (the game logic compares them:
                        p_floor.c stairs).
  and a list of the flat names of GSFLATn (for the sector data).

Usage: gsview.py DOOM1.WAD SRCDIR OUTDIR [MAP...]   (SRCDIR: src/iigs, for info65.s)
GSVIEW_CACHE=DIR keeps the palettes (palN.txt) and uses them again.
"""
import math
import multiprocessing
import os
import random
import struct
import sys
from collections import Counter, defaultdict

import doomview as V
from gscolor import align4

LAMBDA = 0.08            # the pairs (the old format)
CHROMA = 1.5             # dist(): the old OKLab distance (flat colors)
NUKAGE = ('NUKAGE1', 'NUKAGE2', 'NUKAGE3')
LEVEL = V.fast_level     # the light of the game: once per seg, per plane, per sprite

# the settings (chosen from contact sheets of each map)
CFG = {
    'views': 96,
    # the group weights
    'world': 0.66, 'monsters': 0.12, 'weapon': 0.10, 'items': 0.05, 'gore': 0.035, 'fx': 0.035,
    'alpha_sprites': 0.75,
    'chroma': 2.0,
    # the noise weight of each use
    'lam_wall': 0.08, 'lam_plane': 0.30, 'lam_sky': 0.20, 'lam_thing': 0.35, 'lam_monsters': 0.35,
    'lam_weapon': 0.35, 'lam_items': 0.35, 'lam_gore': 0.35, 'lam_fx': 0.35,
    'err_kc': 2.0, 'err_kh': 2.0, 'err_d0': 20.0, 'noise_kc': 2.0, 'hue_k': 6.0,
    'rounds': 30,
}
# per map changes of CFG (after a look at the contact sheets)
MAP_CFG = {}

WEAPON_THINGS = {2001: 'SHOTGUN', 2002: 'CHAINGUN', 2003: 'LAUNCHER', 2005: 'SAW'}
WEAPON_SPRITES = {
    'FIST': (('PUNG', 'ABCD'),),
    'PISTOL': (('PISG', 'ABC'), ('PISF', 'A')),
    'SHOTGUN': (('SHTG', 'ABCDE'), ('SHTF', 'AB')),
    'CHAINGUN': (('CHGG', 'AB'), ('CHGF', 'AB')),
    'LAUNCHER': (('MISG', 'AB'), ('MISF', 'ABCD')),
    'SAW': (('SAWG', 'ABCD'),),
}
# how much each weapon is on screen when the player has it
WEAPON_USE = {'FIST': 0.3, 'PISTOL': 1.0, 'SHOTGUN': 2.0, 'CHAINGUN': 1.5, 'LAUNCHER': 1.0, 'SAW': 0.5}
DISTANCES = ((80, 1 / 80), (128, 1 / 128), (192, 1 / 192), (288, 1 / 288), (432, 1 / 432))
MONSTERS = {3004: 'POSS', 9: 'SPOS', 3001: 'TROO', 3002: 'SARG', 3003: 'BOSS'}
SHADOWS = {58}
NO_SPRITE = {1, 2, 3, 4, 11, 14}         # starts, teleport landings
# the frames of each monster: walk, attack, pain, dying (the last is the
# corpse), extreme death (the last is the corpse)
MFRAMES = {
    'POSS': ('ABCD', 'EF', 'G', 'HIJKL', 'MNOPQRSTU'),
    'SPOS': ('ABCD', 'EF', 'G', 'HIJKL', 'MNOPQRSTU'),
    'TROO': ('ABCD', 'EFG', 'H', 'IJKLM', 'NOPQRSTU'),
    'SARG': ('ABCD', 'EFG', 'H', 'IJKLMN', ''),
    'BOSS': ('ABCD', 'EFG', 'H', 'IJKLMNO', ''),
}


# ---- color math

def _lin(v):
    v /= 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


LIN = [_lin(i) for i in range(256)]
LIN4 = [LIN[v * 17] for v in range(16)]


def oklab_lin(r, g, b):
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (math.copysign(abs(v) ** (1 / 3), v) for v in (l, m, s))
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def oklab8(c):
    return oklab_lin(LIN[c[0]], LIN[c[1]], LIN[c[2]])


def lab12(c):
    return oklab_lin(LIN4[c[0]], LIN4[c[1]], LIN4[c[2]])


def dist(a, b):
    return 100 * math.sqrt((a[0] - b[0]) ** 2 + CHROMA * CHROMA * ((a[1] - b[1]) ** 2 +
                                                                  (a[2] - b[2]) ** 2))


def mean_lin(cols, ws):
    t = sum(ws)
    return oklab_lin(*(sum(LIN4[c[i]] * w for c, w in zip(cols, ws)) / t for i in range(3)))


def to_srgb(v):
    v = 12.92 * v if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055
    return max(0, min(255, int(round(255 * v))))


class Metric:
    """The error of a color against a target and the noise of two colors
    side by side (see above)."""

    def __init__(self, cfg):
        self.ekc, self.ekh, self.d0 = cfg['err_kc'], cfg['err_kh'], cfg['err_d0']
        self.nkc, self.hk = cfg['noise_kc'], cfg['hue_k']

    @staticmethod
    def parts(a, b):
        dl = a[0] - b[0]
        dc = math.hypot(a[1], a[2]) - math.hypot(b[1], b[2])
        dab2 = (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2
        return dl * dl, dc * dc, max(0.0, dab2 - dc * dc)

    def noise(self, a, b):
        l2, c2, h2 = self.parts(a, b)
        return 100 * math.sqrt(l2 + self.nkc * self.nkc * c2 + self.hk * self.hk * h2)

    def err(self, t, m):
        """The error in the table: plain."""
        l2, c2, h2 = self.parts(t, m)
        return 100 * math.sqrt(l2 + self.ekc * self.ekc * c2 + self.ekh * self.ekh * h2)

    def err_search(self, t, m):
        """The error in the palette search: a large miss counts more."""
        d = self.err(t, m)
        return d + d * d / self.d0 if self.d0 else d


# ---- what is on screen: the world

class Sampler:
    def __init__(self, res):
        self.res = res
        self._flatmean = {}
        self._flatcolor = {}

    def flat_color(self, name):
        """The Doom color nearest (OKLab) to the mean of the flat's texels
        in linear light."""
        if name not in self._flatcolor:
            t = oklab8(self.flat_mean(name, 0))
            pal = self.res.pal
            self._flatcolor[name] = min(range(256), key=lambda k: dist(t, oklab8(pal[k])))
        return self._flatcolor[name]

    def flat_mean(self, name, cm):
        """The mean color of the flat through colormap cm, in linear light."""
        key = (name, cm)
        if key not in self._flatmean:
            pal, row, src = self.res.pal, self.res.colormap[cm], self.res.flats[name]
            s = [0.0, 0.0, 0.0]
            for b in src:
                c = pal[row[b]]
                for i in range(3):
                    s[i] += LIN[c[i]]
            self._flatmean[key] = tuple(to_srgb(v / len(src)) for v in s)
        return self._flatmean[key]

    def plane_colors(self, mp):
        """The GSFLAT color of each flat of the map (a plane has one color)."""
        fc = {}
        for sec in mp.sectors:
            for nm in (sec[2], sec[3]):
                if nm != 'F_SKY1' and nm not in fc and nm in self.res.flats:
                    fc[nm] = self.flat_color(nm)
        fc['NUKAGE'] = self.flat_color('NUKAGE1')
        return fc


def view_points(res, m, n, seed=1):
    """Views from random subsector centers (sectors 56 or more high), random
    angles."""
    mp = V.Map(res, 'E1M%d' % m)
    rnd = random.Random(seed * 1000 + m)
    pts = []
    while len(pts) < n:
        cnt, first = mp.ssectors[rnd.randrange(len(mp.ssectors))]
        p = [mp.verts[mp.segs[i][0]] for i in range(first, first + cnt)]
        x = sum(q[0] for q in p) / len(p)
        y = sum(q[1] for q in p) / len(p)
        sec = mp.sectors[mp.point_sector(x, y)]
        if sec[1] - sec[0] < 56:
            continue
        pts.append((x, y, rnd.uniform(0, 360)))
    return pts


_W = {}


def _init(wadpath, infopath):
    res = V.Resources(wadpath, infopath)
    _W['res'] = res
    _W['sampler'] = Sampler(res)
    _W['maps'] = {}


def _one_view(args):
    """The lit Doom colors of one view, by kind: {kind: {color: pixels}},
    and the light of the player's sector."""
    m, x, y, ang = args
    res, sampler = _W['res'], _W['sampler']
    if m not in _W['maps']:
        mp = V.Map(res, 'E1M%d' % m)
        _W['maps'][m] = (mp, sampler.plane_colors(mp))
    mp, fc = _W['maps'][m]
    v = V.View(res, mp, fc, x, y, ang, things=True, weapon=None)
    cmap = res.colormap
    out = defaultdict(Counter)
    for i in range(V.W * V.H):
        k = v.K[i]
        lev = LEVEL(v.L[i], k, v.D[i], v.Z[i], v.ZS[i])
        if k == V.WALL:
            kind = 'wall'
        elif k == V.PLANE:
            kind = 'plane'
        elif k == V.BRIGHT and v.Z[i] >= 1e29:
            kind = 'sky'
        else:
            kind = 'thing'
        out[kind][cmap[lev][v.S[i]]] += 1
    return {k: dict(c) for k, c in out.items()}, v.player_light


# ---- what is on screen: the sprites

def startmap(light):
    return (15 - max(0, min(15, light >> 4))) * 4


def sprite_level(light, z):
    return max(0, min(31, startmap(light) - min(47, int(2560.0 / z)) // 2))


def weapon_level(light):
    return max(0, min(31, startmap(light) - 23))


class Presenter:
    """The sprite groups of a map: {group: Counter(lit Doom color -> weight)}
    with the sum 1 in each group."""

    def __init__(self, res):
        self.res = res
        self._hist = {}
        self.bright = defaultdict(set)
        for st, (spr, f) in res.states.items():
            if f & 0x8000:
                self.bright[spr].add(chr(65 + (f & 0x7fff)))
        self._info = {}

    def lump_hist(self, name):
        if name not in self._hist:
            w, h, lo, to, cols = self.res.patch(name)
            c = Counter()
            for col in cols:
                c.update(col.values())
            self._hist[name] = c
        return self._hist[name]

    def frame_lumps(self, spr, letter):
        r0 = self.res.sprites.get((spr, letter, '0'))
        if r0:
            return [r0[0]]
        return [self.res.sprites[(spr, letter, r)][0] for r in '12345678' if (spr, letter, r) in self.res.sprites]

    def add_frame(self, acc, spr, letter, weight, lights, dists=DISTANCES, level=None):
        """acc[lit color] += the texels of all rotations of the frame, lit at
        the lights ((light, weight) ...) and the distances."""
        lumps = self.frame_lumps(spr, letter)
        if not lumps:
            return
        levels = Counter()
        if letter in self.bright.get(spr, ()):
            levels[0] = 1.0
        elif level is not None:
            for li, lw in lights:
                levels[level(li)] += lw
        else:
            dw = sum(w for _, w in dists)
            lw_t = sum(w for _, w in lights)
            for li, lw in lights:
                for z, w in dists:
                    levels[sprite_level(li, z)] += lw / lw_t * w / dw
        cmap = self.res.colormap
        for name in lumps:
            h = self.lump_hist(name)
            for lev in sorted(levels):
                row = cmap[lev]
                k = weight * levels[lev] / len(lumps)
                for c in sorted(h):
                    acc[row[c]] += h[c] * k

    def map_info(self, m):
        """The things of the map at skill 3 (ultra-violence only: half)."""
        if m not in self._info:
            mp = V.Map(self.res, 'E1M%d' % m)
            things = []
            for tx, ty, tang, tt, tf in mp.things:
                if tf & 16:
                    continue
                wt = 1.0 if tf & 2 else 0.5 if tf & 4 else 0.0
                if wt:
                    sec = mp.sectors[mp.point_sector(tx, ty)]
                    things.append((tt, wt, sec[4]))
            self._info[m] = things
        return self._info[m]

    def weapons(self, m):
        have = ['FIST', 'PISTOL']
        for mm in range(1, m + 1):
            for tt, wt, light in self.map_info(mm):
                w = 'SHOTGUN' if tt == 9 else WEAPON_THINGS.get(tt)
                if w and w not in have:
                    have.append(w)
        return have

    def has_launcher(self, m):
        return any(tt in (2003, 2010, 2046) for mm in range(1, m + 1) for tt, wt, light in self.map_info(mm))

    @staticmethod
    def _add(group, acc, weight):
        tot = sum(acc.values())
        if tot:
            for c in sorted(acc):
                group[c] += weight * acc[c] / tot

    def groups(self, m, player_lights):
        res = self.res
        g = {k: Counter() for k in ('monsters', 'gore', 'fx', 'items', 'weapon')}
        lights_of = defaultdict(list)
        count = Counter()
        for tt, wt, light in self.map_info(m):
            lights_of[tt].append((light, wt))
            count[tt] += wt
        monster_lights = [lw for tt in sorted(MONSTERS) for lw in lights_of.get(tt, [])]
        all_lights = [lw for tt in sorted(lights_of) for lw in lights_of[tt]]
        # monsters: each type by the square root of its count; in a type,
        # walk 40%, attack 15%, pain 10%, dying 10%, the corpse 20-25%, the
        # extreme death 5%
        for tt in sorted(MONSTERS):
            if not count.get(tt):
                continue
            spr = MONSTERS[tt]
            walk, atk, pain, death, xdeath = MFRAMES[spr]
            parts = [(walk, 0.40), (atk, 0.15), (pain, 0.10), (death[:-1], 0.10)]
            if xdeath:
                parts += [(death[-1], 0.20), (xdeath[:-1], 0.025), (xdeath[-1], 0.025)]
            else:
                parts += [(death[-1], 0.25)]
            acc = Counter()
            for letters, pw in parts:
                for L in letters:
                    self.add_frame(acc, spr, L, pw / len(letters), lights_of[tt])
            self._add(g['monsters'], acc, math.sqrt(count[tt]))
        # gore: the blood of hits, at the monster lights, near
        if monster_lights:
            acc = Counter()
            for L in 'ABC':
                self.add_frame(acc, 'BLUD', L, 1 / 3, monster_lights, dists=DISTANCES[:4])
            self._add(g['gore'], acc, 1.0)
        # fx
        fx = [('PUFF', 'ABCD', 3.0, monster_lights or all_lights)]
        if count.get(3001):
            fx.append(('BAL1', 'ABCDE', 2.0, lights_of[3001]))
        if count.get(3003):
            fx.append(('BAL7', 'ABCDE', 2.0, lights_of[3003]))
        if count.get(2035):
            fx.append(('BEXP', 'ABCDE', 1.0, lights_of[2035]))
        if self.has_launcher(m):
            fx.append(('MISL', 'ABCD', 1.0, monster_lights or all_lights))
        if count.get(14):
            fx.append(('TFOG', 'ABCDEFGHIJ', 0.5, lights_of[14]))
        for spr, letters, fw, lts in fx:
            acc = Counter()
            for L in letters:
                self.add_frame(acc, spr, L, 1 / len(letters), lts or [(160, 1)])
            self._add(g['fx'], acc, fw)
        # items and decorations, the dead players and the pools of blood
        for tt in sorted(count):
            if tt in MONSTERS or tt in SHADOWS or tt in NO_SPRITE or tt not in res.things:
                continue
            spr = res.things[tt][0]
            letters = sorted(set(k[1] for k in res.sprites if k[0] == spr))
            acc = Counter()
            for L in letters:
                self.add_frame(acc, spr, L, 1 / len(letters), lights_of[tt])
            self._add(g['items'], acc, math.sqrt(count[tt]))
        # the weapons, at the weapon light of the player's sectors
        for wname in self.weapons(m):
            acc = Counter()
            for i, (spr, letters) in enumerate(WEAPON_SPRITES[wname]):
                share = 1.0 if i == 0 else 0.25
                for L in letters:
                    self.add_frame(acc, spr, L, share / len(letters), player_lights, level=weapon_level)
            self._add(g['weapon'], acc, WEAPON_USE[wname])
        for k in g:
            tot = sum(g[k].values())
            if tot:
                g[k] = Counter({c: g[k][c] / tot for c in sorted(g[k])})
        return g


def flatten(h, alpha):
    """The shares of a histogram to the power alpha, the sum 1."""
    if alpha == 1.0:
        return h
    t = sum(h.values())
    out = Counter({c: (h[c] / t) ** alpha for c in sorted(h) if h[c] > 0})
    t2 = sum(out.values())
    return Counter({c: out[c] / t2 for c in sorted(out)})


def targets(res, pres, world, lights, m, cfg):
    """The weight and the noise weight of each Doom color, and the weight of
    each use: (weights[256], lams[256], uses)."""
    uses = {}
    wt = sum(sum(h.values()) for h in world.values())
    for kind in sorted(world):
        u = uses.setdefault(kind, Counter())
        for c, n in world[kind].items():
            u[c] += cfg['world'] * n / wt
    if m:
        groups = pres.groups(m, lights)
    else:
        groups = {}
        for mm in range(1, 10):
            for k, h in pres.groups(mm, lights).items():
                t = groups.setdefault(k, Counter())
                for c in sorted(h):
                    t[c] += h[c] / 9
    for g in sorted(groups):
        u = uses.setdefault(g, Counter())
        h = flatten(groups[g], cfg['alpha_sprites'])
        for c in sorted(h):
            u[c] += cfg[g] * h[c]
    w = [0.0] * 256
    lam = [0.0] * 256
    for use in sorted(uses):
        lu = cfg['lam_' + use]
        for c, x in uses[use].items():
            w[c] += x
            lam[c] += x * lu
    lams = [lam[c] / w[c] if w[c] else cfg['lam_wall'] for c in range(256)]
    tw = sum(w)
    weights = []
    for c in range(256):
        lab = oklab8(res.pal[c])
        weights.append(w[c] / tw * (1 + cfg['chroma'] * math.hypot(lab[1], lab[2])))
    return weights, lams, uses


# ---- the palette

FIXED = ((0, 0, 0), (13, 13, 13))  # black and a white
_GRID = []


def grid():
    if not _GRID:
        _GRID.extend(((r, g, b), lab12((r, g, b))) for r in range(16) for g in range(16) for b in range(16))
    return _GRID


def kmeans(items, k=16, rounds=30, fixed=FIXED):
    nf = len(fixed)
    centers = [lab12(c) for c in fixed]
    while len(centers) < k:
        centers.append(max(items, key=lambda it: it[1] * min(dist(it[0], c) ** 2 for c in centers))[0])
    for _ in range(rounds):
        sums = [[0.0, 0.0, 0.0, 0.0] for _ in range(k)]
        for lab, w in items:
            j = min(range(k), key=lambda i: dist(lab, centers[i]))
            s = sums[j]
            for i in range(3):
                s[i] += lab[i] * w
            s[3] += w
        centers = centers[:nf] + [(s[0] / s[3], s[1] / s[3], s[2] / s[3]) if s[3] else centers[j]
                                  for j, s in enumerate(sums) if j >= nf]
    return list(fixed) + [min(grid(), key=lambda e: dist(e[1], c))[0] for c in centers[nf:]]


class Search:
    """The palette search over the clean mixes (one color, two colors 50/50
    or 75/25)."""

    def __init__(self, targets, metric):
        tw = sum(w for _, w, _ in targets)
        self.targets = [(t, w / tw, lam) for t, w, lam in targets]
        self.mt = metric
        self.cache = {}

    def mixes_of(self, P, k, others):
        labs = [lab12(c) for c in P]
        out = [(labs[k], 0.0)]
        for j in others:
            if j == k:
                continue
            key = (P[k], P[j])
            if key not in self.cache:
                s = self.mt.noise(labs[k], labs[j])
                self.cache[key] = (mean_lin([P[k], P[j]], [1, 1]), mean_lin([P[k], P[j]], [3, 1]),
                                   mean_lin([P[k], P[j]], [1, 3]), s)
            m50, m75, m25, s = self.cache[key]
            out += [(m50, s), (m75, s), (m25, s)]
        return out

    def all_mixes(self, P, idx):
        out = []
        for a in idx:
            out += self.mixes_of(P, a, [b for b in idx if b > a])
        return out

    def best(self, mixes):
        e = self.mt.err_search
        return [min(e(t, m) + lam * s for m, s in mixes) for t, w, lam in self.targets]

    def run(self, P, rounds=30):
        P = list(P)
        n, nf = len(P), len(FIXED)
        cur = sum(t[1] * c for t, c in zip(self.targets, self.best(self.all_mixes(P, range(n)))))
        e = self.mt.err_search
        for _ in range(rounds):
            improved = False
            for k in range(nf, n):
                others = [j for j in range(n) if j != k]
                base = self.best(self.all_mixes(P, others))
                cands = []
                for ch in range(3):
                    for step in (-2, -1, 1, 2):
                        v = P[k][ch] + step
                        if 0 <= v <= 15:
                            c = list(P[k])
                            c[ch] = v
                            cands.append(tuple(c))
                # jumps: to the targets served worst without k
                worst = sorted(range(len(self.targets)), key=lambda i: (-self.targets[i][1] * base[i], i))[:3]
                for i in worst:
                    c = min(grid(), key=lambda g: dist(g[1], self.targets[i][0]))[0]
                    if c not in P and c not in cands:
                        cands.append(c)
                best_c, best_v = None, cur
                for c in cands:
                    Q = P[:k] + [c] + P[k + 1:]
                    mine = self.mixes_of(Q, k, others)
                    v = 0.0
                    for (t, w, lam), b in zip(self.targets, base):
                        x = min(e(t, m) + lam * s for m, s in mine)
                        v += w * (x if x < b else b)
                    if v < best_v - 1e-9:
                        best_c, best_v = c, v
                if best_c is not None:
                    P[k] = best_c
                    cur = best_v
                    improved = True
            if not improved:
                break
        return P


# ---- mixes of 4

class Mixes:
    def __init__(self, P, metric):
        self.P = P
        self.mt = metric
        labs = [lab12(c) for c in P]
        n = len(P)
        self.mixes = []
        for a in range(n):
            for b in range(a, n):
                for c in range(b, n):
                    for d in range(c, n):
                        q = (a, b, c, d)
                        spread = max(metric.noise(labs[i], labs[j]) for i in q for j in q)
                        self.mixes.append((mean_lin([P[i] for i in q], [1, 1, 1, 1]), spread, q))
        self.lightness = [l[0] for l in labs]

    def pair_for(self, rgb):
        """The best mix with a = b and c = d, as a pair byte p << 4 | q."""
        t = oklab8(rgb)
        _, _, q = min((e for e in self.mixes if e[2][0] == e[2][1] and e[2][2] == e[2][3]),
                      key=lambda e: dist(t, e[0]) + LAMBDA * e[1])
        return (q[0] << 4) | q[2]

    def bytes_for(self, rgb, lam):
        t = oklab8(rgb)
        err = self.mt.err
        _, _, q = min(self.mixes, key=lambda e: err(t, e[0]) + lam * e[1])
        a, b, c, d = sorted(q, key=lambda i: self.lightness[i])
        return (a << 4) | d, (c << 4) | b


# ---- the lumps

def view_record(P, playpals, dweights, mixes, lams):
    """GSVIEWn. The tints follow what PLAYPAL p does to the Doom colors
    nearest to each palette color (as tools/gscolor.py palette_record)."""
    base = playpals[0]
    labs = [lab12(c) for c in P]
    nearest = [min(range(16), key=lambda k: dist(oklab8(c), labs[k])) for c in base]
    members = [[] for _ in range(16)]
    for i in range(256):
        members[nearest[i]].append((i, dweights[i] + 1))
    rec = bytearray()
    for p in range(14):
        for k in range(16):
            if members[k]:
                tw = sum(w for _, w in members[k])
                shift = [sum((playpals[p][i][ch] - base[i][ch]) * w for i, w in members[k]) / tw
                         for ch in range(3)]
            else:
                shift = [0, 0, 0]
            rgb = [max(0, min(255, P[k][ch] * 17 + shift[ch])) for ch in range(3)]
            r, g, b = (max(0, min(15, int(round(v / 17)))) for v in rgb)
            rec += struct.pack('<H', (r << 8) | (g << 4) | b)
    for c in base:
        rec.append(mixes.pair_for(c))
    ab = [mixes.bytes_for(c, lams[i]) for i, c in enumerate(base)]
    rec += bytes(a for a, _ in ab) + bytes(b for _, b in ab)
    return bytes(rec)


def flat_list(res, maps):
    names = list(NUKAGE)
    for m in maps:
        base = res.wad.index('E1M%d' % m)
        sec = res.wad.lumps[base + 8][1]
        for i in range(len(sec) // 26):
            for o in (4, 12):
                nm = V.name8(sec[i * 26 + o:i * 26 + o + 8])
                if nm != 'F_SKY1' and nm not in names:
                    names.append(nm)
    return names


def flat_record(sampler, names):
    return bytes(sampler.flat_color(nm) for nm in names)


def _design(args):
    """The palette and the record of map m (run in a worker process)."""
    m, world, lights, cpath = args
    res = _W['res']
    cfg = dict(CFG)
    cfg.update(MAP_CFG.get(m, {}))
    pres = Presenter(res)
    weights, lams, uses = targets(res, pres, world, lights, m, cfg)
    metric = Metric(cfg)
    if cpath and os.path.exists(cpath):
        P = [tuple(int(ch, 16) for ch in w) for w in open(cpath).read().split()]
    else:
        tg = [(oklab8(res.pal[c]), weights[c], lams[c]) for c in range(256) if weights[c] > 0]
        P = kmeans([(t, w) for t, w, _ in tg])
        P = Search(tg, metric).run(P, cfg['rounds'])
        P = align4(P, len(FIXED))
    dweights = [0.0] * 256
    for use in sorted(uses):
        for c, x in uses[use].items():
            dweights[c] += x * 1e6
    return P, view_record(P, res.playpals, dweights, Mixes(P, metric), lams)


def main():
    wadpath, infopath, outdir, *maps = sys.argv[1:]
    maps = [int(m) for m in maps] or list(range(10))
    res = V.Resources(wadpath, infopath)
    sampler = Sampler(res)
    os.makedirs(outdir, exist_ok=True)
    cache = os.environ.get('GSVIEW_CACHE')
    need = sorted(set(mm for m in maps for mm in ([m] if m else range(1, 10))))
    jobs = [(m, x, y, a) for m in need for x, y, a in view_points(res, m, CFG['views'])]
    ctx = multiprocessing.get_context('spawn')
    with ctx.Pool(min(len(jobs), os.cpu_count() or 1), initializer=_init, initargs=(wadpath, infopath)) as pool:
        world = {m: defaultdict(Counter) for m in need}
        lights = {m: Counter() for m in need}
        for (m, _, _, _), (h, pl) in zip(jobs, pool.imap(_one_view, jobs, chunksize=2)):
            for k in sorted(h):
                for c, n in sorted(h[k].items()):
                    world[m][k][int(c)] += n
            lights[m][pl] += 1

        def world_of(m):
            if m:
                return {k: dict(v) for k, v in world[m].items()}, sorted(lights[m].items())
            w, pl = defaultdict(Counter), Counter()
            for mm in range(1, 10):
                tot = sum(sum(h.values()) for h in world[mm].values())
                for k in sorted(world[mm]):
                    for c, n in sorted(world[mm][k].items()):
                        w[k][c] += n / tot
                pl.update(lights[mm])
            return {k: dict(v) for k, v in w.items()}, sorted(pl.items())
        args = []
        for m in maps:
            w, pl = world_of(m)
            args.append((m, w, pl, cache and os.path.join(cache, 'pal%d.txt' % m)))
        results = pool.map(_design, args, chunksize=1)
    for m, (P, rec) in zip(maps, results):
        if cache:
            os.makedirs(cache, exist_ok=True)
            open(os.path.join(cache, 'pal%d.txt' % m), 'w').write(' '.join('%X%X%X' % c for c in P))
        names = flat_list(res, [m] if m else list(range(1, 10)))
        open(os.path.join(outdir, 'GSVIEW%d.lmp' % m), 'wb').write(rec)
        open(os.path.join(outdir, 'GSFLAT%d.lmp' % m), 'wb').write(flat_record(sampler, names))
        open(os.path.join(outdir, 'GSFLAT%d.txt' % m), 'w').write('\n'.join(names) + '\n')
        print('GSVIEW%d' % m, ' '.join('%X%X%X' % c for c in P), 'flats %d' % len(names), flush=True)


if __name__ == '__main__':
    main()
