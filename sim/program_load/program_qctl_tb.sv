`timescale 1ns/1ps
module program_qctl_tb;
import lpu_program_load_pkg::*;
localparam QUEUE_COUNT=2, POOL_DEPTH=8, QUEUE_ENTRY_LIMIT=4;
localparam QUEUE_ID_WIDTH=1, POOL_ADDRESS_WIDTH=3, ENTRY_COUNT_WIDTH=3, GENERATION_WIDTH=64;
logic clk_i;
logic rst_ni;
logic clear_i;
logic run_i;
logic load_mode_i;
logic partition_valid_i;
logic partition_ready_o;
logic [QUEUE_ID_WIDTH-1:0] partition_queue_i;
logic [POOL_ADDRESS_WIDTH-1:0] partition_base_i;
logic [ENTRY_COUNT_WIDTH-1:0] partition_count_i;
logic [GENERATION_WIDTH-1:0] partition_generation_i;
logic load_valid_i;
logic load_ready_o;
logic [POOL_ADDRESS_WIDTH-1:0] load_address_i;
logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] load_data_i;
logic event_valid_i;
	logic event_ready_o;
	logic [31:0] event_tag_i;
	logic [QUEUE_COUNT-1:0] event_mask_i;
	logic [GENERATION_WIDTH-1:0] event_generation_i;
	logic event_phase_i;
	logic receipt_valid_o;
	logic receipt_ready_i;
	logic [31:0] receipt_tag_o;
	logic [GENERATION_WIDTH-1:0] receipt_generation_o;
	logic [63:0] receipt_cycle_o;
logic [QUEUE_COUNT-1:0] sync_valid_i;
logic [QUEUE_COUNT-1:0] sync_ready_o;
logic [QUEUE_COUNT-1:0] notify_valid_o;
logic [QUEUE_COUNT-1:0] notify_ready_i;
logic [QUEUE_COUNT-1:0] mem_packet_valid_o;
logic [QUEUE_COUNT*lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] mem_packet_ordinal_o;
logic [QUEUE_COUNT-1:0] mem_packet_retired_i;
logic [QUEUE_COUNT-1:0] queue_active_o;
logic [QUEUE_COUNT-1:0] scheduler_enable_o;
logic [QUEUE_COUNT*lpu_qctl_pkg::QCTL_CYCLE_WIDTH-1:0] queue_cycle_o;
logic [QUEUE_COUNT-1:0] wait_event_blocked_o;
logic [QUEUE_COUNT*lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] wait_event_tag_o;
logic [QUEUE_COUNT-1:0] primed_o;
logic [QUEUE_COUNT-1:0] done_o;
logic all_primed_o;
logic all_done_o;
logic fault_o;
logic [7:0] fault_code_o;
lpu_qctl_fabric #(
.QUEUE_COUNT(2),.POOL_DEPTH(8),.QUEUE_ENTRY_LIMIT(4),.CACHE_DEPTH(4),.READ_LATENCY(2)
) dut (.*);
initial clk_i=0; always #5 clk_i=~clk_i;

import lpu_qctl_pkg::*;
integer cycles=0;
integer phase=0;
task automatic ck(input logic ok,input string s);if(!ok)$fatal(1,"%s cycle=%0d fault=%0d",s,cycles,fault_code_o);endtask
always @(posedge clk_i) if(rst_ni)begin
 cycles++;ck(cycles<1000,"timeout");ck(!fault_o,"QCTL fault");
 if(cycles%100==0)$display("QCTL progress phase=%0d run=%b prime=%b clock=%d wait=%b notify=%b packet=%b done=%b",phase,run_i,primed_o,queue_cycle_o[31:0],wait_event_blocked_o,notify_valid_o,mem_packet_valid_o,done_o);
 if(event_valid_i)$display("EVENT ready=%b tag=%0d expected=%0d",event_ready_o,event_tag_i[31:0],wait_event_tag_o[31:0]);
end
task automatic rec(input integer addr,cyc,op,operand);
 @(negedge clk_i);load_valid_i=1;load_address_i=3'(addr);load_data_i=qctl_pack_record(32'(cyc),4'(op),32'(operand));
 do @(posedge clk_i);while(!load_ready_o);
 @(negedge clk_i);load_valid_i=0;
endtask
initial begin
rst_ni='0;
clear_i='0;
run_i='0;
load_mode_i='0;
partition_valid_i='0;
partition_queue_i='0;
partition_base_i='0;
partition_count_i='0;
partition_generation_i='0;
load_valid_i='0;
load_address_i='0;
load_data_i='0;
event_valid_i='0;event_mask_i=1;event_generation_i=1;event_phase_i=0;receipt_ready_i=1;
event_tag_i='0;
sync_valid_i='0;
notify_ready_i='0;
mem_packet_retired_i='0;

 repeat(4)@(negedge clk_i);rst_ni=1;load_mode_i=1;
 partition_valid_i=1;partition_queue_i=0;partition_base_i=0;partition_count_i=4;partition_generation_i=1;
 do @(posedge clk_i);while(!partition_ready_o);
 @(negedge clk_i);partition_valid_i=0;
 rec(0,0,QCTL_OPCODE_WAIT_EVENT,55);
 rec(1,1,QCTL_OPCODE_NOTIFY,0);
 rec(2,2,QCTL_OPCODE_SYNC,0);
 rec(3,3,QCTL_OPCODE_MEM_PACKET,9);
 @(negedge clk_i);load_mode_i=0;
 while(!(all_primed_o)) @(negedge clk_i);@(negedge clk_i);run_i=1;
 phase=1;
 while(!(wait_event_blocked_o[0])) @(negedge clk_i);repeat(5)@(negedge clk_i);
 ck(queue_cycle_o[31:0]==0&&!scheduler_enable_o[0]&&wait_event_tag_o[31:0]==55,"WAIT_EVENT freezes local time");
 event_valid_i=1;event_generation_i=0;event_mask_i=1;event_tag_i[31:0]=99;
 phase=2;
 do @(posedge clk_i);while(!event_ready_o);
 @(negedge clk_i);event_valid_i=0;
 repeat(5)@(negedge clk_i);ck(wait_event_blocked_o[0],"wrong tag must not release");
 event_valid_i=1;event_generation_i=1;event_mask_i=1;event_tag_i[31:0]=55;
 phase=3;
 do @(posedge clk_i);while(!event_ready_o);
 @(negedge clk_i);event_valid_i=0;
 while(!(notify_valid_o[0])) @(negedge clk_i);repeat(5)@(negedge clk_i);
 phase=4;
 ck(queue_cycle_o[31:0]==1&&notify_valid_o[0],"NOTIFY waits for acceptance");
 notify_ready_i=1;@(negedge clk_i);notify_ready_i=0;
 while(!(queue_cycle_o[31:0]==2)) @(negedge clk_i);repeat(5)@(negedge clk_i);
 ck(queue_cycle_o[31:0]==2&&!scheduler_enable_o[0],"SYNC waits for token");
 sync_valid_i=1;do @(posedge clk_i);while(!sync_ready_o[0]);
 @(negedge clk_i);sync_valid_i=0;
 while(!(mem_packet_valid_o[0])) @(negedge clk_i);repeat(5)@(negedge clk_i);
 ck(queue_cycle_o[31:0]==3&&mem_packet_ordinal_o[31:0]==9,"MEM_PACKET waits for retirement");
 mem_packet_retired_i=1;@(negedge clk_i);mem_packet_retired_i=0;
 while(!(all_done_o)) @(negedge clk_i);@(negedge clk_i);ck(queue_active_o==1&&!fault_o,"completion");
 // Rebind both real controllers to a fresh epoch. B waits two cycles after A.
 @(negedge clk_i);run_i=0;clear_i=1;@(negedge clk_i);clear_i=0;load_mode_i=1;
 for(int q=0;q<2;q++)begin
   partition_valid_i=1;partition_queue_i=q;partition_base_i=q;partition_count_i=1;partition_generation_i=42;
   do @(posedge clk_i);while(!partition_ready_o);
   @(negedge clk_i);partition_valid_i=0;rec(q,q*2,QCTL_OPCODE_WAIT_EVENT,55);
 end
 @(negedge clk_i);load_mode_i=0;while(!all_primed_o)@(negedge clk_i);
 event_mask_i=3;event_tag_i=55;event_phase_i=1;event_generation_i=41;event_valid_i=1;
 @(posedge clk_i);ck(event_ready_o,"stale input was not discarded");@(negedge clk_i);event_valid_i=0;run_i=1;
 repeat(3)begin @(posedge clk_i);ck(dut.selected_fire==0,"stale same tag released");end
 @(negedge clk_i);event_valid_i=1;event_generation_i=42;
 @(posedge clk_i);ck(event_ready_o,"phase enqueue");@(negedge clk_i);event_valid_i=0;receipt_ready_i=0;
 @(posedge clk_i);ck(dut.selected_fire===2'b11 && scheduler_enable_o===2'b11,"partial phase or extra token edge");
 @(negedge clk_i);ck(done_o==3 && !all_done_o && receipt_valid_o && receipt_generation_o==42 && receipt_tag_o==55,"missing physical fire receipt");
 begin logic[63:0] stamp;stamp=receipt_cycle_o;repeat(4)begin @(negedge clk_i);ck(receipt_valid_o && receipt_cycle_o==stamp && dut.selected_fire==0,"unstable or duplicated fire");end end
 receipt_ready_i=1;@(negedge clk_i);ck(!receipt_valid_o && all_done_o,"receipt slot not reclaimed");
 // Selected current-generation wrong tag MUST prevent a younger match for that target.
 run_i=0;clear_i=1;@(negedge clk_i);clear_i=0;load_mode_i=1;partition_valid_i=1;partition_queue_i=0;partition_base_i=0;partition_count_i=1;partition_generation_i=43;
 do @(posedge clk_i);while(!partition_ready_o);@(negedge clk_i);partition_valid_i=0;rec(0,0,QCTL_OPCODE_WAIT_EVENT,55);
 load_mode_i=0;while(!all_primed_o)@(negedge clk_i);
 event_phase_i=0;event_generation_i=43;event_mask_i=1;event_valid_i=1;event_tag_i=99;
 @(posedge clk_i);ck(event_ready_o,"HOL setup");@(negedge clk_i);event_tag_i=55;
 @(posedge clk_i);ck(event_ready_o,"HOL second");@(negedge clk_i);event_valid_i=0;run_i=1;
 repeat(8)begin @(posedge clk_i);ck(wait_event_blocked_o[0] && !dut.selected_fire && !scheduler_enable_o[0],"young matching tag bypassed wrong-tag head");end
 $display("PASS QCTL shared pool, prime, WAIT_EVENT/NOTIFY/SYNC/MEM_PACKET");$finish;
end
endmodule


