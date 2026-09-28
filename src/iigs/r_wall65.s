;;; Wall setup in 65816 assembly.
;;;
;;; R_StoreWallRange of r_draw.c, with the same
;;; results. The seg, side, line, sectors and texture tables are read
;;; through long pointers in the direct page of the BSP phase (BSPDP of
;;; src/iigs/r_sprite65.s); their banks stay for the frame. The drawseg is
;;; in the near bank: X or Y = ds_p. Byte stores allow intervening register
;;; work to overlap the accelerator write buffer. PUTWN/PUTWD use word
;;; stores where splitting would add overhead without useful overlap.
;;; Low-byte-only stores rely on the destination's high byte already being 0.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"
#include "wpage.inc"
#include "dscols.inc"

              .extern _Dp, _Mod16, _Div32, FixedMul, FixedMul3216
              .extern umul16, umul16lo, MA, MB, MR, BSPDP, iigs_mulT
              .extern R_ScaleFromGlobalAngle, R_RenderSegLoop, xtoviewangleTable
              .extern ds_p, _s_drawsegs, frontsector, _g_lines, _g_sectors
              .extern _g_segs, _g_sides, _g_lines, _g_sectors
              .extern rw_normalangle, rw_distance, rw_stopx
              .extern lastopening, openings, rw_scale, rw_scalestep
              .extern worldtop, worldbottom, worldhigh, worldlow, viewz, viewangle16
              .extern midtexture, toptexture, bottomtexture, maskedtexture, maskedtexturecol
              .extern rw_midtexturemid, rw_toptexturemid, rw_bottomtexturemid
              .extern texturetranslation, textureheight, skyflatnum
              .extern screenheightarray, negonearray, ceilingclip, floorclip
              .extern rw_offset, rw_centerangle, rw_lightlevel
              .extern ceilingplane_color, floorplane_color, didsolidcol
              .extern finesineTable_part_1, sprites, fileinfo, _g_gametic
              .extern viewx, viewy, viewcos, viewsin, PR_GZ, PR_GX, PR_IOK, R_InitSpriteIScales
              .extern prFrame, c21FloorDone
#if defined IIGS_PHASES
              .extern iigs_phase
#endif


;;; Existing per-level address tables, filled by P_InitBlockRows and
;;; P_InitSightTables before rendering. Reuse them without new allocation.
CORE_LN36     .equ    (MM_B3F + 0x6200)
CORE_SEC58    .equ    (MM_B3F + 0xa000)

;;; Long pointers (3 bytes) in the direct page of the BSP phase.
WP_SEG        .equ    BSPDP           ; curline
WP_SIDE       .equ    (BSPDP+3)       ; sidedef
WP_LINE       .equ    (BSPDP+6)       ; linedef
WP_FS         .equ    (BSPDP+9)       ; frontsector
WP_BS         .equ    (BSPDP+12)      ; backsector
WP_TT         .equ    (BSPDP+15)      ; texturetranslation
WP_TH         .equ    (BSPDP+18)      ; textureheight
QT            .equ    (BSPDP+30)      ; qmul: sq(a + b) >> 16
QT2           .equ    (BSPDP+32)      ; FMFAST: the part of B.hi
QB            .equ    (BSPDP+34)      ; hypMul: C
WP_SPR        .equ    (BSPDP+38)      ; sprites, fileinfo (for R_ProjectSprite
WP_FI         .equ    (BSPDP+41)      ;   of src/iigs/r_thing65.s)
D8            .equ    (BSPDP+44)      ; div8: d << 8 (the low byte stays 0)
DSIGN         .equ    (BSPDP+47)      ; bit 7: the dividend of rw_scalestep < 0

SWR_PADN      .equ    28              ; the pads at the ends of the bspcode and segcode
SEG_PADN      .equ    27              ;   parts: the code after them keeps its place
RECIP_TABLE   .equ    MM_RECIP        ; (2^31 - 1) / M of src/iigs/m_recip65.s
MULT0         .equ    iigs_mulT + 510 ; T[0] of src/iigs/mul.inc
SQL           .equ    MM_SQL          ; the quarter squares of src/iigs/m_fixed65.s:
SQH           .equ    MM_SQH          ;   their low words and high words

              .section znear, bss
SW_START:     .space  2               ; start (the high byte is 0)
SW_OFF:       .space  2               ; floor(OFF): rw_offset less the offsets
SW_TH:        .space  2               ; th = viewangle16 - rw_normalangle
SW_AL:        .space  2               ; the low word of the heights
SW_CS:        .space  4               ; FixedMul(SW_AL, rw_scale)
SW_CSS:       .space  4               ; FixedMul(SW_AL, rw_scalestep)
SW_P:         .space  4               ; edge: (CENTERY << FRACBITS) + round - FixedMul(h, rw_scale)
SW_T:         .space  2               ; rowMod: b - 1, b
SW_EO:        .space  2               ; edge: the offset of the step in WPAGE,
SW_ER:        .space  2               ;   1 for a bottom edge, the height
SW_EH:        .space  2               ;   (the high bytes of the first two are 0)
              .space  6               ; (free: the marks moved to the loop page)
SW_LF:        .space  2               ; the low byte of linedef->flags (the pegs)
SW_SIL:       .space  2               ; the silhouette of the drawseg
SW_OPEN:      .space  2               ; 1: two sided and not closed (own clips)
SW_EDGES:     .space  2               ; 1: worldhigh < worldtop, 2: worldlow > worldbottom
SW_D:         .space  4               ; D, 16.16 (normD shifts it)
SW_R:         .space  2               ; R16 = RECIP_TABLE[M] of D
SW_LZ:        .space  2               ; 2 lz of D (the high byte is 0)
SW_DX:        .space  2               ; distAny: v1 - the view, rounded
SW_DY:        .space  2
SW_BS:        .space  2               ; distAny: bit 15, the sign of MA
SW_O:         .space  4               ; distAny: dy c
SW_M8:        .space  2               ; distAny: the high byte of MA
              .space  6               ; (the old size: the near data stays in place)

;;; Signed 32-bit a < b: lda a.lo / cmp b.lo / lda a.hi / SLT32 b.hi / bmi
SLT32         .macro  op
              sbc     \op
              bvc     1$
              eor     ##0x8000
1$:
              .endm

;;; The same for the fixed_t at offset Y of the sectors \p and \q:
;;; N = [\p] < [\q]; Y += 2.
SECLT         .macro  p, q
              lda     [.tiny \p],y
              cmp     [.tiny \q],y
              iny
              iny
              lda     [.tiny \p],y
              sbc     [.tiny \q],y
              bvc     1$
              eor     ##0x8000
1$:
              .endm

;;; Store 16-bit C to near word \dst without changing C. These sites have
;;; no useful work between the two byte writes, so SEP/REP and byte swapping
;;; would add overhead without hiding the second write's buffer stall.
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

;;; The same for X:C to the field \fld of the drawseg at Y.
PUT32Y        .macro  fld
              sta     abs:\fld,y
              txa
              sta     abs:(\fld+2),y
              .endm

;;; The same for X:C to the near fixed_t \dst and the field \fld of the
;;; drawseg at Y.
PUT32NY       .macro  dst, fld
              sta     .near \dst
              sta     abs:\fld,y
              txa
              sta     .near (\dst+2)
              sta     abs:(\fld+2),y
              .endm

;;; X:C = -X:C.
NEG32         .macro
              eor     ##0xffff
              clc
              adc     ##1
              tay
              txa
              eor     ##0xffff
              adc     ##0
              tax
              tya
              .endm

;;; X:C = AH * B + \cb (mod 2^32), for AH in MA (signed), the fixed_t B at
;;; near \b and \cb = FixedMul(AL, B): that is FixedMul(h, B) for the height
;;; h = AH:AL (see edge below).
FMFAST        .macro  b, cb
              lda     .near (\b+2)          ; lo16(AH * B.hi) << 16
              beq     5$
              cmp     ##0xffff
              bne     1$
              lda     .near \b              ; B.hi = -1: AH * B.lo - AH << 16
              jsr     .kbank qmul
              sec
              sbc     dp:.tiny MA
              bra     6$
1$:           cmp     ##8
              bcs     3$
              jsr     .kbank kmul           ; B.hi = 1..7: shifts and adds
              bra     4$
3$:           jsr     .kbank qmul
              tya
4$:           PUTWD   QT2
              lda     .near \b              ; + (AH & 0xffff) * B.lo
              jsr     .kbank qmul
              clc
              adc     dp:.tiny QT2
              bra     6$
5$:           lda     .near \b
              jsr     .kbank qmul
6$:           bit     dp:.tiny MA           ; AH < 0: - B.lo << 16
              bpl     7$
              sec
              sbc     .near \b
7$:           tax
              tya                           ; + \cb
              clc
              adc     .near \cb
              tay
              txa
              adc     .near (\cb+2)
              tax
              tya
              .endm

;;; FMFASTZ: FMFAST for B = rw_scalestep, where B = 0 (a seg of one column)
;;; jumps to \z with C = 0 and X as it was.
FMFASTZ       .macro  b, cb, z
              lda     .near (\b+2)          ; lo16(AH * B.hi) << 16
              beq     5$
              cmp     ##0xffff
              bne     1$
              lda     .near \b              ; B.hi = -1: AH * B.lo - AH << 16
              jsr     .kbank qmul
              sec
              sbc     dp:.tiny MA
              bra     6$
1$:           cmp     ##8
              bcs     3$
              jsr     .kbank kmul           ; B.hi = 1..7: shifts and adds
              bra     4$
3$:           jsr     .kbank qmul
              tya
4$:           PUTWD   QT2
              lda     .near \b              ; + (AH & 0xffff) * B.lo
              jsr     .kbank qmul
              clc
              adc     dp:.tiny QT2
              bra     6$
5$:           lda     .near \b
              beq     \z                    ; B = 0: to \z (no product)
              jsr     .kbank qmul
6$:           bit     dp:.tiny MA           ; AH < 0: - B.lo << 16
              bpl     7$
              sec
              sbc     .near \b
7$:           tax
              tya                           ; + \cb
              clc
              adc     .near \cb
              tay
              txa
              adc     .near (\cb+2)
              tax
              tya
              .endm

;;; \cb = FixedMul(AL, B) = AL * B.hi + hi16(AL * B.lo) for AL = SW_AL
;;; (not 0, also in MA) and the fixed_t B at near \b.
FIXAL         .macro  b, cb
              lda     .near (\b+2)
              beq     1$
              cmp     ##0xffff
              beq     1$
              lda     .near SW_AL           ; B.hi other than 0 and -1:
              PUTWD   _Dp                   ;   FixedMul3216(B, AL)
              lda     .near \b
              ldx     .near (\b+2)
              jsl     long:FixedMul3216
              bra     3$
1$:           lda     .near \b              ; hi16(AL * B.lo) (+ 0 or 1 in the
              jsr     .kbank qmulh          ;   last bit: nothing)
              ldx     ##0
              ldy     .near (\b+2)          ; B.hi = -1: - AL
              beq     3$
              sec
              sbc     .near SW_AL
              bcs     3$
              dex
3$:           PUT32N  \cb
              .endm

;;; FIXALZ: FIXAL for B = rw_scalestep, where B = 0 (a seg of one column)
;;; jumps to \z with no product: \cb is not set then, and edge (FMFASTZ)
;;; does not read it for B = 0.
FIXALZ        .macro  b, cb, z
              lda     .near \b             ; B.lo first: it is the operand of
              beq     8$                    ;   qmulh too
              ldy     .near (\b+2)
              beq     1$
              cpy     ##0xffff
              beq     1$
9$:           lda     .near SW_AL           ; B.hi other than 0 and -1:
              PUTWD   _Dp                   ;   FixedMul3216(B, AL)
              lda     .near \b
              ldx     .near (\b+2)
              jsl     long:FixedMul3216
              bra     3$
8$:           ldy     .near (\b+2)          ; B.lo = 0: B = 0, or B.hi << 16
              bne     9$
              bra     \z
1$:           jsr     .kbank qmulh          ; hi16(AL * B.lo) (+ 0 or 1 in the
              ldx     ##0                   ;   last bit: nothing)
              ldy     .near (\b+2)          ; B.hi = -1: - AL
              beq     3$
              sec
              sbc     .near SW_AL
              bcs     3$
              dex
3$:           PUT32N  \cb
              .endm

;;; X:C = G(AL, b) = hi16(AL * b.lo) - (b < 0 ? AL : 0) for the word \al
;;; and the view sine or cosine \b, with MA = b.lo (R_WallFrame).
GPART         .macro  al, b
              lda     .near \al
              jsl     long:qmulL            ; C = hi16(AL * b.lo)
              ldx     ##0
              ldy     .near (\b+2)
              beq     1$
              sec
              sbc     .near \al
              bcs     1$
              dex
1$:
              .endm

#if defined IIGS_PHASES
PHASE         .macro  n
              lda     ##\n
              sta     .near iigs_phase
              .endm
#else
PHASE         .macro  n
              .endm
#endif

;;; ---------------------------------------------------------------------------
;;; void R_StoreWallRange(const int16_t start, const int16_t stop)
;;;   In: C = start, _Dp[0-1] = stop. linedef is the line of curline
;;;   (R_AddLine).
;;; ---------------------------------------------------------------------------
              .section bspcode, text
              .public R_StoreWallRange
R_StoreWallRange:
              ldx     .near ds_p            ; don't overflow and crash (the
              cpx     ##.word0 (_s_drawsegs + CONST_MAXDRAWSEGS * SIZEOF_DS)
              bne     1$                    ;   bank of ds_p stays)
              rtl
1$:           sep     #0x20                 ; start, rw_stopx = stop + 1 (0..160:
              sta     .near SW_START        ;   the high bytes stay 0)
              lda     dp:.tiny _Dp
              inc     a
              sta     .near rw_stopx
              rep     #0x20                 ; the line of the seg (WP_SEG, from
              ldy     ##OFS_SEG_LINENUM     ;   segLoop): &_g_lines[linenum] (* 36)
              lda     [.tiny WP_SEG],y
              asl     a                     ; LN36 already includes _g_lines
              tax
              lda     long:CORE_LN36,x
              sta     dp:.tiny WP_LINE
              bra     881$                  ; preserve all following addresses
              .space  8
881$:
              ldy     ##OFS_LINE_R_FLAGS    ; linedef->r_flags |= ML_MAPPED
              lda     [.tiny WP_LINE],y     ;   (16-bit: no REP/SEP)
              bit     ##CONST_ML_MAPPED     ; (once: no store after that)
              bne     2$
              ora     ##CONST_ML_MAPPED
              sta     [.tiny WP_LINE],y
2$:
              ldy     ##OFS_LINE_FLAGS      ; the pegs of the flags, for later
              lda     [.tiny WP_LINE],y     ;   (the word: the pegs are in its
              sta     .near SW_LF           ;   low byte)

              ;; R_CheckOpenings(start): need = (lastopening - openings) / 2
              ;; + (rw_stopx - start) * 2 > MAXOPENINGS: openings overflow,
              ;; nevermind (no need to look when there is room for 2 * 160)
              lda     .near lastopening
              cmp     ##.word0 (openings + 2 * (CONST_MAXOPENINGS - 2 * CONST_VIEWWIDTH) + 1)
              bcc     4$
              sec
              sbc     ##.word0 openings
              cmp     ##0x8000
              ror     a
              clc
              adc     .near rw_stopx
              clc
              adc     .near rw_stopx
              sec
              sbc     .near SW_START
              sec
              sbc     .near SW_START
              sec
              sbc     ##(CONST_MAXOPENINGS+1)
              bvc     3$
              eor     ##0x8000
3$:           bmi     4$
              rtl

              ;; the seg (WP_SEG): rw_normalangle = curline->angle, sidedef =
              ;; &_g_sides[curline->sidenum]
4$:           ldy     ##OFS_SEG_SIDENUM
              lda     [.tiny WP_SEG],y
              asl     a
              asl     a
              asl     a
              sec
              sbc     [.tiny WP_SEG],y      ; * 7
              asl     a                     ; * 14
              clc
              adc     .near _g_sides
              PUTWD   WP_SIDE
              ldy     ##OFS_SEG_ANGLE
              lda     [.tiny WP_SEG],y
              PUTWN   rw_normalangle

              ;; D = (v1 - view) . n, the distance of the view from the line
              ;; of the seg (n: the unit vector of rw_normalangle), 16.16,
              ;; and OFF = (v1 - view) . (-sin, cos), the place of v1 along
              ;; the line: rw_distance = floor(D), rw_offset = floor(OFF) +
              ;; the offsets (the C code: hyp * cos and -hyp * sin of
              ;; rw_normalangle - rw_angle1). Along an axis they are
              ;; differences; at another angle, distAny.
              bit     ##0x3fff              ; (C = rw_normalangle)
              beq     20$
              jsr     .kbank distAny
              brl     axisEnd
20$:          xba                           ; the quadrant * 2
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              tax
              jmp     (.kbank axisJump,x)
axisN8:       ldy     ##(OFS_SEG_V1+2)      ; n = (-1, 0): OFF = viewy - v1.y,
              lda     .near (viewy+2)       ;   D = viewx - v1.x
              sec
              sbc     [.tiny WP_SEG],y
              PUTWN   SW_OFF
              lda     .near viewx
              PUTWN   SW_D
              ldy     ##OFS_SEG_V1
              lda     .near (viewx+2)
              sec
              sbc     [.tiny WP_SEG],y
              brl     axisHi
axisN4:       ldy     ##OFS_SEG_V1          ; n = (0, 1): OFF = viewx - v1.x,
              lda     .near (viewx+2)       ;   D = v1.y - viewy
              sec
              sbc     [.tiny WP_SEG],y
              PUTWN   SW_OFF
              lda     ##0
              sec
              sbc     .near viewy
              PUTWN   SW_D
              ldy     ##(OFS_SEG_V1+2)
              lda     [.tiny WP_SEG],y
              sbc     .near (viewy+2)
              bra     axisHi
axisNC:       ldy     ##OFS_SEG_V1          ; n = (0, -1): OFF = v1.x - viewx,
              lda     ##0                   ;   D = viewy - v1.y (carry: no
              cmp     .near viewx           ;   borrow from the low words)
              lda     [.tiny WP_SEG],y
              sbc     .near (viewx+2)
              PUTWN   SW_OFF
              lda     .near viewy
              PUTWN   SW_D
              ldy     ##(OFS_SEG_V1+2)
              lda     .near (viewy+2)
              sec
              sbc     [.tiny WP_SEG],y
              bra     axisHi
axisN0:       ldy     ##(OFS_SEG_V1+2)      ; n = (1, 0): OFF = v1.y - viewy,
              lda     ##0                   ;   D = v1.x - viewx
              cmp     .near viewy
              lda     [.tiny WP_SEG],y
              sbc     .near (viewy+2)
              PUTWN   SW_OFF
              lda     ##0
              sec
              sbc     .near viewx
              PUTWN   SW_D
              ldy     ##OFS_SEG_V1
              lda     [.tiny WP_SEG],y
              sbc     .near (viewx+2)
axisHi:       PUTWN   (SW_D+2)
axisEnd:      lda     .near (SW_D+2)        ; rw_distance = floor(D)
              PUTWN   rw_distance

              ;; ds_p->curline = curline (the high byte of its bank is 0),
              ;; ds_p->x1 = start, ds_p->x2 = stop (bytes: their high bytes
              ;; are 0)
              ldx     .near ds_p
              lda     dp:.tiny WP_SEG
              sta     abs:OFS_DS_CURLINE,x
              sep     #0x20
              lda     dp:.tiny (WP_SEG+2)
              sta     abs:(OFS_DS_CURLINE+2),x
              lda     .near SW_START
              sta     abs:OFS_DS_X1,x
              lda     .near rw_stopx
              dec     a
              sta     abs:OFS_DS_X2,x
              rep     #0x20

              ;; the scales: rw_scale = ds_p->scale1, scale2, rw_scalestep =
              ;; ds_p->scalestep (scaleFast); D below 4 map units or a scale
              ;; at a clamp: the old way (scaleSlow)
              lda     .near (SW_D+2)
              bmi     11$
              cmp     ##4
              bcc     11$
              jsr     .kbank scaleFast
              beq     12$
11$:          jsl     long:scaleSlow

              ;; the front sector: worldtop, worldbottom
12$:
              ldy     ##OFS_SEC_CEILINGHEIGHT
              lda     [.tiny WP_FS],y
              sec
              sbc     .near viewz
              sta     .near worldtop
              iny
              iny
              lda     [.tiny WP_FS],y
              sbc     .near (viewz+2)
              sta     .near (worldtop+2)
              ;; bspSub already produces worldbottom while testing the
              ;; front floor against viewz. It remains valid for its walls.
              bra     c21WallFloorEnd
              .space  20                    ; old22byte floor calculation
c21WallFloorEnd .equ   .
              ldy     ##OFS_SEG_BACKSECTORNUM ; backsectornum == NO_INDEX8: one
              lda     [.tiny WP_SEG],y      ;   sided; else the back sector
              and     ##0x00ff              ;   &_g_sectors[n] (* 58) to WP_BS
              cmp     ##0x00ff
              beq     oneSided
              asl     a                     ; SEC58 already includes _g_sectors
              tax
              lda     long:CORE_SEC58,x
              sta     dp:.tiny WP_BS
              jmp     .kbank twoSided
              .space  19                    ; unreachable: keep oneSided in place

              ;; a single sided line: midtexture = texturetranslation
              ;; [sidedef->midtexture], markfloor = markceiling = true
oneSided:     ldx     .near ds_p            ; ds_p->maskedtexturecol = NULL
              sep     #0x20                 ;   (its high byte is 0)
              stz     abs:OFS_DS_MASKEDTEXTURECOL,x
              stz     abs:(OFS_DS_MASKEDTEXTURECOL+1),x
              stz     abs:(OFS_DS_MASKEDTEXTURECOL+2),x
              stz     .near SW_EDGES
              rep     #0x20
              lda     ##1                   ; markfloor = markceiling = 1, no
              sta     long:(WPAGE+W_MF)     ;   masked, top or bottom texture
              sta     long:(WPAGE+W_MC)
              lda     ##0
              sta     long:(WPAGE+W_MASKED)
              sta     long:(WPAGE+W_TOPTEX)
              sta     long:(WPAGE+W_BOTTEX)
              ldy     ##OFS_SIDE_MIDTEXTURE
              lda     [.tiny WP_SIDE],y
              asl     a
              tay
              lda     [.tiny WP_TT],y
              sta     long:(WPAGE+W_MIDTEX)
              jsr     .kbank rowMod         ; Mod(rowoffset, textureheight[midtexture])
              tax
              lda     .near SW_LF
              and     ##CONST_ML_DONTPEGBOTTOM
              beq     13$
              ;; the bottom of the texture at the bottom: rw_midtexturemid =
              ;; floorheight + (textureheight[sidedef->midtexture] << 16) - viewz
              ldy     ##OFS_SIDE_MIDTEXTURE
              lda     [.tiny WP_SIDE],y
              asl     a
              tay
              txa
              clc
              adc     [.tiny WP_TH],y
              ldx     ##.word0 worldbottom
              ldy     ##.word0 rw_midtexturemid
              jsr     .kbank midTex
              bra     14$
13$:          txa                           ; the top at the top: worldtop
              ldx     ##.word0 worldtop
              ldy     ##.word0 rw_midtexturemid
              jsr     .kbank midTex
14$:          ldx     .near ds_p
              jsr     .kbank silBoth
              jmp     .kbank textured

;;; ---------------------------------------------------------------------------
;;; The rest of R_StoreWallRange: the texture columns, the planes, the
;;; edges, R_RenderSegLoop, the clips for the sprites.
;;; ---------------------------------------------------------------------------
              ;; a two sided line
twoSided:     ;; worldhigh, worldlow first: the tests below compare the world
              ;; values (each sector height less the same viewz: the same order)
              ldy     ##OFS_SEC_CEILINGHEIGHT
              lda     [.tiny WP_BS],y
              sec
              sbc     .near viewz
              PUTWN   worldhigh
              iny
              iny
              lda     [.tiny WP_BS],y
              sbc     .near (viewz+2)
              PUTWN   (worldhigh+2)
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     [.tiny WP_BS],y
              sec
              sbc     .near viewz
              PUTWN   worldlow
              iny
              iny
              lda     [.tiny WP_BS],y
              sbc     .near (viewz+2)
              PUTWN   (worldlow+2)
              sep     #0x20
              lda     #1                    ; its own clips (sprtopclip =
              sta     .near SW_OPEN         ;   sprbottomclip = NULL until the
              stz     .near SW_SIL          ;   saves below), SIL_NONE
              rep     #0x20
              lda     ##0                   ; no mid texture (the loop page)
              sta     long:(WPAGE+W_MIDTEX)
              ldx     .near ds_p            ; (RF_CLOSED is never set: no test)
              lda     .near worldlow        ; frontsector->floorheight >
              cmp     .near worldbottom     ;   backsector->floorheight: worldlow
              lda     .near (worldlow+2)    ;   < worldbottom
              SLT32   .near (worldbottom+2)
              bpl     21$
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     ##OFS_DS_BSILHEIGHT
              jsr     .kbank secdsF
              bra     22$
21$:          lda     .near (worldlow+2)    ; backsector->floorheight > viewz:
              bmi     24$                   ;   worldlow > 0
              ora     .near worldlow
              beq     24$
              jsr     .kbank bsilMax
22$:          lda     ##CONST_SIL_BOTTOM    ; SIL_BOTTOM
              sta     .near SW_SIL
24$:          lda     .near worldtop        ; frontsector->ceilingheight <
              cmp     .near worldhigh       ;   backsector->ceilingheight: worldtop
              lda     .near (worldtop+2)    ;   < worldhigh
              SLT32   .near (worldhigh+2)
              bpl     25$
              ldy     ##OFS_SEC_CEILINGHEIGHT
              lda     ##OFS_DS_TSILHEIGHT
              jsr     .kbank secdsF
              bra     27$
25$:          lda     .near (worldhigh+2)   ; backsector->ceilingheight < viewz:
              bpl     30$                   ;   worldhigh < 0
              jsr     .kbank tsilMin
27$:          lda     .near SW_SIL          ; SIL_TOP
              ora     ##CONST_SIL_TOP
              sta     .near SW_SIL

              ;; a closed door: backsector->ceilingheight <=
              ;; frontsector->floorheight (worldhigh <= worldbottom) or
              ;; backsector->floorheight >= frontsector->ceilingheight
              ;; (worldlow >= worldtop, before the sky below): X = 1
30$:          ldx     ##1
              lda     .near worldbottom
              cmp     .near worldhigh
              lda     .near (worldbottom+2)
              SLT32   .near (worldhigh+2)
              bpl     31$
              lda     .near worldlow
              cmp     .near worldtop
              lda     .near (worldlow+2)
              SLT32   .near (worldtop+2)
              bpl     31$
              dex
              ;; both skies: worldtop = worldhigh
31$:          ldy     ##OFS_SEC_CEILINGPIC
              lda     [.tiny WP_FS],y
              cmp     .near skyflatnum
              bne     32$
              lda     [.tiny WP_BS],y
              cmp     .near skyflatnum
              bne     32$
              lda     .near worldhigh
              PUTWN   worldtop
              lda     .near (worldhigh+2)
              PUTWN   (worldtop+2)

              ;; markfloor = worldlow != worldbottom || the floorpics or the
              ;; lights differ; markceiling the same with the ceilings; a
              ;; closed door: both
32$:          txa
              bne     46$
              ldy     ##OFS_SEC_LIGHTLEVEL
              lda     [.tiny WP_BS],y
              cmp     [.tiny WP_FS],y
              bne     46$
              lda     .near worldlow        ; X = markfloor
              cmp     .near worldbottom
              bne     33$
              lda     .near (worldlow+2)
              cmp     .near (worldbottom+2)
              bne     33$
              ldy     ##OFS_SEC_FLOORPIC
              lda     [.tiny WP_BS],y
              cmp     [.tiny WP_FS],y
              beq     34$
33$:          inx
34$:          txa
              sta     long:(WPAGE+W_MF)
              ldx     ##0                   ; X = markceiling
              lda     .near worldhigh
              cmp     .near worldtop
              bne     47$
              lda     .near (worldhigh+2)
              cmp     .near (worldtop+2)
              bne     47$
              ldy     ##OFS_SEC_CEILINGPIC
              lda     [.tiny WP_BS],y
              cmp     [.tiny WP_FS],y
              beq     48$
47$:          inx
48$:          txa
              sta     long:(WPAGE+W_MC)
              bra     35$
46$:          lda     ##1                   ; both marks
              sta     long:(WPAGE+W_MF)
              sta     long:(WPAGE+W_MC)

              ;; the tiers: 1 for worldhigh < worldtop (the top texture),
              ;; 2 for worldlow > worldbottom (the bottom texture)
35$:          ldx     ##0
              lda     .near worldhigh
              cmp     .near worldtop
              lda     .near (worldhigh+2)
              SLT32   .near (worldtop+2)
              bpl     36$
              inx
36$:          lda     .near worldbottom
              cmp     .near worldlow
              lda     .near (worldbottom+2)
              SLT32   .near (worldlow+2)
              bpl     37$
              inx
              inx
37$:          txa
              sta     .near SW_EDGES
              lsr     a
              bcs     38$
              lda     ##0                   ; toptexture = 0
              sta     long:(WPAGE+W_TOPTEX)
              bra     40$

              ;; toptexture = texturetranslation[sidedef->toptexture]
38$:          ldy     ##OFS_SIDE_TOPTEXTURE
              lda     [.tiny WP_SIDE],y
              asl     a
              tay
              lda     [.tiny WP_TT],y
              sta     long:(WPAGE+W_TOPTEX)
              jsr     .kbank rowMod
              tax
              lda     .near SW_LF
              and     ##CONST_ML_DONTPEGTOP
              beq     39$
              txa                           ; the top at the top: worldtop
              ldx     ##.word0 worldtop
              ldy     ##.word0 rw_toptexturemid
              jsr     .kbank midTex
              bra     40$
39$:          ldy     ##OFS_SIDE_TOPTEXTURE ; backsector->ceilingheight
              lda     [.tiny WP_SIDE],y     ;   + (textureheight[sidedef->toptexture]
              asl     a                     ;   << 16) - viewz
              tay
              txa
              clc
              adc     [.tiny WP_TH],y
              ldx     ##.word0 worldhigh
              ldy     ##.word0 rw_toptexturemid
              jsr     .kbank midTex

40$:          lda     .near SW_EDGES
              and     ##2
              bne     41$
              lda     ##0                   ; bottomtexture = 0
              sta     long:(WPAGE+W_BOTTEX)
              bra     44$
              ;; bottomtexture = texturetranslation[sidedef->bottomtexture]
41$:          ldy     ##OFS_SIDE_BOTTOMTEXTURE
              lda     [.tiny WP_SIDE],y
              asl     a
              tay
              lda     [.tiny WP_TT],y
              sta     long:(WPAGE+W_BOTTEX)
              jsr     .kbank rowMod
              tax
              lda     .near SW_LF
              and     ##CONST_ML_DONTPEGBOTTOM
              beq     42$
              txa                           ; the bottom at the bottom: worldtop
              ldx     ##.word0 worldtop
              ldy     ##.word0 rw_bottomtexturemid
              jsr     .kbank midTex
              bra     44$
42$:          txa                           ; else worldlow
              ldx     ##.word0 worldlow
              ldy     ##.word0 rw_bottomtexturemid
              jsr     .kbank midTex

              ;; a masked midtexture: maskedtexture = true,
              ;; ds_p->maskedtexturecol = maskedtexturecol = lastopening - rw_x,
              ;; lastopening += rw_stopx - rw_x (the high bytes of the banks
              ;; are 0)
44$:          ldx     .near ds_p
              ldy     ##OFS_SIDE_MIDTEXTURE
              lda     [.tiny WP_SIDE],y
              bne     45$
              sta     long:(WPAGE+W_MASKED) ; none: maskedtexture = false (C = 0),
              stz     abs:OFS_DS_MASKEDTEXTURECOL,x ; ds_p->maskedtexturecol =
              stz     abs:(OFS_DS_MASKEDTEXTURECOL+2),x ; NULL (16-bit)
              bra     textured
45$:          lda     .near lastopening
              sec
              sbc     .near SW_START
              sec
              sbc     .near SW_START
              sep     #0x20
              sta     .near maskedtexturecol
              sta     abs:OFS_DS_MASKEDTEXTURECOL,x
              xba
              sta     .near (maskedtexturecol+1)
              sta     abs:(OFS_DS_MASKEDTEXTURECOL+1),x
              lda     .near (lastopening+2)
              sta     .near (maskedtexturecol+2)
              sta     abs:(OFS_DS_MASKEDTEXTURECOL+2),x
              rep     #0x20
              lda     ##1
              sta     long:(WPAGE+W_MASKED)
              lda     .near rw_stopx
              sec
              sbc     .near SW_START
              asl     a
              clc
              adc     .near lastopening
              PUTWN   lastopening

              ;; rw_offset, only for textured lines:
              ;; (midtexture | toptexture | bottomtexture | maskedtexture) > 0
textured:     ldx     ##0
              lda     long:(WPAGE+W_MIDTEX)
              ora     long:(WPAGE+W_TOPTEX)
              ora     long:(WPAGE+W_BOTTEX)
              ora     long:(WPAGE+W_MASKED)
              beq     50$
              bmi     50$
              inx
50$:          txa                           ; segtextured (the loop page)
              sta     long:(WPAGE+W_SEGTEX)
              beq     53$
              ;; rw_offset = floor(OFF) + sidedef->textureoffset +
              ;; curline->offset
51$:          lda     .near SW_OFF
              ldy     ##OFS_SIDE_TEXTUREOFFSET
              clc
              adc     [.tiny WP_SIDE],y
              ldy     ##OFS_SEG_OFFSET
              clc
              adc     [.tiny WP_SEG],y
              sta     long:(WPAGE+W_OFFSET) ; rw_offset (the loop page)
              lda     ##0x4000              ; rw_centerangle = ANG90_16 + viewangle16 - rw_normalangle
              clc
              adc     .near viewangle16
              sec
              sbc     .near rw_normalangle
              sta     long:(WPAGE+W_CANGLE) ; rw_centerangle
              ldy     ##OFS_SEC_LIGHTLEVEL  ; rw_lightlevel = frontsector->lightlevel
              lda     [.tiny WP_FS],y
              PUTWN   rw_lightlevel

              ;; planes on the wrong side of the view plane are invisible
              ;; markfloor = false for frontsector->floorheight >= viewz, and
              ;; markceiling = false for frontsector->ceilingheight <= viewz
              ;; and not a sky: the plane colors of R_Subsector (bspSub of
              ;; src/iigs/r_bsp65.s) are FLAT_SPAN (0xffff) just then (the
              ;; same compares of the same sector); FLAT_SPAN: no color, no
              ;; marks. Before the edges, which look at the marks.
53$:          lda     .near ceilingplane_color
              inc     a                     ; 0xffff (C = 0 then)
              bne     63$
              sta     long:(WPAGE+W_MC)
63$:          lda     .near floorplane_color
              inc     a
              bne     64$
              sta     long:(WPAGE+W_MF)

              ;; the steps of the texture edges, and their starts one step
              ;; early, straight into the direct page of the loop. Only a
              ;; loop that uses yl (markceiling, a top or mid wall) needs the
              ;; top edge, only one that uses yh (markfloor, a bottom or mid
              ;; wall) the bottom edge (segvar.inc and genColumn of
              ;; src/iigs/r_seg65.s)
64$:          jsr     .kbank edgeAL
              lda     long:(WPAGE+W_MC)
              ora     long:(WPAGE+W_TOPTEX)
              ora     long:(WPAGE+W_MIDTEX)
              beq     54$
              ldy     ##.word0 worldtop
              ldx     ##W_TS
              clc
              jsr     .kbank edge
54$:          lda     long:(WPAGE+W_MF)
              ora     long:(WPAGE+W_BOTTEX)
              ora     long:(WPAGE+W_MIDTEX)
              beq     55$
              ldy     ##.word0 worldbottom
              ldx     ##W_BS
              sec
              jsr     .kbank edge
55$:          lda     .near SW_EDGES
              lsr     a
              bcc     61$
              ldy     ##.word0 worldhigh    ; worldhigh < worldtop
              ldx     ##W_PHS
              sec
              jsr     .kbank edge
61$:          lda     .near SW_EDGES
              and     ##2
              beq     62$
              ldy     ##.word0 worldlow     ; worldlow > worldbottom
              ldx     ##W_PLS
              clc
              jsr     .kbank edge

              ;; R_RenderSegLoop(rw_x): segtextured, the marks, the textures,
              ;; rw_offset and rw_centerangle are in the loop page already
62$:          stz     .near didsolidcol     ; didsolidcol = false
              PHASE   10
              lda     .near SW_START
              jsl     long:R_RenderSegLoop
              PHASE   9

              ;; a two sided line with its own clips (SIL_BOTH lines need
              ;; nothing more): a column made solid by this wall needs full
              ;; clipping info
              lda     .near SW_OPEN
              bne     65$
              jmp     .kbank 70$
65$:          ldx     .near ds_p
              lda     .near didsolidcol
              beq     67$
              lda     .near SW_SIL
              and     ##CONST_SIL_BOTTOM
              bne     66$
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     ##OFS_DS_BSILHEIGHT
              jsr     .kbank secdsB
              sep     #0x20
              lda     .near SW_SIL
              ora     #CONST_SIL_BOTTOM
              sta     .near SW_SIL
              rep     #0x20
66$:          lda     .near SW_SIL
              and     ##CONST_SIL_TOP
              bne     67$
              ldy     ##OFS_SEC_CEILINGHEIGHT
              lda     ##OFS_DS_TSILHEIGHT
              jsr     .kbank secdsB
              sep     #0x20
              lda     .near SW_SIL
              ora     #CONST_SIL_TOP
              sta     .near SW_SIL
              rep     #0x20

              ;; save the sprite clipping info
67$:          lda     .near SW_SIL
              and     ##CONST_SIL_TOP
              ora     long:(WPAGE+W_MASKED)
              beq     68$
              ldx     ##.word0 ceilingclip
              ldy     ##OFS_DS_SPRTOPCLIP
              jsr     .kbank saveClip
68$:          lda     .near SW_SIL
              and     ##CONST_SIL_BOTTOM
              ora     long:(WPAGE+W_MASKED)
              beq     69$
              ldx     ##.word0 floorclip
              ldy     ##OFS_DS_SPRBOTTOMCLIP
              jsr     .kbank saveClip
69$:          lda     long:(WPAGE+W_MASKED) ; a masked midtexture: both
              beq     70$                   ;   silhouettes
              ldx     .near ds_p
              lda     .near SW_SIL
              and     ##CONST_SIL_TOP
              bne     71$
              jsr     .kbank tsilMin
71$:          lda     .near SW_SIL
              and     ##CONST_SIL_BOTTOM
              bne     72$
              jsr     .kbank bsilMax
72$:          sep     #0x20
              lda     #CONST_SIL_BOTH
              sta     .near SW_SIL
              rep     #0x20

              ;; the silhouette of the drawseg (a byte: its high byte is 0);
              ;; the columns of the drawseg for R_DrawSprite: x2, and x1
              ;; (255 when it neither clips sprites nor has a masked
              ;; texture); ds_p++
70$:          ldy     .near ds_p
              lda     long:dsCount          ; (a byte: its high byte is 0)
              tax
              sep     #0x20
              lda     .near SW_SIL
              sta     abs:OFS_DS_SILHOUETTE,y
              beq     73$
              lda     .near SW_START
              bra     74$
73$:          lda     #0xff
74$:          sta     long:dsX1,x
              lda     .near rw_stopx
              dec     a
              sta     long:dsX2,x
              inx
              txa
              sta     long:dsCount
              rep     #0x20
              tya
              clc
              adc     ##SIZEOF_DS
              PUTWN   ds_p
              rtl
              .space  15                    ; preserve normD's linked address

axisJump:     .word   .word0 axisN0, .word0 axisN4, .word0 axisN8, .word0 axisNC

;;; ---------------------------------------------------------------------------
;;; scaleFast: the scales of the seg for D = SW_D of 4..32767 map units. The
;;; scale of column x is
;;;   scale(x) = PROJECTIONY sin(ANG90 + xa[x] + th) / (D sin(ANG90 + xa[x]))
;;; (R_ScaleFromGlobalAngle), xa = xtoviewangleTable, th = viewangle16 -
;;; rw_normalangle. rw_scale = scale1 = scale(start) = P1 / D with P1 =
;;; sin(ANG90 + xa[start] + th) * KS[start] (8.8); the step is the slope of
;;; the scale over the columns, 2.0025 sin(th) / D (the columns of
;;; xtoviewangleTable are 79.9 tan apart), and scale2 = scale1 + (stop -
;;; start) * step: no division. 1 / D = RECIP_TABLE[M] * 2^(lz - 31)
;;; (normD). Out: C = 0 (Z set) when done; C != 0 (a sine of the start
;;; below 0, or a scale below 256): the old way.
;;; ---------------------------------------------------------------------------
scaleFast:    lda     .near viewangle16     ; th
              sec
              sbc     .near rw_normalangle
              PUTWN   SW_TH
              lda     .near SW_START        ; s1 = sin(ANG90 + xa[start] + th)
              asl     a
              tax
              lda     abs:.near xtoviewangleTable,x
              clc
              adc     ##0x4000
              clc
              adc     .near SW_TH
              jsr     .kbank sinA
              bcc     1$
              brl     90$                   ; below 0: the old way
1$:           PUTWD   MA
              lda     .near SW_START        ; P1 = hi16(s1 * KS[start]), 8.8
              asl     a
              tax
              lda     long:KS,x
              jsr     .kbank qmulh          ; (+ 0 or 1 in the last bit)
              PUTWD   MA
              jsr     .kbank normD          ; C = R16, SW_LZ = 2 lz
              sta     .near SW_R
              ldx     .near SW_LZ
              cpx     ##16
              bcs     5$
              jsr     .kbank qmulh          ; lz < 8: scale1 = hi16(P1 * R16)
              ldx     .near SW_LZ           ;   >> (7 - lz), below 1.0
              jsr     (.kbank (shrS+14),x)
              ldx     ##0
              bra     10$

              ;; lz >= 8: scale1 = (P1 * R16) >> (23 - lz): the product >> 8
              ;; from its bytes, then >> (15 - lz) through a marker bit above
              ;; the high byte
5$:           jsr     .kbank qmul           ; Y = [l1 l0], C = [h1 h0]
              sty     dp:.tiny QT           ; QT..QT+3 = l0 l1 h0 h1
              PUTWD   (QT+2)
              ldx     .near SW_LZ           ; scale1 = [h1 h0 l1] >> s, s = 15 - lz
              lda     dp:.tiny (QT+1)       ;   (2..7): its low byte r0 from
              jsr     (.kbank (shrS-2),x)   ;   [h0 l1] >> s, its bytes r2 r1
              tay                           ;   from [h1 h0] >> s (shrS: 14 -
              lda     dp:.tiny (QT+2)       ;   (lz - 1) shifts)
              jsr     (.kbank (shrS-2),x)
              sta     dp:.tiny QT           ; QT = r1, QT+1 = r2
              xba
              and     ##0x00ff
              tax                           ; X = r2
              tya
              sep     #0x20
              xba                           ; B = r0
              lda     dp:.tiny QT           ; A = r1
              xba
              rep     #0x20                 ; X:C = scale1 = [r2 r1 r0]

10$:          cpx     ##0                   ; below 256: the old way
              bne     11$
              cmp     ##256
              bcs     11$
              brl     90$
11$:          ldy     .near ds_p            ; rw_scale = ds_p->scale1
              PUT32NY rw_scale, OFS_DS_SCALE1
              lda     .near rw_stopx        ; one column: scale2 = scale1, step 0
              dec     a
              cmp     .near SW_START
              bne     20$
              lda     .near rw_scale
              ldx     .near (rw_scale+2)
              ldy     .near ds_p
              PUT32Y  OFS_DS_SCALE2
              lda     ##0
              tax
              ldy     .near ds_p
              PUT32NY rw_scalestep, OFS_DS_SCALESTEP
              lda     ##0
              rts

              ;; the step: hi16(|sin th| * R16) >> (14 - lz) = 2 |sin th| / D,
              ;; times 1.001; the sign of sin th is the top bit of th
20$:          lda     .near SW_TH
              jsr     .kbank sinA
              PUTWD   MA
              lda     .near SW_R
              jsr     .kbank qmul
              ldx     .near SW_LZ
              jsr     (.kbank shrS,x)
              tay
              xba
              and     ##0x00ff
              lsr     a
              lsr     a
              PUTWD   QT
              tya
              clc
              adc     dp:.tiny QT           ; |step|
              PUTWD   MA

              ;; scale2 = scale1 + (stop - start) * step; n = stop - start of 1
              ;; or 2 (a third of the segs on the stairs) without qmul
              lda     .near rw_stopx
              dec     a
              sec
              sbc     .near SW_START
              cmp     ##3
              bcs     19$
              lsr     a                     ; carry: n = 1
              lda     dp:.tiny MA
              ldx     ##0
              bcs     17$
              asl     a                     ; n = 2: 2 |step|
              bcc     17$
              inx
              bra     17$
19$:          jsr     .kbank qmul
              tax
              tya
17$:          bit     .near SW_TH
              bpl     21$
              NEG32
21$:          clc
              adc     .near rw_scale
              tay
              txa
              adc     .near (rw_scale+2)
              tax
              tya                           ; X:C = scale2
              cpx     ##0                   ; below 256: the old way
              bmi     90$
              bne     22$
              cmp     ##256
              bcc     90$
22$:          ldy     .near ds_p
              PUT32Y  OFS_DS_SCALE2
              lda     dp:.tiny MA           ; rw_scalestep = ds_p->scalestep
              ldx     ##0
              bit     .near SW_TH
              bpl     23$
              eor     ##0xffff
              inc     a
              beq     23$
              dex
23$:          ldy     .near ds_p
              PUT32NY rw_scalestep, OFS_DS_SCALESTEP
              lda     ##0
              rts
90$:          lda     ##1
              rts

;;; normD: C = RECIP_TABLE[M] ~ (2^31 - 1) / M for the 16 bits M of D (SW_D,
;;; 4..32767 map units) from its first 1 bit, D ~ M * 2^-lz; SW_LZ = 2 lz
;;; (lz = 1..13; a byte, the high byte stays 0). The window V (16 bits from
;;; the first nonzero byte) and the bytes below it (at X) shift left until
;;; bit 15 of V is set (at most 7 times). Destroys SW_D, X, Y.
normD:        lda     .near (SW_D+2)
              cmp     ##0x0100
              bcs     1$
              lda     .near (SW_D+1)        ; D < 256: V = D >> 8, lz = 8 + the
              ldy     ##16                  ;   shifts (the low byte of the
              ldx     ##.word0 (SW_D-1)     ;   word below is any byte)
              bra     2$
1$:           ldy     ##0
              ldx     ##.word0 SW_D
2$:           cmp     ##0x8000
              bcs     3$
              asl     abs:0,x
              rol     a
              iny
              iny
              bra     2$
3$:           asl     a                     ; RECIP_TABLE[M]
              tax
              sty     .near SW_LZ           ; (16-bit: its high byte 0)
              lda     long:RECIP_TABLE,x
              rts
              .space  5                     ; (sinA keeps its address)

;;; sinA: C = |finesineapprox(C >> 3)|, the sine of the angle C (16 bits) as
;;; the table value (25..65535); carry set for a negative sine. Destroys X.
sinA:         lsr     a
              lsr     a
              lsr     a
              cmp     ##4096
              bcs     2$
              cmp     ##2048
              bcc     1$
              eor     ##4095
1$:           asl     a
              tax
              lda     long:finesineTable_part_1,x
              clc
              rts
2$:           and     ##4095
              cmp     ##2048
              bcc     3$
              eor     ##4095
3$:           asl     a
              tax
              lda     long:finesineTable_part_1,x
              sec
              rts

;;; shrS: C >>= 14 - j, entered by jsr (shrS + 2 k, x) with X = 2 lz (j = lz
;;; + k): j = 0..14.
shrC:         lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              rts
shrS:         .word   .word0 (shrC+0), .word0 (shrC+1), .word0 (shrC+2), .word0 (shrC+3)
              .word   .word0 (shrC+4), .word0 (shrC+5), .word0 (shrC+6), .word0 (shrC+7)
              .word   .word0 (shrC+8), .word0 (shrC+9), .word0 (shrC+10), .word0 (shrC+11)
              .word   .word0 (shrC+12), .word0 (shrC+13), .word0 (shrC+14)

;;; distAny: SW_D = D and SW_OFF = floor(OFF) (R_StoreWallRange) for a seg
;;; that is not along an axis: (c, s) = the unit vector of rw_normalangle,
;;; v1 - the view = (dx - fx, dy - fy) with the map units dx = v1.x -
;;; viewx.hi and the fraction fx = viewx.lo (8 bits here; the same for y):
;;;   D = dx c + dy s - (fx c + fy s),  OFF = dy c - dx s - (fy c - fx s)
;;; (16.16; qmul for the map units, the quarter squares T for the
;;; fractions: 0.02 map units at most).
distAny:      ldy     ##OFS_SEG_V1          ; dx
              lda     [.tiny WP_SEG],y
              sec
              sbc     .near (viewx+2)
              PUTWN   SW_DX
              iny
              iny
              lda     [.tiny WP_SEG],y      ; dy
              sec
              sbc     .near (viewy+2)
              PUTWN   SW_DY
              lda     .near rw_normalangle  ; c
              clc
              adc     ##0x4000
              jsr     .kbank sinA
              jsr     .kbank sfrac
              lda     .near (viewx+1)       ; D = dx c - fx c
              ldx     .near SW_DX
              jsr     .kbank fmulv
              PUT32N  SW_D
              lda     .near (viewy+1)       ; O = dy c - fy c
              ldx     .near SW_DY
              jsr     .kbank fmulv
              PUT32N  SW_O
              lda     .near rw_normalangle  ; s
              jsr     .kbank sinA
              jsr     .kbank sfrac
              lda     .near (viewy+1)       ; D += dy s - fy s
              ldx     .near SW_DY
              jsr     .kbank fmulv
              clc
              adc     .near SW_D
              tay
              txa
              adc     .near (SW_D+2)
              tax
              tya
              PUT32N  SW_D
              lda     .near (viewx+1)       ; OFF = O - (dx s - fx s)
              ldx     .near SW_DX
              jsr     .kbank fmulv
              eor     ##0xffff
              sec
              adc     .near SW_O
              txa
              eor     ##0xffff
              adc     .near (SW_O+2)
              PUTWN   SW_OFF
              rts

;;; sfrac: MA = C (a magnitude, 0.16), SW_M8 = its high byte, SW_BS = the
;;; carry in bit 15 (its sign).
sfrac:        PUTWD   MA
              xba                           ; the high byte
              and     ##0x00ff
              PUTWN   SW_M8
              lda     ##0
              ror     a
              PUTWN   SW_BS
              rts

;;; fmulv: X:C = (d - f / 256) * the fraction (MA, SW_BS), 16.16, for the
;;; signed map units d = X and the byte f = the low byte of C: d * MA
;;; (qmul) less f * SW_M8 (quarter squares: T[f + m] - T[|f - m|]).
fmulv:        and     ##0x00ff
              tay                           ; Y = f
              clc
              adc     .near SW_M8
              asl     a
              phx                           ; (d)
              tax                           ; X = 2 (f + m)
              tya
              sec
              sbc     .near SW_M8
              bcs     1$
              eor     ##0xffff
              inc     a
1$:           asl     a
              tay                           ; Y = 2 |f - m|
              lda     long:MULT0,x
              tyx
              sec
              sbc     long:MULT0,x          ; f * m, 0.16
              PUTWN   SW_T
              pla                           ; d
              tax
              dec     a                     ; N: (d <= 0) ^ the sign of m, the
              eor     .near SW_BS           ;   sign of the product
              php
              txa
              bmi     5$
              beq     5$
              jsr     .kbank qmul           ; d > 0: |d - f| = d - f: d * MA
              tax                           ;   (Y = lo, C = hi) - f * m
              tya
              sec
              sbc     .near SW_T
              bcs     7$
              dex
              bra     7$
5$:           eor     ##0xffff              ; d <= 0: |d - f| = -d + f
              inc     a
              jsr     .kbank qmul
              tax
              tya
              clc
              adc     .near SW_T
              bcc     7$
              inx
7$:           plp
              bpl     8$
              NEG32
8$:           rts

;;; KS: PROJECTIONY / sin(ANG90 + xtoviewangleTable[x]) (8.8) of the columns
;;; (the table sine of R_ScaleFromGlobalAngle); one read a seg: cold.
;;; edgeS: step = -X:C to WPAGE + SW_EO; start = SW_P - step before it
;;; (edgeSlow: cold, so not in segcode).
edgeS:        txy
              ldx     .near SW_EO
              eor     ##0xffff
              clc
              adc     ##1
              sta     long:WPAGE,x
              tya
              eor     ##0xffff
              adc     ##0
              sta     long:(WPAGE+2),x
              lda     .near SW_P
              sec
              sbc     long:WPAGE,x
              sta     long:(WPAGE-4),x
              lda     .near (SW_P+2)
              sbc     long:(WPAGE+2),x
              sta     long:(WPAGE-2),x
              rts

;;; kmul: C = lo16(MA * C) for C = 1..7 (FMFAST: the high word of a scale
;;; or a step), as the low word of qmul.
kmul:         asl     a
              tax
              lda     dp:.tiny MA
              jmp     (.kbank (kmulT-2),x)
kmulT:        .word   .word0 km1, .word0 km2, .word0 km3, .word0 km4
              .word   .word0 km5, .word0 km6, .word0 km7
km7:          asl     a                     ; 8 MA - MA
              asl     a
              asl     a
              sec
              sbc     dp:.tiny MA
              rts
km6:          asl     a                     ; (2 MA + MA) * 2
              clc
              adc     dp:.tiny MA
              asl     a
              rts
km5:          asl     a                     ; 4 MA + MA
              asl     a
km1b:         clc
              adc     dp:.tiny MA
              rts
km3:          asl     a                     ; 2 MA + MA
              bra     km1b
km4:          asl     a
km2:          asl     a
km1:          rts

              .public c21Floor
;;; bspSub's original signed32 compare, retaining its previously discarded
;;; low difference as worldbottom. High result/flags and Y return unchanged.
;;; Both pointers identify the current front sector. Fixed JMP continuation
;;; avoids a call/return and stack writes; CN_LSEC provides frame validity.
c21Floor:
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     [.tiny WP_FS],y
              sec
              sbc     .near viewz
              sta     .near worldbottom
              iny
              iny
              lda     [.tiny WP_FS],y
              sbc     .near (viewz+2)
              sta     .near (worldbottom+2)
              jmp     .kbank c21FloorDone
              .space  SWR_PADN - (. - c21Floor) ; original fragment extent

              .section coldcode, text
KS:
              .word   57994, 57597, 57250, 56911, 56535, 56167, 55847, 55494
              .word   55147, 54807, 54474, 54111, 53793, 53446, 53139, 52806
              .word   52480, 52161, 51849, 51544, 51215, 50924, 50610, 50331
              .word   50032, 49739, 49454, 49150, 48878, 48589, 48330, 48055
              .word   47787, 47527, 47272, 47005, 46764, 46511, 46284, 46045
              .word   45813, 45587, 45368, 45140, 44935, 44721, 44514, 44314
              .word   44121, 43935, 43755, 43581, 43403, 43243, 43078, 42920
              .word   42769, 42624, 42486, 42355, 42230, 42104, 41991, 41878
              .word   41779, 41679, 41586, 41500, 41420, 41347, 41281, 41220
              .word   41167, 41119, 41077, 41040, 41012, 40990, 40974, 40964
              .word   40961, 40963, 40973, 40989, 41011, 41038, 41075, 41116
              .word   41164, 41217, 41277, 41343, 41416, 41495, 41581, 41673
              .word   41773, 41872, 41984, 42096, 42221, 42347, 42477, 42615
              .word   42759, 42910, 43068, 43232, 43391, 43569, 43743, 43922
              .word   44108, 44300, 44500, 44706, 44920, 45124, 45351, 45570
              .word   45795, 46026, 46265, 46492, 46745, 46984, 47251, 47505
              .word   47765, 48033, 48307, 48565, 48854, 49124, 49428, 49713
              .word   50005, 50304, 50582, 50895, 51186, 51513, 51819, 52129
              .word   52447, 52773, 53105, 53410, 53757, 54076, 54437, 54769
              .word   55109, 55455, 55808, 56128, 56494, 56868, 57208, 57552
              .word   57949

;;; ---------------------------------------------------------------------------
;;; Helpers of R_StoreWallRange, after the seg loop in bank 3 (the free
;;; slots after R_RenderSegLoop: the BSP code at $4000 is full).
;;; ---------------------------------------------------------------------------
              .section segcode, text

;;; silBoth: silhouette SIL_BOTH, sprtopclip = screenheightarray,
;;; sprbottomclip = negonearray, bsilheight = INT32_MAX, tsilheight =
;;; INT32_MIN, for the drawseg at X; its clips are set (SW_OPEN = 0). The
;;; high bytes of the banks of the pointers are 0.
silBoth:      sep     #0x20
              lda     #CONST_SIL_BOTH
              sta     .near SW_SIL
              lda     #.byte0 screenheightarray
              sta     abs:OFS_DS_SPRTOPCLIP,x
              lda     #.byte1 screenheightarray
              sta     abs:(OFS_DS_SPRTOPCLIP+1),x
              lda     #.byte2 screenheightarray
              sta     abs:(OFS_DS_SPRTOPCLIP+2),x
              lda     #.byte0 negonearray
              sta     abs:OFS_DS_SPRBOTTOMCLIP,x
              lda     #.byte1 negonearray
              sta     abs:(OFS_DS_SPRBOTTOMCLIP+1),x
              lda     #.byte2 negonearray
              sta     abs:(OFS_DS_SPRBOTTOMCLIP+2),x
              stz     .near SW_OPEN
              rep     #0x20
              jsr     .kbank tsilMin
              ;; fall into bsilMax

;;; bsilMax: ds->bsilheight = INT32_MAX; tsilMin: ds->tsilheight =
;;; INT32_MIN, for the drawseg at X.
bsilMax:      lda     ##0xffff              ; (16-bit stores: no REP/SEP)
              sta     abs:OFS_DS_BSILHEIGHT,x
              lda     ##0x7fff
              sta     abs:(OFS_DS_BSILHEIGHT+2),x
              rts
tsilMin:      stz     abs:OFS_DS_TSILHEIGHT,x
              lda     ##0x8000
              sta     abs:(OFS_DS_TSILHEIGHT+2),x
              rts

;;; midTex: the fixed_t at near Y = the one at near X + (C << FRACBITS).
midTex:       clc
              adc     abs:2,x
              sta     abs:2,y
              lda     abs:0,x
              sta     abs:0,y
              rts

;;; secdsF, secdsB: the fixed_t at offset Y of the front (back) sector to
;;; the field C of the drawseg ds_p; X = ds_p on exit.
secdsB:       clc                           ; (16-bit: no REP/SEP)
              adc     .near ds_p
              tax
              lda     [.tiny WP_BS],y
              sta     abs:0,x
              iny
              iny
              lda     [.tiny WP_BS],y
              bra     secds3
secdsF:       clc
              adc     .near ds_p
              tax
              lda     [.tiny WP_FS],y
              sta     abs:0,x
              iny
              iny
              lda     [.tiny WP_FS],y
secds3:       sta     abs:2,x
              ldx     .near ds_p
              rts

;;; rowMod: C = Mod(sidedef->rowoffset, textureheight[C]): 0 <= result < b
;;; for b > 0, as Mod of r_draw.c.
rowMod:       tax                           ; the texture
              ldy     ##OFS_SIDE_ROWOFFSET  ; a
              lda     [.tiny WP_SIDE],y
              beq     1$                    ; !a: 0 (no look at b)
              txa
              asl     a
              tay
              lda     [.tiny WP_TH],y       ; b
              tax
              dec     a
              PUTWN   SW_T                  ; b - 1
              ldy     ##OFS_SIDE_ROWOFFSET
              txa                           ; b & (b - 1): not a power of 2
              and     .near SW_T
              bne     2$
              lda     [.tiny WP_SIDE],y     ; a & (b - 1)
              and     .near SW_T
1$:           rts
2$:           txa                           ; r = a % b; r < 0 ? r + b : r
              PUTWN   SW_T
              lda     [.tiny WP_SIDE],y
              jsl     long:_Mod16
              cmp     ##0
              bpl     3$
              clc
              adc     .near SW_T
3$:           rts

;;; saveClip: copy clip X (the near address of ceilingclip or floorclip)
;;; from start to rw_stopx - 1 to lastopening; the drawseg field Y =
;;; lastopening - start; lastopening += rw_stopx - start. MVN: one byte
;;; and one 8-bit store each 7 cycles (the clip and the openings are in the
;;; near bank); Y ends at the new lastopening. The high byte of the bank
;;; of the field is 0.
saveClip:     tya
              clc
              adc     .near ds_p
              tay                           ; the field
              lda     .near lastopening     ; lastopening - start (int16_t)
              sec
              sbc     .near SW_START
              sec
              sbc     .near SW_START
              sta     abs:0,y               ; (16-bit: no REP/SEP)
              lda     .near (lastopening+2) ; the bank, its high byte 0
              and     ##0x00ff
              sta     abs:2,y
              txa                           ; from clip + 2 * start
              clc
              adc     .near SW_START
              adc     .near SW_START
              tax
              lda     .near rw_stopx        ; 2 * (rw_stopx - start) bytes
              sec
              sbc     .near SW_START
              asl     a
              dec     a
              ldy     .near lastopening     ; to lastopening
              .byte   0x54, .byte2 openings, .byte2 ceilingclip ; mvn, near to near
              tya
              PUTWN   lastopening
              rts

;;; ---------------------------------------------------------------------------
;;; The edges of the texture tiers in the direct page of the loop
;;; (R_RenderSegLoop of src/iigs/r_seg65.s), for a height h (fixed_t):
;;;   step = -FixedMul(h, rw_scalestep)                        at WPAGE+X
;;;   start = (CENTERY << FRACBITS) - FixedMul(h, rw_scale)
;;;           + round - step                                   at WPAGE+X-4
;;; one step early, round = FRACUNIT - 1 (top edges) or FRACUNIT (bottom
;;; edges). The heights of a seg are whole map units less the same viewz,
;;; so they share their low word AL, and h * B = AH * B * 65536 + AL * B
;;; gives FixedMul(h, B) = AH * B + FixedMul(AL, B): the second part is the
;;; same for each edge. A height with another low word takes FixedMul.
;;; ---------------------------------------------------------------------------

;;; edgeAL: SW_AL = the low word of worldtop, SW_CS = FixedMul(AL, rw_scale),
;;; SW_CSS = FixedMul(AL, rw_scalestep).
edgeAL:       lda     .near worldtop
              sta     .near SW_AL
              bne     1$
              stz     .near SW_CS           ; AL = 0: both 0 (8 bytes one after
              stz     .near (SW_CS+2)       ;   the other: the 16-bit stores
              stz     .near SW_CSS          ;   wait no more than 8-bit ones)
              stz     .near (SW_CSS+2)
              rts
1$:           PUTWD   MA
              FIXAL   rw_scale, SW_CS
              FIXALZ  rw_scalestep, SW_CSS, edgeALz
edgeALz:      rts

;;; edge: the edge of the height at the near address Y into WPAGE + X;
;;; carry set: round = FRACUNIT, clear: FRACUNIT - 1.
edge:         stx     .near SW_EO           ; (X < 256; 16-bit stores: no
              lda     ##0                   ;   REP/SEP)
              rol     a
              sta     .near SW_ER
              lda     abs:0,y               ; the low word of the heights?
              cmp     .near SW_AL
              beq     edgeH
              jsl     long:edgeSlow         ; another low word: FixedMul
              jmp     .kbank edgeS
edgeZ:        sta     long:WPAGE,x          ; rw_scalestep = 0 (FMFASTZ: C = 0,
              sta     long:(WPAGE+2),x      ;   X = SW_EO): step 0, no product
              bra     edgeP
edgeH:        lda     abs:2,y               ; MA = AH
              PUTWD   MA
              FMFASTZ rw_scalestep, SW_CSS, edgeZ ; X:C = FixedMul(h, rw_scalestep)
              txy                           ; step = -X:C to WPAGE + SW_EO
              ldx     .near SW_EO
              eor     ##0xffff
              clc
              adc     ##1
              sta     long:WPAGE,x
              tya
              eor     ##0xffff
              adc     ##0
              sta     long:(WPAGE+2),x
edgeP:        FMFAST  rw_scale, SW_CS       ; X:C = P = FixedMul(h, rw_scale)
              ;; start = (CENTERY << FRACBITS) + round - P - step before it:
              ;; with Q = P + the stored step, (CENTERY + 1) << FRACBITS + ~Q
              ;; for round = FRACUNIT - 1, (CENTERY + 1) << FRACBITS - Q for
              ;; round = FRACUNIT (no SW_P: one carry chain)
              ldy     .near SW_ER
              bne     3$
              txy
              ldx     .near SW_EO
              clc
              adc     long:WPAGE,x          ; Q.lo (C: its carry)
              eor     ##0xffff
              sta     long:(WPAGE-4),x
              tya
              adc     long:(WPAGE+2),x      ; Q.hi
              eor     ##0xffff
              clc
              adc     ##(CONST_CENTERY + 1)
              sta     long:(WPAGE-2),x
              rts
3$:           txy
              ldx     .near SW_EO
              clc
              adc     long:WPAGE,x          ; Q.lo (C: its carry)
              eor     ##0xffff
              inc     a                     ; -Q.lo (Z: Q.lo = 0)
              sta     long:(WPAGE-4),x
              beq     4$
              tya
              adc     long:(WPAGE+2),x      ; Q.hi
              eor     ##0xffff
              clc
              adc     ##(CONST_CENTERY + 1)
              sta     long:(WPAGE-2),x
              rts
4$:           tya                           ; -Q with Q.lo = 0: + 1 in the
              adc     long:(WPAGE+2),x      ;   high word
              eor     ##0xffff
              clc
              adc     ##(CONST_CENTERY + 2)
              sta     long:(WPAGE-2),x
              rts

              .space  37                    ; (qmul keeps its address)

;;; qmul: Y = the low word, C = the high word of MA * C, unsigned 16 x 16,
;;; with the quarter squares of src/iigs/m_fixed65.s: a * b = sq(a + b) -
;;; sq(|a - b|) (the 4 table reads of QMULR there); one word of temporary
;;; store (QT) and no other.
              .public qmul
qmul:         tay                           ; Y = b
              clc
              adc     dp:.tiny MA           ; s = a + b (17 bits)
              bcs     20$
              asl     a
              tax
              bcs     10$
              lda     long:SQH,x
              PUTWD   QT
              lda     long:SQL,x
              bra     50$
10$:          lda     long:(SQH+0x10000),x
              PUTWD   QT
              lda     long:(SQL+0x10000),x
              bra     50$
20$:          asl     a
              tax
              bcs     30$
              lda     long:(SQH+0x20000),x
              PUTWD   QT
              lda     long:(SQL+0x20000),x
              bra     50$
30$:          lda     long:(SQH+0x30000),x
              PUTWD   QT
              lda     long:(SQL+0x30000),x
50$:          tax                           ; X = sq(s), low word
              tya                           ; d = |b - a|
              sec
              sbc     dp:.tiny MA
              bcs     60$
              eor     ##0xffff
              inc     a
60$:          asl     a                     ; (carry: the bank of sq(d))
              tay
              txa
              tyx                           ; X: the index of sq(d), C: sq(s)
              bcs     70$
              sec
              sbc     long:SQL,x
              tay
              lda     dp:.tiny QT
              sbc     long:SQH,x
              rts
70$:          sbc     long:(SQL+0x10000),x  ; (carry set: bcs)
              tay
              lda     dp:.tiny QT
              sbc     long:(SQH+0x10000),x
              rts

;;; qmulh: C = the high word of MA * C, or 1 more: sq(a + b) - sq(|a - b|)
;;; from the high words of the quarter squares only (the borrow of the low
;;; words is not taken): 2 table reads (4 bytes) instead of 4, no store. For
;;; the products of the renderer whose low word is not used and where 1
;;; more in the last bit of the high word is nothing (the scales).
              .public qmulh
qmulh:        tay                           ; Y = b
              clc
              adc     dp:.tiny MA           ; s = a + b (17 bits)
              bcs     20$
              asl     a
              tax
              bcs     10$
              lda     long:SQH,x
              bra     50$
10$:          lda     long:(SQH+0x10000),x
              bra     50$
20$:          asl     a
              tax
              bcs     30$
              lda     long:(SQH+0x20000),x
              bra     50$
30$:          lda     long:(SQH+0x30000),x
50$:          tax                           ; X = sq(s), high word
              tya                           ; d = |b - a|
              sec
              sbc     dp:.tiny MA
              bcs     60$
              eor     ##0xffff
              inc     a
60$:          asl     a                     ; (carry: the bank of sq(d))
              tay
              txa
              tyx
              bcs     70$
              sec
              sbc     long:SQH,x
              rts
70$:          sbc     long:(SQH+0x10000),x  ; (carry set: bcs)
              rts

;;; ---------------------------------------------------------------------------
;;; The cold parts of R_StoreWallRange: once a frame, and heights that are
;;; not whole map units.
;;; ---------------------------------------------------------------------------
              .space  SEG_PADN         ; preserve the following section's placement

              .section coldcode, text

;;; ---------------------------------------------------------------------------
;;; void R_WallFrame(void): the banks of the long pointers of the BSP walk,
;;; and its tables (R_RenderPlayerView, before the walk): they stay for the
;;; walk of the frame.
;;; ---------------------------------------------------------------------------
              .public R_WallFrame
R_WallFrame:  sep     #0x20
              lda     .near (_g_segs+2)
              sta     dp:.tiny (WP_SEG+2)
              lda     .near (_g_sides+2)
              sta     dp:.tiny (WP_SIDE+2)
              lda     .near (_g_lines+2)
              sta     dp:.tiny (WP_LINE+2)
              lda     .near (_g_sectors+2)
              sta     dp:.tiny (WP_FS+2)
              lda     .near (_g_sectors+2)
              sta     dp:.tiny (WP_BS+2)
              lda     .near texturetranslation
              sta     dp:.tiny WP_TT
              lda     .near (texturetranslation+1)
              sta     dp:.tiny (WP_TT+1)
              lda     .near (texturetranslation+2)
              sta     dp:.tiny (WP_TT+2)
              lda     .near textureheight
              sta     dp:.tiny WP_TH
              lda     .near (textureheight+1)
              sta     dp:.tiny (WP_TH+1)
              lda     .near (textureheight+2)
              sta     dp:.tiny (WP_TH+2)
              lda     .near sprites
              sta     dp:.tiny WP_SPR
              lda     .near (sprites+1)
              sta     dp:.tiny (WP_SPR+1)
              lda     .near (sprites+2)
              sta     dp:.tiny (WP_SPR+2)
              lda     .near fileinfo
              sta     dp:.tiny WP_FI
              lda     .near (fileinfo+1)
              sta     dp:.tiny (WP_FI+1)
              lda     .near (fileinfo+2)
              sta     dp:.tiny (WP_FI+2)
              stz     dp:.tiny D8           ; (div8)
              rep     #0x20
              lda     .near PR_IOK          ; the sprite tables: once (they
              bne     1$                    ;   read WP_SPR, WP_FI)
              jsl     long:R_InitSpriteIScales
1$:

              ;; the G parts of R_ProjectSprite (src/iigs/r_thing65.s) for a
              ;; thing at whole map units: the low words of its tr_x and tr_y
              ;; are -viewx.lo (SW_T) and -viewy.lo (SW_EH); PR_GZ =
              ;; G(x, cos) + G(y, sin), PR_GX = G(x, sin) - G(y, cos)
              lda     ##0
              sec
              sbc     .near viewx
              PUTWN   SW_T
              lda     ##0
              sec
              sbc     .near viewy
              PUTWN   SW_EH
              lda     .near viewcos
              PUTWD   MA
              GPART   SW_T, viewcos
              PUT32N  PR_GZ
              GPART   SW_EH, viewcos
              PUT32N  PR_GX
              lda     .near viewsin
              PUTWD   MA
              GPART   SW_EH, viewsin
              clc
              adc     .near PR_GZ
              tay
              txa
              adc     .near (PR_GZ+2)
              tax
              tya
              PUT32N  PR_GZ
              GPART   SW_T, viewsin
              sec
              sbc     .near PR_GX
              tay
              txa
              sbc     .near (PR_GX+2)
              tax
              tya
              PUT32N  PR_GX
              jmp     long:prFrame          ; (the constants of gTZ and gTX: r_thing65)

;;; edgeSlow: SW_P as edgeP, and X:C = FixedMul(h, rw_scalestep), with
;;; FixedMul for the height h at near Y.
edgeSlow:     phy
              lda     .near rw_scale
              sta     dp:.tiny _Dp
              lda     .near (rw_scale+2)
              sta     dp:.tiny (_Dp+2)
              lda     abs:2,y
              tax
              lda     abs:0,y
              jsl     long:FixedMul         ; X:C = FixedMul(h, rw_scale)
              eor     ##0xffff              ; SW_P = (CENTERY << FRACBITS)
              ldy     .near SW_ER           ;   + round + ~X:C + 1
              bne     1$
              sta     .near SW_P            ; round = FRACUNIT - 1
              txa
              eor     ##0xffff
              sec
              adc     ##CONST_CENTERY
              bra     2$
1$:           clc                           ; round = FRACUNIT
              adc     ##1
              sta     .near SW_P
              txa
              eor     ##0xffff
              adc     ##(CONST_CENTERY + 1)
2$:           sta     .near (SW_P+2)
              lda     .near rw_scalestep
              sta     dp:.tiny _Dp
              lda     .near (rw_scalestep+2)
              sta     dp:.tiny (_Dp+2)
              ply
              lda     abs:2,y
              tax
              lda     abs:0,y
              jmp     long:FixedMul         ; FixedMul(h, rw_scalestep)

;;; qmulL: qmul for the far code (R_WallFrame): alone, so that it goes last.
              .space  8                ; preserve following code's cache slots

              .section bspcode, text
              .public qmulL
qmulL:        jsr     .kbank qmul
              rtl

;;; ---------------------------------------------------------------------------
;;; scaleSlow: the scales of the seg the old way, for D below 4 map units (or
;;; below 0) and the scales at a clamp: R_ScaleFromGlobalAngle at both ends
;;; (with rw_distance), the step by division.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
scaleSlow:    lda     .near SW_START        ; ds_p->scale1 = rw_scale
              jsl     long:R_ScaleFromGlobalAngle
              ldy     .near ds_p
              PUT32NY rw_scale, OFS_DS_SCALE1
              lda     .near rw_stopx        ; stop > start ?
              dec     a
              cmp     .near SW_START
              bne     11$
              lda     .near rw_scale        ; no: ds_p->scale2 = ds_p->scale1
              ldx     .near (rw_scale+2)
              PUT32Y  OFS_DS_SCALE2
              rtl
11$:          jsl     long:R_ScaleFromGlobalAngle ; ds_p->scale2 = R_ScaleFromGlobalAngle(stop)
              ldy     .near ds_p
              PUT32Y  OFS_DS_SCALE2
              ;; rw_scalestep = (ds_p->scale2 - rw_scale) / (stop - start),
              ;; truncated as in C: |N| / d by bytes (div8s), then the sign
              ;; of N. |N| < 0x400000: the scales are 256..64 * FRACUNIT.
              lda     .near rw_stopx        ; D8 = d << 8, d = stop - start:
              dec     a                     ;   1..159
              sec
              sbc     .near SW_START
              sep     #0x20
              sta     dp:.tiny (D8+1)
              rep     #0x20
              lda     abs:OFS_DS_SCALE2,y   ; N = scale2 - rw_scale: Y = the high
              sec                           ;   word, X = the low word
              sbc     .near rw_scale
              tax
              lda     abs:(OFS_DS_SCALE2+2),y
              sbc     .near (rw_scale+2)
              tay
              bpl     20$
              txa                           ; N < 0: |N|
              eor     ##0xffff
              clc
              adc     ##1
              tax
              tya
              eor     ##0xffff
              adc     ##0
              tay
              sep     #0x20
              lda     #0x80
              bra     21$
20$:          sep     #0x20
              lda     #0
21$:          sta     dp:.tiny DSIGN
              rep     #0x20
              txa                           ; the bytes n1, n0 of |N| to _Dp
              sep     #0x20
              sta     dp:.tiny _Dp
              xba
              sta     dp:.tiny (_Dp+1)
              tya                           ; n2 < d: the quotient byte q2 is 0,
              cmp     dp:.tiny (D8+1)       ;   the remainder n2
              bcs     22$
              xba
              ldx     ##0
              bra     23$
22$:          rep     #0x20                 ; else q2 = n2 / d (X)
              tya
              jsr     .kbank div8s
              tax
              sep     #0x20
23$:          lda     dp:.tiny (_Dp+1)      ; q1 (Y)
              rep     #0x20
              jsr     .kbank div8s
              tay
              sep     #0x20
              lda     dp:.tiny _Dp          ; q0
              rep     #0x20
              jsr     .kbank div8s
              sep     #0x20                 ; X:C = q2:q1:q0
              xba
              tya
              xba
              rep     #0x20
              tay
              txa
              and     ##0x00ff
              tax
              tya
              bit     dp:.tiny (DSIGN-1)    ; N < 0: - X:C
              bpl     24$
              NEG32
24$:          ldy     .near ds_p
              PUT32NY rw_scalestep, OFS_DS_SCALESTEP
              rtl

;;; div8s: 8 steps of the long division by d, for C = r:n (r < d) and
;;; D8 = d << 8: C = the new r:the quotient byte (scaleSlow). A carry out
;;; of r (d > 127) means r >= d.
DIVSTEP       .macro
              asl     a
              bcs     1$
              cmp     dp:.tiny D8
              bcc     2$
1$:           sbc     dp:.tiny D8
              inc     a
2$:
              .endm
div8s:        DIVSTEP
              DIVSTEP
              DIVSTEP
              DIVSTEP
              DIVSTEP
              DIVSTEP
              DIVSTEP
              DIVSTEP
              rts
              .space  4                ; preserve following code's cache slots
