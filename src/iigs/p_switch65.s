;;; Line-special dispatch and switch/button textures.
;;;
;;; P_UseSpecialLine and P_CrossSpecialLine route a triggered line to its
;;; door, floor, platform or other action. Switch textures stay changed;
;;; timed buttons retain the original texture so the timer can restore it.
;;; Manual-door movement is implemented by p_doors65.s:EV_VerticalDoor.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"

              .extern _Dp, _g_sides, _g_player, IIGS_MulLo16, I_Error
              .extern R_CheckTextureNumForName, R_GetTexture
              .extern S_StartSound, S_StartSound2, P_CheckTag
              .extern EV_VerticalDoor, EV_BuildStairs, EV_DoDonut, EV_DoFloor
              .extern EV_DoPlat, EV_DoDoor, G_ExitLevel, G_SecretExitLevel
              .extern EV_LightTurnOn, EV_Teleport

NUMSW2        .equ    38              ; MAXSWITCHES * 2: the off and on textures
BUTTONTIME    .equ    CONST_TICRATE

              .section znear, bss
              .public _g_buttonlist
_g_buttonlist:
              .space  (CONST_MAXBUTTONS * SIZEOF_BTN)
              .public switchlist            ; (W_LevelDone of src/iigs/w_level65.s)
switchlist:   .space  (NUMSW2 * 2)    ; the texture numbers, off and on
SW_I:         .space  2
SW_P:         .space  2               ; the name of switch texture SW_I / 2
SW_LINE:      .space  4               ; the line
SW_THING:     .space  4               ; P_UseSpecialLine: the thing
SW_SIDE:      .space  4               ; the front side of the line
SW_ORG:       .space  4               ; &frontsector->soundorg
SW_AGAIN:     .space  2               ; useAgain
SW_POS:       .space  2               ; top, middle, bottom
SW_TEX:       .space  2               ; the texture of the switch
SW_TTOP:      .space  2
SW_TMID:      .space  2
SW_TBOT:      .space  2
SW_CSIDE:     .space  2               ; P_CrossSpecialLine: the side
SW_END:       .space  2               ; findSpecial: the end of the table

              .section coldfar, bss
SW_IDX:       .space  256             ; 2 * i + 1 for the first switchlist[i]
                                      ;   of texture t < 256 at SW_IDX + t, 0:
                                      ;   not a switch (P_LoadTexture)

              .section cfar, rodata
;;; alphSwitchList: the off and on texture of each switch, 9 bytes each
swnames:      .asciz  "SW1BRCOM"
              .asciz  "SW2BRCOM"
              .asciz  "SW1BRN1"
              .byte   0
              .asciz  "SW2BRN1"
              .byte   0
              .asciz  "SW1BRN2"
              .byte   0
              .asciz  "SW2BRN2"
              .byte   0
              .asciz  "SW1BRNGN"
              .asciz  "SW2BRNGN"
              .asciz  "SW1BROWN"
              .asciz  "SW2BROWN"
              .asciz  "SW1COMM"
              .byte   0
              .asciz  "SW2COMM"
              .byte   0
              .asciz  "SW1COMP"
              .byte   0
              .asciz  "SW2COMP"
              .byte   0
              .asciz  "SW1DIRT"
              .byte   0
              .asciz  "SW2DIRT"
              .byte   0
              .asciz  "SW1EXIT"
              .byte   0
              .asciz  "SW2EXIT"
              .byte   0
              .asciz  "SW1GRAY"
              .byte   0
              .asciz  "SW2GRAY"
              .byte   0
              .asciz  "SW1GRAY1"
              .asciz  "SW2GRAY1"
              .asciz  "SW1METAL"
              .asciz  "SW2METAL"
              .asciz  "SW1PIPE"
              .byte   0
              .asciz  "SW2PIPE"
              .byte   0
              .asciz  "SW1SLAD"
              .byte   0
              .asciz  "SW2SLAD"
              .byte   0
              .asciz  "SW1STARG"
              .asciz  "SW2STARG"
              .asciz  "SW1STON1"
              .asciz  "SW2STON1"
              .asciz  "SW1STON2"
              .asciz  "SW2STON2"
              .asciz  "SW1STONE"
              .asciz  "SW2STONE"
              .asciz  "SW1STRTN"
              .asciz  "SW2STRTN"
swnames_end:
btnerr:       .asciz  "P_StartButton: no button slots left!"

;;; ---------------------------------------------------------------------------
;;; void P_InitSwitchList(void): the texture numbers of the switches.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public P_InitSwitchList
P_InitSwitchList:
              stz     .near SW_I
              lda     ##.word0 swnames
              sta     .near SW_P
1$:           lda     .near SW_P
              sta     dp:.tiny _Dp
              lda     ##.word2 swnames
              sta     dp:.tiny (_Dp+2)
              jsl     long:R_CheckTextureNumForName
              ldx     .near SW_I
              sta     abs:.near switchlist,x
              inx
              inx
              stx     .near SW_I
              lda     .near SW_P
              clc
              adc     ##9
              sta     .near SW_P
              cpx     ##(NUMSW2 * 2)
              bcc     1$
              ldx     ##254                 ; SW_IDX: no switches
              lda     ##0
2$:           sta     long:SW_IDX,x
              dex
              dex
              bpl     2$
              ldx     ##((NUMSW2 - 1) * 2)  ; the first switch of each texture
3$:           lda     abs:.near switchlist,x ; wins: from the last one down
              cmp     ##256                 ; (-1: not in the WAD)
              bcs     4$
              phx
              tax
              pla
              pha
              inc     a                     ; 2 * i + 1
              sep     #0x20
              sta     long:SW_IDX,x
              rep     #0x20
              plx
4$:           dex
              dex
              bpl     3$
              rtl

;;; ---------------------------------------------------------------------------
;;; void P_LoadTexture(int16_t texture): the texture, and the other texture
;;; of a switch.
;;; ---------------------------------------------------------------------------
              .public P_LoadTexture
P_LoadTexture:
              pha
              jsl     long:R_GetTexture
              pla
              cmp     ##256                 ; (texture numbers are below 256:
              bcs     2$                    ;   COLDIR of src/iigs/r_data65.s)
              tax
              lda     long:SW_IDX,x         ; a switch: the other texture,
              and     ##0x00ff              ;   switchlist[i ^ 1]
              beq     1$
              dec     a
              eor     ##2
              tax
              lda     abs:.near switchlist,x
              jmp     long:R_GetTexture
1$:           rtl
2$:           jsr     .kbank findSwitch
              bcs     3$
              rtl
3$:           txa                           ; the other one: i ^ 1
              eor     ##2
              tax
              lda     abs:.near switchlist,x
              jmp     long:R_GetTexture

;;; findSwitch: carry set and X = 2 * i if switchlist[i] == C.
findSwitch:   ldx     ##0
1$:           cmp     abs:.near switchlist,x
              beq     2$
              inx
              inx
              cpx     ##(NUMSW2 * 2)
              bcc     1$
              clc
              rts
2$:           sec
              rts

;;; ---------------------------------------------------------------------------
;;; void P_ChangeSwitchTexture(line_t __far* line, boolean useAgain)
;;; The switch texture of the front side changes to the other one, with the
;;; switch sound; a used up line loses its special; a button changes back
;;; after BUTTONTIME.
;;; ---------------------------------------------------------------------------
              .public P_ChangeSwitchTexture
P_ChangeSwitchTexture:
              sta     .near SW_AGAIN
              lda     dp:.tiny _Dp
              sta     .near SW_LINE
              lda     dp:.tiny (_Dp+2)
              sta     .near (SW_LINE+2)
              ldy     ##OFS_LINE_SIDENUM    ; the front side
              lda     [.tiny _Dp],y
              ldx     ##SIZEOF_SIDE
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sides
              sta     .near SW_SIDE
              lda     .near (_g_sides+2)
              sta     .near (SW_SIDE+2)
              lda     .near SW_AGAIN        ; not again: line->special = 0
              bne     1$
              jsr     .kbank swLine
              ldy     ##OFS_LINE_SPECIAL
              lda     ##0
              sta     [.tiny _Dp],y
1$:           jsr     .kbank swSide         ; the three textures
              ldy     ##OFS_SIDE_TOPTEXTURE
              lda     [.tiny _Dp],y
              sta     .near SW_TTOP
              ldy     ##OFS_SIDE_MIDTEXTURE
              lda     [.tiny _Dp],y
              sta     .near SW_TMID
              ldy     ##OFS_SIDE_BOTTOMTEXTURE
              lda     [.tiny _Dp],y
              sta     .near SW_TBOT
              ldx     ##0                   ; the first switch texture of the three
2$:           lda     abs:.near switchlist,x
              cmp     .near SW_TTOP
              bne     21$
              ldy     ##OFS_SIDE_TOPTEXTURE
              lda     ##CONST_TOP
              bra     3$
21$:          cmp     .near SW_TMID
              bne     22$
              ldy     ##OFS_SIDE_MIDTEXTURE
              lda     ##CONST_MIDDLE
              bra     3$
22$:          cmp     .near SW_TBOT
              bne     23$
              ldy     ##OFS_SIDE_BOTTOMTEXTURE
              lda     ##CONST_BOTTOM
              bra     3$
23$:          inx
              inx
              cpx     ##(NUMSW2 * 2)
              bcc     2$
              rtl                           ; none
3$:           sta     .near SW_POS
              lda     abs:.near switchlist,x
              sta     .near SW_TEX
              txa                           ; the texture = switchlist[i ^ 1]
              eor     ##2
              tax
              lda     abs:.near switchlist,x
              pha
              jsr     .kbank swSide
              pla
              sta     [.tiny _Dp],y
              ldy     ##(OFS_SIDE_SECTOR+2) ; the sound at the front sector
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SIDE_SECTOR
              lda     [.tiny _Dp],y
              clc
              adc     ##OFS_SEC_SOUNDORG
              sta     .near SW_ORG
              stx     .near (SW_ORG+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     ##CONST_SFX_SWTCHN
              jsl     long:S_StartSound2
              lda     .near SW_AGAIN
              bne     startButton
              rtl

;;; startButton: P_StartButton(SW_LINE, SW_POS, SW_TEX, BUTTONTIME): a
;;; button for the line if it has none, in the first free slot.
startButton:  ldx     ##0
1$:           lda     abs:.near (_g_buttonlist+OFS_BTN_BTIMER),x
              beq     2$
              lda     abs:.near (_g_buttonlist+OFS_BTN_LINE),x
              cmp     .near SW_LINE
              bne     2$
              lda     abs:.near (_g_buttonlist+OFS_BTN_LINE+2),x
              cmp     .near (SW_LINE+2)
              bne     2$
              rtl                           ; pressed already
2$:           txa
              clc
              adc     ##SIZEOF_BTN
              tax
              cpx     ##(CONST_MAXBUTTONS * SIZEOF_BTN)
              bcc     1$
              ldx     ##0
3$:           lda     abs:.near (_g_buttonlist+OFS_BTN_BTIMER),x
              beq     4$
              txa
              clc
              adc     ##SIZEOF_BTN
              tax
              cpx     ##(CONST_MAXBUTTONS * SIZEOF_BTN)
              bcc     3$
              lda     ##.word0 btnerr
              sta     dp:.tiny _Dp
              lda     ##.word2 btnerr
              sta     dp:.tiny (_Dp+2)
              jmp     long:I_Error
4$:           lda     .near SW_LINE
              sta     abs:.near (_g_buttonlist+OFS_BTN_LINE),x
              lda     .near (SW_LINE+2)
              sta     abs:.near (_g_buttonlist+OFS_BTN_LINE+2),x
              lda     .near SW_POS
              sta     abs:.near (_g_buttonlist+OFS_BTN_WHERE),x
              lda     .near SW_TEX
              sta     abs:.near (_g_buttonlist+OFS_BTN_BTEXTURE),x
              lda     ##BUTTONTIME
              sta     abs:.near (_g_buttonlist+OFS_BTN_BTIMER),x
              lda     .near SW_ORG
              sta     abs:.near (_g_buttonlist+OFS_BTN_SOUNDORG),x
              lda     .near (SW_ORG+2)
              sta     abs:.near (_g_buttonlist+OFS_BTN_SOUNDORG+2),x
              rtl

;;; swLine, swSide: _Dp[0-3] = SW_LINE, SW_SIDE.
swLine:       lda     .near SW_LINE
              sta     dp:.tiny _Dp
              lda     .near (SW_LINE+2)
              sta     dp:.tiny (_Dp+2)
              rts
swSide:       lda     .near SW_SIDE
              sta     dp:.tiny _Dp
              lda     .near (SW_SIDE+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; isPlayer: Z set if SW_THING is the mobj of the player.
isPlayer:     lda     .near (_g_player+OFS_PL_MO)
              cmp     .near SW_THING
              bne     1$
              lda     .near (_g_player+OFS_PL_MO+2)
              cmp     .near (SW_THING+2)
1$:           rts

;;; ---------------------------------------------------------------------------
;;; boolean P_UseSpecialLine(mobj_t __far* thing, line_t __far* line)
;;; A thing uses (pushes) a line: the action of its special (usetab).
;;; Monsters can only open the manual doors that are not secret.
;;; ---------------------------------------------------------------------------
              .public P_UseSpecialLine
P_UseSpecialLine:
              lda     dp:.tiny _Dp
              sta     .near SW_THING
              lda     dp:.tiny (_Dp+2)
              sta     .near (SW_THING+2)
              lda     dp:.tiny (_Dp+4)
              sta     .near SW_LINE
              lda     dp:.tiny (_Dp+6)
              sta     .near (SW_LINE+2)
              jsr     .kbank isPlayer
              beq     2$
              jsr     .kbank swLine         ; a monster: not a secret line
              ldy     ##OFS_LINE_FLAGS
              lda     [.tiny _Dp],y
              and     ##CONST_ML_SECRET
              bne     1$
              ldy     ##OFS_LINE_SPECIAL    ; and only the manual doors 1, 32-34
              lda     [.tiny _Dp],y
              cmp     ##1
              beq     2$
              cmp     ##32
              bcc     1$
              cmp     ##35
              bcc     2$
1$:           lda     ##0
              rtl
2$:           ldx     ##(usetab - spectab)
              ldy     ##(usetab_end - spectab)
              jsr     .kbank findSpecial
              bcs     3$
              lda     ##1                   ; the other specials: nothing
              rtl
3$:           jsr     (.kbank (spectab+2),x)
              pha                           ; the result
              ldx     .near SW_I
              lda     long:(spectab+6),x    ; the mode
              tay
              pla
              cpy     ##0                   ; 0: the result of the routine
              beq     5$
              cmp     ##0                   ; 1, 2: true; a started thinker
              beq     4$                    ; changes the switch (1: once,
              dey                           ; 2: again)
              jsr     .kbank swLine
              tya
              jsl     long:P_ChangeSwitchTexture
4$:           lda     ##1
5$:           rtl

;;; ---------------------------------------------------------------------------
;;; void P_CrossSpecialLine(line_t __far* line, int16_t side, mobj_t __far* thing)
;;; A thing crosses a line with a special (crosstab). Monsters trigger only
;;; the teleporter 97 and the lift 88, and some missiles nothing; a walk
;;; once line loses its special when its action starts.
;;; ---------------------------------------------------------------------------
              .public P_CrossSpecialLine
P_CrossSpecialLine:
              sta     .near SW_CSIDE
              lda     dp:.tiny _Dp
              sta     .near SW_LINE
              lda     dp:.tiny (_Dp+2)
              sta     .near (SW_LINE+2)
              lda     dp:.tiny (_Dp+4)
              sta     .near SW_THING
              lda     dp:.tiny (_Dp+6)
              sta     .near (SW_THING+2)
              jsr     .kbank isPlayer
              beq     2$
              lda     .near SW_THING        ; not the player: not these missiles
              sta     dp:.tiny _Dp
              lda     .near (SW_THING+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_MO_TYPE
              lda     [.tiny _Dp],y
              cmp     ##CONST_MT_ROCKET
              beq     1$
              cmp     ##CONST_MT_TROOPSHOT
              beq     1$
              cmp     ##CONST_MT_BRUISERSHOT
              beq     1$
              jsr     .kbank swLine         ; and only 97 and 88
              ldy     ##OFS_LINE_SPECIAL
              lda     [.tiny _Dp],y
              cmp     ##97
              beq     2$
              cmp     ##88
              beq     2$
1$:           rtl
2$:           ldx     ##(crosstab - spectab)
              ldy     ##(crosstab_end - spectab)
              jsr     .kbank findSpecial
              bcc     1$
              jsr     (.kbank (spectab+2),x)
              tay                           ; Y = the result
              ldx     .near SW_I            ; walk once (1) and started: no
              lda     long:(spectab+6),x    ; more special
              beq     1$
              tya
              beq     1$
              jsr     .kbank swLine
              ldy     ##OFS_LINE_SPECIAL
              lda     ##0
              sta     [.tiny _Dp],y
              rtl

;;; findSpecial: P_CheckTag(SW_LINE) (a zero tag only for some types), then
;;; the special of SW_LINE in spectab from offset X to offset Y. Carry set
;;; when it is there: X = SW_I = its offset, C = its argument, _Dp[0-3] =
;;; the line.
findSpecial:  stx     .near SW_I
              sty     .near SW_END
              jsr     .kbank swLine
              jsl     long:P_CheckTag
              cmp     ##0
              beq     9$
              jsr     .kbank swLine
              ldy     ##OFS_LINE_SPECIAL
              lda     [.tiny _Dp],y
              sta     .near SW_TEX
              ldx     .near SW_I
1$:           lda     long:spectab,x
              cmp     .near SW_TEX
              beq     2$
              txa
              clc
              adc     ##8
              tax
              cpx     .near SW_END
              bcc     1$
9$:           clc
              rts
2$:           stx     .near SW_I
              lda     long:(spectab+4),x
              sec
              rts

;;; The routines of the specials: C = the argument, _Dp[0-3] = the line.
;;; Out: C = the result.
lnDoor:       jsl     long:EV_DoDoor
              rts
lnFloor:      jsl     long:EV_DoFloor
              rts
lnPlat:       jsl     long:EV_DoPlat
              rts
lnStairs:     jsl     long:EV_BuildStairs
              rts
lnDonut:      jsl     long:EV_DoDonut
              rts
lnLight:      jsl     long:EV_LightTurnOn
              lda     ##1
              rts
lnTele:       lda     .near SW_THING        ; EV_Teleport(line, side, thing)
              sta     dp:.tiny (_Dp+4)
              lda     .near (SW_THING+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near SW_CSIDE
              jsl     long:EV_Teleport
              rts
lnVDoor:      lda     .near SW_THING        ; EV_VerticalDoor(line, thing)
              sta     dp:.tiny (_Dp+4)
              lda     .near (SW_THING+2)
              sta     dp:.tiny (_Dp+6)
              jsl     long:EV_VerticalDoor
              lda     ##1
              rts

;;; lnExit: C = 0 the exit, 1 the secret exit. A dead player cannot leave
;;; (the sound noway, false); else the switch changes, true.
lnExit:       pha
              jsr     .kbank isPlayer
              bne     2$
              lda     .near (_g_player+OFS_PL_HEALTH)
              beq     1$
              bpl     2$
1$:           pla
              lda     .near SW_THING
              sta     dp:.tiny _Dp
              lda     .near (SW_THING+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##CONST_SFX_NOWAY
              jsl     long:S_StartSound
              lda     ##0
              rts
2$:           jsr     .kbank swLine
              lda     ##0
              jsl     long:P_ChangeSwitchTexture
              pla
              bne     3$
              jsl     long:G_ExitLevel
              lda     ##1
              rts
3$:           jsl     long:G_SecretExitLevel
              lda     ##1
              rts

;;; spectab: special, routine, argument, mode. In the code bank for
;;; jsr (spectab + 2, x).
;;; usetab, P_UseSpecialLine. Mode 0: the result of the routine; 1: the
;;; switch changes; 2: a button.
;;; crosstab, P_CrossSpecialLine. Mode 1: walk once.
spectab:
usetab:       .word   1, .word0 lnVDoor, 0, 0              ; the manual doors
              .word   26, .word0 lnVDoor, 0, 0
              .word   27, .word0 lnVDoor, 0, 0
              .word   28, .word0 lnVDoor, 0, 0
              .word   31, .word0 lnVDoor, 0, 0
              .word   32, .word0 lnVDoor, 0, 0
              .word   33, .word0 lnVDoor, 0, 0
              .word   34, .word0 lnVDoor, 0, 0
              .word   7, .word0 lnStairs, 0, 1             ; switches
              .word   9, .word0 lnDonut, 0, 1
              .word   11, .word0 lnExit, 0, 0
              .word   18, .word0 lnFloor, CONST_RAISEFLOORTONEAREST, 1
              .word   20, .word0 lnPlat, CONST_RAISETONEARESTANDCHANGE, 1
              .word   23, .word0 lnFloor, CONST_LOWERFLOORTOLOWEST, 1
              .word   51, .word0 lnExit, 1, 0
              .word   103, .word0 lnDoor, CONST_DOPEN, 1
              .word   62, .word0 lnPlat, CONST_DOWNWAITUPSTAY, 2 ; buttons
              .word   63, .word0 lnDoor, CONST_NORMAL, 2
              .word   70, .word0 lnFloor, CONST_TURBOLOWER, 2
usetab_end:
crosstab:     .word   2, .word0 lnDoor, CONST_DOPEN, 1     ; walk once
              .word   5, .word0 lnFloor, CONST_RAISEFLOOR, 1
              .word   8, .word0 lnStairs, 0, 1
              .word   16, .word0 lnDoor, CONST_CLOSE30THENOPEN, 1
              .word   22, .word0 lnPlat, CONST_RAISETONEARESTANDCHANGE, 1
              .word   35, .word0 lnLight, 35, 1
              .word   36, .word0 lnFloor, CONST_TURBOLOWER, 1
              .word   76, .word0 lnDoor, CONST_CLOSE30THENOPEN, 0 ; walk again
              .word   82, .word0 lnFloor, CONST_LOWERFLOORTOLOWEST, 0
              .word   86, .word0 lnDoor, CONST_DOPEN, 0
              .word   88, .word0 lnPlat, CONST_DOWNWAITUPSTAY, 0
              .word   90, .word0 lnDoor, CONST_NORMAL, 0
              .word   91, .word0 lnFloor, CONST_RAISEFLOOR, 0
              .word   97, .word0 lnTele, 0, 0
              .word   98, .word0 lnFloor, CONST_TURBOLOWER, 0
crosstab_end:
