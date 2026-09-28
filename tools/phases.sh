#!/bin/sh
# Time each frame phase of the timedemo from game tic 100 to 300 (make
# TIMEDEMO=1 PHASES=1 first). ZIP as for tools/probe.sh.
cd "$(dirname "$0")/.." || exit 1
addr() { python3 tools/symaddr.py build/doom.elf "$1"; }
PROBE_SECONDS=${PROBE_SECONDS:-900} PROBE_GAMETIC=$(addr _g_gametic) PROBE_PHASETICS=1 \
    PROBE_PHASE=$(addr iigs_phase),${FROM:-100},${TO:-300} tools/probe.sh | grep "phase\|count\|trace"
