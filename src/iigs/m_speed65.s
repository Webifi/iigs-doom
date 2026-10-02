;;; The first view size, from a speed test at boot.
;;;
;;; Byte 21 of the settings file (VW_FVSIZE, src/iigs/viewwin.inc) is the view
;;; size, or 0 when the player has not picked one: the shipped file, a missing
;;; file, an invalid file and a size that is not one of the six all mean 0.
;;; Then uiLoadSettings takes the size of the machine from the test below, once
;;; for each boot, and the file keeps 0 until the player picks a size (the view
;;; keys or the VIEW item). vwStored is the byte that collect writes to the file.
;;;
;;; The test runs once, before the title music, with interrupts off. Loop A is a
;;; run of 8-bit stores to bank 5, loop B the same cycles of NOPs. Each loop counts
;;; its batches in SP_TICS tics of the DOC timer (I_GetTime). The timer is read
;;; only between batches: a GLU read is slow I/O. B shows the CPU clock; A
;;; against B shows if a store waits for the motherboard (a ZipGS or TransWarp GS
;;; holds the next write until the last one has left) or runs at CPU speed.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "viewwin.inc"

              .extern I_GetTime, oneNormalize, settingsFile

TW_IRQOFF     .equ    0xbcff34        ; the TransWarp GS firmware (m_menu65.s)
TW_GETCFG     .equ    0xbcff3c
TW_SETCFG     .equ    0xbcff40

SP_TICS       .equ    2               ; DOC tics for each loop
SP_PASSES     .equ    32              ; passes in a batch: 32 stores each, 4256 cycles
SP_BMIN       .equ    56              ; B batches in SP_TICS tics. A stock IIgs counts
                                      ;   33, the slowest accelerator (7 MHz) 89: below
                                      ;   this (about 4.7 MHz) the CPU is a stock one
SP_STOCK      .equ    VW_QUARTERSIZE  ; the first size: about 2.8 MHz,
SP_STALL      .equ    VW_TWOSIZE      ;   fast CPU, stores wait (ZipGS, TransWarp GS)
SP_NATIVE     .equ    10              ;   fast CPU, stores at CPU speed
                                      ; (10 is the full view, VW_TWOSIZE the 2/3 view)

;;; 8 stores, and the 16 NOPs of the same 32 cycles.
ST8           .macro  b
              sta     abs:.kbank (\b + 0)
              sta     abs:.kbank (\b + 1)
              sta     abs:.kbank (\b + 2)
              sta     abs:.kbank (\b + 3)
              sta     abs:.kbank (\b + 4)
              sta     abs:.kbank (\b + 5)
              sta     abs:.kbank (\b + 6)
              sta     abs:.kbank (\b + 7)
              .endm
NP8           .macro
              nop
              nop
              nop
              nop
              nop
              nop
              nop
              nop
              nop
              nop
              nop
              nop
              nop
              nop
              nop
              nop
              .endm

;;; RUN: the batches of \batch until SP_TICS tics have passed since spNow; Y =
;;; their number (it stays at 65535 on a machine that is very fast).
RUN           .macro  batch
              lda     long:spNow
              clc
              adc     ##SP_TICS
              sta     long:spGoal
              ldy     ##0
1$:           jsr     .kbank \batch
              iny
              bne     2$
              dey
2$:           jsl     long:I_GetTime
              sta     long:spNow
              sec
              sbc     long:spGoal
              bmi     1$
              .endm

              .section speedcode, text
              .public vwStored, speedA, speedB, speedClass
              .public speedStored, speedSize

;;; speedStored (from oneLoadSettings, carry set: no valid file): vwStored = the
;;; size of the file, or 0 when it has none or has a bad one; A = the size for
;;; VW_SIZE (10 when there is none).
speedStored:  bcs     8$
              lda     long:(settingsFile+VW_FVSIZE)
              and     ##0x00ff
              beq     8$
              pha
              jsl     long:oneNormalize     ; the same value for a size, else 10
              cmp     1,s
              bne     7$
              plx
              sta     long:vwStored
              rtl
7$:           pla
8$:           lda     ##0
              sta     long:vwStored
              lda     ##10
              rtl

;;; speedSize (from uiLoadSettings): A = the size to start with.
speedSize:    lda     long:vwStored
              and     ##0x00ff
              bne     9$
              jsr     .kbank speedTest
9$:           rtl

;;; speedTest: A = the size of this machine. The cache gets both loops first.
;;; The first batch of A starts at the edge of a tic, and B starts where A ends.
speedTest:    php
              sei
              rep     #0x30
              jsr     .kbank twFast
              jsr     .kbank spBatchA
              jsr     .kbank spBatchB
              jsl     long:I_GetTime
              sta     long:spNow
1$:           jsl     long:I_GetTime
              cmp     long:spNow
              beq     1$
              sta     long:spNow
              RUN     spBatchA
              tya
              sta     long:speedA
              RUN     spBatchB
              tya
              sta     long:speedB
              lda     long:speedB
              cmp     ##SP_BMIN
              bcc     3$
              lsr     a                     ; the stores wait when A is below B - B / 8:
              lsr     a                     ;   A is B at CPU speed, 0.79 B on a TransWarp GS
              lsr     a                     ;   at 14 MHz, 0.4 to 0.8 B on a ZipGS
              sta     long:spGoal
              lda     long:speedB
              sec
              sbc     long:spGoal
              sta     long:spGoal
              lda     long:speedA
              cmp     long:spGoal
              bcc     2$
              lda     ##2
              sta     long:speedClass
              lda     ##SP_NATIVE
              bra     9$
2$:           lda     ##1
              sta     long:speedClass
              lda     ##SP_STALL
              bra     9$
3$:           lda     ##0
              sta     long:speedClass
              lda     ##SP_STOCK
9$:           pha
              jsr     .kbank twBack
              pla
              plp
              rts

;;; twFast and twBack: with TWGS SLOW IRQ at CARD the card runs at the motherboard
;;; speed while interrupts are off, and the test would read a stock machine. twFast
;;; keeps the configuration of the card and turns its IRQ logic off; twBack puts the
;;; configuration back (no change when the logic was off). Only a TransWarp GS
;;; (VW_TWON). The firmware calls need D = $0A00, as in m_menu65.s.
twFast:       lda     long:VW_TWON
              cmp     ##VW_TWTAG
              bne     9$
              php
              sei
              phb
              phd
              lda     ##0x0a00
              tcd
              jsl     long:TW_GETCFG
              sta     long:spTw
              jsl     long:TW_IRQOFF
              pld
              plb
              plp
9$:           rts

twBack:       lda     long:VW_TWON
              cmp     ##VW_TWTAG
              bne     9$
              php
              sei
              phb
              phd
              lda     ##0x0a00
              tcd
              lda     long:spTw
              jsl     long:TW_SETCFG
              pld
              plb
              plp
9$:           rts

;;; The batches: SP_PASSES passes of 32 stores (A) or the same cycles of NOPs (B),
;;; 133 cycles a pass. The stores go to spBuf, so the data bank is this one (an
;;; absolute store takes 4 cycles; a long store takes 5).
spBatchA:     phb
              phk
              plb
              sep     #0x20
              ldx     ##SP_PASSES
1$:           ST8     spBuf
              ST8     spBuf + 8
              ST8     spBuf + 16
              ST8     spBuf + 24
              dex
              bne     1$
              rep     #0x20
              plb
              rts

spBatchB:     phb
              phk
              plb
              sep     #0x20
              ldx     ##SP_PASSES
1$:           NP8
              NP8
              NP8
              NP8
              dex
              bne     1$
              rep     #0x20
              plb
              rts

vwStored:     .word   0               ; the size for the file; 0: not set
speedA:       .word   0               ; the batches of A and of B, and the class
speedB:       .word   0               ;   (0 about 2.8 MHz, 1 stores wait,
speedClass:   .word   0               ;   2 stores at CPU speed): left for the
                                      ;   benchmark and the MAME logs
spTw:         .word   0               ; the card configuration at the start
spNow:        .word   0
spGoal:       .word   0
spBuf:        .space  32
