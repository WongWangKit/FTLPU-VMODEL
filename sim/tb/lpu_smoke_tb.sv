`timescale 1ns/1ps

module lpu_smoke_tb;
  timeunit 1ns;
  timeprecision 1ps;

  logic clk;
  logic rst_n;

  lpu_top dut (
    .clk_i  (clk),
    .rst_ni (rst_n)
  );

  initial begin
    clk = 1'b0;
    forever #5ns clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);
    $display("FTLPU-VMODEL smoke test passed");
    $finish;
  end
endmodule

