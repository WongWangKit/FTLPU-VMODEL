`timescale 1ns/1ps

bind ftlpu_sr_superlane_col_dir_lane lpu_srf_lane_input_checker #(
  .STREAMS(STREAMS),
  .LANES(LANES),
  .DATA_BITS(DATA_BITS),
  .LOCAL_PRODUCERS(LOCAL_PRODUCERS),
  .LOCAL_CONSUMERS(LOCAL_CONSUMERS)
) u_srf_input_checker (
  .clk_i(clk_i),
  .rst_ni(rst_ni),
  .upstream_valid_i(upstream_valid_i),
  .upstream_data_i(upstream_data_i),
  .inject_valid_i(inject_valid_i),
  .inject_data_i(inject_data_i),
  .consume_i(consume_i)
);

bind ftlpu_sr_superlane_col_dir lpu_srf_legacy_projection_checker #(
  .LANES(LANES),
  .FIRST_SEGMENTS(STREAMS),
  .SECOND_SEGMENTS(STREAMS),
  .FIRST_NAME("state_valid_o"),
  .SECOND_NAME("downstream_valid_o")
) u_srf_projection_checker (
  .clk_i(clk_i),
  .rst_ni(rst_ni),
  .first_valid_i(lane_state_valid_o),
  .second_valid_i(lane_downstream_valid_o)
);
