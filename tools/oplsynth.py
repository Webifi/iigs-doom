#!/usr/bin/env python3
"""A YM3812 (OPL2) channel renderer for the music tool (tools/musbank.py).

One channel of two operators, as Doom's DMX driver programs it, at the
chip's sample rate (RATE). The math follows the YM3812 as Nuked OPL3
models it: a quarter log-sine table and an exponent table, the envelope
generator with its rate steps and the key scale level, the feedback of the
first operator, and the two connections (frequency modulation, or the sum
of both operators). Tremolo and vibrato are left out: the music tool makes
one-cycle loops, which cannot hold them.

A GENMIDI voice (16 bytes) has, for the modulator and then the carrier,
the OPL registers $20 (tremolo byte), $60 (attack), $80 (sustain), $E0
(waveform), and the scale (the top 2 bits of $40) and level (its low 6
bits), with the feedback byte ($C0) between them.
"""

import math

RATE = 49716                    # the YM3812 sample rate, Hz

LOGSIN = [round(-math.log2(math.sin((i + 0.5) * math.pi / 512)) * 256) for i in range(256)]
EXP = [round(2 ** ((255 - i) / 256) * 1024) for i in range(256)]
MT = (1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 20, 24, 24, 30, 30)
KSLROM = (0, 32, 40, 45, 48, 51, 53, 55, 56, 58, 59, 60, 61, 62, 63, 64)
KSLSHIFT = (8, 1, 2, 0)
EG_INCSTEP = ((0, 0, 0, 0), (1, 0, 0, 0), (1, 0, 1, 0), (1, 1, 1, 0))
ATTACK, DECAY, SUSTAIN, RELEASE = range(4)


def exp_out(level):
    if level > 0x1fff:
        level = 0x1fff
    return (EXP[level & 0xff] << 1) >> (level >> 8)


def wave(wf, phase, env):
    """The operator output for waveform wf (0-3), a 10-bit phase and the
    9-bit attenuation env."""
    phase &= 0x3ff
    if wf == 0:
        out = LOGSIN[(phase & 0xff) ^ 0xff] if phase & 0x100 else LOGSIN[phase & 0xff]
        v = exp_out(out + (env << 3))
        return -v - 1 if phase & 0x200 else v
    if wf == 1:
        if phase & 0x200:
            return 0
        out = LOGSIN[(phase & 0xff) ^ 0xff] if phase & 0x100 else LOGSIN[phase & 0xff]
        return exp_out(out + (env << 3))
    if wf == 2:
        out = LOGSIN[(phase & 0xff) ^ 0xff] if phase & 0x100 else LOGSIN[phase & 0xff]
        return exp_out(out + (env << 3))
    if phase & 0x100:
        return 0
    return exp_out(LOGSIN[phase & 0xff] + (env << 3))


class Slot:
    """One operator: its registers and its envelope and phase state."""

    def __init__(self, tremolo, attack, sustain, waveform, scale, level):
        self.ksr = (tremolo >> 4) & 1
        self.egt = (tremolo >> 5) & 1
        self.mult = tremolo & 15
        self.ar, self.dr = attack >> 4, attack & 15
        self.sl, self.rr = sustain >> 4, sustain & 15
        if self.sl == 15:
            self.sl = 0x1f
        self.wf = waveform & 3
        self.ksl = scale >> 6
        self.tl = level & 0x3f
        self.eg_rout = 0x1ff
        self.eg_gen = RELEASE
        self.key = 0
        self.phase = 0
        self.out = 0
        self.prout = 0


class Channel:
    """A two-operator channel with DMX's register values for one GENMIDI
    voice. data: the 16 bytes of the voice."""

    def __init__(self, data):
        m, fb, c = data[0:6], data[6], data[7:13]
        self.mod = Slot(*m)
        self.car = Slot(*c)
        self.fb = (fb >> 1) & 7
        self.con = fb & 1
        self.fnum = 0
        self.block = 0
        self.timer = 0
        self.eg_state = 0
        self.eg_timer = 0
        self.eg_add = 0
        self.eg_timer_lo = 0

    def set_freq(self, fnum, block):
        self.fnum, self.block = fnum & 0x3ff, block & 7
        self.ksv = (self.block << 1) | ((self.fnum >> 9) & 1)
        ksl = (KSLROM[self.fnum >> 6] << 2) - ((8 - self.block) << 5)
        self.eg_ksl = max(ksl, 0)
        self.basefreq = (self.fnum << self.block) >> 1

    def key_on(self):
        self.mod.key = self.car.key = 1

    def key_off(self):
        self.mod.key = self.car.key = 0

    def envelope(self, s):
        """One step of the envelope generator of slot s; returns eg_out."""
        eg_out = s.eg_rout + (s.tl << 2) + (self.eg_ksl >> KSLSHIFT[s.ksl])
        if eg_out > 0x1ff:
            eg_out = 0x1ff
        reset = 0
        if s.key and s.eg_gen == RELEASE:
            reset = 1
            reg_rate = s.ar
        elif s.eg_gen == ATTACK:
            reg_rate = s.ar
        elif s.eg_gen == DECAY:
            reg_rate = s.dr
        elif s.eg_gen == SUSTAIN:
            reg_rate = 0 if s.egt else s.rr
        else:
            reg_rate = s.rr
        s.reset = reset
        ks = self.ksv >> ((s.ksr ^ 1) << 1)
        rate = ks + (reg_rate << 2)
        rate_hi, rate_lo = rate >> 2, rate & 3
        if rate_hi & 0x10:
            rate_hi = 0x0f
        shift = 0
        if reg_rate:
            if rate_hi < 12:
                if self.eg_state:
                    eg_shift = rate_hi + self.eg_add
                    if eg_shift == 12:
                        shift = 1
                    elif eg_shift == 13:
                        shift = (rate_lo >> 1) & 1
                    elif eg_shift == 14:
                        shift = rate_lo & 1
            else:
                shift = (rate_hi & 3) + EG_INCSTEP[rate_lo][self.eg_timer_lo]
                if shift & 4:
                    shift = 3
                if not shift:
                    shift = self.eg_state
        eg_rout = s.eg_rout
        eg_inc = 0
        if reset and rate_hi == 0x0f:
            eg_rout = 0
        eg_off = (s.eg_rout & 0x1f8) == 0x1f8
        if s.eg_gen != ATTACK and not reset and eg_off:
            eg_rout = 0x1ff
        if s.eg_gen == ATTACK:
            if not s.eg_rout:
                s.eg_gen = DECAY
            elif s.key and shift > 0 and rate_hi != 0x0f:
                eg_inc = (~s.eg_rout) >> (4 - shift)
        elif s.eg_gen == DECAY:
            if (s.eg_rout >> 4) == s.sl:
                s.eg_gen = SUSTAIN
            elif not eg_off and not reset and shift > 0:
                eg_inc = 1 << (shift - 1)
        elif not eg_off and not reset and shift > 0:
            eg_inc = 1 << (shift - 1)
        s.eg_rout = (eg_rout + eg_inc) & 0x1ff
        if reset:
            s.eg_gen = ATTACK
        if not s.key:
            s.eg_gen = RELEASE
        return eg_out

    def step_timers(self):
        self.timer += 1
        if self.eg_state:
            shift = 0
            while shift < 13 and ((self.eg_timer >> shift) & 1) == 0:
                shift += 1
            self.eg_add = 0 if shift > 12 else shift + 1
            self.eg_timer_lo = self.eg_timer & 3
        if self.eg_state:
            self.eg_timer += 1
        self.eg_state ^= 1

    def sample(self):
        """One output sample of the channel."""
        m, c = self.mod, self.car
        fbmod = (m.prout + m.out) >> (9 - self.fb) if self.fb else 0
        m.prout = m.out
        env = self.envelope(m)
        phase = (m.phase >> 9) & 0xffff
        if m.reset:
            m.phase = 0
        m.phase += (self.basefreq * MT[m.mult]) >> 1
        m.out = wave(m.wf, phase + fbmod, env)
        c.prout = c.out
        env = self.envelope(c)
        phase = (c.phase >> 9) & 0xffff
        if c.reset:
            c.phase = 0
        c.phase += (self.basefreq * MT[c.mult]) >> 1
        c.out = wave(c.wf, phase + (0 if self.con else m.out), env)
        self.step_timers()
        return c.out + m.out if self.con else c.out

    def envelope_only(self):
        """One step of both envelopes with no waveform: the attenuation of
        each slot (for the loudness curve of a note)."""
        em = self.envelope(self.mod)
        ec = self.envelope(self.car)
        self.step_timers()
        return em, ec


def freq_regs(hz):
    """The F-number and block for a frequency in Hz (the lowest block with
    an F-number below 1024)."""
    for block in range(8):
        fnum = round(hz * (1 << (20 - block)) / RATE)
        if fnum < 1024:
            return fnum, block
    return 1023, 7


def render(data, hz, seconds, key_off=None):
    """Samples of one GENMIDI voice (data: 16 bytes) at hz: key on at 0,
    key off after key_off seconds (None: held)."""
    ch = Channel(data)
    ch.set_freq(*freq_regs(hz))
    ch.key_on()
    off = None if key_off is None else int(key_off * RATE)
    out = []
    for n in range(int(seconds * RATE)):
        if n == off:
            ch.key_off()
        out.append(ch.sample())
    return out
