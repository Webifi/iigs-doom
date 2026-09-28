#!/usr/bin/env python3
"""gmref.py FONT.sf2 SONG OUT.wav [SECONDS]: a Doom song as a General MIDI
synthesizer plays it from a SoundFont, for reference: the MUS events as
mus2mid.c gives them (tools/dmxmus.py), each note on the regions of its
preset (tools/music/sf2.py; channel 9: the drum kit, bank 128), played as
FluidSynth does: linear interpolation, the region's loop, its volume
envelope (delay, attack, hold, decay to sustain, release after the note
off), its attenuation (0.4 x, as E-mu hardware), velocity and the channel
volume on the default concave curve (amplitude ~ (v / 127)^2), its low-pass
filter (initialFilterFc and Q, and the default velocity modulator: -2400
cents x (1 - v / 127) from velocity 64 up), pan from the region and
controller 10, pitch bend +-2 semitones, exclusive classes (the hi-hats cut
each other). No reverb or chorus. 44100 Hz stereo.
"""
import array
import math
import os
import sys
import wave

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, '..'))
sys.path.insert(0, _HERE)
import dmxmus
import sf2

RATE = 44100
BLOCK = 32                         # samples of one envelope step
WAD = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'data', 'DOOM1.WAD')


FILTER = os.environ.get('GMREF_FILTER', 'vel')    # vel: with the velocity modulator; fc: fixed; off


def filter_coefs(r, vel, env=None):
    """The biquad of FluidSynth's low-pass for a region and velocity (and its
    modulation envelope's value env, 0..1, which moves the cutoff by
    modEnvToFilterFc), or None (open)."""
    if FILTER == 'off':
        return None
    fc = r.fc - (2400.0 * (1.0 - vel / 127.0) if vel >= 64 and FILTER == 'vel' else 0.0)
    if env is not None and getattr(r, 'mod_to_fc', 0):
        fc += r.mod_to_fc * env
    if fc >= 13500:
        return None
    hz = min(0.45 * RATE, max(5.0, 8.176 * 2.0 ** (fc / 1200.0)))
    q_db = max(0.0, min(96.0, r.g.get('initialFilterQ', 0) / 10.0)) - 3.01
    q = 10.0 ** (q_db / 20.0)
    gain = 1.0 / math.sqrt(q)
    w = 2.0 * math.pi * hz / RATE
    alpha = math.sin(w) / (2.0 * q)
    a0 = 1.0 + alpha
    b1 = (1.0 - math.cos(w)) / a0 * gain
    return (b1 * 0.5, b1, b1 * 0.5, -2.0 * math.cos(w) / a0, (1.0 - alpha) / a0)


class Voice:
    def __init__(self, r, key, vel, chvol, chpan, bend):
        self.r = r
        s = r.sample
        self.data = s.data
        self.base = s.rate / RATE * 2.0 ** (r.tune / 12.0)
        self.step = self.base * 2.0 ** (bend / 12.0)
        self.pos = float(r.start)
        self.vel, self.chpan = vel, chpan
        self.set_volume(chvol)
        self.t = 0                    # samples since the note on
        self.off = None               # samples since the note on at the note off
        self.off_level = 1.0
        self.alive = True
        self.key = key
        self.vel = vel
        self.flt = filter_coefs(r, vel, 0.0 if getattr(r, 'mod_to_fc', 0) else None)
        self.z = [0.0, 0.0, 0.0, 0.0]  # x1, x2, y1, y2

    def set_volume(self, chvol):
        """The gains for the channel volume (controller 7 changes them while
        the note sounds, as FluidSynth does)."""
        r = self.r
        amp = (self.vel / 127.0) ** 2 * (chvol / 127.0) ** 2 * 10 ** (-r.atten / 20.0)
        pan = max(0.0, min(1.0, (self.chpan - 64) / 128.0 + 0.5 + r.pan))
        self.gl = amp * math.cos(pan * math.pi / 2)
        self.gr = amp * math.sin(pan * math.pi / 2)

    def env(self, t):
        r = self.r
        if self.off is None or t < self.off:
            return self.held(t / RATE)
        dt = (t - self.off) / RATE
        # the release: from the level at the note off to -100 dB in r.release
        if dt >= r.release:
            return 0.0
        return self.off_level * 10 ** (-100.0 * dt / r.release / 20.0)

    def held(self, t):
        r = self.r
        if t < r.delay:
            return 0.0
        t -= r.delay
        if t < r.attack:
            return t / r.attack
        t -= r.attack
        if t < r.hold:
            return 1.0
        t -= r.hold
        # the decay: 100 dB in r.decay seconds, down to the sustain level
        db = min(r.sustain, 100.0 * t / r.decay)
        return 10 ** (-db / 20.0)

    def note_off(self):
        if self.off is None:
            self.off_level = self.held(self.t / RATE)
            self.off = self.t


def mix(v, a, b, left, right):
    d = v.data
    r = v.r
    loop = r.mode in (1, 3) and r.le > r.ls + 1
    ls, le = r.ls, r.le
    ln = le - ls
    end = min(r.end, len(d)) - 1
    flt = v.flt
    if flt:
        b0, b1, b2, a1, a2 = flt
        x1, x2, y1, y2 = v.z
    i = a
    pos, step = v.pos, v.step
    while i < b:
        n = min(BLOCK, b - i)
        if getattr(r, 'mod_to_fc', 0):
            # the modulation envelope moves the cutoff (a pluck, a sweep)
            new = filter_coefs(r, v.vel, sf2.mod_env_at(r, v.t / RATE))
            if (new is None) != (flt is None) and new is not None and flt is None:
                x1 = x2 = y1 = y2 = 0.0
            flt = new
            if flt:
                b0, b1, b2, a1, a2 = flt
        e0 = v.env(v.t)
        e1 = v.env(v.t + n)
        if v.off is not None and e0 <= 1e-5 and e1 <= 1e-5:
            v.alive = False
            break
        de = (e1 - e0) / n
        e = e0
        gl, gr = v.gl, v.gr
        for j in range(i, i + n):
            if loop and pos >= le and (v.off is None or r.mode == 1):
                pos = ls + (pos - le) % ln
            k = int(pos)
            if k >= end:
                v.alive = False
                break
            x = d[k] + (d[k + 1] - d[k]) * (pos - k)
            if flt:
                y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2, x1, y2, y1 = x1, x, y1, y
                x = y
            x *= e
            left[j] += x * gl
            right[j] += x * gr
            e += de
            pos += step
        if not v.alive:
            break
        v.t += n
        i += n
    v.pos = pos
    if flt:
        v.z = [x1, x2, y1, y2]


ONLY = os.environ.get('GMREF_ONLY')        # e.g. 'p29,p30' or 'drums' or 'p34'
ONEREG = os.environ.get('GMREF_ONEREG')    # each note on one region (the one of least attenuation)


def wanted(ch, prog, key=None):
    if not ONLY:
        return True
    keys = ONLY.split(',')
    if ch == 9:
        return 'drums' in keys or 'k%d' % key in keys
    return 'p%d' % prog in keys


def render(font, name, seconds=None):
    sf = sf2.SF2(font)
    lumps = dmxmus.read_wad(WAD)
    groups, length = dmxmus.parse_mus(lumps[name])
    total = length / 140.0 if seconds is None else min(seconds, length / 140.0)
    n = int(total * RATE)
    left = array.array('f', bytes(4 * n))
    right = array.array('f', bytes(4 * n))
    prog = [0] * 16
    vol = [100] * 16
    pan = [64] * 16
    bend = [0.0] * 16
    voices = []
    t_prev = 0
    for tic, evs in groups + [(length, [])]:
        s0 = min(n, int(t_prev / 140.0 * RATE))
        s1 = min(n, int(tic / 140.0 * RATE))
        for v in voices:
            if v.alive:
                mix(v, s0, s1, left, right)
        voices = [v for v in voices if v.alive]
        if s1 >= n:
            break
        for kind, ch, a, b in evs:
            if kind == 'prog':
                prog[ch] = a
            elif kind == 'ctl':
                if a == 7:
                    vol[ch] = b
                    for v in voices:
                        if v.ch == ch:
                            v.set_volume(b)
                elif a == 10:
                    pan[ch] = b
                elif a in (0x78, 0x7b):
                    for v in voices:
                        if v.ch == ch:
                            v.note_off()
            elif kind == 'bend':
                bend[ch] = (a - 64) / 64.0 * 2.0
                for v in voices:
                    if v.ch == ch:
                        v.step = v.base * 2.0 ** (bend[ch] / 12.0)
            elif kind == 'on':
                bank, pr = (128, 0) if ch == 9 else (0, prog[ch])
                if not wanted(ch, pr, a):
                    continue
                regs = sf.regions(bank, pr, a, b)
                if ONEREG and regs:
                    regs = [min(regs, key=lambda r: r.atten)]   # (a test: our table's region only)
                for r in regs:
                    if r.excl:
                        for v in voices:
                            if v.ch == ch and v.r.excl == r.excl:
                                v.note_off()
                                v.cut = True
                    v = Voice(r, a, b, vol[ch], pan[ch], bend[ch])
                    v.ch = ch
                    voices.append(v)
            elif kind == 'off':
                for v in voices:
                    if v.ch == ch and v.key == a:
                        v.note_off()
        # an exclusive class cuts at once (FluidSynth: a fast release)
        for v in voices:
            if getattr(v, 'cut', False):
                v.r = _fast_release(v.r)
                v.cut = False
        t_prev = tic
    return left, right


def _fast_release(r):
    import copy
    q = copy.copy(r)
    q.release = 0.05
    return q


def write(path, l, r, rate=RATE, peak=None):
    peak = peak or max(max(abs(x) for x in l), max(abs(x) for x in r)) or 1.0
    g = 29000.0 / peak
    out = array.array('h')
    for a, b in zip(l, r):
        out.append(int(max(-32768, min(32767, a * g))))
        out.append(int(max(-32768, min(32767, b * g))))
    w = wave.open(path, 'wb')
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(rate)
    w.writeframes(out.tobytes())
    w.close()
    return peak


def main():
    font, name, path = sys.argv[1], sys.argv[2], sys.argv[3]
    secs = float(sys.argv[4]) if len(sys.argv) > 4 else None
    l, r = render(font, name, secs)
    # GMREF_PEAK: the scale of another render (a part against its whole song)
    peak = write(path, l, r, peak=float(os.environ['GMREF_PEAK']) if os.environ.get('GMREF_PEAK') else None)
    print('%s: %.1f s, peak %.6g' % (path, len(l) / RATE, peak))


if __name__ == '__main__':
    main()
