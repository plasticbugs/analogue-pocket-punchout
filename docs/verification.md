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

## Full system against MAME (Phase 5) — PASSING

`sim/run_system.sh` boots the whole machine from reset -- Z80, memory map, I/O,
the LS259, the vblank NMI -- runs attract mode with no input at all, and diffs
the frames it produces against MAME's own bitmaps for the same frame numbers.
Attract mode is deterministic from reset in both, so the comparison is fair.

```sh
./tools/capture_attract.sh                    # MAME references, no input
ROM=build/punchout.rom ./sim/run_system.sh    # boot and compare
```

The 6502 half of the sound board is T65, which is VHDL and invisible to
Verilator, so `sim/t65_stub.sv` stands in and the sound CPU sits idle. Nothing
on the main board waits on it.

### The bug this found that nothing else could

Frame 60 came out 511 pixels different on **both** monitors, with identical
counts — and identical counts on two independently rendered screens points at
the one thing they share, the big sprite. Everything else matched exactly.

The chain of elimination, each step a measurement rather than a theory:

1. Was it a frame offset? No: MAME's frames 40 through 80 are pixel-identical
   to each other, so there is no phase to be wrong about.
2. Were the sprite control registers stale? No: dumped from the running machine,
   `dff0-dffd` matched MAME's byte for byte.
3. Was the sprite's video RAM wrong? No: all 2048 bytes matched MAME's.
4. Did the renderer disagree given that exact state? No: the reference renderer
   and the frozen-state RTL bench both render `state_0060` with zero differing
   pixels.

That leaves what the frozen bench does not exercise — the path the graphics take
into SDRAM. The frozen bench loads them directly; the real core queues them
through a write FIFO, because the APF loader has no back-pressure and a write
posted while the SDRAM is busy would be lost. The queue was 64 entries, the
bench was feeding a byte every four clocks, and an SDRAM write costs about
twelve: it overflowed within the first hundred bytes and dropped graphics data
silently.

Fixed on both sides. The queue is 256 entries, which is far more than the bridge
can deliver between two writes, and overflow is now latched into
`dbg_load_overflow` and fails the run rather than corrupting the picture
invisibly. The bench feeds at one byte per sixteen clocks, which is already
generous next to an SPI link. Both benches now verify the SDRAM contents before
rendering anything.

### The one difference that is not a bug

With the loader fixed, three of the five frames are pixel-identical to MAME.
The other two are pixel-identical to MAME's **previous** frame — not close to
it, exactly it, zero differing pixels — and only while the big sprite is
animating.

That is a difference in when the sprite's geometry is sampled, not in how it is
drawn:

* MAME calls `screen_update` once, at the end of a frame's visible area, and
  draws the whole frame from the register values at that instant.
* This core draws the frame a line at a time as the beam moves, so it has to
  take one snapshot and hold it. It takes it near the end of vertical blanking,
  which is as late as it can be and still be ready for line 0.

Measured: the game writes `dff0-dff7` at raster rows **1 through 713** — all
over the frame, active display included. So no snapshot point inside blanking
can be as current as MAME's end-of-frame one, and on an animated frame the two
models differ by exactly one frame.

Neither is what the board does. The real video hardware reads those registers
as the beam scans, so a mid-frame write takes effect mid-frame; MAME's
end-of-frame snapshot and this core's start-of-frame snapshot are two different
approximations of that, one late and one early. Matching MAME exactly would mean
rendering a frame behind into a framebuffer, which buys agreement with an
approximation at the cost of a frame of latency in a reaction game.

`sim/run_system.sh` therefore compares each captured frame against MAME's frame
*N* and frame *N-1* and passes if either is identical, and says which.

### The tilemap snapshot

The tilemaps and sprite RAM are snapshotted the same way: the CPU writes a live
copy, and near the end of vertical blanking (back-porch row 17, two rows before
line 0 is rendered) a copier walks all 2048 entries into a shadow copy that the
renderer alone reads. A write the CPU makes during the walk is also written
into the shadow three clocks later, after the copier's own write of that entry,
so the shadow always ends the walk holding the newest value. The system bench
checks this: after every walk it compares each shadow array with its live one
(`snapshot walks 151: ... 39 writes, 39 written through; 151 shadows checked
against live, 0 mismatched`).

The first version snapshotted at the *start* of blanking and held the NMI back
until the copy was done. Every frozen state still matched, but the animated
attract frame came out identical to MAME's frame **148** instead of 149: a clean
picture, one frame late, because the handler's writes for a frame were not drawn
until the next one. The bench's *N* / *N-1* rule caught it. Snapshotting after
the handler has run restored the phase the live design had, at no latency cost.

## Synthesis and timing — CLOSED

`./build-local.sh map` (Quartus 18.1 in Docker) runs analysis and synthesis in
about a minute and is the check to run before every push; a broken push costs a
whole CI cycle.

| | |
|---|---|
| Errors | 0 |
| Logic (ALMs) | 4,637 of 18,480 (25%) |
| Registers | 5,927 |
| Block memory bits | 879,841 of 3,153,920 (28%) |
| RAM blocks | 121 of 308 (39%) |
| DSP blocks | 13 of 66 (20%) |
| Worst setup slack, 96 MHz | **+0.844 ns** |
| Worst hold slack | +0.287 ns |
| Negative slack, any corner | none |

### Two things it caught that simulation could not

**The wrong T65.** The copy in `modules/cpu-t65` was NES_MiSTer's, which needs a
VHDL savestate package this core does not have. Verilator never noticed, because
it cannot read the file at all and a stub stands in for it. Replaced with
MiSTer's VIC20 copy, which carries no savestate bus.

**Five memories built out of flip-flops** (METHODOLOGY §5.5, the same category as
the byte-enable trap). Quartus reported each as "uninferred due to asynchronous
read logic":

* the two line buffers, because the write and the enabled read were in separate
  always blocks — 4096 flip-flops for 512 bytes;
* the work RAM, the NVRAM and the sound RAM, because they used the true
  dual-port template with the second port tied off, so Quartus saw a port whose
  output went nowhere and gave up on the whole array.

`po_ram.sv` gained the two templates that were missing: `po_spram` for a single
CPU bus port, and `po_spram_re` for a write port with an enabled read. Registers
fell from 9,677 to 5,546 and the block memory bits rose by exactly the 4,096
the line buffers should always have been.

Both regressions were re-run afterwards and still pass: sixteen frozen states at
zero differing pixels, and attract mode identical to MAME frame for frame.

### Closing timing: -6.107 ns to +0.844 ns

The first fit missed by 6.1 ns with -273 ns of total negative slack. Rather than
guess, `projects/report_worst.tcl` was pointed at the timing database, and all
400 worst paths turned out to be one path group: the APU's noise channel through
its mixer into the DC blocker, 25.7 ns end to end.

The delay split at about 18 ns inside the APU's own mixer and 7.7 ns in the DC
blocker's carry chain, which decided the two fixes:

* **The DC blocker** was three chained 26-bit adds in one cycle. Split into two
  stages -- the difference, then the recursion -- which is the same filter with
  one extra sample of delay, and at 1.79 MHz that is nothing.
* **The APU's mixer** is 18 ns because NES_MiSTer clocks it at 21.477 MHz, where
  it has 46 ns. It cannot be made to close at 96 MHz, and it does not need to:
  the only thing that samples it updates once per 2A03 cycle, about 54 system
  clocks. Every register inside the APU was checked to be enable-gated at an APU
  rate before the multicycle went in -- the one exception, `phi2_old`, is driven
  from outside the APU and so is not covered by it.

That left two paths of this core's own making, each missing by half a
nanosecond, and each a long combinational chain feeding a register in the same
cycle it was computed:

* the row-scroll lookup, a 32-entry mux hanging off the raster counter through
  `act_y`, `next_row`, `next_line` and a shift — moved into a renderer state of
  its own, where it starts from a registered line number instead;
* the sprite Y, a 32-bit multiply wired straight into the condition that picks
  the next renderer state — now registered, which costs nothing because
  `rend_line` is stable for the whole row and the value is read hundreds of
  clocks later.

### The constraints file was being read too early

Every `get_clocks` in `punchout_pocket.sdc` matched nothing, and the entire
`set_clock_groups` was silently ignored: Quartus reads SDC files in the order
they are listed, and the Pocket BSP's `sys_constr.sdc` is what creates
`clk_74a`, `clk_74b` and the PLL outputs. It is now listed after the BSP's.

This matters beyond tidiness. The BSP puts each PLL output in its own
asynchronous group, which **cuts** the clk_sys to clk_vid crossing rather than
analysing it — and that crossing is the video output. Cutting it would let each
build route it blind and make the picture depend on the fitter seed.

## First hardware report: backgrounds perfect, sprites garbage

The first bitstream ran on a Pocket. Game logic, music and every background
tile were right; every sprite tile was garbage. Backgrounds come from block
RAM and sprites from SDRAM, so the report named the subsystem and nothing more
-- and the SDRAM path had passed every simulation. Two independent faults were
found, both of a kind no behavioural model would show.

### 1. The loader queued every byte four times

The APF data loader holds its write strobe high for `DIO_HOLD` = 4 clocks, and
the core's SDRAM write queue enqueued on level rather than on edge: four
entries per byte. `data_loader.sv` says the bridge delivers a 32-bit word every
~75 clocks of 74 MHz, so that was 16 entries per word arriving against about 8
the SDRAM could retire in the same time. The 256-entry queue overflowed a few
hundred bytes into the graphics and dropped everything after. Block RAM never
noticed, because rewriting the same byte four times is harmless -- which is
exactly why the backgrounds were perfect and the program ran.

Verilator never saw it because both benches feed bytes with a one-clock strobe.
Fixed by enqueuing on the strobe's rising edge, and the system bench now feeds
at the loader's real cadence.

### 2. The read capture had half the time it needed, and the SDC hid it

`sdram16` came from the Xenophobe core, where it clocked the chip on an
*inverted* copy of the 40 MHz system clock and captured read data on the first
internal edge after the chip's. That gives the chip's access time half a
period: 12.5 ns at 40 MHz, comfortable; **5.2 ns at 96 MHz**, against a
datasheet tAC of 6.5 ns. It cannot work, and it did not.

It passed timing because the SDC carried a `-setup 2` multicycle on the
`dram_dq` inputs -- an exception that moved the checked edge a full period
later than the RTL actually captured. Measured by deleting the exception and
re-running STA on the same fit: **every `dram_dq` input missed by 7.5 ns**.
That is the number the first build was hiding. The SNES Pocket core uses the
same inverted-clock arrangement at 85.9 MHz with the pins left unconstrained
and survives on the gap between datasheet maximum and typical silicon; ten
more MHz took that away.

The fix is geometry, derived from STA's own numbers on a real fit rather than
assumed:

| Term | Measured |
|---|---|
| clock network, PLL → `dram_clk` pin | 12.56 ns |
| clock network, PLL → `dq_in` register | 7.9 ns |
| `dram_dq` pin → `dq_in` | 2.84 ns |
| chip tAC max + board | 7.0 ns |
| chip tOH min | 2.5 ns |

The chip is now clocked from a fourth PLL output, phase-shifted so its edge at
the pin lands ~2.1 ns before the controller's internal edge; read data is
captured one edge later than before (READ+4 at the pins); and the multicycle is
back, but this time it is *the* relationship -- the pin's clock network is
4.66 ns longer than the register's, so the physical capture spans two nominal
periods and the analyser's default pairing checks an edge the data can never
meet. `projects/punchout_pocket.sdc` walks through every transfer's setup and
hold with those numbers. Getting from there to a build that closes took three
more fits, each of which taught something the previous one could not:

* **The fitter was tuning the data pins' input delay chains per pin, per
  build** -- 1 unit on one `dram_dq`, 10 on another -- to buy hold, and the
  pin-to-register delay moved from 2.84 ns to 5.6 ns between two compiles of
  the same RTL. CI reproduced the same -0.193 ns exactly, so it was
  deterministic, not random: the fitter's response to the hold constraint.
  `D1_DELAY 0` / `D3_DELAY 0` on `dram_dq[*]` pin it. (The first attempt used
  `PAD_TO_INPUT_REGISTER_DELAY`, which is not the Cyclone V name and did
  nothing; the fit report's Delay Chain Summary names the columns.)
* **A `-hold 1` that first accompanied the multicycle reported +11 ns and was
  wrong.** It moved the check to the edge coincident with the launch, which
  cannot fail; the real hazard is the next word arriving before this capture,
  which is the analyser's default hold edge for a `-setup 2` path.
* **The slow corner alone was flattering.** With the phase centred there
  (+1.67 / +1.68), the fast corner gave -1.03 of hold. The launch path -- clock
  out through the DDIO cell and output buffer, across the chip and back -- has
  about 4.7 ns more process- and temperature-dependent delay than the capture
  clock, and STA's corners assume they diverge together. Across all four
  corners the read-capture window is **0.64 ns** wide.

The phase is set to the middle of that multi-corner window, 5859 ps (45 steps
of the 960 MHz VCO's 130.208 ps quantum -- 4550 was rejected as illegal for
not being one). Final numbers, no exceptions beyond the one derived multicycle:

| Path | Slow corner | Fast corner |
|---|---|---|
| chip → `dq_in` (read capture) setup | **+0.37 ns** | +4.41 ns |
| chip → `dq_in` (read capture) hold | +2.98 ns | **+0.28 ns** |
| controller → command/address/data pins, setup | +3.06 ns | +3.52 ns |
| controller → pins, hold | +2.97 ns | +3.55 ns |
| whole design, worst of any corner | setup +0.37 | hold +0.10 |

Both were predicted to the second decimal from the previous fit's numbers
before this one ran. Typical silicon sits ~1.6 ns from either edge of the
window; every other ~100 MHz SDRAM core on this platform gets there by leaving
the pins unconstrained and never asking.

The behavioural SDRAM model gained a `PHASE_LAG`
parameter so it presents data where an in-phase chip would; against it, the
old capture point reads zeros -- the bench now reproduces the hardware failure
-- and the new one reads correctly. Both regressions pass through the new path.

### 3. The platform glue held the core in reset for the whole download

Second hardware report, with the overlay on: squares 0, 4 and 6 green, 3 red --
queue never overflowed, chip reads and writes correctly, ROM data not in the
chip. Flipping the read timing to its alternate left 4 green and 3 red, so it
was not the capture point either. Only one thing fits all of that and the
first report as well: the graphics never got written.

`core_top.sv` was inherited from Time Pilot '84, where the core is held in
reset for the entire download (`po_reset = reset_sw | ioctl_download | ...`).
Harmless there -- every ROM is block RAM, which takes the loader's writes
regardless. Here the reset also held the SDRAM write queue and the controller
behind it, for exactly as long as the bytes were arriving. The block RAMs still
filled, so backgrounds were perfect; the SDRAM held whatever it powered up
with, so sprites were garbage -- in the first build regardless of the capture
timing, which was a real fault of its own but not the one on screen.

Faults 1 and 2 above were real and are fixed, but this is the one that was
showing -- half of it: see 4. The lesson is about the benches: they stop at `punchout_core`, so a
single line of glue in `core_top` sat outside every one of them. The core now
owns its own reset during a load; `core_top`'s reset is just the menu action
and the PLL lock.

On the alternate capture point staying green: this chip at room temperature
beats its datasheet access time by enough that the old, marginal capture
happens to work. That is the datasheet-versus-typical gap the SNES core lives
on; the normal setting is the one with analysed margin.

### 4. ...and the host's own reset held it there too

Third report, after fault 3 was fixed: identical -- 0, 4, 6 green, 3 red,
sprites unchanged. `reset_sw` from the platform's `interact` module is
`~(reset_n && core_reset_s)`: the menu action **and** the APF host's `reset_n`,
which the platform header describes as "driven by host commands, can be used as
core-wide reset". The Pocket's boot sequence holds that line low for the whole
data-slot download and releases it afterwards. Removing `ioctl_download` from
the reset equation had changed nothing on the panel, because the same reset
arrived by a second path for exactly the same interval.

`punchout_core` now takes two resets: `hw_reset`, the PLL not being locked,
which resets everything; and `reset`, from host or menu, which stops the
machine and touches nothing on the load path -- queue, SDRAM controller,
checksum, self-test. The system bench holds `reset` asserted through the
entire download and releases it after, as the host does. Both benches had been
feeding a clean burst with reset low, which is why a fault that took every
sprite twice over never once showed in simulation; it will now.

Fourth report: all seven squares green, and the game plays.

### 5. A flashing black bar when the opponent comes in close -- OPEN

With the game playing, one artefact: after a knock-down, as the opponent zooms
in to gloat, a solid black bar flashes at the left of the fight screen. It
persists on the snapshot design, so it is not the CPU tearing a frame.

What has been established, in order:

* **Where it is.** Measured against the canvas edge in a photograph of the
  panel: fight-screen lines 143-166, x 0 to about 89. That is background tile
  rows 20-22 (lines 144-167) exactly, and at those rows' scroll of 191 the
  right edge x = 89 is exactly the boundary of tile column 35. The opponent's
  footprint on those lines starts at x = 14 and its tile grid (16 px at that
  zoom, offset 14) does not line up with either edge. So the bar is background
  cells: rows 20-22, columns 23-34.
* **What is in those cells.** Tile 0x3ff, attribute 0x07: the canvas tile
  (every pen 3) in colour 1, whose four pens are white, blue, navy and tan.
  Nothing in it can render black. The same tile and attribute fill the whole
  canvas around them; nothing in the tilemap distinguishes the twelve cells.
* **The state is static while it flashes.** A MAME write tap over frames
  7800-8300 of the losing fight shows the sprite RAM, control block, scroll
  table and those tilemap rows unchanged from frame 8189 (when the Game Over
  box is built into sprite 2's tilemap, rows 29-31) to 8285 (the wipe to the
  credit screen). The only video RAM traffic in between is the game's scratch
  use of tilemap row 31 and a 2x2 animation at row 19-20 columns 9-10. Every
  frozen state through the sequence -- 29 of the gloat, 7 of this window, 7
  of the credit-screen slide -- renders pixel-exact in the reference and in
  the RTL.
* **The Game Over box is sprite 2**, not a tilemap: the player's big sprite
  is reused for it once the player is down. It sits at lines 163-186, x
  89-176, hidden behind the opponent when he is in close.

A black pixel on the fight palette is index 0-3 (colour 0, all four pens) or
36, 37, 39, 44. For those cells to come out black the background pass must
have written colour 0 -- or the entry was never written, or it was overwritten
by a sprite pass with colour 0 -- and only on the hardware, only some frames,
from a state that does not change. That is a dynamic hardware effect the
simulator has no model of: block-RAM read behaviour, a timing-marginal path,
or SDRAM traffic interacting with the line budget.

So the next step is to make the hardware say which. The **Black probe**
overlay mode (below) tags every line-buffer entry with the pass that wrote it
and the raw attribute byte that pass fetched, and latches the tag of the first
colour-0 pixel displayed inside that window, freezing the CPUs at that instant.
The tag partitions the fault: background pass with attribute 0x00 means the
tilemap read returned the wrong entry; background pass with 0x07 means the
fetch was right and the fault is between it and the display; a sprite pass
means a sprite wrote black where it should have been transparent. Whether the
bar survives the freeze says whether it needs the CPUs moving.

The first attempt at this fault, recorded here for honesty, assumed the sprite
control block was being torn between frames and moved the latch to the start
of every line; the second built the vblank snapshot. Both were sound changes
-- the snapshot is the right design and the bench caught a real frame of lag
in its first version -- but neither was the bar, because the bar was never
measured until the photograph.

### The overlay, and why the next report will be specific

METHODOLOGY §4 says to add the diagnostic overlay before it is needed; it was
needed before it existed. It is in now: eight squares in the bottom rows of the
fight screen, behind **Diagnostics Overlay** in the Pocket menu:

**Status** (the boot-time picture):

| Square | Meaning | Green | Red | Yellow |
|---|---|---|---|---|
| 0 | loader queue overflowed | never | yes | — |
| 1 | a video line overran its row | never | yes | — |
| 2 | the DMC asked for a DMA (unserviced) | never | yes | — |
| 3 | SDRAM self-test: ROM readback matches the loader's checksum | pass | fail | running |
| 4 | SDRAM self-test: pattern written and read back | pass | fail | running |
| 5 | SDRAM read timing setting | normal | — | alternate |
| 6 | SDRAM controller initialised | yes | — | no |
| 7 | unused | — | — | grey |

**Faults** (sticky; the first one freezes the CPUs so the frame stays up):
0 line overran its row, 1 the overrun was still in the background pass,
2 sprite geometry took more than 700 clocks, 3 one SDRAM read took more than
96 clocks, 4 loader queue overflowed, 5 black probe hit, 6 ROM readback,
7 pattern test.

**Black probe** (freezes the CPUs on the hit): the first pixel that leaves
the core black inside fight lines 136-171, x < 120. Lower row: square 0 is
the pass that wrote it -- green background, red sprite 1, yellow sprite 2 --
and squares 1-7 are bits 1-7 of the attribute byte that pass used, red for 1:
bits 2-6 the colour, bit 7 the x flip. For the canvas the expected byte is
0x07: squares 1 and 2 red, the rest green. Upper row: the pixel's palette
index, bit 0 at the left, red for 1. All grey until a hit. That is page 0 of
**Probe Page**, all of the pixel under the crosshair; page 1 is its x
(upper; on the info screen, info x = 2 x value - 128) and line (lower); page
2 the tile code byte the pass fetched (upper) and bits 7-0 of the tilemap
address it read (lower); page 3, only while the CPUs are frozen, is the same
cell read through the CPU's port of the live RAM: code byte (upper) and
attribute byte (lower).
**Video Path** offers the palette (normal), the raw index (R from bits 7-5, G
from 4-2, B from 1-0: the canvas is blue), the writer tag (green background,
red sprite 1, yellow sprite 2) and index 7 in white with the rest raw.

**First hit on the bar** (v0.1.0-alpha.1, reported from the panel): lower
row `G RR GGGGG`, upper row `RRR GGGGG`. That is: written by the
**background pass**, attribute **0x07**, palette index **7** -- the tan
canvas entry, the correct value in every respect -- and the colour that left
the PROM stage for it was black. The canvas beside the bar on the same lines
is the same index 7 and renders tan. So three separate PROM RAMs answered a
correct address with 0xF, transiently, on the hardware only. The probe now
also records where the hit was, the six PROM nibbles, the bank bits and the
line-buffer select, selectable by **Probe Page**; **Video Path: Raw index**
bypasses the PROMs and paints the index itself (the canvas comes out blue),
which shows the bar's true line-buffer contents with no probe in the loop.

**Second hit** (build f35bca5, pages read from the panel; the record in that
build was one bit short and every field shifted by one, undone here): the hit
is at fight **x 0, line 144** -- the bar's top-left corner, and line 144 is
the first line of tile row 20. Index 7, attribute 0x07, background pass, bank
0, fight screen, and the three fight PROM nibbles all **0xF**. The live count
was 9664 raster pixels black in the window per frame, about 24 lines by 100:
**the bar is redrawn every frame from a frozen, static state**, so it is
deterministic in the render or display path. In **Raw index** mode the bar
region shows as a *lighter* blue than the canvas -- an index with higher
green bits than 7 -- which does not agree with the probe's index 7 unless the
bar's first pixel differs from the rest. The bar is 88 wide and 24 tall,
which is exactly the Game Over box (11 by 3 tiles of sprite 2), whose black
tiles are index 55: light blue in raw mode. Next build: a video mode that
paints each pixel by the pass that wrote it, and live black-pixel counts per
writer.

**Third round** (build d4bc189): in the writer-tag view the bar is **green --
written by the background pass**, and no sprite-2 box is drawn at its
position (the yellow box appears only at the end, over the real Game Over
box). In the index-7-white view the bar is light blue: **not the canvas
index**, and the per-writer counts agree -- 150 x 64 black pixels per frame
from the background pass, none from either sprite, and **zero whose index
was 7**. The earlier "index 7" first-hit record came from a build whose
record was mis-packed and is discarded. So the background pass drew those
cells with a wrong colour: for a background pixel to be black and light blue
in raw view it is pen 3 of colour 11, 12, 13, 28, 29, 30 or 31. The canvas
cell's attribute is 0x07; reading it as **0xFF** -- the cell's own code byte
-- gives colour 31, pen 3, index 127: black, raw (96,224,192). The panel
also shows the info screen's **VS** graphic flashing in unison with the bar,
and MAME's game writes nothing to the top tilemap through frames 7800-8300
(`tools/writetap.lua` over d800-dfef), so that flash is the same fault at a
second place. Next build: the tag carries the code byte and the tilemap
address the pass used, and two counters of CPU writes MAME never makes here
(bottom rows 21-22, the top tilemap), to tell a wrong read from a diverged
game.

**Fourth round** (build b2ded16): first hit again at x 0, line 144, index 7,
attribute 0x07, background pass; the code byte read **0x92** and the tilemap
address **1**, which matches no cell of either map, so that tag entry is
either stale or one square was misread -- the limit of reading single bits
off a first-hit latch. The CPU-write counters were **0 and 0**: the Pocket's
game makes no writes MAME's does not, so the game has not diverged and is
not drawing the bar. The VS on the info screen: MAME shows it **green with a
purple shadow, unchanged on every consecutive frame** 7900-7915, 8000-8007
and 8264-8279 (odd frames included -- every earlier capture was an even
frame), and never a bar. On the Pocket it alternates green / yellow-orange,
and the bar is present exactly while it is yellow. Yellow-orange is colour
9's pens in the top PROMs; the VS tiles carry colour 6. And the canvas
index, 7, looked up in the *top* monitor's PROMs, is black. Two monitors,
two wrong colours, both consistent with the wrong PROM set or the wrong
colour for the right tile -- and the bar is only part of its rows, so
whatever it is acts per cell, not per frame.

The bit-reading probe is replaced by an **inspector**: the hit freezes the
CPUs and parks a crosshair on the hit pixel; the D-pad then moves it (KO
button held: 8-pixel steps) and the pages show the record of whatever pixel
it is on, refreshed every frame -- so the bar, the canvas beside it and the
VS letters can each be read exactly.

**Fifth round** (build 6fdf899, the inspector), four spots read while
frozen on the bar, every field self-consistent:

| spot | index | writer | attr | code | map address | PROM |
|---|---|---|---|---|---|---|
| bar, x 44 line 154 | 47 (colour 11 pen 3) | bg | **0x2C** | 0xFF | bottom row 21 col 22 | F F F black |
| canvas below, row 23 | 7 (colour 1 pen 3) | bg | 0x07 | 0xFF | bottom row 23 col 22 | 2 5 9 tan |
| VS letter (yellow) | 38 (colour 9 pen 2) | bg | **0x24** | 0xCB | top row 18 col 17 | 0 0 F yellow |

The VS cell is the right cell -- tile 0xCB does live at (18,17) -- with the
right code byte and the wrong attribute: 0x24 (colour 9) for 0x18 (colour
6). The bar cell is the canvas tile with the wrong attribute: 0x2C (colour
11) for 0x07. Neither wrong value exists anywhere in that map. **The code
lane reads right and the attribute lane reads wrong**, in both maps, in
cells the CPU has not written (the divergence counters were zero), from a
state that is static while frozen. The timing report puts every one of the
40 tightest paths in the SDRAM controller (worst +0.36 ns); nothing in the
tilemap path is near the edge, and the RAMs are inferred as written
(bidirectional dual port, OLD_DATA on mixed ports). So the next build
bisects on the hardware: a **Render Test** menu that makes the background
pass read the live RAMs directly with the copier stopped, and one that
disables the sprite passes.

(The x-0 pixel of a line gives unstable readings -- code 0x92 / address 1
once, address 0x30 the next time -- and is set aside; the readings above
are from ordinary pixels. Spots A and B also put column 22 at x 44, i.e. a
row scroll of 133 rather than MAME's 191 at the equivalent moment; the game
does move the scroll during a fight, so that may simply be the state the
Pocket's game was in, and the crosshair on a ring post will say.)

**Sixth round** (build 7e3e11c, Render Test): sprites off -- the bar spans
nearly the whole canvas width, so it is the full rows and is normally hidden
behind the opponent; background from live RAM with the copier stopped -- the
bar is still there, so the snapshot copier and shadow RAMs are exonerated:
the wrong attribute comes out of the CPU's own tilemap RAM. Both tests on --
no bar, VS still blinking; but stopping the copier also stops the row-scroll
latch, so the ring showed a stale scroll and the bad columns were simply out
of view. The bar is **locked to the canvas and scrolls with it**: a fixed
set of cells, rows 20-22 from the canvas's left edge rightward. When fully
exposed it carries the bottom halves of two **red digits** at its top-left.
Attribute 0x2C is colour 11 -- black, black, red, black -- the credit
screen's text colour, which the game writes in bulk at the wipe. And the
"scratch row" is the Z80's stack: bytes 0xFFDE-0xFFFF, the tail of this
RAM, pushed to every frame. The ring post read at x 5 is at map column 17,
where MAME's is column 54 at the equivalent moment.

Black cells with red digits in the ring is what stale or misdirected
*writes* look like, not a read error -- but the write counters saw none by
intended address, and the cells change state while the CPUs are frozen.
The seventh build reads the crosshair cell through **both ports** of the
live RAM -- the renderer's and, while frozen, the CPU's -- which tells wrong
content from a wrong read directly.

The first probe tested the palette index for 0-3 (colour 0). It fired on the
credit screen's black tiles, as it should, and **not on the bar** -- so the
bar is not colour 0. The fight palette has 49 black entries in bank 0 --
0-3, 36, 37, 39, 44, 45, 47, 49, 51, 53, 55, 65, 67-69, 72, 73, and pen 3 of
nearly every colour from 25 up -- so an index test cannot cover them. The
probe now tests the colour itself, and reports the index.

The two self-tests run with the machine held in reset after every load and
reset, and again whenever **SDRAM Read Timing** is changed from the menu. They
split the fault space: PATTERN never touches the loader, so PATTERN red means
the chip cannot be read or written at this clock and phase whatever the loader
did; ROM red with PATTERN green means the loader. The timing setting exists so
the capture point can be flipped on the panel without a rebuild; its alternate
is the old READ+3 and is expected to turn square 4 red.

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

  What a MAME recording of 66 seconds of play already shows, and what it means
  for the core:

  | Channel | Mean | AC RMS | Range |
  |---|---|---|---|
  | left — VLM5030 speech | 15 | 530 | -9947 .. 10546 |
  | right — 2A03 | **3760** | 1451 | -206 .. 10333 |

  * The 2A03's DC offset is real and large — a tenth of full scale — which is
    what the DC blocker in `punchout_sound.sv` is for. Handing that to the
    Pocket's two's complement audio path unblocked would put a large step
    through the filter chain.
  * MAME splits the two chips across a stereo pair, speech left and music
    right. This core mixes them to mono, which is what a handheld wants; the
    split is noted here so the deviation is deliberate rather than forgotten.
  * The speech chip is doing real work — ±10,000 peaks — so the core is missing
    an audible part of the game until the VLM5030 lands, not a garnish.

  The bench to build is the one from METHODOLOGY §4: send the same sound command
  in both, record with `-wavwrite`, and compare peak, RMS and per-band energy.
  It needs the APU driven from a captured register-write stream, because the
  6502 that would otherwise drive it is VHDL and Verilator cannot see it.
  A write tap on the sound CPU's program space does see the APU registers — 443
  writes over 66 seconds, which looked implausible until the recording showed
  the chip is mostly running its own envelope and sweep units between commands.

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
