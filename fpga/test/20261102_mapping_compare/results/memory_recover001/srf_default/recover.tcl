open_checkpoint {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/memory001/srf_default/synthesized.dcp}
set fd [open {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/memory_recover001/srf_default/primitives.txt} w]
foreach pattern {LUT* FD* RAMB18E2 RAMB36E2 URAM288 DSP48E2 SRL* MUXF* CARRY* LD*} {
 set selector [format {REF_NAME =~ %s} $pattern]
 puts $fd "$pattern=[llength [get_cells -hier -quiet -filter $selector]]"
}
puts $fd "blackbox_count=[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]"
close $fd
report_timing_summary -max_paths 3 -report_unconstrained -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/memory_recover001/srf_default/timing_summary.rpt}
report_drc -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/memory_recover001/srf_default/drc.rpt}
puts RECOVERY_COMPLETED
exit
