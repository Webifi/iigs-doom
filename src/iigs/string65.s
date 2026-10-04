;;; memcpy and memset in 65816 assembly.
;;;
;;; Copy and fill words from the start of the buffer, then handle an odd
;;; trailing byte. memcpy requires non-overlapping source/destination
;;; ranges; neither routine provides a backward-copy path.

              .rtmodel version, "1"
              .rtmodel core, "*"

              .extern _Dp

;;; ---------------------------------------------------------------------------
;;; void *memcpy(void *dest, const void *src, size_t n)
;;;   In: _Dp[0-3] = dest, _Dp[4-7] = src, C = n. Out: X:C = dest.
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public memcpy
memcpy:       ldy     ##0
              lsr     a                     ; carry = n & 1, the loop keeps it
              tax
              beq     2$
1$:           lda     [.tiny (_Dp+4)],y
              sta     [.tiny _Dp],y
              iny
              iny
              dex
              bne     1$
2$:           bcc     3$
              sep     #0x20                 ; the last byte
              lda     [.tiny (_Dp+4)],y
              sta     [.tiny _Dp],y
              rep     #0x20
3$:           lda     dp:.tiny _Dp
              ldx     dp:.tiny (_Dp+2)
              rtl

;;; ---------------------------------------------------------------------------
;;; void *memset(void *s, int c, size_t n)
;;;   In: _Dp[0-3] = s, C = c, _Dp[4-5] = n. Out: X:C = s.
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public memset
memset:       and     ##0x00ff
              sta     dp:.tiny (_Dp+6)
              xba
              ora     dp:.tiny (_Dp+6)
              sta     dp:.tiny (_Dp+6)      ; c in both bytes
              ldy     ##0
              lda     dp:.tiny (_Dp+4)
              lsr     a                     ; carry = n & 1, the loop keeps it
              tax
              lda     dp:.tiny (_Dp+6)
              inx
              dex
              beq     2$
1$:           sta     [.tiny _Dp],y
              iny
              iny
              dex
              bne     1$
2$:           bcc     3$
              sep     #0x20                 ; the last byte
              sta     [.tiny _Dp],y
              rep     #0x20
3$:           lda     dp:.tiny _Dp
              ldx     dp:.tiny (_Dp+2)
              rtl
