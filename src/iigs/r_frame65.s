;;; The frame of the view in 65816 assembly.
;;;
;;; R_RenderPlayerView, R_SetupFrame and the clears at the frame start and
;;; R_DrawMasked (the sprite sort, the masked mid textures, the player
;;; sprites) of r_draw.c, and R_LoadSkyPatch and R_FreeSkyPatch of
;;; r_sky.c, with the same results. R_RecalcLineFlags is in
;;; src/iigs/r_wall65.s.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"
#include "dscols.inc"
#include "lists.inc"
#include "wpage.inc"
#include "viewwin.inc"
              .extern iigs_mulT
MULT0         .equ    iigs_mulT + 510 ; T[0] of src/iigs/mul.inc
#include "mul.inc"

              .extern _Dp, _g_player, _g_sectors, _g_sides, _g_lines, _g_gametic
              .extern viewx, viewy, viewz, viewangle, viewangle16, viewsin, viewcos
              .extern extralight, fixedcolormap, fullcolormap, validcount, LT_BASE, LT_FIXED
              .extern _g_gamma
              .extern solidcol, ds_p, _s_drawsegs, floorclip, ceilingclip, viewtop
              .extern SPR_TOPINIT, SPR_TOPTEST
              .extern lastopening, openings, num_vissprite, vissprites, numnodes
              .extern curline, linedef, frontsector, backsector, skyflatnum
              .extern skypatch, skypatchnum, sprites, rw_lightlevel, rw_scalestep
              .extern maskedtexturecol, spryscale, sprtopscreen, mfloorclip, mceilingclip
              .extern screenheightarray, negonearray, texturetranslation, textureheight
              .extern R_RenderBSPNode, R_DrawSprite, R_DrawVisSprite
              .extern MA, MB, MR, umul16, BSPDP, COLW, newPage, iigs_shrcmapA, I_Error
              .extern VS_CLIP, DS_X2, wcDraw3, wdDraw
              .extern R_DrawColumnSprite, R_WallLight, R_GetTexture, R_SpriteColorMap
              .extern W_GetLumpByNum, W_TryGetLumpByNum, Z_ChangeTagToCache
              .extern finesineapprox, finecosineapprox, FixedMul, FixedReciprocal
              .extern IIGS_MulLo16, _Mul32, viewbottom, SPR_BOTINIT, SPR_BOTTEST, R_WallFrame
              .extern LT_I, SMAP, PGT, automapmode, message_on, iigs_shrcmapB
              .extern iigs_textShown, settingsFile
#if defined IIGS_PHASES
              .extern iigs_phase
#endif


;;; Existing per-level address tables, filled by P_InitBlockRows and
;;; P_InitSightTables before rendering. Reuse them without new allocation.
CORE_LN36     .equ    (MM_B3F + 0x6200)
CORE_SEC58    .equ    (MM_B3F + 0xa000)

CENTERX       .equ    (CONST_VIEWWIDTH / 2)
SHADOW        .equ    0xe0c035
PSPRITEISCALE_HI .equ (320 / CONST_VIEWWIDTH) ; FRACUNIT * SCREENWIDTH_VGA / VIEWWINDOWWIDTH
PSPRITEYSCALE_HI .equ (CONST_PROJECTIONY / 160) ; FRACUNIT * PROJECTIONY / 160
PSPRITEYFRACSTEP .equ ((0x10000 * 160 / CONST_PROJECTIONY) >> 7)
BASEXCENTER   .equ    160             ; SCREENWIDTH_VGA / 2
BASEYCENTER   .equ    100             ; SCREENHEIGHT_VGA / 2
MAXVIS        .equ    80              ; MAXVISSPRITES

;;; N = (a < b) for the fixed_t in near a and b, signed.
LT32          .macro  a, b
              lda     .near \a
              cmp     .near \b
              lda     .near (\a+2)
              sbc     .near (\b+2)
              bvc     1$
              eor     ##0x8000
1$:
              .endm

#if defined IIGS_PHASES
PHASE         .macro  n
              lda     ##\n
              sta     .near iigs_phase
              .endm
#else
PHASE         .macro  n
              .endm
#endif

              .section znear, bss
FR_ORDER:     .space  (2 * MAXVIS)    ; the sprite order: offsets in vissprites
FR_DS:        .space  2               ; the drawseg of R_DrawMasked (near)
FR_X:         .space  2               ; R_RenderMaskedSegRange: the column
FR_X2:        .space  2
FR_TEX:       .space  2               ;   the texture number
FR_WMASK:     .space  2               ;   its width mask
FR_PATCH:     .space  4               ;   its patch
FR_TMID:      .space  4               ;   texturemid
FR_T:         .space  4
FR_DCV:       .space  SIZEOF_DC       ; the column of the masked texture
FR_VIS:       .space  SIZEOF_VIS      ; R_DrawPSprite: the vissprite
FR_X1:        .space  2               ;   x1 before the clip
FR_LIGHT:     .space  2               ; R_DrawPlayerSprites: the light level
FR_N2:        .space  2               ; sortSprites: 2 * n, 2 * i, 2 * j, temp
FR_I:         .space  2
FR_J:         .space  2
FR_TEMP:      .space  2
FR_Y:         .space  2               ; higher, lower: the offset
SM_W:         .space  6               ; smul48: the sum
FR_P:         .space  6               ; texturemid * spryscale, bits 0-47:
FR_B:         .space  6               ;   sprtopscreen of each column; the
FR_TM7:       .space  2               ;   step, texturemid * rw_scalestep;
                                      ;   texturemid >> 7 (mwCols)
FR_SKIP:      .space  2               ; 1: this frame skips the weapon rows

;;; ---------------------------------------------------------------------------
;;; void R_RenderPlayerView(player_t* player)       In: _Dp[0-3].
;;; The walls, floors, ceilings and sprites become records of the column
;;; lists; R_DrawLists (src/iigs/r_list65.s) draws them at the end of the
;;; frame. The rows from viewbottom on are not drawn (the map title of the
;;; automap overlay).
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public R_RenderPlayerView
R_RenderPlayerView:
              sep     #0x20                 ; SHR shadowing on (R_DrawLists of
              lda     long:SHADOW           ;   src/iigs/r_list65.s turns it off
              and     #0xf7                 ;   after the view)
              sta     long:SHADOW
              rep     #0x20
              PHASE   2
              jsr     .kbank setupFrame
              lda     ##0                   ; R_ClearClipSegs: no solid columns
              ldx     ##(CONST_VIEWWIDTH - 2)
1$:           sta     abs:.near solidcol,x
              dex
              dex
              bpl     1$
              lda     ##.near _s_drawsegs   ; R_ClearDrawSegs
              sta     .near ds_p
              lda     ##.word2 _s_drawsegs
              sta     .near (ds_p+2)
              lda     ##0
              sta     long:dsCount
              ldy     .near viewtop         ; the top of the openings, and of
              iny                           ;   the sprite clip; + 1: the clip
              lda     .near viewbottom      ;   arrays hold the clips + 1
              inc     a                     ;   (src/iigs/segvar.inc); the
              cmp     .near screenheightarray ; bottom of the openings, of the
              beq     3$                    ;   sprite clip and of the player
              ldx     ##(2 * CONST_VIEWWIDTH - 2) ; sprites (screenheightarray)
4$:           sta     abs:.near screenheightarray,x
              dex
              dex
              bpl     4$
3$:           sep     #0x20                 ; the byte operands of R_DrawSprite
              sta     long:SPR_BOTINIT
              sta     long:SPR_BOTTEST
              xba                           ; (B: the bottom + 1)
              tya
              sta     long:SPR_TOPINIT
              sta     long:SPR_TOPTEST
              ldx     ##(2 * CONST_VIEWWIDTH - 2) ; the clip of the openings: the
5$:           sta     abs:.near ceilingclip,x ;   low bytes (their high bytes are 0)
              xba
              sta     abs:.near floorclip,x
              xba
              dex
              dex
              bpl     5$
              rep     #0x20
              jsr     .kbank weaponClipSame ; the rows under the weapon
              lda     ##.near openings      ; R_ClearOpenings
              sta     .near lastopening
              lda     ##.word2 openings
              sta     .near (lastopening+2)
              stz     .near num_vissprite   ; R_ClearSprites
              jsl     long:R_WallFrame      ; the pointers of the walk
              PHASE   3
              lda     .near numnodes        ; R_RenderBSPNode(numnodes - 1)
              dec     a
              jsl     long:R_RenderBSPNode
              jsl     long:R_FreeSkyPatch
              PHASE   4
              jsr     .kbank drawMasked
              rtl

;;; drawMasked: R_DrawMasked: the sprites back to front, the masked mid
;;; textures of the drawsegs (last first), the player sprites.
drawMasked:   jsr     .kbank sortSkip
              lda     .near num_vissprite   ; for (i = num_vissprite; --i >= 0; )
              asl     a
              tax
1$:           dex
              dex
              bmi     2$
              phx
              lda     abs:.near FR_ORDER,x  ; R_DrawSprite(vissprite_ptrs[i])
              clc
              adc     ##.near vissprites
              sta     dp:.tiny _Dp
              lda     ##.word2 vissprites
              sta     dp:.tiny (_Dp+2)
              jsl     long:R_DrawSprite
              plx
              bra     1$
2$:           lda     .near ds_p            ; for (ds = ds_p; ds-- > drawsegs; )
3$:           sec
              sbc     ##SIZEOF_DS
              cmp     ##.near _s_drawsegs
              bcc     5$
              sta     .near FR_DS
              tax
              lda     abs:OFS_DS_MASKEDTEXTURECOL,x ; a masked mid texture
              ora     abs:(OFS_DS_MASKEDTEXTURECOL+2),x
              beq     4$
              jsr     .kbank maskedSeg
4$:           lda     .near FR_DS
              bra     3$
5$:           jmp     .kbank playerSkip

;;; setupFrame: R_SetupFrame(player): the view point and angle, the extra
;;; light, the fixed colormap of the player, a new validcount.
setupFrame:   ldy     ##(OFS_PL_MO+2)       ; mo = player->mo
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_PL_MO
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              ldy     ##OFS_PL_VIEWZ        ; viewz = player->viewz
              lda     [.tiny _Dp],y
              sta     .near viewz
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (viewz+2)
              ldy     ##OFS_PL_EXTRALIGHT   ; extralight
              lda     [.tiny _Dp],y
              sta     .near extralight
              clc                           ; the light number base of the
              adc     .near _g_gamma        ;   light tables (src/iigs/r_bsp65.s)
              adc     ##16
              sta     .near LT_BASE
              ldy     ##OFS_PL_FIXEDCOLORMAP ; fixedcolormap: fullcolormap + n * 256,
              lda     [.tiny _Dp],y         ; or NULL
              beq     1$
              xba
              and     ##0xff00
              sta     .near LT_FIXED
              clc
              adc     ##.word0 fullcolormap
              sta     .near fixedcolormap
              lda     ##.word2 fullcolormap
              sta     .near (fixedcolormap+2)
              bra     2$
1$:           stz     .near fixedcolormap
              stz     .near (fixedcolormap+2)
              lda     ##0xffff
              sta     .near LT_FIXED
2$:           ldy     ##OFS_MO_X            ; viewx, viewy, viewangle
              lda     [.tiny (_Dp+4)],y
              sta     .near viewx
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sta     .near (viewx+2)
              ldy     ##OFS_MO_Y
              lda     [.tiny (_Dp+4)],y
              sta     .near viewy
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sta     .near (viewy+2)
              ldy     ##OFS_MO_ANGLE
              lda     [.tiny (_Dp+4)],y
              sta     .near viewangle
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sta     .near (viewangle+2)
              sta     .near viewangle16
              lsr     a                     ; viewsin, viewcos (angle >> 3)
              lsr     a
              lsr     a
              pha
              jsl     long:finesineapprox
              sta     .near viewsin
              stx     .near (viewsin+2)
              pla
              jsl     long:finecosineapprox
              sta     .near viewcos
              stx     .near (viewcos+2)
              inc     .near validcount
              rts

;;; sortSprites: R_SortVisSprites: FR_ORDER = the vissprites by scale, the
;;; largest first; equal scales keep their order (the insertion sort of the
;;; C code, isort). FR_I = 2 * i and FR_N2 = 2 * n (words); FR_TEMP =
;;; s[i], FR_T its scale; Y = 2 * j.
sortSprites:  lda     .near num_vissprite
              bne     1$
              rts
1$:           asl     a                     ; (16-bit stores: a SEP/REP pair
              sta     .near FR_N2           ;   costs more than the second byte)
              ldx     ##0                   ; the order of the array first
              txa
2$:           sta     abs:.near FR_ORDER,x
              clc
              adc     ##SIZEOF_VIS
              inx
              inx
              cpx     .near FR_N2
              bcc     2$
              ldx     ##2                   ; for (i = 1; i < n; i++)
3$:           cpx     .near FR_N2
              bcc     4$
              rts
4$:           ldy     abs:.near FR_ORDER,x  ; temp = s[i]
              lda     abs:.near (vissprites+OFS_VIS_SCALE+2),y
              sta     .near (FR_T+2)        ;   and its scale
              lda     abs:.near (vissprites+OFS_VIS_SCALE),y
              sta     .near FR_T
              txy                           ; j = i
              ldx     abs:.near (FR_ORDER-2),y ; s[j - 1]->scale < temp->scale:
              jsr     .kbank scaleLess      ;   on (else s[i] stays)
              bmi     5$
              tyx
              bra     9$
5$:           sty     .near FR_I
              lda     abs:.near FR_ORDER,y
              sta     .near FR_TEMP
6$:           txa                           ; s[j] = s[j - 1]
              sta     abs:.near FR_ORDER,y
              dey                           ; --j, to the start at most
              dey
              beq     8$
              ldx     abs:.near (FR_ORDER-2),y
              jsr     .kbank scaleLess
              bmi     6$
8$:           lda     .near FR_TEMP         ; s[j] = temp
              sta     abs:.near FR_ORDER,y
              ldx     .near FR_I
9$:           inx
              inx
              bra     3$

;;; scaleLess: N set if the scale of the vissprite at offset X is less than
;;; FR_T (signed).
scaleLess:    lda     abs:.near (vissprites+OFS_VIS_SCALE),x
              cmp     .near FR_T
              lda     abs:.near (vissprites+OFS_VIS_SCALE+2),x
              sbc     .near (FR_T+2)
              bvc     1$
              eor     ##0x8000
1$:           rts

;;; ---------------------------------------------------------------------------
;;; void R_RenderMaskedSegRange(const drawseg_t *ds, int16_t x1, int16_t x2)
;;;   In: _Dp[0-3] = ds (in the near bank), C = x1, _Dp[4-7] = x2.
;;; The masked mid texture of a two sided line from x1 to x2, column by
;;; column (each column only once: maskedtexturecol[x] becomes SHRT_MAX).
;;; maskedSeg: the same for the drawseg at near FR_DS, from its x1 to x2.
;;; ---------------------------------------------------------------------------
              .public R_RenderMaskedSegRange
R_RenderMaskedSegRange:
              sta     .near FR_X
              lda     dp:.tiny (_Dp+4)
              sta     .near FR_X2
              lda     dp:.tiny _Dp
              sta     .near FR_DS
              jsr     .kbank maskedRange
              rtl
maskedSeg:    ldx     .near FR_DS
              lda     abs:OFS_DS_X1,x
              sta     .near FR_X
              lda     abs:OFS_DS_X2,x
              sta     .near FR_X2
              ;; fall into maskedRange
maskedRange:  ldx     .near FR_DS
              lda     abs:OFS_DS_SCALESTEP,x ; rw_scalestep; spryscale = scale1 +
              sta     .near rw_scalestep    ;   (x1 - ds->x1) * rw_scalestep
              sta     dp:.tiny _Dp
              lda     abs:(OFS_DS_SCALESTEP+2),x
              sta     .near (rw_scalestep+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near FR_X
              sec
              sbc     abs:OFS_DS_X1,x
              beq     1$
              sta     dp:.tiny (_Dp+4)
              ldy     ##0
              cmp     ##0
              bpl     11$
              dey
11$:          sty     dp:.tiny (_Dp+6)
              jsl     long:_Mul32
              phx
              ldx     .near FR_DS
              clc
              adc     abs:OFS_DS_SCALE1,x
              sta     .near spryscale
              pla
              adc     abs:(OFS_DS_SCALE1+2),x
              sta     .near (spryscale+2)
              bra     12$
1$:           lda     abs:OFS_DS_SCALE1,x
              sta     .near spryscale
              lda     abs:(OFS_DS_SCALE1+2),x
              sta     .near (spryscale+2)
12$:          ldx     .near FR_DS
              lda     abs:OFS_DS_CURLINE,x  ; curline = ds->curline
              sta     .near curline
              sta     dp:.tiny _Dp
              lda     abs:(OFS_DS_CURLINE+2),x
              sta     .near (curline+2)
              sta     dp:.tiny (_Dp+2)
              lda     abs:OFS_DS_MASKEDTEXTURECOL,x ; maskedtexturecol
              sta     .near maskedtexturecol
              lda     abs:(OFS_DS_MASKEDTEXTURECOL+2),x
              sta     .near (maskedtexturecol+2)
              lda     abs:OFS_DS_SPRBOTTOMCLIP,x ; mfloorclip, mceilingclip
              sta     .near mfloorclip
              lda     abs:(OFS_DS_SPRBOTTOMCLIP+2),x
              sta     .near (mfloorclip+2)
              lda     abs:OFS_DS_SPRTOPCLIP,x
              sta     .near mceilingclip
              lda     abs:(OFS_DS_SPRTOPCLIP+2),x
              sta     .near (mceilingclip+2)
              ldy     ##OFS_SEG_FRONTSECTORNUM ; frontsector, backsector
              lda     [.tiny _Dp],y
              and     ##0x00ff
              asl     a                     ; existing level address table
              tax
              lda     long:CORE_SEC58,x
              bra     881$                  ; preserve all following addresses
              .space  3
881$:
              sta     .near frontsector
              lda     .near (_g_sectors+2)
              sta     .near (frontsector+2)
              ldy     ##OFS_SEG_BACKSECTORNUM
              lda     [.tiny _Dp],y
              and     ##0x00ff
              asl     a                     ; existing level address table
              tax
              lda     long:CORE_SEC58,x
              bra     882$                  ; preserve all following addresses
              .space  3
882$:
              sta     .near backsector
              lda     .near (_g_sectors+2)
              sta     .near (backsector+2)
              ldy     ##OFS_SEG_SIDENUM     ; the side
              lda     [.tiny _Dp],y
              ldx     ##SIZEOF_SIDE
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sides
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_sides+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_SIDE_ROWOFFSET  ; the row offset (for texturemid)
              lda     [.tiny (_Dp+4)],y
              sta     .near FR_T
              ldy     ##OFS_SIDE_MIDTEXTURE ; texnum = texturetranslation[midtexture]
              lda     [.tiny (_Dp+4)],y
              asl     a
              tay
              lda     .near texturetranslation
              sta     dp:.tiny (_Dp+4)
              lda     .near (texturetranslation+2)
              sta     dp:.tiny (_Dp+6)
              lda     [.tiny (_Dp+4)],y
              sta     .near FR_TEX
              lda     .near frontsector     ; rw_lightlevel = frontsector->lightlevel
              sta     dp:.tiny (_Dp+4)
              lda     .near (frontsector+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_SEC_LIGHTLEVEL
              lda     [.tiny (_Dp+4)],y
              sta     .near rw_lightlevel
              lda     .near backsector      ; _Dp[4-7] = front, _Dp[0-3] = back
              sta     dp:.tiny _Dp
              lda     .near (backsector+2)
              sta     dp:.tiny (_Dp+2)
              jsr     .kbank lineFlags      ; ML_DONTPEGBOTTOM of the line
              and     ##CONST_ML_DONTPEGBOTTOM
              beq     2$
              ldy     ##OFS_SEC_FLOORHEIGHT ; the higher floor + textureheight << 16
              jsr     .kbank higher
              lda     .near FR_TEX
              asl     a
              tay
              lda     .near textureheight
              sta     dp:.tiny _Dp
              lda     .near (textureheight+2)
              sta     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp],y
              clc
              adc     .near (FR_TMID+2)
              sta     .near (FR_TMID+2)
              bra     3$
2$:           ldy     ##OFS_SEC_CEILINGHEIGHT ; the lower ceiling
              jsr     .kbank lower
3$:           lda     .near FR_TMID         ; - viewz, + rowoffset << 16
              sec
              sbc     .near viewz
              sta     .near FR_TMID
              lda     .near (FR_TMID+2)
              sbc     .near (viewz+2)
              clc
              adc     .near FR_T
              sta     .near (FR_TMID+2)
              lda     .near FR_TMID
              sta     .near (FR_DCV+OFS_DC_TEXTUREMID)
              lda     .near (FR_TMID+2)
              sta     .near (FR_DCV+OFS_DC_TEXTUREMID+2)
              lda     .near curline         ; the colormap: the light of curline
              sta     dp:.tiny _Dp          ;   at the middle of the drawseg
              lda     .near (curline+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_SEG_ANGLE       ; (the normal angle)
              lda     [.tiny _Dp],y
              clc
              adc     ##0x4000
              tay
              ldx     .near FR_DS
              lda     .near rw_lightlevel
              jsl     long:R_WallLight
              clc
              adc     ##.word0 fullcolormap
              sta     .near (FR_DCV+OFS_DC_COLORMAP)
              lda     ##.word2 fullcolormap
              adc     ##0
              sta     .near (FR_DCV+OFS_DC_COLORMAP+2)
              lda     .near FR_TEX          ; the texture and its first patch
              jsl     long:R_GetTexture
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##OFS_TEX_WIDTHMASK
              lda     [.tiny _Dp],y
              sta     .near FR_WMASK
              ldy     ##(OFS_TEX_PATCHES+OFS_TP_PATCHNUM)
              lda     [.tiny _Dp],y
              jsl     long:W_GetLumpByNum
              sta     .near FR_PATCH
              stx     .near (FR_PATCH+2)
              lda     .near spryscale       ; sprtopscreen from FR_P, which each
              ldx     .near (spryscale+2)   ;   column steps by FR_B: the bits
              jsl     long:smul48           ;   16-47 of the exact products
              ldx     ##4                   ;   (FixedMul)
71$:          lda     .near SM_W,x
              sta     .near FR_P,x
              dex
              dex
              bpl     71$
              lda     .near rw_scalestep
              ldx     .near (rw_scalestep+2)
              jsl     long:smul48
              ldx     ##4
72$:          lda     .near SM_W,x
              sta     .near FR_B,x
              dex
              dex
              bpl     72$
              jsl     long:mwCols           ; the columns (from x1 = FR_X)
              lda     .near FR_PATCH        ; Z_ChangeTagToCache(patch)
              sta     dp:.tiny _Dp
              lda     .near (FR_PATCH+2)
              sta     dp:.tiny (_Dp+2)
              jsl     long:Z_ChangeTagToCache
              stz     .near curline         ; curline = NULL
              stz     .near (curline+2)
              rts

;;; lineFlags: C = _g_lines[curline->linenum].flags (curline at _Dp[8-11]:
;;; it is a scratch pointer here, _Dp[8-11] is saved by nothing).
lineFlags:    pei     dp:.tiny (_Dp+10)
              pei     dp:.tiny (_Dp+8)
              lda     .near (curline+2)
              sta     dp:.tiny (_Dp+10)
              lda     .near curline
              sta     dp:.tiny (_Dp+8)
              ldy     ##OFS_SEG_LINENUM
              lda     [.tiny (_Dp+8)],y
              asl     a                     ; existing level address table
              tax
              lda     long:CORE_LN36,x
              bra     883$                  ; preserve all following addresses
              .space  3
883$:
              sta     dp:.tiny (_Dp+8)
              lda     .near (_g_lines+2)
              sta     dp:.tiny (_Dp+10)
              ldy     ##OFS_LINE_FLAGS
              lda     [.tiny (_Dp+8)],y
              and     ##0x00ff
              tax
              pla
              sta     dp:.tiny (_Dp+8)
              pla
              sta     dp:.tiny (_Dp+10)
              txa
              rts

;;; higher, lower: FR_TMID = the higher (lower) of the fixed_t at offset Y
;;; of the front sector (_Dp[4-7]) and the back sector (_Dp[0-3]); the back
;;; one when they are equal, as the C code.
higher:       sty     .near FR_Y            ; front > back: front
              lda     [.tiny _Dp],y         ; (back < front)
              cmp     [.tiny (_Dp+4)],y
              iny
              iny
              lda     [.tiny _Dp],y
              sbc     [.tiny (_Dp+4)],y
              bvc     1$
              eor     ##0x8000
1$:           bmi     front
              bra     back
lower:        sty     .near FR_Y            ; front < back: front
              lda     [.tiny (_Dp+4)],y
              cmp     [.tiny _Dp],y
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sbc     [.tiny _Dp],y
              bvc     1$
              eor     ##0x8000
1$:           bmi     front
back:         ldy     .near FR_Y
              lda     [.tiny _Dp],y
              sta     .near FR_TMID
              iny
              iny
              lda     [.tiny _Dp],y
              sta     .near (FR_TMID+2)
              rts
front:        ldy     .near FR_Y
              lda     [.tiny (_Dp+4)],y
              sta     .near FR_TMID
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sta     .near (FR_TMID+2)
              rts

;;; ---------------------------------------------------------------------------
;;; weaponClip: the clip pass of the weapon (R_DrawVisSprite with VS_CLIP):
;;; floorclip of each column starts at the first row of the run of posts of
;;; the weapon that reaches the last row of the view. The weapon is drawn
;;; over those rows last in the frame, so the picture is the same without
;;; the walls, floors and ceilings there. Not for the shadow weapon, which
;;; darkens the rows under it.
;;; ---------------------------------------------------------------------------
weaponClip:   jsr     .kbank dvInit         ; (before the walls: they use them)
              lda     ##1
              sta     .near VS_CLIP
              jsr     .kbank psSetup
              ldx     ##.near (_g_player+OFS_PL_PSPRITES) ; the weapon
              jsr     .kbank pspSprite
              stz     .near VS_CLIP
              rts

;;; ---------------------------------------------------------------------------
;;; playerSprites: R_DrawPlayerSprites: the weapon and its flash, lit as the
;;; sector of the player, clipped to the view only.
;;; ---------------------------------------------------------------------------
playerSprites:
              jsr     .kbank psSetup
              ldx     ##.near (_g_player+OFS_PL_PSPRITES) ; the two psprites
              jsr     .kbank pspDraw0
              ldx     ##.near (_g_player+OFS_PL_PSPRITES+SIZEOF_PSP)
              brl     pspSprite

;;; psSetup: FR_LIGHT = the light of the sector of the player; mfloorclip,
;;; mceilingclip = the view only.
psSetup:      lda     .near (_g_player+OFS_PL_MO) ; the light of the sector
              sta     dp:.tiny _Dp
              lda     .near (_g_player+OFS_PL_MO+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_MO_SUBSECTOR+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_MO_SUBSECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##(OFS_SUB_SECTOR+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_SUB_SECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##OFS_SEC_LIGHTLEVEL
              lda     [.tiny _Dp],y
              sta     .near FR_LIGHT
              lda     ##.near screenheightarray ; mfloorclip, mceilingclip
              sta     .near mfloorclip
              lda     ##.word2 screenheightarray
              sta     .near (mfloorclip+2)
              lda     ##.near negonearray
              sta     .near mceilingclip
              lda     ##.word2 negonearray
              sta     .near (mceilingclip+2)
              rts

;;; pspSprite: R_DrawPSprite(the psprite at near X, FR_LIGHT) if it has a
;;; state.
pspSprite:    lda     abs:OFS_PSP_STATE,x
              ora     abs:(OFS_PSP_STATE+2),x
              bne     1$
              rts
1$:           phx                           ; 1,s = psp
              lda     abs:OFS_PSP_STATE,x   ; (states are in the near bank)
              tay
              lda     abs:OFS_ST_FRAME,y    ; the frame (FF_FULLBRIGHT, the number)
              pha                           ; 1,s = frame, 3,s = psp
              lda     abs:OFS_ST_SPRITE,y   ; sprframe = &sprites[sprite].spriteframes[frame]
              asl     a
              asl     a
              tay
              lda     .near sprites
              sta     dp:.tiny _Dp
              lda     .near (sprites+2)
              sta     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp],y
              tax
              iny
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+2)
              stx     dp:.tiny _Dp
              lda     1,s                   ; * SIZEOF_SF (19): the FF_FULLBRIGHT
              and     ##0x7fff              ;   bit of the three adds goes with
              asl     a                     ;   the last and
              asl     a
              asl     a
              asl     a
              clc
              adc     1,s
              clc
              adc     1,s
              clc
              adc     1,s
              and     ##0x7fff
              tay                           ; lump = sprframe->lump[0]
              lda     [.tiny _Dp],y
              sta     .near (FR_VIS+OFS_VIS_LUMP)
              jsl     long:W_GetLumpByNum   ; the patch, also in gy for
              sta     dp:.tiny _Dp          ;   R_DrawVisSprite
              stx     dp:.tiny (_Dp+2)
              sta     .near (FR_VIS+OFS_VIS_GY)
              stx     .near (FR_VIS+OFS_VIS_GY+2)
              lda     3,s                   ; tx = psp->sx - BASEXCENTER - leftoffset
              tax
              lda     abs:OFS_PSP_SX,x
              sec
              sbc     ##BASEXCENTER
              ldy     ##OFS_PATCH_LEFTOFFSET
              sec
              sbc     [.tiny _Dp],y
              pha                           ; 1,s = tx
              cmp     ##0x8000              ; x1 = CENTERX + (tx * PSPRITESCALE >> 16)
              ror     a                     ; (PSPRITESCALE = 0.5)
              clc
              adc     ##CENTERX
              sta     .near FR_X1
              pla                           ; tx += width
              ldy     ##OFS_PATCH_WIDTH
              clc
              adc     [.tiny _Dp],y
              cmp     ##0x8000              ; x2 = CENTERX + (tx * PSPRITESCALE >> 16) - 1
              ror     a
              clc
              adc     ##(CENTERX - 1)
              sta     .near (FR_VIS+OFS_VIS_X2)
              bmi     2$                    ; x2 < 0 || x1 > VIEWWINDOWWIDTH: off
              lda     .near FR_X1           ; the side
              sec
              sbc     ##(CONST_VIEWWIDTH + 1)
              bvc     11$
              eor     ##0x8000
11$:          bmi     3$
2$:           pla                           ; (Z_ChangeTagToCache leaves the
              pla                           ;   lumps of the WAD image alone)
              rts
3$:           lda     3,s                   ; texturemid = BASEYCENTER << 16 -
              tax                           ;   (psp->sy - topoffset << 16)
              lda     ##0
              sec
              sbc     abs:OFS_PSP_SY,x
              sta     .near (FR_VIS+OFS_VIS_TEXTUREMID)
              lda     ##BASEYCENTER
              sbc     abs:(OFS_PSP_SY+2),x
              ldy     ##OFS_PATCH_TOPOFFSET
              clc
              adc     [.tiny _Dp],y
              sta     .near (FR_VIS+OFS_VIS_TEXTUREMID+2)
              lda     .near FR_X1           ; x1 = max(x1, 0)
              bpl     4$
              lda     ##0
4$:           sta     .near (FR_VIS+OFS_VIS_X1)
              lda     .near (FR_VIS+OFS_VIS_X2) ; x2 = min(x2, VIEWWINDOWWIDTH - 1)
              cmp     ##CONST_VIEWWIDTH
              bmi     5$
              lda     ##(CONST_VIEWWIDTH - 1)
              sta     .near (FR_VIS+OFS_VIS_X2)
5$:           stz     .near (FR_VIS+OFS_VIS_SCALE) ; scale, fracstep, xiscale
              lda     ##PSPRITEYSCALE_HI
              sta     .near (FR_VIS+OFS_VIS_SCALE+2)
              lda     ##PSPRITEYFRACSTEP
              sta     .near (FR_VIS+OFS_VIS_FRACSTEP)
              stz     .near (FR_VIS+OFS_VIS_XISCALE)
              lda     ##PSPRITEISCALE_HI
              sta     .near (FR_VIS+OFS_VIS_XISCALE+2)
              stz     .near (FR_VIS+OFS_VIS_STARTFRAC) ; startfrac = xiscale * (x1' - x1)
              lda     .near (FR_VIS+OFS_VIS_X1)
              sec
              sbc     .near FR_X1
              beq     6$                    ; (xiscale is a whole number here)
              ldx     ##PSPRITEISCALE_HI
              jsl     long:IIGS_MulLo16
6$:           sta     .near (FR_VIS+OFS_VIS_STARTFRAC+2)
              ;; the colormap: shadow (invisible), fixed, full bright or the light
              lda     .near (_g_player+OFS_PL_POWERS+2*CONST_PW_INVISIBILITY)
              cmp     ##(4 * 32 + 1)
              bpl     7$
              and     ##8
              beq     8$
7$:           lda     ##0                   ; NULL: the shadow drawer
              tax
              bra     10$
8$:           lda     .near fixedcolormap
              ldx     .near (fixedcolormap+2)
              bne     10$
              cmp     ##0
              bne     10$
              lda     1,s                   ; FF_FULLBRIGHT
              bpl     9$
              lda     ##.word0 fullcolormap
              ldx     ##.word2 fullcolormap
              bra     10$
9$:           ldx     ##0xffff              ; startmap - 23, as Doom's
              lda     .near FR_LIGHT        ;   spritelights[MAXLIGHTSCALE-1]
              jsl     long:R_SpriteColorMap
10$:          sta     .near (FR_VIS+OFS_VIS_COLORMAP)
              stx     .near (FR_VIS+OFS_VIS_COLORMAP+2)
              pla
              pla
              lda     .near VS_CLIP         ; the clip pass: not the shadow
              beq     pspDraw               ;   weapon
              lda     .near (FR_VIS+OFS_VIS_COLORMAP)
              ora     .near (FR_VIS+OFS_VIS_COLORMAP+2)
              bne     pspDraw
              rts
pspDraw:      lda     ##.near FR_VIS        ; R_DrawVisSprite(vis) (wcDraw3: the
              sta     dp:.tiny _Dp          ;   clip pass from the profile of
              lda     ##.word2 FR_VIS       ;   the patch, src/iigs/r_sprite65.s)
              sta     dp:.tiny (_Dp+2)
              jsl     long:wcDraw3
              rts

;;; ---------------------------------------------------------------------------
;;; void R_LoadSkyPatch(void), void R_FreeSkyPatch(void)
;;; The sky patch of the level for the frame (NULL: not there).
;;; ---------------------------------------------------------------------------
              .public R_LoadSkyPatch, R_FreeSkyPatch
R_LoadSkyPatch:
              lda     .near skypatchnum
              jsl     long:W_TryGetLumpByNum
              sta     .near skypatch
              stx     .near (skypatch+2)
              rtl
R_FreeSkyPatch:
              lda     .near skypatch
              ora     .near (skypatch+2)
              beq     1$
              lda     .near skypatch
              sta     dp:.tiny _Dp
              lda     .near (skypatch+2)
              sta     dp:.tiny (_Dp+2)
              jsl     long:Z_ChangeTagToCache
              stz     .near skypatch
              stz     .near (skypatch+2)
1$:           rtl

;;; ---------------------------------------------------------------------------
;;; The weapon skip. When the view of the frame before shows (W_FSW) and its
;;; weapon is the same as this one (WPREV of src/iigs/lists.inc), the run
;;; of weapon posts at the view bottom still shows on the screen: floorclip
;;; keeps the walls, floors and ceilings out of its rows (weaponClip),
;;; wclipSprite the sprites, and the weapon draws only its posts above
;;; them (mfloorclip = WCLIP). Not with a flash (its rows change), the
;;; automap overlay (its lines cross the rows) or the shadow weapon.
;;; ---------------------------------------------------------------------------
;;; weaponClipSame: weaponClip, then FR_SKIP (1: this frame skips the rows),
;;; WPREV = this weapon (or none), WCLIP at the first frame that skips, and
;;; W_WSK = FR_SKIP.
weaponClipSame:
              jsr     .kbank weaponClip
              lda     .near FR_SKIP         ; 1,s: the frame before skipped,
              pha                           ;   so WCLIP holds this weapon
              stz     .near FR_SKIP
              lda     .near (_g_player+OFS_PL_PSPRITES+OFS_PSP_STATE)
              ora     .near (_g_player+OFS_PL_PSPRITES+OFS_PSP_STATE+2)
              beq     8$                    ; no weapon
              lda     .near (_g_player+OFS_PL_PSPRITES+SIZEOF_PSP+OFS_PSP_STATE)
              ora     .near (_g_player+OFS_PL_PSPRITES+SIZEOF_PSP+OFS_PSP_STATE+2)
              bne     8$                    ; a flash
              lda     .near automapmode     ; the automap overlay (also on
              and     ##3                   ;   the half view, where the view
              cmp     ##3                   ;   keeps all its rows): AM_ACTIVE
              beq     8$                    ;   | AM_OVERLAY of am_map65
              lda     .near (FR_VIS+OFS_VIS_COLORMAP)
              ora     .near (FR_VIS+OFS_VIS_COLORMAP+2)
              beq     8$                    ; the shadow weapon
              lda     long:(WPAGE+W_FSW)    ; Y = 1: the view of the frame
              and     ##0x00ff              ;   before shows
              tay
              ldx     ##(SIZEOF_VIS - 2)    ; WPREV = FR_VIS; Y = 0 when they
1$:           lda     abs:.near FR_VIS,x    ;   are not the same
              cmp     long:WPREV,x
              beq     2$
              ldy     ##0
              sta     long:WPREV,x
2$:           dex
              dex
              bpl     1$
              sty     .near FR_SKIP
              tya
              beq     9$
              pla                           ; the first frame that skips:
              bne     7$                    ;   WCLIP = floorclip
              ldx     ##(2 * CONST_VIEWWIDTH - 2)
              sep     #0x20
3$:           lda     abs:.near floorclip,x
              sta     long:WCLIP,x
              dex
              dex
              bpl     3$
              rep     #0x20
7$:           lda     .near FR_SKIP
              sta     long:(WPAGE+W_WSK)
              rts
8$:           lda     ##0xffff              ; WPREV: none
              sta     long:(WPREV+OFS_VIS_LUMP)
9$:           pla
              lda     .near FR_SKIP
              sta     long:(WPAGE+W_WSK)
              rts

;;; playerSkip: playerSprites, or in a frame that skips the weapon rows only
;;; the weapon posts above them (mfloorclip = WCLIP; there is no flash).
playerSkip:   lda     .near FR_SKIP
              bne     1$
              brl     playerSprites
1$:           lda     ##0                   ; (the sprites are done)
              sta     long:(WPAGE+W_WSK)
              jsr     .kbank psSetup
              lda     ##(WCLIP & 0xffff)
              sta     .near mfloorclip
              lda     ##(WCLIP >> 16)
              sta     .near (mfloorclip+2)
              ldx     ##.near (_g_player+OFS_PL_PSPRITES)
              brl     pspDraw0

;;; wclipSprite: in a frame that skips the weapon rows, the sprite of
;;; R_DrawVisSprite ends above them: V_FCP = WTMP, min(mfloorclip, WCLIP)
;;; for the columns W_X2 / 2 .. DS_X2 + 1 (visCol can draw one column past
;;; x2; floorclip stays as it is, as the sprites after it read it there).
;;; D = WPAGE; C, X and Y change.
              .public wclipSprite
wclipSprite:  lda     long:DS_X2
              cmp     ##(CONST_VIEWWIDTH - 1)
              bcs     1$
              inc     a
1$:           inc     a
              asl     a
              sta     dp:V_TEND
              ldy     dp:W_X2
              sep     #0x20
2$:           tyx
              lda     long:WCLIP,x
              cmp     [V_FCP],y
              bcc     3$
              lda     [V_FCP],y
3$:           sta     long:WTMP,x
              iny
              iny
              cpy     dp:V_TEND
              bcc     2$
              rep     #0x20
              lda     ##(WTMP & 0xffff)
              sta     dp:V_FCP
              lda     ##(WTMP >> 16)
              sta     dp:(V_FCP+2)
              rtl

;;; sortSkip: sortSprites. A shadow sprite reads the rows next to its own,
;;; so a frame with one draws the weapon again (no sprite ends above the
;;; weapon rows).
sortSkip:     jsr     .kbank dvInit         ; (after the walls)
              jsr     .kbank sortSprites
              lda     .near FR_SKIP
              beq     9$
              ldy     .near num_vissprite
              beq     9$
              ldx     ##.near vissprites
1$:           lda     abs:OFS_VIS_COLORMAP,x
              ora     abs:(OFS_VIS_COLORMAP+2),x
              beq     5$
              txa
              clc
              adc     ##SIZEOF_VIS
              tax
              dey
              bne     1$
9$:           rts
5$:           stz     .near FR_SKIP
              lda     ##0
              sta     long:(WPAGE+W_WSK)
              rts

;;; dvInit: the bytes of the sprite page (src/iigs/wpage.inc) that
;;; R_DrawVisSprite reads and no sprite changes, but the wall loop does: the
;;; bank of the T pointers, the zero high bytes of the byte variables.
dvInit:       sep     #0x20
              lda     #.byte2 iigs_mulT
              sta     long:(WPAGE+V_QP+2)
              sta     long:(WPAGE+V_QM+2)
              sta     long:(WPAGE+V_QP2+2)
              sta     long:(WPAGE+V_QM2+2)
              lda     #0
              sta     long:(WPAGE+V_TD+1)
              sta     long:(WPAGE+V_LEN+1)
              sta     long:(WPAGE+V_HI+1)
              sta     long:(WPAGE+V_LO+1)
              sta     long:(WPAGE+V_YL+1)
              rep     #0x20
              rts

;;; pspDraw0: pspSprite for the weapon (X: psprite 0). The clip pass of this
;;; frame made its vissprite in FR_VIS from the same state and light
;;; (MM_WPOK of wcDraw3, src/iigs/r_sprite65.s): only its draw is left
;;; (wdDraw: its records from the profile of its patch).
pspDraw0:     lda     long:MM_WPOK
              cmp     ##0x5aa5
              beq     1$
              brl     pspSprite
1$:           lda     ##.near FR_VIS
              sta     dp:.tiny _Dp
              lda     ##.word2 FR_VIS
              sta     dp:.tiny (_Dp+2)
              jsl     long:wdDraw
              rts

;;; The old size of this section (0x89d bytes), so that the other sections
;;; of the far code keep their cache slots.
              .space  (0x89d - (. - R_RenderPlayerView))

;;; ---------------------------------------------------------------------------
;;; smul48: SM_W[0-5] = bits 0-47 of FR_TMID * X:C (signed 32-bit values:
;;; the unsigned product, less X:C << 32 when FR_TMID < 0 and FR_TMID << 32
;;; when X:C < 0). maskedRange, once for each range.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
smul48:       sta     .near FR_T            ; (b low; FR_T+2 = b high below)
              stx     .near (FR_T+2)
              pei     dp:.tiny MA
              pei     dp:.tiny MB
              pei     dp:.tiny MR
              pei     dp:.tiny (MR+2)
              sta     dp:.tiny MB           ; AL * BL
              lda     .near FR_TMID
              sta     dp:.tiny MA
              jsl     long:umul16
              lda     dp:.tiny MR
              sta     .near SM_W
              lda     dp:.tiny (MR+2)
              sta     .near (SM_W+2)
              stz     .near (SM_W+4)
              lda     .near (FR_TMID+2)     ; AH * BL
              sta     dp:.tiny MA
              jsl     long:umul16
              jsr     .kbank smAdd16
              lda     .near FR_TMID         ; AL * BH
              sta     dp:.tiny MA
              lda     .near (FR_T+2)
              sta     dp:.tiny MB
              jsl     long:umul16
              jsr     .kbank smAdd16
              lda     .near (FR_TMID+2)     ; AH * BH, low 16 bits at 32
              sta     dp:.tiny MA
              jsl     long:umul16
              lda     .near (SM_W+4)
              clc
              adc     dp:.tiny MR
              ldx     .near (FR_TMID+2)     ; the sign corrections
              bpl     1$
              sec
              sbc     .near FR_T
1$:           ldx     .near (FR_T+2)
              bpl     2$
              sec
              sbc     .near FR_TMID
2$:           sta     .near (SM_W+4)
              pla
              sta     dp:.tiny (MR+2)
              pla
              sta     dp:.tiny MR
              pla
              sta     dp:.tiny MB
              pla
              sta     dp:.tiny MA
              rtl

;;; smAdd16: SM_W[2-5] += MR (a product at bit 16).
smAdd16:      lda     .near (SM_W+2)
              clc
              adc     dp:.tiny MR
              sta     .near (SM_W+2)
              lda     .near (SM_W+4)
              adc     dp:.tiny (MR+2)
              sta     .near (SM_W+4)
              rts


;;; ---------------------------------------------------------------------------
;;; mwCols: the columns FR_X .. FR_X2 of the masked wall of maskedRange, with
;;; spryscale, FR_P and FR_B set: the posts of each column become K_TEX
;;; records, the same records as R_DrawMaskedColumn (src/iigs/r_sprite65.s)
;;; makes. For a post edge b (topdelta, topdelta + length), H(b) =
;;; hi16(sprtopscreen + 0xFFFF + spryscale * b) comes from 3 products of
;;; the quarter squares (mul.inc) with the bytes s0, s1, s2 of spryscale
;;; (byte 3 is 0: R_ScaleFromGlobalAngle gives at most 64.0): yl =
;;; H(topdelta), yh + 1 = H(topdelta + length). Section maskcode (its own
;;; cache slots, src/iigs/iigs.scm). DBR = the near bank (the bank of T).
;;; The direct page bytes of the old column code (BSPDP of
;;; src/iigs/r_sprite65.s, below DS_SPR, which R_DrawSprite keeps) and _Dp.
;;; ---------------------------------------------------------------------------
MW_COL        .equ    BSPDP           ; the post (a long pointer)
MW_QA0        .equ    BSPDP+4         ; &T[s0], &T[-s0], &T[s1], &T[-s1],
MW_QB0        .equ    BSPDP+6         ;   &T[s2], &T[-s2] (the bank of T is
MW_QA1        .equ    BSPDP+8         ;   the data bank)
MW_QB1        .equ    BSPDP+10
MW_QA2        .equ    BSPDP+12
MW_QB2        .equ    BSPDP+14
MW_PF0        .equ    BSPDP+16        ; &T[f0], &T[-f0], &T[f1], &T[-f1]: the
MW_MF0        .equ    BSPDP+18        ;   bytes of the step
MW_PF1        .equ    BSPDP+20
MW_MF1        .equ    BSPDP+22
MW_CLL        .equ    BSPDP+24        ; sprtopscreen + 0xFFFF: bits 0-7 and
MW_CLH        .equ    BSPDP+26        ;   8-15 (words with a high byte of 0),
MW_CH         .equ    BSPDP+28        ;   bits 16-31
MW_K          .equ    BSPDP+30        ; the texture position of row -1 (lo16)
MW_CC1        .equ    BSPDP+32        ; the first row that can show
MW_FCL        .equ    BSPDP+34        ; the row after the last one
MW_YL         .equ    BSPDP+36        ; the rows of the post: the first, the
MW_END        .equ    BSPDP+38        ;   row after the last
MW_LT         .equ    BSPDP+40        ; topdelta, length
MW_X2         .equ    BSPDP+42        ; 2 * the column
MW_MTC        .equ    BSPDP+44        ; maskedtexturecol, mfloorclip,
MW_FCP        .equ    BSPDP+47        ;   mceilingclip (long pointers)
MW_CCP        .equ    BSPDP+50
MW_LVF        .equ    BSPDP+53        ; startmap + 24 when each column takes its
                                      ;   own light (a byte), 0: MW_CMP for all
MW_S2         .equ    BSPDP+54        ; the step >> 1 of the records: SF, SI
MW_CMP        .equ    BSPDP+56        ; the colormap page of the records
MW_CONT       .equ    BSPDP+57        ; bit 7: the post before in the column made
                                      ;   the last record of its list (K_TEXC)
MW_STEP       .equ    _Dp+4           ; the step
FSTEP_TABLE   .equ    MM_FSTEP        ; the steps of the scales below 1.0
                                      ;   (IIGS_InitFstep of src/iigs/m_recip65.s)

;;; MWROW01: C = H(b) - s2 * b for Y = 2b (b <= 255); mwPost adds s2 * b
;;; after it (mwS2a, mwS2b: a bra over that for s2 = 0, see mwCol). The sum
;;; of the low 16 bits, CLL + s0 * b + (CLH + s1 * b) << 8, carries z >> 8
;;; into the high word, with z = ((CLL + s0 * b) >> 8) + CLH + s1 * b <=
;;; 65535.
MWROW01       .macro
              lda     (.tiny MW_QA0),y      ; s0 * b
              sec
              sbc     (.tiny MW_QB0),y
              clc                           ; + CLL (<= 65280: no carry)
              adc     dp:.tiny MW_CLL
              xba                           ; >> 8, + CLH (carry clear)
              and     ##0x00ff
              adc     dp:.tiny MW_CLH
              adc     (.tiny MW_QA1),y      ; + s1 * b (carry clear: the sum
              sec                           ;   is at most 510)
              sbc     (.tiny MW_QB1),y
              xba                           ; z >> 8
              and     ##0x00ff
              clc
              adc     dp:.tiny MW_CH
              .endm

;;; QSETC qp, qm: QSET (src/iigs/mul.inc) for C = 2v, but no stores when
;;; qp already points at T[v] (the byte of the column before; mwCols makes
;;; the qp odd first: never T[v]).
QSETC         .macro  qp, qm
              tax
              clc
              adc     ##.word0 MULT0
              cmp     dp:\qp
              beq     1$
              sta     dp:\qp
              txa
              eor     ##0xffff
              sec
              adc     ##.word0 MULT0
              sta     dp:\qm
1$:
              .endm

;;; MDLIGHT: C = d = min(23, spryscale >> 13), the distance steps of the
;;; light of a column, from C = spryscale >> 8 (bits 8..23): DLIGHT of
;;; src/iigs/r_seg65.s (the walls). 16-bit A.
MDLIGHT       .macro
              cmp     ##(24 << 5)
              bcc     1$
              lda     ##(23 << 5)
1$:           asl     a
              asl     a
              asl     a
              xba
              and     ##0x00ff
              .endm

;;; CVSETB first, end: CVSET of lists.inc when B holds the high byte of Y
;;; (the page of the record, from the COLW loads before it): TYA with 8-bit
;;; A leaves B, so no REP/SEP pair (each costs a slow cycle).
CVSETB        .macro  first, end
              lda     long:(CV_ROW+1),x     ; the rows of the range (255:
              sec                           ;   none can come)
              sbc     long:CV_ROW,x
              clc                           ; + first >= end: not more rows
              adc     \first
              bcs     9$
              cmp     \end
              bcs     9$
              lda     \first
              sta     long:CV_ROW,x
              tya
              sta     long:CV_REC,x
              xba
              sta     long:(CV_REC+1),x
              lda     \end
              sta     long:(CV_ROW+1),x
9$:
              .endm

              .section maskcode, text
              .public mwCols, mwNextCol, FR_X, FR_P, FR_B ; (the half view: hvPatch
                                      ;   and mwHalf of src/iigs/r_thing65.s)
mwCols:       lda     .near maskedtexturecol ; the long pointers of the range
              sta     dp:.tiny MW_MTC
              lda     .near (maskedtexturecol+1)
              sta     dp:.tiny (MW_MTC+1)
              lda     .near mfloorclip
              sta     dp:.tiny MW_FCP
              lda     .near (mfloorclip+1)
              sta     dp:.tiny (MW_FCP+1)
              lda     .near mceilingclip
              sta     dp:.tiny MW_CCP
              lda     .near (mceilingclip+1)
              sta     dp:.tiny (MW_CCP+1)
              lda     .near FR_PATCH        ; the patch; the posts are in its
              sta     dp:.tiny _Dp          ;   bank
              lda     .near (FR_PATCH+1)
              sta     dp:.tiny (_Dp+1)
              sta     dp:.tiny (MW_COL+1)
              stz     dp:.tiny MW_CLL       ; (the high bytes stay 0)
              stz     dp:.tiny MW_CLH
              stz     dp:.tiny MW_YL
              stz     dp:.tiny MW_END
              lda     ##1                   ; no T pointers yet (QSETC)
              sta     dp:.tiny MW_PF0
              sta     dp:.tiny MW_PF1
              sta     dp:.tiny MW_QA0
              sta     dp:.tiny MW_QA1
              sta     dp:.tiny MW_QA2
              lda     .near (FR_DCV+OFS_DC_COLORMAP) ; the page of the SHR
              sec                           ;   colormap (as fastSetup of
              sbc     ##.word0 fullcolormap ;   src/iigs/r_sprite65.s)
              clc
              adc     ##.word0 iigs_shrcmapA
              xba
              sep     #0x20
              sta     dp:.tiny MW_CMP
              stz     dp:.tiny MW_LVF
              rep     #0x20
              ;; the light of the columns, as the walls (R_RenderSegLoop of
              ;; src/iigs/r_seg65.s, Doom's walllights[spryscale >> 12]):
              ;; PGT[startmap + 24 - d], d = min(23, spryscale >> 13) of each
              ;; column; the same d at both ends of the drawseg: one page for
              ;; all; a fixed colormap keeps MW_CMP
              lda     .near LT_FIXED
              bpl     29$
              ldx     .near FR_DS
              lda     abs:(OFS_DS_SCALE1+1),x
              MDLIGHT
              sta     dp:.tiny MW_LT        ; (a temp here)
              lda     abs:(OFS_DS_SCALE2+1),x
              MDLIGHT
              tay                           ; Y = d at scale2
              lda     .near LT_I            ; startmap + 24 (R_WallLight of the
              asl     a                     ;   drawseg, maskedRange)
              tax
              lda     long:SMAP,x
              cpy     dp:.tiny MW_LT
              beq     28$
              sep     #0x20                 ; two lights: mwCol lights each
              sta     dp:.tiny MW_LVF       ;   column
              rep     #0x20
              bra     29$
28$:          sty     dp:.tiny MW_LT        ; one light: MW_CMP = PGT[startmap
              sec                           ;   + 24 - d]
              sbc     dp:.tiny MW_LT
              tax
              sep     #0x20
              lda     long:PGT,x
              sta     dp:.tiny MW_CMP
              rep     #0x20
29$:          lda     .near FR_TMID         ; texturemid >> 7 (lo16)
              xba
              asl     a
              lda     .near (FR_TMID+1)
              rol     a
              sta     .near FR_TM7

mwCol:        lda     .near FR_X            ; x <= x2
              cmp     .near FR_X2
              beq     1$
              bmi     1$
              rtl
1$:           asl     a
              sta     dp:.tiny MW_X2
              tay
              lda     [.tiny MW_MTC],y      ; xc = maskedtexturecol[x]
              cmp     ##0x7fff              ; SHRT_MAX: drawn already
              bne     2$
              brl     mwNextCol
2$:           and     .near FR_WMASK
              tax                           ; X = xc
              lda     ##0x7fff              ; drawn
              sta     [.tiny MW_MTC],y
              lda     [.tiny MW_CCP],y      ; the rows that can show: from
              sta     dp:.tiny MW_CC1       ;   ceilingclip + 1 to floorclip - 1
              lda     [.tiny MW_FCP],y      ;   (the arrays hold the clips + 1)
              dec     a
              sta     dp:.tiny MW_FCL
              bmi     3$                    ; none: no post shows
              cmp     dp:.tiny MW_CC1
              beq     3$
              bcs     4$
3$:           brl     mwNextCol
4$:           txa                           ; the posts: patch + columnofs[xc]
              asl     a
              asl     a
              clc
              adc     ##OFS_PATCH_COLUMNOFS
              tay
              lda     [.tiny _Dp],y         ; (the low word of columnofs)
              clc
              adc     dp:.tiny _Dp
              sta     dp:.tiny MW_COL
              lda     ##0                   ; sprtopscreen = CENTERY * FRACUNIT -
              sec                           ;   FixedMul(texturemid, spryscale)
              sbc     .near (FR_P+2)        ;   (FR_P >> 16); + 0xFFFF
              tax
              lda     ##CONST_CENTERY
              sbc     .near (FR_P+4)
              cpx     ##1                   ; (the carry of the low word)
              adc     ##0
              sta     dp:.tiny MW_CH
              dex
              txa
              sep     #0x20
              sta     dp:.tiny MW_CLL
              xba
              sta     dp:.tiny MW_CLH
              stz     dp:.tiny MW_CONT      ; (the first post of a column: K_TEX)
              lda     dp:.tiny MW_LVF       ; the light of this column (mwCols):
              rep     #0x20                 ;   MW_CMP = PGT[startmap + 24 - d]
              beq     43$
              lda     .near (spryscale+1)
              MDLIGHT
              sep     #0x20                 ; (B = 0: X = S - d)
              eor     #0xff
              sec
              adc     dp:.tiny MW_LVF
              tax
              lda     long:PGT,x
              sta     dp:.tiny MW_CMP
              rep     #0x20
43$:
              lda     .near (spryscale+2)   ; the step: FSTEP_TABLE[scale] when
              bne     5$                    ;   the high word is 0 (as texCol of
              lda     .near spryscale       ;   src/iigs/r_seg65.s), else
              asl     a                     ;   FixedReciprocal(spryscale) >>
              tax                           ;   COLEXTRABITS
              bcs     41$
              lda     long:FSTEP_TABLE,x
              bra     6$
41$:          lda     long:(FSTEP_TABLE+0x10000),x
              bra     6$
5$:           lda     .near spryscale
              ldx     .near (spryscale+2)
              jsl     long:FixedReciprocal
              asl     a                     ; (X:C >> 7: the middle word of X:C
              xba                           ;   << 1)
              tay
              txa
              rol     a
              sep     #0x20
              xba
              tya
              rep     #0x20
6$:           sta     dp:.tiny MW_STEP
              lsr     a
              sta     dp:.tiny MW_S2
              lda     dp:.tiny MW_STEP      ; the bytes of the step
              and     ##0x00ff
              asl     a
              QSETC   .tiny MW_PF0, .tiny MW_MF0
              lda     dp:.tiny (MW_STEP+1)
              and     ##0x00ff
              asl     a
              QSETC   .tiny MW_PF1, .tiny MW_MF1
              ldy     ##(2 * CONST_CENTERY) ; K = texturemid >> 7 - (CENTERY + 1)
              lda     (.tiny MW_PF1),y      ;   * the step (lo16)
              sec
              sbc     (.tiny MW_MF1),y
              xba
              and     ##0xff00
              clc
              adc     (.tiny MW_PF0),y
              sec
              sbc     (.tiny MW_MF0),y
              clc
              adc     dp:.tiny MW_STEP
              eor     ##0xffff
              sec
              adc     .near FR_TM7
              sta     dp:.tiny MW_K
              lda     .near spryscale       ; the bytes of spryscale
              and     ##0x00ff
              asl     a
              QSETC   .tiny MW_QA0, .tiny MW_QB0
              lda     .near (spryscale+1)
              and     ##0x00ff
              asl     a
              QSETC   .tiny MW_QA1, .tiny MW_QB1
              lda     .near (spryscale+2)
              and     ##0x00ff
              asl     a
              tax                           ; QSETC MW_QA2, MW_QB2; a new s2
              clc                           ;   also sets the s2 products of
              adc     ##.word0 MULT0        ;   mwPost: a bra over them for s2
              cmp     dp:.tiny MW_QA2       ;   = 0 (0x80, 4), else clc and
              beq     mwPost                ;   the adc opcode (0x18, 0x71)
              sta     dp:.tiny MW_QA2
              txa
              eor     ##0xffff
              sec
              adc     ##.word0 MULT0
              sta     dp:.tiny MW_QB2
              ldy     ##0x0480
              txa
              beq     9$
              ldy     ##0x7118
9$:           tya
              sta     long:mwS2a
              sta     long:mwS2b

;;; mwPost: the post at MW_COL, then the next one.
mwPost:       lda     [.tiny MW_COL]        ; topdelta, length
              sta     dp:.tiny MW_LT
              and     ##0x00ff
              cmp     ##0x00ff              ; 0xff: no more posts
              bne     1$
              brl     mwNextCol
1$:           asl     a
              tay
              MWROW01                       ; yl = max(H(topdelta), the first
mwS2a:        clc                           ;   row that can show)
              adc     (.tiny MW_QA2),y      ; (+ s2 * b)
              sec
              sbc     (.tiny MW_QB2),y
              bmi     2$
              cmp     dp:.tiny MW_CC1
              bcs     3$
2$:           lda     dp:.tiny MW_CC1
3$:           cmp     dp:.tiny MW_FCL       ; yl >= the row after the last that
              bcs     6$                    ;   can show: no rows (else yl < 200)
              sep     #0x20
              sta     dp:.tiny MW_YL        ; (a byte: the high byte stays 0)
              lda     dp:.tiny MW_LT        ; topdelta + length
              clc
              adc     dp:.tiny (MW_LT+1)
              bcc     4$
              brl     mwTall
6$:           sep     #0x20                 ; no record: the next post is a K_TEX
              stz     dp:.tiny MW_CONT
              rep     #0x20
              brl     mwSkip
4$:           rep     #0x20
              and     ##0x00ff
              asl     a
              tay
              MWROW01                       ; yh + 1 = H(topdelta + length); the
mwS2b:        clc                           ;   row after the rows: min(yh + 1,
              adc     (.tiny MW_QA2),y      ;   floorclip)
              sec
              sbc     (.tiny MW_QB2),y
              bmi     2$
              cmp     dp:.tiny MW_FCL
              bcc     5$
              lda     dp:.tiny MW_FCL
5$:           sep     #0x20
              sta     dp:.tiny MW_END       ; (a byte)
              cmp     dp:.tiny MW_YL        ; no rows?
              beq     7$
              bcs     8$
7$:           stz     dp:.tiny MW_CONT      ; no record: the next post is a K_TEX
              rep     #0x20
              brl     mwSkip
2$:           sep     #0x20
              bra     7$
8$:           ldx     dp:.tiny MW_X2        ; X = 2 * the column
              FSCUT   dp:.tiny MW_YL, dp:.tiny MW_END ; (lists.inc)
              lda     long:(COLW+1),x       ; Y = the free byte of the list (two
              xba                           ;   8-bit loads: no REP/SEP)
              lda     long:COLW,x
              tay
              bit     dp:.tiny MW_CONT      ; right after a record of this column:
              bpl     40$                   ;   a K_TEXC (the step, the colormap and
              cmp     #(PAGE_ROOM - TEXC_SIZE + 1) ; the bank of that record; no lump
              bcs     40$                   ;   crosses a bank) when it fits the page
              adc     #TEXC_SIZE            ; (carry clear)
              sta     long:COLW,x
              CVSETB  dp:.tiny MW_YL, dp:.tiny MW_END ; (B: the page)
              tyx                           ; X = the record
              lda     #K_TEXC
              sta     long:(RECBASE+R_KIND),x
              lda     dp:.tiny MW_YL
              sta     long:(RECBASE+R_ROW),x
              lda     dp:.tiny MW_END
              sta     long:(RECBASE+R_END),x
              lda     dp:.tiny MW_COL       ; the texels: the post + 3 (the low
              clc                           ;   word; 8-bit: no REP/SEP)
              adc     #3
              sta     long:(RECBASE+R_TCSRC),x
              lda     dp:.tiny (MW_COL+1)
              adc     #0
              sta     long:(RECBASE+(R_TCSRC+1)),x
              brl     42$
40$:          cmp     #(PAGE_ROOM - TEX_SIZE + 1) ; no room in the page: an
              bcc     6$                    ;   extra page first
              rep     #0x20
              phb
              sep     #0x20
              lda     #RECBANK
              pha
              plb
              rep     #0x20
              jsl     long:newPage          ; Y = the free byte of the new page
              plb
              tya
              sep     #0x20
              clc
6$:           adc     #TEX_SIZE             ; (carry clear)
              sta     long:COLW,x           ; COLW past the record
              CVSETB  dp:.tiny MW_YL, dp:.tiny MW_END ; (B: the page)
              tyx                           ; X = the record
              lda     #K_TEX
              sta     long:(RECBASE+R_KIND),x
              lda     dp:.tiny MW_YL
              sta     long:(RECBASE+R_ROW),x
              lda     dp:.tiny MW_END
              sta     long:(RECBASE+R_END),x
              lda     dp:.tiny MW_S2
              sta     long:(RECBASE+R_SF),x
              lda     dp:.tiny (MW_S2+1)
              sta     long:(RECBASE+R_SI),x
              lda     dp:.tiny MW_CMP
              sta     long:(RECBASE+R_CMP),x
              lda     dp:.tiny MW_COL       ; the texels: the post + 3 (8-bit:
              clc                           ;   no REP/SEP)
              adc     #3
              sta     long:(RECBASE+R_SRC),x
              lda     dp:.tiny (MW_COL+1)
              adc     #0
              sta     long:(RECBASE+R_SRC+1),x
              lda     dp:.tiny (MW_COL+2)
              adc     #0
              sta     long:(RECBASE+R_SRC+2),x
42$:          rep     #0x20                 ; the position of the row before yl
              lda     dp:.tiny MW_YL        ;   >> 1: (yl * the step + K) >> 1,
              asl     a                     ;   less topdelta in the texel byte
              tay
              lda     (.tiny MW_PF1),y
              sec
              sbc     (.tiny MW_MF1),y
              xba
              and     ##0xff00
              clc
              adc     (.tiny MW_PF0),y
              sec
              sbc     (.tiny MW_MF0),y
              clc
              adc     dp:.tiny MW_K
              lsr     a
              sep     #0x20
              sta     long:(RECBASE+R_TF),x
              xba
              sec
              sbc     dp:.tiny MW_LT
              and     #0x7f
              sta     long:(RECBASE+R_TI),x
              lda     #0x80                 ; the next post may be a K_TEXC
              sta     dp:.tiny MW_CONT
              rep     #0x20
mwSkip:       lda     dp:.tiny MW_LT        ; the next post: + length + 4
              xba
              and     ##0x00ff
              sec
              adc     ##3
              adc     dp:.tiny MW_COL
              sta     dp:.tiny MW_COL
              brl     mwPost
              .space  8                     ; (mwNextCol keeps its address)

mwNextCol:    lda     .near FR_X            ; x++, spryscale += rw_scalestep,
              inc     a                     ;   FR_P += FR_B (48 bits)
              sta     .near FR_X
              lda     .near spryscale
              clc
              adc     .near rw_scalestep
              sta     .near spryscale
              lda     .near (spryscale+2)
              adc     .near (rw_scalestep+2)
              sta     .near (spryscale+2)
              lda     .near FR_P
              clc
              adc     .near FR_B
              sta     .near FR_P
              lda     .near (FR_P+2)
              adc     .near (FR_B+2)
              sta     .near (FR_P+2)
              lda     .near (FR_P+4)
              adc     .near (FR_B+4)
              sta     .near (FR_P+4)
              brl     mwCol

;;; mwTall: a post that ends after texture row 255 (the products need b <=
;;; 255; no texture of the game has one).
mwTall:       rep     #0x20
              lda     ##.word0 errTall
              sta     dp:.tiny _Dp
              lda     ##.word2 errTall
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
errTall:      .asciz  "mwCols: a masked post ends after row 255"

;;; ---------------------------------------------------------------------------
;;; The column loop of R_DrawVisSprite (src/iigs/r_seg65.s) for a magnified
;;; sprite: visColD (after the setup of R_DrawVisSprite) takes this loop for
;;; |xiscale| < 0.75 with no clip pass and no unit scale, else visCol. The
;;; same records as visCol/visPost, but a post of a column is also made
;;; into the next columns that show the same texture column (frac >>
;;; FRACBITS) with the same clips (V_REP of them): the same record in each,
;;; with no header, YHTAB, clamp or frac work of its own; then vrNext goes
;;; to the last of those columns at once. Direct page WPAGE, DBR = RECBANK,
;;; as in visCol.
;;; ---------------------------------------------------------------------------
              .extern visCol, YHTABM
              .public visColD, vrCol8, vrPost, vrAdv, vrNext0, vrDone, VR_LP, VR_NX, vrFill
YHTAB         .equ    YHTABM + 2

;;; STEP8 v, s: \v += \s (32 bits) one byte at a time, as STEP8 of
;;; src/iigs/r_seg65.s; A = the top byte. 8-bit A.
STEP8         .macro  v, s
              clc
              lda     dp:\v
              adc     dp:\s
              sta     dp:\v
              lda     dp:(\v+1)
              adc     dp:(\s+1)
              sta     dp:(\v+1)
              lda     dp:(\v+2)
              adc     dp:(\s+2)
              sta     dp:(\v+2)
              lda     dp:(\v+3)
              adc     dp:(\s+3)
              sta     dp:(\v+3)
              .endm
V_REP         .equ    W_YH            ; the columns of the run after this one
V_XEND        .equ    W_CC            ; 2 * the column after the run (V_REP > 0)
V_TFI         .equ    W_TOP           ; TF, TI of the post (the loop at 21$)

visColD:      lda     dp:(V_XIS+2)          ; |xiscale| < 0.75 (more repeats than
              bne     3$                    ;   the test of each column costs)
              lda     dp:V_XIS
              cmp     ##0xc000
              bcs     2$
1$:           lda     dp:V_CLIP             ; not the clip pass of the weapon,
              ora     dp:V_UNIT             ;   not the unit scale
              beq     vrCol
2$:           jmp     long:visCol
3$:           cmp     ##0xffff
              bne     2$
              lda     dp:V_XIS
              cmp     ##0x4001
              bcs     1$
              bra     2$

;;; vrCol: visCol, and V_REP. The column loop stays in 8-bit A (vrCol8)
;;; but for the post pointer and V_REP (REP and SEP cost a slow cycle each).
vrCol:        sep     #0x20                 ; (16-bit A from visColD)
vrCol8:       ldy     dp:W_X2
              cpy     ##(2 * CONST_VIEWWIDTH)
              bcc     1$
              brl     vrDone
2$:           brl     vrNext0
1$:           lda     [V_FCP],y             ; the rows the clips leave: V_LO
              beq     2$                    ;   to V_HI - 1
              dec     a
              sta     dp:V_HI
              lda     [V_CCP],y
              sta     dp:V_LO
              cmp     dp:V_HI
              bcs     2$
              rep     #0x20                 ; (16-bit to 7$)
              lda     dp:(V_FRAC+2)         ; column = patch + columnofs[frac >> FRACBITS]
              asl     a
              asl     a
              adc     ##OFS_PATCH_COLUMNOFS ; (carry clear)
              tay
              lda     [V_PATCH],y
              clc
              adc     dp:V_PATCH
              sta     dp:V_COL
              ldy     dp:W_X2               ; the run: the next columns with the
              ldx     dp:V_FRAC             ;   same texture column (frac +
4$:           iny                           ;   xiscale: xiscale.hi + the carry
              iny                           ;   of the low words is 0) and the
              cpy     ##(2 * CONST_VIEWWIDTH) ; same clips; X = the low word of
              bcs     6$                    ;   the frac of the last one
              txa
              clc
              adc     dp:V_XIS
              tax
              lda     dp:(V_XIS+2)
              adc     ##0
              bne     5$
              lda     [V_FCP],y             ; (V_HI, V_LO: words with a high
              and     ##0x00ff              ;   byte of 0)
              dec     a
              cmp     dp:V_HI
              bne     5$
              lda     [V_CCP],y
              and     ##0x00ff
              cmp     dp:V_LO
              beq     4$
5$:           txa                           ; (column Y / 2 is not in the run)
              sec
              sbc     dp:V_XIS
              tax
6$:           tya                           ; V_REP = (Y - W_X2) / 2 - 1 (carry
              clc                           ;   clear: the - 1 before the shift)
              sbc     dp:W_X2
              lsr     a
              beq     7$
              sty     dp:V_XEND             ; a run: its end (the loop at 21$)
              stx     dp:V_FRAC             ;   and the frac of its last column
7$:           sep     #0x20                 ;   (vrNext; the high word is the
              sta     dp:V_REP              ;   same)
              bra     vrPost

;;; vrPost: visPost (no unit scale, no clip pass). 8-bit A.
vrEnd:        brl     vrNext                ; (the last post of the column)
vrSkip:       sep     #0x20
vrAdv:        lda     dp:V_LEN
              clc
              adc     #4
              bcc     1$
              inc     dp:(V_COL+1)
              clc
1$:           adc     dp:V_COL
              sta     dp:V_COL
              bcc     vrPost
              inc     dp:(V_COL+1)
vrPost:       lda     [V_COL]               ; topdelta, 0xff: no more posts
              cmp     #0xff
              beq     vrEnd
              sta     dp:V_TD
              ldy     ##1
              lda     [V_COL],y             ; length
              sta     dp:V_LEN
              rep     #0x20
              lda     dp:V_TD               ; yh: none when above V_LO, then
              clc                           ;   V_YH1 = min(yh + 1, V_HI)
              adc     dp:V_LEN
              cmp     dp:V_TN               ; (YHTAB up to the row)
              bcc     1$
              jsr     .kbank vrFill
1$:           asl     a
              tax
              lda     long:YHTAB,x
              bmi     vrSkip
              cmp     dp:V_LO
              bcc     vrSkip
              cmp     dp:V_HI
              bcc     4$
              lda     dp:V_HI
              dec     a
4$:           inc     a
              sta     dp:V_YH1              ; (16-bit, no REP/SEP: its high byte 0)
              lda     dp:V_TD               ; yl: none when V_HI or more, then
              asl     a                     ;   V_YL = max(yl, V_LO)
              tax
              lda     long:YHTAB,x
              bmi     61$
              inc     a
              cmp     dp:V_HI
              bcs     vrSkip
              cmp     dp:V_LO
              bcs     62$
61$:          lda     dp:V_LO
62$:          sep     #0x20
              sta     dp:V_YL
              lda     dp:V_YH1              ; the count of rows
              sec
              sbc     dp:V_YL
              beq     vrAdv
              bcc     vrAdv
              lda     dp:V_REP
              beq     11$
              brl     20$
18$:          rep     #0x20                 ; an extra page first
              jsl     long:newPage          ; Y = the free byte of the new page
              tya
              sep     #0x20
              clc
              bra     13$
              ;; the post as a K_TEX record at the end of the list of the
              ;; column (as visPost)
11$:          ldx     dp:W_X2
              FSCUT   dp:V_YL, dp:V_YH1
              lda     long:(COLW+1),x       ; Y = the free byte of the list (two
              xba                           ;   8-bit loads: no REP/SEP)
              lda     long:COLW,x
              tay
              cmp     #(PAGE_ROOM - TEX_SIZE + 1)
              bcs     18$
13$:          adc     #TEX_SIZE             ; (carry clear)
              sta     long:COLW,x
              CVSETB  dp:V_YL, dp:V_YH1     ; (B: the page)
              tyx                           ; X = the record
              lda     #K_TEX
              sta     abs:R_KIND,x
              lda     dp:V_YL
              sta     abs:R_ROW,x
              lda     dp:V_YH1
              sta     abs:R_END,x
              rep     #0x20                 ; Y = 2 * the first row; the frac
              lda     dp:V_YL               ;   of the row in 16-bit (one REP,
              asl     a                     ;   one SEP)
              tay
              lda     dp:V_TD               ; |xiscale| < 0.75 makes fH zero
              asl     a                     ; V_K - (2 * topdelta << 8)
              xba
              and     ##0xff00
              eor     ##0xffff
              sec
              adc     dp:V_K
              bra     131$
              .space  3                     ; keep the record loop in place
131$:
              clc                           ; + row * fL (QPROD)
              adc     [V_QP],y
              sec
              sbc     [V_QM],y
              lsr     a                     ; frac >> 1: TF, TI
              sep     #0x20
              sta     abs:R_TF,x
              xba
              sta     abs:R_TI,x
              lda     dp:V_S2               ; fracstep >> 1: SF, SI
              sta     abs:R_SF,x
              lda     dp:(V_S2+1)
              sta     abs:R_SI,x
              lda     dp:V_COL              ; the texels: the post + 3
              clc
              adc     #3
              sta     abs:R_SRC,x
              lda     dp:(V_COL+1)
              adc     #0
              sta     abs:(R_SRC+1),x
              lda     dp:(V_COL+2)
              sta     abs:(R_SRC+2),x
              lda     dp:W_CMP              ; the colormap of the even rows
              sta     abs:R_CMP,x
              brl     vrAdv

              ;; the post in this column and in the V_REP next ones: TF, TI
              ;; once, then the record in each (X = the column: the record
              ;; stores go through Y; no call and no count in memory)
20$:          rep     #0x20                 ; the frac as in 11$ (16-bit)
              lda     dp:V_YL
              asl     a
              tay
              lda     dp:V_TD               ; |xiscale| < 0.75 makes fH zero
              asl     a                     ; V_K - (2 * topdelta << 8)
              xba
              and     ##0xff00
              eor     ##0xffff
              sec
              adc     dp:V_K
              bra     201$
              .space  3                     ; keep the record loop in place
201$:
              clc
              adc     [V_QP],y
              sec
              sbc     [V_QM],y
              lsr     a
              sta     dp:V_TFI
              ldx     dp:W_X2
              sep     #0x20
VR_LP         .equ    . + 0           ; (the 2/3 view: vr3Nx comes back here)
21$:          FSCUT   dp:V_YL, dp:V_YH1
              lda     long:(COLW+1),x       ; Y = the free byte of the list (two
              xba                           ;   8-bit loads: no REP/SEP)
              lda     long:COLW,x
              tay
              cmp     #(PAGE_ROOM - TEX_SIZE + 1)
              bcs     28$
24$:          adc     #TEX_SIZE             ; (carry clear)
              sta     long:COLW,x
              CVSETB  dp:V_YL, dp:V_YH1     ; (B: the page)
              lda     #K_TEX
              sta     abs:R_KIND,y
              lda     dp:V_YL
              sta     abs:R_ROW,y
              lda     dp:V_YH1
              sta     abs:R_END,y
              lda     dp:V_TFI
              sta     abs:R_TF,y
              lda     dp:(V_TFI+1)
              sta     abs:R_TI,y
              lda     dp:V_S2
              sta     abs:R_SF,y
              lda     dp:(V_S2+1)
              sta     abs:R_SI,y
              lda     dp:V_COL
              clc
              adc     #3
              sta     abs:R_SRC,y
              lda     dp:(V_COL+1)
              adc     #0
              sta     abs:(R_SRC+1),y
              lda     dp:(V_COL+2)
              sta     abs:(R_SRC+2),y
              lda     dp:W_CMP
              sta     abs:R_CMP,y
VR_NX         .equ    . + 0           ; (the 2/3 view: jmp vr3Nx)
              inx
              inx
              cpx     dp:V_XEND
              bcs     29$
              jmp     .kbank VR_LP          ; (the loop is over 128 bytes)
29$:          brl     vrAdv
28$:          rep     #0x20                 ; an extra page first
              jsl     long:newPage          ; (X kept)
              tya
              sep     #0x20
              clc
              brl     24$

;;; vrFill: visFill (YHTAB for texel rows V_TN..C; C is kept).
vrFill:       pha
              asl     a
              sta     dp:V_TEND
              lda     dp:V_TN
              asl     a
              tax
              ldy     dp:V_E
1$:           tya                           ; E += spryscale
              clc
              adc     dp:V_SS
              tay
              lda     long:(YHTAB-2),x
              adc     dp:(V_SS+2)
              sta     long:YHTAB,x
              inx
              inx
              cpx     dp:V_TEND
              bcc     1$
              beq     1$
              sty     dp:V_E
              txa
              lsr     a
              sta     dp:V_TN
              pla
              rts

;;; vrNext: W_X2 to the last column of the run (vrCol8 left its frac in
;;; V_FRAC), then vrNext0: visNext. 8-bit A.
vrNext:       lda     dp:V_REP              ; W_X2 += 2 * V_REP
              beq     vrNext0
              asl     a
              bcc     1$
              inc     dp:(W_X2+1)           ; (a run of 128 columns or more)
              clc
1$:           adc     dp:W_X2
              sta     dp:W_X2
              bcc     vrNext0
              inc     dp:(W_X2+1)
vrNext0:      STEP8   V_FRAC, V_XIS         ; (8-bit A throughout)
              bmi     vrDone                ; frac < 0
              bne     7$                    ; (frac >> FRACBITS) >= 256
              lda     dp:(V_FRAC+2)         ; (frac >> FRACBITS) >= width: the
              cmp     dp:V_WIDTH            ;   low bytes, then a width of 256
              bcc     2$                    ;   or more
              lda     dp:(V_WIDTH+1)
              beq     vrDone
2$:           lda     dp:W_X2
              clc
              adc     #2
              sta     dp:W_X2
              bcc     3$
              inc     dp:(W_X2+1)
3$:           brl     vrCol8
7$:           rep     #0x20                 ; a column of 256 or more: the
              lda     dp:(V_FRAC+2)         ;   16-bit compare
              cmp     dp:V_WIDTH
              sep     #0x20
              bcc     2$
vrDone:       rep     #0x20
              plb
              pld
              rtl

;;; ---------------------------------------------------------------------------
;;; The half view and the 2/3 view (src/iigs/viewwin.inc).
;;;
;;; vwFrame (display of src/iigs/d_main65.s, after viewtop and viewbottom):
;;; the size of this frame from VW_SIZE. In the half view and the 2/3 view
;;; the view keeps all its rows (viewtop = -1: the message strip is outside
;;; the window). A new size drops the fill spans
;;; and the weapon of the frame before (their bytes on the screen are of the
;;; other size). The border around the window is painted in black when it
;;; needs paint: a new size, a frame before that did not show the view
;;; (W_FSW = 0: another screen, the automap, the menu, a wipe). A message
;;; that went off gets only the rows of its strip. Section vwcode (its own
;;; region: no other code moves). 16-bit A, X and Y.
;;; ---------------------------------------------------------------------------
              .section vwcode, text
              .public vwFrame
              .extern hvPatch
VW_STRIP      .equ    10              ; STRIP_ROWS of src/iigs/i_viigs65.s
VW_AMACTIVE   .equ    1               ; AM_ACTIVE of src/iigs/am_map65.s
vwFrame:      lda     long:VW_INIT          ; the first view: the size of the
              cmp     ##VW_INITTAG          ;   settings file (vwKeys of
              beq     1$                    ;   src/iigs/m_menu65.s keeps it
              lda     ##VW_INITTAG          ;   there)
              sta     long:VW_INIT
              lda     long:(settingsFile+VW_FVSIZE)
              sta     long:VW_SIZE
1$:           lda     long:VW_SIZE          ; the size of the player: the half
              and     ##0x00ff              ;   view, the 2/3 view, else the
              cmp     ##VW_HALFSIZE         ;   full view
              beq     2$
              cmp     ##VW_TWOSIZE
              beq     2$
              lda     ##10
              sta     long:VW_SIZE
2$:           tay                           ; (the automap overlay keeps the
              tya                           ;   size: src/iigs/am_map65.s draws
                                            ;   it on the half view too)
              ora     ##VW_TAG
              cmp     long:VW_CUR
              beq     5$
              sta     long:VW_CUR           ; a new size: its window (VWTAB),
              lda     ##0                   ;   the border, no fill spans and
              sta     long:VW_HALF          ;   no weapon skip from the frame
              sta     long:VW_THIRD         ;   before
              ldx     ##0
              lda     ##1
              cpy     ##VW_HALFSIZE
              bne     3$
              ldx     ##8
              sta     long:VW_HALF
3$:           cpy     ##VW_TWOSIZE
              bne     4$
              ldx     ##16
              sta     long:VW_THIRD
4$:           lda     long:VWTAB,x
              sta     long:VW_LEFT
              lda     long:(VWTAB+2),x
              sta     long:VW_RIGHT
              lda     long:(VWTAB+4),x
              sta     long:VW_TOP
              lda     long:(VWTAB+6),x
              sta     long:VW_BOTTOM
              lda     ##1
              sta     long:VW_BORDER
              lda     ##0xffff
              sta     long:(WPREV+OFS_VIS_LUMP)
              sep     #0x20
              lda     #0
              sta     long:(WPAGE+W_FSW)
              rep     #0x20
              jsl     long:hvPatch          ; the code of the sprites and masked
                                            ;   walls for the size (r_thing65)
5$:           lda     ##0                   ; (a menu after this view hides the
              sta     long:VW_MHID          ;   message again: stHide)
              lda     long:(WPAGE+W_FSW)    ; the frame before did not show
              and     ##0x00ff              ;   the view
              bne     6$
              lda     ##1
              sta     long:VW_BORDER
6$:           lda     .near message_on      ; a message went off: the rows of
              cmp     long:VW_MSG           ;   its strip only (a message that
              beq     7$                    ;   goes on gets a black strip from
              sta     long:VW_MSG           ;   I_MessageStrip)
              cmp     ##0
              bne     7$
              lda     ##1
              sta     long:VW_BSTRIP
7$:
              lda     long:VW_HALF          ; the half view and the 2/3 view:
              ora     long:VW_THIRD         ;   all rows of the view (also with
              beq     71$                   ;   the automap
              lda     ##0xffff              ;   overlay: its title is outside
              sta     .near viewtop         ;   the window); display keeps the
              lda     ##CONST_VIEWHEIGHT    ;   text of the message strip
              sta     .near viewbottom
              lda     ##0
              bra     72$
71$:          lda     .near viewtop
72$:          sta     long:VW_STRIPV
              lda     long:VW_BORDER
              ora     long:VW_BSTRIP
              beq     8$
              lda     long:VW_HALF          ; (the full view: no border)
              ora     long:VW_THIRD
              beq     74$
              jsr     .kbank vwBorder
74$:          lda     ##0
              sta     long:VW_BORDER
              sta     long:VW_BSTRIP
8$:           rtl

;;; VWTAB: the window of each size: its first and last column, the row
;;; above it and the row after it.
VWTAB:        .word   0, 159, 0xffff, 168       ; the full view: 160 x 168
              .word   40, 119, 41, 126          ; the half view: 80 x 84
              .word   26, 132, 27, 140          ; the 2/3 view: 107 x 112

;;; vwBorder: the rows of the view outside the window in black (Doom color 0
;;; at full light: the byte of the even rows, of the odd rows), from row 0
;;; (the message strip is gone then), or after the strip while a message
;;; shows. With VW_BORDER = 0 only the rows of the strip (VW_BSTRIP). SHR
;;; shadowing on: the view bank and the screen.
vwBorder:     sep     #0x20
              lda     long:SHADOW
              and     #0xf7
              sta     long:SHADOW
              rep     #0x20
              lda     long:iigs_shrcmapA    ; the byte twice in a word
              and     ##0x00ff
              sta     long:VW_PA
              xba
              ora     long:VW_PA
              sta     long:VW_PA
              lda     long:iigs_shrcmapB
              and     ##0x00ff
              sta     long:VW_PB
              xba
              ora     long:VW_PB
              sta     long:VW_PB
              lda     ##VW_STRIP            ; the first row
              ldx     .near message_on
              bne     1$
              stz     .near iigs_textShown  ; (the text of the strip goes)
              lda     ##0
1$:           sta     long:VW_ROW
              ldx     ##CONST_VIEWHEIGHT    ; the row after the last
              lda     long:VW_BORDER
              bne     11$
              ldx     ##VW_STRIP
11$:          txa
              sta     long:VW_BEND
2$:           lda     long:VW_ROW
              cmp     long:VW_BEND
              bcc     21$
              rts
21$:          asl     a                     ; the row: row * 160 in the bank
              asl     a                     ;   of the view
              asl     a
              asl     a
              asl     a
              sta     long:VW_T
              asl     a
              asl     a
              clc
              adc     long:VW_T
              sta     long:VW_BASE
              lda     long:VW_ROW           ; the byte of an even or odd row
              lsr     a
              lda     long:VW_PA
              bcc     3$
              lda     long:VW_PB
3$:           sta     long:VW_FILL
              lda     long:VW_ROW           ; above the window, or under it: all
              sec                           ;   of the row
              sbc     long:VW_TOP
              beq     5$
              bvc     31$
              eor     ##0x8000
31$:          bmi     5$
              lda     long:VW_ROW
              cmp     long:VW_BOTTOM
              bcs     5$
              lda     long:VW_BASE          ; beside it: 0..left - 1 and right +
              tax                           ;   1..159 (both even)
              lda     long:VW_LEFT
              tay
              jsr     .kbank vwFill
              lda     long:VW_RIGHT
              inc     a
              clc
              adc     long:VW_BASE
              tax
              lda     ##(CONST_VIEWWIDTH - 1)
              sec
              sbc     long:VW_RIGHT
              tay
              jsr     .kbank vwFill
              bra     6$
5$:           lda     long:VW_BASE
              tax
              ldy     ##CONST_VIEWWIDTH
              jsr     .kbank vwFill
6$:           lda     long:VW_ROW
              inc     a
              sta     long:VW_ROW
              brl     2$

;;; vwFill: Y bytes (more than 0) of VW_FILL from X in the view bank. An odd
;;; count (the right side of the 2/3 view) stores one byte first.
vwFill:       tya
              lsr     a
              bcc     1$
              sep     #0x20
              lda     long:VW_FILL
              sta     long:0x012000,x
              rep     #0x20
              inx
              dey
              beq     2$
1$:           lda     long:VW_FILL
11$:          sta     long:0x012000,x
              inx
              inx
              dey
              dey
              bne     11$
2$:           rts

              .public OF_CMP, OF_CPY, OF_FLAG, OF_SMALL, OF_BORDER, VWTAB

OF_CMP        .equ    (vwFrame + 31) ; unchanged instruction site

OF_CPY        .equ    (vwFrame + 80) ; unchanged instruction site

OF_FLAG        .equ    (vwFrame + 88) ; unchanged instruction site

OF_SMALL        .equ    (vwFrame + 212) ; unchanged instruction site

OF_BORDER        .equ    (vwFrame + 256) ; unchanged instruction site
