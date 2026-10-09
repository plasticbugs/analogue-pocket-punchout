// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: (c) 2026 plasticbugs
//
// Part of an Analogue Pocket openFPGA core for Nintendo's Punch-Out!! board.
//------------------------------------------------------------------------------
// The bottom monitor on its own, at a CRT's own timing, for the Analogizer.
//
// punchout_video draws both monitors into one 512 x 672 Pocket raster at
// 42.8 kHz: the fight screen is rows 224..671, each of its 224 source lines
// shown twice and each pixel twice.  A CRT wants that screen alone, 256 x 224
// at about 15 kHz.  So the fight screen's lines are taken out of the Pocket
// raster as it is drawn -- the first row of each pair, every other dot, as the
// four-bit colours the PROMs give -- into a ring of lines, and read out again
// at the native raster below:
//
//     6 MHz dots (clk / 16), 392 x 255, 15.31 kHz, 60.02 Hz
//     hsync  dots 0..27       picture  dots 92..347      (256)
//     vsync  lines 0..2       picture  lines 20..243     (224)
//
// The native frame is exactly as long as the Pocket's (392 x 255 x 16 =
// 560 x 714 x 4 = 1,599,360 clocks), so the two stay locked: the native frame
// is restarted T_N0 clocks after every Pocket vsync, which after the first
// frame lands where it already was.  T_N0 puts native line 0 of the fight
// screen just after the Pocket has finished drawing it.
//
// The Pocket draws a fight line every 4480 clocks and the CRT shows one every
// 6272, so the reader falls behind: 64 lines by the time the Pocket's last
// fight line is drawn, plus the one being read.  A 64-line ring is overrun by
// four lines; 128 lines is the next power of two (48 M10K).  The reader
// finishes the frame's last line before the next frame's first fight line is
// written, so no line is ever read from the wrong frame
// (sim/tb_po_crt.sv checks every pixel of three frames against the frame
// it came from).
//------------------------------------------------------------------------------
`default_nettype none

module po_crt (
    input  wire         clk,          // clk_sys, 96 MHz

    // the Pocket raster from punchout_video, qualified by ce_pix
    input  wire         ce_pix,
    input  wire         vs,
    input  wire         de,
    input  wire   [7:0] r,
    input  wire   [7:0] g,
    input  wire   [7:0] b,

    // the fight screen at the bottom monitor's own timing: o_ce marks the
    // first clock of each dot, and everything else holds for the whole dot
    output logic        o_ce,
    output logic [23:0] o_rgb,
    output logic        o_hs,         // active high
    output logic        o_vs,
    output logic        o_hb,
    output logic        o_vb
);
    // ------------------------------------------------------------ the Pocket
    localparam int FIGHT_ROW0 = 224;      // de rows 224..671 are the fight screen
    localparam int FIGHT_ROWS = 448;

    // ------------------------------------------------------------- native
    localparam int NDIV = 16, NH = 392, NV = 255;
    localparam int N_HS = 28, N_X0 = 92, N_X1 = 348;
    localparam int N_VS = 3,  N_Y0 = 20, N_Y1 = 244;
    // Pocket vsync to native line 0.  The Pocket's fight line 0 is drawn from
    // 546,656 clocks after its vsync; native line 0 is read from
    // T_N0 + 20 * 6272 + 92 * 16 = T_N0 + 126,912.  One Pocket row (2240) of
    // margin past the earliest that works.
    localparam int T_N0 = 422_000;

    // ------------------------------------------------------- write: capture
    logic       vs_d = 1'b0, de_d = 1'b0;
    logic [9:0] row = '0;                 // de rows since vsync
    logic [9:0] dot = '0;                 // de dots before this one, in the row
    logic [20:0] fc = '0;                 // clocks since the Pocket's vsync
    wire        vs_rise = ce_pix && vs && !vs_d;

    wire [9:0]  frow = row - 10'(FIGHT_ROW0);
    wire        wr = ce_pix && de && (row >= 10'(FIGHT_ROW0))
                  && (row < 10'(FIGHT_ROW0 + FIGHT_ROWS)) && !frow[0] && !dot[0];
    wire [14:0] wa = {frow[7:1], dot[8:1]};
    wire [11:0] wd = {r[7:4], g[7:4], b[7:4]};

    always_ff @(posedge clk) begin
        fc <= vs_rise ? 21'd0 : fc + 21'd1;
        if (ce_pix) begin
            vs_d <= vs;
            de_d <= de;
            dot  <= de ? dot + 10'd1 : 10'd0;
            if (vs && !vs_d)       row <= 10'd0;
            else if (de_d && !de)  row <= row + 10'd1;
        end
    end

    // one-dimensional, power of two: 128 lines x 256 dots
    logic [11:0] mem [0:32767];
    logic [14:0] ra;
    logic [11:0] q;
    always_ff @(posedge clk) begin
        if (wr) mem[wa] <= wd;
        q <= mem[ra];
    end

    // ----------------------------------------------------- read: the CRT
    logic [3:0] div = '0;
    logic [8:0] hn = '0;
    logic [7:0] vn = '0;
    wire        restart = (fc == 21'(T_N0));
    always_ff @(posedge clk) begin
        if (restart) begin
            div <= '0; hn <= '0; vn <= '0;
        end else begin
            div <= div + 4'd1;
            if (div == 4'(NDIV - 1)) begin
                if (hn == 9'(NH - 1)) begin
                    hn <= '0;
                    vn <= (vn == 8'(NV - 1)) ? 8'd0 : vn + 8'd1;
                end else hn <= hn + 9'd1;
            end
        end
    end

    // div 0: address and qualifiers; div 2: the RAM's word; div 3: out
    wire       vis_x = (hn >= 9'(N_X0)) && (hn < 9'(N_X1));
    wire       vis_y = (vn >= 8'(N_Y0)) && (vn < 8'(N_Y1));
    wire [8:0] nx = hn - 9'(N_X0);
    wire [7:0] ny = vn - 8'(N_Y0);
    logic      vis_r, hs_r, vs_r, hb_r, vb_r;
    always_ff @(posedge clk) begin
        o_ce <= (div == 4'd3);
        if (div == 4'd0) begin
            ra    <= {ny[6:0], nx[7:0]};
            vis_r <= vis_x && vis_y;
            hs_r  <= (hn < 9'(N_HS));
            vs_r  <= (vn < 8'(N_VS));
            hb_r  <= !vis_x;
            vb_r  <= !vis_y;
        end
        if (div == 4'd3) begin
            o_rgb <= vis_r ? {q[11:8], q[11:8], q[7:4], q[7:4], q[3:0], q[3:0]} : 24'h0;
            o_hs  <= hs_r;
            o_vs  <= vs_r;
            o_hb  <= hb_r;
            o_vb  <= vb_r;
        end
    end
endmodule

`default_nettype wire
