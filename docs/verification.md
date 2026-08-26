# Verification

What is checked, how, and what is not checked yet.

## Reference renderer (METHODOLOGY Phase 3) — PASSING

`tools/render_model.py` renders a frozen machine state and diffs it against
MAME's own screen bitmaps. Sixteen states, both monitors, **zero differing
pixels**.

```sh
python3 tools/mra_build.py punchout.mra mame-romset/   # -> punchout.rom
./tools/capture_states.sh                              # -> artifacts/
./tools/regress_ref.sh                                 # the gate
```

### Why the comparison is against `screen:pixels()`, not the snapshot

MAME's dual-screen snapshot goes through `layout_dualhovu`, which resamples the
bottom monitor: the first attempt reported 13,445 differing pixels that were
all near-miss colours like `(0,85,153) -> (0,75,143)`, and the same source
colour mapping to two different destinations gave it away as filtering rather
than a renderer bug. The top monitor was exact in the same image. `screen:pixels()`
returns the 256x224 bitmap itself, unfiltered, and against that the very first
run was already identical on both monitors.

`pixels()` returns three values — data, width, height — so it must be written
as `g:write((scr:pixels()))`. Without the extra parentheses Lua appends the
ASCII "256224" to the file.

### Why the state dump can be trusted

`punchout.cpp` never calls `update_partial`, so MAME draws each monitor once
from end-of-frame state. `tools/dumpstate.lua` copies the three video RAM
blocks into Lua tables and installs write taps that hand the saved byte back,
so the picture stops moving while the CPUs keep running. Two frames later it
re-reads all 8 KB and compares against the tables; the `drift` field in every
dump records the result, and it has been 0 on every capture. A tap that
silently never fired would otherwise leave the dump describing a frame MAME
never drew.

### State coverage

Frames were chosen from a 9000-frame scan of the big-sprite control registers,
not by eye:

| State | What it covers |
|---|---|
| 0003 | `zoom == 0` — big sprite #1 entirely disabled |
| 0040 | top monitor only (`ctrl[7] & 1`), and the largest zoom the game reaches (2040) |
| 0120 | big sprite #1 on **both** monitors at once |
| 0161 | the smallest zoom reached (192) — maximum magnification |
| 1100 | big sprite #1 flipped in x |
| 1800, 2400 | big sprite #2 flipped in x |
| 0900p1, 0900p3 | palette bank forced to 1 and 3 |
| rest | ordinary gameplay at assorted opponent distances |

The palette bank states are synthetic on purpose: the game left `dffd` at zero
for all 9000 scanned frames, so bank 1 is unreachable by playing and half the
colour PROM would otherwise never be read by any test. `PO_PALBANK` sets the
frozen byte and the RAM together, so MAME renders exactly what gets dumped.

## How much the game changes per frame — MEASURED

The core renders the top monitor into output rows 0..223 and the bottom into
224..671, so the two monitors sample video RAM at different points in the
output frame. On real hardware both monitors scan together, so that only
matters if the game writes video RAM outside vblank.

Measured two ways, because the first result looked too small to believe
(METHODOLOGY §5.1). Counting write taps said 11.8 writes per frame; reading the
whole 8 KB at the end of every frame and diffing against the previous frame --
no taps involved at all -- agreed:

| Region | bytes changed/frame, mean | peak | frames with any change |
|---|---|---|---|
| bg_top | 2.9 | 992 | 79 / 1198 |
| sprite control | 0.3 | 7 | 110 / 1198 |
| spr1 (opponent) | 0.5 | 292 | 2 / 1198 |
| spr2 (player) | 0.0 | 0 | 0 / 1198 |
| row scroll | 0.0 | 30 | 1 / 1198 |
| bg_bot | 7.0 | 1320 | 1030 / 1198 |

Peak is ~1300 bytes in one frame. At roughly five Z80 cycles per store that is
~6,500 cycles, and a 32-line vblank in a 256-line raster at 4 MHz is ~8,300 --
so even the worst frame fits inside vblank. MAME reaches the same conclusion
from the other direction: `punchout.cpp` renders both monitors once from
end-of-frame state and is rated "good".

Belt and braces anyway: the core latches the 16 sprite-control bytes, the
palette bank and the 64-byte row-scroll table at the start of each output
frame, so the two monitors can never disagree about sprite position, zoom or
palette even if a write does land mid-frame. Tilemap RAM is read live.

### A trap worth remembering

Nothing inside a MAME write-tap callback may call back into the machine.
`screen:vpos()` and `machine.time` both segfault MAME 0.288 from inside a tap.
Taps may only touch Lua state; anything that needs machine state has to be
measured from `register_frame_done` instead.

## RTL video against the reference renderer (Phase 4) — PASSING

`sim/run_video.sh` builds the video core with the real SDRAM controller and a
behavioural SDRAM, loads the ROM image once through the real loader path, then
renders every captured state and diffs it against `tools/povideo.py`. Sixteen
states, both monitors, **zero differing pixels**, and the fight screen is a
clean integer 2x in both axes.

The diff pulls the two monitors back out of the 512x672 composite rather than
comparing the composite directly, so it checks the compositor as well as the
renderers: the info screen must be at 1:1 in rows 0..223 columns 128..383, the
fight screen must survive a 2x2-block uniformity test before being downsampled,
and everything else in the top 224 rows must be black.

### Line budget (METHODOLOGY §5.2)

An output row is 2240 clocks at 96 MHz. Worst line measured across all states:

| State | Worst line | Of 2240 |
|---|---|---|
| 0003 (no big sprite) | 558 | 25% |
| 0040 (top monitor only) | 772 | 34% |
| 1400 (background + both big sprites) | 1388 | 62% |

Most of it is SDRAM latency: `sdram16` spends five cycles recovering after
every access, so a gfx3 tile row costs ~25 cycles for its two reads. That
budget is why the renderer clock is 96 MHz rather than 48 — at 48 a row is 1120
clocks and a three-layer line does not fit. The alternative was a prefetch
pipeline to hide the latency, which is exactly the Xenophobe sprite-engine
complexity this avoids. `dbg_line_overrun` is wired to the bench and fails the
run if any line ever runs past its row.

### Three bugs the bench caught, and what each looked like

1. **Video RAM address decode.** The three regions are 2 KB, 4 KB and 4 KB, so
   as offsets from 0xd800 they sit at 0x0000, 0x0800 and 0x1800 — not power of
   two aligned, and no bit slice decodes them. The first version sliced anyway,
   so the bottom tilemap landed in big sprite #2's memory, big sprite #2's in
   big sprite #1's, and big sprite #1's nowhere. On screen: the fight screen
   blank below line 112 and wrong-coloured above it. The module now takes the
   CPU address itself and decodes it with one comparison per region.

2. **Display pipeline off by one.** The line-buffer read and the PROM read are
   each registered, so the colour leaving the block belongs to the pixel whose
   sync and blanking are in stage 0 of the delay line, not stage 1. Being one
   pixel out costs nothing visible on a 1:1 monitor — the window test shifts
   with the data — but it breaks the fight screen's 2x doubling, because an odd
   shift makes columns 2k and 2k+1 land on different source pixels. The 2x2
   uniformity check is in the diff tool precisely because of this.

3. **A simulation-only tristate fault in the SDRAM controller.** Every big
   sprite pixel came out transparent because every gfx3 and gfx4 read returned
   0xFFFF. The contents were verifiably correct in the memory array, so the
   fault was in the read path. Isolating the controller and the model in a
   twelve-line testbench showed reads returning the *previous write's* byte,
   doubled — the controller was still driving the data bus. `sdram16` released
   it by assigning `16'bZ` to an `inout reg` from inside its clocked block, and
   Verilator's procedural-tristate handling keeps the enable asserted from the
   last non-Z assignment. Rewritten as an explicit `dq_oe`/`dq_out` pair with a
   continuous assign — the same registered tristate after synthesis, and the
   form that simulates. The hardware was never wrong, only the simulation of it.

The bench now verifies the SDRAM twice before rendering anything: once against
the memory array, and once by reading a spread of words back through the
controller. A renderer fault and a memory fault look identical on screen.

## Not yet checked
* **RTL sprite-engine line budget** (METHODOLOGY §5.2) — the bench must report
  worst-case cycles per line, not just pixel equality.
* **Audio against MAME.** The sound board is built and its rates are exact, but
  nothing has been measured yet. What is already established:

  * The 2A03's tempo comes from its own crystal, not from CPU throughput, so
    METHODOLOGY §5.3 does not bite. The enable is a 32-bit phase accumulator off
    the 96 MHz system clock, exact to under a part per million.
  * §5.4 does apply and is handled: the sample crosses into `clk_74b` through a
    toggle-flag handshake in `core_top.sv`, after being decimated to 48.000 kHz
    (96 MHz / 2000) by a tick-aligned box average and two cascaded two-point
    averages.
  * The APU mixer is **unipolar** — its output is the sum of two positive lookup
    tables — and the Pocket's audio path is two's complement, so a DC blocker
    stands in for the board's coupling capacitor. Handing the raw value over
    would put a large DC step through the filter chain. METHODOLOGY §5.1's
    warning about signedness in the *harness* applies here in the RTL.

  The bench to build is the one from METHODOLOGY §4: send the same sound command
  in both, record with `-wavwrite`, and compare peak, RMS and per-band energy.

* **No DMC sample playback — established statically.** The 8 KB sound ROM
  contains no absolute reference to `$4010`, `$4012`, `$4013` or `$4014`, found
  by scanning it for 3-byte opcodes with an operand in `4000-4017`. So the DMC
  never requests a DMA and the sound CPU's bus is never stolen. This was checked
  in the ROM rather than in MAME on purpose: MAME's RP2A03 services its own APU
  registers internally, and a write tap on the audio CPU's program space sees
  almost none of them — the first attempt reported 143 writes to `$4017` and
  none at all to `$4002`, which is not a machine that plays music.
  `dbg_dma_req` is brought out of the core in case the assumption is ever
  wrong.
* **VLM5030 speech.** Deferred to last, by decision.
