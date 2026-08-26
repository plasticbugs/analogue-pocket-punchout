//! VLM5030 BUSY, without the voice.
//!
//! The game paces its display against the speech chip's BUSY line: it starts
//! a phrase and then sequences cues -- the blinking fighter introduction
//! before the bout, the blinking VS, among others -- against BUSY dropping.
//! Before this module the core answered "never busy", so a knock-down phrase
//! finished the instant it started and the game ran its pre-bout blink cue in
//! the middle of the opponent's gloat: a black bar of the introduction's
//! cells in the ring, in step with the VS turning yellow. Reproduced in MAME
//! by forcing the same answer.
//!
//! This holds BUSY for exactly as long as the chip would, from MAME's
//! vlm5030.cpp: BUSY rises on ST's rising edge; speech starts on its falling
//! edge, when the phrase's frame count (tools/vlm_durations.py walked the
//! speech ROM the way the chip does) is scaled by the speed parameter the
//! game latched on RST's falling edge -- every frame is 4 interpolation
//! periods of frame_size samples -- plus one period after the end marker and
//! one sample, at 3579545/440 Hz; then BUSY drops. RST rising while busy
//! resets the chip. The direct-address mode (VCU high) is not used by this
//! game and is treated as a phrase of no frames.
//!
//! The VLM5030 proper -- the voice -- replaces this later; the interface is
//! the chip's pins so that is a drop-in.
module po_vlm_busy (
    input  wire        clk,             // 96 MHz
    input  wire        reset,
    input  wire        rst,             // chip RST pin (LS259 bit 4)
    input  wire        st,              // chip ST pin  (LS259 bit 5)
    input  wire        vcu,             // chip VCU pin (LS259 bit 6)
    input  wire  [7:0] data,            // the byte latched at port 4
    output logic       busy
);
    `include "po_vlm_phrases.svh"

    // sample clock: 3579545 / 440 = 8135.33 Hz from 96 MHz
    localparam logic [31:0] CE_INC = 32'd363968;
    logic [31:0] acc;
    logic        sample_ce;
    always_ff @(posedge clk) begin
        {sample_ce, acc} <= {1'b0, acc} + {1'b0, CE_INC};
    end

    // speed parameter -> frame_size (samples per interpolation period)
    logic [7:0] param;
    logic [6:0] frame_size;
    always_comb begin
        case (param[5:3])
            3'd0: frame_size = 7'd40;   // normal
            3'd1: frame_size = 7'd30;   // fast
            3'd2: frame_size = 7'd20;   // faster
            3'd3: frame_size = 7'd20;
            3'd4: frame_size = 7'd40;
            3'd5: frame_size = 7'd60;   // slower
            3'd6: frame_size = 7'd50;   // slow
            default: frame_size = 7'd50;
        endcase
    end

    logic        rst_d, st_d;
    logic [23:0] remain;            // samples of BUSY left
    logic [11:0] frames;            // the phrase's frame count
    logic [23:0] samples_total;
    // frames * 4 * frame_size + frame_size + 1 -- a multiply that only has
    // to be right many clocks after ST falls, so it is done in two steps
    logic [18:0] f4;                // frames * 4 * frame_size
    always_comb begin
        f4 = 19'(frames) * 19'(frame_size) * 19'd4;
        samples_total = 24'(f4) + 24'(frame_size) + 24'd1;
    end

    always_ff @(posedge clk) begin
        rst_d <= rst;
        st_d  <= st;
        if (reset) begin
            busy <= 1'b0; remain <= '0; param <= '0; frames <= '0;
        end else begin
            // RST high -> low: latch the parameter byte
            if (rst_d && !rst) param <= data;
            // RST low -> high while busy: chip reset
            if (!rst_d && rst && busy) begin
                busy <= 1'b0; remain <= '0;
            end
            // ST low -> high: BUSY on
            if (!st_d && st) begin
                busy   <= 1'b1;
                frames <= (vcu || data[0]) ? 12'd0 : VLM_FRAMES[data[7:1]];
                remain <= '0;
            end
            // ST high -> low: speech starts; the frame count was latched on
            // the rising edge, giving the product a full ST pulse to settle
            if (st_d && !st && busy) remain <= samples_total;
            // count the samples down, then BUSY off
            if (sample_ce && remain != '0) begin
                remain <= remain - 24'd1;
                if (remain == 24'd1) busy <= 1'b0;
            end
        end
    end
endmodule
