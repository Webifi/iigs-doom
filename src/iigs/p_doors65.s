;;; Door thinkers and line actions.
;;;
;;; EV_DoDoor starts tagged doors; EV_VerticalDoor handles doors used directly
;;; by a player or actor. The door thinker owns direction, waiting time and
;;; ceiling movement, including gradual lighting for tagged manual doors.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "tics.inc"
#if TICSTEP > 1
              .extern ticRun
#endif

              .extern _Dp, _g_sectors, T_MovePlaneCeiling, S_StartSound2
              .extern P_RemoveThinker, P_AddThinker, Z_CallocLevSpec
              .extern P_FindSectorFromLineTag, getNextSector, FixedApproxDiv
              .extern P_FindLowestCeilingSurrounding, IIGS_MulLo16, _Mul32
              .extern _g_sides, _g_player, S_StartSound

VDOORSPEED_HI .equ    2               ; door speed: 2 map units per tic
VDOORWAIT     .equ    150

              .section znear, bss
DR_DOOR:      .space  4               ; the door thinker
DR_RES:       .space  2               ; the result of the plane move
DR_T:         .space  4
DL_LINE:      .space  4               ; EV_LightTurnOnPartway: the line
DL_LEVEL:     .space  4               ; the level 0..FRACUNIT
DL_I:         .space  2               ; the sector number
DL_J:         .space  2
DL_SEC:       .space  4
DL_BRIGHT:    .space  2
DL_MIN:       .space  2
ED_LINE:      .space  4               ; EV_DoDoor
ED_TYPE:      .space  2
ED_SECNUM:    .space  2
ED_RTN:       .space  2
ED_SEC:       .space  4
VD_PLAYER:    .space  2               ; EV_VerticalDoor: 1 for the player

              .section cfar, rodata
;;; Messages for locked doors, selected by the required key color.
msgBlue:      .asciz  "You need a blue key to open this"
msgYellow:    .asciz  "You need a yellow key to open this"
msgRed:       .asciz  "You need a red key to open this"

;;; ---------------------------------------------------------------------------
;;; T_VerticalDoor(vldoor_t __far* door): the door thinker: waits, goes
;;; down or goes up.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public T_VerticalDoor
T_VerticalDoor:
              lda     dp:.tiny _Dp
              sta     .near DR_DOOR
              lda     dp:.tiny (_Dp+2)
              sta     .near (DR_DOOR+2)
              ldy     ##OFS_DOOR_DIRECTION
              lda     [.tiny _Dp],y
              and     ##0x00ff
              beq     wait
              cmp     ##1
              bne     1$
              brl     up
1$:           cmp     ##0x00ff
              beq     down
              rtl

              ;; waiting: when the countdown ends, down (normal) or up
wait:         ldy     ##OFS_DOOR_TOPCOUNTDOWN
              lda     [.tiny _Dp],y
#if TICSTEP > 1
              sec                           ; (the countdown ends in the run)
              sbc     .near ticRun
              sta     [.tiny _Dp],y
              beq     10$
              bpl     9$
10$:
#else
              dec     a
              sta     [.tiny _Dp],y
              bne     9$
#endif
              ldy     ##OFS_DOOR_TYPE
              lda     [.tiny _Dp],y
              cmp     ##CONST_NORMAL
              bne     1$
              lda     ##0xff                ; direction = -1, the close sound
              jsr     .kbank setDir
              lda     ##CONST_SFX_DORCLS
              jsr     .kbank doorSound
              rtl
1$:           cmp     ##CONST_CLOSE30THENOPEN
              bne     9$
              lda     ##1                   ; direction = 1, the open sound
              jsr     .kbank setDir
              lda     ##CONST_SFX_DOROPN
              jsr     .kbank doorSound
9$:           rtl

              ;; down to the floor
down:         jsr     .kbank sectorArg      ; dest = sector->floorheight
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     [.tiny _Dp],y
              sta     .near DR_T
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (DR_T+2)
              jsr     .kbank moveCeiling
              jsr     .kbank partLight
              lda     .near DR_RES
              cmp     ##CONST_PASTDEST
              bne     5$
              jsr     .kbank doorArg        ; at the bottom
              ldy     ##OFS_DOOR_TYPE
              lda     [.tiny _Dp],y
              cmp     ##CONST_NORMAL        ; normal: done
              bne     1$
              brl     done
1$:           cmp     ##CONST_CLOSE30THENOPEN ; close30ThenOpen: waits 30 s
              bne     9$
              lda     ##0
              jsr     .kbank setDir
              lda     ##(CONST_TICRATE * 30)
              ldy     ##OFS_DOOR_TOPCOUNTDOWN
              sta     [.tiny _Dp],y
              rtl
5$:           cmp     ##CONST_CRUSHED       ; something under it: up again
              bne     9$
              lda     ##1
              jsr     .kbank setDir
              lda     ##CONST_SFX_DOROPN
              jsr     .kbank doorSound
9$:           rtl

              ;; up to the top
up:           ldy     ##OFS_DOOR_TOPHEIGHT  ; dest = topheight
              lda     [.tiny _Dp],y
              sta     .near DR_T
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (DR_T+2)
              jsr     .kbank moveCeiling
              jsr     .kbank partLight
              lda     .near DR_RES
              cmp     ##CONST_PASTDEST
              bne     9$
              jsr     .kbank doorArg        ; at the top
              ldy     ##OFS_DOOR_TYPE
              lda     [.tiny _Dp],y
              cmp     ##CONST_NORMAL        ; normal: waits
              bne     1$
              lda     ##0
              jsr     .kbank setDir
              lda     ##VDOORWAIT
              ldy     ##OFS_DOOR_TOPCOUNTDOWN
              sta     [.tiny _Dp],y
              rtl
1$:           cmp     ##CONST_CLOSE30THENOPEN ; close30ThenOpen, open: done
              beq     done
              cmp     ##CONST_DOPEN
              beq     done
9$:           rtl

;;; done: sector->ceilingdata = NULL, the thinker removed.
done:         jsr     .kbank sectorArg
              ldy     ##OFS_SEC_CEILINGDATA
              lda     ##0
              sta     [.tiny _Dp],y
              iny
              iny
              sta     [.tiny _Dp],y
              jsr     .kbank doorArg
              jmp     long:P_RemoveThinker

;;; doorArg: _Dp[0-3] = DR_DOOR. sectorArg: _Dp[0-3] = its sector.
doorArg:      lda     .near DR_DOOR
              sta     dp:.tiny _Dp
              lda     .near (DR_DOOR+2)
              sta     dp:.tiny (_Dp+2)
              rts
sectorArg:    jsr     .kbank doorArg
              ldy     ##(OFS_DOOR_SECTOR+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_DOOR_SECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              rts

;;; setDir: door->direction = C (a byte).
setDir:       pha
              jsr     .kbank doorArg
              pla
              sep     #0x20
              ldy     ##OFS_DOOR_DIRECTION
              sta     [.tiny _Dp],y
              rep     #0x20
              rts

;;; doorSound: S_StartSound2(&door->sector->soundorg, C).
doorSound:    pha
              jsr     .kbank sectorArg
              lda     dp:.tiny _Dp
              clc
              adc     ##OFS_SEC_SOUNDORG
              sta     dp:.tiny _Dp
              pla
              jsl     long:S_StartSound2
              rts

;;; moveCeiling: DR_RES = T_MovePlaneCeiling(door->sector, door->speed,
;;; DR_T, door->direction).
moveCeiling:  jsr     .kbank doorArg
              ldy     ##OFS_DOOR_DIRECTION
              lda     [.tiny _Dp],y
              pha
              ldy     ##(OFS_DOOR_SPEED+2)
              lda     [.tiny _Dp],y
              pha
              ldy     ##OFS_DOOR_SPEED
              lda     [.tiny _Dp],y
              pha
              jsr     .kbank sectorArg
              lda     .near DR_T
              sta     dp:.tiny (_Dp+4)
              lda     .near (DR_T+2)
              sta     dp:.tiny (_Dp+6)
              pla
              plx
              jsl     long:T_MovePlaneCeiling
              sta     .near DR_RES
              pla
              rts

;;; partLight: if (door->lighttag && topheight != floorheight)
;;; EV_LightTurnOnPartway(door->line, FixedApproxDiv(ceilingheight -
;;; floorheight, topheight - floorheight)).
partLight:    jsr     .kbank doorArg
              ldy     ##OFS_DOOR_LIGHTTAG
              lda     [.tiny _Dp],y
              bne     1$
              rts
1$:           ldy     ##OFS_DOOR_TOPHEIGHT  ; topheight (in DR_T)
              lda     [.tiny _Dp],y
              sta     .near DR_T
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (DR_T+2)
              ldy     ##OFS_DOOR_LINE       ; the line
              lda     [.tiny _Dp],y
              sta     .near DL_LINE
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (DL_LINE+2)
              jsr     .kbank sectorArg
              ldy     ##OFS_SEC_FLOORHEIGHT ; topheight - floorheight
              lda     .near DR_T
              sec
              sbc     [.tiny _Dp],y
              sta     .near DR_T
              iny
              iny
              lda     .near (DR_T+2)
              sbc     [.tiny _Dp],y
              sta     .near (DR_T+2)
              ora     .near DR_T
              bne     2$
              rts
2$:           ldy     ##OFS_SEC_CEILINGHEIGHT ; ceilingheight - floorheight
              lda     [.tiny _Dp],y
              sec
              ldy     ##OFS_SEC_FLOORHEIGHT
              sbc     [.tiny _Dp],y
              pha
              ldy     ##(OFS_SEC_CEILINGHEIGHT+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_SEC_FLOORHEIGHT+2)
              sbc     [.tiny _Dp],y
              tax
              lda     .near DR_T
              sta     dp:.tiny _Dp
              lda     .near (DR_T+2)
              sta     dp:.tiny (_Dp+2)
              pla
              jsl     long:FixedApproxDiv
              sta     .near DL_LEVEL
              stx     .near (DL_LEVEL+2)
              jmp     .kbank lightPartway

;;; ---------------------------------------------------------------------------
;;; lightPartway: EV_LightTurnOnPartway(DL_LINE, DL_LEVEL): the sectors with
;;; the tag of the line get the light between the lowest and the highest
;;; light next to them (the level between 0 and FRACUNIT).
;;; ---------------------------------------------------------------------------
lightPartway: lda     .near (DL_LEVEL+2)    ; level < 0: 0
              bpl     1$
              stz     .near DL_LEVEL
              stz     .near (DL_LEVEL+2)
              bra     2$
1$:           beq     2$                    ; level > FRACUNIT: FRACUNIT
              cmp     ##1
              bne     11$
              lda     .near DL_LEVEL
              beq     2$
11$:          stz     .near DL_LEVEL
              lda     ##1
              sta     .near (DL_LEVEL+2)
2$:           lda     ##0xffff
              sta     .near DL_I
3$:           lda     .near DL_LINE         ; i = P_FindSectorFromLineTag(line, i)
              sta     dp:.tiny _Dp
              lda     .near (DL_LINE+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near DL_I
              jsl     long:P_FindSectorFromLineTag
              sta     .near DL_I
              cmp     ##0
              bpl     4$
              rts
4$:           ldx     ##SIZEOF_SEC          ; the sector
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sectors
              sta     .near DL_SEC
              lda     .near (_g_sectors+2)
              sta     .near (DL_SEC+2)
              stz     .near DL_BRIGHT       ; bright = 0, min = lightlevel
              jsr     .kbank dlSec
              ldy     ##OFS_SEC_LIGHTLEVEL
              lda     [.tiny _Dp],y
              sta     .near DL_MIN
              stz     .near DL_J
5$:           jsr     .kbank dlSec          ; for (j = 0; j < linecount; j++)
              ldy     ##OFS_SEC_LINECOUNT
              lda     .near DL_J
              cmp     [.tiny _Dp],y
              bcs     8$
              asl     a                     ; getNextSector(lines[j], sector)
              asl     a
              clc
              ldy     ##OFS_SEC_LINES
              adc     [.tiny _Dp],y
              pha
              iny
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+2)
              pla
              sta     dp:.tiny _Dp
              ldy     ##2
              lda     [.tiny _Dp],y
              tax
              lda     [.tiny _Dp]
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near DL_SEC
              sta     dp:.tiny (_Dp+4)
              lda     .near (DL_SEC+2)
              sta     dp:.tiny (_Dp+6)
              jsl     long:getNextSector
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ora     dp:.tiny (_Dp+2)
              beq     7$
              ldy     ##OFS_SEC_LIGHTLEVEL
              lda     [.tiny _Dp],y         ; > bright: bright
              sec
              sbc     .near DL_BRIGHT
              beq     6$
              bvc     51$
              eor     ##0x8000
51$:          bmi     6$
              lda     [.tiny _Dp],y
              sta     .near DL_BRIGHT
6$:           lda     [.tiny _Dp],y         ; < min: min
              sec
              sbc     .near DL_MIN
              bvc     61$
              eor     ##0x8000
61$:          bpl     7$
              lda     [.tiny _Dp],y
              sta     .near DL_MIN
7$:           inc     .near DL_J
              bra     5$
              ;; lightlevel = (level * bright + (FRACUNIT - level) * min) >> 16
8$:           lda     .near DL_LEVEL
              sta     dp:.tiny _Dp
              lda     .near (DL_LEVEL+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near DL_BRIGHT
              jsr     .kbank mulExt
              sta     .near DR_T
              stx     .near (DR_T+2)
              lda     ##0                   ; FRACUNIT - level
              sec
              sbc     .near DL_LEVEL
              sta     dp:.tiny _Dp
              lda     ##1
              sbc     .near (DL_LEVEL+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near DL_MIN
              jsr     .kbank mulExt
              clc
              adc     .near DR_T
              txa
              adc     .near (DR_T+2)        ; >> 16: the high word
              pha
              jsr     .kbank dlSec
              pla
              ldy     ##OFS_SEC_LIGHTLEVEL
              sta     [.tiny _Dp],y
              brl     3$

;;; dlSec: _Dp[0-3] = DL_SEC.
dlSec:        lda     .near DL_SEC
              sta     dp:.tiny _Dp
              lda     .near (DL_SEC+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; mulExt: X:C = _Dp[0-3] * C (C sign extended), the low 32 bits.
mulExt:       sta     dp:.tiny (_Dp+4)
              ldx     ##0
              cmp     ##0
              bpl     1$
              dex
1$:           stx     dp:.tiny (_Dp+6)
              jsl     long:_Mul32
              rts

;;; ---------------------------------------------------------------------------
;;; boolean EV_DoDoor(const line_t __far* line, vldoor_e type)
;;; A door for each sector with the tag of the line that has no moving
;;; ceiling.
;;; ---------------------------------------------------------------------------
              .public EV_DoDoor
EV_DoDoor:    sta     .near ED_TYPE
              lda     dp:.tiny _Dp
              sta     .near ED_LINE
              lda     dp:.tiny (_Dp+2)
              sta     .near (ED_LINE+2)
              lda     ##0xffff
              sta     .near ED_SECNUM
              stz     .near ED_RTN
edLoop:       jsr     .kbank edLine         ; secnum = P_FindSectorFromLineTag(line, secnum)
              lda     .near ED_SECNUM
              jsl     long:P_FindSectorFromLineTag
              sta     .near ED_SECNUM
              cmp     ##0
              bpl     2$
              lda     .near ED_RTN
              rtl
2$:           ldx     ##SIZEOF_SEC          ; the sector
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sectors
              sta     .near ED_SEC
              lda     .near (_g_sectors+2)
              sta     .near (ED_SEC+2)
              jsr     .kbank edSec
              ldy     ##OFS_SEC_CEILINGDATA ; a moving ceiling: no
              lda     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              bne     edLoop
              lda     ##1
              sta     .near ED_RTN
              jsr     .kbank newDoor
              ldy     ##OFS_DOOR_TYPE       ; (lighttag stays 0)
              lda     .near ED_TYPE
              sta     [.tiny _Dp],y
              cmp     ##CONST_CLOSE30THENOPEN
              bne     3$
              jsr     .kbank edSec          ; topheight = ceilingheight, down
              ldy     ##(OFS_SEC_CEILINGHEIGHT+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SEC_CEILINGHEIGHT
              lda     [.tiny _Dp],y
              jsr     .kbank setTop
              lda     ##0xff
              jsr     .kbank setDir
              lda     ##CONST_SFX_DORCLS
              jsr     .kbank edSound
              bra     edLoop
3$:           cmp     ##CONST_NORMAL        ; normal, open: up to the lowest
              beq     4$                    ; ceiling next to it - 4
              cmp     ##CONST_DOPEN
              bne     edLoop
4$:           lda     ##1
              jsr     .kbank setDir
              jsr     .kbank topLowest
              jsr     .kbank edSec          ; not already there: the open sound
              ldy     ##OFS_SEC_CEILINGHEIGHT
              lda     .near DR_T
              cmp     [.tiny _Dp],y
              bne     5$
              iny
              iny
              lda     .near (DR_T+2)
              cmp     [.tiny _Dp],y
              bne     5$
              brl     edLoop
5$:           lda     ##CONST_SFX_DOROPN
              jsr     .kbank edSound
              brl     edLoop

;;; newDoor: a new door thinker for the sector ED_SEC: in the thinkers,
;;; sec->ceilingdata = it, function T_VerticalDoor, sector ED_SEC, speed
;;; VDOORSPEED, line ED_LINE. Out: DR_DOOR and _Dp[0-3] = the door.
newDoor:      lda     ##SIZEOF_DOOR
              jsl     long:Z_CallocLevSpec
              sta     .near DR_DOOR
              stx     .near (DR_DOOR+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              jsl     long:P_AddThinker
              jsr     .kbank edSec          ; sec->ceilingdata = door
              ldy     ##OFS_SEC_CEILINGDATA
              lda     .near DR_DOOR
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (DR_DOOR+2)
              sta     [.tiny _Dp],y
              jsr     .kbank doorArg
              ldy     ##OFS_TH_FUNCTION
              lda     ##.word0 T_VerticalDoor
              sta     [.tiny _Dp],y
              iny
              iny
              lda     ##.word2 T_VerticalDoor
              sta     [.tiny _Dp],y
              ldy     ##OFS_DOOR_SECTOR
              lda     .near ED_SEC
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (ED_SEC+2)
              sta     [.tiny _Dp],y
              ldy     ##OFS_DOOR_SPEED
              lda     ##0
              sta     [.tiny _Dp],y
              iny
              iny
              lda     ##VDOORSPEED_HI
              sta     [.tiny _Dp],y
              ldy     ##OFS_DOOR_LINE
              lda     .near ED_LINE
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (ED_LINE+2)
              sta     [.tiny _Dp],y
              rts

;;; topLowest: door->topheight = P_FindLowestCeilingSurrounding(ED_SEC) - 4
;;; (also in DR_T).
topLowest:    jsr     .kbank edSec
              jsl     long:P_FindLowestCeilingSurrounding
              pha
              txa
              sec
              sbc     ##4
              tax
              pla
              ;; fall into setTop

;;; setTop: door->topheight = X:C (also in DR_T).
setTop:       sta     .near DR_T
              stx     .near (DR_T+2)
              jsr     .kbank doorArg
              ldy     ##OFS_DOOR_TOPHEIGHT
              lda     .near DR_T
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (DR_T+2)
              sta     [.tiny _Dp],y
              rts

;;; edLine, edSec: _Dp[0-3] = ED_LINE, ED_SEC.
edLine:       lda     .near ED_LINE
              sta     dp:.tiny _Dp
              lda     .near (ED_LINE+2)
              sta     dp:.tiny (_Dp+2)
              rts
edSec:        lda     .near ED_SEC
              sta     dp:.tiny _Dp
              lda     .near (ED_SEC+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; edSound: S_StartSound2(&ED_SEC->soundorg, C).
edSound:      pha
              jsr     .kbank edSec
              lda     dp:.tiny _Dp
              clc
              adc     ##OFS_SEC_SOUNDORG
              sta     dp:.tiny _Dp
              pla
              jsl     long:S_StartSound2
              rts

;;; ---------------------------------------------------------------------------
;;; EV_VerticalDoor(line_t __far* line, mobj_t __far* thing)
;;; In: _Dp[0-3] = the line, _Dp[4-7] = the thing (from P_UseSpecialLine).
;;; A manual door: the key check of the locked doors, then the sector on
;;; the back side of the line opens; a door that moves already turns
;;; around (repeatable lines only).
;;; ---------------------------------------------------------------------------
              .public EV_VerticalDoor
EV_VerticalDoor:
              lda     dp:.tiny _Dp
              sta     .near ED_LINE
              lda     dp:.tiny (_Dp+2)
              sta     .near (ED_LINE+2)
              stz     .near VD_PLAYER       ; the thing is the player?
              lda     .near (_g_player+OFS_PL_MO)
              cmp     dp:.tiny (_Dp+4)
              bne     1$
              lda     .near (_g_player+OFS_PL_MO+2)
              cmp     dp:.tiny (_Dp+6)
              bne     1$
              inc     .near VD_PLAYER
1$:           ldy     ##OFS_LINE_SPECIAL    ; the locks
              lda     [.tiny _Dp],y
              ldx     ##(2 * CONST_IT_BLUECARD)
              cmp     ##26
              beq     2$
              cmp     ##32
              beq     2$
              ldx     ##(2 * CONST_IT_YELLOWCARD)
              cmp     ##27
              beq     2$
              cmp     ##34
              beq     2$
              ldx     ##(2 * CONST_IT_REDCARD)
              cmp     ##28
              beq     2$
              cmp     ##33
              bne     vdOpen
2$:           lda     .near VD_PLAYER       ; a monster: no
              bne     3$
              rtl
3$:           lda     abs:.near (_g_player+OFS_PL_CARDS),x
              bne     vdOpen
              cpx     ##(2 * CONST_IT_BLUECARD) ; no key: the message and oof
              bne     4$
              lda     ##.word0 msgBlue
              ldx     ##.word2 msgBlue
              bra     6$
4$:           cpx     ##(2 * CONST_IT_YELLOWCARD)
              bne     5$
              lda     ##.word0 msgYellow
              ldx     ##.word2 msgYellow
              bra     6$
5$:           lda     ##.word0 msgRed
              ldx     ##.word2 msgRed
6$:           sta     .near (_g_player+OFS_PL_MESSAGE)
              stx     .near (_g_player+OFS_PL_MESSAGE+2)
              brl     oof

vdOpen:       jsr     .kbank edLine         ; no back side: oof
              ldy     ##(OFS_LINE_SIDENUM+2)
              lda     [.tiny _Dp],y
              cmp     ##0xffff
              bne     1$
              lda     .near VD_PLAYER       ; only a player gets the failed-use sound
              beq     5$
              brl     oof
5$:           rtl
1$:           ldx     ##SIZEOF_SIDE         ; sec = the back sector
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sides
              sta     dp:.tiny _Dp
              lda     .near (_g_sides+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_SIDE_SECTOR+2)
              lda     [.tiny _Dp],y
              sta     .near (ED_SEC+2)
              ldy     ##OFS_SIDE_SECTOR
              lda     [.tiny _Dp],y
              sta     .near ED_SEC
              jsr     .kbank edSec          ; door = sec->ceilingdata
              ldy     ##OFS_SEC_CEILINGDATA
              lda     [.tiny _Dp],y
              sta     .near DR_DOOR
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (DR_DOOR+2)
              ora     .near DR_DOOR
              beq     vdNew
              jsr     .kbank edLine         ; a repeatable line (1, 26-28)
              ldy     ##OFS_LINE_SPECIAL
              lda     [.tiny _Dp],y
              cmp     ##1
              beq     2$
              cmp     ##26
              bcc     vdNew
              cmp     ##29
              bcs     vdNew
              ;; only doors set ceilingdata, so the thinker is T_VerticalDoor:
              ;; down turns up, else the player sends it down
2$:           jsr     .kbank doorArg
              ldy     ##OFS_DOOR_DIRECTION
              lda     [.tiny _Dp],y
              and     ##0x00ff
              cmp     ##0x00ff
              bne     3$
              lda     ##1
              jsr     .kbank setDir
              rtl
3$:           lda     .near VD_PLAYER
              beq     4$
              lda     ##0xff
              jsr     .kbank setDir
4$:           rtl

vdNew:        lda     ##CONST_SFX_DOROPN    ; the open sound, a new door going up
              jsr     .kbank edSound
              jsr     .kbank newDoor
              lda     ##1
              jsr     .kbank setDir
              jsr     .kbank edLine         ; lighttag = line->tag; the type
              ldy     ##OFS_LINE_TAG
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_LINE_SPECIAL
              lda     [.tiny _Dp],y
              cmp     ##1
              beq     2$
              cmp     ##26
              bcc     1$
              cmp     ##29
              bcc     2$
              cmp     ##31
              bcc     1$
              cmp     ##35
              bcs     1$
              lda     ##0                   ; 31-34: open, the line is used up
              sta     [.tiny _Dp],y
              lda     ##CONST_DOPEN
              bra     3$
1$:           ldx     ##0                   ; other lines: no light
2$:           lda     ##CONST_NORMAL
3$:           pha
              phx
              jsr     .kbank doorArg
              pla
              ldy     ##OFS_DOOR_LIGHTTAG
              sta     [.tiny _Dp],y
              pla
              ldy     ##OFS_DOOR_TYPE
              sta     [.tiny _Dp],y
              jsr     .kbank topLowest
              rtl

;;; oof: S_StartSound(player->mo, sfx_oof).
oof:          lda     .near (_g_player+OFS_PL_MO)
              sta     dp:.tiny _Dp
              lda     .near (_g_player+OFS_PL_MO+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##CONST_SFX_OOF
              jmp     long:S_StartSound
