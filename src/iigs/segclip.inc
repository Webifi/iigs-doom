;;; Clip-only columns of the small views. Kept columns re-enter the original
;;; loop; omitted columns retain every clip and edge/scale update, including
;;; the original genColumn fallback. No records, texture projection or DC inputs.
#define V_TEX (V_ONE || V_TOP || V_BOT)
L(select):    lda     long:(O_PAGE2+1),x ; patched once per size change
              bne     L(clip)
              lda     long:floorclip,x
              jmp     .kbank (V_COL+4)
L(slow):      rep     #0x20
              jsr     .kbank genColumn
              sep     #0x20
              jmp     .kbank V_NEXT
L(clip):      lda     long:floorclip,x      ; floor clip + 1
              beq     L(slow)               ;   (-1: a closed column)
              sta     dp:W_FC
              dec     a
              sta     dp:W_FCR
              lda     long:ceilingclip,x    ; ceiling clip + 1
              sta     dp:W_CT
#if V_ONE
              STEP8E W_TF, W_TS
              STEP8E W_BF, W_BS
#else
#if V_MC || V_TOP || V_ONE
              ;; (a loop with no ceiling, top wall or mid wall never uses yl)
              STEP8E  W_TF, W_TS            ; yl = max(the top edge, ct), to 169
              bmi     1$                    ;   (above row 0: ct)
              bne     2$                    ;   (row 256 or more: 169)
              lda     dp:(W_TF+2)
              cmp     dp:W_CT
              bcc     1$
              cmp     #(CONST_VIEWHEIGHT + 2)
              bcc     3$
2$:           lda     #(CONST_VIEWHEIGHT + 1)
              bra     3$
1$:           lda     dp:W_CT
3$:           sta     dp:W_YL
#endif
#if V_MF || V_BOT || V_ONE
              ;; (a loop with no floor, bottom wall or mid wall never uses yh)
              STEP8E  W_BF, W_BS            ; yh + 1 = min(the bottom edge, fc)
              bmi     4$                    ;   (above row 0: -1)
              bne     5$                    ;   (row 256 or more: fc)
              lda     dp:(W_BF+2)
              cmp     dp:W_FC
              bcs     5$
              inc     a
              bra     6$
4$:           lda     #0
              bra     6$
5$:           lda     dp:W_FC
6$:           sta     dp:W_YH1
#endif
#endif
#if V_TEX
              STEP8   W_SC, W_SCS           ; rw_scale
#endif

#if V_MC && !V_ONE
              ;; ceiling: rows ct .. min(yl, fc) - 1 in the ceiling color
              ;; (ceilFill), then ct = that end
              lda     dp:W_YL
              cmp     dp:W_FC               ; yl <= fc: yl, else fc
              bcc     7$
              lda     dp:W_FCR
7$:           sta     dp:W_CB1              ; (the end; the first row: ct)
#define V_CC1 W_CB1
#else
#define V_CC1 W_CT
#endif

#if V_MF && !V_ONE
              ;; floor: rows max(yh + 1, V_CC1) .. fc - 1 in the floor color
              ;; (floorFill), then fc = that first row
              lda     dp:V_CC1
              cmp     dp:W_YH1              ; V_CC1 > yh + 1: V_CC1
              bcs     9$
              lda     dp:W_YH1
              dec     a
9$:           sta     dp:W_FT               ; (the first row; the end: fc)
#define V_FC W_FT
#else
#define V_FC W_FCR
#endif

#if V_ONE
              lda     #(CONST_VIEWHEIGHT + 1) ; closed: ceiling clip 168,
              sta     long:ceilingclip,x    ;   floor clip -1
              lda     #0
              sta     long:floorclip,x
#else

#if V_TOP
              ;; top wall: rows yl .. mid, mid + 1 = min(the edge, V_FC); cc =
              ;; mid, or yl - 1 when it has no rows
              STEP8E  W_PH, W_PHS
              bmi     13$                   ; (above row 0: no rows)
              bne     121$                  ; (row 256 or more: V_FC)
              lda     dp:(W_PH+2)
              cmp     dp:V_FC
              bcc     12$
121$:         lda     dp:V_FC
12$:          sta     dp:W_MID1
              sec
              sbc     dp:W_YL
              beq     13$
              bcc     13$
              lda     dp:W_MID1
              bra     14$
13$:          lda     dp:W_YL
14$:          sta     dp:W_CC1
#define V_CC1R W_CC1
#elif V_MC
#define V_CC1R W_YL                         ; no top wall: cc = yl - 1
#else
#define V_CC1R W_CT                         ; cc as it was
#endif

#if V_BOT
              ;; bottom wall: rows mid .. yh, mid = max(the edge, cc + 1), to
              ;; 169; fc = mid, or yh + 1 when it has no rows
              STEP8E  W_PL, W_PLS
              bmi     15$                   ; (above row 0: cc + 1)
              bne     151$                  ; (row 256 or more: 169)
              lda     dp:(W_PL+2)
              cmp     dp:V_CC1R
              bcs     16$
15$:          lda     dp:V_CC1R
              bra     16$
151$:         lda     #(CONST_VIEWHEIGHT + 1)
16$:          sta     dp:W_MID
              lda     dp:W_YH1              ; (yh + 1) - mid
              clc
              sbc     dp:W_MID
              beq     17$
              bcc     17$
              lda     dp:W_MID              ; the new floor clip + 1 = mid + 1
              inc     a
              bra     18$
17$:          lda     dp:W_YH1              ; = yh + 1, + 1
18$:          sta     dp:W_FC1
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
              bcc     20$
              rep     #0x20
              jsr     .kbank solidColumn
              sep     #0x20
20$:
#endif
              lda     dp:V_FC1R             ; the new clips + 1, one byte each
              sta     long:floorclip,x
              lda     dp:V_CC1R
              sta     long:ceilingclip,x
#undef V_CC1R
#undef V_FC1R
#endif


              jmp     .kbank V_NEXT
#undef V_TEX
#undef V_CC1
#undef V_FC
