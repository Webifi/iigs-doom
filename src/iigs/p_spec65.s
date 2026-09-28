;;; Sector and line specials in 65816 assembly.
;;;
;;; p_spec.c with the same results: the sector helpers, the tag
;;; checks, the animated textures, the switch timers, the scrolling walls
;;; and the spawning of the specials at level start.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "tics.inc"
#if TICSTEP > 1
              .extern ticRun
#endif

              .extern _Dp, _g_sides, _g_sectors, _g_numsectors, _g_lines
              .extern _g_numlines, _g_leveltime, _g_totalsecret, _g_buttonlist
              .extern texturetranslation, R_CheckTextureNumForName
              .extern P_UpdateAnimatedFlat, S_StartSound2
              .extern P_SpawnLightFlash, P_SpawnStrobeFlash, P_SpawnGlowingLight
              .extern P_AddThinker, Z_CallocLevSpec, IIGS_MulLo16
              .extern MA, MB, MR, umul16

FASTDARK      .equ    15              ; p_spec.h
SLOWDARK      .equ    35
SC_TEXOFS     .equ    12              ; scroll_t: thinker_t, textureoffset
SC_SIZE       .equ    16

              .section znear, bss
              .public animated_texture_basepic ; (W_LevelDone of w_level65.s)
animated_texture_basepic:
              .space  2
SP_SEC:       .space  4               ; a sector
SP_T:         .space  4               ; the result of the Find functions
SP_I:         .space  2
SP_OTHER:     .space  4

              .section cfar, rodata
sladrip1:     .asciz  "SLADRIP1"
;;; the specials that need no tag: manual doors, lights, thing teleporters,
;;; exits, scrolling walls
notags:       .word   1, 26, 27, 28, 31, 32, 33, 34, 35, 97, 11, 51, 48
notags_end:

;;; ---------------------------------------------------------------------------
;;; void P_InitPicAnims(void): the first texture of the dripping slime.
;;; ---------------------------------------------------------------------------
              .section logiccode, text
              .public P_InitPicAnims
P_InitPicAnims:
              lda     ##.word0 sladrip1
              sta     dp:.tiny _Dp
              lda     ##.word2 sladrip1
              sta     dp:.tiny (_Dp+2)
              jsl     long:R_CheckTextureNumForName
              sta     .near animated_texture_basepic
              rtl

;;; ---------------------------------------------------------------------------
;;; sector_t __far* getNextSector(const line_t __far* line, sector_t __far* sec)
;;; The sector on the other side of the line, NULL for a one sided line or
;;; when both sides are sec.
;;; ---------------------------------------------------------------------------
              .public getNextSector
getNextSector:
              ldy     ##OFS_LINE_SIDENUM    ; the front sector
              jsr     .kbank sideSector
              cmp     dp:.tiny (_Dp+4)
              bne     8$                    ; not sec: the front one
              cpx     dp:.tiny (_Dp+6)
              bne     8$
              ldy     ##(OFS_LINE_SIDENUM+2) ; sec: the back one, if not sec
              lda     [.tiny _Dp],y
              cmp     ##0xffff
              beq     9$
              jsr     .kbank sideSector
              cmp     dp:.tiny (_Dp+4)
              bne     8$
              cpx     dp:.tiny (_Dp+6)
              beq     9$
8$:           rtl
9$:           lda     ##0
              tax
              rtl

;;; sideSector: X:C = the sector of side number [_Dp] + Y. _Dp stays.
sideSector:   lda     [.tiny _Dp],y
              ldx     ##SIZEOF_SIDE
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sides
              sta     .near SP_OTHER
              lda     .near (_g_sides+2)
              sta     .near (SP_OTHER+2)
              pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              lda     .near SP_OTHER
              sta     dp:.tiny _Dp
              lda     .near (SP_OTHER+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_SIDE_SECTOR+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SIDE_SECTOR
              lda     [.tiny _Dp],y
              ply
              sty     dp:.tiny _Dp
              ply
              sty     dp:.tiny (_Dp+2)
              rts

;;; ---------------------------------------------------------------------------
;;; fixed_t P_FindLowestFloorSurrounding(sector_t __far* sec)
;;; fixed_t P_FindHighestFloorSurrounding(sector_t __far* sec)
;;; fixed_t P_FindLowestCeilingSurrounding(sector_t __far* sec)
;;; The lowest floor of sec and the sectors next to it; the highest floor
;;; of the sectors next to it (-32000 at least); the lowest ceiling of the
;;; sectors next to it (32000 at most).
;;; ---------------------------------------------------------------------------
              .public P_FindLowestFloorSurrounding, P_FindHighestFloorSurrounding
              .public P_FindLowestCeilingSurrounding
P_FindLowestFloorSurrounding:
              ldy     ##OFS_SEC_FLOORHEIGHT ; floor = sec->floorheight
              lda     [.tiny _Dp],y
              sta     .near SP_T
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (SP_T+2)
              ldy     ##OFS_SEC_FLOORHEIGHT
              ldx     ##0                   ; the lower one
              bra     around
P_FindHighestFloorSurrounding:
              stz     .near SP_T            ; -32000 * FRACUNIT
              lda     ##(0x10000 - 32000)
              sta     .near (SP_T+2)
              ldy     ##OFS_SEC_FLOORHEIGHT
              ldx     ##1                   ; the higher one
              bra     around
P_FindLowestCeilingSurrounding:
              stz     .near SP_T            ; 32000 * FRACUNIT
              lda     ##32000
              sta     .near (SP_T+2)
              ldy     ##OFS_SEC_CEILINGHEIGHT
              ldx     ##0
              ;; fall into around

;;; around: SP_T = the lowest (X = 0) or highest (X = 1) of SP_T and the
;;; fixed_t at offset Y of the sectors next to the sector at _Dp[0-3].
around:       phy                           ; 5,s the offset, 3,s the kind
              phx
              lda     dp:.tiny _Dp
              sta     .near SP_SEC
              lda     dp:.tiny (_Dp+2)
              sta     .near (SP_SEC+2)
              pea     #0                    ; 1,s: i
1$:           jsr     .kbank secArg         ; for (i = 0; i < linecount; i++)
              ldy     ##OFS_SEC_LINECOUNT
              lda     1,s
              cmp     [.tiny _Dp],y
              bcs     9$
              jsr     .kbank lineOf         ; other = getNextSector(lines[i], sec)
              lda     .near SP_SEC
              sta     dp:.tiny (_Dp+4)
              lda     .near (SP_SEC+2)
              sta     dp:.tiny (_Dp+6)
              jsl     long:getNextSector
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ora     dp:.tiny (_Dp+2)
              beq     5$
              lda     5,s                   ; the value of other
              tay
              lda     3,s
              bne     3$
              lda     [.tiny _Dp],y         ; lower: it < SP_T
              cmp     .near SP_T
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     .near (SP_T+2)
              bvc     2$
              eor     ##0x8000
2$:           bpl     5$
              bra     4$
3$:           lda     .near SP_T            ; higher: SP_T < it
              cmp     [.tiny _Dp],y
              iny
              iny
              lda     .near (SP_T+2)
              sbc     [.tiny _Dp],y
              bvc     31$
              eor     ##0x8000
31$:          bpl     5$
4$:           lda     5,s                   ; SP_T = it
              tay
              lda     [.tiny _Dp],y
              sta     .near SP_T
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (SP_T+2)
5$:           lda     1,s                   ; i++
              inc     a
              sta     1,s
              bra     1$
9$:           pla
              pla
              pla
              lda     .near SP_T
              ldx     .near (SP_T+2)
              rtl

;;; secArg: _Dp[0-3] = SP_SEC.
secArg:       lda     .near SP_SEC
              sta     dp:.tiny _Dp
              lda     .near (SP_SEC+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; lineOf: _Dp[0-3] = sec->lines[i], sec at _Dp[0-3], i at 3,s (the caller's
;;; 1,s).
lineOf:       lda     3,s
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
              rts

;;; ---------------------------------------------------------------------------
;;; int16_t P_FindSectorFromLineTag(const line_t __far* line, int16_t start)
;;; The next sector after start with the tag of the line, -1 for none.
;;; ---------------------------------------------------------------------------
              .public P_FindSectorFromLineTag
P_FindSectorFromLineTag:
              inc     a                     ; i = start + 1
              sta     .near SP_I
              ldy     ##OFS_LINE_TAG
              lda     [.tiny _Dp],y
              sta     .near SP_T            ; the tag
              lda     .near SP_I            ; the sector: _g_sectors + i
              ldx     ##SIZEOF_SEC
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sectors
              sta     dp:.tiny _Dp
              lda     .near (_g_sectors+2)
              sta     dp:.tiny (_Dp+2)
              ldx     .near SP_I
1$:           cpx     .near _g_numsectors   ; i < numsectors (signed)
              bpl     9$
              ldy     ##OFS_SEC_TAG
              lda     [.tiny _Dp],y
              cmp     .near SP_T
              beq     8$
              lda     dp:.tiny _Dp          ; the next sector
              clc
              adc     ##SIZEOF_SEC
              sta     dp:.tiny _Dp
              inx
              bra     1$
8$:           txa
              rtl
9$:           lda     ##0xffff
              rtl

;;; ---------------------------------------------------------------------------
;;; boolean P_CheckTag(const line_t __far* line)
;;; A nonzero tag, or a special that needs none.
;;; ---------------------------------------------------------------------------
              .public P_CheckTag
P_CheckTag:   ldy     ##OFS_LINE_TAG
              lda     [.tiny _Dp],y
              bne     8$
              ldy     ##OFS_LINE_SPECIAL
              lda     [.tiny _Dp],y
              ldx     ##(notags_end - notags - 2)
1$:           cmp     long:notags,x
              beq     8$
              dex
              dex
              bpl     1$
              lda     ##0
              rtl
8$:           lda     ##1
              rtl

;;; ---------------------------------------------------------------------------
;;; void P_UpdateSpecials(void): the animated flats and textures, and the
;;; switches that change back.
;;; ---------------------------------------------------------------------------
              .public P_UpdateSpecials
P_UpdateSpecials:
              jsl     long:P_UpdateAnimatedFlat
              ;; the slime textures: basepic + ((leveltime >> 3) % 3)
              lda     .near _g_leveltime    ; (leveltime >> 3), 32 bits
              sta     .near SP_T
              lda     .near (_g_leveltime+2)
              ldx     ##3
1$:           cmp     ##0x8000
              ror     a
              ror     .near SP_T
              dex
              bne     1$
              clc                           ; % 3: 65536 is 1 mod 3, so the
              adc     .near SP_T            ; halves add (leveltime >= 0)
              bcc     2$
              adc     ##0                   ; (carry: + 65536, that is + 1)
2$:           jsr     .kbank mod3
              clc
              adc     .near animated_texture_basepic
              pha                           ; pic
              lda     .near texturetranslation
              sta     dp:.tiny _Dp
              lda     .near (texturetranslation+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near animated_texture_basepic
              asl     a
              tay
              pla
              sta     [.tiny _Dp],y         ; texturetranslation[basepic..+2] = pic
              iny
              iny
              sta     [.tiny _Dp],y
              iny
              iny
              sta     [.tiny _Dp],y

              ;; the switch timers
              ldx     ##.near _g_buttonlist
10$:          lda     abs:OFS_BTN_BTIMER,x
              beq     19$
#if TICSTEP > 1
              sec                           ; (the tics of the run, at least 0)
              sbc     .near ticRun
              bpl     11$
              lda     ##0
11$:
#else
              dec     a
#endif
              sta     abs:OFS_BTN_BTIMER,x
              bne     19$
              phx
              jsr     .kbank buttonDone
              plx
19$:          txa
              clc
              adc     ##SIZEOF_BTN
              tax
              cpx     ##.near (_g_buttonlist + CONST_MAXBUTTONS * SIZEOF_BTN)
              bcc     10$
              rtl

;;; buttonDone: the button at near X changes back: its texture on its side,
;;; the switch sound, and the button is cleared.
buttonDone:   lda     abs:OFS_BTN_LINE,x    ; the side of the line
              sta     dp:.tiny _Dp
              lda     abs:(OFS_BTN_LINE+2),x
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_LINE_SIDENUM    ; sidenum[0]
              lda     [.tiny _Dp],y
              phx
              ldx     ##SIZEOF_SIDE
              jsl     long:IIGS_MulLo16
              plx
              clc
              adc     .near _g_sides
              sta     dp:.tiny _Dp
              lda     .near (_g_sides+2)
              sta     dp:.tiny (_Dp+2)
              lda     abs:OFS_BTN_WHERE,x   ; top, middle or bottom
              ldy     ##OFS_SIDE_TOPTEXTURE
              cmp     ##CONST_TOP
              beq     1$
              ldy     ##OFS_SIDE_MIDTEXTURE
              cmp     ##CONST_MIDDLE
              beq     1$
              ldy     ##OFS_SIDE_BOTTOMTEXTURE
              cmp     ##CONST_BOTTOM
              bne     2$
1$:           lda     abs:OFS_BTN_BTEXTURE,x
              sta     [.tiny _Dp],y
2$:           lda     abs:OFS_BTN_SOUNDORG,x ; S_StartSound2(soundorg, sfx_swtchn)
              sta     dp:.tiny _Dp
              lda     abs:(OFS_BTN_SOUNDORG+2),x
              sta     dp:.tiny (_Dp+2)
              phx
              lda     ##CONST_SFX_SWTCHN
              jsl     long:S_StartSound2
              plx
              ldy     ##SIZEOF_BTN          ; memset(button, 0, sizeof(button_t))
              sep     #0x20
3$:           stz     abs:0,x
              inx
              dey
              bne     3$
              rep     #0x20
              rts

;;; mod3: C = C % 3 (unsigned 16 bits): C - 3 * ((C * 0xaaab) >> 17).
mod3:         sta     .near SP_I
              sta     dp:.tiny MA
              lda     ##0xaaab
              sta     dp:.tiny MB
              jsl     long:umul16
              lda     dp:.tiny (MR+2)
              lsr     a                     ; the quotient
              sta     dp:.tiny MA
              asl     a                     ; * 3
              clc
              adc     dp:.tiny MA
              eor     ##0xffff              ; C - it
              sec
              adc     .near SP_I
              rts

;;; ---------------------------------------------------------------------------
;;; void P_SpawnSpecials(void): the light thinkers of the special sectors,
;;; the count of the secrets, no active platforms, no buttons, the
;;; scrollers.
;;; ---------------------------------------------------------------------------
              .public P_SpawnSpecials
P_SpawnSpecials:
              lda     .near _g_sectors
              sta     .near SP_SEC
              lda     .near (_g_sectors+2)
              sta     .near (SP_SEC+2)
              stz     .near SP_I
1$:           lda     .near SP_I            ; for (i = 0; i < numsectors; i++)
              cmp     .near _g_numsectors
              bpl     20$
              jsr     .kbank secArg
              ldy     ##OFS_SEC_SPECIAL
              lda     [.tiny _Dp],y
              cmp     ##1                   ; 1: random off
              bne     2$
              jsl     long:P_SpawnLightFlash
              bra     9$
2$:           cmp     ##2                   ; 2: strobe fast
              bne     3$
              lda     ##FASTDARK
              ldx     ##0
              bra     15$
3$:           cmp     ##3                   ; 3: strobe slow
              bne     4$
              lda     ##SLOWDARK
              ldx     ##0
              bra     15$
4$:           cmp     ##8                   ; 8: glowing light
              bne     5$
              jsl     long:P_SpawnGlowingLight
              bra     9$
5$:           cmp     ##9                   ; 9: a secret
              bne     6$
              inc     .near _g_totalsecret
              bne     9$
              inc     .near (_g_totalsecret+2)
              bra     9$
6$:           cmp     ##12                  ; 12: sync strobe slow
              bne     7$
              lda     ##SLOWDARK
              ldx     ##1
              bra     15$
7$:           cmp     ##13                  ; 13: sync strobe fast
              bne     9$
              lda     ##FASTDARK
              ldx     ##1
15$:          stx     dp:.tiny (_Dp+4)      ; P_SpawnStrobeFlash(sector, dark, sync)
              jsl     long:P_SpawnStrobeFlash
9$:           lda     .near SP_SEC          ; the next sector
              clc
              adc     ##SIZEOF_SEC
              sta     .near SP_SEC
              inc     .near SP_I
              bra     1$

20$:          ldx     ##(CONST_MAXBUTTONS * SIZEOF_BTN - 2) ; no buttons
21$:          stz     .near _g_buttonlist,x
              dex
              dex
              bpl     21$
              ;; the scrollers: a thinker for each line of special 48
              lda     .near _g_lines
              sta     .near SP_OTHER
              lda     .near (_g_lines+2)
              sta     .near (SP_OTHER+2)
              stz     .near SP_I
22$:          lda     .near SP_I
              cmp     .near _g_numlines
              bpl     29$
              lda     .near SP_OTHER
              sta     dp:.tiny _Dp
              lda     .near (SP_OTHER+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_LINE_SPECIAL
              lda     [.tiny _Dp],y
              cmp     ##48
              bne     23$
              ldy     ##OFS_LINE_SIDENUM
              lda     [.tiny _Dp],y
              jsr     .kbank addScroller
23$:          lda     .near SP_OTHER
              clc
              adc     ##SIZEOF_LINE
              sta     .near SP_OTHER
              inc     .near SP_I
              bra     22$
29$:          rtl

;;; addScroller: Add_Scroller(C): a T_Scroll thinker for side C.
addScroller:  pha
              lda     ##SC_SIZE             ; s = Z_CallocLevSpec(sizeof *s)
              jsl     long:Z_CallocLevSpec
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##OFS_TH_FUNCTION     ; s->thinker.function = T_Scroll
              lda     ##.word0 T_Scroll
              sta     [.tiny _Dp],y
              iny
              iny
              lda     ##.word2 T_Scroll
              sta     [.tiny _Dp],y
              pla                           ; s->textureoffset = &sides[affectee].textureoffset
              ldx     ##SIZEOF_SIDE
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sides
              clc
              adc     ##OFS_SIDE_TEXTUREOFFSET
              ldy     ##SC_TEXOFS
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (_g_sides+2)
              sta     [.tiny _Dp],y
              jsl     long:P_AddThinker     ; P_AddThinker(&s->thinker)
              rts

;;; ---------------------------------------------------------------------------
;;; T_Scroll(scroll_t __far* s): (*s->textureoffset)++ (+= TICSTEP)
;;; ---------------------------------------------------------------------------
              .public T_Scroll
T_Scroll:     ldy     ##(SC_TEXOFS+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##SC_TEXOFS
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp]
#if TICSTEP > 1
              clc
              adc     .near ticRun
#else
              inc     a
#endif
              sta     [.tiny _Dp]
              rtl
