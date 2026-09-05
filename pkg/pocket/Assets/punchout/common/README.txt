Put punchout.rom, spnchout.rom and/or armwrest.rom here.

One core plays all three games. You do not pick the image directly any more:
the Pocket lists the games by name, and each entry knows which image it needs.
Those entries are the .json files one folder up, in

    Assets/punchout/plasticbugs.punchout/

so that folder and this one both have to be on the card. A game whose image is
missing simply will not load; the others still work.

Build the images from your own MAME romsets with the mra_build.py included in
this release:

    python3 mra_build.py punchout.mra punchout.zip
    python3 mra_build.py spnchout.mra spnchout.zip
    python3 mra_build.py armwrest.mra armwrest.zip

It checks every ROM's CRC32 and verifies the finished image (371,712 bytes for
Punch-Out!! and Super Punch-Out!!, 420,864 for Arm Wrestling), so a wrong or
bad romset is reported rather than silently built.

Records are saved per game, to Saves/punchout/plasticbugs.punchout/.
