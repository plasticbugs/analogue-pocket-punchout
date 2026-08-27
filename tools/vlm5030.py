#!/usr/bin/env python3
"""VLM5030 reference model: a transcription of MAME's vlm5030.cpp.

The executable spec for rtl/po_vlm5030.sv (METHODOLOGY 3): every integer
operation is done the way the C does it -- division truncates toward zero --
so the RTL can be held to it sample for sample. The one deliberate departure
from MAME: unvoiced frames take their random bit from a 16-bit LFSR here and
in the RTL, where MAME calls machine().rand(); the two implementations agree
with each other, and neither can be expected to agree with MAME bit for bit
on unvoiced samples.

  python3 tools/vlm5030.py build/punchout.rom build/vlm          # all phrases, param 8
  python3 tools/vlm5030.py build/punchout.rom build/vlm 64 8      # one phrase (table byte), param

Writes phrase_<byte>.s16 (little-endian signed 16-bit, the 10-bit output
left-justified by 6 bits) and phrase_<byte>.wav at 8135 Hz.
"""
import sys, os, struct

VLM_OFF, VLM_LEN = 0x56C00, 0x4000
FR_SIZE = 4
SPEED = [40, 30, 20, 20, 40, 60, 50, 50]
ENERGY = [0,1,2,3,5,6,7,9,11,13,15,17,19,22,24,27,31,34,38,42,47,51,57,62,68,75,82,89,98,107,116,127]
PITCH  = [0,21,22,23,24,25,26,27,28,29,31,33,35,37,39,41,43,45,49,53,57,61,65,69,73,77,85,93,101,109,117,125]
K = [
 [390,403,414,425,434,443,450,457,463,469,474,478,482,485,488,491,494,496,498,499,501,502,503,504,505,506,507,507,508,508,509,509,
  -390,-376,-360,-344,-325,-305,-284,-261,-237,-211,-183,-155,-125,-95,-64,-32,0,32,64,95,125,155,183,211,237,261,284,305,325,344,360,376],
 [0,50,100,149,196,241,284,325,362,396,426,452,473,490,502,510,0,-510,-502,-490,-473,-452,-426,-396,-362,-325,-284,-241,-196,-149,-100,-50],
 [0,64,128,192,256,320,384,448,-512,-448,-384,-320,-256,-192,-128,-64],
 [0,64,128,192,256,320,384,448,-512,-448,-384,-320,-256,-192,-128,-64],
 [0,128,256,384,-512,-384,-256,-128],
 [0,128,256,384,-512,-384,-256,-128],
 [0,128,256,384,-512,-384,-256,-128],
 [0,128,256,384,-512,-384,-256,-128],
 [0,128,256,384,-512,-384,-256,-128],
 [0,128,256,384,-512,-384,-256,-128],
]
KBITS = [6, 5, 4, 4, 3, 3, 3, 3, 3, 3]
KSBIT = [42, 37, 33, 29, 26, 23, 20, 17, 14, 11]     # start bit of K1..K10 in the 48-bit frame

def cdiv(a, b):
    """C integer division: truncate toward zero."""
    q = abs(a) // b
    return q if a >= 0 else -q

class LFSR:
    """16-bit Fibonacci LFSR, taps 16,14,13,11 (x^16+x^14+x^13+x^11+1), seed 0xACE1.
    One step per unvoiced sample; the output bit is bit 0 BEFORE the step."""
    def __init__(self): self.s = 0xACE1
    def bit(self):
        b = self.s & 1
        fb = ((self.s >> 0) ^ (self.s >> 2) ^ (self.s >> 3) ^ (self.s >> 5)) & 1
        self.s = (self.s >> 1) | (fb << 15)
        return b

class VLM5030:
    def __init__(self, rom):
        self.rom = rom
        self.reset()
        self.setup_parameter(0)
    def reset(self):
        self.old_energy = self.old_pitch = 0; self.new_energy = self.new_pitch = 0
        self.current_energy = self.current_pitch = 0; self.target_energy = self.target_pitch = 0
        self.old_k = [0]*10; self.new_k = [0]*10; self.current_k = [0]*10; self.target_k = [0]*10
        self.interp_count = self.sample_count = self.pitch_count = 0
        self.x = [0]*10
        self.lfsr = LFSR()
    def setup_parameter(self, p):
        self.interp_step = 4 if (p & 2) else (2 if (p & 1) else 1)
        self.frame_size = SPEED[(p >> 3) & 7]
        self.pitch_offset = -8 if (p & 0x80) else (8 if (p & 0x40) else 0)
    def rb(self, a): return self.rom[a] if a < len(self.rom) else 0
    def get_bits(self, sbit, bits):
        off = self.address + (sbit >> 3)
        data = self.rb(off) | (self.rb(off + 1) << 8)
        data >>= (sbit & 7)
        return data & (0xff >> (8 - bits))
    def parse_frame(self):
        self.old_energy = self.new_energy; self.old_pitch = self.new_pitch; self.old_k = list(self.new_k)
        cmd = self.rb(self.address)
        if cmd & 1:
            self.new_energy = self.new_pitch = 0; self.new_k = [0]*10
            self.address += 1
            if cmd & 2: return 0
            return ((cmd >> 2) + 1) * 2 * FR_SIZE
        self.new_pitch = PITCH[self.get_bits(1, 5)]
        if self.new_pitch > 0: self.new_pitch += self.pitch_offset
        self.new_energy = ENERGY[self.get_bits(6, 5)]
        for i in range(10):
            self.new_k[i] = K[i][self.get_bits(KSBIT[i], KBITS[i])]
        self.address += 6
        return FR_SIZE
    def start(self, table_byte):
        """ST falling edge, indirect mode: look the phrase up and run it."""
        table = (table_byte & 0xfe) + ((table_byte & 1) << 8)
        self.address = (self.rb(table) << 8) | self.rb(table + 1)
        self.sample_count = self.frame_size; self.interp_count = FR_SIZE
        self.phase = 'RUN'
    def speak(self, table_byte):
        """Samples from ST falling until BSY drops (PH_RUN, PH_STOP, PH_END)."""
        self.start(table_byte)
        out = []
        while True:
            if self.sample_count == 0:
                if self.phase == 'STOP':
                    # PH_END: one more sample, then BSY off. MAME produces no
                    # audio sample in PH_END; it only counts the stream.
                    break
                self.sample_count = self.frame_size
                if self.interp_count == 0:
                    self.interp_count = self.parse_frame()
                    if self.interp_count == 0:
                        self.interp_count = FR_SIZE; self.sample_count = self.frame_size; self.phase = 'STOP'
                    self.current_energy = self.old_energy; self.current_pitch = self.old_pitch
                    self.current_k = list(self.old_k)
                    if self.current_energy == 0:
                        self.target_energy = 0; self.target_pitch = self.current_pitch; self.target_k = list(self.current_k)
                    else:
                        self.target_energy = self.new_energy; self.target_pitch = self.new_pitch; self.target_k = list(self.new_k)
                self.interp_count -= self.interp_step
                eff = FR_SIZE - (self.interp_count % FR_SIZE)
                self.current_energy = self.old_energy + cdiv((self.target_energy - self.old_energy) * eff, FR_SIZE)
                if self.old_pitch > 1:
                    self.current_pitch = self.old_pitch + cdiv((self.target_pitch - self.old_pitch) * eff, FR_SIZE)
                for i in range(10):
                    self.current_k[i] = self.old_k[i] + cdiv((self.target_k[i] - self.old_k[i]) * eff, FR_SIZE)
            if self.old_energy == 0:
                cur = 0
            elif self.old_pitch <= 1:
                cur = self.current_energy if self.lfsr.bit() else -self.current_energy
            else:
                cur = self.current_energy if self.pitch_count == 0 else 0
            u = [0]*11; u[10] = cur
            for i in range(9, -1, -1):
                u[i] = u[i+1] - cdiv(-self.current_k[i] * self.x[i], 512)
            for i in range(9, 0, -1):
                self.x[i] = self.x[i-1] + cdiv(-self.current_k[i-1] * u[i-1], 512)
            self.x[0] = u[0]
            s = max(-512, min(511, u[0]))
            out.append(s)
            if len(out) > 400000: break        # a table entry that is not a phrase never ends
            self.sample_count -= 1
            self.pitch_count += 1
            if self.pitch_count >= self.current_pitch: self.pitch_count = 0
        return out

def write_wav(path, samples, rate=8135):
    data = b''.join(struct.pack('<h', s << 6) for s in samples)
    hdr = b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, rate, rate*2, 2, 16) + b'data' + struct.pack('<I', len(data))
    open(path, 'wb').write(hdr + data)

def main():
    image, out = sys.argv[1], sys.argv[2]
    rom = open(image, 'rb').read()[VLM_OFF:VLM_OFF + VLM_LEN]
    os.makedirs(out, exist_ok=True)
    phrases = [int(sys.argv[3])] if len(sys.argv) > 3 else list(range(0, 256, 2))
    param = int(sys.argv[4]) if len(sys.argv) > 4 else 8
    for tb in phrases:
        v = VLM5030(rom); v.setup_parameter(param)
        s = v.speak(tb)
        if len(s) <= 2 * v.frame_size + 1: continue   # empty phrase
        open(f'{out}/phrase_{tb:02x}.s16', 'wb').write(b''.join(struct.pack('<h', x << 6) for x in s))
        write_wav(f'{out}/phrase_{tb:02x}.wav', s)
        print('phrase byte %02x: %6d samples %6.0f ms  peak %4d  nonzero %5.1f%%' % (tb, len(s), len(s)/8135.33*1000, max(abs(x) for x in s), 100*sum(1 for x in s if x)/len(s)))

if __name__ == '__main__':
    main()
