//------------------------------------------------------------------------------
// Punch-Out!! main board: the Z80, its memory map and its I/O.
//
// docs/hardware.md section 2 is the map this implements. Everything the CPU can
// reach is block RAM -- 48 KB of program, 1 KB of NVRAM, 2 KB of work RAM --
// except the video RAM, which lives in punchout_video so the renderer can read
// it on its own port.
//
// The Z80 runs at 4.000 MHz exactly, stepped by a clock enable off the 96 MHz
// system clock (96 / 24). Its NMI is the video vblank, gated by bit 0 of the
// 74LS259 addressable latch at I/O 08-0f.
//------------------------------------------------------------------------------
`default_nettype none

module punchout_main (
    input  wire         clk,             // 96 MHz
    input  wire         reset,
    input  wire         pause,           // hold the CPU; video keeps rendering

    //! ---- ROM download
    input  wire  [24:0] dl_addr,
    input  wire   [7:0] dl_data,
    input  wire         dl_we,

    //! ---- one pulse per frame from the video, at the start of vblank
    input  wire         vblank_rise,

    //! ---- cabinet inputs, all active high as the board reads them
    input  wire   [7:0] in0,             // d0 left punch, d2 right punch, d3 KO
    input  wire   [7:0] in1,             // d0 right d1 left d2 up d3 down,
                                         // d6 service, d7 coin
    input  wire   [7:0] dsw1,
    input  wire   [7:0] dsw2,
    input  wire         vlm_busy,        // VLM5030 BSY; reads back inverted

    //! ---- video RAM port, shared with punchout_video
    output logic [15:0] cpu_vaddr,
    output logic  [7:0] cpu_vdin,
    output logic        cpu_vwe,
    input  wire   [7:0] cpu_vq,

    //! ---- big sprite control registers and palette bank, mirrored out of the
    //!      dff0-dffd RAM so the renderer can latch them once a frame
    output logic [63:0] spr1_ctrl,
    output logic [39:0] spr2_ctrl,
    output logic  [7:0] palettebank,

    //! ---- to the sound board
    output logic  [7:0] soundlatch,
    output logic        soundlatch_wr,
    output logic  [7:0] soundlatch2,
    output logic        soundlatch2_wr,
    output logic        snd_reset,       // LS259 bit 3 -> 2A03 RESET

    //! ---- to the speech chip
    output logic  [7:0] vlm_data,
    output logic        vlm_data_wr,
    output logic        vlm_rst,         // LS259 bit 4
    output logic        vlm_st,          // LS259 bit 5
    output logic        vlm_vcu,         // LS259 bit 6

    //! ---- diagnostics
    output logic        dbg_nmi,
    //! ---- the NVRAM's second port: the Pocket loads a save into it at start,
    //!      reads it back at shutdown, and the records-reset wipes it
    input  wire   [9:0] nv_addr,
    input  wire         nv_we,
    input  wire   [7:0] nv_d,
    output wire   [7:0] nv_q,
    output wire         nv_dirty         // the Z80 wrote the NVRAM this clock
);
    // -------------------------------------------------------------------------
    // 4.000 MHz from 96 MHz: an exact divide by 24, so the CPU keeps arcade
    // speed rather than something close to it.
    // -------------------------------------------------------------------------
    logic [4:0] cdiv;
    logic       cpu_cen;
    always_ff @(posedge clk) begin
        if (reset) begin
            cdiv    <= '0;
            cpu_cen <= 1'b0;
        end else begin
            cpu_cen <= (cdiv == 5'd23) && !pause;
            cdiv    <= (cdiv == 5'd23) ? 5'd0 : cdiv + 5'd1;
        end
    end

    // -------------------------------------------------------------------------
    // CPU
    // -------------------------------------------------------------------------
    wire [15:0] A;
    wire  [7:0] cpu_do;
    wire        mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n;
    logic [7:0] cpu_di;
    logic       nmi_n;

    tv80s_cen u_cpu (
        .reset_n (~reset),
        .clk     (clk),
        .cen     (cpu_cen),
        .wait_n  (1'b1),
        .int_n   (1'b1),
        .nmi_n   (nmi_n),
        .busrq_n (1'b1),
        .m1_n    (m1_n),
        .mreq_n  (mreq_n),
        .iorq_n  (iorq_n),
        .rd_n    (rd_n),
        .wr_n    (wr_n),
        .rfsh_n  (rfsh_n),
        .halt_n  (),
        .busak_n (),
        .A       (A),
        .di      (cpu_di),
        .dout    (cpu_do)
    );

    wire mem_wr = !mreq_n && !wr_n && rfsh_n;
    wire io_rd  = !iorq_n && !rd_n && m1_n;
    wire io_wr  = !iorq_n && !wr_n && m1_n;

    // -------------------------------------------------------------------------
    // Address decode. c400-cfff and dfe0-dfef are unmapped on the board.
    // -------------------------------------------------------------------------
    wire sel_rom  = (A < 16'hc000);
    wire sel_nv   = (A[15:10] == 6'b1100_00);          // c000-c3ff
    wire sel_ram  = (A[15:11] == 5'b1101_0);           // d000-d7ff
    wire sel_vid  = (A >= 16'hd800);                   // d800-ffff, all video

    // A one-clock strobe at the start of each bus cycle. Gating on cpu_cen
    // instead would fire once per enable tick for as long as wr_n is low, which
    // is harmless for RAM but would hand the sound board and the speech chip
    // the same byte several times.
    logic mem_wr_d, io_wr_d;
    always_ff @(posedge clk) begin
        mem_wr_d <= mem_wr;
        io_wr_d  <= io_wr;
    end
    wire mem_wr_stb = mem_wr && !mem_wr_d;
    wire io_wr_stb  = io_wr  && !io_wr_d;

    // -------------------------------------------------------------------------
    // Program ROM, 48 KB. Split 32 + 16 rather than one 64 KB memory: the top
    // quarter of the address space is video RAM, and a 64 KB block RAM would
    // waste 16 KB of a part that has 385 KB in total.
    // -------------------------------------------------------------------------
    wire        in_prog_lo = (dl_addr < 25'h08000);
    wire        in_prog_hi = (dl_addr >= 25'h08000) && (dl_addr < 25'h0C000);
    logic [7:0] rom_lo_q, rom_hi_q;
    po_spram_dp #(.AW(15), .DW(8)) u_prog_lo (.clk(clk),
        .wa(dl_addr[14:0]), .we(dl_we && in_prog_lo), .d(dl_data),
        .ra(A[14:0]), .q(rom_lo_q));
    po_spram_dp #(.AW(14), .DW(8)) u_prog_hi (.clk(clk),
        .wa(dl_addr[13:0]), .we(dl_we && in_prog_hi), .d(dl_data),
        .ra(A[13:0]), .q(rom_hi_q));
    logic rom_hi_d;
    always_ff @(posedge clk) rom_hi_d <= A[15];

    // -------------------------------------------------------------------------
    // Work RAM, and the battery-backed NVRAM the Pocket can save and restore
    // -------------------------------------------------------------------------
    logic [7:0] ram_q;
    po_spram #(.AW(11), .DW(8)) u_ram (.clk(clk),
        .addr(A[10:0]), .we(mem_wr_stb && sel_ram), .d(cpu_do), .q(ram_q));

    // Single port for now. Persisting this to the SD card means giving it a
    // second port for the Pocket's save path -- and po_dpram with one port tied
    // off does not infer, so that change is a real one, not a wiring tweak.
    logic [7:0] nvram_q;
    assign nv_dirty = mem_wr_stb && sel_nv;
    po_dpram #(.AW(10), .DW(8)) u_nvram (.clk(clk),
        .a_addr(A[9:0]), .a_we(mem_wr_stb && sel_nv), .a_d(cpu_do), .a_q(nvram_q),
        .b_addr(nv_addr), .b_we(nv_we), .b_d(nv_d), .b_q(nv_q));

    // -------------------------------------------------------------------------
    // Video RAM port. The renderer owns the memories; this just forwards.
    // -------------------------------------------------------------------------
    assign cpu_vaddr = A;
    assign cpu_vdin  = cpu_do;
    assign cpu_vwe   = mem_wr_stb && sel_vid;

    // dff0-dffd are ordinary RAM that the video hardware also reads. They stay
    // in the tilemap memory so the CPU can read them back, and are mirrored
    // into registers here so the renderer can latch the set atomically.
    wire reg_hit = mem_wr_stb && (A[15:4] == 12'hdff);
    always_ff @(posedge clk) begin
        if (reset) begin
            spr1_ctrl   <= '0;
            spr2_ctrl   <= '0;
            palettebank <= '0;
        end else if (reg_hit) begin
            if (!A[3])                       spr1_ctrl[8*A[2:0] +: 8] <= cpu_do;   // dff0-dff7
            else if (A[2:0] <= 3'd4)         spr2_ctrl[8*A[2:0] +: 8] <= cpu_do;   // dff8-dffc
            else if (A[2:0] == 3'd5)         palettebank <= cpu_do;                // dffd
        end
    end

    // -------------------------------------------------------------------------
    // I/O
    // -------------------------------------------------------------------------
    logic [7:0] latch259;                 // chip 2B
    assign snd_reset = latch259[3];
    assign vlm_rst   = latch259[4];
    assign vlm_st    = latch259[5];
    assign vlm_vcu   = latch259[6];

    always_ff @(posedge clk) begin
        soundlatch_wr  <= 1'b0;
        soundlatch2_wr <= 1'b0;
        vlm_data_wr    <= 1'b0;
        if (reset) begin
            latch259 <= '0;
        end else if (io_wr_stb) begin
            case (A[3:0])
                4'h2: begin soundlatch  <= cpu_do; soundlatch_wr  <= 1'b1; end
                4'h3: begin soundlatch2 <= cpu_do; soundlatch2_wr <= 1'b1; end
                4'h4: begin vlm_data    <= cpu_do; vlm_data_wr    <= 1'b1; end
                default: if (A[3])   // 08-0f: 74LS259, D0 into bit (addr & 7)
                    latch259[A[2:0]] <= cpu_do[0];
            endcase
        end
    end

    // DSW1 bit 4 is not a switch: it is the VLM5030's busy line, active low.
    wire [7:0] dsw1_rd = {dsw1[7:5], ~vlm_busy, dsw1[3:0]};

    logic [7:0] io_q;
    always_comb begin
        case (A[1:0])
            2'd0: io_q = in0;
            2'd1: io_q = in1;
            2'd2: io_q = dsw2;
            default: io_q = dsw1_rd;
        endcase
    end

    // -------------------------------------------------------------------------
    // Read mux. Every memory is registered, so the select is delayed to match.
    // -------------------------------------------------------------------------
    // The memories are registered, so their data trails the address by one
    // clock. The address is stable for a whole 24-clock CPU cycle, so it has
    // long settled by the time the Z80 samples the bus.
    always_comb begin
        if      (io_rd)   cpu_di = io_q;
        else if (sel_rom) cpu_di = rom_hi_d ? rom_hi_q : rom_lo_q;
        else if (sel_nv)  cpu_di = nvram_q;
        else if (sel_ram) cpu_di = ram_q;
        else if (sel_vid) cpu_di = cpu_vq;
        else              cpu_di = 8'hff;
    end

    // -------------------------------------------------------------------------
    // NMI. tv80 latches the falling edge, so the line is pulsed low for a few
    // CPU cycles rather than held: held low it would still yield one NMI, but
    // it has to return high before the next frame for that edge to exist.
    // Clearing the enable clears a pending NMI, which is what nmi_mask_w does.
    // -------------------------------------------------------------------------
    logic [2:0] nmi_cnt;
    always_ff @(posedge clk) begin
        if (reset) begin
            nmi_cnt <= '0;
        end else if (!latch259[0]) begin
            nmi_cnt <= '0;
        end else if (vblank_rise) begin
            nmi_cnt <= 3'd4;
        end else if (cpu_cen && nmi_cnt != 3'd0) begin
            nmi_cnt <= nmi_cnt - 3'd1;
        end
    end
    assign nmi_n = (nmi_cnt == 3'd0);
    assign dbg_nmi = ~nmi_n;

endmodule

`default_nettype wire
