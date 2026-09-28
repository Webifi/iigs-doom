#!/bin/sh
# Show the game in a normal MAME window for the user. It runs the model MAME
# release (gsdoom, with the ZipGS cache and bus model), never the Homebrew
# mame: that one has no cache model and runs faster than a real accelerator.
# Disks are swapped automatically, loading runs at full emulator speed, the
# game at real speed.
# Usage: tools/watch.sh [disk prefix, default build/disk]
# ZIP=1|3|5|7 selects a 7, 8, 12 or 16 MHz ZipGS, default 5 (12 MHz).
# CACHE=4|2|6 selects the ZipGS cache: 32 KB (the target, default), 16 KB,
# 64 KB.
# MACHINE=apple2gsr1 (ROM 01) or apple2gsr0 (ROM 00), default apple2gs (ROM 03).
# MOUSE=1 gives the Mac mouse to the IIgs (MAME -mouse): it turns and fires.
# PROBE_TAG=text shows that label of the build in the top right corner.
# MAME then keeps the pointer in its window; Command-Tab gets it back.
cd "$(dirname "$0")/.." || exit 1
machine=${MACHINE:-apple2gs}
cfgdir=build/watch-cfg
mkdir -p "$cfgdir"
{
echo '<?xml version="1.0"?>'
echo "<mameconfig version=\"10\"><system name=\"$machine\"><input>"
echo '<keyboard tag=":macadb" enabled="1" />'
echo "<port tag=\":a2_config\" type=\"CONFIG\" mask=\"7\" defvalue=\"0\" value=\"${ZIP:-5}\" />"
echo "<port tag=\":bus_timing\" type=\"CONFIG\" mask=\"6\" defvalue=\"6\" value=\"${CACHE:-4}\" />"
echo '</input></system></mameconfig>'
} > "$cfgdir/$machine.cfg"
prefix=${1:-build/disk}
disks=$(ls "$prefix"[0-9].po | sort | paste -sd, -)
PROBE_DISKS=$disks PROBE_FASTLOAD=1 exec /Users/john/iigs-doom-research/mame-zipgs/bin/mame "$machine" -rompath roms -ramsize 8M \
    -flop3 "${prefix}1.po" -window -nomaximize -skip_gameinfo -cheat \
    ${MOUSE:+-mouse} \
    -autoboot_script tools/probe.lua \
    -snapshot_directory snap -nvram_directory nvram -cfg_directory "$cfgdir"
