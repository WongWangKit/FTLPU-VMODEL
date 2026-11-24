`timescale 1ns/1ps
// Three real iMEM/fetch/decode/scheduler paths followed by real timed queues.
module program_frontends_tb;
logic clk=0,rst=0,run=0,load=0,prime=0,last=0;
always #5 clk=~clk;
logic [16:0] addr=0;
logic [127:0] data[3];
logic [2:0] load_ready,prime_ready,ready,idle,fault,enqueue,enqueue_ready,issue,qfault;
logic [5:0] codes[3];
logic [48:0] insn[3],issued[3];
logic [31:0] deadline[3],issued_cycle[3];
logic [31:0] cycle=0;
integer seen[3]='{0,0,0};
integer ticks=0;
integer mode=0;
localparam logic [48:0] EXPECTED[3]='{49'h8,49'h3f80,49'h100010320001};
localparam integer DUE[3]='{5,2,6};
localparam integer CONTEXTS=24;
localparam logic [127:0] SINGLE_BODY[3]='{
  128'h00000000000000000400000800000028,
  128'h00000000000000000007f00000000010,
  128'h00000060400040000004032000000030};
function automatic logic [255:0] multi_body(input integer k);
  logic [255:0] payload;
  integer state_bits, template_bits, run_at;
  payload='0;
  state_bits=32 + ((k==0)?2:(k==1)?0:13);
  template_bits=(k==0)?34:(k==1)?21:54;
  payload[0+:3]=1;
  payload[3+:22]=12;
  for(integer i=0;i<state_bits;i++) payload[39+i]=SINGLE_BODY[k][3+i];
  payload[39+:32]=1;
  run_at=39+state_bits;
  payload[run_at]=1;
  payload[run_at+1+:16]=16'(CONTEXTS-1);
  for(integer i=0;i<template_bits;i++)
    payload[run_at+17+i]=SINGLE_BODY[k][3+state_bits+1+i];
  return payload;
endfunction
for(genvar k=0;k<3;k++)begin:g
 lpu_mxm_local_imem_frontend #(.TARGET_KIND(k+1),.IMEM_DEPTH(8),.ACTIVE_CONTEXTS(2)) u_frontend(
  .clk_i(clk),.rst_ni(rst),.program_reset_i(1'b0),.clear_i(1'b0),
  .load_valid_i(load),.load_ready_o(load_ready[k]),.load_address_i(addr),.load_data_i(data[k]),.load_strb_i(4'hf),.load_last_i(last),
  .prime_valid_i(prime),.prime_ready_o(prime_ready[k]),.run_i(run),.schedule_cycle_i(cycle),
  .issue_valid_o(enqueue[k]),.issue_ready_i(enqueue_ready[k]),.issue_instruction_o(insn[k]),.issue_cycle_o(deadline[k]),
  .configured_o(),.frontend_ready_o(ready[k]),.frontend_idle_o(idle[k]),.fault_o(fault[k]),.fault_code_o(codes[k]));
 lpu_mxm_issue_queue #(.DEPTH(3)) u_queue(
  .clk_i(clk),.rst_ni(rst),.run_i(run),.schedule_cycle_i(cycle),
  .enqueue_valid_i(enqueue[k]),.enqueue_ready_o(enqueue_ready[k]),.enqueue_instruction_i(insn[k]),.enqueue_cycle_i(deadline[k]),
  .issue_valid_o(issue[k]),.issue_ready_i(1'b1),.issue_instruction_o(issued[k]),.issue_cycle_o(issued_cycle[k]),.level_o(),.fault_o(qfault[k]));
end
always @(posedge clk)if(rst)begin
 if($test$plusargs("TRACE") && ticks<60)$display("EDGE t=%0d run=%b cycle=%0d ready=%b tail=%b next0=%0d next1=%0d valid=%b%b due=%0d look=%0d enq=%b issued=%b",ticks,run,cycle,ready,g[0].u_frontend.gen_load_frontend.u_frontend.prime_tail,g[0].u_frontend.gen_load_frontend.u_frontend.u_scheduler.active_next_cycle_q[0],g[0].u_frontend.gen_load_frontend.u_frontend.u_scheduler.active_next_cycle_q[1],g[0].u_frontend.gen_load_frontend.u_frontend.u_scheduler.active_valid_q[0],g[0].u_frontend.gen_load_frontend.u_frontend.u_scheduler.active_valid_q[1],g[0].u_frontend.gen_load_frontend.u_frontend.u_scheduler.due_count_w,g[0].u_frontend.gen_load_frontend.u_frontend.u_scheduler.lookahead_cycle_w,enqueue,issue);
 ticks++;if(ticks>500)$fatal(1,"frontend timeout");
 for(integer k=0;k<3;k++)begin
  if(fault[k]||qfault[k])$fatal(1,"frontend %0d fault=%0d q=%0b dequant_detail=%0d",k,codes[k],qfault[k],g[1].u_frontend.frontend_fault_code);
  if(issue[k])begin
   if(cycle!=((mode==1)?1+seen[k]*12:DUE[k])||issued_cycle[k]!=cycle||issued[k]!=EXPECTED[k])
    $fatal(1,"frontend %0d cycle=%0d instruction=%h",k,cycle,issued[k]);
   seen[k]++;
  end
 end
end
initial begin
 if ($value$plusargs("CASE=%d",mode)) begin end
 for(integer k=0;k<3;k++)data[k]=(mode==1) ? (128'(CONTEXTS)<<4)|128'h7 : 128'h17;
 repeat(4)@(negedge clk);rst=1;load=1;
 do @(posedge clk);while(!(&load_ready));
 @(negedge clk);addr=1;last=(mode==0);
 for(integer k=0;k<3;k++)data[k]=(mode==1) ? 128'(multi_body(k)) : SINGLE_BODY[k];
 do @(posedge clk);while(!(&load_ready));
 if(mode==1)begin
  @(negedge clk);addr=2;last=1;
  for(integer k=0;k<3;k++)data[k]=128'(multi_body(k)>>128);
  do @(posedge clk);while(!(&load_ready));
 end
 @(negedge clk);load=0;prime=1;
 do @(posedge clk);while(!(&prime_ready));
 @(negedge clk);prime=0;
 // START is sampled on a clock edge; a combinational delta during PRIME is not acceptance.
 do @(posedge clk); while ((&ready) !== 1'b1); @(negedge clk);
 if (mode==1 && (g[0].u_frontend.decoder_done || g[1].u_frontend.decoder_done || g[2].u_frontend.decoder_done))
   $fatal(1,"oversized MXM context window was fully decoded before START");
 run=1;
 for(integer c=0;c<((mode==1)?(12*CONTEXTS+10):12);c++)begin
  cycle=32'(c);@(negedge clk);
  if(c==3)begin
   run=0;repeat(11)@(negedge clk);
   if(issue!=0)$fatal(1,"issue while stopped");run=1;
  end
 end
 run=0;
 for(integer k=0;k<3;k++)if(seen[k]!=((mode==1)?CONTEXTS:1))$fatal(1,"missing/duplicate issue %0d count %0d",k,seen[k]);
 if (!(&idle)) $fatal(1,"frontend did not drain");
 $display("PASS MXM Load/Dequant/Compute: %0d contexts each, cycle-one prime/refill, local-time pause",seen[0]);$finish;
end
endmodule


