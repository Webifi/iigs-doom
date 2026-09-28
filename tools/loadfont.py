#!/usr/bin/env python3
"""The graphics of the load strip for the loader (src/iigs/loader.s): the
glyphs of Doom's small red font (STCFN) and the disk icon, as an assembly
file.

The strip is rows 191-199 of TITLEPIC, with palette 15 (the colors are in
STRIP_COLORS of tools/gscolor.py): 0 black, 1-4 the reds $400 $700 $A00
$D00, 5 yellow, 6 blue, 7 grey, 8 white.

A glyph has 2 bits for each pixel: 0 black, 1 $400, 2 $A00, 3 $D00 (the
nearest of these to the font color). The loader turns each pair of pixels
(4 bits) into a screen byte through a table, which also makes the text
darker for the pulse of the INSERT DISK prompt.
  glyph:  width in screen bytes (2 pixels each), then GLYPH_ROWS rows of
          (width + 1) / 2 bytes, the left pixels in the high bits
  GLYPHS: the address of each glyph, in the order of CHARS (the digits
          first, so glyph n is the digit n)
  PROMPT: the glyph numbers of "INSERT DISK ", then $FF

Usage: loadfont.py DOOM1.WAD OUT.s
"""

import struct
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0])
import gscolor
import wadtool

CHARS = '0123456789/ DEIKNRST'
GLYPH_ROWS = 7
SPACE_WIDTH = 4                  # pixels, as in Doom's HU font
LEVELS = ((68, 0, 0), (170, 0, 0), (221, 0, 0))

# The 3.5-inch disk, 11 x 9 pixels: B body, M shutter, K hole, W label
DISK = ('BBBBBBBBBB.',
        'BMMMMMMBBBB',
        'BMMKMMMBBBB',
        'BMMMMMMBBBB',
        'BBBBBBBBBBB',
        'BWWWWWWWWWB',
        'BWWWWWWWWWB',
        'BWWWWWWWWWB',
        'BBBBBBBBBBB')
ICON_COLORS = {'.': 0, 'K': 0, 'M': 7, 'W': 8}
BODY_LIT, BODY_DARK = 6, 1       # blue, and $400 when it blinks


def glyph(wad, pal, ch):
    """The 2-bit rows of a character, padded to an even number of pixels."""
    if ch == ' ':
        return [[0] * SPACE_WIDTH for _ in range(GLYPH_ROWS)]
    d = wad.get('STCFN%03d' % ord(ch))
    w, h, _, _ = struct.unpack_from('<hhhh', d, 0)
    if h != GLYPH_ROWS:
        sys.exit(f'STCFN{ord(ch):03d}: {h} rows, not {GLYPH_ROWS}')
    _, _, img = wadtool.decode_patch(d)
    rows = []
    for row in img:
        out = []
        for c in row:
            if c is None:
                out.append(0)
            else:
                out.append(1 + min(range(3), key=lambda i: gscolor.dist(pal[c], LEVELS[i])))
        rows.append(out + [0] * (w % 2))
    return rows


def pack(rows):
    """Width in screen bytes, then the rows with 4 pixels in each byte."""
    wb = len(rows[0]) // 2
    out = [wb]
    for row in rows:
        px = row + [0] * (-len(row) % 4)
        for i in range(0, len(px), 4):
            out.append(px[i] << 6 | px[i + 1] << 4 | px[i + 2] << 2 | px[i + 3])
    return out


def icon(body):
    out = []
    for row in DISK:
        px = [body if ch == 'B' else ICON_COLORS[ch] for ch in row] + [0]
        out += [px[i] << 4 | px[i + 1] for i in range(0, len(px), 2)]
    return out


def main():
    wad = wadtool.Wad(sys.argv[1])
    pal = wadtool.read_playpals(wad)[0]
    lines = [';;; Made by tools/loadfont.py from the STCFN font of the WAD. Do not edit.',
             '',
             f'GLYPH_ROWS    .equ    {GLYPH_ROWS}',
             f'ICON_ROWS     .equ    {len(DISK)}',
             f'ICON_BYTES    .equ    {(len(DISK[0]) + 1) // 2}',
             '',
             '              .section loader, text',
             '              .public GLYPHS, PROMPT, ICON_LIT, ICON_DARK',
             f'GLYPH_SLASH   .equ    {CHARS.index("/")}',
             'PROMPT:       .byte   ' + ', '.join(str(CHARS.index(c)) for c in 'INSERT DISK ') + ', 0xff',
             ';;; the glyphs of: ' + CHARS,
             'GLYPHS:']
    for i in range(len(CHARS)):
        lines.append(f'              .word   glyph{i}')
    for i, ch in enumerate(CHARS):
        data = pack(glyph(wad, pal, ch))
        lines.append(f'glyph{i}:       .byte   ' + ', '.join('0x%02x' % b for b in data)
                     + f'   ; {ch!r}')
    for name, body in (('ICON_LIT', BODY_LIT), ('ICON_DARK', BODY_DARK)):
        lines.append(f'{name}:')
        data = icon(body)
        n = (len(DISK[0]) + 1) // 2
        for r in range(len(DISK)):
            lines.append('              .byte   ' + ', '.join('0x%02x' % b for b in data[r * n:(r + 1) * n]))
    open(sys.argv[2], 'w').write('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
