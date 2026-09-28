;;; The column lists of the 3D view (src/iigs/r_list65.s). Each frame, the
;;; walls, floors, ceilings, sprites, masked walls and shadows become
;;; records in the list of their column, and R_DrawLists draws the lists at
;;; the end of the frame.
;;;
;;; The records are in bank RECBANK (src/iigs/memmap.inc). No page is in
;;; cache slots $0900-$1FFF (pages $09-$1F, $89-$9F): the direct pages, the
;;; row blocks and the replay are there. RECBANK is cached, so record pages
;;; would compete for those slots. Column c starts at page COLPAGE(c):
;;; c for c < 9, c + $17 up to column 113, c + $2E after. A full page goes
;;; on in an extra page (a K_NEXT record); the extra pages are XP_FIRST..$FF.
;;; COLW (src/iigs/r_list65.s) holds the free byte of each list: the page
;;; << 8 | the offset, one word for each column.
#include "memmap.inc"
RECBANK       .equ    MM_RECBANK
RECBASE       .equ    MM_RECBASE
XP_FIRST      .equ    0xce            ; the first extra page (50: $CE..$FF)

;;; COLPAGE: A = the first page of column A (8-bit A, 0..159).
COLPAGE       .macro
              cmp     #9
              bcc     1$
              adc     #0x16                 ; (carry set: + $17)
              cmp     #0x89
              bcc     1$
              adc     #0x16                 ; (carry set: + $17 again)
1$:
              .endm
PAGE_ROOM     .equ    254             ; a record ends at this offset or before,
                                      ; so a K_NEXT record fits after it

;;; A record: its kind (the offset of its drawer in the table of
;;; R_DrawLists), then its fields, all bytes.
R_KIND        .equ    0
R_ROW         .equ    1               ; the first row
R_END         .equ    2               ; the row after the last
;;; K_FILL: one color: the byte of the first row, then of the row after it.
R_B1          .equ    3
R_B2          .equ    4
FILL_SIZE     .equ    5
;;; K_TEX: a texture column for the stepping drawer (walls, sprites, masked
;;; walls). The texture position one row before the first and the step, both >> 1
;;; (8.8 in 7.8): the fraction byte, then the texel (0..127). The texels.
;;; The page of the colormap of the even rows (in the bank of
;;; iigs_shrcmapA).
R_TF          .equ    3
R_TI          .equ    4
R_SF          .equ    5
R_SI          .equ    6
R_SRC         .equ    7               ; 3 bytes
R_CMP         .equ    10
TEX_SIZE      .equ    11
;;; K_TEXC: a masked post that follows, in the list of its column, the
;;; record (K_TEX or K_TEXC) of the post before it of the same column of the
;;; same texture or sprite: its rows, its position (R_TF, R_TI) and the low
;;; word of its texels; its step, colormap and texel bank are those of the
;;; K_TEX that starts the chain (drawTexC of src/iigs/r_list65.s). Never at
;;; offset 0 of a page (after a new page or a flush: K_TEX).
R_TCSRC       .equ    5               ; the low word of the texels
TEXC_SIZE     .equ    7
;;; K_FUZZ: the shadow drawer, the count of rows, from fuzz position R_POS.
R_COUNT       .equ    2
R_POS         .equ    3
FUZZ_SIZE     .equ    4
;;; K_OVL: a pixel of an automap line over the 3D view (the overlay mode):
;;; the row, the nibble to keep, the color nibble.
R_KEEP        .equ    2
R_COLOR       .equ    3
OVL_SIZE      .equ    4
;;; K_NEXT: the list goes on at the start of page R_PAGE.
R_PAGE        .equ    1
NEXT_SIZE     .equ    2
;;; The fill spans of the frame before (ceilFill and floorFill of
;;; src/iigs/r_seg65.s). Its top span is the ceiling fill of a column from
;;; the first row of the view (W_TOPR of src/iigs/wpage.inc); its bottom
;;; span is the floor fill to the row after the view (W_BOTR). Byte 2c of
;;; each table is the top span of column c, byte 2c + 1 its bottom span. A
;;; fill of the same bytes gets a record only for its rows that its span of
;;; the frame before (stamp W_FSP) did not show. A record over the rows of
;;; the walls (sprites, masked walls, shadows, the automap overlay) cuts the
;;; spans of its column (FSCUT). Bank $74: the cache does not hold it.
FS_ROW        .equ    MM_FS           ; the end of the top span, the first
                                      ;   row of the bottom span
FS_EVEN       .equ    (MM_FS + 0x200) ; the byte of the even rows
FS_ODD        .equ    (MM_FS + 0x400) ; the byte of the odd rows
FS_STAMP      .equ    (MM_FS + 0x600) ; the frame of the span (W_FSC)

;;; FSCUT first, end: the top span of the column X / 2 ends at the first
;;; row of a record, the bottom span starts at its end, when they reach
;;; into its rows. FSCUTE first: the same with the end in A. 8-bit A, X = 2
;;; * the column.
FSCUT         .macro  first, end
              lda     \end
              FSCUTE  \first
              .endm
FSCUTE        .macro  first
              cmp     long:(FS_ROW+1),x
              bcc     1$
              beq     1$
              sta     long:(FS_ROW+1),x
1$:           lda     \first
              cmp     long:FS_ROW,x
              bcs     2$
              sta     long:FS_ROW,x
2$:
              .endm

;;; The covered range of each column: the rows of its opaque masked K_TEX
;;; record (a sprite post, a masked wall) with the most rows, and that
;;; record. R_DrawLists does not paint those rows for the records before it
;;; in the list, as it paints them again. Byte 2c of CV_ROW is the first
;;; row, byte 2c + 1 the row after the last (0, 0: no range; 255, 254: none
;;; in this frame, as a shadow reads the rows next to its own); word 2c of
;;; CV_REC is the record. R_DrawLists sets 0, 0 again. Bank $74: the cache
;;; does not hold it.
CV_ROW        .equ    (MM_FS + 0x800)
CV_REC        .equ    (MM_FS + 0xa00)

;;; Bank $74 also holds the screen points of the automap's line ends by
;;; vertex (fastLine of src/iigs/am_map65.s): LV_KEY $0C00, LV_TAB $1000,
;;; VS_TAB $4000-$BFFF.

;;; The weapon skip (weaponClipSame of src/iigs/r_frame65.s). Byte 2c of
;;; WCLIP is floorclip of column c after the clip pass of the weapon: the
;;; first row of the run of weapon posts at the view bottom, + 1. WPREV is
;;; the vissprite of the weapon of the frame before (lump 0xffff: none).
;;; WTMP: the floor clip of a sprite in a frame that skips the weapon rows
;;; (wclipSprite). Bank $74: the cache does not hold it.
WCLIP         .equ    MM_WCLIP
WPREV         .equ    (MM_WCLIP + 0x180)
WTMP          .equ    (MM_WCLIP + 0x1c0)

;;; CVSET first, end: the masked K_TEX record Y paints the rows first .. end
;;; - 1 of column X / 2: it becomes the covered range of the column when it
;;; has more rows than the range before. 8-bit A, 16-bit X and Y. CVSETY
;;; first: the same with the end in the record (R_END of Y, DBR = RECBANK).
CVSET         .macro  first, end
              lda     long:(CV_ROW+1),x     ; the rows of the range (255:
              sec                           ;   none can come)
              sbc     long:CV_ROW,x
              clc                           ; + first >= end: not more rows
              adc     \first
              bcs     9$
              cmp     \end
              bcs     9$
              lda     \first
              sta     long:CV_ROW,x
              rep     #0x20                 ; (register work while the bus
              tya                           ;   writes)
              sep     #0x20
              sta     long:CV_REC,x
              xba
              sta     long:(CV_REC+1),x
              lda     \end
              sta     long:(CV_ROW+1),x
9$:
              .endm
CVSETY        .macro  first
              lda     long:(CV_ROW+1),x     ; the rows of the range (255:
              sec                           ;   none can come)
              sbc     long:CV_ROW,x
              clc                           ; + first >= end: not more rows
              adc     \first
              bcs     9$
              cmp     abs:R_END,y
              bcs     9$
              lda     \first
              sta     long:CV_ROW,x
              rep     #0x20                 ; (register work while the bus
              tya                           ;   writes)
              sep     #0x20
              sta     long:CV_REC,x
              xba
              sta     long:(CV_REC+1),x
              lda     abs:R_END,y
              sta     long:(CV_ROW+1),x
9$:
              .endm

K_TEX         .equ    0               ; (0: R_DrawLists reads it with R_ROW)
K_FILL        .equ    2
K_TEXC        .equ    6
K_FUZZ        .equ    8
K_OVL         .equ    10
K_NEXT        .equ    12
