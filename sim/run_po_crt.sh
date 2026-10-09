#!/bin/sh
# The Analogizer's two Punch-Out!!-specific pieces, each on its own:
#   po_crt        the fight screen at the bottom monitor's own timing,
#                 checked dot by dot against the frame it came from
#   po_topscreen  "Pocket shows top screen": DE narrowed to the info screen
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
for t in po_crt po_topscreen; do
    verilator --binary --timing -j "${JOBS:-8}" -O2 -Wno-fatal -Wno-lint -Wno-style \
        --top-module tb_$t -Mdir obj_$t \
        ../target/pocket/$t.sv tb_$t.sv > obj_$t.log 2>&1 \
        || { tail -40 obj_$t.log; exit 1; }
    ./obj_$t/Vtb_$t | grep -v '^- ' | tee obj_$t/run.log
    grep -q "^PASS" obj_$t/run.log
done
