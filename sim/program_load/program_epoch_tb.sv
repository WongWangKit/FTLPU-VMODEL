`timescale 1ns/1ps
module program_epoch_tb;
  logic clk_i=0,rst_ni=0;
  always #5 clk_i=~clk_i;
  logic reload_valid_i=0,reload_ready_o,reload_ack_o,load_fire_i=0,start_fire_i=0;
  logic load_complete_i=0,segment_done_i=0,fault_i=0,axi_idle_i=1,execution_drained_i=1;
  logic admit_o,cancel_transport_o,cancel_valid_i=0,cancel_ready_o;
  lpu_program_epoch_control dut(.*);
  task automatic step(); @(posedge clk_i); @(negedge clk_i); endtask
  task automatic ck(input logic ok,input string name); if(!ok)$fatal(1,"%s",name); endtask
  initial begin
    step();rst_ni=1;step();
    ck(admit_o && reload_ready_o,"cold start not admitted");
    load_fire_i=1;axi_idle_i=0;step();load_fire_i=0;
    fault_i=1;step();
    ck(cancel_transport_o && !admit_o,"faulted transport still admitting");
    reload_valid_i=1;step();reload_valid_i=0;
    repeat(5)begin step();ck(!reload_ack_o && !admit_o,"prestart fault returned before AXI drain");end
    axi_idle_i=1;step();ck(reload_ack_o && !admit_o,"prestart recovery after AXI drain");
    fault_i=0;step();ck(admit_o && !cancel_transport_o,"old cancellation leaked into new epoch");
    load_fire_i=1;step();load_fire_i=0;
    load_complete_i=1;start_fire_i=1;execution_drained_i=0;step();start_fire_i=0;
    reload_valid_i=1;step();reload_valid_i=0;
    segment_done_i=1;
    repeat(3)begin step();ck(!reload_ack_o,"ack before active data drained");end
    execution_drained_i=1;step();ck(reload_ack_o,"drained epoch did not retire");
    segment_done_i=0;load_complete_i=0;step();
    load_fire_i=1;step();load_fire_i=0;
    load_complete_i=1;start_fire_i=1;step();start_fire_i=0;
    fault_i=1;step();reload_valid_i=1;step();reload_valid_i=0;
    segment_done_i=1;
    repeat(8)begin step();ck(!reload_ack_o && !admit_o,"active execution fault falsely recovered");end
    $display("PASS epoch: prestart AXI drain, active FU drain, fatal execution quarantine");
    $finish;
  end
endmodule
