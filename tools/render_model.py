#!/usr/bin/env python3
"""Render a frozen Punch-Out!! state with the reference model and diff it
against MAME's own screen bitmaps for the same state.

    render_model.py <state.txt> <rom> [--png]
    render_model.py artifacts/state_0900.txt punchout.rom

The comparison is against pix_top_<tag>.bin / pix_bot_<tag>.bin, which
tools/dumpstate.lua writes straight out of screen:pixels(). Those are the
256x224 bitmaps MAME drew, at native size with nothing resampled -- unlike the
dual-screen snapshot, whose layout resamples the bottom monitor and turns every
comparison into hundreds of near-miss colours.

Prints the differing pixel count per monitor and, on a mismatch, the worst 8x8
cells, so a failure starts somewhere instead of nowhere. --png also writes the
model's render and a side-by-side diff image.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import povideo as pv

W, H = 256, 224


def read_mame_pixels(path):
    """screen:pixels() output -> RGB bytes. rgb_t is 0xAARRGGBB in a u32, and
    the Pocket toolchain is little-endian, so the file runs B G R A."""
    d = open(path, 'rb').read()
    if len(d) != W * H * 4:
        raise SystemExit(f'{path}: {len(d)} bytes, expected {W * H * 4}')
    out = bytearray(W * H * 3)
    for i in range(W * H):
        out[i * 3 + 0] = d[i * 4 + 2]
        out[i * 3 + 1] = d[i * 4 + 1]
        out[i * 3 + 2] = d[i * 4 + 0]
    return bytes(out)


def compare(name, model, mame, verbose=True):
    diff, cells = 0, {}
    for y in range(H):
        for x in range(W):
            o = (y * W + x) * 3
            if model[o:o + 3] != mame[o:o + 3]:
                diff += 1
                cells[(y // 8, x // 8)] = cells.get((y // 8, x // 8), 0) + 1
    if diff == 0:
        print(f'  {name:6s}  0 differing pixels')
        return 0
    print(f'  {name:6s}  {diff} differing pixels ({100.0 * diff / (W * H):.2f}%) '
          f'in {len(cells)} cells')
    if verbose:
        for (cy, cx), n in sorted(cells.items(), key=lambda kv: -kv[1])[:8]:
            print(f'            cell x={cx * 8:3d} y={cy * 8:3d}  {n:3d} px')
    return diff


def side_by_side(path, model, mame):
    dw = W * 2 + 4
    out = bytearray(dw * H * 3)
    for y in range(H):
        for x in range(W):
            o = (y * W + x) * 3
            a = (y * dw + x) * 3
            b = (y * dw + x + W + 4) * 3
            bad = model[o:o + 3] != mame[o:o + 3]
            out[a:a + 3] = b'\xff\x00\xff' if bad else model[o:o + 3]
            out[b:b + 3] = mame[o:o + 3]
    pv.write_png(path, dw, H, out)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    want_png = '--png' in sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    state_path, rom_path = args[0], args[1]

    d = os.path.dirname(state_path) or '.'
    tag = os.path.basename(state_path).replace('state_', '').replace('.txt', '')

    st = pv.State(state_path)
    roms = pv.Roms(rom_path)
    if st.drift:
        print(f'warning: dump reports {st.drift} bytes of drift after freezing; '
              'the bitmaps may not be of the state in this file')

    maps = pv.build_pixmaps(st, roms)
    model = {'top': pv.render_top(st, roms, maps),
             'bot': pv.render_bottom(st, roms, maps)}

    print(f'{os.path.basename(state_path)} (frame {st.frame}):')
    total = 0
    for which in ('top', 'bot'):
        ref = os.path.join(d, f'pix_{which}_{tag}.bin')
        if not os.path.exists(ref):
            sys.exit(f'missing {ref} - re-capture with tools/capture_states.sh')
        mame = read_mame_pixels(ref)
        n = compare(which, model[which], mame)
        total += n
        if want_png or n:
            pv.write_png(os.path.join(d, f'ref_{which}_{tag}.png'), W, H, model[which])
        if n:
            p = os.path.join(d, f'diff_{which}_{tag}.png')
            side_by_side(p, model[which], mame)
            print(f'            wrote {p} (model left, mame right, differences magenta)')
    return 0 if total == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
