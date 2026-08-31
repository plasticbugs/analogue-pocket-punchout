#!/usr/bin/env python3
"""Super Punch-Out!! protection: RP5C01 RTC + RP5H01 OTP, as MAME models them.

The executable spec for rtl/po_protect.sv (METHODOLOGY 3), and the checker for
it: replay a trace of every I/O access the real game makes to ports 05-07
(scratchpad/prot.lua) and confirm the model returns exactly what MAME returned
on every read.

  python3 tools/protection.py prot.bin

Both chips sit on the Z80's I/O ports:

  05  W   RP5H01 RESET   (d0; a 1 also clocks a 0 into DATA CLOCK/TEST)
  06  W   RP5H01 DATA CLOCK + TEST (d0)
  07  RW  RP5C01 register (selected by address bits 7-4), and on read the
          RP5H01's COUNTER OUT and DATA OUT in d6/d7

Punch-Out!! never touches these ports (MAME's own io_map calls 05-07 "spunchout
protection"), so the hardware is harmless when it is present and that game is
running -- which is why one bitstream plays both.

The RP5C01 is wired with OSCIN to Vcc and no battery, so MAME allocates it no
timers: nothing ticks, the 1 Hz and 16 Hz lines stay high, and the ALARM output
is always high. What the game actually uses is the register file's write
masking and the 13 nibbles of scratch RAM in BLOCK10/BLOCK11 mode.

The RP5H01's PROM is unprogrammed, which is a known 16-byte pattern.
"""
import sys, struct, collections

# what an unprogrammed RP5H01 reads back (MAME rp5h01.cpp, s_initial_data)
RP5H01_DATA = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
               0xff, 0xff, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00]

# RP5C01 per-mode write masks: a register that holds fewer than 4 bits reads
# back what it kept, which is the "masking" the game leans on
WRITE_MASK = [
    [0xf, 0x7, 0xf, 0x7, 0xf, 0x3, 0x7, 0xf, 0x3, 0xf, 0x1, 0xf, 0xf, 0xf, 0xf, 0xf],
    [0x0, 0x0, 0xf, 0x7, 0xf, 0x3, 0x7, 0xf, 0x3, 0x0, 0x1, 0x3, 0x0, 0xf, 0xf, 0xf],
]
REG_MODE, REG_TEST, REG_RESET = 13, 14, 15
MODE_MASK, MODE_ALARM_EN = 0x03, 0x04
RESET_ALARM = 0x01


class RP5H01:
    def __init__(self):
        self.counter = 0
        self.mode = 0x3f          # 6-bit until TEST says otherwise
        self.old_reset = 0
        self.old_clock = 0
        self.enabled = 1          # _CE is tied to GND on this board

    def reset_w(self, state):
        if not self.enabled:
            return
        if not self.old_reset and state:
            self.counter = 0
        self.old_reset = state

    def clock_w(self, state):
        if not self.enabled:
            return
        if self.old_clock and not state:     # falling edge
            self.counter = (self.counter + 1) & 0xff
        self.old_clock = state

    def test_w(self, state):
        if not self.enabled:
            return
        self.mode = 0x7f if state else 0x3f

    def counter_r(self):
        return 1 if not self.enabled else (self.counter >> 5) & 1

    def data_r(self):
        if not self.enabled:
            return 1
        byte = (self.counter & self.mode) >> 3
        bit = 7 - (self.counter & 7)
        return (RP5H01_DATA[byte] >> bit) & 1


class RP5C01:
    def __init__(self):
        self.reg = [[0] * 16, [0] * 16]    # MODE00 and MODE01 register files
        self.ram = [0] * 16                # 13 usable bytes, nibble addressed
        self.mode = 0
        self.reset = 0
        self.reg[1][10] = 1                # 12/24 select, set at device_start

    def read(self, offset):
        offset &= 0x0f
        if offset == REG_MODE:
            data = self.mode
        elif offset in (REG_TEST, REG_RESET):
            data = 0                       # write only
        else:
            m = self.mode & MODE_MASK
            if m in (0, 1):
                data = self.reg[m][offset]
            elif m == 2:
                data = self.ram[offset]
            else:
                data = self.ram[offset] >> 4
        return data & 0x0f

    def write(self, offset, data):
        offset &= 0x0f
        data &= 0x0f
        if offset == REG_MODE:
            self.mode = data
        elif offset == REG_TEST:
            pass
        elif offset == REG_RESET:
            self.reset = data
            if data & RESET_ALARM:
                for i in range(2, 9):      # the alarm registers
                    self.reg[1][i] = 0
        else:
            m = self.mode & MODE_MASK
            if m in (0, 1):
                self.reg[m][offset] = data & WRITE_MASK[m][offset]
            elif m == 2:
                self.ram[offset] = (self.ram[offset] & 0xf0) | data
            else:
                self.ram[offset] = (data << 4) | (self.ram[offset] & 0x0f)

    def alarm_r(self):
        # no oscillator on this board, so the 1 Hz and 16 Hz lines stay high
        # and m_alarm_on starts at 1: the output is always high
        return 1


class Protection:
    """The two chips as the Z80 sees them."""
    def __init__(self):
        self.rtc = RP5C01()
        self.otp = RP5H01()

    def io_w(self, port, data):
        p = port & 0x0f
        if p == 5:
            self.otp.reset_w(data & 1)
            if data & 1:
                self.otp.clock_w(0)
                self.otp.test_w(0)
        elif p == 6:
            self.otp.clock_w(data & 1)
            self.otp.test_w(data & 1)
        elif p == 7:
            self.rtc.write((port >> 4) & 0x0f, data & 0x0f)

    def io_r(self, port):
        if (port & 0x0f) != 7:
            return None
        ret = self.rtc.read((port >> 4) & 0x0f) & 0x0f
        ret |= 0x10
        ret |= 0x00 if self.rtc.alarm_r() else 0x20
        ret |= 0x00 if self.otp.counter_r() else 0x40
        ret |= 0x00 if self.otp.data_r() else 0x80
        return ret


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'prot.bin'
    d = open(path, 'rb').read()
    recs = [struct.unpack_from('<HBBB', d, i) for i in range(0, len(d) - len(d) % 5, 5)]
    p = Protection()
    reads = bad = 0
    firsts = []
    for frame, is_read, port, value in recs:
        if is_read:
            got = p.io_r(port)
            reads += 1
            if got != value:
                bad += 1
                if len(firsts) < 8:
                    firsts.append((frame, port, got, value))
        else:
            p.io_w(port, value)
    print(f'{len(recs)} accesses, {reads} reads checked against MAME, {bad} mismatched')
    for frame, port, got, want in firsts:
        print(f'  frame {frame} port {port:02x}: model {got:02x}, mame {want:02x}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
