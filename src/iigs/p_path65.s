;;; Traces through the block map in 65816 assembly.
;;;
;;; P_AproxDistance, P_PathTraverse and P_TraverseIntercepts of
;;; p_maputl.c, with the same results.

              .rtmodel version, "1"
              .rtmodel core, "*"


#include "offsets.inc"
#include "memmap.inc"

              .extern _Dp, validcount, intercepts, intercept_p, _g_trace
              .extern longTrace, TR_LONG, sideSetup, traceLines, VT_RR, icInsertL
              .extern _g_bmaporgx, _g_bmaporgy, DC_EXITP
              .extern P_BlockLinesIterator, P_BlockThingsIterator
              .extern PIT_AddLineIntercepts, traceThings
              .extern FixedApproxDiv, FixedMul3216, _Mul16, _UDivMod32
              .extern _g_blockmap, _g_blockmaplump, _g_blocklinks, _g_lines
              .extern _g_bmapwidth, _g_bmapheight, _g_numlines, gBlockT

MAXINTERCEPTS .equ    64              ; as in src/iigs/p_trace65.s
PAD_GB        .equ    2               ; (the code of bank 0 keeps its size)
GSTAMP        .equ    MM_GSTAMP       ; guard: a word for each line (16384)
GW_TAB        .equ    MM_GW_TAB       ; guard: the line counts of the first
                                      ;   walk (gBlk), 10 bytes a block
GW_MAXB       .equ    3276            ;   for the blocks below this
BMROW         .equ    (MM_B3F + 0x6000) ; y * _g_bmapwidth for each row
                                      ;   (P_InitBlockRows, src/iigs/p_map65.s)

IC_NEXT       .equ    (MM_B3F + 0xe800) ; the intercepts by frac (icInsert of
IC_LAST       .equ    (MM_B3F + 0xea84) ;   src/iigs/p_trace65.s)
PT_JMP        .equ    DC_EXITP        ; the traverser for jml [] (bank 0), free
                                      ; in the game code

              .section znear, bss
              .public G_MX, G_MY, G_OFS, G_N, G_ID, PT_FLAGS, G_IDT, GW_TAG
              .public PT_FLP, ptL1, ptL2, ptL3, ptG1, ptG2
PT_FLAGS:     .space  2
PT_X1:        .space  4               ; x1, y1, x2, y2
PT_Y1:        .space  4
PT_X2:        .space  4
PT_Y2:        .space  4
PT_XT1:       .space  2               ; the block of each end
PT_YT1:       .space  2
PT_XT2:       .space  2
PT_YT2:       .space  2
PT_XSTEP:     .space  4
PT_YSTEP:     .space  4
PT_XI:        .space  4               ; xintercept, yintercept
PT_YI:        .space  4
PT_MX:        .space  2               ; mapx, mapy
PT_MY:        .space  2
PT_MXS:       .space  2               ; mapxstep, mapystep
PT_MYS:       .space  2
PT_COUNT:     .space  2
PT_T:         .space  4
AX_A:         .space  2               ; axisStep: this axis, 0 or 4
AX_OT:        .space  2               ; the other axis, 4 or 0
AX_P:         .space  2               ; partial
PT_TRV        .equ    PT_T            ; the blocks (after axisStep): the trav
PT_TR0        .equ    (PT_T+2)        ;   calls, their number at the step
PT_IP0        .equ    AX_P            ;   start, the first intercept of the
PT_END        .equ    AX_A            ;   things of the block, a copy end
G_TIGHT       .equ    AX_OT           ; guard: 1: count with the sides
G_IDT         .equ    G_OFS           ; after it: its G_ID, 0: none (the
                                      ;   lines it found not crossed have
                                      ;   GSTAMP = G_IDT | 0x8000, crossed
                                      ;   G_IDT | 0x4000, traceLines)
TI_N:         .space  2               ; P_TraverseIntercepts: count
TI_IN:        .space  2               ; in (near address)
TI_DIST:      .space  4
G_DOY         .equ    TI_DIST         ; gWalk1: W * MYS, the steps left (the
G_LEFT        .equ    (TI_DIST+2)     ;   guard runs after the use of TI_DIST)
TI_LIM:       .space  4               ; the intercepts up to this frac
PT_K:         .space  2               ; 128 * FRACUNIT / the trace length, 0: none
PT_OK:        .space  2               ; guard: 0 not yet, 1 passed, 0xffff failed
G_MX:         .space  2               ; guard: a copy of the steps
G_MY:         .space  2
G_XI:         .space  4
G_YI:         .space  4
G_COUNT:      .space  2
G_N:          .space  2               ; intercepts so far and to come, * SIZEOF_IC
G_OFS:        .space  2
G_ID:         .space  2               ; the number of this guard run, never 0
G_PREV:       .space  2               ; the first walk: the block before,
                                      ;   0x8000 none
GW_TAG:       .space  2               ; the tag of GW_TAB for this level: 1 to
                                      ;   255 in the high byte (P_InitFlood of
                                      ;   src/iigs/p_pspr65.s), 0 at the start
PT_FLP:       .space  2               ; the flags ptPatch set the branches
                                      ;   of for (sideSetup)
              .space  2               ; (free: kept for the layout)

;;; With TICSTEP = 1 this code is in bank 0: in the slots $2000-$3DFF it
;;; shared the cache slots of PIT_AddLineIntercepts and other code of the
;;; same traces.
#if TICSTEP > 1
              .section logiccode, text
#else
              .section code, text
#endif

;;; ---------------------------------------------------------------------------
;;; fixed_t P_AproxDistance(fixed_t dx, fixed_t dy)
;;; In: X:C = dx, _Dp[0-3] = dy. Out: X:C; _Dp[0-3] changes.
;;;   dx = labs(dx), dy = labs(dy); dx + dy - ((dx < dy ? dx : dy) >> 1)
;;; In registers: dx in X:Y; dy stays in _Dp. The smaller one m goes in
;;; as (m >> 1) + (m & 1), which is m - (m >> 1).
;;; ---------------------------------------------------------------------------
              .public P_AproxDistance
P_AproxDistance:
              tay                           ; dx = labs(dx) in X:Y
              cpx     ##0
              bpl     1$
              eor     ##0xffff
              clc
              adc     ##1
              tay
              txa
              eor     ##0xffff
              adc     ##0
              tax
1$:           lda     dp:.tiny (_Dp+2)      ; dy = labs(dy), in place
              bpl     2$
              lda     ##0
              sec
              sbc     dp:.tiny _Dp
              sta     dp:.tiny _Dp
              lda     ##0
              sbc     dp:.tiny (_Dp+2)
              sta     dp:.tiny (_Dp+2)
2$:           tya                           ; dx < dy (signed)?
              cmp     dp:.tiny _Dp
              txa
              sbc     dp:.tiny (_Dp+2)
              bvc     3$
              eor     ##0x8000
3$:           bpl     5$
              txa                           ; yes: dy + (dx >> 1) + (dx & 1),
              cmp     ##0x8000              ;   which is dx + dy - (dx >> 1)
              ror     a                     ;   (an arithmetic shift)
              tax
              tya
              ror     a                     ; (C = dx & 1)
              adc     dp:.tiny _Dp
              tay
              txa
              adc     dp:.tiny (_Dp+2)
              tax
              tya
              rtl
5$:           lda     dp:.tiny (_Dp+2)      ; no: dx + (dy >> 1) + (dy & 1),
              cmp     ##0x8000              ;   with dy >> 1 in place
              ror     a
              sta     dp:.tiny (_Dp+2)
              lda     dp:.tiny _Dp
              ror     a                     ; (C = dy & 1)
              sta     dp:.tiny _Dp
              tya
              adc     dp:.tiny _Dp
              tay
              txa
              adc     dp:.tiny (_Dp+2)
              tax
              tya
              rtl

;;; ---------------------------------------------------------------------------
;;; boolean P_PathTraverse(fixed_t x1, fixed_t y1, fixed_t x2, fixed_t y2,
;;;                        int16_t flags, boolean trav(intercept_t*))
;;; In: X:C = x1, _Dp[0-3] = y1, _Dp[4-7] = x2; on the stack y2, flags,
;;; trav (the caller removes them).
;;; Collects the lines (PT_ADDLINES) and things (PT_ADDTHINGS) of the blocks
;;; along the trace, then calls trav for them from the nearest one.
;;;
;;; The early traversal (a long trace): after each block, the intercepts
;;; that no later block can come before already go to trav, so a trace that
;;; stops at a near wall does not collect the blocks behind it. The calls
;;; of trav are the same, in the same order: with more than MAXINTERCEPTS
;;; intercepts the C code calls trav for none of them, so before the first
;;; early call the guard proves that the whole trace has no more.
;;; ---------------------------------------------------------------------------
              .public P_PathTraverse
P_PathTraverse:
              sta     .near PT_X1
              stx     .near (PT_X1+2)
              lda     dp:.tiny _Dp
              sta     .near PT_Y1
              lda     dp:.tiny (_Dp+2)
              sta     .near (PT_Y1+2)
              lda     dp:.tiny (_Dp+4)
              sta     .near PT_X2
              lda     dp:.tiny (_Dp+6)
              sta     .near (PT_X2+2)
              lda     4,s
              sta     .near PT_Y2
              lda     6,s
              sta     .near (PT_Y2+2)
              lda     10,s
              sta     dp:.tiny PT_JMP
              lda     12,s
              sta     dp:.tiny (PT_JMP+2)
              lda     8,s
              sta     .near PT_FLAGS
              and     ##CONST_PT_ADDTHINGS  ; with things (the shots), _Dp[8-15]
              beq     ptBody                ;   of the caller is kept here once
              pei     dp:.tiny (_Dp+14)     ;   for the trace: traceLines and
              pei     dp:.tiny (_Dp+12)     ;   traceThings of
              pei     dp:.tiny (_Dp+10)     ;   src/iigs/p_trace65.s use it
              pei     dp:.tiny (_Dp+8)      ;   (else it is kept around
              jsl     long:ptBody           ;   traceLines, 10$)
              tay
              pla
              sta     dp:.tiny (_Dp+8)
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+12)
              pla
              sta     dp:.tiny (_Dp+14)
              tya
              rtl

ptBody:       inc     .near validcount
              lda     ##.near intercepts    ; intercept_p = intercepts
              sta     .near intercept_p
              lda     ##.word2 intercepts
              sta     .near (intercept_p+2)
              lda     ##0xffff              ; (none by frac)
              sta     long:(IC_NEXT+MAXINTERCEPTS*SIZEOF_IC)
              lda     ##(MAXINTERCEPTS * SIZEOF_IC)
              sta     long:IC_LAST

              ;; do not start exactly on a block line: + FRACUNIT
              ldx     ##.near PT_X1
              ldy     ##.near _g_bmaporgx
              jsr     .kbank offLine
              ldx     ##.near PT_Y1
              ldy     ##.near _g_bmaporgy
              jsr     .kbank offLine

              lda     .near PT_X1           ; the trace
              sta     .near (_g_trace+OFS_DL_X)
              lda     .near (PT_X1+2)
              sta     .near (_g_trace+OFS_DL_X+2)
              lda     .near PT_Y1
              sta     .near (_g_trace+OFS_DL_Y)
              lda     .near (PT_Y1+2)
              sta     .near (_g_trace+OFS_DL_Y+2)
              lda     .near PT_X2           ; dx = x2 - x1
              sec
              sbc     .near PT_X1
              sta     .near (_g_trace+OFS_DL_DX)
              lda     .near (PT_X2+2)
              sbc     .near (PT_X1+2)
              sta     .near (_g_trace+OFS_DL_DX+2)
              lda     .near PT_Y2           ; dy = y2 - y1
              sec
              sbc     .near PT_Y1
              sta     .near (_g_trace+OFS_DL_DY)
              lda     .near (PT_Y2+2)
              sbc     .near (PT_Y1+2)
              sta     .near (_g_trace+OFS_DL_DY+2)
              jsl     long:longTrace        ; TR_LONG: the lines test the ends
              lda     ##0                   ;   (src/iigs/p_trace65.s)
              rol     a
              sta     .near TR_LONG
              jsl     long:sideSetup        ; the vertex sides of the trace
              stz     .near G_IDT           ; (no count of guard with the sides)

              ;; K = 128 * FRACUNIT / L for the early traversal, with L a
              ;; length >= the trace: P_AproxDistance (>= the true length)
              ;; rounded up; 0 for a trace of 128 units or less
              stz     .near PT_K
              stz     .near PT_OK
              lda     .near (_g_trace+OFS_DL_DY)
              sta     dp:.tiny _Dp
              lda     .near (_g_trace+OFS_DL_DY+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near (_g_trace+OFS_DL_DX)
              ldx     .near (_g_trace+OFS_DL_DX+2)
              jsl     long:P_AproxDistance
              txa
              inc     a
              cmp     ##129
              bcc     9$
              sta     dp:.tiny (_Dp+4)      ; 0x800000 / L
              stz     dp:.tiny (_Dp+6)
              stz     dp:.tiny _Dp
              lda     ##0x0080
              sta     dp:.tiny (_Dp+2)
              jsl     long:_UDivMod32
              sta     .near PT_K

              ;; the points from the block map origin, and their blocks
9$:
              ldx     ##.near PT_X1
              ldy     ##.near _g_bmaporgx
              jsr     .kbank fromOrigin
              sta     .near PT_XT1
              ldx     ##.near PT_Y1
              ldy     ##.near _g_bmaporgy
              jsr     .kbank fromOrigin
              sta     .near PT_YT1
              ldx     ##.near PT_X2
              ldy     ##.near _g_bmaporgx
              jsr     .kbank fromOrigin
              sta     .near PT_XT2
              ldx     ##.near PT_Y2
              ldy     ##.near _g_bmaporgy
              jsr     .kbank fromOrigin
              sta     .near PT_YT2

              ;; the steps: x (ystep, yintercept), then y (xstep, xintercept)
              ldx     ##0
              jsr     .kbank axisStep
              ldx     ##4
              jsr     .kbank axisStep

              ;; the blocks along the trace
              lda     .near PT_XT1
              sta     .near PT_MX
              lda     .near PT_YT1
              sta     .near PT_MY
              stz     .near PT_COUNT
10$:          lda     .near PT_TRV          ; (16$)
              sta     .near PT_TR0
91$:          .byte   0x80, 11$-(91$+2), 6, 11$-(91$+2) ; PT_ADDLINES (ptPatch)
              .space  4
ptL1          .equ    91$
              lda     .near PT_MY           ; P_BlockLinesIterator(mapx, mapy, PIT_AddLineIntercepts)
              sta     dp:.tiny _Dp
              lda     .near VT_RR           ; (traceLines: the same with the
              beq     101$                  ;   fast sides, src/iigs/p_trace65.s)
92$:          .byte   0x80, 6, 100$-(92$+2), 6 ; no things: _Dp[8-15] kept here
              .space  4
ptL2          .equ    92$
              pei     dp:.tiny (_Dp+14)
              pei     dp:.tiny (_Dp+12)
              pei     dp:.tiny (_Dp+10)
              pei     dp:.tiny (_Dp+8)
              lda     .near PT_MX
              jsl     long:traceLines
              tay
              pla
              sta     dp:.tiny (_Dp+8)
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+12)
              pla
              sta     dp:.tiny (_Dp+14)
              tya
              bra     102$
100$:         lda     .near PT_MX
              jsl     long:traceLines
              bra     102$
101$:         lda     ##.word0 PIT_AddLineIntercepts
              sta     dp:.tiny (_Dp+4)
              lda     ##.word2 PIT_AddLineIntercepts
              sta     dp:.tiny (_Dp+6)
              lda     .near PT_MX
              jsl     long:P_BlockLinesIterator
102$:         cmp     ##0
              bne     11$
              brl     19$                   ; early out
11$:          lda     .near intercept_p     ; (16$)
              sta     .near PT_IP0
93$:          .byte   0x80, 12$-(93$+2), 6, 12$-(93$+2) ; PT_ADDTHINGS (ptPatch)
              .space  4
ptL3          .equ    93$
              lda     .near PT_MY           ; P_BlockThingsIterator(mapx, mapy,
              sta     dp:.tiny _Dp          ;   PIT_AddThingIntercepts): the same
              lda     .near PT_MX           ;   walk with the fast sides first
              jsl     long:traceThings      ;   (src/iigs/p_trace65.s; Z: C
              beq     19$                   ;   is 0)
12$:          lda     .near PT_K            ; the early traversal
              beq     121$
              jsr     .kbank early
              bcs     121$
              brl     19$                   ; trav said false
121$:         lda     .near PT_MX           ; the last block?
              cmp     .near PT_XT2
              bne     13$
              lda     .near PT_MY
              cmp     .near PT_YT2
              beq     20$
13$:          lda     .near (PT_YI+2)       ; (yintercept >> FRACBITS) == mapy
              cmp     .near PT_MY
              bne     14$
              clc                           ; yintercept += ystep, mapx += mapxstep
              lda     .near PT_YI
              adc     .near PT_YSTEP
              sta     .near PT_YI
              lda     .near (PT_YI+2)
              adc     .near (PT_YSTEP+2)
              sta     .near (PT_YI+2)
              lda     .near PT_MX
              clc
              adc     .near PT_MXS
              sta     .near PT_MX
              bra     15$
14$:          lda     .near (PT_XI+2)       ; (xintercept >> FRACBITS) == mapx
              cmp     .near PT_MX
              bne     16$
              clc                           ; xintercept += xstep, mapy += mapystep
              lda     .near PT_XI
              adc     .near PT_XSTEP
              sta     .near PT_XI
              lda     .near (PT_XI+2)
              adc     .near (PT_XSTEP+2)
              sta     .near (PT_XI+2)
              lda     .near PT_MY
              clc
              adc     .near PT_MYS
              sta     .near PT_MY
15$:          inc     .near PT_COUNT        ; for (count = 0; count < 64; count++)
              lda     .near PT_COUNT
              cmp     ##64
              bcs     20$
              brl     10$
19$:          lda     ##0                   ; false
              rtl
20$:          jmp     .kbank traverse

16$:          jsl     long:ptStuck          ; no step (A: 0 false, 1 the
              dec     a                     ;   traversal, 2 on)
              bmi     19$
              beq     20$
              bra     15$

;;; offLine: if ((v - origin) & (MAPBLOCKSIZE - 1)) == 0, v += FRACUNIT, for
;;; the fixed_t at near X and the origin at near Y.
offLine:      lda     abs:0,x
              sec
              sbc     abs:0,y
              bne     9$                    ; bits 0..15
              lda     abs:2,x
              sbc     abs:2,y
              and     ##0x007f              ; bits 16..22
              bne     9$
              inc     abs:2,x
9$:           rts

;;; fromOrigin: the fixed_t at near X -= the origin at near Y; C = it >>
;;; MAPBLOCKSHIFT (FRACBITS + 7), arithmetic: bits 23..30 of it and the
;;; sign.
fromOrigin:   lda     abs:0,x
              sec
              sbc     abs:0,y
              sta     abs:0,x
              lda     abs:2,x
              sbc     abs:2,y
              sta     abs:2,x
              asl     a
              xba                           ; (xba keeps the carry)
              and     ##0x00ff
              bcc     1$
              ora     ##0xff00
1$:           rts

;;; axisStep: the steps for one axis a (X = 0: x, 4: y) and the other
;;; axis b; the outputs are mapxstep, ystep, yintercept for x and mapystep,
;;; xstep, xintercept for y:
;;;   at2 > at1: step 1,  partial = FRACUNIT - ((a1 >> 7) & 0xffff)
;;;              bstep = FixedApproxDiv(b2 - b1, a2 - a1)
;;;   at2 < at1: step -1, partial = (a1 >> 7) & 0xffff
;;;              bstep = FixedApproxDiv(b2 - b1, a1 - a2)
;;;   both:      bintercept = (b1 >> 7) + FixedMul3216(bstep, partial)
;;;   else:      step 0, bstep = 256 * FRACUNIT, bintercept = (b1 >> 7) + bstep
;;; partial is the uint16_t argument of FixedMul3216 (FRACUNIT gives 0).
axisStep:     stx     .near AX_A
              txa
              eor     ##4
              sta     .near AX_OT
              txa
              lsr     a
              tay                           ; Y = X / 2
              lda     .near PT_XT2,y        ; at2 - at1, signed
              sec
              sbc     .near PT_XT1,y
              bne     1$
              brl     30$
1$:           bvc     2$
              eor     ##0x8000
2$:           bmi     20$
              lda     ##1                   ; at2 > at1
              sta     .near PT_MXS,y
              jsr     .kbank a1Shr7
              eor     ##0xffff
              inc     a
              sta     .near AX_P
              ldx     .near AX_A            ; a2 - a1
              lda     .near PT_X2,x
              sec
              sbc     .near PT_X1,x
              sta     dp:.tiny _Dp
              lda     .near (PT_X2+2),x
              sbc     .near (PT_X1+2),x
              sta     dp:.tiny (_Dp+2)
              bra     25$
20$:          lda     ##0xffff              ; at2 < at1
              sta     .near PT_MXS,y
              jsr     .kbank a1Shr7
              sta     .near AX_P
              ldx     .near AX_A            ; a1 - a2
              lda     .near PT_X1,x
              sec
              sbc     .near PT_X2,x
              sta     dp:.tiny _Dp
              lda     .near (PT_X1+2),x
              sbc     .near (PT_X2+2),x
              sta     dp:.tiny (_Dp+2)
25$:          ldx     .near AX_OT           ; bstep = FixedApproxDiv(b2 - b1, _Dp)
              lda     .near PT_X2,x
              sec
              sbc     .near PT_X1,x
              tay
              lda     .near (PT_X2+2),x
              sbc     .near (PT_X1+2),x
              tax
              tya
              jsl     long:FixedApproxDiv
              ldy     .near AX_OT           ; into bstep: PT_XSTEP + 4 - axis
              sta     .near PT_XSTEP,y
              txa
              sta     .near (PT_XSTEP+2),y
              lda     .near AX_P            ; FixedMul3216(bstep, partial)
              sta     dp:.tiny _Dp
              lda     .near PT_XSTEP,y
              jsl     long:FixedMul3216
              bra     40$
30$:          sta     .near PT_MXS,y        ; at2 == at1: step 0
              ldy     .near AX_OT           ; bstep = 256 * FRACUNIT
              sta     .near PT_XSTEP,y
              lda     ##256
              sta     .near (PT_XSTEP+2),y
              tax
              lda     ##0
40$:          sta     .near PT_T            ; bintercept = (b1 >> 7) + X:C
              stx     .near (PT_T+2)
              ldx     .near AX_OT
              lda     .near (PT_X1+2),x     ; b1 >> 7 (arithmetic): its high
              asl     a                     ;   word is bits 23..30 of b1 and the
              xba                           ;   sign (xba keeps the carry)
              and     ##0x00ff
              bcc     41$
              ora     ##0xff00
41$:          tay
              lda     .near PT_X1,x         ; its low word: bits 7..22 of b1
              xba
              asl     a
              lda     .near (PT_X1+1),x
              rol     a
              clc
              adc     .near PT_T
              sta     .near PT_XI,x
              tya
              adc     .near (PT_T+2)
              sta     .near (PT_XI+2),x
              rts

;;; a1Shr7: C = (a1 >> 7) & 0xffff, bits 7..22 of a1 (a1 at PT_X1 + AX_A).
a1Shr7:       ldx     .near AX_A
              lda     .near PT_X1,x         ; bit 7 into carry
              xba
              asl     a
              lda     .near (PT_X1+1),x     ; bits 8..23
              rol     a
              rts

;;; ---------------------------------------------------------------------------
;;; traverse: P_TraverseIntercepts(trav): trav for each intercept from the
;;; nearest one, up to FRACUNIT, while it returns true. C = the result.
;;; ---------------------------------------------------------------------------
traverse:     stz     .near TI_LIM          ; up to FRACUNIT
              lda     ##1
              sta     .near (TI_LIM+2)
              jsr     .kbank traverseTo
              lda     ##0                   ; C = carry
              rol     a
              rtl

;;; early: after the blocks so far, every intercept still to come is more
;;; than (M - 1) * 128 - 43 map units from the start, M = max(|mapx - xt1|,
;;; |mapy - yt1|): a point of a later block is more than (M - 1) * 128
;;; units away, the lines there cross the trace there, and a thing there
;;; reaches at most 43 units nearer (radius 30 of info65.s, times sqrt 2).
;;; So its frac is above T = (M - 2) * K, with 85 units for the rounding of
;;; the fracs. The intercepts below T go to trav now. Out: carry clear when
;;; trav said false.
early:        lda     .near PT_MX           ; M
              sec
              sbc     .near PT_XT1
              bpl     1$
              eor     ##0xffff
              inc     a
1$:           sta     .near TI_DIST
              lda     .near PT_MY
              sec
              sbc     .near PT_YT1
              bpl     2$
              eor     ##0xffff
              inc     a
2$:           cmp     .near TI_DIST
              bcs     3$
              lda     .near TI_DIST
3$:           sec                           ; M - 2 > 0?
              sbc     ##2
              beq     9$
              bmi     9$
              tax
              bra     4$                    ; no guard (decision 34): a trace
              .space  5                     ;   over MAXINTERCEPTS hits first
              phx
              lda     ##0x8000              ; (the first walk: no block
              sta     .near G_PREV          ;   before)
              jsl     long:guardL           ; (cold code)
              plx
              lda     ##1
              bcs     31$
              lda     ##0xffff
31$:          sta     .near PT_OK
              bmi     9$
4$:           txa
              ldx     .near PT_K            ; T = (M - 2) * K, up to T - 1
              jsl     long:_Mul16
              sec
              sbc     ##1
              sta     .near TI_LIM
              txa
              sbc     ##0
              sta     .near (TI_LIM+2)
              cmp     ##1                   ; but not above FRACUNIT, the end
              bcc     5$                    ;   of P_TraverseIntercepts (when
              bne     51$                   ;   the walk misses the last block)
              lda     .near TI_LIM
              beq     5$
51$:          stz     .near TI_LIM
              lda     ##1
              sta     .near (TI_LIM+2)
5$:           brl     traverseTo
9$:           sec
              rts

;;; The guard (guardL, cold code): carry set if the whole trace can have
;;; no more than MAXINTERCEPTS intercepts: those so far, plus the lines of
;;; the lists of the blocks still to come, plus the things of those blocks.
;;; The blocks come from a copy of the steps of the collection loop.

;;; gBlockL: the count of block (G_MX, G_MY) for gStuck: gBlk in the first
;;; walk, gBlockT in the second.
gBlockL:      lda     .near G_TIGHT         ; (the count with the sides)
              beq     gBlk
              jmp     long:gBlockT

;;; gBlk: G_N += SIZEOF_IC for each line of block (G_MX, G_MY) that is not
;;; in the block visited before in this walk (G_PREV: all when there is
;;; none, none when it is the same block) (PT_ADDLINES), and for each thing
;;; in it (PT_ADDTHINGS), as P_BlockLinesIterator and P_BlockThingsIterator
;;; would visit them. A line that the walk leaves and meets again counts
;;; again, and a line that is collected already counts too: the count stays
;;; above the true one, and the second walk (gBlockT) takes off each line
;;; at most once. The counts of the lines come from GW_TAB: at 10 * the
;;; block, + 0 all its lines, + 2 the block before at x - 1, + 4 at x + 1,
;;; + 6 at y - 1, + 8 at y + 1: the tag of the level in the high byte, 10 *
;;; the count in the low byte (gwMiss makes them).
gBlk:         lda     .near G_MX            ; 0 <= x < _g_bmapwidth, 0 <= y <
              cmp     .near _g_bmapwidth    ;   _g_bmapheight (unsigned: below
              bcs     0$                    ;   0 is above)
              lda     .near G_MY
              cmp     .near _g_bmapheight
              bcc     10$
0$:           rtl                           ; (outside: the steps only go
                                            ;   away from the map)
10$:          asl     a                     ; y * _g_bmapwidth + x (BMROW)
              tax
              lda     long:BMROW,x
              clc
              adc     .near G_MX
              sta     .near G_OFS
94$:          .byte   0x80, 5$-(94$+2), 6, 5$-(94$+2) ; PT_ADDLINES (ptPatch)
              .space  4
ptG1          .equ    94$
              ldy     ##0                   ; Y = + 0: no block before
              lda     .near G_PREV
              bmi     12$
              eor     ##0xffff              ; the step G_OFS - G_PREV: 0 the
              sec                           ;   same block (its lines are
              adc     .near G_OFS           ;   counted), 1 or W from x - 1
              beq     5$                    ;   or y - 1 (+ 2, + 6), -1 or -W
              bmi     11$                   ;   from x + 1 or y + 1 (+ 4, + 8)
              ldy     ##2
              bra     111$
11$:          ldy     ##4
              eor     ##0xffff
              inc     a
111$:         dec     a
              beq     12$
              iny
              iny
              iny
              iny
12$:          lda     .near G_OFS           ; a place in GW_TAB?
              cmp     ##GW_MAXB
              bcs     13$
              asl     a                     ; 10 * the block + Y
              asl     a
              adc     .near G_OFS
              asl     a
              sty     dp:.tiny _Dp
              adc     dp:.tiny _Dp
              tax
              lda     long:GW_TAB,x         ; for this level?
              eor     .near GW_TAG
              cmp     ##0x100
              bcs     14$
              adc     .near G_N             ; yes: G_N += 10 * the count
              sta     .near G_N
              lda     .near G_OFS           ; (the block before of the next)
              sta     .near G_PREV
              bra     5$
13$:          ldx     ##0xffff              ; no place
14$:          jsl     long:gwMiss           ; (cold code)
              lda     .near _g_blocklinks   ; [_Dp+4] again
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_blocklinks+2)
              sta     dp:.tiny (_Dp+6)
5$:           .byte   0x80, 9$-(5$+2), 6, 9$-(5$+2) ; PT_ADDTHINGS (ptPatch)
              .space  4
ptG2          .equ    5$
              lda     .near G_OFS           ; the things of the block (the block
              asl     a                     ;   links at [_Dp+4]: gRun)
              asl     a
              tay
              lda     [.tiny (_Dp+4)],y
              iny
              iny
              ora     [.tiny (_Dp+4)],y
              beq     9$
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny (_Dp+2)
              dey
              dey
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny _Dp
              ldx     .near G_N
6$:           txa                           ; + SIZEOF_IC for each one
              clc
              adc     ##SIZEOF_IC
              tax
              ldy     ##(OFS_MO_BNEXT+2)
              lda     [.tiny _Dp],y
              pha
              ldy     ##OFS_MO_BNEXT
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
              ora     dp:.tiny _Dp
              bne     6$
              stx     .near G_N
9$:           rtl
              .space  PAD_GB                ; (traverseTo keeps its place)

;;; traverseTo: trav for each intercept with frac <= TI_LIM, from the nearest
;;; (the first of equal ones: the list IC_NEXT by frac), while it returns
;;; true; each one leaves the list and gets frac INT32_MAX after its call.
;;; Out: carry clear when trav said false.
traverseTo:   ldx     ##(MAXINTERCEPTS * SIZEOF_IC) ; the first one
              lda     long:IC_NEXT,x
              bmi     8$
              tax
              lda     .near TI_LIM          ; frac > the limit: all done
              cmp     .near (intercepts+OFS_IC_FRAC),x
              lda     .near (TI_LIM+2)
              sbc     .near (intercepts+OFS_IC_FRAC+2),x
              bvc     1$
              eor     ##0x8000
1$:           bmi     8$
              lda     long:IC_NEXT,x        ; off the list (IC_LAST: the head
              phx                           ;   when it was the last one in)
              ldx     ##(MAXINTERCEPTS * SIZEOF_IC)
              sta     long:IC_NEXT,x
              pla
              cmp     long:IC_LAST
              bne     11$
              pha
              txa
              sta     long:IC_LAST
              pla
11$:
              inc     .near PT_TRV          ; (16$ of P_PathTraverse)
              clc                           ; trav(in)
              adc     ##.near intercepts
              sta     .near TI_IN
              sta     dp:.tiny _Dp
              lda     ##.word2 intercepts
              sta     dp:.tiny (_Dp+2)
              jsl     long:callTrav
              cmp     ##0
              bne     2$
              clc                           ; false
              rts
2$:           ldx     .near TI_IN           ; in->frac = INT32_MAX
              lda     ##0xffff
              sta     abs:OFS_IC_FRAC,x
              lda     ##0x7fff
              sta     abs:(OFS_IC_FRAC+2),x
              bra     traverseTo
8$:           sec
              rts

callTrav:     .byte   0xdc                  ; jml [PT_JMP]
              .word   .word0 PT_JMP

;;; ---------------------------------------------------------------------------
;;; ptStuck: no step of the walk of P_PathTraverse: it stays in this block
;;; up to count 64. When trav ran for none of its intercepts, nothing
;;; changed, and the next steps only add the intercepts of its things again
;;; (its lines have the validcount, early finds nothing new): they are
;;; copied here (a forward copy repeats them). Out: C = 0 false (they do not
;;; fit), 1 the traversal, 2 the next step as usual.
;;; guardL: guard. The first walk counts all lines and things of the
;;; blocks to come; above MAXINTERCEPTS, with the fast sides, a second walk
;;; takes off those the trace does not cross, until the count is low
;;; enough. Out: carry as guard.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
ptStuck:      lda     .near PT_TRV          ; trav ran: the next step as usual
              cmp     .near PT_TR0
              bne     8$
              lda     .near intercept_p     ; n: the bytes of its things
              sec
              sbc     .near PT_IP0
              beq     7$
              sta     .near PT_END
              lda     ##63                  ; 63 - count more steps, n each
              sec
              sbc     .near PT_COUNT
              beq     7$
              tax
              lda     ##0
1$:           clc
              adc     .near PT_END
              dex
              bne     1$
              clc                           ; the end of the copy
              adc     .near intercept_p
              bcs     6$
              cmp     ##.word0 (intercepts + MAXINTERCEPTS * SIZEOF_IC + 1)
              bcs     6$                    ; more than MAXINTERCEPTS: false
              sta     .near PT_END
              ldx     .near PT_IP0
              ldy     .near intercept_p
2$:           lda     abs:0,x
              sta     abs:0,y
              inx
              inx
              iny
              iny
              cpy     .near PT_END
              bcc     2$
              lda     .near intercept_p     ; the copies into the list by frac
3$:           pha
              sec
              sbc     ##.near intercepts
              tay
              jsl     long:icInsertL
              pla
              clc
              adc     ##SIZEOF_IC
              cmp     .near PT_END
              bcc     3$
              sta     .near intercept_p
7$:           lda     ##1
              rtl
6$:           lda     ##0
              rtl
8$:           lda     ##2
              rtl

guardL:       stz     .near G_TIGHT         ; the first walk: all lines and
              jsr     .kbank gRun           ;   things of the blocks to come
              bcs     2$
              lda     .near VT_RR           ; too many: with the fast sides,
              beq     2$                    ;   a second walk takes off those
              lda     .near G_N             ;   the trace does not cross
              cmp     ##0x7000              ;   (gBlockT), block by block, up
              bcs     1$                    ;   to MAXINTERCEPTS
              inc     .near G_TIGHT
              jsr     .kbank gRun
              lda     .near G_ID            ; (the carry stays)
              sta     .near G_IDT
              rtl
1$:           clc
2$:           stz     .near G_IDT
              rtl

;;; gNewId: a new number G_ID for GSTAMP (bits 14, 15: gBlockT): after
;;; 0x3fff, and in the first run of a level (G_ID = 0, P_SetupLevel), no
;;; stamps for its lines.
gNewId:       lda     .near G_ID
              inc     a
              cmp     ##0x4000
              bcs     9$
              cmp     ##1
              bne     11$
9$:           lda     .near _g_numlines
              asl     a
              tax
              lda     ##0
10$:          dex
              dex
              bmi     12$
              sta     long:GSTAMP,x
              bra     10$
12$:          lda     ##1
11$:          sta     .near G_ID
              rts

;;; gRun: a walk of guard, with gBlock (the second one: gBlockT, the count
;;; goes on from the first). Out: carry set when the count is at most
;;; MAXINTERCEPTS (gCheck can end the walk before its last block).
gRun:         jsr     .kbank gNewId
              lda     .near _g_blocklinks   ; [_Dp+4]: the block links (gBlk)
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_blocklinks+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near G_TIGHT
              bne     1$
              lda     .near intercept_p
              sec
              sbc     ##.near intercepts
              sta     .near G_N
1$:           lda     .near PT_MX
              sta     .near G_MX
              lda     .near PT_MY
              sta     .near G_MY
              lda     .near PT_XI
              sta     .near G_XI
              lda     .near (PT_XI+2)
              sta     .near (G_XI+2)
              lda     .near PT_YI
              sta     .near G_YI
              lda     .near (PT_YI+2)
              sta     .near (G_YI+2)
              lda     .near PT_COUNT
              sta     .near G_COUNT
2$:           lda     .near G_MX            ; the last block?
              cmp     .near PT_XT2
              bne     3$
              lda     .near G_MY
              cmp     .near PT_YT2
              beq     gEnd
3$:           lda     .near (G_YI+2)        ; the next block, as 13$..15$ of
              cmp     .near G_MY            ;   P_PathTraverse
              bne     4$
              clc
              lda     .near G_YI
              adc     .near PT_YSTEP
              sta     .near G_YI
              lda     .near (G_YI+2)
              adc     .near (PT_YSTEP+2)
              sta     .near (G_YI+2)
              lda     .near G_MX
              clc
              adc     .near PT_MXS
              sta     .near G_MX
              bra     5$
4$:           lda     .near (G_XI+2)
              cmp     .near G_MX
              bne     gStuck
              clc
              lda     .near G_XI
              adc     .near PT_XSTEP
              sta     .near G_XI
              lda     .near (G_XI+2)
              adc     .near (PT_XSTEP+2)
              sta     .near (G_XI+2)
              lda     .near G_MY
              clc
              adc     .near PT_MYS
              sta     .near G_MY
5$:           inc     .near G_COUNT         ; no more after 64 steps
              lda     .near G_COUNT
              cmp     ##64
              bcs     gEnd
              jsl     long:gBlockW          ; (the first walk: on in gWalk1)
              jsr     .kbank gCheck
              beq     2$
gRet:         lsr     a                     ; (1: carry set, 2: clear)
              rts
gEnd:         lda     .near G_N             ; the end: at most MAXINTERCEPTS?
              cmp     ##(MAXINTERCEPTS * SIZEOF_IC + 1)
              bcs     gFail
              sec
              rts
gFail:        clc
              rts

;;; gStuck: no step of the walk: its lines are counted or collected (the
;;; visit before, or the block of the collection), so each visit from this
;;; one on counts the same for its things (T in TI_DIST). A collected line
;;; of the block of the collection counts in each visit of the first walk
;;; and goes off in each visit of the second one, as in gBlockT.
gStuck:       inc     .near G_COUNT         ; this visit
              lda     .near G_COUNT
              cmp     ##64
              bcs     gEnd
              lda     .near G_N
              sta     .near TI_DIST
              jsl     long:gBlockL
              jsr     .kbank gCheck
              bne     gRet
              lda     .near G_N
              sec
              sbc     .near TI_DIST
              sta     .near TI_DIST
              lda     .near G_MX            ; the last block? (2$ of gRun)
              cmp     .near PT_XT2
              bne     1$
              lda     .near G_MY
              cmp     .near PT_YT2
              beq     gEnd
1$:           lda     ##63                  ; the visits up to count 64, T
              sec                           ;   each: the count only grows
              sbc     .near G_COUNT         ;   (or only falls), so its end
              beq     gEnd                  ;   value tells as gCheck at each
              tax                           ;   visit would
              lda     .near G_N
2$:           clc
              adc     .near TI_DIST
              bvs     gFail                 ; (above 0x7fff: fail, not a wrap)
              dex
              bne     2$
              sta     .near G_N
              bra     gEnd

;;; gCheck: after a block: C = 0 go on, 1 end with pass (the second walk:
;;; the count is low enough), 2 end with fail (above MAXINTERCEPTS and no
;;; second walk can follow, or above 0x7000).
gCheck:       lda     .near G_N
              ldx     .near G_TIGHT
              bne     2$
              cmp     ##0x7000
              bcs     9$
              ldx     .near VT_RR           ; (a second walk can follow: the
              bne     1$                    ;   first goes to the end)
              cmp     ##(MAXINTERCEPTS * SIZEOF_IC + 1)
              bcs     9$
1$:           lda     ##0
              rts
2$:           cmp     ##(MAXINTERCEPTS * SIZEOF_IC + 1)
              bcs     1$
              lda     ##1
              rts
9$:           lda     ##2
              rts
              .space  2                     ; (the fragment keeps its size)

;;; ---------------------------------------------------------------------------
;;; gBlockW: the count of block (G_MX, G_MY) for gRun (gBlockT in the second
;;; walk). The first walk of a shot or aim goes on in gWalk1 from its first
;;; block in the map (the steps of gRun, the counts of gBlk, gCheck inline;
;;; out by gEnd, gFail or gStuck), in slots of its own (guardcode), not the
;;; BSP code's that gBlk shares. A step gives the block before (3 - MXS,
;;; 7 - MYS: the operands of wRdX, wRdY) and the next G_OFS. A walk that
;;; leaves the map never comes back, so it ends there; a zero step never
;;; comes (its intercept is 256 blocks away). G_PREV only for gwMiss, gStuck.
;;; ---------------------------------------------------------------------------
              .section guardcode, text
gBlockW:      lda     .near G_TIGHT
              bne     9$
              lda     .near PT_FLAGS
              and     ##(CONST_PT_ADDLINES | CONST_PT_ADDTHINGS)
              cmp     ##(CONST_PT_ADDLINES | CONST_PT_ADDTHINGS)
              bne     8$
              lda     .near G_MX
              cmp     .near _g_bmapwidth
              bcs     8$
              lda     .near G_MY
              cmp     .near _g_bmapheight
              bcc     gWalk1
8$:           jmp     long:gBlk
9$:           jmp     long:gBlockT
gWalk1:       tsc                           ; gRun's jsl frame off (out by jml)
              clc
              adc     ##3
              tcs
              lda     .near _g_bmapwidth    ; W * MYS
              ldx     .near PT_MYS
              bpl     1$
              eor     ##0xffff
              inc     a
1$:           sta     .near G_DOY
              lda     ##64                  ; the steps left
              sec
              sbc     .near G_COUNT
              sta     .near G_LEFT
              sep     #0x20
              lda     #3                    ; the block before of each step
              sec
              sbc     .near PT_MXS
              sta     long:(wRdX+1)
              lda     #7                    ; (W = 1: + 2, + 4 as gBlk, which takes
              ldx     .near _g_bmapwidth    ;   a step of 1 as one in x)
              cpx     ##1
              bne     2$
              lda     #3
2$:           sec
              sbc     .near PT_MYS
              sta     long:(wRdY+1)
              rep     #0x20
              jsl     long:gBlk             ; this block (the one before: G_PREV)
              brl     wChk
wStuck:       lda     ##63                  ; G_COUNT before this step, G_PREV
              sec                           ;   this block (counted)
              sbc     .near G_LEFT
              sta     .near G_COUNT
              lda     .near G_OFS
              sta     .near G_PREV
              jmp     long:gStuck
wNoPlY:       ldx     ##0xffff              ; no place
              bra     wPrevY
wMissY:       txa                           ; the place: + the block before (the
              clc                           ;   operand of wRdY: GW_TAB is at + 0
              adc     long:(wRdY+1)         ;   of a bank)
              tax
wPrevY:       lda     .near G_OFS           ; G_PREV: the block before (gwMiss)
              sec
              sbc     .near G_DOY
              brl     wMiss
wStepY:       lda     .near (G_XI+2)
              cmp     .near G_MX
              bne     wStuck
              clc                           ; y step
              lda     .near G_XI
              adc     .near PT_XSTEP
              sta     .near G_XI
              lda     .near (G_XI+2)
              adc     .near (PT_XSTEP+2)
              sta     .near (G_XI+2)
              lda     .near G_MY
              clc
              adc     .near PT_MYS
              sta     .near G_MY
              cmp     .near _g_bmapheight   ; out of the map: the end
              bcs     wEnd
              lda     .near G_OFS
              clc
              adc     .near G_DOY
              sta     .near G_OFS
              cmp     ##GW_MAXB             ; a place in GW_TAB?
              bcs     wNoPlY
              asl     a                     ; 10 * the block
              asl     a
              adc     .near G_OFS
              asl     a
              tax
wRdY:         lda     long:(GW_TAB+6),x     ; + 6 or + 8: for this level?
              eor     .near GW_TAG
              cmp     ##0x100
              bcs     wMissY
              adc     .near G_N             ; yes: G_N += 10 * the count
              sta     .near G_N
              bra     wThings
wEnd:         jmp     long:gEnd
wLoop:        lda     .near G_MX            ; the last block?
              cmp     .near PT_XT2
              bne     1$
              lda     .near G_MY
              cmp     .near PT_YT2
              beq     wEnd
1$:           sep     #0x20                 ; no more after 64 steps (a byte: no
              dec     .near G_LEFT          ;   second write)
              rep     #0x20
              beq     wEnd
              lda     .near (G_YI+2)        ; the next block, as gRun
              cmp     .near G_MY
              bne     wStepY
              clc                           ; x step
              lda     .near G_YI
              adc     .near PT_YSTEP
              sta     .near G_YI
              lda     .near (G_YI+2)
              adc     .near (PT_YSTEP+2)
              sta     .near (G_YI+2)
              lda     .near G_MX
              clc
              adc     .near PT_MXS
              sta     .near G_MX
              cmp     .near _g_bmapwidth
              bcs     wEnd
              lda     .near G_OFS
              clc
              adc     .near PT_MXS
              sta     .near G_OFS
              cmp     ##GW_MAXB
              bcs     wNoPlX
              asl     a
              asl     a
              adc     .near G_OFS
              asl     a
              tax
wRdX:         lda     long:(GW_TAB+2),x     ; + 2 or + 4
              eor     .near GW_TAG
              cmp     ##0x100
              bcs     wMissX
              adc     .near G_N
              sta     .near G_N
wThings:      lda     .near G_OFS           ; the things of the block: the bank of
              asl     a                     ;   the first at [_Dp+4] (0: none; the
              asl     a                     ;   mobjs are in the zone)
              tay
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              beq     wChk
              sta     dp:.tiny (_Dp+2)
              dey
              dey
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny _Dp
              ldx     .near G_N
2$:           txa                           ; + SIZEOF_IC for each one
              clc
              adc     ##SIZEOF_IC
              tax
              ldy     ##(OFS_MO_BNEXT+2)    ; the bank of the next (0: the end)
              lda     [.tiny _Dp],y
              beq     4$
              cmp     dp:.tiny (_Dp+2)
              bne     3$
              ldy     ##OFS_MO_BNEXT        ; the same bank: the low word only
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              bra     2$
3$:           pha
              ldy     ##OFS_MO_BNEXT
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
              bra     2$
4$:           stx     .near G_N
wChk:         lda     .near G_N             ; gCheck: fail at 0x7000, or above
              cmp     ##0x7000              ;   MAXINTERCEPTS when no second walk
              bcs     wFail                 ;   can follow
              cmp     ##(MAXINTERCEPTS * SIZEOF_IC + 1)
              bcc     5$
              ldx     .near VT_RR
              beq     wFail
5$:           brl     wLoop
wFail:        jmp     long:gFail
wNoPlX:       ldx     ##0xffff
              bra     wPrevX
wMissX:       txa
              clc
              adc     long:(wRdX+1)
              tax
wPrevX:       lda     .near G_OFS
              sec
              sbc     .near PT_MXS
wMiss:        sta     .near G_PREV
              jsl     long:gwMiss
              lda     .near _g_blocklinks   ; [_Dp+4] again
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_blocklinks+2)
              sta     dp:.tiny (_Dp+6)
              brl     wThings

;;; ---------------------------------------------------------------------------
;;; gwMiss: the count of gBlk for the lines of block G_OFS that are not in
;;; the block before (G_PREV, 0x8000: none): the lines of that block get a
;;; new stamp (G_ID: the first walk has no stamps of its own), then those
;;; of G_OFS without it count. G_N += 10 * the count, and into GW_TAB at X
;;; (0xffff: no place) with the tag when it fits in the low byte. G_PREV =
;;; G_OFS. It runs in the game tic (logiccode).
;;; ---------------------------------------------------------------------------
              .section logiccode, text
gwMiss:       stx     dp:.tiny (_Dp+6)      ; its place
              stz     dp:.tiny (_Dp+4)      ; the count
              lda     long:G_ID             ; a new stamp (as gNewId: from 1
              inc     a                     ;   after 0x3fff, no stamps)
              cmp     ##0x4000
              bcc     2$
              lda     .near _g_numlines
              asl     a
              tax
              lda     ##0
1$:           dex
              dex
              bmi     11$
              sta     long:GSTAMP,x
              bra     1$
11$:          lda     ##1
2$:           sta     long:G_ID
              lda     .near G_PREV          ; the lines of the block before
              bmi     4$                    ;   get it
              jsl     long:gwList
3$:           lda     [.tiny _Dp],y
              asl     a
              bcs     4$                    ; (0xffff: the end)
              tax
              lda     long:G_ID
              sta     long:GSTAMP,x
              iny
              iny
              bra     3$
4$:           lda     .near G_OFS           ; the lines of G_OFS without it
              sta     .near G_PREV          ;   count
              jsl     long:gwList
41$:          lda     [.tiny _Dp],y
              asl     a
              bcs     5$
              tax
              lda     long:G_ID
              cmp     long:GSTAMP,x
              beq     42$
              inc     dp:.tiny (_Dp+4)
42$:          iny
              iny
              bra     41$
5$:           lda     dp:.tiny (_Dp+4)      ; 10 * the count
              asl     a
              sta     dp:.tiny (_Dp+4)
              asl     a
              asl     a
              adc     dp:.tiny (_Dp+4)
              ldx     dp:.tiny (_Dp+6)
              bmi     6$
              cmp     ##0x100
              bcs     6$
              tay
              ora     .near GW_TAG
              sta     long:GW_TAB,x
              tya
6$:           clc
              adc     .near G_N
              sta     .near G_N
              rtl

;;; gwList: [_Dp] = the list of the lines of block C, Y = 2 (after its 0).
              .section logiccode, text
gwList:       asl     a
              tay
              lda     .near _g_blockmap
              sta     dp:.tiny _Dp
              lda     .near (_g_blockmap+2)
              sta     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp],y
              asl     a
              clc
              adc     .near _g_blockmaplump
              sta     dp:.tiny _Dp
              lda     .near (_g_blockmaplump+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##2
              rtl
