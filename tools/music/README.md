# Optional song converter

`make` does not use this directory. The disks are built from the song
units already in `data/music`: one `.mus` file per song, containing the
stream, the pitch tables, and the DOC samples. No SoundFont is required.

To make your own units from a General MIDI SoundFont:

```
python3 tools/music/mussc.py FONT.sf2 build/wad/music.bin \
  D_E1M1,D_E1M2,D_E1M3,D_E1M4,D_E1M5,D_E1M6,D_E1M7,D_E1M8,D_E1M9,D_INTER,D_INTRO,D_VICTOR \
  --units data/music
```

Then run `make` again. `tools/music/MUSIC_FORMAT.md` describes a unit.
`tools/music/gmref.py` plays a song from a SoundFont so you can listen; it
does not write the disk units.
