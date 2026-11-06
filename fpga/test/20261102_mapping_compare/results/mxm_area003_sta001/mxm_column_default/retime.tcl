set_param general.maxThreads 1
open_checkpoint {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm_area003/mxm_column_default/synthesized.dcp}
set data_inputs [get_ports -filter {DIRECTION == IN && NAME != clk_i && NAME != rst_ni}]
for {set i 0} {$i < [llength $data_inputs]} {incr i 512} {set_input_delay 1.0 -clock clk [lrange $data_inputs $i [expr {$i+511}]]}
set data_outputs [all_outputs]
for {set i 0} {$i < [llength $data_outputs]} {incr i 512} {set_output_delay 1.0 -clock clk [lrange $data_outputs $i [expr {$i+511}]]}
report_timing_summary -max_paths 3 -report_unconstrained -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm_area003_sta001/mxm_column_default/timing_summary.rpt}
report_drc -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm_area003_sta001/mxm_column_default/drc.rpt}
write_xdc -force {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm_area003_sta001/mxm_column_default/resolved_timing.xdc}
puts "RETIME_COMPLETED"
exit
