# ==============================================================================
# Quartus Prime Synopsys Design Constraint File
# ==============================================================================
# Punch-Out!! core constraints.
#
# The Pocket BSP (platform/pocket/bsp/pocket/sys_constr.sdc) creates the APF
# clocks; this file describes what is specific to this core.
#
# There is no external memory here at all -- the whole 53 KB romset lives in
# block RAM -- so there are no SDRAM pin constraints to get right.
# ==============================================================================

# ==============================================================================
# The two 6809s are clocked by E and Q rather than by clk_sys -- mc6809i has no
# system clock input at all. Both are generated from clk_sys by a 32-count
# divider, so declare them and keep them in the machine's clock group.
# ==============================================================================
create_generated_clock -name cpu_e -source [get_pins {ic|core_pll|core_pll_inst|altera_pll_i|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -divide_by 32 [get_registers {*|tp84_main:u_main|cpu_e}]
create_generated_clock -name cpu_q -source [get_pins {ic|core_pll|core_pll_inst|altera_pll_i|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -divide_by 32 -phase 90 [get_registers {*|tp84_main:u_main|cpu_q}]

# ==============================================================================
# Clock groups
#
# core_pll general[0] = clk_sys       49.152 MHz (8x the dot clock)
#          general[1] = clk_vid        6.144 MHz (dot clock)
#          general[2] = clk_vid 90deg  6.144 MHz
#          general[3], general[4]      unused
#
# clk_sys and the two pixel clocks stay in ONE group on purpose. The video
# output is launched on clk_sys and sampled by the APF scaler on clk_vid; they
# are integer-related outputs of the same PLL, so that crossing is synchronous
# by construction and should be verified rather than cut. Cutting it would let
# each build route it blind and make the picture depend on the fitter seed.
#
# clk_74a, clk_74b, the bridge SPI clock and the audio PLL are genuinely
# asynchronous to the machine. The one multi-bit bus that crosses into clk_74b
# -- the audio sample -- is handed over with a toggle flag in core_top, so the
# capture is always of a value that has been still for several cycles.
# ==============================================================================
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk \
          cpu_e cpu_q } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

# ==============================================================================
# CPU multicycle.
#
# The sound Z80 advances only on a clock enable, at worst every 13 clk_sys
# cycles (a phase accumulator averaging 3.579545 MHz), so every
# register-to-register path *inside* tv80_core has at least 13 clock periods to
# settle and tv80's microcode decode is the widest combinational block in it.
#
# Deliberately scoped to paths that both start and end inside the CPU: the
# address and data buses run to block RAM ports that are clocked every cycle,
# and those must still meet single-cycle timing.
#
# 6 rather than 13: half the provable margin, which is plenty of relief and
# leaves the constraint correct even if the enable generation is ever changed.
# ==============================================================================
set_multicycle_path -setup 6 -from [get_registers {*|tv80_core:*|*}] -to [get_registers {*|tv80_core:*|*}]
set_multicycle_path -hold  5 -from [get_registers {*|tv80_core:*|*}] -to [get_registers {*|tv80_core:*|*}]



# ==============================================================================
# clk_sys <-> E/Q multicycle.
#
# E and Q are generated from clk_sys by a 32-count divider, so the timing
# analyser pairs them at the tightest available edge -- one clk_sys period,
# 20.3 ns -- for every path that crosses between the two domains. That is not
# what the hardware does. A 6809 bus cycle is 32 clk_sys periods long:
#
#   * clk_sys -> E/Q is the registered read mux feeding the CPU's data bus. The
#     address has been stable since the last E edge, so the value settles within
#     a few clk_sys cycles and is then held until the CPU samples it 32 later.
#   * E/Q -> clk_sys is the CPU's address and write data reaching the block RAM
#     ports and the write strobe. The strobe fires at count 31, and the memories
#     are only read back a full bus cycle later.
#
# 16 rather than 32: half the provable margin, which is ample relief and leaves
# the constraint correct even if the divider is ever changed.
# ==============================================================================
# The brackets must be escaped. get_clocks matches with Tcl globbing, where
# general[0] is a character class matching the single character "0" -- so the
# unescaped pattern matches "general0..." and silently selects nothing. The
# exceptions below were being dropped entirely, which is why two compiles gave
# byte-identical slack.
set CLKSYS {ic|core_pll|core_pll_inst|altera_pll_i|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk}

set_multicycle_path -setup -end 16 -from [get_clocks $CLKSYS]      -to [get_clocks {cpu_e cpu_q}]
set_multicycle_path -hold  -end 15 -from [get_clocks $CLKSYS]      -to [get_clocks {cpu_e cpu_q}]
set_multicycle_path -setup -end 16 -from [get_clocks {cpu_e cpu_q}] -to [get_clocks $CLKSYS]
set_multicycle_path -hold  -end 15 -from [get_clocks {cpu_e cpu_q}] -to [get_clocks $CLKSYS]
# NOT relaxed: E-to-E paths are mc6809i's own internal logic, and those
# registers advance on every falling edge of E. They have one E period, not
# sixteen. An earlier version of this file relaxed them along with the
# cross-domain paths, which is the sort of exception that simulates perfectly
# and misbehaves only on silicon.
