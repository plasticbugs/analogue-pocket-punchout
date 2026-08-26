//------------------------------------------------------------------------------
// Savestate stubs for the vendored NES APU.
//
// apu.sv comes from NES_MiSTer, where every register block is shadowed onto a
// savestate bus. This core has no savestates, so rather than editing 1300 lines
// of proven audio RTL, the two things it needs from that framework are provided
// here: the parameter package it reads its reset values from, and a register
// module that always hands back the default.
//
// The APU uses SS_*[...] as its reset values, so returning the defaults is
// exactly a cold start -- which is the only state this core ever wants.
//
// apu.sv itself is upstream except for one added `import regs_savestates::*;`
// so it stays diffable.
//------------------------------------------------------------------------------
`default_nettype none

package regs_savestates;
    parameter [9:0]  SSREG_INDEX_APU_TOP    = 10'd16;
    parameter [63:0] SSREG_DEFAULT_APU_TOP  = 64'h0000000000000000;
    parameter [9:0]  SSREG_INDEX_APU_DMC1   = 10'd17;
    parameter [63:0] SSREG_DEFAULT_APU_DMC1 = 64'h0000000000000000;
    parameter [9:0]  SSREG_INDEX_APU_DMC2   = 10'd18;
    parameter [63:0] SSREG_DEFAULT_APU_DMC2 = 64'h0000000000000000;
    parameter [9:0]  SSREG_INDEX_APU_FCT    = 10'd19;
    parameter [63:0] SSREG_DEFAULT_APU_FCT  = 64'h0000000000007FFF;
endpackage

module eReg_SavestateV #(
    parameter [9:0]  INDEX   = 10'd0,
    parameter [63:0] DEFAULT = 64'd0
) (
    input  wire        clk,
    input  wire [63:0] BUS_Din,
    input  wire  [9:0] BUS_Adr,
    input  wire        BUS_wren,
    input  wire        BUS_rst,
    output wire [63:0] BUS_Dout,
    input  wire [63:0] Din,          // the block's current state, for saving
    output wire [63:0] Dout          // what the block resets to
);
    assign BUS_Dout = 64'd0;
    assign Dout     = DEFAULT;
endmodule

`default_nettype wire
