;;; Macros of the thinker code in assembly (src/iigs/p_enemy65.s,
;;; src/iigs/p_mobj65.s). A public routine keeps its mobj in AP (_Dp+8,
;;; callee saved, its old value on the stack) for its helpers.
;;; The file that includes this one declares _Dp, mobjinfo and
;;; IIGS_MulLo16 extern.

AP            .equ    _Dp+8           ; the mobj

;;; Keep _Dp+8..11 and make AP the mobj of _Dp[0-3].
ENTER         .macro
              pei     dp:.tiny (_Dp+10)
              pei     dp:.tiny (_Dp+8)
              lda     dp:.tiny _Dp
              sta     dp:.tiny AP
              lda     dp:.tiny (_Dp+2)
              sta     dp:.tiny (AP+2)
              .endm

;;; Back to the caller of ENTER with C.
LEAVE         .macro
              tay
              pla
              sta     dp:.tiny AP
              pla
              sta     dp:.tiny (AP+2)
              tya
              rtl
              .endm

;;; _Dp[0-3] = AP, the first argument of a C function.
ARGAP         .macro
              lda     dp:.tiny AP
              sta     dp:.tiny _Dp
              lda     dp:.tiny (AP+2)
              sta     dp:.tiny (_Dp+2)
              .endm

;;; X = the near address of mobjinfo[mobj->type] (src/iigs/info.inc).
MINFO         .macro
              ldy     ##OFS_MO_TYPE
              lda     [.tiny AP],y
              INFOADDR
              tax
              .endm

;;; Signed 32-bit a < b: lda a.lo / cmp b.lo / lda a.hi / SLT32 b.hi / bmi
SLT32         .macro  op
              sbc     \op
              bvc     1$
              eor     ##0x8000
1$:
              .endm

;;; The same with the operand [p],y, p a direct page pointer.
SLT32Y        .macro  p
              sbc     [\p],y
              bvc     1$
              eor     ##0x8000
1$:
              .endm
