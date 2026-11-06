`timescale 1ns/1ps
module alu_basic_tb;
  reg clk_i=0,rst_ni=0,input_valid_i=0;
  always #5 clk_i=~clk_i;
  reg [1:0] data_format_i=0;
  reg [2:0] opcode_i=0;
  reg [31:0] lhs_i=0,rhs_i=0;
  wire input_ready_o,output_valid_o,illegal_opcode_o,unsupported_format_o,result_collision_o,lut_fault_o;
  wire [31:0] result_o;
  lpu_vxm_alu dut(.clk_i,.rst_ni,.input_valid_i,.data_format_i,.opcode_i,.lhs_i,.rhs_i,
    .lut_configured_i(3'b0),.lut_input_min_i(48'b0),.lut_segment_width_i(48'b0),
    .lut_read_valid_i(1'b0),.lut_read_k_i(16'b0),.lut_read_b_i(16'b0),
    .lut_read_valid_o(),.lut_read_bank_o(),.lut_read_address_o(),
    .input_ready_o,.output_valid_o,.result_o,.illegal_opcode_o,.unsupported_format_o,.result_collision_o,.lut_fault_o);
  integer checks=0;
  task automatic test_op(input [1:0] fmt,input [2:0] op,input [31:0] a,b,expected);
    integer latency;
    begin
      latency=(op==3)?2:1;
      @(negedge clk_i); data_format_i=fmt;opcode_i=op;lhs_i=a;rhs_i=b;input_valid_i=1;
      #1;
      if(input_ready_o!==1 || illegal_opcode_o!==0 || unsupported_format_o!==0) $fatal(1,"ALU request rejected");
      @(posedge clk_i); #1;
      if(latency==2) begin
        if(output_valid_o!==0) $fatal(1,"multiply early");
        @(negedge clk_i); input_valid_i=0;
        @(posedge clk_i); #1;
      end
      if(output_valid_o!==1 || result_o!==expected || result_collision_o!==0 || lut_fault_o!==0)
        $fatal(1,"ALU mismatch fmt=%0d op=%0d a=%h b=%h actual=%h expected=%h valid=%b",fmt,op,a,b,result_o,expected,output_valid_o);
      @(negedge clk_i);input_valid_i=0;
      @(posedge clk_i); #1;
      if(output_valid_o!==0) $fatal(1,"duplicate result");
      checks++;
    end
  endtask
  initial begin
    #200;@(negedge clk_i);rst_ni=1;
    // Exact bit-pattern oracles; no DUT math functions reused.
    test_op(0,1,32'h3c00,32'h4000,32'h4200);
    test_op(0,2,32'h3c00,32'h4000,32'hbc00);
    test_op(0,3,32'h3e00,32'h4000,32'h4200);
    test_op(0,4,32'h3c00,0,32'hbc00);
    test_op(0,5,32'hbc00,0,0);
    test_op(0,0,32'hffff7e11,0,32'h7e11);
    test_op(1,1,32'h3f80,32'h4000,32'h4040);
    test_op(1,2,32'h3f80,32'h4000,32'hbf80);
    test_op(1,3,32'h3fc0,32'h4000,32'h4040);
    test_op(1,4,32'hbf80,0,32'h3f80);
    test_op(1,5,32'hbf80,0,0);
    test_op(2,1,32'h3f800000,32'h40000000,32'h40400000);
    test_op(2,2,32'h3f800000,32'h40000000,32'hbf800000);
    test_op(2,3,32'h3fc00000,32'h40000000,32'h40400000);
    test_op(2,4,32'hbf800000,0,32'h3f800000);
    test_op(2,5,32'hbf800000,0,0);
    test_op(2,1,32'h7f800000,32'hff800000,32'h7fc00000);
    test_op(0,3,32'h7c00,0,32'h7e00);
    test_op(1,1,32'h7fc1,32'h3f80,32'h7fc0);
    test_op(2,1,32'h00000001,32'h3f800000,32'h3f800000);
    test_op(0,1,32'h00000001,32'h3c00,32'h3c00);
    @(negedge clk_i); input_valid_i=1; data_format_i=3;opcode_i=1; #1;
    if(unsupported_format_o!==1) $fatal(1,"reserved format not rejected");
    @(negedge clk_i);data_format_i=0;opcode_i=6; #1;
    if(illegal_opcode_o!==1) $fatal(1,"unsupported opcode not rejected");
    @(negedge clk_i);input_valid_i=0;
    $display("PASS alu_basic vectors=%0d plus_reserved_format_and_opcode",checks);$finish;
  end
  initial begin #10000;$fatal(1,"ALU timeout");end
endmodule
