set_param general.maxThreads 1
create_project -in_memory -part xcvu9p-flga2104-2L-e
set_property verilog_define {FTLPU_DISABLE_BLOCK8} [current_fileset]
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_mxm_full001/src/rtl/core/lpu_pkg.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_mxm_full001/src/rtl/vxm/lpu_vxm_math_pkg.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_mxm_full001/src/rtl/mxm/lpu_mxm_dot_bank.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_mxm_full001/src/rtl/mxm/lpu_mxm_compute.sv}
read_xdc {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm_full001/mxm_compute_default/timing.xdc}
synth_design -top lpu_mxm_compute -part xcvu9p-flga2104-2L-e -mode out_of_context -flatten_hierarchy rebuilt -generic {ACCUMULATOR_BLOCK_COUNT=1}
report_utilization -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm_full001/mxm_compute_default/utilization.rpt}
report_utilization -hierarchical -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm_full001/mxm_compute_default/utilization_hier.rpt}
write_checkpoint -force [file join {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm_full001/mxm_compute_default} synthesized.dcp]
write_verilog -force -mode funcsim [file join {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm_full001/mxm_compute_default} netlist.v]
set fd [open {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm_full001/mxm_compute_default/primitives.txt} w]
foreach pattern {LUT* FD* RAMB18E2 RAMB36E2 URAM288 DSP48E2 SRL* MUXF* CARRY* LD*} {
  set selector [format {REF_NAME =~ %s} $pattern]
  puts $fd "$pattern=[llength [get_cells -hier -quiet -filter $selector]]"
}
puts $fd "blackbox_count=[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]"
close $fd
report_timing_summary -max_paths 3 -report_unconstrained -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm_full001/mxm_compute_default/timing_summary.rpt}
report_drc -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm_full001/mxm_compute_default/drc.rpt}
puts "MAPPING_COMPLETED mxm_compute_default"
exit
