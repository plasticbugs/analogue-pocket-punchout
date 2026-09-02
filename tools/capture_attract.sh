#!/bin/sh
# Capture MAME's own screen bitmaps for a spread of attract-mode frames, with
# no input at all, so the full-system bench has something deterministic to be
# held to. One MAME run per frame.
set -e
cd "$(dirname "$0")/.."
OUT=${OUT:-artifacts_sys}
ROMSET=${ROMSET:-mame-romset}
# GAME picks the MAME set: punchout, or spnchout for Super Punch-Out!!
GAME=${GAME:-punchout}
# Every MAME run starts from a blank battery RAM and no saved config,
# which is how the core starts. A carried-over nvram changes what
# attract mode draws -- it is why Arm Wrestling's first boot comparison
# differed by 94,606 pixels -- and made the references irreproducible.
COLD=$(mktemp -d)
trap 'rm -rf "$COLD" ${SCRATCH:-}' EXIT
FRAMES=${FRAMES:-"60 150 300 600 900"}

ROMPATH="$ROMSET"
if [ -d "$ROMSET" ]; then
    SCRATCH=$(mktemp -d)
    (cd "$ROMSET" && zip -q -X "$SCRATCH/$GAME.zip" ./*.*)
    ROMPATH="$SCRATCH"
else
    ROMPATH=$(dirname "$ROMSET")
fi

rm -rf "$OUT"; mkdir -p "$OUT" build/mamecfg
for f in $FRAMES; do
    rm -rf "$COLD"; mkdir -p "$COLD"
    tag=$(printf "%04d" "$f")
    PO_OUT="$OUT" PO_FRAME="$f" PO_TAG="$tag" PO_NOINPUT=1 \
    mame "$GAME" -rompath "$ROMPATH" -video none -sound none -nothrottle \
        -skip_gameinfo -seconds_to_run 3600 -snapshot_directory "$OUT/snap" \
        -cfg_directory "$COLD" -nvram_directory "$COLD" \
        -autoboot_script tools/dumpstate.lua 2>&1 | grep -E '^\[po\]' | tail -1
done
rm -rf "$OUT/snap"
echo "attract-mode references in $OUT"
