;;; Hitscan aiming and damage along a trace.
;;;
;;; P_AimLineAttack uses PTR_AimTraverse to narrow the visible vertical range
;;; and select a target. P_LineAttack uses PTR_ShootTraverse to apply the shot
;;; to the first blocking wall or actor. P_ShootSpecialLine handles shootable
;;; line specials; FixedMul3 and P_IsAttackRangeMeleeRange supply shared math.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"

              .extern _Dp, _g_linetarget, _g_trace, _g_openbottom, _g_opentop
              .extern _g_sides, _g_sectors, skyflatnum
              .extern P_PathTraverse, P_LineOpening, FixedMul, FixedApproxDiv
              .extern FixedReciprocal, finesine, finecosine, _Mul32
              .extern P_SpawnPuff, P_SpawnBlood, P_DamageMobj, P_MobjIsPlayer
              .extern P_CheckTag, EV_DoDoor, P_ChangeSwitchTexture
              .extern P_CheckSight, P_BlockThingsIterator, _g_bmaporgx, _g_bmaporgy
              .extern MA, MB

TOPSLOPE      .equ    40960           ; 100 * FRACUNIT / 160

              .section znear, bss
AT_SHOOT:     .space  4               ; shootthing
AT_Z:         .space  4               ; shootz
AT_DAMAGE:    .space  2               ; la_damage
AT_RANGE:     .space  4               ; attackrange
AT_TOP:       .space  4               ; topslope
AT_BOT:       .space  4               ; bottomslope
AT_AIM:       .space  4               ; aimslope
AT_T1:        .space  4               ; the attacker
AT_X2:        .space  4               ; the end of the trace
AT_Y2:        .space  4
AT_IN:        .space  4               ; the intercept of the traverser
AT_LI:        .space  4               ; its line or thing
AT_DIST:      .space  4
AT_TTOP:      .space  4               ; thingtopslope, thingbottomslope
AT_TBOT:      .space  4
AT_FRAC:      .space  4               ; the puff position
AT_PX:        .space  4
AT_PY:        .space  4
AT_PZ:        .space  4
AT_FS:        .space  4               ; the front and back sectors
AT_BS:        .space  4
AT_T:         .space  4
AT_BSPOT:     .space  4               ; P_RadiusAttack: bombspot
AT_BSOURCE:   .space  4               ;   bombsource
AT_BDAMAGE:   .space  2               ;   bombdamage
AT_BDIST:     .space  2               ;   the distance of the thing
AT_BTHING:    .space  4               ;   the thing

;;; Signed 32-bit a < b: lda a.lo / cmp b.lo / lda a.hi / SLT32 b.hi / bmi
SLT32         .macro  op
              sbc     \op
              bvc     1$
              eor     ##0x8000
1$:
              .endm

;;; C = C >> 7, arithmetic (the high word of a fixed_t >> MAPBLOCKSHIFT).
SHR7          .macro
              asl     a
              xba
              and     ##0x00ff
              bcc     1$
              ora     ##0xff00
1$:
              .endm

;;; ---------------------------------------------------------------------------
;;; void P_LineAttack(mobj_t __far* t1, angle_t angle, fixed_t distance,
;;;                   fixed_t slope, int16_t damage)
;;; In: _Dp[0-3] = t1, X:C = angle, _Dp[4-7] = distance, on the stack slope
;;; and damage (the caller removes them).
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public P_LineAttack
P_LineAttack: pha
              lda     6,s                   ; aimslope = slope
              sta     .near AT_AIM
              lda     8,s
              sta     .near (AT_AIM+2)
              lda     10,s                  ; la_damage = damage
              sta     .near AT_DAMAGE
              pla
              jsr     .kbank traceSetup
              lda     ##.word0 PTR_ShootTraverse
              ldx     ##.word2 PTR_ShootTraverse
              jsr     .kbank traceRun
              rtl

;;; traceSetup: for t1 (_Dp[0-3]), angle (X:C) and distance (_Dp[4-7]):
;;; shootthing, the end (x2, y2) = t1 + (distance >> 16) * (cos, sin) of the
;;; fine angle, shootz = z + height / 2 + 8 * FRACUNIT, attackrange.
traceSetup:   txa                           ; the fine angle: angle >> 19
              lsr     a
              lsr     a
              lsr     a
              pha
              lda     dp:.tiny _Dp          ; shootthing = t1
              sta     .near AT_SHOOT
              sta     .near AT_T1
              lda     dp:.tiny (_Dp+2)
              sta     .near (AT_SHOOT+2)
              sta     .near (AT_T1+2)
              lda     dp:.tiny (_Dp+4)      ; attackrange = distance
              sta     .near AT_RANGE
              lda     dp:.tiny (_Dp+6)
              sta     .near (AT_RANGE+2)
              lda     1,s                   ; x2 = t1->x + (distance >> 16) * finecosine(an)
              jsl     long:finecosine
              ldy     ##OFS_MO_X
              jsr     .kbank endPoint
              sta     .near AT_X2
              stx     .near (AT_X2+2)
              pla                           ; y2 = t1->y + (distance >> 16) * finesine(an)
              jsl     long:finesine
              ldy     ##OFS_MO_Y
              jsr     .kbank endPoint
              sta     .near AT_Y2
              stx     .near (AT_Y2+2)
              lda     .near AT_T1           ; shootz = z + (height >> 1) + 8 * FRACUNIT
              sta     dp:.tiny _Dp
              lda     .near (AT_T1+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_MO_HEIGHT+2)
              lda     [.tiny _Dp],y
              cmp     ##0x8000
              ror     a
              sta     .near (AT_Z+2)
              ldy     ##OFS_MO_HEIGHT
              lda     [.tiny _Dp],y
              ror     a
              clc
              ldy     ##OFS_MO_Z
              adc     [.tiny _Dp],y
              sta     .near AT_Z
              lda     .near (AT_Z+2)
              ldy     ##(OFS_MO_Z+2)
              adc     [.tiny _Dp],y
              clc
              adc     ##8
              sta     .near (AT_Z+2)
              rts

;;; endPoint: X:C = the coordinate at offset Y of t1 + (attackrange >> 16) *
;;; X:C, the low 32 bits.
endPoint:     sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near (AT_RANGE+2)    ; distance >> FRACBITS, sign extended
              sta     dp:.tiny (_Dp+4)
              ldx     ##0
              cmp     ##0
              bpl     1$
              dex
1$:           stx     dp:.tiny (_Dp+6)
              phy
              jsl     long:_Mul32
              ply
              pha
              lda     .near AT_T1
              sta     dp:.tiny _Dp
              lda     .near (AT_T1+2)
              sta     dp:.tiny (_Dp+2)
              pla
              clc
              adc     [.tiny _Dp],y
              pha
              txa
              iny
              iny
              adc     [.tiny _Dp],y
              tax
              pla
              rts

;;; traceRun: P_PathTraverse(t1->x, t1->y, x2, y2, PT_ADDLINES | PT_ADDTHINGS,
;;; the traverser X:C).
traceRun:     phx                           ; trav
              pha
              pea     #(CONST_PT_ADDLINES | CONST_PT_ADDTHINGS)
              lda     .near (AT_Y2+2)       ; y2
              pha
              lda     .near AT_Y2
              pha
              lda     .near AT_X2           ; x2
              sta     dp:.tiny (_Dp+4)
              lda     .near (AT_X2+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near AT_T1
              sta     dp:.tiny _Dp
              lda     .near (AT_T1+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_MO_X+2)        ; t1->x
              lda     [.tiny _Dp],y
              pha
              ldy     ##OFS_MO_Y            ; t1->y
              lda     [.tiny _Dp],y
              tax
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (AT_T+2)
              stx     .near AT_T
              ldy     ##OFS_MO_X
              lda     [.tiny _Dp],y
              ldx     .near AT_T
              stx     dp:.tiny _Dp
              ldx     .near (AT_T+2)
              stx     dp:.tiny (_Dp+2)
              plx
              jsl     long:P_PathTraverse
              pla
              pla
              pla
              pla
              pla
              rts

go:           lda     ##1
              rtl

;;; ---------------------------------------------------------------------------
;;; boolean PTR_ShootTraverse(intercept_t* in)
;;; ---------------------------------------------------------------------------
              .public PTR_ShootTraverse
PTR_ShootTraverse:
              jsr     .kbank loadIntercept
              bne     1$
              brl     30$                   ; a thing
1$:           ldy     ##OFS_LINE_SPECIAL    ; a special line: its action
              lda     [.tiny (_Dp+4)],y
              beq     2$
              jsr     .kbank shootSpecial
              lda     .near AT_LI           ; (_Dp[4-7] again: the line)
              sta     dp:.tiny (_Dp+4)
              lda     .near (AT_LI+2)
              sta     dp:.tiny (_Dp+6)
2$:           ldy     ##OFS_LINE_FLAGS      ; a two sided line: through the opening?
              lda     [.tiny (_Dp+4)],y
              and     ##CONST_ML_TWOSIDED
              beq     10$
              jsr     .kbank opening
              lda     .near AT_IN           ; t = FixedMul3(aimslope, frac, range) + shootz
              sta     dp:.tiny _Dp
              lda     .near (AT_IN+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_IC_FRAC
              lda     [.tiny _Dp],y
              tax
              iny
              iny
              lda     [.tiny _Dp],y
              jsr     .kbank mul3           ; (C = frac high, X = frac low)
              clc
              adc     .near AT_Z
              sta     .near AT_T
              txa
              adc     .near (AT_Z+2)
              sta     .near (AT_T+2)
              jsr     .kbank lineSectors
              ldy     ##OFS_SEC_FLOORHEIGHT ; (floors equal || openbottom <= t)
              jsr     .kbank sectorsDiffer
              beq     5$
              lda     .near AT_T            ; openbottom <= t: !(t < openbottom)
              cmp     .near _g_openbottom
              lda     .near (AT_T+2)
              SLT32   .near (_g_openbottom+2)
              bmi     10$
5$:           ldy     ##OFS_SEC_CEILINGHEIGHT ; && (ceilings equal || opentop >= t)
              jsr     .kbank sectorsDiffer
              beq     6$
              lda     .near _g_opentop      ; opentop >= t: !(opentop < t)
              cmp     .near AT_T
              lda     .near (_g_opentop+2)
              SLT32   .near (AT_T+2)
              bmi     10$
6$:           brl     go                    ; the shot goes on

              ;; the line is hit: a little closer
10$:          lda     ##4                   ; frac = in->frac - 4 * FixedReciprocal(range)
              jsr     .kbank puffPos
              jsr     .kbank lineSectors
              lda     .near AT_FS           ; the front ceiling is the sky
              sta     dp:.tiny _Dp
              lda     .near (AT_FS+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_SEC_CEILINGPIC
              lda     [.tiny _Dp],y
              cmp     .near skyflatnum
              bne     20$
              ldy     ##OFS_SEC_CEILINGHEIGHT ; into the sky: no puff
              jsr     .kbank ceilBelowZ
              bpl     11$
              brl     stop
11$:          lda     .near AT_BS           ; a sky hack wall: the back ceiling
              ora     .near (AT_BS+2)
              beq     20$
              lda     .near AT_BS
              sta     dp:.tiny _Dp
              lda     .near (AT_BS+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_SEC_CEILINGPIC
              lda     [.tiny _Dp],y
              cmp     .near skyflatnum
              bne     20$
              ldy     ##OFS_SEC_CEILINGHEIGHT ; back ceilingheight < z: no puff
              jsr     .kbank ceilBelowZ
              bpl     20$
              brl     stop
20$:          jsr     .kbank spawnPuff
              brl     stop

              ;; a thing
30$:          jsr     .kbank shootable
              bcc     31$
              brl     go
31$:          jsr     .kbank rangeDist
              jsr     .kbank thingTopRaw    ; thingtopslope < aimslope: over it
              lda     .near AT_TTOP
              cmp     .near AT_AIM
              lda     .near (AT_TTOP+2)
              SLT32   .near (AT_AIM+2)
              bpl     32$
              brl     go
32$:          jsr     .kbank thingBottomRaw ; thingbottomslope > aimslope: under it
              lda     .near AT_AIM
              cmp     .near AT_TBOT
              lda     .near (AT_AIM+2)
              SLT32   .near (AT_TBOT+2)
              bpl     33$
              brl     go
33$:          lda     ##10                  ; frac = in->frac - 10 * FixedReciprocal(range)
              jsr     .kbank puffPos
              lda     .near AT_LI           ; MF_NOBLOOD: a puff, else blood
              sta     dp:.tiny _Dp
              lda     .near (AT_LI+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_MO_FLAGS+2)
              lda     [.tiny _Dp],y
              and     ##CONST_MF_NOBLOOD_HI
              beq     34$
              jsr     .kbank spawnPuff
              bra     35$
34$:          lda     .near AT_DAMAGE       ; P_SpawnBlood(x, y, z, la_damage)
              pha
              jsr     .kbank puffArgs
              jsl     long:P_SpawnBlood
              pla
35$:          lda     .near AT_DAMAGE       ; P_DamageMobj(th, shootthing, shootthing, damage)
              bne     36$
              brl     stop
36$:          lda     .near (AT_SHOOT+2)
              pha
              lda     .near AT_SHOOT
              pha
              sta     dp:.tiny (_Dp+4)
              lda     .near (AT_SHOOT+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near AT_LI
              sta     dp:.tiny _Dp
              lda     .near (AT_LI+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near AT_DAMAGE
              jsl     long:P_DamageMobj
              pla
              pla
              brl     stop

;;; loadIntercept: AT_IN = in (_Dp[0-3]), AT_LI = in->d, also in _Dp[4-7].
;;; C = in->isaline, Z set for a thing.
loadIntercept:
              lda     dp:.tiny _Dp
              sta     .near AT_IN
              lda     dp:.tiny (_Dp+2)
              sta     .near (AT_IN+2)
              ldy     ##OFS_IC_D
              lda     [.tiny _Dp],y
              sta     .near AT_LI
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (AT_LI+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_IC_ISALINE
              lda     [.tiny _Dp],y
              rts

;;; opening: P_LineOpening(the line AT_LI).
opening:      lda     .near AT_LI
              sta     dp:.tiny _Dp
              lda     .near (AT_LI+2)
              sta     dp:.tiny (_Dp+2)
              jsl     long:P_LineOpening
              rts

;;; rangeDist: AT_DIST = FixedMul(attackrange, in->frac).
rangeDist:    lda     .near AT_IN
              sta     dp:.tiny _Dp
              lda     .near (AT_IN+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_IC_FRAC
              lda     [.tiny _Dp],y
              tax
              iny
              iny
              lda     [.tiny _Dp],y
              jsr     .kbank rangeMul
              sta     .near AT_DIST
              stx     .near (AT_DIST+2)
              rts

;;; rangeMul: X:C = FixedMul(attackrange, v), C = the high word of v, X its
;;; low word. For attackrange 1 << 27 (MISSILERANGE) or 1 << 26 (the aim of
;;; the player) the product is a multiple of FRACUNIT: v << 11 or v << 10
;;; (the low 32 bits, as FixedMul). MA, MB are scratch.
rangeMul:     ldy     .near AT_RANGE
              bne     9$
              ldy     ##3                   ; the bits after a byte
              pha
              lda     .near (AT_RANGE+2)
              cmp     ##0x0800
              beq     1$
              dey
              cmp     ##0x0400
              beq     1$
              pla
9$:           sta     dp:.tiny (_Dp+2)      ; else FixedMul(attackrange, v)
              stx     dp:.tiny _Dp
              lda     .near AT_RANGE
              ldx     .near (AT_RANGE+2)
              jsl     long:FixedMul
              rts
1$:           pla                           ; << 8: the high word hi << 8 |
              stx     dp:.tiny MA           ;   lo >> 8, the low word lo << 8
              xba
              and     ##0xff00
              sta     dp:.tiny MB
              lda     dp:.tiny (MA+1)
              and     ##0x00ff
              ora     dp:.tiny MB
              tax
              lda     dp:.tiny MA
              xba
              and     ##0xff00
              sta     dp:.tiny MA
              txa
2$:           asl     dp:.tiny MA           ; then one bit at a time
              rol     a
              dey
              bne     2$
              tax
              lda     dp:.tiny MA
              rts

;;; lineSectors: AT_FS, AT_BS = the front and back (or NULL) sectors of the
;;; line AT_LI (which has a front side). The sectors are in the bank of
;;; _g_sectors.
lineSectors:  lda     .near AT_LI
              sta     dp:.tiny (_Dp+4)
              lda     .near (AT_LI+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_LINE_SIDENUM    ; X = &sides[sidenum[0]]
              jsr     .kbank sideAddr
              tax
              ldy     ##(OFS_LINE_SIDENUM+2) ; Y = &sides[sidenum[1]]
              lda     [.tiny (_Dp+4)],y
              cmp     ##0xffff              ; (NO_INDEX: no back sector)
              beq     2$
              jsr     .kbank sideAddr
              tay
              jsr     .kbank sideSectors
              lda     .near (_g_sectors+2)
              bra     3$
2$:           txy                           ; (the front twice)
              jsr     .kbank sideSectors
              ldy     ##0
              tya
3$:           sty     .near AT_BS
              sta     .near (AT_BS+2)
              rts

;;; sideAddr: C = &sides[[_Dp+4] + Y]: 14 * n as (8n - n) * 2.
sideAddr:     lda     [.tiny (_Dp+4)],y
              asl     a
              asl     a
              asl     a
              sec
              sbc     [.tiny (_Dp+4)],y
              asl     a
              clc
              adc     .near _g_sides
              rts

;;; sideSectors: AT_FS = the sector of the side at X, Y = the low word of
;;; the sector of the side at Y (DBR = the sides for them).
sideSectors:  phb
              lda     .near (_g_sides+1)    ; DBR = the sides (the high byte; no
              pha                           ;   SEP and REP)
              plb
              plb
              lda     abs:OFS_SIDE_SECTOR,y
              tay
              lda     abs:OFS_SIDE_SECTOR,x
              plb
              sta     .near AT_FS
              lda     .near (_g_sectors+2)
              sta     .near (AT_FS+2)
              rts
              .space  3                     ; (the code after keeps its address)

;;; sectorsDiffer: Z clear if the fixed_t at offset Y of the front and back
;;; sectors differ.
sectorsDiffer:
              lda     .near AT_FS
              sta     dp:.tiny _Dp
              lda     .near (AT_FS+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near AT_BS
              sta     dp:.tiny (_Dp+4)
              lda     .near (AT_BS+2)
              sta     dp:.tiny (_Dp+6)
              lda     [.tiny _Dp],y
              cmp     [.tiny (_Dp+4)],y
              bne     9$
              iny
              iny
              lda     [.tiny _Dp],y
              cmp     [.tiny (_Dp+4)],y
9$:           rts

;;; shootable: carry set if the thing AT_LI is the shooter or not
;;; MF_SHOOTABLE (the shot goes on).
shootable:    lda     .near AT_LI
              cmp     .near AT_SHOOT
              bne     1$
              lda     .near (AT_LI+2)
              cmp     .near (AT_SHOOT+2)
              beq     8$
1$:           lda     .near AT_LI
              sta     dp:.tiny _Dp
              lda     .near (AT_LI+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_MO_FLAGS
              lda     [.tiny _Dp],y
              and     ##CONST_MF_SHOOTABLE_LO
              beq     8$
              clc
              rts
8$:           sec
              rts

;;; rawSlope: AT_T = FixedApproxDiv(X:C, dist).
rawSlope:     ldy     .near AT_DIST
              sty     dp:.tiny _Dp
              ldy     .near (AT_DIST+2)
              sty     dp:.tiny (_Dp+2)
              jsl     long:FixedApproxDiv
              sta     .near AT_T
              stx     .near (AT_T+2)
              rts

;;; thingHead: X:C = th->z + th->height - shootz. thingFoot: th->z - shootz.
thingHead:    jsr     .kbank thingPtr
              ldy     ##OFS_MO_Z
              lda     [.tiny _Dp],y
              clc
              ldy     ##OFS_MO_HEIGHT
              adc     [.tiny _Dp],y
              sta     .near AT_T
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_HEIGHT+2)
              adc     [.tiny _Dp],y
              tax
              lda     .near AT_T
              bra     minusZ
thingFoot:    jsr     .kbank thingPtr
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_MO_Z
              lda     [.tiny _Dp],y
minusZ:       sec
              sbc     .near AT_Z
              pha
              txa
              sbc     .near (AT_Z+2)
              tax
              pla
              rts

thingPtr:     lda     .near AT_LI
              sta     dp:.tiny _Dp
              lda     .near (AT_LI+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; mul3: X:C = FixedMul3(aimslope, C:X frac, attackrange) =
;;;   aimslope ? FixedMul(FixedMul(range, frac), aimslope) : 0
;;; (C = the high word of frac, X = its low word).
mul3:         ldy     .near AT_AIM
              bne     1$
              ldy     .near (AT_AIM+2)
              bne     1$
              lda     ##0
              tax
              rts
1$:           jsr     .kbank rangeMul       ; FixedMul(range, frac)
              ldy     .near AT_AIM          ; FixedMul(bc, aimslope)
              sty     dp:.tiny _Dp
              ldy     .near (AT_AIM+2)
              sty     dp:.tiny (_Dp+2)
              jsl     long:FixedMul
              rts

;;; ---------------------------------------------------------------------------
;;; boolean P_IsAttackRangeMeleeRange(void): attackrange == MELEERANGE
;;; ---------------------------------------------------------------------------
              .public P_IsAttackRangeMeleeRange
P_IsAttackRangeMeleeRange:
              lda     .near AT_RANGE
              cmp     ##CONST_MELEERANGE_LO
              bne     1$
              lda     .near (AT_RANGE+2)
              cmp     ##CONST_MELEERANGE_HI
              bne     1$
              lda     ##1
              rtl
1$:           lda     ##0
              rtl

;;; ---------------------------------------------------------------------------
;;; fixed_t P_AimLineAttack(mobj_t __far* t1, angle_t angle, fixed_t distance)
;;; In: _Dp[0-3] = t1, X:C = angle, _Dp[4-7] = distance. Out: X:C.
;;; ---------------------------------------------------------------------------
              .public P_AimLineAttack
P_AimLineAttack:
              jsr     .kbank traceSetup
              lda     ##TOPSLOPE            ; the view angles
              sta     .near AT_TOP
              stz     .near (AT_TOP+2)
              lda     ##(0x10000 - TOPSLOPE)
              sta     .near AT_BOT
              lda     ##0xffff
              sta     .near (AT_BOT+2)
              stz     .near _g_linetarget   ; linetarget = NULL
              stz     .near (_g_linetarget+2)
              lda     ##.word0 PTR_AimTraverse
              ldx     ##.word2 PTR_AimTraverse
              jsr     .kbank traceRun
              lda     .near _g_linetarget   ; linetarget ? aimslope : 0
              ora     .near (_g_linetarget+2)
              beq     1$
              lda     .near AT_AIM
              ldx     .near (AT_AIM+2)
              rtl
1$:           lda     ##0
              tax
              rtl

;;; ---------------------------------------------------------------------------
;;; boolean PTR_AimTraverse(intercept_t* in)
;;; Sets linetarget and aimslope when a target is aimed at.
;;; ---------------------------------------------------------------------------
              .public PTR_AimTraverse
PTR_AimTraverse:
              jsr     .kbank loadIntercept
              bne     1$
              brl     aimThing              ; a thing
1$:           ldy     ##OFS_LINE_FLAGS      ; a one sided line: stop
              lda     [.tiny (_Dp+4)],y
              and     ##CONST_ML_TWOSIDED
              bne     2$
              brl     stop
2$:           jsr     .kbank opening        ; openbottom >= opentop: stop
              lda     .near _g_openbottom
              cmp     .near _g_opentop
              lda     .near (_g_openbottom+2)
              SLT32   .near (_g_opentop+2)
              bmi     3$
              brl     stop
3$:           jsr     .kbank rangeDist      ; dist = FixedMul(attackrange, in->frac)
              jsr     .kbank lineSectors
              ldy     ##OFS_SEC_FLOORHEIGHT ; the floors differ: the bottom slope
              jsr     .kbank sectorsDiffer
              beq     5$
              ldx     ##.near _g_openbottom
              jsr     .kbank slopeTo        ; slope > bottomslope: bottomslope = slope
              lda     .near AT_BOT
              cmp     .near AT_T
              lda     .near (AT_BOT+2)
              SLT32   .near (AT_T+2)
              bpl     5$
              lda     .near AT_T
              sta     .near AT_BOT
              lda     .near (AT_T+2)
              sta     .near (AT_BOT+2)
5$:           ldy     ##OFS_SEC_CEILINGHEIGHT ; the ceilings differ: the top slope
              jsr     .kbank sectorsDiffer
              beq     6$
              ldx     ##.near _g_opentop
              jsr     .kbank slopeTo        ; slope < topslope: topslope = slope
              lda     .near AT_T
              cmp     .near AT_TOP
              lda     .near (AT_T+2)
              SLT32   .near (AT_TOP+2)
              bpl     6$
              lda     .near AT_T
              sta     .near AT_TOP
              lda     .near (AT_T+2)
              sta     .near (AT_TOP+2)
6$:           lda     .near AT_BOT          ; topslope <= bottomslope: stop
              cmp     .near AT_TOP
              lda     .near (AT_BOT+2)
              SLT32   .near (AT_TOP+2)
              bmi     goA
              brl     stop

goA:          lda     ##1
              rtl

              ;; a thing: not the shooter, and shootable

aimThing:     jsr     .kbank shootable
              bcs     goA
              jsr     .kbank rangeDist
              jsr     .kbank thingTop       ; thingtopslope < bottomslope: over it
              lda     .near AT_TTOP
              cmp     .near AT_BOT
              lda     .near (AT_TTOP+2)
              SLT32   .near (AT_BOT+2)
              bmi     goA
              jsr     .kbank thingBottom    ; thingbottomslope > topslope: under it
              lda     .near AT_TOP
              cmp     .near AT_TBOT
              lda     .near (AT_TOP+2)
              SLT32   .near (AT_TBOT+2)
              bmi     goA
              lda     .near AT_TOP          ; thingtopslope = min(it, topslope)
              cmp     .near AT_TTOP
              lda     .near (AT_TOP+2)
              SLT32   .near (AT_TTOP+2)
              bpl     21$
              lda     .near AT_TOP
              sta     .near AT_TTOP
              lda     .near (AT_TOP+2)
              sta     .near (AT_TTOP+2)
21$:          lda     .near AT_TBOT         ; thingbottomslope = max(it, bottomslope)
              cmp     .near AT_BOT
              lda     .near (AT_TBOT+2)
              SLT32   .near (AT_BOT+2)
              bpl     22$
              lda     .near AT_BOT
              sta     .near AT_TBOT
              lda     .near (AT_BOT+2)
              sta     .near (AT_TBOT+2)
22$:          clc                           ; aimslope = (top + bottom) / 2, toward 0
              lda     .near AT_TTOP
              adc     .near AT_TBOT
              sta     .near AT_T
              lda     .near (AT_TTOP+2)
              adc     .near (AT_TBOT+2)
              bpl     23$
              inc     .near AT_T            ; minus: + 1 first
              bne     23$
              inc     a
23$:          cmp     ##0x8000
              ror     a
              sta     .near (AT_AIM+2)
              lda     .near AT_T
              ror     a
              sta     .near AT_AIM
              lda     .near AT_LI           ; linetarget = th
              sta     .near _g_linetarget
              lda     .near (AT_LI+2)
              sta     .near (_g_linetarget+2)
stop:         lda     ##0
              rtl

;;; thingTop: AT_TTOP = the slope to the top of the thing AT_LI, INT32_MAX
;;; for dist 0. thingBottom: AT_TBOT, the same to its bottom.
;;; thingTopRaw, thingBottomRaw: without the test of dist.
thingTop:     jsr     .kbank thingHead
              jsr     .kbank slopeOf
              bra     thingTopT
thingTopRaw:  jsr     .kbank thingHead
              jsr     .kbank rawSlope
thingTopT:    lda     .near AT_T
              sta     .near AT_TTOP
              lda     .near (AT_T+2)
              sta     .near (AT_TTOP+2)
              rts

;;; PIT_RadiusAttack(the thing at _Dp[0-3]): a shootable thing within
;;; bombdamage units of bombspot (the larger of dx and dy, minus its
;;; radius), in its sight, takes the damage minus the distance. True.
PIT_RadiusAttack:
              ldy     ##OFS_MO_FLAGS
              lda     [.tiny _Dp],y
              and     ##CONST_MF_SHOOTABLE_LO
              bne     10$
              brl     9$
10$:
              lda     dp:.tiny _Dp
              sta     .near AT_BTHING
              lda     dp:.tiny (_Dp+2)
              sta     .near (AT_BTHING+2)
              lda     .near AT_BSPOT
              sta     dp:.tiny (_Dp+4)
              lda     .near (AT_BSPOT+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_MO_X            ; dx = |thing->x - spot->x|
              jsr     .kbank absDelta
              lda     .near AT_T
              sta     .near AT_DIST
              lda     .near (AT_T+2)
              sta     .near (AT_DIST+2)
              ldy     ##OFS_MO_Y            ; dy = |thing->y - spot->y|
              jsr     .kbank absDelta
              lda     .near AT_T            ; dist = dx > dy ? dx : dy
              cmp     .near AT_DIST
              lda     .near (AT_T+2)
              SLT32   .near (AT_DIST+2)
              bmi     1$
              lda     .near AT_T
              sta     .near AT_DIST
              lda     .near (AT_T+2)
              sta     .near (AT_DIST+2)
1$:           ldy     ##OFS_MO_RADIUS       ; dist = (dist - radius) >> FRACBITS,
              lda     .near AT_DIST         ; at least 0
              sec
              sbc     [.tiny _Dp],y
              iny
              iny
              lda     .near (AT_DIST+2)
              sbc     [.tiny _Dp],y
              bpl     2$
              lda     ##0
2$:           cmp     .near AT_BDAMAGE      ; dist >= bombdamage: out of range
              bcs     9$
              sta     .near AT_BDIST
              jsl     long:P_CheckSight     ; P_CheckSight(thing, bombspot)
              cmp     ##0
              beq     9$
              lda     .near (AT_BSOURCE+2)  ; P_DamageMobj(thing, bombspot,
              pha                           ;   bombsource, bombdamage - dist)
              lda     .near AT_BSOURCE
              pha
              lda     .near AT_BTHING
              sta     dp:.tiny _Dp
              lda     .near (AT_BTHING+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near AT_BSPOT
              sta     dp:.tiny (_Dp+4)
              lda     .near (AT_BSPOT+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near AT_BDAMAGE
              sec
              sbc     .near AT_BDIST
              jsl     long:P_DamageMobj
              pla
              pla
9$:           lda     ##1
              rtl

;;; ---------------------------------------------------------------------------
;;; void P_RadiusAttack(mobj_t __far* spot, mobj_t __far* source, int16_t damage)
;;;   In: _Dp[0-3] = spot, _Dp[4-7] = source, C = damage.
;;; Each shootable thing in the blocks within damage units of spot that
;;; spot can see takes damage minus its distance, from source. The loop
;;; state is on the stack: P_DamageMobj runs game logic.
;;; ---------------------------------------------------------------------------
              .public P_RadiusAttack
P_RadiusAttack:
              sta     .near AT_BDAMAGE
              lda     dp:.tiny _Dp
              sta     .near AT_BSPOT
              lda     dp:.tiny (_Dp+2)
              sta     .near (AT_BSPOT+2)
              lda     dp:.tiny (_Dp+4)
              sta     .near AT_BSOURCE
              lda     dp:.tiny (_Dp+6)
              sta     .near (AT_BSOURCE+2)
              ;; the blocks (spot +- dist - org) >> MAPBLOCKSHIFT, with dist =
              ;; damage << FRACBITS (the C expression (damage + MAXRADIUS) <<
              ;; FRACBITS loses MAXRADIUS in 32 bits)
              ldy     ##OFS_MO_X            ; xh, xl
              ldx     ##.near _g_bmaporgx
              jsr     .kbank blockPair
              pha
              phx                           ; 1,s xl, 3,s xh
              ldy     ##OFS_MO_Y            ; yh, yl
              ldx     ##.near _g_bmaporgy
              jsr     .kbank blockPair
              pha
              phx                           ; 1,s y = yl, 3,s yh, 5,s xl, 7,s xh
1$:           lda     5,s                   ; x = xl
              pha                           ; 1,s x, 3,s y, 5,s yh, 7,s xl, 9,s xh
2$:           lda     3,s                   ; P_BlockThingsIterator(x, y, PIT_RadiusAttack)
              sta     dp:.tiny _Dp
              lda     ##.word0 PIT_RadiusAttack
              sta     dp:.tiny (_Dp+4)
              lda     ##.word2 PIT_RadiusAttack
              sta     dp:.tiny (_Dp+6)
              lda     1,s
              jsl     long:P_BlockThingsIterator
              lda     1,s                   ; x++ while x <= xh
              inc     a
              sta     1,s
              lda     9,s
              sec
              sbc     1,s
              bvc     3$
              eor     ##0x8000
3$:           bpl     2$
              pla                           ; y++ while y <= yh
              lda     1,s
              inc     a
              sta     1,s
              lda     3,s
              sec
              sbc     1,s
              bvc     4$
              eor     ##0x8000
4$:           bpl     1$
              pla
              pla
              pla
              pla
              rtl

;;; shootSpecial: P_ShootSpecialLine(shootthing, the line AT_LI): only line
;;; type 46 (open a door on impact) has an action; monsters can use it too.
shootSpecial: lda     .near AT_LI
              sta     dp:.tiny _Dp
              lda     .near (AT_LI+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_LINE_SPECIAL
              lda     [.tiny _Dp],y
              cmp     ##46
              bne     9$
              jsl     long:P_CheckTag       ; a tag is needed
              cmp     ##0
              beq     9$
              lda     .near AT_LI           ; EV_DoDoor(line, dopen)
              sta     dp:.tiny _Dp
              lda     .near (AT_LI+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##CONST_DOPEN
              jsl     long:EV_DoDoor
              lda     .near AT_LI           ; P_ChangeSwitchTexture(line, true)
              sta     dp:.tiny _Dp
              lda     .near (AT_LI+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##1
              jsl     long:P_ChangeSwitchTexture
9$:           rts

;;; ceilBelowZ: N set if the fixed_t at offset Y of the sector at _Dp[0-3]
;;; is below the puff z.
ceilBelowZ:   lda     [.tiny _Dp],y
              cmp     .near AT_PZ
              iny
              iny
              lda     [.tiny _Dp],y
              SLT32   .near (AT_PZ+2)
              rts

thingBottom:  jsr     .kbank thingFoot
              jsr     .kbank slopeOf
              bra     thingBotT
thingBottomRaw:
              jsr     .kbank thingFoot
              jsr     .kbank rawSlope
thingBotT:    lda     .near AT_T
              sta     .near AT_TBOT
              lda     .near (AT_T+2)
              sta     .near (AT_TBOT+2)
              rts

;;; slopeTo: AT_T = dist != 0 ? FixedApproxDiv(height - shootz, dist) :
;;; INT32_MAX, height the fixed_t at near address X.
slopeTo:      lda     abs:0,x
              sec
              sbc     .near AT_Z
              pha
              lda     abs:2,x
              sbc     .near (AT_Z+2)
              tax
              pla
              ;; fall into slopeOf

;;; slopeOf: AT_T = dist != 0 ? FixedApproxDiv(X:C, dist) : INT32_MAX.
slopeOf:      ldy     .near AT_DIST
              bne     1$
              ldy     .near (AT_DIST+2)
              bne     1$
              lda     ##0xffff
              sta     .near AT_T
              lda     ##0x7fff
              sta     .near (AT_T+2)
              rts
1$:           ldy     .near AT_DIST
              sty     dp:.tiny _Dp
              ldy     .near (AT_DIST+2)
              sty     dp:.tiny (_Dp+2)
              jsl     long:FixedApproxDiv
              sta     .near AT_T
              stx     .near (AT_T+2)
              rts

;;; puffPos: the puff a little before the hit: C = 4 or 10,
;;;   frac = in->frac - C * FixedReciprocal(attackrange)
;;;   x = trace.x + FixedMul(trace.dx, frac)
;;;   y = trace.y + FixedMul(trace.dy, frac)
;;;   z = shootz + FixedMul3(aimslope, frac, attackrange)
puffPos:      pha
              lda     .near AT_RANGE
              ldx     .near (AT_RANGE+2)
              jsl     long:FixedReciprocal
              sta     dp:.tiny _Dp          ; * 4 or * 10 (low 32 bits)
              stx     dp:.tiny (_Dp+2)
              pla
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_Mul32
              sta     .near AT_T
              stx     .near (AT_T+2)
              lda     .near AT_IN
              sta     dp:.tiny _Dp
              lda     .near (AT_IN+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_IC_FRAC
              lda     [.tiny _Dp],y
              sec
              sbc     .near AT_T
              sta     .near AT_FRAC
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     .near (AT_T+2)
              sta     .near (AT_FRAC+2)
              ldx     ##0                   ; x
              jsr     .kbank traceAt
              sta     .near AT_PX
              stx     .near (AT_PX+2)
              ldx     ##4                   ; y
              jsr     .kbank traceAt
              sta     .near AT_PY
              stx     .near (AT_PY+2)
              lda     .near (AT_FRAC+2)     ; z
              ldx     .near AT_FRAC
              jsr     .kbank mul3
              clc
              adc     .near AT_Z
              sta     .near AT_PZ
              txa
              adc     .near (AT_Z+2)
              sta     .near (AT_PZ+2)
              rts

;;; traceAt: X:C = trace.x + FixedMul(trace.dx, frac) for X = 0, the same
;;; with y for X = 4.
traceAt:      phx
              lda     .near AT_FRAC
              sta     dp:.tiny _Dp
              lda     .near (AT_FRAC+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near (_g_trace+OFS_DL_DX),x
              pha
              lda     .near (_g_trace+OFS_DL_DX+2),x
              tax
              pla
              jsl     long:FixedMul
              ply
              clc
              adc     .near (_g_trace+OFS_DL_X),y
              pha
              txa
              adc     .near (_g_trace+OFS_DL_X+2),y
              tax
              pla
              rts

puffArgs:     lda     .near AT_PY
              sta     dp:.tiny _Dp
              lda     .near (AT_PY+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near AT_PZ
              sta     dp:.tiny (_Dp+4)
              lda     .near (AT_PZ+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near AT_PX
              ldx     .near (AT_PX+2)
              rts

;;; spawnPuff: P_SpawnPuff(x, y, z). puffArgs: its arguments.
spawnPuff:    jsr     .kbank puffArgs
              jsl     long:P_SpawnPuff
              rts

;;; blockPair: for the coordinate at offset Y of bombspot and the origin at
;;; near X: C = (it + dist - org) >> 23, X = (it - dist - org) >> 23.
blockPair:    lda     .near AT_BSPOT
              sta     dp:.tiny _Dp
              lda     .near (AT_BSPOT+2)
              sta     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp],y         ; the high word of it - org
              sec
              sbc     abs:0,x
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     abs:2,x
              pha
              sec                           ; - dist
              sbc     .near AT_BDAMAGE
              SHR7
              tax
              pla                           ; + dist
              clc
              adc     .near AT_BDAMAGE
              SHR7
              rts

;;; absDelta: AT_T = |the fixed_t at offset Y of _Dp[0-3] - the one of
;;; _Dp[4-7]| (D_abs).
absDelta:     lda     [.tiny _Dp],y
              sec
              sbc     [.tiny (_Dp+4)],y
              sta     .near AT_T
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     [.tiny (_Dp+4)],y
              bpl     1$
              tax
              lda     ##0
              sec
              sbc     .near AT_T
              sta     .near AT_T
              txa
              eor     ##0xffff
              adc     ##0
1$:           sta     .near (AT_T+2)
              rts
