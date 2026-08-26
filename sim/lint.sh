#!/bin/sh
# Lint every RTL file the core synthesises, plus the bench wrappers. Run before
# every push: it catches syntax and inference errors in seconds, where a broken
# push costs a whole CI cycle.
set -e
cd "$(dirname "$0")/.."
FLAGS="-Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-VARHIDDEN -Wno-PROCASSINIT
       -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNSIGNED
       -Wno-PINCONNECTEMPTY -Wno-IMPLICITSTATIC"

echo "--- video core ---"
verilator --lint-only $FLAGS --top-module punchout_video \
    rtl/po_ram.sv rtl/punchout_video.sv

echo "--- video bench hierarchy (adds the SDRAM controller and loader) ---"
verilator --lint-only $FLAGS --top-module tb_video_top \
    rtl/po_ram.sv rtl/po_romload.sv rtl/sdram16.sv rtl/punchout_video.sv \
    sim/sdram_model.sv sim/tb_video_top.sv

echo "lint clean"
