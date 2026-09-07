module lpu_vxm_shared_float_multiplier (
  input  logic        enable_i,
  input  logic [1:0]  data_format_i,
  input  logic [31:0] lhs_i,
  input  logic [31:0] rhs_i,
  output logic [31:0] result_o,
  output logic [8:0]  active_blocks_o
);
  import lpu_pkg::*;
  import lpu_vxm_fp16_pkg::*;
  import lpu_vxm_math_pkg::*;

  localparam logic [31:0] FP32_CANONICAL_NAN = 32'h7fc00000;

  logic [31:0] lhs_wide;
  logic [31:0] rhs_wide;
  logic [23:0] lhs_significand;
  logic [23:0] rhs_significand;
  logic [47:0] significand_product;
  logic        finite_multiply;
  logic [31:0] wide_result;

  function automatic logic fp32_is_nan_local(input logic [31:0] value);
    fp32_is_nan_local =
      (value[30:23] == 8'hff) && (value[22:0] != 0);
  endfunction

  function automatic logic fp32_is_inf_local(input logic [31:0] value);
    fp32_is_inf_local =
      (value[30:23] == 8'hff) && (value[22:0] == 0);
  endfunction

  function automatic logic [31:0] fp32_sanitize_ftz_local(
    input logic [31:0] value
  );
    begin
      if (fp32_is_nan_local(value))
        fp32_sanitize_ftz_local = FP32_CANONICAL_NAN;
      else if (value[30:23] == 0)
        fp32_sanitize_ftz_local = {value[31], 31'b0};
      else
        fp32_sanitize_ftz_local = value;
    end
  endfunction

  function automatic logic [31:0] finish_fp32_product(
    input logic [31:0] lhs,
    input logic [31:0] rhs,
    input logic [47:0] product
  );
    logic sign;
    logic [23:0] significand;
    logic guard_bit;
    logic round_bit;
    logic sticky_bit;
    logic [24:0] rounded;
    integer exponent;
    begin
      sign = lhs[31] ^ rhs[31];
      significand = '0;
      guard_bit = 1'b0;
      round_bit = 1'b0;
      sticky_bit = 1'b0;
      rounded = '0;
      exponent = 0;

      if (fp32_is_nan_local(lhs) || fp32_is_nan_local(rhs))
        finish_fp32_product = FP32_CANONICAL_NAN;
      else if ((fp32_is_inf_local(lhs) && (rhs[30:0] == 0)) ||
               (fp32_is_inf_local(rhs) && (lhs[30:0] == 0)))
        finish_fp32_product = FP32_CANONICAL_NAN;
      else if (fp32_is_inf_local(lhs) || fp32_is_inf_local(rhs))
        finish_fp32_product = {sign, 8'hff, 23'b0};
      else if ((lhs[30:0] == 0) || (rhs[30:0] == 0))
        finish_fp32_product = {sign, 31'b0};
      else begin
        exponent = lhs[30:23] + rhs[30:23] - 127;
        if (product[47]) begin
          significand = product[47:24];
          guard_bit = product[23];
          round_bit = product[22];
          sticky_bit = |product[21:0];
          exponent = exponent + 1;
        end else begin
          significand = product[46:23];
          guard_bit = product[22];
          round_bit = product[21];
          sticky_bit = |product[20:0];
        end

        rounded = {1'b0, significand};
        if (guard_bit && (round_bit || sticky_bit || significand[0]))
          rounded = rounded + 1'b1;
        if (rounded[24]) begin
          significand = rounded[24:1];
          exponent = exponent + 1;
        end else
          significand = rounded[23:0];

        if (exponent <= 0)
          finish_fp32_product = {sign, 31'b0};
        else if (exponent >= 255)
          finish_fp32_product = {sign, 8'hff, 23'b0};
        else
          finish_fp32_product = {
            sign, exponent[7:0], significand[22:0]};
      end
    end
  endfunction

  always_comb begin
    case (data_format_i)
      VXM_FORMAT_FP16: begin
        lhs_wide = fp16_to_fp32(fp16_sanitize_ftz(lhs_i[15:0]));
        rhs_wide = fp16_to_fp32(fp16_sanitize_ftz(rhs_i[15:0]));
      end
      VXM_FORMAT_BF16: begin
        lhs_wide = bf16_to_fp32(lhs_i[15:0]);
        rhs_wide = bf16_to_fp32(rhs_i[15:0]);
      end
      VXM_FORMAT_FP32: begin
        lhs_wide = fp32_sanitize_ftz_local(lhs_i);
        rhs_wide = fp32_sanitize_ftz_local(rhs_i);
      end
      default: begin
        lhs_wide = 32'b0;
        rhs_wide = 32'b0;
      end
    endcase

    lhs_significand = {1'b1, lhs_wide[22:0]};
    rhs_significand = {1'b1, rhs_wide[22:0]};
    finite_multiply = enable_i &&
      (lhs_wide[30:23] != 0) && (lhs_wide[30:23] != 8'hff) &&
      (rhs_wide[30:23] != 0) && (rhs_wide[30:23] != 8'hff);
    wide_result = finish_fp32_product(
      lhs_wide, rhs_wide, significand_product);

    case (data_format_i)
      VXM_FORMAT_FP16:
        result_o = {16'b0,
          fp16_sanitize_ftz(fp32_to_fp16(wide_result))};
      VXM_FORMAT_BF16:
        result_o = {16'b0, fp32_to_bf16_ftz(wide_result)};
      VXM_FORMAT_FP32:
        result_o = wide_result;
      default:
        result_o = 32'b0;
    endcase
  end

  lpu_vxm_significand_multiplier u_significand_multiplier (
    .enable_i(finite_multiply),
    .data_format_i,
    .lhs_significand_i(lhs_significand),
    .rhs_significand_i(rhs_significand),
    .product_o(significand_product),
    .active_blocks_o
  );
endmodule
