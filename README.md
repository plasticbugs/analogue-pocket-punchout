# Punch-Out!! and Super Punch-Out!! for Analogue Pocket

An openFPGA core for **Punch-Out!!**, **Super Punch-Out!!** (Nintendo, 1984) and
**Arm Wrestling** (1985), reimplementing the arcade hardware: a Z80 main board, an RP2A03 sound board (a
6502 with the NES APU on the same die), a VLM5030 speech synthesiser, two
256×224 monitors, and the two zooming "big sprite" tilemaps that draw the
boxers.

All three ran on the same Nintendo board, so one bitstream plays any of them —
pick the image from **ROM Set** in the core menu. Super Punch-Out!! adds an
RP5C01 clock and an RP5H01 one-time PROM as copy protection, which the core
implements; those chips sit on I/O ports the other games never read, so nothing
has to be detected for them. Arm Wrestling genuinely rewires the video — a third
tilemap, one character set shared by both monitors, a sideways big sprite — and
the core switches to it on the image's length, which the Pocket reports before
the first byte arrives.

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
   python3 mra_build.py punchout.mra punchout.zip     # Punch-Out!!
   python3 mra_build.py spnchout.mra spnchout.zip     # Super Punch-Out!!
   python3 mra_build.py armwrest.mra armwrest.zip     # Arm Wrestling
   ```

   Nothing but Python 3 is needed. It checks every ROM's CRC32 and verifies the
   finished image against a known md5, so a wrong or bad romset is reported
   rather than silently built. Put any of them in `Assets/punchout/common/` and
   choose one from **ROM Set** in the core menu. The two Punch-Out!!s share a
   371,712-byte layout; Arm Wrestling's is 420,864, which is how the core knows
   which hardware to be.

## Controls

| Pocket | Arcade |
|---|---|
| D-pad | 4-way stick — dodge left/right, duck, block |
| Y, or L | Left punch |
| X, or R | Right punch |
| B or A | KO punch |
| Start | Super Punch-Out!!'s fourth button (menu can move it to L or R) |
| Select | Coin |

There is no start button on these machines: inserting a coin begins play, so
Select is the coin slot. Top row is the two jabs, bottom row the KO; the
shoulders mirror the jabs so either hand position works. Super Punch-Out!! has a
fourth button, which Punch-Out!! leaves unconnected and ignores, so it is wired
for both games and defaults to Start.

## The core menu

| Option | What it does |
|---|---|
| Reset Core | Restart the machine |
| Reset Records | Wipe the battery RAM (high scores, play counters) |
| Screen Shape | Arcade (square pixels) or Fill Screen |
| ROM Set | Which game: `punchout.rom`, `spnchout.rom` or `armwrest.rom` |
| SPO 4th Button | Start / L / R / Off — Super Punch-Out!!'s fourth button |
| Cabinet Reverb | Off / Light / Medium / Heavy — a short, dark room around the whole mix |
| Scanlines | Off / 25 % / 50 % / 75 % — on the fight screen, drawn at 2×, they fall on one row of each pair |
| Shadow Mask | Off / On / rotated / 2× |
| Difficulty, Round Time, Demo Sounds, Rematch At A Discount, Free Play, Copyright Notice, Service Mode | The board's DIP switches. Labelled for Punch-Out!!; Arm Wrestling's switches mean different things (two halves of a coinage table, and a rematch count) |

Records (high scores) are saved by the core itself a couple of seconds after
they change, to `Saves/punchout/plasticbugs.punchout/punchout.sav`, and loaded
at start. The Pocket's own **CRT Trinitron** display mode is available in its
display settings for this core.

## What is and is not implemented

Synthesis closes on the real part: 41% of the logic, 51% of the block RAM,
14 of 66 DSP blocks, and nothing negative in any timing corner at 96 MHz.

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
* **Super Punch-Out!!** on the same bitstream: its RP5C01 + RP5H01 protection
  reproduces every one of the 5853 reads the game makes in 30 seconds of MAME,
  its frozen states render pixel-identical, and it boots and runs frame for
  frame with MAME through attract mode.
* **Arm Wrestling** on the same bitstream: its third tilemap, shared character
  set and sideways big sprite render pixel-identical to MAME across eight
  frozen states, and frames 150, 300, 600, 900 and 1500 of attract mode are
  identical to MAME.
* **All three games boot into attract mode frame-identical to MAME** from
  frame 300 onward, on one bitstream. One earlier frame per game still differs
  -- Punch-Out!! at 150, Arm Wrestling at 60 -- and each of those renders
  pixel-exactly from its own state, so what differs is the machine's timing in
  the first seconds, not the video hardware.

Not yet:

* **Music sample-exact against MAME.** The sound board's music tracks MAME's
  envelope frame for frame when fed MAME's own register-write stream (the
  sound CPU is VHDL and cannot run in the simulator, so it is driven that
  way), but the NES_MiSTer APU and MAME's differ in level convention and
  mixing detail, so a sample-for-sample match -- as the video and speech have
  -- is not on offer. `docs/verification.md` has the measurement.
* **A fight frame-locked to MAME.** The pre-bout sequence matches MAME to the
  frame, but from the first exchange the scripted fight plays out about two
  seconds differently — the game's random source, an input-sampling detail or
  a sound-board handshake; measured, cause not yet found. Arm Wrestling shows
  the same kind of gap at frame 60 -- one second after power-on, before the
  first screen has settled -- and is identical to MAME from frame 150 on.

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

Very little of a core like this is invented. The hardware description came from
people who reverse-engineered the board, the CPUs came from projects that
predate this one by twenty years, and the platform layer came from a framework
that makes an openFPGA core buildable at all.

### The hardware description

* MAME's `nintendo/punchout.cpp`, `punchout_v.cpp` and `punchout.h` by **Nicola
  Salmoria** — the description of the board this core is derived from, read at
  MAME 0.288. `docs/hardware.md` cites it throughout.
* MAME's `rp5c01.cpp` and `rp5h01.cpp` device models — the source for Super
  Punch-Out!!'s RTC and one-time-PROM protection, transcribed in
  `rtl/po_protect.sv` and `tools/protection.py`.
* MAME's `vlm5030.cpp` by **Tatsuyuki Satoh** (BSD-3-Clause) — the speech
  synthesiser, with the chip's coefficient tables recovered from decaps by
  **ogoun** and **John McMaster**.

### CPUs and sound

* [tv80](https://github.com/hutch31/tv80) Z80 by **Guy Hutchison** (MIT), itself
  based on Daniel Wallner's T80.
* T65 6502 by **Daniel Wallner**, **Mike Johnson**, **Wolfgang Scherr** and
  **Morten Leikvoll** (BSD), via MiSTer's VIC20 core.
* NES APU by **Kitrinx** (GPLv3), via
  [NES_MiSTer](https://github.com/MiSTer-devel/NES_MiSTer).

### Platform layer

* The Pocket platform layer is the [OpenGateware](https://github.com/opengateware)
  framework, whose primary author is **Marcus Andrade** (MIT and GPLv3). Within
  it this core also uses work by **Alexey Melnikov** (SDRAM controller, scanline,
  shadow-mask and audio filters), **Mike Field** (the original SDRAM
  controller), **Jim Gregory** and **Alan Steremberg** (hiscore/NVRAM),
  **Jacob Boline** (USB-HID keyboard), **Till Harbaum** (scanline generator)
  and **Adam Gastineau** (data loader and unloader).
* `rtl/sdram16.sv` is OpenGateware's SDRAM controller, © Alexey Melnikov and
  Mike Field (GPLv3).
* PLL and memory wrappers under `core_pll/` and `platform/pocket/megafunctions/`
  are generated Altera/Intel megafunction instantiations.

### Licensing

Copyright © 2026 plasticbugs. This project is GPLv3 — see `LICENSE`. Two things
it does **not** cover:

* `platform/pocket/bsp/pocket/apf_top.sv` and the APF bridge peripherals in
  `platform/pocket/peripherals/` are supplied by **Analogue Enterprises
  Limited** under the Analogue Pocket Framework Software License Agreement and
  [EULA](https://www.analogue.link/pocket-eula), not under the GPL. `core_top.sv`
  and the synchronisers also carry Analogue copyright.
* The vendored CPU cores keep their own licences (MIT for tv80, BSD for T65);
  their headers are intact and must stay that way in any redistribution.

No ROM data of any kind is included, and none may be added — see **ROM
distribution** above.

### Tools

* **MAME 0.288** as the oracle: not just a thing to compare against but a
  scriptable instrument, driven by the Lua scripts in `tools/` to freeze state,
  tap writes and dump the screen.
* **Verilator** for simulation and lint, **Quartus Prime Lite 18.1** for
  synthesis (via the `raetro/quartus:pocket` image), **Python 3** for the
  reference renderers and the ROM builder — no third-party Python modules.
