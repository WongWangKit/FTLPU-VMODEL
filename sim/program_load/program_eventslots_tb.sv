`timescale 1ns/1ps
module program_eventslots_tb;
 bit clk=0,rst=0,clear=0,v=0,phase=0,ack=0;always #5 clk=~clk;
 bit[63:0] generation=7,source=7;bit[31:0] tag;bit[1:0] mask=1,active=3,waiting=0;
 logic[63:0] tags;logic ready,rv,idle,fault;logic[1:0] fire;logic[63:0] stamp,rg;logic[31:0] returned;
 lpu_qctl_event_buffer #(.N(2),.DEPTH(8)) d(.clk_i(clk),.rst_ni(rst),.clear_i(clear),.generation_i(generation),
 .event_valid_i(v),.event_ready_o(ready),.event_tag_i(tag),.event_generation_i(source),.event_mask_i(mask),.event_phase_i(phase),
 .active_i(active),.wait_i(waiting),.wait_tag_i(tags),.fire_o(fire),.receipt_valid_o(rv),.receipt_ready_i(ack),
 .receipt_tag_o(returned),.receipt_generation_o(rg),.receipt_cycle_o(stamp),.idle_o(idle),.fault_o(fault));
 task automatic send(input int k,input bit[1:0] m,input bit atomic);
  @(negedge clk);v=1;tag=k;mask=m;phase=atomic;do @(posedge clk);while(!ready);@(negedge clk);v=0;
 endtask
 initial begin
  logic[63:0] held;
  repeat(3)@(negedge clk);rst=1;
  for(int i=0;i<8;i++)send(i+20,1,0);
  if(ready||idle)$fatal(1,"overbooked table");
  source=6;send(90,2,1);source=7;#1;if(ready||fault)$fatal(1,"stale generation occupied a slot");
  waiting=1;tags=20;@(posedge clk);if(fire!=1||ready)$fatal(1,"full: borrowed unretired slot");
  @(negedge clk);waiting=0;send(99,2,1);
  for(int i=1;i<8;i++)begin tags=i+20;waiting=1;@(posedge clk);if(fire!=1)$fatal(1,"FIFO order");@(negedge clk);end
  waiting=2;tags={32'd99,32'd0};@(posedge clk);if(fire!=2)$fatal(1,"retry lost");@(negedge clk);waiting=0;
  if(!rv||returned!=99||rg!=7||idle)$fatal(1,"missing first receipt");held=stamp;
  send(100,1,1);waiting=1;tags=100;@(posedge clk);if(fire!=1)$fatal(1,"second receipt");@(negedge clk);waiting=0;
  repeat(3)begin @(posedge clk);if(!rv||returned!=99||stamp!=held)$fatal(1,"stalled receipt changed");end
  @(negedge clk);ack=1;@(posedge clk);@(negedge clk);if(!rv||returned!=100||stamp<=held)$fatal(1,"receipt reorder");@(posedge clk);@(negedge clk);ack=0;
  if(!idle||rv)$fatal(1,"unretired receipt");
  source=8;send(22,1,1);if(!fault||fire)$fatal(1,"future generation");clear=1;@(negedge clk);clear=0;generation=8;source=8;send(22,1,1);
  waiting=1;tags=22;@(posedge clk);if(fire!=1||fault)$fatal(1,"fresh generation after clear");
  $display("PASS 8-slot event table, stale at full, retry, stable ordered receipts, future fault and new epoch");$finish;
 end
 initial begin #4000;$fatal(1,"timeout");end
endmodule
