;;; The record sizes of the state and thing tables of src/iigs/info65.s. They
;;; are powers of two, so the address of a record is its number shifted.

STATE_SIZE    .equ    16              ; state_t (SIZEOF_ST 12) and 4 free
INFO_SIZE     .equ    64              ; mobjinfo_t (SIZEOF_MI 51) and 13 free

;;; STATEADDR: C = the near address of state C: states + 16 * C.
STATEADDR     .macro
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     ##.near states
              .endm

;;; INFOINDEX: C = 64 * the thing type C (type < 256).
INFOINDEX     .macro
              xba
              lsr     a
              lsr     a
              .endm

;;; INFOADDR: C = the near address of thing type C: mobjinfo + 64 * C.
INFOADDR      .macro
              INFOINDEX
              clc
              adc     ##.near mobjinfo
              .endm
