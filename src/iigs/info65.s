;;; The thing and state tables in 65816 assembly.
;;;
;;; The tables of info.c (the shareware things): the 4-letter names
;;; of the sprites, the states of the animations (sprite, frame, tics, action,
;;; next state) and the thing types. The names come from offsets.inc. A state
;;; takes 16 bytes and a thing type 64 bytes (src/iigs/info.inc), so the
;;; address of a record is its number shifted.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "info.inc"

              .extern A_BossDeath, A_BruisAttack, A_Chase, A_Explode, A_FaceTarget
              .extern A_Fall, A_FireCGun, A_FireMissile, A_FirePistol, A_FireShotgun
              .extern A_GunFlash, A_Light0, A_Light1, A_Light2, A_Look
              .extern A_Lower, A_Pain, A_PlayerScream, A_PosAttack, A_Punch
              .extern A_Raise, A_ReFire, A_SPosAttack, A_SargAttack, A_Saw
              .extern A_Scream, A_TroopAttack, A_WeaponReady, A_XScream

FRACUNIT      .equ    0x10000
FULLBRIGHT    .equ    0x8000          ; a frame that ignores the light

;;; STATE: a state_t: the sprite, its frame, the tics (-1: for ever), the
;;; action (a routine, 0 for none) and the next state; 4 bytes free.
STATE         .macro  sprite, frame, tics, action, next
              .word   \sprite, \frame, \tics
              .long   \action
              .word   \next
              .space  STATE_SIZE - SIZEOF_ST
              .endm

              .section cnear, rodata
;;; The sprite names (spritenum_t order), 4 letters each: the start of the
;;; names of their lumps.
              .public sprnames
sprnames:     .ascii  "TROOSHTGPUNGPISGPISFSHTFCHGGCHGF"
              .ascii  "MISGMISFSAWGBLUDPUFFBAL1MISLTFOG"
              .ascii  "PLAYPOSSSPOSSARGBAL7BOSSARM1ARM2"
              .ascii  "BAR1BEXPBON1BON2BKEYRKEYYKEYSTIM"
              .ascii  "MEDISOULPINSSUITPMAPPVISCLIPAMMO"
              .ascii  "ROCKBROKSHELSBOXBPAKMGUNCSAWLAUN"
              .ascii  "SHOTCOLUPOL5CANDCBRAELECTRED"

;;; The states (statenum_t order).
              .public states
states:       STATE   CONST_SPR_TROO, 0, -1, 0, CONST_S_NULL                            ; S_NULL
              STATE   CONST_SPR_SHTG, 4, 0, A_Light0, CONST_S_NULL                      ; S_LIGHTDONE
              STATE   CONST_SPR_PUNG, 0, 1, A_WeaponReady, CONST_S_PUNCH                ; S_PUNCH
              STATE   CONST_SPR_PUNG, 0, 1, A_Lower, CONST_S_PUNCHDOWN                  ; S_PUNCHDOWN
              STATE   CONST_SPR_PUNG, 0, 1, A_Raise, CONST_S_PUNCHUP                    ; S_PUNCHUP
              STATE   CONST_SPR_PUNG, 1, 4, 0, CONST_S_PUNCH2                           ; S_PUNCH1
              STATE   CONST_SPR_PUNG, 2, 4, A_Punch, CONST_S_PUNCH3                     ; S_PUNCH2
              STATE   CONST_SPR_PUNG, 3, 5, 0, CONST_S_PUNCH4                           ; S_PUNCH3
              STATE   CONST_SPR_PUNG, 2, 4, 0, CONST_S_PUNCH5                           ; S_PUNCH4
              STATE   CONST_SPR_PUNG, 1, 5, A_ReFire, CONST_S_PUNCH                     ; S_PUNCH5
              STATE   CONST_SPR_PISG, 0, 1, A_WeaponReady, CONST_S_PISTOL               ; S_PISTOL
              STATE   CONST_SPR_PISG, 0, 1, A_Lower, CONST_S_PISTOLDOWN                 ; S_PISTOLDOWN
              STATE   CONST_SPR_PISG, 0, 1, A_Raise, CONST_S_PISTOLUP                   ; S_PISTOLUP
              STATE   CONST_SPR_PISG, 0, 4, 0, CONST_S_PISTOL2                          ; S_PISTOL1
              STATE   CONST_SPR_PISG, 1, 6, A_FirePistol, CONST_S_PISTOL3               ; S_PISTOL2
              STATE   CONST_SPR_PISG, 2, 4, 0, CONST_S_PISTOL4                          ; S_PISTOL3
              STATE   CONST_SPR_PISG, 1, 5, A_ReFire, CONST_S_PISTOL                    ; S_PISTOL4
              STATE   CONST_SPR_PISF, FULLBRIGHT + 0, 7, A_Light1, CONST_S_LIGHTDONE    ; S_PISTOLFLASH
              STATE   CONST_SPR_SHTG, 0, 1, A_WeaponReady, CONST_S_SGUN                 ; S_SGUN
              STATE   CONST_SPR_SHTG, 0, 1, A_Lower, CONST_S_SGUNDOWN                   ; S_SGUNDOWN
              STATE   CONST_SPR_SHTG, 0, 1, A_Raise, CONST_S_SGUNUP                     ; S_SGUNUP
              STATE   CONST_SPR_SHTG, 0, 3, 0, CONST_S_SGUN2                            ; S_SGUN1
              STATE   CONST_SPR_SHTG, 0, 7, A_FireShotgun, CONST_S_SGUN3                ; S_SGUN2
              STATE   CONST_SPR_SHTG, 1, 5, 0, CONST_S_SGUN4                            ; S_SGUN3
              STATE   CONST_SPR_SHTG, 2, 5, 0, CONST_S_SGUN5                            ; S_SGUN4
              STATE   CONST_SPR_SHTG, 3, 4, 0, CONST_S_SGUN6                            ; S_SGUN5
              STATE   CONST_SPR_SHTG, 2, 5, 0, CONST_S_SGUN7                            ; S_SGUN6
              STATE   CONST_SPR_SHTG, 1, 5, 0, CONST_S_SGUN8                            ; S_SGUN7
              STATE   CONST_SPR_SHTG, 0, 3, 0, CONST_S_SGUN9                            ; S_SGUN8
              STATE   CONST_SPR_SHTG, 0, 7, A_ReFire, CONST_S_SGUN                      ; S_SGUN9
              STATE   CONST_SPR_SHTF, FULLBRIGHT + 0, 4, A_Light1, CONST_S_SGUNFLASH2   ; S_SGUNFLASH1
              STATE   CONST_SPR_SHTF, FULLBRIGHT + 1, 3, A_Light2, CONST_S_LIGHTDONE    ; S_SGUNFLASH2
              STATE   CONST_SPR_CHGG, 0, 1, A_WeaponReady, CONST_S_CHAIN                ; S_CHAIN
              STATE   CONST_SPR_CHGG, 0, 1, A_Lower, CONST_S_CHAINDOWN                  ; S_CHAINDOWN
              STATE   CONST_SPR_CHGG, 0, 1, A_Raise, CONST_S_CHAINUP                    ; S_CHAINUP
              STATE   CONST_SPR_CHGG, 0, 4, A_FireCGun, CONST_S_CHAIN2                  ; S_CHAIN1
              STATE   CONST_SPR_CHGG, 1, 4, A_FireCGun, CONST_S_CHAIN3                  ; S_CHAIN2
              STATE   CONST_SPR_CHGG, 1, 0, A_ReFire, CONST_S_CHAIN                     ; S_CHAIN3
              STATE   CONST_SPR_CHGF, FULLBRIGHT + 0, 5, A_Light1, CONST_S_LIGHTDONE    ; S_CHAINFLASH1
              STATE   CONST_SPR_CHGF, FULLBRIGHT + 1, 5, A_Light2, CONST_S_LIGHTDONE    ; S_CHAINFLASH2
              STATE   CONST_SPR_MISG, 0, 1, A_WeaponReady, CONST_S_MISSILE              ; S_MISSILE
              STATE   CONST_SPR_MISG, 0, 1, A_Lower, CONST_S_MISSILEDOWN                ; S_MISSILEDOWN
              STATE   CONST_SPR_MISG, 0, 1, A_Raise, CONST_S_MISSILEUP                  ; S_MISSILEUP
              STATE   CONST_SPR_MISG, 1, 8, A_GunFlash, CONST_S_MISSILE2                ; S_MISSILE1
              STATE   CONST_SPR_MISG, 1, 12, A_FireMissile, CONST_S_MISSILE3            ; S_MISSILE2
              STATE   CONST_SPR_MISG, 1, 0, A_ReFire, CONST_S_MISSILE                   ; S_MISSILE3
              STATE   CONST_SPR_MISF, FULLBRIGHT + 0, 3, A_Light1, CONST_S_MISSILEFLASH2; S_MISSILEFLASH1
              STATE   CONST_SPR_MISF, FULLBRIGHT + 1, 4, 0, CONST_S_MISSILEFLASH3       ; S_MISSILEFLASH2
              STATE   CONST_SPR_MISF, FULLBRIGHT + 2, 4, A_Light2, CONST_S_MISSILEFLASH4; S_MISSILEFLASH3
              STATE   CONST_SPR_MISF, FULLBRIGHT + 3, 4, A_Light2, CONST_S_LIGHTDONE    ; S_MISSILEFLASH4
              STATE   CONST_SPR_SAWG, 2, 4, A_WeaponReady, CONST_S_SAWB                 ; S_SAW
              STATE   CONST_SPR_SAWG, 3, 4, A_WeaponReady, CONST_S_SAW                  ; S_SAWB
              STATE   CONST_SPR_SAWG, 2, 1, A_Lower, CONST_S_SAWDOWN                    ; S_SAWDOWN
              STATE   CONST_SPR_SAWG, 2, 1, A_Raise, CONST_S_SAWUP                      ; S_SAWUP
              STATE   CONST_SPR_SAWG, 0, 4, A_Saw, CONST_S_SAW2                         ; S_SAW1
              STATE   CONST_SPR_SAWG, 1, 4, A_Saw, CONST_S_SAW3                         ; S_SAW2
              STATE   CONST_SPR_SAWG, 1, 0, A_ReFire, CONST_S_SAW                       ; S_SAW3
              STATE   CONST_SPR_BLUD, 2, 8, 0, CONST_S_BLOOD2                           ; S_BLOOD1
              STATE   CONST_SPR_BLUD, 1, 8, 0, CONST_S_BLOOD3                           ; S_BLOOD2
              STATE   CONST_SPR_BLUD, 0, 8, 0, CONST_S_NULL                             ; S_BLOOD3
              STATE   CONST_SPR_PUFF, FULLBRIGHT + 0, 4, 0, CONST_S_PUFF2               ; S_PUFF1
              STATE   CONST_SPR_PUFF, 1, 4, 0, CONST_S_PUFF3                            ; S_PUFF2
              STATE   CONST_SPR_PUFF, 2, 4, 0, CONST_S_PUFF4                            ; S_PUFF3
              STATE   CONST_SPR_PUFF, 3, 4, 0, CONST_S_NULL                             ; S_PUFF4
              STATE   CONST_SPR_BAL1, FULLBRIGHT + 0, 4, 0, CONST_S_TBALL2              ; S_TBALL1
              STATE   CONST_SPR_BAL1, FULLBRIGHT + 1, 4, 0, CONST_S_TBALL1              ; S_TBALL2
              STATE   CONST_SPR_BAL1, FULLBRIGHT + 2, 6, 0, CONST_S_TBALLX2             ; S_TBALLX1
              STATE   CONST_SPR_BAL1, FULLBRIGHT + 3, 6, 0, CONST_S_TBALLX3             ; S_TBALLX2
              STATE   CONST_SPR_BAL1, FULLBRIGHT + 4, 6, 0, CONST_S_NULL                ; S_TBALLX3
              STATE   CONST_SPR_MISL, FULLBRIGHT + 0, 1, 0, CONST_S_ROCKET              ; S_ROCKET
              STATE   CONST_SPR_MISL, FULLBRIGHT + 1, 8, A_Explode, CONST_S_EXPLODE2    ; S_EXPLODE1
              STATE   CONST_SPR_MISL, FULLBRIGHT + 2, 6, 0, CONST_S_EXPLODE3            ; S_EXPLODE2
              STATE   CONST_SPR_MISL, FULLBRIGHT + 3, 4, 0, CONST_S_NULL                ; S_EXPLODE3
              STATE   CONST_SPR_TFOG, FULLBRIGHT + 0, 6, 0, CONST_S_TFOG01              ; S_TFOG
              STATE   CONST_SPR_TFOG, FULLBRIGHT + 1, 6, 0, CONST_S_TFOG02              ; S_TFOG01
              STATE   CONST_SPR_TFOG, FULLBRIGHT + 0, 6, 0, CONST_S_TFOG2               ; S_TFOG02
              STATE   CONST_SPR_TFOG, FULLBRIGHT + 1, 6, 0, CONST_S_TFOG3               ; S_TFOG2
              STATE   CONST_SPR_TFOG, FULLBRIGHT + 2, 6, 0, CONST_S_TFOG4               ; S_TFOG3
              STATE   CONST_SPR_TFOG, FULLBRIGHT + 3, 6, 0, CONST_S_TFOG5               ; S_TFOG4
              STATE   CONST_SPR_TFOG, FULLBRIGHT + 4, 6, 0, CONST_S_TFOG6               ; S_TFOG5
              STATE   CONST_SPR_TFOG, FULLBRIGHT + 5, 6, 0, CONST_S_TFOG7               ; S_TFOG6
              STATE   CONST_SPR_TFOG, FULLBRIGHT + 6, 6, 0, CONST_S_TFOG8               ; S_TFOG7
              STATE   CONST_SPR_TFOG, FULLBRIGHT + 7, 6, 0, CONST_S_TFOG9               ; S_TFOG8
              STATE   CONST_SPR_TFOG, FULLBRIGHT + 8, 6, 0, CONST_S_TFOG10              ; S_TFOG9
              STATE   CONST_SPR_TFOG, FULLBRIGHT + 9, 6, 0, CONST_S_NULL                ; S_TFOG10
              STATE   CONST_SPR_PLAY, 0, -1, 0, CONST_S_NULL                            ; S_PLAY
              STATE   CONST_SPR_PLAY, 0, 4, 0, CONST_S_PLAY_RUN2                        ; S_PLAY_RUN1
              STATE   CONST_SPR_PLAY, 1, 4, 0, CONST_S_PLAY_RUN3                        ; S_PLAY_RUN2
              STATE   CONST_SPR_PLAY, 2, 4, 0, CONST_S_PLAY_RUN4                        ; S_PLAY_RUN3
              STATE   CONST_SPR_PLAY, 3, 4, 0, CONST_S_PLAY_RUN1                        ; S_PLAY_RUN4
              STATE   CONST_SPR_PLAY, 4, 12, 0, CONST_S_PLAY                            ; S_PLAY_ATK1
              STATE   CONST_SPR_PLAY, FULLBRIGHT + 5, 6, 0, CONST_S_PLAY_ATK1           ; S_PLAY_ATK2
              STATE   CONST_SPR_PLAY, 6, 4, 0, CONST_S_PLAY_PAIN2                       ; S_PLAY_PAIN
              STATE   CONST_SPR_PLAY, 6, 4, A_Pain, CONST_S_PLAY                        ; S_PLAY_PAIN2
              STATE   CONST_SPR_PLAY, 7, 10, 0, CONST_S_PLAY_DIE2                       ; S_PLAY_DIE1
              STATE   CONST_SPR_PLAY, 8, 10, A_PlayerScream, CONST_S_PLAY_DIE3          ; S_PLAY_DIE2
              STATE   CONST_SPR_PLAY, 9, 10, A_Fall, CONST_S_PLAY_DIE4                  ; S_PLAY_DIE3
              STATE   CONST_SPR_PLAY, 10, 10, 0, CONST_S_PLAY_DIE5                      ; S_PLAY_DIE4
              STATE   CONST_SPR_PLAY, 11, 10, 0, CONST_S_PLAY_DIE6                      ; S_PLAY_DIE5
              STATE   CONST_SPR_PLAY, 12, 10, 0, CONST_S_PLAY_DIE7                      ; S_PLAY_DIE6
              STATE   CONST_SPR_PLAY, 13, -1, 0, CONST_S_NULL                           ; S_PLAY_DIE7
              STATE   CONST_SPR_PLAY, 14, 5, 0, CONST_S_PLAY_XDIE2                      ; S_PLAY_XDIE1
              STATE   CONST_SPR_PLAY, 15, 5, A_XScream, CONST_S_PLAY_XDIE3              ; S_PLAY_XDIE2
              STATE   CONST_SPR_PLAY, 16, 5, A_Fall, CONST_S_PLAY_XDIE4                 ; S_PLAY_XDIE3
              STATE   CONST_SPR_PLAY, 17, 5, 0, CONST_S_PLAY_XDIE5                      ; S_PLAY_XDIE4
              STATE   CONST_SPR_PLAY, 18, 5, 0, CONST_S_PLAY_XDIE6                      ; S_PLAY_XDIE5
              STATE   CONST_SPR_PLAY, 19, 5, 0, CONST_S_PLAY_XDIE7                      ; S_PLAY_XDIE6
              STATE   CONST_SPR_PLAY, 20, 5, 0, CONST_S_PLAY_XDIE8                      ; S_PLAY_XDIE7
              STATE   CONST_SPR_PLAY, 21, 5, 0, CONST_S_PLAY_XDIE9                      ; S_PLAY_XDIE8
              STATE   CONST_SPR_PLAY, 22, -1, 0, CONST_S_NULL                           ; S_PLAY_XDIE9
              STATE   CONST_SPR_POSS, 0, 10, A_Look, CONST_S_POSS_STND2                 ; S_POSS_STND
              STATE   CONST_SPR_POSS, 1, 10, A_Look, CONST_S_POSS_STND                  ; S_POSS_STND2
              STATE   CONST_SPR_POSS, 0, 4, A_Chase, CONST_S_POSS_RUN2                  ; S_POSS_RUN1
              STATE   CONST_SPR_POSS, 0, 4, A_Chase, CONST_S_POSS_RUN3                  ; S_POSS_RUN2
              STATE   CONST_SPR_POSS, 1, 4, A_Chase, CONST_S_POSS_RUN4                  ; S_POSS_RUN3
              STATE   CONST_SPR_POSS, 1, 4, A_Chase, CONST_S_POSS_RUN5                  ; S_POSS_RUN4
              STATE   CONST_SPR_POSS, 2, 4, A_Chase, CONST_S_POSS_RUN6                  ; S_POSS_RUN5
              STATE   CONST_SPR_POSS, 2, 4, A_Chase, CONST_S_POSS_RUN7                  ; S_POSS_RUN6
              STATE   CONST_SPR_POSS, 3, 4, A_Chase, CONST_S_POSS_RUN8                  ; S_POSS_RUN7
              STATE   CONST_SPR_POSS, 3, 4, A_Chase, CONST_S_POSS_RUN1                  ; S_POSS_RUN8
              STATE   CONST_SPR_POSS, 4, 10, A_FaceTarget, CONST_S_POSS_ATK2            ; S_POSS_ATK1
              STATE   CONST_SPR_POSS, 5, 8, A_PosAttack, CONST_S_POSS_ATK3              ; S_POSS_ATK2
              STATE   CONST_SPR_POSS, 4, 8, 0, CONST_S_POSS_RUN1                        ; S_POSS_ATK3
              STATE   CONST_SPR_POSS, 6, 3, 0, CONST_S_POSS_PAIN2                       ; S_POSS_PAIN
              STATE   CONST_SPR_POSS, 6, 3, A_Pain, CONST_S_POSS_RUN1                   ; S_POSS_PAIN2
              STATE   CONST_SPR_POSS, 7, 5, 0, CONST_S_POSS_DIE2                        ; S_POSS_DIE1
              STATE   CONST_SPR_POSS, 8, 5, A_Scream, CONST_S_POSS_DIE3                 ; S_POSS_DIE2
              STATE   CONST_SPR_POSS, 9, 5, A_Fall, CONST_S_POSS_DIE4                   ; S_POSS_DIE3
              STATE   CONST_SPR_POSS, 10, 5, 0, CONST_S_POSS_DIE5                       ; S_POSS_DIE4
              STATE   CONST_SPR_POSS, 11, -1, 0, CONST_S_NULL                           ; S_POSS_DIE5
              STATE   CONST_SPR_POSS, 12, 5, 0, CONST_S_POSS_XDIE2                      ; S_POSS_XDIE1
              STATE   CONST_SPR_POSS, 13, 5, A_XScream, CONST_S_POSS_XDIE3              ; S_POSS_XDIE2
              STATE   CONST_SPR_POSS, 14, 5, A_Fall, CONST_S_POSS_XDIE4                 ; S_POSS_XDIE3
              STATE   CONST_SPR_POSS, 15, 5, 0, CONST_S_POSS_XDIE5                      ; S_POSS_XDIE4
              STATE   CONST_SPR_POSS, 16, 5, 0, CONST_S_POSS_XDIE6                      ; S_POSS_XDIE5
              STATE   CONST_SPR_POSS, 17, 5, 0, CONST_S_POSS_XDIE7                      ; S_POSS_XDIE6
              STATE   CONST_SPR_POSS, 18, 5, 0, CONST_S_POSS_XDIE8                      ; S_POSS_XDIE7
              STATE   CONST_SPR_POSS, 19, 5, 0, CONST_S_POSS_XDIE9                      ; S_POSS_XDIE8
              STATE   CONST_SPR_POSS, 20, -1, 0, CONST_S_NULL                           ; S_POSS_XDIE9
              STATE   CONST_SPR_SPOS, 0, 10, A_Look, CONST_S_SPOS_STND2                 ; S_SPOS_STND
              STATE   CONST_SPR_SPOS, 1, 10, A_Look, CONST_S_SPOS_STND                  ; S_SPOS_STND2
              STATE   CONST_SPR_SPOS, 0, 3, A_Chase, CONST_S_SPOS_RUN2                  ; S_SPOS_RUN1
              STATE   CONST_SPR_SPOS, 0, 3, A_Chase, CONST_S_SPOS_RUN3                  ; S_SPOS_RUN2
              STATE   CONST_SPR_SPOS, 1, 3, A_Chase, CONST_S_SPOS_RUN4                  ; S_SPOS_RUN3
              STATE   CONST_SPR_SPOS, 1, 3, A_Chase, CONST_S_SPOS_RUN5                  ; S_SPOS_RUN4
              STATE   CONST_SPR_SPOS, 2, 3, A_Chase, CONST_S_SPOS_RUN6                  ; S_SPOS_RUN5
              STATE   CONST_SPR_SPOS, 2, 3, A_Chase, CONST_S_SPOS_RUN7                  ; S_SPOS_RUN6
              STATE   CONST_SPR_SPOS, 3, 3, A_Chase, CONST_S_SPOS_RUN8                  ; S_SPOS_RUN7
              STATE   CONST_SPR_SPOS, 3, 3, A_Chase, CONST_S_SPOS_RUN1                  ; S_SPOS_RUN8
              STATE   CONST_SPR_SPOS, 4, 10, A_FaceTarget, CONST_S_SPOS_ATK2            ; S_SPOS_ATK1
              STATE   CONST_SPR_SPOS, FULLBRIGHT + 5, 10, A_SPosAttack, CONST_S_SPOS_ATK3; S_SPOS_ATK2
              STATE   CONST_SPR_SPOS, 4, 10, 0, CONST_S_SPOS_RUN1                       ; S_SPOS_ATK3
              STATE   CONST_SPR_SPOS, 6, 3, 0, CONST_S_SPOS_PAIN2                       ; S_SPOS_PAIN
              STATE   CONST_SPR_SPOS, 6, 3, A_Pain, CONST_S_SPOS_RUN1                   ; S_SPOS_PAIN2
              STATE   CONST_SPR_SPOS, 7, 5, 0, CONST_S_SPOS_DIE2                        ; S_SPOS_DIE1
              STATE   CONST_SPR_SPOS, 8, 5, A_Scream, CONST_S_SPOS_DIE3                 ; S_SPOS_DIE2
              STATE   CONST_SPR_SPOS, 9, 5, A_Fall, CONST_S_SPOS_DIE4                   ; S_SPOS_DIE3
              STATE   CONST_SPR_SPOS, 10, 5, 0, CONST_S_SPOS_DIE5                       ; S_SPOS_DIE4
              STATE   CONST_SPR_SPOS, 11, -1, 0, CONST_S_NULL                           ; S_SPOS_DIE5
              STATE   CONST_SPR_SPOS, 12, 5, 0, CONST_S_SPOS_XDIE2                      ; S_SPOS_XDIE1
              STATE   CONST_SPR_SPOS, 13, 5, A_XScream, CONST_S_SPOS_XDIE3              ; S_SPOS_XDIE2
              STATE   CONST_SPR_SPOS, 14, 5, A_Fall, CONST_S_SPOS_XDIE4                 ; S_SPOS_XDIE3
              STATE   CONST_SPR_SPOS, 15, 5, 0, CONST_S_SPOS_XDIE5                      ; S_SPOS_XDIE4
              STATE   CONST_SPR_SPOS, 16, 5, 0, CONST_S_SPOS_XDIE6                      ; S_SPOS_XDIE5
              STATE   CONST_SPR_SPOS, 17, 5, 0, CONST_S_SPOS_XDIE7                      ; S_SPOS_XDIE6
              STATE   CONST_SPR_SPOS, 18, 5, 0, CONST_S_SPOS_XDIE8                      ; S_SPOS_XDIE7
              STATE   CONST_SPR_SPOS, 19, 5, 0, CONST_S_SPOS_XDIE9                      ; S_SPOS_XDIE8
              STATE   CONST_SPR_SPOS, 20, -1, 0, CONST_S_NULL                           ; S_SPOS_XDIE9
              STATE   CONST_SPR_TROO, 0, 10, A_Look, CONST_S_TROO_STND2                 ; S_TROO_STND
              STATE   CONST_SPR_TROO, 1, 10, A_Look, CONST_S_TROO_STND                  ; S_TROO_STND2
              STATE   CONST_SPR_TROO, 0, 3, A_Chase, CONST_S_TROO_RUN2                  ; S_TROO_RUN1
              STATE   CONST_SPR_TROO, 0, 3, A_Chase, CONST_S_TROO_RUN3                  ; S_TROO_RUN2
              STATE   CONST_SPR_TROO, 1, 3, A_Chase, CONST_S_TROO_RUN4                  ; S_TROO_RUN3
              STATE   CONST_SPR_TROO, 1, 3, A_Chase, CONST_S_TROO_RUN5                  ; S_TROO_RUN4
              STATE   CONST_SPR_TROO, 2, 3, A_Chase, CONST_S_TROO_RUN6                  ; S_TROO_RUN5
              STATE   CONST_SPR_TROO, 2, 3, A_Chase, CONST_S_TROO_RUN7                  ; S_TROO_RUN6
              STATE   CONST_SPR_TROO, 3, 3, A_Chase, CONST_S_TROO_RUN8                  ; S_TROO_RUN7
              STATE   CONST_SPR_TROO, 3, 3, A_Chase, CONST_S_TROO_RUN1                  ; S_TROO_RUN8
              STATE   CONST_SPR_TROO, 4, 8, A_FaceTarget, CONST_S_TROO_ATK2             ; S_TROO_ATK1
              STATE   CONST_SPR_TROO, 5, 8, A_FaceTarget, CONST_S_TROO_ATK3             ; S_TROO_ATK2
              STATE   CONST_SPR_TROO, 6, 6, A_TroopAttack, CONST_S_TROO_RUN1            ; S_TROO_ATK3
              STATE   CONST_SPR_TROO, 7, 2, 0, CONST_S_TROO_PAIN2                       ; S_TROO_PAIN
              STATE   CONST_SPR_TROO, 7, 2, A_Pain, CONST_S_TROO_RUN1                   ; S_TROO_PAIN2
              STATE   CONST_SPR_TROO, 8, 8, 0, CONST_S_TROO_DIE2                        ; S_TROO_DIE1
              STATE   CONST_SPR_TROO, 9, 8, A_Scream, CONST_S_TROO_DIE3                 ; S_TROO_DIE2
              STATE   CONST_SPR_TROO, 10, 6, 0, CONST_S_TROO_DIE4                       ; S_TROO_DIE3
              STATE   CONST_SPR_TROO, 11, 6, A_Fall, CONST_S_TROO_DIE5                  ; S_TROO_DIE4
              STATE   CONST_SPR_TROO, 12, -1, 0, CONST_S_NULL                           ; S_TROO_DIE5
              STATE   CONST_SPR_TROO, 13, 5, 0, CONST_S_TROO_XDIE2                      ; S_TROO_XDIE1
              STATE   CONST_SPR_TROO, 14, 5, A_XScream, CONST_S_TROO_XDIE3              ; S_TROO_XDIE2
              STATE   CONST_SPR_TROO, 15, 5, 0, CONST_S_TROO_XDIE4                      ; S_TROO_XDIE3
              STATE   CONST_SPR_TROO, 16, 5, A_Fall, CONST_S_TROO_XDIE5                 ; S_TROO_XDIE4
              STATE   CONST_SPR_TROO, 17, 5, 0, CONST_S_TROO_XDIE6                      ; S_TROO_XDIE5
              STATE   CONST_SPR_TROO, 18, 5, 0, CONST_S_TROO_XDIE7                      ; S_TROO_XDIE6
              STATE   CONST_SPR_TROO, 19, 5, 0, CONST_S_TROO_XDIE8                      ; S_TROO_XDIE7
              STATE   CONST_SPR_TROO, 20, -1, 0, CONST_S_NULL                           ; S_TROO_XDIE8
              STATE   CONST_SPR_SARG, 0, 10, A_Look, CONST_S_SARG_STND2                 ; S_SARG_STND
              STATE   CONST_SPR_SARG, 1, 10, A_Look, CONST_S_SARG_STND                  ; S_SARG_STND2
              STATE   CONST_SPR_SARG, 0, 2, A_Chase, CONST_S_SARG_RUN2                  ; S_SARG_RUN1
              STATE   CONST_SPR_SARG, 0, 2, A_Chase, CONST_S_SARG_RUN3                  ; S_SARG_RUN2
              STATE   CONST_SPR_SARG, 1, 2, A_Chase, CONST_S_SARG_RUN4                  ; S_SARG_RUN3
              STATE   CONST_SPR_SARG, 1, 2, A_Chase, CONST_S_SARG_RUN5                  ; S_SARG_RUN4
              STATE   CONST_SPR_SARG, 2, 2, A_Chase, CONST_S_SARG_RUN6                  ; S_SARG_RUN5
              STATE   CONST_SPR_SARG, 2, 2, A_Chase, CONST_S_SARG_RUN7                  ; S_SARG_RUN6
              STATE   CONST_SPR_SARG, 3, 2, A_Chase, CONST_S_SARG_RUN8                  ; S_SARG_RUN7
              STATE   CONST_SPR_SARG, 3, 2, A_Chase, CONST_S_SARG_RUN1                  ; S_SARG_RUN8
              STATE   CONST_SPR_SARG, 4, 8, A_FaceTarget, CONST_S_SARG_ATK2             ; S_SARG_ATK1
              STATE   CONST_SPR_SARG, 5, 8, A_FaceTarget, CONST_S_SARG_ATK3             ; S_SARG_ATK2
              STATE   CONST_SPR_SARG, 6, 8, A_SargAttack, CONST_S_SARG_RUN1             ; S_SARG_ATK3
              STATE   CONST_SPR_SARG, 7, 2, 0, CONST_S_SARG_PAIN2                       ; S_SARG_PAIN
              STATE   CONST_SPR_SARG, 7, 2, A_Pain, CONST_S_SARG_RUN1                   ; S_SARG_PAIN2
              STATE   CONST_SPR_SARG, 8, 8, 0, CONST_S_SARG_DIE2                        ; S_SARG_DIE1
              STATE   CONST_SPR_SARG, 9, 8, A_Scream, CONST_S_SARG_DIE3                 ; S_SARG_DIE2
              STATE   CONST_SPR_SARG, 10, 4, 0, CONST_S_SARG_DIE4                       ; S_SARG_DIE3
              STATE   CONST_SPR_SARG, 11, 4, A_Fall, CONST_S_SARG_DIE5                  ; S_SARG_DIE4
              STATE   CONST_SPR_SARG, 12, 4, 0, CONST_S_SARG_DIE6                       ; S_SARG_DIE5
              STATE   CONST_SPR_SARG, 13, -1, 0, CONST_S_NULL                           ; S_SARG_DIE6
              STATE   CONST_SPR_BAL7, FULLBRIGHT + 0, 4, 0, CONST_S_BRBALL2             ; S_BRBALL1
              STATE   CONST_SPR_BAL7, FULLBRIGHT + 1, 4, 0, CONST_S_BRBALL1             ; S_BRBALL2
              STATE   CONST_SPR_BAL7, FULLBRIGHT + 2, 6, 0, CONST_S_BRBALLX2            ; S_BRBALLX1
              STATE   CONST_SPR_BAL7, FULLBRIGHT + 3, 6, 0, CONST_S_BRBALLX3            ; S_BRBALLX2
              STATE   CONST_SPR_BAL7, FULLBRIGHT + 4, 6, 0, CONST_S_NULL                ; S_BRBALLX3
              STATE   CONST_SPR_BOSS, 0, 10, A_Look, CONST_S_BOSS_STND2                 ; S_BOSS_STND
              STATE   CONST_SPR_BOSS, 1, 10, A_Look, CONST_S_BOSS_STND                  ; S_BOSS_STND2
              STATE   CONST_SPR_BOSS, 0, 3, A_Chase, CONST_S_BOSS_RUN2                  ; S_BOSS_RUN1
              STATE   CONST_SPR_BOSS, 0, 3, A_Chase, CONST_S_BOSS_RUN3                  ; S_BOSS_RUN2
              STATE   CONST_SPR_BOSS, 1, 3, A_Chase, CONST_S_BOSS_RUN4                  ; S_BOSS_RUN3
              STATE   CONST_SPR_BOSS, 1, 3, A_Chase, CONST_S_BOSS_RUN5                  ; S_BOSS_RUN4
              STATE   CONST_SPR_BOSS, 2, 3, A_Chase, CONST_S_BOSS_RUN6                  ; S_BOSS_RUN5
              STATE   CONST_SPR_BOSS, 2, 3, A_Chase, CONST_S_BOSS_RUN7                  ; S_BOSS_RUN6
              STATE   CONST_SPR_BOSS, 3, 3, A_Chase, CONST_S_BOSS_RUN8                  ; S_BOSS_RUN7
              STATE   CONST_SPR_BOSS, 3, 3, A_Chase, CONST_S_BOSS_RUN1                  ; S_BOSS_RUN8
              STATE   CONST_SPR_BOSS, 4, 8, A_FaceTarget, CONST_S_BOSS_ATK2             ; S_BOSS_ATK1
              STATE   CONST_SPR_BOSS, 5, 8, A_FaceTarget, CONST_S_BOSS_ATK3             ; S_BOSS_ATK2
              STATE   CONST_SPR_BOSS, 6, 8, A_BruisAttack, CONST_S_BOSS_RUN1            ; S_BOSS_ATK3
              STATE   CONST_SPR_BOSS, 7, 2, 0, CONST_S_BOSS_PAIN2                       ; S_BOSS_PAIN
              STATE   CONST_SPR_BOSS, 7, 2, A_Pain, CONST_S_BOSS_RUN1                   ; S_BOSS_PAIN2
              STATE   CONST_SPR_BOSS, 8, 8, 0, CONST_S_BOSS_DIE2                        ; S_BOSS_DIE1
              STATE   CONST_SPR_BOSS, 9, 8, A_Scream, CONST_S_BOSS_DIE3                 ; S_BOSS_DIE2
              STATE   CONST_SPR_BOSS, 10, 8, 0, CONST_S_BOSS_DIE4                       ; S_BOSS_DIE3
              STATE   CONST_SPR_BOSS, 11, 8, A_Fall, CONST_S_BOSS_DIE5                  ; S_BOSS_DIE4
              STATE   CONST_SPR_BOSS, 12, 8, 0, CONST_S_BOSS_DIE6                       ; S_BOSS_DIE5
              STATE   CONST_SPR_BOSS, 13, 8, 0, CONST_S_BOSS_DIE7                       ; S_BOSS_DIE6
              STATE   CONST_SPR_BOSS, 14, -1, A_BossDeath, CONST_S_NULL                 ; S_BOSS_DIE7
              STATE   CONST_SPR_ARM1, 0, 6, 0, CONST_S_ARM1A                            ; S_ARM1
              STATE   CONST_SPR_ARM1, FULLBRIGHT + 1, 7, 0, CONST_S_ARM1                ; S_ARM1A
              STATE   CONST_SPR_ARM2, 0, 6, 0, CONST_S_ARM2A                            ; S_ARM2
              STATE   CONST_SPR_ARM2, FULLBRIGHT + 1, 6, 0, CONST_S_ARM2                ; S_ARM2A
              STATE   CONST_SPR_BAR1, 0, 6, 0, CONST_S_BAR2                             ; S_BAR1
              STATE   CONST_SPR_BAR1, 1, 6, 0, CONST_S_BAR1                             ; S_BAR2
              STATE   CONST_SPR_BEXP, FULLBRIGHT + 0, 5, 0, CONST_S_BEXP2               ; S_BEXP
              STATE   CONST_SPR_BEXP, FULLBRIGHT + 1, 5, A_Scream, CONST_S_BEXP3        ; S_BEXP2
              STATE   CONST_SPR_BEXP, FULLBRIGHT + 2, 5, 0, CONST_S_BEXP4               ; S_BEXP3
              STATE   CONST_SPR_BEXP, FULLBRIGHT + 3, 10, A_Explode, CONST_S_BEXP5      ; S_BEXP4
              STATE   CONST_SPR_BEXP, FULLBRIGHT + 4, 10, 0, CONST_S_NULL               ; S_BEXP5
              STATE   CONST_SPR_BON1, 0, 6, 0, CONST_S_BON1A                            ; S_BON1
              STATE   CONST_SPR_BON1, 1, 6, 0, CONST_S_BON1B                            ; S_BON1A
              STATE   CONST_SPR_BON1, 2, 6, 0, CONST_S_BON1C                            ; S_BON1B
              STATE   CONST_SPR_BON1, 3, 6, 0, CONST_S_BON1D                            ; S_BON1C
              STATE   CONST_SPR_BON1, 2, 6, 0, CONST_S_BON1E                            ; S_BON1D
              STATE   CONST_SPR_BON1, 1, 6, 0, CONST_S_BON1                             ; S_BON1E
              STATE   CONST_SPR_BON2, 0, 6, 0, CONST_S_BON2A                            ; S_BON2
              STATE   CONST_SPR_BON2, 1, 6, 0, CONST_S_BON2B                            ; S_BON2A
              STATE   CONST_SPR_BON2, 2, 6, 0, CONST_S_BON2C                            ; S_BON2B
              STATE   CONST_SPR_BON2, 3, 6, 0, CONST_S_BON2D                            ; S_BON2C
              STATE   CONST_SPR_BON2, 2, 6, 0, CONST_S_BON2E                            ; S_BON2D
              STATE   CONST_SPR_BON2, 1, 6, 0, CONST_S_BON2                             ; S_BON2E
              STATE   CONST_SPR_BKEY, 0, 10, 0, CONST_S_BKEY2                           ; S_BKEY
              STATE   CONST_SPR_BKEY, FULLBRIGHT + 1, 10, 0, CONST_S_BKEY               ; S_BKEY2
              STATE   CONST_SPR_RKEY, 0, 10, 0, CONST_S_RKEY2                           ; S_RKEY
              STATE   CONST_SPR_RKEY, FULLBRIGHT + 1, 10, 0, CONST_S_RKEY               ; S_RKEY2
              STATE   CONST_SPR_YKEY, 0, 10, 0, CONST_S_YKEY2                           ; S_YKEY
              STATE   CONST_SPR_YKEY, FULLBRIGHT + 1, 10, 0, CONST_S_YKEY               ; S_YKEY2
              STATE   CONST_SPR_STIM, 0, -1, 0, CONST_S_NULL                            ; S_STIM
              STATE   CONST_SPR_MEDI, 0, -1, 0, CONST_S_NULL                            ; S_MEDI
              STATE   CONST_SPR_SOUL, FULLBRIGHT + 0, 6, 0, CONST_S_SOUL2               ; S_SOUL
              STATE   CONST_SPR_SOUL, FULLBRIGHT + 1, 6, 0, CONST_S_SOUL3               ; S_SOUL2
              STATE   CONST_SPR_SOUL, FULLBRIGHT + 2, 6, 0, CONST_S_SOUL4               ; S_SOUL3
              STATE   CONST_SPR_SOUL, FULLBRIGHT + 3, 6, 0, CONST_S_SOUL5               ; S_SOUL4
              STATE   CONST_SPR_SOUL, FULLBRIGHT + 2, 6, 0, CONST_S_SOUL6               ; S_SOUL5
              STATE   CONST_SPR_SOUL, FULLBRIGHT + 1, 6, 0, CONST_S_SOUL                ; S_SOUL6
              STATE   CONST_SPR_PINS, FULLBRIGHT + 0, 6, 0, CONST_S_PINS2               ; S_PINS
              STATE   CONST_SPR_PINS, FULLBRIGHT + 1, 6, 0, CONST_S_PINS3               ; S_PINS2
              STATE   CONST_SPR_PINS, FULLBRIGHT + 2, 6, 0, CONST_S_PINS4               ; S_PINS3
              STATE   CONST_SPR_PINS, FULLBRIGHT + 3, 6, 0, CONST_S_PINS                ; S_PINS4
              STATE   CONST_SPR_SUIT, FULLBRIGHT + 0, -1, 0, CONST_S_NULL               ; S_SUIT
              STATE   CONST_SPR_PMAP, FULLBRIGHT + 0, 6, 0, CONST_S_PMAP2               ; S_PMAP
              STATE   CONST_SPR_PMAP, FULLBRIGHT + 1, 6, 0, CONST_S_PMAP3               ; S_PMAP2
              STATE   CONST_SPR_PMAP, FULLBRIGHT + 2, 6, 0, CONST_S_PMAP4               ; S_PMAP3
              STATE   CONST_SPR_PMAP, FULLBRIGHT + 3, 6, 0, CONST_S_PMAP5               ; S_PMAP4
              STATE   CONST_SPR_PMAP, FULLBRIGHT + 2, 6, 0, CONST_S_PMAP6               ; S_PMAP5
              STATE   CONST_SPR_PMAP, FULLBRIGHT + 1, 6, 0, CONST_S_PMAP                ; S_PMAP6
              STATE   CONST_SPR_PVIS, FULLBRIGHT + 0, 6, 0, CONST_S_PVIS2               ; S_PVIS
              STATE   CONST_SPR_PVIS, 1, 6, 0, CONST_S_PVIS                             ; S_PVIS2
              STATE   CONST_SPR_CLIP, 0, -1, 0, CONST_S_NULL                            ; S_CLIP
              STATE   CONST_SPR_AMMO, 0, -1, 0, CONST_S_NULL                            ; S_AMMO
              STATE   CONST_SPR_ROCK, 0, -1, 0, CONST_S_NULL                            ; S_ROCK
              STATE   CONST_SPR_BROK, 0, -1, 0, CONST_S_NULL                            ; S_BROK
              STATE   CONST_SPR_SHEL, 0, -1, 0, CONST_S_NULL                            ; S_SHEL
              STATE   CONST_SPR_SBOX, 0, -1, 0, CONST_S_NULL                            ; S_SBOX
              STATE   CONST_SPR_BPAK, 0, -1, 0, CONST_S_NULL                            ; S_BPAK
              STATE   CONST_SPR_MGUN, 0, -1, 0, CONST_S_NULL                            ; S_MGUN
              STATE   CONST_SPR_CSAW, 0, -1, 0, CONST_S_NULL                            ; S_CSAW
              STATE   CONST_SPR_LAUN, 0, -1, 0, CONST_S_NULL                            ; S_LAUN
              STATE   CONST_SPR_SHOT, 0, -1, 0, CONST_S_NULL                            ; S_SHOT
              STATE   CONST_SPR_COLU, FULLBRIGHT + 0, -1, 0, CONST_S_NULL               ; S_COLU
              STATE   CONST_SPR_POL5, 0, -1, 0, CONST_S_NULL                            ; S_GIBS
              STATE   CONST_SPR_CAND, FULLBRIGHT + 0, -1, 0, CONST_S_NULL               ; S_CANDLESTIK
              STATE   CONST_SPR_CBRA, FULLBRIGHT + 0, -1, 0, CONST_S_NULL               ; S_CANDELABRA
              STATE   CONST_SPR_ELEC, 0, -1, 0, CONST_S_NULL                            ; S_TECHPILLAR
              STATE   CONST_SPR_TRED, FULLBRIGHT + 0, 4, 0, CONST_S_REDTORCH2           ; S_REDTORCH
              STATE   CONST_SPR_TRED, FULLBRIGHT + 1, 4, 0, CONST_S_REDTORCH3           ; S_REDTORCH2
              STATE   CONST_SPR_TRED, FULLBRIGHT + 2, 4, 0, CONST_S_REDTORCH4           ; S_REDTORCH3
              STATE   CONST_SPR_TRED, FULLBRIGHT + 3, 4, 0, CONST_S_REDTORCH            ; S_REDTORCH4

;;; The thing types (mobjtype_t order): mobjinfo_t (51 bytes) and 13 bytes
;;; free each.
              .public mobjinfo
mobjinfo:
              ; MT_PLAYER
              .word   -1                                      ; doomednum
              .word   CONST_S_PLAY                            ; spawnstate
              .word   100                                     ; spawnhealth
              .word   CONST_S_PLAY_RUN1                       ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   0                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_PLAY_PAIN                       ; painstate
              .byte   255                                     ; painchance
              .word   CONST_SFX_PLPAIN                        ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_PLAY_ATK1                       ; missilestate
              .word   CONST_S_PLAY_DIE1                       ; deathstate
              .word   CONST_S_PLAY_XDIE1                      ; xdeathstate
              .word   CONST_SFX_PLDETH                        ; deathsound
              .long   0                                       ; speed
              .long   16 * FRACUNIT                           ; radius
              .long   56 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SOLID_LO | CONST_MF_SHOOTABLE_LO | CONST_MF_DROPOFF_LO | CONST_MF_PICKUP_LO ; flags
              .word   CONST_MF_SOLID_HI | CONST_MF_SHOOTABLE_HI | CONST_MF_DROPOFF_HI | CONST_MF_PICKUP_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_POSSESSED
              .word   3004                                    ; doomednum
              .word   CONST_S_POSS_STND                       ; spawnstate
              .word   20                                      ; spawnhealth
              .word   CONST_S_POSS_RUN1                       ; seestate
              .word   CONST_SFX_POSIT1                        ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_PISTOL                        ; attacksound
              .word   CONST_S_POSS_PAIN                       ; painstate
              .byte   200                                     ; painchance
              .word   CONST_SFX_POPAIN                        ; painsound
              .word   0                                       ; meleestate
              .word   CONST_S_POSS_ATK1                       ; missilestate
              .word   CONST_S_POSS_DIE1                       ; deathstate
              .word   CONST_S_POSS_XDIE1                      ; xdeathstate
              .word   CONST_SFX_PODTH1                        ; deathsound
              .long   8                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   56 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_POSACT                        ; activesound
              .word   CONST_MF_SOLID_LO | CONST_MF_SHOOTABLE_LO | CONST_MF_COUNTKILL_LO ; flags
              .word   CONST_MF_SOLID_HI | CONST_MF_SHOOTABLE_HI | CONST_MF_COUNTKILL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_SHOTGUY
              .word   9                                       ; doomednum
              .word   CONST_S_SPOS_STND                       ; spawnstate
              .word   30                                      ; spawnhealth
              .word   CONST_S_SPOS_RUN1                       ; seestate
              .word   CONST_SFX_POSIT2                        ; seesound
              .word   8                                       ; reactiontime
              .word   0                                       ; attacksound
              .word   CONST_S_SPOS_PAIN                       ; painstate
              .byte   170                                     ; painchance
              .word   CONST_SFX_POPAIN                        ; painsound
              .word   0                                       ; meleestate
              .word   CONST_S_SPOS_ATK1                       ; missilestate
              .word   CONST_S_SPOS_DIE1                       ; deathstate
              .word   CONST_S_SPOS_XDIE1                      ; xdeathstate
              .word   CONST_SFX_PODTH2                        ; deathsound
              .long   8                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   56 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_POSACT                        ; activesound
              .word   CONST_MF_SOLID_LO | CONST_MF_SHOOTABLE_LO | CONST_MF_COUNTKILL_LO ; flags
              .word   CONST_MF_SOLID_HI | CONST_MF_SHOOTABLE_HI | CONST_MF_COUNTKILL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_TROOP
              .word   3001                                    ; doomednum
              .word   CONST_S_TROO_STND                       ; spawnstate
              .word   60                                      ; spawnhealth
              .word   CONST_S_TROO_RUN1                       ; seestate
              .word   CONST_SFX_BGSIT1                        ; seesound
              .word   8                                       ; reactiontime
              .word   0                                       ; attacksound
              .word   CONST_S_TROO_PAIN                       ; painstate
              .byte   200                                     ; painchance
              .word   CONST_SFX_POPAIN                        ; painsound
              .word   CONST_S_TROO_ATK1                       ; meleestate
              .word   CONST_S_TROO_ATK1                       ; missilestate
              .word   CONST_S_TROO_DIE1                       ; deathstate
              .word   CONST_S_TROO_XDIE1                      ; xdeathstate
              .word   CONST_SFX_BGDTH1                        ; deathsound
              .long   8                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   56 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_BGACT                         ; activesound
              .word   CONST_MF_SOLID_LO | CONST_MF_SHOOTABLE_LO | CONST_MF_COUNTKILL_LO ; flags
              .word   CONST_MF_SOLID_HI | CONST_MF_SHOOTABLE_HI | CONST_MF_COUNTKILL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_SERGEANT
              .word   3002                                    ; doomednum
              .word   CONST_S_SARG_STND                       ; spawnstate
              .word   150                                     ; spawnhealth
              .word   CONST_S_SARG_RUN1                       ; seestate
              .word   CONST_SFX_SGTSIT                        ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_SGTATK                        ; attacksound
              .word   CONST_S_SARG_PAIN                       ; painstate
              .byte   180                                     ; painchance
              .word   CONST_SFX_DMPAIN                        ; painsound
              .word   CONST_S_SARG_ATK1                       ; meleestate
              .word   0                                       ; missilestate
              .word   CONST_S_SARG_DIE1                       ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_SGTDTH                        ; deathsound
              .long   10                                      ; speed
              .long   30 * FRACUNIT                           ; radius
              .long   56 * FRACUNIT                           ; height
              .word   400                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_DMACT                         ; activesound
              .word   CONST_MF_SOLID_LO | CONST_MF_SHOOTABLE_LO | CONST_MF_COUNTKILL_LO ; flags
              .word   CONST_MF_SOLID_HI | CONST_MF_SHOOTABLE_HI | CONST_MF_COUNTKILL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_SHADOWS
              .word   58                                      ; doomednum
              .word   CONST_S_SARG_STND                       ; spawnstate
              .word   150                                     ; spawnhealth
              .word   CONST_S_SARG_RUN1                       ; seestate
              .word   CONST_SFX_SGTSIT                        ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_SGTATK                        ; attacksound
              .word   CONST_S_SARG_PAIN                       ; painstate
              .byte   180                                     ; painchance
              .word   CONST_SFX_DMPAIN                        ; painsound
              .word   CONST_S_SARG_ATK1                       ; meleestate
              .word   0                                       ; missilestate
              .word   CONST_S_SARG_DIE1                       ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_SGTDTH                        ; deathsound
              .long   10                                      ; speed
              .long   30 * FRACUNIT                           ; radius
              .long   56 * FRACUNIT                           ; height
              .word   400                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_DMACT                         ; activesound
              .word   CONST_MF_SOLID_LO | CONST_MF_SHOOTABLE_LO | CONST_MF_SHADOW_LO | CONST_MF_COUNTKILL_LO ; flags
              .word   CONST_MF_SOLID_HI | CONST_MF_SHOOTABLE_HI | CONST_MF_SHADOW_HI | CONST_MF_COUNTKILL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_BRUISER
              .word   3003                                    ; doomednum
              .word   CONST_S_BOSS_STND                       ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_BOSS_RUN1                       ; seestate
              .word   CONST_SFX_BRSSIT                        ; seesound
              .word   8                                       ; reactiontime
              .word   0                                       ; attacksound
              .word   CONST_S_BOSS_PAIN                       ; painstate
              .byte   50                                      ; painchance
              .word   CONST_SFX_DMPAIN                        ; painsound
              .word   CONST_S_BOSS_ATK1                       ; meleestate
              .word   CONST_S_BOSS_ATK1                       ; missilestate
              .word   CONST_S_BOSS_DIE1                       ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_BRSDTH                        ; deathsound
              .long   8                                       ; speed
              .long   24 * FRACUNIT                           ; radius
              .long   64 * FRACUNIT                           ; height
              .word   1000                                    ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_DMACT                         ; activesound
              .word   CONST_MF_SOLID_LO | CONST_MF_SHOOTABLE_LO | CONST_MF_COUNTKILL_LO ; flags
              .word   CONST_MF_SOLID_HI | CONST_MF_SHOOTABLE_HI | CONST_MF_COUNTKILL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_BRUISERSHOT
              .word   -1                                      ; doomednum
              .word   CONST_S_BRBALL1                         ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_FIRSHT                        ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_BRBALLX1                        ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_FIRXPL                        ; deathsound
              .long   15 * FRACUNIT                           ; speed
              .long   6 * FRACUNIT                            ; radius
              .long   8 * FRACUNIT                            ; height
              .word   100                                     ; mass
              .word   8                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_NOBLOCKMAP_LO | CONST_MF_MISSILE_LO | CONST_MF_DROPOFF_LO | CONST_MF_NOGRAVITY_LO ; flags
              .word   CONST_MF_NOBLOCKMAP_HI | CONST_MF_MISSILE_HI | CONST_MF_DROPOFF_HI | CONST_MF_NOGRAVITY_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_BARREL
              .word   2035                                    ; doomednum
              .word   CONST_S_BAR1                            ; spawnstate
              .word   20                                      ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_BEXP                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_BAREXP                        ; deathsound
              .long   0                                       ; speed
              .long   10 * FRACUNIT                           ; radius
              .long   42 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SOLID_LO | CONST_MF_SHOOTABLE_LO | CONST_MF_NOBLOOD_LO ; flags
              .word   CONST_MF_SOLID_HI | CONST_MF_SHOOTABLE_HI | CONST_MF_NOBLOOD_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_TROOPSHOT
              .word   -1                                      ; doomednum
              .word   CONST_S_TBALL1                          ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_FIRSHT                        ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_TBALLX1                         ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_FIRXPL                        ; deathsound
              .long   10 * FRACUNIT                           ; speed
              .long   6 * FRACUNIT                            ; radius
              .long   8 * FRACUNIT                            ; height
              .word   100                                     ; mass
              .word   3                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_NOBLOCKMAP_LO | CONST_MF_MISSILE_LO | CONST_MF_DROPOFF_LO | CONST_MF_NOGRAVITY_LO ; flags
              .word   CONST_MF_NOBLOCKMAP_HI | CONST_MF_MISSILE_HI | CONST_MF_DROPOFF_HI | CONST_MF_NOGRAVITY_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_ROCKET
              .word   -1                                      ; doomednum
              .word   CONST_S_ROCKET                          ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_EXPLODE1                        ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_BAREXP                        ; deathsound
              .long   20 * FRACUNIT                           ; speed
              .long   11 * FRACUNIT                           ; radius
              .long   8 * FRACUNIT                            ; height
              .word   100                                     ; mass
              .word   20                                      ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_NOBLOCKMAP_LO | CONST_MF_MISSILE_LO | CONST_MF_DROPOFF_LO | CONST_MF_NOGRAVITY_LO ; flags
              .word   CONST_MF_NOBLOCKMAP_HI | CONST_MF_MISSILE_HI | CONST_MF_DROPOFF_HI | CONST_MF_NOGRAVITY_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_PUFF
              .word   -1                                      ; doomednum
              .word   CONST_S_PUFF1                           ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_NOBLOCKMAP_LO | CONST_MF_NOGRAVITY_LO ; flags
              .word   CONST_MF_NOBLOCKMAP_HI | CONST_MF_NOGRAVITY_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_BLOOD
              .word   -1                                      ; doomednum
              .word   CONST_S_BLOOD1                          ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_NOBLOCKMAP_LO ; flags
              .word   CONST_MF_NOBLOCKMAP_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_TFOG
              .word   -1                                      ; doomednum
              .word   CONST_S_TFOG                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_NOBLOCKMAP_LO | CONST_MF_NOGRAVITY_LO ; flags
              .word   CONST_MF_NOBLOCKMAP_HI | CONST_MF_NOGRAVITY_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_TELEPORTMAN
              .word   14                                      ; doomednum
              .word   CONST_S_NULL                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_NOBLOCKMAP_LO | CONST_MF_NOSECTOR_LO ; flags
              .word   CONST_MF_NOBLOCKMAP_HI | CONST_MF_NOSECTOR_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC0
              .word   2018                                    ; doomednum
              .word   CONST_S_ARM1                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC1
              .word   2019                                    ; doomednum
              .word   CONST_S_ARM2                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC2
              .word   2014                                    ; doomednum
              .word   CONST_S_BON1                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO | CONST_MF_COUNTITEM_LO ; flags
              .word   CONST_MF_SPECIAL_HI | CONST_MF_COUNTITEM_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC3
              .word   2015                                    ; doomednum
              .word   CONST_S_BON2                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO | CONST_MF_COUNTITEM_LO ; flags
              .word   CONST_MF_SPECIAL_HI | CONST_MF_COUNTITEM_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC4
              .word   5                                       ; doomednum
              .word   CONST_S_BKEY                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC5
              .word   13                                      ; doomednum
              .word   CONST_S_RKEY                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC6
              .word   6                                       ; doomednum
              .word   CONST_S_YKEY                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC10
              .word   2011                                    ; doomednum
              .word   CONST_S_STIM                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC11
              .word   2012                                    ; doomednum
              .word   CONST_S_MEDI                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC12
              .word   2013                                    ; doomednum
              .word   CONST_S_SOUL                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO | CONST_MF_COUNTITEM_LO ; flags
              .word   CONST_MF_SPECIAL_HI | CONST_MF_COUNTITEM_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_INS
              .word   2024                                    ; doomednum
              .word   CONST_S_PINS                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO | CONST_MF_COUNTITEM_LO ; flags
              .word   CONST_MF_SPECIAL_HI | CONST_MF_COUNTITEM_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC14
              .word   2025                                    ; doomednum
              .word   CONST_S_SUIT                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC15
              .word   2026                                    ; doomednum
              .word   CONST_S_PMAP                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO | CONST_MF_COUNTITEM_LO ; flags
              .word   CONST_MF_SPECIAL_HI | CONST_MF_COUNTITEM_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC16
              .word   2045                                    ; doomednum
              .word   CONST_S_PVIS                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO | CONST_MF_COUNTITEM_LO ; flags
              .word   CONST_MF_SPECIAL_HI | CONST_MF_COUNTITEM_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_CLIP
              .word   2007                                    ; doomednum
              .word   CONST_S_CLIP                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC17
              .word   2048                                    ; doomednum
              .word   CONST_S_AMMO                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC18
              .word   2010                                    ; doomednum
              .word   CONST_S_ROCK                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC19
              .word   2046                                    ; doomednum
              .word   CONST_S_BROK                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC22
              .word   2008                                    ; doomednum
              .word   CONST_S_SHEL                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC23
              .word   2049                                    ; doomednum
              .word   CONST_S_SBOX                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC24
              .word   8                                       ; doomednum
              .word   CONST_S_BPAK                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_CHAINGUN
              .word   2002                                    ; doomednum
              .word   CONST_S_MGUN                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC26
              .word   2005                                    ; doomednum
              .word   CONST_S_CSAW                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC27
              .word   2003                                    ; doomednum
              .word   CONST_S_LAUN                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_SHOTGUN
              .word   2001                                    ; doomednum
              .word   CONST_S_SHOT                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SPECIAL_LO ; flags
              .word   CONST_MF_SPECIAL_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC31
              .word   2028                                    ; doomednum
              .word   CONST_S_COLU                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   16 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SOLID_LO ; flags
              .word   CONST_MF_SOLID_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC43
              .word   46                                      ; doomednum
              .word   CONST_S_REDTORCH                        ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   16 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SOLID_LO ; flags
              .word   CONST_MF_SOLID_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC48
              .word   48                                      ; doomednum
              .word   CONST_S_TECHPILLAR                      ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   16 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SOLID_LO ; flags
              .word   CONST_MF_SOLID_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC49
              .word   34                                      ; doomednum
              .word   CONST_S_CANDLESTIK                      ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .long   0                                       ; flags
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC50
              .word   35                                      ; doomednum
              .word   CONST_S_CANDELABRA                      ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   16 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .word   CONST_MF_SOLID_LO ; flags
              .word   CONST_MF_SOLID_HI
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC62
              .word   15                                      ; doomednum
              .word   CONST_S_PLAY_DIE7                       ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .long   0                                       ; flags
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC68
              .word   10                                      ; doomednum
              .word   CONST_S_PLAY_XDIE9                      ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .long   0                                       ; flags
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC69
              .word   12                                      ; doomednum
              .word   CONST_S_PLAY_XDIE9                      ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .long   0                                       ; flags
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_MISC71
              .word   24                                      ; doomednum
              .word   CONST_S_GIBS                            ; spawnstate
              .word   1000                                    ; spawnhealth
              .word   CONST_S_NULL                            ; seestate
              .word   CONST_SFX_NONE                          ; seesound
              .word   8                                       ; reactiontime
              .word   CONST_SFX_NONE                          ; attacksound
              .word   CONST_S_NULL                            ; painstate
              .byte   0                                       ; painchance
              .word   CONST_SFX_NONE                          ; painsound
              .word   CONST_S_NULL                            ; meleestate
              .word   CONST_S_NULL                            ; missilestate
              .word   CONST_S_NULL                            ; deathstate
              .word   CONST_S_NULL                            ; xdeathstate
              .word   CONST_SFX_NONE                          ; deathsound
              .long   0                                       ; speed
              .long   20 * FRACUNIT                           ; radius
              .long   16 * FRACUNIT                           ; height
              .word   100                                     ; mass
              .word   0                                       ; damage
              .word   CONST_SFX_NONE                          ; activesound
              .long   0                                       ; flags
              .space  INFO_SIZE - SIZEOF_MI
              ; MT_NOTHING: all 0
              .space  INFO_SIZE
