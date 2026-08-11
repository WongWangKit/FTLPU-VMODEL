module lpu_vxm_control (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic [15:0] issue_valid_i,
  input  logic [16*128-1:0] issue_instruction_i,
  output logic [4*16-1:0] tile_valid_o,
  output logic [4*16*128-1:0] tile_instruction_o
);
  generate
    for (genvar alu = 0; alu < 16; alu++) begin : gen_alu
      logic [3:0] row_valid;
      logic [4*128-1:0] row_instruction;

      lpu_control_pipeline #(.WIDTH(128), .ROWS(4)) u_pipeline (
        .clk_i,
        .rst_ni,
        .issue_valid_i(issue_valid_i[alu]),
        .issue_payload_i(issue_instruction_i[alu*128 +: 128]),
        .row_valid_o(row_valid),
        .row_payload_o(row_instruction)
      );

      for (genvar tile = 0; tile < 4; tile++) begin : gen_route
        assign tile_valid_o[tile*16 + alu] = row_valid[tile];
        assign tile_instruction_o[(tile*16 + alu)*128 +: 128] =
          row_instruction[tile*128 +: 128];
      end
    end
  endgenerate
endmodule
