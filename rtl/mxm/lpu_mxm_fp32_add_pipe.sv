// Three register stages, II=1: align; add/subtract; normalize/RNE/pack.
// FP32 subnormals are preserved. NaNs are canonicalized. No ready/stall path.
// This first implementation uses exact leading-zero detection, not LZA.
module lpu_mxm_fp32_add_pipe #(
  parameter integer TAG_WIDTH = 16
) (
  input logic clk_i, rst_ni,
  input logic valid_i,
  input logic [31:0] lhs_i, rhs_i,
  input logic [TAG_WIDTH-1:0] tag_i,
  output logic valid_o,
  output logic [31:0] result_o,
  output logic [TAG_WIDTH-1:0] tag_o
);
  import lpu_mxm_supercell_math_pkg::*;
  logic a1_valid_q, a2_valid_q;
  logic [TAG_WIDTH-1:0] a1_tag_q, a2_tag_q;
  logic [26:0] a1_big_q, a1_small_q;
  logic a1_sign_q, a1_subtract_q, a1_direct_q;
  logic [31:0] a1_direct_result_q;
  logic signed [10:0] a1_exponent_q;
  logic [27:0] a2_magnitude_q;
  logic a2_sign_q, a2_direct_q;
  logic [31:0] a2_direct_result_q;
  logic signed [10:0] a2_exponent_q;
  logic [5:0] a2_shift_q;

  logic [26:0] big_d, small_d;
  logic sign_d, subtract_d, direct_d;
  logic [31:0] direct_result_d;
  logic signed [10:0] exponent_d;
  logic [27:0] magnitude_d;
  integer leading_d;
  logic [63:0] normalized_d;

  always_comb begin : align_inputs
    logic [31:0] big_operand, small_operand;
    logic lhs_nan, rhs_nan, lhs_inf, rhs_inf;
    integer big_exponent, small_exponent, distance;
    logic [63:0] shifted;
    big_operand = lhs_i[30:0] >= rhs_i[30:0] ? lhs_i : rhs_i;
    small_operand = lhs_i[30:0] >= rhs_i[30:0] ? rhs_i : lhs_i;
    lhs_nan = (&lhs_i[30:23]) && (|lhs_i[22:0]);
    rhs_nan = (&rhs_i[30:23]) && (|rhs_i[22:0]);
    lhs_inf = (&lhs_i[30:23]) && !(|lhs_i[22:0]);
    rhs_inf = (&rhs_i[30:23]) && !(|rhs_i[22:0]);
    direct_d = 1'b1;
    direct_result_d = FP32_QNAN;
    if (lhs_nan || rhs_nan || (lhs_inf && rhs_inf && lhs_i[31] != rhs_i[31]))
      direct_result_d = FP32_QNAN;
    else if (lhs_inf) direct_result_d = lhs_i;
    else if (rhs_inf) direct_result_d = rhs_i;
    else if (!(|lhs_i[30:0]) && !(|rhs_i[30:0]))
      direct_result_d = {lhs_i[31] & rhs_i[31], 31'b0};
    else if (!(|lhs_i[30:0])) direct_result_d = rhs_i;
    else if (!(|rhs_i[30:0])) direct_result_d = lhs_i;
    else direct_d = 1'b0;
    big_exponent = big_operand[30:23] == 0 ? 1 : int'(big_operand[30:23]);
    small_exponent = small_operand[30:23] == 0 ? 1 : int'(small_operand[30:23]);
    distance = big_exponent - small_exponent;
    big_d = {(|big_operand[30:23]), big_operand[22:0], 3'b0};
    shifted = shift_right_sticky64(
      {37'b0, (|small_operand[30:23]), small_operand[22:0], 3'b0}, distance);
    small_d = shifted[26:0];
    sign_d = big_operand[31];
    subtract_d = big_operand[31] != small_operand[31];
    exponent_d = 11'(big_exponent - 127);
    if (direct_d) begin big_d = 0; small_d = 0; end
  end

  always_comb begin
    magnitude_d = a1_subtract_q ?
      {1'b0,a1_big_q} - {1'b0,a1_small_q} :
      {1'b0,a1_big_q} + {1'b0,a1_small_q};
    leading_d = leading_one64({36'b0,magnitude_d});
    normalized_d = {36'b0,a2_magnitude_q} << a2_shift_q;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a1_valid_q <= 0; a2_valid_q <= 0; valid_o <= 0;
      a1_tag_q <= '0; a2_tag_q <= '0; tag_o <= '0;
      a1_big_q <= 0; a1_small_q <= 0; a1_sign_q <= 0;
      a1_subtract_q <= 0; a1_direct_q <= 0; a1_direct_result_q <= 0;
      a1_exponent_q <= 0;
      a2_magnitude_q <= 0; a2_sign_q <= 0; a2_direct_q <= 0;
      a2_direct_result_q <= 0; a2_exponent_q <= 0; a2_shift_q <= 0;
      result_o <= 0;
    end else begin
      a1_valid_q <= valid_i;
      a2_valid_q <= a1_valid_q;
      valid_o <= a2_valid_q;
      if (valid_i) begin
        a1_tag_q <= tag_i;
        a1_big_q <= big_d; a1_small_q <= small_d;
        a1_sign_q <= sign_d; a1_subtract_q <= subtract_d;
        a1_exponent_q <= exponent_d;
        a1_direct_q <= direct_d; a1_direct_result_q <= direct_result_d;
      end
      if (a1_valid_q) begin
        a2_tag_q <= a1_tag_q;
        a2_magnitude_q <= magnitude_d;
        a2_sign_q <= magnitude_d == 0 ? 1'b0 : a1_sign_q;
        a2_exponent_q <= a1_exponent_q + 11'(leading_d-26);
        a2_shift_q <= 6'(63-leading_d);
        a2_direct_q <= a1_direct_q;
        a2_direct_result_q <= a1_direct_result_q;
      end
      if (a2_valid_q) begin
        tag_o <= a2_tag_q;
        result_o <= a2_direct_q ? a2_direct_result_q :
          pack_fp32_rne(a2_sign_q, int'(a2_exponent_q), normalized_d);
      end
    end
  end
endmodule
