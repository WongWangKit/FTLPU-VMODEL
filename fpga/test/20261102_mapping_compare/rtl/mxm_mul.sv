// One exact scalar product used by the legacy MXM dot bank.
module fpga_mxm_mul(
 input logic format_bf16_i,
 input logic [15:0] lhs_i,rhs_i,
 output logic [31:0] product_o
);
 import lpu_vxm_math_pkg::*;
 wire [31:0] a=format_bf16_i?{lhs_i,16'b0}:fp16_to_fp32(lhs_i);
 wire [31:0] b=format_bf16_i?{rhs_i,16'b0}:fp16_to_fp32(rhs_i);
 assign product_o=fp32_multiply_rne(a,b);
endmodule
