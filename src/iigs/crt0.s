;;; Start of the program.
;;;
;;; The stage 2 loader jumps here in native mode with 16-bit registers. All
;;; code and initialized data are already in place, so only the sections
;;; without a source in data_init_table (the linker's list of the BSS
;;; sections) get zeros here. Then main (src/iigs/i_iigs65.s) runs.

              .rtmodel cstartup, "iigs"
              .rtmodel version, "1"
              .rtmodel core, "*"

              .section stack
              .section data_init_table

              .extern main
              .extern _DirectPageStart, _NearBaseAddress

;;; The pseudo registers in the direct page: the arguments of a call in
;;; _Dp+0..7, _Dp+8..19 kept by the callee.
              .section registers, noinit
              .public _Dp
_Dp:          .space  20

INIT_DEST     .equ    0               ; an entry of data_init_table: the
INIT_SRC      .equ    4               ;   destination, the source (0: zeros)
INIT_SIZE     .equ    8               ;   and the length
INIT_ENTRY    .equ    10

              .section startup, text, root, noreorder
              .public __program_start
              .public __program_root_section
__program_root_section:
__program_start:
              sei
              clc
              xce
              rep     #0x38
              ldx     ##.sectionEnd stack
              txs
              lda     ##_DirectPageStart
              tcd
              lda     ##.word2 _NearBaseAddress
              xba
              pha
              plb
              plb

;;; The linker pulls this part in when there is a section to initialize.
              .section startup, text, noroot, noreorder
              .public __data_initialization_needed
__data_initialization_needed:
              ldx     ##0
1$:           cpx     ##.word0 (.sectionSize data_init_table)
              bcs     9$
              lda     long:((.sectionStart data_init_table) + INIT_DEST),x
              sta     dp:.tiny _Dp
              lda     long:((.sectionStart data_init_table) + INIT_DEST + 2),x
              sta     dp:.tiny (_Dp+2)
              lda     long:((.sectionStart data_init_table) + INIT_SRC),x
              sta     dp:.tiny (_Dp+4)
              lda     long:((.sectionStart data_init_table) + INIT_SRC + 2),x
              sta     dp:.tiny (_Dp+6)
              lda     long:((.sectionStart data_init_table) + INIT_SIZE),x
              phx
              tax
              beq     8$
              ldy     ##0
              lda     dp:.tiny (_Dp+4)
              ora     dp:.tiny (_Dp+6)
              sep     #0x20
              beq     4$
3$:           lda     [.tiny (_Dp+4)],y     ; a copy
              sta     [.tiny _Dp],y
              iny
              dex
              bne     3$
              bra     7$
4$:           lda     #0                    ; zeros
5$:           sta     [.tiny _Dp],y
              iny
              dex
              bne     5$
7$:           rep     #0x20
8$:           pla
              clc
              adc     ##INIT_ENTRY
              tax
              bra     1$
9$:

              .section startup, text, root, noreorder
              lda     ##0
              jsl     long:main
halt:         bra     halt
