`timescale 1ns/1ps
// True MEM SRAM -> inherited single SRF -> new SXM -> same SRF -> SRAM.
// Preload uses normal MEM writes; final verification uses normal MEM reads.
module sxm_row_mem_tb #(parameter integer T=4, F=16);
  localparam integer C=16,S=32,N=8*T,G=F/4,DEPTH=128;
  localparam integer PRE=20, READ0=PRE+N*T+30;
  localparam integer CAP_DELAY=15, OUT0=READ0+N*T+20;
  localparam integer OUT_STEP=T+4, CHECK0=OUT0+N*OUT_STEP+40;
  reg clk_i=0,rst_ni=0;
  always #5 clk_i=~clk_i;
  reg [F*2-1:0] vmodel_mem_issue_valid_i;
  reg [F*2*47-1:0] vmodel_mem_issue_instruction_i;
  reg [2*T*S-1:0] boundary_valid_i;
  reg [2*T*S*64-1:0] boundary_data_i;
  reg row_ctrl_valid_i,row_ctrl_ctx_i;
  reg [1:0] row_ctrl_op_i;
  reg [2:0] row_ctrl_index_i;
  reg [127:0] row_ctrl_data_i;
  reg row_cap_valid_i,row_cap_ctx_i;
  reg [2:0] row_cap_tile_i,row_cap_group_i;
  reg [3:0] row_cap_row_i;
  reg row_p_valid_i,row_p_ctx_i,row_p_paired_i,row_p_branch_i;
  reg [2:0] row_p_dest_i,row_p_source_i;
  reg [3:0] row_p_row_i;
  reg [5:0] row_p_sequence_i;
  reg [T-1:0] row_run_valid_i;
  reg row_run_ctx_i;
  reg [15:0] row_run_delay_i,row_run_interval_i;
  reg [5:0] row_run_count_i,row_run_sequence_i;
  wire [3:0] row_fault_o;
  wire [2*C*T*S-1:0] state_valid_o;
  wire [2*C*T*S*64-1:0] state_data_o;
  wire [2*C*T-1:0] srf_collision_o,srf_invalid_consume_o;
  wire [F*2*T-1:0] mem_producer_valid_o,mem_producer_direction_o;
  wire [F*2*T*64-1:0] mem_producer_data_o;
  wire [F*2*T*5-1:0] mem_producer_stream_o;
  wire [F*2*T*4-1:0] mem_producer_boundary_o;
  wire [F*2-1:0] mem_command_fault_o;
  wire mem_fault_valid_o,mem_busy_o,sxm_fault_valid_o,sxm_busy_o;
  lpu_mem_srf_sxm_turnaround_integration #(.SUPERLANES(T),.MEM_SLICES(F),
    .MEM_DEPTH_ROWS(DEPTH),.P_ROW_MODE(1)) dut(
    .clk_i,.rst_ni,.vmodel_mem_issue_valid_i,.vmodel_mem_issue_instruction_i,
    .vmodel_transpose_valid_i(1'b0),.vmodel_transpose_instruction_i(416'b0),
    .vmodel_permute_valid_i(1'b0),.vmodel_permute_instruction_i(416'b0),
    .boundary_valid_i,.boundary_data_i,.state_valid_o,.state_data_o,
    .srf_collision_o,.srf_invalid_consume_o,.mem_producer_valid_o,.mem_producer_data_o,
    .mem_producer_direction_o,.mem_producer_stream_o,.mem_producer_boundary_o,
    .mem_command_fault_o,.mem_fault_valid_o,.mem_busy_o,.sxm_fault_valid_o,.sxm_busy_o,
    .row_ctrl_valid_i,.row_ctrl_op_i,.row_ctrl_ctx_i,.row_ctrl_index_i,.row_ctrl_data_i,
    .row_cap_valid_i,.row_cap_ctx_i,.row_cap_tile_i,.row_cap_group_i,.row_cap_row_i,
    .row_p_valid_i,.row_p_ctx_i,.row_p_dest_i,.row_p_source_i,.row_p_row_i,
    .row_p_paired_i,.row_p_branch_i,.row_p_sequence_i,
    .row_run_valid_i,.row_run_ctx_i,.row_run_delay_i,.row_run_interval_i,.row_run_count_i,.row_run_sequence_i,
    .row_fault_o);

  integer cycle,r,d,p,l,idx,delta,tile,row,checked=0,negative=0;
  reg [63:0] want;
  function automatic [31:0] pattern(input integer row,col);
    pattern=32'h814375ab+(row*N+col)*32'h01030107;
  endfunction
  function automatic [63:0] input_segment(input integer rr,tt,plane);
    integer k; reg [31:0] v;
    begin for(k=0;k<8;k=k+1) begin v=pattern(rr,8*tt+k);input_segment[k*8+:8]=v[8*plane+:8];end end
  endfunction
  function automatic [63:0] output_segment(input integer rr,tt,plane);
    integer k; reg [31:0] v;
    begin for(k=0;k<8;k=k+1) begin v=pattern(8*tt+7-k,rr);output_segment[k*8+:8]=v[8*plane+:8];end end
  endfunction
  task automatic memcmd(input integer op,west,rr);
    integer k; reg [46:0] word;
    begin for(k=0;k<4;k=k+1) begin
      word=0;word[2:0]=op;word[7:3]=k;word[8]=west;word[30:15]=rr;
      vmodel_mem_issue_valid_i[k*2]=1;vmodel_mem_issue_instruction_i[k*2*47+:47]=word;
    end end
  endtask
  task automatic clear;
    begin
      vmodel_mem_issue_valid_i=0;vmodel_mem_issue_instruction_i=0;boundary_valid_i=0;boundary_data_i=0;
      row_ctrl_valid_i=0;row_ctrl_op_i=0;row_ctrl_ctx_i=0;row_ctrl_index_i=0;row_ctrl_data_i=0;
      row_cap_valid_i=0;row_cap_ctx_i=0;row_cap_tile_i=0;row_cap_group_i=0;row_cap_row_i=0;
      row_p_valid_i=0;row_p_ctx_i=0;row_p_dest_i=0;row_p_source_i=0;row_p_row_i=0;
      row_p_paired_i=0;row_p_branch_i=0;row_p_sequence_i=0;
      row_run_valid_i=0;row_run_ctx_i=0;row_run_delay_i=0;row_run_interval_i=4;row_run_count_i=1;row_run_sequence_i=0;
    end
  endtask
  // Count actual legal SRAM write edges and validate address+data at the leaf.
  // Read-only hierarchical observation: never force/preload internal arrays.
  integer commits[0:3][0:T-1];
  for(genvar gp=0;gp<4;gp=gp+1) begin:g_commit_p
    for(genvar gt=0;gt<T;gt=gt+1) begin:g_commit_t
      wire cv=dut.u_mem.gen_group[0].u_group.gen_slice[gp].u_slice.gen_bank[0].u_logical_bank.gen_leaf[gt].u_leaf.cmd_valid_i;
      wire [2:0] op=dut.u_mem.gen_group[0].u_group.gen_slice[gp].u_slice.gen_bank[0].u_logical_bank.gen_leaf[gt].u_leaf.cmd_opcode_i;
      wire [14:0] addr=dut.u_mem.gen_group[0].u_group.gen_slice[gp].u_slice.gen_bank[0].u_logical_bank.gen_leaf[gt].u_leaf.cmd_row_i;
      wire valid=dut.u_mem.gen_group[0].u_group.gen_slice[gp].u_slice.gen_bank[0].u_logical_bank.gen_leaf[gt].u_leaf.stream_valid_i;
      wire [63:0] data=dut.u_mem.gen_group[0].u_group.gen_slice[gp].u_slice.gen_bank[0].u_logical_bank.gen_leaf[gt].u_leaf.stream_data_i;
      always @(posedge clk_i) if(!rst_ni) commits[gp][gt]=0;
      else if(cv && op==1 && addr>=N) begin
        if(addr>=2*N || !valid || data!==output_segment(addr-N,gt,gp))
          $fatal(1,"C%0d leaf commit plane=%0d tile=%0d addr=%0d valid=%b",cycle,gp,gt,addr,valid);
        if(cycle!==OUT0+(addr-N)*OUT_STEP+16+gt) $fatal(1,"MEM commit phase C%0d",cycle);
        commits[gp][gt]=commits[gp][gt]+1;
      end
    end
  end
  initial begin
    if($value$plusargs("MISSING_PLANE=%d",negative)) begin end
    clear();repeat(2) @(negedge clk_i);rst_ni=1;
    for(cycle=0;cycle<CHECK0+N*T+30;cycle=cycle+1) begin
      @(negedge clk_i);clear();
      if(cycle==0) begin
        row_ctrl_valid_i=1;row_ctrl_op_i=1;row_ctrl_data_i[114]=1;
        for(p=0;p<16;p=p+1) row_ctrl_data_i[6*p+:6]=32+p; // East input
      end
      if(cycle>=1 && cycle<=T) begin
        row_ctrl_valid_i=1;row_ctrl_op_i=2;row_ctrl_index_i=cycle-1;
        for(p=0;p<16;p=p+1) row_ctrl_data_i[6*p+:6]=p; // West output
        for(l=0;l<8;l=l+1) row_ctrl_data_i[96+3*l+:3]=7-l;
        row_ctrl_data_i[122:120]=cycle-1;
      end
      // Public boundary preload, followed by ordinary native-backed MEM write.
      delta=cycle-(PRE-1);
      if(delta>=0 && delta<N*T) begin
        row=delta/T;tile=delta%T;
        for(p=0;p<4;p=p+1) begin
          idx=tile*S+p;boundary_valid_i[idx]=1;boundary_data_i[idx*64+:64]=input_segment(row,tile,p);
        end
      end
      if(cycle>=PRE && cycle<PRE+N*T && (cycle-PRE)%T==0) memcmd(1,0,(cycle-PRE)/T);
      if(cycle>=READ0 && cycle<READ0+N*T && (cycle-READ0)%T==0) memcmd(0,0,(cycle-READ0)/T);
      if(negative!=0 && cycle==READ0) vmodel_mem_issue_valid_i[6]=0;
      for(r=0;r<T;r=r+1) if(cycle==READ0+8*r*T+CAP_DELAY-1) begin
        row_ctrl_valid_i=1;row_ctrl_op_i=3;row_ctrl_index_i=r;
      end
      delta=cycle-(READ0+CAP_DELAY);
      if(delta>=0 && delta<N*T) begin
        row_cap_valid_i=1;row_cap_tile_i=delta%T;row_cap_group_i=(delta/T)/8;row_cap_row_i=(delta/T)%8;
      end
      delta=cycle-OUT0;
      if(delta>=0 && delta<N*OUT_STEP && delta%OUT_STEP<T) begin
        row_p_valid_i=1;row_p_dest_i=delta%OUT_STEP;row_p_source_i=(delta/OUT_STEP)/8;row_p_row_i=(delta/OUT_STEP)%8;
      end
      delta=cycle-(OUT0+1);
      if(delta>=0 && delta<N*OUT_STEP && delta%OUT_STEP<T) row_run_valid_i[delta%OUT_STEP]=1;
      delta=cycle-(OUT0+16);
      if(delta>=0 && delta<N*OUT_STEP && delta%OUT_STEP==0) memcmd(1,1,N+delta/OUT_STEP);
      if(cycle==CHECK0-1 && (sxm_busy_o || mem_busy_o || state_valid_o!=0)) $fatal(1,"pre-readback drain");
      delta=cycle-CHECK0;
      if(delta>=0 && delta<N*T && delta%T==0) memcmd(0,0,N+delta/T);
      #1;
      if(negative!=0 && cycle==READ0+CAP_DELAY) begin
        if(row_fault_o!==4'b0010 || dut.sxm_consume!='0 || dut.sxm_write_valid!='0)
          $fatal(1,"missing plane must reject before side effects");
        @(posedge clk_i);#1;
        if(dut.g_row.u_sxm.u_core.written_q[0]!=0) $fatal(1,"partial row persisted");
        $display("SXM_ROW_MEM_NEGATIVE PASS missing_plane no_consume no_capture no_output");
        $finish;
      end else if(row_fault_o!=0 || mem_fault_valid_o || sxm_fault_valid_o || |mem_command_fault_o ||
         |srf_collision_o || |srf_invalid_consume_o) $fatal(1,"C%0d fault row=%h mem=%b sr=%h invalid=%h",cycle,row_fault_o,mem_fault_valid_o,srf_collision_o,srf_invalid_consume_o);
      @(posedge clk_i);#1;
      if(delta>=0 && delta<N*T) begin
        row=delta/T;tile=delta%T;
        for(p=0;p<4;p=p+1) begin
          idx=p*2*T+tile;want=output_segment(row,tile,p);
          if(!mem_producer_valid_o[idx] || mem_producer_data_o[idx*64+:64]!==want)
            $fatal(1,"C%0d readback row%0d tile%0d plane%0d expected=%h actual=%h",cycle,row,tile,p,want,mem_producer_data_o[idx*64+:64]);
          checked=checked+1;
        end
      end
    end
    for(p=0;p<4;p=p+1) for(d=0;d<T;d=d+1) if(commits[p][d]!=N) $fatal(1,"commit count");
    if(checked!=N*T*4 || sxm_busy_o || mem_busy_o || state_valid_o!=0) $fatal(1,"final drain/count");
    $display("SXM_ROW_MEM PASS T=%0d F=%0d words=%0d commits=%0d CAP_DELAY=%0d output_to_commit=14",T,F,N*N,checked,CAP_DELAY);
    $finish;
  end
endmodule
