`timescale 1ns/1ps
// Phase 4A-2 adds no data-path state: it is the explicit full-round-trip
// variant of the validated Phase 4A-1 shared-SRF integration.
module lpu_mem_srf_sxm_roundtrip_integration #(
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
  input logic clk_i,rst_ni,input logic [F*2-1:0] vmodel_mem_issue_valid_i,
  input logic [F*2*47-1:0] vmodel_mem_issue_instruction_i,
  output logic [F*2-1:0] native_mem_issue_valid_o,mem_command_fault_o,
  output logic [F*2*32-1:0] native_mem_issue_o,
  input logic vmodel_transpose_valid_i,input logic [415:0] vmodel_transpose_instruction_i,
  input logic vmodel_permute_valid_i,input logic [415:0] vmodel_permute_instruction_i,
  input logic [2*T*STREAMS-1:0] boundary_valid_i,
  input logic [2*T*STREAMS*SEGMENT_BITS-1:0] boundary_data_i,
  output logic [2*COLUMNS*T*STREAMS-1:0] state_valid_o,
  output logic [2*COLUMNS*T*STREAMS*SEGMENT_BITS-1:0] state_data_o,
  output logic [2*COLUMNS*T-1:0] srf_collision_o,srf_invalid_consume_o,
  output logic [F*2*T-1:0] mem_producer_valid_o,mem_producer_direction_o,
  output logic [F*2*T*SEGMENT_BITS-1:0] mem_producer_data_o,
  output logic [F*2*T*5-1:0] mem_producer_stream_o,
  output logic [F*2*T*4-1:0] mem_producer_boundary_o,
  output logic [(F/G+1)*(2*STREAMS*T)-1:0] mem_boundary_consume_o,
  output logic [F*2*T-1:0] mem_internal_collision_o,
  output logic [F*2-1:0] mem_bank_fault_valid_o,
  output logic mem_fault_valid_o,mem_busy_o,sxm_fault_valid_o,
  output logic [T-1:0] sxm_transpose_input_invalid_o,sxm_transpose_buffer_full_o,
  output logic sxm_permute_phase_fault_o,sxm_permute_selector_fault_o,
  output logic sxm_permute_buffer_not_ready_o,sxm_busy_o,sxm_command_fault_o
);
  lpu_mem_srf_sxm_turnaround_integration #(.MEM_SLICES(F),.MEM_SLICES_PER_GROUP(G),.MEM_DEPTH_ROWS(P),.COLUMNS(COLUMNS),.SUPERLANES(T),.STREAMS(STREAMS),.SEGMENT_BITS(SEGMENT_BITS),.LOCAL_PRODUCERS(LOCAL_PRODUCERS),.LOCAL_CONSUMERS(LOCAL_CONSUMERS),.P_LPU_PROFILE(P_LPU_PROFILE),.MEM_ACTIVE_ROWS(E)) u_turnaround (.*);
endmodule
