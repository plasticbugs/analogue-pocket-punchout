#!/usr/bin/env python3
"""Assemble an Analogue Pocket SD-card package from the compiled bitstream.

The Pocket loads a bit-reversed RBF (each byte's bits swapped) named per
core.json ("bitstream.rbf_r"). Output goes to release/pocket/ ready to copy
onto the SD card root.

Never ships a ROM: the copy step excludes them and there is a final sweep that
fails the package if one slipped through anyway.
"""
import os, shutil, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RBF = os.path.join(ROOT, "projects", "output_files", "punchout_pocket.rbf")
PKG = os.path.join(ROOT, "pkg", "pocket")
OUT = os.path.join(ROOT, "release", "pocket")
CORE_ID = "plasticbugs.punchout"
# The Pocket resolves a data slot to Assets/<platform_id>/common/<filename>.
PLATFORM_ID = "punchout"

if not os.path.exists(RBF):
    sys.exit(f"missing {RBF} - run the Quartus compile first "
             "(and make sure the project generates a compressed RBF)")

REV = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
reversed_rbf = bytes(REV[b] for b in open(RBF, "rb").read())

if os.path.exists(OUT):
    shutil.rmtree(OUT)
# ROMs may sit in pkg/pocket/Assets locally (gitignored); never package them.
shutil.copytree(PKG, OUT, ignore=shutil.ignore_patterns('.DS_Store', '*.rom', '*.zip'))

core_dir = os.path.join(OUT, "Cores", CORE_ID)
with open(os.path.join(core_dir, "bitstream.rbf_r"), "wb") as f:
    f.write(reversed_rbf)

# Ship the ROM recipe and its builder alongside the core, so a downloaded
# release contains everything needed to produce punchout.rom.
for extra in ("punchout.mra", "spnchout.mra", "armwrest.mra", "README.md",
              os.path.join("tools", "mra_build.py")):
    src = os.path.join(ROOT, extra)
    if os.path.exists(src):
        shutil.copy(src, os.path.join(OUT, os.path.basename(extra)))

# Backstop: the ROM folder must be in the package even though it ships empty.
# git cannot track an empty directory, so it only survives a fresh checkout
# because of the placeholder note inside it -- delete that and the release
# silently loses the one folder telling users where their ROMs go.
slot = os.path.join(OUT, "Assets", PLATFORM_ID, "common")
if not os.path.isdir(slot) or not os.listdir(slot):
    sys.exit(f"refusing to package, {os.path.relpath(slot, ROOT)} is missing or "
             "empty - it needs a tracked placeholder note, since git drops empty "
             "directories and the core cannot find its ROMs without that folder")

# Backstop: the three instance JSONs are how the Pocket lists the games. Losing
# one silently drops a game from the menu, which looks like a core bug rather
# than a packaging one, so check for all of them by name.
inst = os.path.join(OUT, "Assets", PLATFORM_ID, "plasticbugs.punchout")
want = {"Punch-Out!! (Rev B).json", "Super Punch-Out!!.json", "Arm Wrestling.json"}
have = set(os.listdir(inst)) if os.path.isdir(inst) else set()
if want - have:
    sys.exit("refusing to package, instance JSON missing:\n  " +
             "\n  ".join(sorted(want - have)))

# Backstop: a gitignored test ROM in the package tree must never reach a release.
strays = [os.path.join(dp, f) for dp, _, fs in os.walk(OUT) for f in fs
          if f.lower().endswith(('.rom', '.zip'))]
if strays:
    sys.exit("refusing to package, ROM files present:\n  " + "\n  ".join(strays))

print(f"packaged -> {OUT}")
print("copy Cores/, Platforms/ and Assets/ from that folder onto the SD card root")
print("build a ROM with:    python3 mra_build.py punchout.mra punchout.zip")
print("                     python3 mra_build.py spnchout.mra spnchout.zip")
print("                     python3 mra_build.py armwrest.mra armwrest.zip")
