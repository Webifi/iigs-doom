#!/usr/bin/env python3
"""SoundFont 2 files: the presets, instruments, zones and samples, and the
regions that play a note (the generators of the instrument zone over the
instrument's global zone, plus those of the preset zone), for the music
tools (a reference render; the DOC tables of a song).

sf = SF2(path); sf.regions(bank, program, key, velocity) -> [Region]
Region: sample (Sample: data as floats, rate, root key, pitch correction,
loop start/end in samples, mode 0 none / 1 loop / 3 loop until release),
and the generators in natural units: tune (semitones, the key's offset in
it), attenuation (dB), pan (-0.5..0.5), the volume envelope (delay, attack,
hold, decay seconds, sustain dB, release seconds), exclusive class.

usage: sf2.py FILE.sf2 [BANK PROGRAM]   (the presets, or a preset's zones)
"""
import array
import math
import struct
import sys

GEN = {0: 'startAddrsOffset', 1: 'endAddrsOffset', 2: 'startloopAddrsOffset', 3: 'endloopAddrsOffset',
       4: 'startAddrsCoarseOffset', 5: 'modLfoToPitch', 6: 'vibLfoToPitch', 7: 'modEnvToPitch',
       8: 'initialFilterFc', 9: 'initialFilterQ', 10: 'modLfoToFilterFc', 11: 'modEnvToFilterFc',
       12: 'endAddrsCoarseOffset', 13: 'modLfoToVolume', 21: 'delayModLFO', 22: 'freqModLFO',
       23: 'delayVibLFO', 24: 'freqVibLFO', 25: 'delayModEnv', 26: 'attackModEnv', 27: 'holdModEnv',
       28: 'decayModEnv', 29: 'sustainModEnv', 30: 'releaseModEnv',
       17: 'pan', 33: 'delayVolEnv', 34: 'attackVolEnv', 35: 'holdVolEnv', 36: 'decayVolEnv',
       37: 'sustainVolEnv', 38: 'releaseVolEnv', 41: 'instrument', 43: 'keyRange', 44: 'velRange',
       45: 'startloopAddrsCoarseOffset', 46: 'keynum', 47: 'velocity', 48: 'initialAttenuation',
       50: 'endloopAddrsCoarseOffset', 51: 'coarseTune', 52: 'fineTune', 53: 'sampleID', 54: 'sampleModes',
       56: 'scaleTuning', 57: 'exclusiveClass', 58: 'overridingRootKey'}
DEFAULTS = {'initialFilterFc': 13500, 'delayVolEnv': -12000, 'attackVolEnv': -12000, 'holdVolEnv': -12000,
            'decayVolEnv': -12000, 'releaseVolEnv': -12000, 'sustainVolEnv': 0, 'scaleTuning': 100,
            'overridingRootKey': -1, 'keynum': -1, 'velocity': -1,
            'delayModEnv': -12000, 'attackModEnv': -12000, 'holdModEnv': -12000, 'decayModEnv': -12000,
            'sustainModEnv': 0, 'releaseModEnv': -12000, 'delayModLFO': -12000, 'freqModLFO': 0,
            'delayVibLFO': -12000, 'freqVibLFO': 0}


class Sample:
    pass


def neutral_sample_name(name):
    """SoundFonts sometimes prefix a sample with a product tag
    (two letters, a hyphen, two digits). Tables in this converter
    key the same samples as 'gm - N'."""
    if (len(name) >= 8 and name[:2].isalpha() and name[:2].isupper()
            and name[2] == '-' and name[3:5].isdigit() and name[5:8] == ' - '):
        return 'gm' + name[5:]
    return name


class Region:
    pass


def _chunks(d, off, end):
    while off < end:
        cid = d[off:off + 4]
        size = struct.unpack_from('<I', d, off + 4)[0]
        yield cid, off + 8, size
        off += 8 + size + (size & 1)


class SF2:
    def __init__(self, path):
        d = open(path, 'rb').read()
        assert d[:4] == b'RIFF' and d[8:12] == b'sfbk', 'not a SoundFont'
        self.info = {}
        pd = {}
        smpl = None
        for cid, o, size in _chunks(d, 12, len(d)):
            if cid != b'LIST':
                continue
            kind = d[o:o + 4]
            for sid, so, ss in _chunks(d, o + 4, o + size):
                if kind == b'INFO':
                    self.info[sid.decode('latin1')] = d[so:so + ss].rstrip(b'\0').decode('latin1')
                elif kind == b'sdta' and sid == b'smpl':
                    smpl = array.array('h')
                    smpl.frombytes(d[so:so + ss - (ss & 1)])
                elif kind == b'pdta':
                    pd[sid.decode('latin1')] = d[so:so + ss]
        self.smpl = smpl
        self.phdr = [struct.unpack_from('<20sHHHIII', pd['phdr'], i) for i in range(0, len(pd['phdr']), 38)]
        self.pbag = [struct.unpack_from('<HH', pd['pbag'], i) for i in range(0, len(pd['pbag']), 4)]
        self.pgen = [struct.unpack_from('<HH', pd['pgen'], i) for i in range(0, len(pd['pgen']), 4)]
        self.inst = [struct.unpack_from('<20sH', pd['inst'], i) for i in range(0, len(pd['inst']), 22)]
        self.ibag = [struct.unpack_from('<HH', pd['ibag'], i) for i in range(0, len(pd['ibag']), 4)]
        self.igen = [struct.unpack_from('<HH', pd['igen'], i) for i in range(0, len(pd['igen']), 4)]
        self.shdr = [struct.unpack_from('<20sIIIIIBbHH', pd['shdr'], i) for i in range(0, len(pd['shdr']), 46)]
        self.samples = {}
        self.presets = {}
        for i, h in enumerate(self.phdr[:-1]):
            name, prog, bank = h[0].split(b'\0')[0].decode('latin1'), h[1], h[2]
            self.presets[(bank, prog)] = (i, name)

    @staticmethod
    def _gens(gens):
        g = {}
        for oper, amount in gens:
            name = GEN.get(oper)
            if name is None:
                continue
            if name in ('keyRange', 'velRange'):
                g[name] = (amount & 0xff, amount >> 8)
            elif name in ('instrument', 'sampleID', 'sampleModes'):
                g[name] = amount
            else:
                g[name] = amount - 65536 if amount >= 32768 else amount
        return g

    def _zones(self, bags, gens, first, last):
        out = []
        for b in range(first, last):
            g0, g1 = bags[b][0], bags[b + 1][0]
            out.append(self._gens(gens[g0:g1]))
        return out

    def sample(self, sid):
        if sid in self.samples:
            return self.samples[sid]
        name, start, end, ls, le, rate, pitch, corr, link, stype = self.shdr[sid]
        s = Sample()
        s.name = neutral_sample_name(name.split(b'\0')[0].decode('latin1'))
        s.start, s.end, s.ls, s.le = start, end, ls, le
        s.rate, s.root, s.corr = rate, pitch, corr
        s.data = [v / 32768.0 for v in self.smpl[start:end]]
        self.samples[sid] = s
        return s

    def regions(self, bank, prog, key, vel):
        """The regions of a note: the zones of the preset (bank, prog) and
        of its instruments that hold key and vel (a missing preset: bank 0,
        then program 0)."""
        p = self.presets.get((bank, prog)) or self.presets.get((0 if bank != 128 else 128, prog)) or \
            self.presets.get((bank, 0)) or self.presets.get((0, 0))
        if p is None:
            return []
        i = p[0]
        pz = self._zones(self.pbag, self.pgen, self.phdr[i][3], self.phdr[i + 1][3])
        pglobal = pz[0] if pz and 'instrument' not in pz[0] else {}
        out = []
        for z in pz:
            if 'instrument' not in z:
                continue
            if not _in(z.get('keyRange'), key) or not _in(z.get('velRange'), vel):
                continue
            ii = z['instrument']
            iz = self._zones(self.ibag, self.igen, self.inst[ii][1], self.inst[ii + 1][1])
            iglobal = iz[0] if iz and 'sampleID' not in iz[0] else {}
            for zz in iz:
                if 'sampleID' not in zz:
                    continue
                if not _in(zz.get('keyRange'), key) or not _in(zz.get('velRange'), vel):
                    continue
                g = dict(DEFAULTS)
                g.update(iglobal)
                g.update(zz)
                for k, v in list(pglobal.items()) + list(z.items()):
                    if k in ('keyRange', 'velRange', 'instrument'):
                        continue
                    g[k] = g.get(k, 0) + v              # preset generators add
                out.append(region(self, g, key))
        return out


def _in(rng, v):
    return rng is None or rng[0] <= v <= rng[1]


def tc(v):
    """Timecents to seconds."""
    return 2.0 ** (v / 1200.0)


RANGES = {'delayModEnv': (-12000, 5000), 'attackModEnv': (-12000, 8000), 'holdModEnv': (-12000, 5000),
          'decayModEnv': (-12000, 8000), 'sustainModEnv': (0, 1000), 'releaseModEnv': (-12000, 8000),
          'modEnvToPitch': (-12000, 12000), 'modEnvToFilterFc': (-12000, 12000),
          'initialAttenuation': (0, 1440), 'pan': (-500, 500), 'delayVolEnv': (-12000, 5000),
          'attackVolEnv': (-12000, 8000), 'holdVolEnv': (-12000, 5000), 'decayVolEnv': (-12000, 8000),
          'sustainVolEnv': (0, 1440), 'releaseVolEnv': (-12000, 8000), 'coarseTune': (-120, 120),
          'fineTune': (-99, 99), 'initialFilterFc': (1500, 13500), 'scaleTuning': (0, 1200)}


def region(sf, g, key):
    for k, (lo, hi) in RANGES.items():            # sums of preset and instrument values
        if k in g:
            g[k] = max(lo, min(hi, g[k]))
    r = Region()
    s = sf.sample(g['sampleID'])
    r.sample = s
    r.g = g
    root = g['overridingRootKey'] if g['overridingRootKey'] >= 0 else s.root
    r.root = root
    r.tune = (key - root) * g['scaleTuning'] / 100.0 + g.get('coarseTune', 0) + (g.get('fineTune', 0) + s.corr) / 100.0
    r.start = g.get('startAddrsOffset', 0) + 32768 * g.get('startAddrsCoarseOffset', 0)
    r.end = len(s.data) + g.get('endAddrsOffset', 0) + 32768 * g.get('endAddrsCoarseOffset', 0)
    r.ls = s.ls - s.start + g.get('startloopAddrsOffset', 0) + 32768 * g.get('startloopAddrsCoarseOffset', 0)
    r.le = s.le - s.start + g.get('endloopAddrsOffset', 0) + 32768 * g.get('endloopAddrsCoarseOffset', 0)
    r.mode = g.get('sampleModes', 0) & 3
    r.atten = g.get('initialAttenuation', 0) / 10.0 * 0.4          # cB, scaled as FluidSynth does (0.4)
    r.pan = max(-500, min(500, g.get('pan', 0))) / 1000.0
    r.delay = tc(g['delayVolEnv'])
    r.attack = tc(g['attackVolEnv'])
    r.hold = tc(g['holdVolEnv'])
    r.decay = tc(g['decayVolEnv'])
    r.sustain = max(0, g['sustainVolEnv']) / 10.0                   # dB down
    r.release = tc(g['releaseVolEnv'])
    r.excl = g.get('exclusiveClass', 0)
    r.fc = g['initialFilterFc']
    # the modulation envelope (0..1: its peak at 1, its sustain level) and
    # what it moves: the filter's cutoff and the pitch (cents at the peak)
    r.mod_env = (tc(g['delayModEnv']), tc(g['attackModEnv']), tc(g['holdModEnv']), tc(g['decayModEnv']),
                 1.0 - g['sustainModEnv'] / 1000.0, tc(g['releaseModEnv']))
    r.mod_to_fc = g.get('modEnvToFilterFc', 0)
    r.mod_to_pitch = g.get('modEnvToPitch', 0)
    r.vib_to_pitch = g.get('vibLfoToPitch', 0)
    r.vib_freq = 8.176 * 2.0 ** (g['freqVibLFO'] / 1200.0)
    r.vib_delay = tc(g['delayVibLFO'])
    r.mod_freq = 8.176 * 2.0 ** (g['freqModLFO'] / 1200.0)
    r.mod_delay = tc(g['delayModLFO'])
    r.mod_lfo_pitch = g.get('modLfoToPitch', 0)
    r.mod_lfo_fc = g.get('modLfoToFilterFc', 0)
    r.mod_lfo_volume = g.get('modLfoToVolume', 0) / 10.0
    return r


def lfo_at(t, delay, freq):
    """SF2 triangle LFO, initially zero, positive-going after its delay."""
    return 0.0 if t < delay else 2.0 / 3.141592653589793 * math.asin(
        math.sin(2.0 * 3.141592653589793 * freq * (t - delay)))


def pitch_at(r, t, off=None):
    return (r.mod_to_pitch * mod_env_at(r, t, off) +
            r.vib_to_pitch * lfo_at(t, r.vib_delay, r.vib_freq) +
            r.mod_lfo_pitch * lfo_at(t, r.mod_delay, r.mod_freq))


def mod_env_at(r, t, off=None):
    """The modulation envelope of a region t s after the note on, the key
    held (0..1): delay, a linear attack, hold, a decay to its sustain level
    (linear in the envelope's units, as FluidSynth's)."""
    d, a, h, dc, sus, rel = r.mod_env
    if off is not None and t >= off:
        return mod_env_at(r, off) * max(0.0, 1.0 - (t-off)/max(rel,1e-9))
    if t < d:
        return 0.0
    t -= d
    if t < a:
        return t / a if a > 0 else 1.0
    t -= a
    if t < h:
        return 1.0
    t -= h
    if dc <= 0:
        return sus
    return max(sus, 1.0 - t / dc)


if __name__ == '__main__':
    sf = SF2(sys.argv[1])
    print(sf.info)
    if len(sys.argv) > 3:
        bank, prog = int(sys.argv[2]), int(sys.argv[3])
        for key in range(24, 108, 6):
            for r in sf.regions(bank, prog, key, 100):
                s = r.sample
                print('key %3d: %-20s rate %5d root %3d len %6d loop %d-%d mode %d atten %.1f dB env %.3f/%.3f/%.3f/%.1f dB/%.3f fc %d' % (
                    key, s.name, s.rate, r.root, len(s.data), r.ls, r.le, r.mode, r.atten, r.attack, r.hold,
                    r.decay, r.sustain, r.release, r.fc))
    else:
        for (bank, prog), (i, name) in sorted(sf.presets.items()):
            print('%3d %3d %s' % (bank, prog, name))
