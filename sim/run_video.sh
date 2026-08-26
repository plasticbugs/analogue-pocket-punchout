#!/bin/sh
# Frozen-state video bench: build once, load the ROM once, render every
# captured state in the RTL and diff each against the reference renderer.
#
#   ./sim/run_video.sh                       artifacts/ + punchout.rom
#   OUT=art2 ROM=build/punchout.rom ./sim/run_video.sh
set -e
cd "$(dirname "$0")/.."
OUT=${OUT:-artifacts}
ROM=${ROM:-punchout.rom}
BUILD=build/sim_video

[ -f "$ROM" ] || { echo "no $ROM - build it with tools/mra_build.py"; exit 2; }
states=$(ls "$OUT"/state_*.txt 2>/dev/null) || true
[ -n "$states" ] || { echo "no states in $OUT - run tools/capture_states.sh"; exit 2; }

mkdir -p "$BUILD" build
verilator --cc --exe --build -j 0 -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-VARHIDDEN -Wno-PROCASSINIT \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-PINCONNECTEMPTY -Wno-IMPLICITSTATIC -Wno-PINMISSING \
    --top-module tb_video_top --Mdir "$BUILD" -o tb_video \
    rtl/po_ram.sv rtl/po_romload.sv rtl/sdram16.sv rtl/punchout_video.sv \
    sim/sdram_model.sv sim/tb_video_top.sv sim/tb_video.cpp

# One process for every state: the 363 KB image only has to reach SDRAM once.
"$BUILD/tb_video" "$ROM" build $states

fail=0
for s in $states; do
    tag=$(basename "$s" .txt); tag=${tag#state_}
    python3 tools/diff_rtl.py "build/rtl_$tag.ppm" "$s" "$ROM" || fail=1
done

echo
if [ "$fail" -eq 0 ]; then
    echo "RTL matches the reference renderer on every state"
else
    echo "RTL does NOT match - fix that before building"
fi
exit $fail
