;;; Products of a byte with the quarter squares T of src/iigs/m_fixed65.s
;;; (iigs_mulT): x * y = T[x + y] - T[x - y] for bytes x and y, T[k] =
;;; k * k / 4 for k = -255..510, 16 bits. T is 1532 bytes in the cache slots
;;; $1800-$1DFB, which the view stores never use (src/iigs/iigs.scm), so its
;;; reads hit and fill the cycles after each store. For a byte operand this
;;; beats the large tables SQL and SQH; for 16 x 16 it does not (four
;;; products). MULT0 = &T[0].
;;; qp, qm: long pointers in the direct page, with the bank of T in their
;;; third byte. 16-bit A, X, Y.

;;; QSET qp, qm: qp = &T[y], qm = &T[-y], for C = 2y. Destroys X.
QSET          .macro  qp, qm
              tax
              clc
              adc     ##.word0 MULT0
              sta     dp:\qp
              txa
              eor     ##0xffff
              sec
              adc     ##.word0 MULT0
              sta     dp:\qm
              .endm

;;; QPROD qp, qm: C = x * y, for Y = 2x.
QPROD         .macro  qp, qm
              lda     [\qp],y
              sec
              sbc     [\qm],y
              .endm
