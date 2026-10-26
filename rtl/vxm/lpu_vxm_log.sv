// C3-class Log continuation. A single multiplier and a single Horner adder
// are selected by phase; low formats bypass unneeded polynomial stages.
// LUT row = {ln(c) UQ0.28, 1/c UQ1.21}, c=1+address/64.
module lpu_vxm_log (
  input logic clk_i, rst_ni,
  input logic valid_i,
  input logic [1:0] data_format_i,
  input logic operand_sign_i,
  input logic [7:0] operand_exponent_i,
  input logic [22:0] operand_fraction_i,
  input logic operand_zero_i, operand_inf_i, operand_nan_i,
  input logic lut_configured_i,
  output logic lut_read_valid_o,
  output logic [5:0] lut_read_address_o,
  input logic lut_read_valid_i,
  input logic [49:0] lut_read_data_i,
  output logic multiply_enable_o,
  output logic [31:0] multiply_lhs_o, multiply_rhs_o,
  input logic [31:0] multiply_product_i,
  output logic ready_o,
  output logic valid_o,
  output logic [31:0] result_o,
  output logic fault_o
);
  import lpu_pkg::*;
  import lpu_vxm_math_pkg::*;
  import lpu_vxm_log_math_pkg::*;

  typedef enum logic [2:0] {IDLE, REQUEST, WAIT_LUT, H0, H1, H2, RESTORE} state_t;
  state_t state_q;
  logic [1:0] format_q;
  logic lookup_q, direct_q, near_q;
  logic [31:0] direct_result_q, delta_q, u_q, h_q;
  logic [27:0] base_q;
  logic signed [8:0] exponent_q;
  logic [5:0] address_q;

  logic [31:0] operand32, input_delta, input_direct;
  logic [5:0] input_address;
  logic signed [8:0] input_exponent;
  logic input_near, input_special, input_lookup;
  logic [31:0] inverse_value, mul_lhs, mul_rhs, mul_product;
  logic [31:0] rounded_product, add_rhs, horner_value, restored_value;
  logic multiply_enable;
  logic signed [47:0] residual_fixed, exponent_fixed, base_fixed, sum_fixed;

  always_comb begin
    operand32 = 32'b0;
    input_address = 0;
    input_exponent = 0;
    input_delta = 0;
    case (data_format_i)
      VXM_FORMAT_FP16: begin
        operand32 = fp16_to_fp32({operand_sign_i, operand_exponent_i[4:0], operand_fraction_i[9:0]});
        input_exponent = $signed({4'b0,operand_exponent_i[4:0]}) - 9'sd15;
        input_address = operand_fraction_i[9:4];
        input_delta = log_fixed_to_fp32($signed({44'b0,operand_fraction_i[3:0]}),10);
      end
      VXM_FORMAT_BF16: begin
        operand32 = bf16_to_fp32({operand_sign_i, operand_exponent_i, operand_fraction_i[6:0]});
        input_exponent = $signed({1'b0,operand_exponent_i}) - 9'sd127;
        input_address = operand_fraction_i[6:1];
        input_delta = log_fixed_to_fp32($signed({47'b0,operand_fraction_i[0]}),7);
      end
      default: begin
        operand32 = {operand_sign_i,operand_exponent_i,operand_fraction_i};
        input_exponent = $signed({1'b0,operand_exponent_i}) - 9'sd127;
        input_address = operand_fraction_i[22:17];
        input_delta = log_fixed_to_fp32($signed({31'b0,operand_fraction_i[16:0]}),23);
      end
    endcase
    input_near = !operand_sign_i && !operand_zero_i && !operand_nan_i && !operand_inf_i &&
      (data_format_i == VXM_FORMAT_BF16 ?
        ((operand32 >= 32'h3f7e0000) && (operand32 <= 32'h3f810000)) :
        ((operand32 >= 32'h3f7c0000) && (operand32 <= 32'h3f820000)));
    if (input_near) begin
      if (operand32[30:23] == 8'd127)
        input_delta = log_fixed_to_fp32($signed({25'b0,operand32[22:0]}),23);
      else
        input_delta = log_fixed_to_fp32(-$signed(48'd8388608 - {25'b0,operand32[22:0]}),24);
      input_exponent = 0;
      input_address = 0;
    end
    input_special = operand_nan_i || operand_zero_i || operand_sign_i || operand_inf_i;
    input_direct = 32'h7fc00000;
    if (operand_nan_i) input_direct = 32'h7fc00000;
    else if (operand_zero_i) input_direct = 32'hff800000;
    else if (operand_sign_i) input_direct = 32'h7fc00000;
    else if (operand_inf_i) input_direct = 32'h7f800000;
    input_lookup = !input_special && !input_near;
  end

  always_comb begin
    ready_o = state_q == IDLE;
    lut_read_valid_o = state_q == REQUEST && lookup_q;
    lut_read_address_o = address_q;
    inverse_value = log_fixed_to_fp32(
      $signed({26'b0,log_active_inverse(lut_read_data_i[21:0],format_q)}),21);
    mul_lhs = 0; mul_rhs = 0; add_rhs = 0;
    multiply_enable = 1'b0;
    case (state_q)
      WAIT_LUT: begin
        multiply_enable = !direct_q && (!lookup_q || lut_read_valid_i);
        mul_lhs = delta_q;
        mul_rhs = near_q ? 32'h3f800000 : inverse_value;
      end
      H0: begin
        multiply_enable = !direct_q && format_q != VXM_FORMAT_BF16;
        mul_lhs = format_q == VXM_FORMAT_FP32 ? 32'hbe800000 : 32'hbf000000;
        mul_rhs = u_q;
        add_rhs = format_q == VXM_FORMAT_FP32 ? 32'h3eaaaaab : 32'h3f800000;
      end
      H1: begin
        multiply_enable = !direct_q && format_q == VXM_FORMAT_FP32;
        mul_lhs = h_q; mul_rhs = u_q; add_rhs = 32'hbf000000;
      end
      H2: begin
        multiply_enable = !direct_q && format_q == VXM_FORMAT_FP32;
        mul_lhs = h_q; mul_rhs = u_q; add_rhs = 32'h3f800000;
      end
      RESTORE: begin
        multiply_enable = !direct_q;
        mul_lhs = h_q; mul_rhs = u_q;
      end
      default: begin end
    endcase
    rounded_product = log_round_format(mul_product,format_q);
    horner_value = log_round_format(fp32_add_rne(rounded_product,add_rhs),format_q);
    residual_fixed = log_fp32_to_q40(rounded_product);
    base_fixed = $signed({8'b0,base_q,12'b0});
    exponent_fixed = $signed(exponent_q) * LOG_LN2_Q40;
    sum_fixed = exponent_fixed + base_fixed + residual_fixed;
    restored_value = log_fixed_to_fp32(sum_fixed,40);
    if (near_q) restored_value = rounded_product;
    if (direct_q) restored_value = direct_result_q;
  end

  assign multiply_enable_o = multiply_enable;
  assign multiply_lhs_o = mul_lhs;
  assign multiply_rhs_o = mul_rhs;
  assign mul_product = multiply_product_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE; format_q <= VXM_FORMAT_FP16;
      lookup_q <= 0; direct_q <= 0; near_q <= 0;
      direct_result_q <= 0; delta_q <= 0; u_q <= 0; h_q <= 0;
      base_q <= 0; exponent_q <= 0; address_q <= 0;
      valid_o <= 0; result_o <= 0; fault_o <= 0;
    end else begin
      valid_o <= 0; fault_o <= 0;
      case (state_q)
        IDLE: if (valid_i) begin
          format_q <= data_format_i;
          lookup_q <= input_lookup && lut_configured_i;
          direct_q <= input_special || (input_lookup && !lut_configured_i);
          near_q <= input_near;
          direct_result_q <= input_lookup && !lut_configured_i ? 32'h7fc00000 : input_direct;
          delta_q <= input_delta; exponent_q <= input_exponent;
          address_q <= input_address; base_q <= 0; u_q <= 0; h_q <= 0;
          fault_o <= input_lookup && !lut_configured_i;
          state_q <= REQUEST;
        end
        REQUEST: state_q <= WAIT_LUT;
        WAIT_LUT: if (!lookup_q || lut_read_valid_i) begin
          u_q <= direct_q ? 32'b0 : rounded_product;
          base_q <= lookup_q ? log_active_base(lut_read_data_i[49:22],format_q) : 28'b0;
          state_q <= H0;
        end
        H0: begin
          h_q <= format_q == VXM_FORMAT_BF16 ? 32'h3f800000 : horner_value;
          state_q <= H1;
        end
        H1: begin
          if (format_q == VXM_FORMAT_FP32) h_q <= horner_value;
          state_q <= H2;
        end
        H2: begin
          if (format_q == VXM_FORMAT_FP32) h_q <= horner_value;
          state_q <= RESTORE;
        end
        RESTORE: begin
          result_o <= log_pack_result(restored_value,format_q);
          valid_o <= 1'b1; state_q <= IDLE;
        end
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
