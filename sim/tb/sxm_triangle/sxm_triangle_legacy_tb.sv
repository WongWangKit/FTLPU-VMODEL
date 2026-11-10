`timescale 1ns/1ps
module sxm_triangle_legacy_tb #(parameter integer T=4, PORT_STREAMS=16);
  localparam integer RAW_BITS=((240+8*T*(T<4?5:$clog2(8*T))+8+(T<4?3:$clog2(T)+1)+31)/32)*32;
  reg [RAW_BITS-1:0] raw_t[0:16383],raw_p[0:16383];
  reg [5:0] legacy[0:16383];
  reg [T*PORT_STREAMS-1:0] consumes[0:16383];
  reg [T*PORT_STREAMS*6-1:0] read_sels[0:16383],write_sels[0:16383];
  reg [RAW_BITS-1:0] tcmd=0,pcmd=0;
  reg [5:0] lc=0;
  wire [3:0] compat_fault_o;
  integer compat=0,control_bits;
  reg clk_i=0, rst_ni=0;
  always #5 clk_i=~clk_i;
  reg [255:0] commands[0:16383];
  reg [T*PORT_STREAMS*64-1:0] inputs[0:16383], expected[0:16383];
  reg [T*PORT_STREAMS-1:0] in_valid[0:16383], ex_valid[0:16383];
  reg [15:0] flags[0:16383];
  reg [255:0] cmd=0;
  reg [T*PORT_STREAMS*64-1:0] sr_read_data_i=0;
  reg [T*PORT_STREAMS-1:0] sr_read_valid_i=0;
  wire [T*PORT_STREAMS*6-1:0] sr_read_req_o, sr_write_sel_o;
  wire [T*PORT_STREAMS-1:0] sr_consume_o, sr_write_valid_o;
  wire [T*PORT_STREAMS*64-1:0] sr_write_data_o;
  wire [3:0] fault_o;
  wire busy_o;
  wire typed_fault;
  reg [T*2048-1:0] typed_cap_data=0;
  reg typed_job=0;
  reg [1:0] typed_fmt=0;
  reg [T-1:0] typed_cap_valid=0;
  wire [T-1:0] typed_accept,typed_out_valid,typed_out_fmt;
  wire [T*2048-1:0] typed_out_data;
  wire typed_ready;
  wire [T*24-1:0] typed_lanes;
  wire [T*$clog2(T)-1:0] typed_tiles;
  for(genvar z=0;z<T;z=z+1)begin
    assign typed_tiles[z*$clog2(T)+:$clog2(T)]=$clog2(T)'(z);
    for(genvar l=0;l<8;l=l+1)assign typed_lanes[z*24+l*3+:3]=3'(7-l);
  end
  assign fault_o={3'b0,typed_fault};
  sxm_triangle_compatible_core #(.T(T)) dut(
    .clk_i,.rst_ni,.job_valid_i(typed_job),.mode_i(2'd1),.dtype_i(typed_fmt),.count_i(16'd1),
    .lane_map_i(typed_lanes),.tile_map_i(typed_tiles),.job_ready_o(typed_ready),.cap_valid_i(typed_cap_valid),.cap_lane_valid_i({T*8{1'b1}}),.cap_data_i(typed_cap_data),
    .cap_accept_o(typed_accept),.block_ready_i({T{1'b1}}),.block_valid_o(typed_out_valid),.block_fp32_o(typed_out_fmt),.block_vector_o(),.block_data_o(typed_out_data),
    .block_matrix_o(),.block_column_o(),.busy_o,.fault_o(typed_fault),
    .sr_read_req_o,.sr_read_valid_i,.sr_read_data_i,.sr_consume_o,
    .sr_write_valid_o,.sr_write_sel_o,.sr_write_data_o,
    .compat_t_valid_i(lc[0]),.compat_p_valid_i(lc[1]),.compat_t_family_i(lc[3:2]),.compat_p_family_i(lc[5:4]),
    .compat_t_raw_i(tcmd),.compat_p_raw_i(pcmd),.compat_fault_o);
  integer mixed=0,pass;
  task automatic typed_jobs;
    reg [31:0] want;
    @(negedge clk_i);lc=0;cmd=0;sr_read_valid_i=0;
    for(integer fmt=0;fmt<2;fmt++)begin
      typed_fmt=2'(fmt);typed_job=1;
      #1;if(!typed_ready || (|compat_fault_o))$fatal(1,"typed/legacy handover");
      @(posedge clk_i);#1;@(negedge clk_i);typed_job=0;typed_cap_valid={T{1'b1}};
      for(integer t=0;t<T;t++)for(integer l=0;l<8;l++)typed_cap_data[t*2048+l*32+:32]=32'h41238001+32'(t*8+l);
      #1;if(typed_accept!=={T{1'b1}})$fatal(1,"typed capture after legacy");
      @(posedge clk_i);#1;@(negedge clk_i);typed_cap_valid=0;#1;
      if(typed_out_valid!=={T{1'b1}} || typed_out_fmt!=={T{1'(fmt)}})$fatal(1,"typed output after legacy");
      for(integer t=0;t<T;t++)for(integer l=0;l<8;l++)begin
        want=32'h41238001+32'(t*8+7-l);if(fmt==0)want=want&32'hffff;
        if(typed_out_data[t*2048+l*32+:32]!==want)$fatal(1,"shared storage stale data");
      end
      @(posedge clk_i);#1;@(negedge clk_i);
      if(busy_o || typed_fault || (|compat_fault_o))$fatal(1,"typed drain before legacy");
    end
  endtask
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
    if($value$plusargs("COMPAT=%d",compat) && compat!=0) begin
      $readmemh({path,"/raw_t.hex"},raw_t,0,cycles-1);
      $readmemh({path,"/raw_p.hex"},raw_p,0,cycles-1);
      $readmemh({path,"/legacy.hex"},legacy,0,cycles-1);
      $readmemh({path,"/consume.hex"},consumes,0,cycles-1);
      $readmemh({path,"/read_sel.hex"},read_sels,0,cycles-1);
      $readmemh({path,"/write_sel.hex"},write_sels,0,cycles-1);
    end
    control_bits=$bits(dut.u_legacy.north_q)+$bits(dut.u_legacy.north_valid_q)
      +$bits(dut.u_legacy.rows_q)+$bits(dut.u_legacy.metadata_q)
      +$bits(dut.u_legacy.claimed_q)+$bits(dut.u_legacy.destination_q);
    if(control_bits!=197*(T-1)+(105+$clog2(T))*T) $fatal(1,"compat ledger");
    $display("COMPAT_CONTROL_BITS T=%0d bits=%0d PAYLOAD_ADDED=0",T,control_bits);
    if($value$plusargs("MIX=%d",mixed))begin end
    repeat(2) @(negedge clk_i); rst_ni=1;
    for(pass=0;pass<(mixed!=0?2:1);pass++)begin
      if(pass==1)typed_jobs();
    for(c=0;c<cycles;c=c+1) begin
      @(negedge clk_i); cmd=commands[c]; sr_read_data_i=inputs[c]; sr_read_valid_i=in_valid[c];
      if(compat!=0) begin lc=legacy[c];tcmd=raw_t[c];pcmd=raw_p[c];end
      rst_ni=!flags[c][6]; #1;
      if(compat_fault_o!==flags[c][11:8]) $fatal(1,"C%0d compat fault expected=%h actual=%h",c,flags[c][11:8],compat_fault_o);
      if(compat!=0 && flags[c][7]) begin
        if(sr_consume_o!==consumes[c]) $fatal(1,"C%0d compatibility consume",c);
        for(k=0;k<T*PORT_STREAMS;k=k+1) begin
          if(consumes[c][k] && sr_read_req_o[k*6+:6]!==read_sels[c][k*6+:6]) $fatal(1,"C%0d read selector %0d",c,k);
          if(ex_valid[c][k] && sr_write_sel_o[k*6+:6]!==write_sels[c][k*6+:6]) $fatal(1,"C%0d write selector %0d",c,k);
        end
      end
      if(fault_o!==flags[c][3:0]) $fatal(1,"C%0d fault expected=%h actual=%h",c,flags[c][3:0],fault_o);
      if(sr_write_valid_o!==ex_valid[c]) $fatal(1,"C%0d valid expected=%h actual=%h",c,ex_valid[c],sr_write_valid_o);
      for(k=0;k<T*PORT_STREAMS;k=k+1) if(ex_valid[c][k]) begin
        if(sr_write_data_o[k*64+:64]!==expected[c][k*64+:64])
          $fatal(1,"C%0d slot%0d expected=%h actual=%h",c,k,expected[c][k*64+:64],sr_write_data_o[k*64+:64]);
        segments=segments+1;
      end
      if(!(compat!=0 && flags[c][7])) begin
      if(cmd[136] && !flags[c][1]) begin
        if(sr_consume_o!==in_valid[c]) $fatal(1,"C%0d capture consume",c);
        captures=captures+1;
      end else if(sr_consume_o!=0) $fatal(1,"C%0d invalid consume side effect",c);
      end
      if(fault_o!=0) faults=faults+1;
      @(posedge clk_i); #1;
      if(flags[c][5] && !busy_o) $fatal(1,"C%0d prematurely idle",c);
      if(flags[c][4] && busy_o) $fatal(1,"C%0d not drained",c);
    end
    end
    $display("SXM_TRIANGLE_LEGACY PASS T=%0d cycles=%0d segments=%0d captures=%0d negative_faults=%0d",T,cycles,segments,captures,faults);
    $finish;
  end
endmodule
