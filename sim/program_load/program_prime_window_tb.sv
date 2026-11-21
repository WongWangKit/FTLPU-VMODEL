`timescale 1ns/1ps
module program_prime_window_tb;
  logic clk_i=0,rst_ni=0,prime_i=0,decoder_drained_i=0;
  logic context_fire_i=0,scheduler_ready_i=0,scheduler_blocked_i=0,stream_prefix_i=0;
  logic [31:0] context_cycle_i=0;
  logic tail_o,ready_o,fault_o;
  always #5 clk_i=~clk_i;
  lpu_program_prime_window dut(.*);
  task automatic step(); @(posedge clk_i); @(negedge clk_i); endtask
  task automatic ck(input logic ok,input string msg); if(!ok)$fatal(1,"%s",msg); endtask
  initial begin
    step();rst_ni=1;prime_i=1;
    context_fire_i=1;context_cycle_i=1;step();context_cycle_i=16;step();
    context_fire_i=0; scheduler_blocked_i=1;stream_prefix_i=1;
    step();ck(tail_o && ready_o && !fault_o,"valid bounded prefix not accepted");
    prime_i=0; context_fire_i=1;context_cycle_i=12;
    #1;ck(!fault_o,"fault is not registered");
    step();ck(fault_o && !ready_o,"runtime context inversion escaped");
    rst_ni=0;step();rst_ni=1;prime_i=1;context_fire_i=0;stream_prefix_i=0;
    step();ck(!tail_o && !ready_o && fault_o,"too-early blocked prefix reached START");
    $display("PASS prime window: admissible prefix, registered inversion, unsafe early-prefix rejection");
    $finish;
  end
endmodule
