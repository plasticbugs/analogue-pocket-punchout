//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2024, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// Simple SDRAM controller with universal 8/16 bit mode
//
// Copyright (c) 2015-2019, Alexey Melnikov <pour.garbage@gmail.com>
// Copyright (c) 2013, Mike Field <hamster@snap.net.nz>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.
//
//------------------------------------------------------------------------------
// Implementation using Micron MT48LC16M16A2 – 4 Meg x 16 x 4 banks SDR SDRAM
//------------------------------------------------------------------------------

module sdram16 #(
        // (64 ms / 8192 rows) = 7.8125 us between refreshes: 750 cycles at
        // the 96 MHz this core clocks it at. (An earlier value of 375 assumed
        // 48 MHz and refreshed twice as often as needed -- harmless, but it
        // cost bandwidth for nothing.)
        parameter [13:0] CYCLES_PER_REFRESH = 14'd750
    ) (
        input             init,        // Reset to initialize RAM
        input             clk,         // Controller clock, 96 MHz
        // SDRAM_CLK is made from this, not from clk. It is the same frequency
        // from the same PLL, phase-shifted so that the chip's clock edge at
        // its pin lands just after the controller's internal edge. That gives
        // the chip's data a full period to arrive instead of half of one --
        // see the read-capture note below and docs/verification.md.
        input             clk_pin,
        // 1: read data is captured one clock later than the Xenophobe-era
        // controller did (READ+4 at the pins), which is where it lands with
        // the chip clocked in phase. 0 is the old capture point, kept only as
        // a diagnostic the Pocket menu can flip without a rebuild.
        input             rd_late,
        // SDRAM signals
        inout  wire[15:0] SDRAM_DQ,    // 16 bit bidirectional data bus
        output reg [12:0] SDRAM_A,     // 13 bit multiplexed address bus
        output reg        SDRAM_DQML,  // Lower Input/Output Mask
        output reg        SDRAM_DQMH,  // Upper Input/Output Mask
        output reg  [1:0] SDRAM_BA,    // Two banks
        output            SDRAM_nCS,   // A single chip select
        output            SDRAM_nWE,   // Write enable
        output            SDRAM_nRAS,  // Row address select
        output            SDRAM_nCAS,  // Columns address select
        output            SDRAM_CKE,   // Clock enable
        output            SDRAM_CLK,   // SDRAM Clock
        // User Interface
        input      [24:0] addr,        // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
        output      [7:0] dout,        // Data output to cpu
        output     [15:0] dout16,      // Full 16-bit word (issue reads with addr[0]=0)
        // burst port: 8 consecutive words starting at a 16-byte boundary
        input      [24:4] baddr,       // 16-byte block address
        input             brd,         // edge-triggered like rd
        output reg [127:0] bdata,      // words 0..7, [15:0] first
        output reg        bready,
        input       [7:0] din,         // Data input from cpu
        input             we,          // Cpu requests write
        input             rd,          // Cpu requests read
        output reg        ready        // Dout is valid. Ready to accept new read/write.
    );

    assign SDRAM_CKE  = 1;
    assign SDRAM_nCS  = 0;

    // Explicit output enable rather than assigning 16'bZ to an inout reg from
    // inside the clocked block. The two forms synthesise to the same registered
    // tristate, but Verilator's procedural-tristate handling keeps the enable
    // asserted from the last non-Z assignment, so the controller went on
    // driving the previous write's data over the chip's read data and every
    // read came back as that byte doubled. Cost a long afternoon; the hardware
    // was never wrong, only the simulation of it.
    reg [15:0] dq_out;
    reg        dq_oe;
    assign SDRAM_DQ = dq_oe ? dq_out : 16'bZ;
    assign SDRAM_nRAS = command[2];
    assign SDRAM_nCAS = command[1];
    assign SDRAM_nWE  = command[0];
    assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

    // no burst configured
    localparam BURST_LENGTH         = 3'b000;   // 000=1, 001=2, 010=4, 011=8
    localparam ACCESS_TYPE          = 1'b0;     // 0=sequential, 1=interleaved
    localparam CAS_LATENCY          = 3'd2;     // 2 for < 100MHz, 3 for >100MHz
    localparam OP_MODE              = 2'b00;    // only 00 (standard operation) allowed
    localparam NO_WRITE_BURST       = 1'b1;     // 0= write burst enabled, 1=only single access write
    localparam MODE                 = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

    localparam sdram_startup_cycles = 14'd12100;// 100us, plus a little more, @ 100MHz
    localparam [13:0] cycles_per_refresh = CYCLES_PER_REFRESH;
    localparam startup_refresh_max  = 14'b11111111111111;

    // SDRAM commands
    wire [2:0] CMD_NOP              = 3'b111;
    wire [2:0] CMD_ACTIVE           = 3'b011;
    wire [2:0] CMD_READ             = 3'b101;
    wire [2:0] CMD_WRITE            = 3'b100;
    wire [2:0] CMD_PRECHARGE        = 3'b010;
    wire [2:0] CMD_AUTO_REFRESH     = 3'b001;
    wire [2:0] CMD_LOAD_MODE        = 3'b000;

    reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
    reg  [2:0] command;
    reg [24:0] save_addr;

    reg [15:0] data;
    assign dout   = save_addr[0] ? data[15:8] : data[7:0];
    assign dout16 = data;

    typedef enum {
        STATE_STARTUP,
        STATE_OPEN_1, STATE_OPEN_2,
        STATE_IDLE,	  STATE_IDLE_1, STATE_IDLE_2, STATE_IDLE_3,
        STATE_IDLE_4, STATE_IDLE_5, STATE_IDLE_6, STATE_IDLE_7,
        STATE_BOPEN, STATE_BREAD
    } state_t;

    always @(posedge clk) begin
        reg old_we, old_rd, old_brd, new_brd;
        reg [2:0] bcol;
        reg       bphase;
        reg [2:0] bdelay;
        reg [CAS_LATENCY+2:0] data_ready_delay;
        reg [15:0] dq_in;

        reg  [7:0] new_data;
        reg        new_we;
        reg        new_rd;
        reg [24:0] new_waddr;
        // No declaration initialiser on either of these: a blocking assignment
        // to a variable the block otherwise drives non-blocking is an
        // Unsupported error in Verilator 5.020 (5.050 lets it pass), and the
        // init path below establishes both anyway -- which is better than a
        // power-on value, because it also re-establishes them on reset.
        reg        save_we;

        state_t state;

        dq_oe    <= 1'b0;
        command  <= CMD_NOP;
        refresh_count  <= refresh_count+1'b1;

        // DQ is sampled into dq_in every clock, unconditionally, so the
        // register can live in the I/O cell right at the pin (an enable would
        // keep it out). The pipeline below then decides which sample is the
        // read data. Read capture: the chip samples our READ at its edge after
        // ours, drives data CAS_LATENCY edges later, and that arrives here in
        // time for the NEXT edge -- so with the in-phase clock the good sample
        // is dq_in taken at READ+4, transferred at READ+5. The Xenophobe-era
        // capture at READ+3 assumed the chip's edge sat half a period ahead,
        // which left 5.2 ns at 96 MHz for a 6.5 ns access time: the timing
        // analyser put that path at -7.5 ns once the exception hiding it was
        // removed, and on the Pocket every sprite came out as garbage.
        dq_in <= SDRAM_DQ;
        data_ready_delay <= {1'b0, data_ready_delay[CAS_LATENCY+2:1]};

        if(data_ready_delay[0])
            {ready, data}  <= {1'b1, dq_in};

        case(state)
            STATE_STARTUP: begin
                SDRAM_A    <= 0;
                SDRAM_BA   <= 0;

                if (refresh_count == startup_refresh_max-31) begin
                    command     <= CMD_PRECHARGE;
                    SDRAM_A[10] <= 1;  // all banks
                    SDRAM_BA    <= 2'b00;
                end
                if (refresh_count == startup_refresh_max-23) begin
                    command     <= CMD_AUTO_REFRESH;
                end
                if (refresh_count == startup_refresh_max-15) begin
                    command     <= CMD_AUTO_REFRESH;
                end
                if (refresh_count == startup_refresh_max-7) begin
                    command     <= CMD_LOAD_MODE;
                    SDRAM_A     <= MODE;
                end

                if(!refresh_count) begin
                    state         <= STATE_IDLE;
                    ready         <= 1;
                    refresh_count <= 0;
                end
            end

            STATE_IDLE_7: begin state <= STATE_IDLE_6; end
            STATE_IDLE_6: begin state <= STATE_IDLE_5; end
            STATE_IDLE_5: begin state <= STATE_IDLE_4; end
            STATE_IDLE_4: begin state <= STATE_IDLE_3; end
            STATE_IDLE_3: begin state <= STATE_IDLE_2; end
            STATE_IDLE_2: begin state <= STATE_IDLE_1; end
            STATE_IDLE_1: begin
                state <= STATE_IDLE;
                // mask possible refresh to reduce colliding.
                if(refresh_count > cycles_per_refresh) begin
                    state         <= STATE_IDLE_7;
                    command       <= CMD_AUTO_REFRESH;
                    refresh_count <= 0;
                end
            end

            STATE_BOPEN: begin
                bcol   <= '0;
                bphase <= 1'b0;
                state  <= STATE_BREAD;
            end

            STATE_BREAD: begin
                // One read at a time inside the open row. This is PROVEN on
                // hardware; issuing reads back-to-back instead (even carrying
                // the destination index down the pipeline) reproduces the
                // mirrored-sprite corruption, because with only one read in
                // flight the data stays on the bus long enough for the
                // capture to land correctly regardless of exact latency.
                // Speed must come from the renderer, not from pipelining this.
                if (!bphase) begin
                    command <= CMD_READ;
                    SDRAM_A <= {2'b00, (bcol == 3'd7), 1'b0, baddr[9:4], bcol};
                    bdelay  <= 3'b100;
                    bphase  <= 1'b1;
                end else begin
                    bdelay <= {1'b0, bdelay[2:1]};
                    if (bdelay[0]) begin
                        case (bcol)
                            3'd0: bdata[ 15:  0] <= SDRAM_DQ;
                            3'd1: bdata[ 31: 16] <= SDRAM_DQ;
                            3'd2: bdata[ 47: 32] <= SDRAM_DQ;
                            3'd3: bdata[ 63: 48] <= SDRAM_DQ;
                            3'd4: bdata[ 79: 64] <= SDRAM_DQ;
                            3'd5: bdata[ 95: 80] <= SDRAM_DQ;
                            3'd6: bdata[111: 96] <= SDRAM_DQ;
                            3'd7: bdata[127:112] <= SDRAM_DQ;
                        endcase
                        if (bcol == 3'd7) begin
                            bready <= 1'b1;
                            state  <= STATE_IDLE_2;
                        end else begin
                            bcol   <= bcol + 1'd1;
                            bphase <= 1'b0;
                        end
                    end
                end
            end

            STATE_IDLE: begin
                // Priority is to issue a refresh if one is outstanding
                if(refresh_count > (cycles_per_refresh<<1))
                    state <= STATE_IDLE_1;
                else if(new_brd) begin
                    new_brd  <= 0;
                    SDRAM_A  <= baddr[22:10];
                    SDRAM_BA <= baddr[24:23];
                    command  <= CMD_ACTIVE;
                    state    <= STATE_BOPEN;
                end
                else if(new_rd | new_we) begin
                    // Service ONE op and leave the other queued: clearing
                    // both here silently dropped a read that arrived while
                    // a write was pending. Writes go first so a following
                    // read observes the new data. The write must use the
                    // address captured at its request edge -- CPU writes
                    // are posted and the bus has long since moved on.
                    if (new_we) begin
                        new_we    <= 0;
                        save_we   <= 1'b1;
                        save_addr <= new_waddr;
                        SDRAM_A   <= new_waddr[22:10];
                        SDRAM_BA  <= new_waddr[24:23];
                    end
                    else begin
                        new_rd    <= 0;
                        save_we   <= 1'b0;
                        save_addr <= addr;
                        SDRAM_A   <= addr[22:10];
                        SDRAM_BA  <= addr[24:23];
                    end
                    state     <= STATE_OPEN_1;
                    command   <= CMD_ACTIVE;
                end
            end

            STATE_OPEN_1: begin state <= STATE_OPEN_2; end

            STATE_OPEN_2: begin
                SDRAM_A      <= {save_we & ~save_addr[0], save_we & save_addr[0], 2'b10, save_addr[9:1]};
                if(save_we) begin
                    command  <= CMD_WRITE;
                    dq_out   <= {new_data[7:0], new_data[7:0]};
                    dq_oe    <= 1'b1;
                    // a read that queued behind this write is still owed
                    // its data: raising ready here released the WAITing
                    // CPU with the previous read's stale byte
                    ready    <= ~new_rd;
                    // IDLE_3, not IDLE_2: ACTIVE to the next ACTIVE must be at
                    // least tRC, 63 ns on the Pocket's part. Through IDLE_2 the
                    // write cycle was 6 clocks, 62.5 ns at 96 MHz.
                    state    <= STATE_IDLE_3;
                end
                else begin
                    command <= CMD_READ;
                    if (rd_late) data_ready_delay[CAS_LATENCY+2] <= 1;
                    else         data_ready_delay[CAS_LATENCY+1] <= 1;
                    state   <= STATE_IDLE_5;
                end
            end
        endcase

        if(init) begin
            state         <= STATE_STARTUP;
            refresh_count <= startup_refresh_max - sdram_startup_cycles;
            save_we       <= 1'b1;   // so the first read cannot take the
                                     // same-address cache path against a
                                     // save_addr that is still zero
        end

        old_we <= we;
        if(we & ~old_we) begin
            {ready, new_we, new_data} <= {1'b0, 1'b1, din};
            new_waddr <= addr;
        end

        old_brd <= brd;
        if(brd & ~old_brd) begin
            {bready, new_brd} <= {1'b0, 1'b1};
        end

        old_rd <= rd;
        if(rd & ~old_rd) begin
            if(ready & ~save_we & (save_addr[24:1] == addr[24:1])) begin
                save_addr <= addr;
            end
            else begin
                {ready, new_rd} <= {1'b0, 1'b1};
            end
        end
    end

`ifdef VERILATOR
    assign SDRAM_CLK = clk_pin;   // the model clocks itself; see sdram_model
`else
    altddio_out #(
        .extend_oe_disable      ( "OFF"          ),
        .intended_device_family ( "Cyclone V"    ),
        .invert_output          ( "OFF"          ),
        .lpm_hint               ( "UNUSED"       ),
        .lpm_type               ( "altddio_out"  ),
        .oe_reg                 ( "UNREGISTERED" ),
        .power_up_high          ( "OFF"          ),
        .width                  ( 1              )
    ) sdramclk_ddr (
        // In phase with clk_pin (high first), not inverted as the original
        // was: the phase is set at the PLL, where the timing analyser can see
        // it, rather than by flipping the clock here where it cannot.
        .datain_h               ( 1'b1           ),
        .datain_l               ( 1'b0           ),
        .outclock               ( clk_pin        ),
        .dataout                ( SDRAM_CLK      ),
        .aclr                   ( 1'b0           ),
        .aset                   ( 1'b0           ),
        .oe                     ( 1'b1           ),
        .outclocken             ( 1'b1           ),
        .sclr                   ( 1'b0           ),
        .sset                   ( 1'b0           )
    );
`endif

endmodule
