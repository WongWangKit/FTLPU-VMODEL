`timescale 1ns/1ps

module mem_p1_active_depth_tb;
  logic clk=0,rst_n=0,valid=0,write=0,bad=0,tap=0,sv=0;
  wire[6:0] rv,fault,consume;
  wire[63:0] data[0:6];
  for(genvar n=0;n<7;n=n+1)begin:gen_active
    localparam integer E=1<<n;
    mem_bank_superlane_leaf #(.P_MEM_BANK_DEPTH_ROWS(64),.P_MEM_ACTIVE_ROWS(E)) dut(
      .clk_i(clk),.rst_ni(rst_n),.cmd_valid_i(valid),.cmd_opcode_i(write?3'd1:3'd0),
      .cmd_row_i(bad?15'(E):15'(E-1)),.cmd_stream_dir_i(1'b0),.cmd_stream_idx_i(5'd0),
      .cmd_preserve_i(tap),.stream_valid_i(sv),.stream_data_i(64'h123456789abcdef0+n),
      .stream_consume_o(consume[n]),.read_valid_o(rv[n]),.read_data_o(data[n]),.fault_valid_o(fault[n]));
  end
  task automatic tick;#3;clk=1;#1;clk=0;#1;endtask
  initial begin
    tick();rst_n=1;valid=1;tick();
    if(rv!==7'h7f || fault)$fatal(1,"active initial valid");
    for(integer n=0;n<7;n=n+1)if(data[n]!==0)$fatal(1,"active cold zero");
    write=1;sv=1;tick();if(consume!==7'h7f || fault)$fatal(1,"active legal write");
    bad=1;sv=0;tap=1;tick();if(fault!==7'h7f || consume || rv)$fatal(1,"active invalid Tap must reject before no-op");
    tap=0;tick();if(fault!==7'h7f || consume || rv)$fatal(1,"active invalid Write must reject");
    rst_n=0;tick();rst_n=1;bad=0;write=0;tick();
    for(integer n=0;n<7;n=n+1)if(data[n]!==64'h123456789abcdef0+n)$fatal(1,"active reset/alias E=%0d",1<<n);
    $display("MEM_ACTIVE_DEPTH TEST_PASS E=1,2,4,8,16,32,64 power_of_two_only=1");$finish;
  end
endmodule
