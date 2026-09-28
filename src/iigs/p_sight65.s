;;; Line of sight checks in 65816 assembly.
;;;
;;; P_CheckSight, P_CrossBSPNode, P_CrossSubsector and P_DivlineSide of
;;; p_sight.c, with the same results. P_CheckSight sets up los and walks
;;; the tree. The side tests multiply the whole parts of the coordinates,
;;; which always fit in 16 bits.
;;;
;;; A check runs cold in the cache (other code runs between two checks),
;;; so it costs about a bus read for each byte of code that it runs, and
;;; a write stalls on the next miss: the code is small, the walk keeps its
;;; waiting nodes on the stack instead of calls, one side test (sideTest)
;;; serves the nodes, the lines and the line of sight with the values in
;;; registers, the walk reads the nodes, lines and sectors where they are
;;; (tables of bank 3F give their addresses), and the stores are bytes.
;;;
;;; Address arithmetic assumes sizes 8 (subsector_t), 18 (seg_t),
;;; 28 (mapnode_t), 36 (line_t) and 58 (sector_t). Keep these strides
;;; consistent with the layouts and SIZEOF_* constants in offsets.inc.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"

              .extern sqmFlood
              .extern _Dp, _Mul32, FixedReciprocalSmall, IIGS_MulLo16
              .extern nodes, numnodes, validcount, _g_numlines
              .extern _g_subsectors, _g_segs, _g_lines, _g_sectors
              .extern numsubsectors, _g_numsectors, _g_rejectmatrix
              .extern MA, MB, MR, umul16, I_Error, _g_sides, _UDivMod16
              .extern DC_TF, DC_TI, DC_TMID7, DC_FLATW, DC_SRC, DC_CMB, DC_COUNT

              .section ztiny, bss
PS_P:         .space  4               ; the divline of nodeSide: a node or a line
PS_SEG:       .space  4               ; the current seg
LOGP:         .space  4               ; LOGTAB, for sideTest (P_InitSightLogs)

;;; Direct page: inputs of the column drawers (tools/gendraw.py), free in
;;; a game tic (TH_P and SM_P of src/iigs/p_tick65.s are free while a
;;; thinker runs).
QK            .equ    DC_TF           ; K of the divline of sideTest
SS            .equ    DC_TMID7        ; a side (its high byte 0 in the walk)
ST            .equ    DC_FLATW
FS            .equ    DC_SRC          ; the front sector of a two sided seg
BS            .equ    DC_CMB          ;   and its back sector
SC            .equ    DC_COUNT        ; the segs left in the subsector (byte)
SVEC          .equ    DC_TI           ; the side passes: where they end (a word)

              .section znear, bss
              .public los
los:          .space  SIZEOF_LOS      ; los_t of p_sight.c
DLN:          .space  8               ; a line as a divline: x, y, dx, dy
NX            .equ    DLN             ;   (whole units, interceptFrac)
NY            .equ    (DLN+2)
NDX           .equ    (DLN+4)
NDY           .equ    (DLN+6)
PS_OPENTOP:   .space  4
PS_OPENBOT:   .space  4
PS_FRAC:      .space  2
LS_XL:        .space  2               ; the box of the line of sight in whole
LS_XH:        .space  2               ;   units, + 0x8000 (lineBox): x, then
LS_YL:        .space  2               ;   y 4 bytes on; L the ceil of the
LS_YH:        .space  2               ;   lower end, H the whole part of the higher
KS:           .space  2               ; K of the line of sight (lineSideS)
FAKESEG:      .space  SIZEOF_SEG      ; the line of the sightline test
SL_N:         .space  2               ; P_InitSightLogs: count, table offset,
SL_X:         .space  2               ;   the low bits of K, a log
SL_B:         .space  2
SL_T:         .space  2
              .public sightblocker
sightblocker: .space  2               ; linenum + 1 of the one sided line that
                                      ; stopped P_CrossBSPNode, 0: none
TWOBLOCKER:   .space  2               ; the same for a two sided line (SIGHTHINT)
QR:           .space  4               ; right, for the exact side test

;;; The sight tables of the map (P_InitSightTables): a word for each
;;; subsector, the REJECT row of its sector (sector * numsectors) and its
;;; sector; for each subsector its first seg (the low word of its address)
;;; and their count (a byte); the address of each sector (the low word).
;;; Bank 3F (src/iigs/iigs.scm), with SIGHTLOG and LINELOG, BMROW and LN36
;;; (src/iigs/p_map65.s).
SS_SEGT       .equ    (MM_B3F + 0x2000)
SS_ROW        .equ    (MM_B3F + 0x4000)
SS_SEC        .equ    (MM_B3F + 0x5000)
SEC58         .equ    (MM_B3F + 0xa000)
LNSEC         .equ    (MM_B3F + 0xc000) ; the sectors of each line (src/iigs/p_map65.s)

;;; SIGHTHINT: for each mobj (a word at (its address >> 2) & 0x7ffe, 32 KB,
;;; bank 4A) linenum + 1 of the two sided line that stopped its last check,
;;; else 0. The walk tries it first when t1 has no sightline: a line that
;;; crosses the line of sight and blocks it gives false in any order of the
;;; lines, as the slopes only narrow. Another mobj at a near address, or a
;;; line of an old map, only costs that test (a line number is checked).
SIGHTHINT     .equ    MM_SIGHTHINT
SS_MAX        .equ    0x800           ; the subsectors that fit
SEC_MAX       .equ    0x100           ; the sectors (a seg keeps a byte)

;;; For each node (node * 4) the low word of its address and its K; for
;;; each line (line * 2) its K (P_InitSightLogs), for the side tests
;;; (sideTest). The lines come from LN36 of src/iigs/p_map65.s.
SIGHTLOG      .equ    MM_B3F
LINELOG       .equ    (MM_B3F + 0x8000)
NODE_MAX      .equ    0x800
LN36          .equ    (MM_B3F + 0x6200)

LOS_STRACE    .equ    (los + OFS_LOS_STRACE)

;;; C = log2(|C|) * 2048, C != 0 (build/tables/log.bin).
LOGTAB        .equ    MM_LOGTAB

;;; Copy a 32-bit value.
MOVE32        .macro  src, dst
              lda     .near \src
              sta     .near \dst
              lda     .near (\src + 2)
              sta     .near (\dst + 2)
              .endm


;;; ---------------------------------------------------------------------------
;;; boolean P_CheckSight(mobj_t __far* t1, mobj_t __far* t2)
;;; In: _Dp[0-3] = t1, _Dp[4-7] = t2. Out: C.
;;; P_CheckSight of p_sight.c: the answer of the last pair again,
;;; REJECT, the same subsector, then the walk of P_CrossBSPNode, which
;;; first takes the one sided line that stopped the last check of t1, else
;;; the two sided one (SIGHTHINT).
;;; The answers are 0 or 1: CS_PREVR and CS_Z keep their high bytes 0.
;;; ---------------------------------------------------------------------------
              .section znear, bss
CS_PREV1:     .space  4               ; the pair of the last call
CS_PREV2:     .space  4
CS_PREVR:     .space  2               ; its answer
CS_T:         .space  4
CS_Z:         .space  2               ; 1: the heights of los are set (zSetup)

              .section code, text
              .public P_CheckSight
P_CheckSight:
              ldx     ##6                   ; the same pair as the last call:
1$:           lda     dp:.tiny _Dp,x        ;   its answer
              cmp     .near CS_PREV1,x
              bne     2$
              dex
              dex
              bpl     1$
              lda     .near CS_PREVR
              rtl
2$:           ldx     ##6                   ; the pair (words: no SEP and REP)
3$:           lda     dp:.tiny _Dp,x
              sta     .near CS_PREV1,x
              dex
              dex
              bpl     3$

              ;; REJECT bit s1 * numsectors + s2 of the sectors of t1 and t2
              ldy     ##OFS_MO_SUBSECTOR
              lda     [.tiny (_Dp+4)],y     ; X: t2 (2 * its subsector)
              sec
              sbc     .near _g_subsectors
              lsr     a
              lsr     a
              tax
              lda     [.tiny _Dp],y         ; Y: t1
              sec
              sbc     .near _g_subsectors
              lsr     a
              lsr     a
              tay
              lda     long:SS_SEC,x         ; the sector of t2
              tyx
              clc
              adc     long:SS_ROW,x         ; + the row of the sector of t1
              tax                           ; (the bit)
              lsr     a
              lsr     a
              lsr     a
              clc                           ; Y = its byte in the bank of the
              adc     .near _g_rejectmatrix ;   matrix (DBR for the read)
              tay
              txa
              and     ##7
              tax
              phb                           ; (16-bit A: the bank as the high byte,
              lda     .near (_g_rejectmatrix+1) ;   the bit in the low byte)
              pha
              plb
              plb
              lda     abs:0,y
              plb
              and     long:bitTab,x
              and     ##0x00ff
              beq     4$
              stz     .near CS_PREVR        ; cannot be connected
              lda     ##0
              rtl

              ;; the same subsector: visible
4$:           ldy     ##OFS_MO_SUBSECTOR
              lda     [.tiny _Dp],y
              cmp     [.tiny (_Dp+4)],y
              bne     5$
              iny
              iny
              lda     [.tiny _Dp],y
              cmp     [.tiny (_Dp+4)],y
              bne     5$
              lda     ##1
              sta     .near CS_PREVR
              rtl
              .space  39                    ; (the code after keeps its address)

5$:           inc     .near validcount      ; validcount++

              ;; strace from t1 to t2: strace.x, y = t1->x, y and t2x, t2y =
              ;; t2->x, y; strace.dx, dy = t2x - strace.x, t2y - strace.y
              ldx     ##6
              ldy     ##(OFS_MO_X+6)
7$:           lda     [.tiny _Dp],y
              sta     .near LOS_STRACE,x
              lda     [.tiny (_Dp+4)],y
              sta     .near (los+OFS_LOS_T2X),x
              dey
              dey
              dex
              dex
              bpl     7$
              lda     .near (los+OFS_LOS_T2X)
              sec
              sbc     .near LOS_STRACE
              sta     .near (LOS_STRACE+OFS_DL_DX)
              lda     .near (los+OFS_LOS_T2X+2)
              sbc     .near (LOS_STRACE+2)
              sta     .near (LOS_STRACE+OFS_DL_DX+2)
              lda     .near (los+OFS_LOS_T2X+4)
              sec
              sbc     .near (LOS_STRACE+4)
              sta     .near (LOS_STRACE+OFS_DL_DX+4)
              lda     .near (los+OFS_LOS_T2X+6)
              sbc     .near (LOS_STRACE+6)
              sta     .near (LOS_STRACE+OFS_DL_DX+6)

              ;; the box of the line of sight for lineBox: for y, then x,
              ;; the whole part of the higher end (t1 when t2 < t1, else
              ;; t2: Y = X + 8 or X from t2x) and the ceil of the lower end
              ;; (things are inside the map: x < 32767)
              ldx     ##4
10$:          lda     .near (los+OFS_LOS_T2X),x
              cmp     .near LOS_STRACE,x
              lda     .near (los+OFS_LOS_T2X+2),x
              sbc     .near (LOS_STRACE+2),x
              bvc     11$
              eor     ##0x8000
11$:          asl     a                     ; (C: t2 < t1)
              txa
              bcc     12$
              adc     ##(OFS_LOS_STRACE - OFS_LOS_T2X - 1)
12$:          tay
              lda     .near (los+OFS_LOS_T2X+2),y
              eor     ##0x8000
              sta     .near LS_XH,x
              tya                           ; the other end
              eor     ##(OFS_LOS_STRACE - OFS_LOS_T2X)
              tay
              lda     .near (los+OFS_LOS_T2X),y
              cmp     ##1                   ; (C: a fraction)
              lda     .near (los+OFS_LOS_T2X+2),y
              adc     ##0x8000
              sta     .near LS_XL,x
              dex
              dex
              dex
              dex
              bpl     10$

              ;; KS = K of the line of sight: log |s.dx >> 16| -
              ;; log |s.dy >> 16| (0 when one is 0: not used), bit 0 s.dx < 0,
              ;; bit 1 s.dy < 0 (bits 2-3: 0, see P_InitSightLogs)
              lda     .near (LOS_STRACE+OFS_DL_DY+2)
              beq     15$
              bpl     13$
              eor     ##0xffff
              inc     a
13$:          asl     a                     ; (|C| = 32768: 0)
              tax
              lda     .near (LOS_STRACE+OFS_DL_DX+2)
              beq     15$
              bpl     14$
              eor     ##0xffff
              inc     a
14$:          asl     a
              tay
              lda     [.tiny LOGP],y
              sec
              sbc     long:LOGTAB,x
              and     ##0xfff0
15$:          ldx     .near (LOS_STRACE+OFS_DL_DX+2)
              bpl     16$
              ora     ##1
16$:          ldx     .near (LOS_STRACE+OFS_DL_DY+2)
              bpl     17$
              ora     ##2
17$:          sta     .near KS              ; (words: no SEP and REP)

              ;; the walk of P_CrossBSPNode(numnodes - 1): the far children
              ;; wait on the stack over 0x7fff (not a child). First the one
              ;; sided line that stopped the last check of t1, else the two
              ;; sided one (SIGHTHINT), as a subsector of one seg (FAKESEG,
              ;; with the sectors of the line from LNSEC).
              stz     .near sightblocker
              stz     .near TWOBLOCKER
              lda     .near (_g_sectors+2)  ; the bank of the sectors
              sta     dp:.tiny (FS+2)
              sta     dp:.tiny (BS+2)
              lda     .near (nodes+2)       ; the bank of the nodes
              stz     .near CS_Z
              sta     dp:.tiny (PS_P+2)
              lda     ##.word0 nodeDone     ; the node loop (SVEC)
              sta     dp:.tiny SVEC
              pea     #0x7fff
              lda     .near numnodes        ; the root
              dec     a
              ldy     ##OFS_MO_SIGHTLINE
              tax
              lda     [.tiny _Dp],y
              bne     19$
              jsr     .kbank hintOf         ; else SIGHTHINT, a line of this
              lda     long:SIGHTHINT,x      ;   map
              beq     18$
              dec     a
              cmp     .near _g_numlines
              inc     a
              bcc     19$
18$:          ldx     .near numnodes
              dex
              bra     20$
19$:          ldx     .near numnodes
              dex
              phx                           ; the tree waits
              dec     a
              asl     a
              tax
              lsr     a
              sta     .near (FAKESEG+OFS_SEG_LINENUM) ; (words: no SEP and REP; the
              lda     long:LNSEC,x          ;   front and back sectors are its
              sta     .near (FAKESEG+OFS_SEG_FRONTSECTORNUM) ;   bytes 16, 17)
              lda     ##.word0 FAKESEG
              sta     dp:.tiny PS_SEG
              lda     ##.byte2 FAKESEG
              sta     dp:.tiny (PS_SEG+2)
              lda     ##1
              sta     dp:.tiny SC
              brl     segBank
              .space  14                    ; (the code after keeps its address)
20$:          txa

;;; nodeLoop: A = bspnum. A node: the sides of the start and the end of
;;; the line of sight (nodeSide, then nodeDone); on the same side the child
;;; there, else the child on the side of the start while the other one
;;; waits.
nodeLoop:     bit     ##CONST_NF_SUBSECTOR
              beq     1$
              brl     subsector
1$:           asl     a                     ; the node: its address (PS_P), K
              asl     a                     ;   (words: no SEP and REP)
              tax
              lda     long:SIGHTLOG,x
              sta     dp:.tiny PS_P
              lda     long:(SIGHTLOG+2),x
              sta     dp:.tiny QK
              lda     ##0x8000              ; SS: the first point (bit 15)
              sta     dp:.tiny SS
              ldx     ##.near LOS_STRACE    ; side = P_DivlineSide(strace.x,
              ldy     ##OFS_NODE_DX         ;   strace.y, node) (nodeDone)
              brl     nodeSide
              .space  15                    ; (the code after keeps its address)

;;; P_CrossSubsector(bspnum == -1 ? 0 : bspnum & ~NF_SUBSECTOR): its segs
;;; (SS_SEGT), PS_P their lines.
subsector:    cmp     ##0xffff
              bne     1$
              lda     ##0
1$:           asl     a                     ; (NF_SUBSECTOR goes out)
              asl     a
              tax
              lda     long:SS_SEGT,x        ; its segs and their count (words: no
              sta     dp:.tiny PS_SEG       ;   SEP and REP)
              lda     long:(SS_SEGT+2),x
              and     ##0x00ff
              sta     dp:.tiny SC
              lda     .near (_g_segs+2)
              sta     dp:.tiny (PS_SEG+2)
segBank:      lda     .near (_g_lines+2)
              sta     dp:.tiny (PS_P+2)
              bra     segTop
              .space  5                     ; (the code after keeps its address)

              ;; crossed: the nodes again, the next waiting child
subDone:      lda     .near (nodes+2)
              sta     dp:.tiny (PS_P+2)
              lda     ##.word0 nodeDone     ; the node loop again
              sta     dp:.tiny SVEC
              pla
              cmp     ##0x7fff
              beq     1$
              brl     nodeLoop
1$:           lda     ##1                   ; seen
              bra     walkEnd
              .space  5                     ; (the code after keeps its address)
blocked:      pla                           ; blocked: the waiting children go
              cmp     ##0x7fff
              bne     blocked
              lda     ##0
              ;; CS_PREVR = seen, t1->sightline = sightblocker (0 when seen;
              ;; after zSetup _Dp was reused: t1 again)
walkEnd:      sta     .near CS_PREVR        ; (words: no SEP and REP)
              lda     .near CS_Z
              beq     1$
              lda     .near (CS_PREV1+1)    ; t1 again, bytes 0-2 (_Dp was reused)
              sta     dp:.tiny (_Dp+1)
              lda     .near CS_PREV1
              sta     dp:.tiny _Dp
1$:           ldy     ##OFS_MO_SIGHTLINE
              lda     .near sightblocker
              sta     [.tiny _Dp],y
              jsr     .kbank hintOf         ; SIGHTHINT of t1 = TWOBLOCKER
              lda     .near TWOBLOCKER
              sta     long:SIGHTHINT,x
              lda     .near CS_PREVR
              rtl
              .space  26                    ; (the code after keeps its address)

nextSeg:      lda     dp:.tiny PS_SEG       ; seg++ (a word: no SEP and REP)
              clc
              adc     ##SIZEOF_SEG
              sta     dp:.tiny PS_SEG
segTop:       lda     dp:.tiny SC           ; for (count = numlines; count--; )
              beq     subDone
              dec     dp:.tiny SC
              ;; line = &_g_lines[seg->linenum]: PS_P; checked already on
              ;; its other side? (the stamp: a word)
              ldy     ##OFS_SEG_LINENUM
              lda     [.tiny PS_SEG],y
              asl     a
              tax
              lda     long:LN36,x
              sta     dp:.tiny PS_P
              ldy     ##OFS_LINE_VALIDCOUNT
              lda     [.tiny PS_P],y
              cmp     .near validcount
              beq     nextSeg
              lda     .near validcount
              sta     [.tiny PS_P],y
              ;; its box misses the box of the line of sight: left > LS_XH,
              ;; right < LS_XL, bottom > LS_YH or top < LS_YL (+ 0x8000)
              ldy     ##(OFS_LINE_BBOX + 2 * CONST_BOXLEFT)
              lda     [.tiny PS_P],y
              eor     ##0x8000
              cmp     .near LS_XH
              beq     2$
              bcs     nextSeg
2$:           ldy     ##(OFS_LINE_BBOX + 2 * CONST_BOXRIGHT)
              lda     [.tiny PS_P],y
              eor     ##0x8000
              cmp     .near LS_XL
              bcc     nextSeg
              ldy     ##(OFS_LINE_BBOX + 2 * CONST_BOXBOTTOM)
              lda     [.tiny PS_P],y
              eor     ##0x8000
              cmp     .near LS_YH
              beq     3$
              bcs     nextSeg
3$:           ldy     ##(OFS_LINE_BBOX + 2 * CONST_BOXTOP)
              lda     [.tiny PS_P],y
              eor     ##0x8000
              cmp     .near LS_YL
              bcc     9$

              ;; two sided: no wall to block sight with (the same floor and
              ;; ceiling heights of FS and BS, the sectors of the seg)?
              ldy     ##OFS_LINE_FLAGS
              lda     [.tiny PS_P],y
              and     ##CONST_ML_TWOSIDED
              beq     sides
              ldy     ##OFS_SEG_FRONTSECTORNUM
              lda     [.tiny PS_SEG],y      ; FS, BS: words, no SEP and REP
              and     ##0x00ff
              asl     a
              tax
              lda     long:SEC58,x
              sta     dp:.tiny FS
              iny                           ; OFS_SEG_BACKSECTORNUM
              lda     [.tiny PS_SEG],y
              and     ##0x00ff
              asl     a
              tax
              lda     long:SEC58,x
              sta     dp:.tiny BS
              ldy     ##OFS_SEC_FLOORHEIGHT ; the floor, then the ceiling
4$:           lda     [.tiny FS],y
              cmp     [.tiny BS],y
              bne     sides
              iny
              iny
              cpy     ##(OFS_SEC_CEILINGHEIGHT+4)
              bne     4$
9$:           brl     nextSeg
              .space  51                    ; (the code after keeps its address)

              ;; forget this line if it doesn't cross the line of sight:
              ;; the ends of the line of sight on the two sides of the line
              ;; (a divline, its K from LINELOG), and the ends of the line
              ;; on the two sides of the line of sight (KS)
sides:        ldy     ##OFS_SEG_LINENUM
              lda     [.tiny PS_SEG],y
              asl     a
              tax
              lda     long:LINELOG,x        ; QK, SVEC, SS: the line as a divline,
              sta     dp:.tiny QK           ;   the first point (words, no SEP and
              lda     ##.word0 lineDone     ;   REP)
              sta     dp:.tiny SVEC
              lda     ##0x8000
              sta     dp:.tiny SS
              ldx     ##.near LOS_STRACE    ; P_DivlineSide(strace.x, strace.y,
              ldy     ##OFS_LINE_DX         ;   line) (lineDone)
              brl     nodeSide
              .space  16                    ; (the code after keeps its address)
              ;; crossed: blocked by a one sided line (P_CheckSight keeps
              ;; linenum + 1)
crossed:      ldy     ##OFS_LINE_FLAGS
              lda     [.tiny PS_P],y
              and     ##CONST_ML_TWOSIDED
              bne     twoSided
              ldy     ##OFS_SEG_LINENUM
              lda     [.tiny PS_SEG],y
              inc     a
              sta     .near sightblocker    ; (a word)
              brl     blocked
              .space  8                     ; (the code after keeps its address)

              ;; crosses a two sided line: blocked when the opening is
              ;; closed (openbottom >= opentop); else the slopes narrow to
              ;; its bottom and top where the floors or the ceilings differ,
              ;; blocked when topslope <= bottomslope
twoSided:     jsr     .kbank opening
              lda     .near PS_OPENBOT
              cmp     .near PS_OPENTOP
              lda     .near (PS_OPENBOT+2)
              sbc     .near (PS_OPENTOP+2)
              bvc     1$
              eor     ##0x8000
1$:           bmi     2$
              brl     keepTwo
2$:           lda     .near CS_Z            ; the heights of los, the first time
              bne     3$
              jsr     .kbank zSetup
3$:           jsl     long:interceptFrac    ; PS_FRAC
              ldy     ##OFS_SEC_FLOORHEIGHT ; front->floorheight != back->floorheight
              jsr     .kbank sameHeight
              beq     5$
              lda     .near PS_OPENBOT      ; slope > bottomslope: bottomslope = slope
              ldx     .near (PS_OPENBOT+2)
              jsl     long:sightSlope
              tay
              cmp     .near (los+OFS_LOS_BOTTOMSLOPE)
              txa
              sbc     .near (los+OFS_LOS_BOTTOMSLOPE+2)
              bvc     4$
              eor     ##0x8000
4$:           bmi     5$
              txa
              tyx
              ldy     ##.near (los+OFS_LOS_BOTTOMSLOPE)
              jsr     .kbank st32
5$:           ldy     ##OFS_SEC_CEILINGHEIGHT ; front->ceilingheight != back->ceilingheight
              jsr     .kbank sameHeight
              beq     7$
              lda     .near PS_OPENTOP      ; slope < topslope: topslope = slope
              ldx     .near (PS_OPENTOP+2)
              jsl     long:sightSlope
              tay
              cmp     .near (los+OFS_LOS_TOPSLOPE)
              txa
              sbc     .near (los+OFS_LOS_TOPSLOPE+2)
              bvc     6$
              eor     ##0x8000
6$:           bpl     7$
              txa
              tyx
              ldy     ##.near (los+OFS_LOS_TOPSLOPE)
              jsr     .kbank st32
7$:           lda     .near (los+OFS_LOS_BOTTOMSLOPE) ; topslope <= bottomslope
              cmp     .near (los+OFS_LOS_TOPSLOPE)
              lda     .near (los+OFS_LOS_BOTTOMSLOPE+2)
              sbc     .near (los+OFS_LOS_TOPSLOPE+2)
              bvc     8$
              eor     ##0x8000
8$:           bmi     9$
              brl     keepTwo
9$:           brl     nextSeg

              ;; keepTwo: blocked by the two sided line: linenum + 1 for
              ;; SIGHTHINT
keepTwo:      ldy     ##OFS_SEG_LINENUM
              lda     [.tiny PS_SEG],y
              inc     a
              sta     .near TWOBLOCKER      ; (a word)
              brl     blocked
              .space  8                     ; (the code after keeps its address)

;;; hintOf: X = the offset of the SIGHTHINT word of t1 (_Dp[0-2]):
;;; (address >> 2) & 0x7ffe, bit 14 from the bank. 16-bit A.
hintOf:       lda     dp:.tiny (_Dp+2)      ; C = bit 0 of the bank
              lsr     a
              lda     dp:.tiny _Dp
              ror     a
              lsr     a
              and     ##0x7ffe
              tax
              rts

;;; ---------------------------------------------------------------------------
;;; nodeSide: A = P_DivlineSide(the point at near X, the divline [PS_P]):
;;; 0 front, 1 back, 2 on. The point x, y are fixed_t; the divline x, y
;;; at 0, 2 and dx, dy at Y, Y + 2 (a node: Y = 4, a line: Y = 8) are
;;; whole units, so its fixed point values reduce to the high words of the
;;; point:
;;;   !dx ? x == dl.x ? 2 : x <= dl.x ? dy > 0 : dy < 0 :
;;;   !dy ? y == dl.y ? 2 : y <= dl.y ? dx < 0 : dx > 0 :
;;;   sideTest with QA = y.hi - dl.y, QC = x.hi - dl.x
;;; ---------------------------------------------------------------------------
nodeSide:     lda     [.tiny PS_P],y        ; dx
              beq     10$
              iny
              iny
              lda     [.tiny PS_P],y        ; dy
              beq     20$
              ldy     ##2                   ; QA
              lda     abs:6,x
              sec
              sbc     [.tiny PS_P],y
              tay
              lda     abs:2,x               ; QC
              sec
              sbc     [.tiny PS_P]
              tax
              bra     sideTest

              ;; dx == 0
10$:          iny                           ; (dy)
              iny
              lda     abs:2,x
              sec
              sbc     [.tiny PS_P]
              beq     12$                   ; the same whole part
              bvc     11$
              eor     ##0x8000
11$:          bpl     14$                   ; x > dl.x
              bra     13$
12$:          lda     abs:0,x
              bne     14$                   ; x > dl.x
              lda     ##2
              jmp     (abs:SVEC)
13$:          lda     [.tiny PS_P],y        ; x < dl.x: dy > 0
              bmi     90$
              bne     91$
              bra     90$
14$:          lda     [.tiny PS_P],y        ; x > dl.x: dy < 0
              bmi     91$
90$:          lda     ##0
              jmp     (abs:SVEC)
91$:          lda     ##1
              jmp     (abs:SVEC)

              ;; dy == 0 (dx != 0: its sign is bit 0 of QK)
20$:          ldy     ##2
              lda     abs:6,x
              sec
              sbc     [.tiny PS_P],y
              beq     22$                   ; the same whole part
              bvc     21$
              eor     ##0x8000
21$:          bpl     24$                   ; y > dl.y
23$:          lda     dp:.tiny QK           ; y < dl.y: dx < 0
              and     ##1
              jmp     (abs:SVEC)
22$:          lda     abs:4,x
              beq     25$
24$:          lda     dp:.tiny QK           ; y > dl.y: dx > 0
              and     ##1
              eor     ##1
              jmp     (abs:SVEC)
25$:          lda     ##2
              jmp     (abs:SVEC)

;;; ---------------------------------------------------------------------------
;;; sideTest: A = 0 if right < left, 2 if they are equal, else 1, for
;;; right = QA * QB and left = QC * QD (signed 16 x 16). In: Y = QA,
;;; X = QC; QK = K of the divline (QB, QD not 0, see P_InitSightLogs).
;;; The signs decide first; for the same sign M = log |QA| - log |QC| + K
;;; decides when it is 18 or more away from 0 (the four log entries are
;;; off by 1/2 each, K by 15 more), else the products.
;;; ---------------------------------------------------------------------------
sideTest:     lda     dp:.tiny QK           ; C = QB < 0
              lsr     a
              tya                           ; right = 0: left decides
              beq     20$
              bcc     1$                    ; V = right < 0: the sign of QA,
              eor     ##0xffff              ;   the other one for QB < 0
1$:           clv
              bpl     2$
              sep     #0x40
2$:           lda     dp:.tiny QK           ; C = QD < 0
              lsr     a
              lsr     a
              txa                           ; left = 0: right decides
              beq     10$
              bcc     3$                    ; N = left < 0
              eor     ##0xffff
3$:           bvs     4$
              bmi     11$                   ; right > 0 > left: 1
              bra     30$
4$:           bpl     12$                   ; right < 0 < left: 0
              ;; the same sign: the logs, X = 2 |QA|, Y = 2 |QC| (|Q| =
              ;; 32768: 0), and the stack keeps V
30$:          php
              txa
              bpl     31$
              eor     ##0xffff
              inc     a
31$:          asl     a
              tyx
              tay
              txa
              bpl     32$
              eor     ##0xffff
              inc     a
32$:          asl     a
              tax
              lda     long:LOGTAB,x         ; M
              sec
              sbc     [.tiny LOGP],y
              clc
              adc     dp:.tiny QK
              bvs     36$                   ; |M| > 32767: N is the other sign
              bmi     35$
              cmp     ##18
              bcs     37$
              bra     40$
35$:          cmp     ##(0x10000 - 17)
              bcc     38$
              bra     40$
36$:          bpl     38$
37$:          lda     ##1                   ; |right| > |left|: 1 for right > 0,
              bra     39$                   ;   0 for right < 0
38$:          lda     ##0                   ; |right| < |left|: the other way
39$:          plp
              bvc     9$
              eor     ##1
9$:           jmp     (abs:SVEC)
10$:          bvs     12$                   ; left = 0: right > 0: 1, right < 0: 0
11$:          lda     ##1
              jmp     (abs:SVEC)
12$:          lda     ##0
              jmp     (abs:SVEC)
20$:          lda     dp:.tiny QK           ; right = 0: left < 0: 1, left > 0: 0,
              lsr     a                     ;   left = 0: 2
              lsr     a
              txa
              beq     21$
              bcc     22$
              eor     ##0xffff
22$:          bmi     11$
              bra     12$
21$:          lda     ##2
              jmp     (abs:SVEC)

              ;; too close: the products |QA| * |QB| and |QC| * |QD|
              ;; (umul16), the same way round
40$:          phy
              txa
              jsr     .kbank half
              sta     dp:.tiny MA
              ldx     ##0
              jsr     .kbank qbd
              sta     dp:.tiny MB
              jsl     long:umul16
              lda     dp:.tiny MR
              sta     .near QR
              lda     dp:.tiny (MR+2)
              sta     .near (QR+2)
              pla
              jsr     .kbank half
              sta     dp:.tiny MA
              ldx     ##2
              jsr     .kbank qbd
              sta     dp:.tiny MB
              jsl     long:umul16
              lda     .near (QR+2)
              cmp     dp:.tiny (MR+2)
              bne     41$
              lda     .near QR
              cmp     dp:.tiny MR
              bne     41$
              plp                           ; equal: 2
              lda     ##2
              jmp     (abs:SVEC)
41$:          bcs     37$
              bra     38$

;;; half: C = |v| from C = 2 |v| (0: 32768).
half:         lsr     a
              bne     1$
              lda     ##0x8000
1$:           rts

;;; qbd: C = |QB| (X = 0) or |QD| (X = 2) of the divline of sideTest: at
;;; (QK & 12) + X of [PS_P], or of the line of sight for 0.
qbd:          lda     dp:.tiny QK
              and     ##12
              beq     1$
              cpx     ##0
              beq     4$
              inc     a
              inc     a
4$:           tay
              lda     [.tiny PS_P],y
              bra     2$
1$:           txa
              asl     a
              tax
              lda     .near (LOS_STRACE+OFS_DL_DX+2),x
2$:           bpl     3$
              eor     ##0xffff
              inc     a
3$:           rts

;;; ---------------------------------------------------------------------------
;;; lineSideS: A = P_DivlineSide(vx << FRACBITS, vy << FRACBITS, &los.strace)
;;; In: X = vx, Y = vy (whole units); QK = KS. Out: A = 0 front, 1 back,
;;; 2 on.
;;;   !s.dx ? x == s.x ? 2 : x <= s.x ? s.dy > 0 : s.dy < 0 :
;;;   !s.dy ? y == s.y ? 2 : y <= s.y ? s.dx < 0 : s.dx > 0 :
;;;   sideTest with QA = (y - s.y) >> 16 (0 for s.dx >> 16 == 0),
;;;   QC = (x - s.x) >> 16 (0 for s.dy >> 16 == 0)
;;; ---------------------------------------------------------------------------
lineSideS:    lda     .near (LOS_STRACE+OFS_DL_DX)
              ora     .near (LOS_STRACE+OFS_DL_DX+2)
              beq     10$
              lda     .near (LOS_STRACE+OFS_DL_DY)
              ora     .near (LOS_STRACE+OFS_DL_DY+2)
              beq     20$
              lda     ##0                   ; QA
              sec
              sbc     .near (LOS_STRACE+OFS_DL_Y)
              tya
              sbc     .near (LOS_STRACE+OFS_DL_Y+2)
              tay
              lda     ##0                   ; QC
              sec
              sbc     .near (LOS_STRACE+OFS_DL_X)
              txa
              sbc     .near (LOS_STRACE+OFS_DL_X+2)
              tax
              lda     .near (LOS_STRACE+OFS_DL_DX+2)
              bne     1$
              tay
1$:           lda     .near (LOS_STRACE+OFS_DL_DY+2)
              bne     2$
              tax
2$:           brl     sideTest

              ;; s.dx == 0
10$:          txa
              sec
              sbc     .near (LOS_STRACE+OFS_DL_X+2)
              beq     12$                   ; the same whole part
              bvc     11$
              eor     ##0x8000
11$:          bpl     14$                   ; x > s.x
              bra     13$
12$:          lda     .near (LOS_STRACE+OFS_DL_X)
              beq     15$                   ; x == s.x
13$:          lda     .near (LOS_STRACE+OFS_DL_DY+2) ; x < s.x: s.dy > 0
              bmi     90$
              ora     .near (LOS_STRACE+OFS_DL_DY)
              beq     90$
              bra     91$
14$:          lda     .near (LOS_STRACE+OFS_DL_DY+2) ; x > s.x: s.dy < 0
              bmi     91$
90$:          lda     ##0
              jmp     (abs:SVEC)
91$:          lda     ##1
              jmp     (abs:SVEC)
15$:          lda     ##2
              jmp     (abs:SVEC)

              ;; s.dy == 0 (s.dx != 0)
20$:          tya
              sec
              sbc     .near (LOS_STRACE+OFS_DL_Y+2)
              beq     22$                   ; the same whole part
              bvc     21$
              eor     ##0x8000
21$:          bpl     24$                   ; y > s.y
23$:          lda     .near (LOS_STRACE+OFS_DL_DX+2) ; y < s.y: s.dx < 0
              bmi     91$
              bra     90$
22$:          lda     .near (LOS_STRACE+OFS_DL_Y)
              beq     15$                   ; y == s.y
              bra     23$                   ; y < s.y
24$:          lda     .near (LOS_STRACE+OFS_DL_DX+2) ; y > s.y: s.dx > 0
              bmi     90$
              bra     91$

;;; ---------------------------------------------------------------------------
;;; The side passes: nodeSide and lineSideS end at SVEC with A = the side
;;; of the point: nodeDone (the node loop), lineDone (the line as a
;;; divline: the start and the end of the line of sight), straceDone (the
;;; line of sight as a divline: the ends of the line). SS: bit 7 the first
;;; point, else its side (the node loop: the offset of children[side & 1]).
;;; No calls: SS, QK and SVEC are the only stores.
;;; ---------------------------------------------------------------------------
nodeDone:     bit     dp:.tiny SS           ; (16-bit A: bit 15 of SS is the
              bpl     2$                    ;   first point)
              and     ##1                   ; the start: SS = the offset of
              asl     a                     ;   children[side & 1]
              adc     ##OFS_NODE_CHILDREN
              sta     dp:.tiny SS
              ldx     ##.near (los+OFS_LOS_T2X) ; side2 = P_DivlineSide(t2x,
              ldy     ##OFS_NODE_DX         ;   t2y, node)
              brl     nodeSide
2$:           asl     a                     ; the end: side == side2:
              adc     ##OFS_NODE_CHILDREN   ;   children[side]
              ldy     dp:.tiny SS
              cmp     dp:.tiny SS
              beq     3$
              tya                           ; crossed: children[side ^ 1] waits
              eor     ##2
              tay
              lda     [.tiny PS_P],y
              pha
              ldy     dp:.tiny SS
3$:           lda     [.tiny PS_P],y
              brl     nodeLoop

lineDone:     bit     dp:.tiny SS           ; the line as a divline
              bpl     2$
              sta     dp:.tiny SS           ; the start, then the end
              ldx     ##.near (los+OFS_LOS_T2X)
              ldy     ##OFS_LINE_DX
              brl     nodeSide
2$:           cmp     dp:.tiny SS           ; the same side: not crossed
              beq     9$
              lda     .near KS              ; then the line of sight as the
              sta     dp:.tiny QK           ;   divline (KS): v1, then v2
              lda     ##.word0 straceDone
              sta     dp:.tiny SVEC
              lda     ##0x8000
              sta     dp:.tiny SS
              ldy     ##OFS_LINE_V1
              bra     vtx
9$:           brl     nextSeg

straceDone:   bit     dp:.tiny SS           ; the line of sight as a divline
              bmi     1$
              cmp     dp:.tiny SS           ; the same side: not crossed
              beq     9$
              brl     crossed
9$:           brl     nextSeg
              .space  27                    ; (the code after keeps its address)
1$:           sta     dp:.tiny SS
              ldy     ##OFS_LINE_V2
vtx:          lda     [.tiny PS_P],y        ; X = vx, Y = vy
              tax
              iny
              iny
              lda     [.tiny PS_P],y
              tay
              brl     lineSideS

;;; ---------------------------------------------------------------------------
;;; opening: PS_OPENTOP = the lower ceiling of FS and BS, PS_OPENBOT = the
;;; higher floor (bytes).
;;; ---------------------------------------------------------------------------
opening:      ldx     ##.near PS_OPENTOP
              ldy     ##OFS_SEC_CEILINGHEIGHT ; FS < BS: FS
              lda     [.tiny FS],y
              cmp     [.tiny BS],y
              iny
              iny
              lda     [.tiny FS],y
              sbc     [.tiny BS],y
              bvc     1$
              eor     ##0x8000
1$:           jsr     .kbank pick
              ldx     ##.near PS_OPENBOT
              ldy     ##OFS_SEC_FLOORHEIGHT ; BS < FS: FS
              lda     [.tiny BS],y
              cmp     [.tiny FS],y
              iny
              iny
              lda     [.tiny BS],y
              sbc     [.tiny FS],y
              bvc     2$
              eor     ##0x8000
2$:           ;; fall into pick

;;; pick: the 32-bit height at Y - 2 of FS (N set) or BS to near X, as
;;; bytes.
pick:         bmi     2$
              dey
              dey
              sep     #0x20
1$:           lda     [.tiny BS],y
              sta     abs:0,x
              inx
              iny
              tya
              and     #3
              bne     1$
              rep     #0x20
              rts
2$:           dey
              dey
              sep     #0x20
3$:           lda     [.tiny FS],y
              sta     abs:0,x
              inx
              iny
              tya
              and     #3
              bne     3$
              rep     #0x20
              rts

;;; sameHeight: Z set if the 32-bit heights at offset Y of the sectors FS
;;; and BS are equal.
sameHeight:   lda     [.tiny FS],y
              cmp     [.tiny BS],y
              bne     1$
              iny
              iny
              lda     [.tiny FS],y
              cmp     [.tiny BS],y
1$:           rts

;;; st32: the near fixed_t at Y = X:A (X its low word, A its high word).
;;; Destroys A.
st32:         sta     abs:2,y               ; (words: no SEP and REP)
              txa
              sta     abs:0,y
              rts
              .space  17                    ; (the code after keeps its address)

;;; ---------------------------------------------------------------------------
;;; zSetup: the heights of los, for the first two sided line of a check
;;; (t1, t2 still in _Dp): los.sightzstart = t1->z + t1->height -
;;; (t1->height >> 2), los.bottomslope = t2->z - sightzstart, topslope =
;;; that + t2->height. CS_T = height >> 2, then height - CS_T.
;;; ---------------------------------------------------------------------------
zSetup:       ldy     ##(OFS_MO_HEIGHT+2)
              lda     [.tiny _Dp],y
              cmp     ##0x8000
              ror     a
              tax                           ; X = high >> 1 (C: its bit 0)
              ldy     ##OFS_MO_HEIGHT
              lda     [.tiny _Dp],y
              ror     a
              tay                           ; Y = (height >> 1) low
              txa
              cmp     ##0x8000
              ror     a
              tax                           ; X = (height >> 2) high
              tya
              ror     a                     ; (height >> 2) low
              tay
              txa
              tyx
              ldy     ##.near CS_T
              jsr     .kbank st32
              ldy     ##OFS_MO_HEIGHT       ; height - CS_T
              lda     [.tiny _Dp],y
              sec
              sbc     .near CS_T
              tax
              ldy     ##(OFS_MO_HEIGHT+2)
              lda     [.tiny _Dp],y
              sbc     .near (CS_T+2)
              ldy     ##.near CS_T
              jsr     .kbank st32
              ldy     ##OFS_MO_Z            ; + t1->z
              lda     [.tiny _Dp],y
              clc
              adc     .near CS_T
              tax
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny _Dp],y
              adc     .near (CS_T+2)
              ldy     ##.near (los+OFS_LOS_SIGHTZSTART)
              jsr     .kbank st32
              ldy     ##OFS_MO_Z            ; bottomslope = t2->z - sightzstart
              lda     [.tiny (_Dp+4)],y
              sec
              sbc     .near (los+OFS_LOS_SIGHTZSTART)
              tax
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny (_Dp+4)],y
              sbc     .near (los+OFS_LOS_SIGHTZSTART+2)
              ldy     ##.near (los+OFS_LOS_BOTTOMSLOPE)
              jsr     .kbank st32
              ldy     ##OFS_MO_HEIGHT       ; topslope = bottomslope + t2->height
              lda     [.tiny (_Dp+4)],y
              clc
              adc     .near (los+OFS_LOS_BOTTOMSLOPE)
              tax
              ldy     ##(OFS_MO_HEIGHT+2)
              lda     [.tiny (_Dp+4)],y
              adc     .near (los+OFS_LOS_BOTTOMSLOPE+2)
              ldy     ##.near (los+OFS_LOS_TOPSLOPE)
              jsr     .kbank st32
              sep     #0x20
              lda     #1
              sta     .near CS_Z
              rep     #0x20
              rts
;;; ---------------------------------------------------------------------------
;;; interceptFrac: PS_FRAC = P_InterceptVector2(&los.strace, &divl) of
;;; p_sight.c, divl the line (NX, NY, NDX, NDY) << 16. With
;;; s = los.strace:
;;;   num = NDY * (((NX << 16) - s.x) >> 8) + NDX * ((s.y - (NY << 16)) >> 8)
;;;   den = ((s.dx * NDY) >> 8) - ((s.dy * NDX) >> 8)
;;;   0 if num == 0 or den >> 12 == 0, else (num << 4) / (den >> 12)
;;;   limited to 0..0xffff (a negative quotient gives 0xffff).
;;; The quotient is |num << 4| / |den >> 12|; it is 0xffff or more when
;;; the high word of the dividend is at least the divisor.
;;; ---------------------------------------------------------------------------
              .section znear, bss
IF_V:         .space  4               ; smul48: the 32-bit operand
IF_P:         .space  6               ; smul48: the 48-bit product
IF_S:         .space  2               ; smul48: the sign of the product
IF_NUM:       .space  4
IF_E:         .space  4               ; den, then den >> 12
IF_QS:        .space  2               ; the sign of the quotient

IF_R          .equ    _Dp             ; the remainder (2 words)
IF_Q          .equ    _Dp+4           ; the dividend low word, then the quotient


              .section logiccode, text      ; (a two sided line: rare)
interceptFrac:
              sep     #0x20                 ; DLN: the line [PS_P] as a divline:
              ldy     ##3                   ;   v1 and dx, dy (bytes)
91$:          lda     [.tiny PS_P],y
              sta     abs:.near DLN,y
              dey
              bpl     91$
              ldy     ##(OFS_LINE_DX+3)
92$:          lda     [.tiny PS_P],y
              sta     abs:.near (DLN+4-OFS_LINE_DX),y
              dey
              cpy     ##OFS_LINE_DX
              bcs     92$
              rep     #0x20
              sec                           ; num = NDY * (((NX << 16) - s.x) >> 8)
              lda     ##0
              sbc     .near (LOS_STRACE+OFS_DL_X)
              sta     .near IF_P
              lda     .near NX
              sbc     .near (LOS_STRACE+OFS_DL_X+2)
              sta     .near (IF_P+2)
              jsr     .kbank shr8V
              lda     .near NDY
              jsr     .kbank smul48
              MOVE32  IF_P, IF_NUM
              lda     .near (LOS_STRACE+OFS_DL_Y) ; + NDX * ((s.y - (NY << 16)) >> 8)
              sta     .near IF_P
              lda     .near (LOS_STRACE+OFS_DL_Y+2)
              sec
              sbc     .near NY
              sta     .near (IF_P+2)
              jsr     .kbank shr8V
              lda     .near NDX
              jsr     .kbank smul48
              lda     .near IF_NUM
              clc
              adc     .near IF_P
              sta     .near IF_NUM
              lda     .near (IF_NUM+2)
              adc     .near (IF_P+2)
              sta     .near (IF_NUM+2)
              ora     .near IF_NUM
              bne     1$
              stz     .near PS_FRAC
              rtl

1$:           MOVE32  (LOS_STRACE+OFS_DL_DX), IF_V ; den = ((s.dx * NDY) >> 8)
              lda     .near NDY
              jsr     .kbank smul48
              lda     .near (IF_P+1)
              sta     .near IF_E
              lda     .near (IF_P+3)
              sta     .near (IF_E+2)
              MOVE32  (LOS_STRACE+OFS_DL_DY), IF_V ; - ((s.dy * NDX) >> 8)
              lda     .near NDX
              jsr     .kbank smul48
              lda     .near IF_E
              sec
              sbc     .near (IF_P+1)
              sta     .near IF_E
              lda     .near (IF_E+2)
              sbc     .near (IF_P+3)
              sta     .near (IF_E+2)
              ;; den >> 12: bits 12..27 and the sign extended bits 28..31
              lda     .near (IF_E+2)
              asl     a
              asl     a
              asl     a
              asl     a
              and     ##0xf000
              sta     dp:.tiny IF_R
              lda     .near (IF_E+1)
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              ora     dp:.tiny IF_R
              sta     .near IF_E
              lda     .near (IF_E+3)
              and     ##0x00f0
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              cmp     ##8
              bcc     2$
              ora     ##0xfff0
2$:           sta     .near (IF_E+2)
              ora     .near IF_E
              bne     3$
              stz     .near PS_FRAC
              rtl

              ;; |num << 4| and |den >> 12|, the sign of the quotient
3$:           ldx     ##4
4$:           asl     .near IF_NUM
              rol     .near (IF_NUM+2)
              dex
              bne     4$
              lda     .near (IF_NUM+2)
              eor     .near (IF_E+2)
              sta     .near IF_QS
              lda     .near (IF_NUM+2)
              bpl     5$
              lda     .near IF_NUM
              eor     ##0xffff
              clc
              adc     ##1
              sta     .near IF_NUM
              lda     .near (IF_NUM+2)
              eor     ##0xffff
              adc     ##0
              sta     .near (IF_NUM+2)
5$:           lda     .near (IF_E+2)
              bpl     6$
              lda     .near IF_E
              eor     ##0xffff
              clc
              adc     ##1
              sta     .near IF_E
              lda     .near (IF_E+2)
              eor     ##0xffff
              adc     ##0
              sta     .near (IF_E+2)
6$:           bne     7$                    ; a quotient of 0x10000 or more?
              lda     .near (IF_NUM+2)
              cmp     .near IF_E
              bcc     7$
              lda     ##0xffff
              sta     .near PS_FRAC
              rtl

              ;; 16 steps of the division: the remainder starts with the
              ;; high word of the dividend. For den >> 12 below 0x10000 (most
              ;; lines) the remainder stays in X, with bit 16 in the carry,
              ;; and each rol of IF_Q takes out a dividend bit and puts in the
              ;; quotient bit of the step before: one write a step.
7$:           lda     .near IF_NUM
              sta     dp:.tiny IF_Q
              ldx     .near (IF_NUM+2)
              lda     .near (IF_E+2)
              bne     70$
              ldy     ##16
              clc
71$:          rol     dp:.tiny IF_Q         ; carry: the next dividend bit
              txa
              rol     a                     ; R = R << 1 | the bit
              bcs     72$                   ; R >= 0x10000 > E
              cmp     .near IF_E
              bcc     73$                   ; R < E: the bit 0 (carry clear)
72$:          sbc     .near IF_E
              sec                           ; the bit 1
73$:          tax
              dey
              bne     71$
              rol     dp:.tiny IF_Q         ; the last quotient bit
              bra     74$
70$:          stx     dp:.tiny IF_R
              stz     dp:.tiny (IF_R+2)
              ldy     ##16
8$:           asl     dp:.tiny IF_Q
              rol     dp:.tiny IF_R
              rol     dp:.tiny (IF_R+2)
              lda     dp:.tiny IF_R
              sec
              sbc     .near IF_E
              tax
              lda     dp:.tiny (IF_R+2)
              sbc     .near (IF_E+2)
              bcc     9$
              sta     dp:.tiny (IF_R+2)
              stx     dp:.tiny IF_R
              inc     dp:.tiny IF_Q
9$:           dey
              bne     8$
74$:          lda     dp:.tiny IF_Q         ; a negative quotient: 0xffff
              ldx     .near IF_QS
              bpl     10$
              cmp     ##0
              beq     10$
              lda     ##0xffff
10$:          sta     .near PS_FRAC
              rtl

;;; shr8V: IF_V = IF_P (32 bits) >> 8, arithmetic.
shr8V:        lda     .near (IF_P+1)
              sta     .near IF_V
              lda     .near (IF_P+3)
              and     ##0x00ff
              cmp     ##0x0080
              bcc     1$
              ora     ##0xff00
1$:           sta     .near (IF_V+2)
              rts

;;; smul48: IF_P = IF_V * C, signed 32 x 16 -> 48 bits. IF_V is lost.
smul48:       ldx     ##0
              cmp     ##0
              bpl     1$
              eor     ##0xffff
              inc     a
              ldx     ##0xffff
1$:           sta     dp:.tiny MB
              lda     .near (IF_V+2)
              bpl     2$
              lda     .near IF_V
              eor     ##0xffff
              clc
              adc     ##1
              sta     .near IF_V
              lda     .near (IF_V+2)
              eor     ##0xffff
              adc     ##0
              sta     .near (IF_V+2)
              txa
              eor     ##0xffff
              tax
2$:           stx     .near IF_S
              lda     .near IF_V            ; |v| low * |c|
              sta     dp:.tiny MA
              jsl     long:umul16
              lda     dp:.tiny MR
              sta     .near IF_P
              lda     dp:.tiny (MR+2)
              sta     .near (IF_P+2)
              lda     .near (IF_V+2)        ; + |v| high * |c| << 16
              sta     dp:.tiny MA
              jsl     long:umul16
              lda     dp:.tiny MR
              clc
              adc     .near (IF_P+2)
              sta     .near (IF_P+2)
              lda     dp:.tiny (MR+2)
              adc     ##0
              sta     .near (IF_P+4)
              lda     .near IF_S
              beq     9$
              lda     .near IF_P            ; the sign
              eor     ##0xffff
              clc
              adc     ##1
              sta     .near IF_P
              lda     .near (IF_P+2)
              eor     ##0xffff
              adc     ##0
              sta     .near (IF_P+2)
              lda     .near (IF_P+4)
              eor     ##0xffff
              adc     ##0
              sta     .near (IF_P+4)
9$:           rts

;;; ---------------------------------------------------------------------------
;;; sightSlope: X:C = frac != 0 ?
;;;   ((height - los.sightzstart) >> FRACBITS) * FixedReciprocalSmall(frac)
;;;   : INT32_MAX, frac = PS_FRAC. In: X:C = the height.
;;; ---------------------------------------------------------------------------
sightSlope:   ldy     .near PS_FRAC
              bne     3$
              lda     ##0xffff              ; INT32_MAX
              ldx     ##0x7fff
              rtl
3$:           sec                           ; (height - sightzstart) >> 16,
              sbc     .near (los+OFS_LOS_SIGHTZSTART) ; sign extended to 32 bits
              txa                           ;   (bytes)
              sbc     .near (los+OFS_LOS_SIGHTZSTART+2)
              sep     #0x20
              sta     dp:.tiny _Dp
              xba
              sta     dp:.tiny (_Dp+1)
              asl     a                     ; (C: the sign)
              lda     #0
              adc     #0xff
              eor     #0xff
              sta     dp:.tiny (_Dp+2)
              sta     dp:.tiny (_Dp+3)
              rep     #0x20
              tya
              jsl     long:FixedReciprocalSmall
              sep     #0x20                 ; the reciprocal (bytes)
              sta     dp:.tiny (_Dp+4)
              xba
              sta     dp:.tiny (_Dp+5)
              rep     #0x20
              txa
              sep     #0x20
              sta     dp:.tiny (_Dp+6)
              xba
              sta     dp:.tiny (_Dp+7)
              rep     #0x20
              jmp     long:_Mul32

bitTab:       .byte   1, 2, 4, 8, 16, 32, 64, 128, 0


;;; ---------------------------------------------------------------------------
;;; void P_InitSightLogs(void): LOGP, SIGHTLOG and LINELOG of the map,
;;; after P_LoadLineDefs and P_LoadNodes. K of a divline (kOf) is
;;; log |dx| - log |dy| (log.bin) with its low 4 bits: bit 0 dx < 0,
;;; bit 1 dy < 0, bits 2-3 the offset of dx / 4 (4 a node, 8 a line, 0 the
;;; line of sight), which sideTest reads.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public P_InitSightLogs
P_InitSightLogs:
              stz     dp:.tiny LOGP         ; LOGP = LOGTAB
              lda     ##(LOGTAB >> 16)
              sta     dp:.tiny (LOGP+2)
              lda     .near numnodes
              cmp     ##(NODE_MAX + 1)
              bcc     1$
              lda     ##.word0 nlErr
              sta     dp:.tiny _Dp
              lda     ##.word2 nlErr
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
1$:           lda     .near nodes           ; each node: its address, K
              sta     dp:.tiny PS_P
              lda     .near (nodes+2)
              sta     dp:.tiny (PS_P+2)
              lda     .near numnodes
              sta     .near SL_N
              stz     .near SL_X
2$:           dec     .near SL_N
              bmi     3$
              lda     dp:.tiny PS_P
              ldx     .near SL_X
              sta     long:SIGHTLOG,x
              ldy     ##OFS_NODE_DX
              jsr     .kbank kOf
              ldx     .near SL_X
              sta     long:(SIGHTLOG+2),x
              inx
              inx
              inx
              inx
              stx     .near SL_X
              lda     dp:.tiny PS_P
              clc
              adc     ##SIZEOF_NODE
              sta     dp:.tiny PS_P
              bra     2$
3$:           lda     .near _g_lines        ; each line: K
              sta     dp:.tiny PS_P
              lda     .near (_g_lines+2)
              sta     dp:.tiny (PS_P+2)
              lda     .near _g_numlines
              sta     .near SL_N
              stz     .near SL_X
4$:           dec     .near SL_N
              bmi     5$
              ldy     ##OFS_LINE_DX
              jsr     .kbank kOf
              ldx     .near SL_X
              sta     long:LINELOG,x
              inx
              inx
              stx     .near SL_X
              lda     dp:.tiny PS_P
              clc
              adc     ##SIZEOF_LINE
              sta     dp:.tiny PS_P
              bra     4$
5$:           rtl

;;; kOf: C = K of the divline [PS_P] whose dx, dy are at Y, Y + 2.
kOf:          sty     .near SL_B            ; the low bits
              lda     [.tiny PS_P],y        ; dx < 0: bit 0
              bpl     1$
              inc     .near SL_B
1$:           iny
              iny
              lda     [.tiny PS_P],y        ; dy < 0: bit 1
              bpl     2$
              inc     .near SL_B
              inc     .near SL_B
2$:           jsr     .kbank absLog         ; log |dy|
              beq     8$
              sta     .near SL_T
              dey
              dey
              lda     [.tiny PS_P],y        ; log |dx|
              jsr     .kbank absLog
              beq     8$
              sec
              sbc     .near SL_T
              and     ##0xfff0
              bra     9$
8$:           lda     ##0                   ; (dx or dy 0: not used)
9$:           ora     .near SL_B
              rts

;;; absLog: C = log2(|C|) * 2048 (LOGTAB), Z set for C = 0.
absLog:       cmp     ##0
              beq     2$
              bpl     1$
              eor     ##0xffff
              inc     a
1$:           asl     a
              tax
              lda     long:LOGTAB,x
              ldx     ##1                   ; (Z clear)
2$:           rts

nlErr:        .asciz  "P_InitSightLogs: too many nodes"

;;; ---------------------------------------------------------------------------
;;; void P_InitSightTables(void): SS_ROW, SS_SEC and SS_SEGT of the map
;;; after P_GroupLines (the sector of each subsector), SEC58, and LNSEC for
;;; PIT_CheckLine of src/iigs/p_map65.s.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public P_InitSightTables
P_InitSightTables:
              lda     .near numsubsectors
              cmp     ##(SS_MAX + 1)
              bcs     8$
              lda     .near _g_numsectors
              cmp     ##(SEC_MAX + 1)
              bcc     1$
8$:           lda     ##.word0 ssErr
              sta     dp:.tiny _Dp
              lda     ##.word2 ssErr
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
1$:           lda     .near _g_subsectors
              sta     dp:.tiny PS_P
              lda     .near (_g_subsectors+2)
              sta     dp:.tiny (PS_P+2)
              stz     .near CS_T            ; 2 * the subsector
2$:           lda     .near CS_T
              lsr     a
              cmp     .near numsubsectors
              bcs     6$
              asl     a                     ; * 8
              asl     a
              asl     a
              tay
              lda     [.tiny PS_P],y        ; its sector: (sector - _g_sectors) / 58
              sec                           ;   as (offset * M) >> 20 with
              sbc     .near _g_sectors      ;   M = ceil(2^20 / 58), exact for
              sta     dp:.tiny MA           ;   these offsets
              lda     ##((0x100000 + SIZEOF_SEC - 1) / SIZEOF_SEC)
              sta     dp:.tiny MB
              jsl     long:umul16
              lda     dp:.tiny (MR+2)
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              ldx     .near CS_T
              sta     long:SS_SEC,x
              ldx     .near _g_numsectors   ; its REJECT row
              jsl     long:IIGS_MulLo16
              ldx     .near CS_T
              sta     long:SS_ROW,x
              lda     .near CS_T            ; its segs: the first (firstline * 18
              asl     a                     ;   + _g_segs) and the count (less
              tax                           ;   than 256)
              lda     .near CS_T
              asl     a
              asl     a
              clc
              adc     ##OFS_SUB_FIRSTLINE
              tay
              lda     [.tiny PS_P],y
              asl     a
              sta     .near SL_T
              asl     a
              asl     a
              asl     a
              clc
              adc     .near SL_T
              clc
              adc     .near _g_segs
              sta     long:SS_SEGT,x
              dey
              dey
              lda     [.tiny PS_P],y        ; OFS_SUB_NUMLINES
              cmp     ##0x100
              bcc     3$
              brl     8$
3$:           sta     long:(SS_SEGT+2),x
              lda     .near CS_T
              inc     a
              inc     a
              sta     .near CS_T
              bra     2$
6$:           ldx     ##0                   ; each sector: its address
              lda     .near _g_sectors
              ldy     .near _g_numsectors
              beq     9$
7$:           sta     long:SEC58,x
              clc
              adc     ##SIZEOF_SEC
              inx
              inx
              dey
              bne     7$
9$:           lda     .near _g_lines        ; each line: its front and back
              sta     dp:.tiny PS_P         ;   sectors (LNSEC; no back: the
                                            ;   front again)
              lda     .near (_g_lines+2)
              sta     dp:.tiny (PS_P+2)
              stz     .near SL_X            ; 2 * the line
10$:          lda     .near SL_X
              lsr     a
              cmp     .near _g_numlines
              bcs     19$
              ldy     ##OFS_LINE_SIDENUM    ; the front
              jsr     .kbank sideSec
              sta     .near SL_N
              ldy     ##(OFS_LINE_SIDENUM+2) ; the back (none: the front)
              lda     [.tiny PS_P],y
              cmp     ##0xffff
              lda     .near SL_N
              bcs     11$
              jsr     .kbank sideSec
11$:          and     ##0x00ff
              xba
              ora     .near SL_N
              ldx     .near SL_X
              sta     long:LNSEC,x
              inx
              inx
              stx     .near SL_X
              lda     dp:.tiny PS_P
              clc
              adc     ##SIZEOF_LINE
              sta     dp:.tiny PS_P
              bra     10$
19$:          jmp     long:sqmFlood         ; SQMID, the lists of the sound flood

;;; sideSec: C = the number of the sector of the side whose number is at
;;; [PS_P],y.
sideSec:      lda     [.tiny PS_P],y        ; its address: _g_sides + 14 * side
              asl     a
              sta     .near SL_B
              asl     a
              asl     a
              asl     a
              sec
              sbc     .near SL_B
              clc
              adc     .near _g_sides
              sta     dp:.tiny _Dp
              lda     .near (_g_sides+2)
              sta     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp]           ; its sector (OFS_SIDE_SECTOR):
              sec                           ;   (sector - _g_sectors) / 58 as
              sbc     .near _g_sectors      ;   in the subsector loop above
              sta     dp:.tiny MA
              lda     ##((0x100000 + SIZEOF_SEC - 1) / SIZEOF_SEC)
              sta     dp:.tiny MB
              jsl     long:umul16
              lda     dp:.tiny (MR+2)
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              rts

ssErr:        .asciz  "P_InitSightTables: the map is too large"
