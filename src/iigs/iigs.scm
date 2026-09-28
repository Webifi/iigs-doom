;;; Apple IIgs memory map, 4 MB RAM or more. The linker places banks 00-05
;;; and 0D; the fixed data addresses of the other banks are in
;;; src/iigs/memmap.inc (with the name of each address in the code).
;;;
;;; Bank 00    direct page at $0900, the direct page of the wall loop at
;;;            $0A00 (WPAGE of src/iigs/r_seg65.s), stack $0B00-$3FFF (the
;;;            game tic from $1B6F down, LOGIC_SP of src/iigs/p_think65.s),
;;;            bank 0 code $4000-$5FFF (the hot game logic: P_TryMove,
;;;            P_CheckSight, P_RunThinkers), loader at $6000, the disk calls
;;;            and the variables of the level loader $8000-$8FFF
;;;            (src/iigs/w_level65.s), the game interrupt and the music
;;;            player at $DC00 (src/iigs/irq65.s); its immutable load image
;;;            at $BA00-$BCFF, five music state bytes at $BD00
;;; Bank 01    the blocks of the rows of texBlocks $1E41 [TEXLO, TEXHI of
;;;            src/iigs/r_list65.s], SHR back buffer $2000-$9CFF [SHRBUF],
;;;            spectre fuzz: darken table $A000 [FUZZ_DARKEN], directions
;;;            $A100 [FUZZ_DIR], the status bar background $A200 [STCACHE]
;;; Bank 02    near data (DBR), initialized data below $7B00, BSS above
;;; Bank 03-05 code; the level loader at $05DC00
;;; Bank 06-0C the zone, tables (src/iigs/memmap.inc)
;;; Bank 0D    far BSS, the SHR colormaps $4600 [iigs_shrcmapA]
;;; Bank 0E-0F the level window when detected as RAM
;;; Bank 10-3F the resident WAD, the tables, the level window
;;;            (src/iigs/memmap.inc)
;;; Bank 40-6F 8 MB: the level store (tools/levelimg.py), more level window,
;;;            the songs [MM_MUSBANK]
;;; Bank E1    super hi-res screen

(define memories
  '((memory DirectPage (address (#x000900 . #x0009ff))
            (section registers ztiny))
    (memory Stack (address (#x000b00 . #x003fff))
            (section stack))
    (memory LowCode (address (#x004000 . #x005fff))
            (section code))
    ;; The disk calls of the level loader (src/iigs/w_level65.s): the slot
    ;; firmware needs bank 0 code; the loader at $6000-$7FFF has finished
    ;; when the game runs. Its variables follow, up to $8FFF.
    (memory DiskCode (address (#x008000 . #x0089ff))
            (section diskcode quitcode))
    ;; The game interrupt and the music player (src/iigs/irq65.s) in
    ;; slots $5D00-$5EFF (measured with music on). The disk
    ;; loads $DC00-$DEFF at $BA00-$BCFF (mkdisk.py). copyMusicIrq copies
    ;; it only after SHADOW.IOLC makes LC RAM writable. State stays at
    ;; $BD00, so a disk pause/resume never resets the song.
    ;; Level setup runs before play; the wall loops use its old slots.
    (memory LevelSetup (address (#x009400 . #x009d3d))
            (section (levelsetup #x009400)))
    (memory Core5Cold (address (#x00b400 . #x00b7ff))
            (section (core5cold #x00b400)))
    ;; BSP log bounds (core14) and the full-view row-kernel source image
    ;; (core16head) share this bank-0 region. Their declared memory ranges
    ;; overlap: core14's emitted bytes must end before core16head at $9100.
    (memory Core14 (address (#x009000 . #x0093ff))
            (section (core14 #x009000)))
    (memory Core16Head (address (#x009100 . #x00927f))
            (section (core16head #x009100)))
    (memory IrqState (address (#x00bd00 . #x00bd04))
            (section (irqstate #x00bd00)))
    (memory IrqCode (address (#x00dd00 . #x00deff))
            (section (irqcode #x00dd00)))
    ;; Its rare commands (pitch changes, the loop of a drum, the end of a
    ;; song) in slots $5C00-$5CFF.
    (memory IrqCold (address (#x00dc00 . #x00dcff))
            (section (irqcold #x00dc00)))
    ;; The start, load and stop of a song (src/iigs/s_sound65.s): run at a
    ;; track change only. The region ends before the saved view-code bytes
    ;; and the core16rows source image.
    (memory MusCode (address (#x009d40 . #x00a4ff))
            (section muscode))
    ;; c19Install saves the displaced small-view code here before copying
    ;; full-view kernels into its slots; c19Restore puts it back on a mode
    ;; change. Accessed during mode installation, not column rendering.
    (memory Core19Save (address (#x00a500 . #x00aaff))
            (section (core19save #x00a500)))
    ;; Source image of the constant-row kernels copied by c19Install.
    (memory Core16Rows (address (#x00af00 . #x00b33f))
            (section (core16rows #x00af00)))
    ;; Bank 0D by cache slot (slot = address & $7FFF, 32 KB cache): the
    ;; SHR colormaps in slots $4600-$09FF, the far BSS of the cold modules
    ;; in the slots of the row code, the other far BSS after them.
    (memory Colormaps (address (#x0d4600 . #x0d89ff))
            (section (cmaps #x0d4600)))
    (memory ColdFar (address (#x0d8a00 . #x0dcfff))
            (section coldfar))
    (memory FarBss (address (#x0dd000 . #x0dffff))
            (section zfar))
    (memory NearData (address (#x020000 . #x027aff))
            (section near cnear switch))
    (memory NearBss (address (#x027b00 . #x02ffff))
            (section znear))
    ;; Code banks 03-05 by cache slot. The view stores (bank 01
    ;; $2000-$88FF) take the slots $2000-$7FFF and $0000-$08FF in each
    ;; frame, so:
    ;;   $0900-$1FFF: the direct page, the row blocks of the drawers
    ;;                (hotdraw), the replay of the lists (hotlist), the
    ;;                entries of the blocks at $1E41 of bank 01 (TEXLO,
    ;;                TEXHI of src/iigs/r_list65.s); other code there is
    ;;                cold (coldcode)
    ;;   $2000-$3DFF: the seg loop (segcode); other code there is game
    ;;                logic (logiccode), which runs once a frame
    ;;   $3E00-$3FFF: the stack; other code there is cold
    ;;   $4000-$5FFF: the code of the BSP phase (bspcode: the BSP, the
    ;;                wall setup, the point and angle math, the sprite
    ;;                projection, the plane check, the 32-bit divisions),
    ;;                which runs between the columns of the segs
    ;;   $6000-$66FF: the multiplies (hotmul, bank 5); cold code in the
    ;;                other banks
    ;;   $0000-$08FF, $6700-$7FFF: the other code, the colormaps and the
    ;;                column lists (src/iigs/lists.inc)
    (memory Code3a (address (#x030000 . #x0308ff))
            (section (startup #x030000) farcode farswitch cfar far))
    (memory Code3b (address (#x030900 . #x031fff))
            (section coldcode))
    (memory SegCode (address (#x032000 . #x033dff))
            (section (segcode #x032000)))
    (memory Code3c (address (#x033e00 . #x033fff))
            (section coldcode))
    (memory BspCode (address (#x034000 . #x035fff))
            (section bspcode (segthird #x035db6)))
    (memory Code3d0 (address (#x036000 . #x0366ff))
            (section coldcode))
    (memory Code3d (address (#x036700 . #x0388ff))
            (section farcode farswitch cfar far))
    (memory Code3e0 (address (#x038900 . #x039283))
            (section coldcode))
    ;; The replay uses these slots after wall production has finished.
    (memory SegWalls (address (#x039284 . #x039bc1))
            (section (segwalls #x039284)))
    (memory Code3e1 (address (#x039bc2 . #x039fff))
            (section coldcode (segmore #x039c00)))
    (memory Code3f (address (#x03a000 . #x03bdff))
            (section logiccode))
    (memory Code3f2 (address (#x03be00 . #x03bfff))
            (section coldcode))
    (memory Code3g (address (#x03c000 . #x03ffff))
            (section farcode farswitch cfar far))
    (memory Code4a (address (#x040000 . #x0408ff))
            (section farcode cfar far))
    (memory Code4b (address (#x040900 . #x041fff))
            (section coldcode))
    (memory Code4c (address (#x042000 . #x043dff))
            (section logiccode))
    (memory Code4c2 (address (#x043e00 . #x043fff))
            (section coldcode))
    (memory Code4d (address (#x044000 . #x045fff))
            (section farcode cfar far))
    (memory Code4d0 (address (#x046000 . #x0466ff))
            (section coldcode))
    (memory Code4d1 (address (#x046700 . #x046bff))
            (section (logicfar #x046700) farcode cfar far))
    ;; The first walk of the guard of P_PathTraverse (gWalk1 of
    ;; src/iigs/p_path65.s): slots $6C00-$6DFF, which the hot code and
    ;; tables of the shot tics do not use.
    (memory GuardCode (address (#x046c00 . #x046dff))
            (section guardcode))
    ;; The ENDOOM page of the exit (tools/endtext.py) first: read once.
    (memory Code4d2 (address (#x046e00 . #x0488ff))
            (section (endtext #x046e00) farcode cfar far))
    (memory Code4e (address (#x048900 . #x049fff))
            (section coldcode))
    (memory Code4f (address (#x04a000 . #x04bdff))
            (section logiccode))
    (memory Code4f2 (address (#x04be00 . #x04bfff))
            (section coldcode))
    ;; The masked wall columns (mwCols of src/iigs/r_frame65.s) in slots $4000-$47FF:
    ;; the BSP code and the game logic use them, the masked pass does not.
    (memory MaskCode (address (#x04c000 . #x04c7ff))
            (section (maskcode #x04c000)))
    (memory Code4g (address (#x04c800 . #x04ffff))
            (section vwcode (uicode #x04d64a) (vw3code #x04e100) (fourui #x04ec90) farcode cfar far))
    (memory Code5a (address (#x050000 . #x0508ff))
            (section farcode data_init_table cfar far))
    (memory Code5b (address (#x050900 . #x050aff))
            (section coldcode))
    (memory HotDraw (address (#x050b00 . #x051a1a))
            (section (hotdraw #x050b00)))
    (memory Code5c (address (#x051a1b . #x051fff))
            (section coldcode))
    (memory Code5d (address (#x052000 . #x0523ff))
            (section logiccode))
    ;; The automap (src/iigs/am_map65.s): the overlay runs it before the
    ;; replay, so it stays out of the replay's slots $0900-$1FFF.
    (memory AmCode (address (#x052400 . #x053dff))
            (section amcode))
    (memory Code5d2 (address (#x053e00 . #x053fff))
            (section coldcode))
    ;; The image of the 2/3 blocks (tools/gendraw.py; copied at a size change).
    (memory ThirdImg (address (#x054000 . #x054fff))
            (section thirdimg ))
    (memory Code5e (address (#x055000 . #x055fff))
            (section (fourimg #x055000) farcode data_init_table cfar far))
    (memory HotMul (address (#x056000 . #x0566ff))
            (section (hotmul #x056000)))
    (memory Code5f (address (#x056700 . #x0588ff))
            (section (fourlist #x056700) farcode data_init_table cfar far))
    (memory Code5g (address (#x058900 . #x05927f))
            (section coldcode))
    ;; Sprite and masked-wall stride for the 1/4 and 1/3 views. Cold: once
    ;; a sprite, not the column loop. Free after the coldcode above.
    (memory QStride (address (#x059280 . #x059a1a))
            (section (qstride #x059280)))
    ;; drawOvl of src/iigs/r_list65.s: slots $1A1B-$1A6F, free between
    ;; hotdraw and hotlist.
    (memory ListOvl (address (#x059a1b . #x059a6f))
            (section (listovl #x059a1b)))
    (memory HotList (address (#x059a70 . #x059e40))
            (section (hotlist #x059a70)))
    ;; drawFuzz of src/iigs/r_list65.s: slots $1F93-$1FFF, free after TEXHI.
    (memory ListFuzz (address (#x059f93 . #x059fff))
            (section (listfuzz #x059f93)))
    ;; The replay of the 2/3 view (thirdAll of src/iigs/r_list65.s): slots
    ;; $2000-$2FFF, below the first store of its window (slot $319A).
    (memory ThirdList (address (#x05a000 . #x05afff))
            (section (thirdlist #x05a000) (onelist #x05a6d0)))
    ;; The replay of the half view (halfAll of src/iigs/r_list65.s) in slots
    ;; $3000-$37FF: the seg loop there does not run during the replay, and
    ;; the window of the half view (rows 42-125) takes slots from $3A68.
    (memory HalfList (address (#x05b000 . #x05b7ff))
            (section (halflist #x05b000)))
    (memory PairCode (address (#x05b800 . #x05bdff))
            (section (paircode #x05b800)))
    (memory Code5h2 (address (#x05be00 . #x05bfff))
            (section coldcode))
    (memory Code5i (address (#x05c000 . #x05dbff))
            (section farcode data_init_table cfar far coldcode detailimg))
    ;; The level loader (src/iigs/w_level65.s): cold, after the rest.
    (memory LvlCode (address (#x05dc00 . #x05ffff))
            (section lvlcode (onecold #x05ec00)))
    (block stack (size #x3500))
    (base-address _DirectPageStart DirectPage 0)
    (base-address _NearBaseAddress NearData 0)
    ))
