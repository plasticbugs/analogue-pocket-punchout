// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: (c) 2026 plasticbugs
//
// Part of an Analogue Pocket openFPGA core for Nintendo's Punch-Out!! board.
//------------------------------------------------------------------------------
// "Analogizer: On, Pocket shows top screen": the CRT has the fight screen, so
// the Pocket becomes the cabinet's upper monitor.  The 512 x 672 composite is
// left exactly as it is drawn; only its DE is narrowed to the info screen --
// de rows 0..223, de dots 128..383, where punchout_video puts it at 1x -- and
// core_top tells the scaler to use the 256 x 224 slot, which fills the
// display with it.  With `en` low DE passes through untouched.
//------------------------------------------------------------------------------
`default_nettype none

module po_topscreen (
    input  wire  clk,             // clk_vid: one clock a dot
    input  wire  en,              // already in this clock's domain
    input  wire  vs,
    input  wire  de,
    output wire  de_out
);
    localparam int TOP_ROWS = 224, TOP_X0 = 128, TOP_X1 = 384;

    logic       vs_d = 1'b0, de_d = 1'b0;
    logic [9:0] row = '0;           // de rows since vsync: this row's index
    logic [9:0] dot = '0;           // de dots before this one, in the row
    always_ff @(posedge clk) begin
        vs_d <= vs;
        de_d <= de;
        dot  <= de ? dot + 10'd1 : 10'd0;
        if (vs && !vs_d)       row <= 10'd0;
        else if (de_d && !de)  row <= row + 10'd1;
    end

    wire top = (row < 10'(TOP_ROWS)) && (dot >= 10'(TOP_X0)) && (dot < 10'(TOP_X1));
    assign de_out = de && (!en || top);
endmodule

`default_nettype wire
