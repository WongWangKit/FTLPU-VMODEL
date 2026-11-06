// Exact specialization: decoded FP16/BF16 significands have 13 low zero bits.
// Product remains 48-bit aligned; all original rounding/exception behavior retained.
module fpga_mxm_mul(
 input logic format_bf16_i,
 input logic [15:0] lhs_i,rhs_i,
 output logic [31:0] product_o
);
 import lpu_vxm_math_pkg::*;
 wire [31:0] a=format_bf16_i?{lhs_i,16'b0}:fp16_to_fp32(lhs_i);
 wire [31:0] b=format_bf16_i?{rhs_i,16'b0}:fp16_to_fp32(rhs_i);
 (* use_dsp = "yes" *) wire [21:0] significand_product;
 assign significand_product={1'b1,a[22:13]}*{1'b1,b[22:13]};
function automatic logic [31:0] finish_product(
  input logic [31:0] lhs,
  input logic [31:0] rhs,
  input logic [47:0] exact_product
);
  logic sign;
  logic [23:0] lhs_significand;
  logic [23:0] rhs_significand;
  logic [47:0] product;
  logic [23:0] significand;
  logic guard_bit;
  logic round_bit;
  logic sticky_bit;
  logic [24:0] rounded;
  integer exponent;
  begin
    sign = lhs[31] ^ rhs[31];
    if ((lhs[30:0] == 0) || (rhs[30:0] == 0))
      finish_product = {sign, 31'b0};
    else begin
      lhs_significand = {1'b1, lhs[22:0]};
      rhs_significand = {1'b1, rhs[22:0]};
      product = exact_product;
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
        finish_product = 32'h7fc00001;
      else if (exponent >= 255)
        finish_product = {sign, 8'hff, 23'b0};
      else
        finish_product = {
          sign, exponent[7:0], significand[22:0]};
    end
  end
endfunction
 assign product_o=finish_product(a,b,{significand_product,26'b0});
endmodule
