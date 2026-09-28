#!/usr/bin/env python3
"""Color conversion for the Apple IIgs super hi-res screen.

The SHR screen has 16 palettes of 16 colors with 4 bits per channel, and
each of the 200 rows picks one palette. Doom's 256 colors are shown as
pairs of two palette colors: a Doom pixel of the 3D view is one byte, two
SHR pixels, and even and odd rows swap the two, which gives a checkerboard.

Palette record (704 bytes, the start of GSVIEWn of tools/gsview.py, and
each palette of GSSTAT after its 32-byte row map, tools/wadtool.py):
  14 x 16 x 2  the 16 colors for each of the 14 PLAYPAL palettes, $0RGB
  256          the best pair for each Doom color: high nibble = color of
               the left pixel on even rows, low nibble = the right pixel

SHR picture (36864 bytes, lumps TITLEPIC, HELP2, WIMAP0). Bytes 0-32767
are an image of the SHR screen memory $E1:2000-$9FFF, so the loader can
show a picture block by block (src/iigs/loader.s):
  32000        pixels, 160 bytes for each of the 200 rows
  200          palette number of each row
  56           zeros
  16 x 16 x 2  palettes, $0RGB; color 0 of each palette is black
  16 x 256     best pair for each Doom color in each palette, for patches
               drawn on top of the picture
"""

import struct

PAIR_PENALTY = 1 / 8

# The load strip of the loader over TITLEPIC: rows STRIP_ROW0-199 take
# palette STRIP_PAL, and its first colors are fixed: black, the red ramp
# $400 $700 $A00 $D00 (the text and its pulse), yellow (a loaded cell of the
# bar), blue, grey and white (the disk icon). src/iigs/loader.s uses these
# color numbers.
STRIP_ROW0 = 191
STRIP_PAL = 15
STRIP_COLORS = ((0, 0, 0), (68, 0, 0), (119, 0, 0), (170, 0, 0), (221, 0, 0),
                (255, 255, 0), (0, 0, 170), (187, 170, 153), (255, 255, 238))


# The slot order of every palette (the user, 2026-09-26: reddish, bluish,
# greenish colors in roughly the same places in all palettes, so a row that
# shows for a moment with the palette of another picture keeps its colors
# near): the colors of a palette go to the slots of ALIGN_REF (4-bit RGB)
# with the least total OKLab distance. Slots 0 and 1: black and white.
ALIGN_REF = ((0, 0, 0), (13, 13, 13),
             (9, 0, 0), (5, 0, 0),                          # red, dark red
             (12, 8, 5), (9, 6, 4), (6, 5, 3), (4, 3, 2), (2, 2, 1),  # tan .. dark brown
             (2, 4, 2), (1, 2, 1),                          # green, dark green
             (0, 0, 5),                                     # blue
             (8, 8, 8), (5, 5, 5), (3, 3, 3), (1, 1, 1))    # grays


def _lin4(v):
    v = v * 17 / 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def oklab4(c):
    """OKLab of a 4-bit RGB color."""
    r, g, b = (_lin4(v) for v in c)
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (v ** (1 / 3) for v in (l, m, s))
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def lab_dist(a, b):
    return (a[0] - b[0]) ** 2 + 2.25 * ((a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2)


def assignment(cost):
    """The least-cost assignment of rows to columns of a square matrix
    (Hungarian method): col[row]."""
    n = len(cost)
    inf = float('inf')
    u, v, p, way = [0.0] * (n + 1), [0.0] * (n + 1), [0] * (n + 1), [0] * (n + 1)
    for i in range(1, n + 1):
        p[0], j0 = i, 0
        minv, used = [inf] * (n + 1), [False] * (n + 1)
        while True:
            used[j0] = True
            i0, delta, j1 = p[j0], inf, 0
            for j in range(1, n + 1):
                if not used[j]:
                    cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j]:
                        minv[j], way[j] = cur, j0
                    if minv[j] < delta:
                        delta, j1 = minv[j], j
            for j in range(n + 1):
                if used[j]:
                    u[p[j]] += delta
                    v[j] -= delta
                else:
                    minv[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while True:
            j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
            if j0 == 0:
                break
    col = [0] * n
    for j in range(1, n + 1):
        col[p[j] - 1] = j - 1
    return col


def align4(pal4, keep):
    """The 16 4-bit colors pal4 in the slot order of ALIGN_REF; the first
    keep colors stay in their places."""
    rest = list(pal4[keep:])
    slots = list(range(keep, 16))
    cost = [[lab_dist(oklab4(c), oklab4(ALIGN_REF[s])) for s in slots] for c in rest]
    col = assignment(cost)
    out = list(pal4[:keep]) + [None] * len(rest)
    for i, c in enumerate(rest):
        out[slots[col[i]]] = c
    return out


def align8(pal, keep):
    """align4 for a palette of 8-bit colors (multiples of 17)."""
    return [from12(c) for c in align4([to12(c) for c in pal], keep)]


def to12(c):
    return tuple(max(0, min(15, int(round(v * 15 / 255)))) for v in c)


def from12(c):
    return tuple(v * 17 for v in c)


def word12(c):
    r, g, b = to12(c)
    return (r << 8) | (g << 4) | b


def dist(a, b):
    dr, dg, db = a[0] - b[0], a[1] - b[1], a[2] - b[2]
    return 3 * dr * dr + 4 * dg * dg + 2 * db * db


def kmeans(items, k=16, fixed=((0, 0, 0),), rounds=30):
    """Weighted k-means. items: list of ((r, g, b), weight).
    The colors in fixed are kept and count as centers."""
    items = [(c, w) for c, w in items if w > 0]
    fixed = [tuple(float(v) for v in c) for c in fixed]
    if not items:
        return [from12(to12(c)) for c in fixed] + [(0, 0, 0)] * (k - len(fixed))
    centers = list(fixed)
    # k-means++ style start: take the color farthest from all centers,
    # weighted by its use
    while len(centers) < k:
        best = max(items, key=lambda it: it[1] * min(dist(it[0], c) for c in centers))
        if best[1] * min(dist(best[0], c) for c in centers) == 0:
            centers.append(centers[-1])
        else:
            centers.append(tuple(float(v) for v in best[0]))
    for _ in range(rounds):
        sums = [[0.0, 0.0, 0.0, 0.0] for _ in range(k)]
        for c, w in items:
            j = min(range(k), key=lambda i: dist(c, centers[i]))
            s = sums[j]
            s[0] += c[0] * w
            s[1] += c[1] * w
            s[2] += c[2] * w
            s[3] += w
        new = list(fixed)
        for j in range(len(fixed), k):
            s = sums[j]
            new.append((s[0] / s[3], s[1] / s[3], s[2] / s[3]) if s[3] else centers[j])
        moved = max(dist(a, b) for a, b in zip(new, centers))
        centers = new
        if moved < 1:
            break
    return [from12(to12(c)) for c in centers]


def best_pairs(pal, targets):
    """For each target color, the pair (p, q) whose mean is closest, with a
    small penalty on the distance between p and q. Returns bytes p<<4|q."""
    pairs = []
    for p in range(len(pal)):
        for q in range(p, len(pal)):
            m = tuple((pal[p][i] + pal[q][i]) / 2 for i in range(3))
            pairs.append((m, p, q, dist(pal[p], pal[q]) * PAIR_PENALTY))
    out = bytearray()
    for c in targets:
        best = min(pairs, key=lambda e: dist(c, e[0]) + e[3])
        out.append((best[1] << 4) | best[2])
    return bytes(out)


def palette_record(pal, playpals, weights):
    """704-byte palette record, see above. The tinted colors follow what
    PLAYPAL does to the Doom colors that each SHR color stands for."""
    base = playpals[0]
    nearest = [min(range(16), key=lambda k: dist(c, pal[k])) for c in base]
    members = [[] for _ in range(16)]
    for i in range(256):
        members[nearest[i]].append((i, weights[i] + 1))
    rec = bytearray()
    for p in range(14):
        for k in range(16):
            if members[k]:
                tw = sum(w for _, w in members[k])
                shift = [sum((playpals[p][i][ch] - base[i][ch]) * w for i, w in members[k]) / tw
                         for ch in range(3)]
            else:
                shift = [0, 0, 0]
            rgb = [max(0, min(255, pal[k][ch] + shift[ch])) for ch in range(3)]
            rec += struct.pack('<H', word12(rgb))
    rec += best_pairs(pal, base)
    return bytes(rec)


def picture(raw, playpal, overlay_weights=None, weight=None, strip=False, rounds=6):
    """SHR picture record from a raw 320x200 image of Doom colors.
    overlay_weights: Doom color use of graphics drawn on top of the
    picture, added to every palette. weight(x, y): the weight of a pixel
    in the palettes (1 for all when None). strip: rows STRIP_ROW0-199 take
    palette STRIP_PAL with STRIP_COLORS. The palettes of the other rows
    start as bands of rows; then each row takes the palette with the least
    error for its pixels and each palette is made again from its rows,
    rounds times (free rows: the research "load and audio plan" 11.4)."""
    width, height = 320, 200
    free = STRIP_ROW0 if strip else height
    bands = STRIP_PAL if strip else 16
    rowhist = []
    for y in range(height):
        h = {}
        for x in range(width):
            c = raw[y * width + x]
            h[c] = h.get(c, 0) + (weight(x, y) if weight else 1)
        rowhist.append(h)
    ototal = sum(overlay_weights) if overlay_weights else 0

    def palette_for(rows, fixed=((0, 0, 0),)):
        hist = [0] * 256
        for y in rows:
            for c, n in rowhist[y].items():
                hist[c] += n
        if overlay_weights:
            total = sum(hist) or 1
            for i in range(256):
                hist[i] += overlay_weights[i] * total // (4 * (ototal or 1))
        return kmeans([(playpal[i], hist[i]) for i in range(256)], fixed=fixed)

    rows_per_band = [free // bands + (1 if b < free % bands else 0) for b in range(bands)]
    band_of_row = []
    for b, n in enumerate(rows_per_band):
        band_of_row += [b] * n
    pals = [palette_for([y for y in range(free) if band_of_row[y] == b]) for b in range(bands)]
    for _ in range(rounds):
        nearest = [[min(dist(playpal[c], q) for q in pal) for pal in pals] for c in range(256)]
        band_of_row = [min(range(bands), key=lambda p: sum(n * nearest[c][p] for c, n in rowhist[y].items()))
                       for y in range(free)]
        pals = [palette_for([y for y in range(free) if band_of_row[y] == p]) if p in band_of_row else pals[p]
                for p in range(bands)]
    if strip:
        pals.append(palette_for(range(STRIP_ROW0, height), STRIP_COLORS))
        band_of_row += [STRIP_PAL] * (height - STRIP_ROW0)

    # Floyd-Steinberg dithering in RGB with the palette of each row
    cur = [[0.0, 0.0, 0.0] for _ in range(width)]
    pixels = bytearray(32000)
    for y in range(height):
        pal = pals[band_of_row[y]]
        nxt = [[0.0, 0.0, 0.0] for _ in range(width)]
        for x in range(width):
            c = playpal[raw[y * width + x]]
            v = [max(0.0, min(255.0, c[ch] + cur[x][ch])) for ch in range(3)]
            k = min(range(16), key=lambda j: dist(v, pal[j]))
            e = [v[ch] - pal[k][ch] for ch in range(3)]
            if x + 1 < width:
                for ch in range(3):
                    cur[x + 1][ch] += e[ch] * 7 / 16
            for dx, f in ((-1, 3 / 16), (0, 5 / 16), (1, 1 / 16)):
                if 0 <= x + dx < width:
                    for ch in range(3):
                        nxt[x + dx][ch] += e[ch] * f
            if x % 2 == 0:
                pixels[y * 160 + x // 2] = k << 4
            else:
                pixels[y * 160 + x // 2] |= k
        cur = nxt
    rec = bytearray(pixels)
    rec += bytes(band_of_row)
    rec += bytes(32256 - len(rec))
    for pal in pals:
        for c in pal:
            rec += struct.pack('<H', word12(c))
    for pal in pals:
        rec += best_pairs(pal, playpal)
    assert len(rec) == 36864
    return bytes(rec)
