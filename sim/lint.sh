#!/bin/sh
# Lint every RTL file the core synthesises, plus the bench wrappers. Run before
# every push: it catches syntax and inference errors in seconds, where a broken
# push costs a whole CI cycle.
set -e
cd "$(dirname "$0")/.."

verilator --version >/dev/null 2>&1 || { echo "verilator not found"; exit 2; }

# Verilator renames and splits warning names between releases -- PROCASSINIT
# became PROCASSWIRE, UNUSED split into UNUSEDSIGNAL and UNUSEDPARAM, WIDTH
# split into WIDTHEXPAND and WIDTHTRUNC -- and an unknown -Wno- name is a hard
# error, not a warning. A CI runner with a different build than the developer's
# then fails on the flags rather than on the RTL, which is what happened the
# first time this ran.
#
# So each waiver is probed against a trivial module and kept only if this
# Verilator knows it. Anything genuinely wrong still fails; the list just stops
# depending on which release is installed.
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
echo 'module lintprobe; endmodule' > "$PROBE/lintprobe.v"

WANT="DECLFILENAME UNUSEDSIGNAL UNUSEDPARAM VARHIDDEN PROCASSINIT PROCASSWIRE
      WIDTHEXPAND WIDTHTRUNC WIDTH CASEINCOMPLETE UNSIGNED PINCONNECTEMPTY
      IMPLICITSTATIC IMPORTSTAR DEFPARAM PINMISSING SYNCASYNCNET MULTIDRIVEN
      BLKSEQ"

# sim/waivers.vlt silences the vendored sources -- tv80, T65, the NES APU and
# the SDRAM controller -- by PATH rather than by warning name. They are kept
# byte-identical to upstream so they stay diffable, so their style warnings are
# not ours to fix, and a name-based list would fail on whichever Verilator the
# runner happens to have: 5.020 reports BLKSEQ on tv80 where 5.050 does not.
#
# That file carries no comments because Verilator's config parser rejects both
# // and block comments inside it, which is why this note is here instead.
#
# Nothing in rtl/punchout_*.sv or rtl/po_*.sv is waived. Lint exists to catch
# mistakes in this core's own code, and it still does.
FLAGS="-Wall sim/waivers.vlt"
for w in $WANT; do
    if verilator --lint-only "-Wno-$w" "$PROBE/lintprobe.v" >/dev/null 2>&1; then
        FLAGS="$FLAGS -Wno-$w"
    fi
done

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
