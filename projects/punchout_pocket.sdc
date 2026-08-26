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
# sdram16 drives SDRAM_CLK from a DDIO cell fed by clk_sys, so the chip clocks
# on the inverted edge and the controller has half a period of setup either way.
# The generated clock has to be declared for the I/O paths to be analysed at
# all; without it Quartus reports them as unconstrained and the fit is a guess.
#
# The board delays are the usual Pocket figures: short traces, one load.
# ==============================================================================
set SDRAM_CLK_PIN [get_ports {dram_clk}]
create_generated_clock -name dram_clk_out -source \
    [get_pins {ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -invert $SDRAM_CLK_PIN

set_input_delay  -max -clock dram_clk_out 6.4 [get_ports {dram_dq[*]}]
set_input_delay  -min -clock dram_clk_out 3.2 [get_ports {dram_dq[*]}]
set_output_delay -max -clock dram_clk_out 1.5 [get_ports {dram_dq[*] dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n dram_cke}]
set_output_delay -min -clock dram_clk_out -0.8 [get_ports {dram_dq[*] dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n dram_cke}]

# The controller reads DQ one full clock after the CAS latency expires, so the
# capture is a whole period away from the launch, not half.
set_multicycle_path -setup 2 -from [get_ports {dram_dq[*]}] -to [get_registers {*|sdram16:*|data[*]}]
set_multicycle_path -hold  1 -from [get_ports {dram_dq[*]}] -to [get_registers {*|sdram16:*|data[*]}]

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
