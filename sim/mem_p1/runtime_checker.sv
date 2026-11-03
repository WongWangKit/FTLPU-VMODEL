`timescale 1ns/1ps

// Passive, simulation-only checks. Invalid payload is unconstrained.
module mem_p1_leaf_checker (
  input logic clk_i, rst_ni, cmd_valid_i,
  input logic [2:0] cmd_opcode_i,
  input logic [14:0] cmd_row_i,
  input logic cmd_stream_dir_i,
  input logic [4:0] cmd_stream_idx_i,
  input logic cmd_preserve_i, stream_valid_i,
  input logic [63:0] stream_data_i
);
  bit reset_seen = 0;
  always @(negedge rst_ni)
    if (rst_ni === 1'b0) reset_seen = 1;
  always @(posedge clk_i) begin
    if (reset_seen && $isunknown(rst_ni)) $fatal(1, "%m unknown MEM reset");
    if (reset_seen && rst_ni === 1'b1) begin
      if ($isunknown(cmd_valid_i)) $fatal(1, "%m unknown MEM command valid");
      if (cmd_valid_i === 1'b1) begin
        if ($isunknown({cmd_opcode_i,cmd_row_i,cmd_stream_dir_i,cmd_stream_idx_i,cmd_preserve_i}))
          $fatal(1, "%m unknown valid MEM command");
        if (cmd_opcode_i == 3'b001) begin
          if ($isunknown(stream_valid_i)) $fatal(1, "%m unknown MEM segment valid");
          if (stream_valid_i && $isunknown(stream_data_i))
            $fatal(1, "%m unknown valid MEM write payload");
        end
      end
    end
  end
endmodule

module mem_p1_command_checker (
  input logic clk_i, rst_ni, valid_i,
  input logic [31:0] command_i
);
  bit reset_seen = 0;
  always @(negedge rst_ni)
    if (rst_ni === 1'b0) reset_seen = 1;
  always @(posedge clk_i) begin
    if (reset_seen && $isunknown(rst_ni)) $fatal(1, "%m unknown MEM reset");
    if (reset_seen && rst_ni === 1'b1) begin
      if ($isunknown(valid_i)) $fatal(1, "%m unknown MEM command valid");
      if (valid_i === 1'b1 && $isunknown(command_i))
        $fatal(1, "%m unknown valid MEM command");
    end
  end
endmodule
