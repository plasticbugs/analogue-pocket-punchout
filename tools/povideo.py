#!/usr/bin/env python3
"""Reference renderer for the Punch-Out!! video hardware.

The executable spec (METHODOLOGY section 1): given a ROM image built by
mra_build.py and a frozen machine state dumped by tools/dumpstate.lua, produce
exactly the two frames MAME produces. Once this is pixel-identical across a
spread of states, it -- not MAME's C++ -- is what the RTL gets checked against.

Everything here is a transcription of punchout_v.cpp and the parts of
tilemap.cpp it leans on; docs/hardware.md records where each rule came from.

No third-party modules: plain Python 3, including the PNG codec.
"""
import struct, zlib
from array import array

# ---------------------------------------------------------------- ROM image

# Region bases in the flat image built by mra_build.py; see docs/hardware.md.
REGIONS = {
    'maincpu':  (0x00000, 0x0C000),
    'audiocpu': (0x0C000, 0x02000),
    'gfx1':     (0x0E000, 0x04000),
    'gfx2':     (0x12000, 0x04000),
    'gfx3':     (0x16000, 0x30000),
    'gfx4':     (0x46000, 0x10000),
    'proms':    (0x56000, 0x00C00),
    'vlm':      (0x56C00, 0x04000),
}
ROM_SIZE = 0x5AC00


class Roms:
    def __init__(self, path):
        data = open(path, 'rb').read()
        if len(data) != ROM_SIZE:
            raise SystemExit(f'{path}: {len(data)} bytes, expected {ROM_SIZE} '
                             '(build it with tools/mra_build.py)')
        for name, (off, size) in REGIONS.items():
            setattr(self, name, data[off:off + size])


# ---------------------------------------------------------------- state dump

class State:
    """The three video RAM blocks written by tools/dumpstate.lua."""

    def __init__(self, path):
        blocks, name, hexed = {}, None, []
        self.frame, self.drift = None, None
        for line in open(path):
            line = line.strip()
            if not line:
                continue
            if line.startswith('frame '):
                self.frame = int(line.split()[1]);  continue
            if line.startswith('drift '):
                self.drift = int(line.split()[1]);  continue
            if line == 'END' or line.startswith('VRAM_'):
                if name:
                    blocks[name] = bytes.fromhex(''.join(hexed))
                name, hexed = (None if line == 'END' else line), []
                continue
            hexed.append(line)

        self.d800 = blocks['VRAM_D800']   # bg_top + sprite control + palettebank
        self.e000 = blocks['VRAM_E000']   # spr1 (opponent) then spr2 (player)
        self.f000 = blocks['VRAM_F000']   # bg_bot + per-row scroll

        self.bg_top = self.d800                 # 0x800, tilemap reads 2 bytes/tile
        self.spr1_ctrl = self.d800[0x7f0:0x7f8]
        self.spr2_ctrl = self.d800[0x7f8:0x7fd]
        self.palettebank = self.d800[0x7fd]
        self.spr1_vram = self.e000[0x000:0x800]
        self.spr2_vram = self.e000[0x800:0x1000]
        self.bg_bot = self.f000


# ---------------------------------------------------------------- tile decode

def _tile_rows(gfx, stride, planes, code, flipx):
    """Eight rows of eight pen values for one 8x8 planar tile.

    MAME's gfx_8x8xN_planar puts plane bit p at RGN_FRAC(p, N), because
    planeoffset[0] is the most significant bit and the list runs high to low.
    xoffset STEP8(0,1) makes bit 7 of the byte the leftmost pixel.
    """
    base = code * 8
    out = []
    for r in range(8):
        planebytes = [gfx[stride * p + base + r] for p in range(planes)]
        row = []
        for x in range(8):
            xx = 7 - x if flipx else x
            shift = 7 - xx
            pen = 0
            for p in range(planes):
                pen |= ((planebytes[p] >> shift) & 1) << p
            row.append(pen)
        out.append(row)
    return out


def _build_map(vram, gfx, stride, planes, cols, rows, decode, colour_base,
               transparent_pen=None):
    """Render a tilemap to a pixmap of palette indices, plus an opacity mask.

    decode(index) -> (code, colour, flipx). colour_base is the GFXDECODE colour
    base, which is baked into the pixmap exactly as MAME bakes it.
    """
    w, h = cols * 8, rows * 8
    # 'H' not bytearray: gfx2 and gfx4 carry a 0x100 colour base, so pixmap
    # values are 9-bit palette indices, not bytes.
    pix = [array('H', bytes(2 * w)) for _ in range(h)]
    opq = [bytearray(b'\x01' * w) for _ in range(h)] if transparent_pen is not None else None
    granularity = 1 << planes

    cache = {}
    for row in range(rows):
        for col in range(cols):
            code, colour, flipx = decode(row * cols + col)
            key = (code, flipx)
            tile = cache.get(key)
            if tile is None:
                tile = cache[key] = _tile_rows(gfx, stride, planes, code, flipx)
            pbase = colour_base + colour * granularity
            for r in range(8):
                y = row * 8 + r
                src = tile[r]
                prow = pix[y]
                x0 = col * 8
                for c in range(8):
                    prow[x0 + c] = pbase + src[c]
                if opq is not None:
                    orow = opq[y]
                    for c in range(8):
                        if src[c] == transparent_pen:
                            orow[x0 + c] = 0
    return pix, opq


def build_pixmaps(st, roms):
    """The four tilemaps, exactly as punchout_state::video_start creates them."""

    def top_info(i):
        attr = st.bg_top[i * 2 + 1]
        return (st.bg_top[i * 2] + ((attr & 0x03) << 8),
                (attr & 0x7c) >> 2,
                bool(attr & 0x80))

    def bot_info(i):
        attr = st.bg_bot[i * 2 + 1]
        return (st.bg_bot[i * 2] + ((attr & 0x03) << 8),
                (attr & 0x7c) >> 2,
                bool(attr & 0x80))

    def bs1_info(i):
        attr = st.spr1_vram[i * 4 + 3]
        return (st.spr1_vram[i * 4] + ((st.spr1_vram[i * 4 + 1] & 0x1f) << 8),
                attr & 0x1f,
                bool(attr & 0x80))

    def bs2_info(i):
        attr = st.spr2_vram[i * 4 + 3]
        return (st.spr2_vram[i * 4] + ((st.spr2_vram[i * 4 + 1] & 0x0f) << 8),
                attr & 0x3f,
                bool(attr & 0x80))

    maps = {}
    # gfx1 colour base 0x000: the top monitor's palette is pens 0x000-0x0ff.
    maps['top'] = _build_map(st.bg_top, roms.gfx1, 0x2000, 2, 32, 32, top_info, 0x000)
    # gfx2 colour base 0x100: the bottom monitor's palette is pens 0x100-0x1ff.
    maps['bot'] = _build_map(st.bg_bot, roms.gfx2, 0x2000, 2, 64, 32, bot_info, 0x100)
    # gfx3 colour base 0x000; draw_big_sprite adds 0x100 for the bottom monitor.
    maps['spr1'] = _build_map(st.spr1_vram, roms.gfx3, 0x10000, 3, 16, 32, bs1_info,
                              0x000, transparent_pen=0x07)
    maps['spr2'] = _build_map(st.spr2_vram, roms.gfx4, 0x8000, 2, 16, 32, bs2_info,
                              0x100, transparent_pen=0x03)
    return maps


# ---------------------------------------------------------------- ROZ blit

M32 = 0xFFFFFFFF
CLIP = (0, 16, 255, 239)     # MAME's visarea inside the 256x256 bitmap


def draw_roz(dest, pixmap, opaque, startx, starty, incxx, incyy, pal_off):
    """tilemap_t::draw_roz_core, non-rotated, wraparound off.

    Every comparison is unsigned 32-bit; that is what makes coordinates off the
    left or top edge fall out for free, and it is not optional.
    """
    ph = len(pixmap)
    pw = len(pixmap[0])
    left, top, right, bottom = CLIP
    startx = (startx + left * incxx) & M32
    starty = (starty + top * incyy) & M32
    incxx &= M32
    incyy &= M32

    sx, sy, ex, ey = left, top, right, bottom
    widthshifted = pw << 16
    heightshifted = ph << 16

    while startx >= widthshifted and sx <= ex:
        startx = (startx + incxx) & M32
        sx += 1
    if sx > ex:
        return

    while sy <= ey:
        if starty < heightshifted:
            cx = startx
            cy = starty >> 16
            src = pixmap[cy]
            msk = opaque[cy] if opaque is not None else None
            drow = dest[sy]
            x = sx
            while x <= ex and cx < widthshifted:
                i = cx >> 16
                if msk is None or msk[i]:
                    drow[x] = (src[i] + pal_off) & 0x1ff
                cx = (cx + incxx) & M32
                x += 1
        starty = (starty + incyy) & M32
        sy += 1


def draw_big_sprite(dest, maps, st, palette):
    """punchout_state::draw_big_sprite -- the zooming opponent."""
    c = st.spr1_ctrl
    zoom = c[0] + 256 * (c[1] & 0x0f)
    if zoom == 0:
        return

    sx = 4096 - (c[2] + 256 * (c[3] & 0x0f))
    if sx > 4096 - 4 * 127:
        sx -= 4096
    sy = -(c[4] + 256 * (c[5] & 1))
    if sy <= -256 + zoom // 0x40:
        sy += 512
    sy += 12

    incxx = incyy = zoom << 6
    startx = (-sx * 0x4000 + 3740 * zoom) & M32
    starty = (-sy * 0x10000 - 178 * zoom) & M32

    if c[6] & 1:                       # flip x
        startx = ((16 * 8) << 16) - startx - 1
        incxx = -incxx

    pix, opq = maps['spr1']
    draw_roz(dest, pix, opq, startx & M32, (starty + 0x400 * zoom) & M32,
             incxx, incyy, 0x100 * palette)


def draw_bs2(dest, maps, st):
    """punchout_state::drawbs2 -- the player, bottom monitor only, no zoom."""
    c = st.spr2_ctrl
    sx = 512 - (c[0] + 256 * (c[1] & 1))
    if sx > 512 - 127:
        sx -= 512
    sx -= 55
    # Not a typo, and not symmetrical with sx: the driver really does write
    # -ctrl[2] + 256*bit rather than -(ctrl[2] + 256*bit).
    sy = -c[2] + 256 * (c[3] & 1)
    sy += 3

    startx = (-sx << 16) & M32
    starty = (-sy << 16) & M32
    if c[4] & 1:
        startx = (((16 * 8) << 16) - startx - 1) & M32
        incxx = -1
    else:
        incxx = 1

    pix, opq = maps['spr2']
    draw_roz(dest, pix, opq, startx, starty, incxx << 16, 1 << 16, 0)


# ---------------------------------------------------------------- palette

def palette_rgb(roms, monitor, bank):
    """256 (r,g,b) triples for one monitor at one bank.

    Six 512-byte PROMs, low nibble only, and the value is inverted:
    component = 255 - pal4bit(v). Top monitor reads the first three PROMs,
    bottom monitor the second three.
    """
    base = 0x600 if monitor == 'bot' else 0x000
    off = 0x100 * bank
    p = roms.proms
    out = []
    for i in range(256):
        r = 255 - ((p[base + 0x000 + off + i] & 0x0f) * 0x11)
        g = 255 - ((p[base + 0x200 + off + i] & 0x0f) * 0x11)
        b = 255 - ((p[base + 0x400 + off + i] & 0x0f) * 0x11)
        out.append((r, g, b))
    return out


# ---------------------------------------------------------------- screens

def _blank_bitmap():
    return [array('H', bytes(512)) for _ in range(256)]


def render_top(st, roms, maps, raw=False):
    """screen_update_punchout_top -> 256x224 RGB bytes (or raw palette
    indices when raw=True, which is what the RTL's line buffer holds)."""
    dest = _blank_bitmap()
    pix, _ = maps['top']
    for y in range(CLIP[1], CLIP[3] + 1):      # tilemap scroll is zero
        dest[y][:] = pix[y][:256]
    if st.spr1_ctrl[7] & 1:
        draw_big_sprite(dest, maps, st, 0)
    if raw:
        return [[dest[y][x] & 0xff for x in range(256)]
                for y in range(CLIP[1], CLIP[3] + 1)]
    return _to_rgb(dest, palette_rgb(roms, 'top', (st.palettebank >> 1) & 1), 0x000)


def render_bottom(st, roms, maps, raw=False):
    """screen_update_punchout_bottom -> 256x224 RGB bytes (or raw palette
    indices when raw=True)."""
    dest = _blank_bitmap()
    pix, _ = maps['bot']

    # 32 rows of 8 pixels, scroll read from the first 64 bytes of the same RAM.
    # MAME's convention: a positive scrollx moves the picture left, so screen x
    # shows tilemap pixel (x + scrollx) mod 512.
    scroll = [58 + st.bg_bot[2 * r] + 256 * (st.bg_bot[2 * r + 1] & 1) for r in range(32)]
    for y in range(CLIP[1], CLIP[3] + 1):
        s = scroll[y // 8] % 512
        srow = pix[y]
        drow = dest[y]
        for x in range(256):
            drow[x] = srow[(x + s) & 511]

    if st.spr1_ctrl[7] & 2:
        draw_big_sprite(dest, maps, st, 1)
    draw_bs2(dest, maps, st)
    if raw:
        return [[dest[y][x] & 0xff for x in range(256)]
                for y in range(CLIP[1], CLIP[3] + 1)]
    return _to_rgb(dest, palette_rgb(roms, 'bot', st.palettebank & 1), 0x100)


def _to_rgb(dest, pal, pal_base):
    """Crop the 256x256 bitmap to the visible 256x224 and resolve colours."""
    out = bytearray(256 * 224 * 3)
    o = 0
    for y in range(CLIP[1], CLIP[3] + 1):
        row = dest[y]
        for x in range(256):
            r, g, b = pal[(row[x] - pal_base) & 0xff]
            out[o] = r; out[o + 1] = g; out[o + 2] = b
            o += 3
    return out


def render(st, roms):
    """Both monitors stacked the way MAME's dual-screen snapshot stacks them:
    top 0..223, two blank rows, bottom 226..449."""
    maps = build_pixmaps(st, roms)
    top = render_top(st, roms, maps)
    bot = render_bottom(st, roms, maps)
    img = bytearray(256 * 450 * 3)
    img[0:256 * 224 * 3] = top
    img[256 * 226 * 3:256 * 450 * 3] = bot
    return 256, 450, img


# ---------------------------------------------------------------- PNG codec

def read_png(path):
    d = open(path, 'rb').read()
    pos, idat, plte = 8, b'', None
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        tag = d[pos + 4:pos + 8]
        if tag == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', d[pos + 8:pos + 18])
            ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
        elif tag == b'PLTE':
            plte = d[pos + 8:pos + 8 + ln]
        elif tag == b'IDAT':
            idat += d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = w * ch
    img = bytearray(w * h * 3)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        row = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        if f:
            for x in range(stride):
                a = row[x - ch] if x >= ch else 0
                b = prev[x]
                c = prev[x - ch] if x >= ch else 0
                if f == 1:   row[x] = (row[x] + a) & 0xff
                elif f == 2: row[x] = (row[x] + b) & 0xff
                elif f == 3: row[x] = (row[x] + (a + b) // 2) & 0xff
                elif f == 4:
                    pp = a + b - c
                    pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                    row[x] = (row[x] + (a if (pa <= pb and pa <= pc) else (b if pb <= pc else c))) & 0xff
        prev = row
        for x in range(w):
            o = (y * w + x) * 3
            if ct == 3:
                pi = row[x] * 3
                img[o:o + 3] = plte[pi:pi + 3]
            elif ct == 0:
                img[o:o + 3] = bytes([row[x]] * 3)
            else:
                img[o:o + 3] = row[x * ch:x * ch + 3]
    return w, h, img


def write_png(path, w, h, img):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += img[y * w * 3:(y + 1) * w * 3]

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(bytes(raw), 9)))
        f.write(chunk(b'IEND', b''))
