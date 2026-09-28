;;; BSP walk in 65816 assembly.
;;;
;;; R_RenderBSPNode, R_CheckBBox, R_Subsector, R_AddLine and
;;; R_ClipWallSegment of r_draw.c, with the same results; the light of
;;; Doom's renderer (R_WallLight, R_SpriteColorMap, the plane colors) in
;;; place of the one light of each sector of r_draw.c (R_LoadColorMap).
;;; R_AddSprites is in src/iigs/r_thing65.s, R_LoadSkyPatch in
;;; src/iigs/r_frame65.s. The walk calls itself with
;;; jsr; each level keeps its node on the stack. The code below it keeps
;;; its values in registers and stores only what the callees read.
;;;
;;; The walk keeps the angle of each vertex (the segs that meet at a vertex
;;; need the same R_PointToAngle16) while the view stays at the same map
;;; unit. I_InitSegVertices (src/iigs/i_viigs65.s) numbers the seg ends and
;;; clears their frame stamps at level load.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"

              .extern _Dp, memset, fixedcolormap, fullcolormap, extralight, _g_gamma, nukage
              .extern pointAngle, shiftMul, R_StoreWallRange
              .extern R_LoadSkyPatch, R_AddSprites, c21Floor
              .extern nodes, _g_subsectors, _g_segs, _g_sectors, _g_lines, _g_gametic
              .extern viewx, viewy, viewz, viewangle16, skyflatnum, validcount
              .extern BSPDP, CN_LSEC
              .extern floorplane_color, ceilingplane_color, solidcol
#if defined IIGS_PHASES
              .extern iigs_phase
#endif

ND            .equ    (_Dp+12)        ; the node of the level, or its box
SG            .equ    (_Dp+16)        ; the seg of R_Subsector
SC            .equ    (_Dp+4)         ; the sector of R_Subsector
WP_SEG        .equ    BSPDP           ; the seg for R_StoreWallRange (src/iigs/r_wall65.s)
WP_FS         .equ    (BSPDP+9)       ; its front sector

CLIPANGLE     .equ    0x2008          ; clipangle = xtoviewangleTable[0]
PLANE_D       .equ    10              ; fixed distance-light offset for planes
                                      ;   before the PCMO colormap lookup

SEGANGLE      .equ    MM_SEGANGLE     ; see src/iigs/iigs.scm
SEGSTAMP      .equ    MM_SEGSTAMP
SEGVTX        .equ    MM_SEGVTX
VTXHASH_SIZE  .equ    8192

CORE_NODEADR  .equ    MM_B3F          ; SIGHTLOG: existing node address at node * 4

              .section znear, bss
BS_A1:        .space  2               ; checkBox: angle1 + 0x8000; the segs: angle2
BS_SPAN:      .space  2               ; angle1 - angle2 of the seg
BS_FIRST:     .space  2               ; R_ClipWallSegment: first, last
BS_LAST:      .space  2
BS_F:         .space  2               ; the first column not solid (only grows
                                      ;   in a frame; CONST_VIEWWIDTH: all solid)
BS_TO:        .space  2
BS_SEGX:      .space  2               ; the seg * 2
BS_SEGEND:    .space  2               ; the end of the segs * 2
BS_CM:        .space  2               ; the plane colormap of the sector
BS_XP:        .space  4               ; viewSide: the view from the node
BS_YP:        .space  4
BS_L:         .space  4
VA_FRAME:     .space  2               ; frame number for SEGSTAMP, never 0
VA_VX:        .space  2               ; the map unit of the view of VA_FRAME
VA_VY:        .space  2

;;; N = (A < operand), signed 16-bit. Destroys A.
SLT16         .macro  op
              sec
              sbc     \op
              bvc     1$
              eor     ##0x8000
1$:
              .endm

;;; The same with the operand [ptr],y.
SLT16Y        .macro  ptr
              sec
              sbc     [.tiny \ptr],y
              bvc     1$
              eor     ##0x8000
1$:
              .endm

#if defined IIGS_PHASES
PHASE         .macro  n
              lda     ##\n
              sta     .near iigs_phase
              .endm
#else
PHASE         .macro  n
              .endm
#endif

;;; ---------------------------------------------------------------------------
;;; void R_RenderBSPNode(int16_t bspnum)                     In: C.
;;; ---------------------------------------------------------------------------
              .section bspcode, text
              .public R_RenderBSPNode
R_RenderBSPNode:
              stz     .near BS_F            ; no solid column yet
              tax                           ; bspnum
              lda     .near (viewx+2)       ; the vertex angles stay while the
              cmp     .near VA_VX           ;   view stays at the same map unit
              bne     1$
              lda     .near (viewy+2)
              cmp     .near VA_VY
              bne     1$
              lda     .near VA_FRAME
              bne     3$
1$:           lda     .near (viewx+2)
              sta     .near VA_VX
              lda     .near (viewy+2)
              sta     .near VA_VY
              inc     .near VA_FRAME        ; a new frame for the angle cache
              bne     3$
              phx
              lda     ##0                   ; after 65535 frames: no angles
              ldx     ##(2*VTXHASH_SIZE-2)
2$:           sta     long:SEGSTAMP,x
              dex
              dex
              bpl     2$
              inc     .near VA_FRAME
              plx
3$:           stz     .near CN_LSEC         ; (bspSub: no sector before)
              pei     dp:.tiny ND
              pei     dp:.tiny (ND+2)
              pei     dp:.tiny SG
              pei     dp:.tiny (SG+2)
              lda     .near (nodes+2)       ; the banks of the nodes and segs
              sta     dp:.tiny (ND+2)
              lda     .near (_g_segs+2)
              sta     dp:.tiny (SG+2)
              txa
              jsr     .kbank bspNode
              PHASE   3
              pla
              sta     dp:.tiny (SG+2)
              pla
              sta     dp:.tiny SG
              pla
              sta     dp:.tiny (ND+2)
              pla
              sta     dp:.tiny ND
              rtl

;;; bspNode: R_RenderBSPNode(C) of the C code, with jsr. The node stays on
;;; the stack (actual node address) for the back side; side0 and side1 know the
;;; side of the view.
bspNode:      bit     ##CONST_NF_SUBSECTOR  ; a subsector
              beq     10$
              cmp     ##0xffff
              beq     1$
              and     ##0x7fff
              jmp     .kbank bspSub
1$:           lda     ##0                   ; bspnum == -1: subsector 0
              jmp     .kbank bspSub

10$:          asl     a                     ; P_InitSightLogs already resolved nodes[]
              asl     a                     ; four bytes per node, address first
              tax
              lda     long:CORE_NODEADR,x
              pha                           ; actual address for the back side
              sta     dp:.tiny ND
              bra     19$
              .space  3                     ; subsequent code keeps its address
19$:
              ldy     ##OFS_NODE_DX         ; the side of the view point
              lda     [.tiny ND],y          ;   (R_PointOnSide)
              beq     30$
              ldy     ##OFS_NODE_DY
              lda     [.tiny ND],y
              beq     40$
              jsr     .kbank viewSide
              bcs     side1
              bra     side0
30$:          ldy     ##OFS_NODE_X          ; dx == 0: ix <= node->x ? dy > 0 : dy < 0
              lda     [.tiny ND],y
              SLT16   .near (viewx+2)       ; node->x < ix
              bmi     32$
              ldy     ##OFS_NODE_DY
              lda     [.tiny ND],y
              bmi     side0
              beq     side0
              bra     side1
32$:          ldy     ##OFS_NODE_DY
              lda     [.tiny ND],y
              bmi     side1
              bra     side0
40$:          ldy     ##OFS_NODE_Y          ; dy == 0: iy <= node->y ? dx < 0 : dx > 0
              lda     [.tiny ND],y
              SLT16   .near (viewy+2)       ; node->y < iy
              bmi     42$
              ldy     ##OFS_NODE_DX
              lda     [.tiny ND],y
              bmi     side1
              bra     side0
42$:          ldy     ##OFS_NODE_DX
              lda     [.tiny ND],y
              bmi     side0
              bra     side1

side0:        ldy     ##OFS_NODE_CHILDREN   ; the front space: children[0]
              lda     [.tiny ND],y
              jsr     .kbank bspNode
              lda     1,s                   ; saved node address: ND = bbox[1]
              clc
              adc     ##(OFS_NODE_BBOX + 8)
              sta     dp:.tiny ND
              bra     19$
              .space  7                     ; subsequent code keeps its address
19$:
              jsr     .kbank checkBox
              pla
              bcc     1$
              ldy     ##(OFS_NODE_CHILDREN + 2 - OFS_NODE_BBOX - 8) ; children[1]
              lda     [.tiny ND],y
              brl     bspNode
1$:           rts

side1:        ldy     ##(OFS_NODE_CHILDREN + 2) ; the front space: children[1]
              lda     [.tiny ND],y
              jsr     .kbank bspNode
              lda     1,s                   ; saved node address: ND = bbox[0]
              clc
              adc     ##OFS_NODE_BBOX
              sta     dp:.tiny ND
              bra     19$
              .space  7                     ; subsequent code keeps its address
19$:
              jsr     .kbank checkBox
              pla
              bcc     1$
              ldy     ##(OFS_NODE_CHILDREN - OFS_NODE_BBOX) ; children[0]
              lda     [.tiny ND],y
              brl     bspNode
1$:           rts

;;; viewSide: C = R_PointOnSide(viewx, viewy, ND) for dx != 0, dy != 0.
viewSide:     ldy     ##OFS_NODE_X          ; x -= node->x << FRACBITS
              lda     .near (viewx+2)
              sec
              sbc     [.tiny ND],y
              sta     .near (BS_XP+2)
              ldy     ##OFS_NODE_Y          ; y -= node->y << FRACBITS
              lda     .near (viewy+2)
              sec
              sbc     [.tiny ND],y
              sta     .near (BS_YP+2)
              ldy     ##OFS_NODE_DX         ; the sign bits decide: (dy ^ dx ^ ix ^ iy) < 0
              eor     [.tiny ND],y
              eor     .near (BS_XP+2)
              ldy     ##OFS_NODE_DY
              eor     [.tiny ND],y
              bpl     1$
              lda     [.tiny ND],y          ; (dy ^ ix) < 0
              eor     .near (BS_XP+2)
              asl     a
              rts
1$:           jsl     long:c14Bounds        ; proven log interval, else original products
              nop
              nop                           ; original instruction addresses stay
              lda     .near viewy
              sta     .near BS_YP
              ldx     ##.near BS_YP
              ldy     ##OFS_NODE_DX
              lda     [.tiny ND],y
              jsl     long:shiftMul
              sta     .near BS_L
              stx     .near (BS_L+2)
              ldx     ##.near BS_XP
              ldy     ##OFS_NODE_DY
              lda     [.tiny ND],y
              jsl     long:shiftMul
              sta     dp:.tiny _Dp          ; L - R >= 0
              stx     dp:.tiny (_Dp+2)
              lda     .near BS_L
              cmp     dp:.tiny _Dp
              lda     .near (BS_L+2)
              sbc     dp:.tiny (_Dp+2)
              bvc     2$
              eor     ##0x8000
2$:           eor     ##0x8000              ; C = not N
              asl     a
c14SideDone:  rts

;;; ---------------------------------------------------------------------------
;;; checkBox: R_CheckBBox(ND), ND = the bounding box of a child. Out: C = 1
;;; if some part of the box might be visible. The corners to check come
;;; from the place of the view: x: viewx <= left << 16 (0), viewx < right
;;; << 16 (1), else 2; y: viewy >= top << 16 (0), viewy > bottom << 16 (1),
;;; else 2.
;;; Two tests before the corner angles give false where the C code gives
;;; false (BOXPRE): all columns solid, and the angles of the two corners
;;; of the case lie in an arc R (see below) whose angles, less viewangle,
;;; are all in clipangle..-clipangle: then the C code finds both corners
;;; off one edge, or wraps them around behind the view and still finds
;;; them off an edge. (demo3: 17 of the 99 corner angles a frame.)
;;; ---------------------------------------------------------------------------
checkBox:     ldy     ##(2*CONST_BOXLEFT)
              lda     .near (viewx+2)
              sec
              sbc     [.tiny ND],y
              beq     1$
              bvc     2$
              eor     ##0x8000
2$:           bmi     3$                    ; viewx.hi < left
              bra     4$
1$:           lda     .near viewx           ; viewx.hi == left
              bne     4$
3$:           ldx     ##0                   ; x 0
              bra     6$
4$:           ldy     ##(2*CONST_BOXRIGHT)
              lda     .near (viewx+2)
              SLT16Y  ND
              bmi     5$                    ; viewx < right << 16
              ldx     ##4                   ; x 2
              bra     6$
5$:           ldx     ##2                   ; x 1
6$:           ldy     ##(2*CONST_BOXTOP)
              lda     .near (viewy+2)
              SLT16Y  ND
              bmi     7$
              jmp     (.kbank boxY0,x)      ; viewy >= top << 16: y 0
7$:           ldy     ##(2*CONST_BOXBOTTOM)
              lda     .near (viewy+2)
              sec
              sbc     [.tiny ND],y
              beq     8$
              bvc     9$
              eor     ##0x8000
9$:           bmi     10$                   ; viewy.hi < bottom: y 2
              jmp     (.kbank boxY1,x)
8$:           lda     .near viewy           ; viewy.hi == bottom
              bne     11$
10$:          jmp     (.kbank boxY2,x)
11$:          jmp     (.kbank boxY1,x)

boxY0:        .word   .word0 box0, .word0 box1, .word0 box2
boxY1:        .word   .word0 box4, .word0 boxIn, .word0 box6
boxY2:        .word   .word0 box8, .word0 box9, .word0 box10

;;; The cases: angle1 from the first corner (+ 0x8000 in BS_A1: the signed
;;; order of the angles is the unsigned order then), angle2 from the other.
;;; The angles of the corners of a case lie in the arc R = [r0, r0 + len]
;;; (the octants of pointAngle, with its values 0x3fff, 0x7fff, 0xc000 on
;;; the axes; angle2 to angle1 goes counterclockwise in R), except a corner
;;; at the map unit of the view (angle 0): viewCorner.
;;; boxPre: for the case X (0..16: 6 * the y case + 2 * the x case), false
;;; for checkBox (the return address of the case is dropped) when all
;;; columns are solid, or when (r0 - clipangle - viewangle) & 0xffff <=
;;; 0x10000 - 2 clipangle - len (R is outside the view) and no corner is
;;; at the view; else rts.
boxPre:       lda     .near BS_F            ; all columns solid
              cmp     ##CONST_VIEWWIDTH
              bcs     1$
              lda     long:BXR0,x           ; r0 - clipangle
              sec
              sbc     .near viewangle16
              cmp     long:BXLIM,x          ; 0x10000 - 2 clipangle - len + 1
              bcs     2$
              jsr     .kbank viewCorner
              bcs     2$
1$:           pla                           ; false for checkBox
              clc
2$:           rts
;;; The arcs R of the cases, by X: r0 - clipangle, 0x10000 - 2 clipangle -
;;; len + 1 (box0: 270..360 degrees, box1: 180..360, box2: 180..270, box4:
;;; 270..450, box6: 90..270, box8: 0..90, box9: 0..180, box10: 90..180).
BXR0:         .word   0xc000 - CLIPANGLE, 0x7fff - CLIPANGLE, 0x7fff - CLIPANGLE
              .word   0xc000 - CLIPANGLE, 0, 0x3fff - CLIPANGLE
              .word   0x10000 - CLIPANGLE, 0x10000 - CLIPANGLE, 0x3fff - CLIPANGLE
BXLIM:        .word   0x10000 - 2 * CLIPANGLE - 0x4000 + 1, 0x10000 - 2 * CLIPANGLE - 0x8001 + 1
              .word   0x10000 - 2 * CLIPANGLE - 0x4001 + 1, 0x10000 - 2 * CLIPANGLE - 0x7fff + 1, 0
              .word   0x10000 - 2 * CLIPANGLE - 0x8001 + 1, 0x10000 - 2 * CLIPANGLE - 0x3fff + 1
              .word   0x10000 - 2 * CLIPANGLE - 0x7fff + 1, 0x10000 - 2 * CLIPANGLE - 0x4000 + 1

boxIn:        sec                           ; the view is in the box
              rts
box0:         ldx     ##0
              jsr     .kbank boxPre
              jsr     .kbank cornerRT       ; right top, left bottom
              sec
              sbc     .near viewangle16
              eor     ##0x8000
              sta     .near BS_A1
              jsr     .kbank cornerLB
              jmp     .kbank boxAngles
box1:         ldx     ##2
              jsr     .kbank boxPre
              jsr     .kbank cornerRT       ; right top, left top
              sec
              sbc     .near viewangle16
              eor     ##0x8000
              sta     .near BS_A1
              jsr     .kbank cornerLT
              jmp     .kbank boxAngles
box2:         ldx     ##4
              jsr     .kbank boxPre
              jsr     .kbank cornerRB       ; right bottom, left top
              sec
              sbc     .near viewangle16
              eor     ##0x8000
              sta     .near BS_A1
              jsr     .kbank cornerLT
              jmp     .kbank boxAngles
box4:         ldx     ##6
              jsr     .kbank boxPre
              jsr     .kbank cornerLT       ; left top, left bottom
              sec
              sbc     .near viewangle16
              eor     ##0x8000
              sta     .near BS_A1
              jsr     .kbank cornerLB
              jmp     .kbank boxAngles
box6:         ldx     ##10
              jsr     .kbank boxPre
              jsr     .kbank cornerRB       ; right bottom, right top
              sec
              sbc     .near viewangle16
              eor     ##0x8000
              sta     .near BS_A1
              jsr     .kbank cornerRT
              jmp     .kbank boxAngles
box8:         ldx     ##12
              jsr     .kbank boxPre
              jsr     .kbank cornerLT       ; left top, right bottom
              sec
              sbc     .near viewangle16
              eor     ##0x8000
              sta     .near BS_A1
              jsr     .kbank cornerRB
              jmp     .kbank boxAngles
box9:         ldx     ##14
              jsr     .kbank boxPre
              jsr     .kbank cornerLB       ; left bottom, right bottom
              sec
              sbc     .near viewangle16
              eor     ##0x8000
              sta     .near BS_A1
              jsr     .kbank cornerRB
              jmp     .kbank boxAngles
box10:        ldx     ##16
              jsr     .kbank boxPre
              jsr     .kbank cornerLB       ; left bottom, right top
              sec
              sbc     .near viewangle16
              eor     ##0x8000
              sta     .near BS_A1
              jsr     .kbank cornerRT
              jmp     .kbank boxAngles

;;; viewCorner: carry set when the map unit of the view is a corner of the
;;; box ND (its angle is then 0, which R of the case may not hold).
viewCorner:   lda     .near (viewx+2)
              ldy     ##(2*CONST_BOXLEFT)
              cmp     [.tiny ND],y
              beq     1$
              ldy     ##(2*CONST_BOXRIGHT)
              cmp     [.tiny ND],y
              bne     9$
1$:           lda     .near (viewy+2)
              ldy     ##(2*CONST_BOXTOP)
              cmp     [.tiny ND],y
              beq     8$
              ldy     ##(2*CONST_BOXBOTTOM)
              cmp     [.tiny ND],y
              beq     8$
9$:           clc
              rts
8$:           sec
              rts

;;; cornerRT, cornerLT, cornerRB, cornerLB: C = R_PointToAngle16 of a
;;; corner of the box ND (right or left, top or bottom).
cornerRT:     ldy     ##(2*CONST_BOXTOP)
              lda     [.tiny ND],y
              tax
              ldy     ##(2*CONST_BOXRIGHT)
              bra     corner
cornerLT:     ldy     ##(2*CONST_BOXTOP)
              lda     [.tiny ND],y
              tax
              ldy     ##(2*CONST_BOXLEFT)
              bra     corner
cornerRB:     ldy     ##(2*CONST_BOXBOTTOM)
              lda     [.tiny ND],y
              tax
              ldy     ##(2*CONST_BOXRIGHT)
              bra     corner
cornerLB:     ldy     ##(2*CONST_BOXBOTTOM)
              lda     [.tiny ND],y
              tax
              ldy     ##(2*CONST_BOXLEFT)
corner:       lda     [.tiny ND],y
              txy
              jmp     .kbank pointAngle

;;; boxAngles: the rest of R_CheckBBox, C = angle2, BS_A1 = angle1 + 0x8000.
boxAngles:    sec
              sbc     .near viewangle16
              eor     ##0x8000
              cmp     .near BS_A1           ; angle1 < angle2: behind us
              beq     3$
              bcc     3$
              ldy     .near BS_A1           ; ANG180_16 <= angle1 < ANG270_16:
              cpy     ##0x4000              ;   angle1 = INT16_MAX
              bcs     2$
              ldy     ##0xffff
              sty     .near BS_A1
              bra     3$
2$:           lda     ##0                   ; else angle2 = INT16_MIN
3$:           cmp     ##(CLIPANGLE + 0x8000) ; angle2 >= clipangle: both off the
              bcc     4$                    ;   left edge
              clc
              rts
4$:           cmp     ##(0x10000 - CLIPANGLE - 0x8000 + 1) ; angle2 <= -clipangle:
              bcs     5$                    ;   clip at the right edge
              lda     ##(0x10000 - CLIPANGLE - 0x8000)
5$:           sec                           ; sx2 = viewangletox(angle2)
              sbc     ##(0x4000 + 8 * CONST_VIEWANGLETOXMAX)
              bcs     6$
              lda     ##CONST_VIEWWIDTH
              bra     7$
6$:           lsr     a
              lsr     a
              lsr     a
              tax
              lda     abs:.near viewangletoxTable,x
              and     ##0x00ff
7$:           sta     .near BS_LAST
              lda     .near BS_A1           ; angle1 <= -clipangle: both off the
              cmp     ##(0x10000 - CLIPANGLE - 0x8000 + 1) ; right edge
              bcs     8$
              clc
              rts
8$:           cmp     ##(CLIPANGLE + 0x8000) ; angle1 >= clipangle: clip at the
              bcc     9$                    ;   left edge
              lda     ##(CLIPANGLE + 0x8000)
9$:           sec                           ; sx1 = viewangletox(angle1)
              sbc     ##(0x4000 + 8 * CONST_VIEWANGLETOXMAX)
              bcs     10$
              lda     ##CONST_VIEWWIDTH
              bra     11$
10$:          lsr     a
              lsr     a
              lsr     a
              tax
              lda     abs:.near viewangletoxTable,x
              and     ##0x00ff
11$:          cmp     .near BS_LAST         ; sx1 == sx2: does not cross a pixel
              beq     12$
              tax                           ; all columns solid?
              jsr     .kbank scan0
              cmp     .near BS_LAST
              beq     12$
              sec
              rts
12$:          clc
              rts

;;; scan0: C = the first x in X..BS_LAST-1 with solidcol[x] == 0, else
;;; BS_LAST (R_ScanCols(first, last, 0) of r_draw.c). scan1: the same for
;;; solidcol[x] == 1. They test 4 columns at a time; the columns past the
;;; end can be any bytes, so the result is at most BS_LAST.
scan0:        cpx     .near BS_LAST
              bcs     9$
1$:           lda     abs:.near solidcol,x  ; 4 ones: 0x0101 after and
              and     abs:.near (solidcol+2),x
              cmp     ##0x0101
              bne     2$
              inx
              inx
              inx
              inx
              cpx     .near BS_LAST
              bcc     1$
9$:           lda     .near BS_LAST
              rts
2$:           lda     abs:.near solidcol,x  ; x or x + 1, else x + 2 or x + 3
              cmp     ##0x0101
              bne     3$
              inx
              inx
              lda     abs:.near solidcol,x
3$:           and     ##0x00ff
              beq     4$
              inx
4$:           cpx     .near BS_LAST
              bcs     9$
              txa
              rts
scan1:        cpx     .near BS_LAST
              bcs     9$
1$:           lda     abs:.near solidcol,x  ; 4 zeros: 0 after ora
              ora     abs:.near (solidcol+2),x
              bne     2$
              inx
              inx
              inx
              inx
              cpx     .near BS_LAST
              bcc     1$
9$:           lda     .near BS_LAST
              rts
2$:           lda     abs:.near solidcol,x  ; x or x + 1, else x + 2 or x + 3
              bne     3$
              inx
              inx
              lda     abs:.near solidcol,x
3$:           and     ##0x00ff
              bne     4$
              inx
4$:           cpx     .near BS_LAST
              bcs     9$
              txa
              rts

;;; ---------------------------------------------------------------------------
;;; bspSub: R_Subsector(C), then rts. _Dp[0-3] = the subsector (for
;;; R_AddSprites), SC = its sector, SG = its segs.
;;; ---------------------------------------------------------------------------
bspSub:       asl     a                     ; sub = &_g_subsectors[num]
              asl     a
              asl     a
              clc
              adc     .near _g_subsectors
              sta     dp:.tiny _Dp
              lda     .near (_g_subsectors+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_SUB_FIRSTLINE   ; the segs: BS_SEGX (seg * 2) to
              lda     [.tiny _Dp],y         ;   BS_SEGEND, SG = &_g_segs[firstline]
              asl     a
              sta     .near BS_SEGX
              asl     a
              asl     a
              asl     a
              clc
              adc     .near BS_SEGX         ; * 18
              clc
              adc     .near _g_segs
              sta     dp:.tiny SG
              ldy     ##OFS_SUB_NUMLINES
              lda     [.tiny _Dp],y
              asl     a
              clc
              adc     .near BS_SEGX
              sta     .near BS_SEGEND
              ldy     ##(OFS_SUB_SECTOR+2)  ; SC = sub->sector (the near
              lda     [.tiny _Dp],y         ;   frontsector is written by the
              sta     dp:.tiny (SC+2)       ;   masked pass, which reads it back)
              ldy     ##OFS_SUB_SECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny SC
              cmp     .near CN_LSEC         ; the sector of the subsector before:
              bne     12$                   ;   the same plane colors, its things
              sta     dp:.tiny WP_FS        ; (R_StoreWallRange: its bank is set
              brl     c21SubSky                   ;   for the frame). Already in SC.
12$:          sta     dp:.tiny WP_FS
              sta     .near CN_LSEC

              ;; the plane colors: FLATCM[the colormap of the light + the
              ;; flat]; the colormap is startmap - PLANE_D, or the fixed one
              ldy     ##OFS_SEC_LIGHTLEVEL
              lda     [.tiny SC],y
              ldx     .near LT_FIXED
              bpl     1$
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              clc
              adc     .near LT_BASE
              sec                           ; without the gun flash: the fill
              sbc     .near extralight      ;   colors stay, so the fill skip
              asl     a                     ;   can reuse unchanged fill colors
              tax
              lda     long:SMAP,x
              sec
              sbc     ##PLANE_D
              asl     a
              tax
              lda     long:PCMO,x
              bra     2$
1$:           txa                           ; the fixed colormap: n * 32
              lsr     a
              lsr     a
              lsr     a
2$:           sta     .near BS_CM
              ;; Keep the floor's signed difference for all walls in this
              ;; sector. The helper returns the original high word and flags.
              jmp     .kbank c21Floor
              .space  12                    ; original15byte comparison prefix
              .public c21FloorDone
c21FloorDone  .equ    .
              bvc     3$
              eor     ##0x8000
3$:           bpl     4$
              ldy     ##OFS_SEC_FLOORPIC
              jsr     .kbank flatColor
              bra     5$
4$:           lda     ##0xffff
5$:           sta     .near floorplane_color
              ldy     ##OFS_SEC_CEILINGPIC  ; a sky: its patch after the sprites
              lda     [.tiny SC],y
              cmp     .near skyflatnum
              bne     6$
              lda     ##0xfffe
              bra     9$
6$:           ldy     ##OFS_SEC_CEILINGHEIGHT ; ceilingheight > viewz
              lda     .near viewz
              cmp     [.tiny SC],y
              iny
              iny
              lda     .near (viewz+2)
              sbc     [.tiny SC],y
              bvc     7$
              eor     ##0x8000
7$:           bpl     8$
              ldy     ##OFS_SEC_CEILINGPIC
              jsr     .kbank flatColor
              bra     9$
8$:           lda     ##0xffff
9$:           sta     .near ceilingplane_color

              ;; R_AddSprites(SC, frontsector->lightlevel), when the things
              ;; of the sector are not in the frame yet
              ldy     ##OFS_SEC_VALIDCOUNT
              lda     [.tiny SC],y
              cmp     .near validcount
              beq     c21SubSky
              lda     .near validcount      ; sec->validcount = validcount
              sta     [.tiny SC],y
              PHASE   11
              ldy     ##OFS_SEC_LIGHTLEVEL
              lda     [.tiny SC],y
              jsl     long:R_AddSprites
              PHASE   3
c21SubSky:    lda     .near ceilingplane_color
              cmp     ##0xfffe
              bne     11$
              jsl     long:R_LoadSkyPatch
11$:          lda     .near BS_SEGX         ; no segs
              cmp     .near BS_SEGEND
              bcc     segLoop
              rts

;;; flatColor: C = FLATCM[BS_CM + the flat in field Y of SC] (flats 0-2:
;;; nukage, the frame of the time).
flatColor:    lda     [.tiny SC],y
              cmp     ##3
              bcs     1$
              lda     .near nukage
1$:           clc
              adc     .near BS_CM
              tax
              lda     long:FLATCM,x
              and     ##0x00ff
              rts
              .space  4                     ; dropped the frontsector copies

;;; ---------------------------------------------------------------------------
;;; segLoop: R_AddLine for each seg SG of the subsector, then curline =
;;; NULL and rts. The angles of the vertices come from the cache when this
;;; frame has them.
;;; ---------------------------------------------------------------------------
segLoop:      ldy     ##OFS_SEG_ANGLE       ; along an axis, with the map unit of
              lda     [.tiny SG],y          ;   the view (the point of the
              bit     ##0x3fff              ;   angles) 2 or more behind the
              bne     sl0                   ;   line: the back side, which the
              asl     a                     ;   angles would find (a seg is at
              bmi     1$                    ;   most 2380 long: 35 angle units
              ldy     ##OFS_SEG_V1          ;   past ANG180_16)
              lda     .near (viewx+2)       ; n = (1, 0), (-1, 0): x
              bra     2$
1$:           ldy     ##(OFS_SEG_V1+2)      ; n = (0, 1), (0, -1): y
              lda     .near (viewy+2)
2$:           bcs     3$
              sec                           ; + : view - v1 - 2 >= 0
              sbc     [.tiny SG],y
              bra     4$
3$:           eor     ##0xffff              ; - : v1 - view - 2 >= 0
              sec
              adc     [.tiny SG],y
4$:           bvs     sl0
              sec
              sbc     ##2
              bvs     sl0
              bmi     sl0
              brl     segNext
sl0:          lda     .near BS_SEGX         ; angle2 = R_PointToAngle16(v2)
              asl     a
              tax
              lda     long:(SEGVTX+2),x     ; the vertex number
              asl     a
              tax
              lda     long:SEGSTAMP,x
              cmp     .near VA_FRAME
              bne     1$
              lda     long:SEGANGLE,x
              bra     2$
1$:           ldy     ##(OFS_SEG_V2+2)
              jsr     .kbank vtxAngle
2$:           sta     .near BS_A1
              lda     .near BS_SEGX         ; angle1 = R_PointToAngle16(v1)
              asl     a
              tax
              lda     long:SEGVTX,x
              asl     a
              tax
              lda     long:SEGSTAMP,x
              cmp     .near VA_FRAME
              bne     3$
              lda     long:SEGANGLE,x
              bra     4$
3$:           ldy     ##(OFS_SEG_V1+2)
              jsr     .kbank vtxAngle
4$:           tay                           ; span = angle1 - angle2
              sec
              sbc     .near BS_A1
              cmp     ##0x8000              ; span >= ANG180_16: the back side
              bcc     5$
              brl     segNext
5$:           sta     .near BS_SPAN
              tya                           ; tspan = angle1 - viewangle16 +
              sec                           ;   clipangle
              sbc     .near viewangle16
              clc
              adc     ##CLIPANGLE
              cmp     ##(2*CLIPANGLE+1)     ; tspan > 2 * clipangle
              bcc     7$
              sbc     ##(2*CLIPANGLE)       ; carry is set
              cmp     .near BS_SPAN         ; tspan >= span: off the left edge
              bcc     6$
              brl     segNext
6$:           lda     ##(2*CLIPANGLE)       ; angle1 = clipangle
7$:           tay                           ; Y = tspan of angle1
              lda     .near viewangle16     ; tspan = clipangle - (angle2 -
              clc                           ;   viewangle16)
              adc     ##CLIPANGLE
              sec
              sbc     .near BS_A1
              cmp     ##(2*CLIPANGLE+1)
              bcc     9$
              sbc     ##(2*CLIPANGLE)
              cmp     .near BS_SPAN
              bcc     8$
              brl     segNext
8$:           lda     ##(2*CLIPANGLE)       ; angle2 = -clipangle
9$:           eor     ##0xffff              ; x2 = viewangletox(angle2):
              sec                           ;   (angle2 + ANG90_16) >> 3 - 1032 =
              adc     ##(0x4000 + CLIPANGLE - 8 * CONST_VIEWANGLETOXMAX) ; (0x3fc8 - tspan) >> 3
              bpl     10$
              lda     ##CONST_VIEWWIDTH
              bra     11$
10$:          lsr     a
              lsr     a
              lsr     a
              tax
              lda     abs:.near viewangletoxTable,x
              and     ##0x00ff
11$:          sta     .near BS_LAST
              tya                           ; x1 = viewangletox(angle1): (tspan
              sec                           ;   - 0x48) >> 3
              sbc     ##(8 * CONST_VIEWANGLETOXMAX + CLIPANGLE - 0x4000)
              bcs     12$
              lda     ##CONST_VIEWWIDTH
              bra     13$
12$:          lsr     a
              lsr     a
              lsr     a
              tax
              lda     abs:.near viewangletoxTable,x
              and     ##0x00ff
13$:          cmp     .near BS_LAST         ; x1 >= x2: does not cross a pixel
              bcc     14$
              brl     segNext
14$:          sta     .near BS_FIRST

              ;; the seg for R_StoreWallRange (WP_SEG: it finds its line and
              ;; back sector itself, only for a seg that draws)
              lda     dp:.tiny SG
              sta     dp:.tiny WP_SEG

;;; clipWall: R_ClipWallSegment(BS_FIRST, BS_LAST, 0). The render flags of
;;; the C code (RF_IGNORE, RF_CLOSED: skip the line, clip it as solid) are
;;; never set (the low byte of r_flags stays 0, R_RecalcLineFlags only kept
;;; r_validcount, which nothing else reads): no test of them, no
;;; memset of solidcol here (R_RenderSegLoop marks the solid columns).
clipWall:     ldx     .near BS_FIRST        ; while (first < last)
              cpx     .near BS_LAST
              bcs     segNext
              lda     abs:.near solidcol,x
              and     ##0x00ff
              beq     2$
              jsr     .kbank scan0          ; first = R_ScanCols(first, last, 0)
              sta     .near BS_FIRST
              bra     clipWall
2$:           jsr     .kbank scan1          ; to = R_ScanCols(first, last, 1)
              sta     .near BS_TO
              PHASE   9
              lda     .near BS_TO           ; R_StoreWallRange(first, to - 1)
              dec     a
              sta     dp:.tiny _Dp
              lda     .near BS_FIRST
              jsl     long:R_StoreWallRange
              PHASE   3
              lda     .near BS_F            ; the first column not solid (F <= first:
              cmp     .near BS_FIRST        ;   first is open) moves only when this
              bne     3$                    ;   wall began at it
              ldy     .near BS_LAST         ; F = the first open column from F
              lda     ##CONST_VIEWWIDTH
              sta     .near BS_LAST
              ldx     .near BS_F
              jsr     .kbank scan0
              sta     .near BS_F
              sty     .near BS_LAST
3$:           lda     .near BS_TO           ; first = to
              sta     .near BS_FIRST
              bra     clipWall

segNext:      lda     dp:.tiny SG           ; line++
              clc
              adc     ##SIZEOF_SEG
              sta     dp:.tiny SG
              lda     .near BS_SEGX
              inc     a
              inc     a
              sta     .near BS_SEGX
              cmp     .near BS_SEGEND
              bcs     1$
              brl     segLoop
1$:           rts                           ; (curline: only the masked pass
                                            ;   uses it, and sets it)

;;; vtxAngle: C = R_PointToAngle16 of the end of the seg SG at Y - 2 (x)
;;; and Y (y), into the cache of its vertex X * 2.
vtxAngle:     phx
              lda     [.tiny SG],y          ; y
              tax
              dey
              dey
              lda     [.tiny SG],y          ; x
              txy
              jsr     .kbank pointAngle
              plx
              sta     long:SEGANGLE,x
              tay
              lda     .near VA_FRAME
              sta     long:SEGSTAMP,x
              tya
              rts
              .space  72               ; preserve following code's cache slots

;;; ---------------------------------------------------------------------------
;;; The distance light of Doom (R_InitLightTables), once for each wall
;;; segment, sprite and plane. The light number lightnum = (lightlevel >> 4)
;;; + extralight + gamma (0..15) gives startmap = (15 - lightnum) * 4, and
;;; the distance steps d give the colormap startmap - d (0..31):
;;;   d = min(47, scale >> 12) / 2 for a wall segment or a sprite at the
;;;   scale (16.16, the projection of PROJECTIONY) of its middle;
;;;   d = PLANE_D for a floor or a ceiling (the planes have one color);
;;;   the weapon: d = 23.
;;; The fixed colormap (invulnerability, light amplification) replaces all.
;;; Tables do the clamps: SMAP[lightnum + 16] = startmap + 24, and
;;; CMO[startmap + 24 - d] = the offset of the colormap in fullcolormap
;;; (PCMO: in FLATCM, the colors of the flats of the level).
;;; R_SetupFrame (src/iigs/r_frame65.s) sets LT_BASE and LT_FIXED.
;;;
;;; int16_t R_WallLight(int16_t lightlevel, drawseg_t* ds, angle_t normal)
;;;   In: C, X = the near address of the drawseg, Y = the normal angle of
;;;   the seg (the fake contrast: lightnum - 1 for a wall along x, + 1 along
;;;   y). Out: C = the offset of the colormap in fullcolormap (and in the

;;;   SHR colormaps) for a fixed effect, otherwise 0. Both callers select
;;;   endpoint/per-column distance lighting themselves, using LT_I.
;;; const uint8_t* R_SpriteColorMap(int16_t lightlevel, uint16_t scale >> 8)
;;;   In: C, X ($ffff: the weapon). Out: X:C.
;;; ---------------------------------------------------------------------------
              .section znear, bss
              .public LT_BASE, LT_FIXED, LT_I
LT_BASE:      .space  2               ; extralight + gamma + 16
LT_FIXED:     .space  2               ; the offset of fixedcolormap, -1: none
LT_I:         .space  2               ; lightnum + 16
LT_D:         .space  2               ; the distance steps of the light

              .section zfar, bss
              .public FLATCM
FLATCM:       .space  34 * 32         ; the plane colors of the level: [cm * 32 +
                                      ;   flat] = fullcolormap[cm * 256 + the
                                      ;   color of the flat] (I_SetLevelPalette)

              .section cfar, rodata
              .public SMAP, CMO
SMAP:
              .word   84, 84, 84, 84, 84, 84, 84, 84
              .word   84, 84, 84, 84, 84, 84, 84, 84
              .word   84, 80, 76, 72, 68, 64, 60, 56
              .word   52, 48, 44, 40, 36, 32, 28, 24
              .word   24, 24, 24, 24, 24, 24, 24, 24
              .word   24, 24, 24, 24, 24, 24, 24, 24
              .word   24, 24, 24, 24, 24, 24, 24, 24
              .word   24, 24, 24, 24, 24, 24, 24, 24
CMO:
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 256, 512, 768, 1024, 1280, 1536, 1792
              .word   2048, 2304, 2560, 2816, 3072, 3328, 3584, 3840
              .word   4096, 4352, 4608, 4864, 5120, 5376, 5632, 5888
              .word   6144, 6400, 6656, 6912, 7168, 7424, 7680, 7936
              .word   7936, 7936, 7936, 7936, 7936, 7936, 7936, 7936
              .word   7936, 7936, 7936, 7936, 7936, 7936, 7936, 7936
              .word   7936, 7936, 7936, 7936, 7936, 7936, 7936, 7936
              .word   7936, 7936, 7936, 7936, 7936
PCMO:
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 0, 0, 0, 0, 0, 0, 0
              .word   0, 32, 64, 96, 128, 160, 192, 224
              .word   256, 288, 320, 352, 384, 416, 448, 480
              .word   512, 544, 576, 608, 640, 672, 704, 736
              .word   768, 800, 832, 864, 896, 928, 960, 992
              .word   992, 992, 992, 992, 992, 992, 992, 992
              .word   992, 992, 992, 992, 992, 992, 992, 992
              .word   992, 992, 992, 992, 992, 992, 992, 992
              .word   992, 992, 992, 992, 992

              .section bspcode, text
              .public R_WallLight, R_SpriteColorMap
R_WallLight:  lsr     a
              lsr     a
              lsr     a
              lsr     a
              clc
              adc     .near LT_BASE
              sta     .near LT_I
              tya                           ; the fake contrast
              and     ##0x7fff
              beq     1$                    ; along y: +1
              cmp     ##0x4000
              bne     2$
              dec     .near LT_I            ; along x: -1
              bra     2$
1$:           inc     .near LT_I
2$:           lda     .near LT_FIXED
              bpl     9$
              ;; Both wall consumers choose their final colormap from the
              ;; endpoint/per-column scales. The old midpoint result is dead.
              ;; Use the valid full colormap until that choice; fixed effects
              ;; retain their exact offset. LT_I above remains authoritative.
              lda     ##0
9$:           rtl
              .space  53                    ; removed midpoint work; sprite entry stays

R_SpriteColorMap:
              pha
              lda     .near LT_FIXED
              bpl     2$
              txa                           ; d = min(47, scale >> 12) / 2
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              cmp     ##24
              bcc     1$
              lda     ##23
1$:           sta     .near LT_D
              lda     1,s                   ; the colormap startmap - d
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              clc
              adc     .near LT_BASE
              asl     a
              tax
              lda     long:SMAP,x
              sec
              sbc     .near LT_D
              asl     a
              tax
              lda     long:CMO,x
2$:           plx
              clc                           ; fullcolormap + the offset
              adc     ##.word0 fullcolormap
              tay
              lda     ##.word2 fullcolormap
              adc     ##0
              tax
              tya
              rtl

;;; The column (0-160) of each view angle (4096 fine angles) from 1032 to
;;; 3073; the angles below 1032 give 160, the angles from 3073 give 0
;;; (viewangletoxTable of r_draw.c, and 0 for 3073: the clipped angles
;;; are at most 3073).
              .section cnear, rodata
              .public viewangletoxTable
viewangletoxTable:
              .byte   159, 159, 159, 159, 159, 159, 159, 159, 158, 158, 158, 158, 158, 158, 158, 158
              .byte   157, 157, 157, 157, 157, 157, 157, 157, 157, 156, 156, 156, 156, 156, 156, 156
              .byte   156, 156, 155, 155, 155, 155, 155, 155, 155, 155, 154, 154, 154, 154, 154, 154
              .byte   154, 154, 154, 153, 153, 153, 153, 153, 153, 153, 153, 153, 152, 152, 152, 152
              .byte   152, 152, 152, 152, 152, 151, 151, 151, 151, 151, 151, 151, 151, 151, 150, 150
              .byte   150, 150, 150, 150, 150, 150, 150, 150, 149, 149, 149, 149, 149, 149, 149, 149
              .byte   149, 148, 148, 148, 148, 148, 148, 148, 148, 148, 148, 147, 147, 147, 147, 147
              .byte   147, 147, 147, 147, 146, 146, 146, 146, 146, 146, 146, 146, 146, 146, 145, 145
              .byte   145, 145, 145, 145, 145, 145, 145, 145, 144, 144, 144, 144, 144, 144, 144, 144
              .byte   144, 144, 143, 143, 143, 143, 143, 143, 143, 143, 143, 143, 142, 142, 142, 142
              .byte   142, 142, 142, 142, 142, 142, 141, 141, 141, 141, 141, 141, 141, 141, 141, 141
              .byte   141, 140, 140, 140, 140, 140, 140, 140, 140, 140, 140, 139, 139, 139, 139, 139
              .byte   139, 139, 139, 139, 139, 139, 138, 138, 138, 138, 138, 138, 138, 138, 138, 138
              .byte   137, 137, 137, 137, 137, 137, 137, 137, 137, 137, 137, 136, 136, 136, 136, 136
              .byte   136, 136, 136, 136, 136, 136, 135, 135, 135, 135, 135, 135, 135, 135, 135, 135
              .byte   135, 134, 134, 134, 134, 134, 134, 134, 134, 134, 134, 134, 134, 133, 133, 133
              .byte   133, 133, 133, 133, 133, 133, 133, 133, 132, 132, 132, 132, 132, 132, 132, 132
              .byte   132, 132, 132, 132, 131, 131, 131, 131, 131, 131, 131, 131, 131, 131, 131, 130
              .byte   130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 129, 129, 129, 129, 129
              .byte   129, 129, 129, 129, 129, 129, 129, 128, 128, 128, 128, 128, 128, 128, 128, 128
              .byte   128, 128, 128, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 126
              .byte   126, 126, 126, 126, 126, 126, 126, 126, 126, 126, 126, 126, 125, 125, 125, 125
              .byte   125, 125, 125, 125, 125, 125, 125, 125, 124, 124, 124, 124, 124, 124, 124, 124
              .byte   124, 124, 124, 124, 124, 123, 123, 123, 123, 123, 123, 123, 123, 123, 123, 123
              .byte   123, 122, 122, 122, 122, 122, 122, 122, 122, 122, 122, 122, 122, 122, 121, 121
              .byte   121, 121, 121, 121, 121, 121, 121, 121, 121, 121, 121, 120, 120, 120, 120, 120
              .byte   120, 120, 120, 120, 120, 120, 120, 120, 119, 119, 119, 119, 119, 119, 119, 119
              .byte   119, 119, 119, 119, 119, 118, 118, 118, 118, 118, 118, 118, 118, 118, 118, 118
              .byte   118, 118, 118, 117, 117, 117, 117, 117, 117, 117, 117, 117, 117, 117, 117, 117
              .byte   116, 116, 116, 116, 116, 116, 116, 116, 116, 116, 116, 116, 116, 116, 115, 115
              .byte   115, 115, 115, 115, 115, 115, 115, 115, 115, 115, 115, 115, 114, 114, 114, 114
              .byte   114, 114, 114, 114, 114, 114, 114, 114, 114, 114, 113, 113, 113, 113, 113, 113
              .byte   113, 113, 113, 113, 113, 113, 113, 113, 112, 112, 112, 112, 112, 112, 112, 112
              .byte   112, 112, 112, 112, 112, 112, 111, 111, 111, 111, 111, 111, 111, 111, 111, 111
              .byte   111, 111, 111, 111, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110
              .byte   110, 110, 109, 109, 109, 109, 109, 109, 109, 109, 109, 109, 109, 109, 109, 109
              .byte   109, 108, 108, 108, 108, 108, 108, 108, 108, 108, 108, 108, 108, 108, 108, 107
              .byte   107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 107, 106, 106
              .byte   106, 106, 106, 106, 106, 106, 106, 106, 106, 106, 106, 106, 106, 105, 105, 105
              .byte   105, 105, 105, 105, 105, 105, 105, 105, 105, 105, 105, 105, 104, 104, 104, 104
              .byte   104, 104, 104, 104, 104, 104, 104, 104, 104, 104, 104, 103, 103, 103, 103, 103
              .byte   103, 103, 103, 103, 103, 103, 103, 103, 103, 103, 102, 102, 102, 102, 102, 102
              .byte   102, 102, 102, 102, 102, 102, 102, 102, 102, 101, 101, 101, 101, 101, 101, 101
              .byte   101, 101, 101, 101, 101, 101, 101, 101, 100, 100, 100, 100, 100, 100, 100, 100
              .byte   100, 100, 100, 100, 100, 100, 100, 100, 99, 99, 99, 99, 99, 99, 99, 99
              .byte   99, 99, 99, 99, 99, 99, 99, 98, 98, 98, 98, 98, 98, 98, 98, 98
              .byte   98, 98, 98, 98, 98, 98, 98, 97, 97, 97, 97, 97, 97, 97, 97, 97
              .byte   97, 97, 97, 97, 97, 97, 96, 96, 96, 96, 96, 96, 96, 96, 96, 96
              .byte   96, 96, 96, 96, 96, 96, 95, 95, 95, 95, 95, 95, 95, 95, 95, 95
              .byte   95, 95, 95, 95, 95, 95, 94, 94, 94, 94, 94, 94, 94, 94, 94, 94
              .byte   94, 94, 94, 94, 94, 94, 93, 93, 93, 93, 93, 93, 93, 93, 93, 93
              .byte   93, 93, 93, 93, 93, 93, 92, 92, 92, 92, 92, 92, 92, 92, 92, 92
              .byte   92, 92, 92, 92, 92, 92, 91, 91, 91, 91, 91, 91, 91, 91, 91, 91
              .byte   91, 91, 91, 91, 91, 91, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90
              .byte   90, 90, 90, 90, 90, 90, 89, 89, 89, 89, 89, 89, 89, 89, 89, 89
              .byte   89, 89, 89, 89, 89, 89, 88, 88, 88, 88, 88, 88, 88, 88, 88, 88
              .byte   88, 88, 88, 88, 88, 88, 87, 87, 87, 87, 87, 87, 87, 87, 87, 87
              .byte   87, 87, 87, 87, 87, 87, 86, 86, 86, 86, 86, 86, 86, 86, 86, 86
              .byte   86, 86, 86, 86, 86, 86, 86, 85, 85, 85, 85, 85, 85, 85, 85, 85
              .byte   85, 85, 85, 85, 85, 85, 85, 84, 84, 84, 84, 84, 84, 84, 84, 84
              .byte   84, 84, 84, 84, 84, 84, 84, 83, 83, 83, 83, 83, 83, 83, 83, 83
              .byte   83, 83, 83, 83, 83, 83, 83, 82, 82, 82, 82, 82, 82, 82, 82, 82
              .byte   82, 82, 82, 82, 82, 82, 82, 82, 81, 81, 81, 81, 81, 81, 81, 81
              .byte   81, 81, 81, 81, 81, 81, 81, 81, 80, 80, 80, 80, 80, 80, 80, 80
              .byte   80, 80, 80, 80, 80, 80, 80, 80, 79, 79, 79, 79, 79, 79, 79, 79
              .byte   79, 79, 79, 79, 79, 79, 79, 79, 79, 78, 78, 78, 78, 78, 78, 78
              .byte   78, 78, 78, 78, 78, 78, 78, 78, 78, 77, 77, 77, 77, 77, 77, 77
              .byte   77, 77, 77, 77, 77, 77, 77, 77, 77, 76, 76, 76, 76, 76, 76, 76
              .byte   76, 76, 76, 76, 76, 76, 76, 76, 76, 75, 75, 75, 75, 75, 75, 75
              .byte   75, 75, 75, 75, 75, 75, 75, 75, 75, 75, 74, 74, 74, 74, 74, 74
              .byte   74, 74, 74, 74, 74, 74, 74, 74, 74, 74, 73, 73, 73, 73, 73, 73
              .byte   73, 73, 73, 73, 73, 73, 73, 73, 73, 73, 72, 72, 72, 72, 72, 72
              .byte   72, 72, 72, 72, 72, 72, 72, 72, 72, 72, 71, 71, 71, 71, 71, 71
              .byte   71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 70, 70, 70, 70, 70, 70
              .byte   70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 69, 69, 69, 69, 69, 69
              .byte   69, 69, 69, 69, 69, 69, 69, 69, 69, 69, 68, 68, 68, 68, 68, 68
              .byte   68, 68, 68, 68, 68, 68, 68, 68, 68, 68, 67, 67, 67, 67, 67, 67
              .byte   67, 67, 67, 67, 67, 67, 67, 67, 67, 67, 66, 66, 66, 66, 66, 66
              .byte   66, 66, 66, 66, 66, 66, 66, 66, 66, 66, 65, 65, 65, 65, 65, 65
              .byte   65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 64, 64, 64, 64, 64, 64
              .byte   64, 64, 64, 64, 64, 64, 64, 64, 64, 63, 63, 63, 63, 63, 63, 63
              .byte   63, 63, 63, 63, 63, 63, 63, 63, 63, 62, 62, 62, 62, 62, 62, 62
              .byte   62, 62, 62, 62, 62, 62, 62, 62, 61, 61, 61, 61, 61, 61, 61, 61
              .byte   61, 61, 61, 61, 61, 61, 61, 61, 60, 60, 60, 60, 60, 60, 60, 60
              .byte   60, 60, 60, 60, 60, 60, 60, 59, 59, 59, 59, 59, 59, 59, 59, 59
              .byte   59, 59, 59, 59, 59, 59, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58
              .byte   58, 58, 58, 58, 58, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57
              .byte   57, 57, 57, 57, 56, 56, 56, 56, 56, 56, 56, 56, 56, 56, 56, 56
              .byte   56, 56, 56, 55, 55, 55, 55, 55, 55, 55, 55, 55, 55, 55, 55, 55
              .byte   55, 55, 54, 54, 54, 54, 54, 54, 54, 54, 54, 54, 54, 54, 54, 54
              .byte   54, 53, 53, 53, 53, 53, 53, 53, 53, 53, 53, 53, 53, 53, 53, 52
              .byte   52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 51, 51
              .byte   51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 50, 50, 50, 50
              .byte   50, 50, 50, 50, 50, 50, 50, 50, 50, 50, 49, 49, 49, 49, 49, 49
              .byte   49, 49, 49, 49, 49, 49, 49, 49, 48, 48, 48, 48, 48, 48, 48, 48
              .byte   48, 48, 48, 48, 48, 48, 47, 47, 47, 47, 47, 47, 47, 47, 47, 47
              .byte   47, 47, 47, 47, 46, 46, 46, 46, 46, 46, 46, 46, 46, 46, 46, 46
              .byte   46, 46, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45
              .byte   44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 43, 43, 43
              .byte   43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 42, 42, 42, 42, 42
              .byte   42, 42, 42, 42, 42, 42, 42, 42, 41, 41, 41, 41, 41, 41, 41, 41
              .byte   41, 41, 41, 41, 41, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40
              .byte   40, 40, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 38
              .byte   38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 37, 37, 37, 37, 37
              .byte   37, 37, 37, 37, 37, 37, 37, 37, 36, 36, 36, 36, 36, 36, 36, 36
              .byte   36, 36, 36, 36, 35, 35, 35, 35, 35, 35, 35, 35, 35, 35, 35, 35
              .byte   35, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 33, 33, 33
              .byte   33, 33, 33, 33, 33, 33, 33, 33, 33, 32, 32, 32, 32, 32, 32, 32
              .byte   32, 32, 32, 32, 32, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31
              .byte   31, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 29, 29, 29, 29
              .byte   29, 29, 29, 29, 29, 29, 29, 29, 28, 28, 28, 28, 28, 28, 28, 28
              .byte   28, 28, 28, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 26
              .byte   26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 25, 25, 25, 25, 25, 25
              .byte   25, 25, 25, 25, 25, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24
              .byte   23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 22, 22, 22, 22, 22, 22
              .byte   22, 22, 22, 22, 22, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 20
              .byte   20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 19, 19, 19, 19, 19, 19
              .byte   19, 19, 19, 19, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 17, 17
              .byte   17, 17, 17, 17, 17, 17, 17, 17, 16, 16, 16, 16, 16, 16, 16, 16
              .byte   16, 16, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 14, 14, 14, 14
              .byte   14, 14, 14, 14, 14, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 12
              .byte   12, 12, 12, 12, 12, 12, 12, 12, 11, 11, 11, 11, 11, 11, 11, 11
              .byte   11, 11, 10, 10, 10, 10, 10, 10, 10, 10, 10, 9, 9, 9, 9, 9
              .byte   9, 9, 9, 9, 8, 8, 8, 8, 8, 8, 8, 8, 8, 7, 7, 7
              .byte   7, 7, 7, 7, 7, 7, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5
              .byte   5, 5, 5, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4, 4, 4
              .byte   3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2
              .byte   1, 1, 1, 1, 1, 1, 1, 1, 1
              .byte   0

;;; c14Bounds: conservative log intervals avoid two shiftMul calls when
;;; their comparison is unambiguous. Enter after the product-sign shortcut;
;;; X is node*4.
;;; For |dx|,|dy| <=255 the signed 24x8 products cannot overflow int32.
;;; With i=abs(integer relative coordinate)>=16, its true magnitude in
;;; map units lies between i-1 and i+1, including the discarded 8 bits.
;;; Each log interval is within 191 units (log2 scaled by 2048). The two
;;; rounding errors plus SIGHTLOG's masked low nibble add at most 17. Thus
;;; |observed log difference| > 416 fixes the sign; closer cases fall back
;;; to the products, preserving the partition-side decision.
              .section core14, text
c14Bounds:    ldy     ##OFS_NODE_DX
              lda     [.tiny ND],y
              clc
              adc     ##255
              cmp     ##511                ; -255..255, nonzero from the caller
              bcc     c14SmallX
c14Miss:      lda     .near viewx           ; the replaced original instructions
              sta     .near BS_XP
              rtl
c14SmallX:    ldy     ##OFS_NODE_DY
              lda     [.tiny ND],y
              clc
              adc     ##255
              cmp     ##511
              bcs     c14Miss
              lda     long:(CORE_NODEADR+2),x
              and     ##0xfff0              ; signed floor of log|dx|-log|dy|
              sta     .near BS_L
              lda     .near (BS_XP+2)
              bpl     c14AbsX
              eor     ##0xffff
              inc     a
              bmi     c14Miss               ; -32768: do not index its wrap
c14AbsX:      cmp     ##16
              bcc     c14Miss
              asl     a
              tax
              lda     long:MM_LOGTAB,x
              sta     .near (BS_L+2)
              lda     .near (BS_YP+2)
              bpl     c14AbsY
              eor     ##0xffff
              inc     a
              bmi     c14Miss
c14AbsY:      cmp     ##16
              bcc     c14Miss
              asl     a
              tax
              lda     long:MM_LOGTAB,x
              sec
              sbc     .near (BS_L+2)
              clc
              adc     .near BS_L
              bvs     c14Overflow           ; genuine magnitude beyond int16
              bmi     c14Negative
              cmp     ##417
              bcs     c14Greater
              bra     c14Miss
c14Negative:  cmp     ##(65536-416)
              bcc     c14Less
              bra     c14Miss
c14Overflow:  bmi     c14Greater            ; positive overflow wrapped negative
              bra     c14Less
c14Greater:   ldy     ##OFS_NODE_DY          ; |L|>|R|: L>=R iff both positive
              lda     [.tiny ND],y
              eor     .near (BS_XP+2)
              eor     ##0x8000
              bra     c14Return
c14Less:      ldy     ##OFS_NODE_DY          ; |L|<|R|: L>=R iff both negative
              lda     [.tiny ND],y
              eor     .near (BS_XP+2)
c14Return:    asl     a                     ; carry is the exact original side
              lda     ##.word0 (c14SideDone-1)
              sta     1,s                   ; return to original viewSide RTS
              rtl
