;;; Main loop and display.
;;; The command-line timedemo runs one tic per frame; normal play and the
;;; menu benchmark run tics from the DOC clock. Static screens track menu
;;; and skull versions so an idle menu does not repaint the whole screen.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "viewwin.inc"
#include "tics.inc"
#include "wpage.inc"

              .extern _Dp, printf, FixedApproxDiv, IIGS_MulLo16
              .extern W_NextDemo
              .extern I_GetTime, I_StartTic, I_InitKeyboard, IIGS_InitDocTimer, I_InitSound
#if TICSTEP > 1
              .extern I_StartTicUntil, P_WorldRuns
#endif
              .extern IIGS_StartInterrupts
              .extern I_InitSound2, I_InitGraphics, I_SetPalette, I_FinishUpdate
              .extern I_SaveView, I_RestoreView, I_RestoreBackRect, I_ShowDirty
              .extern I_ApplyColors, iigs_textShown
              .extern R_DrawLists, viewbottom, am_valid, am_band, R_FillStamps
              .extern messageToPrint
              .extern I_ViewPalette, I_MessageStrip, message_on, message_new, viewtop
              .extern vwFrame, uiDisplay
              .public displayCall, display, menuDisplayNear, onlyTics
              .public uiStaticCheck, uiStaticDrawn, singletics
              .extern D_Wipe
              .extern Z_Init, W_Init, W_GetNumForName, V_DrawRawFullScreen
              .extern G_BuildTiccmd, G_Ticker, G_Responder, G_DeferedPlayDemo, iigs_newframe
              .extern G_ReloadDefaults
              .extern M_Ticker, M_Responder, M_Drawer, M_Init, M_DrawVersion
              .extern M_SkullVersion, M_SkullRect, M_DrawSkull
              .extern C_Responder, AM_Responder, AM_Drawer, WI_Drawer, WI_Init
              .extern F_Drawer, F_Init, ST_doPaletteStuff, ST_Drawer, ST_Init
              .extern HU_Drawer, HU_Init, R_RenderPlayerView, R_Init, P_Init, S_Init
              .extern S_UpdateSounds, snd_SfxVolume, snd_MusicVolume
              .extern musFrame
              .extern uiLoadSettings
              .extern _g_gametic, _g_basetic, _g_gamestate, _g_gameaction, _g_player
              .extern automapmode, _g_menuactive, _g_demoplayback, _g_usergame
              .extern _g_timingdemo, _g_singledemo
#if defined IIGS_PHASES
              .extern iigs_phase
#endif

PL            .equ    _g_player
AM_ACTIVE     .equ    1               ; automapmode, am_map.h
AMAP_PAL      .equ    11              ; i_viigs65.s: AMAP_PAL.
STRIP_ROWS    .equ    10              ; i_viigs65.s: STRIP_ROWS.
AM_OVERLAY    .equ    2
AM_TITLEY     .equ    (CONST_VIEWHEIGHT - 1 - 7) ; hu_stuff65.s: HU_TITLEY.

#if defined IIGS_PHASES
PHASE         .macro  n
              lda     ##\n
              sta     .near iigs_phase
              .endm
#else
PHASE         .macro  n
              .endm
#endif

              .section cnear, rodata
              .public nomusicparm, nodrawers
nomusicparm:  .word   1               ; no music
nodrawers:    .word   0

              .section near, data
              .public wipegamestate
wipegamestate: .word  CONST_GS_DEMOSCREEN ; -1 forces a wipe

              .section znear, bss
              .public nosfxparm, _g_fps_show, _g_fps_framerate
nosfxparm:    .space  2
_g_fps_show:  .space  2
_g_fps_framerate: .space 2
              .public maketic
maketic:      .space  4               ; the tic commands made
lastmadetic:  .space  4
pagetic:      .space  2               ; the tics of the title page
singletics:   .space  2               ; One tic per frame (-timedemo).
advancedemo:  .space  2
titlepicnum:  .space  2
demosequence: .space  2
timedemo:     .space  4               ; the demo of a timedemo (0: none)
oldgamestate: .space  2               ; D_Display
pagedrawn:    .space  2
viewsaved:    .space  2
DD_WIPE:      .space  2
DD_VIEW:      .space  2               ; the view is shown
DD_PAUSED:    .space  2               ; the menu pauses the 3D view
screenmenuversion: .space 2           ; a static screen: the menu of the
screenskullversion: .space 2          ;   screen, its skull
skullshown:   .space  2
              .public skx, sky, skw, skh    ; (M_SkullRect)
skx:          .space  2
sky:          .space  2
skw:          .space  2
skh:          .space  2
SS_OLDSHOWN:  .space  2
SS_OLDY:      .space  2
SS_OLDH:      .space  2
DE_EV:        .space  4               ; D_PostEvent: the event
TR_ENTER:     .space  4               ; TryRunTics: the time at the start
TR_RUN:       .space  2               ;   the tics to run
NT_NEW:       .space  2               ; D_BuildNewTiccmds: the new tics
#if TICSTEP > 1
NT_TIC:       .space  2               ;   the tic of the next command
#endif
fps_frames:   .space  4
fps_timebefore: .space 4
FP_NOW:       .space  4
FP_T:         .space  4

              .section cfar, rodata
strTitlepic:  .asciz  "TITLEPIC"
strDemo3:     .asciz  "demo3"
msgZ:         .asciz  "Z_Init: Init zone memory allocation daemon.\n"
msgW:         .asciz  "W_Init: Init WADfiles.\n"
msgM:         .asciz  "M_Init: Init miscellaneous info.\n"
msgR:         .asciz  "R_Init: DOOM refresh daemon - [...................]\n"
msgP:         .asciz  "P_Init: Init Playloop state.\n"
msgHU:        .asciz  "HU_Init: Setting up heads up display.\n"
msgST:        .asciz  "ST_Init: Init status bar.\n"

;;; ---------------------------------------------------------------------------
;;; void D_DoomMain(const char* timedemo)
;;;   In: _Dp[0-3] = the demo of a timedemo (0: none). The setup, then the
;;;   loop (no return).
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public D_DoomMain
D_DoomMain:   lda     dp:.tiny _Dp
              sta     .near timedemo
              lda     dp:.tiny (_Dp+2)
              sta     .near (timedemo+2)
              jsl     long:I_InitKeyboard   ; the subsystems
              jsl     long:IIGS_InitDocTimer
              jsl     long:IIGS_StartInterrupts
              jsl     long:I_InitSound
              ldx     ##.word0 msgZ
              lda     ##.word2 msgZ
              jsr     .kbank print
              jsl     long:Z_Init
              jsl     long:G_ReloadDefaults
              ldx     ##.word0 msgW
              lda     ##.word2 msgW
              jsr     .kbank print
              jsl     long:W_Init
              jsl     long:I_InitSound2
              lda     ##.word0 strTitlepic  ; D_Init
              sta     dp:.tiny _Dp
              lda     ##.word2 strTitlepic
              sta     dp:.tiny (_Dp+2)
              jsl     long:W_GetNumForName
              sta     .near titlepicnum
              jsl     long:F_Init
              jsl     long:WI_Init
              ldx     ##.word0 msgM
              lda     ##.word2 msgM
              jsr     .kbank print
              jsl     long:M_Init
              ldx     ##.word0 msgR
              lda     ##.word2 msgR
              jsr     .kbank print
              jsl     long:R_Init
              ldx     ##.word0 msgP
              lda     ##.word2 msgP
              jsr     .kbank print
              jsl     long:P_Init
              lda     .near snd_MusicVolume ; S_Init(sfx volume, music volume)
              sta     dp:.tiny _Dp
              lda     .near snd_SfxVolume
              jsl     long:S_Init
              ldx     ##.word0 msgHU
              lda     ##.word2 msgHU
              jsr     .kbank print
              jsl     long:HU_Init
              ldx     ##.word0 msgST
              lda     ##.word2 msgST
              jsr     .kbank print
              jsl     long:ST_Init
              jsl     long:uiLoadSettings  ; Settings and the view selector.
              stz     .near _g_fps_show
              jsl     long:I_InitGraphics
              lda     .near timedemo        ; a timedemo: that demo, one tic
              ora     .near (timedemo+2)    ;   for each frame, then quit
              beq     1$
              lda     .near timedemo
              sta     dp:.tiny _Dp
              lda     .near (timedemo+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##1
              sta     .near singletics
              sta     .near _g_timingdemo
              jsl     long:G_DeferedPlayDemo
              lda     ##1
              sta     .near _g_singledemo
              brl     doomLoop
1$:           jsl     long:D_StartTitle     ; else the title and demo loop
              brl     doomLoop

;;; print: printf(the string at X (its low word) in bank C).
print:        stx     dp:.tiny _Dp
              sta     dp:.tiny (_Dp+2)
              jsl     long:printf
              rts

;;; doomLoop: D_DoomLoop: the tics (one, or as many as the time asks for),
;;; the positional sounds, the frame; the frame rate if it is shown. With
;;; TICSTEP > 1 the world runs of the tics come first (P_WorldRuns).
doomLoop:     PHASE   1
              lda     .near singletics
              beq     2$
              jsl     long:I_StartTic
              jsl     long:G_BuildTiccmd
#if TICSTEP > 1
              lda     ##1
              jsl     long:P_WorldRuns
#endif
              jsr     .kbank runTic
              inc     .near maketic
              bne     3$
              inc     .near (maketic+2)
              bra     3$
2$:           jsr     .kbank tryRunTics
3$:           PHASE   8
              jsl     long:musFrame         ; a part of a song's load, the
              bra     4$                    ;   positional sounds
              .space  6                     ; (the size of the old code: no
4$:                                           ;   code of the game moves)
displayCall:  jsr     .kbank display
              lda     ##1
              sta     .near iigs_newframe
              lda     .near _g_fps_show
              beq     doomLoop
              jsr     .kbank updateFPS
              bra     doomLoop

;;; runTic: the demo sequence if it advances, M_Ticker, G_Ticker, the tic.
runTic:       lda     .near advancedemo
              beq     1$
              jsr     .kbank doAdvanceDemo
1$:           jsl     long:M_Ticker
              jsl     long:G_Ticker
              inc     .near _g_gametic
              bne     2$
              inc     .near (_g_gametic+2)
2$:           rts

;;; tryRunTics: TryRunTics: the new tic commands; none yet: again, but
;;; after 10 tics only M_Ticker; else the tics of the commands. The menu
;;; stops every game state: then only M_Ticker for
;;; each new tic, and the commands go (a demo has its own), so the menu is
;;; quick on a slow machine and the demo goes on as it was. With TICSTEP >
;;; 1 the world runs of the tics come first, then the tic commands of the
;;; time they took: the tics of the player come last, with the newest keys.
tryRunTics:   jsl     long:I_GetTime
              sta     .near TR_ENTER
              stx     .near (TR_ENTER+2)
1$:           jsr     .kbank buildNewTiccmds
              lda     .near _g_menuactive
              beq     12$
              bra     15$                 ; Every menu pauses its screen.
              .space  11
15$:          lda     .near maketic         ; the new tics: M_Ticker
              sec
              sbc     .near _g_gametic
              beq     14$
              sta     .near TR_RUN
13$:          jsl     long:M_Ticker
              dec     .near TR_RUN
              bne     13$
              lda     .near _g_gametic
              sta     .near maketic
              lda     .near (_g_gametic+2)
              sta     .near (maketic+2)
14$:          rts
12$:          lda     .near maketic         ; runtics = maketic - gametic
              sec
              sbc     .near _g_gametic
              sta     .near TR_RUN          ; runtics > 0: run them
              beq     11$
              bpl     3$
11$:
              jsl     long:I_GetTime        ; (int16) (now - enter) > 10:
              sec                           ;   M_Ticker only
              sbc     .near TR_ENTER
              sta     .near FP_NOW
              lda     ##10
              sec
              sbc     .near FP_NOW
              bvc     2$
              eor     ##0x8000
2$:           bpl     1$
              jsl     long:M_Ticker
              rts
#if TICSTEP > 1
3$:           lda     .near TR_RUN
              jsl     long:P_WorldRuns
              jsr     .kbank buildNewTiccmds
              lda     .near maketic
              sec
              sbc     .near _g_gametic
              sta     .near TR_RUN
31$:          jsr     .kbank runTic
              dec     .near TR_RUN
              bne     31$
              rts
#else
3$:           jsr     .kbank runTic
              dec     .near TR_RUN
              bne     3$
              rts
#endif

;;; buildNewTiccmds: D_BuildNewTiccmds: a tic command for each new tic of
;;; the time, while maketic - gametic <= MAXTICS - 1, so at most MAXTICS
;;; ahead of the game (src/iigs/tics.inc). The
;;; key events of I_StartTic come only with a tic command, so a short key
;;; press reaches one of them. With TICSTEP > 1 each key byte has its tic
;;; (src/iigs/iigs_asm.s): the command of a tic gets the keys of that tic.
buildNewTiccmds:
              jsl     long:I_GetTime        ; newtics = now - lastmadetic
#if TICSTEP > 1
              ldx     .near lastmadetic     ; (the tic of the first command)
              stx     .near NT_TIC
#endif
              sec
              sbc     .near lastmadetic
              sta     .near NT_NEW
              ldx     ##0                   ; lastmadetic += newtics
              cmp     ##0
              bpl     1$
              dex
1$:           clc
              adc     .near lastmadetic
              sta     .near lastmadetic
              txa
              adc     .near (lastmadetic+2)
              sta     .near (lastmadetic+2)
2$:           lda     .near NT_NEW          ; while (newtics--)
              beq     4$
              dec     .near NT_NEW
              lda     .near maketic         ; (int16) (maketic - gametic) >
              sec                           ;   MAXTICS - 1: enough
              sbc     .near _g_gametic
              sta     .near FP_NOW
              lda     ##(MAXTICS - 1)
              sec
              sbc     .near FP_NOW
              bvc     3$
              eor     ##0x8000
3$:           bmi     4$
#if TICSTEP > 1
              lda     .near NT_TIC          ; the keys up to its tic
              inc     .near NT_TIC
              jsl     long:I_StartTicUntil
#else
              jsl     long:I_StartTic
#endif
              jsl     long:G_BuildTiccmd
              inc     .near maketic
              bne     2$
              inc     .near (maketic+2)
              bra     2$
4$:           rts

;;; ---------------------------------------------------------------------------
;;; display: D_Display: the screen of the game state (intermission, finale,
;;; title page, or the level: view, automap, status bar, messages), the
;;; menu, the new tic commands, then the screen shows (or a wipe).
;;; ---------------------------------------------------------------------------
display:      sep     #0x20                 ; WPAGE flags are bytes (lists.inc).
              lda     long:(WPAGE+W_FSG)    ; Old fills require a visible view.
              sta     long:(WPAGE+W_FSW)
              lda     #0
              sta     long:(WPAGE+W_FSG)
              rep     #0x20
              lda     .near _g_gamestate    ; wipe = gamestate != wipegamestate
              stz     .near DD_WIPE
              cmp     .near wipegamestate
              beq     1$
              inc     .near DD_WIPE
1$:           lda     .near _g_gamestate
              beq     level
              lda     .near oldgamestate    ; not a level
              bne     2$
              lda     ##0
              jsl     long:I_SetPalette
2$:           lda     .near _g_gamestate
              cmp     ##CONST_GS_INTERMISSION
              bne     3$
              jsl     long:WI_Drawer
              brl     done
3$:           cmp     ##CONST_GS_FINALE
              bne     4$
              jsl     long:F_Drawer
              brl     done
4$:           cmp     ##CONST_GS_DEMOSCREEN
              beq     41$
              brl     done
41$:
              lda     .near DD_WIPE         ; the page is up to date: only
              bne     5$                    ;   the tic commands
              lda     .near pagedrawn
              beq     5$
              lda     .near oldgamestate
              cmp     ##CONST_GS_DEMOSCREEN
              bne     5$
              jsr     .kbank staticUpToDate
              bcc     5$
              brl     onlyTics
5$:           lda     ##1
              sta     .near pagedrawn
              lda     .near titlepicnum     ; D_PageDrawer
              jsl     long:V_DrawRawFullScreen
              jsr     .kbank staticDrawn
              brl     done
level:        lda     .near _g_gametic      ; gametic == basetic: nothing
              cmp     .near _g_basetic
              bne     dmLevel1
              lda     .near (_g_gametic+2)
              cmp     .near (_g_basetic+2)
              bne     dmLevel1
              brl     done
dmLevel1:     lda     .near automapmode     ; the view shows: no automap,
              stz     .near DD_VIEW         ;   or its overlay
              bit     ##AM_ACTIVE
              beq     dmLevel2
              bit     ##AM_OVERLAY
              beq     dmLevel3
dmLevel2:     inc     .near DD_VIEW
dmLevel3:     stz     .near DD_PAUSED       ; The old view-saving fallback.
              lda     .near _g_menuactive   ; uiOpen selects menuDisplayNear
              beq     dmLevel4              ; for the paused snapshot path.
              lda     .near DD_VIEW
              beq     dmLevel4
              inc     .near DD_PAUSED
dmLevel4:     lda     .near DD_PAUSED
              bne     dmLevel5
              stz     .near viewsaved
              lda     ##0                   ; the view rows: the palette of
              ldx     .near DD_VIEW         ;   the view, or of the automap
              bne     dmLevel41
              lda     ##AMAP_PAL
dmLevel41:    jsl     long:I_ViewPalette
              bra     dmLevel7
dmLevel5:     lda     .near viewsaved       ; paused with the view saved: the
              beq     dmLevel7                    ;   static screen, or the view back
              lda     .near DD_WIPE
              bne     dmLevel7
              lda     .near oldgamestate
              bne     dmLevel7
              jsr     .kbank staticUpToDate
              bcc     dmLevel6
              brl     onlyTics
dmLevel6:     jsl     long:I_RestoreView
              stz     .near am_valid
              brl     dmLevel8
dmLevel7:     lda     .near DD_VIEW         ; the view (saved when paused)
              bne     dmLevel78
              brl     dmLevel8
dmLevel78:
              lda     ##0xffff              ; its top: a message (not paused)
              ldx     .near DD_PAUSED       ;   keeps rows 0-9 for its strip
              bne     dmLevel72
              ldx     .near message_on
              beq     dmLevel72
              lda     ##(STRIP_ROWS - 1)
dmLevel72:    sta     .near viewtop
              lda     .near automapmode     ; the automap overlay: the map
              and     ##(AM_ACTIVE | AM_OVERLAY) ;   title keeps its rows (the
              cmp     ##(AM_ACTIVE | AM_OVERLAY) ;   lines are records after
              bne     dmLevel74                   ;   those of the view)
              lda     ##AM_TITLEY
              sta     .near viewbottom
              bra     dmLevel75
dmLevel74:    lda     ##CONST_VIEWHEIGHT
              sta     .near viewbottom
dmLevel75:    jsl     long:vwFrame          ; viewwin.inc: view size and border.
              jsl     long:R_FillStamps
              lda     ##.near PL
              sta     dp:.tiny _Dp
              lda     ##.word2 PL
              sta     dp:.tiny (_Dp+2)
              jsl     long:R_RenderPlayerView
              lda     .near automapmode     ; the overlay: its lines as records
              and     ##(AM_ACTIVE | AM_OVERLAY) ;   (the half view keeps all
              cmp     ##(AM_ACTIVE | AM_OVERLAY) ;   rows of the view: vwFrame)
              bne     dmLevel76
              jsl     long:AM_Drawer
              bra     dmLevel77
dmLevel76:    stz     .near (iigs_textShown+2) ; (the view drew over the title)
              stz     .near am_band
dmLevel77:    jsl     long:stripEarly       ; the strip palette first: the
              jsl     long:I_ApplyColors    ;   new colors with the new view
              PHASE   12
              jsl     long:R_DrawLists      ; the records: the view is complete
              stz     .near am_valid        ; (the full automap: all again)
              lda     long:VW_STRIPV        ; the view drew over the message
              bpl     dmLevel70                   ;   strip without a message
              stz     .near iigs_textShown
dmLevel70:    lda     .near DD_PAUSED
              beq     dmLevel71
              jsl     long:I_SaveView       ; (the view under the menu)
              lda     ##1
              sta     .near viewsaved
              bra     dmLevel8
menuDisplayNear .equ .
              jmp     long:uiDisplay
uiStaticCheck .equ .
              jsr     .kbank staticUpToDate
              rtl
uiStaticDrawn .equ .
              jsr     .kbank staticDrawn
              rtl
dmLevel71:    sep     #0x20                 ; the screen shows this view
              lda     #1
              sta     long:(WPAGE+W_FSG)
              rep     #0x20
dmLevel8:     lda     .near DD_VIEW         ; the full automap (the overlay
              bne     dmLevel9                    ;   goes with the view)
              lda     .near automapmode
              bit     ##AM_ACTIVE
              beq     dmLevel9
              jsl     long:AM_Drawer
dmLevel9:     PHASE   5
              jsl     long:ST_doPaletteStuff
              jsl     long:ST_Drawer
              jsl     long:HU_Drawer
              lda     .near DD_PAUSED
              beq     done
              jsr     .kbank staticDrawn
done:         lda     .near _g_gamestate
              sta     .near wipegamestate
              sta     .near oldgamestate
              PHASE   6
              jsl     long:M_Drawer         ; the menu over all
              lda     .near _g_menuactive   ; (over the view: not its fill
              ora     .near messageToPrint  ;   spans)
              ora     .near DD_WIPE
              beq     2$
              sep     #0x20
              lda     #0
              sta     long:(WPAGE+W_FSG)
              rep     #0x20
2$:           jsr     .kbank buildNewTiccmds
              lda     .near DD_WIPE
              beq     1$
              jsl     long:D_Wipe
              rts
1$:           PHASE   7
              jsl     long:I_FinishUpdate
              rts
onlyTics:     jmp     .kbank buildNewTiccmds

;;; staticUpToDate: D_StaticScreenUpToDate: carry set if the static screen
;;; shows the menu version; a skull that moved or blinked is erased and
;;; drawn again.
staticUpToDate:
              jsl     long:M_DrawVersion
              cmp     .near screenmenuversion
              beq     1$
              clc
              rts
1$:           jsl     long:M_SkullVersion
              cmp     .near screenskullversion
              bne     2$
              sec
              rts
2$:           lda     .near skullshown      ; the old skull
              sta     .near SS_OLDSHOWN
              lda     .near sky
              sta     .near SS_OLDY
              lda     .near skh
              sta     .near SS_OLDH
              lda     .near SS_OLDSHOWN
              beq     3$
              jsr     .kbank restoreRect
3$:           jsr     .kbank skullRect      ; the new one
              beq     4$
              jsr     .kbank restoreRect
              beq     4$
              lda     ##1
4$:           sta     .near skullshown
              beq     5$
              jsl     long:M_DrawSkull
5$:           jsl     long:I_ShowDirty      ; (the rectangles of the skulls)
              jsl     long:M_SkullVersion
              sta     .near screenskullversion
              sec
              rts

;;; restoreRect: C = I_RestoreBackRect(skx, sky, skw, skh), Z from it.
restoreRect:  lda     .near skh
              pha
              lda     .near skw
              sta     dp:.tiny (_Dp+4)
              lda     .near sky
              sta     dp:.tiny _Dp
              lda     .near skx
              jsl     long:I_RestoreBackRect
              ply
              cmp     ##0
              rts

;;; skullRect: C = M_SkullRect() (it sets skx, sky, skw, skh), Z from it.
skullRect:    jsl     long:M_SkullRect
              cmp     ##0
              rts

;;; staticDrawn: D_StaticScreenDrawn: the static screen shows this menu
;;; version and skull.
staticDrawn:  jsl     long:M_DrawVersion
              sta     .near screenmenuversion
              jsl     long:M_SkullVersion
              sta     .near screenskullversion
              jsr     .kbank skullRect
              sta     .near skullshown
              rts

;;; updateFPS: D_UpdateFPS: the frame rate (in tenths) of the frames since
;;; the last second.
updateFPS:    inc     .near fps_frames
              bne     1$
              inc     .near (fps_frames+2)
1$:           jsl     long:I_GetTime
              sta     .near FP_NOW
              stx     .near (FP_NOW+2)
              lda     .near fps_timebefore  ; now >= before + TICRATE (uint32)
              clc
              adc     ##CONST_TICRATE
              sta     .near FP_T
              lda     .near (fps_timebefore+2)
              adc     ##0
              sta     .near (FP_T+2)
              lda     .near FP_NOW
              cmp     .near FP_T
              lda     .near (FP_NOW+2)
              sbc     .near (FP_T+2)
              bcc     2$
              lda     .near fps_frames      ; FixedApproxDiv((frames * 350)
              ldx     ##(CONST_TICRATE*10)  ;   << 16, (now - before) << 16)
              jsl     long:IIGS_MulLo16
              pha
              lda     .near FP_NOW
              sec
              sbc     .near fps_timebefore
              sta     dp:.tiny (_Dp+2)
              stz     dp:.tiny _Dp
              plx
              lda     ##0
              jsl     long:FixedApproxDiv
              stx     .near _g_fps_framerate
              bra     3$
2$:           lda     .near FP_NOW          ; now < before: the timer wrapped
              cmp     .near fps_timebefore
              lda     .near (FP_NOW+2)
              sbc     .near (fps_timebefore+2)
              bcs     4$
3$:           lda     .near FP_NOW          ; start again
              sta     .near fps_timebefore
              lda     .near (FP_NOW+2)
              sta     .near (fps_timebefore+2)
              stz     .near fps_frames
              stz     .near (fps_frames+2)
4$:           rts

;;; ---------------------------------------------------------------------------
;;; void D_PostEvent(event_t* ev)      In: _Dp[0-3] = ev.
;;; After tic 3: the menu, else (in a level) the cheats and the automap,
;;; else the game gets the event.
;;; ---------------------------------------------------------------------------
              .public D_PostEvent
D_PostEvent:  lda     .near (_g_gametic+2)  ; gametic < 3: none
              bmi     9$
              bne     1$
              lda     .near _g_gametic
              cmp     ##3
              bcc     9$
1$:           lda     dp:.tiny _Dp
              sta     .near DE_EV
              lda     dp:.tiny (_Dp+2)
              sta     .near (DE_EV+2)
              jsl     long:M_Responder
              cmp     ##0
              bne     9$
              lda     .near _g_gamestate
              bne     2$
              jsr     .kbank eventArg
              jsl     long:C_Responder
              cmp     ##0
              bne     9$
              jsr     .kbank eventArg
              jsl     long:AM_Responder
              cmp     ##0
              bne     9$
2$:           jsr     .kbank eventArg
              jsl     long:G_Responder
9$:           rtl

;;; eventArg: _Dp[0-3] = the event.
eventArg:     lda     .near DE_EV
              sta     dp:.tiny _Dp
              lda     .near (DE_EV+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; ---------------------------------------------------------------------------
;;; void D_PageTicker(void): the title page stays for pagetic tics (it
;;; waits while the menu is up).
;;; void D_AdvanceDemo(void): the next step of the demo sequence at the
;;; next tic.
;;; void D_StartTitle(void): the demo sequence from the start.
;;; ---------------------------------------------------------------------------
              .public D_PageTicker, D_AdvanceDemo, D_StartTitle
D_PageTicker: lda     .near _g_menuactive
              bne     1$
              dec     .near pagetic
              bpl     1$
              lda     ##1                   ; D_AdvanceDemo
              sta     .near advancedemo
1$:           rtl
D_AdvanceDemo:
              lda     ##1
              sta     .near advancedemo
              rtl
D_StartTitle: stz     .near _g_gameaction   ; (ga_nothing)
              lda     ##0xffff
              sta     .near demosequence
              bra     D_AdvanceDemo

;;; doAdvanceDemo: D_DoAdvanceDemo: the demo screen state, then the next
;;; step: the title page (30 s), or demo3.
doAdvanceDemo:
              stz     .near (PL+OFS_PL_PLAYERSTATE) ; PST_LIVE: not reborn
              stz     .near advancedemo
              stz     .near _g_usergame
              stz     .near _g_gameaction   ; (ga_nothing)
              lda     ##(CONST_TICRATE*11)
              sta     .near pagetic
              lda     ##CONST_GS_DEMOSCREEN
              sta     .near _g_gamestate
              lda     .near demosequence    ; the steps: title, demo3 (the
              jsl     long:W_NextDemo       ;   title picture, no demo from
              sta     .near demosequence    ;   floppies: src/iigs/w_level65.s)
              bne     2$
              lda     ##(CONST_TICRATE*30)  ; the title page
              sta     .near pagetic
              rts
              .space  7                     ; (farcode keeps its layout)
2$:           lda     ##.word0 strDemo3     ; demo3
              sta     dp:.tiny _Dp
              lda     ##.word2 strDemo3
              sta     dp:.tiny (_Dp+2)
              jsl     long:G_DeferedPlayDemo
              rts

;;; ---------------------------------------------------------------------------
;;; stripEarly: set the message-strip palette before I_ApplyColors and
;;; R_DrawLists, so rows 0-9 use the palette of the pixels drawn there.
;;; Skip the saved, gray view while the menu is up.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
stripEarly:   lda     .near DD_PAUSED
              bne     9$
              ldx     .near message_new     ; Menu text needs a fresh clear.
              stz     .near message_new
              lda     .near _g_menuactive
              beq     3$
              inc     .near message_new
3$:           lda     .near message_on
              jsl     long:I_MessageStrip
9$:           rtl
