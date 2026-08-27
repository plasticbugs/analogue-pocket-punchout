#!/bin/sh
# VLM5030 RTL against the reference model, sample for sample, on the phrases
# the game uses (table bytes). Regenerate the model with tools/vlm5030.py.
set -e
cd "$(dirname "$0")/.."
ROM=${ROM:-build/punchout.rom}
MODEL=${MODEL:-build/vlm}
PHRASES=${PHRASES:-"00 04 0e 10 14 1c 20 28 34 40 48 4a 4c 4e 50"}
verilator --cc --exe --build -j 0 -O2 -Irtl -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDPARAM \
    --top-module po_vlm5030 rtl/po_ram.sv rtl/po_vlm5030.sv sim/tb_vlm.cpp -Mdir build/sim_vlm5030 -o tb_vlm >/dev/null
# PARAM selects the speed/pitch parameter byte (default 8, the game's usual);
# the model directory must have been generated with the same one.
build/sim_vlm5030/tb_vlm "$ROM" "$MODEL" $PHRASES
