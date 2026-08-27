// VLM5030 bench: load the speech ROM the way the core's loader does, speak the
// phrases the game uses with the parameter it uses, and hold every sample to
// tools/vlm5030.py's stream (build/vlm/phrase_XX.s16).
//   tb_vlm <punchout.rom> <model dir> <table byte>...
#include "Vpo_vlm5030.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>
static Vpo_vlm5030 *dut;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vpo_vlm5030;
    FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 2; }
    std::vector<unsigned char> rom(0x5AC00); fread(rom.data(), 1, rom.size(), f); fclose(f);
    dut->reset = 1; dut->rst = 0; dut->st = 0; dut->vcu = 0; dut->data = 0; dut->dl_we = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    for (unsigned a = 0x56C00; a < 0x5AC00; a++) {          // the loader's bytes
        dut->dl_addr = a; dut->dl_data = rom[a]; dut->dl_we = 1; tick();
    }
    dut->dl_we = 0; tick();
    int param = getenv("PARAM") ? atoi(getenv("PARAM")) : 8, failures = 0;
    for (int ai = 3; ai < argc; ai++) {
        int tb = strtol(argv[ai], nullptr, 16);
        char path[256]; snprintf(path, sizeof path, "%s/phrase_%02x.s16", argv[2], tb);
        FILE *m = fopen(path, "rb"); if (!m) { printf("phrase %02x: no model file\n", tb); continue; }
        std::vector<short> ref; short v; while (fread(&v, 2, 1, m) == 1) ref.push_back(v >> 6); fclose(m);
        // a fresh chip per phrase, as the model has (the filter state is not
        // cleared by a new phrase on the chip either, but the comparison is
        // per phrase)
        dut->reset = 1; for (int i = 0; i < 4; i++) tick(); dut->reset = 0; for (int i = 0; i < 4; i++) tick();
        // the game's sequence: parameter on the bus, RST high then low; phrase
        // byte on the bus, ST high then low
        dut->data = param; dut->rst = 1; for (int i = 0; i < 4; i++) tick();
        dut->rst = 0; for (int i = 0; i < 4; i++) tick();
        dut->data = tb; dut->st = 1; for (int i = 0; i < 4; i++) tick();
        dut->st = 0; for (int i = 0; i < 4; i++) tick();
        std::vector<int> got; long guard = 0;
        while (dut->busy && guard++ < 4000000000L) {
            tick();
            if (dut->sample_ce) got.push_back((short)((dut->sample & 0x3ff) << 6) >> 6);
        }
        long busy_samples = 0;   // report length in samples of the sample clock
        size_t n = std::min(got.size(), ref.size()); size_t bad = 0, first = 0; bool any = false;
        for (size_t i = 0; i < n; i++) if (got[i] != ref[i]) { if (!any) { first = i; any = true; } bad++; }
        bool ok = !any && got.size() == ref.size();
        printf("phrase %02x: rtl %zu samples, model %zu, %zu mismatches%s\n", tb, got.size(), ref.size(), bad + (got.size() > n ? got.size() - n : ref.size() - n),
               ok ? "  OK" : "");
        if (any) { printf("   first mismatch at %zu: rtl", first); for (size_t i = first; i < first + 8 && i < n; i++) printf(" %d", got[i]); printf("  model"); for (size_t i = first; i < first + 8 && i < n; i++) printf(" %d", ref[i]); printf("\n"); }
        if (!ok) failures++;
        for (int i = 0; i < 2000; i++) tick();
    }
    return failures ? 1 : 0;
}
