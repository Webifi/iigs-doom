;;; The level setup in 65816 assembly, Doom8088: Apple IIgs Edition.
;;;
;;; p_setup.c with the same results: the map lumps become the level
;;; data (lines, sides, sectors and subsectors in the zone; segs, nodes,
;;; blockmap and reject in place in the WAD), each sector gets its lines
;;; and a sound origin in the middle of their box, then the things spawn.
;;; The Z_Free calls for lumps (which do nothing) are gone.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "memmap.inc"

              .extern _Dp, IIGS_MulLo16, _UDivMod16, I_Error, MA
              .extern W_GetNumForName, W_GetLumpByNum, W_LumpLength
              .extern Z_CallocLevel, Z_MallocLevel, Z_FreeTags, poolInit
PAD_LT        .equ    0
SEC58         .equ    (MM_B3F + 0xa000) ; the address of each sector (P_InitSightTables)
              .extern I_SetLevelPalette, I_InitSegVertices, S_Start, P_InitThinkers
              .extern W_LoadSet, W_InitLevels
              .extern P_InitSightLogs, P_InitSightTables, R_PointInSubsectorNew
              .extern P_InitBlockRows, G_ID
              .extern sgrid, sgridX, sgridY, sgridCols, sgridRows
              .extern LR_OK, _g_gamemap, P_InitFlood, MB
              .extern P_LoadTexture, R_MakeLevelColumns, P_SpawnMapThing, P_SpawnSpecials
              .extern P_MapEnd, P_InitSwitchList, P_InitPicAnims, R_InitSprites
              .extern _g_player, _g_leveltime, _g_totalkills, _g_totallive, _g_totalitems
              .extern _g_totalsecret, _g_wminfo

PL            .equ    _g_player
ML_THINGS     .equ    1               ; the lumps after the map name lump
ML_LINEDEFS   .equ    2
ML_SIDEDEFS   .equ    3
ML_SEGS       .equ    4
ML_SSECTORS   .equ    5
ML_NODES      .equ    6
ML_SECTORS    .equ    7
ML_REJECT     .equ    8
ML_BLOCKMAP   .equ    9
MAPTHING_SIZE .equ    8               ; mapthing_t
MAPLINE_SIZE  .equ    15              ; packed_line_t: v1, v2, the sides,
ML_FLAGS      .equ    12              ;   flags, special, tag (bytes)
ML_SPECIAL    .equ    13
ML_TAG        .equ    14
MAPSIDE_SIZE  .equ    7               ; mapsidedef_t: textureoffset, then
MS_ROWOFFSET  .equ    2               ;   bytes: rowoffset, top, bottom,
MS_TOP        .equ    3               ;   middle texture, sector
MS_BOTTOM     .equ    4
MS_MID        .equ    5
MS_SECTOR     .equ    6
MAPSECTOR_SIZE .equ   12              ; mapsector_t: floor, ceiling heights
MSC_FLOORPIC  .equ    4               ;   and pics, then bytes lightlevel,
MSC_CEILINGPIC .equ   6               ;   special, and the tag
MSC_LIGHT     .equ    8
MSC_TAG       .equ    10
WM_PARTIME    .equ    18              ; wbstartstruct_t
NO_INDEX      .equ    0xffff

              .section znear, bss
              .public _g_segs, _g_numsectors, _g_sectors, _g_subsectors, _g_numlines
              .public _g_lines, _g_sides, _g_bmapwidth, _g_bmapheight, _g_blockmap
              .public _g_blockmaplump, _g_bmaporgx, _g_bmaporgy, _g_blocklinks
              .public _g_rejectmatrix, _g_thingPool, _g_thingPoolSize, numsubsectors
_g_segs:      .space  4
_g_numsectors: .space 2
_g_sectors:   .space  4
numsubsectors: .space 2
_g_subsectors: .space 4
_g_numlines:  .space  2
_g_lines:     .space  4
numsides:     .space  2
_g_sides:     .space  4
_g_bmapwidth: .space  2               ; the blockmap: size in blocks
_g_bmapheight: .space 2
_g_blockmap:  .space  4               ; the block offsets
_g_blockmaplump: .space 4
_g_bmaporgx:  .space  4               ; its origin
_g_bmaporgy:  .space  4
_g_blocklinks: .space 4               ; the thing chain of each block
_g_rejectmatrix: .space 4
_g_thingPool: .space  4
_g_thingPoolSize: .space 2
SU_LUMP:      .space  2               ; the map lump
SU_I:         .space  2
SU_J:         .space  2
SU_T:         .space  4
SU_TOTAL:     .space  2
SU_TEX:       .space  6               ; the textures of a side
SU_BOX:       .space  16              ; top, bottom, left, right (fixed_t)
SU_NAME:      .space  6               ; "E1Mn"
SU_GRID:      .space  8               ; "SGRIDn"

;;; ---------------------------------------------------------------------------
;;; void P_SetupLevel(int16_t map)      In: C = map.
;;; ---------------------------------------------------------------------------
;;; Cold setup leaves its bank-3 slots to the wall loops.
              .section levelsetup, text
              .public P_SetupLevel, P_Init
P_SetupLevel: pha
              jsl     long:W_LoadSet        ; the lumps of the map (its palette too)
              lda     1,s
              jsl     long:I_SetLevelPalette
              stz     .near LR_OK           ; the line record of lineBlocks is of the old level
              stz     .near _g_totallive
              stz     .near (_g_totallive+2)
              stz     .near _g_totalkills
              stz     .near (_g_totalkills+2)
              stz     .near _g_totalitems
              stz     .near (_g_totalitems+2)
              stz     .near _g_totalsecret
              stz     .near (_g_totalsecret+2)
              lda     ##180
              sta     .near (_g_wminfo+WM_PARTIME)
              stz     .near (PL+OFS_PL_KILLCOUNT)
              stz     .near (PL+OFS_PL_SECRETCOUNT)
              stz     .near (PL+OFS_PL_ITEMCOUNT)
              lda     ##1                   ; viewz = 1: the player sets it
              sta     .near (PL+OFS_PL_VIEWZ)
              stz     .near (PL+OFS_PL_VIEWZ+2)
              jsl     long:S_Start          ; all sounds stop before Z_FreeTags
              jsl     long:Z_FreeTags
              jsl     long:P_InitThinkers
              stz     .near _g_leveltime
              stz     .near (_g_leveltime+2)
              stz     .near _g_totallive
              stz     .near (_g_totallive+2)
              pla                           ; the lump "E1Mn"
              jsr     .kbank mapName
              jsl     long:rlName
              sta     .near SU_LUMP
              jsr     .kbank loadThings
              jsr     .kbank loadLineDefs
              jsr     .kbank loadSegs
              jsr     .kbank loadBlockMap
              jsl     long:P_InitBlockRows  ; (the rows of the blockmap)
              stz     .near G_ID            ; (the guard of P_PathTraverse:
                                      ;   no stamps for the new lines)
              jsr     .kbank loadNodes
              jsr     .kbank loadGrid
              jsl     long:rlSightLogs      ; (lines and nodes: the logs of
                                            ;   their deltas)
              jsr     .kbank loadSectors
              jsr     .kbank loadSideDefs
              lda     .near numsides
              jsl     long:R_MakeLevelColumns
              lda     ##ML_REJECT           ; P_LoadReject
              jsr     .kbank mapLump
              sta     .near _g_rejectmatrix
              stx     .near (_g_rejectmatrix+2)
              jsr     .kbank loadSubsectors
              jsr     .kbank newPoint
              jsr     .kbank groupLines
              jsl     long:rlSave
              jsl     long:rlSightTables    ; (the sector of each subsector)
              stz     .near (PL+OFS_PL_MO)
              stz     .near (PL+OFS_PL_MO+2)
              jsr     .kbank loadThings2
              jsl     long:P_SpawnSpecials
              jmp     long:P_MapEnd

;;; ---------------------------------------------------------------------------
;;; void P_Init(void): the switches, the animations, the sprites.
;;; ---------------------------------------------------------------------------
P_Init:       jsl     long:W_InitLevels     ; the level window (after R_Init)
              jsl     long:P_InitSwitchList
              jsl     long:P_InitPicAnims
              jmp     long:rlInit

;;; mapName: _Dp[0-3] = the name "E1M" + the number C (0..99).
mapName:      ldx     ##0                   ; X = tens, C = ones
1$:           cmp     ##10
              bcc     2$
              sbc     ##10
              inx
              bra     1$
2$:           clc
              adc     ##'0'
              sta     .near SU_T
              lda     ##('E' | ('1' << 8))
              sta     .near SU_NAME
              txa
              beq     3$
              clc                           ; two digits
              adc     ##'0'
              xba
              ora     ##'M'
              sta     .near (SU_NAME+2)
              lda     .near SU_T
              sta     .near (SU_NAME+4)
              bra     4$
3$:           lda     .near SU_T            ; one digit
              xba
              ora     ##'M'
              sta     .near (SU_NAME+2)
              stz     .near (SU_NAME+4)
4$:           lda     ##.near SU_NAME
              sta     dp:.tiny _Dp
              lda     ##.word2 SU_NAME
              sta     dp:.tiny (_Dp+2)
              rts

;;; mapLump: X:C = the lump C after the map name lump.
mapLump:      clc
              adc     .near SU_LUMP
              jsl     long:W_GetLumpByNum
              rts

;;; mapLength: C = the length of the lump C after the map name lump.
mapLength:    clc
              adc     .near SU_LUMP
              jsl     long:W_LumpLength
              rts

;;; loadThings: P_LoadThings: the pool of mobjs, one for each map thing,
;;; all MT_NOTHING and free (poolInit of src/iigs/p_spawn65.s).
loadThings:   lda     ##ML_THINGS
              jsr     .kbank mapLength
              lsr     a
              lsr     a
              lsr     a
              sta     .near _g_thingPoolSize
              ldx     ##SIZEOF_MO
              jsl     long:IIGS_MulLo16
              jsl     long:Z_CallocLevel
              sta     .near _g_thingPool
              stx     .near (_g_thingPool+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              jsl     long:poolInit
              rts
              .space  PAD_LT                ; (the fragment keeps its size)

;;; loadThings2: P_LoadThings2: each map thing spawns.
loadThings2:  lda     ##ML_THINGS
              jsr     .kbank mapLump
              sta     .near SU_T
              stx     .near (SU_T+2)
              stz     .near SU_I
1$:           lda     .near SU_I
              cmp     .near _g_thingPoolSize
              bcs     2$
              asl     a                     ; MAPTHING_SIZE
              asl     a
              asl     a
              clc
              adc     .near SU_T
              sta     dp:.tiny _Dp
              lda     .near (SU_T+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              jsl     long:P_SpawnMapThing
              inc     .near SU_I
              bra     1$
2$:           rts

;;; loadLineDefs: P_LoadLineDefs: the lines with their deltas, box and
;;; slope type.
loadLineDefs: lda     ##ML_LINEDEFS
              jsr     .kbank mapLength
              ldx     ##MAPLINE_SIZE
              jsl     long:_UDivMod16
              stx     .near _g_numlines
              txa
              ldx     ##SIZEOF_LINE
              jsl     long:IIGS_MulLo16
              stz     dp:.tiny _Dp          ; (no user)
              stz     dp:.tiny (_Dp+2)
              jsl     long:Z_MallocLevel
              sta     .near _g_lines
              stx     .near (_g_lines+2)
              sta     dp:.tiny (_Dp+4)      ; _Dp+4: the line
              stx     dp:.tiny (_Dp+6)
              lda     ##ML_LINEDEFS         ; _Dp: the map line
              jsr     .kbank mapLump
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near _g_numlines
              sta     .near SU_I
              bne     1$
              rts
1$:           ldy     ##6                   ; v1, v2
2$:           lda     [.tiny _Dp],y
              sta     [.tiny (_Dp+4)],y
              dey
              dey
              bpl     2$
              ldy     ##8                   ; sidenum[0], sidenum[1]
              lda     [.tiny _Dp],y
              ldy     ##OFS_LINE_SIDENUM
              sta     [.tiny (_Dp+4)],y
              ldy     ##10
              lda     [.tiny _Dp],y
              ldy     ##(OFS_LINE_SIDENUM+2)
              sta     [.tiny (_Dp+4)],y
              ldy     ##4                   ; dx = v2.x - v1.x
              lda     [.tiny _Dp],y
              sec
              sbc     [.tiny _Dp]
              ldy     ##OFS_LINE_DX
              sta     [.tiny (_Dp+4)],y
              sta     .near SU_T
              ldy     ##6                   ; dy = v2.y - v1.y
              lda     [.tiny _Dp],y
              ldy     ##2
              sec
              sbc     [.tiny _Dp],y
              ldy     ##OFS_LINE_DY
              sta     [.tiny (_Dp+4)],y
              sta     .near (SU_T+2)
              ldy     ##2                   ; v1.y < v2.y: top v2.y, bottom v1.y
              lda     [.tiny _Dp],y
              ldy     ##6
              sec
              sbc     [.tiny _Dp],y
              bvc     3$
              eor     ##0x8000
3$:           bmi     4$
              ldy     ##2                   ; else top v1.y, bottom v2.y
              lda     [.tiny _Dp],y
              ldy     ##(OFS_LINE_BBOX+2*CONST_BOXTOP)
              sta     [.tiny (_Dp+4)],y
              ldy     ##6
              lda     [.tiny _Dp],y
              bra     5$
4$:           ldy     ##6
              lda     [.tiny _Dp],y
              ldy     ##(OFS_LINE_BBOX+2*CONST_BOXTOP)
              sta     [.tiny (_Dp+4)],y
              ldy     ##2
              lda     [.tiny _Dp],y
5$:           ldy     ##(OFS_LINE_BBOX+2*CONST_BOXBOTTOM)
              sta     [.tiny (_Dp+4)],y
              lda     [.tiny _Dp]           ; v1.x < v2.x: left v1.x, right v2.x
              ldy     ##4
              sec
              sbc     [.tiny _Dp],y
              bvc     6$
              eor     ##0x8000
6$:           bmi     7$
              ldy     ##4                   ; else left v2.x, right v1.x
              lda     [.tiny _Dp],y
              ldy     ##(OFS_LINE_BBOX+2*CONST_BOXLEFT)
              sta     [.tiny (_Dp+4)],y
              lda     [.tiny _Dp]
              bra     8$
7$:           lda     [.tiny _Dp]
              ldy     ##(OFS_LINE_BBOX+2*CONST_BOXLEFT)
              sta     [.tiny (_Dp+4)],y
              ldy     ##4
              lda     [.tiny _Dp],y
8$:           ldy     ##(OFS_LINE_BBOX+2*CONST_BOXRIGHT)
              sta     [.tiny (_Dp+4)],y
              ldy     ##ML_TAG              ; tag (int8)
              lda     [.tiny _Dp],y
              jsr     .kbank signByte
              ldy     ##OFS_LINE_TAG
              sta     [.tiny (_Dp+4)],y
              ldy     ##ML_SPECIAL          ; special (int8)
              lda     [.tiny _Dp],y
              jsr     .kbank signByte
              ldy     ##OFS_LINE_SPECIAL
              sta     [.tiny (_Dp+4)],y
              lda     .near SU_T            ; the slope type
              bne     9$
              lda     ##CONST_ST_VERTICAL
              bra     11$
9$:           lda     .near (SU_T+2)
              bne     10$
              lda     ##0                   ; ST_HORIZONTAL
              bra     11$
10$:          eor     .near SU_T
              bmi     101$
              lda     ##CONST_ST_POSITIVE
              bra     11$
101$:         lda     ##CONST_ST_NEGATIVE
11$:          xba                           ; flags, slopetype
              pha
              ldy     ##ML_FLAGS
              lda     [.tiny _Dp],y
              and     ##0x00ff
              ora     1,s
              ply
              ldy     ##OFS_LINE_FLAGS
              sta     [.tiny (_Dp+4)],y
              lda     ##0                   ; validcount, r_validcount, r_flags
              ldy     ##OFS_LINE_VALIDCOUNT
              sta     [.tiny (_Dp+4)],y
              ldy     ##OFS_LINE_R_VALIDCOUNT
              sta     [.tiny (_Dp+4)],y
              ldy     ##OFS_LINE_R_FLAGS
              sta     [.tiny (_Dp+4)],y
              lda     dp:.tiny _Dp          ; the next line
              clc
              adc     ##MAPLINE_SIZE
              sta     dp:.tiny _Dp
              lda     dp:.tiny (_Dp+4)
              clc
              adc     ##SIZEOF_LINE
              sta     dp:.tiny (_Dp+4)
              dec     .near SU_I
              beq     12$
              brl     1$
12$:          rts

;;; signByte: C = the low byte of C, sign extended.
signByte:     and     ##0x00ff
              cmp     ##0x0080
              bcc     1$
              ora     ##0xff00
1$:           rts

;;; loadSegs: P_LoadSegs: the segs in place, their vertex numbers.
loadSegs:     lda     ##ML_SEGS
              jsr     .kbank mapLump
              sta     .near _g_segs
              stx     .near (_g_segs+2)
              lda     ##ML_SEGS
              jsr     .kbank mapLength
              ldx     ##SIZEOF_SEG
              jsl     long:_UDivMod16
              lda     .near _g_segs
              sta     dp:.tiny _Dp
              lda     .near (_g_segs+2)
              sta     dp:.tiny (_Dp+2)
              txa
              jsl     long:I_InitSegVertices
              rts

;;; loadBlockMap: P_LoadBlockMap: the blockmap in place, its origin and
;;; size, the thing chains 0.
loadBlockMap: lda     ##ML_BLOCKMAP
              jsr     .kbank mapLump
              sta     .near _g_blockmaplump
              stx     .near (_g_blockmaplump+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              clc                           ; the offsets after 4 words
              adc     ##8
              sta     .near _g_blockmap
              stx     .near (_g_blockmap+2)
              stz     .near _g_bmaporgx
              lda     [.tiny _Dp]
              sta     .near (_g_bmaporgx+2)
              stz     .near _g_bmaporgy
              ldy     ##2
              lda     [.tiny _Dp],y
              sta     .near (_g_bmaporgy+2)
              ldy     ##4
              lda     [.tiny _Dp],y
              sta     .near _g_bmapwidth
              ldy     ##6
              lda     [.tiny _Dp],y
              sta     .near _g_bmapheight
              ldx     .near _g_bmapwidth    ; width * height * 4 bytes
              jsl     long:IIGS_MulLo16
              asl     a
              asl     a
              jsl     long:Z_CallocLevel
              sta     .near _g_blocklinks
              stx     .near (_g_blocklinks+2)
              rts

;;; loadNodes: P_LoadNodes: the nodes in place.
loadNodes:    lda     ##ML_NODES
              jsr     .kbank mapLength
              ldx     ##SIZEOF_NODE
              jsl     long:_UDivMod16
              stx     .near numnodes
              lda     ##ML_NODES
              jsr     .kbank mapLump
              sta     .near nodes
              stx     .near (nodes+2)
              rts

;;; loadGrid: the subsector grid of R_PointInSubsector (the lump SGRIDn of
;;; tools/sgrid.py, n = the map digit in SU_NAME, "E1Mn"): its address,
;;; origin, columns and rows.
loadGrid:     lda     ##('S' | ('G' << 8))
              sta     .near SU_GRID
              lda     ##('R' | ('I' << 8))
              sta     .near (SU_GRID+2)
              lda     .near (SU_NAME+3)     ; 'D', the digit, 0
              xba
              and     ##0xff00
              ora     ##'D'
              sta     .near (SU_GRID+4)
              stz     .near (SU_GRID+6)
              lda     ##.near SU_GRID
              sta     dp:.tiny _Dp
              lda     ##.word2 SU_GRID
              sta     dp:.tiny (_Dp+2)
              jsl     long:rlGridName
              jsl     long:W_GetLumpByNum
              sta     .near sgrid
              stx     .near (sgrid+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp]           ; the cell size of the game
              cmp     ##64
              beq     1$
              lda     ##.word0 errGrid
              sta     dp:.tiny _Dp
              lda     ##.word2 errGrid
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
1$:           ldy     ##2
              lda     [.tiny _Dp],y
              sta     .near sgridX
              ldy     ##4
              lda     [.tiny _Dp],y
              sta     .near sgridY
              ldy     ##6
              lda     [.tiny _Dp],y
              sta     .near sgridCols
              ldy     ##8
              lda     [.tiny _Dp],y
              sta     .near sgridRows
              rts

;;; newPoint: the last point of R_PointInSubsector is one of the new map
;;; (after its subsectors): a point of no map, 32767.99, 32767.99.
newPoint:     lda     ##0xffff
              sta     dp:.tiny _Dp
              lda     ##0x7fff
              sta     dp:.tiny (_Dp+2)
              tax
              lda     ##0xffff
              jsl     long:R_PointInSubsectorNew
              rts

errGrid:      .asciz  "P_SetupLevel: the subsector grid (SGRIDn) is not of 64 map units"

;;; loadSectors: P_LoadSectors: the sectors: heights, flats, light,
;;; special, tag.
loadSectors:  lda     ##ML_SECTORS
              jsr     .kbank mapLength
              ldx     ##MAPSECTOR_SIZE
              jsl     long:_UDivMod16
              stx     .near _g_numsectors
              txa
              ldx     ##SIZEOF_SEC
              jsl     long:IIGS_MulLo16
              jsl     long:Z_CallocLevel
              sta     .near _g_sectors
              stx     .near (_g_sectors+2)
              sta     dp:.tiny (_Dp+4)      ; _Dp+4: the sector
              stx     dp:.tiny (_Dp+6)
              lda     ##ML_SECTORS          ; _Dp: the map sector
              jsr     .kbank mapLump
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     .near _g_numsectors
              sta     .near SU_I
              beq     2$
1$:           lda     [.tiny _Dp]           ; floorheight << FRACBITS
              ldy     ##(OFS_SEC_FLOORHEIGHT+2)
              sta     [.tiny (_Dp+4)],y
              ldy     ##2                   ; ceilingheight << FRACBITS
              lda     [.tiny _Dp],y
              ldy     ##(OFS_SEC_CEILINGHEIGHT+2)
              sta     [.tiny (_Dp+4)],y
              lda     ##0
              ldy     ##OFS_SEC_FLOORHEIGHT
              sta     [.tiny (_Dp+4)],y
              ldy     ##OFS_SEC_CEILINGHEIGHT
              sta     [.tiny (_Dp+4)],y
              ldy     ##MSC_FLOORPIC        ; floorpic, ceilingpic
              lda     [.tiny _Dp],y
              ldy     ##OFS_SEC_FLOORPIC
              sta     [.tiny (_Dp+4)],y
              ldy     ##MSC_CEILINGPIC
              lda     [.tiny _Dp],y
              ldy     ##OFS_SEC_CEILINGPIC
              sta     [.tiny (_Dp+4)],y
              ldy     ##MSC_LIGHT           ; lightlevel (uint8)
              lda     [.tiny _Dp],y
              pha
              and     ##0x00ff
              ldy     ##OFS_SEC_LIGHTLEVEL
              sta     [.tiny (_Dp+4)],y
              pla                           ; special, oldspecial (int8)
              xba
              jsr     .kbank signByte
              ldy     ##OFS_SEC_SPECIAL
              sta     [.tiny (_Dp+4)],y
              ldy     ##OFS_SEC_OLDSPECIAL
              sta     [.tiny (_Dp+4)],y
              ldy     ##MSC_TAG             ; tag
              lda     [.tiny _Dp],y
              ldy     ##OFS_SEC_TAG
              sta     [.tiny (_Dp+4)],y
              lda     dp:.tiny _Dp          ; the next sector (the lists
              clc                           ; stay NULL)
              adc     ##MAPSECTOR_SIZE
              sta     dp:.tiny _Dp
              lda     dp:.tiny (_Dp+4)
              clc
              adc     ##SIZEOF_SEC
              sta     dp:.tiny (_Dp+4)
              dec     .near SU_I
              bne     1$
2$:           rts

;;; loadSideDefs: P_LoadSideDefs: the sides (offsets, sector, textures),
;;; with the textures of each side ready (middle, top, bottom).
loadSideDefs: lda     ##ML_SIDEDEFS
              jsr     .kbank mapLength
              ldx     ##MAPSIDE_SIZE
              jsl     long:_UDivMod16
              stx     .near numsides
              txa
              ldx     ##SIZEOF_SIDE
              jsl     long:IIGS_MulLo16
              stz     dp:.tiny _Dp          ; no memset: the loop writes all
              stz     dp:.tiny (_Dp+2)      ;   14 bytes of each side
              jsl     long:Z_MallocLevel
              sta     .near _g_sides
              stx     .near (_g_sides+2)
              lda     ##ML_SIDEDEFS
              jsr     .kbank mapLump
              sta     .near SU_T
              stx     .near (SU_T+2)
              stz     .near SU_I
1$:           lda     .near SU_I
              cmp     .near numsides
              bcc     2$
              rts
2$:           jsr     .kbank mul7           ; _Dp: the map side
              clc
              adc     .near SU_T
              sta     dp:.tiny _Dp
              lda     .near (SU_T+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              lda     .near SU_I            ; _Dp+4: the side
              jsr     .kbank mul14          ; (SIZEOF_SIDE)
              clc
              adc     .near _g_sides
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_sides+2)
              adc     ##0
              sta     dp:.tiny (_Dp+6)
              lda     [.tiny _Dp]           ; textureoffset
              ldy     ##OFS_SIDE_TEXTUREOFFSET
              sta     [.tiny (_Dp+4)],y
              ldy     ##MS_ROWOFFSET        ; rowoffset (uint8)
              lda     [.tiny _Dp],y
              and     ##0x00ff
              ldy     ##OFS_SIDE_ROWOFFSET
              sta     [.tiny (_Dp+4)],y
              ldy     ##MS_SECTOR           ; sector = &_g_sectors[sector]
              lda     [.tiny _Dp],y
              and     ##0x00ff
              jsr     .kbank mul58          ; (SIZEOF_SEC)
              clc
              adc     .near _g_sectors
              ldy     ##OFS_SIDE_SECTOR
              sta     [.tiny (_Dp+4)],y
              lda     .near (_g_sectors+2)
              adc     ##0
              iny
              iny
              sta     [.tiny (_Dp+4)],y
              ldy     ##MS_MID              ; the textures (int8)
              lda     [.tiny _Dp],y
              jsr     .kbank signByte
              sta     .near SU_TEX
              ldy     ##OFS_SIDE_MIDTEXTURE
              sta     [.tiny (_Dp+4)],y
              ldy     ##MS_TOP
              lda     [.tiny _Dp],y
              jsr     .kbank signByte
              sta     .near (SU_TEX+2)
              ldy     ##OFS_SIDE_TOPTEXTURE
              sta     [.tiny (_Dp+4)],y
              ldy     ##MS_BOTTOM
              lda     [.tiny _Dp],y
              jsr     .kbank signByte
              sta     .near (SU_TEX+4)
              ldy     ##OFS_SIDE_BOTTOMTEXTURE
              sta     [.tiny (_Dp+4)],y
              lda     .near SU_TEX          ; ready: middle, top, bottom
              jsl     long:P_LoadTexture
              lda     .near (SU_TEX+2)
              jsl     long:P_LoadTexture
              lda     .near (SU_TEX+4)
              jsl     long:P_LoadTexture
              inc     .near SU_I
              lda     .near SU_I
              brl     1$

;;; loadSubsectors: P_LoadSubsectors: the seg count and first seg of each
;;; subsector.
loadSubsectors:
              lda     ##ML_SSECTORS
              jsr     .kbank mapLength
              sta     .near numsubsectors
              asl     a                     ; SIZEOF_SUB
              asl     a
              asl     a
              stz     dp:.tiny _Dp          ; no memset: this loop and
              stz     dp:.tiny (_Dp+2)      ;   groupLines write all 8 bytes
              jsl     long:Z_MallocLevel
              sta     .near _g_subsectors
              stx     .near (_g_subsectors+2)
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              lda     ##ML_SSECTORS
              jsr     .kbank mapLump
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              stz     .near SU_J            ; firstseg
              ldx     .near numsubsectors
              beq     2$
1$:           lda     [.tiny _Dp]           ; numlines (int8)
              jsr     .kbank signByte
              ldy     ##OFS_SUB_NUMLINES
              sta     [.tiny (_Dp+4)],y
              pha
              lda     .near SU_J
              ldy     ##OFS_SUB_FIRSTLINE
              sta     [.tiny (_Dp+4)],y
              pla
              clc
              adc     .near SU_J
              sta     .near SU_J
              inc     dp:.tiny _Dp          ; the next one
              lda     dp:.tiny (_Dp+4)
              clc
              adc     ##SIZEOF_SUB
              sta     dp:.tiny (_Dp+4)
              dex
              bne     1$
2$:           rts

;;; ---------------------------------------------------------------------------
;;; groupLines: P_GroupLines: the sector of each subsector (of its first seg
;;; with a side); the lines of each sector (a line of two sectors is in
;;; both); the sound origin of each sector in the middle of its box.
;;; ---------------------------------------------------------------------------
groupLines:   jsl     long:rlGroup
              bcc     0$
              rts
0$:           stz     .near SU_I            ; each subsector
1$:           lda     .near SU_I
              cmp     .near numsubsectors
              bcc     2$
              brl     10$
2$:           asl     a                     ; _Dp: the subsector
              asl     a
              asl     a
              clc
              adc     .near _g_subsectors
              sta     dp:.tiny _Dp
              lda     .near (_g_subsectors+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              lda     ##0                   ; sector = NULL
              ldy     ##OFS_SUB_SECTOR
              sta     [.tiny _Dp],y
              iny
              iny
              sta     [.tiny _Dp],y
              ldy     ##OFS_SUB_FIRSTLINE   ; _Dp+4: its first seg
              lda     [.tiny _Dp],y
              jsr     .kbank mul18          ; (SIZEOF_SEG)
              clc
              adc     .near _g_segs
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_segs+2)
              adc     ##0
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_SUB_NUMLINES
              lda     [.tiny _Dp],y
              sta     .near SU_J
              beq     5$
3$:           ldy     ##OFS_SEG_SIDENUM     ; a seg with a side: its sector
              lda     [.tiny (_Dp+4)],y
              cmp     ##NO_INDEX
              beq     4$
              jsr     .kbank sideSector
              ldy     ##OFS_SUB_SECTOR
              sta     [.tiny _Dp],y
              txa
              iny
              iny
              sta     [.tiny _Dp],y
              bra     5$
4$:           lda     dp:.tiny (_Dp+4)
              clc
              adc     ##SIZEOF_SEG
              sta     dp:.tiny (_Dp+4)
              dec     .near SU_J
              bne     3$
5$:           inc     .near SU_I
              brl     1$
10$:          lda     .near _g_numlines     ; the lines of each sector:
              sta     .near SU_TOTAL        ; the counts
              ldx     ##0
              jsr     .kbank eachLine
              lda     .near SU_TOTAL        ; the line tables (4 bytes each)
              asl     a
              asl     a
              stz     dp:.tiny _Dp          ; (no user)
              stz     dp:.tiny (_Dp+2)
              jsl     long:Z_MallocLevel
              sta     .near SU_T
              stx     .near (SU_T+2)
              lda     .near _g_sectors      ; each sector: its table,
              sta     dp:.tiny _Dp          ;   linecount 0
              lda     .near (_g_sectors+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near _g_numsectors
              sta     .near SU_I
              beq     12$
11$:          lda     .near SU_T
              ldy     ##OFS_SEC_LINES
              sta     [.tiny _Dp],y
              lda     .near (SU_T+2)
              iny
              iny
              sta     [.tiny _Dp],y
              ldy     ##OFS_SEC_LINECOUNT
              lda     [.tiny _Dp],y
              asl     a
              asl     a
              clc
              adc     .near SU_T
              sta     .near SU_T
              lda     ##0
              sta     [.tiny _Dp],y
              lda     dp:.tiny _Dp
              clc
              adc     ##SIZEOF_SEC
              sta     dp:.tiny _Dp
              dec     .near SU_I
              bne     11$
12$:          ldx     ##2                   ; the lines in the tables
              jsr     .kbank eachLine
              brl     soundOrigins

;;; eachLine: for each line, its front sector and its back sector (if it
;;; has one that is not the front): X = 0: linecount++ (and SU_TOTAL++ for
;;; the back); X = 2: the line in the table of the sector.
eachLine:     stx     .near SU_J
              stz     .near SU_I
1$:           lda     .near SU_I
              cmp     .near _g_numlines
              bcc     2$
              rts
2$:           jsr     .kbank mul36          ; SU_T: the line (SIZEOF_LINE)
              clc
              adc     .near _g_lines
              sta     .near SU_T
              sta     dp:.tiny _Dp
              lda     .near (_g_lines+2)
              adc     ##0
              sta     .near (SU_T+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##(OFS_LINE_SIDENUM+2) ; the back sector, or NULL
              lda     [.tiny _Dp],y
              pha
              ldy     ##OFS_LINE_SIDENUM    ; the front sector
              lda     [.tiny _Dp],y
              jsr     .kbank sideSector
              sta     dp:.tiny (_Dp+4)
              stx     dp:.tiny (_Dp+6)
              pla
              cmp     ##NO_INDEX
              beq     3$
              jsr     .kbank sideSector
              bra     4$
3$:           lda     ##0
              tax
4$:           sta     .near SU_BOX          ; (the back sector)
              stx     .near (SU_BOX+2)
              jsr     .kbank lineToSector   ; the front
              lda     .near SU_BOX          ; a back that is not the front
              ora     .near (SU_BOX+2)
              beq     5$
              lda     .near SU_BOX
              cmp     dp:.tiny (_Dp+4)
              bne     41$
              lda     .near (SU_BOX+2)
              cmp     dp:.tiny (_Dp+6)
              beq     5$
41$:          lda     .near SU_BOX
              sta     dp:.tiny (_Dp+4)
              lda     .near (SU_BOX+2)
              sta     dp:.tiny (_Dp+6)
              jsr     .kbank lineToSector
              lda     .near SU_J
              bne     5$
              inc     .near SU_TOTAL
5$:           inc     .near SU_I
              bra     1$

;;; lineToSector: for the sector at _Dp[4-7]: SU_J = 0: linecount++;
;;; else lines[linecount++] = the line SU_T.
lineToSector: ldy     ##OFS_SEC_LINECOUNT
              lda     [.tiny (_Dp+4)],y
              pha
              inc     a
              sta     [.tiny (_Dp+4)],y
              pla
              ldx     .near SU_J
              beq     1$
              asl     a                     ; lines[linecount] = the line
              asl     a
              pha
              ldy     ##OFS_SEC_LINES
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny _Dp
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny (_Dp+2)
              ply
              lda     .near SU_T
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (SU_T+2)
              sta     [.tiny _Dp],y
1$:           rts

;;; sideSector: X:C = _g_sides[C].sector. _Dp stays.
sideSector:   jsr     .kbank mul14          ; (SIZEOF_SIDE)
              tay
              lda     dp:.tiny _Dp
              pha
              lda     dp:.tiny (_Dp+2)
              pha
              lda     .near _g_sides
              sta     dp:.tiny _Dp
              lda     .near (_g_sides+2)
              sta     dp:.tiny (_Dp+2)
              iny                           ; (OFS_SIDE_SECTOR)
              iny
              lda     [.tiny _Dp],y
              tax
              dey
              dey
              lda     [.tiny _Dp],y
              ply
              sty     dp:.tiny (_Dp+2)
              ply
              sty     dp:.tiny _Dp
              rts

;;; soundOrigins: each sector: the box of its line ends (M_AddToBox, with
;;; its else if), the sound origin in the middle.
soundOrigins: lda     .near _g_sectors
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_sectors+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near _g_numsectors
              sta     .near SU_I
              bne     1$
              rts
1$:           lda     ##0x0000              ; M_ClearBox: top, right INT32_MIN,
              sta     .near SU_BOX          ;   bottom, left INT32_MAX
              sta     .near (SU_BOX+4*CONST_BOXRIGHT)
              lda     ##0x8000
              sta     .near (SU_BOX+2)
              sta     .near (SU_BOX+4*CONST_BOXRIGHT+2)
              lda     ##0xffff
              sta     .near (SU_BOX+4*CONST_BOXBOTTOM)
              sta     .near (SU_BOX+4*CONST_BOXLEFT)
              lda     ##0x7fff
              sta     .near (SU_BOX+4*CONST_BOXBOTTOM+2)
              sta     .near (SU_BOX+4*CONST_BOXLEFT+2)
              stz     .near SU_J            ; each line of the sector
2$:           lda     .near SU_J
              ldy     ##OFS_SEC_LINECOUNT
              cmp     [.tiny (_Dp+4)],y
              bcs     3$
              asl     a                     ; the line
              asl     a
              pha
              ldy     ##OFS_SEC_LINES
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny _Dp
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny (_Dp+2)
              ply
              lda     [.tiny _Dp],y
              tax
              iny
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+2)
              stx     dp:.tiny _Dp
              ldy     ##(OFS_LINE_V1+2)     ; v1
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_LINE_V1
              lda     [.tiny _Dp],y
              jsr     .kbank addToBox
              ldy     ##(OFS_LINE_V2+2)     ; v2
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_LINE_V2
              lda     [.tiny _Dp],y
              jsr     .kbank addToBox
              inc     .near SU_J
              bra     2$
3$:           ldx     ##(4*CONST_BOXRIGHT)  ; soundorg.x = right / 2 + left / 2
              ldy     ##(4*CONST_BOXLEFT)
              jsr     .kbank halfSum
              ldy     ##OFS_SEC_SOUNDORG
              sta     [.tiny (_Dp+4)],y
              txa
              iny
              iny
              sta     [.tiny (_Dp+4)],y
              ldx     ##(4*CONST_BOXTOP)    ; soundorg.y = top / 2 + bottom / 2
              ldy     ##(4*CONST_BOXBOTTOM)
              jsr     .kbank halfSum
              ldy     ##(OFS_SEC_SOUNDORG+4)
              sta     [.tiny (_Dp+4)],y
              txa
              iny
              iny
              sta     [.tiny (_Dp+4)],y
              lda     dp:.tiny (_Dp+4)      ; the next sector
              clc
              adc     ##SIZEOF_SEC
              sta     dp:.tiny (_Dp+4)
              dec     .near SU_I
              beq     4$
              brl     1$
4$:           rts

;;; halfSum: X:C = SU_BOX[X] / 2 + SU_BOX[Y] / 2 (X, Y: byte offsets). The
;;; values are even or positive, so / 2 is the arithmetic shift.
halfSum:      lda     abs:.near (SU_BOX+2),x
              cmp     ##0x8000
              ror     a
              sta     .near (SU_T+2)
              lda     abs:.near SU_BOX,x
              ror     a
              sta     .near SU_T
              tyx
              lda     abs:.near (SU_BOX+2),x
              cmp     ##0x8000
              ror     a
              tay
              lda     abs:.near SU_BOX,x
              ror     a
              clc
              adc     .near SU_T
              pha
              tya
              adc     .near (SU_T+2)
              tax
              pla
              rts

;;; addToBox: M_AddToBox(SU_BOX, C << FRACBITS, X << FRACBITS): x < left:
;;; left = x, else x > right: right = x; y < bottom: bottom = y, else
;;; y > top: top = y.
addToBox:     phx
              ldy     ##(4*CONST_BOXLEFT)
              ldx     ##(4*CONST_BOXRIGHT)
              jsr     .kbank boxCoord
              pla
              ldy     ##(4*CONST_BOXBOTTOM)
              ldx     ##(4*CONST_BOXTOP)
              ;; (falls through)

;;; boxCoord: v = C << FRACBITS: v < SU_BOX[Y]: SU_BOX[Y] = v; else
;;; v > SU_BOX[X]: SU_BOX[X] = v.
boxCoord:     sta     .near SU_TEX          ; v < low: (0 - low.lo, v - low.hi)
              lda     ##0                   ;   negative
              sec
              sbc     abs:.near SU_BOX,y
              lda     .near SU_TEX
              sbc     abs:.near (SU_BOX+2),y
              bvc     1$
              eor     ##0x8000
1$:           bpl     2$
              lda     ##0
              sta     abs:.near SU_BOX,y
              lda     .near SU_TEX
              sta     abs:.near (SU_BOX+2),y
              rts
2$:           lda     abs:.near SU_BOX,x    ; v > high: high - v negative
              sec
              sbc     ##0
              lda     abs:.near (SU_BOX+2),x
              sbc     .near SU_TEX
              bvc     3$
              eor     ##0x8000
3$:           bpl     4$
              stz     abs:.near SU_BOX,x
              lda     .near SU_TEX
              sta     abs:.near (SU_BOX+2),x
4$:           rts

;;; mul7, mul14, mul18, mul36, mul58: C = C * 7 (MAPSIDE_SIZE), 14
;;; (SIZEOF_SIDE), 18 (SIZEOF_SEG), 36 (SIZEOF_LINE), 58 (SIZEOF_SEC), the
;;; low 16 bits, with shifts (the loops of a level load). MA is scratch.
mul7:         sta     dp:.tiny MA           ; 8x - x
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny MA
              rts
mul14:        jsr     .kbank mul7
              asl     a
              rts
mul18:        asl     a                     ; 16x + 2x
              sta     dp:.tiny MA
              asl     a
              asl     a
              asl     a
              clc
              adc     dp:.tiny MA
              rts
mul36:        jsr     .kbank mul18
              asl     a
              rts
mul58:        sta     dp:.tiny MA           ; 2 (32x - 3x)
              asl     a
              clc
              adc     dp:.tiny MA
              sta     dp:.tiny (MA+2)
              lda     dp:.tiny MA
              asl     a
              asl     a
              asl     a
              asl     a
              asl     a
              sec
              sbc     dp:.tiny (MA+2)
              asl     a
              rts

;;; ---------------------------------------------------------------------------
;;; A new life on the same map (RL_ON): the results of groupLines come from
;;; a copy of the first load (rlSave). The copy holds offsets, not
;;; addresses: each load puts the level blocks at other addresses. The zone
;;; calls stay the same, so each block gets the address of a full load.
;;; The sight tables of the map stay in bank 3F; only SEC58 and the flood
;;; lists hold addresses.
;;; ---------------------------------------------------------------------------
RL_SECS       .equ    (MM_BRL + 0xc000) ; each sector: sound origin, linecount,
                                      ;   table offset (12 bytes)
RL_SUBS       .equ    (MM_BRL + 0xd000) ; each subsector: sector offset (0xffff: none)
RL_LTAB       .equ    (MM_BRL + 0xd800) ; each table entry: line offset
RL_MAP        .equ    (MM_BRL + 0xfe00) ; the map of the copy, 0: none
RL_ON         .equ    (MM_BRL + 0xfe02)
RL_LUMP       .equ    (MM_BRL + 0xfe04)
RL_GRID       .equ    (MM_BRL + 0xfe06)
RL_TOTAL      .equ    (MM_BRL + 0xfe08) ; the table entries (SU_TOTAL)
RL_NSMAX      .equ    341             ; 12 * 341 < 0x1000
RL_NSSMAX     .equ    1024            ; 2 * 1024 = 0x800
RL_NTMAX      .equ    4864            ; 2 * 4864 = 0x2600

;;; rlInit: bank 4F is not cleared at boot.
              .section coldcode, text
rlInit:       lda     ##0
              sta     long:RL_MAP
              jmp     long:R_InitSprites

;;; rlName: the map lump; the search only for another map.
              .section coldcode, text
rlName:       lda     long:RL_MAP
              cmp     .near _g_gamemap
              bne     1$
              lda     ##1
              sta     long:RL_ON
              lda     long:RL_LUMP
              rtl
1$:           lda     ##0
              sta     long:RL_ON
              sta     long:RL_MAP
              jsl     long:W_GetNumForName
              sta     long:RL_LUMP
              rtl

;;; rlGridName: the grid lump; the search only for another map.
              .section coldcode, text
rlGridName:   lda     long:RL_ON
              beq     1$
              lda     long:RL_GRID
              rtl
1$:           jsl     long:W_GetNumForName
              sta     long:RL_GRID
              rtl

;;; rlSightLogs, rlSightTables: with the copy, only the tables that hold
;;; addresses: SEC58 and the flood lists.
              .section coldcode, text
rlSightLogs:  lda     long:RL_ON
              bne     1$
              jmp     long:P_InitSightLogs
1$:           rtl
rlSightTables:
              lda     long:RL_ON
              bne     1$
              jmp     long:P_InitSightTables
1$:           ldx     ##0
              lda     .near _g_sectors
              ldy     .near _g_numsectors
              beq     3$
2$:           sta     long:SEC58,x
              clc
              adc     ##SIZEOF_SEC
              inx
              inx
              dey
              bne     2$
3$:           jmp     long:P_InitFlood

;;; rlGroup: for groupLines: with the copy, its results from it (C = 1);
;;; the same Z_MallocLevel keeps the zone as a full load.
              .section coldcode, text
rlGroup:      lda     long:RL_ON
              bne     1$
              clc
              rtl
1$:           lda     .near _g_subsectors
              sta     dp:.tiny _Dp
              lda     .near (_g_subsectors+2)
              sta     dp:.tiny (_Dp+2)
              ldx     ##0
              ldy     ##OFS_SUB_SECTOR
2$:           txa
              lsr     a
              cmp     .near numsubsectors
              bcs     5$
              lda     long:RL_SUBS,x
              cmp     ##0xffff
              bne     3$
              lda     ##0                   ; (none)
              sta     [.tiny _Dp],y
              iny
              iny
              sta     [.tiny _Dp],y
              bra     4$
3$:           clc
              adc     .near _g_sectors
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (_g_sectors+2)
              sta     [.tiny _Dp],y
4$:           tya
              clc
              adc     ##(SIZEOF_SUB - 2)
              tay
              inx
              inx
              bra     2$
5$:           lda     long:RL_TOTAL
              sta     .near SU_TOTAL
              asl     a
              asl     a
              stz     dp:.tiny _Dp          ; (no user)
              stz     dp:.tiny (_Dp+2)
              jsl     long:Z_MallocLevel
              sta     .near SU_T
              stx     .near (SU_T+2)
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ldx     ##0
              ldy     ##0
6$:           txa
              lsr     a
              cmp     long:RL_TOTAL
              bcs     7$
              lda     long:RL_LTAB,x
              clc
              adc     .near _g_lines
              sta     [.tiny _Dp],y
              iny
              iny
              lda     .near (_g_lines+2)
              sta     [.tiny _Dp],y
              iny
              iny
              inx
              inx
              bra     6$
7$:           jmp     long:rlSecs

;;; rlSecs: for rlGroup (SU_T: the first table). C = 1.
              .section coldcode, text
rlSecs:       lda     .near _g_sectors
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_sectors+2)
              sta     dp:.tiny (_Dp+6)
              ldx     ##0                   ; X: 12 s
              lda     .near _g_numsectors
              sta     dp:.tiny MB
              beq     9$
1$:           ldy     ##OFS_SEC_SOUNDORG
2$:           lda     long:RL_SECS,x
              sta     [.tiny (_Dp+4)],y
              inx
              inx
              iny
              iny
              cpy     ##(OFS_SEC_SOUNDORG + 8)
              bcc     2$
              lda     long:RL_SECS,x
              ldy     ##OFS_SEC_LINECOUNT
              sta     [.tiny (_Dp+4)],y
              lda     long:(RL_SECS+2),x
              clc
              adc     .near SU_T
              ldy     ##OFS_SEC_LINES
              sta     [.tiny (_Dp+4)],y
              iny
              iny
              lda     .near (SU_T+2)
              sta     [.tiny (_Dp+4)],y
              inx
              inx
              inx
              inx
              lda     dp:.tiny (_Dp+4)
              clc
              adc     ##SIZEOF_SEC
              sta     dp:.tiny (_Dp+4)
              dec     dp:.tiny MB
              bne     1$
9$:           sec
              rtl

;;; rlSave: after groupLines of a full load: the copy of this map, if it
;;; fits.
              .section coldcode, text
rlSave:       lda     long:RL_ON
              beq     1$
              rtl
1$:           lda     .near _g_numsectors
              cmp     ##(RL_NSMAX + 1)
              bcs     8$
              lda     .near numsubsectors
              cmp     ##(RL_NSSMAX + 1)
              bcs     8$
              lda     .near SU_TOTAL
              cmp     ##(RL_NTMAX + 1)
              bcs     8$
              sta     long:RL_TOTAL
              jsl     long:rlSave2
              jsl     long:rlSave3
              lda     .near _g_gamemap
              sta     long:RL_MAP
8$:           rtl

;;; rlSave2: for rlSave: the subsectors and the table entries (the tables
;;; start at the table of sector 0).
              .section coldcode, text
rlSave2:      lda     .near _g_subsectors
              sta     dp:.tiny _Dp
              lda     .near (_g_subsectors+2)
              sta     dp:.tiny (_Dp+2)
              ldx     ##0
              ldy     ##OFS_SUB_SECTOR
1$:           txa
              lsr     a
              cmp     .near numsubsectors
              bcs     4$
              iny                           ; NULL: 0xffff
              iny
              lda     [.tiny _Dp],y
              dey
              dey
              ora     [.tiny _Dp],y
              beq     2$
              lda     [.tiny _Dp],y
              sec
              sbc     .near _g_sectors
              bra     3$
2$:           lda     ##0xffff
3$:           sta     long:RL_SUBS,x
              tya
              clc
              adc     ##SIZEOF_SUB
              tay
              inx
              inx
              bra     1$
4$:           lda     .near _g_sectors
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_sectors+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_SEC_LINES
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny _Dp
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny (_Dp+2)
              ldx     ##0
              ldy     ##0
5$:           txa
              lsr     a
              cmp     long:RL_TOTAL
              bcs     6$
              lda     [.tiny _Dp],y
              sec
              sbc     .near _g_lines
              sta     long:RL_LTAB,x
              iny
              iny
              iny
              iny
              inx
              inx
              bra     5$
6$:           rtl

;;; rlSave3: for rlSave: the sectors.
              .section coldcode, text
rlSave3:      lda     .near _g_sectors
              sta     dp:.tiny (_Dp+4)
              lda     .near (_g_sectors+2)
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_SEC_LINES
              lda     [.tiny (_Dp+4)],y
              sta     dp:.tiny MA
              ldx     ##0
              lda     .near _g_numsectors
              sta     dp:.tiny MB
              beq     9$
1$:           ldy     ##OFS_SEC_SOUNDORG
2$:           lda     [.tiny (_Dp+4)],y
              sta     long:RL_SECS,x
              inx
              inx
              iny
              iny
              cpy     ##(OFS_SEC_SOUNDORG + 8)
              bcc     2$
              ldy     ##OFS_SEC_LINECOUNT
              lda     [.tiny (_Dp+4)],y
              sta     long:RL_SECS,x
              ldy     ##OFS_SEC_LINES
              lda     [.tiny (_Dp+4)],y
              sec
              sbc     dp:.tiny MA
              sta     long:(RL_SECS+2),x
              inx
              inx
              inx
              inx
              lda     dp:.tiny (_Dp+4)
              clc
              adc     ##SIZEOF_SEC
              sta     dp:.tiny (_Dp+4)
              dec     dp:.tiny MB
              bne     1$
9$:           rtl

              .section znear, bss
              .public numnodes, nodes
numnodes:     .space  2               ; the BSP nodes of the level
nodes:        .space  4
