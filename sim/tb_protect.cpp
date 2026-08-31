// Super Punch-Out!! protection bench: replay every I/O access the real game
// makes to ports 05-07 and check the RTL returns exactly what MAME returned.
//
//   tb_protect <prot.bin>
//
// The trace is (frame u16, is_read u8, port u8, value u8) records written by
// scratchpad/prot.lua. Writes are driven into the module; reads are compared.
#include "Vpo_protect.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>

static Vpo_protect *dut;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vpo_protect;
    const char *path = argc > 1 ? argv[1] : "prot.bin";
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 2; }
    std::vector<unsigned char> log;
    unsigned char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) log.insert(log.end(), buf, buf + n);
    fclose(f);

    dut->reset = 1; dut->io_wr = 0; dut->addr = 0; dut->din = 0;
    tick(); tick();
    dut->reset = 0; tick();

    long reads = 0, writes = 0, bad = 0;
    for (size_t i = 0; i + 5 <= log.size(); i += 5) {
        unsigned frame = log[i] | (log[i + 1] << 8);
        unsigned is_read = log[i + 2], port = log[i + 3], value = log[i + 4];
        if (is_read) {
            if ((port & 0x0f) != 7) continue;      // only port 07 reads back
            dut->addr = port; dut->eval();
            unsigned got = dut->dout;
            reads++;
            if (got != value) {
                if (bad < 8)
                    printf("  frame %u port %02x: rtl %02x, mame %02x\n", frame, port, got, value);
                bad++;
            }
        } else {
            dut->addr = port; dut->din = value; dut->io_wr = 1; tick();
            dut->io_wr = 0; tick();
            writes++;
        }
    }
    printf("%ld writes replayed, %ld reads checked against MAME, %ld mismatched%s\n",
           writes, reads, bad, bad ? "" : "  OK");
    return bad ? 1 : 0;
}
