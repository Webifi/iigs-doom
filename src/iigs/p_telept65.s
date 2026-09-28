;;; Teleporters in 65816 assembly, Doom8088: Apple IIgs Edition.
;;;
;;; p_telept.c with the same results. P_TeleportMove is in
;;; src/iigs/p_map65.s.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"

;;; CLEAN: the byte 11 of a mobj (the high byte of its thinker function,
;;; 0 in a pointer) is 1 once P_RunThinkers found the mobj with no momentum
;;; on its floor; a change of its momentum, z or floorz clears it.
CLEARCLEAN    .macro  p
              sep     #0x20
              lda     #0
              ldy     ##(OFS_TH_FUNCTION+3)
              sta     [.tiny \p],y
              rep     #0x20
              .endm


              .extern _Dp, _g_sectors, _g_player, _g_thinkerclasscap
              .extern P_FindSectorFromLineTag, IIGS_MulLo16, P_MobjThinker
              .extern P_TeleportMove, P_SpawnMobj, S_StartSound
              .extern finesine, finecosine

CAP           .equ    _g_thinkerclasscap

              .section znear, bss
TP_LINE:      .space  4
TP_THING:     .space  4
TP_PLAYER:    .space  2               ; 1: the thing is the player
TP_I:         .space  2               ; the sector number
TP_SEC:       .space  4               ; the sector
TP_M:         .space  4               ; the destination
TP_OX:        .space  4               ; the old position
TP_OY:        .space  4
TP_OZ:        .space  4
TP_T:         .space  4

;;; ---------------------------------------------------------------------------
;;; boolean EV_Teleport(const line_t __far* line, int16_t side, mobj_t __far* thing)
;;;   In: _Dp[0-3] = line, C = side, _Dp[4-7] = thing.
;;; A thing on the front side (not a missile) goes to the teleport
;;; destination in a sector with the tag of the line, with fog and sound at
;;; both ends, and stops there.
;;; ---------------------------------------------------------------------------
              .section coldcode, text
              .public EV_Teleport
EV_Teleport:  cmp     ##0                   ; the back side: no
              bne     no
              lda     dp:.tiny _Dp
              sta     .near TP_LINE
              lda     dp:.tiny (_Dp+2)
              sta     .near (TP_LINE+2)
              lda     dp:.tiny (_Dp+4)
              sta     .near TP_THING
              lda     dp:.tiny (_Dp+6)
              sta     .near (TP_THING+2)
              ldy     ##(OFS_MO_FLAGS+2)    ; a missile: no
              lda     [.tiny (_Dp+4)],y
              and     ##CONST_MF_MISSILE_HI
              bne     no
              jsr     .kbank destination
              bcs     found
no:           lda     ##0
              rtl
found:        stz     .near TP_PLAYER       ; the player (P_MobjIsPlayer)
              lda     .near (_g_player+OFS_PL_MO)
              cmp     .near TP_THING
              bne     2$
              lda     .near (_g_player+OFS_PL_MO+2)
              cmp     .near (TP_THING+2)
              bne     2$
              inc     .near TP_PLAYER
2$:           jsr     .kbank thingArg       ; the old position
              ldy     ##OFS_MO_X
              ldx     ##0
3$:           lda     [.tiny _Dp],y
              sta     abs:.near TP_OX,x
              iny
              iny
              inx
              inx
              cpx     ##12
              bcc     3$
              pea     #0                    ; P_TeleportMove(thing, m->x, m->y, false)
              jsr     .kbank destArg
              ldy     ##OFS_MO_Y
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_MO_X
              lda     [.tiny _Dp],y
              pha
              jsr     .kbank thingArg
              pla
              jsl     long:P_TeleportMove
              ply
              cmp     ##0
              beq     no
              jsr     .kbank thingArg       ; z = floorz
              CLEARCLEAN _Dp
              ldy     ##OFS_MO_FLOORZ
              lda     [.tiny _Dp],y
              ldy     ##OFS_MO_Z
              sta     [.tiny _Dp],y
              ldy     ##(OFS_MO_FLOORZ+2)
              lda     [.tiny _Dp],y
              ldy     ##(OFS_MO_Z+2)
              sta     [.tiny _Dp],y
              lda     .near TP_PLAYER       ; the player: viewz = z + viewheight
              beq     4$
              ldy     ##OFS_MO_Z
              lda     [.tiny _Dp],y
              clc
              adc     .near (_g_player+OFS_PL_VIEWHEIGHT)
              sta     .near (_g_player+OFS_PL_VIEWZ)
              ldy     ##(OFS_MO_Z+2)
              lda     [.tiny _Dp],y
              adc     .near (_g_player+OFS_PL_VIEWHEIGHT+2)
              sta     .near (_g_player+OFS_PL_VIEWZ+2)
4$:           lda     .near TP_OY           ; the fog at the old position
              sta     dp:.tiny _Dp
              lda     .near (TP_OY+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near TP_OZ
              sta     dp:.tiny (_Dp+4)
              lda     .near (TP_OZ+2)
              sta     dp:.tiny (_Dp+6)
              lda     .near TP_OX
              ldx     .near (TP_OX+2)
              jsr     .kbank fogSound
              jsr     .kbank destArg        ; the fog 20 units in front of the
              ldy     ##(OFS_MO_ANGLE+2)    ; destination: an = angle >> 19
              lda     [.tiny _Dp],y
              lsr     a
              lsr     a
              lsr     a
              pha
              jsl     long:finesine         ; y + 20 * finesine(an)
              jsr     .kbank times20
              jsr     .kbank destArg
              ldy     ##OFS_MO_Y
              lda     [.tiny _Dp],y
              clc
              adc     .near TP_T
              sta     .near TP_OY
              iny
              iny
              lda     [.tiny _Dp],y
              adc     .near (TP_T+2)
              sta     .near (TP_OY+2)
              pla
              jsl     long:finecosine       ; x + 20 * finecosine(an)
              jsr     .kbank times20
              jsr     .kbank destArg
              ldy     ##OFS_MO_X
              lda     [.tiny _Dp],y
              clc
              adc     .near TP_T
              sta     .near TP_OX
              iny
              iny
              lda     [.tiny _Dp],y
              adc     .near (TP_T+2)
              sta     .near (TP_OX+2)
              jsr     .kbank thingArg       ; P_SpawnMobj(x, y, thing->z, MT_TFOG)
              ldy     ##OFS_MO_Z
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              iny
              iny
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              lda     .near TP_OY
              sta     dp:.tiny _Dp
              lda     .near (TP_OY+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near TP_OX
              ldx     .near (TP_OX+2)
              jsr     .kbank fogSound
              jsr     .kbank thingArg
              lda     .near TP_PLAYER       ; the player waits 18 tics
              beq     5$
              lda     ##18
              ldy     ##OFS_MO_REACTIONTIME
              sta     [.tiny _Dp],y
5$:           jsr     .kbank destArg        ; angle = m->angle
              ldy     ##(OFS_MO_ANGLE+2)
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_MO_ANGLE
              lda     [.tiny _Dp],y
              pha
              jsr     .kbank thingArg
              pla
              sta     [.tiny _Dp],y
              iny
              iny
              txa
              sta     [.tiny _Dp],y
              lda     ##0                   ; no momentum
              ldy     ##OFS_MO_MOMX
6$:           sta     [.tiny _Dp],y
              iny
              iny
              cpy     ##(OFS_MO_MOMZ+4)
              bcc     6$
              ldx     .near TP_PLAYER       ; the player: no bob momentum
              beq     7$
              sta     .near (_g_player+OFS_PL_MOMX)
              sta     .near (_g_player+OFS_PL_MOMX+2)
              sta     .near (_g_player+OFS_PL_MOMY)
              sta     .near (_g_player+OFS_PL_MOMY+2)
7$:           lda     ##1
              rtl

;;; fogSound: S_StartSound(P_SpawnMobj(X:C, _Dp[0-3], _Dp[4-7], MT_TFOG),
;;; sfx_telept).
fogSound:     pea     #CONST_MT_TFOG
              jsl     long:P_SpawnMobj
              ply
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     ##CONST_SFX_TELEPT
              jsl     long:S_StartSound
              rts

;;; times20: TP_T = 20 * X:C (fixed_t, the low 32 bits).
times20:      sta     .near TP_T            ; 4 * v
              stx     .near (TP_T+2)
              asl     .near TP_T
              rol     .near (TP_T+2)
              asl     .near TP_T
              rol     .near (TP_T+2)
              lda     .near TP_T            ; + 16 * v
              ldx     .near (TP_T+2)
              sta     .near TP_OZ
              stx     .near (TP_OZ+2)
              asl     .near TP_OZ
              rol     .near (TP_OZ+2)
              asl     .near TP_OZ
              rol     .near (TP_OZ+2)
              lda     .near TP_T
              clc
              adc     .near TP_OZ
              sta     .near TP_T
              lda     .near (TP_T+2)
              adc     .near (TP_OZ+2)
              sta     .near (TP_T+2)
              rts

;;; thingArg, destArg: _Dp[0-3] = TP_THING, TP_M.
thingArg:     lda     .near TP_THING
              sta     dp:.tiny _Dp
              lda     .near (TP_THING+2)
              sta     dp:.tiny (_Dp+2)
              rts
destArg:      lda     .near TP_M
              sta     dp:.tiny _Dp
              lda     .near (TP_M+2)
              sta     dp:.tiny (_Dp+2)
              rts

;;; destination: P_TeleportDestination(TP_LINE): for each sector with the
;;; tag of the line, the first teleport destination thing in it (in the
;;; order of the thinkers). Carry set when there is one: TP_M.
destination:  lda     ##0xffff
              sta     .near TP_I
1$:           lda     .near TP_LINE
              sta     dp:.tiny _Dp
              lda     .near (TP_LINE+2)
              sta     dp:.tiny (_Dp+2)
              lda     .near TP_I
              jsl     long:P_FindSectorFromLineTag
              sta     .near TP_I
              cmp     ##0
              bpl     2$
              clc
              rts
2$:           ldx     ##SIZEOF_SEC
              jsl     long:IIGS_MulLo16
              clc
              adc     .near _g_sectors
              sta     .near TP_SEC
              lda     .near (_g_sectors+2)
              sta     .near (TP_SEC+2)
              lda     .near (CAP+OFS_TH_NEXT) ; th = the first thinker
              sta     dp:.tiny _Dp
              lda     .near (CAP+OFS_TH_NEXT+2)
              sta     dp:.tiny (_Dp+2)
3$:           lda     dp:.tiny _Dp          ; the head again: the next sector
              cmp     ##.near CAP
              bne     4$
              lda     dp:.tiny (_Dp+2)
              cmp     ##.word2 CAP
              beq     1$
4$:           ldy     ##OFS_TH_FUNCTION     ; a mobj
              lda     [.tiny _Dp],y
              cmp     ##.word0 P_MobjThinker
              bne     5$
              iny
              iny
              lda     [.tiny _Dp],y
              and     ##0x00ff              ; (not CLEAN)
              cmp     ##.word2 P_MobjThinker
              bne     5$
              ldy     ##OFS_MO_TYPE         ; a teleport destination
              lda     [.tiny _Dp],y
              cmp     ##CONST_MT_TELEPORTMAN
              bne     5$
              ldy     ##(OFS_MO_SUBSECTOR+2) ; in the sector
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              ldy     ##OFS_MO_SUBSECTOR
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              ldy     ##OFS_SUB_SECTOR
              lda     [.tiny (_Dp+4)],y
              cmp     .near TP_SEC
              bne     5$
              iny
              iny
              lda     [.tiny (_Dp+4)],y
              cmp     .near (TP_SEC+2)
              bne     5$
              lda     dp:.tiny _Dp
              sta     .near TP_M
              lda     dp:.tiny (_Dp+2)
              sta     .near (TP_M+2)
              sec
              rts
5$:           ldy     ##(OFS_TH_NEXT+2)     ; th = th->next
              lda     [.tiny _Dp],y
              tax
              ldy     ##OFS_TH_NEXT
              lda     [.tiny _Dp],y
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              bra     3$
