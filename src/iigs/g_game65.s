;;; Game actions, tic commands, demo playback and save slots.
;;;
;;; G_BuildTiccmd converts held actions into the command consumed by a game
;;; tic. G_Ticker processes pending game actions and dispatches the current
;;; game state. Level completion, intermission, finale and demo transitions
;;; are coordinated here rather than by their drawing routines.
;;; Save slots are records in the settings file (m_config65.s:F_SLOTS);
;;; m_menu65.s:saveSelect writes that file to disk.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "keys.inc"
#include "tics.inc"

              .extern _Dp, I_Error, I_GetTime, I_Quit, printf, _Mod16, bmDone, bmLoad
              .extern memset, memcpy, _Mul32, _UDivMod32, IIGS_MulLo16
              .extern W_GetNumForName, W_GetLumpByNum, W_LumpLength
              .extern Z_MallocStatic, Z_Free, Z_CheckHeap
              .extern P_WeaponCycleUp, P_WeaponCycleDown, P_CheckAmmo, P_SwitchWeapon
              .extern P_SetSecnodeFirstpoolToNull, P_SetupLevel, P_MapEnd, P_Ticker
              .extern ST_Start, ST_Ticker, HU_Start, HU_Ticker, AM_Ticker, AM_Stop
              .extern WI_End, WI_Ticker, F_Ticker, W_StartInter, W_StartFinale, F_LoadScreen
              .extern M_StartControlPanel, M_ClearRandom, D_PageTicker, D_AdvanceDemo
              .extern wipegamestate, automapmode, _g_menuactive, _g_leveltime
              .extern _g_alwaysRun, _g_savegamestrings
              .extern iigs_mousedx, iigs_mousedy, iigs_mousespeed, iigs_mousemove
              .extern mouseTurn, mouseMoveScale
              .extern maxammo, settingsFile

PL            .equ    _g_player
INITIAL_HEALTH .equ   100             ; a new player: health,
INITIAL_BULLETS .equ  50              ;   bullets
FINETURNS     .equ    3               ; frames of fine turns (fineturn)
#if MAXTICS > 7
CMDS          .equ    16              ; the tic commands (D_BuildNewTiccmds
                                      ;   makes MAXTICS at most before
                                      ;   G_Ticker, src/iigs/tics.inc)
#else
CMDS          .equ    8               ; the tic commands (D_BuildNewTiccmds
                                      ;   makes MAXTICS at most before
                                      ;   G_Ticker)
#endif
MAXPLMOVE     .equ    0x32            ; forwardmove[1]
BT_ATTACK     .equ    1
BT_USE        .equ    2
BT_CHANGE     .equ    4
GA_NOTHING    .equ    0               ; gameaction_t
GA_LOADLEVEL  .equ    1
GA_NEWGAME    .equ    2
GA_LOADGAME   .equ    3
GA_SAVEGAME   .equ    4
GA_PLAYDEMO   .equ    5
GA_COMPLETED  .equ    6
GA_VICTORY    .equ    7
GA_WORLDDONE  .equ    8
EV_KEYDOWN    .equ    0               ; evtype_t
EV_KEYUP      .equ    1
EV_DATA1      .equ    2               ; event_t: type, data1
AM_ACTIVE     .equ    1
DEMOMARKER    .equ    0x80
WM_DIDSECRET  .equ    0               ; wbstartstruct_t
WM_LAST       .equ    2
WM_NEXT       .equ    4
WM_MAXKILLS   .equ    6
WM_MAXITEMS   .equ    10
WM_MAXSECRET  .equ    14
WM_PARTIME    .equ    18
WM_SKILLS     .equ    20
WM_SITEMS     .equ    24
WM_SSECRET    .equ    28
WM_STIME      .equ    32
WM_TOTALTIMES .equ    36
WM_SIZE       .equ    40
F_SLOTS       .equ    160             ; the saved games in the settings
SLOT_SIZE     .equ    33              ;   file (src/iigs/m_config65.s): 1
SL_PRESENT    .equ    0               ;   for a save, the skill, the map, 0,
SL_SKILL      .equ    1               ;   the level times, the weapons
SL_MAP        .equ    2               ;   owned (1 byte each), the ammo and
SL_PAD        .equ    3               ;   its maximum (2 bytes each)
SL_TIMES      .equ    4
SL_WEAPONS    .equ    8
SL_AMMO       .equ    SL_WEAPONS + CONST_NUMWEAPONS
SL_MAXAMMO    .equ    SL_AMMO + 2 * CONST_NUMAMMO

              .section cnear, rodata
              .public key_menu_right, key_menu_left, key_menu_up, key_menu_down
              .public key_menu_escape, key_menu_enter, key_menu_back, key_fire, key_escape
              .public key_map_right, key_map_left, key_map_up, key_map_down
              .public key_map_zoomin, key_map_zoomout, key_map, key_map_follow
key_menu_right: .word KEYC_RIGHT        ; the menu keys do not change with
key_menu_left: .word  KEYC_LEFT         ;   the key setup (keys.inc)
key_menu_up:  .word   KEYC_UP
key_menu_down: .word  KEYC_DOWN
key_menu_escape: .word KEY_ESCAPE
key_menu_enter: .word KEYC_ENTER
key_menu_back: .word  KEYC_BACK
key_fire:     .word   KEY_FIRE
key_escape:   .word   KEY_ESCAPE
key_map_right: .word  KEY_RIGHT
key_map_left: .word   KEY_LEFT
key_map_up:   .word   KEY_UP
key_map_down: .word   KEY_DOWN
key_map_zoomin: .word KEY_ZOOMIN
key_map_zoomout: .word KEY_ZOOMOUT
key_map:      .word   KEY_MAP
key_map_follow: .word 'f'
forwardmove:  .byte   0x19, 0x32
sidemove:     .byte   0x18, 0x28
angleturn:    .word   640, 1280       ; the turn of a tic: walk, run
fineturn:     .word   320, 640, 1280  ; the turn of frames 1-3 of a turn
pars:         .byte   0, 30, 75, 120, 90, 165, 180, 180, 30, 165

              .section znear, bss
              .public _g_gameaction, _g_gamestate, _g_gameskill, _g_gamemap, _g_player
              .extern maketic
              .public _g_gametic, _g_basetic, _g_totalkills, _g_totallive, _g_totalitems
              .public _g_totalsecret, _g_wminfo, _g_respawnmonsters, _g_usergame
              .public _g_timingdemo, _g_demoplayback, _g_singledemo
_g_gameaction: .space 2
_g_gamestate: .space  2
_g_gameskill: .space  2
_g_gamemap:   .space  2
_g_player:    .space  SIZEOF_PL
_g_gametic:   .space  4
_g_basetic:   .space  4               ; for the demo sync
_g_totalkills: .space 4               ; for the intermission
_g_totallive: .space  4
_g_totalitems: .space 4
_g_totalsecret: .space 4
_g_wminfo:    .space  WM_SIZE
_g_respawnmonsters: .space 2
_g_usergame:  .space  2               ; the game can be saved or ended
_g_timingdemo: .space 2               ; the timing at the end of the demo
_g_demoplayback: .space 2
_g_singledemo: .space 2               ; quit after the demo
demobuffer:   .space  4
demolength:   .space  2
demo_p:       .space  4
starttime:    .space  4
totalleveltimes: .space 4
gamekeydown:  .space  (2 * NUMKEYS)
d_skill:      .space  2
savegameslot: .space  2               ; (a byte)
secretexit:   .space  2
defdemoname:  .space  4
netcmd:       .space  SIZEOF_TC       ; the command G_BuildTiccmd makes
cmds:         .space  (CMDS * 8)      ; Tic t uses slot t & (CMDS-1).
              .space  4               ; Keep later near data at its offsets.
GT_CMD:       .space  2               ; G_Ticker: the offset of its command
turnframes:   .space  2               ; frames of the turn key, to 4
              .public iigs_newframe
iigs_newframe: .space 2               ; a frame showed since the last tic
                                      ;   command (d_main65.s)
fudgecount:   .space  2               ; the c of fudgef
prevgamestate: .space 2
GB_SPEED:     .space  2
GB_TURN:      .space  2
GB_FORWARD:   .space  2
GB_SIDE:      .space  2
              .public GG_T
GG_T:         .space  4
GG_U:         .space  4
GG_I:         .space  2
SL_BASE:      .space  2               ; the slot in settingsFile
GG_NAME:      .space  10              ; the demo name, 0 padded

              .section cfar, rodata
              .public strGameSaved          ; (m_menu65.s saveDone)
strGameSaved: .asciz  "game saved."
errOverrun:   .asciz  "CheckForOverrun: wrong demo header\n"
msgMarker:    .asciz  "G_ReadDemoTiccmd: missing DEMOMARKER\n"
errTimed:     .asciz  "Timed %lu gametics in %lu realtics = %lu.%.3lu frames per second"

;;; ---------------------------------------------------------------------------
;;; void G_BuildTiccmd(void): the tic command of the keys (the run key,
;;; the weapon keys, the turns).
;;; A turn is per frame, not per tic: at 4 tics a frame, the slow tics of
;;; Doom turn 7 degrees at a tap, too much to aim. Frames 1-3 of a turn key
;;; turn 1.8, 3.5 and 7 degrees (fineturn, all at the first tic of the
;;; frame), then each tic turns as in Doom. A key that goes down at a later
;;; tic of a frame starts its turn at that tic. In a demo G_Ticker puts the
;;; command of the demo in place of this one.
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public G_BuildTiccmd
G_BuildTiccmd:
              stz     .near netcmd
              stz     .near (netcmd+2)
              sep     #0x20
              stz     .near (netcmd+4)
              rep     #0x20
              lda     .near (gamekeydown+2*KEY_SPEED) ; Run key XOR alwaysRun.
              eor     .near _g_alwaysRun
              sta     .near GB_SPEED
              stz     .near GB_FORWARD
              stz     .near GB_SIDE
              lda     .near (gamekeydown+2*KEY_RIGHT)
              ora     .near (gamekeydown+2*KEY_LEFT)
              bne     1$
              stz     .near turnframes      ; no turn key
              stz     .near GB_TURN
              bra     3$
1$:           ldx     .near turnframes      ; a new frame or a new turn: one
              lda     .near iigs_newframe   ;   more frame of the turn
              bne     101$
              txa
              bne     102$
101$:          cpx     ##(FINETURNS+1)
              bcs     102$
              inx
              stx     .near turnframes
              cpx     ##(FINETURNS+1)
              bcs     102$
              txa                           ; a fine turn
              asl     a
              tax
              lda     .near (fineturn-2),x
              bra     2$
102$:          lda     ##0                   ; the other tics of a fine frame
              cpx     ##(FINETURNS+1)
              bcc     2$
              lda     .near GB_SPEED        ; after the fine frames: Doom
              asl     a
              tax
              lda     .near angleturn,x
2$:           sta     .near GB_TURN
3$:           stz     .near iigs_newframe
              lda     .near (gamekeydown+2*KEY_STRAFE)
              beq     5$
              lda     .near (gamekeydown+2*KEY_RIGHT) ; strafe: side moves
              beq     4$
              jsr     .kbank sideMove
              clc
              adc     .near GB_SIDE
              sta     .near GB_SIDE
4$:           lda     .near (gamekeydown+2*KEY_LEFT)
              beq     7$
              jsr     .kbank sideMove
              jsr     .kbank subSide
              bra     7$
5$:           lda     .near (gamekeydown+2*KEY_RIGHT) ; else the turns
              beq     6$
              lda     .near GB_TURN
              eor     ##0xffff
              sec
              adc     .near (netcmd+OFS_TC_ANGLETURN)
              sta     .near (netcmd+OFS_TC_ANGLETURN)
6$:           lda     .near (gamekeydown+2*KEY_LEFT)
              beq     7$
              lda     .near GB_TURN
              clc
              adc     .near (netcmd+OFS_TC_ANGLETURN)
              sta     .near (netcmd+OFS_TC_ANGLETURN)
7$:           lda     .near (gamekeydown+2*KEY_UP) ; forward
              beq     8$
              jsr     .kbank forwardMove
              clc
              adc     .near GB_FORWARD
              sta     .near GB_FORWARD
8$:           lda     .near (gamekeydown+2*KEY_DOWN)
              beq     9$
              jsr     .kbank forwardMove
              eor     ##0xffff
              sec
              adc     .near GB_FORWARD
              sta     .near GB_FORWARD
9$:           lda     .near (gamekeydown+2*KEY_STRAFERIGHT) ; strafe keys
              beq     10$
              jsr     .kbank sideMove
              clc
              adc     .near GB_SIDE
              sta     .near GB_SIDE
10$:          lda     .near (gamekeydown+2*KEY_STRAFELEFT)
              beq     11$
              jsr     .kbank sideMove
              jsr     .kbank subSide
11$:          lda     .near (gamekeydown+2*KEY_FIRE) ; the buttons
              beq     12$
              lda     ##BT_ATTACK
              jsr     .kbank orButtons
12$:          lda     .near (gamekeydown+2*KEY_USE)
              beq     13$
              lda     ##BT_USE
              jsr     .kbank orButtons
13$:          jsr     .kbank weaponKey      ; the new weapon: a number key,
              cmp     ##CONST_WP_NOCHANGE
              bne     16$
              jsr     .kbank playerArg      ;   a cycle key
              lda     .near (gamekeydown+2*KEY_WEAPONUP)
              beq     14$
              jsl     long:P_WeaponCycleUp
              bra     16$
14$:          lda     .near (gamekeydown+2*KEY_WEAPONDOWN)
              beq     15$
              jsl     long:P_WeaponCycleDown
              bra     16$
15$:          lda     .near (PL+OFS_PL_ATTACKDOWN) ; attackdown without ammo:
              beq     151$                  ;   the best weapon
              jsl     long:P_CheckAmmo
              cmp     ##0
              bne     151$
              jsr     .kbank playerArg
              jsl     long:P_SwitchWeapon
              bra     16$
151$:         lda     ##CONST_WP_NOCHANGE
16$:          cmp     ##CONST_WP_NOCHANGE
              beq     17$
              asl     a                     ; Weapon in bits 3+, BT_CHANGE in
                                            ; bit 2.
              asl     a
              asl     a
              ora     ##BT_CHANGE
              jsr     .kbank orButtons
17$:          jsr     .kbank mouseMoves     ; the mouse
              lda     .near GB_FORWARD      ; the limits
              jsr     .kbank clampMove
              sta     .near GB_FORWARD
              lda     .near GB_SIDE
              jsr     .kbank clampMove
              sta     .near GB_SIDE
              lda     .near GB_FORWARD      ; forwardmove += fudgef(forward)
              jsr     .kbank fudgef
              sep     #0x20
              clc
              adc     .near (netcmd+OFS_TC_FORWARDMOVE)
              sta     .near (netcmd+OFS_TC_FORWARDMOVE)
              lda     .near GB_SIDE         ; sidemove += side
              clc
              adc     .near (netcmd+OFS_TC_SIDEMOVE)
              sta     .near (netcmd+OFS_TC_SIDEMOVE)
              rep     #0x20
;;; Index by tic number so commands dropped in the menu cannot shift
;;; the ring; G_Ticker reads the slot for gametic.
              lda     .near maketic
              and     ##(CMDS-1)
              asl     a
              asl     a
              asl     a
              tax
              lda     .near netcmd
              sta     .near cmds,x
              lda     .near (netcmd+2)
              sta     .near (cmds+2),x
              lda     .near (netcmd+4)
              sta     .near (cmds+4),x
              rtl
              .space  7                     ; Keep later farcode in its slots.

;;; orButtons: the buttons of the command |= the low byte of C.
orButtons:    sep     #0x20
              ora     .near (netcmd+OFS_TC_BUTTONS)
              sta     .near (netcmd+OFS_TC_BUTTONS)
              rep     #0x20
              rts

;;; subSide: GB_SIDE -= C.
subSide:      eor     ##0xffff
              sec
              adc     .near GB_SIDE
              sta     .near GB_SIDE
              rts

;;; playerArg: store the far player pointer in _Dp[0..3]. A16 is preserved;
;;; X16 is scratch at both weapon-selection call sites. Flags are not kept.
playerArg:    ldx     ##.near PL
              stx     dp:.tiny _Dp
              ldx     ##.word2 PL
              stx     dp:.tiny (_Dp+2)
              rts
              .space  (13 - (. - playerArg)) ; retain following cache slots

;;; weaponKey: C = the weapon of the first number key that is down, else
;;; wp_nochange. Key 1 is the chainsaw when the player has it, but not when
;;; the chainsaw is up with berserk (as P_PlayerThink of Doom does).
weaponKey:    ldx     ##0
1$:           lda     .near (gamekeydown+2*KEY_WEAPON1),x
              bne     2$
              inx
              inx
              cpx     ##14
              bcc     1$
              lda     ##CONST_WP_NOCHANGE
              rts
2$:           txa
              lsr     a
              bne     9$
              lda     .near (PL+OFS_PL_WEAPONOWNED+2*CONST_WP_CHAINSAW)
              beq     9$
              lda     .near (PL+OFS_PL_READYWEAPON)
              cmp     ##CONST_WP_CHAINSAW
              bne     3$
              lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_STRENGTH)
              bne     4$
3$:           lda     ##CONST_WP_CHAINSAW
              rts
4$:           lda     ##CONST_WP_FIST
9$:           rts

;;; Consume and clear both mouse deltas once per tic command. Horizontal
;;; counts turn unless the strafe action is held; vertical counts move
;;; forward/back only when iigs_mousemove is set. Clear disabled Y movement
;;; too, so enabling it cannot replay accumulated motion.
;;; Turning uses mouseTurn[speed] angle units per count (speed 0..15).
;;; Movement uses min(turn gain, 42) / 16 command units per count. Turning
;;; must precede movement: mouseMoveScale caps the shared gain in GG_T.
mouseMoves:   lda     .near iigs_mousespeed
              asl     a
              tax
              lda     long:mouseTurn,x
              sta     .near GG_T
              lda     .near iigs_mousedx
              stz     .near iigs_mousedx
              ldx     .near (gamekeydown+2*KEY_STRAFE)
              bne     1$
              jsr     .kbank mouseScale
              beq     2$
              eor     ##0xffff              ; angleturn -= C
              sec
              adc     .near (netcmd+OFS_TC_ANGLETURN)
              sta     .near (netcmd+OFS_TC_ANGLETURN)
              bra     2$
1$:           jsr     .kbank mouseMovePart  ; side += scaled horizontal movement
              clc
              adc     .near GB_SIDE
              sta     .near GB_SIDE
2$:           lda     .near iigs_mousedy
              stz     .near iigs_mousedy
              ldx     .near iigs_mousemove
              beq     3$
              jsr     .kbank mouseMovePart  ; forward -= scaled movement (down is
              eor     ##0xffff              ;   positive)
              sec
              adc     .near GB_FORWARD
              sta     .near GB_FORWARD
3$:           rts

;;; mouseScale: A = low 16 bits of clamp(A, -700, 700) * GG_T; Z if zero.
;;; Angle commands wrap modulo 65536. Movement caps GG_T at 42 first,
;;; keeping the signed product within -29400..29400 before division.
mouseScale:   cmp     ##0x8000
              bcs     1$
              cmp     ##701
              bcc     2$
              lda     ##700
              bra     2$
1$:           cmp     ##(0x10000-700)
              bcs     2$
              lda     ##(0x10000-700)
2$:           ldx     .near GG_T
              jsl     long:IIGS_MulLo16
              cmp     ##0
              rts

;;; mouseMovePart: signed count in A16 -> movement command units in A16.
;;; Cap GG_T, clamp/multiply the count, then fall through to shr4. Arithmetic
;;; shifting rounds negative products toward minus infinity.
mouseMovePart: jsl    long:mouseMoveScale
              jsr     .kbank mouseScale
;;; shr4: C = C >> 4, arithmetic.
shr4:         cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              rts

;;; sideMove, forwardMove: C = sidemove[speed], forwardmove[speed].
sideMove:     ldx     .near GB_SPEED
              lda     .near sidemove,x
              and     ##0x00ff
              rts
forwardMove:  ldx     .near GB_SPEED
              lda     .near forwardmove,x
              and     ##0x00ff
              rts

;;; clampMove: C limited to -MAXPLMOVE..MAXPLMOVE.
clampMove:    sta     .near GG_T
              sec                           ; C > MAXPLMOVE
              sbc     ##(MAXPLMOVE+1)
              bvc     1$
              eor     ##0x8000
1$:           bmi     2$
              lda     ##MAXPLMOVE
              rts
2$:           lda     .near GG_T            ; C < -MAXPLMOVE
              clc
              adc     ##MAXPLMOVE
              bvc     3$
              eor     ##0x8000
3$:           bpl     4$
              lda     ##(0x10000-MAXPLMOVE)
              rts
4$:           lda     .near GG_T
              rts

;;; fudgef: C = fudgef(the low byte of C): 0 stays; every 32nd other move
;;; is made odd, less 2 if more than 2 (int8).
fudgef:       and     ##0x00ff
              beq     9$
              sta     .near GG_T
              inc     .near fudgecount
              lda     .near fudgecount
              and     ##0x001f
              bne     8$
              lda     .near GG_T            ; b |= 1; b > 2 (int8): b -= 2
              ora     ##1
              cmp     ##0x80
              bcs     9$
              cmp     ##3
              bcc     9$
              sec
              sbc     ##2
9$:           rts
8$:           lda     .near GG_T
              rts

;;; ---------------------------------------------------------------------------
;;; void G_Responder(event_t* ev)       In: _Dp[0-3] = ev.
;;; During a demo or on the title page, a key down starts the menu (on the
;;; title page without the automap); else the keys go up and down.
;;; ---------------------------------------------------------------------------
              .public G_Responder
G_Responder:  lda     .near _g_gameaction
              bne     3$
              lda     .near _g_demoplayback
              bne     1$
              lda     .near _g_gamestate
              cmp     ##CONST_GS_DEMOSCREEN
              bne     3$
1$:           lda     .near _g_gamestate
              cmp     ##CONST_GS_DEMOSCREEN
              bne     2$
              lda     .near automapmode
              bit     ##AM_ACTIVE
              bne     2$
              lda     [.tiny _Dp]
              cmp     ##EV_KEYDOWN
              bne     2$
              jsl     long:M_StartControlPanel
2$:           rtl
3$:           ldy     ##EV_DATA1            ; data1 < NUMKEYS (signed)
              lda     [.tiny _Dp],y
              tax
              sec
              sbc     ##NUMKEYS
              bvc     31$
              eor     ##0x8000
31$:          bpl     5$
              txa
              asl     a
              tax
              lda     [.tiny _Dp]
              cmp     ##EV_KEYDOWN
              bne     4$
              lda     ##1
              sta     .near gamekeydown,x
              rtl
4$:           cmp     ##EV_KEYUP
              bne     5$
              stz     .near gamekeydown,x
5$:           rtl

;;; ---------------------------------------------------------------------------
;;; G_Ticker: handle rebirth and game actions, then tick the game state.
;;; Each tic reads its own ring command; reusing the last command of a
;;; frame would lose short turns and shots. Demos replace it from the lump.
;;; ---------------------------------------------------------------------------
              .public G_Ticker
G_Ticker:     lda     .near _g_gametic
              and     ##(CMDS-1)
              asl     a
              asl     a
              asl     a
              sta     .near GT_CMD
              lda     .near (PL+OFS_PL_PLAYERSTATE) ; G_DoReborn
              cmp     ##CONST_PST_REBORN
              bne     1$
              lda     ##GA_LOADLEVEL
              sta     .near _g_gameaction
1$:           jsl     long:P_MapEnd
2$:           lda     .near _g_gameaction   ; each game action
              beq     4$
              cmp     ##(GA_WORLDDONE+1)
              bcs     2$                    ; (no case: again, as C)
              asl     a
              tax
              jsr     (.kbank (actions-2),x)
              bra     2$
4$:           lda     .near _g_demoplayback ; the tic command
              bne     5$
              lda     .near _g_menuactive
              beq     5$
              inc     .near _g_basetic      ; paused: the demo sync
              bne     6$
              inc     .near (_g_basetic+2)
              bra     6$
5$:           ldx     .near GT_CMD
              lda     .near cmds,x
              sta     .near (PL+OFS_PL_CMD)
              lda     .near (cmds+2),x
              sta     .near (PL+OFS_PL_CMD+2)
              sep     #0x20
              lda     .near (cmds+4),x
              sta     .near (PL+OFS_PL_CMD+4)
              rep     #0x20
              lda     .near _g_demoplayback
              beq     6$
              jsr     .kbank readDemoTiccmd
6$:           lda     .near _g_gamestate    ; out of the intermission: WI_End
              cmp     .near prevgamestate
              beq     7$
              lda     .near prevgamestate
              cmp     ##CONST_GS_INTERMISSION
              bne     61$
              jsl     long:WI_End
61$:          lda     .near _g_gamestate
              sta     .near prevgamestate
7$:           lda     .near _g_gamestate    ; the ticker of the game state
              bne     8$
              jsl     long:P_Ticker
              jsl     long:ST_Ticker
              jsl     long:AM_Ticker
              jmp     long:HU_Ticker
8$:           cmp     ##CONST_GS_INTERMISSION
              bne     9$
              jmp     long:WI_Ticker
9$:           cmp     ##CONST_GS_FINALE
              bne     10$
              jmp     long:F_Ticker
10$:          cmp     ##CONST_GS_DEMOSCREEN
              bne     11$
              jmp     long:D_PageTicker
11$:          rtl
              .space  4                     ; Keep later farcode in its slots.

actions:      .word   .word0 loadLevel, .word0 doNewGame, .word0 doLoadGame
              .word   .word0 doSaveGame, .word0 doPlayDemo, .word0 doCompleted
              .word   .word0 victory, .word0 doWorldDone

;;; loadLevel: ga_loadlevel: the player is reborn in the level.
loadLevel:    lda     ##CONST_PST_REBORN
              sta     .near (PL+OFS_PL_PLAYERSTATE)
              brl     doLoadLevel

;;; victory: ga_victory: the finale.
victory:      jsl     long:W_StartFinale  ; (F_StartFinale with its pictures)
              rts

;;; doLoadLevel: G_DoLoadLevel: a wipe from a level, the level of gamemap,
;;; the keys up, the status bar and messages.
              .extern J13LevelStart, J13DemoStart
doLoadLevel:  lda     .near wipegamestate   ; from a level: a wipe
              bne     1$
              lda     ##0xffff
              sta     .near wipegamestate
1$:           stz     .near _g_gamestate    ; GS_LEVEL
              lda     .near (PL+OFS_PL_PLAYERSTATE)
              cmp     ##CONST_PST_DEAD
              bne     2$
              lda     ##CONST_PST_REBORN
              sta     .near (PL+OFS_PL_PLAYERSTATE)
2$:           jsl     long:P_SetSecnodeFirstpoolToNull
              lda     .near _g_gamemap
              jsl     long:bmLoad           ; P_SetupLevel with "LOADING"
              stz     .near _g_gameaction
              jsl     long:Z_CheckHeap
              ldx     ##(2 * NUMKEYS - 2)   ; all keys up
3$:           stz     .near gamekeydown,x
              dex
              dex
              bpl     3$
              jsl     long:ST_Start
              jsl     long:J13LevelStart   ; HU_Start, then select this level's input mode.
              rts

;;; ---------------------------------------------------------------------------
;;; void G_PlayerReborn(void): a new player: only the cheats and the
;;; counts stay.
;;; ---------------------------------------------------------------------------
              .public G_PlayerReborn
G_PlayerReborn:
              lda     .near (PL+OFS_PL_KILLCOUNT)
              pha
              lda     .near (PL+OFS_PL_ITEMCOUNT)
              pha
              lda     .near (PL+OFS_PL_SECRETCOUNT)
              pha
              lda     .near (PL+OFS_PL_CHEATS)
              pha
              ldx     ##(SIZEOF_PL - 1)     ; memset(p, 0, sizeof(*p))
              sep     #0x20
1$:           stz     .near PL,x
              dex
              bpl     1$
              rep     #0x20
              pla
              sta     .near (PL+OFS_PL_CHEATS)
              pla
              sta     .near (PL+OFS_PL_SECRETCOUNT)
              pla
              sta     .near (PL+OFS_PL_ITEMCOUNT)
              pla
              sta     .near (PL+OFS_PL_KILLCOUNT)
              lda     ##1                   ; usedown = attackdown = true
              sta     .near (PL+OFS_PL_USEDOWN)
              sta     .near (PL+OFS_PL_ATTACKDOWN)
              stz     .near (PL+OFS_PL_PLAYERSTATE) ; PST_LIVE
              lda     ##INITIAL_HEALTH
              sta     .near (PL+OFS_PL_HEALTH)
              lda     ##CONST_WP_PISTOL
              sta     .near (PL+OFS_PL_READYWEAPON)
              sta     .near (PL+OFS_PL_PENDINGWEAPON)
              lda     ##1                   ; the fist, the pistol
              sta     .near (PL+OFS_PL_WEAPONOWNED+2*CONST_WP_FIST)
              sta     .near (PL+OFS_PL_WEAPONOWNED+2*CONST_WP_PISTOL)
              lda     ##INITIAL_BULLETS
              sta     .near (PL+OFS_PL_AMMO+2*CONST_AM_CLIP)
              ldx     ##(2 * CONST_NUMAMMO - 2) ; maxammo[i] = maxammo[i]
2$:           lda     .near maxammo,x
              sta     .near (PL+OFS_PL_MAXAMMO),x
              dex
              dex
              bpl     2$
              rtl

;;; ---------------------------------------------------------------------------
;;; void G_ExitLevel(void), G_SecretExitLevel(void): the level is completed
;;; (to the next level, or the secret level).
;;; ---------------------------------------------------------------------------
              .public G_ExitLevel, G_SecretExitLevel
G_ExitLevel:  stz     .near secretexit
              lda     ##GA_COMPLETED
              sta     .near _g_gameaction
              rtl
G_SecretExitLevel:
              lda     ##1
              sta     .near secretexit
              lda     ##GA_COMPLETED
              sta     .near _g_gameaction
              rtl

;;; doCompleted: G_DoCompleted: the player finishes the level; the
;;; intermission with the counts, the times and the next level.
doCompleted:  stz     .near _g_gameaction
              ldx     ##(2 * CONST_NUMPOWERS - 1) ; Clear level-only powers and
                                                  ; cards.
              sep     #0x20                 ; Also mobj and palette flashes.
1$:           stz     .near (PL+OFS_PL_POWERS),x
              dex
              bpl     1$
              ldx     ##(2 * CONST_NUMCARDS - 1) ; (boolean cards)
2$:           stz     .near (PL+OFS_PL_CARDS),x
              dex
              bpl     2$
              rep     #0x20
              stz     .near (PL+OFS_PL_MO)
              stz     .near (PL+OFS_PL_MO+2)
              stz     .near (PL+OFS_PL_EXTRALIGHT)
              stz     .near (PL+OFS_PL_FIXEDCOLORMAP)
              stz     .near (PL+OFS_PL_DAMAGECOUNT)
              stz     .near (PL+OFS_PL_BONUSCOUNT)
              lda     .near automapmode
              bit     ##AM_ACTIVE
              beq     3$
              jsl     long:AM_Stop
3$:           lda     .near _g_gamemap      ; map 9 counts as the secret
              cmp     ##9
              bne     4$
              lda     ##1
              sta     .near (PL+OFS_PL_DIDSECRET)
4$:           lda     .near (PL+OFS_PL_DIDSECRET)
              sta     .near (_g_wminfo+WM_DIDSECRET)
              lda     .near _g_gamemap
              dec     a
              sta     .near (_g_wminfo+WM_LAST)
              ldx     ##8                   ; next: the secret level 9, or 4
              lda     .near secretexit      ;   after 9, or the next one
              bne     5$
              ldx     ##3
              lda     .near _g_gamemap
              cmp     ##9
              beq     5$
              tax
5$:           stx     .near (_g_wminfo+WM_NEXT)
              ldx     ##0                   ; the totals
6$:           lda     .near _g_totalkills,x
              sta     .near (_g_wminfo+WM_MAXKILLS),x
              lda     .near _g_totalitems,x
              sta     .near (_g_wminfo+WM_MAXITEMS),x
              lda     .near _g_totalsecret,x
              sta     .near (_g_wminfo+WM_MAXSECRET),x
              inx
              inx
              cpx     ##4
              bcc     6$
              lda     .near _g_gamemap      ; partime = TICRATE * pars[map]
              tax
              lda     long:pars,x
              and     ##0x00ff
              ldx     ##CONST_TICRATE
              jsl     long:IIGS_MulLo16
              sta     .near (_g_wminfo+WM_PARTIME)
              lda     .near (PL+OFS_PL_KILLCOUNT) ; the counts of the player
              ldx     ##WM_SKILLS
              jsr     .kbank signLong
              lda     .near (PL+OFS_PL_ITEMCOUNT)
              ldx     ##WM_SITEMS
              jsr     .kbank signLong
              lda     .near (PL+OFS_PL_SECRETCOUNT)
              ldx     ##WM_SSECRET
              jsr     .kbank signLong
              lda     .near _g_leveltime
              sta     .near (_g_wminfo+WM_STIME)
              lda     .near (_g_leveltime+2)
              sta     .near (_g_wminfo+WM_STIME+2)
              lda     .near _g_leveltime    ; round the full 32-bit tic count
              sta     dp:.tiny _Dp          ; down to whole seconds
              lda     .near (_g_leveltime+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##CONST_TICRATE
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_UDivMod32
              lda     dp:.tiny _Dp          ; remainder (0..34)
              sta     .near GG_T
              stz     .near (GG_T+2)
              lda     .near _g_leveltime
              sec
              sbc     .near GG_T
              tax
              lda     .near (_g_leveltime+2)
              sbc     .near (GG_T+2)
              tay
              txa
              clc
              adc     .near totalleveltimes
              sta     .near totalleveltimes
              sta     .near (_g_wminfo+WM_TOTALTIMES)
              tya
              adc     .near (totalleveltimes+2)
              sta     .near (totalleveltimes+2)
              sta     .near (_g_wminfo+WM_TOTALTIMES+2)
              lda     ##CONST_GS_INTERMISSION
              sta     .near _g_gamestate
              lda     .near automapmode
              and     ##(0xffff - AM_ACTIVE)
              sta     .near automapmode
              lda     ##.near _g_wminfo     ; WI_Start(&wminfo)
              sta     dp:.tiny _Dp
              lda     ##.word2 _g_wminfo
              sta     dp:.tiny (_Dp+2)
              jsl     long:W_StartInter   ; (WI_Start with its pictures)
              rts

;;; signLong: _g_wminfo + X = C, sign extended to 32 bits.
signLong:     sta     .near _g_wminfo,x
              ldy     ##0
              cmp     ##0
              bpl     1$
              dey
1$:           tya
              sta     .near (_g_wminfo+2),x
              rts

;;; ---------------------------------------------------------------------------
;;; void G_WorldDone(void): after the intermission: the next level (after
;;; map 8 the finale).
;;; ---------------------------------------------------------------------------
              .public G_WorldDone
G_WorldDone:  lda     ##GA_WORLDDONE
              sta     .near _g_gameaction
              lda     .near secretexit
              beq     1$
              lda     ##1
              sta     .near (PL+OFS_PL_DIDSECRET)
1$:           lda     .near _g_gamemap
              cmp     ##8
              bne     2$
              lda     ##GA_VICTORY
              sta     .near _g_gameaction
2$:           rtl

;;; doWorldDone: G_DoWorldDone: the level after the intermission.
doWorldDone:  jsl     long:F_LoadScreen     ; retire the map before LOADING
              stz     .near _g_gamestate    ; GS_LEVEL
              lda     .near (_g_wminfo+WM_NEXT)
              inc     a
              sta     .near _g_gamemap
              jsr     .kbank doLoadLevel
              stz     .near _g_gameaction
              rts

;;; ---------------------------------------------------------------------------
;;; The saved games: 8 slots in the settings file (settingsFile + F_SLOTS,
;;; src/iigs/m_config65.s), which goes to the disk only when the player
;;; saves a game or picks SAVE SETTINGS (src/iigs/m_menu65.s). Loading a
;;; save restarts its map with the stored level times, weapons and ammo;
;;; monsters and other world state are recreated by the level loader.
;;; A slot has SLOT_SIZE bytes: 1 for a save, the skill, the map, 0,
;;; the level times (4), the weapons owned (0 or 1 each), the ammo and its
;;; maximum (2 bytes each).
;;; void G_UpdateSaveGameStrings(void): "EMPTY", or "E1Mn" for the map of a
;;; slot with a save.
;;; ---------------------------------------------------------------------------
              .public G_UpdateSaveGameStrings
G_UpdateSaveGameStrings:
              stz     .near GG_I
1$:           lda     .near GG_I            ; the slot
              jsr     .kbank slotOffset
              lda     .near GG_I            ; its string
              asl     a
              asl     a
              asl     a
              tay
              jsr     .kbank slotSave
              bcs     2$
              lda     ##('E' | ('1' << 8))  ; "E1M" + '0' + gamemap
              sta     .near _g_savegamestrings,y
              lda     long:(settingsFile+SL_MAP),x
              and     ##0x00ff
              clc
              adc     ##'0'
              xba
              ora     ##'M'
              sta     .near (_g_savegamestrings+2),y
              lda     ##0
              sta     .near (_g_savegamestrings+4),y
              bra     3$
2$:           lda     ##('E' | ('M' << 8))  ; "EMPTY"
              sta     .near _g_savegamestrings,y
              lda     ##('P' | ('T' << 8))
              sta     .near (_g_savegamestrings+2),y
              lda     ##'Y'
              sta     .near (_g_savegamestrings+4),y
3$:           inc     .near GG_I
              lda     .near GG_I
              cmp     ##8
              bcc     1$
              rtl

;;; slotOffset: X = SL_BASE = the offset of slot C in settingsFile.
slotOffset:   and     ##0x00ff
              sta     .near SL_BASE
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     .near SL_BASE         ; * SLOT_SIZE
              adc     ##F_SLOTS
              sta     .near SL_BASE
              tax
              rts

;;; slotSave: carry clear if the slot at X has a save: 1, a skill of 0-4, a
;;; map of 1-9.
slotSave:     lda     long:(settingsFile+SL_PRESENT),x
              and     ##0x00ff
              cmp     ##1
              bne     9$
              lda     long:(settingsFile+SL_SKILL),x
              and     ##0x00ff
              cmp     ##5
              bcs     9$
              lda     long:(settingsFile+SL_MAP),x
              and     ##0x00ff
              beq     9$
              cmp     ##10
              bcs     9$
              clc
              rts
9$:           sec
              rts

;;; ---------------------------------------------------------------------------
;;; void G_LoadGame(int16_t slot), G_SaveGame(int16_t slot)   In: C.
;;; ---------------------------------------------------------------------------
              .public G_LoadGame, G_SaveGame
G_LoadGame:   sep     #0x20
              sta     .near savegameslot
              rep     #0x20
              stz     .near _g_demoplayback
              jsr     .kbank doLoadGame
              rtl
G_SaveGame:   sep     #0x20
              sta     .near savegameslot
              rep     #0x20
              jsr     .kbank doSaveGame
              rtl

;;; doLoadGame: G_DoLoadGame: a slot with a save: a new game of its skill
;;; and map, with its times, weapons and ammo; the backpack if the ammo
;;; maximum is more than the normal one. No save: nothing.
doLoadGame:   lda     .near savegameslot
              jsr     .kbank slotOffset
              jsr     .kbank slotSave
              bcc     1$
              rts
1$:           lda     long:(settingsFile+SL_SKILL),x
              and     ##0x00ff
              sta     .near _g_gameskill
              lda     long:(settingsFile+SL_MAP),x
              and     ##0x00ff
              sta     .near _g_gamemap
              sta     dp:.tiny _Dp          ; G_InitNew(skill, map)
              lda     .near _g_gameskill
              jsr     .kbank initNew
              ldx     .near SL_BASE
              lda     long:(settingsFile+SL_TIMES),x
              sta     .near totalleveltimes
              lda     long:(settingsFile+SL_TIMES+2),x
              sta     .near (totalleveltimes+2)
              ldy     ##0                   ; the weapons owned
2$:           lda     long:(settingsFile+SL_WEAPONS),x
              and     ##0x00ff
              sta     .near (PL+OFS_PL_WEAPONOWNED),y
              inx
              iny
              iny
              cpy     ##(2 * CONST_NUMWEAPONS)
              bcc     2$
              ldx     .near SL_BASE
              ldy     ##0                   ; the ammo and its maximum
3$:           lda     long:(settingsFile+SL_AMMO),x
              sta     .near (PL+OFS_PL_AMMO),y
              lda     long:(settingsFile+SL_MAXAMMO),x
              sta     .near (PL+OFS_PL_MAXAMMO),y
              inx
              inx
              iny
              iny
              cpy     ##(2 * CONST_NUMAMMO)
              bcc     3$
              lda     .near maxammo         ; more than the clip maximum:
              sec                           ;   the backpack
              sbc     .near (PL+OFS_PL_MAXAMMO+2*CONST_AM_CLIP)
              bvc     4$
              eor     ##0x8000
4$:           bpl     5$
              lda     ##1
              sta     .near (PL+OFS_PL_BACKPACK)
5$:           rts

;;; doSaveGame: G_DoSaveGame: the skill, map, times, weapons and ammo in the
;;; slot; the message; the slot strings.
doSaveGame:   lda     .near savegameslot
              jsr     .kbank slotOffset
              sep     #0x20
              lda     #1
              sta     long:(settingsFile+SL_PRESENT),x
              lda     .near _g_gameskill
              sta     long:(settingsFile+SL_SKILL),x
              lda     .near _g_gamemap
              sta     long:(settingsFile+SL_MAP),x
              lda     #0
              sta     long:(settingsFile+SL_PAD),x
              rep     #0x20
              lda     .near totalleveltimes
              sta     long:(settingsFile+SL_TIMES),x
              lda     .near (totalleveltimes+2)
              sta     long:(settingsFile+SL_TIMES+2),x
              ldy     ##0                   ; the weapons owned: 0 or 1
1$:           lda     .near (PL+OFS_PL_WEAPONOWNED),y
              beq     2$
              lda     ##1
2$:           sep     #0x20
              sta     long:(settingsFile+SL_WEAPONS),x
              rep     #0x20
              inx
              iny
              iny
              cpy     ##(2 * CONST_NUMWEAPONS)
              bcc     1$
              ldx     .near SL_BASE
              ldy     ##0                   ; the ammo and its maximum
3$:           lda     .near (PL+OFS_PL_AMMO),y
              sta     long:(settingsFile+SL_AMMO),x
              lda     .near (PL+OFS_PL_MAXAMMO),y
              sta     long:(settingsFile+SL_MAXAMMO),x
              inx
              inx
              iny
              iny
              cpy     ##(2 * CONST_NUMAMMO)
              bcc     3$
              jsl     long:G_UpdateSaveGameStrings
              rts
              .space  12                    ; Keep later farcode at its slots.

;;; ---------------------------------------------------------------------------
;;; void G_DeferedInitNew(skill_t skill)  In: C. A new game at the next tic.
;;; void G_ReloadDefaults(void): no demo.
;;; ---------------------------------------------------------------------------
              .public G_DeferedInitNew, G_ReloadDefaults
G_DeferedInitNew:
              sta     .near d_skill
              lda     ##GA_NEWGAME
              sta     .near _g_gameaction
              rtl
G_ReloadDefaults:
              stz     .near _g_demoplayback
              stz     .near _g_singledemo
              rtl

;;; doNewGame: G_DoNewGame: a new game of d_skill from map 1.
doNewGame:    jsl     long:G_ReloadDefaults
              lda     ##1
              sta     dp:.tiny _Dp
              lda     .near d_skill
              jsr     .kbank initNew
              stz     .near _g_gameaction
              jsl     long:ST_Start
              rts

;;; initNew: G_InitNew(skill C, map _Dp[0-1]): the limits (skill up to
;;; nightmare, map 1..9), the random numbers from the start, the level.
initNew:      cmp     ##(CONST_SK_NIGHTMARE+1) ; skill > sk_nightmare (signed)
              bmi     1$
              lda     ##CONST_SK_NIGHTMARE
1$:           sta     .near _g_gameskill
              lda     dp:.tiny _Dp          ; map 1..9 (signed)
              cmp     ##1
              bpl     2$
              lda     ##1
2$:           cmp     ##10
              bmi     3$
              lda     ##9
3$:           sta     .near _g_gamemap
              jsl     long:M_ClearRandom
              stz     .near _g_respawnmonsters
              lda     .near _g_gameskill
              cmp     ##CONST_SK_NIGHTMARE
              bne     4$
              inc     .near _g_respawnmonsters
4$:           lda     ##CONST_PST_REBORN
              sta     .near (PL+OFS_PL_PLAYERSTATE)
              lda     ##1
              sta     .near _g_usergame
              lda     .near automapmode
              and     ##(0xffff - AM_ACTIVE)
              sta     .near automapmode
              stz     .near totalleveltimes
              stz     .near (totalleveltimes+2)
              brl     doLoadLevel

;;; ---------------------------------------------------------------------------
;;; readDemoTiccmd: G_ReadDemoTiccmd: the tic command from the demo, or at
;;; its end the demo status.
;;; ---------------------------------------------------------------------------
readDemoTiccmd:
              lda     .near demo_p
              sta     dp:.tiny _Dp
              lda     .near (demo_p+2)
              sta     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp]           ; DEMOMARKER: the end
              and     ##0x00ff
              cmp     ##DEMOMARKER
              beq     2$
              lda     .near _g_demoplayback ; past the end: no marker
              beq     1$
              lda     .near demo_p
              clc
              adc     ##4
              sec
              sbc     .near demobuffer
              beq     1$
              cmp     .near demolength
              beq     1$
              bcc     1$
              lda     ##.word0 msgMarker
              sta     dp:.tiny _Dp
              lda     ##.word2 msgMarker
              sta     dp:.tiny (_Dp+2)
              jsl     long:printf
2$:           jsl     long:G_CheckDemoStatus
              rts
1$:           lda     [.tiny _Dp]           ; forwardmove, sidemove
              sta     .near (PL+OFS_PL_CMD+OFS_TC_FORWARDMOVE)
              ldy     ##2                   ; angleturn = byte << 8
              lda     [.tiny _Dp],y
              xba
              and     ##0xff00
              sta     .near (PL+OFS_PL_CMD+OFS_TC_ANGLETURN)
              sep     #0x20                 ; buttons
              ldy     ##3
              lda     [.tiny _Dp],y
              sta     .near (PL+OFS_PL_CMD+OFS_TC_BUTTONS)
              rep     #0x20
              lda     .near demo_p
              clc
              adc     ##4
              sta     .near demo_p
              rts

;;; ---------------------------------------------------------------------------
;;; void G_DeferedPlayDemo(const char* name)   In: _Dp[0-3]. The demo at
;;; the next tic.
;;; ---------------------------------------------------------------------------
              .public G_DeferedPlayDemo
G_DeferedPlayDemo:
              lda     dp:.tiny _Dp
              sta     .near defdemoname
              lda     dp:.tiny (_Dp+2)
              sta     .near (defdemoname+2)
              lda     ##GA_PLAYDEMO
              sta     .near _g_gameaction
              rtl

;;; doPlayDemo: G_DoPlayDemo: the demo lump of the base of the name (up to
;;; 8 characters before a '.', upper case), its header, the playback.
doPlayDemo:   lda     .near defdemoname     ; ExtractFileBase: from the end
              sta     dp:.tiny _Dp          ;   back to the start or a ':',
              lda     .near (defdemoname+2) ;   '\' or '/'
              sta     dp:.tiny (_Dp+2)
              ldy     ##0
              sep     #0x20
1$:           lda     [.tiny _Dp],y         ; the end of the name
              beq     2$
              iny
              bra     1$
2$:           cpy     ##0                   ; src = the last character
              beq     4$
              dey
3$:           cpy     ##0                   ; while src != path and
              beq     4$                    ;   src[-1] is not ':' '\' '/'
              dey
              lda     [.tiny _Dp],y
              iny
              cmp     #':'
              beq     4$
              cmp     #0x5c
              beq     4$
              cmp     #'/'
              beq     4$
              dey
              bra     3$
4$:           ldx     ##0                   ; memset(dest, 0, 8)
41$:          stz     .near GG_NAME,x
              inx
              cpx     ##9
              bcc     41$
              ldx     ##0                   ; up to 8 characters, upper case
5$:           lda     [.tiny _Dp],y
              beq     7$
              cmp     #'.'
              beq     7$
              cpx     ##8
              bcs     7$
              cmp     #'a'
              bcc     6$
              cmp     #('z'+1)
              bcs     6$
              sbc     #('a'-'A'-1)          ; (carry clear: - 0x20)
6$:           sta     .near GG_NAME,x
              inx
              iny
              bra     5$
7$:           rep     #0x20
              lda     ##.near GG_NAME       ; the lump of the name
              sta     dp:.tiny _Dp
              lda     ##.word2 GG_NAME
              sta     dp:.tiny (_Dp+2)
              jsl     long:W_GetNumForName
              pha
              jsl     long:W_GetLumpByNum
              sta     .near demobuffer
              stx     .near (demobuffer+2)
              pla
              jsl     long:W_LumpLength
              sta     .near demolength
              jsr     .kbank readDemoHeader
              stz     .near _g_gameaction
              stz     .near _g_usergame
              lda     ##1
              sta     .near _g_demoplayback
              jsl     long:J13DemoStart    ; Select demo input; return I_GetTime in X:A.
              sta     .near starttime
              stx     .near (starttime+2)
              rts

;;; readDemoHeader: G_ReadDemoHeader: the skill and map of the demo (a new
;;; game), no cheats; demo_p after the header.
readDemoHeader:
              lda     .near _g_gametic      ; basetic = gametic
              sta     .near _g_basetic
              lda     .near (_g_gametic+2)
              sta     .near (_g_basetic+2)
              lda     ##1                   ; the version
              jsr     .kbank checkOverrun
              lda     ##(1+8)               ; skill, episode, map, 5 more
              jsr     .kbank checkOverrun
              lda     ##(1+8+1)             ; the player
              jsr     .kbank checkOverrun
              lda     .near demobuffer
              sta     dp:.tiny (_Dp+4)
              lda     .near (demobuffer+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##1                   ; skill, map
              lda     [.tiny (_Dp+4)],y
              and     ##0x00ff
              pha
              ldy     ##3
              lda     [.tiny (_Dp+4)],y
              and     ##0x00ff
              sta     dp:.tiny _Dp
              lda     .near demobuffer      ; demo_p = the header + 13
              clc
              adc     ##(1+8+1+3)
              sta     .near demo_p
              lda     .near (demobuffer+2)
              sta     .near (demo_p+2)
              pla
              ldx     .near _g_gameaction   ; not a loaded game: G_InitNew
              cpx     ##GA_LOADGAME
              beq     1$
              jsr     .kbank initNew
1$:           stz     .near (PL+OFS_PL_CHEATS)
              rts

;;; checkOverrun: CheckForOverrun: I_Error if C bytes of the header go
;;; past the demo length.
checkOverrun: cmp     .near demolength
              beq     1$
              bcc     1$
              lda     ##.word0 errOverrun
              sta     dp:.tiny _Dp
              lda     ##.word2 errOverrun
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
1$:           rts

;;; ---------------------------------------------------------------------------
;;; G_CheckDemoStatus: timed results go to bmDone in m_menu65.s; a single
;;; demo exits, otherwise the title loop continues. bmDone depends on the
;;; four 32-bit arguments below and this routine's untouched return stack.
;;; ---------------------------------------------------------------------------
              .public G_CheckDemoStatus
G_CheckDemoStatus:
              lda     .near _g_timingdemo
              beq     1$
              jsl     long:I_GetTime        ; realtics = now - starttime
              sec
              sbc     .near starttime
              sta     .near GG_U
              txa
              sbc     .near (starttime+2)
              sta     .near (GG_U+2)
              lda     .near _g_gametic      ; resultfps = 35000 * gametic /
              sta     dp:.tiny _Dp          ;   realtics
              lda     .near (_g_gametic+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##(CONST_TICRATE*1000)
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_Mul32
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near GG_U
              sta     dp:.tiny (_Dp+4)
              lda     .near (GG_U+2)
              sta     dp:.tiny (_Dp+6)
              jsl     long:_UDivMod32
              sta     .near GG_T
              stx     .near (GG_T+2)
              jsr     .kbank div1000        ; resultfps % 1000
              lda     dp:.tiny (_Dp+2)
              pha
              lda     dp:.tiny _Dp
              pha
              jsr     .kbank div1000        ; resultfps / 1000
              phx
              pha
              lda     .near (GG_U+2)        ; realtics, gametic
              pha
              lda     .near GG_U
              pha
              lda     .near (_g_gametic+2)
              pha
              lda     .near _g_gametic
              pha
              lda     ##.word0 errTimed
              sta     dp:.tiny _Dp
              lda     ##.word2 errTimed
              sta     dp:.tiny (_Dp+2)
              jsl     long:bmDone           ; I_Error, or the benchmark result
1$:           lda     .near _g_demoplayback
              beq     2$
              lda     .near _g_singledemo
              beq     3$
              jmp     long:I_Quit
3$:           jsl     long:G_ReloadDefaults
              jmp     long:D_AdvanceDemo
2$:           rtl

;;; div1000: X:C = GG_T / 1000, _Dp[0-3] = GG_T % 1000.
div1000:      lda     .near GG_T
              sta     dp:.tiny _Dp
              lda     .near (GG_T+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##1000
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_UDivMod32
              rts
