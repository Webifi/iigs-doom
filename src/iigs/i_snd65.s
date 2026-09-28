;;; Sound bank decoder, Doom8088: Apple IIgs Edition.
;;;
;;; Decodes the blocks of tools/sndbank.py: 16 samples each, a header byte
;;; (order << 4) | width, then 2 * width bytes of residuals. The residuals
;;; come from the tables at the start of the bank.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "memmap.inc"

              .extern _Dp, DC_TI

SNDBANK       .equ    MM_SNDBANK      ; the sound bank (src/iigs/iigs.scm)
HI4           .equ    SNDBANK+0x000   ; the tables of tools/sndbank.py
LO4           .equ    SNDBANK+0x100
S2A           .equ    SNDBANK+0x200
S2B           .equ    SNDBANK+0x300
S2C           .equ    SNDBANK+0x400
S2D           .equ    SNDBANK+0x500
S6A           .equ    SNDBANK+0x600
S6BH          .equ    SNDBANK+0x700
S6BL          .equ    SNDBANK+0x800
S6CH          .equ    SNDBANK+0x900
S6CL          .equ    SNDBANK+0xa00
S6D           .equ    SNDBANK+0xb00

;;; Direct page: the variables of the column drawers are free at boot.
SD_T          .equ    DC_TI           ; the 16 samples of the block
SD_C80        .equ    DC_TI+16        ; 0x80, the prediction of order 0
SD_X1         .equ    DC_TI+17        ; x[-1] of an order 2 block
SD_TMP        .equ    DC_TI+18
SD_H          .equ    DC_TI+19        ; block header
SD_SRC        .equ    DC_TI+20        ; 4 bytes
SD_DST        .equ    DC_TI+24        ; 4 bytes
SD_N          .equ    DC_TI+28        ; blocks left (word)

;;; Sample k = the residual in A + the prediction: with SD_T, 1 the sample
;;; before, with SD_C80, 0 the constant 0x80. 8-bit A.
EMIT          .macro  k, base, stride
              clc
              adc     dp:.tiny (\base+(((\k+15)&15)*\stride))
              sta     dp:.tiny (SD_T+\k)
              .endm

;;; A residual of 0.
DW0           .macro  k, base, stride
              lda     #0
              EMIT    \k, \base, \stride
              .endm

;;; 4 residuals of 2 bits from a byte. B = 0, so TAX gives the byte.
DW2           .macro  k, base, stride
              lda     [.tiny SD_SRC],y
              iny
              tax
              lda     long:S2A,x
              EMIT    \k, \base, \stride
              lda     long:S2B,x
              EMIT    \k+1, \base, \stride
              lda     long:S2C,x
              EMIT    \k+2, \base, \stride
              lda     long:S2D,x
              EMIT    \k+3, \base, \stride
              .endm

;;; 2 residuals of 4 bits from a byte.
DW4           .macro  k, base, stride
              lda     [.tiny SD_SRC],y
              iny
              tax
              lda     long:HI4,x
              EMIT    \k, \base, \stride
              lda     long:LO4,x
              EMIT    \k+1, \base, \stride
              .endm

;;; 4 residuals of 6 bits from 3 bytes. The high part tables have the sign.
DW6           .macro  k, base, stride
              lda     [.tiny SD_SRC],y
              iny
              tax
              lda     long:S6A,x
              EMIT    \k, \base, \stride
              lda     long:S6BH,x
              sta     dp:.tiny SD_TMP
              lda     [.tiny SD_SRC],y
              iny
              tax
              lda     long:S6BL,x
              clc
              adc     dp:.tiny SD_TMP
              EMIT    \k+1, \base, \stride
              lda     long:S6CH,x
              sta     dp:.tiny SD_TMP
              lda     [.tiny SD_SRC],y
              iny
              tax
              lda     long:S6CL,x
              clc
              adc     dp:.tiny SD_TMP
              EMIT    \k+2, \base, \stride
              lda     long:S6D,x
              EMIT    \k+3, \base, \stride
              .endm

;;; A residual of 8 bits.
DW8           .macro  k, base, stride
              lda     [.tiny SD_SRC],y
              iny
              EMIT    \k, \base, \stride
              .endm

;;; Adds the sample before to slope k: the samples of an order 2 block.
PSUM          .macro  k
              clc
              adc     dp:.tiny (SD_T+\k)
              sta     dp:.tiny (SD_T+\k)
              .endm

;;; ---------------------------------------------------------------------------
;;; int16_t IIGS_DecodeSound(uint16_t nblocks, const uint8_t __far* src,
;;;                          uint8_t __far* dst)
;;; In: C = nblocks, _Dp[0-3] = src, _Dp[4-7] = dst. Writes nblocks * 16
;;; samples. Returns 0, or 1 for a bad block header.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public IIGS_DecodeSound
IIGS_DecodeSound:
              sta     dp:.tiny SD_N
              lda     dp:.tiny _Dp
              sta     dp:.tiny SD_SRC
              lda     dp:.tiny (_Dp+2)
              sta     dp:.tiny (SD_SRC+2)
              lda     dp:.tiny (_Dp+4)
              sta     dp:.tiny SD_DST
              lda     dp:.tiny (_Dp+6)
              sta     dp:.tiny (SD_DST+2)
              lda     ##0x8080              ; x[-2] = x[-1] = 0x80
              sta     dp:.tiny (SD_T+14)
              sta     dp:.tiny SD_C80
              ldy     ##0
              lda     dp:.tiny SD_N
              bne     block
              rtl

block:        lda     ##0                   ; B = 0 for TAX
              sep     #0x20
              lda     [.tiny SD_SRC],y
              iny
              sta     dp:.tiny SD_H
              cmp     #0x29
              bcc     5$
              jmp     .kbank bad
5$:           asl     a
              tax
              lda     dp:.tiny SD_H
              and     #0xf0
              cmp     #0x20
              bne     1$
              lda     dp:.tiny (SD_T+15)    ; order 2: the order 1 code makes
              sta     dp:.tiny SD_X1        ; the slopes from x[-1] - x[-2]
              sec
              sbc     dp:.tiny (SD_T+14)
              sta     dp:.tiny (SD_T+15)
1$:           jsr     (.kbank decoders,x)
              lda     dp:.tiny SD_H
              and     #0xf0
              cmp     #0x20
              bne     2$
              lda     dp:.tiny SD_X1        ; the samples are the sums of the
              PSUM    0
              PSUM    1
              PSUM    2
              PSUM    3
              PSUM    4
              PSUM    5
              PSUM    6
              PSUM    7
              PSUM    8
              PSUM    9
              PSUM    10
              PSUM    11
              PSUM    12
              PSUM    13
              PSUM    14
              PSUM    15
2$:           rep     #0x20                 ; copy the block out
              phy
              ldy     ##0
              lda     dp:.tiny SD_T
              sta     [.tiny SD_DST],y
              ldy     ##2
              lda     dp:.tiny (SD_T+2)
              sta     [.tiny SD_DST],y
              ldy     ##4
              lda     dp:.tiny (SD_T+4)
              sta     [.tiny SD_DST],y
              ldy     ##6
              lda     dp:.tiny (SD_T+6)
              sta     [.tiny SD_DST],y
              ldy     ##8
              lda     dp:.tiny (SD_T+8)
              sta     [.tiny SD_DST],y
              ldy     ##10
              lda     dp:.tiny (SD_T+10)
              sta     [.tiny SD_DST],y
              ldy     ##12
              lda     dp:.tiny (SD_T+12)
              sta     [.tiny SD_DST],y
              ldy     ##14
              lda     dp:.tiny (SD_T+14)
              sta     [.tiny SD_DST],y
              ply
              lda     dp:.tiny SD_DST
              clc
              adc     ##16
              sta     dp:.tiny SD_DST
              bcc     3$
              inc     dp:.tiny (SD_DST+2)
3$:           dec     dp:.tiny SD_N
              beq     4$
              jmp     .kbank block
4$:           lda     ##0
              rtl

bad:          rep     #0x20
              lda     ##1
              rtl

;;; A header with a bad width: return from IIGS_DecodeSound with 1.
badWidth:     pla
              pla
              bra     bad

;;; The block code for each header byte: orders 1 and 2 have the same code.
decoders:
              .word   .word0 W0O0
              .word   .word0 badWidth
              .word   .word0 W2O0
              .word   .word0 badWidth
              .word   .word0 W4O0
              .word   .word0 badWidth
              .word   .word0 W6O0
              .word   .word0 badWidth
              .word   .word0 W8O0
              .word   .word0 badWidth
              .word   .word0 badWidth
              .word   .word0 badWidth
              .word   .word0 badWidth
              .word   .word0 badWidth
              .word   .word0 badWidth
              .word   .word0 badWidth
              .word   .word0 W0O1
              .word   .word0 badWidth
              .word   .word0 W2O1
              .word   .word0 badWidth
              .word   .word0 W4O1
              .word   .word0 badWidth
              .word   .word0 W6O1
              .word   .word0 badWidth
              .word   .word0 W8O1
              .word   .word0 badWidth
              .word   .word0 badWidth
              .word   .word0 badWidth
              .word   .word0 badWidth
              .word   .word0 badWidth
              .word   .word0 badWidth
              .word   .word0 badWidth
              .word   .word0 W0O1
              .word   .word0 badWidth
              .word   .word0 W2O1
              .word   .word0 badWidth
              .word   .word0 W4O1
              .word   .word0 badWidth
              .word   .word0 W6O1
              .word   .word0 badWidth
              .word   .word0 W8O1

;;; Width 0, order 0.
W0O0:         DW0     0, SD_C80, 0
              DW0     1, SD_C80, 0
              DW0     2, SD_C80, 0
              DW0     3, SD_C80, 0
              DW0     4, SD_C80, 0
              DW0     5, SD_C80, 0
              DW0     6, SD_C80, 0
              DW0     7, SD_C80, 0
              DW0     8, SD_C80, 0
              DW0     9, SD_C80, 0
              DW0     10, SD_C80, 0
              DW0     11, SD_C80, 0
              DW0     12, SD_C80, 0
              DW0     13, SD_C80, 0
              DW0     14, SD_C80, 0
              DW0     15, SD_C80, 0
              rts

;;; Width 2, order 0.
W2O0:         DW2     0, SD_C80, 0
              DW2     4, SD_C80, 0
              DW2     8, SD_C80, 0
              DW2     12, SD_C80, 0
              rts

;;; Width 4, order 0.
W4O0:         DW4     0, SD_C80, 0
              DW4     2, SD_C80, 0
              DW4     4, SD_C80, 0
              DW4     6, SD_C80, 0
              DW4     8, SD_C80, 0
              DW4     10, SD_C80, 0
              DW4     12, SD_C80, 0
              DW4     14, SD_C80, 0
              rts

;;; Width 6, order 0.
W6O0:         DW6     0, SD_C80, 0
              DW6     4, SD_C80, 0
              DW6     8, SD_C80, 0
              DW6     12, SD_C80, 0
              rts

;;; Width 8, order 0.
W8O0:         DW8     0, SD_C80, 0
              DW8     1, SD_C80, 0
              DW8     2, SD_C80, 0
              DW8     3, SD_C80, 0
              DW8     4, SD_C80, 0
              DW8     5, SD_C80, 0
              DW8     6, SD_C80, 0
              DW8     7, SD_C80, 0
              DW8     8, SD_C80, 0
              DW8     9, SD_C80, 0
              DW8     10, SD_C80, 0
              DW8     11, SD_C80, 0
              DW8     12, SD_C80, 0
              DW8     13, SD_C80, 0
              DW8     14, SD_C80, 0
              DW8     15, SD_C80, 0
              rts

;;; Width 0, order 1 (and the slopes of order 2).
W0O1:         DW0     0, SD_T, 1
              DW0     1, SD_T, 1
              DW0     2, SD_T, 1
              DW0     3, SD_T, 1
              DW0     4, SD_T, 1
              DW0     5, SD_T, 1
              DW0     6, SD_T, 1
              DW0     7, SD_T, 1
              DW0     8, SD_T, 1
              DW0     9, SD_T, 1
              DW0     10, SD_T, 1
              DW0     11, SD_T, 1
              DW0     12, SD_T, 1
              DW0     13, SD_T, 1
              DW0     14, SD_T, 1
              DW0     15, SD_T, 1
              rts

;;; Width 2, order 1 (and the slopes of order 2).
W2O1:         DW2     0, SD_T, 1
              DW2     4, SD_T, 1
              DW2     8, SD_T, 1
              DW2     12, SD_T, 1
              rts

;;; Width 4, order 1 (and the slopes of order 2).
W4O1:         DW4     0, SD_T, 1
              DW4     2, SD_T, 1
              DW4     4, SD_T, 1
              DW4     6, SD_T, 1
              DW4     8, SD_T, 1
              DW4     10, SD_T, 1
              DW4     12, SD_T, 1
              DW4     14, SD_T, 1
              rts

;;; Width 6, order 1 (and the slopes of order 2).
W6O1:         DW6     0, SD_T, 1
              DW6     4, SD_T, 1
              DW6     8, SD_T, 1
              DW6     12, SD_T, 1
              rts

;;; Width 8, order 1 (and the slopes of order 2).
W8O1:         DW8     0, SD_T, 1
              DW8     1, SD_T, 1
              DW8     2, SD_T, 1
              DW8     3, SD_T, 1
              DW8     4, SD_T, 1
              DW8     5, SD_T, 1
              DW8     6, SD_T, 1
              DW8     7, SD_T, 1
              DW8     8, SD_T, 1
              DW8     9, SD_T, 1
              DW8     10, SD_T, 1
              DW8     11, SD_T, 1
              DW8     12, SD_T, 1
              DW8     13, SD_T, 1
              DW8     14, SD_T, 1
              DW8     15, SD_T, 1
              rts
