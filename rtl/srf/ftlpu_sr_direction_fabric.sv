`timescale 1ns/1ps

module ftlpu_sr_direction_fabric_lane #(
  parameter integer COLUMNS         = 16,
  parameter integer SUPERLANES      = 4,
  parameter integer STREAMS         = 32,
  parameter integer LANES           = 8,
  parameter integer DATA_BITS       = 8,
  parameter integer LOCAL_PRODUCERS = 2,
  parameter integer LOCAL_CONSUMERS = 2,
  parameter integer DIRECTION       = 0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input logic [(SUPERLANES*STREAMS)*LANES-1:0] stream_valid_i,
  input  logic [SUPERLANES*STREAMS*LANES*DATA_BITS-1:0] stream_data_i,
  output logic [(SUPERLANES*STREAMS)*LANES-1:0] stream_valid_o,
  output logic [SUPERLANES*STREAMS*LANES*DATA_BITS-1:0] stream_data_o,
  input logic [(COLUMNS*SUPERLANES*LOCAL_PRODUCERS*STREAMS)*LANES-1:0] inject_valid_i,
  input  logic [COLUMNS*SUPERLANES*LOCAL_PRODUCERS*STREAMS*LANES*DATA_BITS-1:0]
    inject_data_i,
  input logic [(COLUMNS*SUPERLANES*LOCAL_CONSUMERS*STREAMS)*LANES-1:0] consume_i,
  output logic [COLUMNS*SUPERLANES-1:0] collision_o,
  output logic [COLUMNS*SUPERLANES-1:0] invalid_consume_o,
  output logic [(COLUMNS*SUPERLANES*STREAMS)*LANES-1:0] state_valid_o,
  output logic [COLUMNS*SUPERLANES*STREAMS*LANES*DATA_BITS-1:0]
    state_data_o
);
`ifndef SYNTHESIS
  initial begin : check_parameters
    if (COLUMNS <= 0 || SUPERLANES <= 0 || STREAMS <= 0 || LANES <= 0 || DATA_BITS <= 0 || LOCAL_PRODUCERS <= 0 || LOCAL_CONSUMERS <= 0)
      $fatal(1, "%m dimensions and slot counts must be positive");
    if (DIRECTION != 0 && DIRECTION != 1)
      $fatal(1, "%m DIRECTION must be East=0 or West=1");
  end
`endif
  localparam integer COLUMN_VALID_BITS = (SUPERLANES * STREAMS) * LANES;
  localparam integer COLUMN_DATA_BITS =
    SUPERLANES * STREAMS * LANES * DATA_BITS;
  localparam integer COLUMN_INJECT_VALID_BITS =
    (SUPERLANES * LOCAL_PRODUCERS * STREAMS) * LANES;
  localparam integer COLUMN_INJECT_DATA_BITS =
    SUPERLANES * LOCAL_PRODUCERS * STREAMS * LANES * DATA_BITS;
  localparam integer COLUMN_CONSUME_BITS =
    (SUPERLANES * LOCAL_CONSUMERS * STREAMS) * LANES;

  logic [COLUMNS*COLUMN_VALID_BITS-1:0] column_valid_i;
  logic [COLUMNS*COLUMN_VALID_BITS-1:0] column_valid_o;
  // Per-column nets retain exactly the same combinational hop mapping.
  // Avoid a wide packed intermediate alias: XSim 2023.2 O0 loses the T8
  // cross-column payload with the equivalent flat part-select connection.
  // Reproducer and both source identities are retained in the profile run.
  wire [COLUMN_DATA_BITS-1:0] column_data_i [0:COLUMNS-1];
  wire [COLUMN_DATA_BITS-1:0] column_data_o [0:COLUMNS-1];

  generate
    for (genvar column = 0; column < COLUMNS; column = column + 1) begin : gen_column
      if (DIRECTION == 0) begin : gen_east
        if (column == 0) begin : gen_boundary
          assign column_valid_i[
            column*COLUMN_VALID_BITS +: COLUMN_VALID_BITS] = stream_valid_i;
          assign column_data_i[column] = stream_data_i;
        end else begin : gen_link
          assign column_valid_i[
            column*COLUMN_VALID_BITS +: COLUMN_VALID_BITS] =
            column_valid_o[(column-1)*COLUMN_VALID_BITS +: COLUMN_VALID_BITS];
          assign column_data_i[column] =
            column_data_o[column-1];
        end
      end else begin : gen_west
        if (column == COLUMNS-1) begin : gen_boundary
          assign column_valid_i[
            column*COLUMN_VALID_BITS +: COLUMN_VALID_BITS] = stream_valid_i;
          assign column_data_i[column] = stream_data_i;
        end else begin : gen_link
          assign column_valid_i[
            column*COLUMN_VALID_BITS +: COLUMN_VALID_BITS] =
            column_valid_o[(column+1)*COLUMN_VALID_BITS +: COLUMN_VALID_BITS];
          assign column_data_i[column] =
            column_data_o[column+1];
        end
      end

      ftlpu_sr_column_dir_lane #(
        .SUPERLANES(SUPERLANES),
        .STREAMS(STREAMS),
        .LANES(LANES),
        .DATA_BITS(DATA_BITS),
        .LOCAL_PRODUCERS(LOCAL_PRODUCERS),
        .LOCAL_CONSUMERS(LOCAL_CONSUMERS)
      ) u_column (
        .clk_i,
        .rst_ni,
        .column_valid_i(
          column_valid_i[column*COLUMN_VALID_BITS +: COLUMN_VALID_BITS]),
        .column_data_i(
          column_data_i[column]),
        .column_valid_o(
          column_valid_o[column*COLUMN_VALID_BITS +: COLUMN_VALID_BITS]),
        .column_data_o(
          column_data_o[column]),
        .column_state_valid_o(
          state_valid_o[column*COLUMN_VALID_BITS +: COLUMN_VALID_BITS]),
        .column_state_data_o(
          state_data_o[column*COLUMN_DATA_BITS +: COLUMN_DATA_BITS]),
        .inject_valid_i(inject_valid_i[
          column*COLUMN_INJECT_VALID_BITS +: COLUMN_INJECT_VALID_BITS]),
        .inject_data_i(inject_data_i[
          column*COLUMN_INJECT_DATA_BITS +: COLUMN_INJECT_DATA_BITS]),
        .consume_i(consume_i[
          column*COLUMN_CONSUME_BITS +: COLUMN_CONSUME_BITS]),
        .collision_o(
          collision_o[column*SUPERLANES +: SUPERLANES]),
        .invalid_consume_o(
          invalid_consume_o[column*SUPERLANES +: SUPERLANES])
      );
    end
  endgenerate

  generate
    if (DIRECTION == 0) begin : gen_east_output
      assign stream_valid_o = column_valid_o[
        (COLUMNS-1)*COLUMN_VALID_BITS +: COLUMN_VALID_BITS];
      assign stream_data_o = column_data_o[COLUMNS-1];
    end else begin : gen_west_output
      assign stream_valid_o = column_valid_o[0 +: COLUMN_VALID_BITS];
      assign stream_data_o = column_data_o[0];
    end
  endgenerate
endmodule

module ftlpu_sr_direction_fabric #(
  parameter integer COLUMNS         = 16,
  parameter integer SUPERLANES      = 4,
  parameter integer STREAMS         = 32,
  parameter integer LANES           = 8,
  parameter integer DATA_BITS       = 8,
  parameter integer LOCAL_PRODUCERS = 2,
  parameter integer LOCAL_CONSUMERS = 2,
  parameter integer DIRECTION       = 0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic [SUPERLANES*STREAMS-1:0] stream_valid_i,
  input  logic [SUPERLANES*STREAMS*LANES*DATA_BITS-1:0] stream_data_i,
  output logic [SUPERLANES*STREAMS-1:0] stream_valid_o,
  output logic [SUPERLANES*STREAMS*LANES*DATA_BITS-1:0] stream_data_o,
  input  logic [COLUMNS*SUPERLANES*LOCAL_PRODUCERS*STREAMS-1:0]
    inject_valid_i,
  input  logic [COLUMNS*SUPERLANES*LOCAL_PRODUCERS*STREAMS*LANES*DATA_BITS-1:0]
    inject_data_i,
  input  logic [COLUMNS*SUPERLANES*LOCAL_CONSUMERS*STREAMS-1:0] consume_i,
  output logic [COLUMNS*SUPERLANES-1:0] collision_o,
  output logic [COLUMNS*SUPERLANES-1:0] invalid_consume_o,
  output logic [COLUMNS*SUPERLANES*STREAMS-1:0] state_valid_o,
  output logic [COLUMNS*SUPERLANES*STREAMS*LANES*DATA_BITS-1:0]
    state_data_o
);
  // Legacy segment interface: combinational projection of the lane core.
  logic [(SUPERLANES*STREAMS)*LANES-1:0] lane_stream_valid_i;
  logic [(SUPERLANES*STREAMS)*LANES-1:0] lane_stream_valid_o;
  logic [(COLUMNS*SUPERLANES*LOCAL_PRODUCERS*STREAMS)*LANES-1:0] lane_inject_valid_i;
  logic [(COLUMNS*SUPERLANES*LOCAL_CONSUMERS*STREAMS)*LANES-1:0] lane_consume_i;
  logic [(COLUMNS*SUPERLANES*STREAMS)*LANES-1:0] lane_state_valid_o;
  for (genvar n_stream_valid_i = 0; n_stream_valid_i < (SUPERLANES*STREAMS); n_stream_valid_i = n_stream_valid_i + 1) begin : map_stream_valid_i
    assign lane_stream_valid_i[n_stream_valid_i*LANES +: LANES] = {LANES{stream_valid_i[n_stream_valid_i]}};
  end
  for (genvar n_stream_valid_o = 0; n_stream_valid_o < (SUPERLANES*STREAMS); n_stream_valid_o = n_stream_valid_o + 1) begin : map_stream_valid_o
    assign stream_valid_o[n_stream_valid_o] = lane_stream_valid_o[n_stream_valid_o*LANES];
  end
  for (genvar n_inject_valid_i = 0; n_inject_valid_i < (COLUMNS*SUPERLANES*LOCAL_PRODUCERS*STREAMS); n_inject_valid_i = n_inject_valid_i + 1) begin : map_inject_valid_i
    assign lane_inject_valid_i[n_inject_valid_i*LANES +: LANES] = {LANES{inject_valid_i[n_inject_valid_i]}};
  end
  for (genvar n_consume_i = 0; n_consume_i < (COLUMNS*SUPERLANES*LOCAL_CONSUMERS*STREAMS); n_consume_i = n_consume_i + 1) begin : map_consume_i
    assign lane_consume_i[n_consume_i*LANES +: LANES] = {LANES{consume_i[n_consume_i]}};
  end
  for (genvar n_state_valid_o = 0; n_state_valid_o < (COLUMNS*SUPERLANES*STREAMS); n_state_valid_o = n_state_valid_o + 1) begin : map_state_valid_o
    assign state_valid_o[n_state_valid_o] = lane_state_valid_o[n_state_valid_o*LANES];
  end

  ftlpu_sr_direction_fabric_lane #(
    .COLUMNS(COLUMNS),
    .SUPERLANES(SUPERLANES),
    .STREAMS(STREAMS),
    .LANES(LANES),
    .DATA_BITS(DATA_BITS),
    .LOCAL_PRODUCERS(LOCAL_PRODUCERS),
    .LOCAL_CONSUMERS(LOCAL_CONSUMERS),
    .DIRECTION(DIRECTION)
  ) u_lane (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .stream_valid_i(lane_stream_valid_i),
    .stream_data_i(stream_data_i),
    .stream_valid_o(lane_stream_valid_o),
    .stream_data_o(stream_data_o),
    .inject_valid_i(lane_inject_valid_i),
    .inject_data_i(inject_data_i),
    .consume_i(lane_consume_i),
    .collision_o(collision_o),
    .invalid_consume_o(invalid_consume_o),
    .state_valid_o(lane_state_valid_o),
    .state_data_o(state_data_o)
  );

endmodule
