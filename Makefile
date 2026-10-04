# Builds the game and the disk images (see BUILD.md).

CALYPSI  := tools/calypsi/bin
AS       := $(CALYPSI)/as65816
LD       := $(CALYPSI)/ln65816
PYTHON   := python3

BUILD    := build
OBJ      := $(BUILD)/obj

# The game is all 65816 assembly: no C compiler and no C library.
# make TIMEDEMO=1 starts -timedemo demo3 instead of the title screen;
# make TIMEDEMO=demo1 (or demo2) plays that demo.
# make PHASES=1 marks the frame phases for tools/probe.lua (PROBE_PHASE).
# make PISCHECK=1: R_PointInSubsector also walks from the root and stops
# with I_Error when the grid start gives another subsector.
# make TICSTEP=N: the player runs each tic of 1/35 s, the monsters and
# the rest of the world once each N tics, with N tics of work
# (src/iigs/tics.inc); 1 (the default) is Doom, and the demos play as
# recorded only then.
# make MAXTICS=M: a frame runs at most M tics of the game (1 to 15; the
# default is 4, 8 with TICSTEP > 1); a slower frame makes the game slower.
TICSTEP  ?= 1
ASFLAGS  := --code-model=large --data-model=medium -I tools/calypsi/src/lib/lowlevel \
            $(if $(PHASES),-D IIGS_PHASES) $(if $(PISCHECK),-D PISCHECK) -D TICSTEP=$(TICSTEP) \
            $(if $(MAXTICS),-D MAXTICS=$(MAXTICS))
IIGS_S   := src/iigs/crt0.s src/iigs/iigs_asm.s src/iigs/irq65.s src/iigs/m_fixed65.s src/iigs/m_recip65.s \
            src/iigs/patch65.s src/iigs/r_iigs65.s src/iigs/r_sprite65.s src/iigs/r_seg65.s \
            src/iigs/p_sight65.s src/iigs/p_enemy65.s src/iigs/p_mobj65.s src/iigs/p_path65.s src/iigs/p_attack65.s src/iigs/p_pspr65.s src/iigs/p_user65.s \
            src/iigs/m_random65.s src/iigs/p_think65.s src/iigs/p_lights65.s src/iigs/p_spec65.s src/iigs/p_floor65.s \
            src/iigs/p_doors65.s src/iigs/p_plats65.s src/iigs/p_switch65.s src/iigs/p_telept65.s src/iigs/p_use65.s src/iigs/p_spawn65.s src/iigs/p_inter65.s src/iigs/r_frame65.s src/iigs/st_stuff65.s src/iigs/hu_stuff65.s src/iigs/s_sound65.s \
            src/iigs/w_wad65.s src/iigs/z_zone65.s src/iigs/r_data65.s src/iigs/p_setup65.s src/iigs/d_main65.s src/iigs/g_game65.s src/iigs/m_cheat65.s src/iigs/f_finale65.s src/iigs/wi_stuff65.s src/iigs/am_map65.s src/iigs/m_menu65.s src/iigs/i_iigs65.s src/iigs/i_viigs65.s \
            src/iigs/tables65.s src/iigs/info65.s src/iigs/r_state65.s \
            src/iigs/p_tick65.s src/iigs/p_map65.s src/iigs/string65.s src/iigs/r_wall65.s src/iigs/r_bsp65.s src/iigs/r_thing65.s src/iigs/p_trace65.s src/iigs/r_list65.s \
            src/iigs/i_doc65.s src/iigs/i_snd65.s src/iigs/m_config65.s \
            src/iigs/cal_integer.s src/iigs/w_level65.s src/iigs/m_speed65.s src/iigs/i_stealth65.s

OBJS     := $(patsubst src/iigs/%.s,$(OBJ)/%.o,$(IIGS_S)) $(OBJ)/drawcol.o $(OBJ)/endtext.o

WAD      := data/DOOM1.WAD
WADOUT   := $(BUILD)/wad
# the timedemo builds keep DEMO1 and DEMO2 for the tests. wadtool writes the
# resident WAD (FILE, FILE.SEG: its lumps in the free areas of the table
# banks, FILE.PIC: the title picture) and the level store (tools/levelimg.py).
WADFILE  := $(WADOUT)/$(if $(TIMEDEMO),DOOMGSD.WAD,DOOMGS.WAD)
STOREFILE := $(WADFILE:.WAD=.STO)
LEVELTOOLS := tools/levelset.py tools/levelimg.py tools/levelhot.txt tools/b1.py src/iigs/info65.s \
            src/iigs/p_switch65.s src/iigs/memmap.inc
MAME     := mame apple2gs -rompath roms -ramsize 8M -skip_gameinfo \
            -nvram_directory nvram -cfg_directory cfg -snapshot_directory snap

.PHONY: all disks run clean

all: disks

disks: $(BUILD)/disk1.po

# Rebuild everything when the build switches change
DEFSTAMP := $(OBJ)/defs-$(if $(TIMEDEMO),timedemo,game)$(if $(PHASES),-phases)$(if $(PISCHECK),-pischeck)-tic$(TICSTEP)$(if $(MAXTICS),-max$(MAXTICS)).stamp
$(DEFSTAMP): | $(OBJ)
	rm -f $(OBJ)/defs-*.stamp
	touch $@

# The demo of a timedemo build is only in i_iigs65.s: TIMEDEMO_N, the
# number of the demo (TIMEDEMO=1 is demo3)
DEMOSTAMP := $(OBJ)/demo-$(or $(TIMEDEMO),none).stamp
# GNU Make 3.81 compares whole seconds. A rapid demo switch can otherwise
# leave the previous variant's object, ELF or disks when timestamps tie.
# Select the force prerequisite before the missing stamp is created.
ifeq ($(wildcard $(DEMOSTAMP)),)
.PHONY: force-demo-variant
$(OBJ)/i_iigs65.o $(BUILD)/doom.elf $(BUILD)/disk1.po: force-demo-variant
endif
$(DEMOSTAMP): | $(OBJ)
	rm -f $(OBJ)/demo-*.stamp
	touch $@
$(OBJ)/i_iigs65.o: $(DEMOSTAMP)
$(OBJ)/i_iigs65.o: ASFLAGS += $(if $(TIMEDEMO),-D TIMEDEMO_N=$(if $(filter 1,$(TIMEDEMO)),3,$(patsubst demo%,%,$(TIMEDEMO))))
# A timedemo build starts with music volume 0: the engine timings of the
# demos stay comparable (the game starts with 12).
$(OBJ)/s_sound65.o: ASFLAGS += $(if $(TIMEDEMO),-D MUSIC_OFF)
MUSIC_MENU ?= 1
# MUSIC_MENU=1: the MUSIC VOLUME row of DISPLAY & SOUND (src/iigs/m_menu65.s)
$(OBJ)/m_menu65.o: ASFLAGS += $(if $(MUSIC_MENU),-D MUSIC_MENU=$(MUSIC_MENU))


$(OBJ)/%.o: src/iigs/%.s $(wildcard src/iigs/*.inc) $(DEFSTAMP) | $(OBJ)
	$(AS) $(ASFLAGS) -o $@ $<

$(OBJ):
	mkdir -p $@

# Unrolled column drawers: view at byte 0 of each row, row 0, center row 84
$(BUILD)/gen/drawcol.s: tools/gendraw.py Makefile $(DEFSTAMP)
	mkdir -p $(BUILD)/gen
	$(PYTHON) tools/gendraw.py $@ 0 0 84

$(OBJ)/drawcol.o: $(BUILD)/gen/drawcol.s src/iigs/lists.inc src/iigs/replay.inc | $(OBJ)
	$(AS) $(ASFLAGS) -I src/iigs -o $@ $<

# The ENDOOM page of the exit, as 80-column text
$(BUILD)/gen/endtext.s: $(WAD) tools/endtext.py
	mkdir -p $(BUILD)/gen
	$(PYTHON) tools/endtext.py $(WAD) $@

$(OBJ)/endtext.o: $(BUILD)/gen/endtext.s | $(OBJ)
	$(AS) $(ASFLAGS) -o $@ $<

# The addresses of the data (src/iigs/memmap.inc): the resident WAD MM_WAD,
# the sound bank MM_SNDBANK, LOGTAB, SINE, the title MM_TITLEPIC, the store.
# --hosted: the loader puts the initialized data in place (no copies).
$(BUILD)/doom.elf: $(OBJS) src/iigs/iigs.scm
	$(LD) -o $@ src/iigs/iigs.scm $(OBJS) --hosted \
	      --list-file $(BUILD)/doom.lst --cross-reference

$(BUILD)/boot/boot.raw: src/iigs/boot.s src/iigs/boot.scm
	mkdir -p $(BUILD)/boot
	$(AS) -o $(BUILD)/boot/boot.o src/iigs/boot.s
	$(LD) -o $(BUILD)/boot/boot.elf src/iigs/boot.scm $(BUILD)/boot/boot.o --output-format raw

# The glyphs and the disk icon of the load strip
$(BUILD)/gen/loadfont.s: $(WAD) tools/loadfont.py tools/wadtool.py tools/gscolor.py
	mkdir -p $(BUILD)/gen
	$(PYTHON) tools/loadfont.py $(WAD) $@

$(BUILD)/boot/loader.raw: src/iigs/loader.s src/iigs/loader.scm $(BUILD)/gen/loadfont.s
	mkdir -p $(BUILD)/boot
	$(AS) -I $(BUILD)/gen -o $(BUILD)/boot/loader.o src/iigs/loader.s
	$(LD) -o $(BUILD)/boot/loader.elf src/iigs/loader.scm $(BUILD)/boot/loader.o --output-format raw

$(BUILD)/tables/recip.bin $(BUILD)/tables/phase.bin $(BUILD)/tables/log.bin: tools/gentables.py
	$(PYTHON) tools/gentables.py $(BUILD)/tables

$(BUILD)/tables/sine.bin: tools/gensine.py
	mkdir -p $(BUILD)/tables
	$(PYTHON) tools/gensine.py $@

# The colors of the 3D view (GSVIEW0-9, GSFLAT0-9): about 60 s.
GSVIEW   := $(WADOUT)/gsview
$(GSVIEW)/stamp: $(WAD) tools/gsview.py tools/doomview.py src/iigs/info65.s src/iigs/offsets.inc
	$(PYTHON) tools/gsview.py $(WAD) src/iigs $(GSVIEW)
	touch $@

$(WADOUT)/DOOMGS.WAD: data/demo2.hex $(WAD) tools/wadtool.py tools/gscolor.py tools/sgrid.py $(GSVIEW)/stamp $(LEVELTOOLS) $(WADOUT)/music.bin
	$(PYTHON) tools/wadtool.py $(WAD) $(WADOUT) --demo2 data/demo2.hex --flat-span --layout 320 --gsview $(GSVIEW) \
	    --store $(WADOUT)/DOOMGS.STO --src src/iigs --music-bank $(WADOUT)/music.bin

$(WADOUT)/DOOMGSD.WAD: data/demo2.hex $(WAD) tools/wadtool.py tools/gscolor.py tools/sgrid.py $(GSVIEW)/stamp $(LEVELTOOLS) $(WADOUT)/music.bin
	$(PYTHON) tools/wadtool.py $(WAD) $(WADOUT) --demo2 data/demo2.hex --flat-span --layout 320 --gsview $(GSVIEW) --keep-demos --name DOOMGSD.WAD \
	    --store $(WADOUT)/DOOMGSD.STO --src src/iigs --music-bank $(WADOUT)/music.bin

$(WADOUT)/sounds.bin: $(WAD) tools/sndbank.py src/iigs/offsets.inc $(WADOUT)/music.bin
	mkdir -p $(WADOUT)
	$(PYTHON) tools/sndbank.py $(WAD) src/iigs/offsets.inc $@ $(WADOUT)/music.bin

# The tables of docVolume (the level of each sound, the limit of the pan),
# from the same levels as the bank.
$(BUILD)/gen/sfxvol.inc: $(WAD) tools/sndbank.py src/iigs/offsets.inc
	mkdir -p $(BUILD)/gen
	$(PYTHON) tools/sndbank.py $(WAD) src/iigs/offsets.inc - --law $@

$(OBJ)/s_sound65.o: $(BUILD)/gen/sfxvol.inc
$(OBJ)/s_sound65.o: ASFLAGS += -I $(BUILD)/gen

# All episode songs: the level store owns their disk bytes. On 8 MB the
# loader assembles MUSBANK from those units; only INTRO is also a boot segment.
# data/music holds the converted units (stream, pitch tables, DOC samples).
# make packs those bytes. It does not need a SoundFont. tools/music/ is the
# optional converter for someone building their own units.
# ProDOS directory dates. 1790467200 is 2026-09-27 00:00:00 UTC, so a clean
# tree rebuilds the release images byte for byte. Override for a private stamp.
SOURCE_DATE_EPOCH ?= 1790467200
export SOURCE_DATE_EPOCH
MUSIC_UNITS := data/music/D_E1M1.mus data/music/D_E1M2.mus data/music/D_E1M3.mus \
               data/music/D_E1M4.mus data/music/D_E1M5.mus data/music/D_E1M6.mus \
               data/music/D_E1M7.mus data/music/D_E1M8.mus data/music/D_E1M9.mus \
               data/music/D_INTER.mus data/music/D_INTRO.mus data/music/D_VICTOR.mus
$(WADOUT)/music.bin: $(MUSIC_UNITS) tools/packunits.py tools/musbank.py
	mkdir -p $(WADOUT)
	$(PYTHON) tools/packunits.py data/music $@

$(WADOUT)/mus/stamp: $(WADOUT)/music.bin tools/songunits.py
	$(PYTHON) tools/songunits.py $< $(WADOUT)/mus
	touch $@

$(BUILD)/disk1.po: $(BUILD)/doom.elf $(BUILD)/boot/boot.raw $(BUILD)/boot/loader.raw \
                   $(WADFILE) $(WADOUT)/sounds.bin $(WADOUT)/music.bin $(WADOUT)/mus/stamp $(BUILD)/tables/log.bin \
                   $(BUILD)/tables/sine.bin tools/mkdisk.py
	$(PYTHON) tools/mkdisk.py --boot $(BUILD)/boot/boot.raw --loader $(BUILD)/boot/loader.raw \
	    --elf $(BUILD)/doom.elf --entry 0x030000 \
	    --data $(WADFILE)@0x100000 --data-list $(WADFILE).SEG \
	    --data $(WADOUT)/sounds.bin@0x2c0000 \
	    --data $(BUILD)/tables/log.bin@0x1f0000 \
	    --data $(BUILD)/tables/sine.bin@0x200000 \
	    --picture-file $(WADFILE).PIC@0x2a0000 --store $(STOREFILE)@0x400000 \
	    --store-regions $(STOREFILE).REG --compress --b1cache $(WADOUT)/b1cache \
	    --hd-store $(STOREFILE).RAW@0x400000 \
	    --boot-song $(WADOUT)/mus/D_INTRO.mus@0x2a8000 \
	    --hd $(BUILD)/doom-hd.po --scsi $(BUILD)/doom-scsi.hda \
	    --out $(BUILD)/disk

run: disks
	$(MAME) -window -nomaximize -flop3 $(BUILD)/disk1.po

clean:
	rm -rf $(BUILD)/obj $(BUILD)/doom.elf $(BUILD)/doom.lst $(BUILD)/disk*.po $(BUILD)/boot $(WADOUT)
