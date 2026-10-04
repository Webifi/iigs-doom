;;; Input from the Apple IIe keyboard of a "stealth" IIgs: a ROM 00 or ROM 01
;;; board in a IIe case, with the keyboard on the board's J13 connector. That
;;; keyboard is not an ADB device: the keyboard microcontroller scans it and
;;; posts one character at a time in $C000, any-key-down in $C010 and the
;;; modifiers in $C025. This file turns those registers into the same key
;;; down and up events the ADB code makes, and reads the microcontroller's
;;; key rows when two keys are held, to see which one was released.
;;; This section occupies a previously empty hole after ENDOOM. No normal
;;; ADB instruction, table or variable moves; J13 dispatch owns this code.
;;; Compatibility mode patches the two existing tic-call operands once.
;;; The existing music alarm captures register edges only after J13 arming.

              .rtmodel version, "1"
              .rtmodel core, "*"
#include "tics.inc"
#include "keys.inc"
#include "music.inc"
#include "viewwin.inc"
              .extern hcol, tcol, ocol, qcol, ucol
              .extern IIGS_StartKeys, I_StartTic, I_GetTime
              .extern J13ColumnSite, J13StatusSite, J13AlarmSite, adbTalk
              .extern J13SilentBranchWord
              .extern J13SilentExit, J13SilentTrampoline, IIGS_AlarmOff, musOn, musPend
              .extern _g_menuactive, _g_gamestate
              .extern keyboardTicCall, keyboardBuildCall
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
ROMVER        .equ    0xfffb59

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
              lda     long:ROMVER
              cmp     #2
              bcs     adbPlain
              jsr     .kbank identifyMatrix
              jsr     .kbank installProbe
adbPlain:     rep     #0x30
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
              jsr     .kbank identifyMatrix
              jsr     .kbank installProbe
              sep     #0x20
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

installProbe:
              rep     #0x20
              lda     ##.word0 I_BesideTic
              sta     long:(keyboardTicCall+1)
              sep     #0x20
              lda     #.byte2 I_BesideTic
              sta     long:(keyboardTicCall+3)
              rep     #0x20
#if TICSTEP > 1
              lda     ##.word0 I_BesideTicUntil
#else
              lda     ##.word0 I_BesideTic
#endif
              sta     long:(keyboardBuildCall+1)
              sep     #0x20
#if TICSTEP > 1
              lda     #.byte2 I_BesideTicUntil
#else
              lda     #.byte2 I_BesideTic
#endif
              sta     long:(keyboardBuildCall+3)
              rts

;;; No presence strap. No hook or modifier sampler runs before this strobe.
              .public I_BesideTic, J13Arm, j13Armed, modifierLatch
I_BesideTic:  sep     #0x20
              lda     long:KBD
              bmi     besideSeen
              rep     #0x20
              jmp     long:I_StartTic
besideSeen:   jsl     long:J13Arm
              jmp     long:I_StealthStartTic
#if TICSTEP > 1
I_BesideTicUntil:
              pha
              sep     #0x20
              lda     long:KBD
              bpl     besideUntilDone
              jsl     long:J13Arm
              jsl     long:IIGS_PollStealth
besideUntilDone:
              rep     #0x20
              pla
              jmp     long:I_StartTicUntil
#endif
I_StealthStartTic:
              jsl     long:IIGS_PollStealth
              jmp     long:I_StartTic
#if TICSTEP > 1
              .public I_StealthStartTicUntil
I_StealthStartTicUntil:
              pha
              jsl     long:IIGS_PollStealth
              pla
              jmp     long:I_StartTicUntil
#endif

;;; Arm the existing-wake capture and the stopped-music extension once.
;;; The image below C000 is copied back after each disk operation. No
;;; vectors, SCBs or ADB code are changed. Silent sampling shares oscillator 30.
J13Arm:      jmp     long:J13ArmSilent
              pha
              lda     ##1
              sta     long:j13Armed
              lda     ##.word0 I_StealthStartTic
              sta     long:(keyboardTicCall+1)
#if TICSTEP > 1
              lda     ##.word0 I_StealthStartTicUntil
#endif
              sta     long:(keyboardBuildCall+1)
              sep     #0x20
              lda     #.byte2 I_StealthStartTic
              sta     long:(keyboardTicCall+3)
              sta     long:(keyboardBuildCall+3)
              lda     #0x5c
              sta     long:J13AlarmSite
              sta     long:(J13AlarmSite-0x2200)
              rep     #0x20
              lda     ##.word0 J13MusicLatch
              sta     long:(J13AlarmSite+1)
              sta     long:(J13AlarmSite-0x2200+1)
              sep     #0x20
              lda     #.byte2 J13MusicLatch
              sta     long:(J13AlarmSite+3)
              sta     long:(J13AlarmSite-0x2200+3)
              rep     #0x20
              pla
              plp
              rep     #0x20
              rtl

 ; Existing music wake, after the original alarm restart. No cadence subdivision.
 ; The displaced store starts the alarm before keyboard work. X/Y/B stay intact.
              .public J13MusicLatch, captureClock, captureTics, captureAKDs
J13MusicLatch:
              sta     long:0xe0c03d
              jsr     .kbank captureStrobe
              lda     long:pumpRendering
              beq     wakeKeysDone
              lda     long:pumpState
              beq     wakeKeysDone
              cmp     #5
              beq     wakeKeysDone          ; Retire an expired transfer at the poll.
              rep     #0x20
              pha
              sep     #0x20
              jsr     .kbank pumpCore        ; At most one status read; never waits.
              rep     #0x20
              pla
              sep     #0x20
wakeKeysDone: jmp     long:(J13AlarmSite+4)

 ; Capture a fresh character or an all-up edge, in chronological FIFO order.
 ; Queue capacity is checked before acknowledging C010. One read of each register.
captureStrobe:
              lda     long:captureHead
              inc     a
              and     #15
              cmp     long:captureTail
              bne     captureRoom
              rts
captureRoom:  lda     long:KBD
              sta     long:captureSample
              lda     long:MODIFIERS
              sta     long:captureModSample
              ora     long:modifierLatch
              sta     long:modifierLatch
              lda     long:AKD
              sta     long:captureAKDSample
              eor     long:captureLastAKD
              and     #0x80
              bne     captureChangedAKD
              lda     long:captureSample
              bpl     captureDone
              lda     long:captureModSample
              bit     #8
              beq     capturePush
              rts
captureChangedAKD:
              lda     long:captureAKDSample
              sta     long:captureLastAKD
              lda     long:captureSample
              bpl     captureNoFresh
              lda     long:captureModSample
              bit     #8
              beq     capturePush
captureNoFresh:
              lda     long:captureAKDSample
              bmi     captureDone           ; AKD can rise before the ASCII write.
              lda     long:captureSample
              and     #0x7f                 ; All-up marker, no new character.
              sta     long:captureSample
capturePush:  php
              rep     #0x30
              pha
              phx
              jsr     .kbank captureTime
              lda     long:captureHead
              asl     a
              tax
              lda     long:captureClock
              sta     long:captureTics,x
              lda     long:captureHead
              tax
              sep     #0x20
              lda     long:captureSample
              sta     long:captureAscii,x
              lda     long:captureModSample
              sta     long:captureRepeat,x
              lda     long:captureAKDSample
              sta     long:captureAKDs,x
              inx
              txa
              and     #15
              sta     long:captureHead
              rep     #0x30
              plx
              pla
              plp
captureDone:  rts

 ; Edge-only clock stamp. Check DOC once: no new wait, and no IRQ can start
 ; another access between this check and the existing clock reader.
captureTime:  sep     #0x20
              lda     long:0xe0c03c
              bmi     captureClockBusy
              phb
              lda     #.byte2 iigs_adbq
              pha
              plb
              rep     #0x20
              jsl     long:I_GetTime
              sta     long:captureClock
              plb
              rts
captureClockBusy:
              rep     #0x20
              rts

;;; Two ordinary keys plus a transient third identity and five modifiers.
;;; C010 releases all ordinary keys; individual releases need a valid row.
;;; Reserve ten slots for modifiers, pair releases, and a completed tap before acknowledging C000. With
;;; a full ring we change no state and leave the strobe for the next tic.
;;; IRQ producer cannot interleave these writes. The original consumer still
;;; keeps a down/up pair alive for at least one tic and performs menu repeat.
IIGS_PollStealth:
              jmp     long:J13PollSilent
              pha
              sep     #0x20
              lda     long:captureHead
              cmp     long:captureTail
              beq     pollNoCapture
              brl     pollActive
pollNoCapture:
              lda     long:stealthRecover
              beq     pollNoRecovery
              brl     pollActive
pollNoRecovery:
              lda     long:pumpResult
              beq     pollNoResult
              brl     pollActive
pollNoResult:
              lda     long:pumpAmbiguous
              beq     pollOrdinary
              lda     long:pumpState
              cmp     #1
              bne     pollPending
              lda     long:VW_SIZE
              cmp     long:pumpView
              beq     pollOrdinary
              bra     pollActive
pollPending:  bcs     pollActive
              rep     #0x30
              phx
              jsr     .kbank pumpSchedule
              plx
              sep     #0x20
pollOrdinary: lda     long:KBD
              bmi     pollStrobed
              cmp     long:stealthASCII     ; AKD reads can clear a concurrent strobe.
              bne     pollActive            ; A changed character still survives in C000.
              bra     pollModifiers
pollStrobed:  and     #0x7f
              cmp     long:stealthASCII
              bne     pollActive
              lda     long:stealthKey
              cmp     #NONE
              beq     pollActive
              lda     long:MODIFIERS
              bit     #8
              beq     pollActive
pollModifiers:
              lda     long:MODIFIERS
              ora     long:modifierLatch
              and     #0xc7
              cmp     long:stealthMods
              bne     pollActive
              lda     long:BUTTON0
              eor     long:stealthMods
              bmi     pollActive
              lda     long:BUTTON1
              eor     long:stealthButton1
              bmi     pollActive
              lda     long:AKD
              eor     long:stealthAKD
              bmi     pollActive
              lda     #0
              sta     long:modifierLatch
              .public pollFastDone
pollFastDone: rep     #0x20
              pla
              plp
              rtl
pollActive:   rep     #0x30
              phx
              phy
pollQueueRoom:
              lda     long:iigs_adbqtail
              sec
              sbc     long:iigs_adbqhead
              dec     a
              and     ##31
              cmp     ##10
              bcs     sample
              brl     pollDone
sample:
#if TICSTEP > 1
              jsl     long:I_GetTime
              sta     long:stealthTic
#endif
              sep     #0x20
              jsr     .kbank captureStrobe
              lda     long:captureTail
              cmp     long:captureHead
              beq     sampleLive
              rep     #0x20
              and     ##15
              tax
#if TICSTEP > 1
              asl     a
              tax
              lda     long:captureTics,x
              sta     long:stealthTic
              txa
              lsr     a
              tax
#endif
              sep     #0x20
              lda     #1
              sta     long:captureSampled
              lda     long:captureAKDs,x
              sta     long:sampleAKD
              lda     long:captureRepeat,x
              sta     long:pumpRepeat
              lda     long:captureAscii,x
              pha
              inx
              txa
              and     #15
              sta     long:captureTail
              pla
              bra     sampleSaved
sampleLive:   lda     #0
              sta     long:captureSampled
              lda     long:MODIFIERS
              sta     long:pumpRepeat
              lda     long:KBD               ; Always read strobe before AKD.
              bmi     sampleSaved
              cmp     long:stealthASCII       ; Recover a character whose strobe an
              beq     sampleSaved            ; earlier AKD read raced with. Repeat
              ora     #0x80                  ; indication is still checked below.
sampleSaved:  bit     #0x80
              beq     sampleCheckRecovery
              pha
              lda     #0
              sta     long:stealthRecover
              pla
              bra     sampleRecovered
sampleCheckRecovery:
              pha
              lda     long:stealthRecover
              beq     sampleNotRecovered
              lda     long:pumpRepeat
              bit     #0x20                 ; Wait for key-associated modifiers;
              bne     sampleNotRecovered    ; AKD can rise before the ASCII write.
              and     #0xf7
              sta     long:pumpRepeat
              lda     #0
              sta     long:stealthRecover
              pla
              ora     #0x80
              bra     sampleRecovered
sampleNotRecovered:
              pla
sampleRecovered:
              sta     long:stealthSample
              and     #0x7f
              sta     long:stealthASCII
              lda     long:MODIFIERS
              ora     long:modifierLatch
              and     #0xc7                 ; Latched modifiers, including Apple taps.
              sta     long:stealthNextMods
              lda     #0
              sta     long:modifierLatch
              lda     long:BUTTON0           ; Live Apple button inputs.
              bpl     1$
              lda     long:stealthNextMods
              ora     #0x80
              sta     long:stealthNextMods
1$:           lda     long:BUTTON1
              sta     long:stealthButton1
              bpl     2$
              lda     long:stealthNextMods
              ora     #0x40
              sta     long:stealthNextMods
2$:           lda     long:stealthAKD
              sta     long:stealthOldAKD
              lda     long:captureSampled
              beq     sampleLiveAKD
              lda     long:sampleAKD
              bra     sampleHaveAKD
sampleLiveAKD:
              lda     long:AKD
sampleHaveAKD:
              sta     long:stealthAKD
              bpl     sampleAKDDone
              eor     long:stealthOldAKD
              bpl     sampleAKDDone
              lda     long:stealthSample
              bmi     sampleAKDDone
              lda     #1                    ; A first key arrived without a saved
              sta     long:stealthRecover    ; strobe. Recover on a later poll.
sampleAKDDone:
              rep     #0x20
              lda     long:stealthNextMods
              eor     long:stealthMods
              beq     modifiersDone
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
modifiersDone:
              jsr     .kbank pumpCollect
              lda     long:stealthSample
              bit     ##0x80
              beq     testRelease
              lda     long:pumpRepeat
              bit     ##8
              bne     testRelease
              lda     long:stealthSample
              and     ##0x7f
              tax
              lda     long:asciiKeys,x
              and     ##0x00ff
              cmp     ##NONE
              beq     testRelease
              cmp     long:stealthKey
              beq     repressPrimary
              cmp     long:pumpSecond
              beq     repressSecond
              cmp     long:pumpThird
              beq     repressThird
              sta     long:pumpNewKey
              jsr     .kbank pumpNewOrdinary
              bra     testRelease
repressPrimary:
              lda     long:stealthKey
              ora     ##0x80
              jsr     .kbank queue
              lda     long:stealthKey
              jsr     .kbank queue
              bra     testRelease
repressSecond:
              lda     long:pumpSecond
              ora     ##0x80
              jsr     .kbank queue
              lda     long:pumpSecond
              jsr     .kbank queue
              bra     testRelease
repressThird:
              lda     long:pumpThird
              ora     ##0x80
              jsr     .kbank queue
              lda     long:pumpThird
              jsr     .kbank queue
testRelease:  lda     long:stealthAKD
              bit     ##0x80
              beq     allReleased
              jsr     .kbank pumpSchedule
              bra     pollDone
allReleased:  lda     ##0
              sta     long:stealthRecover
              jsr     .kbank releaseOrdinary
              lda     long:pumpSecond
              cmp     ##NONE
              beq     noSecondRelease
              ora     ##0x80
              jsr     .kbank queue
              lda     ##NONE
              sta     long:pumpSecond
noSecondRelease:
              lda     long:pumpThird
              cmp     ##NONE
              beq     noThirdRelease
              ora     ##0x80
              jsr     .kbank queue
              lda     ##NONE
              sta     long:pumpThird
noThirdRelease:
              lda     long:pumpState
              cmp     ##1
              bne     releasedUnhooked
              jsr     .kbank pumpRemove     ; armed request, no byte sent yet
releasedUnhooked:
              lda     ##0
              sta     long:pumpAmbiguous
pollDone:     sep     #0x20
              lda     long:captureHead
              cmp     long:captureTail
              rep     #0x20
              beq     pollReturn
              lda     long:iigs_adbqtail
              sec
              sbc     long:iigs_adbqhead
              dec     a
              and     ##31
              cmp     ##10
              bcc     pollReturn
              brl     sample
pollReturn:   ply
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
stealthRecover:  .word 0
stealthOldAKD:   .word 0
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

j13Armed:      .word 0
modifierLatch: .byte 0
stealthButton1: .byte 0
stealthASCII: .byte 0

identifyMatrix:
              rep     #0x20
              lda     ##0
              sta     long:stealthMatrix
              sep     #0x20
              ldy     ##256                ; Forced K bypasses detect's drain.
identifyDrain:
              lda     long:ADBSTATUS
              and     #0x20
              beq     identifyStart
              lda     long:ADBDATA
              dey
              bne     identifyDrain
              rts
identifyStart:
              ldx     ##0
identifyLoop: phx
              rep     #0x20
              txa
              clc
              cpx     ##32
              bcs     identifyUpdate
              adc     ##0x18ac
              bra     identifyAddress
identifyUpdate:
              clc
              adc     ##(0x1a10-32)
identifyAddress:
              tax
              sep     #0x20
              jsr     .kbank readMCU
              plx
              bcs     identifyDone
              cmp     long:matrixROM,x
              bne     identifyDone
              inx
              cpx     ##64
              bcc     identifyLoop
              lda     #1
              sta     long:stealthMatrix
identifyDone: rts

;;; X = MCU address; A8 result, C set on timeout. X is preserved.
readMCU:      lda     #9
              jsr     .kbank sendBounded
              bcs     readMCUDone
              txa
              jsr     .kbank sendBounded
              bcs     readMCUDone
              rep     #0x20
              txa
              xba
              sep     #0x20
              jsr     .kbank sendBounded
              bcs     readMCUDone
              jsr     .kbank readBounded
readMCUDone:  rts


matrixROM:
              .byte 0x3c, 0xff, 0xe4, 0xa2, 0x09, 0x22, 0x59, 0x3c, 0x0a, 0x48, 0xc6, 0x48, 0x30, 0x5b, 0xa5, 0x48, 0xaa, 0x8b, 0x85, 0xe4, 0xb5, 0x31, 0x45, 0xe2, 0x3c, 0xff, 0xe4, 0xf0, 0xed, 0xa0, 0x08, 0x88
              .byte 0x22, 0xb4, 0xf7, 0x4c, 0x05, 0x15, 0x31, 0x95, 0x31, 0x60, 0x8f, 0x0a, 0xe7, 0x0f, 0x06, 0x49, 0xff, 0x35, 0x31, 0x95, 0x31, 0x22, 0xc5, 0x33, 0x1c, 0xf3, 0x1a, 0xa6, 0x4c, 0xe0, 0x37, 0xf0

pumpRows:
              .byte 0x31, 0x33, 0x32, 0x35, 0x34, 0x36, 0x31, 0x32, 0x33, 0x34, 0xff, 0x35, 0x32, 0x33, 0x34, 0x35
              .byte 0x36, 0x37, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x3a, 0x38, 0x3a, 0x39, 0x39, 0x3a, 0x3a
              .byte 0x38, 0x39, 0x39, 0x38, 0x37, 0x3a, 0x37, 0x3a, 0x38, 0x39, 0x37, 0x38, 0x3a, 0x36, 0x37, 0x39
              .byte 0x31, 0x39, 0x37, 0x37, 0xff, 0x31, 0xff, 0xff, 0xff, 0xff, 0xff, 0x39, 0x3a, 0x38, 0x38, 0xff
pumpMasks:
              .byte 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x08, 0x08, 0x08, 0x08, 0x00, 0x08, 0x02, 0x02, 0x02, 0x02
              .byte 0x02, 0x02, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x10, 0x01, 0x01, 0x10, 0x01, 0x10, 0x20, 0x02
              .byte 0x02, 0x20, 0x02, 0x20, 0x40, 0x04, 0x04, 0x40, 0x04, 0x04, 0x10, 0x08, 0x08, 0x08, 0x08, 0x08
              .byte 0x02, 0x40, 0x20, 0x80, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x80, 0x80, 0x40, 0x00


;;; Only a known overlapping pair permits one private row transaction.
;;; The renderer and IRQ status load are patched only for that transaction.
              .public pumpState, pumpResult, pumpSecond, pumpAmbiguous
              .public pumpCore, pumpColumn, pumpInstall, pumpRemove, pumpRow, pumpValue
              .public pumpTimeouts, stealthMatrix
stealthMatrix: .word 0
pumpSecond: .word NONE
              .public pumpThird
pumpThird: .word NONE
pumpAmbiguous: .word 0
pumpNewKey: .word NONE
pumpRepeat: .word 0
pumpState: .word 0
pumpResult: .word 0
pumpRow: .word 0
pumpValue: .word 0
pumpAlternate: .word 0
pumpTimeouts: .word 0
pumpBatch: .byte 0
pumpNextRow: .byte 0
pumpNextMask: .byte 0
pumpExpired: .byte 0
pumpStatus: .byte 0
pumpEnables: .byte 0
pumpExpected: .byte 0
pumpDeferred: .byte 0
pumpBudget: .byte 0
pumpRowsCached: .space 3,0
pumpMasksCached: .space 3,0
pumpRaw: .byte 0
              .public captureHead, captureTail
captureHead: .word 0
captureTail: .word 0
captureAscii: .space 16,0
captureRepeat: .space 16,0
captureAKDs: .space 16,0
captureTics: .space 32,0
captureClock: .word 0
captureSample: .byte 0
captureModSample: .byte 0
captureAKDSample: .byte 0
captureLastAKD: .byte 0
captureSampled: .byte 0
sampleAKD: .byte 0
pumpRendering: .word 0

pumpNewOrdinary:
              cmp ##NONE
              beq pumpUseSingle
              lda long:stealthMatrix
              beq pumpUseSingle
              lda long:stealthAKD
              bit ##0x80
              beq pumpUseSingle
              lda long:stealthKey
              cmp ##NONE
              beq pumpUseSingle
              tax
              lda long:pumpRows,x
              and ##0xff
              cmp ##0xff
              beq pumpUseSingle
              lda long:pumpNewKey
              tax
              lda long:pumpRows,x
              and ##0xff
              cmp ##0xff
              beq pumpUseSingle
              lda long:pumpSecond
              cmp ##NONE
              bne pumpNewThird
              lda long:pumpNewKey
              sta long:pumpSecond
              bra pumpNewTracked
pumpNewThird:
              lda long:pumpThird
              cmp ##NONE
              bne pumpIgnoreThird
              lda long:pumpNewKey
              sta long:pumpThird
pumpNewTracked:
              jsr .kbank queue
              lda ##1
              sta long:pumpAmbiguous
              lda long:pumpState
              cmp ##1
              bne pumpNewCache
              jsr .kbank pumpRemove          ; no command sent: reselect expanded masks
pumpNewCache: jsr .kbank pumpCachePair
pumpIgnoreThird: rts
pumpUseSingle:
              lda long:pumpNewKey
              pha
              jsr .kbank releaseOrdinary
              pla
              sta long:stealthKey
              cmp ##NONE
              beq pumpIgnoreThird
              jmp .kbank queue

;;; A result is immutable until consumed; no request replaces it.
pumpCollect:
              lda long:pumpState
              cmp ##1
              bne pumpCollectBusy
              lda long:VW_SIZE
              cmp long:pumpView
              bne pumpChangedView
              brl pumpCollectResult
pumpChangedView:
              jsr .kbank pumpRemove
              brl pumpCollectResult
pumpCollectBusy:
              lda long:pumpState
              cmp ##2
              bcs pumpCollectOwned
              brl pumpCollectResult
pumpCollectOwned:
              sep #0x20
              lda long:ADBSTATUS
              sta long:pumpStatus
              lda long:pumpState
              cmp #5
              bne pumpCollectPhase
              lda long:pumpExpired
              sta long:pumpState
pumpCollectPhase:
              lda long:pumpState
              cmp #4
              bne pumpCollectDiscard
              lda long:pumpStatus
              and #0x20
              beq pumpCollectDiscard
              ; Validate a late reply before retiring the transaction.
              lda #0
              sta long:pumpBatch
              jsr .kbank pumpOwned
              lda long:pumpState
              beq pumpCollectFinished
              lda long:pumpStatus
              and #0xdf                    ; DATA was already consumed.
              sta long:pumpStatus
              bra pumpCollectDiscard
pumpCollectFinished:
              rep #0x20
              bra pumpCollectResult
pumpCollectDiscard:
              lda long:pumpStatus
              and #0x20
              beq pumpAbortEmpty
              lda long:ADBDATA
              sta long:pumpRaw
              jsr .kbank pumpSaveStatus
pumpAbortEmpty:
              jsr .kbank pumpComplete        ; restore enables and replay a real SRQ
              rep #0x20
              lda long:pumpThird
              cmp ##NONE
              beq pumpRetryPair
              lda long:pumpAlternate
              bne pumpRetryThird
              lda ##3
pumpRetryThird:
              dec a
              bra pumpRetryChosen
pumpRetryPair:
              lda long:pumpAlternate
              eor ##1
pumpRetryChosen:
              sta long:pumpAlternate
              lda long:pumpTimeouts
              inc a
              sta long:pumpTimeouts
pumpCollectResult:
              lda long:pumpResult
              bne pumpHaveResult
              rts
pumpHaveResult:
              lda ##0
              sta long:pumpResult
              lda long:stealthKey
              jsr .kbank pumpIsUp
              bcc pumpCheckSecond
              lda long:stealthKey
              ora ##0x80
              jsr .kbank queue
              lda ##NONE
              sta long:stealthKey
pumpCheckSecond:
              lda long:pumpSecond
              jsr .kbank pumpIsUp
              bcc pumpCheckThird
              lda long:pumpSecond
              ora ##0x80
              jsr .kbank queue
              lda ##NONE
              sta long:pumpSecond
              bra pumpCheckThird
pumpCheckThird:
              lda long:pumpThird
              jsr .kbank pumpIsUp
              bcc pumpCompact
              lda long:pumpThird
              ora ##0x80
              jsr .kbank queue
              lda ##NONE
              sta long:pumpThird
pumpCompact: lda long:stealthKey
              cmp ##NONE
              bne pumpPair
              lda long:pumpSecond
              sta long:stealthKey
              lda ##NONE
              sta long:pumpSecond
pumpPair:     lda long:pumpSecond
              cmp ##NONE
              bne pumpPairCached
              lda long:pumpThird
              sta long:pumpSecond
              lda ##NONE
              sta long:pumpThird
              lda long:stealthKey
              cmp ##NONE
              bne pumpPairReady
              lda long:pumpSecond
              sta long:stealthKey
              lda ##NONE
              sta long:pumpSecond
pumpPairReady:
              lda long:pumpSecond
              cmp ##NONE
              bne pumpPairCached
              lda ##0
              sta long:pumpAmbiguous
              rts
pumpPairCached:
              jsr .kbank pumpCachePair
pumpCollectDone: rts
pumpIsUp:     cmp ##NONE
              beq pumpNotUp
              tax
              lda long:pumpRows,x
              and ##0xff
              cmp long:pumpRow
              bne pumpNotUp
              lda long:pumpMasks,x
              and ##0xff
              and long:pumpValue
              beq pumpNotUp
              sec
              rts
pumpNotUp:    clc
              rts

pumpSchedule:
              lda long:pumpState
              beq pumpScheduleIdle
              rts
pumpScheduleIdle:
              lda long:pumpAmbiguous
              bne pumpScheduleNeeded
              rts
pumpScheduleNeeded:
              lda long:_g_menuactive
              ora long:_g_gamestate
              bne pumpScheduleDone
              lda long:pumpThird
              cmp ##NONE
              beq pumpChoosePair
              lda long:pumpAlternate
              inc a
              cmp ##3
              bcc pumpChooseReady
              lda ##0
              bra pumpChooseReady
pumpChoosePair:
              lda long:pumpAlternate
              and ##1
              eor ##1
pumpChooseReady:
              sta long:pumpAlternate
              tax
              lda long:pumpRowsCached,x
              and ##0xff
              sta long:pumpRow
              sep #0x20
              lda long:pumpMasksCached,x
              sta long:pumpExpected
              lda long:pumpThird
              cmp #NONE
              beq pumpNextPairSlot
              txa
              inc a
              cmp #3
              bcc pumpNextSlotReady
              lda #0
              bra pumpNextSlotReady
pumpNextPairSlot:
              txa
              eor #1
pumpNextSlotReady:
              tax
              lda long:pumpRowsCached,x
              sta long:pumpNextRow
              cmp long:pumpRow
              beq pumpOneRow
              lda #1
              bra pumpSetBatch
pumpOneRow:   lda #0
pumpSetBatch: sta long:pumpBatch
              lda long:pumpMasksCached,x
              sta long:pumpNextMask
              rep #0x20
              jsr .kbank pumpInstall
pumpScheduleDone: rts
pumpCachePair:
              lda long:stealthKey
              tax
              sep #0x20
              lda long:pumpRows,x
              sta long:pumpRowsCached
              lda long:pumpMasks,x
              sta long:pumpMasksCached
              rep #0x20
              lda long:pumpSecond
              tax
              sep #0x20
              lda long:pumpRows,x
              sta long:(pumpRowsCached+1)
              lda long:pumpMasks,x
              sta long:(pumpMasksCached+1)
              lda long:pumpRowsCached
              cmp long:(pumpRowsCached+1)
              bne pumpCacheDone
              lda long:pumpMasksCached
              ora long:(pumpMasksCached+1)
              sta long:pumpMasksCached
              sta long:(pumpMasksCached+1)
pumpCacheDone: rep #0x20
              lda long:pumpThird
              cmp ##NONE
              beq pumpCacheReturn
              tax
              sep #0x20
              lda long:pumpRows,x
              sta long:(pumpRowsCached+2)
              lda long:pumpMasks,x
              sta long:(pumpMasksCached+2)
              lda long:(pumpRowsCached+2)
              cmp long:pumpRowsCached
              bne pumpMergeThirdSecond
              lda long:(pumpMasksCached+2)
              ora long:pumpMasksCached
              sta long:pumpMasksCached
              sta long:(pumpMasksCached+2)
pumpMergeThirdSecond:
              lda long:(pumpRowsCached+2)
              cmp long:(pumpRowsCached+1)
              bne pumpCacheReturn8
              lda long:(pumpMasksCached+2)
              ora long:(pumpMasksCached+1)
              sta long:(pumpMasksCached+1)
              sta long:(pumpMasksCached+2)
              lda long:pumpRowsCached
              cmp long:(pumpRowsCached+1)
              bne pumpCacheReturn8
              lda long:(pumpMasksCached+2)
              sta long:pumpMasksCached
pumpCacheReturn8:
              rep #0x20
pumpCacheReturn:
              ; A fresh third identity may share an in-flight row. Validate
              ; its reply against every tracked switch in that row, not just
              ; the mask saved when the transaction started.
              sep #0x20
              lda long:pumpState
              beq pumpCacheFinish
              lda #0
              sta long:pumpExpected
              sta long:pumpNextMask
              ldx ##2
pumpMergeLive:
              cpx ##2
              bne pumpMergeSlot
              lda long:pumpThird
              cmp #NONE
              beq pumpMergeSkip
pumpMergeSlot:
              lda long:pumpRowsCached,x
              cmp long:pumpRow
              bne pumpMergeNext
              lda long:pumpMasksCached,x
              ora long:pumpExpected
              sta long:pumpExpected
pumpMergeNext:
              lda long:pumpRowsCached,x
              cmp long:pumpNextRow
              bne pumpMergeSkip
              lda long:pumpMasksCached,x
              ora long:pumpNextMask
              sta long:pumpNextMask
pumpMergeSkip:
              dex
              bpl pumpMergeLive
pumpCacheFinish:
              rep #0x20
              rts

;;; A8/X16. Column indices pace checks without reading video counters.
;;; The intermediate calls are one CMP/BNE; the hook disappears on completion.
;;; Preserve registers and execute displaced STA/ASL/XBA, then jump back.
pumpColumn:  cmp #0                        ; next column index, patched in place
              bne pumpOriginal
              php
              sei
              pha
              clc
              adc #4                         ; skip the next three column calls
              sta long:(pumpColumn+1)
              pla
              rep #0x20
              pha
              sep #0x20
              jsr .kbank pumpCore
              rep #0x20
              pla
              plp
              .public pumpOriginal
pumpOriginal: .space 4,0xea
pumpReturn:   jmp long:(J13ColumnSite+4)

;;; A8, no X/Y changes. One status read; a stable reply may send the
;;; next command immediately when that cached status says the MCU is ready.
;;; No waiting loop. Exhaustion unhooks the columns; the next poll retires
;;; the expired transaction, preserving held keys and retrying the same row.
pumpCore:     lda #1
              sta long:pumpRendering
              lda long:pumpState
              beq pumpCoreDone
              lda long:pumpBudget
              beq pumpPause
              dec a
              sta long:pumpBudget
              lda long:ADBSTATUS
              sta long:pumpStatus
              lda long:pumpState
              cmp #1
              bne pumpOwned
              lda long:adbTalk
              bne pumpCoreDone
              lda long:pumpStatus
              and #0xa1
              bne pumpCoreDone
              jsr .kbank pumpOwnIRQ
              lda long:pumpStatus
              and #0x50
              sta long:pumpEnables
              lda long:pumpStatus
              and #0xaf
              sta long:ADBSTATUS
              lda #9
              sta long:ADBDATA
              sta long:ZIPCANCEL
              lda #2
              sta long:pumpState
pumpCoreDone: rts
pumpPause:    jmp long:pumpDrainReady
              nop                           ; Preserve every original reader address.
              sep #0x20
              lda long:pumpState
              cmp #1
              beq pumpNeverOwned
              sta long:pumpExpired
              lda #5
              sta long:pumpState
              rts
pumpNeverOwned:
              lda #0
              sta long:pumpState
              rts
pumpOwned:    lda long:pumpStatus
              bit #0x20
              beq pumpSend
              lda long:ADBDATA
              sta long:pumpRaw
              lda long:pumpState
              cmp #4
              bne pumpSaveStatus
              lda long:pumpRaw
              ora long:pumpExpected
              cmp #0xff
              bne pumpSaveStatus
              lda long:pumpRaw
              sta long:pumpValue
              and long:pumpExpected
              beq pumpStableRow
              lda #1
              sta long:pumpResult
              jmp .kbank pumpComplete
pumpStableRow:
              lda long:pumpBatch
              bne pumpChain
              jmp .kbank pumpComplete
pumpChain:    lda #0
              sta long:pumpBatch
              lda long:pumpNextRow
              sta long:pumpRow
              lda long:pumpNextMask
              sta long:pumpExpected
              lda #6
              sta long:pumpState
              lda long:pumpStatus
              and #1
              bne pumpOwnedDone
              bra pumpNextCommand
pumpSaveStatus:
              lda long:pumpRaw
              and #0x87
              bne pumpOwnedDone             ; unresolved row-shaped data is not SRQ
              lda long:pumpRaw
              ora long:pumpDeferred
              sta long:pumpDeferred
              rts
pumpOwnedDone: rts
pumpSend:     lda long:pumpStatus
              and #1
              bne pumpOwnedDone
              lda long:pumpState
              cmp #2
              beq pumpLow
              cmp #6
              beq pumpNextCommand
              cmp #3
              bne pumpOwnedDone
              lda #0
              sta long:ADBDATA
              sta long:ZIPCANCEL
              lda #4
              sta long:pumpState
              rts
pumpNextCommand:
              lda #9
              sta long:ADBDATA
              sta long:ZIPCANCEL
              lda #2
              sta long:pumpState
              rts
pumpLow:      lda long:pumpRow
              sta long:ADBDATA
              sta long:ZIPCANCEL
              lda #3
              sta long:pumpState
              rts
pumpComplete:
              lda long:pumpStatus
              and #0xaf
              ora long:pumpEnables
              sta long:ADBSTATUS
              lda long:pumpDeferred
              and #8
              beq pumpNoDeferred
              lda long:adbHalt
              bne pumpNoDeferred
              lda #0xc2
              sta long:ADBDATA
              sta long:ZIPCANCEL
              lda #1
              sta long:adbTalk
pumpNoDeferred:
              rep #0x20
              jsr .kbank pumpRemove
              sep #0x20
              rts

 ; All six column entries reside in the same code bank. Narrow-view
 ; entries begin two bytes later, after STA: XBA/LDA #0/XBA is four bytes.
 ; Select the current view for this transaction; no dormant renderer hooks.
pumpSites:    .word .word0 J13ColumnSite, .word0 J13ColumnSite
              .word .word0 (qcol+2), .word0 (ocol+2), .word0 J13ColumnSite
              .word .word0 hcol, .word0 J13ColumnSite, .word0 (tcol+2)
              .word .word0 (ucol+2), .word0 J13ColumnSite, .word0 J13ColumnSite
pumpSite:     .word .word0 J13ColumnSite
pumpView:     .word 10
pumpInstall: phx
              lda long:VW_SIZE
              cmp ##11
              bcc pumpViewValid
              lda ##10
pumpViewValid: sta long:pumpView
              asl a
              tax
              lda long:pumpSites,x
              sta long:pumpSite
              tax
              clc
              adc ##4
              sta long:(pumpReturn+1)
              lda long:0x050000,x
              sta long:pumpOriginal
              lda long:(0x050000+2),x
              sta long:(pumpOriginal+2)
              lda ##1
              sta long:pumpState
              lda ##.word0 pumpColumn
              sta long:(0x050000+1),x
              sep #0x20
              lda #0
              sta long:pumpRendering
              lda #10
              sta long:pumpBudget
              lda #0
              sta long:pumpDeferred
              sta long:(pumpColumn+1)
              lda #.byte2 pumpColumn
              sta long:(0x050000+3),x
              lda #0x5c
              sta long:0x050000,x
              rep #0x20
              plx
              rts
pumpOwnIRQ:  rep #0x20
              lda ##0x00a9                 ; LDA #0: no private byte to ADB parser.
              sta long:J13StatusSite
              sta long:(J13StatusSite-0x2200)
              lda ##0xeaea
              sta long:(J13StatusSite+2)
              sta long:(J13StatusSite+2-0x2200)
              sep #0x20
              rts
pumpRestoreColumn:
              phx
              lda long:pumpSite
              tax
              lda long:pumpOriginal
              sta long:0x050000,x
              lda long:(pumpOriginal+2)
              sta long:(0x050000+2),x
              plx
              rts
pumpRemove:   lda ##0
              sta long:pumpRendering
              jsr .kbank pumpRestoreColumn
              lda ##0xc027
              sta long:(J13StatusSite+1)
              sta long:(J13StatusSite+1-0x2200)
              sep #0x20
              lda #0xe0
              sta long:(J13StatusSite+3)
              sta long:(J13StatusSite+3-0x2200)
              lda #0xaf
              sta long:J13StatusSite
              sta long:(J13StatusSite-0x2200)
              rep #0x20
              lda ##0
              sta long:pumpState
              rts

;;; Silent-owner extensions stay after the original reader. Preserve every
;;; existing capture, pump and table address to avoid music-on cache changes.
J13ArmSilent: php
              sei
              rep     #0x20
              pha
              lda     ##.word0 J13SilentBranchWord
              sta     long:J13SilentExit
              sta     long:(J13SilentExit-0x2200)
              lda     ##.word0 J13SilentIRQ
              sta     long:(J13SilentTrampoline+1)
              sta     long:(J13SilentTrampoline-0x2200+1)
              lda     ##.word0 J13AlarmOff
              sta     long:(IIGS_AlarmOff+1)
              sep     #0x20
              lda     #.byte2 J13SilentIRQ
              sta     long:(J13SilentTrampoline+3)
              sta     long:(J13SilentTrampoline-0x2200+3)
              lda     #.byte2 J13AlarmOff
              sta     long:(IIGS_AlarmOff+3)
              lda     #0x5c
              sta     long:J13SilentTrampoline
              sta     long:(J13SilentTrampoline-0x2200)
              sta     long:IIGS_AlarmOff
              rep     #0x20
              pla
              jmp     long:(J13Arm+4)

J13PollSilent:
              php
              sei
              rep     #0x20
              pha
              sep     #0x20
              jsr     .kbank J13EnsureAlarm
              jmp     long:(IIGS_PollStealth+7)

 ; Playing music keeps its original branch and
 ; stream cadence. Only its stopped-music return and unused padding are
 ; patched. The silent owner uses a 32 ms interval (about four wakes per
 ; full-view frame). Song startup takes over the same oscillator unchanged.
              .public J13SilentIRQ, J13SilentEnd, J13AlarmOff, J13EnsureAlarm, silentActive, silentPhase
silentActive: .byte 0
silentPhase:  .byte 0
J13EnsureAlarm:
              lda     long:silentActive
              beq     silentNotActive
              rts
silentNotActive:
              lda     long:musOn
              beq     silentCheckPending
              rep     #0x20                 ; Song owns the alarm: remove this poll hook.
              lda     ##0x7808              ; Original PHP / SEI / REP #$20.
              sta     long:IIGS_PollStealth
              lda     ##0x20c2
              sta     long:(IIGS_PollStealth+2)
              sep     #0x20
              rts
silentCheckPending:
              lda     long:musPend
              bne     silentNoStart
              lda     long:0xe0c03c
              bmi     silentNoStart
              lda     long:0x0009ff
              sta     long:0xe0c03c
              lda     long:silentPhase
              beq     silentLow
              cmp     #1
              beq     silentHigh
              bra     silentRestart
silentLow:    lda     #0x1e                  ; Oscillator 30 frequency, no notes/volume.
              sta     long:0xe0c03e
              lda     #155                   ; 131072 / 155 samples ~= 32.1 ms.
              sta     long:0xe0c03d
              lda     #1
              sta     long:silentPhase
              lda     long:0xe0c03c
              bmi     silentNoStart          ; Resume the high byte next poll if busy.
silentHigh:   lda     #0x3e
              sta     long:0xe0c03e
              lda     #0
              sta     long:0xe0c03d
              lda     #2
              sta     long:silentPhase
silentRestart:
              lda     long:0xe0c03c
              bmi     silentNoStart          ; One readiness check, never wait.
              lda     long:0x0009ff
              sta     long:0xe0c03c
              lda     #0xbe                  ; The same music alarm, oscillator 30.
              sta     long:0xe0c03e
              lda     #0x0a
              sta     long:0xe0c03d
              lda     #1
              sta     long:silentActive
silentNoStart: rts

 ; Displace PHP/SEI/SEP #$20 from the original alarm stop. A disk pause or
 ; shutdown really stops the alarm; only a later armed game poll restarts it.
J13AlarmOff:   php
              sei
              sep     #0x20
              lda     #0
              sta     long:silentActive
              sta     long:silentPhase
              jsr     .kbank silentHookPoll
              jmp     long:(IIGS_AlarmOff+4)

silentHookPoll:
              rep     #0x20                 ; Rearm the poll hook for stopped/pending music.
              lda     ##.word0 J13PollSilent
              sta     long:(IIGS_PollStealth+1)
              sep     #0x20
              lda     #.byte2 J13PollSilent
              sta     long:(IIGS_PollStealth+3)
              lda     #0x5c
              sta     long:IIGS_PollStealth
              rts

 ; The existing IRQ has acknowledged oscillator 30 and stacked 8-bit A.
 ; Do not enter the song stream or change musOn/musPend while silent.
J13SilentIRQ:
              rep     #0x30
              pha
              phx
              phy
              sep     #0x20
              lda     long:silentActive
              beq     silentFirstWake       ; The pending final wake of a non-looping song.
              lda     #0
              sta     long:silentActive
              jsr     .kbank silentRestart
              bra     silentSample
silentFirstWake:
              jsr     .kbank silentHookPoll
              jsr     .kbank J13EnsureAlarm  ; Set the fixed silent interval once.
silentSample: jsr     .kbank captureStrobe
 ; Silent wakes capture register edges only. The existing column pump owns
 ; its bounded MCU checks; spending that budget from a second site can leave
 ; a completed row reply holding off an ADB tap until the next game poll.
silentReturn: rep     #0x30
              ply
              plx
              pla
              sep     #0x20
              pla
J13SilentEnd: rti


;;; Do not strand a completed reply behind the frame budget with ADB masked.
;;; One bounded final status read, only after all command parameters were sent.
;;; No new command or row chain is started; the poll consumes the result.
pumpDrainReady:
              lda long:pumpState
              cmp #4
              bne pumpDrainPause
              lda long:ADBSTATUS
              sta long:pumpStatus
              and #0x20
              beq pumpDrainPause
              lda #0
              sta long:pumpBatch
              jsr .kbank pumpOwned
              lda long:pumpState
              bne pumpDrainPause
              rts
pumpDrainPause:
              rep #0x20
              jsr .kbank pumpRestoreColumn
              jmp long:(pumpPause+5)
