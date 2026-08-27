# Punch-Out!! arcade hardware

Everything the core needs to know about the machine, taken from MAME 0.288
(`src/mame/nintendo/punchout.cpp`, `punchout_v.cpp`, `punchout.h`) and from
interrogating the running driver. Written first, per METHODOLOGY §3 Phase 1,
and updated whenever a measurement contradicts it.

Target set: **`punchout`** — Punch-Out!! (Rev B), Nintendo, 1984. Super
Punch-Out!! and Arm Wrestling run on the same main board but are out of scope
for this core (see §11).

---

## 1. Chips and clocks

| Part | Role | Clock | Source |
|---|---|---|---|
| Zilog Z80 | main CPU | **4.000 MHz** (8 MHz XTAL ÷2) | `Z80(config, m_maincpu, XTAL(8'000'000)/2)` |
| Ricoh RP2A03 | sound CPU **and** APU | **1.789772 MHz** (`NTSC_APU_CLOCK`) | 21.477272 MHz ÷12 |
| Sanyo VLM5030 | LPC speech | **3.579545 MHz** (`RP2A03_NTSC_XTAL/6`) | `po_vlm5030`: sample clock 3579545/440 = 8135 Hz from a 96 MHz phase accumulator |
| — | pixel clock | derived from a 20.16 MHz XTAL; exact raw params **not modelled by MAME** | driver TODO |

Two monitors, both 256×224 at 60 Hz nominal. MAME declares
`set_size(32*8, 32*8)` with `set_visarea(0, 255, 16, 239)`, i.e. a 256×256
raster of which lines **16–239** are visible. Every screen coordinate quoted in
this document is in that 256×256 space, so **visible line 0 of the core's
output is MAME bitmap y = 16**.

MAME's `punchout.cpp` carries `TODO: video raw params - pixel clock is derived
from 20.16mhz xtal`, so the real horizontal and vertical totals are unknown and
the 60 Hz refresh is a placeholder. The core therefore generates its own raster
(§9) and drives the game from it; nothing in the game depends on the exact
totals because everything is paced by the vblank NMI, and the audio is paced by
the 2A03's own crystal, not by the CPU (METHODOLOGY §5.3 does not bite here).

Both screens share one `screen_vblank` callback:

```
top.screen_vblank().set(FUNC(punchout_state::vblank_irq));          // Z80 NMI, if enabled
top.screen_vblank().append_inputline(m_audiocpu, INPUT_LINE_NMI);   // 2A03 NMI, always
```

So one vblank per frame raises **NMI on both CPUs**; the Z80's is gated by the
`nmi_mask` latch bit, the 2A03's is not.

---

## 2. Main CPU (Z80) memory map

```
0000-bfff  ROM                        48 KB
c000-c3ff  NVRAM                       1 KB   battery-backed, high scores/records
d000-d7ff  work RAM                    2 KB
d800-dfef  video RAM, INFO screen      (bg_top_videoram, top monitor tilemap)
dff0-dff7  spr1_ctrlram                big sprite #1 control (see §5)
dff8-dffc  spr2_ctrlram                big sprite #2 control (see §6)
dffd       palettebank                 bit0 = bottom monitor bank, bit1 = top
dffe-dfff  RAM (unused)
e000-e7ff  video RAM, OPPONENT         (spr1_videoram, big sprite #1 tilemap)
e800-efff  video RAM, PLAYER           (spr2_videoram, big sprite #2 tilemap)
f000-ffff  video RAM, BACKGROUND       (bg_bot_videoram, bottom monitor tilemap)
           f000-f03f is also the per-row scroll table (see §4)
```

Note `d800-dfef` and `dff0-dfff` are one contiguous 2 KB RAM; the top 16 bytes
are registers rather than tilemap. `bg_top_videoram` is declared as the whole
`d800-dfef` share.

### I/O ports (`map.global_mask(0xff)`)

Read:

```
00  IN0    d0 = Button 1 (left punch)   active HIGH
           d2 = Button 2 (right punch)  active HIGH
           d3 = Button 3 (KO punch)     active HIGH
           d1, d4-d7 unused
01  IN1    d0 = Right   d1 = Left   d2 = Up   d3 = Down   (4-way, active HIGH)
           d6 = Service 1              active HIGH
           d7 = Coin 1                 active HIGH
02  DSW2   see §8
03  DSW1   see §8; d4 = VLM5030 BSY, **active LOW**
```

Write:

```
00-01  to 2A03 #1 (not populated on this board) - ignored
02     soundlatch  -> 2A03 reads at 4016
03     soundlatch2 -> 2A03 reads at 4017
04     VLM5030 data
05-07  Super Punch-Out!! protection only; no-ops here
08-0f  74LS259 addressable latch (chip 2B), D0 written to bit (addr & 7)
```

74LS259 "mainlatch" bits:

| Bit | Function |
|---|---|
| 0 | NMI enable (+ watchdog reset). Clearing it also clears a pending NMI. |
| 1 | watchdog reset (no-op for us) |
| 2 | unknown, no-op |
| 3 | 2A03 RESET line |
| 4 | VLM5030 RST |
| 5 | VLM5030 ST (start) |
| 6 | VLM5030 VCU |
| 7 | NVRAM enable? no-op |

---

## 3. Sound CPU (RP2A03) memory map

```
0000-07ff  RAM (2 KB)
4000-400f  APU registers, reads return open bus (MAME: nopr)
4016       soundlatch  (command from Z80 port 02)
4017       soundlatch2 (command from Z80 port 03)
e000-ffff  ROM (8 KB)
```

The RP2A03 is a 6502 with decimal mode removed plus the NES APU on the same
die. Its two `4016/4017` "controller" ports are wired to the two sound
latches instead. Music tempo comes from the APU frame sequencer running off the
chip's own 1.789772 MHz clock, so it is independent of anything the Z80 does.

`4011` (APU DMC direct load) is written directly as a 7-bit DAC — that is the
crowd noise.

---

## 4. Video: tilemaps

Four graphics regions, all 8×8 tiles, all **planar**, decoded with MAME's
standard layouts (`src/emu/video/generic.cpp`):

```
gfx_8x8x2_planar: 2 planes, planeoffset { RGN_FRAC(1,2), RGN_FRAC(0,2) }
gfx_8x8x3_planar: 3 planes, planeoffset { RGN_FRAC(2,3), RGN_FRAC(1,3), RGN_FRAC(0,3) }
xoffset STEP8(0,1)   -> bit 7 of the byte is the LEFTMOST pixel
yoffset STEP8(0,8)   -> row r is byte r
charincrement 8*8    -> 8 bytes per tile per plane
```

`planeoffset[0]` is the **most significant** pixel bit (MAME's `decodechar`
uses `1 << (planes - 1 - plane)`), so for a 2 bpp region the high plane comes
from the **second** half and for gfx3 the planes are, from bit 2 down,
`0x20000 / 0x10000 / 0x00000`.

| Region | Size | bpp | Tiles | Used by | Palette |
|---|---|---|---|---|---|
| gfx1 | 0x4000 | 2 | 1024 | top monitor background | top, base 0, granularity 4 |
| gfx2 | 0x4000 | 2 | 1024 | bottom monitor background | bottom, base 0, granularity 4 |
| gfx3 | 0x30000 | 3 | 8192 | big sprite #1 (both monitors) | whichever monitor, granularity 8 |
| gfx4 | 0x10000 | 2 | 4096 | big sprite #2 (bottom only) | bottom, granularity 4 |

### Top monitor background — 32×32 tiles (256×256 px), no scroll

From `bg_top_videoram`, two bytes per tile:

```
code  = ram[i*2] + ((attr & 0x03) << 8)      10 bits -> 1024 tiles
color = (attr & 0x7c) >> 2                    5 bits -> 32 colours
flipx =  attr & 0x80
attr  = ram[i*2 + 1]
```

Palette index = `color * 4 + pen`, resolved through the **top** monitor PROMs.
Drawn opaque, first.

### Bottom monitor background — 64×32 tiles (512×256 px), per-row scroll

From `bg_bot_videoram`, same tile encoding as the top map (gfx2 instead of
gfx1, palette base 0x100 = the bottom monitor's palette).

Per-row X scroll, 32 rows of 8 pixels each, read from the **first 64 bytes of
the same RAM** (`f000-f03f`, which is therefore also tilemap row 0, off screen):

```
scrollx[row] = 58 + bg_bot_videoram[2*row] + 256 * (bg_bot_videoram[2*row+1] & 1)
```

MAME tilemap scroll convention: a positive `scrollx` moves the image **left**,
i.e. screen x shows tilemap pixel `(x + scrollx) mod 512`. Row `r` covers
screen y `8r .. 8r+7`, so the first visible line (y=16) uses row 2.

---

## 5. Video: big sprite #1 — the opponent

This is not a sprite in the usual sense: it is a **second tilemap, 16×32 tiles
(128×256 px), drawn through a zooming ROZ blit**. It appears on *both*
monitors, with a per-monitor palette and a per-monitor enable.

Tile data from `spr1_videoram` (`e000-e7ff`), **four** bytes per tile:

```
code  = ram[i*4] + ((ram[i*4+1] & 0x1f) << 8)   13 bits -> 8192 tiles (gfx3)
color =  ram[i*4+3] & 0x1f                       5 bits
flipx =  ram[i*4+3] & 0x80
```

Transparent pen = **7** (all three planes set). Palette index within the
selected monitor's 256 entries = `color * 8 + pen`.

Control registers, `dff0-dff7`:

```
dff0  zoom, low 8 bits
dff1  zoom, high 4 bits          12-bit zoom; 0x400 == 1:1
dff2  x position, low 8
dff3  x position, high 4
dff4  y position, low 8
dff5  y position, bit 8
dff6  bit0 = flip x
dff7  bit0 = show on TOP monitor, bit1 = show on BOTTOM monitor
```

MAME's `draw_big_sprite()`, verbatim in effect:

```
zoom = ctrl[0] + 256*(ctrl[1] & 0x0f)
if zoom == 0: draw nothing

sx = 4096 - (ctrl[2] + 256*(ctrl[3] & 0x0f))
if sx > 4096 - 4*127:  sx -= 4096            # i.e. if sx > 3588
sy = -(ctrl[4] + 256*(ctrl[5] & 1))
if sy <= -256 + zoom/0x40:  sy += 512
sy += 12

incxx = incyy = zoom << 6                     # 16.16 step; zoom 0x400 -> 1<<16
startx = -sx * 0x4000  + 3740 * zoom          # "adjustment to match screen shots"
starty = -sy * 0x10000 - 178  * zoom

if ctrl[6] & 1:                               # flip x
    startx = (128 << 16) - startx - 1
    incxx  = -incxx

draw_roz(startx, starty + 0x400*zoom, incxx, 0, 0, incyy, wraparound=false)
```

`startx`/`starty` are **u32** and the arithmetic relies on that wrapping.

### ROZ blit semantics (`tilemap_t::draw_roz_core`, non-rotated, no wraparound)

```
startx += cliprect.left * incxx        # cliprect.left = 0
starty += cliprect.top  * incyy        # cliprect.top  = 16
sx = 0, sy = 16, ex = 255, ey = 239

while startx >= (128 << 16) and sx <= ex:      # unsigned compare
    startx += incxx;  sx += 1

for y in sy..ey:
    if starty < (256 << 16):                   # unsigned compare
        cx = startx;  cy = starty >> 16
        x  = sx
        while x <= ex and cx < (128 << 16):    # unsigned compare
            pen = pixmap[cy][cx >> 16]
            if pen is not transparent: dest[y][x] = pen
            cx += incxx;  x += 1
    starty += incyy
```

Every comparison is **unsigned 32-bit**, which is what makes "off the left
edge" and "off the top" fall out for free: a negative coordinate becomes a huge
unsigned number and fails the `< width`/`< height` test.

Since `incxy == incyx == 0`, this is separable: one source row per output line,
and a plain horizontal accumulator across it. That maps directly onto a
line-based renderer in RTL.

---

## 6. Video: big sprite #2 — the player

Same idea, no zoom: a 16×32 tile (128×256 px) tilemap from `spr2_videoram`
(`e800-efff`), **bottom monitor only**, drawn last (on top of everything).

```
code  = ram[i*4] + ((ram[i*4+1] & 0x0f) << 8)   12 bits -> 4096 tiles (gfx4)
color =  ram[i*4+3] & 0x3f                       6 bits
flipx =  ram[i*4+3] & 0x80
```

Transparent pen = **3**. Palette index within the bottom monitor's 256 entries
= `color * 4 + pen`.

Control registers, `dff8-dffc`:

```
dff8  x position low 8
dff9  x position bit 8
dffa  y position low 8
dffb  y position bit 8
dffc  bit0 = flip x
```

```
sx = 512 - (ctrl2[0] + 256*(ctrl2[1] & 1))
if sx > 512 - 127:  sx -= 512                 # i.e. if sx > 385
sx -= 55                                       # "adjustment to match screen shots"
sy = -ctrl2[2] + 256*(ctrl2[3] & 1)
sy += 3

startx = -sx << 16
starty = -sy << 16
if ctrl2[4] & 1:  startx = (128 << 16) - startx - 1;  incxx = -1
else:                                                 incxx = +1

draw_roz(startx, starty, incxx << 16, 0, 0, 1 << 16, wraparound=false)
```

Note the sign asymmetry in `sy`: it is `-ctrl2[2] + 256*bit`, not
`-(ctrl2[2] + 256*bit)`. That is what the driver says, and it is deliberate.

---

## 7. Palette

Six 512-byte colour PROMs, only the **low 4 bits** of each byte used, and the
value is **inverted**:

```
component = 255 - pal4bit(prom_byte)      pal4bit(v) = (v & 0x0f) * 0x11
```

| PROM | Region offset | Monitor | Component |
|---|---|---|---|
| chp1-b-6e | 0x000 | top | R |
| chp1-b-6f | 0x200 | top | G |
| chp1-b-7f | 0x400 | top | B |
| chp1-b-7e | 0x600 | bottom | R |
| chp1-b-8e | 0x800 | bottom | G |
| chp1-b-8f | 0xa00 | bottom | B |

Each is 512 bytes = **two banks of 256**. The bank is selected per monitor by
`palettebank` (`dffd`): bit 1 for the top monitor, bit 0 for the bottom.

```
top    pixel: r = 255 - pal4bit(prom[0x000 + 0x100*bit1 + idx]) ... etc
bottom pixel: r = 255 - pal4bit(prom[0x600 + 0x100*bit0 + idx]) ... etc
```

Boards shipped with either **pink**-labelled or **white**-labelled PROMs; the
white set has its indices reversed (`idx ^ 0xff`). MAME defaults to pink and so
does this core; the white PROMs are in the romset but unused.

`chp1-v-2d.2d` (256 bytes) is a timing PROM. Not used, by MAME or by us.

---

## 8. DIP switches

Both read active-high as stored; MAME's `diplocation` entries are marked
`inverted`, so a switch in the ON position reads 0.

**DSW1** (port 03)

| Bits | Function |
|---|---|
| 0-3 | Coinage (0 = 1C/1C, 0x0f = Free Play) |
| 4 | VLM5030 BSY, **active low** — not a switch |
| 5 | unused |
| 6 | unused (R18 resistor) |
| 7 | Copyright: 0 = "Nintendo", 1 = "Nintendo of America Inc." |

**DSW2** (port 02)

| Bits | Function |
|---|---|
| 0-1 | Difficulty: 0 Easy, 1 Medium, 2 Hard, 3 Hardest |
| 2-3 | Time: 0 Longest, 1 Long, 2 Short, 3 Shortest |
| 4 | Demo Sounds: 1 = On (factory default) |
| 5 | Rematch At A Discount |
| 6 | unused |
| 7 | Service Mode |

Factory defaults: **DSW1 = 0x00, DSW2 = 0x10**.

---

## 9. What the core does differently

### One display instead of two

The Pocket has one screen. The core composites both monitors into a single
**512 × 672** raster:

```
rows   0..223   INFO screen  (top monitor)    256x224 at 1x, centred at x=128..383
rows 224..671   FIGHT screen (bottom monitor) 512x448 at 2x, full width
```

Chosen over an exact 25/75 split because it is the largest arrangement in which
**neither monitor loses a pixel** — the info screen stays at native resolution
and the fight screen is a clean integer 2× — while keeping the pixel clock near
22 MHz, roughly twice the highest found in any shipping Pocket core, and
leaving the Pocket's CRT Trinitron display mode usable (it quantises the
displayed height to an integer multiple of the source height; 672 × 2 = 1344 of
1440 rows).

Rendering order follows the output raster: the top monitor's line *L* is
rendered during output row *L−1*, the bottom monitor's line *M* during output
rows 224+2M−1. Both read the same VRAM, which the game updates in its vblank
NMI handler, so the two halves see the same machine state. (To be confirmed by
measurement — see `docs/verification.md`.)

### Memory

The romset is 363 KB of address space, which does not fit the 5CEBA4's ~385 KB
of block RAM alongside the RAMs and line buffers, so METHODOLOGY §8.4 ("put
everything in BRAM if it fits") does not apply. Split:

| Where | Regions | Size |
|---|---|---|
| block RAM | maincpu, audiocpu, gfx1, gfx2, PROMs | 91 KB |
| SDRAM | gfx3, gfx4, VLM speech | 272 KB |

The SDRAM side is only read by the sprite renderers and the speech chip. Budget
per bottom-monitor line (METHODOLOGY §5.2): big sprite #1 spans at most 16
tiles because its tilemap is only 128 px wide, big sprite #2 likewise, so at
most 32 tile-row fetches — about 64 SDRAM word reads in a 48 µs window. There
is no bandwidth problem to design around here.

### Clocks

| Clock | Rate | Drives |
|---|---|---|
| `clk_sys` | 48 MHz | video rendering, Z80 (÷12 = 4.000 MHz exactly) |
| `clk_snd` | 21.477272 MHz | 2A03 (÷12), VLM5030 (÷6) — both exact |
| `clk_vid` | ~23 MHz | Pocket video output (512×672 raster) |
| `clk_ram` | ~96 MHz | SDRAM controller |

Two multi-bit crossings need auditing before integration (METHODOLOGY §5.4):
the audio sample into `clk_74b`, and anything the renderer hands between
`clk_sys` and `clk_vid`.

---

## 10. ROM image layout

One flat image, built by `tools/mra_build.py` from `punchout.mra`. Region base
addresses are kept at their MAME offsets including the unpopulated gaps, so a
tile code maps to an address with a shift and an add and no remapping table.

```
offset     size      region     notes
0x00000    0x0C000   maincpu    Z80 0000-bfff
0x0C000    0x02000   audiocpu   2A03 e000-ffff
0x0E000    0x04000   gfx1       top bg chars    (plane0 +0x0000, plane1 +0x2000)
0x12000    0x04000   gfx2       bottom bg chars (plane0 +0x0000, plane1 +0x2000)
0x16000    0x30000   gfx3       big sprite #1   (plane0 +0x00000, +0x10000, +0x20000)
0x46000    0x10000   gfx4       big sprite #2   (plane0 +0x0000, plane1 +0x8000)
0x56000    0x00C00   proms      pink set: R,G,B top then R,G,B bottom
0x56C00    0x04000   vlm        speech data
0x5AC00    total = 371,712 bytes
```

Two regions are loaded interleaved on real hardware. `chp1-b.4c`, `4d`, `4a`,
`4b` (gfx1/gfx2) and `chp1-v.6p`, `6n`, `8p`, `8n` (gfx4) each get their four
2 KB quarters placed in the order **0, 2, 1, 3** within their 8 KB slot:

```
file 0x0000-0x07ff -> slot + 0x0000
file 0x0800-0x0fff -> slot + 0x1000
file 0x1000-0x17ff -> slot + 0x0800
file 0x1800-0x1fff -> slot + 0x1800
```

gfx3 and gfx4 have unpopulated sockets that read as 0xFF; the image includes
those gaps so addressing stays trivial.

---

## 11. Deliberately not implemented

* **Super Punch-Out!!** — same board plus a security PCB in the Z80 socket
  (RP5C01 RTC, RP5H01 OTP PROM) and a fourth button.
* **Arm Wrestling** — same main board, different video board: an extra
  foreground tilemap on the bottom monitor, a 32×16 big-sprite tilemap with a
  custom scan order, and different tile decoding.
* **White-label colour PROMs** — present in the romset, unused; MAME's default
  is the pink set.
* **`chp1-v-2d.2d`** — video timing PROM, unused by MAME.
* **2A03 #1** — the board has a second sound CPU socket that was never
  populated. Writes to I/O ports 00-01 go nowhere.

## NMI phase on this raster

The board raises NMI at the start of its 32-line vertical blank and the game
writes its display updates to fit the ~2.1 ms before the beam returns. This
core snapshots the whole video state once per frame at the end of its own,
shorter, blanking (raster row 17) and renders both monitors from the snapshot,
so a write that lands after the snapshot waits a frame. Measured, the game's
K.O.-meter redraw writes the scroll bytes 20 rows after NMI and the tiles
75-139 rows after: with NMI at the vblank start (row 692) the snapshot fell
between them and the box flickered left on every landed punch. So NMI is
raised at row 520 (`NMI_ROW` in `punchout_video`), 4.9 ms before the
snapshot; the last fight lines are still being drawn from the previous
snapshot while the handler runs. Once per frame is all the game can observe.

## VLM5030

`rtl/po_vlm5030.sv` is a transcription of MAME's `vlm5030.cpp` (Tatsuyuki
Satoh; coefficient tables from decaps of the chip by ogoun and John McMaster).
Its executable spec is `tools/vlm5030.py`, and `sim/run_vlm.sh` holds the RTL
to it sample for sample on every phrase the game uses at each speed the game
latches (parameter bytes 8, 4 and 0).

* **Pins.** Data byte at port 04; LS259 bits 4/5/6 are RST/ST/VCU; BSY is read
  on DSW1 bit 4, active low. RST falling latches the parameter byte from the
  data bus (bits 0-1 interpolation step, 3-5 speed, 6-7 pitch offset); RST
  rising while busy resets the chip. ST rising raises BSY; ST falling looks the
  phrase up -- table entry at `(data & 0xfe) | (data & 1) << 8`, two bytes
  big-endian -- and starts it. VCU (direct addressing) is unused by this game.
* **Frames.** 48-bit LPC frames: pitch 5 bits at bit 1, energy 5 bits at bit
  6, K10..K1 at bits 11, 14, 17, 20, 23, 26, 29, 33, 37, 42 (3,3,3,3,3,3,4,4,5,6
  bits). A command byte with bit 0 set is a silent run of `((cmd>>2)+1)*2`
  frames, or with bit 1 also set the end of speech. Each frame is four
  interpolation periods of `frame_size` samples (40/30/20/60/50 by speed);
  energy, pitch and the ten K's are interpolated in quarters, C integer
  division truncating toward zero.
* **Synthesis.** Excitation is a pulse of `energy` every `pitch` samples, or
  +/-energy noise when pitch is 0 or 1 (a 16-bit LFSR here and in the model;
  MAME uses its random generator there, the one place bit-exactness with MAME
  is not claimed). A ten-stage lattice filter with `/512`, the output clamped
  to 10 bits. After the end marker: one more period of samples, one sample,
  BSY drops.
* **ROM.** The 16 KB speech ROM is in block RAM, filled by the loader from
  image offset 0x56C00 (the same bytes `po_romload` also carries to SDRAM at
  0x50000, now unused there), so speech needs no SDRAM arbitration.
* **Mix.** MAME routes the 2A03 and the VLM5030 into the speaker at 0.5 each.
  The core has the VLM at full scale to the board's 1/2 -- judged on the
  Pocket's panel, where 1/2, 5/8 and 25/32 were all too quiet -- its 10 bits
  left-justified to 16 and held
  between its 8 kHz samples, sampled at the sound board's rate, the sum
  saturated.

## NVRAM

The board's battery-backed 1 KB at c000-c3ff holds the records. On the Pocket
it is data slot 1, `Records`, nonvolatile: 1 KB at bridge address
0x20000000, file `Saves/punchout/plasticbugs.punchout/punchout.sav`, loaded
into the RAM's second port at start (parameters 0x22: "initialise on load"
marks the slot as loaded even on the first run, filling it with 0xFF -- without
that bit the APF has no name for a never-loaded slot and either writes nothing
or a junk filename) and saved by the core's own command: whenever the game has written its
battery RAM, two seconds after the last write (or at once when the Pocket
menu opens) `core_top` issues `target_dataslot_write` for slot 1 from
0x20000000, 1 KB, and the APF reads the range through the `data_unloader`
and creates or updates the file. The Pocket's exit-time flush alone never
creates a file -- it writes a nonvolatile slot back only onto a file it
loaded -- which is why the first save has to come from the core. The
platform's loader accepts only the ROM's address range, so the slot has its
own `data_io` instance (upper address nibble 2); the core also writes the
slot's size (0x400) into the APF's data-slot table. Not 0x10000000: a slot there hangs the Pocket at the
end of loading as soon as a file exists for it, with or without hardware
behind the address. **Reset Records** in the menu writes bridge address
0xF0000020: the interact layer holds `nvclear` high through the reset window
it starts, and the core wipes the RAM to 0xFF through the second port while
the machine is in reset -- the same bytes as a fresh file, so both roads to
"no records" are one road. The game treats either as an unformatted battery
RAM and writes its defaults.

