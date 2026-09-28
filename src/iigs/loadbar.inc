;;; The load bar in the strip at the bottom of the title picture (rows
;;; 191-199, palette 15 with the colors STRIP_COLORS of tools/gscolor.py).
;;; The loader (src/iigs/loader.s) fills LOAD_CELLS cells as the disks load
;;; (tools/mkdisk.py has the same LOAD_CELLS); the game fills the others as
;;; it makes its tables (I_InitProgress, src/iigs/i_viigs65.s).
BAR_ROW       .equ    193 * 160       ; rows 193-197
BAR_X         .equ    44              ; the first cell at pixel 44; cells of
BAR_CELLS     .equ    38              ;   5 x 5 pixels, 7 pixels apart
LOAD_CELLS    .equ    34
BAR_FULL      .equ    0x55            ; a full cell: 2 pixels of color 5
BAR_EMPTY     .equ    0x11            ; an empty cell: color 1 ($400)
