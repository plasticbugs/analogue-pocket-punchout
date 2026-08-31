#!/bin/sh
# Capture a spread of frozen video states + the matching MAME snapshots.
# One MAME run per state: freezing the video RAM is a one-way door.
#
#   ./tools/capture_states.sh                 default spread into artifacts/
#   FRAMES="900 1500" OUT=art2 ./tools/capture_states.sh
#
# ROMSET defaults to the loose romset directory in the tree; a punchout.zip
# works just as well.
set -e
cd "$(dirname "$0")/.."
OUT=${OUT:-artifacts}
ROMSET=${ROMSET:-mame-romset}
# GAME picks the MAME set: punchout, or spnchout for Super Punch-Out!!
GAME=${GAME:-punchout}

# Frames picked from a 9000-frame scan of the big-sprite control registers
# rather than by eye, so the set actually covers what the hardware can do:
#     3  zoom = 0, the whole big sprite disabled
#    40  top monitor only, and the largest zoom the game reaches (2040)
#   120  big sprite on BOTH monitors at once
#   161  the smallest zoom the game reaches (192) - maximum magnification
#  1100  big sprite #1 flipped in x
#  1800  big sprite #2 flipped in x
#  the rest are ordinary gameplay at assorted opponent distances
FRAMES=${FRAMES:-"3 40 120 161 300 700 900 1100 1400 1800 2400 3000 3600 7312"}

# MAME needs a directory containing punchout.zip, or loose files it can find on
# the rompath. A loose directory named for the set works if we point rompath at
# its parent, so build a zip in a scratch dir when handed a directory.
ROMPATH="$ROMSET"
SCRATCH=""
if [ -d "$ROMSET" ]; then
    SCRATCH=$(mktemp -d)
    (cd "$ROMSET" && zip -q -X "$SCRATCH/$GAME.zip" ./*.*)
    ROMPATH="$SCRATCH"
    trap 'rm -rf "$SCRATCH"' EXIT
else
    ROMPATH=$(dirname "$ROMSET")
fi

rm -rf "$OUT"; mkdir -p "$OUT" build/mamecfg
# Two synthetic states on top of the real ones: the game leaves palettebank at
# zero for as long as anything has ever been able to drive it, so bank 1 and
# bank 3 (both monitors switched) are forced by hand at frame 900. Without
# these, half the palette PROM is never read by any test.
SYNTH=${SYNTH:-"900:1 900:3"}

for f in $FRAMES; do
    tag=$(printf "%04d" "$f")
    PO_OUT="$OUT" PO_FRAME="$f" PO_TAG="$tag" \
    mame "$GAME" -rompath "$ROMPATH" -video none -sound none -nothrottle \
        -skip_gameinfo -seconds_to_run 3600 \
        -snapshot_directory "$OUT/snap_$tag" -cfg_directory build/mamecfg \
        -nvram_directory build/mamecfg -autoboot_script tools/dumpstate.lua \
        2>&1 | grep -E '^\[po\]' || true
    snap=$(ls "$OUT/snap_$tag"/"$GAME"/*.png 2>/dev/null | head -1)
    [ -n "$snap" ] || { echo "no snapshot for frame $f"; exit 1; }
    mv "$snap" "$OUT/mame_$tag.png"
    rm -rf "$OUT/snap_$tag"
    echo "captured $tag"
done

for spec in $SYNTH; do
    f=${spec%%:*}; bank=${spec##*:}
    tag=$(printf "%04dp%s" "$f" "$bank")
    PO_OUT="$OUT" PO_FRAME="$f" PO_TAG="$tag" PO_PALBANK="$bank" \
    mame "$GAME" -rompath "$ROMPATH" -video none -sound none -nothrottle \
        -skip_gameinfo -seconds_to_run 3600 \
        -snapshot_directory "$OUT/snap_$tag" -cfg_directory build/mamecfg \
        -nvram_directory build/mamecfg -autoboot_script tools/dumpstate.lua \
        2>&1 | grep -E '^\[po\]' || true
    snap=$(ls "$OUT/snap_$tag"/"$GAME"/*.png 2>/dev/null | head -1)
    [ -n "$snap" ] && mv "$snap" "$OUT/mame_$tag.png"
    rm -rf "$OUT/snap_$tag"
    echo "captured $tag (palettebank $bank)"
done
