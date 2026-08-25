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

## Not yet checked

* **RTL video against the reference renderer** — the frozen-state bench
  (METHODOLOGY Phase 4). Not built yet.
* **Where in the frame the game writes video RAM.** The core renders the top
  monitor into output rows 0..223 and the bottom into 224..671, so the two
  halves are rendered at different points in the frame. That is only safe if
  the game confines its video RAM writes to vblank. Measure it with a write tap
  that records the current scanline before relying on it.
* **Audio.** Nothing yet. The 2A03's tempo comes from its own crystal, so
  METHODOLOGY §5.3 does not apply, but §5.4 does: the sample bus crossing into
  `clk_74b` needs the toggle handshake.
* **VLM5030 speech.** Deferred to last, by decision.
