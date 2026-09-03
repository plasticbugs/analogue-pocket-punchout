Put punchout.rom, spnchout.rom and/or armwrest.rom here.

One core plays all three games; the ROM Set slot picks which image to load,
so keep the ones you build side by side in this folder.

Build them from your own MAME romsets with the mra_build.py included in
this release:

    python3 mra_build.py punchout.mra punchout.zip
    python3 mra_build.py spnchout.mra spnchout.zip
    python3 mra_build.py armwrest.mra armwrest.zip

It checks every ROM's CRC32 and verifies the finished image (371,712 bytes
for Punch-Out!! and Super Punch-Out!!, 421,888 for Arm Wrestling), so a
wrong or bad romset is reported rather than silently built.
