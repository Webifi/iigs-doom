;;; The level loader.
;;;
;;; Each map, the title picture and the intermission pictures are a set of
;;; lumps (tools/levelimg.py) that the game puts into the level window when
;;; it needs them: the banks MM_WINDOW..$3F of src/iigs/memmap.inc, then the
;;; extra RAM banks that the loader found ($0E-$0F, $40-$6F). The lumps come
;;; in units, compressed (tools/b1.py), from the store: in RAM from $40:0000
;;; when the loader loaded it (the 8 MB mode), else from the disks. Both put
;;; the same bytes at the same offsets of the window banks, so the frames
;;; are the same. A set is loaded only when the window holds another one: a
;;; new life on the same map reads nothing.
;;;
;;; The disks: the store map of the headers (tools/mkdisk.py) gives the disk
;;; and the block of each store block. The game looks in the drives of the
;;; boot slot (drive 2 when its SmartPort DIB says a 3.5" drive). When no
;;; drive has the disk, one drive ejects (drive 2 when there are two and
;;; drive 1 holds disk 1, else drive 1) and the sign asks for the disk
;;; ("INSERT DISK n" in the middle of the screen, and the text page line of
;;; the loader for tools/probe.lua) until a drive has it, with no key press.
;;; A wrong disk in that drive goes out again. A hard disk holds all the
;;; store on disk 1: no prompt. A map loads under the LOADING sign of bmLoad;
;;; a picture set from the disks shows it here.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "memmap.inc"

              .extern _Dp, I_Error, fileinfo, numlumps, LC_MAP, PR_IOK, bootInfo
              .extern bmDiskOn, bmDiskOff, IIGS_CopyHuge, memset, W_GetNumForName
              .extern bmDiskAsk, bmSignLoading, bmSignSaving, bmSignOff
              .extern WI_Start, F_StartFinale, AM_LevelCache, colmem
              .extern switchlist, animated_texture_basepic, R_MakeTextureColumns
              .public W_InitLevels, W_LoadSet, W_NeedDisk, W_ZeroBank, W_NEXTBANK
              .public W_COLSTART, W_SET, W_StartInter, W_StartFinale, W_NextDemo
              .extern musTitle, musInter, musFinale
              .public W_LevelDone
              .public lvRead, lvStatus, lvEject, lvDib
              .public titleWipe
              .extern I_ApplyColors, musGo, musLoad, snd_MusicVolume, Z_MallocStatic

BOOTINFO      .equ    0x007e00        ; the loader (src/iigs/loader.s)
BI_EXT        .equ    BOOTINFO + 16   ; the mode, the disks, the banks, the
BI_EXT_SIZE   .equ    84              ;   store map (84 bytes)
BI_UNIT       .equ    bootInfo + 2    ; the game's copy (src/iigs/m_config65.s):
BI_SPUNIT     .equ    bootInfo + 3    ;   the ProDOS unit, the SmartPort unit
BI_DRIVER     .equ    bootInfo + 4    ;   of the drive in use, the ProDOS
BI_SPORT      .equ    bootInfo + 6    ;   block driver, the SmartPort entry
BI_BUILD      .equ    bootInfo + 12   ;   of the slot, the build ID
HDRBUF        .equ    0x7800          ; bank 0 buffers (the loader's HDR and
BLKBUF        .equ    0x7a00          ;   BUF; src/iigs/m_config65.s too)
HDR_DISK      .equ    6               ; the disk header (src/iigs/loader.s)
HDR_BUILD     .equ    432
TEXTLINE      .equ    0xe00554        ; text page row 18, column 4: the prompt
                                      ;   line of the loader for probe.lua
PD_CMD        .equ    0x42            ; the ProDOS block driver (direct page 0)
PD_UNIT       .equ    0x43
PD_BUF        .equ    0x44
PD_BLOCK      .equ    0x46
PD_READ       .equ    1
SP_STATUS     .equ    0               ; SmartPort commands
SP_CONTROL    .equ    4
ST_ONLINE     .equ    0x10            ; the status byte: a disk in the drive,
ST_SWITCHED   .equ    0x01            ;   the disk changed (IIGS Tech Note #25)
DIB_TYPE      .equ    21              ; the device type in a DIB: 1 = 3.5"
RDVBLBAR      .equ    0xe0c019        ; bit 7: the vertical blank
STORE_BASE    .equ    0x400000        ; tools/levelimg.py
SETREC        .equ    12
ENTRY         .equ    10
FILL          .equ    0xffff
UNIT          .equ    0xfffe
UNIT_RAW      .equ    0xfffd
TITLE_SET     .equ    10              ; the title picture (the loader puts it
                                      ;   at the window start at boot)
INTER_SET     .equ    11              ; the intermission and finale pictures
RES_MIN       .equ    32              ; with this many window banks the picture
                                      ;   sets stay (ROM 03 + 4 MB: 38, 8 MB)
NSETS_MAX     .equ    16
SCRATCH       .equ    MM_RECBASE      ; the entries of a set from the disk: the
                                      ;   records are not in use at a load
SCRATCH_IN    .equ    MM_RECBASE + 0x4000 ; a unit's stream from the disks
SCRATCH_INLEN .equ    0xc000          ;   (48 KB, to the end of the bank)
STREAM_GAP    .equ    1024            ; streamIn: the most store bytes between
                                      ;   two streams of one read
B1DP          .equ    0x8d00          ; the direct page of b1Decode (bank 0)

;;; The variables: bank 0 after the disk code (no data_init_table entry, so
;;; no code moves), up to $8FFF.
;;; BI_EXT: the loader's copy in LV_EXT
EX_MODE       .equ    0               ; 1: the store is in RAM
EX_RESD       .equ    1
EX_NDISKS     .equ    2
EX_SBANKS     .equ    3
EX_BANKS      .equ    MM_EX_BANKS     ; the RAM banks $00-$7F, a bit each
EX_MAP        .equ    20              ; 8 runs: first store block, count, first
                                      ;   disk block, disk (words)

W_NEXTBANK    .equ    0x008a00        ; the window bank after bank b (0: none),
                                      ;   for R_ColumnAlloc (src/iigs/r_data65.s)
W_COLSTART    .equ    0x008b00        ; the end of the image of the set: the
                                      ;   texture columns start there
LV_EXT        .equ    MM_LV_EXT       ; (src/iigs/memmap.inc: music reads it)
LV_WIN        .equ    0x008b58        ; the window banks, in order
LV_NWIN       .equ    0x008b98
LV_SET        .equ    0x008b9a        ; the set in the window, 0: none
W_SET         .equ    LV_SET          ; (bmLoad of src/iigs/m_menu65.s)
LV_HDR        .equ    0x008b9c        ; the store header
LV_HDROK      .equ    0x008c64        ; LV_HDR holds it
LV_PLACE      .equ    0x008c66        ; the filepos of the placeholder lump
LV_DK         .equ    0x008c68        ; the disk in drive 1, 2 (0: none or not
                                      ;   known, 0xff: not a disk of this build)
LV_DRV        .equ    0x008c6c        ; the drive of the reads: 0 or 2
LV_BLK        .equ    0x008c6e        ; the store block in BLKBUF, 0xffff: none
LV_E          .equ    0x008c70        ; the entry
LV_N          .equ    0x008c74        ; the entries left
LV_DST        .equ    0x008c76        ; the entry: its address
LV_SRC        .equ    0x008c7a        ;   its store address
LV_LEN        .equ    0x008c7e        ;   its length
LV_LUMP       .equ    0x008c82
LV_T          .equ    0x008c84
LV_PART       .equ    0x008c88        ; the bytes of a block in a copy
LV_WANT       .equ    0x008c8a        ; the disk that must be in a drive
LV_FR         .equ    0x008c8c        ; frames while it waits

              .section lvlcode, text
errWindow:    .asciz  "W_LoadSet: set %d needs %d banks, the window has %d"
errRead:      .asciz  "W_LoadSet: disk read error, disk %d block %u"
errStore:     .asciz  "W_LoadSet: no store map for store block %u"
errChanged:   .asciz  "W_LoadSet: disk %d changed or does not read"
strTitle:     .asciz  "TITLEPIC"
txInsert:     .ascii  "INSERT DISK "  ; (+ the digit, for the text page)
txBlank:      .ascii  "             "

;;; ---------------------------------------------------------------------------
;;; void W_InitLevels(void): at boot, after the directory (W_Init): the
;;; loader's data, the window banks, the title picture in the window.
;;; ---------------------------------------------------------------------------
              .section lvlcode, text
W_InitLevels:
              ldx     ##(LV_END - W_NEXTBANK - 2) ; the variables 0 (no BSS: they
              lda     ##0                   ;   are not in a section)
0$:           sta     long:W_NEXTBANK,x
              dex
              dex
              bpl     0$
              ldx     ##(BI_EXT_SIZE - 2)
1$:           lda     long:BI_EXT,x
              sta     long:LV_EXT,x
              dex
              dex
              bpl     1$
              ldx     ##254                 ; W_NEXTBANK: none
2$:           lda     ##0
              sta     long:W_NEXTBANK,x
              dex
              dex
              bpl     2$
              lda     ##0
              sta     long:LV_NWIN
              sta     long:LV_HDROK
              sta     long:LV_DK
              sta     long:(LV_DK+2)
              lda     ##1                   ; the boot loader left the title
              sta     long:LV_BOOTT         ;   in gray (src/iigs/loader.s)
              lda     ##MM_WINDOW           ; the window: MM_WINDOW..$3F,
3$:           jsr     .kbank addWin         ;   then the extra banks
              inc     a
              cmp     ##MM_WINDOW_END
              bcc     3$
              lda     ##0x0e
4$:           jsr     .kbank ramBank
              bcc     5$
              jsr     .kbank addWin
5$:           inc     a
              cmp     ##0x10
              bcc     4$
              lda     long:(LV_EXT+EX_MODE) ; from $40, after the store in RAM,
              and     ##0x00ff              ;   up to the songs (the banks
              beq     6$                    ;   below $70: a ZipGS caches them)
              lda     long:(LV_EXT+EX_SBANKS)
              and     ##0x00ff
6$:           clc
              adc     ##0x40
7$:           cmp     ##(MM_MUSBANK >> 16)
              bcs     8$
              jsr     .kbank ramBank
              bcc     71$
              jsr     .kbank addWin
71$:          inc     a
              bra     7$
8$:           lda     .near numlumps        ; the placeholder: after the directory
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     ##12
              sta     long:LV_PLACE
              lda     long:(LV_EXT+EX_MODE) ; 8 MB: construct MUSBANK from the
              and     ##0x00ff              ; stored song chunks, once at boot.
              beq     9$
              jsr     .kbank storeHeader
              lda     long:(LV_HDR+6)
              dec     a
              dec     a                    ; the set before common
              jsr     .kbank setRecord
              jsr     .kbank runSet
9$:           rtl                           ; (no set in the window: the first
                                            ;   W_LoadSet loads the common units)

;;; addWin: bank C (kept) is the next bank of the window.
addWin:       pha
              lda     long:LV_NWIN
              tax
              beq     1$
              lda     long:(LV_WIN-1),x     ; W_NEXTBANK[the last] = C
              and     ##0x00ff
              tay
              lda     1,s
              tyx
              sep     #0x20
              sta     long:W_NEXTBANK,x
              rep     #0x20
              lda     long:LV_NWIN
              tax
1$:           lda     1,s
              sep     #0x20
              sta     long:LV_WIN,x
              rep     #0x20
              inx
              txa
              sta     long:LV_NWIN
              pla
              rts

;;; ramBank: carry set when bank C (kept) is RAM (the loader's bits).
ramBank:      pha
              and     ##0x0007
              tax
              lda     long:bitOf,x
              and     ##0x00ff
              sta     long:LV_T
              lda     1,s
              lsr     a
              lsr     a
              lsr     a
              tax
              lda     long:(LV_EXT+EX_BANKS),x
              and     long:LV_T
              cmp     ##1
              pla
              rts

;;; entryPtr: _Dp[0-3] = the directory entry of lump C.
entryPtr:     asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     .near fileinfo
              sta     dp:.tiny _Dp
              lda     .near (fileinfo+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              rts

;;; ---------------------------------------------------------------------------
;;; void W_LoadSet(int16_t set)        In: C = 1-9 a map, 10 the title, 11
;;; the intermission and the end pictures. Nothing when it is there.
;;; ---------------------------------------------------------------------------
W_LoadSet:    cmp     long:LV_SET
              bne     1$
              cmp     ##TITLE_SET
              bcc     0$                    ; same map: keep its song
              pha
              lda     long:(LV_EXT+EX_MODE)
              and     ##0x00ff
              bne     01$
              lda     .near snd_MusicVolume
              beq     01$
              pla                           ; same pictures, different song:
              bra     1$                    ; INTER -> VICTOR on 4 MB
01$:          pla
0$:           rtl
1$:           pha
              cmp     ##TITLE_SET
              bcs     10$
              sta     long:LV_MUSWANT       ; map MUS numbers are 1-9
10$:          lda     ##0
              sta     long:LV_SONGDO
              lda     ##0                   ; (a new set: the zeroed bank goes,
              sta     long:LV_ZB            ;   SCRATCH_IN holds no stream)
              sta     long:LV_RST
              sta     long:LV_CN
              lda     1,s
              cmp     ##TITLE_SET           ; a picture set that stays in the
              bcc     12$                   ;   window (LV_RES): loaded once,
              lda     long:LV_RES           ;   and the map stays
              beq     12$
              lda     1,s
              jsr     .kbank picBit
              and     long:LV_PICOK
              beq     13$
              pla
              rtl
12$:          lda     ##0                   ; the columns and the sprite bounds
              sta     long:LV_SET           ;   of the old set go
              sta     long:LC_MAP
              sta     .near PR_IOK
              jsr     .kbank unmap
              lda     1,s                   ; a map: no boot title on the
              cmp     ##TITLE_SET           ;   screen after it (a timedemo
              bcs     13$                   ;   plays before any title page)
              lda     ##0
              sta     long:LV_BOOTT
13$:          lda     long:(LV_EXT+EX_MODE)
              and     ##0x00ff
              bne     2$
              lda     1,s                   ; a picture set: the LOADING sign
              cmp     ##TITLE_SET           ;   (a map has it from bmLoad)
              bcc     11$
              jsl     long:bmSignLoading
11$:          jsl     long:bmDiskOn
              lda     ##0                   ; the drives: look again
              sta     long:LV_DK
              sta     long:(LV_DK+2)
              sta     long:LV_SAVE
              jsr     .kbank drives
              lda     ##0xffff
              sta     long:LV_BLK
2$:           jsr     .kbank storeHeader
              lda     long:LV_COMMON        ; the common units, once: the last
              bne     21$                   ;   set of the store
              lda     long:(LV_HDR+6)
              dec     a
              jsr     .kbank setRecord
              jsr     .kbank runSet
              jsr     .kbank again          ; (a changed disk: again)
              bcs     2$
              lda     ##1
              sta     long:LV_COMMON
              jsr     .kbank picBases
21$:          lda     1,s                   ; the record of the set: the
              dec     a                     ;   intermission set on the disk of
              cmp     ##(INTER_SET - 1)     ;   the map before (a copy on each
              bne     22$                   ;   level disk, tools/levelimg.py)
              lda     long:LV_LASTDISK
              sec
              sbc     ##2
              bcs     23$
              lda     ##0
23$:          clc
              adc     ##(INTER_SET - 1)
22$:          jsr     .kbank setRecord
              lda     1,s                   ; a map: its disk
              cmp     ##TITLE_SET
              bcs     24$
              lda     long:(LV_HDR+8+7),x
              and     ##0x00ff
              sta     long:LV_LASTDISK
24$:
              lda     long:(LV_HDR+8+6),x   ; the banks (a byte)
              and     ##0x00ff
              cmp     long:LV_NWIN
              bcc     3$
              beq     3$
              sta     long:LV_T             ; I_Error(set, banks, window)
              lda     long:LV_NWIN
              pha
              lda     long:LV_T
              pha
              lda     5,s
              pha
              lda     ##.word0 errWindow
              sta     dp:.tiny _Dp
              lda     ##.word2 errWindow
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
3$:           phx                           ; a map: the texture columns start
              lda     3,s                   ;   after the image: its end in its
              cmp     ##TITLE_SET           ;   last bank, 0: the next bank
              bcs     31$
              lda     long:(LV_HDR+8+6),x
              and     ##0x00ff
              dec     a
              tay
              lda     long:(LV_HDR+8+8),x
              sta     long:W_COLSTART
              tyx
              lda     long:LV_WIN,x
              and     ##0x00ff
              sta     long:(W_COLSTART+2)
              lda     long:W_COLSTART
              bne     31$
              lda     long:(LV_WIN+1),x     ; (a full last bank: the columns
              and     ##0x00ff              ;   start in the next one, zeros
              sta     long:(W_COLSTART+2)   ;   like the tail of a bank)
              jsl     long:W_ZeroBank
31$:          plx
              lda     ##0                   ; a picture set: its banks (after
              sta     long:LV_BOFS          ;   the common units, or at the end
              lda     1,s                   ;   of the window when they stay)
              cmp     ##TITLE_SET
              bcc     34$
              beq     32$
              lda     long:LV_PICI
              bra     33$
32$:          lda     long:LV_PICT
33$:          sta     long:LV_BOFS
34$:          txa
              sta     long:LV_REC
35$:          lda     long:LV_REC
              tax
              jsr     .kbank runSet
              jsr     .kbank again          ; (a changed disk: again)
              bcs     35$
              jsr     .kbank songFinish    ; before texture columns reuse it
              lda     ##0
              sta     long:LV_BOFS
8$:           lda     long:(LV_EXT+EX_MODE)
              and     ##0x00ff
              bne     81$
              jsl     long:bmDiskOff
              lda     1,s
              cmp     ##TITLE_SET
              bcc     81$
              jsl     long:bmSignOff
81$:          lda     1,s                   ; a picture set that stays: the map
              cmp     ##TITLE_SET           ;   is still the set of the window
              bcc     9$
              lda     long:LV_RES
              beq     9$
              pla
              jsr     .kbank picBit
              ora     long:LV_PICOK
              sta     long:LV_PICOK
              rtl
9$:           pla
              sta     long:LV_SET
              rtl

;;; picBit: C = the bit of picture set C in LV_PICOK (1 the title, 2 the
;;; intermission).
picBit:       cmp     ##TITLE_SET
              beq     1$
              lda     ##2
              rts
1$:           lda     ##1
              rts

;;; picBases: the window banks of the picture sets (once, after the common
;;; units). With RES_MIN banks or more the title and the intermission sets
;;; stay at the end of the window (LV_RES): the texture columns of a map
;;; stop before them. Else they load after the common units, over the map.
picBases:     lda     long:(LV_HDR+6)       ; the common set: its banks
              dec     a
              jsr     .kbank setRecord
              lda     long:(LV_HDR+8+6),x
              and     ##0x00ff
              sta     long:LV_PICT
              sta     long:LV_PICI
              lda     long:(LV_EXT+EX_MODE) ; streamed picture songs reuse the
              and     ##0x00ff              ; old map: only RAM-store pictures
              beq     9$                    ; may remain resident
              lda     long:LV_NWIN
              cmp     ##RES_MIN
              bcc     9$
              lda     ##(TITLE_SET - 1)     ; the title: its banks (on the
              jsr     .kbank setRecord      ;   stack: setRecord uses LV_T)
              lda     long:(LV_HDR+8+6),x
              and     ##0x00ff
              pha
              lda     ##(INTER_SET - 1)     ; the intermission (its copies are
              jsr     .kbank setRecord      ;   alike)
              lda     long:(LV_HDR+8+6),x
              and     ##0x00ff
              eor     ##0xffff
              sec
              adc     long:LV_NWIN
              sta     long:LV_PICI          ; = LV_NWIN - its banks
              sec
              sbc     1,s
              sta     long:LV_PICT          ; = LV_PICI - the title's banks
              plx
              tax                           ; the columns stop before them
              lda     long:(LV_WIN-1),x
              and     ##0x00ff
              tax
              sep     #0x20
              lda     #0
              sta     long:W_NEXTBANK,x
              rep     #0x20
              lda     ##1
              sta     long:LV_RES
9$:           rts

;;; ---------------------------------------------------------------------------
;;; void W_LevelDone(void): the end of a map load with its sign (bmLoad of
;;; src/iigs/m_menu65.s): the automap cache (AM_LevelCache of
;;; src/iigs/am_map65.s) reads the vertex hash now, before a frame writes
;;; its records over it (the same bank, src/iigs/memmap.inc); the texture
;;; columns that the game would make in play (moreColumns); the window
;;; bank after the texture columns zeroed now (LV_ZB), so that a texture
;;; made in play that goes on into it does not zero 64 KB in a frame
;;; (demo2 tic 660 of b7: +62 ms); then bmSignOff.
;;; ---------------------------------------------------------------------------
              .extern R_LevelLists
W_LevelDone:  jsl     long:R_LevelLists     ; covered ranges, then automap cache
              jsr     .kbank moreColumns
              lda     long:(colmem+2)
              and     ##0x00ff
              tax
              lda     long:W_NEXTBANK,x
              and     ##0x00ff
              beq     1$
              pha
              jsl     long:W_ZeroBank
              pla
              sta     long:LV_ZB
1$:           jmp     long:bmSignOff

;;; moreColumns: the texture columns that the game would make at their first
;;; sight in play (needColumns of src/iigs/r_seg65.s: demo2 tic 660, 222 ms
;;; against 135 ms around it), made at the load: the other texture of each
;;; switch that has columns (switchlist of src/iigs/p_switch65.s: off and
;;; on in pairs), the 3 slime frames when one has (P_UpdateSpecials of
;;; src/iigs/p_spec65.s). Each only while the column memory is in the
;;; first MORE_BANKS banks of the window: a texture adds less than a bank,
;;; so the 24th bank of a 4 MB window stays free at the load (E1M3 needs
;;; 22.97 banks without these textures, 23.48 with all of them). The first
;;; banks of the window are the same on every IIgs: 4 MB = 8 MB.
NUMSW2        .equ    38              ; (switchlist: the texture numbers)
MORE_BANKS    .equ    22
moreColumns:  lda     ##0
1$:           pha                           ; 4 * the pair
              tax
              lda     long:switchlist,x     ; the off texture made: the on one
              jsr     .kbank madeT
              bcc     2$
              lda     1,s
              tax
              lda     long:(switchlist+2),x
              jsr     .kbank makeT
2$:           lda     1,s                   ; the on texture made: the off one
              tax
              lda     long:(switchlist+2),x
              jsr     .kbank madeT
              bcc     3$
              lda     1,s
              tax
              lda     long:switchlist,x
              jsr     .kbank makeT
3$:           pla
              clc
              adc     ##4
              cmp     ##(NUMSW2 * 2)
              bcc     1$
              lda     long:animated_texture_basepic ; the slime (3 frames)
              cmp     ##254
              bcs     9$
              pha
              ldy     ##3
4$:           jsr     .kbank madeT          ; one of them made: all
              bcs     5$
              inc     a
              dey
              bne     4$
              bra     8$
5$:           lda     1,s
              jsr     .kbank makeT
              lda     1,s
              inc     a
              jsr     .kbank makeT
              lda     1,s
              inc     a
              inc     a
              jsr     .kbank makeT
8$:           pla
9$:           rts

;;; madeT: carry set when texture C has its columns (COLDIR: its bank word
;;; not 0); clear for a number of 256 or more (-1: not in the WAD). C stays.
madeT:        cmp     ##256
              bcs     8$
              pha
              asl     a
              asl     a
              tax
              lda     long:(MM_COLDIR+2),x
              cmp     ##1
              pla
              rts
8$:           clc
              rts

;;; makeT: the columns of texture C (below 256) if it has none and the
;;; column memory is in the first MORE_BANKS banks of the window.
makeT:        jsr     .kbank madeT
              bcs     9$
              cmp     ##256
              bcs     9$
              pha
              lda     long:(colmem+2)
              and     ##0x00ff
              tax
              jsr     .kbank inWindow       ; X = its window index
              pla
              bcc     9$
              cpx     ##MORE_BANKS
              bcs     9$
              jsl     long:R_MakeTextureColumns
9$:           rts

;;; ---------------------------------------------------------------------------
;;; W_StartInter, W_StartFinale: WI_Start (src/iigs/wi_stuff65.s) and
;;; F_StartFinale (src/iigs/f_finale65.s) with their pictures in the window
;;; (INTER_SET). _Dp[0-3] stay (the argument of WI_Start).
;;; int16_t W_NextDemo(int16_t step): the step of the demo sequence after C
;;; (0 the title page, 1 demo3); the title page with its picture. A 4 MB
;;; IIgs that reads floppy disks plays no demo: a map load takes a minute.
;;; ---------------------------------------------------------------------------
W_StartInter: lda     ##28
              sta     long:LV_MUSWANT
              jsr     .kbank interSet
              jmp     long:musInter         ; its music, then WI_Start
W_StartFinale:
              lda     ##31
              sta     long:LV_MUSWANT
              jsr     .kbank interSet
              jmp     long:musFinale        ; its music, then F_StartFinale
interSet:     pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              lda     ##INTER_SET
              jsl     long:W_LoadSet
              pla
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
              rts
W_NextDemo:   inc     a                     ; 0, 1, 0, ...
              cmp     ##2
              bcc     1$
              lda     ##0
1$:           tax
              beq     2$
              jsr     .kbank floppies
              bcs     2$
              txa
              rtl
2$:           lda     ##29
              sta     long:LV_MUSWANT
              lda     long:LV_BOOTT
              beq     3$
              lda     ##0
              sta     long:LV_MUSWANT       ; boot segment, before common
              lda     ##29
              ldx     ##0x8000
              ldy     ##0x002a
              jsl     long:musLoad
3$:           lda     ##TITLE_SET          ; the title page
              jsl     long:W_LoadSet
              lda     long:LV_BOOTT
              beq     4$
              lda     ##0                   ; first title starts at color switch
              rtl
4$:           jmp     long:musTitle         ; its music; C = 0

;;; floppies: carry set when the maps load from floppy disks (the store is
;;; not in RAM, more than one disk).
floppies:     lda     long:(LV_EXT+EX_MODE)
              and     ##0x00ff
              bne     1$
              lda     long:(LV_EXT+EX_NDISKS)
              and     ##0x00ff
              cmp     ##2
              rts
1$:           clc
              rts

;;; setRecord: X = the offset of the record of set C (0-based) in LV_HDR.
setRecord:    asl     a
              sta     long:LV_T
              asl     a
              clc
              adc     long:LV_T             ; * 6
              asl     a                     ; * 12 (SETREC)
              tax
              rts

;;; runSet: the entries of the set of the record at X, one by one. From
;;; the floppy disks it stops (LV_SW = 1) when the disk of the reads
;;; changed: the entries do not add up to the sum of the record, a unit
;;; does not decode to its end, or the drive reports a change (switched).
runSet:       lda     ##0
              sta     long:(LV_SONGPTR+2)
              lda     long:(LV_HDR+8+4),x   ; the entries
              sta     long:LV_N
              lda     long:(LV_HDR+8+10),x  ; the sum of their words
              sta     long:LV_CSUM
              lda     long:(LV_HDR+8),x     ; their store offset
              sta     long:LV_SRC
              lda     long:(LV_HDR+8+2),x
              sta     long:(LV_SRC+2)
              jsr     .kbank entriesIn      ; LV_E = the entries in RAM
              jsr     .kbank entriesOk
              bcs     9$
1$:           lda     long:LV_N
              beq     8$
              jsr     .kbank oneEntry
              lda     long:LV_SW
              bne     9$
              lda     long:LV_E
              clc
              adc     ##ENTRY
              sta     long:LV_E
              lda     long:(LV_E+2)
              adc     ##0
              sta     long:(LV_E+2)
              lda     long:LV_N
              dec     a
              sta     long:LV_N
              bra     1$
8$:           jsr     .kbank switched
9$:           rts

;;; switched: carry set and LV_SW = 1 when the drive of the reads reports
;;; a changed disk (bit 0 of its status, IIGS Technical Note #25): an image
;;; switcher (FloppyEmu) changes the disk without an eject and without a
;;; read error. MAME reports none: entriesOk and unitIn find the change by
;;; the data. A set of floppy disks read from the disks, after a read.
switched:     jsr     .kbank floppyRead
              bcc     9$
              lda     long:LV_BLK           ; (no read yet)
              cmp     ##0xffff
              beq     9$
              jsl     long:lvStatus
              bcs     9$
              and     ##ST_SWITCHED
              bne     badDisk
9$:           clc
              rts

;;; badDisk: the disk of the reads changed: the disks are looked at again
;;; (LV_DK), no block or stream is cached (LV_BLK, LV_CN), runSet stops
;;; (LV_SW = 1), and the set loads again (again). Carry set.
badDisk:      lda     ##0
              sta     long:LV_DK
              sta     long:(LV_DK+2)
              sta     long:LV_CN
              lda     ##0xffff
              sta     long:LV_BLK
              lda     ##1
              sta     long:LV_SW
              sec
              rts

;;; floppyRead: carry set when the store comes from floppy disks (the disk
;;; mode, a set of 2 or more disks).
floppyRead:   lda     long:(LV_EXT+EX_MODE)
              and     ##0x00ff
              bne     9$
              lda     long:(LV_EXT+EX_NDISKS)
              and     ##0x00ff
              cmp     ##2
              rts
9$:           clc
              rts

;;; entriesOk: carry set (badDisk) when the entries read from the floppy
;;; disks do not add up to the sum of their record (LV_CSUM: the words of
;;; the entries, tools/levelimg.py) or when the drive reports a change.
entriesOk:    jsr     .kbank floppyRead
              bcc     9$
              lda     long:LV_E
              sta     dp:.tiny _Dp
              lda     long:(LV_E+2)
              sta     dp:.tiny (_Dp+2)
              lda     long:LV_N             ; the bytes: 10 an entry
              asl     a
              sta     long:LV_T
              asl     a
              asl     a
              clc
              adc     long:LV_T
              tay
              lda     ##0
1$:           dey
              dey
              bmi     2$
              clc
              adc     [.tiny _Dp],y
              bra     1$
2$:           cmp     long:LV_CSUM
              bne     badDisk
              jmp     .kbank switched
9$:           clc
              rts

;;; again: carry set (LV_SW 0 again) when a changed disk stopped runSet;
;;; after 3 loads again the disk does not read: I_Error(disk).
again:        lda     long:LV_SW
              beq     9$
              lda     ##0
              sta     long:LV_SW
              lda     long:LV_RST
              inc     a
              sta     long:LV_RST
              cmp     ##4
              bcs     8$
              sec
              rts
8$:           lda     long:LV_WANT
              pha
              lda     ##.word0 errChanged
              sta     dp:.tiny _Dp
              lda     ##.word2 errChanged
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
9$:           clc
              rts

;;; unmap: each lump in a window bank points to the placeholder again.
unmap:        lda     .near fileinfo
              sta     dp:.tiny _Dp
              lda     .near (fileinfo+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near numlumps
              sta     long:LV_T
1$:           lda     long:LV_T
              beq     9$
              ldy     ##2                   ; its bank: filepos.hi + MM_WAD_BANK
              lda     [.tiny _Dp],y
              clc
              adc     ##MM_WAD_BANK
              and     ##0x00ff
              tax
              jsr     .kbank inWindow
              bcc     2$
              lda     long:LV_RES           ; (a picture that stays)
              beq     21$
              txa
              cmp     long:LV_PICT
              bcs     2$
21$:          lda     long:LV_PLACE
              sta     [.tiny _Dp]
              lda     ##0
              sta     [.tiny _Dp],y
2$:           lda     dp:.tiny _Dp          ; (the directory is in one bank)
              clc
              adc     ##16
              sta     dp:.tiny _Dp
              lda     long:LV_T
              dec     a
              sta     long:LV_T
              bra     1$
9$:           rts

;;; inWindow: carry set when bank X is a window bank, X its index.
inWindow:     phx
              ldx     ##0
1$:           txa
              cmp     long:LV_NWIN
              bcs     8$
              lda     long:LV_WIN,x
              and     ##0x00ff
              cmp     1,s
              beq     9$
              inx
              bra     1$
8$:           plx
              clc
              rts
9$:           pla
              sec
              rts

;;; storeHeader: LV_HDR = the start of the store (once).
storeHeader:  lda     long:LV_HDROK
              bne     9$
              lda     ##0
              sta     long:LV_SRC
              lda     ##.word2 STORE_BASE
              sta     long:LV_SRC+2
              lda     ##.word0 LV_HDR
              sta     long:LV_DST
              lda     ##.word2 LV_HDR
              sta     long:(LV_DST+2)
              lda     ##(8 + SETREC * NSETS_MAX)
              sta     long:LV_LEN
              lda     ##0
              sta     long:(LV_LEN+2)
              jsr     .kbank fetch
              lda     ##1
              sta     long:LV_HDROK
9$:           rts

;;; entriesIn: LV_E = the entries of LV_SRC (a store offset), LV_N of them:
;;; in the store (in RAM), or read from the disks to SCRATCH.
entriesIn:    lda     long:LV_SRC           ; the store address
              sta     long:LV_E
              lda     long:(LV_SRC+2)
              clc
              adc     ##.word2 STORE_BASE
              sta     long:(LV_E+2)
              sta     long:(LV_SRC+2)
              lda     long:(LV_EXT+EX_MODE)
              and     ##0x00ff
              bne     9$
              lda     ##.word0 SCRATCH      ; from the disks
              sta     long:LV_DST
              sta     long:LV_E
              lda     ##.word2 SCRATCH
              sta     long:(LV_DST+2)
              sta     long:(LV_E+2)
              lda     long:LV_N             ; * ENTRY
              asl     a
              sta     long:LV_T
              asl     a
              asl     a
              clc
              adc     long:LV_T
              sta     long:LV_LEN
              lda     ##0
              sta     long:(LV_LEN+2)
              jsr     .kbank fetch
9$:           rts

;;; oneEntry: the entry at LV_E: a lump to its window address and its
;;; directory entry, or a fill with zeros.
oneEntry:     lda     long:LV_E             ; _Dp[4-7]: the entry
              sta     dp:.tiny (_Dp+4)
              lda     long:(LV_E+2)
              sta     dp:.tiny (_Dp+6)
              lda     [.tiny (_Dp+4)]       ; the lump
              sta     long:LV_LUMP
              ldy     ##2                   ; the window bank | 0x80
              lda     [.tiny (_Dp+4)],y
              and     ##0x00ff
              bit     ##0x0080
              beq     1$
              and     ##0x007f
              clc
              adc     long:LV_BOFS          ; (the banks of a picture set)
              tax
              lda     long:LV_WIN,x
              and     ##0x00ff
1$:           sta     long:(LV_DST+2)
              ldy     ##3
              lda     [.tiny (_Dp+4)],y     ; its offset
              sta     long:LV_DST
              ldy     ##5
              lda     [.tiny (_Dp+4)],y     ; the store address (24 bits)
              sta     long:LV_SRC
              ldy     ##7                   ; (its bank: the store from $40)
              lda     [.tiny (_Dp+4)],y
              and     ##0x00ff
              sta     long:(LV_SRC+2)
              ldy     ##8
              lda     [.tiny (_Dp+4)],y     ; the length (0: 64 KB for a fill)
              sta     long:LV_LEN
              lda     ##0
              sta     long:(LV_LEN+2)
              lda     long:LV_LUMP
              cmp     ##0xffe0
              bcc     92$
              cmp     ##0xfffd
              bcs     92$
              jmp     .kbank songEntry
92$:          cmp     ##FILL
              bne     3$
              lda     long:LV_LEN           ; zeros (0: the whole bank)
              bne     31$
              jmp     .kbank zeroBank
31$:          jmp     .kbank zeros
3$:           cmp     ##UNIT
              bne     32$
              jsr     .kbank switched       ; (a changed disk: runSet stops)
              bcs     4$
              jmp     .kbank unitIn
32$:          cmp     ##UNIT_RAW            ; a unit as it is (the store of a
              bne     5$                    ;   hard disk): its bytes after the
              lda     long:LV_SRC           ;   length word, as a lump
              clc
              adc     ##2
              sta     long:LV_SRC
              lda     long:LV_LEN
              sec
              sbc     ##2
              sta     long:LV_LEN
              jmp     .kbank fetch
5$:           lda     long:LV_LUMP          ; filepos = the address - MM_WAD
              jsr     .kbank entryPtr       ;   (before the fetch: a read from
              lda     long:LV_DST           ;   the disks moves LV_DST on)
              sta     [.tiny _Dp]
              lda     long:(LV_DST+2)
              sec
              sbc     ##MM_WAD_BANK
              ldy     ##2
              sta     [.tiny _Dp],y
              lda     long:LV_LEN
              beq     4$                    ; a marker lump: only its address
              jmp     .kbank fetch
4$:           rts

;;; Song selectors/chunks live after the image's FILL entries. Absolute
;;; staging addresses never change W_COLSTART or the planner layout.
;;; Volume zero and the 8 MB bank path skip all song reads and DOC writes.
songEntry:    cmp     ##0xfff7
              bne     98$
              jmp     .kbank cacheSong
98$:          cmp     ##0xfff8             ; boot-only RAM copy: decoded chunk
              bne     0$                    ; to its (possibly crossing) bank
              jmp     .kbank fetch
0$:           cmp     ##0xfff0
              bcs     3$
              sec
              sbc     ##0xffe0
              tax
              lda     long:songMus,x
              and     ##0x00ff
              cmp     long:LV_MUSWANT
              bne     1$
              lda     long:(LV_EXT+EX_MODE)
              and     ##0x00ff
              bne     1$
              lda     .near snd_MusicVolume
              beq     1$
              lda     ##1
              bra     2$
1$:           lda     ##0
2$:           sta     long:LV_SONGDO
              rts
3$:           lda     long:LV_SONGDO
              beq     9$
              lda     long:LV_LUMP
              cmp     ##0xfff5
              beq     31$
              cmp     ##0xfff6
              bne     32$
31$:          jmp     .kbank cachedSong
32$:          cmp     ##0xfffc
              bne     4$
              jmp     .kbank unitIn
4$:           cmp     ##0xfff9             ; raw boundary byte
              bne     5$
              lda     long:LV_SRC
              clc
              adc     ##2
              sta     long:LV_SRC
              lda     long:LV_LEN
              dec     a
              dec     a
              sta     long:LV_LEN
              jmp     .kbank fetch
5$:           lda     long:LV_DST          ; after the whole set succeeds,
              sta     long:LV_SONGPTR      ; songFinish consumes the unit
              lda     long:(LV_DST+2)
              sta     long:(LV_SONGPTR+2)
              lda     long:LV_SRC          ; marker source field = unit size
              sta     long:LV_SONGLEN
              lda     long:(LV_SRC+2)
              sta     long:(LV_SONGLEN+2)
9$:           rts

songFinish:   lda     long:(LV_SONGPTR+2)
              beq     9$
              tay
              lda     long:LV_SONGPTR
              tax
              lda     long:LV_MUSWANT
              jsl     long:musLoad
              lda     long:LV_SONGPTR
              sta     long:LV_DST
              lda     long:(LV_SONGPTR+2)
              sta     long:(LV_DST+2)
              lda     long:(LV_SONGLEN+2)  ; restore the transient space so
              beq     1$                    ; no song bytes become overread
              jsr     .kbank zeroBank
              lda     long:(LV_DST+2)
              inc     a
              sta     long:(LV_DST+2)
              lda     ##0
              sta     long:LV_DST
1$:           lda     long:LV_SONGLEN
              beq     9$
              jsr     .kbank zeros
9$:           rts
cacheSong:    lda     long:(LV_EXT+EX_MODE)
              and     ##0x00ff
              bne     9$                    ; 8 MB has the store itself
              lda     long:LV_DST          ; cache index: allocated once,
              asl     a                     ; reused on a changed-disk retry
              asl     a
              pha
              tax
              lda     long:(LV_CACHE+2),x
              bne     1$
              lda     long:LV_LEN
              jsl     long:Z_MallocStatic
              tay
              txa
              pha
              lda     3,s
              tax
              pla
              sta     long:(LV_CACHE+2),x
              tya
              sta     long:LV_CACHE,x
1$:           plx
              lda     long:LV_CACHE,x
              sta     long:LV_DST
              lda     long:(LV_CACHE+2),x
              sta     long:(LV_DST+2)
              jmp     .kbank fetch
9$:           rts

cachedSong:   lda     long:LV_SRC          ; cache index -> compressed unit
              asl     a
              asl     a
              tax
              lda     long:LV_CACHE,x
              sta     long:LV_SRC
              sta     dp:.tiny _Dp
              lda     long:(LV_CACHE+2),x
              sta     long:(LV_SRC+2)
              sta     dp:.tiny (_Dp+2)
              lda     long:LV_LUMP
              cmp     ##0xfff5
              bne     1$
              ldy     ##2                  ; raw boundary chunk: one byte
              sep     #0x20
              lda     [.tiny _Dp],y
              pha
              rep     #0x20
              lda     long:LV_DST
              sta     dp:.tiny _Dp
              lda     long:(LV_DST+2)
              sta     dp:.tiny (_Dp+2)
              sep     #0x20
              pla
              sta     [.tiny _Dp]
              rep     #0x20
              rts
1$:           lda     [.tiny _Dp]
              sta     long:LV_RAW
              lda     long:LV_LEN
              sta     long:LV_SLEN
              jmp     .kbank b1Decode

songMus:      .byte   1,2,3,4,5,6,7,8,9,28,29,31,32

;;; unitIn: the unit of the entry: its stream (LV_LEN bytes at the store
;;; address LV_SRC: the unit's length, then B1) decoded to LV_DST. From the
;;; disks the stream goes to SCRATCH_IN first.
unitIn:       lda     long:LV_LEN           ; (the end of the stream: b1Decode)
              sta     long:LV_SLEN
              lda     long:(LV_EXT+EX_MODE)
              and     ##0x00ff
              bne     1$
              jsr     .kbank streamIn       ; LV_SRC: the stream in SCRATCH_IN
1$:           lda     long:LV_SRC           ; the unit's length
              sta     dp:.tiny _Dp
              lda     long:(LV_SRC+2)
              sta     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp]
              sta     long:LV_RAW
              jsr     .kbank b1Decode
              bcc     9$                    ; a stream from the floppy disks
              jsr     .kbank floppyRead     ;   that does not end at its end:
              bcc     9$                    ;   a changed disk
              jmp     .kbank badDisk
9$:           rts

;;; streamIn: LV_SRC = the stream of the unit (LV_LEN bytes at the store
;;; address LV_SRC) in SCRATCH_IN, read from the disks when it is not there
;;; yet. A read takes the streams of the units after it in the entries too,
;;; while each starts at most STREAM_GAP bytes after the one before in the
;;; store and all fit SCRATCH_IN: a block read right after a block read
;;; costs one turn of the interleave (25 ms), the first read after a decode
;;; waits for the disk to come round (75-95 ms, 2026-09-27). LV_CS: the
;;; store address of SCRATCH_IN, LV_CN bytes (0: none).
streamIn:     lda     long:LV_SRC           ; LV_CT = LV_SRC - LV_CS: the
              sec                           ;   stream is in SCRATCH_IN when
              sbc     long:LV_CS            ;   LV_CT + LV_LEN <= LV_CN
              sta     long:LV_CT
              lda     long:(LV_SRC+2)
              sbc     long:(LV_CS+2)
              bne     2$
              lda     long:LV_CT
              clc
              adc     long:LV_LEN
              bcs     2$
              cmp     long:LV_CN
              beq     1$
              bcs     2$
1$:           lda     long:LV_CT            ; there: LV_SRC in SCRATCH_IN
              clc
              adc     ##.word0 SCRATCH_IN
              sta     long:LV_SRC
              lda     ##.word2 SCRATCH_IN
              sta     long:(LV_SRC+2)
              rts
2$:           lda     long:LV_SRC           ; a read from this stream on
              sta     long:LV_CS
              lda     long:(LV_SRC+2)
              sta     long:(LV_CS+2)
              lda     long:LV_LEN
              sta     long:LV_CN
              lda     long:LV_E             ; X: the entry in SCRATCH
              tax
              lda     long:LV_N             ; the entries after it
3$:           dec     a
              beq     5$
              pha
              txa
              clc
              adc     ##ENTRY
              tax
              lda     long:SCRATCH,x        ; a unit
              cmp     ##UNIT
              bne     4$
              lda     long:(SCRATCH+5),x    ; that starts in the 64 KB after
              sec                           ;   LV_CS,
              sbc     long:LV_CS
              sta     long:LV_CT
              lda     long:(SCRATCH+7),x
              and     ##0x00ff
              sbc     long:(LV_CS+2)
              bne     4$
              lda     long:LV_CT            ;   not before the end of the
              sec                           ;   streams so far and at most
              sbc     long:LV_CN            ;   STREAM_GAP bytes after it,
              bcc     4$
              cmp     ##(STREAM_GAP + 1)
              bcs     4$
              lda     long:LV_CT            ;   and ends in SCRATCH_IN
              clc
              adc     long:(SCRATCH+8),x
              bcs     4$
              cmp     ##(SCRATCH_INLEN + 1)
              bcs     4$
              sta     long:LV_CN
              pla
              bra     3$
4$:           pla
5$:           lda     long:LV_DST           ; the read: LV_CN bytes from LV_CS
              pha                           ;   to SCRATCH_IN
              lda     long:(LV_DST+2)
              pha
              lda     ##.word0 SCRATCH_IN
              sta     long:LV_DST
              lda     ##.word2 SCRATCH_IN
              sta     long:(LV_DST+2)
              lda     long:LV_CN
              sta     long:LV_LEN
              jsr     .kbank fetch
              pla
              sta     long:(LV_DST+2)
              pla
              sta     long:LV_DST
              lda     long:LV_SLEN          ; (LV_LEN again for the caller)
              sta     long:LV_LEN
              lda     ##.word0 SCRATCH_IN
              sta     long:LV_SRC
              lda     ##.word2 SCRATCH_IN
              sta     long:(LV_SRC+2)
              rts

;;; ---------------------------------------------------------------------------
;;; b1Decode: the B1 stream at LV_SRC + 2 to LV_DST, LV_RAW bytes: the
;;; decoder of the codec study (research_notes/compression 2026-09-25/codec/
;;; bench/b1dec.s). X is the input offset, Y the output offset; the banks go
;;; into the MVN operands and the long reads. Neither the stream nor the
;;; unit crosses a bank, and the unit ends before the end of its bank.
;;; Carry set: the stream (LV_SLEN bytes) does not end at the end of the
;;; output and of the input, so it is not a unit (another disk).
;;; ---------------------------------------------------------------------------
B1_BITS       .equ    0               ; (direct page B1DP)
B1_OFF        .equ    2
B1_INP        .equ    4
B1_CNT        .equ    6
B1_END        .equ    8
B1_SEND       .equ    10              ; the end of the stream

b1Decode:     phb
              phd
              sep     #0x20
              lda     long:(LV_SRC+2)       ; the banks
              sta     long:(b1Lmvn+2)
              sta     long:(b1Rdb+3)
              sta     long:(b1Rdw+3)
              lda     long:(LV_DST+2)
              sta     long:(b1Lmvn+1)
              sta     long:(b1Mmvn+1)
              sta     long:(b1Mmvn+2)
              rep     #0x20
              lda     ##B1DP
              tcd
              lda     long:LV_DST
              clc
              adc     long:LV_RAW
              sta     dp:B1_END
              lda     ##0x8000
              sta     dp:B1_BITS
              lda     ##1
              sta     dp:B1_OFF
              lda     long:LV_SRC
              clc
              adc     long:LV_SLEN
              sta     dp:B1_SEND
              lda     long:LV_SRC
              inc     a
              inc     a
              tax
              lda     long:LV_DST
              tay
              jsr     .kbank b1Lits
              cpy     dp:B1_END             ; a sound stream ends at the end of
              bne     8$                    ;   the output and of the input
              cpx     dp:B1_SEND
              bne     8$
              pld
              plb
              clc
              rts
8$:           pld
              plb
              sec
              rts

b1Lits:       jsr     .kbank b1Gamma        ; a literal run
              dec     a
b1Lmvn:       .byte   0x54, 0x00, 0x00      ; MVN: input -> output
              cpy     dp:B1_END
              bcs     b1Done
              asl     dp:B1_BITS            ; after literals: 0 = the last offset
              bne     1$
              jsr     .kbank b1Refill
1$:           bcs     b1New
              jsr     .kbank b1Gamma
              bra     b1Copy
b1New:        jsr     .kbank b1Gamma        ; a new offset: the high part,
              dec     a
              xba
              sep     #0x20
b1Rdb:        lda     long:0x000000,x       ;   the low byte
              rep     #0x20
              inx
              lsr     a
              inc     a
              sta     dp:B1_OFF
              jsr     .kbank b1GammaC       ; the length - 1
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
              bcs     b1Done
              asl     dp:B1_BITS            ; after a match: 0 = literals
              bne     2$
              jsr     .kbank b1Refill
2$:           bcc     b1Lits
              bra     b1New
b1Done:       rts

;;; b1Gamma: C = an Elias gamma code (interlaced). b1GammaC: its first
;;; control bit is in the carry.
b1Gamma:      lda     ##1
b1G0:         asl     dp:B1_BITS
              bne     b1G1
              jsr     .kbank b1Refill
b1G1:         bcs     b1G3
              asl     dp:B1_BITS
              bne     b1G2
              jsr     .kbank b1Refill
b1G2:         rol     a
              bra     b1G0
b1G3:         rts
b1GammaC:     lda     ##1
              bra     b1G1

;;; b1Refill: the next 16 bits (C stays); the carry = the first of them.
b1Refill:     pha
b1Rdw:        lda     long:0x000000,x
              inx
              inx
              sec
              rol     a
              sta     dp:B1_BITS
              pla
              rts

;;; ---------------------------------------------------------------------------
;;; titleWipe: from D_Wipe (I_FinishUpdate) of src/iigs/i_viigs65.s when a new
;;; picture comes, in place of its lda ##0, ldx ##510 for the black colors.
;;; The first new picture after the boot is the title page, over the title
;;; that the boot loader leaves on the screen in gray (LV_BOOTT, PLAN decision
;;; 32): its pixels are there already, so no black (decision 33). Its colors
;;; (I_ApplyColors) and its rows 191-199 over the load strip go on in the
;;; vertical blank, so the change shows between two frames; the other marked
;;; rows copy later with the same bytes. Then back to the caller of D_Wipe.
;;; Else C = 0, X = 510: the black colors as before.
;;; The VBL flag comes at row 192 of the 200 (Apple IIGS Technical Note #40),
;;; 1.5 ms before the bottom border ends: that and the 1.7 ms of writes do not
;;; fit before the border (a MAME frame showed rows 197-199 of the strip), so
;;; the writes wait TITLE_WAIT reads of a soft switch (0.8-1 us each at the
;;; 1 MHz of the slow side, on any accelerator): 1.6-2 ms, into the blank,
;;; and they end before row 0 of the next frame (4.4 ms after the flag).
;;; ---------------------------------------------------------------------------
TITLE_STRIP   .equ    191 * 160       ; the title's rows 191-199 (the load
TITLE_BACK    .equ    0x012000        ;   strip of src/iigs/loader.s) in the
TITLE_SCREEN  .equ    0xe12000        ;   back buffer (SHRBUF of i_viigs65.s)
TITLE_WAIT    .equ    2000
titleWipe:    lda     long:LV_BOOTT
              bne     1$
              lda     ##0
              ldx     ##510
              rtl
1$:           lda     ##0
              sta     long:LV_BOOTT
              jsr     .kbank frame          ; the VBL flag
              ldx     ##TITLE_WAIT          ; past the bottom border
              sep     #0x20
2$:           lda     long:RDVBLBAR
              dex
              bne     2$
              rep     #0x20
              jsl     long:I_ApplyColors    ; the SCBs and the colors
              jsl     long:musGo            ; the intro music with them (the
                                            ;   song musLoad put in place,
                                            ;   src/iigs/s_sound65.s)
              phb                           ; (MVN sets the data bank)
              ldx     ##((TITLE_BACK & 0xffff) + TITLE_STRIP)
              ldy     ##((TITLE_SCREEN & 0xffff) + TITLE_STRIP)
              lda     ##(9 * 160 - 1)
              .byte   0x54, (TITLE_SCREEN >> 16), (TITLE_BACK >> 16) ; MVN
              plb
              tsc                           ; back to the caller of D_Wipe:
              clc                           ;   the return of this JSL goes
              adc     ##3
              tcs
              rtl

;;; ---------------------------------------------------------------------------
;;; void W_ZeroBank(int16_t bank)      In: C. The bank all zeros: a new bank
;;; of texture columns (R_ColumnAlloc of src/iigs/r_data65.s), so that the
;;; reads past its last column find zeros on every IIgs; nothing for the bank
;;; that W_LevelDone zeroed (LV_ZB, once). _Dp[0-7] stay.
;;; ---------------------------------------------------------------------------
W_ZeroBank:   cmp     long:LV_ZB
              bne     1$
              lda     ##0
              sta     long:LV_ZB
              rtl
1$:           pei     dp:.tiny (_Dp+6)
              pei     dp:.tiny (_Dp+4)
              pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              sta     long:(LV_DST+2)
              lda     ##0
              sta     long:LV_DST
              jsr     .kbank zeroBank
              pla
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
              pla
              sta     dp:.tiny (_Dp+4)
              pla
              sta     dp:.tiny (_Dp+6)
              rtl

;;; zeroBank: 64 KB of zeros at LV_DST (offset 0).
zeroBank:     lda     ##0x8000
              jsr     .kbank zeros
              lda     ##0x8000
              sta     long:LV_DST
;;; zeros: C bytes (not 0) of zeros at LV_DST.
zeros:        sta     dp:.tiny (_Dp+4)
              lda     long:LV_DST
              sta     dp:.tiny _Dp
              lda     long:(LV_DST+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##0
              jsl     long:memset
              rts

;;; fetch: LV_LEN bytes (LV_LEN + 2 = 0) from the store at LV_SRC to LV_DST:
;;; a copy from the store in RAM, else the blocks from the disks.
fetch:        lda     long:(LV_EXT+EX_MODE)
              and     ##0x00ff
              beq     2$
              lda     long:LV_SRC           ; IIGS_CopyHuge(dst, src, len)
              sta     dp:.tiny _Dp
              lda     long:(LV_SRC+2)
              sta     dp:.tiny (_Dp+2)
              lda     long:LV_LEN
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              lda     long:(LV_DST+2)
              tax
              lda     long:LV_DST
              jsl     long:IIGS_CopyHuge
              rts
2$:           lda     long:LV_LEN           ; each block of it
              bne     21$
              rts
21$:          jsr     .kbank storeBlock     ; the block of LV_SRC in BLKBUF
              lda     long:LV_SRC           ; the part: from its offset in the
              and     ##0x01ff              ;   block, up to the block end or
              sta     long:LV_T             ;   the length
              eor     ##0xffff
              sec
              adc     ##512
              cmp     long:LV_LEN
              bcc     3$
              lda     long:LV_LEN
3$:           sta     long:LV_PART
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              lda     long:LV_T
              clc
              adc     ##BLKBUF
              sta     dp:.tiny _Dp
              stz     dp:.tiny (_Dp+2)
              lda     long:(LV_DST+2)
              tax
              lda     long:LV_DST
              jsl     long:IIGS_CopyHuge
              lda     long:LV_SRC           ; on: src, dst += part, len -= part
              clc
              adc     long:LV_PART
              sta     long:LV_SRC
              lda     long:(LV_SRC+2)
              adc     ##0
              sta     long:(LV_SRC+2)
              lda     long:LV_DST
              clc
              adc     long:LV_PART
              sta     long:LV_DST
              lda     long:(LV_DST+2)
              adc     ##0
              sta     long:(LV_DST+2)
              lda     long:LV_LEN
              sec
              sbc     long:LV_PART
              sta     long:LV_LEN
              brl     2$

;;; storeBlock: BLKBUF = the store block of LV_SRC (a store address).
storeBlock:   lda     long:(LV_SRC+2)       ; b = (LV_SRC - STORE_BASE) >> 9
              sec
              sbc     ##.word2 STORE_BASE
              xba
              sta     long:LV_T
              lda     long:(LV_SRC+1)
              and     ##0x00ff
              ora     long:LV_T
              lsr     a
              cmp     long:LV_BLK
              bne     1$
              rts
1$:           sta     long:LV_BLK
              ldx     ##0                   ; its run of the store map
2$:           cpx     ##64
              bcs     8$
              lda     long:(LV_EXT+EX_MAP+2),x ; the count (0: no more)
              beq     8$
              lda     long:LV_BLK
              sec
              sbc     long:(LV_EXT+EX_MAP),x
              bcc     3$
              cmp     long:(LV_EXT+EX_MAP+2),x
              bcc     4$
3$:           txa
              clc
              adc     ##8
              tax
              bra     2$
4$:           clc                           ; the disk block
              adc     long:(LV_EXT+EX_MAP+4),x
              pha
              lda     long:(LV_EXT+EX_MAP+6),x ; the disk
              pha
              lda     ##3                   ; 3 reads; after an error the
              sta     long:LV_TRY           ;   drives are looked at again (the
5$:           lda     1,s                   ;   disk may be another one now)
              jsr     .kbank useDisk
              bcs     7$                    ; (a set of one disk that does not
              lda     3,s                   ;   read)
              tax
              lda     ##PD_READ
              ldy     ##BLKBUF
              jsl     long:lvRead
              bcc     6$
              lda     ##0
              sta     long:LV_DK
              sta     long:(LV_DK+2)
              lda     long:LV_TRY
              dec     a
              sta     long:LV_TRY
              bne     5$
7$:           lda     ##.word0 errRead      ; I_Error(disk, block)
              sta     dp:.tiny _Dp
              lda     ##.word2 errRead
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
6$:           pla
              pla
              rts
8$:           lda     long:LV_BLK
              pha
              lda     ##.word0 errStore
              sta     dp:.tiny _Dp
              lda     ##.word2 errStore
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error

;;; ---------------------------------------------------------------------------
;;; void W_NeedDisk(int16_t disk)      In: C. Disk access state on
;;; (bmDiskOn), the SAVING sign up. The disk is in a drive, and the reads
;;; and writes go to that drive (the units in bootInfo for
;;; src/iigs/m_config65.s too); a prompt until a drive has it. Carry set:
;;; a set of one disk (a hard disk) whose header does not read or is not
;;; of this build (no prompt: no disk can replace it).
;;; ---------------------------------------------------------------------------
W_NeedDisk:   pha
              lda     ##0                   ; the drives: look again
              sta     long:LV_DK
              sta     long:(LV_DK+2)
              lda     ##1                   ; SAVING after a prompt
              sta     long:LV_SAVE
              jsr     .kbank drives
              pla
              jsr     .kbank useDisk
              rtl

;;; drives: LV_TWO = 2 when drive 2 of the boot slot is a 3.5" drive (the
;;; device type of its DIB), 1 when it is another device. A failed inquiry
;;; leaves 0 (not known: the next call asks again; a prompt asks at each
;;; look). A hard disk set (1 disk): 1, no SmartPort call.
drives:       lda     long:LV_TWO
              bne     9$
              lda     long:(LV_EXT+EX_NDISKS)
              and     ##0x00ff
              cmp     ##2
              bcc     7$
              lda     ##2
              sta     long:LV_DRV
              jsr     .kbank setUnit
              jsl     long:lvDib
              bcs     9$
              cmp     ##1
              bne     7$
              lda     ##2
              bra     8$
7$:           lda     ##1
8$:           sta     long:LV_TWO
9$:           rts

;;; useDisk: disk C in a drive, LV_DRV that drive; carry clear. A set of
;;; one disk (a hard disk) not found: carry set, no prompt.
useDisk:      sta     long:LV_WANT
              cmp     long:LV_DK            ; known in a drive
              bne     1$
              lda     ##0
              bra     8$
1$:           cmp     long:(LV_DK+2)
              bne     2$
              lda     ##2
              bra     8$
2$:           ldx     ##0                   ; look: drive 1, then drive 2
              jsr     .kbank lookDrive
              lda     long:LV_DK
              cmp     long:LV_WANT
              bne     3$
              lda     ##0
              bra     8$
3$:           ldx     ##2
              jsr     .kbank lookDrive
              lda     long:(LV_DK+2)
              cmp     long:LV_WANT
              bne     4$
              lda     ##2
              bra     8$
4$:           lda     long:(LV_EXT+EX_NDISKS) ; one disk: a read error
              and     ##0x00ff
              cmp     ##2
              bcc     9$
              jsr     .kbank askDisk
              bra     useDisk2
8$:           sta     long:LV_DRV
              jsr     .kbank setUnit
              clc
              rts
9$:           sec
              rts
useDisk2:     lda     long:LV_WANT
              bra     useDisk

;;; setUnit: the units of drive LV_DRV in bootInfo (the loader's drive is
;;; drive 1; drive 2 has the other drive bit of the ProDOS unit and the
;;; SmartPort unit 3 - unit). The boot units stay in bootUnits.
setUnit:      lda     long:unitsOk
              bne     1$
              lda     long:BI_UNIT
              sta     long:bootUnits
              lda     ##1
              sta     long:unitsOk
1$:           lda     long:LV_DRV
              tax
              lda     long:bootUnits
              cpx     ##0
              beq     2$
              eor     ##0x0080              ; ProDOS: the drive bit
              pha
              lda     long:bootUnits        ; SmartPort: 3 - unit
              xba
              and     ##0x00ff
              eor     ##0xffff
              sec
              adc     ##3
              xba
              and     ##0xff00
              sta     long:LV_U
              pla
              and     ##0x00ff
              ora     long:LV_U
2$:           sta     long:BI_UNIT
              rts

;;; lookDrive: LV_DK[X] = the disk of this build in drive X / 2 + 1: 0 for
;;; none, 0xff for a disk that is not of this build or that does not read.
;;; Drive 2 only when it is a 3.5" drive; a hard disk is always online.
lookDrive:    txa
              sta     long:LV_DRV
              lda     ##0
              sta     long:LV_DK,x
              cpx     ##2
              bne     0$
              lda     long:LV_TWO
              cmp     ##2
              bne     9$
0$:           jsr     .kbank setUnit
              lda     long:(LV_EXT+EX_NDISKS)
              and     ##0x00ff
              cmp     ##2
              bcc     1$
              jsl     long:lvStatus
              bcs     9$
              and     ##ST_ONLINE
              beq     9$
1$:           lda     ##PD_READ             ; the header, once more after an
              ldx     ##1                   ;   error: the first access after
              ldy     ##HDRBUF              ;   a disk change can fail
              jsl     long:lvRead
              bcc     2$
              lda     ##PD_READ
              ldx     ##1
              ldy     ##HDRBUF
              jsl     long:lvRead
              bcs     8$
2$:           ldx     ##4                   ; "DOOMGS" and the build ID
3$:           lda     long:HDRBUF,x
              cmp     long:diskMagic,x
              bne     8$
              dex
              dex
              bpl     3$
              lda     long:(HDRBUF+HDR_BUILD)
              cmp     long:BI_BUILD
              bne     8$
              lda     long:(HDRBUF+HDR_BUILD+2)
              cmp     long:(BI_BUILD+2)
              bne     8$
              lda     long:(HDRBUF+HDR_DISK)
              and     ##0x00ff
              bra     81$
8$:           lda     ##0x00ff
81$:          pha
              lda     long:LV_DRV
              tax
              pla
              sta     long:LV_DK,x
9$:           rts

;;; askDisk: disk LV_WANT is in no drive. The prompt drive LV_PD (drive 2
;;; when there are two and drive 1 holds disk 1, else drive 1) ejects, and
;;; the sign asks for the disk until a drive holds it, 4 looks a second. A
;;; wrong disk in the prompt drive goes out again.
askDisk:      ldx     ##0
              lda     long:LV_TWO
              cmp     ##2
              bne     1$
              lda     long:LV_DK
              cmp     ##1
              bne     1$
              ldx     ##2
1$:           txa
              sta     long:LV_PD
              jsr     .kbank ejectPD
              jsr     .kbank promptOn
              lda     long:LV_WANT          ; the sign
              jsl     long:bmDiskAsk
2$:           lda     ##15                  ; a quarter of a second
              sta     long:LV_FR
3$:           jsr     .kbank frame
              lda     long:LV_FR
              dec     a
              sta     long:LV_FR
              bne     3$
              jsr     .kbank drives         ; (drive 2 not known: ask again)
              ldx     ##0
              jsr     .kbank lookDrive
              ldx     ##2
              jsr     .kbank lookDrive
              lda     long:LV_DK
              cmp     long:LV_WANT
              beq     8$
              lda     long:(LV_DK+2)
              cmp     long:LV_WANT
              beq     8$
              lda     long:LV_PD            ; a wrong disk in the prompt drive
              tax
              lda     long:LV_DK,x
              beq     2$
              jsr     .kbank ejectPD
              bra     2$
8$:           lda     long:LV_SAVE          ; the sign of the step again
              beq     81$
              jsl     long:bmSignSaving
              jmp     .kbank promptOff
81$:          jsl     long:bmSignLoading
              jmp     .kbank promptOff

;;; ejectPD: the prompt drive ejects its disk.
ejectPD:      lda     long:LV_PD
              sta     long:LV_DRV
              jsr     .kbank setUnit
              jsl     long:lvEject
              rts

;;; promptOn: INSERT DISK n on the text page (the line of the loader, for
;;; tools/probe.lua). promptOff: the line blank.
promptOn:     sep     #0x20
              ldx     ##11
1$:           lda     long:txInsert,x
              ora     #0x80
              sta     long:TEXTLINE,x
              dex
              bpl     1$
              lda     long:LV_WANT
              ora     #0xb0
              sta     long:(TEXTLINE+12)
              rep     #0x20
              rts
promptOff:    sep     #0x20
              ldx     ##12
1$:           lda     long:txBlank,x
              ora     #0x80
              sta     long:TEXTLINE,x
              dex
              bpl     1$
              rep     #0x20
              rts

;;; frame: the next vertical blank (bit 7 of RDVBLBAR goes off, then on).
frame:        sep     #0x20
1$:           lda     long:RDVBLBAR
              bmi     1$
2$:           lda     long:RDVBLBAR
              bpl     2$
              rep     #0x20
              rts

              .section lvlcode, text
diskMagic:    .ascii  "DOOMGS"
bitOf:        .byte   1, 2, 4, 8, 16, 32, 64, 128

unitsOk       .equ    0x008c8e
bootUnits     .equ    0x008c90        ; the units of the boot drive
LV_U          .equ    0x008c92        ; setUnit: scratch
LV_TWO        .equ    0x008c94        ; 2: drive 2 is a 3.5" drive, 1: not, 0:
                                      ;   not known
LV_PD         .equ    0x008c96        ; the prompt drive: 0 or 2
LV_SAVE       .equ    0x008c98        ; 1: SAVING after a prompt, 0: LOADING
LV_RAW        .equ    0x008c9a        ; the length of a unit
LV_COMMON     .equ    0x008c9c        ; 1: the common units are in the window
LV_LASTDISK   .equ    0x008c9e        ; the disk of the last map (its record)
LV_RES        .equ    0x008ca0        ; 1: the picture sets stay in the window
LV_PICT       .equ    0x008ca2        ; the first window bank of the title set,
LV_PICI       .equ    0x008ca4        ;   of the intermission set
LV_PICOK      .equ    0x008ca6        ; the picture sets that are in (picBit)
LV_BOFS       .equ    0x008ca8        ; the bank offset of the set that loads
LV_ZB         .equ    0x008caa        ; the window bank after the texture
                                      ;   columns, zeroed (W_LevelDone), 0: none
LV_TRY        .equ    0x008cac        ; storeBlock: the reads left
LV_SW         .equ    0x008cae        ; 1: a changed disk stopped runSet
LV_REC        .equ    0x008cb0        ; the record of the set (runSet again)
LV_CSUM       .equ    0x008cb2        ; the sum of the entries of the set
LV_SLEN       .equ    0x008cb4        ; the bytes of a unit's stream
LV_RST        .equ    0x008cb6        ; the sets loaded again (a changed disk)
LV_CS         .equ    0x008cb8        ; streamIn: the store address of the
LV_CN         .equ    0x008cbc        ;   bytes in SCRATCH_IN, how many (0: none)
LV_CT         .equ    0x008cbe        ; streamIn: scratch
LV_BOOTT      .equ    0x008cc0        ; 1: the boot title is on the screen,
                                      ;   in gray (titleWipe)
LV_MUSWANT    .equ    0x008cc2
LV_SONGDO     .equ    0x008cc6
LV_SONGPTR    .equ    0x008cc8
LV_SONGLEN    .equ    0x008ccc
LV_CACHE      .equ    0x008cd0        ; eight compressed VICTOR chunk pointers
LV_END        .equ    0x008cf0        ; (the end of the variables)

;;; ---------------------------------------------------------------------------
;;; The firmware of the slot needs bank 0 code, D = 0, emulation mode and a
;;; stack in page 1: lvRead (C = PD_READ or 2, X = block, Y = a bank 0
;;; buffer), lvStatus (C = the status byte), lvEject, lvDib (C = the device
;;; type of the DIB), for the drive of the units in bootInfo. Carry set on
;;; an error. Native mode, A/X/Y 16 bits in and out; interrupts off and the
;;; ROM in (bmDiskOn).
;;; ---------------------------------------------------------------------------
              .section diskcode, text
lvRead:       phd
              phb
              phk                           ; this bank: 0
              plb
              pha
              lda     ##0
              tcd
              pla
              sep     #0x20
              sta     dp:PD_CMD
              lda     long:BI_UNIT
              sta     dp:PD_UNIT
              rep     #0x20
              stx     dp:PD_BLOCK
              sty     dp:PD_BUF
              lda     long:BI_DRIVER
              sta     abs:dkTarget
              tsc
              sta     abs:dkStack
              sec
              xce
              jsr     abs:dkJump
              jmp     abs:dkBack

lvStatus:     lda     ##SP_STATUS           ; STATUS code 0: the status byte
              ldx     ##0
              bra     spCall
lvEject:      lda     ##SP_CONTROL          ; CONTROL code 4: eject
              ldx     ##4
              bra     spCall
lvDib:        lda     ##SP_STATUS           ; STATUS code 3: the DIB
              ldx     ##3
spCall:       phd
              phb
              phk
              plb
              sep     #0x20
              sta     abs:spCmd
              txa
              sta     abs:spCode
              lda     long:BI_SPUNIT
              sta     abs:spUnit
              rep     #0x20
              lda     ##0
              tcd
              sta     abs:spList
              lda     long:BI_SPORT
              sta     abs:dkTarget
              tsc
              sta     abs:dkStack
              sec
              xce
              jsr     abs:dkJump
spCmd:        .byte   0
              .word   spParams
              php                           ; (the carry: the error)
              lda     abs:spList            ; the status byte, or the type of
              ldx     abs:spCode            ;   the DIB
              cpx     #3
              bne     1$
              lda     abs:(spList+DIB_TYPE)
1$:           plp

;;; dkBack: native mode again with the stack of the game; C = the byte in A
;;; (8 bits), carry = the error of the firmware.
dkBack:       sta     abs:dkResult
              lda     #0
              rol     a                     ; the error, over the mode change
              clc
              xce
              rep     #0x30
              and     ##1
              tax
              lda     abs:dkStack
              tcs
              lda     abs:dkResult
              and     ##0x00ff
              cpx     ##1                   ; carry: the error
              plb
              pld
              rtl

dkJump:       jmp     (abs:dkTarget)
dkTarget:     .word   0
dkStack:      .word   0
dkResult:     .word   0
spParams:     .byte   3                     ; 3 parameters: the unit, the
spUnit:       .byte   1                     ;   list, the code
              .word   spList
spCode:       .byte   0
spList:       .space  25                    ; the status byte, or the DIB
