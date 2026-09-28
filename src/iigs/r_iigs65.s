;;; Renderer helpers in 65816 assembly.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"

              .extern _Dp

;;; ---------------------------------------------------------------------------
;;; angle16_t R_PointToAngle16(int16_t x, int16_t y)
;;; In: C = x, _Dp[0-1] = y. Out: C.
;;; pointAngle: the same with y in Y, for jsr from the code of the BSP.
;;; The angle of (x, y) seen from (viewx, viewy), as in r_draw.c: the point
;;; is flipped into the first octant and tantoangle gives the angle of
;;; SlopeDiv16(small, big) = min(small * SLOPERANGE / big, SLOPERANGE).
;;; When x and y from the view are in -16384..16384, the compares of the
;;; octants are plain and slopeT divides; else pointOld does as r_draw.c.
;;; Destroys X, Y and _Dp[4-7].
;;; ---------------------------------------------------------------------------
              .extern viewx, viewy, _UDivMod32

SLOPERANGE    .equ    2048
PA_DEN        .equ    _Dp+4           ; the divisor of slopeOld, a compare
PA_DM         .equ    _Dp+6           ; the divisor - 1 of slopeT
PA_PADN       .equ    58              ; see PA_PAD

;;; N = (A < the divisor in _Dp[4-5]), signed 16-bit. Destroys A.
PASLT         .macro
              sec
              sbc     dp:.tiny PA_DEN
              bvc     1$
              eor     ##0x8000
1$:
              .endm


              .section bspcode, text
              .public R_PointToAngle16, pointAngle
R_PointToAngle16:
              ldy     dp:.tiny _Dp
              jsr     .kbank pointAngle
              rtl

pointAngle:   sec
              sbc     .near (viewx+2)
              tax                           ; X = x
              clc
              adc     ##0x4000              ; x in -16384..16384
              cmp     ##0x8001
              bcs     2$
              tya
              sec
              sbc     .near (viewy+2)
              tay                           ; Y = y
              clc
              adc     ##0x4000              ; y in -16384..16384
              cmp     ##0x8001
              bcs     3$
              txa
              bmi     30$
              stx     dp:.tiny PA_DEN       ; x >= 0
              tya
              bmi     20$
              cmp     dp:.tiny PA_DEN       ; y >= 0: y < x?
              bcs     10$
              jmp     .kbank slopeT         ; octant 0: t
10$:          txa                           ; octant 1: ANG90_16 - 1 - t
              tyx
              beq     11$                   ; x == y == 0: 0
              jsr     .kbank slopeT
              eor     ##0xffff
              sec
              adc     ##0x3fff
11$:          rts
20$:          eor     ##0xffff              ; y < 0: y = -y
              inc     a
              tay
              cmp     dp:.tiny PA_DEN       ; y < x?
              bcs     21$
              jsr     .kbank slopeT         ; octant 8: -t
              eor     ##0xffff
              inc     a
              rts
21$:          txa                           ; octant 7: ANG270_16 + t
              tyx
              jsr     .kbank slopeT
              clc
              adc     ##0xc000
              rts
2$:           tya                           ; far: y from the view too
              sec
              sbc     .near (viewy+2)
              tay
3$:           jsl     long:pointOld         ; (cold: only when the coordinates wrap)
              rts

              ;; x < 0: x = -x
30$:          eor     ##0xffff
              inc     a
              tax
              sta     dp:.tiny PA_DEN
              tya
              bmi     40$
              cmp     dp:.tiny PA_DEN       ; y >= 0: y < x?
              bcs     31$
              jsr     .kbank slopeT         ; octant 3: ANG180_16 - 1 - t
              eor     ##0xffff
              sec
              adc     ##0x7fff
              rts
31$:          txa                           ; octant 2: ANG90_16 + t
              tyx
              jsr     .kbank slopeT
              clc
              adc     ##0x4000
              rts
40$:          eor     ##0xffff              ; y < 0: y = -y
              inc     a
              tay
              cmp     dp:.tiny PA_DEN       ; y < x?
              bcs     41$
              jsr     .kbank slopeT         ; octant 4: ANG180_16 + t
              clc
              adc     ##0x8000
              rts
41$:          txa                           ; octant 5: ANG270_16 - 1 - t
              tyx
              jsr     .kbank slopeT
              eor     ##0xffff
              sec
              adc     ##0xbfff
              rts

;;; slopeT: C = tantoangle16(n * 2048 / d), n in C, d in X, 0 <= n <= d,
;;; 1 <= d <= 16384. The division does not restore: the remainder r stays
;;; in -d..d-1, so 2r fits in 16 bits. A step is r = 2r - d for r >= 0 and
;;; 2r + d for r < 0, and the quotient bit is 1 when the new r >= 0. After
;;; asl the carry is the sign of r, so sbc and adc of d - 1 (PA_DM) give
;;; -d and +d with no clc or sec. The first 2 bits set X; the code keeps
;;; the bits of each group of 3 in its branches and adds them to X (the
;;; quotient * 4) at the end of the group; a stop bit leaves X after the
;;; last group.
slopeT:       dex
              stx     dp:.tiny PA_DM
              cmp     dp:.tiny PA_DM        ; n <= d - 1
              beq     1$
              bcc     1$
              lda     ##0x2000              ; n == d: tantoangle16 of SLOPERANGE
              rts
1$:           asl     a                     ; the first 2 bits, from r = n
              sbc     dp:.tiny PA_DM
              bmi     3$
              asl     a                     ; 1
              sbc     dp:.tiny PA_DM
              bmi     2$
              ldx     ##0x8c                ; 11: the stop bit and 3 * 4
              bra     stepP
2$:           ldx     ##0x88                ; 10
              bra     stepM
3$:           asl     a                     ; 0
              adc     dp:.tiny PA_DM
              bmi     4$
              ldx     ##0x84                ; 01
              bra     stepP
4$:           ldx     ##0x80                ; 00
              bra     stepM
slopeDone:    lda     abs:.near (tantoangleTable+2),x ; X = the quotient * 4
              rts

;;; A group of 3 bits. At loopP r >= 0, at loopM r < 0, and the carry is
;;; the stop bit. Each of the 8 ends adds its 3 bits to X.
loopM:        bcs     slopeDone
stepM:        asl     a                     ; r < 0: r = 2r + d
              adc     dp:.tiny PA_DM
              bpl     gr1
gr0:          asl     a
              adc     dp:.tiny PA_DM
              bmi     gr00
              asl     a                     ; 01
              sbc     dp:.tiny PA_DM
              bmi     gr010
              tay                           ; 011
              txa
              asl     a
              asl     a
              asl     a
              ora     ##(3 << 2)
              tax
              tya
              bra     loopP
gr010:        tay
              txa
              asl     a
              asl     a
              asl     a
              ora     ##(2 << 2)
              tax
              tya
              bra     loopM
gr00:         asl     a
              adc     dp:.tiny PA_DM
              bmi     gr000
              tay                           ; 001
              txa
              asl     a
              asl     a
              asl     a
              ora     ##(1 << 2)
              tax
              tya
              bra     loopP
gr000:        tay
              txa
              asl     a
              asl     a
              asl     a
              tax
              tya
              bra     loopM
loopP:        bcs     slopeDone
stepP:        asl     a                     ; r >= 0: r = 2r - d
              sbc     dp:.tiny PA_DM
              bmi     gr0
gr1:          asl     a
              sbc     dp:.tiny PA_DM
              bmi     gr10
              asl     a                     ; 11
              sbc     dp:.tiny PA_DM
              bmi     gr110
              tay                           ; 111
              txa
              asl     a
              asl     a
              asl     a
              ora     ##(7 << 2)
              tax
              tya
              bra     loopP
gr110:        tay
              txa
              asl     a
              asl     a
              asl     a
              ora     ##(6 << 2)
              tax
              tya
              jmp     .kbank loopM
gr10:         asl     a
              adc     dp:.tiny PA_DM
              bmi     gr100
              tay                           ; 101
              txa
              asl     a
              asl     a
              asl     a
              ora     ##(5 << 2)
              tax
              tya
              bra     loopP
gr100:        tay
              txa
              asl     a
              asl     a
              asl     a
              ora     ##(4 << 2)
              tax
              tya
              jmp     .kbank loopM

;;; (Room of the cold pointOld and slopeOld, which went to coldcode: the
;;; code after this in section bspcode keeps its cache slots.)
PA_PAD:       .space  PA_PADN

;;; pointOld: pointAngle for x in X and y in Y from the view, not both in
;;; -16384..16384 (only when the coordinates wrap), as in r_draw.c. Cold
;;; code: jsl, rtl (so the hot code of the BSP stays in place).
              .section coldcode, text
pointOld:     txa
              bpl     2$
              brl     30$

              ;; x >= 0
2$:           stx     dp:.tiny PA_DEN
              tya
              bmi     20$
              PASLT                         ; y >= 0: y < x?
              bpl     10$
              tya                           ; octant 0: t
              jsr     .kbank slopeOld
              rtl
10$:          sty     dp:.tiny PA_DEN       ; octant 1: ANG90_16 - 1 - t
              txa
              jsr     .kbank slopeOld
              eor     ##0xffff
              sec
              adc     ##0x3fff
              rtl
20$:          eor     ##0xffff              ; y < 0: y = -y
              inc     a
              tay
              PASLT
              bpl     21$
              tya                           ; octant 8: -t
              jsr     .kbank slopeOld
              eor     ##0xffff
              inc     a
              rtl
21$:          sty     dp:.tiny PA_DEN       ; octant 7: ANG270_16 + t
              txa
              jsr     .kbank slopeOld
              clc
              adc     ##0xc000
              rtl

              ;; x < 0: x = -x
30$:          eor     ##0xffff
              inc     a
              tax
              sta     dp:.tiny PA_DEN
              tya
              bmi     40$
              PASLT                         ; y >= 0: y < x?
              bpl     31$
              tya                           ; octant 3: ANG180_16 - 1 - t
              jsr     .kbank slopeOld
              eor     ##0xffff
              sec
              adc     ##0x7fff
              rtl
31$:          sty     dp:.tiny PA_DEN       ; octant 2: ANG90_16 + t
              txa
              jsr     .kbank slopeOld
              clc
              adc     ##0x4000
              rtl
40$:          eor     ##0xffff              ; y < 0: y = -y
              inc     a
              tay
              PASLT
              bpl     41$
              tya                           ; octant 4: ANG180_16 + t
              jsr     .kbank slopeOld
              clc
              adc     ##0x8000
              rtl
41$:          sty     dp:.tiny PA_DEN       ; octant 5: ANG270_16 - 1 - t
              txa
              jsr     .kbank slopeOld
              eor     ##0xffff
              sec
              adc     ##0xbfff
              rtl

;;; slopeOld: C = tantoangle16(SlopeDiv16(n, d)), n in C, d in _Dp[4-5].
;;; For n < d the quotient n * 2048 / d has 11 bits: long division.
slopeOld:     ldx     dp:.tiny PA_DEN
              beq     2$                    ; d == 0
              cmp     dp:.tiny PA_DEN
              bcc     10$
              beq     2$                    ; n == d
              brl     80$                   ; n > d: full division
2$:           lda     ##SLOPERANGE
              brl     90$

10$:          ldx     ##0x0020              ; the quotient, after a stop bit that
11$:          asl     a                     ;   leaves X after 11 bits: r = 2r (17
              bcs     12$                   ;   bits), r -= d with a 1 bit when r >= d
              cmp     dp:.tiny PA_DEN
              bcc     13$
12$:          sbc     dp:.tiny PA_DEN       ; carry is set here
              sec
13$:          tay                           ; (r)
              txa
              rol     a                     ; the quotient bit; C = the stop bit
              tax
              tya
              bcc     11$
              txa
90$:          asl     a                     ; tantoangle16Table[t * 2]
              asl     a
              tax
              lda     abs:.near (tantoangleTable+2),x
              rts

              ;; n > d (only when the coordinates wrap): the C code in full
80$:          tay
              xba
              and     ##0x00ff
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              sta     dp:.tiny (_Dp+2)      ; n << 11, high word
              tya
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sta     dp:.tiny _Dp
              stz     dp:.tiny (_Dp+6)
              jsl     long:_UDivMod32
              cmp     ##(SLOPERANGE + 1)    ; (uint16_t) quotient, clamped
              bcc     90$
              lda     ##SLOPERANGE
              bra     90$

;;; ---------------------------------------------------------------------------
;;; fixed_t R_ScaleFromGlobalAngle(int16_t x)       In: C. Out: X:C.
;;; fixed_t R_FixedApproxDiv(fixed_t a, fixed_t b)  a in SG_NUM, b in SG_DEN.
;;; The functions of r_draw.c, with the same results. (R_PointToDist went:
;;; R_StoreWallRange of src/iigs/r_wall65.s finds the distance of a wall
;;; from the view as a dot product.)
;;; ---------------------------------------------------------------------------
              .extern xtoviewangleTable, viewangle16, rw_normalangle, rw_distance
              .extern finesineapprox, finecosineapprox, _Mul32, _Mul16, _UDivMod32
              .extern finesineTable_part_1
              .extern FixedReciprocalSmall, FixedReciprocalBig, FixedMul3232, FixedMul3216


              .section znear, bss
SG_B:         .space  2
SG_NUM:       .space  4
SG_DEN:       .space  4
PD_DX:        .space  4
PD_DY:        .space  4

;;; C = A >> 3, arithmetic
ASR3          .macro
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              .endm

              .section coldcode, text     ; (only for the rare scales of
              .public R_ScaleFromGlobalAngle ;   scaleSlow of src/iigs/r_wall65.s)
R_ScaleFromGlobalAngle:
              asl     a                     ; anglea = ANG90_16 + xtoviewangle[x]
              tax
              lda     abs:.near xtoviewangleTable,x
              clc
              adc     ##0x4000
              pha
              clc                           ; angleb = anglea + viewangle16 - rw_normalangle
              adc     .near viewangle16
              sec
              sbc     .near rw_normalangle
              sta     .near SG_B

              ;; den = rw_distance * finesineapprox(anglea >> 3); anglea is
              ;; 0x1ff8..0x6008, so the sine is a table value 0..65535
              pla
              ASR3
              jsl     long:sineLow
              tax
              lda     .near rw_distance
              jsl     long:_Mul16           ; X:C = unsigned product
              ldy     .near rw_distance
              bpl     1$
              sta     .near SG_DEN          ; rw_distance < 0: minus sine << 16
              stx     .near (SG_DEN+2)
              lda     .near (SG_DEN+2)
              sec
              sbc     dp:.tiny (_Dp+4)
              tax
              lda     .near SG_DEN
1$:           sta     .near SG_DEN
              stx     .near (SG_DEN+2)

              ;; num = PROJECTIONY * finesineapprox(angleb >> 3); angleb >> 3 is
              ;; -4096..4095, so the sine is a table value 0..65535
              lda     .near SG_B
              ASR3
              jsl     long:sineLow
              ldx     ##CONST_PROJECTIONY
              jsl     long:_Mul16
              sta     .near SG_NUM
              stx     .near (SG_NUM+2)

              ;; den > num >> 16 ?
              txa                           ; num >> 16, sign extended
              and     ##0x8000
              beq     2$
              lda     ##0xffff
2$:           sta     dp:.tiny _Dp          ; high word of num >> 16
              lda     .near (SG_NUM+2)      ; (num >> 16) - den < 0: den > num >> 16
              cmp     .near SG_DEN
              lda     dp:.tiny _Dp
              sbc     .near (SG_DEN+2)
              bvc     3$
              eor     ##0x8000
3$:           bmi     4$
              lda     ##0                   ; 64 * FRACUNIT
              ldx     ##64
              rtl

4$:           jsl     long:approxDiv        ; num / den
              stx     dp:.tiny _Dp          ; > 64 * FRACUNIT: 64 * FRACUNIT
              cmp     ##1
              lda     dp:.tiny _Dp
              sbc     ##64
              bvc     5$
              eor     ##0x8000
5$:           bmi     6$
              lda     ##0
              ldx     ##64
              rtl
6$:           txa                           ; < 256: 256
              bmi     7$
              bne     8$
              lda     .near SG_NUM
              cmp     ##256
              bcs     8$
7$:           lda     ##256
              ldx     ##0
              rtl
8$:           lda     .near SG_NUM
              ldx     .near (SG_NUM+2)
              rtl

;;; sineLow: C = finesineapprox(C) for C < 4096, which is a table value
;;; (finesineTable_part_1 of tables.c, read as the C code reads
;;; it, also for C < 0); _Dp[4-5] = C.
sineLow:      cmp     ##2048                ; C < 2048, signed: [C]
              bmi     1$
              eor     ##4095                ; 2048 <= C < 4096: [4095 - C]
1$:           asl     a
              tax
              lda     .near finesineTable_part_1,x
              sta     dp:.tiny (_Dp+4)
              rtl

;;; fixed_t FixedApproxDiv(fixed_t a, fixed_t b)  In: X:C = a, _Dp[0-3] = b.
              .section bspcode, text
              .public FixedApproxDiv
FixedApproxDiv:
              sta     .near SG_NUM
              stx     .near (SG_NUM+2)
              lda     dp:.tiny _Dp
              sta     .near SG_DEN
              lda     dp:.tiny (_Dp+2)
              sta     .near (SG_DEN+2)
              ;; fall into approxDiv

;;; approxDiv: X:C = SG_NUM = FixedApproxDiv(SG_NUM, SG_DEN):
;;;   b <= 0xffff ? FixedMul3232(a, FixedReciprocalSmall(b))
;;;               : FixedMul3216(a, FixedReciprocalBig(b))
;;; (a signed compare in C, so a negative b is small)
approxDiv:    lda     .near (SG_DEN+2)
              beq     5$
              bpl     10$
5$:           lda     .near SG_DEN
              jsl     long:FixedReciprocalSmall
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near SG_NUM
              ldx     .near (SG_NUM+2)
              jsl     long:FixedMul3232
              bra     20$
10$:          lda     .near SG_DEN
              ldx     .near (SG_DEN+2)
              jsl     long:FixedReciprocalBig
              sta     dp:.tiny _Dp
              lda     .near SG_NUM
              ldx     .near (SG_NUM+2)
              jsl     long:FixedMul3216
20$:          sta     .near SG_NUM
              stx     .near (SG_NUM+2)
              rtl

;;; ---------------------------------------------------------------------------
;;; subsector_t __far* R_PointInSubsector(fixed_t x, fixed_t y)
;;;   In: X:C = x, _Dp[0-3] = y. Out: X:C.
;;; The function of r_draw.c, with the same results, and its R_PointOnSide.
;;; ---------------------------------------------------------------------------
              .extern nodes, numnodes, _g_subsectors
              .extern MA, MB, MR, umul16, umul16lo

              .section ztiny, bss
PO_NODE:      .space  4

              .section znear, bss
PO_X:         .space  4
PO_Y:         .space  4
PO_YP:        .space  4               ; y - (node->y << FRACBITS)
PO_XP:        .space  4
PO_NX:        .space  2
PO_NY:        .space  2
PO_NDX:       .space  2
PO_NDY:       .space  2
PO_L:         .space  4
PI_PREVX:     .space  4
PI_PREVY:     .space  4
PI_PREVR:     .space  4
PI_NUM:       .space  2
SM_AH:        .space  2               ; shiftMul
SM_L:         .space  2
SM_H:         .space  2
PO_PADN       .equ    0xd6            ; see PO_PAD

;;; C = A < operand, signed: N flag. Destroys A.
POSLT         .macro  op
              sec
              sbc     \op
              bvc     1$
              eor     ##0x8000
1$:
              .endm

              .section bspcode, text
;;; (Room of loadNode and pointOnSide, now inside walk: shiftMul and the
;;; code after it in section bspcode keep their cache slots.)
PO_PAD:       .space  PO_PADN

;;; shiftMul: X:C = (v >> 8) * C (low 32 bits), v = the fixed_t at near X,
;;; C signed, as _Mul32 of those values: with AL = bits 8..23 of v and
;;; AH = byte 3 of v (signed), AL * C + (AH * C + AL * (C < 0 ? -1 : 0)) << 16.
              .public shiftMul
shiftMul:     sta     dp:.tiny MB
              lda     abs:1,x               ; AL
              sta     dp:.tiny MA
              lda     abs:2,x               ; AH in the high byte
              sta     .near SM_AH
              jsl     long:umul16           ; MR = AL * C, unsigned
              lda     dp:.tiny MR
              sta     .near SM_L
              lda     dp:.tiny (MR+2)
              ldx     dp:.tiny MB           ; C < 0: minus AL << 16
              bpl     1$
              sec
              sbc     dp:.tiny MA
1$:           sta     .near SM_H
              lda     .near SM_AH           ; AH, sign extended
              xba
              and     ##0x00ff
              beq     3$
              cmp     ##0x0080
              bcc     2$
              ora     ##0xff00
2$:           sta     dp:.tiny MA           ; + low 16 bits of AH * C
              jsl     long:umul16lo
              clc
              adc     .near SM_H
              sta     .near SM_H
3$:           lda     .near SM_L
              ldx     .near SM_H
              rtl

              .section znear, bss
              .public sgrid, sgridX, sgridY, sgridCols, sgridRows
sgrid:        .space  4               ; the lump SGRID of the map (0: none)
sgridX:       .space  2               ; its origin, columns and rows
sgridY:       .space  2
sgridCols:    .space  2
sgridRows:    .space  2

              .section logicfar, text     ; (slots $6700-, away from the logic)
              .public R_PointInSubsector, R_PointInSubsectorNew
R_PointInSubsector:
              cmp     .near PI_PREVX
              bne     R_PointInSubsectorNew
              cpx     .near (PI_PREVX+2)
              bne     R_PointInSubsectorNew
              ldy     dp:.tiny _Dp
              cpy     .near PI_PREVY
              bne     R_PointInSubsectorNew
              ldy     dp:.tiny (_Dp+2)
              cpy     .near (PI_PREVY+2)
              bne     R_PointInSubsectorNew
              lda     .near PI_PREVR        ; the same point again
              ldx     .near (PI_PREVR+2)
              rtl

;;; R_PointInSubsectorNew: the same with no look at the last point (the
;;; level setup: a new map).
R_PointInSubsectorNew:
              sta     .near PI_PREVX
              sta     .near PO_X
              stx     .near (PI_PREVX+2)
              stx     .near (PO_X+2)
              lda     dp:.tiny _Dp
              sta     .near PI_PREVY
              sta     .near PO_Y
              lda     dp:.tiny (_Dp+2)
              sta     .near (PI_PREVY+2)
              sta     .near (PO_Y+2)
              lda     .near numnodes        ; no nodes: the only subsector
              bne     2$
              lda     .near _g_subsectors
              ldx     .near (_g_subsectors+2)
              bra     9$
2$:           jsr     .kbank gridStart      ; the walk starts at the node of
                                            ;   the grid cell of the point
#if defined PISCHECK
              jsr     .kbank walk
              pha
              lda     .near numnodes        ; the check build: the walk from
              dec     a                     ;   the root gives the same leaf
              jsr     .kbank walk
              cmp     1,s
              beq     5$
              lda     ##.word0 errGrid
              sta     dp:.tiny _Dp
              lda     ##.word2 errGrid
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
5$:           pla
#else
              jsr     .kbank walk
#endif
              and     ##0x7fff              ; &_g_subsectors[nodenum & ~NF_SUBSECTOR]
              asl     a
              asl     a
              asl     a                     ; * SIZEOF_SUB (8)
              clc
              adc     .near _g_subsectors
              tay
              lda     .near (_g_subsectors+2)
              adc     ##0
              tax
              tya
9$:           sta     .near PI_PREVR
              stx     .near (PI_PREVR+2)
              rtl

#if defined PISCHECK
              .extern I_Error
errGrid:      .asciz  "R_PointInSubsector: the grid start gives another subsector"
#endif

;;; gridStart: C = the node where the walk of the point PO_X, PO_Y starts:
;;; the node of its cell in the subsector grid of the map (the lump SGRID
;;; of tools/sgrid.py: 64 x 64 map units, a row offset table from byte
;;; 10), else the root. Destroys Y; the grid address in PO_NODE.
gridStart:    lda     .near (sgrid+2)       ; no grid: the root
              beq     9$
              sta     dp:.tiny (PO_NODE+2)
              lda     .near sgrid
              sta     dp:.tiny PO_NODE
              lda     .near (PO_X+2)        ; the column: (ix - orgx) >> 6
              sec
              sbc     .near sgridX
              bmi     9$
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              cmp     .near sgridCols
              bcs     9$
              asl     a
              sta     .near PI_NUM
              lda     .near (PO_Y+2)        ; the row
              sec
              sbc     .near sgridY
              bmi     9$
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              cmp     .near sgridRows
              bcs     9$
              asl     a                     ; (carry clear)
              adc     ##10
              tay
              lda     [.tiny PO_NODE],y     ; the offset of the row
              clc
              adc     .near PI_NUM
              tay
              lda     [.tiny PO_NODE],y     ; the node of the cell
              rts
9$:           lda     .near numnodes        ; the root
              dec     a
              rts

;;; walk: C = the leaf (NF_SUBSECTOR | subsector) of the point PO_X, PO_Y
;;; from node C down: R_PointOnSide at each node, with the node read in
;;; place (x, y, dx, dy at +0, +2, +4, +6 of PI_NUM). Destroys X, Y,
;;; _Dp[0-3].
walk:         tax
              lda     .near nodes
              sta     dp:.tiny PO_NODE
              lda     .near (nodes+2)
              sta     dp:.tiny (PO_NODE+2)
              lda     .near PO_X            ; the fractions of x - (node->x <<
              sta     .near PO_XP           ;   FRACBITS), y - (node->y <<
              lda     .near PO_Y            ;   FRACBITS) for shiftMul
              sta     .near PO_YP
              txa
1$:           bit     ##CONST_NF_SUBSECTOR
              beq     2$
              rts
2$:           asl     a                     ; the node: nodenum * 28
              asl     a
              sta     dp:.tiny _Dp
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny _Dp
              sta     .near PI_NUM
              tay
              iny
              iny
              iny
              iny
              lda     [.tiny PO_NODE],y     ; dx
              beq     30$
              tax                           ; X = dx
              iny
              iny
              lda     [.tiny PO_NODE],y     ; dy
              beq     40$
              sta     .near PO_NDY
              ldy     .near PI_NUM          ; x -= node->x << FRACBITS
              lda     .near (PO_X+2)
              sec
              sbc     [.tiny PO_NODE],y
              sta     .near (PO_XP+2)
              iny                           ; y -= node->y << FRACBITS
              iny
              lda     .near (PO_Y+2)
              sec
              sbc     [.tiny PO_NODE],y
              sta     .near (PO_YP+2)
              stx     .near PO_NDX          ; the sign bits decide: (dy ^ dx ^
              eor     .near (PO_XP+2)       ;   ix ^ iy) < 0
              eor     .near PO_NDX
              eor     .near PO_NDY
              bpl     50$
              lda     .near PO_NDY          ; (dy ^ ix) < 0: 1
              eor     .near (PO_XP+2)
              bmi     91$
              bra     90$

              ;; dx == 0: ix <= node->x ? dy > 0 : dy < 0
30$:          iny
              iny
              lda     [.tiny PO_NODE],y     ; dy
              tax
              ldy     .near PI_NUM
              lda     [.tiny PO_NODE],y     ; node->x
              POSLT   .near (PO_X+2)        ; node->x < ix
              bmi     32$
              txa
              bmi     90$
              beq     90$
              bra     91$
32$:          txa
              bmi     91$
              bra     90$

              ;; dy == 0: iy <= node->y ? dx < 0 : dx > 0
40$:          ldy     .near PI_NUM
              iny
              iny
              lda     [.tiny PO_NODE],y     ; node->y
              POSLT   .near (PO_Y+2)        ; node->y < iy
              bmi     42$
              txa
              bmi     91$
              bra     90$
42$:          txa
              bmi     90$
              bra     91$

              ;; (y >> 8) * dx >= (x >> 8) * dy, low 32 bits as in C
50$:          ldx     ##.near PO_YP
              lda     .near PO_NDX
              jsl     long:shiftMul
              sta     .near PO_L
              stx     .near (PO_L+2)
              ldx     ##.near PO_XP
              lda     .near PO_NDY
              jsl     long:shiftMul
              sta     dp:.tiny _Dp          ; L - R >= 0: 1
              stx     dp:.tiny (_Dp+2)
              lda     .near PO_L
              cmp     dp:.tiny _Dp
              lda     .near (PO_L+2)
              sbc     dp:.tiny (_Dp+2)
              bvc     51$
              eor     ##0x8000
51$:          bmi     90$

91$:          lda     .near PI_NUM          ; side 1: children[1]
              clc
              adc     ##(OFS_NODE_CHILDREN + 2)
              tay
              lda     [.tiny PO_NODE],y
              brl     1$
90$:          lda     .near PI_NUM          ; side 0: children[0]
              clc
              adc     ##OFS_NODE_CHILDREN
              tay
              lda     [.tiny PO_NODE],y
              brl     1$

;;; ---------------------------------------------------------------------------
;;; angle_t R_PointToAngle3(fixed_t x, fixed_t y)
;;; In: X:C = x, _Dp[0-3] = y. Out: X:C.
;;; The C version of r_draw.c: the game logic uses it, so the
;;; results are the same. SlopeDiv(num, den) = (uint16_t)((num << 3) /
;;; (den >> 8)), at most SLOPERANGE. When the quotient is below 4096 (always
;;; when num <= den), 12 division steps give it; else _UDivMod32 does.
;;; ---------------------------------------------------------------------------
              .section znear, bss
P3_X:         .space  4               ; |x|
P3_D:         .space  4               ; den >> 8
P3_OCT:       .space  2               ; 4 * (4 * (x < 0) + 2 * (y < 0) + (x <= y))

P3_NB         .equ    _Dp+4           ; the low 12 bits of num << 3, at the top
P3_Q          .equ    _Dp+6           ; the quotient, after a stop bit

              .section farcode, text
              .public R_PointToAngle3
R_PointToAngle3:
              sta     .near P3_X
              stx     .near (P3_X+2)
              ora     .near (P3_X+2)        ; x == 0 && y == 0: 0
              ora     dp:.tiny _Dp
              ora     dp:.tiny (_Dp+2)
              bne     1$
              tax
              rtl
1$:           ldy     ##0
              lda     .near (P3_X+2)
              bpl     2$
              ldy     ##16
              lda     ##0                   ; x = -x
              sec
              sbc     .near P3_X
              sta     .near P3_X
              lda     ##0
              sbc     .near (P3_X+2)
              sta     .near (P3_X+2)
2$:           lda     dp:.tiny (_Dp+2)
              bpl     3$
              tya
              ora     ##8
              tay
              lda     ##0                   ; y = -y
              sec
              sbc     dp:.tiny _Dp
              sta     dp:.tiny _Dp
              lda     ##0
              sbc     dp:.tiny (_Dp+2)
              sta     dp:.tiny (_Dp+2)
3$:           lda     dp:.tiny _Dp          ; x > y (signed): SlopeDiv(y, x)
              cmp     .near P3_X
              lda     dp:.tiny (_Dp+2)
              sbc     .near (P3_X+2)
              bvc     4$
              eor     ##0x8000
4$:           bpl     5$
              sty     .near P3_OCT
              lda     .near (P3_X+1)        ; den >> 8: bytes 1..3 of x
              sta     .near P3_D
              lda     .near (P3_X+3)
              and     ##0x00ff
              sta     .near (P3_D+2)
              bra     6$                    ; num = y
5$:           tya                           ; x <= y: SlopeDiv(x, y)
              ora     ##4
              sta     .near P3_OCT
              lda     dp:.tiny (_Dp+1)      ; den >> 8: bytes 1..3 of y
              sta     .near P3_D
              lda     dp:.tiny (_Dp+3)
              and     ##0x00ff
              sta     .near (P3_D+2)
              lda     .near P3_X            ; num = x
              sta     dp:.tiny _Dp
              lda     .near (P3_X+2)
              sta     dp:.tiny (_Dp+2)
6$:           jsr     .kbank slopeDiv3
              asl     a                     ; Y = the offset of tantoangleTable[q]
              asl     a
              tay
              lda     .near P3_OCT
              lsr     a
              tax
              jmp     (.kbank octJump3,x)

octJump3:     .word   .word0 oct0_3         ; x >= 0, y >= 0, x > y: T
              .word   .word0 oct1_3         ;                 x <= y: ANG90 - 1 - T
              .word   .word0 oct8_3         ; x >= 0, y < 0,  x > y: -T
              .word   .word0 oct7_3         ;                 x <= y: ANG270 + T
              .word   .word0 oct3_3         ; x < 0, y >= 0,  x > y: ANG180 - 1 - T
              .word   .word0 oct2_3         ;                 x <= y: ANG90 + T
              .word   .word0 oct4_3         ; x < 0, y < 0,   x > y: ANG180 + T
              .word   .word0 oct5_3         ;                 x <= y: ANG270 - 1 - T

oct0_3:       lda     abs:.near (tantoangleTable+2),y
              tax
              lda     abs:.near tantoangleTable,y
              rtl
oct1_3:       lda     ##0x3fff
              bra     minusT3
oct8_3:       lda     ##0                   ; 0 - T
              sec
              sbc     abs:.near tantoangleTable,y
              tax
              lda     ##0
              sbc     abs:.near (tantoangleTable+2),y
              txy
              tax
              tya
              rtl
oct7_3:       lda     ##0xc000
              bra     plusT3
oct3_3:       lda     ##0x7fff
              bra     minusT3
oct2_3:       lda     ##0x4000
              bra     plusT3
oct4_3:       lda     ##0x8000
              bra     plusT3
oct5_3:       lda     ##0xbfff
minusT3:      sec                           ; C:0xffff - T: the low word has no borrow
              sbc     abs:.near (tantoangleTable+2),y
              tax
              lda     abs:.near tantoangleTable,y
              eor     ##0xffff
              rtl
plusT3:       clc                           ; C:0 + T
              adc     abs:.near (tantoangleTable+2),y
              tax
              lda     abs:.near tantoangleTable,y
              rtl

;;; slopeDiv3: C = SlopeDiv of num (_Dp[0-3]) and P3_D (den >> 8). N = num
;;; << 3 (32 bits), R = N >> 12 = (num >> 9) & 0xfffff; the steps keep R in
;;; X (high) and Y (low).
slopeDiv3:    lda     .near P3_D
              ora     .near (P3_D+2)
              bne     1$
              lda     ##SLOPERANGE          ; den >> 8 == 0
              rts
1$:           lda     dp:.tiny _Dp          ; the low 12 bits of N at the top: num << 7
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sta     dp:.tiny P3_NB
              lda     dp:.tiny (_Dp+3)      ; R low: bits 9..24 of num
              lsr     a
              lda     dp:.tiny (_Dp+1)
              ror     a
              tay
              lda     dp:.tiny (_Dp+3)      ; R high: bits 25..28 of num
              and     ##0x00ff
              lsr     a
              and     ##0x000f
              tax
              cmp     .near (P3_D+2)        ; R < D: the quotient has 12 bits
              bcc     2$
              bne     20$
              cpy     .near P3_D
              bcs     20$
2$:           lda     ##0x0010              ; a stop bit that leaves after 12 bits
              sta     dp:.tiny P3_Q
10$:          asl     dp:.tiny P3_NB        ; R = R << 1 | the next bit of N
              tya
              rol     a
              tay
              txa
              rol     a
              tax
              cmp     .near (P3_D+2)        ; R >= D: subtract, quotient bit 1
              bcc     12$
              bne     11$
              cpy     .near P3_D
              bcc     12$
11$:          tya
              sbc     .near P3_D            ; (carry set)
              tay
              txa
              sbc     .near (P3_D+2)
              tax
              sec
12$:          rol     dp:.tiny P3_Q
              bcc     10$
              lda     dp:.tiny P3_Q
              bra     30$
20$:          tya                           ; a bigger quotient: _UDivMod32 of
              lsr     a                     ;   N = R << 12 | the low bits of N
              lsr     a
              lsr     a
              lsr     a
              sta     dp:.tiny (_Dp+2)      ; N high = R >> 4
              txa
              xba
              asl     a
              asl     a
              asl     a
              asl     a
              ora     dp:.tiny (_Dp+2)
              sta     dp:.tiny (_Dp+2)
              tya                           ; N low
              and     ##0x000f
              xba
              asl     a
              asl     a
              asl     a
              asl     a
              sta     dp:.tiny _Dp
              lda     dp:.tiny P3_NB
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              ora     dp:.tiny _Dp
              sta     dp:.tiny _Dp
              lda     .near P3_D
              sta     dp:.tiny (_Dp+4)
              lda     .near (P3_D+2)
              sta     dp:.tiny (_Dp+6)
              jsl     long:_UDivMod32
30$:          cmp     ##(SLOPERANGE + 1)    ; (uint16_t) quotient, at most SLOPERANGE
              bcc     31$
              lda     ##SLOPERANGE
31$:          rts

;;; The angle of each slope (2049 slopes 0-1: y * 2048 / x), for
;;; R_PointToAngle (tantoangleTable of r_draw.c).
              .section cnear, rodata
              .public tantoangleTable
tantoangleTable:
              .long   0x00000000, 0x000517cc, 0x000a2f98, 0x000f4763
              .long   0x00145f2e, 0x001976f9, 0x001e8ec2, 0x0023a68b
              .long   0x0028be53, 0x002dd619, 0x0032edde, 0x003805a1
              .long   0x003d1d63, 0x00423523, 0x00474ce0, 0x004c649c
              .long   0x00517c55, 0x0056940b, 0x005babbf, 0x0060c370
              .long   0x0065db1e, 0x006af2c8, 0x00700a70, 0x00752213
              .long   0x007a39b4, 0x007f5150, 0x008468e9, 0x0089807d
              .long   0x008e980d, 0x0093af98, 0x0098c71f, 0x009ddea1
              .long   0x00a2f61e, 0x00a80d96, 0x00ad2509, 0x00b23c77
              .long   0x00b753de, 0x00bc6b41, 0x00c1829d, 0x00c699f3
              .long   0x00cbb143, 0x00d0c88d, 0x00d5dfd0, 0x00daf70c
              .long   0x00e00e42, 0x00e52570, 0x00ea3c98, 0x00ef53b8
              .long   0x00f46ad1, 0x00f981e2, 0x00fe98eb, 0x0103afec
              .long   0x0108c6e6, 0x010dddd6, 0x0112f4be, 0x01180b9e
              .long   0x011d2276, 0x01223944, 0x0127500a, 0x012c66c6
              .long   0x01317d78, 0x01369420, 0x013baac0, 0x0140c156
              .long   0x0145d7e2, 0x014aee62, 0x015004da, 0x01551b46
              .long   0x015a31a8, 0x015f4800, 0x01645e4c, 0x0169748c
              .long   0x016e8ac2, 0x0173a0ec, 0x0178b70c, 0x017dcd1e
              .long   0x0182e326, 0x0187f920, 0x018d0f10, 0x019224f2
              .long   0x01973ac8, 0x019c5090, 0x01a1664e, 0x01a67bfc
              .long   0x01ab919e, 0x01b0a734, 0x01b5bcbc, 0x01bad234
              .long   0x01bfe7a0, 0x01c4fcfe, 0x01ca124e, 0x01cf2790
              .long   0x01d43cc4, 0x01d951e8, 0x01de66fe, 0x01e37c04
              .long   0x01e890fc, 0x01eda5e6, 0x01f2babe, 0x01f7cf88
              .long   0x01fce442, 0x0201f8ec, 0x02070d88, 0x020c2210
              .long   0x0211368c, 0x02164af4, 0x021b5f4c, 0x02207394
              .long   0x022587cc, 0x022a9bf4, 0x022fb008, 0x0234c40c
              .long   0x0239d7fc, 0x023eebdc, 0x0243ffa8, 0x02491364
              .long   0x024e2710, 0x02533aa8, 0x02584e2c, 0x025d61a0
              .long   0x02627500, 0x0267884c, 0x026c9b84, 0x0271aeac
              .long   0x0276c1bc, 0x027bd4bc, 0x0280e7a8, 0x0285fa80
              .long   0x028b0d44, 0x02901ff4, 0x0295328c, 0x029a4514
              .long   0x029f5784, 0x02a469e4, 0x02a97c28, 0x02ae8e5c
              .long   0x02b3a078, 0x02b8b280, 0x02bdc474, 0x02c2d650
              .long   0x02c7e818, 0x02ccf9c8, 0x02d20b64, 0x02d71ce8
              .long   0x02dc2e54, 0x02e13fac, 0x02e650ec, 0x02eb6214
              .long   0x02f07324, 0x02f58420, 0x02fa9504, 0x02ffa5cc
              .long   0x0304b680, 0x0309c71c, 0x030ed7a0, 0x0313e80c
              .long   0x0318f860, 0x031e0898, 0x032318bc, 0x032828c4
              .long   0x032d38b4, 0x0332488c, 0x03375848, 0x033c67ec
              .long   0x03417774, 0x034686e8, 0x034b963c, 0x0350a578
              .long   0x0355b49c, 0x035ac3a4, 0x035fd290, 0x0364e164
              .long   0x0369f01c, 0x036efeb8, 0x03740d3c, 0x03791ba0
              .long   0x037e29ec, 0x0383381c, 0x03884630, 0x038d5428
              .long   0x03926200, 0x03976fc0, 0x039c7d64, 0x03a18aec
              .long   0x03a69854, 0x03aba5a0, 0x03b0b2d0, 0x03b5bfe4
              .long   0x03baccdc, 0x03bfd9b4, 0x03c4e66c, 0x03c9f30c
              .long   0x03ceff88, 0x03d40bec, 0x03d9182c, 0x03de2454
              .long   0x03e33058, 0x03e83c40, 0x03ed4808, 0x03f253b4
              .long   0x03f75f3c, 0x03fc6aa8, 0x040175f8, 0x04068120
              .long   0x040b8c30, 0x04109718, 0x0415a1e8, 0x041aac98
              .long   0x041fb720, 0x0424c190, 0x0429cbd8, 0x042ed600
              .long   0x0433e010, 0x0438e9f8, 0x043df3c0, 0x0442fd68
              .long   0x044806e8, 0x044d1050, 0x04521990, 0x045722b0
              .long   0x045c2bb0, 0x04613488, 0x04663d40, 0x046b45d8
              .long   0x04704e48, 0x04755698, 0x047a5ec8, 0x047f66d8
              .long   0x04846ec0, 0x04897680, 0x048e7e20, 0x049385a0
              .long   0x04988cf8, 0x049d9430, 0x04a29b40, 0x04a7a228
              .long   0x04aca8f0, 0x04b1af98, 0x04b6b618, 0x04bbbc70
              .long   0x04c0c2a8, 0x04c5c8b8, 0x04cacea0, 0x04cfd468
              .long   0x04d4da08, 0x04d9df80, 0x04dee4d0, 0x04e3ea00
              .long   0x04e8ef08, 0x04edf3e8, 0x04f2f8a0, 0x04f7fd38
              .long   0x04fd01a8, 0x050205e8, 0x05070a08, 0x050c0e00
              .long   0x051111d8, 0x05161580, 0x051b1900, 0x05201c58
              .long   0x05251f88, 0x052a2298, 0x052f2578, 0x05342830
              .long   0x05392ac0, 0x053e2d28, 0x05432f68, 0x05483180
              .long   0x054d3370, 0x05523530, 0x055736c8, 0x055c3840
              .long   0x05613980, 0x05663aa0, 0x056b3b98, 0x05703c60
              .long   0x05753d00, 0x057a3d70, 0x057f3dc0, 0x05843de0
              .long   0x05893dd0, 0x058e3da0, 0x05933d40, 0x05983cb0
              .long   0x059d3bf8, 0x05a23b18, 0x05a73a08, 0x05ac38d0
              .long   0x05b13768, 0x05b635d8, 0x05bb3418, 0x05c03228
              .long   0x05c53010, 0x05ca2dd0, 0x05cf2b60, 0x05d428c0
              .long   0x05d925f8, 0x05de2300, 0x05e31fd8, 0x05e81c88
              .long   0x05ed1908, 0x05f21558, 0x05f71178, 0x05fc0d70
              .long   0x06010938, 0x060604d0, 0x060b0038, 0x060ffb78
              .long   0x0614f688, 0x0619f160, 0x061eec10, 0x0623e690
              .long   0x0628e0e8, 0x062ddb08, 0x0632d4f8, 0x0637ceb8
              .long   0x063cc850, 0x0641c1b0, 0x0646bae0, 0x064bb3e8
              .long   0x0650acb8, 0x0655a558, 0x065a9dc8, 0x065f9608
              .long   0x06648e18, 0x066985f8, 0x066e7da0, 0x06737520
              .long   0x06786c68, 0x067d6380, 0x06825a68, 0x06875118
              .long   0x068c4798, 0x06913df0, 0x06963408, 0x069b29f8
              .long   0x06a01fb0, 0x06a51538, 0x06aa0a88, 0x06aeffa8
              .long   0x06b3f498, 0x06b8e950, 0x06bdddd8, 0x06c2d228
              .long   0x06c7c648, 0x06ccba38, 0x06d1adf0, 0x06d6a170
              .long   0x06db94c0, 0x06e087d8, 0x06e57ac0, 0x06ea6d78
              .long   0x06ef5ff0, 0x06f45238, 0x06f94450, 0x06fe3630
              .long   0x070327d8, 0x07081948, 0x070d0a88, 0x0711fb90
              .long   0x0716ec60, 0x071bdd00, 0x0720cd68, 0x0725bd98
              .long   0x072aad90, 0x072f9d58, 0x07348ce8, 0x07397c38
              .long   0x073e6b58, 0x07435a40, 0x074848f8, 0x074d3770
              .long   0x075225b0, 0x075713c0, 0x075c0190, 0x0760ef30
              .long   0x0765dc98, 0x076ac9c0, 0x076fb6b8, 0x0774a370
              .long   0x07798ff8, 0x077e7c40, 0x07836850, 0x07885430
              .long   0x078d3fd0, 0x07922b38, 0x07971668, 0x079c0158
              .long   0x07a0ec18, 0x07a5d698, 0x07aac0e0, 0x07afaaf0
              .long   0x07b494c8, 0x07b97e60, 0x07be67c0, 0x07c350e8
              .long   0x07c839d8, 0x07cd2288, 0x07d20b00, 0x07d6f338
              .long   0x07dbdb38, 0x07e0c300, 0x07e5aa88, 0x07ea91d8
              .long   0x07ef78f0, 0x07f45fc8, 0x07f94660, 0x07fe2cc8
              .long   0x080312f0, 0x0807f8d0, 0x080cde80, 0x0811c3f0
              .long   0x0816a920, 0x081b8e20, 0x082072d0, 0x08255750
              .long   0x082a3b90, 0x082f1fa0, 0x08340360, 0x0838e6f0
              .long   0x083dca30, 0x0842ad40, 0x08479010, 0x084c72a0
              .long   0x08515500, 0x08563710, 0x085b18f0, 0x085ffa80
              .long   0x0864dbe0, 0x0869bd00, 0x086e9de0, 0x08737e80
              .long   0x08785ee0, 0x087d3f00, 0x08821ee0, 0x0886fe90
              .long   0x088bddf0, 0x0890bd10, 0x08959bf0, 0x089a7aa0
              .long   0x089f5900, 0x08a43720, 0x08a91510, 0x08adf2b0
              .long   0x08b2d010, 0x08b7ad40, 0x08bc8a20, 0x08c166c0
              .long   0x08c64320, 0x08cb1f40, 0x08cffb20, 0x08d4d6c0
              .long   0x08d9b220, 0x08de8d40, 0x08e36820, 0x08e842b0
              .long   0x08ed1d10, 0x08f1f720, 0x08f6d0f0, 0x08fbaa80
              .long   0x090083d0, 0x09055ce0, 0x090a35b0, 0x090f0e30
              .long   0x0913e680, 0x0918be80, 0x091d9640, 0x09226dc0
              .long   0x092744f0, 0x092c1bf0, 0x0930f2a0, 0x0935c910
              .long   0x093a9f30, 0x093f7520, 0x09444ac0, 0x09492020
              .long   0x094df540, 0x0952ca10, 0x09579eb0, 0x095c7300
              .long   0x09614700, 0x09661ad0, 0x096aee50, 0x096fc180
              .long   0x09749480, 0x09796730, 0x097e39a0, 0x09830bc0
              .long   0x0987dda0, 0x098caf40, 0x099180a0, 0x099651b0
              .long   0x099b2270, 0x099ff300, 0x09a4c340, 0x09a99330
              .long   0x09ae62e0, 0x09b33250, 0x09b80180, 0x09bcd050
              .long   0x09c19ef0, 0x09c66d40, 0x09cb3b50, 0x09d00910
              .long   0x09d4d690, 0x09d9a3c0, 0x09de70b0, 0x09e33d50
              .long   0x09e809b0, 0x09ecd5c0, 0x09f1a190, 0x09f66d20
              .long   0x09fb3860, 0x0a000350, 0x0a04ce00, 0x0a099860
              .long   0x0a0e6280, 0x0a132c50, 0x0a17f5e0, 0x0a1cbf20
              .long   0x0a218820, 0x0a2650d0, 0x0a2b1940, 0x0a2fe150
              .long   0x0a34a930, 0x0a3970c0, 0x0a3e3800, 0x0a42fef0
              .long   0x0a47c5a0, 0x0a4c8c00, 0x0a515220, 0x0a5617f0
              .long   0x0a5add80, 0x0a5fa2b0, 0x0a6467a0, 0x0a692c50
              .long   0x0a6df0b0, 0x0a72b4c0, 0x0a777880, 0x0a7c3c00
              .long   0x0a80ff30, 0x0a85c220, 0x0a8a84b0, 0x0a8f4700
              .long   0x0a940900, 0x0a98cac0, 0x0a9d8c30, 0x0aa24d50
              .long   0x0aa70e20, 0x0aabceb0, 0x0ab08ef0, 0x0ab54ee0
              .long   0x0aba0e80, 0x0abecde0, 0x0ac38ce0, 0x0ac84ba0
              .long   0x0acd0a10, 0x0ad1c840, 0x0ad68610, 0x0adb43a0
              .long   0x0ae000e0, 0x0ae4bdd0, 0x0ae97a80, 0x0aee36d0
              .long   0x0af2f2e0, 0x0af7ae90, 0x0afc6a00, 0x0b012520
              .long   0x0b05e000, 0x0b0a9a80, 0x0b0f54b0, 0x0b140ea0
              .long   0x0b18c840, 0x0b1d8180, 0x0b223a80, 0x0b26f330
              .long   0x0b2bab90, 0x0b3063a0, 0x0b351b70, 0x0b39d2e0
              .long   0x0b3e8a00, 0x0b4340e0, 0x0b47f760, 0x0b4cada0
              .long   0x0b516380, 0x0b561920, 0x0b5ace60, 0x0b5f8360
              .long   0x0b643800, 0x0b68ec60, 0x0b6da070, 0x0b725420
              .long   0x0b770790, 0x0b7bbab0, 0x0b806d70, 0x0b851ff0
              .long   0x0b89d210, 0x0b8e83f0, 0x0b933570, 0x0b97e6a0
              .long   0x0b9c9790, 0x0ba14820, 0x0ba5f860, 0x0baaa850
              .long   0x0baf57f0, 0x0bb40740, 0x0bb8b640, 0x0bbd64f0
              .long   0x0bc21350, 0x0bc6c150, 0x0bcb6f10, 0x0bd01c70
              .long   0x0bd4c980, 0x0bd97640, 0x0bde22b0, 0x0be2ced0
              .long   0x0be77aa0, 0x0bec2610, 0x0bf0d140, 0x0bf57c10
              .long   0x0bfa2690, 0x0bfed0c0, 0x0c037a90, 0x0c082420
              .long   0x0c0ccd50, 0x0c117630, 0x0c161ec0, 0x0c1ac6f0
              .long   0x0c1f6ee0, 0x0c241670, 0x0c28bdb0, 0x0c2d64a0
              .long   0x0c320b30, 0x0c36b180, 0x0c3b5770, 0x0c3ffd10
              .long   0x0c44a250, 0x0c494740, 0x0c4debe0, 0x0c529030
              .long   0x0c573430, 0x0c5bd7d0, 0x0c607b20, 0x0c651e10
              .long   0x0c69c0c0, 0x0c6e6310, 0x0c730500, 0x0c77a6b0
              .long   0x0c7c4800, 0x0c80e8f0, 0x0c8589a0, 0x0c8a29f0
              .long   0x0c8ec9e0, 0x0c936990, 0x0c9808e0, 0x0c9ca7e0
              .long   0x0ca14680, 0x0ca5e4d0, 0x0caa82c0, 0x0caf2060
              .long   0x0cb3bdb0, 0x0cb85ab0, 0x0cbcf750, 0x0cc19390
              .long   0x0cc62f80, 0x0ccacb20, 0x0ccf6670, 0x0cd40160
              .long   0x0cd89bf0, 0x0cdd3630, 0x0ce1d020, 0x0ce669b0
              .long   0x0ceb02f0, 0x0cef9bd0, 0x0cf43460, 0x0cf8cca0
              .long   0x0cfd6480, 0x0d01fc00, 0x0d069330, 0x0d0b2a10
              .long   0x0d0fc090, 0x0d1456b0, 0x0d18ec80, 0x0d1d8200
              .long   0x0d221720, 0x0d26abf0, 0x0d2b4060, 0x0d2fd470
              .long   0x0d346830, 0x0d38fba0, 0x0d3d8eb0, 0x0d422160
              .long   0x0d46b3c0, 0x0d4b45d0, 0x0d4fd770, 0x0d5468d0
              .long   0x0d58f9c0, 0x0d5d8a70, 0x0d621ab0, 0x0d66aaa0
              .long   0x0d6b3a40, 0x0d6fc970, 0x0d745860, 0x0d78e6e0
              .long   0x0d7d7510, 0x0d8202f0, 0x0d869070, 0x0d8b1d90
              .long   0x0d8faa50, 0x0d9436c0, 0x0d98c2e0, 0x0d9d4ea0
              .long   0x0da1da00, 0x0da66500, 0x0daaefb0, 0x0daf7a00
              .long   0x0db40400, 0x0db88da0, 0x0dbd16e0, 0x0dc19fc0
              .long   0x0dc62850, 0x0dcab090, 0x0dcf3860, 0x0dd3bfe0
              .long   0x0dd84700, 0x0ddccdd0, 0x0de15430, 0x0de5da50
              .long   0x0dea6000, 0x0deee560, 0x0df36a60, 0x0df7ef00
              .long   0x0dfc7340, 0x0e00f730, 0x0e057ac0, 0x0e09fe00
              .long   0x0e0e80d0, 0x0e130350, 0x0e178570, 0x0e1c0740
              .long   0x0e2088a0, 0x0e2509b0, 0x0e298a60, 0x0e2e0ab0
              .long   0x0e328ab0, 0x0e370a50, 0x0e3b8990, 0x0e400870
              .long   0x0e4486f0, 0x0e490520, 0x0e4d82f0, 0x0e520060
              .long   0x0e567d70, 0x0e5afa30, 0x0e5f7680, 0x0e63f280
              .long   0x0e686e20, 0x0e6ce960, 0x0e716440, 0x0e75ded0
              .long   0x0e7a5900, 0x0e7ed2c0, 0x0e834c30, 0x0e87c550
              .long   0x0e8c3e00, 0x0e90b650, 0x0e952e50, 0x0e99a5e0
              .long   0x0e9e1d20, 0x0ea29400, 0x0ea70a80, 0x0eab80a0
              .long   0x0eaff670, 0x0eb46bd0, 0x0eb8e0e0, 0x0ebd5580
              .long   0x0ec1c9d0, 0x0ec63dc0, 0x0ecab150, 0x0ecf2480
              .long   0x0ed39750, 0x0ed809c0, 0x0edc7bd0, 0x0ee0ed90
              .long   0x0ee55ee0, 0x0ee9cfe0, 0x0eee4070, 0x0ef2b0b0
              .long   0x0ef72080, 0x0efb9000, 0x0effff20, 0x0f046de0
              .long   0x0f08dc40, 0x0f0d4a30, 0x0f11b7d0, 0x0f162510
              .long   0x0f1a91f0, 0x0f1efe70, 0x0f236a90, 0x0f27d650
              .long   0x0f2c41b0, 0x0f30acb0, 0x0f351760, 0x0f3981a0
              .long   0x0f3deb80, 0x0f425500, 0x0f46be20, 0x0f4b26e0
              .long   0x0f4f8f40, 0x0f53f740, 0x0f585ee0, 0x0f5cc620
              .long   0x0f612d00, 0x0f659380, 0x0f69f9a0, 0x0f6e5f50
              .long   0x0f72c4b0, 0x0f7729b0, 0x0f7b8e50, 0x0f7ff280
              .long   0x0f845660, 0x0f88b9d0, 0x0f8d1cf0, 0x0f917fa0
              .long   0x0f95e200, 0x0f9a43f0, 0x0f9ea580, 0x0fa306b0
              .long   0x0fa76780, 0x0fabc7f0, 0x0fb02800, 0x0fb487b0
              .long   0x0fb8e700, 0x0fbd45e0, 0x0fc1a470, 0x0fc60290
              .long   0x0fca6050, 0x0fcebdb0, 0x0fd31ab0, 0x0fd77750
              .long   0x0fdbd390, 0x0fe02f70, 0x0fe48ae0, 0x0fe8e600
              .long   0x0fed40b0, 0x0ff19b00, 0x0ff5f4f0, 0x0ffa4e80
              .long   0x0ffea7b0, 0x10030080, 0x100758e0, 0x100bb0e0
              .long   0x10100880, 0x10145fc0, 0x1018b6a0, 0x101d0d20
              .long   0x10216340, 0x1025b8e0, 0x102a0e40, 0x102e6320
              .long   0x1032b7c0, 0x10370be0, 0x103b5fa0, 0x103fb300
              .long   0x10440600, 0x104858a0, 0x104caae0, 0x1050fcc0
              .long   0x10554e40, 0x10599f40, 0x105df000, 0x10624040
              .long   0x10669020, 0x106adfa0, 0x106f2ec0, 0x10737d80
              .long   0x1077cbe0, 0x107c19c0, 0x10806760, 0x1084b480
              .long   0x10890160, 0x108d4dc0, 0x109199c0, 0x1095e560
              .long   0x109a30a0, 0x109e7b60, 0x10a2c5e0, 0x10a70fe0
              .long   0x10ab59a0, 0x10afa2e0, 0x10b3ebc0, 0x10b83440
              .long   0x10bc7c60, 0x10c0c400, 0x10c50b60, 0x10c95240
              .long   0x10cd98e0, 0x10d1df00, 0x10d624c0, 0x10da6a00
              .long   0x10deaf00, 0x10e2f3a0, 0x10e737c0, 0x10eb7b80
              .long   0x10efbee0, 0x10f401e0, 0x10f84480, 0x10fc86c0
              .long   0x1100c880, 0x11050a00, 0x11094b00, 0x110d8ba0
              .long   0x1111cbe0, 0x11160ba0, 0x111a4b20, 0x111e8a20
              .long   0x1122c8e0, 0x11270720, 0x112b4500, 0x112f8260
              .long   0x1133bf80, 0x1137fc20, 0x113c3860, 0x11407460
              .long   0x1144afc0, 0x1148eae0, 0x114d25a0, 0x11515fe0
              .long   0x115599c0, 0x1159d340, 0x115e0c60, 0x11624520
              .long   0x11667d60, 0x116ab540, 0x116eece0, 0x11732400
              .long   0x11775aa0, 0x117b9100, 0x117fc6e0, 0x1183fc60
              .long   0x11883180, 0x118c6640, 0x11909aa0, 0x1194ce80
              .long   0x11990200, 0x119d3520, 0x11a167e0, 0x11a59a40
              .long   0x11a9cc20, 0x11adfdc0, 0x11b22ee0, 0x11b65fa0
              .long   0x11ba8fe0, 0x11bebfe0, 0x11c2ef60, 0x11c71e80
              .long   0x11cb4d40, 0x11cf7b80, 0x11d3a980, 0x11d7d700
              .long   0x11dc0420, 0x11e030e0, 0x11e45d20, 0x11e88920
              .long   0x11ecb4a0, 0x11f0dfc0, 0x11f50a80, 0x11f934c0
              .long   0x11fd5ec0, 0x12018840, 0x1205b160, 0x1209da00
              .long   0x120e0260, 0x12122a40, 0x121651c0, 0x121a78e0
              .long   0x121e9f80, 0x1222c5e0, 0x1226ebc0, 0x122b1120
              .long   0x122f3640, 0x12335b00, 0x12377f40, 0x123ba320
              .long   0x123fc680, 0x1243e9a0, 0x12480c40, 0x124c2e80
              .long   0x12505060, 0x125471e0, 0x125892e0, 0x125cb380
              .long   0x1260d3c0, 0x1264f3a0, 0x12691300, 0x126d3200
              .long   0x127150a0, 0x12756ee0, 0x12798ca0, 0x127daa00
              .long   0x1281c700, 0x1285e3a0, 0x1289ffe0, 0x128e1ba0
              .long   0x12923700, 0x12965200, 0x129a6c80, 0x129e86a0
              .long   0x12a2a060, 0x12a6b9c0, 0x12aad2c0, 0x12aeeb40
              .long   0x12b30360, 0x12b71b20, 0x12bb3260, 0x12bf4940
              .long   0x12c35fc0, 0x12c775e0, 0x12cb8b80, 0x12cfa0e0
              .long   0x12d3b5c0, 0x12d7ca20, 0x12dbde40, 0x12dff1e0
              .long   0x12e40520, 0x12e81800, 0x12ec2a60, 0x12f03c60
              .long   0x12f44e00, 0x12f85f40, 0x12fc7000, 0x13008060
              .long   0x13049060, 0x1308a000, 0x130caf20, 0x1310bde0
              .long   0x1314cc40, 0x1318da20, 0x131ce7a0, 0x1320f4c0
              .long   0x13250180, 0x13290de0, 0x132d19c0, 0x13312540
              .long   0x13353040, 0x13393b00, 0x133d4540, 0x13414f20
              .long   0x13455880, 0x13496180, 0x134d6a20, 0x13517260
              .long   0x13557a20, 0x135981a0, 0x135d88a0, 0x13618f20
              .long   0x13659540, 0x13699b20, 0x136da060, 0x1371a560
              .long   0x1375a9e0, 0x1379ae00, 0x137db1c0, 0x1381b500
              .long   0x1385b7e0, 0x1389ba60, 0x138dbc60, 0x1391be20
              .long   0x1395bf60, 0x1399c020, 0x139dc0a0, 0x13a1c0a0
              .long   0x13a5c040, 0x13a9bf60, 0x13adbe40, 0x13b1bca0
              .long   0x13b5ba80, 0x13b9b820, 0x13bdb540, 0x13c1b200
              .long   0x13c5ae40, 0x13c9aa20, 0x13cda5a0, 0x13d1a0c0
              .long   0x13d59b60, 0x13d995c0, 0x13dd8f80, 0x13e18900
              .long   0x13e58200, 0x13e97aa0, 0x13ed72e0, 0x13f16aa0
              .long   0x13f56200, 0x13f95900, 0x13fd4f80, 0x140145c0
              .long   0x14053b60, 0x140930c0, 0x140d25a0, 0x14111a20
              .long   0x14150e40, 0x141901e0, 0x141cf540, 0x1420e800
              .long   0x1424da80, 0x1428cc80, 0x142cbe20, 0x1430af60
              .long   0x1434a020, 0x14389080, 0x143c8080, 0x14407000
              .long   0x14445f20, 0x14484de0, 0x144c3c40, 0x14502a20
              .long   0x145417a0, 0x145804c0, 0x145bf160, 0x145fdda0
              .long   0x1463c980, 0x1467b4e0, 0x146b9fe0, 0x146f8a80
              .long   0x147374c0, 0x14775e80, 0x147b47e0, 0x147f30e0
              .long   0x14831960, 0x14870180, 0x148ae940, 0x148ed080
              .long   0x1492b760, 0x14969de0, 0x149a8400, 0x149e69a0
              .long   0x14a24ee0, 0x14a633a0, 0x14aa1820, 0x14adfc20
              .long   0x14b1dfa0, 0x14b5c2e0, 0x14b9a5a0, 0x14bd8800
              .long   0x14c169e0, 0x14c54b60, 0x14c92c80, 0x14cd0d40
              .long   0x14d0ed80, 0x14d4cd60, 0x14d8acc0, 0x14dc8be0
              .long   0x14e06a80, 0x14e448c0, 0x14e82680, 0x14ec03e0
              .long   0x14efe0e0, 0x14f3bd60, 0x14f799a0, 0x14fb7540
              .long   0x14ff50a0, 0x15032b80, 0x15070600, 0x150ae020
              .long   0x150eb9c0, 0x15129300, 0x15166be0, 0x151a4440
              .long   0x151e1c60, 0x1521f3e0, 0x1525cb20, 0x1529a1e0
              .long   0x152d7840, 0x15314e20, 0x153523c0, 0x1538f8e0
              .long   0x153ccd80, 0x1540a1e0, 0x154475c0, 0x15484920
              .long   0x154c1c40, 0x154feee0, 0x1553c120, 0x155792e0
              .long   0x155b6460, 0x155f3540, 0x156305e0, 0x1566d600
              .long   0x156aa5c0, 0x156e7520, 0x15724400, 0x15761280
              .long   0x1579e0a0, 0x157dae40, 0x15817b80, 0x15854860
              .long   0x158914e0, 0x158ce0e0, 0x1590ac80, 0x159477a0
              .long   0x15984280, 0x159c0ce0, 0x159fd6c0, 0x15a3a060
              .long   0x15a76980, 0x15ab3220, 0x15aefa80, 0x15b2c260
              .long   0x15b689e0, 0x15ba50e0, 0x15be1780, 0x15c1ddc0
              .long   0x15c5a3a0, 0x15c96900, 0x15cd2e00, 0x15d0f2a0
              .long   0x15d4b6c0, 0x15d87a80, 0x15dc3de0, 0x15e000c0
              .long   0x15e3c340, 0x15e78560, 0x15eb4720, 0x15ef0860
              .long   0x15f2c940, 0x15f689c0, 0x15fa49c0, 0x15fe0960
              .long   0x1601c8a0, 0x16058760, 0x160945c0, 0x160d03c0
              .long   0x1610c140, 0x16147e60, 0x16183b20, 0x161bf780
              .long   0x161fb360, 0x16236ee0, 0x16272a00, 0x162ae4a0
              .long   0x162e9ee0, 0x163258c0, 0x16361220, 0x1639cb20
              .long   0x163d83c0, 0x16413c00, 0x1644f3c0, 0x1648ab20
              .long   0x164c6220, 0x165018a0, 0x1653cec0, 0x16578480
              .long   0x165b39c0, 0x165eeea0, 0x1662a320, 0x16665740
              .long   0x166a0ae0, 0x166dbe20, 0x16717100, 0x16752360
              .long   0x1678d560, 0x167c8700, 0x16803820, 0x1683e8e0
              .long   0x16879940, 0x168b4940, 0x168ef8c0, 0x1692a7e0
              .long   0x169656a0, 0x169a04e0, 0x169db2c0, 0x16a16040
              .long   0x16a50d40, 0x16a8ba00, 0x16ac6620, 0x16b01200
              .long   0x16b3bd60, 0x16b76860, 0x16bb1300, 0x16bebd40
              .long   0x16c26700, 0x16c61060, 0x16c9b940, 0x16cd61c0
              .long   0x16d109e0, 0x16d4b1a0, 0x16d858e0, 0x16dbffe0
              .long   0x16dfa640, 0x16e34c60, 0x16e6f200, 0x16ea9740
              .long   0x16ee3c20, 0x16f1e080, 0x16f58480, 0x16f92820
              .long   0x16fccb60, 0x17006e20, 0x17041080, 0x1707b260
              .long   0x170b5400, 0x170ef520, 0x171295e0, 0x17163620
              .long   0x1719d600, 0x171d7580, 0x172114a0, 0x1724b340
              .long   0x17285180, 0x172bef60, 0x172f8ce0, 0x173329e0
              .long   0x1736c680, 0x173a62c0, 0x173dfe80, 0x174199e0
              .long   0x174534e0, 0x1748cf80, 0x174c69a0, 0x17500360
              .long   0x17539cc0, 0x175735a0, 0x175ace20, 0x175e6640
              .long   0x1761fe00, 0x17659540, 0x17692c20, 0x176cc2a0
              .long   0x177058c0, 0x1773ee60, 0x177783a0, 0x177b1880
              .long   0x177eace0, 0x178240e0, 0x1785d480, 0x178967c0
              .long   0x178cfa80, 0x17908ce0, 0x17941ee0, 0x1797b080
              .long   0x179b41a0, 0x179ed260, 0x17a262c0, 0x17a5f2a0
              .long   0x17a98220, 0x17ad1140, 0x17b0a000, 0x17b42e40
              .long   0x17b7bc40, 0x17bb49c0, 0x17bed6c0, 0x17c26380
              .long   0x17c5efc0, 0x17c97b80, 0x17cd0700, 0x17d09200
              .long   0x17d41ca0, 0x17d7a6e0, 0x17db30c0, 0x17deba20
              .long   0x17e24320, 0x17e5cbc0, 0x17e953e0, 0x17ecdbc0
              .long   0x17f06320, 0x17f3ea00, 0x17f770a0, 0x17faf6c0
              .long   0x17fe7c80, 0x180201e0, 0x180586c0, 0x18090b40
              .long   0x180c8f60, 0x18101320, 0x18139680, 0x18171960
              .long   0x181a9be0, 0x181e1e00, 0x18219fa0, 0x182520e0
              .long   0x1828a1c0, 0x182c2240, 0x182fa240, 0x18332200
              .long   0x1836a140, 0x183a2000, 0x183d9e80, 0x18411c80
              .long   0x18449a20, 0x18481760, 0x184b9440, 0x184f10a0
              .long   0x18528ca0, 0x18560840, 0x18598360, 0x185cfe40
              .long   0x186078a0, 0x1863f2a0, 0x18676c20, 0x186ae560
              .long   0x186e5e20, 0x1871d680, 0x18754e80, 0x1878c600
              .long   0x187c3d20, 0x187fb3e0, 0x18832a40, 0x1886a040
              .long   0x188a15c0, 0x188d8ae0, 0x1890ffa0, 0x189473e0
              .long   0x1897e7e0, 0x189b5b60, 0x189ece80, 0x18a24140
              .long   0x18a5b380, 0x18a92560, 0x18ac96e0, 0x18b00800
              .long   0x18b378c0, 0x18b6e900, 0x18ba58e0, 0x18bdc860
              .long   0x18c13780, 0x18c4a640, 0x18c81480, 0x18cb8260
              .long   0x18ceefe0, 0x18d25d00, 0x18d5c9a0, 0x18d935e0
              .long   0x18dca1c0, 0x18e00d40, 0x18e37860, 0x18e6e300
              .long   0x18ea4d40, 0x18edb720, 0x18f120a0, 0x18f489a0
              .long   0x18f7f260, 0x18fb5aa0, 0x18fec280, 0x190229e0
              .long   0x19059100, 0x1908f7a0, 0x190c5de0, 0x190fc3c0
              .long   0x19132940, 0x19168e40, 0x1919f2e0, 0x191d5740
              .long   0x1920bb00, 0x19241e80, 0x192781a0, 0x192ae440
              .long   0x192e4680, 0x1931a860, 0x193509e0, 0x19386ae0
              .long   0x193bcb80, 0x193f2be0, 0x19428ba0, 0x1945eb20
              .long   0x19494a40, 0x194ca8e0, 0x19500720, 0x19536500
              .long   0x1956c280, 0x195a1fa0, 0x195d7c40, 0x1960d880
              .long   0x19643460, 0x19678fe0, 0x196aeb00, 0x196e45a0
              .long   0x1971a000, 0x1974f9e0, 0x19785360, 0x197bac80
              .long   0x197f0520, 0x19825d80, 0x1985b560, 0x19890ce0
              .long   0x198c6400, 0x198fbac0, 0x19931100, 0x19966700
              .long   0x1999bc80, 0x199d11a0, 0x19a06660, 0x19a3bac0
              .long   0x19a70ea0, 0x19aa6240, 0x19adb560, 0x19b10820
              .long   0x19b45a80, 0x19b7ac60, 0x19bafe00, 0x19be4f20
              .long   0x19c1a000, 0x19c4f060, 0x19c84060, 0x19cb8fe0
              .long   0x19cedf20, 0x19d22e00, 0x19d57c60, 0x19d8ca60
              .long   0x19dc1800, 0x19df6540, 0x19e2b200, 0x19e5fe80
              .long   0x19e94a80, 0x19ec9640, 0x19efe180, 0x19f32c60
              .long   0x19f676c0, 0x19f9c0e0, 0x19fd0a80, 0x1a0053e0
              .long   0x1a039cc0, 0x1a06e540, 0x1a0a2d60, 0x1a0d7520
              .long   0x1a10bc60, 0x1a140360, 0x1a1749e0, 0x1a1a9000
              .long   0x1a1dd5c0, 0x1a211b20, 0x1a246020, 0x1a27a4c0
              .long   0x1a2ae8e0, 0x1a2e2cc0, 0x1a317020, 0x1a34b320
              .long   0x1a37f5c0, 0x1a3b3800, 0x1a3e79e0, 0x1a41bb40
              .long   0x1a44fc60, 0x1a483d00, 0x1a4b7d40, 0x1a4ebd40
              .long   0x1a51fcc0, 0x1a553bc0, 0x1a587a80, 0x1a5bb8e0
              .long   0x1a5ef6c0, 0x1a623460, 0x1a657180, 0x1a68ae40
              .long   0x1a6beaa0, 0x1a6f26a0, 0x1a726240, 0x1a759d80
              .long   0x1a78d840, 0x1a7c12c0, 0x1a7f4cc0, 0x1a828660
              .long   0x1a85bfc0, 0x1a88f8a0, 0x1a8c3120, 0x1a8f6920
              .long   0x1a92a0e0, 0x1a95d840, 0x1a990f20, 0x1a9c45c0
              .long   0x1a9f7be0, 0x1aa2b1a0, 0x1aa5e700, 0x1aa91c20
              .long   0x1aac50a0, 0x1aaf84e0, 0x1ab2b8c0, 0x1ab5ec40
              .long   0x1ab91f40, 0x1abc5200, 0x1abf8440, 0x1ac2b620
              .long   0x1ac5e7c0, 0x1ac918e0, 0x1acc49a0, 0x1acf7a00
              .long   0x1ad2a9e0, 0x1ad5d980, 0x1ad908c0, 0x1adc37a0
              .long   0x1adf6600, 0x1ae29400, 0x1ae5c1c0, 0x1ae8ef00
              .long   0x1aec1be0, 0x1aef4860, 0x1af27480, 0x1af5a040
              .long   0x1af8cba0, 0x1afbf6a0, 0x1aff2140, 0x1b024b80
              .long   0x1b057540, 0x1b089ec0, 0x1b0bc7c0, 0x1b0ef080
              .long   0x1b1218c0, 0x1b1540a0, 0x1b186840, 0x1b1b8f60
              .long   0x1b1eb620, 0x1b21dc80, 0x1b250280, 0x1b282820
              .long   0x1b2b4d60, 0x1b2e7220, 0x1b3196a0, 0x1b34bac0
              .long   0x1b37de60, 0x1b3b01c0, 0x1b3e24c0, 0x1b414740
              .long   0x1b446960, 0x1b478b40, 0x1b4aaca0, 0x1b4dcda0
              .long   0x1b50ee60, 0x1b540ea0, 0x1b572e80, 0x1b5a4e00
              .long   0x1b5d6d20, 0x1b608be0, 0x1b63aa40, 0x1b66c840
              .long   0x1b69e5e0, 0x1b6d0320, 0x1b702000, 0x1b733c80
              .long   0x1b765880, 0x1b797440, 0x1b7c8fa0, 0x1b7faaa0
              .long   0x1b82c520, 0x1b85df60, 0x1b88f940, 0x1b8c12a0
              .long   0x1b8f2bc0, 0x1b924460, 0x1b955cc0, 0x1b9874a0
              .long   0x1b9b8c40, 0x1b9ea360, 0x1ba1ba20, 0x1ba4d0a0
              .long   0x1ba7e6a0, 0x1baafc60, 0x1bae11a0, 0x1bb12680
              .long   0x1bb43b20, 0x1bb74f40, 0x1bba6300, 0x1bbd7680
              .long   0x1bc08980, 0x1bc39c20, 0x1bc6ae60, 0x1bc9c060
              .long   0x1bccd1e0, 0x1bcfe300, 0x1bd2f3e0, 0x1bd60440
              .long   0x1bd91440, 0x1bdc23e0, 0x1bdf3340, 0x1be24220
              .long   0x1be550a0, 0x1be85ec0, 0x1beb6ca0, 0x1bee7a00
              .long   0x1bf18700, 0x1bf493c0, 0x1bf7a000, 0x1bfaabe0
              .long   0x1bfdb780, 0x1c00c2a0, 0x1c03cd60, 0x1c06d7e0
              .long   0x1c09e1e0, 0x1c0ceba0, 0x1c0ff4e0, 0x1c12fde0
              .long   0x1c160660, 0x1c190ea0, 0x1c1c1660, 0x1c1f1de0
              .long   0x1c2224e0, 0x1c252ba0, 0x1c283200, 0x1c2b37e0
              .long   0x1c2e3d80, 0x1c3142c0, 0x1c3447a0, 0x1c374c00
              .long   0x1c3a5020, 0x1c3d53e0, 0x1c405740, 0x1c435a40
              .long   0x1c465ce0, 0x1c495f20, 0x1c4c6100, 0x1c4f6280
              .long   0x1c5263a0, 0x1c556480, 0x1c5864e0, 0x1c5b64e0
              .long   0x1c5e64a0, 0x1c6163e0, 0x1c6462c0, 0x1c676160
              .long   0x1c6a5f80, 0x1c6d5d60, 0x1c705ae0, 0x1c7357e0
              .long   0x1c7654a0, 0x1c795100, 0x1c7c4d00, 0x1c7f48a0
              .long   0x1c8243e0, 0x1c853ec0, 0x1c883940, 0x1c8b3360
              .long   0x1c8e2d40, 0x1c9126a0, 0x1c941fc0, 0x1c971860
              .long   0x1c9a10c0, 0x1c9d08a0, 0x1ca00040, 0x1ca2f780
              .long   0x1ca5ee60, 0x1ca8e4c0, 0x1cabdae0, 0x1caed0c0
              .long   0x1cb1c620, 0x1cb4bb20, 0x1cb7afc0, 0x1cbaa420
              .long   0x1cbd9800, 0x1cc08ba0, 0x1cc37ec0, 0x1cc671a0
              .long   0x1cc96420, 0x1ccc5640, 0x1ccf4800, 0x1cd23960
              .long   0x1cd52a60, 0x1cd81b20, 0x1cdb0b60, 0x1cddfb60
              .long   0x1ce0eae0, 0x1ce3da20, 0x1ce6c900, 0x1ce9b780
              .long   0x1ceca5a0, 0x1cef9360, 0x1cf280c0, 0x1cf56dc0
              .long   0x1cf85a80, 0x1cfb46c0, 0x1cfe32c0, 0x1d011e60
              .long   0x1d040980, 0x1d06f460, 0x1d09df00, 0x1d0cc920
              .long   0x1d0fb2e0, 0x1d129c40, 0x1d158560, 0x1d186e20
              .long   0x1d1b5680, 0x1d1e3e60, 0x1d212620, 0x1d240d60
              .long   0x1d26f440, 0x1d29dac0, 0x1d2cc100, 0x1d2fa6e0
              .long   0x1d328c40, 0x1d357160, 0x1d385620, 0x1d3b3aa0
              .long   0x1d3e1ea0, 0x1d410260, 0x1d43e5a0, 0x1d46c8a0
              .long   0x1d49ab40, 0x1d4c8d80, 0x1d4f6f60, 0x1d5250e0
              .long   0x1d553220, 0x1d5812e0, 0x1d5af360, 0x1d5dd380
              .long   0x1d60b340, 0x1d6392a0, 0x1d6671c0, 0x1d695060
              .long   0x1d6c2ec0, 0x1d6f0cc0, 0x1d71ea60, 0x1d74c7a0
              .long   0x1d77a480, 0x1d7a8120, 0x1d7d5d40, 0x1d803920
              .long   0x1d8314a0, 0x1d85efc0, 0x1d88ca80, 0x1d8ba500
              .long   0x1d8e7f00, 0x1d9158c0, 0x1d943220, 0x1d970b20
              .long   0x1d99e3e0, 0x1d9cbc20, 0x1d9f9420, 0x1da26bc0
              .long   0x1da54300, 0x1da819e0, 0x1daaf060, 0x1dadc6a0
              .long   0x1db09c60, 0x1db371e0, 0x1db64700, 0x1db91be0
              .long   0x1dbbf040, 0x1dbec460, 0x1dc19820, 0x1dc46b80
              .long   0x1dc73e80, 0x1dca1120, 0x1dcce380, 0x1dcfb580
              .long   0x1dd28720, 0x1dd55860, 0x1dd82940, 0x1ddaf9e0
              .long   0x1dddca20, 0x1de09a00, 0x1de36980, 0x1de638a0
              .long   0x1de90780, 0x1debd600, 0x1deea420, 0x1df171e0
              .long   0x1df43f40, 0x1df70c60, 0x1df9d920, 0x1dfca580
              .long   0x1dff7180, 0x1e023d40, 0x1e0508a0, 0x1e07d3a0
              .long   0x1e0a9e40, 0x1e0d6880, 0x1e103280, 0x1e12fc20
              .long   0x1e15c560, 0x1e188e40, 0x1e1b56e0, 0x1e1e1f00
              .long   0x1e20e6e0, 0x1e23ae80, 0x1e2675a0, 0x1e293c80
              .long   0x1e2c0300, 0x1e2ec920, 0x1e318ee0, 0x1e345460
              .long   0x1e371980, 0x1e39de40, 0x1e3ca2a0, 0x1e3f66c0
              .long   0x1e422a80, 0x1e44ede0, 0x1e47b0e0, 0x1e4a73a0
              .long   0x1e4d3600, 0x1e4ff800, 0x1e52b9a0, 0x1e557b00
              .long   0x1e583c00, 0x1e5afca0, 0x1e5dbce0, 0x1e607ce0
              .long   0x1e633c80, 0x1e65fbc0, 0x1e68baa0, 0x1e6b7940
              .long   0x1e6e3780, 0x1e70f560, 0x1e73b300, 0x1e767020
              .long   0x1e792d00, 0x1e7be9a0, 0x1e7ea5c0, 0x1e8161a0
              .long   0x1e841d20, 0x1e86d840, 0x1e899320, 0x1e8c4da0
              .long   0x1e8f07c0, 0x1e91c1a0, 0x1e947b00, 0x1e973440
              .long   0x1e99ed00, 0x1e9ca560, 0x1e9f5d80, 0x1ea21560
              .long   0x1ea4ccc0, 0x1ea783e0, 0x1eaa3aa0, 0x1eacf100
              .long   0x1eafa720, 0x1eb25ce0, 0x1eb51240, 0x1eb7c760
              .long   0x1eba7c20, 0x1ebd3080, 0x1ebfe480, 0x1ec29840
              .long   0x1ec54ba0, 0x1ec7fea0, 0x1ecab160, 0x1ecd63c0
              .long   0x1ed015c0, 0x1ed2c780, 0x1ed578e0, 0x1ed829e0
              .long   0x1edada80, 0x1edd8ae0, 0x1ee03ae0, 0x1ee2eaa0
              .long   0x1ee59a00, 0x1ee84900, 0x1eeaf7a0, 0x1eeda600
              .long   0x1ef05400, 0x1ef301a0, 0x1ef5af00, 0x1ef85c00
              .long   0x1efb08c0, 0x1efdb500, 0x1f006100, 0x1f030cc0
              .long   0x1f05b800, 0x1f086300, 0x1f0b0dc0, 0x1f0db820
              .long   0x1f106220, 0x1f130bc0, 0x1f15b520, 0x1f185e20
              .long   0x1f1b06c0, 0x1f1daf20, 0x1f205720, 0x1f22fee0
              .long   0x1f25a620, 0x1f284d40, 0x1f2af3e0, 0x1f2d9a40
              .long   0x1f304040, 0x1f32e600, 0x1f358b60, 0x1f383060
              .long   0x1f3ad500, 0x1f3d7960, 0x1f401d80, 0x1f42c120
              .long   0x1f4564a0, 0x1f4807a0, 0x1f4aaa60, 0x1f4d4cc0
              .long   0x1f4feee0, 0x1f529080, 0x1f553200, 0x1f57d300
              .long   0x1f5a73c0, 0x1f5d1440, 0x1f5fb460, 0x1f625420
              .long   0x1f64f380, 0x1f6792a0, 0x1f6a3160, 0x1f6ccfe0
              .long   0x1f6f6e00, 0x1f720be0, 0x1f74a940, 0x1f774680
              .long   0x1f79e340, 0x1f7c7fc0, 0x1f7f1c00, 0x1f81b7c0
              .long   0x1f845340, 0x1f86ee80, 0x1f898960, 0x1f8c23e0
              .long   0x1f8ebe20, 0x1f915800, 0x1f93f1a0, 0x1f968ae0
              .long   0x1f9923c0, 0x1f9bbc60, 0x1f9e54a0, 0x1fa0ec80
              .long   0x1fa38420, 0x1fa61b80, 0x1fa8b280, 0x1fab4920
              .long   0x1faddf60, 0x1fb07560, 0x1fb30b20, 0x1fb5a080
              .long   0x1fb83580, 0x1fbaca40, 0x1fbd5ea0, 0x1fbff2a0
              .long   0x1fc28660, 0x1fc519e0, 0x1fc7ace0, 0x1fca3fc0
              .long   0x1fccd220, 0x1fcf6440, 0x1fd1f620, 0x1fd487a0
              .long   0x1fd718c0, 0x1fd9a9a0, 0x1fdc3a20, 0x1fdeca60
              .long   0x1fe15a40, 0x1fe3e9e0, 0x1fe67920, 0x1fe90800
              .long   0x1feb96a0, 0x1fee24e0, 0x1ff0b2e0, 0x1ff34080
              .long   0x1ff5cde0, 0x1ff85ae0, 0x1ffae7a0, 0x1ffd7400
              .long   0x20000000
