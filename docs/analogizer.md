# The Analogizer

[Analogizer](https://github.com/RndMnkIII/Analogizer) is RndMnkIII's adapter
for the Pocket's cartridge slot. It gives analog video out of a VGA connector
(RGBS, RGsB, YPbPr, Y/C, and a scandoubled RGBHV) and takes native controllers
through SNAC adapters. Its wiki is the authority on the adapter itself:
[specifications](https://github.com/RndMnkIII/Analogizer/wiki/Analogizer-Specifications),
[how to configure it](https://github.com/RndMnkIII/Analogizer/wiki/Supported-Cores-and-How-to-Configure-Them).

Punch-Out!! supports it (`USE_ANALOGIZER = 1` in `core_top.sv`), added after
the core shipped by following the pocket-core-template's retrofit handoff.
This page is what the player gets, how it is built, and what has been
proven.

**The cabinet had two monitors; the CRT gets the bottom one.** The Pocket
shows both screens stacked in one picture. On the Analogizer the core sends
the fight screen alone -- 256 x 224, at a 15 kHz monitor's own timing -- as
the cabinet's lower monitor showed it, and the Pocket can then become the
upper monitor (the info screen, filling the display): one Pocket and one
CRT, set up like the cabinet.

## For the player

**Settings are in the core's own menu**, under the game's other options,
like RndMnkIII's own "Pocket Menu" Analogizer cores (the wiki's list calls the
other kind, which reads a shared `analogizer.bin`, "Analogizer File"; a core
from this template does not read that file). The Pocket remembers them per
core.

| entry | options |
|---|---|
| Analogizer | Off (the default); On (the Pocket keeps both screens); On, Pocket: top screen (the Pocket shows the info screen alone, filling the display); On, Pocket off (the Pocket's screen goes black) |
| Analogizer Video | RGBS, RGsB, YPbPr, Y/C NTSC, Y/C PAL, Scandoubler, Scandoubler 25% / 50% / 75%, Scandoubler HQ2x |
| SNAC Adapter | None, DB15, NES, SNES, PCE 2-button, PCE 6-button, PCE Multitap, DB15 Fast, SNES A,B<->X,Y, PSX Digital, PSX Digital Fast, PSX Analog, PSX Analog Fast |
| SNAC Assignment | the six below |
| Analogizer H Position | -40 to +44 dots; + moves the picture right |
| Analogizer V Position | -17 to +11 lines; + moves the picture down |

With **Analogizer** off the core behaves exactly as it did without Analogizer
support. The adapter itself is set up as its wiki's
[How to use it](https://github.com/RndMnkIII/Analogizer/wiki/How-to-use-it%3F)
says: SNAC switch in position A, 5 V into its USB-C port, the SCART cable's
audio jack in the Pocket's headphone socket.

**Position.** The two sliders move the picture on the CRT, in the core's
own dots and lines, for a set whose picture sits off centre (the first one
tried, with Moo Mesa, showed it about 10 lines high). They move the syncs,
not the picture, so nothing is cropped and every mode follows; the size is
still the set's to adjust. 0 is the board's own timing.

**Video.** The fight screen, 256 x 224, at 6 MHz dots: 392 x 255 dots a
frame, 15.31 kHz lines and 60.02 Hz, the timing a 15 kHz arcade monitor or a
PVM expects. The core's own frame rate is kept (it is what the Pocket shows
too), so the picture reaches the CRT once per frame with nothing dropped or
doubled. The real board's dot clock is not modelled (MAME's 60 Hz for this
driver is itself a placeholder), so 6 MHz is this core's choice: an ordinary
arcade rate, the picture a little narrower than a TV's full width, as on
most 256-pixel boards.

| mode | SOG switch | notes |
|---|---|---|
| RGBS | off | VGA-to-SCART or VGA-to-BNC |
| RGsB | on | R2/R3 adapters only |
| YPbPr | on | R2/R3 adapters only |
| Y/C NTSC, Y/C PAL | off | needs an active Y/C adapter on the VGA port |
| SC 0% / 25% / 50% / 75% / HQ2x | off | scandoubled for a VGA monitor: twice the line rate |

"On, Pocket off" turns the Pocket's own picture black while the CRT keeps
the fight screen. "On, Pocket: top screen" shows the info screen alone on the
Pocket, at its own 256 x 224 in the Pocket's Screen Shape (Arcade or Fill),
while the CRT has the fight screen. "On" leaves the Pocket's picture as it
is without the adapter.

**Controllers.** SNAC pads (DB15, NES, SNES, PC Engine 2/6-button and
multitap, PlayStation) replace the Pocket's controls according to the
**SNAC Assignment** chosen in the menu:

| assignment | player 1 | player 2 | player 3 | player 4 |
|---|---|---|---|---|
| SNAC P1 → Pocket P1 | SNAC 1 | the Pocket's own controls | dock 3 | dock 4 |
| SNAC P1 → Pocket P2 | Pocket | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P1,P2 | SNAC 1 | SNAC 2 | dock 3 | dock 4 |
| SNAC P1,P2 → P2,P1 | SNAC 2 | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P3,P4 | Pocket | dock 2 | SNAC 1 | SNAC 2 |
| SNAC P1-P4 → P1-P4 | SNAC 1 | SNAC 2 | SNAC 3 | SNAC 4 |

Punch-Out!! is one player, so only the first two rows matter here. A pad's
buttons arrive as the Pocket's own (SNAC's A is the Pocket's A, and so on),
so they do what the core's controls table says: D-pad dodge/duck/block, Y
and X the jabs, B (or A) the KO punch, Select the coin. A PlayStation pad in
analog mode steers with its left stick.

**Cart power is on for everyone.** `core.json` declares the cartridge adapter,
so the Pocket powers the slot whether or not an Analogizer is in it. Do not
leave a game cartridge in the slot while this core runs.

**Not yet tried on an Analogizer.** What the benches prove is listed under
*What was measured* below. Send problems with the adapter itself to the
Analogizer project.

## For the developer

### The pieces

| file | what |
|---|---|
| `target/pocket/analogizer/` | RndMnkIII's `openFPGA_Pocket_Analogizer` 1.4 and what it instantiates, **verbatim**, copied from the pocket-core-template, which took it from RndMnkIII's MiraxPocket (`src/fpga/analogizer/`, commit 9dfdd2b9bec79fe5ea10e154a0613a0c9d4fe37f). Its `analogizer.qip` is ours: only what is used. |
| `target/pocket/pocket_analogizer.sv` | the wrapper: clock hand-over, Y/C constants, SNAC → controller words. Core-agnostic; the same file in the template. |
| `target/pocket/po_crt.sv` | the bottom monitor at its own timing: the fight screen's lines taken out of the Pocket raster into a 128-line ring and played out at 392 x 255 dots of 6 MHz, locked to the Pocket's frame (below) |
| `target/pocket/po_topscreen.sv` | "Pocket: top screen": DE narrowed to the info screen; `core_top` selects the 256 x 224 scaler slot (2 or 3, `video.json`) |
| `target/pocket/core_top.sv` | `USE_ANALOGIZER`, the instance (`LINE_LEN` 392, po_crt's line), `key1..key4` in place of `cont1..4_key`, the bridge read at `0xF7xxxxxx`, bit 16 of the menu word (top screen), the Pocket-screen blank, and the cart pins' idle levels when it is off. |
| `core_pll` `outclk_4` | the Analogizer's 48 MHz, `clk_sys / 2` in phase (was an unused 96 MHz output); already in the SDC's PLL group. |
| `pkg/.../interact.json` | the entries above: ids 70–73, each a masked field of the word at `0xF7000000`, and 74–75, signed sliders at `0xF7000004` and `0xF7000008`. Sixteen entries, Analogue's limit: Scanlines, Shadow Mask, Copyright Notice and Demo Sounds were taken out to make room (README) |
| `pkg/.../video.json` | scaler slots 2 and 3: the info screen alone, 256 x 224, Arcade and Fill |
| `pkg/.../core.json` | `"cartridge_adapter": 0` (powers the slot) |
| `sim/run_analogizer.sh` | the bench (below), at po_crt's raster |
| `sim/run_po_crt.sh` | po_crt dot by dot against the frame each line came from, and po_topscreen's DE |
| `tools/check_json.py` | fails if an entry writes outside its mask, none sets the enable, a position slider is not signed within ±127, a data slot also writes `0xF7000000`, or the slot is not powered |

### The settings word

One 32-bit word at `0xF7000000`, the layout RndMnkIII's adapter module (1.4)
decodes. Each menu entry is a list with a mask that keeps every bit but its
own field (or fields), so the four entries share the word. Bit 16 is this
core's own; the firmware writes the whole merged word every time, so
`core_top` takes it from any write to `0xF7000000`:

| bits | field | values |
|---|---|---|
| 4:0 | SNAC type | 0 none, 1 DB15, 2 NES, 3 SNES, 4 PCE 2-button, 5 PCE 6-button, 6 PCE multitap, 9 DB15 fast, 0xB SNES A/B↔X/Y, 0xC–0xF PS/2 keyboard (+ pad; not in the menu, the wrapper does not wire the keyboard out), 0x10/0x11 PSX digital (125/250 kHz), 0x12/0x13 PSX analog. 16 and up select the adapter's B wiring. |
| 5 | enable | 0: the port stays idle and nothing else applies |
| 9:6 | SNAC assignment | 0–5 as in the table above |
| 13:10 | video | 0 RGBS, 1 RGsB, 2 YPbPr, 3 Y/C NTSC, 4 Y/C PAL, 5–9 scandoubler 0/25/50/75%/HQ2x |
| 14 | blank the Pocket screen | |
| 15 | OSD on the Analogizer output | not used; no menu entry |
| 16 | the Pocket shows the top screen | this core's, read by `core_top` from the menu's writes (the adapter module does not decode bits 16-30); only with bit 5 |

**Read-back.** The word is written as a number (the adapter module is told
`bridge_endian_little = 1`, so it does not byte-swap it as it would a file),
and `pocket_analogizer` keeps its own copy to read back, combinationally.
The Pocket's bridge (`io_bridge_peripheral.sv`) samples read data four clocks
after it presents the address and pulses `bridge_rd` only afterwards; the
adapter module updates its read-back on that pulse, so it would hand back
the *previous* read's value. The firmware merges a masked entry by
reading the word back (Analogue's interact.json docs: every entry not
`writeonly` is read back every frame), so that stale value would wipe the
other fields: in the bench, choosing a video mode turned the Analogizer off. RndMnkIII's menu
cores (Gauntlet) read the word back the same way, from a register.

**Picture position.** Two more words, each a whole signed slider value
(no mask): `0xF7000004` horizontal in dots, + right, and `0xF7000008`
vertical in lines, + down. `pocket_analogizer` reads the low 8 bits and
reads both words back. The adapter module stores them in a table it never
reads (`config_mem`). They move the syncs, not the picture: hsync n dots
earlier puts the picture n dots right, vsync n lines earlier puts it n
lines down. Earlier is built as a line (or frame) less n later: each sync
is re-made from the source's own rising edge after a delay counted in
dots, as wide as the source's, with the line and frame measured from the
source's syncs; the vsync's delay is whole lines, so its edges keep their
place in the line. RGB and blanking go through one clock later with them,
and at 0 each sync passes straight through.

A re-made sync starts only once it has been off at least as long as it is
on. The adapter module's `sync_fix` decides each sync's polarity afresh
every period, by whether the signal was high longer than low. A jump
between settings in one write (one "large" slider step, or a value loaded
at start) can put the next pulse just after the last one ends, and that
period reads as active-low: csync turned inside out for a frame (a line,
for hsync). With the rule such a jump skips one pulse instead.

**The range comes from po_crt's blanking.** Hsync is dots 0..27 and the
picture 92..347 of 392. Moving right, hsync may come up to 44 dots earlier
before it meets the end of the picture; moving left, 40 later, which keeps
the Y/C colour burst (it ends about 3.5 µs, 21 dots, after hsync does)
clear of the picture. Vsync is lines 0..2 and the picture 20..243 of 255:
11 lines earlier, or 17 later, before it reaches a picture line.
`sim/run_analogizer.sh` tries both ends of the range in `interact.json`
and fails if csync is low while a dot is drawn; one step past each
(+45 dots, +12 and -18 lines) fails it.

### The bottom monitor at its own timing (po_crt)

`punchout_video` draws the two monitors one after the other into one
512 x 672 Pocket raster at 24 MHz, 560 x 714 dots, 42.8 kHz: the info screen
at 1x in rows 0..223, the fight screen at 2x in rows 224..671, each of its
224 source lines on two rows and each pixel on two dots. Its timing has
nothing in common with a CRT's, and its source lines are rendered one at a
time into a line buffer while the previous one is shown, so there is no
native-timing fight raster inside it to tap.

`po_crt` makes one. It takes each fight line out of the Pocket raster as it
is drawn -- the first row of each pair, every other dot, as the four bits
per gun the colour PROMs give (`{n,n}` in the 8-bit output, so nothing is
lost) -- into a ring of lines, and reads them out at 6 MHz dots, 392 x 255,
with real hsync, vsync and blanking and one pixel enable a dot. 392 x 255 x
16 clocks is exactly 560 x 714 x 4, the Pocket's frame, so the two rasters
stay locked: the native frame is restarted 422,000 clocks after every
Pocket vsync, which after the first frame is where it already is.

The Pocket draws a fight line every 4,480 clocks; the CRT shows one every
6,272. The CRT's line 0 cannot start before the Pocket has drawn it, so the
reader falls behind by 64 lines over the frame, plus the one being read: a
64-line ring is overrun by four lines (the bench fails it), and 128 lines --
256 dots x 12 bits, 48 M10K blocks -- is the next power of two. The CRT
finishes the frame's last line before the Pocket writes the next frame's
first fight line, so every line on the CRT comes from one Pocket frame,
shown about a third of a frame after the Pocket shows it. Starting the
native frame 4,000 clocks earlier puts lines from the previous frame on the
CRT (the bench fails that too).

The bring-up panel's squares and the core's inspector modes reach the CRT
as they reach the fight screen.

### The Pocket as the top monitor (po_topscreen)

With "On, Pocket: top screen" the Pocket raster is drawn exactly as always;
only DE is narrowed to the info screen (de rows 0..223, dots 128..383, where
`punchout_video` puts it at 1x), and `core_top` sends the scaler slot 2
(Arcade) or 3 (Fill) instead of 0 or 1. Those slots are 256 x 224, so the
scaler fills the display with the info screen alone. Scanlines and shadow
mask are gone from the menu, so nothing in the mixer depends on the raster's
shape.

**The file scheme, not used here.** The adapter module 1.4 was written for
`analogizer.bin`, a file Pupdate and AnalogizerConfigurator write to
`/Assets/analogizer/common/`, loaded through a data slot at the same address.
It needs a data slot naming the file, a second platform id `analogizer`
that the slot's parameters point at, and the file on the card before the
adapter does anything. A player who has never heard of the file has an
Analogizer that stays dark, so the template uses the menu. A data slot at
`0xF7000000` would load the file over the menu's word; `tools/check_json.py`
refuses one.

### Clocks

`openFPGA_Pocket_Analogizer` runs its logic on `i_clk`, puts `video_clk` on the
cartridge pin that clocks the ADV7123, and assumes that is `i_clk` too. The
scandoubler halves the pixel period, so the clock has to be at least four
times the dot rate. The shipped Analogizer cores use 42.95–48 MHz.
Punch-Out!!'s system clock is 96 MHz, which is more than the cart's level
translators have been asked to pass, so the PLL's spare output gives 48 MHz,
in phase with `clk_sys`, 8 of its clocks a 6 MHz dot. `po_crt` registers
each dot's colour, syncs and blanks together one clock before its enable,
and they hold for the whole dot, so `pocket_analogizer` takes them `PIX_LAG`
(2) system clocks after the enable into a holding register and hands them
over with a toggle. The Analogizer side picks the dot up two or three of
its clocks later, well inside the dot.

The Y/C encoder's subcarrier step and colour-burst window are computed in
integers from `CLK_HZ`. The reals used elsewhere lose the bits past 32 in some
tools, and MSX2's hand-typed NTSC step is a few counts off.

### Using SNAC in the game's inputs

`pocket_analogizer` outputs `key1..key4`, the Pocket's controller words with
SNAC pads put in place by the assignment. SNAC's bit order is the Pocket's
(0 up, 1 down, 2 left, 3 right, 4 A, 5 B, 6 X, 7 Y, 8 L1, 9 R1, … 14 select,
15 start). They feed the `gamepad` helper and the direct player-3/4 reads in
place of `cont1..4_key`. **Wherever a core reads `cont*_key` directly**
(players 3 and 4 often are), read `key*` instead, or SNAC will not reach it.

### What was measured

- `sim/run_po_crt.sh`:
  - po_crt fed the Pocket raster as punchout_video draws it, every fight
    pixel a colour naming its line, dot and Pocket frame: six frames, 392
    dots a line, 255 lines and 1,599,360 clocks a frame, hsync 28 dots,
    vsync 3 lines, and 329,661 visible dots each checked against the frame
    it belongs to, 0 differing. A 64-line ring fails it (2,076 dots from the
    wrong frame), and so does starting the native frame 4,000 clocks
    earlier (1,307).
  - po_topscreen: with it off, DE is the Pocket's own, 512 x 672 on every
    frame; on, exactly 256 dots on each of 224 lines, all inside the info
    screen; off again, the full raster back. Its window one dot to the left
    fails it.
- `sim/run_video.sh`: punchout_video is unchanged by this work, and its
  frozen-state gate still passes: 16 states captured afresh from MAME, both
  monitors, 0 differing pixels.
- `sim/run_analogizer.sh`: the wrapper and the vendored module at po_crt's
  raster and clocks (8 Analogizer clocks a dot), read at the cartridge pins
  as the DAC reads them.
  - With the menu at its defaults, every pin sits as on a core without the
    adapter, and the controller words pass through.
  - Every option of every Analogizer entry in the package's `interact.json`
    (33, with "On, Pocket: top screen"), set as the firmware sets a masked
    entry, read back the word as the
    bridge samples it, merged and written: the word, the adapter's copy and
    the enable each followed. With the adapter's own read-back in place of
    the wrapper's, the same run fails at the second entry.
  - RGBS: all 57,344 visible dots of a frame reach the DAC pins, in raster
    order, as their top six bits per channel, with 0 differing. Csync is one
    hsync-long (28-dot) pulse a line.
  - Scandoubler: 510 lines per frame (twice 255) at 1568 clocks, half the
    core's line.
  - YPbPr and Y/C NTSC/PAL: no unknown on any pin for a frame.
  - All six SNAC assignments, the analog stick, and type "none" map as
    tabled.
  - Position, at both ends of the shipped sliders (+44,+11 and -40,-17):
    read back as written, the settings word untouched; at the pins csync
    moves by exactly the dots (352 and 320 clocks) and lines (11 and 17)
    asked, the picture is still every dot with 0 differing, csync is never
    low while a dot is drawn, and the scandoubler's lines and period are
    unchanged; back at 0, csync is where it started. Jumps written just
    after a pulse that put the next right after it (V +11 to +7, H +44 to
    +15) leave csync out of the picture for three frames. One step past
    the range (+45 dots, +12 / -18 lines) fails.
  - The blank bit, and enable off again returning the port to idle.
- `sim/lint.sh`: po_crt, po_topscreen and the wrapper lint clean. The
  vendored files' warnings are dropped by path; their errors are not.
- `tools/check_json.py pkg/pocket --active 512x672,256x224`: clean (16
  entries, 49 options, 6,833 bytes; both raster sizes declared).
- Quartus 18.1: compiles; no negative slack at any corner. Before → after:
  7,522 → 9,579 ALMs (41 → 52%), 213 → 274 RAM blocks of 308 (the ring 48,
  the Analogizer 13), 14 → 16 DSP; worst setup +0.380 → +0.749 ns (slow
  0C, clk_sys); worst hold +0.074 → +0.031 ns (fast 0C, the SDRAM read
  capture, `dram_dq[1]` → `dq_in[1]`: thinner than before, still positive,
  so the SDRAM clock phase was left where hardware chose it). Every
  constraint in `punchout_pocket.sdc` applied; the only ignored ones are the
  platform's own `sys_constr.sdc` output delays on `dram_clk`, as before.

**Not proven:** anything on hardware -- the CRT picture, the Pocket's
switch to the 256 x 224 slot (the scaler accepting a raster whose DE covers
only the info screen), the firmware's handling of bit 16 and of signed
sliders -- and the SNAC serial protocols, which are
the adapter module's and are forced at its outputs in the bench rather than
driven over the pins. The Y/C and YPbPr encodings have no reference to compare
against, only a run without unknowns.

### On hardware, in this order

1. **"Analogizer: Off"** (the default), no adapter: the core must play
   exactly as before -- both screens, controls, records. If it does not,
   stop there.
2. **Analogizer On, Video RGBS, SNAC None**: the fight screen on the CRT,
   both screens still on the Pocket. A PVM's info screen should read
   15.3 kHz / 60.0 Hz. A picture that rolls or tears points at the sync;
   one with the wrong lines or a band from the previous frame points at
   po_crt's ring.
3. **"On, Pocket: top screen"**: the Pocket should show the info screen
   alone, filling the display (try both Screen Shapes), the CRT unchanged.
   A Pocket that keeps the stacked picture, or shows garbage, means the
   scaler did not take slot 2/3 -- say which.
4. **"On, Pocket off"**, then each other video mode (RGsB and YPbPr need
   the SOG switch on), then a SNAC pad, then the two position sliders
   (negative values too), then that the menu keeps all of it across a
   reload.

### Turning it off

Set `USE_ANALOGIZER = 0` in `core_top.sv` and take the six menu entries,
the two 256 x 224 scaler slots and `cartridge_adapter: 0` out of the JSON.
`general[4]` can stay in the SDC's PLL group: the PLL output is still
there, unused. po_crt is then unused and Quartus removes it.
