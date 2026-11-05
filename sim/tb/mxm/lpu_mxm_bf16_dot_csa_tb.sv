`timescale 1ns/1ps
module lpu_mxm_bf16_dot_csa_tb;
  parameter integer TERMS=8;
  localparam integer VECTOR_BITS=TERMS*32+33;
  logic clk=0,rst_n=0,valid=0;
  always #5 clk=~clk;
  logic [TERMS*16-1:0] activation='0,weight='0;
  logic [15:0] tag=0;
  wire result_valid,lost;
  wire [31:0] result;
  wire [15:0] result_tag;
  logic [VECTOR_BITS-1:0] vectors[0:8191];
  bit expected_valid[0:20000];
  logic [31:0] expected_result[0:20000];
  logic [15:0] expected_tag[0:20000];
  bit expected_lost[0:20000];
  integer cycle=0,checked=0,count=2048;
  logic [31:0] input_expected;
  logic input_lost;
  string path;
  lpu_mxm_bf16_dot_csa #(.TERMS(TERMS)) dut (
    .clk_i(clk),.rst_ni(rst_n),.valid_i(valid),
    .activation_i(activation),.weight_i(weight),.tag_i(tag),
    .valid_o(result_valid),.result_o(result),.tag_o(result_tag),.alignment_lost_o(lost)
  );
  always @(posedge clk) begin
    if (!rst_n) begin
      cycle=0;
      for(integer i=0;i<=20000;i++) expected_valid[i]=0;
    end else begin
      cycle=cycle+1;
      if(valid) begin
        expected_valid[cycle+8]=1;
        expected_result[cycle+8]=input_expected;
        expected_tag[cycle+8]=tag;
        expected_lost[cycle+8]=input_lost;
      end
      #1;
      if(result_valid !== expected_valid[cycle])
        $fatal(1,"dot K=%0d cycle=%0d valid/latency mismatch",TERMS,cycle);
      if(result_valid) begin
        if(result !== expected_result[cycle] || result_tag !== expected_tag[cycle] || lost !== expected_lost[cycle])
          $fatal(1,"dot K=%0d tag=%0d got=%h expected=%h lost=%b/%b",TERMS,result_tag,result,expected_result[cycle],lost,expected_lost[cycle]);
        checked=checked+1;
      end
    end
  end
  initial begin
    if(!$value$plusargs("vectors=%s",path)) $fatal(1,"missing vectors path");
    if($value$plusargs("count=%d",count)) begin end
    $readmemh(path,vectors,0,count-1);
    repeat(3) @(negedge clk);
    rst_n=1;
    for(integer i=0;i<count;i++) begin
      @(negedge clk);
      if(i%17==4) begin valid=0; @(negedge clk); end
      valid=1;tag=16'(i);
      {activation,weight,input_expected,input_lost}=vectors[i];
    end
    @(negedge clk);valid=0;
    repeat(12) @(negedge clk);
    if(checked!=count) $fatal(1,"dot missing outputs %0d/%0d",checked,count);
    // Reset discards a valid token from the middle of the pipeline.
    valid=1;
    repeat(4) @(negedge clk);
    rst_n=0;valid=0;
    #1;if(result_valid!==0) $fatal(1,"dot valid survived reset");
    repeat(2) @(negedge clk);rst_n=1;
    repeat(12) @(negedge clk);
    $display("MXM_DOT_K%0d_PASS checked=%0d",TERMS,checked);$finish;
  end
  initial begin #500000;$fatal(1,"dot timeout");end
endmodule
