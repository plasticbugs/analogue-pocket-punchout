#!/bin/sh
# Super Punch-Out!! protection RTL against MAME, access for access.
# Capture the trace first with scratchpad/prot.lua (see docs/verification.md):
#   SDL_VIDEODRIVER=dummy mame spnchout -rompath roms -video none -videodriver dummy \
#        -window -nomaximize -sound none -nothrottle -skip_gameinfo -seconds_to_run 600 \
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
