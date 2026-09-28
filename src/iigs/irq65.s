;;; The interrupt of the game, Doom8088: Apple IIgs Edition.
;;;
;;; Sources: a byte from the ADB microcontroller (the ADB data interrupt), a
;;; mouse report (the ADB mouse interrupt), and the DOC alarm (oscillator 30
;;; of src/iigs/i_doc65.s), which runs only while music plays: each alarm is
;;; a music wake. With bit 6 of the shadow register set, the I/O and the ROM
;;; of banks $00 and $01 at $C000-$FFFF are off (the game uses the I/O of
;;; bank $E0 only), so the 65816 takes its vectors from RAM and no firmware
;;; code runs.
;;; The handler runs in bank 0 at $DD00 (src/iigs/iigs.scm): cache slots
;;; $5D00-$5EFF. mkdisk.py loads its
;;; immutable image below $C000; copyMusicIrq installs it after IOLC.
;;; The vector needs bank 0, so no jump from hot slots. The ADB path: one push (8-bit
;;; A), long addresses (D and DBR are those of the interrupted code).
;;; The main code masks interrupts only in the DOC sequences.

              .rtmodel version, "1"
              .rtmodel core, "*"

              .extern IIGS_PollKeys, musPause, musResume, copyMusicIrq

#include "music.inc"

KMSTATUS      .equ    0xe0c027        ; ADB: the interrupt enables
KM_DATAINT    .equ    0x10            ;   a byte from the microcontroller
KM_MOUSEINT   .equ    0x40            ;   a mouse report
KM_WAITING    .equ    0xa0            ;   bit 7 a mouse report, bit 5 a byte
VGCINT        .equ    0xe0c023        ; scan line, 1 second
SCANINT       .equ    0xe0c032
SCCACMD       .equ    0xe0c039        ; the command register of SCC port A
SHADOW        .equ    0xe0c035
INTEN         .equ    0xe0c041        ; VBL, 1/4 second, Mega II mouse
CLRVBLINT     .equ    0xe0c047
SOUNDCTL      .equ    0xe0c03c        ; the sound GLU: bit 7 busy, bit 6 DOC
GLU_RAM       .equ    0x40            ;   RAM (else the registers)
SOUNDDATA     .equ    0xe0c03d
SOUNDADRL     .equ    0xe0c03e
DOC_IRQ       .equ    0xe0            ; the DOC interrupt register
ALARM_FREQLO  .equ    0x00 + 30       ; the registers of the alarm
ALARM_FREQHI  .equ    0x20 + 30
ALARM_CONTROL .equ    0xa0 + 30
ALARM_CTL     .equ    0x0a            ; one-shot, interrupt on, running
REG_FREQLO    .equ    0x10            ; the registers of oscillator 16 + v
REG_FREQHI    .equ    0x30
REG_VOLUME    .equ    0x50
REG_POINTER   .equ    0x90
REG_CONTROL   .equ    0xb0
REG_SIZE      .equ    0xd0
IOLC          .equ    0x40            ; SHADOW: I/O and ROM of banks 0, 1 off
VECTORS       .equ    0x00ffe0        ; the 65816 vectors, 32 bytes
V_COP         .equ    0x04            ; native mode, from VECTORS
V_BRK         .equ    0x06
V_ABORT       .equ    0x08
V_NMI         .equ    0x0a
V_IRQ         .equ    0x0e

              .section zfar, bss
romVectors:   .space  32              ; the vectors of the ROM
irqOn:        .space  2               ; not 0: the interrupt runs

;;; ---------------------------------------------------------------------------
;;; The handler. RTI restores P, so the mode switches need no way back.
;;; ADB first: a Talk answer must be read before a mouse report replaces it,
;;; and that path leaves the alarm alone. Else the alarm: the read of DOC
;;; register $E0 starts the DOC read, which is the acknowledge (only
;;; oscillator 30 has its interrupt on, so the value is not needed).
;;; ---------------------------------------------------------------------------
              .section irqcode, text
irqEntry:     sep     #0x20
              pha
              lda     long:KMSTATUS
              and     #KM_WAITING
              bne     adbByte
1$:           lda     long:SOUNDCTL         ; busy: a DOC access of the main
              bmi     1$                    ;   code may still run
              bit     #GLU_RAM              ; RAM mode only after an upload
              bne     ramMode
ackAlarm:     lda     #DOC_IRQ
              sta     long:SOUNDADRL
              lda     long:SOUNDDATA        ; the acknowledge
              lda     long:musOn            ; the music stopped: no new alarm
              bne     wake
              pla
              rti
adbByte:      pla
              jsl     long:IIGS_PollKeys
noEntry:      rti                           ; (also BRK, COP, ABORT and NMI)
ramMode:      and     #0x0f                 ; register mode (the volume bits
              sta     long:SOUNDCTL         ;   as the main code keeps them)
              bra     ackAlarm

;;; ---------------------------------------------------------------------------
;;; A music wake (the stream of tools/musbank.py): its wait sets the alarm
;;; first, so the tics of the song do not depend on the work of a wake;
;;; then its commands, up to the next wait (the next wake) or the end.
;;; DBR = the music bank, Y = the stream position, X for the voice or a
;;; table; B = 0, so TAX and TAY give 16-bit indexes. A command starts
;;; with A = its voice.
;;; ---------------------------------------------------------------------------
wake:         xba
              pha                           ; B
              phb
              lda     #(MUSBUF >> 16)
              pha
              plb
              rep     #0x10
              phx
              phy
              lda     #0
              xba
              ldy     abs:MB_SPTR
              ;; 0xF0+n: n tics (the low byte of the alarm frequency);
              ;; 0xE0+n: the high byte too (only n = 1, 2 need one); 0xD0+n:
              ;; the frequency of the wait before. The one-shot alarm starts
              ;; again here: a free-running one keeps its phase, and a new
              ;; frequency then also times the part of the pass before this
              ;; write (MAME runs the DOC in chunks: a late wake, a fast song)
              lda     abs:MB_STREAM,y
              iny
              cmp     #0xe0
              bcc     1$                    ; the same frequency
              cmp     #0xf0                 ; (carry: the low byte only)
              and     #0x0f
              tax
              lda     #ALARM_FREQLO
              sta     long:SOUNDADRL
              lda     abs:MB_WLO,x
              sta     long:SOUNDDATA
              bcs     1$
              lda     #ALARM_FREQHI
              sta     long:SOUNDADRL
              lda     abs:MB_WHI,x
              sta     long:SOUNDDATA
              sta     abs:MB_FCHI           ; (musResume restarts with it)
1$:           lda     #ALARM_CONTROL        ; a halted one-shot counts again
              sta     long:SOUNDADRL        ;   from 0 when it runs
              lda     #ALARM_CTL
              sta     long:SOUNDDATA
next:         lda     abs:MB_STREAM,y
              cmp     #0xd0
              bcs     done
              iny
              lsr     a                     ; kind x 8; sparse dispatch saves
              and     #0x78                 ;   two shifts on every event
              tax
              lda     abs:(MB_STREAM-1),y   ; the voice
              and     #0x0f
              jmp     (.kbank cmds,x)
done:         cmp     #0xe0                 ; 0xE0: the song ends
              bne     wakeEnd
              jmp     abs:songEnd
wakeEnd:      sty     abs:MB_SPTR
              ply
              plx
              plb
              pla
              xba                           ; B
              pla
              rti

              .space  2                     ; keep all hot handlers placed
songEnd:      ldy     ##0
              lda     long:musLoop
              bne     1$
              lda     #0
              sta     long:musOn
1$:           jmp     abs:wakeEnd
              .space  8                     ; old compact table footprint

;;; 0x0v: level + 4 (3 dB down); 0x8v: + 8; 0x9v: - 4. 0x1v a: level a.
cLevDn:       tax
              ora     #REG_VOLUME
              sta     long:SOUNDADRL
              lda     abs:MB_LEVEL,x
              clc
              adc     #4
              bra     setLev
cLevDn2:      tax
              ora     #REG_VOLUME
              sta     long:SOUNDADRL
              lda     abs:MB_LEVEL,x
              clc
              adc     #8
              bra     setLev
cLevUp:       tax
              ora     #REG_VOLUME
              sta     long:SOUNDADRL
              lda     abs:MB_LEVEL,x
              sec
              sbc     #4
              bra     setLev
cLev:         tax
              ora     #REG_VOLUME
              sta     long:SOUNDADRL
              lda     abs:MB_STREAM,y
              iny
setLev:       sta     abs:MB_LEVEL,x
              tax
              lda     abs:MB_VSCALE,x
              sta     long:SOUNDDATA
              brl     next

;;; 0x6v: halt (silence; the next note restarts the table).
cHalt:        tax
              ora     #REG_CONTROL
              sta     long:SOUNDADRL
              lda     abs:MB_CTLH,x
              sta     long:SOUNDDATA
              brl     next

;;; A note: halt (the run below starts the table at its start), [table],
;;; [pitch], level, run; each register only when it changes (a register
;;; write is the cost of the music). 0x3v d p a: the table of descriptor d
;;; from now on; 0x7v p a: the voice's table again (a switch to its loop
;;; changed the pointer and size); 0xCv a: the same with the voice's pitch;
;;; 0x2v p a: the table as it is; 0xAv a: the pitch too. Bit 7 of a: a halt
;;; command stopped the voice (no halt); a level as the voice has: no write.
cNoteC:       sec
              bra     noteT
cNoteP:       tax
              lda     abs:MB_STREAM,y
              iny
              sta     abs:MB_VDESC,x
              txa
cNoteT:       clc                           ; (carry: no pitch follows; the
noteT:        sta     abs:MB_V              ;   table code keeps it)
              tax
              lda     abs:(MB_STREAM+1),y   ; (its level byte)
              bmi     noteTab
              txa
              ora     #REG_CONTROL
              sta     long:SOUNDADRL
              lda     abs:MB_CTLH,x
              sta     long:SOUNDDATA
noteTab:      txa
              ora     #REG_POINTER
              sta     long:SOUNDADRL
              lda     abs:MB_VDESC,x
              tax                           ; X = the descriptor
              lda     abs:MB_DPTR,x
              sta     long:SOUNDDATA
              lda     abs:MB_V
              ora     #REG_SIZE
              sta     long:SOUNDADRL
              lda     abs:MB_DSIZ,x
              sta     long:SOUNDDATA
              lda     abs:MB_DMODE,x
              ldx     abs:MB_V
              ora     abs:MB_CTLR,x
              sta     abs:MB_VCTL,x
              txa
              bcc     notePitch
              bra     noteLevel
cNote:        sta     abs:MB_V
              tax
              lda     abs:(MB_STREAM+1),y
              bmi     1$
              txa
              ora     #REG_CONTROL
              sta     long:SOUNDADRL
              lda     abs:MB_CTLH,x
              sta     long:SOUNDDATA
1$:           txa
notePitch:    ora     #REG_FREQLO
              sta     long:SOUNDADRL
              lda     abs:MB_STREAM,y
              iny
              tax
              lda     abs:MB_PLO,x
              sta     long:SOUNDDATA
              lda     abs:MB_V
              ora     #REG_FREQHI
              sta     long:SOUNDADRL
              lda     abs:MB_PHI,x
              sta     long:SOUNDDATA
noteLevel:    ldx     abs:MB_V              ; (MB_V + 1 is 0)
              lda     abs:MB_STREAM,y
              iny
              and     #0x7f
              cmp     abs:MB_LEVEL,x
              beq     1$
              sta     abs:MB_LEVEL,x
              txa
              ora     #REG_VOLUME
              sta     long:SOUNDADRL
              lda     abs:MB_LEVEL,x
              tax
              lda     abs:MB_VSCALE,x
              sta     long:SOUNDDATA
              ldx     abs:MB_V
1$:           txa
              ora     #REG_CONTROL
              sta     long:SOUNDADRL
              lda     abs:MB_VCTL,x
              sta     long:SOUNDDATA
              brl     next
cNoteS:       sta     abs:MB_V
              tax
              lda     abs:MB_STREAM,y
              bmi     noteLevel
              txa
              ora     #REG_CONTROL
              sta     long:SOUNDADRL
              lda     abs:MB_CTLH,x
              sta     long:SOUNDDATA
              bra     noteLevel
;;; ---------------------------------------------------------------------------
;;; The rare commands, in the cache slots $5C00-$5CFF (src/iigs/iigs.scm):
;;; the pitch changes, the loop of an attack table, the end of a song.
;;; ---------------------------------------------------------------------------
              .section irqcold, text
;;; 0x4v p: pitch p. 0x5v p: its low byte only (the high byte is the same).
cPitch:       sta     abs:MB_V
              ora     #REG_FREQLO
              sta     long:SOUNDADRL
              lda     abs:MB_STREAM,y
              iny
              tax
              lda     abs:MB_PLO,x
              sta     long:SOUNDDATA
              lda     abs:MB_V
              ora     #REG_FREQHI
              sta     long:SOUNDADRL
              lda     abs:MB_PHI,x
              sta     long:SOUNDDATA
              jmp     abs:next
cPitchLo:     ora     #REG_FREQLO
              sta     long:SOUNDADRL
              lda     abs:MB_STREAM,y
              iny
              tax
              lda     abs:MB_PLO,x
              sta     long:SOUNDDATA
              jmp     abs:next

;;; 0xBv: the loop of the voice's attack table (its pointer and size).
cSwitch:      cmp     #0x0e
              beq     cWavePage
              cmp     #0x0f
              beq     cRawControl
              tax
              ora     #REG_POINTER
              sta     long:SOUNDADRL
              lda     abs:MB_VDESC,x
              tax
              lda     abs:MB_LPTR,x
              sta     long:SOUNDDATA
              lda     abs:(MB_STREAM-1),y   ; the voice
              and     #0x0f
              ora     #REG_SIZE
              sta     long:SOUNDADRL
              lda     abs:MB_LSIZ,x
              sta     long:SOUNDDATA
              jmp     abs:next

;;; 0xBE v page: a phase-compatible waveform page, same size and pitch.
;;; Only the pointer changes; the voice keeps its accumulator and descriptor
;;; so a later note can restore the attack using the existing note command.
cWavePage:    lda     abs:MB_STREAM,y
              iny
              ora     #REG_POINTER
              sta     long:SOUNDADRL
              lda     abs:MB_STREAM,y
              iny
              sta     long:SOUNDDATA
              jmp     abs:next

;;; 0xBF v control: a muted voice's output channel. The next ordinary
;;; note still uses its normal channel; no permanent voice-table change.
cRawControl:  lda     abs:MB_STREAM,y
              iny
              ora     #REG_CONTROL
              sta     long:SOUNDADRL
              lda     abs:MB_STREAM,y
              iny
              sta     long:SOUNDDATA
              jmp     abs:next

;;; The end of a song: the next wake is its first again, or (a song that
;;; does not loop) no alarm after this one.
cmds:         ;; 13 live words, stride 8. Only the words touch cache.
              .word   .word0 cLevDn
              .space  6
              .word   .word0 cLev
              .space  6
              .word   .word0 cNote
              .space  6
              .word   .word0 cNoteP
              .space  6
              .word   .word0 cPitch
              .space  6
              .word   .word0 cPitchLo
              .space  6
              .word   .word0 cHalt
              .space  6
              .word   .word0 cNoteT
              .space  6
              .word   .word0 cLevDn2
              .space  6
              .word   .word0 cLevUp
              .space  6
              .word   .word0 cNoteS
              .space  6
              .word   .word0 cSwitch
              .space  6
              .word   .word0 cNoteC

;;; The state of the music that must be right at boot (src/iigs/music.inc).
              .section irqcode, text
              .section irqstate, text
              .public musOn, musPend, musLoop, musCur, musWant
musOn:        .byte   0               ; not 0: a song plays (the alarm runs)
musPend:      .byte   0               ; not 0: a song loads (musStep, a frame at a time)
musLoop:      .byte   0               ; not 0: it loops (else it stops at its end)
musCur:       .byte   MUS_NONE        ; the song in MB_IMAGE
musWant:      .byte   MUS_NONE        ; the song to play (the music volume can be 0)

;;; ---------------------------------------------------------------------------
;;; void IIGS_StartInterrupts(void): the other interrupt sources off, the
;;; vectors in RAM, the ADB data and mouse interrupts on, interrupts on.
;;; void IIGS_StopInterrupts(void): interrupts off, the alarm and the ADB
;;; interrupts off, the ROM and its vectors back (for Control-Reset after
;;; an exit).
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public IIGS_StartInterrupts, IIGS_StopInterrupts
IIGS_StartInterrupts:
              sei
              sep     #0x20
              lda     long:SCCACMD          ; SCC register pointer to 0
              lda     #9                    ; WR9: master interrupt enable off
              sta     long:SCCACMD
              lda     #0
              sta     long:SCCACMD
              sta     long:INTEN
              sta     long:VGCINT
              sta     long:SCANINT
              sta     long:CLRVBLINT
              lda     #KM_DATAINT | KM_MOUSEINT
              sta     long:KMSTATUS
              rep     #0x30
              ldx     ##30                  ; the ROM vectors, then RAM there
1$:           lda     long:VECTORS,x
              sta     long:romVectors,x
              dex
              dex
              bpl     1$
              sep     #0x20
              lda     long:SHADOW
              ora     #IOLC
              sta     long:SHADOW
              ;; ROM is now unmapped: install the execution image before
              ;; writing vectors. The five mutable music bytes stay put.
              jsl     long:copyMusicIrq
              nop
2$:           lda     long:romVectors,x
              sta     long:VECTORS,x
              dex
              dex
              bpl     2$
              lda     ##.word0 irqEntry
              sta     long:(VECTORS+V_IRQ)
              lda     ##.word0 noEntry
              sta     long:(VECTORS+V_BRK)
              sta     long:(VECTORS+V_COP)
              sta     long:(VECTORS+V_ABORT)
              sta     long:(VECTORS+V_NMI)
              sta     long:irqOn            ; (not 0)
              ;; Drain a byte that arrived while DATA/mouse IRQs were masked.
              ;; Do not depend on enabling IRQs to signal an already-full
              ;; latch: the legacy MAME KEYGLU path can leave it pending,
              ;; blocking further ADB replies until an explicit poll.
              jsl     long:IIGS_PollKeys
              jsl     long:musResume        ; the music after a disk access
              cli
              rtl
              .space  1                     ; the size of the old code

IIGS_StopInterrupts:
              sei
              php
              rep     #0x30
              lda     long:irqOn
              beq     9$
              lda     ##0
              sta     long:irqOn
              sep     #0x20
              sta     long:KMSTATUS
              rep     #0x20
              jsl     long:musPause         ; the alarm off, no note drones
              rep     #0x30
              ldx     ##30                  ; the ROM vectors in RAM too
1$:           lda     long:romVectors,x
              sta     long:VECTORS,x
              dex
              dex
              bpl     1$
              sep     #0x20
              lda     long:SHADOW
              and     #0xff - IOLC
              sta     long:SHADOW
9$:           plp
              rtl
