// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: (c) 2026 plasticbugs
//
// Part of an Analogue Pocket openFPGA core for Nintendo's Punch-Out!! board.
// Hardware behaviour derived from MAME's nintendo/punchout.cpp by Nicola
// Salmoria; see README.md for full credits.
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
    input  wire         ovl_en2,          // a second row of squares above the first
    input  wire  [15:0] ovl_stat2,

    //! ---- video out, in the clk domain, qualified by ce_pix
    output logic        ce_pix,
    output logic        hsync,
    output logic        vsync,
    output logic        de,
    output logic  [7:0] vid_r,
    output logic  [7:0] vid_g,
    output logic  [7:0] vid_b,

    //! ---- one clk pulse at the start of vertical blanking: frame counting
    output logic        vblank_rise,
    //! ---- the CPUs' NMI: once per frame like the board's, but EARLIER in
    //!      this raster -- see NMI_ROW
    output logic        nmi_pulse,

    //! ---- diagnostics
    output logic        dbg_line_overrun, // a line renderer ran past its row
    output logic [11:0] dbg_worst_line,   // worst cycles taken by any line
    //! one-clock pulses, made sticky by the core for the Faults overlay:
    output logic        dbg_f_overrun,    // row started with the last line unfinished
    output logic        dbg_f_bg_short,   // ...and it was still in the background pass
    output logic        dbg_f_setup_late, // sprite geometry took > 700 clocks
    output logic        dbg_f_sd_stall,   // one SDRAM read took > 96 clocks
    //! ---- black probe: the first pixel that LEAVES the core black inside a
    //!      fixed window of the fight screen (lines 136-171, x < 120: where
    //!      the black bar shows on the Pocket), with the pass that wrote it,
    //!      the raw attribute byte that pass used and its palette index.
    //!      Cleared by probe_clr.
    input  wire         probe_clr,
    input  wire   [1:0] vid_mode,         // 0 palette, 1 raw index, 2 writer tag, 3 index 7 in white
    //! ---- Arm Wrestling: a third tilemap, one character set shared by both
    //!      monitors, no row scroll, and its own image layout
    input  wire         armwrest,
    //! ---- the inspector's crosshair: parked on the hit pixel by the probe,
    //!      then moved with the pad; the record is of the pixel under it
    //! ---- render tests, to bisect a hardware-only fault:
    //!      bit 0: the background pass reads the LIVE tilemap RAMs and the
    //!             snapshot copier is stopped   bit 1: no sprite passes
    input  wire   [1:0] rtest,
    //! ---- while the CPUs are frozen, the CPU's own port of the live tilemap
    //!      RAMs is borrowed to read the cell under the crosshair, so a wrong
    //!      byte can be told apart as wrong CONTENT (both ports agree) or a
    //!      wrong READ on the renderer's port (they differ)
    input  wire         hijack,
    output wire  [15:0] porta_rec,        // {code via port A, attr via port A} of that cell
    input  wire   [3:0] cur_move,         // {down, up, left, right}, sampled once per frame
    input  wire         cur_fast,         // move 8 instead of 1
    output logic        dbg_f_black,
    output wire  [81:0] probe_rec,        // see the assign at the probe
    output logic [31:0] probe_cnt,        // black pixels in the window per frame, by writer: see below
    //! CPU writes since probe_clr into bottom tilemap rows 21-22 and into the
    //! top tilemap, saturating: MAME's game makes none of either through the
    //! knock-down sequence, so a count here is the Pocket's game diverging
    output logic  [7:0] probe_wr_bot,
    output logic  [7:0] probe_wr_top,
    //! ---- write monitor on bottom rows 20-22: the most writes seen in any
    //!      one frame since arming, and the last byte written there
    output logic  [7:0] probe_wr_max,
    output logic  [7:0] probe_wr_last
);

    // =========================================================================
    // Raster: 560 x 714 at 24 MHz -> 60.02 Hz. MAME's 60 Hz for this driver is
    // itself a placeholder (the real totals come from a 20.16 MHz crystal and
    // are not modelled), so matching it exactly would be false precision.
    // =========================================================================
    localparam logic [9:0] H_ACTIVE = 10'd512, H_BPORCH = 10'd24, H_TOTAL = 10'd560;
    localparam logic [9:0] V_ACTIVE = 10'd672, V_BPORCH = 10'd20, V_TOTAL = 10'd714;
    localparam logic [9:0] TOP_ROWS = 10'd224;        // rows 0..223: info screen
    // The board raises NMI at the start of its 32-line vertical blank and
    // then scans the visible area, so the game has about 2.1 ms after NMI in
    // which a write is invisible, and its display updates are written to fit
    // that: measured, the K.O. meter redraw puts the scroll bytes 20 rows
    // after NMI and the tiles 75-139 rows after. This raster snapshots the
    // whole video state once per frame, at row 17, and a snapshot taken
    // 39 rows (0.9 ms) after NMI fell in the middle of that redraw: one frame
    // with the new scroll and the old tiles, seen as the K.O. box flickering
    // left whenever a punch landed. So NMI is raised at row 520 instead,
    // 211 rows (4.9 ms) before the snapshot -- more time than the board
    // gives, and nothing can tear: the renderer is drawing the last fight
    // lines from the PREVIOUS snapshot while the handler runs, and every
    // write it makes lands in the live RAM only. Once per frame is all the
    // game knows about NMI; its phase against the display is invisible to it.
    localparam logic [9:0] NMI_ROW  = 10'd520;
    localparam logic [9:0] TOP_XOFF = 10'd128;        // (512 - 256) / 2, to centre it

    // Punch-Out!!'s sprite tilemaps are 16x32 tiles, 128 x 256 pixels. Arm
    // Wrestling turns big sprite #1 on its side: 32x16 tiles, 256 x 128. Big
    // sprite #2 is 16x32 on both.
    localparam [31:0] WIDTHSHIFTED  = 32'd128 << 16;
    localparam [31:0] HEIGHTSHIFTED = 32'd256 << 16;
    wire       [31:0] WIDTH1  = armwrest ? (32'd256 << 16) : WIDTHSHIFTED;
    wire       [31:0] HEIGHT1 = armwrest ? (32'd128 << 16) : HEIGHTSHIFTED;

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
            nmi_pulse   <= 1'b0;
        end else begin
            v_act_d     <= v_act;
            vblank_rise <= v_act_d && !v_act;
            nmi_pulse   <= (vcnt == NMI_ROW) && (hcnt == 10'd0);
        end
    end

    // =========================================================================
    // Video RAM.
    //
    // Split by byte lane rather than made wide with byte enables: partial
    // selects do not infer byte enables in Quartus and explode into registers
    // (METHODOLOGY 5.5). Separate lanes also let the renderer read a whole tile
    // entry in a single cycle.
    //
    // Two copies of everything. The CPU reads and writes the LIVE copy. Near
    // the END of every vertical blank -- row 17 of the 20-row back porch,
    // after the game's NMI handler has long finished its writing and two rows
    // before line 0 is rendered -- the live copy is snapshotted into the
    // SHADOW copy, 2048 clocks with all lanes in parallel, and the renderer
    // draws the whole frame from the shadow alone.
    //
    // The board reads its RAM as the beam scans, which is fine with a 2 ms
    // vertical blank for the game to do its writing in; this raster has 1 ms
    // of blanking and draws the two monitors one after the other, so a write
    // that lands after the board's beam has passed can land in the middle of
    // a displayed row here. With the snapshot nothing the CPU does during
    // the active frame can reach the picture until the next blanking.
    //
    // Why the end of blanking and not the start: the handler's writes must be
    // in THIS frame's picture, as they are on the board. Snapshotting first and
    // delaying the NMI until it was done drew a clean frame one frame late --
    // frame 150 of the attract bench came out identical to MAME's 148 -- and a
    // reaction game cannot afford a frame of lag.
    //
    // A write the CPU makes while the copier is walking the array is delayed
    // three clocks and written into the shadow as well. That is later than the
    // copier's own write of any entry it may already have passed, so the
    // shadow ends the walk holding the newest value of every entry, whichever
    // side of the walk pointer the write fell on. The write-through uses the
    // renderer's port of the shadow, which is idle: the renderer only runs for
    // rows that will be displayed.
    // =========================================================================
    // Punch-Out!!:    d800-dfff top map, f000-ffff bottom map (64 columns)
    // Arm Wrestling:  d800-dfff foreground, f000-f7ff bottom, f800-ffff top,
    //                 both backgrounds 32 columns
    wire vsel_d800 = (cpu_vaddr[15:11] == 5'b11011); // d800-dfff
    wire vsel_spr  = (cpu_vaddr[15:12] == 4'b1110);  // e000-efff
    wire vsel_f000 = (cpu_vaddr[15:12] == 4'b1111);  // f000-ffff
    wire vsel_top  = armwrest ? (vsel_f000 &&  cpu_vaddr[11]) : vsel_d800;
    wire vsel_bot  = armwrest ? (vsel_f000 && !cpu_vaddr[11]) : vsel_f000;
    wire vsel_fg   = armwrest && vsel_d800;
    wire spr_hi   = cpu_vaddr[11];                  // 0 = spr1, 1 = spr2

    logic  [9:0] bgt_ridx;
    logic [10:0] bgb_ridx;
    logic  [8:0] s1_ridx, s2_ridx;
    logic  [7:0] bgt_code, bgt_attr, bgb_code, bgb_attr;       // what the renderer sees
    logic  [9:0] fg_ridx;
    logic  [7:0] fg_code, fg_attr;
    logic  [7:0] bgt_code_s, bgt_attr_s, bgb_code_s, bgb_attr_s; // ...from the shadow
    logic  [7:0] bgt_q0, bgt_q1, bgb_q0, bgb_q1;
    logic  [7:0] s1_b [0:3];
    logic  [7:0] s2_b [0:3];
    logic  [7:0] s1_cq [0:3];
    logic  [7:0] s2_cq [0:3];

    // ---- the snapshot copier: walks every entry during row 17 of the back
    //      porch (a row is 2240 clocks; the walk is 2048 plus two of latency)
    wire         row_start;
    wire         cp_start = row_start && (vcnt == V_BPORCH - 10'd3) && !rtest[0];
    logic [11:0] cp_addr;             // bit 11 = running
    wire         cp_run  = cp_addr[11];
    wire  [10:0] cp_a    = cp_addr[10:0];
    logic [10:0] cp_wa;               // the address whose data is on the live ports now
    logic        cp_we;
    logic        cp_done /* verilator public_flat_rd */;   // one clock, after the last entry is read
    always_ff @(posedge clk) begin
        if (reset) begin
            cp_addr <= '0; cp_we <= 1'b0; cp_wa <= '0; cp_done <= 1'b0;
        end else begin
            cp_we   <= cp_run;
            cp_wa   <= cp_a;
            cp_done <= cp_run && (cp_a == 11'h7ff);
            if (cp_start)                 cp_addr <= 12'h800;
            else if (cp_run)              cp_addr <= (cp_a == 11'h7ff) ? 12'h000 : cp_addr + 12'd1;
        end
    end

    // ---- write-through: a CPU write during the walk, three clocks later, into
    //      the shadow. {fg code, fg attr, top code, top attr, bot code,
    //      bot attr, spr1 x4, spr2 x4}
    wire [13:0] wt_sel = {
        cpu_vwe && vsel_fg  && !cpu_vaddr[0], cpu_vwe && vsel_fg  &&  cpu_vaddr[0],
        cpu_vwe && vsel_top && !cpu_vaddr[0], cpu_vwe && vsel_top &&  cpu_vaddr[0],
        cpu_vwe && vsel_bot && !cpu_vaddr[0], cpu_vwe && vsel_bot &&  cpu_vaddr[0],
        cpu_vwe && vsel_spr && !spr_hi && (cpu_vaddr[1:0] == 2'd0),
        cpu_vwe && vsel_spr && !spr_hi && (cpu_vaddr[1:0] == 2'd1),
        cpu_vwe && vsel_spr && !spr_hi && (cpu_vaddr[1:0] == 2'd2),
        cpu_vwe && vsel_spr && !spr_hi && (cpu_vaddr[1:0] == 2'd3),
        cpu_vwe && vsel_spr &&  spr_hi && (cpu_vaddr[1:0] == 2'd0),
        cpu_vwe && vsel_spr &&  spr_hi && (cpu_vaddr[1:0] == 2'd1),
        cpu_vwe && vsel_spr &&  spr_hi && (cpu_vaddr[1:0] == 2'd2),
        cpu_vwe && vsel_spr &&  spr_hi && (cpu_vaddr[1:0] == 2'd3)};
    logic [13:0] wt_s1, wt_s2;
    logic [13:0] wt_s3 /* verilator public_flat_rd */;
    // for the bench: a CPU write to any video RAM this clock, and the walk
    wire         cp_wr_now  /* verilator public_flat_rd */ = |wt_sel;
    wire         cp_walking /* verilator public_flat_rd */ = cp_run;
    logic [10:0] wt_a1, wt_a2, wt_a3;
    logic  [7:0] wt_d1, wt_d2, wt_d3;
    always_ff @(posedge clk) begin
        if (reset) begin
            wt_s1 <= '0; wt_s2 <= '0; wt_s3 <= '0;
        end else begin
            wt_s1 <= cp_run ? wt_sel : 14'd0;
            wt_s2 <= wt_s1;
            wt_s3 <= wt_s2;
        end
        wt_a1 <= cpu_vaddr[11:1]; wt_a2 <= wt_a1; wt_a3 <= wt_a2;
        wt_d1 <= cpu_vdin;        wt_d2 <= wt_d1; wt_d3 <= wt_d2;
    end

    // live copies: port A the CPU, port B the copier
    logic [7:0] bgt_l0, bgt_l1, bgb_l0, bgb_l1;
    logic [7:0] s1_l [0:3];
    logic [7:0] s2_l [0:3];

    logic [80:0] probe_lat;   // the inspector's record (assigned at the probe);
                              // exactly the width of the record: a wider
                              // register zero-extends it and shifts every field
    // port A address: the CPU, or under hijack the crosshair cell's map index
    wire [10:0] pa_idx  = probe_lat[62:52];          // the record's tilemap index
    wire [10:0] pa_bot  = hijack ? pa_idx       : cpu_vaddr[11:1];
    wire  [9:0] pa_top  = hijack ? pa_idx[9:0]  : cpu_vaddr[10:1];
    wire        pa_we   = cpu_vwe && !hijack;
    assign porta_rec = probe_lat[1] ? {bgt_q0, bgt_q1} : {bgb_q0, bgb_q1};

    po_dpram #(.AW(10), .DW(8)) u_bgt0 (.clk(clk),
        .a_addr(pa_top), .a_we(pa_we && vsel_top && !cpu_vaddr[0]),
        .a_d(cpu_vdin), .a_q(bgt_q0),
        .b_addr(rtest[0] ? bgt_ridx : cp_a[9:0]), .b_we(1'b0), .b_d(8'h00), .b_q(bgt_l0));
    po_dpram #(.AW(10), .DW(8)) u_bgt1 (.clk(clk),
        .a_addr(pa_top), .a_we(pa_we && vsel_top &&  cpu_vaddr[0]),
        .a_d(cpu_vdin), .a_q(bgt_q1),
        .b_addr(rtest[0] ? bgt_ridx : cp_a[9:0]), .b_we(1'b0), .b_d(8'h00), .b_q(bgt_l1));
    po_dpram #(.AW(11), .DW(8)) u_bgb0 (.clk(clk),
        .a_addr(pa_bot), .a_we(pa_we && vsel_bot && !cpu_vaddr[0]),
        .a_d(cpu_vdin), .a_q(bgb_q0),
        .b_addr(rtest[0] ? bgb_ridx : cp_a), .b_we(1'b0), .b_d(8'h00), .b_q(bgb_l0));
    po_dpram #(.AW(11), .DW(8)) u_bgb1 (.clk(clk),
        .a_addr(pa_bot), .a_we(pa_we && vsel_bot &&  cpu_vaddr[0]),
        .a_d(cpu_vdin), .a_q(bgb_q1),
        .b_addr(rtest[0] ? bgb_ridx : cp_a), .b_we(1'b0), .b_d(8'h00), .b_q(bgb_l1));

    // Arm Wrestling's foreground map: 32x32, drawn over everything on the
    // bottom monitor. Copied during the same walk as the top map, which also
    // covers only the low half.
    logic [7:0] fg_l0, fg_l1, fg_q0, fg_q1, fg_code_s, fg_attr_s;
    po_dpram #(.AW(10), .DW(8)) u_fg0 (.clk(clk),
        .a_addr(cpu_vaddr[10:1]), .a_we(cpu_vwe && vsel_fg && !cpu_vaddr[0]),
        .a_d(cpu_vdin), .a_q(fg_q0),
        .b_addr(rtest[0] ? fg_ridx : cp_a[9:0]), .b_we(1'b0), .b_d(8'h00), .b_q(fg_l0));
    po_dpram #(.AW(10), .DW(8)) u_fg1 (.clk(clk),
        .a_addr(cpu_vaddr[10:1]), .a_we(cpu_vwe && vsel_fg &&  cpu_vaddr[0]),
        .a_d(cpu_vdin), .a_q(fg_q1),
        .b_addr(rtest[0] ? fg_ridx : cp_a[9:0]), .b_we(1'b0), .b_d(8'h00), .b_q(fg_l1));

    // shadow copies: port A the copier; port B the renderer, and the
    // write-through while the renderer is idle
    /* verilator lint_off PINCONNECTEMPTY */
    po_dpram #(.AW(10), .DW(8)) u_sfg0 (.clk(clk),
        .a_addr(cp_wa[9:0]), .a_we(cp_we && !cp_wa[10]), .a_d(fg_l0), .a_q(),
        .b_addr(wt_s3[13] ? wt_a3[9:0] : fg_ridx), .b_we(wt_s3[13]), .b_d(wt_d3), .b_q(fg_code_s));
    po_dpram #(.AW(10), .DW(8)) u_sfg1 (.clk(clk),
        .a_addr(cp_wa[9:0]), .a_we(cp_we && !cp_wa[10]), .a_d(fg_l1), .a_q(),
        .b_addr(wt_s3[12] ? wt_a3[9:0] : fg_ridx), .b_we(wt_s3[12]), .b_d(wt_d3), .b_q(fg_attr_s));
    po_dpram #(.AW(10), .DW(8)) u_sbgt0 (.clk(clk),
        .a_addr(cp_wa[9:0]), .a_we(cp_we && !cp_wa[10]), .a_d(bgt_l0), .a_q(),
        .b_addr(wt_s3[11] ? wt_a3[9:0] : bgt_ridx), .b_we(wt_s3[11]), .b_d(wt_d3), .b_q(bgt_code_s));
    po_dpram #(.AW(10), .DW(8)) u_sbgt1 (.clk(clk),
        .a_addr(cp_wa[9:0]), .a_we(cp_we && !cp_wa[10]), .a_d(bgt_l1), .a_q(),
        .b_addr(wt_s3[10] ? wt_a3[9:0] : bgt_ridx), .b_we(wt_s3[10]), .b_d(wt_d3), .b_q(bgt_attr_s));
    po_dpram #(.AW(11), .DW(8)) u_sbgb0 (.clk(clk),
        .a_addr(cp_wa), .a_we(cp_we), .a_d(bgb_l0), .a_q(),
        .b_addr(wt_s3[9] ? wt_a3 : bgb_ridx), .b_we(wt_s3[9]), .b_d(wt_d3), .b_q(bgb_code_s));
    po_dpram #(.AW(11), .DW(8)) u_sbgb1 (.clk(clk),
        .a_addr(cp_wa), .a_we(cp_we), .a_d(bgb_l1), .a_q(),
        .b_addr(wt_s3[8] ? wt_a3 : bgb_ridx), .b_we(wt_s3[8]), .b_d(wt_d3), .b_q(bgb_attr_s));
    // the renderer's view: the shadow, or under test the live RAM directly
    // (same one-cycle read latency on both)
    assign fg_code  = rtest[0] ? fg_l0 : fg_code_s;
    assign fg_attr  = rtest[0] ? fg_l1 : fg_attr_s;
    assign bgt_code = rtest[0] ? bgt_l0 : bgt_code_s;
    assign bgt_attr = rtest[0] ? bgt_l1 : bgt_attr_s;
    assign bgb_code = rtest[0] ? bgb_l0 : bgb_code_s;
    assign bgb_attr = rtest[0] ? bgb_l1 : bgb_attr_s;

    generate
        genvar lane;
        for (lane = 0; lane < 4; lane++) begin : g_spr
            po_dpram #(.AW(9), .DW(8)) u_s1 (.clk(clk),
                .a_addr(cpu_vaddr[10:2]),
                .a_we(cpu_vwe && vsel_spr && !spr_hi && (cpu_vaddr[1:0] == lane[1:0])),
                .a_d(cpu_vdin), .a_q(s1_cq[lane]),
                .b_addr(cp_a[8:0]), .b_we(1'b0), .b_d(8'h00), .b_q(s1_l[lane]));
            po_dpram #(.AW(9), .DW(8)) u_s2 (.clk(clk),
                .a_addr(cpu_vaddr[10:2]),
                .a_we(cpu_vwe && vsel_spr &&  spr_hi && (cpu_vaddr[1:0] == lane[1:0])),
                .a_d(cpu_vdin), .a_q(s2_cq[lane]),
                .b_addr(cp_a[8:0]), .b_we(1'b0), .b_d(8'h00), .b_q(s2_l[lane]));
            po_dpram #(.AW(9), .DW(8)) u_ss1 (.clk(clk),
                .a_addr(cp_wa[8:0]), .a_we(cp_we && (cp_wa[10:9] == 2'b00)), .a_d(s1_l[lane]), .a_q(),
                .b_addr(wt_s3[7-lane] ? wt_a3[9:1] : s1_ridx), .b_we(wt_s3[7-lane]), .b_d(wt_d3),
                .b_q(s1_b[lane]));
            po_dpram #(.AW(9), .DW(8)) u_ss2 (.clk(clk),
                .a_addr(cp_wa[8:0]), .a_we(cp_we && (cp_wa[10:9] == 2'b00)), .a_d(s2_l[lane]), .a_q(),
                .b_addr(wt_s3[3-lane] ? wt_a3[9:1] : s2_ridx), .b_we(wt_s3[3-lane]), .b_d(wt_d3),
                .b_q(s2_b[lane]));
        end
    endgenerate
    /* verilator lint_on PINCONNECTEMPTY */

    // CPU read-back, one cycle behind the address, same as the memories.
    logic [1:0] cq_lane;
    logic       cq_low, cq_top, cq_spr, cq_bot, cq_hi, cq_fg;
    always_ff @(posedge clk) begin
        cq_lane <= cpu_vaddr[1:0];
        cq_low  <= cpu_vaddr[0];
        cq_top  <= vsel_top;
        cq_fg   <= vsel_fg;
        cq_spr  <= vsel_spr;
        cq_bot  <= vsel_bot;
        cq_hi   <= spr_hi;
    end
    always_comb begin
        if      (cq_fg)  cpu_vq = cq_low ? fg_q1  : fg_q0;
        else if (cq_top) cpu_vq = cq_low ? bgt_q1 : bgt_q0;
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
    // Arm Wrestling has no row scroll: f000-f03f is tilemap row 0 and nothing
    // else, so nothing shadows it and every row draws at scroll 0.
    wire        rs_hit = !armwrest && cpu_vwe && vsel_bot && (cpu_vaddr[11:6] == 6'd0);
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
    // Arm Wrestling's character generator is wired differently, so its image
    // has its own region bases: gfx1 is 32 KB shared by both monitors and gfx2
    // is 48 KB of three-plane foreground characters. The memories below are
    // sized for that; Punch-Out!! fills the lower half of each and never
    // addresses the rest.
    localparam [24:0] BASE_GFX1 = 25'h0E000;
    wire [24:0] BASE_GFX2 = armwrest ? 25'h16000 : 25'h12000;
    wire [24:0] BASE_GFX3 = armwrest ? 25'h22000 : 25'h16000;
    wire [24:0] BASE_PROM = armwrest ? 25'h62000 : 25'h56000;
    wire [24:0] END_PROM  = BASE_PROM + 25'h00C00;
    // one plane of characters: 8 KB for Punch-Out!!, 16 KB for Arm Wrestling
    wire [14:0] PLANE_SZ  = armwrest ? 15'h4000 : 15'h2000;

    wire        in_gfx1 = (dl_addr >= BASE_GFX1) && (dl_addr < BASE_GFX2);
    wire        in_gfx2 = (dl_addr >= BASE_GFX2) && (dl_addr < BASE_GFX3);
    wire        in_prom = (dl_addr >= BASE_PROM) && (dl_addr < END_PROM);
    wire [15:0] g1_off  = dl_addr[15:0] - {1'b0, BASE_GFX1[14:0]};
    wire [15:0] g2_off  = dl_addr[15:0] - {1'b0, BASE_GFX2[14:0]};
    wire [11:0] pr_off  = dl_addr[11:0] - BASE_PROM[11:0];
    // which plane a loading byte belongs to, and where in that plane
    wire  [1:0] g1_pl   = armwrest ? {1'b0, g1_off[14]} : {1'b0, g1_off[13]};
    wire  [1:0] g2_pl   = armwrest ? (g2_off[15:14] == 2'd0 ? 2'd0 :
                                      g2_off[15:14] == 2'd1 ? 2'd1 : 2'd2)
                                   : {1'b0, g2_off[13]};
    wire [13:0] g1_wa   = armwrest ? g1_off[13:0] : {1'b0, g1_off[12:0]};
    wire [13:0] g2_wa   = armwrest ? g2_off[13:0] : {1'b0, g2_off[12:0]};

    logic [13:0] gfx_ridx;
    logic  [7:0] g1_p0, g1_p1, g2_p0, g2_p1, g2_p2;

    po_spram_dp #(.AW(14), .DW(8)) u_g1p0 (.clk(clk), .wa(g1_wa),
        .we(dl_we && in_gfx1 && g1_pl == 2'd0), .d(dl_data), .ra(gfx_ridx), .q(g1_p0));
    po_spram_dp #(.AW(14), .DW(8)) u_g1p1 (.clk(clk), .wa(g1_wa),
        .we(dl_we && in_gfx1 && g1_pl == 2'd1), .d(dl_data), .ra(gfx_ridx), .q(g1_p1));
    po_spram_dp #(.AW(14), .DW(8)) u_g2p0 (.clk(clk), .wa(g2_wa),
        .we(dl_we && in_gfx2 && g2_pl == 2'd0), .d(dl_data), .ra(gfx_ridx), .q(g2_p0));
    po_spram_dp #(.AW(14), .DW(8)) u_g2p1 (.clk(clk), .wa(g2_wa),
        .we(dl_we && in_gfx2 && g2_pl == 2'd1), .d(dl_data), .ra(gfx_ridx), .q(g2_p1));
    // third plane, Arm Wrestling's foreground only
    po_spram_dp #(.AW(14), .DW(8)) u_g2p2 (.clk(clk), .wa(g2_wa),
        .we(dl_we && in_gfx2 && g2_pl == 2'd2), .d(dl_data), .ra(gfx_ridx), .q(g2_p2));

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

    // The small state goes with the snapshot too: sprite control block, scroll
    // table, palette bank, all latched on the same clock the copy starts.
    logic [63:0] spr1_snap;
    logic [39:0] spr2_snap;
    logic  [8:0] rowscroll [0:31];
    logic  [7:0] palbank_l;
    integer si;
    always_ff @(posedge clk) begin
        if (reset) begin
            spr1_snap <= '0; spr2_snap <= '0; palbank_l <= '0;
            for (si = 0; si < 32; si++) rowscroll[si] <= armwrest ? 9'd0 : 9'd58;
        end else if (cp_done) begin   // the same instant as the tilemap snapshot
            spr1_snap <= spr1_ctrl;
            spr2_snap <= spr2_ctrl;
            palbank_l <= palettebank;
            for (si = 0; si < 32; si++)
                rowscroll[si] <= armwrest ? 9'd0 : (rs_shadow[si] + 9'd58);
        end
    end

    // =========================================================================
    // Big sprite geometry, computed at the start of every line from the
    // snapshotted control block.
    //
    // Per line rather than per frame only because it is cheap -- ~10 clocks
    // plus a skip loop of at most 255 per sprite, inside a 2240-clock row --
    // and it keeps the geometry registers out of the frame-setup critical
    // path. The values it reads are the snapshot's, so every line of a frame
    // sees the same block.
    // =========================================================================
    logic [7:0]  c1 [0:7];
    logic [7:0]  c2 [0:4];
    logic [11:0] zoom;
    logic        spr1_top_en, spr1_bot_en, spr1_flipx;

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
                    for (li = 0; li < 8; li++) c1[li] <= spr1_snap[8*li +: 8];
                    for (li = 0; li < 5; li++) c2[li] <= spr2_snap[8*li +: 8];
                    spr1_flipx  <= spr1_snap[48];       // dff6 bit 0
                    spr1_top_en <= spr1_snap[56];       // dff7 bit 0
                    spr1_bot_en <= spr1_snap[57];       // dff7 bit 1
                    zoom        <= {spr1_snap[11:8], spr1_snap[7:0]};
                    fst         <= FS_CALC1;
                end

                FS_CALC1: begin
                    sxv1 <= (sx1t > (armwrest ? 15'sd2048 : 15'sd3588)) ? (sx1t - 15'sd4096) : sx1t;
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
                        ? (WIDTH1 - 32'((-32'sd1 * 32'(sxv1)) * 32'sd16384 + 32'sd3740 * $signed({20'b0, zoom})) - 32'd1)
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
                    if (sk_x >= WIDTH1 && sk_n <= 9'd255) begin
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


    assign row_start = (hcnt == 10'd0) && ce_pix;
    // Render only rows that will be shown: row 0 during back-porch row 19,
    // each later row during the one before it. The renderer used to run for
    // every row, blanking included, filling a line buffer nobody displayed;
    // now the shadow RAM's read port is free during blanking for the
    // snapshot's write-through.
    wire rend_en  = (vcnt >= V_BPORCH - 10'd1) && (vcnt < V_BPORCH + V_ACTIVE - 10'd1);

    typedef enum logic [4:0] {
        R_IDLE, R_SETUP,
        R_BG_INIT, R_BG_A, R_BG_B, R_BG_C, R_BG_EMIT,
        R_S1_START, R_S1_TILE, R_S1_TW, R_S1_R0, R_S1_R1, R_S1_EMIT,
        R_S2_START, R_S2_TILE, R_S2_TW, R_S2_R, R_S2_EMIT,
        R_FG_INIT, R_FG_A, R_FG_B, R_FG_C, R_FG_EMIT,
        R_DONE
    } rstate_e;
    rstate_e rs;

    // background walk
    logic [4:0] bg_col;        // top map column 0..31
    logic [8:0] bg_x;          // output pixel 0..256
    logic [8:0] bg_tx;         // bottom map tilemap x, wraps at 512
    logic [2:0] bg_i;          // pixel within the fetched tile
    logic [7:0] bg_p0, bg_p1, bg_p2;
    logic       fg_pass;                //! the renderer is in the foreground pass
    logic [4:0] bg_color;
    logic [7:0] bg_attr_raw, sp_attr_raw;   // for the black probe's tag
    logic [28:0] tag_wd;               // {writer[1:0], attr[7:0], code[7:0], tilemap index[10:0]}
    logic [7:0]  bg_code_raw;
    logic [10:0] bg_ridx_raw;
    logic       bg_flipx;

    // sprite walk (shared by both engines)
    logic [31:0] cx;
    logic  [8:0] px;
    logic  [7:0] cy;
    logic  [4:0] tile_col;
    logic        tile_valid;
    logic  [7:0] rp0, rp1, rp2;
    logic  [5:0] sp_color;
    logic        sp_flipx;
    logic [12:0] sp_code;
    logic  [2:0] sd_wait;

    // cx < WIDTHSHIFTED is guaranteed while walking, so the source pixel is
    // cx[22:16]: tile column cx[22:19], pixel within it cx[18:16].
    wire [4:0] src_col = cx[23:19];
    wire [2:0] src_sub = cx[18:16];

    wire [2:0] bg_bit  = bg_flipx ? bg_i : (3'd7 - bg_i);
    wire [1:0] bg_pen  = {bg_p1[bg_bit], bg_p0[bg_bit]};
    wire [2:0] fg_pen  = {bg_p2[bg_bit], bg_p1[bg_bit], bg_p0[bg_bit]};
    wire [2:0] sp_bit  = sp_flipx ? src_sub : (3'd7 - src_sub);
    wire [2:0] sp1_pen = {rp2[sp_bit], rp1[sp_bit], rp0[sp_bit]};
    wire [1:0] sp2_pen = {rp1[sp_bit], rp0[sp_bit]};

    assign bgt_ridx = {vy[7:3], bg_col};
    // 64 columns on Punch-Out!!'s scrolling bottom map, 32 on Arm Wrestling's
    assign bgb_ridx = armwrest ? {1'b0, vy[7:3], bg_tx[7:3]} : {vy[7:3], bg_tx[8:3]};
    assign fg_ridx  = {vy[7:3], bg_col};

    // The character address: code * 8 + row. Punch-Out!!'s codes are 10 bits,
    // with attr[1:0] on top. Arm Wrestling's top map adds attr[7] as bit 10,
    // its bottom map is 10 bits into the same set, and its foreground takes
    // three bits of attr.
    wire [10:0] code_top = armwrest ? {bgt_attr[7], bgt_attr[1:0], bgt_code}
                                    : {1'b0, bgt_attr[1:0], bgt_code};
    wire [10:0] code_bot = {1'b0, bgb_attr[1:0], bgb_code};
    wire [10:0] code_fg  = {fg_attr[2:0], fg_code};
    assign gfx_ridx = fg_pass  ? {code_fg,  vy[2:0]}
                    : rend_top ? {code_top, vy[2:0]}
                               : {code_bot, vy[2:0]};

    // Big sprite #1 is a 16x32 map on Punch-Out!! and a 32x16 one on Arm
    // Wrestling, stored as two 16-column halves one after the other; the x
    // flip picks the other half.
    wire [4:0] s1_col = (armwrest && spr1_flipx) ? (src_col ^ 5'h10) : src_col;
    assign s1_ridx  = armwrest ? {s1_col[4], cy[6:3], s1_col[3:0]}
                               : {cy[7:3], src_col[3:0]};
    assign s2_ridx  = {cy[7:3], src_col[3:0]};

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
            tag_wd         <= '0;
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

            if (row_start && rend_en) begin
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
                        bg_tx <= rend_top ? 9'd0 : rowscroll[vy[7:3]];
                        rs    <= R_BG_A;
                    end
                    // Address is already stable from the previous state, so
                    // A settles the tilemap read, B settles the gfx read.
                    R_BG_A: rs <= R_BG_B;
                    R_BG_B: begin
                        bg_attr_raw <= rend_top ? bgt_attr : bgb_attr;
                        bg_code_raw <= rend_top ? bgt_code : bgb_code;
                        bg_ridx_raw <= rend_top ? {1'b0, bgt_ridx} : bgb_ridx;
                        bg_color <= rend_top ? bgt_attr[6:2] : bgb_attr[6:2];
                        // Arm Wrestling's top map has no flip bit: attr[7] is
                        // bit 10 of the tile code there.
                        bg_flipx <= rend_top ? (!armwrest && bgt_attr[7]) : bgb_attr[7];
                        rs       <= R_BG_C;
                    end
                    R_BG_C: begin
                        // One character set serves both of Arm Wrestling's
                        // background maps; Punch-Out!! has one per monitor.
                        bg_p0 <= (rend_top || armwrest) ? g1_p0 : g2_p0;
                        bg_p1 <= (rend_top || armwrest) ? g1_p1 : g2_p1;
                        bg_i  <= rend_top ? 3'd0 : bg_tx[2:0];
                        rs    <= R_BG_EMIT;
                    end
                    R_BG_EMIT: begin
                        lb_we <= 1'b1;
                        lb_wa <= bg_x[7:0];
                        lb_wd <= {1'b0, bg_color, bg_pen};
                        tag_wd <= {2'd0, bg_attr_raw, bg_code_raw, bg_ridx_raw};
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
                        if (rtest[1] || !spr1_on || (sx1 > 9'd255)
                            || (rend_top ? !spr1_top_en : !spr1_bot_en)
                            || (s1y >= HEIGHT1))
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
                        sp_attr_raw <= s1_b[3];
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
                            tag_wd <= {2'd1, sp_attr_raw, sp_code[7:0], 11'd0};
                        end
                        if (px == 9'd255 || (cx + 32'(incxx1)) >= WIDTH1) begin
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
                        // Skipping big sprite #2 must not skip the
                        // foreground with it: Arm Wrestling's third tilemap is
                        // drawn on every line of the bottom monitor, not only
                        // the lines this sprite happens to cover. Chaining the
                        // foreground off the end of the sprite loop left the
                        // attract screen's text unrendered wherever the sprite
                        // did not reach.
                        if (rtest[1] || rend_top || !spr2_on || (sx2 > 9'd255)
                            || (s2y >= HEIGHTSHIFTED))
                            rs <= (armwrest && !rend_top) ? R_FG_INIT : R_DONE;
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
                        sp_attr_raw <= s2_b[3];
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
                            tag_wd <= {2'd2, sp_attr_raw, sp_code[7:0], 11'd0};
                        end
                        if (px == 9'd255 || (cx + 32'(incxx2)) >= WIDTHSHIFTED) begin
                            // Arm Wrestling draws its foreground map over
                            // everything on the bottom monitor
                            rs <= (armwrest && !rend_top) ? R_FG_INIT : R_DONE;
                        end else begin
                            px <= px + 9'd1;
                            cx <= cx + 32'(incxx2);
                            rs <= R_S2_TILE;
                        end
                    end

                    // ---------------- foreground (Arm Wrestling) ----------
                    // Three bitplanes, pen 7 transparent, drawn last so it
                    // covers the sprites.
                    R_FG_INIT: begin
                        bg_col <= '0;
                        bg_x   <= '0;
                        fg_pass <= 1'b1;
                        rs     <= R_FG_A;
                    end
                    R_FG_A: rs <= R_FG_B;
                    R_FG_B: begin
                        bg_color <= fg_attr[7:3];
                        bg_flipx <= fg_attr[7];
                        rs       <= R_FG_C;
                    end
                    R_FG_C: begin
                        bg_p0 <= g2_p0;
                        bg_p1 <= g2_p1;
                        bg_p2 <= g2_p2;
                        bg_i  <= 3'd0;
                        rs    <= R_FG_EMIT;
                    end
                    R_FG_EMIT: begin
                        if (fg_pen != 3'd7) begin
                            lb_we <= 1'b1;
                            lb_wa <= bg_x[7:0];
                            lb_wd <= {bg_color, fg_pen};
                            tag_wd <= {2'd0, fg_attr, fg_code, 11'd0};
                        end
                        bg_x <= bg_x + 9'd1;
                        if (bg_x == 9'd255) begin
                            fg_pass <= 1'b0;
                            rs      <= R_DONE;
                        end else if (bg_i == 3'd7) begin
                            bg_col <= bg_col + 5'd1;
                            rs     <= R_FG_A;
                        end else begin
                            bg_i <= bg_i + 3'd1;
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

    // ---- black probe. A tag rides alongside every line-buffer entry: which
    //      pass wrote it and the raw attribute byte that pass fetched. The
    //      first colour-0 pixel (palette index 0-3, all black on the fight
    //      palette) displayed inside the window latches its tag. The window
    //      is fixed to where the bar appears on the Pocket; the tag says
    //      whether the entry came from the background pass with a wrong
    //      attribute, from a sprite pass, or from the background with the
    //      RIGHT attribute -- which would put the fault after the fetch.
    logic [28:0] tb0_q, tb1_q;
    po_spram_re #(.AW(8), .DW(29)) u_tb0 (.clk(clk),
        .wa(lb_wa), .we(lb_we &&  lb_sel), .d(tag_wd),
        .ra(disp_x), .re(ce_pix), .q(tb0_q));
    po_spram_re #(.AW(8), .DW(29)) u_tb1 (.clk(clk),
        .wa(lb_wa), .we(lb_we && !lb_sel), .d(tag_wd),
        .ra(disp_x), .re(ce_pix), .q(tb1_q));
    wire [28:0] tag_rd = lb_sel ? tb1_q : tb0_q;

    // The test is on the colour leaving the PROM stage -- "this pixel went out
    // black" -- not on the palette index, so it catches every black entry the
    // fight palette has (49 of them in bank 0) and anything downstream of the
    // index too. The first version tested the index for 0-3 and did not fire
    // on the bar, which is itself a measurement: the bar is not colour 0.
    localparam logic [9:0] PROBE_Y0 = 10'd496;   // fight line 136, first of its two rows
    localparam logic [9:0] PROBE_Y1 = 10'd567;   // fight line 171, second row
    localparam logic [9:0] PROBE_X1 = 10'd240;   // fight x < 120
    // Coordinates, index and tag of the pixel whose colour is on r4/g4/b4:
    // one stage behind the line-buffer read, like dl_show[0].
    logic [9:0] dl_x, dl_y;
    logic [7:0] dl_idx;
    logic [28:0] dl_tag;
    always_ff @(posedge clk) if (ce_pix) begin
        dl_x   <= act_x;
        dl_y   <= act_y;
        dl_idx <= lb_rd;
        dl_tag <= tag_rd;
    end
    wire [3:0] pr4, pg4, pb4;    // the PROM outputs, assigned where they are chosen
    wire [9:0] dl_yb = dl_y - 10'd224;
    wire [7:0] fight_line = dl_yb[8:1];
    // the crosshair ring: the 8 raster pixels around the cursor, drawn only
    // once the probe is armed, so the picture is untouched in the other modes
    wire [9:0] cdx = {1'b0, dl_x[8:0]} - {1'b0, cur_x};
    wire [9:0] cdy = dl_y - cur_y;
    wire cur_ring = ovl_en && ((cdx == 10'd1 || cdx == 10'h3ff || cdy == 10'd1 || cdy == 10'h3ff)
                            && (cdx == 10'd1 || cdx == 10'h3ff || cdx == 10'd0)
                            && (cdy == 10'd1 || cdy == 10'h3ff || cdy == 10'd0));
    wire probe_hit = ce_pix && dl_show[0] && !dl_top[0]
                  && (dl_y >= PROBE_Y0) && (dl_y <= PROBE_Y1) && (dl_x < PROBE_X1)
                  && (pr4 == 4'hf) && (pg4 == 4'hf) && (pb4 == 4'hf);
    logic        probe_valid;
    // the crosshair, in raster coordinates (act_x 0..511, act_y 0..671)
    logic  [8:0] cur_x;
    logic  [9:0] cur_y;
    wire   [9:0] cur_step = cur_fast ? 10'd8 : 10'd1;
    wire         at_cursor = ce_pix && (dl_x[8:0] == cur_x) && (dl_y == cur_y);
    logic [13:0] cnt_bg, cnt_s1, cnt_s2, cnt_i7;   // black pixels this frame, by tag
    wire  [3:0] pr4t = prom_q[0][3:0], pg4t = prom_q[1][3:0], pb4t = prom_q[2][3:0];
    always_ff @(posedge clk) begin
        dbg_f_black <= 1'b0;
        if (reset || probe_clr) begin
            probe_valid <= 1'b0;
            probe_lat   <= '0;
            cur_x <= 9'd0; cur_y <= 10'd512;   // fight line 144, x 0: where the bar starts
        end else if (probe_hit && !probe_valid) begin
            // first hit: freeze (via dbg_f_black) and park the crosshair here
            probe_valid <= 1'b1;
            cur_x <= dl_x[8:0]; cur_y <= dl_y;
            dbg_f_black <= 1'b1;
        end else if (vblank_rise) begin
            // once per frame: the pad moves the crosshair. Fight pixels are 2x2
            // rasters, so a step of 1 stays on the same fight pixel every
            // other press; that is fine, the record only changes when it moves
            if (cur_move[0] && cur_x != 9'd511) cur_x <= cur_x + cur_step[8:0];
            if (cur_move[1] && cur_x != 9'd0)   cur_x <= cur_x - cur_step[8:0];
            if (cur_move[2] && cur_y != 10'd0)  cur_y <= cur_y - cur_step;
            if (cur_move[3] && cur_y != 10'd671) cur_y <= cur_y + cur_step;
        end
        // every frame, the record of the pixel under the crosshair
        if (at_cursor) begin
            probe_lat   <= { dl_tag,                       // [80:52] writer[1:0], attr[7:0], code[7:0], index[10:0]
                             dl_idx,                       // [51:44] palette index
                             dl_x[8:1],                    // [43:36] fight x
                             fight_line,                   // [35:28] fight line
                             pr4, pg4, pb4,                // [27:16] the fight PROM nibbles
                             pr4t, pg4t, pb4t,             // [15:4]  the info PROM nibbles
                             palbank_l[1:0],               // [3:2]
                             dl_top[0], lb_sel };          // [1:0]
        end
        // black pixels in the window per frame, live, by the pass that wrote
        // them and by whether the index was 7. Reported in units of 64 so a
        // count fits eight squares; the window holds 17280 raster pixels.
        if (reset) begin
            cnt_bg <= '0; cnt_s1 <= '0; cnt_s2 <= '0; cnt_i7 <= '0; probe_cnt <= '0;
        end else if (vblank_rise) begin
            probe_cnt <= {cnt_i7[13:6], cnt_s2[13:6], cnt_s1[13:6], cnt_bg[13:6]};
            cnt_bg <= '0; cnt_s1 <= '0; cnt_s2 <= '0; cnt_i7 <= '0;
        end else if (probe_hit) begin
            if (dl_tag[28:27] == 2'd0) cnt_bg <= cnt_bg + 14'd1;
            if (dl_tag[28:27] == 2'd1) cnt_s1 <= cnt_s1 + 14'd1;
            if (dl_tag[28:27] == 2'd2) cnt_s2 <= cnt_s2 + 14'd1;
            if (dl_idx == 8'd7)      cnt_i7 <= cnt_i7 + 14'd1;
        end
    end
    assign probe_rec = {probe_valid, probe_lat};

    // rows 20-22 of the bottom map (row = cpu_vaddr[11:7])
    wire wr_bot_hit = cpu_vwe && vsel_bot && (cpu_vaddr[11:7] >= 5'd20) && (cpu_vaddr[11:7] <= 5'd22);
    logic [7:0] wr_frame;
    always_ff @(posedge clk) begin
        if (reset || probe_clr) begin
            wr_frame <= '0; probe_wr_max <= '0; probe_wr_last <= '0;
        end else begin
            if (vblank_rise) begin
                if (wr_frame > probe_wr_max) probe_wr_max <= wr_frame;
                wr_frame <= '0;
            end else if (wr_bot_hit && wr_frame != 8'hff) wr_frame <= wr_frame + 8'd1;
            if (wr_bot_hit) probe_wr_last <= cpu_vdin;
        end
    end
    wire wr_top_hit = cpu_vwe && vsel_top && (cpu_vaddr[10:4] != 7'h7f);   // not the control block at dff0+
    always_ff @(posedge clk) begin
        if (reset || probe_clr) begin
            probe_wr_bot <= '0; probe_wr_top <= '0;
        end else begin
            if (wr_bot_hit && probe_wr_bot != 8'hff) probe_wr_bot <= probe_wr_bot + 8'd1;
            if (wr_top_hit && probe_wr_top != 8'hff) probe_wr_top <= probe_wr_top + 8'd1;
        end
    end

    // Diagnostic overlay: eight 12x8 squares in the bottom eight rows, at the
    // left of the fight screen, colour from two status bits each. Hidden
    // behind a menu option. Cheap, and the only way to see inside a fault that
    // only shows on real hardware (METHODOLOGY 4).
    wire        ovl_row  = ovl_en && (act_y >= 10'd664);
    wire        ovl_row2 = ovl_en2 && (act_y >= 10'd654) && (act_y < 10'd662);
    wire  [2:0] ovl_idx  = act_x[6:4];
    wire        ovl_cell = (ovl_row || ovl_row2) && (act_x < 10'd128)
                        && (act_x[3:0] >= 4'd2) && (act_x[3:0] < 4'd14);
    wire  [1:0] ovl_st   = ovl_row2 ? ovl_stat2[2 * ovl_idx +: 2] : ovl_stat[2 * ovl_idx +: 2];
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
    assign pal_ra = {dl_top[0] ? palbank_l[1] : palbank_l[0], lb_rd};

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
    assign pr4 = r4; assign pg4 = g4; assign pb4 = b4;

    wire [23:0] ovl_rgb = (dl_ost == 2'd1) ? 24'h00C800 :     // green
                          (dl_ost == 2'd2) ? 24'hDC0000 :     // red
                          (dl_ost == 2'd3) ? 24'hDCC800 :     // yellow
                                             24'h303030;      // grey

    always_ff @(posedge clk) if (ce_pix) begin
        if (dl_ovl) begin
            {vid_r, vid_g, vid_b} <= ovl_rgb;
        end else if (cur_ring) begin
            {vid_r, vid_g, vid_b} <= (dl_x[0] ^ dl_y[0]) ? 24'hFFFFFF : 24'h000000;
        end else if (vid_mode == 2'd1 || (vid_mode == 2'd3 && dl_idx != 8'd7)) begin
            // the palette index as a colour, bypassing the PROMs: R from bits
            // 7-5, G from 4-2, B from 1-0. The canvas (7) comes out blue.
            vid_r <= dl_show[0] ? {dl_idx[7:5], 5'b0} : 8'h00;
            vid_g <= dl_show[0] ? {dl_idx[4:2], 5'b0} : 8'h00;
            vid_b <= dl_show[0] ? {dl_idx[1:0], 6'b0} : 8'h00;
        end else if (vid_mode == 2'd3) begin
            // index 7 -- the canvas entry -- in white, everything else raw
            {vid_r, vid_g, vid_b} <= dl_show[0] ? 24'hFFFFFF : 24'h000000;
        end else if (vid_mode == 2'd2) begin
            // the pass that wrote the pixel: green background, red sprite 1
            // (the opponent), yellow sprite 2 (the player / the Game Over box)
            vid_r <= (dl_show[0] && dl_tag[28:27] != 2'd0) ? 8'hC0 : 8'h00;
            vid_g <= (dl_show[0] && dl_tag[28:27] != 2'd1) ? 8'hC0 : 8'h00;
            vid_b <= 8'h00;
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
