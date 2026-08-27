#!/usr/bin/env python3
"""Sound board against MAME: the APU register-write streams and the audio.

  python3 tools/compare_audio.py <rtl_apu.bin> <mame_apu.bin> <rtl.s16> <mame.wav> [frames]

The write logs are (frame u16, addr u16, data u8) records from the bench
(PO_APULOG) and from scratchpad/aputap.lua. The RTL audio is signed 16-bit at
1789772/37 Hz from PO_WAV; MAME's WAV is 48 kHz stereo, VLM left, 2A03 right.
Pure Python: envelope per frame and a cross-correlation over one window.
"""
import sys, struct, math

def load_log(p):
    d = open(p, 'rb').read()
    return [struct.unpack_from('<HHB', d, i) for i in range(0, len(d) - len(d) % 5, 5)]

def main():
    rtl_log, mame_log, rtl_s16, mame_wav = sys.argv[1:5]
    frames = int(sys.argv[5]) if len(sys.argv) > 5 else 1500
    a = load_log(rtl_log); b = load_log(mame_log)
    a = [r for r in a if r[0] <= frames]; b = [r for r in b if r[0] <= frames]
    print(f"APU writes: rtl {len(a)}, mame {len(b)}")
    # the sound CPU's APU addresses: the RTL logs A[4:0], MAME logs the offset from 0x4000
    seq_a = [(f, ad & 0x1f, v) for f, ad, v in a]; seq_b = [(f, ad & 0x1f, v) for f, ad, v in b]
    n = min(len(seq_a), len(seq_b)); first = None
    for i in range(n):
        if seq_a[i][1:] != seq_b[i][1:]: first = i; break
    if first is None and len(seq_a) == len(seq_b):
        print("  register/data sequence: IDENTICAL")
    else:
        i = first if first is not None else n
        print(f"  register/data sequence: first difference at write #{i}: rtl {seq_a[i] if i < len(seq_a) else None}  mame {seq_b[i] if i < len(seq_b) else None}")
    # frame alignment of matching writes
    off = [seq_a[i][0] - seq_b[i][0] for i in range(min(n, (first or n)))]
    if off:
        from collections import Counter
        print("  frame offset rtl-mame over the matching prefix:", Counter(off).most_common(4))
    # audio
    r = open(rtl_s16, 'rb').read(); rtl = [struct.unpack_from('<h', r, i)[0] for i in range(0, len(r), 2)]
    w = open(mame_wav, 'rb').read(); ch = struct.unpack_from('<H', w, 22)[0]; rate = struct.unpack_from('<I', w, 24)[0]
    i = w.find(b'data'); nbytes = struct.unpack_from('<I', w, i + 4)[0]; pcm = w[i + 8:i + 8 + nbytes]
    mame_r = [struct.unpack_from('<h', pcm, (k * ch + (ch - 1)) * 2)[0] for k in range(nbytes // (2 * ch))]
    rr = 1789772 / 37.0
    def rms(x): return math.sqrt(sum(v * v for v in x) / max(1, len(x)))
    print(f"audio: rtl {len(rtl)/rr:.2f} s at {rr:.0f} Hz; mame {len(mame_r)/rate:.2f} s at {rate} Hz (right channel = 2A03)")
    # envelope per 10 frames
    rows = []
    for k in range(0, frames, 10):
        ra = rtl[int(k / 60 * rr):int((k + 10) / 60 * rr)]; mb = mame_r[int(k / 60 * rate):int((k + 10) / 60 * rate)]
        if not ra or not mb: break
        rows.append((k, rms(ra), rms(mb)))
    active = [(k, x, y) for k, x, y in rows if y > 200]
    ratios = [x / y for k, x, y in active]
    if ratios:
        ratios.sort(); print(f"  envelope ratio rtl/mame over {len(ratios)} active 10-frame windows: median {ratios[len(ratios)//2]:.3f}, min {ratios[0]:.3f}, max {ratios[-1]:.3f}")
    print("  frames  rtl_rms  mame_rms  (every 100 frames)")
    for k, x, y in rows[::10]: print(f"  {k:5d}  {x:7.0f}  {y:7.0f}")
    # cross-correlation on one loud window, MAME resampled to the RTL rate by linear interpolation
    if active:
        k0 = max(active, key=lambda t: t[2])[0]
        a0 = int(k0 / 60 * rr); seg = rtl[a0:a0 + int(rr * 0.5)]
        def m_at(t): 
            p = t * rate; i0 = int(p); f = p - i0
            return mame_r[i0] * (1 - f) + mame_r[min(i0 + 1, len(mame_r) - 1)] * f
        best = (0, 0)
        for lag_ms in [x * 0.25 for x in range(-80, 81)]:
            t0 = k0 / 60 + lag_ms / 1000; m = [m_at(t0 + j / rr) for j in range(len(seg))]
            num = sum(x * y for x, y in zip(seg, m)); den = math.sqrt(sum(x * x for x in seg) * sum(y * y for y in m)) or 1
            c = num / den
            if c > best[0]: best = (c, lag_ms)
        print(f"  waveform correlation over 0.5 s from frame {k0}: peak {best[0]:.3f} at lag {best[1]:+.2f} ms (rtl relative to mame)")

if __name__ == '__main__':
    main()
