;;; Random numbers in 65816 assembly.
;;;
;;; P_Random, M_Random and M_ClearRandom of m_random.c, with the
;;; same table and results.

              .rtmodel version, "1"
              .rtmodel core, "*"

              .section znear, bss
prndindex:    .space  2               ; the index of P_Random (low byte)
rndindex:     .space  2               ; the index of M_Random (low byte)

              .section cfar, rodata
rndtable:
              .byte   0, 8, 109, 220, 222, 241, 149, 107, 75, 248, 254, 140, 16, 66, 74, 21
              .byte   211, 47, 80, 242, 154, 27, 205, 128, 161, 89, 77, 36, 95, 110, 85, 48
              .byte   212, 140, 211, 249, 22, 79, 200, 50, 28, 188, 52, 140, 202, 120, 68, 145
              .byte   62, 70, 184, 190, 91, 197, 152, 224, 149, 104, 25, 178, 252, 182, 202, 182
              .byte   141, 197, 4, 81, 181, 242, 145, 42, 39, 227, 156, 198, 225, 193, 219, 93
              .byte   122, 175, 249, 0, 175, 143, 70, 239, 46, 246, 163, 53, 163, 109, 168, 135
              .byte   2, 235, 25, 92, 20, 145, 138, 77, 69, 166, 78, 176, 173, 212, 166, 113
              .byte   94, 161, 41, 50, 239, 49, 111, 164, 70, 60, 2, 37, 171, 75, 136, 156
              .byte   11, 56, 42, 146, 138, 229, 73, 146, 77, 61, 98, 196, 135, 106, 63, 197
              .byte   195, 86, 96, 203, 113, 101, 170, 247, 181, 113, 80, 250, 108, 7, 255, 237
              .byte   129, 226, 79, 107, 112, 166, 103, 241, 24, 223, 239, 120, 198, 58, 60, 82
              .byte   128, 3, 184, 66, 143, 224, 145, 224, 81, 206, 163, 45, 63, 90, 168, 114
              .byte   59, 33, 159, 95, 28, 139, 123, 98, 125, 196, 15, 70, 194, 253, 54, 14
              .byte   109, 226, 71, 17, 161, 93, 186, 87, 244, 138, 20, 52, 123, 251, 26, 36
              .byte   17, 46, 52, 231, 232, 76, 31, 221, 84, 37, 216, 165, 212, 106, 197, 242
              .byte   98, 43, 39, 175, 254, 145, 190, 84, 118, 222, 187, 136, 120, 163, 236, 249

;;; ---------------------------------------------------------------------------
;;; int16_t P_Random(void)      rndtable[++prndindex], the game random numbers
;;; int16_t M_Random(void)      rndtable[++rndindex], the others
;;; void M_ClearRandom(void)
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public P_Random, M_Random, M_ClearRandom
P_Random:     lda     .near prndindex
              inc     a
              and     ##0x00ff
              sta     .near prndindex
              tax
              lda     long:rndtable,x
              and     ##0x00ff
              rtl

M_Random:     lda     .near rndindex
              inc     a
              and     ##0x00ff
              sta     .near rndindex
              tax
              lda     long:rndtable,x
              and     ##0x00ff
              rtl

M_ClearRandom:
              stz     .near rndindex
              stz     .near prndindex
              rtl
