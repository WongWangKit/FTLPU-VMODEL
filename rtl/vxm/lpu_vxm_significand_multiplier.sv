module lpu_vxm_significand_multiplier (
  input  logic        enable_i,
  input  logic [1:0]  data_format_i,
  input  logic [23:0] lhs_significand_i,
  input  logic [23:0] rhs_significand_i,
  output logic [47:0] product_o,
  output logic [8:0]  active_blocks_o
);
  import lpu_pkg::*;

  logic [7:0] lhs_chunk [0:2];
  logic [7:0] rhs_chunk [0:2];
  logic [15:0] block_product [0:8];
  logic [47:0] shifted_product [0:8];
  logic [47:0] fp16_sum_low;
  logic [47:0] fp16_sum_high;
  logic [47:0] fp32_level1 [0:4];
  logic [47:0] fp32_level2 [0:2];
  logic [47:0] fp32_level3 [0:1];

  // Significands are left-aligned before entering this module:
  //   BF16 = {hidden+fraction[6:0], 16'b0}
  //   FP16 = {hidden+fraction[9:0], 13'b0}
  //   FP32 = {hidden+fraction[22:0]}
  // Thus BF16 needs block 8 only, FP16 needs blocks 4/5/7/8, and FP32
  // permits every block. Zero-valued chunks are additionally isolated.
  always_comb begin
    for (integer chunk = 0; chunk < 3; chunk++) begin
      lhs_chunk[chunk] = lhs_significand_i[chunk*8 +: 8];
      rhs_chunk[chunk] = rhs_significand_i[chunk*8 +: 8];
    end

    active_blocks_o = '0;
    for (integer lhs_index = 0; lhs_index < 3; lhs_index++) begin
      for (integer rhs_index = 0; rhs_index < 3; rhs_index++) begin
        integer block;
        logic format_enables_block;
        block = lhs_index*3 + rhs_index;
        case (data_format_i)
          VXM_FORMAT_BF16:
            format_enables_block =
              (lhs_index == 2) && (rhs_index == 2);
          VXM_FORMAT_FP16:
            format_enables_block =
              (lhs_index >= 1) && (rhs_index >= 1);
          VXM_FORMAT_FP32:
            format_enables_block = 1'b1;
          default:
            format_enables_block = 1'b0;
        endcase
        active_blocks_o[block] = enable_i && format_enables_block &&
          (|lhs_chunk[lhs_index]) && (|rhs_chunk[rhs_index]);
      end
    end
  end

  generate
    for (genvar lhs_block = 0; lhs_block < 3; lhs_block++) begin : g_lhs
      for (genvar rhs_block = 0; rhs_block < 3; rhs_block++) begin : g_rhs
        localparam integer BLOCK = lhs_block*3 + rhs_block;
        localparam integer SHIFT = (lhs_block+rhs_block)*8;
        lpu_vxm_mul8x8 u_mul8x8 (
          .enable_i(active_blocks_o[BLOCK]),
          .lhs_i(lhs_significand_i[lhs_block*8 +: 8]),
          .rhs_i(rhs_significand_i[rhs_block*8 +: 8]),
          .product_o(block_product[BLOCK])
        );
        always_comb begin
          shifted_product[BLOCK] =
            {{32{1'b0}}, block_product[BLOCK]} << SHIFT;
        end
      end
    end
  endgenerate

  // Balanced addition trees keep the RTL from describing a serial chain.
  // Narrow modes bypass every sum that cannot contain useful information.
  always_comb begin
    fp16_sum_low = shifted_product[4] + shifted_product[5];
    fp16_sum_high = shifted_product[7] + shifted_product[8];

    fp32_level1[0] = shifted_product[0] + shifted_product[1];
    fp32_level1[1] = shifted_product[2] + shifted_product[3];
    fp32_level1[2] = shifted_product[4] + shifted_product[5];
    fp32_level1[3] = shifted_product[6] + shifted_product[7];
    fp32_level1[4] = shifted_product[8];
    fp32_level2[0] = fp32_level1[0] + fp32_level1[1];
    fp32_level2[1] = fp32_level1[2] + fp32_level1[3];
    fp32_level2[2] = fp32_level1[4];
    fp32_level3[0] = fp32_level2[0] + fp32_level2[1];
    fp32_level3[1] = fp32_level2[2];

    case (data_format_i)
      VXM_FORMAT_BF16:
        product_o = shifted_product[8];
      VXM_FORMAT_FP16:
        product_o = fp16_sum_low + fp16_sum_high;
      VXM_FORMAT_FP32:
        product_o = fp32_level3[0] + fp32_level3[1];
      default:
        product_o = 48'b0;
    endcase
  end
endmodule
