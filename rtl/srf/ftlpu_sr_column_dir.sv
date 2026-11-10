`timescale 1ns/1ps

module ftlpu_sr_column_dir_lane #(
  parameter integer SUPERLANES      = 4,
  parameter integer STREAMS         = 32,
  parameter integer LANES           = 8,
  parameter integer DATA_BITS       = 8,
  parameter integer LOCAL_PRODUCERS = 2,
  parameter integer LOCAL_CONSUMERS = 2
) (
  input  logic clk_i,
  input  logic rst_ni,
  input logic [(SUPERLANES*STREAMS)*LANES-1:0] column_valid_i,
  input  logic [SUPERLANES*STREAMS*LANES*DATA_BITS-1:0] column_data_i,
  output logic [(SUPERLANES*STREAMS)*LANES-1:0] column_valid_o,
  output logic [SUPERLANES*STREAMS*LANES*DATA_BITS-1:0] column_data_o,
  output logic [(SUPERLANES*STREAMS)*LANES-1:0] column_state_valid_o,
  output logic [SUPERLANES*STREAMS*LANES*DATA_BITS-1:0]
    column_state_data_o,
  input logic [(SUPERLANES*LOCAL_PRODUCERS*STREAMS)*LANES-1:0] inject_valid_i,
  input  logic [SUPERLANES*LOCAL_PRODUCERS*STREAMS*LANES*DATA_BITS-1:0]
    inject_data_i,
  input logic [(SUPERLANES*LOCAL_CONSUMERS*STREAMS)*LANES-1:0] consume_i,
  output logic [SUPERLANES-1:0] collision_o,
  output logic [SUPERLANES-1:0] invalid_consume_o
);
`ifndef SYNTHESIS
  initial begin : check_parameters
    if (SUPERLANES <= 0 || STREAMS <= 0 || LANES <= 0 || DATA_BITS <= 0 || LOCAL_PRODUCERS <= 0 || LOCAL_CONSUMERS <= 0)
      $fatal(1, "%m dimensions and slot counts must be positive");
  end
`endif
  localparam integer SEGMENT_BITS = LANES * DATA_BITS;
  localparam integer LEAF_DATA_BITS = STREAMS * SEGMENT_BITS;
  localparam integer LEAF_INJECT_VALID_BITS = (LOCAL_PRODUCERS * STREAMS) * LANES;
  localparam integer LEAF_INJECT_DATA_BITS =
    LOCAL_PRODUCERS * STREAMS * SEGMENT_BITS;
  localparam integer LEAF_CONSUME_BITS = (LOCAL_CONSUMERS * STREAMS) * LANES;

  generate
    for (genvar superlane = 0; superlane < SUPERLANES;
         superlane = superlane + 1) begin : gen_superlane
      ftlpu_sr_superlane_col_dir_lane #(
        .STREAMS(STREAMS),
        .LANES(LANES),
        .DATA_BITS(DATA_BITS),
        .LOCAL_PRODUCERS(LOCAL_PRODUCERS),
        .LOCAL_CONSUMERS(LOCAL_CONSUMERS)
      ) u_leaf (
        .clk_i,
        .rst_ni,
        .upstream_valid_i(
          column_valid_i[superlane*STREAMS*LANES +: STREAMS*LANES]),
        .upstream_data_i(
          column_data_i[superlane*LEAF_DATA_BITS +: LEAF_DATA_BITS]),
        .state_valid_o(
          column_state_valid_o[superlane*STREAMS*LANES +: STREAMS*LANES]),
        .state_data_o(
          column_state_data_o[superlane*LEAF_DATA_BITS +: LEAF_DATA_BITS]),
        .consume_i(consume_i[
          superlane*LEAF_CONSUME_BITS +: LEAF_CONSUME_BITS]),
        .downstream_valid_o(
          column_valid_o[superlane*STREAMS*LANES +: STREAMS*LANES]),
        .downstream_data_o(
          column_data_o[superlane*LEAF_DATA_BITS +: LEAF_DATA_BITS]),
        .inject_valid_i(inject_valid_i[
          superlane*LEAF_INJECT_VALID_BITS +: LEAF_INJECT_VALID_BITS]),
        .inject_data_i(inject_data_i[
          superlane*LEAF_INJECT_DATA_BITS +: LEAF_INJECT_DATA_BITS]),
        .collision_o(collision_o[superlane]),
        .invalid_consume_o(invalid_consume_o[superlane])
      );
    end
  endgenerate
endmodule

module ftlpu_sr_column_dir #(
  parameter integer SUPERLANES      = 4,
  parameter integer STREAMS         = 32,
  parameter integer LANES           = 8,
  parameter integer DATA_BITS       = 8,
  parameter integer LOCAL_PRODUCERS = 2,
  parameter integer LOCAL_CONSUMERS = 2
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic [SUPERLANES*STREAMS-1:0] column_valid_i,
  input  logic [SUPERLANES*STREAMS*LANES*DATA_BITS-1:0] column_data_i,
  output logic [SUPERLANES*STREAMS-1:0] column_valid_o,
  output logic [SUPERLANES*STREAMS*LANES*DATA_BITS-1:0] column_data_o,
  output logic [SUPERLANES*STREAMS-1:0] column_state_valid_o,
  output logic [SUPERLANES*STREAMS*LANES*DATA_BITS-1:0]
    column_state_data_o,
  input  logic [SUPERLANES*LOCAL_PRODUCERS*STREAMS-1:0] inject_valid_i,
  input  logic [SUPERLANES*LOCAL_PRODUCERS*STREAMS*LANES*DATA_BITS-1:0]
    inject_data_i,
  input  logic [SUPERLANES*LOCAL_CONSUMERS*STREAMS-1:0] consume_i,
  output logic [SUPERLANES-1:0] collision_o,
  output logic [SUPERLANES-1:0] invalid_consume_o
);
  // Legacy segment interface: combinational projection of the lane core.
  logic [(SUPERLANES*STREAMS)*LANES-1:0] lane_column_valid_i;
  logic [(SUPERLANES*STREAMS)*LANES-1:0] lane_column_valid_o;
  logic [(SUPERLANES*STREAMS)*LANES-1:0] lane_column_state_valid_o;
  logic [(SUPERLANES*LOCAL_PRODUCERS*STREAMS)*LANES-1:0] lane_inject_valid_i;
  logic [(SUPERLANES*LOCAL_CONSUMERS*STREAMS)*LANES-1:0] lane_consume_i;
  for (genvar n_column_valid_i = 0; n_column_valid_i < (SUPERLANES*STREAMS); n_column_valid_i = n_column_valid_i + 1) begin : map_column_valid_i
    assign lane_column_valid_i[n_column_valid_i*LANES +: LANES] = {LANES{column_valid_i[n_column_valid_i]}};
  end
  for (genvar n_column_valid_o = 0; n_column_valid_o < (SUPERLANES*STREAMS); n_column_valid_o = n_column_valid_o + 1) begin : map_column_valid_o
    assign column_valid_o[n_column_valid_o] = lane_column_valid_o[n_column_valid_o*LANES];
  end
  for (genvar n_column_state_valid_o = 0; n_column_state_valid_o < (SUPERLANES*STREAMS); n_column_state_valid_o = n_column_state_valid_o + 1) begin : map_column_state_valid_o
    assign column_state_valid_o[n_column_state_valid_o] = lane_column_state_valid_o[n_column_state_valid_o*LANES];
  end
  for (genvar n_inject_valid_i = 0; n_inject_valid_i < (SUPERLANES*LOCAL_PRODUCERS*STREAMS); n_inject_valid_i = n_inject_valid_i + 1) begin : map_inject_valid_i
    assign lane_inject_valid_i[n_inject_valid_i*LANES +: LANES] = {LANES{inject_valid_i[n_inject_valid_i]}};
  end
  for (genvar n_consume_i = 0; n_consume_i < (SUPERLANES*LOCAL_CONSUMERS*STREAMS); n_consume_i = n_consume_i + 1) begin : map_consume_i
    assign lane_consume_i[n_consume_i*LANES +: LANES] = {LANES{consume_i[n_consume_i]}};
  end

  ftlpu_sr_column_dir_lane #(
    .SUPERLANES(SUPERLANES),
    .STREAMS(STREAMS),
    .LANES(LANES),
    .DATA_BITS(DATA_BITS),
    .LOCAL_PRODUCERS(LOCAL_PRODUCERS),
    .LOCAL_CONSUMERS(LOCAL_CONSUMERS)
  ) u_lane (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .column_valid_i(lane_column_valid_i),
    .column_data_i(column_data_i),
    .column_valid_o(lane_column_valid_o),
    .column_data_o(column_data_o),
    .column_state_valid_o(lane_column_state_valid_o),
    .column_state_data_o(column_state_data_o),
    .inject_valid_i(lane_inject_valid_i),
    .inject_data_i(inject_data_i),
    .consume_i(lane_consume_i),
    .collision_o(collision_o),
    .invalid_consume_o(invalid_consume_o)
  );

endmodule
