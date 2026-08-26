//------------------------------------------------------------------------------
// Block RAM primitives for the Punch-Out!! core.
//
// Everything that fits lives here -- program, background characters, PROMs,
// work RAM and the video RAMs -- and every access is single cycle. The two big
// sprite ROMs do not fit and live in SDRAM instead (docs/hardware.md 9).
// Reads are registered: drive the address on cycle N, data is valid on N+1.
//------------------------------------------------------------------------------
`default_nettype none

//! One write port, one read port. Read-during-write to the same address
//! returns the old contents, which is what Quartus infers for this style.
module po_spram_dp #(parameter AW = 8, parameter DW = 8) (
    input  wire           clk,
    input  wire  [AW-1:0] wa,
    input  wire           we,
    input  wire  [DW-1:0] d,
    input  wire  [AW-1:0] ra,
    output logic [DW-1:0] q
);
    logic [DW-1:0] mem [0:(1<<AW)-1] /* verilator public_flat_rd */;
    // Assignment pattern rather than a for loop: Quartus caps constant loops
    // at 5000 iterations, and the program ROM alone is 32768 words.
    initial mem = '{default: '0};
    always_ff @(posedge clk) begin
        if (we) mem[wa] <= d;
        q <= mem[ra];
    end
endmodule

//! One port that both reads and writes -- a CPU bus port.
//!
//! Do NOT use po_dpram with its second port tied off for this. Quartus then
//! sees a port whose output goes nowhere, gives up with "uninferred due to
//! asynchronous read logic", and builds the whole array out of flip-flops. The
//! work RAM, the NVRAM and the sound RAM all did exactly that.
//!
//! Write-through on the write cycle, for the same reason po_dpram does it: an
//! M10K cannot return the old contents on a write, and asking for that drops
//! the memory into logic. A CPU bus cycle is a read or a write, never both, so
//! what it returns on its own write is unobservable.
module po_spram #(parameter AW = 11, parameter DW = 8) (
    input  wire           clk,
    input  wire  [AW-1:0] addr,
    input  wire           we,
    input  wire  [DW-1:0] d,
    output logic [DW-1:0] q
);
    logic [DW-1:0] mem [0:(1<<AW)-1] /* verilator public_flat_rd */;
    initial mem = '{default: '0};
    always_ff @(posedge clk) begin
        if (we) begin
            mem[addr] <= d;
            q         <= d;
        end else begin
            q <= mem[addr];
        end
    end
endmodule

//! One write port and one read port, the read gated by an enable.
//!
//! The line buffers need this: the renderer writes every clock while the
//! display reads once per pixel clock. Splitting those into two always blocks
//! is what stopped them inferring -- 4096 flip-flops for 512 bytes -- and the
//! M10K has a read clock enable that does the job properly.
module po_spram_re #(parameter AW = 8, parameter DW = 8) (
    input  wire           clk,
    input  wire  [AW-1:0] wa,
    input  wire           we,
    input  wire  [DW-1:0] d,
    input  wire  [AW-1:0] ra,
    input  wire           re,
    output logic [DW-1:0] q
);
    logic [DW-1:0] mem [0:(1<<AW)-1] /* verilator public_flat_rd */;
    initial mem = '{default: '0};
    always_ff @(posedge clk) begin
        if (we) mem[wa] <= d;
        if (re) q <= mem[ra];
    end
endmodule

//! True dual port: two independent read/write ports on one array.
module po_dpram #(parameter AW = 10, parameter DW = 8) (
    input  wire           clk,
    input  wire  [AW-1:0] a_addr,
    input  wire           a_we,
    input  wire  [DW-1:0] a_d,
    output logic [DW-1:0] a_q,
    input  wire  [AW-1:0] b_addr,
    input  wire           b_we,
    input  wire  [DW-1:0] b_d,
    output logic [DW-1:0] b_q
);
    logic [DW-1:0] mem [0:(1<<AW)-1] /* verilator public_flat_rd */;
    // Assignment pattern rather than a for loop: Quartus caps constant loops
    // at 5000 iterations, and the program ROM alone is 32768 words.
    initial mem = '{default: '0};

    // One always block PER PORT, which is Altera's true dual-port template.
    // Writing both ports from a single block infers fine while only one of them
    // writes, and silently fails the moment both do: the 2 KB shared RAM
    // between the two 6809s came out as 31,568 ALUTs and 16,400 flip-flops --
    // 73% of the whole design and the reason it would not fit.
    // Write-through on each port, not read-old-data: an M10K in true dual-port
    // mode cannot return the old contents on a write, so the read-old form
    // falls back to logic and the 2 KB shared RAM came out as 31,568 ALUTs and
    // 16,400 flip-flops -- 73% of the design, and why it would not fit.
    //
    // Nothing here reads and writes the same port in the same cycle: a CPU bus
    // cycle is a read or a write, never both, and the video ports are
    // read-only. So which data a port returns on its own write is unobservable.
    /* verilator lint_off MULTIDRIVEN */
    always_ff @(posedge clk) begin
        if (a_we) begin
            mem[a_addr] <= a_d;
            a_q         <= a_d;
        end else begin
            a_q <= mem[a_addr];
        end
    end

    always_ff @(posedge clk) begin
        if (b_we) begin
            mem[b_addr] <= b_d;
            b_q         <= b_d;
        end else begin
            b_q <= mem[b_addr];
        end
    end
    /* verilator lint_on MULTIDRIVEN */
endmodule

`default_nettype wire
