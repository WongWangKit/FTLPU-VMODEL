module lpu_vxm_shared_float_compare (
  input  logic [1:0]  data_format_i,
  input  logic [31:0] lhs_i,
  input  logic [31:0] rhs_i,

  output logic [31:0] lhs_sanitized_o,
  output logic [31:0] rhs_sanitized_o,
  output logic        lhs_magnitude_ge_o,
  output logic        magnitude_equal_o,
  output logic        lhs_less_o,
  output logic [31:0] max_result_o
);
  import lpu_pkg::*;
  import lpu_vxm_fp16_pkg::*;
  import lpu_vxm_math_pkg::*;

  localparam logic [31:0] FP32_CANONICAL_NAN = 32'h7fc00000;
  localparam logic [15:0] BF16_CANONICAL_NAN = 16'h7fc0;

  logic narrow_format;
  logic lhs_nan;
  logic rhs_nan;
  logic lhs_sign;
  logic rhs_sign;
  logic both_zero;
  logic low15_less;
  logic low15_equal;
  logic high16_less;
  logic high16_equal;
  logic magnitude_less;
  logic magnitude_equal;
  logic magnitude_greater;

  function automatic logic fp32_is_nan_local(input logic [31:0] value);
    fp32_is_nan_local =
      (value[30:23] == 8'hff) && (value[22:0] != 0);
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

  always_comb begin
    narrow_format = (data_format_i == VXM_FORMAT_FP16) ||
      (data_format_i == VXM_FORMAT_BF16);
    lhs_sanitized_o = 32'b0;
    rhs_sanitized_o = 32'b0;
    lhs_nan = 1'b0;
    rhs_nan = 1'b0;
    case (data_format_i)
      VXM_FORMAT_FP16: begin
        lhs_sanitized_o[15:0] = fp16_sanitize_ftz(lhs_i[15:0]);
        rhs_sanitized_o[15:0] = fp16_sanitize_ftz(rhs_i[15:0]);
        lhs_nan = fp16_is_nan(lhs_sanitized_o[15:0]);
        rhs_nan = fp16_is_nan(rhs_sanitized_o[15:0]);
      end
      VXM_FORMAT_BF16: begin
        lhs_sanitized_o[15:0] = bf16_sanitize_ftz(lhs_i[15:0]);
        rhs_sanitized_o[15:0] = bf16_sanitize_ftz(rhs_i[15:0]);
        lhs_nan = bf16_is_nan(lhs_sanitized_o[15:0]);
        rhs_nan = bf16_is_nan(rhs_sanitized_o[15:0]);
      end
      VXM_FORMAT_FP32: begin
        lhs_sanitized_o = fp32_sanitize_ftz_local(lhs_i);
        rhs_sanitized_o = fp32_sanitize_ftz_local(rhs_i);
        lhs_nan = fp32_is_nan_local(lhs_sanitized_o);
        rhs_nan = fp32_is_nan_local(rhs_sanitized_o);
      end
      default: begin
        lhs_sanitized_o = 32'b0;
        rhs_sanitized_o = 32'b0;
      end
    endcase

    // This low comparator is physically useful for every format. For FP16
    // and BF16 it covers the complete signless encoding; for FP32 it covers
    // the low portion of the 31-bit signless encoding.
    low15_less = lhs_sanitized_o[14:0] < rhs_sanitized_o[14:0];
    low15_equal = lhs_sanitized_o[14:0] == rhs_sanitized_o[14:0];
    high16_less = lhs_sanitized_o[30:15] < rhs_sanitized_o[30:15];
    high16_equal = lhs_sanitized_o[30:15] == rhs_sanitized_o[30:15];

    if (data_format_i == VXM_FORMAT_FP32) begin
      magnitude_less = high16_less || (high16_equal && low15_less);
      magnitude_equal = high16_equal && low15_equal;
    end else if (narrow_format) begin
      magnitude_less = low15_less;
      magnitude_equal = low15_equal;
    end else begin
      magnitude_less = 1'b0;
      magnitude_equal = 1'b1;
    end
    magnitude_greater = !magnitude_less && !magnitude_equal;
    lhs_magnitude_ge_o = !magnitude_less;
    magnitude_equal_o = magnitude_equal;

    lhs_sign = data_format_i == VXM_FORMAT_FP32 ?
      lhs_sanitized_o[31] : lhs_sanitized_o[15];
    rhs_sign = data_format_i == VXM_FORMAT_FP32 ?
      rhs_sanitized_o[31] : rhs_sanitized_o[15];
    both_zero = data_format_i == VXM_FORMAT_FP32 ?
      ((lhs_sanitized_o[30:0] == 0) &&
       (rhs_sanitized_o[30:0] == 0)) :
      ((lhs_sanitized_o[14:0] == 0) &&
       (rhs_sanitized_o[14:0] == 0));

    if (both_zero)
      lhs_less_o = 1'b0;
    else if (lhs_sign != rhs_sign)
      lhs_less_o = lhs_sign;
    else if (lhs_sign)
      lhs_less_o = magnitude_greater;
    else
      lhs_less_o = magnitude_less;

    if (lhs_nan) begin
      case (data_format_i)
        VXM_FORMAT_FP16: max_result_o = {16'b0, FP16_CANONICAL_NAN};
        VXM_FORMAT_BF16: max_result_o = {16'b0, BF16_CANONICAL_NAN};
        default: max_result_o = FP32_CANONICAL_NAN;
      endcase
    end else if (rhs_nan)
      max_result_o = lhs_sanitized_o;
    else
      max_result_o = lhs_less_o ? rhs_sanitized_o : lhs_sanitized_o;
  end
endmodule
