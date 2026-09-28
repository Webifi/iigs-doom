#!/bin/sh
# Save the back buffer at fixed tics of the timedemo (make TIMEDEMO=1
# PHASES=1 first, or TIMEDEMO=demo1 / demo2 with DEMO=demo1 / demo2 here)
# and compare with build/ref-step (demo3) or build/ref-DEMO-step
# (tools/ticcmp.py): the references of the stepping drawer, the only
# drawer since the compiled scalers went (2026-09-25).
# REF=1 saves a new reference instead. ZIP as for tools/probe.sh, default 7.
cd "$(dirname "$0")/.." || exit 1
DEMO=${DEMO:-demo3}
REFDIR=build/ref-step
[ "$DEMO" = demo3 ] || REFDIR=build/ref-$DEMO-step
case $DEMO in
demo1) DEFTICS=$(seq -s, 250 250 5000) ;;
demo2) DEFTICS=$(seq -s, 250 250 3750) ;;
*)     DEFTICS=20,60,100,140,180,220,260,300,400,600,800,1000,1200,1400,1600,1800,2000,2100 ;;
esac
TICS=${TICS:-$DEFTICS}
G=$(python3 tools/symaddr.py build/doom.elf _g_gametic)
rm -f build/tic_*.bin
ZIP=${ZIP:-7} PROBE_SECONDS=${PROBE_SECONDS:-6000} PROBE_GAMETIC=$G PROBE_TICSHR=$TICS PROBE_TICEXIT=1 \
    tools/probe.sh 2>&1 | grep -c "back buffer saved"
if [ -n "$REF" ]; then
    mkdir -p "$REFDIR" && cp build/tic_*.bin "$REFDIR"/
else
    python3 tools/ticcmp.py "$REFDIR"
fi
