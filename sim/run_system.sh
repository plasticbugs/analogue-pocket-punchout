#!/bin/sh
# Full-system bench: boot the machine from reset and hold it to MAME frame for
# frame through attract mode. Slower than the video bench -- a few minutes for a
# few hundred frames -- so it is for integration questions, not iteration.
#
#   SYSREF=artifacts_sys ROM=build/punchout.rom ./sim/run_system.sh
set -e
cd "$(dirname "$0")/.."
ROM=${ROM:-punchout.rom}
SYSREF=${SYSREF:-artifacts_sys}
FRAMES=${FRAMES:-"60 150 300 600 900"}
BUILD=${BUILD:-build/sim_system}

[ -f "$ROM" ] || { echo "no $ROM - build it with tools/mra_build.py"; exit 2; }
[ -d "$SYSREF" ] || { echo "no $SYSREF - run tools/capture_attract.sh"; exit 2; }

mkdir -p "$BUILD"
verilator --cc --exe --build -j 0 -O2 -Irtl \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-VARHIDDEN -Wno-PROCASSINIT \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNSIGNED \
    -Wno-PINCONNECTEMPTY -Wno-IMPLICITSTATIC -Wno-UNUSEDPARAM -Wno-IMPORTSTAR \
    -Wno-DEFPARAM -Wno-PINMISSING -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN \
    --top-module tb_system_top --Mdir "$BUILD" -o tb_system \
    rtl/po_ram.sv rtl/po_romload.sv rtl/sdram16.sv rtl/po_sdram_test.sv rtl/punchout_video.sv \
    rtl/po_protect.sv rtl/punchout_main.sv rtl/punchout_sound.sv rtl/po_vlm5030.sv rtl/punchout_core.sv \
    rtl/tv80s_cen.v modules/cpu-tv80/tv80_core.v modules/cpu-tv80/tv80_alu.v \
    modules/cpu-tv80/tv80_mcode.v modules/cpu-tv80/tv80_reg.v \
    modules/sound-apu/apu_savestate_stub.sv modules/sound-apu/apu.sv \
    sim/t65_stub.sv sim/sdram_model.sv sim/tb_system_top.sv sim/tb_system.cpp

"$BUILD/tb_system" "$ROM" "$SYSREF" $FRAMES
