#!/usr/bin/env python3
"""Raise every song to the loudest level register 192 can play.

The ROM 03 startup chime peaks at -13.1 dBFS with the master nibble at 5.
This game's music peaks about 16 dB under that. The loudest sample of each
song is already full scale, and its DOC register sits well below 192, so
the product sample * register is what is quiet. A normal board hears that
product. A board with the WVREF diode (1N914 into 1 kOhm, a 5 V Shockley
fit) hears sample * eff(register)
and cuts the low registers. Parking the body on register 192 keeps the
balance on both, because eff(R)/R is nearly flat up there.

The previous pass cut the samples and raised the registers so the product
stayed put. That kept the mix, and it kept the music quiet. This pass
raises the product.

Once, at build time (the player, the slider and the sound effects are
unchanged):

- one product gain for the whole song. It is the largest gain that lands
  every group's loudest note on register 192 with no sample past full
  scale, and it is capped at TARGET_DB over the recording. No song has
  enough room to reach the chime, so the ceiling is what ships;
- the same index shift for every sounding note of a group, so the loudest
  lands on index 0. A relative level command stays relative inside the
  group. Tails take the same shift and are not silenced. The loud group
  stays full scale. A quieter group is scaled only as far as that one
  gain requires, which is the balance;
- a second apply finds every peak already on register 192 and the loudest
  sample already full scale, and does not change a byte.

Register 255 would be a different mant table in the player. This pass
does not write it.
"""
import json
import math
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, '..'))
import musbank

# Fitted diode. Same constants as voltab_diode.py. VFS is the 5 V fit.
VFS = 5.0
_IS, _N, _VT, _R = 2.5e-9, 1.75, 0.02585, 1000.0
# Notes within this many dB of a group's peak are the body the gain is
# fitted to. A tail sits on a coarser rung and must not pull the scale.
BODY_DB = float(os.environ.get('MUSKNEE_BODY', '6'))
# How far the E1M1 mix sits under the ROM 03 chime at master 5, in dB.
# The gain stops here even when a song still has sample room.
TARGET_DB = float(os.environ.get('MUSLOUD_TARGET_DB', '16.34'))
HEAD_MAX = 43264       # METHOD.md: MB_IMAGE to MB_PLANS
PAGE_MAX = {'D_INTRO': 200, 'D_INTER': 200, 'D_VICTOR': 200}
VMAX = 192             # musbank.vol_of(0); the loudest rung the player writes
SAFE_REG = 96          # knee-spread report only; the pass parks on VMAX
# A song already on the ceiling can still show a fraction of a decibel of
# room because a full-scale byte landed on 126 instead of 127. That is not
# another pass.
_PARKED_DB = 0.15


def _wvref(vout):
    if vout <= 0.0:
        return 0.0
    lo, hi = 0.0, vout
    for _ in range(80):
        mid = (lo + hi) / 2.0
        if mid + _N * _VT * math.log(mid / _R / _IS + 1.0) > vout:
            hi = mid
        else:
            lo = mid
    return lo


def eff_table(vfs=VFS):
    """Effective linear volume of each register, 0..255, with the WVREF diode."""
    return [256.0 * _wvref(vfs * v / 256.0) / vfs for v in range(256)]


EFF = eff_table()


def ladder():
    """(level index, register) for every rung the full-volume table produces.

    The first index that yields a register is the one a rewritten level
    uses. An unchanged note keeps the index the song already stored.
    """
    out = []
    seen = set()
    for i in range(128):
        reg = musbank.vol_of(i)
        if reg > 0 and reg not in seen:
            seen.add(reg)
            out.append((i, reg))
    return out


RUNGS = ladder()


def snap(target):
    """Level index whose register is closest in dB to `target`.

    Every rung is eligible, including ones under SAFE_REG: a tail keeps
    its ratio instead of being lifted or cut. Register 0 is only for a
    note that was already silent.
    """
    if target <= 0:
        return 127, 0
    best = None
    for i, reg in RUNGS:
        err = abs(math.log(reg / target))
        if best is None or err < best[0]:
            best = (err, i, reg)
    return best[1], best[2]


def parse_unit(img):
    D, p8, sl, low, flags = struct.unpack_from('<BBHBB', img, 0)
    P = p8 or 256
    base = 6 + sl + 2 * P
    dptr = img[base:base + D]
    dsiz = img[base + D:base + 2 * D]
    dmode = img[base + 2 * D:base + 3 * D]
    lptr = img[base + 3 * D:base + 4 * D]
    lsiz = img[base + 4 * D:base + 5 * D]
    doc_off = base + 5 * D
    doc = img[doc_off:]
    expect = 256 * (255 - low)
    if len(doc) != expect:
        raise ValueError('DOC image %d bytes, expected %d' % (len(doc), expect))
    stream = img[6:6 + sl]
    pitches = img[6 + sl:6 + sl + 2 * P]
    return {
        'D': D, 'P': P, 'SL': sl, 'low': low, 'flags': flags,
        'dptr': dptr, 'dsiz': dsiz, 'dmode': dmode, 'lptr': lptr, 'lsiz': lsiz,
        'doc': bytearray(doc), 'stream': stream, 'pitches': pitches,
        'head': 6 + sl + 2 * P + 5 * D,
    }


def _pages(start, size_byte):
    k = size_byte >> 3
    n = 1 << k
    return list(range(start, start + n))


def zone_pages(u, z):
    pages = _pages(u['dptr'][z], u['dsiz'][z])
    if u['dmode'][z] != 2:          # attack: a separate loop table
        pages += _pages(u['lptr'][z], u['lsiz'][z])
    return pages


def walk(stream, D):
    """Commands in order. Levels are the raw index (8-bit), as the player adds them."""
    pos, n = 0, len(stream)
    level = [0xFF] * 16
    desc = [None] * 16
    cmds = []
    events = []          # (cmd index, desc or None, linear register, is_note, level)
    bes = []             # (desc, page) while that descriptor is current
    waits = []

    def remember(idx, v, is_note):
        d = desc[v]
        lv = level[v]
        reg = musbank.vol_of(lv) if lv < 128 else 0
        events.append((idx, d, reg, is_note, lv))

    while pos < n:
        c = stream[pos]
        if c >= 0xD0:
            cmds.append(('wait', bytes([c])))
            waits.append(c)
            pos += 1
            if c == 0xE0:
                if pos < n:
                    cmds.append(('raw', stream[pos:]))
                break
            continue
        if c == 0xBF:
            cmds.append(('raw', stream[pos:pos + 3]))
            pos += 3
            continue
        if c == 0xBE:
            v, page = stream[pos + 1], stream[pos + 2]
            cmds.append(('raw', stream[pos:pos + 3]))
            if desc[v] is not None:
                bes.append((desc[v], page))
            pos += 3
            continue
        k, v = c >> 4, c & 15
        if v >= 14:
            raise ValueError('voice %d at %d' % (v, pos))
        if k in (0, 8, 9):
            level[v] = (level[v] + {0: 4, 8: 8, 9: -4}[k]) & 0xFF
            cmds.append(('lev', v))
            remember(len(cmds) - 1, v, False)
            pos += 1
        elif k == 1:
            level[v] = stream[pos + 1]
            cmds.append(('lev', v))
            remember(len(cmds) - 1, v, False)
            pos += 2
        elif k == 6 or k == 11:
            cmds.append(('raw', bytes([c])))
            pos += 1
        elif k in (4, 5):
            cmds.append(('raw', stream[pos:pos + 2]))
            pos += 2
        elif k in (3, 7, 2, 12, 10):
            if k == 3:
                prefix = stream[pos:pos + 3]
                a = stream[pos + 3]
                desc[v] = prefix[1]
                pos += 4
            elif k in (7, 2):
                prefix = stream[pos:pos + 2]
                a = stream[pos + 2]
                pos += 3
            else:
                prefix = bytes([c])
                a = stream[pos + 1]
                pos += 2
            level[v] = a & 0x7F
            cmds.append(('note', v, prefix, a & 0x80))
            remember(len(cmds) - 1, v, True)
        else:
            raise ValueError('bad command %02x at %d' % (c, pos))
    if pos != n and not (waits and waits[-1] == 0xE0):
        raise ValueError('stream consumed %d of %d' % (pos, n))
    return cmds, events, bes, waits


class _Union:
    def __init__(self, n):
        self.p = list(range(n))

    def find(self, x):
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]
            x = self.p[x]
        return x

    def union(self, a, b):
        a, b = self.find(a), self.find(b)
        if a != b:
            self.p[b] = a


def _gain_for(nz, shift):
    """Sample scale that matches an index shift.

    Fitted to the body only (notes within BODY_DB of the peak), minimax in
    dB. A tail sits on a coarser part of the ladder, and letting it pull
    the scale would move the mix on a linear board.
    """
    if shift <= 0:
        return 1.0
    peak = max(r for _i, r in nz)
    line = peak * 10.0 ** (-BODY_DB / 20.0)
    ratios = []
    for i, r in nz:
        if r < line:
            continue
        nr = musbank.vol_of(i - shift)
        if nr > 0:
            ratios.append(r / float(nr))
    if not ratios:
        for i, r in nz:
            nr = musbank.vol_of(i - shift)
            if r > 0 and nr > 0:
                ratios.append(r / float(nr))
    if not ratios:
        return 1.0
    return math.sqrt(min(ratios) * max(ratios))


def _page_peak(doc, low, page):
    o = 256 * (page - low)
    if o < 0 or o + 256 > len(doc):
        raise ValueError('page %d outside the image' % page)
    peak = 0
    for b in doc[o:o + 256]:
        if b == 0:
            continue
        a = b - 128
        if a < 0:
            a = -a
        if a > peak:
            peak = a
    return peak


def _plan(u, groups, by_root, pages, bes, uf):
    """One product gain, and a shift and a sample scale per group.

    Each sounding group's loudest index moves to 0 (register VMAX). The
    sample scale is that gain times the ladder ratio of the shift, fitted
    on the body. The gain is the largest one that leaves every scaled
    sample inside full scale, and at most TARGET_DB. A group with no
    sounding note is not scaled and does not limit the gain.
    """
    rows = {}
    limits = []
    for root, zs in groups.items():
        nz = [(i, r) for i, r in by_root.get(root, []) if r > 0 and 0 <= i < 128]
        ps = set()
        for z in zs:
            ps.update(pages[z])
        for d, p in bes:
            if uf.find(d) == root:
                ps.add(p)
        A = 0
        for p in ps:
            A = max(A, _page_peak(u['doc'], u['low'], p))
        if not nz:
            rows[root] = {
                'shift': 0, 'ratio': 1.0, 'A': A, 'peak': 0, 'low': 0,
                'sound': False, 'pages': sorted(ps),
            }
            continue
        loud_i = min(i for i, _r in nz)
        peak = max(r for _i, r in nz)
        line = peak * 10.0 ** (-BODY_DB / 20.0)
        body = [r for _i, r in nz if r >= line] or [r for _i, r in nz]
        ratio = _gain_for(nz, loud_i)
        rows[root] = {
            'shift': loud_i, 'ratio': ratio, 'A': A, 'peak': peak,
            'low': min(body), 'sound': True, 'pages': sorted(ps),
        }
        if A > 0 and ratio > 0:
            limits.append(127.0 / (A * ratio))
    G_ceil = min(limits) if limits else 1.0
    if G_ceil < 1.0:
        G_ceil = 1.0
    G_target = 10.0 ** (TARGET_DB / 20.0)
    G = G_target if G_ceil > G_target else G_ceil
    parked = all(row['shift'] == 0 for row in rows.values())
    if parked and G <= 10.0 ** (_PARKED_DB / 20.0):
        G = 1.0
    shift = {}
    gain = {}
    for root, row in rows.items():
        shift[root] = row['shift'] if row['sound'] else 0
        if (not row['sound']) or (G == 1.0 and row['shift'] == 0):
            gain[root] = 1.0
            continue
        g = G * row['ratio']
        if abs(g - 1.0) < 1e-12:
            g = 1.0
        gain[root] = g
    return G, G_ceil, shift, gain, rows


def apply_image(img, name='song'):
    """Return (new_image_bytes, info). The player tables are not touched."""
    u = parse_unit(img)
    D = u['D']
    cmds, events, bes, waits = walk(u['stream'], D)
    pages = [zone_pages(u, z) for z in range(D)]
    uf = _Union(D)
    used = {}
    for z, ps in enumerate(pages):
        for p in ps:
            if p in used:
                uf.union(z, used[p])
            else:
                used[p] = z
    for d, p in bes:
        if p in used:
            uf.union(d, used[p])
        else:
            used[p] = d
    groups = {}
    for z in range(D):
        groups.setdefault(uf.find(z), []).append(z)
    by_root = {root: [] for root in groups}
    for _i, d, reg, _note, lv in events:
        if d is None:
            continue
        by_root[uf.find(d)].append((lv, reg))
    G, G_ceil, shift, gain, rows = _plan(u, groups, by_root, pages, bes, uf)
    song_db = 20.0 * math.log10(G) if G > 0 else 0.0
    ceil_db = 20.0 * math.log10(G_ceil) if G_ceil > 0 else 0.0
    short_db = TARGET_DB - song_db
    body_line = {}
    parts = []
    for root, zs in groups.items():
        row = rows[root]
        g = gain[root]
        body_line[root] = (row['peak'] * 10.0 ** (-BODY_DB / 20.0)) if row['peak'] else 0.0
        parts.append({
            'zones': zs, 'g': g,
            'g_db': (20.0 * math.log10(g) if g > 0 and g != 1.0 else 0.0),
            'shift': shift[root], 'body_min': row['low'], 'peak': row['peak'],
            'short_db': short_db, 'A': row['A'], 'pages': row['pages'],
        })
    noop = abs(G - 1.0) < 1e-12 and all(s == 0 for s in shift.values())

    def mapped(d, reg, orig_lv):
        # A silent index stays silent. A sounding index moves by the group's
        # shift, which is constant, so a +4 stays a +4.
        if reg <= 0 or d is None or orig_lv >= 128:
            return orig_lv, reg if orig_lv < 128 else 0
        s = shift[uf.find(d)]
        if s == 0:
            return orig_lv, reg
        new_lv = orig_lv - s
        if new_lv < 0:
            new_lv = 0
        return new_lv, musbank.vol_of(new_lv)

    # Rewrite. `cur` is the level index the player will be holding.
    cur = [None] * 16
    desc = [None] * 16
    out = bytearray()
    ei = 0
    lin_errs = []
    body_lin = []
    body_atts = []
    body_landed = []
    n_cut = 0

    def consider(d, reg, new_reg):
        if reg <= 0 or new_reg <= 0 or d is None:
            if reg > 0 and new_reg == 0:
                return True
            return False
        g = gain[uf.find(d)]
        heard = g * new_reg
        # Residual against the one song gain. The ladder's integer rungs
        # are the whole of it on the body.
        err = 20.0 * math.log10(heard / reg) - song_db
        lin_errs.append(err)
        root = uf.find(d)
        if reg >= body_line[root] and (shift[root] > 0 or new_reg >= SAFE_REG):
            body_lin.append(err)
            body_atts.append(20.0 * math.log10(EFF[new_reg] / new_reg))
            body_landed.append(new_reg)
        return False

    def emit_level(v, idx):
        prev = cur[v]
        cur[v] = idx
        if prev is None:
            out.append(0x10 | v)
            out.append(idx)
            return
        delta = idx - prev
        if delta == 4:
            out.append(0x00 | v)
        elif delta == 8:
            out.append(0x80 | v)
        elif delta == -4:
            out.append(0x90 | v)
        elif delta == 0:
            return
        else:
            out.append(0x10 | v)
            out.append(idx)

    if noop:
        out = bytearray(u['stream'])
        ei = len(events)
    for cmd in cmds:
        if noop:
            break
        kind = cmd[0]
        if kind == 'wait' or kind == 'raw':
            out += cmd[1]
            continue
        if kind == 'lev':
            v = cmd[1]
            _i, d, reg, _note, lv = events[ei]
            ei += 1
            idx, new_reg = mapped(d, reg, lv)
            if consider(d, reg, new_reg):
                n_cut += 1
            emit_level(v, idx)
            continue
        # note
        v, prefix, bit7 = cmd[1], cmd[2], cmd[3]
        if prefix[0] >> 4 == 3:
            desc[v] = prefix[1]
        _i, d, reg, _note, lv = events[ei]
        ei += 1
        idx, new_reg = mapped(desc[v], reg, lv)
        if consider(desc[v], reg, new_reg):
            n_cut += 1
        cur[v] = idx
        out += prefix
        out.append(idx | bit7)

    if ei != len(events):
        raise ValueError('%s: %d events, rewrote %d' % (name, len(events), ei))
    if n_cut:
        raise ValueError('%s: %d notes silenced; a tail must keep its ratio' % (name, n_cut))

    # Scale every page a group plays, including waveform-page swaps.
    doc = u['doc']
    low = u['low']
    page_g = {}
    for root, zs in groups.items():
        g = gain[root]
        for z in zs:
            for p in pages[z]:
                if p in page_g and abs(page_g[p] - g) > 1e-12:
                    raise ValueError('%s: page %d has two gains' % (name, p))
                page_g[p] = g
    for d, p in bes:
        g = gain[uf.find(d)]
        if p in page_g and abs(page_g[p] - g) > 1e-12:
            raise ValueError('%s: page %d has two gains' % (name, p))
        page_g[p] = g
    noise = []
    for p, g in sorted(page_g.items()):
        if noop or abs(g - 1.0) < 1e-12:
            continue
        o = 256 * (p - low)
        if o < 0 or o + 256 > len(doc):
            raise ValueError('%s: page %d outside the image' % (name, p))
        block = doc[o:o + 256]
        sig = err = 0.0
        scaled = bytearray(block)
        for i, b in enumerate(block):
            if b == 0:
                continue
            ideal = (b - 128) * g
            q = int(round(ideal))
            if q > 127 or q < -127:
                raise ValueError('%s: page %d sample clips at gain %.4f' % (name, p, g))
            nb = 128 + q
            if nb < 1:
                nb = 1
            if nb > 255:
                nb = 255
            scaled[i] = nb
            sig += ideal * ideal
            e = (nb - 128) - ideal
            err += e * e
        if any(scaled[i] == 0 and block[i] != 0 for i in range(256)):
            raise ValueError('%s: scale produced a 0 byte' % name)
        if any(scaled[i] != 0 and block[i] == 0 for i in range(256)):
            raise ValueError('%s: scale filled a halt byte' % name)
        doc[o:o + 256] = scaled
        noise.append({
            'page': p, 'g_db': 20.0 * math.log10(g) if g > 0 else 0.0,
            'snr_db': (10.0 * math.log10(sig / err) if err > 0 and sig > 0 else None),
        })

    sl = len(out)
    head = 6 + sl + 2 * u['P'] + 5 * D
    if head > HEAD_MAX:
        raise ValueError('%s: head %d exceeds %d' % (name, head, HEAD_MAX))
    img_out = bytearray(struct.pack('<BBHBB', D, u['P'] & 255, sl, low, u['flags']))
    img_out += out
    img_out += u['pitches']
    img_out += u['dptr']
    img_out += u['dsiz']
    img_out += u['dmode']
    img_out += u['lptr']
    img_out += u['lsiz']
    img_out += doc

    _c2, _e2, _b2, waits2 = walk(bytes(out), D)
    if waits2 != waits:
        raise ValueError('%s: wait bytes changed' % name)
    new_regs = _stream_regs(bytes(out))

    def pct(xs, p):
        if not xs:
            return 0.0
        k = min(len(xs) - 1, int(round(p * (len(xs) - 1))))
        return xs[k]

    abs_lin = sorted(abs(e) for e in lin_errs)
    abs_body = sorted(abs(e) for e in body_lin)
    atts = sorted(body_atts)
    info = {
        'name': name,
        'pages': 255 - low,
        'page_budget': PAGE_MAX.get(name, 180),
        'head_before': u['head'],
        'head_after': head,
        'stream_before': u['SL'],
        'stream_after': sl,
        'safe_reg': SAFE_REG,
        'min_reg': min(new_regs) if new_regs else 0,
        'min_nonzero_reg': min((r for r in new_regs if r > 0), default=0),
        'max_reg': max(new_regs) if new_regs else 0,
        'n_level_events': len(events),
        'n_cut': n_cut,
        'n_measured': len(lin_errs),
        'lin_median_db': pct(sorted(lin_errs), 0.5) if lin_errs else 0.0,
        'abs_median_db': pct(abs_lin, 0.5),
        'abs_p90_db': pct(abs_lin, 0.9),
        'abs_worst_db': abs_lin[-1] if abs_lin else 0.0,
        'body_lin_median_db': pct(abs_body, 0.5),
        'body_lin_worst_db': abs_body[-1] if abs_body else 0.0,
        'body_n': len(body_landed),
        'body_min_reg': min(body_landed) if body_landed else 0,
        'body_att_lo': atts[0] if atts else 0.0,
        'body_att_hi': atts[-1] if atts else 0.0,
        'body_att_spread': (atts[-1] - atts[0]) if atts else 0.0,
        'n_short': 1 if short_db > 0.05 else 0,
        'parts': parts,
        'noise': noise,
        'worst_noise_db': max(((-n['g_db']) for n in noise if n['g_db'] < 0), default=0.0),
        'median_noise_db': pct(sorted(n['g_db'] for n in noise), 0.5) if noise else 0.0,
        'song_gain_db': song_db,
        'ceil_db': ceil_db,
        'short_db': short_db,
        'max_sample': max((b - 128 if b >= 128 else 128 - b) for b in doc if b) if any(doc) else 0,
        'stream': bytes(out),
    }
    return bytes(img_out), info


def _stream_regs(stream):
    """Every DOC register the full-volume ladder writes for a level or a note."""
    pos, n = 0, len(stream)
    level = [0xFF] * 16
    regs = []
    while pos < n:
        c = stream[pos]
        if c >= 0xD0:
            pos += 1
            if c == 0xE0:
                break
            continue
        if c == 0xBF:
            pos += 3
            continue
        if c == 0xBE:
            pos += 3
            continue
        k, v = c >> 4, c & 15
        if k in (0, 8, 9):
            level[v] = (level[v] + {0: 4, 8: 8, 9: -4}[k]) & 0xFF
            regs.append(musbank.vol_of(level[v]) if level[v] < 128 else 0)
            pos += 1
        elif k == 1:
            level[v] = stream[pos + 1]
            regs.append(musbank.vol_of(level[v]) if level[v] < 128 else 0)
            pos += 2
        elif k == 6 or k == 11:
            pos += 1
        elif k in (4, 5):
            pos += 2
        elif k == 3:
            level[v] = stream[pos + 3] & 0x7F
            regs.append(musbank.vol_of(level[v]))
            pos += 4
        elif k in (7, 2):
            level[v] = stream[pos + 2] & 0x7F
            regs.append(musbank.vol_of(level[v]))
            pos += 3
        elif k in (12, 10):
            level[v] = stream[pos + 1] & 0x7F
            regs.append(musbank.vol_of(level[v]))
            pos += 2
        else:
            raise ValueError('verify bad %02x' % c)
    return regs


def old_regs(img):
    u = parse_unit(img)
    return _stream_regs(u['stream']), u


def slider_rows(parked_reg):
    """What each music-volume step does to a note parked on `parked_reg`.

    setVolume adds musAtt[volume] to the level index and writes the
    exponential register. Volumes 13-15 are the bake (C=0). A lower step
    is exact on a linear board and walks a hard-knee board back down the
    diode. No remap is installed: a remap that undoes the diode would
    change the boards this music already sounds right on.
    """
    mus_att = [255, 51, 45, 39, 32, 26, 21, 16, 13, 9, 7, 4, 1, 0, 0, 0]
    # Index of the parked register, and of a full-scale voice.
    park_i = next(i for i, r in RUNGS if r == parked_reg)
    rows = []
    for mv in range(16):
        c = mus_att[mv]
        for base_name, base_i in (('body', park_i), ('full', 0)):
            if c >= 255 or (base_i + c) >= 128:
                rows.append((mv, base_name, c, 0, 0.0, None, None))
                continue
            reg = musbank.vol_of(base_i + c)
            full = musbank.vol_of(base_i)
            lin_db = 20.0 * math.log10(reg / full) if reg and full else None
            knee_db = 20.0 * math.log10(EFF[reg] / EFF[full]) if reg and full else None
            rows.append((mv, base_name, c, reg, EFF[reg], lin_db, knee_db))
    return rows


def sfx_curve():
    """DOC registers distance and separation produce today.

    s_sound65.s: close (dist <= 160) writes snd*8. Farther,
    snd*8*(1200-dist)/1040, silent past 1200. docVolume then applies
    left = vol*(254-sep)/127, right = vol*sep/127. sep is 128 +/- up to 96.
    snd_SfxVolume defaults to 15, so a close centered sound is register 120.

    A sample scale that preserved the linear fade could multiply every
    register by k only until the loud pan side hits 255. That k is about
    1.22 (1.7 dB) at volume 15, which does not carry the quiet side over
    the knee. Anything larger clips the loud side and changes the stereo
    image on a normal board. The fade is left as it is.
    """
    swing = 96
    rows = []
    for snd in (15, 12, 8, 4, 1):
        full = snd * 8
        for dist in (0, 160, 400, 600, 800, 853, 900, 1000, 1100, 1199):
            if dist <= 160:
                vol = full
            else:
                units = max(0, 1200 - dist)
                vol = int(full * units / 1040)
            center = int(vol * 126 / 127)
            quiet = int(vol * (128 - swing) / 127)
            loud = min(255, int(vol * (128 + swing) / 127))
            rows.append((snd, dist, center, quiet, loud,
                         round(EFF[center], 2), round(EFF[quiet], 2), round(EFF[loud], 2)))
    return rows


def _songs(path):
    if os.path.isdir(path):
        names = sorted(f for f in os.listdir(path) if f.endswith('.mus'))
        return [(os.path.splitext(n)[0], os.path.join(path, n)) for n in names]
    return [(os.path.splitext(os.path.basename(path))[0], path)]


def main(argv):
    cmd = argv[1] if len(argv) > 1 else 'analyze'
    if cmd == 'law':
        for v in range(256):
            print('%.6f' % EFF[v])
        return 0
    if cmd == 'slider':
        parked = int(argv[2]) if len(argv) > 2 else SAFE_REG
        for row in slider_rows(parked):
            print('\t'.join('' if x is None else ('%.3f' % x if isinstance(x, float) else str(x))
                            for x in row))
        return 0
    if cmd == 'sfx':
        for row in sfx_curve():
            print('\t'.join(str(x) for x in row))
        return 0
    root = argv[2]
    write = cmd == 'apply'
    summary = []
    for name, path in _songs(root):
        img = open(path, 'rb').read()
        old, _u = old_regs(img)
        new_img, info = apply_image(img, name)
        nz = [r for r in old if r > 0]
        info['old_min_nonzero'] = min(nz) if nz else 0
        info['old_median'] = sorted(nz)[len(nz) // 2] if nz else 0
        stream = info.pop('stream')
        summary.append(info)
        print('%s  gain %+.2f dB  ceiling %+.2f  under +16.3 dB cap %.2f  '
              'pages %d/%d  head %d -> %d  stream %d -> %d  '
              'peak reg %d  sample %d  body reg %d  '
              'ladder |err| med %.2f worst %.2f  knee %.2f dB (%.1f..%.1f)  '
              'deepest sample cut %.1f' % (
                  name, info['song_gain_db'], info['ceil_db'], info['short_db'],
                  info['pages'], info['page_budget'],
                  info['head_before'], info['head_after'],
                  info['stream_before'], info['stream_after'],
                  info['max_reg'], info['max_sample'], info['body_min_reg'],
                  info['body_lin_median_db'], info['body_lin_worst_db'],
                  info['body_att_spread'], info['body_att_lo'], info['body_att_hi'],
                  info['worst_noise_db']))
        if info['pages'] > info['page_budget']:
            raise SystemExit('%s over the page budget' % name)
        if write:
            open(path, 'wb').write(new_img)
        else:
            info['stream_len_check'] = len(stream)
    out_json = os.environ.get('MUSKNEE_JSON')
    if out_json:
        for s in summary:
            for p in s['parts']:
                p['g'] = round(p['g'], 5)
                p['g_db'] = round(p['g_db'], 2)
                p['short_db'] = round(p['short_db'], 2)
            for n in s['noise']:
                if n['snr_db'] is not None:
                    n['snr_db'] = round(n['snr_db'], 1)
                n['g_db'] = round(n['g_db'], 2)
        json.dump(summary, open(out_json, 'w'), indent=1)
        print('wrote', out_json)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
