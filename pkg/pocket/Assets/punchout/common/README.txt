Put punchout.rom, spnchout.rom and/or armwrest.rom here.

One core plays all three games. Opening the core asks which image to load, and
this folder is where it looks, so keep whichever ones you build side by side.

Build them from your own MAME romsets with the mra_build.py included in this
release:

    python3 mra_build.py punchout.mra punchout.zip
    python3 mra_build.py spnchout.mra spnchout.zip
    python3 mra_build.py armwrest.mra armwrest.zip

It checks every ROM's CRC32 and verifies the finished image (371,712 bytes for
Punch-Out!! and Super Punch-Out!!, 420,864 for Arm Wrestling), so a wrong or
bad romset is reported rather than silently built.

Records are kept per game: the save file takes the name of the image you
loaded, so punchout.rom keeps its records in punchout.sav, and the other two
games no longer share that file.
