#!/bin/sh
# Run MAME headless with tools/probe.lua. Always windowed, so macOS never
# switches to a fullscreen space, and hidden: the SDL dummy video driver
# and a background app, so no window and no Dock icon come up.
# Environment: PROBE_SECONDS, PROBE_DUMP, PROBE_DUMPTIMES, PROBE_SNAPS.
# Usage: tools/probe.sh [disk prefix, default build/disk]
# ZIP=1|3|5|7 selects a 7, 8, 12 or 16 MHz ZipGS (cfg/zipN), default stock.
# MACHINE=apple2gsr1 (ROM 01) or apple2gsr0 (ROM 00), default apple2gs (ROM 03).
# PROBE_WAV=FILE records the sound output to FILE.
# The game writes its settings file to the last disk; the run uses copies
# of the disks in build/probe-disks, so each run starts from the same
# disks. PROBE_KEEPDISKS=1 uses the disks themselves.
cd "$(dirname "$0")/.." || exit 1
cfgdir=cfg${ZIP:+/zip$ZIP}
prefix=${1:-build/disk}
if [ -z "$PROBE_KEEPDISKS" ]; then
    mkdir -p build/probe-disks
    rm -f build/probe-disks/disk[0-9].po
    for f in "$prefix"[0-9].po; do
        cp "$f" "build/probe-disks/disk${f##*disk}"
    done
    prefix=build/probe-disks/disk
fi
disks=$(ls "$prefix"[0-9].po | sort | paste -sd, -)
SDL_VIDEO_DRIVER=dummy SDL_VIDEODRIVER=dummy SDL_MAC_BACKGROUND_APP=1 \
    PROBE_DISKS=$disks exec mame ${MACHINE:-apple2gs} -rompath roms -ramsize 8M \
    -flop3 "${prefix}1.po" -window -nomaximize -video none -sound none \
    ${PROBE_WAV:+-wavwrite "$PROBE_WAV"} \
    -nothrottle -skip_gameinfo -autoboot_script tools/probe.lua \
    -snapshot_directory snap -nvram_directory nvram -cfg_directory "$cfgdir" 2>&1 |
    grep -v "WRONG\|EXPECTED\|FOUND\|might not\|doesn't"
