//------------------------------------------------------------------------------
// T65 black box, for Verilator only.
//
// The 6502 in the 2A03 is T65, which is VHDL: Quartus compiles it, Verilator
// does not. This stub lets the sound board be linted and lets the APU be driven
// from a captured register-write trace, which is a better test of the APU than
// running the real program through it would be anyway.
//
// Never in the synthesis file list -- see rtl/index.qip.
//------------------------------------------------------------------------------
`default_nettype none

module T65 (
    input  wire  [1:0] Mode,
    input  wire        BCD_en,
    input  wire        Res_n,
    input  wire        Enable,
    input  wire        Clk,
    input  wire        Rdy,
    input  wire        Abort_n,
    input  wire        IRQ_n,
    input  wire        NMI_n,
    input  wire        SO_n,
    output wire        R_W_n,
    output wire        Sync,
    output wire        EF, MF, XF, ML_n, VP_n, VDA, VPA,
    output wire [23:0] A,
    input  wire  [7:0] DI,
    output wire  [7:0] DO,
    output wire [63:0] Regs,
    output wire [63:0] DEBUG,
    output wire        NMI_ack
);
    // Register-write player: the C++ bench pokes these each cycle to replay a
    // captured trace onto the sound bus. Idle (we=0) reads e000, so the CPU
    // "runs" harmlessly; we=1 presents a write to 4000+addr with data.
    logic       inj_we   /* verilator public_flat_rw */ = 1'b0;
    logic [4:0] inj_addr /* verilator public_flat_rw */ = 5'd0;
    logic [7:0] inj_data /* verilator public_flat_rw */ = 8'd0;
    assign R_W_n = ~inj_we;
    assign Sync = 1'b0;
    assign {EF, MF, XF, ML_n, VP_n, VDA, VPA} = 7'b0;
    assign A = inj_we ? (24'h00_4000 | {19'b0, inj_addr}) : 24'hE000;   // 4000 + addr
    assign DO = inj_data;
    assign Regs = 64'd0;
    assign DEBUG = 64'd0;
    assign NMI_ack = 1'b0;
endmodule

`default_nettype wire
