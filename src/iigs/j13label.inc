;;; The HUD font has capitals only. Keep a lowercase e for the IIe label;
;;; all other menu text retains the normal uppercase conversion.
              .section j13ui, text
              .public j13MenuLabel
j13MenuLabel: .asciz "J13 / IIe KEYBOARD"

;;; Inline continuation of bmWrite: A16 is the character, _Dp[8..11] the
;;; string's base address. Only this exact label may use the lowercase patch.
;;; Supply its far pointer in _Dp[4..7] and join the normal width/draw path;
;;; every other character resumes the uppercase font lookup.
bmMenuGlyph:  cmp     ##'e'
              bne     bmMenuUpper
              lda     dp:.tiny (_Dp+8)
              cmp     ##.word0 j13MenuLabel
              bne     bmMenuRestoreE
              lda     dp:.tiny (_Dp+10)
              cmp     ##.word2 j13MenuLabel
              bne     bmMenuRestoreE
              lda     ##.word0 j13LowerE
              sta     dp:.tiny (_Dp+4)
              lda     ##.word2 j13LowerE
              sta     dp:.tiny (_Dp+6)
              jmp     .kbank bmMenuGlyphReady
bmMenuRestoreE:
              lda     ##'e'
bmMenuUpper:  cmp     ##'a'
              bcc     bmMenuGlyphNormal
              cmp     ##('z' + 1)
              bcs     bmMenuGlyphNormal
              sbc     ##('a' - 'A' - 1)
bmMenuGlyphNormal:
              jmp     .kbank bmMenuGlyphLookup

;;; A six-pixel-wide Doom patch with a five-row lowercase e and red shading.
;;; The negative top offset aligns its short form with the menu baseline.
j13LowerE:    .word   6, 5, 0, -1
              .long   j13LowerE0-j13LowerE, j13LowerE1-j13LowerE
              .long   j13LowerE2-j13LowerE, j13LowerE3-j13LowerE
              .long   j13LowerE4-j13LowerE, j13LowerE5-j13LowerE
j13LowerE0:   .byte   0, 5, 0, 0xbf, 0xb5, 0xb4, 0xb5, 0xbf, 0, 0xff
j13LowerE1:   .byte   0, 5, 0, 0xb5, 0xbf, 0xb3, 0xbf, 0xb5, 0, 0xff
j13LowerE2:   .byte   0, 5, 0, 0xb3, 0xbf, 0xb3, 0xbf, 0xb3, 0, 0xff
j13LowerE3:   .byte   0, 5, 0, 0xb4, 0xbf, 0xb4, 0xbf, 0xb4, 0, 0xff
j13LowerE4:   .byte   0, 5, 0, 0xbf, 0xb5, 0xb5, 0xbf, 0xb6, 0, 0xff
j13LowerE5:   .byte   0, 5, 0, 0xbf, 0xbf, 0xbf, 0xbf, 0xbf, 0, 0xff
