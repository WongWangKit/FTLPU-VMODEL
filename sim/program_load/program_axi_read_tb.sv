`timescale 1ns/1ps
module program_axi_read_tb;
  logic clk_i=0,rst_ni=0,cancel_i=0;
  always #5 clk_i=~clk_i;
  logic command_valid_i=0,command_ready_o;
  logic [63:0] command_address_i=0,araddr_o;
  logic [31:0] command_length_i=0,response_keep_o;
  logic [7:0] command_id_i=8'h6a,arid_o,arlen_o,rid_i=0,response_id_o;
  logic [2:0] arsize_o;
  logic [1:0] arburst_o,rresp_i=0;
  logic arvalid_o,arready_i=0,rvalid_i=0,rready_o,rlast_i=0;
  logic response_valid_o,response_ready_i=0,response_last_o,response_error_o;
  logic [255:0] response_data_o,rdata_i=0;
  logic idle_o,protocol_error_o;
  lpu_program_axi_read dut(.*);
  task automatic ck(input logic ok, input string why);
    if (!ok) $fatal(1,"%s",why);
  endtask
  task automatic command(input logic [63:0] address,input logic [31:0] length);
    command_valid_i=1;command_address_i=address;command_length_i=length;
    do @(posedge clk_i); while(!command_ready_o);
    @(negedge clk_i);command_valid_i=0;
  endtask
  task automatic ar(input logic [63:0] address);
    repeat(4)begin
      ck(arvalid_o && araddr_o==address && arid_o==command_id_i &&
         arlen_o==0 && arsize_o==5 && arburst_o==1,"AR stable under stall");
      @(negedge clk_i);
    end
    arready_i=1;
    @(posedge clk_i);@(negedge clk_i);arready_i=0;
    ck(rready_o,"storage not reserved on accepted AR");
  endtask
  task automatic r(input logic [7:0] id,input logic last,input logic [1:0] resp);
    repeat(3)@(negedge clk_i);
    for(integer i=0;i<32;i++)rdata_i[i*8+:8]=8'(i+128);
    rid_i=id;rlast_i=last;rresp_i=resp;rvalid_i=1;
    do @(posedge clk_i);while(!rready_o);
    @(negedge clk_i);rvalid_i=0;
  endtask
  task automatic out_rsp(input integer offset,input integer count,input logic last,err);
    logic [31:0] mask;
    mask=32'hffffffff>>(32-count);
    repeat(4)begin
      ck(response_valid_o && response_id_o==command_id_i &&
         response_keep_o==mask && response_last_o==last && response_error_o==err &&
         !arvalid_o && !rready_o,"response framing or storage under stall");
      for(integer i=0;i<count;i++)ck(response_data_o[i*8+:8]==8'(128+offset+i),"byte shift");
      @(negedge clk_i);
    end
    response_ready_i=1;
    @(posedge clk_i);@(negedge clk_i);response_ready_i=0;
  endtask
  initial begin
    repeat(4)@(negedge clk_i);rst_ni=1;
    command(64'hffd,37);
    ar(64'hfe0);r(command_id_i,1,0);out_rsp(29,3,0,0);
    ar(64'h1000);r(command_id_i,1,0);out_rsp(0,32,0,0);
    ar(64'h1020);r(command_id_i,1,0);out_rsp(0,2,1,0);
    ck(idle_o,"normal range did not drain");
    command(64'h2020,110);cancel_i=1;
    @(negedge clk_i);cancel_i=0;
    ar(64'h2020);r(command_id_i,1,0);
    ck(idle_o && !response_valid_o,"cancel revoked an AXI obligation or leaked data");
    @(negedge clk_i);
    command(64'h3030,128);ar(64'h3020);r(command_id_i,1,2);
    out_rsp(16,16,1,1);
    ck(idle_o,"SLVERR did not terminate the private command");
    command(64'h4000,32);ar(64'h4000);r(8'hff,1,0);
    ck(protocol_error_o && !idle_o && !response_valid_o,"foreign RID retired the transaction");
    cancel_i=1;r(command_id_i,0,0);
    ck(!idle_o && rready_o,"missing RLAST released the slot");
    r(command_id_i,1,0);cancel_i=0;
    ck(idle_o && !response_valid_o,"bad-response drainage failed");
    @(negedge clk_i);
    command(64'hfffffffffffffff0,32);
    ck(response_valid_o && response_error_o && response_last_o && !arvalid_o,"range overflow published AR");
    response_ready_i=1;@(posedge clk_i);@(negedge clk_i);
    ck(idle_o,"range overflow did not retire");
    $display("PASS program AXI: unaligned 4KiB, stable stall, cancel, SLVERR, RID/RLAST drain and overflow");
    $finish;
  end
  initial begin repeat(800)@(posedge clk_i);$fatal(1,"AXI test timeout");end
endmodule
