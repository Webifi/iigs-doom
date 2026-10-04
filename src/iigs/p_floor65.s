;;; Floor/ceiling movement and floor line specials.
;;;
;;; T_MovePlane moves a sector plane and checks affected actors; callers use
;;; its result to handle obstruction, crushing or arrival at the target.
;;; Floor thinkers and floor, stair and donut specials build on that operation.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "tics.inc"
#if TICSTEP > 1
              .extern worldTic, ticRun
#endif

;;; CLEAN: the byte 11 of a mobj (the high byte of its thinker function,
;;; 0 in a pointer) is 1 once P_RunThinkers found the mobj with no momentum
;;; on its floor; a change of its momentum, z or floorz clears it.
CLEARCLEAN    .macro  p
              sep     #0x20
              lda     #0
              ldy     ##(OFS_TH_FUNCTION+3)
              sta     [.tiny \p],y
              rep     #0x20
              .endm


              .extern _Dp, _g_sectors, _g_sides, _g_leveltime
              .extern _g_tmfloorz, _g_tmceilingz, _g_tmdropoffz
              .extern P_CheckPosition, P_SetMobjState, P_RemoveMobj
              .extern S_StartSound2, P_RemoveThinker, P_AddThinker, Z_CallocLevSpec
              .extern P_FindSectorFromLineTag, getNextSector
              .extern P_FindHighestFloorSurrounding, P_FindLowestFloorSurrounding
              .extern P_FindLowestCeilingSurrounding, IIGS_MulLo16, _Div16

;;; floormove_t: thinker_t (12 bytes), then
FM_SECTOR     .equ    12
FM_TYPE       .equ    16              ; floor_e
FM_DIRECTION  .equ    18              ; int8_t
FM_TEXTURE    .equ    19
FM_DEST       .equ    21              ; floordestheight
FM_SPEED      .equ    25
FM_SIZE       .equ    29

FLOORSPEED_HI .equ    1               ; FLOORSPEED = FRACUNIT

              .section znear, bss
MP_SEC:       .space  4               ; the sector of the move
MP_SPEED:     .space  4
MP_DEST:      .space  4
MP_LAST:      .space  4               ; lastpos
MP_T:         .space  4
NOFIT:        .space  2               ; nofit
CS_NODE:      .space  4               ; P_CheckSector: the node
TH_ONFLOOR:   .space  2               ; P_ThingHeightClip
FL_SECNUM:    .space  2               ; EV_ functions: the sector number
FL_SEC:       .space  4               ;   the sector
FL_LINE:      .space  4               ;   the line
FL_TYPE:      .space  2               ;   the floor type
FL_RTN:       .space  2               ;   the result
FL_FLOOR:     .space  4               ;   the new floor thinker
FL_HEIGHT:    .space  4               ; EV_BuildStairs: the height
FL_TEXTURE:   .space  2               ;   the texture of the steps
FL_MIN:       .space  2               ;   minssec
FL_I:         .space  2
FL_S1:        .space  4               ; EV_DoDonut: the pillar
FL_S2:        .space  4               ;   the pool
FL_S3:        .space  4               ;   the model
TM_FLOOR:     .space  4               ; T_MoveFloor: the thinker

;;; Signed 32-bit a < b: lda a.lo / cmp b.lo / lda a.hi / SLT32 b.hi / bmi
SLT32         .macro  op
              sbc     \op
              bvc     1$
              eor     ##0x8000
1$:
              .endm

;;; ---------------------------------------------------------------------------
;;; result_e T_MovePlaneFloor(sector_t __far* sector, fixed_t speed,
;;;                           fixed_t dest, int8_t direction)
;;; result_e T_MovePlaneCeiling(the same)
;;; In: _Dp[0-3] = sector, X:C = speed, _Dp[4-7] = dest, 4,s = direction.
;;; Move the plane one step and check the things in the sector: ok,
;;; pastdest (at the destination) or crushed (held by a thing).
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public T_MovePlaneFloor, T_MovePlaneCeiling
T_MovePlaneFloor:
              jsr     .kbank planeArgs
              cmp     ##0xff                ; direction -1: down
              beq     10$
              cmp     ##1                   ; 1: up
              beq     20$
              brl     okay

              ;; the floor down: past dest, or a step
10$:          ldy     ##OFS_SEC_FLOORHEIGHT
              jsr     .kbank minusSpeed     ; floorheight - speed < dest
              lda     .near MP_T
              cmp     .near MP_DEST
              lda     .near (MP_T+2)
              SLT32   .near (MP_DEST+2)
              bpl     11$
              ldx     ##.near MP_DEST
              brl     toDest
11$:          jsr     .kbank saveLast
              jsr     .kbank setPlaneT
              jsr     .kbank checkSector
              brl     okay

              ;; the floor up: at most to the ceiling
20$:          lda     .near MP_DEST         ; destheight = min(dest, ceilingheight)
              ldy     ##OFS_SEC_CEILINGHEIGHT
              cmp     [.tiny _Dp],y
              lda     .near (MP_DEST+2)
              iny
              iny
              sbc     [.tiny _Dp],y
              bvc     21$
              eor     ##0x8000
21$:          bmi     22$
              ldy     ##OFS_SEC_CEILINGHEIGHT
              lda     [.tiny _Dp],y
              sta     .near MP_DEST
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (MP_DEST+2)
22$:          ldy     ##OFS_SEC_FLOORHEIGHT
              jsr     .kbank plusSpeed      ; floorheight + speed > destheight
              lda     .near MP_DEST
              cmp     .near MP_T
              lda     .near (MP_DEST+2)
              SLT32   .near (MP_T+2)
              bpl     23$
              ldx     ##.near MP_DEST
              brl     toDest
23$:          brl     crushStep

T_MovePlaneCeiling:
              jsr     .kbank planeArgs
              cmp     ##0xff                ; direction -1: down
              beq     30$
              cmp     ##1                   ; 1: up
              beq     40$
              brl     okay

              ;; the ceiling down: at least to the floor
30$:          ldy     ##OFS_SEC_FLOORHEIGHT ; destheight = max(dest, floorheight)
              lda     [.tiny _Dp],y
              cmp     .near MP_DEST
              iny
              iny
              lda     [.tiny _Dp],y
              SLT32   .near (MP_DEST+2)
              bmi     31$
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     [.tiny _Dp],y
              sta     .near MP_DEST
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (MP_DEST+2)
31$:          ldy     ##OFS_SEC_CEILINGHEIGHT
              jsr     .kbank minusSpeed     ; ceilingheight - speed < destheight
              lda     .near MP_T
              cmp     .near MP_DEST
              lda     .near (MP_T+2)
              SLT32   .near (MP_DEST+2)
              bpl     32$
              ldx     ##.near MP_DEST
              brl     toDest
32$:          brl     crushStep

              ;; the ceiling up: past dest, or a step
40$:          ldy     ##OFS_SEC_CEILINGHEIGHT
              jsr     .kbank plusSpeed      ; ceilingheight + speed > dest
              lda     .near MP_DEST
              cmp     .near MP_T
              lda     .near (MP_DEST+2)
              SLT32   .near (MP_T+2)
              bpl     41$
              ldx     ##.near MP_DEST
              brl     toDest
41$:          jsr     .kbank saveLast
              jsr     .kbank setPlaneT
              jsr     .kbank checkSector
              ;; fall into okay

okay:         lda     ##CONST_OK
              rtl

;;; toDest: the plane at offset Y = the value at near X, pastdest; back to
;;; lastpos if a thing does not fit.
toDest:       phy
              jsr     .kbank saveLast
              lda     abs:0,x
              sta     .near MP_T
              lda     abs:2,x
              sta     .near (MP_T+2)
              jsr     .kbank setPlaneT
              jsr     .kbank checkSector
              ply
              cmp     ##0
              beq     9$
              jsr     .kbank restore
9$:           lda     ##CONST_PASTDEST
              rtl

;;; crushStep: the plane at offset Y = MP_T (one step); a thing that does
;;; not fit holds it: back to lastpos, crushed.
crushStep:    phy
              jsr     .kbank saveLast
              jsr     .kbank setPlaneT
              jsr     .kbank checkSector
              ply
              cmp     ##0
              bne     1$
              brl     okay
1$:           jsr     .kbank restore
              lda     ##CONST_CRUSHED
              rtl

;;; restore: the plane at offset Y = lastpos, and the check again.
restore:      lda     .near MP_LAST
              sta     .near MP_T
              lda     .near (MP_LAST+2)
              sta     .near (MP_T+2)
              jsr     .kbank setPlaneT
              jmp     .kbank checkSector

;;; planeArgs: MP_SEC, MP_SPEED, MP_DEST from the arguments; C = the
;;; direction (the low byte of 4,s of the caller), _Dp[0-3] = the sector.
;;; With TICSTEP > 1, MP_SPEED is the move of the run (speed * ticRun).
planeArgs:    sta     .near MP_SPEED
              stx     .near (MP_SPEED+2)
#if TICSTEP > 1
              sta     .near MP_T
              stx     .near (MP_T+2)
              ldx     .near ticRun
              dex
              beq     2$
1$:           lda     .near MP_SPEED
              clc
              adc     .near MP_T
              sta     .near MP_SPEED
              lda     .near (MP_SPEED+2)
              adc     .near (MP_T+2)
              sta     .near (MP_SPEED+2)
              dex
              bne     1$
2$:
#endif
              lda     dp:.tiny _Dp
              sta     .near MP_SEC
              lda     dp:.tiny (_Dp+2)
              sta     .near (MP_SEC+2)
              lda     dp:.tiny (_Dp+4)
              sta     .near MP_DEST
              lda     dp:.tiny (_Dp+6)
              sta     .near (MP_DEST+2)
              lda     6,s                   ; (4,s of the caller, past the jsr)
              and     ##0x00ff
              rts

;;; minusSpeed, plusSpeed: MP_T = the plane at offset Y -/+ speed.
minusSpeed:   lda     [.tiny _Dp],y
              sec
              sbc     .near MP_SPEED
              sta     .near MP_T
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     .near (MP_SPEED+2)
              sta     .near (MP_T+2)
              dey
              dey
              rts
plusSpeed:    lda     [.tiny _Dp],y
              clc
              adc     .near MP_SPEED
              sta     .near MP_T
              iny
              iny
              lda     [.tiny _Dp],y
              adc     .near (MP_SPEED+2)
              sta     .near (MP_T+2)
              dey
              dey
              rts

;;; saveLast: MP_LAST = the plane at offset Y of MP_SEC.
saveLast:     jsr     .kbank secArg
              lda     [.tiny _Dp],y
              sta     .near MP_LAST
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (MP_LAST+2)
              dey
              dey
              rts

;;; setPlaneT: the plane at offset Y of MP_SEC = MP_T.
setPlaneT:    jsr     .kbank secArg
              lda     .near MP_T
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (MP_T+2)
              sta     [.tiny _Dp],y
              dey
              dey
              rts

;;; secArg: _Dp[0-3] = MP_SEC.
secArg:       lda     .near MP_SEC
              sta     dp:.tiny _Dp
              lda     .near (MP_SEC+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; ---------------------------------------------------------------------------
;;; checkSector: P_CheckSector(MP_SEC): each thing that touches the sector
;;; once, with PIT_ChangeSector. The list can change on the way, so the
;;; scan starts again from the head after each thing. C = nofit.
;;; ---------------------------------------------------------------------------
checkSector:  stz     .near NOFIT
              jsr     .kbank secArg         ; all nodes unvisited
              ldy     ##OFS_SEC_TOUCHING_THINGLIST
              jsr     .kbank loadNode
1$:           lda     .near CS_NODE
              ora     .near (CS_NODE+2)
              beq     10$
              jsr     .kbank nodeArg
              ldy     ##OFS_SN_VISITED
              lda     ##0
              sta     [.tiny _Dp],y
              ldy     ##OFS_SN_M_SNEXT
              jsr     .kbank loadNode
              bra     1$

10$:          jsr     .kbank secArg         ; do: the first unvisited node
              ldy     ##OFS_SEC_TOUCHING_THINGLIST
              jsr     .kbank loadNode
11$:          lda     .near CS_NODE
              ora     .near (CS_NODE+2)
              beq     19$                   ; while (n): none left
              jsr     .kbank nodeArg
              ldy     ##OFS_SN_VISITED
              lda     [.tiny _Dp],y
              beq     12$
              ldy     ##OFS_SN_M_SNEXT
              jsr     .kbank loadNode
              bra     11$
12$:          lda     ##1                   ; visited = true
              sta     [.tiny _Dp],y
              ldy     ##(OFS_SN_M_THING+2)  ; the thing, not MF_NOBLOCKMAP
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SN_M_THING
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##OFS_MO_FLAGS
              lda     [.tiny _Dp],y
              and     ##CONST_MF_NOBLOCKMAP_LO
              bne     10$
              jsr     .kbank changeSector
              bra     10$
19$:          lda     .near NOFIT
              rts

;;; loadNode: CS_NODE = the far pointer at offset Y of _Dp[0-3].
loadNode:     lda     [.tiny _Dp],y
              sta     .near CS_NODE
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (CS_NODE+2)
              rts

;;; nodeArg: _Dp[0-3] = CS_NODE.
nodeArg:      lda     .near CS_NODE
              sta     dp:.tiny _Dp
              lda     .near (CS_NODE+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; changeSector: PIT_ChangeSector(the thing at _Dp[0-3]): a thing that
;;; does not fit is crushed to gibs (dead), removed (dropped item), or sets
;;; nofit (shootable).
changeSector: pei     dp:.tiny (_Dp+2)      ; the thing, at 1,s
              pei     dp:.tiny _Dp
              jsr     .kbank heightClip
              cmp     ##0
              bne     9$
              jsr     .kbank thingArg
              ldy     ##OFS_MO_HEALTH       ; dead: gibs
              lda     [.tiny _Dp],y
              beq     1$
              bpl     3$
1$:           lda     ##CONST_S_GIBS
              jsl     long:P_SetMobjState
              jsr     .kbank thingArg
              ldy     ##OFS_MO_FLAGS        ; not solid, no size
              lda     [.tiny _Dp],y
              and     ##(0xffff - CONST_MF_SOLID_LO)
              sta     [.tiny _Dp],y
              lda     ##0
              ldy     ##OFS_MO_HEIGHT
              sta     [.tiny _Dp],y
              iny
              iny
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_RADIUS
              sta     [.tiny _Dp],y
              iny
              iny
              sta     [.tiny _Dp],y
              bra     9$
3$:           ldy     ##(OFS_MO_FLAGS+2)    ; a dropped item: removed
              lda     [.tiny _Dp],y
              and     ##CONST_MF_DROPPED_HI
              beq     4$
              jsl     long:P_RemoveMobj
              bra     9$
4$:           ldy     ##OFS_MO_FLAGS        ; shootable: nofit
              lda     [.tiny _Dp],y
              and     ##CONST_MF_SHOOTABLE_LO
              beq     9$
              lda     ##1
              sta     .near NOFIT
9$:           pla
              pla
              rts

;;; thingArg: _Dp[0-3] = the thing at 3,s of the caller (5,s here).
thingArg:     lda     3,s
              sta     dp:.tiny _Dp
              lda     5,s
              sta     dp:.tiny (_Dp+2)
              rts

;;; heightClip: P_ThingHeightClip(the thing at _Dp[0-3]): the floor and
;;; ceiling of its position again, z with the floor (or under the ceiling);
;;; C = 1 if it fits.
heightClip:   ldy     ##OFS_MO_Z            ; onfloor = z == floorz
              lda     [.tiny _Dp],y
              ldy     ##OFS_MO_FLOORZ
              cmp     [.tiny _Dp],y
              bne     1$
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_FLOORZ+2)
              cmp     [.tiny _Dp],y
              bne     1$
              lda     ##1
              bra     2$
1$:           lda     ##0
2$:           sta     .near TH_ONFLOOR
              pei     dp:.tiny (_Dp+2)      ; P_CheckPosition(thing, x, y)
              pei     dp:.tiny _Dp
              ldy     ##OFS_MO_Y
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_MO_X
              lda     [.tiny _Dp],y
              jsl     long:P_CheckPosition
              pla
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
              CLEARCLEAN _Dp
              ldy     ##OFS_MO_FLOORZ       ; floorz, ceilingz, dropoffz
              lda     .near _g_tmfloorz
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (_g_tmfloorz+2)
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_CEILINGZ
              lda     .near _g_tmceilingz
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (_g_tmceilingz+2)
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_DROPOFFZ
              lda     .near _g_tmdropoffz
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (_g_tmdropoffz+2)
              sta     [.tiny _Dp],y
              lda     .near TH_ONFLOOR      ; on the floor: z = floorz
              beq     3$
              ldy     ##OFS_MO_FLOORZ
              lda     [.tiny _Dp],y
              ldy     ##OFS_MO_Z
              sta     [.tiny _Dp],y
              ldy     ##(OFS_MO_FLOORZ+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_Z+2)
              sta     [.tiny _Dp],y
              bra     5$
3$:           ldy     ##OFS_MO_Z            ; else under the ceiling:
              lda     [.tiny _Dp],y         ; z + height > ceilingz
              clc
              ldy     ##OFS_MO_HEIGHT
              adc     [.tiny _Dp],y
              sta     .near MP_T
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_HEIGHT+2)
              adc     [.tiny _Dp],y
              sta     .near (MP_T+2)
              ldy     ##OFS_MO_CEILINGZ     ; ceilingz < z + height
              lda     [.tiny _Dp],y
              cmp     .near MP_T
              ldy     ##(OFS_MO_CEILINGZ+2)
              lda     [.tiny _Dp],y
              SLT32   .near (MP_T+2)
              bpl     5$
              ldy     ##OFS_MO_CEILINGZ     ; z = ceilingz - height
              lda     [.tiny _Dp],y
              sec
              ldy     ##OFS_MO_HEIGHT
              sbc     [.tiny _Dp],y
              ldy     ##OFS_MO_Z
              sta     [.tiny _Dp],y
              ldy     ##(OFS_MO_CEILINGZ+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_HEIGHT+2)
              sbc     [.tiny _Dp],y
              ldy     ##(OFS_MO_Z+2)
              sta     [.tiny _Dp],y
5$:           ldy     ##OFS_MO_CEILINGZ     ; fits: ceilingz - floorz >= height
              lda     [.tiny _Dp],y
              sec
              ldy     ##OFS_MO_FLOORZ
              sbc     [.tiny _Dp],y
              sta     .near MP_T
              ldy     ##(OFS_MO_CEILINGZ+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_FLOORZ+2)
              sbc     [.tiny _Dp],y
              sta     .near (MP_T+2)
              lda     .near MP_T            ; !(it < height)
              ldy     ##OFS_MO_HEIGHT
              cmp     [.tiny _Dp],y
              lda     .near (MP_T+2)
              ldy     ##(OFS_MO_HEIGHT+2)
              sbc     [.tiny _Dp],y
              bvc     6$
              eor     ##0x8000
6$:           bmi     7$
              lda     ##1
              rts
7$:           lda     ##0
              rts

;;; ---------------------------------------------------------------------------
;;; T_MoveFloor(floormove_t __far* floor): the floor thinker. The stone
;;; sound every 8 tics; at the destination the donut pool gets its new
;;; floor, and the thinker ends with the stop sound.
;;; ---------------------------------------------------------------------------
              .public T_MoveFloor
T_MoveFloor:  lda     dp:.tiny _Dp          ; the thinker
              sta     .near TM_FLOOR
              lda     dp:.tiny (_Dp+2)
              sta     .near (TM_FLOOR+2)
              ldy     ##FM_DIRECTION        ; T_MovePlaneFloor(sector, speed, dest, direction)
              lda     [.tiny _Dp],y
              pha
              ldy     ##FM_DEST
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              jsr     .kbank floorSector
              jsr     .kbank floorSpeed
              jsl     long:T_MovePlaneFloor
              ply                           ; (the direction)
              pha                           ; res
#if TICSTEP > 1
              TICHIT  7                     ; the stone sound when (leveltime & 7) == 0
              bcs     1$
#else
              lda     .near _g_leveltime    ; the stone sound when (leveltime & 7) == 0
              and     ##7
              bne     1$
#endif
              jsr     .kbank floorSector
              lda     ##CONST_SFX_STNMOV
              jsr     .kbank sectorSound
1$:           pla
              cmp     ##CONST_PASTDEST
              beq     2$
              rtl
2$:           jsr     .kbank floorArg       ; up, a donut: the new floor of the pool
              ldy     ##FM_DIRECTION
              lda     [.tiny _Dp],y
              and     ##0x00ff
              cmp     ##1
              bne     3$
              ldy     ##FM_TYPE
              lda     [.tiny _Dp],y
              cmp     ##CONST_DONUTRAISE
              bne     3$
              ldy     ##FM_TEXTURE
              lda     [.tiny _Dp],y
              pha
              jsr     .kbank floorSector
              ldy     ##OFS_SEC_SPECIAL
              lda     ##0
              sta     [.tiny _Dp],y
              pla
              ldy     ##OFS_SEC_FLOORPIC
              sta     [.tiny _Dp],y
3$:           jsr     .kbank floorSector    ; sector->floordata = NULL
              ldy     ##OFS_SEC_FLOORDATA
              lda     ##0
              sta     [.tiny _Dp],y
              iny
              iny
              sta     [.tiny _Dp],y
              jsr     .kbank floorArg       ; P_RemoveThinker(&floor->thinker)
              jsl     long:P_RemoveThinker
              jsr     .kbank floorSector    ; the stop sound
              lda     ##CONST_SFX_PSTOP
              jsr     .kbank sectorSound
              rtl

;;; floorArg: _Dp[0-3] = the floor thinker TM_FLOOR.
floorArg:     lda     .near TM_FLOOR
              sta     dp:.tiny _Dp
              lda     .near (TM_FLOOR+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; floorSector: _Dp[0-3] = the sector of the floor thinker TM_FLOOR.
floorSector:  jsr     .kbank floorArg
              ldy     ##(FM_SECTOR+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##FM_SECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              rts

;;; floorSpeed: X:C = the speed of the floor thinker TM_FLOOR. _Dp stays.
floorSpeed:   pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              jsr     .kbank floorArg
              ldy     ##(FM_SPEED+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##FM_SPEED
              lda     [.tiny _Dp],y
              ply
              sty     dp:.tiny _Dp
              ply
              sty     dp:.tiny (_Dp+2)
              rts

;;; sectorSound: S_StartSound2(&sector->soundorg, C), the sector at _Dp.
sectorSound:  pha
              lda     dp:.tiny _Dp
              clc
              adc     ##OFS_SEC_SOUNDORG
              sta     dp:.tiny _Dp
              pla
              jsl     long:S_StartSound2
              rts

;;; ---------------------------------------------------------------------------
;;; fixed_t P_FindNextHighestFloor(sector_t __far* sec)
;;; The lowest floor next to sec that is above its floor, else its floor.
;;; ---------------------------------------------------------------------------
              .public P_FindNextHighestFloor
P_FindNextHighestFloor:
              lda     dp:.tiny _Dp
              sta     .near FL_SEC
              lda     dp:.tiny (_Dp+2)
              sta     .near (FL_SEC+2)
              ldy     ##OFS_SEC_FLOORHEIGHT ; currentheight
              lda     [.tiny _Dp],y
              sta     .near MP_LAST
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (MP_LAST+2)
              stz     .near FL_I
1$:           jsr     .kbank nextOther      ; the first one above
              bcs     9$
              bvc     2$
              jsr     .kbank aboveCurrent
              bpl     2$
              lda     [.tiny _Dp],y         ; height = it
              sta     .near MP_T
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (MP_T+2)
3$:           inc     .near FL_I            ; the rest: lower ones above current
              jsr     .kbank nextOther
              bcs     8$
              bvc     3$
              lda     [.tiny _Dp],y         ; it < height
              cmp     .near MP_T
              iny
              iny
              lda     [.tiny _Dp],y
              SLT32   .near (MP_T+2)
              bpl     3$
              jsr     .kbank aboveCurrent   ; && it > currentheight
              bpl     3$
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     [.tiny _Dp],y
              sta     .near MP_T
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (MP_T+2)
              bra     3$
2$:           inc     .near FL_I
              bra     1$
8$:           lda     .near MP_T
              ldx     .near (MP_T+2)
              rtl
9$:           lda     .near MP_LAST         ; none above: currentheight
              ldx     .near (MP_LAST+2)
              rtl

;;; nextOther: for line FL_I of FL_SEC: carry set when i >= linecount;
;;; else V set and _Dp[0-3] = the other sector (getNextSector) if there is
;;; one, Y = OFS_SEC_FLOORHEIGHT.
nextOther:    lda     .near FL_SEC
              sta     dp:.tiny _Dp
              lda     .near (FL_SEC+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_SEC_LINECOUNT
              lda     .near FL_I
              cmp     [.tiny _Dp],y
              bcc     1$
              rts                           ; carry set: the end
1$:           asl     a                     ; sec->lines[i]
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
              lda     .near FL_SEC          ; getNextSector(line, sec)
              sta     dp:.tiny (_Dp+4)
              lda     .near (FL_SEC+2)
              sta     dp:.tiny (_Dp+6)
              jsl     long:getNextSector
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##OFS_SEC_FLOORHEIGHT
              clc
              ora     dp:.tiny (_Dp+2)
              beq     2$
              sep     #0x40                 ; V: a sector
              rts
2$:           clv
              rts

;;; aboveCurrent: N set if the floor of the sector at _Dp is above
;;; MP_LAST (currentheight). Y = OFS_SEC_FLOORHEIGHT after it.
aboveCurrent: lda     .near MP_LAST         ; currentheight < floorheight
              ldy     ##OFS_SEC_FLOORHEIGHT
              cmp     [.tiny _Dp],y
              lda     .near (MP_LAST+2)
              iny
              iny
              sbc     [.tiny _Dp],y
              bvc     1$
              eor     ##0x8000
1$:           php
              ldy     ##OFS_SEC_FLOORHEIGHT
              plp
              rts

;;; ---------------------------------------------------------------------------
;;; boolean EV_DoFloor(const line_t __far* line, floor_e floortype)
;;; A floor thinker for each sector with the tag of the line that has none.
;;; ---------------------------------------------------------------------------
              .public EV_DoFloor
EV_DoFloor:   sta     .near FL_TYPE
              jsr     .kbank lineStart
1$:           jsr     .kbank nextTagged     ; secnum = P_FindSectorFromLineTag(line, secnum)
              bcc     20$
              brl     9$
20$:
              ldy     ##OFS_SEC_FLOORDATA   ; a moving floor already
              lda     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              bne     1$
              lda     ##1
              sta     .near FL_RTN
              lda     .near FL_TYPE
              jsr     .kbank newFloor
              lda     .near FL_TYPE
              cmp     ##CONST_LOWERFLOOR
              bne     2$
              jsr     .kbank floorDown
              jsl     long:P_FindHighestFloorSurrounding
              bra     8$
2$:           cmp     ##CONST_LOWERFLOORTOLOWEST
              bne     3$
              jsr     .kbank floorDown
              jsl     long:P_FindLowestFloorSurrounding
              bra     8$
3$:           cmp     ##CONST_TURBOLOWER
              bne     4$
              jsr     .kbank floorDown
              lda     ##(4 * FLOORSPEED_HI) ; speed = FLOORSPEED * 4
              ldy     ##(FM_SPEED+2)
              jsr     .kbank floorField
              jsr     .kbank secArg2
              jsl     long:P_FindHighestFloorSurrounding
              jsr     .kbank sameAsFloor    ; dest != floorheight: + 8 * FRACUNIT
              beq     8$
              pha
              txa
              clc
              adc     ##8
              tax
              pla
              bra     8$
4$:           cmp     ##CONST_RAISEFLOOR
              bne     5$
              jsr     .kbank floorUp
              jsl     long:P_FindLowestCeilingSurrounding
              jsr     .kbank underCeiling   ; at most the ceiling
              bra     8$
5$:           cmp     ##CONST_RAISEFLOORTONEAREST
              bne     1$                    ; (the other types: nothing)
              jsr     .kbank floorUp
              jsl     long:P_FindNextHighestFloor
8$:           jsr     .kbank setDest
              brl     1$
9$:           lda     .near FL_RTN
              rtl

;;; lineStart: FL_LINE = the line at _Dp[0-3], FL_SECNUM = -1, FL_RTN = 0.
lineStart:    lda     dp:.tiny _Dp
              sta     .near FL_LINE
              lda     dp:.tiny (_Dp+2)
              sta     .near (FL_LINE+2)
              lda     ##0xffff
              sta     .near FL_SECNUM
              stz     .near FL_RTN
              rts

;;; nextTagged: FL_SECNUM = P_FindSectorFromLineTag(FL_LINE, FL_SECNUM);
;;; carry set when there is none, else FL_SEC and _Dp[0-3] = the sector.
nextTagged:   lda     .near FL_LINE
              sta     dp:.tiny _Dp
              lda     .near (FL_LINE+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near FL_SECNUM
              jsl     long:P_FindSectorFromLineTag
              sta     .near FL_SECNUM
              cmp     ##0
              bpl     1$
              sec
              rts
1$:           jsr     .kbank secOf
              clc
              rts

;;; secOf: FL_SEC and _Dp[0-3] = &_g_sectors[C].
secOf:        ldx     ##SIZEOF_SEC
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sectors
              sta     .near FL_SEC
              sta     dp:.tiny _Dp
              lda     .near (_g_sectors+2)
              sta     .near (FL_SEC+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; secArg2: _Dp[0-3] = FL_SEC.
secArg2:      lda     .near FL_SEC
              sta     dp:.tiny _Dp
              lda     .near (FL_SEC+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; newFloor: a new floor thinker of type C for the sector FL_SEC: in the
;;; thinkers, sec->floordata = it, function T_MoveFloor. Out: FL_FLOOR.
newFloor:     pha
              lda     ##FM_SIZE
              jsl     long:Z_CallocLevSpec
              sta     .near FL_FLOOR
              stx     .near (FL_FLOOR+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              jsl     long:P_AddThinker
              jsr     .kbank secArg2        ; sec->floordata = floor
              ldy     ##OFS_SEC_FLOORDATA
              lda     .near FL_FLOOR
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (FL_FLOOR+2)
              sta     [.tiny _Dp],y
              lda     ##.word0 T_MoveFloor  ; floor->thinker.function
              ldy     ##OFS_TH_FUNCTION
              jsr     .kbank floorField
              lda     ##.word2 T_MoveFloor
              ldy     ##(OFS_TH_FUNCTION+2)
              jsr     .kbank floorField
              pla                           ; floor->type
              ldy     ##FM_TYPE
              ;; fall into floorField

;;; floorField: the word at offset Y of the floor thinker FL_FLOOR = C.
floorField:   pha
              lda     .near FL_FLOOR
              sta     dp:.tiny _Dp
              lda     .near (FL_FLOOR+2)
              sta     dp:.tiny (_Dp+2)
              pla
              sta     [.tiny _Dp],y
              rts

;;; floorDown, floorUp: direction -1 or 1, sector FL_SEC, speed FLOORSPEED;
;;; then _Dp[0-3] = FL_SEC for the Find function.
floorDown:    lda     ##0xffff
              bra     floorDir
floorUp:      lda     ##1
floorDir:     sep     #0x20
              pha
              rep     #0x20
              jsr     .kbank floorArgFL
              sep     #0x20
              pla
              ldy     ##FM_DIRECTION
              sta     [.tiny _Dp],y
              rep     #0x20
              ldy     ##FM_SECTOR           ; the sector
              lda     .near FL_SEC
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (FL_SEC+2)
              sta     [.tiny _Dp],y
              ldy     ##FM_SPEED            ; speed = FLOORSPEED
              lda     ##0
              sta     [.tiny _Dp],y
              iny
              iny
              lda     ##FLOORSPEED_HI
              sta     [.tiny _Dp],y
              jmp     .kbank secArg2

;;; floorArgFL: _Dp[0-3] = FL_FLOOR.
floorArgFL:   lda     .near FL_FLOOR
              sta     dp:.tiny _Dp
              lda     .near (FL_FLOOR+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; setDest: floor->floordestheight = X:C.
setDest:      pha
              jsr     .kbank floorArgFL
              pla
              ldy     ##FM_DEST
              sta     [.tiny _Dp],y
              iny
              iny
              txa
              sta     [.tiny _Dp],y
              rts

;;; sameAsFloor: Z set if X:C is the floor height of FL_SEC. X:C stay.
sameAsFloor:  sta     .near MP_T
              stx     .near (MP_T+2)
              jsr     .kbank secArg2
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     [.tiny _Dp],y
              cmp     .near MP_T
              bne     9$
              iny
              iny
              lda     [.tiny _Dp],y
              cmp     .near (MP_T+2)
9$:           php
              lda     .near MP_T
              ldx     .near (MP_T+2)
              plp
              rts

;;; underCeiling: X:C = min(X:C, the ceiling height of FL_SEC), signed:
;;; if (dest > ceilingheight) dest = ceilingheight.
underCeiling: sta     .near MP_T
              stx     .near (MP_T+2)
              jsr     .kbank secArg2
              ldy     ##OFS_SEC_CEILINGHEIGHT ; ceilingheight < dest
              lda     [.tiny _Dp],y
              cmp     .near MP_T
              iny
              iny
              lda     [.tiny _Dp],y
              SLT32   .near (MP_T+2)
              bpl     9$
              ldy     ##(OFS_SEC_CEILINGHEIGHT+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SEC_CEILINGHEIGHT
              lda     [.tiny _Dp],y
              rts
9$:           lda     .near MP_T
              ldx     .near (MP_T+2)
              rts

;;; ---------------------------------------------------------------------------
;;; boolean EV_BuildStairs(const line_t __far* line)
;;; A stair from each sector with the tag of the line: each step rises 8
;;; above the one before; the next step is the back sector of the first two
;;; sided line whose front sector is the step, with the same floor texture
;;; and no moving floor. The tag search goes on after the first step of
;;; each stair.
;;; ---------------------------------------------------------------------------
              .public EV_BuildStairs
EV_BuildStairs:
              jsr     .kbank lineStart      ; ssec = -1, rtn = false
              lda     ##0xffff              ; minssec = -1
              sta     .near FL_MIN
1$:           jsr     .kbank nextTagged     ; ssec, with the lower bound minssec
              bcs     9$
              lda     .near FL_SECNUM       ; while (0 <= ssec && ssec <= minssec)
              cmp     .near FL_MIN
              beq     1$
              bmi     1$
              ldy     ##OFS_SEC_FLOORDATA   ; the first step moves already: none
              lda     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              bne     1$
              lda     .near FL_SECNUM       ; (the outer index stays ssec)
              pha
              lda     ##1
              sta     .near FL_RTN
              ldy     ##OFS_SEC_FLOORHEIGHT ; height = floorheight + stairsize
              lda     [.tiny _Dp],y
              sta     .near FL_HEIGHT
              iny
              iny
              lda     [.tiny _Dp],y
              clc
              adc     ##8
              sta     .near (FL_HEIGHT+2)
              ldy     ##OFS_SEC_FLOORPIC    ; texture = sec->floorpic
              lda     [.tiny _Dp],y
              sta     .near FL_TEXTURE
              jsr     .kbank stairStep      ; the first step
2$:           jsr     .kbank nextStep       ; the next ones
              bcs     2$
              pla                           ; the outer index
              sta     .near FL_SECNUM
              brl     1$
9$:           lda     .near FL_RTN
              rtl

;;; stairStep: a floor thinker for the step FL_SEC: up to FL_HEIGHT at
;;; FLOORSPEED / 4, type buildStair.
stairStep:    lda     ##CONST_BUILDSTAIR
              jsr     .kbank newFloor
              jsr     .kbank floorUp
              jsr     .kbank floorArgFL     ; speed = FLOORSPEED / 4
              ldy     ##FM_SPEED
              lda     ##0x4000
              sta     [.tiny _Dp],y
              iny
              iny
              lda     ##0
              sta     [.tiny _Dp],y
              lda     .near FL_HEIGHT
              ldx     .near (FL_HEIGHT+2)
              jmp     .kbank setDest

;;; nextStep: find the next step of the stair from FL_SEC (FL_SECNUM):
;;; carry set if there is one (a thinker for it, height + 8), else clear.
nextStep:     stz     .near FL_I
1$:           jsr     .kbank secArg2        ; for (i = 0; i < linecount; i++)
              ldy     ##OFS_SEC_LINECOUNT
              lda     .near FL_I
              cmp     [.tiny _Dp],y
              bcc     2$
              clc
              rts
2$:           asl     a                     ; the line sec->lines[i]
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
              ldy     ##OFS_LINE_FLAGS      ; two sided
              lda     [.tiny _Dp],y
              and     ##CONST_ML_TWOSIDED
              beq     8$
              ldy     ##OFS_LINE_SIDENUM    ; the front sector is this step
              jsr     .kbank lineSector
              jsr     .kbank sectorNum
              cmp     .near FL_SECNUM
              bne     8$
              ldy     ##(OFS_LINE_SIDENUM+2) ; the back sector (none: next line)
              lda     [.tiny _Dp],y
              cmp     ##0xffff
              beq     8$
              jsr     .kbank lineSector
              sta     .near MP_T            ; tsec
              stx     .near (MP_T+2)
              pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##OFS_SEC_FLOORPIC    ; the same floor texture
              lda     [.tiny _Dp],y
              cmp     .near FL_TEXTURE
              bne     7$
              ldy     ##OFS_SEC_FLOORDATA   ; and no moving floor
              lda     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              bne     7$
              pla                           ; the step
              pla
              lda     .near (FL_HEIGHT+2)   ; height += stairsize
              clc
              adc     ##8
              sta     .near (FL_HEIGHT+2)
              lda     .near MP_T            ; sec = tsec, secnum = its number
              sta     .near FL_SEC
              ldx     .near (MP_T+2)
              stx     .near (FL_SEC+2)
              jsr     .kbank sectorNum
              sta     .near FL_SECNUM
              jsr     .kbank stairStep
              sec
              rts
7$:           pla
              pla
8$:           inc     .near FL_I
              brl     1$

;;; lineSector: X:C = the sector of side number [line _Dp] + Y. _Dp stays.
lineSector:   lda     [.tiny _Dp],y
              ldx     ##SIZEOF_SIDE
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sides
              sta     .near MP_LAST
              lda     .near (_g_sides+2)
              sta     .near (MP_LAST+2)
              pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              lda     .near MP_LAST
              sta     dp:.tiny _Dp
              lda     .near (MP_LAST+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_SIDE_SECTOR+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SIDE_SECTOR
              lda     [.tiny _Dp],y
              ply
              sty     dp:.tiny _Dp
              ply
              sty     dp:.tiny (_Dp+2)
              rts

;;; sectorNum: C = (sector C - _g_sectors) / SIZEOF_SEC, the low word of
;;; the sector pointer in C (the sectors are in one bank).
sectorNum:    sec
              sbc     .near _g_sectors
              ldx     ##SIZEOF_SEC
              jsl     long:_Div16
              rts

;;; ---------------------------------------------------------------------------
;;; boolean EV_DoDonut(const line_t __far* line)
;;; The pillar (tagged) lowers and the pool around it rises, both to the
;;; floor of the sector around the pool, which gives the pool its texture.
;;; ---------------------------------------------------------------------------
              .public EV_DoDonut
EV_DoDonut:   jsr     .kbank lineStart
1$:           jsr     .kbank nextTagged     ; s1: the pillar
              bcc     20$
              brl     9$
20$:
              lda     dp:.tiny _Dp
              sta     .near FL_S1
              lda     dp:.tiny (_Dp+2)
              sta     .near (FL_S1+2)
              ldy     ##OFS_SEC_FLOORDATA   ; moving already: no
              lda     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              bne     1$
              ldy     ##OFS_SEC_LINES       ; s2 = getNextSector(s1->lines[0], s1)
              lda     [.tiny _Dp],y
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
              lda     .near FL_S1
              sta     dp:.tiny (_Dp+4)
              lda     .near (FL_S1+2)
              sta     dp:.tiny (_Dp+6)
              jsl     long:getNextSector
              sta     .near FL_S2
              stx     .near (FL_S2+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ora     dp:.tiny (_Dp+2)
              beq     1$
              ldy     ##OFS_SEC_FLOORDATA   ; the pool moves already: no
              lda     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              bne     1$
              stz     .near FL_I            ; a two sided line of the pool
2$:           jsr     .kbank s2Arg          ; whose back sector is not the pillar
              ldy     ##OFS_SEC_LINECOUNT
              lda     .near FL_I
              cmp     [.tiny _Dp],y
              bcs     1$
              asl     a
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
              ldy     ##(OFS_LINE_SIDENUM+2) ; LN_BACKSECTOR
              lda     [.tiny _Dp],y
              cmp     ##0xffff
              beq     3$
              jsr     .kbank lineSector
              cmp     .near FL_S1           ; the pillar: no
              bne     4$
              cpx     .near (FL_S1+2)
              bne     4$
3$:           inc     .near FL_I
              bra     2$
4$:           sta     .near FL_S3           ; s3: the model
              stx     .near (FL_S3+2)
              lda     ##1
              sta     .near FL_RTN
              lda     .near FL_S2           ; the rising slime
              sta     .near FL_SEC
              lda     .near (FL_S2+2)
              sta     .near (FL_SEC+2)
              lda     ##CONST_DONUTRAISE
              jsr     .kbank newFloor
              jsr     .kbank floorUp
              jsr     .kbank halfSpeed
              jsr     .kbank s3Arg          ; texture = s3->floorpic
              ldy     ##OFS_SEC_FLOORPIC
              lda     [.tiny _Dp],y
              ldy     ##FM_TEXTURE
              jsr     .kbank floorField
              jsr     .kbank s3Floor        ; dest = s3->floorheight
              jsr     .kbank setDest
              lda     .near FL_S1           ; the lowering pillar
              sta     .near FL_SEC
              lda     .near (FL_S1+2)
              sta     .near (FL_SEC+2)
              lda     ##CONST_LOWERFLOOR
              jsr     .kbank newFloor
              jsr     .kbank floorDown
              jsr     .kbank halfSpeed
              jsr     .kbank s3Floor
              jsr     .kbank setDest
              brl     1$
9$:           lda     .near FL_RTN
              rtl

;;; s2Arg, s3Arg: _Dp[0-3] = FL_S2, FL_S3.
s2Arg:        lda     .near FL_S2
              sta     dp:.tiny _Dp
              lda     .near (FL_S2+2)
              sta     dp:.tiny (_Dp+2)
              rts
s3Arg:        lda     .near FL_S3
              sta     dp:.tiny _Dp
              lda     .near (FL_S3+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; s3Floor: X:C = the floor height of FL_S3.
s3Floor:      jsr     .kbank s3Arg
              ldy     ##(OFS_SEC_FLOORHEIGHT+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     [.tiny _Dp],y
              rts

;;; halfSpeed: the speed of the new floor thinker = FLOORSPEED / 2.
halfSpeed:    jsr     .kbank floorArgFL
              ldy     ##FM_SPEED
              lda     ##0x8000
              sta     [.tiny _Dp],y
              iny
              iny
              lda     ##0
              sta     [.tiny _Dp],y
              rts
