#!/bin/sh
# Build each timedemo (DEMOS, default demo3 demo1 demo2) and compare its
# frames with its reference (tools/regress.sh). One line for each demo.
cd "$(dirname "$0")/.." || exit 1
status=0
for d in ${DEMOS:-demo3 demo1 demo2}; do
    if ! make TIMEDEMO=$d PHASES=1 > build/regress-build.log 2>&1; then
        echo "$d: the build failed, see build/regress-build.log"
        status=1
        continue
    fi
    DEMO=$d tools/regress.sh | awk -v d=$d '
        NR > 1 { n++; v += $3; s += $NF; if ($2 == "missing") m++ }
        END { printf "%s: %d frames, %d view bytes and %d status bar bytes differ%s\n",
              d, n, v, s, m ? ", " m " missing" : ""; exit (v || s || m) }' || status=1
done
exit $status
