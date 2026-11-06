// One of the 32 output columns in the original 8-input dot bank.
module fpga_mxm_column(
 input logic format_bf16_i,
 input logic [127:0] activation_bits_i,weight_bits_i,
 output wire [31:0] partial_value_o
);
 import lpu_vxm_math_pkg::*;
 wire [31:0] sums[0:8];
 assign sums[0]=0;
 for(genvar lane=0;lane<8;lane++) begin:g_lane
   wire [15:0] av=activation_bits_i[lane*16+:16];
   wire [15:0] bv=weight_bits_i[lane*16+:16];
   wire [31:0] a=format_bf16_i?{av,16'b0}:fp16_to_fp32(av);
   wire [31:0] b=format_bf16_i?{bv,16'b0}:fp16_to_fp32(bv);
   assign sums[lane+1]=fp32_add_rne(sums[lane],fp32_multiply_rne(a,b));
 end
 assign partial_value_o=sums[8];
endmodule
