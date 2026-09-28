# Building

## You need

- macOS or Linux with GNU make and Python 3.9 or newer (standard library only).
- The Calypsi 65816 assembler and linker (version 5.18). By default the build
  looks in `tools/calypsi/bin`; otherwise pass them:
  `make AS=/path/to/as65816 LD=/path/to/ln65816`.
- `data/DOOM1.WAD` (the shareware WAD) and `data/music/*.mus` (the song data),
  both included.

## Build

```sh
make
```

This builds the game and writes the disk images to `build/`:

- `disk1.po` to `disk4.po`: the 800 KB 3.5-inch floppy set
- `doom-hd.po`: one bootable ProDOS hard disk volume
- `doom-scsi.hda`: the same volume with an Apple partition map, for SCSI

The music comes from `data/music`; the build does not need a SoundFont. A clean
build matches the release images byte for byte (set `SOURCE_DATE_EPOCH` only to
stamp a private build). `make clean` removes the build output.

## Options

- `make TIMEDEMO=1` starts the demo3 timedemo instead of the title screen
  (`TIMEDEMO=demo1` or `demo2` plays those demos).
- `make run` boots `build/disk1.po` with `mame` from your PATH and the Apple IIgs
  ROMs in `roms/` (the ROMs are not included).

## Your own music

To replace the songs, `tools/music` converts them from a General MIDI SoundFont.
See `tools/music/README.md`.

## Other WADs

The build works only with the shareware `DOOM1.WAD`. Another IWAD or a PWAD
will not work without real rework:

- The level tools read the maps by the names E1M1 to E1M9 and expect episode
  1's sky and the shareware textures, sprites and monsters. Episodes 2 to 4
  and Doom II maps are not handled.
- Much of the speed comes from tuning to these nine maps: the cache placement
  profile (`tools/levelhot.txt`), the memory window of 4 MB machines, and the
  grouping of maps and songs on the floppies (which are full).
- The 12 songs are converted one by one for the stock songs, and the demo2
  recording and the intermission map spots belong to these maps.

A PWAD that only replaces E1M1 to E1M9 might go through the build, but it is
not tested, may not fit in memory or on the disks, and would run slower.
