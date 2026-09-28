#!/usr/bin/env python3
"""The Doom songs as DMX played them on an OPL2: the MUS parser, GENMIDI and
the DMX voice logic (Chocolate Doom's src/i_oplmusic.c and src/mus2mid.c,
driver version doom_1_9, OPL2: 9 voices), for tools/musbank.py.

play(mus, instrs) gives the OPL voice actions of one pass of a song, in MUS
tics (1/140 s):
  ('on',   tic, voice, instr, ivoice, freq, car_tl, mod_tl)  key on
  ('tl',   tic, voice, car_tl, mod_tl)                       a volume change
  ('freq', tic, voice, freq)                                  a pitch change
  ('off',  tic, voice)                                        key off (release)
instr is the GENMIDI record (0-174), ivoice its voice (0, or 1 for the second
voice of a double voice instrument), freq the OPL frequency word (block << 10
| fnum), car_tl and mod_tl the level registers of the carrier and the
modulator (scale bits included; mod_tl None when DMX leaves it at the patch
level).
"""
import struct

NUM_VOICES = 9                  # OPL2
FLAG_FIXED = 0x0001
FLAG_2VOICE = 0x0004

# Chocolate Doom src/i_oplmusic.c: frequency_curve and volume_mapping_table
FREQ_CURVE = (
    0x133, 0x133, 0x134, 0x134, 0x135, 0x136, 0x136, 0x137,
    0x137, 0x138, 0x138, 0x139, 0x139, 0x13a, 0x13b, 0x13b,
    0x13c, 0x13c, 0x13d, 0x13d, 0x13e, 0x13f, 0x13f, 0x140,
    0x140, 0x141, 0x142, 0x142, 0x143, 0x143, 0x144, 0x144,
    0x145, 0x146, 0x146, 0x147, 0x147, 0x148, 0x149, 0x149,
    0x14a, 0x14a, 0x14b, 0x14c, 0x14c, 0x14d, 0x14d, 0x14e,
    0x14f, 0x14f, 0x150, 0x150, 0x151, 0x152, 0x152, 0x153,
    0x153, 0x154, 0x155, 0x155, 0x156, 0x157, 0x157, 0x158,
    0x158, 0x159, 0x15a, 0x15a, 0x15b, 0x15b, 0x15c, 0x15d,
    0x15d, 0x15e, 0x15f, 0x15f, 0x160, 0x161, 0x161, 0x162,
    0x162, 0x163, 0x164, 0x164, 0x165, 0x166, 0x166, 0x167,
    0x168, 0x168, 0x169, 0x16a, 0x16a, 0x16b, 0x16c, 0x16c,
    0x16d, 0x16e, 0x16e, 0x16f, 0x170, 0x170, 0x171, 0x172,
    0x172, 0x173, 0x174, 0x174, 0x175, 0x176, 0x176, 0x177,
    0x178, 0x178, 0x179, 0x17a, 0x17a, 0x17b, 0x17c, 0x17c,
    0x17d, 0x17e, 0x17e, 0x17f, 0x180, 0x181, 0x181, 0x182,
    0x183, 0x183, 0x184, 0x185, 0x185, 0x186, 0x187, 0x188,
    0x188, 0x189, 0x18a, 0x18a, 0x18b, 0x18c, 0x18d, 0x18d,
    0x18e, 0x18f, 0x18f, 0x190, 0x191, 0x192, 0x192, 0x193,
    0x194, 0x194, 0x195, 0x196, 0x197, 0x197, 0x198, 0x199,
    0x19a, 0x19a, 0x19b, 0x19c, 0x19d, 0x19d, 0x19e, 0x19f,
    0x1a0, 0x1a0, 0x1a1, 0x1a2, 0x1a3, 0x1a3, 0x1a4, 0x1a5,
    0x1a6, 0x1a6, 0x1a7, 0x1a8, 0x1a9, 0x1a9, 0x1aa, 0x1ab,
    0x1ac, 0x1ad, 0x1ad, 0x1ae, 0x1af, 0x1b0, 0x1b0, 0x1b1,
    0x1b2, 0x1b3, 0x1b4, 0x1b4, 0x1b5, 0x1b6, 0x1b7, 0x1b8,
    0x1b8, 0x1b9, 0x1ba, 0x1bb, 0x1bc, 0x1bc, 0x1bd, 0x1be,
    0x1bf, 0x1c0, 0x1c0, 0x1c1, 0x1c2, 0x1c3, 0x1c4, 0x1c4,
    0x1c5, 0x1c6, 0x1c7, 0x1c8, 0x1c9, 0x1c9, 0x1ca, 0x1cb,
    0x1cc, 0x1cd, 0x1ce, 0x1ce, 0x1cf, 0x1d0, 0x1d1, 0x1d2,
    0x1d3, 0x1d3, 0x1d4, 0x1d5, 0x1d6, 0x1d7, 0x1d8, 0x1d8,
    0x1d9, 0x1da, 0x1db, 0x1dc, 0x1dd, 0x1de, 0x1de, 0x1df,
    0x1e0, 0x1e1, 0x1e2, 0x1e3, 0x1e4, 0x1e5, 0x1e5, 0x1e6,
    0x1e7, 0x1e8, 0x1e9, 0x1ea, 0x1eb, 0x1ec, 0x1ed, 0x1ed,
    0x1ee, 0x1ef, 0x1f0, 0x1f1, 0x1f2, 0x1f3, 0x1f4, 0x1f5,
    0x1f6, 0x1f6, 0x1f7, 0x1f8, 0x1f9, 0x1fa, 0x1fb, 0x1fc,
    0x1fd, 0x1fe, 0x1ff, 0x200, 0x201, 0x201, 0x202, 0x203,
    0x204, 0x205, 0x206, 0x207, 0x208, 0x209, 0x20a, 0x20b,
    0x20c, 0x20d, 0x20e, 0x20f, 0x210, 0x210, 0x211, 0x212,
    0x213, 0x214, 0x215, 0x216, 0x217, 0x218, 0x219, 0x21a,
    0x21b, 0x21c, 0x21d, 0x21e, 0x21f, 0x220, 0x221, 0x222,
    0x223, 0x224, 0x225, 0x226, 0x227, 0x228, 0x229, 0x22a,
    0x22b, 0x22c, 0x22d, 0x22e, 0x22f, 0x230, 0x231, 0x232,
    0x233, 0x234, 0x235, 0x236, 0x237, 0x238, 0x239, 0x23a,
    0x23b, 0x23c, 0x23d, 0x23e, 0x23f, 0x240, 0x241, 0x242,
    0x244, 0x245, 0x246, 0x247, 0x248, 0x249, 0x24a, 0x24b,
    0x24c, 0x24d, 0x24e, 0x24f, 0x250, 0x251, 0x252, 0x253,
    0x254, 0x256, 0x257, 0x258, 0x259, 0x25a, 0x25b, 0x25c,
    0x25d, 0x25e, 0x25f, 0x260, 0x262, 0x263, 0x264, 0x265,
    0x266, 0x267, 0x268, 0x269, 0x26a, 0x26c, 0x26d, 0x26e,
    0x26f, 0x270, 0x271, 0x272, 0x273, 0x275, 0x276, 0x277,
    0x278, 0x279, 0x27a, 0x27b, 0x27d, 0x27e, 0x27f, 0x280,
    0x281, 0x282, 0x284, 0x285, 0x286, 0x287, 0x288, 0x289,
    0x28b, 0x28c, 0x28d, 0x28e, 0x28f, 0x290, 0x292, 0x293,
    0x294, 0x295, 0x296, 0x298, 0x299, 0x29a, 0x29b, 0x29c,
    0x29e, 0x29f, 0x2a0, 0x2a1, 0x2a2, 0x2a4, 0x2a5, 0x2a6,
    0x2a7, 0x2a9, 0x2aa, 0x2ab, 0x2ac, 0x2ae, 0x2af, 0x2b0,
    0x2b1, 0x2b2, 0x2b4, 0x2b5, 0x2b6, 0x2b7, 0x2b9, 0x2ba,
    0x2bb, 0x2bd, 0x2be, 0x2bf, 0x2c0, 0x2c2, 0x2c3, 0x2c4,
    0x2c5, 0x2c7, 0x2c8, 0x2c9, 0x2cb, 0x2cc, 0x2cd, 0x2ce,
    0x2d0, 0x2d1, 0x2d2, 0x2d4, 0x2d5, 0x2d6, 0x2d8, 0x2d9,
    0x2da, 0x2dc, 0x2dd, 0x2de, 0x2e0, 0x2e1, 0x2e2, 0x2e4,
    0x2e5, 0x2e6, 0x2e8, 0x2e9, 0x2ea, 0x2ec, 0x2ed, 0x2ee,
    0x2f0, 0x2f1, 0x2f2, 0x2f4, 0x2f5, 0x2f6, 0x2f8, 0x2f9,
    0x2fb, 0x2fc, 0x2fd, 0x2ff, 0x300, 0x302, 0x303, 0x304,
    0x306, 0x307, 0x309, 0x30a, 0x30b, 0x30d, 0x30e, 0x310,
    0x311, 0x312, 0x314, 0x315, 0x317, 0x318, 0x31a, 0x31b,
    0x31c, 0x31e, 0x31f, 0x321, 0x322, 0x324, 0x325, 0x327,
    0x328, 0x329, 0x32b, 0x32c, 0x32e, 0x32f, 0x331, 0x332,
    0x334, 0x335, 0x337, 0x338, 0x33a, 0x33b, 0x33d, 0x33e,
    0x340, 0x341, 0x343, 0x344, 0x346, 0x347, 0x349, 0x34a,
    0x34c, 0x34d, 0x34f, 0x350, 0x352, 0x353, 0x355, 0x357,
    0x358, 0x35a, 0x35b, 0x35d, 0x35e, 0x360, 0x361, 0x363,
    0x365, 0x366, 0x368, 0x369, 0x36b, 0x36c, 0x36e, 0x370,
    0x371, 0x373, 0x374, 0x376, 0x378, 0x379, 0x37b, 0x37c,
    0x37e, 0x380, 0x381, 0x383, 0x384, 0x386, 0x388, 0x389,
    0x38b, 0x38d, 0x38e, 0x390, 0x392, 0x393, 0x395, 0x397,
    0x398, 0x39a, 0x39c, 0x39d, 0x39f, 0x3a1, 0x3a2, 0x3a4,
    0x3a6, 0x3a7, 0x3a9, 0x3ab, 0x3ac, 0x3ae, 0x3b0, 0x3b1,
    0x3b3, 0x3b5, 0x3b7, 0x3b8, 0x3ba, 0x3bc, 0x3bd, 0x3bf,
    0x3c1, 0x3c3, 0x3c4, 0x3c6, 0x3c8, 0x3ca, 0x3cb, 0x3cd,
    0x3cf, 0x3d1, 0x3d2, 0x3d4, 0x3d6, 0x3d8, 0x3da, 0x3db,
    0x3dd, 0x3df, 0x3e1, 0x3e3, 0x3e4, 0x3e6, 0x3e8, 0x3ea,
    0x3ec, 0x3ed, 0x3ef, 0x3f1, 0x3f3, 0x3f5, 0x3f6, 0x3f8,
    0x3fa, 0x3fc, 0x3fe, 0x36c,
)

VOLUME_MAP = (
    0, 1, 3, 5, 6, 8, 10, 11, 13, 14, 16, 17, 19, 20, 22, 23,
    25, 26, 27, 29, 30, 32, 33, 34, 36, 37, 39, 41, 43, 45, 47, 49,
    50, 52, 54, 55, 57, 59, 60, 61, 63, 64, 66, 67, 68, 69, 71, 72,
    73, 74, 75, 76, 77, 79, 80, 81, 82, 83, 84, 84, 85, 86, 87, 88,
    89, 90, 91, 92, 92, 93, 94, 95, 96, 96, 97, 98, 99, 99, 100, 101,
    101, 102, 103, 103, 104, 105, 105, 106, 107, 107, 108, 109, 109, 110, 110, 111,
    112, 112, 113, 113, 114, 114, 115, 115, 116, 117, 117, 118, 118, 119, 119, 120,
    120, 121, 121, 122, 122, 123, 123, 123, 124, 124, 125, 125, 126, 126, 127, 127,
)

# mus2mid.c: MUS controllers 0-14 to MIDI
CONTROLLER_MAP = (0x00, 0x20, 0x01, 0x07, 0x0A, 0x0B, 0x5B, 0x5D, 0x40, 0x43,
                  0x78, 0x7B, 0x7E, 0x7F, 0x79)


def read_wad(path):
    """The lumps of a WAD by name (the first of each name)."""
    d = open(path, 'rb').read()
    _ident, n, off = struct.unpack_from('<4sii', d, 0)
    lumps = {}
    for i in range(n):
        fp, sz, nm = struct.unpack_from('<ii8s', d, off + 16 * i)
        lumps.setdefault(nm.rstrip(b'\0').decode('ascii').upper(), d[fp:fp + sz])
    return lumps


class Instr:
    """A GENMIDI record: flags, fine tuning, fixed note, and two voices of
    16 bytes (modulator 6, feedback, carrier 6, unused, base note offset)."""

    def __init__(self, index, rec, name):
        self.index = index
        self.flags, self.fine, self.fixed = struct.unpack_from('<HBB', rec, 0)
        self.voices = [rec[4 + 16 * v:20 + 16 * v] for v in range(2)]
        self.base = [struct.unpack_from('<h', rec, 18 + 16 * v)[0] for v in range(2)]
        self.name = name

    def voice(self, v):
        """The 16 bytes of voice v (oplsynth.Channel)."""
        return self.voices[v]

    def feedback(self, v):
        return self.voices[v][6]

    def mod_level(self, v):
        return self.voices[v][5] & 0x3f

    def mod_scale(self, v):
        return self.voices[v][4] & 0xc0

    def car_scale(self, v):
        return self.voices[v][11] & 0xc0


def genmidi(lump):
    assert lump[:8] == b'#OPL_II#', 'not a GENMIDI lump'
    names = lump[8 + 175 * 36:]
    return [Instr(i, lump[8 + 36 * i:8 + 36 * (i + 1)],
                  names[32 * i:32 * (i + 1)].split(b'\0')[0].decode('ascii', 'replace'))
            for i in range(175)]


def parse_mus(b):
    """The events of a MUS lump in the MIDI terms of mus2mid.c, grouped by
    tic: [(tic, [(kind, midi_channel, a, b), ...]), ...], and the length in
    tics. kind: 'off' (key), 'on' (key, velocity), 'bend' (the MIDI MSB),
    'ctl' (controller, value), 'prog' (patch)."""
    assert b[:4] == b'MUS\x1a', 'not a MUS lump'
    _slen, start = struct.unpack_from('<HH', b, 4)
    pos = start
    tic = 0
    velocity = [127] * 16
    channel_map = [-1] * 16
    groups = []
    cur = []
    end = False
    while not end:
        while True:
            desc = b[pos]
            pos += 1
            mch = desc & 15
            ev = desc & 0x70
            if mch == 15:
                ch = 9
            else:
                if channel_map[mch] < 0:
                    m = max(channel_map)
                    m += 1
                    if m == 9:
                        m += 1
                    channel_map[mch] = m
                    cur.append(('ctl', m, 0x7b, 0))     # all notes off at first use
                ch = channel_map[mch]
            if ev == 0x00:
                cur.append(('off', ch, b[pos] & 0x7f, 0))
                pos += 1
            elif ev == 0x10:
                key = b[pos]
                pos += 1
                if key & 0x80:
                    velocity[ch] = b[pos] & 0x7f
                    pos += 1
                cur.append(('on', ch, key & 0x7f, velocity[ch]))
            elif ev == 0x20:
                cur.append(('bend', ch, (b[pos] * 64) >> 7, 0))
                pos += 1
            elif ev == 0x30:
                c = b[pos]
                pos += 1
                assert 10 <= c <= 14, 'bad MUS system event'
                cur.append(('ctl', ch, CONTROLLER_MAP[c], 0))
            elif ev == 0x40:
                c, v = b[pos], b[pos + 1]
                pos += 2
                if v & 0x80:
                    v = 0x7f
                if c == 0:
                    cur.append(('prog', ch, v & 0x7f, 0))
                else:
                    assert 1 <= c <= 9, 'bad MUS controller'
                    cur.append(('ctl', ch, CONTROLLER_MAP[c], v))
            elif ev == 0x60:
                end = True
                break
            else:
                raise ValueError('bad MUS event %02x' % desc)
            if desc & 0x80:
                break
        if cur:
            groups.append((tic, cur))
            cur = []
        if end:
            break
        d = 0
        while True:
            x = b[pos]
            pos += 1
            d = d * 128 + (x & 0x7f)
            if not x & 0x80:
                break
        tic += d
    return groups, tic


class Voice:
    def __init__(self, index):
        self.index = index
        self.channel = None
        self.key = 0
        self.note = 0
        self.note_volume = 0
        self.instr = None
        self.ivoice = 0
        self.freq = 0
        self.car_volume = 0
        self.mod_volume = 0


class Channel:
    def __init__(self, index):
        self.index = index


class Dmx:
    """DMX of Doom 1.9 on an OPL2 (Chocolate Doom, opl_doom_1_9)."""

    def __init__(self, instrs, music_volume=127):
        self.instrs = instrs
        self.voices = [Voice(i) for i in range(NUM_VOICES)]
        self.free = list(self.voices)
        self.alloced = []
        self.channels = [Channel(i) for i in range(16)]
        self.current_music_volume = music_volume
        self.start_music_volume = music_volume
        self.out = []
        self.tic = 0
        for c in self.channels:
            self.init_channel(c)

    def init_channel(self, c):
        c.instrument = self.instrs[0]
        c.volume_base = 100
        c.volume = min(self.current_music_volume, 100)
        c.pan = 0x30
        c.bend = 0

    def restart(self):
        """RestartSong: the channels again, the voices as they are."""
        self.start_music_volume = self.current_music_volume
        for c in self.channels:
            self.init_channel(c)

    def get_free_voice(self):
        if not self.free:
            return None
        v = self.free.pop(0)
        self.alloced.append(v)
        return v

    def voice_key_off(self, v):
        self.out.append(('off', self.tic, v.index))

    def release_voice(self, i):
        v = self.alloced[i]
        self.voice_key_off(v)
        v.channel = None
        v.note = 0
        del self.alloced[i]
        self.free.append(v)

    def set_voice_instrument(self, v, instr, ivoice):
        if v.instr is instr and v.ivoice == ivoice:
            return False
        v.instr = instr
        v.ivoice = ivoice
        modulating = (instr.feedback(ivoice) & 1) == 0
        v.car_volume = 0x3f | instr.car_scale(ivoice)
        if modulating:
            v.mod_volume = instr.mod_level(ivoice) | instr.mod_scale(ivoice)
        else:
            v.mod_volume = 0x3f | instr.mod_scale(ivoice)
        return True

    def set_voice_volume(self, v, volume, emit=True):
        v.note_volume = volume
        instr, iv = v.instr, v.ivoice
        midi_volume = 2 * (VOLUME_MAP[v.channel.volume] + 1)
        full_volume = (VOLUME_MAP[v.note_volume] * midi_volume) >> 9
        car_volume = 0x3f - full_volume
        if car_volume != (v.car_volume & 0x3f):
            v.car_volume = car_volume | (v.car_volume & 0xc0)
            if (instr.feedback(iv) & 1) and instr.mod_level(iv) != 0x3f:
                mod_volume = instr.mod_level(iv)
                if mod_volume < car_volume:
                    mod_volume = car_volume
                mod_volume |= v.mod_volume & 0xc0
                if mod_volume != v.mod_volume:
                    v.mod_volume = mod_volume
            if emit:
                self.out.append(('tl', self.tic, v.index, v.car_volume, v.mod_volume))

    def frequency_for_voice(self, v):
        instr = v.instr
        note = v.note
        if not instr.flags & FLAG_FIXED:
            note += instr.base[v.ivoice]
        while note < 0:
            note += 12
        while note > 95:
            note -= 12
        fi = 64 + 32 * note + v.channel.bend
        if v.ivoice != 0:
            fi += (instr.fine // 2) - 64
        if fi < 0:
            fi = 0
        if fi < 284:
            return FREQ_CURVE[fi]
        sub = (fi - 284) % (12 * 32)
        octave = (fi - 284) // (12 * 32)
        if octave >= 7:
            octave = 7
        return FREQ_CURVE[sub + 284] | (octave << 10)

    def update_voice_frequency(self, v, keyon=False):
        freq = self.frequency_for_voice(v)
        if v.freq != freq:
            v.freq = freq
            if not keyon:
                self.out.append(('freq', self.tic, v.index, freq))

    def voice_key_on(self, ch, instr, ivoice, note, key, volume):
        v = self.get_free_voice()
        if v is None:
            return
        v.channel = ch
        v.key = key
        v.note = instr.fixed if instr.flags & FLAG_FIXED else note
        self.set_voice_instrument(v, instr, ivoice)
        self.set_voice_volume(v, volume, emit=False)
        v.freq = 0
        self.update_voice_frequency(v, keyon=True)
        self.out.append(('on', self.tic, v.index, instr.index, ivoice, v.freq,
                         v.car_volume, v.mod_volume))

    def channel_for(self, midi_ch):
        if midi_ch == 9:
            return self.channels[15]
        if midi_ch == 15:
            return self.channels[9]
        return self.channels[midi_ch]

    def key_off_event(self, midi_ch, key):
        ch = self.channel_for(midi_ch)
        i = 0
        while i < len(self.alloced):
            v = self.alloced[i]
            if v.channel is ch and v.key == key:
                self.release_voice(i)
            else:
                i += 1

    def replace_existing_voice(self):
        result = 0
        for i, v in enumerate(self.alloced):
            if v.ivoice != 0 or v.channel.index >= self.alloced[result].channel.index:
                result = i
        self.release_voice(result)

    def key_on_event(self, midi_ch, key, volume):
        if volume <= 0:
            self.key_off_event(midi_ch, key)
            return
        ch = self.channel_for(midi_ch)
        note = key
        if midi_ch == 9:
            if key < 35 or key > 81:
                return
            instr = self.instrs[128 + key - 35]
            note = 60
        else:
            instr = ch.instrument
        double = (instr.flags & FLAG_2VOICE) != 0
        if not self.free:
            self.replace_existing_voice()
        self.voice_key_on(ch, instr, 0, note, key, volume)
        if double:
            self.voice_key_on(ch, instr, 1, note, key, volume)

    def set_channel_volume(self, ch, volume, clip_start):
        ch.volume_base = volume
        if volume > self.current_music_volume:
            volume = self.current_music_volume
        if clip_start and volume > self.start_music_volume:
            volume = self.start_music_volume
        ch.volume = volume
        for v in self.voices:
            if v.channel is ch:
                self.set_voice_volume(v, v.note_volume)

    def all_notes_off(self, ch):
        i = 0
        while i < len(self.alloced):
            if self.alloced[i].channel is ch:
                self.release_voice(i)
            else:
                i += 1

    def pitch_bend_event(self, midi_ch, msb):
        ch = self.channel_for(midi_ch)
        ch.bend = msb - 64
        updated, not_updated = [], []
        for v in self.alloced:
            if v.channel is ch:
                self.update_voice_frequency(v)
                updated.append(v)
            else:
                not_updated.append(v)
        self.alloced = not_updated + updated

    def event(self, ev):
        kind, midi_ch, a, b = ev
        if kind == 'off':
            self.key_off_event(midi_ch, a)
        elif kind == 'on':
            self.key_on_event(midi_ch, a, b)
        elif kind == 'prog':
            self.channel_for(midi_ch).instrument = self.instrs[a]
        elif kind == 'bend':
            self.pitch_bend_event(midi_ch, a)
        elif kind == 'ctl':
            ch = self.channel_for(midi_ch)
            if a == 0x07:
                self.set_channel_volume(ch, b, True)
            elif a == 0x7b:
                self.all_notes_off(ch)
            # pan: OPL2 has none; the other controllers: DMX ignores them


def play(groups, instrs, dmx=None, t0=0):
    """The OPL voice actions of one pass (dmx: a Dmx to continue, for the
    second pass of a loop)."""
    if dmx is None:
        dmx = Dmx(instrs)
    else:
        dmx.restart()
        dmx.out = []
    for tic, evs in groups:
        dmx.tic = t0 + tic
        for ev in evs:
            dmx.event(ev)
    return dmx


def opl_hz(freq):
    """The frequency in Hz of an OPL frequency word (block << 10 | fnum)."""
    fnum, block = freq & 0x3ff, (freq >> 10) & 7
    return fnum * 49716.0 / (1 << (20 - block))


if __name__ == '__main__':
    import sys
    lumps = read_wad(sys.argv[1])
    instrs = genmidi(lumps['GENMIDI'])
    for name in sorted(n for n in lumps if n.startswith('D_')):
        groups, length = parse_mus(lumps[name])
        d = play(groups, instrs)
        kinds = {}
        for a in d.out:
            kinds[a[0]] = kinds.get(a[0], 0) + 1
        used = sorted({a[3] for a in d.out if a[0] == 'on'})
        print('%-9s %6.1f s  %s  instruments %d' % (name, length / 140.0, kinds, len(used)))
