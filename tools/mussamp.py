#!/usr/bin/env python3
"""DOC tables for the instruments of a song (tools/musbank.py).

A zone is one sound (a GENMIDI voice: its 16 bytes) over a pitch range of at
most an octave. Its table is the voice rendered by tools/oplchip.py at the
zone's top note (lower notes play the table slower: no alias), resampled to
the table's rate. Kinds:

- loop: this encoder fits n periods into L - 1 samples and repeats byte 0
  at byte L - 1. That is the encoder's seam convention, not a reduction of
  the DOC's configured table length. Noisy sounds (such as the distortion
  guitar's feedback) use a longer loop with a crossfade at the seam. The
  carrier envelope is divided out: the player writes it as volume steps.
- oneshot: the whole sound of a drum, envelope in, a 0 byte after it (the
  DOC halts there).
- attack: the start of a drum, envelope in, then its loop (noise, or n
  periods of a tonal drum) at the level where the attack ends; the loop is
  the last bytes of the table, a table of its own: the player switches the
  oscillator to it (pointer and size) after the attack, and writes the rest
  of the envelope as volume steps.

The DOC plays a table without interpolation, so a table at a low rate adds
images of its sound: the rates stay at 8 kHz or more.
"""
import cmath
import math

import musdsp
import oplchip

OPL_RATE = oplchip.RATE
DOC_RATE = 894886.0 / 34
MAX_RATE = DOC_RATE                     # the top note plays one table byte a DOC sample
DRUM_MAX_RATE = 16000.0
DRUM_MIN_RATE = 8000.0
ONESHOT_BYTES = 2048


def opl_hz(freq):
    """The frequency of an OPL frequency word (block << 10 | F-number)."""
    return (freq & 0x3ff) * OPL_RATE / (1 << (20 - ((freq >> 10) & 7)))


def pair_ratio(data):
    """The fundamental of a voice's sound over its channel frequency: the
    gcd of the operators' multipliers (units of 1/2)."""
    mm = oplchip.MT[data[0] & 15]
    mc = oplchip.MT[data[7] & 15]
    return math.gcd(mm, mc) / 2.0


def render(data, freq, secs, key_off=None):
    """(y, eg): the voice at freq with its carrier at level 0 and no key
    scale level (the player's level has them), and the carrier attenuation
    (units of 3/16 dB) each sample, for an additive voice that of both
    operators. No tremolo or vibrato: a loop cannot hold them."""
    chip = oplchip.Chip()
    v = oplchip.Voice(chip)
    d = bytearray(data)
    d[0] &= 0x3f
    d[7] &= 0x3f
    v.set_instrument(bytes(d))
    v.car.ksl, v.car.tl = 0, 0
    v.set_freq(freq)
    v.mod.key = v.car.key = 1
    off = None if key_off is None else int(key_off * OPL_RATE)
    y, eg = [], []
    for i in range(int(secs * OPL_RATE)):
        if i == off:
            v.mod.key = v.car.key = 0
        s = v.sample()
        e = v.car.eg_rout
        if v.con:
            em = min(511, v.mod.eg_rout + (v.mod.tl << 2))
            a = 2.0 ** (-e / 16.0) + 2.0 ** (-em / 16.0)
            e = -16.0 * math.log2(a) if a > 0 else 511
        y.append(s)
        eg.append(e)
        chip.step()
    return y, eg


def normalized(y, eg, ref=0.0, clamp=160):
    """y with the envelope divided out, at the level ref (units)."""
    return [s * 2.0 ** ((min(e, clamp) - ref) / 32.0) for s, e in zip(y, eg)]


def period_corr(x, p, a, b):
    """The correlation of x[a:b] with x one (fractional) period p later."""
    ip = int(p)
    fr = p - ip
    s1 = x[a:b]
    s2 = [x[i + ip] * (1 - fr) + x[i + ip + 1] * fr for i in range(a, b)]
    m1 = sum(s1) / len(s1)
    m2 = sum(s2) / len(s2)
    num = sum((u - m1) * (w - m2) for u, w in zip(s1, s2))
    d1 = math.sqrt(sum((u - m1) ** 2 for u in s1))
    d2 = math.sqrt(sum((w - m2) ** 2 for w in s2))
    return num / (d1 * d2 + 1e-9)


def band(x, rate, frac=0.99):
    """The frequency under which frac of the power of x lies."""
    f, p = musdsp.power_spectrum(x, rate)
    s = sum(p) or 1.0
    c = 0.0
    for fi, pi in zip(f, p):
        c += pi
        if c >= frac * s:
            return fi
    return f[-1]


def audible_len(y, floor_db=-35.0, blk=256):
    """Samples of y until it stays under floor_db of its loudest block."""
    env = [musdsp.rms(y[i:i + blk]) for i in range(0, max(1, len(y) - blk), blk)]
    pk = max(env) or 1.0
    th = pk * 10 ** (floor_db / 20.0)
    last = 0
    for i, e in enumerate(env):
        if e >= th:
            last = i
    return min(len(y), (last + 1) * blk)


def to_bytes(x, peak=None):
    """8-bit DOC samples 1-255 around 128 (0 halts an oscillator)."""
    if peak is None:
        peak = max(abs(v) for v in x) or 1.0
    return bytes(max(1, min(255, 128 + int(round(v * 127.0 / peak)))) for v in x), peak


def gain_of(peak):
    """The level (units) of a table scaled to peak, against a full-scale
    operator (4096)."""
    return -32.0 * math.log2(max(peak, 1.0) / 4096.0)


def harmonic_loop(x, a, f0, rate, L=256):
    """L bytes' worth of samples: n whole periods of f0 in L - 1 samples at
    rate (the harmonics of the steady signal x from sample a, below 0.95 of
    the Nyquist of rate), then sample L - 1 = sample 0."""
    n = max(1, int(round((L - 1) * f0 / rate)))
    P = OPL_RATE / f0
    w1 = a + int(round(max(4, int(0.03 * f0)) * P))
    hmax = max(1, int(0.95 * rate / 2 / f0))
    coef = []
    for h in range(1, hmax + 1):
        step = cmath.exp(-2j * math.pi * h * f0 / OPL_RATE)
        e = 1 + 0j
        acc = 0j
        for i in range(a, w1):
            acc += x[i] * e
            e *= step
        coef.append(2 * acc / (w1 - a))
    out = []
    for j in range(L - 1):
        t = j * n / ((L - 1) * f0)
        v = 0.0
        for h, c in enumerate(coef, 1):
            v += (c * cmath.exp(2j * math.pi * h * f0 * t)).real
        out.append(v)
    out.append(out[0])
    return out


def noise_loop(x, a, L, xfade=64):
    """L bytes' worth of samples of x from a, the last xfade samples faded
    into the ones before a (a seam with no step), sample L - 1 = sample 0."""
    body = x[a + xfade:a + xfade + L - 1]
    pre = x[a:a + xfade]
    for i in range(xfade):
        w = i / xfade
        body[L - 1 - xfade + i] = body[L - 1 - xfade + i] * (1 - w) + pre[i] * w
    return body + [body[0]]


class Zone:
    """A table: a sound (data: 16 bytes of a GENMIDI voice) for the OPL
    frequency words freqs (at most an octave). rate: the table's sample rate
    at the top note; size: its bytes (a power of 2 from 256); kind: loop,
    oneshot or attack; gain: its level in units."""

    def __init__(self, data, freqs, name):
        self.data = data
        self.name = name
        self.ratio = pair_ratio(data)
        self.freqs = sorted(freqs, key=opl_hz)
        self.f_top = opl_hz(self.freqs[-1]) * self.ratio
        self.f_lo = opl_hz(self.freqs[0]) * self.ratio
        self.kind = 'loop'
        self.noisy = False
        self.table = b''
        self.size = 256
        self.rate = MAX_RATE
        self.gain = 0.0
        self.loop_len = 0
        self.attack = 0.0
        self.eg_attack = 0.0
        self.dur = 0.0

    def fc(self, freq):
        """The DOC frequency of a note at OPL frequency word freq (the table
        at resolution = size: a byte each 512 accumulator steps)."""
        f = opl_hz(freq) * self.ratio
        return max(1, min(65535, int(round(512.0 * self.rate * f / self.f_top / DOC_RATE))))

    def ratio_of(self, freq):
        return opl_hz(freq) * self.ratio / self.f_top


def zones_for(data, freqs, name, span=2.0):
    """The zones of a sound: its frequencies in groups of at most span."""
    fs = sorted(set(freqs), key=opl_hz)
    out = []
    cur = [fs[0]]
    for f in fs[1:]:
        if opl_hz(f) / opl_hz(cur[0]) <= span:
            cur.append(f)
        else:
            out.append(Zone(data, cur, name))
            cur = [f]
    out.append(Zone(data, cur, name))
    return out


def build_melodic(z, settle_ms=60.0):
    """A loop: tonal (n periods in 255 samples) or noisy (1024 bytes of the
    sound, a crossfade at the seam)."""
    top = z.freqs[-1]
    f0 = opl_hz(top) * z.ratio
    y, eg = render(z.data, top, settle_ms / 1000.0 + 0.12)
    x = normalized(y, eg)
    a = int(settle_ms / 1000.0 * OPL_RATE)
    P = OPL_RATE / f0
    z.noisy = period_corr(x, P, a, min(len(x) - int(P) - 2, a + int(0.04 * OPL_RATE))) < 0.9
    if not z.noisy:
        L = 256
        n = max(1, int(math.ceil((L - 1) * f0 / MAX_RATE)))
        z.rate = (L - 1) * f0 / n
        loop = harmonic_loop(x, a, f0, z.rate, L)
    else:
        z.rate = min(MAX_RATE, max(DRUM_MIN_RATE, 2.2 * band(x[a:a + 8192], OPL_RATE)))
        L = 1024
        need = int((L + 256) * OPL_RATE / z.rate) + 64
        y2, eg2 = render(z.data, top, (a + need) / OPL_RATE + 0.01)
        src = normalized(y2, eg2)[a:a + need]
        loop = noise_loop(musdsp.resample(src, OPL_RATE, z.rate, taps=16), 0, L, 128)
    z.kind = 'loop'
    z.size = L
    z.table, peak = to_bytes(loop)
    z.gain = gain_of(peak)
    return z


def build_drum(z, held):
    """A drum (one pitch; held: the key time its samples assume, the median
    of the song's notes): a one-shot when the sound fits ONESHOT_BYTES at
    its rate, else an attack (50 ms) and a loop."""
    top = z.freqs[-1]
    y, eg = render(z.data, top, 3.0, held)
    n_aud = audible_len(y)
    f0 = opl_hz(top) * z.ratio
    x = normalized(y, eg)
    P = OPL_RATE / f0
    a20 = int(0.02 * OPL_RATE)
    corr = 0.0
    if P < 0.03 * OPL_RATE:
        corr = period_corr(x, P, a20, min(len(x) - int(P) - 2, a20 + int(0.03 * OPL_RATE)))
    fb = (z.data[6] >> 1) & 7
    z.noisy = fb == 7 or (fb >= 5 and corr < 0.8)
    b = band(y[:min(len(y), int(0.05 * OPL_RATE) + 1024)], OPL_RATE, 0.999)
    if z.noisy:
        z.rate = min(DRUM_MAX_RATE, max(DRUM_MIN_RATE, 2.2 * b))
    else:
        n = max(1, int(math.ceil(255 * f0 / DRUM_MAX_RATE)))
        z.rate = 255 * f0 / n                       # n periods in 255 samples
    m = int(n_aud * z.rate / OPL_RATE)
    if m + 1 <= ONESHOT_BYTES:
        xs = musdsp.resample(y[:n_aud], OPL_RATE, z.rate, taps=16)[:m]
        fade = min(len(xs), int(0.005 * z.rate))
        for i in range(fade):
            xs[len(xs) - fade + i] *= (fade - i) / fade
        size = 256
        while size < len(xs) + 1:
            size *= 2
        tb, peak = to_bytes(xs)
        z.table = tb + b'\0'
        z.size, z.kind = size, 'oneshot'
        z.dur = len(xs) / z.rate
        z.gain = gain_of(peak)
        return z
    A = int(0.05 * z.rate)
    slack = int(0.012 * z.rate)
    L = 512 if z.noisy else 256
    size = 256
    while size < A + slack + L:
        size *= 2
    need = int(size * OPL_RATE / z.rate) + 64
    xs = musdsp.resample(y[:need], OPL_RATE, z.rate, taps=16)[:size]
    e_a = eg[min(len(eg) - 1, int(A * OPL_RATE / z.rate))]
    if z.noisy:
        egs = [eg[min(len(eg) - 1, int(i * OPL_RATE / z.rate))] for i in range(len(xs))]
        norm = [v * 2.0 ** ((min(e, 160) - e_a) / 32.0) for v, e in zip(xs, egs)]
        loop = noise_loop(norm, A, L, min(64, L // 4))
    else:
        g = 2.0 ** (-min(e_a, 160) / 32.0)
        loop = [v * g for v in harmonic_loop(x, int(A * OPL_RATE / z.rate), f0, z.rate, L)]
    tab = xs[:A] + [loop[i % L] for i in range(A, size)]
    tb, peak = to_bytes(tab)
    z.table = tb
    z.size, z.kind = size, 'attack'
    z.loop_len = L
    z.attack = A / z.rate
    z.eg_attack = e_a
    z.gain = gain_of(peak)
    return z
