;;; Weapons of the player in 65816 assembly.
;;;
;;; p_pspr.c with the same results: the weapon sprite states and
;;; their action functions, weapon changes, ammunition, the noise alert and
;;; the attacks. There is one player, so the player_t* arguments are
;;; always &_g_player, and the code uses _g_player directly.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"
#include "info.inc"

              .extern _Dp, _g_player, states, validcount
              .extern _g_leveltime, _g_linetarget, _g_sides, _g_sectors, _g_openrange
              .extern _g_lines, _g_numsectors, _g_numlines
              .extern DC_EXITP, GW_TAG
              .extern P_SetMobjState, S_StartSound, P_Random, P_LineOpeningXY
              .extern P_AimLineAttack, P_LineAttack, P_SpawnPlayerMissile
              .extern R_PointToAngle3, finesine, finecosine, FixedMulAngle
              .extern _Mul32, _Mod16, _Div16, IIGS_MulLo16

PL            .equ    _g_player
BFGCELLS      .equ    40              ; the cells of a BFG shot
PSPW          .equ    (_g_player + OFS_PL_PSPRITES)             ; ps_weapon
PSPF          .equ    (_g_player + OFS_PL_PSPRITES + SIZEOF_PSP) ; ps_flash
PL_MO         .equ    (_g_player + OFS_PL_MO)

LOWERSPEED_HI .equ    6               ; FRACUNIT * 6, also RAISESPEED
ANG90_20      .equ    0x03333333      ; ANG90 / 20
NANG90_20     .equ    0xfccccccd      ; -ANG90 / 20
ANG90_21      .equ    0x030c30c3      ; ANG90 / 21
WEAPONBOTTOM_HI .equ  128             ; FRACUNIT * 128
WEAPONTOP_HI  .equ    32              ; FRACUNIT * 32
PAD_RS        .equ    111             ; (the flood keeps its size)
SEC58         .equ    (MM_B3F + 0xa000) ; the sectors by number (src/iigs/p_sight65.s)
LNSEC         .equ    (MM_B3F + 0xc000) ; the sectors of each line (the same)
LN36          .equ    (MM_B3F + 0x6200) ; the lines by number (src/iigs/p_map65.s)
GW_TAB        .equ    MM_GW_TAB       ; the guard counts of src/iigs/p_path65.s,
GW_MAXB       .equ    3276            ;   10 bytes a block
FL_IDX        .equ    MM_FL_IDX       ; the lists of the sound flood (P_InitFlood):
FL_ENT        .equ    MM_FL_ENT       ;   the index by sector (+ 44: not in the
                                      ;   cache slots of the heights of the
                                      ;   sector), the entries
ACT_JMP       .equ    DC_EXITP        ; the action for jml [] (bank 0), free
                                      ; in the game code

              .section znear, bss
WP_SLOPE:     .space  4               ; bulletslope
WP_ANGLE:     .space  4
WP_T:         .space  4
WP_DAMAGE:    .space  2
WP_I:         .space  2
              .space  4               ; (free: kept for the layout)
RS_TGT:       .space  4               ; its sound target

              .section cfar, rodata
;;; weapon_preferences: the choices of P_SwitchWeapon, and 0 at the end
prefs:        .byte   6, 9, 4, 3, 2, 8, 5, 7, 1, 0

;;; ---------------------------------------------------------------------------
;;; setPsprite: P_SetPsprite(player, position, stnum). In: X = the near
;;; address of the psprite, C = stnum.
;;;   do { if (!stnum) { psp->state = NULL; break; }
;;;        psp->state = &states[stnum]; psp->tics = state->tics;
;;;        if (state->action) { state->action(player, psp);
;;;                             if (!psp->state) break; }
;;;        stnum = psp->state->nextstate; } while (!psp->tics);
;;; Actions can call it again, so the psprite stays on the stack.
;;; ---------------------------------------------------------------------------
              .section logiccode, text
setPsprite:   phx
1$:           plx
              phx
              cmp     ##CONST_S_NULL
              bne     2$
              stz     abs:OFS_PSP_STATE,x   ; the psprite is removed
              stz     abs:(OFS_PSP_STATE+2),x
              plx
              rts
2$:           STATEADDR                     ; &states[stnum]
              tay
              sta     abs:OFS_PSP_STATE,x
              lda     ##.word2 states
              sta     abs:(OFS_PSP_STATE+2),x
              lda     abs:OFS_ST_TICS,y     ; psp->tics = state->tics
              sta     abs:OFS_PSP_TICS,x
              lda     abs:OFS_ST_ACTION,y   ; the action
              ora     abs:(OFS_ST_ACTION+2),y
              beq     5$
              lda     abs:OFS_ST_ACTION,y
              sta     dp:.tiny ACT_JMP
              lda     abs:(OFS_ST_ACTION+2),y
              sta     dp:.tiny (ACT_JMP+2)
              stx     dp:.tiny (_Dp+4)      ; action(player, psp)
              lda     ##.word2 PL
              sta     dp:.tiny (_Dp+6)
              sta     dp:.tiny (_Dp+2)
              lda     ##.near PL
              sta     dp:.tiny _Dp
              jsl     long:callAction
              lda     1,s                   ; if (!psp->state) break
              tax
              lda     abs:OFS_PSP_STATE,x
              ora     abs:(OFS_PSP_STATE+2),x
              beq     9$
5$:           lda     1,s                   ; stnum = psp->state->nextstate
              tax
              ldy     abs:OFS_PSP_STATE,x
              lda     abs:OFS_ST_NEXTSTATE,y
              ldy     abs:OFS_PSP_TICS,x    ; while (!psp->tics)
              bne     9$
              brl     1$
9$:           plx
              rts

callAction:   .byte   0xdc                  ; jml [ACT_JMP]
              .word   .word0 ACT_JMP

;;; wInfo: X = the near address of weaponinfo[readyweapon].
wInfo:        lda     .near (PL+OFS_PL_READYWEAPON)
wInfoOf:      ldx     ##SIZEOF_WI
              jsl     long:IIGS_MulLo16
              clc
              adc     ##.near weaponinfo
              tax
              rts

;;; startSound: S_StartSound(player->mo, C).
startSound:   pha
              jsr     .kbank argMo
              pla
              jsl     long:S_StartSound
              rts

;;; argMo: _Dp[0-3] = player->mo.
argMo:        lda     .near PL_MO
              sta     dp:.tiny _Dp
              lda     .near (PL_MO+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; setMoState: P_SetMobjState(player->mo, C).
setMoState:   pha
              jsr     .kbank argMo
              pla
              jsl     long:P_SetMobjState
              rts

;;; ---------------------------------------------------------------------------
;;; bringUpWeapon: P_BringUpWeapon(player): the pending weapon comes up from
;;; the bottom of the screen.
;;; ---------------------------------------------------------------------------
bringUpWeapon:
              lda     .near (PL+OFS_PL_PENDINGWEAPON)
              cmp     ##CONST_WP_NOCHANGE
              bne     1$
              lda     .near (PL+OFS_PL_READYWEAPON)
              sta     .near (PL+OFS_PL_PENDINGWEAPON)
1$:           cmp     ##CONST_WP_CHAINSAW
              bne     2$
              lda     ##CONST_SFX_SAWUP
              jsr     .kbank startSound
2$:           lda     .near (PL+OFS_PL_PENDINGWEAPON)
              jsr     .kbank wInfoOf
              lda     abs:OFS_WI_UPSTATE,x
              pha
              lda     ##CONST_WP_NOCHANGE
              sta     .near (PL+OFS_PL_PENDINGWEAPON)
              stz     .near (PSPW+OFS_PSP_SY) ; sy = WEAPONBOTTOM + FRACUNIT * 2
              lda     ##(WEAPONBOTTOM_HI + 2)
              sta     .near (PSPW+OFS_PSP_SY+2)
              pla
              ldx     ##.near PSPW
              jmp     .kbank setPsprite

;;; ---------------------------------------------------------------------------
;;; weapontype_t P_SwitchWeapon(player_t* player)
;;; The most preferred weapon with ammunition, not the raised one.
;;; ---------------------------------------------------------------------------
              .public P_SwitchWeapon
P_SwitchWeapon:
              lda     .near (PL+OFS_PL_READYWEAPON)
              sta     .near WP_T            ; newweapon
              lda     ##10                  ; i = NUMWEAPONS + 1
              sta     .near WP_I
              ldx     ##0                   ; prefer
1$:           lda     long:prefs,x
              and     ##0x00ff
              inx
              phx
              cmp     ##1                   ; 1: the fist with berserk,
              bne     2$                    ;    else nothing
              lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_STRENGTH)
              beq     9$
              bra     3$
2$:           cmp     ##0                   ; 0: the fist
              bne     4$
3$:           lda     ##CONST_WP_FIST
              bra     8$
4$:           cmp     ##2                   ; 2: pistol with clips
              bne     5$
              lda     .near (PL+OFS_PL_AMMO+2*CONST_AM_CLIP)
              beq     9$
              lda     ##CONST_WP_PISTOL
              bra     8$
5$:           cmp     ##3                   ; 3: shotgun with shells
              bne     6$
              lda     .near (PL+OFS_PL_WEAPONOWNED+2*CONST_WP_SHOTGUN)
              beq     9$
              lda     .near (PL+OFS_PL_AMMO+2*CONST_AM_SHELL)
              beq     9$
              lda     ##CONST_WP_SHOTGUN
              bra     8$
6$:           cmp     ##4                   ; 4: chaingun with clips
              bne     7$
              lda     .near (PL+OFS_PL_WEAPONOWNED+2*CONST_WP_CHAINGUN)
              beq     9$
              lda     .near (PL+OFS_PL_AMMO+2*CONST_AM_CLIP)
              beq     9$
              lda     ##CONST_WP_CHAINGUN
              bra     8$
7$:           cmp     ##5                   ; 5: rocket launcher with rockets
              bne     71$
              lda     .near (PL+OFS_PL_WEAPONOWNED+2*CONST_WP_MISSILE)
              beq     9$
              lda     .near (PL+OFS_PL_AMMO+2*CONST_AM_MISL)
              beq     9$
              lda     ##CONST_WP_MISSILE
              bra     8$
71$:          cmp     ##8                   ; 8: chainsaw
              bne     9$
              lda     .near (PL+OFS_PL_WEAPONOWNED+2*CONST_WP_CHAINSAW)
              beq     9$
              lda     ##CONST_WP_CHAINSAW
8$:           sta     .near WP_T
9$:           plx
              lda     .near WP_T            ; while (newweapon == currentweapon && --i)
              cmp     .near (PL+OFS_PL_READYWEAPON)
              bne     10$
              dec     .near WP_I
              beq     10$
              brl     1$
10$:          lda     .near WP_T
              rtl

;;; checkCanSwitch: P_CheckCanSwitchWeapon(C, player): C, or wp_nochange
;;; without the ammunition of the weapon.
checkCanSwitch:
              cmp     ##CONST_WP_FIST
              beq     9$
              cmp     ##CONST_WP_CHAINSAW
              beq     9$
              ldx     ##(2*CONST_AM_CLIP)
              cmp     ##CONST_WP_PISTOL
              beq     5$
              cmp     ##CONST_WP_CHAINGUN
              beq     5$
              ldx     ##(2*CONST_AM_SHELL)
              cmp     ##CONST_WP_SHOTGUN
              beq     5$
              ldx     ##(2*CONST_AM_MISL)
              cmp     ##CONST_WP_MISSILE
              beq     5$
              ldx     ##(2*CONST_AM_CELL)
              cmp     ##CONST_WP_PLASMA
              beq     5$
              bra     8$
5$:           ldy     .near (PL+OFS_PL_AMMO),x
              bne     9$
8$:           lda     ##CONST_WP_NOCHANGE
9$:           rts

;;; ---------------------------------------------------------------------------
;;; weapontype_t P_WeaponCycleUp(player_t* player)
;;; weapontype_t P_WeaponCycleDown(player_t* player)
;;; The next owned weapon with ammunition, in the order of PSX Doom.
;;; ---------------------------------------------------------------------------
              .public P_WeaponCycleUp
P_WeaponCycleUp:
              lda     .near (PL+OFS_PL_READYWEAPON)
              sta     .near WP_T
              lda     ##CONST_NUMWEAPONS
              sta     .near WP_I
1$:           lda     .near WP_T            ; w++, 0 after the last
              inc     a
              cmp     ##CONST_NUMWEAPONS
              bcc     2$
              lda     ##0
2$:           cmp     ##CONST_WP_CHAINGUN   ; the order of PSX Doom
              bne     3$
              lda     ##CONST_WP_SUPERSHOTGUN
              bra     7$
3$:           cmp     ##CONST_WP_FIST
              bne     4$
              lda     ##CONST_WP_CHAINGUN
              bra     7$
4$:           cmp     ##CONST_WP_CHAINSAW
              bne     5$
              lda     ##CONST_WP_FIST
              bra     7$
5$:           cmp     ##CONST_WP_PISTOL
              bne     6$
              lda     ##CONST_WP_CHAINSAW
              bra     7$
6$:           cmp     ##CONST_WP_SUPERSHOTGUN
              bne     7$
              lda     ##CONST_WP_PISTOL
7$:           sta     .near WP_T
              jsr     .kbank ownedCan
              bcs     9$
              dec     .near WP_I
              bne     1$
              lda     .near (PL+OFS_PL_READYWEAPON)
9$:           rtl

              .public P_WeaponCycleDown
P_WeaponCycleDown:
              lda     .near (PL+OFS_PL_READYWEAPON)
              sta     .near WP_T
              lda     ##CONST_NUMWEAPONS
              sta     .near WP_I
1$:           lda     .near WP_T            ; w--, the last after 0
              bne     2$
              lda     ##CONST_NUMWEAPONS
2$:           dec     a
              cmp     ##CONST_WP_SHOTGUN    ; the order of PSX Doom
              bne     3$
              lda     ##CONST_WP_SUPERSHOTGUN
              bra     7$
3$:           cmp     ##CONST_WP_CHAINSAW
              bne     4$
              lda     ##CONST_WP_SHOTGUN
              bra     7$
4$:           cmp     ##CONST_WP_FIST
              bne     5$
              lda     ##CONST_WP_CHAINSAW
              bra     7$
5$:           cmp     ##CONST_WP_BFG
              bne     6$
              lda     ##CONST_WP_FIST
              bra     7$
6$:           cmp     ##CONST_WP_SUPERSHOTGUN
              bne     7$
              lda     ##CONST_WP_BFG
7$:           sta     .near WP_T
              jsr     .kbank ownedCan
              bcs     9$
              dec     .near WP_I
              bne     1$
              lda     .near (PL+OFS_PL_READYWEAPON)
9$:           rtl

;;; ownedCan: carry set and C = WP_T if the player owns weapon WP_T and it
;;; has ammunition (P_CheckCanSwitchWeapon is not wp_nochange).
ownedCan:     asl     a
              tax
              lda     .near (PL+OFS_PL_WEAPONOWNED),x
              beq     8$
              lda     .near WP_T
              jsr     .kbank checkCanSwitch
              cmp     ##CONST_WP_NOCHANGE
              beq     8$
              lda     .near WP_T
              sec
              rts
8$:           clc
              rts

;;; ---------------------------------------------------------------------------
;;; boolean P_CheckAmmo(player_t* player)
;;; Enough ammunition for a shot of the raised weapon?
;;; ---------------------------------------------------------------------------
              .public P_CheckAmmo
P_CheckAmmo:  jsr     .kbank checkAmmo
              rtl

checkAmmo:    ldy     ##1                   ; count
              lda     .near (PL+OFS_PL_READYWEAPON)
              cmp     ##CONST_WP_BFG
              bne     1$
              ldy     ##BFGCELLS
              bra     2$
1$:           cmp     ##CONST_WP_SUPERSHOTGUN
              bne     2$
              ldy     ##2
2$:           phy
              jsr     .kbank wInfo
              lda     abs:OFS_WI_AMMO,x     ; ammo == am_noammo: no ammunition needed
              cmp     ##CONST_AM_NOAMMO
              beq     8$
              asl     a                     ; ammo[a] >= count (signed)
              tax
              lda     .near (PL+OFS_PL_AMMO),x
              sec
              sbc     1,s
              bvc     3$
              eor     ##0x8000
3$:           bpl     8$
              ply
              lda     ##0
              rts
8$:           ply
              lda     ##1
              rts

;;; ---------------------------------------------------------------------------
;;; noiseAlert: P_NoiseAlert(player->mo): the monsters that hear the shot
;;; get the player as target. The flood runs with DBR = the sectors.
;;; ---------------------------------------------------------------------------
noiseAlert:   inc     .near validcount
              lda     .near PL_MO           ; the sound target
              sta     .near RS_TGT
              sta     dp:.tiny _Dp
              lda     .near (PL_MO+2)
              sta     .near (RS_TGT+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_MO_SUBSECTOR+2) ; X = mo->subsector->sector (its
              lda     [.tiny _Dp],y         ;   bank: the one of _g_sectors)
              tax
              ldy     ##OFS_MO_SUBSECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##OFS_SUB_SECTOR
              lda     [.tiny _Dp],y
              tax
              phb
              sep     #0x20
              lda     .near (_g_sectors+2)
              pha
              plb
              rep     #0x20
              lda     ##0
              jsr     .kbank recursiveSound
              plb
              rts

;;; recursiveSound: P_RecursiveSound(the sector X, soundblocks C, soundtarget
;;; RS_TGT), DBR = the sectors: the sound floods through the open two sided
;;; lines; a line with ML_SOUNDBLOCK lets it through once. The lines come
;;; from the lists of P_InitFlood: the other sectors of the two sided lines
;;; of sec without ML_SOUNDBLOCK (v = soundblocks), then, with soundblocks
;;; 0, those with it (v = 1). The order of the lines and a line more to the
;;; same sector do not change the result: a sector is flooded again only
;;; with fewer blocks. The state of a level: 1,s the end of the part, 3,s
;;; v, 5,s the sector, X the entry. A call for a sector that is flooded
;;; already, with as few blocks, would return at once: none, and no
;;; opening.
recursiveSound:
              tay                           ; Y = soundblocks
              lda     abs:OFS_SEC_VALIDCOUNT,x ; flooded already, with as few
              cmp     long:validcount       ;   blocks?
              bne     1$
              tya                           ; soundtraversed <= soundblocks + 1
              inc     a
              sec
              sbc     abs:OFS_SEC_SOUNDTRAVERSED,x
              bvc     0$
              eor     ##0x8000
0$:           bmi     1$
              rts
1$:           lda     long:validcount       ; validcount, soundtraversed,
              sta     abs:OFS_SEC_VALIDCOUNT,x ;   soundtarget
              tya
              inc     a
              sta     abs:OFS_SEC_SOUNDTRAVERSED,x
              lda     long:RS_TGT
              sta     abs:OFS_SEC_SOUNDTARGET,x
              lda     long:(RS_TGT+2)
              sta     abs:(OFS_SEC_SOUNDTARGET+2),x
              phx                           ; 5,s the sector
              phy                           ; 3,s v = soundblocks
              lda     long:(FL_IDX+2),x     ; 1,s the end of the entries
              pha                           ;   without ML_SOUNDBLOCK
              lda     long:FL_IDX,x         ; X = the first entry
              tax
              bra     4$
3$:           inx
              inx
4$:           txa
              cmp     1,s
              bcs     9$
              phx                           ; 1,s the entry
              lda     long:FL_ENT,x         ; X = the other sector
              tax
              lda     abs:OFS_SEC_VALIDCOUNT,x ; flooded already, with
              cmp     long:validcount       ;   soundtraversed <= v + 1: no
              bne     5$                    ;   call
              lda     5,s
              inc     a
              sec
              sbc     abs:OFS_SEC_SOUNDTRAVERSED,x
              bpl     8$
5$:           phx                           ; P_LineOpening of the line: of the
              lda     9,s                   ;   sectors X and Y = sec
              tay
              jsl     long:P_LineOpeningXY
              plx
              lda     long:(_g_openrange+2) ; closed (openrange <= 0): no
              bmi     8$
              ora     long:_g_openrange
              beq     8$
              lda     5,s                   ; P_RecursiveSound(other, v)
              jsr     .kbank recursiveSound
8$:           plx                           ; the entry
              bra     3$
9$:           lda     3,s                   ; the end of a part: after v = 0,
              bne     10$                   ;   the entries with ML_SOUNDBLOCK
              inc     a                     ;   with v = 1
              sta     3,s
              lda     5,s
              tax
              lda     long:(FL_IDX+6),x
              sta     1,s
              lda     long:(FL_IDX+4),x
              tax
              bra     4$
10$:          pla                           ; the state of the level
              pla
              pla
              rts
              .space  PAD_RS                ; (the code after keeps its address)

;;; ---------------------------------------------------------------------------
;;; fireWeapon: P_FireWeapon(player): the attack state, if the ammunition
;;; is enough, and the noise that wakes the monsters.
;;; ---------------------------------------------------------------------------
fireWeapon:   jsr     .kbank checkAmmo
              cmp     ##0
              bne     1$
              rts
1$:           lda     ##CONST_S_PLAY_ATK1
              jsr     .kbank setMoState
              jsr     .kbank wInfo
              lda     abs:OFS_WI_ATKSTATE,x
              ldx     ##.near PSPW
              jsr     .kbank setPsprite
              brl     noiseAlert

;;; ---------------------------------------------------------------------------
;;; void P_DropWeapon(player_t* player): the player died, the weapon goes
;;; down.
;;; ---------------------------------------------------------------------------
              .public P_DropWeapon
P_DropWeapon: jsr     .kbank lowerWeapon
              rtl

;;; lowerWeapon: setPsprite(ps_weapon, weaponinfo[readyweapon].downstate).
lowerWeapon:  jsr     .kbank wInfo
              lda     abs:OFS_WI_DOWNSTATE,x
              ldx     ##.near PSPW
              jmp     .kbank setPsprite

;;; ---------------------------------------------------------------------------
;;; void A_WeaponReady(player_t* player, pspdef_t* psp)
;;; The player can fire the weapon or change to another one.
;;; ---------------------------------------------------------------------------
              .public A_WeaponReady
A_WeaponReady:
              pei     dp:.tiny (_Dp+4)      ; psp, at 1,s
              jsr     .kbank argMo          ; out of the attack states of the player
              ldy     ##OFS_MO_STATE
              lda     [.tiny _Dp],y
              cmp     ##.near (states + CONST_S_PLAY_ATK1 * STATE_SIZE)
              beq     1$
              cmp     ##.near (states + CONST_S_PLAY_ATK2 * STATE_SIZE)
              bne     2$
1$:           lda     ##CONST_S_PLAY
              jsr     .kbank setMoState
2$:           lda     .near (PL+OFS_PL_READYWEAPON) ; the chainsaw idles
              cmp     ##CONST_WP_CHAINSAW
              bne     3$
              lda     1,s
              tax
              lda     abs:OFS_PSP_STATE,x
              cmp     ##.near (states + CONST_S_SAW * STATE_SIZE)
              bne     3$
              lda     ##CONST_SFX_SAWIDL
              jsr     .kbank startSound
3$:           lda     .near (PL+OFS_PL_PENDINGWEAPON) ; a change, or dead: down
              cmp     ##CONST_WP_NOCHANGE
              bne     4$
              lda     .near (PL+OFS_PL_HEALTH)
              bne     5$
4$:           jsr     .kbank lowerWeapon
              pla
              rtl
5$:           lda     .near (PL+OFS_PL_CMD+OFS_TC_BUTTONS) ; fire
              and     ##CONST_BT_ATTACK
              beq     7$
              lda     .near (PL+OFS_PL_ATTACKDOWN) ; the rocket launcher and the
              beq     6$                    ; BFG do not fire again by themselves
              lda     .near (PL+OFS_PL_READYWEAPON)
              cmp     ##CONST_WP_MISSILE
              beq     8$
              cmp     ##CONST_WP_BFG
              beq     8$
6$:           lda     ##1
              sta     .near (PL+OFS_PL_ATTACKDOWN)
              jsr     .kbank fireWeapon
              pla
              rtl
7$:           stz     .near (PL+OFS_PL_ATTACKDOWN)

              ;; bob the weapon with the movement
8$:           lda     .near _g_leveltime    ; angle = ((int16_t)leveltime * 128) & FINEMASK
              and     ##0x003f
              xba
              lsr     a
              pha
              jsl     long:finecosine       ; cos
              sta     .near WP_T
              stx     .near (WP_T+2)
              lda     .near (PL+OFS_PL_BOB) ; hi16(bob * (int32_t)bhw)
              sta     dp:.tiny _Dp
              lda     .near (PL+OFS_PL_BOB+2)
              sta     dp:.tiny (_Dp+2)
              txa
              jsr     .kbank signExt4
              jsl     long:_Mul32
              stx     .near WP_ANGLE
              lda     .near (PL+OFS_PL_BOB+2) ; + hi16((uint32_t)ahw * blw)
              jsr     .kbank signExt0
              lda     .near WP_T
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_Mul32
              txa
              sec                           ; + 1
              adc     .near WP_ANGLE
              sta     .near WP_I
              lda     3,s                   ; psp->sx
              tax
              lda     .near WP_I
              sta     abs:OFS_PSP_SX,x
              pla                           ; sy = WEAPONTOP + FixedMulAngle(bob,
              and     ##0x0fff              ;   finesine(angle & 4095))
              jsl     long:finesine
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near (PL+OFS_PL_BOB)
              ldx     .near (PL+OFS_PL_BOB+2)
              jsl     long:FixedMulAngle
              ply
              sta     abs:OFS_PSP_SY,y
              txa
              clc
              adc     ##WEAPONTOP_HI
              sta     abs:(OFS_PSP_SY+2),y
              rtl

;;; signExt4: _Dp[4-7] = C, sign extended. signExt0: _Dp[0-3] = C, the same.
signExt4:     sta     dp:.tiny (_Dp+4)
              ldx     ##0
              cmp     ##0
              bpl     1$
              dex
1$:           stx     dp:.tiny (_Dp+6)
              rts
signExt0:     sta     dp:.tiny _Dp
              ldx     ##0
              cmp     ##0
              bpl     1$
              dex
1$:           stx     dp:.tiny (_Dp+2)
              rts

;;; ---------------------------------------------------------------------------
;;; void A_ReFire(player_t* player, pspdef_t* psp)
;;; Fire again without lowering the weapon, unless a change is pending.
;;; ---------------------------------------------------------------------------
              .public A_ReFire
A_ReFire:     lda     .near (PL+OFS_PL_CMD+OFS_TC_BUTTONS)
              and     ##CONST_BT_ATTACK
              beq     1$
              lda     .near (PL+OFS_PL_PENDINGWEAPON)
              cmp     ##CONST_WP_NOCHANGE
              bne     1$
              lda     .near (PL+OFS_PL_HEALTH)
              beq     1$
              inc     .near (PL+OFS_PL_REFIRE)
              jsr     .kbank fireWeapon
              rtl
1$:           stz     .near (PL+OFS_PL_REFIRE) ; (P_CheckAmmo has no effect here)
              rtl

;;; ---------------------------------------------------------------------------
;;; void A_Lower(player_t* player, pspdef_t* psp)
;;; void A_Raise(player_t* player, pspdef_t* psp)
;;; ---------------------------------------------------------------------------
              .public A_Lower
A_Lower:      ldx     dp:.tiny (_Dp+4)      ; psp->sy += LOWERSPEED
              lda     abs:(OFS_PSP_SY+2),x
              clc
              adc     ##LOWERSPEED_HI
              sta     abs:(OFS_PSP_SY+2),x
              cmp     ##WEAPONBOTTOM_HI     ; still going down: sy < WEAPONBOTTOM
              bpl     1$
              rtl
1$:           lda     .near (PL+OFS_PL_PLAYERSTATE) ; dead: stays at the bottom
              cmp     ##CONST_PST_DEAD
              bne     2$
              stz     abs:OFS_PSP_SY,x
              lda     ##WEAPONBOTTOM_HI
              sta     abs:(OFS_PSP_SY+2),x
              rtl
2$:           lda     .near (PL+OFS_PL_HEALTH) ; no health: off the screen
              bne     3$
              lda     ##CONST_S_NULL
              ldx     ##.near PSPW
              jsr     .kbank setPsprite
              rtl
3$:           lda     .near (PL+OFS_PL_PENDINGWEAPON) ; the new weapon comes up
              sta     .near (PL+OFS_PL_READYWEAPON)
              jsr     .kbank bringUpWeapon
              rtl

              .public A_Raise
A_Raise:      ldx     dp:.tiny (_Dp+4)      ; psp->sy -= RAISESPEED
              lda     abs:(OFS_PSP_SY+2),x
              sec
              sbc     ##LOWERSPEED_HI
              sta     abs:(OFS_PSP_SY+2),x
              sec                           ; sy > WEAPONTOP: still going up
              sbc     ##WEAPONTOP_HI
              bmi     2$
              bne     1$
              lda     abs:OFS_PSP_SY,x
              beq     2$
1$:           rtl
2$:           stz     abs:OFS_PSP_SY,x      ; sy = WEAPONTOP, ready
              lda     ##WEAPONTOP_HI
              sta     abs:(OFS_PSP_SY+2),x
              jsr     .kbank wInfo
              lda     abs:OFS_WI_READYSTATE,x
              ldx     ##.near PSPW
              jsr     .kbank setPsprite
              rtl

;;; fireSomething: A_FireSomething(player, C): the flash state + C.
fireSomething:
              pha
              jsr     .kbank wInfo
              pla
              clc
              adc     abs:OFS_WI_FLASHSTATE,x
              ldx     ##.near PSPF
              jmp     .kbank setPsprite

;;; ---------------------------------------------------------------------------
;;; void A_GunFlash(player_t* player, pspdef_t* psp)
;;; ---------------------------------------------------------------------------
              .public A_GunFlash
A_GunFlash:   lda     ##CONST_S_PLAY_ATK2
              jsr     .kbank setMoState
              lda     ##0
              jsr     .kbank fireSomething
              rtl

;;; ---------------------------------------------------------------------------
;;; void A_Punch(player_t* player, pspdef_t* psp)
;;; void A_Saw(player_t* player, pspdef_t* psp)
;;; ---------------------------------------------------------------------------
              .public A_Punch
A_Punch:      lda     ##10                  ; damage = (P_Random() % 10 + 1) << 1
              jsr     .kbank randMod
              inc     a
              asl     a
              ldx     .near (PL+OFS_PL_POWERS+2*CONST_PW_STRENGTH) ; berserk: * 10
              beq     1$
              sta     .near WP_T
              asl     a
              asl     a
              clc
              adc     .near WP_T
              asl     a
1$:           sta     .near WP_DAMAGE
              jsr     .kbank meleeAngle
              lda     ##0                   ; MELEERANGE
              jsr     .kbank meleeAttack
              lda     .near _g_linetarget
              ora     .near (_g_linetarget+2)
              bne     2$
              rtl
2$:           lda     ##CONST_SFX_PUNCH
              jsr     .kbank startSound
              jsr     .kbank angleToTarget  ; turn to face the target
              pha
              jsr     .kbank argMo
              pla
              ldy     ##OFS_MO_ANGLE
              sta     [.tiny _Dp],y
              iny
              iny
              txa
              sta     [.tiny _Dp],y
              rtl

              .public A_Saw
A_Saw:        lda     ##10                  ; damage = 2 * (P_Random() % 10 + 1)
              jsr     .kbank randMod
              inc     a
              asl     a
              sta     .near WP_DAMAGE
              jsr     .kbank meleeAngle
              lda     ##1                   ; MELEERANGE + 1: the puff shows
              jsr     .kbank meleeAttack
              lda     .near _g_linetarget
              ora     .near (_g_linetarget+2)
              bne     1$
              lda     ##CONST_SFX_SAWFUL    ; no target
              jsr     .kbank startSound
              rtl
1$:           lda     ##CONST_SFX_SAWHIT
              jsr     .kbank startSound
              jsr     .kbank angleToTarget  ; turn toward the target: d = angle - mo->angle
              sta     .near WP_ANGLE
              stx     .near (WP_ANGLE+2)
              jsr     .kbank argMo
              ldy     ##OFS_MO_ANGLE
              lda     .near WP_ANGLE
              sec
              sbc     [.tiny _Dp],y
              sta     .near WP_T
              iny
              iny
              lda     .near (WP_ANGLE+2)
              sbc     [.tiny _Dp],y
              sta     .near (WP_T+2)
              cmp     ##0x8000              ; d > ANG180 (unsigned)
              bcc     5$
              bne     2$
              lda     .near WP_T
              beq     5$
2$:           lda     .near WP_T            ; d < -ANG90 / 20: angle + ANG90 / 21
              cmp     ##.word0 NANG90_20
              lda     .near (WP_T+2)
              sbc     ##.word2 NANG90_20
              bcs     3$
              lda     .near WP_ANGLE
              clc
              adc     ##.word0 ANG90_21
              tax
              lda     .near (WP_ANGLE+2)
              adc     ##.word2 ANG90_21
              bra     8$
3$:           ldy     ##OFS_MO_ANGLE        ; else mo->angle - ANG90 / 20
              lda     [.tiny _Dp],y
              sec
              sbc     ##.word0 ANG90_20
              tax
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     ##.word2 ANG90_20
              bra     8$
5$:           lda     ##.word0 ANG90_20     ; d > ANG90 / 20: angle - ANG90 / 21
              cmp     .near WP_T
              lda     ##.word2 ANG90_20
              sbc     .near (WP_T+2)
              bcs     6$
              lda     .near WP_ANGLE
              sec
              sbc     ##.word0 ANG90_21
              tax
              lda     .near (WP_ANGLE+2)
              sbc     ##.word2 ANG90_21
              bra     8$
6$:           ldy     ##OFS_MO_ANGLE        ; else mo->angle + ANG90 / 20
              lda     [.tiny _Dp],y
              clc
              adc     ##.word0 ANG90_20
              tax
              iny
              iny
              lda     [.tiny _Dp],y
              adc     ##.word2 ANG90_20
8$:           ldy     ##(OFS_MO_ANGLE+2)    ; mo->angle = A:X
              sta     [.tiny _Dp],y
              dey
              dey
              txa
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_FLAGS        ; flags |= MF_JUSTATTACKED
              lda     [.tiny _Dp],y
              ora     ##CONST_MF_JUSTATTACKED_LO
              sta     [.tiny _Dp],y
              rtl

;;; meleeAngle: WP_ANGLE = mo->angle + ((t - P_Random()) << 18), t = P_Random().
meleeAngle:   jsr     .kbank argMo
              ldy     ##OFS_MO_ANGLE
              lda     [.tiny _Dp],y
              sta     .near WP_ANGLE
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (WP_ANGLE+2)
              ;; fall into spread

;;; spread: WP_ANGLE.hi += (t - P_Random()) << 2, t = P_Random().
spread:       jsl     long:P_Random
              pha
              jsl     long:P_Random
              eor     ##0xffff
              sec
              adc     1,s
              asl     a
              asl     a
              clc
              adc     .near (WP_ANGLE+2)
              sta     .near (WP_ANGLE+2)
              pla
              rts

;;; meleeAttack: slope = P_AimLineAttack(mo, WP_ANGLE, MELEERANGE + C), then
;;; P_LineAttack(mo, WP_ANGLE, MELEERANGE + C, slope, WP_DAMAGE).
meleeAttack:  pha                           ; the range, low word
              jsr     .kbank argMo
              lda     1,s
              sta     dp:.tiny (_Dp+4)
              lda     ##CONST_MELEERANGE_HI
              sta     dp:.tiny (_Dp+6)
              lda     .near WP_ANGLE
              ldx     .near (WP_ANGLE+2)
              jsl     long:P_AimLineAttack
              ply                           ; (the range)
              sta     .near WP_T            ; the slope
              stx     .near (WP_T+2)
              lda     .near WP_DAMAGE       ; damage, slope
              pha
              lda     .near (WP_T+2)
              pha
              lda     .near WP_T
              pha
              jsr     .kbank argMo
              sty     dp:.tiny (_Dp+4)
              lda     ##CONST_MELEERANGE_HI
              sta     dp:.tiny (_Dp+6)
              lda     .near WP_ANGLE
              ldx     .near (WP_ANGLE+2)
              jsl     long:P_LineAttack
              pla
              pla
              pla
              rts

;;; angleToTarget: X:C = R_PointToAngle2(mo->x, mo->y, linetarget->x,
;;; linetarget->y) = R_PointToAngle3(dx, dy).
angleToTarget:
              lda     .near _g_linetarget
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_linetarget+2)
              sta     dp:.tiny (_Dp+6)
              jsr     .kbank argMo
              sec                           ; dy
              ldy     ##OFS_MO_Y
              lda     [.tiny (_Dp+4)],y
              sbc     [.tiny _Dp],y
              sta     .near WP_T
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sbc     [.tiny _Dp],y
              sta     .near (WP_T+2)
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
              lda     .near WP_T
              sta     dp:.tiny _Dp
              lda     .near (WP_T+2)
              sta     dp:.tiny (_Dp+2)
              pla
              jsl     long:R_PointToAngle3
              rts

;;; randMod: C = P_Random() % C.
randMod:      pha
              jsl     long:P_Random
              plx
              jsl     long:_Mod16
              rts

;;; useAmmo: player->ammo[weaponinfo[readyweapon].ammo]--.
useAmmo:      jsr     .kbank wInfo
              lda     abs:OFS_WI_AMMO,x
              asl     a
              tax
              dec     .near (PL+OFS_PL_AMMO),x
              rts

;;; ---------------------------------------------------------------------------
;;; void A_FireMissile(player_t* player, pspdef_t* psp)
;;; ---------------------------------------------------------------------------
              .public A_FireMissile
A_FireMissile:
              lda     ##CONST_SFX_RLAUNC
              jsr     .kbank startSound
              jsr     .kbank useAmmo
              jsr     .kbank argMo
              jsl     long:P_SpawnPlayerMissile
              rtl

;;; bulletSlope: P_BulletSlope(mo): the slope to a target in front, or a
;;; little to the left or right.
bulletSlope:  jsr     .kbank argMo
              ldy     ##OFS_MO_ANGLE
              lda     [.tiny _Dp],y
              sta     .near WP_ANGLE
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (WP_ANGLE+2)
              jsr     .kbank aimAt
              bne     9$
              lda     .near (WP_ANGLE+2)    ; an += 1 << 26
              clc
              adc     ##0x0400
              sta     .near (WP_ANGLE+2)
              jsr     .kbank aimAt
              bne     9$
              lda     .near (WP_ANGLE+2)    ; an -= 2 << 26
              sec
              sbc     ##0x0800
              sta     .near (WP_ANGLE+2)
              jsr     .kbank aimAt
9$:           rts

;;; aimAt: bulletslope = P_AimLineAttack(mo, WP_ANGLE, 16 * 64 * FRACUNIT);
;;; Z clear if there is a linetarget.
aimAt:        jsr     .kbank argMo
              stz     dp:.tiny (_Dp+4)
              lda     ##1024
              sta     dp:.tiny (_Dp+6)
              lda     .near WP_ANGLE
              ldx     .near (WP_ANGLE+2)
              jsl     long:P_AimLineAttack
              sta     .near WP_SLOPE
              stx     .near (WP_SLOPE+2)
              lda     .near _g_linetarget
              ora     .near (_g_linetarget+2)
              rts

;;; gunShot: P_GunShot(mo, accurate C): damage 5 * (P_Random() % 3 + 1), a
;;; spread when not accurate.
gunShot:      pha
              lda     ##3
              jsr     .kbank randMod
              inc     a
              sta     .near WP_DAMAGE
              asl     a
              asl     a
              clc
              adc     .near WP_DAMAGE
              sta     .near WP_DAMAGE
              jsr     .kbank argMo
              ldy     ##OFS_MO_ANGLE
              lda     [.tiny _Dp],y
              sta     .near WP_ANGLE
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (WP_ANGLE+2)
              pla
              bne     1$
              jsr     .kbank spread
1$:           lda     .near WP_DAMAGE       ; P_LineAttack(mo, angle, MISSILERANGE,
              pha                           ;   bulletslope, damage)
              lda     .near (WP_SLOPE+2)
              pha
              lda     .near WP_SLOPE
              pha
              jsr     .kbank argMo
              stz     dp:.tiny (_Dp+4)
              lda     ##CONST_MISSILERANGE_HI
              sta     dp:.tiny (_Dp+6)
              lda     .near WP_ANGLE
              ldx     .near (WP_ANGLE+2)
              jsl     long:P_LineAttack
              pla
              pla
              pla
              rts

;;; notRefire: C = !player->refire.
notRefire:    lda     .near (PL+OFS_PL_REFIRE)
              beq     1$
              lda     ##0
              rts
1$:           lda     ##1
              rts

;;; ---------------------------------------------------------------------------
;;; void A_FirePistol(player_t* player, pspdef_t* psp)
;;; void A_FireShotgun(player_t* player, pspdef_t* psp)
;;; void A_FireCGun(player_t* player, pspdef_t* psp)
;;; ---------------------------------------------------------------------------
              .public A_FirePistol
A_FirePistol: lda     ##CONST_SFX_PISTOL
              jsr     .kbank startSound
              lda     ##CONST_S_PLAY_ATK2
              jsr     .kbank setMoState
              jsr     .kbank useAmmo
              lda     ##0
              jsr     .kbank fireSomething
              jsr     .kbank bulletSlope
              jsr     .kbank notRefire
              jsr     .kbank gunShot
              rtl

              .public A_FireShotgun
A_FireShotgun:
              lda     ##CONST_SFX_SHOTGN
              jsr     .kbank startSound
              lda     ##CONST_S_PLAY_ATK2
              jsr     .kbank setMoState
              jsr     .kbank useAmmo
              lda     ##0
              jsr     .kbank fireSomething
              jsr     .kbank bulletSlope
              lda     ##7                   ; seven pellets
              sta     .near WP_I
1$:           lda     ##0
              jsr     .kbank gunShot
              dec     .near WP_I
              bne     1$
              rtl

              .public A_FireCGun
A_FireCGun:   pei     dp:.tiny (_Dp+4)      ; psp
              jsr     .kbank wInfo          ; the sound only with ammunition
              lda     abs:OFS_WI_AMMO,x
              asl     a
              tax
              lda     .near (PL+OFS_PL_AMMO),x
              bne     1$
              pla
              rtl
1$:           lda     ##CONST_SFX_PISTOL
              jsr     .kbank startSound
              lda     ##CONST_S_PLAY_ATK2
              jsr     .kbank setMoState
              jsr     .kbank useAmmo
              plx                           ; flash + (psp->state - &states[S_CHAIN1])
              lda     abs:OFS_PSP_STATE,x
              sec
              sbc     ##.near (states + CONST_S_CHAIN1 * STATE_SIZE)
              lsr     a                     ; / STATE_SIZE
              lsr     a
              lsr     a
              lsr     a
              jsr     .kbank fireSomething
              jsr     .kbank bulletSlope
              jsr     .kbank notRefire
              jsr     .kbank gunShot
              rtl

;;; ---------------------------------------------------------------------------
;;; void A_Light0(player_t* player, pspdef_t* psp), A_Light1, A_Light2
;;; ---------------------------------------------------------------------------
              .public A_Light0, A_Light1, A_Light2
A_Light0:     stz     .near (PL+OFS_PL_EXTRALIGHT)
              rtl
A_Light1:     lda     ##1
              sta     .near (PL+OFS_PL_EXTRALIGHT)
              rtl
A_Light2:     lda     ##2
              sta     .near (PL+OFS_PL_EXTRALIGHT)
              rtl

;;; ---------------------------------------------------------------------------
;;; void P_SetupPsprites(player_t* player)
;;; The gun comes up at the start of a level.
;;; ---------------------------------------------------------------------------
              .public P_SetupPsprites
P_SetupPsprites:
              stz     .near (PSPW+OFS_PSP_STATE)
              stz     .near (PSPW+OFS_PSP_STATE+2)
              stz     .near (PSPF+OFS_PSP_STATE)
              stz     .near (PSPF+OFS_PSP_STATE+2)
              lda     .near (PL+OFS_PL_READYWEAPON)
              sta     .near (PL+OFS_PL_PENDINGWEAPON)
              jsr     .kbank bringUpWeapon
              rtl

;;; ---------------------------------------------------------------------------
;;; void P_MovePsprites(player_t* player)
;;; Each tic: the tics of the weapon and flash sprites, and their states.
;;; ---------------------------------------------------------------------------
              .public P_MovePsprites
P_MovePsprites:
              ldx     ##.near PSPW
              jsr     .kbank tickPsprite
              ldx     ##.near PSPF
              jsr     .kbank tickPsprite
              lda     .near (PSPW+OFS_PSP_SX) ; the flash follows the weapon
              sta     .near (PSPF+OFS_PSP_SX)
              lda     .near (PSPW+OFS_PSP_SY)
              sta     .near (PSPF+OFS_PSP_SY)
              lda     .near (PSPW+OFS_PSP_SY+2)
              sta     .near (PSPF+OFS_PSP_SY+2)
              rtl

;;; tickPsprite: if (psp->state && psp->tics != -1 && !--psp->tics)
;;; P_SetPsprite(player, psp, psp->state->nextstate), psp at near X.
tickPsprite:  lda     abs:OFS_PSP_STATE,x
              ora     abs:(OFS_PSP_STATE+2),x
              beq     9$
              lda     abs:OFS_PSP_TICS,x
              cmp     ##0xffff
              beq     9$
              dec     a
              sta     abs:OFS_PSP_TICS,x
              bne     9$
              ldy     abs:OFS_PSP_STATE,x
              lda     abs:OFS_ST_NEXTSTATE,y
              jmp     .kbank setPsprite
9$:           rts

;;; The weapons (weapontype_t order): the ammo, then the states to raise,
;;; lower, hold ready, fire and flash (weaponinfo_t of d_items.c).
              .section cnear, rodata
              .public weaponinfo
weaponinfo:   .word   CONST_AM_NOAMMO, CONST_S_PUNCHUP, CONST_S_PUNCHDOWN
              .word   CONST_S_PUNCH, CONST_S_PUNCH1, CONST_S_NULL ; fist
              .word   CONST_AM_CLIP, CONST_S_PISTOLUP, CONST_S_PISTOLDOWN
              .word   CONST_S_PISTOL, CONST_S_PISTOL1, CONST_S_PISTOLFLASH ; pistol
              .word   CONST_AM_SHELL, CONST_S_SGUNUP, CONST_S_SGUNDOWN
              .word   CONST_S_SGUN, CONST_S_SGUN1, CONST_S_SGUNFLASH1 ; shotgun
              .word   CONST_AM_CLIP, CONST_S_CHAINUP, CONST_S_CHAINDOWN
              .word   CONST_S_CHAIN, CONST_S_CHAIN1, CONST_S_CHAINFLASH1 ; chaingun
              .word   CONST_AM_MISL, CONST_S_MISSILEUP, CONST_S_MISSILEDOWN
              .word   CONST_S_MISSILE, CONST_S_MISSILE1, CONST_S_MISSILEFLASH1 ; missile launcher
              .word   CONST_AM_CLIP, CONST_S_CHAINUP, CONST_S_CHAINDOWN
              .word   CONST_S_CHAIN, CONST_S_CHAIN1, CONST_S_CHAINFLASH1 ; chaingun, was the plasma rifle
              .word   CONST_AM_MISL, CONST_S_MISSILEUP, CONST_S_MISSILEDOWN
              .word   CONST_S_MISSILE, CONST_S_MISSILE1, CONST_S_MISSILEFLASH1 ; missile launcher, was the BFG 9000
              .word   CONST_AM_NOAMMO, CONST_S_SAWUP, CONST_S_SAWDOWN
              .word   CONST_S_SAW, CONST_S_SAW1, CONST_S_NULL ; chainsaw
              .word   CONST_AM_SHELL, CONST_S_SGUNUP, CONST_S_SGUNDOWN
              .word   CONST_S_SGUN, CONST_S_SGUN1, CONST_S_SGUNFLASH1 ; shotgun, was the super shotgun

;;; ---------------------------------------------------------------------------
;;; P_InitFlood: the lists of the sound flood of the map, from the end of
;;; P_InitSightTables of src/iigs/p_sight65.s (LNSEC and SEC58 there and
;;; LN36 of src/iigs/p_map65.s are ready). The sector at offset s (its
;;; bank: the sectors) has room for linecount entries: FL_IDX + s its first
;;; entry, + 2 the end of the entries without ML_SOUNDBLOCK (up from the
;;; first), + 4 the first entry with ML_SOUNDBLOCK (down from the end), + 6
;;; the end. An entry (FL_ENT, a word) is the other sector of a line of s
;;; with ML_TWOSIDED, a back side and another sector. One walk of the
;;; lines. The temporaries of the weapons are free at the load. At the end,
;;; a new tag of the guard counts (GW_TAB) for the level.
;;; ---------------------------------------------------------------------------
FB_N          .equ    WP_SLOPE        ; 2 * the sector number
FB_P          .equ    (WP_SLOPE+2)    ; the room of the next sector
FB_S          .equ    WP_T            ; the sectors of the line: front | back << 8
FB_R          .equ    WP_DAMAGE       ; bit 15: the line has ML_SOUNDBLOCK
              .section coldcode, text
              .public P_InitFlood
P_InitFlood:  lda     .near (_g_lines+2)    ; _Dp[0-3] = {0, the bank of the
              sta     dp:.tiny (_Dp+2)      ;   lines}: a field of a line at
              stz     dp:.tiny _Dp          ;   [_Dp] + the line + its offset;
              lda     .near (_g_sectors+2)  ;   _Dp[4-7] the same for the
              sta     dp:.tiny (_Dp+6)      ;   sectors
              stz     dp:.tiny (_Dp+4)
              stz     .near FB_P            ; each sector: room for its
              lda     .near _g_numsectors   ;   linecount entries
              asl     a
1$:           dec     a
              dec     a
              bmi     2$
              sta     .near FB_N
              tax
              lda     long:SEC58,x
              tax                           ; X = the sector
              clc
              adc     ##OFS_SEC_LINECOUNT
              tay
              lda     .near FB_P
              sta     long:FL_IDX,x
              sta     long:(FL_IDX+2),x
              lda     [.tiny (_Dp+4)],y
              asl     a                     ; (C = 0: linecount < 0x8000)
              adc     .near FB_P
              sta     .near FB_P
              sta     long:(FL_IDX+4),x
              sta     long:(FL_IDX+6),x
              lda     .near FB_N
              bra     1$
2$:           lda     .near _g_numlines     ; the lines
              asl     a
              tax                           ; X = 2 * the line
3$:           dex
              dex
              bpl     4$
              lda     .near GW_TAG          ; a new tag for GW_TAB of
              sec                           ;   src/iigs/p_path65.s: 255 down
              sbc     ##0x100               ;   to 1; at the first level and
              bcc     31$                   ;   after tag 1, the table gets
              bne     32$                   ;   zeros
31$:          ldx     ##(GW_MAXB * 10 - 2)
              lda     ##0
33$:          sta     long:GW_TAB,x
              dex
              dex
              bpl     33$
              lda     ##0xff00
32$:          sta     .near GW_TAG
              rtl
4$:           lda     long:LNSEC,x          ; two sectors? (front | back <<
              sta     .near FB_S            ;   8 and back | front << 8 differ)
              xba
              cmp     .near FB_S
              beq     3$
              lda     long:LN36,x           ; ML_TWOSIDED, ML_SOUNDBLOCK
              clc
              adc     ##OFS_LINE_FLAGS
              tay
              lda     [.tiny _Dp],y
              bit     ##CONST_ML_TWOSIDED
              beq     3$
              phx                           ; the line
              and     ##CONST_ML_SOUNDBLOCK
              beq     5$
              lda     ##0x8000
5$:           sta     .near FB_R
              lda     .near FB_S            ; 1,s the front sector (SEC58)
              and     ##0x00ff
              asl     a
              tax
              lda     long:SEC58,x
              pha
              lda     .near (FB_S+1)        ; Y = the back sector
              and     ##0x00ff
              asl     a
              tax
              lda     long:SEC58,x
              tay
              lda     1,s                   ; the back in the list of the
              tax                           ;   front
              jsr     .kbank fbOne
              tya                           ; the front in the list of the
              tax                           ;   back
              ply
              jsr     .kbank fbOne
              plx
              bra     3$

;;; fbOne: the entry Y in the list of the sector X: without ML_SOUNDBLOCK
;;; (FB_R >= 0) up from the first entry, with it down from the end.
fbOne:        bit     .near FB_R
              bmi     1$
              lda     long:(FL_IDX+2),x
              inc     a
              inc     a
              sta     long:(FL_IDX+2),x
              bra     2$
1$:           lda     long:(FL_IDX+4),x
              dec     a
              dec     a
              sta     long:(FL_IDX+4),x
              inc     a
              inc     a
2$:           tax                           ; X = the entry + 2
              tya
              sta     long:(FL_ENT-2),x
              rts
              .space  1                     ; (232 bytes: the first-fit placement
                                            ;   puts it in Code5g, and no other cold
                                            ;   code moves)
