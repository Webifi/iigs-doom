# DOC song units

The release build does not run this converter. `make` packs the units already in `data/music`. To make your own, run `tools/music/mussc.py FONT.sf2 OUT.bin SONG[,SONG...] --units DIR` with a General MIDI SoundFont. That command also writes one loader unit per song. The separate floppy music-lump integration belongs to the level loader.

A bank begins with a little-endian u16 song count, then (u32 offset,u32 size) pairs in `musbank.SONGS` order. An absent song has size zero. A unit contains:

- u8 descriptor count D; u8 pitch count P (0 means 256); u16 stream bytes SL; u8 lowest DOC page LOW; u8 feature flags.
- SL stream bytes; P pitch low bytes; P pitch high bytes.
- Five arrays of D bytes: attack page, attack size/resolution, run mode, loop page, loop size/resolution.
- DOC RAM bytes for pages LOW through 254, including waveform dictionaries that do not need descriptors.

Head length is `6 + SL + 2*P + 5*D`. This base places the head at MUSBUF+$0500 and plans at +$AE00: **43264 bytes maximum**, not 43776. D <=64, pitches <=256. Map songs have the full 180-page budget; INTRO/INTER/VICTOR have 200. Actual use may be less. The alarm's tempo remains 140 Hz.

Flags bit 0 identifies a unit using moving waveform pages; bit 1 identifies raw channel-control commands. The current loader copies it as part of the header and otherwise ignores it. Such a stream needs the accompanying irq65.s extension; do not use an older player.

## Stream extension

Existing commands remain unchanged. `BE voice page` writes only the waveform-pointer register of music voice 0..13 (DOC oscillator 16+voice). It preserves the accumulator, frequency, size, level, run mode, and descriptor. Tables in a moving family are phase-compatible, 256 bytes at the same rate. The builder marks the voice switched, so a subsequent note restores its ordinary attack descriptor. There is no additional timer or interrupt.

`BF voice control` writes only the control register (no permanent change to the channel tables). The builder uses it on a muted, already-running oscillator to route a fade partner to the primary voice's channel. A later ordinary note restores that voice's normal mode/channel. The new player and comparison renderer both implement this opcode.

INTRO samples the first 150/140 seconds of both Halo notes. Existing voice-reserve cuts then free voices 1 and 3. At a brief faded handover both members of each pair start at the same phase; subsequent waveform-page writes affect only the muted member. Eleven-tic crossfades use paired level writes every two tics. The code does not reserve two voices during the opening chord. Primary note onsets and held durations are preserved; some release tails and optional stereo duplicates are shorter. This is an approximation, including fixed carrier phases, quantized volume ramps and the handover. No exact hardware or zero-cost claim.

VICTOR uses sampled long loops for intrinsic motion with no repeated Halo frame commands. Its filter envelope is approximated by the attack and a held-loop state. Other slow filter LFOs use compact phase-compatible tables with a discrete set of states sized to fit the song budget. Page changes can therefore introduce amplitude or spectral steps; phase compatibility does not make the filter continuous. A dynamic filter remains active when it reaches the nominal open cutoff, preserving Q-dependent gain rather than jumping to unity.

Pitch envelopes returning within 100 ms are baked into attacks; longer envelopes, MIDI bends, CC1, and SF2 pitch LFOs become bounded frequency updates. Filter LFOs use baked attacks and moving loop families. Volume LFOs use ordinary level updates. A layered voice uses a power-weighted pitch; it cannot reproduce independent oscillators in all layers. E1M3 uses a two-level RMS approximation to its small ongoing vibrato to fit the stream head. The separately measured p118 falling sweep retains precedence over that patch's SF2 vibrato.

`tools/music/docrender.c` implements the player commands for comparison renders. Compile with `cc -O2 tools/music/docrender.c -lm -o docrender`; invoke `docrender BANK SONG_INDEX OUT.wav SECONDS`. Its wake/write counts model the stream; game frame timings must still be measured with music enabled.

## Reference level calibration

`cal_db` in `mussc.py` applies global and song-specific gain corrections;
INTRO p51 has a -3 dB song correction. `channel_attenuation` normally uses
`40*log10(127/cv)` dB attenuation. For INTRO p51/p94/p102 at controller
values `cv > 100`, it adds `14.6*log10(cv/100)` dB attenuation to reduce
the upper-range swell. The correction is continuous at 100 and leaves
the fade below it unchanged. These are song-specific calibration choices,
not a general MIDI controller-7 transfer law.

A short filter-envelope transient that is too large for held states is sampled
into the attack. Multiple carrier periods per compact loop can lower its attack
sample rate while retaining its audible harmonics; the same oscillator frequency
serves attack and loop. This avoids E1M6's former coarse p63 step without a second
oscillator. Budgets include all attack samples and transition tables.

Reverse Cymbal (p119) uses a native 2048-byte noise loop, including a repeated seam byte. Its SF2 volume attack is scheduled at build time in fine volume steps; it has no attack-table switch, spectral peak synthesis, or runtime DSP. The carrier plays at about 26.27 kHz for E1M5 key63. Other cymbals retain their existing native noise paths. `musnoise.py` is a music-bank build dependency.
