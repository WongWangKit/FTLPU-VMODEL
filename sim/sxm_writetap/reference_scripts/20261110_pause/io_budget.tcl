set out [lindex $argv 0]
set xdc [lindex $argv 1]
set clock_site [lindex $argv 2]
set_param general.maxThreads [lindex $argv 3]
open_checkpoint [file join $out routed.dcp]
set fd [open [file join $out clock_and_internal_sta.txt] r]
set old [read $fd];close $fd
if {![regexp {max.slack_ns=([-0-9.]+)} $old -> core_max] || ![regexp {min.slack_ns=([-0-9.]+)} $old -> core_min]} {error "Missing saved core STA"}
reset_timing
read_xdc $xdc
set_property HD.CLK_SRC $clock_site [get_ports clk_i]
report_timing_summary -delay_type min_max -max_paths 10 -report_unconstrained -file [file join $out io_budget_timing.rpt]
foreach kind {max min} {
  report_timing -from [get_ports -filter {DIRECTION == IN && NAME != clk_i && NAME != rst_ni}] -delay_type $kind -max_paths 10 -file [file join $out io_inputs_$kind.rpt]
  report_timing -to [all_outputs] -delay_type $kind -max_paths 10 -file [file join $out io_outputs_$kind.rpt]
}
write_xdc -force [file join $out io_budget.xdc]
set after_max [get_property SLACK [get_timing_paths -from [all_registers] -to [all_registers] -delay_type max -max_paths 1]]
set after_min [get_property SLACK [get_timing_paths -from [all_registers] -to [all_registers] -delay_type min -max_paths 1]]
if {abs($core_max-$after_max)>0.001 || abs($core_min-$after_min)>0.001} {error "IO exception removal changed core timing"}
set fd [open [file join $out timing_scope_check.txt] w]
puts $fd "scope=internal; IO budget is separate, not signoff"
puts $fd "core_max_before=$core_max after=$after_max"
puts $fd "core_min_before=$core_min after=$after_min"
close $fd
puts "SXM_IO_BUDGET_FINISHED"
exit
