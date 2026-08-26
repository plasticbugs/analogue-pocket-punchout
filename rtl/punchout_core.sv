//------------------------------------------------------------------------------
// Punch-Out!! (Nintendo, 1984) -- the whole machine.
//
// Main board Z80, sound board RP2A03, both monitors composited into one Pocket
// raster. Everything that fits is block RAM; the two big-sprite graphics ROMs
// and the speech data are 272 KB and live in SDRAM.
//
// One clock domain: 96 MHz drives the CPUs (by enable), the renderer and the
// SDRAM controller. Only the video output crossing to clk_vid and the audio
// crossing to clk_74b leave it, and both are handled in core_top.
//------------------------------------------------------------------------------
`default_nettype none

module punchout_core (
    input  wire         clk,             // 96 MHz
    input  wire         clk_sdram,       // 96 MHz, phase-shifted: the chip's clock
    //! Two resets, and the distinction is the whole reason the first two
    //! hardware builds had no sprites:
    //!   hw_reset  -- the PLL is not locked. Resets everything, including the
    //!                SDRAM controller and the loader's queue.
    //!   reset     -- the APF host or the Pocket menu asked for a core reset.
    //!                Stops the machine and nothing else. The host holds this
    //!                asserted for the WHOLE data-slot download and releases it
    //!                afterwards, so anything on the load path that honours it
    //!                simply never sees the ROM.
    input  wire         hw_reset,
    input  wire         reset,
    input  wire         rd_late,         // SDRAM read capture point; 1 is correct
    input  wire   [1:0] ovl_mode,        // 0 off, 1 status, 2 faults (freezes on one), 3 inputs
    input  wire         freeze,          // hold both CPUs; the video keeps rendering
    input  wire   [7:0] pad_raw,         // raw pad bits for the inputs overlay

    //! ---- ROM download from the APF data loader
    input  wire         dl_active,
    input  wire  [24:0] dl_addr,
    input  wire   [7:0] dl_data,
    input  wire         dl_we,

    //! ---- cabinet inputs, active high
    input  wire   [7:0] in0,
    input  wire   [7:0] in1,
    input  wire   [7:0] dsw1,
    input  wire   [7:0] dsw2,

    //! ---- video, in the clk domain, qualified by ce_pix
    output wire         ce_pix,
    output wire         hsync,
    output wire         vsync,
    output wire         de,
    output wire   [7:0] vid_r,
    output wire   [7:0] vid_g,
    output wire   [7:0] vid_b,

    //! ---- audio, signed, with an enable marking each new value
    output wire signed [15:0] audio,
    output wire         audio_ce,

    //! ---- one pulse per frame at the start of vblank
    output wire         vblank_rise,

    //! ---- SDRAM pins
    inout  wire  [15:0] dram_dq,
    output wire  [12:0] dram_a,
    output wire   [1:0] dram_ba,
    output wire         dram_dqm_l,
    output wire         dram_dqm_h,
    output wire         dram_cs_n,
    output wire         dram_ras_n,
    output wire         dram_cas_n,
    output wire         dram_we_n,
    output wire         dram_cke,
    output wire         dram_clk,

    //! ---- diagnostics for the on-screen overlay
    output wire         dbg_line_overrun,
    output wire  [11:0] dbg_worst_line,
    output wire         dbg_dma_req,
    output logic        dbg_load_overflow,
    output wire   [1:0] dbg_rom_st,      // SDRAM self-test: ROM readback
    output wire   [1:0] dbg_pat_st       // SDRAM self-test: pattern
);
    // =========================================================================
    // ROM download
    //
    // The APF loader hands over bytes at its own pace with no back-pressure at
    // all, while the SDRAM's service time varies with refresh. Passing them
    // straight through would let a pending write be overwritten in flight and
    // silently lost, so they are buffered and issued at the controller's pace.
    //
    // A write costs about a dozen clocks, so the queue has to cover any burst
    // that arrives faster than that. 256 entries is far more than the bridge
    // can deliver between two writes; the sustained rate is not in question,
    // since 272 KB at a dozen clocks each is 34 ms and the bridge takes far
    // longer than that to send the image.
    //
    // If it ever does fill, bytes would be dropped and the graphics would be
    // quietly wrong -- which is exactly what the full-system bench found when
    // the queue was 64 deep and the bench fed it at one byte per four clocks.
    // So overflow is latched and reported rather than ignored.
    // =========================================================================
    wire [24:0] ld_addr;
    wire  [7:0] ld_data;
    wire        ld_we;
    po_romload u_load (.dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
                       .sd_addr(ld_addr), .sd_data(ld_data), .sd_we(ld_we));

    logic [32:0] wfifo [0:255];
    logic  [8:0] wf_wp, wf_rp;
    wire         wf_empty = (wf_wp == wf_rp);
    wire         wf_full  = (wf_wp[7:0] == wf_rp[7:0]) && (wf_wp[8] != wf_rp[8]);
    logic        wr_busy;

    logic [24:0] sd_addr;
    logic  [7:0] sd_din;
    logic        sd_we, sd_rd;
    wire  [15:0] sd_dout16;
    wire         sd_ready;

    wire [24:0] vid_sd_addr;
    wire        vid_sd_rd;

    // One queue entry per BYTE, on the rising edge of the strobe. The APF data
    // loader holds ioctl_wr high for DIO_HOLD (4) clocks, and enqueuing on
    // level put every byte in four times: 16 entries per bridge word against
    // about 8 the SDRAM could retire in the same time, so the queue overflowed
    // a few hundred bytes into the graphics and the rest were dropped. Block
    // RAM never noticed -- a rewrite of the same byte is harmless -- which is
    // why the first hardware build had perfect backgrounds and garbage sprites.
    logic ld_we_d;
    always_ff @(posedge clk) ld_we_d <= ld_we;
    wire  ld_stb = ld_we && !ld_we_d;

    // Checksum of what the loader was handed, for the self-test to read back
    // against. The address term catches a byte that lands in the wrong place
    // as well as one that is wrong.
    logic [31:0] ld_sum;
    logic        dl_active_d;
    always_ff @(posedge clk) begin
        dl_active_d <= dl_active;
        if (dl_active && !dl_active_d) ld_sum <= '0;
        else if (ld_stb)               ld_sum <= ld_sum + {16'b0, ld_addr[7:0], ld_data};
    end

    always_ff @(posedge clk) begin
        if (hw_reset) begin
            wf_wp             <= '0;
            wf_rp             <= '0;
            wr_busy           <= 1'b0;
            sd_we             <= 1'b0;
            dbg_load_overflow <= 1'b0;
        end else begin
            sd_we <= 1'b0;
            if (ld_stb) begin
                if (wf_full) dbg_load_overflow <= 1'b1;
                wfifo[wf_wp[7:0]] <= {ld_addr, ld_data};
                wf_wp <= wf_wp + 9'd1;
            end
            if (!wr_busy) begin
                if (!wf_empty && sd_ready) begin
                    sd_addr <= wfifo[wf_rp[7:0]][32:8];
                    sd_din  <= wfifo[wf_rp[7:0]][7:0];
                    sd_we   <= 1'b1;
                    wr_busy <= 1'b1;
                end
            end else if (!sd_ready) begin
                wf_rp   <= wf_rp + 9'd1;
                wr_busy <= 1'b0;
            end
        end
    end

    // Loading, self-test and rendering never overlap -- the machine is held in
    // reset for the first two -- so the bus is a fixed-priority select.
    wire loading = dl_active || !wf_empty || wr_busy;

    // ---- SDRAM self-test: after every load and reset, and whenever the read
    //      timing setting is changed from the menu.
    logic [24:0] tst_addr;
    logic  [7:0] tst_din;
    logic        tst_we, tst_rd, tst_busy;
    logic        held_d, rd_late_d;
    wire         held = reset || loading;
    always_ff @(posedge clk) begin
        held_d    <= held;
        rd_late_d <= rd_late;
    end
    wire tst_go = (held_d && !held) || (rd_late != rd_late_d);

    po_sdram_test u_test (
        .clk(clk), .reset(hw_reset), .go(tst_go), .ref_sum(ld_sum),
        .busy(tst_busy), .rom_st(dbg_rom_st), .pat_st(dbg_pat_st),
        .sd_addr(tst_addr), .sd_din(tst_din), .sd_we(tst_we), .sd_rd(tst_rd),
        .sd_dout16(sd_dout16), .sd_ready(sd_ready));

    // The bus select is registered: `loading` includes a 9-bit pointer compare,
    // and straight into the address mux and the controller's registered
    // address it was the last path short of 96 MHz. A cycle late is harmless
    // here -- the loader's own strobe is a cycle behind the queue state
    // anyway, and reads simply start a clock later once loading ends.
    logic loading_r;
    always_ff @(posedge clk) loading_r <= loading;
    wire [24:0] sd_addr_mux = loading_r ? sd_addr  : tst_busy ? tst_addr : vid_sd_addr;
    wire  [7:0] sd_din_mux  = loading_r ? sd_din   : tst_din;
    wire        sd_we_mux   = loading_r ? sd_we    : tst_we;
    wire        sd_rd_mux   = loading_r ? 1'b0     : tst_busy ? tst_rd : vid_sd_rd;

    sdram16 u_sdram (
        .init(hw_reset), .clk(clk), .clk_pin(clk_sdram), .rd_late(rd_late),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_DQML(dram_dqm_l),
        .SDRAM_DQMH(dram_dqm_h), .SDRAM_BA(dram_ba), .SDRAM_nCS(dram_cs_n),
        .SDRAM_nWE(dram_we_n), .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk),
        .addr(sd_addr_mux), .dout(), .dout16(sd_dout16),
        .baddr(21'd0), .brd(1'b0), .bdata(), .bready(),
        .din(sd_din_mux), .we(sd_we_mux), .rd(sd_rd_mux), .ready(sd_ready));

    // The machine stays in reset until the image has landed and been checked.
    // Registered: `loading` carries the queue's 9-bit pointer compare, and as
    // a combinational reset it fanned that compare into every synchronous
    // reset in the machine -- the worst path in the design ran from the read
    // pointer into an APU register. A clock of latency on a reset is free.
    logic mach_reset;
    always_ff @(posedge clk) mach_reset <= reset || loading || tst_busy;

    // ---- diagnostic overlay: eight squares, two bits each
    //      0 grey = not applicable, 1 green = good, 2 red = bad, 3 yellow = busy
    function automatic [1:0] rg(input bad); rg = bad ? 2'd2 : 2'd1; endfunction
    function automatic [1:0] lit(input on); lit = on ? 2'd3 : 2'd0; endfunction
    logic [15:0] ovl_stat;
    always_comb begin
        case (ovl_mode)
            // status: the boot-time picture
            2'd1: ovl_stat = { 2'd0, sd_ready ? 2'd1 : 2'd3, rd_late ? 2'd1 : 2'd3,
                               dbg_pat_st, dbg_rom_st, rg(dbg_dma_req),
                               rg(dbg_line_overrun), rg(dbg_load_overflow) };
            // faults, sticky: 0 overrun 1 bg short 2 setup late 3 sd stall
            //                 4 load overflow 5 dma 6 rom 7 pattern
            2'd2: ovl_stat = { rg(sticky[7]), rg(sticky[6]), rg(sticky[5]), rg(sticky[4]),
                               rg(sticky[3]), rg(sticky[2]), rg(sticky[1]), rg(sticky[0]) };
            // inputs, raw: 0 Y 1 X 2 B 3 A 4 L 5 R 6 Select 7 Start
            2'd3: ovl_stat = { lit(pad_raw[7]), lit(pad_raw[6]), lit(pad_raw[5]), lit(pad_raw[4]),
                               lit(pad_raw[3]), lit(pad_raw[2]), lit(pad_raw[1]), lit(pad_raw[0]) };
            default: ovl_stat = '0;
        endcase
    end
    wire ovl_en = (ovl_mode != 2'd0);

    // =========================================================================
    // Video
    // =========================================================================
    wire [15:0] cpu_vaddr;
    wire  [7:0] cpu_vdin, cpu_vq;
    wire        cpu_vwe;
    wire [63:0] spr1_ctrl;
    wire [39:0] spr2_ctrl;
    wire  [7:0] palettebank;

    punchout_video u_video (
        .clk(clk), .reset(mach_reset),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
        .cpu_vaddr(cpu_vaddr), .cpu_vdin(cpu_vdin), .cpu_vwe(cpu_vwe), .cpu_vq(cpu_vq),
        .spr1_ctrl(spr1_ctrl), .spr2_ctrl(spr2_ctrl), .palettebank(palettebank),
        .sd_addr(vid_sd_addr), .sd_rd(vid_sd_rd),
        .sd_dout16(sd_dout16), .sd_ready(sd_ready),
        .ovl_en(ovl_en), .ovl_stat(ovl_stat),
        .ce_pix(ce_pix), .hsync(hsync), .vsync(vsync), .de(de),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .vblank_rise(vblank_rise),
        .dbg_line_overrun(dbg_line_overrun), .dbg_worst_line(dbg_worst_line),
        .dbg_f_overrun(f_overrun), .dbg_f_bg_short(f_bg_short),
        .dbg_f_setup_late(f_setup_late), .dbg_f_sd_stall(f_sd_stall));

    // ---- sticky faults, cleared on reset or when the overlay mode changes.
    //      In Faults mode a fault also freezes the CPUs, so the frame it
    //      happened in stays on the screen to be looked at.
    wire f_overrun, f_bg_short, f_setup_late, f_sd_stall;
    logic [7:0] sticky;
    logic [1:0] ovl_mode_d;
    always_ff @(posedge clk) begin
        ovl_mode_d <= ovl_mode;
        if (hw_reset || reset || ovl_mode != ovl_mode_d) sticky <= '0;
        else sticky <= sticky | {
            dbg_pat_st == 2'd2, dbg_rom_st == 2'd2, dbg_dma_req, dbg_load_overflow,
            f_sd_stall, f_setup_late, f_bg_short, f_overrun };
    end
    wire cpu_hold = freeze || ((ovl_mode == 2'd2) && (|sticky));

    // =========================================================================
    // Main board
    // =========================================================================
    wire [7:0] soundlatch, soundlatch2, vlm_data;
    wire       soundlatch_wr, soundlatch2_wr, vlm_data_wr;
    wire       snd_reset, vlm_rst, vlm_st, vlm_vcu;

    // Both NMIs fire at the start of vertical blanking, as on the board. The
    // video snapshots its state near the END of blanking, after the handlers
    // have done their writing, so what they wrote is in this frame's picture.
    punchout_main u_main (
        .clk(clk), .reset(mach_reset), .pause(cpu_hold),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
        .vblank_rise(vblank_rise),
        .in0(in0), .in1(in1), .dsw1(dsw1), .dsw2(dsw2),
        .vlm_busy(1'b0),                    // no speech chip yet: never busy
        .cpu_vaddr(cpu_vaddr), .cpu_vdin(cpu_vdin), .cpu_vwe(cpu_vwe), .cpu_vq(cpu_vq),
        .spr1_ctrl(spr1_ctrl), .spr2_ctrl(spr2_ctrl), .palettebank(palettebank),
        .soundlatch(soundlatch), .soundlatch_wr(soundlatch_wr),
        .soundlatch2(soundlatch2), .soundlatch2_wr(soundlatch2_wr),
        .snd_reset(snd_reset),
        .vlm_data(vlm_data), .vlm_data_wr(vlm_data_wr),
        .vlm_rst(vlm_rst), .vlm_st(vlm_st), .vlm_vcu(vlm_vcu),
        .dbg_nmi());

    // =========================================================================
    // Sound board
    // =========================================================================
    punchout_sound u_sound (
        .clk(clk), .reset(mach_reset), .snd_reset(snd_reset), .pause(cpu_hold),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
        .vblank_rise(vblank_rise),
        .soundlatch(soundlatch), .soundlatch2(soundlatch2),
        .sample(audio), .sample_ce(audio_ce),
        .dbg_dma_req(dbg_dma_req));

    // The speech chip is not implemented yet. Its control lines are decoded and
    // brought this far so adding it later is a wiring change, not a redesign.
    wire _unused = &{1'b0, soundlatch_wr, soundlatch2_wr, vlm_data,
                     vlm_data_wr, vlm_rst, vlm_st, vlm_vcu, 1'b0};

endmodule

`default_nettype wire
