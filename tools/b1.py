#!/usr/bin/env python3
"""B1: the compression of the level store (tools/levelimg.py), decoded by
b1Decode of src/iigs/w_level65.s. An LZ of the ZX0 class (the codec study
of 2026-09-25, research_notes/compression 2026-09-25/codec):

- Bits come in 16-bit little-endian words, most significant bit first,
  placed in the byte stream where the decoder needs its next bit (one read
  pointer for bits and bytes).
- Elias gamma codes, interlaced: control bit 1 = stop, 0 = one more data
  bit.
- Tokens: a literal run first (no flag). After literals: 0 = a match at
  the last offset (gamma length), 1 = a match at a new offset. After a
  match: 0 = a literal run (gamma length, then the bytes), 1 = a match at
  a new offset.
- A new offset: gamma(hi), then a byte b: offset = ((hi - 1) << 7 | b >> 1)
  + 1, and b & 1 is the first control bit of gamma(length - 1). Offsets up
  to 32768; matches of 2 to 256 bytes.
- No end marker: the decoder stops at the output length.

The parse is optimal for the bit cost (a dynamic program over the matches
of hash chains). compress() keeps its results in a cache directory (the
same input gives the same output), because the parse takes seconds for
each 64 KB.
"""

import hashlib
import os

WINDOW = 32768
MAXMATCH = 256


def _gamma_bits(n):
    return 2 * n.bit_length() - 1


def _matches(data, maxchain=64):
    """For each position: [(length, offset)], the longest for each offset
    of a hash chain of 3-byte prefixes, and 2-byte matches at offsets 1-4."""
    n = len(data)
    head = {}
    prev = [-1] * n
    res = [None] * n
    for i in range(n):
        cands = []
        if i + 2 < n:
            key = data[i:i + 3]
            j = head.get(key, -1)
            prev[i] = j
            head[key] = i
            chain = 0
            best = 0
            while j >= 0 and i - j <= WINDOW and chain < maxchain:
                ln = 3
                while i + ln < n and ln < MAXMATCH and data[j + ln] == data[i + ln]:
                    ln += 1
                if ln > best:
                    best = ln
                    cands.append((ln, i - j))
                j = prev[j]
                chain += 1
        for off in (1, 2, 3, 4):
            if i - off >= 0 and i + 1 < n and data[i - off] == data[i] and data[i - off + 1] == data[i + 1]:
                ln = 2
                while i + ln < n and ln < MAXMATCH and data[i - off + ln] == data[i + ln]:
                    ln += 1
                if ln < 3 or all(o != off for _, o in cands):
                    cands.append((ln, off))
        res[i] = cands
    return res


def _parse(buf):
    """The optimal parse: [('L', start, n)] literal runs and [('M', length,
    offset, repeat)] matches."""
    n = len(buf)
    inf = float('inf')
    m = _matches(buf)
    lit = [inf] * (n + 1)
    loff = [0] * (n + 1)
    lback = [None] * (n + 1)
    mat = [inf] * (n + 1)
    moff = [0] * (n + 1)
    mback = [None] * (n + 1)
    mat[0] = 0
    moff[0] = 1
    for i in range(n + 1):
        if i > 0 and lit[i - 1] + 8.1 < lit[i]:
            lit[i] = lit[i - 1] + 8.1
            loff[i] = loff[i - 1]
            lback[i] = ('x', i - 1)
        if mat[i] < inf:
            base = mat[i] + 1
            for ln in range(1, min(64, n - i) + 1):
                c = base + _gamma_bits(ln) + 8 * ln
                if c < lit[i + ln]:
                    lit[i + ln] = c
                    loff[i + ln] = moff[i]
                    lback[i + ln] = (i, ln)
        if i == n:
            break
        for ml, off in m[i]:
            for src, last, st in ((lit[i], loff[i], 'L'), (mat[i], moff[i], 'M')):
                if src == inf:
                    continue
                for ln in {ml, 2, 3, 4, 8, 16, 32, 64}:
                    if ln > ml or ln < 2 or i + ln > n:
                        continue
                    rep = off == last and st == 'L'
                    c = src + 1 + (_gamma_bits(ln) if rep else
                                   _gamma_bits((off - 1) // 128 + 1) + 7 + _gamma_bits(ln - 1))
                    if c < mat[i + ln]:
                        mat[i + ln] = c
                        moff[i + ln] = off
                        mback[i + ln] = (i, st, ln, off, rep)
    toks = []
    i = n
    st = 'L' if lit[n] <= mat[n] else 'M'
    while i > 0:
        if st == 'L':
            j, ln = lback[i]
            run = 0
            while j == 'x':
                run += 1
                i = ln
                j, ln = lback[i]
            toks.append(('L', j, ln + run))
            i = j
            st = 'M'
        else:
            j, pst, ln, off, rep = mback[i]
            toks.append(('M', ln, off, rep))
            i = j
            st = pst
    toks.reverse()
    return toks


class _Bits:
    def __init__(self):
        self.out = bytearray()
        self.word = 0
        self.left = 0

    def bit(self, b):
        if self.left == 0:
            self.word = len(self.out)
            self.out += b'\0\0'
            self.left = 16
        self.left -= 1
        if b:
            v = (self.out[self.word] | self.out[self.word + 1] << 8) | 1 << self.left
            self.out[self.word] = v & 255
            self.out[self.word + 1] = v >> 8

    def gamma(self, v):
        nb = v.bit_length()
        for j in range(nb - 1):
            self.bit(0)
            self.bit((v >> (nb - 2 - j)) & 1)
        self.bit(1)


def _encode(buf, toks):
    w = _Bits()
    first = True
    after_lit = False
    for t in toks:
        if t[0] == 'L':
            if not first:
                w.bit(0)
            w.gamma(t[2])
            w.out += buf[t[1]:t[1] + t[2]]
            after_lit = True
        else:
            _, ln, off, rep = t
            if rep:
                w.bit(0)
                w.gamma(ln)
            else:
                w.bit(1)
                w.gamma((off - 1) // 128 + 1)
                g = ln - 1
                nb = g.bit_length()
                firstbit = 1 if nb == 1 else 0
                w.out.append((((off - 1) & 127) << 1) | firstbit)
                # the rest of gamma(ln - 1) after its first control bit
                for j in range(nb - 1):
                    if j:
                        w.bit(0)
                    w.bit((g >> (nb - 2 - j)) & 1)
                if nb > 1:
                    w.bit(1)
            after_lit = False
        first = False
    return bytes(w.out)


def decode(src, n):
    """The reference decoder: n output bytes."""
    pos = 0
    bits = 0x8000
    out = bytearray()
    off = 1

    def rb():
        nonlocal bits, pos
        c = bits >> 15
        bits = (bits << 1) & 0xffff
        if bits == 0:
            v = src[pos] | src[pos + 1] << 8
            pos += 2
            c = v >> 15
            bits = ((v << 1) | 1) & 0xffff
        return c

    def gamma(c=None):
        a = 1
        if c is None:
            c = rb()
        while not c:
            a = a * 2 + rb()
            c = rb()
        return a

    def newoff():
        nonlocal pos, off
        hi = gamma()
        b = src[pos]
        pos += 1
        off = ((hi - 1) << 7 | b >> 1) + 1
        for _ in range(gamma(b & 1) + 1):
            out.append(out[-off])

    state = 'lit'
    while True:
        if state == 'lit':
            ln = gamma()
            out.extend(src[pos:pos + ln])
            pos += ln
            state = 'al'
        elif state == 'al':
            if len(out) >= n:
                break
            if rb():
                newoff()
            else:
                for _ in range(gamma()):
                    out.append(out[-off])
            state = 'am'
        else:
            if len(out) >= n:
                break
            if rb():
                newoff()
            else:
                state = 'lit'
    return bytes(out)


def compress(buf, cache=None):
    """The B1 stream of buf (checked with the reference decoder)."""
    buf = bytes(buf)
    path = None
    if cache:
        key = hashlib.sha1(b'B1v1' + buf).hexdigest()
        path = os.path.join(cache, key[:2], key + '.b1')
        if os.path.exists(path):
            return open(path, 'rb').read()
    enc = _encode(buf, _parse(buf))
    if decode(enc, len(buf)) != buf:
        raise ValueError('B1: the stream does not decode')
    if path:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + '.%d' % os.getpid()
        open(tmp, 'wb').write(enc)
        os.replace(tmp, path)
    return enc


if __name__ == '__main__':
    import sys
    import time
    d = open(sys.argv[1], 'rb').read()[:65536]
    t = time.time()
    e = compress(d)
    print(len(d), len(e), '%.1f s' % (time.time() - t))
