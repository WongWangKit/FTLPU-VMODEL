`timescale 1ns/1ps

// Simulation-only observers. Per-level bind files attach them without RTL edits.
module lpu_srf_lane_input_checker #(
  parameter integer STREAMS         = 32,
  parameter integer LANES           = 8,
  parameter integer DATA_BITS       = 8,
  parameter integer LOCAL_PRODUCERS = 2,
  parameter integer LOCAL_CONSUMERS = 2
) (
  input logic clk_i,
  input logic rst_ni,
  input logic [STREAMS*LANES-1:0] upstream_valid_i,
  input logic [STREAMS*LANES*DATA_BITS-1:0] upstream_data_i,
  input logic [LOCAL_PRODUCERS*STREAMS*LANES-1:0] inject_valid_i,
  input logic [LOCAL_PRODUCERS*STREAMS*LANES*DATA_BITS-1:0] inject_data_i,
  input logic [LOCAL_CONSUMERS*STREAMS*LANES-1:0] consume_i
);
  localparam integer CELL_COUNT = STREAMS * LANES;

  // Some legacy callers clock before their first reset. That undefined startup
  // interval is outside the comparison epoch; this flag is not functional state.
  bit checks_reset_seen = 1'b0;
  always @(negedge rst_ni)
    if (rst_ni === 1'b0) checks_reset_seen = 1'b1;

  // Sample before the active edge updates state. Invalid payload is unconstrained.
  always @(posedge clk_i) begin : check_lane_inputs
    if (checks_reset_seen && $isunknown(rst_ni))
      $fatal(1, "%m unknown reset");
    if (checks_reset_seen && rst_ni === 1'b1) begin
      if ($isunknown({upstream_valid_i, inject_valid_i, consume_i}))
        $fatal(1, "%m unknown valid/consume control");
      for (integer n = 0; n < CELL_COUNT; n = n + 1) begin
        if (upstream_valid_i[n] &&
            $isunknown(upstream_data_i[n*DATA_BITS +: DATA_BITS]))
          $fatal(1, "%m unknown valid upstream payload at cell %0d", n);
        for (integer p = 0; p < LOCAL_PRODUCERS; p = p + 1)
          if (inject_valid_i[p*CELL_COUNT+n] &&
              $isunknown(inject_data_i[(p*CELL_COUNT+n)*DATA_BITS +: DATA_BITS]))
            $fatal(1, "%m unknown valid injection payload at producer %0d cell %0d", p, n);
      end
    end
  end
endmodule

module lpu_srf_legacy_projection_checker #(
  parameter integer LANES           = 8,
  parameter integer FIRST_SEGMENTS  = 32,
  parameter integer SECOND_SEGMENTS = 32,
  parameter FIRST_NAME              = "state_valid_o",
  parameter SECOND_NAME             = "downstream_valid_o"
) (
  input logic clk_i,
  input logic rst_ni,
  input logic [FIRST_SEGMENTS*LANES-1:0] first_valid_i,
  input logic [SECOND_SEGMENTS*LANES-1:0] second_valid_i
);
  bit checks_reset_seen = 1'b0;
  always @(negedge rst_ni)
    if (rst_ni === 1'b0) checks_reset_seen = 1'b1;

  // Legacy segment projection is legal only for all-zero/all-one lane masks.
  always @(posedge clk_i) begin : check_legacy_projection
    if (checks_reset_seen && rst_ni === 1'b1) begin
      for (integer n = 0; n < FIRST_SEGMENTS; n = n + 1)
        if ((first_valid_i[n*LANES +: LANES] !== {LANES{1'b0}}) &&
            (first_valid_i[n*LANES +: LANES] !== {LANES{1'b1}}))
          $fatal(1, "%m partial/unknown mask on legacy %s segment %0d", FIRST_NAME, n);
      for (integer n = 0; n < SECOND_SEGMENTS; n = n + 1)
        if ((second_valid_i[n*LANES +: LANES] !== {LANES{1'b0}}) &&
            (second_valid_i[n*LANES +: LANES] !== {LANES{1'b1}}))
          $fatal(1, "%m partial/unknown mask on legacy %s segment %0d", SECOND_NAME, n);
    end
  end
endmodule

