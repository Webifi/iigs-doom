# Can it play Doom?

It's a question that's nagged at me since before I said goodbye to my trusty IIgs over 30 years ago. It was decked out with a whopping 8 MB RAM and 12.5 MHz ZipGS. With the GS turning 40, I figured it was time to finally try answering it.

![Doom on the Apple IIgs: a fight in Hangar at full view](docs/images/gameplay.png)

Inspired by [Doom8088](https://github.com/FrenkelS/Doom8088), it was first converted to 65816 assembly. That allowed full control of every knob and dial. Most of the work has been finding out where the accelerator spends its time waiting and where the assembly, initially just compiled from C, could be tightened up.

With no real IIgs available, development started on MAME's IIgs emulator. Iterating and testing code changes on the real thing would be too slow anyway. Unfortunately, MAME's ZipGS emulation skips some cache and bus timing. That required a [MAME fork](https://github.com/Webifi/mame/tree/apple2gs-accelerators) with, hopefully, more accurate ZipGS and TransWarp GS emulation.

There are compromises: a 160 x 168 view with double-wide pixels, reduced color palettes with dithering, flat-colored floors and ceilings, and less precise math where it seemed to have little effect. Walls keep their textures and lighting, but they're pretty ugly.

A lot of time was spent trying to work around the assumed single-entry write buffer of the ZipGS. The idea was to keep cached reads and register operations going after an 8-bit store to the slower motherboard bus and then avoiding as many stores as possible.  (The accelerators may just stall immediately on store, so the optimizations could be all for naught.)

In the end, all I could get was a chunky ~4 FPS on my emulated IIgs with 8 MB and a 12 MHz ZipGS.  Without an accelerator, it would be more like seconds per frame.  That is, if it even runs at all on real metal.

I still haven't tried it on an actual IIgs with a real ZipGS accelerator.

So, *can it play Doom?*  I guess that depends on how you define "play".  Maybe?  Give it a try and let me know.

# Wanna try?

Minimum requirements: A working IIgs, 4 MB RAM (8 MB recommended) and a 12 MHz ZipGS or TransWarp GS accelerator with at least 32 KB cache. You'll also need a 3.5" drive and 4 blank 800 KB floppies, or some other way to load the image(s).

Get the [disk images](https://github.com/Webifi/iigs-doom/releases/latest).
