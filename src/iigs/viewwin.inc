;;; View-window state for full, 3/4, 2/3, half, 1/3 and 1/4 sizes. Reduced
;;; views retain the full field of view by skipping rows/columns, including
;;; the weapon. The status bar is independent. vwKeys in m_menu65.s changes
;;; VW_SIZE; view installers patch producer strides and replay dispatch.
;;; R_DrawLists (r_list65.s) draws retained columns and rows into a window in
;;; the middle: in the half view the even ones (80 x 84 bytes: bytes 40 to
;;; 119, rows 42 to 125), in the 2/3 view each column or row n with n mod 3
;;; < 2 (107 x 112 bytes: bytes 26 to 132, rows 28 to 139), and in the
;;; 1/3 view n mod 3 = 0 (54 x 56 bytes: bytes 53..106, rows 56..111).
;;; vwFrame of
;;; src/iigs/r_frame65.s sets VW_HALF and VW_THIRD for each frame and paints
;;; the border around the window. Bank MM_BV (src/iigs/memmap.inc), words.
#include "memmap.inc"
VW_SIZE       .equ    (MM_BV + 0xb800) ; the size the player picked: VW_HALFSIZE
                                      ;   for the half view, else 10 (full)
VW_CUR        .equ    (MM_BV + 0xb802) ; the size of this frame | VW_TAG
VW_TAG        .equ    0xa500          ;   (the RAM at start never matches)
VW_LEFT       .equ    (MM_BV + 0xb804) ; the window of the size: its first
VW_RIGHT      .equ    (MM_BV + 0xb806) ;   and last column, the row above it
VW_TOP        .equ    (MM_BV + 0xb80a) ;   (-1: none) and the row after it
VW_BOTTOM     .equ    (MM_BV + 0xb80c) ;   (168: none)
VW_BORDER     .equ    (MM_BV + 0xb80e) ; not 0: paint the border at the next view
VW_MSG        .equ    (MM_BV + 0xb810) ; message_on at the view before
VW_T          .equ    (MM_BV + 0xb812) ; the scratch words of the cold code
VW_ROW        .equ    (MM_BV + 0xb814)
VW_BASE       .equ    (MM_BV + 0xb816)
VW_PA         .equ    (MM_BV + 0xb818)
VW_PB         .equ    (MM_BV + 0xb81a)
VW_FILL       .equ    (MM_BV + 0xb81c)
VW_BSTRIP     .equ    (MM_BV + 0xb81e) ; not 0: paint only the rows of the message
                                      ;   strip at the next view (a message went off)
VW_BEND       .equ    (MM_BV + 0xb820) ; vwBorder: the row after its last row
VW_THIRD      .equ    (MM_BV + 0xb822) ; 1: this frame shows the 2/3 view
VW_HALF       .equ    (MM_BV + 0xb824) ; 1: this frame shows the half view
VW_STRIPV     .equ    (MM_BV + 0xb826) ; viewtop for the message strip test of
                                      ;   display (src/iigs/d_main65.s): 0 in
                                      ;   the half view (the view is not on it)
VW_HALFSIZE   .equ    5               ; VW_SIZE of the half view
VW_TWOSIZE    .equ    7               ; VW_SIZE of the 2/3 view
VW_INIT       .equ    (MM_BV + 0xb828) ; VW_INITTAG after the first view
VW_MHID       .equ    (MM_BV + 0xb82a) ; 1: the menu hid a message (stHide of
                                      ;   src/iigs/st_stuff65.s); 0 at each view
VW_INITTAG    .equ    0xa55a
VW_FVSIZE     .equ    21              ; the byte of VW_SIZE in the settings file
                                      ;   (settingsFile of src/iigs/m_config65.s:
                                      ;   a free byte, 0 in older files)
;;; The benchmark (bmStart of src/iigs/m_menu65.s).
VW_BENCH      .equ    (MM_BV + 0xb82c) ; VW_BENCHTAG while it runs
VW_BENCHTAG   .equ    0xb3c7          ;   (the RAM at start never matches)
VW_BKHZ       .equ    (MM_BV + 0xb82e) ; the CPU clock in kHz (bmClock)
VW_BACC       .equ    (MM_BV + 0xb830) ; the accelerator: + 1 a ZipGS, + 2 a
                                      ;   TransWarp GS (bmAccel)
VW_BQ         .equ    (MM_BV + 0xb834) ; 4: bmClock: the pass time of loop A
VW_BP         .equ    (MM_BV + 0xb83a) ; the end of the text (an offset)
VW_BN         .equ    (MM_BV + 0xb83c) ; 4: a number of the text
VW_BRT        .equ    (MM_BV + 0xb840) ; 4: the realtics
VW_BFRAMES    .equ    (MM_BV + 0xb844) ; the frames of the benchmark (bmTick)
VW_BCACHE     .equ    (MM_BV + 0xb848) ; the cache of the accelerator in KB (0:
                                      ;   not known)
VW_BROM       .equ    (MM_BV + 0xb84a) ; the ROM version (1 or 3)
VW_TWOWN      .equ    (MM_BV + 0xb84c) ; the TransWarp GS configuration of the
                                      ;   owner (bmAccelOff of m_menu65.s)
VW_TWON       .equ    (MM_BV + 0xb84e) ; VW_TWTAG: a TransWarp GS, its IRQ
VW_TWTAG      .equ    0x7a5c          ;   logic off by the game
;;; The sign of a slow step (bmBusyOn of src/iigs/m_menu65.s).
VW_LMAP       .equ    (MM_BV + 0xb850) ; the map of the last load (bmLoad)
VW_SGON       .equ    (MM_BV + 0xb852) ; 1: the sign is on the screen
VW_SGW        .equ    (MM_BV + 0xb960) ; the width of its patch
VW_SGD        .equ    (MM_BV + 0xb962) ; the offset of the next column's data
VW_SGC        .equ    (MM_BV + 0xb964) ; the next column
VW_SGT        .equ    (MM_BV + 0xb96c) ; scratch
VW_SGCOL      .equ    (MM_BV + 0xb970) ; 8 bytes: a column of a glyph
VW_BTXT       .equ    (MM_BV + 0xb860) ; the text of the result (to $4EB95F)

;;; The menu state, scratch and original screen colors.
UI_PALON      .equ    (MM_BV + 0xbb56) ; $4EB852 is VW_SGON.
UI_EDGE       .equ    (MM_BV + 0xb854)
UI_ITEM       .equ    (MM_BV + 0xb856)
UI_LEFT       .equ    (MM_BV + 0xb858)
UI_Y          .equ    (MM_BV + 0xb85a)
UI_KIND       .equ    (MM_BV + 0xb85c)
UI_VALUE      .equ    (MM_BV + 0xb85e)
UI_ROWS       .equ    (MM_BV + 0xb980) ; 200 saved row palette bytes
UI_OFFSET     .equ    (MM_BV + 0xba48)
UI_VIEWPAL    .equ    (MM_BV + 0xba4a)
UI_STRIPPAL   .equ    (MM_BV + 0xba4c)
UI_PICTURE    .equ    (MM_BV + 0xba4e)
UI_GRAY       .equ    (MM_BV + 0xba50) ; 16 gray maps, 16 bytes each
UI_PIDX       .equ    (MM_BV + 0xbb50)
UI_CMAP       .equ    (MM_BV + 0xbb52)
UI_BYTE       .equ    (MM_BV + 0xbb54)
UI_FONTBUF    .equ    (MM_BV + 0xbb58) ; 16 undithered red font shades
UI_PALETTES   .equ    (MM_BV + 0xbb68) ; 512 original hardware palette bytes
UI_GAMMA      .equ    (MM_BV + 0xbd68) ; gamma when the snapshot was taken
UI_SINGLETIC  .equ    (MM_BV + 0xbd6a) ; restore the diagnostic timedemo mode
UI_VIEWSAVE2  .equ    MM_VIEWSAVE2          ; (src/iigs/memmap.inc)

;;; One of every three source rows and columns; private flag, no new hot test.
VW_ONESIZE    .equ    3
VW_ONE        .equ    (MM_BV + 0xbd6c)

VW_QUARTERSIZE .equ 2
VW_THREEQUARTERSIZE .equ 8
