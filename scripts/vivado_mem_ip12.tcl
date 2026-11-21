# Run from an empty evidence directory:
# vivado -mode batch -source <repo>/scripts/vivado_mem_ip12.tcl -tclargs 16
# Profile 32 and an optional target part can be passed in the same way.
# A third argument (existing DCP) reruns only the storage/blackbox audit.
set root [file normalize [file join [file dirname [info script]] ..]]
if {$argc < 1 || $argc > 3} { error "usage: profile(16|32) ?part? ?synth.dcp?" }
set profile [lindex $argv 0]
switch -- $profile {
    16 { set tiles 2; set depth 1024; set period 5.000 }
    32 { set tiles 4; set depth 2048; set period 2.000 }
    default { error "IP-12 scope is LPU16/LPU32 only" }
}
set part [expr {$argc >= 2 ? [lindex $argv 1] : "xcvu19p-fsva3824-2-e"}]
set_param general.maxThreads 8

proc audit_storage {profile tiles depth} {
    set primitives [get_cells -hierarchical -quiet -filter {REF_NAME =~ RAMB36* || REF_NAME =~ RAMB18* || REF_NAME =~ URAM*}]
    set counts [dict create ramb36 0 ramb18 0 uram 0]
    set leaves [dict create]
    foreach c $primitives {
        set name [get_property NAME $c]
        set ref [get_property REF_NAME $c]
        if {![regexp {^(.*)/mem_array_reg_[^/]+$} $name -> leaf]} {
            error "Unrecognized MEM storage primitive: $name"
        }
        if {[string match RAMB36* $ref]} {
            dict incr counts ramb36
            set bits 36864
        } elseif {[string match RAMB18* $ref]} {
            dict incr counts ramb18
            set bits 18432
        } else {
            dict incr counts uram
            set bits 294912
        }
        dict incr leaves $leaf $bits
    }
    set blackboxes [llength [get_cells -hierarchical -quiet -filter {IS_BLACKBOX == 1}]]
    set expected [expr {52*2*$tiles}]
    set fd [open storage_audit.txt w]
    puts $fd "profile=$profile expected_leaves=$expected mapped_leaves=[dict size $leaves]"
    puts $fd "blackboxes=$blackboxes $counts"
    dict for {leaf bits} $leaves {
        puts $fd "$bits $leaf"
    }
    close $fd
    if {$blackboxes != 0 || [dict size $leaves] != $expected} {
        error "Incomplete MEM hierarchy; see storage_audit.txt"
    }
    dict for {leaf bits} $leaves {
        if {$bits < $depth*64} { error "Insufficient memory capacity for $leaf" }
    }
    puts "MEM_IP12_STORAGE_PASS profile=$profile leaves=$expected $counts"
    return $counts
}

if {$argc == 3} {
    open_checkpoint [file normalize [lindex $argv 2]]
    if {[get_property PART [current_design]] ne $part} { error "checkpoint part mismatch" }
    audit_storage $profile $tiles $depth
    exit
}

set fd [open mem_ooc.xdc w]
puts $fd "create_clock -name mem_clk -period $period \[get_ports clk_i\]"
puts $fd {set_clock_uncertainty 0.100 [get_clocks mem_clk]}
puts $fd {set_input_delay -clock mem_clk -min 0.000 [get_ports -filter {DIRECTION == IN && NAME != clk_i && NAME != rst_ni}]}
puts $fd {set_input_delay -clock mem_clk -max 0.200 [get_ports -filter {DIRECTION == IN && NAME != clk_i && NAME != rst_ni}]}
puts $fd {set_output_delay -clock mem_clk -min 0.000 [all_outputs]}
puts $fd {set_output_delay -clock mem_clk -max 0.200 [all_outputs]}
puts $fd {set_false_path -from [get_ports rst_ni]}
close $fd

foreach name {mem_bank_control_column mem_bank_superlane_leaf mem_logical_bank_column mem_slice mem_group mem_hemisphere} {
    read_verilog -sv [file join $root rtl mem_native ${name}.sv]
}
read_xdc mem_ooc.xdc
synth_design -top mem_hemisphere -part $part -mode out_of_context \
    -flatten_hierarchy rebuilt -generic [list P_MEM_SLICES_PER_HEMI=52 \
        P_MEM_SLICES_PER_GROUP=4 P_TILE_ROWS=$tiles \
        P_MEM_BANK_DEPTH_ROWS=$depth P_MEM_ACTIVE_ROWS=$depth]

report_utilization -file utilization.rpt
report_utilization -hierarchical -hierarchical_depth 2 -file hierarchy.rpt
report_timing_summary -delay_type max -max_paths 10 -report_unconstrained -file timing_summary.rpt
report_timing -delay_type max -max_paths 10 -file setup_paths.rpt
check_timing -verbose -file check_timing.rpt
write_checkpoint -force mem_synth.dcp

set storage [audit_storage $profile $tiles $depth]
set bram36 [dict get $storage ramb36]
set bram18 [dict get $storage ramb18]
set uram [dict get $storage uram]
set blackboxes [llength [get_cells -hierarchical -quiet -filter {IS_BLACKBOX == 1}]]
set logical_bits [expr {52*2*$tiles*$depth*64}]
set path [get_timing_paths -quiet -delay_type max -max_paths 1]
if {[llength $path] != 1} { error "no constrained max timing path" }
set wns [get_property SLACK $path]
set critical_period [expr {$period - $wns}]
if {[llength [get_clocks -quiet mem_clk]] != 1} { error "missing mem_clk" }
set fd [open measurements.txt w]
puts $fd "profile=$profile\ntiles=$tiles\ndepth=$depth\npart=$part\nperiod_ns=$period"
puts $fd "ram_leaves=[expr {52*2*$tiles}]\nlogical_storage_bits=$logical_bits"
puts $fd "ramb36=$bram36\nramb18=$bram18\nuram=$uram\nblackboxes=$blackboxes\nwns_ns=$wns"
puts $fd "critical_period_est_ns=$critical_period"
puts $fd "critical_frequency_est_mhz=[expr {1000.0/$critical_period}]"
close $fd
puts "MEM_IP12_SYNTH_PASS profile=$profile"
