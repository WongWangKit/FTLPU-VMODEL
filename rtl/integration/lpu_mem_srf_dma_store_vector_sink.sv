`timescale 1ns/1ps

// DMA-1C Store-only composition.  MEM and the DMA TX attachment share one
// ordinary SRF hemisphere.  The wrapper owns no SRF payload state: leaf state
// remains exclusively inside ftlpu_sr_superlane_col_dir.
//
// The Store attachment is the existing C2C TX tap in External-storage DMA
// mode: East sreg13, E0..E7, and local consumer slot 0.  It is deliberately
// not a peer transport, descriptor engine, or external-memory protocol.
module lpu_mem_srf_dma_store_vector_sink #(
  parameter integer MEM_SLICES           = 52,
  parameter integer MEM_SLICES_PER_GROUP = 4,
  parameter integer MEM_DEPTH_ROWS       = 32768,
  parameter integer COLUMNS              = 16,
  parameter integer SUPERLANES           = 4,
  parameter integer STREAMS              = 32,
  parameter integer SEGMENT_BITS         = 64,
  parameter integer LOCAL_PRODUCERS      = 2,
  parameter integer LOCAL_CONSUMERS      = 2,
  parameter integer COMPLETED_FIFO_DEPTH = 2 ,
  parameter integer P_LPU_PROFILE=0,
  parameter integer MEM_ACTIVE_ROWS=MEM_DEPTH_ROWS,
  localparam integer T=P_LPU_PROFILE==0 ? SUPERLANES : lpu_native_config_pkg::tile_rows(P_LPU_PROFILE),
  localparam integer P=P_LPU_PROFILE==0 ? MEM_DEPTH_ROWS : lpu_native_config_pkg::mem_depth_rows(P_LPU_PROFILE),
  localparam integer E=P_LPU_PROFILE==0 ? MEM_ACTIVE_ROWS : P,
  localparam integer F=P_LPU_PROFILE==0 ? MEM_SLICES : 52,
  localparam integer G=P_LPU_PROFILE==0 ? MEM_SLICES_PER_GROUP : 4
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic [F*2-1:0]    bank_issue_valid_i,
  input  logic [F*2*32-1:0] bank_issue_i,
  input  logic [2*T*STREAMS-1:0] boundary_valid_i,
  input  logic [2*T*STREAMS*SEGMENT_BITS-1:0] boundary_data_i,

  // Minimal scheduled Store Send control.  This selects East E0..E7 at the
  // fixed sreg13 DMA TX attachment; it is not a descriptor interface.
  input  logic       dma_store_issue_valid_i,
  input  logic [2:0] dma_store_stream_index_i,

  // Abstract external 256-bit vector sink.  This handshake only pops the
  // completed-vector FIFO and never backpressures ordinary SRF traffic.
  output logic         vector_valid_o,
  output logic [255:0] vector_data_o,
  input  logic         vector_accept_i,

  output logic [2*COLUMNS*T*STREAMS-1:0] state_valid_o,
  output logic [2*COLUMNS*T*STREAMS*SEGMENT_BITS-1:0] state_data_o,
  output logic [F*2*T-1:0] mem_producer_valid_o,
  output logic [F*2*T*SEGMENT_BITS-1:0] mem_producer_data_o,
  output logic [F*2*T-1:0] mem_producer_direction_o,
  output logic [F*2*T*5-1:0] mem_producer_stream_o,
  output logic [F*2*T*4-1:0] mem_producer_boundary_o,
  output logic [2*COLUMNS*T-1:0] srf_collision_o,
  output logic [2*COLUMNS*T-1:0] srf_invalid_consume_o,
  output logic mem_fault_valid_o
);
  localparam integer DIRECTIONS = 2;
  localparam integer MEM_BOUNDARIES =
    F / G + 1;
  localparam integer PRODUCERS = F * 2 * T;
  localparam integer SRF_INJECT_CELLS =
    DIRECTIONS * COLUMNS * T * LOCAL_PRODUCERS * STREAMS;
  localparam integer SRF_CONSUME_CELLS =
    DIRECTIONS * COLUMNS * T * LOCAL_CONSUMERS * STREAMS;

  logic [2*T*STREAMS-1:0] boundary_valid_unused;
  logic [2*T*STREAMS*SEGMENT_BITS-1:0] boundary_data_unused;
  logic [MEM_BOUNDARIES*(2*STREAMS*T)-1:0] mem_boundary_state_valid;
  logic [MEM_BOUNDARIES*(2*STREAMS*T)*SEGMENT_BITS-1:0] mem_boundary_state_data;
  logic [MEM_BOUNDARIES*PRODUCERS-1:0] mem_external_collision;
  logic [MEM_BOUNDARIES*(2*STREAMS*T)-1:0] mem_boundary_consume;
  logic [PRODUCERS-1:0] mem_internal_collision;
  logic [F*2-1:0] mem_bank_fault_valid;
  logic [F*2*3-1:0] mem_bank_fault_code;
  logic [F*2-1:0] mem_bank_fault_tile_valid;
  logic [F*2*((T>1)?$clog2(T):1)-1:0] mem_bank_fault_tile_id;
  logic [F*2*15-1:0] mem_bank_fault_row;
  logic [F/G-1:0] mem_group_fault;
  logic [F/G-1:0] mem_group_busy;
  logic mem_busy_unused;

  logic [SRF_INJECT_CELLS-1:0] mem_inject_valid;
  logic [SRF_INJECT_CELLS*SEGMENT_BITS-1:0] mem_inject_data;
  logic [SRF_CONSUME_CELLS-1:0] mem_consume;
  logic [SRF_CONSUME_CELLS-1:0] dma_consume;
  logic [SRF_CONSUME_CELLS-1:0] srf_consume;

  logic [255:0] dma_tile_data;
  logic [3:0] dma_tile_valid;
  logic [3:0] dma_tile_consume;
  logic dma_completed_valid;
  logic [255:0] dma_completed_payload;
  logic dma_fifo_full;
  logic dma_fifo_empty;
  logic [$clog2(COMPLETED_FIFO_DEPTH+1)-1:0] dma_fifo_count;
  logic dma_fifo_pop;
  logic dma_fifo_can_enqueue;

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

  // MEM owns slots0/1 at its boundary cells.  The packed slot
  // address proves that slot IDs are local to a leaf/stream coordinate, not
  // global hemisphere ports.
  always_comb begin
    mem_boundary_state_valid = '0;
    mem_boundary_state_data = '0;
    mem_external_collision = '0;
    mem_inject_valid = '0;
    mem_inject_data = '0;
    mem_consume = '0;

    for (boundary = 0; boundary < MEM_BOUNDARIES;
         boundary = boundary + 1) begin
      for (direction = 0; direction < DIRECTIONS; direction = direction + 1) begin
        for (stream = 0; stream < STREAMS; stream = stream + 1) begin
          for (superlane = 0; superlane < T;
               superlane = superlane + 1) begin
            mem_cell = ((boundary*DIRECTIONS + direction)*STREAMS + stream)*
                       T + superlane;
            srf_cell = ((direction*COLUMNS + boundary)*T +
                        superlane)*STREAMS + stream;
            mem_boundary_state_valid[mem_cell] = state_valid_o[srf_cell];
            mem_boundary_state_data[mem_cell*SEGMENT_BITS +: SEGMENT_BITS] =
              state_data_o[srf_cell*SEGMENT_BITS +: SEGMENT_BITS];

            // MEM consumer ownership is local consumer slot0.
            srf_slot_cell = ((((direction*COLUMNS + boundary)*T +
                              superlane)*LOCAL_CONSUMERS)*STREAMS) + stream;
            mem_consume[srf_slot_cell] = mem_boundary_consume[mem_cell];
          end
        end
      end
    end

    for (producer = 0; producer < PRODUCERS; producer = producer + 1) begin
      if (mem_producer_valid_o[producer]) begin
        target_boundary = mem_producer_boundary_o[producer*4 +: 4];
        target_direction = mem_producer_direction_o[producer];
        target_stream = mem_producer_stream_o[producer*5 +: 5];
        target_superlane = producer % T;
        if ((target_boundary < COLUMNS) && (target_stream < STREAMS)) begin
          // MEM candidate ownership starts at slot0; a second source uses slot1.
          srf_slot_cell = ((((target_direction*COLUMNS + target_boundary)*
                            T + target_superlane)*LOCAL_PRODUCERS)*
                           STREAMS) + target_stream;
          if (!mem_inject_valid[srf_slot_cell]) begin
            mem_inject_valid[srf_slot_cell] = 1'b1;
            mem_inject_data[srf_slot_cell*SEGMENT_BITS +: SEGMENT_BITS] =
              mem_producer_data_o[producer*SEGMENT_BITS +: SEGMENT_BITS];
          end else if (!mem_inject_valid[srf_slot_cell+STREAMS]) begin
            mem_inject_valid[srf_slot_cell+STREAMS] = 1'b1;
            mem_inject_data[(srf_slot_cell+STREAMS)*SEGMENT_BITS +: SEGMENT_BITS] =
              mem_producer_data_o[producer*SEGMENT_BITS +: SEGMENT_BITS];
          end
        end
      end
    end
  end

  lpu_c2c_tx_srf_adapter #(
    .COLUMNS(COLUMNS),
    .SUPERLANES(T),
    .STREAMS(STREAMS),
    .SEGMENT_BITS(SEGMENT_BITS),
    .LOCAL_CONSUMERS(LOCAL_CONSUMERS),
    .C2C_CONSUMER_SLOT(0),
    .TX_COLUMN(13)
  ) u_dma_tx_attachment (
    .clk_i,
    .rst_ni,
    .tx_issue_valid_i(dma_store_issue_valid_i),
    .tx_stream_index_i(dma_store_stream_index_i),
    .srf_state_valid_i(state_valid_o),
    .srf_state_data_i(state_data_o),
    .tile_data_o(dma_tile_data),
    .tile_valid_o(dma_tile_valid),
    .tile_stream_idx_o(),
    .gather_tile_consume_i(dma_tile_consume),
    .srf_consume_o(dma_consume)
  );

  c2c_tx_gather #(
    .SEGMENT_BITS(SEGMENT_BITS)
  ) u_dma_tx_gather (
    .clk_i,
    .rst_ni,
    .tile_data_i(dma_tile_data),
    .tile_valid_i(dma_tile_valid),
    .tile_consume_o(dma_tile_consume),
    .completed_valid_o(dma_completed_valid),
    .completed_payload_o(dma_completed_payload)
  );

  assign dma_fifo_pop = vector_valid_o && vector_accept_i;
  assign dma_fifo_can_enqueue = !dma_fifo_full || dma_fifo_pop;

  c2c_completed_fifo #(
    .DEPTH(COMPLETED_FIFO_DEPTH)
  ) u_dma_completed_fifo (
    .clk_i,
    .rst_ni,
    .enq_valid_i(dma_completed_valid),
    .enq_payload_i(dma_completed_payload),
    .deq_pop_i(dma_fifo_pop),
    .deq_valid_o(vector_valid_o),
    .deq_payload_o(vector_data_o),
    .full_o(dma_fifo_full),
    .empty_o(dma_fifo_empty),
    .count_o(dma_fifo_count)
  );

  // A full completed FIFO is an illegal capacity/static-schedule condition.
  // It must never turn into ordinary SRF ready/stall/retry/replay behavior.
`ifndef SYNTHESIS
  always @(posedge clk_i) begin
    if (rst_ni && dma_completed_valid && !dma_fifo_can_enqueue)
      $fatal(1, "TEST_FAIL DMA completed FIFO enqueue capacity exceeded");
  end
`endif

  assign srf_consume = mem_consume | dma_consume;

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
    .boundary_valid_o(boundary_valid_unused),
    .boundary_data_o(boundary_data_unused),
    .inject_valid_i(mem_inject_valid),
    .inject_data_i(mem_inject_data),
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
    .external_producer_collision_i(mem_external_collision),
    .boundary_consume_o(mem_boundary_consume),
    .producer_valid_o(mem_producer_valid_o),
    .producer_data_o(mem_producer_data_o),
    .producer_stream_dir_o(mem_producer_direction_o),
    .producer_stream_idx_o(mem_producer_stream_o),
    .producer_boundary_o(mem_producer_boundary_o),
    .internal_mem_collision_o(mem_internal_collision),
    .bank_fault_valid_o(mem_bank_fault_valid),
    .bank_fault_code_o(mem_bank_fault_code),
    .bank_fault_tile_valid_o(mem_bank_fault_tile_valid),
    .bank_fault_tile_id_o(mem_bank_fault_tile_id),
    .bank_fault_row_o(mem_bank_fault_row),
    .group_fault_valid_o(mem_group_fault),
    .hemisphere_fault_valid_o(mem_fault_valid_o),
    .group_busy_o(mem_group_busy),
    .hemisphere_busy_o(mem_busy_unused)
  );

`ifndef SYNTHESIS
  initial begin
    if (!lpu_native_config_pkg::profile_valid(P_LPU_PROFILE)) $fatal(1,"illegal MEM P_LPU_PROFILE");
    if ((F % G) != 0 ||
        MEM_BOUNDARIES > 14 || COLUMNS != 16 || T != 4 ||
        STREAMS != 32 || SEGMENT_BITS != 64 || LOCAL_PRODUCERS < 2 ||
        LOCAL_CONSUMERS < 1 || COMPLETED_FIFO_DEPTH < 2)
      $fatal(1, "TEST_FAIL DMA Store vector-sink parameter contract violation");
  end
`endif
endmodule
