;;; Apple IIgs low level helpers.

              .rtmodel version, "1"
              .rtmodel core, "*"

              .extern _Dp, iigs_mouseon, IIGS_StopInterrupts

#include "tics.inc"

MOUSEDATA     .equ    0xe0c024          ; the mouse: X, then Y
ADBDATA       .equ    0xe0c026          ; ADB microcontroller: command, data
ADBSTATUS     .equ    0xe0c027          ; bit 7: a mouse report, bit 5: a byte
                                        ;   from it, bit 1: mouse Y next,
                                        ;   bit 0: the command not taken yet
ADB_TALKKBD   .equ    0xc2              ; Talk register 0 of ADB address 2
ADB_SETMODES  .equ    0x04              ; commands with a mode byte
ADB_CLEARMODES .equ   0x05
ADB_RESETSYS  .equ    0x10              ; the reset of Control-Reset
ADB_KBDSRQON  .equ    0x52              ; service requests of ADB address 2 on
ADB_NOKBDPOLL .equ    0x01              ; mode: it does not poll the keyboard
ADB_ANSWER    .equ    0x80              ; a byte from it: an answer (bits 0-2:
                                        ;   its bytes - 1, 0: none), or not
ADB_KBDSRQ    .equ    0x08              ;   the keyboard asks for a Talk
ZIPCANCEL     .equ    0xe0c05f          ; the AN3 soft switch (on, as it is):
                                        ;   a write ends a ZipGS delay
ZIPSETTINGS   .equ    0xe0c059          ; ZipGS: its settings (unlocked)
ZIPLOCK       .equ    0xe0c05a          ;   $5x 4 times: unlock, $Ax: lock
ZIP_ATALK     .equ    0x20              ;   settings bit 5: the AppleTalk
                                        ;   delay (5 ms at each interrupt)
MOUSE_TALK    .equ    4                 ; mouse reports for a backup Talk
ADBQ_SIZE     .equ    32                ; a power of 2
ADB_MOUSE0    .equ    0x7e              ; the mouse buttons as ADB key codes
ADB_MOUSE1    .equ    0x70              ;   (no key has them)

              .section znear, bss
              .public iigs_adbq, iigs_adbqhead, iigs_adbqtail
iigs_adbq:    .space  ADBQ_SIZE         ; key bytes: bit 7 up, ADB key code
iigs_adbqhead: .space 2                 ; the next byte in (IIGS_PollKeys)
iigs_adbqtail: .space 2                 ; the next byte out (I_StartTic)
#if TICSTEP > 1
              .extern I_GetTime
              .public iigs_adbt
iigs_adbt:    .space  (2 * ADBQ_SIZE)   ; the tic (I_GetTime) of each byte
#endif
adbTalk:      .space  2                 ; 1: a Talk is out
adbHalt:      .space  2                 ; 1: no more Talks (IIGS_StopKeys)
adbByte:      .space  2                 ; the last byte from the ADB
mouseCount:   .space  2                 ; mouse reports since the last Talk
              .public iigs_mousedx, iigs_mousedy
iigs_mousedx: .space  2                 ; the mouse moves since G_BuildTiccmd
iigs_mousedy: .space  2                 ;   took them (Y: down is positive)
mouseX:       .space  2                 ; the X and Y bytes of the mouse
mouseY:       .space  2
mouseUp:      .space  2                 ; bits 7, 6: buttons 0, 1 are up
zipSettings:  .space  2                 ; the ZipGS settings of the user
cDst:         .space  4
cSrc:         .space  4
cLen:         .space  4
cN:           .space  2
;;; Display-only damage tint. Not part of the player: the demos do not
;;; read these. tintSave is the level's real tint-8 view row.
              .public tintPeak, tintLeft, tintShow, tintUntil
              .public tintMark, tintMarkG, tintSave, tintOut, tintC0, tintC8
tintPeak:     .space  2
tintLeft:     .space  2
tintShow:     .space  2
tintUntil:    .space  2
tintMark:     .space  2
tintMarkG:    .space  2
tintSave:     .space  32
tintOut:      .space  32
tintC0:       .space  2
tintC8:       .space  2

;;; ***************************************************************************
;;;
;;; IIGS_PollKeys - collect keyboard transitions and mouse reports.
;;;
;;; IIGS_StartKeys disables automatic keyboard polling. A keyboard service
;;; request (ADB_KBDSRQ) starts a Talk to register 0; adbTalk prevents a
;;; second request before the answer, and adbHalt blocks new Talks at exit.
;;; Drain data answers before mouse reports so the response bytes are read
;;; promptly. Empty answers carry no keys; unrelated answer bytes are skipped.
;;; Key bytes enter iigs_adbq: bit 7 means release, bits 0-6 identify the
;;; physical ADB key, and $FF is ignored. I_StartTic consumes this ring.
;;;
;;; Always drain mouse reports, including when mouse input is disabled, to
;;; clear their interrupt. When enabled, accumulate motion in iigs_mousedx/y
;;; and enqueue button transitions as ADB_MOUSE0/ADB_MOUSE1. Every MOUSE_TALK
;;; reports, attempt a backup keyboard Talk so sustained mouse traffic does
;;; not depend solely on service-request delivery.
;;; A, X, Y, DBR and D are preserved; entry allows either index-register width.
;;;
;;; ***************************************************************************

              .section farcode, text
              .public IIGS_PollKeys
IIGS_PollKeys:
              php
              rep     #0x20
              pha
              sep     #0x20
1$:           lda     long:ADBSTATUS        ; a byte from the microcontroller
              and     #0x20
              beq     7$
              lda     long:ADBDATA
              sta     long:adbByte
              bpl     3$
              and     #0x07                 ; an answer: the keys of the Talk,
              beq     2$                    ;   else its bytes are skipped
              lda     long:adbTalk
              beq     21$
              jsr     .kbank keyBytes
              bra     2$
21$:          jsr     .kbank skipBytes
2$:           lda     #0
              sta     long:adbTalk
3$:           lda     long:adbByte          ; the keyboard asks for a Talk
              and     #ADB_KBDSRQ           ;   (else it asks again)
              beq     1$
              jsr     .kbank talk
              bra     1$
7$:           lda     long:ADBSTATUS        ; a mouse report (read also when
              bpl     9$                    ;   the mouse is off: it holds its
              jsr     .kbank mouseBytes     ;   interrupt)
              lda     long:mouseCount       ; a backup Talk while the mouse
              inc     a                     ;   moves
              sta     long:mouseCount
              cmp     #MOUSE_TALK
              bcc     9$
              jsr     .kbank talk
9$:           rep     #0x20
              pla
              plp
              rtl

;;; talk: request keyboard register 0 if no Talk is pending, shutdown has
;;; not started and the command register is free. ZIPCANCEL clears any
;;; accelerator delay after the command write. Requires 8-bit A.
talk:         lda     long:adbTalk
              ora     long:adbHalt
              bne     9$
              lda     long:ADBSTATUS
              lsr     a
              bcs     9$
              lda     #ADB_TALKKBD
              sta     long:ADBDATA
              sta     long:ZIPCANCEL
              lda     #1
              sta     long:adbTalk
              lda     #0
              sta     long:mouseCount
9$:           rts

;;; keyBytes: the two key bytes of an answer into iigs_adbq.
;;; skipBytes: the bytes of an answer (adbByte) to no Talk are skipped.
;;; mouseBytes: the X and Y bytes of the mouse: the moves, the buttons
;;; (when iigs_mouseon is set).
;;; 8-bit A; X, Y and DBR stay.
keyBytes:     phb
              rep     #0x10
              phx
              phy
              lda     #.byte2 adbTalk
              pha
              plb
              jsr     .kbank keyByte
              jsr     .kbank keyByte
              brl     restore
skipBytes:    phb
              rep     #0x10
              phx
              phy
              rep     #0x20                 ; bits 0-2 + 1 bytes
              lda     long:adbByte
              and     ##0x0007
              tax
              inx
              sep     #0x20
1$:           jsr     .kbank answerByte
              bcs     restore
              dex
              bne     1$
              bra     restore
mouseBytes:   phb
              rep     #0x10
              phx
              phy
              lda     #.byte2 adbTalk
              pha
              plb
              lda     long:ADBSTATUS
              and     #0x02
              beq     1$
              lda     long:MOUSEDATA        ; Y is next (out of step): read it
              bra     restore
1$:           lda     long:MOUSEDATA        ; X: bit 7 button 1 up, the move
              sta     .near mouseX
              lda     long:MOUSEDATA        ; Y: bit 7 button 0 up, the move
              sta     .near mouseY
              lda     .near iigs_mouseon
              beq     restore
              rep     #0x20
              lda     .near mouseX
              jsr     .kbank mouseMove
              clc
              adc     .near iigs_mousedx
              sta     .near iigs_mousedx
              lda     .near mouseY
              jsr     .kbank mouseMove
              clc
              adc     .near iigs_mousedy
              sta     .near iigs_mousedy
              sep     #0x20
              lda     .near mouseX          ; the buttons (bit 7: button 0 up,
              lsr     a                     ;   bit 6: button 1 up), a key
              and     #0x40                 ;   byte for each change
              sta     .near mouseX
              lda     .near mouseY
              and     #0x80
              ora     .near mouseX
              pha
              eor     .near mouseUp
              sta     .near mouseY          ; the changes
              pla
              sta     .near mouseUp
              bit     .near mouseY
              bpl     2$
              lda     #ADB_MOUSE0
              jsr     .kbank buttonByte
2$:           bit     .near mouseY
              bvc     restore
              lda     #ADB_MOUSE1
              jsr     .kbank buttonByte
restore:      ply
              plx
              plb
              rts

;;; mouseMove: C = the move of the mouse byte C (bits 0-6, two's
;;; complement). 16-bit A.
mouseMove:    and     ##0x007f
              cmp     ##0x0040
              bcc     1$
              ora     ##0xff80
1$:           rts

;;; buttonByte: the key byte of the mouse button A (ADB_MOUSE0 or
;;; ADB_MOUSE1) into iigs_adbq: down, or up when its bit in mouseUp is set.
;;; 8-bit A, 16-bit X.
buttonByte:   cmp     #ADB_MOUSE0
              bne     1$
              bit     .near mouseUp         ; bit 7: button 0 up
              bpl     queueByte
              bra     2$
1$:           bit     .near mouseUp         ; bit 6: button 1 up
              bvc     queueByte
2$:           ora     #0x80
              bra     queueByte

;;; keyByte: the next key byte of an answer into iigs_adbq ($FF: none; lost
;;; when the ring is full). 8-bit A, 16-bit X and Y.
keyByte:      jsr     .kbank answerByte
              bcs     9$
              cmp     #0xff
              bne     queueByte
9$:           rts

;;; answerByte: A = the next byte of an answer, carry clear; carry set when
;;; it does not come. The byte comes about 0.2 ms after the one before; the
;;; wait stops after about 20 ms at 2.8 MHz. 8-bit A, 16-bit Y.
answerByte:   ldy     ##4096
1$:           lda     long:ADBSTATUS
              and     #0x20
              bne     2$
              dey
              bne     1$
              sec
              rts
2$:           lda     long:ADBDATA
              clc
              rts

;;; queueByte: the key byte A into iigs_adbq (lost when the ring is full),
;;; with TICSTEP > 1 its tic into iigs_adbt. 8-bit A, 16-bit X, DBR = the
;;; near bank.
queueByte:    ldx     .near iigs_adbqhead
              sta     abs:.near iigs_adbq,x
#if TICSTEP > 1
              rep     #0x20
              txa
              asl     a
              pha
              jsl     long:I_GetTime
              plx
              sta     abs:.near iigs_adbt,x
              txa
              lsr     a
              tax
              sep     #0x20
#endif
              inx
              cpx     ##ADBQ_SIZE
              bcc     1$
              ldx     ##0
1$:           cpx     .near iigs_adbqtail
              beq     9$
              stx     .near iigs_adbqhead
9$:           rts

;;; ***************************************************************************
;;;
;;; IIGS_MouseUp - the mouse buttons that are down go up (key bytes), the
;;; moves are 0: for a change of iigs_mouseon.
;;;
;;; It shares the code section of IIGS_PollKeys (buttonByte).
;;;
;;; ***************************************************************************

              .public IIGS_MouseUp
IIGS_MouseUp: php
              rep     #0x30
              stz     .near iigs_mousedx
              stz     .near iigs_mousedy
              sep     #0x20
              lda     .near mouseUp
              eor     #0xc0                 ; the buttons that are down
              sta     .near mouseY
              lda     #0xc0
              sta     .near mouseUp
              bit     .near mouseY
              bpl     1$
              lda     #ADB_MOUSE0
              jsr     .kbank buttonByte
1$:           bit     .near mouseY
              bvc     2$
              lda     #ADB_MOUSE1
              jsr     .kbank buttonByte
2$:           plp
              rtl

;;; ***************************************************************************
;;;
;;; IIGS_StartKeys, IIGS_StopKeys, IIGS_ResetSystem - the keyboard for
;;; IIGS_PollKeys (old bytes of the ADB are skipped), and back to the ADB
;;; microcontroller (a Talk that is out is read first); the reset of
;;; Control-Reset (the ADB microcontroller does not see the Reset key while
;;; the game reads the keyboard).
;;;
;;; ***************************************************************************

              .section farcode, text
              .public IIGS_StartKeys, IIGS_StopKeys, IIGS_ResetSystem
IIGS_StartKeys:
              php
              sei
              sep     #0x20
1$:           lda     long:ADBSTATUS
              and     #0x20
              beq     2$
              lda     long:ADBDATA
              bra     1$
2$:           lda     #ADB_SETMODES
              jsr     .kbank adbSend
              lda     #ADB_NOKBDPOLL
              jsr     .kbank adbSend
              lda     #ADB_KBDSRQON
              jsr     .kbank adbSend
              rep     #0x20
              stz     .near adbTalk
              stz     .near adbHalt
              stz     .near mouseCount
              stz     .near iigs_adbqhead
              stz     .near iigs_adbqtail
              stz     .near iigs_mousedx
              stz     .near iigs_mousedy
              lda     ##0xc0                ; both mouse buttons up
              sta     .near mouseUp
              plp
              rtl

IIGS_StopKeys:
              php
              rep     #0x30
              lda     ##1                   ; no more Talks
              sta     .near adbHalt
1$:           lda     .near adbTalk
              beq     2$
              jsl     long:IIGS_PollKeys    ; the answer of the Talk
              bra     1$
2$:           sep     #0x20
              lda     #ADB_CLEARMODES
              jsr     .kbank adbSend
              lda     #ADB_NOKBDPOLL
              jsr     .kbank adbSend
              plp
              rtl

IIGS_ResetSystem:
              jsl     long:IIGS_StopInterrupts
              jsl     long:IIGS_StopKeys
              sep     #0x20
              lda     #ADB_RESETSYS
              jsr     .kbank adbSend
1$:           bra     1$

;;; adbSend: the byte A (8-bit) to the ADB microcontroller when its command
;;; register is free; the ZipGS delay of MAME ends.
adbSend:      pha
1$:           lda     long:ADBSTATUS
              lsr     a
              bcs     1$
              pla
              sta     long:ADBDATA
              sta     long:ZIPCANCEL
              rts

;;; ***************************************************************************
;;;
;;; IIGS_ZipOff, IIGS_ZipBack - no AppleTalk delay of a ZipGS while the game
;;; runs (with it, the Zip runs slow for 5 ms at each interrupt: the game
;;; interrupt comes every 20 ms), and the settings of the user back.
;;;
;;; A ZipGS takes a write to its settings register only when it is unlocked:
;;; four writes of $5x to ZIPLOCK with no other write between them (so no
;;; interrupt), then $Ax locks it. The ZipGS manual gives the AppleTalk delay
;;; off as the default (DIP switch SW1/3). Without a ZipGS these are reads
;;; and writes of the annunciator soft switches AN0 and AN1, which the game
;;; does not use.
;;;
;;; ***************************************************************************

              .section farcode, text
              .public IIGS_ZipOff, IIGS_ZipBack
IIGS_ZipOff:  php
              sei
              sep     #0x20
              jsr     .kbank zipUnlock
              lda     long:ZIPSETTINGS
              sta     long:zipSettings
              and     #0xff - ZIP_ATALK
              bra     zipSet

IIGS_ZipBack: php
              sei
              sep     #0x20
              jsr     .kbank zipUnlock
              lda     long:zipSettings

;;; zipSet: the settings A, the ZipGS locked; then plp, rtl.
zipSet:       sta     long:ZIPSETTINGS
              lda     #0xa5
              sta     long:ZIPLOCK
              plp
              rtl

;;; zipUnlock: the four unlock writes. 8-bit A.
zipUnlock:    lda     #0x5a
              sta     long:ZIPLOCK
              sta     long:ZIPLOCK
              sta     long:ZIPLOCK
              sta     long:ZIPLOCK
              rts

;;; ***************************************************************************
;;;
;;; IIGS_CopyHuge - copy any number of bytes between any 24-bit addresses.
;;;
;;; In: X:C       destination
;;;     _Dp[0-3]  source
;;;     _Dp[4-7]  length
;;;
;;; The copy is split into MVN moves that stay inside one bank at both ends.
;;; The areas must not overlap.
;;;
;;; ***************************************************************************

              .section farcode, text
              .public IIGS_CopyHuge
IIGS_CopyHuge:
              phb
              sta     long:cDst
              txa
              sta     long:cDst+2
              lda     dp:.tiny _Dp
              sta     long:cSrc
              lda     dp:.tiny (_Dp+2)
              sta     long:cSrc+2
              lda     dp:.tiny (_Dp+4)
              sta     long:cLen
              lda     dp:.tiny (_Dp+6)
              sta     long:cLen+2

nextChunk:    lda     long:cLen
              ora     long:cLen+2
              bne     1$
              jmp     .kbank done
1$:
              ;; cN = bytes to move minus one
              lda     long:cSrc
              eor     ##0xffff
              sta     long:cN
              lda     long:cDst
              eor     ##0xffff
              cmp     long:cN
              bcs     2$
              sta     long:cN
2$:           lda     long:cLen+2
              bne     3$
              lda     long:cLen
              dec     a
              cmp     long:cN
              bcs     3$
              sta     long:cN
3$:
              sep     #0x20
              lda     long:cDst+2
              sta     long:mvnInst+1
              lda     long:cSrc+2
              sta     long:mvnInst+2
              rep     #0x20
              lda     long:cSrc
              tax
              lda     long:cDst
              tay
              lda     long:cN
mvnInst:      .byte   0x54, 0x00, 0x00

              ;; advance source and destination by cN + 1, reduce length
              clc
              lda     long:cSrc
              adc     long:cN
              sta     long:cSrc
              lda     long:cSrc+2
              adc     ##0
              sta     long:cSrc+2
              clc
              lda     long:cSrc
              adc     ##1
              sta     long:cSrc
              lda     long:cSrc+2
              adc     ##0
              sta     long:cSrc+2

              clc
              lda     long:cDst
              adc     long:cN
              sta     long:cDst
              lda     long:cDst+2
              adc     ##0
              sta     long:cDst+2
              clc
              lda     long:cDst
              adc     ##1
              sta     long:cDst
              lda     long:cDst+2
              adc     ##0
              sta     long:cDst+2

              sec
              lda     long:cLen
              sbc     long:cN
              sta     long:cLen
              lda     long:cLen+2
              sbc     ##0
              sta     long:cLen+2
              sec
              lda     long:cLen
              sbc     ##1
              sta     long:cLen
              lda     long:cLen+2
              sbc     ##0
              sta     long:cLen+2
              jmp     .kbank nextChunk

done:         plb
              rtl
