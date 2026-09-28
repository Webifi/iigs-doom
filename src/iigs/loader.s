;;; Stage 2 loader, the file DOOM.BOOT in disk blocks 8-19 (tools/mkdisk.py),
;;; runs at $6000 in bank 0.
;;;
;;; Entered from the boot block (src/iigs/boot.s) in emulation mode with
;;; X = the ProDOS unit number of the boot drive. The loader:
;;; 1. finds the RAM banks: $02-$0D and $10-$3F must be RAM (4 MB, the
;;;    fixed data of src/iigs/memmap.inc); if not, a text screen says why the
;;;    game cannot run. $0E-$0F and $40-$7F may be there;
;;; 2. turns on the super hi-res screen, black;
;;; 3. loads each disk: the header in block 1, then the segments block by
;;;    block into bank 0 and with MVN to their 24-bit address. The title
;;;    picture comes first on disk 1: each of its blocks also goes to the
;;;    screen. The load strip (rows 191-199 of the picture) shows a disk
;;;    icon, the disk number and a bar. The level store (the segments from
;;;    $40:0000, tools/levelimg.py) loads only when its banks are RAM (the
;;;    8 MB mode); else the game reads it at each level start and the load
;;;    stops after the last disk with other data (HDR_RESDISKS);
;;; 4. ejects each disk but the last after its last block. Then it waits
;;;    for the next disk: INSERT DISK n pulses and the icon blinks; a wrong
;;;    disk goes out again;
;;; 5. writes BOOTINFO for the game (the drive, the settings file on disk 1,
;;;    the RAM banks, the mode, the store map) and jumps to the entry point
;;;    in native mode.
;;; The picture shows in soft gray while the disks load (its palettes 0-14 in
;;; gray on the screen, the picture record keeps its colors; palette 15, the
;;; load strip, keeps its colors: PLAN decision 32). The game keeps it on the
;;; screen until its title page, which brings the colors (titleWipe of
;;; src/iigs/w_level65.s).
;;;
;;; Disk header (block 1, tools/mkdisk.py):
;;;   0   "DOOMGS"
;;;   6   disk number, 1 based
;;;   7   number of disks
;;;   8   number of segments on this disk
;;;   10  entry point, 3 bytes
;;;   14  blocks for each cell of the bar
;;;   16  segments, 8 bytes each: address (3), flags (1), first block (2),
;;;       count (2). Flag SEG_B1: the blocks are the B1 stream of the
;;;       segment (tools/b1.py: its length, then B1), read to STAGE and
;;;       decoded. Flag SEG_PIC: the 64 blocks of the title picture (an
;;;       image of the screen memory), in the order of HDR_ORDER. The last
;;;       disk has the block of DOOM.SETTINGS as a segment to SETTINGS_IN
;;;   368 the store map: 8 runs of the first store block, the count, the
;;;       first disk block, the disk (words; tools/mkdisk.py)
;;;   432 the build ID, the same on all disks of a build, 4 bytes
;;;   436 disk 1: the block of DOOM.SETTINGS
;;;   438 the last disk with data below the store, the banks of the store
;;;   448 HDR_ORDER: the picture block of each block of the SEG_PIC segment
;;;
;;; BOOTINFO for the game (src/iigs/m_config65.s), 16 bytes:
;;;   0   "DB"
;;;   2   the ProDOS unit of the boot drive
;;;   3   its SmartPort unit
;;;   4   the ProDOS block driver of the slot, 2 bytes
;;;   6   the SmartPort entry of the slot, 2 bytes
;;;   8   the block of DOOM.SETTINGS on disk 1, 2 bytes
;;;   10  the disk of DOOM.SETTINGS: 1
;;;   12  the build ID, 4 bytes
;;;   16  the mode: 1 the store is in RAM (8 MB), 0 the game reads it
;;;   17  the last disk with data below the store, 18 the number of disks,
;;;   19  the banks of the store
;;;   20  the RAM banks $00-$7F: a bit each (bank b: byte b >> 3, bit b & 7)
;;;   36  the store map of the header (64 bytes)

PD_CMD        .equ    0x42            ; the ProDOS block driver: command,
PD_UNIT       .equ    0x43            ;   unit,
PD_BUF        .equ    0x44            ;   buffer,
PD_BLOCK      .equ    0x46            ;   block

TMP           .equ    0x50            ; 2 bytes
PTR           .equ    0x52            ; 3 bytes: a long pointer
DEST          .equ    0x56            ; 3 bytes: the address of the block
SEGADDR       .equ    0x5a            ; 3 bytes: the address of the segment
SEGPTR        .equ    0x5e            ; the segment in HDR
SEGS          .equ    0x60            ; segments left on the disk
FLAGS         .equ    0x61            ; the flags of the segment
BLKLEFT       .equ    0x62            ; blocks left in the segment
BLKNUM        .equ    0x64            ; the block in the segment, 0 on
DISKNUM       .equ    0x66            ; the disk to load, 1 on
NDISKS        .equ    0x67            ; the number of disks
STEPLEFT      .equ    0x68            ; blocks to the next cell of the bar
CELLS         .equ    0x69            ; the full cells of the bar
CELL          .equ    0x6a            ; drawBar: the cell
CCOLOR        .equ    0x6b            ; drawCell: 2 pixels of its color
E1            .equ    0x6c            ; drawCell: the first and the last
E3            .equ    0x6d            ;   screen byte of a row of the cell
ROW           .equ    0x6e            ; rows left
PICOFS        .equ    0x70            ; the screen offset of a picture block
XOFS          .equ    0x72            ; the screen offset of the next glyph
GLYPH         .equ    0x74            ; the glyph data
GW            .equ    0x76            ; the width of the glyph, screen bytes
STRPTR        .equ    0x78            ; the glyph numbers of a text
DROP          .equ    0x7a            ; the pulse: the text is DROP steps darker
PULSE         .equ    0x7c            ; the step of the pulse, 0-5 (2 bytes)
FRAMES        .equ    0x7e            ; frames while the loader waits
MSGPTR        .equ    0x80            ; printAt: the text
STOREMODE     .equ    0x82            ; 1: the store loads (its banks are RAM)
LASTDISK      .equ    0x83            ; the last disk to load
B1_BITS       .equ    0x84            ; b1Seg: the bits, the offset, the
B1_OFF        .equ    0x86            ;   input index, the count, the end
B1_INP        .equ    0x88
B1_CNT        .equ    0x8a
B1_END        .equ    0x8c

HDR           .equ    0x7800          ; block 1 of the disk
HDR_DISK      .equ    HDR + 6
HDR_DISKS     .equ    HDR + 7
HDR_SEGS      .equ    HDR + 8
HDR_ENTRY     .equ    HDR + 10
HDR_STEP      .equ    HDR + 14
HDR_SEG       .equ    HDR + 16
HDR_STOREMAP  .equ    HDR + 368
HDR_BUILD     .equ    HDR + 432
HDR_SETTINGS  .equ    HDR + 436
HDR_RESDISKS  .equ    HDR + 438
HDR_STOREBANKS .equ   HDR + 439
HDR_ORDER     .equ    HDR + 448
BOOTINFO      .equ    0x7e00          ; for the game, see above
BI_BANKS      .equ    BOOTINFO + 20   ; the RAM banks (16 bytes)
STORE_BANK    .equ    0x40            ; the store (tools/levelimg.py)
BUF           .equ    0x7a00          ; a data block
SEG_PIC       .equ    1               ; segment flag: the title picture
SEG_B1        .equ    2               ; segment flag: a B1 stream
STAGE         .equ    0x300000        ; the blocks of a B1 segment (a bank of
                                      ;   the level window, free at boot)

SCREEN        .equ    0xe12000        ; the super hi-res screen: 200 rows of
SCB           .equ    0xe19d00        ;   160 bytes, the palette of each row
PALETTES      .equ    0xe19e00        ; 16 palettes of 16 colors
NEWVIDEO      .equ    0xc029          ; bit 7 super hi-res, bit 6 linear
BORDER        .equ    0xc034          ; low 4 bits: the border color
RDVBLBAR      .equ    0xc019          ; bit 7: the vertical blank

STRIP_ROW     .equ    191             ; the load strip: rows 191-199 of the
STRIP_PAL     .equ    15              ;   title, palette 15 (tools/gscolor.py)
STRIP         .equ    STRIP_ROW * 160 ; its first screen byte
PIXELS_END    .equ    200 * 160       ; the end of the pixels
PALS_OFS      .equ    0x7e00          ; the palettes (the last picture block)
ICON_OFS      .equ    STRIP + 2       ; the disk icon at x 4
COUNT_OFS     .equ    STRIP + 160 + 9 ; the disk number at x 18, row 192
PROMPT_OFS    .equ    STRIP + 160 + 30 ; INSERT DISK n at x 60
TEXT_START    .equ    STRIP + 160 + 22 ; rows 192-198 from x 44: the bar
TEXT_ROWS     .equ    7               ;   or the prompt

#include "loadbar.inc"

              .section loader, text, root, noreorder
              .public loaderStart
loaderStart:  sei
              cld
              stx     dp:PD_UNIT
              txa                           ; the ProDOS entry of the boot
              lsr     a                     ;   slot: $Cn00 + ($CnFF)
              lsr     a
              lsr     a
              lsr     a
              ora     #0xc0
              sta     abs:drvAddr+1
              sta     abs:spAddr+1
              sta     dp:TMP+1
              lda     #0xff
              sta     dp:TMP
              ldy     #0
              lda     (TMP),y
              sta     abs:drvAddr
              clc                           ; the SmartPort entry is 3 bytes
              adc     #3                    ;   after it
              sta     abs:spAddr
              lda     dp:PD_UNIT            ; SmartPort unit 1 or 2: the drive
              asl     a                     ;   bit of the ProDOS unit
              lda     #0
              rol     a
              inc     a
              sta     abs:spUnit
              clc
              xce                           ; native mode: A 8 bits, X and Y
              rep     #0x10                 ;   16 bits from here on
              jsr     abs:checkMemory
              bcc     1$
              jmp     abs:cannotRun
1$:           jsr     abs:screenOn
              lda     #1
              sta     dp:DISKNUM
              stz     dp:CELLS
              jsr     abs:readHeader
              php
              jsr     abs:drawStrip
              plp
              bcc     2$
              jsr     abs:waitDisk          ; not disk 1: ask for it
2$:           lda     abs:HDR_STEP
              sta     dp:STEPLEFT
              jsr     abs:storeMode

;;; The segments of the disk DISKNUM, its header in HDR.
diskLoop:     lda     abs:HDR_SEGS
              sta     dp:SEGS
              ldx     ##HDR_SEG
              stx     dp:SEGPTR
segLoop:      lda     dp:SEGS
              bne     1$
              jmp     abs:diskDone
1$:           ldy     ##2                   ; the store, when the game reads it
              lda     (SEGPTR),y
              cmp     #STORE_BANK
              bcc     11$
              lda     dp:STOREMODE
              bne     11$
              jmp     abs:segDone
11$:          ldy     ##0
              lda     (SEGPTR),y            ; the address
              sta     dp:SEGADDR
              sta     dp:DEST
              iny
              lda     (SEGPTR),y
              sta     dp:SEGADDR+1
              sta     dp:DEST+1
              iny
              lda     (SEGPTR),y
              sta     dp:SEGADDR+2
              sta     dp:DEST+2
              iny
              lda     (SEGPTR),y
              sta     dp:FLAGS
              rep     #0x20
              ldy     ##4
              lda     (SEGPTR),y            ; the first block
              sta     dp:PD_BLOCK
              ldy     ##6
              lda     (SEGPTR),y            ; the count
              sta     dp:BLKLEFT
              stz     dp:BLKNUM
              sep     #0x20
              lda     dp:FLAGS              ; a B1 segment: its blocks to STAGE
              and     #SEG_B1
              beq     blockLoop
              ldx     ##.word0 STAGE
              stx     dp:DEST
              lda     #.byte2 STAGE
              sta     dp:DEST+2

blockLoop:    ldx     dp:BLKLEFT
              beq     segDone
              ldx     ##BUF
              stx     dp:PD_BUF
              jsr     abs:readBlock
              bcc     1$
              jmp     abs:readError
1$:           lda     dp:FLAGS
              and     #SEG_PIC
              beq     2$
              jsr     abs:picBlock
2$:           jsr     abs:copyBlock
              jsr     abs:stepBar
              rep     #0x20
              inc     dp:PD_BLOCK
              inc     dp:BLKNUM
              dec     dp:BLKLEFT
              sep     #0x20
              bra     blockLoop

segDone:      lda     dp:FLAGS              ; a B1 segment: decoded to its place
              and     #SEG_B1
              beq     1$
              jsr     abs:b1Seg
1$:           rep     #0x20
              lda     dp:SEGPTR
              clc
              adc     ##8
              sta     dp:SEGPTR
              sep     #0x20
              dec     dp:SEGS
              jmp     abs:segLoop

diskDone:     lda     dp:DISKNUM            ; the last disk stays in
              cmp     dp:LASTDISK
              bcs     allLoaded
              jsr     abs:ejectDisk
              inc     dp:DISKNUM
              jsr     abs:waitDisk
              jmp     abs:diskLoop

allLoaded:    lda     #BAR_FULL             ; the cells of the load all full
              sta     dp:CCOLOR
1$:           lda     dp:CELLS
              cmp     #LOAD_CELLS
              bcs     2$
              inc     dp:CELLS
              jsr     abs:drawCell
              bra     1$
2$:           lda     #'D'                  ; BOOTINFO
              sta     abs:BOOTINFO
              lda     #'B'
              sta     abs:BOOTINFO+1
              lda     dp:PD_UNIT
              sta     abs:BOOTINFO+2
              lda     abs:spUnit
              sta     abs:BOOTINFO+3
              ldx     abs:drvAddr
              stx     abs:BOOTINFO+4
              ldx     abs:spAddr
              stx     abs:BOOTINFO+6
              ldx     abs:settingsBlock
              stx     abs:BOOTINFO+8
              lda     #1                    ; DOOM.SETTINGS is on disk 1
              sta     abs:BOOTINFO+10
              stz     abs:BOOTINFO+11
              ldx     abs:HDR_BUILD
              stx     abs:BOOTINFO+12
              ldx     abs:HDR_BUILD+2
              stx     abs:BOOTINFO+14
              lda     dp:STOREMODE
              sta     abs:BOOTINFO+16
              lda     abs:HDR_RESDISKS
              sta     abs:BOOTINFO+17
              lda     dp:NDISKS
              sta     abs:BOOTINFO+18
              lda     abs:HDR_STOREBANKS
              sta     abs:BOOTINFO+19
              ldx     ##62                  ; the store map
3$:           lda     abs:HDR_STOREMAP,x
              sta     abs:BOOTINFO+36,x
              lda     abs:HDR_STOREMAP+1,x
              sta     abs:BOOTINFO+37,x
              dex
              dex
              bpl     3$
              ldx     abs:HDR_ENTRY
              stx     abs:jmlInst+1
              lda     abs:HDR_ENTRY+2
              sta     abs:jmlInst+3
              rep     #0x30
jmlInst:      .byte   0x5c, 0x00, 0x00, 0x00 ; jml

;;; ---------------------------------------------------------------------------
;;; The memory check.
;;; ---------------------------------------------------------------------------

;;; checkMemory: the RAM banks $00-$7F in BI_BANKS; carry clear when
;;; banks $02-$0D and $10-$3F are RAM. Else carry set, A = the first of
;;; them that is not RAM. Each bank gets 2 bytes at $8000 (the bank number
;;; and its complement), the highest first: a bank that repeats a lower one
;;; then fails. $0E-$0F: a ROM 03 has none (its 1 MB is $00-$0D, $E0-$E1).
checkMemory:  stz     dp:PTR
              lda     #0x80
              sta     dp:PTR+1
              ldy     ##1
              lda     #0x7f
1$:           sta     dp:PTR+2
              sta     [PTR]
              eor     #0xff
              sta     [PTR],y
              eor     #0xff
              dec     a
              cmp     #2
              bcs     1$
              ldx     ##15                  ; BI_BANKS: $00-$01 (the board)
0$:           stz     abs:BI_BANKS,x
              dex
              bpl     0$
              lda     #3
              sta     abs:BI_BANKS
              lda     #2
2$:           sta     dp:PTR+2
              cmp     [PTR]
              bne     4$
              eor     #0xff
              cmp     [PTR],y
              bne     4$
              lda     dp:PTR+2              ; a RAM bank: its bit
              jsr     abs:bankBit
              lda     abs:BI_BANKS,x
              ora     dp:TMP
              sta     abs:BI_BANKS,x
4$:           lda     dp:PTR+2
              inc     a
              bpl     2$
              lda     #2                    ; the fixed banks
5$:           jsr     abs:isBank
              bcc     8$
              inc     a
              cmp     #0x0e
              bne     6$
              lda     #0x10
6$:           cmp     #0x40
              bcc     5$
              clc
              rts
8$:           sec
              rts

;;; isBank: carry set when bank A is RAM (BI_BANKS). A stays.
isBank:       jsr     abs:bankBit
              pha
              lda     abs:BI_BANKS,x
              and     dp:TMP
              cmp     #1                    ; (carry: not 0)
              pla
              rts

;;; bankBit: X = the byte of bank A in BI_BANKS, TMP = its bit. A stays.
;;; (TAX with an 8-bit A copies B too: the index is made in 16 bits.)
bankBit:      pha
              rep     #0x20
              and     ##0x0007
              tax
              sep     #0x20
              lda     abs:bitOf,x
              sta     dp:TMP
              lda     1,s
              rep     #0x20
              and     ##0x00ff
              lsr     a
              lsr     a
              lsr     a
              tax
              sep     #0x20
              pla
              rts

;;; storeMode: STOREMODE = 1 when the banks of the store are RAM, then
;;; LASTDISK = the number of disks; else the last disk with other data.
storeMode:    stz     dp:STOREMODE
              lda     abs:HDR_STOREBANKS
              beq     3$
              clc
              adc     #STORE_BANK
              sta     dp:TMP+1
              lda     #STORE_BANK
1$:           jsr     abs:isBank
              bcc     3$
              inc     a
              cmp     dp:TMP+1
              bcc     1$
              inc     dp:STOREMODE
3$:           lda     dp:STOREMODE
              beq     4$
              lda     dp:NDISKS
              bra     5$
4$:           lda     abs:HDR_RESDISKS
5$:           sta     dp:LASTDISK
              ldx     abs:HDR_SETTINGS      ; (the header of disk 1)
              stx     abs:settingsBlock
              rts

;;; cannotRun: the text screen that says why the game cannot run. A = the
;;; first bank that is not RAM: the IIgs has about A / 16 MB.
cannotRun:    lsr     a
              lsr     a
              lsr     a
              lsr     a
              bne     1$
              ldx     ##msgLess             ; less than 1 MB
              stx     dp:TMP
              ldx     ##msgHasNum
              bra     2$
1$:           ora     #'0'
              sta     abs:msgHasNum
              ldx     ##msgMB
              stx     dp:TMP
              ldx     ##msgHasNum+1
2$:           ldy     ##0                   ; the size and the end of the line
3$:           lda     (TMP),y
              sta     abs:0,x
              beq     4$
              inx
              iny
              bra     3$
4$:           jsr     abs:textScreen
              sep     #0x10
              ldx     #.byte0 msgSorry
              ldy     #.byte1 msgSorry
              jsr     abs:printAt
              ldx     #.byte0 msgSorry2
              ldy     #.byte1 msgSorry2
              jsr     abs:printAt
              ldx     #.byte0 msgNeeds
              ldy     #.byte1 msgNeeds
              jsr     abs:printAt
              ldx     #.byte0 msgHas
              ldy     #.byte1 msgHas
              jsr     abs:printAt
              ldx     #.byte0 msgAdd
              ldy     #.byte1 msgAdd
              jsr     abs:printAt
              ldx     #.byte0 msgAdd2
              ldy     #.byte1 msgAdd2
              jsr     abs:printAt
hang:         bra     hang

;;; readError: a disk read error: the text screen says so, and the loader
;;; stops.
readError:    jsr     abs:textScreen
              sep     #0x10
              ldx     #.byte0 msgReadError
              ldy     #.byte1 msgReadError
              jsr     abs:printAt
              bra     hang

;;; textScreen: the 40 column text screen, cleared, with the title.
textScreen:   lda     abs:NEWVIDEO
              and     #0x7f
              sta     abs:NEWVIDEO
              sta     abs:0xc051            ; text mode
              sta     abs:0xc054            ; page 1
              sta     abs:0xc00c            ; 40 columns
              sta     abs:0xc00e            ; primary character set
              sep     #0x10
              jsr     abs:clearScreen
              ldx     #.byte0 msgTitle
              ldy     #.byte1 msgTitle
              jsr     abs:printAt
              rep     #0x10
              rts

;;; ---------------------------------------------------------------------------
;;; Disk access. The firmware runs in emulation mode; these routines switch
;;; to it and back (X and Y lose their high bytes).
;;; ---------------------------------------------------------------------------

;;; readBlock: block PD_BLOCK to PD_BUF; carry set on an error.
readBlock:    lda     #1
              sta     dp:PD_CMD
              sec
              xce
              jsr     abs:callDriver
              lda     #0
              rol     a                     ; the error, over the mode change
              clc
              xce
              rep     #0x10
              lsr     a
              rts
callDriver:   jmp     (abs:drvAddr)

;;; spCall: the SmartPort call A (0 STATUS, 4 CONTROL) for the boot drive,
;;; with the code in spCode and the list at spList; carry set on an error.
spCall:       sta     abs:spCmd
              sec
              xce
              jsr     abs:spJump
spCmd:        .byte   0
              .word   spParams
              lda     #0
              rol     a
              clc
              xce
              rep     #0x10
              lsr     a
              rts
spJump:       jmp     (abs:spAddr)

;;; ejectDisk: the drive ejects the disk (SmartPort CONTROL, code 4). A
;;; drive that cannot does nothing, and the user takes the disk out.
ejectDisk:    lda     #4
              sta     abs:spCode
              stz     abs:spList            ; no control data
              stz     abs:spList+1
              lda     #4
              jmp     abs:spCall

;;; diskIn: carry set when a disk is in the drive (SmartPort STATUS, code
;;; 0: bit 4 of the status byte); also when the call fails.
diskIn:       stz     abs:spCode
              lda     #0
              jsr     abs:spCall
              bcs     1$
              lda     abs:spList
              and     #0x10
              beq     2$
1$:           sec
              rts
2$:           clc
              rts

;;; readHeader: block 1 to HDR; carry clear when it is disk DISKNUM: disk
;;; 1 gives the build ID (buildId), a later disk must have the same. NDISKS
;;; comes from any Doom disk.
readHeader:   ldx     ##HDR
              stx     dp:PD_BUF
              ldx     ##1
              stx     dp:PD_BLOCK
              jsr     abs:readBlock
              bcs     9$
              ldx     ##5
1$:           lda     abs:HDR,x
              cmp     abs:magic,x
              bne     9$
              dex
              bpl     1$
              lda     abs:HDR_DISKS
              sta     dp:NDISKS
              lda     abs:HDR_DISK
              cmp     dp:DISKNUM
              bne     9$
              ldx     abs:HDR_BUILD
              ldy     abs:HDR_BUILD+2
              cmp     #1
              bne     2$
              stx     abs:buildId
              sty     abs:buildId+2
              bra     3$
2$:           cpx     abs:buildId
              bne     9$
              cpy     abs:buildId+2
              bne     9$
3$:           clc
              rts
9$:           sec
              rts

;;; readHeader2: readHeader, once more after a failure: the first read
;;; after a disk change fails (the firmware reports the change), and the
;;; disk would go out as a wrong one (booting from disk 2: disk 1 went out
;;; again and again, the loader waited for ever).
readHeader2:  jsr     abs:readHeader
              bcc     1$
              jsr     abs:readHeader
1$:           rts

;;; b1Seg: the B1 stream at STAGE (its length, then B1: tools/b1.py) to
;;; SEGADDR (the segment of HDR at SEGPTR). The decoder of
;;; src/iigs/w_level65.s; the output ends at B1_END (it may be the end of
;;; the bank: 0), so the test is equality.
b1Seg:        lda     dp:SEGADDR+2          ; the banks into the code
              sta     abs:b1Lmvn+1
              sta     abs:b1Mmvn+1
              sta     abs:b1Mmvn+2
              lda     #.byte2 STAGE
              sta     abs:b1Lmvn+2
              sta     abs:b1Rdb+3
              sta     abs:b1Rdw+3
              rep     #0x30
              lda     long:STAGE            ; the end
              clc
              adc     dp:SEGADDR
              sta     dp:B1_END
              lda     ##0x8000
              sta     dp:B1_BITS
              lda     ##1
              sta     dp:B1_OFF
              ldx     ##(.word0 STAGE + 2)
              ldy     dp:SEGADDR
              jsr     abs:b1Lits
              phk                           ; (MVN set the data bank)
              plb
              sep     #0x20
              rts

b1Lits:       jsr     abs:b1Gamma           ; a literal run
              dec     a
b1Lmvn:       .byte   0x54, 0x00, 0x00      ; MVN: input -> output
              cpy     dp:B1_END
              beq     b1Done
              asl     dp:B1_BITS            ; after literals: 0 = the last offset
              bne     1$
              jsr     abs:b1Refill
1$:           bcs     b1New
              jsr     abs:b1Gamma
              bra     b1Copy
b1New:        jsr     abs:b1Gamma           ; a new offset: the high part,
              dec     a
              xba
              sep     #0x20
b1Rdb:        lda     long:0x000000,x       ;   the low byte
              rep     #0x20
              inx
              lsr     a
              inc     a
              sta     dp:B1_OFF
              jsr     abs:b1GammaC          ; the length - 1
              inc     a
b1Copy:       dec     a                     ; a match
              sta     dp:B1_CNT
              stx     dp:B1_INP
              tya
              sec
              sbc     dp:B1_OFF
              tax
              lda     dp:B1_CNT
b1Mmvn:       .byte   0x54, 0x00, 0x00      ; MVN: output -> output
              ldx     dp:B1_INP
              cpy     dp:B1_END
              beq     b1Done
              asl     dp:B1_BITS            ; after a match: 0 = literals
              bne     2$
              jsr     abs:b1Refill
2$:           bcc     b1Lits
              bra     b1New
b1Done:       rts

b1Gamma:      lda     ##1
b1G0:         asl     dp:B1_BITS
              bne     b1G1
              jsr     abs:b1Refill
b1G1:         bcs     b1G3
              asl     dp:B1_BITS
              bne     b1G2
              jsr     abs:b1Refill
b1G2:         rol     a
              bra     b1G0
b1G3:         rts
b1GammaC:     lda     ##1
              bra     b1G1

b1Refill:     pha
b1Rdw:        lda     long:0x000000,x
              inx
              inx
              sec
              rol     a
              sta     dp:B1_BITS
              pla
              rts

;;; copyBlock: BUF to DEST; DEST moves to the next block.
copyBlock:    lda     dp:DEST+2
              sta     abs:mvnBank
              rep     #0x30
              ldx     ##BUF
              ldy     dp:DEST
              lda     ##511
              .byte   0x54                  ; mvn
mvnBank:      .byte   0x00, 0x00            ; destination bank, source bank 0
              phk
              plb
              lda     dp:DEST
              clc
              adc     ##512
              sta     dp:DEST
              sep     #0x20
              lda     dp:DEST+2
              adc     #0
              sta     dp:DEST+2
              rts

;;; picBlock: a block of the title picture: DEST is its place in the
;;; picture record, and it goes to the screen too, except for the pixels of
;;; the load strip.
picBlock:     rep     #0x30
              ldx     dp:BLKNUM
              lda     abs:HDR_ORDER,x       ; the picture block
              and     ##0x003f
              asl     a
              xba                           ; * 512
              sta     dp:PICOFS
              clc
              adc     dp:SEGADDR
              sta     dp:DEST
              sep     #0x20
              lda     dp:SEGADDR+2
              adc     #0
              sta     dp:DEST+2
              rep     #0x20
              lda     dp:PICOFS             ; the part above the strip
              cmp     ##STRIP
              bcs     2$
              ldx     ##BUF
              tay
              clc
              adc     ##512
              cmp     ##STRIP
              bcc     1$
              lda     ##STRIP
1$:           sec
              sbc     dp:PICOFS
              jsr     abs:toScreen
2$:           lda     dp:PICOFS             ; the part after the pixels: the
              clc                           ;   row palettes and the palettes
              adc     ##512
              cmp     ##PIXELS_END + 1
              bcc     4$
              lda     dp:PICOFS
              cmp     ##PIXELS_END
              bcs     3$
              lda     ##PIXELS_END
3$:           tay                           ; the screen offset
              sec
              sbc     dp:PICOFS
              clc
              adc     ##BUF
              tax                           ; the part of BUF
              lda     dp:PICOFS
              clc
              adc     ##512
              sty     dp:TMP
              sec
              sbc     dp:TMP                ; the length
              jsr     abs:toScreen
              lda     dp:PICOFS             ; the palettes: in gray
              cmp     ##PALS_OFS
              bne     4$
              jsr     abs:grayPals
4$:           sep     #0x20
              rts

;;; grayPals: palettes 0-14 of the screen in soft gray. A color $0RGB becomes
;;; GRAYS[(5 R + 9 G + 2 B + 8) >> 4]: its luminance (about Rec. 601) on a
;;; palette ranging from $333 to $CCC, keeping dark pixels visible while
;;; reducing contrast. In and out: A and X, Y 16 bits.
grayPals:     ldx     ##(15 * 32 - 2)
1$:           lda     long:PALETTES,x       ; $0RGB
              pha
              and     ##0x000f
              tay
              lda     abs:GRAY_B,y          ; 2 B + 8
              and     ##0x00ff
              sta     dp:TMP
              lda     1,s
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              and     ##0x000f
              tay
              lda     abs:GRAY_G,y          ; 9 G
              and     ##0x00ff
              clc
              adc     dp:TMP
              sta     dp:TMP
              pla
              xba
              and     ##0x000f
              tay
              lda     abs:GRAY_R,y          ; 5 R
              and     ##0x00ff
              clc
              adc     dp:TMP                ; 16 x the luminance
              lsr     a
              lsr     a
              lsr     a
              and     ##0x001e              ; (a word index)
              tay
              lda     abs:GRAYS,y
              sta     long:PALETTES,x
              dex
              dex
              bpl     1$
              rts

;;; toScreen: C bytes (16 bits) from X in bank 0 to screen offset Y.
;;; In and out: A and X, Y 16 bits.
toScreen:     dec     a
              pha
              tya
              clc
              adc     ##.word0 SCREEN
              tay
              pla
              .byte   0x54, 0xe1, 0x00      ; mvn to bank $E1 from bank 0
              phk
              plb
              rts

;;; ---------------------------------------------------------------------------
;;; The screen.
;;; ---------------------------------------------------------------------------

;;; screenOn: the super hi-res screen on, black: all pixels, row palettes
;;; and colors 0; the strip rows take palette STRIP_PAL, with the strip
;;; colors (a prompt before the title picture: another disk in the drive
;;; at boot).
screenOn:     lda     abs:NEWVIDEO
              ora     #0x40                 ; linear memory before the writes
              sta     abs:NEWVIDEO
              rep     #0x30
              lda     ##0
              sta     long:SCREEN
              ldx     ##.word0 SCREEN
              ldy     ##.word0 SCREEN + 2
              lda     ##0x8000 - 3          ; $E1:2002-$9FFF, each byte from
              .byte   0x54, 0xe1, 0xe1      ;   2 bytes before it: zeros
              phk
              plb
              ldx     ##16
2$:           lda     abs:stripPal,x
              sta     long:(PALETTES + 32 * STRIP_PAL),x
              dex
              dex
              bpl     2$
              sep     #0x20
              ldx     ##STRIP_ROW
              lda     #STRIP_PAL
1$:           sta     long:SCB,x
              inx
              cpx     ##200
              bcc     1$
              lda     abs:BORDER
              and     #0xf0
              sta     abs:BORDER
              lda     abs:NEWVIDEO
              ora     #0xc0
              sta     abs:NEWVIDEO
              rts

;;; drawStrip: the load strip: black, the disk icon, the disk number and
;;; the bar with CELLS full cells.
drawStrip:    ldx     ##STRIP
              lda     #0
1$:           sta     long:SCREEN,x
              inx
              cpx     ##PIXELS_END
              bcc     1$
              ldy     ##ICON_LIT
              jsr     abs:drawIcon
              jsr     abs:drawCount
              jmp     abs:drawBar

;;; stepBar: after each block; one more full cell after HDR_STEP blocks.
stepBar:      dec     dp:STEPLEFT
              bne     1$
              lda     abs:HDR_STEP
              sta     dp:STEPLEFT
              lda     #BAR_FULL
              sta     dp:CCOLOR
              lda     dp:CELLS
              cmp     #LOAD_CELLS
              bcs     1$
              inc     dp:CELLS
              jmp     abs:drawCell
1$:           rts

;;; drawBar: all cells, the first CELLS of them full.
drawBar:      stz     dp:CELL
1$:           lda     dp:CELL
              cmp     dp:CELLS
              lda     #BAR_FULL
              bcc     2$
              lda     #BAR_EMPTY
2$:           sta     dp:CCOLOR
              lda     dp:CELL
              jsr     abs:drawCell
              inc     dp:CELL
              lda     dp:CELL
              cmp     #BAR_CELLS
              bcc     1$
              rts

;;; drawCell: cell A of the bar in CCOLOR. The cell starts at pixel
;;; BAR_X + 7 * cell: a pixel at its left (odd x) or its right (even x)
;;; shares a screen byte with it and stays black.
drawCell:     pha
              rep     #0x20
              and     ##0x00ff
              sta     dp:TMP
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:TMP
              clc
              adc     ##BAR_X
              lsr     a
              clc
              adc     ##BAR_ROW
              tax
              sep     #0x20
              lda     dp:CCOLOR
              sta     dp:E1
              sta     dp:E3
              pla
              lsr     a                     ; carry: an odd cell, an odd x
              lda     dp:CCOLOR
              bcs     1$
              and     #0xf0
              sta     dp:E3
              bra     2$
1$:           and     #0x0f
              sta     dp:E1
2$:           lda     #5
              sta     dp:ROW
3$:           lda     dp:E1
              sta     long:SCREEN,x
              lda     dp:CCOLOR
              sta     long:SCREEN+1,x
              lda     dp:E3
              sta     long:SCREEN+2,x
              rep     #0x20
              txa
              clc
              adc     ##160
              tax
              sep     #0x20
              dec     dp:ROW
              bne     3$
              rts

;;; clearText: rows 192-198 from x 44 on black: no bar, no prompt.
clearText:    ldx     ##TEXT_START
              lda     #TEXT_ROWS
              sta     dp:ROW
1$:           ldy     ##160 - 22
              lda     #0
2$:           sta     long:SCREEN,x
              inx
              dey
              bne     2$
              rep     #0x20
              txa
              clc
              adc     ##22
              tax
              sep     #0x20
              dec     dp:ROW
              bne     1$
              rts

;;; drawIcon: the disk icon from Y (ICON_LIT or ICON_DARK).
drawIcon:     ldx     ##ICON_OFS
              lda     #ICON_ROWS
              sta     dp:ROW
1$:           lda     #ICON_BYTES
              sta     dp:TMP
2$:           lda     abs:0,y
              sta     long:SCREEN,x
              iny
              inx
              dec     dp:TMP
              bne     2$
              rep     #0x20
              txa
              clc
              adc     ##160 - ICON_BYTES
              tax
              sep     #0x20
              dec     dp:ROW
              bne     1$
              rts

;;; drawCount: DISKNUM/NDISKS in the plain font colors.
drawCount:    stz     dp:DROP
              jsr     abs:setDrop
              ldx     ##COUNT_OFS
              stx     dp:XOFS
              lda     dp:DISKNUM
              jsr     abs:drawGlyph
              lda     #GLYPH_SLASH
              jsr     abs:drawGlyph
              lda     dp:NDISKS
              jmp     abs:drawGlyph

;;; setDrop: TAB16 for DROP: the screen byte of each 2 glyph pixels (the
;;; left one in the high bits), each red DROP steps darker on the ramp of
;;; palette 15 (black stays black).
setDrop:      sep     #0x10
              ldx     #15
1$:           txa
              lsr     a
              lsr     a
              tay
              lda     abs:LEVEL,y
              sec
              sbc     dp:DROP
              bcs     2$
              lda     #0
2$:           asl     a
              asl     a
              asl     a
              asl     a
              sta     dp:TMP
              txa
              and     #3
              tay
              lda     abs:LEVEL,y
              sec
              sbc     dp:DROP
              bcs     3$
              lda     #0
3$:           ora     dp:TMP
              sta     abs:TAB16,x
              dex
              bpl     1$
              rep     #0x10
              rts

;;; drawText: the glyphs at Y until $FF.
drawText:     sty     dp:STRPTR
1$:           lda     (STRPTR)
              cmp     #0xff
              beq     2$
              jsr     abs:drawGlyph
              rep     #0x20
              inc     dp:STRPTR
              sep     #0x20
              bra     1$
2$:           rts

;;; drawGlyph: glyph A at the screen offset XOFS through TAB16; XOFS moves
;;; past it.
drawGlyph:    rep     #0x30
              and     ##0x00ff
              asl     a
              tax
              lda     abs:GLYPHS,x
              sta     dp:GLYPH
              lda     dp:XOFS
              clc
              adc     ##.word0 SCREEN
              sta     dp:PTR
              sep     #0x30                 ; A, X and Y 8 bits
              lda     #.byte2 SCREEN
              sta     dp:PTR+2
              lda     (GLYPH)               ; the width
              sta     dp:GW
              jsr     abs:nextByte
              lda     #GLYPH_ROWS
              sta     dp:ROW
1$:           ldy     #0
2$:           lda     (GLYPH)               ; 4 pixels
              jsr     abs:nextByte
              pha
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              tax
              lda     abs:TAB16,x
              sta     [PTR],y
              iny
              pla
              cpy     dp:GW
              bcs     3$                    ; an odd width ends here
              and     #0x0f
              tax
              lda     abs:TAB16,x
              sta     [PTR],y
              iny
              cpy     dp:GW
              bcc     2$
3$:           rep     #0x20
              lda     dp:PTR
              clc
              adc     ##160
              sta     dp:PTR
              sep     #0x20
              dec     dp:ROW
              bne     1$
              rep     #0x30
              lda     dp:GW
              and     ##0x00ff
              clc
              adc     dp:XOFS
              sta     dp:XOFS
              sep     #0x20
              rts
nextByte:     inc     dp:GLYPH
              bne     1$
              inc     dp:GLYPH+1
1$:           rts

;;; ---------------------------------------------------------------------------
;;; The next disk.
;;; ---------------------------------------------------------------------------

;;; waitDisk: disk DISKNUM in the other drive of the slot: the loader reads
;;; that drive from now on, no prompt. Else INSERT DISK n pulses and the
;;; icon blinks until it is in a drive (both looked at 4 times a second);
;;; a wrong disk in the loader's drive goes out. Then the bar comes back,
;;; and HDR holds the header of the disk. The text screen gets the prompt
;;; too, for tools/probe.lua.
waitDisk:     jsr     abs:otherDrive
              bcs     0$
              rts
0$:           lda     dp:DISKNUM
              ora     #0xb0
              sta     abs:msgInsertNum
              sep     #0x10
              ldx     #.byte0 msgInsert
              ldy     #.byte1 msgInsert
              jsr     abs:printAt
              rep     #0x10
              jsr     abs:clearText
              jsr     abs:drawCount
              stz     dp:FRAMES
              ldx     ##0
              stx     dp:PULSE
              jsr     abs:pulseStep
1$:           jsr     abs:frame
              inc     dp:FRAMES
              lda     dp:FRAMES
              and     #7
              bne     3$
              ldx     dp:PULSE              ; the next step of the pulse
              inx
              cpx     ##6
              bcc     2$
              ldx     ##0
2$:           stx     dp:PULSE
              jsr     abs:pulseStep
3$:           lda     dp:FRAMES
              and     #15
              bne     1$
              jsr     abs:diskIn
              bcc     5$
              jsr     abs:readHeader2
              bcc     4$
              jsr     abs:ejectDisk         ; the wrong disk
5$:           jsr     abs:otherDrive
              bcs     1$
4$:           sep     #0x10
              ldx     #.byte0 msgBlank
              ldy     #.byte1 msgBlank
              jsr     abs:printAt
              rep     #0x10
              jsr     abs:clearText
              ldy     ##ICON_LIT
              jsr     abs:drawIcon
              jmp     abs:drawBar

;;; otherDrive: carry clear when the other drive of the slot (ProDOS drive
;;; bit, SmartPort unit 3 - unit) holds disk DISKNUM: its header in HDR, its
;;; units the loader's from now on. Else the units stay, carry set.
otherDrive:   jsr     abs:swapDrive
              jsr     abs:diskIn
              bcc     8$
              jsr     abs:readHeader2
              bcs     8$
              rts
8$:           jsr     abs:swapDrive
              sec
              rts
swapDrive:    lda     dp:PD_UNIT
              eor     #0x80
              sta     dp:PD_UNIT
              lda     #3
              sec
              sbc     abs:spUnit
              sta     abs:spUnit
              rts

;;; pulseStep: DROP for the step PULSE, then the prompt and the icon (lit
;;; while the text is bright).
pulseStep:    ldx     dp:PULSE
              lda     abs:PULSE_DROP,x
              sta     dp:DROP
              jsr     abs:setDrop
              ldx     ##PROMPT_OFS
              stx     dp:XOFS
              ldy     ##PROMPT
              jsr     abs:drawText
              lda     dp:DISKNUM
              jsr     abs:drawGlyph
              ldy     ##ICON_LIT
              lda     dp:DROP
              cmp     #2
              bcc     1$
              ldy     ##ICON_DARK
1$:           jmp     abs:drawIcon

;;; frame: the next vertical blank (bit 7 of RDVBLBAR changes one way,
;;; then back).
frame:        lda     abs:RDVBLBAR
              bmi     frame
1$:           lda     abs:RDVBLBAR
              bpl     1$
              rts

;;; ---------------------------------------------------------------------------
;;; The text screen: 40 columns, page 1. These routines need X and Y of 8
;;; bits.
;;; ---------------------------------------------------------------------------

clearScreen:  ldx     #23
1$:           lda     abs:rowLo,x
              sta     dp:TMP
              lda     abs:rowHi,x
              sta     dp:TMP+1
              ldy     #39
              lda     #0xa0
2$:           sta     (TMP),y
              dey
              bpl     2$
              dex
              bpl     1$
              rts

;;; printAt: the text at X (low) and Y (high): row, column, characters, 0.
printAt:      stx     dp:MSGPTR
              sty     dp:MSGPTR+1
              ldy     #0
              lda     (MSGPTR),y
              tax
              lda     abs:rowLo,x
              sta     dp:TMP
              lda     abs:rowHi,x
              sta     dp:TMP+1
              iny
              lda     (MSGPTR),y
              clc
              adc     dp:TMP
              sta     dp:TMP
              clc
              lda     dp:MSGPTR
              adc     #2
              sta     dp:MSGPTR
              bcc     1$
              inc     dp:MSGPTR+1
1$:           ldy     #0
2$:           lda     (MSGPTR),y
              beq     3$
              ora     #0x80
              sta     (TMP),y
              iny
              bra     2$
3$:           rts

;;; ---------------------------------------------------------------------------
;;; Data.
;;; ---------------------------------------------------------------------------

rowLo:        .byte   0x00,0x80,0x00,0x80,0x00,0x80,0x00,0x80
              .byte   0x28,0xa8,0x28,0xa8,0x28,0xa8,0x28,0xa8
              .byte   0x50,0xd0,0x50,0xd0,0x50,0xd0,0x50,0xd0
rowHi:        .byte   0x04,0x04,0x05,0x05,0x06,0x06,0x07,0x07
              .byte   0x04,0x04,0x05,0x05,0x06,0x06,0x07,0x07
              .byte   0x04,0x04,0x05,0x05,0x06,0x06,0x07,0x07

magic:        .ascii  "DOOMGS"
bitOf:        .byte   1, 2, 4, 8, 16, 32, 64, 128
settingsBlock: .word  0                     ; DOOM.SETTINGS on disk 1

LEVEL:        .byte   0, 1, 3, 4            ; the color of each glyph value
stripPal:     .word   0x0000, 0x0400, 0x0700, 0x0a00, 0x0d00 ; STRIP_COLORS of
              .word   0x0ff0, 0x000a, 0x0ba9, 0x0ffe ;   tools/gscolor.py
buildId:      .space  4                     ; the build ID of disk 1
PULSE_DROP:   .byte   3, 2, 1, 0, 1, 2      ; the steps of the pulse
GRAY_B:       .byte   8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38
GRAY_G:       .byte   0, 9, 18, 27, 36, 45, 54, 63, 72, 81, 90, 99, 108, 117, 126, 135
GRAY_R:       .byte   0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75
GRAYS:        .word   0x0333, 0x0444, 0x0444, 0x0555, 0x0555, 0x0666, 0x0777, 0x0777
              .word   0x0888, 0x0888, 0x0999, 0x0aaa, 0x0aaa, 0x0bbb, 0x0bbb, 0x0ccc
TAB16:        .space  16

drvAddr:      .word   0                     ; the ProDOS block driver
spAddr:       .word   0                     ; the SmartPort entry
spParams:     .byte   3                     ; the SmartPort parameters:
spUnit:       .byte   1                     ;   unit,
              .word   spList                ;   status or control list,
spCode:       .byte   0                     ;   status or control code
spList:       .byte   0, 0, 0, 0

msgTitle:     .byte   3, 8
              .asciz  "DOOM FOR THE APPLE IIGS"
msgSorry:     .byte   7, 4
              .asciz  "SORRY! THIS APPLE IIGS CANNOT"
msgSorry2:    .byte   8, 4
              .asciz  "RUN DOOM."
msgNeeds:     .byte   10, 4
              .asciz  "DOOM NEEDS 4 MB OF MEMORY."
msgHas:       .byte   11, 4
              .ascii  "THIS APPLE IIGS HAS "
msgHasNum:    .ascii  "0"                   ; then " MB." or, from msgHasNum,
              .space  16                    ;   "LESS THAN 1 MB."
msgMB:        .asciz  " MB."
msgLess:      .asciz  "LESS THAN 1 MB."
msgAdd:       .byte   14, 4
              .asciz  "ADD A MEMORY CARD, OR SET THE"
msgAdd2:      .byte   15, 4
              .asciz  "EMULATOR TO 4 MB OF MEMORY."
msgInsert:    .byte   18, 4
              .ascii  "INSERT DISK "
msgInsertNum: .ascii  "1"
              .byte   0
msgBlank:     .byte   18, 4
              .asciz  "             "
msgReadError: .byte   18, 4
              .asciz  "DISK READ ERROR"

#include "loadfont.s"
