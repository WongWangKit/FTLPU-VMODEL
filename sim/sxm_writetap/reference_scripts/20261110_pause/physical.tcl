set src [lindex $argv 0]
set out [lindex $argv 1]
set tiles [lindex $argv 2]
set work [lindex $argv 3]
set resume [lindex $argv 4]
set synth_mode [lindex $argv 5]
set resume_stage [lindex $argv 6]
set clock_site [lindex $argv 7]
set route_directive [lindex $argv 8]
set stop_after [lindex $argv 9]
proc finish_stage {stage} {
  global stop_after
  if {$stop_after eq $stage} {puts "SXM_STAGE_FINISHED $stage";exit}
}
set top [lindex $argv 12]
set completed 0
puts "ENV_CHECK native=[exec cmd.exe /d /c cd] tcl=[pwd] normalized=[file normalize [pwd]] expected=$work"
if {[file normalize [pwd]] ne $work} {error "Unsafe Tcl cwd normalization; stop before synthesis"}
set threads 4
if {[llength $argv]>10} {set threads [lindex $argv 10]}
set_param general.maxThreads $threads
set timing_scope all
if {[llength $argv]>11} {set timing_scope [lindex $argv 11]}
if {$resume eq "none"} {
  create_project -in_memory -part xcvu9p-flga2104-2L-e
  set fh [open [file join $src rtl_files.txt] r]
  foreach name [split [string trim [read $fh]] "\n"] {read_verilog -sv [file join $src $name]}
  close $fh
  # Keep all constraints. Structural mapping may skip timing-driven synthesis;
  # implementation and final min/max STA retain the full 100 MHz contract.
  read_xdc [file join $src timing.xdc]
  foreach name {XILINX_PATH HRT_TCL_PATH SYNTH_COMMON} {
    if {[info exists env($name)]} {puts "SYNTH_ENV $name=$env($name)"}
  }
  set extra {}
  if {$synth_mode eq "structural"} {lappend extra -no_timing_driven}
  set generics [list T=$tiles]
  if {$top eq "sxm_triangle_full_core" || $top eq "sxm_triangle_writetap_core"} {lappend generics PORT_STREAMS=32 TIMER_BITS=16}
  synth_design -top $top -part xcvu9p-flga2104-2L-e -mode out_of_context -flatten_hierarchy rebuilt -generic $generics {*}$extra
} else {
  open_checkpoint $resume
  set completed [lsearch -exact {synthesized optimized placed physopt routed} $resume_stage]
  if {$completed < 0} {error "invalid resume stage"}
}
if {[llength [get_sites -quiet $clock_site]] != 1} {error "Invalid OOC clock source site: $clock_site"}
# A checkpoint may carry the previous run's IO exceptions. Rebuild the exact
# recorded timing contract; physical clock-source property is set explicitly.
reset_timing
read_xdc [file join $src timing.xdc]
set_property HD.CLK_SRC $clock_site [get_ports clk_i]
puts "OOC_CLOCK_CONTEXT HD.CLK_SRC=$clock_site (evaluation assumption, not system floorplan)"
if {$timing_scope eq "internal"} {
  set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != clk_i && NAME != rst_ni}]
  set_false_path -to [all_outputs]
  puts "TIMING_SCOPE internal: user-approved core signoff; IO budget reported separately after routing"
}
if {$completed == 0} {
write_checkpoint -force [file join $out synthesized.dcp]
write_verilog -force -mode funcsim [file join $out synthesized.v]
report_utilization -hierarchical -file [file join $out synth_hierarchical.rpt]
report_utilization -file [file join $out synth_utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 10 -report_unconstrained -file [file join $out synth_timing.rpt]
set fd [open [file join $out checks.txt] w]
puts $fd "blackbox_count=[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]"
puts $fd "latch_count=[llength [get_cells -hier -quiet -filter {REF_NAME =~ LD*}]]"
puts $fd "clocks=[get_clocks]"
close $fd
puts "SXM_STAGE_DONE synth T=$tiles"
finish_stage synthesized
}
if {$completed < 1} {
opt_design
write_checkpoint -force [file join $out optimized.dcp]
finish_stage optimized
}
if {$completed < 2} {
place_design
write_checkpoint -force [file join $out placed.dcp]
report_timing_summary -delay_type min_max -max_paths 10 -file [file join $out placed_timing.rpt]
puts "SXM_STAGE_DONE place T=$tiles"
finish_stage placed
}
if {$completed < 3} {
phys_opt_design
write_checkpoint -force [file join $out physopt.dcp]
finish_stage physopt
}
if {$completed < 4} {
route_design -directive $route_directive
}
write_checkpoint -force [file join $out routed.dcp]
report_utilization -file [file join $out routed_utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 20 -report_unconstrained -file [file join $out routed_timing.rpt]
report_timing -delay_type max -max_paths 10 -file [file join $out setup_paths.rpt]
report_timing -delay_type min -max_paths 10 -file [file join $out hold_paths.rpt]
report_timing -from [all_registers] -to [all_registers] -delay_type max -path_type full_clock_expanded -max_paths 10 -file [file join $out internal_setup.rpt]
report_timing -from [all_registers] -to [all_registers] -delay_type min -path_type full_clock_expanded -max_paths 10 -file [file join $out internal_hold.rpt]
set fd [open [file join $out clock_and_internal_sta.txt] w]
puts $fd "HD.CLK_SRC=[get_property HD.CLK_SRC [get_ports clk_i]]"
foreach kind {max min} {
  set paths [get_timing_paths -from [all_registers] -to [all_registers] -delay_type $kind -max_paths 1]
  if {[llength $paths] != 1} {error "Missing internal $kind timing path"}
  puts $fd "$kind.slack_ns=[get_property SLACK $paths]"
  puts $fd "$kind.start=[get_property STARTPOINT_PIN $paths]"
  puts $fd "$kind.end=[get_property ENDPOINT_PIN $paths]"
}
close $fd
report_route_status -file [file join $out route_status.rpt]
report_route_status -route_type GAPS -list_all_nets -file [file join $out route_gaps.rpt]
report_route_status -route_type PARTIAL -list_all_nets -file [file join $out route_partial.rpt]
set fd [open [file join $out route_gap_nets.txt] w]
puts $fd "GAP_NETS [report_route_status -route_type GAPS -return_nets]"
puts $fd "PARTIAL_NETS [report_route_status -route_type PARTIAL -return_nets]"
close $fd
report_drc -file [file join $out drc.rpt]
check_timing -verbose -file [file join $out check_timing.rpt]
write_xdc -force [file join $out implemented.xdc]
# The full object report is costly on wide OOC interfaces. Exact exceptions are
# preserved in implemented.xdc and the DCP; summarize rather than enumerate them.
report_exceptions -summary -file [file join $out implemented_exceptions.rpt]
# Internal-scope runs restore IO budgets in a fresh read-only Vivado process,
# releasing the implementation working set before building a second STA view.
puts "SXM_PHYSICAL_FINISHED T=$tiles"
exit
