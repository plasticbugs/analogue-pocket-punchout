#!/bin/sh
# Run every captured state through the reference renderer and fail on any
# differing pixel. This is the gate the renderer has to keep passing before it
# is trusted as the spec the RTL is checked against.
#
#   ./tools/regress_ref.sh                    artifacts/ + punchout.rom
#   OUT=art2 ROM=build/punchout.rom ./tools/regress_ref.sh
set -e
cd "$(dirname "$0")/.."
OUT=${OUT:-artifacts}
ROM=${ROM:-punchout.rom}

[ -f "$ROM" ] || { echo "no $ROM - build it with tools/mra_build.py"; exit 2; }
states=$(ls "$OUT"/state_*.txt 2>/dev/null) || true
[ -n "$states" ] || { echo "no states in $OUT - run tools/capture_states.sh"; exit 2; }

fail=0
for s in $states; do
    python3 tools/render_model.py "$s" "$ROM" || fail=1
done

if [ "$fail" -ne 0 ]; then
    echo
    echo "reference renderer does NOT match MAME - fix that before touching RTL"
    exit 1
fi
echo
echo "reference renderer matches MAME on every captured state"
