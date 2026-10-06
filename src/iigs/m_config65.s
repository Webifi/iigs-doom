;;; Settings and save slots.
;;; DOOM.SETTINGS is one block on disk 1 (tools/mkdisk.py).
;;; The loader supplies SETTINGS_IN and the drive details in BOOTINFO.
;;; G_SaveSettings writes only a changed file on the matching writable
;;; disk. A failed write leaves settingsKnown unchanged for a later retry.
;;;
;;; The file, one block:
;;;   0    "DOOMSET"
;;;   7    the version, 2; version 1 mouse speeds are converted on load
;;;   8    the sum of the bytes 12-511, 16 bits
;;;   12   gamma 0-4, always run, messages, the sound effect volume 0-15,
;;;        the music volume 0-15, the mouse, the mouse speed 0-15, the mouse
;;;        moves, the detail (0 high, 1 low), the view size (VW_SIZE), the
;;;        TWGS SLOW IRQ (VW_TWIRQ: 0 OFF, 1 CARD; 0 in older files)
;;;        J13 gameplay input (0 OFF, 1 ON; 0 in older files),
;;;        simplified walls (1 means Wall Textures OFF; byte 24), and grates
;;;        (0 original, 1 bars, 2 none; byte 25)
;;;        (1 byte each)
;;;   32   the Doom key of each ADB key code 0-127 (NOKEY: none)
;;;   160  the saved games (F_SLOTS, src/iigs/g_game65.s)

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "keys.inc"
#include "viewwin.inc"

              .extern _Dp, _g_gamma, _g_alwaysRun, showMessages
              .extern iigs_mouseon, iigs_mousespeed, iigs_mousemove, detailLevel
              .extern GG_T
              .extern R_SetDetail, J13SettingsInit, J13SettingsCollect
              .extern solidLoad, solidCollect
              .extern snd_SfxVolume, snd_MusicVolume, S_SetSfxVolume, S_SetMusicVolume
              .extern keyTable, bmSave, bmSaved, W_NeedDisk
PAD_WF        .equ    67              ; (the checks that W_NeedDisk does went)

SETTINGS_IN   .equ    0x007c00        ; bank 0, from the loader
BOOTINFO      .equ    0x007e00
BI_MAGIC      .equ    0               ; BOOTINFO: "DB",
BI_UNIT       .equ    2               ;   the ProDOS unit, the SmartPort
BI_SPUNIT     .equ    3               ;   unit of the boot drive,
BI_DRIVER     .equ    4               ;   the ProDOS block driver, the
BI_SPORT      .equ    6               ;   SmartPort entry of its slot,
BI_BLOCK      .equ    8               ;   the block of DOOM.SETTINGS,
BI_DISKS      .equ    10              ;   the number of the last disk,
BI_BUILD      .equ    12              ;   the build ID
BI_SIZE       .equ    16
HDRBUF        .equ    0x7800          ; bank 0 buffers for the drive (the
FILEBUF       .equ    0x7a00          ;   loader's HDR and BUF)
HDR_DISK      .equ    6               ; the disk header, src/iigs/loader.s
HDR_BUILD     .equ    432

FILE_SIZE     .equ    512
F_VERSION     .equ    7
F_SUM         .equ    8
F_GAMMA       .equ    12
F_RUN         .equ    13
F_MESSAGES    .equ    14
F_SFXVOL      .equ    15
F_MUSICVOL    .equ    16
F_MOUSE       .equ    17
F_MSPEED      .equ    18
F_MMOVE       .equ    19
F_DETAIL      .equ    20
F_TWIRQ       .equ    22              ; (21 is VW_FVSIZE)
F_KEYS        .equ    32
VERSION       .equ    2               ; Version 1 remains readable.
NOKEY         .equ    0xff            ; keyTable: no Doom key
ADB_KEYS      .equ    128

PD_CMD        .equ    0x42            ; the ProDOS block driver: command,
PD_UNIT       .equ    0x43            ;   unit, buffer, block (direct page 0)
PD_BUF        .equ    0x44
PD_BLOCK      .equ    0x46
PD_READ       .equ    1
PD_WRITE      .equ    2
SP_STATUS     .equ    0               ; SmartPort commands
ST_ONLINE     .equ    0x10            ; the status byte: a disk in the drive,
ST_PROTECTED  .equ    0x04            ;   write protected,
ST_SWITCHED   .equ    0x01            ;   disk switched (IIGS Tech Note #25)

              .section coldfar, bss
              .public settingsFile, bootInfo
settingsFile: .space  FILE_SIZE       ; the file, as it is in memory now
settingsKnown: .space FILE_SIZE       ; the file of the last load or write,
                                      ;   as collect makes it (clamped values,
                                      ;   or the defaults): the compare base
                                      ;   of G_SettingsChanged
bootInfo:     .space  BI_SIZE

              .section znear, bss
CF_I:         .space  2

              .section cfar, rodata
magic:        .ascii  "DOOMSET"
diskMagic:    .ascii  "DOOMGS"          ; the disk header

;;; ---------------------------------------------------------------------------
;;; Copy the loader's settings and BOOTINFO before their bank-0 space is
;;; reused. Initialize VW_TWIRQ before bmAccelOff and j13Enabled before input
;;; selection. Invalid files default both off; the final J13SettingsInit
;;; wrapper receives checkFile's carry and the normalized TWGS value in A16.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public I_InitSettings
I_InitSettings:
              ldx     ##FILE_SIZE - 2
1$:           lda     long:SETTINGS_IN,x
              sta     long:settingsFile,x
              dex
              dex
              bpl     1$
              ldx     ##BI_SIZE - 2
2$:           lda     long:BOOTINFO,x
              sta     long:bootInfo,x
              dex
              dex
              bpl     2$
              jsr     .kbank checkFile
              lda     ##0
              bcs     3$
              lda     long:(settingsFile+F_TWIRQ)
              jsr     .kbank flag
3$:           jmp     long:J13SettingsInit
              rtl

;;; ---------------------------------------------------------------------------
;;; G_LoadSettings: validate/clamp stored settings and convert version-1
;;; mouse speed to the current step. Invalid files retain defaults and
;;; clear save slots. collect normalizes the in-memory file to VERSION;
;;; settingsKnown receives the same bytes, so loading alone is not dirty.
;;; Disk writes occur only through the save path.
;;; ---------------------------------------------------------------------------
              .public G_LoadSettings, G_RememberSettings
G_LoadSettings:
              jsr     .kbank checkFile
              bcc     1$
              ldx     ##FILE_SIZE - 2       ; no valid file: all zeros
              lda     ##0
0$:           sta     long:settingsFile,x
              dex
              dex
              bpl     0$
              brl     9$
1$:           lda     long:(settingsFile+F_GAMMA)
              ldx     ##4
              jsr     .kbank inRange
              sta     .near _g_gamma
              lda     long:(settingsFile+F_RUN)
              jsr     .kbank flag
              sta     .near _g_alwaysRun
              lda     long:(settingsFile+F_MESSAGES)
              jsr     .kbank flag
              sta     .near showMessages
              lda     long:(settingsFile+F_MOUSE)
              jsr     .kbank flag
              sta     .near iigs_mouseon
              lda     long:(settingsFile+F_VERSION)
              and     ##0x00ff
              ldx     ##15                  ; Version 2 stores a 0-15 step.
              cmp     ##1
              bne     4$
              ldx     ##9                   ; Version 1 indexes msMap after clamping.
4$:           lda     long:(settingsFile+F_MSPEED)
              jsr     .kbank inRange
              cpx     ##9
              bne     5$
              tax
              lda     long:msMap,x
              and     ##0x00ff
5$:           sta     .near iigs_mousespeed
              lda     long:(settingsFile+F_MMOVE)
              jsr     .kbank flag
              sta     .near iigs_mousemove
              lda     long:(settingsFile+F_DETAIL)
              jsr     .kbank flag
              sta     .near detailLevel
              jsl     long:R_SetDetail
              lda     long:(settingsFile+F_SFXVOL)
              ldx     ##15
              jsr     .kbank inRange
              jsl     long:S_SetSfxVolume
              lda     long:(settingsFile+F_MUSICVOL)
              ldx     ##15
              jsr     .kbank inRange
              sta     .near snd_MusicVolume
              jsl     long:S_SetMusicVolume
              ldx     ##0                   ; the keys: a Doom key or none
2$:           lda     long:(settingsFile+F_KEYS),x
              and     ##0x00ff
              cmp     ##NUMKEYS
              bcc     3$
              lda     ##NOKEY
3$:           sta     .near CF_I
              phx
              txa
              asl     a
              tax
              lda     long:keyTable,x
              and     ##0xff00
              ora     .near CF_I
              sta     long:keyTable,x
              plx
              inx
              cpx     ##ADB_KEYS
              bcc     2$
9$:           jsl     long:solidLoad
              jsr     .kbank collect        ; normalize the in-memory file
;;; Also used after uiLoadSettings normalizes an old view setting.
G_RememberSettings:
              ldx     ##FILE_SIZE - 2
10$:          lda     long:settingsFile,x
              sta     long:settingsKnown,x
              dex
              dex
              bpl     10$
              rtl

;;; inRange: A16 = min(low byte of A, X). Keep X as the limit; CF_I is scratch.
inRange:      and     ##0x00ff
              stx     .near CF_I
              cmp     .near CF_I
              bcc     1$
              beq     1$
              txa
1$:           rts

;;; flag: C = 1 if the byte C is not 0, else 0.
flag:         and     ##0x00ff
              beq     1$
              lda     ##1
1$:           rts

;;; checkFile: carry clear for matching magic, version 1 or 2, and checksum.
;;; Validation leaves the stored version intact for G_LoadSettings to convert.
checkFile:    ldx     ##0
1$:           lda     long:settingsFile,x
              and     ##0x00ff
              sta     .near CF_I
              lda     long:magic,x
              and     ##0x00ff
              cmp     .near CF_I
              bne     8$
              inx
              cpx     ##F_VERSION
              bcc     1$
              lda     long:(settingsFile+F_VERSION)
              and     ##0x00ff
              dec     a                     ; Accept versions 1 and 2 only.
              cmp     ##VERSION
              bcs     8$
              jsr     .kbank fileSum
              cmp     long:(settingsFile+F_SUM)
              bne     8$
              clc
              rts
8$:           sec
              rts

;;; fileSum: C = the sum of the bytes 12-511 of settingsFile.
fileSum:      lda     ##0
              ldx     ##F_GAMMA
1$:           sta     .near CF_I
              lda     long:settingsFile,x
              and     ##0x00ff
              clc
              adc     .near CF_I
              inx
              cpx     ##FILE_SIZE
              bcc     1$
              rts

;;; collect: settingsFile gets the magic, the version, the settings of now
;;; and the sum (the saved games are there already). The view size is
;;; vwStored: 0 until the player picks one (src/iigs/m_speed65.s).
              .extern vwStored
collect:      ldx     ##F_VERSION - 1
1$:           lda     long:magic,x
              sep     #0x20
              sta     long:settingsFile,x
              rep     #0x20
              dex
              bpl     1$
              sep     #0x20
              lda     #VERSION
              sta     long:(settingsFile+F_VERSION)
              lda     .near _g_gamma
              sta     long:(settingsFile+F_GAMMA)
              lda     .near _g_alwaysRun
              sta     long:(settingsFile+F_RUN)
              lda     .near showMessages
              sta     long:(settingsFile+F_MESSAGES)
              lda     .near snd_SfxVolume
              sta     long:(settingsFile+F_SFXVOL)
              lda     .near snd_MusicVolume
              sta     long:(settingsFile+F_MUSICVOL)
              lda     .near iigs_mouseon
              sta     long:(settingsFile+F_MOUSE)
              lda     .near iigs_mousespeed
              sta     long:(settingsFile+F_MSPEED)
              lda     .near iigs_mousemove
              sta     long:(settingsFile+F_MMOVE)
              lda     .near detailLevel
              sta     long:(settingsFile+F_DETAIL)
              lda     long:vwStored         ; 0 until the player picks a size
              sta     long:(settingsFile+VW_FVSIZE)
              jsl     long:J13SettingsCollect ; A8: pack bytes 22/23 before checksum.
              jsl     long:solidCollect
              .space  4,0xea
              rep     #0x20
              ldx     ##0                   ; the Doom key of each ADB key
2$:           phx
              txa
              asl     a
              tax
              lda     long:keyTable,x
              plx
              sep     #0x20
              sta     long:(settingsFile+F_KEYS),x
              rep     #0x20
              inx
              cpx     ##ADB_KEYS
              bcc     2$
              jsr     .kbank fileSum
              sta     long:(settingsFile+F_SUM)
              rts

;;; ---------------------------------------------------------------------------
;;; G_SettingsChanged: collect current settings; return C = 1 if changed.
;;; G_SaveSettings: write changes, then update settingsKnown on success.
;;; Only SAVE SETTINGS and saving a game call it.
;;; ---------------------------------------------------------------------------
              .public G_SaveSettings, G_SettingsChanged, G_SaveUndo
G_SettingsChanged:
              jsr     .kbank collect
              jsr     .kbank changed
              lda     ##0
              rol     a
              rtl
G_SaveSettings:
              jsr     .kbank collect
              jsr     .kbank changed
              bcs     2$
              rtl                           ; no change
2$:           jsl     long:writeFile
              bcs     9$
              ldx     ##FILE_SIZE - 2
3$:           lda     long:settingsFile,x
              sta     long:settingsKnown,x
              dex
              dex
              bpl     3$
9$:           rtl

;;; changed: carry set when settingsFile differs from settingsKnown.
changed:      ldx     ##FILE_SIZE - 2
1$:           lda     long:settingsFile,x
              cmp     long:settingsKnown,x
              bne     2$
              dex
              dex
              bpl     1$
              clc
              rts
2$:           sec
              rts

;;; G_SaveUndo: after a failed write of a saved game: the saved games as
;;; the disk has them, the settings as they are now.
G_SaveUndo:   ldx     ##FILE_SIZE - 2
1$:           lda     long:settingsKnown,x
              sta     long:settingsFile,x
              dex
              dex
              bpl     1$
              jsr     .kbank collect
              rtl

;;; Sixteen turn gains, indexed by 2 * iigs_mousespeed. Each word is angle
;;; units per mouse count; 65536 units make a revolution. The calibration
;;; reference is 100 counts/inch: about 12.1..2.6 inches per half turn,
;;; with step 4 near 8 inches. Actual distance depends on the input device.
              .public mouseTurn, mouseMoveScale
mouseTurn:    .word   27, 30, 33, 37, 41, 45, 50, 55
              .word   61, 68, 75, 84, 93, 103, 114, 126

;;; Version 1 stores speed 0..9 with gain 15 + 3 * speed. Map to the
;;; closest half-turn distance in mouseTurn; gains below its range map to 0.
msMap:        .byte   0, 0, 0, 0, 0, 1, 2, 3, 4, 4

;;; A16 = signed mouse count, GG_T = turn gain. Preserve A and cap GG_T
;;; at 42 before mouseMovePart multiplies and divides by 16. This bounds
;;; movement independently of the faster turn settings. Reapplying the cap
;;; for vertical movement after horizontal strafing leaves it unchanged.
mouseMoveScale:
              pha
              lda     .near GG_T
              cmp     ##42
              bcc     1$
              lda     ##42
              sta     .near GG_T
1$:           pla
              rtl

;;; Preserve the following coldcode addresses and their cache placement.
              .space  3

;;; ---------------------------------------------------------------------------
;;; Slot firmware needs bank 0 code, D = 0, emulation mode and page-1 S.
;;; The wrappers restore native mode and the game stack; A/X/Y 16-bit
;;; in and out. Bank 0 ROM/I/O must be enabled and IRQs masked.
;;; IIGS_DiskBlock: C = PD_READ/PD_WRITE, X = block, Y = bank 0 buffer.
;;; IIGS_DiskStatus: C = SmartPort STATUS 0 byte. Carry set on error.
;;; ---------------------------------------------------------------------------
              .section code, text
              .public IIGS_DiskBlock, IIGS_DiskStatus
IIGS_DiskBlock:
              phd
              phb
              phk                           ; this bank: 0
              plb
              pha
              lda     ##0
              tcd
              pla
              sep     #0x20
              sta     dp:PD_CMD
              lda     long:(bootInfo+BI_UNIT)
              sta     dp:PD_UNIT
              rep     #0x20
              stx     dp:PD_BLOCK
              sty     dp:PD_BUF
              lda     long:(bootInfo+BI_DRIVER)
              sta     abs:dkTarget
              tsc
              sta     abs:dkStack
              sec
              xce
              jsr     abs:dkJump
              jmp     abs:dkBack

IIGS_DiskStatus:
              phd
              phb
              phk
              plb
              lda     ##0
              tcd
              sep     #0x20
              lda     long:(bootInfo+BI_SPUNIT)
              sta     abs:spUnit
              rep     #0x20
              lda     long:(bootInfo+BI_SPORT)
              sta     abs:dkTarget
              tsc
              sta     abs:dkStack
              sec
              xce
              jsr     abs:dkJump
              .byte   SP_STATUS
              .word   spParams
              lda     abs:spList            ; the status byte

;;; dkBack: native mode again with the stack of the game; C = the byte in A
;;; (8 bits), carry = the error of the firmware (carry).
dkBack:       sta     abs:dkResult
              lda     #0
              rol     a                     ; the error, over the mode change
              clc
              xce
              rep     #0x30
              and     ##1
              tax
              lda     abs:dkStack
              tcs
              lda     abs:dkResult
              and     ##0x00ff
              cpx     ##1                   ; carry: the error
              plb
              pld
              rtl

dkJump:       jmp     (abs:dkTarget)
dkTarget:     .word   0
dkStack:      .word   0
dkResult:     .word   0
spParams:     .byte   3                     ; STATUS: 3 parameters, the unit,
spUnit:       .byte   1                     ;   the status list, the code 0
              .word   spList
              .byte   0
spList:       .byte   0, 0, 0, 0

;;; writeFile: write to disk 1 of this build (W_NeedDisk of
;;; src/iigs/w_level65.s: a prompt until a drive holds it) unless it is
;;; write protected. Carry clear on success.
;;; vwcode keeps the remaining coldcode at its existing cache slots.
              .section vwcode, text
writeFile:    lda     long:(bootInfo+BI_MAGIC)
              cmp     ##('D' | ('B' << 8))
              bne     9$
              lda     long:(bootInfo+BI_BLOCK)
              bne     1$
9$:           sec
              rtl
1$:           php
              jsl     long:bmSave           ; Sign, entry TWGS config, ROM/I/O.
              ldx     ##FILE_SIZE - 2       ; the file to bank 0
2$:           lda     long:settingsFile,x
              sta     long:FILEBUF,x
              dex
              dex
              bpl     2$
              lda     ##3                   ; A disk change after the check
3$:           pha                           ;   needs the check again.
              lda     ##1                   ; disk 1 in a drive, the units of
              jsl     long:W_NeedDisk       ;   that drive in bootInfo (carry:
              bcs     7$                    ;   a one-disk set not of this build)
              jsl     long:IIGS_DiskStatus
7$:           ply                           ; (the tries; carry stays)
              bcs     8$
              bit     ##ST_SWITCHED
              beq     4$
              dey
              tya
              bne     3$
              bra     8$
4$:           and     ##(ST_ONLINE | ST_PROTECTED)
              cmp     ##ST_ONLINE
              bne     8$
              lda     long:(bootInfo+BI_BLOCK)
              tax
              lda     ##PD_WRITE
              ldy     ##FILEBUF
              jsl     long:IIGS_DiskBlock
              bcs     8$
              jsl     long:bmSaved          ; (IIGS_StartInterrupts)
              plp
              clc
              rtl
8$:           jsl     long:bmSaved
              plp
              sec
              rtl
              .space  PAD_WF                ; (vwcode keeps its layout)

;;; Take the view size of the validated file (vwStored for collect, VW_SIZE
;;; for the renderer) before G_LoadSettings. A size that is not one of the six
;;; counts as none: the speed test picks one (src/iigs/m_speed65.s).
;;; Cold wrapper only: all old configuration and renderer bytes stay put.
              .section onecold, text
              .public oneLoadSettings
              .extern speedStored
oneLoadSettings:
              jsr     .kbank checkFile
              jsl     long:speedStored      ; vwStored; A = the size, or 10
              sta     long:VW_SIZE
              jmp     long:G_LoadSettings
              .space  12                    ; (onecold keeps its layout)
