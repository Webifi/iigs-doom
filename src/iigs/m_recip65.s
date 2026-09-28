;;; Fast reciprocals for the 65816, Doom8088: Apple IIgs Edition.
;;;
;;; 0xFFFFFFFF / v is found from a table: v is shifted left by s bits
;;; until bit 31 is set, the top 16 bits M index the table of
;;; (2^31 - 1) / M, and the entry is shifted by s - 15 bits:
;;;
;;;   2^32 / v = 2^(32 + s) / (v << s) ~ (2^31 / M) * 2^(s - 15)
;;;
;;; The result has 16 significant bits. IIGS_InitRecip makes the table at
;;; boot (the test program of make mathtest loads recip.bin instead).

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "memmap.inc"

RECIP_TABLE   .equ    MM_RECIP

              .section ztiny, bss
RV:           .space  4
RS:           .space  2
RT:           .space  4

;;; ---------------------------------------------------------------------------
;;; recipCore: X:C = ~0xFFFFFFFF / RV, RV != 0: RECIP_TABLE[M] shifted by
;;; s - 15. The shifts are in registers (computed jumps into chains of
;;; shifts), with one store; the code is in the cache slots of the
;;; multiplies (src/iigs/iigs.scm).
;;; ---------------------------------------------------------------------------
;;; LZX b: X = 2 lz + b, lz = the leading zeros of the byte C (1..255).
LZX           .macro  b
              cmp     ##0x10
              bcs     15$
              cmp     ##0x04
              bcs     13$
              cmp     ##0x02
              ldx     ##(14 + \b)
              bcc     19$
              ldx     ##(12 + \b)
              bra     19$
13$:          cmp     ##0x08
              ldx     ##(10 + \b)
              bcc     19$
              ldx     ##(8 + \b)
              bra     19$
15$:          cmp     ##0x40
              bcs     17$
              cmp     ##0x20
              ldx     ##(6 + \b)
              bcc     19$
              ldx     ##(4 + \b)
              bra     19$
17$:          cmp     ##0x80
              ldx     ##(2 + \b)
              bcc     19$
              ldx     ##(0 + \b)
19$:
              .endm

              .section hotmul, text
recipCore:    lda     dp:.tiny (RV+2)
              bne     1$
              brl     rcSmall
              ;; high word H != 0: the result is RECIP_TABLE[M] >> (15 - s), 16
              ;; bits. M = (V << lz) | ((B << lz) >> 8): for H < 256 V = H:Lhi
              ;; (the word at RV + 1), B = Llo, s = 8 + lz; else V = H, B = Lhi,
              ;; s = lz. lz: the leading zeros of the top byte; X = 2 lz, plus
              ;; 16 in the second case.
1$:           cmp     ##0x0100
              bcs     5$
              LZX     0
              lda     dp:.tiny RV           ; B = Llo
              ldy     dp:.tiny (RV+1)       ; V = H:Lhi
              bra     10$
5$:           xba
              and     ##0x00ff
              LZX     16
              lda     dp:.tiny (RV+1)       ; B = Lhi
              ldy     dp:.tiny (RV+2)       ; V = H
10$:          and     ##0x00ff              ; (B << lz) >> 8
              jmp     (.kbank rcShl1,x)
rcChain1:     asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              xba
              and     ##0x00ff
              sta     dp:.tiny RT
              tya                           ; | V << lz
              txy                           ; (Y = the index of the chains)
              jmp     (.kbank rcShl2,x)
rcChain2:     asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              ora     dp:.tiny RT
              asl     a                     ; RECIP_TABLE[M]
              tax
              lda     long:RECIP_TABLE,x
              tyx
              jmp     (.kbank rcShr,x)
rcChain3:     lsr     a
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
              lsr     a
              ldx     ##0
              rtl

              ;; high word 0: s >= 16, the result is RECIP_TABLE[M] << n,
              ;; n = s - 15 (1..16), 32 bits; X = 2 n
rcSmall:      lda     dp:.tiny RV
              ldx     ##2
              cmp     ##0x0100
              bcs     2$
              xba                           ; L < 256: shift by 8
              ldx     ##18
2$:           tay                           ; N = bit 15
              bmi     4$
3$:           inx
              inx
              asl     a
              bpl     3$
4$:           txy                           ; (Y = 2 n)
              asl     a                     ; RECIP_TABLE[M]
              tax
              lda     long:RECIP_TABLE,x
              tyx
              tay                           ; (Y = the entry)
              jmp     (.kbank rcLo,x)       ; the low word: << n
rcChain4:     asl     a
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
              asl     a
              asl     a
              asl     a
              asl     a
              sta     dp:.tiny RT
              tya                           ; the high word: >> (16 - n)
              jmp     (.kbank rcHi,x)
rcChain5:     lsr     a
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
              lsr     a
              lsr     a
              tax
              lda     dp:.tiny RT
              rtl
rcShl1:
              .word   .word0 (rcChain1 + 7)
              .word   .word0 (rcChain1 + 6)
              .word   .word0 (rcChain1 + 5)
              .word   .word0 (rcChain1 + 4)
              .word   .word0 (rcChain1 + 3)
              .word   .word0 (rcChain1 + 2)
              .word   .word0 (rcChain1 + 1)
              .word   .word0 (rcChain1 + 0)
              .word   .word0 (rcChain1 + 7)
              .word   .word0 (rcChain1 + 6)
              .word   .word0 (rcChain1 + 5)
              .word   .word0 (rcChain1 + 4)
              .word   .word0 (rcChain1 + 3)
              .word   .word0 (rcChain1 + 2)
              .word   .word0 (rcChain1 + 1)
              .word   .word0 (rcChain1 + 0)
rcShl2:
              .word   .word0 (rcChain2 + 7)
              .word   .word0 (rcChain2 + 6)
              .word   .word0 (rcChain2 + 5)
              .word   .word0 (rcChain2 + 4)
              .word   .word0 (rcChain2 + 3)
              .word   .word0 (rcChain2 + 2)
              .word   .word0 (rcChain2 + 1)
              .word   .word0 (rcChain2 + 0)
              .word   .word0 (rcChain2 + 7)
              .word   .word0 (rcChain2 + 6)
              .word   .word0 (rcChain2 + 5)
              .word   .word0 (rcChain2 + 4)
              .word   .word0 (rcChain2 + 3)
              .word   .word0 (rcChain2 + 2)
              .word   .word0 (rcChain2 + 1)
              .word   .word0 (rcChain2 + 0)
rcShr:
              .word   .word0 (rcChain3 + 8)
              .word   .word0 (rcChain3 + 9)
              .word   .word0 (rcChain3 + 10)
              .word   .word0 (rcChain3 + 11)
              .word   .word0 (rcChain3 + 12)
              .word   .word0 (rcChain3 + 13)
              .word   .word0 (rcChain3 + 14)
              .word   .word0 (rcChain3 + 15)
              .word   .word0 (rcChain3 + 0)
              .word   .word0 (rcChain3 + 1)
              .word   .word0 (rcChain3 + 2)
              .word   .word0 (rcChain3 + 3)
              .word   .word0 (rcChain3 + 4)
              .word   .word0 (rcChain3 + 5)
              .word   .word0 (rcChain3 + 6)
              .word   .word0 (rcChain3 + 7)
rcLo:         .word   0
              .word   .word0 (rcChain4 + 15)
              .word   .word0 (rcChain4 + 14)
              .word   .word0 (rcChain4 + 13)
              .word   .word0 (rcChain4 + 12)
              .word   .word0 (rcChain4 + 11)
              .word   .word0 (rcChain4 + 10)
              .word   .word0 (rcChain4 + 9)
              .word   .word0 (rcChain4 + 8)
              .word   .word0 (rcChain4 + 7)
              .word   .word0 (rcChain4 + 6)
              .word   .word0 (rcChain4 + 5)
              .word   .word0 (rcChain4 + 4)
              .word   .word0 (rcChain4 + 3)
              .word   .word0 (rcChain4 + 2)
              .word   .word0 (rcChain4 + 1)
              .word   .word0 (rcChain4 + 0)
rcHi:         .word   0
              .word   .word0 (rcChain5 + 1)
              .word   .word0 (rcChain5 + 2)
              .word   .word0 (rcChain5 + 3)
              .word   .word0 (rcChain5 + 4)
              .word   .word0 (rcChain5 + 5)
              .word   .word0 (rcChain5 + 6)
              .word   .word0 (rcChain5 + 7)
              .word   .word0 (rcChain5 + 8)
              .word   .word0 (rcChain5 + 9)
              .word   .word0 (rcChain5 + 10)
              .word   .word0 (rcChain5 + 11)
              .word   .word0 (rcChain5 + 12)
              .word   .word0 (rcChain5 + 13)
              .word   .word0 (rcChain5 + 14)
              .word   .word0 (rcChain5 + 15)
              .word   .word0 (rcChain5 + 16)

;;; ---------------------------------------------------------------------------
;;; fixed_t FixedReciprocal(fixed_t v)      In: X:C. Out: X:C.
;;; ---------------------------------------------------------------------------
              .section bspcode, text
              .public FixedReciprocal
FixedReciprocal:
              sta     dp:.tiny RV
              stx     dp:.tiny (RV+2)
              ora     dp:.tiny (RV+2)
              beq     10$
              jmp     long:recipCore
10$:          lda     ##0xffff
              tax
              rtl

;;; ---------------------------------------------------------------------------
;;; fixed_t FixedReciprocalSmall(uint16_t v)    In: C. Out: X:C.
;;; ---------------------------------------------------------------------------
              .section bspcode, text
              .public FixedReciprocalSmall
FixedReciprocalSmall:
              sta     dp:.tiny RV
              stz     dp:.tiny (RV+2)
              tax
              beq     10$
              jmp     long:recipCore
10$:          lda     ##0xffff
              tax
              rtl

;;; ---------------------------------------------------------------------------
;;; uint16_t FixedReciprocalBig(fixed_t v), v >= 0x10000    In: X:C. Out: C.
;;; ---------------------------------------------------------------------------
              .section bspcode, text
              .public FixedReciprocalBig
FixedReciprocalBig:
              sta     dp:.tiny RV
              stx     dp:.tiny (RV+2)
              jmp     long:recipCore

;;; ---------------------------------------------------------------------------
;;; void IIGS_InitRecip(void): RECIP_TABLE entry i = (2^31 - 1) / (32768 + i),
;;; the same as recip.bin of tools/gentables.py. With N = q * d + r, the
;;; next quotient comes from N = q * (d + 1) + (r - q).
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public IIGS_InitRecip
IIGS_InitRecip:
              phb
              pea     #((RECIP_TABLE >> 16) * 0x0101)
              plb
              plb
              lda     ##32768               ; d
              sta     dp:.tiny RT
              lda     ##32767               ; r
              sta     dp:.tiny RV
              ldy     ##65535               ; q
              ldx     ##0                   ; 2 * i
              jsr     .kbank quotients
              plb
              rtl

;;; quotients: the words at X up to the end of the data bank get the
;;; quotients q of N / d for d, d + 1, ...: N = q * d + r. In: Y = q,
;;; RT = d, RV = r. nextQuotient first goes on to d + 1.
quotients:    tya
              sta     abs:0,x
              inx
              inx
              beq     qDone
nextQuotient: inc     dp:.tiny RT           ; d + 1
              sty     dp:.tiny RS
              lda     dp:.tiny RV           ; r - q
              sec
              sbc     dp:.tiny RS
              bcs     2$
1$:           dey                           ; below 0: q - 1, r + (d + 1)
              clc
              adc     dp:.tiny RT
              bcc     1$
2$:           sta     dp:.tiny RV
              bra     quotients
qDone:        rts

;;; ---------------------------------------------------------------------------
;;; void IIGS_InitFstep(void): FSTEP_TABLE, after IIGS_InitRecip.
;;; Entry L (the word at FSTEP_TABLE + 2L) is the texture step that fstep
;;; of src/iigs/r_seg65.s gives for the scale 0:L. With lz the leading
;;; zeros of L and M = L << lz, fstep shifts RECIP_TABLE[M] = (2^31 - 1) / M
;;; right by 6 - lz, so for L >= 512 (lz <= 6) the entry is 33554431 / L,
;;; one quotient after the other. Below 512, fsSmall does what fstep does.
;;; ---------------------------------------------------------------------------
FSTEP_TABLE   .equ    MM_FSTEP        ; 65536 words in banks $7E and $7F

              .public IIGS_InitFstep
IIGS_InitFstep:
              phb
              pea     #((FSTEP_TABLE >> 16) * 0x0101)
              plb
              plb
              ldx     ##1022                ; L = 511 .. 1
1$:           phx
              txa
              lsr     a
              jsr     .kbank fsSmall
              plx
              sta     abs:0,x
              dex
              dex
              bne     1$
              lda     ##0xffff              ; L = 0: FixedReciprocal(0)
              sta     abs:0
              lda     ##512                 ; d
              sta     dp:.tiny RT
              lda     ##511                 ; r
              sta     dp:.tiny RV
              ldy     ##65535               ; q
              ldx     ##(2 * 512)
              jsr     .kbank quotients      ; L = 512 .. 32767
              pea     #(((FSTEP_TABLE >> 16) + 1) * 0x0101)
              plb
              plb
              ldx     ##0
              jsr     .kbank nextQuotient   ; L = 32768 .. 65535
              plb
              rtl

;;; fsSmall: C = the fstep of the scale 0:C, C = 1..511: RECIP_TABLE[M]
;;; shifted left by s - 22, where s = 16 + lz is 23 or more.
fsSmall:      ldy     ##0xfffa              ; s - 22 for s = 16
              cmp     ##0x0100
              bcs     2$
              xba                           ; below 256: C << 8, s = 24
              ldy     ##2
              bra     2$
1$:           iny                           ; shift until bit 15 is set
              asl     a
2$:           bit     ##0x8000
              beq     1$
              asl     a                     ; RECIP_TABLE[M]
              tax
              lda     long:RECIP_TABLE,x
3$:           asl     a
              dey
              bne     3$
              rts
