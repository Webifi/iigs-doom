#ifndef V_PAD
#define V_PAD 1
#endif
;;; One loop of R_RenderSegLoop (src/iigs/r_seg65.s), for one kind of seg:
;;;   V_NAME        label prefix
;;;   V_ONE         single sided line (mid texture)
;;;   V_TOP, V_BOT  top wall, bottom wall of a two sided line
;;;   V_MC, V_MF    markceiling (not a sky), markfloor
;;; Entry at L(entry) with the state of the seg in WPAGE.
;;;
;;; The loop runs with 8-bit A and 16-bit X (X = 2 * column): the rows are
;;; bytes, each store is one byte, and reads and register work follow it.
;;; floorclip holds the floor clip + 1 and ceilingclip the ceiling clip + 1,
;;; both clipped to -1..168 (the same result for every reader, as all the
;;; rows are 0..167): bytes 0..169, with a high byte of 0. A column with a
;;; floor clip of -1 (0) goes to genColumn. The bytes of a column:
;;;   W_FC   floor clip + 1 (1..169)      W_FCR  floor clip (0..168)
;;;   W_CT   ceiling clip + 1 (0..169)
;;;   W_YL   yl = max(the top edge, W_CT), at most 169
;;;   W_YH1  (yh + 1) + 1, with yh + 1 = min(the bottom edge, fc), clipped
;;;          to -1..168: 0 when the wall ends above row 0
;;;   W_CB1, W_FT, W_MID1, W_MID, W_CC1: rows; W_FC1: the new floor clip + 1
;;; The edges step as bytes (STEP8E of src/iigs/r_seg65.s: 24 bits).

#define V_TEX (V_ONE || V_TOP || V_BOT)

L(entry):     ldx     dp:W_X2
              sep     #0x20
              bra     L(col)

L(slow):      rep     #0x20
#if V_ONE || (V_TOP != V_BOT)
L(c17slow)    .equ    .
              jsr     .kbank c17Slow        ; FULL; mode installer restores genColumn
#else
              jsr     .kbank genColumn
#endif
              sep     #0x20
              brl     L(next)

L(col):       lda     long:floorclip,x      ; floor clip + 1
              beq     L(slow)               ;   (-1: a closed column)
              sta     dp:W_FC
              dec     a
              sta     dp:W_FCR
              lda     long:ceilingclip,x    ; ceiling clip + 1
              sta     dp:W_CT
#if V_MC || V_TOP || V_ONE
              ;; (a loop with no ceiling, top wall or mid wall never uses yl)
              STEP8E  W_TF, W_TS            ; yl = max(the top edge, ct), to 169
              bmi     L(row1)                    ;   (above row 0: ct)
              bne     L(row2)                    ;   (row 256 or more: 169)
              lda     dp:(W_TF+2)
              cmp     dp:W_CT
              bcc     L(row1)
              cmp     #(CONST_VIEWHEIGHT + 2)
              bcc     L(row3)
L(row2):           lda     #(CONST_VIEWHEIGHT + 1)
              bra     L(row3)
L(row1):           lda     dp:W_CT
L(row3):           sta     dp:W_YL
#if V_BOT && V_MC && !V_TOP && !V_ONE
              sta     dp:.tiny DC_ROW       ; yl stays here: drawBot reuses W_YL
#endif
#endif
#if V_MF || V_BOT || V_ONE
              ;; (a loop with no floor, bottom wall or mid wall never uses yh)
              STEP8E  W_BF, W_BS            ; yh + 1 = min(the bottom edge, fc)
              bmi     L(row4)                    ;   (above row 0: -1)
              bne     L(row5)                    ;   (row 256 or more: fc)
              lda     dp:(W_BF+2)
              cmp     dp:W_FC
              bcs     L(row5)
              inc     a
              bra     L(row6)
L(row4):           lda     #0
              bra     L(row6)
L(row5):           lda     dp:W_FC
L(row6):           sta     dp:W_YH1
#endif
#if V_TEX
              STEP8   W_SC, W_SCS           ; rw_scale
#endif

#if V_MC
              ;; ceiling: rows ct .. min(yl, fc) - 1 in the ceiling color
              ;; (ceilFill), then ct = that end
              lda     dp:W_YL
              cmp     dp:W_FC               ; yl <= fc: yl, else fc
              bcc     L(row7)
              lda     dp:W_FCR
L(row7):           sta     dp:W_CB1              ; (the end; the first row: ct)
              cmp     dp:W_CT
              beq     L(row73)
              bcc     L(row73)
              jsr     .kbank ceilFill
L(row73):
#define V_CC1 W_CB1
#else
#define V_CC1 W_CT
#endif

#if V_MF
              ;; floor: rows max(yh + 1, V_CC1) .. fc - 1 in the floor color
              ;; (floorFill), then fc = that first row
              lda     dp:V_CC1
              cmp     dp:W_YH1              ; V_CC1 > yh + 1: V_CC1
              bcs     L(row9)
              lda     dp:W_YH1
              dec     a
L(row9):           sta     dp:W_FT               ; (the first row; the end: fc)
              inc     a                     ; rows when the first < fc
              cmp     dp:W_FC
              bcs     L(row93)
              jsr     .kbank floorFill
L(row93):
#define V_FC W_FT
#else
#define V_FC W_FCR
#endif

#if V_ONE
              ;; single sided line: rows yl .. yh
              lda     dp:W_YH1              ; (yh + 1) - yl
              clc
              sbc     dp:W_YL
              beq     L(row11)
              bcc     L(row11)
              sta     dp:.tiny DC_COUNT     ; (the high bytes of the DC_ words
              rep     #0x20                 ;   are 0). The row is already W_YL.
L(c17draw)    .equ    .
              jsr     .kbank texCol         ; FULL: fixed mid continuation
L(row11):          lda     #(CONST_VIEWHEIGHT + 1) ; closed: ceiling clip 168,
              sta     long:ceilingclip,x    ;   floor clip -1
              lda     #0
              sta     long:floorclip,x
#else

#if V_TOP
              ;; top wall: rows yl .. mid, mid + 1 = min(the edge, V_FC); cc =
              ;; mid, or yl - 1 when it has no rows
              STEP8E  W_PH, W_PHS
              bmi     L(row13)                   ; (above row 0: no rows)
              bne     L(row121)                  ; (row 256 or more: V_FC)
              lda     dp:(W_PH+2)
              cmp     dp:V_FC
              bcc     L(row12)
L(row121):         lda     dp:V_FC
L(row12):          sta     dp:W_MID1
              sec
              sbc     dp:W_YL
              beq     L(row13)
              bcc     L(row13)
              sta     dp:.tiny DC_COUNT
              rep     #0x20                 ; the row is already W_YL
#if !V_BOT
L(c17draw)    .equ    .
              jsr     .kbank texCol         ; FULL: fixed top continuation
#else
              jsr     .kbank drawTop        ; (8-bit A back: texRec)
#endif
              lda     dp:W_MID1
              bra     L(row14)
L(row13):          lda     dp:W_YL
L(row14):          sta     dp:W_CC1
#define V_CC1R W_CC1
#elif V_MC
#if V_BOT
#define V_CC1R .tiny DC_ROW                 ; yl, saved before drawBot reuses W_YL
#else
#define V_CC1R W_YL                         ; no top wall: cc = yl - 1
#endif
#else
#define V_CC1R W_CT                         ; cc as it was
#endif

#if V_BOT
              ;; bottom wall: rows mid .. yh, mid = max(the edge, cc + 1), to
              ;; 169; fc = mid, or yh + 1 when it has no rows
              STEP8E  W_PL, W_PLS
              bmi     L(row15)                   ; (above row 0: cc + 1)
              bne     L(row151)                  ; (row 256 or more: 169)
              lda     dp:(W_PL+2)
              cmp     dp:V_CC1R
              bcs     L(row16)
L(row15):          lda     dp:V_CC1R
              bra     L(row16)
L(row151):         lda     #(CONST_VIEWHEIGHT + 1)
L(row16):          sta     dp:W_MID
              lda     dp:W_YH1              ; (yh + 1) - mid
              clc
              sbc     dp:W_MID
              beq     L(row17)
              bcc     L(row17)
              sta     dp:.tiny DC_COUNT
              lda     dp:W_MID              ; tierDraw reads the row from W_YL
              sta     dp:W_YL
              rep     #0x20
#if !V_TOP
L(c17draw)    .equ    .
              jsr     .kbank texCol         ; FULL: fixed bottom continuation
#else
              jsr     .kbank drawBot        ; (8-bit A back: texRec)
#endif
              lda     dp:W_MID              ; the new floor clip + 1 = mid + 1
              inc     a
              bra     L(row18)
L(row17):          lda     dp:W_YH1              ; = yh + 1, + 1
L(row18):          sta     dp:W_FC1
#define V_FC1R W_FC1
#elif V_MF
#define V_FC1R W_YH1                        ; no bottom wall: fc = yh + 1
#else
#define V_FC1R W_FC                         ; fc as it was
#endif

#if V_MC || V_MF
              ;; a column that blocks all sight is solid for the BSP code:
              ;; fc <= cc + 1, that is fc + 1 <= (cc + 1) + 1
              lda     dp:V_CC1R
              inc     a
              cmp     dp:V_FC1R
              bcc     L(row20)
              rep     #0x20
              jsr     .kbank solidColumn
              sep     #0x20
L(row20):
#endif
              lda     dp:V_FC1R             ; the new clips + 1, one byte each
              sta     long:floorclip,x
              lda     dp:V_CC1R
              sta     long:ceilingclip,x
#undef V_CC1R
#undef V_FC1R
#endif

L(next):      inx
              inx
              cpx     dp:W_X2END
              bcs     L(done)
L(br):        brl     L(col)                ; (the half view: BRL L(nextH),
L(done):      rep     #0x20                 ;   R_SegHalf of r_list65.s)
#if V_FAR
              jmp     .kbank segDone        ; (segmore: a BRL across sections has
#else                                       ;   no object format)
              brl     segDone
#endif
#if (V_ONE || V_TOP) && V_PAD
              .space  4                     ; the removed W_YL copy; keeps the next loop
#endif

#if V_TEX
              .space 6                     ; 24-bit scale step; next loop stays
#endif

#undef V_TEX
#undef V_CC1
#undef V_FC
