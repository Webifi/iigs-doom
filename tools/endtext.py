#!/usr/bin/env python3
"""Write the ENDOOM page of the WAD as 80-column Apple IIgs text: its rows
1-21, from the title to the last line of text. Its border rows 0 and 22 and
the empty rows 23 and 24 stay out: Applesoft's cold start writes two line
feeds before its prompt, and the prompt must not scroll the title away.
Each row is 40 bytes for the aux page (the even columns), then 40 bytes for
the main page (the odd columns). The text is one color on the IIgs; the line
under the title becomes a MouseText line."""
import struct
import sys

FIRST, ROWS = 1, 21
# CP437 box characters -> the alternate character set of the IIgs
BOX = {0xc4: 0x53}      # horizontal line: MouseText center line


def lump(wad, want):
    count, offset = struct.unpack_from('<4xII', wad)
    for i in range(count):
        pos, size, name = struct.unpack_from('<II8s', wad, offset + 16 * i)
        if name.rstrip(b'\0') == want:
            return wad[pos:pos + size]
    raise SystemExit('no %s in the WAD' % want.decode())


def apple(ch):
    if ch in BOX:
        return BOX[ch]
    if ch == 0:
        return 0xa0
    if 0x20 <= ch < 0x7f:
        return ch | 0x80
    raise SystemExit('ENDOOM character 0x%02x has no IIgs text form' % ch)


def main():
    wad, out = sys.argv[1], sys.argv[2]
    page = lump(open(wad, 'rb').read(), b'ENDOOM')
    rows = []
    for r in range(ROWS):
        cells = [apple(page[((FIRST + r) * 80 + c) * 2]) for c in range(80)]
        rows.append(cells[0::2] + cells[1::2])
    with open(out, 'w') as f:
        f.write(';;; The ENDOOM page as IIgs text (tools/endtext.py).\n')
        f.write('              .section endtext, rodata\n')
        f.write('              .public endText\n')
        f.write('endText:\n')
        for row in rows:
            for i in range(0, 80, 16):
                f.write('              .byte   %s\n' % ', '.join('0x%02x' % b for b in row[i:i + 16]))


if __name__ == '__main__':
    main()
