#!/usr/bin/env python3
"""The subsector grid of a map: for each cell of CELL x CELL map units, the
deepest BSP node (or the subsector) that holds every point of the cell,
for R_PointInSubsector (src/iigs/r_iigs65.s): its walk down the tree
starts there, with the same result as a walk from the root.

A node decides for a whole cell only when its side test gives one answer
for every fixed_t point of the cell. The test is the one of the game
(pointOnSide in src/iigs/r_iigs65.s):
  dx == 0: the integer part ix of x against node.x;
  dy == 0: the integer part iy of y against node.y;
  else xp = x - (node.x << 16), yp = y - (node.y << 16); when
  node.dy ^ node.dx ^ xp ^ yp < 0 the signs decide, else the low 32 bits
  of (yp >> 8) * node.dx and of (xp >> 8) * node.dy are compared.
The cell is cut at xp = 0 and yp = 0; in each part the signs are fixed,
and the products are monotone in each coordinate, so their extremes are at
the corners. A part where a product can pass 32 bits never decides.

The lump: cell size, origin x, origin y, columns, rows (int16 each), the
byte offset in the lump of each row (uint16), then one uint16 per cell,
row by row: a node number, or a subsector number with bit 15
(NF_SUBSECTOR) set. The game takes CELL = 64 (6 shifts).
Usage: sgrid.py WAD [MAP...]: the depth statistics of the maps.
"""

import struct
import sys

CELL = 64
NF_SUBSECTOR = 0x8000
NODE_SIZE = 28


def s32(v):
    v &= 0xffffffff
    return v - (1 << 32) if v & 0x80000000 else v


def read_nodes(data):
    """(x, y, dx, dy, children) of each node of a NODES lump."""
    nodes = []
    for i in range(len(data) // NODE_SIZE):
        x, y, dx, dy = struct.unpack_from('<hhhh', data, i * NODE_SIZE)
        c0, c1 = struct.unpack_from('<HH', data, i * NODE_SIZE + 24)
        nodes.append((x, y, dx, dy, (c0, c1)))
    return nodes


def side_of_point(node, x, y):
    """pointOnSide of the game for the fixed_t point (x, y)."""
    nx, ny, ndx, ndy, _ = node
    ix, iy = x >> 16, y >> 16
    if ndx == 0:
        return int(ndy < 0) if nx < ix else int(ndy > 0)
    if ndy == 0:
        return int(ndx >= 0) if ny < iy else int(ndx < 0)
    xp = s32(x - (nx << 16))
    yp = s32(y - (ny << 16))
    if (ndy ^ ndx ^ xp ^ yp) < 0:
        return int((ndy ^ xp) < 0)
    left = s32((yp >> 8) * ndx)
    right = s32((xp >> 8) * ndy)
    return int(left >= right)


def side_of_box(node, x0, x1, y0, y1):
    """The side of every fixed_t point of [x0, x1] x [y0, y1], or None."""
    nx, ny, ndx, ndy, _ = node
    if ndx == 0:
        a, b = (ndy < 0, ndy > 0)
        if nx < (x0 >> 16):
            return int(a)
        if nx >= (x1 >> 16):
            return int(b)
        return None
    if ndy == 0:
        if ny < (y0 >> 16):
            return int(ndx >= 0)
        if ny >= (y1 >> 16):
            return int(ndx < 0)
        return None
    ox, oy = nx << 16, ny << 16
    xs = [(x0, x1)]
    if x0 < ox <= x1:
        xs = [(x0, ox - 1), (ox, x1)]
    ys = [(y0, y1)]
    if y0 < oy <= y1:
        ys = [(y0, oy - 1), (oy, y1)]
    side = None
    for xa, xb in xs:
        for ya, yb in ys:
            xpa, xpb = xa - ox, xb - ox
            ypa, ypb = ya - oy, yb - oy
            if max(abs(xpa), abs(xpb), abs(ypa), abs(ypb)) >= 1 << 31:
                return None
            xneg, yneg = xpa < 0, ypa < 0        # fixed in this part
            if ((ndy < 0) ^ (ndx < 0) ^ xneg ^ yneg):
                s = int((ndy < 0) ^ xneg)
            else:
                ls = [(ypa >> 8) * ndx, (ypb >> 8) * ndx]
                rs = [(xpa >> 8) * ndy, (xpb >> 8) * ndy]
                if max(abs(v) for v in ls + rs) >= 1 << 31:
                    return None
                if min(ls) >= max(rs):
                    s = 1
                elif max(ls) < min(rs):
                    s = 0
                else:
                    return None
            if side is None:
                side = s
            elif side != s:
                return None
    return side


def build(nodes, orgx, orgy, cols, rows, cell=CELL):
    """The entry of each cell (row by row)."""
    root = len(nodes) - 1
    out = []
    for r in range(rows):
        for c in range(cols):
            x0 = (orgx + c * cell) << 16
            y0 = (orgy + r * cell) << 16
            x1 = x0 + (cell << 16) - 1
            y1 = y0 + (cell << 16) - 1
            n = root
            while not n & NF_SUBSECTOR:
                s = side_of_box(nodes[n], x0, x1, y0, y1)
                if s is None:
                    break
                n = nodes[n][4][s]
            out.append(n)
    return out


def lump(nodes, blockmap, cell=CELL):
    """The SGRID lump of a map from its NODES and BLOCKMAP lumps."""
    orgx, orgy, bw, bh = struct.unpack_from('<hhhh', blockmap, 0)
    cols = (bw * 128 + cell - 1) // cell
    rows = (bh * 128 + cell - 1) // cell
    cells = build(nodes, orgx, orgy, cols, rows, cell)
    first = 10 + 2 * rows
    rowofs = [first + 2 * cols * r for r in range(rows)]
    return (struct.pack('<hhhhh', cell, orgx, orgy, cols, rows) + struct.pack(f'<{rows}H', *rowofs)
            + struct.pack(f'<{len(cells)}H', *cells))


def depth_from(nodes, n, x, y):
    d = 0
    while not n & NF_SUBSECTOR:
        n = nodes[n][4][side_of_point(nodes[n], x, y)]
        d += 1
    return n, d


def main():
    sys.path.insert(0, __file__.rsplit('/', 1)[0])
    import doomview
    wad = doomview.Wad(sys.argv[1])
    maps = sys.argv[2:] or [f'E1M{m}' for m in range(1, 10)]
    import random
    rnd = random.Random(1)
    for name in maps:
        base = wad.index(name)
        nodes = read_nodes(wad.lumps[base + 7][1])
        bmap = wad.lumps[base + 10][1]
        orgx, orgy, bw, bh = struct.unpack_from('<hhhh', bmap, 0)
        for cell in (128, 64, 32):
            cols = (bw * 128 + cell - 1) // cell
            rows = (bh * 128 + cell - 1) // cell
            grid = build(nodes, orgx, orgy, cols, rows, cell)
            full = part = 0
            bad = 0
            for _ in range(3000):
                x = rnd.randrange(orgx << 16, (orgx + bw * 128) << 16)
                y = rnd.randrange(orgy << 16, (orgy + bh * 128) << 16)
                c = ((x >> 16) - orgx) // cell
                r = ((y >> 16) - orgy) // cell
                s1, d1 = depth_from(nodes, len(nodes) - 1, x, y)
                s2, d2 = depth_from(nodes, grid[r * cols + c], x, y)
                bad += s1 != s2
                full += d1
                part += d2
            print(f'{name} cell {cell:3d}: {cols}x{rows} = {cols * rows * 2} bytes, '
                  f'levels from the root {full / 3000:.1f}, from the grid {part / 3000:.2f}, mismatches {bad}')


if __name__ == '__main__':
    main()
