`timescale 1ns/1ps
module program_mem_native_tb;
logic clk=0,rst=0,run=0,load=0,prime=0,last=0;
always #5 clk=~clk;
logic [16:0] addr=0;
logic [127:0] data=0;
logic load_ready,prime_ready,ready,fault,enqueue,enqueue_ready,issue,qfault;
logic [5:0] code;
logic [31:0] instruction,issued,deadline,issued_cycle,cycle=0,native_word;
logic [287:0] payload;
integer seen=0,ticks=0,mode=0;
lpu_mem_local_imem_frontend #(.IMEM_DEPTH(8)) dut(
 .clk_i(clk),.rst_ni(rst),.program_reset_i(1'b0),.clear_i(1'b0),
 .load_valid_i(load),.load_ready_o(load_ready),.load_address_i(addr),.load_data_i(data),.load_strb_i(4'h7),.load_last_i(last),
 .prime_valid_i(prime),.prime_ready_o(prime_ready),.run_i(run),.schedule_cycle_i(cycle),
 .issue_valid_o(enqueue),.issue_ready_i(enqueue_ready),.issue_instruction_o(instruction),.issue_cycle_o(deadline),
 .configured_o(),.frontend_ready_o(ready),.frontend_idle_o(),.fault_o(fault),.fault_code_o(code));
lpu_mem_bank_queue #(.DEPTH(3)) q(
 .clk_i(clk),.rst_ni(rst),.run_i(run),.schedule_cycle_i(cycle),
 .enqueue_valid_i(enqueue),.enqueue_ready_o(enqueue_ready),.enqueue_instruction_i(instruction),.enqueue_cycle_i(deadline),
 .issue_valid_o(issue),.issue_ready_i(1'b1),.issue_instruction_o(issued),.issue_cycle_o(issued_cycle),.level_o(),.fault_o(qfault));
always @(posedge clk)if(rst)begin
 ticks++;if(ticks>500)$fatal(1,"timeout case=%0d",mode);
 if(mode<3&&(fault||qfault))$fatal(1,"unexpected MEM frontend fault %0d",code);
 if(issue)begin
  if(cycle!=5||issued_cycle!=5||issued!=native_word)$fatal(1,"native32 mismatch %h != %h cycle %0d",issued,native_word,cycle);
  seen++;
 end
end
initial begin
 void'($value$plusargs("CASE=%d",mode));
 native_word=32'h00018138; // row 3, west stream 7, READ
 case(mode)
  1:native_word[30]=1; // three-cycle MEM wave, preserved through extended template
  2:begin native_word[31]=1;native_word[2:0]=1;end
  3:native_word[9]=1; // reserved bit: reject
  4:native_word[2:0]=3; // unsupported old MEM opcode: reject, no translation
  5:native_word[31]=1; // preserve is not legal on READ
 endcase
 payload=0;payload[3+:32]=5;payload[35+:13]=3;
 payload[49]=1;payload[50+:32]=native_word;
 payload[82+:32]=1;payload[114+:32]=1;
 payload[178+:32]=1;payload[210+:32]=1;payload[274+:2]=1;
 repeat(4)@(negedge clk);rst=1;
 for(integer w=0;w<4;w++)begin
  @(negedge clk);load=1;addr=17'(w);last=w==3;
  data=w==0?128'h17:{32'd0,payload[(w-1)*96+:96]};
  do @(posedge clk);while(!load_ready);
 end
 @(negedge clk);load=0;prime=1;
 do @(posedge clk);while(!prime_ready);
 @(negedge clk);prime=0;
 if(mode>=3)begin
  while(!fault)@(negedge clk);
  if(code!=5||dut.frontend_fault_code!=6)$fatal(1,"expected decoder native fault, got %0d/%0d",code,dut.frontend_fault_code);
  if(seen!=0)$fatal(1,"invalid native instruction issued");
 end else begin
  while(!ready)@(negedge clk);
  @(negedge clk);run=1;
  for(integer c=0;c<12;c++)begin cycle=32'(c);@(negedge clk);end
  run=0;if(seen!=1)$fatal(1,"native issue count %0d",seen);
 end
 $display("PASS MEM native32 image case=%0d",mode);$finish;
end
endmodule

