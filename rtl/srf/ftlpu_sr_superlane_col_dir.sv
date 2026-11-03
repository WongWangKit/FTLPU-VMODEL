`timescale 1ns/1ps

module ftlpu_sr_superlane_col_dir_lane #(
  parameter integer STREAMS        = 32,
  parameter integer LANES          = 8,
  parameter integer DATA_BITS      = 8,
  parameter integer LOCAL_PRODUCERS = 2,
  parameter integer LOCAL_CONSUMERS = 2
) (
  input  logic clk_i,
  input  logic rst_ni,

  input logic [(STREAMS)*LANES-1:0] upstream_valid_i,
  input  logic [STREAMS*LANES*DATA_BITS-1:0] upstream_data_i,

  output logic [(STREAMS)*LANES-1:0] state_valid_o,
  output logic [STREAMS*LANES*DATA_BITS-1:0] state_data_o,

  input logic [(LOCAL_CONSUMERS*STREAMS)*LANES-1:0] consume_i,
  output logic [(STREAMS)*LANES-1:0] downstream_valid_o,
  output logic [STREAMS*LANES*DATA_BITS-1:0] downstream_data_o,

  input logic [(LOCAL_PRODUCERS*STREAMS)*LANES-1:0] inject_valid_i,
  input  logic [LOCAL_PRODUCERS*STREAMS*LANES*DATA_BITS-1:0]
    inject_data_i,

  output logic collision_o,
  output logic invalid_consume_o
);
`ifndef SYNTHESIS
  initial begin : check_parameters
    if (STREAMS <= 0 || LANES <= 0 || DATA_BITS <= 0 || LOCAL_PRODUCERS <= 0 || LOCAL_CONSUMERS <= 0)
      $fatal(1, "%m dimensions and slot counts must be positive");
  end
`endif

  localparam integer CELL_COUNT = STREAMS * LANES;
  logic [CELL_COUNT-1:0] valid_state_q, next_valid, consume_any;
  logic [CELL_COUNT*DATA_BITS-1:0] data_state_q, next_data;
  integer cell_index, producer, consumer, candidate_count;
  logic [DATA_BITS-1:0] candidate_data;

  // Flat cell index = stream * LANES + lane. Each cell independently chooses
  // its unique next source. Disjoint producer masks merge without arbitration.
  always_comb begin
    next_valid = '0;
    next_data = '0;
    consume_any = '0;
    collision_o = 1'b0;
    invalid_consume_o = 1'b0;
    candidate_count = 0;
    candidate_data = '0;
    for (cell_index = 0; cell_index < CELL_COUNT; cell_index = cell_index + 1) begin
      candidate_count = 0;
      candidate_data = '0;
      if (upstream_valid_i[cell_index]) begin
        candidate_count = 1;
        candidate_data = upstream_data_i[cell_index*DATA_BITS +: DATA_BITS];
      end
      for (producer = 0; producer < LOCAL_PRODUCERS; producer = producer + 1) begin
        if (inject_valid_i[producer*CELL_COUNT + cell_index]) begin
          if (candidate_count == 0)
            candidate_data = inject_data_i[
              (producer*CELL_COUNT + cell_index)*DATA_BITS +: DATA_BITS];
          candidate_count = candidate_count + 1;
        end
      end
      if (candidate_count == 1) begin
        next_valid[cell_index] = 1'b1;
        next_data[cell_index*DATA_BITS +: DATA_BITS] = candidate_data;
      end else if (candidate_count >= 2) begin
        // No winner, even for equal payloads. Other cells still commit normally.
        collision_o = 1'b1;
      end
      for (consumer = 0; consumer < LOCAL_CONSUMERS; consumer = consumer + 1) begin
        if (consume_i[consumer*CELL_COUNT + cell_index]) begin
          consume_any[cell_index] = 1'b1;
          if (!valid_state_q[cell_index]) invalid_consume_o = 1'b1;
        end
      end
    end
  end

  // Only this leaf owns state. No holding, merging across cycles, or retry.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_state_q <= '0;
      data_state_q <= '0;
    end else begin
      valid_state_q <= next_valid;
      data_state_q <= next_data;
    end
  end
  assign state_valid_o = valid_state_q;
  assign state_data_o = data_state_q;
  assign downstream_valid_o = valid_state_q & ~consume_any;
  assign downstream_data_o = data_state_q;

endmodule

module ftlpu_sr_superlane_col_dir #(
  parameter integer STREAMS        = 32,
  parameter integer LANES          = 8,
  parameter integer DATA_BITS      = 8,
  parameter integer LOCAL_PRODUCERS = 2,
  parameter integer LOCAL_CONSUMERS = 2
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic [STREAMS-1:0] upstream_valid_i,
  input  logic [STREAMS*LANES*DATA_BITS-1:0] upstream_data_i,

  output logic [STREAMS-1:0] state_valid_o,
  output logic [STREAMS*LANES*DATA_BITS-1:0] state_data_o,

  input  logic [LOCAL_CONSUMERS*STREAMS-1:0] consume_i,
  output logic [STREAMS-1:0] downstream_valid_o,
  output logic [STREAMS*LANES*DATA_BITS-1:0] downstream_data_o,

  input  logic [LOCAL_PRODUCERS*STREAMS-1:0] inject_valid_i,
  input  logic [LOCAL_PRODUCERS*STREAMS*LANES*DATA_BITS-1:0]
    inject_data_i,

  output logic collision_o,
  output logic invalid_consume_o
);
  // Legacy segment interface: combinational projection of the lane core.
  logic [(STREAMS)*LANES-1:0] lane_upstream_valid_i;
  logic [(STREAMS)*LANES-1:0] lane_state_valid_o;
  logic [(LOCAL_CONSUMERS*STREAMS)*LANES-1:0] lane_consume_i;
  logic [(STREAMS)*LANES-1:0] lane_downstream_valid_o;
  logic [(LOCAL_PRODUCERS*STREAMS)*LANES-1:0] lane_inject_valid_i;
  for (genvar n_upstream_valid_i = 0; n_upstream_valid_i < (STREAMS); n_upstream_valid_i = n_upstream_valid_i + 1) begin : map_upstream_valid_i
    assign lane_upstream_valid_i[n_upstream_valid_i*LANES +: LANES] = {LANES{upstream_valid_i[n_upstream_valid_i]}};
  end
  for (genvar n_state_valid_o = 0; n_state_valid_o < (STREAMS); n_state_valid_o = n_state_valid_o + 1) begin : map_state_valid_o
    assign state_valid_o[n_state_valid_o] = lane_state_valid_o[n_state_valid_o*LANES];
  end
  for (genvar n_consume_i = 0; n_consume_i < (LOCAL_CONSUMERS*STREAMS); n_consume_i = n_consume_i + 1) begin : map_consume_i
    assign lane_consume_i[n_consume_i*LANES +: LANES] = {LANES{consume_i[n_consume_i]}};
  end
  for (genvar n_downstream_valid_o = 0; n_downstream_valid_o < (STREAMS); n_downstream_valid_o = n_downstream_valid_o + 1) begin : map_downstream_valid_o
    assign downstream_valid_o[n_downstream_valid_o] = lane_downstream_valid_o[n_downstream_valid_o*LANES];
  end
  for (genvar n_inject_valid_i = 0; n_inject_valid_i < (LOCAL_PRODUCERS*STREAMS); n_inject_valid_i = n_inject_valid_i + 1) begin : map_inject_valid_i
    assign lane_inject_valid_i[n_inject_valid_i*LANES +: LANES] = {LANES{inject_valid_i[n_inject_valid_i]}};
  end

  ftlpu_sr_superlane_col_dir_lane #(
    .STREAMS(STREAMS),
    .LANES(LANES),
    .DATA_BITS(DATA_BITS),
    .LOCAL_PRODUCERS(LOCAL_PRODUCERS),
    .LOCAL_CONSUMERS(LOCAL_CONSUMERS)
  ) u_lane (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .upstream_valid_i(lane_upstream_valid_i),
    .upstream_data_i(upstream_data_i),
    .state_valid_o(lane_state_valid_o),
    .state_data_o(state_data_o),
    .consume_i(lane_consume_i),
    .downstream_valid_o(lane_downstream_valid_o),
    .downstream_data_o(downstream_data_o),
    .inject_valid_i(lane_inject_valid_i),
    .inject_data_i(inject_data_i),
    .collision_o(collision_o),
    .invalid_consume_o(invalid_consume_o)
  );

endmodule
