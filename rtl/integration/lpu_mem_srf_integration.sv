`timescale 1ns/1ps

// Phase 2A standalone MEM/SRF data-plane integration variant.
//
// The adapter in this module is purely combinational.  The authoritative SRF
// owns all stream state; MEM only observes current boundary state and produces
// consume/inject candidates.  MEM uses two independent local candidate slots (Q06=A).
module lpu_mem_srf_integration #(
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

  // Native MEM command issue interface: one 32-bit command per {slice,bank}.
  input  logic [F*2-1:0]    bank_issue_valid_i,
  input  logic [F*2*32-1:0] bank_issue_i,

  // External SRF hemisphere boundaries.  Direction 0 is East and direction 1
  // is West.  Each valid bit describes one complete 64-bit segment.
  input  logic [2*T*STREAMS-1:0] boundary_valid_i,
  input  logic [2*T*STREAMS*SEGMENT_BITS-1:0]
    boundary_data_i,
  output logic [2*T*STREAMS-1:0] boundary_valid_o,
  output logic [2*T*STREAMS*SEGMENT_BITS-1:0]
    boundary_data_o,

  // Observation ports used by the standalone integration verification.
  output logic [2*COLUMNS*T*STREAMS-1:0] state_valid_o,
  output logic [2*COLUMNS*T*STREAMS*SEGMENT_BITS-1:0]
    state_data_o,
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
  localparam integer DIRECTIONS = 2;
  localparam integer MEM_GROUPS = F / G;
  localparam integer MEM_BOUNDARIES = MEM_GROUPS + 1;
  localparam integer MEM_PRODUCERS = F * 2 * T;
  localparam integer SRF_STATE_CELLS =
    DIRECTIONS * COLUMNS * T * STREAMS;
  localparam integer SRF_INJECT_CELLS =
    DIRECTIONS * COLUMNS * T * LOCAL_PRODUCERS * STREAMS;
  localparam integer SRF_CONSUME_CELLS =
    DIRECTIONS * COLUMNS * T * LOCAL_CONSUMERS * STREAMS;

  logic [MEM_BOUNDARIES*(2*STREAMS*T)-1:0] mem_boundary_state_valid;
  logic [MEM_BOUNDARIES*(2*STREAMS*T)*SEGMENT_BITS-1:0]
    mem_boundary_state_data;
  logic [MEM_BOUNDARIES*MEM_PRODUCERS-1:0]
    unused_external_collision;
  logic [F*2*3-1:0] mem_bank_fault_code;
  logic [F*2-1:0] mem_bank_fault_tile_valid;
  logic [F*2*((T>1)?$clog2(T):1)-1:0] mem_bank_fault_tile_id;
  logic [F*2*15-1:0] mem_bank_fault_row;
  logic [MEM_GROUPS-1:0] mem_group_fault_valid;
  logic [MEM_GROUPS-1:0] mem_group_busy;

  logic [SRF_INJECT_CELLS-1:0] srf_inject_valid;
  logic [SRF_INJECT_CELLS*SEGMENT_BITS-1:0] srf_inject_data;
  logic [SRF_CONSUME_CELLS-1:0] srf_consume;

  integer boundary;
  integer direction;
  integer superlane;
  integer stream;
  integer producer;
  integer mem_cell;
  integer srf_cell;
  integer srf_slot_cell;
  integer target_boundary;
  integer target_direction;
  integer target_stream;
  integer target_superlane;

  // Static format and slot conversion.  There is deliberately no register,
  // queue, arbitration, or collision-feedback path in this adapter.
  always_comb begin
    mem_boundary_state_valid = '0;
    mem_boundary_state_data = '0;
    unused_external_collision = '0;
    srf_inject_valid = '0;
    srf_inject_data = '0;
    srf_consume = '0;

    // boundary b maps directly to sreg column b.  A MEM boundary cell is
    // ordered {direction,stream,superlane}; SRF is
    // {direction,column,superlane,stream}.
    for (boundary = 0; boundary < MEM_BOUNDARIES; boundary = boundary + 1) begin
      for (direction = 0; direction < DIRECTIONS; direction = direction + 1) begin
        for (stream = 0; stream < STREAMS; stream = stream + 1) begin
          for (superlane = 0; superlane < T;
               superlane = superlane + 1) begin
            mem_cell = boundary*(2*STREAMS*T) + (direction*STREAMS + stream)*T + superlane;
            srf_cell = ((direction*COLUMNS + boundary)*T +
                        superlane)*STREAMS + stream;
            mem_boundary_state_valid[mem_cell] = state_valid_o[srf_cell];
            mem_boundary_state_data[mem_cell*SEGMENT_BITS +: SEGMENT_BITS] =
              state_data_o[srf_cell*SEGMENT_BITS +: SEGMENT_BITS];

            // MEM consumes complete segments through SRF consumer slot 0.
            srf_slot_cell = ((((direction*COLUMNS + boundary)*T +
                              superlane)*LOCAL_CONSUMERS)*STREAMS) + stream;
            srf_consume[srf_slot_cell] =
              mem_boundary_consume_o[mem_cell];
          end
        end
      end
    end

    // Q06=A: MEM owns two local candidates at columns 0..13.
    // The raw producer index identifies tile by modulo T.
    for (producer = 0; producer < MEM_PRODUCERS; producer = producer + 1) begin
      if (mem_producer_valid_o[producer]) begin
        target_boundary = mem_producer_boundary_o[producer*4 +: 4];
        target_direction = mem_producer_direction_o[producer];
        target_stream = mem_producer_stream_o[producer*5 +: 5];
        target_superlane = producer % T;
        if ((target_boundary < COLUMNS) && (target_stream < STREAMS)) begin
          srf_slot_cell = ((((target_direction*COLUMNS + target_boundary)*
                            T + target_superlane)*LOCAL_PRODUCERS)*
                           STREAMS) + target_stream;
          // Saturate at two real FF candidates. Never overwrite slot0;
          // both slots remain visible even when a third source also arrives.
          if (!srf_inject_valid[srf_slot_cell]) begin
            srf_inject_valid[srf_slot_cell] = 1'b1;
            srf_inject_data[srf_slot_cell*SEGMENT_BITS +: SEGMENT_BITS] =
              mem_producer_data_o[producer*SEGMENT_BITS +: SEGMENT_BITS];
          end else if (!srf_inject_valid[srf_slot_cell+STREAMS]) begin
            srf_inject_valid[srf_slot_cell+STREAMS] = 1'b1;
            srf_inject_data[(srf_slot_cell+STREAMS)*SEGMENT_BITS +: SEGMENT_BITS] =
              mem_producer_data_o[producer*SEGMENT_BITS +: SEGMENT_BITS];
          end
        end
      end
    end
  end

  ftlpu_sr_hemisphere_fabric #(
    .COLUMNS(COLUMNS),
    .SUPERLANES(T),
    .STREAMS(STREAMS),
    .LANES(8),
    .DATA_BITS(8),
    .LOCAL_PRODUCERS(LOCAL_PRODUCERS),
    .LOCAL_CONSUMERS(LOCAL_CONSUMERS)
  ) u_srf (
    .clk_i,
    .rst_ni,
    .boundary_valid_i,
    .boundary_data_i,
    .boundary_valid_o,
    .boundary_data_o,
    .inject_valid_i(srf_inject_valid),
    .inject_data_i(srf_inject_data),
    .consume_i(srf_consume),
    .collision_o(srf_collision_o),
    .invalid_consume_o(srf_invalid_consume_o),
    .state_valid_o,
    .state_data_o
  );

  mem_hemisphere #(
    .P_MEM_SLICES_PER_HEMI(F),
    .P_MEM_SLICES_PER_GROUP(G),
    .P_MEM_BANK_DEPTH_ROWS(P),
    .P_SLICE_FAULT_CODE_BITS(3),
    .P_TILE_ROWS(T),
    .P_MEM_ACTIVE_ROWS(E)
  ) u_mem (
    .clk_i,
    .rst_ni,
    .bank_issue_valid_i,
    .bank_issue_i,
    .boundary_state_valid_i(mem_boundary_state_valid),
    .boundary_state_data_i(mem_boundary_state_data),
    .external_producer_collision_i(unused_external_collision),
    .boundary_consume_o(mem_boundary_consume_o),
    .producer_valid_o(mem_producer_valid_o),
    .producer_data_o(mem_producer_data_o),
    .producer_stream_dir_o(mem_producer_direction_o),
    .producer_stream_idx_o(mem_producer_stream_o),
    .producer_boundary_o(mem_producer_boundary_o),
    .internal_mem_collision_o(mem_internal_collision_o),
    .bank_fault_valid_o(mem_bank_fault_valid_o),
    .bank_fault_code_o(mem_bank_fault_code),
    .bank_fault_tile_valid_o(mem_bank_fault_tile_valid),
    .bank_fault_tile_id_o(mem_bank_fault_tile_id),
    .bank_fault_row_o(mem_bank_fault_row),
    .group_fault_valid_o(mem_group_fault_valid),
    .hemisphere_fault_valid_o(mem_fault_valid_o),
    .group_busy_o(mem_group_busy),
    .hemisphere_busy_o(mem_busy_o)
  );

`ifndef SYNTHESIS
  initial begin
    if (!lpu_native_config_pkg::profile_valid(P_LPU_PROFILE))
      $fatal(1, "illegal MEM P_LPU_PROFILE");
    if ((F % G) != 0 ||
        MEM_BOUNDARIES > 14 || COLUMNS != 16 || (T != 2 && T != 4 && T != 8) ||
        STREAMS != 32 || SEGMENT_BITS != 64 || LOCAL_PRODUCERS < 2 ||
        LOCAL_CONSUMERS < 1) begin
      $fatal(1, "lpu_mem_srf_integration parameter contract violation");
    end
  end
`endif
endmodule
