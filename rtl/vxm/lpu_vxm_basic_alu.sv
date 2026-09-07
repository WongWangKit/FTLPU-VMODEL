module lpu_vxm_basic_alu (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        valid_i,
  input  logic [1:0]  data_format_i,
  input  logic [2:0]  opcode_i,
  input  logic [31:0] lhs_i,
  input  logic [31:0] rhs_i,
  output logic        ready_o,
  output logic        valid_o,
  output logic [31:0] result_o,
  output logic        illegal_opcode_o,
  output logic        result_collision_o
);
  import lpu_pkg::*;
  import lpu_vxm_fp16_pkg::*;
  import lpu_vxm_math_pkg::*;

  logic        multiply_valid_q;
  logic [31:0] multiply_result_q;
  logic [31:0] one_cycle_result;
  logic        wide_format;
  logic [31:0] wide_lhs_value;
  logic [31:0] wide_rhs_value;
  logic [31:0] wide_add_rhs;
  logic [31:0] wide_add_result;
  logic [31:0] shared_multiply_result;
  logic [31:0] wide_max_result;
  logic [31:0] wide_one_cycle_result;
  logic [31:0] compare_lhs_sanitized;
  logic [31:0] compare_rhs_sanitized;
  logic [31:0] compare_max_result;
  logic        compare_lhs_magnitude_ge;
  logic        basic_opcode;
  logic        multiply_opcode;

  function automatic logic fp32_is_nan(input logic [31:0] value);
    fp32_is_nan = (value[30:23] == 8'hff) && (value[22:0] != 0);
  endfunction

  function automatic logic [31:0] fp32_sanitize_ftz(
    input logic [31:0] value
  );
    begin
      if (fp32_is_nan(value))
        fp32_sanitize_ftz = 32'h7fc00000;
      else if (value[30:23] == 0)
        fp32_sanitize_ftz = {value[31], 31'b0};
      else
        fp32_sanitize_ftz = value;
    end
  endfunction

  function automatic logic [31:0] fp32_add_ftz(
    input logic [31:0] lhs_in,
    input logic [31:0] rhs_in,
    input logic        lhs_magnitude_ge
  );
    logic [31:0] lhs;
    logic [31:0] rhs;
    logic [31:0] sum;
    begin
      lhs = fp32_sanitize_ftz(lhs_in);
      rhs = fp32_sanitize_ftz(rhs_in);
      if (fp32_is_nan(lhs) || fp32_is_nan(rhs))
        fp32_add_ftz = 32'h7fc00000;
      else if ((lhs[30:23] == 8'hff) &&
               (rhs[30:23] == 8'hff) && (lhs[31] != rhs[31]))
        fp32_add_ftz = 32'h7fc00000;
      else if (lhs[30:23] == 8'hff)
        fp32_add_ftz = lhs;
      else if (rhs[30:23] == 8'hff)
        fp32_add_ftz = rhs;
      else begin
        sum = fp32_add_rne_ordered(lhs, rhs, lhs_magnitude_ge);
        // The shared legacy helper marks an underflowing finite sum with a
        // NaN sentinel. VXM defines FTZ, so turn that sentinel into zero.
        fp32_add_ftz = fp32_is_nan(sum) ? 32'b0 : sum;
      end
    end
  endfunction

  // FP16 and BF16 use the common low 15-bit magnitude comparator. FP32
  // extends it with a high 16-bit comparison. Its ordered result is shared
  // by ADD, SUBTRACT and MAX in this ALU.
  lpu_vxm_shared_float_compare u_shared_compare (
    .data_format_i,
    .lhs_i,
    .rhs_i,
    .lhs_sanitized_o(compare_lhs_sanitized),
    .rhs_sanitized_o(compare_rhs_sanitized),
    .lhs_magnitude_ge_o(compare_lhs_magnitude_ge),
    .magnitude_equal_o(),
    .lhs_less_o(),
    .max_result_o(compare_max_result)
  );

  always_comb begin
    basic_opcode = opcode_i <= VXM_LOCAL_MAX;
    multiply_opcode = opcode_i == VXM_LOCAL_MULTIPLY;
    ready_o = !valid_i || !basic_opcode || multiply_opcode ||
      !multiply_valid_q;
    illegal_opcode_o = valid_i && !basic_opcode;

    // BF16 and FP32 explicitly share one wide arithmetic cone. BF16 is
    // widened exactly by the input MUX and rounded only by the output MUX.
    // FP16 retains its independent narrow arithmetic path.
    wide_format = (data_format_i == VXM_FORMAT_BF16) ||
      (data_format_i == VXM_FORMAT_FP32);
    case (data_format_i)
      VXM_FORMAT_BF16: begin
        wide_lhs_value = bf16_to_fp32(compare_lhs_sanitized[15:0]);
        wide_rhs_value = bf16_to_fp32(compare_rhs_sanitized[15:0]);
      end
      VXM_FORMAT_FP32: begin
        wide_lhs_value = compare_lhs_sanitized;
        wide_rhs_value = compare_rhs_sanitized;
      end
      default: begin
        wide_lhs_value = 32'b0;
        wide_rhs_value = 32'b0;
      end
    endcase

    // ADD and SUBTRACT share this single FP32 adder. SUBTRACT is selected by
    // flipping the RHS sign before the shared operation.
    wide_add_rhs = opcode_i == VXM_LOCAL_SUBTRACT ?
      {~wide_rhs_value[31], wide_rhs_value[30:0]} : wide_rhs_value;
    wide_add_result = fp32_add_ftz(
      wide_lhs_value, wide_add_rhs, compare_lhs_magnitude_ge);
    wide_max_result = data_format_i == VXM_FORMAT_BF16 ?
      bf16_to_fp32(compare_max_result[15:0]) : compare_max_result;
    wide_one_cycle_result = 32'b0;
    case (opcode_i)
      VXM_LOCAL_BYPASS:   wide_one_cycle_result = wide_lhs_value;
      VXM_LOCAL_ADD,
      VXM_LOCAL_SUBTRACT: wide_one_cycle_result = wide_add_result;
      VXM_LOCAL_NEGATE: begin
        wide_one_cycle_result = wide_lhs_value;
        wide_one_cycle_result[31] = ~wide_one_cycle_result[31];
      end
      VXM_LOCAL_MAX:      wide_one_cycle_result = wide_max_result;
      default:            wide_one_cycle_result = 32'b0;
    endcase

    one_cycle_result = 32'b0;
    if (wide_format) begin
      if (data_format_i == VXM_FORMAT_BF16)
        one_cycle_result = {16'b0,
          fp32_to_bf16_ftz(wide_one_cycle_result)};
      else
        one_cycle_result = wide_one_cycle_result;
    end else begin
      case (opcode_i)
        VXM_LOCAL_BYPASS:
          one_cycle_result[15:0] = compare_lhs_sanitized[15:0];
        VXM_LOCAL_ADD:
          one_cycle_result[15:0] =
            fp16_add_rne_ftz_ordered(
              compare_lhs_sanitized[15:0],
              compare_rhs_sanitized[15:0],
              compare_lhs_magnitude_ge);
        VXM_LOCAL_SUBTRACT:
          one_cycle_result[15:0] =
            fp16_add_rne_ftz_ordered(
              compare_lhs_sanitized[15:0],
              {~compare_rhs_sanitized[15],
               compare_rhs_sanitized[14:0]},
              compare_lhs_magnitude_ge);
        VXM_LOCAL_NEGATE: begin
          one_cycle_result[15:0] = compare_lhs_sanitized[15:0];
          one_cycle_result[15] = ~one_cycle_result[15];
        end
        VXM_LOCAL_MAX:
          one_cycle_result[15:0] = compare_max_result[15:0];
        default: one_cycle_result = 32'b0;
      endcase
    end
  end

  // All three formats share the configurable significand multiplier. Format
  // controls select how many 8x8 blocks are active; result formatting remains
  // inside the multiplier wrapper so this sequential interface is unchanged.
  lpu_vxm_shared_float_multiplier u_shared_multiplier (
    .enable_i(valid_i && multiply_opcode),
    .data_format_i,
    .lhs_i,
    .rhs_i,
    .result_o(shared_multiply_result),
    .active_blocks_o()
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      multiply_valid_q <= 1'b0;
      multiply_result_q <= 32'b0;
      valid_o <= 1'b0;
      result_o <= 32'b0;
      result_collision_o <= 1'b0;
    end else begin
      valid_o <= 1'b0;
      result_collision_o <= 1'b0;

      if (multiply_valid_q) begin
        valid_o <= 1'b1;
        result_o <= multiply_result_q;
      end
      multiply_valid_q <= 1'b0;

      if (valid_i && basic_opcode) begin
        if (multiply_opcode) begin
          multiply_valid_q <= 1'b1;
          multiply_result_q <= shared_multiply_result;
        end else if (multiply_valid_q) begin
          // The older multiply owns this cycle. The caller must retain the
          // new request while ready_o is low.
          result_collision_o <= 1'b1;
        end else begin
          valid_o <= 1'b1;
          result_o <= one_cycle_result;
        end
      end
    end
  end
endmodule
