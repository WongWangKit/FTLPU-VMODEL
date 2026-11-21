`timescale 1ns/1ps
// Real program endpoint -> iMEM -> timed queue -> native MEM/SRF.
// DMA transport/control are verified separately; this is not a full-SoC TB.
module program_mem_subsystem_tb;
import lpu_program_load_pkg::*;
logic clk=0,rst=0,run=0,pvalid=0,pready,perror,plast=0;
always #5 clk=~clk;
logic [31:0] cycle=0;
logic [2:0] control=0;
logic [7:0] queue_id=0;
logic [16:0] address=0;
logic [127:0] data=0;
logic [103:0] issue_valid,mem_fault;
logic [104*32-1:0] instruction,issue_cycle;
logic ready,idle,frontend_fault,conflict;
logic [5:0] code;
integer ticks=0,seen0=0,seen1=0,produced=0;
lpu_mem_subsystem #(.IMEM_DEPTH(8),.DEPTH_ROWS(32),.ACTIVE_COLUMNS(4)) dut(
 .clk_i(clk),.rst_ni(rst),.program_reset_i(1'b0),.run_i(run),.schedule_cycle_i(cycle),
 .qctl_active_i('0),.qctl_scheduler_enable_i('0),.qctl_schedule_cycle_i('0),
 .program_valid_i(pvalid),.program_ready_o(pready),.program_control_i(control),.program_queue_id_i(queue_id),
 .program_address_i(address),.program_data_i(data),.program_strb_i(4'h7),.program_last_i(plast),.program_error_o(perror),
 .local_issue_valid_o(issue_valid),.local_issue_instruction_o(instruction),.local_issue_cycle_o(issue_cycle),
 .frontends_ready_o(ready),.frontends_idle_o(idle),.frontend_fault_o(frontend_fault),.frontend_fault_code_o(code),
 .east_edge_valid_i('0),.east_edge_data_i('0),.east_edge_valid_o(),.east_edge_data_o(),
 .west_edge_valid_i('0),.west_edge_data_i('0),.west_edge_valid_o(),.west_edge_data_o(),
 .mem_fault_o(mem_fault),.conflict_o(conflict));
function automatic logic [383:0] image(input logic [31:0] native_word);
 logic [287:0] p;
 p=0;p[3+:32]=5;p[35+:13]=native_word[27:15];p[49]=1;p[50+:32]=native_word;
 p[82+:32]=1;p[114+:32]=1;p[178+:32]=1;p[210+:32]=1;p[274+:2]=1;
 return {p,96'h17};
endfunction
task automatic load_image(input logic [7:0] q,input logic [31:0] word);
 logic [383:0] img;
 img=image(word);
 for(integer w=0;w<4;w++)begin
  @(negedge clk);pvalid=1;control=PROGRAM_LOAD_WRITE;queue_id=q;address=17'(w);data={32'd0,img[w*96+:96]};plast=w==3;
  do @(posedge clk);while(!pready);
  if(perror)$fatal(1,"valid image rejected");
 end
 @(negedge clk);pvalid=0;
 @(negedge clk);pvalid=1;control=PROGRAM_LOAD_PRIME;
 do @(posedge clk);while(!pready);
 if(perror)$fatal(1,"PRIME rejected");
 @(negedge clk);pvalid=0;
endtask
always @(posedge clk)if(rst)begin
 ticks++;if(ticks>500)$fatal(1,"MEM subsystem timeout");
 if(frontend_fault||(|mem_fault)||conflict)$fatal(1,"MEM subsystem fault code=%0d banks=%h conflict=%b",code,mem_fault,conflict);
 if(issue_valid[0])begin
  if(cycle!=5||instruction[0+:32]!=32'h00018000)$fatal(1,"short MEM issue");seen0++;
 end
 if(issue_valid[1])begin
  if(cycle!=5||instruction[32+:32]!=32'h40020008)$fatal(1,"long MEM issue");seen1++;
 end
 produced+=$countones(dut.u_native_mem.mem_producer_valid_o);
end
initial begin
 repeat(4)@(negedge clk);rst=1;
 // Inactive bank IDs must be consumed with an error, never silently alias.
 @(negedge clk);pvalid=1;control=PROGRAM_LOAD_WRITE;queue_id=8;
 @(posedge clk);if(!pready||!perror)$fatal(1,"inactive bank not rejected");
 @(negedge clk);pvalid=0;
 load_image(0,32'h00018000);load_image(1,32'h40020008);
 while(!ready)@(negedge clk);
 repeat(5)@(negedge clk);if(issue_valid!=0)$fatal(1,"issue before RUN");
 run=1;
 for(integer c=0;c<30;c++)begin cycle=32'(c);@(negedge clk);end
 if(seen0!=1||seen1!=1||produced!=8||!idle)$fatal(1,"MEM conservation short=%0d long=%0d produced=%0d idle=%b",seen0,seen1,produced,idle);
 $display("PASS MEM subsystem: two program images, native short/long waves, eight tile read responses, inactive-bank rejection");$finish;
end
endmodule
