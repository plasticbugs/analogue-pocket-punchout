//------------------------------------------------------------------------------
// Punch-Out!! video.
//
// Both arcade monitors, composited into one 512x672 Pocket raster:
//
//     rows   0..223   INFO screen  (top monitor)    256x224 at 1x, x = 128..383
//     rows 224..671   FIGHT screen (bottom monitor) 512x448 at 2x, full width
//
// Neither monitor loses a pixel: the info screen is native and the fight
// screen is a clean integer double. docs/hardware.md section 9 has the why.
//
// One source line is rendered into a line buffer while the previous one is
// displayed. The top monitor needs a new line every output row; the bottom
// needs one every two rows, so it gets twice the time for its three layers.
//
// This is a transcription of tools/povideo.py, which is pixel-identical to
// MAME across sixteen frozen states. Where a rule looks arbitrary -- the
// 3740*zoom offset, the unsigned compares in the ROZ walk, the asymmetric sign
// in big sprite #2's Y -- it is arbitrary, it is what the hardware does, and
// povideo.py is where it is explained.
//
// Coordinates: MAME renders into a 256x256 bitmap and shows lines 16..239, so
// visible line L of a monitor is bitmap row L+16. Tile rows, row scroll and
// the sprite Y accumulators all work in bitmap coordinates, never in L.
//------------------------------------------------------------------------------
`default_nettype none

module punchout_video (
    input  wire         clk,              // 96 MHz
    input  wire         reset,

    //! ---- ROM download: the flat image, one byte at a time
    input  wire  [24:0] dl_addr,
    input  wire   [7:0] dl_data,
    input  wire         dl_we,

    //! ---- CPU video RAM port. This takes the CPU address itself, not an
    //!      offset from 0xd800: the three regions are 2 KB, 4 KB and 4 KB, so
    //!      an offset map has them at 0x0000, 0x0800 and 0x1800 -- not power of
    //!      two aligned, and no bit slice decodes them. Decoding the real
    //!      address is one comparison per region and the offsets fall out as
    //!      plain slices.
    //!        d800-dfff  top tilemap + sprite control registers
    //!        e000-e7ff  big sprite #1 (opponent) tilemap
    //!        e800-efff  big sprite #2 (player) tilemap
    //!        f000-ffff  bottom tilemap, first 64 bytes also the row scroll
    input  wire  [15:0] cpu_vaddr,
    input  wire   [7:0] cpu_vdin,
    input  wire         cpu_vwe,
    output logic  [7:0] cpu_vq,

    //! ---- sprite control registers and palette bank. These live in the CPU's
    //!      RAM too; the main module keeps a register copy for us.
    input  wire  [63:0] spr1_ctrl,        // dff0..dff7, byte i at [8*i +: 8]
    input  wire  [39:0] spr2_ctrl,        // dff8..dffc
    input  wire   [7:0] palettebank,      // dffd

    //! ---- SDRAM read client for gfx3 / gfx4
    output logic [24:0] sd_addr,
    output logic        sd_rd,
    input  wire  [15:0] sd_dout16,
    input  wire         sd_ready,

    //! ---- diagnostic overlay: eight 2-bit status squares along the bottom
    input  wire         ovl_en,
    input  wire  [15:0] ovl_stat,

    //! ---- video out, in the clk domain, qualified by ce_pix
    output logic        ce_pix,
    output logic        hsync,
    output logic        vsync,
    output logic        de,
    output logic  [7:0] vid_r,
    output logic  [7:0] vid_g,
    output logic  [7:0] vid_b,

    //! ---- one clk pulse at the start of vertical blanking; drives both NMIs
    output logic        vblank_rise,

    //! ---- diagnostics
    output logic        dbg_line_overrun, // a line renderer ran past its row
    output logic [11:0] dbg_worst_line,   // worst cycles taken by any line
    //! one-clock pulses, made sticky by the core for the Faults overlay:
    output logic        dbg_f_overrun,    // row started with the last line unfinished
    output logic        dbg_f_bg_short,   // ...and it was still in the background pass
    output logic        dbg_f_setup_late, // sprite geometry took > 700 clocks
    output logic        dbg_f_sd_stall    // one SDRAM read took > 96 clocks
);

    // =========================================================================
    // Raster: 560 x 714 at 24 MHz -> 60.02 Hz. MAME's 60 Hz for this driver is
    // itself a placeholder (the real totals come from a 20.16 MHz crystal and
    // are not modelled), so matching it exactly would be false precision.
    // =========================================================================
    localparam logic [9:0] H_ACTIVE = 10'd512, H_BPORCH = 10'd24, H_TOTAL = 10'd560;
    localparam logic [9:0] V_ACTIVE = 10'd672, V_BPORCH = 10'd20, V_TOTAL = 10'd714;
    localparam logic [9:0] TOP_ROWS = 10'd224;        // rows 0..223: info screen
    localparam logic [9:0] TOP_XOFF = 10'd128;        // (512 - 256) / 2, to centre it

    localparam [31:0] WIDTHSHIFTED  = 32'd128 << 16;  // both sprite tilemaps
    localparam [31:0] HEIGHTSHIFTED = 32'd256 << 16;  // are 128 x 256

    // ce_pix divides the 96 MHz system clock down to the 24 MHz dot clock, so
    // the renderer gets 2240 clocks per output row.
    //
    // That budget is why the clock is 96 and not 48. A bottom-monitor line is
    // three layers -- background, the zooming opponent, the player -- and costs
    // about 1380 cycles, most of it SDRAM latency: sdram16 spends five cycles
    // recovering after every access, so a big-sprite tile row is ~25 cycles for
    // its two reads. At 48 MHz a row is 1120 clocks and the line does not fit.
    // Rather than hide the latency behind a prefetch pipeline, which is the
    // Xenophobe sprite-engine problem all over again (METHODOLOGY 5.2), the
    // clock doubles and the renderer stays a plain sequential machine.
    logic [1:0] phase;
    always_ff @(posedge clk) phase <= reset ? 2'd0 : phase + 2'd1;
    assign ce_pix = (phase == 2'd3);

    logic [9:0] hcnt, vcnt;
    always_ff @(posedge clk) begin
        if (reset) begin
            hcnt <= '0;
            vcnt <= '0;
        end else if (ce_pix) begin
            if (hcnt == H_TOTAL - 10'd1) begin
                hcnt <= '0;
                vcnt <= (vcnt == V_TOTAL - 10'd1) ? '0 : vcnt + 1'd1;
            end else begin
                hcnt <= hcnt + 1'd1;
            end
        end
    end

    wire        h_act = (hcnt >= H_BPORCH) && (hcnt < H_BPORCH + H_ACTIVE);
    wire        v_act = (vcnt >= V_BPORCH) && (vcnt < V_BPORCH + V_ACTIVE);
    wire [9:0]  act_x = hcnt - H_BPORCH;
    wire [9:0]  act_y = vcnt - V_BPORCH;
    wire        raw_hs = (hcnt < 10'd8);
    wire        raw_vs = (vcnt < 10'd4);
    wire        raw_de = h_act && v_act;

    logic v_act_d;
    always_ff @(posedge clk) begin
        if (reset) begin
            v_act_d     <= 1'b0;
            vblank_rise <= 1'b0;
        end else begin
            v_act_d     <= v_act;
            vblank_rise <= v_act_d && !v_act;
        end
    end

    // =========================================================================
    // Video RAM.
    //
    // Split by byte lane rather than made wide with byte enables: partial
    // selects do not infer byte enables in Quartus and explode into registers
    // (METHODOLOGY 5.5). Separate lanes also let the renderer read a whole tile
    // entry in a single cycle.
    // =========================================================================
    wire vsel_top = (cpu_vaddr[15:11] == 5'b11011); // d800-dfff
    wire vsel_spr = (cpu_vaddr[15:12] == 4'b1110);  // e000-efff
    wire vsel_bot = (cpu_vaddr[15:12] == 4'b1111);  // f000-ffff
    wire spr_hi   = cpu_vaddr[11];                  // 0 = spr1, 1 = spr2

    logic  [9:0] bgt_ridx;
    logic [10:0] bgb_ridx;
    logic  [8:0] s1_ridx, s2_ridx;
    logic  [7:0] bgt_code, bgt_attr, bgb_code, bgb_attr;
    logic  [7:0] bgt_q0, bgt_q1, bgb_q0, bgb_q1;
    logic  [7:0] s1_b [0:3];
    logic  [7:0] s2_b [0:3];
    logic  [7:0] s1_cq [0:3];
    logic  [7:0] s2_cq [0:3];

    po_dpram #(.AW(10), .DW(8)) u_bgt0 (.clk(clk),
        .a_addr(cpu_vaddr[10:1]), .a_we(cpu_vwe && vsel_top && !cpu_vaddr[0]),
        .a_d(cpu_vdin), .a_q(bgt_q0),
        .b_addr(bgt_ridx), .b_we(1'b0), .b_d(8'h00), .b_q(bgt_code));
    po_dpram #(.AW(10), .DW(8)) u_bgt1 (.clk(clk),
        .a_addr(cpu_vaddr[10:1]), .a_we(cpu_vwe && vsel_top &&  cpu_vaddr[0]),
        .a_d(cpu_vdin), .a_q(bgt_q1),
        .b_addr(bgt_ridx), .b_we(1'b0), .b_d(8'h00), .b_q(bgt_attr));
    po_dpram #(.AW(11), .DW(8)) u_bgb0 (.clk(clk),
        .a_addr(cpu_vaddr[11:1]), .a_we(cpu_vwe && vsel_bot && !cpu_vaddr[0]),
        .a_d(cpu_vdin), .a_q(bgb_q0),
        .b_addr(bgb_ridx), .b_we(1'b0), .b_d(8'h00), .b_q(bgb_code));
    po_dpram #(.AW(11), .DW(8)) u_bgb1 (.clk(clk),
        .a_addr(cpu_vaddr[11:1]), .a_we(cpu_vwe && vsel_bot &&  cpu_vaddr[0]),
        .a_d(cpu_vdin), .a_q(bgb_q1),
        .b_addr(bgb_ridx), .b_we(1'b0), .b_d(8'h00), .b_q(bgb_attr));

    generate
        genvar lane;
        for (lane = 0; lane < 4; lane++) begin : g_spr
            po_dpram #(.AW(9), .DW(8)) u_s1 (.clk(clk),
                .a_addr(cpu_vaddr[10:2]),
                .a_we(cpu_vwe && vsel_spr && !spr_hi && (cpu_vaddr[1:0] == lane[1:0])),
                .a_d(cpu_vdin), .a_q(s1_cq[lane]),
                .b_addr(s1_ridx), .b_we(1'b0), .b_d(8'h00), .b_q(s1_b[lane]));
            po_dpram #(.AW(9), .DW(8)) u_s2 (.clk(clk),
                .a_addr(cpu_vaddr[10:2]),
                .a_we(cpu_vwe && vsel_spr &&  spr_hi && (cpu_vaddr[1:0] == lane[1:0])),
                .a_d(cpu_vdin), .a_q(s2_cq[lane]),
                .b_addr(s2_ridx), .b_we(1'b0), .b_d(8'h00), .b_q(s2_b[lane]));
        end
    endgenerate

    // CPU read-back, one cycle behind the address, same as the memories.
    logic [1:0] cq_lane;
    logic       cq_low, cq_top, cq_spr, cq_bot, cq_hi;
    always_ff @(posedge clk) begin
        cq_lane <= cpu_vaddr[1:0];
        cq_low  <= cpu_vaddr[0];
        cq_top  <= vsel_top;
        cq_spr  <= vsel_spr;
        cq_bot  <= vsel_bot;
        cq_hi   <= spr_hi;
    end
    always_comb begin
        if      (cq_top) cpu_vq = cq_low ? bgt_q1 : bgt_q0;
        else if (cq_bot) cpu_vq = cq_low ? bgb_q1 : bgb_q0;
        else if (cq_spr) cpu_vq = cq_hi ? s2_cq[cq_lane] : s1_cq[cq_lane];
        else             cpu_vq = 8'hff;
    end

    // -------------------------------------------------------------------------
    // Per-row scroll shadow. f000-f03f is both tilemap row 0 (off screen) and
    // the scroll table. Shadowed on write, latched once per frame, so the two
    // monitors cannot disagree about it.
    // -------------------------------------------------------------------------
    logic [8:0] rs_shadow [0:31];
    wire        rs_hit = cpu_vwe && vsel_bot && (cpu_vaddr[11:6] == 6'd0);
    wire  [4:0] rs_idx = cpu_vaddr[5:1];

    integer ri;
    always_ff @(posedge clk) begin
        if (reset) begin
            for (ri = 0; ri < 32; ri++) rs_shadow[ri] <= '0;
        end else if (rs_hit) begin
            if (cpu_vaddr[0]) rs_shadow[rs_idx][8]   <= cpu_vdin[0];
            else              rs_shadow[rs_idx][7:0] <= cpu_vdin;
        end
    end

    // =========================================================================
    // Graphics ROMs held in block RAM: the two background character sets, one
    // memory per bit plane so a tile row is a single read. gfx3 and gfx4 are
    // far too big for block RAM and live in SDRAM (docs/hardware.md section 9).
    // =========================================================================
    localparam [24:0] BASE_GFX1 = 25'h0E000;
    localparam [24:0] BASE_GFX2 = 25'h12000;
    localparam [24:0] BASE_GFX3 = 25'h16000;
    localparam [24:0] BASE_PROM = 25'h56000;
    localparam [24:0] END_PROM  = 25'h56C00;

    wire        in_gfx1 = (dl_addr >= BASE_GFX1) && (dl_addr < BASE_GFX2);
    wire        in_gfx2 = (dl_addr >= BASE_GFX2) && (dl_addr < BASE_GFX3);
    wire        in_prom = (dl_addr >= BASE_PROM) && (dl_addr < END_PROM);
    wire [13:0] g1_off  = dl_addr[13:0] - BASE_GFX1[13:0];
    wire [13:0] g2_off  = dl_addr[13:0] - BASE_GFX2[13:0];
    wire [11:0] pr_off  = dl_addr[11:0] - BASE_PROM[11:0];

    logic [12:0] gfx_ridx;
    logic  [7:0] g1_p0, g1_p1, g2_p0, g2_p1;

    po_spram_dp #(.AW(13), .DW(8)) u_g1p0 (.clk(clk), .wa(g1_off[12:0]),
        .we(dl_we && in_gfx1 && !g1_off[13]), .d(dl_data), .ra(gfx_ridx), .q(g1_p0));
    po_spram_dp #(.AW(13), .DW(8)) u_g1p1 (.clk(clk), .wa(g1_off[12:0]),
        .we(dl_we && in_gfx1 &&  g1_off[13]), .d(dl_data), .ra(gfx_ridx), .q(g1_p1));
    po_spram_dp #(.AW(13), .DW(8)) u_g2p0 (.clk(clk), .wa(g2_off[12:0]),
        .we(dl_we && in_gfx2 && !g2_off[13]), .d(dl_data), .ra(gfx_ridx), .q(g2_p0));
    po_spram_dp #(.AW(13), .DW(8)) u_g2p1 (.clk(clk), .wa(g2_off[12:0]),
        .we(dl_we && in_gfx2 &&  g2_off[13]), .d(dl_data), .ra(gfx_ridx), .q(g2_p1));

    // Six 512-byte colour PROMs, low nibble only. Address is {bank, index}.
    logic [8:0] pal_ra;
    logic [7:0] prom_q [0:5];
    generate
        genvar pn;
        for (pn = 0; pn < 6; pn++) begin : g_prom
            po_spram_dp #(.AW(9), .DW(8)) u_prom (.clk(clk), .wa(pr_off[8:0]),
                .we(dl_we && in_prom && (pr_off[11:9] == pn[2:0])),
                .d(dl_data), .ra(pal_ra), .q(prom_q[pn]));
        end
    endgenerate

    // =========================================================================
    // Big sprite geometry, computed at the start of EVERY line from the live
    // control registers -- the way the board reads them.
    //
    // It was once per frame, latched at a single instant in vertical blanking.
    // Two instants were tried. At the start of vblank the latch preceded the
    // NMI handler's writes and the sprite ran a frame behind MAME. Near the
    // end of vblank it landed in the MIDDLE of those writes often enough to
    // capture a torn block -- a new Y low byte with the old high bit, say --
    // and the sprite spent one frame 256 lines away: on the Pocket, a black
    // band the sprite's width, flashing, whenever the opponent came in close
    // to gloat. The board never has that problem because it reads the
    // registers as the beam scans; a torn value there costs one scanline.
    //
    // So this does the same. The arithmetic is ~10 clocks and the skip loop
    // at most 255 per sprite, inside a 2240-clock row whose worst measured
    // render is ~1520. The row-scroll table and the palette bank are read
    // live for the same reason.
    // =========================================================================
    logic [7:0]  c1 [0:7];
    logic [7:0]  c2 [0:4];
    logic [11:0] zoom;
    logic        spr1_top_en, spr1_bot_en;

    logic signed [31:0] incxx1, incyy1, incxx2;
    logic        [31:0] startx1, starty1_init, startx2, starty2_init;
    logic         [8:0] sx1, sx2;
    logic               spr1_on, spr2_on;

    logic signed [14:0] sxv1, syv1, sxv2, syv2;
    logic        [31:0] sk_x;
    logic         [8:0] sk_n;

    typedef enum logic [3:0] {
        FS_IDLE, FS_LATCH, FS_CALC1, FS_CALC2, FS_CALC3,
        FS_SEED1, FS_SKIP1, FS_SEED2, FS_SKIP2, FS_DONE
    } fstate_e;
    fstate_e fst;

    wire signed [14:0] x1raw = $signed({3'b000, c1[3][3:0], c1[2]});
    wire signed [14:0] y1raw = $signed({6'b0, c1[5][0], c1[4]});
    wire signed [14:0] x2raw = $signed({6'b0, c2[1][0], c2[0]});
    wire signed [14:0] sx1t  = 15'sd4096 - x1raw;
    wire signed [14:0] sy1t  = -y1raw;
    wire signed [14:0] sx2t  = 15'sd512  - x2raw;
    wire signed [14:0] zoom64 = $signed({9'b0, zoom[11:6]});   // zoom / 0x40

    integer li;
    always_ff @(posedge clk) begin
        if (reset) begin
            fst     <= FS_IDLE;
            spr1_on <= 1'b0;
            spr2_on <= 1'b0;
        end else begin
            case (fst)
                FS_IDLE: if (row_start) fst <= FS_LATCH;

                FS_LATCH: begin
                    for (li = 0; li < 8; li++) c1[li] <= spr1_ctrl[8*li +: 8];
                    for (li = 0; li < 5; li++) c2[li] <= spr2_ctrl[8*li +: 8];
                    spr1_top_en <= spr1_ctrl[56];       // dff7 bit 0
                    spr1_bot_en <= spr1_ctrl[57];       // dff7 bit 1
                    zoom        <= {spr1_ctrl[11:8], spr1_ctrl[7:0]};
                    fst         <= FS_CALC1;
                end

                FS_CALC1: begin
                    sxv1 <= (sx1t > 15'sd3588) ? (sx1t - 15'sd4096) : sx1t;
                    syv1 <= (sy1t <= (-15'sd256 + zoom64)) ? (sy1t + 15'sd512 + 15'sd12)
                                                          : (sy1t + 15'sd12);
                    sxv2 <= (sx2t > 15'sd385) ? (sx2t - 15'sd512 - 15'sd55)
                                              : (sx2t - 15'sd55);
                    // Not symmetrical with sx, and not a typo: the driver is
                    // -ctrl[2] + 256*bit, so the high bit adds rather than
                    // extending the negation.
                    syv2 <= -$signed({7'b0, c2[2]}) + (c2[3][0] ? 15'sd256 : 15'sd0) + 15'sd3;
                    fst  <= FS_CALC2;
                end

                FS_CALC2: begin
                    incyy1 <= $signed({20'b0, zoom}) <<< 6;
                    incxx1 <= c1[6][0] ? -($signed({20'b0, zoom}) <<< 6)
                                       :  ($signed({20'b0, zoom}) <<< 6);
                    incxx2 <= c2[4][0] ? -32'sh0001_0000 : 32'sh0001_0000;
                    fst    <= FS_CALC3;
                end

                FS_CALC3: begin
                    // startx = -sx*0x4000 + 3740*zoom, folded for flip.
                    // starty = -sy*0x10000 - 178*zoom + 0x400*zoom, then the
                    // cliprect.top pre-advance of 16 lines.
                    startx1 <= c1[6][0]
                        ? (WIDTHSHIFTED - 32'((-32'sd1 * 32'(sxv1)) * 32'sd16384 + 32'sd3740 * $signed({20'b0, zoom})) - 32'd1)
                        :                 32'((-32'sd1 * 32'(sxv1)) * 32'sd16384 + 32'sd3740 * $signed({20'b0, zoom}));
                    starty1_init <= 32'((-32'sd1 * 32'(syv1)) * 32'sd65536
                                        + 32'sd846 * $signed({20'b0, zoom}))   // 1024 - 178
                                    + 32'(incyy1 * 32'sd16);
                    startx2 <= c2[4][0]
                        ? (WIDTHSHIFTED - 32'((-32'sd1 * 32'(sxv2)) * 32'sd65536) - 32'd1)
                        :                 32'((-32'sd1 * 32'(sxv2)) * 32'sd65536);
                    starty2_init <= 32'((-32'sd1 * 32'(syv2)) * 32'sd65536) + (32'd16 << 16);
                    fst <= FS_SEED1;
                end

                // "skip without drawing until we are within the bitmap" from
                // draw_roz_core. It applies to the whole draw, not to each
                // line, so it is done once here. At most 256 iterations.
                FS_SEED1: begin
                    sk_x <= startx1;
                    sk_n <= 9'd0;
                    fst  <= FS_SKIP1;
                end
                FS_SKIP1: begin
                    if (sk_x >= WIDTHSHIFTED && sk_n <= 9'd255) begin
                        sk_x <= sk_x + 32'(incxx1);
                        sk_n <= sk_n + 9'd1;
                    end else begin
                        startx1 <= sk_x;
                        sx1     <= sk_n;
                        spr1_on <= (zoom != 12'd0) && (sk_n <= 9'd255);
                        fst     <= FS_SEED2;
                    end
                end
                FS_SEED2: begin
                    sk_x <= startx2;
                    sk_n <= 9'd0;
                    fst  <= FS_SKIP2;
                end
                FS_SKIP2: begin
                    if (sk_x >= WIDTHSHIFTED && sk_n <= 9'd255) begin
                        sk_x <= sk_x + 32'(incxx2);
                        sk_n <= sk_n + 9'd1;
                    end else begin
                        startx2 <= sk_x;
                        sx2     <= sk_n;
                        spr2_on <= (sk_n <= 9'd255);
                        fst     <= FS_DONE;
                    end
                end

                FS_DONE: fst <= FS_IDLE;
                default: fst <= FS_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Line renderer
    // =========================================================================
    // Which source line the next output row wants. A bottom-monitor line is
    // shown for two rows, so only the first of the pair asks for a render.
    wire [9:0] next_row  = (act_y == V_ACTIVE - 10'd1) ? 10'd0 : act_y + 10'd1;
    wire       next_top  = (next_row < TOP_ROWS);
    wire [9:0] bot_row   = next_row - TOP_ROWS;
    wire [7:0] next_line = next_top ? next_row[7:0] : bot_row[8:1];

    logic       lb_sel;             // buffer the display reads
    logic [7:0] rend_line;          // source line 0..223
    logic       rend_top;
    wire  [7:0] vy      = rend_line + 8'd16;   // MAME bitmap row
    wire  [7:0] next_vy = next_line + 8'd16;

    // lb_sel names the buffer the DISPLAY reads; the renderer fills the other.
    logic [7:0] lb_wa, lb_wd;
    logic       lb_we;
    logic [7:0] lb0_q, lb1_q;


    wire row_start = (hcnt == 10'd0) && ce_pix;

    typedef enum logic [4:0] {
        R_IDLE, R_SETUP,
        R_BG_INIT, R_BG_A, R_BG_B, R_BG_C, R_BG_EMIT,
        R_S1_START, R_S1_TILE, R_S1_TW, R_S1_R0, R_S1_R1, R_S1_EMIT,
        R_S2_START, R_S2_TILE, R_S2_TW, R_S2_R, R_S2_EMIT,
        R_DONE
    } rstate_e;
    rstate_e rs;

    // background walk
    logic [4:0] bg_col;        // top map column 0..31
    logic [8:0] bg_x;          // output pixel 0..256
    logic [8:0] bg_tx;         // bottom map tilemap x, wraps at 512
    logic [2:0] bg_i;          // pixel within the fetched tile
    logic [7:0] bg_p0, bg_p1;
    logic [4:0] bg_color;
    logic       bg_flipx;

    // sprite walk (shared by both engines)
    logic [31:0] cx;
    logic  [8:0] px;
    logic  [7:0] cy;
    logic  [3:0] tile_col;
    logic        tile_valid;
    logic  [7:0] rp0, rp1, rp2;
    logic  [5:0] sp_color;
    logic        sp_flipx;
    logic [12:0] sp_code;
    logic  [2:0] sd_wait;

    // cx < WIDTHSHIFTED is guaranteed while walking, so the source pixel is
    // cx[22:16]: tile column cx[22:19], pixel within it cx[18:16].
    wire [3:0] src_col = cx[22:19];
    wire [2:0] src_sub = cx[18:16];

    wire [2:0] bg_bit  = bg_flipx ? bg_i : (3'd7 - bg_i);
    wire [1:0] bg_pen  = {bg_p1[bg_bit], bg_p0[bg_bit]};
    wire [2:0] sp_bit  = sp_flipx ? src_sub : (3'd7 - src_sub);
    wire [2:0] sp1_pen = {rp2[sp_bit], rp1[sp_bit], rp0[sp_bit]};
    wire [1:0] sp2_pen = {rp1[sp_bit], rp0[sp_bit]};

    assign bgt_ridx = {vy[7:3], bg_col};
    assign bgb_ridx = {vy[7:3], bg_tx[8:3]};
    // tile code is 10 bits: attr[1:0] are the high bits. Address = code*8 + row.
    assign gfx_ridx = rend_top ? {bgt_attr[1:0], bgt_code, vy[2:0]}
                               : {bgb_attr[1:0], bgb_code, vy[2:0]};
    assign s1_ridx  = {cy[7:3], src_col};
    assign s2_ridx  = {cy[7:3], src_col};

    // Source Y for the two big sprites, computed from the line number rather
    // than accumulated. draw_roz_core steps starty once per screen line, so
    // line L wants starty_init + L*incyy -- and a bottom line is rendered once
    // for each of its two output rows, which an accumulator would step twice.
    // Registered, not wired straight into the sprite state machine. rend_line
    // is stable for the whole row, so these settle one clock after row_start
    // and are read hundreds of clocks later -- but left combinational the
    // 32-bit multiply landed in the path that decides the next state, and it
    // was the other path still missing 96 MHz.
    wire signed [31:0] line_s = $signed({24'b0, rend_line});
    logic       [31:0] s1y, s2y;
    always_ff @(posedge clk) begin
        s1y <= starty1_init + 32'(incyy1 * line_s);
        s2y <= starty2_init + 32'(line_s <<< 16);
    end

    logic [11:0] line_cycles;
    logic [11:0] setup_cyc;
    logic  [7:0] sd_cyc;

    always_ff @(posedge clk) begin
        if (reset) begin
            rs             <= R_IDLE;
            lb_sel         <= 1'b0;
            dbg_line_overrun <= 1'b0;
            dbg_worst_line <= '0;
            line_cycles    <= '0;
            setup_cyc      <= '0;
            sd_cyc         <= '0;
            sd_rd          <= 1'b0;
            lb_we          <= 1'b0;
            dbg_f_overrun <= 1'b0; dbg_f_bg_short <= 1'b0;
            dbg_f_setup_late <= 1'b0; dbg_f_sd_stall <= 1'b0;
        end else begin
            lb_we <= 1'b0;
            sd_rd <= 1'b0;

            if (vblank_rise) begin
                dbg_line_overrun <= 1'b0;
                dbg_worst_line   <= '0;
            end

            if (rs != R_IDLE) line_cycles <= line_cycles + 12'd1;

            dbg_f_overrun    <= 1'b0;
            dbg_f_bg_short   <= 1'b0;
            dbg_f_setup_late <= 1'b0;
            dbg_f_sd_stall   <= 1'b0;
            if (rs == R_SETUP) begin
                if (setup_cyc != 12'hfff) setup_cyc <= setup_cyc + 12'd1;
                if (setup_cyc == 12'd700) dbg_f_setup_late <= 1'b1;
            end else setup_cyc <= '0;
            if (rs == R_S1_R0 || rs == R_S1_R1 || rs == R_S2_R) begin
                if (sd_cyc != 8'hff) sd_cyc <= sd_cyc + 8'd1;
                if (sd_cyc == 8'd96) dbg_f_sd_stall <= 1'b1;
            end else sd_cyc <= '0;

            if (row_start) begin
                if (rs != R_IDLE) dbg_line_overrun <= 1'b1;
                if (rs != R_IDLE) dbg_f_overrun <= 1'b1;
                if (rs == R_SETUP || rs == R_BG_INIT || rs == R_BG_A || rs == R_BG_B
                    || rs == R_BG_C || rs == R_BG_EMIT) dbg_f_bg_short <= 1'b1;
                if (line_cycles > dbg_worst_line) dbg_worst_line <= line_cycles;
                line_cycles <= '0;

                lb_sel    <= ~lb_sel;
                rend_top  <= next_top;
                rend_line <= next_line;
                bg_col    <= '0;
                bg_x      <= '0;
                rs        <= R_SETUP;
            end else begin
                case (rs)
                    R_IDLE: ;
                    // the sprite geometry for this line is being computed
                    R_SETUP: if (fst == FS_DONE) rs <= R_BG_INIT;

                    // ---------------- background ----------------
                    // The row-scroll lookup happens HERE rather than at
                    // row_start. There it was a 32-entry mux hanging off the
                    // raster counter -- vcnt through act_y, next_row, next_line
                    // and a shift before it even reached the mux -- and it was
                    // one of the two paths still missing 96 MHz. From a
                    // registered rend_line it is just an add and the mux, and
                    // the line can spare the cycle.
                    R_BG_INIT: begin
                        bg_tx <= rend_top ? 9'd0 : (rs_shadow[vy[7:3]] + 9'd58);
                        rs    <= R_BG_A;
                    end
                    // Address is already stable from the previous state, so
                    // A settles the tilemap read, B settles the gfx read.
                    R_BG_A: rs <= R_BG_B;
                    R_BG_B: begin
                        bg_color <= rend_top ? bgt_attr[6:2] : bgb_attr[6:2];
                        bg_flipx <= rend_top ? bgt_attr[7]   : bgb_attr[7];
                        rs       <= R_BG_C;
                    end
                    R_BG_C: begin
                        bg_p0 <= rend_top ? g1_p0 : g2_p0;
                        bg_p1 <= rend_top ? g1_p1 : g2_p1;
                        bg_i  <= rend_top ? 3'd0 : bg_tx[2:0];
                        rs    <= R_BG_EMIT;
                    end
                    R_BG_EMIT: begin
                        lb_we <= 1'b1;
                        lb_wa <= bg_x[7:0];
                        lb_wd <= {1'b0, bg_color, bg_pen};
                        bg_x  <= bg_x + 9'd1;
                        if (!rend_top) bg_tx <= bg_tx + 9'd1;
                        if (bg_x == 9'd255) begin
                            rs <= R_S1_START;
                        end else if (bg_i == 3'd7) begin
                            bg_col <= bg_col + 5'd1;
                            rs     <= R_BG_A;
                        end else begin
                            bg_i <= bg_i + 3'd1;
                        end
                    end

                    // ---------------- big sprite #1 ----------------
                    R_S1_START: begin
                        tile_valid <= 1'b0;
                        px <= {1'b0, sx1[7:0]};
                        cx <= startx1;
                        cy <= s1y[23:16];
                        if (!spr1_on || (sx1 > 9'd255)
                            || (rend_top ? !spr1_top_en : !spr1_bot_en)
                            || (s1y >= HEIGHTSHIFTED))
                            rs <= R_S2_START;
                        else
                            rs <= R_S1_TILE;
                    end
                    R_S1_TILE: begin
                        if (tile_valid && tile_col == src_col) begin
                            rs <= R_S1_EMIT;
                        end else begin
                            tile_col <= src_col;
                            rs       <= R_S1_TW;
                        end
                    end
                    R_S1_TW: begin
                        sp_code  <= {s1_b[1][4:0], s1_b[0]};
                        sp_color <= {1'b0, s1_b[3][4:0]};
                        sp_flipx <= s1_b[3][7];
                        // gfx3 is stored one tile row per four bytes:
                        // +0 plane0, +1 plane1, +2 plane2. Two 16-bit reads.
                        sd_addr  <= {7'b0, s1_b[1][4:0], s1_b[0], cy[2:0], 2'b00};
                        sd_rd    <= 1'b1;
                        sd_wait  <= 3'd3;
                        rs       <= R_S1_R0;
                    end
                    R_S1_R0: begin
                        // sdram16 answers a repeat of the previous word from
                        // its cache without ever dropping ready, so waiting for
                        // a falling edge would hang. Settle, then poll.
                        if (sd_wait != 3'd0) sd_wait <= sd_wait - 3'd1;
                        else if (sd_ready) begin
                            rp0     <= sd_dout16[7:0];
                            rp1     <= sd_dout16[15:8];
                            sd_addr <= {7'b0, sp_code, cy[2:0], 2'b10};
                            sd_rd   <= 1'b1;
                            sd_wait <= 3'd3;
                            rs      <= R_S1_R1;
                        end
                    end
                    R_S1_R1: begin
                        if (sd_wait != 3'd0) sd_wait <= sd_wait - 3'd1;
                        else if (sd_ready) begin
                            rp2        <= sd_dout16[7:0];
                            tile_valid <= 1'b1;
                            rs         <= R_S1_EMIT;
                        end
                    end
                    R_S1_EMIT: begin
                        if (sp1_pen != 3'd7) begin
                            lb_we <= 1'b1;
                            lb_wa <= px[7:0];
                            lb_wd <= {sp_color[4:0], sp1_pen};
                        end
                        if (px == 9'd255 || (cx + 32'(incxx1)) >= WIDTHSHIFTED) begin
                            rs <= R_S2_START;
                        end else begin
                            px <= px + 9'd1;
                            cx <= cx + 32'(incxx1);
                            rs <= R_S1_TILE;
                        end
                    end

                    // ---------------- big sprite #2, bottom monitor only ----
                    R_S2_START: begin
                        tile_valid <= 1'b0;
                        px <= {1'b0, sx2[7:0]};
                        cx <= startx2;
                        cy <= s2y[23:16];
                        if (rend_top || !spr2_on || (sx2 > 9'd255)
                            || (s2y >= HEIGHTSHIFTED))
                            rs <= R_DONE;
                        else
                            rs <= R_S2_TILE;
                    end
                    R_S2_TILE: begin
                        if (tile_valid && tile_col == src_col) begin
                            rs <= R_S2_EMIT;
                        end else begin
                            tile_col <= src_col;
                            rs       <= R_S2_TW;
                        end
                    end
                    R_S2_TW: begin
                        sp_color <= s2_b[3][5:0];
                        sp_flipx <= s2_b[3][7];
                        // gfx4 is two bytes per tile row: +0 plane0, +1 plane1,
                        // so one 16-bit read has both planes.
                        sd_addr  <= 25'h4_0000 + {9'b0, s2_b[1][3:0], s2_b[0], cy[2:0], 1'b0};
                        sd_rd    <= 1'b1;
                        sd_wait  <= 3'd3;
                        rs       <= R_S2_R;
                    end
                    R_S2_R: begin
                        if (sd_wait != 3'd0) sd_wait <= sd_wait - 3'd1;
                        else if (sd_ready) begin
                            rp0        <= sd_dout16[7:0];
                            rp1        <= sd_dout16[15:8];
                            tile_valid <= 1'b1;
                            rs         <= R_S2_EMIT;
                        end
                    end
                    R_S2_EMIT: begin
                        if (sp2_pen != 2'd3) begin
                            lb_we <= 1'b1;
                            lb_wa <= px[7:0];
                            lb_wd <= {sp_color, sp2_pen};
                        end
                        if (px == 9'd255 || (cx + 32'(incxx2)) >= WIDTHSHIFTED) begin
                            rs <= R_DONE;
                        end else begin
                            px <= px + 9'd1;
                            cx <= cx + 32'(incxx2);
                            rs <= R_S2_TILE;
                        end
                    end

                    R_DONE: rs <= R_IDLE;

                    default: rs <= R_IDLE;
                endcase
            end
        end
    end

    // =========================================================================
    // Display. Three pixel-clock stages: line buffer read, PROM read, output
    // register. Sync and blanking are delayed by the same three so they still
    // line up with the colour.
    // =========================================================================
    wire       disp_top = (act_y < TOP_ROWS);
    wire       in_info  = disp_top && (act_x >= TOP_XOFF)
                                   && (act_x <  TOP_XOFF + 10'd256);
    wire [7:0] disp_x   = disp_top ? 8'(act_x - TOP_XOFF) : act_x[8:1];
    wire       show     = raw_de && (disp_top ? in_info : 1'b1);

    po_spram_re #(.AW(8), .DW(8)) u_lb0 (.clk(clk),
        .wa(lb_wa), .we(lb_we &&  lb_sel), .d(lb_wd),
        .ra(disp_x), .re(ce_pix), .q(lb0_q));
    po_spram_re #(.AW(8), .DW(8)) u_lb1 (.clk(clk),
        .wa(lb_wa), .we(lb_we && !lb_sel), .d(lb_wd),
        .ra(disp_x), .re(ce_pix), .q(lb1_q));
    wire [7:0] lb_rd = lb_sel ? lb1_q : lb0_q;

    // Diagnostic overlay: eight 12x8 squares in the bottom eight rows, at the
    // left of the fight screen, colour from two status bits each. Hidden
    // behind a menu option. Cheap, and the only way to see inside a fault that
    // only shows on real hardware (METHODOLOGY 4).
    wire        ovl_row  = ovl_en && (act_y >= 10'd664);
    wire  [2:0] ovl_idx  = act_x[6:4];
    wire        ovl_cell = ovl_row && (act_x < 10'd128)
                        && (act_x[3:0] >= 4'd2) && (act_x[3:0] < 4'd14);
    wire  [1:0] ovl_st   = ovl_stat[2 * ovl_idx +: 2];
    logic       dl_ovl;
    logic [1:0] dl_ost;

    logic [2:0] dl_show, dl_de, dl_hs, dl_vs, dl_top;

    always_ff @(posedge clk) if (ce_pix) begin
        dl_ovl  <= ovl_cell;
        dl_ost  <= ovl_st;
        dl_show <= {dl_show[1:0], show};
        dl_de   <= {dl_de[1:0],   raw_de};
        dl_hs   <= {dl_hs[1:0],   raw_hs};
        dl_vs   <= {dl_vs[1:0],   raw_vs};
        dl_top  <= {dl_top[1:0],  disp_top};
    end

    // The bank is palettebank bit 1 for the top monitor, bit 0 for the bottom.
    assign pal_ra = {dl_top[0] ? palettebank[1] : palettebank[0], lb_rd};

    // component = 255 - pal4bit(v), and pal4bit(v) is {v,v}, so it is one NOT.
    // Index [0], not [1]. hcnt settles one tick before disp_x is evaluated
    // from it, the line buffer read is registered, and the PROM read is
    // registered again -- so the colour leaving this block belongs to the
    // pixel whose qualifiers are in stage 0 of the delay line, not stage 1.
    // Getting this off by one costs nothing on a 1:1 monitor, where the window
    // test shifts with the data, but it breaks the fight screen's 2x pixel
    // doubling: an odd shift makes act_x 2k and 2k+1 land on different source
    // pixels, so the pairs stop matching.
    wire [3:0] r4 = dl_top[0] ? prom_q[0][3:0] : prom_q[3][3:0];
    wire [3:0] g4 = dl_top[0] ? prom_q[1][3:0] : prom_q[4][3:0];
    wire [3:0] b4 = dl_top[0] ? prom_q[2][3:0] : prom_q[5][3:0];

    wire [23:0] ovl_rgb = (dl_ost == 2'd1) ? 24'h00C800 :     // green
                          (dl_ost == 2'd2) ? 24'hDC0000 :     // red
                          (dl_ost == 2'd3) ? 24'hDCC800 :     // yellow
                                             24'h303030;      // grey

    always_ff @(posedge clk) if (ce_pix) begin
        if (dl_ovl) begin
            {vid_r, vid_g, vid_b} <= ovl_rgb;
        end else begin
            vid_r <= dl_show[0] ? ~{r4, r4} : 8'h00;
            vid_g <= dl_show[0] ? ~{g4, g4} : 8'h00;
            vid_b <= dl_show[0] ? ~{b4, b4} : 8'h00;
        end
        de    <= dl_de[0];
        hsync <= dl_hs[0];
        vsync <= dl_vs[0];
    end

endmodule

`default_nettype wire
