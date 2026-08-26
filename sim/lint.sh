#!/bin/sh
# Lint every RTL file the core synthesises, plus the bench wrappers. Run before
# every push: it catches syntax and inference errors in seconds, where a broken
# push costs a whole CI cycle.
set -e
cd "$(dirname "$0")/.."

# The waiver names below (WIDTHEXPAND, UNUSEDSIGNAL, IMPLICITSTATIC ...) only
# exist from Verilator 5, and an unknown -Wno- name is an error, not a warning.
# Say so plainly rather than failing with something that looks like an RTL fault.
ver=$(verilator --version 2>/dev/null | sed -E 's/^Verilator ([0-9]+).*/\1/')
if [ -z "$ver" ]; then
    echo "verilator not found"; exit 2
fi
if [ "$ver" -lt 5 ]; then
    echo "Verilator $ver is too old; this needs 5.x for the warning names used here"
    exit 2
fi
FLAGS="-Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-VARHIDDEN -Wno-PROCASSINIT
       -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNSIGNED
       -Wno-PINCONNECTEMPTY -Wno-IMPLICITSTATIC
       -Wno-UNUSEDPARAM -Wno-IMPORTSTAR -Wno-DEFPARAM -Wno-PINMISSING
       -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN"

# The last row of waivers is for vendored code -- tv80's unused flag parameters,
# and the NES APU's defparams, package import and one upstream sub-instantiation
# that leaves allow_us unconnected. Both are kept byte-identical to upstream so
# they stay diffable, so the warnings are waived rather than fixed.

echo "--- video core ---"
verilator --lint-only $FLAGS --top-module punchout_video \
    rtl/po_ram.sv rtl/punchout_video.sv

echo "--- main board (Z80) ---"
verilator --lint-only $FLAGS --top-module punchout_main \
    rtl/po_ram.sv rtl/punchout_main.sv rtl/tv80s_cen.v \
    modules/cpu-tv80/tv80_core.v modules/cpu-tv80/tv80_alu.v \
    modules/cpu-tv80/tv80_mcode.v modules/cpu-tv80/tv80_reg.v

echo "--- sound board (RP2A03; T65 is VHDL, so a stub stands in) ---"
verilator --lint-only $FLAGS --top-module punchout_sound \
    rtl/po_ram.sv modules/sound-apu/apu_savestate_stub.sv modules/sound-apu/apu.sv \
    sim/t65_stub.sv rtl/punchout_sound.sv

echo "--- whole machine ---"
verilator --lint-only $FLAGS --top-module punchout_core \
    rtl/po_ram.sv rtl/po_romload.sv rtl/sdram16.sv rtl/punchout_video.sv \
    rtl/punchout_main.sv rtl/punchout_sound.sv rtl/punchout_core.sv \
    rtl/tv80s_cen.v modules/cpu-tv80/tv80_core.v modules/cpu-tv80/tv80_alu.v \
    modules/cpu-tv80/tv80_mcode.v modules/cpu-tv80/tv80_reg.v \
    modules/sound-apu/apu_savestate_stub.sv modules/sound-apu/apu.sv sim/t65_stub.sv

echo "--- video bench hierarchy (adds the SDRAM controller and loader) ---"
verilator --lint-only $FLAGS --top-module tb_video_top \
    rtl/po_ram.sv rtl/po_romload.sv rtl/sdram16.sv rtl/punchout_video.sv \
    sim/sdram_model.sv sim/tb_video_top.sv

echo "lint clean"
