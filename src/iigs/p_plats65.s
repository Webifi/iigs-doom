;;; Platform/lift thinkers and activation.
;;;
;;; EV_DoPlat configures a sector's moving platform. The thinker advances
;;; through moving and waiting states and clears its sector association when
;;; removed. Platform lifetime is tied to level allocation; there is no
;;; separate active-platform list to traverse or retain across level teardown.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "tics.inc"
#if TICSTEP > 1
              .extern worldTic, ticRun
#endif

              .extern _Dp, _g_sectors, _g_sides, _g_leveltime
              .extern T_MovePlaneFloor, S_StartSound2, P_RemoveThinker, P_AddThinker
              .extern Z_CallocLevSpec, P_FindSectorFromLineTag, IIGS_MulLo16
              .extern P_FindNextHighestFloor, P_FindLowestFloorSurrounding

PLATWAIT      .equ    3               ; wait at an endpoint, in seconds

              .section znear, bss
PL_PLAT:      .space  4               ; the plat thinker
PL_RES:       .space  2               ; the result of the plane move
PL_T:         .space  4
PL_LINE:      .space  4               ; EV_DoPlat: the line
PL_TYPE:      .space  2
PL_SECNUM:    .space  2
PL_RTN:       .space  2
PL_SEC:       .space  4

;;; ---------------------------------------------------------------------------
;;; T_PlatRaise(plat_t __far* plat): the plat thinker: up, down or waiting.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public T_PlatRaise
T_PlatRaise:  lda     dp:.tiny _Dp
              sta     .near PL_PLAT
              lda     dp:.tiny (_Dp+2)
              sta     .near (PL_PLAT+2)
              ldy     ##OFS_PLAT_STATUS
              lda     [.tiny _Dp],y
              beq     up
              cmp     ##CONST_DOWN
              bne     1$
              brl     down
1$:           cmp     ##CONST_WAITING
              beq     wait
              rtl

              ;; waiting: at the end of the count, up from the bottom, else down
wait:         ldy     ##OFS_PLAT_COUNT
              lda     [.tiny _Dp],y
#if TICSTEP > 1
              sec                           ; (the count ends in the run)
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
              ldy     ##OFS_PLAT_LOW
              lda     [.tiny _Dp],y
              sta     .near PL_T
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (PL_T+2)
              jsr     .kbank sectorArg
              ldx     ##CONST_DOWN
              ldy     ##OFS_SEC_FLOORHEIGHT ; floorheight == low: up
              lda     [.tiny _Dp],y
              cmp     .near PL_T
              bne     1$
              iny
              iny
              lda     [.tiny _Dp],y
              cmp     .near (PL_T+2)
              bne     1$
              ldx     ##CONST_UP
1$:           txa
              jsr     .kbank setStatus
              lda     ##CONST_SFX_PSTART
              jsr     .kbank platSound
9$:           rtl

              ;; up to high: the stone sound for the raise type; held: down
up:           lda     ##1
              ldy     ##OFS_PLAT_HIGH
              jsr     .kbank movePlat
              jsr     .kbank platArg
              ldy     ##OFS_PLAT_TYPE
              lda     [.tiny _Dp],y
              cmp     ##CONST_RAISETONEARESTANDCHANGE
              bne     1$
#if TICSTEP > 1
              TICHIT  7
              bcs     1$
#else
              lda     .near _g_leveltime
              and     ##7
              bne     1$
#endif
              lda     ##CONST_SFX_STNMOV
              jsr     .kbank platSound
1$:           lda     .near PL_RES
              cmp     ##CONST_CRUSHED
              bne     2$
              lda     ##CONST_DOWN
              jsr     .kbank waitStatus
              lda     ##CONST_SFX_PSTART
              jsr     .kbank platSound
              rtl
2$:           cmp     ##CONST_PASTDEST      ; at the top: both types are done
              bne     9$
              jsr     .kbank stopWait
              jsr     .kbank platArg
              ldy     ##OFS_PLAT_TYPE
              lda     [.tiny _Dp],y
              cmp     ##(CONST_RAISETONEARESTANDCHANGE + 1)
              bcc     remove
9$:           rtl

              ;; down to low
down:         lda     ##0xffff
              ldy     ##OFS_PLAT_LOW
              jsr     .kbank movePlat
              lda     .near PL_RES
              cmp     ##CONST_PASTDEST
              bne     9$
              jsr     .kbank stopWait
              jsr     .kbank platArg        ; at the bottom: the raise type is done
              ldy     ##OFS_PLAT_TYPE
              lda     [.tiny _Dp],y
              cmp     ##CONST_RAISETONEARESTANDCHANGE
              beq     remove
9$:           rtl

;;; remove: sector->floordata = NULL, the thinker removed.
remove:       jsr     .kbank sectorArg
              ldy     ##OFS_SEC_FLOORDATA
              lda     ##0
              sta     [.tiny _Dp],y
              iny
              iny
              sta     [.tiny _Dp],y
              jsr     .kbank platArg
              jmp     long:P_RemoveThinker

;;; platArg: _Dp[0-3] = PL_PLAT. sectorArg: _Dp[0-3] = its sector.
platArg:      lda     .near PL_PLAT
              sta     dp:.tiny _Dp
              lda     .near (PL_PLAT+2)
              sta     dp:.tiny (_Dp+2)
              rts
sectorArg:    jsr     .kbank platArg
              ldy     ##(OFS_PLAT_SECTOR+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_PLAT_SECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              rts

;;; movePlat: PL_RES = T_MovePlaneFloor(plat->sector, plat->speed, the
;;; fixed_t at offset Y of the plat, C = the direction).
movePlat:     pha
              jsr     .kbank platArg
              lda     [.tiny _Dp],y
              sta     .near PL_T
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (PL_T+2)
              ldy     ##(OFS_PLAT_SPEED+2)
              lda     [.tiny _Dp],y
              pha
              ldy     ##OFS_PLAT_SPEED
              lda     [.tiny _Dp],y
              pha
              jsr     .kbank sectorArg
              lda     .near PL_T
              sta     dp:.tiny (_Dp+4)
              lda     .near (PL_T+2)
              sta     dp:.tiny (_Dp+6)
              pla
              plx
              jsl     long:T_MovePlaneFloor
              sta     .near PL_RES
              pla
              rts

;;; stopWait: count = wait, waiting, the stop sound.
stopWait:     lda     ##CONST_WAITING
              jsr     .kbank waitStatus
              lda     ##CONST_SFX_PSTOP
              ;; fall into platSound

;;; platSound: S_StartSound2(&plat->sector->soundorg, C).
platSound:    pha
              jsr     .kbank sectorArg
              lda     dp:.tiny _Dp
              clc
              adc     ##OFS_SEC_SOUNDORG
              sta     dp:.tiny _Dp
              pla
              jsl     long:S_StartSound2
              rts

;;; waitStatus: count = wait, status = C. setStatus: status = C.
waitStatus:   pha
              jsr     .kbank platArg
              ldy     ##OFS_PLAT_WAIT
              lda     [.tiny _Dp],y
              ldy     ##OFS_PLAT_COUNT
              sta     [.tiny _Dp],y
              pla
              ldy     ##OFS_PLAT_STATUS
              sta     [.tiny _Dp],y
              rts
setStatus:    pha
              jsr     .kbank platArg
              pla
              ldy     ##OFS_PLAT_STATUS
              sta     [.tiny _Dp],y
              rts

;;; setHigh, setLow: plat->high or plat->low = X:C.
setHigh:      ldy     ##OFS_PLAT_HIGH
              bra     setField
setLow:       ldy     ##OFS_PLAT_LOW
setField:     pha
              phx
              jsr     .kbank platArg
              pla
              iny
              iny
              sta     [.tiny _Dp],y
              dey
              dey
              pla
              sta     [.tiny _Dp],y
              rts

;;; ---------------------------------------------------------------------------
;;; boolean EV_DoPlat(const line_t __far* line, plattype_e type)
;;; A plat for each sector with the tag of the line that has no moving
;;; floor. raiseToNearestAndChange takes the floor texture of the front
;;; sector of the line and rises to the next floor; downWaitUpStay goes
;;; down to the lowest floor next to it, waits and comes back.
;;; ---------------------------------------------------------------------------
              .public EV_DoPlat
EV_DoPlat:    sta     .near PL_TYPE
              lda     dp:.tiny _Dp
              sta     .near PL_LINE
              lda     dp:.tiny (_Dp+2)
              sta     .near (PL_LINE+2)
              lda     ##0xffff
              sta     .near PL_SECNUM
              stz     .near PL_RTN
plLoop:       lda     .near PL_LINE         ; secnum = P_FindSectorFromLineTag(line, secnum)
              sta     dp:.tiny _Dp
              lda     .near (PL_LINE+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near PL_SECNUM
              jsl     long:P_FindSectorFromLineTag
              sta     .near PL_SECNUM
              cmp     ##0
              bpl     2$
              lda     .near PL_RTN
              rtl
2$:           ldx     ##SIZEOF_SEC          ; the sector
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sectors
              sta     .near PL_SEC
              sta     dp:.tiny _Dp
              lda     .near (_g_sectors+2)
              sta     .near (PL_SEC+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_SEC_FLOORDATA   ; a moving floor: no
              lda     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              bne     plLoop
              lda     ##1
              sta     .near PL_RTN
              lda     ##SIZEOF_PLAT         ; the plat thinker
              jsl     long:Z_CallocLevSpec
              sta     .near PL_PLAT
              stx     .near (PL_PLAT+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              jsl     long:P_AddThinker
              jsr     .kbank plSec          ; sec->floordata = plat
              ldy     ##OFS_SEC_FLOORDATA
              lda     .near PL_PLAT
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (PL_PLAT+2)
              sta     [.tiny _Dp],y
              ldy     ##(OFS_SEC_FLOORHEIGHT+2) ; low = sec->floorheight
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     [.tiny _Dp],y
              jsr     .kbank setLow
              ldy     ##OFS_PLAT_TYPE       ; the fields (_Dp = the plat)
              lda     .near PL_TYPE
              sta     [.tiny _Dp],y
              ldy     ##OFS_PLAT_SECTOR
              lda     .near PL_SEC
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (PL_SEC+2)
              sta     [.tiny _Dp],y
              ldy     ##OFS_TH_FUNCTION
              lda     ##.word0 T_PlatRaise
              sta     [.tiny _Dp],y
              iny
              iny
              lda     ##.word2 T_PlatRaise
              sta     [.tiny _Dp],y
              lda     .near PL_TYPE
              cmp     ##CONST_RAISETONEARESTANDCHANGE
              beq     raise
              cmp     ##CONST_DOWNWAITUPSTAY
              beq     lower
              brl     plLoop

              ;; raiseToNearestAndChange (wait and status stay 0: up)
raise:        ldy     ##OFS_PLAT_SPEED      ; speed = PLATSPEED / 2
              lda     ##0x8000
              sta     [.tiny _Dp],y
              iny
              iny
              lda     ##0
              sta     [.tiny _Dp],y
              lda     .near PL_LINE         ; the floor texture of the front sector
              sta     dp:.tiny _Dp
              lda     .near (PL_LINE+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_LINE_SIDENUM
              lda     [.tiny _Dp],y
              ldx     ##SIZEOF_SIDE
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sides
              sta     dp:.tiny _Dp
              lda     .near (_g_sides+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_SIDE_SECTOR+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SIDE_SECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##OFS_SEC_FLOORPIC
              lda     [.tiny _Dp],y
              pha
              jsr     .kbank plSec
              pla
              ldy     ##OFS_SEC_FLOORPIC
              sta     [.tiny _Dp],y
              jsl     long:P_FindNextHighestFloor ; high = the next floor up
              jsr     .kbank setHigh
              jsr     .kbank plSec          ; special = oldspecial = 0
              ldy     ##OFS_SEC_SPECIAL
              lda     ##0
              sta     [.tiny _Dp],y
              ldy     ##OFS_SEC_OLDSPECIAL
              sta     [.tiny _Dp],y
              lda     ##CONST_SFX_STNMOV
              jsr     .kbank platSound
              brl     plLoop

              ;; downWaitUpStay
lower:        ldy     ##OFS_PLAT_SPEED      ; speed = PLATSPEED * 4
              lda     ##0
              sta     [.tiny _Dp],y
              iny
              iny
              lda     ##4
              sta     [.tiny _Dp],y
              ldy     ##OFS_PLAT_WAIT
              lda     ##(35 * PLATWAIT)
              sta     [.tiny _Dp],y
              ldy     ##OFS_PLAT_STATUS
              lda     ##CONST_DOWN
              sta     [.tiny _Dp],y
              jsr     .kbank plSec          ; high = sec->floorheight
              ldy     ##(OFS_SEC_FLOORHEIGHT+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     [.tiny _Dp],y
              jsr     .kbank setHigh
              ;; low = the lowest floor next to it, which is never above
              ;; the floor of the sector (so the C clip is not necessary)
              jsr     .kbank plSec
              jsl     long:P_FindLowestFloorSurrounding
              jsr     .kbank setLow
              lda     ##CONST_SFX_PSTART
              jsr     .kbank platSound
              brl     plLoop

;;; plSec: _Dp[0-3] = PL_SEC.
plSec:        lda     .near PL_SEC
              sta     dp:.tiny _Dp
              lda     .near (PL_SEC+2)
              sta     dp:.tiny (_Dp+2)
              rts
