Put punchout.rom here.

Build it from your own MAME punchout romset with the mra_build.py included in
this release:

    python3 mra_build.py punchout.mra punchout.zip

It checks every ROM's CRC32 and verifies the finished 371,712-byte image, so a
wrong or bad romset is reported rather than silently built.
