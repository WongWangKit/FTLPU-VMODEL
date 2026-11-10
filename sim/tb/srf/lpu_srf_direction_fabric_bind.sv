`timescale 1ns/1ps

bind ftlpu_sr_direction_fabric lpu_srf_legacy_projection_checker #(
  .LANES(LANES),
  .FIRST_SEGMENTS(SUPERLANES*STREAMS),
  .SECOND_SEGMENTS(COLUMNS*SUPERLANES*STREAMS),
  .FIRST_NAME("stream_valid_o"),
  .SECOND_NAME("state_valid_o")
) u_srf_projection_checker (
  .clk_i(clk_i),
  .rst_ni(rst_ni),
  .first_valid_i(lane_stream_valid_o),
  .second_valid_i(lane_state_valid_o)
);
