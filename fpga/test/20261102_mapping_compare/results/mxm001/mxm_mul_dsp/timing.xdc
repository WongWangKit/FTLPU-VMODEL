create_clock -period 10.0 -name clk
set_input_delay 1.0 -clock clk [get_ports -filter {DIRECTION == IN && NAME != clk_i && NAME != rst_ni}]
set_output_delay 1.0 -clock clk [all_outputs]
