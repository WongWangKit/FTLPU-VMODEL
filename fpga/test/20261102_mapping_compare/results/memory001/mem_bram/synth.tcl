set_param general.maxThreads 1
create_project -in_memory -part xcvu9p-flga2104-2L-e

read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_memory001/src/experiment/rtl/mem_leaf_bram.sv}
read_xdc {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/memory001/mem_bram/timing.xdc}
synth_design -top mem_bank_superlane_leaf -part xcvu9p-flga2104-2L-e -mode out_of_context -flatten_hierarchy rebuilt -generic {P_MEM_BANK_DEPTH_ROWS=1024 P_MEM_ACTIVE_ROWS=1024}
report_utilization -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/memory001/mem_bram/utilization.rpt}
report_utilization -hierarchical -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/memory001/mem_bram/utilization_hier.rpt}
write_checkpoint -force [file join {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/memory001/mem_bram} synthesized.dcp]
write_verilog -force -mode funcsim [file join {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/memory001/mem_bram} netlist.v]
set fd [open {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/memory001/mem_bram/primitives.txt} w]
foreach pattern {LUT* FD* RAMB18* RAMB36* URAM* DSP* SRL* MUXF* CARRY* LD*} {
  puts $fd "$pattern=[llength [get_cells -hier -quiet -filter \"REF_NAME =~ $pattern\"]]"
}
puts $fd "blackbox_count=[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]"
close $fd
report_timing_summary -max_paths 3 -report_unconstrained -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/memory001/mem_bram/timing_summary.rpt}
report_drc -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/memory001/mem_bram/drc.rpt}
puts "MAPPING_COMPLETED mem_bram"
exit
