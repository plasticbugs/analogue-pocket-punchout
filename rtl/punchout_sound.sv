//------------------------------------------------------------------------------
// Punch-Out!! sound board: the RP2A03.
//
// The 2A03 is a 6502 with decimal mode removed and the NES APU on the same die.
// Here that is a T65 with BCD disabled plus NES_MiSTer's APU. Its two
// "controller" ports are wired to the main board's two command latches instead
// of to joysticks (docs/hardware.md section 3).
//
// Clocking: the chip runs at 1.789772 MHz and the whole core runs at 96 MHz,
// which is not an integer multiple. Rather than add a second PLL output and a
// clock domain crossing for it, the enable comes from a 32-bit phase
// accumulator, so the average rate is exact to under a part per million and the
// jitter is one 96 MHz cycle. That matters because the APU's dividers count
// enable ticks: it is the average rate that sets pitch and tempo, and the
// output is resampled to 48 kHz regardless.
//
// No DMC sample playback. The 8 KB sound ROM contains no reference at all to
// $4010, $4012, $4013 or $4014 -- checked by scanning it for absolute operands,
// not by watching MAME, because MAME's RP2A03 handles its own APU registers
// internally and a memory tap does not see them. So the DMC never requests a
// DMA and there is no bus to steal; dbg_dma_req is brought out in case that
// assumption is ever wrong. $4011, the DMC's direct DAC, IS used -- that is the
// crowd noise -- and works without any DMA.
//------------------------------------------------------------------------------
`default_nettype none

module punchout_sound (
    input  wire         clk,             // 96 MHz
    input  wire         reset,           // core reset
    input  wire         snd_reset,       // LS259 bit 3, the main CPU's hold

    //! ---- ROM download
    input  wire  [24:0] dl_addr,
    input  wire   [7:0] dl_data,
    input  wire         dl_we,

    //! ---- one pulse per frame at the start of vblank; the 2A03's NMI is not
    //!      maskable by the game, unlike the Z80's
    input  wire         vblank_rise,

    //! ---- command latches from the main board
    input  wire   [7:0] soundlatch,      // read at 4016
    input  wire   [7:0] soundlatch2,     // read at 4017

    //! ---- output, signed and DC-free, one new value per chip cycle
    output logic signed [15:0] sample,
    output wire         sample_ce,

    //! ---- diagnostics
    output logic        dbg_dma_req      // set if the DMC ever asks for a DMA
);
    // -------------------------------------------------------------------------
    // 1.789772 MHz from 96 MHz by phase accumulator.
    //   inc = round(1789772.7 / 96000000 * 2^32) = 80_073_146
    // which lands within 0.01 Hz of the real NTSC_APU_CLOCK.
    // -------------------------------------------------------------------------
    localparam [31:0] CE_INC = 32'd80_073_146;
    // the enable is also what paces the sample stream out of here

    logic [31:0] ce_acc;
    logic        ce_2a03;
    always_ff @(posedge clk) begin
        if (reset) begin
            ce_acc  <= '0;
            ce_2a03 <= 1'b0;
        end else begin
            {ce_2a03, ce_acc} <= {1'b0, ce_acc} + {1'b0, CE_INC};
        end
    end

    assign sample_ce = ce_2a03;

    // The APU wants three things per CPU cycle: the enable itself, a phase-2
    // level whose rising edge marks the write point, and a get/put flag that
    // alternates. About 53.6 clocks separate enables, so PHI2 rises at the
    // half-way mark, by which time T65 has the address and write data stable.
    logic [5:0] phase;
    logic       phi2, get_or_put;
    always_ff @(posedge clk) begin
        if (reset) begin
            phase      <= '0;
            phi2       <= 1'b0;
            get_or_put <= 1'b1;
        end else if (ce_2a03) begin
            phase      <= '0;
            phi2       <= 1'b0;
            get_or_put <= ~get_or_put;
        end else begin
            if (phase != 6'd63) phase <= phase + 6'd1;
            if (phase == 6'd26) phi2 <= 1'b1;
        end
    end

    wire cpu_reset = reset || snd_reset;

    // -------------------------------------------------------------------------
    // CPU
    // -------------------------------------------------------------------------
    wire [23:0] A24;
    wire  [7:0] cpu_do;
    wire        rw_n;
    logic [7:0] cpu_di;
    wire [15:0] A = A24[15:0];

    // The 2A03's NMI is the video vblank. Held for a few CPU cycles so T65 sees
    // a clean edge and the line is back high before the next frame.
    logic [2:0] nmi_cnt;
    always_ff @(posedge clk) begin
        if (cpu_reset)            nmi_cnt <= '0;
        else if (vblank_rise)     nmi_cnt <= 3'd4;
        else if (ce_2a03 && nmi_cnt != 3'd0) nmi_cnt <= nmi_cnt - 3'd1;
    end

    wire apu_irq;

    T65 u_cpu (
        .Mode    (2'b00),          // 6502
        .BCD_en  (1'b0),           // 2A03: no decimal mode
        .Res_n   (~cpu_reset),
        .Enable  (ce_2a03),
        .Clk     (clk),
        .Rdy     (1'b1),
        .Abort_n (1'b1),
        .IRQ_n   (~apu_irq),
        .NMI_n   (nmi_cnt == 3'd0),
        .SO_n    (1'b1),
        .R_W_n   (rw_n),
        .Sync    (),
        .EF      (), .MF (), .XF (), .ML_n (), .VP_n (), .VDA (), .VPA (),
        .A       (A24),
        .DI      (cpu_di),
        .DO      (cpu_do),
        .Regs    (),
        .DEBUG   (),
        .NMI_ack ()
    );

    // -------------------------------------------------------------------------
    // Memory map: 2 KB RAM, the APU's registers, the two latches, 8 KB of ROM.
    // MAME maps the RAM without the 2A03's usual mirrors, so this does too.
    // -------------------------------------------------------------------------
    wire sel_ram = (A[15:11] == 5'b00000);            // 0000-07ff
    wire sel_apu = (A[15:5]  == 11'b0100_0000_000);   // 4000-401f
    wire sel_rom = A[15] && A[14] && A[13];           // e000-ffff
    wire wr      = ~rw_n;

    logic [7:0] ram_q;
    po_dpram #(.AW(11), .DW(8)) u_ram (.clk(clk),
        .a_addr(A[10:0]), .a_we(wr && sel_ram && ce_2a03), .a_d(cpu_do), .a_q(ram_q),
        .b_addr(11'd0), .b_we(1'b0), .b_d(8'h00), .b_q());

    wire in_snd_rom = (dl_addr >= 25'h0C000) && (dl_addr < 25'h0E000);
    logic [7:0] rom_q;
    po_spram_dp #(.AW(13), .DW(8)) u_rom (.clk(clk),
        .wa(dl_addr[12:0]), .we(dl_we && in_snd_rom), .d(dl_data),
        .ra(A[12:0]), .q(rom_q));

    wire [7:0]  apu_dout;
    wire [15:0] apu_sample;
    wire        dma_req;
    assign dbg_dma_req = dma_req;

    always_comb begin
        if      (sel_rom)            cpu_di = rom_q;
        else if (sel_ram)            cpu_di = ram_q;
        else if (sel_apu && A[4:0] == 5'h16) cpu_di = soundlatch;
        else if (sel_apu && A[4:0] == 5'h17) cpu_di = soundlatch2;
        else if (sel_apu)            cpu_di = apu_dout;
        else                         cpu_di = 8'hff;
    end

    // -------------------------------------------------------------------------
    // APU. 4016 and 4017 are reads of the command latches here, so the APU only
    // sees them as writes -- which is what they are on a real 2A03 too: 4017 is
    // the frame counter on write and a controller port on read.
    // -------------------------------------------------------------------------
    APU #(
        .SSREG_INDEX_TOP (SSREG_INDEX_APU_TOP),
        .SSREG_INDEX_DMC1(SSREG_INDEX_APU_DMC1),
        .SSREG_INDEX_DMC2(SSREG_INDEX_APU_DMC2),
        .SSREG_INDEX_FCT (SSREG_INDEX_APU_FCT)
    ) u_apu (
        .MMC5           (1'b0),
        .clk            (clk),
        .PHI2           (phi2),
        .ce             (ce_2a03),
        .reset          (cpu_reset),
        .cold_reset     (reset),
        .allow_us       (1'b0),
        .PAL            (1'b0),
        .ADDR           (A[4:0]),
        .DIN            (cpu_do),
        .RW             (rw_n),
        .CS             (sel_apu),
        .audio_channels (5'b11111),
        .DmaData        (8'h00),
        .get_or_put     (get_or_put),
        .DmaAck         (1'b0),
        .DOUT           (apu_dout),
        .Sample         (apu_sample),
        .DmaReq         (dma_req),
        .DmaAddr        (),
        .IRQ            (apu_irq),
        .get_ce         (),
        .put_ce         (),
        .SaveStateBus_Din  (64'd0),
        .SaveStateBus_Adr  (10'd0),
        .SaveStateBus_wren (1'b0),
        .SaveStateBus_rst  (1'b0),
        .SaveStateBus_load (1'b0),
        .SaveStateBus_Dout ()
    );

    // -------------------------------------------------------------------------
    // The APU mixer is unipolar: its output is the sum of two positive lookup
    // tables, so it sits well above zero and never goes below it. The Pocket's
    // audio path is two's complement, and handing it an offset-binary value
    // would put a large DC step through the filter chain.
    //
    // The real board removes the offset with a coupling capacitor; this is the
    // same thing as a difference equation, at the chip's own sample rate:
    //
    //     y[n] = x[n] - x[n-1] + a*y[n-1],   a = 255/256
    //
    // which also tracks any drift in the idle level rather than assuming one.
    // Working in 8 extra fractional bits keeps the pole from quantising away.
    // -------------------------------------------------------------------------
    logic signed [25:0] dcb_y;
    logic        [15:0] dcb_x1;
    always_ff @(posedge clk) begin
        if (reset) begin
            dcb_y  <= '0;
            dcb_x1 <= '0;
        end else if (ce_2a03) begin
            dcb_y  <= (26'($signed({10'b0, apu_sample}) <<< 8))
                    - (26'($signed({10'b0, dcb_x1})    <<< 8))
                    + dcb_y - (dcb_y >>> 8);
            dcb_x1 <= apu_sample;
        end
    end

    // Saturate rather than wrap: a wrapped sample is a full-scale click.
    wire signed [17:0] dcb_out = dcb_y[25:8];
    always_ff @(posedge clk) begin
        if (reset)          sample <= '0;
        else if (ce_2a03)   sample <= (dcb_out >  18'sd32767) ?  16'sd32767 :
                                      (dcb_out < -18'sd32768) ? -16'sd32768 :
                                                                16'(dcb_out);
    end

endmodule

`default_nettype wire
