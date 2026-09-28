#!/usr/bin/env python3
"""An OPL2 (YM3812) chip for the music tools: channels of two operators as
Nuked OPL3 models them (the math of tools/oplsynth.py), with the chip-wide
envelope timer, tremolo and vibrato (depths as DMX leaves register $BD: 1 dB
and 7 cents) and note select 1 (DMX writes register $08 = $40: the key scale
takes bit 8 of the F-number). tools/musbank.py renders its instrument
tables with it; tools/musref.py plays whole songs for reference.
"""
import oplsynth
from oplsynth import LOGSIN, EXP, MT, KSLROM, KSLSHIFT, EG_INCSTEP, ATTACK, DECAY, SUSTAIN, RELEASE

RATE = oplsynth.RATE


def exp_out(level):
    if level > 0x1fff:
        level = 0x1fff
    return (EXP[level & 0xff] << 1) >> (level >> 8)


def wave_out(wf, phase, env):
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


class Chip:
    def __init__(self):
        self.timer = 0
        self.eg_timer = 0
        self.eg_state = 0
        self.eg_add = 0
        self.eg_timer_lo = 0
        self.tremolopos = 0
        self.tremolo = 0
        self.vibpos = 0

    def step(self):
        """The chip timers after a sample (Nuked OPL3_Generate order)."""
        if (self.timer & 0x3f) == 0x3f:
            self.tremolopos = (self.tremolopos + 1) % 210
        if self.tremolopos < 105:
            self.tremolo = self.tremolopos >> 4            # DAM = 0
        else:
            self.tremolo = (210 - self.tremolopos) >> 4
        if (self.timer & 0x3ff) == 0x3ff:
            self.vibpos = (self.vibpos + 1) & 7
        self.timer += 1
        if self.eg_state:
            shift = 0
            while shift < 13 and ((self.eg_timer >> shift) & 1) == 0:
                shift += 1
            self.eg_add = 0 if shift > 12 else shift + 1
            self.eg_timer_lo = self.eg_timer & 3
            self.eg_timer += 1
        self.eg_state ^= 1


class Slot:
    def __init__(self):
        self.eg_rout = 0x1ff
        self.eg_gen = RELEASE
        self.key = 0
        self.phase = 0
        self.out = 0
        self.prout = 0
        self.reset = 0
        self.set_regs(0, 0, 0, 0, 0, 0x3f)

    def set_regs(self, trem, attack, sustain, waveform, scale, level):
        self.am = (trem >> 7) & 1
        self.vib = (trem >> 6) & 1
        self.egt = (trem >> 5) & 1
        self.ksr = (trem >> 4) & 1
        self.mult = trem & 15
        self.ar, self.dr = attack >> 4, attack & 15
        self.sl, self.rr = sustain >> 4, sustain & 15
        if self.sl == 15:
            self.sl = 0x1f
        self.wf = waveform & 3
        self.ksl = scale >> 6
        self.tl = level & 0x3f


class Voice:
    """One OPL2 channel: two slots."""

    def __init__(self, chip):
        self.chip = chip
        self.mod = Slot()
        self.car = Slot()
        self.fb = 0
        self.con = 0
        self.set_freq(0)

    def set_instrument(self, data):
        m, c = data[0:6], data[7:13]
        self.mod.set_regs(*m)
        self.car.set_regs(*c)
        self.fb = (data[6] >> 1) & 7
        self.con = data[6] & 1

    def set_tl(self, car_tl, mod_tl):
        self.car.ksl, self.car.tl = (car_tl >> 6) & 3, car_tl & 0x3f
        if mod_tl is not None:
            self.mod.ksl, self.mod.tl = (mod_tl >> 6) & 3, mod_tl & 0x3f

    def set_freq(self, freq):
        self.fnum, self.block = freq & 0x3ff, (freq >> 10) & 7
        self.ksv = (self.block << 1) | ((self.fnum >> 8) & 1)      # NTS = 1
        ksl = (KSLROM[self.fnum >> 6] << 2) - ((8 - self.block) << 5)
        self.eg_ksl = max(ksl, 0)

    def silent(self):
        return (not self.mod.key and self.mod.eg_rout == 0x1ff and self.car.eg_rout == 0x1ff)

    def envelope(self, s):
        ch = self.chip
        eg_out = s.eg_rout + (s.tl << 2) + (self.eg_ksl >> KSLSHIFT[s.ksl]) + (ch.tremolo if s.am else 0)
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
                if ch.eg_state:
                    eg_shift = rate_hi + ch.eg_add
                    if eg_shift == 12:
                        shift = 1
                    elif eg_shift == 13:
                        shift = (rate_lo >> 1) & 1
                    elif eg_shift == 14:
                        shift = rate_lo & 1
            else:
                shift = (rate_hi & 3) + EG_INCSTEP[rate_lo][ch.eg_timer_lo]
                if shift & 4:
                    shift = 3
                if not shift:
                    shift = ch.eg_state
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

    def phase_inc(self, s):
        f_num = self.fnum
        if s.vib:
            rng = (f_num >> 7) & 7
            vp = self.chip.vibpos
            if not (vp & 3):
                rng = 0
            elif vp & 1:
                rng >>= 1
            rng >>= 1                                           # DVB = 0
            if vp & 4:
                rng = -rng
            f_num += rng
        return (((f_num << self.block) >> 1) * MT[s.mult]) >> 1

    def sample(self):
        m, c = self.mod, self.car
        fbmod = (m.prout + m.out) >> (9 - self.fb) if self.fb else 0
        m.prout = m.out
        env = self.envelope(m)
        phase = (m.phase >> 9) & 0xffff
        if m.reset:
            m.phase = 0
        m.phase += self.phase_inc(m)
        m.out = wave_out(m.wf, phase + fbmod, env)
        c.prout = c.out
        env = self.envelope(c)
        phase = (c.phase >> 9) & 0xffff
        if c.reset:
            c.phase = 0
        c.phase += self.phase_inc(c)
        c.out = wave_out(c.wf, phase + (0 if self.con else m.out), env)
        return c.out + m.out if self.con else c.out
