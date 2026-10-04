#!/usr/bin/env python3
"""Build the sound bank: the Doom sound effects, resampled small for DOC
RAM and coded without loss.

Usage: sndbank.py DOOM1.WAD src/iigs/offsets.inc OUT [MUSIC] [--law SFXVOL.INC]
       (OUT - writes no bank: only the tables of --law)

DOC RAM (64 KB) cannot hold the sounds of a level (97-140 KB), and each
byte of a sound costs DOC RAM and upload time. So the bank has a plan for
each map (plan()): the sounds that the map can start (its things, its line
specials, the player and the weapons of the maps before), the sounds with
the most starts for each page at fixed places for the whole map, and a
pool for the other sounds. src/iigs/s_sound65.s copies the plan to DOC RAM
when the map starts and uses the pool as a cache. With MUSIC (the music bank,
tools/music/mussc.py or tools/musbank.py) each map also has a plan for the pages
below its song, all of them a pool: with a song there, too few pages stay
for sounds at fixed places (the cache with the demos' sound starts: 13-33%
fewer upload bytes than the plan without the song).

Each sound is cut as small as it can be; some loss of quality is expected:
  - the head and the tail below TAIL_DB under the peak go;
  - the band that holds SHARE of the energy (mean spectrum of 1024-sample
    frames) sets the rate: SR / k, SR = 894886 / 34 Hz (the DOC scan rate
    with 32 oscillators), k the largest integer from KMIN to KMAX with
    SR / k >= band / 0.42. The DOC then plays one byte every k scans
    (4386 Hz at most);
  - for a sound with a wider band than SR / KMIN keeps, a higher rate up
    to SR / 4 (6580 Hz) while the sound still needs the same table size
    (the DOC RAM place of a sound is its table), and SR / 4 for a sound
    that fits 2 KB there (short sounds);
  - a sound longer than MAXLEN bytes ends with a fade out at MAXLEN, so
    every sound fits a 4 KB table (a table starts at a multiple of its
    size, so 8 KB tables leave room for only 7 sounds in DOC RAM).
The resampler is a Kaiser windowed sinc low pass at 0.46 of the new rate,
followed by a treble lift for the droop of the DOC, which holds each sample
flat until the next one (and for the dull sound of the low rates).

Each sample is stored at full scale: its peak is 127 steps from 128. The DOC
has only 8 bits, and other IIgs software uses all of them. The level of a
sound is in the volume register of its oscillators. The level of a sound is
its peak in the bank before this scaling: 1 for the loudest sounds of Doom,
0.15 for the pick up sound. So the balance of the sounds is the balance of the
DMX lumps.

SFXVOL.INC holds the two tables of docVolume (src/iigs/s_sound65.s). With
the volume vol (0-120) and the separation sep (the pan, 254 - sep on the
left and sep on the right), docVolume makes W = vol * K / 256, where K =
65536 * level / FULL_DIV is the word of the sound in sfxK. W stops at
panCap[sep] = 65535 / the larger of sep and 254 - sep. The registers are
W * (254 - sep) / 256 (left) and W * sep / 256 (right). The larger one is 255
at most, and the two sides keep their ratio when W stops. FULL_DIV makes the
register 255 for a close sound of level 1 at the middle (sep 127).

The resampler overshoots at a sharp attack: the treble lift and the low pass
ring, and some samples reach 1.28 times full scale. limiter() lowers the gain
smoothly around those samples, so no sample is cut at the bytes 1 and 255.
A sound can start or end loud (more than a quarter of its peak, and not the
rise of an attack). The DOC then steps from silence to the first sample, or
from the last sample to silence, and that is a click. fades() gives such an
end a fade of 3 ms (popain, brsdth, sawhit, dorcls, pstart).

The samples of a DS lump are coded in blocks of 16. A block starts with
the byte (order << 4) | width. Each sample x[i] is the prediction of the
order plus a residual:

  order 0: 128
  order 1: x[i-1]
  order 2: 2 * x[i-1] - x[i-2]

with x[-1] = x[-2] = 128 and all arithmetic mod 256. The residuals are
two's complement numbers of width bits (0, 2, 4, 6 or 8), packed from the
high bit down: 16 residuals take 2 * width bytes. src/iigs/i_snd65.s
decodes the blocks.

As in DMX, the 16 bytes at each end of a DS lump are not played. A sample
of 0 becomes 1, because a 0 byte stops a DOC oscillator.

File layout (N: the number of sfx):
  0x000  12 decoding tables of 256 bytes, in the order of TABLES
  0xc00  u16 N, then for each sfx: u32 offset of the blocks (0: no
         sound), u16 samples, u16 sample rate
  then   u8 stand-in of each sfx (0: none), u8 pitch of each sfx (the
         frequency of the stand-in times pitch / 128), then for map 0 (no
         map) to MAPS: u8 first pool page, u8 end of the sfx pages, u8
         first page of each sfx (255: not in the plan), then for map 1 to
         MAPS the same with its song playing (the plan without it if the
         map has no song)
  ...    the blocks of each sound
"""
import cmath
import math
import re
import struct
import sys

WIDTHS = (0, 2, 4, 6, 8)
SR = 894886 / 34                        # DOC scan rate, 32 oscillators
SHARE = 0.90
KMIN, KMAX = 6, 16                      # 4386 Hz .. 1645 Hz
TAIL_DB = 30
MAXLEN = 4095                           # a 4 KB table with its 0 byte
FADE = 256
CEIL = 127.0                            # the largest step from 128
FADE_MS = 3.0                           # length of the fade at a loud start or end
FULL_DIV = 59                           # docVolume: 120 * 127 / 59 = 258, limited to 255
PAN_TOP = 65535                         # W * the larger side of the pan must stay under this
TABLES = ('HI4', 'LO4', 'S2A', 'S2B', 'S2C', 'S2D',
          'S6A', 'S6BH', 'S6BL', 'S6CH', 'S6CL', 'S6D')
DIR_OFS = 0xc00

DOC_PAGES = 255                         # page 255 has the timer ramp
MUSIC_PAGES = {}                        # map: the DOC pages of its song, at the top
POOL = 64                               # pages for the sounds that come by need
MAPS = 9
MAP_ORDER = (1, 2, 3, 9, 4, 5, 6, 7, 8) # E1M9 comes from E1M3 and goes to E1M4
MTF_MULTI = 16                          # a thing of multiplayer games only

# Sounds unused by the game; A_PlayerScream starts only pldeth.
NEVER = {'rxplod', 'pdiehi', 'tink'}

# The game picks a variant at random (posit1 + P_Random() % 3 and so on);
# a variant that is not in DOC RAM plays its stand-in at the frequency
# pitch / 128, so the sight and death sounds keep some variety. noway has
# the same samples as oof.
VARIANTS = {
    'posit2': ('posit1', 120), 'posit3': ('posit1', 137),
    'podth1': ('podth2', 120), 'podth3': ('podth2', 137),
    'bgsit2': ('bgsit1', 120), 'bgdth1': ('bgdth2', 137),
    'noway': ('oof', 128),
}

# Starts per minute of each sound, the mean of the 3 demos (a MAME trace of
# the sound starts: demo1 E1M5, demo2 E1M3, demo3 E1M7). The chainsaw, the
# rocket launcher, the fist, the barons, teleports and power ups are not in
# the demos: those numbers are estimates. A weapon fires only part of the
# time, so its sounds come to the pool when it fires and stay while it
# fires.
STARTS = {
    'pistol': 25.9, 'bgact': 21.8, 'shotgn': 20.6, 'posact': 19.0, 'plpain': 14.3,
    'firxpl': 13.7, 'firsht': 13.5, 'stnmov': 13.0, 'itemup': 13.0, 'popain': 7.8,
    'pstop': 6.8, 'bgsit2': 6.5, 'pstart': 6.2, 'posit3': 4.3, 'posit2': 4.2, 'claw': 3.9,
    'sgtatk': 3.6, 'bgsit1': 3.4, 'dmact': 3.3, 'doropn': 3.2, 'posit1': 2.9, 'dmpain': 2.8,
    'wpnup': 2.7, 'bgdth1': 2.3, 'podth2': 1.8, 'noway': 1.8, 'pldeth': 1.7, 'podth1': 1.7,
    'dorcls': 1.7, 'podth3': 1.6, 'bgdth2': 1.3, 'sgtdth': 1.0, 'sgtsit': 1.0, 'barexp': 0.9,
    'oof': 0.7, 'slop': 0.4, 'swtchn': 0.2,
    'sawidl': 0.5, 'sawful': 0.2, 'sawhit': 0.2, 'sawup': 0.1, 'rlaunc': 1.0, 'punch': 1.0,
    'getpow': 0.5, 'telept': 1.0, 'brssit': 0.5, 'brsdth': 0.5,
}

# The sounds of the player in every map (A_PlayerScream, P_XYMovement,
# P_UseLines, P_TouchSpecialThing, A_Punch, the pistol, a gib death).
PLAYER_SOUNDS = ('pistol', 'punch', 'plpain', 'pldeth', 'oof', 'noway', 'itemup', 'slop')

# The sounds of the things of a map by editor number (mobjinfo of
# src/iigs/info65.s and the attacks of src/iigs/p_enemy65.s). A shotgun guy
# drops a shotgun, a zombieman a clip.
THING_SOUNDS = {
    3004: ('posit1', 'posit2', 'posit3', 'pistol', 'popain', 'podth1', 'podth2', 'podth3',
           'posact', 'slop'),
    9: ('posit1', 'posit2', 'posit3', 'shotgn', 'popain', 'podth1', 'podth2', 'podth3',
        'posact', 'slop', 'wpnup'),
    3001: ('bgsit1', 'bgsit2', 'claw', 'firsht', 'firxpl', 'popain', 'bgdth1', 'bgdth2',
           'bgact', 'slop'),
    3002: ('sgtsit', 'sgtatk', 'dmpain', 'sgtdth', 'dmact'),
    58: ('sgtsit', 'sgtatk', 'dmpain', 'sgtdth', 'dmact'),
    3003: ('brssit', 'claw', 'firsht', 'firxpl', 'dmpain', 'brsdth', 'dmact'),
    2035: ('barexp',),
    2001: ('wpnup',), 2002: ('wpnup',), 2003: ('wpnup',), 2005: ('wpnup',),
    2013: ('getpow',), 2022: ('getpow',), 2023: ('getpow',), 2024: ('getpow',),
    2025: ('getpow',), 2026: ('getpow',), 2045: ('getpow',),
}

# The sounds of the weapons that a thing gives; the player keeps them in
# the maps after it (the rocket explodes with barexp).
WEAPON_SOUNDS = {
    2001: ('shotgn',), 9: ('shotgn',), 2002: ('pistol',), 2003: ('rlaunc', 'barexp'),
    2005: ('sawup', 'sawidl', 'sawful', 'sawhit'),
}

# Sounds triggered by line specials (P_CrossSpecialLine,
# P_UseSpecialLine, P_ShootSpecialLine; the moving floors play stnmov and
# pstop, the lifts pstart and pstop, a switch swtchn).
LINE_SOUNDS = (
    ({1, 2, 16, 26, 27, 28, 31, 32, 33, 34, 46, 63, 76, 86, 90, 103}, ('doropn', 'dorcls')),
    ({5, 7, 8, 9, 18, 20, 22, 23, 36, 70, 82, 91, 98}, ('stnmov', 'pstop')),
    ({62, 88}, ('pstart', 'pstop')),
    ({97}, ('telept',)),
    ({7, 9, 11, 18, 20, 23, 46, 51, 62, 63, 70, 103}, ('swtchn',)),
)


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def tables():
    t = {}
    t['HI4'] = [sext(b >> 4, 4) for b in range(256)]
    t['LO4'] = [sext(b, 4) for b in range(256)]
    for j, name in enumerate(('S2A', 'S2B', 'S2C', 'S2D')):
        t[name] = [sext(b >> (6 - 2 * j), 2) for b in range(256)]
    # 4 residuals of 6 bits in b0 b1 b2: v0 = b0 >> 2, v1 = (b0 & 3) << 4 | b1 >> 4,
    # v2 = (b1 & 15) << 2 | b2 >> 6, v3 = b2 & 63. The sign of v1 and v2 is in
    # the high part, so the high part table has it.
    t['S6A'] = [sext(b >> 2, 6) for b in range(256)]
    t['S6BH'] = [((b & 3) << 4) - 64 * ((b >> 1) & 1) for b in range(256)]
    t['S6BL'] = [b >> 4 for b in range(256)]
    t['S6CH'] = [((b & 15) << 2) - 64 * ((b >> 3) & 1) for b in range(256)]
    t['S6CL'] = [b >> 6 for b in range(256)]
    t['S6D'] = [sext(b, 6) for b in range(256)]
    return b''.join(bytes(v & 255 for v in t[name]) for name in TABLES)


def residual(x, i, order, block_start_hist):
    x1, x2 = block_start_hist(i)
    p = 128 if order == 0 else x1 if order == 1 else 2 * x1 - x2
    e = (x[i] - p) & 255
    return e - 256 if e >= 128 else e


def fits(es, w):
    if w == 0:
        return all(e == 0 for e in es)
    return all(-(1 << (w - 1)) <= e < (1 << (w - 1)) for e in es)


def pack(es, w):
    if w == 0:
        return b''
    bits = 0
    for e in es:
        bits = (bits << w) | (e & ((1 << w) - 1))
    return bits.to_bytes(2 * w, 'big')


def encode(x):
    """Blocks of the samples x (values 1..255)."""
    n = (len(x) + 15) // 16 * 16
    x = x + [x[-1]] * (n - len(x))
    out = bytearray()

    def hist(i):
        return (x[i - 1] if i >= 1 else 128), (x[i - 2] if i >= 2 else 128)

    for s in range(0, n, 16):
        best = None
        for order in (0, 1, 2):
            es = [residual(x, i, order, hist) for i in range(s, s + 16)]
            w = next(w for w in WIDTHS if fits(es, w))
            if best is None or w < best[1]:
                best = (order, w, es)
        order, w, es = best
        out.append(order << 4 | w)
        out += pack(es, w)
    return bytes(out)


def decode(data, nblocks):
    """The decoder of src/iigs/i_snd65.s, for the self test."""
    t = tables()
    tab = {name: t[k * 256:(k + 1) * 256] for k, name in enumerate(TABLES)}
    out = []
    x1 = x2 = 128
    p = 0
    for _ in range(nblocks):
        h = data[p]
        p += 1
        order, w = h >> 4, h & 15
        es = []
        if w == 0:
            es = [0] * 16
        elif w == 8:
            es = list(data[p:p + 16])
        elif w == 4:
            for b in data[p:p + 8]:
                es += [tab['HI4'][b], tab['LO4'][b]]
        elif w == 2:
            for b in data[p:p + 4]:
                es += [tab['S2A'][b], tab['S2B'][b], tab['S2C'][b], tab['S2D'][b]]
        elif w == 6:
            for g in range(4):
                b0, b1, b2 = data[p + 3 * g:p + 3 * g + 3]
                es += [tab['S6A'][b0], (tab['S6BH'][b0] + tab['S6BL'][b1]) & 255,
                       (tab['S6CH'][b1] + tab['S6CL'][b2]) & 255, tab['S6D'][b2]]
        else:
            sys.exit(f'bad block header {h:#x}')
        p += 2 * w
        slope = (x1 - x2) & 255
        for e in es:
            if order == 0:
                v = (e + 128) & 255
            elif order == 1:
                v = (x1 + e) & 255
            else:
                slope = (slope + e) & 255
                v = (x1 + slope) & 255
            x2, x1 = x1, v
            out.append(v)
    return out


def bessel_i0(x):
    s = term = 1.0
    k = 1
    while term > 1e-12 * s:
        term *= (x / (2 * k)) ** 2
        s += term
        k += 1
    return s


def resample(x, n):
    """The samples x (values 1..255, around 128) as n samples of the same
    length of time, as floats around 0 (not rounded)."""
    step = len(x) / n                   # input samples for each output sample
    fc = 0.46 / step                    # cutoff, cycles for each input sample
    half = 8 / (2 * fc)                 # 8 zero crossings on each side
    beta = 7.0
    i0b = bessel_i0(beta)
    grid = 64
    kern = []
    for g in range(int(half * grid) + 2):
        u = g / grid
        if u > half:
            kern.append(0.0)
            continue
        sinc = 2 * fc if u == 0 else math.sin(2 * math.pi * fc * u) / (math.pi * u)
        w = bessel_i0(beta * math.sqrt(1 - (u / half) ** 2)) / i0b
        kern.append(sinc * w)
    xs = [v - 128 for v in x]
    y = []
    for k in range(n):
        c = (k + 0.5) * step - 0.5
        lo = max(0, math.ceil(c - half))
        hi = min(len(xs) - 1, math.floor(c + half))
        acc = 0.0
        for j in range(lo, hi + 1):
            acc += xs[j] * kern[int(abs(c - j) * grid + 0.5)]
        y.append(acc)
    a = 0.12                            # treble lift for the flat steps
    return [y[k] + a * (2 * y[k] - y[k - 1 if k else k] - y[k + 1 if k + 1 < n else k]) for k in range(n)]


def fft(a):
    n = len(a)
    if n == 1:
        return a
    ev, od = fft(a[0::2]), fft(a[1::2])
    out = [0] * n
    for k in range(n // 2):
        t = cmath.exp(-2j * math.pi * k / n) * od[k]
        out[k] = ev[k] + t
        out[k + n // 2] = ev[k] - t
    return out


def band(x, rate):
    """The frequency below which SHARE of the energy of x lies."""
    n = 1024
    w = [0.5 - 0.5 * math.cos(2 * math.pi * i / n) for i in range(n)]
    xs = [v - 128 for v in x]
    xs += [0] * max(0, n - len(xs))
    acc = [0.0] * (n // 2)
    for s in range(0, len(xs) - n + 1, n // 2):
        f = fft([xs[s + i] * w[i] for i in range(n)])
        for k in range(n // 2):
            acc[k] += abs(f[k]) ** 2
    total = sum(acc) or 1.0
    c = 0.0
    for k, p in enumerate(acc):
        c += p
        if c >= SHARE * total:
            return (k + 1) * rate / n
    return rate / 2


def trim(x):
    peak = max((abs(v - 128) for v in x), default=0)
    thr = max(3, peak * 10 ** (-TAIL_DB / 20))
    lo, hi = 0, len(x)
    while lo < hi and abs(x[lo] - 128) <= thr:
        lo += 1
    while hi > lo and abs(x[hi - 1] - 128) <= thr:
        hi -= 1
    return x[lo:hi]


def limit(z):
    """z cut to MAXLEN samples, with a linear fade over the last FADE."""
    if len(z) <= MAXLEN:
        return z
    z = z[:MAXLEN]
    for i in range(FADE):
        z[MAXLEN - FADE + i] *= (FADE - i) / (FADE + 1)
    return z


def limiter(z, rate):
    """z with no sample above CEIL. The gain dips smoothly around each peak,
    over about 1.2 ms. The old code cut the peak at the byte 1 or 255."""
    if max(abs(v) for v in z) <= CEIL:
        return z
    n = len(z)
    w = max(2, round(rate * 0.0006))
    g = [CEIL / abs(v) if abs(v) > CEIL else 1.0 for v in z]
    m = [min(g[max(0, i - w):i + w + 1]) for i in range(n)]      # so the average keeps each peak under CEIL
    h = [0.5 + 0.5 * math.cos(math.pi * k / (w + 1)) for k in range(-w, w + 1)]
    t = sum(h)
    return [v * sum(h[k + w] * (m[i + k] if 0 <= i + k < n else 1.0) for k in range(-w, w + 1)) / t
            for i, v in enumerate(z)]


def fades(z, rate):
    """z with a fade (half a Hann window of FADE_MS) at a start or an end that
    is loud: more than a quarter of the peak. A start that is the first step
    of a rising attack gets no fade (the pistol starts at -48, then -121)."""
    n = len(z)
    peak = max(abs(v) for v in z)
    f = min(max(4, round(rate * FADE_MS / 1000)), n // 8)
    z = list(z)
    ramp = [0.5 - 0.5 * math.cos(math.pi * (i + 1) / (f + 1)) for i in range(f)]
    if abs(z[0]) > 0.25 * peak and abs(z[0]) >= max(abs(v) for v in z[1:4]):
        for i in range(f):
            z[i] *= ramp[i]
    if max(abs(v) for v in z[-4:]) > 0.25 * peak:
        for i in range(f):
            z[n - 1 - i] *= ramp[i]
    return z


def finish(z):
    """(samples 1..255, level): z (floats around 0, no sample above CEIL) as
    samples at full scale, and the level of the sound: its peak as a
    fraction of 127. The sound has the same loudness as before when its
    volume register is the level times the register of a sound at level 1."""
    peak = max(abs(v) for v in z)
    scale = CEIL / peak if peak else 1.0
    return [min(255, max(1, round(128 + v * scale))) for v in z], min(1.0, round(peak) / 127)


def small(x, rate):
    """(samples, rate): x without its silent ends, at the lowest rate SR / k
    that keeps its band, as floats around 0."""
    x = trim(x)
    if not x:
        return x, rate
    b = band(x, rate)
    k = max(KMIN, min(KMAX, int(SR * 0.42 / b)))

    def size(k):
        return math.ceil(len(x) * SR / k / rate)

    def table(n):
        t = 256
        while t < n + 1:
            t *= 2
        return t

    if size(4) <= 2047:
        k = 4
    elif b > 0.42 * SR / k:
        for up in range(4, k):
            if size(up) <= MAXLEN and table(size(up)) == table(size(k)):
                k = up
                break
    new = round(SR / k)
    if new < rate:
        z = resample(x, max(1, round(len(x) * new / rate)))
    else:
        new = rate
        z = [float(v - 128) for v in x]
    return fades(limiter(limit(z), new), new), new


def read_wad(path):
    """The lumps of the WAD by name (the first lump of each name), and the
    THINGS and LINEDEFS lumps of each map by map number."""
    d = open(path, 'rb').read()
    _ident, n, off = struct.unpack_from('<4sii', d, 0)
    lumps = {}
    names = []
    for i in range(n):
        fp, sz, nm = struct.unpack_from('<ii8s', d, off + 16 * i)
        nm = nm.rstrip(b'\0').decode('ascii').upper()
        names.append((nm, d[fp:fp + sz]))
        lumps.setdefault(nm, d[fp:fp + sz])
    maps = {}
    for i, (nm, _) in enumerate(names):
        m = re.fullmatch(r'E1M(\d)', nm)
        if m:
            parts = dict(names[i + 1:i + 11])
            maps[int(m.group(1))] = (parts['THINGS'], parts['LINEDEFS'])
    return lumps, maps


def map_sounds(maps):
    """The sounds that each map can start: its things, its line specials,
    the player, and the weapons of the maps before it."""
    need = {}
    carried = set()
    for m in MAP_ORDER:
        things, lines = maps[m]
        s = set(PLAYER_SOUNDS)
        for i in range(0, len(things), 10):
            kind, flags = struct.unpack_from('<hh', things, i + 6)
            if flags & MTF_MULTI:
                continue
            s.update(THING_SOUNDS.get(kind, ()))
            carried.update(WEAPON_SOUNDS.get(kind, ()))
        for i in range(0, len(lines), 14):
            special = struct.unpack_from('<h', lines, i + 6)[0]
            for specials, sounds in LINE_SOUNDS:
                if special in specials:
                    s.update(sounds)
        need[m] = s | carried
    return need


def plan(need, size, prev, pin_end, sfx_end):
    """The DOC RAM plan of a map: {sound: first page}. Pages below pin_end
    hold the sounds with the most starts for each page (they stay for the
    whole map); the pool up to sfx_end holds the next sounds at the start
    of the map, and src/iigs/s_sound65.s replaces them there by need. A
    variant without its own place plays its stand-in (VARIANTS), so the
    stand-in counts the starts of its variants, and a variant counts a
    quarter of its own. Each sound goes to the smallest free run that
    holds it (a table starts at a multiple of its size, so the end of a
    table is free for small sounds), or to its place in prev, the plan of
    the map before (no upload at the map start)."""
    value = {s: STARTS.get(s, 0.5) for s in need}
    for v, (s, pitch) in VARIANTS.items():
        if v in need and s in need:
            value[s] += value[v]
            value[v] /= 4
            if pitch == 128:            # the same samples: always the stand-in
                need = need - {v}
    order = sorted(need, key=lambda s: (-value[s] / pages(size[s]), s))
    owner = [None] * sfx_end
    placed = {}
    for lo, hi in ((0, pin_end), (pin_end, sfx_end)):
        for s in order:
            if s in placed:
                continue
            n, step = pages(size[s]), table(size[s]) // 256
            best = None
            for st in range(lo + (-lo) % step, hi - n + 1, step):
                if any(owner[p] for p in range(st, st + n)):
                    continue
                a, b = st, st + n       # the free run around the place
                while a > lo and owner[a - 1] is None:
                    a -= 1
                while b < hi and owner[b] is None:
                    b += 1
                fit = (prev.get(s) != st, b - a, st)
                if best is None or fit < best:
                    best = fit
            if best:
                st = best[2]
                owner[st:st + n] = [s] * n
                placed[s] = st
    return placed, value


def song_pages(path):
    """{map: the DOC pages of its song} of a music bank (the song of map m
    is song m - 1; its image: byte 4 is its lowest DOC page, to 254)."""
    b = open(path, 'rb').read()
    out = {}
    for m in range(1, MAPS + 1):
        off, n = struct.unpack_from('<II', b, 2 + 8 * (m - 1))
        if n:
            out[m] = DOC_PAGES - b[off + 4]
    return out


def pages(n):
    """DOC RAM pages of a sound of n samples and its 0 byte."""
    return (n + 256) >> 8


def table(n):
    """The table size of a sound of n samples and its 0 byte."""
    t = 256
    while t < n + 1:
        t *= 2
    return t


def sfx_names(path):
    """The sound names in sfxenum_t order, from the CONST_SFX_ numbers of
    src/iigs/offsets.inc."""
    found = re.findall(r'^CONST_SFX_(\w+)\s+\.equ\s+(\d+)', open(path).read(), re.M)
    names = [None] * len(found)
    for name, value in found:
        names[int(value)] = name.lower()
    names[0] = 'None'
    return names


def write_law(path, names, level):
    """Write the tables of docVolume (src/iigs/s_sound65.s): sfxK for each
    sound, panCap for each separation 0-254."""
    text = ['; Made by tools/sndbank.py: the tables of docVolume. sfxK: one word for each sound in the',
            f'; order of sfxenum_t, 65536 * level / {FULL_DIV}. panCap: one word for each separation 0 to 254,',
            f'; {PAN_TOP} / the larger of sep and 254 - sep.',
            'sfxK:']
    for name in names:
        k = round(65536 * level[name] / FULL_DIV) if name in level else round(65536 / FULL_DIV)
        text.append(f'              .word   {k:<5d}            ; {name}')
    text.append('panCap:')
    for sep in range(255):
        text.append(f'              .word   {PAN_TOP // max(sep, 254 - sep):<4d}             ; sep {sep}')
    open(path, 'w').write('\n'.join(text) + '\n')


def main():
    args = sys.argv[1:]
    law_inc = None
    if '--law' in args:
        i = args.index('--law')
        law_inc = args[i + 1]
        del args[i:i + 2]
    wad, header, out = args[0:3]
    music = args[3] if len(args) > 3 else None
    lumps, maps = read_wad(wad)
    names = sfx_names(header)
    num = {name: i for i, name in enumerate(names)}
    bank = bytearray(tables())
    assert len(bank) == DIR_OFS
    bank += struct.pack('<H', len(names))
    bank += bytes(8 * len(names))
    plan_ofs = len(bank)
    bank += bytes(2 * len(names) + (2 * MAPS + 1) * (2 + len(names)))
    raw = coded = 0
    size = {}
    samples = {}
    level = {}
    for i, name in enumerate(names):
        lump = lumps.get('DS' + name.upper())
        if i == 0 or lump is None or name in NEVER:
            continue
        fmt, rate, count = struct.unpack_from('<HHI', lump, 0)
        if fmt != 3 or count > len(lump) - 8 or count <= 48:
            sys.exit(f'DS{name.upper()}: not a DMX sound')
        x = [max(1, b) for b in lump[8 + 16:8 + count - 16]]
        z, rate = small(x, rate)
        if not z:
            continue
        x, level[name] = finish(z)
        same = samples.get(bytes(x))
        if same is not None:            # the same samples: the same blocks
            struct.pack_into('<IHH', bank, DIR_OFS + 2 + 8 * i,
                             *struct.unpack_from('<IHH', bank, DIR_OFS + 2 + 8 * same))
            size[name] = len(x)
            continue
        blocks = encode(x)
        n = (len(x) + 15) // 16
        if decode(blocks, n)[:len(x)] != x:
            sys.exit(f'DS{name.upper()}: the decoder does not give the samples back')
        struct.pack_into('<IHH', bank, DIR_OFS + 2 + 8 * i, len(bank), len(x), rate)
        samples[bytes(x)] = i
        size[name] = len(x)
        bank += blocks
        raw += len(x)
        coded += len(blocks)

    for v, (s, pitch) in VARIANTS.items():
        bank[plan_ofs + num[v]] = num[s]
        bank[plan_ofs + len(names) + num[v]] = pitch
    need = map_sounds(maps)
    prev = {}
    for m in MAP_ORDER:
        sfx_end = DOC_PAGES - MUSIC_PAGES.get(m, 0)
        pin_end = sfx_end - POOL
        missing = need[m] - set(size)
        if missing:
            sys.exit(f'E1M{m}: no samples for {sorted(missing)}')
        placed, value = plan(need[m], size, prev, pin_end, sfx_end)
        row = plan_ofs + 2 * len(names) + m * (2 + len(names))
        bank[row:row + 2 + len(names)] = bytes([pin_end, sfx_end]) + bytes([255] * len(names))
        for s, p in placed.items():
            bank[row + 2 + num[s]] = p
        pinned = sorted((s for s in placed if placed[s] < pin_end), key=lambda s: placed[s])
        pool = sorted((s for s in placed if placed[s] >= pin_end), key=lambda s: placed[s])
        out_of = sorted((s for s in need[m] - set(placed) if VARIANTS.get(s, (0, 0))[1] != 128),
                        key=lambda s: -value[s])
        print(f'E1M{m}: {len(need[m])} sounds; pages 0-{pin_end - 1} keep {len(pinned)} '
              f'({sum(pages(size[s]) for s in pinned)} pages), pool {pin_end}-{sfx_end - 1} '
              f'starts with {len(pool)}; {len(out_of)} by need: {" ".join(out_of)}')
        prev = placed
    songs = song_pages(music) if music else {}
    prev = {}
    for m in MAP_ORDER:
        row = plan_ofs + 2 * len(names) + (MAPS + m) * (2 + len(names))
        if m not in songs:
            off = plan_ofs + 2 * len(names) + m * (2 + len(names))
            bank[row:row + 2 + len(names)] = bank[off:off + 2 + len(names)]
            continue
        sfx_end = DOC_PAGES - songs[m]
        placed, value = plan(need[m], size, prev, 0, sfx_end)
        bank[row:row + 2 + len(names)] = bytes([0, sfx_end]) + bytes([255] * len(names))
        for s, p in placed.items():
            bank[row + 2 + num[s]] = p
        print(f'E1M{m} with its song ({songs[m]} pages): pool 0-{sfx_end - 1} starts with {len(placed)}')
        prev = placed
    row = plan_ofs + 2 * len(names)
    bank[row:row + 2 + len(names)] = bytes([0, DOC_PAGES]) + bytes([255] * len(names))
    if out != '-':
        open(out, 'wb').write(bank)
    if law_inc:
        write_law(law_inc, names, level)
    print(f'{out}: {len(size)} sfx, {raw} samples in {coded} bytes, {len(bank)} bytes')


if __name__ == '__main__':
    main()
