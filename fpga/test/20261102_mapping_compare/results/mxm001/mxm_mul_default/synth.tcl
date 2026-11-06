set_param general.maxThreads 1
create_project -in_memory -part xcvu9p-flga2104-2L-e

read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_mxm001/src/rtl/vxm/lpu_vxm_math_pkg.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_mxm001/src/experiment/rtl/mxm_mul.sv}
read_xdc {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm001/mxm_mul_default/timing.xdc}
synth_design -top fpga_mxm_mul -part xcvu9p-flga2104-2L-e -mode out_of_context -flatten_hierarchy rebuilt
report_utilization -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm001/mxm_mul_default/utilization.rpt}
report_utilization -hierarchical -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm001/mxm_mul_default/utilization_hier.rpt}
write_checkpoint -force [file join {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm001/mxm_mul_default} synthesized.dcp]
write_verilog -force -mode funcsim [file join {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm001/mxm_mul_default} netlist.v]
set fd [open {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm001/mxm_mul_default/primitives.txt} w]
foreach pattern {LUT* FD* RAMB18* RAMB36* URAM* DSP* SRL* MUXF* CARRY* LD*} {
  set selector [format {REF_NAME =~ %s} $pattern]
  puts $fd "$pattern=[llength [get_cells -hier -quiet -filter $selector]]"
}
puts $fd "blackbox_count=[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]"
close $fd
report_timing_summary -max_paths 3 -report_unconstrained -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm001/mxm_mul_default/timing_summary.rpt}
report_drc -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/mxm001/mxm_mul_default/drc.rpt}
puts "MAPPING_COMPLETED mxm_mul_default"
exit
