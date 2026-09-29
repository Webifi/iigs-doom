;;; SHR video. 320 x 200, 16 colors per row.
;;; R_DrawLists writes the 3D view directly. Other drawing uses the bank $01
;;; back buffer and marks byte ranges; I_FinishUpdate copies only those.
;;; Nibble-table and row changes invalidate the captured HUD text code.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"
#include "loadbar.inc"
#include "viewwin.inc"

              .extern _Dp, _g_gamma, fullcolormap, iigs_shrcmapA, iigs_shrcmapB, FLATCM
              .extern _g_gamemap
              .extern W_GetNumForName, W_GetLumpByNum, W_LumpLength, I_Error
              .extern IIGS_CopyHuge, IIGS_DrawPatch, _UDivMod16, IIGS_MulLo16
              .extern IIGS_RunText, IIGS_BeginCapture, IIGS_TextCode
              .extern titleWipe

NEWVIDEO      .equ    0xe0c029
BORDER        .equ    0xe0c034
SHR_SCREEN    .equ    0xe12000        ; the pixels of the screen
SHR_SCB       .equ    0xe19d00
SHR_PALETTE   .equ    0xe19e00
SHRBUF        .equ    0x012000        ; the back buffer
STCACHE       .equ    0x01a200        ; the status bar background
VIEWSAVE      .equ    MM_VIEWSAVE     ; the view under the menu
NIBTAB        .equ    MM_NIBTAB       ; 16 nibble tables of 0x400 bytes
FUZZ_DARKEN   .equ    0x01a000
FUZZ_DIR      .equ    0x01a100
CAPVAL        .equ    (MM_CAPVAL + 0x2000) ; the text captures
CAPMSK        .equ    (MM_CAPMSK + 0x2000)
VTXHASH       .equ    MM_VTXHASH      ; x, y, num (6 bytes) at level load
VTXHASH_SIZE  .equ    8192
VTX_MAX       .equ    7000
SEGVTX        .equ    MM_SEGVTX       ; the vertex numbers of the seg ends
SEGVTX_MAX    .equ    MM_SEGVTX_MAX
SEGSTAMP      .equ    MM_SEGSTAMP
VIEW_ROWS     .equ    168
ST_HEIGHT     .equ    32
ST_SHR_OFFSET .equ    VIEW_ROWS * 160
ST_SHR_LENGTH .equ    ST_HEIGHT * 160
VIEW_SHR_LENGTH .equ  VIEW_ROWS * 160
PALREC_A      .equ    14 * 16 * 2 + 256 ; GSVIEWn: the bytes A, then B
PALREC_SIZE   .equ    14 * 16 * 2 + 256 ; a palette record
STAT_PALS     .equ    8               ; GSSTAT: the palette of each status
STAT_RECS     .equ    ST_HEIGHT       ;   bar row, then STAT_PALS records
                                      ;   (palettes 1-8, tools/wadtool.py)
OVL_PAL       .equ    STAT_PALS + 1   ; GSOVL: the palettes of text in a
MENU_PAL      .equ    OVL_PAL         ;   level (tools/wadtool.py): the
MSG_PAL       .equ    OVL_PAL + 1     ;   paused menu over the view in 5
AMAP_PAL      .equ    OVL_PAL + 2     ;   grays, the message strip, the
OVL_PALS      .equ    3               ;   full automap
LEVEL_PALS    .equ    OVL_PAL + OVL_PALS ; the palettes of a level
TINTS         .equ    14              ; the PLAYPAL tints
TINT_ROW      .equ    LEVEL_PALS * 32 ; the level palettes of one tint
STRIP_ROWS    .equ    10              ; the message strip: rows 0-9
MENU_GRAYS    .equ    5               ; colors 0-4 of the menu palette
PALREC_PAIRS  .equ    14 * 16 * 2     ; palette records and SHR pictures,
PICTURE_SIZE  .equ    36864           ;   see tools/gscolor.py
PICTURE_SCB   .equ    32000
PICTURE_PALS  .equ    32256
PICTURE_PAIRS .equ    32768
NO_PALETTE_CHANGE .equ 100
TEXTMAX       .equ    40
FUZZTABLE     .equ    50
TEXT_H        .equ    10              ; the rows of a HUD text line

              .section near, data
viewpalnum:   .word   0xffff          ; the palette record of the 3D view
statpalnum:   .word   0xffff          ; the palette record of the status bar
ovlpalnum:    .word   0xffff          ; the palettes of the text in a level
viewpal:      .word   0               ; the palette of the view rows
levelcopy:    .word   0               ; 1: TINTPAL to the screen (levelPalettes)
strippal:     .word   0               ; the palette of the message strip rows
picturenum:   .word   0xffff          ; the SHR picture on screen, -1: level
stcachenum:   .word   0xffff          ; the status bar in STCACHE

              .section zfar, bss
DRB:          .space  200             ; the marked bytes of each row: the
DRE:          .space  200             ;   first, and the last + 1 (0: none)
GRAYMAP:      .space  256             ; a byte of the view in the grays of
                                      ;   the menu palette (I_SetLevelPalette)
              .public TINTPAL
TINTPAL:      .space  TINTS * TINT_ROW ; the level palettes in each tint

              .section znear, bss
              .public iigs_rowbase, iigs_rowpageL, iigs_rowpageR
#if defined IIGS_PHASES
              .public iigs_phase
iigs_phase:   .space  2
#endif
;;; The nibble table part of each row: palette * 0x400 + (row & 1) * 0x100
;;; (src/iigs/patch65.s, src/iigs/am_map65.s), and its high byte for the left
;;; and the right pixel of a byte.
iigs_rowbase: .space  400
iigs_rowpageL: .space 200
iigs_rowpageR: .space 200
scb:          .space  200             ; the hardware state that
palette:      .space  512             ;   I_FinishUpdate writes
scbchanged:   .space  2
palettecount: .space  2
curtint:      .space  2
newpal:       .space  2               ; (0 at the start: tint 0 comes first)
              .public iigs_textShown
iigs_textShown: .space 4              ; a HUD text slot is on the screen
DRY0:         .space  2               ; the rows with marked bytes: DRY0 ..
DRY1:         .space  2               ;   DRY1 - 1 (DRY1 = 0: none)
MR_Y:         .space  2               ; markRect, showDirty
MR_Y1:        .space  2
MR_B:         .space  2
MR_T:         .space  2
textValid:    .space  4               ; the HUD text slots: valid, length,
textLen:      .space  4               ;   y, text
textY:        .space  4
textText:     .space  2 * TEXTMAX
VG_G:         .space  2               ; gammaColor
VG_C:         .space  2
VT_SLOT:      .space  2               ; the text cache
VT_P:         .space  4
VT_LEN:       .space  2
VT_Y:         .space  2
VR_END:       .space  2               ; setRows
VR_PAL:       .space  2
VL_VIEW:      .space  4               ; levelPalettes, I_SetLevelPalette
VL_STAT:      .space  4
VL_I:         .space  2
VL_NAME:      .space  8
VL_R:         .space  2               ; the darker colors
VL_G:         .space  2
VL_B:         .space  2
VL_N:         .space  2
VL_K:         .space  2
VL_BEST:      .space  2
VL_DIST:      .space  2
VL_BESTDIST:  .space  2
VL_DARKER:    .space  16
VP_REC:       .space  4               ; a picture or a lump
VP_NUM:       .space  2
VP_Y:         .space  2               ; its row
VP_OFS:       .space  2
VP_Y0:        .space  2               ; a rectangle
VP_Y1:        .space  2
VP_B0:        .space  2
VP_B1:        .space  2
VD_X:         .space  2               ; the raw data
VD_OFFSET:    .space  2
VD_LEN:       .space  2
VD_DONE:      .space  2
VD_SB:        .space  2               ;   the status bar
VD_RB:        .space  2               ; pairByte: the row base
VD_ROW:       .space  32              ; V_DrawBackground: a row of tiles
VS_N:         .space  2               ; the seg vertices: the segs,
VS_I:         .space  2
VS_NUMVTX:    .space  2               ;   the vertices,
VS_X:         .space  2               ;   a point, its hash entry
VS_Y:         .space  2
VS_H:         .space  2

              .section coldfar, bss
VL_TABS:      .space  2               ; I_SetLevelPalette: viewpalnum + 1 of
                                      ;   the view tables (0: none)
VL_TINTS:     .space  2               ; buildTints: viewpalnum + 1 of TINTPAL
VL_TGAMMA:    .space  2               ;   (0: none), and its gamma
VS_MAP:       .space  2               ; I_InitSegVertices: the map of SEGVTX
                                      ;   (0: none)

              .section cfar, rodata
strGsstat:    .asciz  "GSSTAT"
strGsovl:     .asciz  "GSOVL"
strGsview:    .asciz  "GSVIEW0"
errSegs:      .asciz  "I_InitSegVertices: %u segs"
errVertices:  .asciz  "I_InitSegVertices: more than %u vertices"
gammatab:     .byte   0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
              .byte   0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 12, 13, 14, 15
              .byte   0, 2, 4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 14, 15
              .byte   0, 3, 4, 5, 7, 8, 8, 9, 10, 11, 12, 12, 13, 14, 14, 15
              .byte   0, 3, 5, 6, 7, 8, 9, 10, 11, 11, 12, 13, 13, 14, 14, 15
squares:      .word   0, 1, 4, 9, 16, 25, 36, 49, 64, 81, 100, 121, 144, 169, 196, 225
;;; The spectre fuzz (fuzzoffset of Doom): 1 the row below, 0 the row above.
fuzzDir:      .byte   1, 0, 1, 0, 1, 1, 0
              .byte   1, 1, 0, 1, 1, 1, 0
              .byte   1, 1, 1, 0, 0, 0, 0
              .byte   1, 0, 0, 1, 1, 1, 1, 0
              .byte   1, 0, 1, 1, 0, 0, 1
              .byte   1, 0, 0, 0, 0, 1, 1
              .byte   1, 1, 0, 1, 1, 0, 1

              .section farcode, text

;;; ---------------------------------------------------------------------------
;;; I_InitProgress: fill the next loader-bar cell (loadbar.inc).
;;; Cells start seven pixels apart. The edge mask keeps a shared gap black.
;;; ---------------------------------------------------------------------------
              .section znear, bss
IP_E1:        .space  2               ; the first and last byte of a row
IP_E3:        .space  2
              .section near, data
initcell:     .word   LOAD_CELLS      ; the next cell of the game

              .section farcode, text
              .public I_InitProgress
I_InitProgress:
              lda     .near initcell
              cmp     ##BAR_CELLS
              bcs     9$
              tay                           ; the cell
              inc     .near initcell
              sty     .near IP_E1           ; x = BAR_X + 7 * cell
              asl     a
              asl     a
              asl     a
              sec
              sbc     .near IP_E1
              clc
              adc     ##BAR_X
              lsr     a                     ; the first screen byte
              clc
              adc     ##BAR_ROW
              tax
              lda     ##BAR_FULL
              sta     .near IP_E1
              sta     .near IP_E3
              tya
              lsr     a                     ; an odd cell has an odd x
              bcs     1$
              lda     ##BAR_FULL & 0xf0
              sta     .near IP_E3
              bra     2$
1$:           lda     ##BAR_FULL & 0x0f
              sta     .near IP_E1
2$:           ldy     ##5                   ; 5 rows of 3 bytes
              sep     #0x20
3$:           lda     .near IP_E1
              sta     long:SHR_SCREEN,x
              lda     #BAR_FULL
              sta     long:(SHR_SCREEN+1),x
              lda     .near IP_E3
              sta     long:(SHR_SCREEN+2),x
              rep     #0x21
              txa
              adc     ##160
              tax
              sep     #0x20
              dey
              bne     3$
              rep     #0x20
9$:           rtl

;;; ---------------------------------------------------------------------------
;;; I_InitGraphicsHardwareSpecificCode: start SHR, buffers and map-0 tables.
;;; Keep the loader title on screen until the first frame.
;;; I_ShutdownGraphics turns SHR off.
;;; ---------------------------------------------------------------------------
              .public I_InitGraphicsHardwareSpecificCode, I_ShutdownGraphics
I_InitGraphicsHardwareSpecificCode:
              lda     ##0
              ldx     ##31998               ; the back buffer, the text
4$:           sta     long:SHRBUF,x         ;   captures
              sta     long:CAPVAL,x
              sta     long:CAPMSK,x
              dex
              dex
              bpl     4$
              lda     ##.word0 strGsstat
              sta     dp:.tiny _Dp
              lda     ##.word2 strGsstat
              sta     dp:.tiny (_Dp+2)
              jsl     long:W_GetNumForName
              sta     .near statpalnum
              lda     ##.word0 strGsovl
              sta     dp:.tiny _Dp
              lda     ##.word2 strGsovl
              sta     dp:.tiny (_Dp+2)
              jsl     long:W_GetNumForName
              sta     .near ovlpalnum
              sep     #0x20                 ; I_InitFuzz
              ldx     ##(FUZZTABLE - 1)
5$:           lda     long:fuzzDir,x
              sta     long:FUZZ_DIR,x
              dex
              bpl     5$
              rep     #0x20
              lda     ##0
              jsl     long:I_SetLevelPalette
              sep     #0x20
              lda     long:BORDER
              and     #0xf0
              sta     long:BORDER
              lda     long:NEWVIDEO
              ora     #0xc0
              sta     long:NEWVIDEO
              rep     #0x20
              rtl
I_ShutdownGraphics:
              sep     #0x20
              lda     long:NEWVIDEO
              and     #0x7f
              sta     long:NEWVIDEO
              rep     #0x20
              rtl

;;; ---------------------------------------------------------------------------
;;; void I_SetPalette(int8_t pal): the tint of the next update.
;;; void I_ReloadPalette(void): the gamma changed.
;;; void I_FinishUpdate(void), D_Wipe(void): the new colors, and the marked
;;;   bytes of the back buffer on the screen. A new picture comes with black
;;;   colors first, so the old one never shows in its colors.
;;; void I_ApplyColors(void): the new colors now (just before the 3D view
;;;   goes to the screen, R_DrawLists of src/iigs/r_list65.s).
;;; void I_ShowDirty(void): the marked bytes on the screen.
;;; ---------------------------------------------------------------------------
              .public I_SetPalette, I_ReloadPalette, I_FinishUpdate, D_Wipe
              .public I_ApplyColors, I_ShowDirty
I_SetPalette: and     ##0x00ff
              sta     .near newpal
              rtl
I_ReloadPalette:
              lda     .near picturenum      ; a picture: new at the next draw
              bmi     1$
              lda     ##0xffff
              sta     .near picturenum
              rtl
1$:           lda     .near viewpalnum      ; a level: its colors
              bmi     2$
              jsr     .kbank buildTints
              jsr     .kbank levelPalettes
2$:           rtl
I_FinishUpdate:
D_Wipe:       lda     .near palettecount    ; a new picture: black first
              beq     2$
              jsl     long:titleWipe        ; C = 0, X = 510 (the title page
              nop                           ;   over the boot title: no black,
              nop                           ;   src/iigs/w_level65.s)
1$:           sta     long:SHR_PALETTE,x
              dex
              dex
              bpl     1$
              jsr     .kbank newColors
              jsr     .kbank showDirty
              jsr     .kbank pictureColors
              rtl
2$:           jsr     .kbank newColors
              jsr     .kbank showDirty
              rtl
I_ApplyColors:
              jsr     .kbank newColors
              jsr     .kbank pictureColors
              rtl
I_ShowDirty:  jsr     .kbank showDirty
              rtl

;;; newColors: a new tint, the SCBs, the level palettes of the tint.
newColors:    lda     .near newpal          ; a new tint
              cmp     ##NO_PALETTE_CHANGE
              beq     1$
              sta     .near curtint
              lda     .near picturenum
              bpl     11$
              jsr     .kbank levelPalettes
11$:          lda     ##NO_PALETTE_CHANGE
              sta     .near newpal
1$:           lda     .near scbchanged      ; the SCBs
              beq     3$
              ldx     ##198
2$:           lda     .near scb,x
              sta     long:SHR_SCB,x
              dex
              dex
              bpl     2$
              stz     .near scbchanged
3$:           lda     .near levelcopy       ; the level palettes of the
              beq     9$                    ;   tint (TINTPAL)
              stz     .near levelcopy
              lda     .near curtint
              ldx     ##TINT_ROW
              jsl     long:IIGS_MulLo16
              clc
              adc     ##.word0 TINTPAL
              sta     dp:.tiny _Dp
              lda     ##.word2 TINTPAL
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              jsr     .kbank tintSpan       ; 32, or every palette at tint 0
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              lda     ##(SHR_PALETTE & 0xffff)
              ldx     ##(SHR_PALETTE >> 16)
              jsl     long:IIGS_CopyHuge
9$:           rts

;;; pictureColors: the palettes of a picture.
pictureColors:
              lda     .near palettecount
              beq     9$
              asl     a
              tax
1$:           dex
              dex
              lda     .near palette,x
              sta     long:SHR_PALETTE,x
              txa
              bne     1$
              stz     .near palettecount
9$:           rts

;;; ---------------------------------------------------------------------------
;;; I_MarkRect: A/X/Y 16-bit; C = first row, X = exclusive end row,
;;; Y = first byte | last byte << 8. Rows 0..200, bytes 0..159.
;;; The range is copied at I_FinishUpdate or I_ShowDirty. markRect is the
;;; near entry; markRows marks full rows.
;;; ---------------------------------------------------------------------------
              .public I_MarkRect
I_MarkRect:   jsr     .kbank markRect
              rtl
markRows:     ldy     ##(159 << 8)
markRect:     sty     .near MR_B
              stx     .near MR_Y1
              cmp     .near MR_Y1
              bcs     9$                    ; (no rows)
              tax
              lda     .near DRY1            ; the rows with marks grow
              bne     1$
              stx     .near DRY0
              lda     .near MR_Y1
              sta     .near DRY1
              bra     3$
1$:           cpx     .near DRY0
              bcs     2$
              stx     .near DRY0
2$:           lda     .near MR_Y1
              cmp     .near DRY1
              bcc     3$
              sta     .near DRY1
3$:           sep     #0x20                 ; Each row mark occupies one byte.
4$:           lda     long:DRE,x
              bne     5$
              lda     .near MR_B
              sta     long:DRB,x
              lda     .near (MR_B+1)
              inc     a
              sta     long:DRE,x
              bra     7$
5$:           lda     .near MR_B
              cmp     long:DRB,x
              bcs     6$
              sta     long:DRB,x
6$:           lda     .near (MR_B+1)
              inc     a
              cmp     long:DRE,x
              bcc     7$
              sta     long:DRE,x
7$:           inx
              cpx     .near MR_Y1
              bcc     4$
              rep     #0x20
9$:           rts

;;; showDirty: copy marked back-buffer bytes from $01 to $E1, then unmark.
;;; A/X/Y 16-bit. MVN bytes are opcode, destination bank, source bank;
;;; A is count - 1. Save DBR because MVN changes it.
showDirty:    lda     .near DRY0
              sta     .near MR_Y
1$:           lda     .near MR_Y
              cmp     .near DRY1
              bcs     8$
              tax
              lda     long:DRE,x
              and     ##0x00ff
              beq     4$                    ; (no marks)
              sta     .near MR_T            ; the end
              lda     long:DRB,x
              and     ##0x00ff
              sta     .near MR_B            ; the first byte
              lda     .near MR_Y            ; its address: SHRBUF + y * 160 + b
              jsr     .kbank rowOffset
              clc
              adc     ##(SHRBUF & 0xffff)
              adc     .near MR_B
              tax
              tay
              lda     .near MR_T
              sec
              sbc     .near MR_B
              dec     a                     ; (MVN: the count - 1)
              phb
              .byte   0x54, (SHR_SCREEN >> 16), (SHRBUF >> 16)
              plb
              ldx     .near MR_Y
              sep     #0x20
              lda     #0
              sta     long:DRE,x
              rep     #0x20
4$:           inc     .near MR_Y
              bra     1$
8$:           stz     .near DRY0
              stz     .near DRY1
              rts

;;; ---------------------------------------------------------------------------
;;; void I_ViewPalette(int16_t pal)    In: C.
;;; The view uses palette 0; the full automap uses AMAP_PAL.
;;; The message strip follows. Paused menus use MENU_PAL for all rows.
;;; void I_MessageStrip(boolean on, boolean clear)    In: C, X.
;;; On: rows 0 to STRIP_ROWS - 1 of the view with MSG_PAL (black and the reds
;;; of the font) for the message, black when they turn on or with clear
;;; (the renderer does not draw them: viewtop); off: the palette of the view.
;;; ---------------------------------------------------------------------------
              .public I_ViewPalette, I_MessageStrip
I_ViewPalette:
              cmp     .near viewpal
              beq     1$
              sta     .near viewpal
              sta     .near strippal
              tay
              lda     ##0
              ldx     ##VIEW_ROWS
              jsr     .kbank setRows
1$:           rtl
I_MessageStrip:
              cmp     ##0
              beq     2$
              lda     .near strippal        ; they turn on, or clear: black
              cmp     ##MSG_PAL
              bne     0$
              txa
              beq     11$
0$:           ldx     ##(STRIP_ROWS * 160 - 16)
1$:           lda     ##0
              sta     long:SHRBUF,x
              sta     long:(SHRBUF+2),x
              sta     long:(SHRBUF+4),x
              sta     long:(SHRBUF+6),x
              sta     long:(SHRBUF+8),x
              sta     long:(SHRBUF+10),x
              sta     long:(SHRBUF+12),x
              sta     long:(SHRBUF+14),x
              txa
              sec
              sbc     ##16
              tax
              bpl     1$
              stz     .near iigs_textShown  ; (the message is gone)
              lda     ##0
              ldx     ##STRIP_ROWS
              jsr     .kbank markRows
11$:          lda     ##MSG_PAL
              bra     3$
2$:           lda     .near viewpal
3$:           cmp     .near strippal
              beq     4$
              sta     .near strippal
              tay
              lda     ##0
              ldx     ##STRIP_ROWS
              jsr     .kbank setRows
4$:           rtl

;;; ---------------------------------------------------------------------------
;;; Palettes.
;;; ---------------------------------------------------------------------------

;;; gammaColor: I_Gamma: C = the color C (4 bits each of red, green, blue)
;;; with the gamma table of _g_gamma.
gammaColor:   pha
              lda     .near _g_gamma
              asl     a
              asl     a
              asl     a
              asl     a
              sta     .near VG_G
              lda     1,s                   ; blue
              and     ##0x000f
              clc
              adc     .near VG_G
              tax
              lda     long:gammatab,x
              and     ##0x00ff
              sta     .near VG_C
              lda     1,s                   ; green
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              and     ##0x000f
              clc
              adc     .near VG_G
              tax
              lda     long:gammatab,x
              and     ##0x00ff
              asl     a
              asl     a
              asl     a
              asl     a
              ora     .near VG_C
              sta     .near VG_C
              pla                           ; red
              xba
              and     ##0x000f
              clc
              adc     .near VG_G
              tax
              lda     long:gammatab,x
              and     ##0x00ff
              xba
              ora     .near VG_C
              rts

;;; buildTints: cache all 14 tints with gamma at level or gamma changes.
;;; A later tint change only copies the selected row (levelPalettes).
buildTints:
              lda     .near _g_gamma        ; (I_SetLevelPalette)
              sta     long:VL_TGAMMA
              lda     .near viewpalnum
              inc     a
              sta     long:VL_TINTS
              dec     a
              jsl     long:W_GetLumpByNum
              sta     .near VL_VIEW
              stx     .near (VL_VIEW+2)
              lda     ##0
              ldx     ##1
              jsr     .kbank tintRecords
              lda     .near statpalnum
              jsl     long:W_GetLumpByNum
              clc
              adc     ##STAT_RECS
              sta     .near VL_VIEW
              txa
              adc     ##0
              sta     .near (VL_VIEW+2)
              lda     ##1
              ldx     ##STAT_PALS
              jsr     .kbank tintRecords
              lda     .near ovlpalnum
              jsl     long:W_GetLumpByNum
              sta     .near VL_VIEW
              stx     .near (VL_VIEW+2)
              lda     ##OVL_PAL
              ldx     ##OVL_PALS
              jmp     .kbank tintRecords

;;; levelPalettes: I_LevelPalettes: the level palettes in the tint curtint
;;; go to the screen at the next update (from TINTPAL).
levelPalettes:
              lda     ##1
              sta     .near levelcopy
              rts

;;; tintRecords: palettes C to C + X - 1 of TINTPAL get the colors of the
;;; palette records from VL_VIEW (tintColors), one after the other.
tintRecords:  stx     .near VL_K
1$:           pha
              jsr     .kbank tintColors
              lda     .near VL_VIEW         ; the next record
              clc
              adc     ##PALREC_SIZE
              sta     .near VL_VIEW
              bcc     2$
              inc     .near (VL_VIEW+2)
2$:           pla
              inc     a
              dec     .near VL_K
              bne     1$
              rts

;;; tintColors: palette C of TINTPAL gets the 16 colors of each of the 14
;;; tints of the palette record at VL_VIEW, with gamma.
tintColors:   asl     a                     ; the palette in a tint row
              asl     a
              asl     a
              asl     a
              asl     a
              sta     .near VL_STAT
              lda     .near VL_VIEW
              sta     dp:.tiny _Dp
              lda     .near (VL_VIEW+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##0                   ; the record: tint * 32 + color * 2
1$:           stz     .near VL_I            ; the 16 colors of a tint
2$:           lda     [.tiny _Dp],y
              jsr     .kbank gammaColor
              ldx     .near VL_STAT
              sta     long:TINTPAL,x
              inx
              inx
              stx     .near VL_STAT
              iny
              iny
              inc     .near VL_I
              lda     .near VL_I
              cmp     ##16
              bcc     2$
              lda     .near VL_STAT         ; the next tint row
              clc
              adc     ##(TINT_ROW - 32)
              sta     .near VL_STAT
              cpy     ##(TINTS * 32)
              bcc     1$
              rts

;;; buildNibtab: I_BuildNibtab(C, the pairs at _Dp[0-3]): the nibble table
;;; of the palette C from its best pairs: the left pixel even row, the left
;;; pixel odd row, the right pixel even row, the right pixel odd row.
buildNibtab:  jsr     .kbank textInvalidate
              xba                           ; C * 0x400
              asl     a
              asl     a
              tax
              ldy     ##0
              sep     #0x20
1$:           lda     [.tiny _Dp],y
              and     #0xf0
              sta     long:NIBTAB,x
              lda     [.tiny _Dp],y
              asl     a
              asl     a
              asl     a
              asl     a
              sta     long:(NIBTAB+0x100),x
              lda     [.tiny _Dp],y
              and     #0x0f
              sta     long:(NIBTAB+0x200),x
              lda     [.tiny _Dp],y
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              sta     long:(NIBTAB+0x300),x
              inx
              iny
              cpy     ##256
              bcc     1$
              rep     #0x20
              rts

;;; setRows: I_SetRows(first C, count X, palette Y): the palette of the rows.
setRows:      pha
              stx     .near VR_END
              clc
              adc     .near VR_END
              sta     .near VR_END
              sty     .near VR_PAL
              jsr     .kbank textInvalidate
              plx
1$:           cpx     .near VR_END
              bcs     2$
              lda     .near VR_PAL
              jsr     .kbank rowPalette
              inx
              bra     1$
2$:           lda     ##1
              sta     .near scbchanged
              rts

;;; rowPalette: the row X gets the palette C: its SCB and its part of the
;;; nibble tables. X stays.
rowPalette:   sep     #0x20
              sta     .near scb,x
              rep     #0x20
              xba                           ; C * 0x400 + (X & 1) * 0x100
              asl     a
              asl     a
              pha
              txa
              and     ##1
              xba
              clc
              adc     1,s
              sta     1,s
              txa
              asl     a
              tay
              pla
              sta     .near iigs_rowbase,y
              xba
              sep     #0x20
              sta     .near iigs_rowpageL,x
              clc
              adc     #2
              sta     .near iigs_rowpageR,x
              rep     #0x20
              rts

;;; enterLevelMode: I_EnterLevelMode: the nibble tables and rows of the view
;;; (palette 0) and the status bar (palettes 1-8, the row map of GSSTAT),
;;; no picture, the colors.
enterLevelMode:
              lda     .near viewpalnum
              jsl     long:W_GetLumpByNum
              jsr     .kbank pairsArg
              lda     ##0
              jsr     .kbank buildNibtab
              lda     .near statpalnum      ; each status bar palette
              jsl     long:W_GetLumpByNum
              sta     .near VL_STAT
              stx     .near (VL_STAT+2)
              lda     ##1
1$:           sta     .near VL_N
              dec     a                     ; its record: STAT_RECS +
              ldx     ##PALREC_SIZE         ;   (n - 1) * PALREC_SIZE
              jsl     long:IIGS_MulLo16
              clc
              adc     ##STAT_RECS
              adc     .near VL_STAT
              ldx     .near (VL_STAT+2)
              bcc     2$
              inx
2$:           jsr     .kbank pairsArg
              lda     .near VL_N
              jsr     .kbank buildNibtab
              lda     .near VL_N
              inc     a
              cmp     ##(STAT_PALS + 1)
              bcc     1$
              lda     .near ovlpalnum       ; the palettes of the text
              jsl     long:W_GetLumpByNum
              sta     .near VL_STAT
              stx     .near (VL_STAT+2)
              lda     ##OVL_PAL
4$:           sta     .near VL_N
              sec                           ; its record: (n - OVL_PAL) *
              sbc     ##OVL_PAL             ;   PALREC_SIZE
              ldx     ##PALREC_SIZE
              jsl     long:IIGS_MulLo16
              clc
              adc     .near VL_STAT
              ldx     .near (VL_STAT+2)
              bcc     5$
              inx
5$:           jsr     .kbank pairsArg
              lda     .near VL_N
              jsr     .kbank buildNibtab
              lda     .near VL_N
              inc     a
              cmp     ##LEVEL_PALS
              bcc     4$
              lda     .near statpalnum      ; (the row map below)
              jsl     long:W_GetLumpByNum
              sta     .near VL_STAT
              stx     .near (VL_STAT+2)
              stz     .near viewpal
              stz     .near strippal
              lda     ##0
              ldx     ##VIEW_ROWS
              ldy     ##0
              jsr     .kbank setRows
              lda     .near VL_STAT         ; the status bar rows: the row
              sta     dp:.tiny _Dp          ;   map
              lda     .near (VL_STAT+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##0
3$:           phy
              lda     [.tiny _Dp],y
              and     ##0x00ff
              inc     a
              pha
              tya
              clc
              adc     ##VIEW_ROWS
              tax
              pla
              jsr     .kbank rowPalette
              ply
              iny
              cpy     ##ST_HEIGHT
              bcc     3$
              lda     ##1
              sta     .near scbchanged
              lda     ##0xffff
              sta     .near picturenum
              brl     levelPalettes

;;; grayMap: GRAYMAP from the 16 colors of the view record VP_REC (tint 0):
;;; each color to one of the MENU_GRAYS grays of the menu palette by its
;;; lightness 3 R + 6 G + B (0-150), a byte to the grays of its two pixels.
grayMap:      jsr     .kbank recArg
              ldy     ##0
1$:           lda     [.tiny _Dp],y         ; $0RGB
              pha
              xba                           ; 3 R
              and     ##0x000f
              sta     .near VL_R
              asl     a
              clc
              adc     .near VL_R
              sta     .near VL_R
              lda     1,s                   ; + 6 G
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              and     ##0x000f
              sta     .near VL_G
              asl     a
              clc
              adc     .near VL_G
              asl     a
              clc
              adc     .near VL_R
              sta     .near VL_R
              pla                           ; + B
              and     ##0x000f
              clc
              adc     .near VL_R
              ldx     ##0                   ; the gray: lightness / 30, 4 at
2$:           cmp     ##30                  ;   most
              bcc     3$
              sbc     ##30
              inx
              cpx     ##(MENU_GRAYS - 1)
              bcc     2$
3$:           tya
              lsr     a
              tay
              txa
              sep     #0x20
              sta     .near VL_DARKER,y     ; (a temporary here)
              rep     #0x20
              tya
              asl     a
              tay
              iny
              iny
              cpy     ##32
              bcc     1$
              ldx     ##0                   ; each byte
4$:           txa
              and     ##0x000f
              tay
              lda     .near VL_DARKER,y
              and     ##0x00ff
              sta     .near VL_G
              txa
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              tay
              lda     .near VL_DARKER,y
              and     ##0x00ff
              asl     a
              asl     a
              asl     a
              asl     a
              ora     .near VL_G
              sep     #0x20
              sta     long:GRAYMAP,x
              rep     #0x20
              inx
              cpx     ##256
              bcc     4$
              rts

;;; levelFlats: GSFLATn supplies the map's flat colors (tools/gsview.py).
;;; FLATCM[cm * 32 + f] = fullcolormap[cm * 256 + color[f]].
;;; The sector flat numbers come from tools/wadtool.py; no map: no work.
levelFlats:   lda     .near (VL_NAME+6)
              and     ##0x00ff
              cmp     ##'0'
              bne     0$
              rts
0$:           lda     ##('F' | 'L' << 8)    ; "GSFLATn"
              sta     .near (VL_NAME+2)
              lda     ##('A' | 'T' << 8)
              sta     .near (VL_NAME+4)
              lda     ##.near VL_NAME
              sta     dp:.tiny _Dp
              lda     ##.word2 VL_NAME
              sta     dp:.tiny (_Dp+2)
              jsl     long:W_GetNumForName
              pha
              jsl     long:W_LumpLength
              sta     .near VL_N
              pla
              jsl     long:W_GetLumpByNum
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              stz     .near VL_K            ; each flat
1$:           ldy     .near VL_K
              lda     [.tiny _Dp],y         ; its color: Y = cm * 256 + color,
              and     ##0x00ff              ;   X = cm * 32 + flat
              tay
              ldx     .near VL_K
2$:           sep     #0x20
              lda     .near fullcolormap,y
              sta     long:FLATCM,x
              rep     #0x20
              tya
              clc
              adc     ##256
              tay
              txa
              clc
              adc     ##32
              tax
              cpx     ##(34 * 32)
              bcc     2$
              inc     .near VL_K
              lda     .near VL_K
              cmp     .near VL_N
              bcc     1$
              rts

;;; pairsArg: _Dp[0-3] = the pairs of the palette record X:C.
pairsArg:     clc
              adc     ##PALREC_PAIRS
              sta     dp:.tiny _Dp
              txa
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              rts

;;; ---------------------------------------------------------------------------
;;; void I_SetLevelPalette(int16_t map)    In: C.
;;; A level starts: the 3D view gets the palette made for this map, and the
;;; colormaps and the spectre fuzz table follow it.
;;; ---------------------------------------------------------------------------
              .public I_SetLevelPalette
I_SetLevelPalette:
              pha
              ldx     ##6                   ; "GSVIEW0", or "GSVIEWn" for map
1$:           lda     long:strGsview,x      ;   1-9
              sta     .near VL_NAME,x
              dex
              dex
              bpl     1$
              pla
              cmp     ##1
              bcc     2$
              cmp     ##10
              bcs     2$
              clc
              adc     ##'0'
              sep     #0x20
              sta     .near (VL_NAME+6)
              rep     #0x20
2$:           lda     ##.near VL_NAME
              sta     dp:.tiny _Dp
              lda     ##.word2 VL_NAME
              sta     dp:.tiny (_Dp+2)
              jsl     long:W_GetNumForName
              sta     .near viewpalnum
              jsl     long:W_GetLumpByNum   ; the record: 14 tints of 16 colors,
              sta     .near VP_REC          ;   the best pairs, then the bytes
              stx     .near (VP_REC+2)      ;   A and B (tools/gsview.py)
              lda     .near viewpalnum      ; the view tables of this record are
              inc     a                     ;   there (a new life on the same
              cmp     long:VL_TABS          ;   map): no new ones
              bne     30$
              brl     70$
30$:          sta     long:VL_TABS
              lda     .near VP_REC
              ldx     .near (VP_REC+2)
              clc
              adc     ##PALREC_A
              sta     dp:.tiny _Dp
              txa
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              sta     dp:.tiny (_Dp+6)
              lda     dp:.tiny _Dp
              clc
              adc     ##256
              sta     dp:.tiny (_Dp+4)
              bcc     31$
              inc     dp:.tiny (_Dp+6)
31$:          ldx     ##0                   ; the SHR colormaps: A on even rows,
3$:           lda     .near fullcolormap,x  ;   B on odd rows (a mix of 4
              and     ##0x00ff              ;   palette colors in each 2 x 2
              tay                           ;   block)
              sep     #0x20
              lda     [.tiny _Dp],y
              sta     long:iigs_shrcmapA,x
              lda     [.tiny (_Dp+4)],y
              sta     long:iigs_shrcmapB,x
              rep     #0x20
              inx
              cpx     ##(34 * 256)
              bcc     3$
              jsr     .kbank levelFlats
              jsr     .kbank grayMap
              jsr     .kbank recArg         ; the darker colors: for each
              stz     .near VL_N            ;   color the nearest to 3/4 of
4$:           lda     .near VL_N            ;   its red, green and blue
              asl     a
              tay
              lda     [.tiny _Dp],y
              pha
              xba
              jsr     .kbank threeQuarters
              sta     .near VL_R
              lda     1,s
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              jsr     .kbank threeQuarters
              sta     .near VL_G
              pla
              jsr     .kbank threeQuarters
              sta     .near VL_B
              stz     .near VL_BEST
              lda     ##0x7fff
              sta     .near VL_BESTDIST
              stz     .near VL_K
5$:           lda     .near VL_K            ; dist = dr * dr * 3 + dg * dg * 4
              asl     a                     ;   + db * db * 2
              tay
              lda     [.tiny _Dp],y
              pha
              xba
              and     ##0x000f
              sec
              sbc     .near VL_R
              jsr     .kbank square
              sta     .near VL_DIST
              asl     a
              clc
              adc     .near VL_DIST
              sta     .near VL_DIST
              lda     1,s
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              and     ##0x000f
              sec
              sbc     .near VL_G
              jsr     .kbank square
              asl     a
              asl     a
              clc
              adc     .near VL_DIST
              sta     .near VL_DIST
              pla
              and     ##0x000f
              sec
              sbc     .near VL_B
              jsr     .kbank square
              asl     a
              clc
              adc     .near VL_DIST
              cmp     .near VL_BESTDIST     ; (0-2025: no sign)
              bcs     6$
              sta     .near VL_BESTDIST
              lda     .near VL_K
              sta     .near VL_BEST
6$:           inc     .near VL_K
              lda     .near VL_K
              cmp     ##16
              bcc     5$
              ldx     .near VL_N
              lda     .near VL_BEST
              sep     #0x20
              sta     .near VL_DARKER,x
              rep     #0x20
              inc     .near VL_N
              lda     .near VL_N
              cmp     ##16
              bcs     7$
              brl     4$
7$:           ldx     ##0                   ; darken: both nibbles darker
8$:           txa
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              tay
              lda     .near VL_DARKER,y
              and     ##0x000f
              asl     a
              asl     a
              asl     a
              asl     a
              sta     .near VL_I
              txa
              and     ##0x000f
              tay
              lda     .near VL_DARKER,y
              and     ##0x000f
              ora     .near VL_I
              sep     #0x20
              sta     long:FUZZ_DARKEN,x
              rep     #0x20
              inx
              cpx     ##256
              bcc     8$
70$:          lda     .near viewpalnum      ; TINTPAL of this record and gamma
              inc     a                     ;   is there: no new tints
              cmp     long:VL_TINTS
              bne     71$
              lda     .near _g_gamma
              cmp     long:VL_TGAMMA
              beq     72$
71$:          jsr     .kbank buildTints
72$:          jsr     .kbank enterLevelMode
              rtl

;;; threeQuarters: C = (C & 15) * 3 / 4.
threeQuarters:
              and     ##0x000f
              sta     .near VL_I
              asl     a
              clc
              adc     .near VL_I
              lsr     a
              lsr     a
              rts

;;; square: C = C * C (C: -15 to 15).
square:       bpl     1$
              eor     ##0xffff
              inc     a
1$:           asl     a
              tax
              lda     long:squares,x
              rts

;;; ---------------------------------------------------------------------------
;;; Pictures and raw data.
;;; ---------------------------------------------------------------------------

;;; drawPicture: I_DrawPicture(C): an SHR picture: its pixels in the back
;;; buffer; if new, its row palettes, its palettes and nibble tables.
drawPicture:  sta     .near VP_NUM
              jsl     long:W_GetLumpByNum
              sta     .near VP_REC
              stx     .near (VP_REC+2)
              sta     dp:.tiny _Dp          ; IIGS_CopyHuge(SHRBUF, rec,
              stx     dp:.tiny (_Dp+2)      ;   32000)
              lda     ##32000
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              lda     ##(SHRBUF & 0xffff)
              ldx     ##(SHRBUF >> 16)
              jsl     long:IIGS_CopyHuge
              lda     ##0
              ldx     ##200
              jsr     .kbank markRows
              lda     .near picturenum
              cmp     .near VP_NUM
              bne     1$
              rts
1$:           jsr     .kbank textInvalidate
              jsr     .kbank recArg
              ldx     ##0                   ; the rows
2$:           txa
              clc
              adc     ##PICTURE_SCB
              tay
              lda     [.tiny _Dp],y
              and     ##0x00ff
              jsr     .kbank rowPalette
              inx
              cpx     ##200
              bcc     2$
              lda     ##1
              sta     .near scbchanged
              ldx     ##0                   ; the 16 palettes
3$:           phx
              txa
              clc
              adc     ##PICTURE_PALS
              tay
              lda     [.tiny _Dp],y
              jsr     .kbank gammaColor
              plx
              sta     .near palette,x
              inx
              inx
              cpx     ##512
              bcc     3$
              lda     ##256
              sta     .near palettecount
              stz     .near VL_I            ; the nibble tables
4$:           lda     .near VL_I
              xba
              clc
              adc     ##PICTURE_PAIRS
              clc
              adc     .near VP_REC
              sta     dp:.tiny _Dp
              lda     .near (VP_REC+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              lda     .near VL_I
              jsr     .kbank buildNibtab
              inc     .near VL_I
              lda     .near VL_I
              cmp     ##16
              bcc     4$
              lda     .near VP_NUM
              sta     .near picturenum
              rts

;;; recArg: _Dp[0-3] = VP_REC.
recArg:       lda     .near VP_REC
              sta     dp:.tiny _Dp
              lda     .near (VP_REC+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; ---------------------------------------------------------------------------
;;; void V_DrawRaw(int16_t num, uint16_t offset)   In: C, _Dp[0-1].
;;; An SHR picture, or raw 8-bit data from a byte offset of a 320 wide
;;; screen. The status bar background is kept in SHR format.
;;; void I_SaveStatusBackground(void)
;;; ---------------------------------------------------------------------------
              .public V_DrawRaw, I_SaveStatusBackground
V_DrawRaw:    sta     .near VP_NUM
              lda     dp:.tiny _Dp
              sta     .near VD_OFFSET
              lda     .near VP_NUM
              jsl     long:W_LumpLength
              sta     .near VD_LEN
              cmp     ##PICTURE_SIZE        ; a picture
              bne     1$
              lda     .near VP_NUM
              jsr     .kbank drawPicture
              rtl
1$:           stz     .near VD_SB           ; the status bar background
              lda     .near VD_OFFSET
              cmp     ##(VIEW_ROWS * 320)
              bne     2$
              lda     .near VD_LEN
              cmp     ##(ST_HEIGHT * 320)
              bne     2$
              inc     .near VD_SB
              lda     .near VP_NUM          ; in the cache
              cmp     .near stcachenum
              bne     2$
              lda     ##(STCACHE & 0xffff)
              sta     dp:.tiny _Dp
              lda     ##(STCACHE >> 16)
              sta     dp:.tiny (_Dp+2)
              lda     ##ST_SHR_LENGTH
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              lda     ##((SHRBUF + ST_SHR_OFFSET) & 0xffff)
              ldx     ##((SHRBUF + ST_SHR_OFFSET) >> 16)
              jsl     long:IIGS_CopyHuge
              lda     ##VIEW_ROWS
              ldx     ##200
              jsr     .kbank markRows
              rtl
2$:           lda     .near VP_NUM          ; the raw data
              jsl     long:W_GetLumpByNum
              sta     .near VP_REC
              stx     .near (VP_REC+2)
              jsr     .kbank drawRawData
              lda     .near VD_SB
              bne     3$
              rtl
3$:           lda     .near VP_NUM          ; the status bar into the cache
              sta     .near stcachenum
I_SaveStatusBackground:
              lda     ##((SHRBUF + ST_SHR_OFFSET) & 0xffff)
              sta     dp:.tiny _Dp
              lda     ##((SHRBUF + ST_SHR_OFFSET) >> 16)
              sta     dp:.tiny (_Dp+2)
              lda     ##ST_SHR_LENGTH
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              lda     ##(STCACHE & 0xffff)
              ldx     ##(STCACHE >> 16)
              jmp     long:IIGS_CopyHuge

;;; drawRawData: I_DrawRawData(VP_REC, VD_LEN bytes, VD_OFFSET): the pixel
;;; pairs from x = offset % 320, y = offset / 320.
drawRawData:  lda     .near VD_OFFSET
              ldx     ##320
              jsl     long:_UDivMod16       ; C = x, X = y
              sta     .near VD_X
              stx     .near VP_Y
              stx     .near VP_Y0
              stz     .near VD_DONE
1$:           lda     .near VD_DONE         ; each row
              cmp     .near VD_LEN
              bcs     9$
              lda     .near VP_Y            ; the byte of x in the row
              jsr     .kbank rowOffset
              sta     .near VP_OFS
              lda     .near VD_X
              lsr     a
              clc
              adc     .near VP_OFS
              tax
              jsr     .kbank recArg
              ldy     .near VD_DONE
2$:           lda     .near VD_X            ; x < 320 and done < length
              cmp     ##320
              bcs     3$
              cpy     .near VD_LEN
              bcs     3$
              jsr     .kbank pairByte
              sep     #0x20
              sta     long:SHRBUF,x
              rep     #0x20
              inx
              iny
              iny
              lda     .near VD_X
              clc
              adc     ##2
              sta     .near VD_X
              bra     2$
3$:           sty     .near VD_DONE
              stz     .near VD_X
              inc     .near VP_Y
              bra     1$
9$:           lda     .near VP_Y            ; its rows
              jsr     .kbank min200
              tax
              lda     .near VP_Y0
              jmp     .kbank markRows

;;; pairByte: I_PairByte: C (low byte) = the byte of the pixels [_Dp],y and
;;; [_Dp],y+1 in the row VP_Y: t[left] | t[0x200 + right], t the nibble
;;; table of the row. X and Y stay.
pairByte:     phx
              lda     .near VP_Y
              asl     a
              tax
              lda     .near iigs_rowbase,x
              sta     .near VD_RB
              lda     [.tiny _Dp],y         ; left, right
              pha
              and     ##0x00ff
              clc
              adc     .near VD_RB
              tax
              lda     long:NIBTAB,x
              and     ##0x00ff
              sta     .near VG_C
              pla
              xba
              and     ##0x00ff
              clc
              adc     .near VD_RB
              tax
              lda     long:(NIBTAB+0x200),x
              ora     .near VG_C
              plx
              rts

;;; rowOffset: C = C * 160.
rowOffset:    asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              pha
              asl     a
              asl     a
              clc
              adc     1,s
              sta     1,s
              pla
              rts

;;; ---------------------------------------------------------------------------
;;; void V_DrawBackground(int16_t num)     In: C.
;;; A 64x64 flat as tiles over the whole screen: each screen row is 5 times
;;; the 32 bytes of a flat row.
;;; ---------------------------------------------------------------------------
              .public V_DrawBackground
V_DrawBackground:
              jsl     long:W_GetLumpByNum
              sta     .near VP_REC
              stx     .near (VP_REC+2)
              stz     .near VP_Y
1$:           jsr     .kbank recArg         ; the flat row y & 63
              lda     .near VP_Y
              and     ##63
              xba
              lsr     a
              lsr     a
              clc
              adc     dp:.tiny _Dp
              sta     dp:.tiny _Dp
              bcc     2$
              inc     dp:.tiny (_Dp+2)
2$:           ldy     ##0                   ; its 32 bytes
              ldx     ##0
3$:           jsr     .kbank pairByte
              sep     #0x20
              sta     .near VD_ROW,x
              rep     #0x20
              inx
              iny
              iny
              cpy     ##64
              bcc     3$
              lda     .near VP_Y            ; 5 times in the screen row
              jsr     .kbank rowOffset
              sta     .near VP_OFS
              tax
              ldy     ##0
4$:           lda     .near VD_ROW,y
              sta     long:SHRBUF,x
              inx
              inx
              iny
              iny
              cpy     ##32
              bcc     5$
              ldy     ##0
5$:           txa
              sec
              sbc     .near VP_OFS
              cmp     ##160
              bcc     4$
              inc     .near VP_Y
              lda     .near VP_Y
              cmp     ##200
              bcc     1$
              lda     ##0
              ldx     ##200
              jsr     .kbank markRows
              rtl

;;; ---------------------------------------------------------------------------
;;; void I_SaveView(void), I_RestoreView(void): the view rows to and from
;;; VIEWSAVE (under the menu).
;;; boolean I_RestoreBackRect(int16_t x, int16_t y, int16_t w, int16_t h)
;;;   In: C = x, _Dp[0-1] = y, _Dp[4-5] = w, h at 4,s. The rectangle from
;;;   the picture or saved menu background, including the hidden bar.
;;; void I_RestoreStatusRect(int16_t x, int16_t y, int16_t w, int16_t h)
;;;   The same, from the status bar background.
;;; ---------------------------------------------------------------------------
              .public I_SaveView, I_RestoreView, I_RestoreBackRect, I_RestoreStatusRect
I_SaveView:   jmp     long:I_MenuPalette
;;; Far entries for menu code in bank 4. Keep the video entries in place.
uiRowPalette: jsr     .kbank rowPalette
              rtl
uiInvalidate: jsr     .kbank textInvalidate
              rtl
uiGrayMap:    jsr     .kbank grayMap
              rtl
uiPairs:      jsr     .kbank pairsArg
              rtl
uiNibbles:    jsr     .kbank buildNibtab
              rtl
uiGammaColor: jsr     .kbank gammaColor
              rtl
uiRectOffset: jsr     .kbank rectOffset
              rtl
uiMarkVP:     jsr     .kbank markVP
              rtl
              .space  (0x47 - (. - I_SaveView))
                                      ; Keep the following video code in place.
I_RestoreView: jmp    long:uiDimAll
              .space  (0x2b - (. - I_RestoreView))

I_RestoreBackRect:
              pha                           ; x
              lda     dp:.tiny _Dp          ; y0 = y < 0 ? 0 : y
              bpl     1$
              lda     ##0
1$:           sta     .near VP_Y0
              lda     dp:.tiny _Dp          ; y1 = y + h > 200 ? 200 : y + h
              clc
              adc     6,s
              jsr     .kbank min200
              sta     .near VP_Y1
              lda     1,s                   ; b0 = x < 0 ? 0 : x >> 1
              bpl     2$
              lda     ##0
2$:           lsr     a
              sta     .near VP_B0
              pla                           ; b1 = x + w - 1 > 319 ? 159 :
              clc                           ;   (x + w - 1) >> 1
              adc     dp:.tiny (_Dp+4)
              dec     a
              pha
              sec
              sbc     ##320
              bvc     3$
              eor     ##0x8000
3$:           bmi     4$
              pla
              lda     ##159
              bra     5$
4$:           pla
              cmp     ##0x8000
              ror     a
5$:           sta     .near VP_B1
              jsr     .kbank rectEmpty
              bcs     9$
              lda     long:UI_PALON     ; All menus use the saved screen.
              cmp     ##0x6d70
              beq     7$
              lda     .near picturenum
              bmi     7$
              jsl     long:W_GetLumpByNum
              sta     .near VP_REC
              stx     .near (VP_REC+2)
              ldx     .near VP_Y0
6$:           cpx     .near VP_Y1
              bcs     9$
              phx
              jsr     .kbank rectOffset
              pha
              clc
              adc     .near VP_REC
              sta     dp:.tiny _Dp
              lda     .near (VP_REC+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              pla
              jsr     .kbank copyToBuffer
              plx
              inx
              bra     6$
7$:           jsl     long:uiDimRect
              bra     9$
              .space  37
                                      ; Keep later video code in place.
9$:           jsr     .kbank markVP
              lda     ##1
              rtl

I_RestoreStatusRect:
              pha                           ; x
              lda     dp:.tiny _Dp          ; y0 = y - 168, y1 = y0 + h
              sec
              sbc     ##VIEW_ROWS
              pha
              clc
              adc     8,s
              sta     .near VP_Y1
              pla                           ; y0 < 0: 0
              bpl     1$
              lda     ##0
1$:           sta     .near VP_Y0
              lda     .near VP_Y1           ; y1 > 32: 32
              sec
              sbc     ##(ST_HEIGHT + 1)
              bvc     2$
              eor     ##0x8000
2$:           bmi     3$
              lda     ##ST_HEIGHT
              sta     .near VP_Y1
3$:           lda     1,s                   ; b0 = x >> 1, b0 < 0: 0
              cmp     ##0x8000
              ror     a
              bpl     4$
              lda     ##0
4$:           sta     .near VP_B0
              pla                           ; b1 = (x + w - 1) >> 1, b1 >
              clc                           ;   159: 159
              adc     dp:.tiny (_Dp+4)
              dec     a
              cmp     ##0x8000
              ror     a
              pha
              sec
              sbc     ##160
              bvc     5$
              eor     ##0x8000
5$:           bmi     6$
              pla
              lda     ##159
              bra     7$
6$:           pla
7$:           sta     .near VP_B1
              jsr     .kbank rectEmpty
              bcs     9$
              ldx     .near VP_Y0
8$:           cpx     .near VP_Y1
              bcs     9$
              phx
              jsr     .kbank rectOffset     ; (a row of the status bar)
              pha
              clc
              adc     ##(STCACHE & 0xffff)
              sta     dp:.tiny _Dp
              lda     ##(STCACHE >> 16)
              sta     dp:.tiny (_Dp+2)
              pla
              clc
              adc     ##ST_SHR_OFFSET
              jsr     .kbank copyToBuffer
              plx
              inx
              bra     8$
9$:           lda     .near VP_Y0           ; (the rows of the status bar)
              clc
              adc     ##VIEW_ROWS
              sta     .near VP_Y0
              lda     .near VP_Y1
              clc
              adc     ##VIEW_ROWS
              sta     .near VP_Y1
              jsr     .kbank markVP
              rtl

;;; markVP: mark rows VP_Y0 .. VP_Y1 - 1, bytes VP_B0 .. VP_B1, if not empty.
markVP:       jsr     .kbank rectEmpty
              bcc     1$
              rts
1$:           lda     .near VP_B1
              xba
              ora     .near VP_B0
              tay
              ldx     .near VP_Y1
              lda     .near VP_Y0
              jmp     .kbank markRect

;;; min200: C = 200 if C > 200 (signed).
min200:       pha
              sec
              sbc     ##201
              bvc     1$
              eor     ##0x8000
1$:           bmi     2$
              pla
              lda     ##200
              rts
2$:           pla
              rts

;;; rectEmpty: carry set if y0 >= y1 or b0 > b1 (signed).
rectEmpty:    lda     .near VP_Y0
              sec
              sbc     .near VP_Y1
              bvc     1$
              eor     ##0x8000
1$:           bpl     3$
              lda     .near VP_B1
              sec
              sbc     .near VP_B0
              bvc     2$
              eor     ##0x8000
2$:           bmi     3$
              clc
              rts
3$:           sec
              rts

;;; rectOffset: C = X * 160 + b0 (X: the row). X stays.
rectOffset:   txa
              jsr     .kbank rowOffset
              clc
              adc     .near VP_B0
              rts

;;; copyToBuffer: b1 - b0 + 1 bytes from _Dp[0-3] to SHRBUF + C.
copyToBuffer: pha
              lda     .near VP_B1
              sec
              sbc     .near VP_B0
              inc     a
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              pla
              clc
              adc     ##(SHRBUF & 0xffff)
              ldx     ##(SHRBUF >> 16)
              jsl     long:IIGS_CopyHuge
              rts

;;; ---------------------------------------------------------------------------
;;; void V_DrawPatchNotScaled(int16_t x, int16_t y, const patch_t __far* patch)
;;; void V_DrawPatchScaled (the same: the screen is 320 wide)
;;;   In: C = x, _Dp[0-1] = y, _Dp[4-7] = patch.
;;; ---------------------------------------------------------------------------
              .public V_DrawPatchNotScaled, V_DrawPatchScaled
V_DrawPatchNotScaled:
V_DrawPatchScaled:
              ldy     ##OFS_PATCH_LEFTOFFSET
              sec
              sbc     [.tiny (_Dp+4)],y
              pha
              lda     dp:.tiny _Dp
              ldy     ##OFS_PATCH_TOPOFFSET
              sec
              sbc     [.tiny (_Dp+4)],y
              sta     dp:.tiny _Dp
              pla
              jmp     long:IIGS_DrawPatch

;;; ---------------------------------------------------------------------------
;;; HUD text caches the string and generated drawing code (patch65.s).
;;; Nibble-table/row changes invalidate it; overdraw clears iigs_textShown.
;;; I_DrawCachedText: C = slot, _Dp[0-3] = text, _Dp[4-5] = length, y at 4,s.
;;; Returns C = 1 if reused; 0 starts capture for the caller to draw.
;;; I_EndTextCapture takes the same arguments after that drawing.
;;; ---------------------------------------------------------------------------
              .public I_DrawCachedText, I_EndTextCapture
I_DrawCachedText:
              sta     .near VT_SLOT
              asl     a
              tax
              lda     .near textValid,x     ; the same text at the same y
              beq     2$
              lda     .near textLen,x
              cmp     dp:.tiny (_Dp+4)
              bne     2$
              lda     4,s
              cmp     .near textY,x
              bne     2$
              ldx     ##0                   ; X: the slot text
              lda     .near VT_SLOT
              beq     11$
              ldx     ##TEXTMAX
11$:          ldy     ##0
1$:           cpy     dp:.tiny (_Dp+4)
              bcs     3$
              sep     #0x20
              lda     [.tiny _Dp],y
              cmp     .near textText,x
              rep     #0x20
              bne     2$
              inx
              iny
              bra     1$
2$:           jsl     long:IIGS_BeginCapture ; no: draw and capture
              lda     ##0
              rtl
3$:           lda     .near VT_SLOT         ; yes: its code, if it is not
              asl     a                     ;   on the screen
              tax
              lda     .near iigs_textShown,x
              bne     4$
              inc     a
              sta     .near iigs_textShown,x
              lda     .near VT_SLOT
              jsl     long:IIGS_RunText
              lda     4,s                   ; its rows: y .. y + TEXT_H - 1
              bpl     31$
              lda     ##0
31$:          pha
              clc
              adc     ##TEXT_H
              jsr     .kbank min200
              tax
              pla
              jsr     .kbank markRows
4$:           lda     ##1
              rtl
I_EndTextCapture:
              sta     .near VT_SLOT
              lda     dp:.tiny _Dp
              sta     .near VT_P
              lda     dp:.tiny (_Dp+2)
              sta     .near (VT_P+2)
              lda     dp:.tiny (_Dp+4)
              sta     .near VT_LEN
              lda     4,s
              sta     .near VT_Y
              lda     .near VT_SLOT
              jsl     long:IIGS_TextCode
              lda     .near VT_SLOT
              asl     a
              tax
              lda     ##1                   ; (the patches drew it)
              sta     .near iigs_textShown,x
              lda     .near VT_LEN          ; valid if len <= TEXTMAX
              cmp     ##(TEXTMAX + 1)
              bcc     1$
              stz     .near textValid,x
              rtl
1$:           lda     ##1
              sta     .near textValid,x
              lda     .near VT_LEN
              sta     .near textLen,x
              lda     .near VT_Y
              sta     .near textY,x
              lda     .near VT_P            ; the text
              sta     dp:.tiny _Dp
              lda     .near (VT_P+2)
              sta     dp:.tiny (_Dp+2)
              ldx     ##0
              lda     .near VT_SLOT
              beq     2$
              ldx     ##TEXTMAX
2$:           ldy     ##0
              sep     #0x20
3$:           cpy     .near VT_LEN
              bcs     4$
              lda     [.tiny _Dp],y
              sta     .near textText,x
              inx
              iny
              bra     3$
4$:           rep     #0x20
              rtl

;;; textInvalidate: I_TextCacheInvalidate: no text slot is valid.
textInvalidate:
              stz     .near textValid
              stz     .near (textValid+2)
              stz     .near iigs_textShown
              stz     .near (iigs_textShown+2)
              rts

;;; ---------------------------------------------------------------------------
;;; I_InitSegVertices: C = seg count, _Dp[0-3] = segs.
;;; Segs store coordinates, not map vertex numbers. Hash equal endpoints
;;; to one number for R_AddLine's angle cache (r_bsp65.s).
;;; ---------------------------------------------------------------------------
              .public I_InitSegVertices
I_InitSegVertices:
              sta     .near VS_N
              cmp     ##(SEGVTX_MAX + 1)
              bcc     1$
              pha
              lda     ##.word0 errSegs
              sta     dp:.tiny _Dp
              lda     ##.word2 errSegs
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
1$:           lda     .near _g_gamemap      ; the vertices of this map are
              cmp     long:VS_MAP           ;   there (a new life on the same
              beq     5$                    ;   map): the stamps only
              sta     long:VS_MAP
              ldx     ##4                   ; the hash empty (num 0xffff)
2$:           lda     ##0xffff
              sta     long:VTXHASH,x
              txa
              clc
              adc     ##6
              tax
              cpx     ##(VTXHASH_SIZE * 6)
              bcc     2$
              stz     .near VS_NUMVTX
              stz     .near VS_I
3$:           lda     .near VS_I            ; each seg: its ends
              cmp     .near VS_N
              bcs     5$
              ldy     ##OFS_SEG_V1
              jsr     .kbank segEnd
              sta     long:SEGVTX,x
              ldy     ##OFS_SEG_V2
              jsr     .kbank segEnd
              sta     long:(SEGVTX+2),x
              lda     dp:.tiny _Dp          ; the next seg
              clc
              adc     ##SIZEOF_SEG
              sta     dp:.tiny _Dp
              bcc     4$
              inc     dp:.tiny (_Dp+2)
4$:           inc     .near VS_I
              bra     3$
5$:           lda     .near VS_NUMVTX       ; the stamps of the vertices 0
              asl     a
              tax
              lda     ##0
6$:           dex
              dex
              bmi     7$
              sta     long:SEGSTAMP,x
              bra     6$
7$:           rtl

;;; segEnd: C = the vertex number of the point at offset Y of the seg at
;;; [_Dp]; X = 4 * VS_I.
segEnd:       lda     [.tiny _Dp],y
              sta     .near VS_X
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near VS_Y
              jsr     .kbank vertexNumber
              pha
              lda     .near VS_I
              asl     a
              asl     a
              tax
              pla
              rts

;;; vertexNumber: C = the number of the point VS_X, VS_Y: the hash entry
;;; h = (x * 31 + y) & 8191 and the next ones; a new point gets the next
;;; number.
vertexNumber: lda     .near VS_X
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     .near VS_X
              clc
              adc     .near VS_Y
              and     ##(VTXHASH_SIZE - 1)
1$:           sta     .near VS_H            ; the entry h: 6 h
              asl     a
              clc
              adc     .near VS_H
              asl     a
              tax
              lda     long:(VTXHASH+4),x    ; empty: a new point
              cmp     ##0xffff
              beq     3$
              lda     long:VTXHASH,x        ; the same point
              cmp     .near VS_X
              bne     2$
              lda     long:(VTXHASH+2),x
              cmp     .near VS_Y
              bne     2$
              lda     long:(VTXHASH+4),x
              rts
2$:           lda     .near VS_H            ; the next entry
              inc     a
              and     ##(VTXHASH_SIZE - 1)
              bra     1$
3$:           lda     .near VS_NUMVTX
              cmp     ##VTX_MAX
              bne     4$
              pea     #VTX_MAX
              lda     ##.word0 errVertices
              sta     dp:.tiny _Dp
              lda     ##.word2 errVertices
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
4$:           lda     .near VS_X
              sta     long:VTXHASH,x
              lda     .near VS_Y
              sta     long:(VTXHASH+2),x
              lda     .near VS_NUMVTX
              sta     long:(VTXHASH+4),x
              inc     .near VS_NUMVTX
              rts

;;; Byte count of one tint change. Tint 0 fills every level palette, because
;;; the screen may still be a picture. Any other tint writes the view's 16
;;; colors only: the status bar, the menu and the message stay readable.
tintSpan:     lda     .near curtint
              bne     1$
              lda     ##TINT_ROW
              rts
1$:           lda     ##32
              rts

;;; The paused screen stays in its original colors. Menus redraw a dark
;;; gray copy; closing restores all pixels, row mappings and palettes.
              .section uicode, text
              .public I_MenuPalette, I_MenuPaletteBack, uiOpen, uiDisplay
              .extern sqmInit
              .extern displayCall, display, menuDisplayNear, onlyTics
              .extern uiStaticCheck, uiStaticDrawn, M_Drawer, singletics

;;; Select the cold menu display while open. The normal call costs the
;;; same as before; both near targets stay in the display's code bank.
uiOpen:       lda     long:(displayCall+1)
              cmp     ##.word0 menuDisplayNear
              beq     1$
              lda     .near singletics
              sta     long:UI_SINGLETIC
              stz     .near singletics
              lda     ##.word0 menuDisplayNear
              sta     long:(displayCall+1)
1$:           rtl
uiDisplay:    lda     long:UI_PALON
              cmp     ##0x6d70
              bne     1$
              jsl     long:uiStaticCheck
              bcs     2$
1$:           jsl     long:M_Drawer
              jsl     long:uiStaticDrawn
              jsl     long:I_FinishUpdate
2$:           jmp     long:onlyTics

I_MenuPalette:
              lda     long:UI_PALON
              cmp     ##0x6d70
              bne     0$
              brl     uiDimAll
0$:           lda     .near picturenum
              sta     long:UI_PICTURE
              lda     .near viewpal
              sta     long:UI_VIEWPAL
              lda     .near strippal
              sta     long:UI_STRIPPAL
              lda     .near _g_gamma
              sta     long:UI_GAMMA
              ldx     ##510
1$:           lda     long:SHR_PALETTE,x
              sta     long:UI_PALETTES,x
              dex
              dex
              bpl     1$
              ldx     ##0
2$:           lda     long:SHR_SCB,x
              sep     #0x20
              sta     long:UI_ROWS,x
              rep     #0x20
              lda     ##MENU_PAL
              jsl     long:uiRowPalette
              inx
              cpx     ##200
              bcc     2$
              ldx     ##VIEW_SHR_LENGTH-2
3$:           lda     long:SHR_SCREEN,x
              sta     long:VIEWSAVE,x
              dex
              dex
              bpl     3$
              ldx     ##ST_SHR_LENGTH-2
4$:           lda     long:(SHR_SCREEN+ST_SHR_OFFSET),x
              sta     long:UI_VIEWSAVE2,x
              dex
              dex
              bpl     4$
              jsr     .kbank uiGrayTables
              lda     .near ovlpalnum
              jsl     long:W_GetLumpByNum
              sta     .near VP_REC
              stx     .near (VP_REC+2)
              jsl     long:uiPairs
              lda     ##MENU_PAL
              jsl     long:uiNibbles
              lda     ##MENU_PAL
              jsr     .kbank uiFontNibbles
              lda     .near VP_REC
              sta     dp:.tiny _Dp
              lda     .near (VP_REC+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##30
5$:           lda     [.tiny _Dp],y
              sta     .near (palette+MENU_PAL*32),y
              dey
              dey
              bpl     5$
              lda     ##0x6d70
              sta     long:UI_PALON
              stz     .near levelcopy
              lda     ##NO_PALETTE_CHANGE
              sta     .near newpal
              lda     ##256
              sta     .near palettecount
              lda     ##1
              sta     .near scbchanged
uiDimAll:     stz     .near VP_Y0
              stz     .near VP_B0
              lda     ##200
              sta     .near VP_Y1
              lda     ##159
              sta     .near VP_B1
              jsl     long:uiDimRect
              jmp     long:uiInvalidate

;;; Restore before clearMenus releases the pause. A changed gamma takes
;;; effect on the next game draw, after the original screen is back.
I_MenuPaletteBack:
              lda     long:UI_SINGLETIC
              sta     .near singletics
              lda     ##.word0 display
              sta     long:(displayCall+1)
              lda     long:UI_PALON
              cmp     ##0x6d70
              beq     0$
              rtl
0$:           lda     ##0
              sta     long:UI_PALON
              ldx     ##VIEW_SHR_LENGTH-2
1$:           lda     long:VIEWSAVE,x
              sta     long:SHRBUF,x
              dex
              dex
              bpl     1$
              ldx     ##ST_SHR_LENGTH-2
2$:           lda     long:UI_VIEWSAVE2,x
              sta     long:(SHRBUF+ST_SHR_OFFSET),x
              dex
              dex
              bpl     2$
              ldx     ##0
3$:           lda     long:UI_ROWS,x
              and     ##15
              jsl     long:uiRowPalette
              lda     long:UI_ROWS,x
              sep     #0x20
              sta     .near scb,x
              rep     #0x20
              inx
              cpx     ##200
              bcc     3$
              ldx     ##510
4$:           lda     long:UI_PALETTES,x
              sta     .near palette,x
              dex
              dex
              bpl     4$
              lda     long:UI_VIEWPAL
              sta     .near viewpal
              lda     long:UI_STRIPPAL
              sta     .near strippal
              jsr     .kbank uiOriginalNibs
              stz     .near levelcopy
              lda     ##NO_PALETTE_CHANGE
              sta     .near newpal
              lda     ##256
              sta     .near palettecount
              lda     ##1
              sta     .near scbchanged
              jsl     long:uiInvalidate
              lda     ##0
              ldx     ##200
              ldy     ##0x9f00
              jsl     long:I_MarkRect
              jsl     long:I_FinishUpdate
              php                           ; The snapshot was over SQMID
              jsl     long:sqmInit          ;   (MM_VIEWSAVE, src/iigs/
              plp                           ;   p_trace65.s): rebuild it.
              lda     .near _g_gamma
              cmp     long:UI_GAMMA
              beq     9$
              jmp     long:I_ReloadPalette
9$:           rtl

;;; Only palette 9's nibble table is borrowed. Pictures have their own
;;; pair table; level menus use the first GSOVL record.
uiOriginalNibs:
              lda     long:UI_PICTURE
              bpl     1$
              lda     .near ovlpalnum
              jsl     long:W_GetLumpByNum
              jsl     long:uiPairs
              bra     2$
1$:           jsl     long:W_GetLumpByNum
              clc
              adc     ##(PICTURE_PAIRS+MENU_PAL*256)
              sta     dp:.tiny _Dp
              txa
              adc     ##0
              sta     dp:.tiny (_Dp+2)
2$:           lda     ##MENU_PAL
              jsl     long:uiNibbles
              rts

;;; One gray index for each original palette color, using the colors
;;; actually on screen, including gamma and damage or radiation tints.
uiGrayTables: lda     ##0
              sta     long:UI_PIDX
1$:           lda     long:UI_PIDX
              asl     a
              clc
              adc     ##.word0 UI_PALETTES
              sta     .near VP_REC
              lda     ##.word2 UI_PALETTES
              sta     .near (VP_REC+2)
              jsl     long:uiGrayMap
              lda     long:UI_PIDX
              tax
              ldy     ##0
2$:           lda     .near VL_DARKER,y
              sep     #0x20
              sta     long:UI_GRAY,x
              rep     #0x20
              inx
              iny
              cpy     ##16
              bcc     2$
              txa
              sta     long:UI_PIDX
              cmp     ##256
              bcc     1$
              rts

;;; Convert VP_Y0..VP_Y1, VP_B0..VP_B1 from the untouched snapshot.
;;; The view and status rows are separate blocks so the 4 MB map fits.
;;; The loop uses UI_GRAY (256 bytes), DP pointers and saved pixels;
;;; it runs only while paused, outside the renderer's hot cache slots.
              .public uiDimRect
uiDimRect:    lda     .near VP_Y0
              pha
              lda     ##.word0 SHRBUF
              sta     dp:.tiny (_Dp+8)
              lda     ##.word2 SHRBUF
              sta     dp:.tiny (_Dp+10)
1$:           ldx     .near VP_Y0
              cpx     .near VP_Y1
              bcc     2$
              pla
              sta     .near VP_Y0
              jmp     long:uiMarkVP
2$:           lda     long:UI_ROWS,x
              and     ##15
              asl     a
              asl     a
              asl     a
              asl     a
              sta     long:UI_CMAP
              jsl     long:uiRectOffset
              tay
              sec
              sbc     .near VP_B0
              clc
              adc     .near VP_B1
              inc     a
              sta     .near VP_OFS
              lda     ##.word0 VIEWSAVE
              ldx     ##.word2 VIEWSAVE
              cpy     ##ST_SHR_OFFSET
              bcc     3$
              lda     ##.word0 (UI_VIEWSAVE2-ST_SHR_OFFSET)
              ldx     ##.word2 (UI_VIEWSAVE2-ST_SHR_OFFSET)
3$:           sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     ##0                  ; Keep B clear for 16-bit TAX.
              sep     #0x20
4$:           lda     [.tiny _Dp],y
              pha
              and     #15
              ora     long:UI_CMAP
              tax
              lda     long:UI_GRAY,x
              sta     long:UI_BYTE
              pla
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              ora     long:UI_CMAP
              tax
              lda     long:UI_GRAY,x
              asl     a
              asl     a
              asl     a
              asl     a
              ora     long:UI_BYTE
              sta     [.tiny (_Dp+8)],y
              iny
              cpy     .near VP_OFS
              bcc     4$
              rep     #0x20
              inc     .near VP_Y0
              brl     1$

;;; Menu glyphs keep their red shades, with one palette color per shade.
;;; The normal pair tables return when the menu closes.
uiFontNibbles:
              xba
              asl     a
              asl     a
              sta     .near VL_STAT
              lda     .near VP_REC
              sta     dp:.tiny _Dp
              lda     .near (VP_REC+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##176
              sta     .near VL_N
1$:           ldx     .near VL_N
              lda     long:(uiFontReds-176),x
              and     ##0x00ff
              sta     .near VL_R
              lda     ##0x7fff
              sta     .near VL_BESTDIST
              ldy     ##0
2$:           lda     [.tiny _Dp],y
              pha
              and     ##15
              sta     .near VL_B
              lda     1,s
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              and     ##15
              clc
              adc     .near VL_B
              sta     .near VL_B
              pla
              xba
              and     ##15
              sec
              sbc     .near VL_R
              bpl     3$
              eor     ##0xffff
              inc     a
3$:           clc
              adc     .near VL_B
              cmp     .near VL_BESTDIST
              bcs     4$
              sta     .near VL_BESTDIST
              tya
              lsr     a
              sta     .near VL_BEST
4$:           iny
              iny
              cpy     ##32
              bcc     2$
              lda     .near VL_BEST
              sep     #0x20
              sta     long:(UI_FONTBUF-176),x
              rep     #0x20
              lda     .near VL_STAT
              clc
              adc     .near VL_N
              tax
              lda     .near VL_BEST
              sep     #0x20
              sta     long:(NIBTAB+0x200),x
              sta     long:(NIBTAB+0x300),x
              asl     a
              asl     a
              asl     a
              asl     a
              sta     long:NIBTAB,x
              sta     long:(NIBTAB+0x100),x
              rep     #0x20
              inc     .near VL_N
              lda     .near VL_N
              cmp     ##192
              bcs     5$
              brl     1$
5$:           rts
uiFontReds:   .byte   15,14,13,13,12,11,11,10,9,8,7,7,6,5,5,4

