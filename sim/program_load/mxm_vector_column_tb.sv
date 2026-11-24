`timescale 1ns/1ps
module mxm_vector_column_tb #(parameter integer BLOCKS=4);
  bit clk=0,rst=0,run=0,cv=0;
  always #5 clk=~clk;
  logic [31:0] cycle=0,n; logic [28:0] native,iw;
  logic ready,iv,fault; logic [3:0] code; logic [31:0] deadline;
  integer seen=0; bit vector_mode;
  lpu_mxm_load_macro_scheduler #(.WEIGHT_BLOCKS(BLOCKS)) dut (
    .clk_i(clk),.rst_ni(rst),.run_i(run),.prime_i(!run),.prime_tail_i(1'b0),.schedule_cycle_i(cycle),
    .context_valid_i(cv),.context_ready_o(ready),.context_instruction_i(native),
    .context_start_cycle_i(12),.context_inner_count_i(n),.context_inner_interval_i(1),
    .context_inner_stride_i(1),.context_outer_count_i(1),.context_outer_interval_i(1),
    .context_outer_stride_i(0),.context_induction_target_i(2'd2),.context_operand_i(2'd0),
    .issue_valid_o(iv),.issue_ready_i(1'b1),.issue_instruction_o(iw),.issue_cycle_o(deadline),
    .fault_o(fault),.fault_code_o(code));
  always @(posedge clk)begin
    if(run)cycle<=cycle+1;
    if(iv && rst)begin
      if(deadline!==12+seen || iw[15:10]!==6'd24 || iw[5]!==vector_mode ||
        iw[4:3]!==(vector_mode?seen/8:seen) || iw[8:6]!==(vector_mode?seen%8:0))
        $fatal(1,"IW mismatch count=%d deadline=%d iw=%h",seen,deadline,iw);
      seen++;
    end
  end
  task automatic check_case(input bit vec,input bit overflow);
    @(negedge clk);rst=0;run=0;cv=0;cycle=0;seen=0;vector_mode=vec;n=BLOCKS*(vec?8:1)+int'(overflow);
    native=(29'd24<<10)|(vec?29'h20:0);
    repeat(3)@(negedge clk);rst=1;cv=1;
    do @(posedge clk);while(!ready);@(negedge clk);cv=0;
    repeat(5)@(negedge clk);
    if(overflow)begin if(!fault || code!==2 || seen!=0)$fatal(1,"column overflow not rejected");end
    else begin run=1;repeat(14+n)@(negedge clk);if(fault || seen!=n)$fatal(1,"missing issue %d/%d",seen,n);end
  endtask
  initial begin check_case(1,0);check_case(1,1);check_case(0,0);check_case(0,1);
    $display("PASS vector/block column sweep, deadlines and one-past-end rejection BLOCKS=%d",BLOCKS);$finish;end
endmodule
