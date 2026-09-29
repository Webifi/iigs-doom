;;; The automap in 65816 assembly.
;;;
;;; am_map.c, and V_DrawLine and V_ClearViewWindow of
;;; i_viigs.c, with the same results: the lines that the player saw
;;; (with the computer map also the others) in the colors of their kind, and
;;; the player arrow; zoom, pan, follow mode, and the overlay mode that turns
;;; the map with the player.
;;; Only a line to draw gets its map coordinates, sectors and clip. The sine,
;;; cosine and origin of the rotation are calculated one time for each frame.
;;; The line drawer has one loop for the lines that are wider than high (an x
;;; step for each pixel) and one for the other lines (a y step for each
;;; pixel). They give the pixels of the Bresenham loop of the C code.

              .rtmodel version, "1"
              .rtmodel core, "*"

              .extern IIGS_SetShadow

#include "offsets.inc"
#include "memmap.inc"
#include "lists.inc"
#include "viewwin.inc"

              .extern _Dp, _g_player, _g_gamemap, _g_lines, _g_numlines, _g_sides
              .extern key_map, key_map_right, key_map_left, key_map_up, key_map_down
              .extern key_map_follow, key_map_zoomout, key_map_zoomin, iigs_rowbase
              .extern I_MarkRect, iigs_textShown, message_on, message_new, _g_menuactive
              .extern COLW, newPage, MA
              .extern FixedMul, FixedReciprocal, FixedApproxDiv, FixedMulAngle
              .extern finesineapprox, finecosineapprox, _Mul32, IIGS_MulLo16, _Div16

PL            .equ    _g_player
AM_ACTIVE     .equ    1               ; automapmode
AM_OVERLAY    .equ    2
AM_ROTATE     .equ    4
AM_FOLLOW     .equ    8
F_W           .equ    320             ; the map window: the screen width,
F_H           .equ    CONST_VIEWHEIGHT ;   the view height
F_PANINC      .equ    4
MAPBITS       .equ    12
M_ZOOMIN      .equ    66846           ; (int32_t) (1.02 * FRACUNIT)
M_ZOOMOUT     .equ    64250           ; (int32_t) (FRACUNIT / 1.02)
INITSCALE     .equ    45875           ; (int32_t) (0.7 * FRACUNIT)
EV_KEYDOWN    .equ    0               ; event_t
EV_KEYUP      .equ    1
EV_DATA1      .equ    2
ML_SECRET     .equ    32              ; line flags
ML_DONTDRAW   .equ    128
ML_MAPPED     .equ    256             ; (in r_flags)
OC_LEFT       .equ    1               ; outcodes
OC_RIGHT      .equ    2
OC_BOTTOM     .equ    4
OC_TOP        .equ    8
COLOR_WALL    .equ    23
COLOR_FCHG    .equ    55
COLOR_CCHG    .equ    215
COLOR_CLSD    .equ    208
COLOR_RDOR    .equ    175
COLOR_BDOR    .equ    204
COLOR_YDOR    .equ    231
COLOR_TELE    .equ    119
COLOR_SECR    .equ    252
COLOR_UNSN    .equ    104
COLOR_SNGL    .equ    208
NUMPLYRLINES  .equ    7
SHRBUF        .equ    0x012000        ; the back buffer, 160 bytes a row
SHR_SCREEN    .equ    0xe12000        ; the screen
STRIP_ROWS    .equ    10              ; the message strip of src/iigs/i_viigs65.s
AM_TITLEY     .equ    (F_H - 1 - 7)   ; HU_TITLEY of src/iigs/hu_stuff65.s
AM_LMAX       .equ    3000            ; the bytes of a list
NIBTAB        .equ    MM_NIBTAB       ; the nibble tables (iigs_rowbase)
SHADOW        .equ    0xe0c035        ; bit 3 set: no SHR shadowing
AM_SQL        .equ    MM_SQL          ; the quarter squares (SQL, SQH of
AM_SQH        .equ    MM_SQH          ;   src/iigs/m_fixed65.s)
VW_HL         .equ    40              ; the half window (VWTAB of
VW_HR         .equ    119             ;   src/iigs/r_frame65.s): its first and
VW_HT         .equ    41              ;   last byte, the row above it and the
VW_HB         .equ    126             ;   row after it
VW_TL         .equ    26              ; the 2/3 window, the same
VW_TR         .equ    132
VW_TT         .equ    27
VW_TB         .equ    140

;;; The screen points of the line ends in a frame of the fast turn, by
;;; vertex (fastLine): bank $74 (lists.inc, not cached). LV_TAB: 8 * the
;;; vertex number of each line end (0xffff: none), from the vertex hash of
;;; I_InitSegVertices (src/iigs/i_viigs65.s: x, y, number, 6 bytes an entry,
;;; h = (x * 31 + y) & 8191); VS_TAB: 8 bytes a vertex: the frame of its
;;; point, x, y. LV_KEY: the level of LV_TAB (map, lines, their address);
;;; LV_OK: 1 when the level fits; AM_VFR: the frame.
VTXHASH       .equ    MM_VTXHASH
VTXHASH_SIZE  .equ    8192
LV_KEY        .equ    MM_AMKEY
LV_OK         .equ    (MM_AMKEY + 8)
AM_VFR        .equ    (MM_AMKEY + 0x0a)
LV_TAB        .equ    MM_LVTAB
LV_MAXL       .equ    3072
VS_TAB        .equ    MM_VSTAB
LV_MAXV       .equ    MM_VSMAXV
#define LPTR  (_Dp+8)
#define FRONT (_Dp+4)
#define BACK  _Dp
#define ROWP  _Dp
#define PX    (_Dp+4)
#define ERR2  (_Dp+6)

              .section near, data
scale_mtof:   .long   13107           ; (fixed_t) (.2 * FRACUNIT)
stopped:      .word   1
mtof_zoommul: .long   0x10000
ftom_zoommul: .long   0x10000
lastlevel:    .word   0xffff

              .section znear, bss
              .public automapmode, am_valid, am_band
automapmode:  .space  2
am_valid:     .space  2               ; the full map on the screen has the
                                      ; bytes of the old list (AM_LB)
am_band:      .space  2               ; the title rows are black (the overlay)
              .public AM_MODE
AM_MODE:      .space  2               ; 0: the full map, 1: the overlay, 2:
                                      ;   the overlay on the half view, 3: it
                                      ;   ended (AM_Clean at the next view)
AM_WTOP:      .space  2               ; the rows of the lines: AM_WTOP ..
AM_WBOT:      .space  2               ;   AM_WBOT - 1
AM_OLDTOP:    .space  2               ; AM_WTOP of the map on the screen
AM_LAST:      .space  2               ; the last byte in the new list
AM_LB:        .space  2               ; the offset of the new list (AM_LISTS)
AM_LN:        .space  2               ; its length in bytes
AM_ON:        .space  2               ; the length of the old list
AM_OVF:       .space  2               ; the new list is full
AM_CN:        .space  2               ; copyList: the length
              .section coldfar, bss
AM_LISTS:     .space  4 * AM_LMAX     ; the bytes of the lines: two lists
              .section znear, bss
m_paninc:     .space  8               ; the pan of a tic (x, y)
m_x:          .space  4               ; the window on the map: its corners,
m_y:          .space  4
m_x2:         .space  4
m_y2:         .space  4
m_w:          .space  4               ;   its size
m_h:          .space  4
min_x:        .space  4               ; the limits of the map (at the same
min_y:        .space  4               ;   distances from each other as m_x
max_x:        .space  4               ;   and m_y)
max_y:        .space  4
max_w:        .space  4
max_h:        .space  4
min_scale_mtof: .space 4
max_scale_mtof: .space 4
f_oldloc:     .space  8               ; the player place at the last follow
scale_ftom:   .space  4
AM_T:         .space  4
AM_U:         .space  4
AM_I:         .space  2
AM_EV:        .space  2               ; the key of the event
AM_COLOR:     .space  2
AM_SPECIAL:   .space  2
AM_TURN:      .space  2               ; the arrow turns (angle not 0)
ML:           .space  16              ; the line on the map: a.x, a.y, b.x, b.y
FL:           .space  8               ; the line on the screen
OC1:          .space  2               ; the outcodes of its ends
OC2:          .space  2
OC_T:         .space  2
OUTSIDE:      .space  2
TMPX:         .space  2               ; the clipped end
TMPY:         .space  2
CL_D:         .space  2
RT_X:         .space  4               ; the rotation: the new x,
RT_OX:        .space  4               ;   the origin,
RT_OY:        .space  4
RT_DX:        .space  4               ;   the point from the origin,
RT_DY:        .space  4
RT_C:         .space  4               ;   the cosine and the sine
RT_S:         .space  4
AMD_X:        .space  4               ; the place of the arrow
AMD_Y:        .space  4
MIN16:        .space  4               ; the box of the lines (x, y)
MAX16:        .space  4
;;; The fast turn (fastLine): frame constants in the places of the arrow
;;; and the box, temporaries in those of rotatePoint (no new near bytes: they
;;; would move the near data of the renderer).
RF_OX         .equ    MIN16           ; the origin, map units (int16)
RF_OY         .equ    (MIN16+2)
RF_CX         .equ    MAX16           ; the origin on the screen
RF_CY         .equ    (MAX16+2)
RF_MC         .equ    AMD_X           ; |s cos|, |s sin| (0.16; s: the pixels
RF_MS         .equ    (AMD_X+2)       ;   of a map unit); RF_MC 0xffff: none
RF_SC         .equ    AMD_Y           ; their signs (0, 0x8000)
RF_SS         .equ    (AMD_Y+2)
RF_DX         .equ    RT_DX           ; the end from the origin (int16)
RF_DY         .equ    (RT_DX+2)
RF_PL         .equ    RT_DY           ; a product (32 bits)
RF_PH         .equ    (RT_DY+2)
RF_T          .equ    RT_X
RF_S          .equ    (RT_X+2)
LN_KEY        .equ    OC_T            ; rowColors: the index of the nibbles
                                      ;   (drawFL; the clip is done then)
LN_Y:         .space  2               ; the line drawer: the y of the pixel,
LN_SX:        .space  2               ;   the steps,
LN_SY:        .space  2
LN_SY160:     .space  2
LN_DX:        .space  2               ;   dx, dy, 2 dx, 2 dy, 2 dx + 2 dy,
LN_DY:        .space  2
LN_DX2:       .space  2
LN_DY2:       .space  2
LN_D2:        .space  2
LN_NIBH:      .space  2               ;   the color in the row: the left and
LN_NIBL:      .space  2               ;   the right nibble

              .section cfar, rodata
msgFollowOn:  .asciz  "Follow Mode On"
msgFollowOff: .asciz  "Follow Mode Off"
playerArrow:  .long   -65536, 0, 74898, 0         ; the lines of the arrow
              .long   74898, 0, 37449, 18724
              .long   74898, 0, 37449, -18724
              .long   -65536, 0, -84260, 18724
              .long   -65536, 0, -84260, -18724
              .long   -46812, 0, -65536, 18724
              .long   -46812, 0, -65536, -18724
doorColors:   .byte   COLOR_BDOR, COLOR_YDOR, COLOR_RDOR, 0, 0, 0 ; specials 26-34
              .byte   COLOR_BDOR, COLOR_RDOR, COLOR_YDOR

              .section amcode, text         ; (src/iigs/iigs.scm)

;;; ---------------------------------------------------------------------------
;;; void AM_Stop(void): no automap.
;;; ---------------------------------------------------------------------------
              .public AM_Stop
AM_Stop:      lda     .near AM_MODE         ; the overlay on the half view
              cmp     ##2                   ;   ends: its pixels go at the
              bne     1$                    ;   next view (AM_Clean)
              lda     ##3
              sta     .near AM_MODE
1$:           stz     .near automapmode
              lda     ##1
              sta     .near stopped
              rtl

;;; ---------------------------------------------------------------------------
;;; boolean AM_Responder(event_t* ev)     In: _Dp[0-3] = ev.
;;; The map key starts the automap. In the automap: the pan keys (not in the
;;; follow mode), the map key (the overlay mode, then off), follow, zoom.
;;; ---------------------------------------------------------------------------
              .public AM_Responder
AM_Responder: ldy     ##EV_DATA1
              lda     [.tiny _Dp],y
              sta     .near AM_EV
              lda     [.tiny _Dp]
              tay                           ; the type
              lda     .near automapmode
              bit     ##AM_ACTIVE
              bne     active
              cpy     ##EV_KEYDOWN          ; not active: the map key starts
              bne     no                    ;   the automap
              lda     .near AM_EV
              cmp     .near key_map
              bne     no
              jsr     .kbank start
yes:          lda     ##1
              rtl
no:           lda     ##0
              rtl
active:       cpy     ##EV_KEYUP
              bne     1$
              brl     keyUp
1$:           cpy     ##EV_KEYDOWN
              bne     no
              lda     .near AM_EV           ; a key down
              ldx     ##0
              cmp     .near key_map_right
              beq     panPlus
              cmp     .near key_map_left
              beq     panMinus
              ldx     ##4
              cmp     .near key_map_up
              beq     panPlus
              cmp     .near key_map_down
              beq     panMinus
              cmp     .near key_map
              beq     mapKey
              cmp     .near key_map_follow
              bne     2$
              brl     follow
2$:           cmp     .near key_map_zoomout
              beq     zoomOut
              cmp     .near key_map_zoomin
              bne     no
              lda     ##(M_ZOOMIN & 0xffff) ; zoom in
              sta     .near mtof_zoommul
              lda     ##(M_ZOOMIN >> 16)
              sta     .near (mtof_zoommul+2)
              lda     ##(M_ZOOMOUT & 0xffff)
              sta     .near ftom_zoommul
              lda     ##(M_ZOOMOUT >> 16)
              sta     .near (ftom_zoommul+2)
              bra     yes
zoomOut:      lda     ##(M_ZOOMOUT & 0xffff) ; zoom out
              sta     .near mtof_zoommul
              lda     ##(M_ZOOMOUT >> 16)
              sta     .near (mtof_zoommul+2)
              lda     ##(M_ZOOMIN & 0xffff)
              sta     .near ftom_zoommul
              lda     ##(M_ZOOMIN >> 16)
              sta     .near (ftom_zoommul+2)
              bra     yes
panPlus:      lda     .near automapmode     ; a pan key (X: the axis): not in
              bit     ##AM_FOLLOW           ;   the follow mode
              beq     1$
              brl     no
1$:           phx
              jsr     .kbank panStep
              bra     pan
panMinus:     lda     .near automapmode
              bit     ##AM_FOLLOW
              beq     1$
              brl     no
1$:           phx
              jsr     .kbank panStep
              jsr     .kbank negate
pan:          ply
              sta     .near m_paninc,y
              txa
              sta     .near (m_paninc+2),y
              brl     yes
mapKey:       lda     .near automapmode     ; the map key: the overlay mode,
              bit     ##AM_OVERLAY          ;   then off
              beq     1$
              jsl     long:AM_Stop
              brl     yes
1$:           ora     ##(AM_OVERLAY | AM_ROTATE | AM_FOLLOW)
              sta     .near automapmode
              brl     yes
follow:       lda     .near automapmode     ; follow on or off
              eor     ##AM_FOLLOW
              sta     .near automapmode
              jsr     .kbank oldlocNone
              lda     .near automapmode
              and     ##AM_FOLLOW
              beq     1$
              lda     ##.word0 msgFollowOn
              ldx     ##.word2 msgFollowOn
              bra     2$
1$:           lda     ##.word0 msgFollowOff
              ldx     ##.word2 msgFollowOff
2$:           sta     .near (PL+OFS_PL_MESSAGE)
              stx     .near (PL+OFS_PL_MESSAGE+2)
              brl     yes
keyUp:        lda     .near AM_EV           ; a key up: the pan or zoom stops
              ldx     ##0
              cmp     .near key_map_right
              beq     1$
              cmp     .near key_map_left
              beq     1$
              ldx     ##4
              cmp     .near key_map_up
              beq     1$
              cmp     .near key_map_down
              beq     1$
              cmp     .near key_map_zoomout
              beq     2$
              cmp     .near key_map_zoomin
              beq     2$
              brl     no
2$:           stz     .near mtof_zoommul    ; FRACUNIT
              stz     .near ftom_zoommul
              lda     ##1
              sta     .near (mtof_zoommul+2)
              sta     .near (ftom_zoommul+2)
              brl     no
1$:           lda     .near automapmode
              bit     ##AM_FOLLOW
              bne     3$
              stz     .near m_paninc,x
              stz     .near (m_paninc+2),x
3$:           brl     no

;;; panStep: X:C = FTOM(F_PANINC).
panStep:      lda     ##F_PANINC
              ldx     ##0
              brl     ftom

;;; ---------------------------------------------------------------------------
;;; start: AM_Start: the automap of the level (its limits and scale when the
;;; level is new), on the player, in the follow mode.
;;; ---------------------------------------------------------------------------
start:        lda     .near stopped
              bne     1$
              jsl     long:AM_Stop
1$:           stz     .near stopped
              lda     .near lastlevel       ; a new level: AM_LevelInit
              cmp     .near _g_gamemap
              beq     2$
              jsr     .kbank findMinMaxBoundaries
              lda     ##INITSCALE           ; scale_mtof = min_scale_mtof / 0.7
              sta     dp:.tiny _Dp
              stz     dp:.tiny (_Dp+2)
              lda     .near min_scale_mtof
              ldx     .near (min_scale_mtof+2)
              jsl     long:FixedApproxDiv
              sta     .near scale_mtof
              stx     .near (scale_mtof+2)
              ldy     ##.near max_scale_mtof ; more than the maximum: the
              ldx     ##.near scale_mtof    ;   minimum
              jsr     .kbank less32
              bpl     11$
              lda     .near min_scale_mtof
              sta     .near scale_mtof
              lda     .near (min_scale_mtof+2)
              sta     .near (scale_mtof+2)
11$:          jsr     .kbank newFtom
              lda     .near _g_gamemap
              sta     .near lastlevel
2$:           lda     .near automapmode     ; AM_initVariables
              ora     ##(AM_ACTIVE | AM_FOLLOW)
              sta     .near automapmode
              jsr     .kbank oldlocNone
              stz     .near m_paninc
              stz     .near (m_paninc+2)
              stz     .near (m_paninc+4)
              stz     .near (m_paninc+6)
              jsr     .kbank windowSize
              jsr     .kbank playerMo       ; the window on the player
              ldy     ##OFS_MO_X
              jsr     .kbank moMap
              sta     .near m_x
              stx     .near (m_x+2)
              ldy     ##OFS_MO_Y
              jsr     .kbank moMap
              sta     .near m_y
              stx     .near (m_y+2)
              jsr     .kbank centerWindow
              brl     changeWindowLoc

;;; findMinMaxBoundaries: AM_findMinMaxBoundaries: the box of the line ends
;;; (with the else if of the C code), the scale limits.
findMinMaxBoundaries:
              lda     ##0x7fff              ; min = INT16_MAX, max = -INT16_MAX
              sta     .near MIN16
              sta     .near (MIN16+2)
              lda     ##0x8001
              sta     .near MAX16
              sta     .near (MAX16+2)
              lda     .near _g_lines
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_lines+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near _g_numlines
              sta     .near AM_I
              beq     2$
1$:           ldy     ##OFS_LINE_V1         ; v1.x, v2.x, v1.y, v2.y
              ldx     ##0
              jsr     .kbank minMax
              ldy     ##OFS_LINE_V2
              ldx     ##0
              jsr     .kbank minMax
              ldy     ##(OFS_LINE_V1+2)
              ldx     ##2
              jsr     .kbank minMax
              ldy     ##(OFS_LINE_V2+2)
              ldx     ##2
              jsr     .kbank minMax
              lda     dp:.tiny (_Dp+4)
              clc
              adc     ##SIZEOF_LINE
              sta     dp:.tiny (_Dp+4)
              bcc     11$
              inc     dp:.tiny (_Dp+6)
11$:          dec     .near AM_I
              bne     1$
2$:           lda     .near MIN16           ; the limits << MAPBITS
              ldx     ##.near min_x
              jsr     .kbank toMap
              lda     .near (MIN16+2)
              ldx     ##.near min_y
              jsr     .kbank toMap
              lda     .near MAX16
              ldx     ##.near max_x
              jsr     .kbank toMap
              lda     .near (MAX16+2)
              ldx     ##.near max_y
              jsr     .kbank toMap
              lda     .near max_x           ; max_w, max_h
              sec
              sbc     .near min_x
              sta     .near max_w
              lda     .near (max_x+2)
              sbc     .near (min_x+2)
              sta     .near (max_w+2)
              lda     .near max_y
              sec
              sbc     .near min_y
              sta     .near max_h
              lda     .near (max_y+2)
              sbc     .near (min_y+2)
              sta     .near (max_h+2)
              lda     .near max_w           ; a = FixedApproxDiv(f_w << 16, max_w)
              sta     dp:.tiny _Dp
              lda     .near (max_w+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##0
              ldx     ##F_W
              jsl     long:FixedApproxDiv
              sta     .near AM_T
              stx     .near (AM_T+2)
              lda     .near max_h           ; b = FixedApproxDiv(f_h << 16, max_h)
              sta     dp:.tiny _Dp
              lda     .near (max_h+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##0
              ldx     ##F_H
              jsl     long:FixedApproxDiv
              sta     .near AM_U
              stx     .near (AM_U+2)
              ldx     ##.near AM_U          ; min_scale_mtof: the smaller
              ldy     ##.near AM_T
              jsr     .kbank less32
              bpl     3$
              ldx     ##.near AM_T
3$:           lda     abs:0,x
              sta     .near min_scale_mtof
              lda     abs:2,x
              sta     .near (min_scale_mtof+2)
              stz     dp:.tiny _Dp          ; max_scale_mtof = FixedApproxDiv(
              lda     ##2                   ;   f_h << 16, 2 * PLAYERRADIUS)
              sta     dp:.tiny (_Dp+2)
              lda     ##0
              ldx     ##F_H
              jsl     long:FixedApproxDiv
              sta     .near max_scale_mtof
              stx     .near (max_scale_mtof+2)
              rts

;;; minMax: the int16 at [_Dp+4],y: less than MIN16[X]: the minimum; else
;;; more than MAX16[X]: the maximum (X: 0 for x, 2 for y).
minMax:       lda     [.tiny (_Dp+4)],y
              tay
              sec
              sbc     .near MIN16,x
              bvc     1$
              eor     ##0x8000
1$:           bpl     2$
              tya
              sta     .near MIN16,x
              rts
2$:           tya
              sec
              sbc     .near MAX16,x
              beq     3$
              bvc     21$
              eor     ##0x8000
21$:          bmi     3$
              tya
              sta     .near MAX16,x
3$:           rts

;;; ---------------------------------------------------------------------------
;;; The window.
;;; ---------------------------------------------------------------------------

;;; changeWindowLoc: AM_changeWindowLoc: a pan ends the follow mode; the
;;; window moves, with its center in the map.
changeWindowLoc:
              lda     .near m_paninc
              ora     .near (m_paninc+2)
              ora     .near (m_paninc+4)
              ora     .near (m_paninc+6)
              beq     1$
              lda     .near automapmode
              and     ##(0xffff - AM_FOLLOW)
              sta     .near automapmode
              jsr     .kbank oldlocNone
1$:           lda     .near m_paninc        ; m_x += paninc.x, m_y += paninc.y
              ldx     .near (m_paninc+2)
              ldy     ##.near m_x
              jsr     .kbank add32
              lda     .near (m_paninc+4)
              ldx     .near (m_paninc+6)
              ldy     ##.near m_y
              jsr     .kbank add32
              lda     .near m_w             ; the center in the map
              ldx     .near (m_w+2)
              ldy     ##.near m_x
              jsr     .kbank clampCenter
              lda     .near m_h
              ldx     .near (m_h+2)
              ldy     ##.near m_y
              jsr     .kbank clampCenter
              brl     setX2Y2

;;; clampCenter: for the axis at near Y (m_x or m_y) with the window size X:C:
;;; the center c = m + size / 2 more than max: m = max - size / 2; else c less
;;; than min: m = min - size / 2.
clampCenter:  jsr     .kbank half
              sta     .near AM_U            ; size / 2
              stx     .near (AM_U+2)
              clc                           ; c
              adc     abs:0,y
              sta     .near AM_T
              txa
              adc     abs:2,y
              sta     .near (AM_T+2)
              phy
              tya                           ; max < c
              clc
              adc     ##(max_x - m_x)
              tay
              ldx     ##.near AM_T
              jsr     .kbank less32
              bmi     1$
              lda     1,s                   ; c < min
              clc
              adc     ##(min_x - m_x)
              tax
              ldy     ##.near AM_T
              jsr     .kbank less32
              bpl     2$
              txy
1$:           tyx                           ; X: the limit
              ply
              lda     abs:0,x               ; m = the limit - size / 2
              sec
              sbc     .near AM_U
              sta     abs:0,y
              lda     abs:2,x
              sbc     .near (AM_U+2)
              sta     abs:2,y
              rts
2$:           ply
              rts

;;; activateNewScale: AM_activateNewScale: the window keeps its center at the
;;; new scale.
activateNewScale:
              lda     .near m_w             ; m_x += m_w / 2, m_y += m_h / 2
              ldx     .near (m_w+2)
              jsr     .kbank half
              ldy     ##.near m_x
              jsr     .kbank add32
              lda     .near m_h
              ldx     .near (m_h+2)
              jsr     .kbank half
              ldy     ##.near m_y
              jsr     .kbank add32
              jsr     .kbank windowSize
              jsr     .kbank centerWindow
              brl     setX2Y2

;;; windowSize: m_w = FTOM(f_w), m_h = FTOM(f_h).
windowSize:   lda     ##F_W
              ldx     ##0
              jsr     .kbank ftom
              sta     .near m_w
              stx     .near (m_w+2)
              lda     ##F_H
              ldx     ##0
              jsr     .kbank ftom
              sta     .near m_h
              stx     .near (m_h+2)
              rts

;;; centerWindow: m_x -= m_w / 2, m_y -= m_h / 2.
centerWindow: lda     .near m_w
              ldx     .near (m_w+2)
              jsr     .kbank half
              jsr     .kbank negate
              ldy     ##.near m_x
              jsr     .kbank add32
              lda     .near m_h
              ldx     .near (m_h+2)
              jsr     .kbank half
              jsr     .kbank negate
              ldy     ##.near m_y
              brl     add32

;;; setX2Y2: m_x2 = m_x + m_w, m_y2 = m_y + m_h.
setX2Y2:      lda     .near m_x
              clc
              adc     .near m_w
              sta     .near m_x2
              lda     .near (m_x+2)
              adc     .near (m_w+2)
              sta     .near (m_x2+2)
              lda     .near m_y
              clc
              adc     .near m_h
              sta     .near m_y2
              lda     .near (m_y+2)
              adc     .near (m_h+2)
              sta     .near (m_y2+2)
              rts

;;; oldlocNone: f_oldloc.x = INT32_MAX.
oldlocNone:   lda     ##0xffff
              sta     .near f_oldloc
              lda     ##0x7fff
              sta     .near (f_oldloc+2)
              rts

;;; newFtom: scale_ftom = FixedReciprocal(scale_mtof).
newFtom:      lda     .near scale_mtof
              ldx     .near (scale_mtof+2)
              jsl     long:FixedReciprocal
              sta     .near scale_ftom
              stx     .near (scale_ftom+2)
              rts

;;; ---------------------------------------------------------------------------
;;; void AM_Ticker(void): follow the player, zoom, pan.
;;; ---------------------------------------------------------------------------
              .public AM_Ticker
AM_Ticker:    lda     .near automapmode
              bit     ##AM_ACTIVE
              beq     9$
              bit     ##AM_FOLLOW
              beq     1$
              jsr     .kbank followPlayer
1$:           lda     .near ftom_zoommul    ; zoom: ftom_zoommul not FRACUNIT
              bne     2$
              lda     .near (ftom_zoommul+2)
              dec     a
              beq     3$
2$:           jsr     .kbank changeWindowScale
3$:           lda     .near m_paninc        ; pan
              ora     .near (m_paninc+2)
              ora     .near (m_paninc+4)
              ora     .near (m_paninc+6)
              beq     9$
              jsr     .kbank changeWindowLoc
9$:           rtl

;;; followPlayer: AM_doFollowPlayer: the window on the player when he moved.
followPlayer: jsr     .kbank playerMo
              ldy     ##OFS_MO_X
              lda     [.tiny (_Dp+4)],y
              cmp     .near f_oldloc
              bne     1$
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              cmp     .near (f_oldloc+2)
              bne     1$
              ldy     ##OFS_MO_Y
              lda     [.tiny (_Dp+4)],y
              cmp     .near (f_oldloc+4)
              bne     1$
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              cmp     .near (f_oldloc+6)
              bne     1$
              rts
1$:           ldy     ##OFS_MO_X            ; f_oldloc = mo->x, mo->y
              lda     [.tiny (_Dp+4)],y
              sta     .near f_oldloc
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sta     .near (f_oldloc+2)
              ldy     ##OFS_MO_Y
              lda     [.tiny (_Dp+4)],y
              sta     .near (f_oldloc+4)
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sta     .near (f_oldloc+6)
              ldy     ##OFS_MO_X            ; m_x = FTOM(MTOF(mo->x >> 4)),
              jsr     .kbank moMap          ; m_y = FTOM(MTOF(mo->y >> 4))
              jsr     .kbank mtof
              jsr     .kbank ftom
              sta     .near m_x
              stx     .near (m_x+2)
              jsr     .kbank playerMo
              ldy     ##OFS_MO_Y
              jsr     .kbank moMap
              jsr     .kbank mtof
              jsr     .kbank ftom
              sta     .near m_y
              stx     .near (m_y+2)
              jsr     .kbank centerWindow
              brl     setX2Y2

;;; changeWindowScale: AM_changeWindowScale: the zoom of a tic, in the scale
;;; limits.
changeWindowScale:
              lda     .near mtof_zoommul    ; scale_mtof = FixedMul(scale_mtof,
              sta     dp:.tiny _Dp          ;   mtof_zoommul)
              lda     .near (mtof_zoommul+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near scale_mtof
              ldx     .near (scale_mtof+2)
              jsl     long:FixedMul
              sta     .near scale_mtof
              stx     .near (scale_mtof+2)
              jsr     .kbank newFtom
              ldy     ##.near scale_mtof    ; less than the minimum
              ldx     ##.near min_scale_mtof
              jsr     .kbank less32
              bmi     1$
              ldy     ##.near max_scale_mtof ; more than the maximum
              ldx     ##.near scale_mtof
              jsr     .kbank less32
              bpl     2$
              ldy     ##.near max_scale_mtof
              bra     3$
1$:           ldy     ##.near min_scale_mtof
3$:           tyx                           ; AM_min/maxOutWindowScale
              lda     abs:0,x
              sta     .near scale_mtof
              lda     abs:2,x
              sta     .near (scale_mtof+2)
              jsr     .kbank newFtom
2$:           brl     activateNewScale

;;; ---------------------------------------------------------------------------
;;; Fixed point helpers.
;;; ---------------------------------------------------------------------------

;;; ftom: X:C = FTOM(X:C) = X:C * scale_ftom (the low 32 bits).
ftom:         sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near scale_ftom
              sta     dp:.tiny (_Dp+4)
              lda     .near (scale_ftom+2)
              sta     dp:.tiny (_Dp+6)
              jsl     long:_Mul32
              rts

;;; mtof: X:C = MTOF(X:C) = FixedMul(X:C, scale_mtof) >> 16.
mtof:         ldy     .near scale_mtof
              sty     dp:.tiny _Dp
              ldy     .near (scale_mtof+2)
              sty     dp:.tiny (_Dp+2)
              jsl     long:FixedMul
              txa
              ldx     ##0
              cmp     ##0
              bpl     1$
              dex
1$:           rts

;;; half: X:C = X:C / 2 (int32, toward 0).
half:         cpx     ##0
              bpl     1$
              inc     a                     ; negative: + 1 first
              bne     1$
              inx
1$:           pha
              txa
              cmp     ##0x8000
              ror     a
              tax
              pla
              ror     a
              rts

;;; negate: X:C = -X:C.
negate:       eor     ##0xffff
              clc
              adc     ##1
              pha
              txa
              eor     ##0xffff
              adc     ##0
              tax
              pla
              rts

;;; add32: the int32 at near Y += X:C.
add32:        clc
              adc     abs:0,y
              sta     abs:0,y
              txa
              adc     abs:2,y
              sta     abs:2,y
              rts

;;; less32: N set if the int32 at near Y is less than the int32 at near X.
less32:       lda     abs:0,y
              cmp     abs:0,x
              lda     abs:2,y
              sbc     abs:2,x
              bvc     1$
              eor     ##0x8000
1$:           rts

;;; toMap: the int32 at near X = C (int16) << MAPBITS.
toMap:        pha
              and     ##0x000f
              xba
              asl     a
              asl     a
              asl     a
              asl     a
              sta     abs:0,x
              pla
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              cmp     ##0x8000
              ror     a
              sta     abs:2,x
              rts

;;; playerMo: _Dp[4-7] = _g_player.mo.
playerMo:     lda     .near (PL+OFS_PL_MO)
              sta     dp:.tiny (_Dp+4)
              lda     .near (PL+OFS_PL_MO+2)
              sta     dp:.tiny (_Dp+6)
              rts

;;; moMap: X:C = the fixed_t at offset Y of the mobj at _Dp[4-7] >> 4.
moMap:        lda     [.tiny (_Dp+4)],y
              sta     .near AM_T
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              ldx     ##(16 - MAPBITS)
1$:           cmp     ##0x8000
              ror     a
              ror     .near AM_T
              dex
              bne     1$
              tax
              lda     .near AM_T
              rts

;;; sinCos: RT_C, RT_S = the cosine and sine of the angle with the high word
;;; C (the fine angle: C >> 3).
sinCos:       lsr     a
              lsr     a
              lsr     a
              pha
              jsl     long:finecosineapprox
              sta     .near RT_C
              stx     .near (RT_C+2)
              pla
              jsl     long:finesineapprox
              sta     .near RT_S
              stx     .near (RT_S+2)
              rts

;;; rotatePoint: AM_rotate of the point at near X with RT_C, RT_S about
;;; RT_OX, RT_OY (the origin >> 4).
rotatePoint:  phx
              lda     abs:0,x               ; dx = x - xorig
              sec
              sbc     .near RT_OX
              sta     .near RT_DX
              lda     abs:2,x
              sbc     .near (RT_OX+2)
              sta     .near (RT_DX+2)
              lda     abs:4,x               ; dy = y - yorig
              sec
              sbc     .near RT_OY
              sta     .near RT_DY
              lda     abs:6,x
              sbc     .near (RT_OY+2)
              sta     .near (RT_DY+2)
              ldx     ##.near RT_DX         ; x = dx * cos - dy * sin + xorig
              ldy     ##.near RT_C
              jsr     .kbank mulAngle
              sta     .near AM_T
              stx     .near (AM_T+2)
              ldx     ##.near RT_DY
              ldy     ##.near RT_S
              jsr     .kbank mulAngle
              sta     .near AM_U
              stx     .near (AM_U+2)
              lda     .near AM_T
              sec
              sbc     .near AM_U
              sta     .near RT_X
              lda     .near (AM_T+2)
              sbc     .near (AM_U+2)
              sta     .near (RT_X+2)
              ldx     ##.near RT_DX         ; y = yorig + dx * sin + dy * cos
              ldy     ##.near RT_S
              jsr     .kbank mulAngle
              sta     .near AM_T
              stx     .near (AM_T+2)
              ldx     ##.near RT_DY
              ldy     ##.near RT_C
              jsr     .kbank mulAngle
              clc
              adc     .near AM_T
              sta     .near AM_T
              txa
              adc     .near (AM_T+2)
              sta     .near (AM_T+2)
              plx
              lda     .near AM_T
              clc
              adc     .near RT_OY
              sta     abs:4,x
              lda     .near (AM_T+2)
              adc     .near (RT_OY+2)
              sta     abs:6,x
              lda     .near RT_X
              clc
              adc     .near RT_OX
              sta     abs:0,x
              lda     .near (RT_X+2)
              adc     .near (RT_OX+2)
              sta     abs:2,x
              rts

;;; mulAngle: X:C = FixedMulAngle(the fixed_t at near X, the one at near Y).
mulAngle:     lda     abs:0,y
              sta     dp:.tiny _Dp
              lda     abs:2,y
              sta     dp:.tiny (_Dp+2)
              lda     abs:2,x
              pha
              lda     abs:0,x
              plx
              jsl     long:FixedMulAngle
              rts

;;; ---------------------------------------------------------------------------
;;; void AM_Drawer(void): the lines and the player arrow, in the rows below
;;; the message strip and above the map title (HU_Drawer).
;;; The full map is drawn in the back buffer (black): the bytes of the old
;;; lines become black, the new lines are drawn, and only the bytes of both
;;; lists go to the screen. All again (the view rows) after another screen,
;;; a change of the rows, with the menu, or when a list is full. A new
;;; message clears only its strip (clearStrip).
;;; The overlay: each pixel is a K_OVL record of the column lists
;;; (src/iigs/r_list65.s), drawn after the 3D view of its column; the title
;;; rows are not part of the view (viewbottom) and become black once.
;;; ---------------------------------------------------------------------------
              .public AM_Drawer
AM_Drawer:    lda     .near automapmode
              bit     ##AM_ACTIVE
              bne     1$
              rtl
1$:           pei     dp:.tiny LPTR         ; the saved scratch of the caller
              pei     dp:.tiny (LPTR+2)
              ldx     ##0                   ; the rows of the lines
              lda     .near message_on
              beq     2$
              ldx     ##STRIP_ROWS
2$:           stx     .near AM_WTOP
              lda     ##AM_TITLEY
              sta     .near AM_WBOT
              lda     .near automapmode
              bit     ##AM_OVERLAY
              beq     full
              lda     long:VW_HALF          ; the half and the 2/3 view:
              ora     long:VW_THIRD         ;   halfOvl
              beq     5$
              brl     halfOvl
5$:           lda     ##1
              sta     .near AM_MODE
              jsr     .kbank titleBand
              jsr     .kbank drawLines
              bra     done
full:         stz     .near AM_MODE
              lda     .near am_valid        ; the map is on the screen: only
              beq     redraw                ;   the bytes of the lines
              lda     .near AM_WTOP
              cmp     .near AM_OLDTOP
              bne     redraw
              lda     .near _g_menuactive
              bne     redraw
              lda     .near message_new     ; a new message: only its strip
              beq     4$                    ;   is black again
              jsr     .kbank clearStrip
4$:           jsr     .kbank eraseOld
              jsr     .kbank drawLines
              jsr     .kbank showBytes
              bra     swap
redraw:       stz     .near message_new
              jsr     .kbank clearView      ; all again
              lda     ##0
              ldx     ##F_H
              ldy     ##(159 << 8)
              jsl     long:I_MarkRect
              stz     .near iigs_textShown  ; (the text of the view is gone)
              stz     .near (iigs_textShown+2)
              lda     ##1
              sta     .near am_band
              sta     .near am_valid
              lda     .near AM_WTOP
              sta     .near AM_OLDTOP
              jsr     .kbank drawLines
swap:         lda     .near AM_OVF          ; a full list: all again next time
              beq     3$
              stz     .near am_valid
3$:           lda     .near AM_LN           ; the new list is the old one now
              sta     .near AM_ON
              lda     .near AM_LB
              eor     ##(2 * AM_LMAX)
              sta     .near AM_LB
done:         pla
              sta     dp:.tiny (LPTR+2)
              pla
              sta     dp:.tiny LPTR
              rtl
;;; halfOvl: split the map overlay at the view-window boundary. Inside the
;;; window, emit records for halfAll's column replay. Outside it, use the
;;; byte list so the next frame erases only pixels touched by the overlay.
halfOvl:      sep     #0x20                 ; shadowing off (the view turned
              lda     long:SHADOW           ;   it on): each border byte must
              pha                           ;   change on screen once, in
              ora     #0x08                 ;   showBytesH, after composition
              jsl     long:IIGS_SetShadow
              rep     #0x20
              lda     .near AM_MODE
              cmp     ##2
              beq     1$
              stz     .near AM_ON           ; first frame: no old list; the
              stz     .near (iigs_textShown+2) ;   title on the border (no band)
              lda     ##2
              sta     .near AM_MODE
1$:           jsr     .kbank eraseOldH
              jsr     .kbank drawLines
              jsr     .kbank showBytesH
              sep     #0x20
              pla
              jsl     long:IIGS_SetShadow
              rep     #0x20
              brl     swap

;;; AM_Clean: erase the last overlay's border pixels and title rows when
;;; leaving AM_MODE 3. The view replay replaces pixels inside its window;
;;; repainting the whole border would expose intermediate writes. Called
;;; by segMode in src/iigs/r_list65.s with DBR set to the near bank.
              .public AM_Clean
AM_Clean:     php
              rep     #0x30
              lda     long:VW_HALF          ; (full view: the view paints it)
              ora     long:VW_THIRD
              beq     9$
              sep     #0x20
              lda     long:SHADOW           ; SHR shadowing off
              pha
              ora     #0x08
              jsl     long:IIGS_SetShadow
              rep     #0x20
              jsr     .kbank eraseOldH
              lda     .near AM_ON
              sta     .near AM_CN
              lda     .near AM_LB
              eor     ##(2 * AM_LMAX)
              jsr     .kbank copyListH
              ldx     ##(AM_TITLEY * 160)   ; the title rows (AM_TITLEY even)
1$:           lda     long:VW_PA
              ldy     ##80
2$:           sta     long:SHRBUF,x
              inx
              inx
              dey
              bne     2$
              lda     long:VW_PB
              ldy     ##80
3$:           sta     long:SHRBUF,x
              inx
              inx
              dey
              bne     3$
              cpx     ##(F_H * 160)
              bcc     1$
              lda     ##AM_TITLEY
              ldx     ##F_H
              ldy     ##(159 << 8)
              jsl     long:I_MarkRect
              sep     #0x20
              pla
              jsl     long:IIGS_SetShadow
              rep     #0x20
9$:           stz     .near (iigs_textShown+2) ; (the title is gone)
              stz     .near AM_ON
              stz     .near AM_MODE
              plp
              rtl

;;; drawLines: the walls and the arrow, with a new list.
drawLines:    stz     .near AM_LN
              stz     .near AM_OVF
              lda     ##0xffff
              sta     .near AM_LAST
              jsr     .kbank drawWalls
              jmp     .kbank drawPlayers

;;; clearStrip: the message strip black (the full map), its text drawn again.
clearStrip:   stz     .near message_new
              ldx     ##0
              lda     ##0
1$:           sta     long:SHRBUF,x
              inx
              inx
              cpx     ##(STRIP_ROWS * 160)
              bcc     1$
              stz     .near iigs_textShown
              lda     ##0
              ldx     ##STRIP_ROWS
              ldy     ##(159 << 8)
              jsl     long:I_MarkRect
              rts

;;; titleBand: the overlay: the title rows black and on the screen once.
titleBand:    lda     .near am_band
              bne     9$
              inc     .near am_band
              ldx     ##(AM_TITLEY * 160)
              lda     ##0
1$:           sta     long:SHRBUF,x
              inx
              inx
              cpx     ##(F_H * 160)
              bcc     1$
              stz     .near (iigs_textShown+2) ; (the title again)
              lda     ##AM_TITLEY
              ldx     ##F_H
              ldy     ##(159 << 8)
              jsl     long:I_MarkRect
9$:           rts

;;; listPtr: _Dp[0-3] = AM_LISTS + C.
listPtr:      clc
              adc     ##.word0 AM_LISTS
              sta     dp:.tiny _Dp
              lda     ##.word2 AM_LISTS
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              rts

;;; eraseOld: the bytes of the old list black in the back buffer.
eraseOld:     lda     .near AM_LB
              eor     ##(2 * AM_LMAX)
              jsr     .kbank listPtr
              ldy     ##0
1$:           cpy     .near AM_ON
              bcs     9$
              lda     [.tiny _Dp],y
              tax
              sep     #0x20
              lda     #0
              sta     long:(SHRBUF & 0xff0000),x
              rep     #0x20
              iny
              iny
              bra     1$
9$:           rts

;;; eraseOldH: the old list's bytes get the border byte of their row.
eraseOldH:    lda     .near AM_LB
              eor     ##(2 * AM_LMAX)
              jsr     .kbank listPtr
              ldy     ##0
1$:           cpy     .near AM_ON
              bcs     9$
              lda     [.tiny _Dp],y
              and     ##0x7fff
              clc
              adc     ##(SHRBUF & 0xffff)
              tax
              lda     [.tiny _Dp],y         ; N: an odd row
              sep     #0x20
              bmi     2$
              lda     long:VW_PA
              bra     3$
2$:           lda     long:VW_PB
3$:           sta     long:(SHRBUF & 0xff0000),x
              rep     #0x20
              iny
              iny
              bra     1$
9$:           rts

;;; showBytes: the bytes of the old list (black now) and of the new list
;;; to the screen; all view rows when the new list is full. Each loop step
;;; has its register work after the slow screen write.
showBytes:    lda     .near AM_OVF
              beq     1$
              lda     ##0
              ldx     ##F_H
              ldy     ##(159 << 8)
              jsl     long:I_MarkRect
              rts
1$:           lda     .near AM_ON
              sta     .near AM_CN
              lda     .near AM_LB
              eor     ##(2 * AM_LMAX)
              jsr     .kbank copyList
              lda     .near AM_LN
              sta     .near AM_CN
              lda     .near AM_LB
;;; copyList: the AM_CN bytes of the list at offset C, from the back buffer
;;; to the screen.
copyList:     jsr     .kbank listPtr
              ldy     ##0
1$:           cpy     .near AM_CN
              bcs     9$
              lda     [.tiny _Dp],y
              tax
              sep     #0x20
              lda     long:(SHRBUF & 0xff0000),x
              sta     long:(SHR_SCREEN & 0xff0000),x
              rep     #0x20
              iny
              iny
              bra     1$
9$:           rts

;;; showBytesH, copyListH: showBytes for the half overlay's list. An entry is
;;; the offset from SHRBUF | 0x8000 for an odd row: bank-1 offsets of rows
;;; 154 on have bit 15 set themselves.
showBytesH:   lda     .near AM_ON
              sta     .near AM_CN
              lda     .near AM_LB
              eor     ##(2 * AM_LMAX)
              jsr     .kbank copyListH
              lda     .near AM_LN
              sta     .near AM_CN
              lda     .near AM_LB
copyListH:    jsr     .kbank listPtr
              ldy     ##0
1$:           cpy     .near AM_CN
              bcs     9$
              lda     [.tiny _Dp],y
              and     ##0x7fff
              clc
              adc     ##(SHRBUF & 0xffff)
              tax
              sep     #0x20
              lda     long:(SHRBUF & 0xff0000),x
              sta     long:(SHR_SCREEN & 0xff0000),x
              rep     #0x20
              iny
              iny
              bra     1$
9$:           rts

;;; plot: the pixel PX of the row LN_Y (ROWP) in the color LN_NIBH /
;;; LN_NIBL, if the row is one of the lines (AM_WTOP .. AM_WBOT - 1). The
;;; full map: into the back buffer, and its byte into the new list (once);
;;; the overlay: a K_OVL record. X stays.
plot:         lda     .near LN_Y
              cmp     .near AM_WTOP
              bcc     9$
              cmp     .near AM_WBOT
              bcs     9$
              phx
              lda     .near AM_MODE
              beq     pixFull
              cmp     ##1
              bne     pixHalf
              brl     ovl
9$:           rts
pixFull:      lda     dp:.tiny PX
              lsr     a
              tay
              sep     #0x20
              bcs     1$
              lda     [.tiny ROWP],y        ; x even: the high nibble
              and     #0x0f
              ora     .near LN_NIBH
              bra     2$
1$:           lda     [.tiny ROWP],y        ; x odd: the low nibble
              and     #0xf0
              ora     .near LN_NIBL
2$:           sta     [.tiny ROWP],y
              rep     #0x20
              tya                           ; its byte
              clc
              adc     dp:.tiny ROWP
              cmp     .near AM_LAST
              beq     8$
              sta     .near AM_LAST
              ldx     .near AM_LN
              cpx     ##(2 * AM_LMAX)
              bcs     7$
              pha
              txa
              clc
              adc     .near AM_LB
              tax
              pla
              sta     long:AM_LISTS,x
              inc     .near AM_LN
              inc     .near AM_LN
              bra     8$
7$:           lda     ##1
              sta     .near AM_OVF
8$:           plx
9$:           rts
;;; pixHalf: a window pixel is a record (ovlH); a border pixel is listed
;;; before it is drawn, and dropped when the list is full (it could not be
;;; erased).
pixHalf:      lda     long:VW_THIRD         ; (the 2/3 window: pixThird)
              bne     pixThird
              lda     .near LN_Y
              cmp     ##(VW_HT + 1)
              bcc     pixBorder
              cmp     ##VW_HB
              bcs     pixBorder
              lda     dp:.tiny PX
              cmp     ##(2 * VW_HL)
              bcc     pixBorder
              cmp     ##(2 * VW_HR + 2)
              bcs     pixBorder
              brl     ovlH
pixThird:     lda     .near LN_Y            ; in the 2/3 window: ovlT
              cmp     ##(VW_TT + 1)
              bcc     pixBorder
              cmp     ##VW_TB
              bcs     pixBorder
              lda     dp:.tiny PX
              cmp     ##(2 * VW_TL)
              bcc     pixBorder
              cmp     ##(2 * VW_TR + 2)
              bcs     pixBorder
              brl     ovlT
pixBorder:    lda     dp:.tiny PX           ; Y = the byte in the row
              lsr     a
              tay
              lda     .near LN_Y            ; its list entry
              lsr     a
              lda     ##0
              ror     a
              sta     .near TMPX
              tya
              clc
              adc     dp:.tiny ROWP
              sec
              sbc     ##(SHRBUF & 0xffff)
              ora     .near TMPX
              cmp     .near AM_LAST         ; (listed with the pixel before)
              beq     6$
              ldx     .near AM_LN
              cpx     ##(2 * AM_LMAX)
              bcs     8$                    ; (full: not drawn)
              sta     .near AM_LAST
              pha
              txa
              clc
              adc     .near AM_LB
              tax
              pla
              sta     long:AM_LISTS,x
              inc     .near AM_LN
              inc     .near AM_LN
6$:           lda     dp:.tiny PX
              lsr     a
              sep     #0x20
              bcs     1$
              lda     [.tiny ROWP],y        ; x even: the high nibble
              and     #0x0f
              ora     .near LN_NIBH
              bra     2$
1$:           lda     [.tiny ROWP],y        ; x odd: the low nibble
              and     #0xf0
              ora     .near LN_NIBL
2$:           sta     [.tiny ROWP],y
              rep     #0x20
8$:           plx
              rts
;;; ovl: recOvl of src/iigs/r_list65.s inline (no call chain or bank change).
ovl:          lda     dp:.tiny PX           ; Y = 2 * the column
              and     ##0xfffe
              tay
              lda     .near COLW,y          ; X = the free byte of its list
              tax
              and     ##0x00ff
              cmp     ##(PAGE_ROOM - OVL_SIZE + 1)
              bcs     8$                    ; (no room: an extra page first)
5$:           sep     #0x20                 ; (carry clear)
              txa
              adc     #OVL_SIZE
              sta     .near COLW,y          ; COLW past the record
              lda     #K_OVL
              sta     long:(RECBASE+R_KIND),x
              lda     .near LN_Y
              sta     long:(RECBASE+R_ROW),x
              lda     dp:.tiny PX
              lsr     a
              bcs     6$
              lda     #0x0f                 ; x even: keep the low nibble
              sta     long:(RECBASE+R_KEEP),x
              lda     .near LN_NIBH
              bra     7$
6$:           lda     #0xf0                 ; x odd: keep the high nibble
              sta     long:(RECBASE+R_KEEP),x
              lda     .near LN_NIBL
7$:           sta     long:(RECBASE+R_COLOR),x
              tyx                           ; X = 2 * the column
              lda     .near LN_Y
              inc     a
              FSCUTE  .near LN_Y
              rep     #0x20
              plx
              rts
8$:           phb                           ; newPage: X = 2 * the column, Y =
              phx                           ;   the free byte, DBR = RECBANK;
              tyx                           ;   out: Y = the free byte of the
              ply                           ;   new page
              pea     #(RECBANK * 0x101)
              plb
              plb
              jsl     long:newPage
              plb
              phy                           ; X = the free byte, Y = 2 * the
              txy                           ;   column
              plx
              clc
              bra     5$

;;; ovlH: ovl for a window pixel: into the list of full column 2 * (byte -
;;; 40), which halfAll draws into that byte, with the screen row; the fill
;;; spans end at full row 2 * (row - 42), the one the window shows.
ovlH:         lda     dp:.tiny PX           ; Y = 2 * the column: 4 * (byte - 40)
              and     ##0xfffe
              asl     a
              sec
              sbc     ##(4 * VW_HL)
              tay
              lda     .near COLW,y          ; X = the free byte of its list
              tax
              and     ##0x00ff
              cmp     ##(PAGE_ROOM - OVL_SIZE + 1)
              bcs     8$                    ; (no room: an extra page first)
5$:
              sep     #0x20                 ; (carry clear)
              txa
              adc     #OVL_SIZE
              sta     .near COLW,y          ; COLW past the record
              lda     #K_OVL
              sta     long:(RECBASE+R_KIND),x
              lda     .near LN_Y
              sta     long:(RECBASE+R_ROW),x
              lda     dp:.tiny PX
              lsr     a
              bcs     6$
              lda     #0x0f                 ; x even: keep the low nibble
              sta     long:(RECBASE+R_KEEP),x
              lda     .near LN_NIBH
              bra     7$
6$:           lda     #0xf0                 ; x odd: keep the high nibble
              sta     long:(RECBASE+R_KEEP),x
              lda     .near LN_NIBL
7$:           sta     long:(RECBASE+R_COLOR),x
              tyx                           ; X = 2 * the column
              lda     .near LN_Y            ; the full row: 2 * (row - 42)
              sec
              sbc     #(VW_HT + 1)
              asl     a
              sta     .near TMPX
              inc     a
              FSCUTE  .near TMPX
              rep     #0x20
              plx
              rts
8$:
              phb                           ; newPage (as ovl)
              phx
              tyx
              ply
              pea     #(RECBANK * 0x101)
              plb
              plb
              jsl     long:newPage
              plb
              phy
              txy
              plx
              clc
              bra     5$

;;; ovlT: ovlH for the 2/3 window: the list of full column c = b + b div 2
;;; (b = byte - 26), the fill spans end at full row k + k div 2 (k = row -
;;; 28).
ovlT:         lda     dp:.tiny PX           ; Y = 2c
              lsr     a
              sec
              sbc     ##VW_TL
              sta     .near TMPX
              lsr     a
              clc
              adc     .near TMPX
              asl     a
              tay
              lda     .near COLW,y          ; X = the free byte of its list
              tax
              and     ##0x00ff
              cmp     ##(PAGE_ROOM - OVL_SIZE + 1)
              bcs     8$
5$:           sep     #0x20                 ; (carry clear)
              txa
              adc     #OVL_SIZE
              sta     .near COLW,y
              lda     #K_OVL
              sta     long:(RECBASE+R_KIND),x
              lda     .near LN_Y
              sta     long:(RECBASE+R_ROW),x
              lda     dp:.tiny PX
              lsr     a
              bcs     6$
              lda     #0x0f                 ; x even: keep the low nibble
              sta     long:(RECBASE+R_KEEP),x
              lda     .near LN_NIBH
              bra     7$
6$:           lda     #0xf0
              sta     long:(RECBASE+R_KEEP),x
              lda     .near LN_NIBL
7$:           sta     long:(RECBASE+R_COLOR),x
              tyx                           ; X = 2c
              lda     .near LN_Y            ; the full row k + k div 2
              sec
              sbc     #(VW_TT + 1)
              sta     .near TMPX
              lsr     a
              clc
              adc     .near TMPX
              sta     .near TMPX
              inc     a
              FSCUTE  .near TMPX
              rep     #0x20
              plx
              rts
8$:           phb                           ; newPage (as ovl)
              phx
              tyx
              ply
              pea     #(RECBANK * 0x101)
              plb
              plb
              jsl     long:newPage
              plb
              phy
              txy
              plx
              clc
              bra     5$

;;; clearView: V_ClearViewWindow: rows 0-167 of the back buffer black.
clearView:    ldx     ##(F_H * 160 - 32)
1$:           lda     ##0
              sta     long:SHRBUF,x
              sta     long:(SHRBUF+2),x
              sta     long:(SHRBUF+4),x
              sta     long:(SHRBUF+6),x
              sta     long:(SHRBUF+8),x
              sta     long:(SHRBUF+10),x
              sta     long:(SHRBUF+12),x
              sta     long:(SHRBUF+14),x
              sta     long:(SHRBUF+16),x
              sta     long:(SHRBUF+18),x
              sta     long:(SHRBUF+20),x
              sta     long:(SHRBUF+22),x
              sta     long:(SHRBUF+24),x
              sta     long:(SHRBUF+26),x
              sta     long:(SHRBUF+28),x
              sta     long:(SHRBUF+30),x
              txa
              sec
              sbc     ##32
              tax
              bpl     1$
              rts

;;; drawWalls: AM_drawWalls: each line to show in the color of its kind.
drawWalls:    lda     .near automapmode     ; the rotation of the frame
              bit     ##AM_ROTATE
              beq     1$
              jsr     .kbank wallRotation
              jsr     .kbank fastSetup
              jsr     .kbank lvFrame
1$:           lda     .near _g_lines
              sta     dp:.tiny LPTR
              lda     .near (_g_lines+2)
              sta     dp:.tiny (LPTR+2)
              lda     .near _g_numlines
              sta     .near AM_I
              bne     line
              rts
next:         lda     dp:.tiny LPTR         ; the next line
              clc
              adc     ##SIZEOF_LINE
              sta     dp:.tiny LPTR
              bcc     1$
              inc     dp:.tiny (LPTR+2)
1$:           dec     .near AM_I
              bne     line
              rts
;;; skipRun: no computer map: the lines after LPTR up to the next seen one
;;; in a tight loop (Y walks their flags; most lines of a level are not seen:
;;; 958 of them in each frame of the E1M7 key test).
skipRun:      ldx     .near AM_I
              ldy     ##(OFS_LINE_R_FLAGS + SIZEOF_LINE)
1$:           dex
              beq     9$                    ; (no line left)
              lda     [.tiny LPTR],y
              and     ##ML_MAPPED
              bne     3$
              tya
              clc
              adc     ##SIZEOF_LINE
              tay
              bcc     1$
              inc     dp:.tiny (LPTR+2)     ; (Y wrapped: the next 64 KB)
              bra     1$
3$:           stx     .near AM_I            ; LPTR = that line
              tya
              sec
              sbc     ##OFS_LINE_R_FLAGS
              clc
              adc     dp:.tiny LPTR
              sta     dp:.tiny LPTR
              bcc     4$
              inc     dp:.tiny (LPTR+2)
4$:           brl     mapped
9$:           rts
line:         ldy     ##OFS_LINE_R_FLAGS    ; seen
              lda     [.tiny LPTR],y
              and     ##ML_MAPPED
              bne     mapped
              lda     .near (PL+OFS_PL_POWERS+2*CONST_PW_ALLMAP) ; else with the
              beq     skipRun               ;   computer map
              ldy     ##OFS_LINE_FLAGS
              lda     [.tiny LPTR],y
              and     ##ML_DONTDRAW
              bne     next
              lda     ##COLOR_UNSN
              bra     draw
mapped:       ldy     ##OFS_LINE_FLAGS
              lda     [.tiny LPTR],y
              bit     ##ML_DONTDRAW
              bne     next
              bit     ##ML_SECRET
              bne     secretLine
              ldy     ##OFS_LINE_SPECIAL    ; a keyed door
              lda     [.tiny LPTR],y
              sta     .near AM_SPECIAL
              sec
              sbc     ##26
              cmp     ##9
              bcs     1$
              tax
              lda     long:doorColors,x
              and     ##0x00ff
              bne     draw
1$:           ldy     ##(OFS_LINE_SIDENUM+2) ; one sided
              lda     [.tiny LPTR],y
              inc     a
              beq     oneSided
              lda     .near AM_SPECIAL      ; a teleporter
              cmp     ##97
              beq     2$
              brl     twoSided
2$:           lda     ##COLOR_TELE
              bra     draw
secretLine:   ldy     ##(OFS_LINE_SIDENUM+2) ; a secret door: the wall color
              lda     [.tiny LPTR],y        ;   (one sided: as the others)
              inc     a
              beq     oneSided
              lda     ##COLOR_WALL
              bra     draw
oneSided:     ldy     ##OFS_LINE_SIDENUM    ; one sided: the bound of a secret
              lda     [.tiny LPTR],y        ;   sector, or a wall
              jsr     .kbank sideSector
              ldy     ##OFS_SEC_OLDSPECIAL
              lda     [.tiny _Dp],y
              cmp     ##9
              bne     1$
              lda     ##COLOR_SECR
              bra     draw
1$:           lda     ##COLOR_WALL
draw:         sta     .near AM_COLOR
              lda     .near automapmode     ; the rotation mode: the fast
              bit     ##AM_ROTATE           ;   turn if it can
              beq     slowLine
              lda     .near RF_MC
              bmi     slowLine
              jsr     .kbank fastLine
              bcc     slowLine              ; (an end too far: the full math)
              brl     next
slowLine:     ldy     ##OFS_LINE_V1         ; the ends << MAPBITS
              lda     [.tiny LPTR],y
              ldx     ##.near ML
              jsr     .kbank toMap
              ldy     ##(OFS_LINE_V1+2)
              lda     [.tiny LPTR],y
              ldx     ##.near (ML+4)
              jsr     .kbank toMap
              ldy     ##OFS_LINE_V2
              lda     [.tiny LPTR],y
              ldx     ##.near (ML+8)
              jsr     .kbank toMap
              ldy     ##(OFS_LINE_V2+2)
              lda     [.tiny LPTR],y
              ldx     ##.near (ML+12)
              jsr     .kbank toMap
              lda     .near automapmode     ; turned with the player
              bit     ##AM_ROTATE
              beq     1$
              ldx     ##.near ML
              jsr     .kbank rotatePoint
              ldx     ##.near (ML+8)
              jsr     .kbank rotatePoint
1$:           jsr     .kbank drawMline
              brl     next
twoSided:     ldy     ##OFS_LINE_SIDENUM    ; two sided: the front and the
              lda     [.tiny LPTR],y        ;   back sector
              jsr     .kbank sideSector
              lda     dp:.tiny _Dp
              sta     dp:.tiny FRONT
              lda     dp:.tiny (_Dp+2)
              sta     dp:.tiny (FRONT+2)
              ldy     ##(OFS_LINE_SIDENUM+2)
              lda     [.tiny LPTR],y
              jsr     .kbank sideSector     ; (BACK: _Dp)
              ldy     ##OFS_SEC_FLOORHEIGHT ; a closed door: floor = ceiling in
              lda     [.tiny BACK],y        ;   the back or the front sector
              ldy     ##OFS_SEC_CEILINGHEIGHT
              cmp     [.tiny BACK],y
              bne     1$
              ldy     ##(OFS_SEC_FLOORHEIGHT+2)
              lda     [.tiny BACK],y
              ldy     ##(OFS_SEC_CEILINGHEIGHT+2)
              cmp     [.tiny BACK],y
              beq     3$
1$:           ldy     ##OFS_SEC_FLOORHEIGHT
              lda     [.tiny FRONT],y
              ldy     ##OFS_SEC_CEILINGHEIGHT
              cmp     [.tiny FRONT],y
              bne     4$
              ldy     ##(OFS_SEC_FLOORHEIGHT+2)
              lda     [.tiny FRONT],y
              ldy     ##(OFS_SEC_CEILINGHEIGHT+2)
              cmp     [.tiny FRONT],y
              bne     4$
3$:           lda     ##COLOR_CLSD
              bra     drawNear
4$:           ldy     ##OFS_SEC_OLDSPECIAL  ; the bound of a secret sector
              lda     [.tiny FRONT],y
              cmp     ##9
              beq     5$
              lda     [.tiny BACK],y
              cmp     ##9
              bne     6$
5$:           lda     ##COLOR_SECR
              bra     drawNear
6$:           ldy     ##OFS_SEC_FLOORHEIGHT ; a floor change
              lda     [.tiny BACK],y
              cmp     [.tiny FRONT],y
              bne     7$
              iny
              iny
              lda     [.tiny BACK],y
              cmp     [.tiny FRONT],y
              beq     8$
7$:           lda     ##COLOR_FCHG
              bra     drawNear
8$:           ldy     ##OFS_SEC_CEILINGHEIGHT ; a ceiling change
              lda     [.tiny BACK],y
              cmp     [.tiny FRONT],y
              bne     9$
              iny
              iny
              lda     [.tiny BACK],y
              cmp     [.tiny FRONT],y
              bne     9$
              brl     next
9$:           lda     ##COLOR_CCHG
drawNear:     brl     draw

;;; sideSector: _Dp[0-3] = _g_sides[C].sector.
sideSector:   asl     a                     ; C * 14 = C * 16 - C * 2
              sta     dp:.tiny _Dp
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny _Dp
              clc
              adc     .near _g_sides
              sta     dp:.tiny _Dp
              lda     .near (_g_sides+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_SIDE_SECTOR
              lda     [.tiny _Dp],y
              tax
              ldy     ##(OFS_SIDE_SECTOR+2)
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+2)
              stx     dp:.tiny _Dp
              rts

;;; fastSetup: the constants of the fast turn. |s cos| and |s sin| must stay
;;; below 0.25 so that int16 screen points cannot overflow; else RF_MC =
;;; 0xffff and the 32-bit path.
fastSetup:    lda     .near RT_C
              ldx     .near (RT_C+2)
              jsr     .kbank sq16
              bcs     9$
              sta     .near RF_MC
              sty     .near RF_SC
              lda     .near RT_S
              ldx     .near (RT_S+2)
              jsr     .kbank sq16
              bcs     9$
              sta     .near RF_MS
              sty     .near RF_SS
              lda     .near RT_OX
              ldx     .near (RT_OX+2)
              jsr     .kbank w16
              sta     .near RF_OX
              ldx     ##.near RT_DX         ; (RT_DX, RT_DY: the origin as a
              jsr     .kbank toMap          ;   map point)
              lda     .near RT_OY
              ldx     .near (RT_OY+2)
              jsr     .kbank w16
              sta     .near RF_OY
              ldx     ##.near RT_DY
              jsr     .kbank toMap
              ldx     ##.near RT_DX
              ldy     ##.near RF_CX         ; RF_CX, RF_CY
              jmp     .kbank toScreen
9$:           lda     ##0xffff
              sta     .near RF_MC
              rts

;;; sq16: C = |X:C * s| in 0.16 (s = scale_mtof / 2^20), Y = its sign;
;;; carry set from 0.25 on.
sq16:         ldy     .near scale_mtof
              sty     dp:.tiny _Dp
              ldy     .near (scale_mtof+2)
              sty     dp:.tiny (_Dp+2)
              jsl     long:FixedMul         ; X:C = the product
              ldy     ##0
              cpx     ##0x8000
              bcc     1$
              ldy     ##0x8000              ; negative: the magnitude
              eor     ##0xffff
              clc
              adc     ##1
              pha
              txa
              eor     ##0xffff
              adc     ##0
              tax
              pla
1$:           cpx     ##0x0004              ; 0x40000 >> 4 = 0.25
              bcs     9$
              pha                           ; X:C >> 4
              txa
              xba
              asl     a
              asl     a
              asl     a
              asl     a
              sta     .near RF_T
              pla
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              ora     .near RF_T
              clc
9$:           rts

;;; fastLine: project each endpoint with four 16x16 products, reusing its
;;; VS_TAB result when another line already projected it this frame.
;;; Carry clear requests the 32-bit path because an endpoint exceeds the
;;; int16 range. TMPX = 4 * line number, TMPY = 8 * vertex index for clipScr;
;;; AM_EV is the frame stamp used by lvFrame.
fastLine:     ldx     ##0xffff              ; (no cache: no vertex)
              lda     long:LV_OK
              beq     1$
              lda     .near _g_numlines     ; TMPX = 4 * the line number
              sec
              sbc     .near AM_I
              asl     a
              asl     a
              sta     .near TMPX
              tax
              lda     long:LV_TAB,x         ; the first end: its point of this
              tax                           ;   frame?
              bmi     1$
              lda     long:VS_TAB,x
              cmp     .near AM_EV
              bne     1$
              lda     long:(VS_TAB+2),x
              sta     .near FL
              lda     long:(VS_TAB+4),x
              sta     .near (FL+2)
              bra     2$
1$:           stx     .near TMPY
              ldy     ##OFS_LINE_V1
              lda     [.tiny LPTR],y
              sec
              sbc     .near RF_OX
              bvs     90$
              sta     .near RF_DX
              ldy     ##(OFS_LINE_V1+2)
              lda     [.tiny LPTR],y
              sec
              sbc     .near RF_OY
              bvs     90$
              sta     .near RF_DY
              ldy     ##.near FL
              jsr     .kbank fpoint
              ldx     .near TMPY            ; its point for the lines after it
              bmi     2$
              lda     .near AM_EV
              sta     long:VS_TAB,x
              lda     .near FL
              sta     long:(VS_TAB+2),x
              lda     .near (FL+2)
              sta     long:(VS_TAB+4),x
2$:           bra     21$
90$:          clc                           ; (an end too far)
              rts
21$:          ldx     ##0xffff              ; the second end
              lda     long:LV_OK
              beq     3$
              ldx     .near TMPX
              lda     long:(LV_TAB+2),x
              tax
              bmi     3$
              lda     long:VS_TAB,x
              cmp     .near AM_EV
              bne     3$
              lda     long:(VS_TAB+2),x
              sta     .near (FL+4)
              lda     long:(VS_TAB+4),x
              sta     .near (FL+6)
              bra     4$
3$:           stx     .near TMPY
              ldy     ##OFS_LINE_V2
              lda     [.tiny LPTR],y
              sec
              sbc     .near RF_OX
              bvs     90$
              sta     .near RF_DX
              ldy     ##(OFS_LINE_V2+2)
              lda     [.tiny LPTR],y
              sec
              sbc     .near RF_OY
              bvs     90$
              sta     .near RF_DY
              ldy     ##.near (FL+4)
              jsr     .kbank fpoint
              ldx     .near TMPY
              bmi     4$
              lda     .near AM_EV
              sta     long:VS_TAB,x
              lda     .near (FL+4)
              sta     long:(VS_TAB+2),x
              lda     .near (FL+6)
              sta     long:(VS_TAB+4),x
4$:           jsr     .kbank clipScr
              bcc     8$
              jsr     .kbank drawFL
8$:           sec
              rts
9$:           clc
              rts

;;; lvFrame: a new frame of the fast turn: its stamp (AM_VFR, and AM_EV for
;;; fastLine); LV_TAB for a new level (lvCheck).
lvFrame:      lda     .near RF_MC           ; (the fast turn off: no cache)
              bmi     9$
              jsr     .kbank lvCheck
              lda     long:AM_VFR
              inc     a
              bne     1$
              jsr     .kbank lvClear        ; (the stamps wrapped)
              lda     ##1
1$:           sta     long:AM_VFR
              sta     .near AM_EV
9$:           rts

;;; AM_LevelCache: lvCheck for the level just loaded (P_SetupLevel, right
;;; after I_InitSegVertices: on the 4 MB map the column records overwrite
;;; the vertex hash in the first frames). _Dp[8-11] kept.
              .public AM_LevelCache
AM_LevelCache: php
              rep     #0x30
              pei     dp:.tiny LPTR
              pei     dp:.tiny (LPTR+2)
              jsr     .kbank lvCheck
              pla
              sta     dp:.tiny (LPTR+2)
              pla
              sta     dp:.tiny LPTR
              plp
              rtl

;;; lvCheck: LV_TAB for this level (once a level: the vertex numbers of the
;;; line ends from the hash, about 20 ms). lvFrame calls it too: with the
;;; level's key already there it only compares (the 8 MB map needs no call
;;; at the level load).
lvCheck:      lda     .near _g_gamemap
              cmp     long:LV_KEY
              bne     1$
              lda     .near _g_numlines
              cmp     long:(LV_KEY+2)
              bne     1$
              lda     .near _g_lines
              cmp     long:(LV_KEY+4)
              bne     1$
              lda     .near (_g_lines+2)
              cmp     long:(LV_KEY+6)
              bne     1$
              rts
1$:           lda     .near _g_gamemap
              sta     long:LV_KEY
              lda     .near _g_numlines
              sta     long:(LV_KEY+2)
              lda     .near _g_lines
              sta     long:(LV_KEY+4)
              sta     dp:.tiny LPTR
              lda     .near (_g_lines+2)
              sta     long:(LV_KEY+6)
              sta     dp:.tiny (LPTR+2)
              lda     ##0
              sta     long:LV_OK
              lda     .near _g_numlines     ; (too many lines: no cache)
              beq     9$
              cmp     ##(LV_MAXL + 1)
              bcs     9$
              sta     .near AM_I
              ldx     ##0                   ; X: 4 * the line
2$:           phx
              ldy     ##OFS_LINE_V1
              jsr     .kbank lvEnd
              plx
              sta     long:LV_TAB,x
              phx
              ldy     ##OFS_LINE_V2
              jsr     .kbank lvEnd
              plx
              sta     long:(LV_TAB+2),x
              inx
              inx
              inx
              inx
              lda     dp:.tiny LPTR         ; the next line
              clc
              adc     ##SIZEOF_LINE
              sta     dp:.tiny LPTR
              bcc     3$
              inc     dp:.tiny (LPTR+2)
3$:           dec     .near AM_I
              bne     2$
              jsr     .kbank lvClear
              lda     ##1
              sta     long:AM_VFR
              sta     long:LV_OK
9$:           rts

;;; lvEnd: C = 8 * the vertex number of the line end at offset Y of the line
;;; at LPTR (vertexNumber of src/iigs/i_viigs65.s, reading only), 0xffff when
;;; it is not in the hash or the number is LV_MAXV or more.
lvEnd:        lda     [.tiny LPTR],y
              sta     .near TMPX
              iny
              iny
              lda     [.tiny LPTR],y
              sta     .near TMPY
              lda     .near TMPX            ; h = (x * 31 + y) & 8191
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     .near TMPX
              clc
              adc     .near TMPY
              and     ##(VTXHASH_SIZE - 1)
1$:           sta     .near CL_D            ; X = 6 h
              asl     a
              clc
              adc     .near CL_D
              asl     a
              tax
              lda     long:(VTXHASH+4),x
              cmp     ##0xffff
              beq     9$                    ; (empty: not a seg end)
              lda     long:VTXHASH,x
              cmp     .near TMPX
              bne     2$
              lda     long:(VTXHASH+2),x
              cmp     .near TMPY
              bne     2$
              lda     long:(VTXHASH+4),x
              cmp     ##LV_MAXV
              bcs     8$
              asl     a
              asl     a
              asl     a
              rts
2$:           lda     .near CL_D            ; the next entry
              inc     a
              and     ##(VTXHASH_SIZE - 1)
              bra     1$
8$:           lda     ##0xffff
9$:           rts

;;; lvClear: no point in VS_TAB (frame 0).
lvClear:      ldx     ##((LV_MAXV - 1) * 8)
              lda     ##0
1$:           sta     long:VS_TAB,x
              txa
              sec
              sbc     ##8
              tax
              lda     ##0
              bcs     1$
              rts

;;; fpoint: the screen point at near Y of RF_DX, RF_DY: x = CX + hi(dx c' -
;;; dy s'), y = CY - hi(dx s' + dy c'), c' = s cos, s' = s sin.
fpoint:       phy
              lda     .near RF_DX
              ldx     .near RF_MC
              ldy     .near RF_SC
              jsr     .kbank smul
              sty     .near RF_PL
              sta     .near RF_PH
              lda     .near RF_DY
              ldx     .near RF_MS
              ldy     .near RF_SS
              jsr     .kbank smul
              sta     .near RF_T            ; RF_P - Y:C = RF_P + ~(Y:C) + 1
              tya
              eor     ##0xffff
              sec
              adc     .near RF_PL
              lda     .near RF_T
              eor     ##0xffff
              adc     .near RF_PH           ; (its high word)
              clc
              adc     .near RF_CX
              ply
              phy
              sta     abs:0,y
              lda     .near RF_DX
              ldx     .near RF_MS
              ldy     .near RF_SS
              jsr     .kbank smul
              sty     .near RF_PL
              sta     .near RF_PH
              lda     .near RF_DY
              ldx     .near RF_MC
              ldy     .near RF_SC
              jsr     .kbank smul
              sta     .near RF_T            ; RF_P + Y:C: its high word
              tya
              clc
              adc     .near RF_PL
              lda     .near RF_T
              adc     .near RF_PH
              eor     ##0xffff              ; CY - that
              sec
              adc     .near RF_CY
              ply
              sta     abs:2,y
              rts

;;; smul: Y:C = C * m, signed; X = |m| < 0x4000, Y = its sign.
smul:         sty     .near RF_S
              cmp     ##0
              bpl     1$
              eor     ##0xffff              ; |a|: the sign turns
              inc     a
              pha
              lda     .near RF_S
              eor     ##0x8000
              sta     .near RF_S
              pla
1$:           sta     dp:.tiny MA           ; qmul of r_wall65.s inline (a
              txa                           ;   JSL each cost 2.2 ms a frame);
              tay                           ;   |a| + |m| < 0xc000: two banks
              clc                           ;   of squares suffice
              adc     dp:.tiny MA
              asl     a
              tax
              bcs     3$
              lda     long:AM_SQH,x
              sta     dp:.tiny _Dp          ; (free: the line is in LPTR)
              lda     long:AM_SQL,x
              bra     4$
3$:           lda     long:(AM_SQH+0x10000),x
              sta     dp:.tiny _Dp
              lda     long:(AM_SQL+0x10000),x
4$:           tax                           ; X = sq(s), low word
              tya                           ; d = |b - a|
              sec
              sbc     dp:.tiny MA
              bcs     5$
              eor     ##0xffff
              inc     a
5$:           asl     a
              tay
              txa
              tyx
              sec
              sbc     long:AM_SQL,x
              tay                           ; Y = low
              lda     dp:.tiny _Dp
              sbc     long:AM_SQH,x         ; C = high
              bit     .near RF_S
              bpl     2$
              pha                           ; negative: -(Y:C)
              tya
              eor     ##0xffff
              clc
              adc     ##1
              tay
              pla
              eor     ##0xffff
              adc     ##0
2$:           rts

;;; w16: C = the int32 X:C >> MAPBITS (arithmetic), clamped to the int16
;;; range.
w16:          pha
              txa
              clc
              adc     ##0x0800              ; X in 0xf800 .. 0x07ff: in range
              cmp     ##0x1000
              bcc     1$
              pla
              txa
              bmi     2$
              lda     ##0x7fff
              rts
2$:           lda     ##0x8000
              rts
1$:           txa
              asl     a
              asl     a
              asl     a
              asl     a
              sta     .near AM_T
              pla
              xba
              and     ##0x00ff
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              ora     .near AM_T
              rts

;;; wallRotation: the rotation of the lines in a frame: the angle ANG90 -
;;; mo->angle, about the player.
wallRotation: jsr     .kbank playerMo
              ldy     ##OFS_MO_ANGLE
              lda     ##0
              sec
              sbc     [.tiny (_Dp+4)],y
              iny
              iny
              lda     ##0x4000
              sbc     [.tiny (_Dp+4)],y
              jsr     .kbank sinCos
              jsr     .kbank playerMo
              ldy     ##OFS_MO_X
              jsr     .kbank moMap
              sta     .near RT_OX
              stx     .near (RT_OX+2)
              ldy     ##OFS_MO_Y
              jsr     .kbank moMap
              sta     .near RT_OY
              stx     .near (RT_OY+2)
              rts

;;; drawPlayers: AM_drawPlayers: the arrow of the player (turned with the map
;;; in the rotation mode).
drawPlayers:  jsr     .kbank playerMo       ; the place: mo->x >> 4, mo->y >> 4
              ldy     ##OFS_MO_X
              jsr     .kbank moMap
              sta     .near AMD_X
              stx     .near (AMD_X+2)
              ldy     ##OFS_MO_Y
              jsr     .kbank moMap
              sta     .near AMD_Y
              stx     .near (AMD_Y+2)
              lda     .near automapmode     ; the angle: in the rotation mode
              bit     ##AM_ROTATE           ;   angle - (angle - ANG90) = ANG90
              beq     1$
              lda     ##0x4000
              bra     2$
1$:           ldy     ##OFS_MO_ANGLE        ; else mo->angle
              lda     [.tiny (_Dp+4)],y
              iny
              iny
              ora     [.tiny (_Dp+4)],y
              sta     .near AM_TURN         ; (0: no turn)
              beq     3$
              lda     [.tiny (_Dp+4)],y
2$:           sta     .near AM_TURN
              jsr     .kbank sinCos
              stz     .near RT_OX           ; about 0
              stz     .near (RT_OX+2)
              stz     .near RT_OY
              stz     .near (RT_OY+2)
3$:           stz     .near AM_I            ; the lines of the arrow
4$:           lda     .near AM_I            ; ML = playerArrow[i]
              asl     a
              asl     a
              asl     a
              asl     a
              tax
              ldy     ##0
5$:           lda     long:playerArrow,x
              sta     .near ML,y
              inx
              inx
              iny
              iny
              cpy     ##16
              bcc     5$
              ldx     ##.near ML            ; turned, at the player
              jsr     .kbank arrowPoint
              ldx     ##.near (ML+8)
              jsr     .kbank arrowPoint
              lda     ##COLOR_SNGL
              sta     .near AM_COLOR
              jsr     .kbank drawMline
              inc     .near AM_I
              lda     .near AM_I
              cmp     ##NUMPLYRLINES
              bcc     4$
              rts

;;; arrowPoint: the point at near X turned (if AM_TURN), then moved to the
;;; place of the player.
arrowPoint:   lda     .near AM_TURN
              beq     1$
              lda     .near automapmode     ; the rotation mode turns by ANG90:
              bit     ##AM_ROTATE           ;   x, y = -y, x without products
              beq     2$                    ;   (the full map keeps its math)
              lda     abs:0,x
              sta     .near AM_U
              lda     abs:2,x
              sta     .near (AM_U+2)
              lda     abs:4,x
              eor     ##0xffff
              clc
              adc     ##1
              sta     abs:0,x
              lda     abs:6,x
              eor     ##0xffff
              adc     ##0
              sta     abs:2,x
              lda     .near AM_U
              sta     abs:4,x
              lda     .near (AM_U+2)
              sta     abs:6,x
              bra     1$
2$:           phx
              jsr     .kbank rotatePoint
              plx
1$:           lda     abs:0,x
              clc
              adc     .near AMD_X
              sta     abs:0,x
              lda     abs:2,x
              adc     .near (AMD_X+2)
              sta     abs:2,x
              lda     abs:4,x
              clc
              adc     .near AMD_Y
              sta     abs:4,x
              lda     abs:6,x
              adc     .near (AMD_Y+2)
              sta     abs:6,x
              rts

;;; ---------------------------------------------------------------------------
;;; drawMline: AM_drawMline(ML, AM_COLOR): the part of the line in the map
;;; window, drawn in screen coordinates.
;;; ---------------------------------------------------------------------------
drawMline:    jsr     .kbank clipMline
              bcc     1$
              brl     drawFL
1$:           rts

;;; clipMline: AM_clipMline(ML, FL): carry set if a part of the line is in the
;;; window; FL is that part in screen coordinates (Cohen-Sutherland).
clipMline:    ldx     ##.near ML            ; the trivial reject on the map
              jsr     .kbank mapCode
              sta     .near OC1
              ldx     ##.near (ML+8)
              jsr     .kbank mapCode
              and     .near OC1
              beq     1$
              clc
              rts
1$:           ldx     ##.near ML            ; the screen coordinates
              ldy     ##.near FL
              jsr     .kbank toScreen
              ldx     ##.near (ML+8)
              ldy     ##.near (FL+4)
              jsr     .kbank toScreen
;;; clipScr: the rest of clipMline for the screen points FL (fastLine).
clipScr:      ldx     ##.near FL            ; their outcodes
              jsr     .kbank outcode
              sta     .near OC1
              ldx     ##.near (FL+4)
              jsr     .kbank outcode
              sta     .near OC2
              and     .near OC1
              beq     2$
              clc
              rts
2$:           lda     .near OC1             ; until both ends are in the view
              ora     .near OC2
              bne     3$
              sec
              rts
3$:           lda     .near OC1             ; the end outside
              bne     4$
              lda     .near OC2
4$:           sta     .near OUTSIDE
              bit     ##OC_TOP
              beq     5$
              lda     .near (FL+2)          ; to the top: y = 0
              jsr     .kbank clipY
              stz     .near TMPY
              bra     8$
5$:           bit     ##OC_BOTTOM
              beq     6$
              lda     .near (FL+2)          ; to the bottom: y = f_h - 1
              sec
              sbc     ##F_H
              jsr     .kbank clipY
              lda     ##(F_H-1)
              sta     .near TMPY
              bra     8$
6$:           bit     ##OC_RIGHT
              beq     7$
              lda     ##(F_W-1)             ; to the right: x = f_w - 1
              sec
              sbc     .near FL
              jsr     .kbank clipX
              lda     ##(F_W-1)
              sta     .near TMPX
              bra     8$
7$:           lda     ##0                   ; to the left: x = 0
              sec
              sbc     .near FL
              jsr     .kbank clipX
              stz     .near TMPX
8$:           lda     .near OUTSIDE         ; that end at the new point
              cmp     .near OC1
              bne     9$
              lda     .near TMPX
              sta     .near FL
              lda     .near TMPY
              sta     .near (FL+2)
              ldx     ##.near FL
              jsr     .kbank outcode
              sta     .near OC1
              and     .near OC2
              bra     10$
9$:           lda     .near TMPX
              sta     .near (FL+4)
              lda     .near TMPY
              sta     .near (FL+6)
              ldx     ##.near (FL+4)
              jsr     .kbank outcode
              sta     .near OC2
              and     .near OC1
10$:          bne     out
              brl     2$
out:          clc
              rts

;;; mapCode: C = the outcode of the map point at near X against the window:
;;; y > m_y2 TOP, else y < m_y BOTTOM; x < m_x LEFT, else x > m_x2 RIGHT.
mapCode:      lda     .near m_y2            ; y > m_y2
              cmp     abs:4,x
              lda     .near (m_y2+2)
              sbc     abs:6,x
              bvc     1$
              eor     ##0x8000
1$:           bpl     2$
              lda     ##OC_TOP
              bra     3$
2$:           lda     abs:4,x               ; y < m_y
              cmp     .near m_y
              lda     abs:6,x
              sbc     .near (m_y+2)
              bvc     21$
              eor     ##0x8000
21$:          bpl     22$
              lda     ##OC_BOTTOM
              bra     3$
22$:          lda     ##0
3$:           sta     .near OC_T
              lda     abs:0,x               ; x < m_x
              cmp     .near m_x
              lda     abs:2,x
              sbc     .near (m_x+2)
              bvc     4$
              eor     ##0x8000
4$:           bpl     5$
              lda     ##OC_LEFT
              ora     .near OC_T
              rts
5$:           lda     .near m_x2            ; x > m_x2
              cmp     abs:0,x
              lda     .near (m_x2+2)
              sbc     abs:2,x
              bvc     51$
              eor     ##0x8000
51$:          bpl     6$
              lda     ##OC_RIGHT
              ora     .near OC_T
              rts
6$:           lda     .near OC_T
              rts

;;; toScreen: the screen point at near Y (int16 x, y) of the map point at
;;; near X: CXMTOF(x) = MTOF(x - m_x), CYMTOF(y) = f_h - MTOF(y - m_y).
toScreen:     phy
              lda     abs:4,x
              sec
              sbc     .near m_y
              sta     .near AM_U
              lda     abs:6,x
              sbc     .near (m_y+2)
              sta     .near (AM_U+2)
              lda     abs:0,x
              sec
              sbc     .near m_x
              pha
              lda     abs:2,x
              sbc     .near (m_x+2)
              tax
              pla
              jsr     .kbank mtof
              ply
              phy
              sta     abs:0,y
              lda     .near AM_U
              ldx     .near (AM_U+2)
              jsr     .kbank mtof
              eor     ##0xffff
              sec
              adc     ##F_H
              ply
              sta     abs:2,y
              rts

;;; outcode: C = DOOUTCODE of the screen point at near X: y < 0 TOP, else
;;; y >= f_h BOTTOM; x < 0 LEFT, else x >= f_w RIGHT (int16).
outcode:      ldy     ##0
              lda     abs:2,x
              bpl     1$
              ldy     ##OC_TOP
              bra     2$
1$:           cmp     ##F_H
              bmi     2$
              ldy     ##OC_BOTTOM
2$:           lda     abs:0,x
              bpl     3$
              tya
              ora     ##OC_LEFT
              rts
3$:           cmp     ##F_W
              bmi     4$
              tya
              ora     ##OC_RIGHT
              rts
4$:           tya
              rts

;;; clipY: TMPX = a.x + (dx * C) / dy with dy = a.y - b.y, dx = b.x - a.x
;;; (int16, as the C code).
clipY:        pha
              lda     .near (FL+2)
              sec
              sbc     .near (FL+6)
              sta     .near CL_D
              lda     .near (FL+4)
              sec
              sbc     .near FL
              tax
              pla
              jsl     long:IIGS_MulLo16
              ldx     .near CL_D
              jsl     long:_Div16
              clc
              adc     .near FL
              sta     .near TMPX
              rts

;;; clipX: TMPY = a.y + (dy * C) / dx with dy = b.y - a.y, dx = b.x - a.x
;;; (int16, as the C code).
clipX:        pha
              lda     .near (FL+4)
              sec
              sbc     .near FL
              sta     .near CL_D
              lda     .near (FL+6)
              sec
              sbc     .near (FL+2)
              tax
              pla
              jsl     long:IIGS_MulLo16
              ldx     .near CL_D
              jsl     long:_Div16
              clc
              adc     .near (FL+2)
              sta     .near TMPY
              rts

;;; ---------------------------------------------------------------------------
;;; drawFL: V_DrawLine(FL, AM_COLOR): the pixels from FL.a to FL.b (in the
;;; view) in the color, with the nibble table of each row. The error is
;;; doubled: ERR2 = 2 * err.
;;; ---------------------------------------------------------------------------
drawFL:       lda     .near (FL+4)          ; dx = abs(x1 - x0), sx
              sec
              sbc     .near FL
              beq     1$
              bpl     2$
1$:           eor     ##0xffff
              inc     a
              ldx     ##0xffff
              bra     3$
2$:           ldx     ##1
3$:           sta     .near LN_DX
              stx     .near LN_SX
              asl     a
              sta     .near LN_DX2
              lda     .near (FL+6)          ; dy = -abs(y1 - y0), sy
              sec
              sbc     .near (FL+2)
              beq     4$
              bpl     5$
4$:           ldx     ##0xffff
              ldy     ##(0x10000 - 160)
              bra     6$
5$:           eor     ##0xffff
              inc     a
              ldx     ##1
              ldy     ##160
6$:           sta     .near LN_DY
              stx     .near LN_SY
              sty     .near LN_SY160
              asl     a
              sta     .near LN_DY2
              clc
              adc     .near LN_DX2
              sta     .near LN_D2           ; 2 dx + 2 dy
              sta     dp:.tiny ERR2         ; 2 err = 2 dx + 2 dy
              lda     .near FL              ; the pixel
              sta     dp:.tiny PX
              lda     .near (FL+2)          ; its row: SHRBUF + y * 160
              sta     .near LN_Y
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sta     dp:.tiny ROWP
              asl     a
              asl     a
              clc
              adc     dp:.tiny ROWP
              adc     ##(SHRBUF & 0xffff)
              sta     dp:.tiny ROWP
              lda     ##(SHRBUF >> 16)
              sta     dp:.tiny (ROWP+2)
              lda     ##0xffff              ; (no index in rowColors yet)
              sta     .near LN_KEY
              lda     .near LN_Y
              jsr     .kbank rowColors
              lda     .near LN_DX           ; dx >= -dy: an x step each pixel
              clc
              adc     .near LN_DY
              bmi     yMajor
              ldx     .near LN_DX           ; (dx + 1 pixels)
xMajor:       jsr     .kbank plot
2$:           dex
              bmi     9$
              lda     dp:.tiny PX           ; the x step
              clc
              adc     .near LN_SX
              sta     dp:.tiny PX
              lda     dp:.tiny ERR2         ; a y step if 2 err <= dx (small
              cmp     .near LN_DX           ;   values: no overflow)
              beq     3$
              bpl     4$
3$:           clc
              adc     .near LN_D2
              sta     dp:.tiny ERR2
              jsr     .kbank yStep
              bra     xMajor
4$:           clc
              adc     .near LN_DY2
              sta     dp:.tiny ERR2
              bra     xMajor
9$:           rts
yMajor:       lda     .near LN_DY           ; a y step each pixel (-dy + 1
              eor     ##0xffff              ;   pixels)
              inc     a
              tax
yLoop:        jsr     .kbank plot
2$:           dex
              bmi     9$
              lda     dp:.tiny ERR2         ; an x step if 2 err >= dy
              cmp     .near LN_DY
              bmi     3$
              clc
              adc     .near LN_D2
              sta     dp:.tiny ERR2
              lda     dp:.tiny PX
              clc
              adc     .near LN_SX
              sta     dp:.tiny PX
              jsr     .kbank yStep
              bra     yLoop
3$:           clc
              adc     .near LN_DX2
              sta     dp:.tiny ERR2
              jsr     .kbank yStep
              bra     yLoop
9$:           rts

;;; yStep: the next row of the line, and the color in it.
yStep:        lda     dp:.tiny ROWP
              clc
              adc     .near LN_SY160
              sta     dp:.tiny ROWP
              lda     .near LN_Y
              clc
              adc     .near LN_SY
              sta     .near LN_Y
;;; rowColors: LN_NIBH, LN_NIBL = the nibbles of AM_COLOR in the row C.
rowColors:    asl     a
              phx
              tax
              lda     .near iigs_rowbase,x
              clc
              adc     .near AM_COLOR
              cmp     .near LN_KEY          ; (same index: same nibbles)
              beq     1$
              sta     .near LN_KEY
              tax
              sep     #0x20
              lda     long:NIBTAB,x
              sta     .near LN_NIBH
              lda     long:(NIBTAB+0x200),x
              sta     .near LN_NIBL
              rep     #0x20
1$:           plx
              rts

              .public OA_MODE, OA_CLEAN, pixHalf, OA_ROW
              .section onelist, text
pixOne:       lda     .near LN_Y
              cmp     ##56
              bcc     9$
              cmp     ##112
              bcs     9$
              lda     dp:.tiny PX
              cmp     ##106
              bcc     9$
              cmp     ##214
              bcs     9$
              lsr     a
              sec
              sbc     ##53
              sta     .near TMPX
              asl     a
              clc
              adc     .near TMPX
              asl     a
              tay
              lda     .near COLW,y
              tax
              and     ##0x00ff
              cmp     ##(PAGE_ROOM - OVL_SIZE + 1)
              bcc     8$
              jmp     long:OA_PAGE
8$:           jmp     long:OA_RECORD
9$:           jmp     long:pixBorder
oneOvlRow:    lda     .near LN_Y
              sec
              sbc     #56
              sta     .near TMPX
              asl     a
              clc
              adc     .near TMPX
              jmp     long:OA_CUT
              .public pixOne, oneOvlRow

OA_MODE        .equ    (AM_Drawer + 41) ; unchanged instruction site

OA_CLEAN        .equ    (AM_Clean + 3) ; unchanged instruction site

OA_RECORD        .equ    (ovlH + 23) ; unchanged instruction site

OA_ROW        .equ    (ovlH + 74) ; unchanged instruction site

OA_CUT        .equ    (ovlH + 81) ; unchanged instruction site

OA_PAGE        .equ    (ovlH + 114) ; unchanged instruction site

              .section fourlist, text
pixQuarter:       lda     .near LN_Y
              cmp     ##63
              bcc     9$
              cmp     ##105
              bcs     9$
              lda     dp:.tiny PX
              cmp     ##120
              bcc     9$
              cmp     ##200
              bcs     9$
              lsr     a
              sec
              sbc     ##60
              asl     a
              asl     a
              asl     a
              tay
              lda     .near COLW,y
              tax
              and     ##0x00ff
              cmp     ##(PAGE_ROOM - OVL_SIZE + 1)
              bcc     8$
              jmp     long:OA_PAGE
8$:           jmp     long:OA_RECORD
9$:           jmp     long:pixBorder
quarterOvlRow:    lda     .near LN_Y
              sec
              sbc     #63
              asl     a
              asl     a
              jmp     long:OA_CUT
pixThreequarter:       lda     .near LN_Y
              cmp     ##21
              bcc     9$
              cmp     ##147
              bcs     9$
              lda     dp:.tiny PX
              cmp     ##40
              bcc     9$
              cmp     ##280
              bcs     9$
              lsr     a
              sec
              sbc     ##20
              tax
              lda     long:U_INV,x
              and     ##255
              asl     a
              tay
              lda     .near COLW,y
              tax
              and     ##0x00ff
              cmp     ##(PAGE_ROOM - OVL_SIZE + 1)
              bcc     8$
              jmp     long:OA_PAGE
8$:           jmp     long:OA_RECORD
9$:           jmp     long:pixBorder
threequarterOvlRow:    lda     .near LN_Y
              sec
              sbc     #21
              phx
              xba
              lda     #0
              xba
              tax
              lda     long:U_INV,x
              plx
              jmp     long:OA_CUT
U_INV:
              .byte   0x00, 0x01, 0x02, 0x04, 0x05, 0x06, 0x08, 0x09, 0x0a, 0x0c, 0x0d, 0x0e, 0x10, 0x11, 0x12, 0x14
              .byte   0x15, 0x16, 0x18, 0x19, 0x1a, 0x1c, 0x1d, 0x1e, 0x20, 0x21, 0x22, 0x24, 0x25, 0x26, 0x28, 0x29
              .byte   0x2a, 0x2c, 0x2d, 0x2e, 0x30, 0x31, 0x32, 0x34, 0x35, 0x36, 0x38, 0x39, 0x3a, 0x3c, 0x3d, 0x3e
              .byte   0x40, 0x41, 0x42, 0x44, 0x45, 0x46, 0x48, 0x49, 0x4a, 0x4c, 0x4d, 0x4e, 0x50, 0x51, 0x52, 0x54
              .byte   0x55, 0x56, 0x58, 0x59, 0x5a, 0x5c, 0x5d, 0x5e, 0x60, 0x61, 0x62, 0x64, 0x65, 0x66, 0x68, 0x69
              .byte   0x6a, 0x6c, 0x6d, 0x6e, 0x70, 0x71, 0x72, 0x74, 0x75, 0x76, 0x78, 0x79, 0x7a, 0x7c, 0x7d, 0x7e
              .byte   0x80, 0x81, 0x82, 0x84, 0x85, 0x86, 0x88, 0x89, 0x8a, 0x8c, 0x8d, 0x8e, 0x90, 0x91, 0x92, 0x94
              .byte   0x95, 0x96, 0x98, 0x99, 0x9a, 0x9c, 0x9d, 0x9e, 0xa0, 0xa1, 0xa2, 0xa4, 0xa5, 0xa6, 0xa8, 0xa9
              .public pixQuarter, quarterOvlRow, pixThreequarter, threequarterOvlRow
