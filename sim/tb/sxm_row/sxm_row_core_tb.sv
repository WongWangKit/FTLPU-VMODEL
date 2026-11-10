`timescale 1ns/1ps
module sxm_row_core_tb #(parameter integer T=4);
  reg clk_i=0, rst_ni=0;
  always #5 clk_i=~clk_i;
  reg [255:0] commands[0:16383];
  reg [T*1024-1:0] inputs[0:16383], expected[0:16383];
  reg [T*16-1:0] in_valid[0:16383], ex_valid[0:16383];
  reg [7:0] flags[0:16383];
  reg [255:0] cmd=0;
  reg [T*1024-1:0] sr_read_data_i=0;
  reg [T*16-1:0] sr_read_valid_i=0;
  wire [T*96-1:0] sr_read_req_o, sr_write_sel_o;
  wire [T*16-1:0] sr_consume_o, sr_write_valid_o;
  wire [T*1024-1:0] sr_write_data_o;
  wire [3:0] fault_o;
  wire busy_o;
  sxm_row_core #(.T(T)) dut(
    .clk_i,.rst_ni,.ctrl_valid_i(cmd[0]),.ctrl_op_i(cmd[2:1]),.ctrl_ctx_i(cmd[3]),
    .ctrl_index_i(cmd[6:4]),.ctrl_data_i(cmd[135:8]),
    .cap_valid_i(cmd[136]),.cap_ctx_i(cmd[137]),.cap_tile_i(cmd[140:138]),
    .cap_group_i(cmd[143:141]),.cap_row_i(cmd[147:144]),
    .p_valid_i(cmd[148]),.p_ctx_i(cmd[149]),.p_dest_i(cmd[152:150]),.p_source_i(cmd[155:153]),
    .p_row_i(cmd[159:156]),.p_paired_i(cmd[160]),.p_branch_i(cmd[161]),.p_sequence_i(cmd[167:162]),
    .run_valid_i(cmd[168+:T]),.run_ctx_i(cmd[176]),.run_delay_i(cmd[192:177]),
    .run_interval_i(cmd[208:193]),.run_count_i(cmd[214:209]),.run_sequence_i(cmd[220:215]),
    .sr_read_req_o,.sr_read_valid_i,.sr_read_data_i,.sr_consume_o,
    .sr_write_valid_o,.sr_write_sel_o,.sr_write_data_o,.fault_o,.busy_o,
    .compat_write_rows_i('0),.compat_write_data_i('0),.compat_read_data_o());
  string path;
  integer cycles,c,k,segments=0,captures=0,faults=0;
  initial begin
    if(!$value$plusargs("CASE=%s",path) || !$value$plusargs("CYCLES=%d",cycles)) $fatal(1,"case arguments");
    $readmemh({path,"/cmd.hex"},commands,0,cycles-1);
    $readmemh({path,"/input.hex"},inputs,0,cycles-1);
    $readmemh({path,"/input_valid.hex"},in_valid,0,cycles-1);
    $readmemh({path,"/output.hex"},expected,0,cycles-1);
    $readmemh({path,"/output_valid.hex"},ex_valid,0,cycles-1);
    $readmemh({path,"/flags.hex"},flags,0,cycles-1);
    repeat(2) @(negedge clk_i); rst_ni=1;
    for(c=0;c<cycles;c=c+1) begin
      @(negedge clk_i); cmd=commands[c]; sr_read_data_i=inputs[c]; sr_read_valid_i=in_valid[c]; #1;
      if(fault_o!==flags[c][3:0]) $fatal(1,"C%0d fault expected=%h actual=%h",c,flags[c][3:0],fault_o);
      if(sr_write_valid_o!==ex_valid[c]) $fatal(1,"C%0d valid expected=%h actual=%h",c,ex_valid[c],sr_write_valid_o);
      for(k=0;k<T*16;k=k+1) if(ex_valid[c][k]) begin
        if(sr_write_data_o[k*64+:64]!==expected[c][k*64+:64])
          $fatal(1,"C%0d slot%0d expected=%h actual=%h",c,k,expected[c][k*64+:64],sr_write_data_o[k*64+:64]);
        segments=segments+1;
      end
      if(cmd[136] && !flags[c][1]) begin
        if(sr_consume_o!==in_valid[c]) $fatal(1,"C%0d capture consume",c);
        captures=captures+1;
      end else if(sr_consume_o!=0) $fatal(1,"C%0d invalid consume side effect",c);
      if(fault_o!=0) faults=faults+1;
      @(posedge clk_i); #1;
      if(flags[c][4] && busy_o) $fatal(1,"C%0d not drained",c);
    end
    $display("SXM_ROW_CORE PASS T=%0d cycles=%0d segments=%0d captures=%0d negative_faults=%0d",T,cycles,segments,captures,faults);
    $finish;
  end
endmodule
