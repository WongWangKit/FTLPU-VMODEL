`timescale 1ns/1ps

// Phase 2B wrapper: a bank-local, zero-cycle command conversion in front of
// the unchanged Phase 2A MEM/SRF data plane.
module lpu_mem_srf_command_integration #(
  parameter integer MEM_SLICES           = 52,
  parameter integer MEM_SLICES_PER_GROUP = 4,
  parameter integer MEM_DEPTH_ROWS       = 32768,
  parameter integer COLUMNS              = 16,
  parameter integer SUPERLANES           = 4,
  parameter integer STREAMS              = 32,
  parameter integer SEGMENT_BITS         = 64,
  parameter integer LOCAL_PRODUCERS      = 2,
  parameter integer LOCAL_CONSUMERS      = 2,
  parameter integer P_LPU_PROFILE        = 0,
  parameter integer MEM_ACTIVE_ROWS      = MEM_DEPTH_ROWS,
  localparam integer F = P_LPU_PROFILE == 0 ? MEM_SLICES : 52,
  localparam integer G = P_LPU_PROFILE == 0 ? MEM_SLICES_PER_GROUP : 4,
  localparam integer T = P_LPU_PROFILE == 0 ? SUPERLANES : lpu_native_config_pkg::tile_rows(P_LPU_PROFILE),
  localparam integer P = P_LPU_PROFILE == 0 ? MEM_DEPTH_ROWS : lpu_native_config_pkg::mem_depth_rows(P_LPU_PROFILE),
  localparam integer E = P_LPU_PROFILE == 0 ? MEM_ACTIVE_ROWS : P
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic [F*2-1:0] vmodel_issue_valid_i,
  input  logic [F*2*47-1:0] vmodel_issue_instruction_i,
  output logic [F*2-1:0] native_issue_valid_o,
  output logic [F*2*32-1:0] native_issue_o,
  output logic [F*2-1:0] command_fault_o,
  input  logic [2*T*STREAMS-1:0] boundary_valid_i,
  input  logic [2*T*STREAMS*SEGMENT_BITS-1:0] boundary_data_i,
  output logic [2*T*STREAMS-1:0] boundary_valid_o,
  output logic [2*T*STREAMS*SEGMENT_BITS-1:0] boundary_data_o,
  output logic [2*COLUMNS*T*STREAMS-1:0] state_valid_o,
  output logic [2*COLUMNS*T*STREAMS*SEGMENT_BITS-1:0] state_data_o,
  output logic [(F/G+1)*(2*STREAMS*T)-1:0]
    mem_boundary_consume_o,
  output logic [F*2*T-1:0] mem_producer_valid_o,
  output logic [F*2*T*SEGMENT_BITS-1:0] mem_producer_data_o,
  output logic [F*2*T-1:0] mem_producer_direction_o,
  output logic [F*2*T*5-1:0] mem_producer_stream_o,
  output logic [F*2*T*4-1:0] mem_producer_boundary_o,
  output logic [2*COLUMNS*T-1:0] srf_collision_o,
  output logic [2*COLUMNS*T-1:0] srf_invalid_consume_o,
  output logic [F*2*T-1:0] mem_internal_collision_o,
  output logic [F*2-1:0] mem_bank_fault_valid_o,
  output logic mem_fault_valid_o,
  output logic mem_busy_o
);
  generate
    for (genvar bank = 0; bank < F*2; bank = bank + 1) begin : gen_adapter
      lpu_mem_command_adapter u_adapter (
        .issue_valid_i(vmodel_issue_valid_i[bank]),
        .issue_instruction_i(vmodel_issue_instruction_i[bank*47 +: 47]),
        .native_valid_o(native_issue_valid_o[bank]),
        .native_command_o(native_issue_o[bank*32 +: 32]),
        .command_fault_o(command_fault_o[bank])
      );
    end
  endgenerate

  lpu_mem_srf_integration #(
    .MEM_SLICES(F),
    .MEM_SLICES_PER_GROUP(G),
    .MEM_DEPTH_ROWS(P),
    .COLUMNS(COLUMNS),
    .SUPERLANES(T),
    .STREAMS(STREAMS),
    .SEGMENT_BITS(SEGMENT_BITS),
    .LOCAL_PRODUCERS(LOCAL_PRODUCERS),
    .LOCAL_CONSUMERS(LOCAL_CONSUMERS),
    .P_LPU_PROFILE(P_LPU_PROFILE),
    .MEM_ACTIVE_ROWS(E)
  ) u_phase2a_data_plane (
    .clk_i,
    .rst_ni,
    .bank_issue_valid_i(native_issue_valid_o),
    .bank_issue_i(native_issue_o),
    .boundary_valid_i,
    .boundary_data_i,
    .boundary_valid_o,
    .boundary_data_o,
    .state_valid_o,
    .state_data_o,
    .mem_boundary_consume_o,
    .mem_producer_valid_o,
    .mem_producer_data_o,
    .mem_producer_direction_o,
    .mem_producer_stream_o,
    .mem_producer_boundary_o,
    .srf_collision_o,
    .srf_invalid_consume_o,
    .mem_internal_collision_o,
    .mem_bank_fault_valid_o,
    .mem_fault_valid_o,
    .mem_busy_o
  );
endmodule
