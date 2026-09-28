;;; Stage 1 boot block, disk block 0.
;;;
;;; The firmware loads block 0 to $0800 and jumps to $0801 in emulation
;;; mode with X = slot * 16. This code first checks that the computer is an
;;; Apple IIgs (with 6502 instructions only, so that an older Apple II can
;;; say so too). Then it loads the stage 2 loader (src/iigs/loader.s, the
;;; file DOOM.BOOT of tools/mkdisk.py) from blocks 8-19 to $6000 through the
;;; ProDOS block driver of the boot slot, and jumps to it with X = the unit
;;; number.

STAGE2_ADDR   .equ    0x6000
STAGE2_BLOCK  .equ    8
STAGE2_COUNT  .equ    6

PD_CMD        .equ    0x42
PD_UNIT       .equ    0x43
PD_BUF        .equ    0x44
PD_BLOCK      .equ    0x46
TMP           .equ    0x40

IDROUTINE     .equ    0xfe1f          ; carry clear on a IIgs only
HOME          .equ    0xfc58          ; the monitor: clear the text screen
COUT          .equ    0xfded          ;   and print a character

              .section boot, text, root, noreorder
              .public bootStart
bootStart:    .byte   0x01

entry:        sei
              cld
              stx     dp:PD_UNIT
              sec
              jsr     abs:IDROUTINE
              bcc     isGS
              jsr     abs:HOME
              ldx     #0
1$:           lda     abs:notGSText,x
              beq     hang6502
              jsr     abs:COUT
              inx
              bne     1$
hang6502:     jmp     abs:hang6502

isGS:         lda     dp:PD_UNIT
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              ora     #0xc0
              sta     abs:drvAddr+1
              sta     dp:TMP+1
              lda     #0xff
              sta     dp:TMP
              ldy     #0
              lda     (TMP),y
              sta     abs:drvAddr

              lda     #1
              sta     dp:PD_CMD
              lda     #.byte0 STAGE2_ADDR
              sta     dp:PD_BUF
              lda     #.byte1 STAGE2_ADDR
              sta     dp:PD_BUF+1
              lda     #STAGE2_BLOCK
              sta     dp:PD_BLOCK
              lda     #0
              sta     dp:PD_BLOCK+1
              lda     #STAGE2_COUNT
              sta     abs:count

readLoop:     jsr     abs:callDriver
              bcs     fail
              inc     dp:PD_BUF+1
              inc     dp:PD_BUF+1
              inc     dp:PD_BLOCK
              dec     abs:count
              bne     readLoop

              ldx     dp:PD_UNIT
              jmp     abs:STAGE2_ADDR

callDriver:   jmp     (abs:drvAddr)

fail:         ldx     #0
failLoop:     lda     abs:failText,x
              beq     hang
              sta     abs:0x0400,x
              inx
              bne     failLoop
hang:         bra     hang

failText:     .byte   'B'|0x80,'O'|0x80,'O'|0x80,'T'|0x80,' '|0x80
              .byte   'E'|0x80,'R'|0x80,'R'|0x80,'O'|0x80,'R'|0x80,0
notGSText:    .byte   'D'|0x80,'O'|0x80,'O'|0x80,'M'|0x80,' '|0x80
              .byte   'N'|0x80,'E'|0x80,'E'|0x80,'D'|0x80,'S'|0x80,' '|0x80
              .byte   'A'|0x80,'N'|0x80,' '|0x80
              .byte   'A'|0x80,'P'|0x80,'P'|0x80,'L'|0x80,'E'|0x80,' '|0x80
              .byte   'I'|0x80,'I'|0x80,'G'|0x80,'S'|0x80,'.'|0x80,0

drvAddr:      .word   0
count:        .byte   0
