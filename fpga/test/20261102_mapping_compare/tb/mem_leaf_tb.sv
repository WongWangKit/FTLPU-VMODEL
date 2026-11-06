`timescale 1ns/1ps
module mem_leaf_tb;
  reg clk_i=0, rst_ni=0;
  always #5 clk_i=~clk_i;
  reg cmd_valid_i=0;
  reg [2:0] cmd_opcode_i=0;
  reg [14:0] cmd_row_i=0;
  reg cmd_stream_dir_i=0, cmd_preserve_i=0, stream_valid_i=0;
  reg [4:0] cmd_stream_idx_i=0;
  reg [63:0] stream_data_i=0;
  wire stream_consume_o, read_valid_o, read_stream_dir_o, fault_valid_o;
  wire [63:0] read_data_o;
  wire [4:0] read_stream_idx_o;
  wire [1:0] fault_code_o;
`ifdef GATE
  mem_bank_superlane_leaf dut(.*);
`else
  mem_bank_superlane_leaf #(.P_MEM_BANK_DEPTH_ROWS(1024),.P_MEM_ACTIVE_ROWS(1024)) dut(.*);
`endif
  reg [63:0] model [0:1023];
  reg [63:0] expected_data=0;
  reg expected_dir=0;
  reg [4:0] expected_idx=0;
  reg ec,ev,ef;
  reg [1:0] ecode;
  integer checks=0;
  reg [31:0] rng=32'h51a7c0de;
  function automatic [31:0] next_rng(input [31:0] x);
    next_rng=x*32'd1664525+32'd1013904223;
  endfunction
  task automatic step(input bit valid, input [2:0] op, input [14:0] row,
                      input bit preserve, input bit data_valid, input [63:0] data);
    begin
      @(negedge clk_i);
      cmd_valid_i=valid; cmd_opcode_i=op; cmd_row_i=row;
      cmd_preserve_i=preserve; stream_valid_i=data_valid; stream_data_i=data;
      cmd_stream_dir_i=row[0]; cmd_stream_idx_i=row[4:0];
      ec=0; ev=0; ef=0; ecode=0;
      if(valid) begin
        if ((op==0 || op==1) && !(op==0 && preserve) && row>=1024) begin
          ef=1; ecode=1;
        end else if(op==0) begin
          if(preserve) begin ef=1; ecode=2; end
          else begin ev=1; expected_data=model[row]; expected_dir=row[0]; expected_idx=row[4:0]; end
        end else if(op==1) begin
          if(data_valid) begin model[row]=data; ec=!preserve; end
          else if(!preserve) begin ef=1; ecode=3; end
        end else begin ef=1; ecode=1; end
      end
      @(posedge clk_i); #1;
      if ({stream_consume_o,read_valid_o,fault_valid_o,fault_code_o,read_stream_dir_o,read_stream_idx_o,read_data_o}
          !== {ec,ev,ef,ecode,expected_dir,expected_idx,expected_data})
        $fatal(1,"MEM mismatch check=%0d op=%0d row=%0d actual=%h expected=%h",checks,op,row,
          {stream_consume_o,read_valid_o,fault_valid_o,fault_code_o,read_stream_dir_o,read_stream_idx_o,read_data_o},
          {ec,ev,ef,ecode,expected_dir,expected_idx,expected_data});
      checks++;
    end
  endtask
  initial begin
    for(integer i=0;i<1024;i++) model[i]=0;
    // Wait beyond the Xilinx glbl startup/GSR interval.
    #200; @(negedge clk_i); rst_ni=1;
    for(integer i=0;i<1024;i++) step(1,0,i,0,0,0);
    for(integer i=0;i<1024;i++) begin
      rng=next_rng(rng); step(1,1,i,0,1,{rng,~rng});
    end
    for(integer i=0;i<1024;i++) step(1,0,i,0,0,0);
    for(integer i=0;i<256;i++) begin
      rng=next_rng(rng);
      step(1,1,rng[9:0],1,rng[16],{~rng,rng});
      step(1,0,rng[9:0],0,0,0);
    end
    step(1,0,1024,0,0,0); step(1,1,32767,0,1,64'hbad);
    step(1,0,0,1,0,0); step(1,1,0,0,0,0);
    for(integer i=2;i<8;i++) step(1,i,0,0,0,0);
    step(0,0,0,0,0,0);
    @(negedge clk_i); rst_ni=0; cmd_valid_i=0;
    repeat(2) @(negedge clk_i);
    expected_data=0; expected_dir=0; expected_idx=0; rst_ni=1;
    for(integer i=0;i<1024;i++) step(1,0,i,0,0,0);
    $display("PASS mem_leaf checks=%0d cold_zero full_address_random_data preserve faults reset_retention",checks);
    $finish;
  end
  initial begin #100000; $fatal(1,"MEM timeout"); end
endmodule
