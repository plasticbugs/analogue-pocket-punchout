#!/usr/bin/env python3
"""Diff the RTL's 512x672 composite against the reference renderer.

    diff_rtl.py <rtl.ppm> <state.txt> <rom>

Pulls the two monitors back out of the composite and checks three things:

  * the info screen occupies rows 0..223, columns 128..383, at 1:1
  * the fight screen occupies rows 224..671 at exactly 2x in both axes, which
    is checked by requiring every 2x2 block to be uniform before downsampling
  * everything else in the top 224 rows is black

then compares both extracted monitors against tools/povideo.py, which is
pixel-identical to MAME. So a pass means the renderers AND the compositor are
right, not just one of them.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import povideo as pv

CW, CH = 512, 672
SW, SH = 256, 224
TOP_XOFF = 128
TOP_ROWS = 224


def read_ppm(path):
    d = open(path, 'rb').read()
    if not d.startswith(b'P6'):
        raise SystemExit(f'{path}: not a P6 ppm')
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(d) and d[i:i + 1].isspace():
            i += 1
        if d[i:i + 1] == b'#':
            while d[i:i + 1] != b'\n':
                i += 1
            continue
        j = i
        while not d[j:j + 1].isspace():
            j += 1
        fields.append(int(d[i:j]))
        i = j
    return fields[0], fields[1], bytearray(d[i + 1:])


def px(img, w, x, y):
    o = (y * w + x) * 3
    return bytes(img[o:o + 3])


def compare(name, model, rtl):
    diff, cells = 0, {}
    for y in range(SH):
        for x in range(SW):
            o = (y * SW + x) * 3
            if bytes(model[o:o + 3]) != bytes(rtl[o:o + 3]):
                diff += 1
                cells[(y // 8, x // 8)] = cells.get((y // 8, x // 8), 0) + 1
    if diff == 0:
        print(f'  {name:6s}  0 differing pixels')
        return 0
    print(f'  {name:6s}  {diff} differing pixels ({100.0 * diff / (SW * SH):.2f}%) '
          f'in {len(cells)} cells')
    for (cy, cx), n in sorted(cells.items(), key=lambda kv: -kv[1])[:8]:
        print(f'            cell x={cx * 8:3d} y={cy * 8:3d}  {n:3d} px')
    return diff


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    ppm_path, state_path, rom_path = sys.argv[1:4]

    w, h, img = read_ppm(ppm_path)
    if (w, h) != (CW, CH):
        sys.exit(f'{ppm_path}: {w}x{h}, expected {CW}x{CH}')

    st = pv.State(state_path)
    roms = pv.Roms(rom_path)
    model = pv.render_screens(st, roms)

    tag = os.path.basename(state_path)
    print(f'{tag}:')
    bad = 0

    # ---- the border around the info screen must be black
    black = 0
    for y in range(TOP_ROWS):
        for x in range(CW):
            if TOP_XOFF <= x < TOP_XOFF + SW:
                continue
            if px(img, CW, x, y) != b'\x00\x00\x00':
                black += 1
    if black:
        print(f'  border  {black} non-black pixels beside the info screen')
        bad += black

    # ---- info screen, 1:1
    top = bytearray(SW * SH * 3)
    for y in range(SH):
        for x in range(SW):
            top[(y * SW + x) * 3:(y * SW + x) * 3 + 3] = px(img, CW, TOP_XOFF + x, y)
    bad += compare('top', model['top'], top)

    # ---- fight screen: require exact 2x2 blocks, then downsample
    bot = bytearray(SW * SH * 3)
    nonuniform = 0
    for y in range(SH):
        for x in range(SW):
            p = px(img, CW, 2 * x, TOP_ROWS + 2 * y)
            for dy in range(2):
                for dx in range(2):
                    if px(img, CW, 2 * x + dx, TOP_ROWS + 2 * y + dy) != p:
                        nonuniform += 1
            bot[(y * SW + x) * 3:(y * SW + x) * 3 + 3] = p
    if nonuniform:
        print(f'  scale   {nonuniform} pixels break the 2x2 blocks - the fight '
              'screen is not a clean integer double')
        bad += nonuniform
    bad += compare('bot', model['bot'], bot)

    return 0 if bad == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
