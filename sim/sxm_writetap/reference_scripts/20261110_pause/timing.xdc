create_clock -period 10.000 -name clk [get_ports clk_i]
set_input_delay 1.0 -clock clk [get_ports -filter {DIRECTION == IN && NAME != clk_i && NAME != rst_ni}]
set_output_delay 1.0 -clock clk [all_outputs]
set_false_path -from [get_ports rst_ni]
