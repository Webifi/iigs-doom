;;; Episode-one finale state and drawing.
;;;
;;; Reveal the ending text over a tiled flat, allowing fire/use to accelerate
;;; it, then display HELP2. This module owns the finale's tick count and
;;; screen transitions; the game-state dispatcher calls its ticker/drawer.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"

              .extern _Dp, _g_gameaction, _g_gamestate, automapmode, wipegamestate
              .extern _g_acceleratestage, WI_checkForAccelerate
              .extern W_GetNumForName, W_GetLumpByNum, V_DrawBackground
              .extern V_DrawRawFullScreen, V_DrawPatchNotScaled, _Div32, I_FinishUpdate

TEXTSPEED     .equ    300
TEXTWAIT      .equ    250
NEWTEXTSPEED  .equ    1
NEWTEXTWAIT   .equ    1000
AM_ACTIVE     .equ    1
HU_FONTSTART  .equ    '!'
HU_FONTEND    .equ    '_'
HU_FONT_SPACE_WIDTH .equ 4

              .section znear, bss
finalestage:  .space  2               ; false: the text, true: the picture
finalecount:  .space  4
midstage:     .space  2               ; the text is fast
help2num:     .space  2
backgroundnum: .space 2
FI_OFFSET:    .space  2               ; F_TextWrite: the font lumps - '!'
FI_COUNT:     .space  4
FI_CX:        .space  2
FI_CY:        .space  2
FI_CH:        .space  2               ; the next character (offset)
FI_T:         .space  4

              .section cfar, rodata
strHelp2:     .asciz  "HELP2"
strFloor:     .asciz  "FLOOR4_8"
strFont:      .asciz  "STCFN033"
e1text:       .ascii  "Once you beat the big badasses\n"
              .ascii  "and clean out the moon base\n"
              .ascii  "you're supposed to win?\n"
              .ascii  "Where's your ticket home?\n"
              .ascii  "What the hell is this? It's not\n"
              .ascii  "supposed to end this way!\n"
              .ascii  "\n"
              .ascii  "It stinks like rotten meat, but\n"
              .ascii  "looks like the lost Deimos base.\n"
              .ascii  "You're stuck on The Shores of\n"
              .ascii  "Hell.\n"
              .ascii  "The only way out is through."
e1end:        .byte   0
E1LENGTH      .equ    (e1end - e1text)

;;; ---------------------------------------------------------------------------
;;; void F_Init(void): the lumps of the picture and the background.
;;; void F_StartFinale(void): the finale state, the text from the start.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public F_Init, F_StartFinale
F_Init:       lda     ##.word0 strHelp2
              ldx     ##.word2 strHelp2
              jsr     .kbank lumpNum
              sta     .near help2num
              lda     ##.word0 strFloor
              ldx     ##.word2 strFloor
              jsr     .kbank lumpNum
              sta     .near backgroundnum
              rtl
F_StartFinale:
              stz     .near _g_gameaction   ; (ga_nothing)
              lda     ##CONST_GS_FINALE
              sta     .near _g_gamestate
              lda     .near automapmode
              and     ##(0xffff - AM_ACTIVE)
              sta     .near automapmode
              stz     .near _g_acceleratestage
              stz     .near midstage
              stz     .near finalestage
              stz     .near finalecount
              stz     .near (finalecount+2)
              rtl

;;; lumpNum: C = W_GetNumForName(the name C (low word), bank X).
lumpNum:      sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              jsl     long:W_GetNumForName
              rts

;;; textSpeed: C = Get_TextSpeed(): fast (1) in the mid stage, or when the
;;; player asked to accelerate (the mid stage starts), else 300.
textSpeed:    lda     .near midstage
              bne     2$
              lda     .near _g_acceleratestage
              sta     .near midstage
              bne     1$
              lda     ##TEXTSPEED
              rts
1$:           stz     .near _g_acceleratestage
2$:           lda     ##NEWTEXTSPEED
              rts

;;; ---------------------------------------------------------------------------
;;; void F_Ticker(void): the text for its time (strlen * speed / 100 + the
;;; wait), or until the player asks in the mid stage; then the picture.
;;; ---------------------------------------------------------------------------
              .public F_Ticker
F_Ticker:     jsl     long:WI_checkForAccelerate
              inc     .near finalecount
              bne     1$
              inc     .near (finalecount+2)
1$:           lda     .near finalestage
              bne     9$
              jsr     .kbank textSpeed      ; the time of the text:
              ldx     ##(E1LENGTH / 100)    ;   strlen * speed / 100
              cmp     ##NEWTEXTSPEED
              beq     2$
              ldx     ##(E1LENGTH * TEXTSPEED / 100)
2$:           txa                           ; + the wait
              ldx     ##TEXTWAIT
              ldy     .near midstage
              beq     3$
              ldx     ##NEWTEXTWAIT
3$:           stx     .near FI_T
              clc
              adc     .near FI_T
              sta     .near FI_T            ; finalecount > it (int32)
              cmp     .near finalecount
              lda     ##0
              sbc     .near (finalecount+2)
              bvc     4$
              eor     ##0x8000
4$:           bmi     5$
              lda     .near midstage        ; or the mid stage and a request
              beq     9$
              lda     .near _g_acceleratestage
              beq     9$
5$:           stz     .near finalecount     ; the picture
              stz     .near (finalecount+2)
              lda     ##1
              sta     .near finalestage
              lda     ##0xffff              ; a wipe
              sta     .near wipegamestate
9$:           rtl

;;; ---------------------------------------------------------------------------
;;; void F_Drawer(void): the background and (finalecount - 10) * 100 /
;;; speed letters of the text, or the picture.
;;; ---------------------------------------------------------------------------
              .public F_Drawer
F_Drawer:     lda     .near finalestage
              beq     1$
              lda     .near help2num
              jmp     long:V_DrawRawFullScreen
1$:           lda     .near backgroundnum
              jsl     long:V_DrawBackground
              lda     .near finalecount     ; (finalecount - 10) * 100
              sec
              sbc     ##10
              sta     dp:.tiny _Dp
              lda     .near (finalecount+2)
              sbc     ##0
              sta     dp:.tiny (_Dp+2)
              ldx     ##2                   ; * 4, * 32, * 64 (int32)
              jsr     .kbank shiftDp
              lda     dp:.tiny _Dp
              sta     .near FI_T
              lda     dp:.tiny (_Dp+2)
              sta     .near (FI_T+2)
              ldx     ##3
              jsr     .kbank shiftDp
              jsr     .kbank addDp
              ldx     ##1
              jsr     .kbank shiftDp
              jsr     .kbank addDp
              lda     .near FI_T
              sta     dp:.tiny _Dp
              lda     .near (FI_T+2)
              sta     dp:.tiny (_Dp+2)
              jsr     .kbank textSpeed      ; / speed (signed)
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_Div32
              cpx     ##0                   ; count < 0: 0
              bpl     2$
              lda     ##0
              tax
2$:           jmp     long:F_TextWrite

;;; shiftDp: _Dp[0-3] <<= X.
shiftDp:      asl     dp:.tiny _Dp
              rol     dp:.tiny (_Dp+2)
              dex
              bne     shiftDp
              rts

;;; addDp: FI_T += _Dp[0-3].
addDp:        lda     .near FI_T
              clc
              adc     dp:.tiny _Dp
              sta     .near FI_T
              lda     .near (FI_T+2)
              adc     dp:.tiny (_Dp+2)
              sta     .near (FI_T+2)
              rts

;;; ---------------------------------------------------------------------------
;;; void F_TextWrite(int32_t count)     In: X:C = count.
;;; The first count characters of the end text in the font (upper case; a
;;; space for the others), from (10, 10), 11 rows a line.
;;; ---------------------------------------------------------------------------
              .public F_TextWrite
F_TextWrite:  sta     .near FI_COUNT
              stx     .near (FI_COUNT+2)
              lda     ##.word0 strFont      ; the font lumps
              ldx     ##.word2 strFont
              jsr     .kbank lumpNum
              sec
              sbc     ##HU_FONTSTART
              sta     .near FI_OFFSET
              lda     ##10
              sta     .near FI_CX
              sta     .near FI_CY
              stz     .near FI_CH
1$:           lda     .near FI_COUNT        ; for (; count; count--)
              ora     .near (FI_COUNT+2)
              beq     9$
              lda     .near FI_COUNT
              bne     2$
              dec     .near (FI_COUNT+2)
2$:           dec     .near FI_COUNT
              ldx     .near FI_CH           ; c = *ch++
              inc     .near FI_CH
              lda     long:e1text,x
              and     ##0x00ff
              beq     9$
              cmp     ##10                  ; a new line
              bne     3$
              lda     ##10
              sta     .near FI_CX
              lda     .near FI_CY
              clc
              adc     ##11
              sta     .near FI_CY
              bra     1$
3$:           cmp     ##'a'                 ; toupper
              bcc     4$
              cmp     ##('z'+1)
              bcs     4$
              sbc     ##('a'-'A'-1)         ; (carry clear: - 0x20)
4$:           cmp     ##HU_FONTSTART        ; a font character
              bcc     5$
              cmp     ##(HU_FONTEND+1)
              bcs     5$
              clc
              adc     .near FI_OFFSET
              jsl     long:W_GetLumpByNum
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              lda     [.tiny (_Dp+4)]       ; cx += width (after the draw)
              pha
              lda     .near FI_CY
              sta     dp:.tiny _Dp
              lda     .near FI_CX
              jsl     long:V_DrawPatchNotScaled
              pla
              bra     6$
5$:           lda     ##HU_FONT_SPACE_WIDTH ; another character: a space
6$:           clc
              adc     .near FI_CX
              sta     .near FI_CX
              bra     1$
9$:           rtl

;;; The intermission has finished. Put its loading sign on the flat, so
;;; neither the next-map pointer nor its name is obscured during disk I/O.
              .public F_LoadScreen
F_LoadScreen: lda     .near backgroundnum
              jsl     long:V_DrawBackground
              jmp     long:I_FinishUpdate
