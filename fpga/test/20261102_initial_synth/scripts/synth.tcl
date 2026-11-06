puts "RAW_ARGV=$argv"
set src [lindex $argv 0]
set out [lindex $argv 1]
set case_name [lindex $argv 2]
set part [lindex $argv 3]
set_param general.maxThreads 1
file mkdir $out
create_project -in_memory -part $part
set rtl {}
set fd [open [file join $src sim filelist.f] r]
foreach line [split [read $fd] "\n"] {
  set line [string trim $line]
  if {[string match "rtl/*" $line]} {lappend rtl [file join $src $line]}
}
close $fd
set generics {}
switch $case_name {
  mem_leaf {
    set rtl [list [file join $src rtl/mem_native/mem_bank_superlane_leaf.sv]]
    set top mem_bank_superlane_leaf
    set generics {P_MEM_BANK_DEPTH_ROWS=1024 P_MEM_ACTIVE_ROWS=1024}
  }
  mem_leaf_bram {
    set rtl [list [file join $src fpga_experiment/rtl/mem_leaf_bram.sv]]
    set top mem_bank_superlane_leaf
    set generics {P_MEM_BANK_DEPTH_ROWS=1024 P_MEM_ACTIVE_ROWS=1024}
  }
  mem_slice {
    set rtl {}
    foreach f {mem_bank_superlane_leaf mem_bank_control_column mem_logical_bank_column mem_slice} {
      lappend rtl [file join $src rtl/mem_native/$f.sv]
    }
    set top mem_slice
    set generics {P_TILE_ROWS=2 P_MEM_BANK_DEPTH_ROWS=1024 P_MEM_ACTIVE_ROWS=1024}
  }
  mem_slice_bram {
    set rtl [list [file join $src fpga_experiment/rtl/mem_leaf_bram.sv]]
    foreach f {mem_bank_control_column mem_logical_bank_column mem_slice} {
      lappend rtl [file join $src rtl/mem_native/$f.sv]
    }
    set top mem_slice
    set generics {P_TILE_ROWS=2 P_MEM_BANK_DEPTH_ROWS=1024 P_MEM_ACTIVE_ROWS=1024}
  }
  srf_leaf {
    set rtl [list [file join $src rtl/srf/ftlpu_sr_superlane_col_dir.sv]]
    set top ftlpu_sr_superlane_col_dir_lane
  }
  old_mem {
    set rtl [list [file join $src rtl/core/lpu_pkg.sv] [file join $src rtl/core/lpu_isa_decode.sv] [file join $src rtl/mem/lpu_mem_tile_slice.sv]]
    set top lpu_mem_tile_slice_behavior
    set generics {DEPTH_ROWS=1024}
  }
  old_dot {
    set rtl [list [file join $src rtl/vxm/lpu_vxm_math_pkg.sv] [file join $src rtl/mxm/lpu_mxm_dot_bank.sv]]
    set top lpu_mxm_dot_bank
  }
  alu_basic {set top lpu_vxm_alu; set generics {SPECIAL_KIND=0}}
  alu_exp {set top lpu_vxm_alu; set generics {SPECIAL_KIND=1}}
  alu_recip {set top lpu_vxm_alu; set generics {SPECIAL_KIND=2}}
  alu_basic_pruned {set top fpga_basic_alu_probe; set generics {FIXED_BF16=0}}
  alu_basic_bf16 {set top fpga_basic_alu_probe; set generics {FIXED_BF16=1}}
  old_top {
    set top lpu_top
    set generics {ICU_QUEUE_DEPTH=4 MEM_DEPTH_ROWS=64 ACTIVE_MEM_COLUMNS=4 MXM_ACCUMULATOR_BLOCK_COUNT=1}
    set_property verilog_define FTLPU_DISABLE_BLOCK8 [current_fileset]
  }
  default {error "Unknown case: $case_name"}
}
puts "EXPERIMENT case=$case_name top=$top part=$part generics=$generics"
if {[string match "alu_*" $case_name]} {
  # Compile only this leaf's dependency closure, not unrelated tile/top code.
  set index [lsearch -exact $rtl [file join $src rtl/vxm/lpu_vxm_alu.sv]]
  set rtl [lrange $rtl 0 $index]
  if {$top == "fpga_basic_alu_probe"} {lappend rtl [file join $src fpga_experiment/rtl/basic_alu_probe.sv]}
}
read_verilog -sv $rtl
# OOC intentionally excludes package pins and board shell. Every port stays dynamic.
set args [list -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt]
if {[llength $generics]} {lappend args -generic $generics}
synth_design {*}$args
if {[llength [get_ports -quiet clk_i]]} {
  create_clock -period 10.000 -name clk [get_ports clk_i]
  set data_inputs [get_ports -filter {DIRECTION == IN && NAME != clk_i && NAME != rst_ni}]
  set_input_delay 1.0 -clock clk $data_inputs
  set_output_delay 1.0 -clock clk [all_outputs]
  if {[llength [get_ports -quiet rst_ni]]} {set_false_path -from [get_ports rst_ni]}
} else {
  create_clock -period 10.000 -name virtual_clk
  set_input_delay 1.0 -clock virtual_clk [all_inputs]
  set_output_delay 1.0 -clock virtual_clk [all_outputs]
}
write_checkpoint -force [file join $out synthesized.dcp]
write_verilog -force -mode funcsim [file join $out netlist.v]
report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -file [file join $out utilization_hier.rpt]
report_timing_summary -max_paths 10 -report_unconstrained -file [file join $out timing_summary.rpt]
report_drc -file [file join $out drc.rpt]
set blackboxes [get_cells -quiet -hier -filter {IS_BLACKBOX == 1}]
set fd [open [file join $out checks.txt] w]
puts $fd "blackbox_count=[llength $blackboxes]"
puts $fd "latch_count=[llength [get_cells -hier -quiet -filter {REF_NAME =~ LD*}]]"
close $fd
puts "SYNTHESIS_COMPLETED case=$case_name"
exit
