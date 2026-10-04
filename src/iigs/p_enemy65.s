;;; Monster decisions and action functions.
;;;
;;; The actor argument is a four-byte far pointer in _Dp[0-3]. Public action
;;; routines save the caller's AP (_Dp+8) on the stack, put their actor there,
;;; and restore AP on return. Local helpers read AP instead of taking another
;;; actor argument; preserve it across calls that can trigger another action.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "tics.inc"

              .extern _Dp, mobjinfo, _g_player, _g_gameskill, _g_gamemap
              .extern _g_numspechit, _g_spechit, _g_tmbbox, _g_bmaporgx, _g_bmaporgy
              .extern _g_thinkerclasscap, validcount, _g_sides
              .extern P_TryMove, P_UseSpecialLine, P_Random, P_CheckSight
              .extern R_PointToAngle3, P_AproxDistance, S_StartSound
              .extern P_SetMobjState, P_AimLineAttack, P_LineAttack
              .extern P_DamageMobj, P_SpawnMissile, P_RadiusAttack, EV_DoFloor
              .extern P_BlockLinesIterator, P_BoxOnLineSide, P_MobjThinker
              .extern finesineTable, finecosineTable, finesine, finecosine
              .extern _Mul32, _Mod16, IIGS_MulLo16
#if TICSTEP > 1
              .extern chaseX
#endif

#include "info.inc"
#include "actor.inc"

;;; CLEAN: the byte 11 of a mobj (the high byte of its thinker function,
;;; 0 in a pointer) is 1 once P_RunThinkers found the mobj with no momentum
;;; on its floor; a change of its momentum, z or floorz clears it.
CLEARCLEAN    .macro  p
              sep     #0x20
              lda     #0
              ldy     ##(OFS_TH_FUNCTION+3)
              sta     [.tiny \p],y
              rep     #0x20
              .endm


AT            .equ    _Dp+12          ; a second pointer (target)

;;; _Dp[4-7] = actor->target, the second argument.
ARGTARGET2    .macro
              ldy     ##OFS_MO_TARGET
              lda     [.tiny AP],y
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     [.tiny AP],y
              sta     dp:.tiny (_Dp+6)
              .endm

              .section znear, bss
PM_TRY:       .space  8               ; P_Move: tryx, tryy
PM_GOOD:      .space  2
EN_T:         .space  4
EN_D:         .space  8               ; deltax, deltay
EN_DIR:       .space  8               ; P_DoNewChaseDir: xdir, ydir, olddir, turnaround
EN_TDIR:      .space  2               ; its search direction
EN_FLOORZ:    .space  4               ; P_AvoidDropoff
EN_DDX:       .space  4               ; dropoff_deltax, dropoff_deltay
EN_DDY:       .space  4
EN_B:         .space  8               ; the block range
EN_BX:        .space  2
EN_BY:        .space  2
EN_LINE:      .space  4               ; PIT_AvoidDropoff: the line

AC_SLOPE:     .space  4
AC_ANGLE:     .space  4
AC_BASE:      .space  4               ; A_SPosAttack: bangle
AC_I:         .space  2
AC_JUNK:      .space  SIZEOF_LINE     ; A_BossDeath: a line with tag 666
#if TICSTEP > 1
CH_K:         .space  2               ; A_Chase: k, the chase states that
                                      ;   this call does (a byte; the high
                                      ;   byte stays 0)
PM_STEPS:     .space  2               ; pMove: the steps to move (a byte)
PM_C:         .space  2               ;   the steps of this chunk (a byte)
PM_R:         .space  2               ;   1: a blocked chunk of 2 steps
                                      ;   tries 1 step (a byte)
PM_N:         .space  2               ; tryWalk: the steps of the walk (a byte)
#endif

              .section logiccode, text
;;; ---------------------------------------------------------------------------
;;; pMove: P_Move(AP), C = true if the actor moved. Walking speeds are below
;;; 65536, so speed * xspeed is speed * 47000, speed << 16 or 0 (and minus).
;;; With TICSTEP > 1: PM_STEPS steps (1 or more), in chunks (PM_C) of 2
;;; steps at most: 2 * speed is below the radius of each monster, so the
;;; checks of a chunk see each line that it crosses. With PM_R = 1 (the
;;; move of A_Chase), a blocked chunk of 2 steps without special lines
;;; tries 1 step; after that step the move is blocked, as the next P_Move
;;; of Doom would be. A blocked move gives false (or the result of the
;;; special lines: an opened line takes a step). Out: PM_STEPS = the steps
;;; that did not move.
;;; ---------------------------------------------------------------------------
pMove:        ldy     ##OFS_MO_MOVEDIR
              lda     [.tiny AP],y
              and     ##0x00ff
              cmp     ##CONST_DI_NODIR
              bne     1$
              lda     ##0
              rts
1$:
#if TICSTEP > 1
              tax                           ; the chunk: 2 steps at most
              sep     #0x20
              lda     .near PM_STEPS
              cmp     #2
              bcc     4$
              lda     #2
4$:           sta     .near PM_C
              rep     #0x20
              txa
pMoveC:                                     ; (C = movedir)
#endif
              pha
              MINFO
              lda     abs:(OFS_MI_SPEED+2),x
              beq     2$
              pla                           ; (never for a walking monster)
              brl     pMoveMul32
2$:           lda     abs:OFS_MI_SPEED,x
#if TICSTEP > 1
              ldy     .near PM_C            ; a chunk of 2 steps: 2 * speed
              cpy     ##2
              bcc     3$
              asl     a
3$:
#endif
              sta     .near EN_T            ; speed
              pla
              asl     a
              tax
              lda     long:(speedTab+0),x   ; xspeed class of the direction
              ldy     ##OFS_MO_X
              jsl     long:speedStep
              ldy     ##OFS_MO_MOVEDIR
              lda     [.tiny AP],y
              and     ##0x00ff
              asl     a
              tax
              lda     long:(speedTab+16),x  ; yspeed class
              ldy     ##OFS_MO_Y
              jsl     long:speedStep
pMoveTry:     lda     .near (PM_TRY+4)      ; P_TryMove(actor, tryx, tryy)
              sta     dp:.tiny (_Dp+4)
              lda     .near (PM_TRY+6)
              sta     dp:.tiny (_Dp+6)
              ARGAP
              lda     .near PM_TRY
              ldx     .near (PM_TRY+2)
              jsl     long:P_TryMove
              and     ##0x00ff
              bne     20$
              lda     .near _g_numspechit   ; blocked: open any specials
              bne     10$
#if TICSTEP > 1
              lda     .near PM_R            ; a chunk of 2 steps: 1 step
              beq     9$
              lda     .near PM_C
              cmp     ##2
              bne     9$
              sep     #0x20
              lda     #1
              sta     .near PM_C
              rep     #0x20
              ldy     ##OFS_MO_MOVEDIR
              lda     [.tiny AP],y
              and     ##0x00ff
              brl     pMoveC
9$:           lda     ##0
#endif
              rts
10$:          sep     #0x20                 ; actor->movedir = DI_NODIR
              lda     #CONST_DI_NODIR
              ldy     ##OFS_MO_MOVEDIR
              sta     [.tiny AP],y
              rep     #0x20
              stz     .near PM_GOOD
11$:          lda     .near _g_numspechit   ; for ( ; _g_numspechit--; )
              dec     .near _g_numspechit
              tax
              bne     12$
              lda     .near PM_GOOD
#if TICSTEP > 1
              beq     13$
              sep     #0x20                 ; a special line opened: it takes
              dec     .near PM_STEPS        ;   the step of this call
              rep     #0x20
13$:
#endif
              rts
12$:          lda     .near _g_numspechit   ; P_UseSpecialLine(actor, spechit[n])
              asl     a
              asl     a
              tax
              lda     abs:.near _g_spechit,x
              sta     dp:.tiny (_Dp+4)
              lda     abs:.near (_g_spechit+2),x
              sta     dp:.tiny (_Dp+6)
              ARGAP
              jsl     long:P_UseSpecialLine
              and     ##0x00ff
              beq     11$
              lda     ##1
              sta     .near PM_GOOD
              bra     11$
20$:          CLEARCLEAN AP
              ldy     ##OFS_MO_FLOORZ       ; actor->z = actor->floorz
              lda     [.tiny AP],y
              ldy     ##OFS_MO_Z
              sta     [.tiny AP],y
              ldy     ##(OFS_MO_FLOORZ+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_MO_Z+2)
              sta     [.tiny AP],y
#if TICSTEP > 1
              lda     .near PM_STEPS        ; the steps left after the chunk
              sec
              sbc     .near PM_C
              sep     #0x20
              sta     .near PM_STEPS
              rep     #0x20
              beq     21$                   ; none: moved
              lda     .near PM_C            ; a chunk of 2 steps: the next
              cmp     ##2                   ;   chunk from the new place
              bne     22$
              brl     pMove
22$:          lda     ##0                   ; the step of a blocked chunk:
              rts                           ;   blocked after it
21$:
#endif
              lda     ##1
              rts

;;; pMoveMul32: compute tryx and tryy with full 32-bit products when
;;; speed does not fit in the low word.
pMoveMul32:   ldy     ##OFS_MO_MOVEDIR
              lda     [.tiny AP],y
              and     ##0x00ff
              asl     a
              asl     a
              sta     .near EN_T
              ldy     ##OFS_MO_X
              ldx     ##0
              jsr     .kbank mulSpeed
              sta     .near PM_TRY
              stx     .near (PM_TRY+2)
              ldy     ##OFS_MO_Y
              ldx     ##32
              jsr     .kbank mulSpeed
              sta     .near (PM_TRY+4)
              stx     .near (PM_TRY+6)
              brl     pMoveTry

;;; mulSpeed: X:C = actor coordinate Y + speed * speeds[X / 4 + dir], the
;;; tables xspeeds (X = 0) and yspeeds (X = 32), EN_T = dir * 4. With
;;; TICSTEP > 1, twice that for a chunk of 2 steps (PM_C).
mulSpeed:     phy
              txa
              clc
              adc     .near EN_T
              tax
              lda     long:speeds,x
              sta     dp:.tiny (_Dp+4)
              lda     long:(speeds+2),x
              sta     dp:.tiny (_Dp+6)
#if TICSTEP > 1
              lda     .near PM_C            ; 2 steps: 2 * speeds[]
              cmp     ##2
              bcc     1$
              asl     dp:.tiny (_Dp+4)
              rol     dp:.tiny (_Dp+6)
1$:
#endif
              MINFO
              lda     abs:OFS_MI_SPEED,x
              sta     dp:.tiny _Dp
              lda     abs:(OFS_MI_SPEED+2),x
              sta     dp:.tiny (_Dp+2)
              jsl     long:_Mul32
              ply
              clc
              adc     [.tiny AP],y
              pha
              txa
              iny
              iny
              adc     [.tiny AP],y
              tax
              pla
              rts

;;; umul16x: X:C = C * X, unsigned 16 x 16.
              .extern MA, MB, MR, umul16
umul16x:      sta     dp:.tiny MA
              stx     dp:.tiny MB
              jsl     long:umul16
              lda     dp:.tiny MR
              ldx     dp:.tiny (MR+2)
              rtl

;;; the speed class of each direction: x then y
speedTab:     .word   2, 1, 0, 3, 4, 3, 0, 1
              .word   0, 1, 2, 1, 0, 3, 4, 3
speeds:       .long   0x10000, 47000, 0, -47000, -0x10000, -47000, 0, 47000
              .long   0, 47000, 0x10000, 47000, 0, -47000, -0x10000, -47000
#if TICSTEP > 1
;;; the byte 3 of the angle of each direction (movedir << 29)
dirByte:      .byte   0x00, 0x20, 0x40, 0x60, 0x80, 0xa0, 0xc0, 0xe0
#endif

;;; ---------------------------------------------------------------------------
;;; boolean P_TryWalk(mobj_t __far* actor)
;;; ---------------------------------------------------------------------------
              .public P_TryWalk
P_TryWalk:    ENTER
#if TICSTEP > 1
              jsr     .kbank oneStep
#endif
              jsr     .kbank tryWalk
              LEAVE

;;; tryWalk: P_TryWalk(AP). With TICSTEP > 1, a walk of n = PM_STEPS steps
;;; (a blocked chunk of 2 steps tries no single step: P_NewChaseDir tries
;;; the next direction); the steps after the first count down movecount,
;;; as the calls of A_Chase after P_NewChaseDir would. Out: PM_STEPS = the
;;; steps not done.
tryWalk:
#if TICSTEP > 1
              sep     #0x20                 ; n, and no retry: a blocked chunk
              stz     .near PM_R            ;   tries the next direction
              lda     .near PM_STEPS
              sta     .near PM_N
              rep     #0x20
#endif
              jsr     .kbank pMove
              and     ##0x00ff
              bne     1$
              rts
1$:           jsl     long:P_Random         ; actor->movecount = P_Random() & 15
              and     ##15
#if TICSTEP > 1
              sec                           ;   - (n - 1), bytes (the high byte
              sbc     .near PM_N            ;   when it changes)
              inc     a
              ldy     ##OFS_MO_MOVECOUNT
              sep     #0x20
              sta     [.tiny AP],y
              xba
              iny
              cmp     [.tiny AP],y
              beq     2$
              sta     [.tiny AP],y
2$:           rep     #0x20
#else
              ldy     ##OFS_MO_MOVECOUNT
              sta     [.tiny AP],y
#endif
              lda     ##1
              rts

#if TICSTEP > 1
;;; oneStep: PM_STEPS = 1, for the public entries. kSteps: PM_STEPS = k
;;; and PM_R = 1, for A_Chase. X and Y are kept.
oneStep:      sep     #0x20
              lda     #1
              bra     stepsSet
kSteps:       sep     #0x20
              lda     #1
              sta     .near PM_R
              lda     .near CH_K
stepsSet:     sta     .near PM_STEPS
              rep     #0x20
              rts
#endif

;;; ---------------------------------------------------------------------------
;;; lookForPlayers: P_LookForPlayers(AP, allaround C), with P_IsVisible.
;;; ---------------------------------------------------------------------------
lookForPlayers:
              pha
              lda     .near (_g_player+OFS_PL_HEALTH) ; dead
              beq     0$
              bpl     1$
0$:           brl     90$
1$:           pla
              bne     10$                   ; allaround: only the sight check
              ;; an = R_PointToAngle2(actor, player->mo) - actor->angle
              lda     .near (_g_player+OFS_PL_MO)
              sta     dp:.tiny AT
              lda     .near (_g_player+OFS_PL_MO+2)
              sta     dp:.tiny (AT+2)
              jsl     long:behindFast       ; the answer without the angle,
              bcc     3$                    ;   if it can tell
              cmp     ##0
              beq     10$                   ; in front
              bra     4$                    ; behind
3$:           jsr     .kbank angleToAT
              sec
              ldy     ##OFS_MO_ANGLE
              sbc     [.tiny AP],y
              pha
              txa
              iny
              iny
              sbc     [.tiny AP],y
              tax                           ; X:1,s = an
              pla
              ;; ANG90 < an && an < ANG270 (unsigned)
              cmp     ##1                   ; an - (ANG90 + 1) >= 0: an > ANG90
              txa
              sbc     ##0x4000
              bcc     10$
              cpx     ##0xc000              ; an < ANG270: hi < 0xc000
              bcs     10$
              ;; and P_AproxDistance(mo - actor) > MELEERANGE: not visible
4$:           jsr     .kbank distanceAT
              cmp     ##1                   ; > 64 << 16 (signed): hi > 64, or hi = 64 and lo > 0
              txa
              sbc     ##64
              bvc     5$
              eor     ##0x8000
5$:           bmi     10$
              lda     ##0
              rts
10$:          lda     .near (_g_player+OFS_PL_MO)
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_player+OFS_PL_MO+2)
              sta     dp:.tiny (_Dp+6)
              ARGAP
              jsl     long:P_CheckSight
              and     ##0x00ff
              bne     20$
              rts
20$:          lda     .near (_g_player+OFS_PL_MO) ; actor->target = player->mo
              ldy     ##OFS_MO_TARGET
              sta     [.tiny AP],y
              lda     .near (_g_player+OFS_PL_MO+2)
              iny
              iny
              sta     [.tiny AP],y
              sep     #0x20                 ; actor->threshold = 60
              lda     #60
              ldy     ##OFS_MO_THRESHOLD
              sta     [.tiny AP],y
              rep     #0x20
              lda     ##1
              rts
90$:          pla
              lda     ##0
              rts

;;; angleToAT: X:C = R_PointToAngle2(actor->x, actor->y, AT->x, AT->y).
angleToAT:    sec                           ; y2 - y1
              ldy     ##OFS_MO_Y
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              sta     dp:.tiny _Dp
              iny
              iny
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              sta     dp:.tiny (_Dp+2)
              sec                           ; x2 - x1
              ldy     ##OFS_MO_X
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              pha
              iny
              iny
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              tax
              pla
              jsl     long:R_PointToAngle3
              rts

;;; distanceAT: X:C = P_AproxDistance(AT->x - actor->x, AT->y - actor->y).
distanceAT:   sec
              ldy     ##OFS_MO_Y
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              sta     dp:.tiny _Dp
              iny
              iny
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              sta     dp:.tiny (_Dp+2)
              sec
              ldy     ##OFS_MO_X
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              pha
              iny
              iny
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              tax
              pla
              jsl     long:P_AproxDistance
              rts

;;; ---------------------------------------------------------------------------
;;; void A_Look(mobj_t __far* actor)
;;; ---------------------------------------------------------------------------
              .public A_Look
A_Look:       ENTER
              pei     dp:.tiny (AT+2)
              pei     dp:.tiny AT
              sep     #0x20                 ; actor->threshold = 0
              lda     #0
              ldy     ##OFS_MO_THRESHOLD
              sta     [.tiny AP],y
              rep     #0x20
              ldy     ##OFS_MO_PURSUECOUNT  ; actor->pursuecount = 0
              lda     ##0
              sta     [.tiny AP],y
              ;; targ = actor->subsector->sector->soundtarget
              ldy     ##OFS_MO_SUBSECTOR
              lda     [.tiny AP],y
              sta     dp:.tiny AT
              iny
              iny
              lda     [.tiny AP],y
              sta     dp:.tiny (AT+2)
              ldy     ##(OFS_SUB_SECTOR+2)
              lda     [.tiny AT],y
              tax
              ldy     ##OFS_SUB_SECTOR
              lda     [.tiny AT],y
              sta     dp:.tiny AT
              stx     dp:.tiny (AT+2)
              ldy     ##(OFS_SEC_SOUNDTARGET+2)
              lda     [.tiny AT],y
              tax
              ldy     ##OFS_SEC_SOUNDTARGET
              lda     [.tiny AT],y
              sta     dp:.tiny AT
              stx     dp:.tiny (AT+2)
              ora     dp:.tiny (AT+2)
              beq     5$
              ldy     ##OFS_MO_FLAGS        ; targ->flags & MF_SHOOTABLE
              lda     [.tiny AT],y
              and     ##CONST_MF_SHOOTABLE_LO
              beq     5$
              lda     dp:.tiny AT           ; actor->target = targ
              ldy     ##OFS_MO_TARGET
              sta     [.tiny AP],y
              lda     dp:.tiny (AT+2)
              iny
              iny
              sta     [.tiny AP],y
              ldy     ##OFS_MO_FLAGS        ; MF_AMBUSH: seen only if visible
              lda     [.tiny AP],y
              and     ##CONST_MF_AMBUSH_LO
              beq     10$
              lda     dp:.tiny AT
              sta     dp:.tiny (_Dp+4)
              lda     dp:.tiny (AT+2)
              sta     dp:.tiny (_Dp+6)
              ARGAP
              jsl     long:P_CheckSight
              and     ##0x00ff
              bne     10$
5$:           lda     ##0                   ; not seen: look for the player
              jsr     .kbank lookForPlayers
              and     ##0x00ff
              bne     10$
              brl     90$

              ;; go into chase state, with the see sound
10$:          MINFO
              phx
              lda     abs:OFS_MI_SEESOUND,x
              beq     20$
              cmp     ##CONST_SFX_POSIT1
              beq     11$
              cmp     ##CONST_SFX_POSIT2
              beq     11$
              cmp     ##CONST_SFX_BGSIT1
              bne     15$
              jsl     long:P_Random         ; sfx_bgsit1 + P_Random() % 2
              and     ##1
              clc
              adc     ##CONST_SFX_BGSIT1
              bra     15$
11$:          jsl     long:P_Random         ; sfx_posit1 + P_Random() % 3
              ldx     ##3
              jsl     long:_Mod16
              clc
              adc     ##CONST_SFX_POSIT1
15$:          pha
              ARGAP
              pla
              jsl     long:S_StartSound
20$:          plx                           ; P_SetMobjState(actor, seestate)
              ARGAP
              lda     abs:OFS_MI_SEESTATE,x
              jsl     long:P_SetMobjState
90$:          pla
              sta     dp:.tiny AT
              pla
              sta     dp:.tiny (AT+2)
              lda     ##0
              LEAVE

;;; ---------------------------------------------------------------------------
;;; void A_Chase(mobj_t __far* actor)
;;; With TICSTEP > 1 the call does the work of k chase states of a world
;;; run (k = chaseX + 1, src/iigs/p_tick65.s; 1 for other calls): the
;;; counters count down k, the turn takes up to k steps, the checks run
;;; once (the missile check when movecount runs out in the k steps), and
;;; the move takes k steps. k = 1 is the call of Doom.
;;; ---------------------------------------------------------------------------
              .public A_Chase
A_Chase:      ENTER
              pei     dp:.tiny (AT+2)
              pei     dp:.tiny AT
#if TICSTEP > 1
              sep     #0x20                 ; k = chaseX + 1, chaseX = 0 again
              lda     .near chaseX
              beq     60$
              stz     .near chaseX
60$:          inc     a
              ldy     ##OFS_MO_REACTIONTIME ; reactiontime -= k, not below 0
              sta     .near CH_K            ;   (it is below 256: a byte)
              lda     [.tiny AP],y
              beq     62$
              sec
              sbc     .near CH_K
              bcs     61$
              lda     #0
61$:          sta     [.tiny AP],y
62$:          rep     #0x20
#else
              ldy     ##OFS_MO_REACTIONTIME ; if (reactiontime) reactiontime--
              lda     [.tiny AP],y
              beq     1$
              dec     a
              sta     [.tiny AP],y
#endif
1$:           ldy     ##OFS_MO_THRESHOLD    ; modify the target threshold
              lda     [.tiny AP],y
              and     ##0x00ff
              beq     4$
              jsr     .kbank loadTarget
              beq     2$                    ; no target
              ldy     ##OFS_MO_HEALTH
              lda     [.tiny AT],y
              beq     2$
              bmi     2$
              ldy     ##OFS_MO_THRESHOLD    ; threshold--
              sep     #0x20
              lda     [.tiny AP],y
#if TICSTEP > 1
              sec                           ;   (threshold -= k, not below 0)
              sbc     .near CH_K
              bcs     63$
              lda     #0
63$:
#else
              dec     a
#endif
              sta     [.tiny AP],y
              rep     #0x20
              bra     4$
2$:           sep     #0x20                 ; threshold = 0
              lda     #0
              ldy     ##OFS_MO_THRESHOLD
              sta     [.tiny AP],y
              rep     #0x20

              ;; turn towards the movement direction
4$:           ldy     ##OFS_MO_MOVEDIR
              lda     [.tiny AP],y
              and     ##0x00ff
              cmp     ##8
              bcs     8$
#if TICSTEP > 1
              ;; k turns of ANG90 / 2 at most, on the byte 3 of the angle
              ;; (angle &= 7 << 29: the other bytes are 0); T = the byte 3
              ;; of movedir << 29 (dirByte). Byte stores, only of the bytes
              ;; that change.
              sep     #0x20
              tax                           ; X = movedir
              ldy     ##(OFS_MO_ANGLE+3)    ; d = (byte 3 & 0xe0) - T, wrapped:
              lda     [.tiny AP],y          ;   its sign is the way to turn
              and     #0xe0
              sec
              sbc     long:dirByte,x
              ldy     .near CH_K
64$:          cmp     #0                    ; d = 0: at movedir
              beq     66$
              bmi     65$
              sbc     #0x20                 ; d > 0: angle -= ANG90 / 2
              dey
              bne     64$
              bra     66$
65$:          clc                           ; d < 0: angle += ANG90 / 2
              adc     #0x20
              dey
              bne     64$
66$:          clc                           ; the byte 3: T + d
              adc     long:dirByte,x
              ldy     ##(OFS_MO_ANGLE+3)
              cmp     [.tiny AP],y
              beq     67$
              sta     [.tiny AP],y
67$:          rep     #0x20                 ; the bytes 0 to 2: 0 (after
              ldy     ##OFS_MO_ANGLE        ;   A_FaceTarget)
              lda     [.tiny AP],y
              iny
              ora     [.tiny AP],y
              beq     8$
              sep     #0x20
              lda     #0
              sta     [.tiny AP],y
              dey
              sta     [.tiny AP],y
              iny
              iny
              sta     [.tiny AP],y
              rep     #0x20
#else
              xba                           ; movedir << 29, high word: << 13
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sta     .near EN_T
              ldy     ##(OFS_MO_ANGLE+2)    ; angle &= 7 << 29 (the low word to 0)
              lda     [.tiny AP],y
              and     ##0xe000
              sta     [.tiny AP],y
              tax
              ldy     ##OFS_MO_ANGLE
              lda     ##0
              sta     [.tiny AP],y
              txa                           ; delta = angle - (movedir << 29),
              sec                           ; wrapped: its sign is bit 31
              sbc     .near EN_T
              beq     8$
              bmi     6$
              lda     ##-0x2000             ; delta > 0: angle -= ANG90 / 2
              bra     7$
6$:           lda     ##0x2000              ; delta < 0: angle += ANG90 / 2
7$:           clc
              ldy     ##(OFS_MO_ANGLE+2)
              adc     [.tiny AP],y
              sta     [.tiny AP],y
#endif

              ;; no target that can be shot: look for a new one
8$:           jsr     .kbank loadTarget
              beq     9$
              ldy     ##OFS_MO_FLAGS
              lda     [.tiny AT],y
              and     ##CONST_MF_SHOOTABLE_LO
              bne     10$
9$:           lda     ##1
              jsr     .kbank lookForPlayers
              and     ##0x00ff
              bne     99$
              MINFO                         ; no new target: the spawn state
              ARGAP
              lda     abs:OFS_MI_SPAWNSTATE,x
              jsl     long:P_SetMobjState
              bra     99$

              ;; do not attack twice in a row
10$:          ldy     ##OFS_MO_FLAGS
              lda     [.tiny AP],y
              bit     ##CONST_MF_JUSTATTACKED_LO
              beq     20$
              and     ##(0xffff - CONST_MF_JUSTATTACKED_LO)
              sta     [.tiny AP],y
              lda     .near _g_gameskill
              and     ##0x00ff
              cmp     ##CONST_SK_NIGHTMARE
              beq     99$
#if TICSTEP > 1
              jsr     .kbank kSteps         ; the new direction: k steps
#endif
              jsr     .kbank newChaseDir
99$:          brl     chaseDone

              ;; melee attack
20$:          MINFO
              lda     abs:OFS_MI_MELEESTATE,x
              beq     30$
              jsr     .kbank checkMeleeRange
              and     ##0x00ff
              beq     30$
              MINFO
              phx
              lda     abs:OFS_MI_ATTACKSOUND,x
              beq     21$
              pha
              ARGAP
              pla
              jsl     long:S_StartSound
21$:          lda     1,s
              tax
              ARGAP
              lda     abs:OFS_MI_MELEESTATE,x
              jsl     long:P_SetMobjState
              plx
              lda     abs:OFS_MI_MISSILESTATE,x ; no missile: remember the attack
              bne     99$
              ldy     ##OFS_MO_FLAGS
              lda     [.tiny AP],y
              ora     ##CONST_MF_JUSTHIT_LO
              sta     [.tiny AP],y
              bra     99$

              ;; missile attack
30$:          MINFO
              lda     abs:OFS_MI_MISSILESTATE,x
              beq     40$
              lda     .near _g_gameskill    ; !(gameskill < nightmare && movecount)
              and     ##0x00ff
              cmp     ##CONST_SK_NIGHTMARE
              bcs     31$
              ldy     ##OFS_MO_MOVECOUNT
              lda     [.tiny AP],y
#if TICSTEP > 1
              cmp     .near CH_K            ;   (movecount is 0 in one of the k
              bcs     40$                   ;   steps: 0 <= movecount < k)
#else
              bne     40$
#endif
31$:          jsr     .kbank checkMissileRange
              and     ##0x00ff
              beq     40$
              MINFO
              ARGAP
              lda     abs:OFS_MI_MISSILESTATE,x
              jsl     long:P_SetMobjState
              ldy     ##OFS_MO_FLAGS
              lda     [.tiny AP],y
              ora     ##CONST_MF_JUSTATTACKED_LO
              sta     [.tiny AP],y
              brl     chaseDone

              ;; pursuit time, and maybe a new target
40$:          ldy     ##OFS_MO_THRESHOLD
              lda     [.tiny AP],y
              and     ##0x00ff
              bne     50$
              ldy     ##OFS_MO_PURSUECOUNT
              lda     [.tiny AP],y
#if TICSTEP > 1
              sep     #0x20                 ; pursuecount -= k (below 256: a
              sec                           ;   byte)
              sbc     .near CH_K
              bcc     41$
              sta     [.tiny AP],y
              rep     #0x20
              bra     50$
41$:          clc                           ; it ran out in the k steps: the
              adc     #(CONST_BASETHRESHOLD + 1) ; check, and BASETHRESHOLD
              sta     [.tiny AP],y          ;   less the steps after it
              rep     #0x20
#else
              beq     41$
              dec     a
              sta     [.tiny AP],y
              bra     50$
41$:          lda     ##CONST_BASETHRESHOLD
              sta     [.tiny AP],y
#endif
              ;; unless a live target can be seen, find a new one
              jsr     .kbank loadTarget
              beq     42$
              ldy     ##OFS_MO_HEALTH
              lda     [.tiny AT],y
              beq     42$
              bmi     42$
              lda     dp:.tiny AT
              sta     dp:.tiny (_Dp+4)
              lda     dp:.tiny (AT+2)
              sta     dp:.tiny (_Dp+6)
              ARGAP
              jsl     long:P_CheckSight
              and     ##0x00ff
              bne     50$
42$:          lda     ##1
              jsr     .kbank lookForPlayers
              and     ##0x00ff
#if TICSTEP > 1
              beq     50$
              brl     chaseDone
#else
              bne     chaseDone
#endif

              ;; chase towards the player
50$:          ldy     ##OFS_MO_MOVECOUNT    ; if (--movecount < 0 || !P_Move(actor))
              lda     [.tiny AP],y
#if TICSTEP > 1
              ;; k steps: movecount -= k; movedir takes the steps before
              ;; movecount runs out (m = movecount, k at most), a new
              ;; direction the steps after it and the steps of a blocked
              ;; move
              tax                           ; X = m
              sec                           ; movecount -= k (bytes: the high
              sbc     .near CH_K            ;   byte when it changes)
              sep     #0x20
              sta     [.tiny AP],y
              xba
              iny
              cmp     [.tiny AP],y
              beq     68$
              sta     [.tiny AP],y
68$:          rep     #0x20
              jsr     .kbank kSteps
              txa                           ; m <= 0: a new direction for all
              beq     51$                   ;   k steps
              bmi     51$
              cmp     .near CH_K            ; m < k: m steps in movedir
              bcs     69$
              sep     #0x20
              sta     .near PM_STEPS
              rep     #0x20
69$:          jsr     .kbank pMove          ; (PM_STEPS: the steps not moved)
              ldy     ##OFS_MO_MOVECOUNT    ; and the steps after movecount
              lda     [.tiny AP],y          ;   ran out: -movecount
              bpl     70$
              eor     ##0xffff
              sec
              adc     .near PM_STEPS
              sep     #0x20
              sta     .near PM_STEPS
              rep     #0x20
70$:          lda     .near PM_STEPS        ; none left: done
              beq     52$
51$:          jsr     .kbank newChaseDir
#else
              dec     a
              sta     [.tiny AP],y
              bmi     51$
              jsr     .kbank pMove
              and     ##0x00ff
              bne     52$
51$:          jsr     .kbank newChaseDir
#endif
              ;; the active sound
52$:          MINFO
              lda     abs:OFS_MI_ACTIVESOUND,x
              beq     chaseDone
              pha
              jsl     long:P_Random
#if TICSTEP > 1
              eor     ##0xffff              ; P_Random() < 3 * k: 3 * k -
              sec                           ;   P_Random() > 0
              adc     .near CH_K
              clc
              adc     .near CH_K
              clc
              adc     .near CH_K
              beq     53$
              bmi     53$
#else
              cmp     ##3
              bcs     53$
#endif
              ARGAP
              pla
              jsl     long:S_StartSound
              bra     chaseDone
53$:          pla
chaseDone:    pla
              sta     dp:.tiny AT
              pla
              sta     dp:.tiny (AT+2)
              lda     ##0
              LEAVE

;;; loadTarget: AT = actor->target, Z set if NULL.
loadTarget:   ldy     ##OFS_MO_TARGET
              lda     [.tiny AP],y
              sta     dp:.tiny AT
              iny
              iny
              lda     [.tiny AP],y
              sta     dp:.tiny (AT+2)
              ora     dp:.tiny AT
              rts

;;; ---------------------------------------------------------------------------
;;; boolean P_CheckMeleeRange(mobj_t __far* actor)
;;; boolean P_CheckMissileRange(mobj_t __far* actor)
;;; ---------------------------------------------------------------------------
              .public P_CheckMeleeRange, P_CheckMissileRange
P_CheckMeleeRange:
              ENTER
              pei     dp:.tiny (AT+2)
              pei     dp:.tiny AT
              jsr     .kbank checkMeleeRange
              bra     popAT
P_CheckMissileRange:
              ENTER
              pei     dp:.tiny (AT+2)
              pei     dp:.tiny AT
              jsr     .kbank checkMissileRange
popAT:        tay
              pla
              sta     dp:.tiny AT
              pla
              sta     dp:.tiny (AT+2)
              tya
              LEAVE

;;; checkMeleeRange: P_CheckMeleeRange(AP), the target in AT.
;;;   pl && P_AproxDistance(pl - actor) < MELEERANGE - 20 * FRACUNIT
;;;         + mobjinfo[pl->type].radius && P_CheckSight(actor, pl)
checkMeleeRange:
              jsr     .kbank loadTarget
              bne     1$
              lda     ##0
              rts
1$:           jsr     .kbank distanceAT
              sta     .near EN_T
              stx     .near (EN_T+2)
              ldy     ##OFS_MO_TYPE         ; mobjinfo[pl->type].radius + 44 << 16
              lda     [.tiny AT],y
              INFOADDR
              tax
              lda     abs:(OFS_MI_RADIUS+2),x ; the limit, high word
              clc
              adc     ##(CONST_MELEERANGE_HI - 20)
              sta     .near EN_D
              lda     .near EN_T            ; distance < limit (signed)
              cmp     abs:OFS_MI_RADIUS,x
              lda     .near (EN_T+2)
              SLT32   .near EN_D
              bmi     2$
              lda     ##0
              rts
2$:           lda     dp:.tiny AT
              sta     dp:.tiny (_Dp+4)
              lda     dp:.tiny (AT+2)
              sta     dp:.tiny (_Dp+6)
              ARGAP
              jsl     long:P_CheckSight
              and     ##0x00ff
              rts

;;; checkMissileRange: P_CheckMissileRange(AP), the target in AT.
checkMissileRange:
              jsr     .kbank loadTarget
              lda     dp:.tiny AT           ; P_CheckSight(actor, actor->target)
              sta     dp:.tiny (_Dp+4)
              lda     dp:.tiny (AT+2)
              sta     dp:.tiny (_Dp+6)
              ARGAP
              jsl     long:P_CheckSight
              and     ##0x00ff
              bne     1$
              rts
1$:           ldy     ##OFS_MO_FLAGS        ; just hit: fight back
              lda     [.tiny AP],y
              bit     ##CONST_MF_JUSTHIT_LO
              beq     2$
              and     ##(0xffff - CONST_MF_JUSTHIT_LO)
              sta     [.tiny AP],y
              lda     ##1
              rts
2$:           ldy     ##OFS_MO_REACTIONTIME ; do not attack yet
              lda     [.tiny AP],y
              beq     3$
              lda     ##0
              rts
              ;; dist = (P_AproxDistance(actor - target) - 64 * FRACUNIT
              ;;         - (no melee attack ? 128 * FRACUNIT : 0)) >> FRACBITS
3$:           jsr     .kbank loadTarget
              jsr     .kbank distanceAT
              txa
              sec
              sbc     ##64
              sta     .near EN_T
              MINFO
              lda     abs:OFS_MI_MELEESTATE,x
              bne     4$
              lda     .near EN_T
              sec
              sbc     ##128
              sta     .near EN_T
4$:           lda     .near EN_T            ; if (dist > 200) dist = 200
              sec
              sbc     ##201
              bvc     5$
              eor     ##0x8000
5$:           bmi     6$
              lda     ##200
              sta     .near EN_T
6$:           jsl     long:P_Random         ; if (P_Random() < dist) return false
              sec
              sbc     .near EN_T
              bvc     7$
              eor     ##0x8000
7$:           bmi     8$
              lda     ##1
              rts
8$:           lda     ##0
              rts

;;; ---------------------------------------------------------------------------
;;; void P_NewChaseDir(mobj_t __far* actor)
;;; ---------------------------------------------------------------------------
              .public P_NewChaseDir
P_NewChaseDir:
              ENTER
              pei     dp:.tiny (AT+2)
              pei     dp:.tiny AT
#if TICSTEP > 1
              jsr     .kbank oneStep
#endif
              jsr     .kbank newChaseDir
              brl     popAT

;;; newChaseDir: P_NewChaseDir(AP). With TICSTEP > 1, the walks in the new
;;; direction take PM_STEPS steps (tryWalk).
newChaseDir:  sec                           ; a tall dropoff:
              ldy     ##OFS_MO_FLOORZ       ; floorz - dropoffz > 24 * FRACUNIT &&
              lda     [.tiny AP],y          ; z <= floorz && !(flags & MF_DROPOFF) &&
              ldy     ##OFS_MO_DROPOFFZ     ; P_AvoidDropoff(actor)
              sbc     [.tiny AP],y
              sta     .near EN_T
              ldy     ##(OFS_MO_FLOORZ+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_MO_DROPOFFZ+2)
              sbc     [.tiny AP],y
              sta     .near (EN_T+2)
              lda     ##0                   ; 24 << 16 < floorz - dropoffz
              cmp     .near EN_T
              lda     ##24
              SLT32   .near (EN_T+2)
              bpl     10$
              ldy     ##OFS_MO_FLOORZ       ; z <= floorz: !(floorz < z)
              lda     [.tiny AP],y
              ldy     ##OFS_MO_Z
              cmp     [.tiny AP],y
              ldy     ##(OFS_MO_FLOORZ+2)
              lda     [.tiny AP],y
              ldy     ##(OFS_MO_Z+2)
              sbc     [.tiny AP],y
              bvc     1$
              eor     ##0x8000
1$:           bmi     10$
              ldy     ##OFS_MO_FLAGS
              lda     [.tiny AP],y
              and     ##CONST_MF_DROPOFF_LO
              bne     10$
              jsr     .kbank avoidDropoff
              beq     10$
              lda     .near EN_DDX          ; P_DoNewChaseDir(actor, dropoff_deltax, dropoff_deltay)
              sta     .near EN_D
              lda     .near (EN_DDX+2)
              sta     .near (EN_D+2)
              lda     .near EN_DDY
              sta     .near (EN_D+4)
              lda     .near (EN_DDY+2)
              sta     .near (EN_D+6)
              jsr     .kbank doNewChaseDir
              ldy     ##OFS_MO_MOVECOUNT    ; small steps away from the dropoff
              lda     ##1
              sta     [.tiny AP],y
              rts
10$:          jsr     .kbank loadTarget
              sec                           ; deltax = target->x - actor->x
              ldy     ##OFS_MO_X
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              sta     .near EN_D
              iny
              iny
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              sta     .near (EN_D+2)
              sec                           ; deltay = target->y - actor->y
              ldy     ##OFS_MO_Y
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              sta     .near (EN_D+4)
              iny
              iny
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              sta     .near (EN_D+6)
              ;; fall into doNewChaseDir

;;; doNewChaseDir: P_DoNewChaseDir(AP, EN_D deltax, EN_D+4 deltay).
;;; EN_DIR: xdir, ydir, olddir, turnaround (words).
doNewChaseDir:
              ldy     ##OFS_MO_MOVEDIR      ; olddir, turnaround
              lda     [.tiny AP],y
              and     ##0x00ff
              sta     .near (EN_DIR+4)
              cmp     ##CONST_DI_NODIR
              beq     1$
              eor     ##4
1$:           sta     .near (EN_DIR+6)
              ;; xdir: deltax > 10 << 16 east, < -10 << 16 west
              ldx     ##CONST_DI_EAST
              lda     ##0
              cmp     .near EN_D
              lda     ##10
              SLT32   .near (EN_D+2)
              bmi     3$
              ldx     ##CONST_DI_WEST
              lda     .near EN_D
              cmp     ##0
              lda     .near (EN_D+2)
              SLT32   ##-10
              bmi     3$
              ldx     ##CONST_DI_NODIR
3$:           stx     .near EN_DIR
              ;; ydir: deltay < -10 << 16 south, > 10 << 16 north
              ldx     ##CONST_DI_SOUTH
              lda     .near (EN_D+4)
              cmp     ##0
              lda     .near (EN_D+6)
              SLT32   ##-10
              bmi     4$
              ldx     ##CONST_DI_NORTH
              lda     ##0
              cmp     .near (EN_D+4)
              lda     ##10
              SLT32   .near (EN_D+6)
              bmi     4$
              ldx     ##CONST_DI_NODIR
4$:           stx     .near (EN_DIR+2)
              ;; the direct route
              lda     .near EN_DIR
              cmp     ##CONST_DI_NODIR
              beq     10$
              cpx     ##CONST_DI_NODIR
              beq     10$
              lda     ##0                   ; deltay < 0 ? (deltax > 0 ? SE : SW)
              cmp     .near EN_D            ;            : (deltax > 0 ? NE : NW)
              lda     ##0
              SLT32   .near (EN_D+2)        ; N: 0 < deltax
              php
              lda     .near (EN_D+6)
              bmi     5$
              ldx     ##CONST_DI_NORTHEAST
              plp
              bmi     6$
              ldx     ##CONST_DI_NORTHWEST
              bra     6$
5$:           ldx     ##CONST_DI_SOUTHEAST
              plp
              bmi     6$
              ldx     ##CONST_DI_SOUTHWEST
6$:           txa
              jsr     .kbank setDir         ; actor->movedir = the diagonal
              cmp     .near (EN_DIR+6)      ; turnaround != it
              beq     10$
              jsr     .kbank tryWalk
              and     ##0x00ff
              beq     10$
              rts
              ;; the other directions
10$:          jsl     long:P_Random         ; P_Random() > 200 || |deltay| > |deltax|
              cmp     ##201
              bcs     11$
              jsr     .kbank absGreater
              bcc     12$
11$:          lda     .near EN_DIR          ; swap xdir and ydir
              ldx     .near (EN_DIR+2)
              sta     .near (EN_DIR+2)
              stx     .near EN_DIR
12$:          lda     .near EN_DIR          ; xdir, unless it is the turnaround
              cmp     .near (EN_DIR+6)
              bne     13$
              lda     ##CONST_DI_NODIR
              sta     .near EN_DIR
13$:          cmp     ##CONST_DI_NODIR
              beq     14$
              jsr     .kbank setDir
              jsr     .kbank tryWalk
              and     ##0x00ff
              beq     14$
              rts
14$:          lda     .near (EN_DIR+2)      ; ydir, unless it is the turnaround
              cmp     .near (EN_DIR+6)
              bne     15$
              lda     ##CONST_DI_NODIR
              sta     .near (EN_DIR+2)
15$:          cmp     ##CONST_DI_NODIR
              beq     16$
              jsr     .kbank setDir
              jsr     .kbank tryWalk
              and     ##0x00ff
              beq     16$
              rts
16$:          lda     .near (EN_DIR+4)      ; the old direction
              cmp     ##CONST_DI_NODIR
              beq     17$
              jsr     .kbank setDir
              jsr     .kbank tryWalk
              and     ##0x00ff
              beq     17$
              rts
              ;; a random search order
17$:          jsl     long:P_Random
              and     ##1
              beq     20$
              lda     ##CONST_DI_EAST       ; east .. southeast
18$:          sta     .near EN_TDIR
              cmp     .near (EN_DIR+6)
              beq     19$
              jsr     .kbank setDir
              jsr     .kbank tryWalk
              and     ##0x00ff
              beq     19$
              rts
19$:          lda     .near EN_TDIR
              inc     a
              cmp     ##(CONST_DI_SOUTHEAST + 1)
              bcc     18$
              bra     30$
20$:          lda     ##CONST_DI_SOUTHEAST  ; southeast .. east
21$:          sta     .near EN_TDIR
              cmp     .near (EN_DIR+6)
              beq     22$
              jsr     .kbank setDir
              jsr     .kbank tryWalk
              and     ##0x00ff
              beq     22$
              rts
22$:          lda     .near EN_TDIR
              dec     a
              bpl     21$
              ;; the turnaround, or no direction
30$:          lda     .near (EN_DIR+6)
              jsr     .kbank setDir
              cmp     ##CONST_DI_NODIR
              beq     31$
              jsr     .kbank tryWalk
              and     ##0x00ff
              bne     31$
              lda     ##CONST_DI_NODIR
              jsr     .kbank setDir
31$:          rts

;;; setDir: actor->movedir = C (a byte). C is kept.
setDir:       sep     #0x20
              ldy     ##OFS_MO_MOVEDIR
              sta     [.tiny AP],y
              rep     #0x20
              and     ##0x00ff
              rts

;;; absGreater: carry set if |deltay| > |deltax| (EN_D, EN_D+4).
absGreater:   ldx     ##4
              jsr     .kbank absD           ; |deltay|
              sta     .near EN_T
              stx     .near (EN_T+2)
              ldx     ##0
              jsr     .kbank absD           ; |deltax| < |deltay| (signed)
              cmp     .near EN_T
              txa
              sbc     .near (EN_T+2)
              bvc     1$
              eor     ##0x8000
1$:           asl     a                     ; the sign into the carry
              rts

;;; absD: X:C = |the 32-bit delta at EN_D + X|.
absD:         lda     .near (EN_D+2),x
              bpl     1$
              lda     .near EN_D,x
              eor     ##0xffff
              clc
              adc     ##1
              pha
              lda     .near (EN_D+2),x
              eor     ##0xffff
              adc     ##0
              tax
              pla
              rts
1$:           lda     .near EN_D,x
              pha
              lda     .near (EN_D+2),x
              tax
              pla
              rts

;;; ---------------------------------------------------------------------------
;;; avoidDropoff: P_AvoidDropoff(AP), Z clear if the actor should move away
;;; from a tall dropoff by (EN_DDX, EN_DDY).
;;; ---------------------------------------------------------------------------
avoidDropoff: ldy     ##OFS_MO_RADIUS       ; the box: y + radius, y - radius,
              lda     [.tiny AP],y          ; x + radius, x - radius
              sta     .near EN_T
              iny
              iny
              lda     [.tiny AP],y
              sta     .near (EN_T+2)
              ldy     ##OFS_MO_Y
              ldx     ##(CONST_BOXTOP * 4)
              jsr     .kbank boxPlus
              ldx     ##(CONST_BOXBOTTOM * 4)
              jsr     .kbank boxMinus
              ldy     ##OFS_MO_X
              ldx     ##(CONST_BOXRIGHT * 4)
              jsr     .kbank boxPlus
              ldx     ##(CONST_BOXLEFT * 4)
              jsr     .kbank boxMinus
              ;; the blocks: (box - bmaporg) >> MAPBLOCKSHIFT
              ldx     ##(CONST_BOXLEFT * 4)
              ldy     ##.near _g_bmaporgx
              jsr     .kbank blockOf
              sta     .near EN_B            ; xl
              ldx     ##(CONST_BOXRIGHT * 4)
              ldy     ##.near _g_bmaporgx
              jsr     .kbank blockOf
              sta     .near (EN_B+2)        ; xh
              ldx     ##(CONST_BOXBOTTOM * 4)
              ldy     ##.near _g_bmaporgy
              jsr     .kbank blockOf
              sta     .near (EN_B+4)        ; yl
              ldx     ##(CONST_BOXTOP * 4)
              ldy     ##.near _g_bmaporgy
              jsr     .kbank blockOf
              sta     .near (EN_B+6)        ; yh
              ldy     ##OFS_MO_Z            ; floorz = actor->z
              lda     [.tiny AP],y
              sta     .near EN_FLOORZ
              iny
              iny
              lda     [.tiny AP],y
              sta     .near (EN_FLOORZ+2)
              stz     .near EN_DDX
              stz     .near (EN_DDX+2)
              stz     .near EN_DDY
              stz     .near (EN_DDY+2)
              inc     .near validcount
              lda     .near EN_B            ; for (bx = xl; bx <= xh; bx++)
              sta     .near EN_BX
1$:           lda     .near (EN_B+2)        ; bx <= xh: xh - bx >= 0
              sec
              sbc     .near EN_BX
              bvc     2$
              eor     ##0x8000
2$:           bmi     9$
              lda     .near (EN_B+4)        ; for (by = yl; by <= yh; by++)
              sta     .near EN_BY
3$:           lda     .near (EN_B+6)
              sec
              sbc     .near EN_BY
              bvc     4$
              eor     ##0x8000
4$:           bmi     8$
              lda     .near EN_BY           ; P_BlockLinesIterator(bx, by, PIT_AvoidDropoff)
              sta     dp:.tiny _Dp
              lda     ##.word0 PIT_AvoidDropoff
              sta     dp:.tiny (_Dp+4)
              lda     ##.word2 PIT_AvoidDropoff
              sta     dp:.tiny (_Dp+6)
              lda     .near EN_BX
              jsl     long:P_BlockLinesIterator
              inc     .near EN_BY
              bra     3$
8$:           inc     .near EN_BX
              bra     1$
9$:           lda     .near EN_DDX          ; (dropoff_deltax | dropoff_deltay) != 0
              ora     .near (EN_DDX+2)
              ora     .near EN_DDY
              ora     .near (EN_DDY+2)
              rts

;;; boxPlus, boxMinus: _g_tmbbox[X / 4] = the coordinate at Y of the actor
;;; plus or minus EN_T. Y is kept.
boxPlus:      clc
              lda     [.tiny AP],y
              adc     .near EN_T
              sta     abs:.near _g_tmbbox,x
              iny
              iny
              lda     [.tiny AP],y
              adc     .near (EN_T+2)
              sta     abs:.near (_g_tmbbox+2),x
              dey
              dey
              rts
boxMinus:     sec
              lda     [.tiny AP],y
              sbc     .near EN_T
              sta     abs:.near _g_tmbbox,x
              iny
              iny
              lda     [.tiny AP],y
              sbc     .near (EN_T+2)
              sta     abs:.near (_g_tmbbox+2),x
              dey
              dey
              rts

;;; blockOf: C = (_g_tmbbox[X / 4] - the origin at near address Y) >>
;;; MAPBLOCKSHIFT (FRACBITS + 7), arithmetic.
blockOf:      lda     abs:.near _g_tmbbox,x
              sec
              sbc     abs:0,y
              lda     abs:.near (_g_tmbbox+2),x
              sbc     abs:2,y
              ldx     ##7
1$:           cmp     ##0x8000
              ror     a
              dex
              bne     1$
              rts

;;; ---------------------------------------------------------------------------
;;; boolean PIT_AvoidDropoff(line_t __far* line)    In: _Dp[0-3]. Out: true.
;;; A two sided line that the box of P_AvoidDropoff touches, between the
;;; floor of the actor and a floor more than 24 below it: move away from
;;; the lower side.
;;; ---------------------------------------------------------------------------
PIT_AvoidDropoff:
              lda     dp:.tiny _Dp
              sta     .near EN_LINE
              lda     dp:.tiny (_Dp+2)
              sta     .near (EN_LINE+2)
              ldy     ##(OFS_LINE_SIDENUM+2) ; one sided lines do not count
              lda     [.tiny _Dp],y
              cmp     ##0xffff
              bne     1$
              brl     90$
              ;; the box touches the bounding box of the line
1$:           ldx     ##(CONST_BOXRIGHT * 4) ; tmbbox[RIGHT] > left << 16
              ldy     ##(OFS_LINE_BBOX + CONST_BOXLEFT * 2)
              jsr     .kbank boxAbove
              bmi     2$
              brl     90$
2$:           ldx     ##(CONST_BOXLEFT * 4) ; tmbbox[LEFT] < right << 16
              ldy     ##(OFS_LINE_BBOX + CONST_BOXRIGHT * 2)
              jsr     .kbank boxBelow
              bmi     3$
              brl     90$
3$:           ldx     ##(CONST_BOXTOP * 4)  ; tmbbox[TOP] > bottom << 16
              ldy     ##(OFS_LINE_BBOX + CONST_BOXBOTTOM * 2)
              jsr     .kbank boxAbove
              bmi     4$
              brl     90$
4$:           ldx     ##(CONST_BOXBOTTOM * 4) ; tmbbox[BOTTOM] < top << 16
              ldy     ##(OFS_LINE_BBOX + CONST_BOXTOP * 2)
              jsr     .kbank boxBelow
              bmi     5$
              brl     90$
              ;; and crosses the line: P_BoxOnLineSide(tmbbox, line) == -1
5$:           lda     .near EN_LINE
              sta     dp:.tiny (_Dp+4)
              lda     .near (EN_LINE+2)
              sta     dp:.tiny (_Dp+6)
              lda     ##.near _g_tmbbox
              sta     dp:.tiny _Dp
              lda     ##.word2 _g_tmbbox
              sta     dp:.tiny (_Dp+2)
              jsl     long:P_BoxOnLineSide
              cmp     ##0xffff
              beq     6$
              brl     90$
              ;; front and back floor heights
6$:           ldy     ##OFS_LINE_SIDENUM
              jsr     .kbank sideFloor
              sta     .near EN_D            ; front
              stx     .near (EN_D+2)
              ldy     ##(OFS_LINE_SIDENUM+2)
              jsr     .kbank sideFloor
              sta     .near (EN_D+4)        ; back
              stx     .near (EN_D+6)
              lda     .near (EN_FLOORZ+2)   ; floorz - 24 * FRACUNIT
              sec
              sbc     ##24
              sta     .near (EN_T+2)
              lda     .near EN_FLOORZ
              sta     .near EN_T
              ;; back == floorz && front < floorz - 24: the angle of (dx, dy)
              lda     .near (EN_D+4)
              cmp     .near EN_FLOORZ
              bne     10$
              lda     .near (EN_D+6)
              cmp     .near (EN_FLOORZ+2)
              bne     10$
              lda     .near EN_D
              cmp     .near EN_T
              lda     .near (EN_D+2)
              SLT32   .near (EN_T+2)
              bpl     10$
              lda     ##0                   ; + (dx, dy)
              bra     20$
              ;; front == floorz && back < floorz - 24: the angle of (-dx, -dy)
10$:          lda     .near EN_D
              cmp     .near EN_FLOORZ
              bne     19$
              lda     .near (EN_D+2)
              cmp     .near (EN_FLOORZ+2)
              bne     19$
              lda     .near (EN_D+4)
              cmp     .near EN_T
              lda     .near (EN_D+6)
              SLT32   .near (EN_T+2)
              bmi     11$
19$:          brl     90$
11$:
              lda     ##0xffff              ; - (dx, dy)
20$:          sta     .near EN_T            ; the sign: 0 or 0xffff
              lda     .near EN_LINE
              sta     dp:.tiny (_Dp+4)
              lda     .near (EN_LINE+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_LINE_DY         ; y = (+-dy) << 16
              lda     [.tiny (_Dp+4)],y
              jsr     .kbank signed
              sta     dp:.tiny (_Dp+2)
              stz     dp:.tiny _Dp
              ldy     ##OFS_LINE_DX         ; x = (+-dx) << 16
              lda     [.tiny (_Dp+4)],y
              jsr     .kbank signed
              tax
              lda     ##0
              jsl     long:R_PointToAngle3
              txa                           ; the fine angle: angle >> 19
              lsr     a
              lsr     a
              lsr     a
              pha
              jsl     long:finesine         ; dropoff_deltax -= finesine * 32
              jsr     .kbank times32
              lda     .near EN_DDX
              sec
              sbc     .near EN_D
              sta     .near EN_DDX
              lda     .near (EN_DDX+2)
              sbc     .near (EN_D+2)
              sta     .near (EN_DDX+2)
              pla
              jsl     long:finecosine       ; dropoff_deltay += finecosine * 32
              jsr     .kbank times32
              lda     .near EN_DDY
              clc
              adc     .near EN_D
              sta     .near EN_DDY
              lda     .near (EN_DDY+2)
              adc     .near (EN_D+2)
              sta     .near (EN_DDY+2)
90$:          lda     ##1
              rtl

;;; boxAbove: N set if _g_tmbbox[X / 4] > the line bbox word at Y << 16.
;;; boxBelow: N set if _g_tmbbox[X / 4] < the line bbox word at Y << 16.
boxAbove:     lda     [.tiny _Dp],y
              sta     .near EN_T
              lda     ##0                   ; bbox << 16 < tmbbox
              cmp     abs:.near _g_tmbbox,x
              lda     .near EN_T
              sbc     abs:.near (_g_tmbbox+2),x
              bvc     1$
              eor     ##0x8000
1$:           rts
boxBelow:     lda     [.tiny _Dp],y
              sta     .near EN_T
              lda     abs:.near _g_tmbbox,x ; tmbbox < bbox << 16
              cmp     ##0
              lda     abs:.near (_g_tmbbox+2),x
              sbc     .near EN_T
              bvc     1$
              eor     ##0x8000
1$:           rts

;;; sideFloor: X:C = the floor height of the sector of the side whose
;;; number is at offset Y of the line EN_LINE.
sideFloor:    lda     .near EN_LINE
              sta     dp:.tiny (_Dp+4)
              lda     .near (EN_LINE+2)
              sta     dp:.tiny (_Dp+6)
              lda     [.tiny (_Dp+4)],y     ; &_g_sides[n]: n * SIZEOF_SIDE
              ldx     ##SIZEOF_SIDE
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sides
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_sides+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##(OFS_SIDE_SECTOR+2) ; ->sector
              lda     [.tiny (_Dp+4)],y
              tax
              ldy     ##OFS_SIDE_SECTOR
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              ldy     ##(OFS_SEC_FLOORHEIGHT+2) ; ->floorheight
              lda     [.tiny (_Dp+4)],y
              tax
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     [.tiny (_Dp+4)],y
              rts

;;; signed: C = C, or -C when EN_T is 0xffff.
signed:       bit     .near EN_T
              bpl     1$
              eor     ##0xffff
              inc     a
1$:           rts

;;; times32: EN_D = X:C << 5.
times32:      sta     .near EN_D
              stx     .near (EN_D+2)
              ldx     ##5
1$:           asl     .near EN_D
              rol     .near (EN_D+2)
              dex
              bne     1$
              rts

;;; ---------------------------------------------------------------------------
;;; The action routines of the monster states. void A_x(mobj_t __far* actor)
;;; ---------------------------------------------------------------------------
              .public A_FaceTarget, A_PosAttack, A_SPosAttack, A_TroopAttack
              .public A_SargAttack, A_CyberAttack, A_BruisAttack, A_Scream
              .public A_XScream, A_Pain, A_Fall, A_Explode, A_BossDeath
              .public A_PlayerScream

;;; the actions that need AT keep it with these
ENTERT        .macro
              ENTER
              pei     dp:.tiny (AT+2)
              pei     dp:.tiny AT
              .endm
LEAVET        .macro
              pla
              sta     dp:.tiny AT
              pla
              sta     dp:.tiny (AT+2)
              lda     ##0
              LEAVE
              .endm

A_FaceTarget: ENTERT
              jsr     .kbank faceTarget
              LEAVET

;;; faceTarget: A_FaceTarget(AP). Z set if the actor has no target (AT).
faceTarget:   jsr     .kbank loadTarget
              bne     1$
              rts
1$:           ldy     ##OFS_MO_FLAGS        ; flags &= ~MF_AMBUSH
              lda     [.tiny AP],y
              and     ##(0xffff - CONST_MF_AMBUSH_LO)
              sta     [.tiny AP],y
              jsr     .kbank angleToAT      ; angle = R_PointToAngle2(actor, target)
              ldy     ##OFS_MO_ANGLE
              sta     [.tiny AP],y
              txa
              iny
              iny
              sta     [.tiny AP],y
              ldy     ##(OFS_MO_FLAGS+2)    ; a shadow target: angle += (t - P_Random()) << 21
              lda     [.tiny AT],y
              and     ##CONST_MF_SHADOW_HI
              beq     2$
              jsl     long:P_Random
              pha
              jsl     long:P_Random
              eor     ##0xffff
              sec
              adc     1,s
              sta     1,s
              pla
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              ldy     ##(OFS_MO_ANGLE+2)
              adc     [.tiny AP],y
              sta     [.tiny AP],y
2$:           lda     ##1                   ; Z clear: a target
              rts

;;; P_Random() % C
randMod:      pha
              jsl     long:P_Random
              plx
              jsl     long:_Mod16
              rts

;;; startSound: S_StartSound(actor, C).
startSound:   pha
              ARGAP
              pla
              jsl     long:S_StartSound
              rts

;;; lineAttack: P_LineAttack(actor, AC_ANGLE, MISSILERANGE, AC_SLOPE, C).
lineAttack:   pha                           ; the damage, then the slope
              lda     .near (AC_SLOPE+2)
              pha
              lda     .near AC_SLOPE
              pha
              stz     dp:.tiny (_Dp+4)      ; MISSILERANGE
              lda     ##CONST_MISSILERANGE_HI
              sta     dp:.tiny (_Dp+6)
              ARGAP
              lda     .near AC_ANGLE
              ldx     .near (AC_ANGLE+2)
              jsl     long:P_LineAttack
              pla
              pla
              pla
              rts

;;; aimLine: AC_SLOPE = P_AimLineAttack(actor, AC_ANGLE, MISSILERANGE).
aimLine:      stz     dp:.tiny (_Dp+4)
              lda     ##CONST_MISSILERANGE_HI
              sta     dp:.tiny (_Dp+6)
              ARGAP
              lda     .near AC_ANGLE
              ldx     .near (AC_ANGLE+2)
              jsl     long:P_AimLineAttack
              sta     .near AC_SLOPE
              stx     .near (AC_SLOPE+2)
              rts

;;; spreadAngle: AC_ANGLE = C:X base + (t - P_Random()) << 20, t = P_Random().
spreadAngle:  sta     .near AC_ANGLE
              stx     .near (AC_ANGLE+2)
              jsl     long:P_Random
              pha
              jsl     long:P_Random
              eor     ##0xffff
              sec
              adc     1,s
              sta     1,s
              pla
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     .near (AC_ANGLE+2)
              sta     .near (AC_ANGLE+2)
              rts

;;; damageTarget: P_DamageMobj(actor->target, actor, actor, C).
damageTarget: pei     dp:.tiny (AP+2)       ; source
              pei     dp:.tiny AP
              pha
              lda     dp:.tiny AP           ; inflictor
              sta     dp:.tiny (_Dp+4)
              lda     dp:.tiny (AP+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_MO_TARGET       ; target
              lda     [.tiny AP],y
              sta     dp:.tiny _Dp
              iny
              iny
              lda     [.tiny AP],y
              sta     dp:.tiny (_Dp+2)
              pla
              jsl     long:P_DamageMobj
              pla
              pla
              rts

;;; spawnMissile: P_SpawnMissile(actor, actor->target, C).
spawnMissile: pha
              ARGTARGET2
              ARGAP
              pla
              jsl     long:P_SpawnMissile
              rts

A_PosAttack:  ENTERT
              jsr     .kbank faceTarget
              beq     9$
              ldy     ##OFS_MO_ANGLE        ; angle = actor->angle
              lda     [.tiny AP],y
              sta     .near AC_ANGLE
              iny
              iny
              lda     [.tiny AP],y
              sta     .near (AC_ANGLE+2)
              jsr     .kbank aimLine
              lda     ##CONST_SFX_PISTOL
              jsr     .kbank startSound
              lda     .near AC_ANGLE
              ldx     .near (AC_ANGLE+2)
              jsr     .kbank spreadAngle
              lda     ##5                   ; damage = (P_Random() % 5 + 1) * 3
              jsr     .kbank randMod
              inc     a
              sta     .near AC_I
              asl     a
              clc
              adc     .near AC_I
              jsr     .kbank lineAttack
9$:           LEAVET

A_SPosAttack: ENTERT
              jsr     .kbank loadTarget
              beq     9$
              lda     ##CONST_SFX_SHOTGN
              jsr     .kbank startSound
              jsr     .kbank faceTarget
              ldy     ##OFS_MO_ANGLE        ; bangle = actor->angle
              lda     [.tiny AP],y
              sta     .near AC_ANGLE
              sta     .near AC_BASE
              iny
              iny
              lda     [.tiny AP],y
              sta     .near (AC_ANGLE+2)
              sta     .near (AC_BASE+2)
              jsr     .kbank aimLine
              lda     ##3
              sta     .near AC_I
1$:           lda     .near AC_BASE         ; angle = bangle + spread
              ldx     .near (AC_BASE+2)
              jsr     .kbank spreadAngle
              lda     ##5                   ; damage = ((P_Random() % 5) + 1) * 3
              jsr     .kbank randMod
              inc     a
              pha
              asl     a
              clc
              adc     1,s
              ply
              jsr     .kbank lineAttack
              dec     .near AC_I
              bne     1$
9$:           LEAVET

A_TroopAttack:
              ENTERT
              jsr     .kbank faceTarget
              beq     9$
              jsr     .kbank checkMeleeRange
              and     ##0x00ff
              beq     5$
              lda     ##CONST_SFX_CLAW
              jsr     .kbank startSound
              jsl     long:P_Random         ; damage = (P_Random() % 8 + 1) * 3
              and     ##7
              inc     a
              pha
              asl     a
              clc
              adc     1,s
              ply
              jsr     .kbank damageTarget
              bra     9$
5$:           lda     ##CONST_MT_TROOPSHOT
              jsr     .kbank spawnMissile
9$:           LEAVET

A_SargAttack: ENTERT
              jsr     .kbank faceTarget
              beq     9$
              jsr     .kbank checkMeleeRange
              and     ##0x00ff
              beq     9$
              lda     ##10                  ; damage = ((P_Random() % 10) + 1) * 4
              jsr     .kbank randMod
              inc     a
              asl     a
              asl     a
              jsr     .kbank damageTarget
9$:           LEAVET

A_CyberAttack:
              ENTERT
              jsr     .kbank faceTarget
              beq     9$
              lda     ##CONST_SFX_RLAUNC
              jsr     .kbank startSound
              lda     ##CONST_MT_ROCKET
              jsr     .kbank spawnMissile
9$:           LEAVET

A_BruisAttack:
              ENTERT
              jsr     .kbank loadTarget
              beq     9$
              jsr     .kbank checkMeleeRange
              and     ##0x00ff
              beq     5$
              lda     ##CONST_SFX_CLAW
              jsr     .kbank startSound
              jsl     long:P_Random         ; damage = (P_Random() % 8 + 1) * 10
              and     ##7
              inc     a
              asl     a
              pha
              asl     a
              asl     a
              clc
              adc     1,s
              ply
              jsr     .kbank damageTarget
              bra     9$
5$:           lda     ##CONST_MT_BRUISERSHOT
              jsr     .kbank spawnMissile
9$:           LEAVET

A_Scream:     ENTER
              MINFO
              lda     abs:OFS_MI_DEATHSOUND,x
              beq     9$
              cmp     ##CONST_SFX_PODTH1
              beq     1$
              cmp     ##CONST_SFX_PODTH2
              beq     1$
              cmp     ##CONST_SFX_BGDTH1
              bne     5$
              jsl     long:P_Random         ; sfx_bgdth1 + P_Random() % 2
              and     ##1
              clc
              adc     ##CONST_SFX_BGDTH1
              bra     5$
1$:           lda     ##3                   ; sfx_podth1 + P_Random() % 3
              jsr     .kbank randMod
              clc
              adc     ##CONST_SFX_PODTH1
5$:           jsr     .kbank startSound
9$:           lda     ##0
              LEAVE

A_XScream:    ENTER
              lda     ##CONST_SFX_SLOP
              jsr     .kbank startSound
              lda     ##0
              LEAVE

A_Pain:       ENTER
              MINFO
              lda     abs:OFS_MI_PAINSOUND,x
              beq     9$
              jsr     .kbank startSound
9$:           lda     ##0
              LEAVE

A_Fall:       ldy     ##OFS_MO_FLAGS        ; flags &= ~MF_SOLID
              lda     [.tiny _Dp],y
              and     ##(0xffff - CONST_MF_SOLID_LO)
              sta     [.tiny _Dp],y
              rtl

A_Explode:    ldy     ##OFS_MO_TARGET       ; P_RadiusAttack(thingy, thingy->target, 128)
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              lda     ##128
              jmp     long:P_RadiusAttack

A_PlayerScream:
              ENTER
              lda     ##CONST_SFX_PLDETH
              jsr     .kbank startSound
              lda     ##0
              LEAVE

;;; A_BossDeath: on map 8, when the last baron dies and the player lives,
;;; lower the floors of tag 666.
A_BossDeath:  lda     .near _g_gamemap
              cmp     ##8
              bne     60$
              ldy     ##OFS_MO_TYPE
              lda     [.tiny _Dp],y
              cmp     ##CONST_MT_BRUISER
              bne     60$
              lda     .near (_g_player+OFS_PL_HEALTH)
              beq     60$
              bpl     61$
60$:          rtl
61$:          ENTERT
              ;; any other boss of the type alive in the thinkers?
              lda     .near (_g_thinkerclasscap+OFS_TH_NEXT)
              sta     dp:.tiny AT
              lda     .near (_g_thinkerclasscap+OFS_TH_NEXT+2)
              sta     dp:.tiny (AT+2)
1$:           lda     dp:.tiny AT           ; th != &thinkercap
              cmp     ##.word0 _g_thinkerclasscap
              bne     2$
              lda     dp:.tiny (AT+2)
              cmp     ##.word2 _g_thinkerclasscap
              beq     8$
2$:           ldy     ##OFS_TH_FUNCTION     ; th->function == P_MobjThinker
              lda     [.tiny AT],y
              cmp     ##.word0 P_MobjThinker
              bne     5$
              iny
              iny
              lda     [.tiny AT],y
              and     ##0x00ff              ; (not CLEAN)
              cmp     ##.word2 P_MobjThinker
              bne     5$
              lda     dp:.tiny AT           ; mo2 != mo
              cmp     dp:.tiny AP
              bne     3$
              lda     dp:.tiny (AT+2)
              cmp     dp:.tiny (AP+2)
              beq     5$
3$:           ldy     ##OFS_MO_TYPE         ; the same type, alive
              lda     [.tiny AT],y
              cmp     ##CONST_MT_BRUISER
              bne     5$
              ldy     ##OFS_MO_HEALTH
              lda     [.tiny AT],y
              beq     5$
              bpl     9$                    ; another boss lives
5$:           ldy     ##(OFS_TH_NEXT+2)     ; th = th->next
              lda     [.tiny AT],y
              tax
              ldy     ##OFS_TH_NEXT
              lda     [.tiny AT],y
              sta     dp:.tiny AT
              stx     dp:.tiny (AT+2)
              bra     1$
8$:           lda     ##666                 ; victory: EV_DoFloor(&junk, lowerFloorToLowest)
              sta     .near (AC_JUNK+OFS_LINE_TAG)
              lda     ##.near AC_JUNK
              sta     dp:.tiny _Dp
              lda     ##.word2 AC_JUNK
              sta     dp:.tiny (_Dp+2)
              lda     ##CONST_LOWERFLOORTOLOWEST
              jsl     long:EV_DoFloor
9$:           LEAVET

;;; behindFast: for an actor angle that is a multiple of ANG45, the answer
;;; of ANG90 < an < ANG270 (an = the angle to AT - the actor angle) from the
;;; whole units xi, yi of AT - actor: behind when d < 0, d = (xi, yi) dot
;;; the direction ((1, 0), (1, 1), (0, 1), ...). Only for S = |xi| + |yi|
;;; >= 64 and |xi|, |yi| < 4096. With T = (S + 2) >> 4, require
;;; 2 * (|d| - 1) > T on axes or |d| - 2 > T on diagonals. This margin
;;; keeps discarded coordinate fractions and angle-table quantization away
;;; from ANG90/ANG270. Carry set: A = 1 behind, 0 in front. Carry clear:
;;; decline the shortcut so the caller computes the angle.
              .section logiccode, text
behindFast:   ldy     ##(OFS_MO_ANGLE+2)    ; k = angle >> 29, the low 29 bits 0
              lda     [.tiny AP],y
              bit     ##0x1fff
              bne     90$
              xba                           ; X = 2 k
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              and     ##0x000e
              tax
              ldy     ##OFS_MO_ANGLE
              lda     [.tiny AP],y
              bne     90$
              sec                           ; xi = (AT->x - actor->x) >> 16
              ldy     ##OFS_MO_X
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              iny
              iny
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              sta     dp:.tiny _Dp
              sec                           ; yi
              ldy     ##OFS_MO_Y
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              iny
              iny
              lda     [.tiny AT],y
              sbc     [.tiny AP],y
              sta     dp:.tiny (_Dp+2)
              bpl     1$                    ; S = |xi| + |yi|, each below 4096
              eor     ##0xffff
              inc     a
1$:           cmp     ##4096
              bcs     90$
              sta     dp:.tiny (_Dp+4)
              lda     dp:.tiny _Dp
              bpl     2$
              eor     ##0xffff
              inc     a
2$:           cmp     ##4096
              bcs     90$
              clc
              adc     dp:.tiny (_Dp+4)
              cmp     ##64
              bcc     90$
              inc     a                     ; T = (S + 2) >> 4
              inc     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              sta     dp:.tiny (_Dp+4)
              jmp     (.kbank bfTab,x)
90$:          clc
              rtl
bfTab:        .word   .word0 bfD0, .word0 bfD1, .word0 bfD2, .word0 bfD3
              .word   .word0 bfD4, .word0 bfD5, .word0 bfD6, .word0 bfD7
bfD0:         lda     dp:.tiny _Dp          ; d = xi
              bra     bfEven
bfD2:         lda     dp:.tiny (_Dp+2)      ; d = yi
              bra     bfEven
bfD4:         lda     ##0                   ; d = -xi
              sec
              sbc     dp:.tiny _Dp
              bra     bfEven
bfD6:         lda     ##0                   ; d = -yi
              sec
              sbc     dp:.tiny (_Dp+2)
              bra     bfEven
bfD1:         lda     dp:.tiny _Dp          ; d = xi + yi
              clc
              adc     dp:.tiny (_Dp+2)
              bra     bfOdd
bfD3:         lda     dp:.tiny (_Dp+2)      ; d = yi - xi
              sec
              sbc     dp:.tiny _Dp
              bra     bfOdd
bfD5:         lda     ##0                   ; d = -xi - yi
              sec
              sbc     dp:.tiny _Dp
              sec
              sbc     dp:.tiny (_Dp+2)
              bra     bfOdd
bfD7:         lda     dp:.tiny _Dp          ; d = xi - yi
              sec
              sbc     dp:.tiny (_Dp+2)
bfOdd:        tay                           ; a diagonal: |d| - 2 > T
              bpl     1$
              eor     ##0xffff
              inc     a
1$:           sec
              sbc     ##2
              bcc     bfNo
              bra     bfCmp
bfEven:       tay                           ; an axis: |d| - 1 > (S + 2) >> 5,
              bpl     1$                    ;   that is 2 (|d| - 1) > T
              eor     ##0xffff
              inc     a
1$:           sec
              sbc     ##1
              bcc     bfNo
              asl     a
bfCmp:        cmp     dp:.tiny (_Dp+4)
              beq     bfNo
              bcc     bfNo
              tya                           ; behind: d < 0
              asl     a
              lda     ##0
              rol     a
              sec
              rtl
bfNo:         clc
              rtl

              .section logicfar, text
;;; speedStep: PM_TRY (Y = OFS_MO_X), PM_TRY + 4 (Y = OFS_MO_Y) = actor
;;; coordinate Y + speed * the speed of class C (0: 0, 1: 47000, 2:
;;; FRACUNIT, 3: -47000, 4: -FRACUNIT), speed in EN_T. A diagonal step of a
;;; speed below 32 takes speed * 47000 from SPD47: no multiply and no calls,
;;; and each word goes to PM_TRY as soon as it is ready. Far code in the
;;; slots $6700- (logicfar): the logic code of bank 3 has no room.
speedStep:    cmp     ##2
              beq     20$
              cmp     ##4
              beq     40$
              cmp     ##0
              beq     10$
              ldx     .near EN_T            ; a diagonal: speed * 47000
              cpx     ##32
              bcs     80$
              cmp     ##3
              beq     30$
              txa                           ; + speed * 47000
              asl     a
              asl     a
              tax
              lda     long:SPD47,x
              clc
              adc     [.tiny AP],y
              sta     abs:.near (PM_TRY-OFS_MO_X),y
              lda     long:(SPD47+2),x
              iny
              iny
              adc     [.tiny AP],y
              sta     abs:.near (PM_TRY-OFS_MO_X),y
              rtl
30$:          txa                           ; - speed * 47000
              asl     a
              asl     a
              tax
              lda     [.tiny AP],y
              sec
              sbc     long:SPD47,x
              sta     abs:.near (PM_TRY-OFS_MO_X),y
              iny
              iny
              lda     [.tiny AP],y
              sbc     long:(SPD47+2),x
              sta     abs:.near (PM_TRY-OFS_MO_X),y
              rtl
10$:          lda     [.tiny AP],y          ; 0: the coordinate
              sta     abs:.near (PM_TRY-OFS_MO_X),y
              iny
              iny
              lda     [.tiny AP],y
              sta     abs:.near (PM_TRY-OFS_MO_X),y
              rtl
20$:          lda     [.tiny AP],y          ; + speed << 16: the low word stays
              sta     abs:.near (PM_TRY-OFS_MO_X),y
              iny
              iny
              lda     [.tiny AP],y
              clc
              adc     .near EN_T
              sta     abs:.near (PM_TRY-OFS_MO_X),y
              rtl
40$:          lda     [.tiny AP],y          ; - speed << 16
              sta     abs:.near (PM_TRY-OFS_MO_X),y
              iny
              iny
              lda     [.tiny AP],y
              sec
              sbc     .near EN_T
              sta     abs:.near (PM_TRY-OFS_MO_X),y
              rtl
80$:          sty     .near (EN_T+2)        ; a speed of 32 or more: the
              pha                           ;   multiply
              txa
              ldx     ##47000
              jsl     long:umul16x
              ply
              cpy     ##3
              bne     81$
              eor     ##0xffff              ; minus
              clc
              adc     ##1
              pha
              txa
              eor     ##0xffff
              adc     ##0
              tax
              pla
81$:          ldy     .near (EN_T+2)        ; + the coordinate
              clc
              adc     [.tiny AP],y
              sta     abs:.near (PM_TRY-OFS_MO_X),y
              txa
              iny
              iny
              adc     [.tiny AP],y
              sta     abs:.near (PM_TRY-OFS_MO_X),y
              rtl

;;; SPD47: speed * 47000 for the speeds 0..31 (speedStep).
SPD47:
              .long   0, 47000, 94000, 141000
              .long   188000, 235000, 282000, 329000
              .long   376000, 423000, 470000, 517000
              .long   564000, 611000, 658000, 705000
              .long   752000, 799000, 846000, 893000
              .long   940000, 987000, 1034000, 1081000
              .long   1128000, 1175000, 1222000, 1269000
              .long   1316000, 1363000, 1410000, 1457000
