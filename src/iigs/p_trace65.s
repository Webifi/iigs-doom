;;; Collect line and thing intersections for a block-map trace.
;;;
;;; P_PathTraverse (p_path65.s) visits relevant blocks and calls
;;; the line/thing collectors here. They append candidate intercepts;
;;; p_path65.s:traverse handles their order and the caller's hit callback.
;;; interceptVector3 and fixedDiv compute the trace fraction at a crossing.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"

              .extern P_InitFlood
              .extern _Dp, FixedMul, FixedMul3216, P_PointOnLineSide
              .extern MA, MB, MR, umul16, umul16lo, _DirectPageStart
              .extern validcount, _g_blockmap, _g_blockmaplump, _g_lines
              .extern _g_bmapwidth, _g_bmapheight, _g_blocklinks
              .extern G_MX, G_MY, G_OFS, G_N, G_ID, PT_FLAGS, G_IDT
              .extern PT_FLP, ptL1, ptL2, ptL3, ptG1, ptG2

MAXINTERCEPTS .equ    64
PAD_FD        .equ    4               ; (fixedDiv keeps its size)

;;; The fast vertex sides (SIDE1): the constants of the trace in bank 3F.
BMROW         .equ    (MM_B3F + 0x6000) ; y * _g_bmapwidth for each row, and
LN36          .equ    (MM_B3F + 0x6200) ;   _g_lines + 36 * n for each line n
                                      ;   (P_InitBlockRows, src/iigs/p_map65.s)
VT_P1         .equ    (MM_B3F + 0xf400) ; SIDE1 (sideSetup): 2 (V2 + SQ), 4 SQ,
VT_P2         .equ    (MM_B3F + 0xf402) ;   C - VJ * SQ - VBV (vertices) and
VT_CV         .equ    (MM_B3F + 0xf404) ;   -VJ * SQ - VBTH (things)
VT_CT         .equ    (MM_B3F + 0xf406)
VT_OXC        .equ    (MM_B3F + 0xf408) ; (x >> 16) + cx, (y >> 16) + cy, and
VT_OYC        .equ    (MM_B3F + 0xf40a) ;   (dx ^ dy) >> 16
VT_SGN        .equ    (MM_B3F + 0xf40c)
VT_DYF        .equ    (MM_B3F + 0xf410) ; (dy >> 16) ^ VT_INVB, and 0x8000 when
VT_INVB       .equ    (MM_B3F + 0xf412) ;   R > 0 is side 0 (sideSetup)
IV_ML         .equ    (MM_B3F + 0xf418) ; ivProd: M = d >> 11 of trace.dx (+ 0)
IV_MH         .equ    (MM_B3F + 0xf41a) ;   and trace.dy (+ 4): its low word, its
                                      ;   high word (0 or -1)
IV_ON         .equ    (MM_B3F + 0xf420) ; not 0: a shot with M for both (ivSetup)
IC_NEXT       .equ    (MM_B3F + 0xe800) ; the intercepts by frac: at the offset
                                      ;   of each one the offset of the next
                                      ;   (0xffff: none), the first one at
                                      ;   MAXINTERCEPTS * SIZEOF_IC
IC_LAST       .equ    (MM_B3F + 0xea84) ; the last one into it (or the head)
SQL           .equ    MM_SQL
SQH           .equ    MM_SQH
VRN           .equ    2040            ; SIDE1: |X'|, |Y'| up to this
VJ            .equ    23              ; V2 = 256 * VJ >= VRN + 2048: the
                                      ;   operands of the products stay above 0
VBV           .equ    5               ; L cannot tell: -5..5 for vertices,
VBTH          .equ    21              ;   -21..13 for the corners of things
VBTL          .equ    13              ;   (their fractions)
SQM_LO        .equ    (256 * VJ - VRN - 2048) ; SQMID: the squares of sub + V2 +- SQ
SQM_HI        .equ    (256 * VJ + VRN + 2048)
SQM_TAB       .equ    (MM_VIEWSAVE + 0) ; 2 * (SQM_HI - SQM_LO + 1) bytes
SQMID         .equ    (SQM_TAB - 2 * SQM_LO) ; square n at SQMID + 2 * n

TR_X          .equ    (_g_trace + OFS_DL_X)
TR_Y          .equ    (_g_trace + OFS_DL_Y)
TR_DX         .equ    (_g_trace + OFS_DL_DX)
TR_DY         .equ    (_g_trace + OFS_DL_DY)

LD            .equ    (_Dp+12)        ; the line or thing
PAD_TT        .equ    1               ; (the bytes the old code had more)
PAD_TS        .equ    74              ; (thSide: its fragment keeps its size)
PAD_GT        .equ    13              ; (gBlockT: its fragment keeps its size)
PAD_SS        .equ    1               ; (sideSetup: its fragment keeps its size)
PAD_TL        .equ    18              ; (traceLines: its fragment keeps its size)
GSTAMP        .equ    MM_GSTAMP       ; the guard of src/iigs/p_path65.s
TL_LS         .equ    (_Dp+8)         ; traceLines: the list (callee-saved)

              .section znear, bss
TC_X:         .space  4               ; point of divlineSide
TC_Y:         .space  4
TC_S1:        .space  2
TC_X1:        .space  4               ; the divline dl of the intercept
TC_Y1:        .space  4
TC_DX:        .space  4
TC_DY:        .space  4
TC_A:         .space  4               ; FixedDiv(a, b), and temporaries
TC_B:         .space  4
TC_T:         .space  4
              .public VT_RR
VT_RR:        .space  2               ; not 0: the fast vertex sides
TC_CH:        .space  2
TC_CL:        .space  2
              .public TR_LONG
TR_LONG:      .space  2               ; 1: a long trace (longTrace), set with
                                      ;   _g_trace (src/iigs/p_path65.s)
TC_PH:        .space  2               ; SIDEPROD

;;; Signed 32-bit a < b: lda a.lo / cmp b.lo / lda a.hi / SLT32 b.hi / bmi
SLT32         .macro  op
              sbc     \op
              bvc     1$
              eor     ##0x8000
1$:
              .endm

;;; X:C = the low 32 bits of (a >> 8) * (b >> 16), a and b the fixed_t at
;;; near a and b (arithmetic shifts), as _Mul32 of those values: with
;;; A = a >> 8 (low word AL, high word AH = byte 3 of a, signed) and
;;; B = b >> 16 (BH = its sign), the product is AL * B + (AH * B +
;;; AL * BH) << 16. AH is 0 or -1 for a point less than 256 units away:
;;; then AH * B is 0 or -B, with no multiply. (umul16lo keeps MR.)
SIDEPROD      .macro  a, b
              lda     .near (\a + 1)       ; AL = bits 8..23 of a
              sta     dp:.tiny MA
              lda     .near (\b + 2)       ; B = b >> 16
              sta     dp:.tiny MB
              jsl     long:umul16           ; MR = AL * B, unsigned
              lda     dp:.tiny (MR+2)
              ldx     dp:.tiny MB           ; B < 0: minus AL << 16
              bpl     1$
              sec
              sbc     dp:.tiny MA
1$:           tax                           ; (the high word)
              lda     .near (\a + 2)       ; AH = byte 3 of a, sign extended
              xba
              and     ##0x00ff
              beq     3$
              cmp     ##0x00ff
              beq     4$
              cmp     ##0x0080
              bcc     2$
              ora     ##0xff00
2$:           stx     .near TC_PH           ; + low 16 bits of AH * B
              sta     dp:.tiny MA
              jsl     long:umul16lo
              clc
              adc     .near TC_PH
              tax
              bra     3$
4$:           txa                           ; AH = -1: minus B
              sec
              sbc     dp:.tiny MB
              tax
3$:           lda     dp:.tiny MR
              .endm

;;; ---------------------------------------------------------------------------
;;; divlineSide: P_PointOnDivlineSide(TC_X, TC_Y, &_g_trace), 0 or 1.
;;;   !dx ? x <= line->x ? dy > 0 : dy < 0 :
;;;   !dy ? y <= line->y ? dx < 0 : dx > 0 :
;;;   (dy ^ dx ^ (x -= line->x) ^ (y -= line->y)) < 0 ? (dy ^ x) < 0 :
;;;   (y >> 8) * (dx >> 16) >= (dy >> 16) * (x >> 8)
;;; TC_X and TC_Y change.
;;; ---------------------------------------------------------------------------
              .section logiccode, text
divlineSide:  lda     .near TR_DX
              ora     .near (TR_DX+2)
              bne     20$
              lda     .near TR_X            ; dx == 0: line->x < x ?
              cmp     .near TC_X
              lda     .near (TR_X+2)
              SLT32   .near (TC_X+2)
              bmi     11$
              lda     .near (TR_DY+2)       ; x <= line->x: dy > 0
              bmi     90$
              ora     .near TR_DY
              beq     90$
              bra     91$
11$:          lda     .near (TR_DY+2)       ; dy < 0
              bmi     91$
              bra     90$

20$:          lda     .near TR_DY
              ora     .near (TR_DY+2)
              bne     30$
              lda     .near TR_Y            ; dy == 0: line->y < y ?
              cmp     .near TC_Y
              lda     .near (TR_Y+2)
              SLT32   .near (TC_Y+2)
              bmi     21$
              lda     .near (TR_DX+2)       ; y <= line->y: dx < 0
              bmi     91$
              bra     90$
21$:          lda     .near (TR_DX+2)       ; dx > 0
              bmi     90$
              ora     .near TR_DX
              beq     90$
              bra     91$

90$:          lda     ##0
              rtl
91$:          lda     ##1
              rtl

30$:          lda     .near TC_X            ; x -= line->x
              sec
              sbc     .near TR_X
              sta     .near TC_X
              lda     .near (TC_X+2)
              sbc     .near (TR_X+2)
              sta     .near (TC_X+2)
              lda     .near TC_Y            ; y -= line->y
              sec
              sbc     .near TR_Y
              sta     .near TC_Y
              lda     .near (TC_Y+2)
              sbc     .near (TR_Y+2)
              sta     .near (TC_Y+2)
              lda     .near (TR_DY+2)       ; signs differ: (dy ^ x) < 0
              eor     .near (TR_DX+2)
              eor     .near (TC_X+2)
              eor     .near (TC_Y+2)
              bpl     40$
              lda     .near (TR_DY+2)
              eor     .near (TC_X+2)
              bmi     91$
              bra     90$

40$:          SIDEPROD TC_Y, TR_DX          ; left = (y >> 8) * (dx >> 16)
              sta     .near TC_T
              stx     .near (TC_T+2)
              SIDEPROD TC_X, TR_DY          ; right = (dy >> 16) * (x >> 8)
              clc                           ; left >= right: right - left - 1 < 0
              sbc     .near TC_T
              txa
              SLT32   .near (TC_T+2)
              bpl     41$
              lda     ##1
              rtl
41$:          lda     ##0
              rtl

;;; ---------------------------------------------------------------------------
;;; interceptVector3: X:C = P_InterceptVector3(&_g_trace, &dl), with dl in
;;; TC_X1, TC_Y1, TC_DX, TC_DY:
;;;   a = (dl.dy >> 16) * ((dl.x - trace.x) >> 8)
;;;   b = (dl.dx >> 16) * ((trace.y - dl.y) >> 8)
;;;   c = FixedMul(trace.dx, dl.dy >> 8)
;;;   d = FixedMul(trace.dy, dl.dx >> 8)
;;;   num = a + b, den = c - d
;;;   num == 0 || den == 0 ? 0 : (num ^ den) < 0 ? -1 : FixedDiv(num, den)
;;; Most lines are along an axis: dl.dy == 0 gives a = c = 0 and dl.dx == 0
;;; gives b = d = 0, with no multiplies for them.
;;; ---------------------------------------------------------------------------
              .section logiccode, text
interceptVector3:
              lda     .near TC_DY           ; dl.dy == 0: a = c = 0
              ora     .near (TC_DY+2)
              bne     1$
              lda     .near TC_DX
              ora     .near (TC_DX+2)
              beq     0$
              brl     ivB
0$:           tax                           ; dl.dx == 0 too: num = 0
              rtl
1$:           lda     .near TC_X1           ; a
              sec
              sbc     .near TR_X
              sta     .near TC_T
              lda     .near (TC_X1+2)
              sbc     .near (TR_X+2)
              sta     .near (TC_T+2)
              SIDEPROD TC_T, TC_DY          ; (dl.dy >> 16) * ((dl.x - trace.x) >> 8)
              sta     .near TC_A
              stx     .near (TC_A+2)
              ldx     ##0                   ; c = FixedMul(trace.dx, dl.dy >> 8)
              jsr     .kbank ivProd
              sta     .near TC_B
              stx     .near (TC_B+2)
              lda     .near TC_DX           ; dl.dx == 0: b = d = 0
              ora     .near (TC_DX+2)
              bne     ivB
              brl     ivTest

;;; ivSlow: the product of ivProd with FixedMul3216 (dl.o >> 24 = 0) or
;;; FixedMul (X: the axis, Y = 4 - X).
ivSlow:       lda     .near (TC_DX+1),y     ; _Dp = dl.o >> 8
              sta     dp:.tiny _Dp
              lda     .near (TC_DX+2),y
              xba
              and     ##0x00ff
              beq     2$
              cmp     ##0x0080
              bcc     1$
              ora     ##0xff00
1$:           sta     dp:.tiny (_Dp+2)
              ldy     .near (TR_DX+2),x
              lda     .near TR_DX,x
              tyx
              jsl     long:FixedMul
              rts
2$:           ldy     .near (TR_DX+2),x
              lda     .near TR_DX,x
              tyx
              jsl     long:FixedMul3216
              rts

ivB:          lda     .near TR_Y            ; b
              sec
              sbc     .near TC_Y1
              sta     .near TC_T
              lda     .near (TR_Y+2)
              sbc     .near (TC_Y1+2)
              sta     .near (TC_T+2)
              SIDEPROD TC_T, TC_DX          ; (dl.dx >> 16) * ((trace.y - dl.y) >> 8)
              ldy     .near TC_DY           ; num = a + b (dl.dy == 0: b)
              bne     1$
              ldy     .near (TC_DY+2)
              bne     1$
              sta     .near TC_A
              stx     .near (TC_A+2)
              bra     2$
1$:           clc
              adc     .near TC_A
              sta     .near TC_A
              txa
              adc     .near (TC_A+2)
              sta     .near (TC_A+2)
2$:           ldx     ##4                   ; d = FixedMul(trace.dy, dl.dx >> 8)
              jsr     .kbank ivProd
              ldy     .near TC_DY           ; den = c - d (dl.dy == 0: -d)
              bne     3$
              ldy     .near (TC_DY+2)
              bne     3$
              eor     ##0xffff
              clc
              adc     ##1
              sta     .near TC_B
              txa
              eor     ##0xffff
              adc     ##0
              sta     .near (TC_B+2)
              bra     ivTest
3$:           sta     .near TC_T
              lda     .near TC_B
              sec
              sbc     .near TC_T
              sta     .near TC_B
              stx     .near TC_T
              lda     .near (TC_B+2)
              sbc     .near TC_T
              sta     .near (TC_B+2)

ivTest:       lda     .near TC_A            ; num == 0 || den == 0: 0
              ora     .near (TC_A+2)
              beq     1$
              lda     .near TC_B
              ora     .near (TC_B+2)
              bne     2$
1$:           lda     ##0
              tax
              rtl
2$:           lda     .near (TC_A+2)        ; (num ^ den) < 0: -1
              eor     .near (TC_B+2)
              bpl     fixedDiv
              lda     ##0xffff
              tax
              rtl

;;; ivProd: X:C = FixedMul(trace.d, dl.o >> 8) of interceptVector3 (jsr)
;;; for the axis X (0: trace.dx and dl.dy, 4: trace.dy and dl.dx). In a
;;; shot (IV_ON) with dl.o in whole units, n = dl.o >> 16 in -4096..4095,
;;; it is M * (n << 3) with M = d >> 11 (IV_ML, IV_MH: ivSetup): one
;;; product, where FixedMul3216 takes two. Else ivSlow.
ivProd:       txa                           ; Y = 4 - X: dl.o
              eor     ##4
              tay
              lda     long:IV_ON
              beq     9$
              lda     .near TC_DX,y         ; dl.o in whole units, n in
              bne     9$                    ;   -4096..4095
              lda     .near (TC_DX+2),y
              clc
              adc     ##4096
              cmp     ##8192
              bcs     9$
              asl     a                     ; MB = n << 3: ((n + 4096) << 3)
              asl     a                     ;   ^ 0x8000
              asl     a
              eor     ##0x8000
              sta     dp:.tiny MB
              bmi     1$                    ; C = (MH & MB) + (MB < 0 ? ML : 0),
              and     long:IV_MH,x          ;   the signed parts, off the high
              bra     2$                    ;   word of the unsigned product
1$:           and     long:IV_MH,x
              clc
              adc     long:IV_ML,x
2$:           pha
              lda     long:IV_ML,x          ; MA = ML
              sta     dp:.tiny MA
              jsl     long:umul16           ; MR = ML * MB, unsigned
              pla
              eor     ##0xffff
              sec
              adc     dp:.tiny (MR+2)
              tax
              lda     dp:.tiny MR
              rts
9$:           brl     ivSlow
              .space  10                    ; (fixedDiv keeps its address)

;;; fixedDiv: X:C = FixedDiv(TC_A, TC_B), using long division with
;;; signed 32-bit comparisons and shifts.
;;; After the first loop, a is in Y:X (no stores for a). One loop makes
;;; the bits of ch, then the 16 bits of cl, in TC_CL: for cl it starts
;;; with a bit above them, which ends the loop. ibit is in MA. The loop 7$
;;; keeps the bits of cl in D (no direct page there; the interrupt does
;;; not use it), so it has no stores.
fixedDiv:     lda     .near (TC_A+2)        ; a < 0: a = -a, b = -b
              bpl     1$
              lda     ##0
              sec
              sbc     .near TC_A
              sta     .near TC_A
              lda     ##0
              sbc     .near (TC_A+2)
              sta     .near (TC_A+2)
              lda     ##0
              sec
              sbc     .near TC_B
              sta     .near TC_B
              lda     ##0
              sbc     .near (TC_B+2)
              sta     .near (TC_B+2)
1$:           lda     .near (TC_B+2)        ; 0 <= a < b < 2^30: ch = 0, and
              cmp     ##0x4000              ;   the loop 7$ makes cl from 2a
              bcs     11$
              lda     .near TC_A
              cmp     .near TC_B
              lda     .near (TC_A+2)
              sbc     .near (TC_B+2)
              bcs     11$
              stz     .near TC_CH
              lda     ##1                   ; D: the bits of cl
              tcd
              lda     .near TC_A            ; 2a in A:X for the loop 7$
              asl     a
              tax
              lda     .near (TC_A+2)
              rol     a
              jmp     long:fdLoop           ; the fast loop
11$:          lda     ##1                   ; ibit = 1
              sta     dp:.tiny MA
2$:           lda     .near TC_B            ; while (b < a) { b <<= 1; ibit <<= 1; }
              cmp     .near TC_A
              lda     .near (TC_B+2)
              SLT32   .near (TC_A+2)
              bpl     3$
              asl     .near TC_B
              rol     .near (TC_B+2)
              asl     dp:.tiny MA
              bra     2$
3$:           ldx     .near TC_A            ; a in Y:X
              ldy     .near (TC_A+2)
              stz     .near TC_CL           ; the bits of ch
              lda     dp:.tiny MA           ; (for (; ibit != 0; ibit >>= 1))
              bne     4$
              stz     .near TC_CH
              bra     6$
4$:           txa                           ; a >= b (signed): a -= b and the
              cmp     .near TC_B            ;   bit is 1, else 0
              tya
              SLT32   .near (TC_B+2)
              clc
              bmi     5$
              txa
              sec
              sbc     .near TC_B
              tax
              tya
              sbc     .near (TC_B+2)
              tay
              sec
5$:           rol     .near TC_CL
              bcs     8$                    ; (the 16 bits of cl)
              txa                           ; a <<= 1, but not after the last
              asl     a                     ;   bit of cl
              tax
              tya
              rol     a
              tay
              lda     dp:.tiny MA           ; a bit of cl (ibit is 0)
              beq     4$
              lsr     dp:.tiny MA           ; the next bit of ch
              bne     4$
              lda     .near TC_CL           ; ch done
              sta     .near TC_CH
6$:           lda     .near (TC_B+2)        ; 0 < b < 2^30 and a >= 0: then a
              cmp     ##0x4000              ;   < 2b < 2^31, and the signed
              bcs     61$                   ;   compares are unsigned ones
              cpy     ##0x8000              ;   (the loop 7$, the bits of cl
              bcs     61$                   ;   in D)
              lda     ##1
              tcd
              tya                           ; (a in A:X)
              jmp     long:fdLoop
7$:           cpx     .near TC_B            ; a >= b: a -= b and the bit is
              tay                           ;   1, else 0 (a in A:X; Y keeps
              sbc     .near (TC_B+2)        ;   its high word, then the one of
              bcc     71$                   ;   a - b)
              tay
              txa
              sbc     .near TC_B
              tax
              sec
71$:          tdc
              rol     a
              tcd
              bcs     72$
              txa                           ; a <<= 1, but not after the last
              asl     a                     ;   bit
              tax
              tya
              rol     a
              bra     7$
72$:          tay                           ; (ch << FRACBITS) | cl; the
              lda     ##.word0 _DirectPageStart ; direct page again
              tcd
              tya
              ldx     .near TC_CH
              rtl
              .space  PAD_FD                ; (the code after keeps its address)
61$:          lda     ##1                   ; cl: 16 bits
              sta     .near TC_CL
              bra     4$
8$:           lda     .near TC_CL           ; (ch << FRACBITS) | cl
              ldx     .near TC_CH
              rtl

;;; ---------------------------------------------------------------------------
;;; ivAxis: interceptVector3 of an axis line in a shot (IV_ON: the trace
;;; deltas have 11 zero low bits, |d| < 2^27) without the length m of the
;;; line (lineCross, jsl). A vertical line has num = m N, den = m D with N
;;; = (dl.x - trace.x) >> 8, D = trace.dx >> 8; a horizontal one N =
;;; (trace.y - dl.y) >> 8, D = -(trace.dy >> 8). For 0 < |m| <= 2047, |N|
;;; < |D| when N and D have one sign (fixedDiv: floor(|N| * 65536 / |D|)
;;; in its fast loop for both) and |N| < 2^20 when not (m N does not
;;; overflow), ivTest gives the same frac for 256 N and 256 D: dl.x -
;;; trace.x rounded down to 256 and trace.dx; for y both negated, dl.y -
;;; trace.y rounded up and trace.dy. A line at 45 degrees (a thing: its
;;; diagonal, traceThings), p = dl.dx >> 16, q = dl.dy >> 16 in whole units,
;;; |p| = |q| = m <= 1023: N = s_q N_x + s_p N_y, D = 8 (s_q M_x - s_p M_y);
;;; times s_p: 256 N = F_x + F_y, 256 D = trace.dx - trace.dy for p, q of one
;;; sign, else F_y - F_x and -trace.dx - trace.dy (F_x = dl.x - trace.x, F_y
;;; = trace.y - dl.y, rounded down to 256). Out: carry set and X:C = the
;;; frac, else carry clear (the old way).
;;; ---------------------------------------------------------------------------
              .section logiccode, text
ivAxis:       lda     long:IV_ON            ; a shot
              beq     9$
              lda     .near (TC_DX+2)       ; X = 0: vertical (dl.dx = 0), m =
              beq     1$                    ;   dl.dy; 4: horizontal (dl.dy = 0),
              ldx     .near (TC_DY+2)       ;   m = dl.dx
              bne     10$
              ldx     ##4
              bra     2$
1$:           tax
              lda     .near (TC_DY+2)
2$:           clc                           ; |m| <= 2047
              adc     ##2047
              cmp     ##4095
              bcs     9$
              lda     .near TC_X1,x         ; dl.o - trace.o (the low word of dl.o
              sec                           ;   is 0)
              sbc     .near TR_X,x
              tay
              lda     .near (TC_X1+2),x
              sbc     .near (TR_X+2),x
              sta     .near (TC_A+2)
              tya
              cpx     ##4                   ; rounded up for y
              bne     3$
              clc
              adc     ##255
              bcc     3$
              inc     .near (TC_A+2)
3$:           and     ##0xff00
              sta     .near TC_A
              lda     .near TR_DX,x         ; 256 D: trace.dx or trace.dy
              sta     .near TC_B
              lda     .near (TR_DX+2),x
              sta     .near (TC_B+2)
14$:          eor     .near (TC_A+2)        ; two signs: |256 N| < 2^28
              bpl     4$
              lda     .near (TC_A+2)
              clc
              adc     ##4096
              cmp     ##8192
              bcs     9$
              bra     5$
9$:           clc                           ; the old way
              rtl
4$:           lda     .near TC_A            ; one sign: N - D has the sign of -D
              sec                           ;   and is not 0
              sbc     .near TC_B
              tay
              lda     .near (TC_A+2)
              sbc     .near (TC_B+2)
              tax
              eor     .near (TC_B+2)
              bpl     9$
              txa
              bne     5$
              tya
              beq     9$
5$:           jsl     long:ivTest           ; the zeros, the signs, fixedDiv
              sec
              rtl
10$:          lda     .near TC_DX           ; 45 degrees: whole units, |p| = |q|
              ora     .near TC_DY           ;   <= 1023
              bne     9$
              lda     .near (TC_DX+2)
              bpl     11$
              eor     ##0xffff
              inc     a
11$:          cmp     ##1024
              bcs     9$
              sta     .near TC_T
              lda     .near (TC_DY+2)
              bpl     12$
              eor     ##0xffff
              inc     a
12$:          cmp     .near TC_T
              bne     9$
              lda     .near TC_X1           ; F_x in TC_A, F_y in TC_T
              sec
              sbc     .near TR_X
              and     ##0xff00
              sta     .near TC_A
              lda     .near (TC_X1+2)
              sbc     .near (TR_X+2)
              sta     .near (TC_A+2)
              lda     .near TR_Y
              sec
              sbc     .near TC_Y1
              and     ##0xff00
              sta     .near TC_T
              lda     .near (TR_Y+2)
              sbc     .near (TC_Y1+2)
              sta     .near (TC_T+2)
              lda     .near (TC_DX+2)       ; p, q of one sign: 256 N = F_x + F_y
              eor     .near (TC_DY+2)
              bmi     13$
              lda     .near TC_A
              clc
              adc     .near TC_T
              sta     .near TC_A
              lda     .near (TC_A+2)
              adc     .near (TC_T+2)
              sta     .near (TC_A+2)
              lda     .near TR_DX           ; 256 D = trace.dx - trace.dy
              sec
              sbc     .near TR_DY
              sta     .near TC_B
              lda     .near (TR_DX+2)
              sbc     .near (TR_DY+2)
              sta     .near (TC_B+2)
              brl     14$
13$:          lda     .near TC_T            ; two signs: 256 N = F_y - F_x
              sec
              sbc     .near TC_A
              sta     .near TC_A
              lda     .near (TC_T+2)
              sbc     .near (TC_A+2)
              sta     .near (TC_A+2)
              lda     ##0                   ; 256 D = -trace.dx - trace.dy
              sec
              sbc     .near TR_DX
              tax
              lda     ##0
              sbc     .near (TR_DX+2)
              tay
              txa
              sec
              sbc     .near TR_DY
              sta     .near TC_B
              tya
              sbc     .near (TR_DY+2)
              sta     .near (TC_B+2)
              brl     14$

;;; ---------------------------------------------------------------------------
;;; fdLoop: the loop 7$ of fixedDiv (a in A:X, 0 <= a < b < 2^30, the bits
;;; of cl in D above a start bit), two bits a step: the start bit leaves D
;;; only after the 16th bit, an even one, so the first bit of a step needs
;;; no test. The high words first: a.hi < b.hi gives 0 at once (more
;;; than half of the bits); for equal high words the low words decide.
;;; ---------------------------------------------------------------------------
              .section logiccode, text
fdLoop:
              cmp     .near (TC_B+2)
              bcc     1$
              beq     2$
3$:           tay                           ; a >= b: a -= b (C = 1)
              txa
              sbc     .near TC_B
              tax
              tya
              sbc     .near (TC_B+2)
1$:           tay
              tdc
              rol     a
              tcd
              txa                           ; a <<= 1
              asl     a
              tax
              tya
              rol     a
              cmp     .near (TC_B+2)
              bcc     4$
              beq     5$
6$:           tay                           ; a >= b: a -= b (C = 1)
              txa
              sbc     .near TC_B
              tax
              tya
              sbc     .near (TC_B+2)
4$:           tay
              tdc
              rol     a
              tcd
              bcs     9$
              txa
              asl     a
              tax
              tya
              rol     a
              bra     fdLoop
9$:           tay                           ; (ch << FRACBITS) | cl; the direct
              lda     ##.word0 _DirectPageStart ;   page again
              tcd
              tya
              ldx     .near TC_CH
              rtl
2$:           cpx     .near TC_B            ; equal high words: the low ones
              bcc     1$
              bra     3$
5$:           cpx     .near TC_B            ; equal high words: the low ones
              bcc     4$
              bra     6$

;;; ---------------------------------------------------------------------------
;;; addIntercept: add the intercept frac TC_T (>= 0) of the line or thing LD,
;;; with isaline = C. Out: C = 0 when the intercepts are full
;;; (check_intercept).
;;; ---------------------------------------------------------------------------
              .section logiccode, text
addIntercept: tax                           ; isaline
              lda     .near intercept_p     ; intercept_p - intercepts < MAXINTERCEPTS
              cmp     ##.word0 (intercepts + MAXINTERCEPTS * SIZEOF_IC)
              bcc     1$
              clc
              rtl
1$:           tay
              txa
              sta     abs:OFS_IC_ISALINE,y
              lda     .near TC_T
              sta     abs:OFS_IC_FRAC,y
              lda     .near (TC_T+2)
              sta     abs:(OFS_IC_FRAC+2),y
              lda     dp:.tiny LD
              sta     abs:OFS_IC_D,y
              lda     dp:.tiny (LD+2)
              sta     abs:(OFS_IC_D+2),y
              tya                           ; intercept_p++
              clc
              adc     ##SIZEOF_IC
              sta     .near intercept_p
              tya                           ; into the list by frac
              sec
              sbc     ##.near intercepts
              tay
              jsr     .kbank icInsert
              sec
              rtl

;;; icInsert: the intercept at offset Y into the list IC_NEXT, after all
;;; with a frac below or equal to its frac: P_TraverseIntercepts takes the
;;; nearest, the first of equal ones. The search starts after the last one
;;; into the list when its frac is not above (the new ones are mostly the
;;; far ones). MA is scratch.
icInsert:     lda     long:IC_LAST
              tax
              cpx     ##(MAXINTERCEPTS * SIZEOF_IC)
              beq     1$
              lda     .near (intercepts+OFS_IC_FRAC),y
              cmp     .near (intercepts+OFS_IC_FRAC),x
              lda     .near (intercepts+OFS_IC_FRAC+2),y
              sbc     .near (intercepts+OFS_IC_FRAC+2),x
              bvc     0$
              eor     ##0x8000
0$:           bpl     1$
              ldx     ##(MAXINTERCEPTS * SIZEOF_IC) ; X: the link (the head)
1$:           stx     dp:.tiny MA
              lda     long:IC_NEXT,x
              bmi     2$                    ; (the end)
              tax                           ; its frac < the next one: here
              lda     .near (intercepts+OFS_IC_FRAC),y
              cmp     .near (intercepts+OFS_IC_FRAC),x
              lda     .near (intercepts+OFS_IC_FRAC+2),y
              sbc     .near (intercepts+OFS_IC_FRAC+2),x
              bvc     3$
              eor     ##0x8000
3$:           bpl     1$
              txa
2$:           tyx
              sta     long:IC_NEXT,x
              tya
              sta     long:IC_LAST
              ldx     dp:.tiny MA
              sta     long:IC_NEXT,x
              rts
              .public icInsertL
icInsertL:    jsr     .kbank icInsert
              rtl

;;; longTrace: C = 1 if a component of the trace is beyond 16 units
;;; (P_PathTraverse keeps it in TR_LONG):
;;; dx > FRACUNIT*16 || dy > FRACUNIT*16 || dx < -FRACUNIT*16 || dy < -FRACUNIT*16
              .public longTrace
longTrace:    lda     ##0                   ; FRACUNIT*16 < dx
              cmp     .near TR_DX
              lda     ##0x10
              SLT32   .near (TR_DX+2)
              bmi     1$
              lda     ##0                   ; FRACUNIT*16 < dy
              cmp     .near TR_DY
              lda     ##0x10
              SLT32   .near (TR_DY+2)
              bmi     1$
              lda     .near TR_DX           ; dx < -FRACUNIT*16
              cmp     ##0
              lda     .near (TR_DX+2)
              SLT32   ##0xfff0
              bmi     1$
              lda     .near TR_DY           ; dy < -FRACUNIT*16
              cmp     ##0
              lda     .near (TR_DY+2)
              SLT32   ##0xfff0
              bmi     1$
              clc
              rtl
1$:           sec
              rtl

;;; sideSetup: the constants of SIDE1 for the trace. With DX = dx >> 16,
;;; DY = dy >> 16, a point X' = vx - (x >> 16) - cx, Y' = vy - (y >> 16) -
;;; cy (cx = 1 when the low word fx of x is not 0) and g = ceil(f / 256)
;;; - 256 * c, the product test of divlineSide is 256 * (Y' * DX - X' *
;;; DY) >= gy * DX - gx * DY. On the main axis (x when |DX| >= |DY|: main
;;; = Y', sub = X'; y: the other way) that is the sign of R = main - sub
;;; * s - k, s = minor / major, k = (g_main - g_sub * s) / 256, times the
;;; sign of the major (and -1 for y). SIDE1 finds L = 8 R with an error
;;; below 6: SQ = round(2048 s) (the error of sub * s is at most VRN /
;;; 4096), C = round(g_main / 32) - round(g_sub * SQ / 65536) (vsC).
;;; VT_INVB = 0x8000 when R > 0 is side 0 (x and DX > 0, y and DY < 0):
;;; the sides are 0x8000 * (side ^ inv), which only the two ends of a
;;; line or thing compare. VT_RR = 0 for a short trace
;;; (P_PointOnLineSide), when dx or dy is zero (axis-aligned traces use
;;; separate side tests), or |DX| + |DY| > 2900 (the full side-test products
;;; can overflow outside this range).
;;; ---------------------------------------------------------------------------
              .public sideSetup
sideSetup:    lda     .near PT_FLAGS        ; other flags than the last trace: the
              cmp     .near PT_FLP          ;   branches of the block loops
              beq     10$
              sta     .near PT_FLP
              jsl     long:ptPatch
10$:          lda     .near PT_FLAGS        ; the shots (with things): M of the
              and     ##CONST_PT_ADDTHINGS  ;   products of interceptVector3
              beq     0$
              jsl     long:ivSetup
0$:           sta     long:IV_ON
              lda     .near TR_LONG         ; (the short traces: P_PointOnLineSide)
              beq     9$
              lda     .near TR_DX
              ora     .near (TR_DX+2)
              beq     9$
              lda     .near TR_DY
              ora     .near (TR_DY+2)
              beq     9$
              lda     .near (TR_DX+2)       ; |DX| (TC_A) + |DY| (TC_B) <= 2900
              bpl     1$
              eor     ##0xffff
              inc     a
1$:           cmp     ##2901
              bcs     9$
              sta     .near TC_A
              lda     .near (TR_DY+2)
              bpl     2$
              eor     ##0xffff
              inc     a
2$:           sta     .near TC_B
              clc                           ; (|DX| <= 2900: no carry)
              adc     .near TC_A
              cmp     ##2901
              bcs     9$
              lda     .near TR_X            ; VT_OXC, VT_OYC (none at 0x7fff
              cmp     ##1                   ;   with a fraction)
              lda     .near (TR_X+2)
              adc     ##0
              bvs     9$
              sta     long:VT_OXC
              lda     .near TR_Y
              cmp     ##1
              lda     .near (TR_Y+2)
              adc     ##0
              bvc     4$
9$:           stz     .near VT_RR
              rtl
4$:           sta     long:VT_OYC
              lda     .near (TR_DX+2)       ; VT_SGN
              eor     .near (TR_DY+2)
              sta     long:VT_SGN
              ldx     ##0                   ; the main axis: X = 0 x (|DX| >=
              lda     .near TC_A            ;   |DY|), 4 y; the major one in C,
              ldy     .near TC_B            ;   the minor one in Y
              cpy     .near TC_A
              bcc     5$
              beq     5$
              ldx     ##4
              tya
              ldy     .near TC_A
5$:           stx     .near TC_T
              sta     .near (TC_T+2)
              tya                           ; floor(4096 minor / major): 13 steps
              ldy     ##0x0008              ;   of a long division, the bits into
6$:           cmp     .near (TC_T+2)        ;   Y above a start bit that ends them
              bcc     61$
              sbc     .near (TC_T+2)
61$:          tax
              tya
              rol     a
              tay
              txa
              bcs     62$
              asl     a
              bra     6$
62$:          tya                           ; SQ = round(2048 minor / major) in
              inc     a                     ;   TC_X, negative for dx ^ dy < 0
              lsr     a
              tax
              lda     .near (TR_DX+2)
              eor     .near (TR_DY+2)
              bpl     63$
              txa
              eor     ##0xffff
              inc     a
              tax
63$:          stx     .near TC_X
              lda     .near TR_Y            ; g of y (TC_A) and x (TC_B)
              jsr     .kbank gOf
              sta     .near TC_A
              lda     .near TR_X
              jsr     .kbank gOf
              sta     .near TC_B
              jsr     .kbank vsC            ; VT_CV, VT_CT
              lda     .near TC_X            ; VT_P1 = 2 SQ + 512 VJ, VT_P2 = 4 SQ
              asl     a
              tax
              clc
              adc     ##(512 * VJ)
              sta     long:VT_P1
              txa
              asl     a
              sta     long:VT_P2
              ldx     .near TC_T            ; VT_INVB: bit 15 of ~DX for x, of DY
              txa                           ;   for y
              sec
              sbc     ##4
              eor     .near (TR_DX+2),x
              and     ##0x8000
              sta     long:VT_INVB
              eor     .near (TR_DY+2)       ; VT_DYF
              sta     long:VT_DYF
              jsl     long:vsPatch          ; the pair of SIDE1 for the axis X
              sta     .near VT_RR           ; (the pair: not 0)
              rtl
              .space  PAD_SS                ; (gOf and smul: in the fragment of
                                            ;   traceLines)

;;; ---------------------------------------------------------------------------
;;; boolean PIT_AddLineIntercepts(line_t __far* ld)   In: _Dp[0-3]. Out: C.
;;; For the traces without the fast sides: P_PathTraverse uses traceLines
;;; for the others.
;;; ---------------------------------------------------------------------------
              .section logiccode, text
              .public PIT_AddLineIntercepts
PIT_AddLineIntercepts:
              pei     dp:.tiny LD
              pei     dp:.tiny (LD+2)
              lda     dp:.tiny _Dp
              sta     dp:.tiny LD
              lda     dp:.tiny (_Dp+2)
              sta     dp:.tiny (LD+2)
              lda     .near TR_LONG         ; (longTrace of the trace)
              beq     10$
              ldy     ##OFS_LINE_V1         ; s1, s2 with P_PointOnDivlineSide
              jsl     long:vtxSlowL
              sta     .near TC_S1
              ldy     ##OFS_LINE_V2
              jsl     long:vtxSlowL
              bra     20$

              ;; s1 = P_PointOnLineSide(trace.x, trace.y, ld)
10$:          lda     .near TR_Y
              sta     dp:.tiny _Dp
              lda     .near (TR_Y+2)
              sta     dp:.tiny (_Dp+2)
              lda     dp:.tiny LD
              sta     dp:.tiny (_Dp+4)
              lda     dp:.tiny (LD+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near TR_X
              ldx     .near (TR_X+2)
              jsl     long:P_PointOnLineSide
              sta     .near TC_S1
              ;; s2 = P_PointOnLineSide(trace.x + trace.dx, trace.y + trace.dy, ld)
              lda     .near TR_Y
              clc
              adc     .near TR_DY
              sta     dp:.tiny _Dp
              lda     .near (TR_Y+2)
              adc     .near (TR_DY+2)
              sta     dp:.tiny (_Dp+2)
              lda     dp:.tiny LD
              sta     dp:.tiny (_Dp+4)
              lda     dp:.tiny (LD+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near TR_X
              clc
              adc     .near TR_DX
              tay
              lda     .near (TR_X+2)
              adc     .near (TR_DX+2)
              tax
              tya
              jsl     long:P_PointOnLineSide

20$:          cmp     .near TC_S1           ; s1 == s2: the line isn't crossed
              beq     90$
              jsl     long:lineCrossL
              bra     91$
90$:          lda     ##1
91$:          tax
              pla
              sta     dp:.tiny (LD+2)
              pla
              sta     dp:.tiny LD
              txa
              rtl

;;; MIDDIFF: C = bits 8..23 of sq(X / 2) - bits 8..23 of sq(Y / 2), mod
;;; 65536 (each square truncated, as the bytes of SQL and SQH), from the
;;; middle words of SQMID (sqmInit); destroys X.
MIDDIFF       .macro
              lda     long:SQMID,x
              tyx
              sec
              sbc     long:SQMID,x
              .endm

;;; SIDE1 fail, pt, cst, lim, done: the side of a point from X' and Y' (X
;;; and Y: the high words of its x and y minus VT_OXC, VT_OYC) as 0x8000 *
;;; (side ^ inv) in C, then to done; to fail when this way cannot tell.
;;; Test the signs first. Otherwise L = 8 main - (sub + V2) * SQ /
;;; 256 - C (sideSetup: cst = C - VJ * SQ - lim / 2) from the quarter
;;; squares at 2 (sub + V2 + SQ) and 4 SQ less, for |X'|, |Y'| <= VRN: the
;;; side from bit 15 of L + lim / 2 unless it is below lim. At pt the pair
;;; that picks sub and main (txa, sty for x; tya, stx for y: vsPatch).
;;; Any data bank; the temporaries are MA and MB (src/iigs/m_fixed65.s).
SIDE1         .macro  fail, pt, cst, lim, done
              tya                           ; (dy ^ dx ^ x ^ y) < 0: the side of
              eor     long:VT_SGN           ;   the side is (dy ^ x) < 0
              bmi     1$
              txa
              bmi     2$
              bra     3$
1$:           txa
              bmi     3$
2$:           eor     long:VT_DYF
              and     ##0x8000
              bra     \done
3$:           txa                           ; |X'|, |Y'| <= VRN
              clc
              adc     ##VRN
              cmp     ##(2 * VRN + 1)
              bcs     \fail
              tya
              clc
              adc     ##VRN
              cmp     ##(2 * VRN + 1)
              bcs     \fail
\pt:          txa                           ; sub; main into MA
              sty     dp:.tiny MA
              asl     a                     ; the quarter squares at 2 (sub + V2 +
              clc                           ;   SQ) and 4 SQ less
              adc     long:VT_P1
              tax
              sec
              sbc     long:VT_P2
              tay
              MIDDIFF
              sta     dp:.tiny MB
              lda     dp:.tiny MA           ; L + lim / 2 = 8 main - that - cst
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny MB
              sec
              sbc     long:\cst
              cmp     ##\lim
              bcs     8$
              brl     \fail
8$:           and     ##0x8000
              .endm

;;; VSIDE ofs, fail, pt, done: SIDE1 for the vertex at ofs of the line X
;;; (the data bank: the lines).
VSIDE         .macro  ofs, fail, pt, done
              lda     abs:(\ofs+2),x        ; Y' = vy - (y >> 16) - cy
              sec
              sbc     long:VT_OYC
              bvs     \fail
              tay
              lda     abs:\ofs,x            ; the same for x
              sec
              sbc     long:VT_OXC
              bvs     \fail
              tax
              SIDE1   \fail, \pt, VT_CV, (2 * VBV + 1), \done
              .endm

;;; ---------------------------------------------------------------------------
;;; traceLines: P_BlockLinesIterator(x, y, PIT_AddLineIntercepts) of a long
;;; trace with the fast sides (VT_RR != 0, P_PathTraverse): the same lines,
;;; validcounts and intercepts. The lines are in the data bank (abs,X), so a
;;; line of the trace before costs no store; the list is in TL_LS, the
;;; position and the line at _Dp[0-3]. In: C = x, _Dp[0-1] = y.
;;; Out: C (0: the intercepts are full). TL_LS and LD change (P_PathTraverse
;;; keeps _Dp[8-15] for its caller).
;;; ---------------------------------------------------------------------------
              .section logiccode, text
              .public traceLines
traceLines:   tax                           ; 0 <= x < _g_bmapwidth
              bmi     tlNone
              cmp     .near _g_bmapwidth
              bpl     tlNone
              lda     dp:.tiny _Dp          ; 0 <= y < _g_bmapheight
              bmi     tlNone
              cmp     .near _g_bmapheight
              bmi     tlGo
tlNone:       lda     ##1
              rtl
tlGo:         asl     a                     ; Y = 2 * (y * width + x) (BMROW)
              txy
              tax
              tya
              clc
              adc     long:BMROW,x
              asl     a
              tay
              lda     .near _g_blockmap     ; the list: _g_blockmaplump + 2 *
              sta     dp:.tiny TL_LS        ;   _g_blockmap[...] (the same
              lda     .near (_g_blockmap+2) ;   lump)
              sta     dp:.tiny (TL_LS+2)
              lda     [.tiny TL_LS],y
              asl     a
              clc
              adc     .near _g_blockmaplump
              sta     dp:.tiny TL_LS
              lda     .near (_g_lines+2)
              sta     dp:.tiny (LD+2)
              phb                           ; (0: for the calls)
              xba                           ; the data bank: the lines (the high
              pha                           ;   byte of the word; no SEP and REP)
              plb
              plb
              ldy     ##2                   ; after the 0
tlLoop:       lda     [.tiny TL_LS],y
              cmp     ##0xffff
              beq     tlEnd
              asl     a
              tax
              lda     long:LN36,x
              tax
              lda     abs:OFS_LINE_VALIDCOUNT,x ; checked already
              cmp     long:validcount
              bne     tlNew
tlNext:       iny
              iny
              bra     tlLoop
tlEnd:        ldx     ##1
tlOut:        plb
              txa
              rtl
              .space  PAD_TL                ; (the fragment keeps its size)
tlF1:         brl     tlSlow1

tlNew:        lda     long:validcount       ; its stamp: a word store, no SEP
              sta     abs:OFS_LINE_VALIDCOUNT,x ;   and REP (a bus cycle each)
              lda     long:G_IDT            ; its sides from the count of
              sty     dp:.tiny _Dp          ;   guard with the sides (gBlockT)?
              stx     dp:.tiny (_Dp+2)      ; (the position and the line)
              beq     tlV1
              lda     [.tiny TL_LS],y
              asl     a
              tax
              lda     long:GSTAMP,x
              eor     long:G_IDT
              cmp     ##0x8000
              bne     tlV00
              brl     tlSame                ; not crossed
tlV00:        cmp     ##0x4000
              bne     tlV0
              brl     tlCross               ; crossed
tlV0:         ldx     dp:.tiny (_Dp+2)
tlV1:         VSIDE   OFS_LINE_V1, tlF1, tlP1, tlS1 ; s1
tlS1:         sta     long:TC_S1
              ldx     dp:.tiny (_Dp+2)
              bra     tlV2
tlF2:         brl     tlSlow2
tlV2:         VSIDE   OFS_LINE_V2, tlF2, tlP2, tlS2 ; s2
tlS2:         cmp     long:TC_S1            ; s1 == s2: not crossed
              beq     tlSame
tlCross:      lda     dp:.tiny (_Dp+2)      ; the intercept, with the data
              sta     dp:.tiny LD           ;   bank 0 and the position on the
              plb                           ;   stack (the calls use _Dp)
              phb
              pei     dp:.tiny _Dp
              jsr     .kbank lineCross
              ply
              tax
              lda     dp:.tiny (LD+1)       ; the data bank again (the high byte)
              pha
              plb
              plb
              txa
              bne     tlCont
              brl     tlOut                 ; full: false (X = 0)
              .space  3                     ; (the code after keeps its address)
tlSame:       ldy     dp:.tiny _Dp
tlCont:       brl     tlNext

;;; TLSLOW ofs: C = vtxSlowR of the vertex at ofs of the line at _Dp[2-3],
;;; with the data bank 0 for it (the byte on top of the stack).
TLSLOW        .macro  ofs
              lda     dp:.tiny (_Dp+2)
              sta     dp:.tiny LD
              plb
              phb
              ldy     ##\ofs
              jsr     .kbank vtxSlowR
              tax
              lda     dp:.tiny (LD+1)       ; the data bank: the lines (the high
              pha                           ;   byte; no SEP and REP)
              plb
              plb
              txa
              .endm

;;; tlSlow1, tlSlow2: vertex 1 or 2 of the line with vtxSlow.
tlSlow1:      TLSLOW  OFS_LINE_V1
              brl     tlS1
tlSlow2:      TLSLOW  OFS_LINE_V2
              brl     tlS2

;;; vtxSlow: divlineSide of the vertex Y of the line LD (data bank 0).
vtxSlow:      lda     [.tiny LD],y
              sta     .near (TC_X+2)
              iny
              iny
              lda     [.tiny LD],y
              sta     .near (TC_Y+2)
              stz     .near TC_X
              stz     .near TC_Y
              jsl     long:divlineSide
              rts
vtxSlowL:     jsr     .kbank vtxSlow
              rtl
;;; vtxSlowR: vtxSlow as 0x8000 * (side ^ inv) (SIDE1).
vtxSlowR:     jsr     .kbank vtxSlow
              lsr     a
              lda     ##0
              ror     a
              eor     long:VT_INVB
              rts

;;; lineCross: the intercept of the line LD, crossed by the trace
;;; (P_MakeDivline, P_InterceptVector3, addIntercept; data bank 0). Out: C
;;; = 0 when the intercepts are full, else 1.
lineCross:    stz     .near TC_X1
              stz     .near TC_Y1
              stz     .near TC_DX
              stz     .near TC_DY
              ldy     ##OFS_LINE_V1
              lda     [.tiny LD],y
              sta     .near (TC_X1+2)
              iny
              iny
              lda     [.tiny LD],y
              sta     .near (TC_Y1+2)
              ldy     ##OFS_LINE_DX
              lda     [.tiny LD],y
              sta     .near (TC_DX+2)
              ldy     ##OFS_LINE_DY
              lda     [.tiny LD],y
              sta     .near (TC_DY+2)
              jsl     long:ivAxis           ; an axis line of a shot
              bcs     3$
              jsl     long:interceptVector3 ; frac
3$:           sta     .near TC_T
              stx     .near (TC_T+2)
              txa                           ; frac < 0: behind the source
              bmi     1$
              lda     ##1
              jsl     long:addIntercept
              bcs     1$
              lda     ##0
              rts
1$:           lda     ##1
              rts
lineCrossL:   jsr     .kbank lineCross
              rtl

;;; gOf: C = g = ceil(f / 256) - 256 * (f != 0) for the fraction f in C
;;; (sideSetup).
gOf:          cmp     ##0
              beq     1$
              dec     a                     ; ((f - 1) >> 8) + 1 - 256
              xba
              and     ##0x00ff
              sec
              sbc     ##255
1$:           rts

;;; smul: X:C = C * X, signed 16 x 16: the unsigned product, minus
;;; b << 16 for a < 0 and a << 16 for b < 0 (sideSetup).
smul:         sta     dp:.tiny MA
              stx     dp:.tiny MB
              jsl     long:umul16
              lda     dp:.tiny (MR+2)
              ldx     dp:.tiny MA
              bpl     1$
              sec
              sbc     dp:.tiny MB
1$:           ldx     dp:.tiny MB
              bpl     2$
              sec
              sbc     dp:.tiny MA
2$:           tax
              lda     dp:.tiny MR
              rts

;;; vsC: VT_CV and VT_CT of SIDE1 (sideSetup), from SQ (TC_X), the axis
;;; (TC_T) and g of y and x (TC_A, TC_B): C = round(g_main / 32) -
;;; round(g_sub * SQ / 65536), each half up (an error below 1: SIDE1
;;; allows it), VT_CV = C - VJ * SQ - VBV, VT_CT = -VJ * SQ - VBTH.
vsC:          lda     .near TC_T            ; g_sub * SQ, rounded: + bit 15 of
              eor     ##4                   ;   its low word
              tax
              lda     .near TC_A,x
              ldx     .near TC_X
              jsr     .kbank smul
              asl     a
              txa
              adc     ##0
              sta     .near TC_Y
              ldx     .near TC_T            ; C - VBV: ((g_main + 272) >> 5) - 8
              lda     .near TC_A,x          ;   - that - VBV
              clc
              adc     ##272
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              sec
              sbc     .near TC_Y
              sec
              sbc     ##(8 + VBV)
              sta     .near TC_Y
              lda     .near TC_X            ; VJ * SQ, the low word
              sta     dp:.tiny MA
              lda     ##VJ
              sta     dp:.tiny MB
              jsl     long:umul16lo
              tax
              eor     ##0xffff              ; VT_CT = -VJ SQ - VBTH
              sec
              sbc     ##(VBTH - 1)
              sta     long:VT_CT
              txa                           ; VT_CV = C - VBV - VJ SQ
              eor     ##0xffff
              sec
              adc     .near TC_Y
              sta     long:VT_CV
              rts
              .space  36                    ; (the fragment keeps its size)

;;; ---------------------------------------------------------------------------
;;; boolean traceThings: P_BlockThingsIterator(x, y, PIT_AddThingIntercepts)
;;; of P_PathTraverse (src/iigs/p_path65.s): the things of block (x, y) in
;;; their order, the thing in LD (P_PathTraverse keeps it for its caller),
;;; first with the fast sides (thFast). In: C = x, _Dp[0-1] = y. Out: C (0:
;;; the intercepts are full).
;;; ---------------------------------------------------------------------------
              .section logiccode, text
              .public traceThings
traceThings:  tax                           ; 0 <= x < _g_bmapwidth
              bmi     11$
              cmp     .near _g_bmapwidth
              bpl     11$
              lda     dp:.tiny _Dp          ; 0 <= y < _g_bmapheight
              bmi     11$
              cmp     .near _g_bmapheight
              bmi     12$
11$:          lda     ##1
              rtl
12$:          asl     a                     ; Y = 4 * (y * width + x) (BMROW)
              txy
              tax
              tya
              clc
              adc     long:BMROW,x
              asl     a
              asl     a
              tay
              lda     .near _g_blocklinks   ; the first thing
              sta     dp:.tiny _Dp
              lda     .near (_g_blocklinks+2)
              sta     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp],y
              tax
              iny
              iny
              lda     [.tiny _Dp],y
              bra     4$
8$:           ldx     ##1                   ; the end: true
9$:           txa
              rtl
              .space  10                    ; (the code after keeps its address)
5$:           ldy     ##OFS_MO_BNEXT        ; the next thing
              lda     [.tiny LD],y
              tax
              ldy     ##(OFS_MO_BNEXT+2)
              lda     [.tiny LD],y
4$:           and     ##0x00ff              ; LD = the thing (bank 0: none)
              beq     8$
              sta     dp:.tiny (LD+2)
              stx     dp:.tiny LD
              jsr     .kbank thFast         ; the fast sides: 0 not crossed,
              cmp     ##1                   ;   1 crossed (X = 1), 2 the sides
              bcc     5$                    ;   below (X = 0)
              and     ##1
              tax

              ;; dl = {x1, y1, 2 * radius, -+2 * radius}: the corners x1 =
              ;; x - radius, y1 and x2 = x + radius, y2 (trace.dx ^ trace.dy
              ;; > 0: y1 = y + radius, y2 = y - radius; else y1 = y - radius,
              ;; y2 = y + radius); x2 - x1 and y2 - y1 in 32 bits
61$:          ldy     ##OFS_MO_RADIUS       ; dl.dx = 2 * radius
              lda     [.tiny LD],y
              asl     a
              sta     .near TC_DX
              iny
              iny
              lda     [.tiny LD],y
              rol     a
              sta     .near (TC_DX+2)
              ldy     ##OFS_MO_X            ; x1 = x - radius
              lda     [.tiny LD],y
              sec
              ldy     ##OFS_MO_RADIUS
              sbc     [.tiny LD],y
              sta     .near TC_X1
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny LD],y
              ldy     ##(OFS_MO_RADIUS+2)
              sbc     [.tiny LD],y
              sta     .near (TC_X1+2)
              lda     .near (TR_DX+2)       ; trace.dx ^ trace.dy > 0?
              eor     .near (TR_DY+2)
              bmi     2$
              bne     1$
              lda     .near TR_DX
              eor     .near TR_DY
              beq     2$
1$:           ldy     ##OFS_MO_Y            ; yes: y1 = y + radius, dl.dy =
              lda     [.tiny LD],y          ;   -dl.dx
              clc
              ldy     ##OFS_MO_RADIUS
              adc     [.tiny LD],y
              sta     .near TC_Y1
              ldy     ##(OFS_MO_Y+2)
              lda     [.tiny LD],y
              ldy     ##(OFS_MO_RADIUS+2)
              adc     [.tiny LD],y
              sta     .near (TC_Y1+2)
              lda     ##0
              sec
              sbc     .near TC_DX
              sta     .near TC_DY
              lda     ##0
              sbc     .near (TC_DX+2)
              sta     .near (TC_DY+2)
              bra     3$
2$:           ldy     ##OFS_MO_Y            ; no: y1 = y - radius, dl.dy = dl.dx
              lda     [.tiny LD],y
              sec
              ldy     ##OFS_MO_RADIUS
              sbc     [.tiny LD],y
              sta     .near TC_Y1
              ldy     ##(OFS_MO_Y+2)
              lda     [.tiny LD],y
              ldy     ##(OFS_MO_RADIUS+2)
              sbc     [.tiny LD],y
              sta     .near (TC_Y1+2)
              lda     .near TC_DX
              sta     .near TC_DY
              lda     .near (TC_DX+2)
              sta     .near (TC_DY+2)

              ;; s1 = P_PointOnDivlineSide(x1, y1, &trace)
3$:           txa
              bne     20$
              ldx     ##6                   ; TC_X, TC_Y = x1, y1
31$:          lda     .near TC_X1,x
              sta     .near TC_X,x
              dex
              dex
              bpl     31$
              jsl     long:divlineSide
              sta     .near TC_S1
              ;; s2 = P_PointOnDivlineSide(x2, y2, &trace): x1 + dl.dx, y1 +
              ;; dl.dy
              lda     .near TC_X1
              clc
              adc     .near TC_DX
              sta     .near TC_X
              lda     .near (TC_X1+2)
              adc     .near (TC_DX+2)
              sta     .near (TC_X+2)
              lda     .near TC_Y1
              clc
              adc     .near TC_DY
              sta     .near TC_Y
              lda     .near (TC_Y1+2)
              adc     .near (TC_DY+2)
              sta     .near (TC_Y+2)
              jsl     long:divlineSide
              cmp     .near TC_S1           ; s1 == s2: not crossed
              beq     55$
20$:          jsl     long:ivAxis           ; a shot: the diagonal without its
              bcs     21$                   ;   length
              jsl     long:interceptVector3 ; frac
21$:          sta     .near TC_T
              stx     .near (TC_T+2)
              txa                           ; frac < 0: behind the source
              bmi     55$
              lda     ##0
              jsl     long:addIntercept
              bcs     55$
              ldx     ##0                   ; full: false
              brl     9$
55$:          brl     5$                    ; the next thing
              .space  PAD_TT                ; (the code after keeps its address)

;;; thFast: the sides of the corners of the thing LD (thSide): C = 0 not
;;; crossed, 1 crossed, 2 this way cannot tell.
thUnk:        lda     ##2                   ; this way cannot tell
              rts
thFast:       lda     .near VT_RR           ; for a whole radius R: the high
              beq     thUnk                    ;   words of the corners are those
              ldy     ##OFS_MO_RADIUS       ;   of the center +- R
              lda     [.tiny LD],y
              bne     thUnk
              iny
              iny
              lda     [.tiny LD],y
              sta     .near TC_T
              ldy     ##OFS_MO_Y            ; (y - trace.y) >> 16 in X for now
              lda     [.tiny LD],y
              sec
              sbc     .near TR_Y
              iny
              iny
              lda     [.tiny LD],y
              sbc     .near (TR_Y+2)
              bvs     thUnk
              tax
              ldy     ##OFS_MO_X            ; (x - trace.x) >> 16 in Y for now
              lda     [.tiny LD],y
              sec
              sbc     .near TR_X
              iny
              iny
              lda     [.tiny LD],y
              sbc     .near (TR_X+2)
              bvs     thUnk
              tay
              lda     .near (TR_DX+2)       ; y1 = y + r when (dx ^ dy) > 0,
              eor     .near (TR_DY+2)       ;   else y - r; y2 in TC_B
              bmi     42$
              bne     41$
              lda     .near TR_DX
              eor     .near TR_DY
              beq     42$
41$:          txa
              sec
              sbc     .near TC_T
              sta     .near TC_B
              txa
              clc
              adc     .near TC_T
              bra     43$
42$:          txa
              clc
              adc     .near TC_T
              sta     .near TC_B
              txa
              sec
              sbc     .near TC_T
43$:          tax
              tya                           ; x2 = x + r in TC_A
              clc
              adc     .near TC_T
              sta     .near TC_A
              tya                           ; x1 = x - r
              sec
              sbc     .near TC_T
              txy
              tax
              jsr     .kbank thSide         ; s1
              bcs     1$
              sta     .near TC_S1
              ldx     .near TC_A            ; s2
              ldy     .near TC_B
              jsr     .kbank thSide
              bcs     1$
              eor     .near TC_S1           ; 0 or 0x8000: 0 or 1
              asl     a
              rol     a
              rts
1$:           lda     ##2
              rts
thFastL:      jsr     .kbank thFast
              rtl

;;; thSide: SIDE1 of a corner of a thing (the high words of its x and y
;;; minus those of the trace start in X and Y) with C = 0; C = 1 when
;;; this way cannot tell.
thNo:         sec
              rts
thSide:       SIDE1   thNo, thP, VT_CT, (VBTL + VBTH + 1), thDone
thDone:       clc
              rts
              .space  PAD_TS                ; (the fragment keeps its size)

;;; ---------------------------------------------------------------------------
;;; gBlockT: the second walk of guard (src/iigs/p_path65.s): G_N -=
;;; SIZEOF_IC for each line of block (G_MX, G_MY) not counted yet in this
;;; run that is collected already or that the trace does not cross (its
;;; sides), and for each thing that the trace does not cross; gBlock
;;; counted all of them in the first walk.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public gBlockT
gBlockT:      lda     .near G_MX            ; 0 <= x < _g_bmapwidth
              bmi     gtOut
              cmp     .near _g_bmapwidth
              bpl     gtOut
              lda     .near G_MY            ; 0 <= y < _g_bmapheight
              bmi     gtOut
              cmp     .near _g_bmapheight
              bmi     gtGo
gtOut:        rtl
gtGo:         asl     a                     ; y * _g_bmapwidth + x (BMROW)
              tax
              lda     long:BMROW,x
              clc
              adc     .near G_MX
              sta     .near G_OFS
ptT1:         .byte   0x80, 6, gtLines-(ptT1+2), 6 ; PT_ADDLINES (ptPatch)
              .space  4
              brl     gtThings
gtLines:      lda     .near _g_blockmap     ; the list, after its 0
              sta     dp:.tiny _Dp
              lda     .near (_g_blockmap+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near G_OFS
              asl     a
              tay
              lda     [.tiny _Dp],y
              asl     a
              clc
              adc     .near _g_blockmaplump
              sta     dp:.tiny _Dp
              lda     .near (_g_blockmaplump+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near (_g_lines+1)    ; the lines in the data bank (the
              phb                           ;   high byte; no SEP and REP)
              pha
              plb
              plb
              ldy     ##2
gtLoop:       lda     [.tiny _Dp],y
              cmp     ##0xffff
              bne     gtLine
              plb
              brl     gtThings
              .space  3                     ; (the code after keeps its address)
gtColl:       lda     long:G_N              ; collected already: one less
              sec
              sbc     ##SIZEOF_IC
              sta     long:G_N
gtSkip:       iny
              iny
              bra     gtLoop
gtLine:       asl     a                     ; counted before in this run?
              tax                           ;   (bit 15: not crossed, bit 14:
              lda     long:GSTAMP,x         ;   crossed)
              and     ##0x3fff
              cmp     long:G_ID
              beq     gtSkip
              lda     long:G_ID
              sta     long:GSTAMP,x
              stx     dp:.tiny MR           ; (its stamp)
              lda     long:LN36,x           ; collected before?
              tax
              lda     abs:OFS_LINE_VALIDCOUNT,x
              cmp     long:validcount
              beq     gtColl
              sty     dp:.tiny (_Dp+4)      ; crossed? (the position and the
              stx     dp:.tiny (_Dp+6)      ;   line)
              bra     gtV1
gtF1:         brl     gtNext
gtV1:         VSIDE   OFS_LINE_V1, gtF1, gtP1, gtS1
gtS1:         sta     long:TC_S1
              ldx     dp:.tiny (_Dp+6)
              bra     gtV2
gtF2:         brl     gtNext
gtV2:         VSIDE   OFS_LINE_V2, gtF2, gtP2, gtS2
gtS2:         cmp     long:TC_S1
              bne     gtCross
              ldx     dp:.tiny MR           ; not crossed: bit 15 of its
              lda     long:G_ID             ;   stamp for traceLines, and one
              ora     ##0x8000              ;   less
              sta     long:GSTAMP,x
              lda     long:G_N
              sec
              sbc     ##SIZEOF_IC
              sta     long:G_N
              bra     gtNext
gtCross:      ldx     dp:.tiny MR           ; crossed: bit 14 of its stamp
              lda     long:G_ID
              ora     ##0x4000
              sta     long:GSTAMP,x
gtNext:       ldy     dp:.tiny (_Dp+4)
              iny
              iny
              brl     gtLoop

gtThings:
ptT2:         .byte   0x80, gtDone-(ptT2+2), 6, gtDone-(ptT2+2) ; the things of the block (LD)
              .space  4
              pei     dp:.tiny LD
              pei     dp:.tiny (LD+2)
              lda     .near _g_blocklinks
              sta     dp:.tiny _Dp
              lda     .near (_g_blocklinks+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near G_OFS
              asl     a
              asl     a
              tay
              lda     [.tiny _Dp],y
              sta     dp:.tiny LD
              iny
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (LD+2)
gtTh:         lda     dp:.tiny LD
              ora     dp:.tiny (LD+2)
              beq     gtThEnd
              jsl     long:thFastL          ; not crossed: one less
              cmp     ##0
              bne     gtThNext
              lda     .near G_N
              sec
              sbc     ##SIZEOF_IC
              sta     .near G_N
gtThNext:     ldy     ##(OFS_MO_BNEXT+2)
              lda     [.tiny LD],y
              tax
              ldy     ##OFS_MO_BNEXT
              lda     [.tiny LD],y
              sta     dp:.tiny LD
              stx     dp:.tiny (LD+2)
              bra     gtTh
gtThEnd:      pla
              sta     dp:.tiny (LD+2)
              pla
              sta     dp:.tiny LD
gtDone:       rtl

;;; vsPatch: the pair of SIDE1 at each of its places for the axis X (0: x,
;;; txa and sty; 4: y, tya and stx), for sideSetup. Out: C = the pair.
vsPatch:      lda     ##0x848a
              cpx     ##4
              bne     1$
              lda     ##0x8698
1$:           sta     long:tlP1
              sta     long:tlP2
              sta     long:gtP1
              sta     long:gtP2
              sta     long:thP
              rtl

;;; sqmInit: SQMID from SQL and SQH (byte 1 of the low word and byte 0 of
;;; the high word of each square), in MM_VIEWSAVE: again after the menu,
;;; which saves the view there. sqmFlood: it, then P_InitFlood, at each
;;; level load (src/iigs/p_sight65.s).
              .public sqmInit
sqmInit:      rep     #0x30                 ; (any widths: the menu calls it)
              ldx     ##(2 * SQM_LO)
1$:           sep     #0x20
              lda     long:SQH,x
              xba
              lda     long:(SQL+1),x
              rep     #0x20
              sta     long:SQMID,x
              inx
              inx
              cpx     ##(2 * SQM_HI + 2)
              bcc     1$
              rtl
              .public sqmFlood
sqmFlood:     jsl     long:sqmInit
              jmp     long:P_InitFlood

;;; ptPatch: the branches of the tests of PT_FLAGS in the block loops (the
;;; sites ptL1.. of src/iigs/p_path65.s, ptT1, ptT2): the offset at + 2 for
;;; the flag set, + 3 for it clear, into + 1. In: C = PT_FLAGS (sideSetup).
ptPatch:      sep     #0x20
              ldx     ##3                   ; PT_ADDLINES
              lsr     a
              bcc     1$
              ldx     ##2
1$:           lda     long:ptL1,x
              sta     long:(ptL1+1)
              lda     long:ptG1,x
              sta     long:(ptG1+1)
              lda     long:ptT1,x
              sta     long:(ptT1+1)
              ldx     ##3                   ; PT_ADDTHINGS
              lda     .near PT_FLAGS
              and     #CONST_PT_ADDTHINGS
              beq     2$
              ldx     ##2
2$:           lda     long:ptL2,x
              sta     long:(ptL2+1)
              lda     long:ptL3,x
              sta     long:(ptL3+1)
              lda     long:ptG2,x
              sta     long:(ptG2+1)
              lda     long:ptT2,x
              sta     long:(ptT2+1)
              rep     #0x20
              rtl
              .space  PAD_GT                ; (the fragment keeps its size)

;;; ivSetup: for a shot, M = d >> 11 of each delta d of the trace (X = 4:
;;; dy, 0: dx) into IV_ML, IV_MH for ivProd, when the 11 low bits of d are
;;; 0 and M is in -65536..65535 (the high word H of d in -2048..2047).
;;; Out: A = 0 when a delta has no M (IV_ON).
              .section coldcode, text
ivSetup:      ldx     ##4
1$:           lda     .near TR_DX,x         ; the low 11 bits 0?
              and     ##0x07ff
              bne     8$
              lda     .near (TR_DX+2),x     ; H in -2048..2047?
              clc
              adc     ##0x0800
              cmp     ##0x1000
              bcs     8$
              lda     .near TR_DX,x         ; ML = (H << 5) | (L >> 11)
              xba
              and     ##0x00ff
              lsr     a
              lsr     a
              lsr     a
              sta     long:IV_ML,x
              lda     .near (TR_DX+2),x
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              ora     long:IV_ML,x
              sta     long:IV_ML,x
              lda     .near (TR_DX+2),x     ; MH = 0 or -1: the sign of H
              asl     a
              lda     ##0
              bcc     2$
              dec     a
2$:           sta     long:IV_MH,x
              dex
              dex
              dex
              dex
              bpl     1$
              lda     ##1
              rtl
8$:           lda     ##0                   ; (no fast path)
              rtl

              .section znear, bss
              .public intercepts, intercept_p, _g_trace
intercepts:   .space  MAXINTERCEPTS * SIZEOF_IC ; the lines and things of a trace
intercept_p:  .space  4               ; the next free intercept
_g_trace:     .space  16              ; the trace line: x, y, dx, dy
