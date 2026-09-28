;;; Sprite projection in 65816 assembly.
;;;
;;; R_AddSprites and R_ProjectSprite of r_draw.c, with the same
;;; results. PROJECTION / (tz >> FRACBITS) and (PROJECTIONY * FRACUNIT) /
;;; (tz >> FRACBITS) come from tables that R_InitSpriteScales makes with
;;; the same C expressions, for tz >> FRACBITS = 4..1280.
;;; Z_ChangeTagToCache is left out: sprite patches are lumps in the WAD
;;; image, which it ignores. The thing, its frame and its patch are long
;;; pointers in the direct page of the BSP phase (BSPDP of
;;; src/iigs/r_sprite65.s). All stores are 8-bit.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"
#include "info.inc"
#include "wpage.inc"
#include "viewwin.inc"

              .extern _Dp, _Mul16, _Mul32, FixedMul, FixedMul3216, FixedReciprocal
              .extern MA, BSPDP, qmul, qmulh, qmulL, dsaInit
              .extern visColD, visCol, visDone, VN_STEP, mwCols, mwNextCol, wdDraw
              .extern vrCol8, vrPost, vrAdv, vrNext0, vrDone, VR_LP, VR_NX
              .extern FR_X, FR_P, FR_B, spryscale, rw_scalestep
              .extern maskedtexturecol
              .extern R_PointToAngle16, SMAP, CMO, LT_BASE, states
              .extern validcount, viewx, viewy, viewz, viewcos, viewsin
              .extern vissprites, num_vissprite
              .extern fixedcolormap, fullcolormap
              .public PR_GZ, PR_GX

SPRXSCALE     .equ    MM_SPRXSCALE    ; see src/iigs/iigs.scm
SPRYSCALE     .equ    MM_SPRYSCALE
SPRISCALE     .equ    MM_SPRISCALE    ; FixedReciprocal(SPRXSCALE[d]), d = 1..1280
                                      ;   (R_InitSpriteIScales, on the first frame)
FQ            .equ    MM_FQ           ; (16 d / 5, 16 d % 5), d = 0..1280 (fracstep)
SPRBOUND      .equ    MM_SPRBOUND     ; (E, E / 2 + 2) of each sprite (the side test)
MAXZ_HI       .equ    1280
GG_PADN       .equ    16              ; the pad after gGX: the old size of tzAny
PS_PADN       .equ    35              ; the pad after bitOf: R_PointToAngle16 and the
                                      ;   rest of bspcode keep their addresses
WAD_BANK      .equ    MM_WAD_BANK     ; WAD_ADDR = 0x100000
FILELUMP_SIZE .equ    16              ; filelump_t of w_wad.c, filepos first

SC            .equ    (_Dp+4)         ; the sector of R_AddSprites (bspSub of
                                      ;   src/iigs/r_bsp65.s)
TH            .equ    (BSPDP+21)      ; the thing (long pointers: 3 bytes; the
SF            .equ    (BSPDP+24)      ;   BSP walk of src/iigs/r_wall65.s uses
PT            .equ    (BSPDP+27)      ;   the bytes below 21), its sprite frame, its patch
PR_HX         .equ    (BSPDP+48)      ; TXH, TYH: the high words of tr_x, tr_y (the
PR_HY         .equ    (BSPDP+50)      ;   BSP walk leaves BSPDP+48..71 alone)
PR_HS         .equ    (BSPDP+52)      ; S = TXH + TYH (gTZ)
PR_K1         .equ    (BSPDP+54)      ; K1 = S * c (gTZ, for gTX)
PR_GBL        .equ    (BSPDP+58)      ; the low words of GB = c - s and GC = s + c
PR_GCL        .equ    (BSPDP+60)      ;   (prFrame, each frame)
PR_LMP        .equ    (BSPDP+62)      ; the lump of the patch (DS_X of R_DrawSprite,
                                      ;   which it sets before a read)
PR_WL         .equ    (BSPDP+66)      ; W = width * xscale (4 bytes: DS_R2 and DS_I
                                      ;   of R_DrawSprite, which it sets in full;
                                      ;   not +62..65: the high byte of its DS_R1
                                      ;   (+65) must stay 0)
WP_SPR        .equ    (BSPDP+38)      ; sprites, fileinfo: set for the frame
WP_FI         .equ    (BSPDP+41)      ;   (R_WallFrame of src/iigs/r_wall65.s)

              .section znear, bss
PR_S:         .space  2               ; SMAP[(lightlevel >> 4) + LT_BASE]
PR_TRX:       .space  4               ; tr_x, tr_y
PR_TRY:       .space  4
PR_TZ:        .space  4
PR_TX:        .space  4
              .public CN_LSEC
CN_LSEC:      .space  2               ; bspSub (r_bsp65): the sector of the
                                      ;   subsector before (0: none)
              .space  6               ; (free)
PR_XL:        .space  4               ; xl (its high word: x1)
PR_XR:        .space  4
              .space  2               ; (free)
PR_FLIP:      .space  2               ; flip (the high byte is 0)
PR_VIS:       .space  2               ; offset of the vissprite in vissprites
PR_GZ:        .space  4               ; the G parts of tz and tx of a thing at
PR_GX:        .space  4               ;   whole map units (see projectSprite)
              .public PR_IOK
PR_IOK:       .space  2               ; SPRISCALE is made (R_WallFrame)
PR_GBI:       .space  1               ; 1 + the index of the code at K3FIX and at
PR_GCI:       .space  1               ;   K2FIX (prFrame; 0 at the start: none)
PR_HVS:       .space  1               ; VW_HALF of the code at the half view sites
                                      ;   (hvPatch; 0 at the start: as assembled)
              .space  1               ; (the old size: the near data stays in place)
PR_X1         .equ    (PR_XL+2)

;;; Signed 32-bit a < b: lda a.lo / cmp b.lo / lda a.hi / SLT32 b.hi / bmi
SLT32         .macro  op
              sbc     \op
              bvc     1$
              eor     ##0x8000
1$:
              .endm

;;; Store C to the near word \dst: one 16-bit store (see PUTWN of
;;; src/iigs/r_wall65.s).
PUTWN         .macro  dst
              sta     .near \dst
              .endm

;;; The same for a direct page word.
PUTWD         .macro  dst
              sta     dp:.tiny \dst
              .endm

;;; The same for X:C to the near fixed_t \dst.
PUT32N        .macro  dst
              sta     .near \dst
              txa
              sta     .near (\dst+2)
              .endm

;;; vis->\fld = X:C, Y = the offset of the vissprite.
VIS32         .macro  fld
              sta     abs:.near (vissprites + \fld),y
              txa
              sta     abs:.near (vissprites + \fld + 2),y
              .endm

;;; vis->\fld = C (a word), Y = the offset of the vissprite.
VIS16         .macro  fld
              sta     abs:.near (vissprites + \fld),y
              .endm

;;; PR_TZ = C:Y (C: the high word); tz < MINZ (4.0: behind the view plane)
;;; or tz > MAXZ (1280.0: too far away): the next thing.
TZTEST        .macro
              PUTWN   (PR_TZ+2)
              sty     .near PR_TZ
              sec
              sbc     ##4
              cmp     ##(MAXZ_HI - 4)
              bcc     2$                    ; 4.0 <= tz < 1280.0
              bne     1$
              cpy     ##0                   ; 1280.0
              beq     2$
1$:           brl     nextThing
2$:
              .endm

;;; ---------------------------------------------------------------------------
;;; void R_AddSprites(sector, int16_t lightlevel)
;;;   In: SC (_Dp[4-6], a long pointer) = the sector, C = lightlevel. bspSub
;;;   (src/iigs/r_bsp65.s) calls it once a frame for each sector with a
;;;   subsector in view, and sets sec->validcount itself. The body of the
;;;   loop is R_ProjectSprite of each thing of the sector.
;;; ---------------------------------------------------------------------------
              .section bspcode, text
              .public R_AddSprites
R_AddSprites:
              tax                           ; X = lightlevel
              ldy     ##(OFS_SEC_THINGLIST+2) ; thing = sec->thinglist (16-bit
              lda     [.tiny SC],y          ;   stores, no REP/SEP: TH+3 is SF,
              sta     dp:.tiny (TH+2)       ;   set before a read)
              ldy     ##OFS_SEC_THINGLIST
              ora     [.tiny SC],y
              beq     1$                    ; no things
              lda     [.tiny SC],y
              PUTWD   TH
              txa                           ; PR_S = SMAP[(lightlevel >> 4) +
              lsr     a                     ;   LT_BASE]: the start of the
              lsr     a                     ;   distance lights of the sector
              lsr     a                     ;   (R_SpriteColorMap of
              lsr     a                     ;   src/iigs/r_bsp65.s)
              clc
              adc     .near LT_BASE
              asl     a
              tax
              lda     long:SMAP,x
              PUTWN   PR_S
              bra     thing
1$:           rtl
              .space  4                     ; (nextThing keeps its address)

nextThing:    ldy     ##(OFS_MO_SNEXT+2)    ; thing = thing->snext
              lda     [.tiny TH],y
              tax
              ldy     ##OFS_MO_SNEXT
              lda     [.tiny TH],y
              bne     1$
              cpx     ##0
              bne     1$
              rtl
1$:           PUTWD   TH
              txa
              sta     dp:.tiny (TH+2)       ; (16-bit)
              bra     thing
              .space  2                     ; (thing keeps its address)

              ;; R_ProjectSprite(thing): tr_x = thing->x - viewx, tr_y =
              ;; thing->y - viewy; tz = FixedMul(tr_x, viewcos) +
              ;; FixedMul(tr_y, viewsin); for tr = AH:AL and b = viewcos or
              ;; viewsin, FixedMul(tr, b) = AH * b + G(AL, b), G(AL, b) =
              ;; hi16(AL * b.lo) - (b < 0 ? AL : 0). A thing at whole map units
              ;; (most things) has the AL of the frame: its G parts are PR_GZ
              ;; and PR_GX (R_WallFrame of src/iigs/r_wall65.s), and only the
              ;; high words of tr_x and tr_y are needed.
thing:        ldy     ##OFS_MO_Y
              lda     [.tiny TH],y
              ldy     ##OFS_MO_X
              ora     [.tiny TH],y
              beq     whole
              lda     [.tiny TH],y          ; another thing: tr_x = x - viewx,
              sec                           ;   tr_y = y - viewy (the low words
              sbc     .near viewx           ;   in PR_TRX and PR_TRY)
              PUTWN   PR_TRX
              iny
              iny
              lda     [.tiny TH],y
              sbc     .near (viewx+2)
              PUTWD   PR_HX
              iny
              iny
              lda     [.tiny TH],y
              sec
              sbc     .near viewy
              PUTWN   PR_TRY
              iny
              iny
              lda     [.tiny TH],y
              sbc     .near (viewy+2)
              PUTWD   PR_HY
              jsr     .kbank gGZcheck       ; reject behind before the fractional products
              jsr     .kbank gTZcalc        ; + TXH * c + TYH * s (already tested)
              clc
              adc     .near PR_TX
              tay
              txa
              adc     .near (PR_TX+2)
              TZTEST
              jsr     .kbank gGX            ; PR_TX = its G parts of tx
              jsr     .kbank gTX            ; + TXH * s - TYH * c
              clc
              adc     .near PR_TX
              tay
              txa
              adc     .near (PR_TX+2)
              tax
              tya
              bra     txDone

whole:        lda     ##0                   ; TXH = x.hi - viewx.hi - the borrow
              cmp     .near viewx           ;   of 0 - viewx.lo
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny TH],y
              sbc     .near (viewx+2)
              PUTWD   PR_HX
              lda     ##0                   ; TYH, the same
              cmp     .near viewy
              ldy     ##(OFS_MO_Y+2)
              lda     [.tiny TH],y
              sbc     .near (viewy+2)
              PUTWD   PR_HY
              jsr     .kbank gTZ            ; tz = TXH * c + TYH * s + PR_GZ
              clc
              adc     .near PR_GZ
              tay
              txa
              adc     .near (PR_GZ+2)
              TZTEST
              jsr     .kbank gTX            ; tx = TXH * s - TYH * c + PR_GX
              clc
              adc     .near PR_GX
              tay
              txa
              adc     .near (PR_GX+2)
              tax
              tya
txDone:       PUTWN   PR_TX
              txa
              PUTWN   (PR_TX+2)

              ;; off the side, whatever the frame: |tx| >= (tz.hi + (tz.hi >> 6)
              ;; + 2 + E) << 16, with E = SPRBOUND[sprite] >= the leftoffset and
              ;; the width - leftoffset of each patch of the sprite; so x1 >
              ;; VIEWWINDOWWIDTH or xr < 0 below (tx - E > tz + tz / 64, or
              ;; tx + E < -tz; checked for each tz >> FRACBITS, 4..1280)
              ldy     ##OFS_MO_SPRITE
              lda     [.tiny TH],y
              asl     a
              asl     a
              tax                           ; X = sprite * 4
              lda     .near (PR_TZ+2)
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              sec
              adc     long:SPRBOUND,x       ; + E + 1
              sec
              adc     .near (PR_TZ+2)       ; + tz.hi + 1
              bit     .near (PR_TX+2)
              bmi     1$
              clc                           ; tx >= 0: tx.hi >= K
              sbc     .near (PR_TX+2)
              bpl     2$
              brl     nextThing
1$:           clc                           ; tx < 0: ~tx.hi (<= labs(tx).hi) >= K
              adc     .near (PR_TX+2)
              bpl     2$
              brl     nextThing

              ;; labs(tx) > tz << 2: too far off the side (R_ProjectSprite; after
              ;; the test above only possible for tz.hi < E / 2 + 2)
2$:           lda     .near (PR_TZ+2)
              cmp     long:(SPRBOUND+2),x
              bcs     5$
              jsl     long:labsTZ           ; (cold) C = 1: off the side; X =
              bcc     5$                    ;   sprite * 4 again
              brl     nextThing

              ;; sprframe = &sprites[thing->sprite].spriteframes[thing->frame
              ;; & FF_FRAMEMASK]; the FF_FULLBRIGHT bit of the three adds
              ;; goes with the last and
5$:           ldy     ##OFS_MO_FRAME        ; 19 * (frame & 0x7fff)
              lda     [.tiny TH],y
              and     ##0x7fff
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     [.tiny TH],y
              clc
              adc     [.tiny TH],y
              clc
              adc     [.tiny TH],y
              and     ##0x7fff
              txy                           ; Y = sprite * 4
              clc
              adc     [.tiny WP_SPR],y
              PUTWD   SF
              iny
              iny
              lda     [.tiny WP_SPR],y
              sta     dp:.tiny (SF+2)       ; (16-bit: SF+3 is PT, set below)

              ;; the rotation for the view angle
              ldx     ##0
              ldy     ##OFS_SF_ROTATE
              lda     [.tiny SF],y
              beq     6$
              ldy     ##(OFS_MO_Y+2)        ; R_PointToAngle(fx, fy)
              lda     [.tiny TH],y
              PUTWD   _Dp
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny TH],y
              jsl     long:R_PointToAngle16
              ldy     ##(OFS_MO_ANGLE+2)    ; - (angle16_t)(thing->angle >> FRACBITS)
              sec
              sbc     [.tiny TH],y
              clc
              adc     ##0x9000              ; + (angle16_t)(ANG45_16 / 2) * 9
              xba                           ; >> 13
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              and     ##7
              asl     a
              tax
6$:           lda     long:bitOf,x          ; flip = SPR_FLIPPED(sprframe, rot)
              ldy     ##OFS_SF_FLIPMASK
              and     [.tiny SF],y
              sta     .near PR_FLIP         ; (16-bit: the high byte 0)

              ;; patch = W_GetLumpByNum(sprframe->lump[rot]) (the lump also
              ;; in PR_LMP, for vis->lump_num)
              txa
              clc
              adc     ##OFS_SF_LUMP
              tay
              lda     [.tiny SF],y
              sta     dp:.tiny PR_LMP
              asl     a                     ; * FILELUMP_SIZE
              asl     a
              asl     a
              asl     a
              tay
              lda     [.tiny WP_FI],y
              tax
              iny
              iny
              lda     [.tiny WP_FI],y
              clc
              adc     ##WAD_BANK
              sta     dp:.tiny (PT+2)       ; (16-bit: PT+3 is QT, scratch)
              txa
              PUTWD   PT

              ;; tx -= (flip ? width - leftoffset : leftoffset) << FRACBITS
              ldy     ##OFS_PATCH_LEFTOFFSET
              lda     [.tiny PT],y
              ldx     .near PR_FLIP
              beq     7$
              eor     ##0xffff              ; width - leftoffset
              sec
              ldy     ##OFS_PATCH_WIDTH
              adc     [.tiny PT],y
7$:           eor     ##0xffff
              sec
              adc     .near (PR_TX+2)
              PUTWN   (PR_TX+2)

              ;; xscale = PROJECTION / (tz >> FRACBITS), in _Dp (FixedMul and
              ;; the width products below read it there)
              lda     .near (PR_TZ+2)
              asl     a
              asl     a
              tax
              lda     long:SPRXSCALE,x
              PUTWD   _Dp
              lda     long:(SPRXSCALE+2),x
              PUTWD   (_Dp+2)

              ;; W = width * xscale: width * xscale.lo, + (width * xscale.hi <<
              ;; 16) for a close thing
              ldy     ##OFS_PATCH_WIDTH
              lda     [.tiny PT],y
              PUTWD   MA
              lda     dp:.tiny _Dp
              jsr     .kbank qmul           ; Y = low, C = high
              ldx     dp:.tiny (_Dp+2)
              beq     10$
              jsr     .kbank wHi
10$:          tax                           ; X:Y = W

              ;; xr <= xl + (FRACUNIT >> 2): too small; xr - xl = W - FRACUNIT
              ;; (below), so W <= 1.25 (no overflow: xl and W are far below 2^31)
              cpx     ##1
              bcc     26$
              bne     11$
              cpy     ##0x4001
              bcs     11$
26$:          brl     nextThing
              .space  4                     ; (the code after the vissprite
                                            ;   fields keeps its place)
11$:          sty     dp:.tiny PR_WL        ; W, for xr
              stx     dp:.tiny (PR_WL+2)

              ;; xl = CENTERX * FRACUNIT + FixedMul(tx, xscale). For xscale <
              ;; 1.0: TXH * xs.lo + hi16(TXL * xs.lo), the latter with qmulh (+ 0
              ;; or 1 in the last bit): x1 = xl >> 16 and x2 = xr >> 16 are
              ;; exact unless the low word of xl or of xr (xl.lo + W.lo) is 0;
              ;; then, and for xscale >= 1.0, FixedMul (12$)
              lda     dp:.tiny (_Dp+2)
              bne     12$
              lda     dp:.tiny _Dp
              PUTWD   MA
              lda     .near PR_TX
              jsr     .kbank qmulh          ; C = hi16(TXL * xs.lo) (+ 0 or 1)
              PUTWD   PR_HS
              lda     .near (PR_TX+2)
              jsr     .kbank qmul           ; TXH * xs.lo: Y = low, C = high
              ldx     .near (PR_TX+2)       ; TXH < 0: - xs.lo << 16
              bpl     13$
              sec
              sbc     dp:.tiny MA
13$:          tax
              tya
              clc
              adc     dp:.tiny PR_HS
              beq     12$                   ; the low word of xl is 0
              bcc     28$
              inx
28$:          tay
              clc
              adc     dp:.tiny PR_WL
              beq     12$                   ; the low word of xr is 0
              tya
              bra     29$
37$:          brl     nextThing             ; (26$ is out of reach of the tests
              .space  9                     ;   below; the pad keeps the addresses)
12$:          lda     .near PR_TX           ; FixedMul(tx, xscale)
              ldx     .near (PR_TX+2)
              jsl     long:FixedMul
29$:          PUTWN   PR_XL                 ; x1 = xl >> FRACBITS
              txa
              clc
              adc     ##(CONST_VIEWWIDTH / 2)
              sta     .near PR_X1
              sec                           ; x1 > VIEWWINDOWWIDTH: off the side
              sbc     ##(CONST_VIEWWIDTH + 1)
              bvc     8$
              eor     ##0x8000
8$:           bpl     37$

              ;; xr = CENTERX * FRACUNIT - FRACUNIT + FixedMul(tx + (width
              ;; << 16), xscale): that is xl - FRACUNIT + W
              lda     .near PR_XL
              clc
              adc     dp:.tiny PR_WL
              tay
              lda     .near PR_X1
              adc     dp:.tiny (PR_WL+2)
              dec     a
              tax
              tya
              PUT32N  PR_XR
              txa                           ; xr < 0: off the side
              bmi     37$

              ;; vis = R_NewVisSprite(), or no more vissprites
              lda     .near num_vissprite
              cmp     ##CONST_MAXVISSPRITES
              bcs     37$
              asl     a                     ; * SIZEOF_VIS (42)
              asl     a
              adc     .near num_vissprite
              asl     a
              asl     a
              adc     .near num_vissprite
              asl     a
              PUTWN   PR_VIS
              tax                           ; X = the vissprite (to the tables)
              inc     .near num_vissprite   ; (16-bit: its high byte stays 0)

              ;; vis->gx: the thing (a long pointer: R_DrawSprite of
              ;; src/iigs/r_sprite65.s reads its x and y there, for its side
              ;; test); vis->gz = thing->z; gy: the patch (below)
              lda     dp:.tiny (TH+2)       ; (the bank, the fourth byte 0)
              and     ##0x00ff
              sta     abs:.near (vissprites + OFS_VIS_GX + 2),x
              lda     dp:.tiny TH
              sta     abs:.near (vissprites + OFS_VIS_GX),x
              ;; vis->texturemid = (gz + (topoffset << FRACBITS)) - viewz
              ldy     ##OFS_MO_Z
              lda     [.tiny TH],y
              sta     abs:.near (vissprites + OFS_VIS_GZ),x
              sec
              sbc     .near viewz
              sta     abs:.near (vissprites + OFS_VIS_TEXTUREMID),x
              iny
              iny
              lda     [.tiny TH],y
              sta     abs:.near (vissprites + OFS_VIS_GZ + 2),x
              sbc     .near (viewz+2)
              ldy     ##OFS_PATCH_TOPOFFSET
              clc
              adc     [.tiny PT],y
              sta     abs:.near (vissprites + OFS_VIS_TEXTUREMID + 2),x
              ;; vis->patch_topoffset = patch->topoffset
              lda     [.tiny PT],y
              sta     abs:.near (vissprites + OFS_VIS_TOPOFFSET),x
              ;; vis->lump_num = sprframe->lump[rot]; vis->gy = the patch, for
              ;; R_DrawVisSprite of src/iigs/r_seg65.s (3 bytes: the fourth
              ;; stays 0)
              lda     dp:.tiny PR_LMP
              sta     abs:.near (vissprites + OFS_VIS_LUMP),x
              lda     dp:.tiny PT
              sta     abs:.near (vissprites + OFS_VIS_GY),x
              lda     dp:.tiny (PT+1)
              sta     abs:.near (vissprites + OFS_VIS_GY + 1),x
              txy                           ; Y = the vissprite

              ;; vis->scale = (PROJECTIONY * FRACUNIT) / (tz >> FRACBITS)
              lda     .near (PR_TZ+2)       ; X = 4 d, d = tz >> FRACBITS (for
              asl     a                     ;   the tables of d below too)
              asl     a
              tax
              lda     long:SPRYSCALE,x
              VIS16   OFS_VIS_SCALE
              lda     long:(SPRYSCALE+2),x
              VIS16   (OFS_VIS_SCALE+2)
              ;; vis->fracstep = tz / (PROJECTIONY << COLEXTRABITS) = n / 5 for
              ;; n = tz >> 12 = 16 d + t: q + (r + t) / 5, FQ[d] = (q, r) =
              ;; (16 d / 5, 16 d % 5)
              lda     .near (PR_TZ+1)
              and     ##0x00f0
              lsr     a
              lsr     a
              lsr     a
              lsr     a                     ; t
              clc
              adc     long:(FQ+2),x         ; r + t: 0..19
              cmp     ##5
              bcc     31$
              cmp     ##10
              bcc     32$
              cmp     ##15
              lda     ##2                   ; 2, or 3 for 15 or more (carry)
              adc     ##0
              bra     33$
31$:          lda     ##0
              bra     33$
32$:          lda     ##1
33$:          clc
              adc     long:FQ,x
              VIS16   OFS_VIS_FRACSTEP
              ;; vis->x1 = x1 < 0 ? 0 : x1; vis->x2 = x2 >= VIEWWINDOWWIDTH ?
              ;; VIEWWINDOWWIDTH - 1 : x2 (bytes: their high bytes are 0)
              lda     .near PR_X1
              bpl     14$
              lda     ##0
14$:          sta     abs:.near (vissprites + OFS_VIS_X1),y ; (16-bit)
              lda     .near (PR_XR+2)       ; x2 = xr >> FRACBITS, 0 or more here
              cmp     ##CONST_VIEWWIDTH
              bcc     15$
              lda     ##(CONST_VIEWWIDTH - 1)
15$:          sta     abs:.near (vissprites + OFS_VIS_X2),y ; (16-bit)

              ;; iscale = FixedReciprocal(xscale) = SPRISCALE[d]; startfrac,
              ;; xiscale
              lda     .near PR_FLIP
              bne     16$
              lda     ##0                   ; startfrac = 0, xiscale = iscale
              VIS16   OFS_VIS_STARTFRAC
              VIS16   (OFS_VIS_STARTFRAC+2)
              lda     long:SPRISCALE,x
              VIS16   OFS_VIS_XISCALE
              lda     long:(SPRISCALE+2),x
              VIS16   (OFS_VIS_XISCALE+2)
              bra     17$
16$:          lda     ##0                   ; xiscale = -iscale
              sec
              sbc     long:SPRISCALE,x
              VIS16   OFS_VIS_XISCALE
              lda     ##0
              sbc     long:(SPRISCALE+2),x
              VIS16   (OFS_VIS_XISCALE+2)
              ldy     ##OFS_PATCH_WIDTH     ; startfrac = (width << FRACBITS) - 1
              lda     [.tiny PT],y
              dec     a
              ldy     .near PR_VIS
              VIS16   (OFS_VIS_STARTFRAC+2)
              lda     ##0xffff
              VIS16   OFS_VIS_STARTFRAC

              ;; vis->x1 > x1, that is x1 < 0:
              ;; startfrac += xiscale * (int16_t)(vis->x1 - x1)
17$:          lda     .near PR_X1
              bpl     18$
              eor     ##0xffff              ; vis->x1 - x1 = -x1, sign extended
              inc     a
              sta     dp:.tiny (_Dp+4)
              ldx     ##0
              cmp     ##0x8000
              bcc     23$
              dex
23$:          txa
              PUTWD   (_Dp+6)
              lda     abs:.near (vissprites + OFS_VIS_XISCALE),y
              PUTWD   _Dp
              lda     abs:.near (vissprites + OFS_VIS_XISCALE + 2),y
              PUTWD   (_Dp+2)
              jsl     long:_Mul32
              ldy     .near PR_VIS
              clc
              adc     abs:.near (vissprites + OFS_VIS_STARTFRAC),y
              VIS16   OFS_VIS_STARTFRAC
              txa
              adc     abs:.near (vissprites + OFS_VIS_STARTFRAC + 2),y
              VIS16   (OFS_VIS_STARTFRAC+2)

              ;; the colormap
18$:          ldy     ##(OFS_MO_FLAGS+2)
              lda     [.tiny TH],y
              and     ##CONST_MF_SHADOW_HI
              beq     19$
              lda     ##0                   ; shadow draw
              tax
              bra     27$
19$:          lda     .near fixedcolormap
              ora     .near (fixedcolormap+2)
              beq     20$
              lda     .near fixedcolormap   ; fixed map
              ldx     .near (fixedcolormap+2)
27$:          ldy     .near PR_VIS
              bra     22$
20$:          ldy     ##OFS_MO_FRAME
              lda     [.tiny TH],y
              ldy     .near PR_VIS
              asl     a                     ; FF_FULLBRIGHT: fullcolormap
              lda     ##0
              bcs     24$
              lda     abs:.near (vissprites + OFS_VIS_SCALE + 1),y ; the distance
              lsr     a                     ;   light (R_SpriteColorMap of r_bsp65):
              lsr     a                     ;   CMO[PR_S - min(23, scale >> 13)]
              lsr     a
              lsr     a
              lsr     a
              cmp     ##24
              bcc     25$
              lda     ##23
25$:          eor     ##0xffff
              sec
              adc     .near PR_S
              asl     a
              tax
              lda     long:CMO,x
24$:          ldx     ##.word2 fullcolormap ; fullcolormap + the offset
              clc
              adc     ##.word0 fullcolormap
              bcc     22$
              inx
22$:          sta     abs:.near (vissprites + OFS_VIS_COLORMAP),y ; X:C (the high
              txa                           ;   byte of its bank is 0)
              sta     abs:.near (vissprites + OFS_VIS_COLORMAP + 2),y ; (16-bit)
              brl     nextThing
;;; Opposite signs on both components put the thing behind the view.
;;; This test uses no product and also covers fractional thing coordinates:
;;; the signed high word has the sign of the full relative coordinate.
;;; The two callers are JSRs from the thing loop; discard that return word
;;; when rejecting, then take the unchanged nextThing path.
gTZ:          lda     dp:.tiny PR_HX
gTZsignX      .equ    .                     ; prFrame selects BPL or BMI
              bpl     gTZsum
              lda     dp:.tiny PR_HY
gTZsignY      .equ    .
              bpl     gTZcalc
              pla
              brl     nextThing
              .space  1                     ; original gTZ arithmetic keeps its address

;;; gTZcalc: X:C = TXH * c + TYH * s (mod 2^32), c = viewcos, s = viewsin, for
;;; PR_HX = TXH, PR_HY = TYH: K1 - K3 with K1 = (TXH + TYH) * c (kept in PR_K1
;;; for gTX) and K3 = TYH * (c - s) (Gauss: 3 products for tz and tx instead
;;; of 4). The high word of a * b: the unsigned product of a and b.lo, less
;;; b.lo for a < 0, plus a * b.hi (b.hi of c: 0 or -1; of c - s and s + c:
;;; -2..1, the code at K3FIX and K2FIX that prFrame sets for the frame).
gTZcalc:      lda     dp:.tiny PR_HX        ; S = TXH + TYH
gTZsum:       clc
              adc     dp:.tiny PR_HY
              bvs     9$                    ; (out of int16: never in the maps)
              PUTWD   PR_HS
              lda     .near viewcos         ; K1 = S * c
              PUTWD   MA
              lda     dp:.tiny PR_HS
              jsr     .kbank qmul           ; Y = low, C = high
              ldx     dp:.tiny PR_HS        ; S < 0: - c.lo
              bpl     1$
              sec
              sbc     dp:.tiny MA
1$:           ldx     .near (viewcos+2)     ; c < 0: - S
              beq     2$
              sec
              sbc     dp:.tiny PR_HS
2$:           PUTWD   (PR_K1+2)
              sty     dp:.tiny PR_K1
3$:           lda     dp:.tiny PR_GBL       ; K3 = TYH * GB, GB = c - s
              PUTWD   MA
              lda     dp:.tiny PR_HY
              jsr     .kbank qmul
              ldx     dp:.tiny PR_HY        ; TYH < 0: - GB.lo
              bpl     4$
              sec
              sbc     dp:.tiny MA
4$:
K3FIX         .equ    . + 0
              bra     5$                    ; + TYH * GB.hi (prFrame)
              nop
              nop
              nop
              nop
5$:           tax                           ; X:C = K1 - K3
              tya
              eor     ##0xffff
              sec
              adc     dp:.tiny PR_K1
              tay
              txa
              eor     ##0xffff
              adc     dp:.tiny (PR_K1+2)
              tax
              tya
              rts
9$:           tax                           ; K1 with S of 17 bits
              lda     .near viewcos
              PUTWD   MA
              txa
              jsl     long:k1Wide
              bra     3$

;;; gTX: X:C = TXH * s - TYH * c = K2 - K1 (after gTZ), K2 = TXH * (s + c).
gTX:          lda     dp:.tiny PR_GCL       ; K2 = TXH * GC, GC = s + c
              PUTWD   MA
              lda     dp:.tiny PR_HX
              jsr     .kbank qmul
              ldx     dp:.tiny PR_HX        ; TXH < 0: - GC.lo
              bpl     1$
              sec
              sbc     dp:.tiny MA
1$:
K2FIX         .equ    . + 0
              bra     2$                    ; + TXH * GC.hi (prFrame)
              nop
              nop
              nop
              nop
2$:           tax                           ; X:C = K2 - K1
              tya
              sec
              sbc     dp:.tiny PR_K1
              tay
              txa
              sbc     dp:.tiny (PR_K1+2)
              tax
              tya
              rts

;;; bitOf: 1 << rot, by rot * 2.
bitOf:        .word   1, 2, 4, 8, 16, 32, 64, 128

;;; Fractional-coordinate caller: the same test before gGZ, then gTZcalc.
gGZcheck:     lda     dp:.tiny PR_HX
gGZsignX      .equ    .
              bpl     gGZgo
              lda     dp:.tiny PR_HY
gGZsignY      .equ    .
              bpl     gGZgo
              pla
              brl     nextThing
gGZgo:        jmp     .kbank gGZ

              .space  PS_PADN               ; (see PS_PADN: the code after it keeps
                                            ;   its addresses)

;;; ---------------------------------------------------------------------------
;;; void R_InitSpriteIScales(void): SPRISCALE[d] = FixedReciprocal(SPRXSCALE[d]),
;;; d = 1..1280, the same values as FixedReciprocal of projectSprite gave;
;;; FQ[d] = (16 d / 5, 16 d % 5), d = 0..1280 (vis->fracstep); SPRBOUND[s]
;;; = (E, E / 2 + 2) for each sprite s: E = the largest leftoffset or width
;;; - leftoffset of the patches of the frames of s that the states use
;;; (0x3fff for none or more); PR_IOK = 1. R_WallFrame
;;; (src/iigs/r_wall65.s) calls it on the first frame, with WP_SPR and WP_FI.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public R_InitSpriteIScales
R_InitSpriteIScales:
              ldx     ##4                   ; 4 d
1$:           phx
              lda     long:(SPRXSCALE+2),x
              tay
              lda     long:SPRXSCALE,x
              tyx
              jsl     long:FixedReciprocal
              txy
              plx
              sta     long:SPRISCALE,x
              tya
              sta     long:(SPRISCALE+2),x
              inx
              inx
              inx
              inx
              cpx     ##(4 * (MAXZ_HI + 1))
              bcc     1$
              jmp     long:fqInit
              .space  3                     ; (its old size: the cold code keeps
                                            ;   its place)

;;; fqInit, boundInit, frameInit: FQ, SPRBOUND, then PR_IOK = 1 (small
;;; fragments: the other cold code keeps its place).
              .section coldcode, text
fqInit:       ldx     ##0                   ; X = 4 d, C = q, Y = r
              txa
              txy
2$:           sta     long:FQ,x
              pha
              tya
              sta     long:(FQ+2),x
              pla
              clc                           ; d + 1: 16 more = 3 * 5 + 1
              adc     ##3
              iny
              cpy     ##5
              bcc     3$
              ldy     ##0
              inc     a
3$:           inx
              inx
              inx
              inx
              cpx     ##(4 * (MAXZ_HI + 1))
              bcc     2$
              jmp     long:boundInit

              .section coldcode, text
boundInit:    ldx     ##(4 * (CONST_NUMSPRITES - 1)) ; SPRBOUND: 0, and in its
              lda     ##0                   ;   second word the number of
4$:           sta     long:SPRBOUND,x       ;   frames that the states use
              sta     long:(SPRBOUND+2),x
              dex
              dex
              dex
              dex
              bpl     4$
              ldy     ##0                   ; each state
5$:           lda     abs:.near (states + OFS_ST_SPRITE),y
              asl     a
              asl     a
              tax
              lda     abs:.near (states + OFS_ST_FRAME),y
              and     ##0x7fff
              inc     a
              cmp     long:(SPRBOUND+2),x
              bcc     6$
              sta     long:(SPRBOUND+2),x
6$:           tya
              clc
              adc     ##STATE_SIZE
              tay
              cpy     ##(CONST_NUMSTATES * STATE_SIZE)
              bcc     5$
              jmp     long:frameInit

              .section coldcode, text
frameInit:
              ldx     ##0                   ; X = 4 s
7$:           txy                           ; SF = sprites[s].spriteframes
              lda     [.tiny WP_SPR],y
              sta     dp:.tiny SF
              iny
              iny
              lda     [.tiny WP_SPR],y
              sep     #0x20
              sta     dp:.tiny (SF+2)
              rep     #0x20
              ora     dp:.tiny SF
              beq     15$                   ; none
              lda     long:(SPRBOUND+2),x   ; the frames
              beq     15$
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)      ; E
8$:           ldy     ##OFS_SF_ROTATE       ; the rotations: 8, or 1
              lda     [.tiny SF],y
              beq     9$
              lda     ##(2 * 7)
9$:           sta     dp:.tiny (_Dp+8)      ; 2 r
10$:          ldy     dp:.tiny (_Dp+8)      ; the patch of lump[r]
              lda     [.tiny SF],y
              asl     a                     ; * FILELUMP_SIZE
              asl     a
              asl     a
              asl     a
              tay
              lda     [.tiny WP_FI],y
              sta     dp:.tiny PT
              iny
              iny
              lda     [.tiny WP_FI],y
              clc
              adc     ##WAD_BANK
              sep     #0x20
              sta     dp:.tiny (PT+2)
              rep     #0x20
              ldy     ##OFS_PATCH_LEFTOFFSET ; E = max(E, leftoffset, width -
              lda     [.tiny PT],y          ;   leftoffset), signed
              bmi     11$
              cmp     dp:.tiny (_Dp+6)
              bcc     11$
              sta     dp:.tiny (_Dp+6)
11$:          eor     ##0xffff
              sec
              ldy     ##OFS_PATCH_WIDTH
              adc     [.tiny PT],y
              bvs     15$                   ; more than 32767
              bmi     12$
              cmp     dp:.tiny (_Dp+6)
              bcc     12$
              sta     dp:.tiny (_Dp+6)
12$:          dec     dp:.tiny (_Dp+8)
              dec     dp:.tiny (_Dp+8)
              bpl     10$
              lda     dp:.tiny SF           ; the next frame
              clc
              adc     ##SIZEOF_SF
              sta     dp:.tiny SF
              dec     dp:.tiny (_Dp+4)
              bne     8$
              lda     dp:.tiny (_Dp+6)
              cmp     ##0x3fff
              bcc     16$
15$:          lda     ##0x3fff
16$:          sta     long:SPRBOUND,x
              lsr     a
              clc
              adc     ##2
              sta     long:(SPRBOUND+2),x
              inx
              inx
              inx
              inx
              cpx     ##(4 * CONST_NUMSPRITES)
              bcs     17$
              brl     7$
17$:          lda     ##1
              sta     .near PR_IOK
              jmp     long:dsaInit          ; (the drawseg addresses: r_sprite65)

;;; ---------------------------------------------------------------------------
;;; gGZ, gGX: PR_TX = the G parts of tz, tx of a thing that is not at whole
;;; map units: G(TXL, c) + G(TYL, s) and G(TXL, s) - G(TYL, c), G(L, b) =
;;; hi16(L * b.lo) - (b < 0 ? L : 0) with qmulh (+ 0 or 1 in the last bit,
;;; as FixedMul3216 of the old fmq), for TXL = PR_TRX, TYL = PR_TRY (the low
;;; words of tr_x, tr_y); gTZ and gTX add TXH * c + TYH * s and TXH * s -
;;; TYH * c.
;;; ---------------------------------------------------------------------------
              .section bspcode, text
gGZ:          lda     .near viewcos         ; G(TXL, c)
              PUTWD   MA
              lda     .near PR_TRX
              jsr     .kbank qmulh
              ldx     ##0
              ldy     .near (viewcos+2)
              beq     1$
              sec
              sbc     .near PR_TRX
              bcs     1$
              dex
1$:           PUTWN   PR_TX
              txa
              PUTWN   (PR_TX+2)
              lda     .near viewsin         ; + G(TYL, s)
              PUTWD   MA
              lda     .near PR_TRY
              jsr     .kbank qmulh
              ldx     ##0
              ldy     .near (viewsin+2)
              beq     2$
              sec
              sbc     .near PR_TRY
              bcs     2$
              dex
2$:           clc
              adc     .near PR_TX
              PUTWN   PR_TX
              txa
              adc     .near (PR_TX+2)
              PUTWN   (PR_TX+2)
              rts

gGX:          lda     .near viewsin         ; G(TXL, s)
              PUTWD   MA
              lda     .near PR_TRX
              jsr     .kbank qmulh
              ldx     ##0
              ldy     .near (viewsin+2)
              beq     1$
              sec
              sbc     .near PR_TRX
              bcs     1$
              dex
1$:           PUTWN   PR_TX
              txa
              PUTWN   (PR_TX+2)
              lda     .near viewcos         ; - G(TYL, c)
              PUTWD   MA
              lda     .near PR_TRY
              jsr     .kbank qmulh
              ldx     ##0
              ldy     .near (viewcos+2)
              beq     2$
              sec
              sbc     .near PR_TRY
              bcs     2$
              dex
2$:           eor     ##0xffff
              sec
              adc     .near PR_TX
              PUTWN   PR_TX
              txa
              eor     ##0xffff
              adc     .near (PR_TX+2)
              PUTWN   (PR_TX+2)
              rts

;;; wHi: C += lo16(width * xscale.hi), MA = width (the high word of W of a
;;; close thing, xscale >= 1.0); keeps Y.
wHi:          PUTWD   PR_HS
              phy
              lda     dp:.tiny (_Dp+2)
              jsr     .kbank qmul           ; Y = lo16(width * xscale.hi)
              tya
              clc
              adc     dp:.tiny PR_HS
              ply
              rts
              .space  GG_PADN               ; (the size of the old tzAny fragment)

;;; ---------------------------------------------------------------------------
;;; prFrame: the constants of gTZ and gTX for the frame: PR_GBL, PR_GCL and
;;; the code at K3FIX and K2FIX for GB.hi and GC.hi (R_WallFrame of
;;; src/iigs/r_wall65.s jumps here at its end, each frame).
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public prFrame
prFrame:      lda     .near viewcos         ; GB = c - s
              sec
              sbc     .near viewsin
              PUTWD   PR_GBL
              lda     .near (viewcos+2)
              sbc     .near (viewsin+2)
              clc
              adc     ##3                   ; 1 + GB.hi + 2: 1..4
              sep     #0x20
              cmp     .near PR_GBI
              beq     1$
              sta     .near PR_GBI
              rep     #0x20
              and     ##0x00ff
              dec     a                     ; X = 6 * (GB.hi + 2)
              asl     a
              PUTWD   PR_HS
              asl     a
              adc     dp:.tiny PR_HS
              tax
              lda     long:k3Tpl,x
              sta     long:K3FIX
              lda     long:(k3Tpl+2),x
              sta     long:(K3FIX+2)
              lda     long:(k3Tpl+4),x
              jsl     long:c12Patch3
1$:           rep     #0x20
              lda     .near viewsin         ; GC = s + c
              clc
              adc     .near viewcos
              PUTWD   PR_GCL
              lda     .near (viewsin+2)
              adc     .near (viewcos+2)
              clc
              adc     ##3
              sep     #0x20
              cmp     .near PR_GCI
              beq     2$
              sta     .near PR_GCI
              rep     #0x20
              and     ##0x00ff
              dec     a
              asl     a
              PUTWD   PR_HS
              asl     a
              adc     dp:.tiny PR_HS
              tax
              lda     long:k2Tpl,x
              sta     long:K2FIX
              lda     long:(k2Tpl+2),x
              sta     long:(K2FIX+2)
              lda     long:(k2Tpl+4),x
              jsl     long:c12Patch2
2$:           rep     #0x20
              rtl

;;; The code at K3FIX (+ TYH * GB.hi to the high word of K3) and at K2FIX (+
;;; TXH * GC.hi to K2) for GB.hi, GC.hi = -2, -1, 0, 1: 6 bytes each.
k3Tpl:        sec                           ; -2
              sbc     dp:.tiny PR_HY
              sec
              sbc     dp:.tiny PR_HY
              sec                           ; -1
              sbc     dp:.tiny PR_HY
              bra     1$
              nop
1$:           bra     2$                    ; 0
              nop
              nop
              nop
              nop
2$:           clc                           ; 1
              adc     dp:.tiny PR_HY
              bra     3$
              nop
3$:
k2Tpl:        sec                           ; -2
              sbc     dp:.tiny PR_HX
              sec
              sbc     dp:.tiny PR_HX
              sec                           ; -1
              sbc     dp:.tiny PR_HX
              bra     4$
              nop
4$:           bra     5$                    ; 0
              nop
              nop
              nop
              nop
5$:           clc                           ; 1
              adc     dp:.tiny PR_HX
              bra     6$
              nop
6$:

;;; k1Wide: PR_K1 = S * c for S = TXH + TYH out of int16 (gTZ: C = S mod
;;; 2^16, MA = c.lo): the sign of S is the opposite of bit 15.
k1Wide:       PUTWD   PR_HS
              jsl     long:qmulL            ; Y = low, C = high
              ldx     dp:.tiny PR_HS        ; S < 0 (bit 15 clear): - c.lo
              bmi     1$
              sec
              sbc     dp:.tiny MA
1$:           ldx     .near (viewcos+2)     ; c < 0: - S
              beq     2$
              sec
              sbc     dp:.tiny PR_HS
2$:           PUTWD   (PR_K1+2)
              sty     dp:.tiny PR_K1
              rtl

;;; labsTZ: C = 1 for labs(tx) > tz << 2, too far off the side (the test of
;;; R_ProjectSprite; after the SPRBOUND test only possible for tz.hi < E / 2
;;; + 2: close things); X = sprite * 4 again.
              .section coldcode, text
labsTZ:       lda     .near PR_TZ           ; X:C = tz << 2
              asl     a
              tay
              lda     .near (PR_TZ+2)
              rol     a
              tax
              tya
              asl     a
              tay
              txa
              rol     a
              tax
              tya
              bit     .near (PR_TX+2)
              bmi     3$
              sec                           ; tx >= 0: (tz << 2) - tx < 0
              sbc     .near PR_TX
              txa
              sbc     .near (PR_TX+2)
              bra     4$
3$:           clc                           ; tx < 0: (tz << 2) + tx < 0
              adc     .near PR_TX
              txa
              adc     .near (PR_TX+2)
4$:           php                           ; (N: off the side)
              ldy     ##OFS_MO_SPRITE       ; X = sprite * 4 again
              lda     [.tiny TH],y
              asl     a
              asl     a
              tax
              plp
              clc
              bpl     5$
              sec
5$:           rtl

;;; ---------------------------------------------------------------------------
;;; The smaller views (src/iigs/viewwin.inc): the replay draws only the kept
;;; columns (the half view: the even ones; the 2/3 view: n mod 3 < 2), so the
;;; sprites and the masked walls make records only for them. hvPatch (from
;;; vwFrame of src/iigs/r_frame65.s when the size changes) puts the code of
;;; the size at the sites below, or the bytes as assembled (HV_SAVE) for the
;;; full view, which runs no test for it:
;;;   site                    half view         2/3 view
;;;   visColD (4 bytes)       jml vcHalf        jml vc3
;;;   mwCols (5 bytes)        jsl mwHalf, nop   jsl mw3, nop
;;;   mwNextCol (4 bytes)     jsl mwNx2         jsl mwN3
;;;   visDone (4 bytes)       (as assembled)    jml vd3
;;;   vrCol8 (3 bytes)        (as assembled)    jmp vr3Col8
;;;   VR_NX (3 bytes)         (as assembled)    jmp vr3Nx
;;; VN_STEP (the W_X2 step of visNext, src/iigs/r_seg65.s): vcHalf and vc3
;;; set it for each sprite, hvSet sets 2 for the full view.
;;; The shadow sprites (R_DrawVisSpriteFuzz of src/iigs/r_sprite65.s) keep all
;;; their columns: the fuzz position of a column follows the rows of the
;;; columns before it, so the kept columns stay as in the full view.
;;; Section vwcode: its own region (Code4g), no other code moves.
;;; ---------------------------------------------------------------------------
HV_SAVE       .equ    (MM_BV + 0xb702) ; the 17 bytes of the sites as assembled
HV_P3         .equ    (MM_BV + 0xb714) ; the 2/3 view: 1 while pass 2 of the
HV_P3X        .equ    (MM_BV + 0xb716) ;   sprite is to come; its first W_X2
HV_P3F        .equ    (MM_BV + 0xb718) ;   and frac (4 bytes)
HV_SV2        .equ    (MM_BV + 0xb71c) ; 6 more bytes of the sites (vrCol8, VR_NX)
V_REP         .equ    W_YH            ; (V_REP and V_XEND of
V_XEND        .equ    W_CC            ;   src/iigs/r_frame65.s)
MW_MTC_H      .equ    (BSPDP+44)      ; MW_MTC of mwCols (src/iigs/r_frame65.s)
HVP_PAD       .equ    203             ; hvPatch keeps its old size: no code
                                      ;   of vwcode moves (hvSet: vw3code)

              .section vwcode, text
              .public hvPatch
              .extern oneViewMode, c5Mode
;;; The 1/4 and 1/3 views do not set VW_HALF or VW_THIRD, so hvSet leaves
;;; the full-view sprite and masked-wall walks in place. Those walks cost
;;; the same as the full view (wdProf, vrCol8, vrPost) and the replay then
;;; drops every column the view does not show. qApply installs the same
;;; kind of stride the half view uses: 4 or 3 columns a step, on the kept
;;; phase only. The byte size of this fragment stays put (writeFile follows).
;;; C12 stays in the same pad: prFrame's coefficient stores also set the
;;; reject-branch senses. 17 is the growth of the calls below versus
;;; jsl c5Mode / jmp hvSet, so hvT does not move.
hvPatch:      jsl     long:c5Mode
              php
              phx
              jsl     long:qUndo
              plx
              plp
              jsl     long:hvSet
              php
              phx
              jsl     long:qApply
              plx
              plp
              rtl
c12Patch3:    sta     long:(K3FIX+4)
              bra     c12Signs
c12Patch2:    sta     long:(K2FIX+4)
c12Signs:     sep     #0x20
              lda     .near (viewcos+3)
              and     #0x20
              ora     #0x10                 ; BPL for c >= 0, BMI for c < 0
              sta     long:gTZsignX
              sta     long:gGZsignX
              lda     .near (viewsin+3)
              and     #0x20
              ora     #0x10
              sta     long:gTZsignY
              sta     long:gGZsignY
              rep     #0x20
              rtl
              .space  HVP_PAD - 4 - 45 - 17

;;; hvT: the code of the half view at the sites (the same order as HV_SAVE).
hvT:          jmp     long:vcHalf           ; visColD
              jsl     long:mwHalf           ; mwCols
              nop
              jsl     long:mwNx2            ; mwNextCol

;;; vcHalf: visColD (src/iigs/r_frame65.s) in the half view: every sprite
;;; takes visCol (src/iigs/r_seg65.s), only the even columns: an odd first
;;; column goes one column on (frac += xiscale), then 2 * xiscale and 2
;;; columns a step (VN_STEP 4). Direct page WPAGE, DBR = RECBANK: long and
;;; direct page operands only.
vcHalf:       sep     #0x20                 ; the column step of visNext: 2
              lda     #2                    ;   for the clip pass of the weapon
              ldx     dp:V_CLIP             ;   (all columns, as the full view:
              bne     2$                    ;   the walk after it reads its
              lda     #4                    ;   floorclip), else 4
2$:           sta     long:VN_STEP
              rep     #0x20
              txa
              bne     8$
              lda     dp:W_X2               ; 2 * x1: bit 1 for an odd x1
              and     ##2
              beq     1$
              clc                           ; frac += xiscale
              lda     dp:V_FRAC
              adc     dp:V_XIS
              sta     dp:V_FRAC
              lda     dp:(V_FRAC+2)
              adc     dp:(V_XIS+2)
              sta     dp:(V_FRAC+2)
              bmi     9$                    ; frac < 0: no column
              cmp     dp:V_WIDTH            ; (frac >> FRACBITS) >= width
              bcs     9$
              lda     dp:W_X2
              clc
              adc     ##2
              sta     dp:W_X2
1$:           asl     dp:V_XIS              ; 2 * xiscale
              rol     dp:(V_XIS+2)
8$:           jmp     long:visCol
9$:           jmp     long:visDone

;;; mwHalf: the first two instructions of mwCols (src/iigs/r_frame65.s) in
;;; the half view: only the even columns of the range: an odd FR_X goes one
;;; column on (spryscale += rw_scalestep, FR_P += FR_B, as mwNextCol), then
;;; both steps double (maskedRange makes them again for each range) and
;;; mwNextCol takes 2 columns a step (mwNx2).
mwHalf:       lda     .near FR_X
              lsr     a
              bcc     1$
              inc     .near FR_X
              lda     .near spryscale
              clc
              adc     .near rw_scalestep
              sta     .near spryscale
              lda     .near (spryscale+2)
              adc     .near (rw_scalestep+2)
              sta     .near (spryscale+2)
              lda     .near FR_P
              clc
              adc     .near FR_B
              sta     .near FR_P
              lda     .near (FR_P+2)
              adc     .near (FR_B+2)
              sta     .near (FR_P+2)
              lda     .near (FR_P+4)
              adc     .near (FR_B+4)
              sta     .near (FR_P+4)
1$:           asl     .near rw_scalestep
              rol     .near (rw_scalestep+2)
              asl     .near FR_B
              rol     .near (FR_B+2)
              rol     .near (FR_B+4)
              lda     .near maskedtexturecol ; (the two instructions of mwCols)
              sta     dp:.tiny MW_MTC_H
              rtl

;;; mwNx2: the first two instructions of mwNextCol in the half view: C =
;;; FR_X + 2.
mwNx2:        lda     .near FR_X
              inc     a
              inc     a
              rtl

;;; ---------------------------------------------------------------------------
;;; The code of the 2/3 view and hvSet (hvPatch). Section vw3code: a fixed
;;; place in Code4g (src/iigs/iigs.scm), so the fragments of vwcode keep
;;; theirs. The code for each sprite and masked column first, then M3, in
;;; slots $6100-$6453: $6100-$620D was the quietest page of the 2/3 masked
;;; pass (full demo3 profile: 277 data reads a frame, 0.02 ms of code).
;;; ---------------------------------------------------------------------------
              .section qstride, text
;;; wdSmall: A = 0 when the weapon profile (wdProf) matches this view.
;;; The 1/4 and 1/3 views keep one column in four or three, so the profile
;;; of every column is the wrong set; half and 2/3 already skipped it.
              .public wdSmall
wdSmall:      sep     #0x20
              lda     long:VW_SIZE
              cmp     #VW_QUARTERSIZE
              beq     1$
              cmp     #VW_ONESIZE
              beq     1$
              lda     long:VW_HALF
              ora     long:VW_THIRD
              beq     2$
1$:           rep     #0x20
              lda     ##1
              rtl
2$:           rep     #0x20
              lda     ##0
              rtl
;;; qUndo: if a stride is installed, put the full-view bytes back so hvSet
;;; sees the sites as assembled. 16-bit X is kept by the caller.
qUndo:        sep     #0x20
              lda     long:Q_ON
              bne     1$
              rep     #0x20
              rtl
1$:           rep     #0x20
              jsr     .kbank qRestore
              sep     #0x20
              lda     #0
              sta     long:Q_ON
              lda     #2                    ; full and 3/4 can keep PR_HVS = 0
              sta     long:VN_STEP
              rep     #0x20
              rtl
;;; qApply: quarter (c mod 4 = 0, step 8) or 1/3 (c mod 3 = 0, step 6).
qApply:       sep     #0x20
              lda     long:VW_SIZE
              cmp     #VW_QUARTERSIZE
              bne     1$
              lda     #8
              sta     long:Q_XN
              lda     #4
              bra     3$
1$:           cmp     #VW_ONESIZE
              bne     9$
              lda     #6
              sta     long:Q_XN
              lda     #3
3$:           sta     long:Q_MOD
              lda     long:Q_ON
              bne     4$
              jsr     .kbank qSave
4$:           sep     #0x20
              lda     #1
              sta     long:Q_ON
              rep     #0x20
              lda     long:qT
              sta     long:visColD
              lda     long:(qT+2)
              sta     long:(visColD+2)
              lda     long:(qT+4)
              sta     long:mwCols
              lda     long:(qT+6)
              sta     long:(mwCols+2)
              sep     #0x20
              lda     long:(qT+8)
              sta     long:(mwCols+4)
              rep     #0x20
              lda     long:(qT+9)
              sta     long:mwNextCol
              lda     long:(qT+11)
              sta     long:(mwNextCol+2)
              jsr     .kbank qGateOn
              rtl
9$:           rep     #0x20
              rtl
qSave:        rep     #0x20
              lda     long:visColD
              sta     long:Q_SAVE
              lda     long:(visColD+2)
              sta     long:(Q_SAVE+2)
              lda     long:mwCols
              sta     long:(Q_SAVE+4)
              lda     long:(mwCols+2)
              sta     long:(Q_SAVE+6)
              sep     #0x20
              lda     long:(mwCols+4)
              sta     long:(Q_SAVE+8)
              rep     #0x20
              lda     long:mwNextCol
              sta     long:(Q_SAVE+9)
              lda     long:(mwNextCol+2)
              sta     long:(Q_SAVE+11)
              jsr     .kbank qGateSave
              rts
qRestore:     lda     long:Q_SAVE
              sta     long:visColD
              lda     long:(Q_SAVE+2)
              sta     long:(visColD+2)
              lda     long:(Q_SAVE+4)
              sta     long:mwCols
              lda     long:(Q_SAVE+6)
              sta     long:(mwCols+2)
              sep     #0x20
              lda     long:(Q_SAVE+8)
              sta     long:(mwCols+4)
              rep     #0x20
              lda     long:(Q_SAVE+9)
              sta     long:mwNextCol
              lda     long:(Q_SAVE+11)
              sta     long:(mwNextCol+2)
              jsr     .kbank qGateRestore
              rts
;;; The weapon profile covers every column. On these views, point (wdDraw+28) at
;;; wdSmall for the whole time the stride is installed, and put the original
;;; 10 bytes back afterwards so the full view does not pay for the call.
qGateSave:    sep     #0x20
              lda     long:(wdDraw+28)
              sta     long:Q_GATE
              lda     long:((wdDraw+28)+1)
              sta     long:(Q_GATE+1)
              lda     long:((wdDraw+28)+2)
              sta     long:(Q_GATE+2)
              lda     long:((wdDraw+28)+3)
              sta     long:(Q_GATE+3)
              lda     long:((wdDraw+28)+4)
              sta     long:(Q_GATE+4)
              lda     long:((wdDraw+28)+5)
              sta     long:(Q_GATE+5)
              lda     long:((wdDraw+28)+6)
              sta     long:(Q_GATE+6)
              lda     long:((wdDraw+28)+7)
              sta     long:(Q_GATE+7)
              lda     long:((wdDraw+28)+8)
              sta     long:(Q_GATE+8)
              lda     long:((wdDraw+28)+9)
              sta     long:(Q_GATE+9)
              rep     #0x20
              rts
qGateRestore: sep     #0x20
              lda     long:Q_GATE
              sta     long:(wdDraw+28)
              lda     long:(Q_GATE+1)
              sta     long:((wdDraw+28)+1)
              lda     long:(Q_GATE+2)
              sta     long:((wdDraw+28)+2)
              lda     long:(Q_GATE+3)
              sta     long:((wdDraw+28)+3)
              lda     long:(Q_GATE+4)
              sta     long:((wdDraw+28)+4)
              lda     long:(Q_GATE+5)
              sta     long:((wdDraw+28)+5)
              lda     long:(Q_GATE+6)
              sta     long:((wdDraw+28)+6)
              lda     long:(Q_GATE+7)
              sta     long:((wdDraw+28)+7)
              lda     long:(Q_GATE+8)
              sta     long:((wdDraw+28)+8)
              lda     long:(Q_GATE+9)
              sta     long:((wdDraw+28)+9)
              rep     #0x20
              rts
qGateOn:      sep     #0x20
              lda     #0x22
              sta     long:(wdDraw+28)
              lda     #.byte0 wdSmall
              sta     long:((wdDraw+28)+1)
              lda     #.byte1 wdSmall
              sta     long:((wdDraw+28)+2)
              lda     #.byte2 wdSmall
              sta     long:((wdDraw+28)+3)
              lda     #0xd0
              sta     long:((wdDraw+28)+4)
              lda     long:(Q_GATE+9)
              clc
              adc     #4
              sta     long:((wdDraw+28)+5)
              lda     #0xea
              sta     long:((wdDraw+28)+6)
              sta     long:((wdDraw+28)+7)
              sta     long:((wdDraw+28)+8)
              sta     long:((wdDraw+28)+9)
              rep     #0x20
              rts
;;; qT: the three sites, in the order hvT uses (visColD, mwCols, mwNextCol).
qT:           jmp     long:vcQ
              jsl     long:mwQ
              nop
              jsl     long:mwNxQ
;;; One column of a sprite before the stride is multiplied. Carry set: stop.
qStep:        clc
              lda     dp:V_FRAC
              adc     dp:V_XIS
              sta     dp:V_FRAC
              lda     dp:(V_FRAC+2)
              adc     dp:(V_XIS+2)
              sta     dp:(V_FRAC+2)
              bmi     9$
              cmp     dp:V_WIDTH
              bcs     9$
              lda     dp:W_X2
              clc
              adc     ##2
              sta     dp:W_X2
              clc
              rts
9$:           sec
              rts
;;; vcQ: visColD for the 1/4 and 1/3 views. The clip pass still walks every
;;; column (the weapon reads every floorclip). The draw pass aligns onto
;;; the kept phase, then multiplies xiscale and the column step.
vcQ:          sep     #0x20
              lda     #2
              ldx     dp:V_CLIP
              bne     2$
              lda     long:Q_XN
2$:           sta     long:VN_STEP
              rep     #0x30
              txa
              bne     8$
              phy
              ldy     ##3
1$:           lda     dp:W_X2
              lsr     a
              sec
3$:           sbc     long:Q_MOD
              bcs     3$
              adc     long:Q_MOD
              beq     4$
              jsr     .kbank qStep
              bcs     6$
              dey
              bne     1$
4$:           ply
              sep     #0x20
              lda     long:Q_MOD
              cmp     #3
              beq     5$
              rep     #0x20
              asl     dp:V_XIS
              rol     dp:(V_XIS+2)
              asl     dp:V_XIS
              rol     dp:(V_XIS+2)
              bra     8$
5$:           rep     #0x20
              lda     dp:V_XIS
              sta     long:Q_TMP
              lda     dp:(V_XIS+2)
              sta     long:(Q_TMP+2)
              asl     dp:V_XIS
              rol     dp:(V_XIS+2)
              clc
              lda     dp:V_XIS
              adc     long:Q_TMP
              sta     dp:V_XIS
              lda     dp:(V_XIS+2)
              adc     long:(Q_TMP+2)
              sta     dp:(V_XIS+2)
8$:           jmp     long:visCol
6$:           ply
7$:           jmp     long:visDone
;;; One masked column before the steps are multiplied.
qMw:          inc     .near FR_X
              lda     .near spryscale
              clc
              adc     .near rw_scalestep
              sta     .near spryscale
              lda     .near (spryscale+2)
              adc     .near (rw_scalestep+2)
              sta     .near (spryscale+2)
              lda     .near FR_P
              clc
              adc     .near FR_B
              sta     .near FR_P
              lda     .near (FR_P+2)
              adc     .near (FR_B+2)
              sta     .near (FR_P+2)
              lda     .near (FR_P+4)
              adc     .near (FR_B+4)
              sta     .near (FR_P+4)
              rts
mwQ:          rep     #0x30
              phy
              ldy     ##3
1$:           lda     .near FR_X
              sec
2$:           sbc     long:Q_MOD
              bcs     2$
              adc     long:Q_MOD
              beq     3$
              jsr     .kbank qMw
              dey
              bne     1$
3$:           ply
              sep     #0x20
              lda     long:Q_MOD
              cmp     #3
              beq     4$
              rep     #0x20
              asl     .near rw_scalestep
              rol     .near (rw_scalestep+2)
              asl     .near rw_scalestep
              rol     .near (rw_scalestep+2)
              asl     .near FR_B
              rol     .near (FR_B+2)
              rol     .near (FR_B+4)
              asl     .near FR_B
              rol     .near (FR_B+2)
              rol     .near (FR_B+4)
              bra     5$
4$:           rep     #0x20
              lda     .near rw_scalestep
              sta     long:Q_TMP
              lda     .near (rw_scalestep+2)
              sta     long:(Q_TMP+2)
              asl     .near rw_scalestep
              rol     .near (rw_scalestep+2)
              clc
              lda     .near rw_scalestep
              adc     long:Q_TMP
              sta     .near rw_scalestep
              lda     .near (rw_scalestep+2)
              adc     long:(Q_TMP+2)
              sta     .near (rw_scalestep+2)
              lda     .near FR_B
              sta     long:Q_TMP
              lda     .near (FR_B+2)
              sta     long:(Q_TMP+2)
              lda     .near (FR_B+4)
              sta     long:(Q_TMP+4)
              asl     .near FR_B
              rol     .near (FR_B+2)
              rol     .near (FR_B+4)
              clc
              lda     .near FR_B
              adc     long:Q_TMP
              sta     .near FR_B
              lda     .near (FR_B+2)
              adc     long:(Q_TMP+2)
              sta     .near (FR_B+2)
              lda     .near (FR_B+4)
              adc     long:(Q_TMP+4)
              sta     .near (FR_B+4)
5$:           lda     .near maskedtexturecol
              sta     dp:.tiny MW_MTC_H
              rtl
mwNxQ:        lda     .near FR_X
              clc
              adc     long:Q_MOD
              rtl
Q_ON:         .byte   0
Q_MOD:        .word   4
Q_XN:         .word   8
Q_TMP:        .word   0, 0, 0
Q_SAVE:       .space  13
Q_GATE:       .space  10

              .section vw3code, text
MV4           .macro  src, dst
              lda     long:\src
              sta     long:\dst
              lda     long:(\src+2)
              sta     long:(\dst+2)
              .endm
MV5           .macro  src, dst
              lda     long:\src
              sta     long:\dst
              lda     long:(\src+2)
              sta     long:(\dst+2)
              lda     long:(\src+3)
              sta     long:(\dst+3)
              .endm
MV3           .macro  src, dst
              lda     long:\src
              sta     long:\dst
              lda     long:(\src+1)
              sta     long:(\dst+1)
              .endm

;;; vc3: visColD (src/iigs/r_frame65.s) in the 2/3 view: a magnified sprite
;;; takes vr3Col8; the others take visCol (src/iigs/r_seg65.s) for their
;;; columns n mod 3 < 2 in two passes, one for each residue, with 3 *
;;; xiscale and 3 columns a step (no test for each column; a column list
;;; does not depend on the order of the columns): pass 1 from x1 or x1 + 1,
;;; pass 2 (vd3) from x1 + 1 or x1 + 2. The clip pass of the weapon takes
;;; all columns. Direct page WPAGE, DBR = RECBANK: long and direct page
;;; operands only.
vc3:          lda     dp:V_CLIP
              beq     1$
              sep     #0x20                 ; the clip pass: all columns
              lda     #2
              sta     long:VN_STEP
              jmp     long:visCol
1$:           lda     dp:(V_XIS+2)          ; |xiscale| < 0.375 and not the unit
              bne     3$                    ;   scale, as visColD: the repeat
              lda     dp:V_XIS              ;   path (vr3Col8)
              cmp     ##0x6000
              bcs     4$
2$:           lda     dp:V_UNIT
              bne     4$
              sep     #0x20
              brl     vr3Col8
3$:           cmp     ##0xffff
              bne     4$
              lda     dp:V_XIS
              cmp     ##0xa001
              bcs     2$
4$:           ldx     dp:W_X2               ; Y = k1 | k2 << 8: the passes
              lda     long:M3,x             ;   start at x1 + k1, x1 + k2
              tay
              lda     dp:V_FRAC             ; pass 2: frac + k2 * xiscale,
              clc                           ;   W_X2 + 2 * k2
              adc     dp:V_XIS
              sta     long:HV_P3F
              lda     dp:(V_FRAC+2)
              adc     dp:(V_XIS+2)
              sta     long:(HV_P3F+2)
              inx
              inx
              cpy     ##0x0200
              bcc     5$
              lda     long:HV_P3F           ; k2 = 2
              clc
              adc     dp:V_XIS
              sta     long:HV_P3F
              lda     long:(HV_P3F+2)
              adc     dp:(V_XIS+2)
              sta     long:(HV_P3F+2)
              inx
              inx
5$:           txa
              sta     long:HV_P3X
              tya                           ; pass 1: k1 = 1 (x1 mod 3 = 2)
              lsr     a
              bcc     6$
              lda     dp:V_FRAC
              clc
              adc     dp:V_XIS
              sta     dp:V_FRAC
              lda     dp:(V_FRAC+2)
              adc     dp:(V_XIS+2)
              sta     dp:(V_FRAC+2)
              bmi     9$                    ; frac < 0 or (frac >> FRACBITS) >=
              cmp     dp:V_WIDTH            ;   width: no column in either pass
              bcs     9$                    ;   (frac only moves away)
              lda     dp:W_X2
              inc     a
              inc     a
              sta     dp:W_X2
6$:           lda     dp:V_XIS              ; xiscale * 3
              asl     a
              tax
              lda     dp:(V_XIS+2)
              rol     a
              tay
              txa
              clc
              adc     dp:V_XIS
              sta     dp:V_XIS
              tya
              adc     dp:(V_XIS+2)
              sta     dp:(V_XIS+2)
              sep     #0x20
              lda     #6                    ; 3 columns a step
              sta     long:VN_STEP
              lda     #1                    ; pass 2 to come
              sta     long:HV_P3
              jmp     long:visCol
9$:           jmp     long:visDone

;;; vd3: visDone in the 2/3 view: after pass 1 (HV_P3 = 1) pass 2 from its
;;; first column, else the end of R_DrawVisSprite (visDone as assembled).
vd3:          sep     #0x20                 ; (8-bit A from visCol8, visNext)
              lda     long:HV_P3
              beq     9$
              lda     #0
              sta     long:HV_P3
              rep     #0x20
              lda     long:HV_P3X
              sta     dp:W_X2
              lda     long:HV_P3F
              sta     dp:V_FRAC
              lda     long:(HV_P3F+2)
              sta     dp:(V_FRAC+2)
              bmi     9$                    ; frac < 0: no column
              cmp     dp:V_WIDTH            ; (frac >> FRACBITS) >= width
              bcs     9$
              jmp     long:visCol
9$:           rep     #0x20
              plb
              pld
              rtl

;;; vr3Col8: vrCol8 (src/iigs/r_frame65.s) in the 2/3 view. A column n mod
;;; 3 = 2 goes to vrNext0 (frac += xiscale, the next column). The scan of
;;; the run takes such columns in without their clips (the seg loops of the
;;; 2/3 view write none there); the record loop of vrPost skips them
;;; (vr3Nx). V_REP, V_XEND and V_FRAC as vrCol8. 8-bit A.
vr3Col8:      ldx     dp:W_X2
              lda     long:M3,x             ; k1 = 1: n mod 3 = 2
              beq     1$
              brl     vrNext0
1$:           txy
              cpy     ##(2 * CONST_VIEWWIDTH)
              bcc     3$
              brl     vrDone
2$:           brl     vrNext0
3$:           lda     [V_FCP],y             ; the rows the clips leave: V_LO
              beq     2$                    ;   to V_HI - 1
              dec     a
              sta     dp:V_HI
              lda     [V_CCP],y
              sta     dp:V_LO
              cmp     dp:V_HI
              bcs     2$
              rep     #0x20                 ; (16-bit to 10$)
              lda     dp:(V_FRAC+2)         ; column = patch + columnofs[frac >> FRACBITS]
              asl     a
              asl     a
              adc     ##OFS_PATCH_COLUMNOFS ; (carry clear)
              tay
              lda     [V_PATCH],y
              clc
              adc     dp:V_PATCH
              sta     dp:V_COL
              lda     long:(M3+1),x         ; k2 = 1 (n mod 3 = 0): n + 1 is
              lsr     a                     ;   kept (6$); else it is not (5$)
              txy                           ; Y = the column of the scan, X =
              ldx     dp:V_FRAC             ;   the low word of its frac
              bcs     6$
              ;; the run: the next columns with the same texture column
              ;; (xiscale.hi + the carry of the low words is 0) and, when
              ;; kept, the same clips
5$:           iny                           ; n mod 3 = 2: the texture column
              iny                           ;   only
              cpy     ##(2 * CONST_VIEWWIDTH)
              bcs     9$
              txa
              clc
              adc     dp:V_XIS
              tax
              lda     dp:(V_XIS+2)
              adc     ##0
              bne     8$
              iny                           ; n mod 3 = 0
              iny
              cpy     ##(2 * CONST_VIEWWIDTH)
              bcs     9$
              txa
              clc
              adc     dp:V_XIS
              tax
              lda     dp:(V_XIS+2)
              adc     ##0
              bne     8$
              lda     [V_FCP],y             ; (V_HI, V_LO: words with a high
              and     ##0x00ff              ;   byte of 0)
              dec     a
              cmp     dp:V_HI
              bne     8$
              lda     [V_CCP],y
              and     ##0x00ff
              cmp     dp:V_LO
              bne     8$
6$:           iny                           ; n mod 3 = 1
              iny
              cpy     ##(2 * CONST_VIEWWIDTH)
              bcs     9$
              txa
              clc
              adc     dp:V_XIS
              tax
              lda     dp:(V_XIS+2)
              adc     ##0
              bne     8$
              lda     [V_FCP],y
              and     ##0x00ff
              dec     a
              cmp     dp:V_HI
              bne     8$
              lda     [V_CCP],y
              and     ##0x00ff
              cmp     dp:V_LO
              beq     5$
8$:           txa                           ; (column Y / 2 is not in the run)
              sec
              sbc     dp:V_XIS
              tax
9$:           tya                           ; V_REP = (Y - W_X2) / 2 - 1
              clc
              sbc     dp:W_X2
              lsr     a
              beq     10$
              sty     dp:V_XEND             ; a run: its end and the frac of
              stx     dp:V_FRAC             ;   its last column
10$:          sep     #0x20
              sta     dp:V_REP
              brl     vrPost

;;; vr3Nx: the step of the record loop of vrPost (VR_NX) in the 2/3 view:
;;; the next column of the run, over a column n mod 3 = 2. 8-bit A.
vr3Nx:        inx
              inx
              lda     long:M3,x
              beq     1$
              inx
              inx
1$:           cpx     dp:V_XEND
              bcs     2$
              jmp     .kbank VR_LP
2$:           brl     vrAdv

;;; mw3: the first two instructions of mwCols (src/iigs/r_frame65.s) in the
;;; 2/3 view: a first column FR_X with n mod 3 = 2 goes one column on.
mw3:          lda     .near FR_X
              asl     a
              tax
              lda     long:M3,x             ; (bit 0: n mod 3 = 2)
              lsr     a
              bcc     1$
              inc     .near FR_X
              jsr     .kbank mwStep
1$:           lda     .near maskedtexturecol ; (the two instructions of mwCols)
              sta     dp:.tiny MW_MTC_H
              rtl

;;; mwN3: the first two instructions of mwNextCol in the 2/3 view: C = FR_X
;;; + 1, or FR_X + 2 over a column n mod 3 = 2 (one step of spryscale and
;;; FR_P here, the other in mwNextCol).
mwN3:         lda     .near FR_X
              inc     a
              asl     a
              tax
              lda     long:M3,x
              lsr     a
              bcc     1$
              jsr     .kbank mwStep
              lda     .near FR_X
              inc     a
              inc     a
              rtl
1$:           lda     .near FR_X
              inc     a
              rtl

;;; mwStep: spryscale += rw_scalestep, FR_P += FR_B (48 bits), as mwNextCol.
mwStep:       lda     .near spryscale
              clc
              adc     .near rw_scalestep
              sta     .near spryscale
              lda     .near (spryscale+2)
              adc     .near (rw_scalestep+2)
              sta     .near (spryscale+2)
              lda     .near FR_P
              clc
              adc     .near FR_B
              sta     .near FR_P
              lda     .near (FR_P+2)
              adc     .near (FR_B+2)
              sta     .near (FR_P+2)
              lda     .near (FR_P+4)
              adc     .near (FR_B+4)
              sta     .near (FR_P+4)
              rts

;;; M3: for each column n (0..161) the bytes k1 = 1 for n mod 3 = 2, else 0
;;; (mw3, mwN3), and k2 = 1 for n mod 3 = 0, else 2: the first columns of
;;; the two passes of a sprite from x1 = n are x1 + k1 and x1 + k2 (vc3).
M3:           .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2
              .byte   0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2, 0, 1, 0, 2, 1, 2

;;; hvSet (hvPatch): the code of the size (VW_HALF, VW_THIRD) at the sites
;;; when PR_HVS (0 full, 1 half, 2 the 2/3 view) is another size. 16-bit A,
;;; X and Y in and out; DBR = the near bank.
hvSet:        sep     #0x20
              lda     long:VW_HALF
              bne     1$
              lda     long:VW_THIRD
              beq     1$
              lda     #2
1$:           cmp     .near PR_HVS
              bne     2$
              rep     #0x20
              rtl
2$:           xba                           ; B = the new state
              lda     .near PR_HVS
              rep     #0x20
              tay                           ; Y = the old state | the new << 8
              and     ##0x00ff
              bne     3$
              MV4     visColD, HV_SAVE      ; from the full view: save the sites
              MV5     mwCols, (HV_SAVE+4)
              MV4     mwNextCol, (HV_SAVE+9)
              MV4     visDone, (HV_SAVE+13)
              MV3     vrCol8, HV_SV2
              MV3     VR_NX, (HV_SV2+3)
              bra     4$
3$:           MV4     HV_SAVE, visColD      ; else the bytes as assembled first
              MV5     (HV_SAVE+4), mwCols
              MV4     (HV_SAVE+9), mwNextCol
              MV4     (HV_SAVE+13), visDone
              MV3     HV_SV2, vrCol8
              MV3     (HV_SV2+3), VR_NX
4$:           tya
              xba
              sep     #0x20
              sta     .near PR_HVS
              lda     #2
              sta     long:VN_STEP
              lda     .near PR_HVS
              rep     #0x20
              and     ##0x00ff
              beq     9$                    ; the full view: as assembled
              cmp     ##2
              beq     5$
              MV4     hvT, visColD          ; the half view
              MV5     (hvT+4), mwCols
              MV4     (hvT+9), mwNextCol
9$:           rtl
5$:           MV4     h3T, visColD          ; the 2/3 view
              MV5     (h3T+4), mwCols
              MV4     (h3T+9), mwNextCol
              MV4     (h3T+13), visDone
              MV3     (h3T+17), vrCol8
              MV3     (h3T+20), VR_NX
              rtl

;;; h3T: the code of the 2/3 view at the sites (the order of HV_SAVE).
h3T:          jmp     long:vc3              ; visColD
              jsl     long:mw3              ; mwCols
              nop
              jsl     long:mwN3             ; mwNextCol
              jmp     long:vd3              ; visDone
              jmp     .kbank vr3Col8        ; vrCol8 (the same bank)
              jmp     .kbank vr3Nx          ; VR_NX
