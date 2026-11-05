`timescale 1ns/1ps
module lpu_mxm_fp32_add_pipe_tb;
  logic clk=0,rst_n=0,valid=0;
  always #5 clk=~clk;
  logic [31:0] lhs=0,rhs=0,input_expected=0;
  logic [15:0] tag=0;
  wire result_valid;
  wire [31:0] result;
  wire [15:0] result_tag;
  logic [95:0] vectors[0:8191];
  bit expected_valid[0:20000];
  logic [31:0] expected_result[0:20000];
  logic [15:0] expected_tag[0:20000];
  integer cycle=0,checked=0,count=4096;
  string path;
  lpu_mxm_fp32_add_pipe dut (
    .clk_i(clk),.rst_ni(rst_n),.valid_i(valid),.lhs_i(lhs),.rhs_i(rhs),.tag_i(tag),
    .valid_o(result_valid),.result_o(result),.tag_o(result_tag)
  );
  always @(posedge clk) begin
    if(!rst_n) begin
      cycle=0;
      for(integer i=0;i<=20000;i++) expected_valid[i]=0;
    end else begin
      cycle=cycle+1;
      if(valid) begin
        expected_valid[cycle+2]=1;
        expected_result[cycle+2]=input_expected;
        expected_tag[cycle+2]=tag;
      end
      #1;
      if(result_valid !== expected_valid[cycle]) $fatal(1,"FP32 adder latency mismatch");
      if(result_valid) begin
        if(result !== expected_result[cycle] || result_tag !== expected_tag[cycle])
          $fatal(1,"FP32 tag=%0d got=%h expected=%h",result_tag,result,expected_result[cycle]);
        checked=checked+1;
      end
    end
  end
  initial begin
    if(!$value$plusargs("vectors=%s",path)) $fatal(1,"missing vectors path");
    if($value$plusargs("count=%d",count)) begin end
    $readmemh(path,vectors,0,count-1);
    repeat(3) @(negedge clk);rst_n=1;
    for(integer i=0;i<count;i++) begin
      @(negedge clk);
      if(i%19==3) begin valid=0; @(negedge clk);end
      valid=1;tag=16'(i);{lhs,rhs,input_expected}=vectors[i];
    end
    @(negedge clk);valid=0;
    repeat(6) @(negedge clk);
    if(checked!=count) $fatal(1,"adder missing outputs");
    valid=1;@(negedge clk);rst_n=0;valid=0;
    #1;if(result_valid!==0) $fatal(1,"adder valid survived reset");
    repeat(2) @(negedge clk);rst_n=1;
    repeat(6) @(negedge clk);
    $display("MXM_FP32_ADD_PASS checked=%0d",checked);$finish;
  end
  initial begin #800000;$fatal(1,"adder timeout");end
endmodule
