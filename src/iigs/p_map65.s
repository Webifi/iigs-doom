;;; Movement clipping in 65816 assembly, Doom8088: Apple IIgs Edition.
;;;
;;; P_CheckPosition, P_TryMove, PIT_CheckLine, PIT_GetSectors and
;;; P_CreateSecNodeList of p_map.c, and P_PointOnLineSide,
;;; P_BoxOnLineSide, P_LineOpening, P_UnsetThingPosition,
;;; P_SetThingPosition and the block map iterators of p_maputl.c,
;;; with the same results and the same side effects.
;;;
;;; Also PIT_CheckThing, P_TeleportMove, PIT_StompThing and the sector
;;; nodes (P_AddSecnode, P_DelSecnode, P_DelSeclist) of p_map.c.
;;;
;;; C code that these routines call can run game logic again (a missile
;;; hits a monster, which then moves), so state that must live across a
;;; C call is on the stack or in the callee-saved _Dp[8-19].
;;; Lumps and zone blocks never cross a bank, so 16-bit pointer
;;; arithmetic gives the same addresses as the C code.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"
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


              .extern _Dp, IIGS_MulLo16, R_PointInSubsector, MA, MB, MR, umul16, umul16lo
              .extern _g_player, _g_lines, _g_sides
              .extern _g_blockmap, _g_blockmaplump, _g_blocklinks
              .extern _g_bmapwidth, _g_bmapheight, _g_bmaporgx, _g_bmaporgy, _g_numlines
              .extern P_CrossSpecialLine, Z_CallocLevel
              .extern P_DamageMobj, P_TouchSpecialThing, P_Random, mobjinfo, I_Error
              .extern DC_TF, DC_TI, DC_SF, DC_SI, DC_COUNT, DC_ROW
              .extern DC_SRC, DC_CMB, DC_ENTRY, DC_TMID7, DC_FRAC, DC_SAVEB
              .extern DC_FLATW, DC_FSTEP, DC_COLX
              .extern _g_sectors, _g_subsectors

;;; The block rows: y * _g_bmapwidth for each row of the blockmap, and
;;; the lines: _g_lines + 36 * n for each line number n (P_InitBlockRows),
;;; for the walks instead of a multiply. Bank 3F after the sight tables
;;; (src/iigs/p_sight65.s).
BMROW         .equ    (MM_B3F + 0x6000)
BMROW_MAX     .equ    0x100           ; (the rows and columns of a map)
LN36          .equ    (MM_B3F + 0x6200)
LN36_MAX      .equ    0xf00

;;; The sectors of each line (line * 2: the front sector, the back sector,
;;; bytes; the front sector twice for a one sided line), the address of
;;; each sector (sector * 2: its low word) and the sector of each subsector,
;;; for PIT_CheckLine, PIT_GetSectors and P_CreateSecNodeList
;;; (P_InitSightTables of src/iigs/p_sight65.s).
LNSEC         .equ    (MM_B3F + 0xc000)
PAD_LO        .equ    137             ; (P_LineOpening keeps its size)
SEC58         .equ    (MM_B3F + 0xa000)
SS_SEC        .equ    (MM_B3F + 0x5000) ; the sector of each subsector (a word)

;;; The direct page of the walks: inputs of the column drawers
;;; (tools/gendraw.py), free in a game tic.
WK_BH         .equ    DC_TF           ; the box of the line walk: bottom >> 16
WK_TF         .equ    DC_TI           ;   (top >> 16) - (its low word == 0)
WK_RF         .equ    DC_SF           ;   (right >> 16) - (its low word == 0)
WK_LH         .equ    DC_SI           ;   left >> 16
WK_TB         .equ    DC_COUNT        ; the thing walk: the bank of the thing
WK_PR         .equ    DC_TF           ;   the radius of the last thing
WK_CP         .equ    DC_ROW          ; the line walk: 1 when MP_TB is the box
WK_LS         .equ    DC_SRC          ; the block list of the line walk
WK_BL         .equ    DC_CMB          ; _g_blocklinks, or _g_blockmap
WK_LN         .equ    DC_ENTRY        ; the line of the line checks (a far pointer)
TP            .equ    DC_TMID7        ; P_TryMove: the thing (3 bytes)
PS            .equ    DC_FRAC         ; PIT_CheckLine: a sector of the line (3
BS            .equ    DC_SAVEB        ;   bytes), the back sector (its low word)
PXO           .equ    DC_FLATW        ; pointOnLineSide: the point x, y at
PYO           .equ    (DC_FLATW+1)    ;   MP_TB + PXO, PYO (bytes)
GSF           .equ    DC_FLATW        ; getSectors: the front and back sectors
GSB           .equ    (DC_FLATW+1)    ;   of the line
PSD           .equ    (DC_FSTEP+1)    ; slanted: the side of the first corner
PVEC          .equ    DC_COUNT        ; pointOnLineSide: where it ends (a word;
                                      ;   WK_TB is not live then)

;;; The walk frame of the blocks on the stack (P_CheckPosition, lineBlocks):
;;; the block x and y (words below 256), the last x and y and the first y
;;; (bytes), the list position of the line walk.
FR_BX         .equ    1
FR_BX1        .equ    2
FR_BY         .equ    3
FR_BY1        .equ    4
FR_XH         .equ    5
FR_YH         .equ    6
FR_YL         .equ    7
FR_LY         .equ    8
FR_LY1        .equ    9
FR_TRY        .equ    10              ; (P_CheckPosition: from P_TryMove)
FR_SIZE       .equ    10
TC_TRY        .equ    (3 + FR_TRY)    ; tCheck: after the thing (3 bytes),
TC_TT         .equ    (3 + FR_SIZE + 2 + 1) ;   the frame of P_TryMove

LS            .equ    (_Dp+8)         ; block list, or a thing of the block
LN            .equ    (_Dp+12)        ; line, or the function of an iterator
BM            .equ    (_Dp+16)        ; _g_blockmap or _g_blocklinks
TM            .equ    (_Dp+16)        ; the thing of P_TryMove and P_SetThingPosition

;;; PQMUL: Y = the low word, C = the high word of MA * MB (unsigned 16 x 16),
;;; the quarter squares of src/iigs/m_fixed65.s inline (its tables SQL and
;;; SQH), with no call: only the high word of sq(MA + MB) is stored (MR+2).
;;; Destroys X.
SQL           .equ    MM_SQL          ; as in src/iigs/m_fixed65.s
SQH           .equ    MM_SQH
PQMUL         .macro
              lda     dp:.tiny MA
              clc
              adc     dp:.tiny MB
              bcs     20$
              asl     a
              tax
              bcs     10$
              lda     long:SQL,x
              tay
              lda     long:SQH,x
              bra     50$
10$:          lda     long:(SQL+0x10000),x
              tay
              lda     long:(SQH+0x10000),x
              bra     50$
20$:          asl     a
              tax
              bcs     30$
              lda     long:(SQL+0x20000),x
              tay
              lda     long:(SQH+0x20000),x
              bra     50$
30$:          lda     long:(SQL+0x30000),x
              tay
              lda     long:(SQH+0x30000),x
50$:          sta     dp:.tiny (MR+2)
              lda     dp:.tiny MA
              sec
              sbc     dp:.tiny MB
              bcs     60$
              eor     ##0xffff
              inc     a
60$:          asl     a
              tax
              tya
              bcs     70$
              sec
              sbc     long:SQL,x
              tay
              lda     dp:.tiny (MR+2)
              sbc     long:SQH,x
              bra     80$
70$:          sec
              sbc     long:(SQL+0x10000),x
              tay
              lda     dp:.tiny (MR+2)
              sbc     long:(SQH+0x10000),x
80$:
              .endm

              .section znear, bss
;;; the globals of p_map.c
              .public tmthing, tmx, tmy, _g_tmbbox, _g_tmfloorz, _g_tmceilingz
              .public _g_tmdropoffz, _g_ceilingline, _g_spechit, _g_numspechit
              .public _s_sector_list, _g_linetarget, LR_OK
LR_MAX        .equ    24              ; lines of the record of lineBlocks
tmthing:      .space  4               ; the thing that moves
tmx:          .space  4
tmy:          .space  4
_g_tmbbox:    .space  16              ; its box for the line checks
_g_tmfloorz:  .space  4               ; the floor it falls to
_g_tmceilingz: .space 4               ; the ceiling of its sector
_g_tmdropoffz: .space 4               ; the floor behind the line it crosses
_g_ceilingline: .space 4
_g_spechit:   .space  16              ; the special lines it crosses
_g_numspechit: .space 2
_s_sector_list: .space 4
_g_linetarget: .space 4               ; the thing that a line attack hits
MP_TB:        .space  16              ; the box of the line checks: top, bottom, left, right
MP_PX:        .space  4               ; point of pointOnLineSide
MP_PY:        .space  4
MP_T0:        .space  4
MP_T1:        .space  4
MP_RAD:       .space  4               ; tmthing->radius
MP_S:         .space  4               ; sector of addSecnode
MP_FRONT:     .space  4
MP_BACK:      .space  4
MP_THING:     .space  4               ; the thing of P_CreateSecNodeList
MP_SAVE:      .space  4               ; its saved tmthing
MP_TMF:       .space  2               ; tmthing: a missile, it picks up (setBox)
MP_VC:        .space  2               ; validcount of the line loop
MP_MODE:      .space  2               ; 0: PIT_CheckLine, else PIT_GetSectors
LR_OK:        .space  2               ; 1: LR_LINES holds the lines of the check walk
LR_USE:       .space  2               ; 1: the next PIT_GetSectors walk takes them
LR_N:         .space  2               ; lines * 2 (a byte), 0xff: too many
LR_LINES:     .space  2 * LR_MAX      ; 2 * the line (LNSEC)
MP_MISSILE:   .space  2               ; tmthing->flags & MF_MISSILE
MP_PLAYER:    .space  2               ; tmthing is the player
MP_XL:        .space  2               ; blocks, clamped to the map
MP_XH:        .space  2
MP_YL:        .space  2
MP_YH:        .space  2
MP_BX:        .space  2
MP_BY:        .space  2
MP_IDX:       .space  2               ; block number
MP_ROW:       .space  2               ; MP_YL * _g_bmapwidth
MP_LY:        .space  2               ; position in the block list
MP_T14:       .space  2
TM_L:         .space  2               ; posMul: the byte 3 of the operand
TM_H:         .space  2
MP_V:         .space  2
MP_A:         .space  2
MP_FL:        .space  2
MP_D:         .space  2
MP_TELEFRAG:  .space  2               ; P_TeleportMove: stomp things (the player, a boss)
MP_TPT:       .space  4               ;   the thing, x, y
MP_TPX:       .space  4
MP_TPY:       .space  4
SN_FREE:      .space  4               ; the free sector nodes, linked by m_tnext
MV_SS:        .space  4               ; P_TryMove: the new subsector
MV_SEC:       .space  4               ;   its sector
MV_BLK:       .space  2               ;   the new block list, 0xffff off the map
MV_KEEP:      .space  2               ;   1: the sector list stays, 2: the block list
MV_F:         .space  2               ; mvLink: the offset of the fields
MP_CLOB:      .space  2               ; P_CheckPosition ran game logic (checkThing)
MP_TRY:       .space  2               ; P_CheckPosition from P_TryMove (a byte)
MP_RS:        .space  2               ; the thing walk: the radii (a byte), twice
MP_RS2:       .space  2               ;   the radii (a byte)

;;; Signed 32-bit a < b: lda a.lo / cmp b.lo / lda a.hi / SLT32 b.hi / bmi
SLT32         .macro  op
              sbc     \op
              bvc     1$
              eor     ##0x8000
1$:
              .endm


;;; A = A >> 7, signed: the high word of a 32-bit value >> MAPBLOCKSHIFT.
SHR7          .macro
              asl     a
              xba
              and     ##0x00ff
              bcc     1$
              ora     ##0xff00
1$:
              .endm

;;; STWC d: the direct page word d = C: its low byte, then its high byte
;;; when that changes (the compare between the stores).
STWC          .macro  d
              sep     #0x20
              sta     dp:.tiny \d
              xba
              cmp     dp:.tiny (\d+1)
              beq     1$
              sta     dp:.tiny (\d+1)
1$:           rep     #0x20
              .endm

;;; N = (A < the word at offset o of the line X), signed. Destroys A.
SLT16X        .macro  o
              sec
              sbc     abs:\o,x
              bvc     1$
              eor     ##0x8000
1$:
              .endm

;;; TEND: the end of the walk of the things: the near DBR, no frame.
TEND          .macro
              lda     ##.byte2 tmthing      ; (16-bit A: the bank as the high
              xba                           ;   byte, no SEP and REP)
              pha
              plb
              plb
              tsc
              clc
              adc     ##FR_SIZE
              tcs
              .endm


              .section znear, bss
              .public _g_opentop, _g_openbottom, _g_openrange, _g_lowfloor
;;; P_LineOpening: the opening of a two sided line.
_g_opentop:   .space  4
_g_openbottom: .space 4
_g_openrange: .space  4
_g_lowfloor:  .space  4               ; (not stored: no code reads it)

;;; The stamp that marks a line or a thing as checked in this search.
              .section near, data
              .public validcount
validcount:   .word   1

              .section code, text
;;; ---------------------------------------------------------------------------
;;; boolean P_TryMove(mobj_t __far* thing, fixed_t x, fixed_t y)
;;;   In: _Dp[0-3] = thing, X:C = x, _Dp[4-7] = y. Out: C.
;;; P_CheckPosition (checkPos) takes the thing, x and y from tmthing, tmx
;;; and tmy. Game logic in it (PIT_CheckThing) can change them: first it
;;; keeps them in the frame of P_TryMove (MP_TRY, tCheck), and they come
;;; back from there (MP_CLOB). The thing is TP ([TP],y), and the move
;;; stores bytes.
;;; ---------------------------------------------------------------------------
TT            .equ    1               ; the frame of P_TryMove: tmthing, tmx
OX            .equ    13              ;   and tmy (12 bytes), oldx, oldy
OY            .equ    17              ;   and oldside of the special lines
OS            .equ    21
TFRAME        .equ    21
SP_TT         .equ    (2 + TT)        ; (in spec, after the return address)
SP_TT1        .equ    (3 + TT)
SP_TT2        .equ    (4 + TT)
SP_OS         .equ    (2 + OS)

              .public P_TryMove
P_TryMove:    phb
              tay                           ; the frame (no writes)
              tsc
              sec
              sbc     ##TFRAME
              tcs
              tya
              jsr     .kbank cpCopy         ; tmthing, tmx, tmy
              lda     ##1                   ; (from P_TryMove; a word)
              sta     .near MP_TRY
              jsr     .kbank checkPos
              bcs     1$
              brl     tmFalse
              .space  4                     ; (the code after keeps its address)
1$:           lda     .near MP_CLOB         ; game logic ran: the thing, x, y
              beq     3$                    ;   of the frame, and their sector
              sep     #0x20
              tsc                           ; (X = S: the frame is long,X in
              tax                           ;   bank 0)
              ldy     ##0
2$:           lda     long:TT,x
              sta     .near tmthing,y
              inx
              iny
              cpy     ##12
              bne     2$
              rep     #0x20
              jsr     .kbank pointSector
              lda     ##.byte2 tmthing      ; (the near DBR: the high byte)
              xba
              pha
              plb
              plb
3$:           lda     .near tmthing         ; TP = the thing (words: no SEP and
              sta     dp:.tiny TP           ;   REP; TP+3 is PSD, set before its
              lda     .near (tmthing+2)     ;   use)
              sta     dp:.tiny (TP+2)
              ldy     ##(OFS_MO_FLAGS+1)    ; MF_NOCLIP: no height checks
              lda     [.tiny TP],y
              and     ##(CONST_MF_NOCLIP >> 8)
              beq     4$
              brl     move
4$:           lda     .near _g_tmceilingz   ; tmceilingz - tmfloorz < height
              sec
              sbc     .near _g_tmfloorz
              tax
              lda     .near (_g_tmceilingz+2)
              sbc     .near (_g_tmfloorz+2)
              jsr     .kbank lessHeight
              bcs     tmFalse
              ldy     ##OFS_MO_Z            ; tmceilingz - thing->z < height
              lda     .near _g_tmceilingz
              sec
              sbc     [.tiny TP],y
              tax
              ldy     ##(OFS_MO_Z+2)
              lda     .near (_g_tmceilingz+2)
              sbc     [.tiny TP],y
              jsr     .kbank lessHeight
              bcs     tmFalse
              ldy     ##OFS_MO_Z            ; tmfloorz - thing->z > 24 * FRACUNIT
              lda     .near _g_tmfloorz
              sec
              sbc     [.tiny TP],y
              tax
              ldy     ##(OFS_MO_Z+2)
              lda     .near (_g_tmfloorz+2)
              sbc     [.tiny TP],y
              jsr     .kbank overStep
              bcs     tmFalse
              ldy     ##OFS_MO_FLAGS        ; !MF_DROPOFF && tmfloorz -
              lda     [.tiny TP],y          ;   tmdropoffz > 24 * FRACUNIT
              and     ##CONST_MF_DROPOFF
              bne     move
              lda     .near _g_tmfloorz
              sec
              sbc     .near _g_tmdropoffz
              tax
              lda     .near (_g_tmfloorz+2)
              sbc     .near (_g_tmdropoffz+2)
              jsr     .kbank overStep
              bcc     move

tmFalse:      lda     ##0
tmRet:        tay
              tsc
              clc
              adc     ##TFRAME
              tcs
              tya
              plb
              rtl

;;; lessHeight: C = the 32-bit d < thing->height (A = its high word, X = its
;;; low word), signed.
lessHeight:   ldy     ##(OFS_MO_HEIGHT+2)
              cmp     [.tiny TP],y
              bne     1$
              txa                           ; equal high words: the low words,
              ldy     ##OFS_MO_HEIGHT       ;   unsigned (C clear: less)
              cmp     [.tiny TP],y
              rol     a
              eor     ##1
              lsr     a
              rts
1$:           sec
              sbc     [.tiny TP],y
              bvc     2$
              eor     ##0x8000
2$:           asl     a                     ; (the sign)
              rts

;;; overStep: C = the 32-bit d > 24 * FRACUNIT (A = its high word, X = its
;;; low word), signed.
overStep:     cmp     ##24
              bne     1$
              txa                           ; 24: more if the low word is not 0
              cmp     ##1
              rts
1$:           sec
              sbc     ##24
              bvc     2$
              eor     ##0x8000
2$:           eor     ##0x8000              ; (not less: more)
              asl     a
              rts

;;; move: P_UnsetThingPosition, the new place, P_SetThingPosition, as
;;; lists: the sector list and the block list of the thing, then its
;;; fields, then its node list (mvNodes); the lists touch no field, so
;;; this order gives the same memory. A list whose head is the thing and
;;; that it goes back to stays as it is.
move:         lda     .near _g_numspechit   ; oldx, oldy for special lines
              beq     4$
              sep     #0x20                 ; (rare: bytes)
              tsc                           ; (X = S: the frame is long,X in
              tax                           ;   bank 0)
              ldy     ##OFS_MO_X
3$:           lda     [.tiny TP],y
              sta     long:OX,x
              inx
              iny
              cpy     ##(OFS_MO_X+8)
              bne     3$
              rep     #0x20
4$:           ldy     ##OFS_MO_FLAGS        ; the sector list (16-bit A: words,
              lda     [.tiny TP],y          ;   no SEP and REP)
              and     ##CONST_MF_NOSECTOR
              bne     10$
              lda     .near MV_SEC          ; the head of the list of the new
              clc                           ;   sector: it stays
              adc     ##OFS_SEC_THINGLIST
              ldy     ##OFS_MO_SPREV
              cmp     [.tiny TP],y
              bne     6$
              ldy     ##(OFS_MO_SPREV+2)
              lda     [.tiny TP],y
              and     ##0x00ff
              cmp     .near (MV_SEC+2)
              beq     10$
6$:           jsr     .kbank mvSector
10$:          ldy     ##OFS_MO_FLAGS        ; the block list
              lda     [.tiny TP],y
              and     ##CONST_MF_NOBLOCKMAP
              bne     20$
              jsr     .kbank mvBlock

20$:          ldy     ##(OFS_TH_FUNCTION+2) ; the fields: not CLEAN (byte 11:
              lda     [.tiny TP],y          ;   floorz can change)
              and     ##0x00ff
              sta     [.tiny TP],y
              ldy     ##(OFS_MO_FLOORZ+10)  ; floorz, ceilingz, dropoffz: the
21$:          lda     abs:.near (_g_tmfloorz - OFS_MO_FLOORZ),y ; near globals in order
              sta     [.tiny TP],y
              dey
              dey
              cpy     ##OFS_MO_FLOORZ
              bcs     21$
              ldy     ##(OFS_MO_X+6)        ; x, y: tmx, tmy
22$:          lda     abs:.near (tmx - OFS_MO_X),y
              sta     [.tiny TP],y
              dey
              dey
              cpy     ##OFS_MO_X
              bcs     22$
              ldy     ##(OFS_MO_SUBSECTOR+2) ; thing->subsector = ss (MV_SS+3: 0)
23$:          lda     abs:.near (MV_SS - OFS_MO_SUBSECTOR),y
              sta     [.tiny TP],y
              dey
              dey
              cpy     ##OFS_MO_SUBSECTOR
              bcs     23$
              ldy     ##OFS_MO_FLAGS        ; the node list
              lda     [.tiny TP],y
              and     ##CONST_MF_NOSECTOR
              bne     30$
              jsr     .kbank mvNodes
30$:          ldy     ##(OFS_MO_FLAGS+1)    ; the special lines that were crossed
              lda     [.tiny TP],y
              and     ##(CONST_MF_NOCLIP >> 8)
              bne     31$
              lda     .near _g_numspechit
              beq     31$
              sep     #0x20                 ; (spec: 8-bit A)
              jsr     .kbank spec
              rep     #0x20
31$:          lda     ##1
              brl     tmRet

;;; ---------------------------------------------------------------------------
;;; The parts of the move: 16-bit A, the thing TP, the near DBR (kept). A
;;; pointer of a list is two words (the fourth byte is 0); _Dp[0-3] and
;;; _Dp[4-7] hold the pointers of the neighbours. X = the offset of the
;;; next field of a list in the thing, its prev field at X + 4 (snext and
;;; sprev, bnext and bprev).
;;; ---------------------------------------------------------------------------

;;; mvSector: the thing out of its sector list and at the head of the list
;;; of MV_SEC.
mvSector:     ldx     ##OFS_MO_SNEXT
              jsr     .kbank unlist
              lda     .near MV_SEC          ; _Dp = &sector->thinglist
              clc
              adc     ##OFS_SEC_THINGLIST
              sta     dp:.tiny _Dp
              lda     .near (MV_SEC+2)
              sta     dp:.tiny (_Dp+2)
              ldx     ##OFS_MO_SNEXT
              brl     link

;;; mvBlock: the block list of tmx, tmy (off the map: none): the thing out
;;; of its list and at the head of the new one, unless it is its head.
mvBlock:      jsr     .kbank blockOf        ; C = the list (C set: none)
              bcs     5$
              ldy     ##OFS_MO_BPREV        ; its head: the list stays
              cmp     [.tiny TP],y
              bne     1$
              ldy     ##(OFS_MO_BPREV+2)
              lda     [.tiny TP],y
              eor     .near (_g_blocklinks+2)
              and     ##0x00ff
              beq     9$
1$:           ldx     ##OFS_MO_BNEXT        ; out of the old list
              jsr     .kbank unlist
              jsr     .kbank blockOf        ; _Dp = the new list
              sta     dp:.tiny _Dp
              lda     .near (_g_blocklinks+2)
              and     ##0x00ff
              sta     dp:.tiny (_Dp+2)
              ldx     ##OFS_MO_BNEXT
              brl     link
5$:           ldx     ##OFS_MO_BNEXT        ; off the map: out of the old list,
              jsr     .kbank unlist         ;   bnext = bprev = NULL
              lda     ##0
              ldy     ##(OFS_MO_BPREV+2)
6$:           sta     [.tiny TP],y
              dey
              dey
              cpy     ##OFS_MO_BNEXT
              bcs     6$
9$:           rts

;;; blockOf: C = the address of the block list of tmx, tmy in _g_blocklinks
;;; (in its bank); carry set: off the map. 16-bit A.
blockOf:      lda     .near (tmy+2)         ; blocky = (y - orgy) >> 23: a byte
              sec                           ;   with its sign in the carry
              sbc     .near (_g_bmaporgy+2)
              asl     a
              xba
              bcs     9$
              and     ##0x00ff              ; (16-bit A: no SEP and REP)
              cmp     .near _g_bmapheight
              bcs     9$
              asl     a
              tax
              lda     .near (tmx+2)         ; blockx
              sec
              sbc     .near (_g_bmaporgx+2)
              asl     a
              xba
              bcs     9$
              and     ##0x00ff
              cmp     .near _g_bmapwidth
              bcs     9$
              clc                           ; 4 * (blocky * width + blockx)
              adc     long:BMROW,x
              asl     a
              asl     a
              clc
              adc     .near _g_blocklinks
              clc
              rts
9$:           sec
              rts
              .space  10                    ; (the code after keeps its address)

;;; unlist: the thing out of a list: if prev, *prev = next and if next,
;;; next->prev = prev.
unlist:       txy                           ; _Dp[4-7] = next, _Dp[0-3] = prev
              lda     [.tiny TP],y
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     [.tiny TP],y
              sta     dp:.tiny (_Dp+6)
              iny
              iny
              lda     [.tiny TP],y
              sta     dp:.tiny _Dp
              iny
              iny
              lda     [.tiny TP],y
              and     ##0x00ff
              beq     9$                    ; (no prev: bank 0)
              sta     dp:.tiny (_Dp+2)
              lda     dp:.tiny (_Dp+4)      ; *prev = next
              sta     [.tiny _Dp]
              ldy     ##2
              lda     dp:.tiny (_Dp+6)
              sta     [.tiny _Dp],y
              and     ##0x00ff
              beq     9$                    ; (no next)
              txa                           ; next->prev = prev
              clc
              adc     ##4
              tay
              lda     dp:.tiny _Dp
              sta     [.tiny (_Dp+4)],y
              iny
              iny
              lda     dp:.tiny (_Dp+2)
              sta     [.tiny (_Dp+4)],y
9$:           rts

;;; link: the thing at the head of the list whose head is at _Dp[0-2]:
;;; next = head, thing->next = next, if next, next->prev = &thing->next,
;;; thing->prev = &head, head = thing.
link:         lda     [.tiny _Dp]           ; _Dp[4-7] = next = the head
              sta     dp:.tiny (_Dp+4)
              ldy     ##2
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              txy                           ; thing->next = next
              lda     dp:.tiny (_Dp+4)
              sta     [.tiny TP],y
              iny
              iny
              lda     dp:.tiny (_Dp+6)
              sta     [.tiny TP],y
              and     ##0x00ff
              beq     1$                    ; (no next)
              txa                           ; next->prev = &thing->next
              clc
              adc     ##4
              tay
              txa
              clc
              adc     dp:.tiny TP
              sta     [.tiny (_Dp+4)],y
              iny
              iny
              lda     dp:.tiny (TP+2)       ; (TP+3 is PSD: the bank only)
              and     ##0x00ff
              sta     [.tiny (_Dp+4)],y
1$:           txa                           ; thing->prev = &head
              clc
              adc     ##4
              tay
              lda     dp:.tiny _Dp
              sta     [.tiny TP],y
              iny
              iny
              lda     dp:.tiny (_Dp+2)
              and     ##0x00ff
              sta     [.tiny TP],y
              lda     dp:.tiny TP           ; head = thing
              sta     [.tiny _Dp]
              ldy     ##2
              lda     dp:.tiny (TP+2)
              and     ##0x00ff
              sta     [.tiny _Dp],y
              rts

;;; ---------------------------------------------------------------------------
;;; void P_UnsetThingPosition(mobj_t __far* thing)         In: _Dp[0-3].
;;; The thing out of its sector list (unless MF_NOSECTOR), its node list
;;; to _s_sector_list (P_SetSeclist), and out of its block list (unless
;;; MF_NOBLOCKMAP): unlist, with TP = the thing (P_TryMove takes TP again
;;; from its frame after game logic). Words.
;;; ---------------------------------------------------------------------------
              .public P_UnsetThingPosition
P_UnsetThingPosition:
              lda     dp:.tiny _Dp          ; TP = the thing (words: no SEP and
              sta     dp:.tiny TP           ;   REP; TP+3 is PSD, set before its
              lda     dp:.tiny (_Dp+2)      ;   use)
              sta     dp:.tiny (TP+2)
              ldy     ##OFS_MO_FLAGS        ; (the flags of the low word)
              lda     [.tiny TP],y
              sta     .near MP_FL
              and     ##CONST_MF_NOSECTOR
              bne     2$
              ldx     ##OFS_MO_SNEXT        ; out of the sector list
              jsr     .kbank unlist
              ldy     ##OFS_MO_TOUCHING     ; P_SetSeclist(thing->touching_sectorlist),
              lda     [.tiny TP],y          ;   thing->touching_sectorlist = NULL
              sta     .near _s_sector_list  ;   (bytes 3 are 0)
              lda     ##0
              sta     [.tiny TP],y
              iny
              iny
              lda     [.tiny TP],y
              sta     .near (_s_sector_list+2)
              lda     ##0
              sta     [.tiny TP],y
2$:           lda     .near MP_FL           ; out of the block list (bprev NULL:
              and     ##CONST_MF_NOBLOCKMAP ;   in none)
              bne     9$
              ldx     ##OFS_MO_BNEXT
              jsr     .kbank unlist
9$:           rtl

;;; ---------------------------------------------------------------------------
;;; void P_SetThingPosition(mobj_t __far* thing)           In: _Dp[0-3].
;;; thing->subsector = R_PointInSubsector(thing->x, thing->y); unless
;;; MF_NOSECTOR the thing at the head of the list of its sector, then its
;;; node list (P_CreateSecNodeList); unless MF_NOBLOCKMAP at the head of
;;; the list of its block (off the map: bnext = bprev = NULL): link, with
;;; TP = the thing (P_TryMove takes TP again after game logic). Words.
;;; ---------------------------------------------------------------------------
              .public P_SetThingPosition
P_SetThingPosition:
              lda     dp:.tiny _Dp          ; TP = the thing (words: no SEP and
              sta     dp:.tiny TP           ;   REP)
              lda     dp:.tiny (_Dp+2)
              sta     dp:.tiny (TP+2)
              ldy     ##(OFS_MO_Y+2)        ; R_PointInSubsector(x, y): _Dp = y,
              lda     [.tiny TP],y          ;   X:C = x
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_MO_Y
              lda     [.tiny TP],y
              sta     dp:.tiny _Dp
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny TP],y
              tax
              ldy     ##OFS_MO_X
              lda     [.tiny TP],y
              jsl     long:R_PointInSubsector
              ldy     ##OFS_MO_SUBSECTOR    ; thing->subsector = ss, and _Dp
              sta     [.tiny TP],y
              sta     dp:.tiny _Dp
              txa
              and     ##0x00ff
              iny
              iny
              sta     [.tiny TP],y
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_MO_FLAGS        ; (the flags of the low word)
              lda     [.tiny TP],y
              and     ##CONST_MF_NOSECTOR
              bne     20$
              ldy     ##OFS_SUB_SECTOR      ; _Dp = &ss->sector->thinglist
              lda     [.tiny _Dp],y
              clc
              adc     ##OFS_SEC_THINGLIST
              tax
              iny
              iny
              lda     [.tiny _Dp],y
              and     ##0x00ff
              sta     dp:.tiny (_Dp+2)
              stx     dp:.tiny _Dp
              ldx     ##OFS_MO_SNEXT        ; at the head of its sector list
              jsr     .kbank link
              lda     dp:.tiny TP           ; P_CreateSecNodeList(thing)
              sta     dp:.tiny _Dp
              lda     dp:.tiny (TP+2)
              and     ##0x00ff
              sta     dp:.tiny (_Dp+2)
              jsl     long:P_CreateSecNodeList
20$:          ldy     ##OFS_MO_FLAGS        ; (the flags again)
              lda     [.tiny TP],y
              and     ##CONST_MF_NOBLOCKMAP
              bne     90$
              ldy     ##(OFS_MO_Y+2)        ; blocky = (y - orgy) >> 23: a byte,
              lda     [.tiny TP],y          ;   its sign in the carry (the low
              sec                           ;   words of the origin are 0)
              sbc     .near (_g_bmaporgy+2)
              asl     a
              xba
              bcs     30$
              and     ##0x00ff
              cmp     .near _g_bmapheight
              bcs     30$
              asl     a
              tax
              ldy     ##(OFS_MO_X+2)        ; blockx
              lda     [.tiny TP],y
              sec
              sbc     .near (_g_bmaporgx+2)
              asl     a
              xba
              bcs     30$
              and     ##0x00ff
              cmp     .near _g_bmapwidth
              bcs     30$
              clc                           ; _Dp = &_g_blocklinks[blocky *
              adc     long:BMROW,x          ;   width + blockx] (BMROW)
              asl     a
              asl     a
              clc
              adc     .near _g_blocklinks
              sta     dp:.tiny _Dp
              lda     .near (_g_blocklinks+2)
              and     ##0x00ff
              sta     dp:.tiny (_Dp+2)
              ldx     ##OFS_MO_BNEXT        ; at the head of its block list
              jsr     .kbank link
              rtl
30$:          lda     ##0                   ; off the map: bnext = bprev = NULL
              ldy     ##(OFS_MO_BPREV+2)
31$:          sta     [.tiny TP],y
              dey
              dey
              cpy     ##OFS_MO_BNEXT
              bcs     31$
90$:          rtl

;;; mvNodes: the node list of the thing at its new place (after its sector
;;; list), as P_CreateSecNodeList(thing) after the node part of
;;; P_UnsetThingPosition. When no game logic ran in P_CheckPosition, its
;;; box is the box of the thing at x, y and its check walk ended: the
;;; PIT_GetSectors walk takes the lines of its record (LR_USE); and when
;;; the box crosses no lines and the thing has one node, of its new sector,
;;; the list stays as it is: the new list would be the same.
mvNodes:      lda     .near MP_CLOB         ; (16-bit A: words, no SEP and REP)
              bne     9$
              lda     .near LR_OK
              beq     9$
              lda     .near LR_N
              bne     8$
              ldy     ##(OFS_MO_TOUCHING+2) ; one node (_Dp): not NULL, no
              lda     [.tiny TP],y          ;   m_tnext, of the new sector
              and     ##0x00ff
              beq     8$
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_MO_TOUCHING
              lda     [.tiny TP],y
              sta     dp:.tiny _Dp
              ldy     ##(OFS_SN_M_TNEXT+2)
              lda     [.tiny _Dp],y
              and     ##0x00ff
              bne     8$
              ldy     ##(OFS_SN_M_SECTOR+2)
              lda     [.tiny _Dp],y
              and     ##0x00ff
              cmp     .near (MV_SEC+2)
              bne     8$
              ldy     ##OFS_SN_M_SECTOR
              lda     [.tiny _Dp],y
              cmp     .near MV_SEC
              bne     8$
              inc     .near validcount      ; the rest that P_CreateSecNodeList
              lda     .near _s_sector_list  ;   leaves: validcount++, no list
              ora     .near (_s_sector_list+1) ;   (its bytes 0-2)
              beq     2$
              stz     .near _s_sector_list
              stz     .near (_s_sector_list+1)
2$:           rts
8$:           lda     ##1                   ; the walk takes the record
              sta     .near LR_USE
9$:           ldy     ##OFS_MO_TOUCHING     ; P_SetSeclist(thing->touching_sectorlist),
              lda     [.tiny TP],y          ;   thing->touching_sectorlist = NULL
              sta     .near _s_sector_list  ;   (bytes 3 are 0)
              lda     ##0
              sta     [.tiny TP],y
              iny
              iny
              lda     [.tiny TP],y
              sta     .near (_s_sector_list+2)
              lda     ##0
              sta     [.tiny TP],y
              lda     dp:.tiny TP           ; P_CreateSecNodeList(thing)
              sta     dp:.tiny _Dp
              lda     dp:.tiny (TP+2)
              and     ##0x00ff
              sta     dp:.tiny (_Dp+2)
              jsl     long:P_CreateSecNodeList
              rts
              .space  109                   ; (the code after keeps its address)

;;; spec: the special lines that were crossed (C: while (numspechit--)):
;;; ld = spechit[numspechit]; if ld->special and P_PointOnLineSide(thing->x,
;;; thing->y, ld) != P_PointOnLineSide(oldx, oldy, ld) (OS),
;;; P_CrossSpecialLine(ld, oldside, thing). That runs game logic: the thing
;;; is in the frame (TT), and TP comes back from there. 8-bit A.
;;; specLine: _Dp[4-7] = _g_spechit[_g_numspechit]; Z clear if it has a
;;; special (8-bit A).
;;; SPECCODE: their code. With TICSTEP > 1 it comes after walkRange
;;; (see there), else before cpCopy.
SPECCODE      .macro
spec:         lda     dp:.tiny TP           ; the thing in the frame
              sta     SP_TT,s
              lda     dp:.tiny (TP+1)
              sta     SP_TT1,s
              lda     dp:.tiny (TP+2)
              sta     SP_TT2,s
1$:           lda     .near _g_numspechit   ; while (numspechit--)
              dec     a
              sta     .near _g_numspechit
              cmp     #0xff
              bne     2$
              sta     .near (_g_numspechit+1) ; (-1: the high byte too)
              rts
2$:           jsr     .kbank specLine       ; _Dp[4-7] = ld, C = ld->special
              beq     1$
              tsc                           ; oldside = P_PointOnLineSide(oldx,
              tax                           ;   oldy, ld)
              lda     long:(2+OY),x
              sta     dp:.tiny _Dp
              lda     long:(3+OY),x
              sta     dp:.tiny (_Dp+1)
              lda     long:(4+OY),x
              sta     dp:.tiny (_Dp+2)
              lda     long:(5+OY),x
              sta     dp:.tiny (_Dp+3)
              rep     #0x20
              lda     long:(2+OX),x
              tay
              lda     long:(4+OX),x
              tax
              tya
              jsl     long:P_PointOnLineSide
              sep     #0x20
              sta     SP_OS,s
              jsr     .kbank specLine       ; != P_PointOnLineSide(thing->x,
              ldy     ##OFS_MO_Y            ;   thing->y, ld)
              lda     [.tiny TP],y
              sta     dp:.tiny _Dp
              iny
              lda     [.tiny TP],y
              sta     dp:.tiny (_Dp+1)
              iny
              lda     [.tiny TP],y
              sta     dp:.tiny (_Dp+2)
              iny
              lda     [.tiny TP],y
              sta     dp:.tiny (_Dp+3)
              rep     #0x20
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny TP],y
              tax
              ldy     ##OFS_MO_X
              lda     [.tiny TP],y
              jsl     long:P_PointOnLineSide
              sep     #0x20
              cmp     SP_OS,s
              beq     1$
              jsr     .kbank specLine       ; P_CrossSpecialLine(ld, oldside,
              lda     dp:.tiny (_Dp+4)      ;   thing): _Dp[0-3] = ld,
              sta     dp:.tiny _Dp          ;   _Dp[4-7] = the thing
              lda     dp:.tiny (_Dp+5)
              sta     dp:.tiny (_Dp+1)
              lda     dp:.tiny (_Dp+6)
              sta     dp:.tiny (_Dp+2)
              lda     dp:.tiny (_Dp+7)
              sta     dp:.tiny (_Dp+3)
              lda     dp:.tiny TP
              sta     dp:.tiny (_Dp+4)
              lda     dp:.tiny (TP+1)
              sta     dp:.tiny (_Dp+5)
              lda     dp:.tiny (TP+2)
              sta     dp:.tiny (_Dp+6)
              stz     dp:.tiny (_Dp+7)
              rep     #0x20
              lda     SP_OS,s
              and     ##0x00ff
              jsl     long:P_CrossSpecialLine
              sep     #0x20
              lda     SP_TT,s               ; TP again
              sta     dp:.tiny TP
              lda     SP_TT1,s
              sta     dp:.tiny (TP+1)
              lda     SP_TT2,s
              sta     dp:.tiny (TP+2)
              brl     1$
specLine:     rep     #0x20
              lda     .near _g_numspechit
              and     ##0x00ff
              asl     a
              asl     a
              tax
              sep     #0x20
              lda     .near _g_spechit,x
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_spechit+1),x
              sta     dp:.tiny (_Dp+5)
              lda     .near (_g_spechit+2),x
              sta     dp:.tiny (_Dp+6)
              lda     .near (_g_spechit+3),x
              sta     dp:.tiny (_Dp+7)
              rep     #0x20
              ldy     ##OFS_LINE_SPECIAL
              lda     [.tiny (_Dp+4)],y
              sep     #0x20
              rts
              .endm
;;; ---------------------------------------------------------------------------
;;; walkRange: the blocks of the box _g_tmbbox grown by X whole units,
;;; clamped to the map, in the walk frame of the caller (after the return
;;; address): FR_BX = xl, FR_XH, FR_YL and FR_YH. Out: C = 1: no blocks.
;;; The C loops skip the blocks outside the map, so the clamp keeps their
;;; order. The origin of the blockmap is whole units, and P_InitBlockRows
;;; keeps a map below 256 columns and rows: the block of an edge is bits
;;; 7..15 of (edge - origin) >> 16, a byte with its sign in the carry.
;;; ---------------------------------------------------------------------------
WR_BX         .equ    (2 + FR_BX)     ; (after the return address)
WR_XH         .equ    (2 + FR_XH)
WR_YH         .equ    (2 + FR_YH)
WR_YL         .equ    (2 + FR_YL)
walkRange:    txa                           ; xh = (right - orgx + d) >> 23
              clc
              adc     .near (_g_tmbbox + 4*CONST_BOXRIGHT + 2)
              sec
              sbc     .near (_g_bmaporgx+2)
              asl     a
              xba
              bcs     9$                    ; (left of the map)
              and     ##0x00ff
              cmp     .near _g_bmapwidth
              bcc     1$
              lda     .near _g_bmapwidth
              dec     a
1$:           sta     WR_XH,s               ; words, no SEP and REP (a bus cycle
              txa                           ;   each): the byte after each store
              eor     ##0xffff              ;   is set later (FR_LY in lHit) or 0
              sec                           ; xl = (left - orgx - d) >> 23
              adc     .near (_g_tmbbox + 4*CONST_BOXLEFT + 2)
              sec
              sbc     .near (_g_bmaporgx+2)
              asl     a
              xba
              bcc     2$
              lda     ##0
2$:           and     ##0x00ff
              cmp     .near _g_bmapwidth
              bcs     9$                    ; (right of the map)
              sta     WR_BX,s
              txa                           ; yh = (top - orgy + d) >> 23
              clc
              adc     .near (_g_tmbbox + 4*CONST_BOXTOP + 2)
              sec
              sbc     .near (_g_bmaporgy+2)
              asl     a
              xba
              bcs     9$
              and     ##0x00ff
              cmp     .near _g_bmapheight
              bcc     3$
              lda     .near _g_bmapheight
              dec     a
3$:           sta     WR_YH,s
              txa                           ; yl = (bottom - orgy - d) >> 23
              eor     ##0xffff
              sec
              adc     .near (_g_tmbbox + 4*CONST_BOXBOTTOM + 2)
              sec
              sbc     .near (_g_bmaporgy+2)
              asl     a
              xba
              bcc     4$
              lda     ##0
4$:           and     ##0x00ff
              cmp     .near _g_bmapheight
              bcs     9$
              sta     WR_YL,s
              clc
              rts
9$:           sec
              rts
              .space  4                     ; (the code after keeps its address)

#if TICSTEP > 1
;;; spec and specLine, cold code (a move that crosses a special line), in
;;; the cache slots of the pointers to the level (src/iigs/p_setup65.s:
;;; _g_lines, _g_blockmap, _g_bmaporgx and the others), which the moves
;;; read: walkRange, before them, no longer takes those slots.
              SPECCODE
#endif

;;; ---------------------------------------------------------------------------
;;; getSectors: the rest of PIT_GetSectors for a line that the box crosses,
;;; X = 2 * the line (LNSEC): its front sector, then its back sector if it
;;; is another one (LNSEC gives the front sector twice for a one sided
;;; line), each by addSecnode. GSF, GSB: the two sector numbers.
;;; addSecnode: P_AddSecnode(the sector A (a number), tmthing): the node of
;;; the thing thread _s_sector_list for the sector gets m_thing = tmthing
;;; again (words); a sector without one gets a new node
;;; (newSecnode). The walk keeps DBR = the bank of the node, X = the node
;;; and Y = the low word of the address of the sector. Out: the near DBR.
;;; ---------------------------------------------------------------------------
getSectors:   lda     long:LNSEC,x          ; GSF, GSB: the front and back sectors
              sta     dp:.tiny GSF          ;   (a word: no SEP and REP)
              jsr     .kbank addSecnode
              lda     dp:.tiny GSF          ; the back sector if it is another
              xba
              eor     dp:.tiny GSF
              and     ##0x00ff
              beq     1$
              lda     dp:.tiny GSB
              bra     addSecnode
1$:           rts

addSecnode:   and     ##0x00ff              ; Y = its address (SEC58)
              asl     a
              tax
              lda     long:SEC58,x
              tay
              ldx     .near _s_sector_list  ; the first node (a NULL has bank 0)
              lda     .near (_s_sector_list+1) ; (16-bit A: the bank as the high
              and     ##0xff00              ;   byte, no SEP and REP)
              beq     5$
              pha                           ; DBR = the bank of the node
              plb
              plb
2$:           tya
              cmp     abs:OFS_SN_M_SECTOR,x ; (the sectors share a bank)
              beq     3$
              lda     abs:(OFS_SN_M_TNEXT+1),x ; the next node: DBR = its bank
              and     ##0xff00
              beq     5$
              pha
              lda     abs:OFS_SN_M_TNEXT,x
              tax
              plb
              plb
              bra     2$
3$:           lda     long:(tmthing+2)      ; m_thing = tmthing (words; bytes 3
              sta     abs:(OFS_SN_M_THING+2),x ;   are 0)
              lda     long:tmthing
              sta     abs:OFS_SN_M_THING,x
              lda     ##.byte2 tmthing      ; the near DBR (the high byte)
              xba
              pha
              plb
              plb
              rts
5$:           lda     ##.byte2 tmthing      ; no node: MP_S = the sector,
              xba                           ;   newSecnode (the near DBR)
              pha
              plb
              plb
              sty     .near MP_S
              lda     .near (_g_sectors+2)
              and     ##0x00ff
              sta     .near (MP_S+2)
              jsl     long:newSecnode
              rts
              .space  28                    ; (the code after keeps its address)

addSecnodeL:  jsr     .kbank addSecnode
              rtl

;;; ---------------------------------------------------------------------------
;;; boolean P_CheckPosition(mobj_t __far* thing, fixed_t x, fixed_t y)
;;;   In: _Dp[0-3] = thing, X:C = x, _Dp[4-7] = y. Out: C.
;;; tmx, tmy and tmthing are only of this file (tmthing keeps its fourth
;;; byte 0). checkPos: the check of tmthing at tmx, tmy (Out: carry). The
;;; walk of the things keeps DBR = the bank of the thing and X = the thing
;;; (abs,X); the blocks are in the walk frame on the stack, which lives
;;; across the game logic that PIT_CheckThing can run.
;;; ---------------------------------------------------------------------------
              .public P_CheckPosition
P_CheckPosition:
              jsr     .kbank cpCopy         ; tmthing, tmx, tmy
              stz     .near MP_TRY          ; (not from P_TryMove; a word)
              jsr     .kbank checkPos
              lda     ##0
              rol     a
              rtl
              .space  4                     ; (the code after keeps its address)

;;; loadRad: MP_RAD = tmthing->radius (8-bit A; a radius is whole units
;;; below 256, so only the byte 2 of MP_RAD changes).
loadRad:      phb
              ldx     .near tmthing
              lda     .near (tmthing+2)
              pha
              plb
              lda     abs:(OFS_MO_RADIUS+2),x
              plb
              sta     .near (MP_RAD+2)
              rts

;;; The cold code takes the cache slots of the data that the moves read:
;;; P_CheckPosition, loadRad and spec those of _g_player
;;; (src/iigs/g_game65.s), boxOnLineSide those of the pointers to the
;;; level (_g_lines, _g_blockmap and the others of src/iigs/p_setup65.s).
#if TICSTEP > 1
              ;; (spec and specLine: after walkRange)
#else
              SPECCODE
#endif

;;; cpCopy: tmthing = _Dp[0-3], tmx = X:C, tmy = _Dp[4-7].
cpCopy:       sta     .near tmx             ; tmx = x, tmy = y, tmthing = thing:
              stx     .near (tmx+2)         ;   words, no SEP and REP
              lda     dp:.tiny (_Dp+4)
              sta     .near tmy
              lda     dp:.tiny (_Dp+6)
              sta     .near (tmy+2)
              lda     dp:.tiny _Dp
              sta     .near tmthing
              lda     dp:.tiny (_Dp+2)      ; (the byte 3 of tmthing stays 0)
              and     ##0x00ff
              sta     .near (tmthing+2)
              rts
              .space  36                    ; (the code after keeps its address)

;;; ---------------------------------------------------------------------------
;;; setBox: _g_tmbbox = tmx, tmy -/+ the radius of the thing _Dp[0-3], which
;;; is tmthing, and MP_RAD = that radius. A radius is whole units below 256
;;; (mobjinfo, 0 for crushed gibs): the low words of the box are those of
;;; tmx, tmy, and the high word of MP_RAD is the radius.
;;; setBoxL: the same for JSL.
;;; ---------------------------------------------------------------------------
setBoxL:      jsr     .kbank setBox
              rtl
setBox:       ldy     ##(OFS_MO_FLAGS+2)    ; MP_TMF (tCheck): bit 15 the thing is
              lda     [.tiny _Dp],y         ;   a missile, bit 2 it picks up
              lsr     a                     ;   (words: no SEP and REP)
              ldy     ##(OFS_MO_FLAGS+1)
              lda     [.tiny _Dp],y
              and     ##(CONST_MF_PICKUP_LO >> 8)
              ror     a
              sta     .near MP_TMF
              ldy     ##(OFS_MO_RADIUS+2)
              lda     [.tiny _Dp],y
              sta     .near (MP_RAD+2)
              lda     .near tmy             ; the low words
              sta     .near (_g_tmbbox + 4*CONST_BOXTOP)
              sta     .near (_g_tmbbox + 4*CONST_BOXBOTTOM)
              lda     .near tmx
              sta     .near (_g_tmbbox + 4*CONST_BOXRIGHT)
              sta     .near (_g_tmbbox + 4*CONST_BOXLEFT)
              lda     .near (tmy+2)         ; top = y + radius (the high words)
              clc
              adc     .near (MP_RAD+2)
              sta     .near (_g_tmbbox + 4*CONST_BOXTOP + 2)
              lda     .near (tmy+2)         ; bottom = y - radius
              sec
              sbc     .near (MP_RAD+2)
              sta     .near (_g_tmbbox + 4*CONST_BOXBOTTOM + 2)
              lda     .near (tmx+2)         ; right = x + radius
              clc
              adc     .near (MP_RAD+2)
              sta     .near (_g_tmbbox + 4*CONST_BOXRIGHT + 2)
              lda     .near (tmx+2)         ; left = x - radius
              sec
              sbc     .near (MP_RAD+2)
              sta     .near (_g_tmbbox + 4*CONST_BOXLEFT + 2)
              rts
              .space  65                    ; (the code after keeps its address)

;;; ---------------------------------------------------------------------------
;;; boxOnLineSide: A = P_BoxOnLineSide(MP_TB, WK_LN) in C: 0, 1, or -1 when
;;; the box crosses the line (for P_BoxOnLineSide: it returns with RTL).
;;; ---------------------------------------------------------------------------
boxOnLineSide:
              ldy     ##OFS_LINE_SLOPETYPE
              lda     [.tiny WK_LN],y
              and     ##0x00ff
              cmp     ##CONST_ST_POSITIVE
              bcc     1$
              lda     ##.word0 box1               ; the corners (slanted, box1, box2)
              brl     slanted
1$:           cmp     ##CONST_ST_VERTICAL
              beq     vertical

              ;; default, ST_HORIZONTAL:
              ;; (bottom > v1.y << 16) == (p = top > v1.y << 16) ? p ^ (dx < 0) : -1
horizontal:   ldy     ##(OFS_LINE_V1+2)
              lda     .near (MP_TB + 4*CONST_BOXBOTTOM + 2)
              ldx     .near (MP_TB + 4*CONST_BOXBOTTOM)
              jsr     .kbank above
              lda     .near (MP_TB + 4*CONST_BOXTOP + 2)
              ldx     .near (MP_TB + 4*CONST_BOXTOP)
              bcs     1$
              jsr     .kbank above          ; bottom not above: top not above
              bcs     crosses
              lda     ##0
              bra     2$
1$:           jsr     .kbank above          ; bottom above: top above
              bcc     crosses
              lda     ##1
2$:           tax                           ; ^ (dx < 0)
              ldy     ##OFS_LINE_DX
              lda     [.tiny WK_LN],y
              bpl     3$
              txa
              eor     ##1
              rtl
3$:           txa
              rtl

crosses:      lda     ##0xffff
              rtl

;;; above: C = 1 if the fixed_t A:X (A its high word, X its low word) >
;;; the whole units [WK_LN],Y << 16.
above:        sec
              sbc     [.tiny WK_LN],y
              beq     2$
              bvc     1$
              eor     ##0x8000
1$:           asl     a                     ; C = negative: not above
              bcs     3$
              sec
              rts
2$:           txa                           ; the same whole part: a fraction
              cmp     ##1
              rts
3$:           clc
              rts

              ;; ST_VERTICAL:
              ;; (left < v1.x << 16) == (p = right < v1.x << 16) ? p ^ (dy < 0) : -1
              ;; (x < v1.x << 16 is x.hi < v1.x)
vertical:     ldy     ##OFS_LINE_V1
              lda     .near (MP_TB + 4*CONST_BOXLEFT + 2)
              sec
              sbc     [.tiny WK_LN],y
              bvc     1$
              eor     ##0x8000
1$:           tax                           ; X: N = left < v1.x
              lda     .near (MP_TB + 4*CONST_BOXRIGHT + 2)
              sec
              sbc     [.tiny WK_LN],y
              bvc     2$
              eor     ##0x8000
2$:           asl     a                     ; C = right < v1.x
              txa
              bmi     4$
              bcs     crosses               ; left not, right less
              lda     ##0
              bra     5$
4$:           bcc     crosses
              lda     ##1
5$:           tax                           ; ^ (dy < 0)
              ldy     ##OFS_LINE_DY
              lda     [.tiny WK_LN],y
              bpl     6$
              txa
              eor     ##1
              rtl
6$:           txa
              rtl

checkPos:     jsr     .kbank setBox         ; (the thing is _Dp)
              lda     .near MP_CLOB         ; (no game logic yet)
              beq     1$
              stz     .near MP_CLOB
1$:           lda     .near MP_TRY          ; the sector at x, y: for P_TryMove
              bne     2$                    ;   after the things (lines), as a
              jsr     .kbank sectorFloor    ;   thing that blocks fails the move
2$:           jsr     .kbank baseLite       ; no lines yet

              phb                           ; MF_NOCLIP: no checks (DBR = the
              ldx     .near tmthing         ;   bank of the thing, the high byte
              lda     .near (tmthing+1)     ;   of this word)
              pha
              plb
              plb
              lda     abs:(OFS_MO_FLAGS+1),x
              plb
              and     ##(CONST_MF_NOCLIP >> 8)
              beq     things8
              stz     .near LR_OK           ; (no record)
              lda     .near MP_TRY          ; (the sector of the move)
              beq     3$
              jsr     .kbank sectorFloor
3$:           sec
              rts
              .space  6                     ; (the code after keeps its address)

              ;; the things in the blocks of the box grown by MAXRADIUS,
              ;; 16-bit A: word stores cost less than a SEP and REP
things8:      lda     ##0xffff              ; WK_PR: no radius yet
              sta     dp:.tiny WK_PR
              tsc                           ; the walk frame: the high bytes of
              sec                           ;   bx and by are 0, FR_TRY: from
              sbc     ##FR_SIZE             ;   P_TryMove (tCheck keeps its
              tcs                           ;   thing, x, y), the last byte: a
              lda     .near MP_TRY          ;   word with FR_LY1
              xba
              sta     FR_LY1,s
              lda     ##0
              sta     FR_BX1,s
              sta     FR_BY1,s
              ldx     ##32
              jsr     .kbank walkRange
              bcc     1$
              brl     tDone
1$:           lda     .near _g_blocklinks   ; WK_BL = _g_blocklinks
              sta     dp:.tiny WK_BL
              lda     .near (_g_blocklinks+2)
              sta     dp:.tiny (WK_BL+2)
              bra     tCol

;;; tNextBlk: the next block of the column, or the next column (FR_YH,
;;; FR_XH and FR_YL are bytes).
tNextBlk:     lda     FR_YH,s
              and     ##0x00ff
              cmp     FR_BY,s
              beq     1$
              lda     FR_BY,s
              inc     a
              sta     FR_BY,s
              bra     tBlk
1$:           lda     FR_XH,s
              and     ##0x00ff
              cmp     FR_BX,s
              bne     2$
              brl     tDone
2$:           lda     FR_BX,s
              inc     a
              sta     FR_BX,s
tCol:         lda     FR_YL,s               ; a column: by = yl
              and     ##0x00ff
              sta     FR_BY,s
tBlk:         asl     a                     ; the block by * width + bx (A = by)
              tax
              lda     long:BMROW,x
              clc
              adc     FR_BX,s
              asl     a
              asl     a
              tay
              iny
              iny
              lda     [.tiny WK_BL],y       ; mobj = _g_blocklinks[block]: the
              and     ##0x00ff              ;   bank of its first thing (0: none)
              beq     tNextBlk
              sta     dp:.tiny WK_TB        ; DBR = the bank of the thing
              xba
              pha
              plb
              plb
              dey
              dey
              lda     [.tiny WK_BL],y
              tax

;;; tThing: X = the thing, DBR = its bank (WK_TB), 16-bit A. PIT_CheckThing
;;; returns true without side effects for tmthing, for a thing that is not
;;; solid, special or shootable, and for a thing that is too far:
;;; |thing->x - tmx| or |thing->y - tmy| >= the sum of the radii (MP_RS).
;;; Radii are whole units below 256. With h the difference of the high
;;; words, 0 < h + r < 2*r is inside, even with a fractional borrow.
;;; Only h = -r or +r needs the low words; zero radii never overlap.
tThing:       lda     abs:OFS_MO_FLAGS,x
              and     ##(CONST_MF_SOLID_LO | CONST_MF_SPECIAL_LO | CONST_MF_SHOOTABLE_LO)
              beq     tSkip
              lda     abs:(OFS_MO_RADIUS+2),x ; the radii, when this one is new
              cmp     dp:.tiny WK_PR        ;   (words: the radii are below 256)
              beq     1$
              sta     dp:.tiny WK_PR
              clc
              adc     long:(MP_RAD+2)
              sta     long:MP_RS
              asl     a
              sta     long:MP_RS2
1$:           txa                           ; tmthing
              cmp     long:tmthing
              bne     2$
              lda     dp:.tiny WK_TB        ; (its high byte is not always 0
              and     ##0x00ff              ;   after tCheck)
              cmp     long:(tmthing+2)
              beq     tSkip
2$:           lda     abs:(OFS_MO_X+2),x    ; whole units settle all but
              sec                           ; the two fractional boundaries
              sbc     long:(tmx+2)
              clc
              adc     long:MP_RS
              beq     tEdgeX
              cmp     long:MP_RS2
              bcc     tInX
              bne     tSkip
              lda     abs:OFS_MO_X,x        ; +r: only a fractional borrow is in
              cmp     long:tmx
              bcs     tSkip
tInX:         lda     abs:(OFS_MO_Y+2),x
              sec
              sbc     long:(tmy+2)
              clc
              adc     long:MP_RS
              beq     tEdgeYJump
              cmp     long:MP_RS2
              bcc     tCheck
              bne     tNext
              lda     abs:OFS_MO_Y,x
              cmp     long:tmy
              bcc     tCheck
tSkip:
tNext:        ldy     abs:OFS_MO_BNEXT,x    ; mobj = mobj->bnext: its bank
              lda     abs:(OFS_MO_BNEXT+2),x ;   (0: none)
              and     ##0x00ff
              bne     3$
              brl     tNextBlk
3$:           cmp     dp:.tiny WK_TB
              beq     4$
              sta     dp:.tiny WK_TB        ; another bank: DBR
              xba
              pha
              plb
              plb
4$:           tyx
              brl     tThing
tEdgeX:       lda     abs:OFS_MO_X,x        ; -r: the fraction must be above x
              cmp     long:tmx
              bcc     tSkip
              beq     tSkip
              lda     long:MP_RS2           ; zero radii never overlap
              beq     tSkip
              brl     tInX
tEdgeYJump:   brl     tEdgeY
              .space  3                     ; tCheck keeps its address

;;; tCheck: the rest of PIT_CheckThing (checkThing) for the thing X in bank
;;; WK_TB (its DBR). When tmthing is no missile and picks nothing up here,
;;; no game logic runs: the thing blocks when it is solid. Else checkThing,
;;; which can run game logic, so the thing goes on the stack.
tCheck:       lda     long:MP_TMF           ; (a word: bit 15 the missile)
              sep     #0x20
              bmi     90$                   ; a missile
              beq     91$                   ; picks up: a special thing
              lda     abs:OFS_MO_FLAGS,x
              and     #CONST_MF_SPECIAL_LO
              bne     90$
91$:          lda     abs:OFS_MO_FLAGS,x    ; !(flags & MF_SOLID)
              and     #CONST_MF_SOLID_LO
              rep     #0x20
              beq     92$
              brl     tFalse
92$:          brl     tNext
90$:          sep     #0x20                 ; the thing on the stack (bank, then
              lda     dp:.tiny WK_TB        ;   X), and _Dp = the thing
              pha
              sta     dp:.tiny (_Dp+2)
              rep     #0x20
              txa
              sep     #0x20
              sta     dp:.tiny _Dp
              xba
              pha
              sta     dp:.tiny (_Dp+1)
              xba
              pha
              stz     dp:.tiny (_Dp+3)
              lda     #.byte2 tmthing       ; the near DBR
              pha
              plb
              lda     TC_TRY,s              ; the first game logic of a walk
              beq     2$                    ;   from P_TryMove: its thing, x, y
              lda     #0                    ;   (tmthing, tmx, tmy) in its frame
              sta     TC_TRY,s
              rep     #0x20
              tsc
              tax
              sep     #0x20
              ldy     ##0
1$:           lda     .near tmthing,y
              sta     long:TC_TT,x
              inx
              iny
              cpy     ##12
              bne     1$
2$:           rep     #0x20
              jsl     long:checkThing
              tay                           ; (the result)
              sep     #0x20
              lda     #1                    ; game logic ran: tmthing, tmx,
              sta     .near MP_CLOB         ;   tmy and the box can differ
              lda     .near _g_blocklinks   ; WK_BL again
              sta     dp:.tiny WK_BL
              lda     .near (_g_blocklinks+1)
              sta     dp:.tiny (WK_BL+1)
              lda     .near (_g_blocklinks+2)
              sta     dp:.tiny (WK_BL+2)
              jsr     .kbank loadRad        ; the C code reads tmthing again
              lda     #0xff                 ; (the radii again)
              sta     dp:.tiny WK_PR
              pla                           ; X = the thing, DBR = its bank
              xba
              pla
              xba
              rep     #0x20
              tax
              sep     #0x20
              pla
              pha
              plb
              sta     dp:.tiny WK_TB
              rep     #0x20
              tya
              beq     tFalse
              brl     tNext

tFalse:       TEND
              bra     cpFalse
              .space  1                     ; (the code after keeps its address)
              .space  3                     ; (the code after keeps its address)
tDone:        TEND

              ;; the lines; C code above can change tmthing. The sector of
              ;; P_TryMove first: game logic that goes on with the walk only
              ;; picks up things, which changes no tmx, tmy or floor.
lines:        lda     .near MP_TRY
              beq     5$
              jsr     .kbank sectorFloor
5$:           phb                           ; MP_MISSILE = tmthing is a missile
              ldx     .near tmthing         ;   (DBR = its bank, the high byte)
              lda     .near (tmthing+1)
              pha
              plb
              plb
              lda     abs:(OFS_MO_FLAGS+2),x
              plb
              and     ##CONST_MF_MISSILE_HI
              sta     .near MP_MISSILE
              ldy     ##0                   ; MP_PLAYER = P_MobjIsPlayer(tmthing)
              txa
              cmp     .near (_g_player+OFS_PL_MO)
              bne     8$
              lda     .near (tmthing+2)
              cmp     .near (_g_player+OFS_PL_MO+2)
              bne     8$
              iny
8$:           stz     .near MP_MODE         ; PIT_CheckLine
              sty     .near MP_PLAYER
              jsl     long:lineBlocks
              bcc     cpFalse

cpTrue:       sec
              rts
cpFalse:      clc
              rts

;;; The negative Y boundary is cold; it uses the old gap after checkPos.
tEdgeY:       lda     abs:OFS_MO_Y,x
              cmp     long:tmy
              bcc     9$
              beq     9$
              lda     long:MP_RS2
              beq     9$
              brl     tCheck
9$:           brl     tNext
              .space  6                     ; lineBlocks keeps its address

;;; ---------------------------------------------------------------------------
;;; lineBlocks: P_BlockLinesIterator for each block of the box _g_tmbbox, x
;;; outer and y inner as in the C loops, with PIT_CheckLine (MP_MODE = 0)
;;; or PIT_GetSectors. validcount does not change during the walk.
;;; Out: C = 0 if a line blocks the move (PIT_CheckLine only).
;;;
;;; The walk keeps DBR = the bank of the lines and X = the line (abs,X),
;;; Y = the position in the list WK_LS, and the blocks in the walk frame;
;;; LN36 (P_InitBlockRows) gives the address of a line number. The box
;;; tests of PIT_CheckLine are compares of whole map units:
;;;   right <= bbox[left] << 16   is  (right >> 16) - (low word == 0) < bbox[left]
;;;   left >= bbox[right] << 16   is  (left >> 16) >= bbox[right]
;;; and the same for top and bottom (WK_*, once a walk). A right or top
;;; edge of exactly -32768.0 is left of or under every line: then WK_BH
;;; = 32767 takes them all out. A horizontal or vertical line that passes
;;; them crosses the box; a slanted one takes P_BoxOnLineSide (crossLine).
;;;
;;; The lines that the box crosses depend only on the box, as the lines
;;; never move. So a PIT_CheckLine walk that ends records them in order
;;; (LR_LINES, LR_OK), and the PIT_GetSectors walk of P_CreateSecNodeList
;;; from P_TryMove for the same box (mvNodes: LR_USE) takes them from there.
;;; ---------------------------------------------------------------------------
lineBlocks:   lda     .near MP_MODE         ; (16-bit A: no SEP and REP)
              bne     10$
              stz     .near LR_N            ; a check: a new record
              bra     13$
10$:          lda     .near LR_USE          ; the sectors of the record
              beq     13$
              stz     .near LR_USE
              lda     ##0
11$:          cmp     .near LR_N            ; the lines in order
              bcs     12$
              pha                           ; (the position)
              tax
              lda     .near LR_LINES,x
              tax
              jsr     .kbank getSectors
              pla
              inc     a
              inc     a
              bra     11$
12$:          sec
              rtl

13$:          stz     dp:.tiny WK_CP        ; MP_TB is not the box yet (a word:
                                            ;   the byte after it is free)
              lda     .near (_g_tmbbox + 4*CONST_BOXRIGHT) ; the box in whole
              cmp     ##1                   ;   units, the high bytes when they
              lda     .near (_g_tmbbox + 4*CONST_BOXRIGHT + 2) ; change (C: the
                                            ;   low word is not 0)
              sbc     ##0
              bvs     15$
              STWC    WK_RF
              lda     .near (_g_tmbbox + 4*CONST_BOXTOP)
              cmp     ##1
              lda     .near (_g_tmbbox + 4*CONST_BOXTOP + 2)
              sbc     ##0
              bvs     15$
              STWC    WK_TF
              lda     .near (_g_tmbbox + 4*CONST_BOXLEFT + 2)
              STWC    WK_LH
              lda     .near (_g_tmbbox + 4*CONST_BOXBOTTOM + 2)
              bra     16$
15$:          lda     ##0x7fff              ; an edge of -32768.0: bottom >=
16$:          STWC    WK_BH                 ;   bbox[top] << 16 for every line
              tsc                           ; the walk frame: the high bytes of
              sec                           ;   bx and by are 0
              sbc     ##FR_SIZE
              tcs
              lda     ##0
              sta     FR_BX1,s
              sta     FR_BY1,s
              tax
              jsr     .kbank walkRange
              bcc     20$
              sep     #0x20                 ; no blocks (a check: no record)
              lda     .near MP_MODE
              bne     17$
              stz     .near LR_OK
17$:          rep     #0x20
              tsc
              clc
              adc     ##FR_SIZE
              tcs
              sec
              rtl
              .space  23                    ; (the code after keeps its address)
20$:          lda     .near _g_blockmap     ; WK_BL = _g_blockmap, WK_LS in
              sta     dp:.tiny WK_BL        ;   the bank of the lump (words, no
              lda     .near (_g_blockmap+2) ;   SEP and REP)
              sta     dp:.tiny (WK_BL+2)
              lda     .near (_g_blockmaplump+2)
              sta     dp:.tiny (WK_LS+2)
              lda     .near (_g_sectors+2)  ; PS: the bank of the sectors
              sta     dp:.tiny (PS+2)
              lda     .near (_g_lines+1)    ; DBR = the bank of the lines (the
              pha                           ;   high byte)
              plb
              plb
lCol:         lda     FR_YL,s               ; a column: by = yl (a byte)
              and     ##0x00ff
              sta     FR_BY,s
lBlk:         asl     a                     ; the list of the block by * width
              tax                           ;   + bx: _g_blockmaplump +
              lda     long:BMROW,x          ;   2 * _g_blockmap[block] (A = by)
              clc
              adc     FR_BX,s
              asl     a
              tay
              lda     [.tiny WK_BL],y
              asl     a
              clc
              adc     long:_g_blockmaplump
              sta     dp:.tiny WK_LS
              ldy     ##2                   ; (after its 0)
lLine:        lda     [.tiny WK_LS],y       ; the line, -1 at the end
              bmi     lNextBlk
              asl     a
              tax
              lda     long:LN36,x
              tax
              lda     abs:OFS_LINE_VALIDCOUNT,x ; checked already
              cmp     long:validcount
              beq     lNext
              lda     dp:.tiny WK_BH        ; bottom >= bbox[top] << 16
              SLT16X  (OFS_LINE_BBOX + 2*CONST_BOXTOP)
              bpl     lStamp
              lda     dp:.tiny WK_TF        ; top <= bbox[bottom] << 16
              SLT16X  (OFS_LINE_BBOX + 2*CONST_BOXBOTTOM)
              bmi     lStamp
              lda     dp:.tiny WK_RF        ; right <= bbox[left] << 16
              SLT16X  (OFS_LINE_BBOX + 2*CONST_BOXLEFT)
              bmi     lStamp
              lda     dp:.tiny WK_LH        ; left >= bbox[right] << 16
              SLT16X  (OFS_LINE_BBOX + 2*CONST_BOXRIGHT)
              bpl     lStamp
              brl     lHit
lStamp:       lda     long:validcount       ; a word store: cheaper than a SEP
              sta     abs:OFS_LINE_VALIDCOUNT,x ;   and REP (a bus cycle each)
lNext:        iny
              iny
              bra     lLine
              .space  8                     ; (the bank 0 code keeps its size)

;;; lNextBlk: the next block of the column, or the next column (FR_YH,
;;; FR_XH and FR_YL are bytes).
lNextBlk:     lda     FR_YH,s
              and     ##0x00ff
              cmp     FR_BY,s
              beq     1$
              lda     FR_BY,s
              inc     a
              sta     FR_BY,s
              brl     lBlk
1$:           lda     FR_XH,s
              and     ##0x00ff
              cmp     FR_BX,s
              beq     2$
              lda     FR_BX,s
              inc     a
              sta     FR_BX,s
              brl     lCol
2$:           sep     #0x20
              lda     #.byte2 tmthing       ; the end: the near DBR
              pha
              plb
              lda     .near MP_MODE         ; a check walk that ends: its record
              bne     3$                    ;   (LR_N 0xff: too many lines)
              lda     .near LR_N
              inc     a
              beq     21$
              lda     #1
21$:          sta     .near LR_OK
3$:           rep     #0x20
              tsc
              clc
              adc     ##FR_SIZE
              tcs
              sec
              rtl
              .space  25                    ; (the code after keeps its address)

;;; lHit: the line X passes the box tests: its stamp, then P_BoxOnLineSide
;;; for a slanted line, and PIT_CheckLine or PIT_GetSectors: with the near
;;; DBR, WK_LN = the line and the list position in the frame.
lHit:         lda     long:validcount       ; line->validcount = validcount, the
              sta     abs:OFS_LINE_VALIDCOUNT,x ;   list position in the frame, WK_LN
              tya                           ;   = the line (words, no SEP and REP)
              sta     FR_LY,s
              stx     dp:.tiny WK_LN
              lda     long:(_g_lines+2)
              and     ##0x00ff
              sta     dp:.tiny (WK_LN+2)
              lda     abs:OFS_LINE_SLOPETYPE,x
              and     ##0x00ff
              tay
              lda     ##.byte2 tmthing      ; the near DBR (the high byte)
              xba
              pha
              plb
              plb
              cpy     ##CONST_ST_POSITIVE   ; slanted: P_BoxOnLineSide(tmbbox, ld)
              bcc     lCross                ;   == -1 (horizontal or vertical: -1):
              lda     dp:.tiny WK_CP        ;   MP_TB = _g_tmbbox once a walk
              bne     7$                    ;   (WK_CP), then the corners
              inc     a                     ;   (slanted: walk1, walk2; they
              sta     dp:.tiny WK_CP        ;   cross the line: lCross)
              ldx     ##14
8$:           lda     .near _g_tmbbox,x
              sta     .near MP_TB,x
              dex
              dex
              bpl     8$
7$:           lda     ##.word0 walk1
              brl     slanted
lCross:       lda     .near MP_MODE         ; (16-bit A: no SEP and REP)
              beq     21$
              brl     4$
21$:          ldx     .near LR_N            ; record the line: 2 * the line
              cpx     ##(2 * LR_MAX)        ;   (LNSEC)
              bcs     3$
              lda     FR_LY,s
              tay
              lda     [.tiny WK_LS],y
              asl     a
              sta     .near LR_LINES,x
              inx
              inx
              stx     .near LR_N
              bra     31$
3$:           lda     ##0xff                ; too many: no record
              sta     .near LR_N
              ;; PIT_CheckLine: one sided lines and blocking lines block;
              ;; else the sectors of the line (LNSEC, SEC58: PS the front,
              ;; BS the back), each in turn, lower tmceilingz (then
              ;; ceilingline = the line), raise tmfloorz and lower
              ;; tmdropoffz, as the opening of the line would (its globals
              ;; are read only after P_LineOpening); a special line joins
              ;; spechit
31$:          ldy     ##(OFS_LINE_SIDENUM+2) ; one sided: sidenum[1] = -1
              lda     [.tiny WK_LN],y
              inc     a
              beq     39$
              lda     .near MP_MISSILE
              bne     32$
              ldy     ##OFS_LINE_FLAGS
              lda     [.tiny WK_LN],y
              bit     ##CONST_ML_BLOCKING
              bne     39$
              and     ##CONST_ML_BLOCKMONSTERS
              beq     32$
              lda     .near MP_PLAYER
              bne     32$
39$:          tsc                           ; the line blocks the move
              clc
              adc     ##FR_SIZE
              tcs
              clc
              rtl
32$:          lda     FR_LY,s               ; LNSEC[line]: front | back << 8
              tay
              lda     [.tiny WK_LS],y
              asl     a
              tax
              lda     long:LNSEC,x
              tay
              and     ##0x00ff
              asl     a
              tax
              lda     long:SEC58,x
              sta     dp:.tiny PS
              tya
              xba
              and     ##0x00ff
              asl     a
              tax
              lda     long:SEC58,x
              sta     dp:.tiny BS
33$:          ldy     ##OFS_SEC_CEILINGHEIGHT ; ceiling < tmceilingz
              lda     [.tiny PS],y
              cmp     .near _g_tmceilingz
              iny
              iny
              lda     [.tiny PS],y
              sbc     .near (_g_tmceilingz+2)
              bvc     34$
              eor     ##0x8000
34$:          bpl     35$
              ldx     ##.near _g_tmceilingz
              jsr     .kbank ps32
              lda     dp:.tiny WK_LN        ; ceilingline = the line (words; its
              sta     .near _g_ceilingline  ;   byte 3 is 0)
              lda     dp:.tiny (WK_LN+2)
              sta     .near (_g_ceilingline+2)
35$:          ldy     ##OFS_SEC_FLOORHEIGHT ; floor > tmfloorz
              lda     .near _g_tmfloorz
              cmp     [.tiny PS],y
              iny
              iny
              lda     .near (_g_tmfloorz+2)
              sbc     [.tiny PS],y
              bvc     36$
              eor     ##0x8000
36$:          bpl     37$
              ldx     ##.near _g_tmfloorz
              jsr     .kbank ps32
37$:          ldy     ##OFS_SEC_FLOORHEIGHT ; floor < tmdropoffz
              lda     [.tiny PS],y
              cmp     .near _g_tmdropoffz
              iny
              iny
              lda     [.tiny PS],y
              sbc     .near (_g_tmdropoffz+2)
              bvc     38$
              eor     ##0x8000
38$:          bpl     40$
              ldx     ##.near _g_tmdropoffz
              jsr     .kbank ps32
40$:          lda     dp:.tiny PS           ; then the back sector (a line with
              cmp     dp:.tiny BS           ;   one sector: once)
              beq     41$
              lda     dp:.tiny BS
              sta     dp:.tiny PS
              bra     33$
41$:          ldy     ##OFS_LINE_SPECIAL    ; a special line: spechit (4 at
              lda     [.tiny WK_LN],y       ;   most; a far pointer, its byte 3
              beq     lBack                 ;   is 0)
              lda     .near _g_numspechit
              cmp     ##4
              bcs     lBack
              asl     a
              asl     a
              tax
              lda     dp:.tiny WK_LN
              sta     .near _g_spechit,x
              lda     dp:.tiny (WK_LN+2)
              sta     .near (_g_spechit+2),x
              inc     .near _g_numspechit
              bra     lBack
4$:           lda     FR_LY,s               ; PIT_GetSectors
              tay
              lda     [.tiny WK_LS],y
              asl     a
              tax
              jsr     .kbank getSectors
lBack:        lda     long:(_g_lines+1)     ; the walk again: the bank of the
              pha                           ;   lines (the high byte), the list
              plb                           ;   position
              plb
              lda     FR_LY,s
              tay
              brl     lNext
              .space  69                    ; (the code after keeps its address)

;;; ps32: the 32-bit height at Y - 2 of the sector PS to near X, as words
;;; (a new tmceilingz, tmfloorz or tmdropoffz of PIT_CheckLine).
ps32:         dey
              dey
              lda     [.tiny PS],y
              sta     abs:0,x
              iny
              iny
              lda     [.tiny PS],y
              sta     abs:2,x
              rts
              .space  4                     ; (the code after keeps its address)

;;; ---------------------------------------------------------------------------
;;; baseFloor: the floor, drop off and ceiling of the sector at tmx, tmy;
;;; no ceiling line, a new validcount, no special lines. MV_SS and MV_SEC:
;;; the subsector and its sector (for P_TryMove).
;;; baseFloorL: the same for JSL.
;;; baseLite: only the second part (no ceiling line, validcount, no special
;;; lines). In: 16-bit A, the near DBR.
;;; sectorFloor: only the first part. Out: 16-bit A, the near DBR.
;;; ---------------------------------------------------------------------------
baseFloorL:   jsr     .kbank baseFloor
              rtl
baseFloor:    jsr     .kbank sectorFloor
              bra     baseLite
sectorFloor:  jsr     .kbank pointSector    ; the sector at x, y (DBR = its bank)
              ldx     abs:(OFS_SEC_FLOORHEIGHT+2),y ; tmfloorz = tmdropoffz = the floor,
              lda     abs:OFS_SEC_FLOORHEIGHT,y ;   tmceilingz = the ceiling (words,
              sta     long:_g_tmfloorz      ;   no SEP and REP)
              sta     long:_g_tmdropoffz
              txa
              sta     long:(_g_tmfloorz+2)
              sta     long:(_g_tmdropoffz+2)
              ldx     abs:(OFS_SEC_CEILINGHEIGHT+2),y
              lda     abs:OFS_SEC_CEILINGHEIGHT,y
              sta     long:_g_tmceilingz
              txa
              sta     long:(_g_tmceilingz+2)
              lda     ##.byte2 tmthing      ; (the near DBR: the high byte)
              xba
              pha
              plb
              plb
              rts
baseLite:     stz     .near _g_numspechit   ; numspechit = 0 (-1 after a move)
              inc     .near validcount      ; validcount++
              lda     .near _g_ceilingline  ; ceilingline = NULL (its bytes 0-2,
              ora     .near (_g_ceilingline+1) ;   when it is not)
              beq     2$
              stz     .near _g_ceilingline
              stz     .near (_g_ceilingline+1)
2$:           rts

;;; pointSector: MV_SS = R_PointInSubsector(tmx, tmy), MV_SEC = its sector.
;;; Out: DBR = the bank of the sector, Y = the sector, 16-bit A.
pointSector:  lda     .near tmy             ; _Dp = y (words: no SEP and REP)
              sta     dp:.tiny _Dp
              lda     .near (tmy+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near tmx
              ldx     .near (tmx+2)
              jsl     long:R_PointInSubsector
              tay                           ; MV_SS = the subsector, DBR = its
              sta     .near MV_SS           ;   bank (the high byte of the word)
              txa
              and     ##0x00ff
              sta     .near (MV_SS+2)
              xba
              pha
              plb
              plb
              lda     abs:OFS_SUB_SECTOR,y  ; MV_SEC = its sector, DBR = its bank
              ldx     abs:(OFS_SUB_SECTOR+2),y
              tay
              sta     long:MV_SEC
              txa
              and     ##0x00ff
              sta     long:(MV_SEC+2)
              xba
              pha
              plb
              plb
              rts
              .space  97                    ; (the code after keeps its address)

;;; ---------------------------------------------------------------------------
;;; The sector nodes. The free nodes are in a list (SN_FREE, linked by
;;; m_tnext); when it is empty, a pool of SN_POOL nodes comes from
;;; Z_CallocLevel. (The C code uses the block allocator of
;;; z_bmallo.c: the same nodes in the same lists at other
;;; addresses.)
;;; ---------------------------------------------------------------------------
SN_POOL       .equ    32

;;; ---------------------------------------------------------------------------
;;; pointOnLineSide: A = P_PointOnLineSide(x, y, WK_LN) in C, 0 or 1, for
;;; the point x = MP_TB + PXO, y = MP_TB + PYO (near fixed_t; PXO and PYO
;;; bytes of the direct page). No calls: it ends at PVEC (posPub for
;;; P_PointOnLineSide, the corners of slanted).
;;;   !dx ? x <= v1.x << 16 ? dy > 0 : dy < 0 :
;;;   !dy ? y <= v1.y << 16 ? dx < 0 : dx > 0 :
;;;   ((y - (v1.y << 16)) >> 8) * dx >= dy * ((x - (v1.x << 16)) >> 8)
;;; The products are the 32-bit products of the C code (posMul; the first
;;; waits in MP_T1).
;;; ---------------------------------------------------------------------------
pointOnLineSide:
              ldy     ##OFS_LINE_DX
              lda     [.tiny WK_LN],y
              bne     20$
              lda     dp:.tiny PXO          ; dx == 0: x <= v1.x << 16 ?
              and     ##0x00ff
              tax
              ldy     ##OFS_LINE_V1
              lda     .near (MP_TB+2),x
              sec
              sbc     [.tiny WK_LN],y
              beq     11$
              bvc     10$
              eor     ##0x8000
10$:          bmi     12$                   ; x.hi < v1.x
              bra     13$
11$:          lda     .near MP_TB,x
              bne     13$
12$:          ldy     ##OFS_LINE_DY         ; x <= v1.x << 16: dy > 0
              lda     [.tiny WK_LN],y
              beq     90$
              bmi     90$
              bra     91$
13$:          ldy     ##OFS_LINE_DY         ; dy < 0
              lda     [.tiny WK_LN],y
              bmi     91$
              bra     90$

20$:          ldy     ##OFS_LINE_DY
              lda     [.tiny WK_LN],y
              bne     30$
              lda     dp:.tiny PYO          ; dy == 0: y <= v1.y << 16 ?
              and     ##0x00ff
              tax
              ldy     ##(OFS_LINE_V1+2)
              lda     .near (MP_TB+2),x
              sec
              sbc     [.tiny WK_LN],y
              beq     21$
              bvc     22$
              eor     ##0x8000
22$:          bmi     23$
              bra     24$
21$:          lda     .near MP_TB,x
              bne     24$
23$:          ldy     ##OFS_LINE_DX         ; y <= v1.y << 16: dx < 0
              lda     [.tiny WK_LN],y
              bmi     91$
              bra     90$
24$:          ldy     ##OFS_LINE_DX         ; dx > 0
              lda     [.tiny WK_LN],y
              beq     90$
              bmi     90$
              bra     91$
90$:          lda     ##0
              jmp     (abs:PVEC)
91$:          lda     ##1
              jmp     (abs:PVEC)

              ;; left = ((y - (v1.y << 16)) >> 8) * dx, then right = dy *
              ;; ((x - (v1.x << 16)) >> 8), by posMul in 16-bit A: word
              ;; stores cost less than a SEP and REP (a bus cycle each).
              ;; Bits 8..23 of the operand are the byte 1 of the point and
              ;; the low byte of the difference of the high words.
30$:          lda     dp:.tiny PYO          ; y - (v1.y << 16), dx
              and     ##0x00ff
              tax
              ldy     ##(OFS_LINE_V1+2)
              lda     .near (MP_TB+2),x
              sec
              sbc     [.tiny WK_LN],y
              xba
              and     ##0x00ff
              sta     .near TM_L
              lda     [.tiny WK_LN],y
              xba
              and     ##0xff00
              eor     ##0xffff
              sec
              adc     .near (MP_TB+1),x
              ldy     ##OFS_LINE_DX
              jsr     .kbank posMul
              sta     .near MP_T1           ; the first (left) in MP_T1
              stx     .near (MP_T1+2)
              lda     dp:.tiny PXO          ; x - (v1.x << 16), dy
              and     ##0x00ff
              tax
              ldy     ##OFS_LINE_V1
              lda     .near (MP_TB+2),x
              sec
              sbc     [.tiny WK_LN],y
              xba
              and     ##0x00ff
              sta     .near TM_L
              lda     [.tiny WK_LN],y
              xba
              and     ##0xff00
              eor     ##0xffff
              sec
              adc     .near (MP_TB+1),x
              ldy     ##OFS_LINE_DY
              jsr     .kbank posMul
              sec                           ; right - left < 0 or 0: 1
              sbc     .near MP_T1
              tay
              txa
              sbc     .near (MP_T1+2)
              bvc     61$
              eor     ##0x8000              ; (the sign of the 33-bit difference;
              ora     ##1                   ;   not 0)
61$:          bmi     62$
              bne     63$
              tya
              bne     63$
62$:          brl     91$
63$:          brl     90$

;;; posMul: X:C = the low 32 bits of V * F (as _Mul32), V = TM_L:C (TM_L
;;; its byte 3, signed) and F the factor at [WK_LN],Y:
;;;   V.lo * F + (AH * F + (F < 0 ? -V.lo : 0)) << 16
;;; AH = 0 or -1 takes no product.
posMul:       sta     dp:.tiny MA           ; MA = V.lo, MB = F
              lda     [.tiny WK_LN],y
              sta     dp:.tiny MB
              PQMUL                         ; V.lo * F, unsigned: Y low, C high
              tyx                           ; X = the low word
              ldy     dp:.tiny MB           ; F < 0: - V.lo << 16
              bpl     41$
              sec
              sbc     dp:.tiny MA
41$:          tay                           ; Y = the high word
              lda     .near TM_L            ; + AH * F, the low word
              beq     44$
              cmp     ##0x00ff
              bne     42$
              tya                           ; AH = -1: - F
              sec
              sbc     dp:.tiny MB
              tay
              bra     44$
42$:          cmp     ##0x0080              ; AH sign extended: a product
              bcc     43$
              ora     ##0xff00
43$:          stx     dp:.tiny MR           ; (the low word waits in MR)
              sta     dp:.tiny MA
              sty     .near TM_H
              jsl     long:umul16lo
              clc
              adc     .near TM_H
              tay
              ldx     dp:.tiny MR
44$:          txa                           ; X:C = the product
              tyx
              rts
              .space  36                    ; (the code after keeps its address)

;;; posPub: the end for P_PointOnLineSide (pointOnLineSideL).
posPub:       rtl

;;; slanted: ST_POSITIVE: side(right, bottom) == (p = side(left, top)) ?
;;; p : -1; ST_NEGATIVE: side(left, bottom) == (p = side(right, top)) ?
;;; p : -1. In: C = the end of the first corner (box1 for P_BoxOnLineSide,
;;; walk1 for the line walk), the next one after it (box2, walk2): PSD
;;; keeps the first side. No calls.
slanted:      sta     dp:.tiny PVEC         ; (words: no SEP and REP)
              ldy     ##OFS_LINE_SLOPETYPE
              lda     [.tiny WK_LN],y
              lsr     a                     ; C: negative
              lda     ##(4*CONST_BOXBOTTOM*256 + 4*CONST_BOXRIGHT) ; PXO, PYO: x, bottom
              bcc     1$
              lda     ##(4*CONST_BOXBOTTOM*256 + 4*CONST_BOXLEFT)
1$:           sta     dp:.tiny PXO
              brl     pointOnLineSide
              .space  8                     ; (the code after keeps its address)
box1:         ldx     ##.word0 box2         ; the first corner: its side, then
              bra     corner2               ;   the other x, top
walk1:        ldx     ##.word0 walk2
corner2:      sep     #0x20
              sta     dp:.tiny PSD
              lda     dp:.tiny PXO
              eor     #(4*CONST_BOXRIGHT ^ 4*CONST_BOXLEFT)
              sta     dp:.tiny PXO
              txa
              sta     dp:.tiny PVEC
              lda     #(4*CONST_BOXTOP)
              sta     dp:.tiny PYO
              rep     #0x20
              txa
              xba
              sep     #0x20
              sta     dp:.tiny (PVEC+1)
              rep     #0x20
              brl     pointOnLineSide
box2:         tay                           ; P_BoxOnLineSide: the side, or -1
              eor     dp:.tiny PSD          ;   (PSD a byte: 16-bit A, no SEP and
              and     ##0x00ff              ;   REP)
              bne     1$
              tya
              rtl
1$:           lda     ##0xffff
              rtl
walk2:        eor     dp:.tiny PSD          ; the line walk: the same side: the
              and     ##0x00ff              ;   box misses the line
              beq     1$
              brl     lCross
1$:           brl     lBack

;;; pointOnLineSideL: the entry of P_PointOnLineSide (PVEC = posPub).
pointOnLineSideL:
              lda     ##.word0 posPub       ; (a word: no SEP and REP)
              sta     dp:.tiny PVEC
              brl     pointOnLineSide
              .space  7                     ; (the code after keeps its address)

;;; ---------------------------------------------------------------------------
;;; void P_LineOpening(const line_t __far* linedef)          In: _Dp[0-3].
;;; int16_t P_PointOnLineSide(fixed_t x, fixed_t y, const line_t __far* line)
;;;   In: X:C = x, _Dp[0-3] = y, _Dp[4-7] = line. Out: C.
;;; int16_t P_BoxOnLineSide(const fixed_t *tmbox, const line_t __far* ld)
;;;   In: _Dp[0-3] = tmbox, _Dp[4-7] = ld. Out: C.
;;; ---------------------------------------------------------------------------
              .section logiccode, text
              .public P_LineOpening
P_LineOpening:
              phb
              ldy     ##(OFS_LINE_SIDENUM+2) ; one sided: openrange = 0
              lda     [.tiny _Dp],y
              cmp     ##0xffff
              bne     1$
              lda     ##0                   ; (words: no SEP and REP)
              sta     long:_g_openrange
              sta     long:(_g_openrange+2)
              plb
              rtl
1$:           asl     a                     ; X = &sides[sidenum[1]]: 14 * n
              asl     a                     ;   as (8n - n) * 2, n in the line
              asl     a
              sec
              sbc     [.tiny _Dp],y
              asl     a
              clc
              adc     long:_g_sides
              tax
              ldy     ##OFS_LINE_SIDENUM    ; Y = &sides[sidenum[0]]
              lda     [.tiny _Dp],y
              asl     a
              asl     a
              asl     a
              sec
              sbc     [.tiny _Dp],y
              asl     a
              clc
              adc     long:_g_sides
              tay
              lda     long:(_g_sides+1)     ; DBR = the sides (the high byte): X
              pha                           ;   = the back sector, Y = the front
              plb                           ;   sector
              plb
              lda     abs:OFS_SIDE_SECTOR,x
              tax
              lda     abs:OFS_SIDE_SECTOR,y
              tay
              lda     long:(_g_sectors+1)   ; DBR = the sectors (the high byte)
              pha
              plb
              plb
openXY:       ;; X = the higher floor (the back when they are the same)
              lda     abs:OFS_SEC_FLOORHEIGHT,x
              cmp     abs:OFS_SEC_FLOORHEIGHT,y
              lda     abs:(OFS_SEC_FLOORHEIGHT+2),x
              sbc     abs:(OFS_SEC_FLOORHEIGHT+2),y
              bvc     2$
              eor     ##0x8000
2$:           bpl     3$
              txa
              tyx
              tay
              ;; Y = the lower ceiling
3$:           lda     abs:OFS_SEC_CEILINGHEIGHT,x
              cmp     abs:OFS_SEC_CEILINGHEIGHT,y
              lda     abs:(OFS_SEC_CEILINGHEIGHT+2),x
              sbc     abs:(OFS_SEC_CEILINGHEIGHT+2),y
              bvc     4$
              eor     ##0x8000
4$:           bpl     5$
              txy
              ;; opentop = the ceiling of Y, openrange = opentop - openbottom,
              ;; openbottom = the floor of X (words: no other work for them)
5$:           lda     abs:OFS_SEC_CEILINGHEIGHT,y
              sta     long:_g_opentop
              sec
              sbc     abs:OFS_SEC_FLOORHEIGHT,x
              sta     long:_g_openrange
              lda     abs:(OFS_SEC_CEILINGHEIGHT+2),y
              sta     long:(_g_opentop+2)
              sbc     abs:(OFS_SEC_FLOORHEIGHT+2),x
              sta     long:(_g_openrange+2)
              lda     abs:OFS_SEC_FLOORHEIGHT,x
              sta     long:_g_openbottom
              lda     abs:(OFS_SEC_FLOORHEIGHT+2),x
              sta     long:(_g_openbottom+2)
              plb
              rtl

;;; P_LineOpeningXY: P_LineOpening of a two sided line whose sides have the
;;; sectors X and Y (either way round; DBR = the sectors).
              .public P_LineOpeningXY
P_LineOpeningXY:
              phb
              bra     openXY
              .space  PAD_LO                ; (the code after keeps its address)


              .public P_PointOnLineSide
P_PointOnLineSide:
              sep     #0x20                 ; MP_PX = X:C, MP_PY = _Dp[0-3]
              sta     .near MP_PX           ;   (bytes), PXO and PYO their
              xba                           ;   offsets from MP_TB
              sta     .near (MP_PX+1)
              rep     #0x20
              txa
              sep     #0x20
              sta     .near (MP_PX+2)
              xba
              sta     .near (MP_PX+3)
              ldx     ##3
1$:           lda     dp:.tiny _Dp,x
              sta     .near MP_PY,x
              dex
              bpl     1$
              lda     #(MP_PX - MP_TB)
              sta     dp:.tiny PXO
              lda     #(MP_PY - MP_TB)
              sta     dp:.tiny PYO
              rep     #0x20
              jsr     .kbank argLine4
              jmp     long:pointOnLineSideL

              .public P_BoxOnLineSide
P_BoxOnLineSide:
              sep     #0x20                 ; MP_TB = tmbox[0..3] (bytes)
              ldy     ##15
1$:           lda     [.tiny _Dp],y
              tyx
              sta     .near MP_TB,x
              dey
              bpl     1$
              rep     #0x20
              jsr     .kbank argLine4
              jmp     long:boxOnLineSide

;;; argLine4: WK_LN = the line _Dp[4-7].
argLine4:     sep     #0x20
              lda     dp:.tiny (_Dp+4)
              sta     dp:.tiny WK_LN
              lda     dp:.tiny (_Dp+5)
              sta     dp:.tiny (WK_LN+1)
              lda     dp:.tiny (_Dp+6)
              sta     dp:.tiny (WK_LN+2)
              lda     dp:.tiny (_Dp+7)
              sta     dp:.tiny (WK_LN+3)
              rep     #0x20
              rts

;;; ---------------------------------------------------------------------------
;;; void P_CreateSecNodeList(mobj_t __far* thing)          In: _Dp[0-3].
;;; The node calls here (newSecnode, P_DelSecnode) only allocate and free
;;; nodes, so near variables keep their values across them.
;;; ---------------------------------------------------------------------------
              .section logiccode, text
              .public P_CreateSecNodeList
P_CreateSecNodeList:
              ldx     ##2                   ; MP_SAVE = tmthing, MP_THING =
1$:           lda     .near tmthing,x       ;   tmthing = thing (words: no SEP
              sta     .near MP_SAVE,x       ;   and REP; bytes 3 are 0: both
              lda     dp:.tiny _Dp,x        ;   callers clear _Dp+3)
              sta     .near tmthing,x
              sta     .near MP_THING,x
              dex
              dex
              bpl     1$
              ldx     ##6                   ; tmx, tmy = thing->x, y
              ldy     ##(OFS_MO_X+6)
2$:           lda     [.tiny _Dp],y
              sta     .near tmx,x
              dey
              dey
              dex
              dex
              bpl     2$
              ;; m_thing = NULL for each node of _s_sector_list: its bank
              ;; (and byte 3, 0), all that the walks look at (DBR = the
              ;; bank of the node, a NULL has bank 0)
              ldx     .near _s_sector_list
              lda     .near (_s_sector_list+1)
              and     ##0xff00
              beq     5$
              pha
              plb
              plb
3$:           stz     abs:(OFS_SN_M_THING+2),x
              lda     abs:(OFS_SN_M_TNEXT+1),x
              and     ##0xff00
              beq     4$
              pha
              lda     abs:OFS_SN_M_TNEXT,x
              tax
              plb
              plb
              bra     3$
4$:           lda     ##.byte2 tmthing      ; the near DBR (the high byte)
              xba
              pha
              plb
              plb
5$:           inc     .near validcount      ; validcount++
              lda     ##1                   ; PIT_GetSectors
              sta     .near MP_MODE
              jsl     long:setBoxL          ; (the thing in _Dp)
              jsl     long:lineBlocks
              ;; P_AddSecnode(thing->subsector->sector, thing): its sector
              ;; number from SS_SEC
              ldx     .near MP_THING
              lda     .near (MP_THING+1)    ; DBR = its bank (the high byte)
              pha
              plb
              plb
              ldy     abs:OFS_MO_SUBSECTOR,x
              lda     ##.byte2 tmthing      ; the near DBR (the high byte)
              xba
              pha
              plb
              plb
              tya
              sec
              sbc     .near _g_subsectors
              lsr     a
              lsr     a
              tax
              lda     long:SS_SEC,x
              jsl     long:addSecnodeL
              ;; delete the nodes without a thing (P_DelSecnode: rare)
              ldx     .near _s_sector_list
              lda     .near (_s_sector_list+1)
              and     ##0xff00
              beq     9$
7$:           pha                           ; (A: the bank as the high byte)
              plb
              plb
71$:          lda     abs:(OFS_SN_M_THING+2),x
              and     ##0x00ff
              beq     10$
              lda     abs:(OFS_SN_M_TNEXT+1),x
              and     ##0xff00
              beq     8$
              pha
              lda     abs:OFS_SN_M_TNEXT,x
              tax
              plb
              plb
              bra     71$
8$:           lda     ##.byte2 tmthing      ; the near DBR (the high byte)
              xba
              pha
              plb
              plb
              ;; tmthing = saved tmthing, thing->touching_sectorlist =
              ;; _s_sector_list, _s_sector_list = NULL (bytes 3 are 0)
9$:           lda     .near MP_SAVE
              sta     .near tmthing
              lda     .near (MP_SAVE+2)
              sta     .near (tmthing+2)
              ldx     .near MP_THING
              lda     .near (MP_THING+1)    ; DBR = its bank (the high byte)
              pha
              plb
              plb
              lda     long:_s_sector_list
              sta     abs:OFS_MO_TOUCHING,x
              lda     long:(_s_sector_list+2)
              sta     abs:(OFS_MO_TOUCHING+2),x
              lda     ##.byte2 tmthing      ; the near DBR (the high byte)
              xba
              pha
              plb
              plb
              stz     .near _s_sector_list
              stz     .near (_s_sector_list+2)
              rtl

              ;; the node X (DBR its bank) has no thing: if it is the
              ;; first, _s_sector_list = its m_tnext; the walk goes on at
              ;; P_DelSecnode(node) (rare: 16-bit stores)
10$:          phb                           ; its bank (twice: a word), then the
              phb                           ;   near DBR
              pla
              and     ##0x00ff
              sta     dp:.tiny (_Dp+2)
              lda     ##.byte2 tmthing      ; the near DBR (the high byte)
              xba
              pha
              plb
              plb
              lda     dp:.tiny (_Dp+2)
              stx     dp:.tiny _Dp
              cpx     .near _s_sector_list
              bne     12$
              cmp     .near (_s_sector_list+2)
              bne     12$
              ldy     ##OFS_SN_M_TNEXT
              lda     [.tiny _Dp],y
              sta     .near _s_sector_list
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (_s_sector_list+2)
12$:          jsl     long:P_DelSecnode     ; X:C = the next node
              txy
              tax
              tya
              and     ##0x00ff
              bne     13$
              brl     9$
13$:          xba                           ; (7$: the bank as the high byte)
              brl     7$
              .space  2                     ; (the code after keeps its address)

;;; ---------------------------------------------------------------------------
;;; boolean P_BlockLinesIterator(int16_t x, int16_t y, boolean func(line_t __far*))
;;; boolean P_BlockThingsIterator(int16_t x, int16_t y, boolean func(mobj_t __far*))
;;;   In: C = x, _Dp[0-1] = y, _Dp[4-7] = func. Out: C.
;;; The function can run game logic again, so the list is in LS, the
;;; function in LN, and vcount and the list position are on the stack.
;;; ---------------------------------------------------------------------------
              .section logiccode, text
              .public P_BlockLinesIterator
P_BlockLinesIterator:
              tax                           ; 0 <= x < _g_bmapwidth
              bmi     9$
              cmp     .near _g_bmapwidth
              bpl     9$
              lda     dp:.tiny _Dp          ; 0 <= y < _g_bmapheight
              bmi     9$
              cmp     .near _g_bmapheight
              bmi     1$
9$:           lda     ##1
              rtl
1$:           pei     dp:.tiny LS           ; (the callee-saved _Dp[8-15] of the
              pei     dp:.tiny (LS+2)       ;   caller: per call)
              pei     dp:.tiny LN
              pei     dp:.tiny (LN+2)
              asl     a                     ; Y = 2 * (y * width + x) (BMROW)
              txy
              tax
              tya
              clc
              adc     long:BMROW,x
              asl     a
              tay
              sep     #0x20                 ; LS = _g_blockmap, LN = the function,
              lda     .near _g_blockmap     ;   the bank of _Dp: the lines (bytes)
              sta     dp:.tiny LS
              lda     dp:.tiny (_Dp+4)
              sta     dp:.tiny LN
              lda     .near (_g_blockmap+1)
              sta     dp:.tiny (LS+1)
              lda     dp:.tiny (_Dp+5)
              sta     dp:.tiny (LN+1)
              lda     .near (_g_blockmap+2)
              sta     dp:.tiny (LS+2)
              lda     dp:.tiny (_Dp+6)
              sta     dp:.tiny (LN+2)
              rep     #0x20
              lda     [.tiny LS],y          ; the list: _g_blockmaplump + 2 *
              asl     a                     ;   _g_blockmap[...] (the same lump:
              clc                           ;   the bank of LS)
              adc     .near _g_blockmaplump
              sep     #0x20
              sta     dp:.tiny LS
              xba
              sta     dp:.tiny (LS+1)
              rep     #0x20
              pea     #2                    ; the list position at 1,s, after the 0
2$:           lda     1,s
              tay
              lda     [.tiny LS],y
              cmp     ##0xffff
              beq     5$
              asl     a                     ; ld = the line (LN36), in _Dp (all
              tax                           ;   of it: the function can reuse
              sep     #0x20                 ;   _Dp)
              lda     long:LN36,x
              sta     dp:.tiny _Dp
              lda     long:(LN36+1),x
              sta     dp:.tiny (_Dp+1)
              lda     .near (_g_lines+2)
              sta     dp:.tiny (_Dp+2)
              stz     dp:.tiny (_Dp+3)
              rep     #0x20
              ldy     ##OFS_LINE_VALIDCOUNT ; checked already
              lda     [.tiny _Dp],y
              cmp     .near validcount
              beq     3$
              sep     #0x20                 ; its stamp (the high byte when it
              lda     .near validcount      ;   changes)
              sta     [.tiny _Dp],y
              iny
              lda     .near (validcount+1)
              cmp     [.tiny _Dp],y
              beq     21$
              sta     [.tiny _Dp],y
21$:          rep     #0x20
              jsl     long:callLN
              inc     a
              dec     a
              beq     4$
3$:           sep     #0x20                 ; the next position (the high byte on
              lda     1,s                   ;   a carry)
              clc
              adc     #2
              sta     1,s
              bcc     31$
              lda     2,s
              inc     a
              sta     2,s
31$:          rep     #0x20
              bra     2$
4$:           ldx     ##0
              bra     6$
5$:           ldx     ##1
6$:           pla                           ; (the position) LS, LN again
              pla                           ;   (16-bit: once a call)
              sta     dp:.tiny (LN+2)
              pla
              sta     dp:.tiny LN
              pla
              sta     dp:.tiny (LS+2)
              pla
              sta     dp:.tiny LS
              txa
              rtl

callLN:       .byte   0xdc                  ; jml [LN]
              .word   .word0 LN

              .section logiccode, text
              .public P_BlockThingsIterator
P_BlockThingsIterator:
              tax                           ; 0 <= x < _g_bmapwidth
              bmi     9$
              cmp     .near _g_bmapwidth
              bpl     9$
              lda     dp:.tiny _Dp          ; 0 <= y < _g_bmapheight
              bmi     9$
              cmp     .near _g_bmapheight
              bmi     1$
9$:           lda     ##1
              rtl
1$:           pei     dp:.tiny LS           ; (the callee-saved _Dp[8-15] of the
              pei     dp:.tiny (LS+2)       ;   caller: per call)
              pei     dp:.tiny LN
              pei     dp:.tiny (LN+2)
              asl     a                     ; Y = 4 * (y * width + x) (BMROW)
              txy
              tax
              tya
              clc
              adc     long:BMROW,x
              asl     a
              asl     a
              tay
              sep     #0x20                 ; LS = _g_blocklinks, LN = the
              lda     .near _g_blocklinks   ;   function (bytes)
              sta     dp:.tiny LS
              lda     dp:.tiny (_Dp+4)
              sta     dp:.tiny LN
              lda     .near (_g_blocklinks+1)
              sta     dp:.tiny (LS+1)
              lda     dp:.tiny (_Dp+5)
              sta     dp:.tiny (LN+1)
              lda     .near (_g_blocklinks+2)
              sta     dp:.tiny (LS+2)
              lda     dp:.tiny (_Dp+6)
              sta     dp:.tiny (LN+2)
              rep     #0x20
              bra     3$
2$:           ldy     ##OFS_MO_BNEXT        ; mobj = mobj->bnext
3$:           lda     [.tiny LS],y          ; (both words read before the
              tax                           ;   stores to LS)
              iny
              iny
              lda     [.tiny LS],y
              sep     #0x20
              sta     dp:.tiny (LS+2)       ; LS and _Dp = mobj (bytes; NULL:
              sta     dp:.tiny (_Dp+2)      ;   bank 0)
              beq     5$
              stz     dp:.tiny (_Dp+3)      ; (all of _Dp: the function can
              rep     #0x20                 ;   reuse it)
              txa
              sep     #0x20
              sta     dp:.tiny LS
              sta     dp:.tiny _Dp
              xba
              sta     dp:.tiny (LS+1)
              sta     dp:.tiny (_Dp+1)
              rep     #0x20
              jsl     long:callLN2
              inc     a
              dec     a
              bne     2$
              ldx     ##0
              bra     6$
5$:           rep     #0x20
              ldx     ##1
6$:           pla                           ; LS, LN again (16-bit: once a call)
              sta     dp:.tiny (LN+2)
              pla
              sta     dp:.tiny LN
              pla
              sta     dp:.tiny (LS+2)
              pla
              sta     dp:.tiny LS
              txa
              rtl

callLN2:      .byte   0xdc                  ; jml [LN]
              .word   .word0 LN

;;; ---------------------------------------------------------------------------
;;; checkThing: the rest of PIT_CheckThing(the thing at _Dp[0-3]) after the
;;; checks of P_CheckPosition (the flags, the distance, not tmthing). A
;;; missile goes over or under the thing, or hits it; else tmthing picks up
;;; a special thing. Out: C = 0 if the thing blocks the move.
;;; ---------------------------------------------------------------------------
              .section logiccode, text
checkThing:   lda     .near tmthing
              sta     dp:.tiny (_Dp+4)
              lda     .near (tmthing+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##(OFS_MO_FLAGS+2)    ; tmthing is a missile
              lda     [.tiny (_Dp+4)],y
              and     ##CONST_MF_MISSILE_HI
              bne     10$
              ldy     ##OFS_MO_FLAGS        ; a special thing: picked up
              lda     [.tiny _Dp],y
              bit     ##CONST_MF_SPECIAL
              beq     2$
              pha                           ; (the flags before the pickup,
              lda     [.tiny (_Dp+4)],y     ; which can remove the thing)
              and     ##CONST_MF_PICKUP_LO
              beq     1$
              jsl     long:P_TouchSpecialThing
1$:           pla
2$:           and     ##CONST_MF_SOLID      ; C = the flags: !solid
              beq     3$
              lda     ##0
              rtl
3$:           lda     ##1
              rtl

              ;; a missile: over the thing (thing->z + height < tmthing->z)
10$:          ldy     ##OFS_MO_Z
              lda     [.tiny _Dp],y
              clc
              ldy     ##OFS_MO_HEIGHT
              adc     [.tiny _Dp],y
              sta     .near MP_T0
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_HEIGHT+2)
              adc     [.tiny _Dp],y
              sta     .near (MP_T0+2)
              lda     .near MP_T0
              ldy     ##OFS_MO_Z
              cmp     [.tiny (_Dp+4)],y
              lda     .near (MP_T0+2)
              ldy     ##(OFS_MO_Z+2)
              sbc     [.tiny (_Dp+4)],y
              bvc     11$
              eor     ##0x8000
11$:          bmi     13$
              ;; under it (tmthing->z + tmthing->height < thing->z)
              ldy     ##OFS_MO_Z
              lda     [.tiny (_Dp+4)],y
              clc
              ldy     ##OFS_MO_HEIGHT
              adc     [.tiny (_Dp+4)],y
              sta     .near MP_T0
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny (_Dp+4)],y
              ldy     ##(OFS_MO_HEIGHT+2)
              adc     [.tiny (_Dp+4)],y
              sta     .near (MP_T0+2)
              lda     .near MP_T0
              ldy     ##OFS_MO_Z
              cmp     [.tiny _Dp],y
              lda     .near (MP_T0+2)
              ldy     ##(OFS_MO_Z+2)
              sbc     [.tiny _Dp],y
              bvc     12$
              eor     ##0x8000
12$:          bpl     14$
13$:          lda     ##1                   ; over or under: true
              rtl
              ;; the same species as the shooter: not the shooter, and only
              ;; players hurt players
14$:          ldy     ##(OFS_MO_TARGET+2)
              lda     [.tiny (_Dp+4)],y
              sta     .near (MP_T1+2)
              ldy     ##OFS_MO_TARGET
              lda     [.tiny (_Dp+4)],y
              sta     .near MP_T1
              ora     .near (MP_T1+2)
              beq     17$
              lda     .near MP_T1
              sta     dp:.tiny (_Dp+4)
              lda     .near (MP_T1+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_MO_TYPE
              lda     [.tiny (_Dp+4)],y
              cmp     [.tiny _Dp],y
              bne     16$
              lda     dp:.tiny _Dp          ; the shooter itself: true
              cmp     .near MP_T1
              bne     15$
              lda     dp:.tiny (_Dp+2)
              cmp     .near (MP_T1+2)
              beq     13$
15$:          lda     [.tiny _Dp],y         ; not a player: explodes, no damage
              cmp     ##CONST_MT_PLAYER
              bne     19$
16$:          lda     .near tmthing
              sta     dp:.tiny (_Dp+4)
              lda     .near (tmthing+2)
              sta     dp:.tiny (_Dp+6)
17$:          ldy     ##OFS_MO_FLAGS        ; not shootable: no damage, !solid
              lda     [.tiny _Dp],y
              bit     ##CONST_MF_SHOOTABLE
              bne     18$
              brl     2$
18$:
              ldy     ##OFS_MO_TYPE         ; damage = (P_Random() % 8 + 1) *
              lda     [.tiny (_Dp+4)],y     ;   mobjinfo[tmthing->type].damage
              INFOINDEX
              tax
              lda     abs:.near (mobjinfo+OFS_MI_DAMAGE),x
              sta     .near MP_T0
              jsl     long:P_Random
              and     ##7
              inc     a
              ldx     .near MP_T0
              jsl     long:IIGS_MulLo16
              sta     .near MP_T0
              lda     .near tmthing         ; P_DamageMobj(thing, tmthing,
              sta     dp:.tiny (_Dp+4)      ;   tmthing->target, damage)
              lda     .near (tmthing+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##(OFS_MO_TARGET+2)
              lda     [.tiny (_Dp+4)],y
              pha
              ldy     ##OFS_MO_TARGET
              lda     [.tiny (_Dp+4)],y
              pha
              lda     .near MP_T0
              jsl     long:P_DamageMobj
              pla
              pla
19$:          lda     ##0
              rtl

;;; void P_SetSecnodeFirstpoolToNull(void): no free nodes (Z_FreeTags
;;; frees the pools of the level).
              .section logiccode, text
              .public P_SetSecnodeFirstpoolToNull
P_SetSecnodeFirstpoolToNull:
              stz     .near SN_FREE
              stz     .near (SN_FREE+2)
              rtl

;;; void P_SetSeclist(msecnode_t __far* sectorList)      In: _Dp[0-3].
              .public P_SetSeclist
P_SetSeclist: lda     dp:.tiny _Dp
              sta     .near _s_sector_list
              lda     dp:.tiny (_Dp+2)
              sta     .near (_s_sector_list+2)
              rtl

;;; void P_DelSeclist(void): all the nodes of _s_sector_list deleted.
              .public P_DelSeclist
P_DelSeclist: lda     .near _s_sector_list  ; X:C = the first node
              ldx     .near (_s_sector_list+2)
1$:           sep     #0x20                 ; _Dp = the node (bytes; NULL: bank 0)
              sta     dp:.tiny _Dp
              xba
              sta     dp:.tiny (_Dp+1)
              stz     dp:.tiny (_Dp+3)
              txa
              sta     dp:.tiny (_Dp+2)
              rep     #0x20
              beq     2$
              jsl     long:P_DelSecnode     ; X:C = the next node
              bra     1$
2$:           sep     #0x20                 ; _s_sector_list = NULL (byte 3 is 0)
              stz     .near _s_sector_list
              stz     .near (_s_sector_list+1)
              stz     .near (_s_sector_list+2)
              rep     #0x20
              rtl

;;; msecnode_t __far* P_DelSecnode(msecnode_t __far* node)
;;;   In: _Dp[0-3] = node. Out: X:C = the next node on the thing thread.
;;; The node leaves the thing thread and the sector thread, and is free.
;;; Bytes; _Dp[4-6] holds a pointer of the links (a NULL has bank 0).
              .public P_DelSecnode
P_DelSecnode: lda     dp:.tiny _Dp
              ora     dp:.tiny (_Dp+2)
              bne     1$
              tax
              rtl
1$:           ldy     ##OFS_SN_M_TPREV      ; tp->m_tnext = tn
              ldx     ##OFS_SN_M_TNEXT
              jsr     .kbank snLink
              ldy     ##OFS_SN_M_TNEXT      ; tn->m_tprev = tp
              ldx     ##OFS_SN_M_TPREV
              jsr     .kbank snLink
              ldy     ##OFS_SN_M_SNEXT      ; sn->m_sprev = sp
              ldx     ##OFS_SN_M_SPREV
              jsr     .kbank snLink
              ldy     ##OFS_SN_M_SPREV      ; sp->m_snext = sn
              ldx     ##OFS_SN_M_SNEXT
              jsr     .kbank snLink
              sep     #0x20
              bcs     2$
              ldy     ##OFS_SN_M_SECTOR     ; no sp: the sector thread starts
              lda     [.tiny _Dp],y         ;   at sn
              sta     dp:.tiny (_Dp+4)
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+5)
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_SN_M_SNEXT
              lda     [.tiny _Dp],y
              ldy     ##OFS_SEC_TOUCHING_THINGLIST
              sta     [.tiny (_Dp+4)],y
              ldy     ##(OFS_SN_M_SNEXT+1)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_SEC_TOUCHING_THINGLIST+1)
              sta     [.tiny (_Dp+4)],y
              ldy     ##(OFS_SN_M_SNEXT+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_SEC_TOUCHING_THINGLIST+2)
              sta     [.tiny (_Dp+4)],y
2$:           ldy     ##OFS_SN_M_TNEXT      ; the result tn (_Dp[4-6]), then
              lda     [.tiny _Dp],y         ;   the node in front of the free
              sta     dp:.tiny (_Dp+4)      ;   list (m_tnext = SN_FREE,
              iny                           ;   SN_FREE = node)
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+5)
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              lda     .near (SN_FREE+2)
              sta     [.tiny _Dp],y
              dey
              lda     .near (SN_FREE+1)
              sta     [.tiny _Dp],y
              dey
              lda     .near SN_FREE
              sta     [.tiny _Dp],y
              lda     dp:.tiny _Dp
              sta     .near SN_FREE
              lda     dp:.tiny (_Dp+1)
              sta     .near (SN_FREE+1)
              lda     dp:.tiny (_Dp+2)
              sta     .near (SN_FREE+2)
              rep     #0x20
              lda     dp:.tiny (_Dp+6)
              and     ##0x00ff
              tax
              lda     dp:.tiny (_Dp+4)
              rtl

;;; snLink: if the pointer at offset Y of the node _Dp[0-3] is not NULL, its
;;; field at offset X = the field at offset X of the node: for example
;;; tp->m_tnext = node->m_tnext. Carry set if it is not NULL. Bytes.
snLink:       sep     #0x20
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+5)
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              beq     9$                    ; (NULL: bank 0)
              txy
              lda     [.tiny _Dp],y
              sta     [.tiny (_Dp+4)],y
              iny
              lda     [.tiny _Dp],y
              sta     [.tiny (_Dp+4)],y
              iny
              lda     [.tiny _Dp],y
              sta     [.tiny (_Dp+4)],y
              rep     #0x20
              sec
              rts
9$:           rep     #0x20
              clc
              rts

;;; newSecnode: P_AddSecnode(MP_S, tmthing) when the thing has no node for
;;; the sector (addSecnode looked): a new node at the head of the thing
;;; thread (_s_sector_list) and of the sector thread. Words (bytes 3 of the
;;; pointers are 0).
newSecnode:   lda     .near SN_FREE         ; a free node
              ora     .near (SN_FREE+2)
              bne     2$
              lda     ##(SN_POOL * SIZEOF_SN) ; none: a new pool, each node
              jsl     long:Z_CallocLevel    ; linked to the next one
              sta     .near SN_FREE
              stx     .near (SN_FREE+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldx     ##(SN_POOL - 1)
1$:           lda     dp:.tiny _Dp
              clc
              adc     ##SIZEOF_SN
              ldy     ##OFS_SN_M_TNEXT
              sta     [.tiny _Dp],y
              iny
              iny
              lda     dp:.tiny (_Dp+2)
              sta     [.tiny _Dp],y
              lda     dp:.tiny _Dp
              clc
              adc     ##SIZEOF_SN
              sta     dp:.tiny _Dp
              dex
              bne     1$                    ; (the last one: NULL from the calloc)
2$:           lda     .near SN_FREE         ; node = the first free one (_Dp),
              sta     dp:.tiny _Dp          ;   SN_FREE = its m_tnext (words: no
              lda     .near (SN_FREE+2)     ;   SEP and REP; bytes 3 of the
              sta     dp:.tiny (_Dp+2)      ;   pointers are 0)
              ldy     ##OFS_SN_M_TNEXT
              lda     [.tiny _Dp],y
              sta     .near SN_FREE
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (SN_FREE+2)
              lda     ##0                   ; visited = false, no m_tprev, m_sprev
              ldy     ##OFS_SN_VISITED
              sta     [.tiny _Dp],y
              ldy     ##OFS_SN_M_TPREV
              sta     [.tiny _Dp],y
              iny
              iny
              sta     [.tiny _Dp],y
              ldy     ##OFS_SN_M_SPREV
              sta     [.tiny _Dp],y
              iny
              iny
              sta     [.tiny _Dp],y
              ldy     ##OFS_SN_M_SECTOR     ; m_sector = MP_S
              lda     .near MP_S
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (MP_S+2)
              sta     [.tiny _Dp],y
              ldy     ##OFS_SN_M_THING      ; m_thing = tmthing
              lda     .near tmthing
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (tmthing+2)
              sta     [.tiny _Dp],y
              ldy     ##OFS_SN_M_TNEXT      ; m_tnext = _s_sector_list, and its
              lda     .near _s_sector_list  ;   m_tprev = node
              sta     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     .near (_s_sector_list+2)
              sta     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              and     ##0x00ff
              beq     5$
              jsr     .kbank nodeAt         ; (its m_tprev)
5$:           lda     .near MP_S            ; m_snext = s->touching_thinglist,
              sta     dp:.tiny (_Dp+4)      ;   and its m_sprev = node
              lda     .near (MP_S+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_SEC_TOUCHING_THINGLIST
              lda     [.tiny (_Dp+4)],y
              tax
              iny
              iny
              lda     [.tiny (_Dp+4)],y     ; (its bank: 0 for NULL)
              and     ##0x00ff
              ldy     ##(OFS_SN_M_SNEXT+2)
              sta     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              beq     6$                    ; (none: a NULL)
              txa
              ldy     ##OFS_SN_M_SNEXT
              sta     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              ldy     ##(OFS_SN_M_SPREV - OFS_SN_M_TPREV)
              jsr     .kbank nodeAtY
              bra     7$
6$:           ldy     ##OFS_SN_M_SNEXT      ; (NULL: its low word 0 too)
              lda     ##0
              sta     [.tiny _Dp],y
7$:           lda     .near MP_S            ; s->touching_thinglist = node,
              sta     dp:.tiny (_Dp+4)      ;   _s_sector_list = node
              lda     .near (MP_S+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_SEC_TOUCHING_THINGLIST
              lda     dp:.tiny _Dp
              sta     [.tiny (_Dp+4)],y
              sta     .near _s_sector_list
              iny
              iny
              lda     dp:.tiny (_Dp+2)
              sta     [.tiny (_Dp+4)],y
              sta     .near (_s_sector_list+2)
              rtl

;;; nodeAt: the pointer at offset OFS_SN_M_TPREV (nodeAtY: that + Y) of the
;;; node _Dp[4-6] = the node _Dp[0-3] (words).
nodeAt:       ldy     ##0
nodeAtY:      tya
              clc
              adc     ##OFS_SN_M_TPREV
              tay
              lda     dp:.tiny _Dp
              sta     [.tiny (_Dp+4)],y
              iny
              iny
              lda     dp:.tiny (_Dp+2)
              sta     [.tiny (_Dp+4)],y
              rts
              .space  70                    ; (the code after keeps its address)

;;; ---------------------------------------------------------------------------
;;; void P_MapEnd(void): no thing moves.
;;; ---------------------------------------------------------------------------
              .public P_MapEnd
P_MapEnd:     stz     .near tmthing
              stz     .near (tmthing+2)
              rtl

;;; ---------------------------------------------------------------------------
;;; void P_InitBlockRows(void): BMROW and LN36 of the map, after
;;; P_LoadLineDefs and P_LoadBlockMap. The walks count the columns and the
;;; rows of the blocks in bytes: a map has less than 256 of each.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public P_InitBlockRows
P_InitBlockRows:
              lda     .near _g_bmapheight
              cmp     ##BMROW_MAX
              bcs     8$
              lda     .near _g_bmapwidth
              cmp     ##BMROW_MAX
              bcs     8$
              lda     .near _g_numlines
              cmp     ##(LN36_MAX + 1)
              bcc     1$
8$:           lda     ##.word0 brErr
              sta     dp:.tiny _Dp
              lda     ##.word2 brErr
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
1$:           ldx     ##0                   ; 2 * the row
              lda     ##0                   ; its first block
2$:           sta     long:BMROW,x
              clc
              adc     .near _g_bmapwidth
              inx
              inx
              cpx     ##(2 * BMROW_MAX)
              bcc     2$
              ldx     ##0                   ; 2 * the line
              lda     .near _g_lines        ; its address
              ldy     .near _g_numlines
              beq     4$
3$:           sta     long:LN36,x
              clc
              adc     ##SIZEOF_LINE
              inx
              inx
              dey
              bne     3$
4$:           rtl

brErr:        .asciz  "P_InitBlockRows: the map is too large"

              .section logiccode, text
;;; ---------------------------------------------------------------------------
;;; blockRange: for P_TeleportMove, the blocks of the box _g_tmbbox, grown by C whole units on
;;; each side, clamped to the map: MP_XL..MP_XH, MP_YL..MP_YH.
;;; The C loops skip the blocks outside the map, so the clamp keeps the
;;; order of the blocks. Out: C = 1 if there are no blocks.
;;; ---------------------------------------------------------------------------
blockRange:   sta     .near MP_D
              lda     .near (_g_tmbbox + 4*CONST_BOXLEFT)    ; (left - orgx - d) >> 23
              sec
              sbc     .near _g_bmaporgx
              lda     .near (_g_tmbbox + 4*CONST_BOXLEFT + 2)
              sbc     .near (_g_bmaporgx+2)
              sec
              sbc     .near MP_D
              SHR7
              bpl     1$
              lda     ##0
1$:           sta     .near MP_XL
              lda     .near (_g_tmbbox + 4*CONST_BOXRIGHT)   ; (right - orgx + d) >> 23
              sec
              sbc     .near _g_bmaporgx
              lda     .near (_g_tmbbox + 4*CONST_BOXRIGHT + 2)
              sbc     .near (_g_bmaporgx+2)
              clc
              adc     .near MP_D
              SHR7
              cmp     .near _g_bmapwidth    ; small values: cmp is a signed compare
              bmi     2$
              lda     .near _g_bmapwidth
              dec     a
2$:           sta     .near MP_XH
              lda     .near (_g_tmbbox + 4*CONST_BOXBOTTOM)  ; (bottom - orgy - d) >> 23
              sec
              sbc     .near _g_bmaporgy
              lda     .near (_g_tmbbox + 4*CONST_BOXBOTTOM + 2)
              sbc     .near (_g_bmaporgy+2)
              sec
              sbc     .near MP_D
              SHR7
              bpl     3$
              lda     ##0
3$:           sta     .near MP_YL
              lda     .near (_g_tmbbox + 4*CONST_BOXTOP)     ; (top - orgy + d) >> 23
              sec
              sbc     .near _g_bmaporgy
              lda     .near (_g_tmbbox + 4*CONST_BOXTOP + 2)
              sbc     .near (_g_bmaporgy+2)
              clc
              adc     .near MP_D
              SHR7
              cmp     .near _g_bmapheight
              bmi     4$
              lda     .near _g_bmapheight
              dec     a
4$:           sta     .near MP_YH
              cmp     .near MP_YL
              bmi     9$
              lda     .near MP_XH
              cmp     .near MP_XL
              bmi     9$
              clc
              rtl
9$:           sec
              rtl

              .section logiccode, text
;;; ---------------------------------------------------------------------------
;;; boolean P_TeleportMove(mobj_t __far* thing, fixed_t x, fixed_t y, boolean boss)
;;;   In: _Dp[0-3] = thing, X:C = x, _Dp[4-7] = y, 4,s = boss. Out: C.
;;; The thing moves to x, y. A shootable thing in the way dies (telefrag)
;;; when the thing is the player or boss is true, else it stops the move.
;;; ---------------------------------------------------------------------------
              .public P_TeleportMove
P_TeleportMove:
              sta     .near tmx
              sta     .near MP_TPX
              stx     .near (tmx+2)
              stx     .near (MP_TPX+2)
              lda     dp:.tiny (_Dp+4)
              sta     .near tmy
              sta     .near MP_TPY
              lda     dp:.tiny (_Dp+6)
              sta     .near (tmy+2)
              sta     .near (MP_TPY+2)
              lda     dp:.tiny _Dp
              sta     .near tmthing
              sta     .near MP_TPT
              lda     dp:.tiny (_Dp+2)
              sta     .near (tmthing+2)
              sta     .near (MP_TPT+2)
              lda     4,s                   ; telefrag = the player || boss
              and     ##0x00ff
              sta     .near MP_TELEFRAG
              lda     .near tmthing
              cmp     .near (_g_player+OFS_PL_MO)
              bne     1$
              lda     .near (tmthing+2)
              cmp     .near (_g_player+OFS_PL_MO+2)
              bne     1$
              inc     .near MP_TELEFRAG
1$:           jsl     long:setBoxL
              jsl     long:baseFloorL
              lda     ##32                  ; the things in the blocks grown by
              jsl     long:blockRange       ; MAXRADIUS (the loop state is on the
              bcs     5$                    ; stack: P_DamageMobj runs game logic)
              lda     .near MP_YH
              pha
              lda     .near MP_YL
              pha
              lda     .near MP_XH
              pha
              lda     .near MP_XL
              pha                           ; 1,s bx, 3,s XH, 5,s YL, 7,s YH
2$:           lda     5,s                   ; by = YL
              pha                           ; 1,s by, 3,s bx, 5,s XH, 9,s YH
3$:           lda     1,s                   ; P_BlockThingsIterator(bx, by, stompThing)
              sta     dp:.tiny _Dp
              lda     ##.word0 stompThing
              sta     dp:.tiny (_Dp+4)
              lda     ##.word2 stompThing
              sta     dp:.tiny (_Dp+6)
              lda     3,s
              jsl     long:P_BlockThingsIterator
              cmp     ##0
              bne     4$
              pla                           ; a thing in the way: false
              pla
              pla
              pla
              pla
              lda     ##0
              rtl
4$:           lda     1,s                   ; by++ while by <= YH
              inc     a
              sta     1,s
              dec     a
              cmp     9,s
              bcc     3$
              pla                           ; bx++ while bx <= XH
              lda     1,s
              inc     a
              sta     1,s
              dec     a
              cmp     3,s
              bcc     2$
              pla
              pla
              pla
              pla
5$:           jsr     .kbank tpThing        ; out of the old blocks and sectors
              jsl     long:P_UnsetThingPosition
              jsr     .kbank tpThing        ; floorz, ceilingz, dropoffz, x, y
              CLEARCLEAN _Dp
              ldy     ##OFS_MO_FLOORZ
              lda     .near _g_tmfloorz
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (_g_tmfloorz+2)
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_CEILINGZ
              lda     .near _g_tmceilingz
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (_g_tmceilingz+2)
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_DROPOFFZ
              lda     .near _g_tmdropoffz
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (_g_tmdropoffz+2)
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_X
              lda     .near MP_TPX
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (MP_TPX+2)
              sta     [.tiny _Dp],y
              ldy     ##OFS_MO_Y
              lda     .near MP_TPY
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (MP_TPY+2)
              sta     [.tiny _Dp],y
              jsl     long:P_SetThingPosition ; into the new ones
              lda     ##1
              rtl

;;; tpThing: _Dp[0-3] = the thing of P_TeleportMove.
tpThing:      lda     .near MP_TPT
              sta     dp:.tiny _Dp
              lda     .near (MP_TPT+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; stompThing: PIT_StompThing(the thing at _Dp[0-3]): a shootable thing
;;; (not tmthing) in the way dies when telefrag, else it blocks the move.
stompThing:   lda     dp:.tiny _Dp          ; not tmthing
              cmp     .near tmthing
              bne     1$
              lda     dp:.tiny (_Dp+2)
              cmp     .near (tmthing+2)
              beq     9$
1$:           ldy     ##OFS_MO_FLAGS        ; shootable
              lda     [.tiny _Dp],y
              and     ##CONST_MF_SHOOTABLE_LO
              beq     9$
              lda     .near tmthing
              sta     dp:.tiny (_Dp+4)
              lda     .near (tmthing+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_MO_RADIUS       ; blockdist = thing->radius + tmthing->radius
              lda     [.tiny _Dp],y
              clc
              adc     [.tiny (_Dp+4)],y
              sta     .near MP_T1
              iny
              iny
              lda     [.tiny _Dp],y
              adc     [.tiny (_Dp+4)],y
              sta     .near (MP_T1+2)
              ldy     ##OFS_MO_X            ; |thing->x - tmx| >= blockdist: true
              ldx     ##.near tmx
              jsr     .kbank farFrom
              bpl     9$
              ldy     ##OFS_MO_Y            ; |thing->y - tmy| >= blockdist: true
              ldx     ##.near tmy
              jsr     .kbank farFrom
              bpl     9$
              lda     .near MP_TELEFRAG     ; no telefrag: blocked
              beq     8$
              lda     .near (tmthing+2)     ; P_DamageMobj(thing, tmthing, tmthing, 10000)
              pha
              lda     .near tmthing
              pha
              lda     ##10000
              jsl     long:P_DamageMobj
              pla
              pla
9$:           lda     ##1
8$:           rtl

;;; farFrom: N clear if |the fixed_t at offset Y of the thing _Dp[0-3] -
;;; the fixed_t at near X| >= MP_T1, a signed compare as the C code.
farFrom:      lda     [.tiny _Dp],y
              sec
              sbc     abs:0,x
              sta     .near MP_T0
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     abs:2,x
              bpl     1$
              tax
              lda     ##0
              sec
              sbc     .near MP_T0
              sta     .near MP_T0
              txa
              eor     ##0xffff
              adc     ##0
1$:           sta     .near (MP_T0+2)
              lda     .near MP_T0
              cmp     .near MP_T1
              lda     .near (MP_T0+2)
              SLT32   .near (MP_T1+2)
              rts
