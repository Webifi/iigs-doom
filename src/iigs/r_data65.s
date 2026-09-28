;;; Render data in 65816 assembly, Doom8088: Apple IIgs Edition.
;;;
;;; r_data.c (the textures), r_sky.c (the sky), r_plane.c (the
;;; nukage frame), v_video.c (patches by lump number), r_things.c (the
;;; sprite frames) and the rest of the code of r_draw.c (the texture
;;; columns, the colormaps, the sprite scale tables, R_PointOnSegSide) with
;;; the same results. The lumps are in place in the WAD image, so the calls
;;; of Z_ChangeTagToCache for them (which do nothing) are gone.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"

              .extern _Dp, I_Error, Z_MallocStatic, Z_MallocLevel, Z_Free, memset, memcpy
              .extern W_GetNumForName, W_GetLumpByNum, W_GetNameForNum, W_ReadLumpByNum
              .extern V_DrawRaw, V_DrawPatchScaled, V_DrawPatchNotScaled
              .extern R_InitLists
              .extern R_DrawColumnFlat, R_DrawColumnWall, FixedMul3216, IIGS_MulLo16
              .extern _Div32, _UDivMod16, _Mod16
              .extern viewangle, xtoviewangleTable, _g_leveltime, _g_sides, sprnames
              .extern _g_gamemap, W_NEXTBANK, W_COLSTART, W_ZeroBank

MAXSPRITEFRAMES .equ  29

              .section coldfar, bss
              .public LC_MAP                ; (0 from the level loader: its window
                                      ;   holds another set)
LC_MAP:       .space  2               ; R_MakeLevelColumns: the map of the
                                      ;   column tables (0: none)
CM_MAX        .equ    16
CM_PASS:      .space  2               ; R_MakeLevelColumns: 1 in pass 1
CM_HOT:       .space  2               ; columnAlloc: not 0 for a hot column
CM_N:         .space  2               ; 2 * the holes
CM_HS:        .space  2 * CM_MAX + 2  ; a hole: the start, the end, the bank
CM_HE:        .space  2 * CM_MAX + 2  ;   (one more: a hole that the list has
CM_HB:        .space  2 * CM_MAX + 2  ;   no room for)
FLAT_SKY_COLOR .equ   99
SKYFRACSTEP   .equ    0x200           ; FRACUNIT >> COLEXTRABITS
SKYSHIFT      .equ    6               ; ANGLETOSKYSHIFT - FRACBITS
COLDIR_ADDR   .equ    MM_COLDIR       ; also in src/iigs/r_seg65.s
COLDIR_SIZE   .equ    0x400
OVERREAD      .equ    128             ; a texel read goes up to 127 bytes past a
                                      ;   column start (the & 127 of short
                                      ;   textures): a column ends this far
                                      ;   from the end of its bank, so no read
                                      ;   leaves the bank (the window banks
                                      ;   are not in order, src/iigs/memmap.inc)
SPRXSCALE_ADDR .equ   MM_SPRXSCALE    ; see src/iigs/iigs.scm
SPRYSCALE_ADDR .equ   MM_SPRYSCALE
MAXZ_HI       .equ    1280            ; MAXZ >> FRACBITS
;;; maptexture_t in TEXTURE1: name, width, height, patchcount, patches of
;;; mappatch_t (originx, originy, patch)
MT_WIDTH      .equ    8
MT_HEIGHT     .equ    10
MT_PATCHCOUNT .equ    12
MT_PATCHES    .equ    14

              .section cnear, rodata
              .public skyflatnum
skyflatnum:   .word   0xfffe          ; -2: the sky is a flat color

              .section znear, bss
              .public sprites, nukage, skypatchnum, skywidthmask, skypatch
sprites:      .space  4               ; spritedef_t __far*
nukage:       .space  2               ; the flat number of the NUKAGE frame
skypatchnum:  .space  2
skywidthmask: .space  2
skypatch:     .space  4               ; also used by r_frame65.s, r_seg65.s
textures:     .space  4               ; const texture_t __far*__far*
numtextures:  .space  2
firstspritelump: .space 2
numentries:   .space  2               ; the sprite lumps
maxframe:     .space  2
sprtemp:      .space  4
              .public colmem                ; (W_LevelDone of src/iigs/w_level65.s)
colmem:       .space  4               ; the next free column memory
RD_T:         .space  4
RD_U:         .space  4
RD_A:         .space  4
RD_I:         .space  2
RD_J:         .space  2
RD_K:         .space  2
RD_N:         .space  2
RD_X:         .space  2
RD_W:         .space  2
RD_PNUM:      .space  2
RD_COVERS:    .space  2
RD_ONLYY:     .space  2
RD_HEIGHT:    .space  2
RD_TEXNUM:    .space  2
RD_NAME8:     .space  8               ; a name, 0 padded
RD_NAME:      .space  4               ; a name
RD_ONLY:      .space  4               ; the column of the only patch
RD_TEX:       .space  4               ; the new texture
RD_HASH:      .space  4               ; R_InitSprites: the hash chains
LC_I:         .space  2               ; R_MakeLevelColumns: the side,
LC_N:         .space  2               ;   the sides, the side offset
LC_X:         .space  2

              .section cfar, rodata
strPnames:    .asciz  "PNAMES"
strTexture1:  .asciz  "TEXTURE1"
strSky1:      .asciz  "SKY1"
strSStart:    .asciz  "S_START"
strSEnd:      .asciz  "S_END"
strColormap:  .asciz  "COLORMAP"
errTexture:   .asciz  "R_GetTextureNumForName: texture name: %s not found."
errColumns:   .asciz  "R_ColumnAlloc: the wall textures of the level fill the level window"
errFrame:     .asciz  "R_InstallSpriteLump: Bad frame characters in lump %i"
errNoPatch:   .asciz  "R_InitSprites: No patches found for %.4s frame %c"
errRotations: .asciz  "R_InitSprites: Sprite %.4s frame %c is missing rotations"

;;; ---------------------------------------------------------------------------
;;; void R_Init(void): the textures, the sky, the sprite lumps, the
;;; colormaps (after W_Init).
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public R_Init
R_Init:       jsl     long:R_InitLists      ; no column records (src/iigs/r_list65.s)
              jsr     .kbank initTextures
              jsr     .kbank initSky
              jsl     long:R_InitSpriteLumps
              jsl     long:R_InitColormaps
              rtl

;;; namePtr: _Dp[0-3] = the string at X (its low word) of bank C.
namePtr:      stx     dp:.tiny _Dp
              sta     dp:.tiny (_Dp+2)
              rts

;;; lumpByName: X:C = W_GetLumpByNum(W_GetNumForName(the name in
;;; _Dp[0-3])).
lumpByName:   jsl     long:W_GetNumForName
              jsl     long:W_GetLumpByNum
              rts

;;; initTextures: R_InitTextures: numtextures from TEXTURE1; textures and
;;; textureheight 0; texturetranslation[i] = i.
initTextures: ldx     ##.word0 strTexture1
              lda     ##.word2 strTexture1
              jsr     .kbank namePtr
              jsr     .kbank lumpByName
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp]
              sta     .near numtextures
              asl     a                     ; textures: 4 bytes each
              asl     a
              jsr     .kbank allocZero
              sta     .near textures
              stx     .near (textures+2)
              lda     .near numtextures     ; textureheight: 2 bytes each
              asl     a
              jsr     .kbank allocZero
              sta     .near textureheight
              stx     .near (textureheight+2)
              lda     .near numtextures     ; texturetranslation: one more
              inc     a
              asl     a
              jsl     long:Z_MallocStatic
              sta     .near texturetranslation
              stx     .near (texturetranslation+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##0
              tya
              bra     2$
1$:           sta     [.tiny _Dp],y
              inc     a
              iny
              iny
2$:           cmp     .near numtextures
              bcc     1$
              rts

;;; allocZero: X:C = Z_MallocStatic(C bytes), filled with 0.
allocZero:    pha
              jsl     long:Z_MallocStatic
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              pla
              sta     dp:.tiny (_Dp+4)
              lda     ##0
              jsl     long:memset
              rts

;;; initSky: R_InitSky: the patch and width mask of the texture SKY1.
initSky:      ldx     ##.word0 strSky1
              lda     ##.word2 strSky1
              jsr     .kbank namePtr
              jsl     long:R_CheckTextureNumForName
              jsl     long:R_GetTexture
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##(OFS_TEX_PATCHES+OFS_TP_PATCHNUM)
              lda     [.tiny _Dp],y
              sta     .near skypatchnum
              ldy     ##OFS_TEX_WIDTHMASK
              lda     [.tiny _Dp],y
              sta     .near skywidthmask
              rts

;;; ---------------------------------------------------------------------------
;;; const texture_t __far* R_GetTexture(int16_t texture)   In: C. Out: X:C.
;;; The texture, made from TEXTURE1 if it is not there (a PU_LEVEL block
;;; with the user textures[texture]).
;;; ---------------------------------------------------------------------------
              .public R_GetTexture
R_GetTexture: sta     .near RD_TEXNUM
              asl     a
              asl     a
              tay
              lda     .near textures
              sta     dp:.tiny _Dp
              lda     .near (textures+2)
              sta     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp],y
              tax
              iny
              iny
              ora     [.tiny _Dp],y
              beq     1$
              lda     [.tiny _Dp],y
              phx
              tax
              pla
              rtl
1$:           jsr     .kbank loadTexture
              lda     .near RD_TEX
              ldx     .near (RD_TEX+2)
              rtl

;;; loadTexture: R_LoadTexture(RD_TEXNUM): RD_TEX = the new texture: the
;;; size, the patches (their lumps and widths), a mask of the largest power
;;; of 2 in the width, and if patches overlap.
loadTexture:  pei     dp:.tiny (_Dp+8)      ; _Dp+8: the maptexture
              pei     dp:.tiny (_Dp+10)
              pei     dp:.tiny (_Dp+12)     ; _Dp+12: the texture
              pei     dp:.tiny (_Dp+14)
              ldx     ##.word0 strTexture1  ; mtexture = maptex + directory[n]
              lda     ##.word2 strTexture1
              jsr     .kbank namePtr
              jsr     .kbank lumpByName
              sta     dp:.tiny (_Dp+8)
              stx     dp:.tiny (_Dp+10)
              lda     .near RD_TEXNUM
              inc     a
              asl     a
              asl     a
              tay
              lda     [.tiny (_Dp+8)],y
              tax
              iny
              iny
              lda     [.tiny (_Dp+8)],y
              pha
              txa
              clc
              adc     dp:.tiny (_Dp+8)
              sta     dp:.tiny (_Dp+8)
              pla
              adc     dp:.tiny (_Dp+10)
              sta     dp:.tiny (_Dp+10)
              lda     .near RD_TEXNUM       ; the user: &textures[n]
              asl     a
              asl     a
              clc
              adc     .near textures
              sta     dp:.tiny _Dp
              lda     .near (textures+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              ldy     ##MT_PATCHCOUNT       ; size 16 + 8 * (patchcount - 1)
              lda     [.tiny (_Dp+8)],y
              asl     a
              asl     a
              asl     a
              clc
              adc     ##(16-8)
              jsl     long:Z_MallocLevel
              sta     dp:.tiny (_Dp+12)
              stx     dp:.tiny (_Dp+14)
              sta     .near RD_TEX
              stx     .near (RD_TEX+2)
              ldy     ##MT_WIDTH            ; width, height
              lda     [.tiny (_Dp+8)],y
              sta     .near RD_W
              ldy     ##OFS_TEX_WIDTH
              sta     [.tiny (_Dp+12)],y
              ldy     ##MT_HEIGHT
              lda     [.tiny (_Dp+8)],y
              ldy     ##OFS_TEX_HEIGHT
              sta     [.tiny (_Dp+12)],y
              ldy     ##MT_PATCHCOUNT       ; overlapped = false, patchcount
              lda     [.tiny (_Dp+8)],y     ; (a byte)
              xba
              and     ##0xff00
              ldy     ##OFS_TEX_OVERLAPPED
              sta     [.tiny (_Dp+12)],y
              xba
              sta     .near RD_N
              lda     ##1                   ; widthmask: w - 1, w the largest
1$:           asl     a                     ; power of 2 <= width
              cmp     .near RD_W
              beq     1$
              bmi     1$
              lsr     a
              dec     a
              ldy     ##OFS_TEX_WIDTHMASK
              sta     [.tiny (_Dp+12)],y
              ldx     ##.word0 strPnames    ; the patch names (after a count)
              lda     ##.word2 strPnames
              jsr     .kbank namePtr
              jsr     .kbank lumpByName
              clc
              adc     ##4
              sta     .near RD_NAME
              stx     .near (RD_NAME+2)
              stz     .near RD_J            ; each patch
              bra     3$
2$:           lda     .near RD_J            ; mpatch: MT_PATCHES + 6 * j
              asl     a
              sta     .near RD_K
              asl     a
              clc
              adc     .near RD_K
              adc     ##MT_PATCHES
              sta     .near RD_K
              lda     .near RD_J            ; patch: OFS_TEX_PATCHES + 8 * j
              asl     a
              asl     a
              asl     a
              adc     ##OFS_TEX_PATCHES
              sta     .near RD_X
              ldy     .near RD_K            ; originx
              lda     [.tiny (_Dp+8)],y
              ldy     .near RD_X
              sta     [.tiny (_Dp+12)],y
              ldy     .near RD_K            ; originy
              iny
              iny
              lda     [.tiny (_Dp+8)],y
              ldy     .near RD_X
              iny
              iny
              sta     [.tiny (_Dp+12)],y
              ldy     .near RD_K            ; the name of the patch
              iny
              iny
              iny
              iny
              lda     [.tiny (_Dp+8)],y
              asl     a
              asl     a
              asl     a
              clc
              adc     .near RD_NAME
              sta     dp:.tiny _Dp
              lda     .near (RD_NAME+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              jsl     long:W_GetNumForName  ; patch_num
              pha
              lda     .near RD_X
              clc
              adc     ##OFS_TP_PATCHNUM
              tay
              pla
              sta     [.tiny (_Dp+12)],y
              jsl     long:V_NumPatchWidth  ; patch_width
              pha
              lda     .near RD_X
              clc
              adc     ##OFS_TP_PATCHWIDTH
              tay
              pla
              sta     [.tiny (_Dp+12)],y
              inc     .near RD_J
3$:           lda     .near RD_J
              cmp     .near RD_N
              bcc     2$
              stz     .near RD_J            ; overlapping patches
4$:           lda     .near RD_J
              cmp     .near RD_N
              bcs     8$
              asl     a                     ; l1 = originx
              asl     a
              asl     a
              adc     ##OFS_TEX_PATCHES
              tay
              lda     [.tiny (_Dp+12)],y
              sta     .near RD_X
              tya                           ; r1 = l1 + patch_width
              clc
              adc     ##OFS_TP_PATCHWIDTH
              tay
              lda     [.tiny (_Dp+12)],y
              clc
              adc     .near RD_X
              sta     .near RD_W
              lda     .near RD_J
              inc     a
              sta     .near RD_K
5$:           lda     .near RD_K
              cmp     .near RD_N
              bcs     7$
              asl     a                     ; l2
              asl     a
              asl     a
              adc     ##OFS_TEX_PATCHES
              tay
              lda     [.tiny (_Dp+12)],y
              sta     .near RD_T
              tya                           ; r2 = l2 + patch_width
              clc
              adc     ##OFS_TP_PATCHWIDTH
              tay
              lda     [.tiny (_Dp+12)],y
              clc
              adc     .near RD_T
              sta     .near (RD_T+2)
              lda     .near RD_T            ; r1 > l2: l2 - r1 < 0
              sec
              sbc     .near RD_W
              bvc     51$
              eor     ##0x8000
51$:          bpl     6$
              lda     .near RD_X            ; l1 < r2
              sec
              sbc     .near (RD_T+2)
              bvc     52$
              eor     ##0x8000
52$:          bpl     6$
              sep     #0x20                 ; overlapped
              lda     #1
              ldy     ##OFS_TEX_OVERLAPPED
              sta     [.tiny (_Dp+12)],y
              rep     #0x20
              bra     8$
6$:           inc     .near RD_K
              bra     5$
7$:           inc     .near RD_J
              bra     4$
8$:           lda     .near textureheight   ; textureheight[n] = height
              sta     dp:.tiny _Dp
              lda     .near (textureheight+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_TEX_HEIGHT
              lda     [.tiny (_Dp+12)],y
              tax
              lda     .near RD_TEXNUM
              asl     a
              tay
              txa
              sta     [.tiny _Dp],y
              lda     .near texturetranslation ; texturetranslation[n] = n
              sta     dp:.tiny _Dp
              lda     .near (texturetranslation+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near RD_TEXNUM
              sta     [.tiny _Dp],y
              asl     a                     ; textures[n] = texture
              asl     a
              tay
              lda     .near textures
              sta     dp:.tiny _Dp
              lda     .near (textures+2)
              sta     dp:.tiny (_Dp+2)
              lda     dp:.tiny (_Dp+12)
              sta     [.tiny _Dp],y
              iny
              iny
              lda     dp:.tiny (_Dp+14)
              sta     [.tiny _Dp],y
              pla
              sta     dp:.tiny (_Dp+14)
              pla
              sta     dp:.tiny (_Dp+12)
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              rts

;;; ---------------------------------------------------------------------------
;;; int16_t R_CheckTextureNumForName(const char* tex_name)  In: _Dp[0-3].
;;; 0 for "-" (no texture), else the first texture of the name in
;;; TEXTURE1 (8 characters or up to a 0); I_Error if none.
;;; ---------------------------------------------------------------------------
              .public R_CheckTextureNumForName
R_CheckTextureNumForName:
              lda     [.tiny _Dp]
              and     ##0x00ff
              cmp     ##'-'
              bne     1$
              lda     ##0
              rtl
1$:           lda     dp:.tiny _Dp          ; name8 = strncpy(tex_name, 8)
              sta     .near RD_NAME
              lda     dp:.tiny (_Dp+2)
              sta     .near (RD_NAME+2)
              ldy     ##0
              sep     #0x20
2$:           lda     [.tiny _Dp],y
              beq     3$
              sta     abs:.near RD_NAME8,y
              iny
              cpy     ##8
              bcc     2$
              bra     4$
3$:           sta     abs:.near RD_NAME8,y
              iny
              cpy     ##8
              bcc     3$
4$:           rep     #0x20
              ldx     ##.word0 strTexture1  ; each texture
              lda     ##.word2 strTexture1
              jsr     .kbank namePtr
              jsr     .kbank lumpByName
              sta     .near RD_A
              stx     .near (RD_A+2)
              stz     .near RD_I
5$:           lda     .near RD_I
              cmp     .near numtextures
              bcs     8$
              lda     .near RD_A            ; mtexture = maptex + directory[i]
              sta     dp:.tiny _Dp
              lda     .near (RD_A+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near RD_I
              inc     a
              asl     a
              asl     a
              tay
              lda     [.tiny _Dp],y
              pha
              iny
              iny
              lda     [.tiny _Dp],y
              tax
              pla
              clc
              adc     dp:.tiny _Dp
              sta     dp:.tiny _Dp
              txa
              adc     dp:.tiny (_Dp+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##6                   ; the same 8 bytes
6$:           lda     [.tiny _Dp],y
              cmp     abs:.near RD_NAME8,y
              bne     7$
              dey
              dey
              bpl     6$
              lda     .near RD_I
              rtl
7$:           inc     .near RD_I
              bra     5$
8$:           lda     .near (RD_NAME+2)
              pha
              lda     .near RD_NAME
              pha
              lda     ##.word0 errTexture
              sta     dp:.tiny _Dp
              lda     ##.word2 errTexture
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error

;;; ---------------------------------------------------------------------------
;;; int16_t V_NumPatchWidth(int16_t num)            In: C. The width.
;;; void V_DrawRawFullScreen(int16_t num)           V_DrawRaw(num, 0)
;;; void V_DrawNumPatchScaled(int16_t x, int16_t y, int16_t num)
;;; void V_DrawNumPatchNotScaled(int16_t x, int16_t y, int16_t num)
;;;   In: C = x, _Dp[0-1] = y, _Dp[4-5] = num.
;;; ---------------------------------------------------------------------------
              .public V_NumPatchWidth, V_DrawRawFullScreen
              .public V_DrawNumPatchScaled, V_DrawNumPatchNotScaled
V_NumPatchWidth:
              jsl     long:W_GetLumpByNum
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp]           ; (OFS_PATCH_WIDTH)
              rtl
V_DrawRawFullScreen:
              stz     dp:.tiny _Dp
              jmp     long:V_DrawRaw
V_DrawNumPatchScaled:
              jsr     .kbank numPatch
              jmp     long:V_DrawPatchScaled
V_DrawNumPatchNotScaled:
              jsr     .kbank numPatch
              jmp     long:V_DrawPatchNotScaled

;;; numPatch: _Dp[4-7] = the lump _Dp[4-5]; C and _Dp[0-1] stay.
numPatch:     pha
              pei     dp:.tiny _Dp
              lda     dp:.tiny (_Dp+4)
              jsl     long:W_GetLumpByNum
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              pla
              sta     dp:.tiny _Dp
              pla
              rts

;;; ---------------------------------------------------------------------------
;;; void R_DrawSky(draw_column_vars_t* dcvars)      In: _Dp[0-3].
;;; The column of the sky patch at the angle of dcvars->x, full bright (or
;;; the fixed colormap); without a patch the flat sky color.
;;; ---------------------------------------------------------------------------
              .public R_DrawSky
R_DrawSky:    lda     .near skypatch
              ora     .near (skypatch+2)
              bne     1$
              lda     ##FLAT_SKY_COLOR
              jmp     long:R_DrawColumnFlat
1$:           lda     ##0                   ; texturemid = 100 << FRACBITS
              ldy     ##OFS_DC_TEXTUREMID
              sta     [.tiny _Dp],y
              lda     ##100
              iny
              iny
              sta     [.tiny _Dp],y
              lda     .near fixedcolormap   ; colormap: fixed, else full
              ldx     .near (fixedcolormap+2)
              bne     2$
              cmp     ##0
              bne     2$
              lda     ##.word0 fullcolormap
              ldx     ##.word2 fullcolormap
2$:           ldy     ##OFS_DC_COLORMAP
              sta     [.tiny _Dp],y
              txa
              iny
              iny
              sta     [.tiny _Dp],y
              lda     ##SKYFRACSTEP
              ldy     ##OFS_DC_FRACSTEP
              sta     [.tiny _Dp],y
              lda     [.tiny _Dp]           ; xc: the angle of column x,
              asl     a                     ; >> SKYSHIFT (arithmetic), in
              tax                           ; the width mask
              lda     .near (viewangle+2)
              clc
              adc     .near xtoviewangleTable,x
              ldx     ##SKYSHIFT
3$:           cmp     ##0x8000
              ror     a
              dex
              bne     3$
              and     .near skywidthmask
              asl     a                     ; source = the column + 3
              asl     a
              clc
              adc     ##OFS_PATCH_COLUMNOFS
              tay
              lda     .near skypatch
              sta     dp:.tiny (_Dp+4)
              lda     .near (skypatch+2)
              sta     dp:.tiny (_Dp+6)
              lda     [.tiny (_Dp+4)],y
              clc
              adc     ##3
              clc
              adc     dp:.tiny (_Dp+4)
              ldy     ##OFS_DC_SOURCE
              sta     [.tiny _Dp],y
              lda     dp:.tiny (_Dp+6)
              adc     ##0
              iny
              iny
              sta     [.tiny _Dp],y
              jmp     long:R_DrawColumnWall

;;; ---------------------------------------------------------------------------
;;; void P_UpdateAnimatedFlat(void): the nukage flat of the level time.
;;; ---------------------------------------------------------------------------
              .public P_UpdateAnimatedFlat
P_UpdateAnimatedFlat:
              lda     .near _g_leveltime    ; (leveltime >> 3) % 3, unsigned: flats
              lsr     a                     ;   0-2 are NUKAGE1-3. A signed shift
              lsr     a                     ;   went negative after 32,768 tics and
              lsr     a                     ;   drew flats -1 and -2 (the user's
              ldx     ##3                   ;   blue/green flashing in E1M1).
              jsl     long:_Mod16
              sta     .near nukage
              rtl
              .space  9                     ; Keep later code at its slots.

;;; ---------------------------------------------------------------------------
;;; void R_InitColormaps(void): the COLORMAP lump to fullcolormap.
;;; void R_InitSpriteLumps(void): the sprite lumps between S_START, S_END.
;;; ---------------------------------------------------------------------------
              .public R_InitColormaps, R_InitSpriteLumps
R_InitColormaps:
              ldx     ##.word0 strColormap
              lda     ##.word2 strColormap
              jsr     .kbank namePtr
              jsl     long:W_GetNumForName
              ldx     ##.word0 fullcolormap
              stx     dp:.tiny _Dp
              ldx     ##.word2 fullcolormap
              stx     dp:.tiny (_Dp+2)
              jmp     long:W_ReadLumpByNum
R_InitSpriteLumps:
              ldx     ##.word0 strSStart
              lda     ##.word2 strSStart
              jsr     .kbank namePtr
              jsl     long:W_GetNumForName
              inc     a
              sta     .near firstspritelump
              ldx     ##.word0 strSEnd      ; numentries = (S_END - 1) - first + 1
              lda     ##.word2 strSEnd
              jsr     .kbank namePtr
              jsl     long:W_GetNumForName
              sec
              sbc     .near firstspritelump
              sta     .near numentries
              rtl

;;; ---------------------------------------------------------------------------
;;; void R_InitSpriteScales(void): the tables of PROJECTION / d and
;;; (PROJECTIONY << FRACBITS) / d, d = 1..1280, of R_ProjectSprite.
;;; ---------------------------------------------------------------------------
              .public R_InitSpriteScales
R_InitSpriteScales:
              lda     ##1
              sta     .near RD_I
1$:           lda     .near RD_I            ; xscale[d]
              asl     a
              asl     a
              sta     .near RD_X
              lda     ##(CONST_VIEWWIDTH / 2)
              jsr     .kbank divD
              ldx     .near RD_X
              sta     long:SPRXSCALE_ADDR,x
              lda     .near RD_T
              sta     long:(SPRXSCALE_ADDR+2),x
              lda     ##CONST_PROJECTIONY   ; yscale[d]
              jsr     .kbank divD
              ldx     .near RD_X
              sta     long:SPRYSCALE_ADDR,x
              lda     .near RD_T
              sta     long:(SPRYSCALE_ADDR+2),x
              inc     .near RD_I
              lda     .near RD_I
              cmp     ##(MAXZ_HI+1)
              bcc     1$
              rtl

;;; divD: C = the low word of (C << 16) / RD_I, RD_T = the high word.
divD:         sta     dp:.tiny (_Dp+2)
              stz     dp:.tiny _Dp
              lda     .near RD_I
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              jsl     long:_Div32
              stx     .near RD_T
              rts

;;; ---------------------------------------------------------------------------
;;; boolean R_PointOnSegSide(fixed_t x, fixed_t y, const seg_t __far* line)
;;;   In: X:C = x, _Dp[0-3] = y, _Dp[4-7] = line. Out: C = 1 for the back.
;;; ---------------------------------------------------------------------------
              .public R_PointOnSegSide
R_PointOnSegSide:
              sta     .near RD_A            ; x
              stx     .near (RD_A+2)
              ldy     ##(OFS_SEG_V2+2)      ; ldy
              lda     [.tiny (_Dp+4)],y
              ldy     ##(OFS_SEG_V1+2)
              sec
              sbc     [.tiny (_Dp+4)],y
              sta     .near RD_K
              ldy     ##OFS_SEG_V2          ; ldx
              lda     [.tiny (_Dp+4)],y
              ldy     ##OFS_SEG_V1
              sec
              sbc     [.tiny (_Dp+4)],y
              sta     .near RD_J
              bne     psLdy
              lda     ##0                   ; !ldx: x <= lx << 16 ? ldy > 0 :
              sec                           ;   ldy < 0
              sbc     .near RD_A
              lda     [.tiny (_Dp+4)],y     ; ((lx << 16) - x >= 0)
              sbc     .near (RD_A+2)
              bvc     psX1
              eor     ##0x8000
psX1:         bmi     psYNeg
psYPos:       lda     .near RD_K            ; ldy > 0
              beq     psNo
              bmi     psNo
psYes:        lda     ##1
              rtl
psYNeg:       lda     .near RD_K            ; ldy < 0
              bmi     psYes
psNo:         lda     ##0
              rtl
psLdy:        lda     .near RD_K
              bne     psSigns
              lda     ##0                   ; !ldy: y <= ly << 16 ? ldx < 0 :
              sec                           ;   ldx > 0
              sbc     dp:.tiny _Dp
              ldy     ##(OFS_SEG_V1+2)
              lda     [.tiny (_Dp+4)],y
              sbc     dp:.tiny (_Dp+2)
              bvc     psY1
              eor     ##0x8000
psY1:         bmi     psXPos
              lda     .near RD_J            ; ldx < 0
              bmi     psYes
              bra     psNo
psXPos:       lda     .near RD_J            ; ldx > 0
              beq     psNo
              bmi     psNo
              bra     psYes
psSigns:      ldy     ##OFS_SEG_V1          ; x -= lx << 16, y -= ly << 16
              lda     .near (RD_A+2)
              sec
              sbc     [.tiny (_Dp+4)],y
              sta     .near (RD_A+2)
              ldy     ##(OFS_SEG_V1+2)
              lda     dp:.tiny (_Dp+2)
              sec
              sbc     [.tiny (_Dp+4)],y
              sta     dp:.tiny (_Dp+2)
              eor     .near (RD_A+2)        ; the signs of ldy, ldx, x, y
              eor     .near RD_J
              eor     .near RD_K
              bpl     psProducts
              lda     .near RD_K            ; ldy ^ x < 0
              eor     .near (RD_A+2)
              bmi     psYes
              bra     psNo
psProducts:   lda     dp:.tiny _Dp          ; FixedMul3216(y, ldx) >=
              ldx     dp:.tiny (_Dp+2)      ;   FixedMul3216(x, ldy)
              ldy     .near RD_J
              sty     dp:.tiny _Dp
              jsl     long:FixedMul3216
              sta     .near RD_T
              stx     .near (RD_T+2)
              lda     .near RD_K
              sta     dp:.tiny _Dp
              lda     .near RD_A
              ldx     .near (RD_A+2)
              jsl     long:FixedMul3216
              sta     .near RD_U
              stx     .near (RD_U+2)
              lda     .near RD_T
              cmp     .near RD_U
              lda     .near (RD_T+2)
              sbc     .near (RD_U+2)
              bvc     psP1
              eor     ##0x8000
psP1:         bmi     psP2
              lda     ##1
              rtl
psP2:         lda     ##0
              rtl

;;; ---------------------------------------------------------------------------
;;; void R_MakeLevelColumns(int16_t numsides)       In: C.
;;; The column tables of the textures of the sides, at level load: the
;;; directory at COLDIR_ADDR (a table address with the width mask in its
;;; top byte for each texture), the tables and columns after it. The same
;;; map again (a new life) keeps the tables it has (LC_MAP).
;;; ---------------------------------------------------------------------------
              .public R_MakeLevelColumns, R_MakeTextureColumns
R_MakeLevelColumns:
              sta     .near LC_N
              lda     .near _g_gamemap      ; the tables of this map are there:
              cmp     long:LC_MAP           ;   nothing to do
              bne     10$
              rtl
10$:          sta     long:LC_MAP
              lda     ##.word0 COLDIR_ADDR
              sta     dp:.tiny _Dp
              lda     ##.word2 COLDIR_ADDR
              sta     dp:.tiny (_Dp+2)
              lda     ##COLDIR_SIZE
              sta     dp:.tiny (_Dp+4)
              lda     ##0
              jsl     long:memset
              lda     long:W_COLSTART       ; after the lumps of the map in the
              sta     .near colmem          ;   level window (src/iigs/w_level65.s)
              lda     long:(W_COLSTART+2)
              sta     .near (colmem+2)
              jsl     long:cmPass1          ; the hot textures first (cmSkip)
2$:           stz     .near LC_I
              stz     .near LC_X            ; the offset of side i
1$:           lda     .near LC_I
              cmp     .near LC_N
              bcs     9$
              ldy     ##OFS_SIDE_TOPTEXTURE ; top, middle, bottom
              jsr     .kbank sideColumns
              ldy     ##OFS_SIDE_MIDTEXTURE
              jsr     .kbank sideColumns
              ldy     ##OFS_SIDE_BOTTOMTEXTURE
              jsr     .kbank sideColumns
              lda     .near LC_X
              clc
              adc     ##SIZEOF_SIDE
              sta     .near LC_X
              inc     .near LC_I
              bra     1$
9$:           jsl     long:cmPass2          ; then the others
              bcs     2$
              rtl

;;; sideColumns: the columns of the texture at offset Y of side LC_X, if it
;;; is not 0, has none yet and belongs to this pass.
sideColumns:  tya
              clc
              adc     .near LC_X
              tay
              lda     .near _g_sides
              sta     dp:.tiny _Dp
              lda     .near (_g_sides+2)
              sta     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp],y
              beq     1$
              pha
              asl     a
              asl     a
              tax
              lda     long:COLDIR_ADDR,x
              ora     long:(COLDIR_ADDR+2),x
              tax
              pla
              cpx     ##0
              bne     1$
              jsl     long:cmSkip
              bcs     1$
              jsl     long:R_MakeTextureColumns
1$:           rts

;;; ---------------------------------------------------------------------------
;;; void R_MakeTextureColumns(int16_t texnum)       In: C.
;;; The column table of a texture: for each column xc (to the width mask)
;;; the address of its texels: the column of its patch (as R_GetColumn),
;;; or a composed column for overlapping patches; 0 with a 1 in its top
;;; byte for no column.
;;; ---------------------------------------------------------------------------
R_MakeTextureColumns:
              pei     dp:.tiny (_Dp+8)      ; _Dp+8: the texture
              pei     dp:.tiny (_Dp+10)
              pei     dp:.tiny (_Dp+12)     ; _Dp+12: the column table
              pei     dp:.tiny (_Dp+14)
              pha
              jsl     long:R_GetTexture
              sta     dp:.tiny (_Dp+8)
              stx     dp:.tiny (_Dp+10)
              ldy     ##OFS_TEX_WIDTHMASK   ; table: (widthmask + 1) * 4 bytes
              lda     [.tiny (_Dp+8)],y
              inc     a
              sta     .near RD_W
              asl     a
              asl     a
              jsr     .kbank columnAlloc
              sta     dp:.tiny (_Dp+12)
              stx     dp:.tiny (_Dp+14)
              stz     .near RD_X            ; each column xc
1$:           lda     .near RD_X
              cmp     .near RD_W
              bcc     2$
              brl     20$
2$:           stz     .near RD_A
              stz     .near (RD_A+2)
              ldy     ##OFS_TEX_OVERLAPPED
              lda     [.tiny (_Dp+8)],y
              and     ##0x00ff
              beq     3$
              jsr     .kbank composedColumn
              brl     10$
3$:           lda     ##0xffff              ; pnum = -1, x = xc
              sta     .near RD_PNUM
              lda     .near RD_X
              sta     .near RD_J
              ldy     ##OFS_TEX_PATCHCOUNT
              lda     [.tiny (_Dp+8)],y
              and     ##0x00ff
              sta     .near RD_N
              cmp     ##1
              bne     4$
              ldy     ##(OFS_TEX_PATCHES+OFS_TP_PATCHNUM)
              lda     [.tiny (_Dp+8)],y
              sta     .near RD_PNUM
              bra     8$
4$:           stz     .near RD_I            ; the first patch over xc
5$:           lda     .near RD_I
              cmp     .near RD_N
              bcs     8$
              asl     a
              asl     a
              asl     a
              adc     ##OFS_TEX_PATCHES
              tay
              lda     .near RD_X            ; x = xc - originx >= 0
              sec
              sbc     [.tiny (_Dp+8)],y
              sta     .near RD_J
              bvc     51$
              eor     ##0x8000
51$:          bmi     6$
              tya                           ; x < patch_width
              clc
              adc     ##OFS_TP_PATCHWIDTH
              tay
              lda     .near RD_J
              sec
              sbc     [.tiny (_Dp+8)],y
              bvc     52$
              eor     ##0x8000
52$:          bpl     6$
              dey
              dey
              lda     [.tiny (_Dp+8)],y
              sta     .near RD_PNUM
              bra     8$
6$:           inc     .near RD_I
              bra     5$
8$:           lda     .near RD_PNUM         ; src = patch + columnofs[x] + 3
              bmi     10$
              jsl     long:W_GetLumpByNum
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near RD_J
              asl     a
              asl     a
              clc
              adc     ##OFS_PATCH_COLUMNOFS
              tay
              lda     [.tiny _Dp],y
              clc
              adc     ##3
              clc
              adc     dp:.tiny _Dp
              sta     .near RD_A
              lda     dp:.tiny (_Dp+2)
              adc     ##0
              sta     .near (RD_A+2)
10$:          lda     .near RD_X            ; entry[xc] = src (0: a 1 on top)
              asl     a
              asl     a
              tay
              lda     .near RD_A
              sta     [.tiny (_Dp+12)],y
              iny
              iny
              lda     .near (RD_A+2)
              ora     .near RD_A
              bne     11$
              lda     ##0x0100
              bra     12$
11$:          lda     .near (RD_A+2)
12$:          sta     [.tiny (_Dp+12)],y
              inc     .near RD_X
              brl     1$
20$:          pla                           ; dir[texnum] = table, the width
              asl     a                     ; mask in its top byte
              asl     a
              tax
              lda     dp:.tiny (_Dp+12)
              sta     long:COLDIR_ADDR,x
              ldy     ##OFS_TEX_WIDTHMASK
              lda     [.tiny (_Dp+8)],y
              xba
              and     ##0xff00
              ora     dp:.tiny (_Dp+14)
              sta     long:(COLDIR_ADDR+2),x
              pla
              sta     dp:.tiny (_Dp+14)
              pla
              sta     dp:.tiny (_Dp+12)
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              rtl

;;; columnAlloc, columnAllocC (a composed column): X:C =
;;; R_ColumnAlloc(C): colAllocL, colAllocH (cold, bank 5).
columnAlloc:  jsl     long:colAllocL
              rts
columnAllocC: jsl     long:colAllocH
              rts
colError:     lda     ##.word0 errColumns   ; colAllocL: no room
              sta     dp:.tiny _Dp
              lda     ##.word2 errColumns
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
;;; CM_COLD: a bit for each texture (TEXTURE1 of DOOM1.WAD), 0 for the hot
;;; ones: the table and column reads a frame of GEOMETRY's profiles of
;;; demo1-3 and the user's session (2026-09-27), 40 or more in one of them:
;;; BIGDOOR2 BRNPOIS2 BROWN1 BROWN144 BROWN96 BROWNGRN COMPTALL COMPUTE2
;;; DOOR3 DOORSTOP DOORYEL EXITDOOR GRAYTALL LITE3 LITE4 LITEBLU3 METAL1
;;; SLADWALL STARG1 STARG3 STARGR1 STARTAN1 STARTAN2 STARTAN3 STEP1 STEP6
;;; STONE SUPPORT2 SW1COMP SW2COMP TEKWALL1 TEKWALL4. (A byte more for the
;;; 16-bit read of texture 255.)
CM_COLD:      .byte   0xfb, 0x3e, 0xfc, 0xb6, 0xe5, 0xe5, 0xfa, 0xff
              .byte   0x00, 0xcf, 0xfd, 0xfe, 0xff, 0xf7, 0xff, 0xf6
              .byte   0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
              .byte   0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
              .byte   0x00
              .space  53 - 5 - 14 - 33      ; (farcode keeps its layout)

;;; composedColumn: RD_A = R_ComposedColumn(the texture at _Dp[8-11],
;;; column RD_X): the texels of the one patch post that covers the whole
;;; column, else a new column (0 filled) with the posts of all the patches
;;; over it.
composedColumn:
              ldy     ##OFS_TEX_HEIGHT
              lda     [.tiny (_Dp+8)],y
              sta     .near RD_HEIGHT
              ldy     ##OFS_TEX_PATCHCOUNT
              lda     [.tiny (_Dp+8)],y
              and     ##0x00ff
              sta     .near RD_N
              stz     .near RD_COVERS
              stz     .near RD_ONLYY
              stz     .near RD_I            ; the patches over column xc
1$:           lda     .near RD_I
              cmp     .near RD_N
              bcs     3$
              jsr     .kbank patchColumn
              bcc     2$
              inc     .near RD_COVERS       ; only = the column, onlyy
              lda     dp:.tiny _Dp
              sta     .near RD_ONLY
              lda     dp:.tiny (_Dp+2)
              sta     .near (RD_ONLY+2)
              jsr     .kbank originY
              sta     .near RD_ONLYY
2$:           inc     .near RD_I
              bra     1$
3$:           lda     .near RD_COVERS       ; one post from the top of the
              cmp     ##1                   ; column, not shorter, and no more
              bne     4$                    ; posts: its texels
              lda     .near RD_ONLYY
              bne     4$
              lda     .near RD_ONLY
              sta     dp:.tiny _Dp
              lda     .near (RD_ONLY+2)
              sta     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp]           ; topdelta 0
              and     ##0x00ff
              bne     4$
              lda     [.tiny _Dp]           ; length >= height
              xba
              and     ##0x00ff
              sec
              sbc     .near RD_HEIGHT
              bvc     31$
              eor     ##0x8000
31$:          bmi     4$
              lda     [.tiny _Dp]           ; only[length + 4] == 0xff
              xba
              and     ##0x00ff
              clc
              adc     ##4
              tay
              lda     [.tiny _Dp],y
              and     ##0x00ff
              cmp     ##0x00ff
              bne     4$
              lda     .near RD_ONLY
              clc
              adc     ##3
              sta     .near RD_A
              lda     .near (RD_ONLY+2)
              adc     ##0
              sta     .near (RD_A+2)
              rts
4$:           lda     .near RD_HEIGHT       ; a new column, 0 filled
              jsr     .kbank columnAllocC
              sta     .near RD_A
              stx     .near (RD_A+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near RD_HEIGHT
              sta     dp:.tiny (_Dp+4)
              lda     ##0
              jsl     long:memset
              stz     .near RD_I            ; the posts of each patch
5$:           lda     .near RD_I
              cmp     .near RD_N
              bcs     7$
              jsr     .kbank patchColumn
              bcc     6$
              jsr     .kbank originY
              sta     .near RD_ONLYY
              jsr     .kbank drawColumnInColumn
6$:           inc     .near RD_I
              bra     5$
7$:           rts

;;; originY: C = the originy of patch RD_I of the texture at _Dp[8-11].
originY:      lda     .near RD_I
              asl     a
              asl     a
              asl     a
              clc
              adc     ##(OFS_TEX_PATCHES+OFS_TP_ORIGINY)
              tay
              lda     [.tiny (_Dp+8)],y
              rts

;;; patchColumn: carry set if patch RD_I of the texture at _Dp[8-11]
;;; covers column RD_X (x = xc - originx, 0 <= x < the patch width):
;;; _Dp[0-3] = the column x of the patch.
patchColumn:  lda     .near RD_I
              asl     a
              asl     a
              asl     a
              clc
              adc     ##OFS_TEX_PATCHES
              tay
              lda     .near RD_X            ; x = xc - originx
              sec
              sbc     [.tiny (_Dp+8)],y
              sta     .near RD_J
              bvc     1$
              eor     ##0x8000
1$:           bmi     9$
              tya
              clc
              adc     ##OFS_TP_PATCHNUM
              tay
              lda     [.tiny (_Dp+8)],y
              jsl     long:W_GetLumpByNum
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near RD_J            ; x < width
              sec
              sbc     [.tiny _Dp]
              bvc     2$
              eor     ##0x8000
2$:           bpl     9$
              lda     .near RD_J            ; the column
              asl     a
              asl     a
              clc
              adc     ##OFS_PATCH_COLUMNOFS
              tay
              lda     [.tiny _Dp],y
              clc
              adc     dp:.tiny _Dp
              sta     dp:.tiny _Dp
              bcc     3$
              inc     dp:.tiny (_Dp+2)
3$:           sec
              rts
9$:           clc
              rts

;;; drawColumnInColumn: R_DrawColumnInColumn(the column at _Dp[0-3], the
;;; column RD_A, originy RD_ONLYY, height RD_HEIGHT): each post to its rows.
drawColumnInColumn:
              lda     dp:.tiny _Dp
              sta     .near RD_T
              lda     dp:.tiny (_Dp+2)
              sta     .near (RD_T+2)
1$:           lda     .near RD_T
              sta     dp:.tiny (_Dp+4)
              lda     .near (RD_T+2)
              sta     dp:.tiny (_Dp+6)
              lda     [.tiny (_Dp+4)]       ; topdelta 0xff: the end
              and     ##0x00ff
              cmp     ##0x00ff
              bne     2$
              rts
2$:           clc                           ; position = originy + topdelta
              adc     .near RD_ONLYY
              sta     .near RD_K
              lda     [.tiny (_Dp+4)]       ; count = length
              xba
              and     ##0x00ff
              sta     .near RD_J
              lda     .near RD_K            ; position < 0: count += position,
              bpl     3$                    ;   position = 0
              clc
              adc     .near RD_J
              sta     .near RD_J
              stz     .near RD_K
3$:           lda     .near RD_K            ; position + count > height:
              clc                           ;   count = height - position
              adc     .near RD_J
              sec
              sbc     .near RD_HEIGHT
              bvc     4$
              eor     ##0x8000
4$:           bmi     5$
              beq     5$
              lda     .near RD_HEIGHT
              sec
              sbc     .near RD_K
              sta     .near RD_J
5$:           lda     .near RD_J            ; count > 0: memcpy(cache +
              beq     6$                    ;   position, source, count)
              bmi     6$
              lda     .near RD_K
              clc
              adc     .near RD_A
              sta     dp:.tiny _Dp
              lda     .near (RD_A+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              lda     .near RD_T
              clc
              adc     ##3
              sta     dp:.tiny (_Dp+4)
              lda     .near (RD_T+2)
              adc     ##0
              sta     dp:.tiny (_Dp+6)
              lda     .near RD_J
              jsl     long:memcpy
6$:           lda     .near RD_T            ; the next post: + length + 4
              sta     dp:.tiny (_Dp+4)
              lda     .near (RD_T+2)
              sta     dp:.tiny (_Dp+6)
              lda     [.tiny (_Dp+4)]
              xba
              and     ##0x00ff
              clc
              adc     ##4
              clc
              adc     .near RD_T
              sta     .near RD_T
              bcc     7$
              inc     .near (RD_T+2)
7$:           brl     1$

;;; ---------------------------------------------------------------------------
;;; void R_InitSprites(void): the frames of each sprite from the sprite
;;; lump names (4 letters, a frame letter and a rotation digit, maybe a
;;; second frame and rotation for the flipped lump), found through a hash
;;; of the 4 letters.
;;; ---------------------------------------------------------------------------
              .public R_InitSprites
R_InitSprites:
              lda     .near numentries      ; no sprite lumps: none
              bne     2$
              rtl
2$:           lda     ##(4 * CONST_NUMSPRITES) ; sprites: 0 filled
              jsr     .kbank allocZero
              sta     .near sprites
              stx     .near (sprites+2)
              lda     ##(MAXSPRITEFRAMES * SIZEOF_SF)
              jsl     long:Z_MallocStatic
              sta     .near sprtemp
              stx     .near (sprtemp+2)
              lda     .near numentries      ; the hash chains: index, next
              asl     a
              asl     a
              jsl     long:Z_MallocStatic
              sta     .near RD_HASH
              stx     .near (RD_HASH+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldy     ##0                   ; all empty
              lda     ##0xffff
              ldx     .near numentries
3$:           sta     [.tiny _Dp],y
              iny
              iny
              iny
              iny
              dex
              bne     3$
              stz     .near RD_I            ; each lump on the front of its
4$:           lda     .near RD_I            ; chain (later ones first)
              cmp     .near numentries
              bcs     5$
              clc
              adc     .near firstspritelump
              jsl     long:W_GetNameForNum
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              jsr     .kbank nameHash
              asl     a                     ; hash[i].next = hash[j].index
              asl     a
              tay
              jsr     .kbank hashPtr
              lda     [.tiny _Dp],y
              pha
              lda     .near RD_I            ; hash[j].index = i
              sta     [.tiny _Dp],y
              asl     a
              asl     a
              tay
              pla
              iny
              iny
              sta     [.tiny _Dp],y
              inc     .near RD_I
              bra     4$
5$:           stz     .near RD_I            ; each sprite name
6$:           lda     .near RD_I
              cmp     ##CONST_NUMSPRITES
              bcc     7$
              brl     30$
7$:           asl     a                     ; the name: sprnames + 4 i
              asl     a
              clc
              adc     ##.word0 sprnames
              sta     .near RD_NAME
              sta     dp:.tiny _Dp
              lda     ##.word2 sprnames
              sta     .near (RD_NAME+2)
              sta     dp:.tiny (_Dp+2)
              jsr     .kbank nameHash       ; j = hash[h].index
              asl     a
              asl     a
              tay
              jsr     .kbank hashPtr
              lda     [.tiny _Dp],y
              bpl     8$
              brl     29$
8$:           sta     .near RD_J
              lda     .near sprtemp         ; sprtemp: all -1
              sta     dp:.tiny _Dp
              lda     .near (sprtemp+2)
              sta     dp:.tiny (_Dp+2)
              lda     ##(MAXSPRITEFRAMES * SIZEOF_SF)
              sta     dp:.tiny (_Dp+4)
              lda     ##0xffff
              jsl     long:memset
              lda     ##0xffff
              sta     .near maxframe
9$:           lda     .near RD_J            ; each lump of the chain
              clc
              adc     .near firstspritelump
              sta     .near RD_PNUM
              jsl     long:W_GetNameForNum
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              lda     .near RD_NAME
              sta     dp:.tiny _Dp
              lda     .near (RD_NAME+2)
              sta     dp:.tiny (_Dp+2)
              lda     [.tiny (_Dp+4)]       ; the same 4 letters
              cmp     [.tiny _Dp]
              bne     11$
              ldy     ##2
              lda     [.tiny (_Dp+4)],y
              cmp     [.tiny _Dp],y
              bne     11$
              ldy     ##4                   ; frame sn[4] - 'A', rotation
              lda     [.tiny (_Dp+4)],y     ;   sn[5] - '0'
              stz     .near RD_W
              jsr     .kbank installLump
              ldy     ##6                   ; sn[6]: the flipped frame
              lda     [.tiny (_Dp+4)],y
              bit     ##0x00ff
              beq     11$
              ldx     ##1
              stx     .near RD_W
              jsr     .kbank installLump
11$:          lda     .near RD_J            ; j = hash[j].next
              asl     a
              asl     a
              tay
              iny
              iny
              jsr     .kbank hashPtr
              lda     [.tiny _Dp],y
              sta     .near RD_J
              bpl     9$
              inc     .near maxframe        ; the frames that were found
              bne     12$
              brl     29$
12$:          stz     .near RD_K            ; each frame: complete
13$:          lda     .near RD_K
              cmp     .near maxframe
              bcs     20$
              jsr     .kbank tempFrame
              ldy     ##OFS_SF_ROTATE
              lda     [.tiny _Dp],y
              beq     19$                   ; false: only the first rotation
              cmp     ##1
              beq     14$
              lda     ##.word0 errNoPatch   ; no rotation at all
              ldx     ##.word2 errNoPatch
              brl     frameError
14$:          ldy     ##(2 * 7)             ; true: all 8 rotations
15$:          lda     [.tiny _Dp],y
              cmp     ##0xffff
              beq     16$
              dey
              dey
              bpl     15$
              bra     19$
16$:          lda     ##.word0 errRotations
              ldx     ##.word2 errRotations
              brl     frameError
19$:          inc     .near RD_K
              bra     13$
20$:          lda     .near maxframe        ; the frames of the sprite:
              ldx     ##SIZEOF_SF           ;   a copy of sprtemp
              jsl     long:IIGS_MulLo16
              sta     .near RD_T
              jsl     long:Z_MallocStatic
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near sprites         ; sprites[i].spriteframes
              sta     dp:.tiny (_Dp+4)
              lda     .near (sprites+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near RD_I
              asl     a
              asl     a
              tay
              lda     dp:.tiny _Dp
              sta     [.tiny (_Dp+4)],y
              iny
              iny
              lda     dp:.tiny (_Dp+2)
              sta     [.tiny (_Dp+4)],y
              lda     .near sprtemp
              sta     dp:.tiny (_Dp+4)
              lda     .near (sprtemp+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near RD_T
              jsl     long:memcpy
29$:          inc     .near RD_I
              brl     6$
30$:          lda     .near RD_HASH         ; Z_Free(hash), Z_Free(sprtemp)
              sta     dp:.tiny _Dp
              lda     .near (RD_HASH+2)
              sta     dp:.tiny (_Dp+2)
              jsl     long:Z_Free
              lda     .near sprtemp
              sta     dp:.tiny _Dp
              lda     .near (sprtemp+2)
              sta     dp:.tiny (_Dp+2)
              jsl     long:Z_Free
              rtl

;;; frameError: I_Error(the message X:C, the sprite name, 'A' + frame).
frameError:   sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near RD_K
              clc
              adc     ##'A'
              pha
              lda     .near (RD_NAME+2)
              pha
              lda     .near RD_NAME
              pha
              jsl     long:I_Error

;;; hashPtr: _Dp[0-3] = the hash chains. C, Y stay.
hashPtr:      pha
              lda     .near RD_HASH
              sta     dp:.tiny _Dp
              lda     .near (RD_HASH+2)
              sta     dp:.tiny (_Dp+2)
              pla
              rts

;;; tempFrame: _Dp[0-3] = &sprtemp[RD_K].
tempFrame:    lda     .near RD_K
              ldx     ##SIZEOF_SF
              jsl     long:IIGS_MulLo16
              clc
              adc     .near sprtemp
              sta     dp:.tiny _Dp
              lda     .near (sprtemp+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              rts

;;; nameHash: C = R_SpriteNameHash(the name at _Dp[0-3]) % numentries:
;;; s0 - ((s1 * 3 - s3 * 2 - s2) * 2), unsigned 16 bits.
nameHash:     ldy     ##1
              lda     [.tiny _Dp],y
              and     ##0x00ff
              sta     .near RD_T
              asl     a
              clc
              adc     .near RD_T
              sta     .near RD_T
              ldy     ##3
              lda     [.tiny _Dp],y
              and     ##0x00ff
              asl     a
              sta     .near (RD_T+2)
              lda     .near RD_T
              sec
              sbc     .near (RD_T+2)
              sta     .near RD_T
              ldy     ##2
              lda     [.tiny _Dp],y
              and     ##0x00ff
              sta     .near (RD_T+2)
              lda     .near RD_T
              sec
              sbc     .near (RD_T+2)
              asl     a
              sta     .near RD_T
              lda     [.tiny _Dp]
              and     ##0x00ff
              sec
              sbc     .near RD_T
              ldx     .near numentries
              jsl     long:_UDivMod16
              rts

;;; installLump: R_InstallSpriteLump(RD_PNUM, frame: the low byte of C -
;;; 'A', rotation: the high byte - '0', flipped RD_W). _Dp[4-7] stays.
installLump:  pha
              and     ##0x00ff              ; frame (uint8_t)
              sec
              sbc     ##'A'
              and     ##0x00ff
              sta     .near RD_K
              pla
              xba
              and     ##0x00ff
              sec
              sbc     ##'0'
              and     ##0x00ff
              sta     .near RD_X            ; rotation
              lda     .near RD_K            ; frame >= 29 || rotation > 8
              cmp     ##MAXSPRITEFRAMES
              bcs     1$
              lda     .near RD_X
              cmp     ##9
              bcc     2$
1$:           lda     .near RD_PNUM
              pha
              lda     ##.word0 errFrame
              sta     dp:.tiny _Dp
              lda     ##.word2 errFrame
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
2$:           lda     .near RD_K            ; frame > maxframe: maxframe = frame
              sec
              sbc     .near maxframe
              bvc     21$
              eor     ##0x8000
21$:          bmi     22$
              beq     22$
              lda     .near RD_K
              sta     .near maxframe
22$:          jsr     .kbank tempFrame
              lda     .near RD_X
              bne     5$
              sep     #0x20                 ; rotation 0: all free rotations,
              ldy     ##OFS_SF_FLIPMASK     ;   flipmask from 0
              lda     #0
              sta     [.tiny _Dp],y
              rep     #0x20
              ldy     ##0                   ; 2 * r
3$:           lda     [.tiny _Dp],y
              cmp     ##0xffff
              bne     4$
              lda     .near RD_PNUM
              sta     [.tiny _Dp],y
              lda     .near RD_W            ; flipped: the bit of r
              beq     31$
              tya
              lsr     a
              jsr     .kbank orFlip
31$:          lda     ##0                   ; rotate = false
              phy
              ldy     ##OFS_SF_ROTATE
              sta     [.tiny _Dp],y
              ply
4$:           iny
              iny
              cpy     ##16
              bcc     3$
              rts
5$:           dec     a                     ; one rotation (rotation - 1)
              sta     .near RD_X
              asl     a
              tay
              lda     [.tiny _Dp],y
              cmp     ##0xffff
              bne     9$
              lda     .near RD_PNUM
              sta     [.tiny _Dp],y
              lda     .near RD_W            ; flipped: set the bit, else clear
              beq     6$
              lda     .near RD_X
              jsr     .kbank orFlip
              bra     7$
6$:           lda     .near RD_X
              jsr     .kbank flipBit
              eor     ##0xffff
              sep     #0x20
              ldy     ##OFS_SF_FLIPMASK
              and     [.tiny _Dp],y
              sta     [.tiny _Dp],y
              rep     #0x20
7$:           lda     ##1                   ; rotate = true
              ldy     ##OFS_SF_ROTATE
              sta     [.tiny _Dp],y
9$:           rts

;;; orFlip: the flipmask of the frame at _Dp[0-3] |= 1 << C. Y stays.
orFlip:       phy
              jsr     .kbank flipBit
              sep     #0x20
              ldy     ##OFS_SF_FLIPMASK
              ora     [.tiny _Dp],y
              sta     [.tiny _Dp],y
              rep     #0x20
              ply
              rts

;;; flipBit: C = 1 << C (C = 0..7).
flipBit:      tax
              lda     ##1
              cpx     ##0
              beq     2$
1$:           asl     a
              dex
              bne     1$
2$:           rts

              .section znear, bss
              .public fullcolormap, fixedcolormap, textureheight, texturetranslation
fullcolormap: .space  34 * 256        ; the COLORMAP lump: 34 light levels
fixedcolormap: .space 4               ; the colormap of a power, or 0
textureheight: .space 4               ; the height of each texture
texturetranslation: .space 4          ; the texture that each one shows now

;;; ---------------------------------------------------------------------------
;;; The column memory of a level (R_MakeLevelColumns, W_LevelDone of
;;; src/iigs/w_level65.s, needColumns of src/iigs/r_seg65.s): the composed
;;; columns of the textures that the demos and the sessions draw most (hot,
;;; CM_COLD) stay off the replay's cache slots $0900-$1FFF, where their
;;; texel reads would evict the row blocks and the list code: such a column
;;; that would touch them starts at $2000 or $A000 of its bank, and the
;;; range skipped becomes a hole. The other blocks (the column tables, read
;;; in the seg phase when those slots are quiet, and the columns of the
;;; other textures) go first into the holes. Pass 1 makes the hot textures,
;;; pass 2 the others, so the holes fill and the memory stays as it was.
;;; In the cold bank 5 section after the replay's detail code.
;;; ---------------------------------------------------------------------------
              .section detailimg, text
              .public colAllocL, colAllocH, cmPass1, cmPass2, cmSkip
;;; colAllocL (a table), colAllocH (a composed column of texture RD_TEXNUM):
;;; X:C = C bytes of column memory that end OVERREAD bytes or more before
;;; the end of their bank; I_Error after the last bank.
colAllocL:    sta     .near RD_T
              lda     ##0
              bra     colAlloc
colAllocH:    sta     .near RD_T
              lda     .near RD_TEXNUM
              jsr     .kbank cmBit          ; C clear: hot
              lda     ##0
              rol     a
              eor     ##1
colAlloc:     sta     long:CM_HOT
              bne     4$
              tax                           ; cold: the first hole that fits
1$:           txa
              cmp     long:CM_N
              bcs     4$
              lda     long:CM_HE,x
              sec
              sbc     long:CM_HS,x
              cmp     .near RD_T
              bcs     2$
              inx
              inx
              bra     1$
2$:           lda     long:CM_HS,x
              pha
              clc
              adc     .near RD_T
              sta     long:CM_HS,x
              lda     long:CM_HB,x
              tax
              pla
              rtl
4$:           lda     .near RD_T            ; low + size + OVERREAD wraps: the
              clc                           ;   next bank
              adc     .near colmem
              bcs     5$
              adc     ##OVERREAD
              bcc     6$
5$:           stz     .near colmem
              lda     .near (colmem+2)
              tax
              lda     long:W_NEXTBANK,x
              and     ##0x00ff
              beq     9$
              sta     .near (colmem+2)
              jsl     long:W_ZeroBank       ; (zeros after the last column)
6$:           lda     long:CM_HOT           ; hot: a column that would touch
              beq     8$                    ;   the replay slots starts at their
              lda     .near colmem          ;   end
              and     ##0x7fff
              cmp     ##0x2000
              bcs     8$
              adc     .near RD_T
              cmp     ##0x0901
              bcc     8$
              lda     long:CM_N             ; the hole: colmem to that end
              tax
              cmp     ##(2 * CM_MAX)
              bcs     7$
              inc     a
              inc     a
              sta     long:CM_N
7$:           lda     .near colmem
              sta     long:CM_HS,x
              lda     .near (colmem+2)
              sta     long:CM_HB,x
              lda     .near colmem
              and     ##0x8000
              ora     ##0x2000
              sta     .near colmem
              sta     long:CM_HE,x
8$:           lda     .near colmem          ; a = colmem, colmem += size
              pha
              clc
              adc     .near RD_T
              sta     .near colmem
              ldx     .near (colmem+2)
              pla
              rtl
9$:           jmp     long:colError

;;; cmPass1, cmPass2 (R_MakeLevelColumns): pass 1 with no holes; after it
;;; pass 2 (C set), after that the end (C clear).
cmPass1:      lda     ##0
              sta     long:CM_N
              inc     a
              sta     long:CM_PASS
              rtl
cmPass2:      lda     long:CM_PASS
              lsr     a
              sta     long:CM_PASS
              rtl

;;; cmSkip (sideColumns): C set in pass 1 for texture A (kept) when it is
;;; not hot.
cmSkip:       jsr     .kbank cmBit
              bcc     1$
              pha
              lda     long:CM_PASS
              lsr     a
              pla
1$:           rtl

;;; cmBit: C = the CM_COLD bit of texture A (kept): set when not hot.
cmBit:        pha
              lsr     a
              lsr     a
              lsr     a
              tax
              lda     1,s
              and     ##7
              tay
              lda     long:CM_COLD,x
1$:           lsr     a
              dey
              bpl     1$
              pla
              rts
