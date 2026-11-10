`timescale 1ns/1ps

module ftlpu_sr_fabric_lane #(
  parameter integer HEMISPHERES     = 2,
  parameter integer COLUMNS         = 16,
  parameter integer SUPERLANES      = 4,
  parameter integer STREAMS         = 32,
  parameter integer LANES           = 8,
  parameter integer DATA_BITS       = 8,
  parameter integer LOCAL_PRODUCERS = 2,
  parameter integer LOCAL_CONSUMERS = 2
) (
  input  logic clk_i,
  input  logic rst_ni,
  input logic [(HEMISPHERES*2*SUPERLANES*STREAMS)*LANES-1:0] boundary_valid_i,
  input  logic [HEMISPHERES*2*SUPERLANES*STREAMS*LANES*DATA_BITS-1:0]
    boundary_data_i,
  output logic [(HEMISPHERES*2*SUPERLANES*STREAMS)*LANES-1:0] boundary_valid_o,
  output logic [HEMISPHERES*2*SUPERLANES*STREAMS*LANES*DATA_BITS-1:0]
    boundary_data_o,
  input logic [(HEMISPHERES*2*COLUMNS*SUPERLANES*LOCAL_PRODUCERS*STREAMS)*LANES-1:0] inject_valid_i,
  input  logic [HEMISPHERES*2*COLUMNS*SUPERLANES*LOCAL_PRODUCERS*STREAMS*LANES*DATA_BITS-1:0]
    inject_data_i,
  input logic [(HEMISPHERES*2*COLUMNS*SUPERLANES*LOCAL_CONSUMERS*STREAMS)*LANES-1:0] consume_i,
  output logic [HEMISPHERES*2*COLUMNS*SUPERLANES-1:0] collision_o,
  output logic [HEMISPHERES*2*COLUMNS*SUPERLANES-1:0] invalid_consume_o,
  output logic [(HEMISPHERES*2*COLUMNS*SUPERLANES*STREAMS)*LANES-1:0] state_valid_o,
  output logic [HEMISPHERES*2*COLUMNS*SUPERLANES*STREAMS*LANES*DATA_BITS-1:0]
    state_data_o
);
`ifndef SYNTHESIS
  initial begin : check_parameters
    if (HEMISPHERES <= 0 || COLUMNS <= 0 || SUPERLANES <= 0 || STREAMS <= 0 || LANES <= 0 || DATA_BITS <= 0 || LOCAL_PRODUCERS <= 0 || LOCAL_CONSUMERS <= 0)
      $fatal(1, "%m dimensions and slot counts must be positive");
  end
`endif
  localparam integer HEMI_BOUNDARY_VALID_BITS = (2 * SUPERLANES * STREAMS) * LANES;
  localparam integer HEMI_BOUNDARY_DATA_BITS =
    2 * SUPERLANES * STREAMS * LANES * DATA_BITS;
  localparam integer HEMI_INJECT_VALID_BITS =
    (2 * COLUMNS * SUPERLANES * LOCAL_PRODUCERS * STREAMS) * LANES;
  localparam integer HEMI_INJECT_DATA_BITS =
    2 * COLUMNS * SUPERLANES * LOCAL_PRODUCERS * STREAMS * LANES * DATA_BITS;
  localparam integer HEMI_CONSUME_BITS =
    (2 * COLUMNS * SUPERLANES * LOCAL_CONSUMERS * STREAMS) * LANES;
  localparam integer HEMI_STATUS_BITS = 2 * COLUMNS * SUPERLANES;
  localparam integer HEMI_STATE_VALID_BITS =
    (2 * COLUMNS * SUPERLANES * STREAMS) * LANES;
  localparam integer HEMI_STATE_DATA_BITS =
    2 * COLUMNS * SUPERLANES * STREAMS * LANES * DATA_BITS;

  generate
    for (genvar hemisphere = 0; hemisphere < HEMISPHERES;
         hemisphere = hemisphere + 1) begin : gen_hemisphere
      ftlpu_sr_hemisphere_fabric_lane #(
        .COLUMNS(COLUMNS),
        .SUPERLANES(SUPERLANES),
        .STREAMS(STREAMS),
        .LANES(LANES),
        .DATA_BITS(DATA_BITS),
        .LOCAL_PRODUCERS(LOCAL_PRODUCERS),
        .LOCAL_CONSUMERS(LOCAL_CONSUMERS)
      ) u_hemisphere (
        .clk_i,
        .rst_ni,
        .boundary_valid_i(boundary_valid_i[
          hemisphere*HEMI_BOUNDARY_VALID_BITS +: HEMI_BOUNDARY_VALID_BITS]),
        .boundary_data_i(boundary_data_i[
          hemisphere*HEMI_BOUNDARY_DATA_BITS +: HEMI_BOUNDARY_DATA_BITS]),
        .boundary_valid_o(boundary_valid_o[
          hemisphere*HEMI_BOUNDARY_VALID_BITS +: HEMI_BOUNDARY_VALID_BITS]),
        .boundary_data_o(boundary_data_o[
          hemisphere*HEMI_BOUNDARY_DATA_BITS +: HEMI_BOUNDARY_DATA_BITS]),
        .inject_valid_i(inject_valid_i[
          hemisphere*HEMI_INJECT_VALID_BITS +: HEMI_INJECT_VALID_BITS]),
        .inject_data_i(inject_data_i[
          hemisphere*HEMI_INJECT_DATA_BITS +: HEMI_INJECT_DATA_BITS]),
        .consume_i(consume_i[
          hemisphere*HEMI_CONSUME_BITS +: HEMI_CONSUME_BITS]),
        .collision_o(collision_o[
          hemisphere*HEMI_STATUS_BITS +: HEMI_STATUS_BITS]),
        .invalid_consume_o(invalid_consume_o[
          hemisphere*HEMI_STATUS_BITS +: HEMI_STATUS_BITS]),
        .state_valid_o(state_valid_o[
          hemisphere*HEMI_STATE_VALID_BITS +: HEMI_STATE_VALID_BITS]),
        .state_data_o(state_data_o[
          hemisphere*HEMI_STATE_DATA_BITS +: HEMI_STATE_DATA_BITS])
      );
    end
  endgenerate
endmodule

module ftlpu_sr_fabric #(
  parameter integer HEMISPHERES     = 2,
  parameter integer COLUMNS         = 16,
  parameter integer SUPERLANES      = 4,
  parameter integer STREAMS         = 32,
  parameter integer LANES           = 8,
  parameter integer DATA_BITS       = 8,
  parameter integer LOCAL_PRODUCERS = 2,
  parameter integer LOCAL_CONSUMERS = 2
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic [HEMISPHERES*2*SUPERLANES*STREAMS-1:0] boundary_valid_i,
  input  logic [HEMISPHERES*2*SUPERLANES*STREAMS*LANES*DATA_BITS-1:0]
    boundary_data_i,
  output logic [HEMISPHERES*2*SUPERLANES*STREAMS-1:0] boundary_valid_o,
  output logic [HEMISPHERES*2*SUPERLANES*STREAMS*LANES*DATA_BITS-1:0]
    boundary_data_o,
  input  logic [HEMISPHERES*2*COLUMNS*SUPERLANES*LOCAL_PRODUCERS*STREAMS-1:0]
    inject_valid_i,
  input  logic [HEMISPHERES*2*COLUMNS*SUPERLANES*LOCAL_PRODUCERS*STREAMS*LANES*DATA_BITS-1:0]
    inject_data_i,
  input  logic [HEMISPHERES*2*COLUMNS*SUPERLANES*LOCAL_CONSUMERS*STREAMS-1:0]
    consume_i,
  output logic [HEMISPHERES*2*COLUMNS*SUPERLANES-1:0] collision_o,
  output logic [HEMISPHERES*2*COLUMNS*SUPERLANES-1:0] invalid_consume_o,
  output logic [HEMISPHERES*2*COLUMNS*SUPERLANES*STREAMS-1:0]
    state_valid_o,
  output logic [HEMISPHERES*2*COLUMNS*SUPERLANES*STREAMS*LANES*DATA_BITS-1:0]
    state_data_o
);
  // Legacy segment interface: combinational projection of the lane core.
  logic [(HEMISPHERES*2*SUPERLANES*STREAMS)*LANES-1:0] lane_boundary_valid_i;
  logic [(HEMISPHERES*2*SUPERLANES*STREAMS)*LANES-1:0] lane_boundary_valid_o;
  logic [(HEMISPHERES*2*COLUMNS*SUPERLANES*LOCAL_PRODUCERS*STREAMS)*LANES-1:0] lane_inject_valid_i;
  logic [(HEMISPHERES*2*COLUMNS*SUPERLANES*LOCAL_CONSUMERS*STREAMS)*LANES-1:0] lane_consume_i;
  logic [(HEMISPHERES*2*COLUMNS*SUPERLANES*STREAMS)*LANES-1:0] lane_state_valid_o;
  for (genvar n_boundary_valid_i = 0; n_boundary_valid_i < (HEMISPHERES*2*SUPERLANES*STREAMS); n_boundary_valid_i = n_boundary_valid_i + 1) begin : map_boundary_valid_i
    assign lane_boundary_valid_i[n_boundary_valid_i*LANES +: LANES] = {LANES{boundary_valid_i[n_boundary_valid_i]}};
  end
  for (genvar n_boundary_valid_o = 0; n_boundary_valid_o < (HEMISPHERES*2*SUPERLANES*STREAMS); n_boundary_valid_o = n_boundary_valid_o + 1) begin : map_boundary_valid_o
    assign boundary_valid_o[n_boundary_valid_o] = lane_boundary_valid_o[n_boundary_valid_o*LANES];
  end
  for (genvar n_inject_valid_i = 0; n_inject_valid_i < (HEMISPHERES*2*COLUMNS*SUPERLANES*LOCAL_PRODUCERS*STREAMS); n_inject_valid_i = n_inject_valid_i + 1) begin : map_inject_valid_i
    assign lane_inject_valid_i[n_inject_valid_i*LANES +: LANES] = {LANES{inject_valid_i[n_inject_valid_i]}};
  end
  for (genvar n_consume_i = 0; n_consume_i < (HEMISPHERES*2*COLUMNS*SUPERLANES*LOCAL_CONSUMERS*STREAMS); n_consume_i = n_consume_i + 1) begin : map_consume_i
    assign lane_consume_i[n_consume_i*LANES +: LANES] = {LANES{consume_i[n_consume_i]}};
  end
  for (genvar n_state_valid_o = 0; n_state_valid_o < (HEMISPHERES*2*COLUMNS*SUPERLANES*STREAMS); n_state_valid_o = n_state_valid_o + 1) begin : map_state_valid_o
    assign state_valid_o[n_state_valid_o] = lane_state_valid_o[n_state_valid_o*LANES];
  end

  ftlpu_sr_fabric_lane #(
    .HEMISPHERES(HEMISPHERES),
    .COLUMNS(COLUMNS),
    .SUPERLANES(SUPERLANES),
    .STREAMS(STREAMS),
    .LANES(LANES),
    .DATA_BITS(DATA_BITS),
    .LOCAL_PRODUCERS(LOCAL_PRODUCERS),
    .LOCAL_CONSUMERS(LOCAL_CONSUMERS)
  ) u_lane (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .boundary_valid_i(lane_boundary_valid_i),
    .boundary_data_i(boundary_data_i),
    .boundary_valid_o(lane_boundary_valid_o),
    .boundary_data_o(boundary_data_o),
    .inject_valid_i(lane_inject_valid_i),
    .inject_data_i(inject_data_i),
    .consume_i(lane_consume_i),
    .collision_o(collision_o),
    .invalid_consume_o(invalid_consume_o),
    .state_valid_o(lane_state_valid_o),
    .state_data_o(state_data_o)
  );

endmodule
