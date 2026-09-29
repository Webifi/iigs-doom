;;; The load bar in the strip at the bottom of the title picture (rows
;;; 191-199, palette 15 with the colors STRIP_COLORS of tools/gscolor.py).
;;; The loader (src/iigs/loader.s) fills LOAD_CELLS cells as the disks load.
;;; tools/mkdisk.py stores two steps for the blocks a boot reads: one when
;;; the store stays on disk, one when it loads (its banks are RAM). Each
;;; medium has its own pair (the floppies, the hard disk). The game fills
;;; the other cells during the first load (w_level65.s), a byte at a time,
;;; before the title or the first demo is shown.
BAR_ROW       .equ    193 * 160       ; rows 193-197
BAR_X         .equ    44              ; the first cell at pixel 44; cells of
BAR_CELLS     .equ    38              ;   5 x 5 pixels, 7 pixels apart
LOAD_CELLS    .equ    34
BAR_FULL      .equ    0x55            ; a full cell: 2 pixels of color 5
BAR_EMPTY     .equ    0x11            ; an empty cell: color 1 ($400)
