`timescale 1ns/1ps

bind ftlpu_sr_hemisphere_fabric lpu_srf_legacy_projection_checker #(
  .LANES(LANES),
  .FIRST_SEGMENTS(2*SUPERLANES*STREAMS),
  .SECOND_SEGMENTS(2*COLUMNS*SUPERLANES*STREAMS),
  .FIRST_NAME("boundary_valid_o"),
  .SECOND_NAME("state_valid_o")
) u_srf_projection_checker (
  .clk_i(clk_i),
  .rst_ni(rst_ni),
  .first_valid_i(lane_boundary_valid_o),
  .second_valid_i(lane_state_valid_o)
);
