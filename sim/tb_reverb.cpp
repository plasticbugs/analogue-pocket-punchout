// Impulse and full-scale tests of the cabinet reverb: tail envelope per 50 ms
// at each mode, and that a full-scale square never overflows.
#include "Vpo_reverb.h"
#include "Vpo_reverb___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
static Vpo_reverb *dut;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }
static short sample(short in) {   // one 48 kHz period: ce for one clock, then 1999 idle clocks
    dut->in = in; dut->ce = 1; tick(); dut->ce = 0;
    for (int i = 0; i < 60; i++) tick();
    short o = (short)dut->out;
    for (int i = 0; i < 1939; i++) tick();
    return o;
}
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vpo_reverb;
    for (int mode = 1; mode <= 2; mode++) {
        dut->reset = 1; dut->ce = 0; dut->mode = mode; tick(); tick(); dut->reset = 0; tick();
        std::vector<int> out;
        for (int n = 0; n < 48000; n++) out.push_back(sample(n == 0 ? 16384 : 0));
        printf("mode %d impulse 16384: out[1]=%d (dry, one sample late)\n", mode, out[1]);
        if (mode == 1) {
            // replay the first 1440 samples watching the loop's internals around the first recurrence
            dut->reset = 1; tick(); dut->reset = 0; tick();
            for (int n = 0; n < 1440; n++) {
                dut->in = (n == 0) ? 16384 : 0; dut->ce = 1; tick(); dut->ce = 0;
                for (int i = 0; i < 60; i++) tick();
                if (n < 2 || (n >= 1424 && n < 1432))
                    printf("   n=%4d wp=%4d r0=%6d lp0=%6d wd0=%6d out=%6d\n", n, dut->rootp->po_reverb__DOT__wp,
                           (short)dut->rootp->po_reverb__DOT__r0, (short)dut->rootp->po_reverb__DOT__lp0,
                           (short)dut->rootp->po_reverb__DOT__wd0, (short)dut->out);
                for (int i = 0; i < 1939; i++) tick();
            }
        }
        for (int w = 0; w < 20; w++) {
            int peak = 0; for (int n = w * 2400; n < (w + 1) * 2400; n++) if (abs(out[n]) > peak) peak = abs(out[n]);
            printf("  %3d-%3d ms: peak %5d\n", w * 50, w * 50 + 50, peak);
        }
        // full-scale square at 100 Hz for 1 s: must stay bounded (saturated), no wrap
        dut->reset = 1; tick(); dut->reset = 0; tick();
        int mx = 0, mn = 0; for (int n = 0; n < 48000; n++) { short o = sample(((n / 240) & 1) ? 32767 : -32768); if (o > mx) mx = o; if (o < mn) mn = o; }
        printf("mode %d full-scale square: output range %d .. %d\n", mode, mn, mx);
    }
    return 0;
}
