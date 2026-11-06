module fpga_mxm_column(
 input logic format_bf16_i,
 input logic [127:0] activation_bits_i,weight_bits_i,
 output wire [31:0] partial_value_o
);
 import lpu_vxm_math_pkg::*;
 wire [31:0] sums[0:8];
 assign sums[0]=0;
 for(genvar k=0;k<8;k++) begin:g_mul
   wire [31:0] p;
   fpga_mxm_mul u_mul(.format_bf16_i,.lhs_i(activation_bits_i[k*16+:16]),
     .rhs_i(weight_bits_i[k*16+:16]),.product_o(p));
   assign sums[k+1]=fp32_add_rne(sums[k],p);
 end
 assign partial_value_o=sums[8];
endmodule
