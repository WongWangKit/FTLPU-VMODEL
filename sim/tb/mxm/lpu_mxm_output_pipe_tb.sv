`timescale 1ns/1ps
// Public ports only. Exercise both formats for every independent vector,
// alternating formats on consecutive cycles with bubbles and a reset flush.
module lpu_mxm_output_pipe_tb;
  localparam integer COUNT=331776,LANES=3;
  logic clk=0,rst_n=0,valid=0,bf16=0;
  logic [LANES*32-1:0] data=0;
  logic [31:0] meta=0;
  wire result_valid,result_bf16;
  wire [LANES*32-1:0] result;
  wire [31:0] result_meta;
  logic [63:0] vectors[0:COUNT-1];
  integer checked=0;
  string path;
  always #5 clk=~clk;
  lpu_mxm_output_pipe #(.LANES(LANES)) dut (
    .clk_i(clk),.rst_ni(rst_n),.valid_i(valid),.bf16_i(bf16),.data_i(data),.meta_i(meta),
    .valid_o(result_valid),.bf16_o(result_bf16),.data_o(result),.meta_o(result_meta));
  initial begin
    if(!$value$plusargs("vectors=%s",path)) $fatal(1,"missing output vectors");
    $readmemh(path,vectors);
    repeat(2) @(negedge clk);rst_n=1;
    for(integer index=0;index<COUNT*2;index++) begin
      @(negedge clk);valid=1;bf16=1'(index%2);meta=32'(index);
      for(integer lane=0;lane<LANES;lane++) data[lane*32+:32]=vectors[(index/2+lane*131)%COUNT][63:32];
      @(posedge clk);#1;
      if(!result_valid || result_bf16!==bf16 || result_meta!==meta) $fatal(1,"output control/latency mismatch");
      for(integer lane=0;lane<LANES;lane++) begin
        logic [31:0] expected;
        expected=bf16?vectors[(index/2+lane*131)%COUNT][31:0]:data[lane*32+:32];
        if(result[lane*32+:32]!==expected) $fatal(1,"output conversion mismatch index=%0d lane=%0d got=%h expected=%h",index,lane,result[lane*32+:32],expected);
        checked=checked+1;
      end
      if(index%127==126) begin
        @(negedge clk);valid=0;
        @(posedge clk);#1;if(result_valid || result_bf16) $fatal(1,"output bubble mismatch");
      end
    end
    @(negedge clk);valid=0;rst_n=0;
    #1;if(result_valid || result_bf16) $fatal(1,"output reset failed");
    @(negedge clk);rst_n=1;
    @(posedge clk);#1;if(result_valid) $fatal(1,"stale output after reset");
    $display("MXM_OUTPUT_PIPE_PASS vectors=%0d formats=2 lanes=%0d checked=%0d common_stages=1",COUNT,LANES,checked);
    $finish;
  end
endmodule
