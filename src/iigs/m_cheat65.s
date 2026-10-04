;;; Incremental cheat-key matching and cheat actions.
;;;
;;; Each sequence retains its current match position. A mismatch resets that
;;; sequence without trying the same key again as a new start. The first
;;; completed entry handles the key; entries after it do not see that key.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "keys.inc"

              .extern _Dp, _g_player, _g_gameaction, _g_fps_show
              .extern P_GivePower, G_ExitLevel

PL            .equ    _g_player
GOD_HEALTH    .equ    100             ; cheat grants: health
IDFA_ARMOR    .equ    200             ;   of iddqd, the armor of idfa and
IDFA_ARMOR_CLASS .equ 2               ;   idkfa
NUMCHEATS     .equ    15
EV_KEYDOWN    .equ    0
EV_DATA1      .equ    2
GA_VICTORY    .equ    7

              .section znear, bss
CHT_P:        .space  (2 * NUMCHEATS) ; the next character of each sequence
CH_KEY:       .space  2
CH_I:         .space  2

              .section cfar, rodata
seqs:
seqChoppers:  .asciz  "idchoppers"
seqGod:       .asciz  "iddqd"
seqKfa:       .asciz  "idkfa"
seqFa:        .asciz  "idfa"
seqNoclip:    .asciz  "idspispopd"
seqBeholdV:   .asciz  "idbeholdv"
seqBeholdS:   .asciz  "idbeholds"
seqBeholdI:   .asciz  "idbeholdi"
seqBeholdR:   .asciz  "idbeholdr"
seqBeholdA:   .asciz  "idbeholda"
seqBeholdL:   .asciz  "idbeholdl"
seqClev:      .asciz  "idclev"
seqEnd:       .asciz  "idend"
seqRocket:    .asciz  "idrocket"
seqRate:      .asciz  "idrate"
seqStart:     .word   seqChoppers - seqs, seqGod - seqs, seqKfa - seqs, seqFa - seqs
              .word   seqNoclip - seqs, seqBeholdV - seqs, seqBeholdS - seqs
              .word   seqBeholdI - seqs, seqBeholdR - seqs, seqBeholdA - seqs
              .word   seqBeholdL - seqs, seqClev - seqs, seqEnd - seqs
              .word   seqRocket - seqs, seqRate - seqs
msgDqdOn:     .asciz  "Degreelessness Mode On"
msgDqdOff:    .asciz  "Degreelessness Mode Off"
msgKfa:       .asciz  "Very Happy Ammo Added"
msgFa:        .asciz  "Ammo (no keys) Added"
msgNcOn:      .asciz  "No Clipping Mode On"
msgNcOff:     .asciz  "No Clipping Mode Off"
msgChoppers:  .asciz  "... doesn't suck - GM"
msgRocketOn:  .asciz  "Enemy Rockets On"
msgRocketOff: .asciz  "Enemy Rockets Off"
msgFpsOn:     .asciz  "FPS Counter On"
msgFpsOff:    .asciz  "FPS Counter Off"

;;; ---------------------------------------------------------------------------
;;; boolean C_Responder(event_t* ev)     In: _Dp[0-3] = ev.
;;; A character key down goes to each cheat sequence: true for a completed
;;; cheat. A Doom key (W, A, S, D, E and the digits are Doom keys and
;;; characters) does not stop a sequence.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public C_Responder
C_Responder:  lda     [.tiny _Dp]
              cmp     ##EV_KEYDOWN
              bne     9$
              ldy     ##EV_DATA1            ; (char) data1
              lda     [.tiny _Dp],y
              and     ##0x00ff
              cmp     ##NUMKEYS
              bcc     9$
              sta     .near CH_KEY
              ldx     ##0                   ; each cheat
1$:           stx     .near CH_I
              lda     long:seqStart,x       ; the character at p
              clc
              adc     abs:.near CHT_P,x
              tay
              tyx
              lda     long:seqs,x
              and     ##0x00ff
              ldx     .near CH_I
              cmp     .near CH_KEY          ; the same: p++, else the start
              bne     2$
              inc     abs:.near CHT_P,x
              iny
              bra     3$
2$:           stz     abs:.near CHT_P,x
              lda     long:seqStart,x
              tay
3$:           tyx                           ; the end of the sequence: the
              lda     long:seqs,x           ;   cheat works
              ldx     .near CH_I
              and     ##0x00ff              ; (the flags after the ldx)
              bne     4$
              stz     abs:.near CHT_P,x
              jsr     (.kbank cheats,x)
              lda     ##1
              rtl
4$:           inx
              inx
              cpx     ##(2 * NUMCHEATS)
              bcc     1$
9$:           lda     ##0
              rtl

cheats:       .word   .word0 cheatChoppers, .word0 cheatGod, .word0 cheatKfa
              .word   .word0 cheatFa, .word0 cheatNoclip, .word0 cheatBeholdV
              .word   .word0 cheatBeholdS, .word0 cheatBeholdI, .word0 cheatBeholdR
              .word   .word0 cheatBeholdA, .word0 cheatBeholdL, .word0 cheatClev
              .word   .word0 cheatEnd, .word0 cheatRocket, .word0 cheatRate

;;; message: the message of the player is the string at X (its low word)
;;; in bank C.
message:      stx     .near (PL+OFS_PL_MESSAGE)
              sta     .near (PL+OFS_PL_MESSAGE+2)
              rts

;;; power: P_GivePower(&_g_player, C).
power:        ldx     ##.near PL
              stx     dp:.tiny _Dp
              ldx     ##.word2 PL
              stx     dp:.tiny (_Dp+2)
              jsl     long:P_GivePower
              rts

;;; iddqd: god mode on or off (on: full health).
cheatGod:     lda     .near (PL+OFS_PL_CHEATS)
              eor     ##CONST_CF_GODMODE
              sta     .near (PL+OFS_PL_CHEATS)
              and     ##CONST_CF_GODMODE
              beq     1$
              lda     ##GOD_HEALTH
              sta     .near (PL+OFS_PL_HEALTH)
              ldx     ##.word0 msgDqdOn
              lda     ##.word2 msgDqdOn
              bra     message
1$:           ldx     ##.word0 msgDqdOff
              lda     ##.word2 msgDqdOff
              bra     message

;;; idchoppers: the chainsaw, invulnerability.
cheatChoppers:
              lda     ##1
              sta     .near (PL+OFS_PL_WEAPONOWNED+2*CONST_WP_CHAINSAW)
              lda     ##CONST_WP_CHAINSAW
              sta     .near (PL+OFS_PL_PENDINGWEAPON)
              lda     ##CONST_PW_INVULNERABILITY
              jsr     .kbank power
              ldx     ##.word0 msgChoppers
              lda     ##.word2 msgChoppers
              bra     message

;;; idkfa: the ammo of idfa, and all the cards.
cheatKfa:     jsr     .kbank giveAmmo
              ldx     ##(2 * CONST_NUMCARDS - 2) ; (boolean cards)
              lda     ##1
1$:           sta     .near (PL+OFS_PL_CARDS),x
              dex
              dex
              bpl     1$
              ldx     ##.word0 msgKfa
              lda     ##.word2 msgKfa
              bra     message

;;; idfa: a backpack, armor, the weapons of the shareware game, full ammo
;;; (but cells).
cheatFa:      jsr     .kbank giveAmmo
              ldx     ##.word0 msgFa
              lda     ##.word2 msgFa
              bra     message

giveAmmo:     lda     .near (PL+OFS_PL_BACKPACK) ; no backpack: double maximum
              bne     2$
              ldx     ##(2 * CONST_NUMAMMO - 2)
1$:           lda     .near (PL+OFS_PL_MAXAMMO),x
              asl     a
              sta     .near (PL+OFS_PL_MAXAMMO),x
              dex
              dex
              bpl     1$
              lda     ##1
              sta     .near (PL+OFS_PL_BACKPACK)
2$:           lda     ##IDFA_ARMOR
              sta     .near (PL+OFS_PL_ARMORPOINTS)
              lda     ##IDFA_ARMOR_CLASS
              sta     .near (PL+OFS_PL_ARMORTYPE)
              ldx     ##(2 * CONST_NUMWEAPONS - 2) ; not plasma, BFG, super shotgun
3$:           cpx     ##(2 * CONST_WP_PLASMA)
              beq     4$
              cpx     ##(2 * CONST_WP_BFG)
              beq     4$
              cpx     ##(2 * CONST_WP_SUPERSHOTGUN)
              beq     4$
              lda     ##1
              sta     .near (PL+OFS_PL_WEAPONOWNED),x
4$:           dex
              dex
              bpl     3$
              ldx     ##(2 * CONST_NUMAMMO - 2) ; full ammo, not cells
5$:           cpx     ##(2 * CONST_AM_CELL)
              beq     6$
              lda     .near (PL+OFS_PL_MAXAMMO),x
              sta     .near (PL+OFS_PL_AMMO),x
6$:           dex
              dex
              bpl     5$
              rts

;;; idspispopd: no clipping on or off.
cheatNoclip:  lda     .near (PL+OFS_PL_CHEATS)
              eor     ##CONST_CF_NOCLIP
              sta     .near (PL+OFS_PL_CHEATS)
              and     ##CONST_CF_NOCLIP
              beq     1$
              ldx     ##.word0 msgNcOn
              lda     ##.word2 msgNcOn
              brl     message
1$:           ldx     ##.word0 msgNcOff
              lda     ##.word2 msgNcOff
              brl     message

;;; idbehold v, s, i, r, a, l: the powers.
cheatBeholdV: lda     ##CONST_PW_INVULNERABILITY
              brl     power
cheatBeholdS: lda     ##CONST_PW_STRENGTH
              brl     power
cheatBeholdI: lda     ##CONST_PW_INVISIBILITY
              brl     power
cheatBeholdR: lda     ##CONST_PW_IRONFEET
              brl     power
cheatBeholdA: lda     ##CONST_PW_ALLMAP
              brl     power
cheatBeholdL: lda     ##CONST_PW_INFRARED
              brl     power

;;; idclev: the level ends. idend: the finale.
cheatClev:    jsl     long:G_ExitLevel
              rts
cheatEnd:     lda     ##GA_VICTORY
              sta     .near _g_gameaction
              rts

;;; idrocket: enemy rockets on (with health and the rocket launcher) or off.
cheatRocket:  lda     .near (PL+OFS_PL_CHEATS)
              eor     ##CONST_CF_ENEMY_ROCKETS
              sta     .near (PL+OFS_PL_CHEATS)
              and     ##CONST_CF_ENEMY_ROCKETS
              beq     1$
              lda     ##GOD_HEALTH
              sta     .near (PL+OFS_PL_HEALTH)
              lda     ##1
              sta     .near (PL+OFS_PL_WEAPONOWNED+2*CONST_WP_MISSILE)
              lda     .near (PL+OFS_PL_MAXAMMO+2*CONST_AM_MISL)
              sta     .near (PL+OFS_PL_AMMO+2*CONST_AM_MISL)
              lda     ##CONST_WP_MISSILE
              sta     .near (PL+OFS_PL_PENDINGWEAPON)
              ldx     ##.word0 msgRocketOn
              lda     ##.word2 msgRocketOn
              brl     message
1$:           ldx     ##.word0 msgRocketOff
              lda     ##.word2 msgRocketOff
              brl     message

;;; idrate: the frame rate on or off.
cheatRate:    lda     .near _g_fps_show
              beq     1$
              stz     .near _g_fps_show
              ldx     ##.word0 msgFpsOff
              lda     ##.word2 msgFpsOff
              brl     message
1$:           lda     ##1
              sta     .near _g_fps_show
              ldx     ##.word0 msgFpsOn
              lda     ##.word2 msgFpsOn
              brl     message
