#!/usr/bin/env python3
"""Build the music bank: the Doom songs for the Ensoniq DOC.

Usage: musbank.py DOOM1.WAD OUT [--report] [--only D_E1M1,...]

DMX played the songs (MUS) on the 9 voices of an OPL2 with the GENMIDI
patches. This tool plays them the same way at build time (tools/dmxmus.py:
Chocolate Doom's DMX code, OPL2) and writes, for each song, the DOC
register writes that the game interrupt makes (src/iigs/irq65.s):

- OPL voice v is DOC oscillator 16 + v (on channel v & 1). Its tables are
  the voice's own sound rendered by an OPL2 model (tools/mussamp.py): a
  table for each pitch zone (at most an octave), a loop for a melodic
  voice, a one-shot or an attack and a loop for a drum. A note restarts
  its table at the start (halt, then run).
- pitch: the DOC frequency (resolution = table size: a table byte each 512
  accumulator steps), from a table of the song's pitches (at most 256).
- loudness: the OPL envelope (tools/opleg.py) with DMX's volumes and key
  scale levels, in 3 dB steps (a drum table holds its own envelope up to
  its loop). A level is an index in 1/8 octave steps into the volume table
  of the player (the music volume moves the table). A level step may wait
  TOL tics for a wake; a note under the DOC's quietest volume stops.
- time: wakes on whole MUS tics (1/140 s); each wake starts with the tics
  to the next one: the alarm (oscillator 30) is set for them. Notes,
  bends, fast releases (gate instruments) and the switch of a drum from
  its attack to its loop are exact.

Bank: u16 N, then N x (u32 offset, u32 length: 0 for a song not in it);
then the song images (the player loads one into MUSBUF of music.inc):
  u8 D table descriptors, u8 P pitches (0: 256), u16 stream length,
  u8 the lowest DOC page of the tables, u8 0, the stream,
  P pitch low bytes, P pitch high bytes,
  the descriptors: D pages, D size bytes, D modes, D loop pages, D loop
  size bytes (the DOC registers $80 + osc, $C0 + osc, the run mode of $A0 +
  osc: 0 free run, 2 one-shot; the loop of an attack table),
  the DOC RAM image of pages (lowest page) to 254 (page 255 has the timer
  ramp).
Stream: wakes; a wake is a wait (the tics to the next wake: the player
starts the alarm first), then its commands (v = voice 0-8, low 4 bits):
  0x0v         level + 4 (3 dB down)
  0x1v a       level = a
  0x2v p a     note: halt, pitch p, level a, run (the voice's table)
  0x3v d p a   note with the table of descriptor d
  0x7v p a     note with the voice's table again (after a switch to its loop)
  0xAv a       note at the voice's pitch
  0x4v p       pitch p (both bytes)
  0x5v p       pitch p (low byte: the high byte is the same)
  0x6v         halt (silence)
  0x8v         level + 8 (6 dB down: two steps in one wake)
  0x9v         level - 4 (3 dB up)
  0xBv         the loop of the voice's attack table (pointer and size)
  0xD0+n       wait n tics (1-15) at the alarm frequency of the wait before
  0xE0         the end: the next wake is the first (all voices halted)
  0xE0+n       wait n tics (1-15), the alarm frequency high byte too
  0xF0+n       wait n tics (1-15): the next wake
"""
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dmxmus
import mussamp
import opleg

DOC_RATE = 894886.0 / 34                 # 32 oscillators
TIC_SAMPLES = DOC_RATE / 140.0
TIC_MS = 1000.0 / 140
SONGS = ('D_E1M1', 'D_E1M2', 'D_E1M3', 'D_E1M4', 'D_E1M5', 'D_E1M6', 'D_E1M7',
         'D_E1M8', 'D_E1M9', 'D_INTER', 'D_INTRO', 'D_VICTOR', 'D_INTROA')
VMAX = 192                               # DOC volume of level 0 (a full-scale voice)
STEP = 16                                # 3 dB (units of 3/16 dB): a level write
TOL = 3                                  # tics a level write may wait
TOP_PAGE = 254
VOICES = dmxmus.NUM_VOICES
FAST = 4.0                               # a release this fast (units a ms) is exact


# Timing estimate used by this OPL song compiler: ceil(255*512 / FC)
# plus one final sample and an average 0.8-sample IRQ/restart allowance.
# The allowance is an emulator calibration, not a fixed DOC latency;
# alarm_samples() uses it to estimate elapsed time for encoded waits.
PASS_TAIL = 1.8


def alarm_fc(n):
    return max(1, int(round(130560.0 / (TIC_SAMPLES * n))))


def alarm_samples(n):
    return math.ceil(130560.0 / alarm_fc(n)) + PASS_TAIL


def doc_fc(hz):
    return max(1, min(65535, int(round(hz * 131072.0 / DOC_RATE))))


def vol_of(level):
    """The DOC volume of a level index (1/8 octave) at full music volume,
    as the player's table (src/iigs/s_sound65.s setVolume) makes it."""
    k = level
    if (k >> 3) >= 16:
        return 0
    m = int(round(VMAX * 256 * 2.0 ** (-(k & 7) / 8.0)))
    return ((m >> (k >> 3)) + 128) >> 8


def music_atten():
    """The attenuation (0.75 dB steps) of music volume 0-15: DMX limits
    each channel to 8 x the volume (a default channel is 100), and a note
    of velocity 127 then gets the level of that channel volume."""
    def tl(chan):
        full = (dmxmus.VOLUME_MAP[127] * 2 * (dmxmus.VOLUME_MAP[chan] + 1)) >> 9
        return 0x3f - full
    base = tl(min(100, 8 * 15))
    return [255 if v == 0 else max(0, tl(min(100, 8 * v)) - base) for v in range(16)]


class Note:
    def __init__(self, voice, tic, instr, iv, freq, car_tl, mod_tl):
        self.voice, self.on, self.off, self.end = voice, tic, None, None
        self.instr, self.iv = instr, iv
        self.freqs = [(tic, freq)]
        self.tls = [(tic, car_tl, mod_tl)]


def notes_of(actions, instrs):
    cur = [None] * VOICES
    out = []
    for a in actions:
        kind, tic, v = a[0], a[1], a[2]
        n = cur[v]
        if kind == 'on':
            if n is not None and n.end is None:
                n.end = tic
                if n.off is None:
                    n.off = tic
            n = Note(v, tic, instrs[a[3]], a[4], a[5], a[6], a[7])
            cur[v] = n
            out.append(n)
        elif n is None:
            continue
        elif kind == 'off' and n.off is None:
            n.off = tic
        elif kind == 'tl':
            n.tls.append((tic, a[3], a[4]))
        elif kind == 'freq':
            n.freqs.append((tic, a[3]))
    return out


def audible(note):
    """False for a voice with no attack on its carrier (silent: the second
    voice of the Electric Snare)."""
    return (note.instr.voice(note.iv)[8] >> 4) != 0


def db_sum(a, b):
    s = 2.0 ** (-a / 16.0) + 2.0 ** (-b / 16.0)
    return -16.0 * math.log2(s) if s > 0 else opleg.SILENT


class Levels:
    """The OPL level (units) of a note at ms after its key on."""

    def __init__(self, note, cache):
        self.n = note
        instr, iv = note.instr, note.iv
        self.additive = (instr.feedback(iv) & 1) == 1
        ksv = opleg.ksv_of(note.freqs[0][1])
        self.car = cache.get(instr, iv, 1, ksv)
        self.mod = cache.get(instr, iv, 0, ksv) if self.additive else None
        self.off_ms = (note.off - note.on) * TIC_MS if note.off is not None else None

    @staticmethod
    def _at(lst, tic):
        v = lst[0]
        for x in lst:
            if x[0] <= tic:
                v = x
        return v

    def env(self, e, ms):
        if self.off_ms is None or ms <= self.off_ms:
            return e.held(ms)
        return e.release(e.held(self.off_ms), ms - self.off_ms)

    def level(self, ms):
        tic = self.n.on + ms / TIC_MS
        _, car_tl, mod_tl = self._at(self.n.tls, tic)
        f = self._at(self.n.freqs, tic)[1]
        c = min(opleg.SILENT, self.env(self.car, ms) + ((car_tl & 0x3f) << 2) + opleg.ksl_units(f, car_tl))
        if not self.additive:
            return c
        m = min(opleg.SILENT, self.env(self.mod, ms) + ((mod_tl & 0x3f) << 2) + opleg.ksl_units(f, mod_tl))
        return db_sum(c, m)

    def freq_at(self, tic):
        return self._at(self.n.freqs, tic)[1]


    def base(self, ms):
        """The carrier's level without its envelope (total level and key
        scale level): a drum table holds its own envelope."""
        tic = self.n.on + ms / TIC_MS
        _, car_tl, mod_tl = self._at(self.n.tls, tic)
        f = self._at(self.n.freqs, tic)[1]
        return ((car_tl & 0x3f) << 2) + opleg.ksl_units(f, car_tl)


def level_index(u):
    """The level index (1/8 octave) of u units, in STEP steps; None: too
    quiet for the DOC."""
    idx = max(0, int(u // STEP) * STEP // 4 + STEP // 8)
    return idx if idx <= 127 and vol_of(idx) > 0 else None


def median_held(ns):
    ds = sorted(((n.off if n.off is not None else (n.end or n.on + 14)) - n.on) for n in ns)
    return max(1, ds[len(ds) // 2]) / 140.0


class Song:
    def __init__(self, name, lump, instrs, cache, tol=TOL):
        self.name = name
        groups, self.length = dmxmus.parse_mus(lump)
        d = dmxmus.play(groups, instrs)
        self.notes = [n for n in notes_of(d.out, instrs) if audible(n)]
        self.cache = cache
        self.tables()
        self.layout()
        self.plan(tol)

    def tables(self):
        """The zones of each sound (the same 16 bytes of GENMIDI voice
        share their tables: the toms, the two crash cymbals)."""
        groups = {}
        for n in self.notes:
            groups.setdefault(bytes(n.instr.voice(n.iv)[:13]), []).append(n)
        self.zones = []
        self.zone_of = {}
        for key in sorted(groups, key=lambda k: min((n.instr.index, n.iv) for n in groups[k])):
            ns = groups[key]
            first = min(ns, key=lambda n: (n.instr.index, n.iv))
            data = first.instr.voice(first.iv)
            name = '%d.%d %s' % (first.instr.index, first.iv, first.instr.name)
            freqs = [f for n in ns for _, f in n.freqs]
            zs = mussamp.zones_for(data, freqs, name)
            for z in zs:
                if first.instr.index >= 128:
                    mussamp.build_drum(z, median_held(ns))
                else:
                    mussamp.build_melodic(z)
            for n in ns:
                f = mussamp.opl_hz(n.freqs[0][1])
                k = min(range(len(zs)), key=lambda i: 0 if mussamp.opl_hz(zs[i].freqs[0]) <= f <= mussamp.opl_hz(zs[i].freqs[-1])
                        else abs(math.log(f * zs[i].ratio / zs[i].f_top)))
                self.zone_of[id(n)] = len(self.zones) + k
            self.zones += zs
        if len(self.zones) > 64:
            raise ValueError('%s: %d tables' % (self.name, len(self.zones)))

    def layout(self):
        """DOC pages for the tables: from 254 down, the biggest first, each
        at a multiple of its size; a table holds only the pages of its bytes
        (a one-shot ends at its 0 byte), so a smaller table can take the rest
        of its block."""
        used = set()
        self.pages = [None] * len(self.zones)
        for i in sorted(range(len(self.zones)), key=lambda i: -self.zones[i].size):
            n = self.zones[i].size // 256
            k = (len(self.zones[i].table) + 255) // 256       # the pages it fills
            p = (255 - n) // n * n
            while p >= 0 and any(q in used or q > 254 for q in range(p, p + k)):
                p -= n
            if p < 0:
                raise ValueError('%s: the tables do not fit DOC RAM' % self.name)
            self.pages[i] = p
            used.update(range(p, p + k))
        self.low = min(used) if used else 255

    def fc_of(self, note, freq):
        return self.zones[self.zone_of[id(note)]].fc(freq)

    def plan(self, tol):
        """self.wakes: {tic: [(kind, voice, value)]}, kinds 'on' (note,
        level index, fc), 'lev' (level index), 'fc', 'off', 'sw' (the loop
        of an attack table)."""
        tracks, exact = self.tracks()
        schedule(self, tracks, exact, tol)

    def tracks(self):
        """For each voice its notes: (on, end, note, levels, q), q the level
        index of each tic from on to end (None: silent, 'done': a one-shot
        that ended); and the tics that must be exact. A one-shot has one
        level until its sample ends; an attack table one level until its
        switch (an exact tic), then the envelope from the level where the
        attack ended."""
        length = self.length
        exact = set()
        tracks = [[] for _ in range(VOICES)]
        self.switch_at = {}
        for n in self.notes:
            z = self.zones[self.zone_of[id(n)]]
            lv = Levels(n, self.cache)
            end = n.end if n.end is not None else length
            exact.add(n.on)
            for t, _ in n.freqs[1:]:
                exact.add(t)
            r = z.ratio_of(n.freqs[0][1])
            q = []
            if z.kind == 'oneshot':
                dur = int(math.ceil(z.dur / r * 140))
                for t in range(n.on, end + 1):
                    if t - n.on >= dur:
                        q.append('done')
                    else:
                        q.append(level_index(lv.base((t - n.on) * TIC_MS) + z.gain))
            elif z.kind == 'attack':
                sw = int(math.ceil(z.attack / r * 140))
                self.switch_at[id(n)] = n.on + sw
                if n.on + sw <= end:
                    exact.add(n.on + sw)
                for t in range(n.on, end + 1):
                    ms = (t - n.on) * TIC_MS
                    u = lv.base(ms) + z.gain
                    if t - n.on >= sw:
                        u += max(0.0, lv.env(lv.car, ms) - z.eg_attack)
                    q.append(level_index(u))
            else:
                if n.off is not None and n.off < end and lv.car.sr > FAST:
                    exact.add(n.off)
                for t in range(n.on, end + 1):
                    q.append(level_index(lv.level((t - n.on) * TIC_MS) + z.gain))
            tracks[n.voice].append((n.on, end, n, lv, q))
        return tracks, exact


    def encode(self):
        """(stream, pitches)."""
        fcs = []
        fci = {}

        def pidx(fc):
            if fc not in fci:
                fci[fc] = len(fcs)
                fcs.append(fc)
            return fci[fc]
        out = bytearray()
        st = [None] * VOICES             # [descriptor, fc, level, running]
        fchi = None                      # the first wait writes both bytes
        self.drift = 0.0                 # samples the alarm is behind the song
        self.wake_tics = []
        wakes = sorted(self.wakes)
        for i, t in enumerate(wakes):
            nxt = wakes[i + 1] if i + 1 < len(wakes) else self.length
            gap = max(1, nxt - t)
            m = gap
            if self.drift > TIC_SAMPLES / 2 and m > 1:
                m -= 1
            elif self.drift < -TIC_SAMPLES / 2:
                m += 1
            self.drift -= gap * TIC_SAMPLES
            waits = bytearray()
            wt = t
            while m > 0:
                n = min(m, 15)
                hi = alarm_fc(n) >> 8
                waits += bytes([(0xe0 if hi != fchi else 0xf0) | n])
                self.wake_tics.append(wt)
                wt += n
                fchi = hi
                self.drift += alarm_samples(n)
                m -= n
            out += waits[0:1]
            for kind, v, val in self.wakes[t]:
                s = st[v]
                if kind == 'on':
                    n, lev, fc = val
                    d = self.zone_of[id(n)]
                    p = pidx(fc)
                    if s is None or s[0] != d:
                        out += bytes([0x30 | v, d, p, lev])
                    elif len(s) > 4 and s[4]:
                        out += bytes([0x70 | v, p, lev])     # its table again (after a switch)
                    elif s[1] == fc:
                        out += bytes([0xa0 | v, lev])        # the same pitch
                    else:
                        out += bytes([0x20 | v, p, lev])
                    st[v] = [d, fc, lev, True, False]
                elif kind == 'sw':
                    out += bytes([0xb0 | v])
                    s[4] = True
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
            if i + 1 == len(wakes):      # the loop starts with all voices halted
                for v in range(VOICES):
                    if st[v] is not None and st[v][3]:
                        out += bytes([0x60 | v])
                        st[v][3] = False
            out += waits[1:]
        out += bytes([0xe0])
        if len(fcs) > 256:
            raise ValueError('%s: %d pitches' % (self.name, len(fcs)))
        return bytes(out), fcs


def schedule(self, tracks, exact, tol):
    """The wakes of the tracks: at each exact tic, and at a level change
    (it may wait tol tics for another wake)."""
    if True:
        length = self.length
        self.wakes = {}
        cur = [None] * VOICES
        pos = [0] * VOICES
        wr = [None] * VOICES             # [note, level, fc, running, switched]
        ex = sorted(exact)
        ei = 0
        t = 0
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
                on, end, n, lv, q = c
                ql = q[t - on] if t <= end else None
                w = wr[v]
                fc = self.fc_of(n, lv.freq_at(t))
                if ql == 'done':                 # the one-shot halted itself
                    if w is not None and w[0] is n:
                        w[1] = None
                        w[3] = False
                    continue
                if w is None or w[0] is not n:
                    if ql is not None:
                        writes.append(('on', v, (n, ql, fc)))
                        wr[v] = [n, ql, fc, True, False]
                    else:
                        if w is not None and w[3]:
                            writes.append(('off', v, None))
                        wr[v] = [n, None, fc, False, False]
                    continue
                if not w[3]:
                    continue
                sw = self.switch_at.get(id(n))
                if sw is not None and not w[4] and t >= sw:
                    writes.append(('sw', v, None))
                    w[4] = True
                if ql is None:
                    writes.append(('off', v, None))
                    w[1] = None
                    w[3] = False
                    continue
                if fc != w[2]:
                    writes.append(('fc', v, fc))
                    w[2] = fc
                if vol_of(ql) != vol_of(w[1]):
                    writes.append(('lev', v, ql))
                    w[1] = ql
            if writes or t == 0:
                self.wakes[t] = writes
            if t >= length:
                break
            while ei < len(ex) and ex[ei] <= t:
                ei += 1
            nxt = ex[ei] if ei < len(ex) else length
            due = None
            for v in range(VOICES):
                c, w = cur[v], wr[v]
                if c is None or w is None or w[0] is not c[2] or not w[3]:
                    continue
                on, end, n, lv, q = c
                for tt in range(t + 1, min(end, nxt) + 1):
                    ql = q[tt - on]
                    if ql == 'done':
                        break
                    if (ql is None) != (w[1] is None) or (ql is not None and vol_of(ql) != vol_of(w[1])):
                        due = tt if due is None else min(due, tt)
                        break
            cand = nxt
            if due is not None:
                cand = min(cand, due + tol)
            t = max(min(cand, length), t + 1)


def size_code(size):
    """The DOC size and resolution byte of a table: size k and resolution
    k (a table byte each 512 accumulator steps at any size)."""
    k = int(math.log2(size // 256))
    return (k << 3) | k


def song_image(song):
    """The song image (the bank format above)."""
    stream, fcs = song.encode()
    D = len(song.zones)
    img = bytearray(struct.pack('<BBHBB', D, len(fcs) & 255, len(stream), song.low, 0))
    img += stream
    img += bytes(fc & 255 for fc in fcs)
    img += bytes(fc >> 8 for fc in fcs)
    img += bytes(song.pages)
    img += bytes(size_code(z.size) for z in song.zones)
    img += bytes(2 if z.kind == 'oneshot' else 0 for z in song.zones)
    img += bytes((p + (z.size - z.loop_len) // 256) if z.kind == 'attack' else p for z, p in zip(song.zones, song.pages))
    img += bytes(size_code(z.loop_len) if z.kind == 'attack' else size_code(z.size) for z in song.zones)
    doc = bytearray(b'\x80' * (256 * (255 - song.low)))
    for z, p in zip(song.zones, song.pages):
        o = 256 * (p - song.low)
        doc[o:o + len(z.table)] = z.table
    img += doc
    return bytes(img), stream, fcs


def main():
    args = sys.argv[1:]
    wad, out = args[0], args[1]
    report = '--report' in args
    only = args[args.index('--only') + 1].split(',') if '--only' in args else None
    wakelog = args[args.index('--wakes') + 1] if '--wakes' in args else None
    lumps = dmxmus.read_wad(wad)
    instrs = dmxmus.genmidi(lumps['GENMIDI'])
    cache = opleg.Cache()
    bank = bytearray(struct.pack('<H', len(SONGS)) + bytes(8 * len(SONGS)))
    for i, name in enumerate(SONGS):
        if only and name not in only:
            continue
        s = Song(name, lumps[name], instrs, cache)
        img, stream, fcs = song_image(s)
        head = len(img) - 256 * (255 - s.low)
        if 0x500 + head > 0xae00:           # MB_IMAGE to MB_PLANS of music.inc:
            print('%s left out: its head (%d bytes) does not fit MUSBUF' % (name, head))
            continue                        #   the map has no music
        if wakelog:
            open('%s.%s' % (wakelog, name), 'w').write(''.join('%d\n' % t for t in s.wake_tics))
        struct.pack_into('<II', bank, 2 + 8 * i, len(bank), len(img))
        bank += img
        if report:
            secs = s.length / 140.0
            print('%-9s %5.1f s  tables %2d (%3d pages from %d)  pitches %3d  stream %6d (%3.0f/s)  wakes %4.1f/s  image %6d' % (
                name, secs, len(s.zones), 255 - s.low, s.low, len(fcs), len(stream), len(stream) / secs,
                len(s.wakes) / secs, len(img)))
    open(out, 'wb').write(bank)
    print('%s: %d bytes' % (out, len(bank)))


if __name__ == '__main__':
    main()
