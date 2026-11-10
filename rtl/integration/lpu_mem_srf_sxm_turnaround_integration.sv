`timescale 1ns/1ps

// Shared-SRF integration. MEM slots0/1 and SXM slot1 share disjoint columns
// under Q06=A; this wrapper is entirely combinational outside the existing IP.
module lpu_mem_srf_sxm_turnaround_integration #(
  parameter integer MEM_SLICES=16, MEM_SLICES_PER_GROUP=4, MEM_DEPTH_ROWS=16,
  parameter integer COLUMNS=16, SUPERLANES=4, STREAMS=32, SEGMENT_BITS=64,
  parameter integer LOCAL_PRODUCERS=2, LOCAL_CONSUMERS=2 ,
  parameter integer P_LPU_PROFILE=0,
  parameter integer MEM_ACTIVE_ROWS=MEM_DEPTH_ROWS,
  localparam integer T=P_LPU_PROFILE==0 ? SUPERLANES : lpu_native_config_pkg::tile_rows(P_LPU_PROFILE),
  localparam integer P=P_LPU_PROFILE==0 ? MEM_DEPTH_ROWS : lpu_native_config_pkg::mem_depth_rows(P_LPU_PROFILE),
  localparam integer E=P_LPU_PROFILE==0 ? MEM_ACTIVE_ROWS : P,
  localparam integer F=P_LPU_PROFILE==0 ? MEM_SLICES : 52,
  localparam integer G=P_LPU_PROFILE==0 ? MEM_SLICES_PER_GROUP : 4
) (
  input logic clk_i, rst_ni,
  input logic [F*2-1:0] vmodel_mem_issue_valid_i,
  input logic [F*2*47-1:0] vmodel_mem_issue_instruction_i,
  output logic [F*2-1:0] native_mem_issue_valid_o, mem_command_fault_o,
  output logic [F*2*32-1:0] native_mem_issue_o,
  input logic vmodel_transpose_valid_i, input logic [415:0] vmodel_transpose_instruction_i,
  input logic vmodel_permute_valid_i, input logic [415:0] vmodel_permute_instruction_i,
  input logic [2*T*STREAMS-1:0] boundary_valid_i,
  input logic [2*T*STREAMS*SEGMENT_BITS-1:0] boundary_data_i,
  output logic [2*COLUMNS*T*STREAMS-1:0] state_valid_o,
  output logic [2*COLUMNS*T*STREAMS*SEGMENT_BITS-1:0] state_data_o,
  output logic [2*COLUMNS*T-1:0] srf_collision_o, srf_invalid_consume_o,
  output logic [F*2*T-1:0] mem_producer_valid_o, mem_producer_direction_o,
  output logic [F*2*T*SEGMENT_BITS-1:0] mem_producer_data_o,
  output logic [F*2*T*5-1:0] mem_producer_stream_o,
  output logic [F*2*T*4-1:0] mem_producer_boundary_o,
  output logic [(F/G+1)*(2*STREAMS*T)-1:0] mem_boundary_consume_o,
  output logic [F*2*T-1:0] mem_internal_collision_o,
  output logic [F*2-1:0] mem_bank_fault_valid_o,
  output logic mem_fault_valid_o, mem_busy_o,
  output logic sxm_fault_valid_o, output logic [T-1:0] sxm_transpose_input_invalid_o,
  output logic [T-1:0] sxm_transpose_buffer_full_o,
  output logic sxm_permute_phase_fault_o, sxm_permute_selector_fault_o,
  output logic sxm_permute_buffer_not_ready_o, sxm_busy_o, sxm_command_fault_o
);
  localparam integer GROUPS=F/G;
  localparam integer BOUNDARIES=GROUPS+1, PRODUCERS=F*2*T;
  localparam integer INJECT=2*COLUMNS*T*LOCAL_PRODUCERS*STREAMS;
  localparam integer CONSUME=2*COLUMNS*T*LOCAL_CONSUMERS*STREAMS;
  localparam integer SXM_STREAMS=16;
  logic [F*2-1:0] native_mem_valid;
  logic [F*2*32-1:0] native_mem_cmd;
  logic [BOUNDARIES*(2*STREAMS*T)-1:0] mem_state_valid;
  logic [BOUNDARIES*(2*STREAMS*T)*SEGMENT_BITS-1:0] mem_state_data;
  logic [BOUNDARIES*PRODUCERS-1:0] mem_ext_collision;
  logic [F*2*3-1:0] mem_fault_code;
  logic [F*2-1:0] mem_fault_tile_valid;
  logic [F*2*((T>1)?$clog2(T):1)-1:0] mem_fault_tile_id;
  logic [F*2*15-1:0] mem_fault_row;
  logic [GROUPS-1:0] group_fault, group_busy;
  logic [INJECT-1:0] mem_inject_valid, mem_inject_data_valid, sxm_inject_valid, srf_inject_valid;
  logic [INJECT*SEGMENT_BITS-1:0] mem_inject_data, sxm_inject_data, srf_inject_data;
  logic [CONSUME-1:0] mem_consume, sxm_consume, srf_consume;
  logic native_t_valid, native_p_valid;
  logic [95:0] native_t_cmd, native_p_cmd;
  logic [T*SXM_STREAMS*6-1:0] sxm_read_req;
  logic [T*SXM_STREAMS-1:0] sxm_read_valid, sxm_consume_req, sxm_write_valid;
  logic [T*SXM_STREAMS*SEGMENT_BITS-1:0] sxm_read_data, sxm_write_data;
  logic [SXM_STREAMS*6-1:0] sxm_write_sel;

  assign native_mem_issue_valid_o=native_mem_valid;
  assign native_mem_issue_o=native_mem_cmd;
  generate for(genvar b=0;b<F*2;b=b+1) begin: g_mem_cmd
    lpu_mem_command_adapter u(.issue_valid_i(vmodel_mem_issue_valid_i[b]),
      .issue_instruction_i(vmodel_mem_issue_instruction_i[b*47+:47]), .native_valid_o(native_mem_valid[b]),
      .native_command_o(native_mem_cmd[b*32+:32]), .command_fault_o(mem_command_fault_o[b]));
  end endgenerate
  lpu_sxm_command_adapter u_sxm_cmd(.vmodel_transpose_valid_i,.vmodel_transpose_instruction_i,
    .vmodel_permute_valid_i,.vmodel_permute_instruction_i,.native_transpose_valid_o(native_t_valid),
    .native_transpose_command_o(native_t_cmd),.native_permute_valid_o(native_p_valid),
    .native_permute_command_o(native_p_cmd),.command_fault_o(sxm_command_fault_o));

  integer bnd, dir, sl, str, prod, mc, sc, slot, tbnd, tdir, tstr, tsl;
  always_comb begin
    mem_state_valid='0; mem_state_data='0; mem_ext_collision='0;
    mem_inject_valid='0; mem_inject_data='0; mem_consume='0;
    for(bnd=0;bnd<BOUNDARIES;bnd=bnd+1) for(dir=0;dir<2;dir=dir+1)
      for(str=0;str<STREAMS;str=str+1) for(sl=0;sl<T;sl=sl+1) begin
        mc=bnd*(2*STREAMS*T)+(dir*STREAMS+str)*T+sl;
        sc=((dir*COLUMNS+bnd)*T+sl)*STREAMS+str;
        mem_state_valid[mc]=state_valid_o[sc];
        mem_state_data[mc*SEGMENT_BITS+:SEGMENT_BITS]=state_data_o[sc*SEGMENT_BITS+:SEGMENT_BITS];
        slot=((((dir*COLUMNS+bnd)*T+sl)*LOCAL_CONSUMERS)*STREAMS)+str;
        mem_consume[slot]=mem_boundary_consume_o[mc];
      end
    for(prod=0;prod<PRODUCERS;prod=prod+1) if(mem_producer_valid_o[prod]) begin
      tbnd=mem_producer_boundary_o[prod*4+:4]; tdir=mem_producer_direction_o[prod];
      tstr=mem_producer_stream_o[prod*5+:5]; tsl=prod%T;
      if(tbnd<COLUMNS && tstr<STREAMS) begin
        slot=((((tdir*COLUMNS+tbnd)*T+tsl)*LOCAL_PRODUCERS)*STREAMS)+tstr;
        if(!mem_inject_valid[slot]) begin
          mem_inject_valid[slot]=1'b1;
          mem_inject_data[slot*SEGMENT_BITS+:SEGMENT_BITS]=mem_producer_data_o[prod*SEGMENT_BITS+:SEGMENT_BITS];
        end else if(!mem_inject_valid[slot+STREAMS]) begin
          mem_inject_valid[slot+STREAMS]=1'b1;
          mem_inject_data[(slot+STREAMS)*SEGMENT_BITS+:SEGMENT_BITS]=mem_producer_data_o[prod*SEGMENT_BITS+:SEGMENT_BITS];
        end
      end
    end
  end
  lpu_sxm_srf_adapter #(.COLUMNS(COLUMNS),.SUPERLANES(T),.STREAMS(STREAMS),
    .SEGMENT_BITS(SEGMENT_BITS),.LOCAL_PRODUCERS(LOCAL_PRODUCERS),.LOCAL_CONSUMERS(LOCAL_CONSUMERS),
    .SXM_ACTIVE_STREAMS(SXM_STREAMS),.SXM_CONSUMER_SLOT(1),.SXM_PRODUCER_SLOT(1)) u_sxm_adapter(
      .srf_state_valid_i(state_valid_o),.srf_state_data_i(state_data_o),.sxm_sr_read_req_i(sxm_read_req),
      .sxm_sr_read_valid_o(sxm_read_valid),.sxm_sr_read_data_o(sxm_read_data),.sxm_sr_consume_i(sxm_consume_req),
      .sxm_sr_write_valid_i(sxm_write_valid),.sxm_sr_write_sel_i(sxm_write_sel),.sxm_sr_write_data_i(sxm_write_data),
      .srf_consume_o(sxm_consume),.srf_inject_valid_o(sxm_inject_valid),.srf_inject_data_o(sxm_inject_data));
  // Q06=A: MEM destinations <=13; SXM outputs are 14/15. Mask invalid
  // payloads explicitly, and prove slot sharing instead of relying on OR.
  for(genvar n=0;n<INJECT;n=n+1) begin:g_merge
    assign srf_inject_valid[n]=mem_inject_valid[n]|sxm_inject_valid[n];
    assign srf_inject_data[n*SEGMENT_BITS+:SEGMENT_BITS]=
      mem_inject_valid[n] ? mem_inject_data[n*SEGMENT_BITS+:SEGMENT_BITS] :
      sxm_inject_valid[n] ? sxm_inject_data[n*SEGMENT_BITS+:SEGMENT_BITS] : '0;
  end
`ifndef SYNTHESIS
  initial begin
    if(!lpu_native_config_pkg::profile_valid(P_LPU_PROFILE) || T!=4 || COLUMNS!=16 || STREAMS!=32 || SEGMENT_BITS!=64 || BOUNDARIES>14 || LOCAL_PRODUCERS<2)
      $fatal(1,"SXM compatibility integration requires T4, MEM columns<=13 and two local candidates");
  end
  always @(posedge clk_i) if(rst_ni && |(mem_inject_valid&sxm_inject_valid))
    $fatal(1,"Q06 MEM/SXM slot destination ownership overlap");
`endif
  assign srf_consume=mem_consume|sxm_consume;
  ftlpu_sr_hemisphere_fabric #(.COLUMNS(COLUMNS),.SUPERLANES(T),.STREAMS(STREAMS),.LANES(8),.DATA_BITS(8),.LOCAL_PRODUCERS(LOCAL_PRODUCERS),.LOCAL_CONSUMERS(LOCAL_CONSUMERS)) u_srf(
    .clk_i,.rst_ni,.boundary_valid_i,.boundary_data_i,.boundary_valid_o(),.boundary_data_o(),.inject_valid_i(srf_inject_valid),.inject_data_i(srf_inject_data),.consume_i(srf_consume),.collision_o(srf_collision_o),.invalid_consume_o(srf_invalid_consume_o),.state_valid_o,.state_data_o);
  mem_hemisphere #(.P_MEM_SLICES_PER_HEMI(F),.P_MEM_SLICES_PER_GROUP(G),.P_MEM_BANK_DEPTH_ROWS(P),.P_SLICE_FAULT_CODE_BITS(3),.P_TILE_ROWS(T),.P_MEM_ACTIVE_ROWS(E)) u_mem(
    .clk_i,.rst_ni,.bank_issue_valid_i(native_mem_valid),.bank_issue_i(native_mem_cmd),.boundary_state_valid_i(mem_state_valid),.boundary_state_data_i(mem_state_data),.external_producer_collision_i(mem_ext_collision),.boundary_consume_o(mem_boundary_consume_o),.producer_valid_o(mem_producer_valid_o),.producer_data_o(mem_producer_data_o),.producer_stream_dir_o(mem_producer_direction_o),.producer_stream_idx_o(mem_producer_stream_o),.producer_boundary_o(mem_producer_boundary_o),.internal_mem_collision_o(mem_internal_collision_o),.bank_fault_valid_o(mem_bank_fault_valid_o),.bank_fault_code_o(mem_fault_code),.bank_fault_tile_valid_o(mem_fault_tile_valid),.bank_fault_tile_id_o(mem_fault_tile_id),.bank_fault_row_o(mem_fault_row),.group_fault_valid_o(group_fault),.hemisphere_fault_valid_o(mem_fault_valid_o),.group_busy_o(group_busy),.hemisphere_busy_o(mem_busy_o));
  sxm_slice u_sxm(.clk_i,.rst_ni,.transpose_cmd_valid_i(native_t_valid),.transpose_cmd_i(native_t_cmd),.permute_cmd_valid_i(native_p_valid),.permute_cmd_i(native_p_cmd),.sr_read_req_o(sxm_read_req),.sr_read_valid_i(sxm_read_valid),.sr_read_data_i(sxm_read_data),.sr_consume_o(sxm_consume_req),.sr_write_valid_o(sxm_write_valid),.sr_write_sel_o(sxm_write_sel),.sr_write_data_o(sxm_write_data),.fault_valid_o(sxm_fault_valid_o),.transpose_input_invalid_o(sxm_transpose_input_invalid_o),.transpose_buffer_full_o(sxm_transpose_buffer_full_o),.permute_phase_fault_o(sxm_permute_phase_fault_o),.permute_selector_fault_o(sxm_permute_selector_fault_o),.permute_buffer_not_ready_o(sxm_permute_buffer_not_ready_o),.busy_o(sxm_busy_o));
endmodule
