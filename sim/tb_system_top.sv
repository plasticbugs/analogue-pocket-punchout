//------------------------------------------------------------------------------
// Full-system bench wrapper: the whole machine, running its own program.
//
// punchout_core with a behavioural SDRAM behind it. The frozen-state video
// bench proves the renderer draws what MAME draws when handed the same video
// RAM; this proves the Z80 can produce that video RAM in the first place --
// memory map, I/O decode, the LS259, the vblank NMI and the boot sequence.
//
// The 6502 half of the sound board is T65. That is VHDL, which this simulator
// cannot read, so sim/t65_stub.sv stands in and leaves the sound CPU idle.
// Fine here: nothing on the main board waits on it.
//------------------------------------------------------------------------------
`default_nettype none

module tb_system_top (
    input  wire         clk,
    input  wire         reset,
    input  wire         hw_reset,

    input  wire         dl_active,
    input  wire  [24:0] dl_addr,
    input  wire   [7:0] dl_data,
    input  wire         dl_we,

    input  wire   [7:0] in0,
    input  wire   [7:0] in1,
    input  wire   [7:0] dsw1,
    input  wire   [7:0] dsw2,

    output wire         ce_pix,
    output wire         hsync,
    output wire         vsync,
    output wire         de,
    output wire   [7:0] vid_r,
    output wire   [7:0] vid_g,
    output wire   [7:0] vid_b,
    output wire         vblank_rise,
    output wire         dbg_line_overrun,
    output wire  [11:0] dbg_worst_line,
    output wire         dbg_dma_req,
    output wire         dbg_load_overflow,
    output wire   [1:0] dbg_rom_st,
    output wire   [1:0] dbg_pat_st,
    output wire signed [15:0] audio,
    output wire         audio_ce,
    output wire  [63:0] dbg_spr1_ctrl,
    output wire  [39:0] dbg_spr2_ctrl,
    output wire   [7:0] dbg_palbank,
    output wire   [9:0] dbg_ctrl_wr_vcnt,
    output wire         dbg_ctrl_wr,
    //! every CPU write into video RAM, for the bench's write log
    output wire         dbg_vwe,
    output wire  [15:0] dbg_vaddr,
    output wire   [7:0] dbg_vdata
);
    wire [15:0] dq;
    wire [12:0] sa;
    wire  [1:0] sba;
    wire        sdqml, sdqmh, scs_n, sras_n, scas_n, swe_n, scke, sclk;

    punchout_core u_core (
        .clk(clk), .clk_sdram(clk), .hw_reset(hw_reset), .reset(reset), .rd_late(1'b1), .ovl_mode(2'd0), .freeze(1'b0), .pad_raw(8'd0),
        .dl_active(dl_active), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
        .in0(in0), .in1(in1), .dsw1(dsw1), .dsw2(dsw2),
        .ce_pix(ce_pix), .hsync(hsync), .vsync(vsync), .de(de),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .audio(audio), .audio_ce(audio_ce), .vblank_rise(vblank_rise),
        .dram_dq(dq), .dram_a(sa), .dram_ba(sba),
        .dram_dqm_l(sdqml), .dram_dqm_h(sdqmh), .dram_cs_n(scs_n),
        .dram_ras_n(sras_n), .dram_cas_n(scas_n), .dram_we_n(swe_n),
        .dram_cke(scke), .dram_clk(sclk),
        .dbg_line_overrun(dbg_line_overrun), .dbg_worst_line(dbg_worst_line),
        .dbg_dma_req(dbg_dma_req), .dbg_load_overflow(dbg_load_overflow),
        .dbg_rom_st(dbg_rom_st), .dbg_pat_st(dbg_pat_st));


    assign dbg_spr1_ctrl = u_core.spr1_ctrl;
    assign dbg_spr2_ctrl = u_core.spr2_ctrl;
    assign dbg_palbank   = u_core.palettebank;
    // Where in the raster does the game write the big-sprite control block?
    // sprite-1 tilemap writes (e000-e7ff), the thing the laugh animation rewrites
    assign dbg_ctrl_wr      = u_core.cpu_vwe && (u_core.cpu_vaddr[15:11] == 5'b11100);
    assign dbg_ctrl_wr_vcnt = u_core.u_video.vcnt;
    assign dbg_vwe   = u_core.cpu_vwe;
    assign dbg_vaddr = u_core.cpu_vaddr;
    assign dbg_vdata = u_core.cpu_vdin;

    sdram_model u_model (
        .clk(clk), .dq(dq), .a(sa), .ba(sba), .dqml(sdqml), .dqmh(sdqmh),
        .cs_n(scs_n), .ras_n(sras_n), .cas_n(scas_n), .we_n(swe_n), .cke(scke));

endmodule

`default_nettype wire
