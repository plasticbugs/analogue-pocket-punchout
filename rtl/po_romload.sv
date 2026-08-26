//------------------------------------------------------------------------------
// Where each byte of the ROM image goes.
//
// The flat image built by tools/mra_build.py keeps MAME's region layout, which
// is planar: gfx3's three bit planes are 0x10000 apart and gfx4's two are
// 0x8000 apart. Reading a tile row straight out of that layout would be three
// scattered SDRAM reads for gfx3 and two for gfx4.
//
// So the planes are interleaved on the way in, which costs nothing because the
// loader sees every byte exactly once and the mapping is pure bit shuffling:
//
//   gfx3  tile row t -> four bytes at t*4:   plane0, plane1, plane2, unused
//   gfx4  tile row t -> two bytes at t*2:    plane0, plane1
//
// A tile row is then one 16-bit read for gfx4 and two for gfx3, and the
// renderer's per-line SDRAM budget halves (METHODOLOGY 5.2).
//
// Everything before gfx3 -- program, sound program, background characters,
// colour PROMs -- goes to block RAM instead and never reaches here.
//------------------------------------------------------------------------------
`default_nettype none

module po_romload (
    input  wire  [24:0] dl_addr,
    input  wire   [7:0] dl_data,
    input  wire         dl_we,

    output logic [24:0] sd_addr,
    output logic  [7:0] sd_data,
    output logic        sd_we
);
    // image layout, from docs/hardware.md section 10
    localparam [24:0] IMG_GFX3 = 25'h1_6000, IMG_GFX3_END = 25'h4_6000;
    localparam [24:0] IMG_GFX4 = 25'h4_6000, IMG_GFX4_END = 25'h5_6000;
    localparam [24:0] IMG_VLM  = 25'h5_6C00, IMG_VLM_END  = 25'h5_AC00;

    // where they land in SDRAM
    localparam [24:0] SD_GFX3 = 25'h0_0000;   // 0x10000 rows * 4 bytes
    localparam [24:0] SD_GFX4 = 25'h4_0000;   // 0x08000 rows * 2 bytes
    localparam [24:0] SD_VLM  = 25'h5_0000;   // 16 KB, flat

    wire in_gfx3 = (dl_addr >= IMG_GFX3) && (dl_addr < IMG_GFX3_END);
    wire in_gfx4 = (dl_addr >= IMG_GFX4) && (dl_addr < IMG_GFX4_END);
    wire in_vlm  = (dl_addr >= IMG_VLM)  && (dl_addr < IMG_VLM_END);

    wire [17:0] g3_off = dl_addr[17:0] - IMG_GFX3[17:0];   // plane in [17:16]
    wire [15:0] g4_off = dl_addr[15:0] - IMG_GFX4[15:0];   // plane in [15]
    wire [13:0] vl_off = dl_addr[13:0] - IMG_VLM[13:0];

    always_comb begin
        sd_data = dl_data;
        sd_we   = dl_we && (in_gfx3 || in_gfx4 || in_vlm);
        if (in_gfx3)      sd_addr = SD_GFX3 + {5'b0, g3_off[15:0], g3_off[17:16]};
        else if (in_gfx4) sd_addr = SD_GFX4 + {8'b0, g4_off[14:0], g4_off[15]};
        else              sd_addr = SD_VLM  + {11'b0, vl_off};
    end
endmodule

`default_nettype wire
