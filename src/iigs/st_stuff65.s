;;; Status bar.
;;; Widgets hold near addresses of values and patch lists. Changed widgets
;;; restore their background before drawing; the menu forces a full redraw
;;; on return. Damage, bonus and radiation-suit tints follow ST_doPaletteStuff.

              .extern weaponOffsets
              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "viewwin.inc"

              .extern _Dp, _g_player, weaponinfo, _g_fps_show, _g_fps_framerate
              .extern _g_menuactive, M_Random, R_PointToAngle3
              .extern W_GetNumForName, W_GetLumpByNum, Z_ChangeTagToCache
              .extern V_NumPatchWidth, V_DrawNumPatchNotScaled, V_DrawRaw
              .extern I_SaveStatusBackground, I_RestoreStatusRect, I_SetPalette
              .extern IIGS_MulLo16, _Div16, _UDivMod16
              .extern I_GetTime, TINTPAL, _g_gamemap, _g_gamma
              .extern tintPeak, tintLeft, tintShow, tintUntil
              .extern tintMark, tintMarkG, tintSave, tintOut, tintC0, tintC8

PL            .equ    _g_player
ST_Y          .equ    168             ; SCREENHEIGHT - ST_HEIGHT
ST_FACESTRIDE .equ    8               ; 3 straight, 2 turn, 3 special faces
ST_NUMPAINFACES .equ  5
ST_TURNOFFSET .equ    3
ST_OUCHOFFSET .equ    5
ST_EVILGRINOFFSET .equ 6
ST_RAMPAGEOFFSET .equ 7
ST_GODFACE    .equ    40
ST_DEADFACE   .equ    41
ST_NUMFACES   .equ    42
ST_EVILGRINCOUNT .equ (2 * CONST_TICRATE)
ST_STRAIGHTFACECOUNT .equ 18
ST_TURNCOUNT  .equ    CONST_TICRATE
ST_RAMPAGEDELAY .equ  (2 * CONST_TICRATE)
ST_MUCHPAIN   .equ    20
LARGEAMMO     .equ    1994            ; "n/a"
STARTREDPALS  .equ    1
STARTBONUSPALS .equ   9
NUMREDPALS    .equ    8
NUMBONUSPALS  .equ    4
RADIATIONPAL  .equ    13

;;; a number widget: x, y, width, oldnum, num (near), p (near)
NW_X          .equ    0
NW_Y          .equ    2
NW_WIDTH      .equ    4
NW_OLDNUM     .equ    6
NW_NUM        .equ    8
NW_P          .equ    10
NW_SIZE       .equ    12
;;; an icon widget: x, y, oldinum, inum (near), p (near)
IW_X          .equ    0
IW_Y          .equ    2
IW_OLDINUM    .equ    4
IW_INUM       .equ    6
IW_P          .equ    8
IW_SIZE       .equ    10

              .section znear, bss
statusbarnum: .space  2
starmsnum:    .space  2
tallpercentnum: .space 2
tallnum:      .space  20
shortnum:     .space  20
keys:         .space  (2 * CONST_NUMCARDS)
faces:        .space  (2 * ST_NUMFACES)
arms:         .space  24              ; [6][2]: gray, yellow
W_READY:      .space  NW_SIZE
W_HEALTH:     .space  NW_SIZE
W_ARMOR:      .space  NW_SIZE
W_AMMO:       .space  (4 * NW_SIZE)
W_MAXAMMO:    .space  (4 * NW_SIZE)
W_ARMS:       .space  (6 * IW_SIZE)
W_FACES:      .space  IW_SIZE
W_KEYBOXES:   .space  (3 * IW_SIZE)
oldweaponsowned: .space (2 * CONST_NUMWEAPONS)
st_facecount: .space  2
st_faceindex: .space  2
keyboxes:     .space  6
st_randomnumber: .space 2
st_oldhealth: .space  2
largeammo:    .space  2               ; LARGEAMMO (ST_Init)
st_running:   .space  2               ; !st_stopped
st_refreshed: .space  2               ; !st_needrefresh
st_palette:   .space  2
st_priority:  .space  2               ; the face widget
st_lastattackdown: .space 2           ; -1 (ST_Init)
st_oldhealthPO: .space 2              ; Cached health; ST_Init sets -1.
st_lastcalc:  .space  2
ST_W:         .space  2               ; the widget
ST_NUM:       .space  2               ; drawNum
ST_DIGITS:    .space  2
ST_PX:        .space  2
ST_PW:        .space  2
ST_T:         .space  4
ST_DRAWN:     .space  2
ST_I:         .space  2
ST_NAME:      .space  2               ; ST_loadData: the name list

              .section cfar, rodata
;;; the lump names of ST_loadData, in its order (the table stNames)
nmBar:        .asciz  "STBAR"
nmArms:       .asciz  "STARMS"
nmPercent:    .asciz  "STTPRCNT"
nmNums:       .asciz  "STTNUM0", "STYSNUM0", "STTNUM1", "STYSNUM1"
              .asciz  "STTNUM2", "STYSNUM2", "STTNUM3", "STYSNUM3"
              .asciz  "STTNUM4", "STYSNUM4", "STTNUM5", "STYSNUM5"
              .asciz  "STTNUM6", "STYSNUM6", "STTNUM7", "STYSNUM7"
              .asciz  "STTNUM8", "STYSNUM8", "STTNUM9", "STYSNUM9"
nmKeys:       .asciz  "STKEYS0", "STKEYS1", "STKEYS2"
nmGray:       .asciz  "STGNUM2", "STGNUM3", "STGNUM4", "STGNUM5", "STGNUM6", "STGNUM7"
nmFaces:      .asciz  "STFST00", "STFST01", "STFST02", "STFTR00", "STFTL00"
              .asciz  "STFOUCH0", "STFEVL0", "STFKILL0"
              .asciz  "STFST10", "STFST11", "STFST12", "STFTR10", "STFTL10"
              .asciz  "STFOUCH1", "STFEVL1", "STFKILL1"
              .asciz  "STFST20", "STFST21", "STFST22", "STFTR20", "STFTL20"
              .asciz  "STFOUCH2", "STFEVL2", "STFKILL2"
              .asciz  "STFST30", "STFST31", "STFST32", "STFTR30", "STFTL30"
              .asciz  "STFOUCH3", "STFEVL3", "STFKILL3"
              .asciz  "STFST40", "STFST41", "STFST42", "STFTR40", "STFTL40"
              .asciz  "STFOUCH4", "STFEVL4", "STFKILL4"
              .asciz  "STFGOD0", "STFDEAD0"
nmEnd:
;;; Ammo-count rows in type order: bullets, shells, rockets, cells.
ammoRows:     .word   ST_Y+5, ST_Y+11, ST_Y+17, ST_Y+23

;;; ---------------------------------------------------------------------------
;;; void ST_Init(void): resolve status-bar lump numbers and initialize
;;; cached widget values used to detect changes between redraws.
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public ST_Init
ST_Init:      lda     ##LARGEAMMO
              sta     .near largeammo
              lda     ##0xffff
              sta     .near st_lastattackdown
              sta     .near st_oldhealthPO
              lda     ##.word0 nmBar        ; STBAR, STARMS, STTPRCNT
              sta     .near ST_NAME
              jsr     .kbank lumpNum
              sta     .near statusbarnum
              jsr     .kbank lumpNum
              sta     .near starmsnum
              jsr     .kbank lumpNum
              sta     .near tallpercentnum
              ldx     ##0                   ; the tall and short numbers
1$:           phx
              jsr     .kbank lumpNum
              plx
              sta     abs:.near tallnum,x
              phx
              jsr     .kbank lumpNum
              plx
              sta     abs:.near shortnum,x
              inx
              inx
              cpx     ##20
              bcc     1$
              ldx     ##0                   ; the key cards
2$:           phx
              jsr     .kbank lumpNum
              plx
              sta     abs:.near keys,x
              inx
              inx
              cpx     ##(2 * CONST_NUMCARDS)
              bcc     2$
              ldx     ##0                   ; Arms: STGNUMn gray, shortnum
                                            ; yellow.
3$:           phx
              jsr     .kbank lumpNum
              plx
              sta     abs:.near arms,x
              txa                           ; (x = 4 * i: shortnum[i + 2])
              lsr     a
              tay
              lda     abs:.near (shortnum+4),y
              sta     abs:.near (arms+2),x
              inx
              inx
              inx
              inx
              cpx     ##24
              bcc     3$
              ldx     ##0                   ; the faces
4$:           phx
              jsr     .kbank lumpNum
              plx
              sta     abs:.near faces,x
              inx
              inx
              cpx     ##(2 * ST_NUMFACES)
              bcc     4$
              rtl

;;; lumpNum: C = W_GetNumForName(the name at ST_NAME); ST_NAME moves to
;;; the next name.
lumpNum:      lda     .near ST_NAME
              sta     dp:.tiny _Dp
              lda     ##.word2 nmBar
              sta     dp:.tiny (_Dp+2)
              ldy     ##0                   ; the next name
              sep     #0x20
2$:           lda     [.tiny _Dp],y
              iny
              cmp     #0
              bne     2$
              rep     #0x20
              tya
              clc
              adc     .near ST_NAME
              sta     .near ST_NAME
              jsl     long:W_GetNumForName
              rts

;;; ---------------------------------------------------------------------------
;;; void ST_Start(void): the status bar of a new level.
;;; ---------------------------------------------------------------------------
              .public ST_Start
ST_Start:     stz     .near st_refreshed    ; st_needrefresh = true
              lda     .near st_running      ; ST_Stop
              beq     1$
              lda     ##0
              jsl     long:I_SetPalette
              stz     .near st_running
1$:           stz     .near st_faceindex    ; ST_initData
              lda     ##0xffff              ; ST_initPalette
              sta     .near st_palette
              sta     .near st_oldhealth
              ldx     ##(2 * CONST_NUMWEAPONS - 2)
2$:           lda     abs:.near (PL+OFS_PL_WEAPONOWNED),x
              sta     abs:.near oldweaponsowned,x
              dex
              dex
              bpl     2$
              lda     ##0xffff
              sta     .near keyboxes
              sta     .near (keyboxes+2)
              sta     .near (keyboxes+4)
              ;; ST_createWidgets
              ldx     ##.near W_READY       ; the ready weapon's ammo
              lda     ##44                  ; ST_AMMOX
              ldy     ##(ST_Y+3)
              jsr     .kbank tallNum
              lda     .near (PL+OFS_PL_READYWEAPON) ; Ready weapon's ammo field.
              asl     a                     ; weapon 0..8 -> word offset-table index
              tax
              lda     long:weaponOffsets,x ; record offset (SIZEOF_WI = 12)
              nop                           ; retain following cache slots
              tax
              lda     abs:.near (weaponinfo+OFS_WI_AMMO),x
              asl     a
              clc
              adc     ##.near (PL+OFS_PL_AMMO)
              sta     .near (W_READY+NW_NUM)
              ldx     ##.near W_HEALTH      ; health percentage
              lda     ##90
              ldy     ##(ST_Y+3)
              jsr     .kbank tallNum
              lda     ##.near (PL+OFS_PL_HEALTH)
              sta     .near (W_HEALTH+NW_NUM)
              ldx     ##.near W_ARMOR       ; armor percentage
              lda     ##221
              ldy     ##(ST_Y+3)
              jsr     .kbank tallNum
              lda     ##.near (PL+OFS_PL_ARMORPOINTS)
              sta     .near (W_ARMOR+NW_NUM)
              ldx     ##0                   ; Weapons: 3 x 2 from x = 111.
3$:           txa                           ; y ST_Y + 4, 12 and 10 apart
              ldy     ##IW_SIZE
              jsr     .kbank mulXY
              tay                           ; (Y = the widget offset)
              txa                           ; x = 111 + (i % 3) * 12
              cmp     ##3
              bcc     31$
              sbc     ##3
31$:          asl     a
              asl     a
              sta     .near ST_T
              asl     a
              clc
              adc     .near ST_T
              adc     ##111
              sta     abs:.near (W_ARMS+IW_X),y
              lda     ##(ST_Y+4)            ; y = ST_Y + 4 + (i / 3) * 10
              cpx     ##3
              bcc     32$
              adc     ##9                   ; (carry set: + 10)
32$:          sta     abs:.near (W_ARMS+IW_Y),y
              lda     ##0xffff
              sta     abs:.near (W_ARMS+IW_OLDINUM),y
              txa                           ; inum = &weaponowned[i + 1]
              asl     a
              clc
              adc     ##.near (PL+OFS_PL_WEAPONOWNED+2)
              sta     abs:.near (W_ARMS+IW_INUM),y
              txa                           ; p = arms[i]
              asl     a
              asl     a
              clc
              adc     ##.near arms
              sta     abs:.near (W_ARMS+IW_P),y
              inx
              cpx     ##6
              bcc     3$
              ldx     ##0                   ; Keys: x 239, y offsets 3/13/23.
4$:           txa
              ldy     ##IW_SIZE
              jsr     .kbank mulXY
              tay
              lda     ##239
              sta     abs:.near (W_KEYBOXES+IW_X),y
              txa
              ldy     ##10
              jsr     .kbank mulXY
              clc
              adc     ##(ST_Y+3)
              pha
              txa
              ldy     ##IW_SIZE
              jsr     .kbank mulXY
              tay
              pla
              sta     abs:.near (W_KEYBOXES+IW_Y),y
              lda     ##0xffff
              sta     abs:.near (W_KEYBOXES+IW_OLDINUM),y
              txa
              asl     a
              clc
              adc     ##.near keyboxes
              sta     abs:.near (W_KEYBOXES+IW_INUM),y
              lda     ##.near keys
              sta     abs:.near (W_KEYBOXES+IW_P),y
              inx
              cpx     ##3
              bcc     4$
              ldx     ##0                   ; Ammo and maximum: short digits.
5$:           txa                           ; numbers at 288 and 314, y + 5, 11,
              ldy     ##NW_SIZE             ; 17, 23
              jsr     .kbank mulXY
              tay
              txa
              asl     a
              sta     .near ST_T            ; (2 * i)
              phx                           ; y: ammoRows
              tax
              lda     long:ammoRows,x
              plx
              sta     abs:.near (W_AMMO+NW_Y),y
              sta     abs:.near (W_MAXAMMO+NW_Y),y
              lda     ##288
              sta     abs:.near (W_AMMO+NW_X),y
              lda     ##314
              sta     abs:.near (W_MAXAMMO+NW_X),y
              lda     ##3
              sta     abs:.near (W_AMMO+NW_WIDTH),y
              sta     abs:.near (W_MAXAMMO+NW_WIDTH),y
              lda     ##0
              sta     abs:.near (W_AMMO+NW_OLDNUM),y
              sta     abs:.near (W_MAXAMMO+NW_OLDNUM),y
              lda     .near ST_T
              clc
              adc     ##.near (PL+OFS_PL_AMMO)
              sta     abs:.near (W_AMMO+NW_NUM),y
              lda     .near ST_T
              clc
              adc     ##.near (PL+OFS_PL_MAXAMMO)
              sta     abs:.near (W_MAXAMMO+NW_NUM),y
              lda     ##.near shortnum
              sta     abs:.near (W_AMMO+NW_P),y
              sta     abs:.near (W_MAXAMMO+NW_P),y
              inx
              cpx     ##4
              bcc     5$
              lda     ##143                 ; the face
              sta     .near (W_FACES+IW_X)
              lda     ##ST_Y
              sta     .near (W_FACES+IW_Y)
              lda     ##0xffff
              sta     .near (W_FACES+IW_OLDINUM)
              lda     ##.near st_faceindex
              sta     .near (W_FACES+IW_INUM)
              lda     ##.near faces
              sta     .near (W_FACES+IW_P)
              lda     ##1                   ; st_stopped = false
              sta     .near st_running
              rtl

;;; tallNum: the number widget at near X: x C, y Y, width 3, oldnum 0,
;;; the tall numbers.
tallNum:      sta     abs:NW_X,x
              tya
              sta     abs:NW_Y,x
              lda     ##3
              sta     abs:NW_WIDTH,x
              stz     abs:NW_OLDNUM,x
              lda     ##.near tallnum
              sta     abs:NW_P,x
              rts

;;; mulXY: C = C * Y (small values). X stays.
mulXY:        phx
              tyx
              jsl     long:IIGS_MulLo16
              plx
              rts

;;; readyNum: w_ready.num: the frame rate (the fps cheat), largeammo for a
;;; weapon without ammo, else the ammo of the ready weapon.
readyNum:     lda     .near _g_fps_show
              beq     1$
              lda     ##.near _g_fps_framerate
              bra     3$
1$:           lda     .near (PL+OFS_PL_READYWEAPON)
              asl     a                     ; weapon 0..8 -> word offset-table index
              tax
              lda     long:weaponOffsets,x ; record offset (SIZEOF_WI = 12)
              nop                           ; retain following cache slots
              tax
              lda     abs:.near (weaponinfo+OFS_WI_AMMO),x
              cmp     ##CONST_AM_NOAMMO
              bne     2$
              lda     ##.near largeammo
              bra     3$
2$:           asl     a
              clc
              adc     ##.near (PL+OFS_PL_AMMO)
3$:           sta     .near (W_READY+NW_NUM)
              rts

;;; ---------------------------------------------------------------------------
;;; void ST_Ticker(void): a random number for the face, the widgets, the
;;; health for the next tic.
;;; ---------------------------------------------------------------------------
              .public ST_Ticker
ST_Ticker:    jsl     long:M_Random
              sta     .near st_randomnumber
              jsr     .kbank readyNum       ; ST_updateWidgets
              ldx     ##0                   ; keyboxes[i] = cards[i] ? i : -1
1$:           lda     abs:.near (PL+OFS_PL_CARDS),x
              beq     2$
              txa
              lsr     a
              bra     3$
2$:           lda     ##0xffff
3$:           sta     abs:.near keyboxes,x
              inx
              inx
              cpx     ##6
              bcc     1$
              jsr     .kbank updateFace
              lda     .near (PL+OFS_PL_HEALTH)
              sta     .near st_oldhealth
              rtl

;;; painOffset: ST_calcPainOffset: C = ST_FACESTRIDE * (((100 - health) *
;;; ST_NUMPAINFACES) / 101), health at most 100 (computed when it changes).
painOffset:   lda     .near (PL+OFS_PL_HEALTH)
              cmp     ##101
              bmi     1$
              lda     ##100
1$:           cmp     .near st_oldhealthPO
              beq     2$
              sta     .near st_oldhealthPO
              eor     ##0xffff              ; (100 - health) * 5 / 101
              sec
              adc     ##100
              sta     .near ST_T
              asl     a
              asl     a
              clc
              adc     .near ST_T
              ldx     ##101
              jsl     long:_Div16
              asl     a                     ; * 8
              asl     a
              asl     a
              sta     .near st_lastcalc
2$:           lda     .near st_lastcalc
              rts

;;; updateFace: ST_updateFaceWidget: dead > evil grin > turned head >
;;; ouch > rampage > god > straight ahead.
updateFace:   lda     .near st_priority     ; dead
              cmp     ##10
              bpl     1$
              lda     .near (PL+OFS_PL_HEALTH)
              bne     1$
              lda     ##9
              sta     .near st_priority
              lda     ##ST_DEADFACE
              sta     .near st_faceindex
              lda     ##1
              sta     .near st_facecount
1$:           lda     .near st_priority     ; a new weapon: the evil grin
              cmp     ##9
              bpl     4$
              lda     .near (PL+OFS_PL_BONUSCOUNT)
              beq     4$
              stz     .near ST_DRAWN        ; (doevilgrin)
              ldx     ##0
2$:           lda     abs:.near (PL+OFS_PL_WEAPONOWNED),x
              cmp     abs:.near oldweaponsowned,x
              beq     3$
              sta     abs:.near oldweaponsowned,x
              inc     .near ST_DRAWN
3$:           inx
              inx
              cpx     ##(2 * CONST_NUMWEAPONS)
              bcc     2$
              lda     .near ST_DRAWN
              beq     4$
              lda     ##8
              sta     .near st_priority
              lda     ##ST_EVILGRINCOUNT
              sta     .near st_facecount
              jsr     .kbank painOffset
              clc
              adc     ##ST_EVILGRINOFFSET
              sta     .near st_faceindex
4$:           lda     .near st_priority     ; attacked by someone else
              cmp     ##8
              bpl     10$
              lda     .near (PL+OFS_PL_DAMAGECOUNT)
              beq     10$
              lda     .near (PL+OFS_PL_ATTACKER)
              ora     .near (PL+OFS_PL_ATTACKER+2)
              beq     10$
              lda     .near (PL+OFS_PL_ATTACKER)
              cmp     .near (PL+OFS_PL_MO)
              bne     5$
              lda     .near (PL+OFS_PL_ATTACKER+2)
              cmp     .near (PL+OFS_PL_MO+2)
              beq     10$
5$:           lda     ##7
              sta     .near st_priority
              jsr     .kbank muchPain       ; much pain: ouch
              bpl     6$
              jsr     .kbank ouch
              bra     10$
6$:           jsr     .kbank turnHead
10$:          lda     .near st_priority     ; damage: ouch or rampage
              cmp     ##7
              bpl     13$
              lda     .near (PL+OFS_PL_DAMAGECOUNT)
              beq     13$
              jsr     .kbank muchPain
              bpl     11$
              lda     ##7
              sta     .near st_priority
              jsr     .kbank ouch
              bra     13$
11$:          lda     ##6
              sta     .near st_priority
              lda     ##ST_TURNCOUNT
              sta     .near st_facecount
              jsr     .kbank painOffset
              clc
              adc     ##ST_RAMPAGEOFFSET
              sta     .near st_faceindex
13$:          lda     .near st_priority     ; rapid firing: rampage
              cmp     ##6
              bpl     16$
              lda     .near (PL+OFS_PL_ATTACKDOWN)
              beq     15$
              lda     .near st_lastattackdown
              cmp     ##0xffff
              bne     14$
              lda     ##ST_RAMPAGEDELAY
              sta     .near st_lastattackdown
              bra     16$
14$:          dec     .near st_lastattackdown
              bne     16$
              lda     ##5
              sta     .near st_priority
              jsr     .kbank painOffset
              clc
              adc     ##ST_RAMPAGEOFFSET
              sta     .near st_faceindex
              lda     ##1
              sta     .near st_facecount
              sta     .near st_lastattackdown
              bra     16$
15$:          lda     ##0xffff
              sta     .near st_lastattackdown
16$:          lda     .near st_priority     ; god mode, invulnerability
              cmp     ##5
              bpl     17$
              lda     .near (PL+OFS_PL_CHEATS)
              and     ##CONST_CF_GODMODE
              ora     .near (PL+OFS_PL_POWERS+2*CONST_PW_INVULNERABILITY)
              beq     17$
              lda     ##4
              sta     .near st_priority
              lda     ##ST_GODFACE
              sta     .near st_faceindex
              lda     ##1
              sta     .near st_facecount
17$:          lda     .near st_facecount    ; timed out: straight ahead,
              bne     18$                   ; looking left or right
              jsr     .kbank painOffset
              sta     .near ST_T
              lda     .near st_randomnumber
              ldx     ##3
              jsl     long:_UDivMod16       ; (C = the remainder)
              clc
              adc     .near ST_T
              sta     .near st_faceindex
              lda     ##ST_STRAIGHTFACECOUNT
              sta     .near st_facecount
              stz     .near st_priority
18$:          dec     .near st_facecount
              rts

;;; muchPain: N set if st_oldhealth - health > ST_MUCHPAIN (signed).
muchPain:     lda     ##ST_MUCHPAIN
              sec
              sbc     .near st_oldhealth
              clc
              adc     .near (PL+OFS_PL_HEALTH)
              bvc     1$
              eor     ##0x8000
1$:           rts

;;; ouch: the ouch face for ST_TURNCOUNT tics.
ouch:         lda     ##ST_TURNCOUNT
              sta     .near st_facecount
              jsr     .kbank painOffset
              clc
              adc     ##ST_OUCHOFFSET
              sta     .near st_faceindex
              rts

;;; turnHead: the face turns to the attacker: head-on (rampage) within 45
;;; degrees, else right or left.
turnHead:     lda     .near (PL+OFS_PL_MO)  ; Angle from player to attacker.
              sta     dp:.tiny _Dp
              lda     .near (PL+OFS_PL_MO+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near (PL+OFS_PL_ATTACKER)
              sta     dp:.tiny (_Dp+4)
              lda     .near (PL+OFS_PL_ATTACKER+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_MO_Y
              lda     [.tiny (_Dp+4)],y
              sec
              sbc     [.tiny _Dp],y
              sta     .near ST_T
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sbc     [.tiny _Dp],y
              sta     .near (ST_T+2)
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
              ldy     ##OFS_MO_ANGLE        ; (the angle of the player, kept)
              lda     [.tiny _Dp],y
              sta     .near ST_PX
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near ST_PW
              lda     .near ST_T
              sta     dp:.tiny _Dp
              lda     .near (ST_T+2)
              sta     dp:.tiny (_Dp+2)
              pla
              jsl     long:R_PointToAngle3
              sta     .near ST_T            ; badguyangle
              stx     .near (ST_T+2)
              lda     .near ST_PX           ; badguyangle > angle (unsigned)
              cmp     .near ST_T
              lda     .near ST_PW
              sbc     .near (ST_T+2)
              bcs     1$
              lda     .near ST_T            ; diffang = badguyangle - angle
              sec
              sbc     .near ST_PX
              sta     .near ST_T
              lda     .near (ST_T+2)
              sbc     .near ST_PW
              sta     .near (ST_T+2)
              ldx     ##0                   ; i = diffang > ANG180
              lda     ##0
              cmp     .near ST_T
              lda     ##CONST_ANG180_HI
              sbc     .near (ST_T+2)
              bcs     2$
              inx
              bra     2$
1$:           lda     .near ST_PX           ; diffang = angle - badguyangle
              sec
              sbc     .near ST_T
              sta     .near ST_T
              lda     .near ST_PW
              sbc     .near (ST_T+2)
              sta     .near (ST_T+2)
              ldx     ##0                   ; i = diffang <= ANG180
              lda     ##0
              cmp     .near ST_T
              lda     ##CONST_ANG180_HI
              sbc     .near (ST_T+2)
              bcc     2$
              inx
2$:           stx     .near ST_I
              lda     ##ST_TURNCOUNT
              sta     .near st_facecount
              jsr     .kbank painOffset
              sta     .near st_faceindex
              lda     .near (ST_T+2)        ; diffang < ANG45: head-on
              cmp     ##CONST_ANG45_HI
              bcs     3$
              lda     ##ST_RAMPAGEOFFSET
              bra     5$
3$:           lda     .near ST_I            ; right, else left
              beq     4$
              lda     ##ST_TURNOFFSET
              bra     5$
4$:           lda     ##(ST_TURNOFFSET+1)
5$:           clc
              adc     .near st_faceindex
              sta     .near st_faceindex
              rts

;;; ---------------------------------------------------------------------------
;;; ST_Drawer: redraw changed widgets, or the whole bar after ST_Start
;;; and the menu. stHide handles the menu case. ST_doRefresh redraws all.
;;; ---------------------------------------------------------------------------
              .public ST_Drawer, ST_doRefresh
ST_Drawer:    lda     .near _g_menuactive
              bne     3$
              lda     .near st_refreshed
              bne     2$
              jsr     .kbank refresh
              inc     .near st_refreshed    ; The whole bar has been refreshed.
              rtl
2$:           jsr     .kbank diffDraw
              rtl
3$:           stz     .near st_refreshed    ; Redraw all after the menu closes.
              jmp     long:stHide
              .space  2                     ; Keep later farcode in its slots.
ST_doRefresh: jsr     .kbank refresh
              rtl

;;; refresh: the background (and the arms background), saved for the
;;; restores, then all the widgets.
refresh:      stz     dp:.tiny _Dp          ; Status background starts at ST_Y.
              lda     ##(ST_Y * 320)
              sta     dp:.tiny _Dp
              lda     .near statusbarnum
              jsl     long:V_DrawRaw
              lda     ##ST_Y                ; the arms background at 104
              sta     dp:.tiny _Dp
              lda     .near starmsnum
              sta     dp:.tiny (_Dp+4)
              lda     ##104
              jsl     long:V_DrawNumPatchNotScaled
              jsl     long:I_SaveStatusBackground
              ldx     ##.near W_READY       ; ST_drawWidgets
              jsr     .kbank drawNum
              ldx     ##0
1$:           phx
              txa
              ldy     ##NW_SIZE
              jsr     .kbank mulXY
              pha
              clc
              adc     ##.near W_AMMO
              tax
              jsr     .kbank drawNum
              pla
              clc
              adc     ##.near W_MAXAMMO
              tax
              jsr     .kbank drawNum
              plx
              inx
              cpx     ##4
              bcc     1$
              ldx     ##.near W_HEALTH
              jsr     .kbank drawNum
              ldx     ##.near W_ARMOR
              jsr     .kbank drawNum
              jsr     .kbank healthPercent
              jsr     .kbank armorPercent
              ldx     ##.near W_FACES
              jsr     .kbank updateIcon
              ldx     ##.near W_KEYBOXES
2$:           phx
              jsr     .kbank updateIcon
              pla
              clc
              adc     ##IW_SIZE
              tax
              cpx     ##.near (W_KEYBOXES+3*IW_SIZE)
              bcc     2$
              ldx     ##.near W_ARMS
3$:           phx
              jsr     .kbank updateIcon
              pla
              clc
              adc     ##IW_SIZE
              tax
              cpx     ##.near (W_ARMS+6*IW_SIZE)
              bcc     3$
              rts

;;; healthPercent, armorPercent: the percent sign after the number.
healthPercent:
              lda     ##90
              bra     percent
armorPercent: lda     ##221
percent:      pha
              lda     ##(ST_Y+3)
              sta     dp:.tiny _Dp
              lda     .near tallpercentnum
              sta     dp:.tiny (_Dp+4)
              pla
              jsl     long:V_DrawNumPatchNotScaled
              rts

;;; diffDraw: ST_diffDraw: the widgets that changed. Carry set if any.
diffDraw:     stz     .near ST_DRAWN
              ldx     ##.near W_READY
              jsr     .kbank diffNum
              ldx     ##.near W_AMMO        ; ammo i, then max ammo i
1$:           jsr     .kbank diffNum
              txa
              clc
              adc     ##(W_MAXAMMO - W_AMMO)
              tax
              jsr     .kbank diffNum
              txa
              sec
              sbc     ##(W_MAXAMMO - W_AMMO - NW_SIZE)
              tax
              cpx     ##.near W_MAXAMMO
              bcc     1$
              ldx     ##.near W_HEALTH      ; (the last digit byte can hold the
              jsr     .kbank diffNum        ;  first pixel of the percent sign)
              bcc     2$
              jsr     .kbank healthPercent
2$:           ldx     ##.near W_ARMOR
              jsr     .kbank diffNum
              bcc     3$
              jsr     .kbank armorPercent
3$:           ldx     ##.near W_FACES
              jsr     .kbank diffIcon
              ldx     ##.near W_KEYBOXES
4$:           jsr     .kbank diffIcon
              txa
              clc
              adc     ##IW_SIZE
              tax
              cpx     ##.near (W_KEYBOXES+3*IW_SIZE)
              bcc     4$
              ldx     ##.near W_ARMS
5$:           jsr     .kbank diffIcon
              txa
              clc
              adc     ##IW_SIZE
              tax
              cpx     ##.near (W_ARMS+6*IW_SIZE)
              bcc     5$
              lda     .near ST_DRAWN
              cmp     ##1                   ; carry: drawn
              rts
              .space  6                     ; Keep restoreRect at its slots.

;;; diffNum: ST_diffNum(the number widget at near X): a changed number is
;;; drawn again over its restored background. Carry set if drawn (also in
;;; ST_DRAWN). X stays.
diffNum:      ldy     abs:NW_NUM,x
              lda     abs:0,y
              cmp     abs:NW_OLDNUM,x
              bne     1$
              clc
              rts
1$:           stx     .near ST_W
              ldy     abs:NW_P,x            ; w = V_NumPatchWidth(p[0])
              lda     abs:0,y
              jsl     long:V_NumPatchWidth
              ldx     .near ST_W            ; restore x - w, width patches wide
              sta     .near ST_T
              lda     abs:NW_X,x
              sec
              sbc     .near ST_T
              pha
              lda     abs:NW_WIDTH,x
              pha
              ldy     abs:NW_P,x
              lda     abs:0,y
              tay
              lda     abs:NW_Y,x
              tax
              jsr     .kbank restoreRect
              pla
              pla
              ldx     .near ST_W
              jsr     .kbank drawNum
              lda     ##1
              sta     .near ST_DRAWN
              ldx     .near ST_W
              sec
              rts

;;; diffIcon: ST_diffIcon(the icon widget at near X): a changed icon is
;;; drawn again over the restored background of the old one. Carry set if
;;; drawn (also in ST_DRAWN). X stays.
diffIcon:     ldy     abs:IW_INUM,x
              lda     abs:0,y
              cmp     abs:IW_OLDINUM,x
              bne     1$
              clc
              rts
1$:           stx     .near ST_W
              lda     abs:IW_OLDINUM,x      ; the old one: restored
              cmp     ##0xffff
              beq     2$
              asl     a
              clc
              adc     abs:IW_P,x
              tay
              lda     abs:IW_X,x
              pha
              lda     ##1
              pha
              lda     abs:0,y
              tay
              lda     abs:IW_Y,x
              tax
              jsr     .kbank restoreRect
              pla
              pla
2$:           ldx     .near ST_W
              jsr     .kbank updateIcon
              lda     ##1
              sta     .near ST_DRAWN
              ldx     .near ST_W
              sec
              rts

;;; restoreRect: ST_restorePatchRect(x = 5,s, y = X, num = Y, count = 3,s):
;;; the saved background under count patches num wide, the last at x.
restoreRect:  stx     .near ST_PX           ; (y)
              tya                           ; patch = W_GetLumpByNum(num)
              jsl     long:W_GetLumpByNum
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##OFS_PATCH_HEIGHT    ; h: on the stack (count at 5,s and
              lda     [.tiny _Dp],y         ; x at 7,s then)
              pha
              lda     5,s                   ; w = count * width
              tax
              lda     [.tiny _Dp]
              jsl     long:IIGS_MulLo16
              sta     .near ST_PW
              lda     7,s                   ; Left edge of the group of patches.
              ldy     ##OFS_PATCH_LEFTOFFSET
              sec
              sbc     [.tiny _Dp],y
              sec
              sbc     .near ST_PW
              clc
              adc     [.tiny _Dp]
              sta     .near ST_NUM
              lda     .near ST_PX           ; y - topoffset
              ldy     ##OFS_PATCH_TOPOFFSET
              sec
              sbc     [.tiny _Dp],y
              sta     .near ST_T
              pei     dp:.tiny (_Dp+2)      ; Patch for Z_ChangeTagToCache.
              pei     dp:.tiny _Dp
              lda     5,s                   ; h
              pha
              lda     .near ST_T
              sta     dp:.tiny _Dp
              lda     .near ST_PW
              sta     dp:.tiny (_Dp+4)
              lda     .near ST_NUM
              jsl     long:I_RestoreStatusRect
              pla
              pla
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
              pla                           ; h
              jsl     long:Z_ChangeTagToCache
              rts

;;; updateIcon: STlib_updateMultIcon(the icon widget at near X): the icon
;;; of the current value (none for -1).
updateIcon:   stx     .near ST_W
              lda     abs:IW_P,x            ; no patches: nothing
              bne     2$
              rts
2$:           ldy     abs:IW_INUM,x
              lda     abs:0,y
              cmp     ##0xffff
              beq     1$
              asl     a                     ; Select the patch for this icon.
              clc
              adc     abs:IW_P,x
              tay
              lda     abs:0,y
              sta     dp:.tiny (_Dp+4)
              lda     abs:IW_Y,x
              sta     dp:.tiny _Dp
              lda     abs:IW_X,x
              jsl     long:V_DrawNumPatchNotScaled
              ldx     .near ST_W
1$:           ldy     abs:IW_INUM,x         ; oldinum = inum
              lda     abs:0,y
              sta     abs:IW_OLDINUM,x
              rts

;;; drawNum: STlib_drawNum(the number widget at near X): the number right
;;; aligned before x, at most width digits (a negative number: its digits,
;;; at least -9 or -99); largeammo is not drawn.
drawNum:      stx     .near ST_W
              lda     abs:NW_WIDTH,x
              sta     .near ST_DIGITS
              ldy     abs:NW_NUM,x          ; num = *n->num, oldnum = num
              lda     abs:0,y
              sta     abs:NW_OLDNUM,x
              cmp     ##0
              bpl     3$
              ldy     .near ST_DIGITS       ; negative
              cpy     ##2
              bne     1$
              cmp     ##(0x10000 - 9)       ; num < -9: -9
              bcs     2$
              lda     ##(0x10000 - 9)
              bra     2$
1$:           cpy     ##3
              bne     2$
              cmp     ##(0x10000 - 99)      ; num < -99: -99
              bcs     2$
              lda     ##(0x10000 - 99)
2$:           eor     ##0xffff              ; num = -num
              inc     a
3$:           sta     .near ST_NUM
              cmp     ##LARGEAMMO           ; not a number
              bne     4$
              rts
4$:           ldy     abs:NW_P,x            ; w = V_NumPatchWidth(p[0])
              lda     abs:0,y
              jsl     long:V_NumPatchWidth
              sta     .near ST_PW
              ldx     .near ST_W
              lda     abs:NW_X,x
              sta     .near ST_PX
              lda     .near ST_NUM          ; 0: the digit 0
              bne     5$
              lda     .near ST_PX
              sec
              sbc     .near ST_PW
              ldy     ##0
              jsr     .kbank drawDigit
5$:           lda     .near ST_NUM          ; while (num && numdigits--)
              beq     6$
              lda     .near ST_DIGITS
              beq     6$
              dec     .near ST_DIGITS
              lda     .near ST_PX           ; x -= w
              sec
              sbc     .near ST_PW
              sta     .near ST_PX
              lda     .near ST_NUM          ; the digit num % 10, num /= 10
              ldx     ##10
              jsl     long:_UDivMod16
              stx     .near ST_NUM
              asl     a
              tay
              lda     .near ST_PX
              jsr     .kbank drawDigit
              bra     5$
6$:           rts

;;; drawDigit: V_DrawNumPatchNotScaled(C, y of ST_W, p of ST_W at offset Y).
drawDigit:    pha
              ldx     .near ST_W
              tya
              clc
              adc     abs:NW_P,x
              tay
              lda     abs:0,y
              sta     dp:.tiny (_Dp+4)
              lda     abs:NW_Y,x
              sta     dp:.tiny _Dp
              pla
              jsl     long:V_DrawNumPatchNotScaled
              rts

;;; ---------------------------------------------------------------------------
;;; void ST_doPaletteStuff(void): the red palettes of damage (and of the
;;; berserk strength, fading), the gold palettes of bonuses, the green
;;; palette of the radiation suit (blinking at the end).
;;; ---------------------------------------------------------------------------
              .public ST_doPaletteStuff
ST_doPaletteStuff:
              jsl     long:tintDecide       ; same length as the old lda/sta
              rtl
              nop
              lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_STRENGTH)
              beq     1$
              lsr     a                     ; bzc = 12 - (strength >> 6)
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              eor     ##0xffff
              sec
              adc     ##12
              cmp     .near ST_T            ; bzc > cnt: cnt = bzc (signed)
              beq     1$
              bmi     1$
              sta     .near ST_T
1$:           lda     .near ST_T
              beq     3$
              clc                           ; red: (cnt + 7) >> 3, at most 7
              adc     ##7
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##NUMREDPALS
              bmi     2$
              lda     ##(NUMREDPALS - 1)
2$:           ldx     .near _g_menuactive   ; half in the menu
              beq     21$
              cmp     ##0x8000
              ror     a
21$:          clc
              adc     ##STARTREDPALS
              bra     6$
3$:           lda     .near (PL+OFS_PL_BONUSCOUNT)
              beq     4$
              clc                           ; Gold: ceil(bonuscount/8), max 3.
              adc     ##7
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##NUMBONUSPALS
              bmi     31$
              lda     ##(NUMBONUSPALS - 1)
31$:          clc
              adc     ##STARTBONUSPALS
              bra     6$
4$:           lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_IRONFEET)
              cmp     ##(4 * 32 + 1)        ; the suit: > 128, or blinking
              bpl     5$
              and     ##8
              beq     51$
5$:           lda     ##RADIATIONPAL
              bra     6$
51$:          lda     ##0
6$:           cmp     .near st_palette      ; a new palette
              beq     7$
              sta     .near st_palette
              jsl     long:I_SetPalette
7$:           rtl

;;; ---------------------------------------------------------------------------
;;; stHide: blank the bar and message while the menu is up.
;;; VW_MHID blanks the strip again after I_RestoreView restores old text;
;;; vwFrame clears it when the next view is drawn. Mark both regions dirty.
;;; This lives in vwcode to keep farcode at its existing cache slots.
;;; ---------------------------------------------------------------------------
              .section vwcode, text
              .extern I_MarkRect, message_on, iigs_textShown
stHide:       ldx     ##(ST_Y * 160)
              lda     ##0
1$:           sta     long:0x012000,x
              inx
              inx
              cpx     ##(200 * 160)
              bcc     1$
              lda     ##ST_Y
              ldx     ##200
              ldy     ##(0 | (159 << 8))
              jsl     long:I_MarkRect
              lda     .near message_on
              ora     long:VW_MHID
              beq     3$
              stz     .near message_on
              stz     .near iigs_textShown
              lda     ##1
              sta     long:VW_MHID
              ldx     ##0
              lda     ##0
2$:           sta     long:0x012000,x
              inx
              inx
              cpx     ##(10 * 160)
              bcc     2$
              lda     ##0
              ldx     ##10
              ldy     ##(0 | (159 << 8))
              jsl     long:I_MarkRect
3$:           rtl

;;; ---------------------------------------------------------------------------
;;; The drawn tint. damagecount still falls one per tic; a frame samples
;;; the strongest count since the previous frame and keeps a new red up
;;; for two drawn frames or 14 real tics (0.4 s), whichever is longer.
;;; Palette 8 is flattened to one red by the 16 view colors, so the row
;;; that is copied is three quarters of that red and one quarter of the
;;; ordinary view. Bank 5, after the level loader: nothing else moves.
;;; ---------------------------------------------------------------------------
TINT_FRAMES   .equ    2
TINT_REALTICS .equ    14
TINT8_OFF     .equ    (8 * 384)
              .section tintcode, text
              .public notePeak, tintDecide
notePeak:     sta     .near (PL+OFS_PL_DAMAGECOUNT)
              cmp     .near tintPeak
              bcc     1$
              sta     .near tintPeak
1$:           sec
              rtl

tintDecide:   lda     .near (PL+OFS_PL_DAMAGECOUNT)
              cmp     .near tintPeak
              bcs     0$
              lda     .near tintPeak
0$:           stz     .near tintPeak
              sta     .near ST_T
              lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_STRENGTH)
              beq     1$
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              eor     ##0xffff
              sec
              adc     ##12
              cmp     .near ST_T
              beq     1$
              bmi     1$
              sta     .near ST_T
1$:           lda     .near ST_T
              beq     3$
              clc
              adc     ##7
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##NUMREDPALS
              bmi     2$
              lda     ##(NUMREDPALS - 1)
2$:           ldx     .near _g_menuactive
              beq     21$
              cmp     ##0x8000
              ror     a
21$:          clc
              adc     ##STARTREDPALS
              bra     6$
3$:           lda     .near (PL+OFS_PL_BONUSCOUNT)
              beq     4$
              clc
              adc     ##7
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##NUMBONUSPALS
              bmi     31$
              lda     ##(NUMBONUSPALS - 1)
31$:          clc
              adc     ##STARTBONUSPALS
              bra     6$
4$:           lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_IRONFEET)
              cmp     ##(4 * 32 + 1)
              bpl     5$
              and     ##8
              beq     51$
5$:           lda     ##RADIATIONPAL
              bra     6$
51$:          lda     ##0
6$:           jsr     .kbank tintHold
              cmp     ##8
              bne     7$
              jsr     .kbank tintSoften
              lda     ##8
7$:           cmp     .near st_palette
              beq     8$
              sta     .near st_palette
              jsl     long:I_SetPalette
8$:           rtl

;;; A = the palette just chosen. A red (2..8) is held at its strongest.
;;; Anything else is shown as itself, except 0 while a hold is still up.
tintHold:     sta     .near ST_T
              cmp     ##2
              bcc     4$
              cmp     ##9
              bcs     4$
              lda     .near tintShow
              beq     1$
              cmp     .near ST_T
              bcs     2$
1$:           lda     .near ST_T
              sta     .near tintShow
              lda     ##TINT_FRAMES
              sta     .near tintLeft
              jsl     long:I_GetTime
              clc
              adc     ##TINT_REALTICS
              sta     .near tintUntil
              bra     3$
2$:           lda     .near tintLeft
              beq     20$
              dec     .near tintLeft
20$:          jsl     long:I_GetTime
              sec
              sbc     .near tintUntil
              bmi     3$
              lda     .near tintLeft
              bne     3$
              stz     .near tintShow
              lda     .near ST_T
              rts
3$:           lda     .near tintShow
              rts
4$:           lda     .near ST_T
              bne     5$
              lda     .near tintShow
              beq     6$
              lda     .near tintLeft
              beq     40$
              dec     .near tintLeft
40$:          jsl     long:I_GetTime
              sec
              sbc     .near tintUntil
              bmi     3$
              lda     .near tintLeft
              bne     3$
              stz     .near tintShow
6$:           lda     ##0
              rts
5$:           stz     .near tintShow
              stz     .near tintLeft
              lda     .near ST_T
              rts

;;; Palette 8's 16 view colors are mostly the same red. Keep a quarter of
;;; the ordinary color so the room stays visible. Once per level and gamma.
tintSoften:   lda     .near _g_gamemap
              cmp     .near tintMark
              bne     1$
              lda     .near _g_gamma
              cmp     .near tintMarkG
              beq     2$
1$:           lda     .near _g_gamemap
              sta     .near tintMark
              lda     .near _g_gamma
              sta     .near tintMarkG
              lda     ##.word0 (TINTPAL+TINT8_OFF)
              sta     dp:.tiny _Dp
              lda     ##.word2 (TINTPAL+TINT8_OFF)
              sta     dp:.tiny (_Dp+2)
              ldy     ##0
10$:          lda     [.tiny _Dp],y
              sta     .near tintSave,y
              iny
              iny
              cpy     ##32
              bcc     10$
2$:           lda     ##.word0 TINTPAL
              sta     dp:.tiny _Dp
              lda     ##.word2 TINTPAL
              sta     dp:.tiny (_Dp+2)
              ldy     ##0
20$:          lda     [.tiny _Dp],y
              sta     .near tintC0
              lda     .near tintSave,y
              phy
              jsr     .kbank tintBlend
              ply
              sta     .near tintOut,y
              iny
              iny
              cpy     ##32
              bcc     20$
              lda     ##.word0 (TINTPAL+TINT8_OFF)
              sta     dp:.tiny _Dp
              lda     ##.word2 (TINTPAL+TINT8_OFF)
              sta     dp:.tiny (_Dp+2)
              ldy     ##0
30$:          lda     .near tintOut,y
              sta     [.tiny _Dp],y
              iny
              iny
              cpy     ##32
              bcc     30$
              rts

;;; A = tint-8 color, tintC0 = ordinary color. Each nibble is
;;; (ordinary + 3 * red) >> 2, which stays in 0..15. X is c0.
tintBlend:    ldx     .near tintC0
              sta     .near tintC8
              txa
              and     ##0x000f
              sta     .near ST_PW
              lda     .near tintC8
              and     ##0x000f
              sta     .near ST_T
              asl     a
              clc
              adc     .near ST_T
              clc
              adc     .near ST_PW
              lsr     a
              lsr     a
              and     ##0x000f
              sta     .near ST_PW
              txa
              and     ##0x00f0
              sta     .near ST_PX
              lda     .near tintC8
              and     ##0x00f0
              sta     .near ST_T
              asl     a
              clc
              adc     .near ST_T
              clc
              adc     .near ST_PX
              lsr     a
              lsr     a
              and     ##0x00f0
              ora     .near ST_PW
              sta     .near ST_PW
              txa
              and     ##0x0f00
              sta     .near ST_PX
              lda     .near tintC8
              and     ##0x0f00
              sta     .near ST_T
              asl     a
              clc
              adc     .near ST_T
              clc
              adc     .near ST_PX
              lsr     a
              lsr     a
              and     ##0x0f00
              ora     .near ST_PW
              rts
