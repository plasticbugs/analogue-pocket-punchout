# Worst setup paths on the machine clock. Run against a completed compile:
#   docker run --rm --platform linux/amd64 -v "$PWD":/build -w /build \
#       raetro/quartus:pocket quartus_sta -t projects/report_worst.tcl
# Writes output_files/worst_paths.txt next to the other reports.
cd projects
if {[catch {project_open punchout_pocket -revision punchout_pocket} err]} {
    puts "PROJECT OPEN FAILED: $err"; exit 1
}
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set n [report_timing -setup -npaths 40 -detail full_path \
        -file output_files/worst_paths.txt]
puts "report_timing returned: $n"
delete_timing_netlist
project_close
