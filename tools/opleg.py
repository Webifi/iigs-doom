#!/usr/bin/env python3
"""The OPL2 envelope of a DMX note as a level curve in time, for
tools/musbank.py, in units of 3/16 dB (the attenuation of the OPL: 32
units = 6 dB, 511 = silence), from the exact envelope generator of
tools/oplsynth.py. The generator depends only on the effective rate
(4 x the register rate + the key scale part), so the attack curve and the
decay/release slope of each effective rate are simulated once (the decay
and the release are linear in these units); the rest is arithmetic.

Env(data, op, ksv): the envelope of operator op (0 modulator, 1 carrier) of
a GENMIDI voice (16 bytes) at key scale value ksv (block << 1 | the fnum
bit of the keyboard split; DMX sets note select 1: fnum bit 8).
  held(ms)            attenuation ms after key on, the key held
  release(level, ms)  attenuation ms after a key off at that level
Total level and key scale level are not included (see ksl_units)."""
import oplsynth

RATE = oplsynth.RATE                     # 49716 Hz
MS = RATE / 1000.0
SILENT = 511
ATTACK, DECAY, SUSTAIN, RELEASE = oplsynth.ATTACK, oplsynth.DECAY, oplsynth.SUSTAIN, oplsynth.RELEASE

_slopes = {}
_attacks = {}


def _slot_at(eff):
    """A channel and slot whose generator runs at effective rate eff."""
    ch = oplsynth.Channel(bytes(16))
    ch.set_freq(0x100, 0)
    ch.ksv = eff & 3                     # ks = ksv with the key scale rate on
    s = ch.car
    s.ksr = 1
    return ch, s, eff >> 2


def slope(eff):
    """Units a ms of a decay or release at effective rate eff."""
    if eff in _slopes:
        return _slopes[eff]
    if eff < 4:
        v = 0.0
    else:
        ch, s, r = _slot_at(eff)
        s.dr = r
        s.sl = 0x1f
        s.eg_rout = 0
        s.eg_gen = DECAY
        s.key = 1
        n, limit = 0, int(1500 * MS)
        while n < limit and s.eg_rout < 64:
            ch.envelope_only()
            n += 1
        v = s.eg_rout / (n / MS)
    _slopes[eff] = v
    return v


def attack(eff):
    """The attack from silence at effective rate eff: the level each ms up
    to level 0 (at most 5 s), and whether it reached 0."""
    if eff in _attacks:
        return _attacks[eff]
    if eff < 4:
        v = ([SILENT], False)
    else:
        ch, s, r = _slot_at(eff)
        s.ar = r
        s.dr = 0
        s.key = 1
        lev = []
        n, ms, nxt = 0, 0, 0.0
        while ms < 5000:
            ch.envelope_only()
            n += 1
            if n >= nxt:
                lev.append(s.eg_rout)
                ms += 1
                nxt = ms * MS
            if s.eg_gen != ATTACK and s.eg_gen != RELEASE:
                break
        v = (lev, s.eg_gen != ATTACK and s.eg_gen != RELEASE)
    _attacks[eff] = v
    return v


def eff_rate(reg_rate, ksr, ksv):
    if reg_rate == 0:
        return 0
    ks = ksv >> ((ksr ^ 1) << 1)
    return min(63, (reg_rate << 2) + ks)


class Env:
    def __init__(self, data, op, ksv):
        p = data[0:6] if op == 0 else data[7:13]
        self.egt = (p[0] >> 5) & 1
        ksr = (p[0] >> 4) & 1
        sl = p[2] >> 4
        self.sl = 0x1f * 16 if sl == 15 else sl * 16   # oplsynth: sl 15 -> 0x1f
        ar, dr, rr = p[1] >> 4, p[1] & 15, p[2] & 15
        self.attack, self.attack_done = attack(eff_rate(ar, ksr, ksv))
        self.ta = len(self.attack)
        self.sd = slope(eff_rate(dr, ksr, ksv))
        self.sr = slope(eff_rate(rr, ksr, ksv))
        self.td = self.sl / self.sd if self.sd > 0 else float('inf')

    def held(self, ms):
        if ms < self.ta:
            return self.attack[int(ms)]
        if not self.attack_done:
            return self.attack[-1]
        t = ms - self.ta
        if t < self.td:
            return min(SILENT, t * self.sd)
        lev = self.sl
        if not self.egt and self.sr > 0:
            lev += (t - self.td) * self.sr
        return min(SILENT, lev)

    def release(self, level, ms):
        return min(SILENT, level + ms * self.sr)


class Cache:
    def __init__(self):
        self.envs = {}

    def get(self, instr, iv, op, ksv):
        key = (instr.index, iv, op, ksv)
        e = self.envs.get(key)
        if e is None:
            e = self.envs[key] = Env(instr.voice(iv), op, ksv)
        return e


def ksv_of(freq):
    """The key scale value of an OPL frequency word: block << 1 | fnum bit
    8 (DMX writes 0x40 to register 8: note select 1)."""
    fnum, block = freq & 0x3ff, (freq >> 10) & 7
    return (block << 1) | ((fnum >> 8) & 1)


def ksl_units(freq, level_reg):
    """The key scale level attenuation (units) of an operator whose level
    register (scale in the top 2 bits) is level_reg, at an OPL frequency."""
    fnum, block = freq & 0x3ff, (freq >> 10) & 7
    ksl = (oplsynth.KSLROM[fnum >> 6] << 2) - ((8 - block) << 5)
    ksl = max(ksl, 0)
    return ksl >> oplsynth.KSLSHIFT[(level_reg >> 6) & 3]
