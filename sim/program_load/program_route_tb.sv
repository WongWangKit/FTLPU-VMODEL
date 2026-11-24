`timescale 1ns/1ps
module program_route_tb;
 import lpu_program_load_pkg::*;
 bit clk,rst,valid,wr,er;always #5 clk=~clk;
 logic ready,w,e,idle,fault;logic[5:0] code;logic[1:0] side;logic[3:0] kind;logic[127:0] data,west,east;
 lpu_program_load_distributor dut(.clk_i(clk),.rst_ni(rst),.input_valid_i(valid),.input_ready_o(ready),
 .input_control_i(PROGRAM_LOAD_WRITE),.input_data_i(data),.input_strb_i(4'h7),.input_hemisphere_i(side),
 .input_target_kind_i(kind),.input_queue_id_i(8'd1),.input_imem_address_i(17'd3),.input_last_i(1'b1),
 .west_valid_o(w),.west_ready_i(wr),.west_data_o(west),.east_valid_o(e),.east_ready_i(er),.east_data_o(east),
 .idle_o(idle),.fault_o(fault),.fault_code_o(code));
 int wc=0,ec=0;
 always @(posedge clk)if(rst)begin
   if(w&&wr)begin if(west!==128'h123)$fatal(1,"WEST payload");wc++;end
   if(e&&er)begin if(east!==(ec==0?128'h123:128'h456))$fatal(1,"EAST payload");ec++;end
 end
 task automatic push(input logic[1:0] h,input logic[3:0] k,input logic[127:0] v);
  @(negedge clk);side=h;kind=k;data=v;valid=1;do @(posedge clk);while(!ready);@(negedge clk);valid=0;
 endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;wr=1;er=0;
  push(PROGRAM_HEMISPHERE_BOTH,PROGRAM_TARGET_MEM,128'h123);
  while(wc!=1)@(negedge clk);
  repeat(8)begin @(negedge clk);if(idle||w||!e||east!==128'h123)$fatal(1,"lost or repeated BOTH");end
  er=1;while(!idle)@(negedge clk);
  push(PROGRAM_HEMISPHERE_BOTH,PROGRAM_TARGET_VXM,128'h456);while(!idle)@(negedge clk);
  if(wc!=1||ec!=2||fault)$fatal(1,"central route");
  push(2'b11,PROGRAM_TARGET_VXM,128'h789);repeat(4)@(negedge clk);
  if(!fault||code!=PROGRAM_FAULT_ROUTE||wc!=1||ec!=2||w||e)$fatal(1,"invalid side routed");
  $display("PASS paired MEM branches skew; central VXM exactly once; invalid route zero fires");$finish;
 end
 initial begin #3500;$fatal(1,"timeout");end
endmodule
