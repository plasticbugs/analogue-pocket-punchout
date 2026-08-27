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
everything else, so the two big-sprite graphics ROMs live in SDRAM. Everything
else — program, sound program, background characters, colour PROMs, the speech
ROM, all the video RAM — is block RAM and single cycle.

> **ROMs are not included and never will be.** You supply your own MAME
> `punchout` romset; the core reads one image built from it.

## Installing

1. Copy `Cores/`, `Platforms/` and `Assets/` from the release zip onto the root
   of the Pocket's SD card (overwriting an earlier version keeps your records:
   they live under `Saves/`, which the zip never touches).
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

## The core menu

| Option | What it does |
|---|---|
| Reset Core | Restart the machine |
| Reset Records | Wipe the battery RAM (high scores, play counters) |
| Screen Shape | Arcade (square pixels) or Fill Screen |
| Cabinet Reverb | Off / Light / Medium / Heavy — a short, dark room around the whole mix |
| Scanlines | Off / 25 % / 50 % / 75 % — on the fight screen, drawn at 2×, they fall on one row of each pair |
| Shadow Mask | Off / On / rotated / 2× |
| Difficulty, Round Time, Demo Sounds, Rematch At A Discount, Free Play, Copyright Notice, Service Mode | The board's DIP switches |

Records (high scores) are saved by the core itself a couple of seconds after
they change, to `Saves/punchout/plasticbugs.punchout/punchout.sav`, and loaded
at start. The Pocket's own **CRT Trinitron** display mode is available in its
display settings for this core.

## What is and is not implemented

Synthesis closes on the real part: 37% of the logic, 38% of the block RAM,
15 of 66 DSP blocks, and nothing negative in any timing corner at 96 MHz.

Working and verified:

* Both monitors, pixel-identical to MAME across 58 frozen machine states —
  both background tilemaps with per-row scrolling, the zooming opponent, the
  player, both palette banks, both flips and the full range of zoom the game
  reaches. The video state is snapshotted once per frame at the end of vertical
  blanking, so nothing the game writes mid-frame can tear the picture; the NMI
  leads that snapshot by 4.9 ms, more than the arcade's beam gives the game, so
  its updates always land whole.
* Z80 main board with the full memory map, I/O, the 74LS259 latch and the
  NMI — booted from reset in simulation and held to MAME frame for frame
  through attract mode, and through a scripted fight to the knockdown.
* RP2A03 sound board: T65 with decimal mode disabled, plus the NES APU; the
  speech mixed in at full scale to the board's half, judged on the Pocket's
  speaker.
* VLM5030 announcer, bit-exact against a transcription of MAME's synthesiser
  on every phrase the game speaks, at every speed it uses; its BUSY line paces
  the game's display cues exactly as the chip's would.
* Battery RAM saved to and restored from the SD card, byte-identical to MAME's
  through a 900-frame round trip in simulation.
* Cabinet reverb, scanlines and shadow mask as options; the platform banner
  and core icon.

Not yet:

* **Music verified against MAME.** The sound board is built and its clock
  rates are exact, but unlike the video and the speech it has not been held
  to a MAME recording sample for sample.
* **A fight frame-locked to MAME.** The pre-bout sequence matches MAME to the
  frame, but from the first exchange the scripted fight plays out about two
  seconds differently — the game's random source, an input-sampling detail or
  a sound-board handshake; measured, cause not yet found.

Hardware status: **plays on the Pocket** (v0.1.2) -- game logic, music,
speech, both screens, sprites, records. Getting the SDRAM path from garbage to
correct took four faults, all of them in the gap between simulation and
silicon, the black bar a fifth, and the save slot a sixth;
`docs/verification.md` tells that story. The diagnostic overlay,
probe and render-test switches that made each one a one-step diagnosis are
still in the RTL (`ovl_mode`, `probe_page`, `vid_mode`, `rtest` in
`punchout_core`), off by default and no longer in the Pocket menu; re-adding
their `interact.json` entries (git history, before v0.1.0-alpha.3) brings them
back.

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
* The Pocket platform layer from the OpenGateware framework, including its
  scanline and shadow-mask filters, and Adam Gastineau's data loader and
  unloader.

GPLv3. See `LICENSE`.
