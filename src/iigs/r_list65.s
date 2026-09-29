;;; The column lists of the 3D view.
;;;
;;; Each frame, the walls, floors, ceilings, sprites, masked walls and
;;; shadows of the 3D view become records in the lists of their columns
;;; (lists.inc). R_DrawLists draws all lists at the end of the frame, column
;;; by column, with SHR shadowing on. The screen keeps the frame before
;;; while the new one is made, and then gets the new frame in one pass. The
;;; drawers do the slow screen writes while the accelerator goes on with
;;; their register work.
;;;
;;; RECBANK is bank $1D (memmap.inc), within the cached address range.
;;; COLPAGE skips pages whose cache slots hold the direct pages and replay
;;; code; keep that exclusion when changing the record layout (lists.inc).
;;; COLW holds each column list's next free page/offset.

              .rtmodel version, "1"
              .rtmodel core, "*"

              .extern IIGS_SetShadow

#include "offsets.inc"
#include "lists.inc"
#include "wpage.inc"
#include "viewwin.inc"

              .extern _DirectPageStart, _NearBaseAddress, iigs_shrcmapA
              .extern _Dp, I_Error
              .extern DC_ROW, DC_COUNT, DC_COLX, DC_FRAC, DC_FSTEP, DC_SRC
              .extern DC_CMA, DC_CMB, DC_FLATW, DC_TI, DC_SF, DC_SI
              .extern DC_ENTRY, DC_EXITP
              .extern fuzzColumn, texEntryLo, texEntryHi, texBlocks
              .extern SEGPATCH, SEGPATCHT, R_RenderSegLoop, AM_MODE, AM_Clean
              .extern flatBlocks, scRowTab, texImgH, TEXIMG_SIZE
              .extern texImgT, TEXIMGT_SIZE, TFLAT_ADDR, texEntryLoT, texEntryHiT
              .extern viewtop, viewbottom
              .public O_PAGE2, Q_PAGE2

BUF_BANK      .equ    0x01
SHADOW        .equ    0xe0c035
CMAP_B        .equ    34              ; iigs_shrcmapB - iigs_shrcmapA, in pages
TEXBANK       .equ    0x050000        ; the bank of texBlocks (section hotdraw,
                                      ; src/iigs/iigs.scm): drawTex patches the
                                      ; blocks with long addresses
;;; The block of each row of texBlocks: its address, low and high bytes
;;; (texEntryLo, texEntryHi of tools/gendraw.py), copied into BUF_BANK, the
;;; data bank of the drawers, in cache slots that the view stores never use.
;;; The exit patch changes a row's first byte to JMP indirect ($6C).
;;; Smaller views use EB 65 04 -> JMP ($0465). Full-view pairs use EB 65 05
;;; on odd rows and 98 65 07 on even rows: JMP ($0565) or JMP ($0765).
;;; Replay saves these text-page words and restores each row's own opcode.
TEXRET_PTR    .equ    0x000465
TEXLO         .equ    0x1e41
TEXHI         .equ    TEXLO + CONST_VIEWHEIGHT + 1

              .section ztiny, bss
RL_P:         .space  2               ; the next record
RL_E:         .space  2               ; the end of the list of the column
RL_C:         .space  2               ; the column (the high byte is 0)
RL_I:         .space  2               ; the index into colOrder (a byte)
RL_TENT:      .space  2               ; drawTex: the block of the first row,
RL_XO:        .space  3               ;   the block after the last row (long)
RL_FENT:      .space  2               ; drawFill: the block of the first row
RL_FX:        .space  3               ; the bank of the blocks, offset 0 (long)
RL_OD:        .space  1               ; (bytes of halfAll and thirdAll: RL_HA,
RL_RB:        .space  1               ;   RL_HB)
RL_CV0P:      .space  1               ; the covered range of the column
RL_CV0:       .space  1               ;   (lists.inc CV_ROW): its first row + 1
RL_CV1:       .space  1               ;   (255: no cut), its first row, the row
                                      ;   after it
RL_CE:        .space  2               ; the end of the list after the cut
;;; halfAll (the half view) in bytes that it does not use otherwise: the
;;; column of the lists, the first row of a record, the row after its last,
;;; its first half row and the half row after its last, the fill bytes of the
;;; even and odd rows, the step and the position (TF, TI) of a texture
;;; record (drawer inputs of the C code that the lists do not use; a flush
;;; keeps them, RL_SAVE).
RL_HC         .equ    RL_I
RL_HA         .equ    RL_OD
RL_HB         .equ    RL_RB
RL_HK0        .equ    DC_TI
RL_HK1        .equ    DC_TI+1
RL_FE         .equ    DC_FLATW
RL_FO         .equ    DC_FLATW+1
RL_HS         .equ    DC_FSTEP
RL_HP         .equ    DC_FRAC
RL_K          .equ    DC_ENTRY        ; texStart: the rows to step, the step
RL_ST         .equ    DC_ENTRY+2      ;   (drawer inputs that the lists do not
RL_T          .equ    DC_EXITP        ;   use); fillStart: a byte

              .section znear, bss
              .public COLW, XPNEXT
COLW:         .space  2 * CONST_VIEWWIDTH ; the free byte of the list of each
                                      ; column: the page << 8 | the offset
XPNEXT:       .space  2               ; the next extra page (a byte; 0: none left)
colOrder:     .space  2 * CONST_VIEWWIDTH ; 2 * the columns, in the order of the
                                      ; drawing
RA_SIZE:      .space  2               ; recAlloc: the size of the record
RL_DETW:      .space  2               ; requested full-view image: $100
RL_DETI:      .space  2               ; current row image; full pairs use $100

              .section zfar, bss
RL_SAVE:      .space  0x2c            ; the drawer inputs of the direct page
                                      ; during a flush

;;; ---------------------------------------------------------------------------
;;; void R_InitLists(void): no records.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public R_InitLists, R_DrawLists, newPage
              .public recAlloc, recTex, recFuzz, recOvl, fillCol
R_InitLists:  jsl     long:initColw         ; each column: its own page, offset
              .space  14                    ;   0 (the old loop's bytes: the cold
                                            ;   code after it keeps its address)
              lda     ##XP_FIRST            ; no extra page used
              sta     long:XPNEXT
              lda     ##.byte2 texBlocks    ; texBlocks in TEXBANK
              cmp     ##(TEXBANK >> 16)
              beq     2$
              lda     ##.word0 errTexBank
              sta     dp:.tiny _Dp
              lda     ##.word2 errTexBank
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
2$:           sep     #0x20                 ; TEXLO, TEXHI
              ldx     ##CONST_VIEWHEIGHT
3$:           lda     long:texEntryLo,x
              sta     long:(BUF_BANK * 0x10000 + TEXLO),x
              lda     long:texEntryHi,x
              sta     long:(BUF_BANK * 0x10000 + TEXHI),x
              dex
              bpl     3$
              lda     #.byte2 texBlocks     ; the bank of the blocks
              sta     dp:.tiny (RL_XO+2)
              sta     dp:.tiny (RL_FX+2)
              stz     dp:.tiny RL_FX
              stz     dp:.tiny (RL_FX+1)
              stz     dp:.tiny (RL_C+1)
              rep     #0x20
              jmp     long:fsInit           ; no fill spans yet

              .section cnear, rodata
errTexBank:   .asciz  "R_InitLists: texBlocks is not in TEXBANK"
              .section coldcode, text

              .section detailimg, text     ; (cold, src/iigs/iigs.scm)
;;; ---------------------------------------------------------------------------
;;; void R_FillStamps(void): the stamps of the fill spans (lists.inc) of
;;; this frame, before R_RenderPlayerView. W_FSC = the next frame (a byte).
;;; W_FSP = W_FSC - 1 when the screen shows the view of the frame before
;;; (W_FSW) with the same first row and the same row after the view, else
;;; W_FSC: no span has it. Each 128 frames all stamps get a value that no
;;; frame of the next 127 uses (fsFill). fsInit: no spans (R_InitLists).
;;; DBR = the near bank.
;;; ---------------------------------------------------------------------------
              .public R_FillStamps
R_FillStamps: jsl     long:segMode          ; (the loops for the view)
              php
              sep     #0x20
              ldy     ##0                   ; Y = 1: the old spans show
              lda     long:(WPAGE+W_FSW)
              beq     1$
              iny
1$:           lda     .near viewtop         ; the first row of the view
              inc     a
              cmp     long:(WPAGE+W_TOPR)
              beq     2$
              sta     long:(WPAGE+W_TOPR)   ; (another one: no old spans)
              ldy     ##0
2$:           lda     .near viewbottom      ; the row after the view
              cmp     long:(WPAGE+W_BOTR)
              beq     3$
              sta     long:(WPAGE+W_BOTR)
              ldy     ##0
3$:           lda     #0x80                 ; no plane colors of the frame
              sta     long:(WPAGE+W_LCC+1)  ;   before (the colormaps can
              sta     long:(WPAGE+W_LFC+1)  ;   change between frames)
              lda     long:(WPAGE+W_FSC)    ; the stamp of this frame
              inc     a
              sta     long:(WPAGE+W_FSC)
              bit     #0x7f
              bne     4$
              jsr     .kbank fsFill
4$:           cpy     ##0
              beq     5$
              dec     a
5$:           sta     long:(WPAGE+W_FSP)
              plp
              rtl

;;; fsFill: all stamps = A ^ 0x80. 8-bit A, kept.
fsFill:       eor     #0x80
              ldx     ##(2 * CONST_VIEWWIDTH - 1)
1$:           sta     long:FS_STAMP,x
              dex
              bpl     1$
              eor     #0x80
              rts

fsInit:       php
              sep     #0x20
              lda     #0
              sta     long:(WPAGE+W_FSC)
              sta     long:(WPAGE+W_FSG)
              jsr     .kbank fsFill
              plp
              rtl

;;; ---------------------------------------------------------------------------
;;; void R_SetDetail(int16_t ignored): the full-view pair image and entries.
;;; Smaller views install their scaled pair images before replay.
;;; The paired rows start at texBlocks + 1: the flat drawer restores the
;;; shared end marker at texBlocks to XBA. Do not call during R_DrawLists.
;;; ---------------------------------------------------------------------------
              .public R_SetDetail
R_SetDetail:  lda     ##0x0100
              sta     long:RL_DETW
R_SetDetailI: brl     pairSetDetail
              .space  34 - (. - R_SetDetailI)
;;; initColw (R_InitLists, R_ViewMode): COLW of each column = its first page
;;; in the map of the view (the 2/3 view: T_PAGE2, else COLPAGE), offset 0;
;;; the order of the drawing: left to right. The replay takes the first page
;;; of a list from that map, so a new view needs its map before its records.
initColw:     lda     long:VW_THIRD
              and     ##0x00ff
              bne     5$
              ldx     ##(2 * CONST_VIEWWIDTH - 2)
1$:           txa
              sta     long:colOrder,x
              lsr     a
              sep     #0x20
              COLPAGE
              xba
              lda     #0
              rep     #0x20
              sta     long:COLW,x
              dex
              dex
              bpl     1$
              rtl
5$:           ldx     ##(2 * CONST_VIEWWIDTH - 2)
6$:           txa
              sta     long:colOrder,x
              lda     long:T_PAGE2,x        ; (a zero after each page)
              xba
              sta     long:COLW,x
              dex
              dex
              bpl     6$
              rtl
              .space  103 - 37 - 31         ; (the low path's bytes: the menu code
                                            ;   after it keeps its address)
              .section coldcode, text

;;; ---------------------------------------------------------------------------
;;; recAlloc: room for a record of C bytes (16-bit A, X, Y) at the end of
;;; the list of column X / 2 (X = 2 * the column, kept). Out: Y = the
;;; record, COLW past it. DBR = RECBANK.
;;; ---------------------------------------------------------------------------
recAlloc:     sta     long:RA_SIZE
1$:           lda     long:COLW,x           ; the free byte of the list
              tay
              and     ##0x00ff
              clc
              adc     long:RA_SIZE
              cmp     ##(PAGE_ROOM + 1)
              bcs     2$                    ; (no room in the page)
              sep     #0x20
              sta     long:COLW,x           ; the offset after the record
              rep     #0x20
              rtl
2$:           jsl     long:newPage
              lda     long:RA_SIZE
              bra     1$

;;; newPage: the list of column X / 2 goes on in the next extra page: a
;;; K_NEXT record at the free byte Y, then COLW = the new page, offset 0.
;;; With no extra page left, all lists are drawn first (then COLW is the
;;; first page of the column again). Out: Y = COLW. 16-bit A, X, Y; X kept;
;;; DBR = RECBANK. Any direct page.
newPage:      sep     #0x20
              lda     long:XPNEXT
              beq     9$                    ; (no extra page left)
              sta     abs:R_PAGE,y          ; K_NEXT: the new page
              xba                           ; (B = the page)
              lda     #K_NEXT
              sta     abs:R_KIND,y
              lda     #0                    ; COLW = the page, offset 0
              sta     long:COLW,x
              xba
              sta     long:(COLW+1),x
              inc     a                     ; the next extra page, 0 after the
              sta     long:XPNEXT           ;   last one
              rep     #0x20
              lda     long:COLW,x
              tay
              rtl
9$:           rep     #0x20
              phx
              jsr     .kbank flush
              plx
              lda     long:COLW,x
              tay
              rtl

;;; flush: all lists drawn now (no extra page left). The direct page and the
;;; drawer inputs of the caller stay.
flush:        phb
              phd
              lda     ##.word0 _DirectPageStart
              tcd
              ldx     ##(0x2c - 2)
1$:           lda     dp:0,x
              sta     long:RL_SAVE,x
              dex
              dex
              bpl     1$
              jsl     long:drawAllL
              ldx     ##(0x2c - 2)
2$:           lda     long:RL_SAVE,x
              sta     dp:0,x
              dex
              dex
              bpl     2$
              pld
              plb
              rts

;;; ---------------------------------------------------------------------------
;;; recTex: a K_TEX record (C = the kind) from the drawer inputs
;;; of the direct page: DC_COLX, DC_ROW, DC_COUNT, DC_FRAC, DC_FSTEP,
;;; DC_SRC, DC_CMA (the colormap of the even rows). Any data bank.
;;; recFuzz: a K_FUZZ record from DC_COLX, DC_ROW, DC_COUNT, fuzz position
;;; C.
;;; recOvl: a K_OVL record: a pixel of an automap line, from DC_COLX,
;;; DC_ROW, DC_FLATW (the nibble to keep | the color nibble << 8).
;;; fillCol: a floor, ceiling or flat column as a K_FILL record: DC_ROW,
;;; DC_COUNT, DC_COLX, DC_FLATW (the byte of the even rows | the byte of
;;; the odd rows << 8).
;;; Each is one record at the end of the list of the column; 16-bit A, X,
;;; Y in and out.
;;; ---------------------------------------------------------------------------
recTex:       pha                           ; the kind
              phb
              lda     ##TEX_SIZE
              jsr     .kbank recStart       ; Y = the record
              lda     dp:.tiny DC_ROW       ; the fill spans of the column end
              clc                           ;   at its rows (lists.inc)
              adc     dp:.tiny DC_COUNT
              FSCUTE  dp:.tiny DC_ROW
              lda     2,s
              sta     abs:R_KIND,y
              lda     dp:.tiny DC_ROW       ; the rows: the first, the row after
              sta     abs:R_ROW,y           ;   the last
              clc
              adc     dp:.tiny DC_COUNT
              sta     abs:R_END,y
              lda     dp:.tiny (DC_FRAC+1)  ; the position >> 1: TF, TI
              lsr     a
              sta     abs:R_TI,y
              lda     dp:.tiny DC_FRAC
              ror     a
              sta     abs:R_TF,y
              lda     dp:.tiny (DC_FSTEP+1) ; the step >> 1: SF, SI
              lsr     a
              sta     abs:R_SI,y
              lda     dp:.tiny DC_FSTEP
              ror     a
              sta     abs:R_SF,y
              lda     dp:.tiny DC_SRC       ; the texels
              sta     abs:R_SRC,y
              lda     dp:.tiny (DC_SRC+1)
              sta     abs:(R_SRC+1),y
              lda     dp:.tiny (DC_SRC+2)
              sta     abs:(R_SRC+2),y
              lda     dp:.tiny (DC_CMA+1)   ; the colormap of the even rows
              sta     abs:R_CMP,y
              CVSETY  dp:.tiny DC_ROW       ; (lists.inc)
              rep     #0x20
              plb
              pla
              rtl

recFuzz:      pha                           ; the fuzz position
              phb
              lda     ##FUZZ_SIZE
              jsr     .kbank recStart
              lda     dp:.tiny DC_ROW       ; the fill spans of the column end
              clc                           ;   at its rows (lists.inc)
              adc     dp:.tiny DC_COUNT
              FSCUTE  dp:.tiny DC_ROW
              lda     #255                  ; no covered range in the column
              sta     long:CV_ROW,x         ;   (lists.inc)
              lda     #K_FUZZ
              sta     abs:R_KIND,y
              lda     #254
              sta     long:(CV_ROW+1),x
              lda     dp:.tiny DC_ROW
              sta     abs:R_ROW,y
              lda     dp:.tiny DC_COUNT
              sta     abs:R_COUNT,y
              lda     2,s
              sta     abs:R_POS,y
              rep     #0x20
              plb
              pla
              rtl

recOvl:       phb
              lda     ##OVL_SIZE
              jsr     .kbank recStart
              lda     dp:.tiny DC_ROW       ; the fill spans of the column end
              inc     a                     ;   at its row (lists.inc)
              FSCUTE  dp:.tiny DC_ROW
              lda     #K_OVL
              sta     abs:R_KIND,y
              lda     dp:.tiny DC_ROW
              sta     abs:R_ROW,y
              lda     dp:.tiny DC_FLATW
              sta     abs:R_KEEP,y
              lda     dp:.tiny (DC_FLATW+1)
              sta     abs:R_COLOR,y
              rep     #0x20
              plb
              rtl

fillCol:      phb
              lda     ##FILL_SIZE
              jsr     .kbank recStart
              lda     dp:.tiny DC_ROW       ; the fill spans of the column end
              clc                           ;   at its rows (lists.inc)
              adc     dp:.tiny DC_COUNT
              FSCUTE  dp:.tiny DC_ROW
              lda     #K_FILL
              sta     abs:R_KIND,y
              lda     dp:.tiny DC_ROW       ; the rows: the first, the row after
              sta     abs:R_ROW,y           ;   the last
              clc
              adc     dp:.tiny DC_COUNT
              sta     abs:R_END,y
              lda     dp:.tiny DC_ROW       ; an odd first row: the byte of the
              lsr     a                     ;   odd rows first
              lda     dp:.tiny DC_FLATW
              bcs     1$
              sta     abs:R_B1,y
              lda     dp:.tiny (DC_FLATW+1)
              sta     abs:R_B2,y
              bra     2$
1$:           sta     abs:R_B2,y
              lda     dp:.tiny (DC_FLATW+1)
              sta     abs:R_B1,y
2$:           rep     #0x20
              plb
              rtl

;;; recStart: DBR = RECBANK, Y = a record of C bytes at the end of the list
;;; of column DC_COLX. Out: 8-bit A.
recStart:     pha
              sep     #0x20
              lda     #RECBANK
              pha
              plb
              rep     #0x20
              lda     dp:.tiny DC_COLX
              asl     a
              tax
              pla
              jsl     long:recAlloc
              sep     #0x20
              rts

;;; ---------------------------------------------------------------------------
;;; The drawers of the rare kinds: from the table of drawAll, with Y = the
;;; record; back to done with X = the next record. 8-bit A, 16-bit X, Y,
;;; DBR = BUF_BANK, the direct page of the drawers. Own cache slots (listfuzz,
;;; listovl): in coldcode they shared slots with texBlocks, and a spectre
;;; column and a texture column pushed each other out (-6 ms a spectre frame).
;;; ---------------------------------------------------------------------------
              .section listfuzz, text

;;; drawFuzz: the shadow drawer, fuzzColumn of src/iigs/r_sprite65.s.
drawFuzz:     tyx
              rep     #0x20
              lda     long:(RECBASE+R_ROW),x
              and     ##0x00ff
              sta     dp:.tiny DC_ROW
              lda     long:(RECBASE+R_COUNT),x
              and     ##0x00ff
              sta     dp:.tiny DC_COUNT
              lda     dp:.tiny RL_C
              sta     dp:.tiny DC_COLX
              txa                           ; the next record
              clc
              adc     ##FUZZ_SIZE
              sta     dp:.tiny RL_P
              lda     long:(RECBASE+R_POS),x
              and     ##0x00ff
              jsl     long:fuzzColumn
              sep     #0x20
              ldx     dp:.tiny RL_P
              jmp     long:done

              .section listovl, text        ; (src/iigs/iigs.scm)
;;; drawOvl: an automap pixel over the view, then the K_OVL records after it
;;; in this loop (they end each list: the map is drawn after the view).
;;; 8-bit A: the 16-bit indexes by TAX with B (no REP/SEP a pixel).
drawOvl:      tyx
1$:           lda     long:(RECBASE+R_KEEP),x
              sta     dp:.tiny DC_FLATW
              lda     long:(RECBASE+R_COLOR),x
              sta     dp:.tiny (DC_FLATW+1)
              lda     long:(RECBASE+R_ROW),x
              asl     a                     ; X = 2 * the row
              xba
              lda     #0
              rol     a
              xba
              tax
              lda     long:scRowTab,x       ; X = its byte of the column
              clc
              adc     dp:.tiny RL_C
              xba
              lda     long:(scRowTab+1),x
              adc     #0
              xba
              tax
              lda     abs:0,x
              and     dp:.tiny DC_FLATW
              ora     dp:.tiny (DC_FLATW+1)
              sta     abs:0,x
              lda     dp:.tiny (RL_P+1)     ; the next record, in the same page
              xba
              tya
              clc
              adc     #OVL_SIZE
              tax
              tay
              cpx     dp:.tiny RL_E         ; (the end: done)
              beq     2$
              lda     long:(RECBASE+R_KIND),x
              cmp     #K_OVL
              beq     1$
2$:           jmp     long:done


;;; ---------------------------------------------------------------------------
;;; The replay: in its own cache slots (section hotlist, src/iigs/iigs.scm),
;;; away from the direct pages, the stack, the colormaps and the hot data.
;;; void R_DrawLists(void): all lists (drawAll), then SHR shadowing off (the
;;; end of the 3D view). The direct page is the one of the drawers (the C
;;; code).
;;; ---------------------------------------------------------------------------
              .section hotlist, text
R_DrawLists:  jsr     .kbank drawSel
              php
              sep     #0x20
              lda     long:SHADOW
              ora     #0x08                 ; SHR shadowing off
              jsl     long:IIGS_SetShadow
              plp
              rtl

;;; drawAll, drawAllL (a long call): the lists of all columns, in the order
;;; of colOrder, then no records. SHR shadowing is on while they are drawn,
;;; then as it was. The drawers get X = the record with 8-bit A, 16-bit X,
;;; Y, and go back to done with X = the next record. The records are read
;;; with long addresses: DBR is the bank of the screen for the drawers.
drawAllL:     jsr     .kbank drawSel
              rtl
drawAll:      php
              rep     #0x20
              brl     pairBegin
              .space  9
pairBeginDone:
              phb
              rep     #0x10
              sep     #0x20
              lda     #BUF_BANK             ; the data bank of the drawers
              pha
              plb
              lda     long:SHADOW
              pha
              and     #0xf7                 ; SHR shadowing on
              jsl     long:IIGS_SetShadow
              lda     #.byte2 iigs_shrcmapA ; the bank of the colormaps (once
              sta     dp:.tiny (DC_CMA+2)   ;   a frame)
              sta     dp:.tiny (DC_CMB+2)
              lda     #255                  ; no cut
              sta     dp:.tiny RL_CV0P
              lda     #0
              sta     dp:.tiny RL_I
col:          sta     dp:.tiny RL_C         ; c = the next column, left to right
              asl     a                     ;   (A = the index RL_I, 8 bits), X =
              xba                           ;   2c: bit 8 of 2c into B, as TAX
              lda     #0                    ;   with 8-bit A and 16-bit X copies B
              rol     a                     ;   too (no REP/SEP: each costs a slow
              xba                           ;   cycle)
              tax
              lda     long:(CV_ROW+1),x     ; a covered range (lists.inc)?
              bne     cvCol
              lda     long:COLW,x           ; the end of the list
              sta     dp:.tiny RL_E
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_E+1)
col2:         lda     #0                    ; no records for the next frame:
              sta     long:COLW,x           ;   COLPAGE(c), offset 0
              lda     dp:.tiny RL_C
              COLPAGE
              sta     long:(COLW+1),x
              sta     dp:.tiny (RL_P+1)     ; (the page of the records)
              xba                           ; X = that page, offset 0: the first
              lda     #0                    ;   record (TAX copies B too)
              tax
              brl     done

;;; cvCol: column X / 2 has a covered range (lists.inc CV_ROW; A = the row
;;; after it). The records before its covering record do not paint its rows
;;; (cutTex, cutFill); done stops the cut at the covering record (cvEnd).
;;; The next frame starts with no range.
cvCol:        sta     dp:.tiny RL_CV1
              lda     long:CV_ROW,x         ; the first row (255: a shadow, no
              cmp     dp:.tiny RL_CV1       ;   range)
              bcs     1$
              sta     dp:.tiny RL_CV0
              inc     a
              sta     dp:.tiny RL_CV0P
              lda     long:COLW,x           ; the end of the list after the cut
              sta     dp:.tiny RL_CE
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_CE+1)
              lda     long:CV_REC,x         ; the cut ends at the covering record
              sta     dp:.tiny RL_E
              lda     long:(CV_REC+1),x
              sta     dp:.tiny (RL_E+1)
              bra     2$
1$:           lda     long:COLW,x           ; the end of the list
              sta     dp:.tiny RL_E
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_E+1)
2$:           lda     #0
              sta     long:CV_ROW,x
              sta     long:(CV_ROW+1),x
              brl     col2

;;; cutTex: a K_TEX record before the covering record, past the first
;;; covered row c0 (A = its row after the last e, Y = its first row a, B =
;;; 0): no rows when all are in the range; the rows a .. c0 - 1 when it ends
;;; in the range; the rows c1 .. e - 1 when it starts in the range
;;; (texStart); else all rows.
cutTex:       xba                           ; B = e
              tya                           ; A = a
              cmp     dp:.tiny RL_CV1       ; a >= c1: all rows
              bcs     texAll
              cmp     dp:.tiny RL_CV0
              xba                           ; A = e, B = a
              bcc     5$
              cmp     dp:.tiny RL_CV1       ; a >= c0, e <= c1: no rows
              beq     skipTex
              bcc     skipTex
              brl     texStart
5$:           cmp     dp:.tiny RL_CV1       ; a < c0, e > c1: all rows
              beq     6$
              bcs     texAllE
6$:           lda     dp:.tiny RL_CV0       ; a < c0, e <= c1: the rows a ..
texAllE:      xba                           ;   c0 - 1; Y = the row after the
              lda     #0                    ;   last (B = 0: TAY copies B too)
              xba
              tay
              brl     texEndY
texAll:       xba
              bra     texAllE
skipTex:      txa                           ; the next record, in the same
              clc                           ;   page (RL_P + 1): TAX copies B
              adc     #TEX_SIZE             ;   too, no REP/SEP
              xba
              lda     dp:.tiny (RL_P+1)
              xba
              tax
              lda     long:(RECBASE+R_KIND),x ; a K_TEXC after it takes its
              cmp     #K_TEXC               ;   step, colormap and texel bank
              bne     1$                    ;   (skipLoad)
              brl     skipLoad
1$:           brl     done

;;; rec: the record at X, 8-bit A: the kind (K_TEX is 0), then the first
;;; row, as two byte reads (the same two uncached bytes as one 16-bit read,
;;; and no REP/SEP pair: each costs a slow cycle).
notTex8:      xba                           ; B = the kind
              lda     long:(RECBASE+R_ROW),x
              xba                           ; A = the kind, B = the first row
              brl     notTex
rec:          lda     long:(RECBASE+R_KIND),x
              bne     notTex8
              xba                           ; B = 0
              lda     long:(RECBASE+R_ROW),x

;;; drawTex: rows R_ROW .. R_END - 1 with the stepping drawer (texBlocks of
;;; tools/gendraw.py). Its inputs are bytes: the texels, the pages of the
;;; colormaps (the blocks write the texel into the low byte of DC_CMA and
;;; DC_CMB), SF and SI, the block of the first row, and the block after the
;;; last row patched to JMP indirect. The blocks use 8-bit A, X, Y; B = the
;;; fraction, Y = TI, X = the column. In: 8-bit A =
;;; the first row, B = 0.
drawTexR:     tay                           ; Y = the first row
              lda     abs:TEXLO,y           ; the block of the first row
              sta     dp:.tiny RL_TENT
              lda     abs:TEXHI,y
              sta     dp:.tiny (RL_TENT+1)
              lda     long:(RECBASE+R_END),x ; the block after the last row
              cmp     dp:.tiny RL_CV0P      ; (past the first covered row: the
              bcs     cutTex                ;   cut)
              tay                           ; (B = 0)
texEndY:      lda     abs:TEXLO,y
              sta     dp:.tiny RL_XO
              lda     abs:TEXHI,y
              sta     dp:.tiny (RL_XO+1)
              lda     long:(RECBASE+R_SRC),x ; the texels
              sta     dp:.tiny DC_SRC
              lda     long:(RECBASE+R_SRC+1),x
              sta     dp:.tiny (DC_SRC+1)
              lda     long:(RECBASE+R_SRC+2),x
              sta     dp:.tiny (DC_SRC+2)
              lda     long:(RECBASE+R_CMP),x ; the colormaps of the even and odd
              sta     dp:.tiny (DC_CMA+1)   ;   rows
              clc
              adc     #CMAP_B
              sta     dp:.tiny (DC_CMB+1)
              lda     long:(RECBASE+R_SF),x ; original and paired steps,
              sta     dp:.tiny DC_SF        ; shared by the K_TEXC chain
              asl     a
              sta     dp:.tiny (DC_SF+1)
              lda     long:(RECBASE+R_SI),x
              sta     dp:.tiny DC_SI
              adc     #0                    ; carry from 2 * SF
              and     #0x7f
              sta     dp:.tiny (DC_SI+1)
              txa                           ; the next record, in the same page
              adc     #TEX_SIZE             ;   (carry clear: SI + carry < 256)
              sta     dp:.tiny RL_P
texTail:      brl     pairPrepare
pairReady:    tay                           ; (TF:TI; 8 bits at the blocks)
              lda     #0x6c                 ; JMP through the row exit word
              sta     [.tiny RL_XO]
              ldx     dp:.tiny RL_C         ; X = the column
              sep     #0x10
              clc                           ; the blocks keep carry clear
              .byte   0x6c                  ; JMP (RL_TENT): no return address
              .word   .word0 RL_TENT
texContinue:  rep     #0x10
              lda     #0xeb
pairRestore:  sta     [.tiny RL_XO]
              ldx     dp:.tiny RL_P         ; X = the next record
done:         cpx     dp:.tiny RL_E
              bne     rec
              lda     dp:.tiny RL_CV0P      ; the covering record: no cut from
              inc     a                     ;   it on
              bne     cvEnd
              lda     dp:.tiny RL_I         ; the next column
              inc     a
              sta     dp:.tiny RL_I
              cmp     #CONST_VIEWWIDTH
              bcs     1$
              brl     col
1$:           lda     #XP_FIRST             ; no extra page used
              sta     long:XPNEXT
              pla
              jsl     long:IIGS_SetShadow
              plb
              rep     #0x20
              brl     pairEnd
              .space  2
pairEndDone:  plp
              rts

;;; cvEnd: done is at the covering record: all rows from it on.
cvEnd:        lda     #255
              sta     dp:.tiny RL_CV0P
              lda     dp:.tiny RL_CE
              sta     dp:.tiny RL_E
              lda     dp:.tiny (RL_CE+1)
              sta     dp:.tiny (RL_E+1)
              brl     rec

;;; drawTexC: a K_TEXC record (lists.inc): drawTex with the step, the
;;; colormaps and the texel bank that the record before it left in the
;;; direct page; its own rows, position and the low word of its texels.
;;; In: X = the record, 8-bit A = K_TEXC, B = the first row.
drawTexC:     lda     #0                    ; Y = the first row (B = 0)
              xba
              tay
              lda     abs:TEXLO,y           ; the block of the first row
              sta     dp:.tiny RL_TENT
              lda     abs:TEXHI,y
              sta     dp:.tiny (RL_TENT+1)
              lda     long:(RECBASE+R_END),x ; the block after the last row
              cmp     dp:.tiny RL_CV0P      ; (past the first covered row: the
              bcc     texEndYC              ;   cut, cutTexC)
              brl     cutTexC
texEndYC:     tay                           ; (B = 0)
              lda     abs:TEXLO,y
              sta     dp:.tiny RL_XO
              lda     abs:TEXHI,y
              sta     dp:.tiny (RL_XO+1)
              lda     long:(RECBASE+R_TCSRC),x ; the texels (the bank as before)
              sta     dp:.tiny DC_SRC
              lda     long:(RECBASE+R_TCSRC+1),x
              sta     dp:.tiny (DC_SRC+1)
              txa                           ; the next record, in the same page
              clc
              adc     #TEXC_SIZE
              sta     dp:.tiny RL_P
              brl     texTail

;;; The other kinds: 8-bit A = the kind, B = the first row (notTex8).
notTex:       cmp     #K_FILL
              beq     drawFill
              cmp     #K_TEXC
              beq     drawTexC
              cmp     #K_NEXT
              beq     3$
              rep     #0x20                 ; the others: Y = the record
              and     ##0x00ff
              txy
              tax
              sep     #0x20
              jmp     (.kbank kinds,x)
3$:           lda     long:(RECBASE+R_PAGE),x ; the list goes on at the start
              sta     dp:.tiny (RL_P+1)     ;   of the next page (a record is
              xba                           ;   there: not the end, but it can be
              lda     #0                    ;   the covering record; TAX copies
              tax                           ;   B too)
              brl     done

kinds:        .word   0, 0, 0, 0, .word0 kFuzz, .word0 kOvl

kFuzz:        jmp     long:drawFuzz
kOvl:         jmp     long:drawOvl

;;; cutFill: a K_FILL record before the covering record, past the first
;;; covered row c0 (A = its row after the last e): as cutTex (fillStart for
;;; the rows c1 .. e - 1).
cutFill:      xba                           ; B = e
              lda     long:(RECBASE+R_ROW),x ; A = a
              cmp     dp:.tiny RL_CV1       ; a >= c1: all rows
              bcs     fillAll
              cmp     dp:.tiny RL_CV0
              xba                           ; A = e, B = a
              bcc     5$
              cmp     dp:.tiny RL_CV1       ; a >= c0, e <= c1: no rows
              beq     skipFill
              bcc     skipFill
              brl     fillStart
5$:           cmp     dp:.tiny RL_CV1       ; a < c0, e > c1: all rows
              beq     6$
              bcs     fillEnd
6$:           lda     dp:.tiny RL_CV0       ; a < c0, e <= c1: the rows a ..
              bra     fillEnd               ;   c0 - 1
fillAll:      xba
              bra     fillEnd
skipFill:     txa                           ; the next record, in the same
              clc                           ;   page (as skipTex)
              adc     #FILL_SIZE
              xba
              lda     dp:.tiny (RL_P+1)
              xba
              tax
              brl     done

;;; drawFill: rows R_ROW .. R_END - 1 with flatBlocks of tools/gendraw.py:
;;; B = the byte of the first row, A = the byte of the next one, X = the
;;; column; the block after the last row is patched to RTS and back (its
;;; first byte is XBA). Y keeps that block. Each byte of the record is read
;;; once, R_END twice on the cut. In: B = the first row (notTex8). Both
;;; blocks in one 16-bit stretch: one REP/SEP pair (each costs a slow cycle).
drawFill:     lda     long:(RECBASE+R_END),x ; the row after the last
              cmp     dp:.tiny RL_CV0P      ; (past the first covered row: the
              bcs     fillCut               ;   cut)
              rep     #0x20                 ; C = the first row << 8 | the row
              tay                           ;   after the last
              xba                           ; entry = flatBlocks + 4 * the row
              and     ##0x00ff
              asl     a
              asl     a
              adc     ##.word0 flatBlocks   ; (carry clear: bcs, the shifts)
              sta     dp:.tiny RL_FENT
              tya
fillEndW:     and     ##0x00ff              ; Y = the block after the last row
              asl     a
              asl     a
              adc     ##.word0 flatBlocks
              tay
              sep     #0x20
              txa                           ; the next record, in the same page
              adc     #FILL_SIZE            ;   (carry clear)
              sta     dp:.tiny RL_P
              lda     #0x60                 ; RTS there
              sta     [.tiny RL_FX],y
              lda     long:(RECBASE+R_B1),x ; B = the byte of the first row, A =
              xba                           ;   the byte of the second
              lda     long:(RECBASE+R_B2),x
              ldx     dp:.tiny RL_C
              jsr     .kbank rlFillJump
              lda     #0xeb                 ; XBA again
              sta     [.tiny RL_FX],y
              ldx     dp:.tiny RL_P         ; X = the next record
              brl     done
fillCut:      xba                           ; the cut: the entry first (A = the
              rep     #0x20                 ;   first row), then cutFill with
              and     ##0x00ff              ;   A = the row after the last
              asl     a
              asl     a
              adc     ##.word0 flatBlocks
              sta     dp:.tiny RL_FENT
              sep     #0x20
              lda     long:(RECBASE+R_END),x
              brl     cutFill
fillEnd:      rep     #0x20                 ; (cutFill: A = the row after the last)
              bra     fillEndW

;;; (147 free bytes: the low detail's drawTexLR and its jump were here, 12
;;; went to COLPAGE of col2, 2 came from drawTexR's patch site; the replay
;;; code after them keeps its cache slots.)
;;; A mobj with no function is not a thinker. Spawn asks addIfFunc instead
;;; of P_AddThinker; remove asks linkRemove so the delayed free still runs.
;;; 39 bytes, then 105 of the gap, so rlFillJump stays put.
              .extern P_AddThinker, P_RemoveThing
              .public addIfFunc, linkRemove
addIfFunc:    rep     #0x30
              ldy     ##OFS_TH_FUNCTION
              lda     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              beq     noFn
              jsl     long:P_AddThinker
noFn:         rtl
linkRemove:   rep     #0x30
              ldy     ##OFS_TH_FUNCTION
              lda     [.tiny _Dp],y
              iny
              iny
              ora     [.tiny _Dp],y
              bne     onList
              jsl     long:P_AddThinker
onList:       jmp     long:P_RemoveThing
              .space  105
rlFillJump:   .byte   0x6c                  ; jmp (RL_FENT)
              .word   .word0 RL_FENT

              .section detailimg, text     ; (cold, bank 5 with the replay:
                                            ;   its BRL targets)
;;; skipLoad: skipTex before a K_TEXC (X): the step, the colormaps and the
;;; texel bank of the skipped K_TEX (X - TEX_SIZE) into the direct page, as
;;; texEndY sets them. 8-bit A.
skipLoad:     rep     #0x20
              txa
              sec
              sbc     ##TEX_SIZE
              tax
              sep     #0x20
              lda     long:(RECBASE+R_SRC+2),x ; the texel bank
              sta     dp:.tiny (DC_SRC+2)
              lda     long:(RECBASE+R_CMP),x ; the colormaps of the even and odd
              sta     dp:.tiny (DC_CMA+1)   ;   rows
              clc
              adc     #CMAP_B
              sta     dp:.tiny (DC_CMB+1)
              lda     long:(RECBASE+R_SF),x ; original and paired steps,
              sta     dp:.tiny DC_SF        ; shared by the K_TEXC chain
              asl     a
              sta     dp:.tiny (DC_SF+1)
              lda     long:(RECBASE+R_SI),x
              sta     dp:.tiny DC_SI
              adc     #0                    ; carry from 2 * SF
              and     #0x7f
              sta     dp:.tiny (DC_SI+1)
              rep     #0x20                 ; X = the K_TEXC again
              txa
              clc
              adc     ##TEX_SIZE
              tax
              sep     #0x20
              brl     done

;;; cutTexC: cutTex for a K_TEXC record (A = its row after the last e, Y =
;;; its first row a, B = 0), with its own size and the step of the direct
;;; page (texStartC).
cutTexC:      xba                           ; B = e
              tya                           ; A = a
              cmp     dp:.tiny RL_CV1       ; a >= c1: all rows
              bcs     4$
              cmp     dp:.tiny RL_CV0
              xba                           ; A = e, B = a
              bcc     5$
              cmp     dp:.tiny RL_CV1       ; a >= c0, e <= c1: no rows
              beq     3$
              bcc     3$
              bra     texStartC
5$:           cmp     dp:.tiny RL_CV1       ; a < c0, e > c1: all rows
              beq     6$
              bcs     7$
6$:           lda     dp:.tiny RL_CV0       ; a < c0, e <= c1: the rows a ..
7$:           rep     #0x20                 ;   c0 - 1
              and     ##0x00ff              ; Y = the row after the last
              tay
              sep     #0x20
              tya
              brl     texEndYC
4$:           xba
              bra     7$
3$:           rep     #0x20                 ; no rows: the next record (the
              txa                           ;   step and the rest stay for a
              clc                           ;   K_TEXC after it)
              adc     ##TEXC_SIZE
              tax
              sep     #0x20
              brl     done

;;; texStartC: texStart for a K_TEXC record (A = e, B = a): the step is
;;; that of the direct page (DC_SF, DC_SI).
texStartC:    xba                           ; c1 - a
              eor     #0xff
              sec
              adc     dp:.tiny RL_CV1
              sta     dp:.tiny RL_K
              stz     dp:.tiny (RL_K+1)
              lda     dp:.tiny DC_SF        ; SF | SI << 8
              sta     dp:.tiny RL_ST
              lda     dp:.tiny DC_SI
              sta     dp:.tiny (RL_ST+1)
              rep     #0x20
              lda     long:(RECBASE+R_TF),x ; TF | TI << 8
1$:           lsr     dp:.tiny RL_K         ; + (c1 - a) * the step
              bcc     2$
              clc
              adc     dp:.tiny RL_ST
2$:           asl     dp:.tiny RL_ST
              ldy     dp:.tiny RL_K
              bne     1$
              and     ##0x7fff
              sta     long:(RECBASE+R_TF),x ; (texTail reads it from there)
              lda     dp:.tiny RL_CV1       ; the block of row c1
              and     ##0x00ff
              tay
              sep     #0x20
              lda     abs:TEXLO,y
              sta     dp:.tiny RL_TENT
              lda     abs:TEXHI,y
              sta     dp:.tiny (RL_TENT+1)
              lda     long:(RECBASE+R_END),x
              brl     texEndYC

;;; Odd rows are exact. Even rows round the carry to its nearer value.
;;; The K_TEX decode (or skipLoad) prepared SF+1/SI+1 once for the chain.
;;; K_TEXC and the cut paths keep all four step bytes, so only the initial
;;; position is adjusted here. SF/SI remain the original per-row step.
              .space  4                    ; skipLoad grew nine, this lost 13;
                                            ; the following code stays put
pairPrepare:  lda     dp:.tiny RL_TENT      ; +1 prefix: even entries are odd
              lsr     a
              bcs     pairEven
              lda     long:(RECBASE+R_TF),x ; odd start: undo one frac step
              sec
              sbc     dp:.tiny DC_SF
              xba
              lda     long:(RECBASE+R_TI),x
              sbc     #0
              bit     dp:.tiny DC_SF
              bpl     pairNoRound
              inc     a
pairNoRound:  and     #0x7f
              clc
              brl     pairReady
pairEven:     clc
              lda     long:(RECBASE+R_TF),x
              xba
              lda     long:(RECBASE+R_TI),x
              brl     pairReady
pairContinueShort:
              rep     #0x10
              lda     #0x98
              brl     pairRestore
              .space  118 - (. - pairPrepare) ; R_FillStamps keeps its address

              .section hotlist, text
;;; texStart: cutTex for the rows c1 .. e - 1 (A = e, B = a): the position
;;; in the record steps c1 - a rows, the first block is that of row c1.
texStart:     xba                           ; c1 - a
              eor     #0xff
              sec
              adc     dp:.tiny RL_CV1
              rep     #0x20
              and     ##0x00ff
              sta     dp:.tiny RL_K
              lda     long:(RECBASE+R_SF),x ; SF | SI << 8
              sta     dp:.tiny RL_ST
              lda     long:(RECBASE+R_TF),x ; TF | TI << 8
1$:           lsr     dp:.tiny RL_K         ; + (c1 - a) * the step
              bcc     2$
              clc
              adc     dp:.tiny RL_ST
2$:           asl     dp:.tiny RL_ST
              ldy     dp:.tiny RL_K
              bne     1$
              and     ##0x7fff
              sta     long:(RECBASE+R_TF),x ; (drawTexR reads it from there)
              lda     dp:.tiny RL_CV1       ; the block of row c1
              and     ##0x00ff
              tay
              sep     #0x20
              lda     abs:TEXLO,y
              sta     dp:.tiny RL_TENT
              lda     abs:TEXHI,y
              sta     dp:.tiny (RL_TENT+1)
              lda     long:(RECBASE+R_END),x
              brl     texAllE

;;; fillStart: cutFill for the rows c1 .. e - 1 (A = e, B = a): the first
;;; block is that of row c1; the bytes swap when c1 - a is odd.
fillStart:    xba
              eor     dp:.tiny RL_CV1
              lsr     a
              bcc     1$
              lda     long:(RECBASE+R_B1),x
              sta     dp:.tiny RL_T
              lda     long:(RECBASE+R_B2),x
              sta     long:(RECBASE+R_B1),x
              lda     dp:.tiny RL_T
              sta     long:(RECBASE+R_B2),x
1$:           lda     dp:.tiny RL_CV1
              rep     #0x20
              and     ##0x00ff
              asl     a
              asl     a
              adc     ##.word0 flatBlocks
              sep     #0x20
              sta     dp:.tiny RL_FENT
              xba
              sta     dp:.tiny (RL_FENT+1)
              lda     long:(RECBASE+R_END),x
              brl     fillEnd


;;; ---------------------------------------------------------------------------
;;; The half view (viewwin.inc): VW_HALF = 1 in this frame. halfAll draws
;;; the even columns c of the lists at screen byte 40 + c / 2, and of each
;;; record its even rows r at screen row 42 + r / 2, so the even rows and
;;; columns of the whole view fill the window of 80 x 84 bytes (bytes 40 to
;;; 119, rows 42 to 125) at half scale. The cuts of the covered ranges
;;; (lists.inc) work in full rows first. A texture record with the rows a
;;; .. b - 1 gets the half rows k0 = ceil(a / 2) .. ceil(b / 2) - 1 with
;;; twice the step, from the position one half row before the first: pos(a
;;; - 1) - step for an even a, pos(a - 1) for an odd a. A fill gives each
;;; window row the byte of its own parity (the dither of the full view). The
;;; high detail blocks draw it (drawSel), as their rows take the colormap of
;;; their own parity. The odd columns and the other lists only become empty
;;; for the next frame. In its own cache slots (section halflist,
;;; src/iigs/iigs.scm), which the replay of the half view does not use
;;; otherwise.
;;; ---------------------------------------------------------------------------
              .section halflist, text
HV_ROW0       .equ    42              ; the window: its first row and byte
HV_COL0       .equ    40

;;; drawSel: drawAll, or halfAll in the half view, with the blocks of the
;;; right detail in texBlocks (the half view: high detail). 16-bit A, X, Y.
drawSel:      lda     long:VW_HALF          ; the half view: halfAll
              bne     1$
              lda     long:RL_DETI          ; the blocks of the detail of the
              cmp     long:RL_DETW          ;   player (after the half view)
              beq     2$
              lda     long:RL_DETW
              jsl     long:R_SetDetailI
2$:           jmp     .kbank drawAll
1$:           lda     long:RL_DETI          ; the half view: the blocks of high
              beq     halfAll               ;   detail
              lda     ##0
              jsl     long:R_SetDetailI

;;; halfAll: as drawAll, for the half view.
halfAll:      php
              rep     #0x20
              brl     spBeginH
              .space  9
spBeginDoneH:
              phb
              rep     #0x10
              sep     #0x20
              lda     #BUF_BANK             ; the data bank of the drawers
              pha
              plb
              lda     long:SHADOW
              pha
              and     #0xf7                 ; SHR shadowing on
              jsl     long:IIGS_SetShadow
              lda     #.byte2 iigs_shrcmapA ; the bank of the colormaps
              sta     dp:.tiny (DC_CMA+2)
              sta     dp:.tiny (DC_CMB+2)
              lda     #255                  ; no cut
              sta     dp:.tiny RL_CV0P
              lda     #0
hcol:         sta     dp:.tiny RL_HC        ; c = the next column, left to right
              asl     a                     ; X = 2c (TAX copies B: no REP/SEP
              xba                           ;   a column)
              lda     #0
              rol     a
              xba
              tax
              lda     dp:.tiny RL_HC        ; an odd column: no drawing
              lsr     a
              bcs     hodd
              adc     #HV_COL0              ; the screen byte 40 + c / 2
              sta     dp:.tiny RL_C
              lda     long:(CV_ROW+1),x     ; a covered range (lists.inc)?
              bne     hcv
              lda     long:COLW,x           ; the end of the list
              sta     dp:.tiny RL_E
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_E+1)
hcol2:        lda     #0                    ; no records for the next frame:
              sta     long:COLW,x           ;   COLPAGE(c), offset 0 (H_PAGE2:
              lda     long:H_PAGE2,x        ;   cheaper than the macro)
              sta     long:(COLW+1),x
              sta     dp:.tiny (RL_P+1)     ; (the page of the records)
              xba                           ; X = that page, offset 0: the first
              lda     #0                    ;   record
              tax
              brl     hdone
hodd:         lda     #0                    ; an odd column: its list and its
              sta     long:COLW,x           ;   covered range empty for the next
              sta     long:CV_ROW,x         ;   frame
              sta     long:(CV_ROW+1),x
              lda     long:H_PAGE2,x
              sta     long:(COLW+1),x
              brl     hnext

;;; hcv: as cvCol.
hcv:          sta     dp:.tiny RL_CV1
              lda     long:CV_ROW,x         ; the first row (255: a shadow, no
              cmp     dp:.tiny RL_CV1       ;   range)
              bcs     1$
              sta     dp:.tiny RL_CV0
              inc     a
              sta     dp:.tiny RL_CV0P
              lda     long:COLW,x           ; the end of the list after the cut
              sta     dp:.tiny RL_CE
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_CE+1)
              lda     long:CV_REC,x         ; the cut ends at the covering record
              sta     dp:.tiny RL_E
              lda     long:(CV_REC+1),x
              sta     dp:.tiny (RL_E+1)
              bra     2$
1$:           lda     long:COLW,x           ; the end of the list
              sta     dp:.tiny RL_E
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_E+1)
2$:           lda     #0
              sta     long:CV_ROW,x
              sta     long:(CV_ROW+1),x
              brl     hcol2

;;; hrec: the record at X (as rec): B = its first row, A = its kind (8-bit
;;; reads: no REP/SEP a record).
hrec:         lda     long:(RECBASE+R_ROW),x
              xba
              lda     long:(RECBASE+R_KIND),x
              beq     htex
              cmp     #K_FILL
              bne     1$
              brl     hfill
1$:           cmp     #K_TEXC
              bne     2$
              brl     htexc
2$:           cmp     #K_NEXT
              bne     3$
              lda     long:(RECBASE+R_PAGE),x ; the list goes on at the start
              sta     dp:.tiny (RL_P+1)     ;   of the next page
              xba
              lda     #0
              tax
              brl     hdone
3$:           cmp     #K_FUZZ
              bne     4$
              brl     hfuzz
4$:           txy                           ; K_OVL: the pixels of the automap
              brl     hOvl                  ;   overlay in this screen byte

;;; hOvl: drawOvl for halfAll; the rows are screen rows (am_map65 halfOvl).
hOvl:         tyx                           ; (8-bit A: the indexes by TAX
1$:           lda     long:(RECBASE+R_KEEP),x ;   with B, no REP/SEP a pixel)
              sta     dp:.tiny DC_FLATW
              lda     long:(RECBASE+R_COLOR),x
              sta     dp:.tiny (DC_FLATW+1)
              lda     long:(RECBASE+R_ROW),x
              asl     a                     ; X = 2 * the row
              xba
              lda     #0
              rol     a
              xba
              tax
              lda     long:scRowTab,x       ; X = its byte of the window
              clc
              adc     dp:.tiny RL_C
              xba
              lda     long:(scRowTab+1),x
              adc     #0
              xba
              tax
              lda     abs:0,x
              and     dp:.tiny DC_FLATW
              ora     dp:.tiny (DC_FLATW+1)
              sta     abs:0,x
              lda     dp:.tiny (RL_P+1)     ; the next record, in the same page
              xba
              tya
              clc
              adc     #OVL_SIZE
              tax
              tay
              cpx     dp:.tiny RL_E
              beq     2$
              lda     long:(RECBASE+R_KIND),x
              cmp     #K_OVL
              beq     1$
2$:           brl     hdone

;;; htex: a K_TEX record: the step S (RL_HS) and 2S (DC_SF, DC_SI), the
;;; texels, the colormaps into the direct page (a K_TEXC after it takes
;;; them), its rows (hTexRows).
htex:         lda     long:(RECBASE+R_SF),x ; the step and twice the step (its
              sta     dp:.tiny RL_HS        ;   whole part mod 128: the blocks
              asl     a                     ;   need TI + SI + 1 < 256, and TI
              sta     dp:.tiny DC_SF        ;   is mod 128)
              lda     long:(RECBASE+R_SI),x
              sta     dp:.tiny (RL_HS+1)
              rol     a
              and     #0x7f
              sta     dp:.tiny DC_SI
              lda     long:(RECBASE+R_SRC),x ; the texels
              sta     dp:.tiny DC_SRC
              lda     long:(RECBASE+R_SRC+1),x
              sta     dp:.tiny (DC_SRC+1)
              lda     long:(RECBASE+R_SRC+2),x
              sta     dp:.tiny (DC_SRC+2)
              lda     long:(RECBASE+R_CMP),x ; the colormaps of the even and odd
              sta     dp:.tiny (DC_CMA+1)   ;   rows
              clc
              adc     #CMAP_B
              sta     dp:.tiny (DC_CMB+1)
              lda     long:(RECBASE+R_TF),x ; the position before the first row
              sta     dp:.tiny RL_HP
              lda     long:(RECBASE+R_TI),x
              sta     dp:.tiny (RL_HP+1)
              txa                           ; the next record, in the same page
              adc     #TEX_SIZE             ;   (carry clear: SI + carry < 256)
              sta     dp:.tiny RL_P
              xba                           ; the rows a .. b - 1 (B: a, hrec)
              sta     dp:.tiny RL_HA
              lda     long:(RECBASE+R_END),x
              bra     hTexRows

;;; htexc: a K_TEXC record: the step, colormaps and texel bank of the K_TEX
;;; before it (the direct page), its rows and position, the low word of its
;;; texels.
htexc:        lda     long:(RECBASE+R_TCSRC),x
              sta     dp:.tiny DC_SRC
              lda     long:(RECBASE+R_TCSRC+1),x
              sta     dp:.tiny (DC_SRC+1)
              lda     long:(RECBASE+R_TF),x
              sta     dp:.tiny RL_HP
              lda     long:(RECBASE+R_TI),x
              sta     dp:.tiny (RL_HP+1)
              txa
              clc
              adc     #TEXC_SIZE
              sta     dp:.tiny RL_P
              xba                           ; (B: the first row, hrec)
              sta     dp:.tiny RL_HA
              lda     long:(RECBASE+R_END),x

;;; hTexRows: the texture rows RL_HA .. A - 1 (8-bit A), the position RL_HP
;;; one row before the first, the step RL_HS; the cut in full rows, then the
;;; half rows with texBlocks.
;;; Entry low bytes are unique in this window: equal means no rows.
hTexRows:     cmp     dp:.tiny RL_CV0P      ; (past the first covered row: the
              bcc     1$                    ;   cut)
              jsr     .kbank hCut
              bcs     hNoRows               ; (no rows)
1$:           xba
              lda     #0
              xba
              tax
              lda     long:(texBlocks+0x100),x
              sta     dp:.tiny RL_XO
              lda     long:(texBlocks+0x200),x
              sta     dp:.tiny (RL_XO+1)
              lda     dp:.tiny RL_HA
              tax
              lda     long:(texBlocks+0x100),x
              cmp     dp:.tiny RL_XO
              beq     hNoRows
              sta     dp:.tiny RL_TENT
              lda     long:(texBlocks+0x200),x
              sta     dp:.tiny (RL_TENT+1)
              jmp     abs:.word0 (texBlocks+0x1)
              .space  96 - (. - hTexRows)
halfCont:     rep     #0x10
              lda     #0xeb                 ; XBA again
              sta     [.tiny RL_XO]
hNoRows:      ldx     dp:.tiny RL_P         ; X = the next record
              brl     hdone

;;; hCut: the rows of a record RL_HA .. A - 1 (8-bit A) before the covering
;;; record, past its first row c0: as cutTex, the rows RL_HA .. c0 - 1 when
;;; it ends in the range, c1 .. when it starts in the range (the position
;;; RL_HP steps c1 - a rows of RL_HS), all rows when it starts after the
;;; range or covers all of it, none when it lies in it. Out: A = the row
;;; after the last, RL_HA the first, carry set: no rows.
hCut:         sta     dp:.tiny RL_HB        ; b
              lda     dp:.tiny RL_HA
              cmp     dp:.tiny RL_CV1       ; a >= c1: all rows
              bcs     8$
              cmp     dp:.tiny RL_CV0
              bcc     5$
              lda     dp:.tiny RL_HB        ; a >= c0, b <= c1: no rows
              cmp     dp:.tiny RL_CV1
              beq     9$
              bcc     9$
              lda     dp:.tiny RL_CV1       ; a >= c0, b > c1: the rows c1 ..
              sec                           ;   b - 1, the position + (c1 - a)
              sbc     dp:.tiny RL_HA        ;   * S
              rep     #0x20
              and     ##0x00ff
              sta     dp:.tiny RL_K
              lda     dp:.tiny RL_HS
              sta     dp:.tiny RL_ST
              lda     dp:.tiny RL_HP
1$:           lsr     dp:.tiny RL_K
              bcc     2$
              clc
              adc     dp:.tiny RL_ST
2$:           asl     dp:.tiny RL_ST
              ldy     dp:.tiny RL_K
              bne     1$
              sta     dp:.tiny RL_HP
              sep     #0x20
              lda     dp:.tiny RL_CV1
              sta     dp:.tiny RL_HA
8$:           lda     dp:.tiny RL_HB
              clc
              rts
5$:           lda     dp:.tiny RL_HB        ; a < c0: b > c1: all rows; b <= c1:
              cmp     dp:.tiny RL_CV1       ;   the rows a .. c0 - 1
              beq     6$
              bcs     8$
6$:           lda     dp:.tiny RL_CV0
              clc
              rts
9$:           sec
              rts

;;; hfill: a K_FILL record (B = its first row a): each window row gets the
;;; byte of its own parity, RL_FE for the even rows, RL_FO for the odd ones
;;; (B1 is the byte of row a).
hfill:        xba
              sta     dp:.tiny RL_HA
              lsr     a
              lda     long:(RECBASE+R_B1),x
              bcs     1$
              sta     dp:.tiny RL_FE        ; an even a: B1 even, B2 odd
              lda     long:(RECBASE+R_B2),x
              sta     dp:.tiny RL_FO
              bra     2$
1$:           sta     dp:.tiny RL_FO        ; an odd a: B1 odd, B2 even
              lda     long:(RECBASE+R_B2),x
              sta     dp:.tiny RL_FE
2$:           txa                           ; the next record, in the same page
              clc
              adc     #FILL_SIZE
              sta     dp:.tiny RL_P
              lda     long:(RECBASE+R_END),x ; b; the cut in full rows
              cmp     dp:.tiny RL_CV0P
              bcc     3$
              jsr     .kbank hCutF
              bcs     9$
3$:           inc     a                     ; k1 = ceil(b / 2)
              lsr     a
              sta     dp:.tiny RL_HK1
              lda     dp:.tiny RL_HA        ; k0 = ceil(a / 2)
              lsr     a
              adc     #0
              cmp     dp:.tiny RL_HK1
              bcs     9$
              clc                           ; the first window row
              adc     #HV_ROW0
              sta     dp:.tiny RL_HK0
              rep     #0x20                 ; entry = flatBlocks + 4 * that row
              and     ##0x00ff
              asl     a
              asl     a
              adc     ##.word0 flatBlocks
              sta     dp:.tiny RL_FENT
              lda     dp:.tiny RL_HK1       ; RTS at the block of row 42 + k1
              and     ##0x00ff
              clc
              adc     ##HV_ROW0
              asl     a
              asl     a
              adc     ##.word0 flatBlocks
              tay
              sep     #0x20
              lda     #0x60
              sta     [.tiny RL_FX],y
              lda     dp:.tiny RL_HK0       ; B = the byte of the first window
              lsr     a                     ;   row (its parity), A = the other
              bcs     4$
              lda     dp:.tiny RL_FE
              xba
              lda     dp:.tiny RL_FO
              bra     5$
4$:           lda     dp:.tiny RL_FO
              xba
              lda     dp:.tiny RL_FE
5$:           ldx     dp:.tiny RL_C
              jsr     .kbank rlFillJump
              lda     #0xeb                 ; XBA again
              sta     [.tiny RL_FX],y
9$:           ldx     dp:.tiny RL_P
              brl     hdone

;;; hCutF: hCut for a fill (no position).
hCutF:        sta     dp:.tiny RL_HB
              lda     dp:.tiny RL_HA
              cmp     dp:.tiny RL_CV1       ; a >= c1: all rows
              bcs     8$
              cmp     dp:.tiny RL_CV0
              bcc     5$
              lda     dp:.tiny RL_HB        ; a >= c0, b <= c1: no rows
              cmp     dp:.tiny RL_CV1
              beq     9$
              bcc     9$
              lda     dp:.tiny RL_CV1       ; a >= c0, b > c1: c1 .. b - 1
              sta     dp:.tiny RL_HA
8$:           lda     dp:.tiny RL_HB
              clc
              rts
5$:           lda     dp:.tiny RL_HB        ; a < c0: b > c1: all rows; b <= c1:
              cmp     dp:.tiny RL_CV1       ;   the rows a .. c0 - 1
              beq     6$
              bcs     8$
6$:           lda     dp:.tiny RL_CV0
              clc
              rts
9$:           sec
              rts

;;; hfuzz: a K_FUZZ record (drawFuzz) on its half rows.
hfuzz:        lda     long:(RECBASE+R_ROW),x ; a, b = a + the count
              sta     dp:.tiny RL_HA
              clc
              adc     long:(RECBASE+R_COUNT),x
              inc     a                     ; k1 = ceil(b / 2)
              lsr     a
              sta     dp:.tiny RL_HK1
              rep     #0x20                 ; the next record
              txa
              clc
              adc     ##FUZZ_SIZE
              sta     dp:.tiny RL_P
              sep     #0x20
              lda     dp:.tiny RL_HA        ; k0 = ceil(a / 2)
              lsr     a
              adc     #0
              cmp     dp:.tiny RL_HK1
              bcs     9$
              sta     dp:.tiny RL_HK0
              rep     #0x20
              and     ##0x00ff
              clc
              adc     ##HV_ROW0
              sta     dp:.tiny DC_ROW
              lda     dp:.tiny RL_HK1
              sec
              sbc     dp:.tiny RL_HK0
              and     ##0x00ff
              sta     dp:.tiny DC_COUNT
              lda     dp:.tiny RL_C
              and     ##0x00ff
              sta     dp:.tiny DC_COLX
              lda     long:(RECBASE+R_POS),x
              and     ##0x00ff
              jsl     long:fuzzColumn
              sep     #0x20
9$:           ldx     dp:.tiny RL_P
              brl     hdone

;;; hdone: the next record, or the end of the list.
hdone:        cpx     dp:.tiny RL_E
              beq     1$
              brl     hrec
1$:           lda     dp:.tiny RL_CV0P      ; the covering record: no cut from
              inc     a                     ;   it on
              bne     hcvEnd
hnext:        lda     dp:.tiny RL_HC        ; the next column
              inc     a
              cmp     #CONST_VIEWWIDTH
              bcs     1$
              brl     hcol
1$:           lda     #XP_FIRST             ; no extra page used
              sta     long:XPNEXT
              pla
              jsl     long:IIGS_SetShadow
              plb
              rep     #0x20
              brl     spEndH
              .space  2
spEndDoneH:
              plp
              rts
hcvEnd:       lda     #255
              sta     dp:.tiny RL_CV0P
              lda     dp:.tiny RL_CE
              sta     dp:.tiny RL_E
              lda     dp:.tiny (RL_CE+1)
              sta     dp:.tiny (RL_E+1)
              brl     hrec

;;; ---------------------------------------------------------------------------
;;; segMode: the loops of src/iigs/r_seg65.s for the view of this frame
;;; (R_SegHalf) when VW_HALF changed (R_FillStamps, after vwFrame, before
;;; R_RenderPlayerView). R_SegHalf: the patches SEGPATCH of
;;; src/iigs/r_seg65.s with the bytes of the full view (C = 0) or of the half
;;; view (C = 1): the half view takes the even columns only. 16-bit A, X, Y;
;;; the direct page of the C code (its drawer inputs are free then).
;;; ---------------------------------------------------------------------------
segMode:      lda     .near AM_MODE         ; the automap overlay on the half
              cmp     ##3                   ;   view ended: its pixels go
              bne     1$                    ;   (src/iigs/am_map65.s)
              jsl     long:AM_Clean
1$:           lda     long:VW_HALF
              cmp     long:(WPAGE+W_SEGH)
              bne     R_SegHalf
              rtl
              .public R_SegHalf
R_SegHalf:    php
              rep     #0x30
              and     ##0x0001
              sta     long:(WPAGE+W_SEGH)
              beq     1$                    ; the bytes: + 3 (full) or + 6 (half)
              lda     ##3
1$:           clc
              adc     ##3
              sta     dp:.tiny DC_FRAC
              sep     #0x20
              lda     #.byte2 R_RenderSegLoop ; (the bank of the patches)
              sta     dp:.tiny (DC_ENTRY+2)
              ldx     ##0                   ; X = the entry
2$:           rep     #0x21
              lda     long:SEGPATCH,x       ; its address (0: the end)
              beq     9$
              sta     dp:.tiny DC_ENTRY
              txa
              adc     dp:.tiny DC_FRAC      ; (carry clear)
              sta     dp:.tiny DC_EXITP     ; the index of its bytes
              sep     #0x20
              lda     long:(SEGPATCH+2),x   ; its count
              sta     dp:.tiny (DC_EXITP+2)
              phx
              ldx     dp:.tiny DC_EXITP
              ldy     ##0
3$:           lda     long:SEGPATCH,x
              sta     [.tiny DC_ENTRY],y
              inx
              iny
              dec     dp:.tiny (DC_EXITP+2)
              bne     3$
              plx
              rep     #0x21                 ; the next entry, 9 bytes on
              txa
              adc     ##9
              tax
              bra     2$
9$:           plp
              rtl

;;; H_PAGE2: COLPAGE(c) at byte 2c (hcol2, hodd: X = 2c).
H_PAGE2:
              .byte   0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00, 0x05, 0x00, 0x06, 0x00, 0x07, 0x00
              .byte   0x08, 0x00, 0x20, 0x00, 0x21, 0x00, 0x22, 0x00, 0x23, 0x00, 0x24, 0x00, 0x25, 0x00, 0x26, 0x00
              .byte   0x27, 0x00, 0x28, 0x00, 0x29, 0x00, 0x2a, 0x00, 0x2b, 0x00, 0x2c, 0x00, 0x2d, 0x00, 0x2e, 0x00
              .byte   0x2f, 0x00, 0x30, 0x00, 0x31, 0x00, 0x32, 0x00, 0x33, 0x00, 0x34, 0x00, 0x35, 0x00, 0x36, 0x00
              .byte   0x37, 0x00, 0x38, 0x00, 0x39, 0x00, 0x3a, 0x00, 0x3b, 0x00, 0x3c, 0x00, 0x3d, 0x00, 0x3e, 0x00
              .byte   0x3f, 0x00, 0x40, 0x00, 0x41, 0x00, 0x42, 0x00, 0x43, 0x00, 0x44, 0x00, 0x45, 0x00, 0x46, 0x00
              .byte   0x47, 0x00, 0x48, 0x00, 0x49, 0x00, 0x4a, 0x00, 0x4b, 0x00, 0x4c, 0x00, 0x4d, 0x00, 0x4e, 0x00
              .byte   0x4f, 0x00, 0x50, 0x00, 0x51, 0x00, 0x52, 0x00, 0x53, 0x00, 0x54, 0x00, 0x55, 0x00, 0x56, 0x00
              .byte   0x57, 0x00, 0x58, 0x00, 0x59, 0x00, 0x5a, 0x00, 0x5b, 0x00, 0x5c, 0x00, 0x5d, 0x00, 0x5e, 0x00
              .byte   0x5f, 0x00, 0x60, 0x00, 0x61, 0x00, 0x62, 0x00, 0x63, 0x00, 0x64, 0x00, 0x65, 0x00, 0x66, 0x00
              .byte   0x67, 0x00, 0x68, 0x00, 0x69, 0x00, 0x6a, 0x00, 0x6b, 0x00, 0x6c, 0x00, 0x6d, 0x00, 0x6e, 0x00
              .byte   0x6f, 0x00, 0x70, 0x00, 0x71, 0x00, 0x72, 0x00, 0x73, 0x00, 0x74, 0x00, 0x75, 0x00, 0x76, 0x00
              .byte   0x77, 0x00, 0x78, 0x00, 0x79, 0x00, 0x7a, 0x00, 0x7b, 0x00, 0x7c, 0x00, 0x7d, 0x00, 0x7e, 0x00
              .byte   0x7f, 0x00, 0x80, 0x00, 0x81, 0x00, 0x82, 0x00, 0x83, 0x00, 0x84, 0x00, 0x85, 0x00, 0x86, 0x00
              .byte   0x87, 0x00, 0x88, 0x00, 0xa0, 0x00, 0xa1, 0x00, 0xa2, 0x00, 0xa3, 0x00, 0xa4, 0x00, 0xa5, 0x00
              .byte   0xa6, 0x00, 0xa7, 0x00, 0xa8, 0x00, 0xa9, 0x00, 0xaa, 0x00, 0xab, 0x00, 0xac, 0x00, 0xad, 0x00
              .byte   0xae, 0x00, 0xaf, 0x00, 0xb0, 0x00, 0xb1, 0x00, 0xb2, 0x00, 0xb3, 0x00, 0xb4, 0x00, 0xb5, 0x00
              .byte   0xb6, 0x00, 0xb7, 0x00, 0xb8, 0x00, 0xb9, 0x00, 0xba, 0x00, 0xbb, 0x00, 0xbc, 0x00, 0xbd, 0x00
              .byte   0xbe, 0x00, 0xbf, 0x00, 0xc0, 0x00, 0xc1, 0x00, 0xc2, 0x00, 0xc3, 0x00, 0xc4, 0x00, 0xc5, 0x00
              .byte   0xc6, 0x00, 0xc7, 0x00, 0xc8, 0x00, 0xc9, 0x00, 0xca, 0x00, 0xcb, 0x00, 0xcc, 0x00, 0xcd, 0x00

;;; ---------------------------------------------------------------------------
;;; The 2/3 view (VW_THIRD, viewwin.inc) skips every third column and row.
;;; thirdAll draws the columns c with c mod 3 < 2 into
;;; screen byte 26 + c - c div 3, and of each record its rows r with r mod
;;; 3 < 2 into screen row 28 + k, k = r - r div 3. The blocks are the 2/3
;;; image of tools/gendraw.py in texBlocks (R_SetThird): an odd k steps once,
;;; an even k twice. Own cache slots (thirdlist, $2000-$2FFF): the window's
;;; stores begin at slot $319A.
;;; ---------------------------------------------------------------------------
              .section thirdlist, text
T_ROW0        .equ    28
T_ROWS        .equ    112

;;; tRowK: A = T_ROWK[A] (8-bit A in and out, 16-bit X, Y; X is not kept).
tRowK:        xba
              lda     #0
              xba
              tax
              lda     long:T_ROWK,x
              rts

;;; thirdSel: drawSel in the 2/3 view (R_ViewMode patches drawSel to jump
;;; here): the 2/3 blocks in texBlocks once, then thirdAll.
thirdSel:     lda     long:RL_DETI
              cmp     ##2
              beq     thirdAll
              jsl     long:R_SetThird

;;; thirdAll: halfAll for the 2/3 view.
thirdAll:      php
              rep     #0x20
              brl     spBeginT
              .space  9
spBeginDoneT:
              phb
              rep     #0x10
              sep     #0x20
              lda     #BUF_BANK             ; the data bank of the drawers
              pha
              plb
              lda     long:SHADOW
              pha
              and     #0xf7                 ; SHR shadowing on
              jsl     long:IIGS_SetShadow
              lda     #.byte2 iigs_shrcmapA ; the bank of the colormaps
              sta     dp:.tiny (DC_CMA+2)
              sta     dp:.tiny (DC_CMB+2)
              lda     #255                  ; no cut
              sta     dp:.tiny RL_CV0P
              lda     #0
tcol:         sta     dp:.tiny RL_HC        ; c = the next column
              xba                           ; X = c (TAX copies B = 0: no
              lda     #0                    ;   REP/SEP a column)
              xba
              tax
              lda     long:T_COLB,x         ; its screen byte, 0xff: skipped
              cmp     #0xff
              beq     todd
              sta     dp:.tiny RL_C
              txa                           ; X = 2c
              asl     a
              xba
              rol     a
              xba
              tax
              lda     long:(CV_ROW+1),x     ; a covered range (lists.inc)?
              bne     tcv
              lda     long:COLW,x           ; the end of the list
              sta     dp:.tiny RL_E
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_E+1)
tcol2:        lda     #0                    ; no records for the next frame:
              sta     long:COLW,x           ;   COLPAGE(c), offset 0 (T_PAGE2:
              lda     long:T_PAGE2,x        ;   cheaper than the macro)
              sta     long:(COLW+1),x
              sta     dp:.tiny (RL_P+1)
              xba                           ; X = that page, offset 0
              lda     #0
              tax
              brl     tdone
todd:         txa                           ; a skipped column: its list and its
              asl     a                     ;   covered range empty for the next
              xba                           ;   frame (X = 2c)
              rol     a
              xba
              tax
              lda     #0
              sta     long:COLW,x
              sta     long:CV_ROW,x
              sta     long:(CV_ROW+1),x
              lda     long:T_PAGE2,x
              sta     long:(COLW+1),x
              brl     tnext

;;; tcv: hcv for the 2/3 view.
tcv:          sta     dp:.tiny RL_CV1
              lda     long:CV_ROW,x
              cmp     dp:.tiny RL_CV1
              bcs     1$
              sta     dp:.tiny RL_CV0
              inc     a
              sta     dp:.tiny RL_CV0P
              lda     long:COLW,x
              sta     dp:.tiny RL_CE
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_CE+1)
              lda     long:CV_REC,x
              sta     dp:.tiny RL_E
              lda     long:(CV_REC+1),x
              sta     dp:.tiny (RL_E+1)
              bra     2$
1$:           lda     long:COLW,x
              sta     dp:.tiny RL_E
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_E+1)
2$:           lda     #0
              sta     long:CV_ROW,x
              sta     long:(CV_ROW+1),x
              brl     tcol2

;;; trec: the record at X: B = its first row, A = its kind (8-bit reads:
;;; no REP/SEP a record). K_TEX is 0.
trec:         lda     long:(RECBASE+R_ROW),x
              xba
              lda     long:(RECBASE+R_KIND),x
              beq     ttex
              cmp     #K_FILL
              bne     2$
              brl     tfill
2$:           cmp     #K_TEXC
              bne     3$
              brl     ttexc
3$:           cmp     #K_NEXT
              bne     4$
              lda     long:(RECBASE+R_PAGE),x ; the list goes on at the start
              sta     dp:.tiny (RL_P+1)     ;   of the next page
              xba                           ; X = that page, offset 0
              lda     #0
              tax
              brl     tdone
4$:           cmp     #K_FUZZ
              bne     5$
              brl     tfuzz
5$:           txy                           ; K_OVL: the automap overlay
              brl     tOvl

;;; ttex: a K_TEX record: its step S, texels, colormaps, the position before
;;; its first row (tTexRows).
ttex:         lda     long:(RECBASE+R_SF),x ; the step (the blocks step once or
              sta     dp:.tiny DC_SF        ;   twice with it; RL_HS only for a
              lda     long:(RECBASE+R_SI),x ;   cut, tTexRows)
              sta     dp:.tiny DC_SI
              lda     long:(RECBASE+R_SRC),x ; the texels
              sta     dp:.tiny DC_SRC
              lda     long:(RECBASE+R_SRC+1),x
              sta     dp:.tiny (DC_SRC+1)
              lda     long:(RECBASE+R_SRC+2),x
              sta     dp:.tiny (DC_SRC+2)
              lda     long:(RECBASE+R_CMP),x ; the colormaps of the even and odd
              sta     dp:.tiny (DC_CMA+1)   ;   screen rows
              clc
              adc     #CMAP_B
              sta     dp:.tiny (DC_CMB+1)
              lda     long:(RECBASE+R_TF),x ; the position before the first row
              sta     dp:.tiny RL_HP
              lda     long:(RECBASE+R_TI),x
              sta     dp:.tiny (RL_HP+1)
              txa                           ; the next record, in the same page
              adc     #TEX_SIZE             ;   (carry clear: SI + carry < 256)
              sta     dp:.tiny RL_P
              xba                           ; the rows a .. b - 1
              sta     dp:.tiny RL_HA
              lda     long:(RECBASE+R_END),x
              bra     tTexRows

;;; ttexc: a K_TEXC record (htexc; B = its first row).
ttexc:        lda     long:(RECBASE+R_TCSRC),x
              sta     dp:.tiny DC_SRC
              lda     long:(RECBASE+R_TCSRC+1),x
              sta     dp:.tiny (DC_SRC+1)
              lda     long:(RECBASE+R_TF),x
              sta     dp:.tiny RL_HP
              lda     long:(RECBASE+R_TI),x
              sta     dp:.tiny (RL_HP+1)
              txa
              clc
              adc     #TEXC_SIZE
              sta     dp:.tiny RL_P
              xba
              sta     dp:.tiny RL_HA
              lda     long:(RECBASE+R_END),x

;;; tTexRows: the texture rows RL_HA .. A - 1 (8-bit A), the position RL_HP
;;; one row before the first, the step DC_SF, DC_SI; the cut in full rows
;;; (hCut), then window rows k0 .. k1 - 1. The block of k0 steps twice when
;;; k0 is even: the start is pos(a - 1) - S when a mod 3 = 0 (then k0 is
;;; even and row a its first row), else pos(a - 1) (a mod 3 = 1: k0 odd, one
;;; step to row a; a mod 3 = 2: two steps to row a + 1). The indexes: TAX,
;;; TAY with B = 0 (no REP/SEP).
;;; Entry-map bit 7 marks starts that need one source step back.
tTexRows:     cmp     dp:.tiny RL_CV0P
              bcc     1$
              pha                           ; the cut (hCut steps RL_HS)
              lda     dp:.tiny DC_SF
              sta     dp:.tiny RL_HS
              lda     dp:.tiny DC_SI
              sta     dp:.tiny (RL_HS+1)
              pla
              jsr     .kbank hCut
              bcs     tNoRows
1$:           xba
              lda     #0
              xba
              tax
              lda     long:(texBlocks+0x780),x
              sta     dp:.tiny RL_XO
              lda     long:(texBlocks+0x840),x
              and     #0x7f
              sta     dp:.tiny (RL_XO+1)
              lda     dp:.tiny RL_HA
              tax
              lda     long:(texBlocks+0x780),x
              cmp     dp:.tiny RL_XO
              beq     tNoRows
              sta     dp:.tiny RL_TENT
              lda     long:(texBlocks+0x840),x
              bpl     11$
              and     #0x7f
              sta     dp:.tiny (RL_TENT+1)
              lda     dp:.tiny RL_HP
              xba
              lda     dp:.tiny (RL_HP+1)
              xba
              sec
              sbc     dp:.tiny DC_SF
              xba
              sbc     dp:.tiny DC_SI
              bra     12$
11$:          sta     dp:.tiny (RL_TENT+1)
              lda     dp:.tiny RL_HP
              xba
              lda     dp:.tiny (RL_HP+1)
12$:          and     #0x7f
              jmp     abs:.word0 (texBlocks+0x910)
              .space  109 - (. - tTexRows)
tCont:        rep     #0x10
              lda     #0xeb                 ; XBA again
              sta     [.tiny RL_XO]
tNoRows:      ldx     dp:.tiny RL_P         ; X = the next record
              brl     tdone

;;; tfill: a K_FILL record (hfill): each window row gets the byte of its
;;; screen row's parity (the dither of the full view).
tfill:        xba
              sta     dp:.tiny RL_HA
              lsr     a
              lda     long:(RECBASE+R_B1),x
              bcs     1$
              sta     dp:.tiny RL_FE        ; an even a: B1 even, B2 odd
              lda     long:(RECBASE+R_B2),x
              sta     dp:.tiny RL_FO
              bra     2$
1$:           sta     dp:.tiny RL_FO
              lda     long:(RECBASE+R_B2),x
              sta     dp:.tiny RL_FE
2$:           txa
              clc
              adc     #FILL_SIZE
              sta     dp:.tiny RL_P
              lda     long:(RECBASE+R_END),x ; b; the cut in full rows
              cmp     dp:.tiny RL_CV0P
              bcc     3$
              jsr     .kbank hCutF
              bcs     9$
3$:           xba                           ; k1, k0 (X = b, B = 0: TAX copies
              lda     #0                    ;   it)
              xba
              tax
              lda     long:T_ROWK,x
              and     #0x7f
              sta     dp:.tiny RL_HK1
              lda     dp:.tiny RL_HA
              tax
              lda     long:T_ROWK,x
              and     #0x7f
              cmp     dp:.tiny RL_HK1
              bcs     9$
              sta     dp:.tiny RL_HK0
              rep     #0x21                 ; entry = the fill block of k0 (C =
              asl     a                     ;   k0: B = 0)
              asl     a
              adc     long:TFLAT_ADDR
              sta     dp:.tiny RL_FENT
              lda     dp:.tiny RL_HK1       ; RTS at the block of k1
              and     ##0x00ff
              asl     a
              asl     a
              adc     long:TFLAT_ADDR
              tay
              sep     #0x20
              lda     #0x60
              sta     [.tiny RL_FX],y
              lda     dp:.tiny RL_HK0       ; B = the byte of the first window
              lsr     a                     ;   row (screen row 28 + k0: the
              bcs     4$                    ;   parity of k0), A = the other
              lda     dp:.tiny RL_FE
              xba
              lda     dp:.tiny RL_FO
              bra     5$
4$:           lda     dp:.tiny RL_FO
              xba
              lda     dp:.tiny RL_FE
5$:           ldx     dp:.tiny RL_C
              jsr     .kbank rlFillJump
              lda     #0xeb                 ; XBA again
              sta     [.tiny RL_FX],y
9$:           ldx     dp:.tiny RL_P
              brl     tdone

;;; tfuzz: a K_FUZZ record (hfuzz) on its window rows.
tfuzz:        phx
              lda     long:(RECBASE+R_ROW),x ; a, b = a + the count
              sta     dp:.tiny RL_HA
              clc
              adc     long:(RECBASE+R_COUNT),x
              jsr     .kbank tRowK          ; k1
              and     #0x7f
              sta     dp:.tiny RL_HK1
              lda     dp:.tiny RL_HA
              jsr     .kbank tRowK          ; k0
              and     #0x7f
              sta     dp:.tiny RL_HK0
              plx
              rep     #0x20
              txa                           ; the next record
              clc
              adc     ##FUZZ_SIZE
              sta     dp:.tiny RL_P
              sep     #0x20
              lda     dp:.tiny RL_HK0
              cmp     dp:.tiny RL_HK1
              bcs     9$
              rep     #0x20
              and     ##0x00ff
              clc
              adc     ##T_ROW0
              sta     dp:.tiny DC_ROW
              lda     dp:.tiny RL_HK1
              sec
              sbc     dp:.tiny RL_HK0
              and     ##0x00ff
              sta     dp:.tiny DC_COUNT
              lda     dp:.tiny RL_C
              and     ##0x00ff
              sta     dp:.tiny DC_COLX
              lda     long:(RECBASE+R_POS),x
              and     ##0x00ff
              jsl     long:fuzzColumn
9$:           sep     #0x20
              ldx     dp:.tiny RL_P
              brl     tdone

;;; tOvl: drawOvl for thirdAll; the rows are screen rows (am_map65).
tOvl:         tyx                           ; (8-bit A: the indexes by TAX
1$:           lda     long:(RECBASE+R_KEEP),x ;   with B, no REP/SEP a pixel)
              sta     dp:.tiny DC_FLATW
              lda     long:(RECBASE+R_COLOR),x
              sta     dp:.tiny (DC_FLATW+1)
              lda     long:(RECBASE+R_ROW),x
              asl     a                     ; X = 2 * the row
              xba
              lda     #0
              rol     a
              xba
              tax
              lda     long:scRowTab,x       ; X = its byte of the window
              clc
              adc     dp:.tiny RL_C
              xba
              lda     long:(scRowTab+1),x
              adc     #0
              xba
              tax
              lda     abs:0,x
              and     dp:.tiny DC_FLATW
              ora     dp:.tiny (DC_FLATW+1)
              sta     abs:0,x
              lda     dp:.tiny (RL_P+1)     ; the next record, in the same page
              xba
              tya
              clc
              adc     #OVL_SIZE
              tax
              tay
              cpx     dp:.tiny RL_E
              beq     2$
              lda     long:(RECBASE+R_KIND),x
              cmp     #K_OVL
              beq     1$
2$:           brl     tdone

;;; tdone: the next record, or the end of the list.
tdone:        cpx     dp:.tiny RL_E
              beq     1$
              brl     trec
1$:           lda     dp:.tiny RL_CV0P
              inc     a
              bne     tcvEnd
tnext:        lda     dp:.tiny RL_HC        ; the next column
              inc     a
              cmp     #CONST_VIEWWIDTH
              bcs     1$
              brl     tcol
1$:           lda     #XP_FIRST             ; no extra page used
              sta     long:XPNEXT
              pla
              jsl     long:IIGS_SetShadow
              plb
              rep     #0x20
              brl     spEndT
              .space  2
spEndDoneT:
              plp
              rts
tcvEnd:       lda     #255
              sta     dp:.tiny RL_CV0P
              lda     dp:.tiny RL_CE
              sta     dp:.tiny RL_E
              lda     dp:.tiny (RL_CE+1)
              sta     dp:.tiny (RL_E+1)
              brl     trec

;;; R_SetThird: the 2/3 image into texBlocks, its entries into TEXLO and
;;; TEXHI (the full view gets its own again from drawSel: RL_DETI = 2).
              .public R_SetThird
R_SetThird:   php
              rep     #0x30
              phb
              lda     ##2
              sta     long:RL_DETI
              ldx     ##.word0 texImgT
              ldy     ##.word0 texBlocks
              lda     ##(TEXIMGT_SIZE - 1)
              .byte   0x54, .byte2 texBlocks, .byte2 texImgT ; mvn
              ldx     ##.word0 texEntryLoT
              ldy     ##TEXLO
              lda     ##T_ROWS
              .byte   0x54, BUF_BANK, .byte2 texEntryLoT ; mvn
              ldx     ##.word0 texEntryHiT
              ldy     ##TEXHI
              lda     ##T_ROWS
              .byte   0x54, BUF_BANK, .byte2 texEntryHiT ; mvn
              jmp     .kbank nrTSet

;;; R_ViewMode (hvPatch of src/iigs/r_thing65.s, at a size change): in the
;;; 2/3 view drawSel jumps to thirdSel and the seg loops take the patches
;;; SEGPATCHT, else drawSel has its own first instruction (LDA long:VW_HALF)
;;; and the seg loops the bytes of the full view (segMode puts the half
;;; view's in).
              .public R_ViewMode
R_ViewMode:   php
              rep     #0x30
              jsl     long:initColw         ; (the lists: the map of the view)
              lda     long:VW_THIRD
              beq     5$
              lda     long:(WPAGE+W_SEGH)   ; the seg loops: the half view's
              and     ##1                   ;   patches off (segMode then
              beq     1$                    ;   keeps them off), the 2/3
              lda     ##0                   ;   view's on
              jsl     long:R_SegHalf
1$:           lda     long:T_SEGT
              and     ##0x00ff
              bne     2$
              ldx     ##6
              jsr     .kbank tPatch
2$:           sep     #0x20
              lda     #1
              sta     long:T_SEGT
              lda     #0x4c                 ; JMP thirdSel
              sta     long:drawSel
              lda     #.byte0 thirdSel
              sta     long:(drawSel+1)
              lda     #.byte1 thirdSel
              sta     long:(drawSel+2)
              plp
              rtl
5$:           lda     long:T_SEGT           ; the seg loops of the full view
              and     ##0x00ff              ;   (segMode then patches the half
              beq     6$                    ;   view's in)
              ldx     ##3
              jsr     .kbank tPatch
6$:           sep     #0x20
              lda     #0
              sta     long:T_SEGT
              lda     #0xaf                 ; LDA long:VW_HALF
              sta     long:drawSel
              lda     #.byte0 VW_HALF
              sta     long:(drawSel+1)
              lda     #.byte1 VW_HALF
              sta     long:(drawSel+2)
              plp
              rtl
;;; tPatch: the patches SEGPATCHT of src/iigs/r_seg65.s with the bytes of
;;; the full view (X = 3) or of the 2/3 view (X = 6), as R_SegHalf. 16-bit
;;; A, X, Y; the direct page of the C code.
tPatch:       stx     dp:.tiny DC_FRAC
              sep     #0x20
              lda     #.byte2 R_RenderSegLoop ; (the bank of the patches)
              sta     dp:.tiny (DC_ENTRY+2)
              ldx     ##0                   ; X = the entry
2$:           rep     #0x21
              lda     long:SEGPATCHT,x      ; its address (0: the end)
              beq     9$
              sta     dp:.tiny DC_ENTRY
              txa
              adc     dp:.tiny DC_FRAC      ; (carry clear)
              sta     dp:.tiny DC_EXITP     ; the index of its bytes
              sep     #0x20
              lda     long:(SEGPATCHT+2),x  ; its count
              sta     dp:.tiny (DC_EXITP+2)
              phx
              ldx     dp:.tiny DC_EXITP
              ldy     ##0
3$:           lda     long:SEGPATCHT,x
              sta     [.tiny DC_ENTRY],y
              inx
              iny
              dec     dp:.tiny (DC_EXITP+2)
              bne     3$
              plx
              rep     #0x21                 ; the next entry, 9 bytes on
              txa
              adc     ##9
              tax
              bra     2$
9$:           rts
;;; T_SEGT: 1 while the seg loops have the patches of the 2/3 view.
T_SEGT:       .byte   0

;;; T_COLB: the screen byte of column c (26 + c - c div 3), 0xff: skipped.
              .public T_COLB
T_COLB:       .byte   26, 27, 0xff, 28, 29, 0xff, 30, 31, 0xff, 32, 33, 0xff
              .byte   34, 35, 0xff, 36, 37, 0xff, 38, 39, 0xff, 40, 41, 0xff
              .byte   42, 43, 0xff, 44, 45, 0xff, 46, 47, 0xff, 48, 49, 0xff
              .byte   50, 51, 0xff, 52, 53, 0xff, 54, 55, 0xff, 56, 57, 0xff
              .byte   58, 59, 0xff, 60, 61, 0xff, 62, 63, 0xff, 64, 65, 0xff
              .byte   66, 67, 0xff, 68, 69, 0xff, 70, 71, 0xff, 72, 73, 0xff
              .byte   74, 75, 0xff, 76, 77, 0xff, 78, 79, 0xff, 80, 81, 0xff
              .byte   82, 83, 0xff, 84, 85, 0xff, 86, 87, 0xff, 88, 89, 0xff
              .byte   90, 91, 0xff, 92, 93, 0xff, 94, 95, 0xff, 96, 97, 0xff
              .byte   98, 99, 0xff, 100, 101, 0xff, 102, 103, 0xff, 104, 105, 0xff
              .byte   106, 107, 0xff, 108, 109, 0xff, 110, 111, 0xff, 112, 113, 0xff
              .byte   114, 115, 0xff, 116, 117, 0xff, 118, 119, 0xff, 120, 121, 0xff
              .byte   122, 123, 0xff, 124, 125, 0xff, 126, 127, 0xff, 128, 129, 0xff
              .byte   130, 131, 0xff, 132
;;; T_PAGE2: the first page of the list of column c in the 2/3 view, at
;;; byte 2c (tcol2, todd: X = 2c). The rightmost kept columns (their records
;;; are read last) get the pages whose slots neither the 2/3 replay nor the
;;; seg phase uses ($00-$08, $0B-$0C, $1A-$1B, $78-$7F and the $80 mirrors),
;;; the others the window's pages from the left, the skipped columns (no
;;; records) the pages of the 2/3 replay code and blocks.
              .public T_PAGE2
T_PAGE2:
              .byte   0x32, 0x00, 0x33, 0x00, 0x20, 0x00, 0x34, 0x00, 0x35, 0x00, 0x21, 0x00, 0x36, 0x00, 0x37, 0x00
              .byte   0x22, 0x00, 0x38, 0x00, 0x39, 0x00, 0x23, 0x00, 0x3a, 0x00, 0x3b, 0x00, 0x24, 0x00, 0x3c, 0x00
              .byte   0x3d, 0x00, 0x25, 0x00, 0x3e, 0x00, 0x3f, 0x00, 0x26, 0x00, 0x40, 0x00, 0x41, 0x00, 0xa0, 0x00
              .byte   0x42, 0x00, 0x43, 0x00, 0xa1, 0x00, 0x44, 0x00, 0x45, 0x00, 0xa2, 0x00, 0x46, 0x00, 0x47, 0x00
              .byte   0xa3, 0x00, 0x48, 0x00, 0x49, 0x00, 0xa4, 0x00, 0x4a, 0x00, 0x4b, 0x00, 0xa5, 0x00, 0x4c, 0x00
              .byte   0x4d, 0x00, 0xa6, 0x00, 0x4e, 0x00, 0x4f, 0x00, 0x09, 0x00, 0x50, 0x00, 0x51, 0x00, 0x0a, 0x00
              .byte   0x52, 0x00, 0x53, 0x00, 0x89, 0x00, 0x54, 0x00, 0x55, 0x00, 0x8a, 0x00, 0x56, 0x00, 0x57, 0x00
              .byte   0x0d, 0x00, 0x58, 0x00, 0x59, 0x00, 0x0e, 0x00, 0x5a, 0x00, 0x5b, 0x00, 0x0f, 0x00, 0x5c, 0x00
              .byte   0x5d, 0x00, 0x10, 0x00, 0x5e, 0x00, 0x5f, 0x00, 0x11, 0x00, 0x60, 0x00, 0x61, 0x00, 0x12, 0x00
              .byte   0x62, 0x00, 0x63, 0x00, 0x13, 0x00, 0x64, 0x00, 0x65, 0x00, 0x14, 0x00, 0x66, 0x00, 0x67, 0x00
              .byte   0x15, 0x00, 0x68, 0x00, 0x69, 0x00, 0x16, 0x00, 0x6a, 0x00, 0x6b, 0x00, 0x17, 0x00, 0x6c, 0x00
              .byte   0x6d, 0x00, 0x18, 0x00, 0x6e, 0x00, 0x6f, 0x00, 0x19, 0x00, 0x70, 0x00, 0x71, 0x00, 0x8d, 0x00
              .byte   0x72, 0x00, 0x73, 0x00, 0x8e, 0x00, 0x74, 0x00, 0x75, 0x00, 0x8f, 0x00, 0x76, 0x00, 0x77, 0x00
              .byte   0x90, 0x00, 0xb2, 0x00, 0xb3, 0x00, 0x91, 0x00, 0xb4, 0x00, 0x0b, 0x00, 0x92, 0x00, 0x0c, 0x00
              .byte   0x8b, 0x00, 0x93, 0x00, 0x8c, 0x00, 0x1a, 0x00, 0x94, 0x00, 0x1b, 0x00, 0x9a, 0x00, 0x95, 0x00
              .byte   0x9b, 0x00, 0x00, 0x00, 0x96, 0x00, 0x01, 0x00, 0x02, 0x00, 0x97, 0x00, 0x03, 0x00, 0x04, 0x00
              .byte   0x98, 0x00, 0x05, 0x00, 0x06, 0x00, 0x99, 0x00, 0x07, 0x00, 0x08, 0x00, 0x1c, 0x00, 0x80, 0x00
              .byte   0x81, 0x00, 0x1d, 0x00, 0x82, 0x00, 0x83, 0x00, 0x1e, 0x00, 0x84, 0x00, 0x85, 0x00, 0x1f, 0x00
              .byte   0x86, 0x00, 0x87, 0x00, 0x9c, 0x00, 0x88, 0x00, 0x78, 0x00, 0x9d, 0x00, 0x79, 0x00, 0x7a, 0x00
              .byte   0x9e, 0x00, 0x7b, 0x00, 0x7c, 0x00, 0x9f, 0x00, 0x7d, 0x00, 0x7e, 0x00, 0xb5, 0x00, 0x7f, 0x00
;;; T_ROWK: k = r - r div 3 for the rows r = 0..168 (the window row of the
;;; first kept row from r on); bit 7: r mod 3 = 0.
T_ROWK:
              .byte   0x80, 0x01, 0x02, 0x82, 0x03, 0x04, 0x84, 0x05, 0x06, 0x86, 0x07, 0x08
              .byte   0x88, 0x09, 0x0a, 0x8a, 0x0b, 0x0c, 0x8c, 0x0d, 0x0e, 0x8e, 0x0f, 0x10
              .byte   0x90, 0x11, 0x12, 0x92, 0x13, 0x14, 0x94, 0x15, 0x16, 0x96, 0x17, 0x18
              .byte   0x98, 0x19, 0x1a, 0x9a, 0x1b, 0x1c, 0x9c, 0x1d, 0x1e, 0x9e, 0x1f, 0x20
              .byte   0xa0, 0x21, 0x22, 0xa2, 0x23, 0x24, 0xa4, 0x25, 0x26, 0xa6, 0x27, 0x28
              .byte   0xa8, 0x29, 0x2a, 0xaa, 0x2b, 0x2c, 0xac, 0x2d, 0x2e, 0xae, 0x2f, 0x30
              .byte   0xb0, 0x31, 0x32, 0xb2, 0x33, 0x34, 0xb4, 0x35, 0x36, 0xb6, 0x37, 0x38
              .byte   0xb8, 0x39, 0x3a, 0xba, 0x3b, 0x3c, 0xbc, 0x3d, 0x3e, 0xbe, 0x3f, 0x40
              .byte   0xc0, 0x41, 0x42, 0xc2, 0x43, 0x44, 0xc4, 0x45, 0x46, 0xc6, 0x47, 0x48
              .byte   0xc8, 0x49, 0x4a, 0xca, 0x4b, 0x4c, 0xcc, 0x4d, 0x4e, 0xce, 0x4f, 0x50
              .byte   0xd0, 0x51, 0x52, 0xd2, 0x53, 0x54, 0xd4, 0x55, 0x56, 0xd6, 0x57, 0x58
              .byte   0xd8, 0x59, 0x5a, 0xda, 0x5b, 0x5c, 0xdc, 0x5d, 0x5e, 0xde, 0x5f, 0x60
              .byte   0xe0, 0x61, 0x62, 0xe2, 0x63, 0x64, 0xe4, 0x65, 0x66, 0xe6, 0x67, 0x68
              .byte   0xe8, 0x69, 0x6a, 0xea, 0x6b, 0x6c, 0xec, 0x6d, 0x6e, 0xee, 0x6f, 0x70
              .byte   0xf0

;;; 1/3-view replay and column-page permutation. onePrepare installs the
;;; window/overlay patches at settings changes; oneViewMode selects the
;;; seg and replay dispatch. Other view modes do not execute onelist.
;;; Slots $26D0..$2FFF hold this code and its maps. The centered
;;; window writes slots $4335..$656A; its page map prioritizes other slots.
              .section onelist, text
OV_ROW0 .equ 56
OV_COL0 .equ 53
;;; oneSel: drawSel in the 1/3 view (the blocks of high detail).
oneSel:       lda     long:RL_DETI
              beq     oneAll
              lda     ##0
              jsl     long:R_SetDetailI

;;; oneAll: halfAll for the 1/3 view.
oneAll:      php
              rep     #0x20
              brl     spBeginO
              .space  9
spBeginDoneO:
              phb
              rep     #0x10
              sep     #0x20
              lda     #BUF_BANK             ; the data bank of the drawers
              pha
              plb
              lda     long:SHADOW
              pha
              and     #0xf7                 ; SHR shadowing on
              jsl     long:IIGS_SetShadow
              lda     #.byte2 iigs_shrcmapA ; the bank of the colormaps
              sta     dp:.tiny (DC_CMA+2)
              sta     dp:.tiny (DC_CMB+2)
              lda     #255                  ; no cut
              sta     dp:.tiny RL_CV0P
              lda     #0
ocol:         sta     dp:.tiny RL_HC        ; c = the next column
              xba                           ; X = c (TAX copies B = 0: no
              lda     #0                    ;   REP/SEP a column)
              xba
              tax
              lda     long:O_COLB,x         ; its screen byte, 0xff: skipped
              cmp     #0xff
              beq     oskip
              sta     dp:.tiny RL_C
              txa                           ; X = 2c
              asl     a
              xba
              rol     a
              xba
              tax
              lda     long:(CV_ROW+1),x     ; a covered range (lists.inc)?
              bne     ocv
              lda     long:COLW,x           ; the end of the list
              sta     dp:.tiny RL_E
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_E+1)
ocol2:        lda     #0                    ; no records for the next frame:
              sta     long:COLW,x           ;   the first page of c, offset 0
              lda     long:O_PAGE2,x
              sta     long:(COLW+1),x
              sta     dp:.tiny (RL_P+1)
              xba                           ; X = that page, offset 0
              lda     #0
              tax
              brl     odone
oskip:        txa                           ; a skipped column: its list and its
              asl     a                     ;   covered range empty for the next
              xba                           ;   frame (X = 2c)
              rol     a
              xba
              tax
              lda     #0
              sta     long:COLW,x
              sta     long:CV_ROW,x
              sta     long:(CV_ROW+1),x
              lda     long:O_PAGE2,x
              sta     long:(COLW+1),x
              brl     onext

;;; ocv: hcv for the 1/3 view.
ocv:          sta     dp:.tiny RL_CV1
              lda     long:CV_ROW,x         ; the first row (255: a shadow, no
              cmp     dp:.tiny RL_CV1       ;   range)
              bcs     1$
              sta     dp:.tiny RL_CV0
              inc     a
              sta     dp:.tiny RL_CV0P
              lda     long:COLW,x           ; the end of the list after the cut
              sta     dp:.tiny RL_CE
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_CE+1)
              lda     long:CV_REC,x         ; the cut ends at the covering record
              sta     dp:.tiny RL_E
              lda     long:(CV_REC+1),x
              sta     dp:.tiny (RL_E+1)
              bra     2$
1$:           lda     long:COLW,x           ; the end of the list
              sta     dp:.tiny RL_E
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_E+1)
2$:           lda     #0
              sta     long:CV_ROW,x
              sta     long:(CV_ROW+1),x
              brl     ocol2

;;; orec: the record at X (as hrec): B = its first row, A = its kind.
orec:         lda     long:(RECBASE+R_ROW),x
              xba
              lda     long:(RECBASE+R_KIND),x
              beq     otex
              cmp     #K_FILL
              bne     1$
              brl     ofill
1$:           cmp     #K_TEXC
              bne     2$
              brl     otexc
2$:           cmp     #K_NEXT
              bne     3$
              lda     long:(RECBASE+R_PAGE),x ; the list goes on at the start
              sta     dp:.tiny (RL_P+1)     ;   of the next page
              xba
              lda     #0
              tax
              brl     odone
3$:           cmp     #K_FUZZ
              bne     4$
              brl     ofuzz
4$:           txy                           ; K_OVL: the pixels of the automap
              brl     oOvl                  ;   overlay in this screen byte

;;; oOvl: hOvl for oneAll (am_map65: the rows are screen rows).
oOvl:         tyx
1$:           lda     long:(RECBASE+R_KEEP),x
              sta     dp:.tiny DC_FLATW
              lda     long:(RECBASE+R_COLOR),x
              sta     dp:.tiny (DC_FLATW+1)
              lda     long:(RECBASE+R_ROW),x
              asl     a                     ; X = 2 * the row
              xba
              lda     #0
              rol     a
              xba
              tax
              lda     long:scRowTab,x       ; X = its byte of the window
              clc
              adc     dp:.tiny RL_C
              xba
              lda     long:(scRowTab+1),x
              adc     #0
              xba
              tax
              lda     abs:0,x
              and     dp:.tiny DC_FLATW
              ora     dp:.tiny (DC_FLATW+1)
              sta     abs:0,x
              lda     dp:.tiny (RL_P+1)     ; the next record, in the same page
              xba
              tya
              clc
              adc     #OVL_SIZE
              tax
              tay
              cpx     dp:.tiny RL_E
              beq     2$
              lda     long:(RECBASE+R_KIND),x
              cmp     #K_OVL
              beq     1$
2$:           brl     odone

;;; otex: a K_TEX record: the step S (RL_HS) and 3S (DC_SF, DC_SI), the
;;; texels, the colormaps into the direct page (a K_TEXC after it takes
;;; them), its rows (oTexRows).
otex:         lda     long:(RECBASE+R_SF),x ; the step and three times the step
              sta     dp:.tiny RL_HS        ;   (its whole part mod 128: the
              asl     a                     ;   blocks need TI + SI + 1 < 256,
              sta     dp:.tiny DC_SF        ;   and TI is mod 128)
              lda     long:(RECBASE+R_SI),x
              sta     dp:.tiny (RL_HS+1)
              rol     a
              sta     dp:.tiny DC_SI
              lda     dp:.tiny DC_SF
              clc
              adc     dp:.tiny RL_HS
              sta     dp:.tiny DC_SF
              lda     dp:.tiny DC_SI
              adc     dp:.tiny (RL_HS+1)
              and     #0x7f
              sta     dp:.tiny DC_SI
              lda     long:(RECBASE+R_SRC),x ; the texels
              sta     dp:.tiny DC_SRC
              lda     long:(RECBASE+R_SRC+1),x
              sta     dp:.tiny (DC_SRC+1)
              lda     long:(RECBASE+R_SRC+2),x
              sta     dp:.tiny (DC_SRC+2)
              lda     long:(RECBASE+R_CMP),x ; the colormaps of the even and odd
              sta     dp:.tiny (DC_CMA+1)   ;   rows
              clc
              adc     #CMAP_B
              sta     dp:.tiny (DC_CMB+1)
              lda     long:(RECBASE+R_TF),x ; the position before the first row
              sta     dp:.tiny RL_HP
              lda     long:(RECBASE+R_TI),x
              sta     dp:.tiny (RL_HP+1)
              txa                           ; the next record, in the same page
              adc     #TEX_SIZE             ;   (carry clear: SI + carry < 256)
              sta     dp:.tiny RL_P
              xba                           ; the rows a .. b - 1 (B: a, orec)
              sta     dp:.tiny RL_HA
              lda     long:(RECBASE+R_END),x
              bra     oTexRows

;;; otexc: a K_TEXC record (as htexc).
otexc:        lda     long:(RECBASE+R_TCSRC),x
              sta     dp:.tiny DC_SRC
              lda     long:(RECBASE+R_TCSRC+1),x
              sta     dp:.tiny (DC_SRC+1)
              lda     long:(RECBASE+R_TF),x
              sta     dp:.tiny RL_HP
              lda     long:(RECBASE+R_TI),x
              sta     dp:.tiny (RL_HP+1)
              txa
              clc
              adc     #TEXC_SIZE
              sta     dp:.tiny RL_P
              xba                           ; (B: the first row, orec)
              sta     dp:.tiny RL_HA
              lda     long:(RECBASE+R_END),x

;;; oTexRows: the texture rows RL_HA .. A - 1 (8-bit A), the position RL_HP
;;; one row before the first, the step RL_HS; the cut in full rows, then the
;;; window rows with texBlocks.
;;; Entry low bytes are unique in this window: equal means no rows.
oTexRows:     cmp     dp:.tiny RL_CV0P      ; (past the first covered row: the
              bcc     1$                    ;   cut)
              jsr     .kbank oCut
              bcs     oNoRows               ; (no rows)
1$:           xba
              lda     #0
              xba
              tax
              lda     long:(texBlocks+0x100),x
              sta     dp:.tiny RL_XO
              lda     long:(texBlocks+0x200),x
              sta     dp:.tiny (RL_XO+1)
              lda     dp:.tiny RL_HA
              tax
              lda     long:(texBlocks+0x100),x
              cmp     dp:.tiny RL_XO
              beq     oNoRows
              sta     dp:.tiny RL_TENT
              lda     long:(texBlocks+0x200),x
              sta     dp:.tiny (RL_TENT+1)
nrOSite:      jmp     abs:.word0 (texBlocks+1)
              .space  104 - (. - oTexRows)
oneCont:      rep     #0x10
              lda     #0xeb                 ; XBA again
              sta     [.tiny RL_XO]
oNoRows:      ldx     dp:.tiny RL_P         ; X = the next record
              brl     odone
;;; oBack: the position RL_HP one step S back (8-bit A).
oBack:        lda     dp:.tiny RL_HP
              sec
              sbc     dp:.tiny RL_HS
              sta     dp:.tiny RL_HP
              lda     dp:.tiny (RL_HP+1)
              sbc     dp:.tiny (RL_HS+1)
              sta     dp:.tiny (RL_HP+1)
              rts

;;; oCut: hCut for oneAll.
oCut:         sta     dp:.tiny RL_HB        ; b
              lda     dp:.tiny RL_HA
              cmp     dp:.tiny RL_CV1       ; a >= c1: all rows
              bcs     8$
              cmp     dp:.tiny RL_CV0
              bcc     5$
              lda     dp:.tiny RL_HB        ; a >= c0, b <= c1: no rows
              cmp     dp:.tiny RL_CV1
              beq     9$
              bcc     9$
              lda     dp:.tiny RL_CV1       ; a >= c0, b > c1: the rows c1 ..
              sec                           ;   b - 1, the position + (c1 - a)
              sbc     dp:.tiny RL_HA        ;   * S
              rep     #0x20
              and     ##0x00ff
              sta     dp:.tiny RL_K
              lda     dp:.tiny RL_HS
              sta     dp:.tiny RL_ST
              lda     dp:.tiny RL_HP
1$:           lsr     dp:.tiny RL_K
              bcc     2$
              clc
              adc     dp:.tiny RL_ST
2$:           asl     dp:.tiny RL_ST
              ldy     dp:.tiny RL_K
              bne     1$
              sta     dp:.tiny RL_HP
              sep     #0x20
              lda     dp:.tiny RL_CV1
              sta     dp:.tiny RL_HA
8$:           lda     dp:.tiny RL_HB
              clc
              rts
5$:           lda     dp:.tiny RL_HB        ; a < c0: b > c1: all rows; b <= c1:
              cmp     dp:.tiny RL_CV1       ;   the rows a .. c0 - 1
              beq     6$
              bcs     8$
6$:           lda     dp:.tiny RL_CV0
              clc
              rts
9$:           sec
              rts

;;; ofill: a K_FILL record (B = its first row a): each window row gets the
;;; byte of its own parity (as hfill).
ofill:        xba
              sta     dp:.tiny RL_HA
              lsr     a
              lda     long:(RECBASE+R_B1),x
              bcs     1$
              sta     dp:.tiny RL_FE        ; an even a: B1 even, B2 odd
              lda     long:(RECBASE+R_B2),x
              sta     dp:.tiny RL_FO
              bra     2$
1$:           sta     dp:.tiny RL_FO        ; an odd a: B1 odd, B2 even
              lda     long:(RECBASE+R_B2),x
              sta     dp:.tiny RL_FE
2$:           txa                           ; the next record, in the same page
              clc
              adc     #FILL_SIZE
              sta     dp:.tiny RL_P
              lda     long:(RECBASE+R_END),x ; b; the cut in full rows
              cmp     dp:.tiny RL_CV0P
              bcc     3$
              jsr     .kbank oCutF
              bcs     9$
3$:           xba                           ; k1 = ceil(b / 3)
              lda     #0
              xba
              tax
              lda     long:O_CEIL3,x
              sta     dp:.tiny RL_HK1
              lda     dp:.tiny RL_HA        ; k0 = ceil(a / 3)
              tax
              lda     long:O_CEIL3,x
              cmp     dp:.tiny RL_HK1
              bcs     9$
              clc                           ; the first window row
              adc     #OV_ROW0
              sta     dp:.tiny RL_HK0
              rep     #0x20                 ; entry = flatBlocks + 4 * that row
              and     ##0x00ff
              asl     a
              asl     a
              adc     ##.word0 flatBlocks
              sta     dp:.tiny RL_FENT
              lda     dp:.tiny RL_HK1       ; RTS at the block of row 56 + k1
              and     ##0x00ff
              clc
              adc     ##OV_ROW0
              asl     a
              asl     a
              adc     ##.word0 flatBlocks
              tay
              sep     #0x20
              lda     #0x60
              sta     [.tiny RL_FX],y
              lda     dp:.tiny RL_HK0       ; B = the byte of the first window
              lsr     a                     ;   row (its parity), A = the other
              bcs     4$
              lda     dp:.tiny RL_FE
              xba
              lda     dp:.tiny RL_FO
              bra     5$
4$:           lda     dp:.tiny RL_FO
              xba
              lda     dp:.tiny RL_FE
5$:           ldx     dp:.tiny RL_C
              jsr     .kbank oFillJump
              lda     #0xeb                 ; XBA again
              sta     [.tiny RL_FX],y
9$:           ldx     dp:.tiny RL_P
              brl     odone
oFillJump:    jmp     (RL_FENT)             ; (rlFillJump's JMP, in this bank's
                                            ;   code: the blocks end with RTS)

;;; oCutF: hCutF for oneAll.
oCutF:        sta     dp:.tiny RL_HB
              lda     dp:.tiny RL_HA
              cmp     dp:.tiny RL_CV1       ; a >= c1: all rows
              bcs     8$
              cmp     dp:.tiny RL_CV0
              bcc     5$
              lda     dp:.tiny RL_HB        ; a >= c0, b <= c1: no rows
              cmp     dp:.tiny RL_CV1
              beq     9$
              bcc     9$
              lda     dp:.tiny RL_CV1       ; a >= c0, b > c1: c1 .. b - 1
              sta     dp:.tiny RL_HA
8$:           lda     dp:.tiny RL_HB
              clc
              rts
5$:           lda     dp:.tiny RL_HB        ; a < c0: b > c1: all rows; b <= c1:
              cmp     dp:.tiny RL_CV1       ;   the rows a .. c0 - 1
              beq     6$
              bcs     8$
6$:           lda     dp:.tiny RL_CV0
              clc
              rts
9$:           sec
              rts

;;; ofuzz: a K_FUZZ record (drawFuzz) on its window rows.
ofuzz:        lda     long:(RECBASE+R_ROW),x ; a, b = a + the count
              sta     dp:.tiny RL_HA
              clc
              adc     long:(RECBASE+R_COUNT),x
              xba                           ; k1 = ceil(b / 3)
              lda     #0
              xba
              phx
              tax
              lda     long:O_CEIL3,x
              sta     dp:.tiny RL_HK1
              plx
              rep     #0x20                 ; the next record
              txa
              clc
              adc     ##FUZZ_SIZE
              sta     dp:.tiny RL_P
              sep     #0x20
              phx
              lda     dp:.tiny RL_HA        ; k0 = ceil(a / 3)
              xba
              lda     #0
              xba
              tax
              lda     long:O_CEIL3,x
              plx
              cmp     dp:.tiny RL_HK1
              bcs     9$
              sta     dp:.tiny RL_HK0
              rep     #0x20
              and     ##0x00ff
              clc
              adc     ##OV_ROW0
              sta     dp:.tiny DC_ROW
              lda     dp:.tiny RL_HK1
              sec
              sbc     dp:.tiny RL_HK0
              and     ##0x00ff
              sta     dp:.tiny DC_COUNT
              lda     dp:.tiny RL_C
              and     ##0x00ff
              sta     dp:.tiny DC_COLX
              lda     long:(RECBASE+R_POS),x
              and     ##0x00ff
              jsl     long:fuzzColumn
              sep     #0x20
9$:           ldx     dp:.tiny RL_P
              brl     odone

;;; odone: the next record, or the end of the list.
odone:        cpx     dp:.tiny RL_E
              beq     1$
              brl     orec
1$:           lda     dp:.tiny RL_CV0P      ; the covering record: no cut from
              inc     a                     ;   it on
              bne     ocvEnd
onext:        lda     dp:.tiny RL_HC        ; the next column
              inc     a
              cmp     #CONST_VIEWWIDTH
              bcs     1$
              brl     ocol
1$:           lda     #XP_FIRST             ; no extra page used
              sta     long:XPNEXT
              pla
              jsl     long:IIGS_SetShadow
              plb
              rep     #0x20
              brl     spEndO
              .space  2
spEndDoneO:
              plp
              rts
ocvEnd:       lda     #255
              sta     dp:.tiny RL_CV0P
              lda     dp:.tiny RL_CE
              sta     dp:.tiny RL_E
              lda     dp:.tiny (RL_CE+1)
              sta     dp:.tiny (RL_E+1)
              brl     orec

;;; O_COLB: the screen byte of column c in the 1/3 view (53 + c / 3), 0xff:
;;; skipped.
O_COLB:
              .byte   0x35, 0xff, 0xff, 0x36, 0xff, 0xff, 0x37, 0xff, 0xff, 0x38, 0xff, 0xff
              .byte   0x39, 0xff, 0xff, 0x3a, 0xff, 0xff, 0x3b, 0xff, 0xff, 0x3c, 0xff, 0xff
              .byte   0x3d, 0xff, 0xff, 0x3e, 0xff, 0xff, 0x3f, 0xff, 0xff, 0x40, 0xff, 0xff
              .byte   0x41, 0xff, 0xff, 0x42, 0xff, 0xff, 0x43, 0xff, 0xff, 0x44, 0xff, 0xff
              .byte   0x45, 0xff, 0xff, 0x46, 0xff, 0xff, 0x47, 0xff, 0xff, 0x48, 0xff, 0xff
              .byte   0x49, 0xff, 0xff, 0x4a, 0xff, 0xff, 0x4b, 0xff, 0xff, 0x4c, 0xff, 0xff
              .byte   0x4d, 0xff, 0xff, 0x4e, 0xff, 0xff, 0x4f, 0xff, 0xff, 0x50, 0xff, 0xff
              .byte   0x51, 0xff, 0xff, 0x52, 0xff, 0xff, 0x53, 0xff, 0xff, 0x54, 0xff, 0xff
              .byte   0x55, 0xff, 0xff, 0x56, 0xff, 0xff, 0x57, 0xff, 0xff, 0x58, 0xff, 0xff
              .byte   0x59, 0xff, 0xff, 0x5a, 0xff, 0xff, 0x5b, 0xff, 0xff, 0x5c, 0xff, 0xff
              .byte   0x5d, 0xff, 0xff, 0x5e, 0xff, 0xff, 0x5f, 0xff, 0xff, 0x60, 0xff, 0xff
              .byte   0x61, 0xff, 0xff, 0x62, 0xff, 0xff, 0x63, 0xff, 0xff, 0x64, 0xff, 0xff
              .byte   0x65, 0xff, 0xff, 0x66, 0xff, 0xff, 0x67, 0xff, 0xff, 0x68, 0xff, 0xff
              .byte   0x69, 0xff, 0xff, 0x6a
;;; O_CEIL3: ceil(r / 3) for the rows r = 0..168 (the first window row from
;;; row r on).
O_CEIL3:
              .byte   0x00, 0x01, 0x01, 0x01, 0x02, 0x02, 0x02, 0x03, 0x03, 0x03, 0x04, 0x04
              .byte   0x04, 0x05, 0x05, 0x05, 0x06, 0x06, 0x06, 0x07, 0x07, 0x07, 0x08, 0x08
              .byte   0x08, 0x09, 0x09, 0x09, 0x0a, 0x0a, 0x0a, 0x0b, 0x0b, 0x0b, 0x0c, 0x0c
              .byte   0x0c, 0x0d, 0x0d, 0x0d, 0x0e, 0x0e, 0x0e, 0x0f, 0x0f, 0x0f, 0x10, 0x10
              .byte   0x10, 0x11, 0x11, 0x11, 0x12, 0x12, 0x12, 0x13, 0x13, 0x13, 0x14, 0x14
              .byte   0x14, 0x15, 0x15, 0x15, 0x16, 0x16, 0x16, 0x17, 0x17, 0x17, 0x18, 0x18
              .byte   0x18, 0x19, 0x19, 0x19, 0x1a, 0x1a, 0x1a, 0x1b, 0x1b, 0x1b, 0x1c, 0x1c
              .byte   0x1c, 0x1d, 0x1d, 0x1d, 0x1e, 0x1e, 0x1e, 0x1f, 0x1f, 0x1f, 0x20, 0x20
              .byte   0x20, 0x21, 0x21, 0x21, 0x22, 0x22, 0x22, 0x23, 0x23, 0x23, 0x24, 0x24
              .byte   0x24, 0x25, 0x25, 0x25, 0x26, 0x26, 0x26, 0x27, 0x27, 0x27, 0x28, 0x28
              .byte   0x28, 0x29, 0x29, 0x29, 0x2a, 0x2a, 0x2a, 0x2b, 0x2b, 0x2b, 0x2c, 0x2c
              .byte   0x2c, 0x2d, 0x2d, 0x2d, 0x2e, 0x2e, 0x2e, 0x2f, 0x2f, 0x2f, 0x30, 0x30
              .byte   0x30, 0x31, 0x31, 0x31, 0x32, 0x32, 0x32, 0x33, 0x33, 0x33, 0x34, 0x34
              .byte   0x34, 0x35, 0x35, 0x35, 0x36, 0x36, 0x36, 0x37, 0x37, 0x37, 0x38, 0x38
              .byte   0x38
;;; O_PAGE2: the first page of the list of column c in the 1/3 view at byte
;;; 2c (ocol2, oskip, oneViewMode): the kept columns from the right on the
;;; pages that the 1/3 replay leaves alone ($30-$3D, $40-$45 and their $80
;;; mirrors first), the others after.
O_PAGE2:
              .byte   0x01, 0x00, 0x02, 0x80, 0x03, 0x80, 0x00, 0x00, 0x04, 0x80, 0x05, 0x80, 0xa5, 0x00, 0x06, 0x80
              .byte   0x07, 0x80, 0xa4, 0x00, 0x08, 0x80, 0x26, 0x80, 0xa3, 0x00, 0x27, 0x80, 0x28, 0x80, 0xa2, 0x00
              .byte   0x29, 0x80, 0x2a, 0x80, 0xa1, 0x00, 0x2b, 0x80, 0x2c, 0x80, 0xa0, 0x00, 0x2d, 0x80, 0x2e, 0x80
              .byte   0x25, 0x00, 0x2f, 0x80, 0x3e, 0x80, 0x24, 0x00, 0x3f, 0x80, 0x46, 0x80, 0x23, 0x00, 0x47, 0x80
              .byte   0x48, 0x80, 0x22, 0x00, 0x49, 0x80, 0x4a, 0x80, 0x21, 0x00, 0x4b, 0x80, 0x4c, 0x80, 0x20, 0x00
              .byte   0x4d, 0x80, 0x4e, 0x80, 0xc5, 0x00, 0x4f, 0x80, 0x50, 0x80, 0xc4, 0x00, 0x51, 0x80, 0x52, 0x80
              .byte   0xc3, 0x00, 0x53, 0x80, 0x54, 0x80, 0xc2, 0x00, 0x55, 0x80, 0x56, 0x80, 0xc1, 0x00, 0x57, 0x80
              .byte   0x58, 0x80, 0xc0, 0x00, 0x59, 0x80, 0x5a, 0x80, 0xbd, 0x00, 0x5b, 0x80, 0x5c, 0x80, 0xbc, 0x00
              .byte   0x5d, 0x80, 0x5e, 0x80, 0xbb, 0x00, 0x5f, 0x80, 0x60, 0x80, 0xba, 0x00, 0x61, 0x80, 0x62, 0x80
              .byte   0xb9, 0x00, 0x63, 0x80, 0x64, 0x80, 0xb8, 0x00, 0x65, 0x80, 0x66, 0x80, 0xb7, 0x00, 0x67, 0x80
              .byte   0x68, 0x80, 0xb6, 0x00, 0x69, 0x80, 0x6a, 0x80, 0xb5, 0x00, 0x6b, 0x80, 0x6c, 0x80, 0xb4, 0x00
              .byte   0x6d, 0x80, 0x6e, 0x80, 0xb3, 0x00, 0x6f, 0x80, 0x70, 0x80, 0xb2, 0x00, 0x71, 0x80, 0x72, 0x80
              .byte   0xb1, 0x00, 0x73, 0x80, 0x74, 0x80, 0xb0, 0x00, 0x75, 0x80, 0x76, 0x80, 0x45, 0x00, 0x77, 0x80
              .byte   0x78, 0x80, 0x44, 0x00, 0x79, 0x80, 0x7a, 0x80, 0x43, 0x00, 0x7b, 0x80, 0x7c, 0x80, 0x42, 0x00
              .byte   0x7d, 0x80, 0x7e, 0x80, 0x41, 0x00, 0x7f, 0x80, 0x80, 0x80, 0x40, 0x00, 0x81, 0x80, 0x82, 0x80
              .byte   0x3d, 0x00, 0x83, 0x80, 0x84, 0x80, 0x3c, 0x00, 0x85, 0x80, 0x86, 0x80, 0x3b, 0x00, 0x87, 0x80
              .byte   0x88, 0x80, 0x3a, 0x00, 0xa6, 0x80, 0xa7, 0x80, 0x39, 0x00, 0xa8, 0x80, 0xa9, 0x80, 0x38, 0x00
              .byte   0xaa, 0x80, 0xab, 0x80, 0x37, 0x00, 0xac, 0x80, 0xad, 0x80, 0x36, 0x00, 0xae, 0x80, 0xaf, 0x80
              .byte   0x35, 0x00, 0xbe, 0x80, 0xbf, 0x80, 0x34, 0x00, 0xc6, 0x80, 0xc7, 0x80, 0x33, 0x00, 0xc8, 0x80
              .byte   0xc9, 0x80, 0x32, 0x00, 0xca, 0x80, 0xcb, 0x80, 0x31, 0x00, 0xcc, 0x80, 0xcd, 0x80, 0x30, 0x00

;;; O_PAGE2 high bytes are $80 for skipped columns, zero for kept ones;
;;; 16-bit tier checks use their sign, 8-bit fills read the high byte.
;;; texCol span interpolation is disabled in this size (ONE_TC/ONE_SPAN).
;;; Bank-3 calls keep their bank-3 return address. The checkers therefore
;;; return through an existing bank-3 RTS, never an RTS in bank 5.
              .extern drawMid, drawTop, drawBot, ceilFill, ceilSky, floorFill
              .extern texCol, tcNew, tcLoad, ONE_TC, ONE_SPAN, oneSkip
              .section onelist, text
oneMid:       lda     long:O_PAGE2,x
              bmi     oneSkip16
              cpx     dp:W_TCX
              beq     1$
              jmp     long:(drawMid+4)
1$:           jmp     long:(drawMid+7)
oneTop:       lda     long:O_PAGE2,x
              bmi     oneSkip16
              cpx     dp:W_TCX
              beq     1$
              jmp     long:(drawTop+4)
1$:           jmp     long:(drawTop+7)
oneBot:       lda     long:O_PAGE2,x
              bmi     oneSkip16
              cpx     dp:W_TCX
              beq     1$
              jmp     long:(drawBot+4)
1$:           jmp     long:(drawBot+7)
oneSkip16:    sep     #0x20
              jmp     long:oneSkip
oneCeil:      lda     long:(O_PAGE2+1),x
              bne     oneSkip16
              lda     dp:W_SKY
              beq     1$
              jmp     long:ceilSky
1$:           jmp     long:(ceilFill+4)
oneFloor:     lda     long:(O_PAGE2+1),x
              bne     oneSkip16
              lda     dp:W_FCR
              cmp     dp:W_BOTR
              jmp     long:(floorFill+4)

;;; All setup is cold, in reserved bank-5 space after the level loader. Normal frames
;;; execute the original instruction bytes at the original addresses.
              .section onecold, text
              .extern OF_CMP, OF_CPY, OF_FLAG, OF_SMALL, OF_BORDER, VWTAB
              .extern OA_MODE, OA_CLEAN, pixHalf, OA_ROW, pixOne, oneOvlRow
              .extern G_RememberSettings
              .public oneNormalize, oneRemember, oneDetail, oneViewMode
O_SAVE        .equ    (MM_BV + 0xbd70)
oneNormalize: cmp     ##VW_QUARTERSIZE
              beq     1$
              cmp     ##VW_THREEQUARTERSIZE
              beq     1$
              cmp     ##VW_ONESIZE
              beq     1$
              cmp     ##VW_HALFSIZE
              beq     1$
              cmp     ##VW_TWOSIZE
              beq     1$
              lda     ##10
1$:           rtl
oneRemember:  jsl     long:onePrepare
              jmp     long:G_RememberSettings
oneDetail:    jsl     long:onePrepare
              jmp     long:R_SetDetail
onePrepare:   php
              rep     #0x30
              lda     long:O_UIACTIVE
              and     ##255
              beq     1$
              jsr     .kbank oneChoose
              lda     ##0
              jsr     .kbank onePatch
1$:           lda     ##0
              sta     long:VW_ONE
              sta     long:O_UIACTIVE
              lda     long:VW_SIZE
              jsr     .kbank oneChoose
              bcc     9$
              lda     ##1
              jsr     .kbank onePatch
              lda     ##1
              sta     long:VW_ONE
              sep     #0x20
              lda     long:VW_SIZE
              sta     long:O_UIACTIVE
9$:           plp
              rtl
oneViewMode:  php
              rep     #0x30
              lda     long:O_SEGACTIVE
              and     ##255
              beq     1$
              jsr     .kbank oneChoose
              txa
              clc
              adc     ##(O_SEG-O_PATCH)
              tax
              lda     ##0
              jsr     .kbank onePatch
1$:           jsl     long:R_ViewMode
              lda     long:VW_SIZE
              jsr     .kbank oneChoose
              bcc     oneModeDone
              phx
              lda     ##0
              jsl     long:R_SegHalf
              pla
              clc
              adc     ##(O_SEG-O_PATCH)
              tax
              lda     ##1
              jsr     .kbank onePatch
              ldx     ##318
onePage:      lda     long:O_PAGE2,x
              and     ##255
              xba
              sta     long:COLW,x
              dex
              dex
              bpl     onePage
              sep     #0x20
              lda     #0x4c
              sta     long:drawSel
              rep     #0x20
oneDispatch:  lda     ##.word0 oneSel
              sta     long:(drawSel+1)
oneModeDone:  sep     #0x20
              lda     #0
              sta     long:O_SEGACTIVE
              lda     long:VW_ONE
              beq     8$
              lda     long:VW_SIZE
              sta     long:O_SEGACTIVE
8$:           plp
              rtl
;;; Mode selection is cold. The page and dispatch operands are bank 5.
oneChoose:    ldx     ##0
              cmp     ##VW_ONESIZE
              beq     1$
              ldx     ##6
              cmp     ##VW_QUARTERSIZE
              beq     1$
              ldx     ##12
              cmp     ##VW_THREEQUARTERSIZE
              beq     1$
              clc
              rts
1$:           lda     long:(fourModes+2),x
              sta     long:(onePage+1)
              lda     long:(fourModes+4),x
              sta     long:(oneDispatch+1)
              lda     long:fourModes,x
              tax
              sec
              rts
fourModes:    .word 0, .word0 O_PAGE2, .word0 oneSel
              .word Q_PATCH-O_PATCH, .word0 Q_PAGE2, .word0 qSel
              .word U_PATCH-O_PATCH, .word0 U_PAGE2, .word0 uSel
;;; A=1 saves and installs; A=0 restores. X indexes O_PATCH. Each entry
;;; is address(3), count(1), new bytes(4). Backups have the same index.
onePatch:     sta     dp:.tiny RL_HA
1$:           rep     #0x20
              lda     long:O_PATCH,x
              beq     9$
              sta     dp:.tiny DC_ENTRY
              stx     dp:.tiny DC_FRAC
              sep     #0x20
              lda     long:(O_PATCH+2),x
              sta     dp:.tiny (DC_ENTRY+2)
              lda     long:(O_PATCH+3),x
              sta     dp:.tiny DC_EXITP
              inx
              inx
              inx
              inx
              ldy     ##0
2$:           lda     dp:.tiny RL_HA
              beq     3$
              lda     [.tiny DC_ENTRY],y
              sta     long:O_SAVE,x
              lda     long:O_PATCH,x
              bra     4$
3$:           lda     long:O_SAVE,x
4$:           sta     [.tiny DC_ENTRY],y
              inx
              iny
              dec     dp:.tiny DC_EXITP
              bne     2$
              rep     #0x21
              lda     dp:.tiny DC_FRAC
              adc     ##8
              tax
              bra     1$
9$:           rts
O_UIACTIVE:   .word   0
O_SEGACTIVE:  .word   0
O_PATCH:
              .byte   .byte0 (OF_CMP+1), .byte1 (OF_CMP+1), .byte2 (OF_CMP+1)
              .byte   1
              .byte   VW_ONESIZE
              .space  3
              .byte   .byte0 (OF_CPY+1), .byte1 (OF_CPY+1), .byte2 (OF_CPY+1)
              .byte   1
              .byte   VW_ONESIZE
              .space  3
              .byte   .byte0 (OF_FLAG+1), .byte1 (OF_FLAG+1), .byte2 (OF_FLAG+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (OF_SMALL+1), .byte1 (OF_SMALL+1), .byte2 (OF_SMALL+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (OF_BORDER+1), .byte1 (OF_BORDER+1), .byte2 (OF_BORDER+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (OA_MODE+1), .byte1 (OA_MODE+1), .byte2 (OA_MODE+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (OA_CLEAN+1), .byte1 (OA_CLEAN+1), .byte2 (OA_CLEAN+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (VWTAB+8), .byte1 (VWTAB+8), .byte2 (VWTAB+8)
              .byte   4
              .word   53, 106
              .space  0
              .byte   .byte0 (VWTAB+12), .byte1 (VWTAB+12), .byte2 (VWTAB+12)
              .byte   4
              .word   55, 112
              .space  0
              .byte   .byte0 (pixHalf), .byte1 (pixHalf), .byte2 (pixHalf)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (pixOne), .byte1 (pixOne), .byte2 (pixOne)
              .space  0
              .byte   .byte0 (OA_ROW), .byte1 (OA_ROW), .byte2 (OA_ROW)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (oneOvlRow), .byte1 (oneOvlRow), .byte2 (oneOvlRow)
              .space  0
              .word   0
O_SEG:
              .byte   .byte0 (drawMid), .byte1 (drawMid), .byte2 (drawMid)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (oneMid), .byte1 (oneMid), .byte2 (oneMid)
              .space  0
              .byte   .byte0 (drawTop), .byte1 (drawTop), .byte2 (drawTop)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (oneTop), .byte1 (oneTop), .byte2 (oneTop)
              .space  0
              .byte   .byte0 (drawBot), .byte1 (drawBot), .byte2 (drawBot)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (oneBot), .byte1 (oneBot), .byte2 (oneBot)
              .space  0
              .byte   .byte0 (ceilFill), .byte1 (ceilFill), .byte2 (ceilFill)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (oneCeil), .byte1 (oneCeil), .byte2 (oneCeil)
              .space  0
              .byte   .byte0 (floorFill), .byte1 (floorFill), .byte2 (floorFill)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (oneFloor), .byte1 (oneFloor), .byte2 (oneFloor)
              .space  0
              .byte   .byte0 (ONE_TC), .byte1 (ONE_TC), .byte2 (ONE_TC)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (tcNew), .byte1 (tcNew), .byte2 (tcNew)
              .space  0
              .byte   .byte0 (ONE_SPAN), .byte1 (ONE_SPAN), .byte2 (ONE_SPAN)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (tcLoad), .byte1 (tcLoad), .byte2 (tcLoad)
              .space  0
              .word   0

Q_PATCH:
              .byte   .byte0 (OF_CMP+1), .byte1 (OF_CMP+1), .byte2 (OF_CMP+1)
              .byte   1
              .byte   VW_QUARTERSIZE
              .space  3
              .byte   .byte0 (OF_CPY+1), .byte1 (OF_CPY+1), .byte2 (OF_CPY+1)
              .byte   1
              .byte   VW_QUARTERSIZE
              .space  3
              .byte   .byte0 (OF_FLAG+1), .byte1 (OF_FLAG+1), .byte2 (OF_FLAG+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (OF_SMALL+1), .byte1 (OF_SMALL+1), .byte2 (OF_SMALL+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (OF_BORDER+1), .byte1 (OF_BORDER+1), .byte2 (OF_BORDER+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (OA_MODE+1), .byte1 (OA_MODE+1), .byte2 (OA_MODE+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (OA_CLEAN+1), .byte1 (OA_CLEAN+1), .byte2 (OA_CLEAN+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (VWTAB+8), .byte1 (VWTAB+8), .byte2 (VWTAB+8)
              .byte   4
              .word   60, 99
              .space  0
              .byte   .byte0 (VWTAB+12), .byte1 (VWTAB+12), .byte2 (VWTAB+12)
              .byte   4
              .word   62, 105
              .space  0
              .byte   .byte0 (pixHalf), .byte1 (pixHalf), .byte2 (pixHalf)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (pixQuarter), .byte1 (pixQuarter), .byte2 (pixQuarter)
              .space  0
              .byte   .byte0 (OA_ROW), .byte1 (OA_ROW), .byte2 (OA_ROW)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (quarterOvlRow), .byte1 (quarterOvlRow), .byte2 (quarterOvlRow)
              .space  0
              .word   0
Q_SEG:
              .byte   .byte0 (drawMid), .byte1 (drawMid), .byte2 (drawMid)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (qMid), .byte1 (qMid), .byte2 (qMid)
              .space  0
              .byte   .byte0 (drawTop), .byte1 (drawTop), .byte2 (drawTop)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (qTop), .byte1 (qTop), .byte2 (qTop)
              .space  0
              .byte   .byte0 (drawBot), .byte1 (drawBot), .byte2 (drawBot)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (qBot), .byte1 (qBot), .byte2 (qBot)
              .space  0
              .byte   .byte0 (ceilFill), .byte1 (ceilFill), .byte2 (ceilFill)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (qCeil), .byte1 (qCeil), .byte2 (qCeil)
              .space  0
              .byte   .byte0 (floorFill), .byte1 (floorFill), .byte2 (floorFill)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (qFloor), .byte1 (qFloor), .byte2 (qFloor)
              .space  0
              .byte   .byte0 (ONE_TC), .byte1 (ONE_TC), .byte2 (ONE_TC)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (tcNew), .byte1 (tcNew), .byte2 (tcNew)
              .space  0
              .byte   .byte0 (ONE_SPAN), .byte1 (ONE_SPAN), .byte2 (ONE_SPAN)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (tcLoad), .byte1 (tcLoad), .byte2 (tcLoad)
              .space  0
              .word   0

U_PATCH:
              .byte   .byte0 (OF_CMP+1), .byte1 (OF_CMP+1), .byte2 (OF_CMP+1)
              .byte   1
              .byte   VW_THREEQUARTERSIZE
              .space  3
              .byte   .byte0 (OF_CPY+1), .byte1 (OF_CPY+1), .byte2 (OF_CPY+1)
              .byte   1
              .byte   VW_THREEQUARTERSIZE
              .space  3
              .byte   .byte0 (OF_FLAG+1), .byte1 (OF_FLAG+1), .byte2 (OF_FLAG+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (OF_SMALL+1), .byte1 (OF_SMALL+1), .byte2 (OF_SMALL+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (OF_BORDER+1), .byte1 (OF_BORDER+1), .byte2 (OF_BORDER+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (OA_MODE+1), .byte1 (OA_MODE+1), .byte2 (OA_MODE+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (OA_CLEAN+1), .byte1 (OA_CLEAN+1), .byte2 (OA_CLEAN+1)
              .byte   2
              .word   .word0 VW_ONE
              .space  2
              .byte   .byte0 (VWTAB+8), .byte1 (VWTAB+8), .byte2 (VWTAB+8)
              .byte   4
              .word   20, 139
              .space  0
              .byte   .byte0 (VWTAB+12), .byte1 (VWTAB+12), .byte2 (VWTAB+12)
              .byte   4
              .word   20, 147
              .space  0
              .byte   .byte0 (pixHalf), .byte1 (pixHalf), .byte2 (pixHalf)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (pixThreequarter), .byte1 (pixThreequarter), .byte2 (pixThreequarter)
              .space  0
              .byte   .byte0 (OA_ROW), .byte1 (OA_ROW), .byte2 (OA_ROW)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (threequarterOvlRow), .byte1 (threequarterOvlRow), .byte2 (threequarterOvlRow)
              .space  0
              .word   0
U_SEG:
              .byte   .byte0 (drawMid), .byte1 (drawMid), .byte2 (drawMid)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (uMid), .byte1 (uMid), .byte2 (uMid)
              .space  0
              .byte   .byte0 (drawTop), .byte1 (drawTop), .byte2 (drawTop)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (uTop), .byte1 (uTop), .byte2 (uTop)
              .space  0
              .byte   .byte0 (drawBot), .byte1 (drawBot), .byte2 (drawBot)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (uBot), .byte1 (uBot), .byte2 (uBot)
              .space  0
              .byte   .byte0 (ceilFill), .byte1 (ceilFill), .byte2 (ceilFill)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (uCeil), .byte1 (uCeil), .byte2 (uCeil)
              .space  0
              .byte   .byte0 (floorFill), .byte1 (floorFill), .byte2 (floorFill)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (uFloor), .byte1 (uFloor), .byte2 (uFloor)
              .space  0
              .byte   .byte0 (ONE_TC), .byte1 (ONE_TC), .byte2 (ONE_TC)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (tcNew), .byte1 (tcNew), .byte2 (tcNew)
              .space  0
              .byte   .byte0 (ONE_SPAN), .byte1 (ONE_SPAN), .byte2 (ONE_SPAN)
              .byte   4
              .byte   0x5c
              .byte   .byte0 (tcLoad), .byte1 (tcLoad), .byte2 (tcLoad)
              .space  0
              .word   0

;;; Dedicated new-size replays. No old hot fragment changes.
              .section fourlist, text
QV_ROW0 .equ 63
QV_COL0 .equ 60
UV_ROW0 .equ 21
qSel:       lda     long:RL_DETI
              beq     qAll
              lda     ##0
              jsl     long:R_SetDetailI

;;; qAll: halfAll for the 1/4 view.
qAll:      php
              rep     #0x20
              brl     spBeginQ
              .space  9
spBeginDoneQ:
              phb
              rep     #0x10
              sep     #0x20
              lda     #BUF_BANK             ; the data bank of the drawers
              pha
              plb
              lda     long:SHADOW
              pha
              and     #0xf7                 ; SHR shadowing on
              jsl     long:IIGS_SetShadow
              lda     #.byte2 iigs_shrcmapA ; the bank of the colormaps
              sta     dp:.tiny (DC_CMA+2)
              sta     dp:.tiny (DC_CMB+2)
              lda     #255                  ; no cut
              sta     dp:.tiny RL_CV0P
              lda     #0
qcol:         sta     dp:.tiny RL_HC        ; c = the next column
              xba                           ; X = c (TAX copies B = 0: no
              lda     #0                    ;   REP/SEP a column)
              xba
              tax
              lda     long:Q_COLB,x         ; its screen byte, 0xff: skipped
              cmp     #0xff
              beq     qskip
              sta     dp:.tiny RL_C
              txa                           ; X = 2c
              asl     a
              xba
              rol     a
              xba
              tax
              lda     long:(CV_ROW+1),x     ; a covered range (lists.inc)?
              bne     qcv
              lda     long:COLW,x           ; the end of the list
              sta     dp:.tiny RL_E
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_E+1)
qcol2:        lda     #0                    ; no records for the next frame:
              sta     long:COLW,x           ;   the first page of c, offset 0
              lda     long:Q_PAGE2,x
              sta     long:(COLW+1),x
              sta     dp:.tiny (RL_P+1)
              xba                           ; X = that page, offset 0
              lda     #0
              tax
              brl     qdone
qskip:        txa                           ; a skipped column: its list and its
              asl     a                     ;   covered range empty for the next
              xba                           ;   frame (X = 2c)
              rol     a
              xba
              tax
              lda     #0
              sta     long:COLW,x
              sta     long:CV_ROW,x
              sta     long:(CV_ROW+1),x
              lda     long:Q_PAGE2,x
              sta     long:(COLW+1),x
              brl     qnext

;;; qcv: hcv for the 1/4 view.
qcv:          sta     dp:.tiny RL_CV1
              lda     long:CV_ROW,x         ; the first row (255: a shadow, no
              cmp     dp:.tiny RL_CV1       ;   range)
              bcs     1$
              sta     dp:.tiny RL_CV0
              inc     a
              sta     dp:.tiny RL_CV0P
              lda     long:COLW,x           ; the end of the list after the cut
              sta     dp:.tiny RL_CE
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_CE+1)
              lda     long:CV_REC,x         ; the cut ends at the covering record
              sta     dp:.tiny RL_E
              lda     long:(CV_REC+1),x
              sta     dp:.tiny (RL_E+1)
              bra     2$
1$:           lda     long:COLW,x           ; the end of the list
              sta     dp:.tiny RL_E
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_E+1)
2$:           lda     #0
              sta     long:CV_ROW,x
              sta     long:(CV_ROW+1),x
              brl     qcol2

;;; qrec: the record at X (as hrec): B = its first row, A = its kind.
qrec:         lda     long:(RECBASE+R_ROW),x
              xba
              lda     long:(RECBASE+R_KIND),x
              beq     qtex
              cmp     #K_FILL
              bne     1$
              brl     qfill
1$:           cmp     #K_TEXC
              bne     2$
              brl     qtexc
2$:           cmp     #K_NEXT
              bne     3$
              lda     long:(RECBASE+R_PAGE),x ; the list goes on at the start
              sta     dp:.tiny (RL_P+1)     ;   of the next page
              xba
              lda     #0
              tax
              brl     qdone
3$:           cmp     #K_FUZZ
              bne     4$
              brl     qfuzz
4$:           txy                           ; K_OVL: the pixels of the automap
              brl     qOvl                  ;   overlay in this screen byte

;;; qOvl: hOvl for qAll (am_map65: the rows are screen rows).
qOvl:         tyx
1$:           lda     long:(RECBASE+R_KEEP),x
              sta     dp:.tiny DC_FLATW
              lda     long:(RECBASE+R_COLOR),x
              sta     dp:.tiny (DC_FLATW+1)
              lda     long:(RECBASE+R_ROW),x
              asl     a                     ; X = 2 * the row
              xba
              lda     #0
              rol     a
              xba
              tax
              lda     long:scRowTab,x       ; X = its byte of the window
              clc
              adc     dp:.tiny RL_C
              xba
              lda     long:(scRowTab+1),x
              adc     #0
              xba
              tax
              lda     abs:0,x
              and     dp:.tiny DC_FLATW
              ora     dp:.tiny (DC_FLATW+1)
              sta     abs:0,x
              lda     dp:.tiny (RL_P+1)     ; the next record, in the same page
              xba
              tya
              clc
              adc     #OVL_SIZE
              tax
              tay
              cpx     dp:.tiny RL_E
              beq     2$
              lda     long:(RECBASE+R_KIND),x
              cmp     #K_OVL
              beq     1$
2$:           brl     qdone

;;; qtex: a K_TEX record: the step S (RL_HS) and 4S (DC_SF, DC_SI), the
;;; texels, the colormaps into the direct page (a K_TEXC after it takes
;;; them), its rows (qTexRows).
qtex:         lda     long:(RECBASE+R_SF),x ; the step and four times the step
              sta     dp:.tiny RL_HS        ;   (its whole part mod 128: the
              asl     a                     ;   blocks need TI + SI + 1 < 256,
              sta     dp:.tiny DC_SF        ;   and TI is mod 128)
              lda     long:(RECBASE+R_SI),x
              sta     dp:.tiny (RL_HS+1)
              rol     a
              sta     dp:.tiny DC_SI
              lda     dp:.tiny DC_SF
              clc
              asl     a
              sta     dp:.tiny DC_SF
              lda     dp:.tiny DC_SI
              rol     a
              and     #0x7f
              sta     dp:.tiny DC_SI
              lda     long:(RECBASE+R_SRC),x ; the texels
              sta     dp:.tiny DC_SRC
              lda     long:(RECBASE+R_SRC+1),x
              sta     dp:.tiny (DC_SRC+1)
              lda     long:(RECBASE+R_SRC+2),x
              sta     dp:.tiny (DC_SRC+2)
              lda     long:(RECBASE+R_CMP),x ; the colormaps of the even and odd
              sta     dp:.tiny (DC_CMA+1)   ;   rows
              clc
              adc     #CMAP_B
              sta     dp:.tiny (DC_CMB+1)
              lda     long:(RECBASE+R_TF),x ; the position before the first row
              sta     dp:.tiny RL_HP
              lda     long:(RECBASE+R_TI),x
              sta     dp:.tiny (RL_HP+1)
              txa                           ; the next record, in the same page
              adc     #TEX_SIZE             ;   (carry clear: SI + carry < 256)
              sta     dp:.tiny RL_P
              xba                           ; the rows a .. b - 1 (B: a, qrec)
              sta     dp:.tiny RL_HA
              lda     long:(RECBASE+R_END),x
              bra     qTexRows

;;; qtexc: a K_TEXC record (as htexc).
qtexc:        lda     long:(RECBASE+R_TCSRC),x
              sta     dp:.tiny DC_SRC
              lda     long:(RECBASE+R_TCSRC+1),x
              sta     dp:.tiny (DC_SRC+1)
              lda     long:(RECBASE+R_TF),x
              sta     dp:.tiny RL_HP
              lda     long:(RECBASE+R_TI),x
              sta     dp:.tiny (RL_HP+1)
              txa
              clc
              adc     #TEXC_SIZE
              sta     dp:.tiny RL_P
              xba                           ; (B: the first row, qrec)
              sta     dp:.tiny RL_HA
              lda     long:(RECBASE+R_END),x

;;; qTexRows: the texture rows RL_HA .. A - 1 (8-bit A), the position RL_HP
;;; one row before the first, the step RL_HS; the cut in full rows, then the
;;; window rows with texBlocks.
;;; Entry low bytes are unique in this window: equal means no rows.
qTexRows:     cmp     dp:.tiny RL_CV0P      ; (past the first covered row: the
              bcc     1$                    ;   cut)
              jsr     .kbank qCut
              bcs     qNoRows               ; (no rows)
1$:           xba
              lda     #0
              xba
              tax
              lda     long:(texBlocks+0x100),x
              sta     dp:.tiny RL_XO
              lda     long:(texBlocks+0x200),x
              sta     dp:.tiny (RL_XO+1)
              lda     dp:.tiny RL_HA
              tax
              lda     long:(texBlocks+0x100),x
              cmp     dp:.tiny RL_XO
              beq     qNoRows
              sta     dp:.tiny RL_TENT
              lda     long:(texBlocks+0x200),x
              sta     dp:.tiny (RL_TENT+1)
nrQSite:      jmp     abs:.word0 (texBlocks+1)
              .space  101 - (. - qTexRows)
qCont:      rep     #0x10
              lda     #0xeb                 ; XBA again
              sta     [.tiny RL_XO]
qNoRows:      ldx     dp:.tiny RL_P         ; X = the next record
              brl     qdone
;;; qBack: the position RL_HP one step S back (8-bit A).
qBack:        lda     dp:.tiny RL_HP
              sec
              sbc     dp:.tiny RL_HS
              sta     dp:.tiny RL_HP
              lda     dp:.tiny (RL_HP+1)
              sbc     dp:.tiny (RL_HS+1)
              sta     dp:.tiny (RL_HP+1)
              rts

;;; qCut: hCut for qAll.
qCut:         sta     dp:.tiny RL_HB        ; b
              lda     dp:.tiny RL_HA
              cmp     dp:.tiny RL_CV1       ; a >= c1: all rows
              bcs     8$
              cmp     dp:.tiny RL_CV0
              bcc     5$
              lda     dp:.tiny RL_HB        ; a >= c0, b <= c1: no rows
              cmp     dp:.tiny RL_CV1
              beq     9$
              bcc     9$
              lda     dp:.tiny RL_CV1       ; a >= c0, b > c1: the rows c1 ..
              sec                           ;   b - 1, the position + (c1 - a)
              sbc     dp:.tiny RL_HA        ;   * S
              rep     #0x20
              and     ##0x00ff
              sta     dp:.tiny RL_K
              lda     dp:.tiny RL_HS
              sta     dp:.tiny RL_ST
              lda     dp:.tiny RL_HP
1$:           lsr     dp:.tiny RL_K
              bcc     2$
              clc
              adc     dp:.tiny RL_ST
2$:           asl     dp:.tiny RL_ST
              ldy     dp:.tiny RL_K
              bne     1$
              sta     dp:.tiny RL_HP
              sep     #0x20
              lda     dp:.tiny RL_CV1
              sta     dp:.tiny RL_HA
8$:           lda     dp:.tiny RL_HB
              clc
              rts
5$:           lda     dp:.tiny RL_HB        ; a < c0: b > c1: all rows; b <= c1:
              cmp     dp:.tiny RL_CV1       ;   the rows a .. c0 - 1
              beq     6$
              bcs     8$
6$:           lda     dp:.tiny RL_CV0
              clc
              rts
9$:           sec
              rts

;;; qfill: a K_FILL record (B = its first row a): each window row gets the
;;; byte of its own parity (as hfill).
qfill:        xba
              sta     dp:.tiny RL_HA
              lsr     a
              lda     long:(RECBASE+R_B1),x
              bcs     1$
              sta     dp:.tiny RL_FE        ; an even a: B1 even, B2 odd
              lda     long:(RECBASE+R_B2),x
              sta     dp:.tiny RL_FO
              bra     2$
1$:           sta     dp:.tiny RL_FO        ; an odd a: B1 odd, B2 even
              lda     long:(RECBASE+R_B2),x
              sta     dp:.tiny RL_FE
2$:           txa                           ; the next record, in the same page
              clc
              adc     #FILL_SIZE
              sta     dp:.tiny RL_P
              lda     long:(RECBASE+R_END),x ; b; the cut in full rows
              cmp     dp:.tiny RL_CV0P
              bcc     3$
              jsr     .kbank qCutF
              bcs     9$
3$:           xba                           ; k1 = ceil(b / 4)
              lda     #0
              xba
              tax
              lda     long:Q_CEIL4,x
              sta     dp:.tiny RL_HK1
              lda     dp:.tiny RL_HA        ; k0 = ceil(a / 4)
              tax
              lda     long:Q_CEIL4,x
              cmp     dp:.tiny RL_HK1
              bcs     9$
              clc                           ; the first window row
              adc     #QV_ROW0
              sta     dp:.tiny RL_HK0
              rep     #0x20                 ; entry = flatBlocks + 4 * that row
              and     ##0x00ff
              asl     a
              asl     a
              adc     ##.word0 flatBlocks
              sta     dp:.tiny RL_FENT
              lda     dp:.tiny RL_HK1       ; RTS at the block of row 56 + k1
              and     ##0x00ff
              clc
              adc     ##QV_ROW0
              asl     a
              asl     a
              adc     ##.word0 flatBlocks
              tay
              sep     #0x20
              lda     #0x60
              sta     [.tiny RL_FX],y
              lda     dp:.tiny RL_HK0       ; B = the byte of the first window
              lsr     a                     ;   row (its parity), A = the other
              bcs     4$
              lda     dp:.tiny RL_FE
              xba
              lda     dp:.tiny RL_FO
              bra     5$
4$:           lda     dp:.tiny RL_FO
              xba
              lda     dp:.tiny RL_FE
5$:           ldx     dp:.tiny RL_C
              jsr     .kbank qFillJump
              lda     #0xeb                 ; XBA again
              sta     [.tiny RL_FX],y
9$:           ldx     dp:.tiny RL_P
              brl     qdone
qFillJump:    jmp     (RL_FENT)             ; (rlFillJump's JMP, in this bank's
                                            ;   code: the blocks end with RTS)

;;; qCutF: hCutF for qAll.
qCutF:        sta     dp:.tiny RL_HB
              lda     dp:.tiny RL_HA
              cmp     dp:.tiny RL_CV1       ; a >= c1: all rows
              bcs     8$
              cmp     dp:.tiny RL_CV0
              bcc     5$
              lda     dp:.tiny RL_HB        ; a >= c0, b <= c1: no rows
              cmp     dp:.tiny RL_CV1
              beq     9$
              bcc     9$
              lda     dp:.tiny RL_CV1       ; a >= c0, b > c1: c1 .. b - 1
              sta     dp:.tiny RL_HA
8$:           lda     dp:.tiny RL_HB
              clc
              rts
5$:           lda     dp:.tiny RL_HB        ; a < c0: b > c1: all rows; b <= c1:
              cmp     dp:.tiny RL_CV1       ;   the rows a .. c0 - 1
              beq     6$
              bcs     8$
6$:           lda     dp:.tiny RL_CV0
              clc
              rts
9$:           sec
              rts

;;; qfuzz: a K_FUZZ record (drawFuzz) on its window rows.
qfuzz:        lda     long:(RECBASE+R_ROW),x ; a, b = a + the count
              sta     dp:.tiny RL_HA
              clc
              adc     long:(RECBASE+R_COUNT),x
              xba                           ; k1 = ceil(b / 4)
              lda     #0
              xba
              phx
              tax
              lda     long:Q_CEIL4,x
              sta     dp:.tiny RL_HK1
              plx
              rep     #0x20                 ; the next record
              txa
              clc
              adc     ##FUZZ_SIZE
              sta     dp:.tiny RL_P
              sep     #0x20
              phx
              lda     dp:.tiny RL_HA        ; k0 = ceil(a / 4)
              xba
              lda     #0
              xba
              tax
              lda     long:Q_CEIL4,x
              plx
              cmp     dp:.tiny RL_HK1
              bcs     9$
              sta     dp:.tiny RL_HK0
              rep     #0x20
              and     ##0x00ff
              clc
              adc     ##QV_ROW0
              sta     dp:.tiny DC_ROW
              lda     dp:.tiny RL_HK1
              sec
              sbc     dp:.tiny RL_HK0
              and     ##0x00ff
              sta     dp:.tiny DC_COUNT
              lda     dp:.tiny RL_C
              and     ##0x00ff
              sta     dp:.tiny DC_COLX
              lda     long:(RECBASE+R_POS),x
              and     ##0x00ff
              jsl     long:fuzzColumn
              sep     #0x20
9$:           ldx     dp:.tiny RL_P
              brl     qdone

;;; qdone: the next record, or the end of the list.
qdone:        cpx     dp:.tiny RL_E
              beq     1$
              brl     qrec
1$:           lda     dp:.tiny RL_CV0P      ; the covering record: no cut from
              inc     a                     ;   it on
              bne     qcvEnd
qnext:        lda     dp:.tiny RL_HC        ; the next column
              inc     a
              cmp     #CONST_VIEWWIDTH
              bcs     1$
              brl     qcol
1$:           lda     #XP_FIRST             ; no extra page used
              sta     long:XPNEXT
              pla
              jsl     long:IIGS_SetShadow
              plb
              rep     #0x20
              brl     spEndQ
              .space  2
spEndDoneQ:
              plp
              rts
qcvEnd:       lda     #255
              sta     dp:.tiny RL_CV0P
              lda     dp:.tiny RL_CE
              sta     dp:.tiny RL_E
              lda     dp:.tiny (RL_CE+1)
              sta     dp:.tiny (RL_E+1)
              brl     qrec

;;; 
Q_COLB:
              .byte   0x3c, 0xff, 0xff, 0xff, 0x3d, 0xff, 0xff, 0xff, 0x3e, 0xff, 0xff, 0xff, 0x3f, 0xff, 0xff, 0xff
              .byte   0x40, 0xff, 0xff, 0xff, 0x41, 0xff, 0xff, 0xff, 0x42, 0xff, 0xff, 0xff, 0x43, 0xff, 0xff, 0xff
              .byte   0x44, 0xff, 0xff, 0xff, 0x45, 0xff, 0xff, 0xff, 0x46, 0xff, 0xff, 0xff, 0x47, 0xff, 0xff, 0xff
              .byte   0x48, 0xff, 0xff, 0xff, 0x49, 0xff, 0xff, 0xff, 0x4a, 0xff, 0xff, 0xff, 0x4b, 0xff, 0xff, 0xff
              .byte   0x4c, 0xff, 0xff, 0xff, 0x4d, 0xff, 0xff, 0xff, 0x4e, 0xff, 0xff, 0xff, 0x4f, 0xff, 0xff, 0xff
              .byte   0x50, 0xff, 0xff, 0xff, 0x51, 0xff, 0xff, 0xff, 0x52, 0xff, 0xff, 0xff, 0x53, 0xff, 0xff, 0xff
              .byte   0x54, 0xff, 0xff, 0xff, 0x55, 0xff, 0xff, 0xff, 0x56, 0xff, 0xff, 0xff, 0x57, 0xff, 0xff, 0xff
              .byte   0x58, 0xff, 0xff, 0xff, 0x59, 0xff, 0xff, 0xff, 0x5a, 0xff, 0xff, 0xff, 0x5b, 0xff, 0xff, 0xff
              .byte   0x5c, 0xff, 0xff, 0xff, 0x5d, 0xff, 0xff, 0xff, 0x5e, 0xff, 0xff, 0xff, 0x5f, 0xff, 0xff, 0xff
              .byte   0x60, 0xff, 0xff, 0xff, 0x61, 0xff, 0xff, 0xff, 0x62, 0xff, 0xff, 0xff, 0x63, 0xff, 0xff, 0xff
Q_CEIL4:
              .byte   0x00, 0x01, 0x01, 0x01, 0x01, 0x02, 0x02, 0x02, 0x02, 0x03, 0x03, 0x03, 0x03, 0x04, 0x04, 0x04
              .byte   0x04, 0x05, 0x05, 0x05, 0x05, 0x06, 0x06, 0x06, 0x06, 0x07, 0x07, 0x07, 0x07, 0x08, 0x08, 0x08
              .byte   0x08, 0x09, 0x09, 0x09, 0x09, 0x0a, 0x0a, 0x0a, 0x0a, 0x0b, 0x0b, 0x0b, 0x0b, 0x0c, 0x0c, 0x0c
              .byte   0x0c, 0x0d, 0x0d, 0x0d, 0x0d, 0x0e, 0x0e, 0x0e, 0x0e, 0x0f, 0x0f, 0x0f, 0x0f, 0x10, 0x10, 0x10
              .byte   0x10, 0x11, 0x11, 0x11, 0x11, 0x12, 0x12, 0x12, 0x12, 0x13, 0x13, 0x13, 0x13, 0x14, 0x14, 0x14
              .byte   0x14, 0x15, 0x15, 0x15, 0x15, 0x16, 0x16, 0x16, 0x16, 0x17, 0x17, 0x17, 0x17, 0x18, 0x18, 0x18
              .byte   0x18, 0x19, 0x19, 0x19, 0x19, 0x1a, 0x1a, 0x1a, 0x1a, 0x1b, 0x1b, 0x1b, 0x1b, 0x1c, 0x1c, 0x1c
              .byte   0x1c, 0x1d, 0x1d, 0x1d, 0x1d, 0x1e, 0x1e, 0x1e, 0x1e, 0x1f, 0x1f, 0x1f, 0x1f, 0x20, 0x20, 0x20
              .byte   0x20, 0x21, 0x21, 0x21, 0x21, 0x22, 0x22, 0x22, 0x22, 0x23, 0x23, 0x23, 0x23, 0x24, 0x24, 0x24
              .byte   0x24, 0x25, 0x25, 0x25, 0x25, 0x26, 0x26, 0x26, 0x26, 0x27, 0x27, 0x27, 0x27, 0x28, 0x28, 0x28
              .byte   0x28, 0x29, 0x29, 0x29, 0x29, 0x2a, 0x2a, 0x2a, 0x2a
Q_PAGE2:
              .byte   0x45, 0x00, 0x67, 0x80, 0x68, 0x80, 0x69, 0x80, 0x44, 0x00, 0x6a, 0x80, 0x6b, 0x80, 0x6c, 0x80
              .byte   0x43, 0x00, 0x6d, 0x80, 0x6e, 0x80, 0x6f, 0x80, 0x42, 0x00, 0x70, 0x80, 0x71, 0x80, 0x72, 0x80
              .byte   0x41, 0x00, 0x73, 0x80, 0x74, 0x80, 0x75, 0x80, 0x40, 0x00, 0x76, 0x80, 0x77, 0x80, 0x78, 0x80
              .byte   0x3d, 0x00, 0x79, 0x80, 0x7a, 0x80, 0x7b, 0x80, 0x3c, 0x00, 0x7c, 0x80, 0x7d, 0x80, 0x7e, 0x80
              .byte   0x3b, 0x00, 0x7f, 0x80, 0x80, 0x80, 0x81, 0x80, 0x3a, 0x00, 0x82, 0x80, 0x83, 0x80, 0x84, 0x80
              .byte   0xa6, 0x00, 0x85, 0x80, 0x86, 0x80, 0x87, 0x80, 0xa7, 0x00, 0x88, 0x80, 0x01, 0x80, 0x02, 0x80
              .byte   0x39, 0x00, 0x03, 0x80, 0x00, 0x80, 0x04, 0x80, 0xa8, 0x00, 0x05, 0x80, 0xa5, 0x80, 0x06, 0x80
              .byte   0xa9, 0x00, 0x07, 0x80, 0xa4, 0x80, 0x08, 0x80, 0x38, 0x00, 0x26, 0x80, 0xa3, 0x80, 0x27, 0x80
              .byte   0xaa, 0x00, 0x28, 0x80, 0xa2, 0x80, 0x29, 0x80, 0xab, 0x00, 0x2a, 0x80, 0xa1, 0x80, 0x2b, 0x80
              .byte   0x37, 0x00, 0x2c, 0x80, 0xa0, 0x80, 0x2d, 0x80, 0xac, 0x00, 0x2e, 0x80, 0x25, 0x80, 0x2f, 0x80
              .byte   0xad, 0x00, 0x3e, 0x80, 0x24, 0x80, 0x3f, 0x80, 0x36, 0x00, 0x46, 0x80, 0x23, 0x80, 0x47, 0x80
              .byte   0xae, 0x00, 0x48, 0x80, 0x22, 0x80, 0x49, 0x80, 0xaf, 0x00, 0x4a, 0x80, 0x21, 0x80, 0x4b, 0x80
              .byte   0x35, 0x00, 0x4c, 0x80, 0x20, 0x80, 0x4d, 0x80, 0xbe, 0x00, 0x4e, 0x80, 0xc5, 0x80, 0x4f, 0x80
              .byte   0xbf, 0x00, 0x50, 0x80, 0xc4, 0x80, 0x51, 0x80, 0x34, 0x00, 0x52, 0x80, 0xc3, 0x80, 0x53, 0x80
              .byte   0xc6, 0x00, 0x54, 0x80, 0xc2, 0x80, 0x55, 0x80, 0xc7, 0x00, 0x56, 0x80, 0xc1, 0x80, 0x57, 0x80
              .byte   0x33, 0x00, 0x58, 0x80, 0xc0, 0x80, 0x59, 0x80, 0xc8, 0x00, 0x5a, 0x80, 0xbd, 0x80, 0x5b, 0x80
              .byte   0xc9, 0x00, 0x5c, 0x80, 0xbc, 0x80, 0x5d, 0x80, 0x32, 0x00, 0x5e, 0x80, 0xbb, 0x80, 0x5f, 0x80
              .byte   0xca, 0x00, 0x60, 0x80, 0xba, 0x80, 0x61, 0x80, 0xcb, 0x00, 0x62, 0x80, 0xb9, 0x80, 0x63, 0x80
              .byte   0x31, 0x00, 0x64, 0x80, 0xb8, 0x80, 0x65, 0x80, 0xcc, 0x00, 0x66, 0x80, 0xb7, 0x80, 0xb6, 0x80
              .byte   0xcd, 0x00, 0xb5, 0x80, 0xb4, 0x80, 0xb3, 0x80, 0x30, 0x00, 0xb2, 0x80, 0xb1, 0x80, 0xb0, 0x80
qMid:       lda     long:Q_PAGE2,x
              bmi     qSkip16
              cpx     dp:W_TCX
              beq     1$
              jmp     long:(drawMid+4)
1$:           jmp     long:(drawMid+7)
qTop:       lda     long:Q_PAGE2,x
              bmi     qSkip16
              cpx     dp:W_TCX
              beq     1$
              jmp     long:(drawTop+4)
1$:           jmp     long:(drawTop+7)
qBot:       lda     long:Q_PAGE2,x
              bmi     qSkip16
              cpx     dp:W_TCX
              beq     1$
              jmp     long:(drawBot+4)
1$:           jmp     long:(drawBot+7)
qSkip16:    sep     #0x20
              jmp     long:oneSkip
qCeil:      lda     long:(Q_PAGE2+1),x
              bne     qSkip16
              lda     dp:W_SKY
              beq     1$
              jmp     long:ceilSky
1$:           jmp     long:(ceilFill+4)
qFloor:     lda     long:(Q_PAGE2+1),x
              bne     qSkip16
              lda     dp:W_FCR
              cmp     dp:W_BOTR
              jmp     long:(floorFill+4)

uRowK:        xba
              lda     #0
              xba
              tax
              lda     long:U_ROWK,x
              rts

;;; uSel: drawSel in the 3/4 view (R_ViewMode patches drawSel to jump
;;; here): the 3/4 blocks in texBlocks once, then uAll.
uSel:     lda     long:RL_DETI
              cmp     ##8
              beq     uAll
              jsl     long:uSet

;;; uAll: halfAll for the 3/4 view.
uAll:      php
              rep     #0x20
              brl     spBeginU
              .space  9
spBeginDoneU:
              phb
              rep     #0x10
              sep     #0x20
              lda     #BUF_BANK             ; the data bank of the drawers
              pha
              plb
              lda     long:SHADOW
              pha
              and     #0xf7                 ; SHR shadowing on
              jsl     long:IIGS_SetShadow
              lda     #.byte2 iigs_shrcmapA ; the bank of the colormaps
              sta     dp:.tiny (DC_CMA+2)
              sta     dp:.tiny (DC_CMB+2)
              lda     #255                  ; no cut
              sta     dp:.tiny RL_CV0P
              lda     #0
ucol:         sta     dp:.tiny RL_HC        ; c = the next column
              xba                           ; X = c (TAX copies B = 0: no
              lda     #0                    ;   REP/SEP a column)
              xba
              tax
              lda     long:U_COLB,x         ; its screen byte, 0xff: skipped
              cmp     #0xff
              beq     uodd
              sta     dp:.tiny RL_C
              txa                           ; X = 2c
              asl     a
              xba
              rol     a
              xba
              tax
              lda     long:(CV_ROW+1),x     ; a covered range (lists.inc)?
              bne     ucv
              lda     long:COLW,x           ; the end of the list
              sta     dp:.tiny RL_E
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_E+1)
ucol2:        lda     #0                    ; no records for the next frame:
              sta     long:COLW,x           ;   COLPAGE(c), offset 0 (U_PAGE2:
              lda     long:U_PAGE2,x        ;   cheaper than the macro)
              sta     long:(COLW+1),x
              sta     dp:.tiny (RL_P+1)
              xba                           ; X = that page, offset 0
              lda     #0
              tax
              brl     udone
uodd:         txa                           ; a skipped column: its list and its
              asl     a                     ;   covered range empty for the next
              xba                           ;   frame (X = 2c)
              rol     a
              xba
              tax
              lda     #0
              sta     long:COLW,x
              sta     long:CV_ROW,x
              sta     long:(CV_ROW+1),x
              lda     long:U_PAGE2,x
              sta     long:(COLW+1),x
              brl     unext

;;; ucv: hcv for the 3/4 view.
ucv:          sta     dp:.tiny RL_CV1
              lda     long:CV_ROW,x
              cmp     dp:.tiny RL_CV1
              bcs     1$
              sta     dp:.tiny RL_CV0
              inc     a
              sta     dp:.tiny RL_CV0P
              lda     long:COLW,x
              sta     dp:.tiny RL_CE
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_CE+1)
              lda     long:CV_REC,x
              sta     dp:.tiny RL_E
              lda     long:(CV_REC+1),x
              sta     dp:.tiny (RL_E+1)
              bra     2$
1$:           lda     long:COLW,x
              sta     dp:.tiny RL_E
              lda     long:(COLW+1),x
              sta     dp:.tiny (RL_E+1)
2$:           lda     #0
              sta     long:CV_ROW,x
              sta     long:(CV_ROW+1),x
              brl     ucol2

;;; urec: the record at X: B = its first row, A = its kind (8-bit reads:
;;; no REP/SEP a record). K_TEX is 0.
urec:         lda     long:(RECBASE+R_ROW),x
              xba
              lda     long:(RECBASE+R_KIND),x
              beq     utex
              cmp     #K_FILL
              bne     2$
              brl     ufill
2$:           cmp     #K_TEXC
              bne     3$
              brl     utexc
3$:           cmp     #K_NEXT
              bne     4$
              lda     long:(RECBASE+R_PAGE),x ; the list goes on at the start
              sta     dp:.tiny (RL_P+1)     ;   of the next page
              xba                           ; X = that page, offset 0
              lda     #0
              tax
              brl     udone
4$:           cmp     #K_FUZZ
              bne     5$
              brl     ufuzz
5$:           txy                           ; K_OVL: the automap overlay
              brl     uOvl

;;; utex: a K_TEX record: its step S, texels, colormaps, the position before
;;; its first row (uTexRows).
utex:         lda     long:(RECBASE+R_SF),x ; the step (the blocks step once or
              sta     dp:.tiny DC_SF        ;   twice with it; RL_HS only for a
              lda     long:(RECBASE+R_SI),x ;   cut, uTexRows)
              sta     dp:.tiny DC_SI
              lda     long:(RECBASE+R_SRC),x ; the texels
              sta     dp:.tiny DC_SRC
              lda     long:(RECBASE+R_SRC+1),x
              sta     dp:.tiny (DC_SRC+1)
              lda     long:(RECBASE+R_SRC+2),x
              sta     dp:.tiny (DC_SRC+2)
              lda     long:(RECBASE+R_CMP),x ; the colormaps of the even and odd
              sta     dp:.tiny (DC_CMA+1)   ;   screen rows
              clc
              adc     #CMAP_B
              sta     dp:.tiny (DC_CMB+1)
              lda     long:(RECBASE+R_TF),x ; the position before the first row
              sta     dp:.tiny RL_HP
              lda     long:(RECBASE+R_TI),x
              sta     dp:.tiny (RL_HP+1)
              txa                           ; the next record, in the same page
              adc     #TEX_SIZE             ;   (carry clear: SI + carry < 256)
              sta     dp:.tiny RL_P
              xba                           ; the rows a .. b - 1
              sta     dp:.tiny RL_HA
              lda     long:(RECBASE+R_END),x
              bra     uTexRows

;;; utexc: a K_TEXC record (htexc; B = its first row).
utexc:        lda     long:(RECBASE+R_TCSRC),x
              sta     dp:.tiny DC_SRC
              lda     long:(RECBASE+R_TCSRC+1),x
              sta     dp:.tiny (DC_SRC+1)
              lda     long:(RECBASE+R_TF),x
              sta     dp:.tiny RL_HP
              lda     long:(RECBASE+R_TI),x
              sta     dp:.tiny (RL_HP+1)
              txa
              clc
              adc     #TEXC_SIZE
              sta     dp:.tiny RL_P
              xba
              sta     dp:.tiny RL_HA
              lda     long:(RECBASE+R_END),x

;;; uTexRows: keep r mod 4 < 3. k = r-r/4; screen row = 21+k.
;;; The first block steps twice only when k mod 3 = 0. Back up one
;;; source step only when a mod 4 = 0; other starts already align.
;;; Entry-map bit 7 marks starts that need one source step back.
uTexRows:     cmp     dp:.tiny RL_CV0P
              bcc     1$
              pha                           ; the cut (hCut steps RL_HS)
              lda     dp:.tiny DC_SF
              sta     dp:.tiny RL_HS
              lda     dp:.tiny DC_SI
              sta     dp:.tiny (RL_HS+1)
              pla
              jsr     .kbank hCut
              bcs     uNoRows
1$:           xba
              lda     #0
              xba
              tax
              lda     long:(texBlocks+0x8c0),x
              sta     dp:.tiny RL_XO
              lda     long:(texBlocks+0x980),x
              and     #0x7f
              sta     dp:.tiny (RL_XO+1)
              lda     dp:.tiny RL_HA
              tax
              lda     long:(texBlocks+0x8c0),x
              cmp     dp:.tiny RL_XO
              bne     10$                  ; low bytes repeat on long spans
              lda     long:(texBlocks+0x980),x
              and     #0x7f
              cmp     dp:.tiny (RL_XO+1)
              beq     uNoRows
              lda     long:(texBlocks+0x8c0),x
10$:
              sta     dp:.tiny RL_TENT
              lda     long:(texBlocks+0x980),x
              bpl     11$
              and     #0x7f
              sta     dp:.tiny (RL_TENT+1)
              lda     dp:.tiny RL_HP
              xba
              lda     dp:.tiny (RL_HP+1)
              xba
              sec
              sbc     dp:.tiny DC_SF
              xba
              sbc     dp:.tiny DC_SI
              bra     12$
11$:          sta     dp:.tiny (RL_TENT+1)
              lda     dp:.tiny RL_HP
              xba
              lda     dp:.tiny (RL_HP+1)
12$:          and     #0x7f
              jmp     abs:.word0 (texBlocks+0xa30)
              .space  109 - (. - uTexRows)
uCont:        rep     #0x10
              lda     #0xeb                 ; XBA again
              sta     [.tiny RL_XO]
uNoRows:      ldx     dp:.tiny RL_P         ; X = the next record
              brl     udone

;;; ufill: a K_FILL record (hfill): each window row gets the byte of its
;;; screen row's parity (the dither of the full view).
ufill:        xba
              sta     dp:.tiny RL_HA
              lsr     a
              lda     long:(RECBASE+R_B1),x
              bcs     1$
              sta     dp:.tiny RL_FE        ; an even a: B1 even, B2 odd
              lda     long:(RECBASE+R_B2),x
              sta     dp:.tiny RL_FO
              bra     2$
1$:           sta     dp:.tiny RL_FO
              lda     long:(RECBASE+R_B2),x
              sta     dp:.tiny RL_FE
2$:           txa
              clc
              adc     #FILL_SIZE
              sta     dp:.tiny RL_P
              lda     long:(RECBASE+R_END),x ; b; the cut in full rows
              cmp     dp:.tiny RL_CV0P
              bcc     3$
              jsr     .kbank hCutF
              bcs     9$
3$:           xba                           ; k1, k0 (X = b, B = 0: TAX copies
              lda     #0                    ;   it)
              xba
              tax
              lda     long:U_ROWK,x
              and     #0x7f
              sta     dp:.tiny RL_HK1
              lda     dp:.tiny RL_HA
              tax
              lda     long:U_ROWK,x
              and     #0x7f
              cmp     dp:.tiny RL_HK1
              bcs     9$
              sta     dp:.tiny RL_HK0
              rep     #0x21                 ; entry = the fill block of k0 (C =
              asl     a                     ;   k0: B = 0)
              asl     a
              adc     long:UFLAT_ADDR
              sta     dp:.tiny RL_FENT
              lda     dp:.tiny RL_HK1       ; RTS at the block of k1
              and     ##0x00ff
              asl     a
              asl     a
              adc     long:UFLAT_ADDR
              tay
              sep     #0x20
              lda     #0x60
              sta     [.tiny RL_FX],y
              lda     dp:.tiny RL_HK0       ; B = the byte of the first window
              lsr     a                     ;   row (screen row 21 + k0: the
              bcc     4$                    ;   opposite parity of k0), A = the other
              lda     dp:.tiny RL_FE
              xba
              lda     dp:.tiny RL_FO
              bra     5$
4$:           lda     dp:.tiny RL_FO
              xba
              lda     dp:.tiny RL_FE
5$:           ldx     dp:.tiny RL_C
              jsr     .kbank rlFillJump
              lda     #0xeb                 ; XBA again
              sta     [.tiny RL_FX],y
9$:           ldx     dp:.tiny RL_P
              brl     udone

;;; ufuzz: a K_FUZZ record (hfuzz) on its window rows.
ufuzz:        phx
              lda     long:(RECBASE+R_ROW),x ; a, b = a + the count
              sta     dp:.tiny RL_HA
              clc
              adc     long:(RECBASE+R_COUNT),x
              jsr     .kbank uRowK          ; k1
              and     #0x7f
              sta     dp:.tiny RL_HK1
              lda     dp:.tiny RL_HA
              jsr     .kbank uRowK          ; k0
              and     #0x7f
              sta     dp:.tiny RL_HK0
              plx
              rep     #0x20
              txa                           ; the next record
              clc
              adc     ##FUZZ_SIZE
              sta     dp:.tiny RL_P
              sep     #0x20
              lda     dp:.tiny RL_HK0
              cmp     dp:.tiny RL_HK1
              bcs     9$
              rep     #0x20
              and     ##0x00ff
              clc
              adc     ##UV_ROW0
              sta     dp:.tiny DC_ROW
              lda     dp:.tiny RL_HK1
              sec
              sbc     dp:.tiny RL_HK0
              and     ##0x00ff
              sta     dp:.tiny DC_COUNT
              lda     dp:.tiny RL_C
              and     ##0x00ff
              sta     dp:.tiny DC_COLX
              lda     long:(RECBASE+R_POS),x
              and     ##0x00ff
              jsl     long:fuzzColumn
9$:           sep     #0x20
              ldx     dp:.tiny RL_P
              brl     udone

;;; uOvl: drawOvl for uAll; the rows are screen rows (am_map65).
uOvl:         tyx                           ; (8-bit A: the indexes by TAX
1$:           lda     long:(RECBASE+R_KEEP),x ;   with B, no REP/SEP a pixel)
              sta     dp:.tiny DC_FLATW
              lda     long:(RECBASE+R_COLOR),x
              sta     dp:.tiny (DC_FLATW+1)
              lda     long:(RECBASE+R_ROW),x
              asl     a                     ; X = 2 * the row
              xba
              lda     #0
              rol     a
              xba
              tax
              lda     long:scRowTab,x       ; X = its byte of the window
              clc
              adc     dp:.tiny RL_C
              xba
              lda     long:(scRowTab+1),x
              adc     #0
              xba
              tax
              lda     abs:0,x
              and     dp:.tiny DC_FLATW
              ora     dp:.tiny (DC_FLATW+1)
              sta     abs:0,x
              lda     dp:.tiny (RL_P+1)     ; the next record, in the same page
              xba
              tya
              clc
              adc     #OVL_SIZE
              tax
              tay
              cpx     dp:.tiny RL_E
              beq     2$
              lda     long:(RECBASE+R_KIND),x
              cmp     #K_OVL
              beq     1$
2$:           brl     udone

;;; udone: the next record, or the end of the list.
udone:        cpx     dp:.tiny RL_E
              beq     1$
              brl     urec
1$:           lda     dp:.tiny RL_CV0P
              inc     a
              bne     ucvEnd
unext:        lda     dp:.tiny RL_HC        ; the next column
              inc     a
              cmp     #CONST_VIEWWIDTH
              bcs     1$
              brl     ucol
1$:           lda     #XP_FIRST             ; no extra page used
              sta     long:XPNEXT
              pla
              jsl     long:IIGS_SetShadow
              plb
              rep     #0x20
              brl     spEndU
              .space  2
spEndDoneU:
              plp
              rts
ucvEnd:       lda     #255
              sta     dp:.tiny RL_CV0P
              lda     dp:.tiny RL_CE
              sta     dp:.tiny RL_E
              lda     dp:.tiny (RL_CE+1)
              sta     dp:.tiny (RL_E+1)
              brl     urec


U_COLB:
              .byte   0x14, 0x15, 0x16, 0xff, 0x17, 0x18, 0x19, 0xff, 0x1a, 0x1b, 0x1c, 0xff, 0x1d, 0x1e, 0x1f, 0xff
              .byte   0x20, 0x21, 0x22, 0xff, 0x23, 0x24, 0x25, 0xff, 0x26, 0x27, 0x28, 0xff, 0x29, 0x2a, 0x2b, 0xff
              .byte   0x2c, 0x2d, 0x2e, 0xff, 0x2f, 0x30, 0x31, 0xff, 0x32, 0x33, 0x34, 0xff, 0x35, 0x36, 0x37, 0xff
              .byte   0x38, 0x39, 0x3a, 0xff, 0x3b, 0x3c, 0x3d, 0xff, 0x3e, 0x3f, 0x40, 0xff, 0x41, 0x42, 0x43, 0xff
              .byte   0x44, 0x45, 0x46, 0xff, 0x47, 0x48, 0x49, 0xff, 0x4a, 0x4b, 0x4c, 0xff, 0x4d, 0x4e, 0x4f, 0xff
              .byte   0x50, 0x51, 0x52, 0xff, 0x53, 0x54, 0x55, 0xff, 0x56, 0x57, 0x58, 0xff, 0x59, 0x5a, 0x5b, 0xff
              .byte   0x5c, 0x5d, 0x5e, 0xff, 0x5f, 0x60, 0x61, 0xff, 0x62, 0x63, 0x64, 0xff, 0x65, 0x66, 0x67, 0xff
              .byte   0x68, 0x69, 0x6a, 0xff, 0x6b, 0x6c, 0x6d, 0xff, 0x6e, 0x6f, 0x70, 0xff, 0x71, 0x72, 0x73, 0xff
              .byte   0x74, 0x75, 0x76, 0xff, 0x77, 0x78, 0x79, 0xff, 0x7a, 0x7b, 0x7c, 0xff, 0x7d, 0x7e, 0x7f, 0xff
              .byte   0x80, 0x81, 0x82, 0xff, 0x83, 0x84, 0x85, 0xff, 0x86, 0x87, 0x88, 0xff, 0x89, 0x8a, 0x8b, 0xff
U_ROWK:
              .byte   0x80, 0x01, 0x02, 0x03, 0x83, 0x04, 0x05, 0x06, 0x86, 0x07, 0x08, 0x09, 0x89, 0x0a, 0x0b, 0x0c
              .byte   0x8c, 0x0d, 0x0e, 0x0f, 0x8f, 0x10, 0x11, 0x12, 0x92, 0x13, 0x14, 0x15, 0x95, 0x16, 0x17, 0x18
              .byte   0x98, 0x19, 0x1a, 0x1b, 0x9b, 0x1c, 0x1d, 0x1e, 0x9e, 0x1f, 0x20, 0x21, 0xa1, 0x22, 0x23, 0x24
              .byte   0xa4, 0x25, 0x26, 0x27, 0xa7, 0x28, 0x29, 0x2a, 0xaa, 0x2b, 0x2c, 0x2d, 0xad, 0x2e, 0x2f, 0x30
              .byte   0xb0, 0x31, 0x32, 0x33, 0xb3, 0x34, 0x35, 0x36, 0xb6, 0x37, 0x38, 0x39, 0xb9, 0x3a, 0x3b, 0x3c
              .byte   0xbc, 0x3d, 0x3e, 0x3f, 0xbf, 0x40, 0x41, 0x42, 0xc2, 0x43, 0x44, 0x45, 0xc5, 0x46, 0x47, 0x48
              .byte   0xc8, 0x49, 0x4a, 0x4b, 0xcb, 0x4c, 0x4d, 0x4e, 0xce, 0x4f, 0x50, 0x51, 0xd1, 0x52, 0x53, 0x54
              .byte   0xd4, 0x55, 0x56, 0x57, 0xd7, 0x58, 0x59, 0x5a, 0xda, 0x5b, 0x5c, 0x5d, 0xdd, 0x5e, 0x5f, 0x60
              .byte   0xe0, 0x61, 0x62, 0x63, 0xe3, 0x64, 0x65, 0x66, 0xe6, 0x67, 0x68, 0x69, 0xe9, 0x6a, 0x6b, 0x6c
              .byte   0xec, 0x6d, 0x6e, 0x6f, 0xef, 0x70, 0x71, 0x72, 0xf2, 0x73, 0x74, 0x75, 0xf5, 0x76, 0x77, 0x78
              .byte   0xf8, 0x79, 0x7a, 0x7b, 0xfb, 0x7c, 0x7d, 0x7e, 0xfe
U_PAGE2:
              .byte   0xa5, 0x00, 0x06, 0x00, 0x07, 0x00, 0x67, 0x80, 0xa4, 0x00, 0x08, 0x00, 0x26, 0x00, 0x68, 0x80
              .byte   0xa3, 0x00, 0x27, 0x00, 0x28, 0x00, 0x69, 0x80, 0xa2, 0x00, 0x29, 0x00, 0x2a, 0x00, 0x6a, 0x80
              .byte   0xa1, 0x00, 0x2b, 0x00, 0x2c, 0x00, 0x6b, 0x80, 0xa0, 0x00, 0x2d, 0x00, 0x2e, 0x00, 0x6c, 0x80
              .byte   0x25, 0x00, 0x2f, 0x00, 0x3e, 0x00, 0x6d, 0x80, 0x24, 0x00, 0x3f, 0x00, 0x46, 0x00, 0x6e, 0x80
              .byte   0x23, 0x00, 0x47, 0x00, 0x48, 0x00, 0x6f, 0x80, 0x22, 0x00, 0x49, 0x00, 0x4a, 0x00, 0x70, 0x80
              .byte   0x21, 0x00, 0x4b, 0x00, 0x4c, 0x00, 0x71, 0x80, 0x20, 0x00, 0x4d, 0x00, 0x4e, 0x00, 0x72, 0x80
              .byte   0xc5, 0x00, 0x4f, 0x00, 0x50, 0x00, 0x73, 0x80, 0xc4, 0x00, 0x51, 0x00, 0x52, 0x00, 0x74, 0x80
              .byte   0xc3, 0x00, 0x53, 0x00, 0x54, 0x00, 0x75, 0x80, 0xc2, 0x00, 0x55, 0x00, 0x56, 0x00, 0x76, 0x80
              .byte   0xc1, 0x00, 0x57, 0x00, 0x58, 0x00, 0x77, 0x80, 0xc0, 0x00, 0x59, 0x00, 0x5a, 0x00, 0x78, 0x80
              .byte   0xbd, 0x00, 0x5b, 0x00, 0x5c, 0x00, 0x79, 0x80, 0xbc, 0x00, 0x5d, 0x00, 0x5e, 0x00, 0x7a, 0x80
              .byte   0xbb, 0x00, 0x5f, 0x00, 0x60, 0x00, 0x7b, 0x80, 0xba, 0x00, 0x61, 0x00, 0x62, 0x00, 0x7c, 0x80
              .byte   0xb9, 0x00, 0x63, 0x00, 0x64, 0x00, 0x7d, 0x80, 0xb8, 0x00, 0x65, 0x00, 0x66, 0x00, 0x7e, 0x80
              .byte   0xb7, 0x00, 0xb6, 0x00, 0xb5, 0x00, 0x7f, 0x80, 0xb4, 0x00, 0xb3, 0x00, 0xb2, 0x00, 0x80, 0x80
              .byte   0xb1, 0x00, 0xb0, 0x00, 0x45, 0x00, 0x81, 0x80, 0x44, 0x00, 0x43, 0x00, 0x42, 0x00, 0x82, 0x80
              .byte   0x41, 0x00, 0x40, 0x00, 0x3d, 0x00, 0x83, 0x80, 0x3c, 0x00, 0x3b, 0x00, 0x3a, 0x00, 0x84, 0x80
              .byte   0xa6, 0x00, 0xa7, 0x00, 0x39, 0x00, 0x85, 0x80, 0xa8, 0x00, 0xa9, 0x00, 0x38, 0x00, 0x86, 0x80
              .byte   0xaa, 0x00, 0xab, 0x00, 0x37, 0x00, 0x87, 0x80, 0xac, 0x00, 0xad, 0x00, 0x36, 0x00, 0x88, 0x80
              .byte   0xae, 0x00, 0xaf, 0x00, 0x35, 0x00, 0x01, 0x80, 0xbe, 0x00, 0xbf, 0x00, 0x34, 0x00, 0x02, 0x80
              .byte   0xc6, 0x00, 0xc7, 0x00, 0x33, 0x00, 0x03, 0x80, 0xc8, 0x00, 0xc9, 0x00, 0x32, 0x00, 0x00, 0x80
              .byte   0xca, 0x00, 0xcb, 0x00, 0x31, 0x00, 0x04, 0x80, 0xcc, 0x00, 0xcd, 0x00, 0x30, 0x00, 0x05, 0x80
uMid:       lda     long:U_PAGE2,x
              bmi     uSkip16
              cpx     dp:W_TCX
              beq     1$
              jmp     long:(drawMid+4)
1$:           jmp     long:(drawMid+7)
uTop:       lda     long:U_PAGE2,x
              bmi     uSkip16
              cpx     dp:W_TCX
              beq     1$
              jmp     long:(drawTop+4)
1$:           jmp     long:(drawTop+7)
uBot:       lda     long:U_PAGE2,x
              bmi     uSkip16
              cpx     dp:W_TCX
              beq     1$
              jmp     long:(drawBot+4)
1$:           jmp     long:(drawBot+7)
uSkip16:    sep     #0x20
              jmp     long:oneSkip
uCeil:      lda     long:(U_PAGE2+1),x
              bne     uSkip16
              lda     dp:W_SKY
              beq     1$
              jmp     long:ceilSky
1$:           jmp     long:(ceilFill+4)
uFloor:     lda     long:(U_PAGE2+1),x
              bne     uSkip16
              lda     dp:W_FCR
              cmp     dp:W_BOTR
              jmp     long:(floorFill+4)


              .section fourimg, text
texImgU:      xba
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x2d20,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x2dc0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x2e60,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x2f00,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x2fa0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x3040,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x30e0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x3180,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x3220,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x32c0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x3360,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x3400,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x34a0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x3540,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x35e0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x3680,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x3720,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x37c0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x3860,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x3900,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x39a0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x3a40,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x3ae0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x3b80,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x3c20,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x3cc0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x3d60,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x3e00,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x3ea0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x3f40,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x3fe0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x4080,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x4120,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x41c0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x4260,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x4300,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x43a0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x4440,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x44e0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x4580,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x4620,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x46c0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x4760,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x4800,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x48a0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x4940,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x49e0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x4a80,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x4b20,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x4bc0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x4c60,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x4d00,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x4da0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x4e40,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x4ee0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x4f80,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x5020,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x50c0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x5160,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x5200,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x52a0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x5340,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x53e0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x5480,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x5520,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x55c0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x5660,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x5700,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x57a0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x5840,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x58e0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x5980,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x5a20,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x5ac0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x5b60,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x5c00,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x5ca0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x5d40,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x5de0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x5e80,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x5f20,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x5fc0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x6060,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x6100,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x61a0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x6240,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x62e0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x6380,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x6420,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x64c0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x6560,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x6600,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x66a0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x6740,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x67e0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x6880,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x6920,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x69c0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x6a60,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x6b00,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x6ba0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x6c40,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x6ce0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x6d80,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x6e20,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x6ec0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x6f60,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x7000,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x70a0,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x7140,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x71e0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x7280,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x7320,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x73c0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x7460,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x7500,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x75a0,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x7640,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x76e0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x7780,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x7820,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x78c0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x7960,x
              tya
              adc     dp:.tiny (DC_SI+1)
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x7a00,x
              xba
              adc     dp:.tiny (DC_SF+1)
              xba
              tya
              adc     dp:.tiny DC_ROW
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMB
              lda     [.tiny DC_CMB]
              sta     abs:0x7aa0,x
              xba
              adc     dp:.tiny DC_SF
              xba
              tya
              adc     dp:.tiny DC_SI
              and     #0x7f
              tay
              lda     [.tiny DC_SRC],y
              sta     dp:.tiny DC_CMA
              lda     [.tiny DC_CMA]
              sta     abs:0x7b40,x
              tya
              .byte   0x65, .tiny (DC_SI+1)

;;; Templates and view-change code fit after the 3/4 row image. Copied
;;; helpers use only relative branches and the direct-page entry vector.
nrHStart:     lda     dp:.tiny RL_HA
              lsr     a
              lda     dp:.tiny RL_HP
              xba
              lda     dp:.tiny (RL_HP+1)
              bcs     nrHReady
              xba
              sec
              sbc     dp:.tiny RL_HS
              xba
              sbc     dp:.tiny (RL_HS+1)
nrHReady:    and     #0x7f
              tay
              lda     dp:.tiny DC_SF
              asl     a
              sta     dp:.tiny (DC_SF+1)
              lda     dp:.tiny DC_SI
              adc     #0
              and     #0x7f
              sta     dp:.tiny (DC_SI+1)
              lda     dp:.tiny RL_TENT
              lsr     a
              bcs     nrHEnter
              xba
              sec
              sbc     dp:.tiny DC_SF
              xba
              tya
              sbc     #0
              bit     dp:.tiny DC_SF
              bpl     nrHRound
              inc     a
nrHRound:    and     #0x7f
              tay
nrHEnter:    lda     #0x6c
              sta     [.tiny RL_XO]
              ldx     dp:.tiny RL_C
              sep     #0x10
              clc
              .byte   0x6c
              .word   .word0 RL_TENT

nrHEnd:

nrTStart:
              tay
              lda     dp:.tiny DC_SF
              asl     a
              sta     dp:.tiny SP_AF
              lda     dp:.tiny DC_SI
              rol     a
              and     #0x7f
              sta     dp:.tiny SP_AI
              lda     dp:.tiny SP_AF
              clc
              adc     dp:.tiny DC_SF
              sta     dp:.tiny (DC_SF+1)
              lda     dp:.tiny DC_SI
              adc     #0
              bit     dp:.tiny SP_AF
              bpl     nrTSecond
              dec     a
nrTSecond: and     #0x7f
              sta     dp:.tiny SP_SECOND
              lda     dp:.tiny SP_AF
              asl     a
              lda     dp:.tiny SP_AI
              adc     #0
              and     #0x7f
              sta     dp:.tiny (DC_SI+1)
              lda     dp:.tiny RL_TENT
              lsr     a
              bcc     nrTOdd
              bra     nrTEnter
nrTOdd:
              xba
              sec
              sbc     dp:.tiny SP_AF
              xba
              tya
              sbc     #0
              bit     dp:.tiny SP_AF
              bpl     nrTRound
              inc     a
nrTRound:  and     #0x7f
              tay
nrTEnter:
              lda     #0x6c
              sta     [.tiny RL_XO]
              ldx     dp:.tiny RL_C
              sep     #0x10
              clc
              .byte   0x6c
              .word   .word0 RL_TENT
nrTEnd:

nrUStart:
              tay
              lda     dp:.tiny DC_SF
              asl     a
              sta     dp:.tiny SP_AF
              lda     dp:.tiny DC_SI
              rol     a
              and     #0x7f
              sta     dp:.tiny SP_AI
              lda     dp:.tiny SP_AF
              clc
              adc     dp:.tiny DC_SF
              sta     dp:.tiny (DC_SF+1)
              lda     dp:.tiny DC_SI
              adc     #0
              bit     dp:.tiny SP_AF
              bpl     nrUSecond
              dec     a
nrUSecond: and     #0x7f
              sta     dp:.tiny SP_SECOND
              lda     dp:.tiny SP_AF
              asl     a
              lda     dp:.tiny SP_AI
              adc     #0
              and     #0x7f
              sta     dp:.tiny (DC_SI+1)
              lda     dp:.tiny RL_HA
              and     #3
              cmp     #1
              beq     nrUOdd
              bra     nrUEnter
nrUOdd:
              xba
              sec
              sbc     dp:.tiny SP_AF
              xba
              tya
              sbc     #0
              bit     dp:.tiny SP_AF
              bpl     nrURound
              inc     a
nrURound:  and     #0x7f
              tay
nrUEnter:
              lda     #0x6c
              sta     [.tiny RL_XO]
              ldx     dp:.tiny RL_C
              sep     #0x10
              clc
              .byte   0x6c
              .word   .word0 RL_TENT
nrUEnd:

nrHSet:       ldx     ##.word0 nrHStart
              ldy     ##.word0 (texBlocks+0x1)
              lda     ##(nrHEnd-nrHStart-1)
              .byte   0x54, .byte2 texBlocks, .byte2 nrHStart
              sep     #0x20
              lda     #BUF_BANK
              pha
              plb
              lda     #0
              xba
              lda     #0
              ldx     ##0
nrHMap:
              txa
              inc     a
              lsr     a
              clc
              adc     #HV_ROW0
              tay
              lda     abs:TEXLO,y
              sta     long:(texBlocks+0x100),x
              lda     abs:TEXHI,y
              sta     long:(texBlocks+0x200),x
              inx
              cpx     ##169
              bcc     nrHMap
              rep     #0x20
              plb
              rtl

nrTSet:       ldx     ##.word0 nrTStart
              ldy     ##.word0 (texBlocks+0x910)
              lda     ##(nrTEnd-nrTStart-1)
              .byte   0x54, .byte2 texBlocks, .byte2 nrTStart
              sep     #0x20
              lda     #BUF_BANK
              pha
              plb
              lda     #0
              xba
              lda     #0
              ldx     ##0
nrTMap:
              lda     long:T_ROWK,x
              pha
              and     #0x7f
              tay
              lda     abs:TEXLO,y
              sta     long:(texBlocks+0x780),x
              pla
              and     #0x80
              sta     dp:.tiny SP_AF
              lda     abs:TEXHI,y
              ora     dp:.tiny SP_AF
              sta     long:(texBlocks+0x840),x
              inx
              cpx     ##169
              bcc     nrTMap
              rep     #0x20
              plb
              plp
              rtl

nrUSet:       ldx     ##.word0 nrUStart
              ldy     ##.word0 (texBlocks+0xa30)
              lda     ##(nrUEnd-nrUStart-1)
              .byte   0x54, .byte2 texBlocks, .byte2 nrUStart
              sep     #0x20
              lda     #BUF_BANK
              pha
              plb
              lda     #0
              xba
              lda     #0
              ldx     ##0
nrUMap:
              lda     long:U_ROWK,x
              pha
              and     #0x7f
              tay
              lda     abs:TEXLO,y
              sta     long:(texBlocks+0x8c0),x
              pla
              and     #0x80
              sta     dp:.tiny SP_AF
              lda     abs:TEXHI,y
              ora     dp:.tiny SP_AF
              sta     long:(texBlocks+0x980),x
              inx
              cpx     ##169
              bcc     nrUMap
              rep     #0x20
              plb
              plp
              rtl
              .space  2733 - (. - texImgU)
UFLATOFS .equ . - texImgU
UIMGSIZE .equ . - texImgU
UFLAT_ADDR: .word .word0 (flatBlocks + 21*4)
UEntryLo:
              .byte .byte0 (texBlocks + 1)
              .byte .byte0 (texBlocks + 16)
              .byte .byte0 (texBlocks + 35)
              .byte .byte0 (texBlocks + 54)
              .byte .byte0 (texBlocks + 69)
              .byte .byte0 (texBlocks + 88)
              .byte .byte0 (texBlocks + 107)
              .byte .byte0 (texBlocks + 122)
              .byte .byte0 (texBlocks + 141)
              .byte .byte0 (texBlocks + 160)
              .byte .byte0 (texBlocks + 175)
              .byte .byte0 (texBlocks + 194)
              .byte .byte0 (texBlocks + 213)
              .byte .byte0 (texBlocks + 228)
              .byte .byte0 (texBlocks + 247)
              .byte .byte0 (texBlocks + 266)
              .byte .byte0 (texBlocks + 281)
              .byte .byte0 (texBlocks + 300)
              .byte .byte0 (texBlocks + 319)
              .byte .byte0 (texBlocks + 334)
              .byte .byte0 (texBlocks + 353)
              .byte .byte0 (texBlocks + 372)
              .byte .byte0 (texBlocks + 387)
              .byte .byte0 (texBlocks + 406)
              .byte .byte0 (texBlocks + 425)
              .byte .byte0 (texBlocks + 440)
              .byte .byte0 (texBlocks + 459)
              .byte .byte0 (texBlocks + 478)
              .byte .byte0 (texBlocks + 493)
              .byte .byte0 (texBlocks + 512)
              .byte .byte0 (texBlocks + 531)
              .byte .byte0 (texBlocks + 546)
              .byte .byte0 (texBlocks + 565)
              .byte .byte0 (texBlocks + 584)
              .byte .byte0 (texBlocks + 599)
              .byte .byte0 (texBlocks + 618)
              .byte .byte0 (texBlocks + 637)
              .byte .byte0 (texBlocks + 652)
              .byte .byte0 (texBlocks + 671)
              .byte .byte0 (texBlocks + 690)
              .byte .byte0 (texBlocks + 705)
              .byte .byte0 (texBlocks + 724)
              .byte .byte0 (texBlocks + 743)
              .byte .byte0 (texBlocks + 758)
              .byte .byte0 (texBlocks + 777)
              .byte .byte0 (texBlocks + 796)
              .byte .byte0 (texBlocks + 811)
              .byte .byte0 (texBlocks + 830)
              .byte .byte0 (texBlocks + 849)
              .byte .byte0 (texBlocks + 864)
              .byte .byte0 (texBlocks + 883)
              .byte .byte0 (texBlocks + 902)
              .byte .byte0 (texBlocks + 917)
              .byte .byte0 (texBlocks + 936)
              .byte .byte0 (texBlocks + 955)
              .byte .byte0 (texBlocks + 970)
              .byte .byte0 (texBlocks + 989)
              .byte .byte0 (texBlocks + 1008)
              .byte .byte0 (texBlocks + 1023)
              .byte .byte0 (texBlocks + 1042)
              .byte .byte0 (texBlocks + 1061)
              .byte .byte0 (texBlocks + 1076)
              .byte .byte0 (texBlocks + 1095)
              .byte .byte0 (texBlocks + 1114)
              .byte .byte0 (texBlocks + 1129)
              .byte .byte0 (texBlocks + 1148)
              .byte .byte0 (texBlocks + 1167)
              .byte .byte0 (texBlocks + 1182)
              .byte .byte0 (texBlocks + 1201)
              .byte .byte0 (texBlocks + 1220)
              .byte .byte0 (texBlocks + 1235)
              .byte .byte0 (texBlocks + 1254)
              .byte .byte0 (texBlocks + 1273)
              .byte .byte0 (texBlocks + 1288)
              .byte .byte0 (texBlocks + 1307)
              .byte .byte0 (texBlocks + 1326)
              .byte .byte0 (texBlocks + 1341)
              .byte .byte0 (texBlocks + 1360)
              .byte .byte0 (texBlocks + 1379)
              .byte .byte0 (texBlocks + 1394)
              .byte .byte0 (texBlocks + 1413)
              .byte .byte0 (texBlocks + 1432)
              .byte .byte0 (texBlocks + 1447)
              .byte .byte0 (texBlocks + 1466)
              .byte .byte0 (texBlocks + 1485)
              .byte .byte0 (texBlocks + 1500)
              .byte .byte0 (texBlocks + 1519)
              .byte .byte0 (texBlocks + 1538)
              .byte .byte0 (texBlocks + 1553)
              .byte .byte0 (texBlocks + 1572)
              .byte .byte0 (texBlocks + 1591)
              .byte .byte0 (texBlocks + 1606)
              .byte .byte0 (texBlocks + 1625)
              .byte .byte0 (texBlocks + 1644)
              .byte .byte0 (texBlocks + 1659)
              .byte .byte0 (texBlocks + 1678)
              .byte .byte0 (texBlocks + 1697)
              .byte .byte0 (texBlocks + 1712)
              .byte .byte0 (texBlocks + 1731)
              .byte .byte0 (texBlocks + 1750)
              .byte .byte0 (texBlocks + 1765)
              .byte .byte0 (texBlocks + 1784)
              .byte .byte0 (texBlocks + 1803)
              .byte .byte0 (texBlocks + 1818)
              .byte .byte0 (texBlocks + 1837)
              .byte .byte0 (texBlocks + 1856)
              .byte .byte0 (texBlocks + 1871)
              .byte .byte0 (texBlocks + 1890)
              .byte .byte0 (texBlocks + 1909)
              .byte .byte0 (texBlocks + 1924)
              .byte .byte0 (texBlocks + 1943)
              .byte .byte0 (texBlocks + 1962)
              .byte .byte0 (texBlocks + 1977)
              .byte .byte0 (texBlocks + 1996)
              .byte .byte0 (texBlocks + 2015)
              .byte .byte0 (texBlocks + 2030)
              .byte .byte0 (texBlocks + 2049)
              .byte .byte0 (texBlocks + 2068)
              .byte .byte0 (texBlocks + 2083)
              .byte .byte0 (texBlocks + 2102)
              .byte .byte0 (texBlocks + 2121)
              .byte .byte0 (texBlocks + 2136)
              .byte .byte0 (texBlocks + 2155)
              .byte .byte0 (texBlocks + 2174)
              .byte .byte0 (texBlocks + 2189)
              .byte .byte0 (texBlocks + 2208)
              .byte .byte0 (texBlocks + 2227)
UEntryHi:
              .byte .byte1 (texBlocks + 1)
              .byte .byte1 (texBlocks + 16)
              .byte .byte1 (texBlocks + 35)
              .byte .byte1 (texBlocks + 54)
              .byte .byte1 (texBlocks + 69)
              .byte .byte1 (texBlocks + 88)
              .byte .byte1 (texBlocks + 107)
              .byte .byte1 (texBlocks + 122)
              .byte .byte1 (texBlocks + 141)
              .byte .byte1 (texBlocks + 160)
              .byte .byte1 (texBlocks + 175)
              .byte .byte1 (texBlocks + 194)
              .byte .byte1 (texBlocks + 213)
              .byte .byte1 (texBlocks + 228)
              .byte .byte1 (texBlocks + 247)
              .byte .byte1 (texBlocks + 266)
              .byte .byte1 (texBlocks + 281)
              .byte .byte1 (texBlocks + 300)
              .byte .byte1 (texBlocks + 319)
              .byte .byte1 (texBlocks + 334)
              .byte .byte1 (texBlocks + 353)
              .byte .byte1 (texBlocks + 372)
              .byte .byte1 (texBlocks + 387)
              .byte .byte1 (texBlocks + 406)
              .byte .byte1 (texBlocks + 425)
              .byte .byte1 (texBlocks + 440)
              .byte .byte1 (texBlocks + 459)
              .byte .byte1 (texBlocks + 478)
              .byte .byte1 (texBlocks + 493)
              .byte .byte1 (texBlocks + 512)
              .byte .byte1 (texBlocks + 531)
              .byte .byte1 (texBlocks + 546)
              .byte .byte1 (texBlocks + 565)
              .byte .byte1 (texBlocks + 584)
              .byte .byte1 (texBlocks + 599)
              .byte .byte1 (texBlocks + 618)
              .byte .byte1 (texBlocks + 637)
              .byte .byte1 (texBlocks + 652)
              .byte .byte1 (texBlocks + 671)
              .byte .byte1 (texBlocks + 690)
              .byte .byte1 (texBlocks + 705)
              .byte .byte1 (texBlocks + 724)
              .byte .byte1 (texBlocks + 743)
              .byte .byte1 (texBlocks + 758)
              .byte .byte1 (texBlocks + 777)
              .byte .byte1 (texBlocks + 796)
              .byte .byte1 (texBlocks + 811)
              .byte .byte1 (texBlocks + 830)
              .byte .byte1 (texBlocks + 849)
              .byte .byte1 (texBlocks + 864)
              .byte .byte1 (texBlocks + 883)
              .byte .byte1 (texBlocks + 902)
              .byte .byte1 (texBlocks + 917)
              .byte .byte1 (texBlocks + 936)
              .byte .byte1 (texBlocks + 955)
              .byte .byte1 (texBlocks + 970)
              .byte .byte1 (texBlocks + 989)
              .byte .byte1 (texBlocks + 1008)
              .byte .byte1 (texBlocks + 1023)
              .byte .byte1 (texBlocks + 1042)
              .byte .byte1 (texBlocks + 1061)
              .byte .byte1 (texBlocks + 1076)
              .byte .byte1 (texBlocks + 1095)
              .byte .byte1 (texBlocks + 1114)
              .byte .byte1 (texBlocks + 1129)
              .byte .byte1 (texBlocks + 1148)
              .byte .byte1 (texBlocks + 1167)
              .byte .byte1 (texBlocks + 1182)
              .byte .byte1 (texBlocks + 1201)
              .byte .byte1 (texBlocks + 1220)
              .byte .byte1 (texBlocks + 1235)
              .byte .byte1 (texBlocks + 1254)
              .byte .byte1 (texBlocks + 1273)
              .byte .byte1 (texBlocks + 1288)
              .byte .byte1 (texBlocks + 1307)
              .byte .byte1 (texBlocks + 1326)
              .byte .byte1 (texBlocks + 1341)
              .byte .byte1 (texBlocks + 1360)
              .byte .byte1 (texBlocks + 1379)
              .byte .byte1 (texBlocks + 1394)
              .byte .byte1 (texBlocks + 1413)
              .byte .byte1 (texBlocks + 1432)
              .byte .byte1 (texBlocks + 1447)
              .byte .byte1 (texBlocks + 1466)
              .byte .byte1 (texBlocks + 1485)
              .byte .byte1 (texBlocks + 1500)
              .byte .byte1 (texBlocks + 1519)
              .byte .byte1 (texBlocks + 1538)
              .byte .byte1 (texBlocks + 1553)
              .byte .byte1 (texBlocks + 1572)
              .byte .byte1 (texBlocks + 1591)
              .byte .byte1 (texBlocks + 1606)
              .byte .byte1 (texBlocks + 1625)
              .byte .byte1 (texBlocks + 1644)
              .byte .byte1 (texBlocks + 1659)
              .byte .byte1 (texBlocks + 1678)
              .byte .byte1 (texBlocks + 1697)
              .byte .byte1 (texBlocks + 1712)
              .byte .byte1 (texBlocks + 1731)
              .byte .byte1 (texBlocks + 1750)
              .byte .byte1 (texBlocks + 1765)
              .byte .byte1 (texBlocks + 1784)
              .byte .byte1 (texBlocks + 1803)
              .byte .byte1 (texBlocks + 1818)
              .byte .byte1 (texBlocks + 1837)
              .byte .byte1 (texBlocks + 1856)
              .byte .byte1 (texBlocks + 1871)
              .byte .byte1 (texBlocks + 1890)
              .byte .byte1 (texBlocks + 1909)
              .byte .byte1 (texBlocks + 1924)
              .byte .byte1 (texBlocks + 1943)
              .byte .byte1 (texBlocks + 1962)
              .byte .byte1 (texBlocks + 1977)
              .byte .byte1 (texBlocks + 1996)
              .byte .byte1 (texBlocks + 2015)
              .byte .byte1 (texBlocks + 2030)
              .byte .byte1 (texBlocks + 2049)
              .byte .byte1 (texBlocks + 2068)
              .byte .byte1 (texBlocks + 2083)
              .byte .byte1 (texBlocks + 2102)
              .byte .byte1 (texBlocks + 2121)
              .byte .byte1 (texBlocks + 2136)
              .byte .byte1 (texBlocks + 2155)
              .byte .byte1 (texBlocks + 2174)
              .byte .byte1 (texBlocks + 2189)
              .byte .byte1 (texBlocks + 2208)
              .byte .byte1 (texBlocks + 2227)

              .section onecold, text
uSet:         php
              rep     #0x30
              phb
              lda     ##8
              sta     long:RL_DETI
              ldx     ##.word0 texImgU
              ldy     ##.word0 texBlocks
              lda     ##(UIMGSIZE-1)
              .byte 0x54, .byte2 texBlocks, .byte2 texImgU
              ldx     ##.word0 UEntryLo
              ldy     ##TEXLO
              lda     ##126
              .byte 0x54, BUF_BANK, .byte2 UEntryLo
              ldx     ##.word0 UEntryHi
              ldy     ##TEXHI
              lda     ##126
              .byte 0x54, BUF_BANK, .byte2 UEntryHi
              jmp     .kbank nrUSet
              .extern pixQuarter, quarterOvlRow, pixThreequarter, threequarterOvlRow

;;; Full-view row pairs use two text-page exit words during replay only.
;;; The first operand byte is ADC's opcode, so these words end in $65.
              .section paircode, text
pairBegin:    lda     long:0x000565
              pha
              lda     long:0x000765
              pha
              lda     ##.word0 texContinue
              sta     long:0x000565
              lda     ##.word0 pairContinueShort
              sta     long:0x000765
              brl     pairBeginDone
pairEnd:      pla
              sta     long:0x000765
              pla
              sta     long:0x000565
              brl     pairEndDone

;;; Mode $0100 is the full-view pair image; 0 is a constant-step window.
;;; Keep texBlocks[0] for the flat drawer; full-view rows start at +1.
pairSetDetail:
              sta     long:RL_DETI
              phb
              ldx     ##.word0 texImgH
              ldy     ##.word0 texBlocks
              lda     ##(TEXIMG_SIZE - 1)
              .byte   0x54, .byte2 texBlocks, .byte2 texImgH
              ldx     ##.word0 texEntryLo
              ldy     ##TEXLO
              lda     ##(2 * (CONST_VIEWHEIGHT + 1) - 1)
              .byte   0x54, BUF_BANK, .byte2 texEntryLo
              lda     long:RL_DETI
              cmp     ##0x0100
              beq     pairMake
              brl     spSelect
pairMake:
              sep     #0x20
              lda     #.byte2 texBlocks
              pha
              plb
              ldx     ##0
              ldy     ##1
pairPatch:
              lda     long:(texImgH+4),x
              sta     abs:.word0 (texBlocks+0),y
              lda     long:(texImgH+5),x
              sta     abs:.word0 (texBlocks+1),y
              lda     long:(texImgH+6),x
              sta     abs:.word0 (texBlocks+2),y
              lda     long:(texImgH+7),x
              sta     abs:.word0 (texBlocks+3),y
              lda     long:(texImgH+8),x
              sta     abs:.word0 (texBlocks+4),y
              lda     long:(texImgH+9),x
              sta     abs:.word0 (texBlocks+5),y
              lda     long:(texImgH+10),x
              sta     abs:.word0 (texBlocks+6),y
              lda     long:(texImgH+11),x
              sta     abs:.word0 (texBlocks+7),y
              lda     long:(texImgH+12),x
              sta     abs:.word0 (texBlocks+8),y
              lda     long:(texImgH+13),x
              sta     abs:.word0 (texBlocks+9),y
              lda     long:(texImgH+14),x
              sta     abs:.word0 (texBlocks+10),y
              lda     long:(texImgH+15),x
              sta     abs:.word0 (texBlocks+11),y
              lda     long:(texImgH+16),x
              sta     abs:.word0 (texBlocks+12),y
              lda     long:(texImgH+17),x
              sta     abs:.word0 (texBlocks+13),y
              lda     long:(texImgH+18),x
              sta     abs:.word0 (texBlocks+14),y
              lda     #.tiny (DC_SI+1)
              sta     abs:.word0 (texBlocks+2),y
              lda     long:(texImgH+19),x
              sta     abs:.word0 (texBlocks+15),y
              lda     long:(texImgH+20),x
              sta     abs:.word0 (texBlocks+16),y
              lda     long:(texImgH+21),x
              sta     abs:.word0 (texBlocks+17),y
              lda     long:(texImgH+22),x
              sta     abs:.word0 (texBlocks+18),y
              lda     long:(texImgH+23),x
              sta     abs:.word0 (texBlocks+19),y
              lda     long:(texImgH+24),x
              sta     abs:.word0 (texBlocks+20),y
              lda     long:(texImgH+25),x
              sta     abs:.word0 (texBlocks+21),y
              lda     long:(texImgH+26),x
              sta     abs:.word0 (texBlocks+22),y
              lda     long:(texImgH+27),x
              sta     abs:.word0 (texBlocks+23),y
              lda     long:(texImgH+28),x
              sta     abs:.word0 (texBlocks+24),y
              lda     long:(texImgH+29),x
              sta     abs:.word0 (texBlocks+25),y
              lda     long:(texImgH+30),x
              sta     abs:.word0 (texBlocks+26),y
              lda     long:(texImgH+31),x
              sta     abs:.word0 (texBlocks+27),y
              lda     long:(texImgH+32),x
              sta     abs:.word0 (texBlocks+28),y
              lda     long:(texImgH+33),x
              sta     abs:.word0 (texBlocks+29),y
              lda     long:(texImgH+34),x
              sta     abs:.word0 (texBlocks+30),y
              lda     long:(texImgH+35),x
              sta     abs:.word0 (texBlocks+31),y
              lda     long:(texImgH+36),x
              sta     abs:.word0 (texBlocks+32),y
              lda     long:(texImgH+37),x
              sta     abs:.word0 (texBlocks+33),y
              lda     #.tiny (DC_SF+1)
              sta     abs:.word0 (texBlocks+17),y
              rep     #0x20
              txa
              clc
              adc     ##38
              tax
              tya
              clc
              adc     ##34
              tay
              sep     #0x20
              cpx     ##(168*19)
              bcc     pairPatchMore
              bra     pairPatchDone
pairPatchMore: brl     pairPatch
pairPatchDone:
              lda     #0x98
              sta     abs:.word0 texBlocks,y
              lda     #0x65
              sta     abs:.word0 (texBlocks+1),y
              lda     #.tiny (DC_SI+1)
              sta     abs:.word0 (texBlocks+2),y
              rep     #0x20
              ldx     ##0
              ldy     ##.word0 (texBlocks+1)
pairEntries:  tya
              sep     #0x20
              sta     long:(0x010000+TEXLO),x
              xba
              sta     long:(0x010000+TEXHI),x
              rep     #0x20
              inx
              txa
              and     ##1
              beq     pairAdd19
              tya
              clc
              adc     ##15
              bra     pairAdded
pairAdd19:    tya
              clc
              adc     ##19
pairAdded:    tay
              cpx     ##169
              bcc     pairEntries
pairCopied:   brl     nrCopy


;;; Mode zero pairs the rows of the half, third and quarter windows.
spSelect:     brl     pairMake

;;; In: adjusted TI in A, pre-row fraction in RL_HP. SF/SI are already
;;; scaled to the window; their spare high bytes hold the paired steps.
spConstTail:  tay
              lda     dp:.tiny DC_SF
              asl     a
              sta     dp:.tiny (DC_SF+1)
              lda     dp:.tiny DC_SI
              adc     #0
              and     #0x7f
              sta     dp:.tiny (DC_SI+1)
              lda     dp:.tiny RL_TENT
              lsr     a
              bcs     spEvenStart
              lda     dp:.tiny RL_HP
              sec
              sbc     dp:.tiny DC_SF
              xba
              tya
              sbc     #0
              bit     dp:.tiny DC_SF
              bpl     spConstRound
              inc     a
spConstRound: and     #0x7f
              tay
              bra     spEnter
spEvenStart:  lda     dp:.tiny RL_HP
              xba
spEnter:      lda     #0x6c
              sta     [.tiny RL_XO]
              ldx     dp:.tiny RL_C
              sep     #0x10
              clc
              .byte   0x6c
              .word   .word0 RL_TENT

SP_AF         .equ    DC_COUNT
SP_AI         .equ    DC_COUNT+1
SP_SECOND     .equ    DC_ROW

spBeginH:
              lda     long:0x000565
              pha
              lda     long:0x000765
              pha
              lda     ##.word0 halfCont
              sta     long:0x000565
              lda     ##.word0 spShortH
              sta     long:0x000765
              brl     spBeginDoneH
spEndH:
              pla
              sta     long:0x000765
              pla
              sta     long:0x000565
              brl     spEndDoneH
spShortH:    rep     #0x10
              lda     #0x98
              brl     halfCont+4

spBeginT:
              lda     long:0x000565
              pha
              lda     long:0x000765
              pha
              lda     ##.word0 tCont
              sta     long:0x000565
              lda     ##.word0 spShortT
              sta     long:0x000765
              brl     spBeginDoneT
spEndT:
              pla
              sta     long:0x000765
              pla
              sta     long:0x000565
              brl     spEndDoneT
spShortT:    rep     #0x10
              lda     #0x98
              brl     tCont+4

spBeginO:
              lda     long:0x000565
              pha
              lda     long:0x000765
              pha
              lda     ##.word0 oneCont
              sta     long:0x000565
              lda     ##.word0 spShortO
              sta     long:0x000765
              brl     spBeginDoneO
spEndO:
              pla
              sta     long:0x000765
              pla
              sta     long:0x000565
              brl     spEndDoneO
spShortO:    rep     #0x10
              lda     #0x98
              brl     oneCont+4

spBeginQ:
              lda     long:0x000565
              pha
              lda     long:0x000765
              pha
              lda     ##.word0 qCont
              sta     long:0x000565
              lda     ##.word0 spShortQ
              sta     long:0x000765
              brl     spBeginDoneQ
spEndQ:
              pla
              sta     long:0x000765
              pla
              sta     long:0x000565
              brl     spEndDoneQ
spShortQ:    rep     #0x10
              lda     #0x98
              brl     qCont+4

spBeginU:
              lda     long:0x000465
              pha
              lda     long:0x000565
              pha
              lda     long:0x000765
              pha
              lda     ##.word0 uCont
              sta     long:0x000465
              lda     ##.word0 uCont
              sta     long:0x000565
              lda     ##.word0 spShortU
              sta     long:0x000765
              brl     spBeginDoneU
spEndU:
              pla
              sta     long:0x000765
              pla
              sta     long:0x000565
              pla
              sta     long:0x000465
              brl     spEndDoneU
spShortU:    rep     #0x10
              lda     #0x98
              brl     uCont+4


;;; The 2S,S pair ends exactly at 3S. Its first row rounds 2S; the
;;; remaining integer part and carry are applied by its second row.
spTailT:
              tay
              lda     dp:.tiny DC_SF
              asl     a
              sta     dp:.tiny SP_AF
              lda     dp:.tiny DC_SI
              rol     a
              and     #0x7f
              sta     dp:.tiny SP_AI
              lda     dp:.tiny SP_AF
              clc
              adc     dp:.tiny DC_SF
              sta     dp:.tiny (DC_SF+1)
              lda     dp:.tiny DC_SI
              adc     #0
              bit     dp:.tiny SP_AF
              bpl     spSecondT
              dec     a
spSecondT: and     #0x7f
              sta     dp:.tiny SP_SECOND
              lda     dp:.tiny SP_AF
              asl     a
              lda     dp:.tiny SP_AI
              adc     #0
              and     #0x7f
              sta     dp:.tiny (DC_SI+1)
              lda     dp:.tiny RL_TENT
              lsr     a
              bcc     spOddT
              brl     spEvenStart
spOddT:
              lda     dp:.tiny RL_HP
              sec
              sbc     dp:.tiny SP_AF
              xba
              tya
              sbc     #0
              bit     dp:.tiny SP_AF
              bpl     spStartT
              inc     a
spStartT:  and     #0x7f
              tay
              brl     spEnter


;;; The 2S,S pair ends exactly at 3S. Its first row rounds 2S; the
;;; remaining integer part and carry are applied by its second row.
spTailU:
              tay
              lda     dp:.tiny DC_SF
              asl     a
              sta     dp:.tiny SP_AF
              lda     dp:.tiny DC_SI
              rol     a
              and     #0x7f
              sta     dp:.tiny SP_AI
              lda     dp:.tiny SP_AF
              clc
              adc     dp:.tiny DC_SF
              sta     dp:.tiny (DC_SF+1)
              lda     dp:.tiny DC_SI
              adc     #0
              bit     dp:.tiny SP_AF
              bpl     spSecondU
              dec     a
spSecondU: and     #0x7f
              sta     dp:.tiny SP_SECOND
              lda     dp:.tiny SP_AF
              asl     a
              lda     dp:.tiny SP_AI
              adc     #0
              and     #0x7f
              sta     dp:.tiny (DC_SI+1)
              lda     dp:.tiny RL_HA
              and     #3
              cmp     #1
              beq     spOddU
              brl     spEvenStart
spOddU:
              lda     dp:.tiny RL_HP
              sec
              sbc     dp:.tiny SP_AF
              xba
              tya
              sbc     #0
              bit     dp:.tiny SP_AF
              bpl     spStartU
              inc     a
spStartU:  and     #0x7f
              tay
              brl     spEnter

;;; Keep the aligned position in A/B until entering its first row.
nrOStart:
              lda     dp:.tiny RL_HA
              tax
              lda     long:(texBlocks+0x300),x
              tax
              lda     dp:.tiny RL_HP
              xba
              lda     dp:.tiny (RL_HP+1)
              cpx     ##0
              beq     nrOReady
              cpx     ##1
              beq     nrOOne
nrOTwo:       xba
              sec
              sbc     dp:.tiny RL_HS
              xba
              sbc     dp:.tiny (RL_HS+1)
nrOOne:       xba
              sec
              sbc     dp:.tiny RL_HS
              xba
              sbc     dp:.tiny (RL_HS+1)
nrOReady:    and     #0x7f
              tay
              lda     dp:.tiny DC_SF
              asl     a
              sta     dp:.tiny (DC_SF+1)
              lda     dp:.tiny DC_SI
              adc     #0
              and     #0x7f
              sta     dp:.tiny (DC_SI+1)
              lda     dp:.tiny RL_TENT
              lsr     a
              bcs     nrOEnter
              xba
              sec
              sbc     dp:.tiny DC_SF
              xba
              tya
              sbc     #0
              bit     dp:.tiny DC_SF
              bpl     nrORound
              inc     a
nrORound:    and     #0x7f
              tay
nrOEnter:    lda     #0x6c
              sta     [.tiny RL_XO]
              ldx     dp:.tiny RL_C
              sep     #0x10
              clc
              .byte   0x6c
              .word   .word0 RL_TENT

nrOEnd:

;;; Keep the aligned position in A/B until entering its first row.
nrQStart:
              lda     dp:.tiny RL_HA
              dec     a
              and     #3
              tax
              lda     dp:.tiny RL_HP
              xba
              lda     dp:.tiny (RL_HP+1)
              cpx     ##0
              beq     nrQReady
              cpx     ##1
              beq     nrQOne
              cpx     ##2
              beq     nrQTwo
nrQThree:       xba
              sec
              sbc     dp:.tiny RL_HS
              xba
              sbc     dp:.tiny (RL_HS+1)
nrQTwo:       xba
              sec
              sbc     dp:.tiny RL_HS
              xba
              sbc     dp:.tiny (RL_HS+1)
nrQOne:       xba
              sec
              sbc     dp:.tiny RL_HS
              xba
              sbc     dp:.tiny (RL_HS+1)
nrQReady:    and     #0x7f
              tay
              lda     dp:.tiny DC_SF
              asl     a
              sta     dp:.tiny (DC_SF+1)
              lda     dp:.tiny DC_SI
              adc     #0
              and     #0x7f
              sta     dp:.tiny (DC_SI+1)
              lda     dp:.tiny RL_TENT
              lsr     a
              bcs     nrQEnter
              xba
              sec
              sbc     dp:.tiny DC_SF
              xba
              tya
              sbc     #0
              bit     dp:.tiny DC_SF
              bpl     nrQRound
              inc     a
nrQRound:    and     #0x7f
              tay
nrQEnter:    lda     #0x6c
              sta     [.tiny RL_XO]
              ldx     dp:.tiny RL_C
              sep     #0x10
              clc
              .byte   0x6c
              .word   .word0 RL_TENT
nrQEnd:

;;; Constant-step windows leave the top image rows unused. The setup
;;; helper and entry maps use those slots instead of column-record slots.
;;; Byte zero stays XBA for the flat drawer; live texture rows start later.
nrCopy:       lda     long:RL_DETI
              beq     nrSmall
              plb
              rtl
nrSmall:
              lda     long:VW_SIZE
              cmp     ##VW_HALFSIZE
              bne     1$
              jmp     .kbank nrHSet
1$:           cmp     ##VW_ONESIZE
              beq     nrCopyO
              cmp     ##VW_QUARTERSIZE
              bne     nrCopied
              ldx     ##.word0 nrQStart
              lda     ##(nrQEnd-nrQStart-1)
              bra     nrCopyRun
nrCopyO:      ldx     ##.word0 nrOStart
              lda     ##(nrOEnd-nrOStart-1)
nrCopyRun:    ldy     ##.word0 (texBlocks+1)
              .byte   0x54, .byte2 texBlocks, .byte2 nrOStart
              ldx     ##.word0 nrBack3
              ldy     ##.word0 (texBlocks+0x300)
              lda     ##168
              .byte   0x54, .byte2 texBlocks, .byte2 nrBack3
              lda     long:VW_SIZE
              cmp     ##VW_ONESIZE
              beq     nrMapO
              lda     ##.word0 Q_CEIL4
              sta     long:(nrRowLoad+1)
              lda     ##QV_ROW0
              bra     nrMapSet
nrMapO:       lda     ##.word0 O_CEIL3
              sta     long:(nrRowLoad+1)
              lda     ##OV_ROW0
nrMapSet:     sep     #0x20
              sta     long:(nrRowBase+1)
              lda     #BUF_BANK
              pha
              plb
              lda     #0
              xba
              lda     #0
              ldx     ##0
nrRowLoad:    lda     long:O_CEIL3,x
              clc
nrRowBase:    adc     #OV_ROW0
              tay
              lda     abs:TEXLO,y
              sta     long:(texBlocks+0x100),x
              lda     abs:TEXHI,y
              sta     long:(texBlocks+0x200),x
              inx
              cpx     ##169
              bcc     nrRowLoad
              rep     #0x20
nrCopied:     plb
              rtl

;;; Back-steps from the source start to the previous retained row.
nrBack3:
              .byte   2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2
              .byte   0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0
              .byte   1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1
              .byte   2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2
              .byte   0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0
              .byte   1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1
              .byte   2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2
              .byte   0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0
              .byte   1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1
              .byte   2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2
              .byte   0, 1, 2, 0, 1, 2, 0, 1, 2
