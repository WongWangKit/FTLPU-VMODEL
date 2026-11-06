set_param general.maxThreads 1
create_project -in_memory -part xcvu9p-flga2104-2L-e

read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/core/lpu_pkg.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/core/lpu_isa_decode.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/core/lpu_stream_stage.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/core/lpu_control_pipeline.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/icu/lpu_icu_queue.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/icu/lpu_icu.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mem/lpu_sram_1rw_banked.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mem/lpu_mem_tile_slice.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mem/lpu_mem_tile_slice_sram.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mem/lpu_mem_tile_slice_select.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mem/lpu_mem_column.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mem/lpu_mem_hemisphere.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_math_pkg.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_fp16_pkg.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_input_converter.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_fp16_stream_groups.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_local_decoder.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_datapath_mux.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_datapath_stage.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_global_config.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_instruction_controller.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mxm/lpu_mxm_control.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mxm/lpu_mxm_dequantizer.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mxm/lpu_mxm_weight_buffer.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mxm/lpu_mxm_dot_bank.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mxm/lpu_mxm_compute.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mxm/lpu_mxm_accumulator_sram.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mxm/lpu_mxm_shared_accumulator.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mxm/lpu_mxm_accumulator.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mxm/lpu_mxm_block_accumulator.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/mxm/lpu_mxm_slice.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/sxm/lpu_sxm_control.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/sxm/lpu_sxm_slice.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_control.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/experiment/rtl/mul8x8_dsp.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_csa3_2.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_significand_multiplier.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_shared_float_multiplier.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_special_coefficient_multiplier.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_recip_linear_fixed.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_fp32_newton_multiplier.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_rsqrt_linear_fixed.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_fp32_rsqrt_correction.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_float_unpack.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_basic_opcode_decode.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_shared_float_compare.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_segmented_addsub.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_grouped_lzc.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_shared_left_shift.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_shared_float_adder.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_basic_alu.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_lut_storage.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_lut_sram.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_tile_pair_lut.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_special_alu.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/rtl/vxm/lpu_vxm_alu.sv}
read_verilog -sv {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/tmp/mapping_vxm001/src/experiment/rtl/basic_alu_probe.sv}
read_xdc {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/vxm001/alu_dsp/timing.xdc}
synth_design -top fpga_basic_alu_probe -part xcvu9p-flga2104-2L-e -mode out_of_context -flatten_hierarchy rebuilt -generic {FIXED_BF16=0}
report_utilization -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/vxm001/alu_dsp/utilization.rpt}
report_utilization -hierarchical -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/vxm001/alu_dsp/utilization_hier.rpt}
write_checkpoint -force [file join {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/vxm001/alu_dsp} synthesized.dcp]
write_verilog -force -mode funcsim [file join {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/vxm001/alu_dsp} netlist.v]
set fd [open {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/vxm001/alu_dsp/primitives.txt} w]
foreach pattern {LUT* FD* RAMB18* RAMB36* URAM* DSP* SRL* MUXF* CARRY* LD*} {
  puts $fd "$pattern=[llength [get_cells -hier -quiet -filter \"REF_NAME =~ $pattern\"]]"
}
puts $fd "blackbox_count=[llength [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]]"
close $fd
report_timing_summary -max_paths 3 -report_unconstrained -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/vxm001/alu_dsp/timing_summary.rpt}
report_drc -file {C:/Users/huazh/Desktop/LPU/lpu_src/FTLPU-VMODEL/fpga/test/20261102_mapping_compare/results/vxm001/alu_dsp/drc.rpt}
puts "MAPPING_COMPLETED alu_dsp"
exit
