// target/pocket/po_crt.sv on its own: the Pocket raster as punchout_video
// draws it (560 x 714 dots at 24 MHz, de 512 x 672 from row 20 / dot 24,
// vsync rows 0..3), with every fight-screen pixel a colour that names its
// line, its dot and the Pocket frame it was drawn in.  Checks the native
// output: 392 dots a line, 255 lines a frame, 1,599,360 clocks a frame,
// hsync 28 dots, vsync 3 lines, 224 x 256 visible, and every visible dot the
// fight screen's, from the frame the native frame belongs to -- so a line
// read before it is written, or after the next frame overwrote it, fails.
// sim/run_po_crt.sh builds and runs it.
`timescale 1ns/1ps
`default_nettype none

module tb_po_crt;
    logic clk = 1'b0;
    always #5.208 clk = ~clk;              // 96 MHz

    // ------------------------------------------------- the Pocket raster
    logic [1:0] phase = '0;
    logic [9:0] hcnt = '0, vcnt = '0;
    int         pf = 0;                    // Pocket frame number
    wire        ce_pix = (phase == 2'd3);
    always_ff @(posedge clk) begin
        phase <= phase + 2'd1;
        if (ce_pix) begin
            if (hcnt == 10'd559) begin
                hcnt <= '0;
                if (vcnt == 10'd713) begin vcnt <= '0; pf <= pf + 1; end
                else vcnt <= vcnt + 10'd1;
            end else hcnt <= hcnt + 10'd1;
        end
    end
    function automatic [11:0] colour(input int k, input int x, input int f);
        colour = 12'((k * 37 + x * 11 + f * 1013) & 12'hfff);
    endfunction
    wire        raw_de = (hcnt >= 10'd24) && (hcnt < 10'd536) && (vcnt >= 10'd20) && (vcnt < 10'd692);
    wire [9:0]  ax = hcnt - 10'd24, ay = vcnt - 10'd20;
    logic       de, vs;
    logic [7:0] r, g, b;
    always_ff @(posedge clk) if (ce_pix) begin
        de <= raw_de;
        vs <= (vcnt < 10'd4);
        if (raw_de && ay >= 10'd224) begin
            logic [11:0] c;
            c = colour(int'(ay - 10'd224) / 2, int'(ax) / 2, pf);
            {r, g, b} <= {c[11:8], c[11:8], c[7:4], c[7:4], c[3:0], c[3:0]};
        end else {r, g, b} <= raw_de ? 24'h5a5a5a : 24'h0;
    end

    wire        o_ce, o_hs, o_vs, o_hb, o_vb;
    wire [23:0] o_rgb;
    po_crt dut (.clk(clk), .ce_pix(ce_pix), .vs(vs), .de(de), .r(r), .g(g), .b(b),
                .o_ce(o_ce), .o_rgb(o_rgb), .o_hs(o_hs), .o_vs(o_vs), .o_hb(o_hb), .o_vb(o_vb));

    // ------------------------------------------------------------- checks
    int errors = 0;
    int clk_n = 0;
    always_ff @(posedge clk) clk_n <= clk_n + 1;

    logic p_hs = 0, p_vs = 0, p_vis_line = 0;
    int dots = 0, lines = 0, hs_w = 0, vs_w = 0, vis_lines = 0, vis_dots = 0;
    int line_vis = 0, vline = -1, vx = 0, frame_ref = -1, frames = 0, last_vs_clk = 0;
    int bad = 0, checked = 0;
    always_ff @(posedge clk) if (o_ce) begin
        // lines: hsync rising edges
        if (o_hs && !p_hs) begin
            if (frames >= 2 && dots != 392) begin $display("FAIL: line of %0d dots", dots); errors++; end
            dots = 0; lines++;
            if (line_vis > 0) begin
                if (frames >= 2 && line_vis != 256) begin $display("FAIL: %0d visible dots in a line", line_vis); errors++; end
                vis_lines++;
            end
            line_vis = 0; vx = 0;
        end
        dots++;
        if (o_hs) hs_w++;
        // frames: vsync rising edges
        if (o_vs && !p_vs) begin
            if (frames >= 2) begin
                if (lines != 255)  begin $display("FAIL: frame of %0d lines", lines); errors++; end
                if (vis_lines != 224) begin $display("FAIL: %0d visible lines", vis_lines); errors++; end
                if (clk_n - last_vs_clk != 1_599_360) begin
                    $display("FAIL: frame of %0d clocks", clk_n - last_vs_clk); errors++;
                end
                if (hs_w != 28 * 255) begin $display("FAIL: hsync %0d dots a frame", hs_w); errors++; end
                if (vs_w != 3 * 392) begin $display("FAIL: vsync %0d dots", vs_w); errors++; end
            end
            frames++; last_vs_clk = clk_n;
            lines = 0; vis_lines = 0; hs_w = 0; vs_w = 0; vline = -1; frame_ref = -1;
        end
        if (o_vs) vs_w++;
        // the picture: the frame the native frame belongs to is the Pocket's
        // frame when its first visible dot is shown
        if (!o_hb && !o_vb) begin
            if (vx == 0) begin
                vline++;
                if (vline == 0) frame_ref = pf;
            end
            if (frames >= 2 && frame_ref >= 0) begin
                logic [11:0] want, got;
                want = colour(vline, vx, frame_ref);
                got  = {o_rgb[23:20], o_rgb[15:12], o_rgb[7:4]};
                checked++;
                if (got !== want || o_rgb[19:16] !== o_rgb[23:20]) begin
                    if (bad < 5) $display("  line %0d dot %0d: got %03h want %03h (frame %0d)", vline, vx, got, want, frame_ref);
                    bad++;
                end
            end
            vx++; line_vis++;
        end
        p_hs = o_hs; p_vs = o_vs;
    end

    initial begin
        repeat (1_599_360 * 6) @(posedge clk);
        $display("po_crt: %0d native frames, %0d visible dots checked against their frame, %0d differ",
                 frames, checked, bad);
        if (bad != 0) errors++;
        if (checked != 224 * 256 * (frames - 3) && checked < 224 * 256 * 3) begin
            $display("FAIL: only %0d dots checked", checked); errors++;
        end
        if (errors == 0) $display("PASS"); else $display("FAILED: %0d", errors);
        $finish;
    end
endmodule
