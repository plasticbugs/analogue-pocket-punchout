// target/pocket/po_topscreen.sv on its own: the Pocket raster as core_top
// hands it to the scaler (560 x 714 dots, de 512 x 672 from row 20 / dot 24,
// vsync rows 0..3, one dot a clock).  With `en` low DE must pass through
// untouched; with it high, DE must cover exactly the info screen -- de rows
// 0..223, de dots 128..383 -- 256 dots on each of 224 lines, every frame.
// sim/run_po_crt.sh builds and runs it after the po_crt bench.
`timescale 1ns/1ps
`default_nettype none

module tb_po_topscreen;
    logic clk = 1'b0;
    always #20.8 clk = ~clk;              // 24 MHz
    logic [9:0] hcnt = '0, vcnt = '0;
    always_ff @(posedge clk) begin
        if (hcnt == 10'd559) begin
            hcnt <= '0; vcnt <= (vcnt == 10'd713) ? '0 : vcnt + 10'd1;
        end else hcnt <= hcnt + 10'd1;
    end
    logic de = 1'b0, vs = 1'b0;
    logic [9:0] ax = '0, ay = '0;
    always_ff @(posedge clk) begin
        de <= (hcnt >= 10'd24) && (hcnt < 10'd536) && (vcnt >= 10'd20) && (vcnt < 10'd692);
        vs <= (vcnt < 10'd4);
        ax <= hcnt - 10'd24; ay <= vcnt - 10'd20;
    end
    logic en = 1'b0;
    wire  de_out;
    po_topscreen dut (.clk(clk), .en(en), .vs(vs), .de(de), .de_out(de_out));

    int errors = 0;
    task automatic frame(input logic e, output int n_de, output int n_bad, output int n_lines);
        logic p;
        int run;
        @(posedge clk iff (hcnt == 10'd0 && vcnt == 10'd0));
        n_de = 0; n_bad = 0; n_lines = 0; p = 0; run = 0;
        repeat (560 * 714) begin
            @(negedge clk);
            if (de_out) begin
                n_de++; run++;
                if (e ? !(ay < 10'd224 && ax >= 10'd128 && ax < 10'd384) : !de) n_bad++;
            end else if (p) begin
                if (e && run != 256) n_bad++;
                n_lines++; run = 0;
            end
            if (!e && de_out !== de) n_bad++;
            p = de_out;
        end
    endtask

    initial begin
        int n, bad, lines;
        repeat (3) frame(1'b0, n, bad, lines);
        $display("top screen off: %0d DE dots in %0d lines, %0d wrong", n, lines, bad);
        if (n != 512 * 672 || lines != 672 || bad != 0) errors++;
        en = 1'b1;
        frame(1'b1, n, bad, lines);          // the frame it changes in
        repeat (2) frame(1'b1, n, bad, lines);
        $display("top screen on:  %0d DE dots in %0d lines, %0d wrong", n, lines, bad);
        if (n != 256 * 224 || lines != 224 || bad != 0) errors++;
        en = 1'b0;
        frame(1'b0, n, bad, lines);
        frame(1'b0, n, bad, lines);
        $display("top screen off again: %0d DE dots, %0d wrong", n, bad);
        if (n != 512 * 672 || bad != 0) errors++;
        if (errors == 0) $display("PASS"); else $display("FAILED: %0d", errors);
        $finish;
    end
endmodule
