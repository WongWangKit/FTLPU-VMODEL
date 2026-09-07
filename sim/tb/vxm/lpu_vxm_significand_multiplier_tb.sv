`timescale 1ns/1ps

module lpu_vxm_significand_multiplier_tb;
  import lpu_pkg::*;

  logic        enable;
  logic [1:0]  data_format;
  logic [23:0] lhs_significand;
  logic [23:0] rhs_significand;
  wire [47:0] product;
  wire [8:0]  active_blocks;

  lpu_vxm_significand_multiplier dut (
    .enable_i(enable),
    .data_format_i(data_format),
    .lhs_significand_i(lhs_significand),
    .rhs_significand_i(rhs_significand),
    .product_o(product),
    .active_blocks_o(active_blocks)
  );

  task automatic check_product(
    input logic        request_enable,
    input logic [1:0]  format,
    input logic [23:0] lhs,
    input logic [23:0] rhs,
    input logic [8:0]  expected_blocks,
    input logic [47:0] expected_product
  );
    begin
      enable = request_enable;
      data_format = format;
      lhs_significand = lhs;
      rhs_significand = rhs;
      #1;
      if (active_blocks !== expected_blocks)
        $fatal(1,
          "format=%0d active blocks %b expected %b",
          format, active_blocks, expected_blocks);
      if (product !== expected_product)
        $fatal(1,
          "format=%0d product %h expected %h",
          format, product, expected_product);
    end
  endtask

  initial begin
    enable = 1'b0;
    data_format = VXM_FORMAT_FP16;
    lhs_significand = '0;
    rhs_significand = '0;
    #1;

    // BF16 has only its upper eight significand bits populated, so only P22
    // may switch and the result bypasses the partial-product addition tree.
    check_product(1'b1, VXM_FORMAT_BF16,
                  24'hab0000, 24'hcd0000, 9'b100000000,
                  48'hab0000 * 48'hcd0000);

    // FP16 has eleven populated bits in [23:13]. Blocks P11/P12/P21/P22
    // implement the equivalent 11x11 multiplication.
    check_product(1'b1, VXM_FORMAT_FP16,
                  24'habc000, 24'hd6a000, 9'b110110000,
                  48'habc000 * 48'hd6a000);

    // A general FP32 significand activates all nine 8x8 blocks.
    check_product(1'b1, VXM_FORMAT_FP32,
                  24'habcdef, 24'hd5a37b, 9'b111111111,
                  48'habcdef * 48'hd5a37b);

    // Chunk-zero detection also isolates unused blocks for an FP32 value
    // whose low sixteen significand bits happen to be zero.
    check_product(1'b1, VXM_FORMAT_FP32,
                  24'hab0000, 24'hcd0000, 9'b100000000,
                  48'hab0000 * 48'hcd0000);

    check_product(1'b0, VXM_FORMAT_FP32,
                  24'habcdef, 24'hd5a37b, 9'b000000000, 48'b0);
    check_product(1'b1, VXM_FORMAT_RESERVED,
                  24'habcdef, 24'hd5a37b, 9'b000000000, 48'b0);

    $display("LPU_VXM_SIGNIFICAND_MULTIPLIER_TB_PASS");
    $finish;
  end
endmodule
