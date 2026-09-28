;;; The thinker list in 65816 assembly.
;;;
;;; P_InitThinkers, P_AddThinker, P_RemoveThinker, P_RemoveThing and their
;;; delayed removers, P_NextThinker and P_Ticker of p_tick.c, with
;;; the same results. P_RunThinkers is in src/iigs/p_tick65.s.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "tics.inc"

              .extern _Dp, _g_player, _g_menuactive, _g_gameaction
              .extern _g_demoplayback, _g_gamestate
              .extern Z_Free, P_PlayerThink, P_RunThinkers, P_UpdateSpecials
              .extern poolFree
              .extern P_MapEnd
#if TICSTEP > 1
              .extern P_MobjThinker, ticRun
#endif

CAP           .equ    _g_thinkerclasscap

;;; ---------------------------------------------------------------------------
;;; void P_InitThinkers(void): an empty list.
;;; ---------------------------------------------------------------------------
              .section logiccode, text
              .public P_InitThinkers
P_InitThinkers:
              lda     ##.near CAP
              sta     .near (CAP+OFS_TH_PREV)
              sta     .near (CAP+OFS_TH_NEXT)
              lda     ##.word2 CAP
              sta     .near (CAP+OFS_TH_PREV+2)
              sta     .near (CAP+OFS_TH_NEXT+2)
              rtl

;;; ---------------------------------------------------------------------------
;;; void P_AddThinker(thinker_t __far* thinker): at the end of the list.
;;; ---------------------------------------------------------------------------
              .public P_AddThinker
P_AddThinker: lda     .near (CAP+OFS_TH_PREV) ; cap.prev->next = thinker
              sta     dp:.tiny (_Dp+4)
              lda     .near (CAP+OFS_TH_PREV+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_TH_NEXT
              lda     dp:.tiny _Dp
              sta     [.tiny (_Dp+4)],y
              iny
              iny
              lda     dp:.tiny (_Dp+2)
              sta     [.tiny (_Dp+4)],y
              ldy     ##OFS_TH_NEXT         ; thinker->next = &cap
              lda     ##.near CAP
              sta     [.tiny _Dp],y
              iny
              iny
              lda     ##.word2 CAP
              sta     [.tiny _Dp],y
              ldy     ##OFS_TH_PREV         ; thinker->prev = cap.prev
              lda     dp:.tiny (_Dp+4)
              sta     [.tiny _Dp],y
              iny
              iny
              lda     dp:.tiny (_Dp+6)
              sta     [.tiny _Dp],y
              lda     dp:.tiny _Dp          ; cap.prev = thinker
              sta     .near (CAP+OFS_TH_PREV)
              lda     dp:.tiny (_Dp+2)
              sta     .near (CAP+OFS_TH_PREV+2)
              rtl

;;; ---------------------------------------------------------------------------
;;; void P_RemoveThinker(thinker_t __far* thinker)
;;; void P_RemoveThing(mobj_t __far* thing)
;;; The removal is late: the function becomes a remover that runs in the
;;; turn of the thinker.
;;; ---------------------------------------------------------------------------
              .public P_RemoveThinker, P_RemoveThing
P_RemoveThinker:
              lda     ##.word0 P_RemoveThinkerDelayed
              ldx     ##.word2 P_RemoveThinkerDelayed
              bra     setFunction
P_RemoveThing:
              lda     ##.word0 P_RemoveThingDelayed
              ldx     ##.word2 P_RemoveThingDelayed
setFunction:  ldy     ##OFS_TH_FUNCTION
              sta     [.tiny _Dp],y
              iny
              iny
              txa
              sta     [.tiny _Dp],y
              rtl

;;; P_RemoveThinkerDelayed(thinker), P_RemoveThingDelayed(thinker): out of
;;; the list, then freed; a thing of the pool gets type MT_NOTHING instead,
;;; and its bit in TP_BITS (poolFree of src/iigs/p_spawn65.s).
              .public P_RemoveThinkerDelayed, P_RemoveThingDelayed
P_RemoveThinkerDelayed:
              jsr     .kbank unlink
              jmp     long:Z_Free
P_RemoveThingDelayed:
              jsr     .kbank unlink
              ldy     ##(OFS_MO_FLAGS+2)
              lda     [.tiny _Dp],y
              and     ##CONST_MF_POOLED_HI
              bne     1$
              jmp     long:Z_Free
1$:           lda     ##CONST_MT_NOTHING
              ldy     ##OFS_MO_TYPE
              sta     [.tiny _Dp],y
              jmp     long:poolFree
              .space  11                    ; (the fragment keeps its size)

;;; unlink: (next->prev = thinker->prev)->next = next, thinker at _Dp[0-3].
unlink:       ldy     ##OFS_TH_NEXT         ; next
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_TH_PREV         ; next->prev = thinker->prev
              lda     [.tiny _Dp],y
              sta     [.tiny (_Dp+4)],y
              tax
              iny
              iny
              lda     [.tiny _Dp],y
              sta     [.tiny (_Dp+4)],y
              pei     dp:.tiny _Dp          ; prev->next = next
              pei     dp:.tiny (_Dp+2)
              sta     dp:.tiny (_Dp+2)
              stx     dp:.tiny _Dp
              ldy     ##OFS_TH_NEXT
              lda     dp:.tiny (_Dp+4)
              sta     [.tiny _Dp],y
              iny
              iny
              lda     dp:.tiny (_Dp+6)
              sta     [.tiny _Dp],y
              pla
              sta     dp:.tiny (_Dp+2)
              pla
              sta     dp:.tiny _Dp
              rts

;;; ---------------------------------------------------------------------------
;;; thinker_t __far* P_NextThinker(thinker_t __far* th)
;;; The thinker after th (the first one for NULL), NULL after the last.
;;; ---------------------------------------------------------------------------
              .public P_NextThinker
P_NextThinker:
              lda     dp:.tiny _Dp          ; NULL: the list head
              ora     dp:.tiny (_Dp+2)
              bne     1$
              lda     ##.near CAP
              sta     dp:.tiny _Dp
              lda     ##.word2 CAP
              sta     dp:.tiny (_Dp+2)
1$:           ldy     ##(OFS_TH_NEXT+2)     ; th->next
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_TH_NEXT
              lda     [.tiny _Dp],y
              cmp     ##.near CAP           ; the head: NULL
              bne     9$
              cpx     ##.word2 CAP
              bne     9$
              lda     ##0
              tax
9$:           rtl

;;; ---------------------------------------------------------------------------
;;; void P_Ticker(void): one game tic of the level. With TICSTEP > 1 only
;;; the player and his mobj: the world runs in P_WorldRuns.
;;; The tic runs on its own stack, LOGIC_SP down: the top of the frame
;;; stack is in the cache slots of the logic code ($2000-$3FFF), the
;;; slots $1A1A-$1B6F hold only cold code (src/iigs/iigs.scm). The
;;; frame stack never goes that deep.
;;; ---------------------------------------------------------------------------
LOGIC_SP      .equ    0x1b6f

              .public P_Ticker
P_Ticker:     lda     .near _g_menuactive   ; paused in the menu, after a tic
              beq     1$
              lda     .near _g_demoplayback
              bne     1$
              lda     .near (_g_player+OFS_PL_VIEWZ)
              cmp     ##1
              bne     9$
              lda     .near (_g_player+OFS_PL_VIEWZ+2)
              bne     9$
1$:           tsc                           ; the stack of the tic
              sta     .near PT_SP
              lda     ##LOGIC_SP
              tcs
              lda     .near _g_gamestate    ; not in the intermission
              cmp     ##CONST_GS_LEVEL
              bne     2$
              lda     ##.near _g_player
              sta     dp:.tiny _Dp
              lda     ##.word2 _g_player
              sta     dp:.tiny (_Dp+2)
              jsl     long:P_PlayerThink
#if TICSTEP > 1
              jsr     .kbank playerMobj     ; the tic of his mobj
2$:
#else
2$:           jsl     long:P_RunThinkers
              jsl     long:P_UpdateSpecials
#endif
              jsl     long:P_MapEnd
              lda     .near PT_SP           ; the frame stack again
              tcs
              inc     .near _g_leveltime    ; leveltime++
              bne     9$
              inc     .near (_g_leveltime+2)
9$:           rtl

#if TICSTEP > 1
;;; ---------------------------------------------------------------------------
;;; void P_WorldRuns(int16_t tics)      In: C = the tics the player runs next.
;;; One world run for those tics: the steps of TICSTEP tics from worldAt
;;; that the tics need, in one call of the thinkers (P_RunThinkers leaves
;;; out the mobj of the player, ticRun = the tics of the steps) and of
;;; P_UpdateSpecials, on the stack of the tics; worldTic is the first tic
;;; of the run. A worldAt far from leveltime (a new level, a
;;; loaded game) starts again at leveltime. None outside a level (the
;;; state is also GS_LEVEL at the start, before a level: then the player
;;; has no mobj), before a game action (a new level) or while the menu
;;; pauses the game (as P_Ticker).
;;; ---------------------------------------------------------------------------
              .public P_WorldRuns
P_WorldRuns:  tay                           ; Y = the tics of the player
              lda     .near _g_gamestate
              cmp     ##CONST_GS_LEVEL
              bne     9$
              lda     .near _g_gameaction
              bne     9$
              lda     .near (_g_player+OFS_PL_MO)
              ora     .near (_g_player+OFS_PL_MO+2)
              beq     9$
              lda     .near _g_menuactive
              beq     1$
              lda     .near _g_demoplayback
              bne     1$
              lda     .near (_g_player+OFS_PL_VIEWZ)
              cmp     ##1
              bne     9$
              lda     .near (_g_player+OFS_PL_VIEWZ+2)
              beq     1$
9$:           rtl
1$:           lda     .near worldAt         ; d = worldAt - leveltime in
              sec                           ;   -(MAXTICS + TICSTEP)..TICSTEP:
              sbc     .near _g_leveltime    ;   in step
              bmi     2$
              cmp     ##(TICSTEP + 1)
              bcc     3$
              bra     4$
2$:           cmp     ##(0x10000 - MAXTICS - TICSTEP)
              bcs     3$
4$:           lda     .near _g_leveltime
              sta     .near worldAt
3$:           ldx     ##0                   ; X = the tics of the run
              tya                           ; C = leveltime + tics - worldAt,
              clc                           ;   the tics that the world is
              adc     .near _g_leveltime    ;   behind
              sec
              sbc     .near worldAt
5$:           beq     6$                    ; steps of TICSTEP tics while C > 0
              bmi     6$
              sec
              sbc     ##TICSTEP
              tay
              txa
              clc
              adc     ##TICSTEP
              tax
              tya
              bra     5$
6$:           txa
              beq     9$
              sep     #0x20                 ; a byte: the high byte of ticRun
              sta     .near ticRun          ;   stays 0
              rep     #0x20
              lda     .near worldAt
              sta     .near worldTic        ; the first tic of the run
              txa                           ; the next run starts after it
              clc
              adc     .near worldTic
              sta     .near worldAt
              tsc                           ; the stack of the tics
              sta     .near PT_SP
              lda     ##LOGIC_SP
              tcs
              jsl     long:P_RunThinkers
              jsl     long:P_UpdateSpecials
              jsl     long:P_MapEnd
              lda     .near PT_SP
              tcs
              rtl

;;; playerMobj: P_MobjThinker(player->mo) for one tic (ticRun = 1), when
;;; the player has a mobj.
playerMobj:   sep     #0x20                 ; ticRun = 1, a byte
              lda     #1
              sta     .near ticRun
              rep     #0x20
              lda     .near (_g_player+OFS_PL_MO)
              sta     dp:.tiny _Dp
              lda     .near (_g_player+OFS_PL_MO+2)
              sta     dp:.tiny (_Dp+2)
              ora     dp:.tiny _Dp
              beq     9$
              ldy     ##OFS_TH_FUNCTION     ; (not removed)
              lda     [.tiny _Dp],y
              cmp     ##.word0 P_MobjThinker
              bne     9$
              jsl     long:P_MobjThinker
9$:           rts
#endif

              .section znear, bss
              .public _g_leveltime, _g_thinkerclasscap
_g_leveltime: .space  4               ; the tics of the level
_g_thinkerclasscap: .space SIZEOF_TH  ; the head of the thinker list
PT_SP:        .space  2               ; the frame stack of P_Ticker
#if TICSTEP > 1
worldAt:      .space  2               ; the first tic of the next world run
              .public worldTic
worldTic:     .space  2               ; the first tic of this world run
#endif
