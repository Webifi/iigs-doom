;;; The columns of each drawseg for the scan of R_DrawSprite (src/iigs/
;;; r_sprite65.s), one byte each: x1 (255 when the drawseg neither clips
;;; sprites nor has a masked texture) and x2 of drawseg i at dsX1 + i and
;;; dsX2 + i; dsCount (a word) drawsegs. Their bank is cached: the scans of
;;; the sprites read these bytes hundreds of times a frame. Their cache
;;; slots $3500-$3601 overlap genColumn (src/iigs/r_seg65.s), which runs
;;; during wall production, before these repeated masked-pass scans.
;;; Keep frequently used masked-pass code out of these slots when moving
;;; either section; cached banks still alias by the low 15 address bits.
#include "memmap.inc"
dsX1          .equ    (MM_BV + 0xb500)
dsX2          .equ    (MM_BV + 0xb580)
dsCount       .equ    (MM_BV + 0xb600)
;;; DSADDR: the near address of drawsegs[i], a word for each i < 128 (made
;;; once by dsaInit of src/iigs/r_sprite65.s; slots $3602-$3701).
DSADDR        .equ    (MM_BV + 0xb602)
