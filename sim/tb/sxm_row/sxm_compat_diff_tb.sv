`timescale 1ns/1ps
module sxm_compat_diff_tb #(parameter integer T=4);
  localparam integer RAW_BITS=((240+8*T*(T<4?5:$clog2(8*T))+8+(T<4?3:$clog2(T)+1)+31)/32)*32;
  reg [RAW_BITS-1:0] raw_t[0:16383],raw_p[0:16383];
  reg [5:0] legacy[0:16383];
  reg [T*16-1:0] consumes[0:16383];
  reg [T*96-1:0] read_sels[0:16383],write_sels[0:16383];
  reg [RAW_BITS-1:0] tcmd=0,pcmd=0;
  reg [5:0] lc=0;
  wire [3:0] compat_fault_o;
  integer compat=0,control_bits;
  reg clk_i=0, rst_ni=0;
  always #5 clk_i=~clk_i;
  reg [255:0] commands[0:16383];
  reg [T*1024-1:0] inputs[0:16383], expected[0:16383];
  reg [T*16-1:0] in_valid[0:16383], ex_valid[0:16383];
  reg [15:0] flags[0:16383];
  reg [255:0] cmd=0;
  reg [T*1024-1:0] sr_read_data_i=0;
  reg [T*16-1:0] sr_read_valid_i=0;
  wire [T*96-1:0] sr_read_req_o, sr_write_sel_o;
  wire [T*16-1:0] sr_consume_o, sr_write_valid_o;
  wire [T*1024-1:0] sr_write_data_o;
  wire [3:0] fault_o;
  wire busy_o;
  sxm_compatible_core #(.T(T)) dut(
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
    .compat_t_valid_i(lc[0]),.compat_p_valid_i(lc[1]),
    .compat_t_family_i(lc[3:2]),.compat_p_family_i(lc[5:4]),
    .compat_t_raw_i(tcmd),.compat_p_raw_i(pcmd),.compat_fault_o);

  reg ref_tv=0,ref_pv=0;
  reg [415:0] ref_t=0,ref_p=0;
  wire [127:0] reov,rwov;
  wire [8191:0] reod,rwod;
  reg [127:0] reiv,rwiv,neov,nwov;
  reg [8191:0] reid,rwid,neod,nwod;
  wire ref_fault,ref_conflict;
  lpu_sxm_slice reference_sxm(.clk_i,.rst_ni,.run_i(1'b1),
    .transpose_issue_valid_i(ref_tv),.transpose_issue_instruction_i(ref_t),
    .permute_issue_valid_i(ref_pv),.permute_issue_instruction_i(ref_p),
    .east_inner_valid_i(reiv),.east_inner_data_i(reid),
    .west_outer_valid_i(rwiv),.west_outer_data_i(rwid),
    .east_outer_valid_o(reov),.east_outer_data_o(reod),
    .west_inner_valid_o(rwov),.west_inner_data_o(rwod),.fault_o(ref_fault),.conflict_o(ref_conflict));
  wire ntv,npv,ncf,nfault,nbusy;
  wire [95:0] nt,np;
  wire [383:0] nreq;
  wire [95:0] nsel;
  wire [63:0] nconsume,nvalid;
  wire [4095:0] ndata;
  integer native_check=0;
  lpu_sxm_command_adapter adapter(.vmodel_transpose_valid_i(lc[0]),.vmodel_transpose_instruction_i(tcmd),
    .vmodel_permute_valid_i(lc[1]),.vmodel_permute_instruction_i(pcmd),
    .native_transpose_valid_o(ntv),.native_transpose_command_o(nt),
    .native_permute_valid_o(npv),.native_permute_command_o(np),.command_fault_o(ncf));
  sxm_slice native_old(.clk_i,.rst_ni,.transpose_cmd_valid_i(ntv),.transpose_cmd_i(nt),
    .permute_cmd_valid_i(npv),.permute_cmd_i(np),.sr_read_req_o(nreq),.sr_read_valid_i,.sr_read_data_i,
    .sr_consume_o(nconsume),.sr_write_valid_o(nvalid),.sr_write_sel_o(nsel),.sr_write_data_o(ndata),
    .fault_valid_o(nfault),.transpose_input_invalid_o(),.transpose_buffer_full_o(),
    .permute_phase_fault_o(),.permute_selector_fault_o(),.permute_buffer_not_ready_o(),.busy_o(nbusy));
  integer dt,ds,physical,ix;
  always @* begin
    reiv=0;reid=0;rwiv=0;rwid=0;neov=0;neod=0;nwov=0;nwod=0;
    physical=0;ix=0;
    for(dt=0;dt<4;dt=dt+1)for(ds=0;ds<16;ds=ds+1)begin
      ix=dt*16+ds;
      physical=int'(sr_read_req_o[ix*6+:6]);
      if(sr_read_valid_i[ix]) begin
        if(physical>=32)begin reiv[dt*32+physical%32]=1;reid[(dt*32+physical%32)*64+:64]=sr_read_data_i[ix*64+:64];end
        else begin rwiv[dt*32+physical]=1;rwid[(dt*32+physical)*64+:64]=sr_read_data_i[ix*64+:64];end
      end
      physical=int'(sr_write_sel_o[ix*6+:6]);
      if(sr_write_valid_o[ix]) begin
        if(physical>=32)begin neov[dt*32+physical%32]=1;neod[(dt*32+physical%32)*64+:64]=sr_write_data_o[ix*64+:64];end
        else begin nwov[dt*32+physical]=1;nwod[(dt*32+physical)*64+:64]=sr_write_data_o[ix*64+:64];end
      end
    end
  end
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
    if($value$plusargs("NATIVE=%d",native_check)) begin end
    repeat(2) @(negedge clk_i); rst_ni=1;
    // Keep the fixed reference's ORIGINAL issue register, one cycle upstream.
    ref_tv=legacy[0][0];ref_pv=legacy[0][1];ref_t=raw_t[0];ref_p=raw_p[0];
    for(c=0;c<cycles;c=c+1) begin
      @(negedge clk_i); cmd=commands[c]; sr_read_data_i=inputs[c]; sr_read_valid_i=in_valid[c];
      if(compat!=0) begin lc=legacy[c];tcmd=raw_t[c];pcmd=raw_p[c];end
      if(c+1<cycles) begin
        ref_tv=legacy[c+1][0];ref_pv=legacy[c+1][1];ref_t=raw_t[c+1];ref_p=raw_p[c+1];
      end else begin ref_tv=0;ref_pv=0;end
      rst_ni=!flags[c][6]; #1;
      if(ref_fault || ref_conflict || reov!==neov || rwov!==nwov) $fatal(1,"C%0d fixed reference valid/fault",c);
      for(k=0;k<128;k=k+1) begin
        if(reov[k] && reod[k*64+:64]!==neod[k*64+:64]) $fatal(1,"C%0d fixed reference east data",c);
        if(rwov[k] && rwod[k*64+:64]!==nwod[k*64+:64]) $fatal(1,"C%0d fixed reference west data",c);
      end
      if(native_check!=0) begin
        if(ncf || nfault || nconsume!==sr_consume_o || nvalid!==sr_write_valid_o) $fatal(1,"C%0d native valid/consume/fault",c);
        for(k=0;k<64;k=k+1) begin
          if(nconsume[k] && nreq[k*6+:6]!==sr_read_req_o[k*6+:6]) $fatal(1,"C%0d native selector",c);
          if(nvalid[k] && (ndata[k*64+:64]!==sr_write_data_o[k*64+:64] || nsel[(k%16)*6+:6]!==sr_write_sel_o[k*6+:6])) $fatal(1,"C%0d native data/selector",c);
        end
      end
      if(compat_fault_o!==flags[c][11:8]) $fatal(1,"C%0d compat fault expected=%h actual=%h",c,flags[c][11:8],compat_fault_o);
      if(compat!=0 && flags[c][7]) begin
        if(sr_consume_o!==consumes[c]) $fatal(1,"C%0d compatibility consume",c);
        for(k=0;k<T*16;k=k+1) begin
          if(consumes[c][k] && sr_read_req_o[k*6+:6]!==read_sels[c][k*6+:6]) $fatal(1,"C%0d read selector %0d",c,k);
          if(ex_valid[c][k] && sr_write_sel_o[k*6+:6]!==write_sels[c][k*6+:6]) $fatal(1,"C%0d write selector %0d",c,k);
        end
      end
      if(fault_o!==flags[c][3:0]) $fatal(1,"C%0d fault expected=%h actual=%h",c,flags[c][3:0],fault_o);
      if(sr_write_valid_o!==ex_valid[c]) $fatal(1,"C%0d valid expected=%h actual=%h",c,ex_valid[c],sr_write_valid_o);
      for(k=0;k<T*16;k=k+1) if(ex_valid[c][k]) begin
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
    $display("SXM_COMPAT_DIFF PASS T=%0d cycles=%0d segments=%0d captures=%0d negative_faults=%0d",T,cycles,segments,captures,faults);
    $finish;
  end
endmodule
