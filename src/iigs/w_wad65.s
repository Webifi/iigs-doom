;;; The WAD directory in 65816 assembly, Doom8088: Apple IIgs Edition.
;;;
;;; w_wad.c with the same results. The disk loader puts the resident WAD
;;; (tools/levelimg.py: the directory of all lumps and the lumps of every
;;; map) in RAM at WAD_ADDR; no lump crosses a 64 KB bank, so a lump is used
;;; in place at WAD_ADDR + filepos (a lump below WAD_ADDR has a filepos that
;;; wraps). The lumps of a map come into the level window at its start, and
;;; the level loader (src/iigs/w_level65.s) sets their filepos. The
;;; directory (fileinfo) is also used in place. W_GetNumForName finds a
;;; name through the hash chains lumphash and lumpnext.

              .rtmodel version, "1"
              .rtmodel core, "*"

              .extern _Dp, printf, I_Error, IIGS_CopyHuge

#include "memmap.inc"

WAD_ADDR      .equ    MM_WAD
WAD_BANK      .equ    MM_WAD_BANK
LUMPHASH      .equ    256
MAXLUMPS      .equ    1536
FI_FILEPOS    .equ    0               ; filelump_t, 16 bytes
FI_SIZE       .equ    4
FI_NAME       .equ    8

              .section znear, bss
              .public fileinfo, numlumps
fileinfo:     .space  4               ; the directory, read by r_thing65.s
numlumps:     .space  2
WN_NAME:      .space  8               ; W_GetNumForName: the name, 0 padded
WN_H:         .space  2
WN_I:         .space  2
WN_C:         .space  2

              .section coldfar, bss
lumphash:     .space  (2 * LUMPHASH)  ; the first lump of each hash, -1: none
lumpnext:     .space  (2 * MAXLUMPS)  ; the next lump of the same hash

              .section cfar, rodata
msgAdding:    .asciz  "\tadding DOOM1.WAD\n"
msgShare:     .asciz  "\tshareware version.\n"
errLumps:     .asciz  "W_Init: %d lumps, more than %d"
errNotFound:  .asciz  "W_GetNumForName: %.8s not found"

;;; ---------------------------------------------------------------------------
;;; void W_Init(void): the directory of the WAD in RAM, the hash chains of
;;; the lump names (the first lump with a name is first in its chain).
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public W_Init, W_Shutdown
W_Init:       lda     ##.word0 msgAdding
              sta     dp:.tiny _Dp
              lda     ##.word2 msgAdding
              sta     dp:.tiny (_Dp+2)
              jsl     long:printf
              lda     ##.word0 msgShare
              sta     dp:.tiny _Dp
              lda     ##.word2 msgShare
              sta     dp:.tiny (_Dp+2)
              jsl     long:printf
              lda     long:(WAD_ADDR+8)     ; fileinfo = WAD_ADDR + infotableofs
              sta     .near fileinfo
              lda     long:(WAD_ADDR+10)
              clc
              adc     ##WAD_BANK
              sta     .near (fileinfo+2)
              lda     long:(WAD_ADDR+4)     ; numlumps
              sta     .near numlumps
              cmp     ##(MAXLUMPS+1)
              bcc     1$
              pea     #MAXLUMPS
              pha
              lda     ##.word0 errLumps
              sta     dp:.tiny _Dp
              lda     ##.word2 errLumps
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
1$:           ldx     ##(2 * LUMPHASH - 2)  ; no chains
              lda     ##0xffff
2$:           sta     long:lumphash,x
              dex
              dex
              bpl     2$
              lda     .near fileinfo        ; each lump from the last
              sta     dp:.tiny (_Dp+4)
              lda     .near (fileinfo+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near numlumps
3$:           dec     a
              bmi     4$
              sta     .near WN_I
              asl     a
              asl     a
              asl     a
              asl     a
              ora     ##FI_NAME
              tay
              jsr     .kbank hashName
              asl     a                     ; lumpnext[i] = lumphash[h]
              tax
              lda     long:lumphash,x
              pha
              lda     .near WN_I            ; lumphash[h] = i
              sta     long:lumphash,x
              asl     a
              tax
              pla
              sta     long:lumpnext,x
              lda     .near WN_I
              bra     3$
4$:
W_Shutdown:   rtl

;;; hashName: C = W_HashName of the name at [_Dp+4],y: h = h * 3 + c for
;;; each character up to 8 or a 0, in 8 bits. Y changes.
hashName:     stz     .near WN_H
              ldx     ##8
1$:           lda     [.tiny (_Dp+4)],y
              and     ##0x00ff
              beq     2$
              sta     .near WN_C
              lda     .near WN_H
              asl     a
              adc     .near WN_H
              clc
              adc     .near WN_C
              and     ##0x00ff
              sta     .near WN_H
              iny
              dex
              bne     1$
2$:           lda     .near WN_H
              rts

;;; ---------------------------------------------------------------------------
;;; int16_t W_GetNumForName(const char* name)     In: _Dp[0-3] = name.
;;; The lump of the name (8 characters or up to a 0); I_Error if none.
;;; ---------------------------------------------------------------------------
              .public W_GetNumForName
W_GetNumForName:
              pei     dp:.tiny (_Dp+2)      ; (the name for I_Error)
              pei     dp:.tiny _Dp
              ldy     ##0                   ; strncpy(name8, name, 8)
              sep     #0x20
1$:           lda     [.tiny _Dp],y
              beq     2$
              sta     abs:.near WN_NAME,y
              iny
              cpy     ##8
              bcc     1$
              bra     3$
2$:           sta     abs:.near WN_NAME,y   ; (A = 0)
              iny
              cpy     ##8
              bcc     2$
3$:           rep     #0x20
              lda     ##.near WN_NAME       ; h = W_HashName(name8)
              sta     dp:.tiny (_Dp+4)
              lda     ##.word2 WN_NAME
              sta     dp:.tiny (_Dp+6)
              ldy     ##0
              jsr     .kbank hashName
              asl     a
              tax
              lda     .near fileinfo        ; each lump of the chain
              sta     dp:.tiny (_Dp+4)
              lda     .near (fileinfo+2)
              sta     dp:.tiny (_Dp+6)
              lda     long:lumphash,x
4$:           cmp     ##0xffff
              beq     notFound
              sta     .near WN_I
              asl     a                     ; the same 8 bytes
              asl     a
              asl     a
              asl     a
              ora     ##FI_NAME
              tay
              lda     [.tiny (_Dp+4)],y
              cmp     .near WN_NAME
              bne     5$
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              cmp     .near (WN_NAME+2)
              bne     5$
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              cmp     .near (WN_NAME+4)
              bne     5$
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              cmp     .near (WN_NAME+6)
              bne     5$
              pla
              pla
              lda     .near WN_I
              rtl
5$:           lda     .near WN_I            ; i = lumpnext[i]
              asl     a
              tax
              lda     long:lumpnext,x
              bra     4$
notFound:     lda     ##.word0 errNotFound  ; (the name is on the stack)
              sta     dp:.tiny _Dp
              lda     ##.word2 errNotFound
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error

;;; ---------------------------------------------------------------------------
;;; const char __far* W_GetNameForNum(int16_t num)  In: C. Out: X:C.
;;; uint16_t W_LumpLength(int16_t num)
;;; ---------------------------------------------------------------------------
              .public W_GetNameForNum, W_LumpLength
W_GetNameForNum:
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     .near fileinfo
              pha
              lda     .near (fileinfo+2)
              adc     ##0
              tax
              pla
              clc
              adc     ##FI_NAME
              bcc     1$
              inx
1$:           rtl
W_LumpLength: jsr     .kbank entry
              ldy     ##FI_SIZE
              lda     [.tiny _Dp],y
              rtl

;;; entry: _Dp[0-3] = &fileinfo[C], Y = 0.
entry:        asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     .near fileinfo
              sta     dp:.tiny _Dp
              lda     .near (fileinfo+2)
              adc     ##0
              sta     dp:.tiny (_Dp+2)
              ldy     ##0
              rts

;;; ---------------------------------------------------------------------------
;;; const void __far* W_GetLumpByNum(int16_t num)   In: C. Out: X:C, the
;;; lump in place (WAD_ADDR + filepos). W_GetLumpByNumAutoFree and
;;; W_TryGetLumpByNum are the same. W_GetFirstInt16: its first word.
;;; W_IsLumpCached: always true.
;;; ---------------------------------------------------------------------------
              .public W_GetLumpByNum, W_GetLumpByNumAutoFree, W_TryGetLumpByNum
              .public W_GetFirstInt16, W_IsLumpCached
W_GetLumpByNum:
W_GetLumpByNumAutoFree:
W_TryGetLumpByNum:
              jsr     .kbank entry
              lda     [.tiny _Dp],y         ; (Y = FI_FILEPOS)
              pha
              iny
              iny
              lda     [.tiny _Dp],y
              clc
              adc     ##WAD_BANK
              tax
              pla
              rtl
W_GetFirstInt16:
              jsl     long:W_GetLumpByNum
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     [.tiny _Dp]
              rtl
W_IsLumpCached:
              lda     ##1
              rtl

;;; ---------------------------------------------------------------------------
;;; void W_ReadLumpByNum(int16_t num, void __far* ptr)
;;;   In: C = num, _Dp[0-3] = ptr.
;;; The lump to ptr; an odd size copies one byte more (as the XMS copy of
;;; z_zone.c).
;;; ---------------------------------------------------------------------------
              .public W_ReadLumpByNum
W_ReadLumpByNum:
              pei     dp:.tiny (_Dp+2)      ; (ptr)
              pei     dp:.tiny _Dp
              pha
              jsr     .kbank entry          ; length = (size + 1) & ~1
              ldy     ##FI_SIZE
              lda     [.tiny _Dp],y
              inc     a
              and     ##0xfffe
              sta     dp:.tiny (_Dp+4)
              stz     dp:.tiny (_Dp+6)
              pla
              jsl     long:W_GetLumpByNum   ; the source
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              pla                           ; IIGS_CopyHuge(ptr, lump, length)
              plx
              jsl     long:IIGS_CopyHuge
              rtl
