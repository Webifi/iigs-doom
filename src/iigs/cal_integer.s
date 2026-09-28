;;; Copy of the Calypsi C library src/lib/lowlevel/integer.s (version 5.18)
;;; without _Mul16 and _Mul32, for Doom8088: Apple IIgs Edition.
/****************************************************************************
 *
 * Copyright Håkan Thörngren
 *
 * This file is part of the Calypsi C library.
 * Permission to use with the Calypsi tool chain is hereby granted.
 *
 ****************************************************************************/

;;; ----------------------------------------------------------------------
;;;
;;; Integer math support.
;;;
;;; ----------------------------------------------------------------------

              .rtmodel version, "1"
              .rtmodel cpu, "*"

#include "macros.h"

              .extern _Dp

;;; _Mul16 and _Mul32 are in src/iigs/m_fixed65.s (Doom8088: Apple IIgs
;;; Edition), which uses quarter-square tables instead of shift and add.

;;; ***************************************************************************
;;;
;;; _Mul64 - 64x64 to 64 bits multiplication
;;;
;;; In: dp24_0 - points to result to be
;;;     dp24_4 - op1
;;;     dp24_8 - op2
;;;
;;; Out: dp24_0 - points to result
;;;
;;; Destroys: a, x, y
;;;
;;; ***************************************************************************

              .section libcode
              .public _Mul64
_Mul64:                             ; clear result to be
                                    ; push op2 and op1 interleaved
              ldy     ##6
10$:          lda     [.tiny (_Dp+8)],y
              pha
              lda     [.tiny (_Dp+4)],y
              pha
              lda     ##0
              sta     [.tiny _Dp],y
              dey
              dey
              bpl     10$

              ldx     ##63          ; loop counter

100$:         lda     1,s
              bne     110$
                                    ; 16 bits of zero, shuffle words
              lda     5,s           ; op1 >>= 16
              sta     1,s
              lda     9,s
              sta     5,s
              lda     13,s
              sta     9,s           ; (no need to clear upper bits, loop
                                    ;  counter ensures we will not look at it)

              lda     11,s          ; op2 <<= 16
              sta     15,s
              lda     7,s
              sta     11,s
              lda     3,s
              sta     7,s
              lda     ##0
              sta     3,s           ; clear lower 16 bits of op2

              txa
              sec
              sbc     ##16
              bmi     500$          ; done
              tax
              bra     100$

110$:         lda     13,s          ; op1 >>= 1
              lsr     a
              sta     13,s
              lda     9,s
              ror     a
              sta     9,s
              lda     5,s
              ror     a
              sta     5,s
              lda     1,s
              ror     a
              sta     1,s

              bcc     150$          ; no contribution

              clc                   ; add to result
              lda     [.tiny (_Dp+0)]
              adc     3,s
              sta     [.tiny (_Dp+0)]
              ldy     ##2
              lda     [.tiny (_Dp+0)],y
              adc     7,s
              sta     [.tiny (_Dp+0)],y
              iny
              iny
              lda     [.tiny (_Dp+0)],y
              adc     11,s
              sta     [.tiny (_Dp+0)],y
              iny
              iny
              lda     [.tiny (_Dp+0)],y
              adc     15,s
              sta     [.tiny (_Dp+0)],y

150$:         lda     3,s           ; op2 <<= 1
              asl     a
              sta     3,s
              lda     7,s
              rol     a
              sta     7,s
              lda     11,s
              rol     a
              sta     11,s
              lda     15,s
              rol     a
              sta     15,s

              dex
              bpl     100$

500$:         tsc                   ; clean stack work area
              clc
              adc     ##16
              tcs

              return

              .section libcode, noreorder
DivMod16:     tay
              bpl     10$           ; positive dividend
              eor     ##0xffff      ; negate dividend
              inc     a
10$:          txy
              bpl     _UDivMod16    ; positive divisor
              tay                   ; negate divisor
              txa
              eor     ##0xffff
              inc     a
              tax
              tya

;;; ***************************************************************************
;;;
;;; _UDivMod16 - unsigned short int divide and remainder
;;;
;;; In: c - dividend
;;;     x - divisor
;;;
;;; Out: x - quote
;;;      c - remainder
;;;
;;; Destroys: y
;;;
;;; ***************************************************************************

              .section libcode, noreorder
              .public _UDivMod16
_UDivMod16:   pei     dp:.tiny(_Dp+6)
              pei     dp:.tiny(_Dp+4)
              phx                   ; push divisor
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              lda     dp:.tiny (_Dp+6) ; A / remainder = 0
              inc     dp:.tiny (_Dp+6) ; counter marker = 1

20$:          asl     dp:.tiny (_Dp+4) ; rem <<= 1
              rol     a
              sec
              tay
              sbc     1,s           ; rem -= divisor
              bcs     25$
              tya                   ; use old rem (rem < divisor)
25$:          rol     dp:.tiny (_Dp+6)
              bcc     20$
              plx
              ldx     dp:.tiny (_Dp+6) ; x = quote
              ply
              sty     dp:.tiny(_Dp+4)
              ply
              sty     dp:.tiny(_Dp+6)
              return

;;; ***************************************************************************
;;;
;;; _Div16 - signed short int divide
;;;
;;; In: c - dividend
;;;     x - divisor
;;;
;;; Out: c - quote
;;;
;;; Destroys: x, y, dp32_0
;;;
;;; ***************************************************************************

              .section libcode, noreorder
              .public _Div16
_Div16:       phx
              pha
              eor     3,s
              sta     3,s
              pla
              call    DivMod16
              txa
              bra     _DivModSign16

;;; ***************************************************************************
;;;
;;; _Mod16 - signed short int modulo
;;;
;;; In: c - dividend
;;;     x - divisor
;;;
;;; Out: c - remainder
;;;
;;; Destroys: x, y, dp32_0
;;;
;;; ***************************************************************************

              .section libcode, noreorder
              .public _Mod16
              .require _DivModSign16
_Mod16:       pha
              call    DivMod16

              .section libcode, noreorder
              .public _DivModSign16 ; in order to make require work
_DivModSign16:
              plx
              bpl     10$           ; positive result
              eor     ##0xffff      ; negative, negate result
              inc     a
10$:          return

              .section bspcode, text
DivMod32:     bit     dp:.tiny(_Dp+2)
              bpl     10$
              lda     ##0
              sec
              sbc     dp:.tiny(_Dp+0)
              sta     dp:.tiny(_Dp+0)
              lda     ##0
              sbc     dp:.tiny(_Dp+2)
              sta     dp:.tiny(_Dp+2)
10$:          bit     dp:.tiny(_Dp+6)
              bpl     _UDivMod32
              lda     ##0
              sec
              sbc     dp:.tiny(_Dp+4)
              sta     dp:.tiny(_Dp+4)
              lda     ##0
              sbc     dp:.tiny(_Dp+6)
              sta     dp:.tiny(_Dp+6)

;;; ***************************************************************************
;;;
;;; _UModDiv32 - 32 bits unsigned divide and modulo
;;;
;;; In: dp32_0 - op1
;;;     dp32_4 - op2
;;;
;;; Out: x:c - quote
;;;      dp32_0 - reminder
;;;
;;; Destroys: a, x, y
;;;
;;; ***************************************************************************

              .public _UDivMod32
_UDivMod32:
;;; Doom8088: Apple IIgs Edition: fast paths for a 16-bit divisor.
;;; A divisor below 256 (the column count of rw_scalestep) runs in 8-bit
;;; mode: the quotient bits replace the dividend bytes with 8-bit
;;; read-modify-writes, each followed by register work and cache hits, and
;;; a byte below the divisor with a remainder of 0 is a quotient byte of 0.
;;; Another divisor: long division in two 16-bit steps; the first step is
;;; skipped when the high word of the dividend is below the divisor. A
;;; remainder that overflows 16 bits when shifted (divisor >= 0x8000) is
;;; always larger than the divisor. The quotient replaces the dividend,
;;; one byte at a time (divW2, divW0).
              lda     dp:.tiny(_Dp+6)
              bne     slowDiv32
              lda     dp:.tiny(_Dp+4)
              beq     slowDiv32
              cmp     ##0x0100
              bcs     10$
              sep     #0x30
              lda     #0                    ; the remainder
              ldx     #3                    ; the dividend bytes, the high one first
1$:           cmp     #0                    ; remainder 0, byte < divisor: quotient
              bne     2$                    ;   byte 0, the byte is the remainder
              lda     dp:.tiny _Dp,x
              cmp     dp:.tiny (_Dp+4)
              bcs     5$
              stz     dp:.tiny _Dp,x
              bra     4$
5$:           lda     #0
2$:           ldy     #8
3$:           asl     dp:.tiny _Dp,x        ; C = the next bit of the dividend
              rol     a                     ; the remainder
              bcs     6$                    ; (9 bits: >= divisor)
              cmp     dp:.tiny (_Dp+4)
              bcc     7$
6$:           sbc     dp:.tiny (_Dp+4)
              inc     dp:.tiny _Dp,x        ; a quotient bit of 1
7$:           dey
              bne     3$
4$:           dex
              bpl     1$
              rep     #0x30
              and     ##0x00ff
              tay                           ; remainder
              ldx     dp:.tiny(_Dp+2)
              lda     dp:.tiny(_Dp+0)
              sty     dp:.tiny(_Dp+0)
              stz     dp:.tiny(_Dp+2)
              return
10$:          lda     dp:.tiny(_Dp+2)
              cmp     dp:.tiny(_Dp+4)
              bcs     11$
              stz     dp:.tiny(_Dp+2)       ; quotient high = 0, remainder = high word
              bra     12$
11$:          lda     ##0
              jsr     .kbank divW2
12$:          jsr     .kbank divW0
              tay                           ; remainder
              ldx     dp:.tiny(_Dp+2)
              lda     dp:.tiny(_Dp+0)
              sty     dp:.tiny(_Dp+0)
              stz     dp:.tiny(_Dp+2)
              return

slowDiv32:    pei     dp:.tiny(_Dp+14)
              pei     dp:.tiny(_Dp+12)
              pei     dp:.tiny(_Dp+10)
              pei     dp:.tiny(_Dp+8)

              lda     dp:.tiny(_Dp+0) ; move reminder fraction
              sta     dp:.tiny(_Dp+8)
              lda     dp:.tiny(_Dp+2)
              sta     dp:.tiny(_Dp+10)
              stz     dp:.tiny(_Dp+0) ; reminder = 0
              stz     dp:.tiny(_Dp+2)

              stz     dp:.tiny(_Dp+12) ; counter marker = 1
              stz     dp:.tiny(_Dp+14)
              inc     dp:.tiny(_Dp+12)

20$:          asl     dp:.tiny(_Dp+8) ; rem <<= 1
              rol     dp:.tiny(_Dp+10)
              rol     dp:.tiny(_Dp+0)
              rol     dp:.tiny(_Dp+2)

              sec
              lda     dp:.tiny(_Dp+0)
              sbc     dp:.tiny(_Dp+4)
              tay
              lda     dp:.tiny(_Dp+2)
              sbc     dp:.tiny(_Dp+6)
              bcc     25$           ; skip if (rem < divisor)
              sta     dp:.tiny(_Dp+2)
              sty     dp:.tiny(_Dp+0)
25$:          rol     dp:.tiny(_Dp+12) ; counter <<= 1
              rol     dp:.tiny(_Dp+14)
              bcc     20$           ; counter not expired

              lda     dp:.tiny(_Dp+12) ; x:c = quote
              ldx     dp:.tiny(_Dp+14)

              ply
              sty     dp:.tiny(_Dp+8)
              ply
              sty     dp:.tiny(_Dp+10)
              ply
              sty     dp:.tiny(_Dp+12)
              ply
              sty     dp:.tiny(_Dp+14)
              return

;;; divW2, divW0: the long division of the word _Dp[2-3] (divW2) or
;;; _Dp[0-1] (divW0) by _Dp[4-5]; the quotient bytes replace it with 8-bit
;;; stores. In: A = the remainder. Out: A = the remainder. Destroys X, Y.
DIVW          .macro  w
              tax                           ; (the remainder)
              lda     dp:.tiny (_Dp+\w)     ; the high byte, and a stop bit
              and     ##0xff00
              ora     ##1
              tay
              txa
              jsr     .kbank div8
              sep     #0x20
              tya
              sta     dp:.tiny (_Dp+\w+1)   ; the high quotient byte
              rep     #0x20
              lda     dp:.tiny (_Dp+\w)     ; the low byte, and a stop bit
              xba
              and     ##0xff00
              ora     ##1
              tay
              txa
              jsr     .kbank div8
              sep     #0x20
              tya
              sta     dp:.tiny (_Dp+\w)     ; the low quotient byte
              rep     #0x20
              txa
              rts
              .endm

divW2:        DIVW    2
divW0:        DIVW    0

;;; div8: 8 steps of the long division by the word in _Dp[4-5]. In: A = the
;;; remainder, Y = the next byte of the dividend << 8 | 1 (a stop bit). Out:
;;; X = the remainder, the low byte of Y = the 8 quotient bits (the stop
;;; bit reaches bit 8 after the 8th step).
div8:         tax
              tya
1$:           asl     a                     ; C = the next bit of the dividend
              tay
              txa
              rol     a                     ; the remainder
              bcs     2$
              cmp     dp:.tiny(_Dp+4)
              bcc     3$
2$:           sbc     dp:.tiny(_Dp+4)       ; carry is set here
              iny                           ; a quotient bit of 1
3$:           tax
              tya
              bit     ##0x0100              ; the stop bit in bit 8: done
              beq     1$
              rts

;;; ***************************************************************************
;;;
;;; _Mod32 - 32 bits signed modulo
;;;
;;; In: dp32_0 - op1
;;;     dp32_4 - op2
;;;
;;; Out: x:c - reminder op1 % op2
;;;
;;; Destroys: a, x, y, dp32_0
;;;
;;; ***************************************************************************

              .section bspcode, text
              .public _Mod32
_Mod32:       pei     dp:.tiny (_Dp+2) ; push sign bit of result
              call    DivMod32
              bra     _DivModSign32

;;; ***************************************************************************
;;;
;;; _Div32 - 32 bits signed divide
;;;
;;; In: dp32_0 - op1
;;;     dp32_4 - op2
;;;
;;; Out: x:c - quote op1 / op2
;;;
;;; Destroys: a, x, y, dp32_0
;;;
;;; ***************************************************************************

              .public _Div32
              .require _DivModSign32
_Div32:       lda     dp:.tiny(_Dp+2)
              eor     dp:.tiny(_Dp+6)
              pha
              call    DivMod32
              stx     dp:.tiny(_Dp+2)
              sta     dp:.tiny(_Dp+0)

              .public _DivModSign32
_DivModSign32:
              ply
              bpl     10$
              lda     ##0
              tax
              sec
              sbc     dp:.tiny(_Dp+0)
              tay
              txa
              sbc     dp:.tiny(_Dp+2)
              tax
              tya
              return
10$:          lda     dp:.tiny(_Dp+0)
              ldx     dp:.tiny(_Dp+2)
              return

;;; ***************************************************************************
;;;
;;; _UDiv64 - 64 bits signed divide
;;; _UMod64 - 64 bits signed divide
;;;
;;; In: dp24_0 - pointer to result
;;;     dp24_4 - op1
;;;     dp24_8 - op2
;;;
;;; Out: dp24_0 filled in
;;;
;;; Destroys: a, x, y
;;;
;;; ***************************************************************************

              .section libcode
              .public _UDiv64, _UMod64
_UDiv64:      clc
              bra     UDivMod64
_UMod64:      sec
UDivMod64:    php
              ldy     ##6           ; push op1 (reminder low part)
5$:           lda     [.tiny (_Dp+4)],y
              pha
              dey
              dey
              bpl     5$
              ldy     ##6
              lda     ##0
10$:          pha                   ; push remainder (high) = 0
              dey
              bpl     10$
              inc     a
              pha                   ; push result with marker = 1
20$:          ldy     ##0
              ldx     ##3
              lda     17,s          ; rem <<= 1
              asl     a
              sta     17,s
              lda     19,s
              rol     a
              sta     19,s
              lda     21,s
              rol     a
              sta     21,s
              lda     23,s
              rol     a
              sta     23,s
              lda     15,s
              rol     a
              sta     15,s
              lda     13,s
              rol     a
              sta     13,s
              lda     11,s
              rol     a
              sta     11,s
              lda     9,s
              rol     a
              sta     9,s
              sec                   ; rem - divisor
              ldy     ##0
              ldx     ##3
24$:          lda     15,s
              sbc     [.tiny (_Dp+8)],y
              pha
              iny
              iny
              dex
              bpl     24$
              pla
              bcc     25$           ; skip if (rem < divisor)
              sta     15,s
              pla
              sta     15,s
              pla
              sta     15,s
              pla
              sta     15,s
              bra     30$
25$:          ply
              ply
              ply
30$:          lda     1,s           ; counter <<= 1
              rol     a
              sta     1,s
              lda     3,s
              rol     a
              sta     3,s
              lda     5,s
              rol     a
              sta     5,s
              lda     7,s
              rol     a
              sta     7,s
              bcc     20$           ; counter not expired

              lda     25,s
              lsr     a             ; want modulo result?
              bcs     70$           ; yes

              ldx     ##3
              ldy     ##0
50$:          pla                   ; divide, move result in place
              sta     [.tiny _Dp+0],y
              iny
              iny
              dex
              bpl     50$
              tsc
              clc
              adc     ##16
              tcs
              plp
              return
70$:          pla
              pla
              pla
              pla
              ldy     ##6
75$:          pla                   ; move modulo result in place
              sta     [.tiny _Dp+0],y
              dey
              dey
              bpl     75$
              ply
              ply
              ply
              ply
              plp
              return

;;; ***************************************************************************
;;;
;;; _Mod64 - 64 bits signed modulo
;;;
;;; In: dp24_0 - pointer to result
;;;     dp24_4 - op1
;;;     dp24_8 - op2
;;;
;;; Out: dp24_0 filled in with result
;;;
;;; Destroys: a, x, y
;;;
;;; ***************************************************************************

              .section libcode, noreorder
              .public _Mod64
_Mod64:       ldy     ##6
              lda     [.tiny (_Dp+4)],y
              sec
              bra     DivMod64

;;; ***************************************************************************
;;;
;;; _Div64 - 64 bits signed divide
;;;
;;; In: dp24_0 - pointer to result
;;;     dp24_4 - op1
;;;     dp24_8 - op2
;;;
;;; Out: dp24_0 filled in with result
;;;
;;; Destroys: a, x, y
;;;
;;; ***************************************************************************

              .section libcode, noreorder
              .public _Div64
_Div64:       ldy     ##6
              lda     [.tiny (_Dp+4)],y
              eor     [.tiny (_Dp+8)],y
              clc

              .section libcode, noreorder
DivMod64:     pha                   ; save result sign flag
              php                   ; save operation code (carry)

                                    ; preserve original operand input pointers
              pei     dp:.tiny(_Dp+10)
              pei     dp:.tiny(_Dp+8)
              pei     dp:.tiny(_Dp+6)
              pei     dp:.tiny(_Dp+4)

              tsc                   ; reserve space for temporaries that are
              sec                   ; used if input operand is negative
              sbc     ##16
              tcs

              ldx     ##0
              lda     [.tiny (_Dp+4)],y ; op1 positive?
              bpl     20$           ; yes
              sec                   ; no, negate op1 on stack
              txa
              sbc     [.tiny (_Dp+4)]
              sta     1,s
              txa
              ldy     ##2
              sbc     [.tiny (_Dp+4)],y
              sta     3,s
              iny
              iny
              txa
              sbc     [.tiny (_Dp+4)],y
              sta     5,s
              iny
              iny
              txa
              sbc     [.tiny (_Dp+4)],y
              sta     7,s
              stz     dp:.tiny (_Dp+6) ; DP4= negated op1 on stack
              tsc
              inc     a
              sta     dp:.tiny (_Dp+4)

20$:          lda     [.tiny (_Dp+8)],y ;op2 positive?
              bpl     30$           ; yes
              sec                   ; no, negate op2 on stack
              txa
              sbc     [.tiny (_Dp+8)]
              sta     9,s
              txa
              ldy     ##2
              sbc     [.tiny (_Dp+8)],y
              sta     11,s
              iny
              iny
              txa
              sbc     [.tiny (_Dp+8)],y
              sta     13,s
              iny
              iny
              txa
              sbc     [.tiny (_Dp+8)],y
              sta     15,s
              stz     dp:.tiny (_Dp+10) ; DP8= negated op2 on stack
              tsc
              clc
              adc     ##9
              sta     dp:.tiny (_Dp+8)

30$:          lda     25,s          ; carry= operation
              lsr     a
              call    UDivMod64
              tsc                   ; remove temporaies
              clc
              adc     ##16
              tcs
              pla
              sta     dp:.tiny(_Dp+4) ; restore op1 and op2
              pla
              sta     dp:.tiny(_Dp+6)
              pla
              sta     dp:.tiny(_Dp+8)
              pla
              sta     dp:.tiny(_Dp+10)
              plp
              pla
              bpl     50$           ; positive result
              ldy     ##0           ; negate result
              sec
              ldx     ##3
40$:          lda     ##0
              sbc     [.tiny _Dp],y
              sta     [.tiny _Dp],y
              iny
              iny
              dex
              bpl     40$
50$:          return

;;; ***************************************************************************
;;;
;;; _Shl64 - 64 bits left shift
;;;
;;; In: dp24_0 - pointer to result
;;;     dp24_4 - operand
;;;     x - counter
;;;
;;; Out: dp24_0 filled in
;;;
;;; Destroys: a, x, y
;;;
;;; ***************************************************************************

              .section libcode
              .public _Shl64
_Shl64:       ldy     ##6           ; copy operand
10$:          lda     [.tiny (_Dp+4)],y
              sta     [.tiny (_Dp+0)],y
              dey
              dey
              bpl     10$
              txa
              beq     100$          ; no shift
              cpx     ##64
              bcs     90$           ; zero result
20$:          lda     [.tiny (_Dp+0)]
              asl     a
              sta     [.tiny (_Dp+0)]
              ldy     ##2
              lda     [.tiny (_Dp+0)],y
              rol     a
              sta     [.tiny (_Dp+0)],y
              iny
              iny
              lda     [.tiny (_Dp+0)],y
              rol     a
              sta     [.tiny (_Dp+0)],y
              iny
              iny
              lda     [.tiny (_Dp+0)],y
              rol     a
              sta     [.tiny (_Dp+0)],y
              dex
              bne     20$
100$:         return

90$:          lda     ##0           ; zero result
              ldy     ##6
95$:          sta     [.tiny (_Dp+0)],y
              dey
              dey
              bpl     95$
              return

;;; ***************************************************************************
;;;
;;; _UShr64 - 64 bits unsigned right shift
;;;
;;; In: dp24_0 - pointer to result
;;;     dp24_4 - operand
;;;     x - counter
;;;
;;; Out: dp24_0 filled in
;;;
;;; Destroys: a, x, y
;;;
;;; ***************************************************************************

              .section libcode
              .public _UShr64
_UShr64:      ldy     ##6           ; copy operand
10$:          lda     [.tiny (_Dp+4)],y
              sta     [.tiny (_Dp+0)],y
              dey
              dey
              bpl     10$
              txa
              beq     100$          ; no shift
              cpx     ##64
              bcs     90$           ; zero result
20$:          ldy     ##6
              lda     [.tiny (_Dp+0)],y
              lsr     a
              sta     [.tiny (_Dp+0)],y
              dey
              dey
              lda     [.tiny (_Dp+0)],y
              ror     a
              sta     [.tiny (_Dp+0)],y
              dey
              dey
              lda     [.tiny (_Dp+0)],y
              ror     a
              sta     [.tiny (_Dp+0)],y
              lda     [.tiny (_Dp+0)]
              ror     a
              sta     [.tiny (_Dp+0)]
              dex
              bne     20$
100$:         return

90$:          lda     ##0           ; zero result
              ldy     ##6
95$:          sta     [.tiny (_Dp+0)],y
              dey
              dey
              bpl     95$
              return

;;; ***************************************************************************
;;;
;;; _Shr64 - 64 bits signed right shift
;;;
;;; In: dp24_0 - pointer to result
;;;     dp24_4 - operand
;;;     x - counter
;;;
;;; Out: dp24_0 filled in
;;;
;;; Destroys: a, x, y
;;;
;;; ***************************************************************************

              .section libcode
              .public _Shr64
_Shr64:       ldy     ##6           ; copy operand
10$:          lda     [.tiny (_Dp+4)],y
              sta     [.tiny (_Dp+0)],y
              dey
              dey
              bpl     10$
              txa
              beq     100$          ; no shift
              cmp     ##63
              bcs     90$           ; sign propagaed result
20$:          ldy     ##6
              lda     [.tiny (_Dp+0)],y
              asl     a
25$:          lda     [.tiny (_Dp+0)],y
              ror     a
              sta     [.tiny (_Dp+0)],y
              dey
              dey
              bpl     25$
              dex
              bpl     20$
100$:         return

90$:          ldy     ##6           ; sign propagated result
              lda     [.tiny (_Dp+0)],y
              eor     ##0x8000
              asl     a
              sta     [.tiny (_Dp+0)],y
              sbc     [.tiny (_Dp+0)],y
95$:          sta     [.tiny (_Dp+0)],y
              dey
              dey
              bne     95$
              return
