// Full-system bench: boot the machine and hold it to MAME frame for frame.
//
// Loads the ROM, releases reset, runs attract mode with no input at all, and at
// each requested frame pulls the two monitors back out of the composite and
// diffs them against MAME's own bitmaps for the same frame. Attract mode is
// deterministic from reset in both, so "the same frame" is a fair comparison.
//
//   tb_system <punchout.rom> <ref_dir> <frame> [frame ...]

#include "Vtb_system_top.h"
#include "Vtb_system_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

static Vtb_system_top *dut;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

// The video snapshot (punchout_video: the copier and its write-through).
// After every walk, once the write-through pipeline has drained, every shadow
// array must equal its live one -- unless the CPU wrote video RAM in the last
// few clocks, in which case the live copy is legitimately newer and the check
// is skipped for that frame.
static long cp_walks = 0, cp_walks_with_wr = 0, cp_wr_in_walk = 0, cp_wt = 0, cp_checked = 0, cp_bad = 0;
#define V(sig) (r->tb_system_top__DOT__u_core__DOT__u_video__DOT__##sig)
#define LANE(n, live, shadow) (r->tb_system_top__DOT__u_core__DOT__u_video__DOT__g_spr__BRA__##n##__KET____DOT__##live##__DOT__mem[i] != \
                              r->tb_system_top__DOT__u_core__DOT__u_video__DOT__g_spr__BRA__##n##__KET____DOT__##shadow##__DOT__mem[i])
template <class R> static void snapshot_check(R *r) {
    static int since_wr = 1000, since_done = 1000;
    static bool wr_this_walk = false;
    if (V(cp_wr_now)) since_wr = 0; else since_wr++;
    if (V(cp_walking) && V(cp_wr_now)) { cp_wr_in_walk++; wr_this_walk = true; }
    if (V(wt_s3)) cp_wt++;
    if (V(cp_done)) { cp_walks++; since_done = 0; if (wr_this_walk) cp_walks_with_wr++; wr_this_walk = false; }
    else since_done++;
    if (since_done != 8 || since_wr < 12) return;
    long bad = 0;
    for (int i = 0; i < 1024; i++) {
        if (V(u_bgt0__DOT__mem)[i] != V(u_sbgt0__DOT__mem)[i]) bad++;
        if (V(u_bgt1__DOT__mem)[i] != V(u_sbgt1__DOT__mem)[i]) bad++;
    }
    for (int i = 0; i < 2048; i++) {
        if (V(u_bgb0__DOT__mem)[i] != V(u_sbgb0__DOT__mem)[i]) bad++;
        if (V(u_bgb1__DOT__mem)[i] != V(u_sbgb1__DOT__mem)[i]) bad++;
    }
    for (int i = 0; i < 512; i++) {
        if (LANE(0, u_s1, u_ss1)) bad++; if (LANE(1, u_s1, u_ss1)) bad++;
        if (LANE(2, u_s1, u_ss1)) bad++; if (LANE(3, u_s1, u_ss1)) bad++;
        if (LANE(0, u_s2, u_ss2)) bad++; if (LANE(1, u_s2, u_ss2)) bad++;
        if (LANE(2, u_s2, u_ss2)) bad++; if (LANE(3, u_s2, u_ss2)) bad++;
    }
    cp_checked++;
    if (bad) { cp_bad++; if (cp_bad <= 3) printf("  snapshot %ld: %ld shadow entries differ from live\n", cp_walks, bad); }
}
#undef V
#undef LANE

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    main_time++;
}

static const int CW = 512, CH = 672, SW = 256, SH = 224, TOP_XOFF = 128, TOP_ROWS = 224;

static std::vector<unsigned char> load_file(const char *path, bool required = true) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        if (required) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
        return {};
    }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<unsigned char> d(n);
    if (fread(d.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read %s\n", path); exit(1); }
    fclose(f);
    return d;
}

// screen:pixels() writes rgb_t as a little-endian u32, so the file runs B G R A.
static std::vector<unsigned char> mame_rgb(const std::vector<unsigned char> &d) {
    std::vector<unsigned char> out(SW * SH * 3);
    for (int i = 0; i < SW * SH; i++) {
        out[i * 3 + 0] = d[i * 4 + 2];
        out[i * 3 + 1] = d[i * 4 + 1];
        out[i * 3 + 2] = d[i * 4 + 0];
    }
    return out;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) {
        fprintf(stderr, "usage: tb_system <rom> <ref_dir> <frame> [frame ...]\n");
        return 2;
    }
    const char *rom_path = argv[1];
    const char *ref_dir  = argv[2];

    std::vector<int> want;
    for (int i = 3; i < argc; i++) want.push_back(atoi(argv[i]));
    int last_frame = 0;
    for (int f : want) if (f > last_frame) last_frame = f;

    dut = new Vtb_system_top;
    // The Pocket holds the core's reset asserted for the entire download and
    // releases it afterwards; the first two hardware builds lost the whole ROM
    // to a load path that honoured that reset. So this bench does the same:
    // hw_reset (PLL lock) drops before loading, reset stays up until after.
    dut->hw_reset = 1;
    dut->reset = 1; dut->dl_active = 1; dut->dl_we = 0;
    dut->in0 = 0; dut->in1 = 0;
    dut->dsw1 = 0x00; dut->dsw2 = 0x10;      // factory defaults
    for (int i = 0; i < 64; i++) tick();
    dut->hw_reset = 0;                        // PLL locked; reset stays asserted

    long guard = 0;
    while (guard++ < 400000) tick();          // SDRAM power-up sequence

    auto rom = load_file(rom_path);
    for (size_t a = 0; a < rom.size(); a++) {
        dut->dl_addr = (unsigned)a;
        dut->dl_data = rom[a];
        dut->dl_we   = 1;
        tick();
        dut->dl_we = 0;
        // The APF bridge cannot deliver faster than this; a byte every sixteen
        // clocks is already generous next to an SPI link, and it leaves the
        // SDRAM's ~12-clock write comfortably ahead of the queue.
        for (int i = 0; i < 15; i++) tick();
    }
    dut->dl_active = 0;
    for (int i = 0; i < 4096; i++) tick();    // let the FIFO drain
    dut->reset = 0;                           // the host releases the core
    {
        // The loader goes through a write FIFO here, which the frozen-state
        // bench does not exercise. Check what actually landed.
        auto &r = *dut->rootp;
        auto rd = [&](unsigned byte_addr) -> unsigned char {
            unsigned w = r.tb_system_top__DOT__u_model__DOT__mem[byte_addr >> 1];
            return (byte_addr & 1) ? ((w >> 8) & 0xff) : (w & 0xff);
        };
        long bad = 0; unsigned firstbad = 0;
        for (unsigned t = 0; t < 0x10000 && bad < 4; t++)
            for (int p2 = 0; p2 < 3; p2++)
                if (rom[0x16000 + p2 * 0x10000 + t] != rd(t * 4 + p2)) {
                    if (!bad) firstbad = t * 4 + p2;
                    bad++;
                }
        for (unsigned t = 0; t < 0x8000 && bad < 8; t++)
            for (int p2 = 0; p2 < 2; p2++)
                if (rom[0x46000 + p2 * 0x8000 + t] != rd(0x40000 + t * 2 + p2)) {
                    if (!bad) firstbad = 0x40000 + t * 2 + p2;
                    bad++;
                }
        if (dut->dbg_load_overflow) {
            fprintf(stderr, "the loader's write queue overflowed\n");
            return 1;
        }
        if (bad) {
            fprintf(stderr, "SDRAM wrong after loading through the FIFO "
                            "(first bad byte at %06x)\n", firstbad);
            return 1;
        }
    }
    printf("loaded %zu bytes, SDRAM verified; releasing the machine\n", rom.size());
    // The core now runs its own SDRAM self-test before releasing the machine.
    // Wait for it and report what the overlay would show.
    {
        long g = 0;
        while (dut->dbg_pat_st != 1 && dut->dbg_pat_st != 2 && g++ < 20000000) tick();
        printf("self-test: ROM readback %s, pattern %s\n",
               dut->dbg_rom_st == 1 ? "PASS" : dut->dbg_rom_st == 2 ? "FAIL" : "not run",
               dut->dbg_pat_st == 1 ? "PASS" : dut->dbg_pat_st == 2 ? "FAIL" : "not run");
        if (dut->dbg_rom_st != 1 || dut->dbg_pat_st != 1) return 1;
    }

    // ---- run, capturing the requested frames
    int frame = 0;
    size_t next = 0;
    int failures = 0;
    std::vector<unsigned char> img;
    bool capturing = false;
    int prev_ce = 0;

    // 96 MHz, ~60 frames a second: a frame is about 1.6 M ticks.
    const long long limit = 2500000LL * (last_frame + 8);
    long long t = 0;
    // Track where in the raster the game writes the sprite control block: that
    // decides how late the renderer can latch it and still be current.
    int wr_min = 9999, wr_max = -1, wr_count = 0;
    bool prev_wr = false;
    static int wr_hist[64] = {0};                // raster row / 12
    while (next < want.size() && t++ < limit) {
        tick();
        if (dut->dbg_ctrl_wr && !prev_wr && (!getenv("PO_HIST_FROM") || frame >= atoi(getenv("PO_HIST_FROM")))) {
            int v = dut->dbg_ctrl_wr_vcnt;
            if (v < wr_min) wr_min = v;
            if (v > wr_max) wr_max = v;
            wr_count++;
            wr_hist[v / 12]++;
        }
        prev_wr = dut->dbg_ctrl_wr;
        // PO_VLOG=lo-hi (hex byte addresses), PO_VLOG_FROM/TO (frames): every
        // CPU write into that range, with the raster row it landed on
        if (getenv("PO_VLOG") && dut->dbg_vwe) {
            static unsigned lo = 0, hi = 0; static int f0 = 0, f1 = 1 << 30; static bool init = false;
            if (!init) { sscanf(getenv("PO_VLOG"), "%x-%x", &lo, &hi);
                         if (getenv("PO_VLOG_FROM")) f0 = atoi(getenv("PO_VLOG_FROM"));
                         if (getenv("PO_VLOG_TO"))   f1 = atoi(getenv("PO_VLOG_TO")); init = true; }
            unsigned a = dut->dbg_vaddr;
            if (a >= lo && a <= hi && frame >= f0 && frame <= f1)
                printf("vw %d %d %04x %02x\n", frame, dut->dbg_ctrl_wr_vcnt, a, dut->dbg_vdata);
        }
        // PO_WAV=<file>, PO_WAV_FROM/TO (frames): the mixed audio as raw
        // little-endian 16-bit at the sound board's rate / 37 (~48.4 kHz)
        if (getenv("PO_WAV") && dut->audio_ce) {
            static FILE *wf = nullptr; static int dec = 0; static int f0 = 0, f1 = 1 << 30;
            if (!wf) { wf = fopen(getenv("PO_WAV"), "wb");
                       if (getenv("PO_WAV_FROM")) f0 = atoi(getenv("PO_WAV_FROM"));
                       if (getenv("PO_WAV_TO"))   f1 = atoi(getenv("PO_WAV_TO")); }
            if (frame >= f0 && frame <= f1 && ++dec >= 37) { dec = 0; short v = (short)dut->audio; fwrite(&v, 2, 1, wf); }
            if (frame > f1) fflush(wf);
        }
        if (getenv("PO_VLM")) {
            static bool pb = false;
            bool b = dut->rootp->tb_system_top__DOT__u_core__DOT__u_vlm__DOT__busy;
            if (b != pb) {
                if (b) printf("vlm: frame %d BUSY on\n", frame);
                else   printf("vlm: frame %d BUSY off\n", frame);
                fflush(stdout);
            }
            pb = b;
        }
        snapshot_check(dut->rootp);
        if (dut->vblank_rise) {
            frame++;
            // PO_LOSE: the same losing fight tools/dumpstate.lua plays in MAME
            // -- coin at 200, then one tap of button 1 at 700, 900 and 1100 to
            // start the round, then stand there and be knocked out.
            if (getenv("PO_LOSE")) {
                bool coin = frame >= 200 && frame < 206;
                bool b1 = (frame >= 700 && frame < 706) || (frame >= 900 && frame < 906)
                       || (frame >= 1100 && frame < 1106);
                dut->in1 = coin ? 0x80 : 0x00;      // d7 coin, active high
                dut->in0 = b1 ? 0x01 : 0x00;        // d0 button 1 (left punch)
            }
            if (next < want.size() && frame == want[next]) {
                capturing = true;
                img.clear();
                img.reserve(CW * CH * 3);
            }
        }
        int ce = dut->ce_pix;
        if (capturing && prev_ce && !ce && dut->de) {
            img.push_back(dut->vid_r);
            img.push_back(dut->vid_g);
            img.push_back(dut->vid_b);
            if ((int)img.size() == CW * CH * 3) {
                capturing = false;
                int f = want[next++];
                char p[512];
                snprintf(p, sizeof p, "%s/pix_top_%04d.bin", ref_dir, f);
                auto rt = load_file(p, false);
                if (rt.empty()) { snprintf(p, sizeof p, "%s/pix_top_%05d.bin", ref_dir, f); rt = load_file(p); }
                snprintf(p, sizeof p, "%s/pix_bot_%04d.bin", ref_dir, f);
                auto rb = load_file(p, false);
                if (rb.empty()) { snprintf(p, sizeof p, "%s/pix_bot_%05d.bin", ref_dir, f); rb = load_file(p); }
                auto mt = mame_rgb(rt), mb = mame_rgb(rb);

                auto cmp = [&](const char *name, bool top,
                               const std::vector<unsigned char> &ref) {
                    long diff = 0;
                    for (int y = 0; y < SH; y++)
                        for (int x = 0; x < SW; x++) {
                            int o = top ? ((y * CW + TOP_XOFF + x) * 3)
                                        : (((TOP_ROWS + 2 * y) * CW + 2 * x) * 3);
                            int r = (y * SW + x) * 3;
                            if (img[o] != ref[r] || img[o + 1] != ref[r + 1] ||
                                img[o + 2] != ref[r + 2]) diff++;
                        }
                    (void)name;
                    return diff;
                };
                printf("frame %d:  (sprite control written %d times so far, "
                       "raster rows %d..%d; active video is rows 20..691)\n",
                       f, wr_count, wr_min, wr_max);
                if (getenv("PO_VRAM")) {
                    // Compare the machine's own video RAM against the state MAME
                    // dumped for this frame: a renderer fault and a CPU fault
                    // look the same on screen.
                    char sp[512];
                    snprintf(sp, sizeof sp, "%s/state_%04d.txt", ref_dir, f);
                    FILE *sf = fopen(sp, "r");
                    if (sf) {
                        char line[512]; std::string cur; std::vector<unsigned char> e000;
                        while (fgets(line, sizeof line, sf)) {
                            std::string L(line);
                            while (!L.empty() && (L.back()=='\n'||L.back()=='\r')) L.pop_back();
                            if (L.rfind("VRAM_",0)==0) { cur=L; continue; }
                            if (cur!="VRAM_E000" || L=="END" || L.empty()) continue;
                            for (size_t i=0;i+1<L.size();i+=2)
                                e000.push_back((unsigned char)strtol(L.substr(i,2).c_str(),nullptr,16));
                        }
                        fclose(sf);
                        auto &r = *dut->rootp;
                        long bad = 0; int firstbad = -1;
                        for (int t = 0; t < 512 && (int)e000.size() >= 2048; t++)
                            for (int lane = 0; lane < 4; lane++) {
                                unsigned got =
                                  lane==0 ? r.tb_system_top__DOT__u_core__DOT__u_video__DOT__g_spr__BRA__0__KET____DOT__u_s1__DOT__mem[t] :
                                  lane==1 ? r.tb_system_top__DOT__u_core__DOT__u_video__DOT__g_spr__BRA__1__KET____DOT__u_s1__DOT__mem[t] :
                                  lane==2 ? r.tb_system_top__DOT__u_core__DOT__u_video__DOT__g_spr__BRA__2__KET____DOT__u_s1__DOT__mem[t] :
                                            r.tb_system_top__DOT__u_core__DOT__u_video__DOT__g_spr__BRA__3__KET____DOT__u_s1__DOT__mem[t];
                                unsigned want = e000[t*4+lane];
                                if (got != want) { if (firstbad<0) firstbad = t*4+lane; bad++; }
                            }
                        printf("  spr1 video RAM: %ld of 2048 bytes differ from MAME%s\n",
                               bad, bad ? "" : " (identical)");
                        if (bad) printf("    first at e%03x\n", 0x000 + firstbad);
                    }
                }
                printf("  spr1 ctrl %016llx  spr2 ctrl %010llx  palbank %02x\n",
                       (unsigned long long)dut->dbg_spr1_ctrl,
                       (unsigned long long)dut->dbg_spr2_ctrl, dut->dbg_palbank);
                // The renderer takes its sprite snapshot at the start of a
                // frame; MAME takes one at the end. On an animated frame that
                // is exactly one frame of difference and nothing else, so the
                // comparison is against frame f and frame f-1, and a run passes
                // if EITHER is pixel-identical. See docs/verification.md.
                long d = cmp("top", true, mt) + cmp("bot", false, mb);
                long dprev = -1;
                snprintf(p, sizeof p, "%s/pix_top_%04d.bin", ref_dir, f - 1);
                auto rt1 = load_file(p, false);
                if (rt1.empty()) { snprintf(p, sizeof p, "%s/pix_top_%05d.bin", ref_dir, f - 1); rt1 = load_file(p, false); }
                snprintf(p, sizeof p, "%s/pix_bot_%04d.bin", ref_dir, f - 1);
                auto rb1 = load_file(p, false);
                if (rb1.empty()) { snprintf(p, sizeof p, "%s/pix_bot_%05d.bin", ref_dir, f - 1); rb1 = load_file(p, false); }
                if (!rt1.empty() && !rb1.empty()) {
                    auto mt1 = mame_rgb(rt1), mb1 = mame_rgb(rb1);
                    dprev = cmp("top", true, mt1) + cmp("bot", false, mb1);
                }
                if (d == 0)              printf("  identical to MAME frame %d\n", f);
                else if (dprev == 0)     printf("  identical to MAME frame %d "
                                                "(one frame of snapshot phase)\n", f - 1);
                else printf("  %ld differing pixels vs frame %d, %ld vs frame %d\n",
                            d, f, dprev, f - 1);
                if (dprev == 0) d = 0;
                if (getenv("PO_DUMP")) {
                    snprintf(p, sizeof p, "build/sys_%04d.ppm", f);
                    FILE *o = fopen(p, "wb");
                    fprintf(o, "P6\n%d %d\n255\n", CW, CH);
                    fwrite(img.data(), 1, img.size(), o);
                    fclose(o);
                    printf("  wrote %s\n", p);
                }
                if (d) failures++;
                if (dut->dbg_line_overrun)
                    printf("  WARNING: a line renderer ran past its output row\n");
                if (dut->dbg_dma_req)
                    printf("  WARNING: the DMC asked for a DMA, which this core does "
                           "not service\n");
            }
        }
        prev_ce = ce;
    }
    printf("snapshot walks %ld: CPU wrote video RAM during %ld of them (%ld writes, %ld written through); "
           "%ld shadows checked against live, %ld mismatched\n",
           cp_walks, cp_walks_with_wr, cp_wr_in_walk, cp_wt, cp_checked, cp_bad);
    if (cp_bad) failures++;
    if (getenv("PO_WRHIST")) {
        printf("sprite-control writes by raster row (active rows are 20..691, "
               "vblank 692..713 and 0..19):\n");
        for (int i = 0; i < 60; i++)
            if (wr_hist[i]) printf("  rows %3d-%3d: %d\n", i * 12, i * 12 + 11, wr_hist[i]);
    }
    if (next < want.size()) {
        fprintf(stderr, "ran out of time after %d frames\n", frame);
        return 1;
    }
    return failures ? 1 : 0;
}
