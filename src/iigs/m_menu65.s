;;; Menus, key setup and benchmark, Doom8088: Apple IIgs Edition.
;;; Menu and skull versions let D_Display reuse a static screen.
;;; Messages are drawn from the original string without a zone copy.
;;; Only SAVE SETTINGS and a saved game write the settings file;
;;; G_SaveSettings in m_config65.s handles unchanged settings and errors.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"
#include "keys.inc"
#include "viewwin.inc"

#ifndef MUSIC_MENU
#define MUSIC_MENU 0
#endif

              .extern _Dp, _g_player, _g_singledemo, _g_message_dontfuckwithme
              .extern W_SET, W_LevelDone
              .extern key_menu_right, key_menu_left, key_menu_up, key_menu_down
              .extern key_menu_escape, key_menu_enter, key_menu_back, key_fire, key_escape
              .extern W_GetNumForName, W_GetLumpByNum, V_DrawNumPatchNotScaled
              .extern V_DrawPatchNotScaled, V_NumPatchWidth, S_StartSound
              .extern G_DeferedInitNew, G_LoadGame, G_SaveGame, G_CheckDemoStatus
              .extern _g_usergame, _g_demoplayback, _g_gamestate
              .extern G_UpdateSaveGameStrings, D_StartTitle, I_Quit, G_SaveSettings
              .extern strGameSaved, G_SaveUndo
              .extern I_ReloadPalette, I_SetPalette, skx, sky, skw, skh
              .extern IIGS_MouseUp, I_BindKey, I_DefaultKeys, I_ActionKeys
              .extern iigs_bindwait, iigs_bindcode, R_SetDetail
              .extern key_map_zoomout, key_map_zoomin, automapmode, settingsFile
              .extern G_DeferedPlayDemo, _g_timingdemo, vwFrame
              .extern I_Error, _Mul32, _UDivMod32, P_SetupLevel, IIGS_StopInterrupts
              .extern IIGS_StartInterrupts, G_SettingsChanged, I_MarkRect, I_ShowDirty
              .extern IIGS_ZipOff, IIGS_ZipBack, _g_gamemap
              .extern snd_SfxVolume, snd_MusicVolume
              .extern S_SetSfxVolume, S_SetMusicVolume
              .extern I_MenuPalette, I_MenuPaletteBack, message_on
              .extern uiOpen

PL            .equ    _g_player
EV_DATA1      .equ    2               ; event_t (type 0: ev_keydown)
SKULLXOFF     .equ    32              ; (subtracted)
LINEHEIGHT    .equ    16              ; the rows of the menus (menuLine),
CTLLINE       .equ    14              ;   of the key setup
HU_FONTSTART  .equ    '!'
HU_FONTEND    .equ    '_'
HU_FONT_HEIGHT .equ   7
HU_FONT_SPACE_WIDTH .equ 4
NIGHTMARE     .equ    4               ; the skill
MENU_MAIN     .equ    0               ; currentMenu (x 2)
MENU_NEW      .equ    2
MENU_LOAD     .equ    4
MENU_OPTIONS  .equ    6
MENU_CONTROLS .equ    8
MENU_VIDEO    .equ    12
MENU_SOUND    .equ    14
MENU_INPUT    .equ    16
MENU_SAVE     .equ    10
CONTROLS      .equ    10              ; the actions of the key setup
ADB_ESC       .equ    0x35
MSG_NIGHTMARE .equ    0               ; messageKind (x 4)
MSG_QUIT      .equ    4
MSG_ENDGAME   .equ    8
MSG_SAVEDEAD  .equ    12              ;   (no Y or N: any key, also for the
MSG_BENCH     .equ    16              ;   benchmark result of bmDone,
MSG_SAVEFAIL  .equ    20              ;   and a failed disk write)
L_DOOM        .equ    0               ; the patch lumps in LUMPS (x 2)
L_NGAME       .equ    2
L_OPTION      .equ    4
L_LOADG       .equ    6
L_QUITG       .equ    8
L_NEWG        .equ    10
L_SKILL       .equ    12
L_JKILL       .equ    14              ; the 5 skills
L_LSLEFT      .equ    24
L_LSCNTR      .equ    26
L_LSRGHT      .equ    28
L_OPTTTL      .equ    30
L_MSGOFF      .equ    32
L_MSGON       .equ    34
L_ENDGAM      .equ    36
L_MESSG       .equ    38
L_ARUN        .equ    40
L_GAMMA       .equ    42
L_THERML      .equ    44
L_THERMM      .equ    46
L_THERMR      .equ    48
L_THERMO      .equ    50
L_SKULL1      .equ    52
L_SKULL2      .equ    54
L_FONT        .equ    56              ; STCFN033
L_MOUSE       .equ    58
L_MSPEED      .equ    60
L_MMOVE       .equ    62
L_CTRLS       .equ    64
L_SAVEG       .equ    66
NUM_LUMPS     .equ    34

              .section near, data
              .public showMessages, iigs_mouseon, iigs_mousespeed, iigs_mousemove
              .public detailLevel, messageToPrint
showMessages: .word   1
detailLevel:  .word   0               ; the textures: 0 high detail, 1 low
                                      ; (half the rows, R_SetDetail)
iigs_mouseon: .word   1               ; the mouse turns and fires
iigs_mousespeed: .word 5              ; 0-9
iigs_mousemove: .word 0               ; the mouse moves forward and back

              .section znear, bss
              .public _g_alwaysRun, _g_gamma, _g_menuactive, _g_savegamestrings
_g_alwaysRun: .space  2
_g_gamma:     .space  2
_g_menuactive: .space 2
_g_savegamestrings: .space 64
messageToPrint: .space 2
messageKind:  .space  2
messageLastMenuActive: .space 2
currentMenu:  .space  2
itemOn:       .space  2
skullAnimCounter: .space 2
whichSkull:   .space  2
menuversion:  .space  2
skullversion: .space  2
fontLumpOffset: .space 2
LUMPS:        .space  2 * NUM_LUMPS
SK_DX:        .space  2               ; the rectangle of both skulls from
SK_DY:        .space  2               ;   the place of the skull
SK_W:         .space  2
SK_H:         .space  2
MR_CH:        .space  2               ; M_Responder: the key, the state
MR_MENU:      .space  2               ;   before the event
MR_ITEM:      .space  2
MR_ACTIVE:    .space  2
MR_MSG:       .space  2
MD_X:         .space  2               ; M_Drawer: the items
MD_Y:         .space  2
MD_H:         .space  2
MD_N:         .space  2
MD_I:         .space  2
MM_X:         .space  2               ; the patches of the load menu
MM_Y:         .space  2
MM_I:         .space  2
MT_X:         .space  2               ; a line of text: its place,
MT_Y:         .space  2
MT_P:         .space  2               ;   the character,
MT_W:         .space  2               ;   the width
TH_X:         .space  2               ; onOff, thermo: the place,
TH_Y:         .space  2
TH_N:         .space  2               ;   the steps,
TH_V:         .space  2               ;   the place of the dot
CT_I:         .space  2               ; drawControls: the row,
CT_Y:         .space  2               ;   its y,
CT_K:         .space  2               ;   the second key
bindRow:      .space  2               ; the action that waits for a key
                                      ;   (0xffff: none)

              .section cfar, rodata
menuDataStart:
lumpNames:    .ascii  "M_DOOM"                    ; 8 bytes each
              .byte   0, 0
              .ascii  "M_NGAME"
              .byte   0
              .ascii  "M_OPTION"
              .ascii  "M_LOADG"
              .byte   0
              .ascii  "M_QUITG"
              .byte   0
              .ascii  "M_NEWG"
              .byte   0, 0
              .ascii  "M_SKILL"
              .byte   0
              .ascii  "M_JKILL"
              .byte   0
              .ascii  "M_ROUGH"
              .byte   0
              .ascii  "M_HURT"
              .byte   0, 0
              .ascii  "M_ULTRA"
              .byte   0
              .ascii  "M_NMARE"
              .byte   0
              .ascii  "M_LSLEFT"
              .ascii  "M_LSCNTR"
              .ascii  "M_LSRGHT"
              .ascii  "M_OPTTTL"
              .ascii  "M_MSGOFF"
              .ascii  "M_MSGON"
              .byte   0
              .ascii  "M_ENDGAM"
              .ascii  "M_MESSG"
              .byte   0
              .ascii  "M_ARUN"
              .byte   0, 0
              .ascii  "M_GAMMA"
              .byte   0
              .ascii  "M_THERML"
              .ascii  "M_THERMM"
              .ascii  "M_THERMR"
              .ascii  "M_THERMO"
              .ascii  "M_SKULL1"
              .ascii  "M_SKULL2"
              .ascii  "STCFN033"
              .ascii  "M_MOUSE"
              .byte   0
              .ascii  "M_MSPEED"
              .ascii  "M_MMOVE"
              .byte   0
              .ascii  "M_CTRLS"
              .byte   0
              .ascii  "M_SAVEG"
              .byte   0
msgNightmare: .ascii  "Are you sure? This skill level\n"
              .ascii  "isn't even remotely fair.\n\n"
              .asciz  "Press Y or N."
msgQuit:      .ascii  "Are you sure you want to\n"
              .ascii  "quit this great game?\n\n"
              .asciz  "Press Y or N."
msgEndGame:   .ascii  "Are you sure you want to\n"
              .ascii  "end the game?\n\n"
              .asciz  "Press Y or N."
msgSaveDead:  .ascii  "You can't save if you aren't playing!\n\n"
              .asciz  "Press a key."
msgOn:        .asciz  "Messages On"
msgOff:       .asciz  "Messages Off"
msgRunOff:    .asciz  "Take your time."
msgRunOn:     .asciz  "In a hurry, marine?"
              .space  8                     ; Keep offsets; msgTexts is in
                                            ; vwcode.
;;; The key setup: the Doom key and the name of each action.
ctlKeys:      .word   KEY_FIRE, KEY_USE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT
              .word   KEY_STRAFELEFT, KEY_STRAFERIGHT, KEY_STRAFE, KEY_SPEED
ctlNames:     .long   txFire, txUse, txForward, txBackward, txTurnLeft
              .long   txTurnRight, txStrafeLeft, txStrafeRight, txStrafeOn, txRun
              .long   txDefaults
txFire:       .asciz  "FIRE"
txUse:        .asciz  "USE"
txForward:    .asciz  "FORWARD"
txBackward:   .asciz  "BACKWARD"
txTurnLeft:   .asciz  "TURN LEFT"
txTurnRight:  .asciz  "TURN RIGHT"
txStrafeLeft: .asciz  "STRAFE LEFT"
txStrafeRight: .asciz "STRAFE RIGHT"
txStrafeOn:   .asciz  "STRAFE (HOLD)"
txRun:        .asciz  "RUN (HOLD)"
txDefaults:   .asciz  "DEFAULT KEYS"
txControls:   .asciz  "KEY SETUP"
txPress:      .asciz  "KEY / ESC CANCEL"
txNone:       .asciz  "---"
txComma:      .asciz  ", "
keyNames:
;;; The names of the ADB keys (key setup): 8 bytes each.
              .ascii  "A"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "S"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "D"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "F"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "H"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "G"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "Z"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "X"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "C"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "V"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "B"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "Q"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "W"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "E"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "R"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "Y"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "T"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "1"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "2"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "3"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "4"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "6"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "5"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "="
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "9"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "7"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "-"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "8"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "0"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "]"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "O"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "U"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "["
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "I"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "P"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "RETURN"
              .byte   0, 0
              .ascii  "L"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "J"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "'"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "K"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  ";"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "BSLASH"
              .byte   0, 0
              .ascii  "COMMA"
              .byte   0, 0, 0
              .ascii  "/"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "N"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "M"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "PERIOD"
              .byte   0, 0
              .ascii  "TAB"
              .byte   0, 0, 0, 0, 0
              .ascii  "SPACE"
              .byte   0, 0, 0
              .ascii  "GRAVE"
              .byte   0, 0, 0
              .ascii  "DELETE"
              .byte   0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "ESC"
              .byte   0, 0, 0, 0, 0
              .ascii  "CONTROL"
              .byte   0
              .ascii  "COMMAND"
              .byte   0
              .ascii  "SHIFT"
              .byte   0, 0, 0
              .ascii  "CAPS"
              .byte   0, 0, 0, 0
              .ascii  "OPTION"
              .byte   0, 0
              .ascii  "LEFT"
              .byte   0, 0, 0, 0
              .ascii  "RIGHT"
              .byte   0, 0, 0
              .ascii  "DOWN"
              .byte   0, 0, 0, 0
              .ascii  "UP"
              .byte   0, 0, 0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "KP ."
              .byte   0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "KP *"
              .byte   0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "KP +"
              .byte   0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "CLEAR"
              .byte   0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "KP /"
              .byte   0, 0, 0, 0
              .ascii  "ENTER"
              .byte   0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "KP -"
              .byte   0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "KP ="
              .byte   0, 0, 0, 0
              .ascii  "KP 0"
              .byte   0, 0, 0, 0
              .ascii  "KP 1"
              .byte   0, 0, 0, 0
              .ascii  "KP 2"
              .byte   0, 0, 0, 0
              .ascii  "KP 3"
              .byte   0, 0, 0, 0
              .ascii  "KP 4"
              .byte   0, 0, 0, 0
              .ascii  "KP 5"
              .byte   0, 0, 0, 0
              .ascii  "KP 6"
              .byte   0, 0, 0, 0
              .ascii  "KP 7"
              .byte   0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "KP 8"
              .byte   0, 0, 0, 0
              .ascii  "KP 9"
              .byte   0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "F5"
              .byte   0, 0, 0, 0, 0, 0
              .ascii  "F6"
              .byte   0, 0, 0, 0, 0, 0
              .ascii  "F7"
              .byte   0, 0, 0, 0, 0, 0
              .ascii  "F3"
              .byte   0, 0, 0, 0, 0, 0
              .ascii  "F8"
              .byte   0, 0, 0, 0, 0, 0
              .ascii  "F9"
              .byte   0, 0, 0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "F11"
              .byte   0, 0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "F13"
              .byte   0, 0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "F14"
              .byte   0, 0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "F10"
              .byte   0, 0, 0, 0, 0
              .ascii  "?"
              .byte   0, 0, 0, 0, 0, 0, 0
              .ascii  "F12"
              .byte   0, 0, 0, 0, 0
              .ascii  "MOUSE 2"
              .byte   0
              .ascii  "F15"
              .byte   0, 0, 0, 0, 0
              .ascii  "HELP"
              .byte   0, 0, 0, 0
              .ascii  "HOME"
              .byte   0, 0, 0, 0
              .ascii  "PAGE UP"
              .byte   0
              .ascii  "DEL"
              .byte   0, 0, 0, 0, 0
              .ascii  "F4"
              .byte   0, 0, 0, 0, 0, 0
              .ascii  "END"
              .byte   0, 0, 0, 0, 0
              .ascii  "F2"
              .byte   0, 0, 0, 0, 0, 0
              .ascii  "PAGE DN"
              .byte   0
              .ascii  "F1"
              .byte   0, 0, 0, 0, 0, 0
              .ascii  "R SHIFT"
              .byte   0
              .ascii  "R OPT"
              .byte   0, 0, 0
              .ascii  "R CTRL"
              .byte   0, 0
              .ascii  "MOUSE 1"
              .byte   0
              .ascii  "RESET"
              .byte   0, 0, 0

msgSaveFail:  .ascii  "Not saved: the disk is write\n"
              .ascii  "protected or cannot be written.\n\n"
              .asciz  "Press a key."

              .space  (0x82e - (. - menuDataStart))
                                      ; Keep other cfar at its cache slots.
              .section coldcode, text
menuColdStart:
itemRoutine:
              .word   .word0 newGame
              .word   .word0 options
              .word   .word0 loadGame
              .word   .word0 saveGame
              .word   .word0 quitDoom
              .word   .word0 quitDoom
              .word   .word0 chooseSkill
              .word   .word0 chooseSkill
              .word   .word0 chooseSkill
              .word   .word0 chooseSkill
              .word   .word0 chooseSkill
              .word   .word0 loadSelect
              .word   .word0 loadSelect
              .word   .word0 loadSelect
              .word   .word0 loadSelect
              .word   .word0 loadSelect
              .word   .word0 loadSelect
              .word   .word0 loadSelect
              .word   .word0 loadSelect
              .word   .word0 changeMessages
              .word   .word0 videoMenu
              .word   .word0 inputMenu
              .word   .word0 vwItem
              .word   .word0 vwItem
              .word   .word0 soundMenu
              .word   .word0 bindAction
              .word   .word0 bindAction
              .word   .word0 bindAction
              .word   .word0 bindAction
              .word   .word0 bindAction
              .word   .word0 bindAction
              .word   .word0 bindAction
              .word   .word0 bindAction
              .word   .word0 bindAction
              .word   .word0 bindAction
              .word   .word0 defaultKeys
              .word   .word0 saveSelect
              .word   .word0 saveSelect
              .word   .word0 saveSelect
              .word   .word0 saveSelect
              .word   .word0 saveSelect
              .word   .word0 saveSelect
              .word   .word0 saveSelect
              .word   .word0 saveSelect
              .word   .word0 viewSize
              .word   .word0 changeGamma
              .word   .word0 sfxVolume
              .word   .word0 musicVolume
              .word   .word0 changeAlwaysRun
              .word   .word0 changeMouse
              .word   .word0 changeMouseSpeed
              .word   .word0 changeMouseMove
              .word   .word0 controls
menuDraw:     .word   .word0 drawMain, .word0 drawNewGame, .word0 drawLoad
              .word   .word0 drawOptions, .word0 drawControls, .word0 drawSave
              .word   .word0 drawOptions, .word0 drawOptions, .word0 drawOptions

;;; ---------------------------------------------------------------------------
;;; void M_Init(void): the main menu, no message; the lumps of the patches
;;; and the font, the rectangle of the skulls; the save game strings.
;;; ---------------------------------------------------------------------------
              .public M_Init
M_Init:       stz     .near currentMenu     ; MENU_MAIN
              lda     ##0xffff              ; no key setup
              sta     .near bindRow
              stz     .near _g_menuactive
              stz     .near whichSkull
              lda     ##10
              sta     .near skullAnimCounter
              stz     .near messageToPrint
              stz     .near messageLastMenuActive
              stz     .near MM_I            ; the lumps
1$:           lda     .near MM_I
              asl     a
              asl     a
              asl     a
              clc
              adc     ##.word0 lumpNames
              sta     dp:.tiny _Dp
              lda     ##.word2 lumpNames
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              jsl     long:W_GetNumForName
              pha
              lda     .near MM_I
              asl     a
              tax
              pla
              sta     .near LUMPS,x
              inc     .near MM_I
              lda     .near MM_I
              cmp     ##NUM_LUMPS
              bcc     1$
              lda     .near (LUMPS+L_FONT)  ; the lump of character 0
              sec
              sbc     ##HU_FONTSTART
              sta     .near fontLumpOffset
              lda     ##0x7fff              ; Bounds include both skull patches.
              sta     .near SK_DX
              sta     .near SK_DY
              lda     ##0x8000
              sta     .near SK_W
              sta     .near SK_H
              lda     .near (LUMPS+L_SKULL1)
              jsr     .kbank skullBox
              lda     .near (LUMPS+L_SKULL2)
              jsr     .kbank skullBox
              lda     .near SK_W
              sec
              sbc     .near SK_DX
              sta     .near SK_W
              lda     .near SK_H
              sec
              sbc     .near SK_DY
              sta     .near SK_H
              jmp     long:uiInit

;;; skullBox: the patch C in the box: SK_DX, SK_DY the smallest -leftoffset
;;; and -topoffset, SK_W, SK_H the largest right and bottom (signed).
skullBox:     jsl     long:W_GetLumpByNum
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##OFS_PATCH_LEFTOFFSET
              lda     ##0
              sec
              sbc     [.tiny _Dp],y
              ldx     ##0
              jsr     .kbank boxSide
              ldy     ##OFS_PATCH_TOPOFFSET
              lda     ##0
              sec
              sbc     [.tiny _Dp],y
              ldx     ##2
              ldy     ##OFS_PATCH_HEIGHT
              bra     boxSide2
;;; boxSide: with C = the left (X = 0) or top (X = 2) from the place, and Y
;;; the offset of the width or height.
boxSide:      ldy     ##OFS_PATCH_WIDTH
boxSide2:     pha
              sec                           ; less than SK_DX[X]
              sbc     .near SK_DX,x
              bvc     1$
              eor     ##0x8000
1$:           bpl     2$
              lda     1,s
              sta     .near SK_DX,x
2$:           pla                           ; the far side more than SK_W[X]
              clc
              adc     [.tiny _Dp],y
              pha
              lda     .near SK_W,x
              sec
              sbc     1,s
              bvc     3$
              eor     ##0x8000
3$:           bpl     4$
              lda     1,s
              sta     .near SK_W,x
4$:           pla
              rts

;;; ---------------------------------------------------------------------------
;;; void M_StartControlPanel(void): the main menu comes up.
;;; ---------------------------------------------------------------------------
              .public M_StartControlPanel
M_StartControlPanel:
              lda     .near _g_menuactive
              bne     1$
              inc     .near _g_menuactive
              stz     .near currentMenu     ; MENU_MAIN
              inc     .near menuversion     ; drawn: also when G_Responder
1$:           jmp     long:uiMain           ; Title/demo has no END GAME.

;;; ---------------------------------------------------------------------------
;;; uint16_t M_DrawVersion(void), M_SkullVersion(void): the versions of the
;;; menu drawing and of the skull.
;;; ---------------------------------------------------------------------------
              .public M_DrawVersion, M_SkullVersion
M_DrawVersion:
              lda     .near menuversion
              rtl
M_SkullVersion:
              lda     .near skullversion
              rtl

;;; ---------------------------------------------------------------------------
;;; void M_Ticker(void): the key of the key setup (I_StartTic took it; Esc:
;;; no change); the skull blinks each 8 tics.
;;; ---------------------------------------------------------------------------
              .public M_Ticker
M_Ticker:     lda     .near bindRow
              bmi     3$
              lda     .near iigs_bindwait
              bne     3$
              ldx     .near iigs_bindcode
              cpx     ##ADB_ESC
              beq     21$
              lda     .near bindRow
              asl     a
              tax
              lda     long:ctlKeys,x
              ldx     .near iigs_bindcode
              jsl     long:I_BindKey
21$:          lda     ##0xffff
              sta     .near bindRow
              inc     .near menuversion
3$:           dec     .near skullAnimCounter
              beq     1$
              bpl     2$
1$:           lda     .near whichSkull
              eor     ##1
              sta     .near whichSkull
              lda     ##8
              sta     .near skullAnimCounter
              inc     .near skullversion
2$:           rtl

;;; ---------------------------------------------------------------------------
;;; boolean M_Responder(event_t* ev)       In: _Dp[0-3] = ev.
;;; An eaten event that only moves the skull changes M_SkullVersion; any
;;; other change of the menu changes M_DrawVersion.
;;; ---------------------------------------------------------------------------
              .public M_Responder
M_Responder:  lda     .near currentMenu     ; the state before
              sta     .near MR_MENU
              lda     .near itemOn
              sta     .near MR_ITEM
              lda     .near _g_menuactive
              sta     .near MR_ACTIVE
              lda     .near messageToPrint
              sta     .near MR_MSG
              jsr     .kbank responderEvent
              bcs     1$
              lda     ##0
              rtl
1$:           lda     .near currentMenu     ; only the skull moved
              cmp     .near MR_MENU
              bne     2$
              lda     .near _g_menuactive
              cmp     .near MR_ACTIVE
              bne     2$
              lda     .near messageToPrint
              cmp     .near MR_MSG
              bne     2$
              lda     .near _g_menuactive
              beq     2$
              lda     .near messageToPrint
              bne     2$
              lda     .near itemOn
              cmp     .near MR_ITEM
              beq     2$
              inc     .near skullversion
              bra     3$
2$:           inc     .near menuversion
3$:           lda     ##1
              rtl

;;; responderEvent: M_ResponderEvent: carry set if the event is eaten.
no:           clc
              rts
responderEvent:
              lda     [.tiny _Dp]           ; key downs only
              bne     no
              ldy     ##EV_DATA1
              lda     [.tiny _Dp],y
              sta     .near MR_CH
              lda     .near messageToPrint
              beq     3$
              lda     .near messageKind     ; a message: any key, or Y, N or
              cmp     ##MSG_SAVEDEAD        ;   escape
              bcs     2$
              lda     .near MR_CH
              cmp     ##'n'
              beq     2$
              cmp     ##'y'
              beq     2$
              cmp     .near key_escape
              bne     no
2$:           lda     .near messageLastMenuActive
              sta     .near _g_menuactive
              stz     .near messageToPrint
              ldx     ##0                   ; the answer: ch == 'y'
              lda     .near MR_CH
              cmp     ##'y'
              bne     21$
              inx
21$:          txa
              jsr     .kbank answer
              lda     .near messageKind     ; a failed save: back to its menu
              cmp     ##MSG_SAVEFAIL
              beq     22$
              jsr     .kbank clearMenus
22$:          lda     ##CONST_SFX_SWTCHX
              brl     soundYes
3$:           lda     .near _g_menuactive
              bne     4$
              jsl     long:vwKeys           ; Carry set: A is the key sound.
              bcc     no
              brl     soundYes
4$:           ldx     .near currentMenu
              lda     .near MR_CH
              cmp     .near key_menu_down
              bne     5$
              lda     .near itemOn          ; down: the next item, or the
              inc     a                     ;   first
              cmp     long:menuNum,x
              bcc     41$
              lda     ##0
41$:          sta     .near itemOn
              lda     ##CONST_SFX_PSTOP
              brl     soundYes
5$:           cmp     .near key_menu_up
              bne     6$
              lda     .near itemOn          ; up: the item before, or the last
              bne     51$
              lda     long:menuNum,x
51$:          dec     a
              sta     .near itemOn
              lda     ##CONST_SFX_PSTOP
              brl     soundYes
6$:           cmp     .near key_menu_left
              bne     7$
              lda     ##0                   ; left: an item with arrows, 0
              bra     71$
7$:           cmp     .near key_menu_right
              bne     8$
              lda     ##1                   ; right: 1
71$:          pha
              jsr     .kbank item
              lda     long:itemStatus,x
              cmp     ##2
              bne     72$
              phx
              lda     ##CONST_SFX_STNMOV
              jsr     .kbank sound
              plx
              lda     1,s
              jsr     (.kbank itemRoutine,x)
72$:          pla
              sec
              rts
8$:           cmp     .near key_menu_enter
              bne     9$
              jsr     .kbank item           ; enter: the routine of the item
              lda     long:itemStatus,x
              cmp     ##2
              bne     81$
              lda     ##1                   ; (with arrows: right)
              jsr     (.kbank itemRoutine,x)
              lda     ##CONST_SFX_STNMOV
              brl     soundYes
81$:          lda     .near itemOn
              jsr     (.kbank itemRoutine,x)
              lda     ##CONST_SFX_PISTOL
              brl     soundYes
9$:           cmp     .near key_menu_escape
              bne     10$
              bra     11$                   ; Esc returns to the parent menu.
              .space  7                     ; Keep later code at its slots.
10$:          cmp     .near key_fire        ; fire or Delete: back
              beq     11$
              cmp     .near key_menu_back
              beq     11$
              brl     no
11$:          lda     long:menuPrev,x       ; Back to the parent and its item;
              bpl     12$                   ; the main menu closes instead.
              jsr     .kbank clearMenus
              bra     13$
12$:          lda     long:menuPrevItem,x
              pha
              lda     long:menuPrev,x
              jsr     .kbank setupMenu
              pla
              sta     .near itemOn
13$:          lda     ##CONST_SFX_SWTCHX
soundYes:     jsr     .kbank sound
              sec
              rts


;;; item: X = the item under the skull (x 2).
item:         ldx     .near currentMenu
              lda     .near itemOn
              asl     a
              clc
              adc     long:menuItems,x
              tax
              rts

;;; sound: S_StartSound(NULL, C).
sound:        stz     dp:.tiny _Dp
              stz     dp:.tiny (_Dp+2)
              jsl     long:S_StartSound
              rts

;;; answer: the routine of the message, with C = the answer (1: yes).
answer:       ldx     .near messageKind
              cpx     ##MSG_NIGHTMARE
              bne     1$
              cmp     ##0                   ; nightmare: a new game
              beq     9$
              lda     ##NIGHTMARE
              jsl     long:G_DeferedInitNew
              rts
1$:           cpx     ##MSG_QUIT
              bne     2$
              cmp     ##0                   ; quit
              beq     9$
              jsl     long:I_Quit
              rts
2$:           cpx     ##MSG_SAVEDEAD
              bcs     9$
              cmp     ##0                   ; end game: the demo ends, the
              beq     9$                    ;   title comes
              lda     .near _g_singledemo
              beq     3$
              jsl     long:G_CheckDemoStatus
3$:           jsr     .kbank clearMenus
              jsl     long:D_StartTitle
9$:           rts

;;; clearMenus: M_ClearMenus: no menu. setupMenu: M_SetupNextMenu(C).
clearMenus:   jsl     long:I_MenuPaletteBack
              stz     .near _g_menuactive
              stz     .near itemOn
              rts
setupMenu:    sta     .near currentMenu
              stz     .near itemOn
              rts

;;; startMessage: M_StartMessage of the message C (MSG_*).
startMessage: sta     .near messageKind
              lda     .near _g_menuactive
              sta     .near messageLastMenuActive
              lda     ##1
              sta     .near messageToPrint
              sta     .near _g_menuactive
              jsl     long:uiOpen
              rts

;;; ---------------------------------------------------------------------------
;;; The routines of the items, with C = the choice.
;;; ---------------------------------------------------------------------------
newGame:      lda     ##MENU_NEW            ; the skill menu at "hurt me
              jsr     .kbank setupMenu      ;   plenty"
              lda     ##2
              sta     .near itemOn
              rts
options:      lda     ##MENU_OPTIONS
              bra     setupMenu
controls:     lda     ##MENU_CONTROLS
              bra     setupMenu
bindAction:   sta     .near bindRow         ; the next key is for this action
              lda     ##1
              sta     .near iigs_bindwait
              rts
defaultKeys:  jsl     long:I_DefaultKeys
              rts
loadGame:     lda     ##MENU_LOAD
              bra     setupMenu
saveGame:     lda     .near _g_usergame     ; M_SaveGame: a game of the
              ora     .near _g_demoplayback ;   player, or a demo
              bne     1$
              lda     ##MSG_SAVEDEAD
              bra     startMessage
1$:           lda     .near _g_gamestate    ; in a level
              bne     2$
              lda     ##MENU_SAVE
              bra     setupMenu
2$:           rts
quitDoom:     lda     ##MSG_QUIT
              bra     startMessage
endGame:      lda     ##MSG_ENDGAME
              bra     startMessage
chooseSkill:  cmp     ##NIGHTMARE           ; nightmare: are you sure
              bne     1$
              lda     ##MSG_NIGHTMARE
              jsr     .kbank startMessage
              stz     .near itemOn
              rts
1$:           jsl     long:G_DeferedInitNew
              brl     clearMenus
loadSelect:   jsl     long:G_LoadGame
              brl     clearMenus
saveSelect:   jsl     long:G_SaveGame       ; the slot in the settings file,
              jsl     long:G_SaveSettings   ;   then to the disk
              brl     saveDone
changeMessages:
              lda     ##1                   ; messages on or off
              sec
              sbc     .near showMessages
              sta     .near showMessages
              beq     1$
              lda     ##.word0 msgOn
              ldx     ##.word2 msgOn
              bra     2$
1$:           lda     ##.word0 msgOff
              ldx     ##.word2 msgOff
2$:           sta     .near (PL+OFS_PL_MESSAGE)
              stx     .near (PL+OFS_PL_MESSAGE+2)
              lda     ##1
              sta     .near _g_message_dontfuckwithme
              rts
changeAlwaysRun:
              lda     ##1                   ; always run on or off
              sec
              sbc     .near _g_alwaysRun
              sta     .near _g_alwaysRun
              beq     1$
              lda     ##.word0 msgRunOn
              ldx     ##.word2 msgRunOn
              bra     2$
1$:           lda     ##.word0 msgRunOff
              ldx     ##.word2 msgRunOff
2$:           sta     .near (PL+OFS_PL_MESSAGE)
              stx     .near (PL+OFS_PL_MESSAGE+2)
              rts
changeMouse:  lda     ##1                   ; the mouse on or off (its
              sec                           ;   buttons up)
              sbc     .near iigs_mouseon
              sta     .near iigs_mouseon
              jsl     long:IIGS_MouseUp
              rts
changeMouseMove:
              lda     ##1                   ; mouse forward and back
              sec
              sbc     .near iigs_mousemove
              sta     .near iigs_mousemove
              rts
              .space  5               ; Keep later coldcode entries fixed.
vwItem:       jsl     long:bmItem           ; BENCHMARK, SAVE SETTINGS
              rts
changeMouseSpeed:
              cmp     ##0                   ; the mouse speed 0-9
              bne     1$
              lda     .near iigs_mousespeed
              beq     2$
              dec     .near iigs_mousespeed
              rts
1$:           lda     .near iigs_mousespeed
              cmp     ##9
              bcs     2$
              inc     .near iigs_mousespeed
2$:           rts
changeGamma:  cmp     ##0                   ; gammatab has five rows: gamma 0-4.
              bne     1$
              lda     .near _g_gamma
              beq     3$
              dec     .near _g_gamma
              bra     3$
1$:           cmp     ##1
              bne     3$
              lda     .near _g_gamma
              cmp     ##4
              bcs     3$
              inc     .near _g_gamma
3$:           jsl     long:uiReload
              lda     ##0
              jsl     long:I_SetPalette
              rts

;;; ---------------------------------------------------------------------------
;;; void M_Drawer(void): the message, or the menu: its own patches, the
;;; items, the skull.
;;; ---------------------------------------------------------------------------
              .public M_Drawer
M_Drawer:     lda     .near messageToPrint
              beq     menu
              pei     dp:.tiny (_Dp+8)      ; (the saved scratch: the text)
              pei     dp:.tiny (_Dp+10)
              jsr     .kbank messagePanel
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              rtl
menu:         lda     .near _g_menuactive
              bne     1$
              rtl
1$:           jsl     long:I_MenuPalette
              ldx     .near currentMenu
              jsr     (.kbank menuDraw,x)
              ldx     .near currentMenu     ; the items
              lda     long:menuX,x
              sta     .near MD_X
              lda     long:menuY,x
              sta     .near MD_Y
              lda     long:menuNum,x
              sta     .near MD_N
              lda     long:menuItems,x
              sta     .near MD_I
              lda     long:menuLine,x
              sta     .near MD_H
2$:           ldx     .near MD_I
              lda     long:itemLump,x
              bmi     3$
              tay
              lda     .near MD_X
              ldx     .near MD_Y
              jsr     .kbank drawPatch
3$:           lda     .near MD_Y
              clc
              adc     .near MD_H
              sta     .near MD_Y
              inc     .near MD_I
              inc     .near MD_I
              dec     .near MD_N
              bne     2$
              jmp     long:bmMenu           ; (the text items, the skull)

;;; ---------------------------------------------------------------------------
;;; void M_DrawSkull(void): the skull at the item.
;;; ---------------------------------------------------------------------------
              .public M_DrawSkull
M_DrawSkull:  lda     .near whichSkull
              asl     a
              clc
              adc     ##L_SKULL1
              tay
              jsr     .kbank skullPlace
              jsr     .kbank drawPatch
              rtl

;;; skullPlace: C = the x, X = the y of the skull. Y stays.
skullPlace:   phy
              ldx     .near currentMenu
              lda     ##0                   ; itemOn * the line height
              ldy     .near itemOn
              beq     2$
1$:           clc
              adc     long:menuLine,x
              dey
              bne     1$
2$:           ply
              clc
              adc     long:menuY,x
              sec
              sbc     ##5
              pha
              lda     long:menuX,x
              sec
              sbc     ##SKULLXOFF
              plx
              rts

;;; ---------------------------------------------------------------------------
;;; boolean M_SkullRect(void): the rectangle of both skull patches in skx,
;;; sky, skw, skh of D_Display; false without a skull.
;;; ---------------------------------------------------------------------------
              .public M_SkullRect
M_SkullRect:  lda     .near messageToPrint
              bne     1$
              lda     .near _g_menuactive
              beq     1$
              jsr     .kbank skullPlace
              clc
              adc     .near SK_DX
              sta     .near skx
              txa
              clc
              adc     .near SK_DY
              sta     .near sky
              lda     .near SK_W
              sta     .near skw
              lda     .near SK_H
              sta     .near skh
              lda     ##1
              rtl
1$:           lda     ##0
              rtl

;;; drawPatch: the patch of LUMPS[Y] at x C, y X.
drawPatch:    stx     dp:.tiny _Dp
              tax
              lda     .near LUMPS,y
              sta     dp:.tiny (_Dp+4)
              txa
              jsl     long:V_DrawNumPatchNotScaled
              rts

;;; The menus.
drawMain:     lda     ##94                  ; M_DOOM
              ldx     ##2
              ldy     ##L_DOOM
              brl     centerPatch
drawNewGame:  lda     ##96                  ; M_NEWG, M_SKILL
              ldx     ##14
              ldy     ##L_NEWG
              jsr     .kbank centerPatch
              lda     ##54
              ldx     ##38
              ldy     ##L_SKILL
              brl     centerPatch
drawOptions:  rts
videoMenu:    lda     ##MENU_VIDEO
              brl     setupMenu
soundMenu:    lda     ##MENU_VIDEO
              brl     setupMenu
inputMenu:    lda     ##MENU_INPUT
              brl     setupMenu
viewSize:     pha
              lda     .near MR_CH
              cmp     .near key_menu_enter
              bne     1$
              pla
              jsl     long:uiViewCycle
              rts
1$:           pla
              jsl     long:uiViewChange
              rts
sfxVolume:    ldx     ##0
              jsl     long:uiVolume
              rts
musicVolume:  ldx     ##2
              jsl     long:uiVolume
              rts
messagePanel: jsl     long:uiMessage
              rts
uiLineWidth:  jsr     .kbank lineWidth
              rtl
uiWriteLine:  jsr     .kbank writeLine
              rtl
uiThermo:     jsr     .kbank thermo
              rtl
uiMessageText:jsr     .kbank drawMessage
              rtl

;;; Center a menu title patch. X = row, Y = lump index.
centerPatch:  phy
              phx
              lda     .near LUMPS,y
              jsl     long:V_NumPatchWidth
              lsr     a
              eor     ##0xffff
              sec
              adc     ##160
              plx
              ply
              brl     drawPatch

;;; onOff: the ON patch (C = 1) or the OFF patch (C = 0) at (TH_X, X).
onOff:        asl     a
              clc
              adc     ##L_MSGOFF
              tay
              lda     .near TH_X
              brl     drawPatch

;;; thermo: M_DrawThermo(TH_X, X, TH_N, C): the left end, TH_N middles, the
;;; right end, the dot at step C.
thermo:       asl     a
              asl     a
              clc
              adc     .near TH_X
              adc     ##8
              sta     .near TH_V
              stx     .near TH_Y
              lda     .near TH_X
              ldy     ##L_THERML
              jsr     .kbank drawPatch
              lda     .near TH_X
              clc
              adc     ##4
              sta     .near TH_X
1$:           lda     .near TH_X
              clc
              adc     ##4
              sta     .near TH_X
              ldx     .near TH_Y
              ldy     ##L_THERMM
              dec     .near TH_N
              bmi     2$
              jsr     .kbank drawPatch
              bra     1$
2$:           ldy     ##L_THERMR
              jsr     .kbank drawPatch
              lda     .near TH_V
              ldx     .near TH_Y
              ldy     ##L_THERMO
              brl     drawPatch
;;; drawControls: the key setup: the title, each action with its first two
;;; keys (I_ActionKeys), or the request for a key.
drawControls:               lda     ##4
              sta     .near MT_Y
              lda     ##.word0 txControls
              ldx     ##.word2 txControls
              jsl     long:uiCenter
              stz     .near CT_I
1$:           lda     .near CT_I            ; the name at (48, 24 + 16 i)
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     ##24
              sta     .near CT_Y
              sta     .near MT_Y
              lda     ##48
              sta     .near MT_X
              lda     .near CT_I
              asl     a
              asl     a
              tax
              lda     long:(ctlNames+2),x
              pha
              lda     long:ctlNames,x
              plx
              jsr     .kbank text
              lda     .near CT_I            ; the keys at x = 176
              cmp     ##CONTROLS
              bcs     8$
              lda     ##176
              sta     .near MT_X
              lda     .near CT_Y
              sta     .near MT_Y
              lda     .near CT_I
              cmp     .near bindRow
              bne     2$
              lda     ##.word0 txPress
              ldx     ##.word2 txPress
              jsr     .kbank text
              bra     8$
2$:           asl     a
              tax
              lda     long:ctlKeys,x
              jsl     long:I_ActionKeys
              stx     .near CT_K
              cmp     ##0xffff
              bne     3$
              lda     ##.word0 txNone
              ldx     ##.word2 txNone
              jsr     .kbank text
              bra     8$
3$:           jsr     .kbank keyName
              lda     .near CT_K
              bmi     8$
              lda     ##.word0 txComma
              ldx     ##.word2 txComma
              jsr     .kbank text
              lda     .near CT_K
              jsr     .kbank keyName
8$:           inc     .near CT_I
              lda     .near CT_I
              cmp     ##(CONTROLS + 1)
              bcs     9$
              brl     1$
9$:           rts

;;; keyName: the name of the ADB key C at (MT_X, MT_Y).
keyName:      asl     a
              asl     a
              asl     a
              clc
              adc     ##.word0 keyNames
              ldx     ##.word2 keyNames

;;; text: M_WriteText of the string at X:C at (MT_X, MT_Y); MT_X moves on.
text:         pei     dp:.tiny (_Dp+8)
              pei     dp:.tiny (_Dp+10)
              sta     dp:.tiny (_Dp+8)
              stx     dp:.tiny (_Dp+10)
              stz     .near MT_P
              jsr     .kbank writeLine
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              rts

drawSave:     ldy     ##L_SAVEG             ; M_SAVEG, or M_LOADG, then the
              bra     drawSlots             ;   slots
drawLoad:     ldy     ##L_LOADG
drawSlots:    lda     ##72
              ldx     ##8
              jsr     .kbank centerPatch
              stz     .near MM_I            ; the 8 slots at y = 34 + 13 i
              lda     ##34
              sta     .near MM_Y
1$:           lda     ##104                  ; the border
              ldx     .near MM_Y
              ldy     ##L_LSLEFT
              jsr     .kbank drawPatch
              lda     ##112
              sta     .near MM_X
2$:           lda     .near MM_X
              ldx     .near MM_Y
              ldy     ##L_LSCNTR
              jsr     .kbank drawPatch
              lda     .near MM_X
              clc
              adc     ##8
              sta     .near MM_X
              cmp     ##(112 + 12 * 8)
              bcc     2$
              ldx     .near MM_Y
              ldy     ##L_LSRGHT
              jsr     .kbank drawPatch
              pei     dp:.tiny (_Dp+8)      ; its string at (112, y - 7)
              pei     dp:.tiny (_Dp+10)
              lda     .near MM_I
              asl     a
              asl     a
              asl     a
              clc
              adc     ##.near _g_savegamestrings
              sta     dp:.tiny (_Dp+8)
              lda     ##.word2 _g_savegamestrings
              sta     dp:.tiny (_Dp+10)
              stz     .near MT_P
              lda     ##112
              sta     .near MT_X
              lda     .near MM_Y
              sec
              sbc     ##7
              sta     .near MT_Y
              jsr     .kbank writeLine
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              lda     .near MM_Y
              clc
              adc     ##13
              sta     .near MM_Y
              inc     .near MM_I
              lda     .near MM_I
              cmp     ##8
              bcc     1$
              rts

;;; ---------------------------------------------------------------------------
;;; Text.
;;; ---------------------------------------------------------------------------

;;; drawMessage: each line centered at x 160, the block at y 100.
;;; Blank lines separate the question and its response keys.
drawMessage:  ldx     .near messageKind
              lda     long:msgTexts,x
              sta     dp:.tiny (_Dp+8)
              lda     long:(msgTexts+2),x
              sta     dp:.tiny (_Dp+10)
              lda     ##HU_FONT_HEIGHT      ; M_StringHeight
              sta     .near MT_Y
              ldy     ##0
1$:           lda     [.tiny (_Dp+8)],y
              and     ##0x00ff
              beq     3$
              cmp     ##10
              bne     2$
              lda     .near MT_Y
              clc
              adc     ##HU_FONT_HEIGHT
              sta     .near MT_Y
2$:           iny
              bra     1$
3$:           lda     .near MT_Y            ; y = 100 - height / 2
              lsr     a
              eor     ##0xffff
              sec
              adc     ##100
              sta     .near MT_Y
              stz     .near MT_P
4$:           ldy     .near MT_P            ; each line
              lda     [.tiny (_Dp+8)],y
              and     ##0x00ff
              beq     9$
              jsr     .kbank lineWidth      ; x = 160 - width / 2
              lsr     a
              eor     ##0xffff
              sec
              adc     ##160
              sta     .near MT_X
              jsr     .kbank writeLine
              lda     .near MT_Y
              clc
              adc     ##HU_FONT_HEIGHT
              sta     .near MT_Y
              ldy     .near MT_P            ; after a line break the next
              lda     [.tiny (_Dp+8)],y     ;   line
              and     ##0x00ff
              beq     9$
              inc     .near MT_P
              bra     4$
9$:           rts

;;; lineWidth: C = M_StringWidth of the line at [_Dp+8] from MT_P (to a 0 or
;;; a line break).
lineWidth:    stz     .near MT_W
              ldy     .near MT_P
1$:           lda     [.tiny (_Dp+8)],y
              and     ##0x00ff
              beq     9$
              cmp     ##10
              beq     9$
              iny
              phy
              jsr     .kbank fontLump
              bcc     2$
              jsl     long:V_NumPatchWidth
              bra     3$
2$:           lda     ##HU_FONT_SPACE_WIDTH
3$:           clc
              adc     .near MT_W
              sta     .near MT_W
              ply
              bra     1$
9$:           lda     .near MT_W
              rts

;;; writeLine: M_WriteText of the line at [_Dp+8] from MT_P (to a 0 or a line
;;; break) at MT_X, MT_Y; MT_P at the end.
writeLine:    ldy     .near MT_P
              lda     [.tiny (_Dp+8)],y
              and     ##0x00ff
              beq     9$
              cmp     ##10
              beq     9$
              inc     .near MT_P
              jsr     .kbank fontLump
              bcc     1$
              jsl     long:W_GetLumpByNum   ; the patch, its width
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              lda     [.tiny (_Dp+4)]       ; (OFS_PATCH_WIDTH 0)
              pha
              lda     .near MT_Y
              sta     dp:.tiny _Dp
              lda     .near MT_X
              jsl     long:V_DrawPatchNotScaled
              pla
              bra     2$
1$:           lda     ##HU_FONT_SPACE_WIDTH
2$:           clc
              adc     .near MT_X
              sta     .near MT_X
              bra     writeLine
9$:           rts

;;; fontLump: carry set and C = the lump of the character C (as toupper) in
;;; the font; carry clear if it is not in the font.
fontLump:     cmp     ##'a'
              bcc     1$
              cmp     ##('z' + 1)
              bcs     1$
              sbc     ##('a' - 'A' - 1)     ; (carry clear)
1$:           cmp     ##HU_FONTSTART
              bcc     2$
              cmp     ##(HU_FONTEND + 1)
              bcs     3$
              adc     .near fontLumpOffset  ; (carry clear)
              sec
2$:           rts
3$:           clc
              rts

;;; saveDone: after the write of a saved game (carry set: it failed,
;;; saveFailed). M_SaveFailed: the message for a failed write. After its
;;; key the menu stays for another try (settingsKnown keeps SAVE SETTINGS
;;; lit).
saveDone:     bcs     1$
              lda     ##.word0 strGameSaved ; (shown when the menu closes)
              sta     .near (PL+OFS_PL_MESSAGE)
              lda     ##.word2 strGameSaved
              sta     .near (PL+OFS_PL_MESSAGE+2)
              brl     clearMenus
1$:           jmp     long:saveFailed
              .public M_SaveFailed
M_SaveFailed: lda     ##MSG_SAVEFAIL
              jsr     .kbank startMessage
              rtl

              .space  (0x93d - (. - menuColdStart))
                                      ; Keep other coldcode at its slots.
              .section detailimg, text
menuDetailPad: .byte   0               ; Retain the reserved detailimg bytes.
              .space  78

;;; vwKeys: M_Responder with no menu. Escape stops a benchmark and opens
;;; the menu. In a level, the automap zoom keys step through uiSizes
;;; only while the automap and benchmark are off (viewwin.inc).
;;; A/X/Y 16-bit. Carry set: key handled, A = sound; clear: unhandled.
              .section vwcode, text
vwKeys:       lda     .near _g_gamestate
              bne     5$
              jsr     .kbank bmRuns
              bcs     5$
              lda     .near automapmode     ; Leave zoom keys to the automap.
              and     ##1
              bne     5$
              lda     .near MR_CH
              cmp     .near key_map_zoomout
              beq     6$
              cmp     .near key_map_zoomin
              bne     5$
              lda     ##1
              bra     7$
6$:           lda     ##0
              bra     7$
5$:           lda     .near MR_CH           ; escape: the menu
              cmp     .near key_escape
              bne     9$
              jsr     .kbank bmStop
              jsl     long:M_StartControlPanel
              lda     ##CONST_SFX_SWTCHN
              sec
              rtl
7$:           jsl     long:uiViewChange
              lda     ##CONST_SFX_STNMOV
              sec
              rtl
9$:           clc
              rtl

;;; ---------------------------------------------------------------------------
;;; Benchmark: demo3 at the selected detail, view size and normal game
;;; tic rate. FPS counts drawn frames, not game tics.
;;; Escape stops it. The -timedemo build still uses one tic per frame.
;;; ---------------------------------------------------------------------------
ZIPLOCK       .equ    0xe0c05a        ; Four $5A writes unlock; $A5 locks.
ZIPSTAT       .equ    0xe0c05b        ; Unlocked bits 0-1: cache size.
ZIPSLOT       .equ    0xe0c05c        ; Slot delay flags.
TW_ID         .equ    0xbcff00        ; TransWarp GS firmware signature: "TWGS".
TW_CACHESIZE  .equ    0xbcff44        ; Get cache size in KB.
TW_IRQOFF     .equ    0xbcff34        ; Disable slowdown while I is set.
TW_GETCFG     .equ    0xbcff3c        ; GetTWConfig.
TW_SETCFG     .equ    0xbcff40        ; SetTWConfig.
ROM_IDY       .equ    0xfffb59        ; ROM ID ($FE1F) result Y: version.

msgTexts:     .long   msgNightmare, msgQuit, msgEndGame, msgSaveDead
              .long   VW_BTXT, msgSaveFail
txBench:      .asciz  "BENCHMARK"
txSaveSet:    .asciz  "SAVE SETTINGS"
txDemo3:      .asciz  "demo3"
txBZip:       .asciz  "ZIPGS "
txBTw:        .asciz  "TRANSWARP GS "
txBNative:    .asciz  "65C816 "
txBMhz:       .asciz  " MHZ"
txBKb:        .asciz  " KB"
txBNone:      .asciz  "NONE"

;;; SAVE SETTINGS is dim while its current values match the saved ones.
BM_BOXL       .equ    30
BM_BOXR       .equ    84
BM_BOXY       .equ    138
SHRBACK       .equ    0x012000
bmMenu:       jmp     long:uiSettings

;;; bmBox: the box of SAVE SETTINGS black (C = 0), or its text dim (C = 1:
;;; alternate pixels darkened on odd rows). Keep full rows between them
;;; so the seven-row letters stay legible. Mark the box for the next update.
bmBox:        sta     dp:.tiny (_Dp+2)      ; (the mode)
              lda     ##(BM_BOXY * 160 + BM_BOXL)
              sta     dp:.tiny (_Dp+6)      ; (the first byte of the row)
              ldy     ##0
1$:           lda     dp:.tiny (_Dp+2)      ; the mask of the row
              beq     2$
              tya
              lsr     a
              lda     ##0x00ff
              bcc     2$
              tya
              lsr     a
              lsr     a
              lda     ##0x00f0
              bcc     2$
              lda     ##0x000f
2$:           sta     dp:.tiny (_Dp+4)
              lda     dp:.tiny (_Dp+6)
              clc
              adc     ##(BM_BOXR - BM_BOXL + 1)
              sta     dp:.tiny _Dp          ; (the end of the row)
              ldx     dp:.tiny (_Dp+6)
              sep     #0x20
3$:           lda     long:SHRBACK,x
              and     dp:.tiny (_Dp+4)
              sta     long:SHRBACK,x
              inx
              cpx     dp:.tiny _Dp
              bcc     3$
              rep     #0x20
              lda     dp:.tiny (_Dp+6)
              clc
              adc     ##160
              sta     dp:.tiny (_Dp+6)
              iny
              cpy     ##HU_FONT_HEIGHT
              bcc     1$
              lda     ##BM_BOXY
              ldx     ##(BM_BOXY + HU_FONT_HEIGHT)
              ldy     ##(BM_BOXL | (BM_BOXR << 8))
              jsl     long:I_MarkRect
              rts

;;; bmWrite: draw the string at X:C at (MT_X, MT_Y); advance MT_X.
bmWrite:      pei     dp:.tiny (_Dp+8)
              pei     dp:.tiny (_Dp+10)
              sta     dp:.tiny (_Dp+8)
              stx     dp:.tiny (_Dp+10)
              ldy     ##0
1$:           lda     [.tiny (_Dp+8)],y
              and     ##0x00ff
              beq     9$
              iny
              phy
              cmp     ##'a'                 ; (upper case)
              bcc     2$
              cmp     ##('z' + 1)
              bcs     2$
              sbc     ##('a' - 'A' - 1)     ; (carry clear)
2$:           cmp     ##HU_FONTSTART
              bcc     4$
              cmp     ##(HU_FONTEND + 1)
              bcs     4$
              adc     .near fontLumpOffset  ; (carry clear)
              jsl     long:W_GetLumpByNum   ; the patch, its width
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              lda     [.tiny (_Dp+4)]       ; (OFS_PATCH_WIDTH 0)
              pha
              lda     .near MT_Y
              sta     dp:.tiny _Dp
              lda     .near MT_X
              jsl     long:V_DrawPatchNotScaled
              pla
              bra     5$
4$:           lda     ##HU_FONT_SPACE_WIDTH
5$:           clc
              adc     .near MT_X
              sta     .near MT_X
              ply
              bra     1$
9$:           pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              rts

;;; ---------------------------------------------------------------------------
;;; LOADING... and SAVING...: centered red text on black.
;;; ---------------------------------------------------------------------------
BUSY_MARGIN   .equ    4               ; black pixels around the text (bmMargin)
BUSY_H        .equ    24              ; its height: 2 x 8 font rows + 2 margins
BUSY_Y        .equ    88              ; (200 - BUSY_H) / 2
BUSY_BAND     .equ    (BUSY_H * 160)  ; the screen bytes of its rows
BUSY_SAVE     .equ    MM_BUSY         ; the rows of the sign as they were: the
BUSY_BACK     .equ    (BUSY_SAVE + BUSY_BAND) ;   screen, the back buffer
BUSY_PATCH    .equ    (BUSY_BACK + BUSY_BAND) ; the sign as a patch (MM_BUSY: 16 KB)
SHR_PIX       .equ    0xe12000
txLoading:    .asciz  "LOADING..."
txSaving:     .asciz  "SAVING..."
txInsert:     .ascii  "INSERT DISK "
txInsertN:    .asciz  "1"                   ; (bmDiskAsk writes the digit)

              .public bmLoad, bmSave, bmSaved, bmDiskOn, bmDiskOff
              .public bmSignOn, bmSignOff, bmDiskAsk, bmSignLoading, bmSignSaving
;;; A new life on the same map reloads it from memory in under a second, so
;;; it gets no sign (the sign costs about 40 ms; it is shown only on
;;; steps of more than a couple of seconds). W_SET: the set in the level
;;; window (src/iigs/w_level65.s); after a title or intermission picture
;;; the map loads again.
bmLoad:       pha
              lda     .near _g_gamemap
              cmp     long:W_SET
              beq     1$
              sta     long:VW_LMAP
              lda     ##.word0 txLoading
              jsl     long:bmSignOn
              pla
              jsl     long:P_SetupLevel
              jmp     long:W_LevelDone      ; (the automap cache, bmSignOff)
1$:           pla
              jmp     long:P_SetupLevel
bmSave:       lda     ##.word0 txSaving
              jsl     long:bmSignOn
              jsr     .kbank bmTwOwner      ; Disk I/O uses the entry config.
              jmp     long:IIGS_StopInterrupts
bmSaved:      jsl     long:IIGS_StartInterrupts
              jsr     .kbank bmTwFast
              jmp     long:bmSignOff
;;; bmDiskOn/bmDiskOff: around the disk reads of a level load (the level
;;; loader of src/iigs/p_setup65.s): the same state as bmSave and bmSaved,
;;; without the sign (bmLoad shows it for the whole load).
bmDiskOn:     jsr     .kbank bmTwOwner
              jmp     long:IIGS_StopInterrupts
bmDiskOff:    jsl     long:IIGS_StartInterrupts
              jsr     .kbank bmTwFast
              rtl

;;; bmSignOn: the sign with the text at C (in this bank). The first time the
;;; rows of the sign are saved; a new text while the sign is on puts them
;;; back first, so any text width works (the level loader: "INSERT DISK n",
;;; then "LOADING..." again). bmSignOff: the rows as they were. A/X/Y 16-bit;
;;; _Dp[8-11] kept. The sign is a patch in RAM: a new WAD lump would move
;;; the lumps after it and the bytes of the texture over-reads with them.
bmSignOn:     pha
              ldy     ##1                   ; (on: the rows as they were first)
              lda     long:VW_SGON
              bne     1$
              ldy     ##0
              lda     ##1
              sta     long:VW_SGON
1$:           jsr     .kbank bmSignBox
              pla
              pei     dp:.tiny (_Dp+8)
              pei     dp:.tiny (_Dp+10)
              sta     dp:.tiny (_Dp+8)
              lda     ##.word2 txLoading
              sta     dp:.tiny (_Dp+10)
              jsr     .kbank bmSignPatch
              lda     ##BUSY_Y
              sta     dp:.tiny _Dp
              lda     ##.word0 BUSY_PATCH
              sta     dp:.tiny (_Dp+4)
              lda     ##.word2 BUSY_PATCH
              sta     dp:.tiny (_Dp+6)
              lda     long:VW_SGW           ; x = 160 - width / 2
              lsr     a
              eor     ##0xffff
              sec
              adc     ##160
              jsl     long:V_DrawPatchNotScaled
              jsl     long:I_ShowDirty
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              rtl
bmSignOff:    lda     long:VW_SGON
              beq     1$
              lda     ##0
              sta     long:VW_SGON
              ldy     ##1
              jsr     .kbank bmSignBox
1$:           rtl
;;; bmDiskAsk: the sign asks for disk C (1-9). bmSignLoading, bmSignSaving:
;;; "LOADING..." or "SAVING..." again after it.
bmDiskAsk:    sep     #0x20
              clc
              adc     #'0'
              sta     long:txInsertN
              rep     #0x20
              lda     ##.word0 txInsert
              bra     bmSignOn
bmSignLoading: lda    ##.word0 txLoading
              bra     bmSignOn
bmSignSaving: lda     ##.word0 txSaving
              bra     bmSignOn

;;; bmSignBox: Y = 0: the rows of the sign, from the screen and the back
;;; buffer to BUSY_SAVE and BUSY_BACK; Y = 1: back. The rows are one run of
;;; bytes, so one MVN each.
bmSignBox:    phb                           ; (MVN sets the data bank)
              tya
              bne     1$
              ldx     ##((SHR_PIX & 0xffff) + BUSY_Y * 160)
              ldy     ##(BUSY_SAVE & 0xffff)
              lda     ##(BUSY_BAND - 1)
;;; MVN bytes are opcode, destination bank, source bank. It changes DBR.
              .byte   0x54, MM_BUSY_BANK, 0xe1      ; (MVN to the sign bank)
              ldx     ##((SHRBACK & 0xffff) + BUSY_Y * 160)
              ldy     ##(BUSY_BACK & 0xffff)
              lda     ##(BUSY_BAND - 1)
              .byte   0x54, MM_BUSY_BANK, 0x01      ; (MVN to the sign bank)
              plb
              rts
1$:           ldx     ##(BUSY_SAVE & 0xffff)
              ldy     ##((SHR_PIX & 0xffff) + BUSY_Y * 160)
              lda     ##(BUSY_BAND - 1)
              .byte   0x54, 0xe1, MM_BUSY_BANK      ; (MVN from the sign bank)
              ldx     ##(BUSY_BACK & 0xffff)
              ldy     ##((SHRBACK & 0xffff) + BUSY_Y * 160)
              lda     ##(BUSY_BAND - 1)
              .byte   0x54, 0x01, MM_BUSY_BANK      ; (MVN from the sign bank)
              plb
              rts

;;; bmSignPatch: BUSY_PATCH = the text at [_Dp+8] in the STCFN font, each
;;; pixel doubled, between black margins: one post of BUSY_H pixels in each
;;; column (color 0, black, where the font has none). VW_SGW = its width.
bmSignPatch:  lda     ##(2 * BUSY_MARGIN)   ; the width first
              sta     long:VW_SGW
              ldy     ##0
1$:           lda     [.tiny (_Dp+8)],y
              and     ##0x00ff
              beq     3$
              iny
              phy
              jsr     .kbank bmGlyph
              bcc     2$
              lda     [.tiny (_Dp+4)]       ; (the glyph width)
              bra     21$
2$:           lda     ##HU_FONT_SPACE_WIDTH
21$:          asl     a
              clc
              adc     long:VW_SGW
              sta     long:VW_SGW
              ply
              bra     1$
3$:           lda     ##0                   ; the header: width, height, no
              sta     long:(BUSY_PATCH+4)   ;   offsets
              sta     long:(BUSY_PATCH+6)
              sta     long:VW_SGC
              lda     ##BUSY_H
              sta     long:(BUSY_PATCH+2)
              lda     long:VW_SGW
              sta     long:BUSY_PATCH
              asl     a                     ; the column data after the offsets
              asl     a
              clc
              adc     ##8
              sta     long:VW_SGD
              ldx     ##BUSY_MARGIN
              jsr     .kbank bmBlanks
              ldy     ##0
4$:           lda     [.tiny (_Dp+8)],y
              and     ##0x00ff
              beq     9$
              iny
              phy
              jsr     .kbank bmGlyph
              bcs     5$
              ldx     ##(2 * HU_FONT_SPACE_WIDTH)
              jsr     .kbank bmBlanks
              bra     8$
5$:           lda     ##0                   ; each glyph column, twice
6$:           pha
              jsr     .kbank bmGlyphCol
              jsr     .kbank bmPut
              jsr     .kbank bmPut
              pla
              inc     a
              cmp     [.tiny (_Dp+4)]
              bcc     6$
8$:           ply
              bra     4$
9$:           ldx     ##BUSY_MARGIN
              ; (falls into bmBlanks)

;;; bmBlanks: X black columns.
bmBlanks:     phx
              lda     ##0
              sta     long:VW_SGCOL
              sta     long:(VW_SGCOL+2)
              sta     long:(VW_SGCOL+4)
              sta     long:(VW_SGCOL+6)
              jsr     .kbank bmPut
              plx
              dex
              bne     bmBlanks
              rts

;;; bmGlyph: carry set and [_Dp+4] = the STCFN patch of the character C;
;;; carry clear for a space or a character the font does not have.
bmGlyph:      cmp     ##'a'
              bcc     1$
              cmp     ##('z' + 1)
              bcs     1$
              sbc     ##('a' - 'A' - 1)     ; (carry clear: upper case)
1$:           cmp     ##HU_FONTSTART
              bcc     9$
              cmp     ##(HU_FONTEND + 1)
              bcs     8$
              adc     .near fontLumpOffset  ; (carry clear)
              jsl     long:W_GetLumpByNum
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              sec
              rts
8$:           clc
9$:           rts

;;; bmGlyphCol: VW_SGCOL = column C of the glyph at [_Dp+4], 0 where the
;;; column has no post (the font is 7 rows; rows past 7 are dropped).
bmGlyphCol:   asl     a                     ; its data: columnofs[C] (a lump
              asl     a                     ;   is less than 64 KB)
              clc
              adc     ##8
              tay
              lda     [.tiny (_Dp+4)],y
              tay
              lda     ##0
              sta     long:VW_SGCOL
              sta     long:(VW_SGCOL+2)
              sta     long:(VW_SGCOL+4)
              sta     long:(VW_SGCOL+6)
              sep     #0x20
1$:           lda     [.tiny (_Dp+4)],y     ; a post: row, length, pad, the
              cmp     #0xff                 ;   pixels, pad; $FF: the end
              beq     9$
              sta     long:VW_SGT
              iny
              lda     [.tiny (_Dp+4)],y
              sta     long:(VW_SGT+1)
              iny
              iny
2$:           lda     long:VW_SGT
              cmp     #8
              bcs     3$
              rep     #0x20
              and     ##0x00ff
              tax
              sep     #0x20
              lda     [.tiny (_Dp+4)],y
              sta     long:VW_SGCOL,x
3$:           iny
              lda     long:VW_SGT
              inc     a
              sta     long:VW_SGT
              lda     long:(VW_SGT+1)
              dec     a
              sta     long:(VW_SGT+1)
              bne     2$
              iny                           ; (the pad after the pixels)
              bra     1$
9$:           rep     #0x20
              rts

;;; bmPut: the next patch column from VW_SGCOL: its offset, then one post
;;; of BUSY_H pixels (margin, each glyph row twice, margin).
bmPut:        lda     long:VW_SGC           ; columnofs[column] = its data
              asl     a
              asl     a
              tax
              lda     long:VW_SGD
              sta     long:(BUSY_PATCH+8),x
              lda     ##0
              sta     long:(BUSY_PATCH+10),x
              lda     long:VW_SGC
              inc     a
              sta     long:VW_SGC
              lda     ##.word0 VW_SGCOL     ; (for [_Dp],y)
              sta     dp:.tiny _Dp
              lda     ##.word2 VW_SGCOL
              sta     dp:.tiny (_Dp+2)
              lda     long:VW_SGD
              tax
              clc
              adc     ##(BUSY_H + 5)        ; row, length, pad, pixels, pad, $FF
              sta     long:VW_SGD
              sep     #0x20
              lda     #0
              sta     long:BUSY_PATCH,x     ; row 0
              sta     long:(BUSY_PATCH+2),x ; (pad)
              lda     #BUSY_H
              sta     long:(BUSY_PATCH+1),x ; length
              inx
              inx
              inx
              jsr     .kbank bmMargin
              ldy     ##0
1$:           lda     [.tiny _Dp],y
              sta     long:BUSY_PATCH,x
              sta     long:(BUSY_PATCH+1),x
              inx
              inx
              iny
              cpy     ##8
              bcc     1$
              jsr     .kbank bmMargin
              lda     #0                    ; pad, the end of the column
              sta     long:BUSY_PATCH,x
              lda     #0xff
              sta     long:(BUSY_PATCH+1),x
              rep     #0x20
              rts

;;; bmMargin: 4 black pixels at X (BUSY_MARGIN; 8-bit A).
bmMargin:     lda     #0
              sta     long:BUSY_PATCH,x
              sta     long:(BUSY_PATCH+1),x
              sta     long:(BUSY_PATCH+2),x
              sta     long:(BUSY_PATCH+3),x
              inx
              inx
              inx
              inx
              rts

;;; ---------------------------------------------------------------------------
;;; TWGS IRQ logic slows the card while I is set; gameplay disables it.
;;; Disk I/O and exit restore the entry config, including an OFF setting:
;;; the machine booted with that config.
;;; Firmware calls use native mode, A/X/Y 16-bit, free D = $0A00, IRQs masked.
;;; Calls preserve D, DBR and P here. Reset reloads the card settings.
;;; ---------------------------------------------------------------------------
              .public bmAccelOff, bmAccelBack
bmAccelOff:   jsl     long:IIGS_ZipOff
              lda     ##0
              sta     long:VW_TWON
              sta     long:VW_LMAP          ; (no map yet: the first load signs)
              sta     long:VW_SGON          ; (no sign)
              sep     #0x20
              lda     long:TW_ID            ; "TWGS"
              cmp     #'T'
              bne     9$
              lda     long:(TW_ID+1)
              cmp     #'W'
              bne     9$
              lda     long:(TW_ID+2)
              cmp     #'G'
              bne     9$
              lda     long:(TW_ID+3)
              cmp     #'S'
              bne     9$
              rep     #0x20
              php
              sei
              phb
              phd
              lda     ##0x0a00
              tcd
              jsl     long:TW_GETCFG
              sta     long:VW_TWOWN
              lda     ##VW_TWTAG
              sta     long:VW_TWON
              jsl     long:TW_IRQOFF
              pld
              plb
              plp
9$:           rep     #0x20
              rtl
bmAccelBack:  jsr     .kbank bmTwOwner
              lda     ##0
              sta     long:VW_TWON
              jmp     long:IIGS_ZipBack

;;; bmTwOwner: the owner's configuration of the entry (SetTWConfig);
;;; bmTwFast: the IRQ logic off again.
bmTwOwner:    lda     long:VW_TWON
              cmp     ##VW_TWTAG
              bne     9$
              php
              sei
              phb
              phd
              lda     ##0x0a00
              tcd
              lda     long:VW_TWOWN
              jsl     long:TW_SETCFG
              pld
              plb
              plp
9$:           rts
bmTwFast:     lda     long:VW_TWON
              cmp     ##VW_TWTAG
              bne     9$
              php
              sei
              phb
              phd
              lda     ##0x0a00
              tcd
              jsl     long:TW_IRQOFF
              pld
              plb
              plp
9$:           rts

;;; bmItem: the item C of OPTIONS: 3 BENCHMARK, 4 SAVE SETTINGS
;;; (the settings to the disk when they changed).
bmItem:       cmp     ##3
              beq     bmStart
              jsl     long:G_SettingsChanged
              cmp     ##0
              beq     9$
              jsl     long:G_SaveSettings
              bcc     9$
              jsl     long:M_SaveFailed
9$:           rtl

;;; saveFailed: the slots as the disk has them, then the message
;;; (startMessage returns to the menu responder).
saveFailed:   jsl     long:G_SaveUndo
              jsl     long:G_UpdateSaveGameStrings
              lda     ##MSG_SAVEFAIL
              jmp     long:startMessage

;;; bmStart: close the menu and time demo3 with normal game tics.
;;; Patch the four-byte LDA long at vwFrame to JSL bmTick so normal play
;;; has no frame-counter cost. bmTick repeats the displaced load; bmEnd
;;; restores it. The first instruction of vwFrame is part of this contract.
bmStart:      jsl     long:I_MenuPaletteBack
              stz     .near _g_menuactive
              stz     .near itemOn
              jsr     .kbank bmAccel
              jsr     .kbank bmClock
              lda     ##VW_BENCHTAG
              sta     long:VW_BENCH
              lda     ##1
              sta     .near _g_timingdemo
              lda     ##0
              sta     long:VW_BFRAMES
              sep     #0x20
              lda     #0x22
              sta     long:vwFrame
              rep     #0x20
              lda     ##.word0 bmTick
              sta     long:(vwFrame+1)
              lda     ##.word2 bmTick
              sep     #0x20
              sta     long:(vwFrame+3)
              rep     #0x20
              lda     ##.word0 txDemo3
              sta     dp:.tiny _Dp
              lda     ##.word2 txDemo3
              sta     dp:.tiny (_Dp+2)
              jmp     long:G_DeferedPlayDemo

;;; bmStop: escape while the benchmark runs: no timing, the demo ends (the
;;; next step of the title loop).
bmStop:       jsr     .kbank bmRuns
              bcc     9$
              jsr     .kbank bmEnd
              jsl     long:G_CheckDemoStatus
9$:           rts

;;; bmEnd: restore vwFrame as $AF followed by VW_INIT, low byte first.
bmEnd:        lda     ##0
              sta     long:VW_BENCH
              stz     .near _g_timingdemo
              lda     ##(0xaf | ((VW_INIT & 0xff) << 8))
              sta     long:vwFrame
              lda     ##(VW_INIT >> 8)
              sta     long:(vwFrame+2)
              rts

;;; bmTick: count the frame and repeat vwFrame's displaced LDA VW_INIT.
bmTick:       lda     long:VW_BFRAMES
              inc     a
              sta     long:VW_BFRAMES
              lda     long:VW_INIT
              rtl

;;; bmRuns: carry set while the benchmark runs (VW_BENCH alone can stay
;;; from before a restart).
bmRuns:       clc
              lda     .near _g_timingdemo
              beq     9$
              lda     long:VW_BENCH
              cmp     ##VW_BENCHTAG         ; (equal: carry set)
              beq     9$
              clc
9$:           rts

;;; bmAccel: VW_BACC = card bits (1 ZipGS, 2 TWGS), VW_BCACHE = KB,
;;; VW_BROM = ROM version. Probe writable slot flags (Zip Chip manual);
;;; without a ZipGS these are unused annunciator switches.
bmAccel:      php
              sei                           ; (no write between the unlock
              sep     #0x20                 ;   writes)
              lda     #0
              sta     long:VW_BACC
              sta     long:(VW_BACC+1)
              sta     long:VW_BCACHE
              sta     long:(VW_BCACHE+1)
              sta     long:(VW_BROM+1)
              lda     long:ROM_IDY
              sta     long:VW_BROM
              jsr     .kbank bmUnlock
              lda     long:ZIPSLOT
              pha
              eor     #0xff                 ; bits 0-3 (4-7 can follow the
              sta     long:ZIPSLOT          ;   disk motors)
              eor     long:ZIPSLOT
              and     #0x0f
              bne     1$
              lda     1,s
              sta     long:ZIPSLOT
              eor     long:ZIPSLOT
              and     #0x0f
              bne     1$
              lda     #1
              sta     long:VW_BACC
              lda     long:ZIPSTAT          ; the cache
              rep     #0x20
              and     ##3
              tax
              sep     #0x20
              lda     long:bmCacheKB,x
              sta     long:VW_BCACHE
1$:           pla
              sta     long:ZIPSLOT
              lda     #0xa5
              sta     long:ZIPLOCK
              lda     long:TW_ID
              cmp     #'T'
              bne     9$
              lda     long:(TW_ID+1)
              cmp     #'W'
              bne     9$
              lda     long:(TW_ID+2)
              cmp     #'G'
              bne     9$
              lda     long:(TW_ID+3)
              cmp     #'S'
              bne     9$
              lda     long:VW_BACC
              ora     #2
              sta     long:VW_BACC
              rep     #0x30                 ; the cache (its firmware: native
              phb                           ;   mode, 16-bit registers)
              phd
              lda     ##0x0a00
              tcd
              jsl     long:TW_CACHESIZE
              pld
              plb
              sta     long:VW_BCACHE
9$:           plp
              rts
bmCacheKB:    .byte   8, 16, 32, 64

;;; bmClock: VW_BKHZ = CPU kHz from the DOC timer (34.9404 Hz).
;;; $C02E would start the ZipGS counter delay. The two loops differ by
;;; 672 cycles per pass, cancelling the shared cost of reading the timer.
BM_STEPS      .equ    17
BM_KHZ        .equ    393928506       ; 34.9404 x 672 / 1000 x 2^24
bmClock:      php
              sei
              lda     ##8
              jsr     .kbank bmPasses
              sta     long:VW_BQ
              txa
              sta     long:(VW_BQ+2)
              lda     ##40
              jsr     .kbank bmPasses
              sec                           ; B - A (2^24 x steps a pass)
              sbc     long:VW_BQ
              sta     dp:.tiny (_Dp+4)
              txa
              sbc     long:(VW_BQ+2)
              sta     dp:.tiny (_Dp+6)
              bmi     8$
              ora     dp:.tiny (_Dp+4)
              beq     8$
              lda     ##(BM_KHZ & 0xffff)
              sta     dp:.tiny _Dp
              lda     ##(BM_KHZ >> 16)
              sta     dp:.tiny (_Dp+2)
              jsl     long:_UDivMod32
              bra     9$
8$:           lda     ##0                   ; (no result)
9$:           sta     long:VW_BKHZ
              plp
              rts

;;; bmPasses: the loop with C x (8 NOP, DEY, BNE) in a pass, from an edge
;;; of the ramp to BM_STEPS steps or more after it: X:C = 2^24 x the steps /
;;; the passes. The ramp byte goes 254, 255, 255, 1: the steps are the sum
;;; of (new - old) & 255 (a hidden step comes with the next one).
bmPasses:     sta     dp:.tiny (_Dp+2)      ; the count of a pass
              sep     #0x20
              jsr     .kbank bmRamp
              sta     dp:.tiny _Dp
1$:           jsr     .kbank bmRamp         ; an edge
              cmp     dp:.tiny _Dp
              beq     1$
              sta     dp:.tiny _Dp
              stz     dp:.tiny (_Dp+1)      ; the steps
              ldx     ##0                   ; the passes
2$:           ldy     dp:.tiny (_Dp+2)
3$:           nop
              nop
              nop
              nop
              nop
              nop
              nop
              nop
              dey
              bne     3$
              inx
              jsr     .kbank bmRamp
              cmp     dp:.tiny _Dp
              beq     2$
              pha
              sec
              sbc     dp:.tiny _Dp
              clc
              adc     dp:.tiny (_Dp+1)
              sta     dp:.tiny (_Dp+1)
              pla
              sta     dp:.tiny _Dp
              lda     dp:.tiny (_Dp+1)
              cmp     #BM_STEPS
              bcc     2$
              rep     #0x20
              and     ##0x00ff              ; steps << 24 / passes
              xba
              sta     dp:.tiny (_Dp+2)
              stz     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_UDivMod32
              rts

;;; bmRamp: A = the data register of the timer oscillator (readRamp of
;;; src/iigs/i_doc65.s). 8-bit A.
SOUNDCTL      .equ    0xe0c03c
SOUNDDATA     .equ    0xe0c03d
SOUNDADRL     .equ    0xe0c03e
bmRamp:       lda     long:SOUNDCTL
              bmi     bmRamp
              and     #0x0f
              sta     long:SOUNDCTL
              lda     #(0x60 + 31)          ; (TIMER_OSC)
              sta     long:SOUNDADRL
              lda     long:SOUNDDATA        ; Dummy read starts the DOC access.
              lda     long:SOUNDDATA
              rts

;;; bmUnlock: the four unlock writes of a ZipGS (8-bit A).
bmUnlock:     lda     #0x5a
              sta     long:ZIPLOCK
              sta     long:ZIPLOCK
              sta     long:ZIPLOCK
              sta     long:ZIPLOCK
              rts

;;; bmDone: G_CheckDemoStatus calls here with four 32-bit arguments at 4,s.
;;; A -timedemo build goes to I_Error. The menu benchmark shows a result
;;; without advancing past the demo end marker; the next tic ends it.
;;; Drop 16 argument bytes and the 3-byte JSL return to bypass the rest
;;; of G_CheckDemoStatus; RTL uses its caller's return address.
              .public bmDone
bmDone:       lda     long:VW_BENCH
              cmp     ##VW_BENCHTAG
              beq     1$
              jmp     long:I_Error
1$:           jsr     .kbank bmEnd
              lda     8,s                   ; the realtics
              sta     long:VW_BRT
              lda     10,s
              sta     long:(VW_BRT+2)
              tsc
              clc
              adc     ##19
              tcs
              pei     dp:.tiny (_Dp+8)      ; (the saved scratch of bmStr)
              pei     dp:.tiny (_Dp+10)
              lda     ##0
              sta     long:VW_BP
              jsr     .kbank uiViewIndex
              lda     long:(uiSizes+4),x
              ldx     ##.word2 uiFull
              jsr     .kbank bmStr
              jsr     .kbank uiNewline
              lda     long:VW_BFRAMES       ; FPS: 35000 x frames / realtics
              sta     dp:.tiny _Dp
              stz     dp:.tiny (_Dp+2)
              lda     ##(CONST_TICRATE * 1000)
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_Mul32
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     long:VW_BRT
              sta     dp:.tiny (_Dp+4)
              lda     long:(VW_BRT+2)
              sta     dp:.tiny (_Dp+6)
              jsl     long:_UDivMod32
              ldy     ##3                   ; x.xxx
              jsr     .kbank bmFrac
              jsr     .kbank uiNewline
              lda     long:VW_BACC
              and     ##2
              bne     4$
              lda     long:VW_BACC
              and     ##1
              beq     3$
              lda     ##.word0 txBZip
              bra     41$
3$:           lda     ##.word0 txBNative
              bra     41$
4$:           lda     ##.word0 txBTw
41$:          ldx     ##.word2 txBZip
              jsr     .kbank bmStr
5$:           lda     long:VW_BKHZ          ; (kHz + 5) / 10: x.xx MHz
              clc
              adc     ##5
              sta     dp:.tiny _Dp
              stz     dp:.tiny (_Dp+2)
              lda     ##10
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_UDivMod32
              ldy     ##2
              jsr     .kbank bmFrac
              lda     ##.word0 txBMhz
              ldx     ##.word2 txBMhz
              jsr     .kbank bmStr
              jsr     .kbank uiNewline
              lda     long:VW_BCACHE
              beq     6$
              ldx     ##0
              jsr     .kbank bmNum
              lda     ##.word0 txBKb
              bra     61$
6$:           lda     ##.word0 txBNone
61$:          ldx     ##.word2 txBKb
              jsr     .kbank bmStr
              jsr     .kbank uiNewline
              lda     long:VW_BROM
              and     ##0x00ff
              ldx     ##0
              jsr     .kbank bmNum
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              lda     ##MSG_BENCH           ; the message (startMessage), no
              sta     .near messageKind     ;   menu after it
              stz     .near messageLastMenuActive
              lda     ##1
              sta     .near messageToPrint
              sta     .near _g_menuactive
              inc     .near menuversion
              jmp     long:uiOpen          ; Return to G_CheckDemoStatus caller.

;;; bmStr: the string at X:C at the end of the text (VW_BTXT from VW_BP).
bmStr:        sta     dp:.tiny (_Dp+8)
              stx     dp:.tiny (_Dp+10)
              ldy     ##0
1$:           lda     [.tiny (_Dp+8)],y
              and     ##0x00ff
              beq     9$
              jsr     .kbank bmChar
              iny
              bra     1$
9$:           rts

;;; bmChar: the character C at the end of the text, then a 0. X and Y stay.
bmChar:       phx
              pha
              lda     long:VW_BP
              tax
              pla
              sep     #0x20
              sta     long:VW_BTXT,x
              lda     #0
              sta     long:(VW_BTXT+1),x
              rep     #0x20
              inx
              txa
              sta     long:VW_BP
              plx
              rts

;;; bmFrac: the unsigned X:C / 10^Y in decimal with Y digits after the
;;; point (Y = 2 or 3).
bmFrac:       sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     ##100
              cpy     ##2
              beq     1$
              lda     ##1000
1$:           sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              phy
              jsl     long:_UDivMod32
              ply
              pei     dp:.tiny _Dp          ; (the remainder)
              phy
              jsr     .kbank bmNum
              lda     ##'.'
              jsr     .kbank bmChar
              ply
              pla
              ldx     ##0
              brl     bmDigits

;;; bmNum: the unsigned X:C in decimal; bmDigits: with at least Y digits.
bmNum:        ldy     ##1
bmDigits:     sta     long:VW_BN
              txa
              sta     long:(VW_BN+2)
              pea     #0                    ; (the end of the digits)
1$:           phy
              lda     long:VW_BN            ; / 10: a digit
              sta     dp:.tiny _Dp
              lda     long:(VW_BN+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##10
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_UDivMod32
              sta     long:VW_BN
              txa
              sta     long:(VW_BN+2)
              ply
              lda     dp:.tiny _Dp
              ora     ##'0'
              pha
              dey                           ; more digits: to Y, or while
              bpl     2$                    ;   the number is not 0
              iny
2$:           bne     1$
              lda     long:VW_BN
              ora     long:(VW_BN+2)
              bne     1$
3$:           pla                           ; the digits, the first one first
              beq     9$
              jsr     .kbank bmChar
              bra     3$
9$:           rts

;;; C = 1 dims the saved font ramp; C = 0 restores it. Only SAVE SETTINGS
;;; uses the dim ramp. Keep every glyph pixel; no checkerboard mask.
BM_NIBTAB     .equ    MM_NIBTAB       ; NIBTAB of i_viigs65.s.
bmFontShade:  sta     dp:.tiny (_Dp+6)
              lda     ##(9 * 0x400 + 176)
              sta     dp:.tiny (_Dp+2)
              ldx     ##0
2$:           lda     dp:.tiny (_Dp+6)
              beq     3$
              txa
              clc
              adc     ##6
              cmp     ##16
              bcc     4$
              lda     ##15
              bra     4$
3$:           txa
4$:           phx
              tax
              lda     long:UI_FONTBUF,x
              and     ##0x00ff
              pha
              lda     3,s
              clc
              adc     dp:.tiny (_Dp+2)
              tax
              pla
              sep     #0x20
              sta     long:(BM_NIBTAB+0x200),x
              sta     long:(BM_NIBTAB+0x300),x
              asl     a
              asl     a
              asl     a
              asl     a
              sta     long:BM_NIBTAB,x
              sta     long:(BM_NIBTAB+0x100),x
              rep     #0x20
              plx
              inx
              cpx     ##16
              bcc     2$
              rts

              .space  (0x9a1 - (. - vwKeys))
                                      ; Keep vwFrame and other vwcode in place.
              .section uicode, text
uiNewline:    lda     ##10
              jmp     .kbank bmChar

;;; Menu layout and settings.
uiInit:       lda     ##0
              sta     long:UI_PALON
              sta     long:UI_SINGLETIC
              lda     ##0xffff
              sta     long:UI_PICTURE
              jmp     long:G_UpdateSaveGameStrings

uiReload:     rtl                           ; Apply gamma after the restore.

;;; Old settings may pair a small view with low detail. Small views use
;;; high-detail drawers; normalize both saved copies without a dirty mark.
UI_FDETAIL    .equ    20              ; F_DETAIL of m_config65.s.
              .public uiLoadSettings
              .extern G_LoadSettings, G_RememberSettings
uiLoadSettings:
              jsl     long:oneLoadSettings
              lda     long:(settingsFile+VW_FVSIZE)
              and     ##0x00ff
              jsl     long:oneNormalize
              bra     1$
              .space  7                     ; preserve every following address
1$:           pha                           ; Every size draws at high detail:
              stz     .near detailLevel     ; FULL FAST (low detail) went, it
                                            ; saved only 6% (1% on fight frames).
              lda     ##0
              jsl     long:R_SetDetail
              sep     #0x20
              lda     #0
              sta     long:(settingsFile+UI_FDETAIL)
              rep     #0x20
              pla
              sta     long:VW_SIZE
              sep     #0x20
              sta     long:(settingsFile+VW_FVSIZE)
              rep     #0x20
              lda     ##VW_INITTAG
              sta     long:VW_INIT
              jsl     long:G_SettingsChanged ; Collect the normalized checksum.
              jmp     long:oneRemember

;;; The last main-menu row is QUIT unless a player game is in progress.
uiMain:       jsl     long:uiOpen
              lda     .near _g_usergame
              beq     1$
              lda     ##6
              sta     long:menuNum
              lda     ##L_ENDGAM
              sta     long:(itemLump+8)
              lda     ##.word0 endGame
              bra     2$
1$:           lda     ##5
              sta     long:menuNum
              lda     ##L_QUITG
              sta     long:(itemLump+8)
              lda     ##.word0 quitDoom
2$:           sta     long:(itemRoutine+8)
              lda     .near currentMenu
              bne     3$                    ; Other menus have their own count.
              lda     .near itemOn
              cmp     long:menuNum
              bcc     3$
              stz     .near itemOn
3$:           rtl

;;; The menu, keys and benchmark share (size, drawer detail, label).
;;; Drawer detail 1 doubles texture rows at full size.
uiViewIndex:  ldx     ##0
1$:           lda     long:VW_SIZE
              and     ##0x00ff
              cmp     long:uiSizes,x
              bne     11$
              cmp     ##10
              bne     2$
              lda     .near detailLevel
              cmp     long:(uiSizes+2),x
              beq     2$
11$:          inx
              inx
              inx
              inx
              inx
              inx
              cpx     ##(uiSizesEnd-uiSizes)
              bcc     1$
              ldx     ##(uiSizesEnd-uiSizes-6)
2$:           rts
uiViewChange: pha
              jsr     .kbank uiViewIndex
              pla
              beq     2$
              cpx     ##(uiSizesEnd-uiSizes-6)
              bcs     9$
              inx
              inx
              inx
              inx
              inx
              inx
              bra     3$
2$:           cpx     ##0
              beq     9$
              dex
              dex
              dex
              dex
              dex
              dex
3$:           bra     uiViewApply
9$:           rtl
uiViewCycle:  jsr     .kbank uiViewIndex
              cpx     ##0
              bne     1$
              ldx     ##(uiSizesEnd-uiSizes)
1$:           dex
              dex
              dex
              dex
              dex
              dex
uiViewApply:  lda     long:uiSizes,x
              sta     long:VW_SIZE
              sep     #0x20
              sta     long:(settingsFile+VW_FVSIZE)
              rep     #0x20
              lda     long:(uiSizes+2),x
              sta     .near detailLevel
              sep     #0x20
              sta     long:(settingsFile+UI_FDETAIL)
              rep     #0x20
              jmp     long:oneDetail
uiOne:        .asciz  "1/3 SIZE"
uiHalf:       .asciz  "1/2 SIZE"
uiTwo:        .asciz  "2/3 SIZE"
uiFull:       .asciz  "FULL"

              .space  9                     ; old table/string extent


;;; C = direction (0 left), X = 0 SFX or 2 music; values stay in 0..15.
uiVolume:     pha
              txa
              pha
              cpx     ##0
              beq     4$
              lda     .near snd_MusicVolume
              bra     5$
4$:           lda     .near snd_SfxVolume
5$:           tax
              lda     3,s
              beq     1$
              txa
              cmp     ##15
              bcs     2$
              inc     a
              bra     2$
1$:           txa
              cmp     ##0
              beq     2$
              dec     a
2$:           plx
              ply
              cpx     ##0
              bne     3$
              jmp     long:S_SetSfxVolume
3$:           jmp     long:S_SetMusicVolume

;;; C = string, X = bank, Y = right edge (0 centers at x 160).
uiCenter:     ldy     ##0
              jsr     .kbank uiAlign
              rtl
uiAlign:      pei     dp:.tiny (_Dp+8)
              pei     dp:.tiny (_Dp+10)
              sta     dp:.tiny (_Dp+8)
              stx     dp:.tiny (_Dp+10)
              tya
              sta     long:UI_EDGE
              stz     .near MT_P
              jsl     long:uiLineWidth
              lda     long:UI_EDGE
              bne     1$
              lda     .near MT_W
              lsr     a
              sta     .near MT_W
              lda     ##160
1$:
              sec
              sbc     .near MT_W
              sta     .near MT_X
              jsl     long:uiWriteLine
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              rts

;;; Settings pages use the HUD font for both labels and values.
uiSettings:   pei     dp:.tiny (_Dp+8)
              pei     dp:.tiny (_Dp+10)
              ldx     .near currentMenu
              lda     long:uiTitles,x
              bne     0$
              brl     9$
0$:
              ldx     ##.word2 uiTitles
              ldy     ##0
              pha
              lda     ##20
              sta     .near MT_Y
              pla
              jsr     .kbank uiAlign
              lda     .near currentMenu
              cmp     ##MENU_OPTIONS
              bne     01$
              jsl     long:G_SettingsChanged
              bne     01$
              lda     ##0
              jsr     .kbank bmBox
01$:
              ldx     .near currentMenu
              lda     long:menuItems,x
              sta     long:UI_ITEM
              lda     long:menuNum,x
              sta     long:UI_LEFT
              lda     long:menuY,x
              sta     long:UI_Y
1$:           lda     long:UI_Y
              sta     .near MT_Y
              lda     ##60
              sta     .near MT_X
              lda     long:UI_ITEM
              cmp     ##46                  ; SAVE SETTINGS is the last row.
              bne     10$
              jsl     long:G_SettingsChanged
              bne     10$
              lda     ##1
              jsr     .kbank bmFontShade
10$:          lda     long:UI_ITEM
              tax
              lda     long:uiLabels,x
              ldx     ##.word2 uiLabels
              jsr     .kbank bmWrite
              lda     long:UI_ITEM
              tax
              lda     long:uiKinds,x
              bne     11$
              brl     6$
11$:
              sta     long:UI_KIND
              tax
              lda     long:uiValues,x
              sta     dp:.tiny (_Dp+8)
              lda     long:(uiValues+2),x
              sta     dp:.tiny (_Dp+10)
              lda     [.tiny (_Dp+8)]
              sta     long:UI_VALUE
              lda     long:UI_KIND
              tax
              lda     long:UI_VALUE
              cpx     ##20
              bcs     4$
              ldx     ##.word0 uiOff
              cmp     ##0
              beq     2$
              ldx     ##.word0 uiOn
2$:           txa
              bra     31$
3$:           jsr     .kbank uiViewIndex
              lda     long:(uiSizes+4),x
31$:          ldx     ##.word2 uiOff
              ldy     ##284
              jsr     .kbank uiAlign
              bra     6$
4$:           cpx     ##20
              beq     3$
              bra     5$
              .space  30              ; Keep later uicode entries fixed.
5$:           lda     long:UI_VALUE
              cpx     ##36
              bcs     51$
              tax
              lda     long:UI_KIND
              cmp     ##32
              beq     50$
              lda     long:uiGammaPos,x
              bra     52$
50$:          lda     long:uiMousePos,x
52$:          and     ##0x00ff
51$:          pha
              lda     ##16
              sta     .near TH_N
              lda     ##204
              sta     .near TH_X
              ldx     .near MT_Y
              dex
              dex
              dex
              pla
              jsl     long:uiThermo
6$:           lda     long:UI_ITEM
              inc     a
              inc     a
              sta     long:UI_ITEM
              ldx     .near currentMenu
              lda     long:UI_Y
              clc
              adc     long:menuLine,x
              sta     long:UI_Y
              lda     long:UI_LEFT
              dec     a
              sta     long:UI_LEFT
              beq     7$
              brl     1$
7$:           lda     .near currentMenu
              cmp     ##MENU_OPTIONS
              bne     9$
              jsl     long:G_SettingsChanged
              bne     9$
              lda     ##0
              jsr     .kbank bmFontShade
9$:           pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              jmp     long:M_DrawSkull
uiOff:        .asciz  "OFF"
uiOn:         .asciz  "ON"

uiGammaPos:   .byte   0, 4, 8, 11, 15
uiMousePos:   .byte   0, 2, 3, 5, 7, 8, 10, 12, 13, 15

;;; A message and the result share the menu palette, but have their own layout.
uiMessage:    jsl     long:I_MenuPalette
              lda     .near messageKind
              cmp     ##MSG_BENCH
              beq     uiBenchmark
              jmp     long:uiMessageText
uiBenchmark: pei     dp:.tiny (_Dp+8)
              pei     dp:.tiny (_Dp+10)
              lda     ##24
              sta     .near MT_Y
              lda     ##.word0 uiBenchTitle
              ldx     ##.word2 uiBenchTitle
              ldy     ##0
              jsr     .kbank uiAlign
              lda     ##0
              sta     long:UI_ITEM
              sta     long:UI_OFFSET
              lda     ##60
              sta     long:UI_Y
1$:           lda     long:UI_Y
              sta     .near MT_Y
              lda     ##36
              sta     .near MT_X
              lda     long:UI_ITEM
              tax
              lda     long:uiBenchLabels,x
              ldx     ##.word2 uiBenchLabels
              jsr     .kbank bmWrite
              lda     long:UI_OFFSET
              clc
              adc     ##.word0 VW_BTXT
              ldx     ##.word2 VW_BTXT
              ldy     ##284
              jsr     .kbank uiAlign
              lda     .near MT_P
              inc     a
              clc
              adc     long:UI_OFFSET
              sta     long:UI_OFFSET
              lda     long:UI_Y
              clc
              adc     ##16
              sta     long:UI_Y
              lda     long:UI_ITEM
              inc     a
              inc     a
              sta     long:UI_ITEM
              cmp     ##10
              bcc     1$
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              rtl
uiBenchTitle: .asciz  "BENCHMARK: DEMO3"
uiBenchLabels: .word   .word0 uiLView, .word0 uiLFps, .word0 uiLCpu
              .word   .word0 uiLCache, .word0 uiLRom
uiLFps:       .asciz  "FPS:"
uiLCpu:       .asciz  "CPU"
uiLCache:     .asciz  "CACHE"
uiLRom:       .asciz  "ROM"

;;; Menu counts, item offsets, layout and parent selections.
;;; Retain the old SOUND slots so later item indices stay fixed.
menuNum:      .word   6, 5, 8, 5, 11, 8
; VIEW, GAMMA and SFX share a page; music adds its row when enabled.
#if MUSIC_MENU
              .word   4, 2, 5
#else
              .word   3, 1, 5
#endif
menuItems:    .word   0, 12, 22, 38, 50, 72, 88, 92, 96
menuX:        .word   97, 48, 112, 60, 48, 112, 60, 60, 60
menuY:        .word   64, 63, 25, 48, 24, 25, 56, 48, 48
menuLine:     .word   16, 16, 13, 18, 16, 13, 24, 28, 20
menuPrev:     .word   0xffff, MENU_MAIN, MENU_MAIN, MENU_MAIN, MENU_INPUT
              .word   MENU_MAIN, MENU_OPTIONS, MENU_OPTIONS, MENU_OPTIONS
menuPrevItem: .word   0, 0, 2, 1, 4, 3, 1, 1, 2
itemStatus:   .word   1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
              .word   2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
              .word   1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 1
itemLump:     .word   L_NGAME, L_OPTION, L_LOADG, L_SAVEG, L_QUITG, L_QUITG
              .word   L_JKILL, L_JKILL+2, L_JKILL+4, L_JKILL+6, L_JKILL+8
              .word   0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff
              .word   0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff
              .word   0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff
              .word   0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff
              .word   0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff
              .word   0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff
uiTitles:     .word   0, 0, 0, .word0 uiOptions, 0, 0, .word0 uiVideo
              .word   .word0 uiSound, .word0 uiInput
uiLabels:     .word   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
              .word   .word0 uiMessages, .word0 uiVideo, .word0 uiInput
              .word   .word0 txBench, .word0 txSaveSet, .word0 uiSound, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
              .word   .word0 uiLView, .word0 uiGamma, .word0 uiSfx
              .word   .word0 uiMusic, .word0 uiRun, .word0 uiMouse
              .word   .word0 uiSpeed, .word0 uiMove, .word0 uiKeys
uiKinds:      .word   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
              .word   4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 20, 28, 36, 40, 8, 12, 32, 16, 0
uiValues:     .long   0, showMessages, _g_alwaysRun, iigs_mouseon
; Unused item 24 keeps the reserved detailimg fragment linked.
              .long   iigs_mousemove, VW_SIZE, menuDetailPad, _g_gamma
              .long   iigs_mousespeed, snd_SfxVolume, snd_MusicVolume
uiOptions:    .asciz  "OPTIONS"
uiMessages:   .asciz  "MESSAGES"
uiVideo:      .asciz  "DISPLAY & SOUND"
uiSound:      .asciz  "SOUND"
uiInput:      .asciz  "CONTROLS"
uiLView:      .asciz  "VIEW"
uiGamma:      .asciz  "GAMMA"
uiSfx:        .asciz  "SFX VOLUME"
uiMusic:      .asciz  "MUSIC VOLUME"
uiRun:        .asciz  "ALWAYS RUN"
uiMouse:      .asciz  "MOUSE"
uiSpeed:      .asciz  "MOUSE SPEED"
uiMove:       .asciz  "MOUSE MOVE"
uiKeys:       .asciz  "KEY SETUP"

              .extern oneNormalize, oneRemember, oneDetail, oneLoadSettings

              .section onecold, text
uiSizes:      .word   VW_QUARTERSIZE, 0, .word0 uiQuarter
              .word   VW_ONESIZE, 0, .word0 uiOne
              .word   VW_HALFSIZE, 0, .word0 uiHalf
              .word   VW_TWOSIZE, 0, .word0 uiTwo
              .word   VW_THREEQUARTERSIZE, 0, .word0 uiThreequarter
              .word   10, 0, .word0 uiFull
uiSizesEnd:

              .section fourui, text
uiQuarter: .asciz "1/4 SIZE"
uiThreequarter: .asciz "3/4 SIZE"
