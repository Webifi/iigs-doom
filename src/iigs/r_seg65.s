;;; Wall column loop and sprite posts in 65816 assembly, Doom8088: Apple
;;; IIgs Edition.
;;;
;;; R_RenderSegLoop, R_DrawSegTextureColumn and R_DrawVisSprite of
;;; r_draw.c. Walls, floors, ceilings and sprite posts become records in
;;; the column lists of src/iigs/r_list65.s, which
;;; R_DrawLists draws at the end of the frame. The loop runs with its own
;;; direct page (WPAGE) and with the bank of the records as the data bank.
;;; Near data is read with long addresses.
;;;
;;; A seg gets one of the loops of src/iigs/segvar.inc, made for its tiers
;;; and plane marks. Masked and sky segs, and columns with a negative floor
;;; clip, go through genColumn, which does all cases as the C code.
;;;
;;; The state of the steps: topfrac holds FRACUNIT - 1 more (so its high
;;; word is yl), bottomfrac and pixhigh FRACUNIT more (yh + 1, mid + 1),
;;; pixlow FRACUNIT - 1 more, and each starts one step early.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"
#include "lists.inc"

              .extern _Dp, _DirectPageStart, _NearBaseAddress
              .extern R_DrawColumnFlat, R_DrawSky
              .extern R_MakeTextureColumns, R_WallLight
              .extern LT_I, LT_FIXED, SMAP
              .extern newPage, COLW
              .extern floorclip, ceilingclip, solidcol, didsolidcol
              .extern rw_stopx, rw_scale, rw_scalestep, ds_p, rw_normalangle
              .extern ceilingplane_color, floorplane_color
              .extern rw_offset, rw_centerangle, rw_distance, rw_lightlevel
              .extern midtexture, toptexture, bottomtexture
              .extern rw_midtexturemid, rw_toptexturemid, rw_bottomtexturemid
              .extern maskedtexture, maskedtexturecol
              .extern xtoviewangleTable
              .extern fullcolormap, iigs_shrcmapA, iigs_shrcmapB
              .extern viewangle, fixedcolormap, skypatch, skywidthmask
              .extern DC_SRC, DC_ROW, DC_COUNT, DC_FSTEP, DC_FRAC, DC_FLATW
              .extern spryscale, sprtopscreen, mfloorclip, mceilingclip
              .extern W_GetLumpByNum, FixedMul
              .extern MA, qmul, BSPDP
VS_HL         .equ    (BSPDP+32)      ; R_DrawVisSprite: hi16(TL * SL), or vis
                                      ;   (MC_CP + 2 of src/iigs/r_sprite65.s,
                                      ;   which columnSetup sets before a read)

COLDIR        .equ    MM_COLDIR       ; COLDIR_ADDR of r_draw.c
RECIP_TABLE   .equ    MM_RECIP        ; see src/iigs/m_recip65.s
FSTEP_TABLE   .equ    MM_FSTEP        ; see IIGS_InitFstep, src/iigs/m_recip65.s
SKY_COLOR     .equ    0xfffe          ; ceilingplane_color of a sky ceiling (-2)
CMAP_B        .equ    34              ; iigs_shrcmapB - iigs_shrcmapA, in pages
                                      ; (R_CheckSegPage)

#include "wpage.inc"
#include "mul.inc"

SKYFRACSTEP   .equ    512             ; FRACUNIT >> COLEXTRABITS, r_sky.c
SKYTMID7      .equ    100 << 9        ; texturemid (100 << FRACBITS) >> 7
SL_PADN       .equ    46              ; the pad after the entry of R_RenderSegLoop

              .extern iigs_mulT
              .extern T_COLB
MULT0         .equ    iigs_mulT + 510 ; T[0] of src/iigs/mul.inc
SQL           .equ    MM_SQL          ; the quarter squares of src/iigs/m_fixed65.s
SQH           .equ    MM_SQH

              .section zfar, bss
              .public YHTABM
YHTABM:       .space  (1 + 512) * 2   ; the high word of E - 1 before row 0, then
YHTAB         .equ    YHTABM + 2      ;   (E - 1) >> FRACBITS of texel row t

              .section znear, bss
VS_CM:        .space  4               ; the fields of the vissprite
VS_FSTEP:     .space  2
VS_TMID:      .space  4
VS_FRAC0:     .space  4
VS_XIS0:      .space  4
VS_X1:        .space  2
VS_PATCHP:    .space  4
              .extern wclipSprite
              .public VS_CLIP
VS_CLIP:      .space  2               ; not 0: R_DrawVisSprite only clips the
                                      ; floor of the columns to the weapon
SL_DCV:       .space  SIZEOF_DC       ; dcvars
SL_X0:        .space  2               ; rw_x

;;; N = (A < operand), signed 16-bit. Destroys A.
SLT           .macro  op
              sec
              sbc     \op
              bvc     1$
              eor     ##0x8000
1$:
              .endm

;;; DLIGHT: C = d = min(23, rw_scale >> 13), the distance steps of the
;;; light of a wall column (Doom: scalelight[rw_scale >> 12] at half the
;;; horizontal resolution), from C = rw_scale >> 8 (bits 8..23): C >> 5,
;;; as the high byte of C << 3. 16-bit A.
DLIGHT        .macro
              cmp     ##(24 << 5)
              bcc     1$
              lda     ##(23 << 5)
1$:           asl     a
              asl     a
              asl     a
              xba
              and     ##0x00ff
              .endm

;;; A 32-bit step: \v += \s, C = the new high word.
STEP32        .macro  v, s
              clc
              lda     dp:\v
              adc     dp:\s
              sta     dp:\v
              lda     dp:(\v+2)
              adc     dp:(\s+2)
              sta     dp:(\v+2)
              .endm

;;; STEP8F v, s: the 32-bit step \v += \s, one byte at a time; A = the top
;;; byte of the high word.
STEP8F        .macro  v, s
              clc
              lda     dp:\v
              adc     dp:\s
              sta     dp:\v
              lda     dp:(\v+1)
              adc     dp:(\s+1)
              sta     dp:(\v+1)
              lda     dp:(\v+2)
              adc     dp:(\s+2)
              sta     dp:(\v+2)
              lda     dp:(\v+3)
              adc     dp:(\s+3)
              sta     dp:(\v+3)
              .endm

;;; STEP8 v, s: the 24-bit scale step \v += \s, one byte at a time; A = byte 2; byte 3 stays zero.
;;; Every consumed wall scale is 1/256..64. All 16 fractional bits remain.
STEP8         .macro  v, s
              clc
              lda     dp:\v
              adc     dp:\s
              sta     dp:\v
              lda     dp:(\v+1)
              adc     dp:(\s+1)
              sta     dp:(\v+1)
              lda     dp:(\v+2)
              adc     dp:(\s+2)
              sta     dp:(\v+2)
              .endm

;;; 24-bit scale step in the 16-bit generic/masked loops. No consumer
;;; uses A afterward; the accumulator width returns to 16 bits.
STEP24W       .macro  v, s
              clc
              lda     dp:\v
              adc     dp:\s
              sta     dp:\v
              sep     #0x20
              lda     dp:(\v+2)
              adc     dp:(\s+2)
              sta     dp:(\v+2)
              rep     #0x20
              .endm

;;; STEP8E v, s: STEP8 without the lowest byte of \v (bits 8..31 only): a
;;; wall edge (16.16 rows) keeps 8 bits of fraction in the loops; its row
;;; can be off by one after many columns (small pixel differences allowed
;;; for speed, 2026-09-25). A = the top byte of the high word.
STEP8E        .macro  v, s
              clc
              lda     dp:(\v+1)
              adc     dp:(\s+1)
              sta     dp:(\v+1)
              lda     dp:(\v+2)
              adc     dp:(\s+2)
              sta     dp:(\v+2)
              lda     dp:(\v+3)
              adc     dp:(\s+3)
              sta     dp:(\v+3)
              .endm

;;; C = bits 16..31 of \a * \b (unsigned), as umul16 of src/iigs/m_fixed65.s:
;;; a * b = sq(a + b) - sq(|a - b|). The low word of sq(a + b) stays in Y,
;;; its high word is the one store (W_MH). Destroys X, Y.
MULHI16       .macro  a, b
              lda     dp:\a
              clc
              adc     dp:\b
              bcs     20$
              asl     a
              tax
              bcs     10$
              lda     long:SQL,x
              tay
              lda     long:SQH,x
              bra     50$
10$:          lda     long:(SQL+0x10000),x
              tay
              lda     long:(SQH+0x10000),x
              bra     50$
20$:          asl     a
              tax
              bcs     30$
              lda     long:(SQL+0x20000),x
              tay
              lda     long:(SQH+0x20000),x
              bra     50$
30$:          lda     long:(SQL+0x30000),x
              tay
              lda     long:(SQH+0x30000),x
50$:          sta     dp:W_MH
              lda     dp:\a
              sec
              sbc     dp:\b
              bcs     60$
              eor     ##0xffff
              inc     a
60$:          asl     a
              tax
              tya
              bcs     70$
              sec
              sbc     long:SQL,x
              lda     dp:W_MH
              sbc     long:SQH,x
              bra     80$
70$:          sec
              sbc     long:(SQL+0x10000),x
              lda     dp:W_MH
              sbc     long:(SQH+0x10000),x
80$:
              .endm

;;; C = bits 0..15 of \a * \b, as umul16lo, with no store. Destroys X, Y.
MULLO16       .macro  a, b
              lda     dp:\a
              clc
              adc     dp:\b
              bcs     20$
              asl     a
              tax
              bcs     10$
              lda     long:SQL,x
              bra     50$
10$:          lda     long:(SQL+0x10000),x
              bra     50$
20$:          asl     a
              tax
              bcs     30$
              lda     long:(SQL+0x20000),x
              bra     50$
30$:          lda     long:(SQL+0x30000),x
50$:          tay
              lda     dp:\a
              sec
              sbc     dp:\b
              bcs     60$
              eor     ##0xffff
              inc     a
60$:          asl     a
              tax
              tya
              bcs     70$
              sec
              sbc     long:SQL,x
              bra     80$
70$:          sec
              sbc     long:(SQL+0x10000),x
80$:
              .endm

;;; The direct page and data bank of the C code, for a call. Destroys C.
CENV          .macro
              phb
              phd
              lda     ##.word0 _DirectPageStart
              tcd
              lda     ##.word2 _NearBaseAddress
              xba
              pha
              plb
              plb
              .endm

;;; Back to the loop after CENV.
WENV          .macro
              pld
              plb
              .endm

;;; Point _Dp[0-3] at SL_DCV (the direct page of the C code).
DCVARG        .macro
              lda     ##.word0 SL_DCV
              sta     dp:.tiny _Dp
              lda     ##.word2 SL_DCV
              sta     dp:.tiny (_Dp+2)
              .endm

;;; A tier with a texture: \dir = COLDIR[texture], \wm = its widthmask,
;;; \tm = texturemid >> 7 of the fixed_t \mid (bits 7..22). A texture
;;; without columns (one made in play) gets them first: tierMake.
TIERDIR       .macro  tex, dir, wm, tm, mid
              lda     dp:\tex
              beq     1$
              asl     a
              asl     a
              tax
              lda     long:(COLDIR+2),x     ; bank | widthmask << 8, 0: none
              bne     2$
              jsr     .kbank tierMake
2$:           sta     dp:(\dir+2)
              xba
              and     ##0x00ff
              sta     dp:\wm
              lda     long:COLDIR,x
              sta     dp:\dir
              lda     .near \mid           ; C = bit 7 of byte 0
              xba
              asl     a
              lda     .near (\mid+1)       ; bytes 1..2, shifted in
              rol     a
              sta     dp:\tm
1$:
              .endm

;;; ---------------------------------------------------------------------------
;;; void R_RenderSegLoop(int16_t rw_x, boolean segtextured, boolean markfloor,
;;;                      boolean markceiling)
;;; In: C = rw_x, _Dp[0-1] = segtextured, _Dp[4-5] = markfloor,
;;; markceiling on the stack.
;;; ---------------------------------------------------------------------------
              .section segcode, text     ; (cache slots $2000-, src/iigs/iigs.scm)
              .public R_RenderSegLoop
R_RenderSegLoop:
SH_P1         .equ    .                     ; (the half view: JSR halfStart)
              cmp     .near rw_stopx        ; 0 <= rw_x, rw_stopx <= SCREENWIDTH
              bcc     1$
              rtl
1$:           sta     .near SL_X0           ; (R_StoreWallRange sets the other
                                            ;   inputs in the loop page)
              phd                           ; the direct page of the loop
              lda     ##WPAGE
              tcd
              ;; Plane-only spans need no wall scale, texture directory or
              ;; wall-light setup. Sky establishes its own record inputs.
              lda     dp:W_SEGTEX
              bne     90$
              brl     80$
90$:
              ldy     .near rw_normalangle  ; sector light and fake contrast
              lda     .near rw_lightlevel
              jsl     long:R_WallLight      ; fixed effect, or a placeholder
              clc
              adc     ##.word0 iigs_shrcmapA
              xba                           ; (16-bit store: W_CMP + 1 is not
              sta     dp:W_CMP              ;   read)
              lda     .near rw_scale        ; rw_scale - rw_scalestep
              sec
              sbc     .near rw_scalestep
              sta     dp:W_SC
              lda     .near (rw_scale+2)
              sbc     .near (rw_scalestep+2)
              sta     dp:(W_SC+2)
              lda     .near rw_scalestep
              sta     dp:W_SCS
              lda     .near (rw_scalestep+2)
              sta     dp:(W_SCS+2)

              ;; the texture columns and the tiers
              lda     .near rw_distance
              sta     dp:W_DIST
              lda     ##0xffff
              sta     dp:W_TCX
              TIERDIR W_MIDTEX, W_MDIR, W_MWM, W_MTM, rw_midtexturemid
              TIERDIR W_TOPTEX, W_TDIR, W_TWM, W_TTM, rw_toptexturemid
              TIERDIR W_BOTTEX, W_BDIR, W_BWM, W_BTM, rw_bottomtexturemid

              lda     dp:W_MASKED           ; the masked texture columns
              beq     23$
              lda     .near maskedtexturecol
              sta     dp:W_MASKP
              lda     .near (maskedtexturecol+2)
              sta     dp:(W_MASKP+2)
23$:
              ;; the light of the wall columns, Doom's: the colormap startmap
              ;; - d, d = min(23, rw_scale >> 13) of each column (DLIGHT; PGT
              ;; does the clamps). The scale steps from scale1 to scale2 of
              ;; the drawseg: the same d at both ends is the d of all columns,
              ;; one page W_CMP; else texRec lights each record (W_LV). A
              ;; fixed colormap keeps W_CMP. (W_LV written once: each write
              ;; holds the bus.)
              lda     .near LT_FIXED
              bpl     28$
              lda     .near LT_I            ; Y = startmap + 24
              asl     a
              tax
              lda     long:SMAP,x
              tay
              ldx     .near ds_p            ; d at the ends of the drawseg
              lda     abs:(OFS_DS_SCALE1+1),x
              DLIGHT
              sta     dp:W_T
              lda     abs:(OFS_DS_SCALE2+1),x
              DLIGHT
              cmp     dp:W_T
              beq     27$
              jsl     long:c26LightSetup    ; varying light: bias the lookup once
              bra     80$
27$:          tya                           ; one light: W_CMP = PGT[startmap
              sec                           ;   + 24 - d], W_LV = 0
              sbc     dp:W_T
              tax
              lda     long:PGT,x            ; (16-bit: no REP/SEP)
              sta     dp:W_CMP
28$:          ldy     ##0
29$:          sty     dp:W_LV

80$:          stz     dp:W_SKY
              lda     dp:W_MC
              beq     2$
              lda     .near ceilingplane_color
              cmp     ##SKY_COLOR
              bne     2$
              sta     dp:W_SKY

2$:
              ;; the fill bytes of the ceiling and the floor (for another
              ;; color than the seg before in this frame), the masked
              ;; texture columns
              lda     .near ceilingplane_color
              cmp     dp:W_LCC
              beq     21$
              sta     dp:W_LCC
              jsr     .kbank fillBytes
              sta     dp:W_CEILW
21$:          lda     .near floorplane_color
              cmp     dp:W_LFC
              beq     22$
              sta     dp:W_LFC
              jsr     .kbank fillBytes
              sta     dp:W_FLOORW
22$:          stz     dp:W_DIDSOLID

              lda     .near rw_stopx
              asl     a
              sta     dp:W_X2END
SH_P2         .equ    .                     ; (the half view: JSR halfSeg)
              lda     .near SL_X0
              asl     a
              sta     dp:W_X2
              ;; The view preparation above may extrapolate a signed scale
              ;; before the first column. Keep its low 24 bits; every actual
              ;; wall-column scale is positive and at most 64.0.
              sep     #0x20
              stz     dp:(W_SC+3)
              rep     #0x20

              ;; the loop of the seg: two sided lines 1 top | 2 bottom |
              ;; 4 markceiling | 8 markfloor, single sided 16 | the marks
              lda     dp:W_MASKED           ; (a sky ceiling takes the loops
              beq     3$                    ;   of its kind: ceilFill)
              lda     dp:W_MC               ; masked, no wall and no marks:
              ora     dp:W_MF               ;   vMask, else genLoop
              ora     dp:W_TOPTEX
              ora     dp:W_BOTTEX
              bne     31$
              lda     ##66
              bra     9$
31$:          lda     ##64
              bra     9$
3$:           lda     ##0
              ldy     dp:W_MF
              beq     4$
              ora     ##8
4$:           ldy     dp:W_MC
              beq     5$
              ora     ##4
5$:           ldy     dp:W_MIDTEX
              beq     6$
              ora     ##16
              bra     8$
6$:           ldy     dp:W_BOTTEX
              beq     7$
              ora     ##2
7$:           ldy     dp:W_TOPTEX
              beq     8$
              ora     ##1
8$:           asl     a
9$:           tax                           ; X = 2 * the loop
c17Hook       .equ    .
              jsl     long:c17Setup         ; full view: one continuation per seg

              phb                           ; the data bank of the records (PEA
              pea     #(RECBANK * 0x0101)   ;   and two PLB: no REP/SEP)
              plb
              plb
SH_VT         .equ    . + 1                 ; (the half view: varTabH)
              jmp     (.kbank varTab,x)
;;; tierMake (TIERDIR): the columns of texture X / 4 (X kept), made in the C
;;; code environment; A = its COLDIR + 2.
tierMake:     phx
              CENV
              lda     4,s
              lsr     a
              lsr     a
              jsl     long:needColumns
              WENV
              plx
              lda     long:(COLDIR+2),x
              rts
;;; A closed column takes genColumn, whose texCol must return normally.
;;; This fallback is patched into eligible full-view loops only. The outer
;;; loop supplies its original JSR return; genColumn preserves X and DP/DB.
c17Slow:      sep     #0x20
              lda     #0x60
              sta     long:c17Return
              rep     #0x20
              jsr     .kbank genColumn
              sep     #0x20
              lda     #0x4c
              sta     long:c17Return
              rep     #0x20
              rts
              .space  SL_PADN - 6 - 4 - 24 - 2 - 6 ; C26 varying-light setup

;;; After the loop: the solid columns of a single sided line, the flag
;;; for R_StoreWallRange, and back to the direct page and data bank of
;;; the caller.
segDone:      lda     dp:W_MIDTEX
              beq     2$
              lda     dp:W_MC
              ora     dp:W_MF
              beq     2$
              lda     long:SL_X0            ; solidcol[rw_x..rw_stopx-1] = 1
              tax
              lda     dp:W_X2END
              lsr     a
              sta     dp:W_T
              sep     #0x20
              lda     #1
              sta     dp:W_DIDSOLID
1$:           sta     long:solidcol,x
              inx
              cpx     dp:W_T
              bcc     1$
              rep     #0x20
2$:           lda     dp:W_DIDSOLID
              and     ##0x00ff
              beq     3$
              lda     ##1
              sta     long:didsolidcol
3$:           plb
              pld
              rtl

;;; The loops, by the kind of the seg (2 * it in X at the prologue's JMP).
;;; The kinds that draw few columns (demo3: v01, v03, v09, v11, v16, v24)
;;; take genLoop; v02 and v07 are in segmore.
varTab:       .word   .word0 segDone                               ; two sided: nothing to do
              .word   .word0 genLoop, .word0 v02entry, .word0 genLoop, .word0 v04entry
              .word   .word0 v05entry, .word0 v06entry, .word0 v07entry, .word0 v08entry
              .word   .word0 genLoop, .word0 v10entry, .word0 genLoop, .word0 v12entry
              .word   .word0 v13entry, .word0 v14entry, .word0 v15entry
              .word   .word0 genLoop, .word0 genLoop, .word0 genLoop, .word0 genLoop   ; single sided
              .word   .word0 v20entry, .word0 genLoop, .word0 genLoop, .word0 genLoop
              .word   .word0 genLoop, .word0 genLoop, .word0 genLoop, .word0 genLoop
              .word   .word0 v28entry, .word0 genLoop, .word0 genLoop, .word0 genLoop
              .word   .word0 genLoop                               ; masked
              .word   .word0 vMask                                 ; masked only

;;; vMask: a two sided line with a masked mid texture and nothing else to
;;; draw (no wall, no marks): the texture column of each column for the
;;; masked texture (as genColumn: its clips stay).
vMask:        ldx     dp:W_X2
1$:           STEP24W W_SC, W_SCS           ; rw_scale (texCol)
              jsr     .kbank texCol
              txy                           ; maskedtexturecol[x] = texturecol
              lda     dp:W_TEXCOL
              sta     [W_MASKP],y
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank segDone

;;; The loop for all cases.
genLoop:      ldx     dp:W_X2
1$:           jsr     .kbank genColumn
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank segDone

;;; The loops of src/iigs/segvar.inc.
#define CAT2(a, b) a ## b
#define CAT(a, b) CAT2(a, b)
#define L(x) CAT(V_NAME, x)
#define V_FAR 0

#define V_NAME v04
#define V_ONE 0
#define V_TOP 0
#define V_BOT 0
#define V_MC 1
#define V_MF 0
#include "segvar.inc"
#undef V_NAME
#undef V_ONE
#undef V_TOP
#undef V_BOT
#undef V_MC
#undef V_MF

              .extern O_PAGE2, Q_PAGE2
c5ClipStart:
;;; Small views step between displayed columns. Solid markers cover the
;;; unused columns in the same group, as they do in the half view.
ssStart:      tax
ssUpStart:    lda     long:ssUp3,x
              and     ##255
              tay
              sta     long:(WPAGE+W_XS)
              txa
              sec
              sbc     long:(WPAGE+W_XS)
              sta     long:(WPAGE+W_XS)    ; original start minus aligned start
              tya
              cmp     .near rw_stopx
              bcc     9$
              lda     long:(WPAGE+W_MIDTEX)
              beq     8$
              lda     long:(WPAGE+W_MF)
              ora     long:(WPAGE+W_MC)
              beq     8$
              sep     #0x20
              lda     #1
7$:           cpx     .near rw_stopx
              bcs     6$
              sta     long:solidcol,x
              inx
              bra     7$
6$:           rep     #0x20
8$:           sec
9$:           rts
ssEnd:        phx
              lda     dp:W_X2END
              lsr     a
              tax
ssUpEnd:      lda     long:ssUp3,x
              and     ##255
              plx
              rts
ssX0:         lda     long:SL_X0
              clc
              adc     dp:W_XS
              rts
ssSolid:      phx
              txa
              lsr     a
              tax
              inx
ssUpSolid:    lda     long:ssUp3,x
              and     ##255
              sta     dp:W_T
              dex
              txa
              cmp     long:SL_X0
              bne     2$
              ;; A closed first sample also closes its unused prefix.
              clc
              adc     dp:W_XS
              tax
2$:           sep     #0x20
              lda     #1
1$:           sta     long:solidcol,x
              inx
              cpx     dp:W_T
              bcc     1$
              sta     dp:W_DIDSOLID
              rep     #0x20
              plx
              rts

;;; A retained column advances three or four original columns. Move each
;;; initial value back by stride-1-offset, then multiply its step. Scale
;;; keeps 24 bits; edges keep STEP8E's fractional precision.
ssSeg:        ldx     ##(W_SC-W_TF)
ssSegLoop:    lda     dp:(W_TF+4),x
              cpx     ##(W_SC-W_TF)
              beq     ssStepReady
              and     ##0xff00              ; match STEP8E before multiplying
ssStepReady:  sta     dp:W_T4
              asl     a
              sta     dp:(W_TF+4),x
              lda     dp:(W_TF+6),x
              sta     dp:(W_T4+2)
              rol     a
              sta     dp:(W_TF+6),x
              lda     dp:W_XS
              clc
ssBack:       adc     ##2
              tay
              beq     3$
2$:           lda     dp:W_TF,x
              sec
              sbc     dp:W_T4
              sta     dp:W_TF,x
              lda     dp:(W_TF+2),x
              sbc     dp:(W_T4+2)
              sta     dp:(W_TF+2),x
              dey
              bne     2$
3$:
ssScale:      bra     ssScale3
ssScale4:     asl     dp:(W_TF+4),x
              rol     dp:(W_TF+6),x
              bra     ssScaled
ssScale3:     lda     dp:(W_TF+4),x
              clc
              adc     dp:W_T4
              sta     dp:(W_TF+4),x
              lda     dp:(W_TF+6),x
              adc     dp:(W_T4+2)
              sta     dp:(W_TF+6),x
ssScaled:     txa
              sec
              sbc     ##8
              tax
              bpl     ssSegLoop
              lda     .near SL_X0
              rts
ss02Next4:    inx
              inx
ss02Next3:    inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v02done
1$:           jmp     .kbank v02col
ss04Next4:    inx
              inx
ss04Next3:    inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v04done
1$:           jmp     .kbank v04col
ss05Next4:    inx
              inx
ss05Next3:    inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v05done
1$:           jmp     .kbank v05col
ss06Next4:    inx
              inx
ss06Next3:    inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v06done
1$:           jmp     .kbank v06col
ss07Next4:    inx
              inx
ss07Next3:    inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v07done
1$:           jmp     .kbank v07col
ss08Next4:    inx
              inx
ss08Next3:    inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v08done
1$:           jmp     .kbank v08col
ss10Next4:    inx
              inx
ss10Next3:    inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v10done
1$:           jmp     .kbank v10col
ss12Next4:    inx
              inx
ss12Next3:    inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v12done
1$:           jmp     .kbank v12col
ss13Next4:    inx
              inx
ss13Next3:    inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v13done
1$:           jmp     .kbank v13col
ss14Next4:    inx
              inx
ss14Next3:    inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v14done
1$:           jmp     .kbank v14col
ss15Next4:    inx
              inx
ss15Next3:    inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v15done
1$:           jmp     .kbank v15col
ss20Next4:    inx
              inx
ss20Next3:    inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v20done
1$:           jmp     .kbank v20col
ss28Next4:    inx
              inx
ss28Next3:    inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v28done
1$:           jmp     .kbank v28col
ssMask:       ldx     dp:W_X2
ssMaskLoop:   STEP24W W_SC, W_SCS
              jsr     .kbank texCol
              txy
              lda     dp:W_TEXCOL
              sta     [W_MASKP],y
              txa
              clc
ssMaskStep:   adc     ##6
              tax
              cpx     dp:W_X2END
              bcc     ssMaskLoop
              jmp     .kbank segDone
ssGeneric:    ldx     dp:W_X2
ssGenLoop:    jsr     .kbank genColumn
              txa
              clc
ssGenStep:    adc     ##6
              tax
              cpx     dp:W_X2END
              bcc     ssGenLoop
              jmp     .kbank segDone
ssVarTab:     .word   .word0 segDone                               ; two sided: nothing to do
              .word   .word0 ssGeneric, .word0 v02entry, .word0 ssGeneric
              .word   .word0 v04entry
              .word   .word0 v05entry, .word0 v06entry, .word0 v07entry
              .word   .word0 v08entry
              .word   .word0 ssGeneric, .word0 v10entry, .word0 ssGeneric
              .word   .word0 v12entry
              .word   .word0 v13entry, .word0 v14entry, .word0 v15entry
              .word   .word0 ssGeneric, .word0 ssGeneric, .word0 ssGeneric
              .word   .word0 ssGeneric
              ; single sided
              .word   .word0 v20entry, .word0 ssGeneric, .word0 ssGeneric
              .word   .word0 ssGeneric
              .word   .word0 ssGeneric, .word0 ssGeneric, .word0 ssGeneric
              .word   .word0 ssGeneric
              .word   .word0 v28entry, .word0 ssGeneric, .word0 ssGeneric
              .word   .word0 ssGeneric
              .word   .word0 ssGeneric                               ; masked
              .word   .word0 ssMask
              ; masked only
ssUp3:
              .byte   0, 3, 3, 3, 6, 6, 6, 9, 9, 9, 12, 12, 12, 15, 15, 15
              .byte   18, 18, 18, 21, 21, 21, 24, 24, 24, 27, 27, 27, 30, 30
              .byte   30, 33
              .byte   33, 33, 36, 36, 36, 39, 39, 39, 42, 42, 42, 45, 45, 45
              .byte   48, 48
              .byte   48, 51, 51, 51, 54, 54, 54, 57, 57, 57, 60, 60, 60, 63
              .byte   63, 63
              .byte   66, 66, 66, 69, 69, 69, 72, 72, 72, 75, 75, 75, 78, 78
              .byte   78, 81
              .byte   81, 81, 84, 84, 84, 87, 87, 87, 90, 90, 90, 93, 93, 93
              .byte   96, 96
              .byte   96, 99, 99, 99, 102, 102, 102, 105, 105, 105, 108, 108
              .byte   108, 111, 111, 111
              .byte   114, 114, 114, 117, 117, 117, 120, 120, 120, 123, 123
              .byte   123, 126, 126, 126, 129
              .byte   129, 129, 132, 132, 132, 135, 135, 135, 138, 138, 138
              .byte   141, 141, 141, 144, 144
              .byte   144, 147, 147, 147, 150, 150, 150, 153, 153, 153, 156
              .byte   156, 156, 159, 159, 159
              .byte   160, 160
ssUp4:
              .byte   0, 4, 4, 4, 4, 8, 8, 8, 8, 12, 12, 12, 12, 16, 16, 16
              .byte   16, 20, 20, 20, 20, 24, 24, 24, 24, 28, 28, 28, 28, 32
              .byte   32, 32
              .byte   32, 36, 36, 36, 36, 40, 40, 40, 40, 44, 44, 44, 44, 48
              .byte   48, 48
              .byte   48, 52, 52, 52, 52, 56, 56, 56, 56, 60, 60, 60, 60, 64
              .byte   64, 64
              .byte   64, 68, 68, 68, 68, 72, 72, 72, 72, 76, 76, 76, 76, 80
              .byte   80, 80
              .byte   80, 84, 84, 84, 84, 88, 88, 88, 88, 92, 92, 92, 92, 96
              .byte   96, 96
              .byte   96, 100, 100, 100, 100, 104, 104, 104, 104, 108, 108
              .byte   108, 108, 112, 112, 112
              .byte   112, 116, 116, 116, 116, 120, 120, 120, 120, 124, 124
              .byte   124, 124, 128, 128, 128
              .byte   128, 132, 132, 132, 132, 136, 136, 136, 136, 140, 140
              .byte   140, 140, 144, 144, 144
              .byte   144, 148, 148, 148, 148, 152, 152, 152, 152, 156, 156
              .byte   156, 156, 160, 160, 160
              .byte   160, 160

;;; Only view changes write the dispatch sites; FULL restores their bytes.
ssMode:       php
              rep     #0x30
              lda     ##0
              jsr     .kbank ssPatch
              jsl     long:oneViewMode
              lda     long:VW_SIZE
              cmp     ##VW_ONESIZE
              beq     1$
              cmp     ##VW_QUARTERSIZE
              beq     2$
              brl     9$
1$:           lda     ##.word0 ssUp3
              sta     long:(ssUpStart+1)
              sta     long:(ssUpEnd+1)
              sta     long:(ssUpSolid+1)
              lda     ##2
              sta     long:(ssBack+1)
              lda     ##6
              sta     long:(ssMaskStep+1)
              sta     long:(ssGenStep+1)
              sep     #0x20
              lda     #(ssScale3-ssScale-2)
              sta     long:(ssScale+1)
              rep     #0x20
              lda     ##2
              bra     3$
2$:           lda     ##.word0 ssUp4
              sta     long:(ssUpStart+1)
              sta     long:(ssUpEnd+1)
              sta     long:(ssUpSolid+1)
              lda     ##3
              sta     long:(ssBack+1)
              lda     ##8
              sta     long:(ssMaskStep+1)
              sta     long:(ssGenStep+1)
              sep     #0x20
              lda     #(ssScale4-ssScale-2)
              sta     long:(ssScale+1)
              rep     #0x20
              lda     ##0
3$:           sta     dp:.tiny DC_FRAC
              ldx     ##0
              ldy     ##0
4$:           lda     long:ssNexts,x
              beq     5$
              clc
              adc     dp:.tiny DC_FRAC
              phx
              tyx
              sta     long:(ssLoopSites+8),x
              plx
              inx
              inx
              tya
              clc
              adc     ##11
              tay
              bra     4$
5$:           lda     ##1
              jsr     .kbank ssPatch
9$:           plp
              rtl
ssNexts:
              .word .word0 ss02Next4, .word0 ss04Next4, .word0 ss05Next4
              .word .word0 ss06Next4, .word0 ss07Next4, .word0 ss08Next4
              .word .word0 ss10Next4, .word0 ss12Next4, .word0 ss13Next4
              .word .word0 ss14Next4, .word0 ss15Next4, .word0 ss20Next4
              .word .word0 ss28Next4, 0
;;; Each site has its address, length, original bytes and sparse bytes.
;;; Restore before oneViewMode patches the other sizes.
ssPatch:      asl     a
              asl     a
              clc
              adc     ##3
              sta     dp:.tiny DC_FRAC
              sep     #0x20
              lda     #3
              sta     dp:.tiny ((_Dp+4)+2)
              ldx     ##0
1$:           rep     #0x21
              lda     long:ssSites,x
              beq     9$
              sta     dp:.tiny (_Dp+4)
              txa
              adc     dp:.tiny DC_FRAC
              sta     dp:.tiny (_Dp+8)
              sep     #0x20
              lda     long:(ssSites+2),x
              sta     dp:.tiny ((_Dp+8)+2)
              phx
              ldx     dp:.tiny (_Dp+8)
              ldy     ##0
2$:           lda     long:ssSites,x
              sta     [.tiny (_Dp+4)],y
              inx
              iny
              dec     dp:.tiny ((_Dp+8)+2)
              bne     2$
              plx
              rep     #0x21
              txa
              adc     ##11
              tax
              bra     1$
9$:           rts
ssSites:
              .word .word0 SH_P1
              .byte 3
              .byte 0xcd, .byte0 rw_stopx, .byte1 rw_stopx, 0
              .byte 0x20, .byte0 ssStart, .byte1 ssStart, 0
              .word .word0 SH_P2
              .byte 3
              .byte 0xad, .byte0 SL_X0, .byte1 SL_X0, 0
              .byte 0x20, .byte0 ssSeg, .byte1 ssSeg, 0
              .word .word0 SH_VT
              .byte 2
              .word .word0 varTab
              .byte 0, 0
              .byte .byte0 ssVarTab, .byte1 ssVarTab, 0, 0
              .word .word0 SH_SD
              .byte 4
              .byte 0xaf, .byte0 SL_X0, .byte1 SL_X0, .byte2 SL_X0
              .byte 0x20, .byte0 ssX0, .byte1 ssX0, 0xea
              .word .word0 SH_SE
              .byte 3
              .byte 0xa5, 0x54, 0x4a, 0x00
              .byte 0x20, .byte0 ssEnd, .byte1 ssEnd, 0
              .word .word0 solidColumn
              .byte 3
              .byte 0x8a, 0x4a, 0xaa, 0x00
              .byte 0x4c, .byte0 ssSolid, .byte1 ssSolid, 0
ssLoopSites:
              .word .word0 v02br
              .byte 3
              .byte 0x82, .byte0 (v02col-v02br-3)
              .byte .byte1 (v02col-v02br-3), 0
              .byte 0x4c, .byte0 ss02Next4, .byte1 ss02Next4, 0
              .word .word0 v04br
              .byte 3
              .byte 0x82, .byte0 (v04col-v04br-3)
              .byte .byte1 (v04col-v04br-3), 0
              .byte 0x4c, .byte0 ss04Next4, .byte1 ss04Next4, 0
              .word .word0 v05br
              .byte 3
              .byte 0x82, .byte0 (v05col-v05br-3)
              .byte .byte1 (v05col-v05br-3), 0
              .byte 0x4c, .byte0 ss05Next4, .byte1 ss05Next4, 0
              .word .word0 v06br
              .byte 3
              .byte 0x82, .byte0 (v06col-v06br-3)
              .byte .byte1 (v06col-v06br-3), 0
              .byte 0x4c, .byte0 ss06Next4, .byte1 ss06Next4, 0
              .word .word0 v07br
              .byte 3
              .byte 0x82, .byte0 (v07col-v07br-3)
              .byte .byte1 (v07col-v07br-3), 0
              .byte 0x4c, .byte0 ss07Next4, .byte1 ss07Next4, 0
              .word .word0 v08br
              .byte 3
              .byte 0x82, .byte0 (v08col-v08br-3)
              .byte .byte1 (v08col-v08br-3), 0
              .byte 0x4c, .byte0 ss08Next4, .byte1 ss08Next4, 0
              .word .word0 v10br
              .byte 3
              .byte 0x82, .byte0 (v10col-v10br-3)
              .byte .byte1 (v10col-v10br-3), 0
              .byte 0x4c, .byte0 ss10Next4, .byte1 ss10Next4, 0
              .word .word0 v12br
              .byte 3
              .byte 0x82, .byte0 (v12col-v12br-3)
              .byte .byte1 (v12col-v12br-3), 0
              .byte 0x4c, .byte0 ss12Next4, .byte1 ss12Next4, 0
              .word .word0 v13br
              .byte 3
              .byte 0x82, .byte0 (v13col-v13br-3)
              .byte .byte1 (v13col-v13br-3), 0
              .byte 0x4c, .byte0 ss13Next4, .byte1 ss13Next4, 0
              .word .word0 v14br
              .byte 3
              .byte 0x82, .byte0 (v14col-v14br-3)
              .byte .byte1 (v14col-v14br-3), 0
              .byte 0x4c, .byte0 ss14Next4, .byte1 ss14Next4, 0
              .word .word0 v15br
              .byte 3
              .byte 0x82, .byte0 (v15col-v15br-3)
              .byte .byte1 (v15col-v15br-3), 0
              .byte 0x4c, .byte0 ss15Next4, .byte1 ss15Next4, 0
              .word .word0 v20br
              .byte 3
              .byte 0x82, .byte0 (v20col-v20br-3)
              .byte .byte1 (v20col-v20br-3), 0
              .byte 0x4c, .byte0 ss20Next4, .byte1 ss20Next4, 0
              .word .word0 v28br
              .byte 3
              .byte 0x82, .byte0 (v28col-v28br-3)
              .byte .byte1 (v28col-v28br-3), 0
              .byte 0x4c, .byte0 ss28Next4, .byte1 ss28Next4, 0
              .word 0
              .space 2344 - (. - c5ClipStart)



;;; ---------------------------------------------------------------------------
;;; genColumn: column x (X = 2x) with the flags of the seg, as the C code.
;;; X is kept.
;;; ---------------------------------------------------------------------------
genColumn:    stx     dp:W_X2
              STEP32  W_TF, W_TS            ; yl
              sta     dp:W_YL
              STEP32  W_BF, W_BS            ; yh
              dec     a
              sta     dp:W_YH
              lda     dp:W_SEGTEX
              beq     1$
              STEP24W W_SC, W_SCS           ; rw_scale
1$:           lda     long:ceilingclip,x    ; (the clips + 1: segvar.inc)
              sta     dp:W_TOP              ; top = cc_rwx + 1
              dec     a
              sta     dp:W_CC
              lda     long:floorclip,x
              dec     a
              sta     dp:W_FC
              lda     dp:W_YL               ; if (yl < top) yl = top
              SLT     dp:W_TOP
              bpl     2$
              lda     dp:W_TOP
              sta     dp:W_YL

              ;; ceiling
2$:           lda     dp:W_MC
              beq     10$
              lda     dp:W_YL               ; bottom = yl - 1
              dec     a
              sta     dp:W_BOT
              SLT     dp:W_FC               ; if (bottom >= fc_rwx) bottom = fc_rwx - 1
              bmi     3$
              lda     dp:W_FC
              dec     a
              sta     dp:W_BOT
3$:           lda     dp:W_SKY
              beq     61$
              lda     dp:W_BOT              ; if (top <= bottom)
              SLT     dp:W_TOP
              bmi     5$
              jsr     .kbank skyColumn
              bra     5$
              ;; the rows of the column in the ceiling: top .. bottom
61$:          lda     dp:W_BOT
              SLT     dp:W_TOP
              bmi     5$                    ; (no rows)
              sep     #0x20                 ; (the rows are bytes here, in
              lda     dp:W_TOP              ;   the bytes of segvar.inc)
              sta     dp:W_CT
              lda     dp:W_BOT
              inc     a
              sta     dp:W_CB1
              jsr     .kbank ceilFill
              rep     #0x20
5$:           lda     dp:W_BOT              ; cc_rwx = bottom
              sta     dp:W_CC

10$:          lda     dp:W_FC               ; bottom = fc_rwx - 1
              dec     a
              sta     dp:W_BOT
              SLT     dp:W_YH               ; if (yh > bottom) yh = bottom
              bpl     11$
              lda     dp:W_BOT
              sta     dp:W_YH

              ;; floor
11$:          lda     dp:W_MF
              beq     20$
              lda     dp:W_YH               ; top = yh < cc_rwx ? cc_rwx : yh
              SLT     dp:W_CC
              bmi     12$
              lda     dp:W_YH
              bra     13$
12$:          lda     dp:W_CC
13$:          inc     a                     ; ++top
              sta     dp:W_TOP
              lda     dp:W_BOT              ; the rows of the column in the floor:
              SLT     dp:W_TOP              ; top .. bottom
              bmi     16$                   ; (no rows)
              sep     #0x20                 ; (the rows are bytes here, in
              lda     dp:W_TOP              ;   the bytes of segvar.inc)
              sta     dp:W_FT
              lda     dp:W_BOT
              inc     a
              sta     dp:W_FCR
              jsr     .kbank floorFill
              rep     #0x20
16$:          lda     dp:W_TOP              ; fc_rwx = top
              sta     dp:W_FC

20$:          lda     dp:W_SEGTEX
              beq     30$
              jsr     .kbank texCol

              ;; the wall tiers
30$:          lda     dp:W_MIDTEX
              beq     40$
              lda     dp:W_YH               ; single sided line: rows yl..yh
              sec
              sbc     dp:W_YL
              inc     a
              bmi     39$
              beq     39$
              sta     dp:.tiny DC_COUNT
              nop                           ; the row is already W_YL
              nop
              nop
              nop
              jsr     .kbank drawMid
              rep     #0x20                 ; (the tier returns 8-bit A)
39$:          lda     ##CONST_VIEWHEIGHT
              sta     dp:W_CC
              lda     ##0xffff
              sta     dp:W_FC
              brl     50$

              ;; two sided line, top wall
40$:          lda     dp:W_TOPTEX
              beq     45$
              STEP32  W_PH, W_PHS           ; mid = pixhigh >> FRACBITS
              dec     a
              sta     dp:W_MID
              SLT     dp:W_FC               ; if (mid >= fc_rwx) mid = fc_rwx - 1
              bmi     41$
              lda     dp:W_FC
              dec     a
              sta     dp:W_MID
41$:          lda     dp:W_MID              ; if (mid >= yl): rows yl..mid
              SLT     dp:W_YL
              bmi     43$
              lda     dp:W_MID
              sec
              sbc     dp:W_YL
              inc     a
              sta     dp:.tiny DC_COUNT
              nop                           ; the row is already W_YL
              nop
              nop
              nop
              jsr     .kbank drawTop
              rep     #0x20                 ; (the tier returns 8-bit A)
              lda     dp:W_MID              ; cc_rwx = mid
              sta     dp:W_CC
              bra     46$
43$:          lda     dp:W_YL               ; cc_rwx = yl - 1
              dec     a
              sta     dp:W_CC
              bra     46$
45$:          lda     dp:W_MC               ; no top wall
              beq     46$
              lda     dp:W_YL
              dec     a
              sta     dp:W_CC

              ;; bottom wall
46$:          lda     dp:W_BOTTEX
              beq     48$
              STEP32  W_PL, W_PLS           ; mid = (pixlow + FRACUNIT - 1) >> FRACBITS
              sta     dp:W_MID
              lda     dp:W_CC               ; if (mid <= cc_rwx) mid = cc_rwx + 1
              SLT     dp:W_MID
              bmi     47$
              lda     dp:W_CC
              inc     a
              sta     dp:W_MID
47$:          lda     dp:W_YH               ; if (mid <= yh): rows mid..yh
              SLT     dp:W_MID
              bmi     49$
              lda     dp:W_YH
              sec
              sbc     dp:W_MID
              inc     a
              sta     dp:.tiny DC_COUNT
              lda     dp:W_MID              ; tierDraw reads the row from W_YL
              sta     dp:W_YL
              jsr     .kbank drawBot
              rep     #0x20                 ; (the tier returns 8-bit A)
              lda     dp:W_MID              ; fc_rwx = mid
              sta     dp:W_FC
              bra     50$
49$:          lda     dp:W_YH               ; fc_rwx = yh + 1
              inc     a
              sta     dp:W_FC
              bra     50$
48$:          lda     dp:W_MF               ; no bottom wall
              beq     50$
              lda     dp:W_YH
              inc     a
              sta     dp:W_FC

              ;; a column that blocks all sight is solid for the BSP code
50$:          lda     dp:W_MC
              ora     dp:W_MF
              beq     52$
              lda     dp:W_CC               ; if (fc_rwx <= cc_rwx + 1)
              inc     a
              SLT     dp:W_FC
              bmi     52$
              jsr     .kbank solidColumn

              ;; save texturecol for backdrawing of masked mid texture
52$:          lda     dp:W_MASKED
              beq     53$
              txy
              lda     dp:W_TEXCOL
              sta     [W_MASKP],y
53$:          lda     dp:W_FC               ; the clips + 1, clipped to -1..168
              jsr     .kbank clip8
              sta     long:floorclip,x
              lda     dp:W_CC
              jsr     .kbank clip8
              sta     long:ceilingclip,x
              rts

;;; clip8: C = min(max(C, -1), 168) + 1, the clip arrays of segvar.inc.
clip8:        bmi     2$
              cmp     ##(CONST_VIEWHEIGHT + 1)
              bcc     1$
              lda     ##CONST_VIEWHEIGHT
1$:           inc     a
              rts
2$:           lda     ##0
              rts

;;; solidColumn: solidcol[x] = 1 (X = 2x, kept).
solidColumn:  txa
              lsr     a
              tax
              sep     #0x20
              lda     #1
              sta     long:solidcol,x
              sta     dp:W_DIDSOLID
              rep     #0x20
              txa
              asl     a
              tax
              rts

;;; skyColumn: the sky in rows W_TOP..W_BOT of column x (X = 2x, kept), as
;;; R_DrawSky of r_sky.c: the texel column
;;; (((viewangle >> 16) + xtoviewangle[x]) >> 6) & skywidthmask of the sky
;;; patch, texturemid 100 << 16, one texel per row (SKYFRACSTEP), the fixed
;;; or the full colormap. The step 256 is a multiple of 64, so the compiled
;;; scaler gives the texels of the stepping drawer.
skyColumn:    lda     long:skypatch
              ora     long:(skypatch+2)
              bne     1$
              brl     skyFlat               ; no sky patch: the C code
1$:           stx     dp:W_X2
              lda     long:(viewangle+2)   ; the texel column
              clc
              adc     long:xtoviewangleTable,x
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              and     long:skywidthmask
              asl     a
              asl     a
              adc     ##OFS_PATCH_COLUMNOFS
              tay
              lda     long:skypatch        ; source = patch + columnofs[xc] + 3
              sta     dp:.tiny DC_SRC
              lda     long:(skypatch+2)
              sta     dp:.tiny (DC_SRC+2)
              lda     [.tiny DC_SRC],y
              clc
              adc     ##3
              clc
              adc     long:skypatch
              sta     dp:.tiny DC_SRC
              lda     long:fixedcolormap   ; the fixed colormap, else the full one
              ora     long:(fixedcolormap+2)
              beq     2$
              lda     long:fixedcolormap
              sec
              sbc     ##.word0 fullcolormap
2$:           clc                           ; its page
              adc     ##.word0 iigs_shrcmapA
              pei     dp:W_LV               ; (the light of the walls: W_LV and
              pei     dp:W_CMP              ;   W_CMP again after the sky)
              stz     dp:W_LV
              sep     #0x20
              xba
              sta     dp:W_CMP
              rep     #0x20
              lda     dp:W_YL               ; the wall's yl, back after the sky
              sta     dp:.tiny DC_ROW
              lda     dp:W_TOP              ; rows top..bottom: tierDraw reads W_YL
              sta     dp:W_YL
              lda     dp:W_BOT
              sec
              sbc     dp:W_TOP
              inc     a
              sta     dp:.tiny DC_COUNT
              lda     ##SKYFRACSTEP
              sta     dp:.tiny DC_FSTEP
              lda     dp:W_TCX              ; (tierDraw takes the column from
              pha                           ;   W_TCX; the texture column of
              stx     dp:W_TCX              ;   the walls stays)
              lda     ##SKYTMID7
              jsr     .kbank tierDraw
              rep     #0x20                 ; (texRec returns 8-bit A)
              pla
              sta     dp:W_TCX
              pla                           ; the light of the walls again
              sta     dp:W_CMP
              pla
              sta     dp:W_LV
              lda     dp:.tiny DC_ROW       ; the wall's yl
              sta     dp:W_YL
              ldx     dp:W_X2
              rts

;;; skyFlat: the sky without a patch, with R_DrawSky of the C code.
skyFlat:      txa
              lsr     a
              sta     long:(SL_DCV+OFS_DC_X)
              lda     dp:W_TOP
              sta     long:(SL_DCV+OFS_DC_YL)
              lda     dp:W_BOT
              sta     long:(SL_DCV+OFS_DC_YH)
              CENV
              DCVARG
              jsl     long:R_DrawSky        ; (dcvars.colormap: R_DrawSky sets
              WENV                          ;   it; R_DrawColumnFlat does not
                                            ;   use it)
              ldx     dp:W_X2
              rts

;;; ---------------------------------------------------------------------------
;;; drawMid, drawTop, drawBot: rows DC_ROW.. (DC_COUNT >= 1) of the tier in
;;; column x (X = 2x, kept). The texture column of x is made first if needed.
;;; ---------------------------------------------------------------------------
TIER          .macro  tex, dir, wm, tm
              cpx     dp:W_TCX              ; (then W_TCX = X: tierDraw, texRec
              beq     1$                    ;   and tierFlat take X from it)
              jsr     .kbank texCol
1$:           lda     dp:W_TEXCOL           ; the texels of the column
              and     dp:\wm
              asl     a
              asl     a
              tay
              lda     [\dir],y
              sta     dp:.tiny DC_SRC
              iny
              iny
              lda     [\dir],y
              cmp     ##0x0100              ; 1 in the high byte: no patch
              bcs     2$
              sta     dp:.tiny (DC_SRC+2)
              lda     dp:\tm
              jmp     .kbank c16Start      ; FULL overlay in this bank
              nop                          ; skipped; TIER stays39 bytes
2$:           lda     dp:\tex
              bra     tierFlat             ; pays for the direct jump byte
              .endm

drawMid:      TIER    W_MIDTEX, W_MDIR, W_MWM, W_MTM
drawTop:      TIER    W_TOPTEX, W_TDIR, W_TWM, W_TTM
drawBot:      TIER    W_BOTTEX, W_BDIR, W_BWM, W_BTM

;;; tierFlat: a column without a patch is drawn in the color of the texture
;;; number, as R_DrawSegTextureColumn does. In: C = the texture number.
tierFlat:     pha
              lda     dp:W_TCX              ; (the column, TIER)
              lsr     a
              sta     long:(SL_DCV+OFS_DC_X)
              lda     dp:W_YL
              sta     long:(SL_DCV+OFS_DC_YL)
              clc
              adc     dp:.tiny DC_COUNT
              dec     a
              sta     long:(SL_DCV+OFS_DC_YH)
              CENV
              DCVARG
              lda     4,s                   ; the color
              jsl     long:R_DrawColumnFlat
              WENV
              pla
              ldx     dp:W_TCX
              sep     #0x20                 ; (8-bit A back, as texRec)
              rts

;;; tierDraw: draw the tier. In: C = its texturemid >> 7, DC_SRC, DC_ROW,
;;; DC_COUNT, and texCol of the column; W_X2.
;;;   frac = (row - CENTERY - 1) * fracstep + texturemid >> 7
;;; is the texture position one row before the first, as in R_WallColumnFast.
;;; The tier becomes a K_TEX record at the end of the list of its column
;;; (src/iigs/r_list65.s).
;;; The product is MULLO16 with a = row - CENTERY - 1 made again in A
;;; instead of a store.
tierDraw:     jmp     long:c16Start        ; full view; c16Mode restores old bytes
              sbc     ##(CONST_CENTERY + 1)
              clc
              adc     dp:.tiny DC_FSTEP
              bcs     20$
              asl     a
              tax
              tya
              bcs     10$
              adc     long:SQL,x            ; (carry clear)
              bra     50$
10$:          clc
              adc     long:(SQL+0x10000),x
              bra     50$
20$:          asl     a
              tax
              tya
              bcs     30$
              adc     long:(SQL+0x20000),x  ; (carry clear)
              bra     50$
30$:          clc
              adc     long:(SQL+0x30000),x
50$:          tay
              lda     dp:W_YL               ; - sq(|a - b|)
              sec
              sbc     ##(CONST_CENTERY + 1)
              sec
              sbc     dp:.tiny DC_FSTEP
              bcs     60$
              eor     ##0xffff
              inc     a
60$:          asl     a
              tax
              tya
              bcs     70$
              sec
              sbc     long:SQL,x
              bra     80$
70$:          sec
              sbc     long:(SQL+0x10000),x
80$:          tay                           ; Y = frac
              ldx     dp:W_TCX

;;; texRec: the tier as a K_TEX record at the end of the list of the column
;;; (X = the column, W_TCX). In: Y = frac, 16-bit A, X, Y. The 16-bit fields
;;; first (position, step, texels: one 16-bit store each), then one SEP and
;;; the bytes: the caller gets 8-bit A back (REP and SEP cost a slow cycle
;;; each). X = W_TCX on exit.
texRec:       lda     long:COLW,x           ; the free byte of the list: no
              tax                           ;   room in the page, an extra
              and     ##0x00ff              ;   page first (X = the record)
              cmp     ##(PAGE_ROOM - TEX_SIZE + 1)
              bcs     c26NewPage
c26RecordReady:           tya                           ; the position >> 1: TF, TI
              txy                           ; (Y = the record)
              lsr     a
              sta     abs:R_TF,y
              lda     dp:.tiny DC_FSTEP     ; the step >> 1: SF, SI
              lsr     a
              sta     abs:R_SF,y
              lda     dp:W_LV               ; the colormap of the even rows:
              beq     c26Fixed                   ;   the light of the column, or W_CMP
              lda     dp:(W_SC+1)           ; (rw_scale of the column)
              DLIGHT
              tax                           ; d; span setup biases c26Lookup
              lda     dp:.tiny DC_SRC       ; the texels (after the light: the
              sta     abs:R_SRC,y           ;   writes before it drain)
              sep     #0x20
c26Lookup     .equ    .
              lda     long:c26Reverse,x    ; PGT[startmap + 24 - d], exactly
              bra     c26Store
c26Fixed:          lda     dp:.tiny DC_SRC
              sta     abs:R_SRC,y
              sep     #0x20
              lda     dp:W_CMP
c26Store:          sta     abs:R_CMP,y
              lda     #K_TEX
              sta     abs:R_KIND,y
              lda     dp:W_YL               ; the rows: the first, the row after
              sta     abs:R_ROW,y           ;   the last
              clc
              adc     dp:.tiny DC_COUNT
              sta     abs:R_END,y
              lda     dp:.tiny (DC_SRC+2)
              sta     abs:(R_SRC+2),y
              ldx     dp:W_TCX              ; COLW past the record (the page
              tya                           ;   stays)
              clc
              adc     #TEX_SIZE
              sta     long:COLW,x
              rts
c26NewPage:           phy                           ; an extra page first (frac)
              txy
              ldx     dp:W_TCX
              jsl     long:newPage          ; Y = the free byte of the new page
              tyx
              ply
              bra     c26RecordReady
              .space  6                     ; C26 keeps ceilFill and later slots

;;; ceilFill, floorFill: the rows W_CT .. W_CB1 - 1 (ceiling) or W_FT ..
;;; W_FCR - 1 (floor) of column X / 2 (X = 2x, kept), bytes, the first below
;;; the end, in the ceiling or floor color: a K_FILL record at the end of
;;; the list of the column. The callers set the rows some cycles before the
;;; call. 8-bit A. Each store is a byte, and a read or register work
;;; follows it.
PLANEFILL     .macro  bytes, first, end
              lda     long:(COLW+1),x       ; Y = the free byte of the list (two
              xba                           ;   8-bit loads: TAY copies B too,
              lda     long:COLW,x           ;   no REP/SEP)
              tay
              cmp     #(PAGE_ROOM - FILL_SIZE + 1) ; no room in the page: an
              bcs     8$                    ;   extra page first
1$:           adc     #FILL_SIZE            ; (carry clear)
              sta     long:COLW,x           ; COLW past the record
              lda     dp:\first             ; an odd first row: the byte of the
              lsr     a                     ;   odd rows first
              lda     #K_FILL
              sta     abs:R_KIND,y
              lda     dp:\first             ; the rows: the first, the row after
              sta     abs:R_ROW,y           ;   the last
              lda     dp:\end
              sta     abs:R_END,y
              lda     dp:\bytes             ; the byte of the even rows
              bcs     2$
              sta     abs:R_B1,y
              lda     dp:(\bytes+1)
              sta     abs:R_B2,y
              rts
2$:           sta     abs:R_B2,y
              lda     dp:(\bytes+1)
              sta     abs:R_B1,y
              rts
8$:           rep     #0x20                 ; an extra page first
              jsl     long:newPage          ; Y = the free byte of the new page
              tya
              sep     #0x20
              clc
              bra     1$
              .endm

;;; ceilSky: the sky in the rows W_CT .. W_CB1 - 1 of the ceiling of column
;;; x (X = 2x, kept), as genColumn draws it. 8-bit A in and out.
ceilSky:      rep     #0x20
              lda     dp:W_CT
              and     ##0x00ff
              sta     dp:W_TOP
              lda     dp:W_CB1
              and     ##0x00ff
              dec     a
              sta     dp:W_BOT
              jsr     .kbank skyColumn
              sep     #0x20
              rts

;;; The fill from the first row of the view (W_TOPR) is the top span of the
;;; column, the fill to the row after the view (W_BOTR) its bottom span
;;; (src/iigs/lists.inc). When the span of the frame before (stamp W_FSP)
;;; has the same bytes, its rows are on the screen: the record gets only the
;;; other rows (ceilFill raises W_CT, floorFill lowers W_FCR), or there is
;;; no record. The span of this frame (stamp W_FSC) takes its place.
ceilFill:     lda     dp:W_SKY              ; a sky ceiling: skyColumn
              bne     ceilSky
              lda     dp:W_CT               ; the top span?
              cmp     dp:W_TOPR
              bne     fillCeil
              lda     long:FS_STAMP,x       ; the top span of the frame before,
              cmp     dp:W_FSP              ;   with the same bytes?
              bne     5$
              lda     long:FS_EVEN,x
              cmp     dp:W_CEILW
              bne     5$
              lda     long:FS_ODD,x
              cmp     dp:(W_CEILW+1)
              bne     5$
              lda     long:FS_ROW,x         ; its end: the rows above it show
              cmp     dp:W_CB1
              bcs     4$                    ; (all the rows: no record)
              sta     dp:W_CT               ; the record from its end
              lda     dp:W_CB1              ; the new end of the top span
              sta     long:FS_ROW,x
              lda     dp:W_FSC
              sta     long:FS_STAMP,x
              bra     fillCeil
4$:           lda     dp:W_CB1
              sta     long:FS_ROW,x
              lda     dp:W_FSC
              sta     long:FS_STAMP,x
              rts
5$:           lda     dp:W_CB1              ; a new top span
              sta     long:FS_ROW,x
              lda     dp:W_CEILW
              sta     long:FS_EVEN,x
              lda     dp:(W_CEILW+1)
              sta     long:FS_ODD,x
              lda     dp:W_FSC
              sta     long:FS_STAMP,x
fillCeil:     PLANEFILL W_CEILW, W_CT, W_CB1


floorFill:    lda     dp:W_FCR              ; the bottom span?
              cmp     dp:W_BOTR
              bne     fillFloor
              lda     long:(FS_STAMP+1),x   ; the bottom span of the frame
              cmp     dp:W_FSP              ;   before, with the same bytes?
              bne     5$
              lda     long:(FS_EVEN+1),x
              cmp     dp:W_FLOORW
              bne     5$
              lda     long:(FS_ODD+1),x
              cmp     dp:(W_FLOORW+1)
              bne     5$
              lda     long:(FS_ROW+1),x     ; its first row: the rows from it
              cmp     dp:W_FT               ;   on show
              beq     4$                    ; (all the rows: no record)
              bcc     4$
              sta     dp:W_FCR              ; the record to its first row
              lda     dp:W_FT               ; the new first row of the bottom
              sta     long:(FS_ROW+1),x     ;   span
              lda     dp:W_FSC
              sta     long:(FS_STAMP+1),x
              bra     fillFloor
4$:           lda     dp:W_FT
              sta     long:(FS_ROW+1),x
              lda     dp:W_FSC
              sta     long:(FS_STAMP+1),x
              rts
5$:           lda     dp:W_FT               ; a new bottom span
              sta     long:(FS_ROW+1),x
              lda     dp:W_FLOORW
              sta     long:(FS_EVEN+1),x
              lda     dp:(W_FLOORW+1)
              sta     long:(FS_ODD+1),x
              lda     dp:W_FSC
              sta     long:(FS_STAMP+1),x
fillFloor:    PLANEFILL W_FLOORW, W_FT, W_FCR

;;; fillBytes: C = the byte of the even rows | the byte of the odd rows << 8
;;; of plane color C (iigs_shrcmapA, iigs_shrcmapB), 0 for no color or the
;;; sky.
fillBytes:    cmp     ##256
              bcs     1$
              tax
              lda     long:iigs_shrcmapB,x
              xba
              and     ##0xff00
              sta     dp:W_T
              lda     long:iigs_shrcmapA,x
              and     ##0x00ff
              ora     dp:W_T
              rts
1$:           lda     ##0
              rts

;;; ---------------------------------------------------------------------------
;;; texCol: for column x (X = 2x, kept): W_TEXCOL and DC_FSTEP.
;;;   ang = (angle16_t)(rw_centerangle + xtoviewangle[x]) >> 3
;;;   u = rw_offset +- rw_distance * tan(ang), texturecolumn = u >> FRACBITS
;;; u is exact (tcExact, 16.16) at the first column of a span and at its
;;; end, TC_N columns on (fewer at the end of the seg), and linear between
;;; (lower precision for speed: most columns take an add instead of the
;;; tangent and two products). Between the ends, W_TEXCOL and W_UF8 hold u
;;; (8.8 fraction), W_UDI and W_UDF its step a column, W_UC the columns to
;;; the span end, whose exact u is W_UN (W_UI: of the span start). W_TCX is
;;; the column of the call before (0xffff at the start of a seg: a new
;;; span).
;;; ---------------------------------------------------------------------------
#ifndef TC_N
#define TC_N 8                              /* columns of a span: 1, 2, 4, 8 */
#endif
#if TC_N == 8
#define TC_LOG 3
#elif TC_N == 4
#define TC_LOG 2
#elif TC_N == 2
#define TC_LOG 1
#else
#define TC_LOG 0
#endif

;;; MULHI16 that also keeps bits 0..15 of the product in W_UF.
MULHI16F      .macro  a, b
              lda     dp:\a
              clc
              adc     dp:\b
              bcs     20$
              asl     a
              tax
              bcs     10$
              lda     long:SQL,x
              tay
              lda     long:SQH,x
              bra     50$
10$:          lda     long:(SQL+0x10000),x
              tay
              lda     long:(SQH+0x10000),x
              bra     50$
20$:          asl     a
              tax
              bcs     30$
              lda     long:(SQL+0x20000),x
              tay
              lda     long:(SQH+0x20000),x
              bra     50$
30$:          lda     long:(SQL+0x30000),x
              tay
              lda     long:(SQH+0x30000),x
50$:          sta     dp:W_MH
              lda     dp:\a
              sec
              sbc     dp:\b
              bcs     60$
              eor     ##0xffff
              inc     a
60$:          asl     a
              tax
              tya
              bcs     70$
              sec
              sbc     long:SQL,x
              sta     dp:W_UF
              lda     dp:W_MH
              sbc     long:SQH,x
              bra     80$
70$:          sec
              sbc     long:(SQL+0x10000),x
              sta     dp:W_UF
              lda     dp:W_MH
              sbc     long:(SQH+0x10000),x
80$:
              .endm

;;; C = bits 16..31 of rw_distance * W_TAN, with du = rw_distance as unsigned:
;;;   M = hi16(du * tanlo) - (d < 0 ? tanlo : 0) + lo16(du * tanhi)
;;; and W_UF = bits 0..15 (lo16(du * tanlo)).
TANPROD       .macro
              MULHI16F W_DIST, W_TAN        ; hi16(du * tanlo)
              ldy     dp:W_DIST
              bpl     1$
              sec
              sbc     dp:W_TAN
1$:           ldy     dp:(W_TAN+2)
              beq     2$
              sta     dp:W_M
              MULLO16 W_DIST, (W_TAN+2)     ; lo16(du * tanhi)
              clc
              adc     dp:W_M
2$:
              .endm

texCol:       txa                           ; the column after the one before?
              sec
              sbc     dp:W_TCX
              stx     dp:W_TCX
#if TC_N == 1
              bra     tcNew
#endif
              bcc     tcNew                 ; (before it: a new span)
SH_TC1        .equ    . + 1                 ; (the half view: 4)
              cmp     ##2                   ; (another column: a new span)
              bne     tcNew
              sep     #0x20
              dec     dp:W_UC               ; the span end: its exact u
              beq     tcEnd
              lda     dp:W_UF8              ; u += the step
              clc
              adc     dp:W_UDF
              sta     dp:W_UF8
              rep     #0x20
              lda     dp:W_TEXCOL           ; (the common path falls into
              adc     dp:W_UDI              ;   tcStep)
tcStep:       sta     dp:W_TEXCOL

              ;; the step: FSTEP_TABLE[scale] when the high word is 0
tcScale:      lda     dp:(W_SC+2)
              bne     c17Scale40
              lda     dp:W_SC
              asl     a
              tax
              bcs     c17Scale31
              lda     long:FSTEP_TABLE,x
c17Scale50:          sta     dp:.tiny DC_FSTEP
              ldx     dp:W_TCX
;;; The three TIER continuations share a high address byte. One word store
;;; per seg selects RTS or JMP to the sole tier, without a per-column test.
c17Return     .equ    .
              .byte   0x60, 0, .byte1 (drawMid+7)
c17Scale31:          lda     long:(FSTEP_TABLE+0x10000),x
              bra     c17Scale50
c17Scale40:          jsl     long:fstepHigh
              bra     c17Scale50
tcEnd:        rep     #0x20                 ; the start of the next span: the
              lda     dp:W_UN               ;   end of this one
              sta     dp:W_UI
              lda     dp:(W_UN+2)
              sta     dp:(W_UI+2)
              bra     tcSpan
tcNew:        jsr     .kbank tcExact        ; u exact
              sta     dp:(W_UI+2)
              lda     dp:W_UF
              sta     dp:W_UI
              ldx     dp:W_TCX
tcSpan:       sep     #0x20                 ; the running u from the start
              lda     dp:(W_UI+1)
              sta     dp:W_UF8
              rep     #0x20
              lda     dp:(W_UI+2)
              sta     dp:W_TEXCOL
#if TC_N > 1
              txa                           ; the next span: TC_N columns on,
              clc                           ;   else 2 or 1, up to the last
              adc     ##(2 * TC_N)          ;   column of the seg
SH_TL         .equ    . + 1                 ; (the half view: TC_LOG - 1)
              ldy     ##TC_LOG
              cmp     dp:W_X2END
              bcc     4$
#if TC_N > 2
SH_TC3        .equ    . + 1                 ; (the half view: 2 * TC_N - 8)
              sbc     ##(2 * TC_N - 4)      ; (carry set)
              ldy     ##1
              cmp     dp:W_X2END
              bcc     4$
#endif
SH_TC4        .equ    . + 1                 ; (the half view: 4)
              sbc     ##2
              ldy     ##0
              cmp     dp:W_X2END
              bcc     4$
              bra     tcLoad                ; the last column: no span
4$:           sty     dp:W_T                ; (the shifts: the columns = 1 << W_T)
              tax
              jsr     .kbank tcExact        ; the exact u of the span end
              sta     dp:(W_UN+2)
              lda     dp:W_UF
              sta     dp:W_UN
              sec                           ; the step: (W_UN - W_UI) / the
              sbc     dp:W_UI               ;   columns, 16.8
              sta     dp:W_T4
              lda     dp:(W_UN+2)
              sbc     dp:(W_UI+2)
              ldx     dp:W_T
              beq     6$
5$:           cmp     ##0x8000              ; (signed)
              ror     a
              ror     dp:W_T4
              dex
              bne     5$
6$:           sta     dp:W_UDI
              lda     dp:W_T4
              xba
              sep     #0x20
              sta     dp:W_UDF
              ldx     dp:W_T                ; W_UC = the columns
              lda     long:tcCols,x
              sta     dp:W_UC
              rep     #0x20
              ldx     dp:W_TCX
#endif
tcLoad:       brl     tcScale               ; (W_TEXCOL holds it already)
              .space  0                     ; c17Return uses the old two bytes
tcCols:       .byte   1, 2, 4, 8

;;; tcExact: the exact u of column X / 2: C = its whole part, W_UF its
;;; fraction. X, Y are not kept.
tcExact:      lda     dp:W_CANGLE
              clc
              adc     long:xtoviewangleTable,x
              lsr     a
              lsr     a
              lsr     a
              cmp     ##2048
              bcc     1$
              brl     20$
1$:           cmp     ##1024
              bcs     2$
              eor     ##1023                ; 0 <= ang < 1024: part_4[1023 - ang], +
              asl     a
              asl     a
              tax
              lda     long:finetangentTable_part_4,x
              sta     dp:W_TAN
              lda     long:(finetangentTable_part_4+2),x
              sta     dp:(W_TAN+2)
              bra     10$
2$:           eor     ##2047                ; 1024 <= ang < 2048: part_3[2047 - ang], +
              asl     a
              tax
              lda     long:finetangentTable_part_3,x
              sta     dp:W_TAN
              ldy     dp:(W_TAN+2)          ; tanhi = 0 (a store only when it
              beq     10$                   ;   was not)
              stz     dp:(W_TAN+2)
10$:          TANPROD
              clc                           ; rw_offset + M, fraction W_UF
              adc     dp:W_OFFSET
              rts
20$:          cmp     ##3072
              bcs     22$
              sbc     ##(2048 - 1)          ; 2048 <= ang < 3072: part_3[ang - 2048], -
              asl     a                     ; (carry clear: minus 1 more)
              tax
              lda     long:finetangentTable_part_3,x
              sta     dp:W_TAN
              ldy     dp:(W_TAN+2)          ; tanhi = 0
              beq     24$
              stz     dp:(W_TAN+2)
              bra     24$
22$:          sbc     ##3072                ; 3072 <= ang: part_4[ang - 3072], -
              asl     a
              asl     a
              tax
              lda     long:finetangentTable_part_4,x
              sta     dp:W_TAN
              lda     long:(finetangentTable_part_4+2),x
              sta     dp:(W_TAN+2)
24$:          TANPROD
              eor     ##0xffff              ; rw_offset - M as before, with the
              sec                           ;   fraction ~W_UF: rw_offset -
              adc     dp:W_OFFSET           ;   M:W_UF + 0xffff / 0x10000, whose
              tay                           ;   whole part is rw_offset - M
              lda     dp:W_UF
              eor     ##0xffff
              sta     dp:W_UF
              tya
              rts


;;; ---------------------------------------------------------------------------
;;; The half view (VW_HALF, viewwin.inc): the loops take the even columns
;;; only, with twice the steps of the edges and of the scale; R_SegHalf of
;;; src/iigs/r_list65.s patches them in (SEGPATCH below) when the view
;;; changes. Here after the rest of the loops, so that the full view keeps
;;; its code where it was. halfStart (JSR for the CMP rw_stopx of
;;; R_RenderSegLoop): the first column rw_x or rw_x + 1, even; W_HD the
;;; parity of rw_x. halfSeg (JSR for its LDA SL_X0): for an even rw_x each
;;; edge and the scale one step back (the value one double step before the
;;; first column), then the steps doubled.
;;; ---------------------------------------------------------------------------
halfStart:    pha
              and     ##1
              sep     #0x20
              sta     long:(WPAGE+W_HD)
              rep     #0x20
              pla
              bit     ##1
              bne     2$
              cmp     .near rw_stopx
              rts
2$:           inc     a                     ; an odd rw_x: the column after
              cmp     .near rw_stopx
              bcc     9$
              dec     a                     ; no even column: rw_x alone (or
              cmp     .near rw_stopx        ;   none). A single sided line
              bcs     8$                    ;   makes it solid (as segDone),
              tax                           ;   else the BSP code calls
              lda     long:(WPAGE+W_MIDTEX) ;   R_StoreWallRange for it again
              beq     8$                    ;   with each seg behind it
              lda     long:(WPAGE+W_MF)     ; markfloor | markceiling
              ora     long:(WPAGE+W_MC)
              beq     8$
              sep     #0x20
              lda     #1
              sta     long:solidcol,x
              rep     #0x20
8$:           sec
9$:           rts
;;; segEndH (JSR for the LDA W_X2END, LSR of segDone): the end of the solid
;;; columns, rw_stopx rounded up to even (the odd column after an even last
;;; column is solid with it, as in solidColumnH).
segEndH:      lda     dp:W_X2END
              lsr     a
              inc     a
              and     ##0xfffe
              rts
;;; segX0H (JSR for the LDA SL_X0 of segDone): the first column of the seg,
;;; rw_x, for its solid columns. solidColumnH (JMP from solidColumn): the
;;; odd column after x solid with x (the BSP code then does not call
;;; R_StoreWallRange for odd columns alone, which the half view never
;;; draws; each call takes a drawseg).
segX0H:       lda     dp:W_HD
              and     ##1
              eor     ##0xffff
              sec
              adc     long:SL_X0
              rts
solidColumnH: txa
              lsr     a
              tax
              sep     #0x20
              lda     #1
              sta     long:solidcol,x
              sta     long:(solidcol+1),x
              sta     dp:W_DIDSOLID
              rep     #0x20
              txa
              asl     a
              tax
              rts
halfSeg:      ldx     ##(W_SC - W_TF)       ; W_TF, W_BF, W_PH, W_PL, W_SC and
1$:           lda     dp:W_HD               ;   their steps 4 bytes on
              lsr     a
              bcs     2$
              lda     dp:W_TF,x             ; an even rw_x: one step back
              sec
              sbc     dp:(W_TF+4),x
              sta     dp:W_TF,x
              lda     dp:(W_TF+2),x
              sbc     dp:(W_TF+6),x
              sta     dp:(W_TF+2),x
2$:           asl     dp:(W_TF+4),x         ; the step doubled
              rol     dp:(W_TF+6),x
              txa
              sec
              sbc     ##8
              tax
              bpl     1$
              lda     .near SL_X0
              rts

;;; The loops of the half view: the exits of the loops of segvar.inc (their
;;; BRL L(col) goes here: one more column on), vMask and genLoop (varTabH).
v04nextH:     inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              brl     v04done
1$:           brl     v04col
v05nextH:     inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v05done
1$:           jmp     .kbank v05col
v06nextH:     inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v06done
1$:           jmp     .kbank v06col
v08nextH:     inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v08done
1$:           jmp     .kbank v08col
v10nextH:     inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v10done
1$:           jmp     .kbank v10col
v12nextH:     inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v12done
1$:           jmp     .kbank v12col
v13nextH:     inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v13done
1$:           jmp     .kbank v13col
v14nextH:     inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v14done
1$:           jmp     .kbank v14col
v15nextH:     inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v15done
1$:           jmp     .kbank v15col
v20nextH:     inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v20done
1$:           jmp     .kbank v20col
v28nextH:     inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v28done
1$:           jmp     .kbank v28col
vMaskH:       ldx     dp:W_X2
1$:           STEP24W W_SC, W_SCS           ; rw_scale (texCol)
              jsr     .kbank texCol
              txy                           ; maskedtexturecol[x] = texturecol
              lda     dp:W_TEXCOL
              sta     [W_MASKP],y
              inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank segDone
genLoopH:     ldx     dp:W_X2
1$:           jsr     .kbank genColumn
              inx
              inx
              inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank segDone
varTabH:      .word   .word0 segDone                               ; two sided: nothing to do
              .word   .word0 genLoopH, .word0 v02entry, .word0 genLoopH, .word0 v04entry
              .word   .word0 v05entry, .word0 v06entry, .word0 v07entry, .word0 v08entry
              .word   .word0 genLoopH, .word0 v10entry, .word0 genLoopH, .word0 v12entry
              .word   .word0 v13entry, .word0 v14entry, .word0 v15entry
              .word   .word0 genLoopH, .word0 genLoopH, .word0 genLoopH, .word0 genLoopH   ; single sided
              .word   .word0 v20entry, .word0 genLoopH, .word0 genLoopH, .word0 genLoopH
              .word   .word0 genLoopH, .word0 genLoopH, .word0 genLoopH, .word0 genLoopH
              .word   .word0 v28entry, .word0 genLoopH, .word0 genLoopH, .word0 genLoopH
              .word   .word0 genLoopH                               ; masked
              .word   .word0 vMaskH                                 ; masked only


;;; ---------------------------------------------------------------------------
;;; The 2/3 view (VW_THIRD, viewwin.inc): the loops take the columns c with
;;; c mod 3 < 2, which thirdAll of src/iigs/r_list65.s draws; R_ViewMode
;;; there patches them in (SEGPATCHT). A skipped column gets only the steps
;;; of the edges, the scale and u, so that each kept column gets the records
;;; of the full view. W_XS: 2 * the next skipped column; W_HD: 1 when rw_x
;;; is skipped. Section segthird: the free end of the BSP code slots (bank 3
;;; for the branches of the loops).
;;; ---------------------------------------------------------------------------
              .section segthird, text
;;; thirdStart (JSR for the CMP rw_stopx of R_RenderSegLoop): the first kept
;;; column from rw_x, as halfStart.
thirdStart:   tax
              lda     long:T_COLB,x         ; the window byte of rw_x (0xff:
              and     ##0x00ff              ;   skipped; even: c mod 3 = 0)
              cmp     ##0x00ff
              beq     4$
              lsr     a                     ; the next skipped column: rw_x + 2
              txa                           ;   or rw_x + 1
              bcs     1$
              inc     a
1$:           inc     a
              asl     a
              sta     long:(WPAGE+W_XS)
              sep     #0x20
              lda     #0
              sta     long:(WPAGE+W_HD)
              rep     #0x20
              txa
              cmp     .near rw_stopx
              rts
4$:           txa                           ; rw_x skipped: thirdSeg steps it
              asl     a                     ;   (W_XS = 2 rw_x); the loop
              sta     long:(WPAGE+W_XS)     ;   starts at rw_x + 1
              sep     #0x20
              lda     #1
              sta     long:(WPAGE+W_HD)
              rep     #0x20
              inx
              txa
              cmp     .near rw_stopx
              bcc     9$
              dex                           ; rw_x alone: as halfStart
              lda     long:(WPAGE+W_MIDTEX)
              beq     8$
              lda     long:(WPAGE+W_MF)
              ora     long:(WPAGE+W_MC)
              beq     8$
              sep     #0x20
              lda     #1
              sta     long:solidcol,x
              rep     #0x20
8$:           sec
9$:           rts
;;; thirdSeg (JSR for the LDA SL_X0 of R_RenderSegLoop): a skipped rw_x
;;; takes its texture column (the span of the columns after it starts there,
;;; as in the full view) and its steps.
thirdSeg:     lda     dp:W_HD
              lsr     a
              bcc     9$
              ldx     dp:W_XS               ; X = 2 rw_x
              lda     dp:W_SEGTEX
              beq     1$
              jsr     .kbank texCol
1$:           sep     #0x20
              jsr     .kbank skPH
              rep     #0x20
9$:           lda     .near SL_X0
              rts
;;; segEndT (JSR for the LDA W_X2END, LSR of segDone): rw_stopx, + 1 when it
;;; is skipped (solid with the column before, as in solidColumnT).
segEndT:      lda     dp:W_X2END
              cmp     dp:W_XS
              bne     1$
              inc     a
              inc     a
1$:           lsr     a
              rts
;;; solidColumnT (JMP from solidColumn): x, and x + 1 when it is skipped:
;;; the BSP code then does not call R_StoreWallRange for it alone.
solidColumnT: txa
              lsr     a
              tax
              sep     #0x20
              lda     #1
              sta     long:solidcol,x
              sta     dp:W_DIDSOLID
              rep     #0x20
              txa
              asl     a
              inc     a
              inc     a
              cmp     dp:W_XS
              bne     1$
              sep     #0x20
              lda     #1
              sta     long:(solidcol+1),x
              rep     #0x20
1$:           txa
              asl     a
              tax
              rts

;;; The steps of a skipped column (X = its 2x, 8-bit A). An exit enters at
;;; the first edge of its loop in this order (most loops then step no edge
;;; they do not use: v10, the most common, steps PL, SC, BF). Then X and
;;; W_XS on; at the end of the seg, segDone.
skPH:         STEP8E  W_PH, W_PHS
skPL:         STEP8E  W_PL, W_PLS
skSC:         STEP8   W_SC, W_SCS
              txy                           ; u one column on as texCol does,
              dey                           ;   when the column before took
              dey                           ;   texCol
              cpy     dp:W_TCX
              bne     skBF
              txa                           ; W_TCX = X (its high byte
              sta     dp:W_TCX              ;   changes only at column 128)
              bne     1$
              lda     #1
              sta     dp:(W_TCX+1)
1$:           dec     dp:W_UC
              beq     2$
              lda     dp:W_UF8
              clc
              adc     dp:W_UDF
              sta     dp:W_UF8
              lda     dp:W_TEXCOL
              adc     dp:W_UDI
              sta     dp:W_TEXCOL
              lda     dp:(W_TEXCOL+1)
              adc     dp:(W_UDI+1)
              sta     dp:(W_TEXCOL+1)
              bra     skBF
2$:           rep     #0x20                 ; the span end: the next span from
              jsr     .kbank tcEnd          ;   this column
              sep     #0x20
skBF:         STEP8E  W_BF, W_BS
skTF:         STEP8E  W_TF, W_TS
              lda     dp:W_XS
              clc
              adc     #6
              sta     dp:W_XS
              bcc     3$
              inc     dp:(W_XS+1)
3$:           inx
              inx
              cpx     dp:W_X2END
              bcs     4$
              rts
4$:           plx                           ; the last column: the seg ends
              rep     #0x20
              jmp     .kbank segDone

;;; The exits of the loops of segvar.inc: their BRL L(col) becomes a JMP
;;; here (a BRL across sections has no object format).
v04nextT:     cpx     dp:W_XS
              bne     1$
              jsr     .kbank skTF
1$:           jmp     .kbank v04col
v05nextT:     cpx     dp:W_XS
              bne     1$
              jsr     .kbank skPH
1$:           jmp     .kbank v05col
v06nextT:     cpx     dp:W_XS
              bne     1$
              jsr     .kbank skPL
1$:           jmp     .kbank v06col
v08nextT:     cpx     dp:W_XS
              bne     1$
              jsr     .kbank skBF
1$:           jmp     .kbank v08col
v10nextT:     cpx     dp:W_XS
              bne     1$
              jsr     .kbank skPL
1$:           jmp     .kbank v10col
v12nextT:     cpx     dp:W_XS
              bne     1$
              jsr     .kbank skBF
1$:           jmp     .kbank v12col
v13nextT:     cpx     dp:W_XS
              bne     1$
              jsr     .kbank skPH
1$:           jmp     .kbank v13col
v14nextT:     cpx     dp:W_XS
              bne     1$
              jsr     .kbank skPL
1$:           jmp     .kbank v14col
v15nextT:     cpx     dp:W_XS
              bne     1$
              jsr     .kbank skPH
1$:           jmp     .kbank v15col
v20nextT:     cpx     dp:W_XS
              bne     1$
              jsr     .kbank skSC
1$:           jmp     .kbank v20col
v28nextT:     cpx     dp:W_XS
              bne     1$
              jsr     .kbank skSC
1$:           jmp     .kbank v28col
;;; genLoopT, vMaskT: genLoop and vMask in the 2/3 view (the skip steps the
;;; edges as the loops of segvar.inc do, not as genColumn: a row can differ
;;; by one in rare columns).
genLoopT:     ldx     dp:W_X2
1$:           jsr     .kbank genColumn
              inx
              inx
              cpx     dp:W_X2END
              bcs     9$
              cpx     dp:W_XS
              bne     1$
              sep     #0x20                 ; (all edges: genColumn steps each
              jsr     .kbank skPH           ;   edge its seg uses)
              rep     #0x20
              bra     1$
9$:           jmp     .kbank segDone
vMaskT:       ldx     dp:W_X2
1$:           STEP24W W_SC, W_SCS           ; rw_scale (texCol)
              jsr     .kbank texCol
              txy                           ; maskedtexturecol[x] = texturecol
              lda     dp:W_TEXCOL
              sta     [W_MASKP],y
              inx
              inx
              cpx     dp:W_X2END
              bcs     9$
              cpx     dp:W_XS
              bne     1$
              sep     #0x20
              jsr     .kbank skSC
              rep     #0x20
              bra     1$
9$:           jmp     .kbank segDone
varTabT:      .word   .word0 segDone                               ; two sided: nothing to do
              .word   .word0 genLoopT, .word0 v02entry, .word0 genLoopT, .word0 v04entry
              .word   .word0 v05entry, .word0 v06entry, .word0 v07entry, .word0 v08entry
              .word   .word0 genLoopT, .word0 v10entry, .word0 genLoopT, .word0 v12entry
              .word   .word0 v13entry, .word0 v14entry, .word0 v15entry
              .word   .word0 genLoopT, .word0 genLoopT, .word0 genLoopT, .word0 genLoopT   ; single sided
              .word   .word0 v20entry, .word0 genLoopT, .word0 genLoopT, .word0 genLoopT
              .word   .word0 genLoopT, .word0 genLoopT, .word0 genLoopT, .word0 genLoopT
              .word   .word0 v28entry, .word0 genLoopT, .word0 genLoopT, .word0 genLoopT
              .word   .word0 genLoopT                               ; masked
              .word   .word0 vMaskT                                 ; masked only


;;; ---------------------------------------------------------------------------
;;; The loops of two kinds that genLoop took (the user's E1M1 stairs,
;;; 2026-09-27: the risers seen from below have no floor mark, 75-89
;;; generic columns a frame): v02 (a bottom wall only), v07 (top and bottom
;;; walls, a ceiling). Section segmore: slots that only the replay uses
;;; (bank 3 for the loops' calls); with their exits of the half view and of
;;; the 2/3 view (R_SegHalf and R_ViewMode patch their L(br) to a JMP).
;;; ---------------------------------------------------------------------------
              .space  2                     ; 24-bit skip/masked steps: old segthird size
              .section segmore, text
#undef V_FAR
#define V_FAR 1
#define V_NAME v02
#define V_ONE 0
#define V_TOP 0
#define V_BOT 1
#define V_MC 0
#define V_MF 0
#include "segvar.inc"
#undef V_NAME
#undef V_ONE
#undef V_TOP
#undef V_BOT
#undef V_MC
#undef V_MF

#define V_NAME v07
#define V_ONE 0
#define V_TOP 1
#define V_BOT 1
#define V_MC 1
#define V_MF 0
#include "segvar.inc"
#undef V_NAME
#undef V_ONE
#undef V_TOP
#undef V_BOT
#undef V_MC
#undef V_MF
#undef V_FAR
#define V_FAR 0

v02nextH:     inx                           ; (the half view: as v04nextH)
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v02done
1$:           jmp     .kbank v02col
v07nextH:     inx
              inx
              cpx     dp:W_X2END
              bcc     1$
              jmp     .kbank v07done
1$:           jmp     .kbank v07col
v02nextT:     cpx     dp:W_XS               ; (the 2/3 view: as v04nextT)
              bne     1$
              jsr     .kbank skPL
1$:           jmp     .kbank v02col
v07nextT:     cpx     dp:W_XS
              bne     1$
              jsr     .kbank skPH
1$:           jmp     .kbank v07col

              .section hotmul, text     ; (src/iigs/iigs.scm)
;;; ---------------------------------------------------------------------------
;;; fstepHigh: texture fracstep for rw_scale >= 1.0. In: C = scale high.
;;; Round the scale to 1/256 and reuse FSTEP_TABLE at scale / 128, then
;;; divide its result by 128. Over 1.0..64.0 the error is at most one
;;; fracstep unit (1/512 texel per screen row); lighting is unchanged.
;;; texCol uses the table directly below 1.0. Keep the general reciprocal
;;; path for high words above 64, outside the renderer's scale range.
fstepHigh:    cmp     ##0x40                ; 64.0 is the renderer's scale clamp
              bcc     fsTable
              beq     fsClamp
              brl     fsGeneral
fsClamp:      lda     ##7
              rtl
fsTable:      lda     dp:W_SC               ; round scale / 256 to nearest
              and     ##0x00ff
              cmp     ##0x0080
              lda     dp:(W_SC+1)
              adc     ##0
              cmp     ##0x4000
              bcs     fsClamp
              asl     a                     ; read FSTEP at twice the rounded scale
              asl     a
              tax
              lda     long:FSTEP_TABLE,x
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              rtl
;;; C26: only varying-light spans come here. Keep W_LV's flag/sky ABI;
;;; the lookup address folds startmap+24 subtraction out of each record.
;;; c26Reverse[84-i] = PGT[i]. W_LV is 24..84, d is 0..23, so the
;;; patched operand and every indexed byte remain in this table's bank.
c26LightSetup:
              sty     dp:W_LV
              tya
              eor     ##0xffff
              sec
              adc     ##.word0 (c26Reverse + 84)
              sta     long:(c26Lookup+1)
              rtl
c26Reverse:
              .byte   .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936)
              .byte   .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936)
              .byte   .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936)
              .byte   .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7680), .byte1 (iigs_shrcmapA + 7424)
              .byte   .byte1 (iigs_shrcmapA + 7168), .byte1 (iigs_shrcmapA + 6912), .byte1 (iigs_shrcmapA + 6656), .byte1 (iigs_shrcmapA + 6400), .byte1 (iigs_shrcmapA + 6144), .byte1 (iigs_shrcmapA + 5888), .byte1 (iigs_shrcmapA + 5632), .byte1 (iigs_shrcmapA + 5376)
              .byte   .byte1 (iigs_shrcmapA + 5120), .byte1 (iigs_shrcmapA + 4864), .byte1 (iigs_shrcmapA + 4608), .byte1 (iigs_shrcmapA + 4352), .byte1 (iigs_shrcmapA + 4096), .byte1 (iigs_shrcmapA + 3840), .byte1 (iigs_shrcmapA + 3584), .byte1 (iigs_shrcmapA + 3328)
              .byte   .byte1 (iigs_shrcmapA + 3072), .byte1 (iigs_shrcmapA + 2816), .byte1 (iigs_shrcmapA + 2560), .byte1 (iigs_shrcmapA + 2304), .byte1 (iigs_shrcmapA + 2048), .byte1 (iigs_shrcmapA + 1792), .byte1 (iigs_shrcmapA + 1536), .byte1 (iigs_shrcmapA + 1280)
              .byte   .byte1 (iigs_shrcmapA + 1024), .byte1 (iigs_shrcmapA + 768), .byte1 (iigs_shrcmapA + 512), .byte1 (iigs_shrcmapA + 256), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0)
              .byte   .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0)
              .byte   .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0)
              .byte   .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0)
              .space  182-47-(. - c26LightSetup) ; retain fsGeneral and slots

fsGeneral:    ldy     ##0
              sta     dp:W_T4
              lda     dp:W_SC
25$:          sta     dp:(W_T4+2)            ; low word
              lda     dp:W_T4                ; high word
              bmi     40$
26$:          iny
              asl     dp:(W_T4+2)
              rol     a
              bpl     26$

40$:          asl     a                     ; RECIP_TABLE[M]
              tax
              lda     long:RECIP_TABLE,x
              sta     dp:W_T4
              tya                           ; shift by s - 22
              sec
              sbc     ##22
              beq     49$
              bcc     45$
              tay
              lda     dp:W_T4
41$:          asl     a
              dey
              bne     41$
              rtl
45$:          eor     ##0xffff              ; right by 22 - s
              inc     a
              cmp     ##16
              bcs     47$
              tay
              lda     dp:W_T4
46$:          lsr     a
              dey
              bne     46$
              rtl
47$:          lda     ##0
              rtl
49$:          lda     dp:W_T4
              rtl

              .section segcode, text
;;; ---------------------------------------------------------------------------
;;; void R_DrawVisSprite(const vissprite_t *vis)
;;; In: _Dp[0-3] = vis. mfloorclip and mceilingclip must be set.
;;; Shadow sprites (no colormap: W_CMP = 0) take the same setup, then the
;;; columns of visColF of src/iigs/r_sprite65.s (K_FUZZ records). For the
;;; others each post becomes a K_TEX record
;;; (visPost), with the rows of the post from YHTAB, which holds for texel
;;; row t of the sprite, E = sprtopscreen + spryscale * t:
;;;   YHTAB[t] = (E - 1) >> FRACBITS               the last row, t = end
;;; The first row of a post, (E + FRACUNIT - 1) >> FRACBITS as topscreen of
;;; R_DrawMaskedColumn, is always YHTAB[t] + 1.
;;; ---------------------------------------------------------------------------
              .public R_DrawVisSprite, visCol, VN_STEP, visDone
              .extern visColD, visColF
R_DrawVisSprite:
              ldx     dp:.tiny _Dp          ; X = vis: its fields are in the near
              lda     abs:OFS_VIS_COLORMAP,x ;   bank, the data bank here; a NULL
              ora     abs:(OFS_VIS_COLORMAP+2),x ; colormap: the shadow drawer
              beq     1$                    ;   (W_CMP = 0: visColF below)
              ;; The fields go straight into the loop page (no copy in near
              ;; variables), and the colormap page is made here as
              ;; R_RenderSegLoop makes W_CMP.
              lda     abs:OFS_VIS_COLORMAP,x ; W_CMP: the page of the SHR
              sec                           ;   colormap A: (colormap -
              sbc     ##.word0 fullcolormap ;   fullcolormap + iigs_shrcmapA)
              clc                           ;   >> 8
              adc     ##.word0 iigs_shrcmapA
              xba                           ; (16-bit store: W_CMP + 1 is 0,
1$:           sta     long:(WPAGE+W_CMP)    ;   not read)
              lda     abs:OFS_VIS_STARTFRAC,x
              sta     long:(WPAGE+V_FRAC)
              lda     abs:(OFS_VIS_STARTFRAC+2),x
              sta     long:(WPAGE+V_FRAC+2)
              lda     abs:OFS_VIS_XISCALE,x
              sta     long:(WPAGE+V_XIS)
              lda     abs:(OFS_VIS_XISCALE+2),x
              sta     long:(WPAGE+V_XIS+2)
              lda     abs:OFS_VIS_X1,x
              asl     a
              sta     long:(WPAGE+W_X2)
              lda     abs:OFS_VIS_SCALE,x   ; spryscale
              sta     long:(WPAGE+V_SS)
              lda     abs:(OFS_VIS_SCALE+2),x
              sta     long:(WPAGE+V_SS+2)
              bne     5$

              ;; sprtopscreen = CENTERY << FRACBITS - FixedMul(texturemid,
              ;; spryscale). For spryscale < 1.0 (its low word SL) the product
              ;; is hi16(TL * SL) + TH * SL (TH signed) with qmul; else FixedMul
              lda     abs:OFS_VIS_SCALE,x   ; MA = SL
              sta     dp:.tiny MA
              lda     abs:OFS_VIS_TEXTUREMID,x ; hi16(TL * SL)
              jsr     .kbank qmul
              sta     dp:.tiny VS_HL
              ldx     dp:.tiny _Dp
              lda     abs:(OFS_VIS_TEXTUREMID+2),x ; + TH * SL: Y = low, C = high
              jsr     .kbank qmul
              ldx     dp:.tiny _Dp          ; TH < 0: - SL << 16
              bit     abs:(OFS_VIS_TEXTUREMID+2),x
              bpl     2$
              sec
              sbc     dp:.tiny MA
2$:           tax
              tya
              clc
              adc     dp:.tiny VS_HL
              bcc     6$
              inx
              bra     6$
5$:           sta     dp:.tiny (_Dp+2)      ; _Dp = spryscale for FixedMul (vis
              stx     dp:.tiny VS_HL        ;   in VS_HL)
              lda     abs:OFS_VIS_SCALE,x
              sta     dp:.tiny _Dp
              ldy     abs:(OFS_VIS_TEXTUREMID+2),x
              lda     abs:OFS_VIS_TEXTUREMID,x
              tyx
              jsl     long:FixedMul
              ldy     dp:.tiny VS_HL        ; _Dp = vis again
              sty     dp:.tiny _Dp
6$:           eor     ##0xffff              ; X:C = the product: sprtopscreen in
              clc                           ;   Y (low word) and X (high word)
              adc     ##1
              tay
              txa
              eor     ##0xffff
              adc     ##CONST_CENTERY
              tax
              tya                           ; the table of rows starts at E =
              clc                           ;   sprtopscreen: E - 1 =
              sbc     long:(WPAGE+V_SS)     ;   sprtopscreen - spryscale - 1
              sta     long:(WPAGE+V_E)
              txa
              sbc     long:(WPAGE+V_SS+2)
              sta     long:YHTABM
              lda     ##0
              sta     long:(WPAGE+V_TN)
              sta     long:(WPAGE+V_UNIT)
              lda     long:(WPAGE+V_SS)
              bne     30$
              lda     long:(WPAGE+V_SS+2)
              cmp     ##1
              bne     30$
              sta     long:(WPAGE+V_UNIT)
              txa                           ; (sprtopscreen - 1) >> FRACBITS
              cpy     ##0
              bne     29$
              dec     a
29$:          sta     long:(WPAGE+V_YH0)
30$:          ldx     dp:.tiny _Dp          ; X = vis
              phd                           ; the direct page of the loop
              lda     ##WPAGE
              tcd
              lda     abs:OFS_VIS_GY,x      ; the patch: vis->gy (R_ProjectSprite
              sta     dp:V_PATCH            ;   of src/iigs/r_thing65.s, pspSprite
              lda     abs:(OFS_VIS_GY+2),x  ;   of src/iigs/r_frame65.s), its bank
              sta     dp:(V_PATCH+2)        ;   with a high byte of 0
              sta     dp:(V_COL+2)
              lda     abs:OFS_VIS_TEXTUREMID,x ; texturemid >> 7
              xba
              asl     a
              lda     abs:(OFS_VIS_TEXTUREMID+1),x
              rol     a
              sta     dp:V_TM7
              ldy     abs:OFS_VIS_FRACSTEP,x ; Y = fracstep
              lda     .near VS_CLIP
              sta     dp:V_CLIP
              lda     .near mfloorclip
              sta     dp:V_FCP
              lda     .near (mfloorclip+2)
              sta     dp:(V_FCP+2)
              lda     .near mceilingclip
              sta     dp:V_CCP
              lda     .near (mceilingclip+2)
              sta     dp:(V_CCP+2)
              lda     [V_PATCH]             ; patch->width (OFS_PATCH_WIDTH 0)
              sta     dp:V_WIDTH

              ;; the first texture position of a post (tierDraw) as
              ;; V_K + lo16(row * fracstep) - (topdelta << 9), the product
              ;; from T (src/iigs/mul.inc): row * fL + (row * fH) << 8
              tya
              lsr     a
              sta     dp:V_S2               ; the step of the records
              tya
              and     ##0x00ff
              asl     a
              QSET    V_QP, V_QM
              tya
              xba
              and     ##0x00ff
              asl     a
              QSET    V_QP2, V_QM2          ; (their banks and the zero high
              ldy     ##(2 * (CONST_CENTERY + 1)) ;   bytes: dvInit of
              lda     [V_QP2],y             ;   src/iigs/r_frame65.s)
              sec                           ; V_K = texturemid >> 7
              sbc     [V_QM2],y             ;   - lo16((CENTERY + 1) * fracstep):
              xba                           ;   (row * fH) << 8 + row * fL
              and     ##0xff00
              clc
              adc     [V_QP],y
              sec
              sbc     [V_QM],y
              eor     ##0xffff
              sec
              adc     dp:V_TM7
              sta     dp:V_K

              phb                           ; the data bank of the records (PEA
              pea     #(RECBANK * 0x0101)   ;   and two PLB: no REP/SEP)
              plb
              plb
              lda     dp:W_CMP              ; a shadow sprite: its own columns
              beq     96$                   ;   (no weapon skip, as before)
              lda     dp:W_WSK              ; a frame that skips the weapon
              beq     95$                   ;   rows: the sprite ends above
              jsl     long:wclipSprite      ;   them (src/iigs/r_frame65.s)
95$:          jmp     long:visColD          ; (magnified sprites: the loop of
96$:          jmp     long:visColF          ;   src/iigs/r_frame65.s)
              .space  43                    ; (visCol keeps its cache slots)

;;; CVSETB first, end: CVSET of lists.inc when B holds the high byte of Y
;;; (the page of the record, from the COLW loads before it): TYA with 8-bit
;;; A leaves B, so no REP/SEP pair (each costs a slow cycle).
CVSETB        .macro  first, end
              lda     long:(CV_ROW+1),x     ; the rows of the range (255:
              sec                           ;   none can come)
              sbc     long:CV_ROW,x
              clc                           ; + first >= end: not more rows
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

;;; visCol: column W_X2 / 2 of the sprite: its clips, its posts (visPost),
;;; then the next column (visNext). The rows are bytes, with 8-bit stores;
;;; the column loop stays in 8-bit A (visCol8) but for the post pointer
;;; (REP and SEP cost a slow cycle each).
visCol:       sep     #0x20                 ; (16-bit A from the setup)
visCol8:      ldy     dp:W_X2
              cpy     ##(2 * CONST_VIEWWIDTH)
              bcc     1$
              brl     visDone
1$:           lda     [V_FCP],y             ; the rows the clips leave: V_LO
                                            ;   to V_HI - 1 (the arrays hold the
              beq     visNext               ;   clips + 1)
              dec     a
              sta     dp:V_HI
              lda     [V_CCP],y
              sta     dp:V_LO
              cmp     dp:V_HI               ; no free row: the next column
              bcs     visNext
              rep     #0x20
              lda     dp:(V_FRAC+2)         ; column = patch + columnofs[frac >> FRACBITS]
              asl     a
              asl     a
              adc     ##OFS_PATCH_COLUMNOFS ; (carry clear)
              tay
              lda     [V_PATCH],y
              clc
              adc     dp:V_PATCH
              sep     #0x20
              sta     dp:V_COL
              xba
              sta     dp:(V_COL+1)
              lda     #0xfe                 ; the clip pass of the weapon: no run
              sta     dp:V_PYH              ;   yet
              bra     visPost

;;; visNext: frac += xiscale, the next column. 8-bit A throughout.
visNext:      STEP8F  V_FRAC, V_XIS
              bmi     visDone               ; frac < 0
              bne     7$                    ; (frac >> FRACBITS) >= 256
              lda     dp:(V_FRAC+2)         ; (frac >> FRACBITS) >= width: the
              cmp     dp:V_WIDTH            ;   low bytes, then a width of 256
              bcc     2$                    ;   or more
              lda     dp:(V_WIDTH+1)
              beq     visDone
2$:           lda     dp:W_X2
              clc
              adc     #2                    ; (4 in the half view: vcHalf of
VN_STEP       .equ    . - 1                 ;   src/iigs/r_thing65.s)
              sta     dp:W_X2
              bcc     visCol8
              inc     dp:(W_X2+1)
              bra     visCol8
7$:           rep     #0x20                 ; a column of 256 or more: the
              lda     dp:(V_FRAC+2)         ;   16-bit compare
              cmp     dp:V_WIDTH
              sep     #0x20
              bcc     2$
visDone:      rep     #0x20
              plb
              pld
              rtl

;;; visPost: the post at V_COL, then the next one; visNext after the last.
;;; 8-bit A. The rows of the post: yl = YHTAB[topdelta] + 1 to yh =
;;; YHTAB[topdelta + length], the rows V_LO .. V_HI - 1 of them.
;;; visAdv: the next post, V_COL += length + 4.
visSkip:      sep     #0x20
visAdv:       lda     dp:V_LEN
              clc
              adc     #4
              bcc     1$
              inc     dp:(V_COL+1)
              clc
1$:           adc     dp:V_COL
              sta     dp:V_COL
              bcc     visPost
              inc     dp:(V_COL+1)
visPost:      lda     [V_COL]               ; topdelta, 0xff: no more posts
              cmp     #0xff
              beq     visNext
              sta     dp:V_TD
              ldy     ##1
              lda     [V_COL],y             ; length
              sta     dp:V_LEN
              rep     #0x20
              lda     dp:V_TD               ; yh: none when above V_LO, then
              clc                           ;   V_YH1 = min(yh + 1, V_HI)
              adc     dp:V_LEN
              ldx     dp:V_UNIT
              bne     2$
              cmp     dp:V_TN               ; (YHTAB up to the row)
              bcc     1$
              jsr     .kbank visFill
1$:           asl     a
              tax
              lda     long:YHTAB,x
              bra     3$
2$:           clc                           ; spryscale = FRACUNIT: V_YH0 + t
              adc     dp:V_YH0
3$:           bmi     visSkip
              cmp     dp:V_LO
              bcc     visSkip
              cmp     dp:V_HI
              bcc     4$
              lda     dp:V_HI
              dec     a
4$:           inc     a
              sta     dp:V_YH1              ; (16-bit, no REP/SEP: its high byte 0)
              lda     dp:V_TD               ; yl: none when V_HI or more, then
              ldx     dp:V_UNIT             ;   V_YL = max(yl, V_LO)
              bne     5$
              asl     a
              tax
              lda     long:YHTAB,x
              bra     6$
5$:           clc
              adc     dp:V_YH0
6$:           bmi     61$
              inc     a
              cmp     dp:V_HI
              bcs     visSkip
              cmp     dp:V_LO
              bcs     62$
61$:          lda     dp:V_LO
62$:          sep     #0x20
              sta     dp:V_YL
              lda     dp:V_YH1              ; the count of rows
              sec
              sbc     dp:V_YL
              beq     7$
              bcs     71$
7$:           brl     visAdv
71$:          ldx     dp:V_CLIP
              beq     11$
              brl     30$
18$:          rep     #0x20                 ; an extra page first
              jsl     long:newPage          ; Y = the free byte of the new page
              tya
              sep     #0x20
              clc
              bra     13$
              ;; the post as a K_TEX record at the end of the list of the
              ;; column
11$:          ldx     dp:W_X2               ; the fill spans of the column
              FSCUT   dp:V_YL, dp:V_YH1     ;   end at the post (lists.inc)
              lda     long:(COLW+1),x       ; Y = the free byte of the list (two
              xba                           ;   8-bit loads: no REP/SEP)
              lda     long:COLW,x
              tay
              cmp     #(PAGE_ROOM - TEX_SIZE + 1) ; no room in the page: an
              bcs     18$                   ;   extra page first
13$:          adc     #TEX_SIZE             ; (carry clear)
              sta     long:COLW,x           ; COLW past the record
              CVSETB  dp:V_YL, dp:V_YH1     ; (B: the page, from the COLW loads)
              tyx                           ; X = the record
              lda     #K_TEX
              sta     abs:R_KIND,x
              lda     dp:V_YL               ; the rows: the first, the row after
              sta     abs:R_ROW,x           ;   the last
              lda     dp:V_YH1
              sta     abs:R_END,x
              rep     #0x20                 ; Y = 2 * the first row; the frac
              lda     dp:V_YL               ;   of the row in 16-bit (one REP,
              asl     a                     ;   one SEP)
              tay
              lda     [V_QP2],y             ; ((row * fH - 2 * topdelta) & 0xff)
              sec                           ;   << 8
              sbc     [V_QM2],y
              sec
              sbc     dp:V_TD
              sec
              sbc     dp:V_TD
              xba
              and     ##0xff00
              clc                           ; + V_K
              adc     dp:V_K
              clc                           ; + row * fL (QPROD)
              adc     [V_QP],y
              sec
              sbc     [V_QM],y
              lsr     a                     ; frac >> 1: TF, TI
              sep     #0x20
              sta     abs:R_TF,x
              xba
              sta     abs:R_TI,x
              lda     dp:V_S2               ; fracstep >> 1: SF, SI
              sta     abs:R_SF,x
              lda     dp:(V_S2+1)
              sta     abs:R_SI,x
              lda     dp:V_COL              ; the texels: the post + 3
              clc
              adc     #3
              sta     abs:R_SRC,x
              lda     dp:(V_COL+1)
              adc     #0
              sta     abs:(R_SRC+1),x
              lda     dp:(V_COL+2)
              sta     abs:(R_SRC+2),x
              lda     dp:W_CMP              ; the colormap of the even rows
              sta     abs:R_CMP,x
              brl     visAdv

8$:           brl     visAdv
              .space  11                    ; (the clip pass and visFill keep
                                            ;   their addresses)

              ;; the clip pass of the weapon: its posts are opaque; a run of
              ;; them that reaches the floor clip of the column (the view
              ;; bottom) is drawn over all the rows from its first one down,
              ;; last in the frame, so floorclip of the column starts there:
              ;; no wall, floor or ceiling draws those rows
30$:          lda     dp:V_PYH              ; a new run unless the post goes on
              inc     a                     ;   from the one above
              cmp     dp:V_YL
              beq     31$
              lda     dp:V_YL
              sta     dp:V_RUN
31$:          lda     dp:V_YH1              ; the last row of the post
              dec     a
              sta     dp:V_PYH
              inc     a
              cmp     dp:V_HI
              bne     8$
              ldx     dp:W_X2
              lda     dp:V_RUN              ; (floorclip holds the clip + 1)
              inc     a
              cmp     long:floorclip,x
              bcs     8$
              sta     long:floorclip,x
              bra     8$

;;; visFill: YHTAB for texel rows V_TN..C. C is kept. V_E holds the low
;;; word of E - 1 of the row before, YHTAB[V_TN - 1] its high word (YHTABM
;;; for row 0).
visFill:      nop                           ; (C comes back from X at the end)
              asl     a
              sta     dp:V_TEND
              lda     dp:V_TN
              asl     a
              tax
              ldy     dp:V_E
1$:           tya                           ; E += spryscale
              clc
              adc     dp:V_SS
              tay
              lda     long:(YHTAB-2),x
              adc     dp:(V_SS+2)
              sta     long:YHTAB,x
              inx
              inx
              cpx     dp:V_TEND
              bcc     1$
              beq     1$
              sty     dp:V_E
              txa
              lsr     a
              sta     dp:V_TN
              dec     a                     ; C: X / 2 is C + 1
              rts

              .section cfar, rodata
              .public PGT
;;; PGT[i]: the page of the SHR colormap startmap - d for i = startmap + 24
;;; - d (SMAP of src/iigs/r_bsp65.s), clamped to 0..31.
PGT:
              .byte   .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0)
              .byte   .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0)
              .byte   .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0)
              .byte   .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0)
              .byte   .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0)
              .byte   .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 0)
              .byte   .byte1 (iigs_shrcmapA + 0), .byte1 (iigs_shrcmapA + 256), .byte1 (iigs_shrcmapA + 512), .byte1 (iigs_shrcmapA + 768)
              .byte   .byte1 (iigs_shrcmapA + 1024), .byte1 (iigs_shrcmapA + 1280), .byte1 (iigs_shrcmapA + 1536), .byte1 (iigs_shrcmapA + 1792)
              .byte   .byte1 (iigs_shrcmapA + 2048), .byte1 (iigs_shrcmapA + 2304), .byte1 (iigs_shrcmapA + 2560), .byte1 (iigs_shrcmapA + 2816)
              .byte   .byte1 (iigs_shrcmapA + 3072), .byte1 (iigs_shrcmapA + 3328), .byte1 (iigs_shrcmapA + 3584), .byte1 (iigs_shrcmapA + 3840)
              .byte   .byte1 (iigs_shrcmapA + 4096), .byte1 (iigs_shrcmapA + 4352), .byte1 (iigs_shrcmapA + 4608), .byte1 (iigs_shrcmapA + 4864)
              .byte   .byte1 (iigs_shrcmapA + 5120), .byte1 (iigs_shrcmapA + 5376), .byte1 (iigs_shrcmapA + 5632), .byte1 (iigs_shrcmapA + 5888)
              .byte   .byte1 (iigs_shrcmapA + 6144), .byte1 (iigs_shrcmapA + 6400), .byte1 (iigs_shrcmapA + 6656), .byte1 (iigs_shrcmapA + 6912)
              .byte   .byte1 (iigs_shrcmapA + 7168), .byte1 (iigs_shrcmapA + 7424), .byte1 (iigs_shrcmapA + 7680), .byte1 (iigs_shrcmapA + 7936)
              .byte   .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936)
              .byte   .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936)
              .byte   .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936)
              .byte   .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936)
              .byte   .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936)
              .byte   .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936)
              .byte   .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936)
              .byte   .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936), .byte1 (iigs_shrcmapA + 7936)

;;; ---------------------------------------------------------------------------
;;; needColumns (tierMake): the column tables of texture C (0: none), made
;;; with R_MakeTextureColumns (r_draw.c) if needed. C code environment.
;;; ---------------------------------------------------------------------------
              .section halflist, rodata     ; (src/iigs/iigs.scm: the half view)
;;; SEGPATCH: the patches of R_SegHalf (src/iigs/r_list65.s): each the
;;; address (in the bank of R_RenderSegLoop), the byte count, the bytes of
;;; the full view and of the half view (3 each); 0: the end.
              .public SEGPATCH
SEGPATCH:     .word   .word0 SH_P1          ; CMP rw_stopx / JSR halfStart
              .byte   3
              .byte   0xcd, .byte0 rw_stopx, .byte1 rw_stopx
              .byte   0x20, .byte0 halfStart, .byte1 halfStart
              .word   .word0 SH_P2          ; LDA SL_X0 / JSR halfSeg
              .byte   3
              .byte   0xad, .byte0 SL_X0, .byte1 SL_X0
              .byte   0x20, .byte0 halfSeg, .byte1 halfSeg
              .word   .word0 SH_VT          ; JMP (varTab,x) / (varTabH,x)
              .byte   2
              .word   .word0 varTab
              .byte   0
              .word   .word0 varTabH
              .byte   0
SH_SD         .equ    segDone + 10          ; (its LDA long:SL_X0)
              .word   .word0 SH_SD          ; LDA long:SL_X0 / JSR segX0H, NOP
              .byte   2
              .byte   0xaf, .byte0 SL_X0, 0
              .byte   0x20, .byte0 segX0H, 0
              .word   .word0 (SH_SD + 2)
              .byte   2
              .byte   .byte1 SL_X0, .byte2 SL_X0, 0
              .byte   .byte1 segX0H, 0xea, 0
SH_SE         .equ    segDone + 15          ; (its LDA W_X2END, LSR)
              .word   .word0 SH_SE          ; LDA W_X2END, LSR / JSR segEndH
              .byte   3
              .byte   0xa5, W_X2END, 0x4a
              .byte   0x20, .byte0 segEndH, .byte1 segEndH
              .word   .word0 solidColumn    ; TXA, LSR, TAX / JMP solidColumnH
              .byte   3
              .byte   0x8a, 0x4a, 0xaa
              .byte   0x4c, .byte0 solidColumnH, .byte1 solidColumnH
              .word   .word0 SH_TC1         ; texCol: the column after, the
              .byte   2                     ;   columns of a span
              .word   2
              .byte   0
              .word   4
              .byte   0
              .word   .word0 SH_TL          ;   (the half view: spans of TC_N / 2
              .byte   2                     ;   even columns, TC_N columns as in
              .word   TC_LOG                ;   the full view)
              .byte   0
              .word   TC_LOG - 1
              .byte   0
              .word   .word0 SH_TC3
              .byte   2
              .word   2 * TC_N - 4
              .byte   0
              .word   2 * TC_N - 8
              .byte   0
              .word   .word0 SH_TC4
              .byte   2
              .word   2
              .byte   0
              .word   4
              .byte   0
              .word   .word0 (v04br + 1)    ; BRL v04col / v04nextH
              .byte   2
              .word   v04col - (v04br + 3)
              .byte   0
              .word   v04nextH - (v04br + 3)
              .byte   0
              .word   .word0 v05br          ; BRL v05col / JMP v05nextH
              .byte   3
              .byte   0x82
              .word   v05col - (v05br + 3)
              .byte   0x4c, .byte0 v05nextH, .byte1 v05nextH
              .word   .word0 v06br          ; BRL v06col / JMP v06nextH
              .byte   3
              .byte   0x82
              .word   v06col - (v06br + 3)
              .byte   0x4c, .byte0 v06nextH, .byte1 v06nextH
              .word   .word0 v08br          ; BRL v08col / JMP v08nextH
              .byte   3
              .byte   0x82
              .word   v08col - (v08br + 3)
              .byte   0x4c, .byte0 v08nextH, .byte1 v08nextH
              .word   .word0 v10br          ; BRL v10col / JMP v10nextH
              .byte   3
              .byte   0x82
              .word   v10col - (v10br + 3)
              .byte   0x4c, .byte0 v10nextH, .byte1 v10nextH
              .word   .word0 v12br          ; BRL v12col / JMP v12nextH
              .byte   3
              .byte   0x82
              .word   v12col - (v12br + 3)
              .byte   0x4c, .byte0 v12nextH, .byte1 v12nextH
              .word   .word0 v13br          ; BRL v13col / JMP v13nextH
              .byte   3
              .byte   0x82
              .word   v13col - (v13br + 3)
              .byte   0x4c, .byte0 v13nextH, .byte1 v13nextH
              .word   .word0 v14br          ; BRL v14col / JMP v14nextH
              .byte   3
              .byte   0x82
              .word   v14col - (v14br + 3)
              .byte   0x4c, .byte0 v14nextH, .byte1 v14nextH
              .word   .word0 v15br          ; BRL v15col / JMP v15nextH
              .byte   3
              .byte   0x82
              .word   v15col - (v15br + 3)
              .byte   0x4c, .byte0 v15nextH, .byte1 v15nextH
              .word   .word0 v20br          ; BRL v20col / JMP v20nextH
              .byte   3
              .byte   0x82
              .word   v20col - (v20br + 3)
              .byte   0x4c, .byte0 v20nextH, .byte1 v20nextH
              .word   .word0 v28br          ; BRL v28col / JMP v28nextH
              .byte   3
              .byte   0x82
              .word   v28col - (v28br + 3)
              .byte   0x4c, .byte0 v28nextH, .byte1 v28nextH
              .word   .word0 v02br          ; BRL v02col / JMP v02nextH (segmore:
              .byte   3                     ;   a BRL across sections has no
              .byte   0x82                  ;   object format)
              .word   v02col - (v02br + 3)
              .byte   0x4c, .byte0 v02nextH, .byte1 v02nextH
              .word   .word0 v07br          ; BRL v07col / JMP v07nextH
              .byte   3
              .byte   0x82
              .word   v07col - (v07br + 3)
              .byte   0x4c, .byte0 v07nextH, .byte1 v07nextH
              .word   0

;;; SEGPATCHT: the patches of the 2/3 view (R_ViewMode of
;;; src/iigs/r_list65.s), as SEGPATCH: the bytes of the full view, then of
;;; the 2/3 view.
              .public SEGPATCHT
SEGPATCHT:    .word   .word0 SH_P1          ; CMP rw_stopx / JSR thirdStart
              .byte   3
              .byte   0xcd, .byte0 rw_stopx, .byte1 rw_stopx
              .byte   0x20, .byte0 thirdStart, .byte1 thirdStart
              .word   .word0 SH_P2          ; LDA SL_X0 / JSR thirdSeg
              .byte   3
              .byte   0xad, .byte0 SL_X0, .byte1 SL_X0
              .byte   0x20, .byte0 thirdSeg, .byte1 thirdSeg
              .word   .word0 SH_VT          ; JMP (varTab,x) / (varTabT,x)
              .byte   2
              .word   .word0 varTab
              .byte   0
              .word   .word0 varTabT
              .byte   0
              .word   .word0 SH_SD          ; LDA long:SL_X0 / JSR segX0H, NOP
              .byte   2
              .byte   0xaf, .byte0 SL_X0, 0
              .byte   0x20, .byte0 segX0H, 0
              .word   .word0 (SH_SD + 2)
              .byte   2
              .byte   .byte1 SL_X0, .byte2 SL_X0, 0
              .byte   .byte1 segX0H, 0xea, 0
              .word   .word0 SH_SE          ; LDA W_X2END, LSR / JSR segEndT
              .byte   3
              .byte   0xa5, W_X2END, 0x4a
              .byte   0x20, .byte0 segEndT, .byte1 segEndT
              .word   .word0 solidColumn    ; TXA, LSR, TAX / JMP solidColumnT
              .byte   3
              .byte   0x8a, 0x4a, 0xaa
              .byte   0x4c, .byte0 solidColumnT, .byte1 solidColumnT
              .word   .word0 v04br          ; BRL v04col / JMP v04nextT
              .byte   3
              .byte   0x82
              .word   v04col - (v04br + 3)
              .byte   0x4c, .byte0 v04nextT, .byte1 v04nextT
              .word   .word0 v05br          ; BRL v05col / JMP v05nextT
              .byte   3
              .byte   0x82
              .word   v05col - (v05br + 3)
              .byte   0x4c, .byte0 v05nextT, .byte1 v05nextT
              .word   .word0 v06br          ; BRL v06col / JMP v06nextT
              .byte   3
              .byte   0x82
              .word   v06col - (v06br + 3)
              .byte   0x4c, .byte0 v06nextT, .byte1 v06nextT
              .word   .word0 v08br          ; BRL v08col / JMP v08nextT
              .byte   3
              .byte   0x82
              .word   v08col - (v08br + 3)
              .byte   0x4c, .byte0 v08nextT, .byte1 v08nextT
              .word   .word0 v10br          ; BRL v10col / JMP v10nextT
              .byte   3
              .byte   0x82
              .word   v10col - (v10br + 3)
              .byte   0x4c, .byte0 v10nextT, .byte1 v10nextT
              .word   .word0 v12br          ; BRL v12col / JMP v12nextT
              .byte   3
              .byte   0x82
              .word   v12col - (v12br + 3)
              .byte   0x4c, .byte0 v12nextT, .byte1 v12nextT
              .word   .word0 v13br          ; BRL v13col / JMP v13nextT
              .byte   3
              .byte   0x82
              .word   v13col - (v13br + 3)
              .byte   0x4c, .byte0 v13nextT, .byte1 v13nextT
              .word   .word0 v14br          ; BRL v14col / JMP v14nextT
              .byte   3
              .byte   0x82
              .word   v14col - (v14br + 3)
              .byte   0x4c, .byte0 v14nextT, .byte1 v14nextT
              .word   .word0 v15br          ; BRL v15col / JMP v15nextT
              .byte   3
              .byte   0x82
              .word   v15col - (v15br + 3)
              .byte   0x4c, .byte0 v15nextT, .byte1 v15nextT
              .word   .word0 v20br          ; BRL v20col / JMP v20nextT
              .byte   3
              .byte   0x82
              .word   v20col - (v20br + 3)
              .byte   0x4c, .byte0 v20nextT, .byte1 v20nextT
              .word   .word0 v28br          ; BRL v28col / JMP v28nextT
              .byte   3
              .byte   0x82
              .word   v28col - (v28br + 3)
              .byte   0x4c, .byte0 v28nextT, .byte1 v28nextT
              .word   .word0 v02br          ; BRL v02col / JMP v02nextT
              .byte   3
              .byte   0x82
              .word   v02col - (v02br + 3)
              .byte   0x4c, .byte0 v02nextT, .byte1 v02nextT
              .word   .word0 v07br          ; BRL v07col / JMP v07nextT
              .byte   3
              .byte   0x82
              .word   v07col - (v07br + 3)
              .byte   0x4c, .byte0 v07nextT, .byte1 v07nextT
              .word   0

              .section bspcode, text
needColumns:  tay
              beq     1$
              asl     a
              asl     a
              tax
              lda     long:(COLDIR+2),x     ; bank | widthmask << 8, 0: not made
              bne     1$
              tya
              jsl     long:R_MakeTextureColumns
1$:           rtl


;;; ---------------------------------------------------------------------------
;;; int16_t R_CheckSegPage(void): 0 if the direct page of the C code has the
;;; layout that WPAGE needs: at $0900 with the DC_* inputs of the drawers
;;; below 0x2c, and the colormaps of the drawers in one bank, B right after
;;; A (the K_TEX records of src/iigs/r_list65.s hold only the page of A),
;;; page aligned.
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public R_CheckSegPage
R_CheckSegPage:
              lda     ##.word0 _DirectPageStart
              cmp     ##0x0900
              bne     9$
              lda     ##.word0 DC_FLATW     ; the last of the drawer inputs
              cmp     ##(0x0900 + W_TF - 1)
              bcs     9$
              lda     ##.word2 iigs_shrcmapA
              cmp     ##.word2 (iigs_shrcmapB + 34 * 256 - 1)
              bne     9$
              lda     ##.word0 iigs_shrcmapB
              sec
              sbc     ##.word0 iigs_shrcmapA
              cmp     ##(34 * 256)
              bne     9$
              lda     ##.word0 iigs_shrcmapA ; page aligned (texBlocks of
              and     ##0x00ff              ;   tools/gendraw.py)
              bne     9$
              lda     ##0
              rtl
9$:           lda     ##1
              rtl

;;; The tangent of the fine angles 2048-3071 (16 bits: the angles near 90
;;; degrees below) and 3072-4095 (fixed_t), for the texture column of a
;;; wall (finetangentTable_part_3 and _part_4 of r_draw.c).
              .section cnear, rodata
              .public finetangentTable_part_3, finetangentTable_part_4
finetangentTable_part_3:
              .word   25, 75, 125, 175, 226, 276, 326, 376
              .word   427, 477, 527, 578, 628, 678, 728, 779
              .word   829, 879, 929, 980, 1030, 1080, 1131, 1181
              .word   1231, 1281, 1332, 1382, 1432, 1483, 1533, 1583
              .word   1633, 1684, 1734, 1784, 1835, 1885, 1935, 1986
              .word   2036, 2086, 2137, 2187, 2237, 2288, 2338, 2388
              .word   2439, 2489, 2539, 2590, 2640, 2690, 2741, 2791
              .word   2841, 2892, 2942, 2992, 3043, 3093, 3144, 3194
              .word   3244, 3295, 3345, 3395, 3446, 3496, 3547, 3597
              .word   3648, 3698, 3748, 3799, 3849, 3900, 3950, 4001
              .word   4051, 4101, 4152, 4202, 4253, 4303, 4354, 4404
              .word   4455, 4505, 4556, 4606, 4657, 4707, 4758, 4808
              .word   4859, 4910, 4960, 5011, 5061, 5112, 5162, 5213
              .word   5264, 5314, 5365, 5415, 5466, 5517, 5567, 5618
              .word   5668, 5719, 5770, 5820, 5871, 5922, 5972, 6023
              .word   6074, 6124, 6175, 6226, 6277, 6327, 6378, 6429
              .word   6480, 6530, 6581, 6632, 6683, 6733, 6784, 6835
              .word   6886, 6937, 6988, 7038, 7089, 7140, 7191, 7242
              .word   7293, 7344, 7395, 7445, 7496, 7547, 7598, 7649
              .word   7700, 7751, 7802, 7853, 7904, 7955, 8006, 8057
              .word   8108, 8159, 8210, 8261, 8312, 8363, 8414, 8466
              .word   8517, 8568, 8619, 8670, 8721, 8772, 8824, 8875
              .word   8926, 8977, 9028, 9080, 9131, 9182, 9233, 9285
              .word   9336, 9387, 9438, 9490, 9541, 9592, 9644, 9695
              .word   9747, 9798, 9849, 9901, 9952, 10004, 10055, 10106
              .word   10158, 10209, 10261, 10312, 10364, 10415, 10467, 10519
              .word   10570, 10622, 10673, 10725, 10777, 10828, 10880, 10931
              .word   10983, 11035, 11086, 11138, 11190, 11242, 11293, 11345
              .word   11397, 11449, 11501, 11552, 11604, 11656, 11708, 11760
              .word   11812, 11864, 11916, 11967, 12019, 12071, 12123, 12175
              .word   12227, 12279, 12331, 12383, 12436, 12488, 12540, 12592
              .word   12644, 12696, 12748, 12800, 12853, 12905, 12957, 13009
              .word   13062, 13114, 13166, 13218, 13271, 13323, 13375, 13428
              .word   13480, 13533, 13585, 13637, 13690, 13742, 13795, 13847
              .word   13900, 13952, 14005, 14057, 14110, 14163, 14215, 14268
              .word   14321, 14373, 14426, 14479, 14531, 14584, 14637, 14690
              .word   14743, 14795, 14848, 14901, 14954, 15007, 15060, 15113
              .word   15166, 15219, 15272, 15325, 15378, 15431, 15484, 15537
              .word   15590, 15643, 15696, 15749, 15802, 15856, 15909, 15962
              .word   16015, 16069, 16122, 16175, 16229, 16282, 16335, 16389
              .word   16442, 16496, 16549, 16603, 16656, 16710, 16763, 16817
              .word   16870, 16924, 16977, 17031, 17085, 17138, 17192, 17246
              .word   17300, 17353, 17407, 17461, 17515, 17569, 17623, 17677
              .word   17731, 17784, 17838, 17892, 17946, 18001, 18055, 18109
              .word   18163, 18217, 18271, 18325, 18380, 18434, 18488, 18542
              .word   18597, 18651, 18705, 18760, 18814, 18868, 18923, 18977
              .word   19032, 19086, 19141, 19195, 19250, 19305, 19359, 19414
              .word   19469, 19523, 19578, 19633, 19688, 19742, 19797, 19852
              .word   19907, 19962, 20017, 20072, 20127, 20182, 20237, 20292
              .word   20347, 20402, 20457, 20513, 20568, 20623, 20678, 20734
              .word   20789, 20844, 20900, 20955, 21010, 21066, 21121, 21177
              .word   21232, 21288, 21343, 21399, 21455, 21510, 21566, 21622
              .word   21678, 21733, 21789, 21845, 21901, 21957, 22013, 22069
              .word   22125, 22181, 22237, 22293, 22349, 22405, 22461, 22517
              .word   22573, 22630, 22686, 22742, 22799, 22855, 22911, 22968
              .word   23024, 23081, 23137, 23194, 23250, 23307, 23364, 23420
              .word   23477, 23534, 23591, 23647, 23704, 23761, 23818, 23875
              .word   23932, 23989, 24046, 24103, 24160, 24217, 24274, 24331
              .word   24389, 24446, 24503, 24560, 24618, 24675, 24732, 24790
              .word   24847, 24905, 24962, 25020, 25078, 25135, 25193, 25251
              .word   25308, 25366, 25424, 25482, 25540, 25598, 25656, 25714
              .word   25772, 25830, 25888, 25946, 26004, 26062, 26120, 26179
              .word   26237, 26295, 26354, 26412, 26471, 26529, 26588, 26646
              .word   26705, 26763, 26822, 26881, 26940, 26998, 27057, 27116
              .word   27175, 27234, 27293, 27352, 27411, 27470, 27529, 27588
              .word   27647, 27707, 27766, 27825, 27884, 27944, 28003, 28063
              .word   28122, 28182, 28241, 28301, 28361, 28420, 28480, 28540
              .word   28600, 28660, 28719, 28779, 28839, 28899, 28959, 29020
              .word   29080, 29140, 29200, 29260, 29321, 29381, 29441, 29502
              .word   29562, 29623, 29683, 29744, 29805, 29865, 29926, 29987
              .word   30048, 30108, 30169, 30230, 30291, 30352, 30413, 30474
              .word   30536, 30597, 30658, 30719, 30781, 30842, 30904, 30965
              .word   31026, 31088, 31150, 31211, 31273, 31335, 31396, 31458
              .word   31520, 31582, 31644, 31706, 31768, 31830, 31892, 31955
              .word   32017, 32079, 32141, 32204, 32266, 32329, 32391, 32454
              .word   32516, 32579, 32642, 32705, 32767, 32830, 32893, 32956
              .word   33019, 33082, 33145, 33208, 33272, 33335, 33398, 33461
              .word   33525, 33588, 33652, 33715, 33779, 33843, 33906, 33970
              .word   34034, 34098, 34162, 34225, 34289, 34354, 34418, 34482
              .word   34546, 34610, 34675, 34739, 34803, 34868, 34932, 34997
              .word   35062, 35126, 35191, 35256, 35321, 35385, 35450, 35515
              .word   35580, 35646, 35711, 35776, 35841, 35907, 35972, 36037
              .word   36103, 36168, 36234, 36300, 36365, 36431, 36497, 36563
              .word   36629, 36695, 36761, 36827, 36893, 36959, 37026, 37092
              .word   37158, 37225, 37291, 37358, 37425, 37491, 37558, 37625
              .word   37692, 37759, 37826, 37893, 37960, 38027, 38094, 38161
              .word   38229, 38296, 38364, 38431, 38499, 38566, 38634, 38702
              .word   38770, 38837, 38905, 38973, 39042, 39110, 39178, 39246
              .word   39314, 39383, 39451, 39520, 39588, 39657, 39726, 39794
              .word   39863, 39932, 40001, 40070, 40139, 40208, 40278, 40347
              .word   40416, 40486, 40555, 40625, 40694, 40764, 40834, 40904
              .word   40973, 41043, 41113, 41184, 41254, 41324, 41394, 41465
              .word   41535, 41605, 41676, 41747, 41817, 41888, 41959, 42030
              .word   42101, 42172, 42243, 42314, 42385, 42457, 42528, 42600
              .word   42671, 42743, 42814, 42886, 42958, 43030, 43102, 43174
              .word   43246, 43318, 43390, 43463, 43535, 43608, 43680, 43753
              .word   43826, 43898, 43971, 44044, 44117, 44190, 44263, 44337
              .word   44410, 44483, 44557, 44630, 44704, 44778, 44851, 44925
              .word   44999, 45073, 45147, 45221, 45296, 45370, 45444, 45519
              .word   45593, 45668, 45743, 45818, 45892, 45967, 46042, 46118
              .word   46193, 46268, 46343, 46419, 46494, 46570, 46646, 46721
              .word   46797, 46873, 46949, 47025, 47102, 47178, 47254, 47331
              .word   47407, 47484, 47560, 47637, 47714, 47791, 47868, 47945
              .word   48022, 48100, 48177, 48255, 48332, 48410, 48488, 48565
              .word   48643, 48721, 48799, 48878, 48956, 49034, 49113, 49191
              .word   49270, 49349, 49427, 49506, 49585, 49664, 49744, 49823
              .word   49902, 49982, 50061, 50141, 50221, 50300, 50380, 50460
              .word   50540, 50621, 50701, 50781, 50862, 50942, 51023, 51104
              .word   51185, 51266, 51347, 51428, 51509, 51591, 51672, 51754
              .word   51835, 51917, 51999, 52081, 52163, 52245, 52327, 52410
              .word   52492, 52575, 52657, 52740, 52823, 52906, 52989, 53072
              .word   53156, 53239, 53322, 53406, 53490, 53574, 53657, 53741
              .word   53826, 53910, 53994, 54079, 54163, 54248, 54333, 54417
              .word   54502, 54587, 54673, 54758, 54843, 54929, 55015, 55100
              .word   55186, 55272, 55358, 55444, 55531, 55617, 55704, 55790
              .word   55877, 55964, 56051, 56138, 56225, 56312, 56400, 56487
              .word   56575, 56663, 56751, 56839, 56927, 57015, 57104, 57192
              .word   57281, 57369, 57458, 57547, 57636, 57725, 57815, 57904
              .word   57994, 58083, 58173, 58263, 58353, 58443, 58534, 58624
              .word   58715, 58805, 58896, 58987, 59078, 59169, 59261, 59352
              .word   59444, 59535, 59627, 59719, 59811, 59903, 59996, 60088
              .word   60181, 60273, 60366, 60459, 60552, 60646, 60739, 60833
              .word   60926, 61020, 61114, 61208, 61302, 61396, 61491, 61585
              .word   61680, 61775, 61870, 61965, 62060, 62156, 62251, 62347
              .word   62443, 62539, 62635, 62731, 62828, 62924, 63021, 63118
              .word   63215, 63312, 63409, 63506, 63604, 63702, 63799, 63897
              .word   63996, 64094, 64192, 64291, 64389, 64488, 64587, 64687
              .word   64786, 64885, 64985, 65085, 65185, 65285, 65385, 65485
finetangentTable_part_4:
              .long   0x00010032, 0x00010096, 0x000100fb, 0x00010160
              .long   0x000101c5, 0x0001022b, 0x00010290, 0x000102f6
              .long   0x0001035c, 0x000103c2, 0x00010428, 0x0001048e
              .long   0x000104f4, 0x0001055b, 0x000105c2, 0x00010629
              .long   0x00010690, 0x000106f7, 0x0001075e, 0x000107c6
              .long   0x0001082d, 0x00010895, 0x000108fd, 0x00010966
              .long   0x000109ce, 0x00010a37, 0x00010a9f, 0x00010b08
              .long   0x00010b71, 0x00010bda, 0x00010c44, 0x00010cad
              .long   0x00010d17, 0x00010d81, 0x00010deb, 0x00010e55
              .long   0x00010ec0, 0x00010f2a, 0x00010f95, 0x00011000
              .long   0x0001106b, 0x000110d6, 0x00011142, 0x000111ad
              .long   0x00011219, 0x00011285, 0x000112f1, 0x0001135e
              .long   0x000113ca, 0x00011437, 0x000114a4, 0x00011511
              .long   0x0001157e, 0x000115eb, 0x00011659, 0x000116c7
              .long   0x00011735, 0x000117a3, 0x00011811, 0x00011880
              .long   0x000118ee, 0x0001195d, 0x000119cc, 0x00011a3c
              .long   0x00011aab, 0x00011b1b, 0x00011b8b, 0x00011bfb
              .long   0x00011c6b, 0x00011cdb, 0x00011d4c, 0x00011dbd
              .long   0x00011e2e, 0x00011e9f, 0x00011f10, 0x00011f82
              .long   0x00011ff3, 0x00012065, 0x000120d8, 0x0001214a
              .long   0x000121bc, 0x0001222f, 0x000122a2, 0x00012315
              .long   0x00012389, 0x000123fc, 0x00012470, 0x000124e4
              .long   0x00012558, 0x000125cd, 0x00012641, 0x000126b6
              .long   0x0001272b, 0x000127a0, 0x00012815, 0x0001288b
              .long   0x00012901, 0x00012977, 0x000129ed, 0x00012a64
              .long   0x00012ada, 0x00012b51, 0x00012bc8, 0x00012c40
              .long   0x00012cb7, 0x00012d2f, 0x00012da7, 0x00012e1f
              .long   0x00012e97, 0x00012f10, 0x00012f89, 0x00013002
              .long   0x0001307b, 0x000130f4, 0x0001316e, 0x000131e8
              .long   0x00013262, 0x000132dd, 0x00013357, 0x000133d2
              .long   0x0001344d, 0x000134c8, 0x00013544, 0x000135c0
              .long   0x0001363c, 0x000136b8, 0x00013734, 0x000137b1
              .long   0x0001382e, 0x000138ab, 0x00013928, 0x000139a6
              .long   0x00013a24, 0x00013aa2, 0x00013b20, 0x00013b9f
              .long   0x00013c1d, 0x00013c9d, 0x00013d1c, 0x00013d9b
              .long   0x00013e1b, 0x00013e9b, 0x00013f1b, 0x00013f9c
              .long   0x0001401d, 0x0001409e, 0x0001411f, 0x000141a0
              .long   0x00014222, 0x000142a4, 0x00014326, 0x000143a9
              .long   0x0001442b, 0x000144ae, 0x00014532, 0x000145b5
              .long   0x00014639, 0x000146bd, 0x00014741, 0x000147c6
              .long   0x0001484b, 0x000148d0, 0x00014955, 0x000149db
              .long   0x00014a60, 0x00014ae6, 0x00014b6d, 0x00014bf4
              .long   0x00014c7a, 0x00014d02, 0x00014d89, 0x00014e11
              .long   0x00014e99, 0x00014f21, 0x00014faa, 0x00015032
              .long   0x000150bc, 0x00015145, 0x000151cf, 0x00015258
              .long   0x000152e3, 0x0001536d, 0x000153f8, 0x00015483
              .long   0x0001550e, 0x0001559a, 0x00015626, 0x000156b2
              .long   0x0001573f, 0x000157cb, 0x00015858, 0x000158e6
              .long   0x00015973, 0x00015a01, 0x00015a90, 0x00015b1e
              .long   0x00015bad, 0x00015c3c, 0x00015ccc, 0x00015d5b
              .long   0x00015deb, 0x00015e7c, 0x00015f0c, 0x00015f9d
              .long   0x0001602e, 0x000160c0, 0x00016152, 0x000161e4
              .long   0x00016276, 0x00016309, 0x0001639c, 0x00016430
              .long   0x000164c4, 0x00016558, 0x000165ec, 0x00016681
              .long   0x00016716, 0x000167ab, 0x00016841, 0x000168d7
              .long   0x0001696d, 0x00016a03, 0x00016a9a, 0x00016b32
              .long   0x00016bc9, 0x00016c61, 0x00016cfa, 0x00016d92
              .long   0x00016e2b, 0x00016ec4, 0x00016f5e, 0x00016ff8
              .long   0x00017092, 0x0001712d, 0x000171c8, 0x00017263
              .long   0x000172ff, 0x0001739b, 0x00017437, 0x000174d4
              .long   0x00017571, 0x0001760e, 0x000176ac, 0x0001774a
              .long   0x000177e9, 0x00017887, 0x00017927, 0x000179c6
              .long   0x00017a66, 0x00017b06, 0x00017ba7, 0x00017c48
              .long   0x00017ce9, 0x00017d8b, 0x00017e2d, 0x00017ed0
              .long   0x00017f73, 0x00018016, 0x000180b9, 0x0001815d
              .long   0x00018202, 0x000182a6, 0x0001834c, 0x000183f1
              .long   0x00018497, 0x0001853d, 0x000185e4, 0x0001868b
              .long   0x00018732, 0x000187da, 0x00018882, 0x0001892b
              .long   0x000189d4, 0x00018a7e, 0x00018b27, 0x00018bd2
              .long   0x00018c7c, 0x00018d27, 0x00018dd3, 0x00018e7f
              .long   0x00018f2b, 0x00018fd8, 0x00019085, 0x00019132
              .long   0x000191e0, 0x0001928e, 0x0001933d, 0x000193ec
              .long   0x0001949c, 0x0001954c, 0x000195fd, 0x000196ad
              .long   0x0001975f, 0x00019811, 0x000198c3, 0x00019975
              .long   0x00019a28, 0x00019adc, 0x00019b90, 0x00019c44
              .long   0x00019cf9, 0x00019dae, 0x00019e64, 0x00019f1a
              .long   0x00019fd1, 0x0001a088, 0x0001a140, 0x0001a1f8
              .long   0x0001a2b0, 0x0001a369, 0x0001a423, 0x0001a4dd
              .long   0x0001a597, 0x0001a652, 0x0001a70d, 0x0001a7c9
              .long   0x0001a885, 0x0001a942, 0x0001a9ff, 0x0001aabd
              .long   0x0001ab7b, 0x0001ac3a, 0x0001acf9, 0x0001adb8
              .long   0x0001ae78, 0x0001af39, 0x0001affa, 0x0001b0bc
              .long   0x0001b17e, 0x0001b241, 0x0001b304, 0x0001b3c8
              .long   0x0001b48c, 0x0001b550, 0x0001b616, 0x0001b6db
              .long   0x0001b7a2, 0x0001b868, 0x0001b930, 0x0001b9f7
              .long   0x0001bac0, 0x0001bb89, 0x0001bc52, 0x0001bd1c
              .long   0x0001bde7, 0x0001beb2, 0x0001bf7d, 0x0001c049
              .long   0x0001c116, 0x0001c1e3, 0x0001c2b1, 0x0001c37f
              .long   0x0001c44e, 0x0001c51e, 0x0001c5ee, 0x0001c6be
              .long   0x0001c78f, 0x0001c861, 0x0001c934, 0x0001ca06
              .long   0x0001cada, 0x0001cbae, 0x0001cc83, 0x0001cd58
              .long   0x0001ce2e, 0x0001cf04, 0x0001cfdb, 0x0001d0b3
              .long   0x0001d18b, 0x0001d264, 0x0001d33d, 0x0001d417
              .long   0x0001d4f2, 0x0001d5cd, 0x0001d6a9, 0x0001d785
              .long   0x0001d862, 0x0001d940, 0x0001da1e, 0x0001dafd
              .long   0x0001dbdd, 0x0001dcbd, 0x0001dd9e, 0x0001de80
              .long   0x0001df62, 0x0001e045, 0x0001e128, 0x0001e20c
              .long   0x0001e2f1, 0x0001e3d7, 0x0001e4bd, 0x0001e5a4
              .long   0x0001e68b, 0x0001e773, 0x0001e85c, 0x0001e946
              .long   0x0001ea30, 0x0001eb1b, 0x0001ec07, 0x0001ecf3
              .long   0x0001ede0, 0x0001eecd, 0x0001efbc, 0x0001f0ab
              .long   0x0001f19b, 0x0001f28b, 0x0001f37d, 0x0001f46f
              .long   0x0001f561, 0x0001f655, 0x0001f749, 0x0001f83e
              .long   0x0001f934, 0x0001fa2a, 0x0001fb21, 0x0001fc19
              .long   0x0001fd12, 0x0001fe0b, 0x0001ff05, 0x00020000
              .long   0x000200fc, 0x000201f8, 0x000202f6, 0x000203f4
              .long   0x000204f3, 0x000205f2, 0x000206f3, 0x000207f4
              .long   0x000208f6, 0x000209f9, 0x00020afc, 0x00020c01
              .long   0x00020d06, 0x00020e0c, 0x00020f13, 0x0002101b
              .long   0x00021123, 0x0002122d, 0x00021337, 0x00021442
              .long   0x0002154e, 0x0002165b, 0x00021769, 0x00021877
              .long   0x00021987, 0x00021a97, 0x00021ba8, 0x00021cba
              .long   0x00021dcd, 0x00021ee1, 0x00021ff6, 0x0002210c
              .long   0x00022222, 0x0002233a, 0x00022452, 0x0002256b
              .long   0x00022686, 0x000227a1, 0x000228bd, 0x000229da
              .long   0x00022af8, 0x00022c17, 0x00022d37, 0x00022e58
              .long   0x00022f7a, 0x0002309d, 0x000231c0, 0x000232e5
              .long   0x0002340b, 0x00023532, 0x0002365a, 0x00023782
              .long   0x000238ac, 0x000239d7, 0x00023b03, 0x00023c30
              .long   0x00023d5e, 0x00023e8c, 0x00023fbc, 0x000240ed
              .long   0x00024220, 0x00024353, 0x00024487, 0x000245bc
              .long   0x000246f3, 0x0002482a, 0x00024963, 0x00024a9c
              .long   0x00024bd7, 0x00024d13, 0x00024e50, 0x00024f8e
              .long   0x000250cd, 0x0002520d, 0x0002534f, 0x00025492
              .long   0x000255d5, 0x0002571a, 0x00025861, 0x000259a8
              .long   0x00025af0, 0x00025c3a, 0x00025d85, 0x00025ed1
              .long   0x0002601e, 0x0002616d, 0x000262bd, 0x0002640e
              .long   0x00026560, 0x000266b3, 0x00026808, 0x0002695e
              .long   0x00026ab5, 0x00026c0e, 0x00026d67, 0x00026ec3
              .long   0x0002701f, 0x0002717d, 0x000272dc, 0x0002743c
              .long   0x0002759e, 0x00027701, 0x00027865, 0x000279cb
              .long   0x00027b32, 0x00027c9a, 0x00027e04, 0x00027f6f
              .long   0x000280dc, 0x0002824a, 0x000283b9, 0x0002852a
              .long   0x0002869c, 0x00028810, 0x00028985, 0x00028afb
              .long   0x00028c73, 0x00028ded, 0x00028f68, 0x000290e4
              .long   0x00029262, 0x000293e2, 0x00029563, 0x000296e5
              .long   0x00029869, 0x000299ef, 0x00029b76, 0x00029cff
              .long   0x00029e89, 0x0002a015, 0x0002a1a3, 0x0002a332
              .long   0x0002a4c3, 0x0002a655, 0x0002a7e9, 0x0002a97f
              .long   0x0002ab16, 0x0002acaf, 0x0002ae4a, 0x0002afe6
              .long   0x0002b184, 0x0002b324, 0x0002b4c5, 0x0002b669
              .long   0x0002b80e, 0x0002b9b4, 0x0002bb5d, 0x0002bd07
              .long   0x0002beb3, 0x0002c061, 0x0002c211, 0x0002c3c2
              .long   0x0002c576, 0x0002c72b, 0x0002c8e2, 0x0002ca9b
              .long   0x0002cc56, 0x0002ce13, 0x0002cfd2, 0x0002d192
              .long   0x0002d355, 0x0002d519, 0x0002d6e0, 0x0002d8a8
              .long   0x0002da73, 0x0002dc3f, 0x0002de0e, 0x0002dfde
              .long   0x0002e1b1, 0x0002e386, 0x0002e55d, 0x0002e735
              .long   0x0002e910, 0x0002eaed, 0x0002eccd, 0x0002eeae
              .long   0x0002f092, 0x0002f277, 0x0002f45f, 0x0002f64a
              .long   0x0002f836, 0x0002fa25, 0x0002fc16, 0x0002fe09
              .long   0x0002fffe, 0x000301f6, 0x000303f0, 0x000305ed
              .long   0x000307ec, 0x000309ed, 0x00030bf0, 0x00030df6
              .long   0x00030fff, 0x0003120a, 0x00031417, 0x00031627
              .long   0x00031839, 0x00031a4e, 0x00031c66, 0x00031e80
              .long   0x0003209c, 0x000322bc, 0x000324dd, 0x00032702
              .long   0x00032929, 0x00032b53, 0x00032d7f, 0x00032faf
              .long   0x000331e0, 0x00033415, 0x0003364d, 0x00033887
              .long   0x00033ac4, 0x00033d04, 0x00033f47, 0x0003418d
              .long   0x000343d5, 0x00034621, 0x0003486f, 0x00034ac1
              .long   0x00034d15, 0x00034f6d, 0x000351c8, 0x00035425
              .long   0x00035686, 0x000358ea, 0x00035b51, 0x00035dbb
              .long   0x00036029, 0x00036299, 0x0003650d, 0x00036784
              .long   0x000369ff, 0x00036c7d, 0x00036efe, 0x00037182
              .long   0x0003740a, 0x00037696, 0x00037925, 0x00037bb7
              .long   0x00037e4d, 0x000380e6, 0x00038383, 0x00038624
              .long   0x000388c8, 0x00038b70, 0x00038e1c, 0x000390cc
              .long   0x0003937f, 0x00039636, 0x000398f1, 0x00039baf
              .long   0x00039e72, 0x0003a139, 0x0003a403, 0x0003a6d2
              .long   0x0003a9a4, 0x0003ac7b, 0x0003af55, 0x0003b234
              .long   0x0003b517, 0x0003b7ff, 0x0003baea, 0x0003bdda
              .long   0x0003c0ce, 0x0003c3c7, 0x0003c6c4, 0x0003c9c5
              .long   0x0003cccb, 0x0003cfd5, 0x0003d2e4, 0x0003d5f8
              .long   0x0003d910, 0x0003dc2d, 0x0003df4e, 0x0003e275
              .long   0x0003e5a0, 0x0003e8d0, 0x0003ec05, 0x0003ef3f
              .long   0x0003f27e, 0x0003f5c2, 0x0003f90b, 0x0003fc59
              .long   0x0003ffac, 0x00040305, 0x00040663, 0x000409c6
              .long   0x00040d2f, 0x0004109d, 0x00041410, 0x00041789
              .long   0x00041b08, 0x00041e8d, 0x00042217, 0x000425a6
              .long   0x0004293c, 0x00042cd8, 0x00043079, 0x00043421
              .long   0x000437ce, 0x00043b82, 0x00043f3c, 0x000442fc
              .long   0x000446c2, 0x00044a8f, 0x00044e62, 0x0004523b
              .long   0x0004561c, 0x00045a02, 0x00045df0, 0x000461e4
              .long   0x000465df, 0x000469e1, 0x00046dea, 0x000471fa
              .long   0x00047611, 0x00047a2f, 0x00047e55, 0x00048282
              .long   0x000486b6, 0x00048af2, 0x00048f35, 0x00049380
              .long   0x000497d3, 0x00049c2e, 0x0004a090, 0x0004a4fb
              .long   0x0004a96d, 0x0004ade8, 0x0004b26b, 0x0004b6f7
              .long   0x0004bb8a, 0x0004c027, 0x0004c4cc, 0x0004c979
              .long   0x0004ce30, 0x0004d2ef, 0x0004d7b8, 0x0004dc89
              .long   0x0004e164, 0x0004e649, 0x0004eb36, 0x0004f02d
              .long   0x0004f52e, 0x0004fa39, 0x0004ff4e, 0x0005046c
              .long   0x00050995, 0x00050ec8, 0x00051405, 0x0005194d
              .long   0x00051e9f, 0x000523fc, 0x00052964, 0x00052ed7
              .long   0x00053456, 0x000539df, 0x00053f74, 0x00054514
              .long   0x00054ac0, 0x00055078, 0x0005563c, 0x00055c0c
              .long   0x000561e8, 0x000567d1, 0x00056dc7, 0x000573c9
              .long   0x000579d8, 0x00057ff4, 0x0005861d, 0x00058c54
              .long   0x00059298, 0x000598ea, 0x00059f4b, 0x0005a5b9
              .long   0x0005ac35, 0x0005b2c0, 0x0005b95a, 0x0005c003
              .long   0x0005c6bb, 0x0005cd82, 0x0005d458, 0x0005db3f
              .long   0x0005e235, 0x0005e93b, 0x0005f052, 0x0005f77a
              .long   0x0005feb2, 0x000605fb, 0x00060d56, 0x000614c2
              .long   0x00061c40, 0x000623d0, 0x00062b72, 0x00063327
              .long   0x00063aef, 0x000642ca, 0x00064ab8, 0x000652bb
              .long   0x00065ad1, 0x000662fb, 0x00066b3a, 0x0006738e
              .long   0x00067bf7, 0x00068475, 0x00068d09, 0x000695b4
              .long   0x00069e75, 0x0006a74d, 0x0006b03c, 0x0006b943
              .long   0x0006c262, 0x0006cb99, 0x0006d4e8, 0x0006de51
              .long   0x0006e7d4, 0x0006f170, 0x0006fb27, 0x000704f8
              .long   0x00070ee5, 0x000718ed, 0x00072312, 0x00072d53
              .long   0x000737b1, 0x0007422c, 0x00074cc6, 0x0007577e
              .long   0x00076255, 0x00076d4c, 0x00077863, 0x0007839b
              .long   0x00078ef4, 0x00079a6f, 0x0007a60d, 0x0007b1cd
              .long   0x0007bdb1, 0x0007c9ba, 0x0007d5e8, 0x0007e23b
              .long   0x0007eeb5, 0x0007fb56, 0x0008081e, 0x00081510
              .long   0x0008222a, 0x00082f6f, 0x00083cde, 0x00084a7a
              .long   0x00085841, 0x00086637, 0x0008745a, 0x000882ad
              .long   0x00089130, 0x00089fe5, 0x0008aecb, 0x0008bde5
              .long   0x0008cd32, 0x0008dcb5, 0x0008ec6f, 0x0008fc60
              .long   0x00090c89, 0x00091ced, 0x00092d8b, 0x00093e66
              .long   0x00094f7e, 0x000960d5, 0x0009726d, 0x00098446
              .long   0x00099663, 0x0009a8c4, 0x0009bb6b, 0x0009ce5b
              .long   0x0009e194, 0x0009f518, 0x000a08e8, 0x000a1d08
              .long   0x000a3178, 0x000a463a, 0x000a5b51, 0x000a70bf
              .long   0x000a8685, 0x000a9ca6, 0x000ab323, 0x000aca00
              .long   0x000ae13f, 0x000af8e2, 0x000b10eb, 0x000b295e
              .long   0x000b423d, 0x000b5b8b, 0x000b754a, 0x000b8f7f
              .long   0x000baa2c, 0x000bc553, 0x000be0fa, 0x000bfd23
              .long   0x000c19d1, 0x000c3709, 0x000c54cf, 0x000c7326
              .long   0x000c9213, 0x000cb19a, 0x000cd1bf, 0x000cf288
              .long   0x000d13f9, 0x000d3619, 0x000d58ea, 0x000d7c75
              .long   0x000da0bd, 0x000dc5ca, 0x000deba1, 0x000e124a
              .long   0x000e39ca, 0x000e6229, 0x000e8b6f, 0x000eb5a3
              .long   0x000ee0ce, 0x000f0cf9, 0x000f3a2b, 0x000f686e
              .long   0x000f97cd, 0x000fc852, 0x000ffa06, 0x00102cf7
              .long   0x0010612f, 0x001096bc, 0x0010cda9, 0x00110606
              .long   0x00113fe1, 0x00117b49, 0x0011b84e, 0x0011f701
              .long   0x00123776, 0x001279bd, 0x0012bded, 0x0013041a
              .long   0x00134c5a, 0x001396c7, 0x0013e378, 0x0014328a
              .long   0x00148419, 0x0014d844, 0x00152f2a, 0x001588f0
              .long   0x0015e5b9, 0x001645ae, 0x0016a8f9, 0x00170fc7
              .long   0x00177a48, 0x0017e8b2, 0x00185b3c, 0x0018d222
              .long   0x00194da6, 0x0019ce0d, 0x001a53a4, 0x001adebc
              .long   0x001b6faf, 0x001c06d6, 0x001ca4a9, 0x001d4992
              .long   0x001df610, 0x001eaaab, 0x001f67f9, 0x00202e9f
              .long   0x0020ff54, 0x0021dadf, 0x0022c21f, 0x0023b60a
              .long   0x0024b7b2, 0x0025c848, 0x0026e924, 0x00281bc5
              .long   0x002961de, 0x002abd57, 0x002c305e, 0x002dbd6d
              .long   0x002f675b, 0x0031316e, 0x00331f6d, 0x003535bd
              .long   0x00377986, 0x0039f0d6, 0x003ca2df, 0x003f9839
              .long   0x0042db3e, 0x00467887, 0x004a7f8e, 0x004f038b
              .long   0x00541cb0, 0x0059e9d7, 0x00609302, 0x00684cff
              .long   0x00715ef8, 0x007c2b37, 0x00893d65, 0x009962e7
              .long   0x00add6ab, 0x00c8956f, 0x00ed0def, 0x0121bc04
              .long   0x01748484, 0x02098758, 0x03653a78, 0x0a2fe260

;;; Wall production shares these slots with the later row-drawing phase.
;;; Record pages avoid them. Keep calls in bank 3 and jump to segDone.
              .section segwalls, text
#undef V_FAR
#define V_FAR 1
#define V_NAME v05
#undef V_PAD
#define V_PAD 0
#define V_ONE 0
#define V_TOP 1
#define V_BOT 0
#define V_MC 1
#define V_MF 0
#include "segvar.inc"
#undef V_NAME
#undef V_PAD
#undef V_ONE
#undef V_TOP
#undef V_BOT
#undef V_MC
#undef V_MF

#define V_NAME v06
#define V_ONE 0
#define V_TOP 0
#define V_BOT 1
#define V_MC 1
#define V_MF 0
#include "segvar.inc"
#undef V_NAME
#undef V_ONE
#undef V_TOP
#undef V_BOT
#undef V_MC
#undef V_MF

#define V_NAME v08
#define V_ONE 0
#define V_TOP 0
#define V_BOT 0
#define V_MC 0
#define V_MF 1
#include "segvar.inc"
#undef V_NAME
#undef V_ONE
#undef V_TOP
#undef V_BOT
#undef V_MC
#undef V_MF

#define V_NAME v10
#define V_ONE 0
#define V_TOP 0
#define V_BOT 1
#define V_MC 0
#define V_MF 1
#include "segvar.inc"
#undef V_NAME
#undef V_ONE
#undef V_TOP
#undef V_BOT
#undef V_MC
#undef V_MF

#define V_NAME v12
#define V_ONE 0
#define V_TOP 0
#define V_BOT 0
#define V_MC 1
#define V_MF 1
#include "segvar.inc"
#undef V_NAME
#undef V_ONE
#undef V_TOP
#undef V_BOT
#undef V_MC
#undef V_MF

#define V_NAME v13
#define V_ONE 0
#define V_TOP 1
#define V_BOT 0
#define V_MC 1
#define V_MF 1
#include "segvar.inc"
#undef V_NAME
#undef V_ONE
#undef V_TOP
#undef V_BOT
#undef V_MC
#undef V_MF

#define V_NAME v14
#define V_ONE 0
#define V_TOP 0
#define V_BOT 1
#define V_MC 1
#define V_MF 1
#include "segvar.inc"
#undef V_NAME
#undef V_ONE
#undef V_TOP
#undef V_BOT
#undef V_MC
#undef V_MF

#define V_NAME v15
#define V_ONE 0
#define V_TOP 1
#define V_BOT 1
#define V_MC 1
#define V_MF 1
#include "segvar.inc"
#undef V_NAME
#undef V_ONE
#undef V_TOP
#undef V_BOT
#undef V_MC
#undef V_MF

#define V_NAME v20
#define V_ONE 1
#define V_TOP 0
#define V_BOT 0
#define V_MC 1
#define V_MF 0
#include "segvar.inc"
#undef V_NAME
#undef V_ONE
#undef V_TOP
#undef V_BOT
#undef V_MC
#undef V_MF

#define V_NAME v28
#define V_ONE 1
#define V_TOP 0
#define V_BOT 0
#define V_MC 1
#define V_MF 1
#include "segvar.inc"
#undef V_NAME
#undef V_ONE
#undef V_TOP
#undef V_BOT
#undef V_MC
#undef V_MF
              .space  10                    ; the old level-setup fragment's size

              .public drawMid, drawTop, drawBot, ceilFill, ceilSky, floorFill
              .public texCol, tcNew, tcLoad, ONE_TC, ONE_SPAN

              .public oneSkip

oneSkip        .equ    (ceilFill + 70) ; unchanged instruction site

ONE_TC        .equ    (texCol + 6) ; unchanged instruction site

ONE_SPAN        .equ    (tcSpan + 12) ; unchanged instruction site

#include "viewwin.inc"
              .extern oneViewMode
              .section core5cold, text
              .public c5Mode
;;; Remove our old patches before the existing mode installer runs. The
;;; original full/half/two-thirds instruction streams keep their addresses.
c5Mode:       php
              rep     #0x30
              jsl     long:c19Restore
              jsl     long:ssMode
              jsl     long:c16Mode
              jsl     long:c17Mode
              jsl     long:c19Install
              plp
              rtl
              .space 290 - (. - c5Mode) ; keep the cold fragment and its callers


;;; C16b: exact constant-row products, with shared magnitude kernels.
;;; Entry/exit are the original tierDraw ABI. W_T4 is dead after texCol.
;;; Y retains row to select the sign after the arithmetic; all rows 0..168.
C19_ROWS      .equ    0x032f00
C19_TABLE     .equ    0x035e00
;;; C19: source images below are copied only at FULL. Kernels retain C16's
;;; cache slots, AFTER live clip/state data02AB18..02AEEB. The table uses
;;; dormant two-thirds code. Head/finish replace the last27 bytes of the
;;; unused quarter-square path; finish falls straight into texRec.
c16Start      .equ    (texRec - 27)
c16Finish     .equ    (texRec - 15)
c16Rows       .equ    C19_TABLE
              .section core16head, text
c19HeadImage:     sta     dp:W_T4
              lda     dp:W_YL
              tay
              asl     a
              tax
              lda     dp:.tiny DC_FSTEP
              jmp     (abs:.word0 c16Rows,x)
c19FinishImage:    cpy     ##(CONST_CENTERY + 1)
              bcs     c19Positive
              eor     ##0xffff
              inc     a
c19Positive:  clc
              adc     dp:W_T4
              tay
              ldx     dp:W_TCX
c19HeadEnd:
              .space  4                    ; preserve source section footprint
c19TableImage:
              .word   .word0 (C19_ROWS + (c16Mag85 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag84 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag83 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag82 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag81 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag80 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag79 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag78 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag77 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag76 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag75 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag74 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag73 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag72 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag71 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag70 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag69 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag68 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag67 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag66 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag65 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag64 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag63 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag62 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag61 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag60 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag59 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag58 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag57 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag56 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag55 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag54 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag53 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag52 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag51 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag50 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag49 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag48 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag47 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag46 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag45 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag44 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag43 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag42 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag41 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag40 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag39 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag38 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag37 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag36 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag35 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag34 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag33 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag32 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag31 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag30 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag29 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag28 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag27 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag26 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag25 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag24 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag23 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag22 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag21 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag20 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag19 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag18 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag17 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag16 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag15 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag14 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag13 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag12 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag11 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag10 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag9 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag8 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag7 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag6 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag5 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag4 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag3 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag2 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag1 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag0 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag1 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag2 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag3 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag4 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag5 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag6 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag7 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag8 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag9 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag10 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag11 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag12 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag13 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag14 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag15 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag16 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag17 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag18 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag19 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag20 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag21 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag22 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag23 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag24 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag25 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag26 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag27 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag28 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag29 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag30 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag31 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag32 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag33 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag34 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag35 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag36 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag37 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag38 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag39 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag40 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag41 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag42 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag43 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag44 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag45 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag46 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag47 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag48 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag49 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag50 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag51 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag52 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag53 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag54 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag55 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag56 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag57 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag58 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag59 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag60 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag61 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag62 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag63 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag64 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag65 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag66 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag67 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag68 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag69 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag70 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag71 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag72 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag73 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag74 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag75 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag76 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag77 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag78 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag79 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag80 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag81 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag82 - c16Mag0))
              .word   .word0 (C19_ROWS + (c16Mag83 - c16Mag0))

c19TableEnd:

              .section core5cold, text
c16Mode:      ldx     ##0
              lda     long:VW_SIZE
              cmp     ##10                  ; FULL (six-size menu value)
              bne     c16Set
              ldx     ##4
c16Set:       lda     long:c16PatchBytes,x
              sta     long:tierDraw
              lda     long:(c16PatchBytes+2),x
              sta     long:(tierDraw+2)
;;; C18: choose each TIER route only at size changes (X=0 small,4 FULL).
              lda     long:c18MidBytes,x
              sta     long:(drawMid+31)
              lda     long:(c18MidBytes+2),x
              sta     long:(drawMid+33)
              lda     long:c18TopBytes,x
              sta     long:(drawTop+31)
              lda     long:(c18TopBytes+2),x
              sta     long:(drawTop+33)
              lda     long:c18BotBytes,x
              sta     long:(drawBot+31)
              lda     long:(c18BotBytes+2),x
              sta     long:(drawBot+33)
              rtl
c16PatchBytes:
              .byte   0xa8, 0xa5, W_YL, 0x38 ; TAY / LDA dp:W_YL / SEC
              .byte   0x5c, .byte0 c16Start, .byte1 c16Start, .byte2 c16Start
;;; Each TIER remains39 bytes: JMP3 + skipped pad / flat BRA2, or BRL3 + pad.
;;; +7 continuations and their shared high byte (C17) therefore stay fixed.
c18MidBytes: .byte   0x82
              .word   .word0 (tierDraw - (drawMid+34))
              .byte   0xea
              .byte   0x4c, .byte0 c16Start, .byte1 c16Start, 0xea
c18TopBytes: .byte   0x82
              .word   .word0 (tierDraw - (drawTop+34))
              .byte   0xea
              .byte   0x4c, .byte0 c16Start, .byte1 c16Start, 0xea
c18BotBytes: .byte   0x82
              .word   .word0 (tierDraw - (drawBot+34))
              .byte   0xea
              .byte   0x4c, .byte0 c16Start, .byte1 c16Start, 0xea

;;; C19: MVN uses each symbol's actual source bank (not the code bank).
;;; Caller has16-bit A/X/Y. Preserve DB; registers and flags are caller-dead.
C19COPY       .macro  source, dest, count
              ldx     ##.word0 \source
              ldy     ##.word0 \dest
              lda     ##(\count - 1)
              .byte   0x54, .byte2 \dest, .byte2 \source
              .endm
C19_HEADLEN   .equ    (c19HeadEnd - c19HeadImage)
C19_ROWLEN    .equ    (c19RowsEnd - c16Mag0)
C19_TABLELEN  .equ    (c19TableEnd - c19TableImage)

c19Restore:   phb
              lda     long:c19Installed
              beq     2$
              C19COPY c19SaveHead, c16Start, C19_HEADLEN
              C19COPY c19SaveRows, C19_ROWS, C19_ROWLEN
              C19COPY c19SaveTable, C19_TABLE, C19_TABLELEN
              lda     ##0
              sta     long:c19Installed
2$:           plb
              rtl

c19Install:   lda     long:VW_SIZE
              cmp     ##10
              bne     1$
              phb
;;; Save the current native bytes AFTER all view installers have run.
;;; This retains previous mode operands across repeated trips through FULL.
              C19COPY c16Start, c19SaveHead, C19_HEADLEN
              C19COPY C19_ROWS, c19SaveRows, C19_ROWLEN
              C19COPY C19_TABLE, c19SaveTable, C19_TABLELEN
              lda     ##1
              sta     long:c19Saved
              C19COPY c19HeadImage, c16Start, C19_HEADLEN
              C19COPY c16Mag0, C19_ROWS, C19_ROWLEN
              C19COPY c19TableImage, C19_TABLE, C19_TABLELEN
              lda     ##1
              sta     long:c19Installed
              plb
1$:           rtl
c19Saved:     .word   0
c19Installed: .word   0

              .section core16rows, text
c16Mag0: ; multiply by 0, 3 nominal arithmetic cycles
              lda     ##0
              jmp     abs:.word0 c16Finish
c16Mag1: ; multiply by 1, 0 nominal arithmetic cycles
              jmp     abs:.word0 c16Finish
c16Mag2: ; multiply by 2, 2 nominal arithmetic cycles
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag3: ; multiply by 3, 8 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag4: ; multiply by 4, 4 nominal arithmetic cycles
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag5: ; multiply by 5, 10 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag6: ; multiply by 6, 10 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag7: ; multiply by 7, 12 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag8: ; multiply by 8, 6 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag9: ; multiply by 9, 12 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag10: ; multiply by 10, 12 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag11: ; multiply by 11, 18 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag12: ; multiply by 12, 12 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag13: ; multiply by 13, 18 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag14: ; multiply by 14, 14 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag15: ; multiply by 15, 14 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag16: ; multiply by 16, 8 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag17: ; multiply by 17, 14 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag18: ; multiply by 18, 14 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag19: ; multiply by 19, 20 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag20: ; multiply by 20, 14 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag21: ; multiply by 21, 20 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag22: ; multiply by 22, 20 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag23: ; multiply by 23, 20 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag24: ; multiply by 24, 14 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag25: ; multiply by 25, 20 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag26: ; multiply by 26, 20 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag27: ; multiply by 27, 22 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag28: ; multiply by 28, 16 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag29: ; multiply by 29, 22 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag30: ; multiply by 30, 16 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag31: ; multiply by 31, 16 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag32: ; multiply by 32, 10 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag33: ; multiply by 33, 16 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag34: ; multiply by 34, 16 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag35: ; multiply by 35, 22 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag36: ; multiply by 36, 16 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag37: ; multiply by 37, 22 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag38: ; multiply by 38, 22 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag39: ; multiply by 39, 22 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag40: ; multiply by 40, 16 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag41: ; multiply by 41, 22 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag42: ; multiply by 42, 22 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag43: ; multiply by 43, 28 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag44: ; multiply by 44, 22 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag45: ; multiply by 45, 28 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag46: ; multiply by 46, 22 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag47: ; multiply by 47, 22 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag48: ; multiply by 48, 16 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag49: ; multiply by 49, 22 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag50: ; multiply by 50, 22 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag51: ; multiply by 51, 28 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag52: ; multiply by 52, 22 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag53: ; multiply by 53, 28 nominal arithmetic cycles
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag54: ; multiply by 54, 24 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag55: ; multiply by 55, 24 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag56: ; multiply by 56, 18 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag57: ; multiply by 57, 24 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag58: ; multiply by 58, 24 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag59: ; multiply by 59, 24 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag60: ; multiply by 60, 18 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag61: ; multiply by 61, 24 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag62: ; multiply by 62, 18 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag63: ; multiply by 63, 18 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag64: ; multiply by 64, 12 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag65: ; multiply by 65, 18 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag66: ; multiply by 66, 18 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag67: ; multiply by 67, 24 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag68: ; multiply by 68, 18 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag69: ; multiply by 69, 24 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag70: ; multiply by 70, 24 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag71: ; multiply by 71, 24 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag72: ; multiply by 72, 18 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag73: ; multiply by 73, 24 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag74: ; multiply by 74, 24 nominal arithmetic cycles
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag75: ; multiply by 75, 30 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag76: ; multiply by 76, 24 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag77: ; multiply by 77, 30 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag78: ; multiply by 78, 24 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag79: ; multiply by 79, 24 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag80: ; multiply by 80, 18 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag81: ; multiply by 81, 24 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag82: ; multiply by 82, 24 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag83: ; multiply by 83, 30 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              sec
              sbc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish
c16Mag84: ; multiply by 84, 24 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              jmp     abs:.word0 c16Finish
c16Mag85: ; multiply by 85, 30 nominal arithmetic cycles
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              asl     a
              asl     a
              clc
              adc     dp:.tiny DC_FSTEP
              jmp     abs:.word0 c16Finish

;;; C17: single-tier FULL segs fuse texCol into their existing outer call.
;;; Generic/masked/two-tier segs retain RTS. The table index is 2 * loop kind.
;;; No math, record, clipping or light changes. All other sizes restore the
;;; original calls and disable the per-seg hook once at mode installation.
c19RowsEnd:

;;; Copy before first use; the backup never needs loader initialization.
              .section core19save, bss
c19SaveHead:  .space C19_HEADLEN
c19SaveRows:  .space C19_ROWLEN
c19SaveTable: .space C19_TABLELEN
c19SaveEnd:

              .section core5cold, text
c17Setup:     lda     long:c17Next,x
              sta     long:c17Return
              rtl
c17Next:
              .word   0x0060                 ; kind 0: ordinary RTS
              .word   0x0060                 ; kind 1: ordinary RTS
              .byte   0x4c, .byte0 (drawBot+7) ; kind 2
              .word   0x0060                 ; kind 3: ordinary RTS
              .word   0x0060                 ; kind 4: ordinary RTS
              .byte   0x4c, .byte0 (drawTop+7) ; kind 5
              .byte   0x4c, .byte0 (drawBot+7) ; kind 6
              .word   0x0060                 ; kind 7: ordinary RTS
              .word   0x0060                 ; kind 8: ordinary RTS
              .word   0x0060                 ; kind 9: ordinary RTS
              .byte   0x4c, .byte0 (drawBot+7) ; kind 10
              .word   0x0060                 ; kind 11: ordinary RTS
              .word   0x0060                 ; kind 12: ordinary RTS
              .byte   0x4c, .byte0 (drawTop+7) ; kind 13
              .byte   0x4c, .byte0 (drawBot+7) ; kind 14
              .word   0x0060                 ; kind 15: ordinary RTS
              .word   0x0060                 ; kind 16: ordinary RTS
              .word   0x0060                 ; kind 17: ordinary RTS
              .word   0x0060                 ; kind 18: ordinary RTS
              .word   0x0060                 ; kind 19: ordinary RTS
              .byte   0x4c, .byte0 (drawMid+7) ; kind 20
              .word   0x0060                 ; kind 21: ordinary RTS
              .word   0x0060                 ; kind 22: ordinary RTS
              .word   0x0060                 ; kind 23: ordinary RTS
              .word   0x0060                 ; kind 24: ordinary RTS
              .word   0x0060                 ; kind 25: ordinary RTS
              .word   0x0060                 ; kind 26: ordinary RTS
              .word   0x0060                 ; kind 27: ordinary RTS
              .byte   0x4c, .byte0 (drawMid+7) ; kind 28
              .word   0x0060                 ; kind 29: ordinary RTS
              .word   0x0060                 ; kind 30: ordinary RTS
              .word   0x0060                 ; kind 31: ordinary RTS
              .word   0x0060                 ; kind 32: ordinary RTS
              .word   0x0060                 ; kind 33: ordinary RTS
c17Mode:      lda     long:VW_SIZE
              cmp     ##10
              bne     c17Small
              lda     ##.word0 texCol
              sta     long:(v02c17draw+1)
              sta     long:(v05c17draw+1)
              sta     long:(v06c17draw+1)
              sta     long:(v10c17draw+1)
              sta     long:(v13c17draw+1)
              sta     long:(v14c17draw+1)
              sta     long:(v20c17draw+1)
              sta     long:(v28c17draw+1)
              lda     ##.word0 c17Slow
              sta     long:(v02c17slow+1)
              sta     long:(v05c17slow+1)
              sta     long:(v06c17slow+1)
              sta     long:(v10c17slow+1)
              sta     long:(v13c17slow+1)
              sta     long:(v14c17slow+1)
              sta     long:(v20c17slow+1)
              sta     long:(v28c17slow+1)
              lda     long:c17HookBytes
              sta     long:c17Hook
              lda     long:(c17HookBytes+2)
              sta     long:(c17Hook+2)
              rtl
c17Small:     lda     ##0x0060
              sta     long:c17Return
              lda     ##0xeaea
              sta     long:c17Hook
              sta     long:(c17Hook+2)
              lda     ##.word0 genColumn
              sta     long:(v02c17slow+1)
              sta     long:(v05c17slow+1)
              sta     long:(v06c17slow+1)
              sta     long:(v10c17slow+1)
              sta     long:(v13c17slow+1)
              sta     long:(v14c17slow+1)
              sta     long:(v20c17slow+1)
              sta     long:(v28c17slow+1)
              lda     ##.word0 drawMid
              sta     long:(v20c17draw+1)
              sta     long:(v28c17draw+1)
              lda     ##.word0 drawTop
              sta     long:(v05c17draw+1)
              sta     long:(v13c17draw+1)
              lda     ##.word0 drawBot
              sta     long:(v02c17draw+1)
              sta     long:(v06c17draw+1)
              sta     long:(v10c17draw+1)
              sta     long:(v14c17draw+1)
              rtl
c17HookBytes: .byte 0x22, .byte0 c17Setup, .byte1 c17Setup, .byte2 c17Setup
