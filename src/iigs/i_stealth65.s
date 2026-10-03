;;; Apple IIe/J13 compatibility keyboard. See docs/stealth-keyboard.md.
;;; This section occupies a previously empty hole after ENDOOM. No normal
;;; ADB instruction, table or variable moves; only startup calls this code.
;;; Compatibility mode patches the two existing tic-call operands once.

              .rtmodel version, "1"
              .rtmodel core, "*"
#include "tics.inc"
#include "keys.inc"
              .extern IIGS_StartKeys, I_StartTic, I_GetTime
              .extern keyboardTicCall, keyboardBuildCall, keyDefaults, keyTable
              .extern adbHalt, mouseUp, iigs_adbq, iigs_adbqhead, iigs_adbqtail
#if TICSTEP > 1
              .extern I_StartTicUntil, iigs_adbt
#endif
KBD           .equ    0xe0c000
AKD           .equ    0xe0c010
MODIFIERS     .equ    0xe0c025
ADBDATA       .equ    0xe0c026
ADBSTATUS     .equ    0xe0c027
BUTTON0       .equ    0xe0c061
BUTTON1       .equ    0xe0c062
ZIPCANCEL     .equ    0xe0c05f
NONE          .equ    0xff

              .section stealthcode, text
              .public IIGS_SelectKeyboard, IIGS_PollStealth
              .public I_StealthStartTic, stealthMode, stealthKey, stealthMods
              .public stealthSample, stealthAKD, stealthNextMods
IIGS_SelectKeyboard:
              php
              sei
              rep     #0x30
              pha
              phx
              phy
              lda     ##0
              sta     long:stealthMode
              sta     long:stealthMods
              sta     long:stealthNextMods
              sta     long:stealthSample
              sta     long:stealthAKD
              lda     ##NONE
              sta     long:stealthKey
              sep     #0x20
              lda     long:KBD               ; Hold K at startup: explicit
              and     #0x5f                  ; compatibility-mode override.
              cmp     #'K'
              bne     detect
              lda     long:AKD
              bmi     compatibility

detect:       ldy     ##256                 ; Drain old controller messages.
1$:           lda     long:ADBSTATUS
              and     #0x20
              beq     2$
              lda     long:ADBDATA
              dey
              bne     1$
              bra     compatibility
2$:           lda     #0xf2                 ; Talk register 3, ADB address 2.
              jsr     .kbank sendBounded
              bcs     compatibility
              ldx     ##16                  ; Ignore bounded status messages.
3$:           jsr     .kbank readBounded
              bcs     compatibility
              bit     #0x80
              bne     4$
              dex
              bne     3$
              bra     compatibility
4$:           and     #0x07                 ; 0 = no reply; otherwise n-1.
              beq     compatibility
              rep     #0x20
              and     ##0x00ff
              inc     a
              tax
              sep     #0x20
5$:           jsr     .kbank readBounded     ; Consume the entire reply.
              bcs     compatibility
              dex
              bne     5$
              rep     #0x30
              ply
              plx
              pla
              plp
              jmp     long:IIGS_StartKeys   ; Exactly the original ADB setup.

compatibility:
              rep     #0x30
              lda     ##1
              sta     long:stealthMode      ; Absence is not J13 detection.
              sta     long:adbHalt          ; Mouse service stays; no raw Talks.
              lda     ##0
              sta     long:iigs_adbqhead
              sta     long:iigs_adbqtail
              lda     ##0xc0
              sta     long:mouseUp
              lda     ##.word0 I_StealthStartTic
              sta     long:(keyboardTicCall+1)
              sep     #0x20
              lda     #.byte2 I_StealthStartTic
              sta     long:(keyboardTicCall+3)
              rep     #0x20
#if TICSTEP > 1
              lda     ##.word0 I_StealthStartTicUntil
#else
              lda     ##.word0 I_StealthStartTic
#endif
              sta     long:(keyboardBuildCall+1)
              sep     #0x20
#if TICSTEP > 1
              lda     #.byte2 I_StealthStartTicUntil
#else
              lda     #.byte2 I_StealthStartTic
#endif
              sta     long:(keyboardBuildCall+3)
              lda     #KEY_FIRE             ; Open Apple fires in this mode;
              sta     long:(keyDefaults+2*0x37) ; avoids the TN58 Ctrl/Shift bug.
              sta     long:(keyTable+2*0x37)
              lda     #0x05                 ; Leave firmware keyboard autopoll
              jsr     .kbank sendBounded    ; enabled for compatibility input.
              bcs     selected
              lda     #0x01
              jsr     .kbank sendBounded
              bcs     selected
              lda     #0x03                 ; Flush pre-game characters.
              jsr     .kbank sendBounded
              lda     long:AKD              ; Acknowledge the startup key.
selected:     rep     #0x30
              ply
              plx
              pla
              plp
              rtl

;;; 8-bit A, 16-bit X/Y. Carry set means timeout. Commands and data are
;;; bounded even with no keyboard/controller reply. The original ADB route
;;; keeps its existing initialization and IRQ routines.
sendBounded:  pha
              ldy     ##16384
1$:           lda     long:ADBSTATUS
              and     #1
              beq     2$
              dey
              bne     1$
              pla
              sec
              rts
2$:           pla
              sta     long:ADBDATA
              sta     long:ZIPCANCEL
              clc
              rts
readBounded:  ldy     ##16384
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

I_StealthStartTic:
              jsl     long:IIGS_PollStealth
              jmp     long:I_StartTic
#if TICSTEP > 1
              .public I_StealthStartTicUntil
I_StealthStartTicUntil:
              jsl     long:IIGS_PollStealth
              jmp     long:I_StartTicUntil
#endif

;;; One ordinary key plus five independent modifiers. There is no ordinary
;;; key-up identity in C000/C010: replacement or AKD=0 releases our key.
;;; Reserve all eight possible transitions before acknowledging C000. With
;;; a full ring we change no state and leave the strobe for the next tic.
;;; IRQ producer cannot interleave these writes. The original consumer still
;;; keeps a down/up pair alive for at least one tic and performs menu repeat.
IIGS_PollStealth:
              php
              sei
              rep     #0x30
              pha
              phx
              phy
              lda     long:iigs_adbqtail
              sec
              sbc     long:iigs_adbqhead
              dec     a
              and     ##31
              cmp     ##8
              bcs     sample
              brl     pollDone
sample:
#if TICSTEP > 1
              jsl     long:I_GetTime
              sta     long:stealthTic
#endif
              sep     #0x20
              lda     long:KBD               ; Always read strobe before AKD.
              sta     long:stealthSample
              lda     long:MODIFIERS
              and     #7                    ; Shift, Control, Caps Lock.
              sta     long:stealthNextMods
              lda     long:BUTTON0           ; Live Apple button inputs.
              bpl     1$
              lda     long:stealthNextMods
              ora     #0x80
              sta     long:stealthNextMods
1$:           lda     long:BUTTON1
              bpl     2$
              lda     long:stealthNextMods
              ora     #0x40
              sta     long:stealthNextMods
2$:           lda     long:AKD
              sta     long:stealthAKD
              rep     #0x20
              lda     long:stealthNextMods
              eor     long:stealthMods
              sta     long:stealthChanged
              ldx     ##0
modifierLoop: lda     long:modifierMasks,x
              and     ##0x00ff
              and     long:stealthChanged
              beq     modifierNext
              lda     long:modifierMasks,x
              and     ##0x00ff
              and     long:stealthNextMods
              beq     modifierUp
              lda     long:modifierKeys,x
              and     ##0x00ff
              bra     modifierSend
modifierUp:   lda     long:modifierKeys,x
              and     ##0x00ff
              ora     ##0x80
modifierSend: jsr     .kbank queue
modifierNext: inx
              cpx     ##5
              bcc     modifierLoop
              lda     long:stealthNextMods
              sta     long:stealthMods
              lda     long:stealthSample
              bit     ##0x80
              beq     testRelease
              and     ##0x7f
              tax
              lda     long:asciiKeys,x
              and     ##0x00ff
              cmp     long:stealthKey
              beq     testRelease            ; Firmware repeats are not edges.
              pha
              jsr     .kbank releaseOrdinary
              pla
              sta     long:stealthKey
              cmp     ##NONE
              beq     testRelease
              jsr     .kbank queue

testRelease:  lda     long:stealthAKD
              bit     ##0x80
              bne     pollDone
              jsr     .kbank releaseOrdinary
pollDone:     ply
              plx
              pla
              plp
              rtl

releaseOrdinary:
              lda     long:stealthKey
              cmp     ##NONE
              beq     1$
              ora     ##0x80
              jsr     .kbank queue
              lda     ##NONE
              sta     long:stealthKey
1$:           rts

;;; A = event byte, full-width registers; capacity already reserved, IRQ off.
queue:        phx
              pha
              lda     long:iigs_adbqhead
              tax
              pla
              sep     #0x20
              sta     long:iigs_adbq,x
              rep     #0x20
#if TICSTEP > 1
              txa
              asl     a
              tax
              lda     long:stealthTic
              sta     long:iigs_adbt,x
              txa
              lsr     a
              tax
#endif
              inx
              txa
              and     ##31
              sta     long:iigs_adbqhead
              plx
              rts

modifierMasks: .byte 0x01, 0x02, 0x04, 0x80, 0x40
modifierKeys:  .byte 0x38, 0x36, 0x39, 0x37, 0x3a, 0

;;; ASCII identities, not hardware raw keycodes. Navigation control aliases
;;; win over letters (e.g. Ctrl-H is Left); shifted punctuation maps to its
;;; unshifted US key. Unknown characters safely replace/release an old key.
asciiKeys:
              .byte   0x31, 0x00, 0x0b, 0x08, 0x02, 0x0e, 0x03, 0x05, 0x3b, 0x30, 0x3d, 0x3e, 0x25, 0x24, 0x2d, 0x1f ; $00-$0F
              .byte   0x23, 0x0c, 0x0f, 0x01, 0x11, 0x3c, 0x09, 0x0d, 0x07, 0x10, 0x06, 0x35, 0x2a, 0x1e, 0x16, 0x1b ; $10-$1F
              .byte   0x31, 0x12, 0x27, 0x14, 0x15, 0x17, 0x1a, 0x27, 0x19, 0x1d, 0x1c, 0x18, 0x2b, 0x1b, 0x2f, 0x2c ; $20-$2F
              .byte   0x1d, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1a, 0x1c, 0x19, 0x29, 0x29, 0x2b, 0x18, 0x2f, 0x2c ; $30-$3F
              .byte   0x13, 0x00, 0x0b, 0x08, 0x02, 0x0e, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2e, 0x2d, 0x1f ; $40-$4F
              .byte   0x23, 0x0c, 0x0f, 0x01, 0x11, 0x20, 0x09, 0x0d, 0x07, 0x10, 0x06, 0x21, 0x2a, 0x1e, 0x16, 0x1b ; $50-$5F
              .byte   0x32, 0x00, 0x0b, 0x08, 0x02, 0x0e, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2e, 0x2d, 0x1f ; $60-$6F
              .byte   0x23, 0x0c, 0x0f, 0x01, 0x11, 0x20, 0x09, 0x0d, 0x07, 0x10, 0x06, 0x21, 0x2a, 0x1e, 0x32, 0x33 ; $70-$7F

;;; Explicitly initialized RAM in the fixed image, never added to near BSS.
stealthMode:     .word 0
stealthKey:      .word NONE
stealthMods:     .word 0
stealthNextMods: .word 0
stealthChanged:  .word 0
stealthSample:   .word 0
stealthAKD:      .word 0
#if TICSTEP > 1
stealthTic:      .word 0
#endif
