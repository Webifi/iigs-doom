;;; Sound effects in 65816 assembly.
;;;
;;; The sound code of Doom (s_sound.c) for the Ensoniq DOC. The 8
;;; channels play the sounds of their origins with the volume and stereo
;;; separation of the distance and angle to the player (on map 8 without a
;;; distance limit). A channel is two DOC oscillators, left and right, that
;;; play the sound once from DOC RAM: the even one has the left volume and
;;; DOC channel 1, the odd one the right volume and DOC channel 0 (a stereo
;;; card: odd left, even right). At the start of a map, DOC RAM gets
;;; the plan of the map from the sound bank (tools/sndbank.py): the sounds
;;; with the most starts at fixed places below the pool, and the next ones
;;; in the pool. A variant that is not in DOC RAM plays its stand-in at
;;; another pitch. The pool holds the recently used sounds: a new one goes
;;; where the newest sound to remove is the oldest, and sounds that play
;;; stay. nosfxparm is always false. The music is at the end of this file.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"
#include "music.inc"

              .extern _Dp, _g_player, _g_gamemap
              .extern R_PointToAngle3, finesineapprox, IIGS_MulLo16
              .extern _Mul32, _Div16, _Div32, _UDivMod32, MA, MB, MR, umul16
              .extern IIGS_DocWrite2, IIGS_DocRead, IIGS_DocUpload, IIGS_DecodeSound
              .extern IIGS_CopyHuge, IIGS_AlarmOff
              .extern I_Error, printf

PL            .equ    _g_player
NUM_CHANNELS  .equ    8
DOC_PAGES     .equ    255             ; page 255 has the timer ramp (i_doc65.s)
DOC_FREQ_11025 .equ   27452           ; 11025 * 65536 / 26320 (32 oscillators)
DOC_FREQLO    .equ    0x00
DOC_FREQHI    .equ    0x20
DOC_VOLUME    .equ    0x40
DOC_POINTER   .equ    0x80
DOC_CONTROL   .equ    0xa0
DOC_SIZE      .equ    0xc0
CTL_HALT      .equ    0x01
CTL_ONESHOT   .equ    0x02
CTL_LEFT      .equ    0x10            ; DOC channel 1, odd: the left of a stereo card
                                      ;   (the right oscillator is channel 0, even:
                                      ;   Apple's rule, TN.IIGS.019)
CTL_STOPPED   .equ    ((CTL_ONESHOT | CTL_HALT | CTL_LEFT) | ((CTL_ONESHOT | CTL_HALT) << 8))
CTL_PLAY      .equ    ((CTL_ONESHOT | CTL_LEFT) | (CTL_ONESHOT << 8))
NORM_SEP      .equ    127             ; the middle of the 254 of the pan law: equal sides
S_STEREO_SWING .equ   96
S_CLIPPING_HI .equ    1200            ; S_CLIPPING_DIST = 1200 << FRACBITS
S_CLOSE_HI    .equ    160             ; S_CLOSE_DIST
S_ATTENUATOR  .equ    (S_CLIPPING_HI - S_CLOSE_HI)
PICKUP_SOUND  .equ    0x8000          ; s_sound.h
SNDBANK_ADDR  .equ    MM_SNDBANK      ; see src/iigs/iigs.scm
SNDDIR_OFS    .equ    0x0c00
PLAN_OFS      .equ    (SNDDIR_OFS + 2 + 8 * CONST_NUMSFX) ; stand-ins, pitches, plans
PLAN_ROWS     .equ    (PLAN_OFS + 2 * CONST_NUMSFX)       ; the plan of map 0 (none)
PLAN_ROW      .equ    (2 + CONST_NUMSFX)  ; a plan: first pool page, end of the
                                          ;   pages, first page of each sfx
PLAN_MAPS     .equ    9
NO_PAGE       .equ    255             ; a sound that is not in the plan
SNDPCM_ADDR   .equ    MM_SNDPCM
SNDPCM_END    .equ    MM_SNDPCM_END   ; VIEWSAVE of src/iigs/i_viigs65.s above

              .section zfar, bss
;;; the sounds (sound_t of i_aiigs.c): 2 bytes each, the samples 4
SND_PCM:      .space  (4 * CONST_NUMSFX) ; the samples in main RAM, 0: none
SND_LEN:      .space  (2 * CONST_NUMSFX)
SND_FREQ:     .space  (2 * CONST_NUMSFX) ; the frequency register for 256 bytes
SND_PAGES:    .space  (2 * CONST_NUMSFX) ; DOC RAM pages with the 0 at the end
SND_SIZE:     .space  (2 * CONST_NUMSFX) ; table size code: 256 << size >= pages
SND_PAGE:     .space  (2 * CONST_NUMSFX) ; the first page in DOC RAM, -1: none
SND_LASTUSE:  .space  (2 * CONST_NUMSFX)
SND_BUSY:     .space  (2 * CONST_NUMSFX)
SND_ALIAS:    .space  (2 * CONST_NUMSFX) ; 2 * the stand-in, 0: none
SND_AFREQ:    .space  (2 * CONST_NUMSFX) ; the frequency through the stand-in
PAGEOWNER:    .space  DOC_PAGES       ; bytes: the sound in the page, 0: none
PLANS:        .space  (PLAN_ROW * (PLAN_MAPS + 1)) ; the plans of the bank (the
                                      ;   column directory takes its RAM)

              .section znear, bss
CH_SFX:       .space  (2 * NUM_CHANNELS) ; the sound of the channel, 0: free
CH_ORIGIN:    .space  (4 * NUM_CHANNELS)
CH_PICKUP:    .space  (2 * NUM_CHANNELS)
CHANSFX:      .space  (2 * NUM_CHANNELS) ; the sound of the DOC channel, 0: none
USECOUNT:     .space  2
POOL_LO:      .space  2               ; the pool: pages POOL_LO..POOL_HI-1
POOL_HI:      .space  2
PLAN_MAP:     .space  2               ; the map of the plan in DOC RAM, -1: none
FM:           .space  20              ; fake_mobj of S_StartSound2: x, y at
                                      ; OFS_MO_X, OFS_MO_Y
SS_ORIGIN:    .space  4               ; the sound to start
SS_SFX:       .space  2
SS_PICKUP:    .space  2
SS_VOL:       .space  2               ; S_AdjustSoundParams: *vol, *sep
SS_SEP:       .space  2
SS_DIST:      .space  4
SS_T:         .space  4
SS_ANG:       .space  4
SS_C:         .space  2               ; a channel (2 * number)
SS_K:         .space  2               ; a channel of I_CacheSound
SS_ID:        .space  2               ; the sound (2 * id)
SS_FREQ:      .space  2               ; its frequency for a 256-byte table
SS_ROW:       .space  2               ; the plan of the map (bank offset)
SS_SZ:        .space  2
SS_BEST:      .space  2
SS_AGE:       .space  2
SS_START:     .space  2
SS_NEWEST:    .space  2
SS_STEP:      .space  2
SS_END:       .space  2
SS_DIR:       .space  4               ; I_InitSound
SS_DST:       .space  4
SS_I:         .space  2

              .section cfar, rodata
msgInit:      .asciz  "S_Init: default sfx volume %d\n"
errVolume:    .asciz  "S_SetSfxVolume: Attempt to set sfx volume at %d"
errBadSfx:    .asciz  "S_StartSoundAtVolume: Bad sfx #: %d"
msgDecode:    .asciz  "I_InitSound: decoding sounds\n"
errCount:     .asciz  "I_InitSound: %u sounds in the sound bank, not %u"
errFit:       .asciz  "I_InitSound: the sounds do not fit in RAM"
errData:      .asciz  "I_InitSound: bad data in sound %d"

;;; ---------------------------------------------------------------------------
;;; void S_Init(int16_t sfxVolume, int16_t musicVolume)   In: C = sfxVolume.
;;; void S_SetSfxVolume(int16_t volume)                    In: C.
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public S_Init, S_SetSfxVolume
S_Init:       pha                           ; printf(msgInit, sfxVolume)
              pha
              lda     ##.word0 msgInit
              sta     dp:.tiny _Dp
              lda     ##.word2 msgInit
              sta     dp:.tiny (_Dp+2)
              jsl     long:printf
              pla
              pla
              jsl     long:S_SetSfxVolume
              ldx     ##(2 * NUM_CHANNELS - 2) ; all channels free
1$:           stz     abs:.near CH_SFX,x
              dex
              dex
              bpl     1$
              rtl
S_SetSfxVolume:
              cmp     ##128                 ; 0..127
              bcc     1$
              pha
              lda     ##.word0 errVolume
              sta     dp:.tiny _Dp
              lda     ##.word2 errVolume
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
1$:           sta     .near snd_SfxVolume
              rtl

              .space  1                     ; (this section keeps its size)

;;; ---------------------------------------------------------------------------
;;; void S_Start(void): at the start of a level all the sounds stop, DOC RAM
;;; gets the plan of the map, and the song of the map starts.
;;; void I_ShutdownSound(void): all the DOC channels and the music stop.
;;; ---------------------------------------------------------------------------
              .public S_Start, I_ShutdownSound
S_Start:      ldx     ##0
1$:           jsr     .kbank stopChannel
              inx
              inx
              cpx     ##(2 * NUM_CHANNELS)
              bcc     1$
              jsl     long:musNewMap
              lda     .near _g_gamemap
              jsr     .kbank loadPlan
              jmp     long:musLevel
I_ShutdownSound:
              jmp     long:musShutdown
              .space  9

;;; ---------------------------------------------------------------------------
;;; void S_StartSound(mobj_t __far* origin, sfxenum_t sfx_id)
;;; void S_StartSound2(degenmobj_t __far* origin, sfxenum_t sfx_id)
;;;   In: _Dp[0-3] = origin, C = sfx_id.
;;; S_StartSound2 plays at the point of origin with the one fake mobj FM
;;; (so all the sounds of S_StartSound2 have the same origin).
;;; ---------------------------------------------------------------------------
              .public S_StartSound, S_StartSound2
S_StartSound2:
              pha
              ldy     ##0                   ; fm.origin = *origin (x, y)
1$:           lda     [.tiny _Dp],y
              sta     abs:.near (FM+OFS_MO_X),y
              iny
              iny
              cpy     ##8
              bcc     1$
              lda     ##.near FM
              sta     dp:.tiny _Dp
              lda     ##.word2 FM
              sta     dp:.tiny (_Dp+2)
              pla
S_StartSound: sta     .near SS_SFX
              lda     dp:.tiny _Dp
              sta     .near SS_ORIGIN
              lda     dp:.tiny (_Dp+2)
              sta     .near (SS_ORIGIN+2)
              stz     .near SS_PICKUP       ; is_pickup: PICKUP_SOUND, oof, noway
              lda     .near SS_SFX
              bit     ##PICKUP_SOUND
              bne     1$
              cmp     ##CONST_SFX_OOF
              beq     1$
              cmp     ##CONST_SFX_NOWAY
              bne     2$
1$:           inc     .near SS_PICKUP
2$:           and     ##(0xffff - PICKUP_SOUND)
              sta     .near SS_SFX
              beq     3$                    ; sfx_None < id < NUMSFX
              cmp     ##CONST_NUMSFX
              bcc     4$
3$:           pha
              lda     ##.word0 errBadSfx
              sta     dp:.tiny _Dp
              lda     ##.word2 errBadSfx
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
4$:           lda     ##NORM_SEP            ; sep = NORM_SEP
              sta     .near SS_SEP
              lda     .near SS_ORIGIN       ; no origin or the player: volume * 8
              ora     .near (SS_ORIGIN+2)
              beq     5$
              lda     .near SS_ORIGIN
              cmp     .near (PL+OFS_PL_MO)
              bne     6$
              lda     .near (SS_ORIGIN+2)
              cmp     .near (PL+OFS_PL_MO+2)
              bne     6$
5$:           lda     .near snd_SfxVolume
              asl     a
              asl     a
              asl     a
              sta     .near SS_VOL
              bra     7$
6$:           lda     .near SS_ORIGIN       ; else the params, or not audible
              sta     dp:.tiny (_Dp+4)
              lda     .near (SS_ORIGIN+2)
              sta     dp:.tiny (_Dp+6)
              jsr     .kbank adjustParams
              bcs     7$
              rtl
7$:           ldx     ##0                   ; kill the old sound of the origin
8$:           lda     abs:.near CH_SFX,x    ; (the same kind of sound)
              beq     9$
              jsr     .kbank sameOrigin
              bne     9$
              lda     abs:.near CH_PICKUP,x
              cmp     .near SS_PICKUP
              bne     9$
              jsr     .kbank stopChannel
              bra     10$
9$:           inx
              inx
              cpx     ##(2 * NUM_CHANNELS)
              bcc     8$
10$:          jsr     .kbank getChannel     ; a channel, or none
              bcs     11$
              rtl
11$:          stx     .near SS_C            ; I_StartSound(id, channel, vol, sep)
              jsr     .kbank startSound
              bcs     12$
              ldx     .near SS_C            ; -1: the channel stops
              jsr     .kbank stopChannel
12$:          rtl

;;; sameOrigin: Z set if the origin of the channel at X is SS_ORIGIN.
;;; X stays.
sameOrigin:   txa
              asl     a
              tay
              lda     abs:.near CH_ORIGIN,y
              cmp     .near SS_ORIGIN
              bne     1$
              lda     abs:.near (CH_ORIGIN+2),y
              cmp     .near (SS_ORIGIN+2)
1$:           rts

;;; getChannel: S_getChannel(SS_ORIGIN, SS_SFX, SS_PICKUP): the first free
;;; channel, or before it a channel of the same origin and kind (stopped);
;;; none: the first channel with a priority not lower, stopped. Carry set
;;; and X = 2 * channel, with the sound, origin and kind set; carry clear:
;;; none.
getChannel:   ldx     ##0
1$:           lda     abs:.near CH_SFX,x
              beq     4$                    ; free
              lda     .near SS_ORIGIN       ; the same origin and kind: stopped
              ora     .near (SS_ORIGIN+2)
              beq     2$
              jsr     .kbank sameOrigin
              bne     2$
              lda     abs:.near CH_PICKUP,x
              cmp     .near SS_PICKUP
              bne     2$
              jsr     .kbank stopChannel
              bra     4$
2$:           inx
              inx
              cpx     ##(2 * NUM_CHANNELS)
              bcc     1$
              lda     .near SS_SFX          ; none free: priority[c] >= priority
              jsr     .kbank priority
              sta     .near SS_T
              ldx     ##0
3$:           lda     abs:.near CH_SFX,x
              jsr     .kbank priority
              sec                           ; (int8 values: no overflow)
              sbc     .near SS_T
              bpl     31$
              inx
              inx
              cpx     ##(2 * NUM_CHANNELS)
              bcc     3$
              clc                           ; no lower priority
              rts
31$:          jsr     .kbank stopChannel
4$:           lda     .near SS_SFX          ; the channel is decided
              sta     abs:.near CH_SFX,x
              lda     .near SS_PICKUP
              sta     abs:.near CH_PICKUP,x
              txa
              asl     a
              tay
              lda     .near SS_ORIGIN
              sta     abs:.near CH_ORIGIN,y
              lda     .near (SS_ORIGIN+2)
              sta     abs:.near (CH_ORIGIN+2),y
              sec
              rts

;;; priority: C = the priority of the sound C. X stays.
priority:     tay
              lda     .near sfxPriority,y
              and     ##0x00ff
              rts

;;; stopChannel: S_StopChannel(X / 2): a channel with a sound stops it (if
;;; it plays) and is free. X stays.
stopChannel:  lda     abs:.near CH_SFX,x
              beq     1$
              stx     .near SS_C
              jsr     .kbank isPlaying
              ldx     .near SS_C
              bcc     2$
              jsr     .kbank docStop
              ldx     .near SS_C
2$:           stz     abs:.near CH_SFX,x
1$:           rts

;;; ---------------------------------------------------------------------------
;;; void S_StopSound(void __far* origin)     In: _Dp[0-3] = origin.
;;; The first channel of the origin stops.
;;; ---------------------------------------------------------------------------
              .public S_StopSound
S_StopSound:  lda     dp:.tiny _Dp
              sta     .near SS_ORIGIN
              lda     dp:.tiny (_Dp+2)
              sta     .near (SS_ORIGIN+2)
              ldx     ##0
1$:           lda     abs:.near CH_SFX,x
              beq     2$
              jsr     .kbank sameOrigin
              bne     2$
              jsr     .kbank stopChannel
              rtl
2$:           inx
              inx
              cpx     ##(2 * NUM_CHANNELS)
              bcc     1$
              rtl

;;; ---------------------------------------------------------------------------
;;; void S_UpdateSounds(void): a channel whose sound ended is free; the
;;; other sounds (not of the player) get the volume and separation of the
;;; new positions, or stop when not audible.
;;; ---------------------------------------------------------------------------
              .public S_UpdateSounds
S_UpdateSounds:
              ldx     ##0
1$:           stx     .near SS_C
              lda     abs:.near CH_SFX,x
              beq     4$
              jsr     .kbank isPlaying
              ldx     .near SS_C
              bcs     2$
              jsr     .kbank stopChannel    ; ended
              bra     4$
2$:           txa                           ; an origin, not the player
              asl     a
              tay
              lda     abs:.near CH_ORIGIN,y
              sta     dp:.tiny (_Dp+4)
              lda     abs:.near (CH_ORIGIN+2),y
              sta     dp:.tiny (_Dp+6)
              ora     dp:.tiny (_Dp+4)
              beq     4$
              lda     dp:.tiny (_Dp+4)
              cmp     .near (PL+OFS_PL_MO)
              bne     3$
              lda     dp:.tiny (_Dp+6)
              cmp     .near (PL+OFS_PL_MO+2)
              beq     4$
3$:           lda     .near snd_SfxVolume   ; volume, sep
              sta     .near SS_VOL
              lda     ##NORM_SEP
              sta     .near SS_SEP
              jsr     .kbank adjustParams
              ldx     .near SS_C
              bcs     31$
              jsr     .kbank stopChannel    ; not audible
              bra     4$
31$:          jsr     .kbank docVolume      ; I_UpdateSoundParams
4$:           ldx     .near SS_C
              inx
              inx
              cpx     ##(2 * NUM_CHANNELS)
              bcc     1$
              rtl

;;; ---------------------------------------------------------------------------
;;; adjustParams: S_AdjustSoundParams(player.mo, the source at _Dp[4-7],
;;; SS_VOL, SS_SEP): the separation from the angle of the source to the
;;; view, the volume from its distance (full within S_CLOSE_DIST, none
;;; beyond S_CLIPPING_DIST except on map 8). Carry set if audible.
;;; ---------------------------------------------------------------------------
adjustParams: lda     .near (PL+OFS_PL_MO)  ; no listener: no
              sta     dp:.tiny _Dp
              lda     .near (PL+OFS_PL_MO+2)
              sta     dp:.tiny (_Dp+2)
              ora     dp:.tiny _Dp
              bne     1$
              clc
              rts
1$:           ldy     ##OFS_MO_X            ; adx, ady (D_abs)
              jsr     .kbank absDelta
              lda     .near SS_T
              sta     .near SS_DIST
              lda     .near (SS_T+2)
              sta     .near (SS_DIST+2)
              ldy     ##OFS_MO_Y
              jsr     .kbank absDelta
              ;; approx_dist = adx + ady - (min(adx, ady) >> 1)
              lda     .near SS_DIST         ; adx < ady: adx is the min
              cmp     .near SS_T
              lda     .near (SS_DIST+2)
              sbc     .near (SS_T+2)
              bvc     2$
              eor     ##0x8000
2$:           bmi     3$
              lda     .near SS_T            ; the min: ady
              sta     .near SS_ANG
              lda     .near (SS_T+2)
              bra     4$
3$:           lda     .near SS_DIST
              sta     .near SS_ANG
              lda     .near (SS_DIST+2)
4$:           cmp     ##0x8000              ; min >> 1 (arithmetic)
              ror     a
              sta     .near (SS_ANG+2)
              ror     .near SS_ANG
              lda     .near SS_DIST         ; adx + ady - that
              clc
              adc     .near SS_T
              tax
              lda     .near (SS_DIST+2)
              adc     .near (SS_T+2)
              tay
              txa
              sec
              sbc     .near SS_ANG
              sta     .near SS_DIST
              tya
              sbc     .near (SS_ANG+2)
              sta     .near (SS_DIST+2)
              ora     .near SS_DIST         ; zero distance: full volume
              bne     5$
              brl     fullVol
5$:           lda     ##0                   ; S_CLIPPING_DIST < dist: not audible
              cmp     .near SS_DIST         ; (except on map 8)
              lda     ##S_CLIPPING_HI
              sbc     .near (SS_DIST+2)
              bvc     6$
              eor     ##0x8000
6$:           bpl     7$
              lda     .near _g_gamemap
              cmp     ##8
              beq     7$
              clc
              rts
7$:           ;; the angle of the source from the view:
              ;; R_PointToAngle2(listener, source), less 1 when it is not
              ;; more than the view angle, less the view angle
              ldy     ##OFS_MO_Y            ; dy
              lda     [.tiny (_Dp+4)],y
              sec
              sbc     [.tiny _Dp],y
              sta     .near SS_T
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sbc     [.tiny _Dp],y
              sta     .near (SS_T+2)
              ldy     ##OFS_MO_X            ; dx
              lda     [.tiny (_Dp+4)],y
              sec
              sbc     [.tiny _Dp],y
              pha
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sbc     [.tiny _Dp],y
              tax
              lda     .near SS_T
              sta     dp:.tiny _Dp
              lda     .near (SS_T+2)
              sta     dp:.tiny (_Dp+2)
              pla
              jsl     long:R_PointToAngle3
              sta     .near SS_ANG
              stx     .near (SS_ANG+2)
              lda     .near (PL+OFS_PL_MO)  ; the listener again
              sta     dp:.tiny _Dp
              lda     .near (PL+OFS_PL_MO+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_MO_ANGLE        ; angle <= listener->angle: - 1
              lda     [.tiny _Dp],y
              cmp     .near SS_ANG
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     .near (SS_ANG+2)
              bcc     8$
              lda     .near SS_ANG
              bne     71$
              dec     .near (SS_ANG+2)
71$:          dec     .near SS_ANG
8$:           lda     .near SS_ANG          ; (angle - listener->angle) >> 19
              ldy     ##OFS_MO_ANGLE
              cmp     [.tiny _Dp],y
              lda     .near (SS_ANG+2)
              iny
              iny
              sbc     [.tiny _Dp],y
              lsr     a
              lsr     a
              lsr     a
              ;; sep = NORM_SEP - ((S_STEREO_SWING * finesineapprox(angle)) >> 16)
              ;; (Doom has 128; 127 gives equal sides at sep NORM_SEP)
              jsl     long:finesineapprox
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     ##S_STEREO_SWING
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_Mul32
              txa
              eor     ##0xffff
              sec
              adc     ##NORM_SEP
              sta     .near SS_SEP
              ;; the volume
              lda     .near (SS_DIST+2)     ; dist < S_CLOSE_DIST: full
              sec
              sbc     ##S_CLOSE_HI
              bvc     9$
              eor     ##0x8000
9$:           bpl     distVol
fullVol:      lda     .near snd_SfxVolume
              asl     a
              asl     a
              asl     a
              bra     volDone
distVol:      lda     .near _g_gamemap      ; map 8: at least 15
              cmp     ##8
              bne     12$
              lda     .near (SS_DIST+2)     ; dist > S_CLIPPING_DIST: that
              cmp     ##S_CLIPPING_HI
              bcc     11$
              bne     101$
              lda     .near SS_DIST
              beq     11$
101$:         stz     .near SS_DIST
              lda     ##S_CLIPPING_HI
              sta     .near (SS_DIST+2)
11$:          jsr     .kbank units          ; 15 + (snd * 8 - 15) * units / S_ATTENUATOR
              lda     .near snd_SfxVolume
              asl     a
              asl     a
              asl     a
              sec
              sbc     ##15
              jsr     .kbank mulLong
              jsr     .kbank divAtt
              clc
              adc     ##15
              bra     volDone
12$:          jsr     .kbank units          ; snd * units * 8 / S_ATTENUATOR
              lda     .near snd_SfxVolume
              jsr     .kbank mulLong
              asl     dp:.tiny _Dp
              rol     dp:.tiny (_Dp+2)
              asl     dp:.tiny _Dp
              rol     dp:.tiny (_Dp+2)
              asl     dp:.tiny _Dp
              rol     dp:.tiny (_Dp+2)
              jsr     .kbank divAtt
volDone:      sta     .near SS_VOL          ; audible: *vol > 0
              cmp     ##0
              beq     1$
              bmi     1$
              sec
              rts
1$:           clc
              rts

;;; units: _Dp[4-7] = (S_CLIPPING_DIST - SS_DIST) >> FRACBITS (0..1040
;;; here).
units:        lda     ##0
              cmp     .near SS_DIST
              lda     ##S_CLIPPING_HI
              sbc     .near (SS_DIST+2)
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              rts

;;; mulLong: _Dp[0-3] = C (sign extended) * _Dp[4-7], the low 32 bits.
mulLong:      sta     dp:.tiny _Dp
              ldx     ##0
              cmp     ##0
              bpl     1$
              dex
1$:           stx     dp:.tiny (_Dp+2)
              jsl     long:_Mul32
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              rts

;;; divAtt: C = _Dp[0-3] / S_ATTENUATOR (signed), the low word.
divAtt:       lda     ##S_ATTENUATOR
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_Div32
              rts

;;; absDelta: SS_T = |the fixed_t at offset Y of the listener (_Dp[0-3]) -
;;; the one of the source (_Dp[4-7])| (D_abs).
absDelta:     lda     [.tiny _Dp],y
              sec
              sbc     [.tiny (_Dp+4)],y
              sta     .near SS_T
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     [.tiny (_Dp+4)],y
              bpl     1$
              tax
              lda     ##0
              sec
              sbc     .near SS_T
              sta     .near SS_T
              txa
              eor     ##0xffff
              adc     ##0
1$:           sta     .near (SS_T+2)
              rts

;;; ---------------------------------------------------------------------------
;;; The DOC channels (i_aiigs.c)
;;; ---------------------------------------------------------------------------

;;; isPlaying: I_SoundIsPlaying(X / 2): carry set if the DOC channel has a
;;; sound and its left oscillator does not stand.
isPlaying:    lda     abs:.near CHANSFX,x
              bne     1$
              clc
              rts
1$:           txa
              clc
              adc     ##DOC_CONTROL
              jsl     long:IIGS_DocRead
              eor     ##CTL_HALT
              lsr     a
              rts

;;; docStop: I_StopSound(X / 2): both oscillators stand.
docStop:      lda     ##CTL_STOPPED
              sta     dp:.tiny _Dp
              txa
              clc
              adc     ##DOC_CONTROL
              jsl     long:IIGS_DocWrite2
              rts

;;; docVolume: I_UpdateSoundParams(X / 2, SS_VOL, SS_SEP). X is 2 * the
;;; channel, as SS_C. The pan law is the law of Chocolate Doom, in the range
;;; of the DOC volume registers: each sample of the sound bank is at full
;;; scale, and the level of a sound is in the register, as other IIgs
;;; software does it (tools/sndbank.py). vol is 0-120. W = vol * K / 256,
;;; with K the word of the sound that plays in sfxK (CHANSFX). The even
;;; oscillator, the left, gets W * (254 - sep) / 256, the odd one, the right,
;;; W * sep / 256. W stops at panCap[sep], so the larger side is 255 at most
;;; and the two sides keep their ratio (no clamp for each side). The loudest
;;; sounds have K = 1111: a close sound at sep 127 gets 255 on both. The
;;; products fit 16 bits, and there is no division.
docVolume:    lda     abs:.near CHANSFX,x
              asl     a
              tay
              lda     .near sfxK,y
              ldx     .near SS_VOL
              sta     dp:.tiny MA
              stx     dp:.tiny MB
              jsl     long:umul16           ; vol * K
              lda     dp:.tiny (MR+1)       ; W: the bits 8-23
              sta     dp:.tiny (_Dp+4)
              lda     .near SS_SEP
              asl     a
              tax
              lda     .near panCap,x
              cmp     dp:.tiny (_Dp+4)
              bcs     1$
              sta     dp:.tiny (_Dp+4)      ; W stops here
1$:           ldx     dp:.tiny (_Dp+4)
              lda     .near SS_SEP          ; right = W * sep / 256
              jsl     long:IIGS_MulLo16
              and     ##0xff00
              sta     dp:.tiny (_Dp+6)
              lda     ##254                 ; left = W * (254 - sep) / 256
              sec
              sbc     .near SS_SEP
              ldx     dp:.tiny (_Dp+4)
              jsl     long:IIGS_MulLo16
              xba
              and     ##0x00ff
              ora     dp:.tiny (_Dp+6)
              sta     dp:.tiny _Dp
              lda     .near SS_C
              clc
              adc     ##DOC_VOLUME
              jsl     long:IIGS_DocWrite2
              rts
              .space  5                     ; the routines after it keep their places

;;; pair: _Dp[0-1] = the low byte of C in both bytes.
pair:         and     ##0x00ff
              sta     dp:.tiny _Dp
              xba
              ora     dp:.tiny _Dp
              sta     dp:.tiny _Dp
              rts

;;; startSound: I_StartSound(SS_SFX, SS_C / 2, SS_VOL, SS_SEP): the sound
;;; in DOC RAM (copied there if needed), both oscillators set and started.
;;; Carry set if it plays.
startSound:   lda     .near SS_SFX
              asl     a
              sta     .near SS_ID
              asl     a
              tax
              lda     long:SND_PCM,x
              ora     long:(SND_PCM+2),x
              bne     1$
              clc                           ; no samples
              rts
1$:           ldx     .near SS_C            ; I_StopSound, chansfx = 0
              jsr     .kbank docStop
              ldx     .near SS_C
              stz     abs:.near CHANSFX,x
              ldx     .near SS_ID           ; in DOC RAM
              lda     long:SND_FREQ,x
              sta     .near SS_FREQ
              lda     long:SND_PAGE,x
              bpl     soundChosen
              jsl     long:selectMissingSound
              bcs     soundChosen
              rts
;;; A far-call bridge for the cold selector; cacheSound returns near.
cacheRequested:
              jsr     .kbank cacheSound
              rtl
              .space  26                    ; preserve the following addresses
soundChosen:  inc     .near USECOUNT        ; the age of its use
              bne     5$
              ldx     ##(2 * CONST_NUMSFX - 2) ; the ages restart
              lda     ##0
4$:           jsl     long:clearSoundUse
              dex
              dex
              bpl     4$
              lda     ##1
              sta     .near USECOUNT
5$:           ldx     .near SS_ID
              jsl     long:recordSoundUse
              nop
              nop
              nop
              lda     long:SND_SIZE,x       ; freq = (freq + ((1 << size) >> 1))
              sta     .near SS_SZ           ;   >> size, 16 bits
              tay
              lda     ##0
              cpy     ##0
              beq     6$
              lda     ##1
              bra     52$
51$:          asl     a
52$:          dey
              bne     51$
6$:           clc
              adc     .near SS_FREQ
              ldy     .near SS_SZ
              beq     8$
7$:           lsr     a
              dey
              bne     7$
8$:           sta     .near SS_T
              jsr     .kbank pair           ; FREQLO, FREQHI of both
              lda     .near SS_C
              clc
              adc     ##DOC_FREQLO
              jsl     long:IIGS_DocWrite2
              lda     .near SS_T
              xba
              jsr     .kbank pair
              lda     .near SS_C
              clc
              adc     ##DOC_FREQHI
              jsl     long:IIGS_DocWrite2
              ldx     .near SS_C            ; chansfx = the sound in DOC RAM,
              lda     .near SS_ID           ;   for docVolume (the volume)
              lsr     a
              sta     abs:.near CHANSFX,x
              jsr     .kbank docVolume
              ldx     .near SS_ID           ; POINTER: the page
              lda     long:SND_PAGE,x
              jsr     .kbank pair
              lda     .near SS_C
              clc
              adc     ##DOC_POINTER
              jsl     long:IIGS_DocWrite2
              lda     .near SS_SZ           ; SIZE: size << 3 | 7
              asl     a
              asl     a
              asl     a
              ora     ##7
              jsr     .kbank pair
              lda     .near SS_C
              clc
              adc     ##DOC_SIZE
              jsl     long:IIGS_DocWrite2
              lda     ##CTL_PLAY            ; CONTROL: play
              sta     dp:.tiny _Dp
              lda     .near SS_C
              clc
              adc     ##DOC_CONTROL
              jsl     long:IIGS_DocWrite2
              sec
              rts
              .space  3                     ; the routines after it keep their places

;;; cacheSound: I_CacheSound(SS_ID / 2): the place in the pool (a multiple
;;; of 256 << size) where the newest sound to remove is the oldest (a free
;;; one at once); sounds that play stay. The sounds there go out, the sound
;;; comes in. Carry clear: no place.
cacheSound:   ldx     ##0                   ; the sounds that play are busy
cacheN1:           stx     .near SS_K
              jsr     .kbank isPlaying
              ldx     .near SS_K
              bcc     cacheN2
              lda     abs:.near CHANSFX,x
              asl     a
              tax
              lda     ##1
              sta     long:SND_BUSY,x
              ldx     .near SS_K
cacheN2:           inx
              inx
              cpx     ##(2 * NUM_CHANNELS)
              bcc     cacheN1
              lda     ##0xffff              ; best = -1, bestage = 0
              sta     .near SS_BEST
              stz     .near SS_AGE
              ldx     .near SS_ID           ; step = 1 << size
              lda     long:SND_SIZE,x
              tay
              lda     ##1
              cpy     ##0
              beq     cacheN4
cacheN3:           asl     a
              dey
              bne     cacheN3
cacheN4:           sta     .near SS_STEP         ; start: the first place in the
              dec     a                     ;   pool
              clc
              adc     .near POOL_LO
              sta     .near SS_START
              lda     .near SS_STEP
              eor     ##0xffff
              inc     a
              and     .near SS_START
              sta     .near SS_START
cacheN5:           ldx     .near SS_ID           ; start + pages <= POOL_HI
              lda     .near SS_START
              clc
              adc     long:SND_PAGES,x
              sta     .near SS_END
              lda     .near POOL_HI
              cmp     .near SS_END
              bcc     cacheN20
              lda     ##0xffff              ; the age of the newest sound in
              sta     .near SS_NEWEST       ; the place
              ldx     .near SS_START
cacheN7:           jmp     long:cacheWalk
              .space  44                    ; preserve this 48-byte loop span
cacheChoice:
cacheN10:          lda     .near SS_BEST         ; best < 0 || newest > bestage
              bmi     cacheN11
              lda     .near SS_NEWEST
              cmp     .near SS_AGE
              beq     cacheN12
              bcc     cacheN12
cacheN11:          lda     .near SS_START
              sta     .near SS_BEST
              lda     .near SS_NEWEST
              sta     .near SS_AGE
              cmp     ##0xffff              ; a free place: at once
              beq     cacheN20
cacheNextCandidate:
cacheN12:          lda     .near SS_START
              clc
              adc     .near SS_STEP
              sta     .near SS_START
              bra     cacheN5
cacheN20:          ldx     ##0                   ; no sound is busy
cacheN21:          phx
              lda     abs:.near CHANSFX,x
              asl     a
              tax
              lda     ##0
              sta     long:SND_BUSY,x
              plx
              inx
              inx
              cpx     ##(2 * NUM_CHANNELS)
              bcc     cacheN21
              lda     .near SS_BEST         ; no place
              bpl     cacheN22
              clc
              rts
cacheN22:          jsr     .kbank placeSound
              sec
              rts

;;; placeSound: the sound SS_ID / 2 to DOC RAM at page SS_BEST: the sounds
;;; in its pages go out, its samples come in, the pages are its own.
placeSound:   ldx     .near SS_ID
              lda     .near SS_BEST
              clc
              adc     long:SND_PAGES,x
              sta     .near SS_END
              ldx     .near SS_BEST
1$:           cpx     .near SS_END
              bcs     3$
              lda     long:PAGEOWNER,x
              and     ##0x00ff
              beq     2$
              phx
              asl     a
              jsr     .kbank evictSound
              plx
2$:           inx
              bra     1$
3$:           ldx     .near SS_ID           ; IIGS_DocUpload(best << 8, pcm, length)
              lda     long:SND_LEN,x
              sta     dp:.tiny (_Dp+4)
              txa
              asl     a
              tax
              lda     long:SND_PCM,x
              sta     dp:.tiny _Dp
              lda     long:(SND_PCM+2),x
              sta     dp:.tiny (_Dp+2)
              lda     .near SS_BEST
              xba
              and     ##0xff00
              jsl     long:IIGS_DocUpload
              lda     .near SS_ID
              lsr     a
              ldx     .near SS_BEST
              sep     #0x20
4$:           cpx     .near SS_END
              bcs     5$
              sta     long:PAGEOWNER,x
              inx
              bra     4$
5$:           rep     #0x20
              ldx     .near SS_ID
              lda     .near SS_BEST
              sta     long:SND_PAGE,x
              rts

;;; loadPlan: DOC RAM gets the plan of map C (tools/sndbank.py; map 0 or a
;;; map without a plan: no sounds, all pages are the pool). Each sound of
;;; the plan that is not at its place goes there, the sounds in those pages
;;; go out, and the pool is the pool of the plan. The same map again (the
;;; player died): the sounds below the pool are still there, and the pool
;;; keeps the sounds of the last minutes.
loadPlan:     cmp     ##(PLAN_MAPS + 1)
              bcc     1$
              lda     ##0
1$:           cmp     .near PLAN_MAP
              bne     11$
              rts
11$:          sta     .near PLAN_MAP
              ldx     ##PLAN_ROW
              jsl     long:IIGS_MulLo16
              sta     .near SS_ROW
              tax
              lda     long:PLANS,x          ; the pool
              and     ##0x00ff
              sta     .near POOL_LO
              lda     long:(PLANS+1),x
              and     ##0x00ff
              sta     .near POOL_HI
              lda     ##2                   ; each sound: SS_ID = 2 * id
              sta     .near SS_ID
2$:           lsr     a
              clc
              adc     .near SS_ROW
              tax
              lda     long:(PLANS+2),x      ; its page
              and     ##0x00ff
              cmp     ##NO_PAGE
              beq     4$
              ldx     .near SS_ID
              cmp     long:SND_PAGE,x       ; there already
              beq     4$
              sta     .near SS_BEST
              lda     long:SND_PAGE,x       ; somewhere else: out
              bmi     3$
              txa
              jsr     .kbank evictSound
3$:           jsr     .kbank placeSound
              ldx     .near SS_ID           ; the oldest use: the first to go
              lda     ##0                   ;   from the pool
              jsl     long:clearSoundUse     ; reset both reference ages
4$:           lda     .near SS_ID
              inc     a
              inc     a
              sta     .near SS_ID
              cmp     ##(2 * CONST_NUMSFX)
              bcc     2$
              rts

;;; evictSound: I_EvictSound(C / 2): its pages are free, it is not in DOC
;;; RAM.
evictSound:   tax
              lda     long:SND_PAGE,x
              clc
              adc     long:SND_PAGES,x
              sta     .near SS_T
              phx
              lda     long:SND_PAGE,x
              tax
              sep     #0x20
              lda     #0
1$:           cpx     .near SS_T
              bcs     2$
              sta     long:PAGEOWNER,x
              inx
              bra     1$
2$:           rep     #0x20
              plx
              lda     ##0xffff
              sta     long:SND_PAGE,x
              rts

;;; ---------------------------------------------------------------------------
;;; void I_InitSound(void): the sounds of the sound bank (SNDBANK_ADDR),
;;; decoded to SNDPCM_ADDR, with their DOC frequency and table size.
;;; ---------------------------------------------------------------------------
              .public I_InitSound
I_InitSound:  lda     long:(SNDBANK_ADDR+SNDDIR_OFS) ; the number of sounds
              cmp     ##CONST_NUMSFX
              beq     1$
              pea     #CONST_NUMSFX
              pha
              lda     ##.word0 errCount
              sta     dp:.tiny _Dp
              lda     ##.word2 errCount
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
1$:           lda     ##.word0 msgDecode
              sta     dp:.tiny _Dp
              lda     ##.word2 msgDecode
              sta     dp:.tiny (_Dp+2)
              jsl     long:printf
              lda     ##.word0 SNDPCM_ADDR  ; dst
              sta     .near SS_DST
              lda     ##.word2 SNDPCM_ADDR
              sta     .near (SS_DST+2)
              stz     .near SS_I
2$:           lda     .near SS_I            ; page = -1
              asl     a
              sta     .near SS_ID
              tax
              lda     ##0xffff
              sta     long:SND_PAGE,x
              txa                           ; the entry: dir + 2 + 8 * i
              asl     a
              asl     a
              tax
              lda     long:(SNDBANK_ADDR+SNDDIR_OFS+2),x ; ofs
              sta     .near SS_DIR
              lda     long:(SNDBANK_ADDR+SNDDIR_OFS+4),x
              sta     .near (SS_DIR+2)
              ora     .near SS_DIR
              bne     3$
              brl     9$                    ; no sound
3$:           lda     long:(SNDBANK_ADDR+SNDDIR_OFS+6),x ; length
              pha
              lda     long:(SNDBANK_ADDR+SNDDIR_OFS+8),x ; rate
              pha
              lda     3,s                   ; nblocks = (length + 15) >> 4
              clc
              adc     ##15
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              sta     .near SS_START
              asl     a                     ; SS_T = nblocks * 16 (32 bits)
              asl     a
              asl     a
              asl     a
              sta     .near SS_T
              lda     .near SS_START
              xba
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              and     ##0x000f
              sta     .near (SS_T+2)
              lda     .near SS_DST          ; SNDPCM_END < dst + that: no room
              clc
              adc     .near SS_T
              sta     .near SS_ANG
              lda     .near (SS_DST+2)
              adc     .near (SS_T+2)
              sta     .near (SS_ANG+2)
              lda     ##.word0 SNDPCM_END
              cmp     .near SS_ANG
              lda     ##.word2 SNDPCM_END
              sbc     .near (SS_ANG+2)
              bcs     4$
              lda     ##.word0 errFit
              sta     dp:.tiny _Dp
              lda     ##.word2 errFit
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
4$:           lda     .near SS_DIR          ; IIGS_DecodeSound(nblocks,
              clc                           ;   SNDBANK_ADDR + ofs, dst)
              adc     ##.word0 SNDBANK_ADDR
              sta     dp:.tiny _Dp
              lda     .near (SS_DIR+2)
              adc     ##.word2 SNDBANK_ADDR
              sta     dp:.tiny (_Dp+2)
              lda     .near SS_DST
              sta     dp:.tiny (_Dp+4)
              lda     .near (SS_DST+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near SS_START
              jsl     long:IIGS_DecodeSound
              cmp     ##0
              beq     5$
              lda     .near SS_I
              pha
              lda     ##.word0 errData
              sta     dp:.tiny _Dp
              lda     ##.word2 errData
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
5$:           lda     .near SS_ID           ; pcm = dst
              asl     a
              tax
              lda     .near SS_DST
              sta     long:SND_PCM,x
              lda     .near (SS_DST+2)
              sta     long:(SND_PCM+2),x
              ldx     .near SS_ID
              lda     3,s                   ; length
              sta     long:SND_LEN,x
              clc                           ; pages = (length + 256) >> 8
              adc     ##256
              xba
              and     ##0x00ff
              sta     long:SND_PAGES,x
              ldy     ##0                   ; size: 1 << size >= pages
              lda     ##1
6$:           cmp     long:SND_PAGES,x
              bcs     7$
              asl     a
              iny
              bra     6$
7$:           tya
              sta     long:SND_SIZE,x
              pla                           ; freq = rate * DOC_FREQ_11025 / 11025
              sta     dp:.tiny _Dp
              stz     dp:.tiny (_Dp+2)
              lda     ##DOC_FREQ_11025
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_Mul32
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     ##11025
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_UDivMod32
              ldx     .near SS_ID
              sta     long:SND_FREQ,x
              pla
              lda     .near SS_T            ; dst += nblocks * 16
              clc
              adc     .near SS_DST
              sta     .near SS_DST
              lda     .near (SS_T+2)
              adc     .near (SS_DST+2)
              sta     .near (SS_DST+2)
9$:           inc     .near SS_I
              lda     .near SS_I
              cmp     ##CONST_NUMSFX
              bcs     10$
              brl     2$
10$:          lda     ##2                   ; the stand-ins: SND_ALIAS and
11$:          sta     .near SS_ID           ;   the frequency through them
              lsr     a
              tax
              lda     long:(SNDBANK_ADDR+PLAN_OFS),x
              and     ##0x00ff
              beq     12$
              asl     a
              ldx     .near SS_ID
              sta     long:SND_ALIAS,x
              tax                           ; its frequency * pitch / 128
              lda     long:SND_FREQ,x
              sta     dp:.tiny _Dp
              stz     dp:.tiny (_Dp+2)
              lda     .near SS_ID
              lsr     a
              tax
              lda     long:(SNDBANK_ADDR+PLAN_OFS+CONST_NUMSFX),x
              and     ##0x00ff
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_Mul32
              sta     .near SS_T            ; >> 7: the middle word of << 1
              stx     .near (SS_T+2)
              asl     .near SS_T
              rol     .near (SS_T+2)
              lda     .near (SS_T+1)
              ldx     .near SS_ID
              sta     long:SND_AFREQ,x
12$:          lda     .near SS_ID
              inc     a
              inc     a
              cmp     ##(2 * CONST_NUMSFX)
              bcc     11$
              ldx     ##(PLAN_ROW * (PLAN_MAPS + 1) - 2) ; the plans
13$:          lda     long:(SNDBANK_ADDR+PLAN_ROWS),x
              sta     long:PLANS,x
              dex
              dex
              bpl     13$
              stz     .near POOL_LO         ; no plan: all pages are the pool
              lda     ##DOC_PAGES
              sta     .near POOL_HI
              lda     ##0xffff
              sta     .near PLAN_MAP
              rtl

;;; The priority of each sound (sfxenum_t order, S_sfx of sounds.c), 0-127,
;;; a low number first: with all channels busy, a new sound stops a sound
;;; with the same or a higher number. The length field of S_sfx is not used.
              .section cnear, rodata
sfxPriority:  .byte   0, 64, 64, 64, 64, 118, 64, 64      ; none pistol shotgn sgcock sawup sawidl sawful sawhit
              .byte   64, 70, 70, 70, 100, 100, 100, 100  ; rlaunc rxplod firsht firxpl pstart pstop doropn dorcls
              .byte   119, 78, 78, 96, 96, 96, 78, 78     ; stnmov swtchn swtchx plpain dmpain popain slop itemup
              .byte   78, 96, 32, 98, 98, 98, 98, 98      ; wpnup oof telept posit1 posit2 posit3 bgsit1 bgsit2
              .byte   98, 94, 70, 70, 32, 32, 70, 70      ; sgtsit brssit sgtatk claw pldeth pdiehi podth1 podth2
              .byte   70, 70, 70, 70, 32, 120, 120, 120   ; podth3 bgdth1 bgdth2 sgtdth brsdth posact bgact dmact
              .byte   78, 60, 64, 60, 60                  ; noway barexp punch tink getpow

;;; The tables of docVolume: sfxK (one word for each sound, in the order of
;;; sfxenum_t) and panCap (one word for each separation 0 to 254).
;;; tools/sndbank.py makes them with the sound bank. The linker script puts
;;; them after the last near data, so no other data moves.
              .section sfxvol, rodata
#include "sfxvol.inc"

;;; The volumes of the sound effects and of the music, 0-15.
              .section near, data
              .public snd_SfxVolume, snd_MusicVolume
snd_SfxVolume: .word  15
#ifdef MUSIC_OFF
snd_MusicVolume: .word 0              ; engine-only timedemo comparisons
#else
snd_MusicVolume: .word 12             ; leave headroom for the sound effects
#endif

;;; ---------------------------------------------------------------------------
;;; Music (tools/musbank.py; the player is the game interrupt of
;;; src/iigs/irq65.s; the layout of MUSBUF is src/iigs/music.inc). Songs are
;;; numbered as in the bank: 0-8 E1M1-E1M9, 9 INTER, 10 INTRO, 11 VICTOR,
;;; 12 INTROA. No song plays at music volume 0: then no alarm runs.
;;; ---------------------------------------------------------------------------
;;; The player's code was 1124 bytes of coldcode: its tables and the same
;;; space stay there, so no code of the game moves (a move changes the
;;; cache slots of hot code: +0.05% in the demos; a section that nothing
;;; uses would go out of the link); the music code runs at a track change
;;; only, in bank 0 $9000 up (src/iigs/iigs.scm).
              .section coldcode, text
;;; The attenuation (1/8 octave) of music volume 0-15: DMX limits each
;;; channel to 8 x the volume (tools/musbank.py music_atten); 255: off.
musAtt:       .byte   255, 51, 45, 39, 32, 26, 21, 16, 13, 9, 7, 4, 1, 0, 0, 0
;;; VMAX x 256 x 2^(-j/8), VMAX = 192 (tools/musbank.py).
mant:         .word   49152, 45073, 41332, 37901, 34756, 31871, 29226, 26800
;;; The alarm frequency (resolution 0) for n tics: a pass is 130560 / FC
;;; samples (tools/musbank.py alarm_fc).
alarmLo:      .byte   0, 182, 91, 231, 174, 139, 116, 99, 87, 77, 69, 63, 58, 53, 50, 46
              .byte   43, 41, 39, 37, 35, 33, 32, 30, 29, 28, 27, 26, 25, 24, 23, 22
              .byte   22, 21, 20, 20, 19, 19, 18, 18, 17, 17, 17, 16, 16, 15, 15, 15
              .byte   14, 14, 14, 14, 13, 13, 13, 13, 12, 12, 12, 12, 12, 11, 11, 11
alarmHi:      .byte   0, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
              .byte   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
              .byte   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
              .byte   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
;;; The song of each music of Doom (sounds.h order): E1M1-E1M9, the other
;;; episodes none, then inter, intro, bunny (none), victor, introa.
musOfDoom:    .byte   255, 0, 1, 2, 3, 4, 5, 6, 7, 8
              .byte   255, 255, 255, 255, 255, 255, 255, 255, 255
              .byte   255, 255, 255, 255, 255, 255, 255, 255, 255
              .byte   9, 10, 255, 11, 12
              ;; PAGEOWNER's nonzero owner covers one contiguous interval.
              ;; Rechecking every page repeats the same busy/age reads and
              ;; stack traffic. Inspect it once, then advance to its end.
              ;; The interval can exceed SS_END: the loop bound handles that.
              ;; Original choice order, minimum age and tie-breaking stay exact.
cacheWalk:    cpx     .near SS_END
              bcc     1$
              jmp     long:cacheChoice
1$:           lda     long:PAGEOWNER,x
              and     ##0x00ff
              bne     2$
              inx
              bra     cacheWalk
2$:           asl     a
              tax
              lda     long:SND_BUSY,x
              beq     3$
              jmp     long:cacheNextCandidate
3$:           lda     .near POOL_HI
              cmp     ##DOC_PAGES
              bcs     cacheLastReference
              lda     .near USECOUNT
              sec
              sbc     long:secondLastUse,x
              ;; Only a song's smaller pool uses second-reference frequency
              ;; weighting. Music off keeps ordinary unweighted last-use age.
              cmp     ##0x1000
              bcc     weightedScale
              lda     ##0xffff
              bra     weightedScaled
weightedScale:
              asl     a
              asl     a
              asl     a
              asl     a
weightedScaled:
              jmp     (.kbank cacheWeightShift,x)
cacheLastReference:
              lda     .near USECOUNT
              sec
              sbc     long:SND_LASTUSE,x
              bra     weightedDone
weightedBy32: lsr     a
weightedBy16: lsr     a
weightedBy8:  lsr     a
weightedBy4:  lsr     a
weightedBy2:  lsr     a
weightedDone:
              ;; A candidate's minimum age can only decrease. Once no older
              ;; than an existing winner it cannot win; retain the first tie.
              cmp     .near SS_AGE
              bcc     5$
              beq     5$
              bra     6$
5$:           tay
              lda     .near SS_BEST
              bmi     7$
              jmp     long:cacheNextCandidate
7$:           tya
6$:           cmp     .near SS_NEWEST
              bcs     4$
              sta     .near SS_NEWEST
4$:           lda     long:SND_PAGE,x
              clc
              adc     long:SND_PAGES,x
              tax
              brl     cacheWalk
;;; 2^round(log2(starts/minute)), clamped to 1..32. These are the
;;; existing priors in tools/sndbank.py STARTS, in CONST_SFX_* order.
;;; A finite recency weight is never a pin: inactive sounds remain evictable.
cacheWeightShift:
              .word   .word0 weightedDone, .word0 weightedBy32, .word0 weightedBy16, .word0 weightedDone, .word0 weightedDone, .word0 weightedDone
              .word   .word0 weightedDone, .word0 weightedDone, .word0 weightedDone, .word0 weightedDone, .word0 weightedBy16, .word0 weightedBy16
              .word   .word0 weightedBy8, .word0 weightedBy8, .word0 weightedBy4, .word0 weightedBy2, .word0 weightedBy16, .word0 weightedDone
              .word   .word0 weightedDone, .word0 weightedBy16, .word0 weightedBy2, .word0 weightedBy8, .word0 weightedDone, .word0 weightedBy16
              .word   .word0 weightedBy2, .word0 weightedDone, .word0 weightedDone, .word0 weightedBy4, .word0 weightedBy4, .word0 weightedBy4
              .word   .word0 weightedBy4, .word0 weightedBy8, .word0 weightedDone, .word0 weightedDone, .word0 weightedBy4, .word0 weightedBy4
              .word   .word0 weightedBy2, .word0 weightedDone, .word0 weightedBy2, .word0 weightedBy2, .word0 weightedBy2, .word0 weightedBy2
              .word   .word0 weightedDone, .word0 weightedDone, .word0 weightedDone, .word0 weightedBy16, .word0 weightedBy16, .word0 weightedBy4
              .word   .word0 weightedBy2, .word0 weightedDone, .word0 weightedDone, .word0 weightedDone, .word0 weightedDone

              .public copyMusicIrq
copyMusicIrq:
              rep     #0x30
              ldx     ##0x02fe
1$:           lda     long:0x00ba00,x
              sta     long:0x00dc00,x
              dex
              dex
              bpl     1$
              ldx     ##30
              rtl
;;; With music sharing DOC RAM, one recent, isolated use should not evict a
;;; repeatedly used effect. Rank idle owners by their second reference age;
;;; retain the finite bank frequency weights and protection for playing sounds.
;;; State and helpers occupy existing cold padding; later code does not move.
recordSoundUse:
              lda     .near POOL_HI
              cmp     ##DOC_PAGES
              bcs     recordLastUse
              lda     long:SND_LASTUSE,x
              sta     long:secondLastUse,x
recordLastUse:
              lda     .near USECOUNT
              sta     long:SND_LASTUSE,x
              rtl
clearSoundUse:
              sta     long:SND_LASTUSE,x
              sta     long:secondLastUse,x
              rtl
;;; Changing residency must not make a cached stand-in suppress its
;;; requested original. In the music pool try the original first; if it
;;; cannot fit, the existing resident stand-in remains the fallback.
;;; The ordinary full-DOC music-off selection retains its prior order.
selectMissingSound:
              lda     .near POOL_HI
              cmp     ##DOC_PAGES
              bcs     missingAlias
              jsl     long:cacheRequested
              bcs     missingDone
missingAlias:
              ldx     .near SS_ID
              lda     long:SND_AFREQ,x
              sta     .near SS_T
              lda     long:SND_ALIAS,x
              beq     missingLoad
              tax
              lda     long:SND_PAGE,x
              bmi     missingLoad
              stx     .near SS_ID
              lda     .near SS_T
              sta     .near SS_FREQ
              sec
              rtl
missingLoad:
              lda     .near POOL_HI
              cmp     ##DOC_PAGES
              bcc     missingFail            ; already tried the original
              jsl     long:cacheRequested
missingDone:  rtl
missingFail:  clc
              rtl
secondLastUse:
              .space  (2 * CONST_NUMSFX)
cacheWalkEnd:
              .space  (1124 - 193 - (cacheWalkEnd - cacheWalk))
              .section muscode, text
              .public S_SetMusicVolume, S_StartMusic, S_ChangeMusic, I_InitSound2
              .public musLevel, musNewMap, musShutdown, musPause, musResume, musStep
              .public musFrame, musTitle, musInter, musFinale, musLoad, musGo
              .extern WI_Start, F_StartFinale
              .extern musOn, musPend, musLoop, musCur, musWant

SOUNDCTL_M    .equ    0xe0c03c
SOUNDDATA_M   .equ    0xe0c03d
SOUNDADRL_M   .equ    0xe0c03e
SOUNDADRH_M   .equ    0xe0c03f
MUS_SONGS     .equ    13
MUS_OSC       .equ    16              ; voice v: oscillator 16 + v
MUS_POOL      .equ    64              ; the pool of the sound effects under a song
ALARM_OSC_M   .equ    30

;;; void I_InitSound2(void): the tables of the player that stay, no song.
I_InitSound2: php
              sep     #0x20
              rep     #0x10
              lda     #0
              sta     long:(MUSBUF+MB_V+1)
              ldx     ##63                  ; the alarm frequency for n tics
1$:           lda     long:alarmLo,x
              sta     long:(MUSBUF+MB_WLO),x
              lda     long:alarmHi,x
              sta     long:(MUSBUF+MB_WHI),x
              dex
              bpl     1$
              ldx     ##15                  ; free run; voices alternate between
2$:           txa                           ;   channels 1 and 0: an even voice
              inc     a                     ;   (the song's left) is channel 1, an
              and     #1                    ;   odd one channel 0 (the right of a
              asl     a                     ;   stereo card, TN.IIGS.019)
              asl     a
              asl     a
              asl     a
              sta     long:(MUSBUF+MB_CTLR),x
              ora     #3                    ; M1 + halt: reset at the DOC scan
              sta     long:(MUSBUF+MB_CTLH),x
              dex
              bpl     2$
              rep     #0x30                 ; the plans of maps 1-9 with their
              lda     ##0                   ;   song (tools/sndbank.py: the rows
              sta     long:(MUSBUF+MB_PSWAP) ;  after map 9), if the sound bank
              sta     long:(MUSBUF+MB_PVALID) ; is still in RAM
              lda     long:(SNDBANK_ADDR+SNDDIR_OFS)
              cmp     ##CONST_NUMSFX
              bne     4$
              ldx     ##(PLAN_ROW * PLAN_MAPS - 1)
3$:           lda     long:(SNDBANK_ADDR+PLAN_ROWS+PLAN_ROW*(PLAN_MAPS+1)),x
              sta     long:(MUSBUF+MB_PLANS),x
              dex
              dex
              bpl     3$
              lda     ##1
              sta     long:(MUSBUF+MB_PVALID)
4$:           plp
              lda     .near snd_MusicVolume
              jmp     long:S_SetMusicVolume

;;; void S_SetMusicVolume(int16_t volume)   In: C = 0-15.
;;; The volume table (the attenuation of DMX for the volume, musAtt); 0:
;;; the music stops (no alarm), a volume again: a looping song plays again.
S_SetMusicVolume:
              php
              rep     #0x30
              and     ##15
              sta     .near snd_MusicVolume
              tax
              lda     long:musAtt,x
              and     ##0x00ff
              cmp     ##0x00ff
              bne     1$
              jsr     .kbank musStop
              plp
              rtl
1$:           jsr     .kbank setVolume
              jsr     .kbank musRevol
              sep     #0x20
              lda     long:musOn
              ora     long:musPend
              bne     2$
              lda     long:musLoop          ; (a song played once, the title's,
              beq     2$                    ;   does not start again)
              lda     long:musWant
              cmp     #MUS_NONE
              beq     2$
              rep     #0x20
              and     ##0x00ff
              jsr     .kbank musPlay
2$:           plp
              rtl

;;; musRevol: each voice's volume register again from its level (the table
;;; changed, and a note writes a level only when it changes). 16-bit A, X, Y.
musRevol:     php
              sei
              lda     ##0                   ; (B = 0: TAX copies it)
              sep     #0x20
              ldy     ##0
1$:           tyx
              lda     long:(MUSBUF+MB_LEVEL),x
              bmi     2$                    ; no level yet
              tax
              lda     long:(MUSBUF+MB_VSCALE),x
              pha
              tya
              clc
              adc     #(0x40 + MUS_OSC)
              tax
              pla
              jsr     .kbank musSet
2$:           iny
              cpy     ##MUS_VOICES
              bcc     1$
              plp
              rts

;;; setVolume: MB_VSCALE[i] = VMAX 2^-((i + C) / 8), i = 0-127, rounded
;;; (vol_of of tools/musbank.py gives the same). 16-bit A, X, Y.
setVolume:    sta     long:(MUSBUF+MB_T0)   ; k = i + C
              ldx     ##0
1$:           lda     long:(MUSBUF+MB_T0)
              lsr     a
              lsr     a
              lsr     a
              cmp     ##16
              bcs     4$
              tay                           ; the shift
              lda     long:(MUSBUF+MB_T0)
              and     ##7
              asl     a
              phx
              tax
              lda     long:mant,x
              plx
2$:           dey
              bmi     3$
              lsr     a
              bra     2$
3$:           clc
              adc     ##128
              xba
              and     ##0x00ff
              bra     5$
4$:           lda     ##0
5$:           sep     #0x20
              sta     long:(MUSBUF+MB_VSCALE),x
              rep     #0x20
              lda     long:(MUSBUF+MB_T0)
              inc     a
              sta     long:(MUSBUF+MB_T0)
              inx
              cpx     ##128
              bcc     1$
              rts

;;; musNewMap (S_Start, before the plan of the map): a new map stops the
;;; song, so the plan gets all DOC pages (the same map again: the song goes
;;; on, as S_ChangeMusic of Doom does). 16-bit A, X, Y.
musNewMap:    lda     .near _g_gamemap
              cmp     ##(PLAN_MAPS + 1)     ; (the map of loadPlan)
              bcc     1$
              lda     ##0
1$:           cmp     .near PLAN_MAP
              beq     2$
              pha
              lda     long:(MUSBUF+MB_READY) ; (a song musLoad put in place for
              bne     4$                    ;   the new map stays)
              jsr     .kbank musStop
4$:           pla
2$:           jsr     .kbank musWillPlay    ; the map's plan with its song in
              cmp     long:(MUSBUF+MB_PSWAP) ;  PLANS if the song will play (a
              beq     9$                    ;   song leaves too few pages for
              pha                           ;   sounds that stay: all a pool)
              lda     long:(MUSBUF+MB_PSWAP)
              beq     3$
              jsr     .kbank planSwap       ; the plan without the song back
3$:           pla
              sta     long:(MUSBUF+MB_PSWAP)
              beq     9$
              jsr     .kbank planSwap
9$:           rtl

;;; musWillPlay: C = map (0-9) if its song will play (music volume, an 8 MB
;;; bank with the song, the plans with the songs), else 0. 16-bit A, X, Y.
musWillPlay:  tay
              beq     9$
              lda     long:(MUSBUF+MB_PVALID)
              beq     8$
              lda     .near snd_MusicVolume
              beq     8$
              lda     long:(MUSBUF+MB_READY) ; its unit in place (musLoad)
              bne     7$
              lda     long:(MUS_RAMMAP + (MUSBANK >> 19))
              and     ##(1 << ((MUSBANK >> 16) & 7))
              beq     8$
              tya                           ; the song of map m: m - 1
              asl     a
              asl     a
              asl     a
              tax
              lda     long:(MUSBANK+2+4-8),x ; its length
              ora     long:(MUSBANK+2+6-8),x
              beq     8$
7$:           tya
              rts
8$:           lda     ##0
9$:           rts

;;; planSwap: the row of map C (1-9) in PLANS and its plan with the song in
;;; MB_PLANS change places. 16-bit A, X, Y.
planSwap:     ldx     ##PLAN_ROW
              jsl     long:IIGS_MulLo16
              tay                           ; Y: the row in PLANS
              sec
              sbc     ##PLAN_ROW
              tax                           ; X: the row in MB_PLANS
              lda     ##PLAN_ROW
              sta     long:(MUSBUF+MB_T0)
              sep     #0x20
1$:           lda     long:(MUSBUF+MB_PLANS),x
              pha
              phx
              tyx
              lda     long:PLANS,x
              plx
              sta     long:(MUSBUF+MB_PLANS),x
              pla
              phx
              tyx
              sta     long:PLANS,x
              plx
              inx
              iny
              rep     #0x20
              lda     long:(MUSBUF+MB_T0)
              dec     a
              sta     long:(MUSBUF+MB_T0)
              sep     #0x20
              bne     1$
              rep     #0x20
              rts

;;; musLevel: the song of the map (S_Start); a song that plays goes on.
musLevel:     ldy     ##1                   ; a map's song loops
              lda     .near _g_gamemap
              dec     a
              cmp     ##9
              bcc     S_ChangeMusic2
              lda     ##MUS_NONE
              bra     S_ChangeMusic2

;;; void S_ChangeMusic(int16_t musicnum), S_StartMusic   In: C = the music
;;; of Doom (mus_e1m1 = 1, ..., mus_inter = 28, mus_intro, mus_bunny,
;;; mus_victor, mus_introa); the song plays unless it plays already. As in
;;; Doom, S_StartMusic plays it once (the title page), S_ChangeMusic again
;;; at its end.
S_StartMusic: ldy     ##0
              bra     musChange
S_ChangeMusic:
              ldy     ##1
musChange:    tax
              lda     long:musOfDoom,x
              and     ##0x00ff
S_ChangeMusic2:
              php
              rep     #0x30
              pha
              tya                           ; (musPlay keeps it: a new music
              sep     #0x20                 ;   volume starts the song as it
              sta     long:musLoop          ;   was)
              rep     #0x20
              pla
              sep     #0x20
              sta     long:musWant
              cmp     long:musCur
              bne     1$
              lda     long:musOn
              ora     long:musPend
              bne     9$
1$:           rep     #0x20
              lda     .near snd_MusicVolume
              beq     8$
              lda     long:musWant
              and     ##0x00ff
              cmp     ##MUS_NONE
              beq     8$
              inc     a                     ; the song musLoad put in place:
              cmp     long:(MUSBUF+MB_READY) ;  it starts, with no load
              bne     2$
              jsr     .kbank musGo2
              plp
              rtl
2$:           dec     a
              jsr     .kbank musPlay
              plp
              rtl
8$:           jsr     .kbank musStop
9$:           plp
              rtl

;;; musPlay: song C: the old one stops, and the new one loads a part a
;;; frame (musStep): its head (stream, pitches, descriptors) into MUSBUF,
;;; its tables into DOC RAM (pages 255 - T to 254); then its pitches and
;;; descriptors in place, the voices halted, the alarm for 1 tic (the first
;;; wake). A track change needs no long stop of the game: the music is
;;; silent while it loads (user, 2026-09-27). A song that is not in the
;;; bank: nothing. 16-bit A, X, Y.
musPlay:      pha
              jsr     .kbank musStop
              pla
              sep     #0x20
              sta     long:musCur
              rep     #0x20
              lda     long:musCur
              and     ##0x00ff
              asl     a
              asl     a
              asl     a
              tax                           ; the entry: u32 offset, u32 length
              lda     long:(MUS_RAMMAP + (MUSBANK >> 19))
              and     ##(1 << ((MUSBANK >> 16) & 7))
              beq     2$                    ; a 4 MB boot: no song bank
              lda     long:(MUSBANK+2+4),x  ; its length
              ora     long:(MUSBANK+2+6),x
              bne     1$
2$:           sep     #0x20                 ; not in the bank
              lda     #MUS_NONE
              sta     long:musCur
              rep     #0x20
              rts
1$:           lda     long:(MUSBANK+2),x    ; the image: MUSBANK + offset
              clc
              adc     ##(MUSBANK & 0xffff)
              sta     dp:.tiny _Dp
              lda     long:(MUSBANK+2+2),x
              adc     ##(MUSBANK >> 16)
              sta     dp:.tiny (_Dp+2)
;;; musSource: the load of the song image at [_Dp] (musPlay, musLoad): its
;;; head and DOC part, its pages (the sound effects there go out). 16-bit.
musSource:    lda     dp:.tiny _Dp
              sta     long:(MUSBUF+MB_HSRC)
              lda     dp:.tiny (_Dp+2)
              sta     long:(MUSBUF+MB_HSRC+2)
              ;; its head: 6 + SL + 2 P + 5 D bytes; its DOC RAM image stays
              ;; where it is (MB_DOCSRC): a song image can be bigger than a bank
              lda     [.tiny _Dp]           ; D
              and     ##0x00ff
              sta     dp:.tiny (_Dp+4)
              asl     a
              asl     a
              clc
              adc     dp:.tiny (_Dp+4)
              sta     dp:.tiny (_Dp+4)      ; 5 D
              lda     [.tiny _Dp]           ; P (0: 256)
              xba
              and     ##0x00ff
              bne     3$
              lda     ##256
3$:           asl     a
              clc
              adc     dp:.tiny (_Dp+4)
              ldy     ##2
              adc     [.tiny _Dp],y         ; SL
              adc     ##6
              sta     long:(MUSBUF+MB_HLEN)
              clc
              adc     dp:.tiny _Dp
              sta     long:(MUSBUF+MB_DOCSRC)
              lda     dp:.tiny (_Dp+2)
              adc     ##0
              sta     long:(MUSBUF+MB_DOCSRC+2)
              lda     ##0
              sta     long:(MUSBUF+MB_HPOS)
              ;; its DOC pages low .. 254: the sound effects there go out now
              ldy     ##4
              lda     [.tiny _Dp],y
              and     ##0x00ff
              sta     long:(MUSBUF+MB_LOW)
              sta     long:(MUSBUF+MB_UPAGE)
              sta     long:(MUSBUF+MB_T1)
              eor     ##0xffff
              sec
              adc     ##255
              sta     long:(MUSBUF+MB_ULEFT)
              jsr     .kbank musEvict
              ;; the sound effects stay below: the pool there, the 64 pages
              ;; under the song (the plan of the map knows no music: with
              ;; the music off it is the game's own)
              lda     long:(MUSBUF+MB_LOW)
              sta     .near POOL_HI
              sec
              sbc     ##MUS_POOL
              bcs     5$
              lda     ##0
5$:           cmp     .near POOL_LO
              bcs     6$
              sta     .near POOL_LO
6$:           sep     #0x20
              lda     #1
              sta     long:musPend
              rep     #0x20
              rts

;;; The music of the pages (src/iigs/w_level65.s jumps here, in place of
;;; its last jump: its code keeps its size): musTitle: the title page
;;; plays mus_intro once (W_NextDemo returns 0); musInter, musFinale: the
;;; intermission and the finale loop mus_inter, mus_victor, then WI_Start or
;;; F_StartFinale with their argument (_Dp[0-3]) as it came.
MUS_INTER     .equ    28              ; sounds.h
MUS_INTRO     .equ    29
MUS_VICTOR    .equ    31
musTitle:     lda     ##MUS_INTRO
              jsl     long:S_StartMusic
              lda     ##0
              rtl
musInter:     pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              lda     ##MUS_INTER
              jsl     long:S_ChangeMusic
              pla
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
              jmp     long:WI_Start
musFinale:    pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              lda     ##MUS_VICTOR
              jsl     long:S_ChangeMusic
              pla
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
              jmp     long:F_StartFinale

;;; musFrame (the main loop, each frame, where it called S_UpdateSounds): a
;;; part of the load of a song, then the positional sounds (a player in a
;;; level).
musFrame:     lda     long:musPend
              and     ##0x00ff
              beq     1$
              jsl     long:musStep
1$:           lda     .near (PL+OFS_PL_MO)
              ora     .near (PL+OFS_PL_MO+2)
              beq     2$
              jmp     long:S_UpdateSounds
2$:           rtl

;;; musStep (musFrame, each frame): a part of the load of the song:
;;; 8 KB of its head, else 16 DOC pages, else its start (musStart).
MUS_PART      .equ    8192
MUS_PAGES     .equ    16
musStep:      php
              rep     #0x30
              lda     long:musPend
              and     ##0x00ff
              beq     9$
              jsr     .kbank musPart
              bcc     9$
              jsr     .kbank musStart
9$:           plp
              rtl

;;; musPart: a part of the load of the song (8 KB of its head, else 16 DOC
;;; pages); C set when all of it is in place. 16-bit A, X, Y.
musPart:      lda     long:(MUSBUF+MB_HLEN)
              sec
              sbc     long:(MUSBUF+MB_HPOS)
              beq     2$
              cmp     ##MUS_PART
              bcc     1$
              lda     ##MUS_PART
1$:           sta     dp:.tiny (_Dp+4)      ; IIGS_CopyHuge(MUSBUF + MB_IMAGE +
              stz     dp:.tiny (_Dp+6)      ;   pos, the image + pos, a part)
              lda     long:(MUSBUF+MB_HPOS)
              clc
              adc     long:(MUSBUF+MB_HSRC)
              sta     dp:.tiny _Dp
              lda     long:(MUSBUF+MB_HSRC+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              lda     long:(MUSBUF+MB_HPOS)
              pha
              clc
              adc     dp:.tiny (_Dp+4)
              sta     long:(MUSBUF+MB_HPOS)
              pla
              clc
              adc     ##((MUSBUF & 0xffff) + MB_IMAGE)
              ldx     ##(MUSBUF >> 16)
              jsl     long:IIGS_CopyHuge
              clc
              rts
2$:           lda     long:(MUSBUF+MB_ULEFT)
              beq     4$
              cmp     ##MUS_PAGES
              bcc     3$
              lda     ##MUS_PAGES
3$:           sta     long:(MUSBUF+MB_T0)   ; musUpload: T0 pages at page T1
              lda     long:(MUSBUF+MB_ULEFT)
              sec
              sbc     long:(MUSBUF+MB_T0)
              sta     long:(MUSBUF+MB_ULEFT)
              lda     long:(MUSBUF+MB_UPAGE)
              sta     long:(MUSBUF+MB_T1)
              clc
              adc     long:(MUSBUF+MB_T0)
              sta     long:(MUSBUF+MB_UPAGE)
              jsr     .kbank musUpload
              clc
              rts
4$:           sec
              rts

;;; musLoad (the level loader: at the end of W_LoadSet of a map, and in the
;;; title's loading screen): the song unit of music A (sounds.h: mus_e1m1 =
;;; 1, mus_inter = 28, mus_intro = 29) at Y:X (the image tools/music/mussc.py
;;; writes: head, DOC part) into MUSBUF and DOC RAM before it returns (the
;;; loader reuses that RAM); it starts at S_ChangeMusic of that music (at
;;; once if the game wants it already), or at musGo. Nothing at music volume
;;; 0 (a raise waits for the next level's unit). Keeps D, B, _Dp[0-7]; A, X,
;;; Y change.
musLoad:      php
              rep     #0x30
              pei     dp:.tiny (_Dp+6)
              pei     dp:.tiny (_Dp+4)
              pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              stx     dp:.tiny _Dp
              sty     dp:.tiny (_Dp+2)
              tax
              lda     .near snd_MusicVolume
              beq     8$
              cpx     ##33                  ; (musOfDoom: 33 musics)
              bcs     8$
              lda     long:musOfDoom,x
              and     ##0x00ff
              cmp     ##MUS_NONE
              beq     8$
              pha
              jsr     .kbank musStop        ; the old song out
              pla
              sep     #0x20
              sta     long:musCur
              rep     #0x20
              jsr     .kbank musSource
1$:           jsr     .kbank musPart
              bcc     1$
              sep     #0x20
              lda     #0
              sta     long:musPend
              rep     #0x20
              lda     long:musCur
              and     ##0x00ff
              inc     a
              sta     long:(MUSBUF+MB_READY) ; in place, not started
              lda     long:musWant          ; the music the game wants already:
              and     ##0x00ff              ;   it starts now
              cmp     long:musCur
              bne     8$
              jsr     .kbank musGo2
8$:           pla
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
              pla
              sta     dp:.tiny (_Dp+4)
              pla
              sta     dp:.tiny (_Dp+6)
              plp
              rtl

;;; musGo (the title: the frame its colors go on): the song musLoad put in
;;; place starts (its first wake at the next tic); at once back when there
;;; is none or the music volume is 0. Keeps D, B, _Dp; A, X, Y change.
musGo:        php
              rep     #0x30
              lda     .near snd_MusicVolume
              beq     9$
              lda     long:(MUSBUF+MB_READY)
              beq     9$
              dec     a
              sep     #0x20
              sta     long:musWant          ; (the title's S_StartMusic finds
              rep     #0x20                 ;   it playing)
              jsr     .kbank musGo2
9$:           plp
              rtl
musGo2:       lda     ##0
              sta     long:(MUSBUF+MB_READY)
              jmp     .kbank musStart       ; (its RTS: back to our caller)

;;; musStart: the loaded song starts: its pitches and descriptors in place,
;;; the voices halted, the alarm for 1 tic (the first wake). 16-bit A, X, Y.
musStart:     ;; the pitches: P low bytes, P high bytes after the stream
              lda     long:(MUSBUF+MB_IMAGE+1)
              and     ##0x00ff
              bne     2$
              lda     ##256
2$:           sta     long:(MUSBUF+MB_T0)   ; P
              lda     long:(MUSBUF+MB_IMAGE+2)   ; the stream length
              clc
              adc     ##MB_STREAM
              tax                           ; the low bytes
              ldy     ##MB_PLO
              lda     long:(MUSBUF+MB_T0)
              dec     a
              phb                           ; (MVN sets the data bank)
              .byte   0x54, (MUSBUF >> 16), (MUSBUF >> 16) ; MVN: X, Y + P
              ldy     ##MB_PHI              ; X: the high bytes
              lda     long:(MUSBUF+MB_T0)
              dec     a
              .byte   0x54, (MUSBUF >> 16), (MUSBUF >> 16)
              ;; the descriptors (D each: pages, sizes, modes, loop pages,
              ;; loop sizes) after the high bytes (X)
              ldy     ##MB_DPTR
              jsr     .kbank musDesc
              ldy     ##MB_DSIZ
              jsr     .kbank musDesc
              ldy     ##MB_DMODE
              jsr     .kbank musDesc
              ldy     ##MB_LPTR
              jsr     .kbank musDesc
              ldy     ##MB_LSIZ
              jsr     .kbank musDesc
              plb
              ;; the voices: halted, 256-byte tables at resolution 0
              lda     ##0                   ; (B = 0: TAX copies it)
              php
              sei
              sep     #0x20
              ldy     ##0
5$:           tya
              clc
              adc     #(0xc0 + MUS_OSC)     ; size and resolution
              tax
              lda     #0
              jsr     .kbank musSet
              tya
              clc
              adc     #(0x40 + MUS_OSC)     ; volume
              tax
              lda     #0
              jsr     .kbank musSet
              tya
              clc
              adc     #(0x80 + MUS_OSC)     ; a table page
              tax
              lda     long:(MUSBUF+MB_LOW)
              jsr     .kbank musSet
              tya
              clc
              adc     #(0xa0 + MUS_OSC)     ; halted
              tax
              phx
              tyx
              lda     long:(MUSBUF+MB_CTLH),x
              plx
              jsr     .kbank musSet
              tyx                           ; no level yet: a note writes its
              lda     #0xff                 ;   own (the player writes a level
              sta     long:(MUSBUF+MB_LEVEL),x ; only when it changes)
              iny
              cpy     ##MUS_VOICES
              bcc     5$
              lda     #0
              sta     long:(MUSBUF+MB_SPTR)
              sta     long:(MUSBUF+MB_SPTR+1)
              sta     long:musPend
              lda     #2                    ; the first alarm: 1 tic (its wait
              sta     long:(MUSBUF+MB_FCHI) ;   writes both bytes)
              lda     #1
              sta     long:musOn
              jsr     .kbank musAlarm
              plp
              rts

;;; musDesc: the D descriptor bytes at X to MUSBUF + Y (MVN: X, Y move on).
;;; 16-bit A, X, Y; DBR saved by the caller.
musDesc:      lda     long:(MUSBUF+MB_IMAGE)
              and     ##0x00ff
              dec     a
              .byte   0x54, (MUSBUF >> 16), (MUSBUF >> 16)
              rts

;;; musUpload: T (MB_T0) tables of 256 bytes of the song's DOC RAM image
;;; (MB_DOCSRC, from page MB_LOW) to DOC RAM pages MB_T1 up; a page at a
;;; time with interrupts off (the interrupt uses the GLU). No 0 byte after
;;; them: page 255 is the timer ramp. 16-bit A, X.
musUpload:    lda     long:(MUSBUF+MB_T1)
              sec
              sbc     long:(MUSBUF+MB_LOW)
              xba                           ; (T1 - LOW) x 256
              and     ##0xff00
              clc
              adc     long:(MUSBUF+MB_DOCSRC)
              sta     dp:.tiny _Dp
              lda     long:(MUSBUF+MB_DOCSRC+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              lda     long:(MUSBUF+MB_T0)
              beq     9$
              lda     long:(MUSBUF+MB_T1)
              sta     long:(MUSBUF+MB_V)    ; (scratch: the page)
1$:           php
              sei
              sep     #0x20
2$:           lda     long:SOUNDCTL_M
              bmi     2$
              and     #0x0f
              ora     #0x60                 ; DOC RAM, auto increment
              sta     long:SOUNDCTL_M
              lda     #0
              sta     long:SOUNDADRL_M
              lda     long:(MUSBUF+MB_V)
              sta     long:SOUNDADRH_M
              ldy     ##0
3$:           lda     [.tiny _Dp],y
              sta     long:SOUNDDATA_M
              iny
              cpy     ##256
              bne     3$
              lda     long:SOUNDCTL_M       ; registers again
              and     #0x0f
              sta     long:SOUNDCTL_M
              lda     long:(MUSBUF+MB_V)
              inc     a
              sta     long:(MUSBUF+MB_V)
              plp
              lda     dp:.tiny _Dp          ; the next page of the image
              clc
              adc     ##256
              sta     dp:.tiny _Dp
              bcc     4$
              inc     dp:.tiny (_Dp+2)
4$:           lda     long:(MUSBUF+MB_T0)
              dec     a
              sta     long:(MUSBUF+MB_T0)
              bne     1$
              lda     ##0                   ; (MB_V + 1 is 0 for the player)
              sta     long:(MUSBUF+MB_V)
9$:           rts

;;; musEvict: the sound effects in pages MB_T1 to 254 go out (the plan and
;;; the pool reach there when no song plays), and the DOC channel that plays
;;; one stops (else it plays the tables). evictSound of the sound effects
;;; above, in this bank. 16-bit A, X, Y.
musEvict:     lda     long:(MUSBUF+MB_T1)
1$:           cmp     ##DOC_PAGES
              bcs     9$
              sta     long:(MUSBUF+MB_T2)   ; the page
              tax
              lda     long:PAGEOWNER,x
              and     ##0x00ff
              beq     3$
              sta     long:(MUSBUF+MB_T3)   ; the sound
              ldx     ##(2 * NUM_CHANNELS - 2)
4$:           lda     abs:.near CHANSFX,x
              cmp     long:(MUSBUF+MB_T3)
              bne     5$
              phx
              lda     ##CTL_STOPPED         ; (docStop)
              sta     dp:.tiny _Dp
              txa
              clc
              adc     ##DOC_CONTROL
              jsl     long:IIGS_DocWrite2
              plx
5$:           dex
              dex
              bpl     4$
              lda     long:(MUSBUF+MB_T3)
              asl     a
              tax                           ; 2 x the sound
              lda     long:SND_PAGE,x
              tay                           ; its first page
              lda     long:SND_PAGES,x
              sta     long:(MUSBUF+MB_T3)   ; its pages
              lda     ##0xffff
              sta     long:SND_PAGE,x       ; not in DOC RAM
              tyx
              sep     #0x20
2$:           lda     #0
              sta     long:PAGEOWNER,x
              inx
              rep     #0x20
              lda     long:(MUSBUF+MB_T3)
              dec     a
              sta     long:(MUSBUF+MB_T3)
              sep     #0x20
              bne     2$
              rep     #0x20
3$:           lda     long:(MUSBUF+MB_T2)
              inc     a
              bra     1$
9$:           rts

;;; musAlarm: the alarm for n = 3 - MB_FCHI tics (1-3): its high byte is
;;; the one the stream's next wait may keep (a wait of 3 tics or more writes
;;; only the low byte). Interrupts off, 8-bit A, 16-bit X.
musAlarm:     lda     #3
              sec
              sbc     long:(MUSBUF+MB_FCHI)
              rep     #0x20
              and     ##0x0003
              tax
              sep     #0x20
              lda     long:(MUSBUF+MB_WLO),x
              pha
              lda     long:(MUSBUF+MB_WHI),x
              ldx     ##(0x20 + ALARM_OSC_M)
              jsr     .kbank musSet
              pla
              ldx     ##(0x00 + ALARM_OSC_M)
              jsr     .kbank musSet
              ldx     ##(0xa0 + ALARM_OSC_M)
              lda     #0x0a                 ; one-shot, interrupt on, running
              jmp     .kbank musSet

;;; musStop: no song plays: no alarm, the voices halted. 16-bit A, X, Y.
musStop:      php
              sei
              sep     #0x20
              lda     #0
              sta     long:musOn
              sta     long:musPend
              sta     long:(MUSBUF+MB_READY)
              sta     long:(MUSBUF+MB_READY+1)
              plp
              ldx     .near SS_ROW          ; the pool of the plan of the map
              lda     long:PLANS,x          ;   again, to the last page (the
              and     ##0x00ff              ;   song's pages too; a plan with
              sta     .near POOL_LO         ;   the song ends at the song)
              lda     ##DOC_PAGES
              sta     .near POOL_HI
              jsl     long:IIGS_AlarmOff
              ;; the voices halted (also from musPause)
musHalt:      php
              sei
              rep     #0x30
              lda     ##0                   ; (B = 0: TAX copies it)
              sep     #0x20
              ldy     ##0
1$:           tya
              clc
              adc     #(0xa0 + MUS_OSC)
              tax
              phx
              tyx
              lda     long:(MUSBUF+MB_CTLH),x
              plx
              jsr     .kbank musSet
              iny
              cpy     ##MUS_VOICES
              bcc     1$
              plp
              rts

;;; musSet: DOC register X = A. 8-bit A, 16-bit X; interrupts off.
musSet:       pha
1$:           lda     long:SOUNDCTL_M
              bmi     1$
              and     #0x0f                 ; registers, no auto increment
              sta     long:SOUNDCTL_M
              txa
              sta     long:SOUNDADRL_M
              pla
              sta     long:SOUNDDATA_M
              rts

;;; musShutdown: I_ShutdownSound: the DOC channels (docStop) and the music.
musShutdown:  ldx     ##0
1$:           phx
              lda     ##CTL_STOPPED
              sta     dp:.tiny _Dp
              txa
              clc
              adc     ##DOC_CONTROL
              jsl     long:IIGS_DocWrite2
              plx
              inx
              inx
              cpx     ##(2 * NUM_CHANNELS)
              bcc     1$
              jsr     .kbank musStop
              rtl

;;; musPause (IIGS_StopInterrupts, for a disk access): no alarm, the voices
;;; halted (no note drones); the song stays. musResume (IIGS_StartInterrupts):
;;; its alarm again. Interrupts off.
musPause:     php
              rep     #0x30
              jsl     long:IIGS_AlarmOff
              jsr     .kbank musHalt
              plp
              rtl
musResume:    php
              sep     #0x20
              rep     #0x10
              lda     long:musOn
              beq     9$
              jsr     .kbank musAlarm
9$:           plp
              rtl

