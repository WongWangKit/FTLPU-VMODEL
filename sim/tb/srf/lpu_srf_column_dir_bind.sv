`timescale 1ns/1ps

bind ftlpu_sr_column_dir lpu_srf_legacy_projection_checker #(
  .LANES(LANES),
  .FIRST_SEGMENTS(SUPERLANES*STREAMS),
  .SECOND_SEGMENTS(SUPERLANES*STREAMS),
  .FIRST_NAME("column_valid_o"),
  .SECOND_NAME("column_state_valid_o")
) u_srf_projection_checker (
  .clk_i(clk_i),
  .rst_ni(rst_ni),
  .first_valid_i(lane_column_valid_o),
  .second_valid_i(lane_column_state_valid_o)
);
