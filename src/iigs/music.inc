;;; Music workspace shared by the loader and interrupt player.
;;;
;;; MB_* values are offsets within the single MUSBUF bank. s_sound65.s
;;; loads the song image at MB_IMAGE, builds the lookup tables and uploads
;;; samples before enabling playback. irq65.s runs with DBR set to this
;;; bank and advances MB_SPTR through the stream built by tools/musbank.py.
;;; The song's DOC sample image stays at MB_DOCSRC until uploaded; it is
;;; not part of the interrupt player's workspace.
#include "memmap.inc"
MUSBUF        .equ    MM_MUSBUF       ; (src/iigs/memmap.inc)
MUSBANK       .equ    MM_MUSBANK      ; all songs, from the disk (8 MB only)
MUS_RAMMAP    .equ    (MM_LV_EXT + MM_EX_BANKS) ; the RAM banks, a bit each
MB_VSCALE     .equ    0x0000          ; 128: level -> DOC volume (music volume in)
MB_WLO        .equ    0x0080          ; 64: tics -> alarm frequency, low byte
MB_WHI        .equ    0x00c0          ;   high byte
MB_PLO        .equ    0x0100          ; 256: pitch -> DOC frequency, low byte
MB_PHI        .equ    0x0200          ;   high byte
MB_DPTR       .equ    0x0300          ; 64 each: the table descriptors: page,
MB_DSIZ       .equ    0x0340          ;   size and resolution byte, run mode
MB_DMODE      .equ    0x0380          ;   (0 free run, 2 one-shot), the loop
MB_LPTR       .equ    0x03c0          ;   of an attack table: page, size
MB_LSIZ       .equ    0x0400
MB_LEVEL      .equ    0x0440          ; 16: the level of each voice
MB_CTLH       .equ    0x0450          ; 16: channel | 3 (M1 + halt resets phase)
MB_CTLR       .equ    0x0460          ; 16: its channel: an even voice (the song's
                                      ;   left) 1, an odd one (right) 0 (TN.IIGS.019)
MB_VDESC      .equ    0x0470          ; 16: the descriptor of each voice
MB_VCTL       .equ    0x0480          ; 16: its run control byte
MB_SPTR       .equ    0x0490          ; 2: the stream position
MB_V          .equ    0x0492          ; 2: a voice (high byte 0: a 16-bit load)
MB_FCHI       .equ    0x0494          ; the alarm frequency high byte of the stream
;;; musOn, musLoop, musCur, musWant: bank 0 bytes of src/iigs/irq65.s (with
;;; their first values from the disk: this bank holds garbage at boot).
MB_T0         .equ    0x0498          ; 2 each: scratch of the start code
MB_T1         .equ    0x049a
MB_T2         .equ    0x049c
MB_T3         .equ    0x049e
MB_DOCSRC     .equ    0x04a0          ; 4: where the song's DOC RAM image is
                                      ;   (it does not come into MUSBUF)
MB_HSRC       .equ    0x04a4          ; 4: the song's image (its head goes to
MB_HLEN       .equ    0x04a8          ;   MB_IMAGE a part a frame); 2: the head
MB_HPOS       .equ    0x04aa          ;   length; 2: the part done
MB_UPAGE      .equ    0x04ac          ; 2: the next DOC page to load
MB_ULEFT      .equ    0x04ae          ; 2: the DOC pages still to load
MB_LOW        .equ    0x04b0          ; 2: the song's lowest DOC page
MB_PSWAP      .equ    0x04b2          ; 2: the map whose plan with its song is
                                      ;   in PLANS (src/iigs/s_sound65.s), 0: none
MB_PVALID     .equ    0x04b4          ; 2: not 0: MB_PLANS holds those plans
MB_READY      .equ    0x04b6          ; 2: loaded/muted song + 1 ready to start, or 0
MB_IMAGE      .equ    0x0500          ; the song image: u8 descriptors, u8
MB_STREAM     .equ    0x0506          ;   pitches, u16 stream length, u8 the
                                      ;   lowest DOC page, u8 feature flags, the stream,
                                      ;   the pitches, the descriptors (its
                                      ;   head); then the DOC RAM image
                                      ;   (tools/musbank.py)
MB_PLANS      .equ    0xae00          ; the plans of maps 1-9 with their song
                                      ;   (tools/sndbank.py), at the end: the
                                      ;   song image stays below
MUS_VOICES    .equ    14              ; oscillators 16-29
MUS_NONE      .equ    0xff
