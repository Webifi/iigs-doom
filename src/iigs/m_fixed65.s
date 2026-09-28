;;; Fast multiplication for the 65816, Doom8088: Apple IIgs Edition.
;;;
;;; Quarter-square multiplication: x * y = sq(x + y) - sq(|x - y|) with
;;; sq(i) = floor(i * i / 4). 16 x 16 products use the large tables SQL and
;;; SQH (two lookups); the routines keep the looked-up words in registers,
;;; so a product stores one word, and their code has its own cache slots
;;; (section hotmul, src/iigs/iigs.scm). The sprite scale products use the
;;; small table T of src/iigs/mul.inc.
;;;
;;; This file replaces the Calypsi runtime _Mul16 and _Mul32, and gives
;;; FixedMul, FixedMul3232 and FixedMul3216 for the engine.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "memmap.inc"

              .extern _Dp

              .section znear, bss
              .public iigs_mulT
iigs_mulT:    .space  766 * 2           ; T[k], k = -255..510
MULT0         .equ    iigs_mulT + 510   ; &T[0]

              .public MA, MB, MR, QP, QM, umul16, umul16lo

              .section ztiny, bss
MA:           .space  2
MB:           .space  2
MR:           .space  4
MID:          .space  2
MC:           .space  2
T:            .space  2
QP:           .space  3                 ; long pointers into T (mul.inc)
QM:           .space  3
FA0:          .space  2                 ; FixedMul operands and result
FA1:          .space  2
FB0:          .space  2
FB1:          .space  2
FR0:          .space  2
FR1:          .space  2

#include "mul.inc"

;;; ---------------------------------------------------------------------------
;;; Large quarter-square tables for 16 x 16 products:
;;;   a * b = sq(a + b) - sq(|a - b|), sq(n) = floor(n * n / 4)
;;; with n = 0..131071. SQL holds the low words and SQH the high words;
;;; each is 256 KB in 4 banks, and byte offset 2n gives entry n.
;;; IIGS_InitSquares builds them at startup.
;;; ---------------------------------------------------------------------------
SQL           .equ    MM_SQL
SQH           .equ    MM_SQH

;;; SQPARTR a, b: sq(a + b) (a + b has 17 bits): its low word in Y, its
;;; high word in MR+2 (the one store); then X = the index of sq(|a - b|),
;;; carry set for its second bank. Destroys A.
SQPARTR       .macro  a, b
              lda     dp:.tiny \a
              clc
              adc     dp:.tiny \b
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
50$:          sta     dp:.tiny (MR+2)
              lda     dp:.tiny \a
              sec
              sbc     dp:.tiny \b
              bcs     60$
              eor     ##0xffff
              inc     a
60$:          asl     a
              tax
              .endm

;;; QMULR a, b: a * b, unsigned: Y = bits 0..15, C = bits 16..31.
;;; Destroys X, MR+2.
QMULR         .macro  a, b
              SQPARTR \a, \b
              tya
              bcs     70$
              sec
              sbc     long:SQL,x
              tay
              lda     dp:.tiny (MR+2)
              sbc     long:SQH,x
              bra     80$
70$:          sec
              sbc     long:(SQL+0x10000),x
              tay
              lda     dp:.tiny (MR+2)
              sbc     long:(SQH+0x10000),x
80$:
              .endm

;;; QMULHIR a, b: C = bits 16..31 of a * b, unsigned. Destroys X, Y, MR+2.
QMULHIR       .macro  a, b
              SQPARTR \a, \b
              tya
              bcs     70$
              cmp     long:SQL,x            ; the borrow of the low words
              lda     dp:.tiny (MR+2)
              sbc     long:SQH,x
              bra     80$
70$:          cmp     long:(SQL+0x10000),x
              lda     dp:.tiny (MR+2)
              sbc     long:(SQH+0x10000),x
80$:
              .endm

;;; QMULLOR a, b: C = bits 0..15 of a * b, with no store. Destroys X, Y.
QMULLOR       .macro  a, b
              lda     dp:.tiny \a
              clc
              adc     dp:.tiny \b
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
              lda     dp:.tiny \a
              sec
              sbc     dp:.tiny \b
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

;;; ---------------------------------------------------------------------------
;;; fmBH: the end of FixedMul3232 for BH = 1..7 (FB1; AH and BH not 0 or
;;; -1), with FR1:FR0 = hi16(AL * BL) + AH * BL: + AL * BH (up to 19 bits)
;;; and + lo16(AH * BH) << 16, one shifted AL or AH for each bit of BH,
;;; then the sign corrections (as 15$ of FixedMul3232; BH >= 0). Its own
;;; fragment, placed after umul16 in hotmul.
;;; ---------------------------------------------------------------------------
              .section hotmul, text
fmBH:         ldx     dp:.tiny FA0          ; X = AL << k, Y = its bits above 16
              ldy     ##0
              lda     dp:.tiny FA1          ; AH << k (low 16) on the stack
              pha
              lda     dp:.tiny FB1          ; the bits of BH, low first
1$:           lsr     a
              pha
              bcc     2$
              txa                           ; FR += AL << k
              clc
              adc     dp:.tiny FR0
              sta     dp:.tiny FR0
              tya
              adc     dp:.tiny FR1
              clc                           ; + AH << k in the high word
              adc     3,s
              sta     dp:.tiny FR1
2$:           txa                           ; k + 1
              asl     a
              tax
              tya
              rol     a
              tay
              lda     3,s
              asl     a
              sta     3,s
              pla
              bne     1$
              pla
              lda     dp:.tiny FR1
              ldx     dp:.tiny FA1          ; AH < 0: - BL << 16 (BH >= 0)
              bpl     3$
              sec
              sbc     dp:.tiny FB0
3$:           tax
              lda     dp:.tiny FR0
              rtl

;;; ---------------------------------------------------------------------------
;;; umul16: MR = MA * MB, unsigned 16 x 16 -> 32.
;;; Destroys A, X, Y.
;;; ---------------------------------------------------------------------------
              .section hotmul, text
umul16:       QMULR   MA, MB
              sty     dp:.tiny MR
              sta     dp:.tiny (MR+2)
              rtl

;;; ---------------------------------------------------------------------------
;;; umul16lo: A = low 16 bits of MA * MB. Destroys X, Y.
;;; ---------------------------------------------------------------------------
              .section hotmul, text
umul16lo:     QMULLOR MA, MB
              rtl

;;; ---------------------------------------------------------------------------
;;; IIGS_MulLo16: C = low 16 bits of C * X.
;;; ---------------------------------------------------------------------------
              .section hotmul, text
              .public IIGS_MulLo16
IIGS_MulLo16: sta     dp:.tiny MA
              stx     dp:.tiny MB
              jmp     long:umul16lo

;;; ---------------------------------------------------------------------------
;;; IIGS_SMul16: signed 16 x 16 -> 32. In: C = a, X = b. Out: X:C.
;;; The unsigned product minus (a < 0 ? b << 16 : 0) and (b < 0 ? a << 16 : 0).
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public IIGS_SMul16
IIGS_SMul16:  sta     dp:.tiny MA
              stx     dp:.tiny MB
              jsl     long:umul16
              lda     dp:.tiny MA
              bpl     10$
              lda     dp:.tiny (MR+2)
              sec
              sbc     dp:.tiny MB
              sta     dp:.tiny (MR+2)
10$:          lda     dp:.tiny MB
              bpl     20$
              lda     dp:.tiny (MR+2)
              sec
              sbc     dp:.tiny MA
              sta     dp:.tiny (MR+2)
20$:          lda     dp:.tiny MR
              ldx     dp:.tiny (MR+2)
              rtl

;;; ---------------------------------------------------------------------------
;;; void IIGS_InitSquares(void): build T (iigs_mulT), then SQL and SQH.
;;; T[k] = k * k / 4 from the square V (V += 2 k + 1), T[-k] = T[k].
;;; SQL, SQH: sq(2k) = V, V += k, sq(2k + 1) = V, V += k + 1, starting with
;;; V = 0.
;;; ---------------------------------------------------------------------------
SQQUARTER     .macro  q
              ldx     ##0
1$:           lda     dp:.tiny FR0          ; sq(2k)
              sta     long:(SQL + \q * 0x10000),x
              lda     dp:.tiny FR1
              sta     long:(SQH + \q * 0x10000),x
              lda     dp:.tiny FR0          ; V += k
              clc
              adc     dp:.tiny MID
              sta     dp:.tiny FR0
              bcc     2$
              inc     dp:.tiny FR1
2$:           inx
              inx
              lda     dp:.tiny FR0          ; sq(2k + 1)
              sta     long:(SQL + \q * 0x10000),x
              lda     dp:.tiny FR1
              sta     long:(SQH + \q * 0x10000),x
              inc     dp:.tiny MID          ; V += k + 1
              lda     dp:.tiny FR0
              clc
              adc     dp:.tiny MID
              sta     dp:.tiny FR0
              bcc     3$
              inc     dp:.tiny FR1
3$:           inx
              inx
              bne     1$
              .endm

              .section farcode, text
              .public IIGS_InitSquares
IIGS_InitSquares:
              stz     dp:.tiny FR0          ; V
              stz     dp:.tiny FR1
              ldx     ##0                   ; X = 2 k
1$:           lda     dp:.tiny FR1          ; T[k] = V >> 2
              lsr     a
              lda     dp:.tiny FR0
              ror     a
              pha
              lda     dp:.tiny FR1
              lsr     a
              lsr     a
              pla
              ror     a
              sta     long:MULT0,x
              txa                           ; V += 2 k + 1
              sec
              adc     dp:.tiny FR0
              sta     dp:.tiny FR0
              bcc     2$
              inc     dp:.tiny FR1
2$:           inx
              inx
              cpx     ##(511 * 2)
              bcc     1$
              ldx     ##(510 + 2)           ; T[-k] = T[k], k = 1..255
              ldy     ##(510 - 2)
3$:           lda     long:iigs_mulT,x
              phx
              tyx
              sta     long:iigs_mulT,x
              plx
              inx
              inx
              dey
              dey
              bpl     3$
              sep     #0x20                 ; the bank of the pointers into T
              lda     #.byte2 iigs_mulT
              sta     dp:.tiny (QP+2)
              sta     dp:.tiny (QM+2)
              rep     #0x20
              stz     dp:.tiny FR0          ; V
              stz     dp:.tiny FR1
              stz     dp:.tiny MID          ; k
              SQQUARTER 0
              SQQUARTER 1
              SQQUARTER 2
              SQQUARTER 3
              rtl

;;; ---------------------------------------------------------------------------
;;; _Mul16 - Calypsi runtime, 16 x 16 -> 32 unsigned.
;;; In: C, X. Out: X:C. Destroys A, X, Y.
;;; ---------------------------------------------------------------------------
              .section bspcode, text
              .public _Mul16
_Mul16:       sta     dp:.tiny MA
              stx     dp:.tiny MB
              jsl     long:umul16
              lda     dp:.tiny MR
              ldx     dp:.tiny (MR+2)
              rtl

;;; ---------------------------------------------------------------------------
;;; _Mul32 - Calypsi runtime, 32 x 32 -> low 32 bits.
;;; In: _Dp[0-3], _Dp[4-7]. Out: X:C. Destroys A, X, Y.
;;;
;;; low32 = AL*BL + ((AH*BL + AL*BH) << 16). A high word of 0 adds nothing
;;; and a high word of 0xFFFF adds minus the other low word, which covers
;;; the int16_t values that C promotes to long.
;;; ---------------------------------------------------------------------------
              .section bspcode, text
              .public _Mul32
_Mul32:       lda     dp:.tiny _Dp          ; AL * BL
              sta     dp:.tiny MA
              lda     dp:.tiny (_Dp+4)
              sta     dp:.tiny MB
              jsl     long:umul16
              lda     dp:.tiny MR
              sta     dp:.tiny FR0
              lda     dp:.tiny (MR+2)
              sta     dp:.tiny FR1

              lda     dp:.tiny (_Dp+2)      ; AH * BL, low 16
              beq     20$
              cmp     ##0xffff
              bne     10$
              lda     dp:.tiny FR1
              sec
              sbc     dp:.tiny (_Dp+4)
              sta     dp:.tiny FR1
              bra     20$
10$:          sta     dp:.tiny MA
              jsl     long:umul16lo
              clc
              adc     dp:.tiny FR1
              sta     dp:.tiny FR1

20$:          lda     dp:.tiny (_Dp+6)      ; AL * BH, low 16
              beq     40$
              cmp     ##0xffff
              bne     30$
              lda     dp:.tiny FR1
              sec
              sbc     dp:.tiny _Dp
              sta     dp:.tiny FR1
              bra     40$
30$:          sta     dp:.tiny MB
              lda     dp:.tiny _Dp
              sta     dp:.tiny MA
              jsl     long:umul16lo
              clc
              adc     dp:.tiny FR1
              sta     dp:.tiny FR1
40$:          lda     dp:.tiny FR0
              ldx     dp:.tiny FR1
              rtl

;;; ---------------------------------------------------------------------------
;;; fixed_t FixedMul(fixed_t a, fixed_t b)       (a * b) >> 16, signed
;;; fixed_t FixedMul3232(fixed_t a, fixed_t b)   same
;;; In: a in X:C, b in _Dp[0-3]. Out: X:C.
;;;
;;; With a = AH:AL and b = BH:BL (AH, BH signed):
;;;   result = hi16(AL*BL) + AH*BL + AL*BH + (lo16(AH*BH) << 16)
;;;            - (AH < 0 ? BL << 16 : 0) - (BH < 0 ? AL << 16 : 0)
;;; where the products are unsigned. When BH is 0 or -1 (b = BL - 65536),
;;; result = (a * BL) >> 16, minus a for BH = -1; the same holds with a and
;;; b swapped.
;;; ---------------------------------------------------------------------------
              .section hotmul, text
              .public FixedMul, FixedMul3232
FixedMul:
FixedMul3232:
              sta     dp:.tiny FA0
              stx     dp:.tiny FA1
              lda     dp:.tiny _Dp
              sta     dp:.tiny FB0
              lda     dp:.tiny (_Dp+2)
              sta     dp:.tiny FB1
              bne     10$
              jmp     long:mul3216            ; BH == 0
10$:          cmp     ##0xffff
              beq     13$                   ; BH == -1
              lda     dp:.tiny FA1          ; AH == 0 or -1: swap a and b
              beq     11$
              cmp     ##0xffff
              bne     15$
11$:          ldx     dp:.tiny FB0
              lda     dp:.tiny FA0
              sta     dp:.tiny FB0
              stx     dp:.tiny FA0
              ldx     dp:.tiny FB1
              lda     dp:.tiny FA1
              sta     dp:.tiny FB1
              stx     dp:.tiny FA1
              lda     dp:.tiny FB1
              bne     13$
              jmp     long:mul3216            ; BH == 0
13$:          jsl     long:mul3216            ; BH == -1: ((a * BL) >> 16) - a
              sec
              sbc     dp:.tiny FA0
              tay
              txa
              sbc     dp:.tiny FA1
              tax
              tya
              rtl

15$:          QMULHIR FA0, FB0              ; hi16(AL * BL)
              sta     dp:.tiny FR0
              QMULR   FA1, FB0              ; + AH * BL
              tax
              tya
              clc
              adc     dp:.tiny FR0
              sta     dp:.tiny FR0
              txa
              adc     ##0
              sta     dp:.tiny FR1
              lda     dp:.tiny FB1          ; BH = 1..7 (a scale of 1.0 to 8.0):
              cmp     ##8                   ;   AL * BH and AH * BH from shifts
              bcs     17$                   ;   and adds (fmBH)
              jmp     .kbank fmBH
17$:          QMULR   FA0, FB1              ; + AL * BH
              tax
              tya
              clc
              adc     dp:.tiny FR0
              sta     dp:.tiny FR0
              txa
              adc     dp:.tiny FR1
              sta     dp:.tiny FR1
              QMULLOR FA1, FB1              ; + AH * BH, low 16
              clc
              adc     dp:.tiny FR1
              ldx     dp:.tiny FA1          ; sign corrections
              bpl     92$
              sec
              sbc     dp:.tiny FB0
92$:          ldx     dp:.tiny FB1
              bpl     93$
              sec
              sbc     dp:.tiny FA0
93$:          tax
              lda     dp:.tiny FR0
              rtl

;;; ---------------------------------------------------------------------------
;;; fixed_t FixedMul3216(fixed_t a, uint16_t blw)   (a * blw) >> 16
;;; In: a in X:C, blw in _Dp[0-1]. Out: X:C.
;;; ---------------------------------------------------------------------------
              .section hotmul, text
              .public FixedMul3216
FixedMul3216:
              sta     dp:.tiny FA0
              stx     dp:.tiny FA1
              lda     dp:.tiny _Dp
              sta     dp:.tiny FB0

;;; FA1:FA0 * FB0 >> 16, FB0 unsigned. Destroys Y.
mul3216:      QMULHIR FA0, FB0              ; hi16(AL * BL)
              sta     dp:.tiny FR0
              QMULR   FA1, FB0              ; + AH * BL: Y = low, C = high
              tax
              tya
              clc
              adc     dp:.tiny FR0
              tay
              txa
              adc     ##0
              ldx     dp:.tiny FA1          ; AH < 0: - BL << 16
              bpl     91$
              sec
              sbc     dp:.tiny FB0
91$:          tax
              tya
              rtl
