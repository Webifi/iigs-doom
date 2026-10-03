#!/usr/bin/env python3
"""A Doom song for the DOC from the samples of a General MIDI SoundFont, in
the stream format of tools/musbank.py (the player of src/iigs/irq65.s).

ScSong(name, lump, sf, q): the MUS events (tools/dmxmus.py, as mus2mid.c
gives them) on VOICES DOC voices (oscillators 16 + v, channel v & 1: a
panned channel takes a voice on its side); each note on the sample of its
region (tools/sf2.py; channel 9: the drum kit, bank 128); a sample that
few notes use gives them to the nearest sample of the preset (q.min_notes).
Each sample one table: only the part the song plays (the longest note at
its speed), the SoundFont's low-pass filter at the notes' pitch and a
one-shot's volume envelope in it, 8-bit, at the lowest rate that keeps
q.f_mel (q.f_drum) Hz of the lowest note and 1 - q.eps of its energy.
A looped sample: its start (at most q.attack s at the lowest note) and a
loop table of 2^k bytes (MAME wraps a table of L bytes after L - 1):
whole source loops (a tone), or a short loop of its tail with a crossfade
(noise: cymbals), switched in by the player after the start (the start
table goes on with the loop for a tic, so the switch may come late).
Levels (3 dB steps): velocity and channel volume on the concave curve of
a SoundFont player ((v / 127)^2), the region's attenuation, its volume
envelope (not in a one-shot's table: after the note off) and release.

usage: mussc.py FONT.sf2 OUT.bin SONG... [--q name=value,...] [--units DIR]
"""
import bisect
import cmath
import math
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, '..'))
sys.path.insert(0, _HERE)
import dmxmus
import musbank
import musdsp
import sf2

DOC_RATE = musbank.DOC_RATE
ONLY = os.environ.get('MUSSC_ONLY', '').split(',') if os.environ.get('MUSSC_ONLY') else None
MB_IMAGE = 0x500                         # src/iigs/music.inc
MUSBUF_SIZE = 0xae00                     # MB_PLANS of music.inc: the head ends below
VOICES = 14                              # oscillators 16-29
TIC = 1.0 / 140


class Q:
    """The quality knobs."""
    f_mel = 3000.0        # Hz kept at a melodic zone's lowest note
    f_drum = 6000.0       # Hz kept of a drum
    f_cym = 11000.0       # Hz kept of a cymbal (a drum with a loop: noise)
    f_floor = 5000.0      # Hz of a drum sample kept at least (its attack), whatever its energy
    eps = 0.001           # energy that may go above the cut
    attack = 0.06         # s of a looped tone's start at its lowest note
    long_attack = 0.14    #   the most played tones: this, while the song's pages allow
    cym_attack = 0.08     # s of a cymbal's start before its noise loop
    tail_db = 40.0        # a one-shot ends this far under its peak
    drum_max = 0.35       # s a one-shot drum plays at most (a fade)
    noise_loop = 1023     # bytes of a noise loop (2^k - 1)
    merge_st = 5          # a melodic sample within this many semitones of a
                          #   more used one gives it its notes
    min_drum = 16         # a drum sample with fewer notes: its kind's main one
    min_notes = 12        # a melodic sample with fewer notes: the nearest kept one
    snap = 0.2            # a table this much over 2^k bytes is cut to it
    pairs = 1             # centred parts on both sides (two voices)
    max_rate = 26320.0
    tol = 4               # tics a level step may wait for a wake
    tol_off = 1           # tics the drop of a fast release (a note off) may wait
    tol_halt = 8          # tics the halt of a silent voice may wait
    sw_early = 2          # tics a switch to the loop may come before the start ends
    sw_late = 6           #   and after (at most the loop its start table holds)
    tol_bend = 2          # tics a pitch bend step may wait
    reff_min = 26400.0    # Hz a melodic table plays at, at least: a step of 1 or more
    reff_bytes = 2048     #   unless its start would take more bytes
    reff_max = 64000.0    #   or the table rate more (a note far below its sample)
    mel_lp = 0.0          # Hz (played) of an extra low-pass of melodic tables (0: none)
    long_loop = 0.1       # s: a melodic loop longer than this (an ensemble)
    short_loop = 0.04     #   is cut to this many seconds of whole periods
    exact_notes = 0       # a key of a looped tone with this many notes: a table at its pitch (0: none)
    exact_attack = 0.12   #   s of its attack, as the note plays (the loop after it)
    exact_step_max = 1.3  #   table bytes an output sample at most (the loop's fit)
    exact_max = 4         #   at most this many keys
    bright_drums = 1      # spare pages: the one-shot snares, hats and cymbals to f_cym
    sharpen = 1           # spare pages: higher rates for the tones under a step
    mask_rate = 0.25      #   of 1, in a song with fewer high drums a second than
                          #   this (nothing masks their fizz)

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, type(getattr(Q, k))(v))


class Note:
    pass


REF_STEAL = os.environ.get('MUSSC_STEAL', '1') == '1'  # (tests: 0 = the parts 11-16 whole)
AUTOSTEP = os.environ.get('MUSSC_AUTOSTEP', 'fine')    # a note under volume automation: 'coarse' (3 dB),
                                                        #   'fine' (0.75 dB), 'tic' (0.75 dB, each on its tic)
PAIR_TAIL = -25.0          # a centred part's second side may take a note with less sound left (dB + 10 log tics)
MUTE = 127                                              # the level index of volume 0 (a muted voice)
LIFT = os.environ.get('MUSSC_LIFT', '1') == '1'        # (tests: 0 = the SoundFont's absolute levels)
HEAD = 16                                               # 3 dB: a song's loudest tic under full scale
LIFT_MAX = float(os.environ.get('MUSSC_LIFTMAX', 2.0))  # dB a song may be raised (its balance with the effects)
KNEE = os.environ.get('MUSSC_KNEE', '1') == '1'
KNEE_DB = 30.0            # static levels this far under the song's loudest tic are pressed
KNEE_RATIO = 0.35         #   by this: 60 dB under it plays 40.5 dB under
MODENV = os.environ.get('MUSSC_MODENV', '1') == '1'    # (tests: 0 = the filters static at their start)
MODPITCH = os.environ.get('MUSSC_MODPITCH', '1') == '1'  # bake short pitch envelopes into attack tables
MOTION = os.environ.get('MUSSC_MOTION', '1') == '1'
MORPH = os.environ.get('MUSSC_MORPH', '1') == '1'
FRAMES = os.environ.get('MUSSC_FRAMES','1') == '1'
PITCH_STEP = float(os.environ.get('MUSSC_PITCHSTEP', '5.0'))
MODENV_START = 0.3        # s of a filter envelope's sweep a start table holds at most
NOVOLS = os.environ.get('MUSSC_NOVOLS') == '1'          # (tests: no channel volume changes)
MIX = os.environ.get('MUSSC_MIX', '1') == '1'          # (tests: 0 = a zone's own sample only)
SYNTH = os.environ.get('MUSSC_SYNTH', '1') == '1'      # (tests: 0 = loops cut from the source)
NATIVE = os.environ.get('MUSSC_NATIVE', '1') == '1'
SYNTH_MIN = 0.65          # a loop with less of its power at the harmonics of its period is not a
                          #   tone (a timpani: 51 %); a breathy pad has 78 %
ONCE = ('D_INTRO', 'D_INTROA')          # songs played once (S_StartMusic): the title's


# Coarser settings, in order, until a song fits its DOC pages
STEPS = (
    {},
    {'min_notes': 24, 'merge_st': 7},
    {'attack': 0.08, 'cym_attack': 0.06, 'noise_loop': 511},
    {'f_mel': 2500.0, 'f_cym': 9000.0, 'f_drum': 5000.0},
    {'attack': 0.06, 'drum_max': 0.25, 'min_notes': 40, 'merge_st': 9},
    {'f_mel': 2000.0, 'f_cym': 7000.0, 'f_drum': 4000.0, 'f_floor': 4000.0},
    {'attack': 0.04, 'cym_attack': 0.04, 'drum_max': 0.18, 'noise_loop': 255},
)
BUDGET = {'D_INTER': 200, 'D_INTRO': 200, 'D_VICTOR': 200, 'D_INTROA': 200}
# the level steps (3/16 dB units) of the title's song: 0.75 dB, a fade
# without stairs (3 dB steps: a stair of the fade every few tenths of a
# second, whose steps spread the tone around its notes); the other songs
# keep 3 dB: a map's for its writes, the intermission's and the ending's
# for MUSBUF (finer steps: their heads do not fit)
LEVEL_STEP = {'D_INTRO': 4, 'D_INTROA': 4}
TAIL_DB = 45.0                            # a note this far down its envelope stops (its writes)


def level_index(u, step):
    """musbank.level_index at another step (units of 3/16 dB)."""
    idx = max(0, int(u // step) * step // 4 + step // 8)
    return idx if idx <= 127 and musbank.vol_of(idx) > 0 else None
GAME_PAGES = 180                          # a map's song: the sound effects keep the rest
                                          #   (their cache at 75 pages: no cost in the demos)


def fit(name, lump, sf, base):
    """The song at the finest settings that fit its budget of DOC pages."""
    budget = int(os.environ.get('MUSSC_PAGES', 0)) or BUDGET.get(name, GAME_PAGES)
    kw = dict(base)
    for step in STEPS:
        kw.update(step)
        q = Q(**kw)
        try:
            s = ScSong(name, lump, sf, q, budget)
        except ValueError as error:
            if os.environ.get("MUSSC_DEBUG"):print(name,step,str(error),file=sys.stderr,flush=True)
            continue
        if 255 - s.low <= budget:
            s.step = STEPS.index(step)
            return s
    raise ValueError('%s: no setting fits %d pages' % (name, budget))


REF_VOICES = 24
REF_RESERVE = [2] * 9 + [6] + [0] * 6    # GS default voice reserve: parts 1-9, the rhythm part, 11-16
REF_OFF_DB = float(os.environ.get('MUSSC_OFFDB', 30.0))  # a voice is free this far down (INTRO's
                                          #   recording: its guitar harmonics go at the 6th hit)


def ref_fates(groups, sf):
    """The notes of the MIDI channels 10-15 as the reference synthesizer plays them: a part
    with no voice reserve (GS default: parts 11-16) sounds only on voices
    the others leave, and a note on of a part within its reserve takes its
    voice back (the oldest note of a part over its reserve goes). A list,
    in the order of their note ons: the tic each is cut at, -1 (not
    sounded) or None (plays whole). Each note takes one voice from its note
    on until it is REF_OFF_DB down (the SoundFont's envelopes). (INTRO's
    reference recording: its vibraphone and guitar harmonics sound in the
    first bars, stop at the fifth and sixth hits, and their second notes
    are missing; this gives that.)"""
    def env_db(L, t):
        if t < L.delay:
            return 200.0
        t -= L.delay
        if t < L.attack + L.hold:
            return 0.0
        t -= L.attack + L.hold
        return min(L.sustain, 100.0 * t / max(L.decay, 1e-4))

    def end_tic(n):
        best = 0
        for L in n['layers']:
            if n['off'] is None:
                if L.sustain < REF_OFF_DB:
                    return 1 << 30
                t = L.delay + L.attack + L.hold + L.decay * REF_OFF_DB / 100.0
            else:
                toff = (n['off'] - n['on']) * TIC
                d0 = env_db(L, toff)
                if d0 >= REF_OFF_DB:
                    t = min(toff, L.delay + L.attack + L.hold + L.decay * REF_OFF_DB / 100.0)
                else:
                    t = toff + (REF_OFF_DB - d0) / 100.0 * L.release
            best = max(best, n['on'] + int(math.ceil(t / TIC)))
        return best
    prog = [0] * 16
    voices = []
    fates = []
    for tic, evs in groups:
        for kind, ch, a, b in evs:
            if kind == 'prog':
                prog[ch] = a
            elif kind == 'off' or (kind == 'ctl' and a in (0x78, 0x7b)):
                for n in voices:
                    if n['ch'] == ch and (kind != 'off' or n['key'] == a) and n['off'] is None:
                        n['off'] = tic
                        n['end'] = end_tic(n)
            elif kind == 'on':
                bank, pr = (128, 0) if ch == 9 else (0, prog[ch])
                regs = sf.regions(bank, pr, a, b)
                if not regs:
                    if ch >= 10:
                        fates.append(None)
                    continue
                voices = [n for n in voices if n['end'] > tic]
                n = {'ch': ch, 'key': a, 'on': tic, 'off': None, 'layers': regs, 'fate': None}
                n['end'] = end_tic(n)
                ok = True
                while len(voices) + 1 > REF_VOICES:
                    per = {}
                    for m in voices:
                        per[m['ch']] = per.get(m['ch'], 0) + 1
                    over = [m for m in voices if per[m['ch']] > REF_RESERVE[m['ch']] and
                            (REF_RESERVE[ch] > 0 or REF_RESERVE[m['ch']] == 0)]
                    if not over:
                        ok = False
                        break
                    old = min(over, key=lambda m: m['on'])
                    if old['ch'] >= 10 and old['fate'] is None:
                        fates[old['idx']] = tic
                    voices.remove(old)
                if ch >= 10:
                    n['idx'] = len(fates)
                    fates.append(None if ok else -1)
                if ok:
                    voices.append(n)
    return fates


# General MIDI drum keys by kind: a rare drum plays its kind's main sample
DRUM_KIND = {}
for kind, keys in (('kick', (35, 36)), ('snare', (37, 38, 39, 40)), ('tom', (41, 43, 45, 47, 48, 50)),
                   ('hat', (42, 44, 46)), ('crash', (49, 52, 55, 57)), ('ride', (51, 53, 59))):
    for k in keys:
        DRUM_KIND[k] = kind


def geo_mean(xs):
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


def env_held_db(r, t):
    """dB down of the volume envelope t s after the note on, the key held."""
    if t < r.delay + r.attack + r.hold:
        return 0.0
    t -= r.delay + r.attack + r.hold
    return min(r.sustain, 100.0 * t / r.decay)


def layers_db(n, t):
    """dB down of all the note's layers (the regions of its preset at its key:
    a delayed one, a detuned twin) against its own region at full level, t s
    after the note on, the key held: the table is its region's, the level
    theirs (a layer before its delay is silent)."""
    tot = 0.0
    for L in getattr(n, 'layers', None) or [n.r]:
        if t + 0.01 < L.delay:          # (the default delay is 1 ms)
            continue
        db = (L.atten - n.r.atten) + env_held_db(L, t)
        if db < 100.0:
            tot += 10.0 ** (-db / 10.0)
    return 100.0 if tot <= 0.0 else -10.0 * math.log10(tot)


def biquad(x, rate, hz, q_cb):
    """FluidSynth's low-pass (RBJ, Q in cB less 3.01 dB, gain 1 / sqrt(q))."""
    q_db = max(0.0, min(96.0, q_cb / 10.0)) - 3.01
    q = 10.0 ** (q_db / 20.0)
    gain = 1.0 / math.sqrt(q)
    hz = min(0.45 * rate, max(5.0, hz))
    w = 2.0 * math.pi * hz / rate
    alpha = math.sin(w) / (2.0 * q)
    a0 = 1.0 + alpha
    b1 = (1.0 - math.cos(w)) / a0 * gain
    b0 = b2 = b1 * 0.5
    a1 = -2.0 * math.cos(w) / a0
    a2 = (1.0 - alpha) / a0
    out = []
    x1 = x2 = y1 = y2 = 0.0
    for v in x:
        y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, v, y1, y
        out.append(y)
    return out


def biquad_pow(f, hz, q_cb, rate=44100.0):
    """The power gain at f Hz of biquad()'s low-pass at hz (FluidSynth's, at
    its output rate)."""
    if f >= 0.5 * rate:
        return 0.0
    q_db = max(0.0, min(96.0, q_cb / 10.0)) - 3.01
    q = 10.0 ** (q_db / 20.0)
    gain = 1.0 / math.sqrt(q)
    hz = min(0.45 * rate, max(5.0, hz))
    w = 2.0 * math.pi * hz / rate
    alpha = math.sin(w) / (2.0 * q)
    a0 = 1.0 + alpha
    b1 = (1.0 - math.cos(w)) / a0 * gain
    a1 = -2.0 * math.cos(w) / a0
    a2 = (1.0 - alpha) / a0
    z1 = cmath.exp(-2j * math.pi * f / rate)
    return abs((b1 * 0.5 + b1 * z1 + b1 * 0.5 * z1 * z1) / (1.0 + a1 * z1 + a2 * z1 * z1)) ** 2


def fc_hz_of(L, vel, t=None):
    """The cutoff (Hz) of a region's low-pass at a velocity (FluidSynth's
    default modulator: -2400 cents x (1 - v / 127) from velocity 64) and its
    modulation envelope's push t s after the note on (None: its sustain,
    the loop's), or None (open). (The SoundFont's filter envelopes: the
    synth basses' pluck, E1M3's opens 240 Hz to 9.7 kHz and closes in
    0.2 s; the halo's sweeps down from 19 kHz to 600 Hz in 2 s; E1M7's
    echoes sit 3500 cents under their initial cutoff.)"""
    fc = L.fc - (2400.0 * (1.0 - vel / 127.0) if vel >= 64 else 0.0)
    if getattr(L, 'mod_to_fc', 0):
        fc += L.mod_to_fc * (L.mod_env[4] if t is None else sf2.mod_env_at(L, t))
    if MOTION and t is not None:
        fc += L.mod_lfo_fc * sf2.lfo_at(t, L.mod_delay, L.mod_freq)
    # A moving filter must not jump to unity gain at the nominal open
    # cutoff: its Q compensation is still part of the transfer function.
    # Clamp the cutoff while retaining that gain. Only truly static open
    # filters retain the old bypass path.
    dynamic = bool(L.mod_to_fc or (MOTION and L.mod_lfo_fc))
    return 8.176 * 2.0 ** (min(fc,13500) / 1200.0) if dynamic or fc < 13500 else None


def play_through(d, ls, le, n):
    """n samples of a sample played through its loop (the loop repeated)."""
    if n <= len(d) or le <= ls + 8:
        return d[:n]
    out = list(d[:le])
    lp = d[ls:le]
    while len(out) < n:
        out.extend(lp)
    return out[:n]



def bake_pitch(r):
    return MODPITCH and r.mod_to_pitch and r.mod_env[4] == 0 and sum(r.mod_env[:4]) <= .1


def pitch_attack(r, count, speed):
    """Bake a short pitch envelope into the attack at the zone's reference speed.
    The envelope returns to zero before the static loop; no pitch writes are added.
    """
    src = r.sample.data[r.start:r.end]
    out = []
    phase = 0.0
    def at(i):
        if r.mode in (1, 3) and i >= r.le and r.le > r.ls:
            i = r.ls + (i - r.ls) % (r.le - r.ls)
        return src[min(len(src) - 1, max(0, i))]
    for i in range(count):
        j = int(phase)
        f = phase - j
        out.append(at(j) * (1.0 - f) + at(j + 1) * f)
        t = i / (r.sample.rate * speed)
        phase += 2.0 ** (r.mod_to_pitch * sf2.mod_env_at(r, t) / 1200.0)
    return out


def biquad_tv(x, rate, hz_at, q_cb, block=32):
    """biquad() with its cutoff hz_at(i) at sample i, the coefficients new
    every block samples (None: open, the input passes)."""
    q_db = max(0.0, min(96.0, q_cb / 10.0)) - 3.01
    q = 10.0 ** (q_db / 20.0)
    gain = 1.0 / math.sqrt(q)
    out = []
    x1 = x2 = y1 = y2 = 0.0
    for i0 in range(0, len(x), block):
        hz = hz_at(i0)
        if hz is None:
            hz = 0.45 * rate
        hz = min(0.45 * rate, max(5.0, hz))
        w = 2.0 * math.pi * hz / rate
        alpha = math.sin(w) / (2.0 * q)
        a0 = 1.0 + alpha
        b1 = (1.0 - math.cos(w)) / a0 * gain
        b0 = b2 = b1 * 0.5
        a1 = -2.0 * math.cos(w) / a0
        a2 = (1.0 - alpha) / a0
        for v in x[i0:i0 + block]:
            y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2, x1, y2, y1 = x1, v, y1, y
            out.append(y)
    return out


def env_pow(L, t, main):
    """The power of a layer t s after its note on (the key held), against
    the note's own region at full level: its attenuation, delay and volume
    envelope."""
    if t + 0.01 < L.delay:
        return 0.0
    db = (L.atten - main.atten) + env_held_db(L, t)
    return 10.0 ** (-db / 10.0) if db < 100.0 else 0.0


_HARM = {}


def loop_harmonics(src, ls, le, per, H, ph_at, nwin=16, source_key=None):
    """The mean amplitudes of harmonics 1..H of a looped tone (a period of
    per samples) over its loop src[ls:le] (wrapped at its end): Hann windows
    of 4 periods spread over the loop; and their phases in the window at
    ph_at. An ensemble's loop moves (its voices beat): the mean is its
    timbre, where one cut of a few periods has some harmonics high and
    others low."""
    key = (tuple(src) if source_key is None else source_key, ls, le, round(per, 4), H, ph_at, nwin)
    if key in _HARM:
        return _HARM[key]
    lp = src[ls:le]
    n = len(lp)
    W = max(16, int(round(4 * per)))
    buf = lp * (W // max(1, n) + 2)
    starts = [(ph_at - ls) % n] + ([int(i * n / nwin) for i in range(nwin)] if n > W else [])
    win = [0.5 - 0.5 * math.cos(2 * math.pi * (i + 0.5) / W) for i in range(W)]
    ws = sum(win)
    pw = [0.0] * (H + 1)
    ph = [0.0] * (H + 1)
    for k, s0 in enumerate(starts):
        seg = [buf[s0 + i] * win[i] for i in range(W)]
        for h in range(1, H + 1):
            rot = cmath.exp(-2j * math.pi * h / per)
            p = 1 + 0j
            acc = 0j
            for v in seg:
                acc += v * p
                p *= rot
            if k == 0:
                ph[h] = cmath.phase(acc)
                if len(starts) > 1:
                    continue
            a = 2.0 * abs(acc) / ws
            pw[h] += a * a
    m = max(1, len(starts) - 1)
    out = ([math.sqrt(v / m) for v in pw], ph)
    _HARM[key] = out
    return out


def harmonic_share(src, ls, le, per, rate):
    """The share of a loop's power at the harmonics of per (up to 5 kHz)."""
    H = max(1, min(160, int(min(5000.0, 0.45 * rate) * per / rate)))
    A, _ = loop_harmonics(src, ls, le, per, H, ls, nwin=8)
    lp = src[ls:le]
    tot = sum(v * v for v in lp) / max(1, len(lp))
    return sum(a * a for a in A[1:]) / 2.0 / max(tot, 1e-12)


def loop_partials(src, ls, le, rate, fmax, npk=24):
    """The strongest peaks of a loop's spectrum (the loop repeated to 2^k
    samples, a Hann window): [(Hz, amplitude)], the strongest first."""
    lp = src[ls:le]
    n = 1
    while n < 4 * len(lp) and n < 65536:
        n *= 2
    x = (lp * (n // len(lp) + 1))[:n]
    w = musdsp.hann(n)
    X = musdsp.fft([a * b for a, b in zip(x, w)])
    mag = [abs(X[k]) for k in range(n // 2)]
    kmax = min(n // 2 - 2, int(fmax * n / rate))
    top = max(mag[1:kmax]) or 1.0
    pk = []
    for k in range(2, kmax):
        m = mag[k]
        if m > mag[k - 1] and m >= mag[k + 1] and m > top * 0.01:
            a, b, c = math.log(mag[k - 1] + 1e-12), math.log(m), math.log(mag[k + 1] + 1e-12)
            d = 0.5 * (a - c) / (a - 2 * b + c) if (a - 2 * b + c) else 0.0
            pk.append(((k + d) * rate / n, 4.0 * m / n))
    pk.sort(key=lambda t: -t[1])
    return pk[:npk]


def inharmonic_cycles(pk, rate, max_src):
    """The loop length (source samples) for a tone of inharmonic partials: a
    whole number of periods of the strongest, the fewest where every
    partial's nearest whole number of cycles is within 0.5 % of its own
    (their power weighted), within max_src samples; and those cycles."""
    f1 = pk[0][0]
    best = None
    for N in range(1, 64):
        lsrc = N * rate / f1
        if lsrc > max_src:
            break
        err = sum(a * a * ((f * lsrc / rate - round(f * lsrc / rate)) / max(1.0, f * lsrc / rate)) ** 2 for f, a in pk)
        err = math.sqrt(err / sum(a * a for f, a in pk))
        if best is None or err < best[0] - 1e-9:
            best = (err, N, lsrc)
        if err < 0.005:
            break
    err, N, lsrc = best
    return lsrc, [max(1, int(round(f * lsrc / rate))) for f, a in pk]


def measure_period(src, ls, per):
    """The period near per (+-10 %) at which the loop's waveform one period
    later is most alike (a sample's tuning may be a little off)."""
    seg = src[ls:ls + int(per * 40)]
    best = None
    for pp in range(int(per * 0.9), int(per * 1.1) + 2):
        a_, b_ = seg[:len(seg) - pp], seg[pp:]
        if len(b_) < per * 4:
            break
        num = sum(u * v for u, v in zip(a_, b_))
        den = math.sqrt(sum(u * u for u in a_) * sum(v * v for v in b_)) or 1.0
        if best is None or num / den > best[0]:
            best = (num / den, pp)
    return float(best[1]) if best else per


def retain_motion(loop, rate, fundamental):
    """Keep a long loop's harmonic sidebands, not just harmonic centres.
    A short harmonic sum removes the source's beating; keeping +/-5 Hz
    in source time preserves it without the mixed-loop seam's broad noise.
    """
    N = 1
    while N < len(loop):
        N *= 2
    x = [loop[int(i * len(loop) / N)] for i in range(N)]
    X = musdsp.fft(x)
    for k in range(N):
        f = min(k, N-k) * rate / N
        h = round(f / fundamental)
        dist = abs(f - h * fundamental)
        width = float(os.environ.get('MUSSC_BANDWIDTH', '5.0')) * (h if os.environ.get('MUSSC_RELATIVE_BANDS', '1') == '1' else 1)
        edge = 1.0 if h == 1 else 2.0
        if h == 1:
            width = min(width, 3.0)
        if h < 1 or dist > width+edge:
            X[k] = 0j
        elif dist > width:
            X[k] *= (width+edge - dist) / edge
    x = [v.real / N for v in musdsp.fft([z.conjugate() for z in X])]
    return [x[int(i * N / len(loop))] for i in range(len(loop))]


def decay_rate(x, rate, t0, t1):
    """The decay (dB a second of source time) of x from t0 to t1 s (a line
    through the levels of 20 ms windows)."""
    pts = []
    w = int(0.02 * rate)
    t = t0
    while t + 0.02 <= t1 and int(t * rate) + w <= len(x):
        seg = x[int(t * rate):int(t * rate) + w]
        pts.append((t, 10.0 * math.log10(sum(v * v for v in seg) / w + 1e-12)))
        t += 0.02
    if len(pts) < 3:
        return 0.0
    n = len(pts)
    mt = sum(p[0] for p in pts) / n
    md = sum(p[1] for p in pts) / n
    num = sum((p[0] - mt) * (p[1] - md) for p in pts)
    den = sum((p[0] - mt) ** 2 for p in pts) or 1.0
    return max(0.0, -num / den)


def snap(n, tol):
    """A power of 2 for n bytes: the smaller one when n is at most tol over it."""
    t = 256
    while t * 2 <= n:
        t *= 2
    return t if n <= t * (1.0 + tol) else t * 2


def cut_freq(x, rate, eps):
    """The frequency under which 1 - eps of the energy of x lies."""
    if len(x) < 64:
        return rate / 2
    n = 1
    while n * 2 <= min(len(x), 16384):
        n *= 2
    tot = None
    # the mean power spectrum of the frames of n samples
    frames = max(1, min(8, len(x) // n))
    step = max(1, (len(x) - n) // frames) if len(x) > n else n
    for i in range(frames):
        seg = x[i * step:i * step + n]
        if len(seg) < n:
            break
        f, p = musdsp.power_spectrum(seg, rate)
        tot = p if tot is None else [a + b for a, b in zip(tot, p)]
    if tot is None:
        return rate / 2
    s = sum(tot) or 1.0
    acc = 0.0
    for fi, pi in zip(f, tot):
        acc += pi
        if acc >= (1.0 - eps) * s:
            return fi
    return rate / 2


class Zone:
    """The tables of one sample: kind 'oneshot' (table ends with a 0 byte)
    or 'attack' (start table, and loop table of loop_len bytes)."""

    def __init__(self, r, name, drum):
        self.r = r
        self.s = r.sample
        self.name = name
        self.drum = drum
        self.notes = []

    def speed(self, n, bend=0.0):
        r = self.r
        g = r.g
        return 2.0 ** (((n.key - r.root) * g['scaleTuning'] / 100.0 + g.get('coarseTune', 0) +
                        (g.get('fineTune', 0) + self.s.corr) / 100.0 + bend) / 12.0)

    def fc(self, speed):
        if getattr(self, 'exact_fc', None):
            return self.exact_fc
        return max(1, min(65535, int(round(512.0 * self.rate * speed / DOC_RATE))))


class ScSong:
    def __init__(self, name, lump, sf, q, budget=None):
        self.name = name
        self.sf = sf
        self.q = q
        groups, self.length = dmxmus.parse_mus(lump)
        self.extra_tables = []
        self.notes = self.allocate(groups)
        self.choose()
        self.has_native = any(n.preset==(0,94) for n in self.notes)
        self.compact_tones = self.has_native or any(L.mod_lfo_fc for n in self.notes for L in n.layers)
        use_frames = self.has_native and FRAMES and self.name in ONCE
        work_budget = budget-80 if budget and use_frames else budget
        if budget and not use_frames:
            work_budget = budget - (4 if any(L.mod_lfo_fc for n in self.notes for L in n.layers) else 0)
        for z in self.zones:
            self.build(z)
        self.layout()
        if budget and q.bright_drums:
            self.brighten(work_budget)           # (before the tones: the beat first)
        if budget and MODENV:
            self.sweep_starts(work_budget)
        if budget and q.long_attack > q.attack:
            self.upgrade(work_budget)
        if budget and q.sharpen and self.high_drums() < q.mask_rate:
            self.sharpen(work_budget)
        # Fund the distinct China cymbal before filter-state budget checks.
        if self.name=="D_E1M7":
            import musfx
            for z in self.zones:
                if z.notes[0].preset in ((0,44),(0,48)) and z.ltable and len(z.ltable)>=1024:
                    musfx.compact(self,z)
            self.layout()
        if MORPH:
            self.add_morphs(budget)
        # Where the complete slow string attack fits, put its envelope in
        # the sample. This avoids1/2/3-volume stairs on quiet DOC voices.
        for z in self.zones:
            if z.notes and z.notes[0].preset==(0,48) and z.kind=='attack':
                a=z.r.delay+z.r.attack
                if z.attack/z.s_mid >= a and not z.mix:
                    tab=[v*max(0.,min(1.,(i/z.rate/z.s_mid-z.r.delay)/max(z.r.attack,.00001)))
                         for i,v in enumerate(z.float_tab)]
                    self.finish(z,tab,z.float_lt,z.rate)
                    z.ensemble_attack_baked=True
        import musfx
        musfx.install(self)
        import musnoise
        musnoise.install(self)
        import museq
        museq.install(self)
        import muschoir
        muschoir.install(self)
        import muspan
        muspan.prepare(self, groups)
        muspan.fixed(self, groups)
        self.plan()

    def upgrade(self, budget):
        """The pages the song leaves in its budget: longer starts for the
        tones with the most notes (more of each note from its own start, at
        its most played pitch exactly)."""
        tones = [z for z in self.zones if z.kind == 'attack' and not z.drum and
                 (z.r.le - z.r.ls < 0.05 * z.s.rate or z.notes[0].preset == (0,48))]
        for z in sorted(tones, key=lambda z: -sum(1 for n in z.notes if n.half == 0)):
            old = dict(z.__dict__)
            z.attack_len = .30 if z.notes[0].preset == (0,48) else self.q.long_attack
            self.build(z)
            try:
                self.layout()
                ok = 255 - self.low <= budget
            except ValueError:
                ok = False
            if not ok:
                z.__dict__.clear()
                z.__dict__.update(old)
                self.layout()

    def brighten(self, budget):
        """The pages the song leaves: the kicks, snares, hats and cymbals of
        one shot kept to q.f_cym, not q.f_drum, the most heard first (their
        notes, velocity squared): a snare's crack and a kick's click lie at
        5-10 kHz, and at 6 kHz the beat was a dull thud against the reference synthesizer's
        (the hits' rise at 2-8 kHz: INTRO 8-13 dB, the recording's 20-29 dB;
        E1M3's kicks 2 dB, the recording's 28 dB)."""
        def heard(z):
            return sum((n.vel / 127.0) ** 2 for n in z.notes if n.half == 0)
        high = [z for z in self.zones if z.drum and z.kind == 'oneshot' and
                DRUM_KIND.get(z.notes[0].key, '') in ('kick', 'snare', 'hat', 'crash', 'ride')]
        for z in sorted(high, key=lambda z: -heard(z)):
            old = dict(z.__dict__)
            z.f_keep = self.q.f_cym
            self.build(z)
            try:
                self.layout()
                ok = 255 - self.low <= budget
            except ValueError:
                ok = False
            if not ok:
                z.__dict__.clear()
                z.__dict__.update(old)
                self.layout()

    def sweep_starts(self, budget):
        """The pages the song leaves: the start tables of the zones whose
        filter envelope sweeps, long enough for the sweep (MODENV_START at
        most), the most heard first: a synth bass's pluck (0.2 s: E1M3's
        16th notes, the recording's 2-8 kHz bursts) passes its sample's own
        start (0.05 s) into the loop."""
        def heard(z):
            return sum((n.stop - n.on) * (n.vel / 127.0) ** 2 for n in z.notes if n.half == 0)
        for z in sorted([z for z in self.zones if getattr(z, 'has_sweep', False)], key=lambda z: -heard(z)):
            old = dict(z.__dict__)
            z.sweep_ok = True
            self.build(z)
            try:
                self.layout()
                ok = 255 - self.low <= budget
            except ValueError:
                ok = False
            if not ok:
                z.__dict__.clear()
                z.__dict__.update(old)
                self.layout()

    def high_drums(self):
        """Hats, cymbals and snares a second (velocity squared): they mask
        the tones' read errors."""
        h = sum((n.vel / 127.0) ** 2 for z in self.zones if z.drum for n in z.notes
                if DRUM_KIND.get(n.key, '') in ('hat', 'crash', 'ride', 'snare'))
        return h / max(1e-6, self.length * TIC)

    def fizz(self, d):
        """Note tics (velocity squared) weighted by how far under a step of 1
        they read the table: a held byte images the tone high up."""
        return sum((n.stop - n.on) * (n.vel / 127.0) ** 2 * max(0.0, 1.0 - d['rate'] * n.sp / self.q.max_rate)
                   for n in d['notes'])

    def sharpen(self, budget):
        """The pages the song still leaves: higher table rates for the tones
        that play under a step of 1, the most heard first."""
        for k in (2.0, 4.0):
            tones = [z for z in self.zones if not z.drum and not getattr(z, 'exact', None) and self.fizz(z.__dict__) > 0]
            for z in sorted(tones, key=lambda z: -self.fizz(z.__dict__)):
                old = dict(z.__dict__)
                z.rscale = k
                self.build(z)
                try:
                    self.layout()
                    ok = 255 - self.low <= budget and self.fizz(z.__dict__) < 0.8 * self.fizz(old)
                except ValueError:
                    ok = False
                if not ok:
                    z.__dict__.clear()
                    z.__dict__.update(old)
                    self.layout()

    # ------------------------------------------------------------------
    def region_of(self, bank, prog, key, vel):
        regs = self.sf.regions(bank, prog, key, vel)
        if not regs:
            return None
        return min(regs, key=lambda r: r.atten)

    def sound_end(self, n, t_off):
        """The tic the note is silent (40 dB down) after, the key off at
        t_off (None: held)."""
        if self.name=='D_E1M5' and n.preset==(0,119):
            import musnoise
            return n.on+musnoise.tail_tics(n.on)
        r = n.r
        s = r.sample
        sp = 2.0 ** (r.tune / 12.0)
        dur = None
        if r.mode == 0:
            dur = (r.end - r.start) / s.rate / sp
        # held: the envelope of its layers reaches 40 dB
        layers = getattr(n, 'layers', None) or [r]
        t40 = None
        if all(L.sustain >= 40 for L in layers):
            t40 = max(L.delay + L.attack + L.hold + L.decay * 40.0 / 100.0 for L in layers)
        if t_off is not None:
            toff = (t_off - n.on) * TIC
            db = layers_db(n, toff)
            trel = toff + max(0.0, 40.0 - db) / 100.0 * max(L.release for L in layers)
            t40 = trel if t40 is None else min(t40, trel)
        if dur is not None:
            t40 = dur if t40 is None else min(t40, dur)
        if t40 is None:
            return None
        return n.on + int(math.ceil(t40 / TIC))

    def until_of(self, n, t_off):
        """The tic the note's voice is free after: its silence (sound_end),
        or the tic the reference synthesizer takes its voice."""
        u = self.sound_end(n, t_off)
        if getattr(n, 'cut', None) is not None:
            u = n.cut if u is None else min(u, n.cut)
        return u

    def allocate(self, groups):
        def level_now(m, t):
            """dB of a sounding note at tic t against a full-scale one: its
            velocity, channel volume, attenuation, envelope and release."""
            secs = (t - m.on) * TIC
            if self.name=='D_E1M5' and m.preset==(0,119):
                import musnoise
                return 40*math.log10(max(1,m.vel)/127)+40*math.log10(116/127)-m.r.atten-musnoise.wet_db(secs,m.on)
            if m.off is None or t < m.off:
                env = layers_db(m, secs)
            else:
                env = layers_db(m, (m.off - m.on) * TIC) + 100.0 * (t - m.off) * TIC / max(m.r.release, 0.001)
            return (40.0 * math.log10(max(1, m.vel) / 127.0) + 40.0 * math.log10(max(1, m.vol) / 127.0)
                    - m.r.atten - env)
        prog = [0] * 16
        vol = [100] * 16
        pan = [64] * 16
        bend = [0.0] * 16
        mod = [0] * 16
        voice_count = VOICES
        cross_title = self.name == "D_INTRO" and os.environ.get("MUSSC_CROSSFADE","1")=="1"
        busy = [None] * VOICES
        notes = []
        alt = [0]
        fates = ref_fates(groups, self.sf) if REF_STEAL else []
        fi = [0]

        def until(m):
            return m.until if m.until is not None else 1 << 30
        for tic, evs in groups:
            pool_voices = [v for v in range(VOICES) if not(cross_title and tic>0 and v in (1,3))]
            for kind, ch, a, b in evs:
                if kind == 'prog':
                    prog[ch] = a
                elif kind == 'ctl' and a == 7:
                    vol[ch] = b
                    for m in busy:              # a sounding note follows its channel's volume
                        if m is not None and m.ch == ch and until(m) > tic and not NOVOLS:
                            m.vols.append((tic, b))
                elif kind == 'ctl' and a == 10:
                    pan[ch] = b
                elif kind == 'ctl' and a in (0x78, 0x7b):
                    for m in busy:
                        if m is not None and m.ch == ch and m.off is None:
                            m.off = tic
                            m.until = self.until_of(m, tic)
                elif kind == 'bend':
                    bend[ch] = (a - 64) / 64.0 * 2.0
                    for m in busy:
                        if m is not None and m.ch == ch and m.off is None:
                            m.bends.append((tic, bend[ch]))
                elif kind == 'ctl' and a == 1:  # modulation: the vibrato's depth
                    mod[ch] = b
                    for m in busy:
                        if m is not None and m.ch == ch and m.off is None:
                            m.mods.append((tic, b))
                elif kind == 'off':
                    for m in busy:
                        if m is not None and m.ch == ch and m.key == a and m.off is None:
                            m.off = tic
                            m.until = self.until_of(m, tic)
                elif kind == 'on':
                    bank, pr = (128, 0) if ch == 9 else (0, prog[ch])
                    cut = None
                    if ch >= 10 and fates:
                        cut = fates[fi[0]]
                        fi[0] += 1
                        if cut == -1:
                            continue            # (no voice for it on the reference synthesizer)
                    if ONLY and ('drums' if ch == 9 else 'p%d' % pr) not in ONLY:
                        continue                # (a test: some parts alone)
                    r = self.region_of(bank, pr, a, b)
                    if r is None:
                        continue
                    n = Note()
                    n.cut = cut
                    n.layers = self.sf.regions(bank, pr, a, b)
                    if bank == 0 and pr in SLOW:
                        for L in [r] + n.layers:         # (each note's own region objects)
                            L.decay *= SLOW[pr]
                            L.release *= SLOW[pr]
                    n.ch, n.key, n.vel, n.on, n.off, n.end = ch, a, b, tic, None, None
                    n.vol = vol[ch]
                    n.vols = [(tic, vol[ch])]
                    n.preset = (bank, pr)
                    n.r = r
                    n.bends = [(tic, bend[ch])]
                    n.mods = [(tic, mod[ch])]
                    n.until = self.until_of(n, None)
                    center = 48 <= pan[ch] <= 80
                    kind = DRUM_KIND.get(a) if ch == 9 else None
                    # a centred melodic part, the kick and the snare: a voice
                    # on each side; the other drums on the side of their pan
                    pair = self.q.pairs and center and (ch != 9 or kind in ('kick', 'snare'))
                    if ch == 9 and not pair:
                        side = 0 if r.pan < -0.05 else 1 if r.pan > 0.05 else None
                    else:
                        side = 0 if pan[ch] < 48 else 1 if pan[ch] > 80 else None
                    halves = [n]
                    n.pair = pair
                    if pair:
                        n2 = Note()
                        n2.__dict__.update(n.__dict__)
                        n2.bends = n.bends          # (the same list: bends go to both)
                        n2.mods = n.mods
                        n2.vols = n.vols
                        n2.half = 1
                        n.partner, n2.partner = n2, n
                        halves.append(n2)
                    n.half = 0
                    for h, hs in zip(halves, (0, 1) if pair else (side,)):
                        v = None
                        if r.excl:          # the same class: the same voice (cut)
                            for u in pool_voices:
                                m = busy[u]
                                if m is not None and m.ch == ch and m.r.excl == r.excl and until(m) > tic:
                                    # E1M1 deliberately layers its two crash keys. The
                                    # reference retains both attacks; the font's shared
                                    # class must not discard the earlier same-tic key.
                                    if self.name == 'D_E1M1' and a in (49,57) and m.key in (49,57) and m.key != a and m.on == tic:
                                        continue
                                    v = u
                        if v is None:
                            free = [u for u in pool_voices if busy[u] is None or until(busy[u]) <= tic]
                            halves_busy = [u for u in pool_voices if busy[u] is not None and busy[u].half == 1]
                            if h.half == 1 and not [u for u in free if (u & 1) == hs]:
                                # the second side of a centred part: a voice of its side
                                # whose note has little sound left (a tail 30 dB down),
                                # else one side (E1M6's lead: 81 of 96 notes on one side,
                                # the reference synthesizer has it in the middle)
                                tails = [u for u in pool_voices if (u & 1) == hs and busy[u] is not None
                                         and busy[u].on < tic and
                                         (busy[u].half == 1 or busy[u].off is not None) and
                                         level_now(busy[u], tic) + 10.0 * math.log10(min(2000, max(1, until(busy[u]) - tic)))
                                         < PAIR_TAIL]
                                if not tails:
                                    halves[0].pair = False      # no voice to spare: one side
                                    continue
                                v = min(tails, key=lambda u: level_now(busy[u], tic))
                                m = busy[v]
                                m.end = tic
                                if m.off is None:
                                    m.off = tic
                                h.voice = v
                                busy[v] = h
                                notes.append(h)
                                continue
                            if hs is not None:
                                # a free voice on its side, else one of the other side, else
                                # the second side of a centred part, else the one of its side
                                # that ends first (a note cut)
                                pool = [u for u in free if (u & 1) == hs] or free or halves_busy or \
                                    [u for u in pool_voices if (u & 1) == hs]
                            elif free:
                                # the side with more free voices
                                left = sum(1 for u in free if (u & 1) == 0)
                                right = len(free) - left
                                want = 0 if left > right else 1 if right > left else alt[0]
                                alt[0] ^= 1
                                pool = [u for u in free if (u & 1) == want] or free
                            else:
                                pool = halves_busy or pool_voices
                            sid = r.g['sampleID']

                            def vkey(u):
                                m = busy[u]
                                if m is None or until(m) <= tic:
                                    # a free voice: the one its sample played last, the
                                    # one free longest
                                    return (0, m is None or m.r.g['sampleID'] != sid,
                                            until(m) if m is not None else -1)
                                # a note to cut: never one of this tic (a kick and a snare
                                # on one beat: the snare took the kick's voice before it
                                # sounded), the same sample's last note (a drum hit again),
                                # else the one with the least sound left: its level now
                                # and the tics it would still sound (a held pad is never
                                # cheaper than a drum's tail)
                                fresh = m.on >= tic
                                left = min(2000, max(1, until(m) - tic))
                                return (1, fresh, fresh or m.r.g['sampleID'] != sid,
                                        level_now(m, tic) + 10.0 * math.log10(left))
                            v = min(pool, key=vkey)
                        m = busy[v]
                        if m is not None:
                            m.end = tic
                            if m.off is None:
                                m.off = tic
                        h.voice = v
                        busy[v] = h
                        notes.append(h)
        for n in notes:
            if n.off is None:
                n.off = self.length
        if self.name in ONCE:
            # played once (it does not loop): it ends when its last note is
            # silent, not at its last event (its releases ring on)
            self.length = max([self.length] + [u for u in (self.until_of(n, n.off) for n in notes)
                                               if u is not None])
        # the end of each note's sound: the next note of its voice or its silence
        byv = [[] for _ in range(VOICES)]
        for n in notes:
            byv[n.voice].append(n)
        for ns in byv:
            for i, n in enumerate(ns):
                nxt = ns[i + 1].on if i + 1 < len(ns) else self.length
                u = self.sound_end(n, n.off)
                n.stop = min(nxt, u if u is not None else nxt)
                if getattr(n, 'cut', None) is not None:
                    n.stop = min(n.stop, max(n.on + 1, n.cut))     # its reference voice taken
        return notes

    # ------------------------------------------------------------------
    def choose(self):
        """The zones: one for each sample the notes use; in a melodic
        preset, a sample with fewer than q.min_notes notes gives them to the
        kept sample whose root is nearest their key."""
        by = {}
        for n in self.notes:
            drum = n.preset[0] == 128
            k = (128, 'kit') if drum else n.preset
            by.setdefault(k, {}).setdefault(n.r.g['sampleID'], []).append(n)
        self.zones = []
        q = self.q
        for preset, samples in sorted(by.items(), key=lambda kv: str(kv[0])):
            drum = preset[0] == 128
            count = {sid: sum(1 for n in ns if n.half == 0) for sid, ns in samples.items()}
            order = sorted(samples, key=lambda sid: -count[sid])
            keep = []
            give = {}
            for sid in order:
                r = samples[sid][0].r
                if drum:
                    kind = DRUM_KIND.get(samples[sid][0].key)
                    main = [k for k in keep if kind and DRUM_KIND.get(samples[k][0].key) == kind]
                    if count[sid] < q.min_drum and main and not any(n.key in {'D_E1M8':(46,), 'D_E1M7':(52,), 'D_E1M1':(38,)}.get(self.name,()) for n in samples[sid]):
                        give[sid] = main[0]
                        continue
                else:
                    near = [k for k in keep if abs(samples[k][0].r.root - r.root) <= q.merge_st]
                    if not near and keep and count[sid] < q.min_notes:
                        near = keep
                    if near:
                        give[sid] = min(near, key=lambda k: abs(samples[k][0].r.root - r.root))
                        continue
                keep.append(sid)
            zs = {}
            for sid in keep:
                ns = samples[sid]
                r = ns[0].r
                z = Zone(r, '%s/%s' % ('kit' if drum else 'p%d' % preset[1], r.sample.name), drum)
                zs[sid] = z
                self.zones.append(z)
            for sid, ns in samples.items():
                for n in ns:
                    z = zs.get(sid) or zs[give[sid]]
                    n.z = z
                    n.stand_in = sid not in zs and drum     # a drum: its kind's main sound
                    z.notes.append(n)
        for n in self.notes:
            z = n.z
            if z.r.g['sampleID'] == n.r.g['sampleID']:
                n.sp = 2.0 ** (n.r.tune / 12.0)          # the region of the note's own key
            elif n.stand_in:
                n.sp = 2.0 ** (z.notes[0].r.tune / 12.0)  # as the main drum of its kind
                n.r = z.notes[0].r
            else:
                n.sp = z.speed(n)
            n.freqs = [(t, n.sp * 2.0 ** (b / 12.0)) for t, b in n.bends]
            if MOTION and n.preset[0] == 0 and (any(v for _, v in n.mods) or
                    any(L.mod_to_pitch or L.vib_to_pitch or L.mod_lfo_pitch for L in n.layers)):
                # E1M3's two-level vibrato is the ranked fault. Every tic
                # overflows the 64 KiB stream. 10-tic steps are not locked
                # to the 5 Hz LFO's zero crossings; 2-cent quantum.
                n.freqs = motion_pitch(n, False, 16, 4.0) if self.name == 'D_E1M3' else motion_pitch(n, False)
            elif any(v for _, v in n.mods):
                n.freqs = vibrato(n)
            if n.preset[0] == 0 and n.preset[1] in SWEEP:
                n.freqs = sweep(n, SWEEP[n.preset[1]])
        self.exact_zones()
        if len(self.zones) > 64:
            raise ValueError('%s: %d tables' % (self.name, len(self.zones)))

    def exact_zones(self):
        """The most played keys of looped tones get a table of their own at
        their pitch: the DOC reads a table byte at floor(n x step) at
        output sample n from the note on (no interpolation), so at a step
        of 1 or more the bytes it reads in the attack can be the note's own
        samples at the output rate (no images: the fizz of a slow table),
        and the step is chosen so that the loop (a whole number of cycles in
        2^k - 1 bytes) goes on at the same step (the switch keeps its
        phase). A note longer than the attack plays the loop there."""
        q = self.q
        if not q.exact_notes:
            return
        groups = {}
        for n in self.notes:
            r = n.r
            if n.preset[0] == 128 or any(b for _, b in n.bends):
                continue
            if not (r.mode in (1, 3) and 8 < r.le - r.ls < 0.05 * r.sample.rate):
                continue
            n_out = (r.le - r.ls) * DOC_RATE / (r.sample.rate * 2.0 ** (r.tune / 12.0))
            if n_out > 2047:                # its loop in 2047 bytes at most
                continue
            groups.setdefault((n.preset, n.key), []).append(n)
        order = sorted(groups, key=lambda k: -sum(1 for n in groups[k] if n.half == 0))
        for k in order[:q.exact_max]:
            ns = groups[k]
            if sum(1 for n in ns if n.half == 0) < q.exact_notes:
                break
            r = ns[0].r
            z = Zone(r, 'p%d/k%d exact' % (k[0][1], k[1]), False)
            z.exact = True
            for n in ns:
                n.z.notes.remove(n)
                n.z = z
                n.sp = 2.0 ** (r.tune / 12.0)
                n.freqs = [(n.on, n.sp)]
                z.notes.append(n)
            self.zones.append(z)
        self.zones = [z for z in self.zones if z.notes]

    # ------------------------------------------------------------------
    def mix_of(self, z):
        """The layers of a zone's notes that its table holds besides its own
        sample: [(region, weight)], weight the layer's mean power over the
        zone's notes (its attenuation, delay and envelope) against the zone's
        region at full level; None when the notes have one sound (their
        other layers are the same sample through the same filter: a stereo
        or detuned twin, which the levels add). A preset of several samples
        (the reference synthesizer's two partials) or of one sample through two filters has
        its timbre only in the sum: the zone's own sample alone is another
        instrument (the halo pad without its strings)."""
        if z.drum or getattr(z, 'exact', None):
            return None
        from collections import Counter
        main = z.r
        # the most played key and velocity among the notes of its own sample
        # (a sample with few notes gives them to the zone: not its layers)
        own = [n for n in z.notes if n.half == 0 and n.r.sample is main.sample]
        c = Counter((n.key, n.vel) for n in own)
        if not c:
            return None
        (key, vel), _ = c.most_common(1)[0]
        n0 = next(n for n in own if n.key == key and n.vel == vel)
        # the layers' pitches and levels against the reference note's own
        # region (the zone's region is its first note's: another key, and a
        # layer's speed against it would be off by the keys between: E1M9's
        # calliope rang a sixth off)
        main = n0.r
        durs = sorted((n.stop - n.on) * TIC for n in z.notes if n.half == 0)
        D = min(10.0, max(0.05, durs[len(durs) // 2]))
        f_out = 440.0 * 2.0 ** ((key - 69) / 12.0)

        def resp(L, h):
            hz = fc_hz_of(L, vel)
            return 1.0 if hz is None else biquad_pow(h * f_out, hz, L.g.get('initialFilterQ', 0))
        out = []
        other = False
        for L in n0.layers:
            if not (L.mode in (1, 3) and L.le > L.ls + 8):
                continue                    # (a one-shot layer: no loop to hold)
            steps = 64
            w = sum(env_pow(L, (i + 0.5) * D / steps, main) for i in range(steps)) / steps
            if w <= 0.0:
                continue
            out.append((L, w))
            if w < 0.01:
                continue
            if L.sample is not main.sample:
                other = True
            elif (MORPH and L.mod_lfo_fc != main.mod_lfo_fc) or (MODPITCH and L.mod_to_pitch != main.mod_to_pitch) or any(abs(10 * math.log10(max(1e-9, resp(L, h)) / max(1e-9, resp(main, h)))) > 2.0
                     for h in range(1, 40) if h * f_out < 4000.0):
                other = True                # the same sample through another filter
        if not other:
            return None
        z.mix_ref = (key, vel)
        z.mix_main = main
        z.mix_M = None
        return out

    def mix_attack(self, z, span, s_mid, vel, steady=False, at_time=None):
        """The start of a mixed zone: each layer's samples in the time of the
        zone's own sample (its speed against it), through its own filter, at
        its mean level, summed."""
        main = z.r
        rate = float(main.sample.rate)
        key = z.mix_ref[0]
        s_m = 2.0 ** (z.mix_main.tune / 12.0)
        x = [0.0] * span
        pows = []
        for L, w in z.mix:
            s_l = 2.0 ** (L.tune / 12.0)
            d = L.sample.data[L.start:L.end]
            rl = float(L.sample.rate)
            if not steady and bake_pitch(L):
                d = pitch_attack(L, max(span, int(span * rl * s_l / (rate * s_m)) + 32), s_mid * s_l / s_m)
            if L.sample is main.sample and abs(s_l - s_m) < 1e-9:
                y = play_through(d, L.ls, L.le, span)
            else:
                # the layer reads rl x s_l samples a second while the zone's reads rate x s_m
                y = musdsp.resample(play_through(d, L.ls, L.le, int(span * rl * s_l / (rate * s_m)) + 32),
                                    rl * s_l / s_m, rate, taps=12)[:span]
            if (getattr(L, 'mod_to_fc', 0) or (MOTION and L.mod_lfo_fc)) and MODENV and not steady:
                y = biquad_tv(y, rate, lambda i, L=L: (lambda h: h / s_mid if h else None)(
                    fc_hz_of(L, vel, i / (rate * s_mid))), L.g.get('initialFilterQ', 0))
            else:
                hz = fc_hz_of(L, vel, at_time)
                if hz is not None:
                    y = biquad(y, rate, hz / s_mid, L.g.get('initialFilterQ', 0))
            g = math.sqrt(w if at_time is None else env_pow(L, at_time, z.mix_main))
            for i in range(min(span, len(y))):
                x[i] += g * y[i]
            pows.append(sum(v * v for v in y[:span]) / max(1, span))
        # (a one-shot's levels: each layer's power over the notes' span; a
        # looped zone's come from its loop, in mixed_harmonics)
        base = next((pw for (L, w), pw in zip(z.mix, pows) if L.sample is main.sample), 0.0) or 1e-9
        z.mix_pow = [pw / base for pw in pows]
        z.mix_M = sum(w * pw for (L, w), pw in zip(z.mix, z.mix_pow)) or 1.0
        return x

    def env_db(self, z, n, t):
        """dB down of a note t s after its note on, the key held."""
        if getattr(z,'frame_native',False):
            i=max(0,min(len(z.frame_times)-1,bisect.bisect_right(z.frame_times,t)-1))
            return z.frame_levels[(n.key,n.vel)][i]
        db = self.mix_db(z, n, t) if getattr(z, 'mix', None) and getattr(z, 'mix_pow', None) else layers_db(n, t)
        if MOTION and any(L.mod_lfo_volume for L in n.layers):
            pw = [env_pow(L, t, n.r) for L in n.layers]
            total = sum(pw)
            mod = sum(w * 10.0 ** (-L.mod_lfo_volume * sf2.lfo_at(t, L.mod_delay, L.mod_freq) / 10.0)
                      for L, w in zip(n.layers, pw))
            if total > 0 and mod > 0:
                db -= 10.0 * math.log10(mod / total)
        if (n.preset == (0,48) and not getattr(z,"ensemble_attack_baked",False)) or getattr(z,"noise_attack",False):
            # Slow volume attacks are separate from the sample's onset.
            # Reverse Cymbal uses this for its entire1.5s swell.
            # Ensemble1's slow volume attack is separate from the sample's
            # bow/noise onset. The old path omitted it entirely, making the
            # quiet E1M5 melody reach full level about60ms too soon.
            weights=[env_pow(L,t,n.r) for L in n.layers]
            total=sum(weights)
            attacked=sum(w*max(0.,min(1.,(t-L.delay)/max(L.attack,.00001)))**2
                         for L,w in zip(n.layers,weights))
            if total>0:db += -10*math.log10(max(1e-12,attacked/total))
        return db

    def mix_db(self, z, n, t):
        """dB down of a mixed zone's note t s after its note on: the power of
        its layers then against the mean power its table holds."""
        tot = sum(env_pow(L, t, z.mix_main) * P for (L, w), P in zip(z.mix, z.mix_pow))
        return 100.0 if tot <= 0.0 else -10.0 * math.log10(tot / z.mix_M)

    def mixed_harmonics(self, z, per, f0, ls, H, time=None):
        """The amplitudes and phases of harmonics 1..H of a synthesized loop:
        each layer's mean over its own loop, through its filter (its power
        response at each harmonic, the mean over the zone's notes: one table
        plays them all), at its mean level; the phases of the zone's own
        sample at ls. Also each layer's power at full level (mix_pow) and
        the mix's (mix_M), against the zone's own sample unfiltered."""
        main = z.r
        rate = float(main.sample.rate)
        src = z.s.data[main.start:main.end]
        s_m = 2.0 ** ((z.mix_main.tune if z.mix else main.tune) / 12.0)
        layers = z.mix if z.mix else [(main, 1.0)]
        notes = [n for n in z.notes if n.half == 0] or z.notes
        wts = [max(1, n.stop - n.on) for n in notes]
        if time is not None:
            # Repeated notes with equal pitch and velocity have the same
            # filter response. Aggregate their integer time weights once.
            grouped={}
            for n,w in zip(notes,wts):
                k=(n.sp,n.vel)
                if k in grouped:grouped[k][1]+=w
                else:grouped[k]=[n,w]
            notes=[v[0] for v in grouped.values()]
            wts=[v[1] for v in grouped.values()]
        wsum = float(sum(wts))
        P = [0.0] * (H + 1)
        pows = []
        base = None
        ph = None
        for L, w in layers:
            if L.sample is main.sample:
                lsrc, lper, lls, lle, lat = src, per, main.ls, main.le, ls
            else:
                # the layer's period: the note's pitch in its own samples
                # (the root's period, then the zone's multiple of it)
                sub = getattr(z, 'sub', 1)
                s_l = 2.0 ** (L.tune / 12.0)
                lsrc = L.sample.data[L.start:L.end]
                lper = float(L.sample.rate) / (f0 * sub * s_m / s_l)
                lls, lle = L.ls, L.le
                if lle - lls > 8 * lper:
                    lper = measure_period(lsrc, lls, lper)
                else:
                    lper = (lle - lls) / max(1, round((lle - lls) / lper))
                lper *= sub
                lat = lls
            A, phl = loop_harmonics(lsrc, lls, lle, lper, H, lat, source_key=tuple(lsrc) if time is not None else None)
            if L is main or (ph is None and L.sample is main.sample):
                ph = phl
            vel_f = []
            for h in range(1, H + 1):
                acc = 0.0
                for n, wt in zip(notes, wts):
                    hz = fc_hz_of(L, n.vel, time)
                    acc += wt * (1.0 if hz is None else
                                 biquad_pow(h * f0 * n.sp, hz, L.g.get('initialFilterQ', 0)))
                vel_f.append(acc / wsum)
            pl = sum(A[h] ** 2 * vel_f[h - 1] for h in range(1, H + 1))
            if L is main or base is None and L.sample is main.sample:
                base = sum(A[h] ** 2 for h in range(1, H + 1))
            pows.append(pl)
            for h in range(1, H + 1):
                P[h] += w * A[h] ** 2 * vel_f[h - 1]
        if ph is None:
            ph = [0.0] * (H + 1)
        base = base or 1.0
        z.mix_pow = [pl / base for pl in pows]
        z.mix_M = sum(w * pl for (L, w), pl in zip(layers, z.mix_pow)) or 1.0
        return [math.sqrt(v) for v in P], ph

    def build(self, z):
        if getattr(z, 'exact', None):
            return self.build_exact(z)
        q = self.q
        s, r = z.s, z.r
        if FRAMES and NATIVE and MORPH and self.name in ONCE and z.notes[0].preset==(0,94):
            import musmotion
            if musmotion.build(self,z):
                return
        data = s.data[r.start:r.end]
        rate = float(s.rate)
        speeds = [n.sp for n in z.notes]
        s_min = min(speeds) * 2.0 ** (-2 / 12.0) if any(len(n.bends) > 1 for n in z.notes) else min(speeds)
        s_max = max(sp for n in z.notes for _, sp in n.freqs)
        s_mid = geo_mean(speeds)
        # the source samples the song plays of it (the longest note)
        need = max((n.stop - n.on) * TIC * rate * max(sp for _, sp in n.freqs) for n in z.notes)
        need = int(need * 1.03) + 64
        looped = r.mode in (1, 3) and r.le > r.ls + 8
        # the filter, at the notes' pitch
        vels = sorted(n.vel for n in z.notes)
        vel = vels[len(vels) // 2]
        fc = r.fc - (2400.0 * (1.0 - vel / 127.0) if vel >= 64 else 0.0)
        span = min(len(data), max(need, (r.le + 16) if looped else need))
        z.unroll = 0
        sweeps = [L for L in ([r] + ([L for L, w in self.mix_of(z)] if (looped and MIX and self.mix_of(z)) else []))
                  if getattr(L, 'mod_to_fc', 0) or (bake_pitch(L))] if MODENV and looped and not z.drum else []
        z.has_sweep = bool(sweeps)
        if sweeps and getattr(z, 'sweep_ok', False):
            # the source through its loop for the sweep: the start table holds
            # the sweep (a synth bass's pluck lasts 0.2 s, its sample's own
            # start 0.05 s before the loop)
            d_, a_, h_, dc_, sus_, rel_ = sweeps[0].mod_env
            z.unroll = int(min(MODENV_START, max(L.mod_env[0] + L.mod_env[1] + L.mod_env[2] + L.mod_env[3]
                                                   for L in sweeps)) * rate * s_max) + 64
            span = max(span, z.unroll + int(0.03 * rate))
            data = play_through(data, r.ls, r.le, span)
        x = pitch_attack(r, span, s_mid) if bake_pitch(r) else data[:span]
        z.fc_hz = None
        if not hasattr(z, 'mix'):
            z.mix = self.mix_of(z) if looped and MIX else None
        if z.mix:
            x = self.mix_attack(z, span, s_mid, vel)
        elif (getattr(r, 'mod_to_fc', 0) or (MOTION and r.mod_lfo_fc)) and MODENV:
            z.fc_hz = fc_hz_of(r, vel)          # (the loop's: the envelope's sustain)
            x = biquad_tv(x, rate, lambda i: (lambda h: h / s_mid if h else None)(
                fc_hz_of(r, vel, i / (rate * s_mid))), r.g.get('initialFilterQ', 0))
        elif fc < 13500:
            z.fc_hz = 8.176 * 2.0 ** (fc / 1200.0)
            x = biquad(x, rate, z.fc_hz / s_mid, r.g.get('initialFilterQ', 0))
        if not z.drum and q.mel_lp:
            # the DOC's reads between table bytes add a little above the
            # tone's own top: the top taken down to the reference's
            x = biquad(x, rate, q.mel_lp / s_mid, 30)
        z.native = NATIVE and not z.drum and bool(z.mix) and z.notes[0].preset == (0, 94)
        # the rate: the lowest note keeps f Hz and 1 - eps of the energy
        f_keep = (q.f_cym if looped else getattr(z, 'f_keep', q.f_drum)) if z.drum else q.f_mel
        body = x[:min(len(x), need)]
        f_src = min(f_keep / s_min, cut_freq(body, rate, q.eps) * 1.05)
        if z.drum:                      # the attack of a drum, in its own time
            f_src = max(f_src, min(getattr(z, 'f_keep', q.f_floor), rate / 2))
        R = max(2000.0, min(rate, q.max_rate / max(s_max, 1e-6), 2.0 * f_src))
        R_one = R_loop = R
        if not z.drum and q.reff_min:
            # the DOC plays a table byte for several output samples (no
            # interpolation): images of the tone at the rate it plays a table
            # at; that rate at least reff_min at most notes (a table above
            # the sample's own rate if need be), within reff_bytes of the
            # form of the table (the one-shot: all the notes need; a looped
            # table: its start)
            sp = sorted(speeds)
            s_low = sp[len(sp) // 10]
            # (a faster note reads 2 or 3 bytes an output sample: the table
            # has nothing above the output's Nyquist there)
            k = getattr(z, 'rscale', 1.0)       # (sharpen: the song's spare pages)
            Rr = min(rate / 2 * 0.9 / max(s_max, 1e-6) * 2 * 3, q.reff_min * k / s_low, q.reff_max * k)
            used = min(need, len(data), (r.ls if looped else len(data)))
            R_one = max(R, min(Rr, max(R, q.reff_bytes * k * rate / max(1, used))))
            if looped:
                used = min(used, int(q.attack * rate * s_min))
                R_loop = max(R, min(Rr, max(R, q.reff_bytes * k * rate / max(1, used))))
        if z.native:
            R_loop = min(R_loop, float(os.environ.get('MUSSC_NATIVE_RATE', '6000' if self.name=='D_VICTOR' else '16000')))
        z.kind = 'oneshot'
        z.loop_len = 0
        z.nat, z.nat_len = 0.0, 0.0
        z.s_mid = s_mid
        one = snap(int(min(need, len(data)) * R_one / rate) + 1, q.snap)
        tone = not z.drum
        lbytes = 256
        lsrc_est = min(r.le - r.ls, q.short_loop * rate * 1.5) if r.le - r.ls > q.long_loop * rate else r.le - r.ls
        while tone and lbytes - 1 < lsrc_est * R_loop / rate:
            lbytes *= 2                     # a tone loop: at least one source loop
        att = snap(int(min(r.ls, (q.attack if tone else q.cym_attack) * rate * s_min) * R_loop / rate) +
                   int(0.03 * R_loop), q.snap) + (lbytes if tone else q.noise_loop + 1)
        if looped and (need > r.ls + 64 or one >= att):
            self.build_looped(z, x, rate, R_loop, s_min, s_max, need)
        else:
            self.build_oneshot(z, x, rate, R_one, s_mid, need)
        # Preserve the rare acoustic snare as its own compact native attack.
        # Three free pages buy its identity without lowering every melodic zone.
        if self.name == 'D_E1M1' and z.drum and all(n.key == 38 for n in z.notes):
            compact_rate = 16000 / z.s_mid
            compact = musdsp.resample(z.float_tab, z.rate, compact_rate, taps=24)[:767]
            for i in range(min(96, len(compact))):
                compact[-96 + i] *= (95 - i) / 96
            self.finish(z, compact, None, compact_rate)
        z.s_min, z.s_max = s_min, s_max

    def build_exact(self, z):
        q = self.q
        s, r = z.s, z.r
        rate = float(s.rate)
        sp = z.notes[0].sp
        ls, le = r.ls, r.le
        lsrc = le - ls
        n_out = lsrc * DOC_RATE / (rate * sp)          # output samples of a source loop
        # the step (>= 1) and the loop: k source loops in 256 m - 1 bytes
        best = None
        for m in (1, 2, 4, 8):
            L = 256 * m - 1
            for k in range(1, 64):
                st = L / (k * n_out)
                if L < n_out:
                    break
                if st < 1.0:
                    break
                if st > q.exact_step_max:
                    continue
                cost = q.exact_attack * DOC_RATE * st + 256 * m
                if best is None or cost < best[0]:
                    best = (cost, m, k)
        if best is None:
            raise ValueError('%s: no loop for %s' % (self.name, z.name))
        _, m, k = best
        L = 256 * m - 1
        fcx = int(round(512.0 * L / (k * n_out)))
        st = fcx / 512.0
        R = st * DOC_RATE / sp                      # the table rate in the sample's time
        # the sample (its loop repeated), the filter at the note's pitch
        durs = sorted((n.stop - n.on) * TIC for n in z.notes)
        T = min(q.exact_attack, durs[-1] + 0.01)
        n_src = int((T + 0.05) * rate * sp) + ls + 64
        data = s.data[r.start:r.end]
        while len(data) < n_src:
            data = data + s.data[r.start + ls:r.start + le]
        x = data[:n_src]
        vels = sorted(n.vel for n in z.notes)
        vel = vels[len(vels) // 2]
        fc = r.fc - (2400.0 * (1.0 - vel / 127.0) if vel >= 64 else 0.0)
        z.fc_hz = None
        cyc = s.data[r.start + ls:r.start + le]
        if fc < 13500:
            z.fc_hz = 8.176 * 2.0 ** (fc / 1200.0)
            x = biquad(x, rate, z.fc_hz / sp, r.g.get('initialFilterQ', 0))
            cyc = biquad(cyc * 8, rate, z.fc_hz / sp, r.g.get('initialFilterQ', 0))[-lsrc:]
        loop = musdsp.resample(cyc * k, rate, R, taps=12, periodic=True)[:L]
        # the attack: the band-limited table, then the bytes the DOC reads
        # (floor(n x step) at output sample n) set to the output samples
        N = int(T * DOC_RATE)
        A = (N * fcx) >> 9
        tab = musdsp.resample(x[:int(A * rate / R) + int(0.02 * rate)], rate, R, taps=12)
        y = musdsp.resample(x[:int(N * rate * sp / DOC_RATE) + 64], rate, DOC_RATE / sp, taps=12)
        for i in range(min(N, len(y))):
            p = (i * fcx) >> 9
            if p < len(tab):
                tab[p] = y[i]
        # the loop's phase that follows the attack best, a crossfade into it,
        # a tic of loop (the switch), 2^k bytes
        X = min(L // 2, max(8, int(0.004 * R)))
        seg = tab[A:A + L]
        phase = 0
        if len(seg) >= X:
            bestp = None
            for ph in range(L):
                c_ = sum(seg[i] * loop[(ph + i) % L] for i in range(0, len(seg), 2))
                if bestp is None or c_ > bestp[0]:
                    bestp = (c_, ph)
            phase = bestp[1]
        margin = int(math.ceil(1.0 * TIC * DOC_RATE * st)) + 16
        size = snap(A + X + margin, q.snap)
        if size < A + X + margin:
            size *= 2
        out = tab[:A]
        for i in range(X):
            w = (i + 0.5) / X
            a_ = tab[A + i] if A + i < len(tab) else 0.0
            out.append(a_ * (1 - w) + loop[(phase + i) % L] * w)
        kk = phase + X
        while len(out) < size:
            out.append(loop[kk % L])
            kk += 1
        A0 = (phase - A) % L
        if z.native:
            z.native_phase = A0
        lt = [loop[(j + A0) % L] for j in range(L)]
        lt.append(lt[0])
        if MORPH and synth and getattr(z, 'do_morph', False):
            z.morph_basis = (per, f0, ls, H, ncyc, L, Rp, A0)
        z.kind = 'attack'
        z.loop_len = L + 1
        z.attack = (A + X) / R
        z.nat, z.nat_len = 0.0, 0.0
        z.s_mid = sp
        z.s_min = z.s_max = sp
        z.exact_fc = fcx
        self.finish(z, out, lt, R)

    def build_oneshot(self, z, x, rate, R, s_mid, need):
        q = self.q
        r = z.r
        n = min(len(x), need)
        if z.drum:
            n = min(n, int(q.drum_max * rate * s_mid))
        y = x[:min(len(x), 2 * n)]
        if self.name == 'D_E1M3' and r.sample.name == 'gm - 950':
            # The recording's kick has a stronger click at the same bass level.
            # Keep the correction in its attack samples: no extra player writes.
            lp = 0.0
            alpha = 1.0 - math.exp(-2.0 * math.pi * 2000.0 / rate)
            for i in range(min(len(y), int(0.015 * rate * s_mid))):
                lp += alpha * (y[i] - lp)
                fade = min(1.0, max(0.0, (0.015 - i / (rate * s_mid)) / 0.003))
                y[i] += fade * (10.0 ** (6.0 / 20.0) - 1.0) * (y[i] - lp)
        if z.drum:
            # the held envelope in the table (a drum's note off does not matter)
            y = [v * 10 ** (-env_held_db(r, i / rate / s_mid) / 20.0) for i, v in enumerate(y)]
        # the end: tail_db under the peak (the rest of the notes is silence)
        peak = max(abs(v) for v in y[:n]) or 1.0
        thr = peak * 10 ** (-q.tail_db / 20.0)
        last = n
        w = int(0.01 * rate)
        while last > w and max(abs(v) for v in y[last - w:last]) < thr:
            last -= w
        # a table of 2^k bytes with its 0 byte: cut to the smaller one or
        # fill the bigger one (more of the sound)
        want = int(last * R / rate) + 1
        size = snap(want, q.snap)
        last = min(len(y), int((size - 1) * rate / R))
        cut = last < len(x)
        tab = musdsp.resample(y[:last], rate, R, taps=12)[:size - 1]
        fade = min(len(tab), int((0.006 if cut else 0.002) * R))
        for i in range(fade):
            tab[len(tab) - fade + i] *= (fade - i) / (fade + 1.0)
        self.finish(z, tab, None, R)

    def build_looped(self, z, x, rate, R, s_min, s_max, need):
        q = self.q
        r = z.r
        ls, le = r.ls, r.le
        lsrc = le - ls
        tone = not z.drum                          # its own loop (a drum: noise)
        attack = getattr(z, 'attack_len', None) or q.attack
        if MODENV and tone and getattr(z, 'sweep_ok', False) and getattr(z, 'unroll', 0):
            attack = max(attack, z.unroll / (rate * s_min))     # (the sweep in the start)
        if z.native:
            attack = float(os.environ.get("MUSSC_NATIVE_ATTACK", ".06" if self.name=="D_VICTOR" else ".12"))
        a_src = min(max(ls, getattr(z, 'unroll', 0)), int((attack if tone else q.cym_attack) * rate * s_min))
        # a loop made from its harmonics: a mixed zone's (its layers summed),
        # and an ensemble's (the mean of its long loop: no beat frozen in a
        # few periods, whose seam repeats as a flutter at the loop's rate)
        synth = tone and not z.native and SYNTH and (bool(z.mix) or lsrc > q.long_loop * rate)
        per = f0 = None
        if tone and not z.native and lsrc > q.long_loop * rate:
            # a long loop (an ensemble): a few periods of its root from it,
            # where the waveform one span later is most alike (its seam)
            f0 = 440.0 * 2.0 ** ((r.root - 69) / 12.0) * 2.0 ** (-(r.g.get('fineTune', 0) + z.s.corr) / 1200.0)
            per = rate / f0
            src = z.s.data[r.start:r.end]
            # its own period (its tuning may be a little off): k periods that
            # are not whole ones jump in phase at each seam (a ring at the
            # rate of the loop)
            seg = src[ls:ls + int(per * 40)]
            bestp = None
            for pp in range(int(per * 0.9), int(per * 1.1) + 2):
                a_, b_ = seg[:len(seg) - pp], seg[pp:]
                if len(b_) < per * 4:
                    break
                num = sum(u * v for u, v in zip(a_, b_))
                den = math.sqrt(sum(u * u for u in a_) * sum(v * v for v in b_)) or 1.0
                if bestp is None or num / den > bestp[0]:
                    bestp = (num / den, pp)
            if bestp:
                per = float(bestp[1])
                f0 = rate / per
            k = max(1, int(round(q.short_loop * f0)))
            span = int(round(k * per))
            bestc = None
            for off in range(ls, max(ls + 1, le - 2 * span), max(1, int(per / 4))):
                a_ = src[off:off + 256]
                b_ = src[off + span:off + span + 256]
                if len(b_) < 256:
                    break
                num = sum(u * v for u, v in zip(a_, b_))
                den = math.sqrt(sum(u * u for u in a_) * sum(v * v for v in b_)) or 1.0
                if bestc is None or num / den > bestc[0]:
                    bestc = (num / den, off)
            ls = bestc[1] if bestc else ls
            le = ls + span
            lsrc = span
        elif synth:
            # a short loop: whole periods of the tone
            f0n = 440.0 * 2.0 ** ((r.root - 69) / 12.0) * 2.0 ** (-(r.g.get('fineTune', 0) + z.s.corr) / 1200.0)
            k = max(1, int(round(lsrc * f0n / rate)))
            per = lsrc / float(k)
            f0 = rate / per
        z.sub = 1
        if synth:
            # the period whose harmonics hold the tone: a drawbar organ's
            # 16' and 5 1/3' sit under its root (at 1/2 and 3/2 of it), a
            # timpani's modes near 2, 3, 4 x half its principal: 2 or 3
            # periods of the root hold them (the root's harmonics miss them)
            src = z.s.data[r.start:r.end]
            best = None
            for m in (1, 2, 3, 4):
                if best is not None and best[1] >= 0.95:
                    break
                sh = harmonic_share(src, r.ls, r.le, per * m, rate)
                if best is None or sh > best[1] + 0.02:
                    best = (m, sh)
            z.sub, z.harm = best
            if z.harm < SYNTH_MIN:
                # not a tone of harmonics (a timpani: modes at 1, 1.49,
                # 1.93, 2.72 x its principal): its strongest partials in a
                # loop of whole cycles of each (a cut of the source at the
                # root's period put them on the root's harmonics: a timpani
                # on E2 rang at F#2 and G2, 8-20 dB over the reference synthesizer)
                synth = False
                if not z.mix:
                    z.inharm = True
            else:
                per *= z.sub
                f0 = rate / per
                if lsrc == r.le - r.ls:
                    k = max(1, int(round(lsrc / per)))
                    lsrc = int(round(k * per))
                else:
                    k = max(1, int(round(q.short_loop * f0)))
                    lsrc = int(round(k * per))
                le = ls + lsrc
        if MORPH and synth and self.compact_tones:
            # A stationary harmonic sum needs one fundamental period.
            # Keeping many identical periods consumes pages needed for
            # the time-varying states; its spectrum is unchanged.
            lsrc = per
            le = ls + lsrc
            z.do_morph = any(L.mod_lfo_fc for L in ([L for L, w in z.mix] if z.mix else [r]))
        inharm = tone and getattr(z, 'inharm', False) and SYNTH
        if inharm:
            src = z.s.data[r.start:r.end]
            pk = loop_partials(src, r.ls, r.le, rate, min(0.45 * rate, 6000.0 / max(s_min, 1e-6)))
            lsrc, cyc_n = inharmonic_cycles(pk, rate, 4095 * rate / R)
            # the zone's filter at each partial (the mean over its notes)
            if z.fc_hz:
                ns = [n for n in z.notes if n.half == 0] or z.notes
                qf = r.g.get('initialFilterQ', 0)
                pk = [(f, a * math.sqrt(sum(biquad_pow(f * n.sp, fc_hz_of(r, n.vel) or 20000.0, qf) for n in ns) / len(ns)))
                      for f, a in pk]
            lsrc = max(8, int(round(lsrc)))
            ls = r.ls
        if tone:
            # c source loops in 256 m - 1 bytes: the rate that meets R, fewest bytes
            best = below = None
            cap = max(rate * 1.01, R * 1.35)
            for m in ((1, 2, 4, 8, 16, 32, 64) if z.native else (1, 2, 4, 8, 16)):
                for c in range(1, 64):
                    Rp = (256.0 * m - 1) * rate / (c * lsrc)
                    if Rp > cap or Rp * s_max > 3.2 * q.max_rate:
                        continue
                    if Rp < R * 0.97:
                        if below is None or Rp > below[3]:
                            below = (0, m, c, Rp)       # the fastest short of R
                        break
                    cost = a_src * Rp / rate + 256 * m
                    if best is None or cost < best[0]:
                        best = (cost, m, c, Rp)
            _, m, c, Rp = best or below
            L = 256 * m - 1
        if inharm:
            # each partial at its whole number of cycles in a source loop, c
            # source loops in the table; phases spread (no peak of all)
            loop = [0.0] * L
            for i, ((f, a), nc) in enumerate(zip(pk, cyc_n)):
                if f * Rp / rate >= 0.45 * Rp or nc * c >= L // 2:
                    continue
                w = 2.0 * math.pi * nc * c / L
                ph0 = 2.0 * math.pi * ((i * 0.618034) % 1.0)
                for j in range(L):
                    loop[j] += a * math.cos(w * j + ph0)
        elif synth:
            H = max(1, int(0.45 * min(rate, Rp) / f0))
            A, ph = self.mixed_harmonics(z, per, f0, ls, H)
            ncyc = c * int(round(lsrc / per))           # periods in the loop table
            loop = [0.0] * L
            for h in range(1, H + 1):
                if A[h] <= 0.0:
                    continue
                w = 2.0 * math.pi * h * ncyc / L
                for j in range(L):
                    loop[j] += A[h] * math.cos(w * j + ph[h])
        elif tone:
            if z.native and z.mix:
                cross = min(lsrc // 8, int(.04 * rate * z.s_mid))
                full = self.mix_attack(z, le + cross, z.s_mid,
                    sorted(n.vel for n in z.notes)[len(z.notes)//2], steady=True)
                cyc = full[ls:le]
                # Layers have independent source loop phases: continue the
                # tail across the seam, then blend to this cycle's start.
                for j in range(cross):
                    w = (j + .5) / cross
                    cyc[j] = full[le + j] * (1.0 - w) + cyc[j] * w
                dc = sum(cyc) / len(cyc)
                cyc = [v - dc for v in cyc]
            else:
                cyc = z.s.data[r.start + ls:r.start + le]
            if lsrc != r.le - r.ls:         # a short loop of a long one: its seam smoothed
                X2 = len(cyc) // 5
                nxt = z.s.data[r.start + le:r.start + le + X2]
                for i in range(min(X2, len(nxt))):
                    w = (i + 0.5) / X2
                    cyc[i] = cyc[i] * w + nxt[i] * (1 - w)
            if z.fc_hz:                     # the filter's steady state on the cycle
                cyc = biquad(cyc * 8, rate, z.fc_hz / z.s_mid, r.g.get('initialFilterQ', 0))[-len(cyc):]
            if q.mel_lp and not z.drum:
                cyc = biquad(cyc * 8, rate, q.mel_lp / z.s_mid, 30)[-len(cyc):]
            loop = musdsp.resample(cyc * c, rate, Rp, taps=12, periodic=True)[:L]
            if z.native and os.environ.get('MUSSC_SIDEBANDS', '0') == '1':
                root_f = 440.0 * 2.0 ** ((z.mix_ref[0] - 69) / 12.0) / 2.0 ** (z.mix_main.tune / 12.0)
                loop = retain_motion(loop, Rp, root_f)
        else:
            # noise: a short loop of the tail right after the start, its ends crossfaded
            L = q.noise_loop
            Rp = R
            n_src = int(L * rate / Rp) + 1
            seg = x[a_src:a_src + n_src + n_src // 4]
            if len(seg) < n_src + n_src // 4:
                seg = (seg * (2 + (n_src // max(1, len(seg)))))[:n_src + n_src // 4]
            y = musdsp.resample(seg, rate, Rp, taps=12)
            X = L // 4
            loop = y[:L]
            for i in range(X):          # equal power: the end runs into the start
                w = (i + 0.5) / X
                loop[i] = loop[i] * math.sin(w * math.pi / 2) + y[L + i] * math.cos(w * math.pi / 2)
        # the start table: its attack, a crossfade into the loop, a tic of
        # loop (the switch may come late); 2^k bytes, the attack cut or
        # lengthened to fill them
        X = min(L // 2, max(8, int(0.004 * Rp)))
        margin = int(math.ceil(1.0 * TIC * Rp * s_max * 1.12)) + 16
        A = int(round(a_src * Rp / rate))
        size = snap(A + X + margin, q.snap)
        A = max(0, min(size - X - margin, int(max(ls, getattr(z, 'unroll', 0)) * Rp / rate)))
        a_src = int(A * rate / Rp)
        att = musdsp.resample(x[:a_src + int(0.02 * rate)], rate, Rp, taps=12)
        att = att[:A + X]
        # the loop's phase that follows the start best (a tone)
        phase = 0
        if tone and A > 0:
            seg = att[A:A + L]
            if len(seg) >= min(L // 2, X):
                best = None
                for ph in range(L):
                    c_ = sum(seg[i] * loop[(ph + i) % L] for i in range(0, len(seg), 2))
                    if best is None or c_ > best[0]:
                        best = (c_, ph)
                phase = best[1]
        if z.native:
            z.native_basis = (ls, le, c, L, Rp)
            # A long loop contains a modulation cycle. A waveform-only
            # seam search can move that cycle by a second; retain its
            # source-time phase instead of choosing a similar short wave.
            phase = int(round(A - ls * Rp / rate)) % L
        if tone and not z.drum:
            self.exact_main(z, att, x, rate, Rp, A)
        tab = att[:A]
        for i in range(X):
            w = (i + 0.5) / X
            a_ = att[A + i] if A + i < len(att) else 0.0
            tab.append(a_ * (1 - w) + loop[(phase + i) % L] * w)
        k = phase + X
        while len(tab) < size:
            tab.append(loop[k % L])
            k += 1
        # the loop table: index j plays loop phase (j + A0) mod L, A0 so that
        # the position in the start table keeps its phase after the switch
        A0 = (phase - A) % L
        if z.native:
            z.native_phase = A0
        lt = [loop[(j + A0) % L] for j in range(L)]
        lt.append(lt[0])
        if MORPH and synth and getattr(z, 'do_morph', False):
            z.morph_basis = (per, f0, ls, H, ncyc, L, Rp, A0)
        z.kind = 'attack'
        z.loop_len = L + 1
        z.attack = (A + X) / Rp                 # s of the start at speed 1
        # the tics of loop the start table holds after the attack (the snap
        # to 2^k bytes often leaves more than the margin): a switch may wait
        z.late_tics = max(1, int((len(tab) - A - X) / (Rp * s_max * 1.12 * TIC)) - 1)
        # a noise loop from before the source loop: the source's own decay
        # from there to its loop goes on in the levels
        z.nat, z.nat_len = 0.0, 0.0
        if not tone and a_src < ls:
            z.nat = decay_rate(x, rate, a_src / rate, min(ls, a_src + int(0.4 * rate)) / rate)
            z.nat_len = (ls - a_src) / rate
        self.finish(z, tab, lt, Rp)

    def exact_main(self, z, tab, x, rate, R, A):
        """The zone's most played pitch reads, from the note on, the bytes at
        floor(n x fc / 512) at output sample n (the accumulator starts at 0):
        when that step is 1 or more, those bytes of the start (up to A) are
        set to the note's own output samples: that pitch plays its start
        without the error of the DOC's missing interpolation."""
        from collections import Counter
        c = Counter()
        for n in z.notes:
            if n.half == 0 and len(n.freqs) == 1:
                c[int(round(512.0 * R * n.sp / DOC_RATE))] += 1
        if not c:
            return
        fc, _ = c.most_common(1)[0]
        if fc < 512:
            return
        sp = fc * DOC_RATE / (512.0 * R)
        N = (A << 9) // fc
        y = musdsp.resample(x[:int(N * rate * sp / DOC_RATE) + 64], rate, DOC_RATE / sp, taps=12)
        for i in range(min(N, len(y))):
            p = (i * fc) >> 9
            if p < min(A, len(tab)):
                tab[p] = y[i]
        z.exact_fc_main = fc

    def finish(self, z, tab, lt, R):
        allv = tab + (lt or [])
        peak = max(abs(v) for v in allv) or 1.0
        z.float_tab, z.float_lt = list(tab), list(lt or [])

        def q8(v):
            return max(1, min(255, 128 + int(round(v * 127.0 / peak))))
        b = bytes(q8(v) for v in tab)
        if z.kind == 'oneshot':
            b += b'\0'
        z.table = b
        z.ltable = bytes(q8(v) for v in lt) if lt else b''
        size = 256
        while size < len(z.table):
            size *= 2
        z.size = size
        z.rate = R
        z.dur = len(tab) / R
        z.gain = -32.0 * math.log2(peak)        # units (3/16 dB) against a full-scale sample

    def native_frames(self, z, count):
        ls, le, copies, L, Rp = z.native_basis
        rate = float(z.s.rate)
        cross = min(int((le-ls)//8), int(.04*rate*z.s_mid))
        saved = (list(z.mix_pow), z.mix_M)
        end = min(10., max((n.stop-n.on)*TIC for n in z.notes))
        first = min(z.attack / n.sp for n in z.notes)
        times = [i*.125 for i in range(int(end/.125)+1) if i*.125 >= first]
        # Pick states in filter/envelope space before the expensive rendering.
        def state(n,t):
            weights=[env_pow(v,t,z.mix_main) for v,w in z.mix]
            scale=sum(w*p for w,p in zip(weights,saved[0])) or 1e-9
            return [math.sqrt(sum(w * biquad_pow(h*440*2**((n.key-69)/12),
                fc_hz_of(v,n.vel,t) or 20000,v.g.get('initialFilterQ',0))
                for (v,_),w in zip(z.mix,weights))/scale) for h in range(1,25)]
        refs = {(n.key,n.vel):n for n in z.notes}
        entries = [(n,t) for n in refs.values() for t in times]
        states = [state(n,t) for n,t in entries]
        def err(a,b): return sum((x-y)**2 for x,y in zip(a,b))/max(1e-9,sum(x*x for x in a))
        ref_time = end if count>1 else sorted((n.off-n.on)*TIC for n in z.notes)[len(z.notes)//2]
        picks=[min(range(len(entries)),key=lambda i:abs(entries[i][1]-ref_time))]
        while len(picks)<min(count,len(entries)):
            i=max(range(len(entries)),key=lambda i:min(err(states[i],states[j]) for j in picks))
            if i in picks or min(err(states[i],states[j]) for j in picks) < .01:break
            picks.append(i)
        loops=[]
        for i in picks:
            n,t=entries[i]
            full=self.mix_attack(z,int(le)+cross,n.sp,n.vel,steady=True,at_time=t)
            cyc=full[int(ls):int(le)]
            for j in range(cross):
                w=(j+.5)/cross
                cyc[j]=full[int(le)+j]*(1-w)+cyc[j]*w
            dc=sum(cyc)/len(cyc);cyc=[v-dc for v in cyc]
            loop=musdsp.resample(cyc*copies,rate,Rp,taps=12,periodic=True)[:L]
            root=440*2**((z.mix_ref[0]-69)/12)/2**(z.mix_main.tune/12)
            loop=retain_motion(loop,Rp,root) if os.environ.get("MUSSC_SIDEBANDS","0")=="1" else loop
            env=sum(env_pow(v,t,z.mix_main)*p for (v,w),p in zip(z.mix,saved[0])) or 1e-9
            gain=math.sqrt(saved[1]/env)
            loop=[loop[(j+z.native_phase)%L]*gain for j in range(L)]
            loop.append(loop[0]);loops.append(loop)
        z.mix_pow,z.mix_M=saved
        if os.environ.get('MUSSC_NATIVE_EQ','1') == '1':
            # Preserve the calibrated harmonic balance while retaining the
            # sidebands. Summing long layered samples coherently can cancel
            # upper partials that the former power-sum loop preserved.
            root=440*2**((z.mix_ref[0]-69)/12)/2**(z.mix_main.tune/12)
            per=round(rate/root);f0=rate/per;H=int(.44*Rp/root)
            target,ph=self.mixed_harmonics(z,per,f0,int(ls),H)
            z.mix_pow,z.mix_M=saved
            N=L+1
            spectra=[musdsp.fft(loop) for loop in loops]
            groups=[[] for _ in range(H+1)]
            for k in range(1,N//2):
                h=round(k*Rp/N/root)
                if 1<=h<=H:groups[h].append(k)
            ratios=[1.]*(H+1)
            for h in range(1,H+1):
                power=sum(sum(abs(X[k])**2 for k in groups[h]) for X in spectra)/len(spectra)
                measured=2*math.sqrt(power)/N
                ratios[h]=target[h]/max(1e-12,measured)
            base=ratios[1] or 1.
            gains=[min(4.,max(.25,x/base)) for x in ratios]
            for j,X in enumerate(spectra):
                for h in range(1,H+1):
                    for k in groups[h]:
                        X[k]*=gains[h];X[-k]*=gains[h]
                loops[j]=[v.real/N for v in musdsp.fft([a.conjugate() for a in X])]
                loops[j][-1]=loops[j][0]
            z.native_eq_db=[round(20*math.log10(g),2) for g in gains[1:]]
        sequence=[min(range(len(picks)),key=lambda j:err(a,states[picks[j]])) for a in states]
        sequences = {key:sequence[i*len(times):(i+1)*len(times)] for i,key in enumerate(refs)}
        return times,sequences,loops

    def add_morphs(self, budget):
        """Filter LFOs change harmonic balance, not the part's master volume.
        Phase-compatible loop tables share the parent's rate, phase and gain.
        The existing full-note command with its no-halt bit changes tables
        while the DOC accumulator keeps running; no new runtime opcode.
        """
        import copy
        def loop_alias(z):
            v=copy.copy(z);v.name=z.name+'/filter';v.kind='loop';v.notes=[]
            v.size=v.loop_len=z.loop_len;v.table=b'';v.ltable=b''
            v.alias_of=z;v.native_basis=None;v.morph_basis=None
            self.zones.append(v)
            return v
        originals = sorted(self.zones, key=lambda z: not (getattr(z,'native_basis',None) or getattr(z,'frame_native',False)))
        remaining_frames=sum(bool(getattr(z,'frame_native',False)) for z in originals)
        for z in originals:
            if getattr(z,'frame_native',False):
                import musmotion
                musmotion.install(self,z,budget,remaining_frames)
                remaining_frames-=1
                continue
            if getattr(z,'native_basis',None):
                held=max((n.off-n.on)*TIC for n in z.notes)
                times,indices,loops=self.native_frames(z,int(os.environ.get("MUSSC_NATIVE_STATES",1)))
                family=[z]
                for loop in loops[1:]:
                    v=copy.copy(z);v.name=z.name+'/filter';v.kind='loop';v.notes=[]
                    v.size=v.loop_len=len(loop);v.table=bytes(len(loop));v.ltable=b''
                    v.native_basis=None;v.morph_basis=None
                    family.append(v);self.zones.append(v)
                self.layout()
                if budget and 255-self.low>budget:
                    raise ValueError(self.name+': native modulation states exceed cap')
                peak=max(abs(x) for x in z.float_tab+[x for loop in loops for x in loop]) or 1.
                def q8(x):return max(1,min(255,128+round(x*127/peak)))
                z.gain=-32*math.log2(peak);z.table=bytes(q8(x) for x in z.float_tab)
                z.ltable=bytes(q8(x) for x in loops[0])
                for v,loop in zip(family[1:],loops[1:]):
                    v.table=bytes(q8(x) for x in loop);v.gain=z.gain
                family[0]=loop_alias(z)
                z.morph_family=family;z.morph_times=times;z.morph_sequences=indices
                z.morph_indices=next(iter(indices.values()))
                continue
            if not getattr(z, 'morph_basis', None):
                continue
            per, f0, ls, H, nc, L, Rp, phase = z.morph_basis
            import mussmooth
            if os.environ.get('MUSSC_SMOOTH_FILTER','1') == '1':
                mussmooth.install(self,z,budget)
                continue
            end = min(20.0, max((n.stop - n.on) * TIC for n in z.notes))
            first = min(z.attack / n.sp for n in z.notes)
            times = [i * .125 for i in range(int(end / .125) + 1) if i * .125 >= first]
            if not times:
                continue
            saved = (list(z.mix_pow), z.mix_M)
            amps = []
            for t in times:
                a, ph = self.mixed_harmonics(z, per, f0, ls, H, time=t)
                amps.append(a)
            z.mix_pow, z.mix_M = saved
            base_a, ph = self.mixed_harmonics(z, per, f0, ls, H)
            z.mix_pow, z.mix_M = saved
            # A relative squared spectral error, weighted by audible energy.
            def err(a, b):
                return sum((x-y)**2 for x,y in zip(a,b)) / max(1e-12,sum(x*x for x in a))
            selected = [base_a]
            max_tables = min(9, 64-len(self.zones))
            while len(selected) < max_tables:
                i = max(range(len(amps)), key=lambda i:min(err(amps[i], a) for a in selected))
                if min(err(amps[i], a) for a in selected) < .01:
                    break
                selected.append(amps[i])
            if len(selected)==1:
                continue
            family = [z]
            loops = [z.float_lt]
            for a in selected[1:]:
                loop = [sum(a[h] * math.cos(2*math.pi*h*nc*((j+phase)%L)/L + ph[h])
                            for h in range(1,H+1)) for j in range(L)]
                loop.append(loop[0])
                v = copy.copy(z)
                v.name = z.name + '/filter'
                v.kind = 'loop'
                v.notes = []
                v.size = v.loop_len = L+1
                v.table = bytes(L+1)
                v.ltable = b''
                v.morph_basis = None
                family.append(v);loops.append(loop)
                self.zones.append(v)
            self.layout()
            # Reduce only the number of timbre states when pages are tight;
            # keep at least two states or reject this source configuration.
            while budget and 255-self.low > budget and len(family)>2:
                self.zones.remove(family.pop());loops.pop();selected.pop()
                self.layout()
            if budget and 255-self.low > budget:
                raise ValueError(self.name + ': filter modulation tables exceed page cap')
            peak = max(abs(x) for x in z.float_tab + [x for loop in loops for x in loop]) or 1.
            def q8(v): return max(1,min(255,128+round(v*127/peak)))
            z.gain = -32*math.log2(peak)
            z.table = bytes(q8(v) for v in z.float_tab)
            z.ltable = bytes(q8(v) for v in loops[0])
            for v,loop in zip(family[1:],loops[1:]):
                v.table = bytes(q8(x) for x in loop)
                v.gain = z.gain
            family[0]=loop_alias(z)
            z.morph_family = family
            z.morph_times = times
            z.morph_indices = [min(range(len(selected)),key=lambda j:err(a,selected[j])) for a in amps]
            z.morph_error = max(min(err(a,b) for b in selected) for a in amps)
        if len(self.zones)>64:
            raise ValueError(self.name+': modulation descriptors exceed 64')
        self.layout()

    def morph_at(self, n, tic):
        z = n.z
        if getattr(z,'quiet_tail',False):return int(tic>=n.quiet_at)
        if not getattr(z, 'morph_family', None):
            return 0
        sec = (tic-n.on)*TIC
        i = max(0, min(len(z.morph_times)-1, bisect.bisect_right(z.morph_times, sec)-1))
        return getattr(z,'morph_sequences',{}).get((n.key,n.vel),z.morph_indices)[i]

    # ------------------------------------------------------------------
    def layout(self):
        """DOC pages: the tables from 254 down, the biggest first, each at a
        multiple of its size; a table holds only the pages of its bytes, so
        a smaller one can take the rest of a block."""
        items = []
        for i, z in enumerate(self.zones):
            if getattr(z,'alias_of',None) is not None:
                continue
            items.append((z.size, len(z.table), i, 'a'))
            if z.kind == 'attack':
                items.append((z.loop_len - 1 + 1, z.loop_len, i, 'l'))
        for i,v in enumerate(self.extra_tables):
            items.append((256,len(v.table),i,'x'))
        used = set()
        self.pages = [None] * len(self.zones)
        self.lpages = [None] * len(self.zones)
        for size, nbytes, i, kind in sorted(items, key=lambda t: (-t[0], -t[1])):
            n = size // 256
            k = (nbytes + 255) // 256
            p = (255 - n) // n * n
            while p >= 0 and any(qq in used or qq > 254 for qq in range(p, p + k)):
                p -= n
            if p < 0:
                raise ValueError('%s: the tables do not fit DOC RAM' % self.name)
            used.update(range(p, p + k))
            if kind == 'x':
                self.extra_tables[i].page = p
            elif kind == 'a':
                self.pages[i] = p
            else:
                self.lpages[i] = p
        for i,z in enumerate(self.zones):
            if getattr(z,'alias_of',None) is not None:
                self.pages[i]=self.lpages[self.zones.index(z.alias_of)]
                self.lpages[i]=self.pages[i]
        for z in self.zones:
            for v in getattr(z,'morph_family',[]):
                if getattr(v,'extra_page',False) and getattr(v,'alias_of',None) is not None:
                    v.page=self.lpages[self.zones.index(v.alias_of)]
        self.low = min(used) if used else 255

    # ------------------------------------------------------------------
    def fc_of(self, n, speed):
        return n.z.fc(speed)

    def plan(self):
        """Tracks for the scheduler of tools/musbank.py."""
        q = self.q
        lstep = int(os.environ.get('MUSSC_LSTEP', 0)) or LEVEL_STEP.get(self.name, musbank.STEP)
        tracks = [[] for _ in range(VOICES)]
        exact = set()
        self.switch_at = {}
        self.zone_of = {}
        byv = [[] for _ in range(VOICES)]
        for n in self.notes:
            byv[n.voice].append(n)
            self.zone_of[id(n)] = self.zones.index(n.z)
        for v in range(VOICES):
            ns = byv[v]
            for i, n in enumerate(ns):
                z = n.z
                r = n.r
                end = ns[i + 1].on if i + 1 < len(ns) else self.length
                amp = (n.vel / 127.0) ** 2                  # (the channel volume: each tic's)
                base = z.gain - 32.0 * math.log2(max(amp, 1e-6)) + r.atten * 32.0 / 6.02 + 16
                base -= cal_db(self.name, n) * 32.0 / 6.02
                # 3 dB down each side of a centred part while both sound (a
                # side whose other one was taken by a later note plays alone)
                both = n.partner.stop if n.pair and getattr(n, 'partner', None) is not None else (end + 1 if n.pair else n.on)
                if getattr(n, "pan_track", None) is not None: both = n.on
                sp = n.freqs[0][1]
                exact.add(n.on)
                if hasattr(n,"quiet_at"):exact.add(n.quiet_at)
                if getattr(z,'frame_native',False):
                    exact.add(n.on+1)
                done = None
                if z.kind == 'oneshot':
                    done = n.on + int(math.ceil(z.dur / sp * 140))
                elif z.kind == 'attack':
                    # the nearest tic: the wake may be half a tic early or late, so
                    # the start table holds a tic of loop after the attack
                    sw = n.on + (z.baked_attack_tics if getattr(z,"baked_attack_tics",0) else max(1, int(round(z.attack / sp * 140))))
                    if getattr(z,"baked_attack_tics",0):exact.add(sw)
                    self.switch_at[id(n)] = sw
                off = max(n.off, n.on + 1)
                n.fast_off = off if r.release < 0.05 and off < end else None
                baked = z.kind == 'oneshot' and (z.drum or getattr(z,'baked_timpani',False))
                # a note under its channel's volume automation (E1M2's swells,
                # the fades of E1M8 and INTRO): 0.75 dB steps; a swell in 3 dB
                # stairs spreads a low note into its neighbours (E1M2's F#1
                # strings: A1-C2 13-18 dB over the reference synthesizer)
                auto = len(set(v for _, v in n.vols)) > 2 or (getattr(z,'frame_native',False) and self.name in ONCE)
                tremolo = MOTION and any(L.mod_lfo_volume for L in n.layers)
                nstep = min(lstep, 4) if (auto and AUTOSTEP != 'coarse') or tremolo or getattr(z,'noise_attack',False) or getattr(z,'rom_timpani',False) or getattr(z,'fine_static',False) or (self.name=='D_VICTOR' and z.drum and n.key in (36,40)) else lstep
                n.tic_steps = nstep < musbank.STEP and (AUTOSTEP == 'tic' or self.name in LEVEL_STEP)
                # Low string swells expose delayed level steps as sidebands.
                n.level_wait = 1 if n.tic_steps else (int(os.environ.get('MUSSC_AUTOWAIT',
                    2 if self.name == 'D_E1M2' else q.tol)) if auto else (2 if tremolo else q.tol))
                if n.preset==(0,48) or getattr(z,"noise_attack",False):n.level_wait=1
                qs = []
                vi = 0
                for t in range(n.on, end + 1):
                    if done is not None and t >= done:
                        qs.append('done')
                        continue
                    while vi + 1 < len(n.vols) and n.vols[vi + 1][0] <= t:
                        vi += 1
                    cv = n.vols[vi][1]                  # the channel's volume now
                    if self.name=='D_E1M5' and n.preset==(0,119):cv=116 # wet curve already includes CC7
                    if cv <= 0:
                        qs.append(None)
                        continue
                    # the channel's volume now, not at the note on: a note
                    # that starts while its channel is at 0 and fades in
                    # (E1M8's choir) sounds as the fade rises
                    dv = channel_attenuation(self.name, n.preset, cv)
                    secs = (t - n.on) * TIC
                    nat = 0.0
                    if z.kind == 'attack' and z.nat:
                        nat = z.nat * min(z.nat_len, max(0.0, secs * sp - z.attack)) / sp
                    if t < off:
                        db = (0.0 if baked else self.env_db(z, n, secs)) + nat
                    else:
                        db0 = (0.0 if baked else self.env_db(z, n, (off - n.on) * TIC)) + nat
                        db = db0 + 100.0 * (t - off) * TIC / max(r.release, 0.001)
                        if baked and r.release > 1.0:
                            db = 0.0                    # a drum rings on
                    if self.name=='D_E1M5' and n.preset==(0,119):
                        import musnoise
                        db=musnoise.wet_db(secs,n.on)
                        if hasattr(n,"quiet_at") and t>=n.quiet_at:db-=24.0824
                    if db > TAIL_DB:
                        qs.append(None)
                        continue
                    if db + dv > 60.0 or t >= n.stop + 1:
                        qs.append(None)
                        continue
                    # (the static level: velocity, channel volume, attenuation,
                    # the side; the envelope's part apart: the knee presses the
                    # static level, not a decay)
                    qs.append((float(base + (16 if t < both else 0) + dv * 32.0 / 6.02), db * 32.0 / 6.02))
                tracks[v].append((n.on, end, n, Freq(n), qs, nstep))
        # the DOC's volume spans 51 dB under a full-scale voice, and a song
        # keeps its loudest tic where the SoundFont puts it (12-17 dB under
        # it: the balance with the sound effects, whose loudest are at 240
        # of 255: no headroom there), LIFT_MAX dB up at most; the levels more
        # than KNEE_DB under the loudest are pressed (KNEE_RATIO), so the
        # quiet parts stay over the floor (E1M8's choir fading in, E1M2's
        # strings at a low channel volume: 9-46 % of their held tics under it)
        us = [u[0] + u[1] for vt in tracks for tr in vt for u in tr[4] if isinstance(u, tuple)]
        top = min(us) if us else 0.0
        lift = max(0.0, min(top - HEAD, LIFT_MAX * 32.0 / 6.02)) if us and LIFT else 0.0
        if getattr(self, 'lift_cap', None) is not None:
            lift = min(lift, self.lift_cap)     # (its head must fit MUSBUF: main)
        self.lift_db = lift * 6.02 / 32.0
        knee = KNEE_DB * 32.0 / 6.02
        for vt in tracks:
            for tr in vt:
                qs = tr[4]
                for i, u in enumerate(qs):
                    if isinstance(u, tuple):
                        rel = u[0] - top
                        if KNEE and rel > knee:
                            rel = knee + (rel - knee) * KNEE_RATIO
                        # Fine attack steps only during Ensemble1's rise;
                        # retain the normal release/sustain write budget.
                        n=tr[2]
                        attack = n.preset==(0,48) and not getattr(n.z,"ensemble_attack_baked",False) and i*TIC < max(L.delay+L.attack for L in n.layers)
                        qs[i] = level_index(top + rel + u[1] - lift, 4 if attack else tr[5])
                # a note silent at its start or for a while (its channel's
                # volume at 0, or under the DOC's floor) that sounds later
                # runs muted till then: the scheduler starts a voice only at
                # its note on and never after a halt (E1M2 opens with its
                # strings on channel volume 0 rising: 14 s of silence)
                last = max((i for i, u in enumerate(qs) if isinstance(u, int)), default=-1)
                for i in range(last):
                    if qs[i] is None:
                        qs[i] = MUTE
        import muspan
        muspan.levels(self, tracks, exact)
        self.schedule(tracks, exact)
        muspan.route(self)
        if self.name == "D_INTRO" and os.environ.get("MUSSC_CROSSFADE","1")=="1":
            import muscross
            muscross.install(self)

    def schedule(self, tracks, exact):
        """The wakes: the notes at their exact tics; every other write when
        a wake comes anyway, within its own time: a level step q.tol tics,
        the drop of a fast release q.tol_off, the halt of a silent voice
        q.tol_halt, a switch to the loop from q.sw_early tics before the end
        of the start to the tic after it (the start table holds a tic of
        loop). A wake is the cost of the music (its interrupt, the restart
        of the alarm, the player's code out of the cache)."""
        q = self.q
        length = self.length
        self.wakes = {}
        cur = [None] * VOICES
        pos = [0] * VOICES
        wr = [None] * VOICES             # [note, level, fc, running, switched]
        ex = sorted(exact)
        ei = 0
        t = 0

        def want(v, tt):
            """(level, fc) the voice wants at tic tt, 'done', or None."""
            c = cur[v]
            on, end, n, fq, qs = c[:5]
            ql = qs[tt - on] if on <= tt <= end else None
            return ql, n.z.fc(fq.freq_at(tt))

        while True:
            for v in range(VOICES):
                while pos[v] < len(tracks[v]) and tracks[v][pos[v]][0] <= t:
                    cur[v] = tracks[v][pos[v]]
                    pos[v] += 1
            writes = []
            for v in range(VOICES):
                c = cur[v]
                if c is None:
                    continue
                on, end, n, fq, qs = c[:5]
                ql, fc = want(v, t)
                w = wr[v]
                if ql == 'done':
                    if w is not None and w[0] is n:
                        w[1] = None
                        w[3] = False
                    continue
                if w is None or w[0] is not n:
                    if ql is not None:
                        writes.append(('on', v, (n, ql, fc)))
                        wr[v] = [n, ql, fc, True, False, 0]
                    else:
                        if w is not None and w[3]:
                            writes.append(('off', v, None))
                        wr[v] = [n, None, fc, False, False, 0]
                    continue
                if not w[3]:
                    continue
                sw = self.switch_at.get(id(n))
                if sw is not None and not w[4] and t >= sw - (0 if getattr(n.z,"baked_attack_tics",0) else q.sw_early):
                    writes.append(('sw', v, None))
                    w[4] = True
                if (w[4] or getattr(n.z,"quiet_tail",False)) and ql is not None:
                    mi = self.morph_at(n,t)
                    if mi != w[5]:
                        writes.append(('morph',v,n.z.morph_family[mi]))
                        w[5] = mi
                if ql is None:
                    writes.append(('off', v, None))
                    w[1] = None
                    w[3] = False
                    continue
                if fc != w[2]:
                    writes.append(('fc', v, fc))
                    w[2] = fc
                if musbank.vol_of(ql) != musbank.vol_of(w[1]):
                    writes.append(('lev', v, ql))
                    w[1] = ql
            if writes or t == 0:
                self.wakes[t] = writes
            if t >= length:
                break
            while ei < len(ex) and ex[ei] <= t:
                ei += 1
            nxt = ex[ei] if ei < len(ex) else length
            # the latest tic each pending write may wait to
            due = nxt
            for v in range(VOICES):
                c, w = cur[v], wr[v]
                if c is None or w is None or w[0] is not c[2] or not w[3]:
                    continue
                on, end, n, fq, qs = c[:5]
                sw = self.switch_at.get(id(n))
                if sw is not None and not w[4] and sw <= end:
                    due = min(due, max(t + 1, sw + min(q.sw_late, getattr(n.z, 'late_tics', 1))))
                for tt in range(t + 1, min(end, due) + 1):
                    ql = qs[tt - on]
                    if ql == 'done':
                        break
                    if ql is None:
                        due = min(due, tt + q.tol_halt)
                        break
                    if (w[4] or getattr(n.z,"quiet_tail",False)) and self.morph_at(n,tt) != w[5]:
                        due = min(due, tt + 2)
                        break
                    if n.z.fc(fq.freq_at(tt)) != w[2]:
                        due = min(due, tt + q.tol_bend)
                        break
                    if musbank.vol_of(ql) != musbank.vol_of(w[1]):
                        late = q.tol_off if n.fast_off is not None and tt >= n.fast_off else \
                            n.level_wait                    # (fine steps: bounded delay)
                        due = min(due, tt + late)
                        break
            t = max(min(due, length), t + 1)

    # ------------------------------------------------------------------
    def encode(self):
        """(stream, pitches), as musbank.Song.encode, for the player's cheaper
        commands: a note names only what changes on its voice (its table
        after a switch, its pitch), and a wait of the same frequency as the
        one before writes only the restart of the alarm."""
        fcs = []
        fci = {}

        def pidx(fc):
            if fc not in fci:
                fci[fc] = len(fcs)
                fcs.append(fc)
            return fci[fc]
        out = bytearray()
        st = [None] * VOICES             # [descriptor, fc, level, running, switched]
        alarm = None                     # the alarm frequency (the first wait writes it)
        drift = 0.0
        wakes = sorted(self.wakes)
        self.wake_tics = []
        for i, t in enumerate(wakes):
            nxt = wakes[i + 1] if i + 1 < len(wakes) else self.length
            gap = max(1, nxt - t)
            m = gap
            if drift > musbank.TIC_SAMPLES / 2 and m > 1:
                m -= 1
            elif drift < -musbank.TIC_SAMPLES / 2:
                m += 1
            drift -= gap * musbank.TIC_SAMPLES
            waits = bytearray()
            wt = t
            while m > 0:
                k = min(m, 15)
                fc = musbank.alarm_fc(k)
                if alarm is not None and fc == alarm:
                    waits += bytes([0xd0 | k])
                elif alarm is not None and (fc >> 8) == (alarm >> 8):
                    waits += bytes([0xf0 | k])
                else:
                    waits += bytes([0xe0 | k])
                alarm = fc
                self.wake_tics.append(wt)
                wt += k
                drift += musbank.alarm_samples(k)
                m -= k
            out += waits[0:1]
            for kind, v, val in self.wakes[t]:
                s = st[v]
                if kind == 'on':
                    n, lev, fc = val
                    d = self.zone_of[id(n)]
                    p = pidx(fc)
                    # bit 7: a halt command stopped the voice (the song's
                    # start and end halt them all), so no halt write
                    a = lev | (0x80 if s is None or not s[3] else 0)
                    if s is None or s[0] != d:
                        out += bytes([0x30 | v, d, p, a])
                    elif s[4] and s[1] == fc:
                        out += bytes([0xc0 | v, a])
                    elif s[4]:
                        out += bytes([0x70 | v, p, a])
                    elif s[1] == fc:
                        out += bytes([0xa0 | v, a])
                    else:
                        out += bytes([0x20 | v, p, a])
                    st[v] = [d, fc, lev, True, False]
                elif kind == 'sw':
                    out += bytes([0xb0 | v])
                    s[4] = True
                elif kind == 'morph':
                    if getattr(val,'extra_page',False):
                        out += bytes([0xbe,v,val.page])
                        s[4] = True
                    else:
                        d = self.zones.index(val)
                        out += bytes([0x30|v,d,pidx(s[1]),s[2]|0x80])
                        s[0],s[4] = d,True
                elif kind == 'ctl':
                    out += bytes([0xbf,v,val])
                elif kind == 'lev':
                    step = {4: 0x00, 8: 0x80, -4: 0x90}.get(val - s[2])
                    if step is not None:
                        out += bytes([step | v])
                    else:
                        out += bytes([0x10 | v, val])
                    s[2] = val
                elif kind == 'fc':
                    p = pidx(val)
                    out += bytes([(0x50 if (val >> 8) == (s[1] >> 8) else 0x40) | v, p])
                    s[1] = val
                elif kind == 'off':
                    if s is not None and s[3]:
                        out += bytes([0x60 | v])
                        s[3] = False
            if i + 1 == len(wakes) and self.name in ONCE:
                for v in range(VOICES):
                    if st[v] is not None and st[v][3]:
                        out += bytes([0x60 | v])
                        st[v][3] = False
            out += waits[1:]
        out += bytes([0xe0])
        if self.name not in ONCE:
            # a looping song: the voices that sound at its end halt as it
            # starts again (its first wake: at its end), not at its last wake
            halts = bytes([0x60 | v for v in range(VOICES) if st[v] is not None and st[v][3]])
            out = out[:1] + halts + out[1:]
        if len(fcs) > 256:
            raise ValueError('%s: %d pitches' % (self.name, len(fcs)))
        return bytes(out), fcs

    def image(self):
        stream, fcs = self.encode()
        D = len(self.zones)
        img = bytearray(struct.pack('<BBHBB', D, len(fcs) & 255, len(stream), self.low, 0))
        img += stream
        img += bytes(fc & 255 for fc in fcs)
        img += bytes(fc >> 8 for fc in fcs)
        img += bytes(self.pages)
        img += bytes(musbank.size_code(z.size) for z in self.zones)
        img += bytes(2 if z.kind == 'oneshot' else 0 for z in self.zones)
        img += bytes(lp if z.kind == 'attack' else p for z, p, lp in zip(self.zones, self.pages, self.lpages))
        img += bytes(musbank.size_code(z.loop_len) if z.kind == 'attack' else musbank.size_code(z.size)
                     for z in self.zones)
        doc = bytearray(b'\x80' * (256 * (255 - self.low)))
        for z, p, lp in zip(self.zones, self.pages, self.lpages):
            o = 256 * (p - self.low)
            doc[o:o + len(z.table)] = z.table
            if z.kind == 'attack':
                o = 256 * (lp - self.low)
                doc[o:o + len(z.ltable)] = z.ltable
        for v in self.extra_tables:
            o=256*(v.page-self.low)
            doc[o:o+len(v.table)]=v.table
        if self.extra_tables:
            img[5]=1  # stream extension: 0xBE voice page, phase-preserving pointer
        if getattr(self,"crossfade_stats",None) or getattr(self,"pan_stats",None) or getattr(self,"fixed_route_count",0):img[5]|=2  # 0xBF raw control/pan
        img += doc
        # One pass on this fresh encode. It raises the product up to the
        # register-192 ceiling and leaves the loud samples full scale.
        # A second apply on that image leaves the bytes unchanged;
        # image() does not loop it.
        import musknee
        baked, info = musknee.apply_image(bytes(img), self.name)
        return baked, info['stream'], fcs


class Freq:
    def __init__(self, n):
        self.n = n
        self.ts = [t for t, _ in n.freqs]

    def freq_at(self, tic):
        i = bisect.bisect_right(self.ts, tic) - 1
        speed = self.n.freqs[max(0, i)][1]
        z=self.n.z
        if tic < self.n.on+getattr(z,"baked_attack_tics",0):
            speed *= z.attack_rate/z.rate
        return speed


VIB_HZ = 5.5              # the reference synthesizer's vibrato (its recording of E1M8)
VIB_CENTS = 0.95          #   cents of depth a step of the modulation (22: +-21)
VIB_STEP = 5.0            #   cents between the pitches it writes


# Levels against the reference recordings (a part's level in the cells it holds
# alone, against the song's other parts, tools: sound_w/partfit.py): dB a
# part plays up (+) or down (-). The kit's kick (sample 950) is 1.5-3.3 dB
# over the recordings in the 5 songs with it; INTRO's halo pad (p94) 6 dB:
# the SoundFont's halo low notes are louder than the reference synthesizer's (VICTOR's
# higher ones match it).
CAL = {('D_E1M5',119,None):4.0,
       ('D_E1M2','kit','gm - 950'):3.3, ('D_E1M2','kit','gm - 956'):3.3,
       ('D_E1M2','kit','gm - 954'):2.0, ('D_E1M3','kit','gm - 954'):5.0,
       ('D_E1M4','kit','gm - 954'):1.5, ('D_E1M8','kit','gm - 954'):3.5,
       ('D_INTER','kit','gm - 954'):2.0, ('D_E1M9','kit','gm - 957'):3.4,
       ('D_E1M9','kit','gm - 959'):3.3, ('D_E1M1', 'kit', 'gm - 956'): 3.0, ('D_E1M1', 'kit', 'gm - 957'): 3.0, ('D_E1M1', 'kit', 'gm - 959'): 3.0, ('D_E1M1', 'kit', 'gm - 617'): 3.0, ('D_VICTOR', 'kit', 'gm - 958'): 2.0, ('D_E1M4', 'kit', 'gm - 583'): -1.0, ('D_E1M6', 'kit', 'gm - 583'): -1.0, ('D_E1M9',42,None): -2.0, ('D_INTER', 'kit', 'gm - 956'): 5.0, ('D_INTER', 'kit', 'gm - 617'): 5.0, ('D_INTER', 'kit', 'gm - 957'): 5.0, ('D_INTER', 'kit', 'gm - 959'): 5.0, ('D_E1M7', 46, None): -2.5, ('D_E1M6', 108, None): -3.5, ('D_VICTOR', 'kit', 'gm - 620'): 2.5, ('D_VICTOR', 32, None): 1.0, ('D_E1M4', 'kit', 'gm - 950'): 1.0, ('D_E1M6', 81, None): 4.0, ('D_E1M3', 'kit', 'gm - 959'): 4.0, ('D_E1M3', 'kit', 'gm - 957'): 3.0, ('D_E1M2', 37, None): 3.5, ('D_E1M3', 38, None): 3.5, ('D_E1M4', 30, None): 5.5, ('D_VICTOR', 'kit', 'gm - 950'): 3.0, ('D_VICTOR', 'kit', 'gm - 953'): 2.5, ('D_E1M3', 'kit', 'gm - 953'): 2.75, ('D_E1M7', 81, None): 2.5, ('D_INTER', 81, None): 4.0, ('D_E1M9', 41, None): -1.5, ('D_E1M9', 30, None): 2.5, ('D_INTRO', 'kit', 'gm - 953'): 4.5, (None, 119, None): -4.0, ('D_E1M1', 30, None): 3.75, ('D_INTRO', 51, None): -3.0, (None, 'kit', 'gm - 950'): -2.5, ('D_INTRO', 94, None): -5.0,
       ('D_E1M3', 'kit', 'gm - 950'): 4.0,
       ('D_E1M7', 'kit', 'gm - 583'): -6.0,
       ('D_E1M8', 29, None): -4.5,
       ('D_E1M8', 44, None): -4.0}


def channel_attenuation(song, preset, cv):
    """Reference-calibrated channel response, in dB attenuation.

    INTRO's held p51/p94/p102 parts jump100->119 at3.4286s. The generic
    squared response makes the dominant strings rise2.6dB and the full
    mix rise2.7dB, against1.7dB in the recording. Preserve the written
    fade below100; use half the excess dB above100 for these held parts.
    This is a recording-specific calibration, not a claimed universal
    reference-synthesizer controller law. Other songs' written swells remain intact.
    """
    db=40.0*math.log10(127.0/cv)
    if song=='D_INTRO' and preset in ((0,51),(0,94),(0,102)) and cv>100:
        # Half the excess rise left B 0.41dB under the hardware step.
        # 0.73 of that half-excess lands the mix rise on the recording.
        db += 0.73*20.0*math.log10(cv/100.0)
    return db


def cal_db(song, n):
    """The level correction of a note (CAL)."""
    if song=='D_E1M8' and n.preset==(0,52):
        return 1.0 if n.ch==1 else -2.0 if n.ch==3 else 0.0
    if song == "D_E1M5" and n.ch == 0 and n.preset == (0,48):
        return 1.0  # exposed attack after restoring its stereo/mono placement
    if n.preset[0] == 128:
        return CAL.get((None, 'kit', n.r.sample.name), 0.0) + CAL.get((song, 'kit', n.r.sample.name), 0.0)
    if song == 'D_INTRO' and n.preset[1] == 94 and 'MUSSC_HALODB' in os.environ:
        return float(os.environ['MUSSC_HALODB'])
    return CAL.get((None, n.preset[1], None), 0.0) + CAL.get((song, n.preset[1], None), 0.0)


# The reference synthesizer's pitch envelopes the SoundFont does not have: semitones a second
# a program's notes fall from their note on (E1M8's recording: its synth drum
# on C2 falls from 129 Hz to 43 Hz in 0.48 s, on C5 from 330 Hz to 107 Hz in
# 0.52 s; the SoundFont holds 123 and 348 Hz: steady notes are heard
# where the reference synthesizer bends)
SWEEP = {118: 39.0}
# ... and decays the SoundFont makes faster: a program's decay and release
# times x this (E1M8's synth drum: 40 dB a second on the reference synthesizer, 100 in the
# SoundFont)
SLOW = {118: 2.5}
SWEEP_STEP = float(os.environ.get('MUSSC_SWSTEP', 0.5))  # semitones between the pitches it writes
                          #   (0.5: E1M8 about 34 wakes a second; 1.0: 32.5; none: 24.2)
SWEEP_MAX = 36.0          # semitones it falls at most


def sweep(n, rate):
    """The pitch of a note of a program with a falling pitch envelope: its
    bends, and rate semitones a second down from its note on, in SWEEP_STEP
    steps, SWEEP_MAX at most."""
    out = []
    last = None
    bi = 0
    for t in range(n.on, max(n.on, n.stop) + 1):
        while bi + 1 < len(n.bends) and n.bends[bi + 1][0] <= t:
            bi += 1
        d = min(SWEEP_MAX, rate * (t - n.on) / 140.0)
        f = n.sp * 2.0 ** ((n.bends[bi][1] - SWEEP_STEP * round(d / SWEEP_STEP)) / 12.0)
        if f != last:
            out.append((t, f))
            last = f
    return out


def motion_pitch(n, twolevel=False, stride=1, quantum=None):
    """MIDI bends plus each layer's pitch envelope and both SF2 LFOs.
    One DOC oscillator represents a layered part: use its instantaneous
    power-weighted pitch. This retains common motion but cannot reproduce
    independent chorus partials; native source loops retain their beating.
    The existing measured p118 sweep takes precedence over its SF2 LFO.
    """
    out = []
    bi = mi = 0
    last = None
    twolevel = os.environ.get('MUSSC_LFOSHAPE', 'twolevel' if twolevel else 'triangle') == 'twolevel'
    def pmod(L, secs):
        value = sf2.pitch_at(L, secs, (n.off-n.on)*TIC)
        if twolevel:
            for depth, delay, freq in [(L.vib_to_pitch,L.vib_delay,L.vib_freq),
                                        (L.mod_lfo_pitch,L.mod_delay,L.mod_freq)]:
                old = sf2.lfo_at(secs,delay,freq)
                # Five-level triangle, not two amplitudes. Still updated
                # only when the quantized value changes.
                new = max(-1.0, min(1.0, round(old * 2.0) / 2.0)) if secs >= delay else 0.0
                value += depth * (new-old)
        return value
    for t in range(n.on, max(n.on, n.stop) + 1, max(1, stride)):
        while bi + 1 < len(n.bends) and n.bends[bi + 1][0] <= t:
            bi += 1
        while mi + 1 < len(n.mods) and n.mods[mi + 1][0] <= t:
            mi += 1
        secs = (t - n.on) * TIC
        ws = [env_pow(L, max(secs, .004), n.r) for L in n.layers]
        cents = sum(w * (pmod(L, secs) - (L.mod_to_pitch * sf2.mod_env_at(L, secs)
                    if bake_pitch(L) else 0.0)) for L, w in zip(n.layers, ws)) / (sum(ws) or 1.)
        cents += VIB_CENTS * n.mods[mi][1] * math.sin(2 * math.pi * VIB_HZ * secs)
        depth = max([abs(L.vib_to_pitch) + abs(L.mod_lfo_pitch) for L in n.layers] + [VIB_CENTS * n.mods[mi][1], 1.0])
        step = min(depth, PITCH_STEP if quantum is None else quantum)
        if twolevel and quantum is None:
            step = min(2.0, depth)
        cents = step * round(cents / step)
        f = n.sp * 2.0 ** (n.bends[bi][1] / 12.0 + cents / 1200.0)
        if f != last:
            out.append((t, f))
            last = f
    return out


def vibrato(n):
    """The pitch of a note under the modulation controller: its bends and a
    vibrato of VIB_HZ, VIB_CENTS x the controller deep, in VIB_STEP cents
    steps (a pitch holds for a few tics: fewer writes and pitches)."""
    out = []
    last = None
    bi = mi = 0
    for t in range(n.on, max(n.on, n.stop) + 1):
        while bi + 1 < len(n.bends) and n.bends[bi + 1][0] <= t:
            bi += 1
        while mi + 1 < len(n.mods) and n.mods[mi + 1][0] <= t:
            mi += 1
        c = VIB_CENTS * n.mods[mi][1] * math.sin(2 * math.pi * VIB_HZ * (t - n.on) / 140.0)
        f = n.sp * 2.0 ** (n.bends[bi][1] / 12.0 + VIB_STEP * round(c / VIB_STEP) / 1200.0)
        if f != last:
            out.append((t, f))
            last = f
    return out


def main():
    args = sys.argv[1:]
    qa = {}
    if '--q' in args:
        i = args.index('--q')
        for kv in args[i + 1].split(','):
            k, v = kv.split('=')
            qa[k] = v
        del args[i:i + 2]
    units = None
    if '--units' in args:
        # each song's image also as its own file (the song unit of the level
        # loader: DIR/SONG.mus, what musLoad takes)
        i = args.index('--units')
        units = args[i + 1]
        del args[i:i + 2]
        os.makedirs(units, exist_ok=True)
    font, out = args[0], args[1]
    names = [x for a in args[2:] for x in a.split(',')]
    q = Q(**qa)
    sf = sf2.SF2(font)
    lumps = dmxmus.read_wad(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'data', 'DOOM1.WAD'))
    bank = bytearray(struct.pack('<H', len(musbank.SONGS)) + bytes(8 * len(musbank.SONGS)))
    for i, name in enumerate(musbank.SONGS):
        if name not in names:
            continue
        s = fit(name, lumps[name], sf, qa)
        img, stream, fcs = s.image()
        head = 6 + len(stream) + 2 * len(fcs) + 5 * len(s.zones)
        while MB_IMAGE + head > MUSBUF_SIZE and s.lift_db > 0.0:
            # the lift makes quiet notes audible, and each of their level
            # steps is a byte: less lift, 1.5 dB at a time, until it fits
            s.lift_cap = max(0.0, (s.lift_db - 1.5) * 32.0 / 6.02)
            s.plan()
            img, stream, fcs = s.image()
            head = 6 + len(stream) + 2 * len(fcs) + 5 * len(s.zones)
        if MB_IMAGE + head > MUSBUF_SIZE:
            raise ValueError('%s: its head (%d bytes) does not fit MUSBUF' % (name, head))
        struct.pack_into('<II', bank, 2 + 8 * i, len(bank), len(img))
        bank += img
        if units:
            open(os.path.join(units, name + '.mus'), 'wb').write(img)
        print('%-9s step %d  tables %2d  %3d pages (%d bytes)  pitches %3d  stream %6d  wakes %4.1f/s  image %6d  lift %.1f dB' % (
            name, s.step, len(s.zones), 255 - s.low, 256 * (255 - s.low), len(fcs), len(stream),
            len(s.wakes) / (s.length / 140.0), len(img), s.lift_db))
        for z, p, lp in zip(s.zones, s.pages, s.lpages):
            print('   %-22s %-7s notes %4d  bytes %5d%s  rate %6.0f  speeds %.2f-%.2f  fc %s  page %d' % (
                z.name, z.kind, len(z.notes), len(z.table), (' + loop %d' % len(z.ltable)) if z.kind == 'attack' else '',
                z.rate, z.s_min, z.s_max, ('%.0f' % z.fc_hz) if z.fc_hz else '-', p))
    open(out, 'wb').write(bank)
    print('%s: %d bytes' % (out, len(bank)))


if __name__ == '__main__':
    main()
