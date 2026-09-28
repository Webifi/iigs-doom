#!/usr/bin/env python3
"""256-byte DOC wave tables of GENMIDI voices, for tools/musbank.py.

tone(data, freq, top_hz, start_ms): one period of the sound of a voice (the
OPL2 channel of tools/oplsynth.py with the key held) at the OPL frequency
word freq, measured from start_ms after key on, as 256 unsigned bytes 1-255
(0 halts the DOC). The table holds one period of both operators: gcd of
their multiples / 2 of the note (ratio). Harmonics that would pass 13 kHz
at top_hz (the highest note on the table) are left out: the DOC has no
filter, so they would alias. Index 0 is the phase of key on (both
operators start there), so a note that starts the table at 0 starts as
the OPL does, with no click.
noise(data, freq): 256 samples of the sound at the DOC rate, for the drums
that the feedback of the modulator makes noise."""
import cmath
import math
import oplsynth

RATE = oplsynth.RATE
DOC_RATE = 894886.0 / 34
NYQ = DOC_RATE / 2 * 0.95


def opl_hz(freq):
    return (freq & 0x3ff) * RATE / (1 << (20 - ((freq >> 10) & 7)))


def ratio(data):
    mm = oplsynth.MT[data[0] & 15]
    mc = oplsynth.MT[data[7] & 15]
    return math.gcd(mm, mc) / 2.0


def _render(data, freq, n0, n1):
    """Samples n0..n1-1 of a key-on at 0, DMX levels at full volume (the
    carrier at 0, the modulator at its patch level)."""
    ch = oplsynth.Channel(data)
    ch.set_freq(freq & 0x3ff, (freq >> 10) & 7)
    ch.car.tl = 0
    # the key scale level of a sounding operator is in the note's level
    # (tools/musbank.py), not in the table; the modulator's shapes the tone
    ch.car.ksl = 0
    if data[6] & 1:
        ch.mod.ksl = 0
    ch.key_on()
    out = []
    for n in range(n1):
        v = ch.sample()
        if n >= n0:
            out.append(v)
    return out


def _to_bytes(w):
    peak = max(abs(x) for x in w) or 1.0
    return bytes(max(1, min(255, 128 + int(round(x * 127.0 / peak)))) for x in w), peak


def tone(data, freq, top_hz, start_ms):
    ft = opl_hz(freq) * ratio(data)              # table periods a second
    periods = max(8, int(0.05 * ft))
    n0 = int(start_ms * RATE / 1000)
    n = int(periods * RATE / ft)
    x = _render(data, freq, n0, n0 + n)
    hmax = max(1, min(127, int(NYQ / (top_hz * ratio(data)))))
    step = cmath.exp(-2j * math.pi * ft / RATE)
    coef = []
    for h in range(1, hmax + 1):
        wh = step ** h
        z = 0j
        e = 1 + 0j
        for v in x:
            z += v * e
            e *= wh
        coef.append(2 * z / n)
    phi0 = ft * n0 / RATE                        # table phase at the window
    table = []
    for j in range(256):
        s = 0.0
        for h, c in enumerate(coef, 1):
            s += (c * cmath.exp(2j * math.pi * h * (j / 256.0 - phi0))).real
        table.append(s)
    b, peak = _to_bytes(table)
    return b, ratio(data), peak


def noise(data, freq, start_ms=3):
    n0 = int(start_ms * RATE / 1000)
    n = int(256 * RATE / DOC_RATE) + 2
    x = _render(data, freq, n0, n0 + n)
    out = []
    for j in range(256):
        t = j * RATE / DOC_RATE
        i = int(t)
        a = t - i
        out.append(x[i] * (1 - a) + x[i + 1] * a)
    return _to_bytes(out)
