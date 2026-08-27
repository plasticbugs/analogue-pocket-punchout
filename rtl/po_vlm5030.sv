//! Sanyo VLM5030 speech synthesiser, after MAME's vlm5030.cpp.
//!
//! The announcer. A 48-bit LPC frame every 4 interpolation periods of
//! frame_size samples (the speed parameter the game latches on RST), a pitch
//! pulse or +/-energy noise as excitation, a ten-stage lattice filter with
//! the reflection coefficients from the chip's own tables, a 10-bit output at
//! 3579545 / 440 = 8135 Hz. tools/vlm5030.py is the executable spec: this
//! module is held to it sample for sample (sim/run_vlm.sh), with integer
//! division truncating toward zero exactly as the C does. The one place the
//! two cannot follow MAME bit for bit is the unvoiced excitation, where MAME
//! uses its random generator; here and in the model it is a 16-bit LFSR.
//!
//! The 16 KB speech ROM lives in block RAM, filled by the loader from the
//! same image offset po_romload carries to SDRAM, so speech never touches
//! the SDRAM the renderer is using.
//!
//! Pins and timing (vlm5030.cpp): ST rising -> BSY high; ST falling -> the
//! phrase table entry at (data & 0xfe) | (data & 1) << 8 names the start
//! address and speech begins; RST falling latches the parameter byte from
//! the data bus; RST rising while busy resets the chip. After the end
//! marker one more period of samples, then one sample, then BSY drops. The
//! direct-address mode (VCU high) is not used by this game and is treated as
//! indirect.
module po_vlm5030 (
    input  wire         clk,             // 96 MHz
    input  wire         reset,
    // ---- loader
    input  wire  [24:0] dl_addr,
    input  wire   [7:0] dl_data,
    input  wire         dl_we,
    // ---- the chip's pins
    input  wire         rst,
    input  wire         st,
    input  wire         vcu,
    input  wire   [7:0] data,
    output logic        busy /* verilator public_flat_rd */,
    // ---- output: one sample per sample_ce, 10-bit signed
    output logic signed [9:0] sample,
    output logic        sample_ce
);
    localparam [24:0] IMG_VLM = 25'h5_6C00, IMG_VLM_END = 25'h5_AC00;
    localparam FR_SIZE = 4;

    // ---- speech ROM, 16 KB
    logic [13:0] rom_ra;
    logic  [7:0] rom_q;
    wire         in_vlm = dl_we && (dl_addr >= IMG_VLM) && (dl_addr < IMG_VLM_END);
    po_spram_dp #(.AW(14), .DW(8)) u_rom (.clk(clk),
        .wa(dl_addr[13:0] - IMG_VLM[13:0]), .we(in_vlm), .d(dl_data), .ra(rom_ra), .q(rom_q));

    // ---- sample clock: 3579545 / 440 Hz from 96 MHz
    localparam logic [31:0] CE_INC = 32'd363968;
    logic [31:0] acc;
    logic        tick;
    always_ff @(posedge clk) {tick, acc} <= {1'b0, acc} + {1'b0, CE_INC};

    // ---- tables
    function automatic logic signed [9:0] k1_tab(input [5:0] i);
        case (i)
            6'd0: k1_tab=390; 6'd1: k1_tab=403; 6'd2: k1_tab=414; 6'd3: k1_tab=425; 6'd4: k1_tab=434; 6'd5: k1_tab=443; 6'd6: k1_tab=450; 6'd7: k1_tab=457;
            6'd8: k1_tab=463; 6'd9: k1_tab=469; 6'd10: k1_tab=474; 6'd11: k1_tab=478; 6'd12: k1_tab=482; 6'd13: k1_tab=485; 6'd14: k1_tab=488; 6'd15: k1_tab=491;
            6'd16: k1_tab=494; 6'd17: k1_tab=496; 6'd18: k1_tab=498; 6'd19: k1_tab=499; 6'd20: k1_tab=501; 6'd21: k1_tab=502; 6'd22: k1_tab=503; 6'd23: k1_tab=504;
            6'd24: k1_tab=505; 6'd25: k1_tab=506; 6'd26: k1_tab=507; 6'd27: k1_tab=507; 6'd28: k1_tab=508; 6'd29: k1_tab=508; 6'd30: k1_tab=509; 6'd31: k1_tab=509;
            6'd32: k1_tab=-390; 6'd33: k1_tab=-376; 6'd34: k1_tab=-360; 6'd35: k1_tab=-344; 6'd36: k1_tab=-325; 6'd37: k1_tab=-305; 6'd38: k1_tab=-284; 6'd39: k1_tab=-261;
            6'd40: k1_tab=-237; 6'd41: k1_tab=-211; 6'd42: k1_tab=-183; 6'd43: k1_tab=-155; 6'd44: k1_tab=-125; 6'd45: k1_tab=-95; 6'd46: k1_tab=-64; 6'd47: k1_tab=-32;
            6'd48: k1_tab=0; 6'd49: k1_tab=32; 6'd50: k1_tab=64; 6'd51: k1_tab=95; 6'd52: k1_tab=125; 6'd53: k1_tab=155; 6'd54: k1_tab=183; 6'd55: k1_tab=211;
            6'd56: k1_tab=237; 6'd57: k1_tab=261; 6'd58: k1_tab=284; 6'd59: k1_tab=305; 6'd60: k1_tab=325; 6'd61: k1_tab=344; 6'd62: k1_tab=360; default: k1_tab=376;
        endcase
    endfunction
    function automatic logic signed [9:0] k2_tab(input [4:0] i);
        case (i)
            5'd0: k2_tab=0; 5'd1: k2_tab=50; 5'd2: k2_tab=100; 5'd3: k2_tab=149; 5'd4: k2_tab=196; 5'd5: k2_tab=241; 5'd6: k2_tab=284; 5'd7: k2_tab=325;
            5'd8: k2_tab=362; 5'd9: k2_tab=396; 5'd10: k2_tab=426; 5'd11: k2_tab=452; 5'd12: k2_tab=473; 5'd13: k2_tab=490; 5'd14: k2_tab=502; 5'd15: k2_tab=510;
            5'd16: k2_tab=0; 5'd17: k2_tab=-510; 5'd18: k2_tab=-502; 5'd19: k2_tab=-490; 5'd20: k2_tab=-473; 5'd21: k2_tab=-452; 5'd22: k2_tab=-426; 5'd23: k2_tab=-396;
            5'd24: k2_tab=-362; 5'd25: k2_tab=-325; 5'd26: k2_tab=-284; 5'd27: k2_tab=-241; 5'd28: k2_tab=-196; 5'd29: k2_tab=-149; 5'd30: k2_tab=-100; default: k2_tab=-50;
        endcase
    endfunction
    // K3, K4: index * 64 as a signed 4-bit value; K5..K10: index * 128 as signed 3-bit
    // K3, K4: the 4-bit index as a signed value times 64; K5..K10: 3-bit times 128
    function automatic logic signed [9:0] k4b_tab(input [3:0] i);
        k4b_tab = {i, 6'b0};                            // the 4 bits ARE the top of the 10: times 64
    endfunction
    function automatic logic signed [9:0] k3b_tab(input [2:0] i);
        k3b_tab = {i, 7'b0};                            // times 128
    endfunction
    function automatic logic [6:0] energy_tab(input [4:0] i);
        case (i)
            5'd0: energy_tab=0; 5'd1: energy_tab=1; 5'd2: energy_tab=2; 5'd3: energy_tab=3; 5'd4: energy_tab=5; 5'd5: energy_tab=6; 5'd6: energy_tab=7; 5'd7: energy_tab=9;
            5'd8: energy_tab=11; 5'd9: energy_tab=13; 5'd10: energy_tab=15; 5'd11: energy_tab=17; 5'd12: energy_tab=19; 5'd13: energy_tab=22; 5'd14: energy_tab=24; 5'd15: energy_tab=27;
            5'd16: energy_tab=31; 5'd17: energy_tab=34; 5'd18: energy_tab=38; 5'd19: energy_tab=42; 5'd20: energy_tab=47; 5'd21: energy_tab=51; 5'd22: energy_tab=57; 5'd23: energy_tab=62;
            5'd24: energy_tab=68; 5'd25: energy_tab=75; 5'd26: energy_tab=82; 5'd27: energy_tab=89; 5'd28: energy_tab=98; 5'd29: energy_tab=107; 5'd30: energy_tab=116; default: energy_tab=127;
        endcase
    endfunction
    function automatic logic [6:0] pitch_tab(input [4:0] i);
        case (i)
            5'd0: pitch_tab=0; 5'd1: pitch_tab=21; 5'd2: pitch_tab=22; 5'd3: pitch_tab=23; 5'd4: pitch_tab=24; 5'd5: pitch_tab=25; 5'd6: pitch_tab=26; 5'd7: pitch_tab=27;
            5'd8: pitch_tab=28; 5'd9: pitch_tab=29; 5'd10: pitch_tab=31; 5'd11: pitch_tab=33; 5'd12: pitch_tab=35; 5'd13: pitch_tab=37; 5'd14: pitch_tab=39; 5'd15: pitch_tab=41;
            5'd16: pitch_tab=43; 5'd17: pitch_tab=45; 5'd18: pitch_tab=49; 5'd19: pitch_tab=53; 5'd20: pitch_tab=57; 5'd21: pitch_tab=61; 5'd22: pitch_tab=65; 5'd23: pitch_tab=69;
            5'd24: pitch_tab=73; 5'd25: pitch_tab=77; 5'd26: pitch_tab=85; 5'd27: pitch_tab=93; 5'd28: pitch_tab=101; 5'd29: pitch_tab=109; 5'd30: pitch_tab=117; default: pitch_tab=125;
        endcase
    endfunction

    // C integer division, truncating toward zero
    function automatic logic signed [13:0] div4(input logic signed [13:0] a);
        div4 = (a + (a[13] ? 14'sd3 : 14'sd0)) >>> 2;
    endfunction
    function automatic logic signed [21:0] div512(input logic signed [32:0] a);
        logic signed [32:0] t;
        t = (a + (a[32] ? 33'sd511 : 33'sd0)) >>> 9;
        div512 = t[21:0];
    endfunction
    // the lattice's multiply: the (already negated, 11-bit) coefficient times
    // a 22-bit lattice value, as a 33-bit product
    function automatic logic signed [32:0] kmul(input logic signed [10:0] nk, input logic signed [21:0] v);
        kmul = nk * v;
    endfunction

    // ---- parameter
    logic [7:0] param;
    logic [6:0] frame_size;
    logic [2:0] interp_step;
    logic signed [4:0] pitch_offset;
    always_comb begin
        case (param[5:3])
            3'd0: frame_size = 7'd40; 3'd1: frame_size = 7'd30; 3'd2: frame_size = 7'd20; 3'd3: frame_size = 7'd20;
            3'd4: frame_size = 7'd40; 3'd5: frame_size = 7'd60; 3'd6: frame_size = 7'd50; default: frame_size = 7'd50;
        endcase
        interp_step  = param[1] ? 3'd4 : param[0] ? 3'd2 : 3'd1;
        pitch_offset = param[7] ? -5'sd8 : param[6] ? 5'sd8 : 5'sd0;
    end

    // ---- speech state
    typedef enum logic [2:0] { PH_IDLE, PH_SETUP, PH_WAIT, PH_RUN, PH_STOP, PH_END } phase_t;
    phase_t      phase;
    logic [15:0] address;
    logic  [7:0] sample_count;
    logic  [9:0] interp_count;      // counts interpolation periods; silent frames load nums*4, up to 520
    logic  [6:0] pitch_count;
    logic  [6:0] old_energy, new_energy, current_energy, target_energy;
    logic signed [7:0] old_pitch, new_pitch, current_pitch, target_pitch;   // pitch may be offset by -8
    logic signed [9:0] old_k [0:9];
    logic signed [9:0] new_k [0:9];
    logic signed [9:0] current_k [0:9];
    logic signed [9:0] target_k [0:9];
    logic signed [21:0] xr [0:9];    // the lattice's delay line, C int width in spirit
    logic [15:0] lfsr;
    logic        rst_d, st_d;

    // ---- the per-sample sequencer
    typedef enum logic [4:0] {
        S_IDLE, S_TICK, S_CMD_W, S_CMD_A, S_CMD_B, S_FRAME_A, S_FRAME_B, S_FRAME_DONE, S_INTERP, S_LERP0, S_LERP1, S_LERP2, S_LERP3, S_EXCITE,
        S_LAT_U0, S_LAT_U1, S_LAT_U2, S_LAT_X0, S_LAT_X1, S_LAT_X2, S_OUT
    } seq_t;
    seq_t        seq;
    logic [47:0] frame;
    logic  [2:0] fidx;
    logic  [3:0] li;                 // lattice index
    logic signed [21:0] u [0:10];
    logic signed [21:0] ex;          // excitation
    // the lattice's operands and product, one stage at a time: fetched,
    // multiplied, accumulated in three clocks so no path carries a dynamic
    // index, a 31-bit multiply and an add together
    logic signed [10:0] kr;          // -k, negated at fetch time
    logic signed [21:0] vr, ar;
    logic signed [32:0] prod;
    logic [2:0]  eff_r;              // the interpolation weight for this period
    logic [3:0]  ki;                 // which coefficient is being interpolated
    logic signed [13:0] lo_r, lt_r;  // its old and target values, fetched a clock ahead
    logic signed [13:0] ld_r;        // target - old
    logic signed [13:0] lm_r;        // (target - old) * weight, the weight 1..4 as shift-adds
    integer i;

    // interpolation, all twelve at once (cheap: 4 x 14-bit adds each)
    wire [2:0] ic_next = interp_count[2:0] - interp_step;     // interp_count after the step, low bits
    wire [2:0] eff     = 3'd4 - {1'b0, ic_next[1:0]};          // 4 - (count % 4): 1..4
    function automatic logic signed [13:0] lerp(input logic signed [13:0] o, input logic signed [13:0] t, input [2:0] e);
        logic signed [13:0] es;
        es = {11'b0, e};
        lerp = o + div4((t - o) * es);
    endfunction
    function automatic logic [6:0] lerp_e(input logic signed [13:0] o, input logic signed [13:0] t, input [2:0] e);
        logic signed [13:0] r; r = lerp(o, t, e); lerp_e = r[6:0];
    endfunction
    function automatic logic signed [7:0] lerp_p(input logic signed [13:0] o, input logic signed [13:0] t, input [2:0] e);
        logic signed [13:0] r; r = lerp(o, t, e); lerp_p = r[7:0];
    endfunction
    // the last step: old + (product / 4), truncating toward zero
    function automatic logic signed [9:0] lerp_fin_k(input logic signed [13:0] o, input logic signed [13:0] m);
        logic signed [13:0] r; r = o + div4(m); lerp_fin_k = r[9:0];
    endfunction
    function automatic logic [6:0] lerp_fin_e(input logic signed [13:0] o, input logic signed [13:0] m);
        logic signed [13:0] r; r = o + div4(m); lerp_fin_e = r[6:0];
    endfunction
    function automatic logic signed [7:0] lerp_fin_p(input logic signed [13:0] o, input logic signed [13:0] m);
        logic signed [13:0] r; r = o + div4(m); lerp_fin_p = r[7:0];
    endfunction
    // signed views of the unsigned state, for the interpolation
    wire signed [13:0] old_energy_s = {7'b0, old_energy}, target_energy_s = {7'b0, target_energy};
    wire signed [13:0] old_pitch_s = {{6{old_pitch[7]}}, old_pitch}, target_pitch_s = {{6{target_pitch[7]}}, target_pitch};
    wire signed [21:0] energy_22 = {15'b0, current_energy};

    always_ff @(posedge clk) begin
        rst_d <= rst; st_d <= st;
        sample_ce <= 1'b0;
        if (reset) begin
            phase <= PH_IDLE; busy <= 1'b0; param <= '0; seq <= S_IDLE;
            address <= '0; sample_count <= '0; interp_count <= '0; pitch_count <= '0;
            old_energy <= '0; new_energy <= '0; current_energy <= '0; target_energy <= '0;
            old_pitch <= '0; new_pitch <= '0; current_pitch <= '0; target_pitch <= '0;
            for (i = 0; i < 10; i++) begin old_k[i] <= '0; new_k[i] <= '0; current_k[i] <= '0; target_k[i] <= '0; xr[i] <= '0; end
            lfsr <= 16'hACE1; sample <= '0;
        end else begin
            // ---- pins
            if (rst_d && !rst) param <= data;                       // RST high->low: parameter
            if (!rst_d && rst && busy) begin                        // RST low->high while busy: reset
                phase <= PH_IDLE; busy <= 1'b0; seq <= S_IDLE; param <= '0;
                old_energy <= '0; new_energy <= '0; current_energy <= '0; target_energy <= '0;
                old_pitch <= '0; new_pitch <= '0; current_pitch <= '0; target_pitch <= '0;
                for (i = 0; i < 10; i++) begin old_k[i] <= '0; new_k[i] <= '0; current_k[i] <= '0; target_k[i] <= '0; xr[i] <= '0; end
                interp_count <= '0; sample_count <= '0; pitch_count <= '0;
            end
            if (!st_d && st) begin                                  // ST low->high: BUSY on
                phase <= PH_SETUP; busy <= 1'b1; sample_count <= 8'd1;
            end
            if (st_d && !st && phase != PH_IDLE) begin             // ST high->low: start
                rom_ra <= {6'b0, data[7:1], 1'b0};                  // table entry (even byte; bit 0 selects +0x100)
                if (data[0]) rom_ra <= {5'b0, 1'b1, data[7:1], 1'b0};
                seq <= S_CMD_W;                                     // fetch the start address
                phase <= PH_WAIT;
            end

            // ---- the sample clock
            case (seq)
                S_IDLE: begin
                    if (tick && phase == PH_SETUP) begin
                        // one sample of setup time, then wait for the start
                        phase <= PH_WAIT;
                    end else if (tick && (phase == PH_RUN || phase == PH_STOP)) begin
                        seq <= S_TICK;
                    end else if (tick && phase == PH_END) begin
                        busy <= 1'b0; phase <= PH_IDLE;             // one sample after the stop period
                    end
                end

                // fetch the phrase start address: two ROM bytes, big-endian.
                // The ROM's q is valid two clocks after rom_ra is assigned:
                // one for the address to reach the array, one for the read.
                S_CMD_W: begin rom_ra <= rom_ra + 14'd1; seq <= S_CMD_A; end
                S_CMD_A: begin address[15:8] <= rom_q; seq <= S_CMD_B; end
                S_CMD_B: begin
                    address[7:0] <= rom_q;
                    sample_count <= {1'b0, frame_size}; interp_count <= 10'd4;
                    phase <= PH_RUN; seq <= S_IDLE;
                end
                S_FRAME_DONE: seq <= S_INTERP;                       // frame parsed, from S_FRAME_B

                // start of a sample: new period? new frame?
                S_TICK: begin
                    if (sample_count == 8'd0) begin
                        if (phase == PH_STOP) begin
                            phase <= PH_END; sample_count <= 8'd1; seq <= S_IDLE;   // no sample in PH_END
                        end else begin
                            sample_count <= {1'b0, frame_size};
                            if (interp_count == 10'd0) begin
                                // parse the next frame: command byte first
                                old_energy <= new_energy; old_pitch <= new_pitch;
                                for (i = 0; i < 10; i++) old_k[i] <= new_k[i];
                                rom_ra <= address[13:0];
                                seq <= S_FRAME_A;
                            end else seq <= S_INTERP;
                        end
                    end else seq <= S_EXCITE;
                end
                S_FRAME_A: begin
                    // rom_q is not valid yet (address just set); wait a clock
                    rom_ra <= address[13:0] + 14'd1; fidx <= 3'd0; seq <= S_FRAME_B;
                end
                S_FRAME_B: begin
                    // rom_q = byte fidx of the frame (address + fidx)
                    if (fidx == 3'd0) begin
                        frame[7:0] <= rom_q;
                        if (rom_q[0]) begin
                            // command frame
                            new_energy <= '0; new_pitch <= '0;
                            for (i = 0; i < 10; i++) new_k[i] <= '0;
                            address <= address + 16'd1;
                            if (rom_q[1]) begin
                                // end of speech: one more period, then stop
                                interp_count <= 10'd4; phase <= PH_STOP;
                            end else begin
                                interp_count <= ({4'b0, rom_q[7:2]} + 10'd1) * 10'd8;
                            end
                            fidx <= 3'd6; seq <= S_FRAME_DONE;   // to the target setup
                        end else begin
                            rom_ra <= rom_ra + 14'd1; fidx <= 3'd1;
                        end
                    end else begin
                        frame[8*fidx +: 8] <= rom_q;
                        rom_ra <= rom_ra + 14'd1;
                        if (fidx == 3'd5) begin
                            address <= address + 16'd6; interp_count <= 10'd4;
                            fidx <= 3'd6; seq <= S_FRAME_DONE;
                        end else fidx <= fidx + 3'd1;
                    end
                end
                // (S_FRAME_DONE with fidx 6: the frame register is complete
                //  for a speech frame, or zeroed by the command path)
                S_INTERP: begin
                    if (fidx == 3'd6) begin
                        // decode the speech frame's fields into new_*, then the
                        // "old target as new start" and target selection
                        fidx <= 3'd0;
                        if (!frame[0]) begin
                            new_pitch  <= (pitch_tab(frame[5:1]) != 7'd0) ? {1'b0, pitch_tab(frame[5:1])} + {{3{pitch_offset[4]}}, pitch_offset} : 8'd0;
                            new_energy <= energy_tab(frame[10:6]);
                            new_k[9] <= k3b_tab(frame[13:11]); new_k[8] <= k3b_tab(frame[16:14]);
                            new_k[7] <= k3b_tab(frame[19:17]); new_k[6] <= k3b_tab(frame[22:20]);
                            new_k[5] <= k3b_tab(frame[25:23]); new_k[4] <= k3b_tab(frame[28:26]);
                            new_k[3] <= k4b_tab(frame[32:29]); new_k[2] <= k4b_tab(frame[36:33]);
                            new_k[1] <= k2_tab(frame[41:37]);  new_k[0] <= k1_tab(frame[47:42]);
                        end
                        // one more clock for new_* to settle before the target copy
                        fidx <= 3'd5; seq <= S_INTERP;
                    end else if (fidx == 3'd5) begin
                        fidx <= 3'd0;
                        current_energy <= old_energy; current_pitch <= old_pitch;
                        for (i = 0; i < 10; i++) current_k[i] <= old_k[i];
                        if (old_energy == 7'd0) begin
                            target_energy <= '0; target_pitch <= old_pitch;
                            for (i = 0; i < 10; i++) target_k[i] <= old_k[i];
                        end else begin
                            target_energy <= new_energy; target_pitch <= new_pitch;
                            for (i = 0; i < 10; i++) target_k[i] <= new_k[i];
                        end
                        fidx <= 3'd4; seq <= S_INTERP;
                    end else if (fidx == 3'd4) begin
                        fidx <= 3'd0;
                        // "next interpolator"
                        interp_count <= interp_count - {7'b0, interp_step};
                        eff_r <= eff; ki <= 4'd0; seq <= S_LERP0;
                    end else begin
                        // plain interpolation period (no new frame)
                        interp_count <= interp_count - {7'b0, interp_step};
                        eff_r <= eff; ki <= 4'd0; seq <= S_LERP0;
                    end
                end
                // one interpolation per two clocks: fetch the pair, then
                // compute -- the ten K's, then energy, then pitch
                S_LERP0: begin
                    if (ki < 4'd10)       begin lo_r <= {{4{old_k[ki][9]}}, old_k[ki]}; lt_r <= {{4{target_k[ki][9]}}, target_k[ki]}; end
                    else if (ki == 4'd10) begin lo_r <= old_energy_s; lt_r <= target_energy_s; end
                    else                  begin lo_r <= old_pitch_s;  lt_r <= target_pitch_s; end
                    seq <= S_LERP1;
                end
                S_LERP1: begin ld_r <= lt_r - lo_r; seq <= S_LERP2; end
                S_LERP2: begin
                    case (eff_r)
                        3'd1:    lm_r <= ld_r;
                        3'd2:    lm_r <= ld_r <<< 1;
                        3'd3:    lm_r <= ld_r + (ld_r <<< 1);
                        default: lm_r <= ld_r <<< 2;
                    endcase
                    seq <= S_LERP3;
                end
                S_LERP3: begin
                    if (ki < 4'd10)       current_k[ki] <= lerp_fin_k(lo_r, lm_r);
                    else if (ki == 4'd10) current_energy <= lerp_fin_e(lo_r, lm_r);
                    else if (old_pitch > 8'sd1) current_pitch <= lerp_fin_p(lo_r, lm_r);
                    if (ki == 4'd11) seq <= S_EXCITE; else begin ki <= ki + 4'd1; seq <= S_LERP0; end
                end
                S_EXCITE: begin
                    if (old_energy == 7'd0) ex <= '0;
                    else if (old_pitch <= 8'sd1) begin
                        ex <= lfsr[0] ? energy_22 : -energy_22;
                        lfsr <= {lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5], lfsr[15:1]};
                    end else ex <= (pitch_count == 7'd0) ? energy_22 : 22'sd0;
                    li <= 4'd9; seq <= S_LAT_U0;
                end
                // u[i] = u[i+1] - ((-k[i] * x[i]) / 512), i = 9..0
                S_LAT_U0: begin
                    kr <= -{current_k[li][9], current_k[li]}; vr <= xr[li];
                    ar <= (li == 4'd9) ? ex : u[li + 1];
                    if (li == 4'd9) u[10] <= ex;
                    seq <= S_LAT_U1;
                end
                S_LAT_U1: begin prod <= kmul(kr, vr); seq <= S_LAT_U2; end
                S_LAT_U2: begin
                    u[li] <= ar - div512(prod);
                    if (li == 4'd0) begin li <= 4'd9; seq <= S_LAT_X0; end
                    else begin li <= li - 4'd1; seq <= S_LAT_U0; end
                end
                // x[i] = x[i-1] + ((-k[i-1] * u[i-1]) / 512), i = 9..1; x[0] = u[0]
                S_LAT_X0: begin
                    kr <= -{current_k[li - 1][9], current_k[li - 1]}; vr <= u[li - 1]; ar <= xr[li - 1];
                    seq <= S_LAT_X1;
                end
                S_LAT_X1: begin prod <= kmul(kr, vr); seq <= S_LAT_X2; end
                S_LAT_X2: begin
                    xr[li] <= ar + div512(prod);
                    if (li == 4'd1) begin xr[0] <= u[0]; seq <= S_OUT; end
                    else begin li <= li - 4'd1; seq <= S_LAT_X0; end
                end
                S_OUT: begin
                    sample <= (u[0] > 22'sd511) ? 10'sd511 : (u[0] < -22'sd512) ? -10'sd512 : u[0][9:0];
                    sample_ce <= 1'b1;
                    sample_count <= sample_count - 8'd1;
                    if ({1'b0, pitch_count} + 8'd1 >= current_pitch) pitch_count <= '0;
                    else pitch_count <= pitch_count + 7'd1;
                    seq <= S_IDLE;
                end
                default: seq <= S_IDLE;
            endcase
        end
    end
endmodule
