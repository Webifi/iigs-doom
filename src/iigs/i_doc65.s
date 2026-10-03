;;; Ensoniq DOC access: the tic timer, the
;;; alarm of the game interrupt, and the register and RAM access of the
;;; sound code in src/iigs/s_sound65.s.
;;;
;;; All 32 oscillators run: 0-15 sound effects, 16-29 music, 30 the alarm,
;;; 31 the timer (the highest one is silent: MAME plays it louder).
;;; Timer: one silent oscillator scans a 256-byte ramp in DOC RAM, one step
;;; for each tic. The data register of the oscillator holds the ramp byte
;;; that it read last, so I_GetTime needs no interrupt.
;;; Alarm: a silent one-shot oscillator on the same ramp, with its
;;; interrupt on: it halts and interrupts after ALARM_FREQ steps, and
;;; the interrupt starts it again (src/iigs/irq65.s).
;;; Each DOC sequence of the main code masks interrupts: the interrupt also
;;; uses the GLU.
;;; Volume: bits 3-0 of the GLU control register are the volume of the
;;; owner (the Control Panel). The game does not change it.
;;; IIGS_InitDocVolume reads the system volume ($E100CA) into DOCVOL, and
;;; each write of the control register uses that value. IIGS_InitDocTimer
;;; calls it first, and so does the sound shutdown (I_Error can come before).

              .rtmodel version, "1"
              .rtmodel core, "*"

              .extern _Dp

SOUNDCTL      .equ    0xe0c03c        ; bit 7 busy, bit 6 RAM, bit 5 auto increment,
SOUNDDATA     .equ    0xe0c03d        ; bits 3-0 volume
SOUNDADRL     .equ    0xe0c03e
SOUNDADRH     .equ    0xe0c03f
SYSVOLUME     .equ    0xe100ca        ; the system volume, bits 3-0
DOCVOL        .equ    0xff            ; the volume for SOUNDCTL, bits 3-0: the byte
DOCVOL_LONG   .equ    0x0009ff        ;   $09FF of the direct page (src/iigs/iigs.scm)

DOC_OSCS      .equ    32              ; scan rate 894886 Hz / (32 + 2) = 26320 Hz
TIMER_OSC     .equ    31
TIMER_PAGE    .equ    0xff            ; DOC RAM page of the ramp
TIMER_FREQ    .equ    87              ; 26320 Hz * 87 / 65536 = 34.94 steps a second
ALARM_OSC     .equ    30
ALARM_FREQ    .equ    249             ; one pass: 131072 / 249 = 526 samples = 20 ms
ALARM_CTL     .equ    0x0a            ; one-shot, interrupt on, running

;;; One byte of IIGS_DocUpload. 8-bit A.
UPBYTE        .macro
              lda     [.tiny _Dp],y
              sta     long:SOUNDDATA
              iny
              .endm

              .section znear, bss
tmSteps:      .space  4               ; ramp steps since IIGS_InitDocTimer
tmLast:       .space  2               ; the ramp byte of the last read
upDoc:        .space  2               ; IIGS_DocUpload: the DOC address
upCount:      .space  2               ;   and the bytes of a page

;;; ***************************************************************************
;;;
;;; IIGS_InitDocTimer - halt all oscillators and start the timer oscillator.
;;;
;;; ***************************************************************************

              .section farcode, text
              .public IIGS_InitDocTimer
IIGS_InitDocTimer:
              jsl     long:IIGS_InitDocVolume
              php
              sei
              sep     #0x20
              ldx     ##0xa0                ; control: halt all 32 oscillators
1$:           lda     #1
              jsr     .kbank docSet
              inx
              cpx     ##0xc0
              bne     1$

              ;; the ramp: byte i = i, byte 0 = 255 because 0 halts the oscillator
              jsr     .kbank docRamMode
              lda     #0
              sta     long:SOUNDADRL
              lda     #TIMER_PAGE
              sta     long:SOUNDADRH
              lda     #255
              sta     long:SOUNDDATA
              lda     #1
3$:           sta     long:SOUNDDATA
              inc     a
              bne     3$

              ldx     ##0xe1                ; oscillators enabled
              lda     #(DOC_OSCS - 1) * 2
              jsr     .kbank docSet
              ldx     ##TIMER_OSC           ; frequency
              lda     #TIMER_FREQ
              jsr     .kbank docSet
              ldx     ##(0x20 + TIMER_OSC)
              lda     #0
              jsr     .kbank docSet
              ldx     ##(0x40 + TIMER_OSC)  ; volume 0
              lda     #0
              jsr     .kbank docSet
              ldx     ##(0x80 + TIMER_OSC)  ; wavetable pointer
              lda     #TIMER_PAGE
              jsr     .kbank docSet
              ldx     ##(0xc0 + TIMER_OSC)  ; 256-byte table, resolution 7
              lda     #0x07
              jsr     .kbank docSet
              ldx     ##(0xa0 + TIMER_OSC)  ; free run, no interrupt, run
              lda     #0
              jsr     .kbank docSet
              ldx     ##ALARM_OSC           ; the alarm: halted until
              lda     #ALARM_FREQ           ;   a song starts it
              jsr     .kbank docSet
              ldx     ##(0x20 + ALARM_OSC)
              lda     #0
              jsr     .kbank docSet
              ldx     ##(0x40 + ALARM_OSC)
              lda     #0
              jsr     .kbank docSet
              ldx     ##(0x80 + ALARM_OSC)
              lda     #TIMER_PAGE
              jsr     .kbank docSet
              ldx     ##(0xc0 + ALARM_OSC)  ; 256-byte table, resolution 0
              lda     #0
              jsr     .kbank docSet

              jsr     .kbank readRamp
              rep     #0x20
              and     ##0x00ff
              sta     .near tmLast
              stz     .near tmSteps
              stz     .near (tmSteps+2)
              plp
              rtl
              .space  7                     ; (I_GetTime keeps its address)


;;; ***************************************************************************
;;;
;;; int32_t I_GetTime(void) - time in 1/35 second tics.
;;;
;;; ***************************************************************************

              .public I_GetTime
I_GetTime:    php
              sei
              sep     #0x20
              jsr     .kbank readRamp
              rep     #0x20
              and     ##0x00ff
              tax
              sec                           ; steps since the last read
              sbc     .near tmLast
              and     ##0x00ff
              clc
              adc     .near tmSteps
              sta     .near tmSteps
              bcc     1$
              inc     .near (tmSteps+2)
1$:           stx     .near tmLast
              lda     .near tmSteps
              ldx     .near (tmSteps+2)
              plp
              rtl

;;; ***************************************************************************
;;;
;;; IIGS_InitDocVolume - DOCVOL = the system volume. IIGS_InitDocTimer and
;;; the sound shutdown call it. This is the only volume that the game writes
;;; to the control register.
;;;
;;; ***************************************************************************

              .public IIGS_InitDocVolume
IIGS_InitDocVolume:
              php
              sep     #0x20
              lda     long:SYSVOLUME
              and     #0x0f
              sta     long:DOCVOL_LONG
              sta     long:(rampVolume+1)   ; cache the same byte in the clock-read immediate
              plp
              rtl

;;; docRegMode: wait for the GLU, then registers, no auto increment. 8-bit A.
;;; Long addresses only: in a build with TICSTEP > 1 the interrupt reads
;;; the clock, and D is that of the interrupted code.
docRegMode:   lda     long:SOUNDCTL
              bmi     docRegMode
              lda     long:DOCVOL_LONG
              sta     long:SOUNDCTL
              rts

;;; docRamMode: wait for the GLU, then DOC RAM, auto increment. 8-bit A.
docRamMode:   lda     long:SOUNDCTL
              bmi     docRamMode
              lda     dp:DOCVOL
              ora     #0x60
              sta     long:SOUNDCTL
              rts

              .space  2                     ; (the room of IIGS_Alarm: the code
                                            ;   after it keeps its address)

;;; IIGS_AlarmOff: the alarm halted (its interrupt waits no more).
              .public IIGS_AlarmOff
IIGS_AlarmOff:
              php
              sei
              sep     #0x20
              rep     #0x10
              ldx     ##(0xa0 + ALARM_OSC)
              lda     #1
              jsr     .kbank docSet
              plp
              rtl

;;; docSet: DOC register X = A. 8-bit A, 16-bit X.
docSet:       pha
1$:           lda     long:SOUNDCTL
              bmi     1$
              lda     dp:DOCVOL             ; registers, no auto increment
              sta     long:SOUNDCTL
              txa
              sta     long:SOUNDADRL
              pla
              sta     long:SOUNDDATA
              rts

;;; readRamp: A = the data register of the timer oscillator. 8-bit A.
;;; The immediate is filled from SYSVOLUME by IIGS_InitDocVolume. This keeps
;;; the clock read at its original cost and works with any interrupted D.
readRamp:     lda     long:SOUNDCTL
              bmi     readRamp
rampVolume:   lda     #0
              sta     long:SOUNDCTL
              lda     #(0x60 + TIMER_OSC)
              sta     long:SOUNDADRL
              lda     long:SOUNDDATA        ; the first read only starts the access
              lda     long:SOUNDDATA
              rts

;;; ***************************************************************************
;;;
;;; void IIGS_DocWrite2(uint16_t reg, uint16_t values)
;;; DOC register reg = the low byte of values, reg + 1 = the high byte.
;;; In: C = reg, _Dp[0-1] = values.
;;;
;;; ***************************************************************************

              .public IIGS_DocWrite2
IIGS_DocWrite2:
              php
              sei
              sep     #0x20
              tax
1$:           lda     long:SOUNDCTL
              bmi     1$
              lda     dp:DOCVOL
              ora     #0x20                 ; registers, auto increment
              sta     long:SOUNDCTL
              txa
              sta     long:SOUNDADRL
              lda     dp:.tiny _Dp
              sta     long:SOUNDDATA
              lda     dp:.tiny (_Dp+1)      ; the next byte waits until this
              pha                           ;   one has left the latch
2$:           lda     long:SOUNDCTL
              bmi     2$
              pla
              sta     long:SOUNDDATA
              plp
              rtl

;;; ***************************************************************************
;;;
;;; uint16_t IIGS_DocRead(uint16_t reg) - the DOC register reg.
;;;
;;; ***************************************************************************

              .public IIGS_DocRead
IIGS_DocRead: php
              sei
              sep     #0x20
              tax
1$:           lda     long:SOUNDCTL
              bmi     1$
              lda     dp:DOCVOL
              sta     long:SOUNDCTL
              txa
              sta     long:SOUNDADRL
              lda     long:SOUNDDATA        ; the first read only starts the access
              lda     long:SOUNDDATA
              rep     #0x20
              and     ##0x00ff
              plp
              rtl

;;; ***************************************************************************
;;;
;;; void IIGS_DocUpload(uint16_t docaddr, const uint8_t __far* src, uint16_t len)
;;; Copies len bytes to DOC RAM at docaddr (a page), then a 0 byte, which
;;; stops an oscillator. In: C = docaddr, _Dp[0-3] = src, _Dp[4-5] = len.
;;; Interrupts wait only for one page (256 bytes) at a time.
;;;
;;; ***************************************************************************

              .public IIGS_DocUpload
IIGS_DocUpload:
              sta     .near upDoc
              ldy     ##0
1$:           php                           ; a page: the GLU address again,
              sei                           ;   the interrupt moves it
              sep     #0x20
2$:           lda     long:SOUNDCTL
              bmi     2$
              lda     dp:DOCVOL
              ora     #0x60                 ; RAM, auto increment
              sta     long:SOUNDCTL
              rep     #0x20
              tya
              clc
              adc     .near upDoc
              sep     #0x20
              sta     long:SOUNDADRL
              xba
              sta     long:SOUNDADRH
              rep     #0x20
              sty     .near upCount         ; the bytes left, 256 at most
              lda     dp:.tiny (_Dp+4)
              sec
              sbc     .near upCount
              beq     7$
              cmp     ##256
              bcc     3$
              lda     ##256
3$:           sta     .near upCount
              and     ##7                   ; count & 7 bytes one at a time
              tax
              sep     #0x20
              beq     5$
4$:           lda     [.tiny _Dp],y
              sta     long:SOUNDDATA
              iny
              dex
              bne     4$
5$:           rep     #0x20                 ; then 8 bytes at a time
              lda     .near upCount
              lsr     a
              lsr     a
              lsr     a
              tax
              sep     #0x20
              beq     61$
6$:           UPBYTE
              UPBYTE
              UPBYTE
              UPBYTE
              UPBYTE
              UPBYTE
              UPBYTE
              UPBYTE
              dex
              bne     6$
61$:          cpy     dp:.tiny (_Dp+4)      ; all bytes: the 0 byte
              bcs     7$
              plp
              brl     1$
7$:           sep     #0x20
              lda     #0
              sta     long:SOUNDDATA
              plp
              rtl

;;; Only tryRunTics' no-new-tic poll calls this watchdog. Normal clock reads
;;; and rendering keep their old instructions and addresses. 65536 polls
;;; without one clock step cannot be a normal 1/35-second wait, even at the
;;; fastest supported clock (each poll also reads the slow DOC twice).
;;; The words start at zero in the loaded image; a changed clock reloads
;;; the full budget. Compare the low word: each read advances at most 255.
              .section timerwait, text
              .public I_TimeWait, IIGS_RepairDocTimer
I_TimeWait:   jsl     long:I_GetTime
              cmp     long:waitLast
              beq     1$
              sta     long:waitLast
              pha
              lda     ##0
              sta     long:waitBudget
              pla
              rtl
1$:           pha
              lda     long:waitBudget
              dec     a
              sta     long:waitBudget
              bne     2$
              phx
              jsl     long:IIGS_RepairDocTimer
              plx
2$:           pla
              rtl
waitLast:     .word   0
waitBudget:   .word   0

;;; A halted timer or a flat, nonzero ramp stalls game tics while music
;;; can continue. Repair only oscillator 31 and the reserved ramp. Unlike
;;; startup, do not halt voices or alarm 30, and do not reset elapsed tics.
;;; The ramp contains no zero even during its rewrite, so alarm 30 can
;;; keep scanning it. Main-thread entry, native A/X16, D/DB/Y unchanged.
IIGS_RepairDocTimer:
              php
              sei
              sep     #0x20
              ldx     ##(0xa0 + TIMER_OSC)
              lda     #1
              jsr     .kbank waitSet
1$:           lda     long:SOUNDCTL
              bmi     1$
              lda     dp:DOCVOL
              ora     #0x60
              sta     long:SOUNDCTL
              lda     #0
              sta     long:SOUNDADRL
              lda     #TIMER_PAGE
              sta     long:SOUNDADRH
              lda     #255
              sta     long:SOUNDDATA
              lda     #1
2$:           sta     long:SOUNDDATA
              inc     a
              bne     2$
              ldx     ##0xe1
              lda     #(DOC_OSCS - 1) * 2
              jsr     .kbank waitSet
              ldx     ##TIMER_OSC
              lda     #TIMER_FREQ
              jsr     .kbank waitSet
              ldx     ##(0x20 + TIMER_OSC)
              lda     #0
              jsr     .kbank waitSet
              ldx     ##(0x40 + TIMER_OSC)
              lda     #0
              jsr     .kbank waitSet
              ldx     ##(0x80 + TIMER_OSC)
              lda     #TIMER_PAGE
              jsr     .kbank waitSet
              ldx     ##(0xc0 + TIMER_OSC)
              lda     #7
              jsr     .kbank waitSet
              ldx     ##(0xa0 + TIMER_OSC)
              lda     #0
              jsr     .kbank waitSet
              lda     #(0x60 + TIMER_OSC)
              sta     long:SOUNDADRL
              lda     long:SOUNDDATA
              lda     long:SOUNDDATA
              rep     #0x20
              and     ##0xff
              sta     long:tmLast
              plp
              rtl

waitSet:      pha
1$:           lda     long:SOUNDCTL
              bmi     1$
              lda     dp:DOCVOL
              sta     long:SOUNDCTL
              lda     #0
              sta     long:SOUNDADRH
              txa
              sta     long:SOUNDADRL
              pla
              sta     long:SOUNDDATA
              rts
