Put punchout.rom, spnchout.rom and/or armwrest.rom here.

One core plays all three games. Choosing Run asks which image to load, and this
folder is where it looks, so keep whichever ones you build side by side.

The core's data.json names a default of "choose-a-game.rom" that is never
shipped. That is deliberate: with no such file on the card the Pocket opens the
file browser instead of starting a game, and the three real images are listed
beside it as alternate_filenames, which is how an updater knows about all of
them. An updater may report "choose-a-game.rom" as not found. That is expected
and nothing is wrong.

Build the images from your own MAME romsets with the mra_build.py included in
this release:

    python3 mra_build.py punchout.mra punchout.zip
    python3 mra_build.py spnchout.mra spnchout.zip
    python3 mra_build.py armwrest.mra armwrest.zip

It checks every ROM's CRC32 and verifies the finished image (371,712 bytes for
Punch-Out!! and Super Punch-Out!!, 420,864 for Arm Wrestling), so a wrong or
bad romset is reported rather than silently built.
