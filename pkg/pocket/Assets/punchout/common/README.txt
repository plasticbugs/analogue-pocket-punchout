Put punchout.rom, spnchout.rom and/or armwrest.rom here.

One core plays all three games. It boots Punch-Out!! and you switch to the
others from ROM Set in the core menu.

All three are named in the core's data.json -- punchout.rom as the default and
the other two as alternate_filenames -- so an updater that fetches assets knows
about all of them, not just the one that boots.

Build them from your own MAME romsets with the mra_build.py included in this
release:

    python3 mra_build.py punchout.mra punchout.zip
    python3 mra_build.py spnchout.mra spnchout.zip
    python3 mra_build.py armwrest.mra armwrest.zip

It checks every ROM's CRC32 and verifies the finished image (371,712 bytes for
Punch-Out!! and Super Punch-Out!!, 420,864 for Arm Wrestling), so a wrong or
bad romset is reported rather than silently built.
