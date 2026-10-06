;;; Solid walls replace eligible wall tiers with K_FILL records.
;;;
;;; texcolors holds one PLAYPAL index per texture, selected at build time
;;; by tools/texcolor.py. Lighting matches texRec: W_CMP when W_LV is 0,
;;; otherwise c26Reverse[84 - W_LV + d], d = min(23, rw_scale >> 13).
;;; iigs_shrcmapA/B supply the packed SHR bytes for even/odd screen rows;
;;; swap them when the record starts on an odd row, as PLANEFILL does.
;;;
;;; Bit 15 of texcolors preserves the ordinary texture path for switches,
;;; doors and other marked surfaces. Wall and grate choices install call
;;; targets at view/option changes; the column loops do not test solidOn.
;;; Grates independently use the original art, generated bars, or omit
;;; patches flagged as transparent. These choices change drawing only;
;;; collision and shot tracing keep the same level geometry.
;;;
;;; solidMid/Top/Bot: A/X/Y 16-bit, X = 2 * column, D = WPAGE,
;;; DBR = RECBANK, DC_COUNT >= 1, W_YL = first row. Return with A8,
;;; X/Y16; X, D and DBR preserved. A, Y and SWB are scratch. The ordinary
;;; tier targets share bank 3 so the protected-texture path can use RTS.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "lists.inc"
#include "wpage.inc"

              .extern newPage, COLW, c26Reverse, iigs_shrcmapA, iigs_shrcmapB
              .extern DC_COUNT, c17Mode
              .extern v20c17draw, v28c17draw, v05c17draw, v13c17draw
              .extern v02c17draw, v06c17draw, v10c17draw, v14c17draw
              .extern v07topCall, v15topCall, v07botCall, v15botCall
              .extern gcTex, gcMid, gcTop, gcBot
              .extern c17Hook, c17Return, genColumn
              .extern v02c17slow, v05c17slow, v06c17slow, v10c17slow
              .extern v13c17slow, v14c17slow, v20c17slow, v28c17slow
              .extern settingsFile, maskedColsCall, mwCols, FR_TEX, FR_PATCH, FR_WMASK
              .extern texCol, drawMid, drawTop, drawBot

SWB           .equ    0xd8            ; solidFlat scratch: even/odd SHR row bytes

              .section solidcode, text
              .public solidMid, solidTop, solidBot, solidOn, changeSolid

solidOn:      .word   0               ; 0 textured walls, 1 eligible tiers use fills

solidMid:     lda     dp:W_MIDTEX
              ldy     ##.word0 (drawMid-1)
              bra     solidGo
solidTop:     lda     dp:W_TOPTEX
              ldy     ##.word0 (drawTop-1)
              bra     solidGo
solidBot:     lda     dp:W_BOTTEX
              ldy     ##.word0 (drawBot-1)
solidGo:      phx
              cmp     ##TEXCOLOR_N
              bcc     1$
              lda     ##0                   ; invalid texture number: use entry 0
1$:           asl     a
              tax
              lda     long:texcolors,x
              bpl     solidFlat
              plx
              phy                           ; Y = ordinary tier address minus one
              rts                           ; tail-call; it returns to our caller
solidFlat:    and     ##0x00ff
              pha                           ; the palette index
              lda     dp:W_LV
              beq     2$
              lda     dp:(W_SC+1)           ; rw_scale >> 8, as texRec
              cmp     ##(24 << 5)
              bcc     3$
              lda     ##(23 << 5)
3$:           asl     a
              asl     a
              asl     a
              xba
              and     ##0x00ff              ; d
              sta     dp:SWB
              lda     ##84
              sec
              sbc     dp:W_LV               ; startmap + 24
              clc
              adc     dp:SWB
              tax
              sep     #0x20
              lda     long:c26Reverse,x     ; the colormap page
              bra     4$
2$:           sep     #0x20
              lda     dp:W_CMP
4$:           sec
              sbc     #.byte1 iigs_shrcmapA ; colormap page -> table level index
              rep     #0x20
              and     ##0x00ff
              xba
              ora     1,s                   ; level << 8 | color
              tax
              lda     long:iigs_shrcmapA,x
              and     ##0x00ff
              sep     #0x20
              sta     dp:SWB
              rep     #0x20
              lda     long:iigs_shrcmapB,x
              and     ##0x00ff
              sep     #0x20
              sta     dp:(SWB+1)
              rep     #0x20
              pla
              plx                           ; X = 2 * column
              sep     #0x20
              lda     long:(COLW+1),x
              xba
              lda     long:COLW,x
              tay
              cmp     #(PAGE_ROOM - FILL_SIZE + 1)
              bcs     8$
5$:           clc
              adc     #FILL_SIZE
              sta     long:COLW,x
              lda     #K_FILL
              sta     abs:R_KIND,y
              lda     dp:W_YL
              sta     abs:R_ROW,y
              clc
              adc     dp:.tiny DC_COUNT
              sta     abs:R_END,y           ; exclusive end row
              lda     dp:W_YL               ; odd first row: swap the bytes
              lsr     a
              lda     dp:SWB
              bcs     6$
              sta     abs:R_B1,y
              lda     dp:(SWB+1)
              sta     abs:R_B2,y
              rts
6$:           sta     abs:R_B2,y
              lda     dp:(SWB+1)
              sta     abs:R_B1,y
              rts
8$:           rep     #0x20
              jsl     long:newPage
              tya
              sep     #0x20
              clc
              bra     5$

;;; Install call targets between frames, after c17Mode has restored the
;;; view's textured path. With solidOn clear, solidReapply leaves c17draw
;;; intact and restores only the generic and mixed-tier call sites.
              .section solidpatch, text
              .public solidReapply, solidLoad, solidCollect

;;; Toggle only wall dispatch. Re-running c5Mode here would undo the half
;;; and 2/3 seg patches without their view-change installers running again.
;;; c17Mode restores the ordinary column calls, then solidReapply selects
;;; the requested wall mode. This near entry shares bank 4 with the menu.
changeSolid:  lda     long:solidOn
              eor     ##1
              sta     long:solidOn
              jsl     long:c17Mode
              jsl     long:solidReapply
              rts

;;; A16: read settings bytes 24 (solid walls) and 25 (grate mode).
;;; The loader clears invalid files; absent options are zero in older
;;; files. Accept only solidOn = 1 and grateMode = 0..2, else default to
;;; textured walls/original grates. Call targets are installed separately.
solidLoad:    lda     long:(settingsFile+24)
              and     ##0x00ff
              cmp     ##1
              beq     1$
              lda     ##0
1$:           sta     long:solidOn
              lda     long:(settingsFile+25)
              and     ##0x00ff
              cmp     ##3
              bcc     2$
              lda     ##0
2$:           sta     long:grateMode
              rtl
;;; A8: store both option bytes before collect computes the checksum.
solidCollect: lda     long:solidOn
              sta     long:(settingsFile+24)
              lda     long:grateMode
              sta     long:(settingsFile+25)
              rtl

solidReapply: php
              rep     #0x30
              lda     long:solidOn
              and     ##0x00ff
              bne     solidEnable
              jmp     .kbank solidOff
solidEnable:
              lda     ##.word0 solidMid
              sta     long:(v20c17draw+1)
              sta     long:(v28c17draw+1)
              sta     long:(gcMid+1)
              lda     ##.word0 solidTop
              sta     long:(v05c17draw+1)
              sta     long:(v13c17draw+1)
              sta     long:(v07topCall+1)
              sta     long:(v15topCall+1)
              sta     long:(gcTop+1)
              lda     ##.word0 solidBot
              sta     long:(v02c17draw+1)
              sta     long:(v06c17draw+1)
              sta     long:(v10c17draw+1)
              sta     long:(v14c17draw+1)
              sta     long:(v07botCall+1)
              sta     long:(v15botCall+1)
              sta     long:(gcBot+1)
              ;; Protected tiers call texCol through drawMid/Top/Bot. Disable
              ;; its fused FULL continuation so it returns to that tier;
              ;; jumping into a tier here would draw it twice. The closed-
              ;; column fallback must use genColumn for the same reason.
              lda     ##0x0060
              sta     long:c17Return
              lda     ##0xeaea
              sta     long:c17Hook
              sta     long:(c17Hook+2)
              lda     ##.word0 genColumn
              sta     long:(v02c17slow+1)
              sta     long:(v05c17slow+1)
              sta     long:(v06c17slow+1)
              sta     long:(v10c17slow+1)
              sta     long:(v13c17slow+1)
              sta     long:(v14c17slow+1)
              sta     long:(v20c17slow+1)
              sta     long:(v28c17slow+1)
              ;; Flat tiers need no texture-column setup. Protected tiers
              ;; obtain it on demand through the ordinary tier entry.
              sep     #0x20
              lda     #0xea
              sta     long:gcTex
              sta     long:(gcTex+1)
              sta     long:(gcTex+2)
              jsl     long:grateReapply
              plp
              rtl
solidOff:     lda     ##.word0 drawMid
              sta     long:(gcMid+1)
              lda     ##.word0 drawTop
              sta     long:(gcTop+1)
              sta     long:(v07topCall+1)
              sta     long:(v15topCall+1)
              lda     ##.word0 drawBot
              sta     long:(gcBot+1)
              sta     long:(v07botCall+1)
              sta     long:(v15botCall+1)
              sep     #0x20
              lda     #0x20
              sta     long:gcTex
              lda     #.byte0 texCol
              sta     long:(gcTex+1)
              lda     #.byte1 texCol
              sta     long:(gcTex+2)
              jsl     long:grateReapply
              plp
              rtl

              .public grateMode, changeGrates, wallOptionText, uiSolid, uiGrates

grateMode:    .word   0               ; 0 original, 1 bars, 2 none

;;; The menu supplies A = 0 for left, 1 for right/Return.
changeGrates: cmp     ##1
              lda     long:grateMode
              bcc     gratePrevious
              inc     a
              cmp     ##3
              bcc     grateChosen
              lda     ##0
              bra     grateChosen
gratePrevious:
              dec     a
              bpl     grateChosen
              lda     ##2
grateChosen:  sta     long:grateMode
              jsl     long:grateReapply
              rts

;;; A = value, X = UI kind; return A = near label address in bank 4.
;;; Kinds 48/52/56 are keyboard/wall/grate settings. WALL TEXTURES shows
;;; the inverse of solidOn; the stored bit always means solid walls.
;;; X is scratch when selecting a grate label.
wallOptionText:
              cpx     ##56
              beq     grateLabel
              cpx     ##52
              bne     optionBoolean
              eor     ##1
optionBoolean:
              cmp     ##0
              beq     optionOff
              lda     ##.word0 wallOnText
              rts
optionOff:    lda     ##.word0 wallOffText
              rts
grateLabel:   asl     a
              tax
              lda     long:grateLabels,x
              rts
grateLabels:  .word   .word0 grateOriginal, .word0 grateBars, .word0 grateNone
wallOnText:   .asciz  "ON"
wallOffText:  .asciz  "OFF"
grateOriginal:.asciz  "ORIGINAL"
grateBars:    .asciz  "BARS"
grateNone:    .asciz  "NONE"
uiSolid:      .asciz  "WALL TEXTURES"
uiGrates:     .asciz  "GRATES"

;;; ORIGINAL calls mwCols directly. BARS and NONE inspect texture flags
;;; once per masked range, including ranges drawn between sprites.
;;; Only call operands change here; all three targets share bank 4.
grateReapply: php
              rep     #0x30
              lda     long:grateMode
              beq     grateOriginalCall
              cmp     ##1
              beq     grateBarsCall
              lda     ##.word0 grateHiddenColumns
              bra     grateSetCall
grateBarsCall:
              lda     ##.word0 grateColumns
              bra     grateSetCall
grateOriginalCall:
              lda     ##.word0 mwCols
grateSetCall: sta     long:(maskedColsCall+1)
              sep     #0x20
              lda     #.byte2 mwCols        ; all targets are in bank 4
              sta     long:(maskedColsCall+3)
              plp
              rtl

;;; Bit 12 marks the single-patch transparent textures recognized by
;;; texcolor.py. Suppress their drawing; all other middle textures retain
;;; the normal path, including opaque panels used as hidden doors.
grateHiddenColumns:
              lda     .near FR_TEX
              asl     a
              tax
              lda     long:texcolors,x
              bit     ##0x1000
              beq     grateOpaque
              rtl
grateOpaque:  jmp     long:mwCols

;;; Bit 14 permits a bar patch; bit 13 selects its 128- rather than 64-row
;;; height. The generator requires matching height and zero patch offsets,
;;; so mwCols can retain the range's texture origin, scale and clipping.
;;; Its normal post path also retains lighting and ordering against sprites.
;;; Restore FR_PATCH for maskedRange's cache release: the static bar patch
;;; does not own that cache entry. FR_WMASK is scratch; maskedRange reloads
;;; it from the texture before each call.
grateColumns: lda     .near FR_TEX
              asl     a
              tax
              lda     long:texcolors,x
              bit     ##0x4000
              bne     grateReplace
              jmp     long:mwCols
grateReplace: ldy     ##.word0 grate64
              bit     ##0x2000
              beq     grateSave
              ldy     ##.word0 grate128
grateSave:    lda     .near FR_PATCH
              pha
              lda     .near (FR_PATCH+2)
              pha
              lda     ##15                  ; repeat the 16-column bar pattern
              sta     .near FR_WMASK
              tya
              sta     .near FR_PATCH
              lda     ##.word2 grate64
              sta     .near (FR_PATCH+2)
              jsl     long:mwCols
              pla
              sta     .near (FR_PATCH+2)
              pla
              sta     .near FR_PATCH
              rtl

              .section gratepatch, rodata
#include "gratepatch.inc"

              .section texcolor, rodata
              .public texcolors
texcolors:
#include "texcolor.inc"
