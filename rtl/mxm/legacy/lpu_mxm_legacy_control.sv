// Compatibility for the old slice only. New MXM uses lpu_mxm_control.
module lpu_mxm_legacy_control #(parameter integer TILES=4) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic load_valid_i,
  input  logic [47:0] load_instruction_i,
  input  logic dequant_valid_i,
  input  logic [15:0] dequant_instruction_i,
  input  logic compute_valid_i,
  input  logic [48:0] compute_instruction_i,
  output logic [TILES-1:0] load_row_valid_o,
  output logic [TILES*48-1:0] load_row_instruction_o,
  output logic [TILES-1:0] dequant_row_valid_o,
  output logic [TILES*16-1:0] dequant_row_instruction_o,
  output logic [TILES-1:0] compute_row_valid_o,
  output logic [TILES*49-1:0] compute_row_instruction_o
);
  lpu_control_pipeline #(.WIDTH(48), .ROWS(TILES)) u_load_pipeline (
    .clk_i,
    .rst_ni,
    .issue_valid_i(load_valid_i),
    .issue_payload_i(load_instruction_i),
    .row_valid_o(load_row_valid_o),
    .row_payload_o(load_row_instruction_o)
  );

  lpu_control_pipeline #(.WIDTH(16), .ROWS(TILES)) u_dequant_pipeline (
    .clk_i,
    .rst_ni,
    .issue_valid_i(dequant_valid_i),
    .issue_payload_i(dequant_instruction_i),
    .row_valid_o(dequant_row_valid_o),
    .row_payload_o(dequant_row_instruction_o)
  );

  lpu_control_pipeline #(.WIDTH(49), .ROWS(TILES)) u_compute_pipeline (
    .clk_i,
    .rst_ni,
    .issue_valid_i(compute_valid_i),
    .issue_payload_i(compute_instruction_i),
    .row_valid_o(compute_row_valid_o),
    .row_payload_o(compute_row_instruction_o)
  );
endmodule
