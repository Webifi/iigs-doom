;;; The world tic (make TICSTEP=N, default 1). The player runs each tic
;;; of 1/35 s, with the keys of that tic, as in Doom; the world (the other
;;; thinkers, the specials) runs in steps of TICSTEP tics. A frame does the
;;; steps that its tics need in one world run (src/iigs/p_think65.s), and
;;; each thinker does the tics of the run in one call: the states of a mobj
;;; run their actions at the tics of Doom, moves and heights take one step
;;; for each tic, and timers count the tics of the run, so monsters and
;;; doors keep the pace of Doom. With TICSTEP = 1 the game is Doom's, and
;;; the demos play as recorded only then.
#ifndef TICSTEP
#define TICSTEP 1
#endif

;;; MAXTICS: a frame runs at most MAXTICS tics of the game; when the frame
;;; takes longer, the game gets slower. The ring of tic commands
;;; (src/iigs/g_game65.s) holds 8 commands, 16 for MAXTICS > 7.
#ifndef MAXTICS
#if TICSTEP > 1
#define MAXTICS 8
#else
#define MAXTICS 4
#endif
#endif
#if MAXTICS < 1 || MAXTICS > 15
#error "MAXTICS: 1 to 15 tics"
#endif

;;; Carry clear if one of the tics of this world run (worldTic ..
;;; worldTic + ticRun - 1, src/iigs/p_think65.s) is a multiple of mask + 1,
;;; the tic of "(leveltime & mask) == 0" in Doom. The file declares
;;; worldTic and ticRun extern.
TICHIT        .macro  mask
              lda     .near worldTic
              clc
              adc     .near ticRun
              dec     a
              and     ##\mask
              cmp     .near ticRun
              .endm

;;; Call fn (a routine that returns with rtl and keeps _Dp[0-3]) ticRun
;;; times (the tics of the world run). 16-bit A.
TICLOOP       .macro  fn
              lda     .near ticRun
1$:           pha
              jsl     long:\fn
              pla
              dec     a
              bne     1$
              .endm
