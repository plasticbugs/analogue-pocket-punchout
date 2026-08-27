# Punch-Out!! for Analogue Pocket

An openFPGA core for **Punch-Out!!** (Nintendo, 1984), reimplementing the arcade
hardware: a Z80 main board, an RP2A03 sound board (a 6502 with the NES APU on
the same die), two 256×224 monitors, and the two zooming "big sprite" tilemaps
that draw the boxers.

The cabinet had **two stacked monitors**. The Pocket has one, so the core
composites both into a single 512×672 raster: the info screen at native size
across the top third, the fight screen below it at a clean integer 2×. Neither
monitor loses a pixel.

```
 rows   0..223   INFO screen   256x224 at 1x, centred
 rows 224..671   FIGHT screen  512x448 at 2x, full width
```

The romset is 363 KB, which does not fit the Cyclone V's block RAM alongside
everything else, so the two big-sprite graphics ROMs and the speech data live in
SDRAM. Everything else — program, sound program, background characters, colour
PROMs, all the video RAM — is block RAM and single cycle.

> **ROMs are not included and never will be.** You supply your own MAME
> `punchout` romset; the core reads one image built from it.

## Installing

1. Copy `Cores/`, `Platforms/` and `Assets/` from the release zip onto the root
   of the Pocket's SD card.
2. Build the ROM image and copy it to `Assets/punchout/common/punchout.rom`:

   ```sh
   python3 mra_build.py punchout.mra punchout.zip
   ```

   Nothing but Python 3 is needed. It checks every ROM's CRC32 and verifies the
   finished 371,712-byte image against a known md5, so a wrong or bad romset is
   reported rather than silently built.

## Controls

| Pocket | Arcade |
|---|---|
| D-pad | 4-way stick — dodge left/right, duck, block |
| Y, or L | Left punch |
| X, or R | Right punch |
| B or A | KO punch |
| Select | Coin |
| Start | Coin |

There is no start button on this machine: inserting a coin begins play, so both
Select and Start are wired to the coin slot. Top row is the two jabs, bottom row
the KO; the shoulders mirror the jabs so either hand position works.

## What is and is not implemented

Synthesis closes on the real part: 25% of the logic, 28% of the block RAM, and
**+0.844 ns** of setup slack at 96 MHz with nothing negative in any corner.

Working and verified:

* Both monitors, pixel-identical to MAME across 52 frozen machine states —
  both background tilemaps with per-row scrolling, the zooming opponent, the
  player, both palette banks, both flips and the full range of zoom the game
  reaches. The video state is snapshotted once per frame at the end of vertical
  blanking, so nothing the game writes mid-frame can tear the picture.
* Z80 main board with the full memory map, I/O, the 74LS259 latch and the
  vblank NMI — booted from reset in simulation and held to MAME frame for frame
  through attract mode.
* RP2A03 sound board: T65 with decimal mode disabled, plus the NES APU.
* VLM5030 announcer, bit-exact against a transcription of MAME's synthesiser
  on every phrase the game speaks, at every speed it uses.

Not yet:

* **Persistent records.** The NVRAM works within a session but is not yet saved
  to the SD card.
* **Audio verified against MAME.** The sound path is built and the clock rates
  are exact, but it has not been measured against a MAME recording yet.
* **Platform artwork.** No banner image ships, so the Pocket shows its default
  one. Cosmetic.

Hardware status: **plays on the Pocket** -- game logic, music, both screens,
sprites. Getting the SDRAM path from garbage to correct took four faults, all
of them in the gap between simulation and silicon; `docs/verification.md`
tells that story, and the **Diagnostics Overlay** in the core menu is what made
each one a one-step diagnosis.

## Building

```sh
./sim/lint.sh                       # seconds; run before every push
./build-local.sh map                # Quartus analysis only, a couple of minutes
./build-local.sh                    # full compile + package
```

The verification gates, which need MAME and a romset:

```sh
python3 tools/mra_build.py punchout.mra mame-romset/ build/punchout.rom
./tools/capture_states.sh           # dump frozen states + MAME's own bitmaps
./tools/regress_ref.sh              # reference renderer vs MAME
ROM=build/punchout.rom ./sim/run_video.sh   # RTL vs reference renderer

./tools/capture_attract.sh                  # MAME references, no input
ROM=build/punchout.rom ./sim/run_system.sh  # boot the machine, compare frames
PO_LOSE=1 SYSREF=<gloat captures> FRAMES="7956 8000 8100" ./sim/run_system.sh  # play the losing fight
python3 tools/vlm5030.py build/punchout.rom build/vlm   # reference speech for every phrase
./sim/run_vlm.sh                                          # VLM5030 RTL vs the model, sample for sample
```

`docs/hardware.md` is the machine description everything is built from, and
`docs/verification.md` records what has been checked, how, and what each bug
looked like on the way.

## Credits

* MAME's `nintendo/punchout.cpp` by Nicola Salmoria — the hardware description
  this core is derived from.
* [tv80](https://github.com/hutch31/tv80) Z80 (MIT).
* T65 6502 by Daniel Wallner and MikeJ (BSD), via MiSTer's VIC20 core.
* NES APU by Kitrinx (GPLv3), via
  [NES_MiSTer](https://github.com/MiSTer-devel/NES_MiSTer).
* VLM5030 after MAME's `vlm5030.cpp` by Tatsuyuki Satoh (BSD-3-Clause), with
  the chip's coefficient tables recovered from decaps by ogoun and John
  McMaster.
* The Pocket platform layer from the openFPGA framework.

GPLv3. See `LICENSE`.
