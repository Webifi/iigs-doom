;;; The intermission in 65816 assembly.
;;;
;;; wi_stuff.c and wi_lib.c with the same results: the counts of
;;; the level (kills, items, secret, times) count up with sounds, then the
;;; map shows the next level; fire or use shortens each stage. G_DoCompleted
;;; always starts it with _g_wminfo, so the code reads _g_wminfo. The lump
;;; numbers of the pictures are found once in WI_Init. The music call (a
;;; stub) is gone.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"

              .extern _Dp, _g_player, _g_wminfo, _g_gamemap, G_WorldDone
              .extern W_GetNumForName, W_GetLumpByNum, V_DrawRawFullScreen
              .extern V_DrawNumPatchScaled, V_DrawPatchScaled, S_StartSound
              .extern _Div32, _UDivMod32, _UDivMod16

PL            .equ    _g_player
WM            .equ    _g_wminfo
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
BT_ATTACK     .equ    1
BT_USE        .equ    2
NOSTATE       .equ    0xffff          ; stateenum_t
STATCOUNT     .equ    0
SHOWNEXTLOC   .equ    1
SHOWNEXTLOCDELAY .equ 4
WI_TITLEY     .equ    2
SP_STATSX     .equ    50
SP_STATSY     .equ    50
SP_TIMEX      .equ    8
SP_TIMEY      .equ    160
LINEHEIGHT    .equ    18
FONTWIDTH     .equ    11
SCREENW       .equ    320             ; SCREENWIDTH_VGA
SCREENH       .equ    200

;;; the lumps (byte offsets in lumps), in the order of lumpNames
L_WIMAP0      .equ    0
L_WIF         .equ    2
L_WIENTER     .equ    4
L_WICOLON     .equ    6
L_WISUCKS     .equ    8
L_WIPCNT      .equ    10
L_WIURH0      .equ    12
L_WISPLAT     .equ    14
L_WIOSTK      .equ    16
L_WIOSTI      .equ    18
L_WISCRT2     .equ    20
L_WITIME      .equ    22
L_WIMSTT      .equ    24
L_WIPAR       .equ    26
L_WINUM       .equ    28              ; WINUM0..9
L_WILV        .equ    48              ; WILV00..08
NUMLUMPS      .equ    33

              .section znear, bss
              .public _g_acceleratestage
_g_acceleratestage: .space 2
state:        .space  2
cnt:          .space  2
bcnt:         .space  2
cnt_time:     .space  4
cnt_total_time: .space 4
cnt_par:      .space  2
cnt_pause:    .space  2
sp_state:     .space  2
cnt_kills:    .space  2
cnt_items:    .space  2
cnt_secret:   .space  2
snl_pointeron: .space 2
lumps:        .space  (2 * NUMLUMPS)
WI_X:         .space  2
WI_Y:         .space  2
WI_Y2:        .space  2
WI_N:         .space  2
WI_D:         .space  2
WI_T:         .space  4
WI_I:         .space  2
WI_LAST:      .space  2
WI_P:         .space  4               ; a patch

              .section cfar, rodata
lumpNames:    .asciz  "WIMAP0"
              .asciz  "WIF"
              .asciz  "WIENTER"
              .asciz  "WICOLON"
              .asciz  "WISUCKS"
              .asciz  "WIPCNT"
              .asciz  "WIURH0"
              .asciz  "WISPLAT"
              .asciz  "WIOSTK"
              .asciz  "WIOSTI"
              .asciz  "WISCRT2"
              .asciz  "WITIME"
              .asciz  "WIMSTT"
              .asciz  "WIPAR"
              .asciz  "WINUM0"
              .asciz  "WINUM1"
              .asciz  "WINUM2"
              .asciz  "WINUM3"
              .asciz  "WINUM4"
              .asciz  "WINUM5"
              .asciz  "WINUM6"
              .asciz  "WINUM7"
              .asciz  "WINUM8"
              .asciz  "WINUM9"
              .asciz  "WILV00"
              .asciz  "WILV01"
              .asciz  "WILV02"
              .asciz  "WILV03"
              .asciz  "WILV04"
              .asciz  "WILV05"
              .asciz  "WILV06"
              .asciz  "WILV07"
              .asciz  "WILV08"
lnodes:       .word   185, 164        ; the places of the levels on the map
              .word   148, 143
              .word   69, 122
              .word   209, 102
              .word   116, 89
              .word   166, 55
              .word   71, 56
              .word   135, 29
              .word   71, 24

;;; ---------------------------------------------------------------------------
;;; void WI_Init(void): the lump numbers of the pictures.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public WI_Init
WI_Init:      lda     ##.word0 lumpNames
              sta     .near WI_P
              lda     ##.word2 lumpNames
              sta     .near (WI_P+2)
              stz     .near WI_I
1$:           lda     .near WI_P            ; each name
              sta     dp:.tiny _Dp
              lda     .near (WI_P+2)
              sta     dp:.tiny (_Dp+2)
              jsl     long:W_GetNumForName
              ldx     .near WI_I
              sta     .near lumps,x
              lda     .near WI_P            ; the next name: after the 0
              sta     dp:.tiny _Dp
              lda     .near (WI_P+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##0
2$:           lda     [.tiny _Dp],y
              iny
              and     ##0x00ff
              bne     2$
              tya
              clc
              adc     .near WI_P
              sta     .near WI_P
              inc     .near WI_I
              inc     .near WI_I
              lda     .near WI_I
              cmp     ##(2 * NUMLUMPS)
              bcc     1$
              rtl

;;; drawLump: V_DrawNumPatchScaled(C, WI_Y, lumps[X]). X: a byte offset.
drawLump:     pha
              lda     .near lumps,x
              sta     dp:.tiny (_Dp+4)
              lda     .near WI_Y
              sta     dp:.tiny _Dp
              pla
              jsl     long:V_DrawNumPatchScaled
              rts

;;; lumpPatch: WI_P = the lump lumps[X].
lumpPatch:    lda     .near lumps,x
              jsl     long:W_GetLumpByNum
              sta     .near WI_P
              stx     .near (WI_P+2)
              rts

;;; patchArg: _Dp[4-7] = WI_P.
patchArg:     lda     .near WI_P
              sta     dp:.tiny (_Dp+4)
              lda     .near (WI_P+2)
              sta     dp:.tiny (_Dp+6)
              rts

;;; ---------------------------------------------------------------------------
;;; void WI_Start(wbstartstruct_t* wbs)    In: _Dp[0-3] (_g_wminfo).
;;; The counts from the start (at least 1 kill and 1 item to count).
;;; void WI_End(void): the counts do not show.
;;; ---------------------------------------------------------------------------
              .public WI_Start, WI_End
WI_Start:     stz     .near _g_acceleratestage ; WI_initVariables
              stz     .near cnt
              stz     .near bcnt
              lda     .near (WM+WM_MAXKILLS)
              ora     .near (WM+WM_MAXKILLS+2)
              bne     1$
              lda     ##1
              sta     .near (WM+WM_MAXKILLS)
1$:           lda     .near (WM+WM_MAXITEMS)
              ora     .near (WM+WM_MAXITEMS+2)
              bne     2$
              lda     ##1
              sta     .near (WM+WM_MAXITEMS)
2$:           stz     .near state           ; WI_initStats: StatCount
              stz     .near _g_acceleratestage
              lda     ##1
              sta     .near sp_state
              lda     ##0xffff
              sta     .near cnt_kills
              sta     .near cnt_secret
              sta     .near cnt_items
              sta     .near cnt_time
              sta     .near (cnt_time+2)
              sta     .near cnt_par
              sta     .near cnt_total_time
              sta     .near (cnt_total_time+2)
              lda     ##CONST_TICRATE
              sta     .near cnt_pause
              rtl
WI_End:       lda     ##0xffff
              sta     .near cnt_kills
              sta     .near cnt_secret
              sta     .near cnt_items
              rtl

;;; ---------------------------------------------------------------------------
;;; void WI_checkForAccelerate(void): a new press of fire or use asks to
;;; go on.
;;; ---------------------------------------------------------------------------
              .public WI_checkForAccelerate
WI_checkForAccelerate:
              lda     .near (PL+OFS_PL_CMD+OFS_TC_BUTTONS)
              bit     ##BT_ATTACK
              beq     2$
              ldx     .near (PL+OFS_PL_ATTACKDOWN)
              bne     1$
              ldx     ##1
              stx     .near _g_acceleratestage
1$:           ldx     ##1
              stx     .near (PL+OFS_PL_ATTACKDOWN)
              bra     3$
2$:           stz     .near (PL+OFS_PL_ATTACKDOWN)
3$:           bit     ##BT_USE
              beq     5$
              ldx     .near (PL+OFS_PL_USEDOWN)
              bne     4$
              ldx     ##1
              stx     .near _g_acceleratestage
4$:           ldx     ##1
              stx     .near (PL+OFS_PL_USEDOWN)
              rtl
5$:           stz     .near (PL+OFS_PL_USEDOWN)
              rtl

;;; ---------------------------------------------------------------------------
;;; void WI_Ticker(void): the stage of the state.
;;; ---------------------------------------------------------------------------
              .public WI_Ticker
WI_Ticker:    inc     .near bcnt
              jsl     long:WI_checkForAccelerate
              lda     .near state
              beq     updateStats
              bmi     updateNoState
              dec     .near cnt             ; ShowNextLoc: the delay, or a
              beq     initNoState           ;   request: NoState
              lda     .near _g_acceleratestage
              bne     initNoState
              lda     .near cnt             ; the pointer blinks
              and     ##31
              ldx     ##0
              cmp     ##20
              bcs     1$
              inx
1$:           stx     .near snl_pointeron
              rtl
initNoState:  lda     ##NOSTATE             ; WI_initNoState
              sta     .near state
              stz     .near _g_acceleratestage
              lda     ##10
              sta     .near cnt
              rtl
updateNoState:
              dec     .near cnt
              bne     1$
              jmp     long:G_WorldDone
1$:           rtl

;;; initShowNextLoc: WI_initShowNextLoc: after map 8 the next world; else
;;; the map with the next level for 4 s.
initShowNextLoc:
              lda     .near _g_gamemap
              cmp     ##8
              bne     1$
              jsl     long:G_WorldDone
              rts
1$:           lda     ##SHOWNEXTLOC
              sta     .near state
              stz     .near _g_acceleratestage
              lda     ##(SHOWNEXTLOCDELAY * CONST_TICRATE)
              sta     .near cnt
              rts

;;; updateStats: WI_updateStats: the counts go up in turn (a pause between
;;; them); a request shows them all at once; then a request goes on.
updateStats:  lda     .near _g_acceleratestage
              beq     1$
              lda     .near sp_state
              cmp     ##10
              beq     1$
              stz     .near _g_acceleratestage ; all at once
              jsr     .kbank killsTotal
              sta     .near cnt_kills
              jsr     .kbank itemsTotal
              sta     .near cnt_items
              jsr     .kbank secretTotal
              sta     .near cnt_secret
              jsr     .kbank totalTimeTotal
              sta     .near cnt_total_time
              stx     .near (cnt_total_time+2)
              jsr     .kbank timeTotal
              sta     .near cnt_time
              stx     .near (cnt_time+2)
              jsr     .kbank parTotal
              sta     .near cnt_par
              jsr     .kbank soundBarexp
              lda     ##10
              sta     .near sp_state
1$:           lda     .near sp_state
              cmp     ##2
              bne     2$
              jsr     .kbank killsTotal     ; kills
              sta     .near WI_T
              stx     .near (WI_T+2)
              lda     ##.near cnt_kills
              brl     countUp
2$:           cmp     ##4
              bne     3$
              jsr     .kbank itemsTotal     ; items
              sta     .near WI_T
              stx     .near (WI_T+2)
              lda     ##.near cnt_items
              brl     countUp
3$:           cmp     ##6
              bne     4$
              jsr     .kbank secretTotal    ; secret
              sta     .near WI_T
              stx     .near (WI_T+2)
              lda     ##.near cnt_secret
              brl     countUp
4$:           cmp     ##8
              bne     5$
              brl     countTimes
5$:           cmp     ##10
              bne     6$
              lda     .near _g_acceleratestage ; the end: a request goes on
              beq     9$
              lda     ##CONST_SFX_SGCOCK
              jsr     .kbank sound
              jsr     .kbank initShowNextLoc
              rtl
6$:           and     ##1                   ; odd: a pause
              beq     9$
              dec     .near cnt_pause
              bne     9$
              inc     .near sp_state
              lda     ##CONST_TICRATE
              sta     .near cnt_pause
9$:           rtl

;;; countUp: the count at the near address C goes up by 2 (a pistol sound
;;; every 4 tics); at the total WI_T (int32) or more: the total, a sound,
;;; the next stage.
countUp:      sta     .near WI_N
              tax
              lda     abs:0,x
              clc
              adc     ##2
              sta     abs:0,x
              jsr     .kbank pistolSound
              ldx     .near WI_N            ; count >= total (int16 as int32)
              lda     abs:0,x
              pha
              cmp     .near WI_T
              ldy     ##0
              pla
              bpl     1$
              dey
1$:           tya
              sbc     .near (WI_T+2)
              bvc     2$
              eor     ##0x8000
2$:           bmi     9$
              lda     .near WI_T
              sta     abs:0,x
              jsr     .kbank soundBarexp
              inc     .near sp_state
9$:           rtl

;;; countTimes: sp_state 8: the times go up by 3 to their totals; then (par
;;; at its total and the others too) the next stage.
countTimes:   jsr     .kbank pistolSound
              lda     .near cnt_time        ; time += 3, at most its total
              clc
              adc     ##3
              sta     .near cnt_time
              bcc     1$
              inc     .near (cnt_time+2)
1$:           jsr     .kbank timeTotal
              ldy     ##.near cnt_time
              jsr     .kbank cmpCount
              bmi     2$
              sta     .near cnt_time
              stx     .near (cnt_time+2)
2$:           lda     .near cnt_total_time  ; total += 3, at most its total
              clc
              adc     ##3
              sta     .near cnt_total_time
              bcc     3$
              inc     .near (cnt_total_time+2)
3$:           jsr     .kbank totalTimeTotal
              ldy     ##.near cnt_total_time
              jsr     .kbank cmpCount
              bmi     4$
              sta     .near cnt_total_time
              stx     .near (cnt_total_time+2)
4$:           lda     .near cnt_par         ; par += 3
              clc
              adc     ##3
              sta     .near cnt_par
              jsr     .kbank parTotal       ; par >= its total: the end
              sta     .near WI_N
              lda     .near cnt_par
              sec
              sbc     .near WI_N
              bvc     5$
              eor     ##0x8000
5$:           bmi     9$
              lda     .near WI_N
              sta     .near cnt_par
              jsr     .kbank timeTotal      ; and the times at theirs
              ldy     ##.near cnt_time
              jsr     .kbank cmpCount
              bmi     9$
              jsr     .kbank totalTimeTotal
              ldy     ##.near cnt_total_time
              jsr     .kbank cmpCount
              bmi     9$
              jsr     .kbank soundBarexp
              inc     .near sp_state
9$:           rtl

;;; cmpCount: N set if the int32 at the near address Y < X:C (signed);
;;; X:C stay.
cmpCount:     sta     .near WI_T
              stx     .near (WI_T+2)
              lda     abs:0,y
              cmp     .near WI_T
              lda     abs:2,y
              sbc     .near (WI_T+2)
              bvc     1$
              eor     ##0x8000
1$:           php
              lda     .near WI_T
              ldx     .near (WI_T+2)
              plp
              rts

;;; pistolSound: a pistol sound every 4 tics.
pistolSound:  lda     .near bcnt
              and     ##3
              bne     1$
              lda     ##CONST_SFX_PISTOL
              brl     sound
1$:           rts

;;; soundBarexp: S_StartSound(NULL, sfx_barexp). sound: S_StartSound(NULL, C).
soundBarexp:  lda     ##CONST_SFX_BAREXP
sound:        stz     dp:.tiny _Dp
              stz     dp:.tiny (_Dp+2)
              jsl     long:S_StartSound
              rts

;;; killsTotal, itemsTotal, secretTotal: X:C = the total percent (count *
;;; 100 / maximum, int32; 100 for no secret).
killsTotal:   ldx     ##WM_SKILLS
              ldy     ##WM_MAXKILLS
              bra     percent
itemsTotal:   ldx     ##WM_SITEMS
              ldy     ##WM_MAXITEMS
              bra     percent
secretTotal:  lda     .near (WM+WM_MAXSECRET)
              ora     .near (WM+WM_MAXSECRET+2)
              bne     1$
              lda     ##100
              ldx     ##0
              rts
1$:           ldx     ##WM_SSECRET
              ldy     ##WM_MAXSECRET
percent:      lda     .near WM,y            ; _Dp+4: the maximum
              sta     dp:.tiny (_Dp+4)
              lda     .near (WM+2),y
              sta     dp:.tiny (_Dp+6)
              lda     .near WM,x            ; the count * 100 (int32)
              sta     dp:.tiny _Dp
              lda     .near (WM+2),x
              sta     dp:.tiny (_Dp+2)
              jsr     .kbank times100
              jsl     long:_Div32
              rts

;;; times100: _Dp[0-3] *= 100 (int32): * 4 + * 32 + * 64.
times100:     asl     dp:.tiny _Dp
              rol     dp:.tiny (_Dp+2)
              asl     dp:.tiny _Dp
              rol     dp:.tiny (_Dp+2)
              lda     dp:.tiny _Dp
              sta     .near WI_T
              lda     dp:.tiny (_Dp+2)
              sta     .near (WI_T+2)
              ldx     ##3
1$:           asl     dp:.tiny _Dp
              rol     dp:.tiny (_Dp+2)
              dex
              bne     1$
              jsr     .kbank addT
              asl     dp:.tiny _Dp
              rol     dp:.tiny (_Dp+2)
              jsr     .kbank addT
              lda     .near WI_T
              sta     dp:.tiny _Dp
              lda     .near (WI_T+2)
              sta     dp:.tiny (_Dp+2)
              rts
addT:         lda     .near WI_T
              clc
              adc     dp:.tiny _Dp
              sta     .near WI_T
              lda     .near (WI_T+2)
              adc     dp:.tiny (_Dp+2)
              sta     .near (WI_T+2)
              rts

;;; timeTotal, totalTimeTotal: X:C = stime / TICRATE, totaltimes / TICRATE
;;; (int32). parTotal: C = partime / TICRATE (int16).
timeTotal:    ldx     ##WM_STIME
              bra     seconds
totalTimeTotal:
              ldx     ##WM_TOTALTIMES
seconds:      lda     .near WM,x
              sta     dp:.tiny _Dp
              lda     .near (WM+2),x
              sta     dp:.tiny (_Dp+2)
              bra     divTicrate
parTotal:     lda     .near (WM+WM_PARTIME)
              sta     dp:.tiny _Dp
              ldx     ##0
              cmp     ##0
              bpl     1$
              dex
1$:           stx     dp:.tiny (_Dp+2)
divTicrate:   lda     ##CONST_TICRATE
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_Div32
              rts

;;; ---------------------------------------------------------------------------
;;; void WI_Drawer(void): the counts, or the map with the next level.
;;; ---------------------------------------------------------------------------
              .public WI_Drawer
WI_Drawer:    lda     .near state
              bne     1$
              brl     drawStats
1$:           bpl     2$
              lda     ##1                   ; NoState: the pointer shows
              sta     .near snl_pointeron
2$:           jsr     .kbank drawShowNextLoc
              rtl

;;; drawShowNextLoc: WI_drawShowNextLoc: the map, the splats of the levels
;;; done (after the secret level: to the one before the next), the secret
;;; level, "you are here", and "entering" the next level.
drawShowNextLoc:
              jsr     .kbank slamBackground
              lda     .near (WM+WM_LAST)
              cmp     ##8
              bne     1$
              lda     .near (WM+WM_NEXT)
              dec     a
1$:           sta     .near WI_LAST
              stz     .near WI_I
2$:           lda     .near WI_I            ; for i <= last (signed)
              sec
              sbc     .near WI_LAST
              beq     3$
              bvc     21$
              eor     ##0x8000
21$:          bpl     4$
3$:           lda     .near WI_I
              ldx     ##L_WISPLAT
              jsr     .kbank drawAtNode
              inc     .near WI_I
              bra     2$
4$:           lda     .near (WM+WM_DIDSECRET)
              beq     5$
              lda     ##8
              ldx     ##L_WISPLAT
              jsr     .kbank drawAtNode
5$:           lda     .near snl_pointeron
              beq     6$
              lda     .near (WM+WM_NEXT)
              ldx     ##L_WIURH0
              jsr     .kbank drawAtNode
6$:           lda     .near (WM+WM_NEXT)    ; WI_drawEL: "entering" at the
              jsr     .kbank levelLump      ;   top, the level name under it
              jsr     .kbank lumpPatch      ;   (the name patch: its height)
              lda     .near WI_P
              pha
              lda     .near (WI_P+2)
              pha
              lda     ##WI_TITLEY
              sta     .near WI_Y
              jsr     .kbank nextY
              ldx     ##L_WIENTER
              jsr     .kbank lumpPatch
              jsr     .kbank drawCenteredPatch
              pla
              sta     .near (WI_P+2)
              pla
              sta     .near WI_P
              lda     .near WI_Y2
              sta     .near WI_Y
              jsr     .kbank drawCenteredPatch
              rts

;;; drawAtNode: keep the original nodes and splats. The top two pointers
;;; sit below the title/name band (rows 2..28), including the secret map.
drawAtNode:   asl     a
              asl     a
              phx
              tax
              lda     long:(lnodes+2),x
              sta     .near WI_Y
              lda     long:lnodes,x
              plx
              cpx     ##L_WIURH0
              bne     1$
              pha
              lda     .near WI_Y
              cmp     ##45                  ; patch top = node y - 15
              bcs     2$
              lda     ##45
              sta     .near WI_Y
2$:           pla
1$:           brl     drawLump

;;; slamBackground: the map picture.
slamBackground:
              lda     .near (lumps+L_WIMAP0)
              jsl     long:V_DrawRawFullScreen
              rts

;;; levelLump: X = the byte offset of the lump WILV0n of level C.
levelLump:    asl     a
              clc
              adc     ##L_WILV
              tax
              rts

;;; drawCenteredPatch: V_DrawPatchScaled((SCREENW - width) / 2, WI_Y, WI_P).
drawCenteredPatch:
              jsr     .kbank patchArg
              lda     ##SCREENW
              sec
              sbc     [.tiny (_Dp+4)]
              cmp     ##0x8000
              ror     a
              pha
              lda     .near WI_Y
              sta     dp:.tiny _Dp
              pla
              jsl     long:V_DrawPatchScaled
              rts

;;; nextY: WI_Y2 = WI_Y + (5 * the height of WI_P) / 4 (heights are small
;;; and positive).
nextY:        jsr     .kbank patchArg
              ldy     ##OFS_PATCH_HEIGHT
              lda     [.tiny (_Dp+4)],y
              sta     .near WI_N
              asl     a
              asl     a
              clc
              adc     .near WI_N
              lsr     a
              lsr     a
              clc
              adc     .near WI_Y
              sta     .near WI_Y2
              rts

;;; drawStats: the map picture, the level finished (WI_drawLF), the counts
;;; (WI_drawStats).
drawStats:    jsr     .kbank slamBackground
              lda     .near (WM+WM_LAST)    ; the level name at the top,
              jsr     .kbank levelLump      ;   "finished" under it
              jsr     .kbank lumpPatch
              lda     ##WI_TITLEY
              sta     .near WI_Y
              jsr     .kbank nextY
              jsr     .kbank drawCenteredPatch
              lda     .near WI_Y2
              sta     .near WI_Y
              ldx     ##L_WIF
              jsr     .kbank lumpPatch
              jsr     .kbank drawCenteredPatch
              lda     ##SP_STATSY           ; kills, items, secret
              sta     .near WI_Y
              lda     ##SP_STATSX
              ldx     ##L_WIOSTK
              jsr     .kbank drawLump
              lda     .near cnt_kills
              jsr     .kbank drawPercent
              lda     ##(SP_STATSY+LINEHEIGHT)
              sta     .near WI_Y
              lda     ##SP_STATSX
              ldx     ##L_WIOSTI
              jsr     .kbank drawLump
              lda     .near cnt_items
              jsr     .kbank drawPercent
              lda     ##(SP_STATSY+2*LINEHEIGHT)
              sta     .near WI_Y
              lda     ##SP_STATSX
              ldx     ##L_WISCRT2
              jsr     .kbank drawLump
              lda     .near cnt_secret
              jsr     .kbank drawPercent
              lda     ##SP_TIMEY            ; time
              sta     .near WI_Y
              lda     ##SP_TIMEX
              ldx     ##L_WITIME
              jsr     .kbank drawLump
              lda     ##(SCREENW/2-SP_TIMEX)
              sta     .near WI_X
              lda     .near cnt_time
              ldx     .near (cnt_time+2)
              jsr     .kbank drawTime
              lda     ##((SP_TIMEY+SCREENH)/2) ; total
              sta     .near WI_Y
              lda     ##SP_TIMEX
              ldx     ##L_WIMSTT
              jsr     .kbank drawLump
              lda     ##(SCREENW/2-SP_TIMEX)
              sta     .near WI_X
              lda     .near cnt_total_time
              ldx     .near (cnt_total_time+2)
              jsr     .kbank drawTime
              lda     ##SP_TIMEY            ; par
              sta     .near WI_Y
              lda     ##(SCREENW/2+SP_TIMEX)
              ldx     ##L_WIPAR
              jsr     .kbank drawLump
              lda     ##(SCREENW-SP_TIMEX)
              sta     .near WI_X
              lda     .near cnt_par
              ldx     ##0
              cmp     ##0
              bpl     1$
              dex
1$:           jsr     .kbank drawTime
              rtl

;;; drawPercent: WI_drawPercent(SCREENW - SP_STATSX, WI_Y, C): nothing for
;;; a negative p; else the sign and the digits.
drawPercent:  cmp     ##0
              bmi     9$
              sta     .near WI_N
              lda     ##(SCREENW-SP_STATSX)
              sta     .near WI_X
              ldx     ##L_WIPCNT
              jsr     .kbank drawLump
              jsr     .kbank digitCount
              brl     drawNum
9$:           rts

;;; digitCount: C = WI_calculateDigits(WI_N): 1 for 0, else the number
;;; of decimal digits (WI_N >= 0).
digitCount:   lda     .near WI_N
              bne     1$
              lda     ##1
              rts
1$:           ldy     ##0
2$:           iny
              ldx     ##10
              phy
              jsl     long:_UDivMod16       ; X = the quotient
              ply
              txa
              bne     2$
              tya
              rts

;;; drawNum: WI_drawNum(WI_X, WI_Y, WI_N, C digits): the digits from the
;;; right (11 pixels each); WI_X = the left end.
drawNum:      sta     .near WI_D
1$:           lda     .near WI_D
              beq     2$
              dec     .near WI_D
              lda     .near WI_X
              sec
              sbc     ##FONTWIDTH
              sta     .near WI_X
              lda     .near WI_N            ; the digit n % 10, n /= 10
              ldx     ##10
              jsl     long:_UDivMod16
              stx     .near WI_N
              asl     a
              clc
              adc     ##L_WINUM
              tax
              lda     .near WI_X
              jsr     .kbank drawLump
              bra     1$
2$:           rts

;;; drawTime: always minutes:seconds, including 0:00. Keep Doom's hours
;;; and its >= 24 hour fallback. WI_LAST counts fields; drawStats does not
;;; use it, and drawShowNextLoc resets it before drawing nodes.
drawTime:     cpx     ##0
              bpl     1$
              rts
1$:           sta     .near WI_T
              stx     .near (WI_T+2)
              cmp     ##0x5180
              txa
              sbc     ##0x0001
              bcc     2$
              ldx     ##L_WISUCKS
              jsr     .kbank lumpPatch
              jsr     .kbank patchArg
              lda     .near WI_X
              sec
              sbc     [.tiny (_Dp+4)]
              pha
              lda     .near WI_Y
              sta     dp:.tiny _Dp
              pla
              jsl     long:V_DrawPatchScaled
              rts
2$:           stz     .near WI_LAST
3$:           lda     .near WI_T
              sta     dp:.tiny _Dp
              lda     .near (WI_T+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##60
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_UDivMod32
              sta     .near WI_T
              stx     .near (WI_T+2)
              lda     dp:.tiny _Dp
              sta     .near WI_N
              lda     .near WI_LAST        ; seconds always have two digits
              beq     4$
              lda     .near WI_T
              ora     .near (WI_T+2)
              bne     4$                    ; minutes below hours: two too
              jsr     .kbank digitCount
              bra     5$
4$:           lda     ##2
5$:           jsr     .kbank drawNum
              lda     .near WI_LAST
              beq     6$                    ; always draw the first colon
              lda     .near WI_T
              ora     .near (WI_T+2)
              beq     9$
6$:           inc     .near WI_LAST
              ldx     ##L_WICOLON
              jsr     .kbank lumpPatch
              jsr     .kbank patchArg
              lda     .near WI_X
              sec
              sbc     [.tiny (_Dp+4)]
              sta     .near WI_X
              ldx     ##L_WICOLON
              jsr     .kbank drawLump
              bra     3$
9$:           rts
