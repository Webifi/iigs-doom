;;; Actor movement, missile impact and player wall sliding.
;;;
;;; P_XYMovement applies horizontal momentum and collision handling;
;;; P_ZMovement handles vertical motion and floor/ceiling limits.
;;; slideMove traces the blocking wall, and hitSlideLine projects the
;;; remaining move along it. P_ExplodeMissile handles the impact transition.
;;; P_MobjIsPlayer and FixedMulAngle are shared helpers for these paths.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"

              .extern _Dp, mobjinfo, states, _g_player, skyflatnum, _g_sides
              .extern _g_ceilingline, _g_openrange, _g_opentop, _g_openbottom
              .extern P_TryMove, P_SetMobjState, P_Random, S_StartSound
              .extern P_RemoveMobj, P_PathTraverse, P_PointOnLineSide
              .extern P_LineOpening, R_PointToAngle3, P_AproxDistance
              .extern finesine, finecosine, FixedMul, FixedMul3216
              .extern IIGS_MulLo16, I_Error, MA, MB, MR, umul16

#include "info.inc"
#include "actor.inc"
#include "tics.inc"
#if TICSTEP > 1
              .extern ticRun, P_MobjThinker
#endif

MAXMOVE_HI    .equ    30              ; maximum move component: 30 map units
GRAVITY_HI    .equ    1               ; GRAVITY = FRACUNIT

              .section znear, bss
MV_PL:        .space  2               ; 1: the mobj is the player's
MV_XM:        .space  8               ; xmove, ymove
MV_PX:        .space  8               ; ptryx, ptryy
MV_T:         .space  4
MV_FA:        .space  4               ; FixedMulAngle: a

SL_HIT:       .space  2               ; P_SlideMove: hitcount
SL_BEST:      .space  4               ; bestslidefrac
SL_LINE:      .space  4               ; bestslideline
SL_MO:        .space  4               ; slidemo
SL_TMX:       .space  4               ; tmxmove, tmymove
SL_TMY:       .space  4
SL_LEAD:      .space  8               ; leadx, leady
SL_TRAIL:     .space  8               ; trailx, traily
SL_LI:        .space  4               ; PTR_SlideTraverse: the line
SL_FRAC:      .space  4               ; its intercept

HS_LA:        .space  4               ; P_HitSlideLine: lineangle
HS_DA:        .space  4               ; deltaangle
HS_LEN:       .space  4               ; movelen, then newlen

              .section cfar, rodata
SL_ERR:       .asciz  "PTR_SlideTraverse: not a line?"

;;; Routine order separates frequently interleaved cache footprints:
;;; P_XYMovement, P_ZMovement and friction are placed at the end,
;;; away from the slots of P_MobjThinker (src/iigs/p_tick65.s) and of the
;;; helpers of P_TryMove (checkThing, P_CreateSecNodeList,
;;; P_BlockLinesIterator), which run with them; the slide code first.
              .section logiccode, text

;;; ---------------------------------------------------------------------------
;;; slideMove: P_SlideMove(AP). The player hit a wall: find the first line
;;; that the three leading corners hit, move up to it and slide along it.
;;; ---------------------------------------------------------------------------
slideMove:    lda     ##3                   ; hitcount
              sta     .near SL_HIT
              lda     dp:.tiny AP           ; slidemo = mo
              sta     .near SL_MO
              lda     dp:.tiny (AP+2)
              sta     .near (SL_MO+2)
1$:           dec     .near SL_HIT          ; do not loop forever
              bne     2$
              brl     stairstep

              ;; the leading and trailing corners
2$:           ldy     ##OFS_MO_MOMX
              ldx     ##0
              jsr     .kbank corners
              ldy     ##OFS_MO_MOMY
              ldx     ##4
              jsr     .kbank corners
              lda     ##1                   ; bestslidefrac = FRACUNIT + 1
              sta     .near SL_BEST
              sta     .near (SL_BEST+2)
              ldx     ##.near SL_LEAD       ; the three traces
              ldy     ##.near (SL_LEAD+4)
              jsr     .kbank slideTrace
              ldx     ##.near SL_TRAIL
              ldy     ##.near (SL_LEAD+4)
              jsr     .kbank slideTrace
              ldx     ##.near SL_LEAD
              ldy     ##.near (SL_TRAIL+4)
              jsr     .kbank slideTrace

              lda     .near SL_BEST         ; nothing hit: the middle, stairstep
              cmp     ##1
              bne     3$
              lda     .near (SL_BEST+2)
              cmp     ##1
              bne     3$
              brl     stairstep

3$:           lda     .near SL_BEST         ; bestslidefrac -= 0x800
              sec
              sbc     ##0x800
              sta     .near SL_BEST
              lda     .near (SL_BEST+2)
              sbc     ##0
              sta     .near (SL_BEST+2)
              bmi     5$                    ; > 0: move up to the wall
              ora     .near SL_BEST
              beq     5$
              ldy     ##OFS_MO_MOMX         ; P_TryMove(mo, x + FixedMul(momx, frac),
              jsr     .kbank bestMul        ;           y + FixedMul(momy, frac))
              ldy     ##OFS_MO_X
              jsr     .kbank addCoord
              sta     .near MV_PX
              stx     .near (MV_PX+2)
              ldy     ##OFS_MO_MOMY
              jsr     .kbank bestMul
              ldy     ##OFS_MO_Y
              jsr     .kbank addCoord
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              ARGAP
              lda     .near MV_PX
              ldx     .near (MV_PX+2)
              jsl     long:P_TryMove
              and     ##0x00ff
              bne     5$
              brl     stairstep

              ;; the rest of the move: FRACUNIT - (frac + 0x800), at most FRACUNIT
5$:           lda     ##0xf800              ; -(frac + 0x800) + FRACUNIT
              sec
              sbc     .near SL_BEST
              sta     .near SL_BEST
              lda     ##0
              sbc     .near (SL_BEST+2)
              sta     .near (SL_BEST+2)
              bmi     7$
              cmp     ##1                   ; > FRACUNIT: FRACUNIT
              bcc     6$
              bne     51$
              lda     .near SL_BEST
              beq     6$
51$:          stz     .near SL_BEST
              lda     ##1
              sta     .near (SL_BEST+2)
6$:           lda     .near SL_BEST         ; <= 0: done
              ora     .near (SL_BEST+2)
              bne     8$
7$:           rts

8$:           ldy     ##OFS_MO_MOMX         ; tmxmove, tmymove
              jsr     .kbank bestMul
              sta     .near SL_TMX
              stx     .near (SL_TMX+2)
              ldy     ##OFS_MO_MOMY
              jsr     .kbank bestMul
              sta     .near SL_TMY
              stx     .near (SL_TMY+2)
              jsr     .kbank hitSlideLine   ; clip the moves
              ldy     ##OFS_MO_MOMX         ; momx = tmxmove, momy = tmymove
              lda     .near SL_TMX
              sta     [.tiny AP],y
              iny
              iny
              lda     .near (SL_TMX+2)
              sta     [.tiny AP],y
              iny
              iny
              lda     .near SL_TMY
              sta     [.tiny AP],y
              iny
              iny
              lda     .near (SL_TMY+2)
              sta     [.tiny AP],y
              jsr     .kbank isPlayer       ; the bobbing too
              beq     9$
              ldx     ##0
              jsr     .kbank bobClip
              ldx     ##4
              jsr     .kbank bobClip
9$:           ldy     ##OFS_MO_X            ; while (!P_TryMove(mo, x + tmxmove, y + tmymove))
              clc
              lda     [.tiny AP],y
              adc     .near SL_TMX
              sta     .near MV_PX
              iny
              iny
              lda     [.tiny AP],y
              adc     .near (SL_TMX+2)
              sta     .near (MV_PX+2)
              ldy     ##OFS_MO_Y
              clc
              lda     [.tiny AP],y
              adc     .near SL_TMY
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     [.tiny AP],y
              adc     .near (SL_TMY+2)
              sta     dp:.tiny (_Dp+6)
              ARGAP
              lda     .near MV_PX
              ldx     .near (MV_PX+2)
              jsl     long:P_TryMove
              and     ##0x00ff
              bne     10$
              brl     1$
10$:          rts

;;; stairstep: if (!P_TryMove(mo, x, y + momy)) P_TryMove(mo, x + momx, y)
stairstep:    ldy     ##OFS_MO_Y
              clc
              lda     [.tiny AP],y
              ldy     ##OFS_MO_MOMY
              adc     [.tiny AP],y
              sta     dp:.tiny (_Dp+4)
              ldy     ##(OFS_MO_Y+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_MO_MOMY+2)
              adc     [.tiny AP],y
              sta     dp:.tiny (_Dp+6)
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny AP],y
              tax
              ldy     ##OFS_MO_X
              lda     [.tiny AP],y
              pha
              ARGAP
              pla
              jsl     long:P_TryMove
              and     ##0x00ff
              bne     9$
              ldy     ##OFS_MO_Y
              lda     [.tiny AP],y
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     [.tiny AP],y
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_MO_X
              clc
              lda     [.tiny AP],y
              ldy     ##OFS_MO_MOMX
              adc     [.tiny AP],y
              sta     .near MV_PX
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_MO_MOMX+2)
              adc     [.tiny AP],y
              tax
              ARGAP
              lda     .near MV_PX
              jsl     long:P_TryMove
9$:           rts

;;; corners: for the momentum at offset Y of the mobj (Y - 4 = its axis
;;; coordinate + MOMX - X): lead = pos + radius and trail = pos - radius
;;; when the momentum is > 0, else the other way; at SL_LEAD + X and
;;; SL_TRAIL + X.
corners:      iny                           ; momentum > 0: hi > 0, or hi = 0 and lo != 0
              iny
              lda     [.tiny AP],y
              bmi     2$
              bne     1$
              dey
              dey
              lda     [.tiny AP],y
              beq     2$
1$:           lda     ##0                   ; > 0: lead = pos + radius
              bra     3$
2$:           lda     ##0xffff              ; <= 0: lead = pos - radius
3$:           sta     .near MV_T
              txa                           ; the coordinate: X = 0 x, 4 y
              clc
              adc     ##OFS_MO_X
              tay
              lda     [.tiny AP],y
              sta     .near SL_LEAD,x
              sta     .near SL_TRAIL,x
              iny
              iny
              lda     [.tiny AP],y
              sta     .near (SL_LEAD+2),x
              sta     .near (SL_TRAIL+2),x
              ldy     ##OFS_MO_RADIUS
              lda     .near MV_T
              bne     5$
              clc                           ; lead += radius, trail -= radius
              lda     .near SL_LEAD,x
              adc     [.tiny AP],y
              sta     .near SL_LEAD,x
              iny
              iny
              lda     .near (SL_LEAD+2),x
              adc     [.tiny AP],y
              sta     .near (SL_LEAD+2),x
              dey
              dey
              sec
              lda     .near SL_TRAIL,x
              sbc     [.tiny AP],y
              sta     .near SL_TRAIL,x
              iny
              iny
              lda     .near (SL_TRAIL+2),x
              sbc     [.tiny AP],y
              sta     .near (SL_TRAIL+2),x
              rts
5$:           sec                           ; lead -= radius, trail += radius
              lda     .near SL_LEAD,x
              sbc     [.tiny AP],y
              sta     .near SL_LEAD,x
              iny
              iny
              lda     .near (SL_LEAD+2),x
              sbc     [.tiny AP],y
              sta     .near (SL_LEAD+2),x
              dey
              dey
              clc
              lda     .near SL_TRAIL,x
              adc     [.tiny AP],y
              sta     .near SL_TRAIL,x
              iny
              iny
              lda     .near (SL_TRAIL+2),x
              adc     [.tiny AP],y
              sta     .near (SL_TRAIL+2),x
              rts

;;; slideTrace: P_PathTraverse(x, y, x + momx, y + momy, PT_ADDLINES,
;;; PTR_SlideTraverse) with x at near address X, y at near address Y.
slideTrace:   phx
              phy
              pea     #.word2 PTR_SlideTraverse
              pea     #.word0 PTR_SlideTraverse
              pea     #1                    ; PT_ADDLINES
              lda     abs:0,y               ; y2 = y + momy
              clc
              ldy     ##OFS_MO_MOMY
              adc     [.tiny AP],y
              sta     .near MV_T
              lda     7,s                   ; (the y address)
              tax
              lda     abs:2,x
              ldy     ##(OFS_MO_MOMY+2)
              adc     [.tiny AP],y
              pha
              lda     .near MV_T
              pha
              lda     13,s                  ; x2 = x + momx
              tax
              lda     abs:0,x
              clc
              ldy     ##OFS_MO_MOMX
              adc     [.tiny AP],y
              sta     dp:.tiny (_Dp+4)
              lda     abs:2,x
              ldy     ##(OFS_MO_MOMX+2)
              adc     [.tiny AP],y
              sta     dp:.tiny (_Dp+6)
              lda     11,s                  ; y1
              tax
              lda     abs:0,x
              sta     dp:.tiny _Dp
              lda     abs:2,x
              sta     dp:.tiny (_Dp+2)
              lda     13,s                  ; x1
              tax
              lda     abs:2,x
              pha
              lda     abs:0,x
              plx
              jsl     long:P_PathTraverse
              pla                           ; the arguments and the two addresses
              pla
              pla
              pla
              pla
              pla
              pla
              rts

;;; bestMul: X:C = FixedMul(the momentum at offset Y of the mobj,
;;; bestslidefrac).
bestMul:      lda     .near SL_BEST
              sta     dp:.tiny _Dp
              lda     .near (SL_BEST+2)
              sta     dp:.tiny (_Dp+2)
              iny
              iny
              lda     [.tiny AP],y
              tax
              dey
              dey
              lda     [.tiny AP],y
              jsl     long:FixedMul
              rts

;;; addCoord: X:C += the coordinate at offset Y of the mobj.
addCoord:     clc
              adc     [.tiny AP],y
              pha
              txa
              iny
              iny
              adc     [.tiny AP],y
              tax
              pla
              rts

;;; bobClip: if (labs(player->momx) > labs(tmxmove)) player->momx = tmxmove,
;;; for X = 0 (x) or 4 (y).
bobClip:      lda     .near (_g_player+OFS_PL_MOMX),x
              ldy     .near (_g_player+OFS_PL_MOMX+2),x
              jsr     .kbank labs
              sta     .near MV_PX
              sty     .near (MV_PX+2)
              lda     .near SL_TMX,x
              ldy     .near (SL_TMX+2),x
              jsr     .kbank labs
              cmp     .near MV_PX           ; labs(tm) < labs(bob), signed
              tya
              SLT32   .near (MV_PX+2)
              bpl     9$
              lda     .near SL_TMX,x
              sta     .near (_g_player+OFS_PL_MOMX),x
              lda     .near (SL_TMX+2),x
              sta     .near (_g_player+OFS_PL_MOMX+2),x
9$:           rts

;;; labs: Y:C = labs(Y:C). X is kept.
labs:         cpy     ##0
              bpl     9$
              eor     ##0xffff
              clc
              adc     ##1
              pha
              tya
              eor     ##0xffff
              adc     ##0
              tay
              pla
9$:           rts

;;; ---------------------------------------------------------------------------
;;; boolean PTR_SlideTraverse(intercept_t* in)
;;; The callback of P_PathTraverse for the slide: a line that blocks the
;;; move of slidemo and is nearer than the best one becomes the best one.
;;; ---------------------------------------------------------------------------
              .public PTR_SlideTraverse
PTR_SlideTraverse:
              ldy     ##OFS_IC_ISALINE
              lda     [.tiny _Dp],y
              bne     1$
              lda     ##.word0 SL_ERR
              sta     dp:.tiny _Dp
              lda     ##.word2 SL_ERR
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
1$:           ldy     ##OFS_IC_FRAC
              lda     [.tiny _Dp],y
              sta     .near SL_FRAC
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (SL_FRAC+2)
              ldy     ##OFS_IC_D            ; li = in->d.line
              lda     [.tiny _Dp],y
              sta     .near SL_LI
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (SL_LI+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near SL_LI
              sta     dp:.tiny (_Dp+4)
              lda     .near SL_MO           ; slidemo in _Dp[0-3] for the reads
              sta     dp:.tiny _Dp
              lda     .near (SL_MO+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_LINE_FLAGS
              lda     [.tiny (_Dp+4)],y
              and     ##CONST_ML_TWOSIDED
              bne     10$
              ;; one sided: blocks, unless from the back side
              ldy     ##OFS_MO_Y            ; P_PointOnLineSide(slidemo->x, slidemo->y, li)
              lda     [.tiny _Dp],y
              pha
              iny
              iny
              lda     [.tiny _Dp],y
              pha
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_MO_X
              lda     [.tiny _Dp],y
              ply
              sty     dp:.tiny (_Dp+2)
              ply
              sty     dp:.tiny _Dp
              jsl     long:P_PointOnLineSide
              cmp     ##0
              bne     5$
              brl     blocking
5$:           lda     ##1
              rtl

              ;; two sided: blocks if the mobj does not fit in the opening
10$:          lda     dp:.tiny (_Dp+4)      ; P_LineOpening(li)
              sta     dp:.tiny _Dp
              lda     dp:.tiny (_Dp+6)
              sta     dp:.tiny (_Dp+2)
              jsl     long:P_LineOpening
              lda     .near SL_MO
              sta     dp:.tiny _Dp
              lda     .near (SL_MO+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_MO_HEIGHT       ; openrange < height
              lda     .near _g_openrange
              cmp     [.tiny _Dp],y
              lda     .near (_g_openrange+2)
              ldy     ##(OFS_MO_HEIGHT+2)
              SLT32Y  .tiny _Dp
              bmi     blocking
              ldy     ##OFS_MO_Z            ; opentop - z < height
              lda     .near _g_opentop
              sec
              sbc     [.tiny _Dp],y
              sta     .near MV_T
              ldy     ##(OFS_MO_Z+2)
              lda     .near (_g_opentop+2)
              sbc     [.tiny _Dp],y
              sta     .near (MV_T+2)
              lda     .near MV_T
              ldy     ##OFS_MO_HEIGHT
              cmp     [.tiny _Dp],y
              lda     .near (MV_T+2)
              ldy     ##(OFS_MO_HEIGHT+2)
              SLT32Y  .tiny _Dp
              bmi     blocking
              ldy     ##OFS_MO_Z            ; openbottom - z > 24 * FRACUNIT
              lda     .near _g_openbottom
              sec
              sbc     [.tiny _Dp],y
              sta     .near MV_T
              ldy     ##(OFS_MO_Z+2)
              lda     .near (_g_openbottom+2)
              sbc     [.tiny _Dp],y
              sta     .near (MV_T+2)
              lda     ##0                   ; 24 << 16 < openbottom - z
              cmp     .near MV_T
              lda     ##24
              SLT32   .near (MV_T+2)
              bmi     blocking
              lda     ##1                   ; does not block
              rtl

blocking:     lda     .near SL_FRAC         ; the nearest blocking line so far
              cmp     .near SL_BEST
              lda     .near (SL_FRAC+2)
              SLT32   .near (SL_BEST+2)
              bpl     1$
              lda     .near SL_FRAC
              sta     .near SL_BEST
              lda     .near (SL_FRAC+2)
              sta     .near (SL_BEST+2)
              lda     .near SL_LI
              sta     .near SL_LINE
              lda     .near (SL_LI+2)
              sta     .near (SL_LINE+2)
1$:           lda     ##0                   ; stop
              rtl

;;; ---------------------------------------------------------------------------
;;; hitSlideLine: P_HitSlideLine(bestslideline): tmxmove, tmymove along the
;;; line.
;;; ---------------------------------------------------------------------------
hitSlideLine: lda     .near SL_LINE
              sta     dp:.tiny (_Dp+4)
              lda     .near (SL_LINE+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_LINE_DY         ; a horizontal line: no more y move
              lda     [.tiny (_Dp+4)],y
              bne     1$
              stz     .near SL_TMY
              stz     .near (SL_TMY+2)
              rts
1$:           ldy     ##OFS_LINE_DX         ; a vertical line: no more x move
              lda     [.tiny (_Dp+4)],y
              bne     2$
              stz     .near SL_TMX
              stz     .near (SL_TMX+2)
              rts

2$:           ldy     ##OFS_MO_Y            ; side = P_PointOnLineSide(x, y, ld)
              lda     [.tiny AP],y
              sta     dp:.tiny _Dp
              iny
              iny
              lda     [.tiny AP],y
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny AP],y
              tax
              ldy     ##OFS_MO_X
              lda     [.tiny AP],y
              jsl     long:P_PointOnLineSide
              pha
              lda     .near SL_LINE         ; lineangle = R_PointToAngle2(0, 0, dx << 16, dy << 16)
              sta     dp:.tiny (_Dp+4)
              lda     .near (SL_LINE+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_LINE_DY
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny (_Dp+2)
              stz     dp:.tiny _Dp
              ldy     ##OFS_LINE_DX
              lda     [.tiny (_Dp+4)],y
              tax
              lda     ##0
              jsl     long:R_PointToAngle3
              sta     .near HS_LA
              pla                           ; side 1: + ANG180
              cmp     ##1
              bne     3$
              txa
              eor     ##0x8000
              tax
3$:           stx     .near (HS_LA+2)
              lda     .near SL_TMY          ; moveangle = R_PointToAngle2(0, 0, tmxmove, tmymove)
              sta     dp:.tiny _Dp
              lda     .near (SL_TMY+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near SL_TMX
              ldx     .near (SL_TMX+2)
              jsl     long:R_PointToAngle3
              clc                           ; deltaangle = moveangle + 10 - lineangle
              adc     ##10
              bcc     4$
              inx
4$:           sec
              sbc     .near HS_LA
              sta     .near HS_DA
              txa
              sbc     .near (HS_LA+2)
              sta     .near (HS_DA+2)
              lda     .near SL_TMY          ; movelen = P_AproxDistance(tmxmove, tmymove)
              sta     dp:.tiny _Dp
              lda     .near (SL_TMY+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near SL_TMX
              ldx     .near (SL_TMX+2)
              jsl     long:P_AproxDistance
              sta     .near HS_LEN
              stx     .near (HS_LEN+2)
              lda     .near (HS_DA+2)       ; deltaangle > ANG180: + ANG180
              cmp     ##0x8000
              bcc     6$
              bne     5$
              lda     .near HS_DA
              beq     6$
5$:           lda     .near (HS_DA+2)
              eor     ##0x8000
              sta     .near (HS_DA+2)
6$:           lda     .near (HS_DA+2)       ; newlen = FixedMulAngle(movelen,
              lsr     a                     ;   finecosine(deltaangle >> 19))
              lsr     a
              lsr     a
              jsl     long:finecosine
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near HS_LEN
              ldx     .near (HS_LEN+2)
              jsl     long:FixedMulAngle
              sta     .near HS_LEN
              stx     .near (HS_LEN+2)
              lda     .near (HS_LA+2)       ; tmxmove = FixedMulAngle(newlen,
              lsr     a                     ;   finecosine(lineangle >> 19))
              lsr     a
              lsr     a
              jsl     long:finecosine
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near HS_LEN
              ldx     .near (HS_LEN+2)
              jsl     long:FixedMulAngle
              sta     .near SL_TMX
              stx     .near (SL_TMX+2)
              lda     .near (HS_LA+2)       ; tmymove = FixedMulAngle(newlen,
              lsr     a                     ;   finesine(lineangle >> 19))
              lsr     a
              lsr     a
              jsl     long:finesine
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near HS_LEN
              ldx     .near (HS_LEN+2)
              jsl     long:FixedMulAngle
              sta     .near SL_TMY
              stx     .near (SL_TMY+2)
              rts

;;; ---------------------------------------------------------------------------
;;; struct player_s* P_MobjIsPlayer(const mobj_t __far* mobj)
;;; &_g_player if mobj is the mobj of the player, else NULL.
;;; ---------------------------------------------------------------------------
              .public P_MobjIsPlayer
P_MobjIsPlayer:
              lda     .near (_g_player+OFS_PL_MO)
              cmp     dp:.tiny _Dp
              bne     1$
              lda     .near (_g_player+OFS_PL_MO+2)
              cmp     dp:.tiny (_Dp+2)
              bne     1$
              ldx     ##.word2 _g_player
              lda     ##.near _g_player
              rtl
1$:           lda     ##0
              tax
              rtl

;;; ---------------------------------------------------------------------------
;;; void P_ExplodeMissile(mobj_t __far* mo)
;;; ---------------------------------------------------------------------------
              .public P_ExplodeMissile
P_ExplodeMissile:
              ENTER
              jsr     .kbank explode
              lda     ##0
              LEAVE

;;; explode: P_ExplodeMissile(AP).
explode:      lda     ##0                   ; momx = momy = momz = 0
              ldy     ##OFS_MO_MOMX
              ldx     ##6
1$:           sta     [.tiny AP],y
              iny
              iny
              dex
              bne     1$
              MINFO                         ; P_SetMobjState(mo, deathstate)
              ARGAP
              lda     abs:OFS_MI_DEATHSTATE,x
              jsl     long:P_SetMobjState
              jsl     long:P_Random         ; tics -= P_Random() & 3
              and     ##3
              eor     ##0xffff
              sec
              ldy     ##OFS_MO_TICS
              adc     [.tiny AP],y
              bmi     2$                    ; if (tics < 1) tics = 1
              bne     3$
2$:           lda     ##1
3$:           sta     [.tiny AP],y
              ldy     ##(OFS_MO_FLAGS+2)    ; flags &= ~MF_MISSILE
              lda     [.tiny AP],y
              and     ##(0xffff - CONST_MF_MISSILE_HI)
              sta     [.tiny AP],y
              MINFO                         ; the death sound
              lda     abs:OFS_MI_DEATHSOUND,x
              beq     9$
              pha
              ARGAP
              pla
              jsl     long:S_StartSound
9$:           rts

;;; halfMove: MV_PX + X = the coordinate at offset Y of the mobj + the move
;;; at MV_XM + X / 2 (toward 0, as C), then the move >>= 1.
halfMove:     lda     .near MV_XM,x
              sta     .near MV_T
              lda     .near (MV_XM+2),x
              sta     .near (MV_T+2)
              bpl     1$
              inc     .near MV_T            ; a negative move: + 1, then >> 1
              bne     1$
              inc     .near (MV_T+2)
1$:           lda     .near (MV_T+2)
              cmp     ##0x8000
              ror     a
              sta     .near (MV_T+2)
              ror     .near MV_T
              clc
              lda     [.tiny AP],y
              adc     .near MV_T
              sta     .near MV_PX,x
              iny
              iny
              lda     [.tiny AP],y
              adc     .near (MV_T+2)
              sta     .near (MV_PX+2),x
              lda     .near (MV_XM+2),x     ; move >>= 1
              cmp     ##0x8000
              ror     a
              sta     .near (MV_XM+2),x
              ror     .near MV_XM,x
              rts

;;; skyHit: carry set if a missile that _g_ceilingline stopped went into
;;; the sky: the back sector of the line has the sky as its ceiling and the
;;; missile is above that ceiling.
skyHit:       lda     .near _g_ceilingline
              ora     .near (_g_ceilingline+2)
              beq     8$
              lda     .near _g_ceilingline
              sta     dp:.tiny _Dp
              lda     .near (_g_ceilingline+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_LINE_SIDENUM+2) ; LN_BACKSECTOR
              lda     [.tiny _Dp],y
              cmp     ##0xffff
              beq     8$
              ldx     ##SIZEOF_SIDE
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sides
              sta     dp:.tiny _Dp
              lda     .near (_g_sides+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_SIDE_SECTOR+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SIDE_SECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ora     dp:.tiny (_Dp+2)
              beq     8$
              ldy     ##OFS_SEC_CEILINGPIC
              lda     [.tiny _Dp],y
              cmp     .near skyflatnum
              bne     8$
              ldy     ##OFS_SEC_CEILINGHEIGHT ; ceilingheight < z
              lda     [.tiny _Dp],y
              ldy     ##OFS_MO_Z
              cmp     [.tiny AP],y
              ldy     ##(OFS_SEC_CEILINGHEIGHT+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_Z+2)
              SLT32Y  .tiny AP
              bpl     8$
              sec
              rts
8$:           clc
              rts

;;; quarterOut: carry set if the momentum at offset Y of the mobj is more
;;; than FRACUNIT / 4 or less than -FRACUNIT / 4.
quarterOut:   iny
              iny
              lda     [.tiny AP],y
              beq     2$
              bmi     5$
1$:           sec                           ; hi > 0
              rts
2$:           dey                           ; hi = 0: lo > 0x4000
              dey
              lda     [.tiny AP],y
              cmp     ##0x4001
              rts
5$:           cmp     ##0xffff              ; hi < -1
              bne     1$
              dey                           ; hi = -1: lo < 0xc000
              dey
              lda     [.tiny AP],y
              cmp     ##0xc000
              bcc     1$
              clc
              rts

;;; missileHit: a missile (not MF_NOCLIP) explodes; carry set if it did.
missileHit:   ldy     ##(OFS_MO_FLAGS+2)
              lda     [.tiny AP],y
              and     ##CONST_MF_MISSILE_HI
              beq     8$
              ldy     ##OFS_MO_FLAGS
              lda     [.tiny AP],y
              and     ##CONST_MF_NOCLIP_LO
              bne     8$
              jsr     .kbank explode
              sec
              rts
8$:           clc
              rts

;;; shr3: C:X = (C:X) >> 3, arithmetic: C holds the high word, X the low word.
shr3:         stx     .near MV_T
              ldx     ##3
1$:           cmp     ##0x8000
              ror     a
              ror     .near MV_T
              dex
              bne     1$
              ldx     .near MV_T
              rts

;;; ---------------------------------------------------------------------------
;;; void P_ZMovement(mobj_t __far* mo)
;;; With TICSTEP > 1: the height move of each tic of the call (zTic,
;;; ticRun times), while the mobj is above its floor or has a height
;;; momentum.
;;; ---------------------------------------------------------------------------
              .public P_ZMovement
#if TICSTEP > 1
P_ZMovement:  pei     dp:.tiny (_Dp+2)      ; the mobj at 3,s
              pei     dp:.tiny _Dp
              lda     .near ticRun          ; the moves left at 1,s
              pha
1$:           jsl     long:zTic
              lda     1,s
              dec     a
              beq     9$
              sta     1,s
              lda     3,s                   ; _Dp = the mobj
              sta     dp:.tiny _Dp
              lda     5,s
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_MO_MOMZ         ; z != floorz or momz: again
              lda     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              bne     1$
              ldy     ##OFS_MO_Z
              lda     [.tiny _Dp],y
              ldy     ##OFS_MO_FLOORZ
              cmp     [.tiny _Dp],y
              bne     1$
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_FLOORZ+2)
              cmp     [.tiny _Dp],y
              bne     1$
9$:           pla
              pla
              pla
              rtl

zTic:         ENTER
#else
P_ZMovement:  ENTER
#endif
              jsr     .kbank isPlayer
              sta     .near MV_PL
              beq     2$
              ;; smooth step up: z < floorz
              ldy     ##OFS_MO_Z
              lda     [.tiny AP],y
              ldy     ##OFS_MO_FLOORZ
              cmp     [.tiny AP],y
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_MO_FLOORZ+2)
              SLT32Y  .tiny AP
              bpl     2$
              ldy     ##OFS_MO_FLOORZ       ; viewheight -= floorz - z
              lda     [.tiny AP],y
              ldy     ##OFS_MO_Z
              sec
              sbc     [.tiny AP],y
              sta     .near MV_T
              ldy     ##(OFS_MO_FLOORZ+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_MO_Z+2)
              sbc     [.tiny AP],y
              sta     .near (MV_T+2)
              lda     .near (_g_player+OFS_PL_VIEWHEIGHT)
              sec
              sbc     .near MV_T
              sta     .near (_g_player+OFS_PL_VIEWHEIGHT)
              lda     .near (_g_player+OFS_PL_VIEWHEIGHT+2)
              sbc     .near (MV_T+2)
              sta     .near (_g_player+OFS_PL_VIEWHEIGHT+2)
              lda     ##CONST_VIEWHEIGHT_LO ; deltaviewheight = (VIEWHEIGHT - viewheight) >> 3
              sec
              sbc     .near (_g_player+OFS_PL_VIEWHEIGHT)
              tax
              lda     ##CONST_VIEWHEIGHT_HI
              sbc     .near (_g_player+OFS_PL_VIEWHEIGHT+2)
              jsr     .kbank shr3
              sta     .near (_g_player+OFS_PL_DELTAVIEWHEIGHT+2)
              stx     .near (_g_player+OFS_PL_DELTAVIEWHEIGHT)

2$:           ldy     ##OFS_MO_Z            ; z += momz
              lda     [.tiny AP],y
              clc
              ldy     ##OFS_MO_MOMZ
              adc     [.tiny AP],y
              ldy     ##OFS_MO_Z
              sta     [.tiny AP],y
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_MO_MOMZ+2)
              adc     [.tiny AP],y
              ldy     ##(OFS_MO_Z+2)
              sta     [.tiny AP],y

              ;; on or below the floor: !(floorz < z)
              ldy     ##OFS_MO_FLOORZ
              lda     [.tiny AP],y
              ldy     ##OFS_MO_Z
              cmp     [.tiny AP],y
              ldy     ##(OFS_MO_FLOORZ+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_MO_Z+2)
              SLT32Y  .tiny AP
              bpl     10$
              brl     30$
10$:          ldy     ##(OFS_MO_MOMZ+2)     ; hit the floor with momz < 0
              lda     [.tiny AP],y
              bpl     15$
              ldx     .near MV_PL           ; the player lands hard: momz < -GRAVITY * 8
              beq     14$
              cmp     ##(0x10000 - 8 * GRAVITY_HI)
              bcs     14$
              tax                           ; deltaviewheight = momz >> 3
              ldy     ##OFS_MO_MOMZ
              lda     [.tiny AP],y
              pha
              txa
              plx
              jsr     .kbank shr3
              sta     .near (_g_player+OFS_PL_DELTAVIEWHEIGHT+2)
              stx     .near (_g_player+OFS_PL_DELTAVIEWHEIGHT)
              ldy     ##OFS_MO_HEALTH       ; "oof" unless dead
              lda     [.tiny AP],y
              beq     14$
              bmi     14$
              ARGAP
              lda     ##CONST_SFX_OOF
              jsl     long:S_StartSound
14$:          lda     ##0                   ; momz = 0
              ldy     ##OFS_MO_MOMZ
              sta     [.tiny AP],y
              iny
              iny
              sta     [.tiny AP],y
15$:          ldy     ##OFS_MO_FLOORZ       ; z = floorz
              lda     [.tiny AP],y
              ldy     ##OFS_MO_Z
              sta     [.tiny AP],y
              ldy     ##(OFS_MO_FLOORZ+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_MO_Z+2)
              sta     [.tiny AP],y
              jsr     .kbank missileHit
              bcc     40$
              brl     zdone

30$:          ldy     ##OFS_MO_FLAGS        ; in the air: gravity
              lda     [.tiny AP],y
              and     ##CONST_MF_NOGRAVITY_LO
              bne     40$
              ldy     ##OFS_MO_MOMZ         ; if (!momz) momz = -GRAVITY; momz -= GRAVITY
              lda     [.tiny AP],y
              iny
              iny
              ora     [.tiny AP],y
              bne     31$
              lda     ##(0x10000 - GRAVITY_HI)
              sta     [.tiny AP],y
31$:          ldy     ##(OFS_MO_MOMZ+2)
              lda     [.tiny AP],y
              sec
              sbc     ##GRAVITY_HI
              sta     [.tiny AP],y

              ;; hit the ceiling: ceilingz < z + height
40$:          ldy     ##OFS_MO_Z
              lda     [.tiny AP],y
              clc
              ldy     ##OFS_MO_HEIGHT
              adc     [.tiny AP],y
              sta     .near MV_T
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_MO_HEIGHT+2)
              adc     [.tiny AP],y
              sta     .near (MV_T+2)
              ldy     ##OFS_MO_CEILINGZ
              lda     [.tiny AP],y
              cmp     .near MV_T
              ldy     ##(OFS_MO_CEILINGZ+2)
              lda     [.tiny AP],y
              SLT32   .near (MV_T+2)
              bpl     zdone
              ldy     ##(OFS_MO_MOMZ+2)     ; if (momz > 0) momz = 0
              lda     [.tiny AP],y
              bmi     42$
              bne     41$
              dey
              dey
              lda     [.tiny AP],y
              beq     42$
41$:          lda     ##0
              ldy     ##OFS_MO_MOMZ
              sta     [.tiny AP],y
              iny
              iny
              sta     [.tiny AP],y
42$:          ldy     ##OFS_MO_CEILINGZ     ; z = ceilingz - height
              lda     [.tiny AP],y
              sec
              ldy     ##OFS_MO_HEIGHT
              sbc     [.tiny AP],y
              ldy     ##OFS_MO_Z
              sta     [.tiny AP],y
              ldy     ##(OFS_MO_CEILINGZ+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_MO_HEIGHT+2)
              sbc     [.tiny AP],y
              ldy     ##(OFS_MO_Z+2)
              sta     [.tiny AP],y
              jsr     .kbank missileHit
zdone:        lda     ##0
              LEAVE

;;; slow: carry set if the momentum at offset Y of the mobj is more than
;;; -STOPSPEED and less than STOPSPEED.
slow:         iny
              iny
              lda     [.tiny AP],y
              beq     2$
              cmp     ##0xffff
              bne     8$
              dey                           ; hi = -1: lo > 0xf000
              dey
              lda     [.tiny AP],y
              cmp     ##0xf001
              rts
2$:           dey                           ; hi = 0: lo < 0x1000
              dey
              lda     [.tiny AP],y
              cmp     ##0x1000
              bcs     8$
              sec
              rts
8$:           clc
              rts

;;; frictionAP: the momentum at offset Y of the mobj = friction(it).
frictionAP:   phy
              iny
              iny
              lda     [.tiny AP],y
              tax
              dey
              dey
              lda     [.tiny AP],y
              jsr     .kbank friction
              ply
              sta     [.tiny AP],y
              iny
              iny
              txa
              sta     [.tiny AP],y
              rts

;;; frictionNear: the 32-bit value at near address X = friction(it).
frictionNear: phx
              lda     abs:2,x
              pha
              lda     abs:0,x
              plx
              jsr     .kbank friction
              ply
              sta     abs:0,y
              txa
              sta     abs:2,y
              rts

;;; friction: X:C = FixedMul32OrigFriction(X:C)
;;;   = ((lo * ORIG_FRICTION) >> 16) + (int16_t)hi * ORIG_FRICTION
friction:     sta     dp:.tiny MA
              lda     ##CONST_ORIG_FRICTION
              sta     dp:.tiny MB
              stx     .near MV_T
              jsl     long:umul16
              lda     dp:.tiny (MR+2)
              sta     .near (MV_T+2)
              lda     .near MV_T
              sta     dp:.tiny MA
              jsl     long:umul16
              lda     .near MV_T            ; hi < 0: - ORIG_FRICTION << 16
              bpl     1$
              lda     dp:.tiny (MR+2)
              sec
              sbc     ##CONST_ORIG_FRICTION
              sta     dp:.tiny (MR+2)
1$:           lda     dp:.tiny MR
              clc
              adc     .near (MV_T+2)
              pha
              lda     dp:.tiny (MR+2)
              adc     ##0
              tax
              pla
              rts

;;; ---------------------------------------------------------------------------
;;; fixed_t FixedMulAngle(fixed_t a, fixed_t b)    In: X:C = a, _Dp[0-3] = b.
;;; FixedMul3216(a, b & 0xffff), minus a when b < 0.
;;; ---------------------------------------------------------------------------
              .public FixedMulAngle
FixedMulAngle:
              ldy     dp:.tiny (_Dp+2)
              bmi     1$
              jmp     long:FixedMul3216
1$:           sta     .near MV_FA
              stx     .near (MV_FA+2)
              jsl     long:FixedMul3216
              sec
              sbc     .near MV_FA
              pha
              txa
              sbc     .near (MV_FA+2)
              tax
              pla
              rtl

;;; isPlayer: C = 1 if AP is the mobj of the player, else 0.
isPlayer:     lda     dp:.tiny AP
              cmp     .near (_g_player+OFS_PL_MO)
              bne     1$
              lda     dp:.tiny (AP+2)
              cmp     .near (_g_player+OFS_PL_MO+2)
              bne     1$
              lda     ##1
              rts
1$:           lda     ##0
              rts

;;; ---------------------------------------------------------------------------
;;; void P_XYMovement(mobj_t __far* mo)
;;; With TICSTEP > 1: the move of each tic of the call (xyTic, ticRun
;;; times: 1 for the mobj of the player, the tics of a world run), while
;;; the mobj is not removed.
;;; ---------------------------------------------------------------------------
              .public P_XYMovement
#if TICSTEP > 1
P_XYMovement: pei     dp:.tiny (_Dp+2)      ; the mobj at 3,s
              pei     dp:.tiny _Dp
              lda     .near ticRun          ; the moves left at 1,s
              pha
1$:           jsl     long:xyTic
              lda     1,s
              dec     a
              beq     9$
              sta     1,s
              lda     3,s                   ; _Dp = the mobj
              sta     dp:.tiny _Dp
              lda     5,s
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_TH_FUNCTION     ; removed: done
              lda     [.tiny _Dp],y
              cmp     ##.word0 P_MobjThinker
              beq     1$
9$:           pla
              pla
              pla
              rtl

xyTic:        ldy     ##OFS_MO_MOMX         ; no momentum: nothing to do
#else
P_XYMovement: ldy     ##OFS_MO_MOMX         ; no momentum: nothing to do
#endif
              lda     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              bne     1$
              rtl
1$:           ENTER
              jsr     .kbank isPlayer
              sta     .near MV_PL
              ldy     ##OFS_MO_MOMX         ; momx, momy in -MAXMOVE..MAXMOVE
              jsr     .kbank clampMove
              ldy     ##OFS_MO_MOMY
              jsr     .kbank clampMove
              ldy     ##OFS_MO_MOMX         ; xmove = momx, ymove = momy
              ldx     ##0
2$:           lda     [.tiny AP],y
              sta     .near MV_XM,x
              iny
              iny
              inx
              inx
              cpx     ##8
              bne     2$

              ;; the move, in two halves while it is more than MAXMOVE / 2
loop:         ldx     ##0
              jsr     .kbank isBig
              bcs     10$
              ldx     ##4
              jsr     .kbank isBig
              bcs     10$
              ldx     ##0                   ; ptry = pos + move, move = 0
              ldy     ##OFS_MO_X
              jsr     .kbank wholeMove
              ldx     ##4
              ldy     ##OFS_MO_Y
              jsr     .kbank wholeMove
              bra     20$
10$:          ldx     ##0                   ; ptry = pos + move / 2, move >>= 1
              ldy     ##OFS_MO_X
              jsr     .kbank halfMove
              ldx     ##4
              ldy     ##OFS_MO_Y
              jsr     .kbank halfMove

20$:          lda     .near (MV_PX+4)       ; P_TryMove(mo, ptryx, ptryy)
              sta     dp:.tiny (_Dp+4)
              lda     .near (MV_PX+6)
              sta     dp:.tiny (_Dp+6)
              ARGAP
              lda     .near MV_PX
              ldx     .near (MV_PX+2)
              jsl     long:P_TryMove
              and     ##0x00ff
              bne     40$
              lda     .near MV_PL           ; blocked: the player slides
              beq     30$
              jsr     .kbank slideMove
              bra     40$
30$:          ldy     ##(OFS_MO_FLAGS+2)    ; a missile explodes
              lda     [.tiny AP],y
              and     ##CONST_MF_MISSILE_HI
              beq     35$
              jsr     .kbank skyHit         ; unless it goes into the sky
              bcc     33$
              ARGAP
              jsl     long:P_RemoveMobj
              brl     done
33$:          jsr     .kbank explode
              bra     40$
35$:          lda     ##0                   ; anything else stops
              ldy     ##OFS_MO_MOMX
              ldx     ##4
36$:          sta     [.tiny AP],y
              iny
              iny
              dex
              bne     36$
40$:          lda     .near MV_XM           ; while (xmove || ymove)
              ora     .near (MV_XM+2)
              ora     .near (MV_XM+4)
              ora     .near (MV_XM+6)
              beq     50$
              brl     loop

              ;; friction: not for missiles, and not in the air
50$:          ldy     ##(OFS_MO_FLAGS+2)
              lda     [.tiny AP],y
              and     ##CONST_MF_MISSILE_HI
              beq     51$
              brl     done
51$:          ldy     ##OFS_MO_FLOORZ       ; z > floorz: floorz - z < 0
              lda     [.tiny AP],y
              ldy     ##OFS_MO_Z
              cmp     [.tiny AP],y
              ldy     ##(OFS_MO_FLOORZ+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_MO_Z+2)
              SLT32Y  .tiny AP
              bpl     52$
              brl     done
              ;; a corpse that slides off a step with some momentum goes on
52$:          ldy     ##(OFS_MO_FLAGS+2)
              lda     [.tiny AP],y
              and     ##CONST_MF_CORPSE_HI
              beq     60$
              ldy     ##OFS_MO_MOMX
              jsr     .kbank quarterOut
              bcs     53$
              ldy     ##OFS_MO_MOMY
              jsr     .kbank quarterOut
              bcc     60$
53$:          ldy     ##OFS_MO_SUBSECTOR    ; floorz != sector floorheight
              lda     [.tiny AP],y
              sta     dp:.tiny _Dp
              iny
              iny
              lda     [.tiny AP],y
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_SUB_SECTOR+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SUB_SECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##OFS_MO_FLOORZ
              lda     [.tiny AP],y
              ldy     ##OFS_SEC_FLOORHEIGHT
              cmp     [.tiny _Dp],y
              bne     54$
              ldy     ##(OFS_MO_FLOORZ+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_SEC_FLOORHEIGHT+2)
              cmp     [.tiny _Dp],y
              beq     60$
54$:          brl     done

              ;; momentum below STOPSPEED and no player move: stop
60$:          ldy     ##OFS_MO_MOMX
              jsr     .kbank slow
              bcc     70$
              ldy     ##OFS_MO_MOMY
              jsr     .kbank slow
              bcc     70$
              lda     .near MV_PL
              beq     62$
              lda     .near (_g_player+OFS_PL_CMD+OFS_TC_FORWARDMOVE) ; forwardmove | sidemove
              bne     70$
              ldy     ##OFS_MO_STATE        ; in a walking frame: S_PLAY
              lda     [.tiny AP],y
              sec
              sbc     ##.near (states + CONST_S_PLAY_RUN1 * STATE_SIZE)
              cmp     ##(4 * STATE_SIZE)
              bcs     61$
              ARGAP
              lda     ##CONST_S_PLAY
              jsl     long:P_SetMobjState
61$:          stz     .near (_g_player+OFS_PL_MOMX)
              stz     .near (_g_player+OFS_PL_MOMX+2)
              stz     .near (_g_player+OFS_PL_MOMY)
              stz     .near (_g_player+OFS_PL_MOMY+2)
62$:          lda     ##0
              ldy     ##OFS_MO_MOMX
              ldx     ##4
63$:          sta     [.tiny AP],y
              iny
              iny
              dex
              bne     63$
              bra     done

              ;; else friction
70$:          ldy     ##OFS_MO_MOMX
              jsr     .kbank frictionAP
              ldy     ##OFS_MO_MOMY
              jsr     .kbank frictionAP
              lda     .near MV_PL
              beq     done
              ldx     ##.near (_g_player+OFS_PL_MOMX)
              jsr     .kbank frictionNear
              ldx     ##.near (_g_player+OFS_PL_MOMY)
              jsr     .kbank frictionNear
done:         lda     ##0
              LEAVE

;;; clampMove: the momentum at offset Y of the mobj to -MAXMOVE..MAXMOVE.
clampMove:    iny
              iny
              lda     [.tiny AP],y          ; high word
              bmi     5$
              cmp     ##MAXMOVE_HI    ; > MAXMOVE: hi > 30, or hi = 30 and lo != 0
              bcc     9$
              bne     2$
              dey
              dey
              lda     [.tiny AP],y
              beq     9$
              iny
              iny
2$:           lda     ##MAXMOVE_HI
              sta     [.tiny AP],y
              dey
              dey
              lda     ##0
              sta     [.tiny AP],y
9$:           rts
5$:           cmp     ##(0x10000 - MAXMOVE_HI) ; < -MAXMOVE: hi < -30
              bcs     9$
              lda     ##(0x10000 - MAXMOVE_HI)
              sta     [.tiny AP],y
              dey
              dey
              lda     ##0
              sta     [.tiny AP],y
              rts

;;; isBig: carry set if the move at MV_XM + X is more than MAXMOVE / 2
;;; or less than -MAXMOVE / 2.
isBig:        lda     .near (MV_XM+2),x
              bmi     5$
              cmp     ##(MAXMOVE_HI / 2) ; hi > 15, or hi = 15 and lo != 0
              bcc     8$
              bne     9$
              lda     .near MV_XM,x
              bne     9$
8$:           clc
              rts
9$:           sec
              rts
5$:           cmp     ##(0x10000 - MAXMOVE_HI / 2) ; hi < -15
              bcc     9$
              clc
              rts

;;; wholeMove: MV_PX + X = the coordinate at offset Y of the mobj + the move
;;; at MV_XM + X, then the move = 0.
wholeMove:    clc
              lda     [.tiny AP],y
              adc     .near MV_XM,x
              sta     .near MV_PX,x
              iny
              iny
              lda     [.tiny AP],y
              adc     .near (MV_XM+2),x
              sta     .near (MV_PX+2),x
              stz     .near MV_XM,x
              stz     .near (MV_XM+2),x
              rts
