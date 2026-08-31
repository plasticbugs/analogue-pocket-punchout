//! Super Punch-Out!! protection: RP5C01 RTC + RP5H01 one-time PROM.
//!
//! The CHP1 board carries two extra chips that Punch-Out!! does not use. They
//! hang off the Z80's I/O ports:
//!
//!   05  W   RP5H01 RESET      (d0; writing a 1 also clocks a 0 into the
//!                              chip's DATA CLOCK and TEST pins, because one
//!                              74LS74 drives both)
//!   06  W   RP5H01 DATA CLOCK + TEST (d0)
//!   07  RW  RP5C01 register, selected by address bits 7-4; on read the
//!           RP5H01's COUNTER OUT and DATA OUT arrive in d6 and d7
//!
//! Punch-Out!! writes zeroes to all three in an init loop and never reads them
//! (measured over 3000 frames in MAME), so this block is invisible to it and
//! one bitstream plays both games with no game detection anywhere.
//!
//! What the game actually leans on is not timekeeping. The RP5C01 is wired
//! with OSCIN to Vcc and no battery, so nothing ticks and the ALARM output
//! stays high; the game uses the register file's write masking -- a register
//! that holds three bits reads back three bits -- and the 13 nibbles of
//! scratch RAM reachable in BLOCK10/BLOCK11 mode. The RP5H01's PROM is
//! unprogrammed, which reads back as a known 16-byte pattern.
//!
//! tools/protection.py is the executable spec and was checked against every
//! one of the 5853 reads the real game makes in 30 seconds of MAME
//! (docs/verification.md).
`default_nettype none

module po_protect (
    input  wire       clk,
    input  wire       reset,
    input  wire [7:0] addr,          //! Z80 A[7:0]: low nibble the port, high nibble the RTC register
    input  wire [7:0] din,
    input  wire       io_wr,         //! one-clock write strobe
    output wire [7:0] dout           //! what a read of port 07 returns
);
    // ---------------------------------------------------------------- RP5H01
    // an unprogrammed PROM (MAME rp5h01.cpp, s_initial_data)
    function automatic logic [7:0] prom(input logic [3:0] i);
        case (i)
            4'd10, 4'd11, 4'd14, 4'd15: prom = 8'h00;
            default:                    prom = 8'hff;
        endcase
    endfunction

    logic [7:0] counter;
    logic       mode7;               //! TEST high selects the 7-bit counter mode
    logic       old_reset, old_clock;

    wire [3:0] otp_byte = mode7 ? counter[6:3] : {1'b0, counter[5:3]};
    wire [2:0] otp_bit  = 3'd7 - counter[2:0];
    // through a named wire: Quartus 18.1 will not index a function's result
    wire [7:0] otp_word = prom(otp_byte);
    wire       otp_data = otp_word[otp_bit];
    wire       otp_cnt  = counter[5];              //! COUNTER OUT is A5

    // ---------------------------------------------------------------- RP5C01
    // Two 16-nibble register files (MODE00 and MODE01), and 16 bytes of RAM
    // that BLOCK10/BLOCK11 reach a nibble at a time.
    logic [3:0] rtc00 [0:15];
    logic [3:0] rtc01 [0:15];
    logic [7:0] rtcram [0:15];
    logic [3:0] rtc_mode;
    logic [3:0] rtc_rst;

    //! A register narrower than four bits keeps only what fits, which is the
    //! masking the game checks.
    function automatic logic [3:0] wmask(input logic bank, input logic [3:0] off);
        if (!bank)
            case (off)
                4'd1, 4'd3, 4'd6: wmask = 4'h7;
                4'd5, 4'd8:       wmask = 4'h3;
                4'd10:            wmask = 4'h1;
                default:          wmask = 4'hf;
            endcase
        else
            case (off)
                4'd0, 4'd1, 4'd9, 4'd12: wmask = 4'h0;
                4'd3, 4'd6:              wmask = 4'h7;
                4'd5, 4'd8:              wmask = 4'h3;
                4'd10:                   wmask = 4'h1;
                4'd11:                   wmask = 4'h3;
                default:                 wmask = 4'hf;
            endcase
    endfunction

    wire [3:0] rd_off = addr[7:4];
    logic [3:0] rtc_q;
    always_comb begin
        case (rd_off)
            4'd13:        rtc_q = rtc_mode;
            4'd14, 4'd15: rtc_q = 4'd0;              // write only
            default:
                case (rtc_mode[1:0])
                    2'd0:    rtc_q = rtc00[rd_off];
                    2'd1:    rtc_q = rtc01[rd_off];
                    2'd2:    rtc_q = rtcram[rd_off][3:0];
                    default: rtc_q = rtcram[rd_off][7:4];
                endcase
        endcase
    end

    // d7 DATA OUT, d6 COUNTER OUT, both inverted by the board; d5 _ALARM,
    // which is always high here and so always reads 0; d4 is not connected
    // and pulls high.
    assign dout = {~otp_data, ~otp_cnt, 1'b0, 1'b1, rtc_q};

    // ----------------------------------------------------------------- writes
    integer i;
    always_ff @(posedge clk) begin
        if (reset) begin
            counter <= '0; mode7 <= 1'b0; old_reset <= 1'b0; old_clock <= 1'b0;
            rtc_mode <= '0; rtc_rst <= '0;
            for (i = 0; i < 16; i++) begin
                rtc00[i]  <= '0;
                rtc01[i]  <= (i == 10) ? 4'd1 : 4'd0;   // 12/24 select, set at power-up
                rtcram[i] <= '0;
            end
        end else if (io_wr) begin
            case (addr[3:0])
                // RESET, then the same write drops CLOCK and TEST -- in that
                // order, so a reset and an increment in one write cancel to 1
                4'h5: begin
                    if (!old_reset && din[0]) counter <= '0;
                    old_reset <= din[0];
                    if (din[0]) begin
                        if (old_clock) counter <= (!old_reset ? 8'd0 : counter) + 8'd1;
                        old_clock <= 1'b0;
                        mode7     <= 1'b0;
                    end
                end
                // DATA CLOCK and TEST together: the counter advances on the
                // falling edge
                4'h6: begin
                    if (old_clock && !din[0]) counter <= counter + 8'd1;
                    old_clock <= din[0];
                    mode7     <= din[0];
                end
                // the RTC register named by the address's high nibble
                4'h7: begin
                    case (addr[7:4])
                        4'd13: rtc_mode <= din[3:0];
                        4'd14: ;                                  // TEST: ignored
                        4'd15: begin
                            rtc_rst <= din[3:0];
                            if (din[0])                           // reset the alarm registers
                                for (i = 2; i < 9; i++) rtc01[i] <= '0;
                        end
                        default:
                            case (rtc_mode[1:0])
                                2'd0: rtc00[addr[7:4]]     <= din[3:0] & wmask(1'b0, addr[7:4]);
                                2'd1: rtc01[addr[7:4]]     <= din[3:0] & wmask(1'b1, addr[7:4]);
                                2'd2: rtcram[addr[7:4]][3:0] <= din[3:0];
                                default: rtcram[addr[7:4]][7:4] <= din[3:0];
                            endcase
                    endcase
                end
                default: ;
            endcase
        end
    end
endmodule

`default_nettype wire
