;;; Bank-bounded zone allocator.
;;;
;;; ZONE_FIRST_BANK..ZONE_LAST_BANK form a doubly linked list of blocks in
;;; address order, closed by a sentinel. Each block has a 16-byte header;
;;; next/prev encode addresses divided by 16. Reserved blocks at bank ends
;;; prevent an allocation from crossing a bank boundary.
;;; Allocation searches from rover and reclaims PU_CACHE blocks encountered
;;; on the way. WAD lump pointers refer outside the zone; Z_Free and
;;; Z_ChangeTagToCache ignore those pointers.

              .rtmodel version, "1"
              .rtmodel core, "*"

              .extern _Dp, printf, I_Error, memset

#include "memmap.inc"

MB_SIZE       .equ    0               ; memblock_t: uint32_t
MB_TAG        .equ    4
MB_USER       .equ    6               ; 0: a free block, 0:2: no user
MB_NEXT       .equ    10              ; segments
MB_PREV       .equ    12
PARAGRAPH     .equ    16
PU_STATIC     .equ    1
PU_LEVEL      .equ    2
PU_LEVSPEC    .equ    3
PU_CACHE      .equ    4
MINFRAGMENT   .equ    64
ZONE_FIRST_BANK .equ  MM_ZONE_FIRST
ZONE_LAST_BANK .equ   MM_ZONE_LAST
HEAPSIZE      .equ    ((ZONE_LAST_BANK - ZONE_FIRST_BANK) * 0xfff0 + 0x10000)

              .section znear, bss
SENTBUF:      .space  (2 * PARAGRAPH) ; the sentinel, 16-byte aligned in it
SENTINEL:     .space  2               ; segments: the sentinel
ROVER:        .space  2               ;   mainzone_rover_segment
ZB:           .space  2               ;   a block
ZO:           .space  2               ;   another block
ZBASE:        .space  2               ; Z_TryMalloc: base, rover, start
ZROV:         .space  2
ZSTART:       .space  2
ZSIZE:        .space  2               ; the size with the header
ZREQ:         .space  2               ; the size asked for
ZTAG:         .space  2
ZUSER:        .space  4
ZSUM:         .space  4
ZMAX:         .space  4
ZBANK:        .space  2
ZT:           .space  2

              .section cfar, rodata
msgZone:      .asciz  "%ld bytes allocated for zone\n"
errMalloc:    .asciz  "Z_Malloc: failed to allocate %u B, max free block %li B, total free %li"
errTouch:     .asciz  "Z_CheckHeap: block size does not touch the next block\n"
errLink:      .asciz  "Z_CheckHeap: next block doesn't have proper back link\n"
errFree:      .asciz  "Z_CheckHeap: two consecutive free blocks\n"

;;; ---------------------------------------------------------------------------
;;; void Z_Init(void): one free block in each bank, below a static block
;;; at the top of each bank but the last.
;;; ---------------------------------------------------------------------------
              .section farcode, text
              .public Z_Init
Z_Init:       lda     ##.near SENTBUF       ; the sentinel: static, no user
              clc
              adc     ##(PARAGRAPH-1)
              and     ##(0xffff - (PARAGRAPH-1))
              sta     dp:.tiny _Dp
              lda     ##.word2 SENTBUF
              sta     dp:.tiny (_Dp+2)
              jsr     .kbank segA
              sta     .near SENTINEL
              sta     .near ZO              ; prev
              ldy     ##MB_TAG
              lda     ##PU_STATIC
              sta     [.tiny _Dp],y
              jsr     .kbank noUser
              lda     ##ZONE_FIRST_BANK
              sta     .near ZBANK
1$:           stz     dp:.tiny (_Dp+4)      ; the free block of the bank
              lda     .near ZBANK
              sta     dp:.tiny (_Dp+6)
              ldx     ##0                   ; size 65520, the last 65536
              lda     ##(0x10000 - PARAGRAPH)
              ldy     .near ZBANK
              cpy     ##ZONE_LAST_BANK
              bne     2$
              inx
              lda     ##0
2$:           sta     [.tiny (_Dp+4)]
              txa
              ldy     ##(MB_SIZE+2)
              sta     [.tiny (_Dp+4)],y
              lda     ##0                   ; tag 0, no user
              ldy     ##MB_TAG
              sta     [.tiny (_Dp+4)],y
              ldy     ##MB_USER
              sta     [.tiny (_Dp+4)],y
              ldy     ##(MB_USER+2)
              sta     [.tiny (_Dp+4)],y
              lda     .near ZBANK           ; its segment: bank << 12
              xba
              asl     a
              asl     a
              asl     a
              asl     a
              jsr     .kbank linkNext
              lda     .near ZBANK
              cmp     ##ZONE_LAST_BANK
              beq     3$
              lda     ##(0x10000 - PARAGRAPH) ; the static block at the top
              sta     dp:.tiny (_Dp+4)
              lda     ##PARAGRAPH
              sta     [.tiny (_Dp+4)]
              lda     ##0
              ldy     ##(MB_SIZE+2)
              sta     [.tiny (_Dp+4)],y
              lda     ##PU_STATIC
              ldy     ##MB_TAG
              sta     [.tiny (_Dp+4)],y
              lda     ##2                   ; no user (0:2)
              ldy     ##MB_USER
              sta     [.tiny (_Dp+4)],y
              lda     ##0
              ldy     ##(MB_USER+2)
              sta     [.tiny (_Dp+4)],y
              lda     .near ZBANK           ; its segment: (bank << 12) + 0xfff
              xba
              asl     a
              asl     a
              asl     a
              asl     a
              ora     ##0x0fff
              jsr     .kbank linkNext
              inc     .near ZBANK
              brl     1$
3$:           lda     .near SENTINEL        ; the last block, the sentinel
              ldy     ##MB_NEXT
              sta     [.tiny _Dp],y
              jsr     .kbank ptrA
              lda     .near ZO
              ldy     ##MB_PREV
              sta     [.tiny _Dp],y
              lda     ##(ZONE_FIRST_BANK << 12)
              sta     .near ROVER
              pea     #(HEAPSIZE >> 16)     ; printf(msgZone, heapSize)
              pea     #(HEAPSIZE & 0xffff)
              lda     ##.word0 msgZone
              sta     dp:.tiny _Dp
              lda     ##.word2 msgZone
              sta     dp:.tiny (_Dp+2)
              jsl     long:printf
              pla
              pla
              rtl

;;; linkNext: the block at _Dp[4-7] with segment C comes after the block at
;;; _Dp[0-3] (segment ZO): its prev, the next of the other; then it is the
;;; block at _Dp[0-3] and ZO.
linkNext:     ldy     ##MB_NEXT
              sta     [.tiny _Dp],y
              tax
              lda     .near ZO
              ldy     ##MB_PREV
              sta     [.tiny (_Dp+4)],y
              stx     .near ZO
              lda     dp:.tiny (_Dp+4)
              sta     dp:.tiny _Dp
              lda     dp:.tiny (_Dp+6)
              sta     dp:.tiny (_Dp+2)
              rts

;;; noUser: the user of the block at _Dp[0-3] is 0:2 (not a user pointer).
noUser:       lda     ##2
              ldy     ##MB_USER
              sta     [.tiny _Dp],y
              lda     ##0
              ldy     ##(MB_USER+2)
              sta     [.tiny _Dp],y
              rts

;;; segA: C = the segment of the address at _Dp[0-3].
segA:         lda     dp:.tiny (_Dp+2)
              xba
              asl     a
              asl     a
              asl     a
              asl     a
              sta     .near ZT
              lda     dp:.tiny _Dp
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              ora     .near ZT
              rts

;;; ptrA: _Dp[0-3] = the block of segment C. ptrB: _Dp[4-7]. C, X stay.
ptrA:         pha
              asl     a
              asl     a
              asl     a
              asl     a
              sta     dp:.tiny _Dp
              lda     1,s
              xba
              and     ##0x00ff
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              sta     dp:.tiny (_Dp+2)
              pla
              rts
ptrB:         pha
              asl     a
              asl     a
              asl     a
              asl     a
              sta     dp:.tiny (_Dp+4)
              lda     1,s
              xba
              and     ##0x00ff
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              sta     dp:.tiny (_Dp+6)
              pla
              rts

;;; ---------------------------------------------------------------------------
;;; void Z_ChangeTagToCache(const void __far* ptr)   In: _Dp[0-3] = ptr.
;;; The block of ptr can be purged.
;;; ---------------------------------------------------------------------------
              .public Z_ChangeTagToCache
Z_ChangeTagToCache:
              lda     dp:.tiny (_Dp+2)      ; a lump: not in the zone banks
              cmp     ##(ZONE_LAST_BANK + 1)
              bcs     1$
              lda     dp:.tiny _Dp          ; the header
              sec
              sbc     ##PARAGRAPH
              sta     dp:.tiny _Dp
              lda     ##PU_CACHE
              ldy     ##MB_TAG
              sta     [.tiny _Dp],y
1$:           rtl

;;; ---------------------------------------------------------------------------
;;; void Z_Free(const void __far* ptr)     In: _Dp[0-3] = ptr.
;;; ---------------------------------------------------------------------------
              .public Z_Free
Z_Free:       lda     dp:.tiny (_Dp+2)      ; a lump: not in the zone banks
              cmp     ##(ZONE_LAST_BANK + 1)
              bcs     1$
              jsr     .kbank segA           ; the block before ptr
              dec     a
              sta     .near ZB
              jsr     .kbank freeBlock
1$:           rtl

;;; freeBlock: Z_FreeBlock(the block of segment ZB): the user pointer (if
;;; there is one) becomes NULL, the block is free and joins a free block
;;; before it and after it. The rover moves off a block that goes.
freeBlock:    lda     .near ZB
              jsr     .kbank ptrA
              ldy     ##MB_USER             ; D_FP_SEG(user) != 0: *user = NULL
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+4)
              and     ##0xfff0
              sta     .near ZT
              ldy     ##(MB_USER+2)
              lda     [.tiny _Dp],y
              sta     dp:.tiny (_Dp+6)
              and     ##0x000f
              ora     .near ZT
              beq     1$
              lda     ##0
              sta     [.tiny (_Dp+4)]
              ldy     ##2
              sta     [.tiny (_Dp+4)],y
1$:           lda     ##0                   ; free
              ldy     ##MB_USER
              sta     [.tiny _Dp],y
              ldy     ##(MB_USER+2)
              sta     [.tiny _Dp],y
              ldy     ##MB_TAG
              sta     [.tiny _Dp],y
              ldy     ##MB_PREV             ; a free block before it: joined
              lda     [.tiny _Dp],y
              sta     .near ZO
              jsr     .kbank ptrB
              jsr     .kbank isFreeB
              bne     3$
              jsr     .kbank addSize        ; other->size += block->size
              ldy     ##MB_NEXT             ; other->next = block->next
              lda     [.tiny _Dp],y
              sta     [.tiny (_Dp+4)],y
              jsr     .kbank ptrB           ; that block->prev = other
              lda     .near ZO
              ldy     ##MB_PREV
              sta     [.tiny (_Dp+4)],y
              lda     .near ZB              ; the rover
              cmp     .near ROVER
              bne     2$
              lda     .near ZO
              sta     .near ROVER
2$:           lda     .near ZO              ; block = other
              sta     .near ZB
              jsr     .kbank ptrA
3$:           ldy     ##MB_NEXT             ; a free block after it: joined
              lda     [.tiny _Dp],y
              sta     .near ZO
              jsr     .kbank ptrB
              jsr     .kbank isFreeB
              bne     5$
              lda     [.tiny _Dp]           ; block->size += other->size
              clc
              adc     [.tiny (_Dp+4)]
              sta     [.tiny _Dp]
              ldy     ##(MB_SIZE+2)
              lda     [.tiny _Dp],y
              adc     [.tiny (_Dp+4)],y
              sta     [.tiny _Dp],y
              ldy     ##MB_NEXT             ; block->next = other->next
              lda     [.tiny (_Dp+4)],y
              sta     [.tiny _Dp],y
              jsr     .kbank ptrB           ; that block->prev = block
              lda     .near ZB
              ldy     ##MB_PREV
              sta     [.tiny (_Dp+4)],y
              lda     .near ZO              ; the rover
              cmp     .near ROVER
              bne     5$
              lda     .near ZB
              sta     .near ROVER
5$:           rts

;;; isFreeB: Z set if the block at _Dp[4-7] is free (no user).
isFreeB:      ldy     ##MB_USER
              lda     [.tiny (_Dp+4)],y
              ldy     ##(MB_USER+2)
              ora     [.tiny (_Dp+4)],y
              rts

;;; isFreeA: Z set if the block at _Dp[0-3] is free.
isFreeA:      ldy     ##MB_USER
              lda     [.tiny _Dp],y
              ldy     ##(MB_USER+2)
              ora     [.tiny _Dp],y
              rts

;;; addSize: the size of the block at _Dp[4-7] += the size at _Dp[0-3].
addSize:      lda     [.tiny (_Dp+4)]
              clc
              adc     [.tiny _Dp]
              sta     [.tiny (_Dp+4)]
              ldy     ##(MB_SIZE+2)
              lda     [.tiny (_Dp+4)],y
              adc     [.tiny _Dp],y
              sta     [.tiny (_Dp+4)],y
              rts

;;; ---------------------------------------------------------------------------
;;; void __far* Z_MallocStatic(uint16_t size)                  In: C.
;;; void __far* Z_MallocLevel(uint16_t size, void __far*__far* user)
;;;   In: C = size, _Dp[0-3] = user.
;;; void __far* Z_CallocLevel(uint16_t size), Z_CallocLevSpec: 0 filled.
;;; Out: X:C. No room is an I_Error.
;;; ---------------------------------------------------------------------------
              .public Z_MallocStatic, Z_MallocLevel, Z_CallocLevel, Z_CallocLevSpec
Z_MallocStatic:
              ldx     ##PU_STATIC
              bra     noUserMalloc
Z_MallocLevel:
              ldx     dp:.tiny _Dp
              stx     .near ZUSER
              ldx     dp:.tiny (_Dp+2)
              stx     .near (ZUSER+2)
              ldx     ##PU_LEVEL
              stx     .near ZTAG
              jsr     .kbank malloc
              rtl
Z_CallocLevel:
              ldx     ##PU_LEVEL
              bra     calloc
Z_CallocLevSpec:
              ldx     ##PU_LEVSPEC
calloc:       stx     .near ZTAG
              stz     .near ZUSER
              stz     .near (ZUSER+2)
              jsr     .kbank malloc
              sta     dp:.tiny _Dp          ; _fmemset(ptr, 0, size)
              stx     dp:.tiny (_Dp+2)
              lda     .near ZREQ
              sta     dp:.tiny (_Dp+4)
              lda     ##0
              jsl     long:memset
              rtl
noUserMalloc: stx     .near ZTAG
              stz     .near ZUSER
              stz     .near (ZUSER+2)
              jsr     .kbank malloc
              rtl

;;; malloc: Z_Malloc(C, ZTAG, ZUSER): X:C = the new block, or I_Error.
malloc:       sta     .near ZREQ
              jsr     .kbank tryMalloc
              cpx     ##0
              bne     1$
              cmp     ##0
              bne     1$
              jsr     .kbank freeSums       ; I_Error(errMalloc, size,
              lda     .near (ZSUM+2)        ;   largest, total)
              pha
              lda     .near ZSUM
              pha
              lda     .near (ZMAX+2)
              pha
              lda     .near ZMAX
              pha
              lda     .near ZREQ
              pha
              lda     ##.word0 errMalloc
              sta     dp:.tiny _Dp
              lda     ##.word2 errMalloc
              sta     dp:.tiny (_Dp+2)
              jsl     long:I_Error
1$:           rts

;;; freeSums: ZMAX = Z_GetLargestFreeBlockSize(), ZSUM =
;;; Z_GetTotalFreeMemory().
freeSums:     stz     .near ZMAX
              stz     .near (ZMAX+2)
              stz     .near ZSUM
              stz     .near (ZSUM+2)
              lda     .near SENTINEL
              jsr     .kbank ptrA
1$:           ldy     ##MB_NEXT             ; each block after the sentinel
              lda     [.tiny _Dp],y
              cmp     .near SENTINEL
              beq     3$
              jsr     .kbank ptrA
              jsr     .kbank isFreeA
              bne     1$
              lda     [.tiny _Dp]           ; total += size
              clc
              adc     .near ZSUM
              sta     .near ZSUM
              ldy     ##(MB_SIZE+2)
              lda     [.tiny _Dp],y
              adc     .near (ZSUM+2)
              sta     .near (ZSUM+2)
              lda     .near ZMAX            ; size > largest: largest = size
              cmp     [.tiny _Dp]
              lda     .near (ZMAX+2)
              sbc     [.tiny _Dp],y
              bcs     1$
              lda     [.tiny _Dp]
              sta     .near ZMAX
              lda     [.tiny _Dp],y
              sta     .near (ZMAX+2)
              bra     1$
3$:           rts

;;; tryMalloc: Z_TryMalloc(ZREQ, ZTAG, ZUSER): X:C = the new block (after
;;; its header), 0: no room. The first free block that is large enough,
;;; from the rover (or the free block before it); purgable blocks on the
;;; way are freed. A rest of more than MINFRAGMENT bytes is a new free
;;; block. The next search starts after the new block.
tryMalloc:    lda     .near ZREQ            ; size: paragraphs, with the header
              clc
              adc     ##(PARAGRAPH-1)
              and     ##(0xffff - (PARAGRAPH-1))
              clc
              adc     ##PARAGRAPH
              sta     .near ZSIZE
              lda     .near ROVER           ; base = rover, or the free block
              sta     .near ZBASE           ; before it
              jsr     .kbank ptrA
              ldy     ##MB_PREV
              lda     [.tiny _Dp],y
              sta     .near ZO
              jsr     .kbank ptrB
              jsr     .kbank isFreeB
              bne     1$
              lda     .near ZO
              sta     .near ZBASE
1$:           lda     .near ZBASE           ; rover = base, start = base->prev
              sta     .near ZROV
              jsr     .kbank ptrA
              ldy     ##MB_PREV
              lda     [.tiny _Dp],y
              sta     .near ZSTART
2$:           lda     .near ZROV            ; all the way around: no room
              cmp     .near ZSTART
              bne     3$
              lda     ##0
              tax
              rts
3$:           jsr     .kbank ptrA
              jsr     .kbank isFreeA
              beq     5$
              ldy     ##MB_TAG
              lda     [.tiny _Dp],y
              cmp     ##PU_CACHE
              bcs     4$
              ldy     ##MB_NEXT             ; not purgable: base = rover =
              lda     [.tiny _Dp],y         ;   the next block
              sta     .near ZROV
              sta     .near ZBASE
              bra     6$
4$:           lda     .near ZBASE           ; purgable: base = base->prev,
              jsr     .kbank ptrA           ;   the rover block is freed,
              ldy     ##MB_PREV             ;   base = base->next,
              lda     [.tiny _Dp],y         ;   rover = base->next
              sta     .near ZBASE
              lda     .near ZROV
              sta     .near ZB
              jsr     .kbank freeBlock
              lda     .near ZBASE
              jsr     .kbank ptrA
              ldy     ##MB_NEXT
              lda     [.tiny _Dp],y
              sta     .near ZBASE
              jsr     .kbank ptrA
              ldy     ##MB_NEXT
              lda     [.tiny _Dp],y
              sta     .near ZROV
              bra     6$
5$:           ldy     ##MB_NEXT             ; free: rover = the next block
              lda     [.tiny _Dp],y
              sta     .near ZROV
6$:           lda     .near ZBASE           ; until base is free and large
              jsr     .kbank ptrA           ; enough
              jsr     .kbank isFreeA
              bne     2$
              ldy     ##(MB_SIZE+2)
              lda     [.tiny _Dp],y
              bne     7$
              lda     [.tiny _Dp]
              cmp     .near ZSIZE
              bcc     2$
7$:           lda     [.tiny _Dp]           ; the rest: base->size - size
              sec
              sbc     .near ZSIZE
              sta     .near ZSUM
              ldy     ##(MB_SIZE+2)
              lda     [.tiny _Dp],y
              sbc     ##0
              sta     .near (ZSUM+2)
              bmi     9$                    ; more than MINFRAGMENT: a free
              bne     8$                    ;   block after the new block
              lda     .near ZSUM
              cmp     ##(MINFRAGMENT+1)
              bcc     9$
8$:           lda     .near ZSIZE           ; its segment
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              clc
              adc     .near ZBASE
              sta     .near ZO
              jsr     .kbank ptrB
              lda     .near ZSUM            ; size, tag 0, no user
              sta     [.tiny (_Dp+4)]
              lda     .near (ZSUM+2)
              ldy     ##(MB_SIZE+2)
              sta     [.tiny (_Dp+4)],y
              lda     ##0
              ldy     ##MB_TAG
              sta     [.tiny (_Dp+4)],y
              ldy     ##MB_USER
              sta     [.tiny (_Dp+4)],y
              ldy     ##(MB_USER+2)
              sta     [.tiny (_Dp+4)],y
              ldy     ##MB_NEXT             ; next = base->next, prev = base
              lda     [.tiny _Dp],y
              sta     [.tiny (_Dp+4)],y
              lda     .near ZBASE
              ldy     ##MB_PREV
              sta     [.tiny (_Dp+4)],y
              ldy     ##MB_NEXT             ; base->next->prev = it
              lda     [.tiny _Dp],y
              jsr     .kbank ptrB
              lda     .near ZO
              ldy     ##MB_PREV
              sta     [.tiny (_Dp+4)],y
              lda     .near ZSIZE           ; base->size = size
              sta     [.tiny _Dp]
              lda     ##0
              ldy     ##(MB_SIZE+2)
              sta     [.tiny _Dp],y
              lda     .near ZO              ; base->next = it
              ldy     ##MB_NEXT
              sta     [.tiny _Dp],y
9$:           lda     .near ZTAG            ; the tag, the user or 0:2
              ldy     ##MB_TAG
              sta     [.tiny _Dp],y
              lda     .near ZUSER
              ora     .near (ZUSER+2)
              bne     10$
              jsr     .kbank noUser
              bra     11$
10$:          lda     .near ZUSER
              ldy     ##MB_USER
              sta     [.tiny _Dp],y
              lda     .near (ZUSER+2)
              ldy     ##(MB_USER+2)
              sta     [.tiny _Dp],y
11$:          ldy     ##MB_NEXT             ; the next search starts after it
              lda     [.tiny _Dp],y
              sta     .near ROVER
              lda     dp:.tiny _Dp          ; the memory after the header
              clc
              adc     ##PARAGRAPH
              ldx     dp:.tiny (_Dp+2)
              rts

;;; ---------------------------------------------------------------------------
;;; void Z_FreeTags(void): all the blocks of the level (PU_LEVEL,
;;; PU_LEVSPEC) are freed.
;;; ---------------------------------------------------------------------------
              .public Z_FreeTags
Z_FreeTags:   lda     .near SENTINEL
              jsr     .kbank ptrA
              ldy     ##MB_NEXT
              lda     [.tiny _Dp],y
1$:           cmp     .near SENTINEL        ; each block after the sentinel
              beq     3$
              sta     .near ZB
              jsr     .kbank ptrA
              ldy     ##MB_NEXT             ; the link before it is freed
              lda     [.tiny _Dp],y
              sta     .near ZROV
              jsr     .kbank isFreeA
              beq     2$
              ldy     ##MB_TAG
              lda     [.tiny _Dp],y
              cmp     ##PU_LEVEL
              bcc     2$
              cmp     ##PU_CACHE
              bcs     2$
              jsr     .kbank freeBlock
2$:           lda     .near ZROV
              bra     1$
3$:           rtl

;;; ---------------------------------------------------------------------------
;;; void Z_CheckHeap(void): I_Error if a block does not touch the next
;;; block, if a next block does not link back, or if two free blocks touch.
;;; ---------------------------------------------------------------------------
              .public Z_CheckHeap
Z_CheckHeap:  lda     .near SENTINEL
              jsr     .kbank ptrA
              ldy     ##MB_NEXT
              lda     [.tiny _Dp],y
              sta     .near ZB
1$:           lda     .near ZB
              jsr     .kbank ptrA
              ldy     ##MB_NEXT             ; the last block: done
              lda     [.tiny _Dp],y
              sta     .near ZO
              cmp     .near SENTINEL
              beq     9$
              ldy     ##(MB_SIZE+2)         ; segment + size / 16 == next
              lda     [.tiny _Dp],y         ; (32 bits)
              cmp     ##PARAGRAPH
              bcs     2$
              xba
              asl     a
              asl     a
              asl     a
              asl     a
              sta     .near ZT
              lda     [.tiny _Dp]
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              ora     .near ZT
              clc
              adc     .near ZB
              bcs     2$
              cmp     .near ZO
              beq     3$
2$:           lda     ##.word0 errTouch
              ldx     ##.word2 errTouch
              bra     8$
3$:           lda     .near ZO              ; next->prev == block
              jsr     .kbank ptrB
              ldy     ##MB_PREV
              lda     [.tiny (_Dp+4)],y
              cmp     .near ZB
              beq     4$
              lda     ##.word0 errLink
              ldx     ##.word2 errLink
              bra     8$
4$:           jsr     .kbank isFreeA        ; not both free
              bne     5$
              jsr     .kbank isFreeB
              bne     5$
              lda     ##.word0 errFree
              ldx     ##.word2 errFree
              bra     8$
5$:           lda     .near ZO
              sta     .near ZB
              bra     1$
8$:           sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              jsl     long:I_Error
9$:           rtl

;;; ---------------------------------------------------------------------------
;;; boolean Z_EqualNames(const char __far* farName, const char* nearName)
;;;   In: _Dp[0-3], _Dp[4-7]. Out: C = 1 if the 8 bytes are the same.
;;; ---------------------------------------------------------------------------
              .public Z_EqualNames
Z_EqualNames: ldy     ##6
1$:           lda     [.tiny _Dp],y
              cmp     [.tiny (_Dp+4)],y
              bne     2$
              dey
              dey
              bpl     1$
              lda     ##1
              rtl
2$:           lda     ##0
              rtl
