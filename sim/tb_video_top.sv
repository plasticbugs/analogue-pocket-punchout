//------------------------------------------------------------------------------
// Frozen-state video bench wrapper.
//
// The video core plus the real SDRAM controller and a behavioural SDRAM, so
// the bench exercises the same fetch path the hardware will: the same address
// mapping from po_romload, the same CAS latency, the same one-read-at-a-time
// discipline. Rendering against a fake single-cycle ROM would verify a design
// that does not exist.
//------------------------------------------------------------------------------
`default_nettype none

module tb_video_top (
    input  wire         clk,
    input  wire         reset,

    // ROM download: the flat image, byte at a time. Held while dl_active.
    input  wire         dl_active,
    input  wire  [24:0] dl_addr,
    input  wire   [7:0] dl_data,
    input  wire         dl_we,
    output wire         dl_ready,       // SDRAM idle, safe to present the next byte

    // Direct read port, bench only: lets the test read SDRAM through the real
    // controller so a controller fault and a renderer fault can be told apart.
    input  wire  [24:0] tst_addr,
    input  wire         tst_rd,      // one-cycle request pulse
    input  wire         tst_sel,     // held for the whole access: sdram16 reads
                                     // `addr` when it services, not when asked
    output wire  [15:0] tst_q,
    output wire         tst_ready,

    // machine state injection
    input  wire  [15:0] cpu_vaddr,
    input  wire   [7:0] cpu_vdin,
    input  wire         cpu_vwe,
    input  wire  [63:0] spr1_ctrl,
    input  wire  [39:0] spr2_ctrl,
    input  wire   [7:0] palettebank,

    // video out
    output wire         ce_pix,
    output wire         hsync,
    output wire         vsync,
    output wire         de,
    output wire   [7:0] vid_r,
    output wire   [7:0] vid_g,
    output wire   [7:0] vid_b,
    output wire         vblank_rise,
    output wire         dbg_line_overrun,
    output wire  [11:0] dbg_worst_line
);
    // ---- SDRAM pins
    wire [15:0] dq;
    wire [12:0] sa;
    wire  [1:0] sba;
    wire        sdqml, sdqmh, scs_n, sras_n, scas_n, swe_n, scke, sclk;

    // ---- download address mapping
    wire [24:0] ld_addr;
    wire  [7:0] ld_data;
    wire        ld_we;
    po_romload u_load (.dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
                       .sd_addr(ld_addr), .sd_data(ld_data), .sd_we(ld_we));

    // ---- video core's read client
    wire [24:0] vid_addr;
    wire        vid_rd;
    wire [15:0] sd_dout16;
    wire        sd_ready;

    // Loading and rendering never overlap: the core is held in reset until the
    // image is in, so a plain select is enough of an arbiter.
    wire [24:0] sd_addr = dl_active ? ld_addr : (tst_sel ? tst_addr : vid_addr);
    wire        sd_we   = dl_active && ld_we;
    wire        sd_rd   = !dl_active && (tst_rd || vid_rd);
    assign      dl_ready = sd_ready;
    assign      tst_q    = sd_dout16;
    assign      tst_ready = sd_ready;

    sdram16 u_sdram (
        .init(reset), .clk(clk),
        .SDRAM_DQ(dq), .SDRAM_A(sa), .SDRAM_DQML(sdqml), .SDRAM_DQMH(sdqmh),
        .SDRAM_BA(sba), .SDRAM_nCS(scs_n), .SDRAM_nWE(swe_n),
        .SDRAM_nRAS(sras_n), .SDRAM_nCAS(scas_n), .SDRAM_CKE(scke),
        .SDRAM_CLK(sclk),
        .addr(sd_addr), .dout(), .dout16(sd_dout16),
        .baddr(21'd0), .brd(1'b0), .bdata(), .bready(),
        .din(ld_data), .we(sd_we), .rd(sd_rd), .ready(sd_ready));

    sdram_model u_model (
        .clk(clk), .dq(dq), .a(sa), .ba(sba), .dqml(sdqml), .dqmh(sdqmh),
        .cs_n(scs_n), .ras_n(sras_n), .cas_n(scas_n), .we_n(swe_n), .cke(scke));

    punchout_video u_vid (
        .clk(clk), .reset(reset || dl_active),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
        .cpu_vaddr(cpu_vaddr), .cpu_vdin(cpu_vdin), .cpu_vwe(cpu_vwe), .cpu_vq(),
        .spr1_ctrl(spr1_ctrl), .spr2_ctrl(spr2_ctrl), .palettebank(palettebank),
        .sd_addr(vid_addr), .sd_rd(vid_rd), .sd_dout16(sd_dout16), .sd_ready(sd_ready),
        .ce_pix(ce_pix), .hsync(hsync), .vsync(vsync), .de(de),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .vblank_rise(vblank_rise),
        .dbg_line_overrun(dbg_line_overrun), .dbg_worst_line(dbg_worst_line));

endmodule

`default_nettype wire
