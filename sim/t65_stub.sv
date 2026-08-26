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
    assign R_W_n = 1'b1;
    assign Sync = 1'b0;
    assign {EF, MF, XF, ML_n, VP_n, VDA, VPA} = 7'b0;
    assign A = 24'hE000;
    assign DO = 8'h00;
    assign Regs = 64'd0;
    assign DEBUG = 64'd0;
    assign NMI_ack = 1'b0;
endmodule

`default_nettype wire
