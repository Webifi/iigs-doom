;;; Startup, text console, keyboard and exit in 65816 assembly.
;;;
;;; i_iigs.c with the same results: main and the math tables, the
;;; 40 column text console with a printf for it (the formats that the game
;;; uses: %s, %c, %d, %i, %u, the l forms and a precision), I_Quit and
;;; I_Error. The key events of I_StartTic come from the ADB keyboard, not
;;; from the keyboard register of i_iigs.c.
;;; A timedemo build gives the demo name to D_DoomMain (TIMEDEMO_N of the
;;; Makefile), so there is no argument list.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "keys.inc"
#include "tics.inc"

              .extern _Dp, D_DoomMain, D_PostEvent
              .extern IIGS_StartKeys, IIGS_StopKeys, IIGS_ResetSystem, IIGS_StopInterrupts
              .extern bmAccelOff, bmAccelBack
              .extern iigs_adbq, iigs_adbqhead, iigs_adbqtail
#if TICSTEP > 1
              .extern iigs_adbt
#endif
              .extern IIGS_InitSquares, IIGS_InitRecip, IIGS_InitFstep
              .extern R_InitSpriteScales, R_CheckSegPage
              .extern I_InitGraphicsHardwareSpecificCode, I_ShutdownGraphics, I_ShutdownSound
              .extern I_InitProgress, I_InitSettings, I_GetTime, _g_menuactive

NEWVIDEO      .equ    0xe0c029
BORDER        .equ    0xe0c034
SHADOW        .equ    0xe0c035
SPEED         .equ    0xe0c036
TXTSET        .equ    0xe0c051
TXTPAGE1      .equ    0xe0c054
CLR80VID      .equ    0xe0c00c
CLRALTCH      .equ    0xe0c00e
TEXT_PAGE     .equ    0xe00400
TEXTCOL       .equ    0xe0c022        ; text color (high 4 bits), background
ROM_PR3       .equ    0xc300          ; the 80-column firmware on (PR#3)
ROM_VTAB      .equ    0xfc22
ROM_BASIC     .equ    0xe000          ; Applesoft cold start
ROM_CH        .equ    0x24            ; the cursor column
ROM_CV        .equ    0x25            ; the cursor row
ROM_OURCH     .equ    0x057b          ; the cursor column of 80-column text
QT_ROW        .equ    0x06            ; quitToBasic: 2 * the row (free zero page)
QT_N          .equ    0x08            ; quitToBasic: the column count
EV_KEYDOWN    .equ    0
EV_KEYUP      .equ    1
ADBQ_MASK     .equ    31              ; the size of iigs_adbq - 1
ADB_CONTROL   .equ    0x36            ; ADB key codes
ADB_RESET     .equ    0x7f
NOKEY         .equ    0xff            ; keyTable: no Doom key

              .section znear, bss
isGraphicsModeSet: .space 2
keyCount:     .space  (2 * NUMKEYS)   ; the ADB keys down of each Doom key
keyNew:       .space  (2 * NUMKEYS)   ; recount: the new counts
              .public iigs_bindwait, iigs_bindcode
iigs_bindwait: .space 2               ; 1: the next key is for the key setup
iigs_bindcode: .space 2               ;   and goes here, with no event
conX:         .space  2
conY:         .space  2
EVENT:        .space  4               ; I_PostKey: type, data1
KB_CALL:      .space  2               ; I_StartTic: the call (not 0),
KB_ENTRY:     .space  2               ;   the keyTable entry of a key
KB_X:         .space  2               ; recount, I_BindKey, I_ActionKeys
KB_Y:         .space  2
KB_CODEEND:   .space  2
KB_KEY:       .space  2               ; I_StartTic: the ADB key (x 2)
#if TICSTEP > 1
KB_UNTIL:     .space  2               ; I_StartTic: the last tic of its bytes
#endif
REP_KEY:      .space  2               ; the menu arrow that repeats (ADB key
REP_CHAR:     .space  2               ;   x 2), its character (0: none), the
REP_NEXT:     .space  2               ;   time of its next repeat
PC_C:         .space  2               ; putChar
SC_S:         .space  2               ; scrollText: the rows
SC_D:         .space  2
SC_N:         .space  2
PF_FMT:       .space  4               ; I_Error: the format
PF_ARG:       .space  2               ; the next argument (bank 0)
PF_PREC:      .space  2               ; the precision (0xffff: none)
PF_LONG:      .space  2               ; an l form
PF_V:         .space  4               ; the number,
PF_NEG:       .space  2               ;   negative,
PF_N:         .space  2               ;   its digits
PF_DIG:       .space  12

              .section zfar, bss
              .public keyTable
keyTable:     .space  256             ; the keys (keyDefaults, I_BindKey)
keyStamp:     .space  256             ; the call of I_StartTic that saw each
                                      ;   ADB key go down, 0: up

              .section cfar, rodata
msgTitle:     .asciz  "Doom for the Apple IIgs\n\n"
errSegPage:   .asciz  "R_CheckSegPage: the direct page does not fit the wall loop"
#if defined TIMEDEMO_N
demoName:     .ascii  "demo"
              .byte   '0' + TIMEDEMO_N, 0
#endif
textRowOffset: .word  0x000, 0x080, 0x100, 0x180, 0x200, 0x280, 0x300, 0x380
              .word   0x028, 0x0a8, 0x128, 0x1a8, 0x228, 0x2a8, 0x328, 0x3a8
              .word   0x050, 0x0d0, 0x150, 0x1d0, 0x250, 0x2d0, 0x350, 0x3d0
;;; The ADB key codes 0-127: the Doom key (low byte, NOKEY: none) and the
;;; character of the key for the menus and the cheats (high byte, 0: none).
;;; keyDefaults are the keys of PC Doom: arrows, Control fires, Space uses,
;;; Shift runs (Caps Lock too: it stays down), Option and Command (MAME:
;;; the Mac Option keys) make the turn keys strafe, comma and period strafe,
;;; 1-7 select a weapon; also W A S D and E. The Mac Command key does not
;;; reach the IIgs in MAME. The mouse buttons (IIGS_PollKeys) fire and
;;; strafe. The Doom keys of keyTable change in the key setup (I_BindKey).
KEYDEF        .macro  key, char
              .word   (\char << 8) | \key
              .endm
keyDefaults:
              KEYDEF  KEY_STRAFELEFT, 'a'     ; $00 A
              KEYDEF  KEY_DOWN, 's'           ; $01 S
              KEYDEF  KEY_STRAFERIGHT, 'd'    ; $02 D
              KEYDEF  NOKEY, 'f'              ; $03 F
              KEYDEF  NOKEY, 'h'              ; $04 H
              KEYDEF  NOKEY, 'g'              ; $05 G
              KEYDEF  NOKEY, 'z'              ; $06 Z
              KEYDEF  NOKEY, 'x'              ; $07 X
              KEYDEF  NOKEY, 'c'              ; $08 C
              KEYDEF  NOKEY, 'v'              ; $09 V
              KEYDEF  NOKEY, 0                ; $0A
              KEYDEF  NOKEY, 'b'              ; $0B B
              KEYDEF  NOKEY, 'q'              ; $0C Q
              KEYDEF  KEY_UP, 'w'             ; $0D W
              KEYDEF  KEY_USE, 'e'            ; $0E E
              KEYDEF  NOKEY, 'r'              ; $0F R
              KEYDEF  NOKEY, 'y'              ; $10 Y
              KEYDEF  NOKEY, 't'              ; $11 T
              KEYDEF  KEY_WEAPON1, '1'        ; $12 1
              KEYDEF  (KEY_WEAPON1+1), '2'    ; $13 2
              KEYDEF  (KEY_WEAPON1+2), '3'    ; $14 3
              KEYDEF  (KEY_WEAPON1+3), '4'    ; $15 4
              KEYDEF  (KEY_WEAPON1+5), '6'    ; $16 6
              KEYDEF  (KEY_WEAPON1+4), '5'    ; $17 5
              KEYDEF  KEY_ZOOMIN, 0           ; $18 =
              KEYDEF  NOKEY, '9'              ; $19 9
              KEYDEF  (KEY_WEAPON1+6), '7'    ; $1A 7
              KEYDEF  KEY_ZOOMOUT, 0          ; $1B -
              KEYDEF  NOKEY, '8'              ; $1C 8
              KEYDEF  NOKEY, '0'              ; $1D 0
              KEYDEF  KEY_WEAPONUP, 0         ; $1E ]
              KEYDEF  NOKEY, 'o'              ; $1F O
              KEYDEF  NOKEY, 'u'              ; $20 U
              KEYDEF  KEY_WEAPONDOWN, 0       ; $21 [
              KEYDEF  NOKEY, 'i'              ; $22 I
              KEYDEF  NOKEY, 'p'              ; $23 P
              KEYDEF  KEY_USE, KEYC_ENTER     ; $24 Return
              KEYDEF  NOKEY, 'l'              ; $25 L
              KEYDEF  NOKEY, 'j'              ; $26 J
              KEYDEF  NOKEY, 0                ; $27 '
              KEYDEF  NOKEY, 'k'              ; $28 K
              KEYDEF  NOKEY, 0                ; $29 ;
              KEYDEF  NOKEY, 0                ; $2A backslash
              KEYDEF  KEY_STRAFELEFT, 0       ; $2B ,
              KEYDEF  NOKEY, 0                ; $2C /
              KEYDEF  NOKEY, 'n'              ; $2D N
              KEYDEF  NOKEY, 'm'              ; $2E M
              KEYDEF  KEY_STRAFERIGHT, 0      ; $2F .
              KEYDEF  KEY_MAP, 0              ; $30 Tab
              KEYDEF  KEY_USE, 0              ; $31 Space
              KEYDEF  NOKEY, 0                ; $32 `
              KEYDEF  NOKEY, KEYC_BACK        ; $33 Delete
              KEYDEF  NOKEY, 0                ; $34
              KEYDEF  KEY_ESCAPE, 0           ; $35 Esc
              KEYDEF  KEY_FIRE, 0             ; $36 Control
              KEYDEF  KEY_STRAFE, 0           ; $37 Command
              KEYDEF  KEY_SPEED, 0            ; $38 Shift
              KEYDEF  KEY_SPEED, 0            ; $39 Caps Lock
              KEYDEF  KEY_STRAFE, 0           ; $3A Option
              KEYDEF  KEY_LEFT, KEYC_LEFT     ; $3B Left
              KEYDEF  KEY_RIGHT, KEYC_RIGHT   ; $3C Right
              KEYDEF  KEY_DOWN, KEYC_DOWN     ; $3D Down
              KEYDEF  KEY_UP, KEYC_UP         ; $3E Up
              KEYDEF  NOKEY, 0                ; $3F
              KEYDEF  NOKEY, 0                ; $40
              KEYDEF  NOKEY, 0                ; $41 keypad .
              KEYDEF  NOKEY, 0                ; $42
              KEYDEF  NOKEY, 0                ; $43 keypad *
              KEYDEF  NOKEY, 0                ; $44
              KEYDEF  KEY_ZOOMIN, 0           ; $45 keypad +
              KEYDEF  NOKEY, 0                ; $46
              KEYDEF  NOKEY, 0                ; $47 keypad Clear
              KEYDEF  NOKEY, 0                ; $48
              KEYDEF  NOKEY, 0                ; $49
              KEYDEF  NOKEY, 0                ; $4A
              KEYDEF  NOKEY, 0                ; $4B keypad /
              KEYDEF  KEY_USE, KEYC_ENTER     ; $4C keypad Enter
              KEYDEF  NOKEY, 0                ; $4D
              KEYDEF  KEY_ZOOMOUT, 0          ; $4E keypad -
              KEYDEF  NOKEY, 0                ; $4F
              KEYDEF  NOKEY, 0                ; $50
              KEYDEF  NOKEY, 0                ; $51 keypad =
              KEYDEF  NOKEY, 0                ; $52 keypad 0
              KEYDEF  NOKEY, 0                ; $53 keypad 1
              KEYDEF  KEY_DOWN, KEYC_DOWN     ; $54 keypad 2
              KEYDEF  NOKEY, 0                ; $55 keypad 3
              KEYDEF  KEY_LEFT, KEYC_LEFT     ; $56 keypad 4
              KEYDEF  NOKEY, 0                ; $57 keypad 5
              KEYDEF  KEY_RIGHT, KEYC_RIGHT   ; $58 keypad 6
              KEYDEF  NOKEY, 0                ; $59 keypad 7
              KEYDEF  NOKEY, 0                ; $5A
              KEYDEF  KEY_UP, KEYC_UP         ; $5B keypad 8
              KEYDEF  NOKEY, 0                ; $5C keypad 9
              KEYDEF  NOKEY, 0                ; $5D
              KEYDEF  NOKEY, 0                ; $5E
              KEYDEF  NOKEY, 0                ; $5F
              KEYDEF  NOKEY, 0                ; $60 F5
              KEYDEF  NOKEY, 0                ; $61 F6
              KEYDEF  NOKEY, 0                ; $62 F7
              KEYDEF  NOKEY, 0                ; $63 F3
              KEYDEF  NOKEY, 0                ; $64 F8
              KEYDEF  NOKEY, 0                ; $65 F9
              KEYDEF  NOKEY, 0                ; $66
              KEYDEF  NOKEY, 0                ; $67 F11
              KEYDEF  NOKEY, 0                ; $68
              KEYDEF  NOKEY, 0                ; $69 F13
              KEYDEF  NOKEY, 0                ; $6A
              KEYDEF  NOKEY, 0                ; $6B F14
              KEYDEF  NOKEY, 0                ; $6C
              KEYDEF  NOKEY, 0                ; $6D F10
              KEYDEF  NOKEY, 0                ; $6E
              KEYDEF  NOKEY, 0                ; $6F F12
              KEYDEF  KEY_STRAFE, 0           ; $70 mouse button 1
              KEYDEF  NOKEY, 0                ; $71 F15
              KEYDEF  NOKEY, 0                ; $72 Help
              KEYDEF  NOKEY, 0                ; $73 Home
              KEYDEF  NOKEY, 0                ; $74 Page Up
              KEYDEF  NOKEY, 0                ; $75 Delete right
              KEYDEF  NOKEY, 0                ; $76 F4
              KEYDEF  NOKEY, 0                ; $77 End
              KEYDEF  NOKEY, 0                ; $78 F2
              KEYDEF  NOKEY, 0                ; $79 Page Down
              KEYDEF  NOKEY, 0                ; $7A F1
              KEYDEF  NOKEY, 0                ; $7B right Shift, Option,
              KEYDEF  NOKEY, 0                ; $7C   Control (only in the
              KEYDEF  NOKEY, 0                ; $7D   extended mode)
              KEYDEF  KEY_FIRE, 0             ; $7E mouse button 0
              KEYDEF  NOKEY, 0                ; $7F Reset (I_StartTic)

              .section coldcode, text

;;; ---------------------------------------------------------------------------
;;; int main(void): the fast speed (no ZipGS delay at interrupts), the CPU
;;; speed test, the math tables, then D_DoomMain (with
;;; the timedemo name in _Dp[0-3], 0 for none). The title picture of the
;;; loader stays on the screen; the text page gets the title for I_Error.
;;; ---------------------------------------------------------------------------
              .public main
main:         sep     #0x20
              lda     long:SPEED
              and     #0xef                 ; video shadowing only in banks 00/01
              ora     #0x80
              sta     long:SPEED
              lda     #0x3f
              jsl     long:IIGS_SetShadow
              rep     #0x20
              jsl     long:bmAccelOff       ; (IIGS_ZipOff, the TWGS IRQ logic)
              jsl     long:I_InitSettings   ; from bank 0, before the game uses it
              jsl     long:IIGS_InitSquares
              jsl     long:IIGS_InitRecip
              jsl     long:IIGS_InitFstep
              jsl     long:I_InitProgress   ; a cell of the load bar
              jsl     long:R_InitSpriteScales
              jsl     long:R_CheckSegPage
              cmp     ##0
              beq     1$
              lda     ##.word0 errSegPage
              sta     dp:.tiny _Dp
              lda     ##.word2 errSegPage
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
1$:           jsr     .kbank clearText
              lda     ##.word0 msgTitle
              sta     dp:.tiny _Dp
              lda     ##.word2 msgTitle
              sta     dp:.tiny (_Dp+2)
              jsr     .kbank format
#if defined TIMEDEMO_N
              lda     ##.word0 demoName
              sta     dp:.tiny _Dp
              lda     ##.word2 demoName
              sta     dp:.tiny (_Dp+2)
#else
              stz     dp:.tiny _Dp
              stz     dp:.tiny (_Dp+2)
#endif
              jmp     long:D_DoomMain

;;; ---------------------------------------------------------------------------
;;; void I_InitGraphics(void), I_Quit(void)
;;; void I_Error(const char* error, ...)   In: _Dp[0-3], the values at 4,s.
;;; ---------------------------------------------------------------------------
              .public I_InitGraphics, I_Quit, I_Error
I_InitGraphics:
              jsl     long:I_InitGraphicsHardwareSpecificCode
              lda     ##1
              sta     .near isGraphicsModeSet
              rtl
I_Quit:       jsr     .kbank shutdown
              jmp     long:quitToBasic
I_Error:      tsc                           ; the first value (bank 0)
              clc
              adc     ##4
              sta     .near PF_ARG
              lda     dp:.tiny _Dp
              sta     .near PF_FMT
              lda     dp:.tiny (_Dp+2)
              sta     .near (PF_FMT+2)
              jsr     .kbank shutdown
              jsr     .kbank textMode
              lda     ##10
              jsr     .kbank putChar
              lda     .near PF_FMT
              sta     dp:.tiny _Dp
              lda     .near (PF_FMT+2)
              sta     dp:.tiny (_Dp+2)
              jsr     .kbank format
              lda     ##10
              jsr     .kbank putChar
1$:           bra     1$

;;; shutdown: I_Shutdown: the graphics (if on), the interrupt and the sound
;;; stop, the ROM is back, the ADB microcontroller reads the keyboard again
;;; (Control-Reset works), the ZipGS settings of the user are back.
shutdown:     lda     .near isGraphicsModeSet
              beq     1$
              jsl     long:I_ShutdownGraphics
              stz     .near isGraphicsModeSet
1$:           jsl     long:IIGS_StopInterrupts
              jsl     long:I_ShutdownSound
              jsl     long:IIGS_StopKeys
              jsl     long:bmAccelBack      ; (the TWGS setting, IIGS_ZipBack)
              rts

;;; ---------------------------------------------------------------------------
;;; Text console, 40 columns, before the graphics start and for errors.
;;; ---------------------------------------------------------------------------

;;; textMode: I_TextMode: the text page 1, 40 columns.
textMode:     sep     #0x20
              lda     long:NEWVIDEO
              and     #0x3f
              ora     #0x40
              sta     long:NEWVIDEO
              lda     #0
              sta     long:TXTSET
              sta     long:TXTPAGE1
              sta     long:CLR80VID
              sta     long:CLRALTCH
              lda     long:BORDER
              and     #0xf0
              sta     long:BORDER
              rep     #0x20
              rts

;;; clearText: I_ClearText: spaces, the cursor at the top left.
clearText:    ldy     ##0                   ; Y = 2 * the row
1$:           tyx
              lda     long:textRowOffset,x
              tax
              lda     ##0xa0a0
              phy
              ldy     ##20
2$:           sta     long:TEXT_PAGE,x
              inx
              inx
              dey
              bne     2$
              ply
              iny
              iny
              cpy     ##48
              bcc     1$
              stz     .near conX
              stz     .near conY
              rts

;;; scrollText: I_ScrollText: rows 0-22 = rows 1-23, row 23 spaces.
scrollText:   ldy     ##0                   ; Y = 2 * the row
1$:           tyx
              lda     long:(textRowOffset+2),x
              sta     .near SC_S
              lda     long:textRowOffset,x
              sta     .near SC_D
              lda     ##20
              sta     .near SC_N
2$:           ldx     .near SC_S
              lda     long:TEXT_PAGE,x
              ldx     .near SC_D
              sta     long:TEXT_PAGE,x
              inc     .near SC_S
              inc     .near SC_S
              inc     .near SC_D
              inc     .near SC_D
              dec     .near SC_N
              bne     2$
              iny
              iny
              cpy     ##46
              bcc     1$
              ldx     ##0x3d0               ; (row 23)
              ldy     ##20
              lda     ##0xa0a0
3$:           sta     long:TEXT_PAGE,x
              inx
              inx
              dey
              bne     3$
              rts

;;; putChar: I_PutChar(C): a line break at '\n' or after 40 characters; a
;;; tab is a space, lower case is upper case, and a control character or
;;; one from 0x80 (a negative char) is not shown.
putChar:      and     ##0x00ff
              sta     .near PC_C
              cmp     ##10
              beq     1$
              lda     .near conX
              cmp     ##40
              bne     3$
1$:           stz     .near conX
              lda     .near conY
              cmp     ##23
              bne     11$
              jsr     .kbank scrollText
              bra     12$
11$:          inc     .near conY
12$:          lda     .near PC_C
              cmp     ##10
              bne     3$
              rts
3$:           lda     .near PC_C
              cmp     ##9
              bne     4$
              lda     ##' '
4$:           cmp     ##'a'
              bcc     5$
              cmp     ##('z' + 1)
              bcs     5$
              sbc     ##('a' - 'A' - 1)     ; (carry clear)
5$:           cmp     ##' '
              bcc     9$
              cmp     ##0x80
              bcs     9$
              ora     ##0x80
              sta     .near PC_C
              lda     .near conY
              asl     a
              tax
              lda     long:textRowOffset,x
              clc
              adc     .near conX
              tax
              sep     #0x20
              lda     .near PC_C
              sta     long:TEXT_PAGE,x
              rep     #0x20
              inc     .near conX
9$:           rts

;;; ---------------------------------------------------------------------------
;;; int printf(const char* format, ...)    In: _Dp[0-3], the values at 4,s.
;;; ---------------------------------------------------------------------------
              .public printf
printf:       tsc                           ; the first value (bank 0)
              clc
              adc     ##4
              sta     .near PF_ARG
              pei     dp:.tiny (_Dp+8)      ; (the saved scratch: a string)
              pei     dp:.tiny (_Dp+10)
              jsr     .kbank format
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              rtl

;;; format: the format at [_Dp] with the values from PF_ARG on the console.
;;; A conversion: %, then a precision .N, then l for 32 bits, then s, c, d,
;;; i or u (any other character is shown).
format:       ldy     ##0
1$:           lda     [.tiny _Dp],y
              and     ##0x00ff
              beq     9$
              iny
              cmp     ##'%'
              beq     2$
              phy
              jsr     .kbank putChar
              ply
              bra     1$
9$:           rts
2$:           lda     ##0xffff              ; no precision, 16 bits
              sta     .near PF_PREC
              stz     .near PF_LONG
              lda     [.tiny _Dp],y
              and     ##0x00ff
              cmp     ##'.'
              bne     4$
              iny                           ; the precision
              stz     .near PF_PREC
3$:           lda     [.tiny _Dp],y
              and     ##0x00ff
              cmp     ##'0'
              bcc     4$
              cmp     ##('9' + 1)
              bcs     4$
              iny
              sbc     ##('0' - 1)           ; (carry clear)
              pha
              lda     .near PF_PREC         ; precision * 10 + the digit
              asl     a
              sta     .near PF_PREC
              asl     a
              asl     a
              clc
              adc     .near PF_PREC
              clc
              adc     1,s
              sta     .near PF_PREC
              pla
              bra     3$
4$:           cmp     ##'l'
              bne     5$
              inc     .near PF_LONG
              iny
              lda     [.tiny _Dp],y
              and     ##0x00ff
5$:           iny
              phy
              jsr     .kbank conversion
              ply
              bra     1$

;;; conversion: the conversion C with the next value.
conversion:   cmp     ##'s'
              beq     str
              cmp     ##'c'
              beq     chr
              cmp     ##'u'
              beq     uns
              cmp     ##'d'
              beq     sgn
              cmp     ##'i'
              beq     sgn
              brl     putChar
str:          ldx     .near PF_ARG          ; a string (4 bytes), at most the
              lda     long:0x000000,x       ;   precision
              sta     dp:.tiny (_Dp+8)
              lda     long:0x000002,x
              sta     dp:.tiny (_Dp+10)
              inx
              inx
              inx
              inx
              stx     .near PF_ARG
              ldy     ##0
1$:           cpy     .near PF_PREC
              bcs     9$
              lda     [.tiny (_Dp+8)],y
              and     ##0x00ff
              beq     9$
              phy
              jsr     .kbank putChar
              ply
              iny
              bra     1$
9$:           rts
chr:          ldx     .near PF_ARG          ; a character (an int)
              lda     long:0x000000,x
              inx
              inx
              stx     .near PF_ARG
              brl     putChar
uns:          stz     .near PF_NEG          ; unsigned
              jsr     .kbank value
              bra     digits
sgn:          stz     .near PF_NEG          ; signed: 16 bits sign extended
              jsr     .kbank value
              lda     .near PF_LONG
              bne     1$
              lda     .near PF_V
              bpl     digits
              lda     ##0xffff
              sta     .near (PF_V+2)
1$:           lda     .near (PF_V+2)        ; negative: - and the size
              bpl     digits
              inc     .near PF_NEG
              lda     .near PF_V
              eor     ##0xffff
              clc
              adc     ##1
              sta     .near PF_V
              lda     .near (PF_V+2)
              eor     ##0xffff
              adc     ##0
              sta     .near (PF_V+2)
;;; digits: PF_V in decimal, with at least the precision digits (1 without).
digits:       stz     .near PF_N
1$:           jsr     .kbank div10          ; the digits, the last first
              ldx     .near PF_N
              sep     #0x20
              sta     .near PF_DIG,x
              rep     #0x20
              inc     .near PF_N
              lda     .near PF_V
              ora     .near (PF_V+2)
              bne     1$
              lda     .near PF_PREC
              cmp     ##0xffff
              bne     2$
              lda     ##1
2$:           cmp     .near PF_N            ; zeros up to the precision
              beq     3$
              bcc     3$
              ldx     .near PF_N
              sep     #0x20
              stz     .near PF_DIG,x
              rep     #0x20
              inc     .near PF_N
              bra     2$
3$:           lda     .near PF_NEG
              beq     4$
              lda     ##'-'
              jsr     .kbank putChar
4$:           dec     .near PF_N
              bmi     9$
              ldx     .near PF_N
              lda     .near PF_DIG,x
              and     ##0x00ff
              clc
              adc     ##'0'
              jsr     .kbank putChar
              bra     4$
9$:           rts

;;; value: PF_V = the next value (32 bits with l, else 16 bits).
value:        ldx     .near PF_ARG
              lda     long:0x000000,x
              sta     .near PF_V
              stz     .near (PF_V+2)
              inx
              inx
              lda     .near PF_LONG
              beq     1$
              lda     long:0x000000,x
              sta     .near (PF_V+2)
              inx
              inx
1$:           stx     .near PF_ARG
              rts

;;; div10: PF_V /= 10 (unsigned), C = the remainder.
div10:        lda     ##0
              ldx     ##32
1$:           asl     .near PF_V
              rol     .near (PF_V+2)
              rol     a
              cmp     ##10
              bcc     2$
              sbc     ##10
              inc     .near PF_V
2$:           dex
              bne     1$
              rts

;;; ---------------------------------------------------------------------------
;;; Keyboard: the key bytes of the ADB keyboard (IIGS_PollKeys) make the key
;;; events, so any number of keys can be down: forward, turn, strafe and
;;; fire at the same time.
;;; void I_InitKeyboard(void), I_StartTic(void)
;;; With TICSTEP > 1: void I_StartTicUntil(int16_t tic) (C = the tic): only
;;; the key bytes of that tic and before (iigs_adbt); I_StartTic takes the
;;; bytes up to the time now.
;;; ---------------------------------------------------------------------------
              .public I_InitKeyboard, I_StartTic
#if TICSTEP > 1
              .public I_StartTicUntil
#endif
I_InitKeyboard:
              ldx     ##254                 ; all keys up, the default keys
1$:           lda     long:keyDefaults,x
              sta     long:keyTable,x
              lda     ##0
              sta     long:keyStamp,x
              dex
              dex
              bpl     1$
              ldx     ##(2 * NUMKEYS - 2)
2$:           stz     .near keyCount,x
              dex
              dex
              bpl     2$
              stz     .near iigs_bindwait
              jsl     long:IIGS_StartKeys
              rtl

;;; I_StartTic: the key events of the key bytes in iigs_adbq. An ADB key is
;;; a Doom key and a character (keyTable). The Doom key goes down with the
;;; first of its ADB keys and up with the last. A key that goes down and up
;;; in the same call is down for one tic: its key up waits for the next
;;; call, with the rest of the ring (each call has its tic command).
;;; An arrow of the menus repeats while it is down and a menu is up: after
;;; REP_DELAY tics, then every REP_RATE tics. (An ADB keyboard sends only
;;; down and up; the repeat of the IIgs is in the firmware that the game
;;; does not use.)
REP_DELAY     .equ    11              ; 0.31 s
REP_RATE      .equ    4               ; 0.11 s
#if TICSTEP > 1
I_StartTic:   jsl     long:I_GetTime
I_StartTicUntil:
              sta     .near KB_UNTIL
              inc     .near KB_CALL
#else
I_StartTic:   inc     .near KB_CALL
#endif
              bne     1$
              inc     .near KB_CALL
1$:           ldx     .near iigs_adbqtail
              cpx     .near iigs_adbqhead
              bne     2$
9$:           brl     repeat
7$:           lda     long:(keyStamp+2*ADB_CONTROL) ; the Reset key: with
              beq     71$                   ;   Control, the reset of
              jsl     long:IIGS_ResetSystem ;   Control-Reset
71$:          brl     8$
2$:
#if TICSTEP > 1
              txa                           ; a byte of a later tic: it waits
              asl     a
              tay
              lda     .near iigs_adbt,y
              sec
              sbc     .near KB_UNTIL
              beq     22$
              bpl     9$
22$:
#endif
              lda     .near iigs_adbq,x
              bit     ##0x0080
              bne     3$
              and     ##0x007f              ; key down
              cmp     ##ADB_RESET
              beq     7$
              ldx     .near iigs_bindwait   ; a key for the key setup: no
              beq     21$                   ;   event
              stz     .near iigs_bindwait
              sta     .near iigs_bindcode
              brl     8$
21$:          asl     a
              tax
              stx     .near KB_KEY
              lda     long:keyStamp,x
              bne     8$
              lda     .near KB_CALL
              sta     long:keyStamp,x
              lda     long:keyTable,x
              sta     .near KB_ENTRY
              and     ##0x00ff
              cmp     ##NOKEY
              beq     4$
              asl     a
              tay
              lda     .near keyCount,y
              inc     a
              sta     .near keyCount,y
              dec     a
              bne     4$
              tya
              lsr     a
              tax
              lda     ##EV_KEYDOWN
              jsr     .kbank postKey
4$:           lda     .near (KB_ENTRY+1)    ; the character
              and     ##0x00ff
              beq     8$
              jsr     .kbank repeatStart
              tax
              lda     ##EV_KEYDOWN
              jsr     .kbank postKey
              bra     8$
90$:          brl     repeat
3$:           and     ##0x007f              ; key up
              asl     a
              tax
              lda     long:keyStamp,x
              beq     8$
              cmp     .near KB_CALL
              beq     90$                   ; down in this call: up in the next
              lda     ##0
              sta     long:keyStamp,x
              lda     long:keyTable,x
              and     ##0x00ff
              cmp     ##NOKEY
              beq     8$
              asl     a
              tay
              lda     .near keyCount,y
              dec     a
              sta     .near keyCount,y
              bne     8$
              tya
              lsr     a
              tax
              lda     ##EV_KEYUP
              jsr     .kbank postKey
8$:           lda     .near iigs_adbqtail   ; the next byte
              inc     a
              and     ##ADBQ_MASK
              sta     .near iigs_adbqtail
              brl     1$

;;; repeatStart: the character C of the ADB key KB_KEY; an arrow of the
;;; menus repeats from REP_DELAY tics on. C stays.
repeatStart:  cmp     ##KEYC_ENTER
              bcs     9$
              cmp     ##KEYC_UP
              bcc     9$
              sta     .near REP_CHAR
              lda     .near KB_KEY
              sta     .near REP_KEY
              jsl     long:I_GetTime        ; (the low 16 bits)
              clc
              adc     ##REP_DELAY
              sta     .near REP_NEXT
              lda     .near REP_CHAR
9$:           rts

;;; repeat: the menu arrow that is still down, when its time comes.
repeat:       lda     .near REP_CHAR
              beq     9$
              ldx     .near REP_KEY
              lda     long:keyStamp,x       ; up: no more repeats
              bne     1$
              stz     .near REP_CHAR
9$:           rtl
1$:           lda     .near _g_menuactive
              beq     9$
              jsl     long:I_GetTime
              sec
              sbc     .near REP_NEXT
              bmi     9$
              lda     .near REP_NEXT
              clc
              adc     ##REP_RATE
              sta     .near REP_NEXT
              ldx     .near REP_CHAR
              lda     ##EV_KEYDOWN
              jsr     .kbank postKey
              rtl

;;; ---------------------------------------------------------------------------
;;; The key setup of the menu.
;;; void I_BindKey(C = a Doom key, X = an ADB key code): the ADB key is the
;;; only key of the Doom key. void I_DefaultKeys(void): keyDefaults.
;;; Both send the key events of the Doom keys that change for the ADB keys
;;; that are down.
;;; I_ActionKeys(C = a Doom key): C, X = its first two ADB keys (0xffff:
;;; none), in the order $30-$3F (Space, arrows, modifiers), $20-$2F,
;;; $00-$1F, $40-$7F.
;;; ---------------------------------------------------------------------------
              .public I_BindKey, I_DefaultKeys, I_ActionKeys
I_BindKey:    sta     .near KB_ENTRY
              txa
              asl     a
              sta     .near KB_X
              ldx     ##254                 ; its keys now: none
1$:           lda     long:keyTable,x
              and     ##0x00ff
              cmp     .near KB_ENTRY
              bne     2$
              lda     long:keyTable,x
              ora     ##NOKEY
              sta     long:keyTable,x
2$:           dex
              dex
              bpl     1$
              ldx     .near KB_X            ; the new key
              lda     long:keyTable,x
              and     ##0xff00
              ora     .near KB_ENTRY
              sta     long:keyTable,x
              bra     recount

I_DefaultKeys:
              ldx     ##254
1$:           lda     long:keyDefaults,x
              sta     long:keyTable,x
              dex
              dex
              bpl     1$

;;; recount: the counts of the Doom keys from the ADB keys that are down, a
;;; key event for each Doom key that goes down or up.
recount:      ldx     ##(2 * NUMKEYS - 2)
1$:           stz     .near keyNew,x
              dex
              dex
              bpl     1$
              ldx     ##254
2$:           lda     long:keyStamp,x
              beq     3$
              lda     long:keyTable,x
              and     ##0x00ff
              cmp     ##NOKEY
              beq     3$
              asl     a
              tay
              lda     .near keyNew,y
              inc     a
              sta     .near keyNew,y
3$:           dex
              dex
              bpl     2$
              ldx     ##(2 * NUMKEYS - 2)
4$:           stx     .near KB_X
              lda     .near keyNew,x
              beq     5$
              lda     .near keyCount,x
              bne     7$
              lda     ##EV_KEYDOWN
              bra     6$
5$:           lda     .near keyCount,x
              beq     7$
              lda     ##EV_KEYUP
6$:           pha
              txa
              lsr     a
              tax
              pla
              jsr     .kbank postKey
              ldx     .near KB_X
7$:           lda     .near keyNew,x
              sta     .near keyCount,x
              dex
              dex
              bpl     4$
              rtl

I_ActionKeys: sta     .near KB_ENTRY
              lda     ##0xffff
              sta     .near KB_X
              sta     .near KB_Y
              ldx     ##0x30                ; the ranges, in order
              ldy     ##0x40
              jsr     .kbank actionRange
              ldx     ##0x20
              ldy     ##0x30
              jsr     .kbank actionRange
              ldx     ##0x00
              ldy     ##0x20
              jsr     .kbank actionRange
              ldx     ##0x40
              ldy     ##0x80
              jsr     .kbank actionRange
              lda     .near KB_X
              ldx     .near KB_Y
              rtl

;;; actionRange: the ADB keys X to Y - 1 of the Doom key KB_ENTRY into KB_X,
;;; then KB_Y.
actionRange:  tya
              asl     a
              sta     .near KB_CODEEND
              txa
              asl     a
              tax
1$:           lda     long:keyTable,x
              and     ##0x00ff
              cmp     .near KB_ENTRY
              bne     3$
              txa
              lsr     a
              ldy     .near KB_X
              bpl     2$
              sta     .near KB_X
              bra     3$
2$:           ldy     .near KB_Y
              bpl     3$
              sta     .near KB_Y
3$:           inx
              inx
              cpx     .near KB_CODEEND
              bcc     1$
              rts

;;; postKey: I_PostKey: D_PostEvent of the event C (type) with the key X.
postKey:      sta     .near EVENT
              stx     .near (EVENT+2)
              lda     ##.near EVENT
              sta     dp:.tiny _Dp
              lda     ##.word2 EVENT
              sta     dp:.tiny (_Dp+2)
              jsl     long:D_PostEvent
              rts

;;; ---------------------------------------------------------------------------
;;; quitToBasic: the exit of DOS Doom on the IIgs: the ROM's 80-column text
;;; with the ENDOOM page on rows 0-20 (tools/endtext.py), then Applesoft's
;;; cold start from row 21: its two line feeds put the "]" prompt on row 23. In bank 0: the ROM's entries
;;; return with RTS. shutdown has put the ROM and its vectors back.
;;; ---------------------------------------------------------------------------
              .section quitcode, text
              .extern endText
quitToBasic:  sep     #0x30
              lda     #0x08                 ; the text pages shadowed again
              jsl     long:IIGS_SetShadow
              lda     #0xd1                 ; yellow on red, as ENDOOM
              sta     long:TEXTCOL
              lda     long:BORDER
              and     #0xf0
              ora     #0x01
              sta     long:BORDER
              lda     #0
              pha
              plb
              rep     #0x20
              lda     ##0
              tcd
              sec
              xce                           ; emulation mode, as the ROM needs
              ldx     #0xff
              txs
              jsr     abs:ROM_PR3           ; 80 columns, a clear screen
              clc
              xce
              rep     #0x30
              ldx     ##0                   ; X = the page, 80 bytes a row
              stz     abs:QT_ROW
1$:           phx
              ldx     abs:QT_ROW
              lda     long:textRowOffset,x
              tay                           ; Y = the row on the screen
              plx
              sep     #0x20
              lda     #40
              sta     abs:QT_N
2$:           lda     long:endText,x
              phx
              tyx
              sta     long:0x010400,x       ; aux: the even columns
              plx
              lda     long:(endText+40),x
              phx
              tyx
              sta     long:0x000400,x       ; main: the odd columns
              plx
              inx
              iny
              dec     abs:QT_N
              bne     2$
              rep     #0x21
              txa
              adc     ##40
              tax
              lda     abs:QT_ROW
              adc     ##2
              sta     abs:QT_ROW
              cmp     ##42                  ; 21 rows
              bcc     1$
              sec
              xce
              lda     #21
              sta     abs:ROM_CV
              jsr     abs:ROM_VTAB
              lda     #0
              sta     abs:ROM_CH
              sta     abs:ROM_OURCH
              jmp     abs:ROM_BASIC

;;; SHADOW must also reach accelerators that decode bank-0 I/O writes.
;;; In: native mode, 8-bit A = new SHADOW. All registers and P preserved.
;;; IOLC hides $00:C035, so briefly expose I/O using the motherboard alias,
;;; then write the final value through bank 0. IRQ cannot enter the ROM
;;; vectors while IOLC is clear. This code, its stack, and direct page are
;;; below $C000; DBR and D are irrelevant to these long stores. Restoring P
;;; delivers any pending DOC/ADB IRQ only after the caller's mapping is back.
;;; Fixed space in DiskCode keeps every existing code/data address in place.
              .section shadowcode, text
              .public IIGS_SetShadow
IIGS_SetShadow:
              php
              sei
              pha
              and     #0xbf
              sta     long:SHADOW
              pla
              sta     long:0x00c035
              plp
              rtl
