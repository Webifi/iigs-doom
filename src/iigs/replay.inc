;;; The one-byte row exit patch turns [XBA/TYA, ADC dp] into JMP (abs).
;;; ADC's opcode $65 becomes the pointer low byte; its DP operand is high.
;;; Use $84-$87 so all three pointers land outside bank-0 video memory.
;;; Cache slots stay $0465/$0565/$0765 (32 KB direct mapped).
;;; These four bytes alias producer scratch: final replay owns them; the
;;; overflow flush saves/restores them in flushReplay. Keep DC_SF/DC_SI at
;;; their original addresses for the game-logic aliases in p_map65.s.
              .extern _DirectPageStart
RS_SF         .equ _DirectPageStart+0x84
RS_SI         .equ _DirectPageStart+0x86
RS_RET        .equ 0x008465
RS_PAIR       .equ 0x008565
RS_SHORT      .equ 0x008765
