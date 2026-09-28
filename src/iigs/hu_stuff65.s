;;; The heads-up text in 65816 assembly, Doom8088: Apple IIgs Edition.
;;;
;;; hu_stuff.c with the same results: the message line at the top
;;; of the view (4 seconds) and the map title over the automap. The text
;;; cache of i_viigs.c draws a line that did not change again.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"

              .extern _Dp, _g_player, _g_gamemap, automapmode, showMessages
              .extern W_GetNumForName, W_GetLumpByNum, Z_ChangeTagToCache
              .extern V_DrawPatchNotScaled, I_DrawCachedText, I_EndTextCapture

PL            .equ    _g_player
HU_MAXLINELENGTH .equ 34
HU_FONTSTART  .equ    '!'
HU_FONTEND    .equ    '_'
HU_FONT_HEIGHT .equ   7
HU_FONT_SPACE_WIDTH .equ 4
HU_TITLEY     .equ    (CONST_VIEWHEIGHT - 1 - HU_FONT_HEIGHT)
HU_MSGY       .equ    0
HU_MSGTIMEOUT .equ    (4 * CONST_TICRATE)
SCREENWIDTH   .equ    320
AM_ACTIVE     .equ    1               ; am_active, am_map.h

;;; a text line (hu_textline_t): y, the text (35 bytes), len
TL_Y          .equ    0
TL_TEXT       .equ    2
TL_LEN        .equ    (TL_TEXT + HU_MAXLINELENGTH + 1)
TL_SIZE       .equ    (TL_LEN + 2)

              .section znear, bss
w_title:      .space  TL_SIZE
w_message:    .space  TL_SIZE
              .public message_on, message_new
message_on:   .space  2
message_new:  .space  2               ; not 0: src/iigs/d_main65.s clears
                                      ;   the strip (a new message)
message_counter: .space 2
font_lump_offset: .space 2
              .public _g_message_dontfuckwithme
_g_message_dontfuckwithme:
              .space  2
HU_LINE:      .space  2               ; the line of drawTextLine
HU_SLOT:      .space  2
HU_X:         .space  2
HU_I:         .space  2
HU_W:         .space  2

              .section cfar, rodata
fontStart:    .asciz  "STCFN033"
;;; the map names (HUSTR_E1M1..9 of d_englsh.h)
mapName1:     .asciz  "E1M1: Hangar"
mapName2:     .asciz  "E1M2: Nuclear Plant"
mapName3:     .asciz  "E1M3: Toxin Refinery"
mapName4:     .asciz  "E1M4: Command Control"
mapName5:     .asciz  "E1M5: Phobos Lab"
mapName6:     .asciz  "E1M6: Central Processing"
mapName7:     .asciz  "E1M7: Computer Station"
mapName8:     .asciz  "E1M8: Phobos Anomaly"
mapName9:     .asciz  "E1M9: Military Base"
mapNames:     .word   .word0 mapName1, .word2 mapName1, .word0 mapName2, .word2 mapName2
              .word   .word0 mapName3, .word2 mapName3, .word0 mapName4, .word2 mapName4
              .word   .word0 mapName5, .word2 mapName5, .word0 mapName6, .word2 mapName6
              .word   .word0 mapName7, .word2 mapName7, .word0 mapName8, .word2 mapName8
              .word   .word0 mapName9, .word2 mapName9

;;; ---------------------------------------------------------------------------
;;; void HU_Init(void): the lump of the first font character, the rows of
;;; the lines.
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public HU_Init
HU_Init:      lda     ##.word0 fontStart
              sta     dp:.tiny _Dp
              lda     ##.word2 fontStart
              sta     dp:.tiny (_Dp+2)
              jsl     long:W_GetNumForName
              sec
              sbc     ##HU_FONTSTART
              sta     .near font_lump_offset
              lda     ##HU_MSGY
              sta     .near (w_message+TL_Y)
              lda     ##HU_TITLEY
              sta     .near (w_title+TL_Y)
              rtl

;;; ---------------------------------------------------------------------------
;;; void HU_Start(void): no message; the title of the map.
;;; ---------------------------------------------------------------------------
              .public HU_Start
HU_Start:     stz     .near message_on
              stz     .near _g_message_dontfuckwithme
              stz     .near (w_message+TL_LEN)
              sep     #0x20
              stz     .near (w_message+TL_TEXT)
              rep     #0x20
              lda     .near _g_gamemap      ; strcpy(title, mapnames[gamemap - 1])
              dec     a
              asl     a
              asl     a
              tax
              lda     long:mapNames,x
              sta     dp:.tiny _Dp
              lda     long:(mapNames+2),x
              sta     dp:.tiny (_Dp+2)
              ldy     ##0
              sep     #0x20
1$:           lda     [.tiny _Dp],y
              sta     abs:.near (w_title+TL_TEXT),y
              beq     2$
              iny
              bra     1$
2$:           rep     #0x20
              sty     .near (w_title+TL_LEN)
              rtl

;;; ---------------------------------------------------------------------------
;;; void HU_Drawer(void): the map title over the automap, the message.
;;; ---------------------------------------------------------------------------
              .public HU_Drawer
HU_Drawer:    lda     .near automapmode
              and     ##AM_ACTIVE
              beq     1$
              ldx     ##.near w_title
              lda     ##1
              jsr     .kbank drawTextLine
1$:           lda     .near message_on
              beq     2$
              ldx     ##.near w_message
              lda     ##0
              jsr     .kbank drawTextLine
2$:           rtl

;;; drawTextLine: HUlib_drawTextLine(the line at near X, text cache slot
;;; C): the characters of the font from x = 0 (a space for the others)
;;; while they fit in the screen width, all lower case as upper case.
drawTextLine: stx     .near HU_LINE
              sta     .near HU_SLOT
              lda     abs:TL_Y,x            ; I_DrawCachedText(slot, text, len, y)
              pha
              jsr     .kbank cacheArgs
              jsl     long:I_DrawCachedText
              ply
              and     ##0x00ff              ; (boolean)
              beq     1$
              rts                           ; the cached code drew it
1$:           stz     .near HU_X
              stz     .near HU_I
2$:           lda     .near HU_I            ; for each character
              ldx     .near HU_LINE
              cmp     abs:TL_LEN,x
              bcs     9$
              clc
              adc     .near HU_LINE
              tax
              lda     abs:TL_TEXT,x
              and     ##0x00ff
              cmp     ##'a'                 ; toupper
              bcc     3$
              cmp     ##('z'+1)
              bcs     3$
              sbc     ##('a'-'A'-1)         ; (carry clear: - 0x20)
3$:           cmp     ##HU_FONTSTART        ; a font character
              bcc     5$
              cmp     ##(HU_FONTEND+1)
              bcs     5$
              clc                           ; patch = W_GetLumpByNum(c + offset)
              adc     .near font_lump_offset
              jsl     long:W_GetLumpByNum
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              lda     [.tiny (_Dp+4)]       ; w = patch->width
              sta     .near HU_W
              clc                           ; x + w > SCREENWIDTH: the end
              adc     .near HU_X
              cmp     ##(SCREENWIDTH+1)
              bmi     4$
              jsr     .kbank patchCache
              bra     9$
4$:           ldx     .near HU_LINE         ; V_DrawPatchNotScaled(x, y, patch)
              lda     abs:TL_Y,x
              sta     dp:.tiny _Dp
              pei     dp:.tiny (_Dp+6)
              pei     dp:.tiny (_Dp+4)
              lda     .near HU_X
              jsl     long:V_DrawPatchNotScaled
              pla
              sta     dp:.tiny (_Dp+4)
              pla
              sta     dp:.tiny (_Dp+6)
              jsr     .kbank patchCache
              lda     .near HU_X            ; x += w
              clc
              adc     .near HU_W
              sta     .near HU_X
              bra     6$
5$:           lda     .near HU_X            ; another character: a space
              clc
              adc     ##HU_FONT_SPACE_WIDTH
              sta     .near HU_X
              cmp     ##SCREENWIDTH         ; x >= SCREENWIDTH: the end
              bpl     9$
6$:           inc     .near HU_I
              brl     2$
9$:           ldx     .near HU_LINE         ; I_EndTextCapture(slot, text, len, y)
              lda     abs:TL_Y,x
              pha
              jsr     .kbank cacheArgs
              jsl     long:I_EndTextCapture
              ply
              rts

;;; patchCache: Z_ChangeTagToCache(the patch at _Dp[4-7]).
patchCache:   lda     dp:.tiny (_Dp+4)
              sta     dp:.tiny _Dp
              lda     dp:.tiny (_Dp+6)
              sta     dp:.tiny (_Dp+2)
              jsl     long:Z_ChangeTagToCache
              rts

;;; cacheArgs: the arguments of the text cache for the line HU_LINE (y is
;;; on the stack): text in _Dp[0-3], len in _Dp[4-5], C = slot.
cacheArgs:    ldx     .near HU_LINE
              lda     abs:TL_LEN,x
              sta     dp:.tiny (_Dp+4)
              txa
              clc
              adc     ##TL_TEXT
              sta     dp:.tiny _Dp
              lda     ##.word2 w_title
              sta     dp:.tiny (_Dp+2)
              lda     .near HU_SLOT
              rts

;;; ---------------------------------------------------------------------------
;;; void HU_Ticker(void): the message goes after HU_MSGTIMEOUT tics; a new
;;; message of the player comes up (when messages are on, or for the
;;; "Messages Off" message).
;;; ---------------------------------------------------------------------------
              .public HU_Ticker
HU_Ticker:    lda     .near message_counter
              beq     1$
              dec     .near message_counter
              bne     1$
              stz     .near message_on
1$:           lda     .near showMessages
              ora     .near _g_message_dontfuckwithme
              beq     9$
              lda     .near (PL+OFS_PL_MESSAGE)
              ora     .near (PL+OFS_PL_MESSAGE+2)
              beq     9$
              lda     .near (PL+OFS_PL_MESSAGE) ; strcpy(w_message.lineoftext, message)
              sta     dp:.tiny _Dp
              lda     .near (PL+OFS_PL_MESSAGE+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##0
              sep     #0x20
2$:           lda     [.tiny _Dp],y
              sta     abs:.near (w_message+TL_TEXT),y
              beq     3$
              iny
              bra     2$
3$:           rep     #0x20
              sty     .near (w_message+TL_LEN)
              stz     .near (PL+OFS_PL_MESSAGE) ; message = NULL
              stz     .near (PL+OFS_PL_MESSAGE+2)
              lda     ##1
              sta     .near message_on
              sta     .near message_new
              lda     ##HU_MSGTIMEOUT
              sta     .near message_counter
              stz     .near _g_message_dontfuckwithme
9$:           rtl
