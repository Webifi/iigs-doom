;;; The player in 65816 assembly, Doom8088: Apple IIgs Edition.
;;;
;;; p_user.c with the same results: P_PlayerThink with the
;;; movement, the view height and bobbing, the death view and the special
;;; sectors. There is one player, so the player_t* argument is always
;;; &_g_player, and the code uses _g_player directly.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "info.inc"

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


              .extern _Dp, _g_player, states, _g_leveltime
              .extern P_SetMobjState, P_Random, P_DamageMobj, P_UseLines
              .extern P_MovePsprites, G_ExitLevel, R_PointToAngle3
              .extern finesine, finecosine, FixedMulAngle, _Mul32, IIGS_MulLo16
              .extern MA, MB, MR, umul16

PL            .equ    _g_player
PL_MO         .equ    (_g_player + OFS_PL_MO)
PL_CMD        .equ    (_g_player + OFS_PL_CMD)

MAXBOB_HI     .equ    0x10            ; MAXBOB = 0x100000
ANG5          .equ    0x038e38e3      ; ANG90 / 18
NANG5         .equ    0xfc71c71d      ; (uint32_t)-ANG5
INVERSECOLORMAP .equ  32
VIEWHALF_LO   .equ    0x8000          ; VIEWHEIGHT / 2 = 20.5 * FRACUNIT
VIEWHALF_HI   .equ    20

              .section znear, bss
PU_ONGROUND:  .space  2               ; onground
PU_T:         .space  4
PU_BOB:       .space  4               ; the bob of P_CalcHeight
PU_ANGLE:     .space  4
PU_V:         .space  4               ; a thrust or a square

;;; Signed 32-bit a < b: lda a.lo / cmp b.lo / lda a.hi / SLT32 b.hi / bmi
SLT32         .macro  op
              sbc     \op
              bvc     1$
              eor     ##0x8000
1$:
              .endm

;;; ---------------------------------------------------------------------------
;;; void P_PlayerThink(player_t* player)
;;; ---------------------------------------------------------------------------
              .section logiccode, text
              .public P_PlayerThink
P_PlayerThink:
              jsr     .kbank argMo          ; MF_NOCLIP with the noclip cheat
              ldy     ##OFS_MO_FLAGS
              lda     [.tiny _Dp],y
              and     ##(0xffff - CONST_MF_NOCLIP_LO)
              tax
              lda     .near (PL+OFS_PL_CHEATS)
              and     ##CONST_CF_NOCLIP
              beq     1$
              txa
              ora     ##CONST_MF_NOCLIP_LO
              tax
1$:           txa
              sta     [.tiny _Dp],y
              and     ##CONST_MF_JUSTATTACKED_LO ; the chainsaw runs forward
              beq     2$
              lda     [.tiny _Dp],y
              and     ##(0xffff - CONST_MF_JUSTATTACKED_LO)
              sta     [.tiny _Dp],y
              stz     .near (PL_CMD+OFS_TC_ANGLETURN)
              lda     ##100                 ; forwardmove = 0xc800 / 512, sidemove = 0
              sta     .near (PL_CMD+OFS_TC_FORWARDMOVE)
2$:           lda     .near (PL+OFS_PL_PLAYERSTATE)
              cmp     ##CONST_PST_DEAD
              bne     3$
              brl     deathThink

3$:           ldy     ##OFS_MO_REACTIONTIME ; no move for a while after a teleport
              lda     [.tiny _Dp],y
              beq     4$
              dec     a
              sta     [.tiny _Dp],y
              bra     5$
4$:           jsr     .kbank movePlayer
5$:           jsr     .kbank calcHeight
              jsr     .kbank argMo          ; a special sector?
              jsr     .kbank moSector
              ldy     ##OFS_SEC_SPECIAL
              lda     [.tiny _Dp],y
              beq     6$
              jsr     .kbank specialSector

6$:           lda     .near (PL_CMD+OFS_TC_BUTTONS) ; a weapon change
              and     ##CONST_BT_CHANGE
              beq     7$
              lda     .near (PL_CMD+OFS_TC_BUTTONS)
              and     ##CONST_BT_WEAPONMASK
              lsr     a
              lsr     a
              lsr     a
              cmp     .near (PL+OFS_PL_READYWEAPON)
              beq     7$
              cmp     ##CONST_WP_PLASMA     ; not to plasma or BFG
              beq     7$
              cmp     ##CONST_WP_BFG
              beq     7$
              tay
              asl     a
              tax
              lda     .near (PL+OFS_PL_WEAPONOWNED),x
              beq     7$
              sty     .near (PL+OFS_PL_PENDINGWEAPON)
7$:           lda     .near (PL_CMD+OFS_TC_BUTTONS) ; use
              and     ##CONST_BT_USE
              beq     8$
              lda     .near (PL+OFS_PL_USEDOWN)
              bne     9$
              lda     ##.near PL
              sta     dp:.tiny _Dp
              lda     ##.word2 PL
              sta     dp:.tiny (_Dp+2)
              jsl     long:P_UseLines
              lda     ##1
              sta     .near (PL+OFS_PL_USEDOWN)
              bra     9$
8$:           stz     .near (PL+OFS_PL_USEDOWN)
9$:           jsl     long:P_MovePsprites

              ;; the counters of the power ups
              lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_STRENGTH) ; strength counts up
              beq     10$
              inc     .near (PL+OFS_PL_POWERS+2*CONST_PW_STRENGTH)
10$:          ldx     ##(2*CONST_PW_INVULNERABILITY)
              jsr     .kbank countDown
              lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_INVISIBILITY)
              beq     11$
              bmi     11$
              dec     a
              sta     .near (PL+OFS_PL_POWERS+2*CONST_PW_INVISIBILITY)
              bne     11$
              jsr     .kbank argMo          ; visible again
              ldy     ##(OFS_MO_FLAGS+2)
              lda     [.tiny _Dp],y
              and     ##(0xffff - CONST_MF_SHADOW_HI)
              sta     [.tiny _Dp],y
11$:          ldx     ##(2*CONST_PW_INFRARED)
              jsr     .kbank countDown
              ldx     ##(2*CONST_PW_IRONFEET)
              jsr     .kbank countDown
              lda     .near (PL+OFS_PL_DAMAGECOUNT)
              beq     12$
              dec     .near (PL+OFS_PL_DAMAGECOUNT)
12$:          lda     .near (PL+OFS_PL_BONUSCOUNT)
              beq     13$
              dec     .near (PL+OFS_PL_BONUSCOUNT)
              ;; the colormap: inverse for invulnerability, 1 for light
              ;; amplification, both blink at the end
13$:          ldy     ##INVERSECOLORMAP
              lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_INVULNERABILITY)
              jsr     .kbank blink
              bcs     14$
              ldy     ##1
              lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_INFRARED)
              jsr     .kbank blink
              bcs     14$
              ldy     ##0
14$:          sty     .near (PL+OFS_PL_FIXEDCOLORMAP)
              rtl

;;; countDown: if (powers[X / 2] > 0) powers[X / 2]--.
countDown:    lda     .near (PL+OFS_PL_POWERS),x
              beq     9$
              bmi     9$
              dec     a
              sta     .near (PL+OFS_PL_POWERS),x
9$:           rts

;;; blink: carry set if C > 4 * 32 or C & 8.
blink:        tax
              sec                           ; > 128, signed
              sbc     ##(4*32+1)
              bvc     0$
              eor     ##0x8000
0$:           bpl     1$
              txa
              and     ##8
              beq     8$
1$:           sec
              rts
8$:           clc
              rts

;;; argMo: _Dp[0-3] = player->mo.
argMo:        lda     .near PL_MO
              sta     dp:.tiny _Dp
              lda     .near (PL_MO+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; moSector: _Dp[0-3] = the sector of the mobj at _Dp[0-3].
moSector:     ldy     ##(OFS_MO_SUBSECTOR+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_MO_SUBSECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##(OFS_SUB_SECTOR+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SUB_SECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              rts

;;; onGround: PU_ONGROUND = mo->z <= mo->floorz. In: _Dp = mo.
onGround:     ldy     ##OFS_MO_FLOORZ       ; !(floorz < z)
              lda     [.tiny _Dp],y
              ldy     ##OFS_MO_Z
              cmp     [.tiny _Dp],y
              ldy     ##(OFS_MO_FLOORZ+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_Z+2)
              sbc     [.tiny _Dp],y
              bvc     1$
              eor     ##0x8000
1$:           bmi     2$
              lda     ##1
              sta     .near PU_ONGROUND
              rts
2$:           stz     .near PU_ONGROUND
              rts

;;; ---------------------------------------------------------------------------
;;; movePlayer: P_MovePlayer(player): turn, and thrust when on the ground.
;;; ---------------------------------------------------------------------------
movePlayer:   jsr     .kbank argMo          ; mo->angle += angleturn << 16
              ldy     ##(OFS_MO_ANGLE+2)
              lda     [.tiny _Dp],y
              clc
              adc     .near (PL_CMD+OFS_TC_ANGLETURN)
              sta     [.tiny _Dp],y
              jsr     .kbank onGround
              lda     .near (PL_CMD+OFS_TC_FORWARDMOVE) ; forwardmove | sidemove
              bne     1$
              rts
1$:           lda     .near PU_ONGROUND
              beq     5$
              lda     .near (PL_CMD+OFS_TC_FORWARDMOVE) ; forward
              and     ##0x00ff
              beq     3$
              pha
              jsr     .kbank argMo
              ldy     ##(OFS_MO_ANGLE+2)
              lda     [.tiny _Dp],y
              lsr     a
              lsr     a
              lsr     a
              tax
              pla
              jsr     .kbank bobAndThrust
3$:           lda     .near (PL_CMD+OFS_TC_SIDEMOVE) ; sideways: angle - ANG90
              and     ##0x00ff
              beq     5$
              pha
              jsr     .kbank argMo
              ldy     ##(OFS_MO_ANGLE+2)
              lda     [.tiny _Dp],y
              sec
              sbc     ##0x4000
              lsr     a
              lsr     a
              lsr     a
              tax
              pla
              jsr     .kbank bobAndThrust
5$:           jsr     .kbank argMo          ; standing: the run animation
              ldy     ##OFS_MO_STATE
              lda     [.tiny _Dp],y
              cmp     ##.near (states + CONST_S_PLAY * STATE_SIZE)
              bne     9$
              lda     ##CONST_S_PLAY_RUN1
              jsl     long:P_SetMobjState
9$:           rts

;;; bobAndThrust: P_BobAndThrust(player, angle X, move C, a signed byte):
;;; m = move * ORIG_FRICTION_FACTOR (2048), v = FixedMulAngle(m, finecosine
;;; and finesine of the angle), added to the momentum of the mobj and to the
;;; momentum of the bobbing.
bobAndThrust: stx     .near PU_ANGLE
              and     ##0x00ff              ; the byte, sign extended
              cmp     ##0x0080
              bcc     1$
              ora     ##0xff00
1$:           tax
              cmp     ##0x8000              ; m high word: move >> 5, arithmetic
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              sta     .near (PU_T+2)
              txa                           ; m low word: move << 11
              xba
              and     ##0xff00
              asl     a
              asl     a
              asl     a
              sta     .near PU_T
              lda     .near PU_ANGLE        ; x
              jsl     long:finecosine
              jsr     .kbank thrustMul
              ldy     ##0
              jsr     .kbank addMom
              lda     .near PU_ANGLE        ; y
              jsl     long:finesine
              jsr     .kbank thrustMul
              ldy     ##4
              ;; fall into addMom

;;; addMom: mo->mom and player->mom += X:C, x for Y = 0, y for Y = 4.
addMom:       sta     .near PU_V
              stx     .near (PU_V+2)
              phy
              jsr     .kbank argMo
              CLEARCLEAN _Dp
              lda     1,s
              clc
              adc     ##OFS_MO_MOMX
              tay
              lda     [.tiny _Dp],y
              clc
              adc     .near PU_V
              sta     [.tiny _Dp],y
              iny
              iny
              lda     [.tiny _Dp],y
              adc     .near (PU_V+2)
              sta     [.tiny _Dp],y
              plx
              lda     .near (PL+OFS_PL_MOMX),x
              clc
              adc     .near PU_V
              sta     .near (PL+OFS_PL_MOMX),x
              lda     .near (PL+OFS_PL_MOMX+2),x
              adc     .near (PU_V+2)
              sta     .near (PL+OFS_PL_MOMX+2),x
              rts

;;; thrustMul: X:C = FixedMulAngle(m = PU_T, X:C).
thrustMul:    sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near PU_T
              ldx     .near (PU_T+2)
              jsl     long:FixedMulAngle
              rts

;;; ---------------------------------------------------------------------------
;;; calcHeight: P_CalcHeight(player): the bobbing and the view height.
;;; ---------------------------------------------------------------------------
calcHeight:   ldx     ##0                   ; bob = (FixedSquare(momx) +
              jsr     .kbank fixedSquare    ;        FixedSquare(momy)) >> 2
              sta     .near PU_BOB
              stx     .near (PU_BOB+2)
              ldx     ##4
              jsr     .kbank fixedSquare
              clc
              adc     .near PU_BOB
              sta     .near PU_BOB
              txa
              adc     .near (PU_BOB+2)
              ldx     ##2
1$:           cmp     ##0x8000
              ror     a
              ror     .near PU_BOB
              dex
              bne     1$
              sta     .near (PU_BOB+2)
              lda     ##0                   ; bob > MAXBOB: MAXBOB
              cmp     .near PU_BOB
              lda     ##MAXBOB_HI
              SLT32   .near (PU_BOB+2)
              bpl     2$
              stz     .near PU_BOB
              lda     ##MAXBOB_HI
              sta     .near (PU_BOB+2)
2$:           lda     .near PU_BOB
              sta     .near (PL+OFS_PL_BOB)
              lda     .near (PU_BOB+2)
              sta     .near (PL+OFS_PL_BOB+2)
              lda     .near PU_ONGROUND     ; in the air: viewz = z + VIEWHEIGHT
              bne     4$
              jsr     .kbank argMo
              ldy     ##OFS_MO_Z
              lda     [.tiny _Dp],y
              clc
              adc     ##CONST_VIEWHEIGHT_LO
              sta     .near (PL+OFS_PL_VIEWZ)
              iny
              iny
              lda     [.tiny _Dp],y
              adc     ##CONST_VIEWHEIGHT_HI
              sta     .near (PL+OFS_PL_VIEWZ+2)
              brl     viewCeiling

              ;; bob = FixedMulAngle(player->bob / 2, finesine(angle)),
              ;; angle = (FINEANGLES / 20 * leveltime) & FINEMASK
4$:           lda     .near _g_leveltime
              ldx     ##409
              jsl     long:IIGS_MulLo16
              and     ##0x1fff
              jsl     long:finesine
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near (PL+OFS_PL_BOB+2) ; bob / 2, toward 0
              tax
              lda     .near (PL+OFS_PL_BOB)
              cpx     ##0
              bpl     5$
              clc
              adc     ##1
              bcc     5$
              inx
5$:           sta     .near PU_V
              txa
              cmp     ##0x8000
              ror     a
              tax
              lda     .near PU_V
              ror     a
              jsl     long:FixedMulAngle
              sta     .near PU_BOB
              stx     .near (PU_BOB+2)

              lda     .near (PL+OFS_PL_PLAYERSTATE) ; alive: the view height moves
              cmp     ##CONST_PST_LIVE
              beq     6$
              brl     10$
6$:           clc                           ; viewheight += deltaviewheight
              lda     .near (PL+OFS_PL_VIEWHEIGHT)
              adc     .near (PL+OFS_PL_DELTAVIEWHEIGHT)
              sta     .near (PL+OFS_PL_VIEWHEIGHT)
              lda     .near (PL+OFS_PL_VIEWHEIGHT+2)
              adc     .near (PL+OFS_PL_DELTAVIEWHEIGHT+2)
              sta     .near (PL+OFS_PL_VIEWHEIGHT+2)
              lda     ##CONST_VIEWHEIGHT_LO ; > VIEWHEIGHT: VIEWHEIGHT, delta 0
              cmp     .near (PL+OFS_PL_VIEWHEIGHT)
              lda     ##CONST_VIEWHEIGHT_HI
              SLT32   .near (PL+OFS_PL_VIEWHEIGHT+2)
              bpl     7$
              lda     ##CONST_VIEWHEIGHT_LO
              sta     .near (PL+OFS_PL_VIEWHEIGHT)
              lda     ##CONST_VIEWHEIGHT_HI
              sta     .near (PL+OFS_PL_VIEWHEIGHT+2)
              stz     .near (PL+OFS_PL_DELTAVIEWHEIGHT)
              stz     .near (PL+OFS_PL_DELTAVIEWHEIGHT+2)
7$:           lda     .near (PL+OFS_PL_VIEWHEIGHT) ; < VIEWHEIGHT / 2: VIEWHEIGHT / 2,
              cmp     ##VIEWHALF_LO               ; and delta at least 1
              lda     .near (PL+OFS_PL_VIEWHEIGHT+2)
              SLT32   ##VIEWHALF_HI
              bpl     8$
              lda     ##VIEWHALF_LO
              sta     .near (PL+OFS_PL_VIEWHEIGHT)
              lda     ##VIEWHALF_HI
              sta     .near (PL+OFS_PL_VIEWHEIGHT+2)
              lda     .near (PL+OFS_PL_DELTAVIEWHEIGHT+2) ; delta <= 0: 1
              bmi     71$
              ora     .near (PL+OFS_PL_DELTAVIEWHEIGHT)
              bne     8$
71$:          lda     ##1
              sta     .near (PL+OFS_PL_DELTAVIEWHEIGHT)
              stz     .near (PL+OFS_PL_DELTAVIEWHEIGHT+2)
8$:           lda     .near (PL+OFS_PL_DELTAVIEWHEIGHT) ; delta: += FRACUNIT / 4,
              ora     .near (PL+OFS_PL_DELTAVIEWHEIGHT+2) ; but not to 0
              beq     10$
              lda     .near (PL+OFS_PL_DELTAVIEWHEIGHT)
              clc
              adc     ##0x4000
              sta     .near (PL+OFS_PL_DELTAVIEWHEIGHT)
              lda     .near (PL+OFS_PL_DELTAVIEWHEIGHT+2)
              adc     ##0
              sta     .near (PL+OFS_PL_DELTAVIEWHEIGHT+2)
              ora     .near (PL+OFS_PL_DELTAVIEWHEIGHT)
              bne     10$
              lda     ##1
              sta     .near (PL+OFS_PL_DELTAVIEWHEIGHT)

10$:          jsr     .kbank argMo          ; viewz = z + viewheight + bob
              ldy     ##OFS_MO_Z
              lda     [.tiny _Dp],y
              clc
              adc     .near (PL+OFS_PL_VIEWHEIGHT)
              tax
              iny
              iny
              lda     [.tiny _Dp],y
              adc     .near (PL+OFS_PL_VIEWHEIGHT+2)
              tay
              txa
              clc
              adc     .near PU_BOB
              sta     .near (PL+OFS_PL_VIEWZ)
              tya
              adc     .near (PU_BOB+2)
              sta     .near (PL+OFS_PL_VIEWZ+2)
              ;; fall into viewCeiling

;;; viewCeiling: viewz at most ceilingz - 4 * FRACUNIT. In: _Dp = mo.
viewCeiling:  ldy     ##OFS_MO_CEILINGZ
              lda     [.tiny _Dp],y
              sta     .near PU_V
              iny
              iny
              lda     [.tiny _Dp],y
              sec
              sbc     ##4
              sta     .near (PU_V+2)
              lda     .near PU_V            ; (ceilingz - 4) < viewz: the ceiling
              cmp     .near (PL+OFS_PL_VIEWZ)
              lda     .near (PU_V+2)
              SLT32   .near (PL+OFS_PL_VIEWZ+2)
              bpl     9$
              lda     .near PU_V
              sta     .near (PL+OFS_PL_VIEWZ)
              lda     .near (PU_V+2)
              sta     .near (PL+OFS_PL_VIEWZ+2)
9$:           rts

;;; fixedSquare: X:C = FixedSquare(a), a = player->mom[X / 4]:
;;;   (a + alw) * ahw + ((alw * alw) >> 16), alw = a & 0xffff, ahw = a >> 16
fixedSquare:  lda     .near (PL+OFS_PL_MOMX),x ; alw * alw
              sta     dp:.tiny MA
              sta     dp:.tiny MB
              phx
              jsl     long:umul16
              plx
              lda     dp:.tiny (MR+2)
              sta     .near PU_V            ; (alw * alw) >> 16
              lda     .near (PL+OFS_PL_MOMX),x ; a + alw
              clc
              adc     .near (PL+OFS_PL_MOMX),x
              sta     dp:.tiny _Dp
              lda     .near (PL+OFS_PL_MOMX+2),x
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              lda     .near (PL+OFS_PL_MOMX+2),x ; * ahw, sign extended
              sta     dp:.tiny (_Dp+4)
              ldy     ##0
              cmp     ##0
              bpl     1$
              dey
1$:           sty     dp:.tiny (_Dp+6)
              jsl     long:_Mul32
              clc
              adc     .near PU_V
              bcc     2$
              inx
2$:           rts

;;; ---------------------------------------------------------------------------
;;; deathThink: P_DeathThink(player): fall to the ground and turn to the
;;; killer. Ends P_PlayerThink.
;;; ---------------------------------------------------------------------------
deathThink:   jsl     long:P_MovePsprites
              lda     ##0                   ; viewheight > 6 * FRACUNIT: - FRACUNIT
              cmp     .near (PL+OFS_PL_VIEWHEIGHT)
              lda     ##6
              SLT32   .near (PL+OFS_PL_VIEWHEIGHT+2)
              bpl     1$
              dec     .near (PL+OFS_PL_VIEWHEIGHT+2)
1$:           lda     .near (PL+OFS_PL_VIEWHEIGHT) ; < 6 * FRACUNIT: 6 * FRACUNIT
              cmp     ##0
              lda     .near (PL+OFS_PL_VIEWHEIGHT+2)
              SLT32   ##6
              bpl     2$
              stz     .near (PL+OFS_PL_VIEWHEIGHT)
              lda     ##6
              sta     .near (PL+OFS_PL_VIEWHEIGHT+2)
2$:           stz     .near (PL+OFS_PL_DELTAVIEWHEIGHT)
              stz     .near (PL+OFS_PL_DELTAVIEWHEIGHT+2)
              jsr     .kbank argMo
              jsr     .kbank onGround
              jsr     .kbank calcHeight
              lda     .near (PL+OFS_PL_ATTACKER) ; an attacker that is not the player
              ora     .near (PL+OFS_PL_ATTACKER+2)
              beq     29$
              lda     .near (PL+OFS_PL_ATTACKER)
              cmp     .near PL_MO
              bne     3$
              lda     .near (PL+OFS_PL_ATTACKER+2)
              cmp     .near (PL_MO+2)
              bne     3$
29$:          brl     20$
3$:           jsr     .kbank angleToAttacker ; delta = angle - mo->angle
              sta     .near PU_ANGLE
              stx     .near (PU_ANGLE+2)
              jsr     .kbank argMo
              ldy     ##OFS_MO_ANGLE
              lda     .near PU_ANGLE
              sec
              sbc     [.tiny _Dp],y
              sta     .near PU_T
              iny
              iny
              lda     .near (PU_ANGLE+2)
              sbc     [.tiny _Dp],y
              sta     .near (PU_T+2)
              lda     ##.word0 NANG5        ; -ANG5 < delta || delta < ANG5: look at it
              cmp     .near PU_T
              lda     ##.word2 NANG5
              sbc     .near (PU_T+2)
              bcc     4$
              lda     .near PU_T
              cmp     ##.word0 ANG5
              lda     .near (PU_T+2)
              sbc     ##.word2 ANG5
              bcs     5$
4$:           ldy     ##OFS_MO_ANGLE        ; mo->angle = angle, the flash fades
              lda     .near PU_ANGLE
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (PU_ANGLE+2)
              sta     [.tiny _Dp],y
              bra     20$
5$:           lda     .near (PU_T+2)        ; delta < ANG180: + ANG5, else - ANG5
              bmi     6$
              ldy     ##OFS_MO_ANGLE
              lda     [.tiny _Dp],y
              clc
              adc     ##.word0 ANG5
              sta     [.tiny _Dp],y
              iny
              iny
              lda     [.tiny _Dp],y
              adc     ##.word2 ANG5
              sta     [.tiny _Dp],y
              bra     21$
6$:           ldy     ##OFS_MO_ANGLE
              lda     [.tiny _Dp],y
              sec
              sbc     ##.word0 ANG5
              sta     [.tiny _Dp],y
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     ##.word2 ANG5
              sta     [.tiny _Dp],y
              bra     21$
20$:          lda     .near (PL+OFS_PL_DAMAGECOUNT) ; the damage flash fades
              beq     21$
              dec     .near (PL+OFS_PL_DAMAGECOUNT)
21$:          lda     .near (PL_CMD+OFS_TC_BUTTONS) ; use: play again
              and     ##CONST_BT_USE
              beq     22$
              lda     ##CONST_PST_REBORN
              sta     .near (PL+OFS_PL_PLAYERSTATE)
22$:          rtl

;;; angleToAttacker: X:C = R_PointToAngle2(mo->x, mo->y, attacker->x,
;;; attacker->y).
angleToAttacker:
              lda     .near (PL+OFS_PL_ATTACKER)
              sta     dp:.tiny (_Dp+4)
              lda     .near (PL+OFS_PL_ATTACKER+2)
              sta     dp:.tiny (_Dp+6)
              jsr     .kbank argMo
              sec                           ; dy
              ldy     ##OFS_MO_Y
              lda     [.tiny (_Dp+4)],y
              sbc     [.tiny _Dp],y
              sta     .near PU_V
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sbc     [.tiny _Dp],y
              sta     .near (PU_V+2)
              sec                           ; dx
              ldy     ##OFS_MO_X
              lda     [.tiny (_Dp+4)],y
              sbc     [.tiny _Dp],y
              pha
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sbc     [.tiny _Dp],y
              tax
              lda     .near PU_V
              sta     dp:.tiny _Dp
              lda     .near (PU_V+2)
              sta     dp:.tiny (_Dp+2)
              pla
              jsl     long:R_PointToAngle3
              rts

;;; ---------------------------------------------------------------------------
;;; specialSector: P_PlayerInSpecialSector(player): the damaging floors, the
;;; secrets and the end of E1M8. In: _Dp = the sector of the player.
;;; ---------------------------------------------------------------------------
specialSector:
              lda     dp:.tiny _Dp          ; not in the air
              sta     .near PU_V
              lda     dp:.tiny (_Dp+2)
              sta     .near (PU_V+2)
              jsr     .kbank argMo
              ldy     ##OFS_MO_Z
              lda     [.tiny _Dp],y
              tax
              iny
              iny
              lda     [.tiny _Dp],y
              pha
              lda     .near PU_V
              sta     dp:.tiny _Dp
              lda     .near (PU_V+2)
              sta     dp:.tiny (_Dp+2)
              pla
              ldy     ##(OFS_SEC_FLOORHEIGHT+2)
              cmp     [.tiny _Dp],y
              bne     9$
              txa
              ldy     ##OFS_SEC_FLOORHEIGHT
              cmp     [.tiny _Dp],y
              bne     9$
              ldy     ##OFS_SEC_SPECIAL
              lda     [.tiny _Dp],y
              cmp     ##5                   ; 5: 10 damage every 32 tics, no suit
              bne     1$
              lda     ##10
              bra     suitHurt
1$:           cmp     ##7                   ; 7: 5 damage
              bne     2$
              lda     ##5
              bra     suitHurt
2$:           cmp     ##16                  ; 16: 20 damage, also with the suit
              bne     3$                    ; when P_Random() < 5
              lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_IRONFEET)
              beq     21$
              jsl     long:P_Random
              cmp     ##5
              bcs     9$
21$:          lda     ##20
              bra     hurt
3$:           cmp     ##9                   ; 9: a secret, found
              bne     4$
              inc     .near (PL+OFS_PL_SECRETCOUNT)
              lda     ##0
              sta     [.tiny _Dp],y
              rts
4$:           cmp     ##11                  ; 11: the end of E1M8
              bne     9$
              lda     .near (PL+OFS_PL_CHEATS)
              and     ##(0xffff - CONST_CF_GODMODE)
              sta     .near (PL+OFS_PL_CHEATS)
              lda     ##20
              jsr     .kbank hurt32
              lda     .near (PL+OFS_PL_HEALTH)
              cmp     ##11                  ; health <= 10 (signed)
              bpl     9$
              jsl     long:G_ExitLevel
9$:           rts

;;; suitHurt: C damage every 32 tics without the radiation suit.
suitHurt:     ldx     .near (PL+OFS_PL_POWERS+2*CONST_PW_IRONFEET)
              beq     hurt
              rts
;;; hurt, hurt32: P_DamageMobj(player->mo, NULL, NULL, C) when
;;; (int16_t)leveltime & 0x1f is 0.
hurt:
hurt32:       tax
              lda     .near _g_leveltime
              and     ##0x1f
              bne     9$
              phx
              pea     #0                    ; source NULL
              pea     #0
              stz     dp:.tiny (_Dp+4)      ; inflictor NULL
              stz     dp:.tiny (_Dp+6)
              jsr     .kbank argMo
              lda     5,s
              jsl     long:P_DamageMobj
              pla
              pla
              pla
9$:           rts
