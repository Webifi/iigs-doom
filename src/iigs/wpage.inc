;;; Wall-producer scratch shared by r_wall65.s setup and r_seg65.s loops.
;;; W_* constants below are byte OFFSETS from D = WPAGE. Outside that
;;; environment, use WPAGE + W_* with an address mode that reaches bank 0.
;;; W_X2 is twice the logical column, for indexing word-sized clip arrays;
;;; record rows remain in full-view coordinates even for reduced views.

WPAGE         .equ    0x0a00          ; direct page of the loop, see src/iigs/iigs.scm
WPOFS         .equ    WPAGE - 0x0900  ; displacement from the default direct page

;;; Offsets $00-$2B mirror the default direct page's DC_* drawer inputs.
;;; R_CheckSegPage verifies this layout. Edges/scales below are 32-bit
;;; fixed-point accumulators; W_Y*/W_C*/W_F* row scratch is allocated as
;;; words but specialized loops use byte encodings described in segvar.inc.
W_TF          .equ    0x2c            ; topfrac, see above
W_TS          .equ    0x30            ; topstep
W_BF          .equ    0x34            ; bottomfrac
W_BS          .equ    0x38
W_PH          .equ    0x3c            ; pixhigh
W_PHS         .equ    0x40
W_PL          .equ    0x44            ; pixlow
W_PLS         .equ    0x48
W_SC          .equ    0x4c            ; rw_scale
W_SCS         .equ    0x50
W_X2END       .equ    0x54            ; rw_stopx * 2
W_X2          .equ    0x56            ; rw_x * 2
W_YL          .equ    0x58            ; the loops of src/iigs/segvar.inc use the
W_YH1         .equ    0x5a            ;   low bytes (see there), genColumn the
W_CT          .equ    0x5c            ;   words
W_FC          .equ    0x5e
W_CB1         .equ    0x60
W_FT          .equ    0x62
W_CC1         .equ    0x64
W_FC1         .equ    0x66
W_MID1        .equ    0x68
W_MID         .equ    0x6a
W_T           .equ    0x6c
W_TCX         .equ    0x6e            ; rw_x * 2 of the texture column below
W_TEXCOL      .equ    0x70            ; texturecolumn
W_XS          .equ    0x72            ; the 2/3 view: 2 * the next skipped
                                      ;   column (thirdStart of r_seg65.s)
W_SEGH        .equ    0x74            ; the view of the patches of R_SegHalf
                                      ;   of r_list65.s now (a word: 0 full,
                                      ;   1 half)
W_HD          .equ    0x77            ; the half view: the parity of rw_x (a
                                      ;   byte; halfStart of r_seg65.s); the
                                      ;   2/3 view: 1 when rw_x is skipped
W_TAN         .equ    0x78
W_M           .equ    0x7c
W_CANGLE      .equ    0x7e            ; rw_centerangle
W_OFFSET      .equ    0x80            ; rw_offset
W_DIST        .equ    0x82            ; rw_distance
W_MDIR        .equ    0x84            ; column table of the mid texture
W_MWM         .equ    0x88            ; its widthmask
W_MTM         .equ    0x8a            ; its texturemid >> 7
W_TDIR        .equ    0x8c            ; the same for the top texture
W_TWM         .equ    0x90
W_TTM         .equ    0x92
W_BDIR        .equ    0x94            ; and the bottom texture
W_BWM         .equ    0x98
W_BTM         .equ    0x9a
W_UDI         .equ    0x9c            ; texCol: the step of u a column: whole
W_UDF         .equ    0x9e            ;   part (2 bytes), fraction (a byte)
W_UF8         .equ    0x9f            ; texCol: the fraction of u (a byte)
W_UF          .equ    0xa0            ; texCol: the fraction of an exact u
W_UC          .equ    0xa2            ; texCol: the columns to the span end (a byte)
W_MASKP       .equ    0xa4            ; maskedtexturecol
W_UI          .equ    0xa8            ; texCol: the exact u of the span start (16.16)
W_UN          .equ    0xac            ; texCol: the exact u of the span end (16.16)
W_WSK         .equ    0xb0            ; not 0: the sprites of this frame end
                                      ;   above the weapon rows (wclipSprite
                                      ;   of src/iigs/r_frame65.s)
W_LV          .equ    0xb2            ; the light of the wall columns (a word):
                                      ;   startmap + 24 of the seg (SMAP) when
                                      ;   texRec lights each record by the scale
                                      ;   of its column (Doom's light); 0: all
                                      ;   records of the seg take W_CMP (one
                                      ;   light, the sky, a fixed colormap)
W_CMP         .equ    0xb4            ; the page of the colormap of the records
                                      ; (a byte): of the seg, the sky or the sprite
W_DIDSOLID    .equ    0xb6            ; low byte 1: a column became solid
W_MC          .equ    0xc0            ; markceiling
W_MF          .equ    0xc2            ; markfloor
W_SEGTEX      .equ    0xc4
W_MIDTEX      .equ    0xc6
W_TOPTEX      .equ    0xc8
W_BOTTEX      .equ    0xca
W_MASKED      .equ    0xcc
W_SKY         .equ    0xce            ; markceiling of a sky ceiling
W_YH          .equ    0xd0            ; genColumn
W_CC          .equ    0xd2
W_TOP         .equ    0xd4
W_BOT         .equ    0xd6
;;; 0xd8-0xd9: solidFlat's even/odd SHR bytes (SWB in solid65.s).
W_T4          .equ    0xda            ; 4 bytes for fstep
W_MH          .equ    0xe0            ; MULHI16: a high word
W_T2          .equ    0xe2
W_CEILW       .equ    0xe4            ; the fill bytes of the ceiling (even rows,
W_FLOORW      .equ    0xe6            ;   odd rows << 8) and of the floor
W_FSC         .equ    0xe8            ; the fill spans (src/iigs/lists.inc): the
W_FSP         .equ    0xe9            ;   stamp of this frame, the stamp of the
W_TOPR        .equ    0xea            ;   frame before (or none), the first row
W_BOTR        .equ    0xeb            ;   of the view, the row after it (bytes)
W_FSG         .equ    0xec            ; 1: this frame shows its view (display of
W_FSW         .equ    0xed            ;   src/iigs/d_main65.s); W_FSG of the
                                      ;   frame before
W_LCC         .equ    0xee            ; the ceiling and floor colors of W_CEILW
W_LFC         .equ    0xf0            ;   and W_FLOORW (0x80xx: none; each frame)
W_FCR         .equ    0xf6            ; segvar.inc: the floor clip of the column

;;; R_DrawVisSprite uses the direct page of the wall loop too, with these
;;; names for the variables that only the wall loop uses.
V_SS          .equ    W_TF            ; spryscale
V_E           .equ    W_TS            ; sprtopscreen + spryscale * texel row - 1
V_FCP         .equ    W_BF            ; mfloorclip
V_CCP         .equ    W_BS            ; mceilingclip
V_PATCH       .equ    W_PH
V_FRAC        .equ    W_PHS
V_XIS         .equ    W_PL            ; xiscale
V_COL         .equ    W_PLS           ; the post
V_TN          .equ    W_SC            ; YLTAB and YHTAB hold texel rows 0..V_TN-1
V_TM7         .equ    W_SC+2          ; texturemid >> 7
V_WIDTH       .equ    W_SCS
V_TD          .equ    W_YL            ; topdelta and length: bytes, the high
V_LEN         .equ    W_YH1           ;   bytes are 0
V_HI          .equ    W_CT            ; the floor clip of the column (the end
V_LO          .equ    W_FC            ;   of its rows), the first row: bytes,
                                      ;   the high bytes are 0
V_YL          .equ    W_CB1           ; the rows of a post: the first, the end
V_YH1         .equ    W_FT            ;   (bytes)
V_TEND        .equ    W_CC1
V_UNIT        .equ    W_FC1           ; spryscale is FRACUNIT: no table,
V_YH0         .equ    W_MID           ; YHTAB[t] = V_YH0 + t
V_CLIP        .equ    0xb8            ; not 0: the clip pass of the weapon (VS_CLIP)
V_RUN         .equ    0xba            ;   the first row of the run of posts
V_PYH         .equ    0xbc            ;   and the last row of the post before
V_QP          .equ    W_MDIR          ; pointers into T of src/iigs/mul.inc:
V_QM          .equ    W_TDIR          ;   &T[fL], &T[-fL], &T[fH], &T[-fH] of
V_QP2         .equ    W_BDIR          ;   fracstep = fH << 8 | fL
V_QM2         .equ    W_MH
V_K           .equ    0xfa            ; texturemid >> 7 - 85 * fracstep (lo16)
V_S2          .equ    0xfc            ; fracstep >> 1
V_TMID        .equ    W_OFFSET        ; texturemid (4 bytes, R_DrawVisSprite)
