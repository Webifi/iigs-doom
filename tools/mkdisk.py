#!/usr/bin/env python3
"""Build bootable 800K Apple IIgs disk images (.po, ProDOS block order).

Each disk is a ProDOS volume DOOM.DISKn, so the Finder and disk tools see
its files:
  block 0        the boot block (src/iigs/boot.s)
  block 1        the disk header (src/iigs/loader.s); ProDOS does not use it
  blocks 2-5     the volume directory
  block 6        the volume bitmap
  DOOM.BOOT      the loader: index block 7, data blocks 8-19 (the boot
                 block reads them)
  DOOM.DATAn     the data of the segments of the disk, in contiguous blocks
                 from block 20 (the loader reads them by block number), then
                 its index blocks
  DOOM.SETTINGS  on disk 1: one block with the settings and the saved
                 games of the game (src/iigs/m_config65.s). The loader loads
                 it to SETTINGS_ADDR as a segment; the game writes the block
                 again when a setting changes, if disk 1 is in the drive and
                 can take writes. The loader and the level loader leave
                 disk 1 in the drive.
  README         a text file

The data is split over as many disks as needed. With --hd FILE, one
volume DOOM for a hard disk (a CFFA3000, FloppyEmu in SmartPort mode, an
emulator) gets all the data in DOOM.DATA and DOOM.SETTINGS: the same loader
and game code, one "disk", no disk change. With --scsi FILE, the same volume
in a device image with an Apple partition map (APM_PART), for the SCSI
cards of Apple (with a BlueSCSI): the card firmware finds the ProDOS
partition and gives the loader the blocks of the partition. With --picture
LUMP, the
first 64 blocks of that lump of a WAD in the data (an SHR picture of
tools/gscolor.py: bytes 0-32767 are an image of the screen memory) come
first on disk 1, as a segment with the flag SEG_PIC: the palettes, the row
palettes, then the pixel blocks in an interlaced order, so the picture
shows early in the load. PIC_ORDER in the header gives the picture block of
each of them. --picture-file FILE@ADDR gives the picture as a file.

--store FILE@ADDR: the level store (tools/levelimg.py) at the address of an
8 MB IIgs; it goes after all other data. A 4 MB IIgs loads only the disks
up to HDR_RESDISKS at boot and reads the store blocks when a level starts
(src/iigs/w_level65.s): HDR_STOREMAP in each header gives each run of
store blocks (the first store block, the count, the first disk block, the
disk), HDR_STOREBANKS the banks of the store.

Usage:
  mkdisk.py --boot boot.raw --loader loader.raw --elf doom.elf
            [--data FILE@ADDR ...] [--picture LUMP] [--hd FILE] [--scsi FILE]
            --out build/disk
"""

import argparse
import datetime
import os
import struct
import sys
import zlib

import b1

BLOCK = 512
DISK_BLOCKS = 1600
DIR_BLOCKS = (2, 3, 4, 5)       # the volume directory
BITMAP_BLOCK = 6                # the bitmap: blocks 6-7 at most (8192 blocks)
HD_FREE = 256                   # free blocks on the hard disk volume
APM_PART = 64                   # --scsi: the first block of the partition
LOADER_FIRST = 8                # STAGE2_BLOCK and STAGE2_COUNT of boot.s
LOADER_BLOCKS = 6
DATA_FIRST = LOADER_FIRST + LOADER_BLOCKS
HDR_STOREMAP = 368              # header: for each run of the store (up to
STOREMAP_MAX = 8                #   8): the first store block, the count,
                                #   the first disk block (3 words), the
                                #   disk (a word)
HDR_BUILD = 432                 # the build ID (4 bytes), the same on all
HDR_SETTINGS = 436              #   disks; the block of DOOM.SETTINGS on
HDR_RESDISKS = 438              #   disk 1; the last disk with data for
HDR_STOREBANKS = 439            #   below the store; the banks of the store
PIC_ORDER = 448                 # the picture block order
MAX_SEGMENTS = (HDR_STOREMAP - 16) // 8
LOAD_CELLS = 34                 # the cells of the load bar for the load,
                                #   as LOAD_CELLS of src/iigs/loadbar.inc
SEG_PIC = 1
SEG_B1 = 2                      # the segment is the B1 stream of its data
                                #   (tools/b1.py: u16 the length, then B1)
PIC_BLOCKS = 64
SETTINGS_ADDR = 0x007c00        # SETTINGS_IN of src/iigs/m_config65.s

# ProDOS file types and access bits
TYPE_TXT, TYPE_BIN, TYPE_CFG = 0x04, 0x06, 0x5a
READ, WRITE, RENAME, DESTROY = 0x01, 0x02, 0x40, 0x80
INVISIBLE = 0x04                # GS/OS: the Finder does not show the file

README = """Doom for the Apple IIgs
Doom8088: Apple IIgs Edition

Disk {n} of {total}

To play, put disk 1 in the 3.5-inch drive and start the IIgs. The game
needs an accelerator and 4 MB of memory. It asks for the other disks: with
4 MB when a level starts, with 8 MB once at the start. With two drives,
keep disk 1 in the first one and put the others in the second one.

The game saves its settings and saved games in the file DOOM.SETTINGS on
disk 1 (it asks for disk 1 when you save). When disk 1 is locked, they
stay in memory only.
"""

README_HD = """Doom for the Apple IIgs
Doom8088: Apple IIgs Edition

To play, start the IIgs from this volume. The game needs an accelerator
and 4 MB of memory. It saves its settings and saved games in the file
DOOM.SETTINGS on this volume; when the volume is locked, it keeps them in
memory only.
"""


def picture_order():
    """The palettes (block 63), the row palettes (62), then the pixel
    blocks: every 8th, the 4th ones between them, the 2nd ones, the rest."""
    order = [63, 62]
    for start, step in ((0, 8), (4, 8), (2, 4), (1, 2)):
        order += [b for b in range(start, 62, step) if b not in order]
    return order


def wad_lump(data, name):
    """The offset of lump name in the WAD bytes data, or None."""
    if data[:4] not in (b'IWAD', b'PWAD'):
        return None
    n, off = struct.unpack_from('<ii', data, 4)
    for i in range(n):
        pos, size, nm = struct.unpack_from('<ii8s', data, off + 16 * i)
        if nm.rstrip(b'\0').decode() == name:
            return pos
    return None


def elf_segments(path):
    data = open(path, 'rb').read()
    if data[:4] != b'\x7fELF':
        sys.exit(f'{path}: not an ELF file')
    if data[4] != 1:
        sys.exit(f'{path}: expected ELF32')
    endian = '<' if data[5] == 1 else '>'
    (e_entry, e_phoff, _e_shoff, _flags, _ehsize, e_phentsize, e_phnum) = \
        struct.unpack_from(endian + 'IIIIHHH', data, 24)
    segments = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, _memsz, _flags, _align = \
            struct.unpack_from(endian + 'IIIIIIII', data, off)
        if p_type == 1 and p_filesz > 0:
            if 0x00dc00 <= p_paddr < 0x00df00:
                if p_paddr + p_filesz > 0x00df00:
                    sys.exit('IRQ execution section crosses its reserved range')
                p_paddr -= 0x2200  # $DC00-$DEFF executes; $BA00-$BCFF loads
            segments.append((p_paddr, data[p_offset:p_offset + p_filesz]))
    return e_entry, segments


def compress_runs(runs, below, cache):
    """The runs below address below as B1 segments: each run in chunks
    that do not cross a bank, a chunk compressed when that saves a block
    (else it stays a raw run). Runs of 3 items (store regions) stay."""
    out = []
    for run in runs:
        if len(run) == 3 or run[0] >= below:
            out.append(run)
            continue
        addr, payload = run
        pos = 0
        while pos < len(payload):
            a = addr + pos
            n = min(len(payload) - pos, 0x10000 - (a & 0xffff))
            data = payload[pos:pos + n]
            enc = struct.pack('<H', n & 0xffff) + b1.compress(data, cache)
            enc += bytes(-len(enc) % BLOCK)
            if len(enc) + BLOCK <= n:           # (a length of 64 KB is 0)
                out.append((a, enc, 'b1'))
            else:
                out.append((a, data))
            pos += n
    return out


def merge(segments):
    """Merge segments into runs of consecutive 512 byte blocks."""
    blocks = {}
    for addr, payload in segments:
        pos = 0
        while pos < len(payload):
            a = addr + pos
            blk = a & ~(BLOCK - 1)
            off = a - blk
            n = min(BLOCK - off, len(payload) - pos)
            b = blocks.setdefault(blk, bytearray(BLOCK))
            b[off:off + n] = payload[pos:pos + n]
            pos += n
    runs = []
    for blk in sorted(blocks):
        if runs and runs[-1][0] + len(runs[-1][1]) == blk:
            runs[-1][1].extend(blocks[blk])
        else:
            runs.append([blk, bytearray(blocks[blk])])
    return [(a, bytes(b)) for a, b in runs]


# --------------------------------------------------------------------------
# ProDOS volumes

def index_blocks(n):
    """The index blocks of a ProDOS file of n data blocks: none (seedling),
    one (sapling), or a master index and one for each 256 (tree)."""
    if n <= 1:
        return 0
    if n <= 256:
        return 1
    return 1 + -(-n // 256)


def data_capacity():
    """Data blocks with README and its index; caller reserves disk-1 settings."""
    readme_blocks = -(-len(README.format(n=9, total=9).encode()) // BLOCK)
    overhead = readme_blocks + index_blocks(readme_blocks)
    n = DISK_BLOCKS - DATA_FIRST
    while DATA_FIRST + n + index_blocks(n) + overhead > DISK_BLOCKS:
        n -= 1
    return n


def bitmap_blocks(blocks):
    return -(-blocks // (8 * BLOCK))


def prodos_time(t):
    """A ProDOS date and time (a year of 0-39 is 2000-2039)."""
    return struct.pack('<HH', (t.year % 100) << 9 | t.month << 5 | t.day,
                       t.hour << 8 | t.minute)


def index_block(pointers):
    """An index block (or master index block): the low bytes of the block
    numbers, then the high bytes at 256."""
    b = bytearray(BLOCK)
    for i, p in enumerate(pointers):
        b[i] = p & 0xff
        b[256 + i] = p >> 8
    return b


class Volume:
    """A ProDOS volume image: the boot and header blocks, the volume
    directory and bitmap, and files with their data in chosen blocks."""

    def __init__(self, name, blocks, stamp):
        self.name = name
        self.blocks = blocks
        self.stamp = stamp
        self.img = bytearray(blocks * BLOCK)
        self.free = [True] * blocks
        self.bitmap = range(BITMAP_BLOCK, BITMAP_BLOCK + bitmap_blocks(blocks))
        if self.bitmap[-1] >= LOADER_FIRST:
            sys.exit(f'{name}: {blocks} blocks, the bitmap reaches the loader')
        for b in (0, 1, *DIR_BLOCKS, *self.bitmap):
            self.free[b] = False
        self.entries = []

    def write(self, block, data):
        self.img[block * BLOCK:block * BLOCK + len(data)] = data

    def take(self, blocks):
        for b in blocks:
            if not self.free[b]:
                sys.exit(f'{self.name}: block {b} used twice')
            self.free[b] = False

    def alloc(self):
        b = self.free.index(True)
        self.free[b] = False
        return b

    def add_file(self, name, ftype, aux, access, data, blocks=None):
        """File name with data in blocks (a list of block numbers), else in
        the first free blocks; its index blocks go to the first free
        blocks after that."""
        n = max(1, -(-len(data) // BLOCK))
        if blocks is None:
            blocks = [self.alloc() for _ in range(n)]
        else:
            blocks = list(blocks)
            if len(blocks) != n:
                sys.exit(f'{name}: {n} blocks of data, {len(blocks)} blocks given')
            self.take(blocks)
        for i, b in enumerate(blocks):
            self.write(b, data[i * BLOCK:(i + 1) * BLOCK])
        if n == 1:
            storage, key, used = 1, blocks[0], 1
        elif n <= 256:
            storage, key, used = 2, self.alloc(), n + 1
            self.write(key, index_block(blocks))
        else:
            storage, key = 3, self.alloc()
            subs = []
            for i in range(0, n, 256):
                subs.append(self.alloc())
                self.write(subs[-1], index_block(blocks[i:i + 256]))
            self.write(key, index_block(subs))
            used = n + 1 + len(subs)
        e = bytearray(39)
        e[0] = storage << 4 | len(name)
        e[1:1 + len(name)] = name.encode()
        e[16] = ftype
        struct.pack_into('<HH', e, 17, key, used)
        e[21:24] = len(data).to_bytes(3, 'little')
        e[24:28] = self.stamp
        e[30] = access
        struct.pack_into('<H', e, 31, aux)
        e[33:37] = self.stamp
        struct.pack_into('<H', e, 37, DIR_BLOCKS[0])
        self.entries.append(e)
        return blocks

    def image(self):
        """The image with the volume directory and the bitmap."""
        h = bytearray(39)
        h[0] = 0xf0 | len(self.name)
        h[1:1 + len(self.name)] = self.name.encode()
        h[24:28] = self.stamp
        h[30] = READ | WRITE | RENAME | DESTROY
        h[31] = 39                              # entry length
        h[32] = 13                              # entries in a block
        struct.pack_into('<HHH', h, 33, len(self.entries), BITMAP_BLOCK, self.blocks)
        slots = [h] + self.entries
        if len(slots) > 13 * len(DIR_BLOCKS):
            sys.exit(f'{self.name}: too many files')
        for i, blk in enumerate(DIR_BLOCKS):
            b = bytearray(BLOCK)
            struct.pack_into('<HH', b, 0, DIR_BLOCKS[i - 1] if i else 0,
                             DIR_BLOCKS[i + 1] if i + 1 < len(DIR_BLOCKS) else 0)
            for k, e in enumerate(slots[13 * i:13 * (i + 1)]):
                b[4 + 39 * k:4 + 39 * (k + 1)] = e
            self.write(blk, b)
        bitmap = bytearray(BLOCK * len(self.bitmap))
        for b in range(self.blocks):
            if self.free[b]:
                bitmap[b >> 3] |= 0x80 >> (b & 7)
        self.write(BITMAP_BLOCK, bitmap)
        return bytes(self.img)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--boot', required=True)
    ap.add_argument('--loader', required=True)
    ap.add_argument('--elf', required=True)
    ap.add_argument('--entry', type=lambda s: int(s, 0))
    ap.add_argument('--data', action='append', default=[],
                    help='FILE@ADDR, loaded at a 512 byte aligned address')
    ap.add_argument('--picture', help='the WAD lump to show while the disks load')
    ap.add_argument('--picture-file', help='FILE@ADDR: first 32 KB of the SHR picture file (the boot screen)')
    ap.add_argument('--store', help='FILE@ADDR: the level store, after all other data')
    ap.add_argument('--boot-song', help='INTRO unit FILE@ADDR, reusing its aligned store streams')
    ap.add_argument('--store-regions', help='a file of the store offsets where the region of '
                    'each disk starts (tools/levelimg.py): region n goes to disk n')
    ap.add_argument('--data-list', action='append', default=[],
                    help='a file of FILE@ADDR lines, as --data (unaligned addresses allowed)')
    ap.add_argument('--hd', help='also one volume with all the data, for a hard disk')
    ap.add_argument('--hd-store', help='FILE@ADDR: the store of the hard disk volume (raw units: '
                    'a hard disk reads faster than B1 decodes), else --store')
    ap.add_argument('--scsi', help='also that volume with an Apple partition map')
    ap.add_argument('--out', required=True, help='output name prefix')
    ap.add_argument('--compress', action='store_true',
                    help='the data below the store as B1 segments (the loader decodes them)')
    ap.add_argument('--b1cache', help='the cache directory of tools/b1.py')
    args = ap.parse_args()

    boot = open(args.boot, 'rb').read()
    loader = open(args.loader, 'rb').read()
    if len(boot) > BLOCK:
        sys.exit('boot block too large')
    if len(loader) > LOADER_BLOCKS * BLOCK:
        sys.exit('loader too large')
    loader = loader.ljust(LOADER_BLOCKS * BLOCK, b'\0')

    entry, segments = elf_segments(args.elf)
    if args.entry is not None:
        entry = args.entry
    for spec in args.data:
        path, addr = spec.rsplit('@', 1)
        addr = int(addr, 0)
        if addr % BLOCK:
            sys.exit(f'{spec}: address not block aligned')
        segments.append((addr, open(path, 'rb').read()))
    for lst in args.data_list:
        for spec in open(lst).read().split():
            path, addr = spec.rsplit('@', 1)
            segments.append((int(addr, 0), open(path, 'rb').read()))
    store = None
    if args.store:
        path, addr = args.store.rsplit('@', 1)
        store = (int(addr, 0), open(path, 'rb').read())
        if store[0] % BLOCK:
            sys.exit(f'{args.store}: address not block aligned')
    pic = None
    picfile = None
    if args.picture_file:
        path, addr = args.picture_file.rsplit('@', 1)
        pic = int(addr, 0)
        picfile = open(path, 'rb').read()
        if pic % BLOCK or len(picfile) < PIC_BLOCKS * BLOCK:
            sys.exit(f'{args.picture_file}: less than {PIC_BLOCKS} blocks, or not at a block')
        # Only the SHR screen is needed at boot. The extra 4 KB of the
        # game's picture record is loaded by W_LoadSet with the title;
        # retaining it here would overwrite INTRO at $2A8000.
        segments.append((pic, picfile[:PIC_BLOCKS * BLOCK]))
    if args.picture:
        for addr, payload in segments:
            pos = wad_lump(payload, args.picture)
            if pos is not None:
                pic = addr + pos
                break
        if pic is None:
            sys.exit(f'{args.picture}: no such lump in the data')
        if pic % BLOCK:
            sys.exit(f'{args.picture}: not block aligned')

    spans = sorted((a, a + len(p)) for a, p in segments)
    boot_song = None
    if args.boot_song:
        path, addr = args.boot_song.rsplit('@', 1)
        boot_song = (int(addr, 0), open(path, 'rb').read())
        spans.append((boot_song[0], boot_song[0] + len(boot_song[1])))
        spans.sort()
    for (a0, e0), (a1, e1) in zip(spans, spans[1:]):
        if a1 < e0:
            sys.exit(f'data at ${a1:06X}-${e1:06X} overlaps data at ${a0:06X}-${e0:06X}')

    runs = merge(segments)
    if store is not None:
        # data above the store (8 MB only: the loader loads the banks from
        # $40 only with the store) goes after it on the disks
        send = store[0] + len(store[1])
        if any(a < send and a + len(p) > store[0] for a, p in runs):
            sys.exit('data inside the store')
        sruns = merge([store])
        if args.store_regions:
            regs = [int(x) for x in open(args.store_regions).read().split()] + [len(store[1])]
            sruns = []
            for r, (a0, a1) in enumerate(zip(regs, regs[1:])):
                a0 = 0 if r == 0 else a0
                piece = store[1][a0:a1]
                piece += bytes(-len(piece) % BLOCK)
                sruns.append((store[0] + a0, piece, r + 1))
        runs = [r for r in runs if r[0] < store[0]] + sruns + \
            [r for r in runs if r[0] >= send]
    picdata = None
    if pic is not None:
        # take the picture blocks out of the runs; they go first
        blocks = {}
        rest = []
        for run in runs:
            if len(run) == 3:
                continue                            # (a store region: no picture)
            addr, payload = run[0], run[1]
            for i in range(len(payload) // BLOCK):
                a = addr + i * BLOCK
                if pic <= a < pic + PIC_BLOCKS * BLOCK:
                    blocks[(a - pic) // BLOCK] = payload[i * BLOCK:(i + 1) * BLOCK]
                else:
                    rest.append((a, payload[i * BLOCK:(i + 1) * BLOCK]))
        keep = [r for r in runs if len(r) == 3]           # (the store regions stay)
        runs = sorted(merge(rest) + keep, key=lambda r: r[0])
        picdata = b''.join(blocks[b] for b in picture_order())
    # the hard disk volume: the data as it is, and its own store
    hd_runs = [r[:2] for r in runs if not (store and store[0] <= r[0] < store[0] + len(store[1]))]
    hd_store = store
    if args.hd_store:
        path, addr = args.hd_store.rsplit('@', 1)
        hd_store = (int(addr, 0), open(path, 'rb').read())
    if hd_store:
        hd_runs = sorted(hd_runs + merge([hd_store]), key=lambda r: r[0])
    if args.compress:
        runs = compress_runs(runs, store[0] if store else 1 << 24, args.b1cache)
    total_blocks = sum(len(r[1]) // BLOCK for r in runs) + (PIC_BLOCKS if pic is not None else 0)
    step = max(1, -(-total_blocks // LOAD_CELLS))
    if step > 255:
        sys.exit('too much data for the progress bar step')

    # Split the runs over disks: (address, data, flags) segments. Disk 1
    # holds DOOM.SETTINGS too.
    capacity = data_capacity()
    disks = []
    cur = []
    free = capacity - 1
    if picdata:
        cur.append((pic, picdata, SEG_PIC))
        free -= PIC_BLOCKS
    for run in runs:
        addr, payload = run[0], run[1]
        want = run[2] if len(run) == 3 and run[2] != 'b1' else None  # a store region: its disk
        if len(run) == 3 and run[2] == 'b1':
            n = len(payload) // BLOCK           # a B1 segment: whole on one disk
            if n > free or len(cur) == MAX_SEGMENTS - 1:
                disks.append(cur)
                cur = []
                free = capacity
            cur.append((addr, payload, SEG_B1))
            free -= n
            continue
        if want is not None:
            if want < len(disks) + 1:
                sys.exit(f'store region {want}: disk {len(disks) + 1} is full')
            while len(disks) + 1 < want:
                disks.append(cur)
                cur = []
                free = capacity
            if len(payload) // BLOCK > free:
                sys.exit(f'store region {want}: {len(payload) // BLOCK} blocks, disk {want} has {free}')
        pos = 0
        nblocks = len(payload) // BLOCK
        while pos < nblocks:
            if free == 0 or len(cur) == MAX_SEGMENTS - 1:
                disks.append(cur)
                cur = []
                free = capacity
            n = min(free, nblocks - pos)
            cur.append((addr + pos * BLOCK, payload[pos * BLOCK:(pos + n) * BLOCK], 0))
            pos += n
            free -= n
    if cur:
        disks.append(cur)

    build = zlib.crc32(loader)
    for segs in disks:
        for _, payload, _ in segs:
            build = zlib.crc32(payload, build)
    # Directory dates follow SOURCE_DATE_EPOCH (UTC). The Makefile sets it so
    # two clean builds of the same source match byte for byte.
    raw = os.environ.get('SOURCE_DATE_EPOCH')
    if raw:
        when = datetime.datetime.fromtimestamp(int(raw), datetime.timezone.utc)
    else:
        when = datetime.datetime(2026, 9, 27, 0, 0, tzinfo=datetime.timezone.utc)
    stamp = prodos_time(when)
    # the last disk with data below the store, the store map (filled in by
    # volume: the first data block of each disk)
    sbase = store[0] if store else 1 << 24
    send = store[0] + len(store[1]) if store else 1 << 24
    resdisks = max([n for n, segs in enumerate(disks, 1) if any(a < sbase for a, _, _ in segs)] or [1])
    sbanks = -(-len(store[1]) // 0x10000) if store else 0
    common = dict(stamp=stamp, boot=boot, loader=loader, entry=entry, step=step, build=build,
                  sbase=sbase, send=send, resdisks=resdisks, sbanks=sbanks)
    common['boot_aliases'] = song_aliases(store, boot_song) if boot_song else []

    # the store map: for each disk its store blocks (the data file of each
    # disk starts at the first free block after the loader)
    first = data_first()
    smap = []
    for num, segs in enumerate(disks, 1):
        block = first
        for addr, payload, flags in segs:
            if sbase <= addr < send:
                sb = (addr - sbase) // BLOCK
                smap.append((sb, len(payload) // BLOCK, block, num))
            block += len(payload) // BLOCK
    if len(smap) > STOREMAP_MAX:
        sys.exit(f'{len(smap)} store runs, more than {STOREMAP_MAX}')
    for num, segs in enumerate(disks, 1):
        out = f'{args.out}{num}.po'
        img = volume(f'DOOM.DISK{num}', DISK_BLOCKS, segs, num, len(disks), f'DOOM.DATA{num}',
                     README.format(n=num, total=len(disks)), out, smap=smap, **common)
        open(out, 'wb').write(img)
    if args.hd:
        segs = ([(pic, picdata, SEG_PIC)] if picdata else []) + [(a, p, 0) for a, p in hd_runs]
        n = sum(len(p) // BLOCK for _, p, _ in segs)
        blocks = LOADER_FIRST + LOADER_BLOCKS + 1 + n + index_blocks(n) + 2 + HD_FREE
        hd = dict(common, resdisks=1)
        hd['boot_aliases'] = song_aliases(hd_store, boot_song) if boot_song else []
        if hd_store:
            hd.update(sbase=hd_store[0], send=hd_store[0] + len(hd_store[1]),
                      sbanks=-(-len(hd_store[1]) // 0x10000))
        img = volume('DOOM', (blocks + 7) & ~7, segs, 1, 1, 'DOOM.DATA', README_HD, args.hd,
                     smap=None, **hd)
        open(args.hd, 'wb').write(img)
        if args.scsi:
            open(args.scsi, 'wb').write(partitioned(img))
            print(f'{args.scsi}: the volume at block {APM_PART} of an Apple partition map')
    print(f'entry ${entry:06X}, {total_blocks} blocks, {len(disks)} disk(s), build {build:08X}')


def partitioned(volume_img):
    """A device image: an Apple partition map (the driver descriptor in
    block 0, the map entries from block 1: the map, the ProDOS partition)
    and the volume at block APM_PART."""
    blocks = APM_PART + len(volume_img) // BLOCK
    img = bytearray(APM_PART * BLOCK) + volume_img
    struct.pack_into('>2sHI', img, 0, b'ER', BLOCK, blocks)
    parts = ((b'Apple', b'Apple_partition_map', 1, APM_PART - 1),
             (b'DOOM', b'Apple_PRODOS', APM_PART, blocks - APM_PART))
    for i, (name, ptype, start, count) in enumerate(parts):
        e = 512 * (1 + i)
        struct.pack_into('>2sHIII32s32sII', img, e, b'PM', 0, len(parts), start, count,
                         name, ptype, 0, count)
        struct.pack_into('>I', img, e + 88, 0x37)       # valid, allocated, in use,
    return bytes(img)                                   #   readable, writable


def data_first():
    """The first block of the data file: after the loader (its index
    block is block 7)."""
    return DATA_FIRST


def song_aliases(store, song):
    """Validate and reference INTRO chunks already present in the level store."""
    base, data = store
    dest, expected = song
    count, = struct.unpack_from('<H', data, 6)
    for k in range(count):
        off, n, _, disk, _, _ = struct.unpack_from('<IHBBHH', data, 8 + 12*k)
        active = False
        rebuilt = bytearray()
        aliases = []
        for j in range(n):
            e = data[off+10*j:off+10*j+10]
            kind, = struct.unpack_from('<H', e)
            src = int.from_bytes(e[5:8], 'little')
            length, = struct.unpack_from('<H', e, 8)
            if 0xffe0 <= kind < 0xfff0:
                active = kind == 0xffea
            elif active and kind == 0xfffc:
                raw, = struct.unpack_from('<H', data, src-base)
                part = b1.decode(data[src-base+2:src-base+length], raw)
                address = dest + len(rebuilt)
                if disk != 1 or src % BLOCK or (address & 0xffff) + raw > 0x10000:
                    raise ValueError('INTRO boot stream must be aligned, bank-safe and on disk 1')
                aliases.append((address, src, -(-length // BLOCK)))
                rebuilt += part
            elif active and kind == 0xfffb:
                if rebuilt != expected:
                    raise ValueError('INTRO boot alias differs from the song unit')
                return aliases
    raise ValueError('INTRO boot song not found in the store')


def volume(name, blocks, segs, num, ndisks, dataname, readme, out, stamp, boot, loader, entry,
           step, build, sbase, send, resdisks, sbanks, smap, boot_aliases=()):
    """The ProDOS volume image of disk num of ndisks with the segments segs
    (address, data, flags): the boot block, the header, DOOM.BOOT, the data
    file, DOOM.SETTINGS on disk 1, README."""
    vol = Volume(name, blocks, stamp)
    vol.write(0, boot)
    vol.add_file('DOOM.BOOT', TYPE_BIN, 0x6000, READ | INVISIBLE, loader,
                 range(LOADER_FIRST, LOADER_FIRST + LOADER_BLOCKS))
    data = b''.join(payload for _, payload, _ in segs)
    n = len(data) // BLOCK
    first = vol.free.index(True)
    if smap is None:
        # one volume (a hard disk): its store blocks, as one run
        smap = []
        block = first
        for addr, payload, flags in segs:
            cnt = len(payload) // BLOCK
            if sbase <= addr < send:
                sb = (addr - sbase) // BLOCK
                if smap and smap[-1][0] + smap[-1][1] == sb and smap[-1][2] + smap[-1][1] == block:
                    smap[-1] = (smap[-1][0], smap[-1][1] + cnt, smap[-1][2], 1)
                else:
                    smap.append((sb, cnt, block, 1))
            block += cnt
    elif first != data_first():
        sys.exit(f'{name}: the data starts at block {first}, not {data_first()}')
    vol.add_file(dataname, TYPE_BIN, 0, READ, data, range(first, first + n))
    hdr = bytearray(BLOCK)
    hdr[0:6] = b'DOOMGS'
    hdr[6] = num
    hdr[7] = ndisks
    struct.pack_into('<I', hdr, 10, entry & 0xffffff)
    struct.pack_into('<H', hdr, 14, step)
    struct.pack_into('<I', hdr, HDR_BUILD, build)
    block = first
    headsegs = []
    for addr, payload, flags in segs:
        headsegs.append((addr | flags << 24, block, len(payload) // BLOCK))
        block += len(payload) // BLOCK
        if flags & SEG_PIC:
            hdr[PIC_ORDER:PIC_ORDER + PIC_BLOCKS] = bytes(picture_order())
    if num == 1:
        for dest, src, count in boot_aliases:
            block = first
            for addr, payload, flags in segs:
                if flags == 0 and addr <= src and src + count*BLOCK <= addr + len(payload):
                    headsegs.append((dest | SEG_B1 << 24, block + (src-addr)//BLOCK, count))
                    break
                block += len(payload)//BLOCK
            else:
                raise ValueError('INTRO boot alias is outside disk-1 data')
    if num == 1:
        sblock = vol.add_file('DOOM.SETTINGS', TYPE_CFG, 0, READ | WRITE | RENAME | DESTROY,
                              bytes(BLOCK))[0]
        struct.pack_into('<H', hdr, HDR_SETTINGS, sblock)
        headsegs.append((SETTINGS_ADDR, sblock, 1))
    hdr[HDR_RESDISKS] = resdisks
    hdr[HDR_STOREBANKS] = sbanks
    for i, (sb, cnt, db, disk) in enumerate(smap):
        struct.pack_into('<HHHH', hdr, HDR_STOREMAP + 8 * i, sb, cnt, db, disk)
    if len(headsegs) > MAX_SEGMENTS:
        sys.exit(f'{name}: {len(headsegs)} segments, more than {MAX_SEGMENTS}')
    hdr[8] = len(headsegs)
    for i, seg in enumerate(headsegs):
        struct.pack_into('<IHH', hdr, 16 + i * 8, *seg)
    vol.write(1, hdr)
    vol.add_file('README', TYPE_TXT, 0, READ | WRITE | RENAME | DESTROY,
                 readme.replace('\n', '\r').encode())
    print(f'{out}: {len(headsegs)} segments, {n} data blocks, {sum(vol.free)} of {blocks} '
          f'blocks free')
    return vol.image()


if __name__ == '__main__':
    main()
