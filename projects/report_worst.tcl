project_open tp84_pocket
create_timing_netlist
read_sdc
update_timing_netlist
set_time_format -unit ns -decimal_places 3
report_timing -setup -npaths 2 -detail full_path -to_clock cpu_e -file worst_to_cpu_e.rpt
report_timing -setup -npaths 2 -detail full_path -from_clock cpu_e -file worst_from_cpu_e.rpt
project_close
