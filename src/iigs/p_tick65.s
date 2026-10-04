;;; Run thinker actions and actor state transitions.
;;;
;;; P_RunThinkers walks the list owned by p_think65.s. P_MobjThinker applies
;;; movement and state timing; P_SetMobjState follows state transitions and
;;; invokes their action functions. Those calls may remove or spawn actors.
;;; The iterator must preserve its next-entry and actor state across them.
;;;
;;; These routines run during game tics, before renderer production/replay.
;;; They reuse the DC_* drawer scratch for indirect addressing; that storage
;;; cannot retain renderer values across a tic. Hot stores are split where
;;; intervening work can overlap a buffered byte write.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "info.inc"
#include "tics.inc"
#if TICSTEP > 1
              .extern worldTic, A_Chase
#if TICSTEP > 10
              .extern A_Look
#endif
#endif

              .extern _Dp, _g_thinkerclasscap, states, mobjinfo, _g_player
              .extern _g_respawnmonsters, _g_leveltime
              .extern P_XYMovement, P_ZMovement, P_NightmareRespawn
              .extern P_RemoveMobj, P_Random, A_CyberAttack
              .extern DC_CMA, DC_ENTRY

MO_P          .equ    DC_CMA          ; mobj of P_MobjThinker
FN_P          .equ    DC_ENTRY        ; function to call (bank 0 for jml [])

#if TICSTEP > 1
              .section znear, bss
TS_LEFT:      .space  2               ; stateBudget: the tics of the run left
                                      ;   (the high byte stays 0)
              .public ticRun
ticRun:       .space  2               ; the tics of this call of
                                      ;   P_MobjThinker: 1 for the mobj of
                                      ;   the player, the tics of the run in
                                      ;   a world run (P_WorldRuns; the high
                                      ;   byte is 0)
              .public chaseX
chaseX:       .space  2               ; merge: the chase states that the next
                                      ;   call of A_Chase does, less 1 (a
                                      ;   byte; A_Chase sets it to 0 again)
SM_FIRST:     .space  2               ; merge: the first and the last of the
SM_LAST:      .space  2               ;   merged states (near addresses)
SM_LEFT:      .space  2               ;   the tics left when the last one
                                      ;   begins (a byte)
#endif

;;; jml [FN_P]
CALLFN        .macro
              jsl     long:callFn
              .endm

;;; DBR = the near bank (the bank of _g_thinkerclasscap). 8-bit A.
NEARDBR       .macro
              lda     #.byte2 _g_thinkerclasscap
              pha
              plb
              .endm

;;; The frame of P_RunThinkers: the mobj of an action (SM, a word), the
;;; bank of the walk (WB, 0xff: the near bank), the DBR of the caller.
SM            .equ    1
SM1           .equ    2
WB            .equ    3
WB4           .equ    7               ; (WB with th->next on the stack: 4 bytes)
FRT           .equ    3               ; (the size, with WB)

;;; WALKBANKW n: the same with 16-bit A (its high byte 0).
WALKBANKW     .macro  n
              lda     \n,s
              and     ##0x00ff
              cmp     ##0x00ff
              bne     1$
              lda     ##.byte2 _g_thinkerclasscap
1$:
              .endm

;;; NEARDBRW: DBR = the near bank, 16-bit A (A changes).
NEARDBRW      .macro
              lda     ##.byte2 _g_thinkerclasscap
              xba
              pha
              plb
              plb
              .endm

;;; A = the bank of the walk, the byte at n,s.
WALKBANK      .macro  n
              lda     \n,s
              cmp     #0xff
              bne     1$
              lda     #.byte2 _g_thinkerclasscap
1$:
              .endm

;;; ---------------------------------------------------------------------------
;;; void P_RunThinkers(void)
;;;
;;; The walk keeps DBR = the bank of the thinker and X = the thinker, so
;;; the fields of a thinker are abs,X and the walk from one thinker to the
;;; next stays in registers. The byte 11 of a mobj (the high byte of its
;;; thinker function, 0 in a pointer) tells its visit once a visit has read
;;; the function: 1 P_MobjThinker with no momentum on the floor (CLEAN), 2
;;; P_MobjBrainlessThinker, 3 no function; 0: read the function, as each
;;; visit of the other thinkers does. A new function (its high word) or a
;;; change of momentum, z or floorz (CLEARCLEAN, src/iigs/p_map65.s)
;;; clears it.
;;;
;;; A visit reads the next thinker before it writes the tics, and a mobj
;;; that runs out of tics gets its next state in the walk (state). A call
;;; of a thinker function keeps th->next on the stack, as the call may
;;; remove th.
;;;
;;; With TICSTEP = 1 the walk is in the slots of the logic ($2000-$3DFF):
;;; in bank 0 it shared the slots of pointOnSide and loadNode, which
;;; R_PointInSubsector runs in the moves.
;;; ---------------------------------------------------------------------------
#if TICSTEP > 1
              .section code, text
#else
              .section logiccode, text
#endif
              .public P_RunThinkers
P_RunThinkers:
              phb
              tsc                           ; the frame (no writes)
              sec
              sbc     ##FRT
              tcs
              ldy     .near (_g_thinkerclasscap+OFS_TH_NEXT) ; the first thinker
              sep     #0x20
              lda     .near (_g_thinkerclasscap+OFS_TH_NEXT+2)

;;; bank: the next thinker is Y in bank A (8-bit A), another bank than
;;; the walk: the head of the list (the end), or DBR = A. A thinker in
;;; the bank of the head makes each step come here (bank 0xff).
bank:         cmp     #.byte2 _g_thinkerclasscap
              bne     2$
              cpy     ##.word0 _g_thinkerclasscap
              beq     done
              pha
              plb
              tyx
              lda     #0xff
              sta     WB,s
              bra     visit
2$:           pha
              plb
              tyx
              sta     WB,s

;;; visit: X = the thinker, DBR = its bank, 8-bit A.
visit:        lda     abs:(OFS_TH_FUNCTION+3),x
              beq     find
              ldy     abs:OFS_TH_NEXT,x     ; Y and B = th->next, read before
              xba                           ;   the tics are written
              lda     abs:(OFS_TH_NEXT+2),x
              xba
#if TICSTEP > 1
              cmp     #3                    ; no function (3), the mobj of
              bcs     other                 ;   the player (4)
#else
              cmp     #3                    ; no function
              beq     step
#endif
              lda     abs:OFS_MO_TICS,x     ; the tics are -1 or 1..12 (the
              inc     a                     ;   states of info65.s): the low
              beq     forever               ;   byte tells -1, and an 8-bit
#if TICSTEP > 1
              clc                           ;   store keeps the high byte 0
              sbc     long:ticRun           ;   (tics -= ticRun: the state
              beq     toState               ;   ends in this run at 0 or less)
              bmi     toState
              sta     abs:OFS_MO_TICS,x
#else
              dec     abs:OFS_MO_TICS,x     ;   decrement keeps the high byte 0
              beq     toState               ;   (if (!--mobj->tics))
#endif
step:         xba                           ; th = th->next
step2:        cmp     WB,s
              bne     bank
              tyx
              bra     visit

#if TICSTEP > 1
toState:      brl     budget

;;; other: kind 3 (Z set: no function) or 4: the mobj of the player, which
;;; P_Ticker runs each tic. A mobj that is not his any more (a corpse after
;;; a new life) is found again. Y is still th->next.
other:        beq     step
              phb
              pla
              cmp     long:(_g_player+OFS_PL_MO+2)
              bne     1$
              rep     #0x20
              txa
              cmp     long:(_g_player+OFS_PL_MO)
              sep     #0x20
              bne     1$
              lda     abs:(OFS_TH_NEXT+2),x ; B = the bank of th->next
              xba
              bra     step
1$:           lda     #0
              sta     abs:(OFS_TH_FUNCTION+3),x
              brl     visit
#else
toState:      brl     state
#endif

done:         rep     #0x20
              tsc
              clc
              adc     ##FRT
              tcs
              plb
              rtl

;;; forever: tics -1. Only a MF_COUNTKILL mobj of P_MobjThinker has more
;;; to do, and only with respawnmonsters (nightmare respawn).
forever:      lda     abs:(OFS_TH_FUNCTION+3),x
              dec     a
              bne     step
              lda     long:_g_respawnmonsters
              ora     long:(_g_respawnmonsters+1)
              beq     step
              lda     abs:(OFS_MO_FLAGS+2),x
              and     #CONST_MF_COUNTKILL_HI
              beq     step
              rep     #0x20
              bra     call

;;; find: byte 11 is 0: the function, compared in full. P_MobjThinker of
;;; a mobj without momentum on the floor: only its tics (CLEAN), else the
;;; full thinker. P_MobjBrainlessThinker: only its tics. No function:
;;; nothing. Else the call.
find:         rep     #0x20
              ldy     abs:(OFS_TH_FUNCTION+2),x
              lda     abs:OFS_TH_FUNCTION,x
              cmp     ##.word0 P_MobjThinker
              bne     find2
              cpy     ##.word2 P_MobjThinker
              bne     call
#if TICSTEP > 1
              txa                           ; the mobj of the player: kind 4
              cmp     long:(_g_player+OFS_PL_MO)
              bne     5$
              sep     #0x20
              phb
              pla
              cmp     long:(_g_player+OFS_PL_MO+2)
              bne     4$
              lda     #4
              bra     kind
4$:           rep     #0x20
5$:
#endif
              lda     abs:OFS_MO_MOMX,x
              ora     abs:(OFS_MO_MOMX+2),x
              ora     abs:OFS_MO_MOMY,x
              ora     abs:(OFS_MO_MOMY+2),x
              ora     abs:OFS_MO_MOMZ,x
              ora     abs:(OFS_MO_MOMZ+2),x
              bne     call
              lda     abs:OFS_MO_Z,x        ; z == floorz
              cmp     abs:OFS_MO_FLOORZ,x
              bne     call
              lda     abs:(OFS_MO_Z+2),x
              cmp     abs:(OFS_MO_FLOORZ+2),x
              bne     call
              sep     #0x20
              lda     #1
kind:         sta     abs:(OFS_TH_FUNCTION+3),x
              brl     visit
find2:        cmp     ##.word0 P_MobjBrainlessThinker
              bne     find3
              cpy     ##.word2 P_MobjBrainlessThinker
              bne     call
              sep     #0x20
              lda     #2
              bra     kind
find3:        cmp     ##0                   ; no function
              bne     call
              cpy     ##0
              bne     call
              sep     #0x20
              lda     #3
              bra     kind

;;; call: th->function(th), X = th, DBR = its bank, 16-bit A. th->next
;;; goes on the stack (4 bytes), and the function runs with DBR = the
;;; near bank. Words: no SEP and REP (a bus cycle each).
call:         stx     dp:.tiny _Dp          ; _Dp = th
              lda     abs:(OFS_TH_NEXT+2),x ; th->next on the stack
              pha
              lda     abs:OFS_TH_NEXT,x
              pha
              lda     abs:OFS_TH_FUNCTION,x ; FN_P = th->function (its byte 3 is
              sta     dp:.tiny FN_P         ;   not read)
              lda     abs:(OFS_TH_FUNCTION+2),x
              sta     dp:.tiny (FN_P+2)
              WALKBANKW WB4
              sta     dp:.tiny (_Dp+2)      ; (_Dp+3 = 0)
              NEARDBRW
              CALLFN

;;; resume: after a call (16-bit A, DBR = the near bank): th = th->next of
;;; the stack.
resume:       ply
              pla
              sep     #0x20                 ; (the walk: 8-bit A)
              cmp     WB,s
              bne     1$
              pha                           ; DBR = the bank of the walk
              plb
              tyx
              brl     visit
1$:           brl     bank
              .space  23                    ; (the walk keeps its size)

#if TICSTEP > 1
;;; budget: the state of the mobj X ends in this run, with -A (8-bit A =
;;; tics - ticRun, 0 or less) tics of the run left: stateBudget runs the
;;; next states, with th->next on the stack as for a call.
budget:       eor     #0xff                 ; the tics left
              inc     a
              sta     long:TS_LEFT
              rep     #0x20
              stx     dp:.tiny _Dp          ; _Dp = th, th->next on the stack
              lda     abs:(OFS_TH_NEXT+2),x ;   (4 bytes)
              pha
              lda     abs:OFS_TH_NEXT,x
              pha
              WALKBANKW WB4
              sta     dp:.tiny (_Dp+2)
              NEARDBRW
              jsl     long:stateBudget
              brl     resume

;;; stateBudget: the state of the mobj _Dp[0-3] ended with TS_LEFT tics of
;;; the run left: the next states come, each with its action, until the
;;; mobj is gone or a state lasts past the run (its tics less the tics
;;; left). Chase states that begin in the same run merge (merge): one call
;;; of A_Chase does their steps, and the others come without the action.
;;; 16-bit A, DBR = the near bank.
stateBudget:  pei     dp:.tiny (_Dp+2)      ; the mobj, at 1,s
              pei     dp:.tiny _Dp
1$:           jsr     .kbank merge          ; carry set: states merge
              ldy     ##OFS_MO_STATE        ; P_SetMobjState(mobj,
              lda     [.tiny _Dp],y         ;   mobj->state->nextstate)
              tax
              lda     abs:OFS_ST_NEXTSTATE,x
              bcs     10$
              jsl     long:P_SetMobjState
              cmp     ##0                   ; removed
              beq     9$
              sep     #0x20                 ; _Dp = the mobj again (bytes;
              lda     1,s                   ;   the byte 3 is not read)
              sta     dp:.tiny _Dp
              lda     2,s
              sta     dp:.tiny (_Dp+1)
              lda     3,s
              sta     dp:.tiny (_Dp+2)
              rep     #0x20
3$:           ldy     ##OFS_MO_TICS
              lda     [.tiny _Dp],y
              bmi     9$                    ; -1: the state stays
              sec
              sbc     .near TS_LEFT
              beq     2$
              bcc     2$
              sep     #0x20                 ; it lasts: tics -= the tics left
              sta     [.tiny _Dp],y         ;   (1..12, the high byte is 0)
              rep     #0x20
              bra     9$
2$:           eor     ##0xffff              ; it ends too: left -= tics
              inc     a
              sep     #0x20
              sta     .near TS_LEFT
              rep     #0x20
              bra     1$
9$:           pla
              pla
              rtl

              ;; merged states: the action does the work of all of them
              ;; (A_Chase takes chaseX). When it keeps the state, the last
              ;; of them comes without the action, with the tics left
              ;; when it begins.
10$:          jsl     long:P_SetMobjState
              cmp     ##0                   ; removed
              beq     9$
              sep     #0x20                 ; _Dp = the mobj again (bytes)
              lda     1,s
              sta     dp:.tiny _Dp
              lda     2,s
              sta     dp:.tiny (_Dp+1)
              lda     3,s
              sta     dp:.tiny (_Dp+2)
              rep     #0x20
              ldy     ##OFS_MO_STATE        ; another state: as it is
              lda     [.tiny _Dp],y
              cmp     .near SM_FIRST
              bne     3$
              jsr     .kbank quietState
              bra     3$

#else
;;; state: the tics ran out: P_SetMobjState(mobj, mobj->state->nextstate)
;;; for the mobj X of the walk (8-bit A). Here the mobj is Y (abs,Y), X is
;;; 16 * the state (long,X in the states) and the writes are bytes: the
;;; state keeps its bank, the high byte of the tics is 0 at 0 and the high
;;; byte of a sprite is 0. S_NULL, the rocket cheat and the last thinker of
;;; the list with an action go to P_SetMobjState.
state:        rep     #0x20
              txy                           ; Y = the mobj
              lda     abs:OFS_MO_STATE,x    ; X = 16 * the state
              sec
              sbc     ##.near states
              tax
              lda     long:(_g_player+OFS_PL_CHEATS) ; a word AND: no SEP, REP
              and     ##CONST_CF_ENEMY_ROCKETS
              bne     stSlow
stNext:       lda     long:(states+OFS_ST_NEXTSTATE),x
              beq     stCall0
              asl     a
              asl     a
              asl     a
              asl     a
              tax
              clc                           ; mobj->state = &states[state], its
              adc     ##.near states        ;   sprite, frame and tics (words, no
              sta     abs:OFS_MO_STATE,y    ;   SEP and REP; the bank stays)
              lda     long:(states+OFS_ST_SPRITE),x
              sta     abs:OFS_MO_SPRITE,y
              lda     long:(states+OFS_ST_FRAME),x
              sta     abs:OFS_MO_FRAME,y
              lda     long:(states+OFS_ST_TICS),x
              sta     abs:OFS_MO_TICS,y
              lda     long:(states+OFS_ST_ACTION+2),x ; if (st->action): its bank (16-bit
              bne     stAct                 ;   A in stAct)
              lda     long:(states+OFS_ST_ACTION),x
              bne     stAct0
              lda     long:(states+OFS_ST_TICS),x ; while (!mobj->tics)
              beq     stNext
              sep     #0x20                 ; th = th->next (8-bit A: the walk)
              tyx
              ldy     abs:OFS_TH_NEXT,x
              lda     abs:(OFS_TH_NEXT+2),x
              brl     step2
              .space  30                    ; (the walk keeps its size)

stLast:       rep     #0x20                 ; the last thinker: C = the state
              txa
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              bra     stCall0
stSlow:       lda     long:(states+OFS_ST_NEXTSTATE),x
stCall0:      tax                           ; th->next on the stack (4 bytes)
              lda     abs:(OFS_TH_NEXT+2),y
              pha
              lda     abs:OFS_TH_NEXT,y
              pha

;;; stCall: P_SetMobjState(mobj, X) (16-bit A, Y = the mobj, DBR = its
;;; bank, the bank of the walk; th->next on the stack), then the walk
;;; goes on.
stCall:       sty     dp:.tiny _Dp          ; (words: no SEP and REP)
              WALKBANKW WB4
              sta     dp:.tiny (_Dp+2)
              NEARDBRW
              txa
              jsl     long:P_SetMobjState
              brl     resume
              .space  10                    ; (the code after keeps its address)

              ;; the action: the mobj in the frame (SM). The action cannot
              ;; unlink th, so th->next is read again after it, but for the
              ;; last thinker (a new thinker would follow it).
stAct0:       lda     ##0                   ; (an action in bank 0)
stAct:        sta     dp:.tiny (FN_P+2)     ; FN_P = st->action (A: its bank;
              lda     long:(states+OFS_ST_ACTION),x ;   words, no SEP and REP)
              sta     dp:.tiny FN_P
              lda     abs:(OFS_TH_NEXT+2),y ; the last thinker: P_SetMobjState
              and     ##0x00ff
              cmp     ##.byte2 _g_thinkerclasscap
              bne     2$
              lda     abs:OFS_TH_NEXT,y
              cmp     ##.word0 _g_thinkerclasscap
              beq     stLast
2$:           tya                           ; SM = _Dp = the mobj
              sta     SM,s
              sta     dp:.tiny _Dp
              WALKBANKW WB
              sta     dp:.tiny (_Dp+2)
              NEARDBRW
              CALLFN
              lda     SM,s                  ; Y = the mobj, DBR = its bank
              tay
              WALKBANKW WB
              xba
              pha
              plb
              plb
              lda     abs:OFS_MO_TICS,y     ; while (!mobj->tics)
              beq     6$
              tyx                           ; th = th->next
              ldy     abs:OFS_TH_NEXT,x
              sep     #0x20
              lda     abs:(OFS_TH_NEXT+2),x
              brl     step2
              .space  23                    ; (the code after keeps its address)
6$:           lda     abs:OFS_MO_STATE,y    ; (no mobj state has 0 tics, so
              sec                           ;   no call set it: st is the state
              sbc     ##.near states        ;   of the mobj)
              tax
              brl     stNext

#endif

callFn:       .byte   0xdc                  ; jml [FN_P]
              .word   .word0 FN_P

;;; ---------------------------------------------------------------------------
;;; void P_MobjThinker(mobj_t __far* mobj)      In: _Dp[0-3].
;;; ---------------------------------------------------------------------------
              .public P_MobjThinker
P_MobjThinker:
              sep     #0x20                 ; MO_P = mobj (3 bytes)
              lda     dp:.tiny _Dp
              sta     dp:.tiny MO_P
              lda     dp:.tiny (_Dp+1)
              sta     dp:.tiny (MO_P+1)
              lda     dp:.tiny (_Dp+2)
              sta     dp:.tiny (MO_P+2)
              rep     #0x20

              ;; momentum movement
              ldy     ##OFS_MO_MOMX
              lda     [.tiny MO_P],y
              iny
              iny
              ora     [.tiny MO_P],y
              ldy     ##OFS_MO_MOMY
              ora     [.tiny MO_P],y
              iny
              iny
              ora     [.tiny MO_P],y
              beq     10$
              jsl     long:P_XYMovement     ; (_Dp is the mobj)
              jsr     .kbank stillMobjThinker ; must've been removed?
              beq     10$
              rtl

              ;; if (mobj->z != mobj->floorz || mobj->momz)
10$:          ldy     ##OFS_MO_Z
              lda     [.tiny MO_P],y
              ldy     ##OFS_MO_FLOORZ
              cmp     [.tiny MO_P],y
              bne     11$
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny MO_P],y
              ldy     ##(OFS_MO_FLOORZ+2)
              cmp     [.tiny MO_P],y
              bne     11$
              ldy     ##OFS_MO_MOMZ
              lda     [.tiny MO_P],y
              iny
              iny
              ora     [.tiny MO_P],y
              beq     20$
11$:          jsr     .kbank mobjArg
              jsl     long:P_ZMovement
              jsr     .kbank stillMobjThinker
              beq     20$
              rtl

              ;; cycle through states (the tics are -1 or 1..12)
20$:          sep     #0x20
              ldy     ##OFS_MO_TICS
              lda     [.tiny MO_P],y
              inc     a
              beq     30$
#if TICSTEP > 1
              dec     a                     ; tics -= ticRun
              sec
              sbc     .near ticRun
              beq     22$
              bmi     22$
              sta     [.tiny MO_P],y
              rep     #0x20
              rtl
22$:          eor     #0xff                 ; the state ends in this run: the
              inc     a                     ;   next states, with the tics
              sta     .near TS_LEFT         ;   left
              rep     #0x20
              jsr     .kbank mobjArg
              brl     stateBudget
#else
              dec     a
              dec     a
              sta     [.tiny MO_P],y
              rep     #0x20
              bne     21$
              jsr     .kbank mobjArg        ; P_SetMobjState(mobj, mobj->state->nextstate)
              ldy     ##OFS_MO_STATE
              lda     [.tiny MO_P],y
              tax
              lda     abs:OFS_ST_NEXTSTATE,x
              jmp     long:P_SetMobjState
21$:          rtl
#endif

              ;; nightmare respawn
30$:          rep     #0x20
              ldy     ##(OFS_MO_FLAGS+2)    ; MF_COUNTKILL
              lda     [.tiny MO_P],y
              and     ##CONST_MF_COUNTKILL_HI
              beq     39$
              lda     .near _g_respawnmonsters
              beq     39$
              ldy     ##OFS_MO_MOVECOUNT    ; if (++movecount < 12 * 35) return
              sep     #0x20                 ;   (bytes)
              lda     [.tiny MO_P],y
#if TICSTEP > 1
              clc                           ; (movecount += ticRun)
              adc     .near ticRun
              sta     [.tiny MO_P],y
              bcc     33$
#else
              inc     a
              sta     [.tiny MO_P],y
              bne     33$
#endif
              iny
              lda     [.tiny MO_P],y
              inc     a
              sta     [.tiny MO_P],y
              dey
33$:          rep     #0x20
              lda     [.tiny MO_P],y
              sec
              sbc     ##(12 * 35)
              bvc     31$
              eor     ##0x8000
31$:          bmi     39$
#if TICSTEP > 1
              TICHIT  31                    ; if (leveltime & 31) return
              bcs     39$
#else
              lda     .near _g_leveltime    ; if (leveltime & 31) return
              and     ##31
              bne     39$
#endif
              jsl     long:P_Random         ; if (P_Random() > 4) return
              sec
              sbc     ##5
              bvc     32$
              eor     ##0x8000
32$:          bpl     39$
              jsr     .kbank mobjArg
              jmp     long:P_NightmareRespawn
39$:          rtl

;;; mobjArg: _Dp[0-3] = MO_P.
mobjArg:      sep     #0x20
              lda     dp:.tiny MO_P
              sta     dp:.tiny _Dp
              lda     dp:.tiny (MO_P+1)
              sta     dp:.tiny (_Dp+1)
              lda     dp:.tiny (MO_P+2)
              sta     dp:.tiny (_Dp+2)
              stz     dp:.tiny (_Dp+3)
              rep     #0x20
              rts

;;; stillMobjThinker: Z set if mobj->thinker.function is still P_MobjThinker.
stillMobjThinker:
              ldy     ##OFS_TH_FUNCTION
              lda     [.tiny MO_P],y
              cmp     ##.word0 P_MobjThinker
              bne     1$
              iny
              iny
              lda     [.tiny MO_P],y
              and     ##0x00ff              ; (not CLEAN)
              cmp     ##.word2 P_MobjThinker
1$:           rts

;;; ---------------------------------------------------------------------------
;;; void P_MobjBrainlessThinker(mobj_t __far* mobj)     In: _Dp[0-3].
;;; ---------------------------------------------------------------------------
              .public P_MobjBrainlessThinker
P_MobjBrainlessThinker:
              sep     #0x20                 ; the tics are -1 or 1..12
              ldy     ##OFS_MO_TICS
              lda     [.tiny _Dp],y
              inc     a
              beq     1$
#if TICSTEP > 1
              clc                           ; tics -= ticRun
              sbc     .near ticRun
              beq     2$
              bmi     2$
              sta     [.tiny _Dp],y
              rep     #0x20
              rtl
2$:           eor     #0xff                 ; the next states, with the tics
              inc     a                     ;   left (_Dp still holds mobj)
              sta     .near TS_LEFT
              rep     #0x20
              brl     stateBudget
#else
              dec     a
              dec     a
              sta     [.tiny _Dp],y
              rep     #0x20
              bne     9$
              ldy     ##OFS_MO_STATE        ; _Dp still holds mobj
              lda     [.tiny _Dp],y
              tax
              lda     abs:OFS_ST_NEXTSTATE,x
              jmp     long:P_SetMobjState
#endif
1$:           rep     #0x20
9$:           rtl

;;; ---------------------------------------------------------------------------
;;; boolean P_SetMobjState(mobj_t __far* mobj, statenum_t state)
;;; In: _Dp[0-3] = mobj, C = state. Out: C.
;;; DBR = the bank of the mobj and Y = the mobj (abs,Y), X = 16 * the
;;; state (long,X in the states); the writes are bytes (the high byte of
;;; a sprite is 0). Action functions can call P_SetMobjState again, so
;;; the mobj stays on the stack while an action runs.
;;; ---------------------------------------------------------------------------
              .public P_SetMobjState
P_SetMobjState:
              phb
              ldy     dp:.tiny _Dp
              tax
              sep     #0x20
              lda     dp:.tiny (_Dp+2)
              pha
              plb
              rep     #0x20
              txa

loopState:    bne     1$                    ; (C = the state)
              ;; S_NULL: mobj->state = NULL, P_RemoveMobj(mobj), false
              sep     #0x20
              sta     abs:OFS_MO_STATE,y
              sta     abs:(OFS_MO_STATE+1),y
              sta     abs:(OFS_MO_STATE+2),y
              phb
              rep     #0x20
              tya
              sep     #0x20
              sta     dp:.tiny _Dp
              xba
              sta     dp:.tiny (_Dp+1)
              pla
              sta     dp:.tiny (_Dp+2)
              stz     dp:.tiny (_Dp+3)
              plb                           ; (the bank of the caller)
              rep     #0x20
              jsl     long:P_RemoveMobj
              lda     ##0
              rtl

1$:           asl     a                     ; X = 16 * the state
              asl     a
              asl     a
              asl     a
              tax
              clc                           ; mobj->state = &states[state]
              adc     ##.near states
              sep     #0x20
              sta     abs:OFS_MO_STATE,y
              lda     #.byte2 states
              sta     abs:(OFS_MO_STATE+2),y
              xba
              sta     abs:(OFS_MO_STATE+1),y
              lda     long:(states+OFS_ST_TICS),x   ; mobj->tics = st->tics
              sta     abs:OFS_MO_TICS,y
              lda     long:(states+OFS_ST_TICS+1),x
              sta     abs:(OFS_MO_TICS+1),y
              lda     long:(states+OFS_ST_SPRITE),x ; mobj->sprite = st->sprite
              sta     abs:OFS_MO_SPRITE,y
              lda     long:(states+OFS_ST_FRAME),x  ; mobj->frame = st->frame
              sta     abs:OFS_MO_FRAME,y
              lda     long:(states+OFS_ST_FRAME+1),x
              sta     abs:(OFS_MO_FRAME+1),y

              lda     long:(states+OFS_ST_ACTION+2),x ; if (st->action)
              bne     2$
              rep     #0x20
              lda     long:(states+OFS_ST_ACTION),x
              beq     smNext
              sep     #0x20
              lda     #0
2$:           sta     dp:.tiny (FN_P+2)
              lda     long:(states+OFS_ST_ACTION),x
              sta     dp:.tiny FN_P
              lda     long:(states+OFS_ST_ACTION+1),x
              sta     dp:.tiny (FN_P+1)
              lda     long:(_g_player+OFS_PL_CHEATS)
              and     #CONST_CF_ENEMY_ROCKETS
              beq     smCall
              jsr     .kbank rocketCheat    ; may change FN_P to A_CyberAttack

smCall:       phb                           ; keep the mobj (its bank, then Y)
              rep     #0x20
              tya                           ; _Dp = the mobj
              sep     #0x20
              sta     dp:.tiny _Dp
              xba
              pha
              sta     dp:.tiny (_Dp+1)
              xba
              pha
              lda     3,s
              sta     dp:.tiny (_Dp+2)
              stz     dp:.tiny (_Dp+3)
              NEARDBR
              rep     #0x20
              CALLFN
              sep     #0x20
              pla                           ; Y = the mobj, DBR = its bank
              xba
              pla
              xba
              rep     #0x20
              tay
              plb

smNext:       lda     abs:OFS_MO_TICS,y     ; while (!mobj->tics)
              bne     3$
              lda     abs:OFS_MO_STATE,y    ; state = st->nextstate: no mobj
              sec                           ;   state has 0 tics, so no call
              sbc     ##.near states        ;   set it: st is the state of
              tax                           ;   the mobj
              lda     long:(states+OFS_ST_NEXTSTATE),x
              brl     loopState
3$:           plb                           ; (the bank of the caller)
              lda     ##1
              rtl

;;; rocketCheat: with CF_ENEMY_ROCKETS, a state in
;;; [mobjinfo[type].missilestate, painstate) calls A_CyberAttack instead.
;;; X = 16 * the state, Y = the mobj (DBR = its bank), 8-bit A.
rocketCheat:  rep     #0x20
              phx                           ; (the cheat only)
              txa                           ; the state
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              pha
              lda     abs:OFS_MO_TYPE,y
              INFOINDEX
              tax
              lda     long:(mobjinfo+OFS_MI_MISSILESTATE),x
              beq     9$
              lda     1,s                   ; state >= missilestate (signed enums)
              sec
              sbc     long:(mobjinfo+OFS_MI_MISSILESTATE),x
              bvc     1$
              eor     ##0x8000
1$:           bmi     9$
              lda     1,s                   ; state < painstate
              sec
              sbc     long:(mobjinfo+OFS_MI_PAINSTATE),x
              bvc     2$
              eor     ##0x8000
2$:           bpl     9$
              lda     ##.word0 A_CyberAttack
              sta     dp:.tiny FN_P
              lda     ##.word2 A_CyberAttack
              sta     dp:.tiny (FN_P+2)
9$:           pla
              plx
              sep     #0x20
              rts

#if TICSTEP > 1
;;; The cold rocketCheat comes before quietState and merge: it takes the
;;; cache slots of P_Random (src/iigs/m_random65.s), which the monsters
;;; call often; the hot code of P_SetMobjState ends before them.

;;; quietState: the state of the mobj _Dp becomes SM_LAST as
;;; P_SetMobjState sets it, but without its action (the action of the
;;; first merged state did its work), and TS_LEFT = SM_LEFT. The state
;;; stays in the bank of the states. Byte stores, a load before each.
;;; 16-bit A, DBR = the near bank.
quietState:   ldx     .near SM_LAST         ; X = the state
              sep     #0x20
              lda     .near SM_LEFT
              ldy     ##OFS_MO_STATE        ; mobj->state = the state
              sta     .near TS_LEFT
              txa
              sta     [.tiny _Dp],y
              iny
              lda     .near (SM_LAST+1)
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_TICS         ; mobj->tics = st->tics
              lda     abs:OFS_ST_TICS,x
              sta     [.tiny _Dp],y
              iny
              lda     abs:(OFS_ST_TICS+1),x
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_SPRITE       ; mobj->sprite = st->sprite (its
              lda     abs:OFS_ST_SPRITE,x   ;   high byte is 0)
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_FRAME        ; mobj->frame = st->frame
              lda     abs:OFS_ST_FRAME,x
              sta     [.tiny _Dp],y
              iny
              lda     abs:(OFS_ST_FRAME+1),x
              sta     [.tiny _Dp],y
              rep     #0x20
              rts

;;; merge: the next state S1 = mobj->state->nextstate of the mobj _Dp
;;; begins with TS_LEFT tics of the run left. When its action is A_Chase
;;; (or A_Look, TICSTEP > 10) and the next states with the same action
;;; begin in the tics left too, one call of the action does the work of
;;; all of them (k states): carry set, SM_FIRST = S1 and SM_LAST = the last
;;; of them, SM_LEFT = the tics left when it begins; for A_Chase chaseX =
;;; k - 1 (A_Chase takes k steps). Else carry clear. A state begins in the
;;; run when the tics of the state before it fit in the tics left (-1:
;;; never). 16-bit A, DBR = the near bank.
merge:        ldy     ##OFS_MO_STATE        ; X = S1 (near addresses)
              lda     [.tiny _Dp],y
              tax
              lda     abs:OFS_ST_NEXTSTATE,x
              STATEADDR
              tax
              lda     abs:OFS_ST_ACTION,x   ; an action that merges
              cmp     ##.word0 A_Chase
              beq     1$
#if TICSTEP > 10
              cmp     ##.word0 A_Look
              beq     2$
#endif
              clc
              rts
1$:           lda     abs:(OFS_ST_ACTION+2),x ; (and its bank)
              cmp     ##.word2 A_Chase
              beq     3$
              clc
              rts
#if TICSTEP > 10
2$:           lda     abs:(OFS_ST_ACTION+2),x
              cmp     ##.word2 A_Look
              beq     3$
              clc
              rts
#endif
3$:           sep     #0x20                 ; A = the tics left when the
              lda     .near TS_LEFT         ;   state X begins
4$:           sec                           ; the next state begins in the run?
              sbc     abs:OFS_ST_TICS,x
              bcc     7$
              pha                           ; (the tics left then)
              rep     #0x20
              lda     abs:OFS_ST_NEXTSTATE,x ; Y = the next state
              STATEADDR
              tay
              lda     abs:OFS_ST_ACTION,y   ; the same action: it merges
              cmp     abs:OFS_ST_ACTION,x
              bne     6$
              lda     abs:(OFS_ST_ACTION+2),y
              cmp     abs:(OFS_ST_ACTION+2),x
              bne     6$
              tyx
              sep     #0x20
              inc     .near chaseX          ; (k - 1)
              pla
              bra     4$
6$:           sep     #0x20
              pla
7$:           clc                           ; X is the last state: the tics
              adc     abs:OFS_ST_TICS,x     ;   left when it begins
              ldy     .near chaseX
              beq     9$                    ; S1 alone: no merge
              sta     .near SM_LEFT
              rep     #0x20                 ; SM_LAST = X, SM_FIRST = S1 (bytes)
              txa
              sep     #0x20
              sta     .near SM_LAST
              xba
              ldy     ##OFS_MO_STATE
              sta     .near (SM_LAST+1)
              rep     #0x20
              lda     [.tiny _Dp],y
              tax
              lda     abs:OFS_ST_NEXTSTATE,x
              STATEADDR
              tax
              sep     #0x20
              sta     .near SM_FIRST
              xba
              sta     .near (SM_FIRST+1)
#if TICSTEP > 10
              rep     #0x20                 ; A_Look takes no steps
              lda     abs:OFS_ST_ACTION,x
              cmp     ##.word0 A_Look
              sep     #0x20
              bne     8$
              stz     .near chaseX
8$:
#endif
              rep     #0x20
              sec
              rts
9$:           rep     #0x20
              clc
              rts

#endif
