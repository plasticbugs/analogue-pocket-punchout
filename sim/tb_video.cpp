// Frozen-state video bench.
//
// Loads the ROM image once, then for every state dump captured by
// tools/dumpstate.lua injects the video RAM, renders a whole 512x672 composite
// frame and writes it out as a PPM. tools/diff_rtl.py pulls the two monitors
// back out of the composite and diffs them against the reference renderer,
// which is itself pixel-identical to MAME.
//
//   tb_video <punchout.rom> <out_dir> <state.txt> [state.txt ...]

#include "Vtb_video_top.h"
#include "Vtb_video_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <map>

static Vtb_video_top *dut;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    main_time++;
}

// --------------------------------------------------------------- state file
struct State {
    std::map<std::string, std::vector<unsigned char>> reg;
    int frame = 0, drift = 0;
};

static State load_state(const char *path) {
    State st;
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    char line[512];
    std::string cur;
    while (fgets(line, sizeof line, f)) {
        std::string s(line);
        while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
        if (s.empty() || s == "END") continue;
        if (s.rfind("frame ", 0) == 0) { st.frame = atoi(s.c_str() + 6); continue; }
        if (s.rfind("drift ", 0) == 0) { st.drift = atoi(s.c_str() + 6); continue; }
        if (s.rfind("VRAM_", 0) == 0)  { cur = s; st.reg[cur]; continue; }
        if (cur.empty()) continue;
        for (size_t i = 0; i + 1 < s.size(); i += 2)
            st.reg[cur].push_back((unsigned char)strtol(s.substr(i, 2).c_str(), nullptr, 16));
    }
    fclose(f);
    return st;
}

static std::vector<unsigned char> load_rom(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<unsigned char> d(n);
    if (fread(d.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read\n"); exit(1); }
    fclose(f);
    return d;
}

static const int W = 512, H = 672;

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) {
        fprintf(stderr, "usage: tb_video <rom> <out_dir> <state.txt> [...]\n");
        return 2;
    }
    const char *rom_path = argv[1];
    const char *out_dir  = argv[2];

    dut = new Vtb_video_top;
    dut->reset = 1; dut->dl_active = 1; dut->dl_we = 0; dut->cpu_vwe = 0;
    dut->tst_rd = 0; dut->tst_sel = 0; dut->tst_addr = 0;
    dut->spr1_ctrl = 0; dut->spr2_ctrl = 0; dut->palettebank = 0;
    for (int i = 0; i < 64; i++) tick();
    dut->reset = 0;

    // Wait for the SDRAM controller to finish its power-up sequence.
    long guard = 0;
    while (!dut->dl_ready && guard++ < 200000) tick();
    if (!dut->dl_ready) { fprintf(stderr, "SDRAM never came ready\n"); return 1; }

    // ---- ROM image, through the real loader path
    auto rom = load_rom(rom_path);
    // Arm Wrestling's image is 420,864 bytes where Punch-Out!!'s is 371,712,
    // and its bigger character regions push everything after them up.
    dut->armwrest = (rom.size() == 0x66C00);
    const unsigned IMG_GFX3 = dut->armwrest ? 0x22000 : 0x16000;
    const unsigned IMG_GFX4 = dut->armwrest ? 0x52000 : 0x46000;
    for (size_t a = 0; a < rom.size(); a++) {
        dut->dl_addr = (unsigned)a;
        dut->dl_data = rom[a];
        dut->dl_we   = 1;
        tick();
        dut->dl_we = 0;
        // Only SDRAM-bound bytes need the handshake; block RAM takes them at
        // full rate. Waiting unconditionally costs a second and keeps the
        // loader model honest.
        long g = 0;
        while (!dut->dl_ready && g++ < 1000) tick();
    }
    dut->dl_active = 0;
    for (int i = 0; i < 64; i++) tick();

    // Read the SDRAM back through the model's own array and check it against
    // the mapping po_romload is supposed to implement. A renderer fault and a
    // loader fault look identical on screen, so separate them here.
    {
        auto word = [&](unsigned byte_addr) -> unsigned {
            return dut->rootp->tb_video_top__DOT__u_model__DOT__mem[byte_addr >> 1];
        };
        auto rd = [&](unsigned byte_addr) -> unsigned char {
            unsigned w = word(byte_addr);
            return (byte_addr & 1) ? ((w >> 8) & 0xff) : (w & 0xff);
        };
        long bad = 0;
        for (unsigned t = 0; t < 0x10000 && bad < 8; t++) {          // gfx3 tile rows
            for (int p = 0; p < 3; p++) {
                unsigned char want = rom[IMG_GFX3 + p * 0x10000 + t];
                unsigned char got  = rd(t * 4 + p);
                if (want != got) {
                    fprintf(stderr, "gfx3 row %05x plane %d: sdram %02x, image %02x\n",
                            t, p, got, want);
                    bad++;
                }
            }
        }
        for (unsigned t = 0; t < 0x8000 && bad < 16; t++) {          // gfx4 tile rows
            for (int p = 0; p < 2; p++) {
                unsigned char want = rom[IMG_GFX4 + p * 0x8000 + t];
                unsigned char got  = rd(0x40000 + t * 2 + p);
                if (want != got) {
                    fprintf(stderr, "gfx4 row %05x plane %d: sdram %02x, image %02x\n",
                            t, p, got, want);
                    bad++;
                }
            }
        }
        if (bad) { fprintf(stderr, "SDRAM contents are wrong; stopping\n"); return 1; }

        // Now read a spread of the same words back through the controller, the
        // way the renderer does, and check the handshake as well as the data.
        auto sdread = [&](unsigned byte_addr) -> unsigned {
            dut->tst_addr = byte_addr & ~1u;
            dut->tst_sel = 1;
            dut->tst_rd = 1; tick(); dut->tst_rd = 0;
            for (int i = 0; i < 4; i++) tick();
            long g = 0;
            while (!dut->tst_ready && g++ < 500) tick();
            unsigned v = dut->tst_q;
            dut->tst_sel = 0;
            return v;
        };
        long rbad = 0;
        for (unsigned t = 0x1351 * 8; t < 0x1351 * 8 + 8 && rbad < 6; t++) {
            unsigned got = sdread(t * 4);
            unsigned want = rom[IMG_GFX3 + t] | (rom[IMG_GFX3 + 0x10000 + t] << 8);
            if (got != want) {
                fprintf(stderr, "controller read of tile row %05x: got %04x, want %04x\n",
                        t, got, want);
                rbad++;
            }
        }
        if (rbad) {
            fprintf(stderr, "the SDRAM controller read path is wrong, not the renderer\n");
            return 1;
        }
        printf("loaded %zu bytes, SDRAM contents and read path verified\n", rom.size());
    }

    int failures = 0;
    for (int ai = 3; ai < argc; ai++) {
        State st = load_state(argv[ai]);
        const auto &d800 = st.reg["VRAM_D800"];
        const auto &e000 = st.reg["VRAM_E000"];
        const auto &f000 = st.reg["VRAM_F000"];
        if (d800.size() != 0x800 || e000.size() != 0x1000 || f000.size() != 0x1000) {
            fprintf(stderr, "%s: unexpected region sizes\n", argv[ai]);
            return 1;
        }

        auto put = [&](unsigned base, const std::vector<unsigned char> &v) {
            for (size_t i = 0; i < v.size(); i++) {
                dut->cpu_vaddr = (unsigned)(base + i);
                dut->cpu_vdin  = v[i];
                dut->cpu_vwe   = 1;
                tick();
            }
            dut->cpu_vwe = 0;
            tick();
        };
        put(0xd800, d800);
        put(0xe000, e000);
        put(0xf000, f000);

        // The sprite control block and palette bank are registers on the CPU
        // side, so the bench presents them the way the main module will.
        uint64_t c1 = 0;
        for (int i = 0; i < 8; i++) c1 |= (uint64_t)d800[0x7f0 + i] << (8 * i);
        uint64_t c2 = 0;
        for (int i = 0; i < 5; i++) c2 |= (uint64_t)d800[0x7f8 + i] << (8 * i);
        dut->spr1_ctrl   = c1;
        dut->spr2_ctrl   = c2;
        dut->palettebank = d800[0x7fd];

        // Two vblanks: the first latches the new control registers, the second
        // starts the frame we capture.
        int vb = 0;
        guard = 0;
        while (vb < 2 && guard++ < 20000000) { tick(); if (dut->vblank_rise) vb++; }

        std::vector<unsigned char> img;
        img.reserve(W * H * 3);
        int prev_ce = 0;
        guard = 0;
        while ((int)img.size() < W * H * 3 && guard++ < 20000000) {
            tick();
            int ce = dut->ce_pix;
            if (prev_ce && !ce) {          // outputs settled at the dot edge
                if (dut->de) {
                    img.push_back(dut->vid_r);
                    img.push_back(dut->vid_g);
                    img.push_back(dut->vid_b);
                }
            }
            prev_ce = ce;
        }

        std::string tag(argv[ai]);
        size_t p = tag.find_last_of('/');
        if (p != std::string::npos) tag = tag.substr(p + 1);
        if (tag.rfind("state_", 0) == 0) tag = tag.substr(6);
        if (tag.size() > 4) tag = tag.substr(0, tag.size() - 4);

        if ((int)img.size() != W * H * 3) {
            fprintf(stderr, "%s: captured %zu pixels, expected %d\n",
                    tag.c_str(), img.size() / 3, W * H);
            failures++;
            continue;
        }
        if (dut->dbg_line_overrun) {
            fprintf(stderr, "%s: a line renderer ran past its output row "
                            "(worst %u cycles)\n", tag.c_str(), dut->dbg_worst_line);
            failures++;
        }

        char path[512];
        snprintf(path, sizeof path, "%s/rtl_%s.ppm", out_dir, tag.c_str());
        FILE *o = fopen(path, "wb");
        if (!o) { fprintf(stderr, "cannot write %s\n", path); return 1; }
        fprintf(o, "P6\n%d %d\n255\n", W, H);
        fwrite(img.data(), 1, img.size(), o);
        fclose(o);
        printf("%-8s worst line %4u cycles  -> %s\n",
               tag.c_str(), dut->dbg_worst_line, path);
    }
    return failures ? 1 : 0;
}
