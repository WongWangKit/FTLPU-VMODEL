create_clock -period 10.0 -name clk
set data_inputs [get_ports -filter {DIRECTION == IN && NAME != clk_i && NAME != rst_ni}]
for {set i 0} {$i < [llength $data_inputs]} {incr i 512} {set_input_delay 1.0 -clock clk [lrange $data_inputs $i [expr {$i+511}]]}
set data_outputs [all_outputs]
for {set i 0} {$i < [llength $data_outputs]} {incr i 512} {set_output_delay 1.0 -clock clk [lrange $data_outputs $i [expr {$i+511}]]}
