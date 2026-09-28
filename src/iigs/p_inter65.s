;;; Interactions in 65816 assembly, Doom8088: Apple IIgs Edition.
;;;
;;; p_inter.c with the same results: the pickups
;;; (P_TouchSpecialThing, P_GivePower and the other give functions), the
;;; damage (P_DamageMobj) and the deaths (P_KillMobj). There is one player
;;; (_g_player). The constants of the file (initial_health, maxammo, ...)
;;; stay in C.

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


              .extern _Dp, _g_player, _g_gameskill, _g_totallive, mobjinfo, states
              .extern weaponinfo, automapmode, P_Random, P_RemoveMobj, S_StartSound
              .extern P_SetMobjState, P_SpawnMobj, P_DropWeapon, AM_Stop, I_Error
              .extern R_PointToAngle3, FixedMulAngle, finesine, finecosine
              .extern IIGS_MulLo16, _Mul32, _Div32, _Div16

PL            .equ    _g_player
BONUSADD      .equ    6
PICKUP_SOUND  .equ    0x8000          ; s_sound.h
AM_ACTIVE     .equ    1               ; am_active, am_map.h

              .section znear, bss
IN_SPECIAL:   .space  4               ; P_TouchSpecialThing: the special thing
IN_SOUND:     .space  2               ;   the pickup sound
IN_MSG:       .space  4               ;   the message
IN_T:         .space  4
IN_I:         .space  2
IN_AMMO:      .space  2               ; giveAmmo: the ammo type
IN_OLD:       .space  2               ;   the ammo before
IN_WEAPON:    .space  2               ; giveWeapon: the weapon
DM_TARGET:    .space  4               ; P_DamageMobj: target
DM_INFL:      .space  4               ;   inflictor
DM_SOURCE:    .space  4               ;   source
DM_DAMAGE:    .space  2               ;   damage
DM_PLAYER:    .space  2               ;   1: target is the player
DM_ANG:       .space  4
DM_THRUST:    .space  4
DM_INFO:      .space  2               ;   &mobjinfo[target->type] (near)
DM_T:         .space  4

              .section cfar, rodata
msgArmor:     .asciz  "Picked up the armor."
msgMega:      .asciz  "Picked up the MegaArmor!"
msgHthBonus:  .asciz  "Picked up a health bonus."
msgArmBonus:  .asciz  "Picked up an armor bonus."
msgStim:      .asciz  "Picked up a stimpack."
msgMedikit:   .asciz  "Picked up a medikit."   ; GOTMEDIKIT and GOTMEDINEED
msgSuper:     .asciz  "Supercharge!"
msgBlueCard:  .asciz  "Picked up a blue keycard."
msgYelwCard:  .asciz  "Picked up a yellow keycard."
msgRedCard:   .asciz  "Picked up a red keycard."
msgInvis:     .asciz  "Partial Invisibility"
msgSuit:      .asciz  "Radiation Shielding Suit"
msgMap:       .asciz  "Computer Area Map"
msgVisor:     .asciz  "Light Amplification Visor"
msgClip:      .asciz  "Picked up a clip."
msgClipBox:   .asciz  "Picked up a box of bullets."
msgRocket:    .asciz  "Picked up a rocket."
msgRockBox:   .asciz  "Picked up a box of rockets."
msgShells:    .asciz  "Picked up 4 shotgun shells."
msgShellBox:  .asciz  "Picked up a box of shotgun shells"
msgBackpack:  .asciz  "Picked up a backpack full of ammo"
msgChaingun:  .asciz  "You got the chaingun!"
msgChainsaw:  .asciz  "A chainsaw!  Find some meat!"
msgLauncher:  .asciz  "You got the rocket launcher!"
msgShotgun:   .asciz  "You got the shotgun!"
errUnknown:   .asciz  "P_SpecialThing: Unknown gettable thing"
;;; clipammo[] and clipammo[] / 2 for each ammo type
clipAmmo:     .word   10, 4, 1, 20
halfClip:     .word   5, 2, 0, 10
;;; the tics of each power: INVULNTICS, strength, INVISTICS, IRONTICS,
;;; allmap, INFRATICS (doomdef.h)
powerTics:    .word   30 * CONST_TICRATE, 1, 60 * CONST_TICRATE, 60 * CONST_TICRATE
              .word   1, 120 * CONST_TICRATE

;;; ---------------------------------------------------------------------------
;;; void P_TouchSpecialThing(mobj_t __far* special, mobj_t __far* toucher)
;;;   In: _Dp[0-3] = special, _Dp[4-7] = toucher (the player).
;;; The player picks up the special thing within its reach (by sprite,
;;; pickTab): the message, the pickup sound, the item count, and the thing
;;; goes away.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public P_TouchSpecialThing
P_TouchSpecialThing:
              lda     dp:.tiny _Dp
              sta     .near IN_SPECIAL
              lda     dp:.tiny (_Dp+2)
              sta     .near (IN_SPECIAL+2)
              ldy     ##OFS_MO_Z            ; delta = special->z - toucher->z
              lda     [.tiny _Dp],y
              sec
              sbc     [.tiny (_Dp+4)],y
              sta     .near IN_T
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     [.tiny (_Dp+4)],y
              sta     .near (IN_T+2)
              ldy     ##OFS_MO_HEIGHT       ; toucher->height < delta: out of reach
              lda     [.tiny (_Dp+4)],y
              cmp     .near IN_T
              ldy     ##(OFS_MO_HEIGHT+2)
              lda     [.tiny (_Dp+4)],y
              sbc     .near (IN_T+2)
              bvc     1$
              eor     ##0x8000
1$:           bmi     9$
              lda     .near IN_T            ; delta < -8 * FRACUNIT: out of reach
              cmp     ##0
              lda     .near (IN_T+2)
              sbc     ##0xfff8
              bvc     2$
              eor     ##0x8000
2$:           bmi     9$
              ldy     ##OFS_MO_HEALTH       ; a dead toucher: no
              lda     [.tiny (_Dp+4)],y
              beq     9$
              bmi     9$
              lda     ##CONST_SFX_ITEMUP
              sta     .near IN_SOUND
              ldy     ##OFS_MO_SPRITE       ; the sprite in pickTab
              lda     [.tiny _Dp],y
              sta     .near IN_T
              ldx     ##0
3$:           lda     long:pickTab,x
              cmp     .near IN_T
              beq     4$
              txa
              clc
              adc     ##10
              tax
              cpx     ##(pickTab_end - pickTab)
              bcc     3$
              lda     ##.word0 errUnknown
              sta     dp:.tiny _Dp
              lda     ##.word2 errUnknown
              sta     dp:.tiny (_Dp+2)
              jmp     long:I_Error
9$:           rtl
4$:           lda     long:(pickTab+4),x    ; the message
              sta     .near IN_MSG
              lda     long:(pickTab+6),x
              sta     .near (IN_MSG+2)
              lda     long:(pickTab+8),x    ; the routine, C = its argument;
              jsr     (.kbank (pickTab+2),x) ; carry clear: not picked up
              bcc     9$
              lda     .near IN_MSG          ; the message (not for a card that
              ora     .near (IN_MSG+2)      ; the player has)
              beq     5$
              lda     .near IN_MSG
              sta     .near (PL+OFS_PL_MESSAGE)
              lda     .near (IN_MSG+2)
              sta     .near (PL+OFS_PL_MESSAGE+2)
5$:           jsr     .kbank specialArg     ; an item to count
              ldy     ##(OFS_MO_FLAGS+2)
              lda     [.tiny _Dp],y
              and     ##CONST_MF_COUNTITEM_HI
              beq     6$
              inc     .near (PL+OFS_PL_ITEMCOUNT)
6$:           jsl     long:P_RemoveMobj     ; the thing goes away
              lda     .near (PL+OFS_PL_BONUSCOUNT)
              clc
              adc     ##BONUSADD
              sta     .near (PL+OFS_PL_BONUSCOUNT)
              jsr     .kbank playerMo       ; S_StartSound(player->mo, sound | PICKUP_SOUND)
              lda     .near IN_SOUND
              ora     ##PICKUP_SOUND
              jmp     long:S_StartSound

;;; specialArg: _Dp[0-3] = IN_SPECIAL. playerMo: _Dp[0-3] = the mobj of
;;; the player.
specialArg:   lda     .near IN_SPECIAL
              sta     dp:.tiny _Dp
              lda     .near (IN_SPECIAL+2)
              sta     dp:.tiny (_Dp+2)
              rts
playerMo:     lda     .near (PL+OFS_PL_MO)
              sta     dp:.tiny _Dp
              lda     .near (PL+OFS_PL_MO+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; The pickups: C = the argument of pickTab. Out: carry set if the player
;;; takes the thing.

;;; pkArmor: P_GiveArmor(player, C): armortype C with C * 100 points, when
;;; that is more than now.
pkArmor:      pha
              ldx     ##100
              jsl     long:IIGS_MulLo16
              cmp     .near (PL+OFS_PL_ARMORPOINTS) ; armorpoints >= hits: no
              beq     1$
              bmi     1$                    ; (signed, small values)
              sta     .near (PL+OFS_PL_ARMORPOINTS)
              pla
              sta     .near (PL+OFS_PL_ARMORTYPE)
              sec
              rts
1$:           pla
              clc
              rts

;;; pkHealthBonus: health + 1, at most 200.
pkHealthBonus:
              lda     .near (PL+OFS_PL_HEALTH)
              inc     a
              cmp     ##201
              bmi     1$
              lda     ##200
1$:           bra     setHealth

;;; pkSoul: health + 100, at most 200; the power-up sound.
pkSoul:       lda     ##CONST_SFX_GETPOW
              sta     .near IN_SOUND
              lda     .near (PL+OFS_PL_HEALTH)
              clc
              adc     ##100
              cmp     ##201
              bmi     setHealth
              lda     ##200
              ;; fall into setHealth

;;; setHealth: player->health = player->mo->health = C; carry set.
setHealth:    sta     .near (PL+OFS_PL_HEALTH)
              pha
              jsr     .kbank playerMo
              pla
              ldy     ##OFS_MO_HEALTH
              sta     [.tiny _Dp],y
              sec
              rts

;;; pkArmorBonus: armorpoints + 1, at most 200; green armor if none.
pkArmorBonus: lda     .near (PL+OFS_PL_ARMORPOINTS)
              inc     a
              cmp     ##201
              bmi     1$
              lda     ##200
1$:           sta     .near (PL+OFS_PL_ARMORPOINTS)
              lda     .near (PL+OFS_PL_ARMORTYPE)
              bne     2$
              lda     ##1
              sta     .near (PL+OFS_PL_ARMORTYPE)
2$:           sec
              rts

;;; pkCard: the card C (no message when the player has it already).
pkCard:       asl     a
              tax
              lda     abs:.near (PL+OFS_PL_CARDS),x
              beq     1$
              stz     .near IN_MSG
              stz     .near (IN_MSG+2)
              sec                           ; (P_GiveCard: nothing)
              rts
1$:           lda     ##BONUSADD            ; P_GiveCard: bonuscount = BONUSADD
              sta     .near (PL+OFS_PL_BONUSCOUNT)
              lda     ##1
              sta     abs:.near (PL+OFS_PL_CARDS),x
              sec
              rts

;;; pkBody: P_GiveBody(player, C).
pkBody:       ;; fall into giveBody

;;; giveBody: P_GiveBody(player, C): health + C, at most 100, when the
;;; health is below 100. Out: carry.
giveBody:     ldx     .near (PL+OFS_PL_HEALTH)
              cpx     ##100                 ; health >= 100: no (signed)
              bmi     1$
              clc
              rts
1$:           clc
              adc     .near (PL+OFS_PL_HEALTH)
              cmp     ##101
              bmi     setHealth
              lda     ##100
              bra     setHealth

;;; pkPower: P_GivePower(player, C), the power-up sound.
pkPower:      jsr     .kbank givePower
              bcc     1$
              lda     ##CONST_SFX_GETPOW
              sta     .near IN_SOUND
1$:           rts

;;; pkClip: a clip: P_GiveAmmo(player, am_clip, dropped ? 0 : 1).
pkClip:       jsr     .kbank specialArg
              ldy     ##(OFS_MO_FLAGS+2)
              ldx     ##1
              lda     [.tiny _Dp],y
              and     ##CONST_MF_DROPPED_HI
              beq     1$
              dex
1$:           lda     ##CONST_AM_CLIP
              jmp     .kbank giveAmmo

;;; pkAmmo: P_GiveAmmo(player, C & 0xff, C >> 8).
pkAmmo:       pha
              xba
              and     ##0x00ff
              tax
              pla
              and     ##0x00ff
              jmp     .kbank giveAmmo

;;; pkBackpack: twice the maximum ammo (once), and a clip of each ammo.
pkBackpack:   lda     .near (PL+OFS_PL_BACKPACK)
              bne     2$
              ldx     ##(2 * CONST_NUMAMMO - 2)
1$:           lda     abs:.near (PL+OFS_PL_MAXAMMO),x
              asl     a
              sta     abs:.near (PL+OFS_PL_MAXAMMO),x
              dex
              dex
              bpl     1$
              lda     ##1
              sta     .near (PL+OFS_PL_BACKPACK)
2$:           stz     .near IN_I
3$:           lda     .near IN_I
              ldx     ##1
              jsr     .kbank giveAmmo
              inc     .near IN_I
              lda     .near IN_I
              cmp     ##CONST_NUMAMMO
              bcc     3$
              sec
              rts

;;; pkWeapon: P_GiveWeapon(player, C & 0xff, dropped), dropped only when
;;; C >> 8 is 1 and the thing is MF_DROPPED; the weapon sound.
pkWeapon:     pha
              and     ##0x00ff
              sta     .near IN_WEAPON
              pla
              xba
              and     ##0x00ff
              beq     1$
              jsr     .kbank specialArg
              ldy     ##(OFS_MO_FLAGS+2)
              lda     [.tiny _Dp],y
              and     ##CONST_MF_DROPPED_HI
1$:           jsr     .kbank giveWeapon
              bcc     2$
              lda     ##CONST_SFX_WPNUP
              sta     .near IN_SOUND
2$:           rts

;;; ---------------------------------------------------------------------------
;;; giveAmmo: P_GiveAmmo(player, C = ammo, X = num clips (0: half a clip)).
;;; Out: carry set if the player takes it. With no ammo before, a better
;;; weapon for it comes up.
;;; ---------------------------------------------------------------------------
giveAmmo:     cmp     ##CONST_AM_NOAMMO
              bne     1$
              clc
              rts
1$:           asl     a
              sta     .near IN_AMMO         ; (2 * ammo)
              tay
              lda     abs:.near (PL+OFS_PL_AMMO),y ; full: no
              cmp     abs:.near (PL+OFS_PL_MAXAMMO),y
              bne     2$
              clc
              rts
2$:           sta     .near IN_OLD
              txa                           ; num = num * clipammo, or half a clip
              beq     3$
              pha
              tyx
              lda     long:clipAmmo,x
              plx
              jsl     long:IIGS_MulLo16
              bra     4$
3$:           tyx
              lda     long:halfClip,x
4$:           ldx     .near _g_gameskill    ; twice in baby and nightmare
              cpx     ##CONST_SK_BABY
              beq     5$
              cpx     ##CONST_SK_NIGHTMARE
              bne     6$
5$:           asl     a
6$:           ldy     .near IN_AMMO         ; ammo += num, at most maxammo
              clc
              adc     .near IN_OLD
              cmp     abs:.near (PL+OFS_PL_MAXAMMO),y
              beq     7$
              bmi     7$                    ; (signed, small values)
              lda     abs:.near (PL+OFS_PL_MAXAMMO),y
7$:           sta     abs:.near (PL+OFS_PL_AMMO),y
              lda     .near IN_OLD          ; some ammo before: done
              beq     8$
              sec
              rts
8$:           lda     .near (PL+OFS_PL_READYWEAPON) ; none before: a better weapon
              cpy     ##(2 * CONST_AM_CLIP)
              bne     10$
              cmp     ##CONST_WP_FIST       ; clip: the chaingun or the pistol
              bne     19$                   ; instead of the fist
              lda     ##CONST_WP_CHAINGUN
              ldx     .near (PL+OFS_PL_WEAPONOWNED+2*CONST_WP_CHAINGUN)
              bne     18$
              lda     ##CONST_WP_PISTOL
              bra     18$
10$:          cpy     ##(2 * CONST_AM_SHELL)
              bne     12$
              ldx     ##CONST_WP_SHOTGUN    ; shell: the shotgun instead of the
              bra     13$                   ; fist or the pistol
12$:          cpy     ##(2 * CONST_AM_CELL)
              bne     14$
              ldx     ##CONST_WP_PLASMA     ; cell: the plasma gun, the same
13$:          cmp     ##CONST_WP_FIST
              beq     15$
              cmp     ##CONST_WP_PISTOL
              bne     19$
15$:          txa
              asl     a
              tax
              lda     abs:.near (PL+OFS_PL_WEAPONOWNED),x
              beq     19$
              txa
              lsr     a
              bra     18$
14$:          cpy     ##(2 * CONST_AM_MISL)
              bne     19$
              cmp     ##CONST_WP_FIST       ; rockets: the launcher instead of
              bne     19$                   ; the fist
              lda     .near (PL+OFS_PL_WEAPONOWNED+2*CONST_WP_MISSILE)
              beq     19$
              lda     ##CONST_WP_MISSILE
18$:          sta     .near (PL+OFS_PL_PENDINGWEAPON)
19$:          sec
              rts

;;; giveWeapon: P_GiveWeapon(player, IN_WEAPON, dropped = C != 0): its ammo
;;; (1 clip dropped, else 2) and the weapon. Out: carry set if either.
giveWeapon:   pha
              lda     .near IN_WEAPON       ; the ammo of the weapon
              ldx     ##SIZEOF_WI
              jsl     long:IIGS_MulLo16
              tax
              lda     abs:.near (weaponinfo+OFS_WI_AMMO),x
              plx
              cmp     ##CONST_AM_NOAMMO
              beq     1$
              pha
              txa                           ; dropped: 1 clip, else 2
              beq     2$
              ldx     ##1
              bra     3$
2$:           ldx     ##2
3$:           pla
              jsr     .kbank giveAmmo
              lda     ##0
              rol     a                     ; gaveammo = carry
              bra     4$
1$:           lda     ##0
4$:           sta     .near IN_T
              lda     .near IN_WEAPON       ; the weapon: new, or not
              asl     a
              tax
              lda     abs:.near (PL+OFS_PL_WEAPONOWNED),x
              bne     5$
              lda     ##1
              sta     abs:.near (PL+OFS_PL_WEAPONOWNED),x
              lda     .near IN_WEAPON
              sta     .near (PL+OFS_PL_PENDINGWEAPON)
              sec
              rts
5$:           lda     .near IN_T            ; only the ammo
              lsr     a
              rts

;;; ---------------------------------------------------------------------------
;;; boolean P_GivePower(player_t* player, powertype_t power)   In: C = power.
;;; The power for its time (unless the player has it for ever); the map
;;; only once; strength also heals; invisibility makes the player a shadow.
;;; ---------------------------------------------------------------------------
              .public P_GivePower
P_GivePower:  jsr     .kbank givePower
              lda     ##0
              rol     a
              rtl

;;; givePower: P_GivePower(player, C). Out: carry.
givePower:    pha
              cmp     ##CONST_PW_INVISIBILITY
              bne     1$
              jsr     .kbank playerMo       ; mo->flags |= MF_SHADOW
              ldy     ##(OFS_MO_FLAGS+2)
              lda     [.tiny _Dp],y
              ora     ##CONST_MF_SHADOW_HI
              sta     [.tiny _Dp],y
              bra     3$
1$:           cmp     ##CONST_PW_ALLMAP
              bne     2$
              lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_ALLMAP)
              beq     3$
              pla                           ; the map again: no
              clc
              rts
2$:           cmp     ##CONST_PW_STRENGTH
              bne     3$
              lda     ##100
              jsr     .kbank giveBody
3$:           pla                           ; the time, unless negative (for ever)
              asl     a
              tax
              lda     abs:.near (PL+OFS_PL_POWERS),x
              bmi     4$
              lda     long:powerTics,x
              sta     abs:.near (PL+OFS_PL_POWERS),x
4$:           sec
              rts

;;; ---------------------------------------------------------------------------
;;; void P_DamageMobj(mobj_t __far* target, mobj_t __far* inflictor,
;;;                   mobj_t __far* source, int16_t damage)
;;;   In: _Dp[0-3] = target, _Dp[4-7] = inflictor, 4,s = source, C = damage.
;;; The thrust away from the inflictor (not for the chainsaw), the armor and
;;; the god mode of the player, the death, the pain, and a new target.
;;; ---------------------------------------------------------------------------
              .public P_DamageMobj
P_DamageMobj: sta     .near DM_DAMAGE
              lda     dp:.tiny _Dp
              sta     .near DM_TARGET
              lda     dp:.tiny (_Dp+2)
              sta     .near (DM_TARGET+2)
              lda     dp:.tiny (_Dp+4)
              sta     .near DM_INFL
              lda     dp:.tiny (_Dp+6)
              sta     .near (DM_INFL+2)
              lda     4,s
              sta     .near DM_SOURCE
              lda     6,s
              sta     .near (DM_SOURCE+2)
              ldy     ##OFS_MO_FLAGS        ; not shootable: no
              lda     [.tiny _Dp],y
              and     ##CONST_MF_SHOOTABLE_LO
              beq     1$
              ldy     ##OFS_MO_HEALTH       ; dead: no
              lda     [.tiny _Dp],y
              beq     1$
              bpl     2$
1$:           rtl
2$:           ldy     ##OFS_MO_TYPE         ; info = &mobjinfo[target->type]
              lda     [.tiny _Dp],y
              INFOADDR
              sta     .near DM_INFO
              stz     .near DM_PLAYER       ; the player: half damage in baby
              lda     .near (PL+OFS_PL_MO)
              cmp     .near DM_TARGET
              bne     3$
              lda     .near (PL+OFS_PL_MO+2)
              cmp     .near (DM_TARGET+2)
              bne     3$
              inc     .near DM_PLAYER
              lda     .near _g_gameskill
              cmp     ##CONST_SK_BABY
              bne     3$
              lda     .near DM_DAMAGE
              cmp     ##0x8000
              ror     a
              sta     .near DM_DAMAGE
3$:           jsr     .kbank thrust
              lda     .near DM_PLAYER
              beq     4$
              jsr     .kbank playerDamage
              bcs     4$
              rtl                           ; god mode, invulnerable
4$:           jsr     .kbank targetArg      ; the damage
              ldy     ##OFS_MO_HEALTH
              lda     [.tiny _Dp],y
              sec
              sbc     .near DM_DAMAGE
              sta     [.tiny _Dp],y
              beq     5$
              bpl     6$
5$:           brl     killMobj
6$:           lda     .near DM_PLAYER       ; the player: target = source
              beq     7$
              jsr     .kbank setTarget
7$:           jsl     long:P_Random         ; the pain chance
              ldx     .near DM_INFO
              sep     #0x20
              cmp     abs:OFS_MI_PAINCHANCE,x
              rep     #0x20
              lda     ##0
              bcs     8$
              lda     abs:OFS_MI_PAINSTATE,x ; justhit, the pain state
              pha
              jsr     .kbank targetArg
              pla
              jsr     .kbank setState
              lda     ##1
8$:           pha                           ; 1,s = justhit
              jsr     .kbank targetArg      ; reactiontime = 0: awake
              lda     ##0
              ldy     ##OFS_MO_REACTIONTIME
              sta     [.tiny _Dp],y
              lda     .near DM_SOURCE       ; a source, not the target itself,
              ora     .near (DM_SOURCE+2)   ; and no threshold: a new target
              beq     12$
              lda     .near DM_SOURCE
              cmp     .near DM_TARGET
              bne     9$
              lda     .near (DM_SOURCE+2)
              cmp     .near (DM_TARGET+2)
              beq     12$
9$:           ldy     ##OFS_MO_THRESHOLD
              lda     [.tiny _Dp],y
              and     ##0x00ff
              bne     12$
              jsr     .kbank lastEnemy
              jsr     .kbank setTarget      ; target = source, threshold
              jsr     .kbank targetArg
              sep     #0x20
              lda     #CONST_BASETHRESHOLD
              ldy     ##OFS_MO_THRESHOLD
              sta     [.tiny _Dp],y
              rep     #0x20
              ldx     .near DM_INFO         ; in the spawn state with a see state:
              lda     abs:OFS_MI_SPAWNSTATE,x ; the see state
              STATEADDR
              ldy     ##OFS_MO_STATE
              cmp     [.tiny _Dp],y
              bne     12$
              iny
              iny
              lda     [.tiny _Dp],y
              cmp     ##.word2 states
              bne     12$
              ldx     .near DM_INFO
              lda     abs:OFS_MI_SEESTATE,x
              beq     12$
              jsr     .kbank setState
12$:          pla                           ; justhit: MF_JUSTHIT
              beq     13$
              jsr     .kbank targetArg
              ldy     ##OFS_MO_FLAGS
              lda     [.tiny _Dp],y
              ora     ##CONST_MF_JUSTHIT_LO
              sta     [.tiny _Dp],y
13$:          rtl

;;; targetArg: _Dp[0-3] = DM_TARGET.
targetArg:    lda     .near DM_TARGET
              sta     dp:.tiny _Dp
              lda     .near (DM_TARGET+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; setTarget: target->target = DM_SOURCE.
setTarget:    jsr     .kbank targetArg
              ldy     ##OFS_MO_TARGET
              lda     .near DM_SOURCE
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (DM_SOURCE+2)
              sta     [.tiny _Dp],y
              rts

;;; setState: P_SetMobjState(target, C); DM_TARGET, DM_SOURCE and DM_INFO
;;; stay (the action of the state can run game logic).
setState:     pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              ldx     .near DM_INFO
              phx
              ldx     .near (DM_SOURCE+2)
              phx
              ldx     .near DM_SOURCE
              phx
              jsl     long:P_SetMobjState
              pla
              sta     .near DM_SOURCE
              pla
              sta     .near (DM_SOURCE+2)
              pla
              sta     .near DM_INFO
              pla
              sta     .near DM_TARGET
              pla
              sta     .near (DM_TARGET+2)
              rts

;;; lastEnemy: the old target becomes lastenemy when there is no live
;;; lastenemy or the old target is not the source.
lastEnemy:    jsr     .kbank targetArg
              ldy     ##OFS_MO_LASTENEMY
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              ora     dp:.tiny (_Dp+4)
              beq     1$
              ldy     ##OFS_MO_HEALTH
              lda     [.tiny (_Dp+4)],y
              beq     1$
              bmi     1$
              ldy     ##OFS_MO_TARGET       ; target->target != source
              lda     [.tiny _Dp],y
              cmp     .near DM_SOURCE
              bne     1$
              iny
              iny
              lda     [.tiny _Dp],y
              cmp     .near (DM_SOURCE+2)
              beq     2$
1$:           ldy     ##OFS_MO_TARGET       ; lastenemy = target
              lda     [.tiny _Dp],y
              ldy     ##OFS_MO_LASTENEMY
              sta     [.tiny _Dp],y
              ldy     ##(OFS_MO_TARGET+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_LASTENEMY+2)
              sta     [.tiny _Dp],y
2$:           rts

;;; thrust: with an inflictor, not MF_NOCLIP, and not the chainsaw of the
;;; player: the target is pushed away from the inflictor, damage * 12.5 /
;;; mass; a hard enough hit from far below can turn it over (four times
;;; the push, the other way).
thrust:       lda     .near DM_INFL
              ora     .near (DM_INFL+2)
              bne     1$
              rts
1$:           jsr     .kbank targetArg
              ldy     ##OFS_MO_FLAGS
              lda     [.tiny _Dp],y
              and     ##CONST_MF_NOCLIP
              beq     2$
              rts
2$:           lda     .near DM_SOURCE       ; the source is the player with the
              cmp     .near (PL+OFS_PL_MO)  ; chainsaw: no push
              bne     3$
              lda     .near (DM_SOURCE+2)
              cmp     .near (PL+OFS_PL_MO+2)
              bne     3$
              lda     .near (PL+OFS_PL_READYWEAPON)
              cmp     ##CONST_WP_CHAINSAW
              bne     3$
              rts
3$:           lda     .near DM_INFL         ; ang = R_PointToAngle2(inflictor, target)
              sta     dp:.tiny (_Dp+4)
              lda     .near (DM_INFL+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_MO_Y
              lda     [.tiny _Dp],y
              sec
              sbc     [.tiny (_Dp+4)],y
              sta     .near DM_ANG
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     [.tiny (_Dp+4)],y
              sta     .near (DM_ANG+2)
              ldy     ##OFS_MO_X
              lda     [.tiny _Dp],y
              sec
              sbc     [.tiny (_Dp+4)],y
              pha
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     [.tiny (_Dp+4)],y
              tax
              lda     .near DM_ANG
              sta     dp:.tiny _Dp
              lda     .near (DM_ANG+2)
              sta     dp:.tiny (_Dp+2)
              pla
              jsl     long:R_PointToAngle3
              sta     .near DM_ANG
              stx     .near (DM_ANG+2)
              lda     .near DM_DAMAGE       ; thrust = damage * 819200 / mass
              asl     a                     ;   (32 bits, as the C code); the
              clc                           ;   product is (12 * damage +
              adc     .near DM_DAMAGE       ;   (damage >> 1)) << 16 + (damage
              asl     a                     ;   & 1) << 15, arithmetic shift
              asl     a
              sta     dp:.tiny (_Dp+2)      ; 12 * damage
              lda     .near DM_DAMAGE
              cmp     ##0x8000
              ror     a
              tax                           ; damage >> 1
              lda     ##0
              ror     a
              sta     dp:.tiny _Dp          ; (damage & 1) << 15
              txa
              clc
              adc     dp:.tiny (_Dp+2)
              sta     dp:.tiny (_Dp+2)
              ldx     .near DM_INFO
              lda     abs:OFS_MI_MASS,x
              sta     dp:.tiny (_Dp+4)
              ldx     ##0
              cmp     ##0
              bpl     5$
              dex
5$:           stx     dp:.tiny (_Dp+6)
              jsl     long:_Div32
              sta     .near DM_THRUST
              stx     .near (DM_THRUST+2)
              jsr     .kbank targetArg      ; health < damage && damage < 40
              ldy     ##OFS_MO_HEALTH       ; && z - inflictor->z > 64 * FRACUNIT
              lda     [.tiny _Dp],y         ; && P_Random() & 1: turned over
              sec
              sbc     .near DM_DAMAGE
              bvc     6$
              eor     ##0x8000
6$:           bpl     9$
              lda     .near DM_DAMAGE
              sec
              sbc     ##40
              bvc     7$
              eor     ##0x8000
7$:           bpl     9$
              lda     .near DM_INFL
              sta     dp:.tiny (_Dp+4)
              lda     .near (DM_INFL+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_MO_Z
              lda     [.tiny _Dp],y
              sec
              sbc     [.tiny (_Dp+4)],y
              sta     .near DM_T
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     [.tiny (_Dp+4)],y
              sta     .near (DM_T+2)
              lda     ##0                   ; 64 * FRACUNIT < dz
              cmp     .near DM_T
              lda     ##64
              sbc     .near (DM_T+2)
              bvc     8$
              eor     ##0x8000
8$:           bpl     9$
              jsl     long:P_Random
              and     ##1
              beq     9$
              lda     .near (DM_ANG+2)      ; ang += ANG180, thrust *= 4
              eor     ##0x8000
              sta     .near (DM_ANG+2)
              asl     .near DM_THRUST
              rol     .near (DM_THRUST+2)
              asl     .near DM_THRUST
              rol     .near (DM_THRUST+2)
9$:           lda     .near (DM_ANG+2)      ; momx += FixedMulAngle(thrust, finecosine(ang))
              lsr     a
              lsr     a
              lsr     a
              pha
              jsl     long:finecosine
              ldy     ##OFS_MO_MOMX
              jsr     .kbank addThrust
              pla
              jsl     long:finesine         ; momy += FixedMulAngle(thrust, finesine(ang))
              ldy     ##OFS_MO_MOMY
              ;; fall into addThrust

;;; addThrust: the fixed_t at offset Y of the target += FixedMulAngle(
;;; DM_THRUST, X:C).
addThrust:    phy
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near DM_THRUST
              ldx     .near (DM_THRUST+2)
              jsl     long:FixedMulAngle
              sta     .near DM_T
              jsr     .kbank targetArg
              CLEARCLEAN _Dp
              ply
              lda     [.tiny _Dp],y
              clc
              adc     .near DM_T
              sta     [.tiny _Dp],y
              iny
              iny
              txa
              adc     [.tiny _Dp],y
              sta     [.tiny _Dp],y
              rts
              .space  4                     ; (the code after keeps its address)

;;; playerDamage: the player part of the damage. The exit sector (special
;;; 11) keeps the player alive; god mode and invulnerability take no damage
;;; below 1000 (carry clear: no damage at all); the armor takes a third
;;; (green) or half (blue) while it lasts.
playerDamage: jsr     .kbank targetArg      ; the exit sector: at least 1 health
              ldy     ##(OFS_MO_SUBSECTOR+2)
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
              ldy     ##OFS_SEC_SPECIAL
              lda     [.tiny (_Dp+4)],y
              cmp     ##11
              bne     1$
              ldy     ##OFS_MO_HEALTH       ; damage >= health: health - 1
              lda     .near DM_DAMAGE
              sec
              sbc     [.tiny _Dp],y
              bvc     11$
              eor     ##0x8000
11$:          bmi     1$
              lda     [.tiny _Dp],y
              dec     a
              sta     .near DM_DAMAGE
1$:           lda     .near (PL+OFS_PL_CHEATS) ; (damage < 1000 || god) && (god ||
              and     ##CONST_CF_GODMODE       ;   invulnerable): no damage
              bne     2$
              lda     .near DM_DAMAGE
              sec
              sbc     ##1000
              bvc     12$
              eor     ##0x8000
12$:          bpl     3$
              lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_INVULNERABILITY)
              beq     3$
2$:           clc
              rts
3$:           lda     .near (PL+OFS_PL_ARMORTYPE) ; the armor
              beq     5$
              ldx     ##3                   ; saved = damage / 3 (green) or / 2
              cmp     ##1
              beq     31$
              ldx     ##2
31$:          lda     .near DM_DAMAGE
              jsl     long:_Div16
              cmp     .near (PL+OFS_PL_ARMORPOINTS) ; armorpoints <= saved: used up
              beq     32$
              bmi     4$                    ; (signed, small values)
32$:          lda     .near (PL+OFS_PL_ARMORPOINTS)
              stz     .near (PL+OFS_PL_ARMORTYPE)
4$:           sta     .near DM_T            ; saved
              lda     .near (PL+OFS_PL_ARMORPOINTS)
              sec
              sbc     .near DM_T
              sta     .near (PL+OFS_PL_ARMORPOINTS)
              lda     .near DM_DAMAGE
              sec
              sbc     .near DM_T
              sta     .near DM_DAMAGE
5$:           lda     .near (PL+OFS_PL_HEALTH) ; health -= damage, at least 0
              sec
              sbc     .near DM_DAMAGE
              bpl     6$
              lda     ##0
6$:           sta     .near (PL+OFS_PL_HEALTH)
              lda     .near DM_SOURCE       ; attacker = source
              sta     .near (PL+OFS_PL_ATTACKER)
              lda     .near (DM_SOURCE+2)
              sta     .near (PL+OFS_PL_ATTACKER+2)
              lda     .near (PL+OFS_PL_DAMAGECOUNT) ; damagecount += damage, at most 100
              clc
              adc     .near DM_DAMAGE
              cmp     ##101
              bmi     7$
              lda     ##100
7$:           sta     .near (PL+OFS_PL_DAMAGECOUNT)
              sec
              rts

;;; ---------------------------------------------------------------------------
;;; killMobj: P_KillMobj(DM_SOURCE, DM_TARGET): a corpse (not solid for the
;;; player), counted, in its death state (the extreme death state for a big
;;; hit), and the dropped item of a zombie or a shotgun guy.
;;; ---------------------------------------------------------------------------
killMobj:     jsr     .kbank targetArg
              ldy     ##OFS_MO_FLAGS        ; not shootable, gravity, a corpse
              lda     [.tiny _Dp],y         ; that can drop off
              and     ##(0xffff - CONST_MF_SHOOTABLE_LO - CONST_MF_NOGRAVITY_LO)
              ora     ##CONST_MF_DROPOFF_LO
              sta     [.tiny _Dp],y
              iny
              iny
              lda     [.tiny _Dp],y
              ora     ##CONST_MF_CORPSE_HI
              sta     [.tiny _Dp],y
              ldy     ##(OFS_MO_HEIGHT+2)   ; height >>= 2 (arithmetic)
              lda     [.tiny _Dp],y
              cmp     ##0x8000
              ror     a
              tax
              dey
              dey
              lda     [.tiny _Dp],y
              ror     a
              pha
              txa
              cmp     ##0x8000
              ror     a
              tax
              pla
              ror     a
              sta     [.tiny _Dp],y
              iny
              iny
              txa
              sta     [.tiny _Dp],y
              ldy     ##(OFS_MO_FLAGS+2)    ; a monster: totallive--, killcount++
              lda     [.tiny _Dp],y
              and     ##CONST_MF_COUNTKILL_HI
              beq     1$
              lda     .near _g_totallive
              bne     11$
              dec     .near (_g_totallive+2)
11$:          dec     .near _g_totallive
              inc     .near (PL+OFS_PL_KILLCOUNT)
1$:           lda     .near DM_PLAYER       ; the player: not solid, dead, the
              beq     2$                    ; weapon down, no automap
              ldy     ##OFS_MO_FLAGS
              lda     [.tiny _Dp],y
              and     ##(0xffff - CONST_MF_SOLID_LO)
              sta     [.tiny _Dp],y
              lda     ##CONST_PST_DEAD
              sta     .near (PL+OFS_PL_PLAYERSTATE)
              lda     ##.near PL
              sta     dp:.tiny _Dp
              lda     ##.word2 PL
              sta     dp:.tiny (_Dp+2)
              jsl     long:P_DropWeapon
              lda     .near automapmode
              and     ##AM_ACTIVE
              beq     2$
              jsl     long:AM_Stop
2$:           jsr     .kbank targetArg      ; health < -spawnhealth and an
              ldx     .near DM_INFO         ; extreme death state: that one
              lda     abs:OFS_MI_SPAWNHEALTH,x
              eor     ##0xffff
              inc     a
              sta     .near DM_T
              ldy     ##OFS_MO_HEALTH
              lda     [.tiny _Dp],y
              sec
              sbc     .near DM_T
              bvc     3$
              eor     ##0x8000
3$:           bpl     4$
              lda     abs:OFS_MI_XDEATHSTATE,x
              bne     5$
4$:           lda     abs:OFS_MI_DEATHSTATE,x
5$:           jsr     .kbank setState
              jsl     long:P_Random         ; tics -= P_Random() & 3, at least 1
              and     ##3
              sta     .near DM_T
              jsr     .kbank targetArg
              ldy     ##OFS_MO_TICS
              lda     [.tiny _Dp],y
              sec
              sbc     .near DM_T
              beq     6$
              bpl     7$
6$:           lda     ##1
7$:           sta     [.tiny _Dp],y
              ldy     ##OFS_MO_TYPE         ; the item to drop
              lda     [.tiny _Dp],y
              ldx     .near (PL+OFS_PL_CHEATS)
              cpx     ##0
              beq     8$
              pha
              txa
              and     ##CONST_CF_ENEMY_ROCKETS
              beq     71$
              lda     1,s                   ; the cheat: everyone from
              cmp     ##CONST_MT_POSSESSED  ; MT_POSSESSED to MT_BRUISERSHOT
              bcc     71$                   ; drops a rocket launcher
              cmp     ##(CONST_MT_BRUISERSHOT + 1)
              bcs     71$
              pla
              lda     ##CONST_MT_MISC27
              bra     10$
71$:          pla
8$:           cmp     ##CONST_MT_POSSESSED
              bne     9$
              lda     ##CONST_MT_CLIP
              bra     10$
9$:           cmp     ##CONST_MT_SHOTGUY
              beq     91$
              rtl
91$:          lda     ##CONST_MT_SHOTGUN
10$:          pha                           ; P_SpawnMobj(x, y, ONFLOORZ, item)
              ldy     ##OFS_MO_Y
              lda     [.tiny _Dp],y
              pha
              iny
              iny
              lda     [.tiny _Dp],y
              pha
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_MO_X
              lda     [.tiny _Dp],y
              ply
              sty     dp:.tiny (_Dp+2)
              ply
              sty     dp:.tiny _Dp
              ldy     ##CONST_ONFLOORZ_LO
              sty     dp:.tiny (_Dp+4)
              ldy     ##CONST_ONFLOORZ_HI
              sty     dp:.tiny (_Dp+6)
              jsl     long:P_SpawnMobj
              ply
              sta     dp:.tiny _Dp          ; MF_DROPPED
              stx     dp:.tiny (_Dp+2)
              ldy     ##(OFS_MO_FLAGS+2)
              lda     [.tiny _Dp],y
              ora     ##CONST_MF_DROPPED_HI
              sta     [.tiny _Dp],y
              rtl

;;; pickTab: sprite, routine, message (word0, word2), argument. In the code
;;; bank for jsr (pickTab + 2, x).
pickTab:      .word   CONST_SPR_ARM1, .word0 pkArmor, .word0 msgArmor, .word2 msgArmor, 1
              .word   CONST_SPR_ARM2, .word0 pkArmor, .word0 msgMega, .word2 msgMega, 2
              .word   CONST_SPR_BON1, .word0 pkHealthBonus, .word0 msgHthBonus, .word2 msgHthBonus, 0
              .word   CONST_SPR_BON2, .word0 pkArmorBonus, .word0 msgArmBonus, .word2 msgArmBonus, 0
              .word   CONST_SPR_SOUL, .word0 pkSoul, .word0 msgSuper, .word2 msgSuper, 0
              .word   CONST_SPR_BKEY, .word0 pkCard, .word0 msgBlueCard, .word2 msgBlueCard, CONST_IT_BLUECARD
              .word   CONST_SPR_YKEY, .word0 pkCard, .word0 msgYelwCard, .word2 msgYelwCard, CONST_IT_YELLOWCARD
              .word   CONST_SPR_RKEY, .word0 pkCard, .word0 msgRedCard, .word2 msgRedCard, CONST_IT_REDCARD
              .word   CONST_SPR_STIM, .word0 pkBody, .word0 msgStim, .word2 msgStim, 10
              .word   CONST_SPR_MEDI, .word0 pkBody, .word0 msgMedikit, .word2 msgMedikit, 25
              .word   CONST_SPR_PINS, .word0 pkPower, .word0 msgInvis, .word2 msgInvis, CONST_PW_INVISIBILITY
              .word   CONST_SPR_SUIT, .word0 pkPower, .word0 msgSuit, .word2 msgSuit, CONST_PW_IRONFEET
              .word   CONST_SPR_PMAP, .word0 pkPower, .word0 msgMap, .word2 msgMap, CONST_PW_ALLMAP
              .word   CONST_SPR_PVIS, .word0 pkPower, .word0 msgVisor, .word2 msgVisor, CONST_PW_INFRARED
              .word   CONST_SPR_CLIP, .word0 pkClip, .word0 msgClip, .word2 msgClip, 0
              .word   CONST_SPR_AMMO, .word0 pkAmmo, .word0 msgClipBox, .word2 msgClipBox, CONST_AM_CLIP + 5 * 256
              .word   CONST_SPR_ROCK, .word0 pkAmmo, .word0 msgRocket, .word2 msgRocket, CONST_AM_MISL + 1 * 256
              .word   CONST_SPR_BROK, .word0 pkAmmo, .word0 msgRockBox, .word2 msgRockBox, CONST_AM_MISL + 5 * 256
              .word   CONST_SPR_SHEL, .word0 pkAmmo, .word0 msgShells, .word2 msgShells, CONST_AM_SHELL + 1 * 256
              .word   CONST_SPR_SBOX, .word0 pkAmmo, .word0 msgShellBox, .word2 msgShellBox, CONST_AM_SHELL + 5 * 256
              .word   CONST_SPR_BPAK, .word0 pkBackpack, .word0 msgBackpack, .word2 msgBackpack, 0
              .word   CONST_SPR_MGUN, .word0 pkWeapon, .word0 msgChaingun, .word2 msgChaingun, CONST_WP_CHAINGUN + 1 * 256
              .word   CONST_SPR_CSAW, .word0 pkWeapon, .word0 msgChainsaw, .word2 msgChainsaw, CONST_WP_CHAINSAW
              .word   CONST_SPR_LAUN, .word0 pkWeapon, .word0 msgLauncher, .word2 msgLauncher, CONST_WP_MISSILE
              .word   CONST_SPR_SHOT, .word0 pkWeapon, .word0 msgShotgun, .word2 msgShotgun, CONST_WP_SHOTGUN + 1 * 256
pickTab_end:

;;; The most ammo without a backpack (ammotype_t order: clip, shell, missile,
;;; cell).
              .section cnear, rodata
              .public maxammo
maxammo:      .word   200, 50, 50, 300
