# ==============================================================================
# Quartus Prime Synopsys Design Constraint File
# ==============================================================================
# Punch-Out!! core constraints.
#
# The Pocket BSP (platform/pocket/bsp/pocket/sys_constr.sdc) creates the APF
# clocks; this file describes what is specific to this core.
# ==============================================================================

# ==============================================================================
# Clock groups
#
# core_pll general[0] = clk_sys       96.0 MHz  machine, renderer, SDRAM
#          general[1] = clk_vid       24.0 MHz  dot clock, exactly clk_sys / 4
#          general[2] = clk_vid 90deg 24.0 MHz
#          general[3], general[4]     unused
#
# clk_sys and the two pixel clocks stay in ONE group on purpose. The renderer
# emits a pixel every fourth clk_sys cycle and the APF scaler samples it on
# clk_vid; they are integer-related outputs of the same PLL, so that crossing is
# synchronous by construction and should be verified rather than cut. Cutting it
# would let each build route it blind and make the picture depend on the fitter
# seed.
#
# clk_74a, clk_74b, the bridge SPI clock and the audio PLL are genuinely
# asynchronous to the machine. The one multi-bit bus that crosses into clk_74b
# -- the audio sample -- is handed over with a toggle flag in core_top, so the
# capture is always of a value that has been still for several cycles
# (METHODOLOGY 5.4).
# ==============================================================================
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

# ==============================================================================
# SDRAM
#
# The chip is clocked from core_pll general[3]: the same 96 MHz as the
# controller, phase-shifted. The phase and the exception below are DERIVED from
# the analyser's own numbers on a real fit, not assumed:
#
#   clock network, PLL output -> dram_clk pin          12.56 ns
#   clock network, PLL output -> dq_in register clock   7.9 ns
#   dram_dq pin -> dq_in register                        2.84 ns
#   chip access time tAC (max) + board                   7.0 ns
#   chip output hold tOH (min)                           2.5 ns
#
# The pin edge therefore trails the same nominal PLL edge by 4.66 ns more than
# the register's clock does. With phase 3650 ps the chip's edge at its pin
# lands about 2.1 ns BEFORE the controller's internal edge, which puts every
# transfer near the middle of its window:
#
#   command launched on our edge E: at the pin E+3, sampled by the chip at its
#     edge E+8.3 -- 5.3 ns setup; the previous chip edge was E-2.1 and the old
#     command holds until E+3 -- 5.1 ns hold.
#   read data: the chip drives it 7.0 ns after its edge, it reaches dq_in 9.84
#     after, i.e. 7.7 ns after our edge -- captured on our NEXT edge with 2.7 ns
#     to spare; the following word cannot arrive before 13.3 -- 2.9 ns hold.
#
# That capture is one full internal period after the chip's edge, but the
# nominal relationship between the two clocks is only 6.76 ns, because the
# extra 4.66 ns of network delay to the pin is not part of the waveform. So the
# analyser's default pairing checks a capture edge the data cannot possibly
# meet, and a multicycle of 2 (hold 1) moves it to the edge the RTL actually
# uses -- READ+4 at the pins, rd_late=1 in sdram16. This is the exception the
# first build lacked a basis for: it had the same numbers on a clock inverted
# by hand, and there the second edge was still 5.2 ns short.
#
# The original controller clocked the chip on an inverted copy of our clock and
# captured on the first edge, leaving 5.2 ns for a 7 ns access. With the
# exception that hid it removed, every dram_dq input missed by 7.5 ns, and on
# the Pocket every sprite was garbage while the block-RAM backgrounds were
# perfect.
#
# The clock is named dram_clk because the BSP (sys_constr.sdc) applies the
# chip's tDS/tDH to a clock of that name -- though it runs before this file and
# never finds it, so those two lines are repeated below.
# ==============================================================================
create_generated_clock -name dram_clk -source \
    [get_pins {ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    [get_ports {dram_clk}]

set_input_delay -max -clock dram_clk 7.0 [get_ports {dram_dq[*]}]
set_input_delay -min -clock dram_clk 2.5 [get_ports {dram_dq[*]}]

# The BSP's sys_constr.sdc carries these same two lines, but it is read before
# this file -- it has to be, it creates the PLL clocks -- so dram_clk does not
# exist yet when it runs and they are silently ignored. Repeated here, after
# the clock is created. tDS 1.5 ns, tDH 0.8 ns from the datasheet.
set SDRAM_OUT [get_ports {dram_a[*] dram_ba[*] dram_cke dram_dqm[*] dram_dq[*] dram_ras_n dram_cas_n dram_we_n}]
set_output_delay -max -clock dram_clk  1.5 $SDRAM_OUT
set_output_delay -min -clock dram_clk -0.8 $SDRAM_OUT

# Read capture is on the second internal edge after the chip's -- see above.
#
# Setup only. The usual "-hold N-1" that accompanies a -setup N is for a path
# whose source launches once per N cycles; the chip launches a new word on
# EVERY edge, and the hazard is the next word arriving before this capture.
# That is the analyser's default hold edge for a -setup 2 path, one period
# before the setup edge. A -hold 1 moved the check back to the edge coincident
# with the launch, which cannot fail, and reported +11 ns where the real margin
# is about +3.
set_multicycle_path -setup 2 -from [get_clocks {dram_clk}] -to [get_registers {*|sdram16:*|dq_in[*]}]

# ==============================================================================
# CPU multicycle.
#
# Both CPUs advance only on a clock enable: the Z80 every 24 clk_sys cycles
# (4.000 MHz) and the 6502 every ~54 (1.789772 MHz). So every
# register-to-register path *inside* either core has at least 24 clock periods
# to settle, and tv80's microcode decode and T65's are the widest combinational
# blocks in the design.
#
# Deliberately scoped to paths that both start and end inside a CPU: the address
# and data buses run to block RAM ports that are clocked every cycle, and those
# must still meet single-cycle timing.
#
# 8 rather than 24: a third of the provable margin, which is plenty of relief
# and leaves the constraint correct even if the enable generation is changed.
# ==============================================================================
set_multicycle_path -setup 8 -from [get_registers {*|tv80_core:*|*}] -to [get_registers {*|tv80_core:*|*}]
set_multicycle_path -hold  7 -from [get_registers {*|tv80_core:*|*}] -to [get_registers {*|tv80_core:*|*}]
set_multicycle_path -setup 8 -from [get_registers {*|T65:*|*}] -to [get_registers {*|T65:*|*}]
set_multicycle_path -hold  7 -from [get_registers {*|T65:*|*}] -to [get_registers {*|T65:*|*}]

# ==============================================================================
# The APU's mixer.
#
# NES_MiSTer clocks the APU at 21.477 MHz, where its mixer -- channel registers
# through two lookup tables and three adds to the Sample output -- has 46 ns and
# is comfortable. Here it runs on the 96 MHz system clock with an enable, and
# measured on this fit that chain is 18 ns: it cannot close in 10.4 ns, and
# every one of the 400 worst paths in the design was this same one.
#
# The only thing that samples it is the DC blocker in punchout_sound, which
# updates once per 2A03 cycle -- about 54 system clocks. And every register
# inside the APU is enable-gated at an APU rate (aclk1, aclk1_d, phi1, env_clk,
# noise_clock, aclk2, write); the sole exception is phi2_old, whose source is
# PHI2 in punchout_sound rather than an APU register, so it is not covered here.
#
# 4 rather than 54: a fraction of the provable margin, ample relief, and it
# stays correct even if the enable generation is ever changed.
# ==============================================================================
set_multicycle_path -setup 4 -from [get_registers {*|APU:*|*}] -to [get_registers {*|punchout_sound:*|dcb_*}]
set_multicycle_path -hold  3 -from [get_registers {*|APU:*|*}] -to [get_registers {*|punchout_sound:*|dcb_*}]
set_multicycle_path -setup 4 -from [get_registers {*|punchout_sound:*|dcb_*}] -to [get_registers {*|punchout_sound:*|dcb_*}]
set_multicycle_path -hold  3 -from [get_registers {*|punchout_sound:*|dcb_*}] -to [get_registers {*|punchout_sound:*|dcb_*}]
set_multicycle_path -setup 4 -from [get_registers {*|punchout_sound:*|dcb_*}] -to [get_registers {*|punchout_sound:*|sample[*]}]
set_multicycle_path -hold  3 -from [get_registers {*|punchout_sound:*|dcb_*}] -to [get_registers {*|punchout_sound:*|sample[*]}]

# ==============================================================================
# Big-sprite geometry.
#
# The frame-setup machine multiplies the 12-bit zoom by three constants and adds
# 32-bit terms, once per frame during vertical blanking. It has 42 blank lines
# -- about 94,000 clocks -- to produce an answer that is not read until the
# first line of the next field, so the arithmetic does not need to close at
# 96 MHz and should not drag the whole fit down trying to.
# ==============================================================================
set_multicycle_path -setup 4 -to [get_registers {*|punchout_video:*|startx1[*] *|punchout_video:*|starty1_init[*] *|punchout_video:*|startx2[*] *|punchout_video:*|starty2_init[*] *|punchout_video:*|incxx1[*] *|punchout_video:*|incyy1[*] *|punchout_video:*|incxx2[*]}]
set_multicycle_path -hold  3 -to [get_registers {*|punchout_video:*|startx1[*] *|punchout_video:*|starty1_init[*] *|punchout_video:*|startx2[*] *|punchout_video:*|starty2_init[*] *|punchout_video:*|incxx1[*] *|punchout_video:*|incyy1[*] *|punchout_video:*|incxx2[*]}]
