bind mem_bank_superlane_leaf mem_p1_leaf_checker u_mem_input_checker (
  .clk_i(clk_i), .rst_ni(rst_ni), .cmd_valid_i(cmd_valid_i),
  .cmd_opcode_i(cmd_opcode_i), .cmd_row_i(cmd_row_i),
  .cmd_stream_dir_i(cmd_stream_dir_i), .cmd_stream_idx_i(cmd_stream_idx_i),
  .cmd_preserve_i(cmd_preserve_i), .stream_valid_i(stream_valid_i), .stream_data_i(stream_data_i)
);
