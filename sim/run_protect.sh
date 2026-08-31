#!/bin/sh
# Super Punch-Out!! protection RTL against MAME, access for access.
# Capture the trace first with scratchpad/prot.lua (see docs/verification.md):
#   mame spnchout -rompath roms -video none -sound none -nothrottle \
#        -autoboot_script prot.lua
set -e
cd "$(dirname "$0")/.."
TRACE=${TRACE:-build/prot.bin}
[ -f "$TRACE" ] || { echo "no $TRACE - capture it with prot.lua in MAME"; exit 2; }
verilator --cc --exe --build -j 0 -O2 -Irtl -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDPARAM \
    --top-module po_protect rtl/po_protect.sv sim/tb_protect.cpp \
    -Mdir build/sim_protect -o tb_protect >/dev/null
build/sim_protect/tb_protect "$TRACE"
