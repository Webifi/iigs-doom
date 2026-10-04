;;; Actor allocation, spawning, removal and respawn.
;;;
;;; P_SpawnMobj initializes an actor; the remaining entry points create map
;;; things, players, missiles and impact effects. P_RemoveMobj detaches an
;;; actor from world structures and schedules its removal.
;;; A new missile pointer stays on the stack across P_TryMove: collision
;;; handling can re-enter game logic and overwrite ordinary scratch.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"
#include "info.inc"

              .extern _Dp, mobjinfo, states, _g_thingPool, _g_thingPoolSize
              .extern _g_gameskill, _g_totallive, _g_totalkills, _g_totalitems
              .extern _g_demoplayback, _g_player, _g_linetarget
              .extern P_Random, P_SetThingPosition, P_UnsetThingPosition
              .extern P_AddThinker, P_MobjThinker, P_MobjBrainlessThinker
              .extern addIfFunc, linkRemove
              .extern Z_MallocLevel, P_DelSeclist, S_StopSound, P_RemoveThing
              .extern P_SetMobjState, P_IsAttackRangeMeleeRange, S_StartSound
              .extern P_TryMove, P_ExplodeMissile, R_PointToAngle3, FixedMulAngle
              .extern finesine, finecosine, P_AproxDistance, _Div32, FixedMul
              .extern P_AimLineAttack, P_CheckPosition, R_PointInSubsector
              .extern G_PlayerReborn, P_SetupPsprites, IIGS_MulLo16, _Mod16
              .extern I_Error, MA, MB, MR, umul16

TP_BITS       .equ    MM_TP_MAP       ; the free mobjs of the pool: bit i & 15
                                      ;   of word i >> 4 for mobj i (1 free)
TP_MASK       .equ    (MM_TP_MAP + 0x40) ; 1 << k at 2 k (poolInit)
TP_MAX        .equ    512             ;   (the pool: up to TP_MAX mobjs)

PAD_NM        .equ    15
MTF_EASY      .equ    1               ; the skill flags of a map thing
MTF_NORMAL    .equ    2
MTF_HARD      .equ    4
MTF_AMBUSH    .equ    8
OFS_MT_X      .equ    0               ; packed map-thing record, from the THINGS lump
OFS_MT_Y      .equ    2
OFS_MT_TYPE   .equ    4
OFS_MT_ANGLE  .equ    6               ; int8_t, 45 degree units
OFS_MT_OPTIONS .equ   7               ; int8_t

              .section znear, bss
SM_X:         .space  4               ; P_SpawnMobj: x, y, z, type
SM_Y:         .space  4
SM_Z:         .space  4
SM_TYPE:      .space  2
SM_INFO:      .space  2               ; &mobjinfo[type] (near)
SM_MO:        .space  4               ; the new mobj
RM_MO:        .space  4               ; P_RemoveMobj: the mobj
SP_X:         .space  4               ; the spawn functions: x, y, z
SP_Y:         .space  4
SP_Z:         .space  4
SP_TH:        .space  4               ;   the new thing
SP_SRC:       .space  4               ;   the source
SP_DEST:      .space  4               ;   the destination
SP_AN:        .space  4               ;   the angle
SP_SLOPE:     .space  4
SP_T:         .space  4
SP_DAMAGE:    .space  2
TP_HW:        .space  2               ; 2 * the highest word of TP_BITS that
                                      ;   can have a free mobj, < 0 none
SP_MT:        .space  4               ; P_SpawnMapThing: the map thing
NR_MO:        .space  4               ; P_NightmareRespawn: the dead monster

              .section cfar, rodata
fdnErr:       .asciz  "P_FindDoomedNum: unknown thing %i"

;;; ---------------------------------------------------------------------------
;;; mobj_t __far* P_SpawnMobj(fixed_t x, fixed_t y, fixed_t z, mobjtype_t type)
;;;   In: X:C = x, _Dp[0-3] = y, _Dp[4-7] = z, 4,s = type. Out: X:C.
;;; A new mobj of the type in its spawn state (no action), in the blocks
;;; and sectors of x, y, on the floor (ONFLOORZ) or under the ceiling
;;; (ONCEILINGZ), with its thinker.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public P_SpawnMobj
P_SpawnMobj:  sta     .near SM_X
              stx     .near (SM_X+2)
              lda     dp:.tiny _Dp
              sta     .near SM_Y
              lda     dp:.tiny (_Dp+2)
              sta     .near (SM_Y+2)
              lda     dp:.tiny (_Dp+4)
              sta     .near SM_Z
              lda     dp:.tiny (_Dp+6)
              sta     .near (SM_Z+2)
              lda     4,s
              sta     .near SM_TYPE
              jsr     .kbank newMobj
              lda     .near SM_TYPE         ; info = &mobjinfo[type]
              INFOADDR
              sta     .near SM_INFO
              tax
              jsr     .kbank moArg
              lda     .near SM_TYPE         ; type, x, y
              ldy     ##OFS_MO_TYPE
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_X
              lda     .near SM_X
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (SM_X+2)
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near SM_Y
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (SM_Y+2)
              sta     [.tiny _Dp],y
              lda     abs:OFS_MI_RADIUS,x   ; radius, height
              ldy     ##OFS_MO_RADIUS
              sta     [.tiny _Dp],y
              lda     abs:(OFS_MI_RADIUS+2),x
              iny
              iny
              sta     [.tiny _Dp],y
              lda     abs:OFS_MI_HEIGHT,x
              ldy     ##OFS_MO_HEIGHT
              sta     [.tiny _Dp],y
              lda     abs:(OFS_MI_HEIGHT+2),x
              iny
              iny
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_FLAGS        ; flags |= info->flags
              lda     [.tiny _Dp],y
              ora     abs:OFS_MI_FLAGS,x
              sta     [.tiny _Dp],y
              iny
              iny
              lda     [.tiny _Dp],y
              ora     abs:(OFS_MI_FLAGS+2),x
              sta     [.tiny _Dp],y
              lda     abs:OFS_MI_SPAWNHEALTH,x ; health
              ldy     ##OFS_MO_HEALTH
              sta     [.tiny _Dp],y
              lda     .near _g_gameskill    ; reactiontime, not in nightmare
              cmp     ##CONST_SK_NIGHTMARE
              beq     1$
              lda     abs:OFS_MI_REACTIONTIME,x
              ldy     ##OFS_MO_REACTIONTIME
              sta     [.tiny _Dp],y
1$:           jsl     long:P_Random         ; (only for compatibility)
              ldx     .near SM_INFO         ; the spawn state, without its action
              lda     abs:OFS_MI_SPAWNSTATE,x
              STATEADDR
              tax
              jsr     .kbank moArg
              txa
              ldy     ##OFS_MO_STATE
              sta     [.tiny _Dp],y
              iny
              iny
              lda     ##.word2 states
              sta     [.tiny _Dp],y
              lda     abs:OFS_ST_TICS,x
              ldy     ##OFS_MO_TICS
              sta     [.tiny _Dp],y
              lda     abs:OFS_ST_SPRITE,x
              ldy     ##OFS_MO_SPRITE
              sta     [.tiny _Dp],y
              lda     abs:OFS_ST_FRAME,x
              ldy     ##OFS_MO_FRAME
              sta     [.tiny _Dp],y
              jsl     long:P_SetThingPosition ; the blocks and the sector
              jsr     .kbank moArg          ; floorz = dropoffz = the floor
              ldy     ##(OFS_MO_SUBSECTOR+2) ; of the sector, ceilingz
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_MO_SUBSECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              ldy     ##(OFS_SUB_SECTOR+2)
              lda     [.tiny (_Dp+4)],y
              tax
              ldy     ##OFS_SUB_SECTOR
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     [.tiny (_Dp+4)],y
              ldy     ##OFS_MO_FLOORZ
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_DROPOFFZ
              sta     [.tiny _Dp],y
              ldy     ##(OFS_SEC_FLOORHEIGHT+2)
              lda     [.tiny (_Dp+4)],y
              ldy     ##(OFS_MO_FLOORZ+2)
              sta     [.tiny _Dp],y
              ldy     ##(OFS_MO_DROPOFFZ+2)
              sta     [.tiny _Dp],y
              ldy     ##OFS_SEC_CEILINGHEIGHT
              lda     [.tiny (_Dp+4)],y
              ldy     ##OFS_MO_CEILINGZ
              sta     [.tiny _Dp],y
              ldy     ##(OFS_SEC_CEILINGHEIGHT+2)
              lda     [.tiny (_Dp+4)],y
              ldy     ##(OFS_MO_CEILINGZ+2)
              sta     [.tiny _Dp],y
              lda     .near (SM_Z+2)        ; z: ONFLOORZ = floorz, ONCEILINGZ
              cmp     ##CONST_ONFLOORZ_HI   ; = ceilingz - height, else z
              bne     2$
              lda     .near SM_Z
              cmp     ##CONST_ONFLOORZ_LO
              bne     4$
              ldy     ##OFS_MO_FLOORZ
              lda     [.tiny _Dp],y
              tax
              ldy     ##(OFS_MO_FLOORZ+2)
              lda     [.tiny _Dp],y
              bra     5$
2$:           cmp     ##CONST_ONCEILINGZ_HI
              bne     4$
              lda     .near SM_Z
              cmp     ##CONST_ONCEILINGZ_LO
              bne     4$
              ldy     ##OFS_MO_CEILINGZ
              lda     [.tiny _Dp],y
              sec
              ldy     ##OFS_MO_HEIGHT
              sbc     [.tiny _Dp],y
              tax
              ldy     ##(OFS_MO_CEILINGZ+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_HEIGHT+2)
              sbc     [.tiny _Dp],y
              bra     5$
4$:           ldx     .near SM_Z
              lda     .near (SM_Z+2)
5$:           ldy     ##(OFS_MO_Z+2)        ; (X = the low word, C the high)
              sta     [.tiny _Dp],y
              txa
              ldy     ##OFS_MO_Z
              sta     [.tiny _Dp],y
              lda     .near SM_TYPE         ; the thinker: full below MT_MISC0,
              cmp     ##CONST_MT_MISC0      ; the states only with tics != -1,
              bcs     6$                    ; else none
              lda     ##.word0 P_MobjThinker
              ldx     ##.word2 P_MobjThinker
              bra     8$
6$:           ldy     ##OFS_MO_TICS
              lda     [.tiny _Dp],y
              cmp     ##0xffff
              beq     7$
              lda     ##.word0 P_MobjBrainlessThinker
              ldx     ##.word2 P_MobjBrainlessThinker
              bra     8$
7$:           lda     ##0
              tax
8$:           ldy     ##OFS_TH_FUNCTION
              sta     [.tiny _Dp],y
              iny
              iny
              txa
              sta     [.tiny _Dp],y
              jsl     long:addIfFunc        ; no function: not a thinker
              jsr     .kbank moArg          ; a monster to kill: totallive++
              ldy     ##(OFS_MO_FLAGS+2)
              lda     [.tiny _Dp],y
              and     ##CONST_MF_COUNTKILL_HI
              beq     9$
              inc     .near _g_totallive
              bne     9$
              inc     .near (_g_totallive+2)
9$:           lda     .near SM_MO
              ldx     .near (SM_MO+2)
              rtl

;;; newMobj: SM_MO and _Dp[0-3] = a cleared mobj: the free one of the pool
;;; with the highest index (flags MF_POOLED, poolTake), else a new zone
;;; block.
newMobj:      jsl     long:poolTake
              bcs     5$
              jsr     .kbank clearMo
              ldy     ##(OFS_MO_FLAGS+2)
              lda     ##CONST_MF_POOLED_HI
              sta     [.tiny _Dp],y
              bra     6$
5$:           stz     dp:.tiny _Dp          ; Z_MallocLevel(sizeof(mobj_t), NULL)
              stz     dp:.tiny (_Dp+2)
              lda     ##SIZEOF_MO
              jsl     long:Z_MallocLevel
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              jsr     .kbank clearMo
6$:           lda     dp:.tiny _Dp
              sta     .near SM_MO
              lda     dp:.tiny (_Dp+2)
              sta     .near (SM_MO+2)
              rts
              .space  PAD_NM                ; (the fragment keeps its size)

;;; clearMo: the fields of the mobj at _Dp[0-3] that P_SpawnMobj does not
;;; write in full get 0: flags to sightline (flags |= info), the moms, and
;;; snext to subsector (the links of P_SetThingPosition are 3 bytes, some
;;; not written; sprite and frame come in it). The others come from
;;; P_SpawnMobj, P_SetThingPosition and P_AddThinker.
clearMo:      lda     ##0
              ldy     ##(SIZEOF_MO - 2)     ; flags .. sightline
1$:           sta     [.tiny _Dp],y
              dey
              dey
              cpy     ##OFS_MO_FLAGS
              bcs     1$
              ldy     ##(OFS_MO_MOMZ + 2)   ; momx, momy, momz
2$:           sta     [.tiny _Dp],y
              dey
              dey
              cpy     ##OFS_MO_MOMX
              bcs     2$
              ldy     ##(OFS_MO_SUBSECTOR + 2) ; snext .. subsector
3$:           sta     [.tiny _Dp],y
              dey
              dey
              cpy     ##OFS_MO_SNEXT
              bcs     3$
              rts

;;; moArg: _Dp[0-3] = SM_MO.
moArg:        lda     .near SM_MO
              sta     dp:.tiny _Dp
              lda     .near (SM_MO+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; ---------------------------------------------------------------------------
;;; void P_RemoveMobj(mobj_t __far* mobj)           In: _Dp[0-3].
;;; Out of the blocks and sectors, its sector nodes deleted, its sound
;;; stopped, no references (except in demo playback), and freed at the end
;;; of the thinker loop.
;;; ---------------------------------------------------------------------------
              .public P_RemoveMobj
P_RemoveMobj: lda     dp:.tiny _Dp
              sta     .near RM_MO
              lda     dp:.tiny (_Dp+2)
              sta     .near (RM_MO+2)
              jsl     long:P_UnsetThingPosition
              jsl     long:P_DelSeclist
              jsr     .kbank rmArg
              jsl     long:S_StopSound
              jsr     .kbank rmArg
              lda     .near _g_demoplayback
              bne     1$
              lda     ##0                   ; target = lastenemy = NULL
              ldy     ##OFS_MO_TARGET
              sta     [.tiny _Dp],y
              iny
              iny
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_LASTENEMY
              sta     [.tiny _Dp],y
              iny
              iny
              sta     [.tiny _Dp],y
1$:           jmp     long:linkRemove       ; link a quiet mobj, then remove

rmArg:        lda     .near RM_MO
              sta     dp:.tiny _Dp
              lda     .near (RM_MO+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; ---------------------------------------------------------------------------
;;; void P_SpawnPuff(fixed_t x, fixed_t y, fixed_t z)
;;;   In: X:C = x, _Dp[0-3] = y, _Dp[4-7] = z.
;;; A puff a bit above or below z that rises, without the spark for a punch.
;;; ---------------------------------------------------------------------------
              .public P_SpawnPuff
P_SpawnPuff:  jsr     .kbank saveXYZ
              jsr     .kbank zNoise
              lda     ##CONST_MT_PUFF
              jsr     .kbank spawnXYZ
              ldy     ##OFS_MO_MOMZ         ; momz = FRACUNIT
              lda     ##0
              sta     [.tiny _Dp],y
              iny
              iny
              lda     ##1
              sta     [.tiny _Dp],y
              jsr     .kbank ticsNoise
              jsl     long:P_IsAttackRangeMeleeRange
              cmp     ##0
              beq     9$
              jsr     .kbank thArg
              lda     ##CONST_S_PUFF3
              jmp     long:P_SetMobjState
9$:           rtl

;;; ---------------------------------------------------------------------------
;;; void P_SpawnBlood(fixed_t x, fixed_t y, fixed_t z, int16_t damage)
;;;   In: X:C = x, _Dp[0-3] = y, _Dp[4-7] = z, 4,s = damage.
;;; Blood a bit above or below z that rises; less damage, less blood.
;;; ---------------------------------------------------------------------------
              .public P_SpawnBlood
P_SpawnBlood: pha
              lda     6,s
              sta     .near SP_DAMAGE
              pla
              jsr     .kbank saveXYZ
              jsr     .kbank zNoise
              lda     ##CONST_MT_BLOOD
              jsr     .kbank spawnXYZ
              ldy     ##OFS_MO_MOMZ         ; momz = 2 * FRACUNIT
              lda     ##0
              sta     [.tiny _Dp],y
              iny
              iny
              lda     ##2
              sta     [.tiny _Dp],y
              jsr     .kbank ticsNoise
              lda     .near SP_DAMAGE       ; damage < 9: S_BLOOD3
              sec
              sbc     ##9
              bvc     1$
              eor     ##0x8000
1$:           bmi     3$
              lda     .near SP_DAMAGE       ; damage <= 12: S_BLOOD2
              sec
              sbc     ##13
              bvc     2$
              eor     ##0x8000
2$:           bpl     9$
              lda     ##CONST_S_BLOOD2
              bra     4$
3$:           lda     ##CONST_S_BLOOD3
4$:           pha
              jsr     .kbank thArg
              pla
              jmp     long:P_SetMobjState
9$:           rtl

;;; saveXYZ: SP_X, SP_Y, SP_Z = X:C, _Dp[0-3], _Dp[4-7].
saveXYZ:      sta     .near SP_X
              stx     .near (SP_X+2)
              lda     dp:.tiny _Dp
              sta     .near SP_Y
              lda     dp:.tiny (_Dp+2)
              sta     .near (SP_Y+2)
              lda     dp:.tiny (_Dp+4)
              sta     .near SP_Z
              lda     dp:.tiny (_Dp+6)
              sta     .near (SP_Z+2)
              rts

;;; zNoise: SP_Z += (P_Random() - P_Random()) << 10.
zNoise:       jsl     long:P_Random
              sta     .near SP_T
              jsl     long:P_Random
              eor     ##0xffff              ; t - r
              sec
              adc     .near SP_T
              pha
              ldx     ##6                   ; the high word: (t - r) >> 6
1$:           cmp     ##0x8000
              ror     a
              dex
              bne     1$
              tax
              pla                           ; the low word: (t - r) << 10
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     .near SP_Z
              sta     .near SP_Z
              txa
              adc     .near (SP_Z+2)
              sta     .near (SP_Z+2)
              rts

;;; spawnXYZ: SP_TH and _Dp[0-3] = P_SpawnMobj(SP_X, SP_Y, SP_Z, C).
spawnXYZ:     pha
              lda     .near SP_Y
              sta     dp:.tiny _Dp
              lda     .near (SP_Y+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near SP_Z
              sta     dp:.tiny (_Dp+4)
              lda     .near (SP_Z+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near SP_X
              ldx     .near (SP_X+2)
              jsl     long:P_SpawnMobj
              ply
              sta     .near SP_TH
              stx     .near (SP_TH+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              rts

;;; ticsNoise: SP_TH->tics -= P_Random() & 3, at least 1. _Dp[0-3] = SP_TH.
ticsNoise:    jsl     long:P_Random
              and     ##3
              sta     .near SP_T
              jsr     .kbank thArg
              ldy     ##OFS_MO_TICS
              lda     [.tiny _Dp],y
              sec
              sbc     .near SP_T
              beq     1$
              bpl     2$
1$:           lda     ##1
2$:           sta     [.tiny _Dp],y
              rts

;;; thArg: _Dp[0-3] = SP_TH.
thArg:        lda     .near SP_TH
              sta     dp:.tiny _Dp
              lda     .near (SP_TH+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; ---------------------------------------------------------------------------
;;; mobj_t __far* P_SpawnMissile(mobj_t __far* source, mobj_t __far* dest, mobjtype_t type)
;;;   In: _Dp[0-3] = source, _Dp[4-7] = dest, C = type. Out: X:C.
;;; A missile from 32 units above source toward dest (not so exact for a
;;; shadow dest), with a speed down or up to its height.
;;; ---------------------------------------------------------------------------
              .public P_SpawnMissile
P_SpawnMissile:
              pha
              lda     dp:.tiny _Dp
              sta     .near SP_SRC
              lda     dp:.tiny (_Dp+2)
              sta     .near (SP_SRC+2)
              lda     dp:.tiny (_Dp+4)
              sta     .near SP_DEST
              lda     dp:.tiny (_Dp+6)
              sta     .near (SP_DEST+2)
              jsr     .kbank srcAbove       ; x, y, z + 32 of source
              pla
              jsr     .kbank spawnXYZ
              jsr     .kbank seeTarget      ; the see sound, target = source
              jsr     .kbank destDelta      ; an = R_PointToAngle2(source, dest)
              jsl     long:R_PointToAngle3
              sta     .near SP_AN
              stx     .near (SP_AN+2)
              lda     .near SP_DEST         ; a shadow dest:
              sta     dp:.tiny _Dp          ; an += (P_Random() - P_Random()) << 20
              lda     .near (SP_DEST+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_MO_FLAGS+2)
              lda     [.tiny _Dp],y
              and     ##CONST_MF_SHADOW_HI
              beq     1$
              jsl     long:P_Random
              sta     .near SP_T
              jsl     long:P_Random
              eor     ##0xffff
              sec
              adc     .near SP_T
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     .near (SP_AN+2)
              sta     .near (SP_AN+2)
1$:           jsr     .kbank angleMom       ; angle, momx, momy
              jsr     .kbank destDelta      ; dist = P_AproxDistance(dx, dy) / speed
              jsl     long:P_AproxDistance
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              jsr     .kbank thSpeed
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              jsl     long:_Div32
              cpx     ##0x8000              ; at least 1
              bcs     2$
              cpx     ##0
              bne     3$
              cmp     ##0
              bne     3$
2$:           lda     ##1
              ldx     ##0
3$:           sta     dp:.tiny (_Dp+4)      ; momz = (dest->z - source->z) / dist
              stx     dp:.tiny (_Dp+6)
              lda     .near SP_DEST
              sta     dp:.tiny _Dp
              lda     .near (SP_DEST+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_MO_Z
              lda     [.tiny _Dp],y
              sta     .near SP_T
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (SP_T+2)
              jsr     .kbank srcArg
              ldy     ##OFS_MO_Z
              lda     .near SP_T
              sec
              sbc     [.tiny _Dp],y
              pha
              iny
              iny
              lda     .near (SP_T+2)
              sbc     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+2)
              pla
              sta     dp:.tiny _Dp
              jsl     long:_Div32
              pha
              jsr     .kbank thArg
              pla
              ldy     ##OFS_MO_MOMZ
              sta     [.tiny _Dp],y
              iny
              iny
              txa
              sta     [.tiny _Dp],y
              lda     .near (SP_TH+2)       ; P_CheckMissileSpawn(th); th is
              pha                           ; the result
              lda     .near SP_TH
              pha
              jsr     .kbank checkMissile
              pla
              plx
              rtl

;;; ---------------------------------------------------------------------------
;;; void P_SpawnPlayerMissile(mobj_t __far* source)   In: _Dp[0-3].
;;; A rocket from 32 units above source, aimed at a monster straight ahead
;;; or 5.6 degrees to one side, else level.
;;; ---------------------------------------------------------------------------
              .public P_SpawnPlayerMissile
P_SpawnPlayerMissile:
              lda     dp:.tiny _Dp
              sta     .near SP_SRC
              lda     dp:.tiny (_Dp+2)
              sta     .near (SP_SRC+2)
              ldy     ##OFS_MO_ANGLE        ; an = source->angle
              lda     [.tiny _Dp],y
              sta     .near SP_AN
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (SP_AN+2)
              jsr     .kbank aim
              bne     2$
              lda     .near (SP_AN+2)       ; an += 1 << 26
              clc
              adc     ##0x0400
              sta     .near (SP_AN+2)
              jsr     .kbank aim
              bne     2$
              lda     .near (SP_AN+2)       ; an -= 2 << 26
              sec
              sbc     ##0x0800
              sta     .near (SP_AN+2)
              jsr     .kbank aim
              bne     2$
              jsr     .kbank srcArg         ; none: an = source->angle, slope 0
              ldy     ##OFS_MO_ANGLE
              lda     [.tiny _Dp],y
              sta     .near SP_AN
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (SP_AN+2)
              stz     .near SP_SLOPE
              stz     .near (SP_SLOPE+2)
2$:           jsr     .kbank srcAbove       ; th = P_SpawnMobj(x, y, z + 32, MT_ROCKET)
              lda     ##CONST_MT_ROCKET
              jsr     .kbank spawnXYZ
              jsr     .kbank seeTarget
              jsr     .kbank angleMom       ; angle, momx, momy
              lda     .near SP_SLOPE        ; momz = FixedMul(speed, slope)
              sta     dp:.tiny _Dp
              lda     .near (SP_SLOPE+2)
              sta     dp:.tiny (_Dp+2)
              jsr     .kbank thSpeed
              jsl     long:FixedMul
              pha
              jsr     .kbank thArg
              pla
              ldy     ##OFS_MO_MOMZ
              sta     [.tiny _Dp],y
              iny
              iny
              txa
              sta     [.tiny _Dp],y
              jsr     .kbank checkMissile
              rtl

;;; aim: SP_SLOPE = P_AimLineAttack(source, SP_AN, 16 * 64 * FRACUNIT);
;;; Z clear when there is a linetarget.
aim:          jsr     .kbank srcArg
              stz     dp:.tiny (_Dp+4)
              lda     ##(16 * 64)
              sta     dp:.tiny (_Dp+6)
              lda     .near SP_AN
              ldx     .near (SP_AN+2)
              jsl     long:P_AimLineAttack
              sta     .near SP_SLOPE
              stx     .near (SP_SLOPE+2)
              lda     .near _g_linetarget
              ora     .near (_g_linetarget+2)
              rts

;;; srcArg: _Dp[0-3] = SP_SRC. srcAbove: SP_X, SP_Y, SP_Z = the x, y and
;;; z + 32 * FRACUNIT of SP_SRC.
srcArg:       lda     .near SP_SRC
              sta     dp:.tiny _Dp
              lda     .near (SP_SRC+2)
              sta     dp:.tiny (_Dp+2)
              rts
srcAbove:     jsr     .kbank srcArg
              ldy     ##OFS_MO_X
              ldx     ##0
1$:           lda     [.tiny _Dp],y
              sta     abs:.near SP_X,x
              iny
              iny
              inx
              inx
              cpx     ##12
              bcc     1$
              lda     .near (SP_Z+2)
              clc
              adc     ##32
              sta     .near (SP_Z+2)
              rts

;;; seeTarget: the see sound of SP_TH (if it has one); th->target = SP_SRC.
seeTarget:    jsr     .kbank thArg
              ldy     ##OFS_MO_TYPE
              lda     [.tiny _Dp],y
              INFOINDEX
              tax
              lda     abs:.near (mobjinfo+OFS_MI_SEESOUND),x
              beq     1$
              jsl     long:S_StartSound
1$:           jsr     .kbank thArg
              ldy     ##OFS_MO_TARGET
              lda     .near SP_SRC
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (SP_SRC+2)
              sta     [.tiny _Dp],y
              rts

;;; thSpeed: X:C = mobjinfo[SP_TH->type].speed. _Dp[0-3] stays.
thSpeed:      pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              jsr     .kbank thArg
              ldy     ##OFS_MO_TYPE
              lda     [.tiny _Dp],y
              INFOINDEX
              tax
              ply
              sty     dp:.tiny _Dp
              ply
              sty     dp:.tiny (_Dp+2)
              lda     abs:.near (mobjinfo+OFS_MI_SPEED+2),x
              pha
              lda     abs:.near (mobjinfo+OFS_MI_SPEED),x
              plx
              rts

;;; destDelta: X:C = dest->x - source->x, _Dp[0-3] = dest->y - source->y.
destDelta:    lda     .near SP_DEST
              sta     dp:.tiny (_Dp+4)
              lda     .near (SP_DEST+2)
              sta     dp:.tiny (_Dp+6)
              jsr     .kbank srcArg
              ldy     ##OFS_MO_Y
              lda     [.tiny (_Dp+4)],y
              sec
              sbc     [.tiny _Dp],y
              sta     .near SP_T
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sbc     [.tiny _Dp],y
              sta     .near (SP_T+2)
              ldy     ##OFS_MO_X
              lda     [.tiny (_Dp+4)],y
              sec
              sbc     [.tiny _Dp],y
              pha
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sbc     [.tiny _Dp],y
              tax
              lda     .near SP_T
              sta     dp:.tiny _Dp
              lda     .near (SP_T+2)
              sta     dp:.tiny (_Dp+2)
              pla
              rts

;;; angleMom: SP_TH->angle = SP_AN; momx, momy = FixedMulAngle(speed,
;;; finecosine / finesine(SP_AN >> ANGLETOFINESHIFT)).
angleMom:     jsr     .kbank thArg
              ldy     ##OFS_MO_ANGLE
              lda     .near SP_AN
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (SP_AN+2)
              sta     [.tiny _Dp],y
              lsr     a
              lsr     a
              lsr     a
              pha
              jsl     long:finecosine
              ldy     ##OFS_MO_MOMX
              jsr     .kbank speedMom
              pla
              jsl     long:finesine
              ldy     ##OFS_MO_MOMY
              ;; fall into speedMom

;;; speedMom: the fixed_t at offset Y of SP_TH = FixedMulAngle(speed, X:C).
speedMom:     phy
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              jsr     .kbank thSpeed
              jsl     long:FixedMulAngle
              pha
              jsr     .kbank thArg
              pla
              ply
              sta     [.tiny _Dp],y
              iny
              iny
              txa
              sta     [.tiny _Dp],y
              rts

;;; checkMissile: P_CheckMissileSpawn(SP_TH): tics noise, half a move
;;; forward, and for a missile P_TryMove there, else it explodes. The
;;; thing stays on the stack over P_TryMove (which runs game logic).
checkMissile: jsr     .kbank ticsNoise
              ldy     ##OFS_MO_MOMX         ; x += momx >> 1, y, z the same
              ldx     ##OFS_MO_X
              jsr     .kbank halfMom
              ldy     ##OFS_MO_MOMY
              ldx     ##OFS_MO_Y
              jsr     .kbank halfMom
              ldy     ##OFS_MO_MOMZ
              ldx     ##OFS_MO_Z
              jsr     .kbank halfMom
              ldy     ##(OFS_MO_FLAGS+2)    ; not a missile: done
              lda     [.tiny _Dp],y
              and     ##CONST_MF_MISSILE_HI
              beq     9$
              pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              ldy     ##OFS_MO_Y            ; P_TryMove(th, th->x, th->y)
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
              jsl     long:P_TryMove
              tay
              pla
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
              tya
              bne     9$
              jsl     long:P_ExplodeMissile
9$:           rts

;;; halfMom: the fixed_t at offset X of the thing _Dp[0-3] += the one at
;;; offset Y >> 1 (arithmetic).
halfMom:      stx     .near SP_T
              iny
              iny
              lda     [.tiny _Dp],y
              cmp     ##0x8000
              ror     a
              sta     .near (SP_T+2)
              dey
              dey
              lda     [.tiny _Dp],y
              ror     a
              ldy     .near SP_T
              clc
              adc     [.tiny _Dp],y
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (SP_T+2)
              adc     [.tiny _Dp],y
              sta     [.tiny _Dp],y
              rts

;;; ---------------------------------------------------------------------------
;;; void P_SpawnMapThing(const mapthing_t __far* mthing)   In: _Dp[0-3].
;;; The player start (type 1) spawns the player; another thing of the skill
;;; level spawns with random tics, counted for the intermission.
;;; ---------------------------------------------------------------------------
              .public P_SpawnMapThing
P_SpawnMapThing:
              lda     dp:.tiny _Dp
              sta     .near SP_MT
              lda     dp:.tiny (_Dp+2)
              sta     .near (SP_MT+2)
              ldy     ##OFS_MT_TYPE         ; the player
              lda     [.tiny _Dp],y
              cmp     ##1
              bne     1$
              brl     spawnPlayer
1$:           ldy     ##OFS_MT_OPTIONS      ; the skill flags: easy, hard, normal
              lda     [.tiny _Dp],y
              ldx     .near _g_gameskill
              cpx     ##CONST_SK_EASY
              bcs     2$
              and     ##MTF_EASY            ; (baby, easy)
              bra     4$
2$:           beq     21$
              cpx     ##CONST_SK_HARD
              bcc     3$
              and     ##MTF_HARD            ; (hard, nightmare)
              bra     4$
21$:          and     ##MTF_EASY
              bra     4$
3$:           and     ##MTF_NORMAL
4$:           bne     5$
              rtl
5$:           ldy     ##OFS_MT_TYPE         ; i = P_FindDoomedNum(type)
              lda     [.tiny _Dp],y
              ldx     ##0
              ldy     ##CONST_NUMMOBJTYPES
6$:           cmp     abs:.near (mobjinfo+OFS_MI_DOOMEDNUM),x
              beq     7$
              pha
              txa
              clc
              adc     ##INFO_SIZE
              tax
              pla
              dey
              bne     6$
              pha                           ; I_Error("... %i", type)
              lda     ##.word0 fdnErr
              sta     dp:.tiny _Dp
              lda     ##.word2 fdnErr
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
7$:           tya                           ; i = NUMMOBJTYPES - Y
              eor     ##0xffff
              sec
              adc     ##CONST_NUMMOBJTYPES
              pha                           ; P_SpawnMobj(x << 16, y << 16, ONFLOORZ, i)
              jsr     .kbank mtArg
              ldy     ##OFS_MT_X
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_MT_Y
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+2)
              stz     dp:.tiny _Dp
              lda     ##CONST_ONFLOORZ_LO
              sta     dp:.tiny (_Dp+4)
              lda     ##CONST_ONFLOORZ_HI
              sta     dp:.tiny (_Dp+6)
              lda     ##0
              jsl     long:P_SpawnMobj
              ply
              sta     .near SP_TH
              stx     .near (SP_TH+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##OFS_MO_TICS         ; tics > 0: 1 + P_Random() % tics
              lda     [.tiny _Dp],y
              beq     8$
              bmi     8$
              pha
              jsl     long:P_Random
              plx
              jsl     long:_Mod16
              inc     a
              pha
              jsr     .kbank thArg
              pla
              ldy     ##OFS_MO_TICS
              sta     [.tiny _Dp],y
8$:           ldy     ##(OFS_MO_FLAGS+2)    ; the counts: kills, items
              lda     [.tiny _Dp],y
              and     ##CONST_MF_COUNTKILL_HI
              beq     9$
              inc     .near _g_totalkills
              bne     9$
              inc     .near (_g_totalkills+2)
9$:           lda     [.tiny _Dp],y
              and     ##CONST_MF_COUNTITEM_HI
              beq     10$
              inc     .near _g_totalitems
              bne     10$
              inc     .near (_g_totalitems+2)
10$:          jsr     .kbank mtAngle        ; angle = ANG45 * mthing->angle
              pha
              jsr     .kbank thArg
              ldy     ##OFS_MO_ANGLE
              lda     ##0
              sta     [.tiny _Dp],y
              iny
              iny
              pla
              sta     [.tiny _Dp],y
              jsr     .kbank mtArg          ; an ambush: MF_AMBUSH
              ldy     ##OFS_MT_OPTIONS
              lda     [.tiny _Dp],y
              and     ##MTF_AMBUSH
              beq     11$
              jsr     .kbank thArg
              ldy     ##OFS_MO_FLAGS
              lda     [.tiny _Dp],y
              ora     ##CONST_MF_AMBUSH_LO
              sta     [.tiny _Dp],y
11$:          rtl

;;; mtArg: _Dp[0-3] = SP_MT. mtAngle: C = the high word of ANG45 *
;;; mthing->angle (the low word is 0).
mtArg:        lda     .near SP_MT
              sta     dp:.tiny _Dp
              lda     .near (SP_MT+2)
              sta     dp:.tiny (_Dp+2)
              rts
mtAngle:      jsr     .kbank mtArg
              ldy     ##OFS_MT_ANGLE
              lda     [.tiny _Dp],y
              and     ##7
              xba
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              rts

;;; spawnPlayer: P_SpawnPlayer(mthing->x, mthing->y, mthing->angle): the
;;; mobj of the player (reborn first after a death) with a new status.
spawnPlayer:  lda     .near (_g_player+OFS_PL_PLAYERSTATE)
              cmp     ##CONST_PST_REBORN
              bne     1$
              jsl     long:G_PlayerReborn
1$:           pea     #CONST_MT_PLAYER      ; P_SpawnMobj(x << 16, y << 16, ONFLOORZ, MT_PLAYER)
              jsr     .kbank mtArg
              ldy     ##OFS_MT_X
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_MT_Y
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+2)
              stz     dp:.tiny _Dp
              lda     ##CONST_ONFLOORZ_LO
              sta     dp:.tiny (_Dp+4)
              lda     ##CONST_ONFLOORZ_HI
              sta     dp:.tiny (_Dp+6)
              lda     ##0
              jsl     long:P_SpawnMobj
              ply
              sta     .near SP_TH
              stx     .near (SP_TH+2)
              sta     .near (_g_player+OFS_PL_MO) ; p->mo = mobj
              stx     .near (_g_player+OFS_PL_MO+2)
              jsr     .kbank mtAngle        ; angle = ANG45 * playerangle
              pha
              jsr     .kbank thArg
              ldy     ##OFS_MO_ANGLE
              lda     ##0
              sta     [.tiny _Dp],y
              iny
              iny
              pla
              sta     [.tiny _Dp],y
              lda     .near (_g_player+OFS_PL_HEALTH) ; health = p->health
              ldy     ##OFS_MO_HEALTH
              sta     [.tiny _Dp],y
              lda     ##CONST_PST_LIVE      ; the player: live, a new status
              sta     .near (_g_player+OFS_PL_PLAYERSTATE)
              stz     .near (_g_player+OFS_PL_REFIRE)
              stz     .near (_g_player+OFS_PL_MESSAGE)
              stz     .near (_g_player+OFS_PL_MESSAGE+2)
              stz     .near (_g_player+OFS_PL_DAMAGECOUNT)
              stz     .near (_g_player+OFS_PL_BONUSCOUNT)
              stz     .near (_g_player+OFS_PL_EXTRALIGHT)
              stz     .near (_g_player+OFS_PL_FIXEDCOLORMAP)
              lda     ##CONST_VIEWHEIGHT_LO
              sta     .near (_g_player+OFS_PL_VIEWHEIGHT)
              lda     ##CONST_VIEWHEIGHT_HI
              sta     .near (_g_player+OFS_PL_VIEWHEIGHT+2)
              stz     .near (_g_player+OFS_PL_MOMX)
              stz     .near (_g_player+OFS_PL_MOMX+2)
              stz     .near (_g_player+OFS_PL_MOMY)
              stz     .near (_g_player+OFS_PL_MOMY+2)
              lda     ##.near _g_player     ; P_SetupPsprites(p)
              sta     dp:.tiny _Dp
              lda     ##.word2 _g_player
              sta     dp:.tiny (_Dp+2)
              jmp     long:P_SetupPsprites

;;; ---------------------------------------------------------------------------
;;; void P_NightmareRespawn(mobj_t __far* mobj)      In: _Dp[0-3].
;;; A dead monster (nightmare) comes back at the place of its death if
;;; there is space, with teleport fog at both places.
;;; ---------------------------------------------------------------------------
              .public P_NightmareRespawn
P_NightmareRespawn:
              lda     dp:.tiny _Dp
              sta     .near NR_MO
              lda     dp:.tiny (_Dp+2)
              sta     .near (NR_MO+2)
              ldy     ##OFS_MO_X            ; x = y = 0: no
              lda     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              bne     1$
              rtl
1$:           jsr     .kbank nmXY           ; P_CheckPosition(mobj, x, y)
              lda     .near SP_Y
              sta     dp:.tiny (_Dp+4)
              lda     .near (SP_Y+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near SP_X
              ldx     .near (SP_X+2)
              jsl     long:P_CheckPosition
              cmp     ##0
              bne     2$
              rtl
2$:           jsr     .kbank nmArg          ; the fog at the old spot, on the
              ldy     ##(OFS_MO_SUBSECTOR+2) ; floor of its sector
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_MO_SUBSECTOR
              lda     [.tiny _Dp],y
              jsr     .kbank subFloor
              jsr     .kbank nmXY
              jsr     .kbank fog
              jsr     .kbank nmXY           ; the fog at the new spot (the same
              lda     .near SP_Y            ; x, y), on the floor of the sector
              sta     dp:.tiny _Dp          ; at x, y
              lda     .near (SP_Y+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near SP_X
              ldx     .near (SP_X+2)
              jsl     long:R_PointInSubsector
              jsr     .kbank subFloor
              jsr     .kbank nmXY
              jsr     .kbank fog
              jsr     .kbank nmXY           ; mo = P_SpawnMobj(x, y, ONFLOORZ, mobj->type)
              lda     ##CONST_ONFLOORZ_LO
              sta     .near SP_Z
              lda     ##CONST_ONFLOORZ_HI
              sta     .near (SP_Z+2)
              jsr     .kbank nmArg
              ldy     ##OFS_MO_TYPE
              lda     [.tiny _Dp],y
              jsr     .kbank spawnXYZ
              jsr     .kbank nmArg          ; angle = mobj->angle, reactiontime 18
              ldy     ##(OFS_MO_ANGLE+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_MO_ANGLE
              lda     [.tiny _Dp],y
              pha
              jsr     .kbank thArg
              pla
              sta     [.tiny _Dp],y
              iny
              iny
              txa
              sta     [.tiny _Dp],y
              lda     ##18
              ldy     ##OFS_MO_REACTIONTIME
              sta     [.tiny _Dp],y
              jsr     .kbank nmArg          ; P_RemoveMobj(mobj)
              jmp     long:P_RemoveMobj

;;; nmArg: _Dp[0-3] = NR_MO. nmXY: SP_X, SP_Y = its x, y; _Dp[0-3] = it.
nmArg:        lda     .near NR_MO
              sta     dp:.tiny _Dp
              lda     .near (NR_MO+2)
              sta     dp:.tiny (_Dp+2)
              rts
nmXY:         jsr     .kbank nmArg
              ldy     ##OFS_MO_X
              ldx     ##0
1$:           lda     [.tiny _Dp],y
              sta     abs:.near SP_X,x
              iny
              iny
              inx
              inx
              cpx     ##8
              bcc     1$
              rts

;;; subFloor: SP_Z = the floor of the sector of the subsector X:C.
subFloor:     sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              ldy     ##(OFS_SUB_SECTOR+2)
              lda     [.tiny (_Dp+4)],y
              tax
              ldy     ##OFS_SUB_SECTOR
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              ldy     ##OFS_SEC_FLOORHEIGHT
              lda     [.tiny (_Dp+4)],y
              sta     .near SP_Z
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sta     .near (SP_Z+2)
              rts

;;; fog: S_StartSound(P_SpawnMobj(SP_X, SP_Y, SP_Z, MT_TFOG), sfx_telept).
fog:          lda     ##CONST_MT_TFOG
              jsr     .kbank spawnXYZ
              lda     ##CONST_SFX_TELEPT
              jsl     long:S_StartSound
              rts

;;; ---------------------------------------------------------------------------
;;; The pool of mobjs (_g_thingPool, one for each map thing): TP_BITS has a
;;; bit for each, 1 when it is free, so poolTake reads a word for 16 mobjs
;;; No word above TP_HW contains a free slot. The
;;; pool has at most TP_MAX mobjs. These run in the game tic (logiccode,
;;; small fragments).
;;; ---------------------------------------------------------------------------

;;; poolTake: _Dp[0-3] = the free mobj of the pool with the highest index,
;;; out of TP_BITS; C = 1 when none is free.
              .section logiccode, text
poolTake:     ldx     .near TP_HW           ; a word with a free one
              bmi     9$
1$:           lda     long:TP_BITS,x
              bne     2$
              dex
              dex
              bpl     1$
              stx     .near TP_HW           ; (none)
9$:           sec
              rtl
2$:           stx     .near TP_HW
              tay                           ; p: its highest bit (the mobj with
              ldx     ##0                   ;   the highest index), by halves
              cmp     ##0x0100
              bcc     3$
              xba
              ldx     ##8
3$:           and     ##0x00ff
              cmp     ##0x0010
              bcc     4$
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              inx
              inx
              inx
              inx
4$:           cmp     ##4
              bcc     5$
              lsr     a
              lsr     a
              inx
              inx
5$:           cmp     ##2
              bcc     6$
              inx
6$:           txa
              sta     dp:.tiny (_Dp+2)
              asl     a
              tax
              tya                           ; that bit off
              eor     long:TP_MASK,x
              ldx     .near TP_HW
              sta     long:TP_BITS,x
              txa                           ; i = 8 X + p
              asl     a
              asl     a
              asl     a
              adc     dp:.tiny (_Dp+2)      ; (carry clear)
              asl     a                     ; the mobj: pool + 120 i, 128 i -
              asl     a                     ;   8 i
              asl     a
              sta     dp:.tiny _Dp
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny _Dp
              clc
              adc     .near _g_thingPool
              sta     dp:.tiny _Dp
              lda     .near (_g_thingPool+2)
              sta     dp:.tiny (_Dp+2)
              clc
              rtl

;;; poolFree: the mobj of the pool at _Dp[0-3] (MT_NOTHING now) into
;;; TP_BITS, for P_RemoveThingDelayed (src/iigs/p_think65.s). Its index i
;;; = j / 15 for j = its offset / 8 (= 15 i) is the high word of (j + 1)
;;; * 4369 (15 * 4369 = 65535).
              .public poolFree
              .section logiccode, text
poolFree:     lda     dp:.tiny _Dp
              sec
              sbc     .near _g_thingPool
              lsr     a
              lsr     a
              lsr     a
              inc     a
              sta     dp:.tiny MA
              lda     ##4369
              sta     dp:.tiny MB
              jsl     long:umul16
              lda     dp:.tiny (MR+2)       ; i
              pha
              and     ##15                  ; its bit on: TP_MASK[2 (i & 15)] in
              asl     a                     ;   word i >> 4 (X = 2 * it)
              tax
              lda     long:TP_MASK,x
              tay
              pla
              lsr     a
              lsr     a
              lsr     a
              and     ##0xfffe
              tax
              tya
              ora     long:TP_BITS,x
              sta     long:TP_BITS,x
              lda     .near TP_HW           ; TP_HW = max(TP_HW, X)
              bmi     3$
              cpx     .near TP_HW
              bcc     4$
3$:           stx     .near TP_HW
4$:           rtl
tpErr:        .asciz  "P_LoadThings: too many things" ; (poolInit)

;;; poolInit: for P_LoadThings (src/iigs/p_setup65.s): all mobjs of the
;;; pool at _Dp[0-3] get type MT_NOTHING and are free in TP_BITS; more than
;;; TP_MAX: I_Error. Cold code (a level load; in logiccode it would move
;;; the fragments of the traces).
              .public poolInit
              .section coldcode, text
poolInit:     lda     .near _g_thingPoolSize
              cmp     ##(TP_MAX + 1)
              bcc     1$
              lda     ##.word0 tpErr
              sta     dp:.tiny _Dp
              lda     ##.word2 tpErr
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
1$:           ldx     ##0                   ; TP_MASK: 1 << k
              lda     ##1
11$:          sta     long:TP_MASK,x
              asl     a
              inx
              inx
              cpx     ##32
              bcc     11$
              ldy     ##OFS_MO_TYPE         ; each mobj: MT_NOTHING
              ldx     .near _g_thingPoolSize
              beq     3$
2$:           lda     ##CONST_MT_NOTHING
              sta     [.tiny _Dp],y
              tya
              clc
              adc     ##SIZEOF_MO
              tay
              dex
              bne     2$
3$:           lda     .near _g_thingPoolSize ; TP_BITS: mobjs 0 .. n - 1 free,
              ldx     ##0                   ;   16 in each full word
4$:           cmp     ##16
              bcc     5$
              sbc     ##16                  ; (carry set)
              tay
              lda     ##0xffff
              sta     long:TP_BITS,x
              tya
              inx
              inx
              bra     4$
5$:           tay                           ; the rest: (1 << r) - 1
              lda     ##0
6$:           dey
              bmi     7$
              sec
              rol     a
              bra     6$
7$:           sta     long:TP_BITS,x        ; then none up to TP_MAX
8$:           inx
              inx
              cpx     ##(TP_MAX / 8)
              bcs     9$
              lda     ##0
              sta     long:TP_BITS,x
              bra     8$
9$:           lda     .near _g_thingPoolSize ; TP_HW = 2 * ((n - 1) >> 4), < 0:
              dec     a                     ;   none
              bmi     10$
              lsr     a
              lsr     a
              lsr     a
              and     ##0xfffe
10$:          sta     .near TP_HW
              rtl
