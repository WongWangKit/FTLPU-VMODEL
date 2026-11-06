`timescale 1ns/1ps
module alu_basic_bf16_tb;
  reg clk_i=0,rst_ni=0,input_valid_i=0;
  always #5 clk_i=~clk_i;
  reg [1:0] data_format_i=0;
  reg [2:0] opcode_i=0;
  reg [31:0] lhs_i=0,rhs_i=0;
  wire input_ready_o,output_valid_o,illegal_opcode_o,unsupported_format_o,result_collision_o,lut_fault_o;
  wire [31:0] result_o;
`ifdef GATE
  fpga_basic_alu_probe dut(
`else
  fpga_basic_alu_probe #(.FIXED_BF16(1)) dut(
`endif
    .clk_i,.rst_ni,.input_valid_i,.data_format_i,.opcode_i,.lhs_i,.rhs_i,
    .lut_configured_i(3'b0),.lut_input_min_i(48'b0),.lut_segment_width_i(48'b0),
    .lut_read_valid_i(1'b0),.lut_read_k_i(16'b0),.lut_read_b_i(16'b0),
    .lut_read_valid_o(),.lut_read_bank_o(),.lut_read_address_o(),
    .input_ready_o,.output_valid_o,.result_o,.illegal_opcode_o,.unsupported_format_o,.result_collision_o,.lut_fault_o);
  integer checks=0;
  task automatic test_op(input [1:0] ignored_format,input [2:0] op,input [31:0] a,b,expected);
    begin
      @(negedge clk_i);data_format_i=ignored_format;opcode_i=op;lhs_i=a;rhs_i=b;input_valid_i=1;
      #1;if(input_ready_o!==1 || illegal_opcode_o!==0 || unsupported_format_o!==0) $fatal(1,"BF16 rejected");
      @(posedge clk_i);#1;
      if(op==3) begin
        if(output_valid_o!==0) $fatal(1,"BF16 multiply early");
        @(negedge clk_i);input_valid_i=0;@(posedge clk_i);#1;
      end
      if(output_valid_o!==1 || result_o!==expected || result_collision_o!==0 || lut_fault_o!==0)
        $fatal(1,"BF16 op=%0d fmt_pin=%0d actual=%h expected=%h",op,ignored_format,result_o,expected);
      @(negedge clk_i);input_valid_i=0;@(posedge clk_i);#1;
      if(output_valid_o!==0) $fatal(1,"duplicate");
      checks++;
    end
  endtask
  initial begin
    #200;@(negedge clk_i);rst_ni=1;
    // Sweep the unused format pin to ensure both unpack and arithmetic are fixed.
    for(integer f=0;f<4;f++) begin
      test_op(f,1,32'h3f80,32'h4000,32'h4040);
      test_op(f,2,32'h3f80,32'h4000,32'hbf80);
      test_op(f,3,32'h3fc0,32'h4000,32'h4040);
      test_op(f,4,32'hbf80,0,32'h3f80);
      test_op(f,5,32'hbf80,0,0);
      test_op(f,0,32'hffff7fc1,0,32'h7fc1);
      test_op(f,1,32'h7fc1,32'h3f80,32'h7fc0);
      test_op(f,3,32'h7f80,0,32'h7fc0);
      test_op(f,1,32'h0001,32'h3f80,32'h3f80);
    end
    @(negedge clk_i);input_valid_i=1;opcode_i=6;#1;
    if(illegal_opcode_o!==1) $fatal(1,"illegal opcode");
    @(negedge clk_i);input_valid_i=0;
    $display("PASS alu_basic_bf16 vectors=%0d fixed_format_all_pin_values",checks);$finish;
  end
  initial begin #10000;$fatal(1,"BF16 timeout");end
endmodule
