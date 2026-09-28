;;; The fixed data addresses of the game (the memory map of
;;; src/iigs/iigs.scm). Only banks $00-$0D and $10-$3F: they are the banks
;;; that every 4 MB IIgs has (a ROM 03 has no $0E-$0F, MAME -ramsize 4M no
;;; $40). The level window (src/iigs/w_level65.s) takes the banks after
;;; these and the extra banks found at boot.
;;;
;;; A hot table keeps the low 15 bits of its old address, so it keeps its
;;; cache slots (slot = address & $7FFF); a table may move to the other half
;;; of a bank ($8000 more or less) for the same reason. The files keep their
;;; own names (SQL .equ MM_SQL).

#if !defined MEMMAP_INC
#define MEMMAP_INC 1

;;; Bank 06-09: the zone (src/iigs/z_zone65.s).
MM_ZONE_FIRST .equ    0x06
MM_ZONE_LAST  .equ    0x09

;;; Bank 0A: SIGHTHINT | the mobj pool map, the drawseg columns, the view
;;; window and the view size sites (at $B500-$B9FF as in their old bank
;;; $4E), the weapon skip, the weapon profiles.
MM_SIGHTHINT  .equ    0x0a0000        ; src/iigs/p_sight65.s
MM_TP_MAP     .equ    0x0a8000        ; TP_BITS, TP_MASK (+ $40) of
                                      ;   src/iigs/p_spawn65.s: 96 bytes
MM_BV         .equ    0x0a0000        ; + $B500-$B9FF: dscols.inc, viewwin.inc,
                                      ;   HV_* of src/iigs/r_thing65.s
MM_WCLIP      .equ    0x0ac500        ; WCLIP, WPREV, WTMP (src/iigs/lists.inc)
MM_WPROF      .equ    0x0ac800        ; + $A0, and the arenas at $D000-$E3FF and
                                      ;   $ED00-$FEFF: the weapon profiles
                                      ;   (src/iigs/r_sprite65.s)
MM_WPOK       .equ    0x0ac84a        ; 0x5aa5: FR_VIS holds the weapon of this
                                      ;   frame's clip pass (wcDraw3, pspDraw0)

;;; Bank 0B: GW_TAB | the nibble tables, the copy of the level for a new
;;; life.
MM_GW_TAB     .equ    0x0b0000        ; src/iigs/p_path65.s
MM_NIBTAB     .equ    0x0b8000        ; 16 palettes x 1 KB (src/iigs/patch65.s)
MM_BRL        .equ    0x0b0000        ; + $C000-$FEFF: RL_* of p_setup65.s

;;; Bank 0C: FL_IDX + the low word of a sector address: any, so all of it.
MM_FL_IDX     .equ    0x0c002c        ; src/iigs/p_pspr65.s

;;; Bank 10-12: the resident WAD (tools/levelimg.py). The level lumps are
;;; in the level window.
MM_WAD        .equ    0x100000
MM_WAD_BANK   .equ    0x10

;;; Bank 13-21: the tables of whole banks.
MM_SQL        .equ    0x130000        ; the quarter squares, 4 banks each
MM_SQH        .equ    0x170000        ;   (src/iigs/m_fixed65.s)
MM_FSTEP      .equ    0x1b0000        ; 2 banks (src/iigs/m_recip65.s)
MM_RECBASE    .equ    0x1d0000        ; the column records (src/iigs/lists.inc)
MM_RECBANK    .equ    0x1d
MM_VTXHASH    .equ    0x1d0000        ; used at level load only, before any
                                      ;   record (src/iigs/i_viigs65.s)
MM_RECIP      .equ    0x1e0000        ; src/iigs/m_recip65.s
MM_LOGTAB     .equ    0x1f0000        ; build/tables/log.bin
MM_SINE       .equ    0x200000        ; build/tables/sine.bin (64 KB)
MM_B3F        .equ    0x210000        ; + the offsets of the old bank $3F: the
                                      ;   sight and move tables of the map
                                      ;   (p_sight65.s, p_map65.s, p_trace65.s,
                                      ;   p_path65.s, p_pspr65.s, p_setup65.s),
                                      ;   up to $F421

;;; Bank 22: the sprite tables | GSTAMP, the view under the menu or SQMID.
MM_SPRXSCALE  .equ    0x220000        ; src/iigs/r_thing65.s
MM_SPRYSCALE  .equ    0x222000
MM_SPRISCALE  .equ    0x224000
MM_FQ         .equ    0x226000
MM_SPRBOUND   .equ    0x227800
MM_GSTAMP     .equ    0x228000        ; a word a line (p_path65.s)
MM_VIEWSAVE   .equ    0x229000        ; 160 x 168 bytes (src/iigs/i_viigs65.s):
                                      ;   the view under an open menu. Else SQMID
                                      ;   (src/iigs/p_trace65.s, 16,354 bytes at
                                      ;   + 0), made by sqmInit at each level load
                                      ;   and when the menu closes: a new writer
                                      ;   outside a menu must call sqmInit after
                                      ;   it. The level loader and its signs
                                      ;   (LOADING, INSERT DISK: MM_BUSY) do not
                                      ;   write here.

;;; Bank 23: the vertex angles and their frames | the automap line table,
;;; the fill spans (3 KB in cache slots $6F00-$7AFF that no hot code uses:
;;; FS_ROW and CV_ROW are read for each sprite record, 2026-09-27).
MM_SEGANGLE   .equ    0x230000        ; a word a vertex (src/iigs/r_bsp65.s)
MM_SEGSTAMP   .equ    0x234000
MM_AMKEY      .equ    0x238c00        ; LV_KEY, LV_OK, AM_VFR of am_map65.s
MM_LVTAB      .equ    0x239000        ; LV_TAB: 4 bytes a line, 3072 lines
MM_FS         .equ    0x23ef00        ; FS_*, CV_* (src/iigs/lists.inc)

;;; Bank 24: the vertex numbers of the seg ends | the sound flood entries,
;;; the status bar rows of the screen under the menu, the automap points.
MM_SEGVTX     .equ    0x240000        ; 4 bytes a seg
MM_SEGVTX_MAX .equ    8192
MM_FL_ENT     .equ    0x248000        ; src/iigs/p_pspr65.s
MM_VIEWSAVE2  .equ    0x24a000        ; 5,120 bytes (the rest of the screen:
                                      ;   MM_VIEWSAVE has the view)
MM_VSTAB      .equ    0x24b400        ; the automap point cache: VS_TAB of
MM_VSMAXV     .equ    2432            ;   src/iigs/am_map65.s, 8 bytes a vertex

;;; Bank 25: the texture column directory, the busy sign | the text capture
;;; masks.
MM_COLDIR     .equ    0x250000        ; 256 textures x 4 bytes
MM_BUSY       .equ    0x254000        ; the busy sign: 16 KB (src/iigs/m_menu65.s)
MM_BUSY_BANK  .equ    0x25            ;   (its MVNs)
MM_CAPMSK     .equ    0x256000        ; + a back buffer offset ($2000-$9CFF)

;;; Bank 26: the text code | the text capture values (src/iigs/patch65.s).
MM_TEXTCODE   .equ    0x260000        ; 2 slots of $4000
MM_CAPVAL     .equ    0x266000        ; + a back buffer offset ($2000-$9CFF)

;;; Bank 27-29: the song that plays (MUSBUF of src/iigs/music.inc: the
;;; player's tables from offset 0, then the song image), then the decoded
;;; sound samples (src/iigs/s_sound65.s).
MM_MUSBUF     .equ    0x270000        ; 44 KB, to $27AFFF
MM_SNDPCM     .equ    0x27b000
MM_SNDPCM_END .equ    0x29e000

;;; Bank 0 $8B04-$8B57: the level loader's copy of the boot loader's data
;;; (LV_EXT of src/iigs/w_level65.s, BI_EXT of src/iigs/loader.s): the
;;; mode, the disks, the RAM banks $00-$7F at + MM_EX_BANKS (a bit each: bank
;;; b is byte b >> 3, bit b & 7), the store map. The music guard of
;;; src/iigs/irq65.s and music.inc reads the RAM banks.
MM_LV_EXT     .equ    0x008b04
MM_EX_BANKS   .equ    4

;;; Bank 2A-3F: the level window (src/iigs/w_level65.s). At boot the loader
;;; puts the title picture at its start (the title set of the level
;;; loader) and the sound bank after it; I_InitSound decodes the sound bank
;;; before the first level.
MM_WINDOW     .equ    0x2a
MM_WINDOW_END .equ    0x40
MM_TITLEPIC   .equ    0x2a0000        ; tools/mkdisk.py --picture-file
MM_SNDBANK    .equ    0x2c0000        ; tools/sndbank.py, src/iigs/i_snd65.s

;;; The free parts of the table banks: the resident WAD puts lumps there
;;; when banks 10-12 are full (tools/levelimg.py reads these lines).
;;; FREE $0D0200-$0D45FF (below the colormaps of the linker)
;;; FREE $250400-$253FFF (after COLDIR)
;;; FREE $0A8100-$0AB4FF (after the pool bits)
;;; FREE $29E000-$29FFFF (after the sound samples)
;;; FREE $238000-$238BFF (before the automap keys)
;;; FREE $23C000-$23EEFF (after the automap line table)
;;; FREE $23FB00-$23FFFF (after the fill spans)

;;; 8 MB only, after the level store: all songs from the disk (MUSBANK of
;;; src/iigs/music.inc), until each song is a lump of the level store.
MM_MUSBANK    .equ    0x6a0000

#endif
