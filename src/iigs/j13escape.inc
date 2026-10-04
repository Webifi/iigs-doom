;;; Mode 0 on ROM 00/01 still permits Escape to open the menu. This hook
;;; reads C000 once per frame and acknowledges any strobed character: other
;;; characters are discarded so they cannot block a later Escape. It neither
;;; enables gameplay input nor runs the capture timer; raw ADB stays separate.
;;; Return with A16 beyond the full eight-byte loop slot. Opening the menu
;;; restores the slot's branch while this routine is still executing.
J13EscapeCheck:
              sep #0x20
              lda long:KBD
              bpl j13EscapeDone
              cmp #0x9b
              beq j13EscapeMenu
              lda long:AKD                  ; Free the latch for a later Escape.
              bra j13EscapeDone
j13EscapeMenu:
              lda long:AKD
              rep #0x20
              jsl long:M_StartControlPanel
j13EscapeDone:
              rep #0x20
              jmp long:(J13EscapeSite+8)

;;; A/X/Y16, IRQs masked by the mode transition. Release adapter-held keys
;;; before selecting raw input. Unsupported ROMs and timedemos skip the hook.
j13InstallEscape:
              jsr .kbank j13ReleaseHeld
              lda long:j13Available
              beq j13EscapeInstalled
              lda long:_g_timingdemo
              bne j13EscapeInstalled
              lda ##.word0 J13EscapeCheck
              sta long:(J13EscapeSite+1)
              sep #0x20
              lda #.byte2 J13EscapeCheck
              sta long:(J13EscapeSite+3)
              lda #0x5c
              sta long:J13EscapeSite
              rep #0x20
j13EscapeInstalled:
              rts

j13EscapeToMenu:
              lda ##0x0680                  ; BRA across the six reserved bytes.
              sta long:J13EscapeSite
              lda ##0
              sta long:(J13EscapeSite+2)
              jmp .kbank installMenuReader

j13EscapeEnd:
