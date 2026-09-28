;;; Sprite drawing in 65816 assembly.
;;;
;;; R_DrawSprite, R_DrawVisSprite (shadow sprites) and R_DrawMaskedColumn of
;;; r_draw.c. The C code with 32-bit pointers spends most of its
;;; time on pointer loads; here the drawsegs and clip arrays in the near
;;; bank use abs,x addressing, and the post multiplies use the quarter
;;; square tables of m_fixed65.s.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "dscols.inc"
#include "lists.inc"
#include "wpage.inc"
#include "viewwin.inc"

              .extern _Dp, iigs_mulT, QP, QM
MULT0         .equ    iigs_mulT + 510 ; T[0] of src/iigs/mul.inc
#include "mul.inc"
              .extern floorclip, ceilingclip, mfloorclip, mceilingclip
              .extern spryscale, sprtopscreen, ds_p, _s_drawsegs
              .extern R_DrawColumnSprite, VS_CLIP, screenheightarray, negonearray
              .extern R_PointOnSegSide, R_RenderMaskedSegRange
              .extern W_GetLumpByNum, FixedMul, R_DrawVisSprite
              .extern R_WallColumnFast, fullcolormap, iigs_shrcmapA, iigs_shrcmapB
              .extern DC_SRC, DC_CMA, DC_CMB, DC_ROW, DC_COUNT, DC_COLX
              .extern DC_TMID7, DC_FSTEP, DC_ENTRY, DC_EXITP, DC_SAVEB
              .extern fuzzBlock, fuzzEntry, fuzzMod50, fuzzQ160

BUF_BANK      .equ    0x01            ; the back buffer

DS_PADN       .equ    24              ; the pad after dsEnd: Code4a keeps its layout
SIL_BOTTOM    .equ    1
SIL_TOP       .equ    2

;;; The BSP walk (src/iigs/r_wall65.s, src/iigs/r_thing65.s) uses these 72
;;; bytes as its own direct page variables (BSPDP): no sprite is drawn in
;;; the walk, and the sprite code sets each of them before it reads it.
              .section ztiny, bss
              .public BSPDP
BSPDP:
MC_COLF:      .space  4               ; column function
MC_DCV:       .space  4               ; draw_column_vars_t *
MC_COL:       .space  4               ; current post
MC_BASE:      .space  4               ; dcvars->texturemid on entry
MC_TOP:       .space  4               ; topscreen
MC_FCLIP:     .space  2
MC_CCLIP:     .space  2
MC_YL:        .space  2
MC_PTR:       .space  4               ; clip array pointer (mfloorclip in a column)
MC_CP:        .space  4               ; mceilingclip in a column
MUL_T:        .space  2
MUL_R:        .space  4               ; product
VS_VIS:       .space  4
VS_PATCH:     .space  4
VS_FRAC:      .space  4
VS_XIS:       .space  4
VS_X:         .space  2
DS_SPR:       .space  4
DS_X:         .space  2               ; near address of the drawseg
DS_R1:        .space  2
DS_R2:        .space  2               ; r2 * 2 + 2, loop end
DS_I:         .space  2               ; the index of the drawseg in the scan
DS_T:         .space  2

              .section znear, bss
VS_WIDTH:     .space  2
VS_DCV:       .space  SIZEOF_DC       ; dcvars of R_DrawVisSprite
DS_X1:        .space  2
DS_X2:        .space  2
DS_SCALE:     .space  4               ; spr->scale
DS_GZ:        .space  4               ; spr->gz
DS_GZT:       .space  4               ; spr->gz + topoffset
DS_HI:        .space  4               ; larger drawseg scale
DS_LO:        .space  4               ; smaller drawseg scale
MC_FAST:      .space  2               ; the column function is R_DrawColumnSprite
MC_X:         .space  2               ; dcvars->x
MC_TMID:      .space  2               ; dcvars->texturemid >> 7

;;; ---------------------------------------------------------------------------
;;; mulScale: MUL_R = spryscale * C, C = 0..255 (low 32 bits, unsigned).
;;; For the columns of a wide sprite (MC_TABLE set by R_DrawVisSprite) the
;;; products come from SC_TAB, which is filled by additions up to the
;;; largest C that a post needs, and made again when spryscale changes.
;;; ---------------------------------------------------------------------------
              .section znear, bss
MC_TABLE:     .space  2
SC_N:         .space  2               ; SC_TAB[0..SC_N-1] are valid
SC_SCALE:     .space  4               ; spryscale of SC_TAB
SC_TAB:       .space  256 * 4

              .section farcode, text
mulScale:     ldx     .near MC_TABLE
              bne     scaleTable
mulScaleNow:  asl     a                     ; the products with C
              QSET    .tiny QP, .tiny QM    ;   (src/iigs/mul.inc)

              lda     .near spryscale       ; byte 0
              and     ##0xff
              asl     a
              tay
              QPROD   .tiny QP, .tiny QM
              sta     dp:.tiny MUL_R

              lda     .near (spryscale+2)   ; byte 2
              and     ##0xff
              asl     a
              tay
              QPROD   .tiny QP, .tiny QM
              sta     dp:.tiny (MUL_R+2)

              lda     .near (spryscale+3)   ; byte 3, only its low byte counts
              and     ##0xff
              beq     10$
              asl     a
              tay
              QPROD   .tiny QP, .tiny QM
              xba
              and     ##0xff00
              clc
              adc     dp:.tiny (MUL_R+2)
              sta     dp:.tiny (MUL_R+2)

10$:          lda     .near (spryscale+1)   ; byte 1, shifted by 8
              and     ##0xff
              asl     a
              tay
              QPROD   .tiny QP, .tiny QM
              tax
              xba
              and     ##0xff00
              clc
              adc     dp:.tiny MUL_R
              sta     dp:.tiny MUL_R
              txa
              xba
              and     ##0x00ff
              adc     dp:.tiny (MUL_R+2)
              sta     dp:.tiny (MUL_R+2)
              rtl

scaleTable:   ldx     .near spryscale       ; the table of this spryscale?
              cpx     .near SC_SCALE
              bne     10$
              ldx     .near (spryscale+2)
              cpx     .near (SC_SCALE+2)
              beq     20$
10$:          ldx     .near spryscale       ; start again: SC_TAB[0] = 0
              stx     .near SC_SCALE
              ldx     .near (spryscale+2)
              stx     .near (SC_SCALE+2)
              ldx     ##0
              stx     .near SC_TAB
              stx     .near (SC_TAB+2)
              inx
              stx     .near SC_N
20$:          cmp     .near SC_N            ; filled up to C?
              bcc     40$
              pha                           ; SC_TAB[n] = SC_TAB[n-1] + spryscale
              lda     .near SC_N
              asl     a
              asl     a
              tax
30$:          lda     abs:.near (SC_TAB-4),x
              clc
              adc     .near spryscale
              sta     abs:.near SC_TAB,x
              lda     abs:.near (SC_TAB-2),x
              adc     .near (spryscale+2)
              sta     abs:.near (SC_TAB+2),x
              inx
              inx
              inx
              inx
              inc     .near SC_N
              lda     1,s
              cmp     .near SC_N
              bcs     30$
              pla
40$:          asl     a
              asl     a
              tax
              lda     abs:.near SC_TAB,x
              sta     dp:.tiny MUL_R
              lda     abs:.near (SC_TAB+2),x
              sta     dp:.tiny (MUL_R+2)
              rtl

;;; ---------------------------------------------------------------------------
;;; void R_DrawMaskedColumn(R_DrawColumn_f colfunc, draw_column_vars_t *dcvars,
;;;                         const column_t __far* column)
;;; In: _Dp[0-3] = colfunc, _Dp[4-7] = dcvars, column on the stack.
;;; Uses spryscale, sprtopscreen, mfloorclip, mceilingclip.
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public R_DrawMaskedColumn
R_DrawMaskedColumn:
              stz     .near MC_TABLE        ; spryscale changes for each column
              lda     dp:.tiny _Dp
              sta     dp:.tiny MC_COLF
              lda     dp:.tiny (_Dp+2)
              sta     dp:.tiny (MC_COLF+2)
              lda     dp:.tiny (_Dp+4)
              sta     dp:.tiny MC_DCV
              lda     dp:.tiny (_Dp+6)
              sta     dp:.tiny (MC_DCV+2)
              lda     4,s
              sta     dp:.tiny MC_COL
              lda     6,s
              sta     dp:.tiny (MC_COL+2)
              ; fall through

;;; maskedColumn: the same with the arguments in MC_COLF, MC_DCV, MC_COL.
maskedColumn:
              jsl     long:columnSetup
              ; fall through

;;; maskedColumnX: a column with the setup of columnSetup: only the column
;;; x and its clip values are new. R_DrawVisSprite calls it for each
;;; column of a sprite.
maskedColumnX:
              ldy     ##OFS_DC_X
              lda     [.tiny MC_DCV],y
              sta     .near MC_X
              asl     a
              tay
              lda     [.tiny MC_PTR],y      ; (the clip arrays hold the clips + 1:
              dec     a                     ;   src/iigs/segvar.inc)
              sta     dp:.tiny MC_FCLIP
              lda     [.tiny MC_CP],y
              dec     a
              sta     dp:.tiny MC_CCLIP
              jmp     .kbank postLoop

;;; columnSetup: what does not change from column to column: the texture
;;; position of dcvars, the fast drawer inputs and the clip arrays.
columnSetup:  ldy     ##OFS_DC_TEXTUREMID
              lda     [.tiny MC_DCV],y
              sta     dp:.tiny MC_BASE
              iny
              iny
              lda     [.tiny MC_DCV],y
              sta     dp:.tiny (MC_BASE+2)

              ;; the texture column drawer (R_DrawColumnSprite = R_DrawColumnWall)
              ;; is called through its fast entry
              stz     .near MC_FAST
              lda     dp:.tiny MC_COLF
              cmp     ##.word0 R_DrawColumnSprite
              bne     1$
              lda     dp:.tiny (MC_COLF+2)
              cmp     ##.word2 R_DrawColumnSprite
              bne     1$
              jsl     long:fastSetup

1$:           lda     .near mfloorclip
              sta     dp:.tiny MC_PTR
              lda     .near (mfloorclip+2)
              sta     dp:.tiny (MC_PTR+2)
              lda     .near mceilingclip
              sta     dp:.tiny MC_CP
              lda     .near (mceilingclip+2)
              sta     dp:.tiny (MC_CP+2)
              rtl

postLoop:     lda     [.tiny MC_COL]        ; topdelta
              and     ##0xff
              cmp     ##0xff
              bne     1$
              jmp     .kbank postsDone

              ;; topscreen = sprtopscreen + spryscale * topdelta
1$:           jsl     long:mulScale
              lda     dp:.tiny MUL_R
              clc
              adc     .near sprtopscreen
              sta     dp:.tiny MC_TOP
              lda     dp:.tiny (MUL_R+2)
              adc     .near (sprtopscreen+2)
              sta     dp:.tiny (MC_TOP+2)

              ;; yl = (topscreen + FRACUNIT - 1) >> FRACBITS
              lda     dp:.tiny MC_TOP
              clc
              adc     ##0xffff
              lda     dp:.tiny (MC_TOP+2)
              adc     ##0
              sta     dp:.tiny MC_YL

              ;; bottomscreen = topscreen + spryscale * length
              ;; yh = (bottomscreen - 1) >> FRACBITS
              lda     [.tiny MC_COL]
              xba
              and     ##0xff
              jsl     long:mulScale
              lda     dp:.tiny MUL_R
              clc
              adc     dp:.tiny MC_TOP
              tax
              lda     dp:.tiny (MUL_R+2)
              adc     dp:.tiny (MC_TOP+2)
              cpx     ##1                   ; borrow of - 1 when the low word is 0
              sbc     ##0
              tax                           ; X = yh

              ;; if (yh >= fclip) yh = fclip - 1
              sec
              sbc     dp:.tiny MC_FCLIP
              bvc     2$
              eor     ##0x8000
2$:           bmi     3$
              ldx     dp:.tiny MC_FCLIP
              dex
              ;; if (yl <= cclip) yl = cclip + 1
3$:           lda     dp:.tiny MC_CCLIP
              sec
              sbc     dp:.tiny MC_YL
              bvc     4$
              eor     ##0x8000
4$:           bmi     5$
              lda     dp:.tiny MC_CCLIP
              inc     a
              sta     dp:.tiny MC_YL

              ;; if (yl <= yh && yh < VIEWHEIGHT) draw
5$:           txa
              sec
              sbc     dp:.tiny MC_YL
              bvc     6$
              eor     ##0x8000
6$:           bmi     nextPost
              txa
              sec
              sbc     ##CONST_VIEWHEIGHT
              bvc     7$
              eor     ##0x8000
7$:           bpl     nextPost

              lda     .near MC_FAST
              beq     8$
              jmp     .kbank fastPost
8$:           txa
              ldy     ##OFS_DC_YH
              sta     [.tiny MC_DCV],y
              lda     dp:.tiny MC_YL
              ldy     ##OFS_DC_YL
              sta     [.tiny MC_DCV],y
              lda     dp:.tiny MC_COL       ; source = column + 3
              clc
              adc     ##3
              ldy     ##OFS_DC_SOURCE
              sta     [.tiny MC_DCV],y
              lda     dp:.tiny (MC_COL+2)
              adc     ##0
              iny
              iny
              sta     [.tiny MC_DCV],y
              ;; texturemid = basetexturemid - (topdelta << FRACBITS)
              lda     dp:.tiny MC_BASE
              ldy     ##OFS_DC_TEXTUREMID
              sta     [.tiny MC_DCV],y
              lda     [.tiny MC_COL]
              and     ##0xff
              sta     dp:.tiny MUL_T
              lda     dp:.tiny (MC_BASE+2)
              sec
              sbc     dp:.tiny MUL_T
              iny
              iny
              sta     [.tiny MC_DCV],y

              lda     dp:.tiny MC_DCV
              sta     dp:.tiny _Dp
              lda     dp:.tiny (MC_DCV+2)
              sta     dp:.tiny (_Dp+2)
              jsl     long:callColumn

              ;; column += length + 4
nextPost:     lda     [.tiny MC_COL]
              xba
              and     ##0xff
              sec                           ; + 1
              adc     ##3
              adc     dp:.tiny MC_COL
              sta     dp:.tiny MC_COL
              jmp     .kbank postLoop

postsDone:    lda     dp:.tiny MC_BASE
              ldy     ##OFS_DC_TEXTUREMID
              sta     [.tiny MC_DCV],y
              lda     dp:.tiny (MC_BASE+2)
              iny
              iny
              sta     [.tiny MC_DCV],y
              rtl

callColumn:   .byte   0xdc                  ; jml [MC_COLF]
              .word   .word0 MC_COLF

              ;; the post through R_WallColumnFast: X = yh
fastPost:     txa
              sec
              sbc     dp:.tiny MC_YL
              inc     a
              sta     dp:.tiny DC_COUNT
              lda     dp:.tiny MC_YL
              sta     dp:.tiny DC_ROW
              lda     .near MC_X
              sta     dp:.tiny DC_COLX
              lda     dp:.tiny MC_COL       ; source = column + 3
              clc
              adc     ##3
              sta     dp:.tiny DC_SRC
              lda     dp:.tiny (MC_COL+2)
              adc     ##0
              sta     dp:.tiny (DC_SRC+2)
              lda     [.tiny MC_COL]        ; (texturemid - (topdelta << 16)) >> 7
              and     ##0xff
              xba
              asl     a
              sta     dp:.tiny MUL_T
              lda     .near MC_TMID
              sec
              sbc     dp:.tiny MUL_T
              sta     dp:.tiny DC_TMID7
              jsl     long:R_WallColumnFast
              jmp     .kbank nextPost

;;; fastSetup: the inputs of R_WallColumnFast that do not change in a column.
fastSetup:    lda     ##1
              sta     .near MC_FAST
              ldy     ##OFS_DC_FRACSTEP
              lda     [.tiny MC_DCV],y
              sta     dp:.tiny DC_FSTEP
              lda     dp:.tiny MC_BASE      ; texturemid >> 7
              xba
              asl     a
              lda     dp:.tiny (MC_BASE+1)
              rol     a
              sta     .near MC_TMID
              ldy     ##OFS_DC_COLORMAP     ; the SHR colormaps
              lda     [.tiny MC_DCV],y
              sec
              sbc     ##.word0 fullcolormap
              tax
              clc
              adc     ##.word0 iigs_shrcmapA
              sta     dp:.tiny DC_CMA
              lda     ##.word2 iigs_shrcmapA
              adc     ##0
              sta     dp:.tiny (DC_CMA+2)
              txa
              clc
              adc     ##.word0 iigs_shrcmapB
              sta     dp:.tiny DC_CMB
              lda     ##.word2 iigs_shrcmapB
              adc     ##0
              sta     dp:.tiny (DC_CMB+2)
              rtl

;;; ---------------------------------------------------------------------------
;;; visColF: the columns of a shadow sprite (R_DrawVisSprite of
;;; src/iigs/r_seg65.s made its setup: YHTAB, the clips, the patch; DP =
;;; WPAGE, DBR = RECBANK, 16-bit A in). Each post that shows is a K_FUZZ
;;; record at the end of its column list, as R_DrawMaskedColumn and
;;; R_DrawFuzzColumn made it before (2026-09-27): the clipped rows also
;;; kept to 1 .. VIEWHEIGHT - 2, the fuzz position FZ_POS, then FZ_POS =
;;; (FZ_POS + the count) mod 50. All columns, also in the half and 2/3
;;; views: the fuzz position of a column follows the rows of the columns
;;; before it.
;;; ---------------------------------------------------------------------------
FZ_N          .equ    V_K             ; the count of rows (a byte; FZ_N + 1 is 0)
FZ_P          .equ    V_S2            ; FZ_POS in the loop (a byte; FZ_P + 1 is 0)

              .section farcode, text
;;; No open column: avoid the sprite setup. The drawer can reach past
;;; x2, so check x2+1 too, then prove the next texture column is outside
;;; the patch. If it is still inside, keep the original drawing path.
fzPad:
dsVisible:    rep     #0x20
              lda     .near DS_X2
              inc     a
              inc     a
              cmp     ##CONST_VIEWWIDTH
              bcc     dsVlimit
              lda     ##CONST_VIEWWIDTH
dsVlimit:           asl     a
              sta     dp:.tiny DS_R2
              lda     .near DS_X1
              asl     a
              tax
              cpx     dp:.tiny DS_R2
              bcs     dsVbeyond
              sep     #0x20
dsVscan:           lda     abs:.near floorclip,x
              beq     dsVnext
              dec     a
              cmp     abs:.near ceilingclip,x
              bcc     dsVnext
              beq     dsVnext
dsDraw:       rep     #0x20
              lda     ##.word0 floorclip
              jmp     .kbank (dsEnd+5)
dsVnext:           inx
              inx
              cpx     dp:.tiny DS_R2
              bcc     dsVscan
dsVbeyond:           rep     #0x20
              cpx     ##(2 * CONST_VIEWWIDTH)
              bcs     dsEmpty
              ldy     ##OFS_VIS_GY
              lda     [.tiny DS_SPR],y
              sta     dp:.tiny MC_PTR
              iny
              iny
              lda     [.tiny DS_SPR],y
              sta     dp:.tiny (MC_PTR+2)
              lda     [.tiny MC_PTR]
              cmp     ##512
              bcs     dsVexact
              ldy     ##(OFS_VIS_XISCALE+2)
              lda     [.tiny DS_SPR],y
              beq     dsVexact
              inc     a
              beq     dsVexact
              ;; Width < 512 and |xiscale| >= 1: the reciprocal table can
              ;; extend the last column by at most two. Check the second.
              sep     #0x20
              lda     abs:.near floorclip,x
              beq     dsVfastEmpty
              dec     a
              cmp     abs:.near ceilingclip,x
              bcc     dsVfastEmpty
              beq     dsVfastEmpty
              brl     dsDraw
dsVfastEmpty: rep     #0x20
              rtl
dsVexact:
              txa                           ; frac at the first untested column
              lsr     a
              sec
              sbc     .near DS_X1
              sta     dp:.tiny (_Dp+2)
              stz     dp:.tiny _Dp
              ldy     ##(OFS_VIS_XISCALE+2)
              lda     [.tiny DS_SPR],y
              tax
              ldy     ##OFS_VIS_XISCALE
              lda     [.tiny DS_SPR],y
              jsl     long:FixedMul
              ldy     ##OFS_VIS_STARTFRAC
              clc
              adc     [.tiny DS_SPR],y
              txa
              ldy     ##(OFS_VIS_STARTFRAC+2)
              adc     [.tiny DS_SPR],y
              bmi     dsEmpty
              cmp     [.tiny MC_PTR]        ; patch width
              bcc     dsDraw
dsEmpty:      rtl
              .space  271 - (. - fzPad)      ; keep the farcode layout

              .section vw3code, text        ; (bank 4, as vrFill)
              .public visColF
              .extern vrFill, COLW, newPage, YHTABM
YHTAB         .equ    YHTABM + 2
visColF:      lda     long:FZ_POS           ; (16-bit A: the high bytes 0)
              sta     dp:FZ_P
              stz     dp:FZ_N
              sep     #0x20

fzCol:        ldy     dp:W_X2
              cpy     ##(2 * CONST_VIEWWIDTH)
              bcs     fzDone
              lda     [V_FCP],y             ; V_HI = min(floorclip, VIEWHEIGHT - 1),
              beq     fzNext                ;   V_LO = max(ceilingclip + 1, 1): the
              dec     a                     ;   rows V_LO .. V_HI - 1 (the clip
              cmp     #(CONST_VIEWHEIGHT - 1) ;   arrays hold the clips + 1)
              bcc     1$
              lda     #(CONST_VIEWHEIGHT - 1)
1$:           sta     dp:V_HI
              lda     [V_CCP],y
              bne     2$
              inc     a
2$:           sta     dp:V_LO
              cmp     dp:V_HI
              bcs     fzNext
              rep     #0x20
              lda     dp:(V_FRAC+2)         ; column = patch + columnofs[frac >> FRACBITS]
              asl     a
              asl     a
              adc     ##OFS_PATCH_COLUMNOFS ; (carry clear)
              tay
              lda     [V_PATCH],y
              clc
              adc     dp:V_PATCH
              sta     dp:V_COL
              sep     #0x20
              bra     fzPost

fzNext:       rep     #0x20                 ; frac += xiscale; the next column
              lda     dp:V_FRAC
              clc
              adc     dp:V_XIS
              sta     dp:V_FRAC
              lda     dp:(V_FRAC+2)
              adc     dp:(V_XIS+2)
              sta     dp:(V_FRAC+2)
              bmi     fzDone                ; frac < 0
              cmp     dp:V_WIDTH            ; (frac >> FRACBITS) >= width
              bcs     fzDone
              lda     dp:W_X2
              adc     ##2                   ; (carry clear)
              sta     dp:W_X2
              sep     #0x20
              bra     fzCol
fzDone:       rep     #0x20
              lda     dp:FZ_P
              sta     long:FZ_POS
              plb
              pld
              rtl

fzSkip:       sep     #0x20
fzAdv:        lda     dp:V_LEN              ; the next post: V_COL += length + 4
              clc
              adc     #4
              bcc     1$
              inc     dp:(V_COL+1)
              clc
1$:           adc     dp:V_COL
              sta     dp:V_COL
              bcc     fzPost
              inc     dp:(V_COL+1)
fzPost:       lda     [V_COL]               ; topdelta, 0xff: no more posts
              cmp     #0xff
              beq     fzNext
              sta     dp:V_TD
              ldy     ##1
              lda     [V_COL],y             ; length
              sta     dp:V_LEN
              rep     #0x20
              lda     dp:V_TD               ; yh = YHTAB[topdelta + length]: none
              clc                           ;   above V_LO; V_YH1 = min(yh + 1,
              adc     dp:V_LEN              ;   V_HI)
              cmp     dp:V_TN
              bcc     3$
              jsr     .kbank vrFill
3$:           asl     a
              tax
              lda     long:YHTAB,x
              bmi     fzSkip
              cmp     dp:V_LO
              bcc     fzSkip
              cmp     dp:V_HI
              bcc     4$
              lda     dp:V_HI
              dec     a
4$:           inc     a
              sta     dp:V_YH1              ; (16-bit: its high byte 0)
              lda     dp:V_TD               ; yl = YHTAB[topdelta] + 1: none from
              asl     a                     ;   V_HI; V_YL = max(yl, V_LO)
              tax
              lda     long:YHTAB,x
              bmi     5$
              inc     a
              cmp     dp:V_HI
              bcs     fzSkip
              cmp     dp:V_LO
              bcs     6$
5$:           lda     dp:V_LO
6$:           sep     #0x20
              sta     dp:V_YL
              lda     dp:V_YH1              ; the count of rows
              sec
              sbc     dp:V_YL
              beq     fzAdv
              bcc     fzAdv
              sta     dp:FZ_N

              ;; the K_FUZZ record at the end of the list of the column, in
              ;; the order of recFuzz: the room first (a flush of all lists
              ;; comes before the cuts below)
              ldx     dp:W_X2
              lda     long:(COLW+1),x       ; Y = the free byte of the list (two
              xba                           ;   8-bit loads: no REP/SEP)
              lda     long:COLW,x
              tay
              cmp     #(PAGE_ROOM - FUZZ_SIZE + 1) ; no room in the page: an
              bcs     fzPage                ;   extra page first
fzRec:        adc     #FUZZ_SIZE            ; (carry clear)
              sta     long:COLW,x           ; COLW past the record
              FSCUT   dp:V_YL, dp:V_YH1     ; the fill spans of the column end
              lda     #255                  ;   at the post; no covered range in
              sta     long:CV_ROW,x         ;   the column (lists.inc)
              lda     #254
              sta     long:(CV_ROW+1),x
              lda     #K_FUZZ
              sta     abs:R_KIND,y
              lda     dp:V_YL
              sta     abs:R_ROW,y
              lda     dp:FZ_N
              sta     abs:R_COUNT,y
              lda     dp:FZ_P               ; the fuzz position, then + the count
              sta     abs:R_POS,y           ;   mod 50
              clc
              adc     dp:FZ_N
              sta     dp:FZ_N
              ldx     dp:FZ_N
              lda     long:fuzzMod50,x
              sta     dp:FZ_P
              brl     fzAdv
fzPage:       rep     #0x20                 ; an extra page first
              jsl     long:newPage          ; Y = the free byte of the new page
              tya
              sep     #0x20
              clc
              bra     fzRec
              ;; the old shadow path's fragments stay linked: no code or data
              ;; after them moves (R_DrawMaskedColumn keeps mulScale and
              ;; SC_TAB)
              .word   .word0 R_DrawMaskedColumn, .word0 fzPad

;;; ---------------------------------------------------------------------------
;;; The weapon from a profile of its patch (2026-09-27): its clip pass
;;; (weaponClip of src/iigs/r_frame65.s, visPost 30$ of src/iigs/r_seg65.s)
;;; and its draw (the K_TEX records of visPost 11$). At unit scale the rows
;;; of a post are its texel rows + V_YH0, so the profile of a lump (made at
;;; its first draw) keeps for each post a = topdelta + 1, b = a + length,
;;; the a of the first post of its run of touching posts and its texels.
;;; With hi = V_HI - V_YH0, the clip pass of a column takes the post with
;;; a < hi <= b, the draw makes a record of each post with a < hi, with no
;;; walk of the patch (demo3: the pass took 1.9 ms a frame, the draw 2.2).
;;; Anything else, or a weapon above row 0: the old code.
;;; ---------------------------------------------------------------------------
WP_TAGL       .equ    MM_WPROF        ; the lumps of the profiles (16 at most)
WP_TAGB       .equ    (MM_WPROF + 0x20) ; and their addresses
WP_NT         .equ    (MM_WPROF + 0x40) ; 2 * the profiles made
WP_FREE       .equ    (MM_WPROF + 0x42) ; the next free byte and its arena (0,
WP_AR         .equ    (MM_WPROF + 0x44) ;   2)
WP_SIG        .equ    (MM_WPROF + 0x46) ; 0x5aa5, 0xc33c: the tags are made
WP_NONE       .equ    (MM_WPROF + 0x4c) ; a profile of width 0: the old code
WB_BUF        .equ    ((MM_WPROF + 0x50) & 0xffff) ; wpBuild: the posts of a column
                                      ;   (14 at most, 5 bytes each)
;;; The profiles: in the arenas $0A:D000-E3FF and $0A:ED00-FEFF (cache slots
;;; $5000-$63FF, $6D00-$7EFF: off the replay's and off this code's, $6763-
;;; $6CFF), in the order they are made; all go when the arenas are full.
;;; A profile: +0 width (320 at most; 0: none), +2 the minimum a, +4 +6 the
;;; columns of each parity, +8 +10 their tables (2 bytes a column: the
;;; address of its list), +12 the list of a column with no post (0, 0), +16
;;; the tables, then the lists: the posts of a column from the lowest up,
;;; 5 bytes each (a + 1, b + 1, the a of its run, the offset of its texels
;;; in the patch), then 0.
WP_A0         .equ    0xd000
WP_A0END      .equ    0xe400
WP_A1         .equ    0xed00
WP_A1END      .equ    0xff00
WP_BANK       .equ    (MM_WPROF & 0xff0000)
;;; The words of wcProf and wdProf on WPAGE (bytes the pass writes too)
WP_VIS        .equ    V_TM7           ; the vissprite
WP_HI         .equ    V_TN            ; hi
WP_TMP        .equ    V_S2
WP_YEND       .equ    V_E             ; 2 * the column after the last
WP_TX         .equ    V_WIDTH         ; the table entry of the column
WP_YM1        .equ    V_UNIT          ; V_YH0 - 1 (a byte)
WP_TF         .equ    V_SS            ; R_TF, R_TI of the records
WP_TI         .equ    (V_SS+1)
WP_SRC        .equ    V_FRAC          ; R_SRC of a record (the low word)
WP_PP         .equ    V_XIS           ; the post

;;; CVSETB first, end: CVSET of lists.inc with B = the page of Y (as in
;;; src/iigs/r_seg65.s).
WCVSET        .macro  first, end
              lda     long:(CV_ROW+1),x
              sec
              sbc     long:CV_ROW,x
              clc
              adc     \first
              bcs     9$
              cmp     \end
              bcs     9$
              lda     \first
              sta     long:CV_ROW,x
              tya
              sta     long:CV_REC,x
              xba
              sta     long:(CV_REC+1),x
              lda     \end
              sta     long:(CV_ROW+1),x
9$:
              .endm

;;; wcDraw3: R_DrawVisSprite (_Dp = the vissprite) for pspSprite, or the clip
;;; pass from the profile: unit scale, a whole first column and 2 columns
;;; of the patch a column (a column is the next entry of the table of its
;;; parity), the clip arrays of psSetup, no sprite clip of the weapon skip.
              .public wcDraw3
wcDraw3:      lda     .near VS_CLIP         ; MM_WPOK: 0x5aa5 after the clip pass
              beq     10$                   ;   (FR_VIS: also the weapon to draw,
              lda     ##0x5aa5              ;   pspDraw0 of src/iigs/r_frame65.s),
              sta     long:MM_WPOK          ;   0 after a draw
              jsr     .kbank wpCheck
              bcs     9$
              phd                           ; the direct page of the sprites
              lda     ##WPAGE
              tcd
              lda     dp:W_WSK
              bne     8$
              stx     dp:WP_VIS
              jsr     .kbank wpFind         ; carry set: no profile
              bcs     8$
              ldx     dp:WP_VIS
              jsr     .kbank wcProf         ; carry set: the pass itself
              bcs     8$
              pld
              rtl
8$:           pld
9$:           jmp     long:R_DrawVisSprite
10$:          sta     long:MM_WPOK
              jmp     long:R_DrawVisSprite

;;; wdDraw: the draw of the weapon of this frame's clip pass (_Dp = FR_VIS,
;;; pspDraw0 of src/iigs/r_frame65.s): R_DrawVisSprite, or its records from
;;; the profile: the checks of the clip pass, a step of 1.0 texel a row, no
;;; weapon skip (WCLIP: a clip for each column) and the full view (the
;;; others draw other columns).
              .public wdDraw
wdDraw:       lda     ##0
              sta     long:MM_WPOK
              jsr     .kbank wpCheck
              bcs     9$
              lda     abs:OFS_VIS_COLORMAP,x ; (not the shadow weapon)
              ora     abs:(OFS_VIS_COLORMAP+2),x
              beq     9$
              lda     abs:OFS_VIS_FRACSTEP,x
              cmp     ##512
              bne     9$
              lda     long:VW_HALF      ; qApply patches these 10 bytes
              ora     long:VW_THIRD     ;   (wdDraw+28) for 1/4 and 1/3
              bne     9$
              phd
              lda     ##WPAGE
              tcd
              lda     dp:W_WSK
              bne     8$
              stx     dp:WP_VIS
              jsr     .kbank wpFind
              bcs     8$
              ldx     dp:WP_VIS
              jsr     .kbank wdProf         ; carry set: the old draw
              bcs     8$
              pld
              rtl
8$:           pld
9$:           jmp     long:R_DrawVisSprite

;;; wpCheck: X = the vissprite (_Dp); carry clear: unit scale, xiscale 2.0,
;;; a whole startfrac, the clip arrays of psSetup.
wpCheck:      ldx     dp:.tiny _Dp
              lda     abs:OFS_VIS_SCALE,x
              ora     abs:OFS_VIS_XISCALE,x
              ora     abs:OFS_VIS_STARTFRAC,x
              bne     9$
              lda     abs:(OFS_VIS_SCALE+2),x
              cmp     ##1
              bne     9$
              lda     abs:(OFS_VIS_XISCALE+2),x
              cmp     ##2
              bne     9$
              lda     .near mfloorclip
              cmp     ##.near screenheightarray
              bne     9$
              lda     .near mceilingclip
              cmp     ##.near negonearray
              bne     9$
              clc
              rts
9$:           sec
              rts

;;; wpFind: V_K = the profile of the lump of the vissprite (X), made now if
;;; it is not there. Carry set: none (width 0: the old code).
wpFind:       lda     long:WP_SIG           ; the first time: no profiles
              cmp     ##0x5aa5
              bne     1$
              lda     long:(WP_SIG+2)
              cmp     ##0xc33c
              beq     3$
1$:           jsr     .kbank wpFlush
              lda     ##0
              sta     long:WP_NONE
              lda     ##0x5aa5
              sta     long:WP_SIG
              lda     ##0xc33c
              sta     long:(WP_SIG+2)
              ldx     dp:WP_VIS
3$:           lda     abs:OFS_VIS_LUMP,x
              pha
              lda     long:WP_NT
              tax
              pla
4$:           dex
              dex
              bmi     7$
              cmp     long:WP_TAGL,x
              bne     4$
              lda     long:WP_TAGB,x
              sta     dp:V_K
              tax
              lda     long:WP_BANK,x        ; width 0: the old code
              beq     6$
              clc
              rts
6$:           sec
              rts
7$:           brl     wpBuild

;;; wpFlush: no profiles; the next one at the start of the first arena.
wpFlush:      lda     ##0
              sta     long:WP_NT
              sta     long:WP_AR
              lda     ##WP_A0
              sta     long:WP_FREE
              rts

;;; wpBuild: the profile of the patch of the vissprite (WP_VIS), tagged with
;;; its lump (C), at WP_FREE: in the next arena, or after a flush, when it
;;; does not fit there; a patch that the profile cannot hold gets WP_NONE.
;;; The direct page words are bytes the pass writes too.
BD_TL         .equ    V_E             ; topdelta | length << 8
BD_A          .equ    V_FCP           ; a
BD_PB         .equ    (V_FCP+2)       ; b of the post before
BD_RSA        .equ    V_CCP           ; the a of the run
BD_LEN        .equ    (V_CCP+2)       ; the length, then b
BD_C          .equ    V_FRAC          ; the column
BD_ENT        .equ    (V_FRAC+2)      ; its entry
BD_FREE       .equ    V_XIS           ; the next free byte
BD_LIM        .equ    (V_XIS+2)       ; the end of the arena
BD_MINA       .equ    V_COL
BD_W          .equ    (V_COL+2)       ; the width
BD_N          .equ    V_TN            ; the posts of the column
BD_LUMP       .equ    W_X2
BD_OFF        .equ    V_YH1           ; the offset of the post
BD_TRY        .equ    V_YL            ; the tries left
wpBuild:      sta     dp:BD_LUMP
              ldx     dp:WP_VIS             ; V_PATCH: the patch (vis->gy)
              lda     abs:OFS_VIS_GY,x
              sta     dp:V_PATCH
              lda     abs:(OFS_VIS_GY+2),x
              and     ##0x00ff
              sta     dp:(V_PATCH+2)
              phb                           ; DBR = $0A: the profiles, WB_BUF
              pea     #((WP_BANK >> 16) * 0x0101)
              plb
              plb
              lda     abs:(WP_NT & 0xffff)  ; 16 tags: all go
              cmp     ##32
              bcc     1$
              jsr     .kbank wpFlush
1$:           lda     ##3
              sta     dp:BD_TRY
2$:           lda     abs:(WP_FREE & 0xffff)
              sta     dp:V_K
              lda     ##WP_A0END
              ldx     abs:(WP_AR & 0xffff)
              beq     3$
              lda     ##WP_A1END
3$:           sta     dp:BD_LIM
              jsr     .kbank wbMake         ; carry set: A = 1 no room, 2 cannot
              bcc     7$
              cmp     ##1
              bne     6$
              dec     dp:BD_TRY
              beq     6$
              lda     abs:(WP_AR & 0xffff)  ; the second arena, else all again
              bne     4$
              lda     ##2
              sta     abs:(WP_AR & 0xffff)
              lda     ##WP_A1
              sta     abs:(WP_FREE & 0xffff)
              bra     2$
4$:           jsr     .kbank wpFlush
              bra     2$
6$:           lda     ##(WP_NONE & 0xffff)
              sta     dp:V_K
              bra     8$
7$:           lda     dp:BD_FREE
              sta     abs:(WP_FREE & 0xffff)
8$:           lda     abs:(WP_NT & 0xffff)  ; the tag
              tax
              lda     dp:BD_LUMP
              sta     abs:(WP_TAGL & 0xffff),x
              lda     dp:V_K
              sta     abs:(WP_TAGB & 0xffff),x
              inx
              inx
              txa
              sta     abs:(WP_NT & 0xffff)
              plb
              ldx     dp:V_K                ; width 0: the old code
              lda     long:WP_BANK,x
              beq     9$
              clc
              rts
9$:           sec
              rts

;;; wbMake: the profile at V_K, below BD_LIM, in one walk of each column.
;;; Carry clear: made, BD_FREE after it; else A = 1: no room, 2: the patch
;;; does not fit the profile (a width over 320, posts that overlap or end
;;; after row 254 of the patch, 15 posts in a column). DBR $0A.
wbMake:       ldx     dp:V_K
              stz     abs:0,x               ; width 0 until it is made
              lda     [V_PATCH]             ; the width
              beq     90$
              cmp     ##321
              bcs     90$
              sta     dp:BD_W
              asl     a                     ; the header and the tables
              adc     ##16
              adc     dp:V_K
              bcs     91$
              sta     dp:BD_FREE
              cmp     dp:BD_LIM
              bcs     91$
              lda     dp:BD_W
              inc     a
              lsr     a
              sta     abs:4,x               ; the columns of each parity
              lda     dp:BD_W
              lsr     a
              sta     abs:6,x
              txa                           ; their tables
              clc
              adc     ##16
              sta     abs:8,x
              lda     abs:4,x
              asl     a
              adc     abs:8,x
              sta     abs:10,x
              stz     abs:12,x              ; the list of a column with no post
              lda     ##0xffff
              sta     dp:BD_MINA
              stz     dp:BD_C
              bra     1$
90$:          lda     ##2
              sec
              rts
91$:          lda     ##1
              sec
              rts
1$:           lda     dp:BD_C               ; the entry of column c: the table
              and     ##1                   ;   of its parity + (c & ~1)
              asl     a
              adc     dp:V_K
              tax
              lda     dp:BD_C
              and     ##0xfffe
              clc
              adc     abs:8,x
              sta     dp:BD_ENT
              lda     dp:BD_C               ; its posts: columnofs[c]
              asl     a
              asl     a
              adc     ##OFS_PATCH_COLUMNOFS
              tay
              lda     [V_PATCH],y
              tay
              ldx     ##0                   ; X = 5 * the posts in WB_BUF
              stz     dp:BD_PB
              stz     dp:BD_N
2$:           lda     [V_PATCH],y           ; topdelta | length << 8
              sta     dp:BD_TL
              and     ##0x00ff
              cmp     ##0x00ff
              beq     4$
              inc     a                     ; a
              sta     dp:BD_A
              sty     dp:BD_OFF
              lda     dp:BD_TL              ; the next post: + length + 4
              xba
              and     ##0x00ff
              sta     dp:BD_LEN
              tya
              sec
              adc     dp:BD_LEN
              adc     ##3
              tay
              lda     dp:BD_LEN             ; length 0: not drawn
              beq     2$
              clc                           ; b <= 254, a >= the b before
              adc     dp:BD_A
              cmp     ##255
              bcs     90$
              sta     dp:BD_LEN
              lda     dp:BD_A
              cmp     dp:BD_PB
              bcc     90$
              beq     3$                    ; it touches the post before: its run
              sta     dp:BD_RSA
3$:           cmp     dp:BD_MINA
              bcs     31$
              sta     dp:BD_MINA
31$:          inc     a                     ; a + 1 | (b + 1) << 8
              sta     dp:BD_TL
              lda     dp:BD_LEN
              inc     a
              xba
              ora     dp:BD_TL
              sta     abs:WB_BUF,x
              lda     dp:BD_RSA
              sta     abs:(WB_BUF+2),x
              lda     dp:BD_OFF             ; the texels: the post + 3
              clc
              adc     ##3
              sta     abs:(WB_BUF+3),x
              lda     dp:BD_LEN
              sta     dp:BD_PB
              inc     dp:BD_N
              txa
              clc
              adc     ##5
              tax
              cpx     ##(5 * 15)
              bcc     2$
              brl     90$
4$:           ldy     dp:BD_ENT             ; the list, from the lowest post up
              txa
              bne     5$
              lda     dp:V_K                ; (no post: the list of the header)
              clc
              adc     ##12
              sta     abs:0,y
              bra     8$
5$:           clc                           ; room for 5 n + 1 bytes
              adc     dp:BD_FREE
              cmp     dp:BD_LIM
              bcc     51$
              brl     91$
51$:          lda     dp:BD_FREE
              sta     abs:0,y
              tay
6$:           txa                           ; the posts of WB_BUF from the last
              sec
              sbc     ##5
              tax
              lda     abs:WB_BUF,x
              sta     abs:0,y
              lda     abs:(WB_BUF+2),x
              sta     abs:2,y
              lda     abs:(WB_BUF+3),x
              sta     abs:3,y
              iny
              iny
              iny
              iny
              iny
              txa
              bne     6$
              sep     #0x20                 ; the end: a + 1 = 0
              sta     abs:0,y
              rep     #0x20
              iny
              sty     dp:BD_FREE
8$:           lda     dp:BD_C               ; the next column
              inc     a
              sta     dp:BD_C
              cmp     dp:BD_W
              bcs     9$
              brl     1$
9$:           ldx     dp:V_K                ; made: the minimum a, the width
              lda     dp:BD_MINA
              sta     abs:2,x
              lda     dp:BD_W
              sta     abs:0,x
              clc
              rts

;;; wpStart: the start of wcProf and wdProf, for the vissprite X and the
;;; profile V_K: V_YH0, hi, and the columns: X = the table entry of the first
;;; (WP_TX), Y = 2 x1, WP_YEND. Carry set: the old code; the overflow flag
;;; set: no column or no post shows (nothing to do).
;;; (V_YH0 = (sprtopscreen - 1) >> 16, sprtopscreen = CENTERY << 16 -
;;; texturemid at unit scale, as R_DrawVisSprite.)
wpStart:      lda     ##0
              sec
              sbc     abs:OFS_VIS_TEXTUREMID,x
              tay
              lda     ##CONST_CENTERY
              sbc     abs:(OFS_VIS_TEXTUREMID+2),x
              cpy     ##0
              bne     1$
              dec     a
1$:           sta     dp:V_YH0
              lda     .near screenheightarray ; V_HI: the view bottom (psSetup)
              and     ##0x00ff
              dec     a
              beq     2$
              bmi     2$
              sta     dp:V_HI
              sec                           ; hi = V_HI - V_YH0: 0 or less: no
              sbc     dp:V_YH0              ;   post shows above V_HI
              beq     2$
              bmi     2$
              cmp     ##255                 ; (255 or more: the old code)
              bcs     8$
              sta     dp:WP_HI
              lda     abs:OFS_VIS_X1,x      ; Y = 2 x1
              asl     a
              tay
              lda     abs:(OFS_VIS_STARTFRAC+2),x ; c0, the first column
              ldx     dp:V_K
              cmp     long:WP_BANK,x        ; c0 < width (unsigned)
              bcs     8$
              sta     dp:WP_TMP
              lda     long:(WP_BANK+2),x    ; V_YH0 + the minimum a >= 0: no
              clc                           ;   post above row 0 (V_LO)
              adc     dp:V_YH0
              bmi     8$
              lda     dp:WP_TMP
              lsr     a                     ; the table of the parity of c0
              bcc     3$
              inx
              inx
3$:           asl     a                     ; 2 * (c0 >> 1)
              sta     dp:WP_TMP
              lda     long:(WP_BANK+4),x    ; 2 * the columns: min(its entries
              asl     a                     ;   from c0, VIEWWIDTH - x1)
              sec
              sbc     dp:WP_TMP
              sta     dp:WP_YEND
              tya
              eor     ##0xffff
              sec
              adc     ##(2 * CONST_VIEWWIDTH)
              beq     2$
              bmi     2$
              cmp     dp:WP_YEND
              bcs     4$
              sta     dp:WP_YEND
4$:           tya
              clc
              adc     dp:WP_YEND
              sta     dp:WP_YEND
              lda     long:(WP_BANK+8),x    ; the entry of c0
              clc
              adc     dp:WP_TMP
              sta     dp:WP_TX
              clv
              clc
              rts
2$:           sep     #0x40                 ; (V: nothing to do)
              clc
              rts
8$:           sec
              rts

;;; wcProf: the clip pass from the profile V_K for the vissprite X. Carry
;;; set: the pass itself (it makes all columns again, the same bytes).
wcProf:       jsr     .kbank wpStart
              bcs     9$
              bvs     8$
              sep     #0x20
1$:           ldx     dp:WP_TX              ; the lowest post of the column
              lda     long:(WP_BANK+1),x
              xba
              lda     long:WP_BANK,x
              tax
              lda     dp:WP_HI
              cmp     long:(WP_BANK+1),x    ; hi > b: it ends above V_HI (and
              bcs     4$                    ;   those above it)
              cmp     long:WP_BANK,x        ; hi > a: it shows and reaches V_HI
              bcc     5$                    ;   (else the posts above it)
2$:           lda     long:(WP_BANK+2),x    ; floorclip = V_YH0 + the a of its
              adc     dp:V_YH0              ;   run + 1 (carry set), lower than
              sta     abs:.near floorclip,y ;   the viewbottom + 1 that
4$:           ldx     dp:WP_TX              ;   R_RenderPlayerView puts in all
              inx                           ;   columns before this pass
              inx
              stx     dp:WP_TX
              iny
              iny
              cpy     dp:WP_YEND
              bcc     1$
              rep     #0x20
8$:           clc
9$:           rts
5$:           inx                           ; the post above
              inx
              inx
              inx
              inx
              lda     long:WP_BANK,x        ; (a + 1 = 0: no more)
              beq     4$
              lda     dp:WP_HI
              cmp     long:(WP_BANK+1),x
              bcs     4$
              cmp     long:WP_BANK,x
              bcs     2$
              bra     5$

;;; wdProf: the records of the weapon from the profile V_K for the vissprite
;;; X, as visPost 11$: the posts with a < hi, rows V_YH0 + a to min(V_YH0 +
;;; b, V_HI), the texture position of the first row the same for all of
;;; them (their first rows are not clipped), a step of 1.0. The posts of a
;;; column go into its list from the lowest up (they do not overlap, so the
;;; picture is the same). Carry set: the old draw.
wdProf:       jsr     .kbank wpStart
              bcc     1$
              rts
1$:           bvc     2$
              clc
              rts
2$:           sty     dp:W_X2
              ldx     dp:WP_VIS
              lda     abs:OFS_VIS_COLORMAP,x ; W_CMP, as R_DrawVisSprite
              sec
              sbc     ##.word0 fullcolormap
              clc
              adc     ##.word0 iigs_shrcmapA
              xba
              sta     dp:W_CMP
              lda     abs:OFS_VIS_GY,x      ; the patch (its bank: R_SRC + 2)
              sta     dp:V_PATCH
              lda     abs:(OFS_VIS_GY+2),x
              and     ##0x00ff
              sta     dp:(V_PATCH+2)
              lda     abs:OFS_VIS_TEXTUREMID,x ; TF, TI: (texturemid >> 7 -
              xba                           ;   (CENTERY + 1) << 9 + (V_YH0 + 1)
              asl     a                     ;   << 9) >> 1, as visPost for a
              lda     abs:(OFS_VIS_TEXTUREMID+1),x ; first row of V_YH0 + 1 +
              rol     a                     ;   topdelta
              sec
              sbc     ##(((CONST_CENTERY + 1) << 9) & 0xffff)
              sta     dp:WP_TMP
              lda     dp:V_YH0
              inc     a
              xba
              and     ##0xff00
              asl     a
              clc
              adc     dp:WP_TMP
              lsr     a
              sta     dp:WP_TF              ; (WP_TI: its high byte)
              lda     dp:V_YH0
              dec     a
              sta     dp:WP_YM1
              phb                           ; DBR: the records
              pea     #(RECBANK * 0x0101)
              plb
              plb
              sep     #0x20
3$:           ldx     dp:WP_TX              ; the lowest post of the column
              lda     long:(WP_BANK+1),x
              xba
              lda     long:WP_BANK,x
              tax
4$:           lda     long:WP_BANK,x        ; a + 1 (0: no more posts)
              bne     42$
              brl     7$
42$:          lda     dp:WP_HI              ; hi <= a: at V_HI or below
              cmp     long:WP_BANK,x
              bcs     43$
              brl     6$
43$:
              lda     long:WP_BANK,x        ; the rows: V_YH0 + a, min(V_YH0 +
              clc                           ;   b, V_HI)
              adc     dp:WP_YM1
              sta     dp:V_YL
              lda     dp:WP_HI
              cmp     long:(WP_BANK+1),x
              lda     dp:V_HI
              bcc     41$
              lda     long:(WP_BANK+1),x
              clc
              adc     dp:WP_YM1
41$:          sta     dp:V_YH1
              lda     long:(WP_BANK+3),x    ; the texels (the low word, no carry
              clc                           ;   into the bank: as visPost)
              adc     dp:V_PATCH
              sta     dp:WP_SRC
              lda     long:(WP_BANK+4),x
              adc     dp:(V_PATCH+1)
              sta     dp:(WP_SRC+1)
              stx     dp:WP_PP
              ldx     dp:W_X2               ; the fill spans of the column end
              FSCUT   dp:V_YL, dp:V_YH1     ;   at the post (lists.inc)
              lda     long:(COLW+1),x       ; Y = the free byte of the list
              xba
              lda     long:COLW,x
              tay
              cmp     #(PAGE_ROOM - TEX_SIZE + 1) ; no room in the page: an
              bcc     5$                    ;   extra page first
              brl     8$
5$:           adc     #TEX_SIZE             ; (carry clear)
              sta     long:COLW,x
              WCVSET  dp:V_YL, dp:V_YH1     ; (B: the page, from the COLW loads)
              lda     #K_TEX
              sta     abs:R_KIND,y
              lda     dp:V_YL
              sta     abs:R_ROW,y
              lda     dp:V_YH1
              sta     abs:R_END,y
              lda     dp:WP_TF
              sta     abs:R_TF,y
              lda     dp:WP_TI
              sta     abs:R_TI,y
              lda     #0                    ; the step: 1.0 (fracstep >> 1)
              sta     abs:R_SF,y
              lda     #1
              sta     abs:R_SI,y
              lda     dp:WP_SRC
              sta     abs:R_SRC,y
              lda     dp:(WP_SRC+1)
              sta     abs:(R_SRC+1),y
              lda     dp:(V_PATCH+2)
              sta     abs:(R_SRC+2),y
              lda     dp:W_CMP
              sta     abs:R_CMP,y
              ldx     dp:WP_PP
6$:           inx                           ; the post above
              inx
              inx
              inx
              inx
              brl     4$
7$:           ldx     dp:WP_TX              ; the next column
              inx
              inx
              stx     dp:WP_TX
              ldy     dp:W_X2
              iny
              iny
              sty     dp:W_X2
              cpy     dp:WP_YEND
              bcs     71$
              brl     3$
71$:          rep     #0x20
              plb
              clc
              rts
8$:           rep     #0x20                 ; an extra page first
              jsl     long:newPage          ; Y = the free byte of the new page
              tya
              sep     #0x20
              clc
              brl     5$

;;; ---------------------------------------------------------------------------
;;; void R_DrawSprite(const vissprite_t* spr)
;;; In: _Dp[0-3] = spr.
;;; Clips the sprite against the drawsegs that are in front of it, then
;;; draws it with R_DrawVisSprite. The clip arrays hold bytes (their high
;;; bytes are 0: src/iigs/segvar.inc), so the loops store the low bytes.
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public R_DrawSprite, SPR_TOPINIT, SPR_TOPTEST, SPR_BOTINIT, SPR_BOTTEST
              .public DS_X2
R_DrawSprite: lda     dp:.tiny _Dp          ; DS_SPR = spr (a long pointer;
              sta     dp:.tiny DS_SPR       ;   16-bit stores, one SEP below:
              lda     dp:.tiny (_Dp+2)      ;   DS_SPR+3 is DS_X, set before a
              sta     dp:.tiny (DS_SPR+2)   ;   read)
              ldy     ##(OFS_VIS_GZ+2)      ; the high word of the top of the
              lda     [.tiny DS_SPR],y      ;   sprite: gz + (topoffset << 16)
              ldy     ##OFS_VIS_TOPOFFSET
              clc
              adc     [.tiny DS_SPR],y
              sta     .near (DS_GZT+2)
              ldy     ##OFS_VIS_X2          ; x2, x1 (their high bytes 0), also
              lda     [.tiny DS_SPR],y      ;   into the compares of dsLoop;
              sta     .near DS_X2           ;   clipbot[x] = viewbottom, cliptop[x]
              inc     a                     ;   = viewtop for x1..x2
              asl     a
              sta     dp:.tiny DS_R2
              ldy     ##OFS_VIS_X1
              lda     [.tiny DS_SPR],y
              sta     .near DS_X1
              asl     a
              tax
              lda     ##0                   ; (B = 0 for the scan below)
              sep     #0x20
              lda     .near DS_X1
              sta     long:DS_X1I
              lda     .near DS_X2
              inc     a
              sta     long:DS_X2P1
              cpx     dp:.tiny DS_R2
              bcs     20$
10$:          lda     #CONST_VIEWHEIGHT     ; viewbottom + 1, set by R_RenderPlayerView
SPR_BOTINIT   .equ    . - 1
              sta     abs:.near floorclip,x
              lda     #0                    ; viewtop + 1, set by R_RenderPlayerView
SPR_TOPINIT   .equ    . - 1
              sta     abs:.near ceilingclip,x
              inx
              inx
              cpx     dp:.tiny DS_R2
              bcc     10$

              ;; scan the drawsegs from the last one to the first, with
              ;; their column bytes (dsX1 is 255 for a drawseg that neither
              ;; clips sprites nor has a masked texture): 8-bit A, X = the
              ;; index; DS_I and DS_T are bytes with a high byte of 0. The
              ;; address below takes B from dsNext: 0 but after a top
              ;; silhouette that does not clip (as before)
20$:          lda     long:dsCount
              sta     dp:.tiny DS_I
              stz     dp:.tiny (DS_I+1)
              ldx     dp:.tiny DS_I         ; (X: 16-bit; A stays 8-bit)
              bra     dsLoop
              .space  21                    ; (dsLoop keeps its address)
dsNext:       ldx     dp:.tiny DS_I
              sep     #0x20
dsLoop:       dex
              bpl     22$
              brl     dsEnd
22$:          lda     long:dsX1,x           ; ds->x1 >= spr->x2 + 1
              cmp     #0                    ; (spr->x2 + 1, set above)
DS_X2P1       .equ    . - 1
              bcs     dsLoop
              lda     long:dsX2,x           ; ds->x2 < spr->x1
              cmp     #0                    ; (spr->x1, set above)
DS_X1I        .equ    . - 1
              bcc     dsLoop
              txa                           ; the drawseg covers the sprite:
              sta     dp:.tiny DS_I         ;   the index (a byte)
              lda     long:dsX1,x           ; r1 = max(ds->x1, spr->x1): the
              cmp     .near DS_X1           ;   bytes of dsX1, dsX2 (a drawseg
              bcs     31$                   ;   that clips); the high byte of
              lda     .near DS_X1           ;   DS_R1 stays 0
31$:          sta     dp:.tiny DS_R1
              lda     long:dsX2,x           ; r2 = min(ds->x2, spr->x2)
              cmp     .near DS_X2
              bcc     32$
              lda     .near DS_X2
32$:          inc     a                     ; DS_R2 = (r2 + 1) * 2
              rep     #0x20
              and     ##0x00ff
              asl     a
              sta     dp:.tiny DS_R2
              txa                           ; X = the drawseg (DSADDR)
              asl     a
              tax
              lda     long:DSADDR,x
              sta     dp:.tiny DS_X
              tax

              ;; max(scale1, scale2) < spr->scale: the seg is behind the
              ;; sprite; else min(scale1, scale2) < spr->scale: behind if
              ;; !R_PointOnSegSide(spr->gx, spr->gy, ds->curline)
              ldy     ##OFS_VIS_SCALE       ; scale1 < spr->scale ?
              lda     abs:OFS_DS_SCALE1,x
              cmp     [.tiny DS_SPR],y
              iny
              iny
              lda     abs:(OFS_DS_SCALE1+2),x
              sbc     [.tiny DS_SPR],y
              bvc     33$
              eor     ##0x8000
33$:          bpl     35$
              jsr     .kbank ltScale2       ; yes: and scale2 < spr->scale?
              bmi     behind
              bra     side
35$:          jsr     .kbank ltScale2       ; no: scale2 < spr->scale?
              bpl     clipIt
side:         lda     abs:OFS_DS_CURLINE,x  ; R_PointOnSegSide(thing->x, thing->y,
              sep     #0x20                 ;   curline): vis->gx holds the thing
              sta     dp:.tiny (_Dp+4)      ;   (a long pointer: R_ProjectSprite
              xba                           ;   of src/iigs/r_thing65.s), MC_PTR
              sta     dp:.tiny (_Dp+5)      ;   the thing here (clipPtr sets it
              lda     abs:(OFS_DS_CURLINE+2),x ;   again below)
              sta     dp:.tiny (_Dp+6)
              ldy     ##(OFS_VIS_GX+2)
              lda     [.tiny DS_SPR],y
              sta     dp:.tiny (MC_PTR+2)
              rep     #0x20
              ldy     ##OFS_VIS_GX
              lda     [.tiny DS_SPR],y
              sta     dp:.tiny MC_PTR
              ldy     ##OFS_MO_Y            ; _Dp[0-3] = thing->y
              lda     [.tiny MC_PTR],y
              sta     dp:.tiny _Dp
              iny
              iny
              lda     [.tiny MC_PTR],y
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_MO_X+2)        ; X:C = thing->x
              lda     [.tiny MC_PTR],y
              tax
              ldy     ##OFS_MO_X
              lda     [.tiny MC_PTR],y
              jsl     long:R_PointOnSegSide
              ldx     dp:.tiny DS_X
              and     ##0xff                ; boolean is one byte
              bne     clipIt

behind:       lda     abs:OFS_DS_MASKEDTEXTURECOL,x
              ora     abs:(OFS_DS_MASKEDTEXTURECOL+2),x
              bne     40$
              jmp     .kbank dsNext
40$:          sep     #0x20                 ; R_RenderMaskedSegRange(ds, r1, r2)
              txa                           ;   (it reads the near address of ds)
              sta     dp:.tiny _Dp
              lda     dp:.tiny (DS_X+1)
              sta     dp:.tiny (_Dp+1)
              rep     #0x20
              lda     dp:.tiny DS_R2
              lsr     a
              dec     a
              sep     #0x20
              sta     dp:.tiny (_Dp+4)
              xba
              sta     dp:.tiny (_Dp+5)
              rep     #0x20
              lda     dp:.tiny DS_R1
              jsl     long:R_RenderMaskedSegRange
              jmp     .kbank dsNext

              ;; bottom silhouette: ds->silhouette & SIL_BOTTOM && spr->gz < ds->bsilheight
clipIt:       lda     abs:OFS_DS_SILHOUETTE,x
              and     ##SIL_BOTTOM
              beq     60$
              ldy     ##OFS_VIS_GZ
              lda     [.tiny DS_SPR],y
              cmp     abs:OFS_DS_BSILHEIGHT,x
              iny
              iny
              lda     [.tiny DS_SPR],y
              sbc     abs:(OFS_DS_BSILHEIGHT+2),x
              bvc     50$
              eor     ##0x8000
50$:          bpl     60$
              lda     abs:OFS_DS_SPRBOTTOMCLIP,x
              ldy     abs:(OFS_DS_SPRBOTTOMCLIP+2),x
              jsr     .kbank clipPtr
51$:          lda     abs:.near floorclip,y
              cmp     #CONST_VIEWHEIGHT     ; not set yet: viewbottom + 1, set by
SPR_BOTTEST   .equ    . - 1                 ;   R_RenderPlayerView
              bne     52$
              lda     [.tiny MC_PTR],y
              sta     abs:.near floorclip,y
52$:          iny
              iny
              cpy     dp:.tiny DS_R2
              bcc     51$
              rep     #0x20

              ;; top silhouette: ds->silhouette & SIL_TOP && gzt > ds->tsilheight
60$:          ldx     dp:.tiny DS_X
              lda     abs:OFS_DS_SILHOUETTE,x
              and     ##SIL_TOP
              beq     70$
              ldy     ##OFS_VIS_GZ          ; (the low word of gzt is the one of gz)
              lda     abs:OFS_DS_TSILHEIGHT,x
              cmp     [.tiny DS_SPR],y
              lda     abs:(OFS_DS_TSILHEIGHT+2),x
              sbc     .near (DS_GZT+2)
              bvc     61$
              eor     ##0x8000
61$:          bpl     70$
              lda     abs:OFS_DS_SPRTOPCLIP,x
              ldy     abs:(OFS_DS_SPRTOPCLIP+2),x
              jsr     .kbank clipPtr
62$:          lda     abs:.near ceilingclip,y
              cmp     #0xff                 ; not set yet: viewtop + 1, set by
SPR_TOPTEST   .equ    . - 1                 ;   R_RenderPlayerView
              bne     63$
              lda     [.tiny MC_PTR],y
              sta     abs:.near ceilingclip,y
63$:          iny
              iny
              cpy     dp:.tiny DS_R2
              bcc     62$
              rep     #0x20
70$:          jmp     .kbank dsNext

              ;; all clipping has been performed, so draw the sprite:
              ;; mfloorclip = floorclip, mceilingclip = ceilingclip (the
              ;; banks stay: every clip array is in the near bank, and
              ;; psSetup of src/iigs/r_frame65.s sets them first), _Dp = spr
dsEnd:        jmp     long:dsVisible
              .space  1                     ; dsDraw resumes at the store
              sta     .near mfloorclip
              lda     ##.word0 ceilingclip
              sta     .near mceilingclip
              lda     dp:.tiny DS_SPR       ; (16-bit: _Dp+3 takes DS_SPR+3,
              sta     dp:.tiny _Dp          ;   not read)
              lda     dp:.tiny (DS_SPR+2)
              sta     dp:.tiny (_Dp+2)
              jmp     long:R_DrawVisSprite
              .space  DS_PADN               ; (the code after it keeps its place)

;;; ltScale2: N = ds->scale2 < spr->scale, for the drawseg at X.
ltScale2:     ldy     ##OFS_VIS_SCALE
              lda     abs:OFS_DS_SCALE2,x
              cmp     [.tiny DS_SPR],y
              iny
              iny
              lda     abs:(OFS_DS_SCALE2+2),x
              sbc     [.tiny DS_SPR],y
              bvc     1$
              eor     ##0x8000
1$:           rts

;;; clipPtr: MC_PTR = Y:C (a far pointer: 3 bytes), Y = 2 * r1, 8-bit A
;;; and B = 0.
clipPtr:      sta     dp:.tiny MC_PTR       ; (16-bit stores: MC_PTR+3 is MC_CP,
              tya                           ;   set before its use)
              sta     dp:.tiny (MC_PTR+2)
              lda     dp:.tiny DS_R1
              asl     a
              tay
              lda     ##0
              sep     #0x20
              rts
              .space  7                     ; (R_DrawMaskedColumn keeps its address)

;;; ---------------------------------------------------------------------------
;;; The shadow drawer: each pixel becomes the darkened pixel of the row
;;; above or below it, in the fuzz order of fuzzoffset (the same sequence as
;;; vanilla Doom). A shadow post is a K_FUZZ record (src/iigs/r_list65.s)
;;; with its fuzz position (visColF); fuzzColumn draws it with fuzzBlock of
;;; tools/gendraw.py. The darken table is in bank 1 with the back buffer,
;;; see src/iigs/iigs.scm.
;;; ---------------------------------------------------------------------------
              .section znear, bss
FZ_POS:       .space  2               ; position in the fuzz table

              .section farcode, text
              .public fuzzColumn
              .space  70                    ; (the old R_DrawFuzzColumn:
                                            ;   fuzzColumn keeps its address)

;;; fuzzColumn: the rows DC_ROW .. DC_ROW + DC_COUNT - 1 of column DC_COLX
;;; from fuzz position C: the row of fuzzBlock with the direction of this
;;; position, v = yl + q, q = (pos - yl) mod 50.
fuzzColumn:   sec
              sbc     dp:.tiny DC_ROW
              clc
              adc     ##200
              tax
              lda     long:fuzzMod50,x
              and     ##0x00ff
              pha                           ; q
              clc
              adc     dp:.tiny DC_ROW
              asl     a
              tax
              lda     long:fuzzEntry,x
              sta     dp:.tiny DC_ENTRY
              txa
              clc
              adc     dp:.tiny DC_COUNT
              adc     dp:.tiny DC_COUNT
              tax
              lda     long:fuzzEntry,x
              sta     dp:.tiny DC_EXITP
              lda     ##.word2 fuzzBlock
              sta     dp:.tiny (DC_ENTRY+2)
              sta     dp:.tiny (DC_EXITP+2)
              pla                           ; X = x + (49 - q) * 160
              asl     a
              tax
              lda     long:fuzzQ160,x
              clc
              adc     dp:.tiny DC_COLX
              tax

              phb
              lda     ##0                   ; B = 0 for TAY in 8-bit mode
              sep     #0x20
              lda     [.tiny DC_EXITP]      ; RTL after the last row
              sta     dp:.tiny DC_SAVEB
              lda     #0x6b
              sta     [.tiny DC_EXITP]
              lda     #BUF_BANK
              pha
              plb
              jsl     long:fzDispatch
              lda     dp:.tiny DC_SAVEB
              sta     [.tiny DC_EXITP]
              rep     #0x20
              plb
              rtl

fzDispatch:   .byte   0xdc                  ; jml [DC_ENTRY]
              .word   .word0 DC_ENTRY

;;; ---------------------------------------------------------------------------
;;; dsaInit: DSADDR[i] = the near address of drawsegs[i] (src/iigs/dscols.inc),
;;; once (frameInit of src/iigs/r_thing65.s, on the first frame).
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public dsaInit
dsaInit:      ldx     ##0
              lda     ##.near _s_drawsegs
1$:           sta     long:DSADDR,x
              clc
              adc     ##SIZEOF_DS
              inx
              inx
              cpx     ##(2 * CONST_MAXDRAWSEGS)
              bcc     1$
              rtl
