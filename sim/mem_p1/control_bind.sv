bind mem_bank_control_column mem_p1_command_checker u_mem_command_checker (
  .clk_i(clk_i), .rst_ni(rst_ni), .valid_i(south_cmd_valid_i), .command_i(south_cmd_i)
);
