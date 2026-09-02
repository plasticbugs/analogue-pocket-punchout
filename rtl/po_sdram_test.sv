// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: (c) 2026 plasticbugs
//
// Part of an Analogue Pocket openFPGA core for Nintendo's Punch-Out!! board.
// Hardware behaviour derived from MAME's nintendo/punchout.cpp by Nicola
// Salmoria; see README.md for full credits.
//------------------------------------------------------------------------------
// SDRAM self-test, for the diagnostic overlay.
//
// Two checks, run with the machine held in reset, once after the ROM has
// loaded and again whenever the read-timing setting changes:
//
//   ROM     read every graphics byte back in the order the loader wrote it and
//           compare a running checksum against the one the loader accumulated
//           from the stream it was handed. A mismatch means the data in the
//           chip is not what the bridge sent -- a dropped or misplaced byte on
//           the way in, or a read that returns the wrong thing on the way out.
//
//   PATTERN write a known sequence to a spare region above the ROM, read it
//           back and compare. This one never touches the loader, so it isolates
//           the controller and its timing: PATTERN bad means the chip cannot be
//           read or written correctly at this clock and phase, whatever the
//           loader did. ROM bad with PATTERN good means the loader.
//
// On the Pocket the first build showed every background tile correct and every
// sprite tile as garbage, which said "SDRAM" and nothing more. This exists so
// the next such report can say which half.
//------------------------------------------------------------------------------
`default_nettype none

module po_sdram_test (
    input  wire         clk,
    input  wire         reset,
    input  wire         go,            // one-clock pulse: run both checks
    input  wire  [31:0] ref_sum,       // the loader's checksum of what it sent

    output logic        busy,
    output logic  [1:0] rom_st,        // 0 not run, 1 pass, 2 fail, 3 running
    output logic  [1:0] pat_st,

    // sdram16 user port
    output logic [24:0] sd_addr,
    output logic  [7:0] sd_din,
    output logic        sd_we,
    output logic        sd_rd,
    input  wire  [15:0] sd_dout16,
    input  wire         sd_ready
);
    // The SDRAM-bound part of the ROM image, in image offsets; the same
    // mapping the loader uses turns each into a chip address (or says the byte
    // never went to the chip, as the colour PROMs do not).
    localparam [24:0] IMG_LO = 25'h1_6000;
    localparam [24:0] IMG_HI = 25'h5_AC00;
    localparam [24:0] PAT_BASE = 25'h6_0000;    // above everything the ROM uses
    localparam        PAT_WORDS = 1024;

    logic [24:0] off;
    wire  [24:0] map_addr;
    wire   [7:0] map_data;
    wire         map_we;
    po_romload u_map (.dl_addr(off), .dl_data(8'h00), .dl_we(1'b1),
                      .sd_addr(map_addr), .sd_data(map_data), .sd_we(map_we));

    // A byte the pattern test can regenerate from its address alone.
    function automatic [7:0] pb(input [10:0] a);
        pb = (a[7:0] + {a[10:8], 5'b10101}) ^ 8'hA5 ^ {a[9:6], a[3:0]};
    endfunction

    typedef enum logic [3:0] {
        T_IDLE, T_ROM_STEP, T_ROM_WAIT, T_ROM_DONE,
        T_PAT_WR, T_PAT_WRW, T_PAT_RD, T_PAT_RDW, T_PAT_DONE
    } tstate_e;
    tstate_e st;

    logic [31:0] sum;
    logic [10:0] i;
    logic  [1:0] wt;
    logic        bad;
    wire   [7:0] rd_byte = map_addr[0] ? sd_dout16[15:8] : sd_dout16[7:0];

    always_ff @(posedge clk) begin
        if (reset) begin
            st <= T_IDLE; busy <= 1'b0; sd_we <= 1'b0; sd_rd <= 1'b0;
            rom_st <= 2'd0; pat_st <= 2'd0;
        end else begin
            sd_we <= 1'b0;
            sd_rd <= 1'b0;
            case (st)
                T_IDLE: if (go) begin
                    busy <= 1'b1; rom_st <= 2'd3; pat_st <= 2'd3;
                    sum <= '0; off <= IMG_LO; st <= T_ROM_STEP;
                end

                // ---- ROM readback, in loader order
                T_ROM_STEP: begin
                    if (off == IMG_HI)  st <= T_ROM_DONE;
                    else if (!map_we)   off <= off + 25'd1;       // never in the chip
                    else begin
                        sd_addr <= {map_addr[24:1], 1'b0};
                        sd_rd   <= 1'b1;
                        wt      <= 2'd3;
                        st      <= T_ROM_WAIT;
                    end
                end
                // sdram16 answers a repeat of the previous word from its cache
                // without ever dropping ready, so wait for a falling edge would
                // hang. Settle, then poll.
                T_ROM_WAIT: begin
                    if (wt != 2'd0) wt <= wt - 2'd1;
                    else if (sd_ready) begin
                        sum <= sum + {16'b0, map_addr[7:0], rd_byte};
                        off <= off + 25'd1;
                        st  <= T_ROM_STEP;
                    end
                end
                T_ROM_DONE: begin
                    rom_st <= (sum == ref_sum) ? 2'd1 : 2'd2;
                    i <= '0; bad <= 1'b0; st <= T_PAT_WR;
                end

                // ---- pattern: 2048 byte writes, then 1024 word reads
                T_PAT_WR: begin
                    sd_addr <= PAT_BASE + {14'b0, i};
                    sd_din  <= pb(i);
                    sd_we   <= 1'b1;
                    wt      <= 2'd3;
                    st      <= T_PAT_WRW;
                end
                T_PAT_WRW: begin
                    if (wt != 2'd0) wt <= wt - 2'd1;
                    else if (sd_ready) begin
                        i  <= i + 11'd1;
                        st <= (i == 11'd2047) ? T_PAT_RD : T_PAT_WR;
                        if (i == 11'd2047) i <= '0;
                    end
                end
                T_PAT_RD: begin
                    sd_addr <= PAT_BASE + {14'b0, i[9:0], 1'b0};
                    sd_rd   <= 1'b1;
                    wt      <= 2'd3;
                    st      <= T_PAT_RDW;
                end
                T_PAT_RDW: begin
                    if (wt != 2'd0) wt <= wt - 2'd1;
                    else if (sd_ready) begin
                        if (sd_dout16 != {pb({i[9:0], 1'b1}), pb({i[9:0], 1'b0})}) bad <= 1'b1;
                        i  <= i + 11'd1;
                        st <= (i == 11'd1023) ? T_PAT_DONE : T_PAT_RD;
                    end
                end
                T_PAT_DONE: begin
                    pat_st <= bad ? 2'd2 : 2'd1;
                    busy   <= 1'b0;
                    st     <= T_IDLE;
                end
                default: st <= T_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
