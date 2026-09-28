;;; Patch drawing into the SHR back buffer.
;;;
;;; Each patch pixel is one SHR pixel (a nibble). There is a nibble table
;;; of 1 KB for each of the 16 palettes, with four parts of 256 entries:
;;; left pixel even row, left pixel odd row, right pixel even row, right
;;; pixel odd row. iigs_rowpageL and iigs_rowpageR give the page of the
;;; table for each screen row and pixel side, so the table index of a
;;; pixel is page << 8 | Doom color. The tables are made by I_BuildNibtab
;;; and I_SetRows in i_viigs.c.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "memmap.inc"

              .extern _Dp, iigs_rowpageL, iigs_rowpageR, I_MarkRect
              .public IIGS_DrawPatch, iigs_capture, IIGS_TextCode, IIGS_RunText

BUF_BANK      .equ    0x01
ROW0          .equ    0x2000
NIBTAB        .equ    MM_NIBTAB
CAPVAL        .equ    MM_CAPVAL       ; see IIGS_TextCode and src/iigs/iigs.scm
CAPMSK        .equ    MM_CAPMSK
TEXTCODE      .equ    MM_TEXTCODE

              .section ztiny, bss
PX:           .space  2               ; SHR x of the patch column
PY:           .space  2               ; SHR y of the patch top
PATCH:        .space  4
COLP:         .space  4               ; current column / post
WIDTH:        .space  2
COL:          .space  2
DEST:         .space  2               ; buffer address in BUF_BANK
NTP:          .space  4               ; row page table, minus 3 for the post header
MASK:         .space  2               ; the nibble of the byte to keep
LEFT:         .space  2               ; byte offset in the row
TMPB:         .space  2
PAGEB:        .space  2               ; iigs_rowpageL or iigs_rowpageR
CNT:          .space  2
CAPLO:        .space  2               ; the lowest and highest byte written while
CAPHI:        .space  2               ; iigs_capture is set

              .section znear, bss
iigs_capture: .space  2               ; nonzero: IIGS_DrawPatch also writes CAPVAL, CAPMSK

;;; ---------------------------------------------------------------------------
;;; void IIGS_DrawPatch(int16_t sx, int16_t sy, const patch_t __far* patch)
;;; sx, sy: SHR pixel position of the patch origin, offsets applied.
;;; In: C = sx, _Dp[0-1] = sy, _Dp[4-7] = patch. The rectangle of the patch
;;; in the screen is marked (I_MarkRect of src/iigs/i_viigs65.s).
;;; ---------------------------------------------------------------------------
              .section farcode, text
IIGS_DrawPatch:
              sta     dp:.tiny PX
              lda     dp:.tiny _Dp
              sta     dp:.tiny PY
              lda     dp:.tiny (_Dp+4)
              sta     dp:.tiny PATCH
              lda     dp:.tiny (_Dp+6)
              sta     dp:.tiny (PATCH+2)
              lda     [.tiny PATCH]         ; width
              sta     dp:.tiny WIDTH
              jsr     .kbank markPatch
              stz     dp:.tiny COL
              lda     ##.word2 iigs_rowpageL
              sta     dp:.tiny (NTP+2)

colLoop:      lda     dp:.tiny COL
              cmp     dp:.tiny WIDTH
              bcc     1$
              rtl
1$:           lda     dp:.tiny PX           ; clip to the screen
              clc
              adc     dp:.tiny COL
              cmp     ##320
              bcc     2$
              jmp     .kbank nextCol
2$:           lsr     a
              sta     dp:.tiny LEFT
              lda     ##0x0f                ; left pixel: keep the right nibble
              ldx     ##.word0 iigs_rowpageL
              bcc     3$
              lda     ##0xf0                ; right pixel: keep the left nibble
              ldx     ##.word0 iigs_rowpageR
3$:           sta     dp:.tiny MASK
              stx     dp:.tiny PAGEB

              lda     dp:.tiny COL          ; column pointer = patch + columnofs[col]
              asl     a
              asl     a
              clc
              adc     ##8
              tay
              lda     [.tiny PATCH],y
              clc
              adc     dp:.tiny PATCH
              sta     dp:.tiny COLP
              lda     dp:.tiny (PATCH+2)
              sta     dp:.tiny (COLP+2)

postLoop:     lda     [.tiny COLP]          ; topdelta, length
              and     ##0xff
              cmp     ##0xff
              bne     4$
              jmp     .kbank nextCol
4$:           clc
              adc     dp:.tiny PY           ; SHR row
              cmp     ##200
              bcc     5$
              jmp     .kbank nextCol
5$:           tax                           ; X = row
              clc                           ; NTP = page table + row - 3
              adc     dp:.tiny PAGEB
              sec
              sbc     ##3
              sta     dp:.tiny NTP
              txa                           ; dest = ROW0 + row * 160 + left
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sta     dp:.tiny DEST         ; row * 32
              asl     a
              asl     a                     ; row * 128
              clc
              adc     dp:.tiny DEST
              adc     ##ROW0
              adc     dp:.tiny LEFT
              sta     dp:.tiny DEST
              lda     [.tiny COLP]          ; length, clipped to row 199
              xba
              and     ##0xff
              sta     dp:.tiny CNT
              stx     dp:.tiny TMPB
              txa
              clc
              adc     dp:.tiny CNT
              cmp     ##201
              bcc     6$
              lda     ##200                 ; count = 200 - row
              sec
              sbc     dp:.tiny TMPB
              sta     dp:.tiny CNT
6$:           lda     dp:.tiny CNT
              beq     endPost

              ldy     ##3                   ; first data byte
              lda     .near iigs_capture
              beq     8$
              jmp     .kbank capPost
8$:           phb
              sep     #0x20
              lda     #BUF_BANK
              pha
              plb
pixLoop:      lda     [.tiny NTP],y         ; table page of the row
              xba
              lda     [.tiny COLP],y        ; Doom color
              tax
              lda     long:NIBTAB,x
              sta     dp:.tiny TMPB
              lda     (.tiny DEST)
              and     dp:.tiny MASK
              ora     dp:.tiny TMPB
              sta     (.tiny DEST)
              lda     dp:.tiny DEST         ; next row
              clc
              adc     #160
              sta     dp:.tiny DEST
              bcc     7$
              inc     dp:.tiny (DEST+1)
7$:           iny
              dec     dp:.tiny CNT
              bne     pixLoop
              rep     #0x20
              plb

endPost:      lda     [.tiny COLP]          ; next post = data + length + 1
              xba
              and     ##0xff
              clc
              adc     ##3
              sec                           ; + 1 for the pad byte
              adc     dp:.tiny COLP
              sta     dp:.tiny COLP
              jmp     .kbank postLoop

nextCol:      inc     dp:.tiny COL
              jmp     .kbank colLoop

;;; markPatch: I_MarkRect of the patch rectangle in the screen: x PX ..
;;; PX + WIDTH - 1, y PY .. PY + height - 1, clipped; nothing if empty.
markPatch:    lda     dp:.tiny PX           ; the first byte: max(PX, 0) / 2
              bpl     1$
              lda     ##0
1$:           cmp     ##320
              bcs     9$
              lsr     a
              sta     dp:.tiny TMPB
              lda     dp:.tiny PX           ; the last byte: min(PX + w - 1, 319) / 2
              clc
              adc     dp:.tiny WIDTH
              dec     a
              bmi     9$
              cmp     ##320
              bcc     2$
              lda     ##319
2$:           lsr     a
              cmp     dp:.tiny TMPB
              bcc     9$
              xba
              ora     dp:.tiny TMPB
              sta     dp:.tiny CNT          ; (the bytes)
              ldy     ##2                   ; the row after the last:
              lda     [.tiny PATCH],y       ;   min(PY + height, 200)
              clc
              adc     dp:.tiny PY
              bmi     9$
              beq     9$
              cmp     ##200
              bcc     3$
              lda     ##200
3$:           tax
              lda     dp:.tiny PY           ; the first: max(PY, 0)
              bpl     4$
              lda     ##0
4$:           ldy     dp:.tiny CNT
              jsl     long:I_MarkRect       ; (first >= last: nothing)
9$:           rts

;;; capPost: the post of pixLoop, and each byte it writes also goes to CAPVAL
;;; with its written nibbles in CAPMSK (at the offset of the byte in the
;;; buffer bank).
capPost:      phb
              sep     #0x20
              lda     #BUF_BANK
              pha
              plb
1$:           lda     [.tiny NTP],y         ; table page of the row
              xba
              lda     [.tiny COLP],y        ; Doom color
              tax
              lda     long:NIBTAB,x
              sta     dp:.tiny TMPB
              lda     (.tiny DEST)
              and     dp:.tiny MASK
              ora     dp:.tiny TMPB
              sta     (.tiny DEST)
              ldx     dp:.tiny DEST
              lda     long:CAPVAL,x
              and     dp:.tiny MASK
              ora     dp:.tiny TMPB
              sta     long:CAPVAL,x
              lda     dp:.tiny MASK
              eor     #0xff
              ora     long:CAPMSK,x
              sta     long:CAPMSK,x
              cpx     dp:.tiny CAPLO
              bcs     2$
              stx     dp:.tiny CAPLO
2$:           cpx     dp:.tiny CAPHI
              bcc     3$
              stx     dp:.tiny CAPHI
3$:           lda     dp:.tiny DEST         ; next row
              clc
              adc     #160
              sta     dp:.tiny DEST
              bcc     4$
              inc     dp:.tiny (DEST+1)
4$:           iny
              dec     dp:.tiny CNT
              bne     1$
              rep     #0x20
              plb
              jmp     .kbank endPost

;;; ---------------------------------------------------------------------------
;;; void IIGS_TextCode(uint16_t slot)     In: C = slot 0 or 1.
;;; The code at TEXTCODE + slot * 0x4000 that writes again each byte of the
;;; capture: for a byte with written nibbles m and value v,
;;;   lda abs:byte / and #~m / ora #v / sta abs:byte
;;; (8-bit A, DBR = the buffer bank), then RTL. Clears the capture.
;;; IIGS_BeginCapture before the drawing: an empty capture.
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public IIGS_BeginCapture
IIGS_BeginCapture:
              lda     ##0xffff
              sta     dp:.tiny CAPLO
              stz     dp:.tiny CAPHI
              lda     ##1
              sta     .near iigs_capture
              rtl

IIGS_TextCode:
              stz     .near iigs_capture
              xba                           ; slot * 0x4000
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sta     dp:.tiny COLP
              lda     ##.word2 TEXTCODE
              sta     dp:.tiny (COLP+2)
              ldy     ##0
              ldx     dp:.tiny CAPLO
              cpx     dp:.tiny CAPHI
              beq     1$
              bcs     9$                    ; nothing drawn
1$:           lda     long:CAPMSK,x
              and     ##0x00ff
              beq     8$
              eor     ##0x09ff              ; ~m, then the ora opcode
              sta     dp:.tiny TMPB
              txa                           ; lda abs:byte
              xba
              and     ##0xff00
              ora     ##0x00ad
              sta     [.tiny COLP],y
              iny
              iny
              txa
              xba
              and     ##0x00ff
              ora     ##0x2900              ; and #
              sta     [.tiny COLP],y
              iny
              iny
              lda     dp:.tiny TMPB         ; ~m, ora #
              sta     [.tiny COLP],y
              iny
              iny
              lda     long:CAPVAL,x         ; v, sta abs
              and     ##0x00ff
              ora     ##0x8d00
              sta     [.tiny COLP],y
              iny
              iny
              txa
              sta     [.tiny COLP],y
              iny
              iny
              sep     #0x20                 ; clear the capture of the byte
              lda     #0
              sta     long:CAPMSK,x
              sta     long:CAPVAL,x
              rep     #0x20
8$:           inx
              cpx     dp:.tiny CAPHI
              bcc     1$
              beq     1$
9$:           lda     ##0x006b              ; rtl
              sta     [.tiny COLP],y
              rtl

;;; void IIGS_RunText(uint16_t slot)      In: C = slot.
IIGS_RunText:
              xba
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sta     dp:.tiny COLP
              lda     ##.word2 TEXTCODE
              sta     dp:.tiny (COLP+2)
              phb
              sep     #0x20
              lda     #BUF_BANK
              pha
              plb
              jsl     long:textDispatch
              rep     #0x20
              plb
              rtl

textDispatch: .byte   0xdc                  ; jml [COLP]
              .word   .word0 COLP
