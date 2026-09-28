;;; Sector lights in 65816 assembly.
;;;
;;; p_lights.c with the same results: the flash, strobe and glow
;;; thinkers, their spawn functions, P_FindMinSurroundingLight and
;;; EV_LightTurnOn.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "tics.inc"
#if TICSTEP > 1
              .extern ticRun
#endif

              .extern _Dp, _g_sectors, P_Random, P_AddThinker, Z_CallocLevSpec
              .extern getNextSector, P_FindSectorFromLineTag, IIGS_MulLo16

GLOWSPEED     .equ    8               ; p_spec.h
STROBEBRIGHT  .equ    5

;;; The thinkers of p_lights.c: thinker_t (12 bytes), then
LT_SECTOR     .equ    12              ; all: the sector
LF_COUNT      .equ    16              ; lightflash_t (22 bytes)
LF_MAXLIGHT   .equ    18
LF_MINLIGHT   .equ    20
LF_SIZE       .equ    22
SF_COUNT      .equ    16              ; strobe_t (24 bytes)
SF_MINLIGHT   .equ    18
SF_MAXLIGHT   .equ    20
SF_DARKTIME   .equ    22
SF_SIZE       .equ    24
GL_MINLIGHT   .equ    16              ; glow_t (21 bytes)
GL_MAXLIGHT   .equ    18
GL_DIRECTION  .equ    20              ; int8_t
GL_SIZE       .equ    21

              .section znear, bss
LI_SEC:       .space  4               ; the sector
LI_MIN:       .space  2
LI_I:         .space  2
LI_LINE:      .space  4               ; EV_LightTurnOn: the line
LI_BRIGHT:    .space  2

;;; ---------------------------------------------------------------------------
;;; T_LightFlash(lightflash_t __far* flash), T_StrobeFlash, T_Glow:
;;; the thinkers, _Dp[0-3] = the thinker. The sector is in _Dp[4-7].
;;; With TICSTEP > 1, each runs its tic (flashTic, strobeTic, glowTic) for
;;; each tic of the run.
;;; ---------------------------------------------------------------------------
              .section logiccode, text
              .public T_LightFlash
#if TICSTEP > 1
T_LightFlash: TICLOOP flashTic
              rtl
flashTic:     ldy     ##LF_COUNT            ; if (--count) return
#else
T_LightFlash: ldy     ##LF_COUNT            ; if (--count) return
#endif
              lda     [.tiny _Dp],y
              dec     a
              sta     [.tiny _Dp],y
              beq     1$
              rtl
1$:           jsr     .kbank ltSector
              ldy     ##OFS_SEC_LIGHTLEVEL  ; at the maximum: to the minimum
              lda     [.tiny (_Dp+4)],y
              ldy     ##LF_MAXLIGHT
              cmp     [.tiny _Dp],y
              bne     2$
              ldy     ##LF_MINLIGHT
              lda     [.tiny _Dp],y
              ldy     ##OFS_SEC_LIGHTLEVEL
              sta     [.tiny (_Dp+4)],y
              jsl     long:P_Random         ; count = (P_Random() & 7) + 1
              and     ##7
              bra     3$
2$:           lda     [.tiny _Dp],y         ; else to the maximum
              ldy     ##OFS_SEC_LIGHTLEVEL
              sta     [.tiny (_Dp+4)],y
              jsl     long:P_Random         ; count = (P_Random() & 64) + 1
              and     ##64
3$:           inc     a
              ldy     ##LF_COUNT
              sta     [.tiny _Dp],y
              rtl

              .public T_StrobeFlash
#if TICSTEP > 1
T_StrobeFlash:
              TICLOOP strobeTic
              rtl
strobeTic:    ldy     ##SF_COUNT            ; if (--count) return
#else
T_StrobeFlash:
              ldy     ##SF_COUNT            ; if (--count) return
#endif
              lda     [.tiny _Dp],y
              dec     a
              sta     [.tiny _Dp],y
              beq     1$
              rtl
1$:           jsr     .kbank ltSector
              ldy     ##OFS_SEC_LIGHTLEVEL  ; at the minimum: to the maximum,
              lda     [.tiny (_Dp+4)],y     ; STROBEBRIGHT tics
              ldy     ##SF_MINLIGHT
              cmp     [.tiny _Dp],y
              bne     2$
              ldy     ##SF_MAXLIGHT
              lda     [.tiny _Dp],y
              ldy     ##OFS_SEC_LIGHTLEVEL
              sta     [.tiny (_Dp+4)],y
              lda     ##STROBEBRIGHT
              bra     3$
2$:           lda     [.tiny _Dp],y         ; else to the minimum, darktime tics
              ldy     ##OFS_SEC_LIGHTLEVEL
              sta     [.tiny (_Dp+4)],y
              ldy     ##SF_DARKTIME
              lda     [.tiny _Dp],y
3$:           ldy     ##SF_COUNT
              sta     [.tiny _Dp],y
              rtl

              .public T_Glow
#if TICSTEP > 1
T_Glow:       TICLOOP glowTic
              rtl
glowTic:      jsr     .kbank ltSector
#else
T_Glow:       jsr     .kbank ltSector
#endif
              ldy     ##GL_DIRECTION        ; -1: dims, 1: brightens, else nothing
              lda     [.tiny _Dp],y
              and     ##0x00ff
              cmp     ##0x00ff
              beq     1$
              cmp     ##1
              beq     2$
              rtl
1$:           ldy     ##OFS_SEC_LIGHTLEVEL  ; lightlevel -= GLOWSPEED
              lda     [.tiny (_Dp+4)],y
              sec
              sbc     ##GLOWSPEED
              sta     [.tiny (_Dp+4)],y
              ldy     ##GL_MINLIGHT         ; <= minlight: back, and up
              sec
              sbc     [.tiny _Dp],y
              beq     11$
              bvc     10$
              eor     ##0x8000
10$:          bpl     9$
11$:          ldy     ##OFS_SEC_LIGHTLEVEL
              lda     [.tiny (_Dp+4)],y
              clc
              adc     ##GLOWSPEED
              sta     [.tiny (_Dp+4)],y
              lda     ##1
              bra     30$
2$:           ldy     ##OFS_SEC_LIGHTLEVEL  ; lightlevel += GLOWSPEED
              lda     [.tiny (_Dp+4)],y
              clc
              adc     ##GLOWSPEED
              sta     [.tiny (_Dp+4)],y
              ldy     ##GL_MAXLIGHT         ; >= maxlight: back, and down
              sec
              sbc     [.tiny _Dp],y
              bvc     20$
              eor     ##0x8000
20$:          bmi     9$
              ldy     ##OFS_SEC_LIGHTLEVEL
              lda     [.tiny (_Dp+4)],y
              sec
              sbc     ##GLOWSPEED
              sta     [.tiny (_Dp+4)],y
              lda     ##0x00ff
30$:          sep     #0x20                 ; direction (a byte)
              ldy     ##GL_DIRECTION
              sta     [.tiny _Dp],y
              rep     #0x20
9$:           rtl

;;; ltSector: _Dp[4-7] = the sector of the light thinker at _Dp[0-3].
ltSector:     ldy     ##LT_SECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              rts

;;; ---------------------------------------------------------------------------
;;; int16_t P_FindMinSurroundingLight(sector_t __far* sector, int16_t max)
;;; The lowest light level of the sectors next to it, at most max.
;;; ---------------------------------------------------------------------------
              .public P_FindMinSurroundingLight
P_FindMinSurroundingLight:
              sta     .near LI_MIN
              lda     dp:.tiny _Dp
              sta     .near LI_SEC
              lda     dp:.tiny (_Dp+2)
              sta     .near (LI_SEC+2)
              jsr     .kbank minLight
              rtl

;;; minLight: C = LI_MIN = min(LI_MIN, the lights next to LI_SEC).
minLight:     stz     .near LI_I
1$:           jsr     .kbank secArg         ; for (i = 0; i < linecount; i++)
              ldy     ##OFS_SEC_LINECOUNT
              lda     .near LI_I
              cmp     [.tiny _Dp],y
              bcs     9$
              jsr     .kbank nextSector     ; check = getNextSector(lines[i], sector)
              bcc     2$
              ldy     ##OFS_SEC_LIGHTLEVEL  ; check->lightlevel < min: min
              lda     [.tiny _Dp],y
              sec
              sbc     .near LI_MIN
              bvc     11$
              eor     ##0x8000
11$:          bpl     2$
              lda     [.tiny _Dp],y
              sta     .near LI_MIN
2$:           inc     .near LI_I
              bra     1$
9$:           lda     .near LI_MIN
              rts

;;; secArg: _Dp[0-3] = LI_SEC.
secArg:       lda     .near LI_SEC
              sta     dp:.tiny _Dp
              lda     .near (LI_SEC+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; nextSector: _Dp[0-3] = getNextSector(LI_SEC->lines[LI_I], LI_SEC),
;;; carry set if it is not NULL.
nextSector:   jsr     .kbank secArg
              lda     .near LI_I            ; lines[i]
              asl     a
              asl     a
              clc
              ldy     ##OFS_SEC_LINES
              adc     [.tiny _Dp],y
              pha
              iny
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+2)
              pla
              sta     dp:.tiny _Dp
              ldy     ##2
              lda     [.tiny _Dp],y
              tax
              lda     [.tiny _Dp]
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near LI_SEC          ; getNextSector(line, sector)
              sta     dp:.tiny (_Dp+4)
              lda     .near (LI_SEC+2)
              sta     dp:.tiny (_Dp+6)
              jsl     long:getNextSector
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              txa
              ora     dp:.tiny _Dp
              beq     8$
              sec
              rts
8$:           clc
              rts

;;; ---------------------------------------------------------------------------
;;; void P_SpawnLightFlash(sector_t __far* sector)
;;; void P_SpawnStrobeFlash(sector_t __far* sector, int16_t fastOrSlow,
;;;                         boolean inSync)
;;; void P_SpawnGlowingLight(sector_t __far* sector)
;;; ---------------------------------------------------------------------------
              .public P_SpawnLightFlash, P_SpawnStrobeFlash, P_SpawnGlowingLight
P_SpawnLightFlash:
              jsr     .kbank takeSector     ; sector->special = 0
              lda     ##LF_SIZE
              ldx     ##.word0 T_LightFlash
              ldy     ##.word2 T_LightFlash
              jsr     .kbank newLight
              ldy     ##OFS_SEC_LIGHTLEVEL  ; maxlight = sector->lightlevel
              lda     [.tiny (_Dp+4)],y
              ldy     ##LF_MAXLIGHT
              sta     [.tiny _Dp],y
              jsr     .kbank minOfSector    ; minlight
              ldy     ##LF_MINLIGHT
              sta     [.tiny _Dp],y
              jsl     long:P_Random         ; count = (P_Random() & 64) + 1
              and     ##64
              inc     a
              ldy     ##LF_COUNT
              sta     [.tiny _Dp],y
              rtl

P_SpawnStrobeFlash:
              pha                           ; fastOrSlow (A), inSync (_Dp+4)
              pei     dp:.tiny (_Dp+4)
              lda     ##SF_SIZE
              ldx     ##.word0 T_StrobeFlash
              ldy     ##.word2 T_StrobeFlash
              jsr     .kbank newLightOf     ; (the sector of _Dp[0-3])
              lda     3,s                   ; darktime = fastOrSlow
              ldy     ##SF_DARKTIME
              sta     [.tiny _Dp],y
              ldy     ##OFS_SEC_LIGHTLEVEL  ; maxlight = sector->lightlevel
              lda     [.tiny (_Dp+4)],y
              ldy     ##SF_MAXLIGHT
              sta     [.tiny _Dp],y
              jsr     .kbank minOfSector    ; minlight, 0 if it is maxlight
              ldy     ##SF_MAXLIGHT
              cmp     [.tiny _Dp],y
              bne     1$
              lda     ##0
1$:           ldy     ##SF_MINLIGHT
              sta     [.tiny _Dp],y
              ldy     ##OFS_SEC_SPECIAL     ; sector->special = 0
              lda     ##0
              sta     [.tiny (_Dp+4)],y
              pla                           ; inSync: count 1
              bne     2$
              jsl     long:P_Random         ; else (P_Random() & 7) + 1
              and     ##7
              inc     a
              bra     3$
2$:           lda     ##1
3$:           ldy     ##SF_COUNT
              sta     [.tiny _Dp],y
              pla
              rtl

P_SpawnGlowingLight:
              lda     ##GL_SIZE
              ldx     ##.word0 T_Glow
              ldy     ##.word2 T_Glow
              jsr     .kbank newLightOf
              jsr     .kbank minOfSector    ; minlight
              ldy     ##GL_MINLIGHT
              sta     [.tiny _Dp],y
              ldy     ##OFS_SEC_LIGHTLEVEL  ; maxlight = sector->lightlevel
              lda     [.tiny (_Dp+4)],y
              ldy     ##GL_MAXLIGHT
              sta     [.tiny _Dp],y
              sep     #0x20                 ; direction = -1
              lda     #0xff
              ldy     ##GL_DIRECTION
              sta     [.tiny _Dp],y
              rep     #0x20
              ldy     ##OFS_SEC_SPECIAL     ; sector->special = 0
              lda     ##0
              sta     [.tiny (_Dp+4)],y
              rtl

;;; takeSector: LI_SEC = the sector at _Dp[0-3], sector->special = 0.
takeSector:   lda     dp:.tiny _Dp
              sta     .near LI_SEC
              lda     dp:.tiny (_Dp+2)
              sta     .near (LI_SEC+2)
              ldy     ##OFS_SEC_SPECIAL
              lda     ##0
              sta     [.tiny _Dp],y
              rts

;;; newLightOf: LI_SEC = the sector at _Dp[0-3], then newLight.
newLightOf:   pha
              lda     dp:.tiny _Dp
              sta     .near LI_SEC
              lda     dp:.tiny (_Dp+2)
              sta     .near (LI_SEC+2)
              pla
              ;; fall into newLight

;;; newLight: a new light thinker of C bytes (Z_CallocLevSpec) with the
;;; function Y:X, added to the thinkers, its sector LI_SEC. Out: _Dp[0-3]
;;; = the thinker, _Dp[4-7] = the sector.
newLight:     phy
              phx
              jsl     long:Z_CallocLevSpec
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              jsl     long:P_AddThinker
              pla
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
              pla                           ; thinker.function
              ldy     ##OFS_TH_FUNCTION
              sta     [.tiny _Dp],y
              pla
              iny
              iny
              sta     [.tiny _Dp],y
              ldy     ##LT_SECTOR           ; the sector
              lda     .near LI_SEC
              sta     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     .near (LI_SEC+2)
              sta     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              rts

;;; minOfSector: C = P_FindMinSurroundingLight(LI_SEC, LI_SEC->lightlevel);
;;; _Dp[0-7] stay.
minOfSector:  pei     dp:.tiny (_Dp+6)
              pei     dp:.tiny (_Dp+4)
              pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              jsr     .kbank secArg
              ldy     ##OFS_SEC_LIGHTLEVEL
              lda     [.tiny _Dp],y
              sta     .near LI_MIN
              jsr     .kbank minLight
              tax
              pla
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
              pla
              sta     dp:.tiny (_Dp+4)
              pla
              sta     dp:.tiny (_Dp+6)
              txa
              rts

;;; ---------------------------------------------------------------------------
;;; void EV_LightTurnOn(const line_t __far* line, int16_t bright)
;;; The sectors with the tag of the line get light level bright, or for 0
;;; the highest light level next to each of them.
;;; ---------------------------------------------------------------------------
              .public EV_LightTurnOn
EV_LightTurnOn:
              sta     .near LI_BRIGHT
              lda     dp:.tiny _Dp
              sta     .near LI_LINE
              lda     dp:.tiny (_Dp+2)
              sta     .near (LI_LINE+2)
              lda     ##0xffff              ; i = -1
1$:           pha                           ; i = P_FindSectorFromLineTag(line, i)
              lda     .near LI_LINE
              sta     dp:.tiny _Dp
              lda     .near (LI_LINE+2)
              sta     dp:.tiny (_Dp+2)
              pla
              jsl     long:P_FindSectorFromLineTag
              cmp     ##0
              bpl     2$
              rtl
2$:           pha                           ; the sector: _g_sectors + i
              ldx     ##SIZEOF_SEC
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sectors
              sta     .near LI_SEC
              lda     .near (_g_sectors+2)
              sta     .near (LI_SEC+2)
              lda     .near LI_BRIGHT       ; tbright = bright
              sta     .near LI_MIN
              bne     5$
              stz     .near LI_I            ; 0: the highest light next to it
3$:           jsr     .kbank secArg
              ldy     ##OFS_SEC_LINECOUNT
              lda     .near LI_I
              cmp     [.tiny _Dp],y
              bcs     5$
              jsr     .kbank nextSector
              bcc     4$
              ldy     ##OFS_SEC_LIGHTLEVEL  ; temp->lightlevel > tbright
              lda     .near LI_MIN
              sec
              sbc     [.tiny _Dp],y
              bvc     31$
              eor     ##0x8000
31$:          bpl     4$
              lda     [.tiny _Dp],y
              sta     .near LI_MIN
4$:           inc     .near LI_I
              bra     3$
5$:           jsr     .kbank secArg         ; sector->lightlevel = tbright
              ldy     ##OFS_SEC_LIGHTLEVEL
              lda     .near LI_MIN
              sta     [.tiny _Dp],y
              pla
              brl     1$
