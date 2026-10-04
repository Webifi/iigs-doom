;;; J13/IIe keyboard adapter for the ADB event ring consumed by I_StartTic.
;;; $C000 provides one ASCII latch and its strobe, not a set of held keys.
;;; Reading $C010 acknowledges that strobe; bit 7 reports any-key-down.
;;; $C025 and $C061/$C062 supply modifiers and Apple-button state.
;;;
;;; IIGS_SelectKeyboard probes ADB address 2 to retain raw ADB input when
;;; available. On ROM 00/01, menus also accept the compatibility registers.
;;; The saved J13 option selects gameplay input at level and menu transitions.
;;; Menu readers can enable it after a recognized character; they never save it.
;;; With it off, the game calls the original ADB consumer directly and
;;; checks the character latch once per frame for Escape on ROM 00/01.
;;;
;;; Overlapping ordinary keys need MCU row reads to identify releases.
;;; identifyMatrix must match the scanner firmware before those reads are
;;; allowed. Unknown firmware uses the latest ASCII identity and all-up
;;; indication. Sampling can miss short taps, and ASCII/control aliases
;;; cannot recover every physical key identity.
;;;
;;; The IRQ sampler publishes register snapshots to a private capture FIFO.
;;; The game poll translates them into ADB identities in iigs_adbq; I_StartTic
;;; alone applies bindings, tap retention and menu repeat. MCU row replies
;;; can release tracked identities, but never invent a new key press.
;;;
;;; stealthcode occupies its own linker region after ENDOOM. Runtime patches
;;; use instruction offsets and saved bytes: keep displaced instructions,
;;; return addresses and the IRQ load-image copies consistent when editing.

              .rtmodel version, "1"
              .rtmodel core, "*"
#include "tics.inc"
#include "keys.inc"
#include "music.inc"
#include "viewwin.inc"
              .extern hcol, tcol, ocol, qcol, ucol
              .extern IIGS_StartKeys, IIGS_StopKeys, I_StartTic, I_GetTime
              .extern J13ColumnSite, J13StatusSite, J13AlarmSite, adbTalk
              .extern J13SilentBranchWord
              .extern J13SilentExit, J13SilentTrampoline, IIGS_AlarmOff, musOn, musPend
              .extern _g_menuactive, _g_gamestate
              .extern keyboardTicCall, keyboardBuildCall
              .extern J13EscapeSite, M_StartControlPanel
              .public J13EscapeCheck
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
;;; Startup, before IIGS_StartKeys takes over raw ADB polling. A complete
;;; address-2 reply selects that path; failure selects compatibility input.
;;; Neither outcome proves that a keyboard is connected to J13. installProbe
;;; gates the compatibility reader by ROM version, independently of the
;;; fingerprint that permits MCU row reads.
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
              .space  16,0xea               ; Keep the input module's following cache slots.

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
              jmp     long:J13StartKeys     ; Raw ADB input, then discard startup characters.

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
selected:     jmp     .kbank j13Selected
              .space  4,0xea               ; Keep subsequent input entries fixed.

;;; A8, X/Y16; caller owns the controller with IRQs masked. Each byte gets
;;; at most 16384 status polls, not a fixed wall-clock timeout. Carry set
;;; reports timeout; callers must stop the current command sequence.
;;; sendBounded preserves A; readBounded returns DATA in A on success.
;;; Both preserve X and consume Y. Only setup, menu-entry flushing and
;;; shutdown use these waits; gameplay row reads advance through pumpCore.
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

;;; A8, X/Y16. ROM 00/01 expose the sixth INPUT item and start with the
;;; menu reader. j13Available means the reader is supported, not detected.
installProbe:
              lda     long:ROMVER
              cmp     #2
              bcs     menuReaderUnavailable
              rep     #0x20
              lda     ##1
              sta     long:j13Available
              sta     long:j13InputMode
              lda     ##6
              sta     long:(menuNum+16)
              jsr     .kbank installMenuReader
              sep     #0x20
menuReaderUnavailable:
              rts
;;; Patch the operands of both JSL sites with IRQs masked; return with A16.
;;; The timestamped build uses a separate wrapper to retain its tic cutoff.
installMenuReader:
              rep     #0x20
              lda     ##.word0 J13MenuTic
              sta     long:(keyboardTicCall+1)
              sep     #0x20
              lda     #.byte2 J13MenuTic
              sta     long:(keyboardTicCall+3)
              rep     #0x20
#if TICSTEP > 1
              lda     ##.word0 J13MenuTicUntil
#else
              lda     ##.word0 J13MenuTic
#endif
              sta     long:(keyboardBuildCall+1)
              sep     #0x20
#if TICSTEP > 1
              lda     #.byte2 J13MenuTicUntil
#else
              lda     #.byte2 J13MenuTic
#endif
              sta     long:(keyboardBuildCall+3)
              rep     #0x20
              rts

;;; I_BesideTic[Until] are fixed-address strobe probes that arm gameplay.
;;; j13SetMode selects the menu or gameplay reader directly, so it does not
;;; install either probe. Keep their footprint for the following patch sites.
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
#if TICSTEP > 1
I_StealthStartTic:
              jsl     long:IIGS_PollStealth
              jmp     long:I_StartTic
              .public I_StealthStartTicUntil
I_StealthStartTicUntil:
              pha
              jsl     long:IIGS_PollStealth
              pla
              jmp     long:I_StartTicUntil
#endif

;;; Install tic dispatch and oscillator-30 capture. Patch both the running
;;; IRQ code and its load image at address - $2200: disk I/O reinstalls the
;;; image. J13ArmSilent supplies PHP/SEI/REP and resumes here at J13Arm+4.
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

 ; Enter from the music IRQ with A8, X/Y16 and the alarm control in A.
 ; Replay its displaced store before capture so keyboard work follows the
 ; alarm restart. Preserve X/Y, accumulator B and DBR for the stream reader;
 ; low A and flags are scratch. An active render request may use one status
 ; sample here, including a second-row command if the first row is unchanged.
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
              phb
              phk
              plb
              jsr     .kbank pumpCore        ; At most one status read; never waits.
              plb
              rep     #0x20
              pla
              sep     #0x20
wakeKeysDone: jmp     long:(J13AlarmSite+4)

 ; A8; X/Y, accumulator B and DBR preserved. Both the IRQ and game poll
 ; call this with IRQs masked, serializing the producer with FIFO consumption.
 ; The 16-slot ring holds 15 snapshots. If full, return before touching the
 ; latch or modifiers; otherwise read C000 before C010 acknowledges its strobe.
 ; Save fresh non-repeat characters and all-up edges in arrival order.
 ; Modifier downs accumulate separately in modifierLatch until the game poll;
 ; this retains an observed tap, not every edge between samples.
captureStrobe:
              lda     long:captureHead
              inc     a
              and     #15
              cmp     long:captureTail
              bne     captureRoom
              rts
captureRoom:  lda     long:KBD
              sta     long:captureSample
              bmi     captureCharacter
 ; With no character, latch modifiers and track AKD transitions. Only an
 ; all-up transition needs a FIFO record; an AKD rise may precede its ASCII.
captureNoCharacter:
              lda     long:MODIFIERS
              sta     long:captureModSample
              ora     long:modifierLatch
              sta     long:modifierLatch
              lda     long:AKD
              eor     long:captureLastAKD
              bpl     captureNoChange
              eor     long:captureLastAKD
              sta     long:captureAKDSample
              sta     long:captureLastAKD
              bmi     captureNoChange
              brl     capturePush
captureNoChange: rts

captureCharacter:
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
 ; Write the complete snapshot before publishing captureHead. captureRepeat
 ; stores the full C025 byte: repeat/recovery tests still need its other bits.
capturePush:  php
              rep     #0x30
              pha
              phx
#if TICSTEP > 1
              jsr     .kbank captureTime
              lda     long:captureHead
              asl     a
              tax
              lda     long:captureClock
              sta     long:captureTics,x
#endif
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
              lda     #1
              sta     long:pollWork
              rep     #0x30
              plx
              pla
              plp
captureDone:  rts

 ; Timestamp only captured edges. IRQs are masked by the caller. If DOC is
 ; busy, retain the last captureClock rather than wait inside the sampler.
 ; Only builds that consume timestamped input call this routine. It returns
 ; A16 and may change X; capturePush saves X. Set DBR for I_GetTime's near
 ; state because an IRQ can arrive with any data bank, then restore it.
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

;;; Track up to three ordinary identities and five modifiers. Clear AKD
;;; releases all ordinary keys; a partial release needs a validated MCU row.
;;; Before consuming each snapshot, reserve ten event-ring slots for modifier
;;; transitions, releases and a completed tap. If space is short, defer the
;;; active sample and let I_StartTic drain the ring before another poll.
;;; J13PollSilent (or the installed PHP/SEI/REP prologue) masks IRQs while
;;; queue() updates the ring. I_StartTic handles tap retention and menu repeat.
;;; A/X/Y are scratch, as in I_StartTic. The normal build enters here directly
;;; and finishes through that consumer; timestamped builds keep its wrapper.
#if TICSTEP == 1
I_StealthStartTic:
#endif
IIGS_PollStealth:
              php
              sei
              rep     #0x20
              sep     #0x20
pollEntry:
              lda     long:pollWork
              beq     pollNoWork
              brl     pollActive
 ; No pending FIFO work: compare live state before doing translation. An
 ; armed row request must still be retired or retargeted after a view change.
pollNoWork:
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
              jsr     .kbank pumpSchedule
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
pollFastDone: plp
#if TICSTEP == 1
              jmp     long:I_StartTic
#else
              rtl
#endif
pollActive:   rep     #0x30
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
 ; The FIFO is older than live register state. Only fall back to this path
 ; after its saved characters/all-up edges have been consumed.
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
              jsr     .kbank sampleRecoveryReady
              bcs     sampleNotRecovered
              .space 3,0xea                 ; Keep the normal reader's addresses.
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
 ; A fresh non-repeat character can reuse an identity whose release was
 ; missed between samples. Queue up/down so the consumer sees a new press;
 ; its per-tic tap rule prevents those transitions collapsing into nothing.
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
pollReturn:
              sep     #0x20
              lda     long:captureHead
              cmp     long:captureTail
              bne     pollStillWork
              lda     long:stealthRecover
              ora     long:pumpResult
              bra     pollSetWork
pollStillWork:
              lda     #1
pollSetWork:   sta     long:pollWork
              plp
#if TICSTEP == 1
              jmp     long:I_StartTic
#else
              rtl
#endif

releaseOrdinary:
              lda     long:stealthKey
              cmp     ##NONE
              beq     1$
              ora     ##0x80
              jsr     .kbank queue
              lda     ##NONE
              sta     long:stealthKey
1$:           rts

;;; A16 = event byte (bit 7 releases), X/Y16; ring capacity reserved, IRQ off.
;;; Raw ADB and this adapter share the producer head. Write the byte and its
;;; optional timestamp before publishing that head. X is preserved; A changes.
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

;;; Translate the low seven ASCII bits to synthetic ADB identities.
;;; Navigation aliases take precedence (Ctrl-H becomes Left); shifted
;;; punctuation maps to its unshifted US key. This mapping cannot distinguish
;;; keys that produce the same character. A NONE entry would be ignored by
;;; the caller; release information comes from AKD or a validated row.
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
pollWork:        .byte 0               ; Captured input, recovery, or a row result.
stealthOldAKD:   .word 0
stealthMode:     .word 0               ; Startup fallback; not the selected gameplay mode.
stealthKey:      .word NONE            ; Primary ordinary identity; NONE when released.
stealthMods:     .word 0               ; Modifier state already queued to I_StartTic.
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

;;; Boot-only fingerprint: compare MCU ROM $18AC-$18CB and $1A10-$1A2F
;;; with matrixROM before using the undocumented $31-$3A scan-row layout.
;;; Any timeout or mismatch leaves stealthMatrix clear. This checks the
;;; firmware layout, not the presence of a J13 keyboard. bufferKeyboard sets
;;; temporary buffering/repeat policy separately; readMCU itself only reads.
identifyMatrix:
              rep     #0x20
              lda     ##0
              sta     long:stealthMatrix
              sep     #0x20
              ldy     ##256                ; Bound the startup drain.
identifyDrain:
              lda     long:ADBSTATUS
              and     #0x20
              beq     identifyStart
              lda     long:ADBDATA
              dey
              bne     identifyDrain
              rts
identifyStart:
              jsr     .kbank bufferKeyboard
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
;;; Command $09 takes address low, address high, then returns one byte.
;;; The bounded waits are for startup identification only; runtime row
;;; reads use pumpCore so rendering and IRQ service can continue.
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


;;; Scanner bytes followed by row-update bytes, in identifyLoop read order.
matrixROM:
              .byte 0x3c, 0xff, 0xe4, 0xa2, 0x09, 0x22, 0x59, 0x3c, 0x0a, 0x48, 0xc6, 0x48, 0x30, 0x5b, 0xa5, 0x48, 0xaa, 0x8b, 0x85, 0xe4, 0xb5, 0x31, 0x45, 0xe2, 0x3c, 0xff, 0xe4, 0xf0, 0xed, 0xa0, 0x08, 0x88
              .byte 0x22, 0xb4, 0xf7, 0x4c, 0x05, 0x15, 0x31, 0x95, 0x31, 0x60, 0x8f, 0x0a, 0xe7, 0x0f, 0x06, 0x49, 0xff, 0x35, 0x31, 0x95, 0x31, 0x22, 0xc5, 0x33, 0x1c, 0xf3, 0x1a, 0xa6, 0x4c, 0xe0, 0x37, 0xf0

;;; Indexed by the synthetic ADB identity from asciiKeys: MCU RAM row and
;;; active-low switch mask. Row $FF/mask 0 means no supported matrix entry.
;;; Same-row keys share a read; pumpCachePair merges their expected masks.
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


;;; With multiple ordinary identities held, one batch reads at most two
;;; distinct MCU rows. Three identities rotate which rows are checked first.
;;; pumpState: 0 idle, 1 waiting to acquire the controller, 2 send address
;;; low, 3 send address high, 4 await reply, 5 expired (phase in pumpExpired),
;;; 6 send the second command. pumpResult stays valid until pumpCollect.
;;;
;;; Ownership starts only with no Talk, pending DATA, mouse report or busy
;;; command. Save/mask DATA and mouse enables and replace the IRQ status
;;; mask so the ADB parser cannot consume a row reply. pumpComplete restores
;;; the enables and issues a deferred keyboard Talk only if raw ADB is active.
;;; pumpRemove only restores code/state; an owned transaction must first pass
;;; through pumpComplete or pumpCollect to release the controller as well.
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
pumpResult: .word 0                  ; Published pumpRow/pumpValue await poll consumption.
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
;;; IRQ/game capture owns head; the game poll owns tail. Both are masked
;;; against interrupts while changing this FIFO. Transition code may reset
;;; it only after capture hooks have been retired. High index bytes stay zero.
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

;;; A/X/Y16; pumpNewKey is a translated press not already in a held slot.
;;; A known matrix can retain three ordinary identities. A fourth press is
;;; ignored while those slots are full; a later character must try again.
;;; Without a usable row mapping, replace the primary identity instead of
;;; inferring independent releases.
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

;;; A/X/Y16, IRQs masked, event-ring capacity reserved by the caller.
;;; Consume a published row result or retire a request left by rendering.
;;; A phase-4 reply may already be ready: validate it before restoring ADB
;;; ownership. An incomplete read retains held identities for a later retry.
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
              phb
              phk
              plb
              jsr .kbank pumpOwned
              plb
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
              phb
              phk
              plb
              jsr .kbank pumpSaveStatus
              plb
pumpAbortEmpty:
              phb
              phk
              plb
              jsr .kbank pumpComplete
              plb        ; restore enables and replay a real SRQ
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
;;; Carry set only when this result covers the key's row and its active-low
;;; bit is now up. A reply for another row says nothing about this identity.
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

;;; A/X/Y16, IRQs masked. Arm work only while playing a level with no menu.
;;; Select a row and, if distinct, one following row; pumpInstall attaches
;;; the column hook but does not acquire the controller or send a command.
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
              phb
              phk
              plb
              sep #0x20                  ; Both game flags were zero, so B is zero.
              lda abs:.word0 pumpThird
              cmp #NONE
              beq pumpChoosePair
              lda abs:.word0 pumpAlternate
              inc a
              cmp #3
              bcc pumpChooseReady
              lda #0
              bra pumpChooseReady
pumpChoosePair:
              lda abs:.word0 pumpAlternate
              and #1
              eor #1
pumpChooseReady:
              sta abs:.word0 pumpAlternate
              tax
              lda abs:.word0 pumpRowsCached,x
              sta abs:.word0 pumpRow
              lda abs:.word0 pumpMasksCached,x
              sta abs:.word0 pumpExpected
              lda abs:.word0 pumpThird
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
              lda abs:.word0 pumpRowsCached,x
              sta abs:.word0 pumpNextRow
              cmp abs:.word0 pumpRow
              beq pumpOneRow
              lda #1
              bra pumpSetBatch
pumpOneRow:   lda #0
pumpSetBatch: sta abs:.word0 pumpBatch
              lda abs:.word0 pumpMasksCached,x
              sta abs:.word0 pumpNextMask
              rep #0x20
              jsr .kbank pumpInstall
              plb
pumpScheduleDone: rts
;;; Cache each held slot's row and combine masks for slots sharing a row.
;;; A reply is accepted only if no switch outside these masks is down.
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

;;; Keep this 529-byte footprint fixed: following entry addresses are part
;;; of the runtime patch/cache layout.
#if TICSTEP > 1
 ; Timestamped input places the Escape helpers inside this reserved span.
 ; TICSTEP == 1 places them after the silent-alarm helpers below.
#include "j13escape.inc"
              .space 529-(j13EscapeEnd-J13EscapeCheck),0xea
#else
              .space 529,0xea
#endif

;;; Stopped music shares oscillator 30 with the song player. Keep this code
;;; after the capture/pump tables so its installation preserves their cache
;;; placement. IRQ patches must also update the image restored after disk I/O.
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
              jsr     .kbank silentHookPoll
              rep     #0x20
              pla
              jmp     long:(J13Arm+4)

J13PollSilent:
              php
              sei
              rep     #0x20
              sep     #0x20
              jsr     .kbank J13EnsureAlarm
              jmp     long:pollEntry

 ; A8; caller masks IRQs. musOn gives the song player oscillator 30 and
 ; removes this poll hook. musPend prevents silent setup during a song load.
 ; Otherwise silentPhase advances frequency-low, frequency-high, restart,
 ; retaining its phase across DOC BUSY. The silent interval is about 32 ms;
 ; frame rate does not determine it. Once started, it loops until the normal
 ; alarm-stop path halts it. A song restores one-shot mode for its waits.
              .public J13SilentIRQ, J13SilentEnd, J13AlarmOff, J13EnsureAlarm, silentActive, silentPhase
silentActive: .byte 0
silentPhase:  .byte 0
J13EnsureAlarm:
              lda     long:silentActive
              beq     silentNotActive
              bra     silentPollReady
silentNotActive:
              lda     long:musOn
              beq     silentCheckPending
silentPollReady:
              rep     #0x20                 ; A running alarm needs no per-tic setup check.
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
              lda     #0x08                 ; Free-running, interrupt on; no rearm work.
              sta     long:0xe0c03d
              lda     #1
              sta     long:silentActive
              bra     silentPollReady
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
 ; Capture preserves X/Y. Save only B here; the original IRQ saved A.
J13SilentIRQ:
              xba
              pha
              lda     long:silentActive
              beq     silentFirstWake       ; The pending final wake of a non-looping song.
              bra     silentSample
silentFirstWake:
              jsr     .kbank silentHookPoll
              jsr     .kbank J13EnsureAlarm  ; Set the fixed silent interval once.
silentSample: jsr     .kbank captureStrobe
 ; Silent wakes capture register edges only. The existing column pump owns
 ; its bounded MCU checks; spending that budget from a second site can leave
 ; a completed row reply holding off an ADB tap until the next game poll.
silentReturn:
              pla
              xba
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

;;; Request controller buffering (mode bit 4) so C010 acknowledgement can
;;; advance characters to C000. This is separate from the software capture
;;; FIFO; neither makes sampling an unbounded or lossless event stream.
;;; ReadModes records whether buffering was already on. Set bufferRestore
;;; before attempting the change so shutdown can undo even a partial setup.
;;; These commands leave ADB autopoll and keyboard interrupt enables alone.
bufferRestore: .byte 0
bufferKeyboard:
              lda     #0x0a
              jsr     .kbank sendBounded
              bcs     bufferDone
              jsr     .kbank readBounded
              bcs     bufferDone
              and     #0x10
              bne     bufferDone
              lda     #0x10
              sta     long:bufferRestore
              lda     #0x04
              jsr     .kbank sendBounded
              bcs     bufferDone
              lda     #0x10
              jsr     .kbank sendBounded
bufferDone:   jsr     .kbank stopFirmwareRepeat
              ldx     ##0                   ; First scanner-signature byte.
              rts

;;; Finish any raw ADB Talk before restoring our temporary buffering mode.
;;; Preserve the state returned by IIGS_StopKeys; both shutdown paths use this.
              .public IIGS_StopStealth
IIGS_StopStealth:
              jsl     long:IIGS_StopKeys
              php
              sei
              rep     #0x30
              pha
              phx
              phy
              sep     #0x20
              jsr     .kbank restoreFirmwareRepeat
              lda     long:bufferRestore
              beq     bufferRestored
              lda     #0x05
              jsr     .kbank sendBounded
              bcs     bufferRestored
              lda     #0x10
              jsr     .kbank sendBounded
              bcs     bufferRestored
              lda     #0
              sta     long:bufferRestore
bufferRestored:
              rep     #0x30
              ply
              plx
              pla
              plp
              rtl

;;; A firmware repeat can occupy the character latch ahead of a new key.
;;; Doom tracks held keys and repeats menu arrows itself. Keep the controller
;;; buffer, but disable its repeat during the game and restore it on exit.
;;; Read/Set Configuration preserve the keyboard/mouse addresses, language
;;; and repeat rate. Delay bits 6:4 = 4 select no repeat; preserve bit 7
;;; and the low rate nibble. Save the original configuration before sending
;;; any replacement bytes so shutdown can attempt restoration after a timeout.
repeatRestore: .byte 0
keyboardConfig: .space 3,0
stopFirmwareRepeat:
              lda     #0x0b
              jsr     .kbank sendBounded
              bcs     repeatSetupDone
              ldx     ##0
readKeyboardConfig:
              jsr     .kbank readBounded
              bcs     repeatSetupDone
              sta     long:keyboardConfig,x
              inx
              cpx     ##3
              bcc     readKeyboardConfig
              lda     long:(keyboardConfig+2)
              and     #0x70
              cmp     #0x40
              beq     repeatSetupDone
              lda     #1
              sta     long:repeatRestore
              jsr     .kbank sendKeyboardConfig
              bcs     repeatSetupDone
              lda     long:(keyboardConfig+2)
              and     #0x8f
              ora     #0x40
              jsr     .kbank sendBounded
repeatSetupDone:
              rts

;;; Send the command and unchanged first two bytes. The caller supplies the
;;; final repeat byte. Carry reports a bounded controller timeout.
sendKeyboardConfig:
              lda     #0x06
              jsr     .kbank sendBounded
              bcs     configDone
              lda     long:keyboardConfig
              jsr     .kbank sendBounded
              bcs     configDone
              lda     long:(keyboardConfig+1)
              jsr     .kbank sendBounded
configDone:   rts

restoreFirmwareRepeat:
              lda     long:repeatRestore
              beq     repeatRestored
              jsr     .kbank sendKeyboardConfig
              bcs     repeatRestored
              lda     long:(keyboardConfig+2)
              jsr     .kbank sendBounded
              bcs     repeatRestored
              lda     #0
              sta     long:repeatRestore
repeatRestored:
              rts

 ; A pending recovery survives a completed tap. The all-up FIFO snapshot
 ; still carries its character, even though live modifiers are no longer
 ; associated with a held key. An ordinary live sample must still wait.
sampleRecoveryReady:
              lda     long:pumpRepeat
              bit     #0x20
              beq     recoveryReady
              lda     long:captureSampled
              beq     recoveryNotReady
              lda     long:sampleAKD
              bmi     recoveryNotReady
              lda     long:pumpRepeat
recoveryReady:
              clc
              rts
recoveryNotReady:
              sec
              rts

#if TICSTEP == 1
#include "j13escape.inc"
#endif

;;; Mode changes own dispatch and capture-hook installation. j13Enabled is
;;; the saved/requested gameplay option; j13InputMode is the installed reader.
;;; ROM 00/01 menus always use compatibility input. Mode 2 additionally arms
;;; IRQ capture and row checks; mode 0 consumes raw ADB plus the frame Escape
;;; hook. Fixed entry points below resume displaced loads at caller +4/+6.
              .section j13cold, text
              .public j13Enabled, j13Available, j13InputMode
              .public J13Toggle, J13MenuOpen, J13MenuClose, J13LevelStart
              .public J13TitleStart, J13SettingsInit, J13SettingsCollect, J13DemoStart
              .extern uiOpen, I_MenuPaletteBack, displayCall, HU_Start
              .extern D_StartTitle, _g_gameaction, _g_usergame, _g_demoplayback
              .extern _g_timingdemo, settingsFile, menuNum
j13Enabled:   .word 0
j13Available: .word 0
j13InputMode: .word 0                 ; 0 raw ADB, 1 menus, 2 J13 gameplay
j13NextMode:  .word 0
              .space 13              ; Keep keyboard transition entries fixed.

;;; A16 holds VW_TWIRQ and carry still reports checkFile's validity; the
;;; intervening flag normalization preserves carry. Store that value before
;;; loading byte 23: invalid/zero means J13 off, any nonzero valid byte means
;;; on. Older settings leave this reserved byte zero. No write occurs here.
J13SettingsInit:
              sta long:VW_TWIRQ
              lda ##0
              bcs j13SettingsDefault
              lda long:(settingsFile+23)
              and ##0xff
              beq j13SettingsDefault
              lda ##1
j13SettingsDefault:
              sta long:j13Enabled
              rtl

;;; A8: the normal settings collector owns the checksum and disk write.
J13SettingsCollect:
              lda long:VW_TWIRQ
              sta long:(settingsFile+22)
              lda long:j13Enabled
              sta long:(settingsFile+23)
              rtl

;;; Change the requested option only; the active menu reader stays in place
;;; until j13Resume chooses gameplay input when the menu closes.
J13Toggle:    lda long:j13Enabled
              eor ##1
              sta long:j13Enabled
              rtl                           ; Menu input remains selected until close.

J13MenuOpen:  lda ##1
              jsr .kbank j13SetMode
              lda long:(displayCall+1)      ; Displaced uiOpen instruction.
              jmp long:(uiOpen+4)
J13MenuClose: jsr .kbank j13Resume
              lda long:UI_SINGLETIC         ; Displaced palette restore instruction.
              jmp long:(I_MenuPaletteBack+4)
J13LevelStart:
              jsl long:HU_Start
              jsr .kbank j13Resume
              rtl
J13DemoStart: jsr .kbank j13Resume
              jmp long:I_GetTime
J13TitleStart:
              lda ##1
              jsr .kbank j13SetMode
              lda ##0
              sta long:_g_gameaction
              lda ##0xffff
              jmp long:(D_StartTitle+6)

;;; Timedemos select raw ADB; title/attract playback selects the menu reader.
;;; Only a user-controlled level uses the saved gameplay option.
j13Resume:    lda long:_g_timingdemo
              bne j13Raw
              lda long:_g_usergame
              beq j13Menu
              lda long:_g_demoplayback
              bne j13Menu
              lda long:j13Enabled
              beq j13Raw
              lda ##2
              bra j13SetMode
j13Menu:      lda ##1
              bra j13SetMode
j13Raw:       lda ##0
;;; A16 = requested mode. Preserve A/X/Y/P while masking all patch writes.
;;; Unsupported ROMs force mode 0. Retire capture before switching readers;
;;; raw-to-menu entry drains disabled-gameplay characters before accepting
;;; menu input, while game-to-menu entry retains its queued input.
j13SetMode:   php
              sei
              rep #0x30
              pha
              phx
              phy
              ldx ##0
              pha
              lda long:j13Available
              bne j13ModeAvailable
              pla
              txa
              bra j13ModeCheck
j13ModeAvailable:
              pla
j13ModeCheck: cmp long:j13InputMode
              beq j13ModeDone
              sta long:j13NextMode
              jsr .kbank j13StopCapture
              lda long:j13InputMode
              tax
              lda long:j13NextMode
              sta long:j13InputMode
              beq j13SelectRaw
              cmp ##2
              beq j13SelectGame
              cpx ##0
              bne j13MenuKeepInput
              jsr .kbank installMenuDrainReader
              bra j13ModeDone
j13MenuKeepInput:
              jsr .kbank installMenuReader
              bra j13ModeDone
j13SelectGame:
              jsl long:J13Arm
              bra j13ModeDone
j13SelectRaw:
              jsr .kbank j13InstallEscape
              lda ##.word0 I_StartTic
              sta long:(keyboardTicCall+1)
#if TICSTEP > 1
              lda ##.word0 I_StartTicUntil
#endif
              sta long:(keyboardBuildCall+1)
              sep #0x20
              lda #.byte2 I_StartTic
              sta long:(keyboardTicCall+3)
              sta long:(keyboardBuildCall+3)
              rep #0x20
j13ModeDone:  ply
              plx
              pla
              plp
              rts

;;; A/X/Y16, IRQs masked by j13SetMode. Retire or discard the outstanding
;;; row transaction before restoring ADB dispatch. Stop only a silent-owned
;;; alarm; a playing song retains oscillator 30. Restore both the live IRQ
;;; patch sites and their disk-I/O load image before changing tic dispatch.
j13StopCapture:
              lda long:j13InputMode
              cmp ##2
              bne j13StopDone
              jsr .kbank j13QueueRoom
              jsr .kbank pumpCollect
              lda long:pumpState
              beq j13NoRequest
              jsr .kbank pumpRemove
j13NoRequest: sep #0x20
              lda long:silentActive
              beq j13NoSilentAlarm
              jsl long:IIGS_AlarmOff
j13NoSilentAlarm:
              rep #0x20
              lda ##0x3d8f                 ; STA long:$E0C03D
              sta long:J13AlarmSite
              sta long:(J13AlarmSite-0x2200)
              lda ##0xe0c0
              sta long:(J13AlarmSite+2)
              sta long:(J13AlarmSite-0x2200+2)
              lda ##0x4068                 ; Original PLA / RTI.
              sta long:J13SilentExit
              sta long:(J13SilentExit-0x2200)
              lda ##0x7808                 ; PHP / SEI
              sta long:IIGS_AlarmOff
              sta long:IIGS_PollStealth
              lda ##0x20e2                 ; SEP #$20
              sta long:(IIGS_AlarmOff+2)
              lda ##0x20c2                 ; REP #$20
              sta long:(IIGS_PollStealth+2)
              lda ##0
              sta long:j13Armed
j13StopDone:  rts

;;; A/X/Y16, IRQs masked. Make sixteen free ring slots through I_StartTic;
;;; do not advance its tail directly. Multiple calls may be needed because
;;; a down/up tap deliberately leaves its release queued for the next call.
j13QueueRoom:
              lda long:iigs_adbqtail
              sec
              sbc long:iigs_adbqhead
              dec a
              and ##31
              cmp ##16
              bcs j13QueueReady
              jsl long:I_StartTic
              bra j13QueueRoom
j13QueueReady: rts

              .section stealthcode, text
;;; On entry to raw mode, queue releases for the adapter's held identities,
;;; then clear its private capture FIFO/recovery state. Capture is already
;;; stopped and IRQs are masked. Queued ADB events stay in the shared ring;
;;; that ring carries identities, not a separate source-device tag.
j13ReleaseHeld:
              jsr .kbank j13QueueRoom
              jsr .kbank releaseOrdinary
              lda long:pumpSecond
              cmp ##NONE
              beq j13ReleaseThird
              ora ##0x80
              jsr .kbank queue
j13ReleaseThird:
              lda long:pumpThird
              cmp ##NONE
              beq j13ReleaseModifiers
              ora ##0x80
              jsr .kbank queue
j13ReleaseModifiers:
              ldx ##0
j13ReleaseModifier:
              lda long:modifierMasks,x
              and ##0xff
              and long:stealthMods
              beq j13ReleaseNext
              lda long:modifierKeys,x
              and ##0xff
              ora ##0x80
              jsr .kbank queue
j13ReleaseNext:
              inx
              cpx ##5
              bcc j13ReleaseModifier
              lda ##NONE
              sta long:pumpSecond
              sta long:pumpThird
              lda ##0
              sta long:stealthMods
              sta long:stealthRecover
              sta long:pumpAmbiguous
              sta long:pumpResult
              sta long:captureHead
              sta long:captureTail
              sep #0x20
              sta long:modifierLatch
              sta long:pollWork
              sta long:captureLastAKD
              rep #0x20
              rts

;;; Keys typed while J13 gameplay was disabled are not menu commands. Drain
;;; only the compatibility latch, at menu polls, until it is empty and up.
;;; ADB events continue through the normal consumer throughout this transition.
installMenuDrainReader:
              jsr .kbank j13EscapeToMenu
              lda ##.word0 J13MenuDrainTic
              sta long:(keyboardTicCall+1)
#if TICSTEP > 1
              lda ##.word0 J13MenuDrainTicUntil
#endif
              sta long:(keyboardBuildCall+1)
              rts
J13MenuDrainTic:
              jsr .kbank j13DrainMenu
              jmp long:I_StartTic
#if TICSTEP > 1
J13MenuDrainTicUntil:
              pha
              jsr .kbank j13DrainMenu
              pla
              jmp long:I_StartTicUntil
#endif
j13DrainMenu: php
              sei
              rep #0x20
              pha
              sep #0x20
              lda long:KBD
              bpl j13MenuNoStrobe
              lda long:AKD
              bra j13MenuDrainDone
j13MenuNoStrobe:
              lda long:AKD
              bmi j13MenuDrainDone
              lda long:KBD
              and #0x7f
              sta long:stealthASCII
              lda #0
              sta long:captureLastAKD
              rep #0x20
              lda ##0
              sta long:stealthAKD
              sta long:stealthRecover
              jsr .kbank installMenuReader
j13MenuDrainDone:
              rep #0x20
              pla
              plp
              rts

              .section j13pump, text
;;; A8 = column index, X/Y16. Check every fourth column without a video
;;; counter read. Preserve low A, P and DBR; the displaced four bytes execute
;;; in pumpOriginal before jumping back to the selected view. They replace
;;; accumulator B before any view uses it, so B need not be saved here.
pumpColumn:  cmp #0                        ; next column index, patched in place
              bne pumpOriginal
              php
              sei
              pha
              phb
              phk
              plb
              clc
              adc #4                         ; skip the next three column calls
              sta abs:.word0 (pumpColumn+1)
              jsr .kbank pumpCore
              plb
              pla
              plp
              .public pumpOriginal
pumpOriginal: .space 4,0xea
pumpReturn:   jmp long:(J13ColumnSite+4)

;;; A8, DBR = this bank, X/Y preserved, caller masks IRQs. Samples status once
;;; and advances a protocol phase without waiting. A stable first-row reply
;;; can chain the second command using that sampled ready status.
;;; The installed column hook and IRQ caller guarantee a nonzero state.
;;; pumpInstall budgets twelve checks per batch. On exhaustion, pumpDrainReady
;;; allows one final status read only for a completed parameter sequence,
;;; then removes the column hook. The game poll retires any expired owner.
pumpCore:     dec abs:.word0 pumpBudget
              bmi pumpPause
              lda long:ADBSTATUS
              sta abs:.word0 pumpStatus
              lda abs:.word0 pumpState
              cmp #1
              bne pumpOwned
              sta abs:.word0 pumpRendering
              lda long:adbTalk
              bne pumpCoreDone
              lda abs:.word0 pumpStatus
              and #0xa1
              bne pumpCoreDone
              jsr .kbank pumpOwnIRQ
              lda abs:.word0 pumpStatus
              and #0x50
              sta abs:.word0 pumpEnables
              lda abs:.word0 pumpStatus
              and #0xaf
              sta long:ADBSTATUS
              lda #9
              jmp .kbank pumpWrite
pumpCoreDone: rts
pumpPause:    jmp long:pumpDrainReady
              nop                           ; Keep the expiry continuation at pumpPause+5.
              sep #0x20
              lda abs:.word0 pumpState
              cmp #1
              beq pumpNeverOwned
              sta abs:.word0 pumpExpired
              lda #5
              sta abs:.word0 pumpState
              rts
pumpNeverOwned:
              lda #0
              sta abs:.word0 pumpState
              rts
pumpOwned:    lda abs:.word0 pumpStatus
              bit #0x20
              beq pumpSend
              lda long:ADBDATA
              sta abs:.word0 pumpRaw
              lda abs:.word0 pumpState
              cmp #4
              bne pumpSaveStatus
              lda abs:.word0 pumpRaw
              ; Invert the active-low row. Equality means no tracked release;
              ; a strict subset can release keys. Extra down bits make the
              ; reply ambiguous, so retain the held state and keep waiting.
              ; Publish only a changed row; never overwrite an unread result
              ; by chaining another row after a release.
              eor #0xff
              cmp abs:.word0 pumpExpected
              beq pumpStableRow
              ora abs:.word0 pumpExpected
              cmp abs:.word0 pumpExpected
              bne pumpSaveStatus
              lda abs:.word0 pumpRaw
              sta abs:.word0 pumpValue
              lda #1
              sta abs:.word0 pumpResult
              sta abs:.word0 pollWork
              jmp .kbank pumpComplete
pumpStableRow:
              lda abs:.word0 pumpBatch
              bne pumpChain
              jmp .kbank pumpComplete
pumpChain:    lda #0
              sta abs:.word0 pumpBatch
              lda abs:.word0 pumpNextRow
              sta abs:.word0 pumpRow
              lda abs:.word0 pumpNextMask
              sta abs:.word0 pumpExpected
              lda #6
              sta abs:.word0 pumpState
              lda abs:.word0 pumpStatus
              and #1
              bne pumpOwnedDone
              bra pumpNextCommand
 ; Accumulate only bytes shaped like controller status: bits 7 and 2:0
 ; must be clear. pumpComplete replays bit 3 (keyboard SRQ); rejected data
 ; does not establish a release, so the held identities remain unchanged.
pumpSaveStatus:
              lda abs:.word0 pumpRaw
              and #0x87
              bne pumpOwnedDone             ; unresolved row-shaped data is not SRQ
              lda abs:.word0 pumpRaw
              ora abs:.word0 pumpDeferred
              sta abs:.word0 pumpDeferred
              rts
pumpOwnedDone: rts
pumpSend:     lda abs:.word0 pumpStatus
              and #1
              bne pumpOwnedDone
              lda abs:.word0 pumpState
              cmp #2
              beq pumpLow
              cmp #6
              beq pumpNextCommand
              cmp #3
              bne pumpOwnedDone
              lda #0
              bra pumpWrite
pumpNextCommand:
              lda #1
              sta abs:.word0 pumpState
              lda #9
              bra pumpWrite
pumpLow:      lda abs:.word0 pumpRow
pumpWrite:
              sta long:ADBDATA
              sta long:ZIPCANCEL
              inc abs:.word0 pumpState
              rts
;;; A8, DBR = this bank, IRQs masked. Release DATA/mouse interrupt ownership
;;; before removing hooks; a deferred raw-keyboard Talk sets adbTalk so the
;;; normal parser owns its eventual reply. Returns A8, X/Y unchanged.
pumpComplete:
              lda abs:.word0 pumpStatus
              and #0xaf
              ora abs:.word0 pumpEnables
              sta long:ADBSTATUS
              lda abs:.word0 pumpDeferred
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
pumpView:     .word 0xffff
 ; Called by pumpSchedule with DBR set to this bank; X is scratch.
pumpInstall:
              lda long:VW_SIZE
              cmp abs:.word0 pumpView
              beq pumpReuseView
              cmp ##11
              bcc pumpViewValid
              lda ##10
pumpViewValid: sta abs:.word0 pumpView
              asl a
              tax
              lda abs:.word0 pumpSites,x
              sta abs:.word0 pumpSite
              tax
              clc
              adc ##4
              sta long:(pumpReturn+1)
              lda long:0x050000,x
              sta abs:.word0 pumpOriginal
              lda long:(0x050000+2),x
              sta long:(pumpOriginal+2)
pumpReuseView:
              lda abs:.word0 pumpSite
              tax
              lda ##.word0 pumpColumn
              sta long:(0x050000+1),x
              sep #0x20
              lda #1
              sta abs:.word0 pumpState
              lda #0
              sta abs:.word0 pumpRendering
              lda #12
              sta abs:.word0 pumpBudget
              lda #0
              sta abs:.word0 pumpDeferred
              sta long:(pumpColumn+1)
              lda #.byte2 pumpColumn
              sta long:(0x050000+3),x
              lda #0x5c
              sta long:0x050000,x
              rep #0x20
              rts
;;; Mask only the IRQ's AND immediate; reading STATUS does not consume DATA.
;;; Update its load image too, or disk I/O would lose the patch.
pumpOwnIRQ:  lda #0                     ; AND #0 makes the IRQ skip ADB DATA.
              sta long:(J13StatusSite+5)
              sta long:(J13StatusSite-0x2200+5)
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
              sep #0x20
              lda #0xa0                  ; Restore DATA-ready and mouse-ready checks.
              sta long:(J13StatusSite+5)
              sta long:(J13StatusSite-0x2200+5)
              rep #0x20
              lda ##0
              sta long:pumpState
              rts

;;; These wrappers translate/consume input first, then inspect the last
;;; compatibility sample while a menu is active. A strobed character with
;;; an ASCII mapping enables the gameplay option once per run; modifiers
;;; alone do not. j13MenuSeen prevents later detection from undoing a manual
;;; OFF choice. Increment menuversion to redraw the row, without saving it.
;;; Gameplay dispatch never calls these detection wrappers.
              .section j13auto, text
              .public J13MenuTic, j13MenuSeen
              .extern menuversion, _g_menuactive
j13MenuSeen:  .word 0
J13MenuTic:   jsl long:I_StealthStartTic
              jmp long:j13MenuDetect
#if TICSTEP > 1
              .public J13MenuTicUntil
J13MenuTicUntil:
              jsl long:I_StealthStartTicUntil
              jmp long:j13MenuDetect
#endif
j13MenuDetect:
              lda long:j13MenuSeen
              bne j13MenuDetectDone
              lda long:_g_menuactive
              beq j13MenuDetectDone
              lda long:stealthSample
              bit ##0x80                   ; An ordinary character from the matrix path.
              beq j13MenuDetectDone
              and ##0x7f
              tax
              lda long:asciiKeys,x
              and ##0xff
              cmp ##NONE
              beq j13MenuDetectDone
              lda ##1
              sta long:j13Enabled
              sta long:j13MenuSeen
              lda long:menuversion
              inc a
              sta long:menuversion
j13MenuDetectDone:
              rtl

;;; Raw ADB polling suppresses its compatibility characters. Flush startup
;;; input only after that mode change, then reset the adapter's last sample
;;; so boot characters do not count as menu recognition.
J13StartKeys: jsl long:IIGS_StartKeys
              php
              rep #0x20
              lda long:j13Available
              beq j13StartDone
              jsr .kbank j13PrimeMenu
j13StartDone: plp
              rtl
j13Selected: jsr .kbank j13PrimeMenu
              rep #0x30
              ply
              plx
              pla
              plp
              rtl
j13PrimeMenu:
              php
              sei
              sep #0x20
              phy
              lda #0x03                    ; Flush buffered startup characters.
              jsr .kbank sendBounded
              lda long:AKD
              lda long:KBD
              and #0x7f
              sta long:stealthASCII
              lda #0
              sta long:stealthSample
              ply
              plp
              rts
