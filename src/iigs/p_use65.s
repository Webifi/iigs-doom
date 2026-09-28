;;; Using lines in 65816 assembly, Doom8088: Apple IIgs Edition.
;;;
;;; P_UseLines, PTR_UseTraverse and PTR_NoWayTraverse of p_map.c
;;; with the same results.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"

              .extern _Dp, _g_openrange, _g_opentop, _g_openbottom
              .extern P_PathTraverse, P_LineOpening, P_PointOnLineSide
              .extern P_UseSpecialLine, S_StartSound, finesine, finecosine

              .section znear, bss
usething:     .space  4               ; the mobj of the player
US_LINE:      .space  4
US_X1:        .space  4               ; the trace
US_Y1:        .space  4
US_X2:        .space  4
US_Y2:        .space  4
US_T:         .space  4

;;; Signed 32-bit a < b: lda a.lo / cmp b.lo / lda a.hi / SLT32 b.hi / bmi
SLT32         .macro  op
              sbc     \op
              bvc     1$
              eor     ##0x8000
1$:
              .endm

;;; ---------------------------------------------------------------------------
;;; void P_UseLines(player_t* player)          In: _Dp[0-3] = player.
;;; The first line within USERANGE in front of the player: a special line
;;; is used; a wall or a closed two sided line gives the sound noway.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public P_UseLines
P_UseLines:   ldy     ##(OFS_PL_MO+2)       ; usething = player->mo
              lda     [.tiny _Dp],y
              sta     .near (usething+2)
              ldy     ##OFS_PL_MO
              lda     [.tiny _Dp],y
              sta     .near usething
              jsr     .kbank useArg
              ldy     ##OFS_MO_X            ; x1, y1
              lda     [.tiny _Dp],y
              sta     .near US_X1
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (US_X1+2)
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near US_Y1
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (US_Y1+2)
              ldy     ##(OFS_MO_ANGLE+2)    ; an = angle >> 19
              lda     [.tiny _Dp],y
              lsr     a
              lsr     a
              lsr     a
              pha
              jsl     long:finecosine       ; x2 = x1 + 64 * finecosine(an)
              jsr     .kbank times64
              clc
              adc     .near US_X1
              sta     .near US_X2
              txa
              adc     .near (US_X1+2)
              sta     .near (US_X2+2)
              pla
              jsl     long:finesine         ; y2 = y1 + 64 * finesine(an)
              jsr     .kbank times64
              clc
              adc     .near US_Y1
              sta     .near US_Y2
              txa
              adc     .near (US_Y1+2)
              sta     .near (US_Y2+2)
              lda     ##.word0 PTR_UseTraverse ; a line to use
              ldx     ##.word2 PTR_UseTraverse
              jsr     .kbank useRun
              cmp     ##0
              beq     9$
              lda     ##.word0 PTR_NoWayTraverse ; none: a line in the way
              ldx     ##.word2 PTR_NoWayTraverse
              jsr     .kbank useRun
              cmp     ##0
              bne     9$
              jsr     .kbank useArg
              lda     ##CONST_SFX_NOWAY
              jsl     long:S_StartSound
9$:           rtl

;;; times64: X:C = 64 * X:C (fixed_t, the low 32 bits).
times64:      sta     .near US_T
              stx     .near (US_T+2)
              ldx     ##6
1$:           asl     .near US_T
              rol     .near (US_T+2)
              dex
              bne     1$
              lda     .near US_T
              ldx     .near (US_T+2)
              rts

;;; useRun: C = P_PathTraverse(x1, y1, x2, y2, PT_ADDLINES, the traverser X:C).
useRun:       phx
              pha
              pea     #CONST_PT_ADDLINES
              lda     .near (US_Y2+2)
              pha
              lda     .near US_Y2
              pha
              lda     .near US_X2
              sta     dp:.tiny (_Dp+4)
              lda     .near (US_X2+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near US_Y1
              sta     dp:.tiny _Dp
              lda     .near (US_Y1+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near US_X1
              ldx     .near (US_X1+2)
              jsl     long:P_PathTraverse
              ply
              ply
              ply
              ply
              ply
              rts

;;; useArg: _Dp[0-3] = usething.
useArg:       lda     .near usething
              sta     dp:.tiny _Dp
              lda     .near (usething+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; lineArg: _Dp[0-3] = US_LINE = in->d.line (in at _Dp[0-3]).
lineArg:      ldy     ##OFS_IC_D
              lda     [.tiny _Dp],y
              sta     .near US_LINE
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (US_LINE+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near US_LINE
              sta     dp:.tiny _Dp
              rts

;;; ---------------------------------------------------------------------------
;;; boolean PTR_UseTraverse(intercept_t* in)       In: _Dp[0-3] = in.
;;; A special line: used from its front side; the trace stops. Another line:
;;; the trace goes on through an opening, else noway and it stops.
;;; ---------------------------------------------------------------------------
PTR_UseTraverse:
              jsr     .kbank lineArg
              ldy     ##OFS_LINE_SPECIAL
              lda     [.tiny _Dp],y
              bne     2$
              jsl     long:P_LineOpening    ; openrange <= 0: noway
              lda     .near (_g_openrange+2)
              bmi     1$
              ora     .near _g_openrange
              bne     8$
1$:           jsr     .kbank useArg
              lda     ##CONST_SFX_NOWAY
              jsl     long:S_StartSound
              lda     ##0
              rtl
8$:           lda     ##1
              rtl
2$:           lda     .near US_LINE         ; not the back side: used
              sta     dp:.tiny (_Dp+4)
              lda     .near (US_LINE+2)
              sta     dp:.tiny (_Dp+6)
              jsr     .kbank useArg
              ldy     ##(OFS_MO_Y+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_MO_Y
              lda     [.tiny _Dp],y
              pha
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny _Dp],y
              pha
              ldy     ##OFS_MO_X
              lda     [.tiny _Dp],y
              ply
              sty     .near US_T
              ply
              sty     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldx     .near US_T
              jsl     long:P_PointOnLineSide
              cmp     ##1
              beq     9$
              jsr     .kbank useArg         ; P_UseSpecialLine(usething, line)
              lda     .near US_LINE
              sta     dp:.tiny (_Dp+4)
              lda     .near (US_LINE+2)
              sta     dp:.tiny (_Dp+6)
              jsl     long:P_UseSpecialLine
9$:           lda     ##0
              rtl

;;; ---------------------------------------------------------------------------
;;; boolean PTR_NoWayTraverse(intercept_t* in)     In: _Dp[0-3] = in.
;;; False (noway) for a line that blocks usething: not special, and
;;; blocking, closed, too high or too low.
;;; ---------------------------------------------------------------------------
PTR_NoWayTraverse:
              jsr     .kbank lineArg
              ldy     ##OFS_LINE_SPECIAL    ; a special line: true
              lda     [.tiny _Dp],y
              bne     8$
              ldy     ##OFS_LINE_FLAGS      ; always blocking
              lda     [.tiny _Dp],y
              and     ##CONST_ML_BLOCKING
              bne     9$
              jsl     long:P_LineOpening    ; no opening
              lda     .near (_g_openrange+2)
              bmi     9$
              ora     .near _g_openrange
              beq     9$
              jsr     .kbank useArg         ; too high: z + 24 < openbottom
              ldy     ##OFS_MO_Z
              lda     [.tiny _Dp],y
              sta     .near US_T
              iny
              iny
              lda     [.tiny _Dp],y
              clc
              adc     ##24
              sta     .near (US_T+2)
              lda     .near US_T
              cmp     .near _g_openbottom
              lda     .near (US_T+2)
              SLT32   .near (_g_openbottom+2)
              bmi     9$
              ldy     ##OFS_MO_Z            ; too low: opentop < z + height
              lda     [.tiny _Dp],y
              clc
              ldy     ##OFS_MO_HEIGHT
              adc     [.tiny _Dp],y
              sta     .near US_T
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_HEIGHT+2)
              adc     [.tiny _Dp],y
              sta     .near (US_T+2)
              lda     .near _g_opentop
              cmp     .near US_T
              lda     .near (_g_opentop+2)
              SLT32   .near (US_T+2)
              bmi     9$
8$:           lda     ##1
              rtl
9$:           lda     ##0
              rtl
