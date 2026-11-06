"""Specialize exact legacy 16-bit-input products, without altering FP32 addition."""
from run import EXP, REPO

def main():
    pkg=(REPO/'rtl/vxm/lpu_vxm_math_pkg.sv').read_text()
    start=pkg.index('function automatic logic [31:0] fp32_multiply_rne(')
    end=pkg.index('endfunction',start)+len('endfunction')
    fun=pkg[start:end]
    fun=fun.replace('fp32_multiply_rne','finish_product')
    fun=fun.replace('input logic [31:0] rhs\n','input logic [31:0] rhs,\n  input logic [47:0] exact_product\n')
    fun=fun.replace('product = lhs_significand * rhs_significand;','product = exact_product;')
    assert 'input logic [47:0] exact_product' in fun
    rtl="""// Exact specialization: decoded FP16/BF16 significands have 13 low zero bits.
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
"""+fun+"""
 assign product_o=finish_product(a,b,{significand_product,26'b0});
endmodule
"""
    (EXP/'rtl/mxm_mul_narrow.sv').write_text(rtl)
    (EXP/'rtl/mxm_column_narrow.sv').write_text("""module fpga_mxm_column(
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
""")
    (EXP/'rtl/mxm_dot_narrow.sv').write_text("""module lpu_mxm_dot_bank(
 input logic format_bf16_i,
 input logic [127:0] activation_bits_i,
 input logic [4095:0] weight_bits_i,
 output wire [1023:0] partial_values_o
);
 for(genvar c=0;c<32;c++) begin:g_column
   wire [127:0] weights;
   for(genvar k=0;k<8;k++) begin:g_weight
     assign weights[k*16+:16]=weight_bits_i[(((c/8)*8+k)*8+c%8)*16+:16];
   end
   fpga_mxm_column u_column(.format_bf16_i,.activation_bits_i,
     .weight_bits_i(weights),.partial_value_o(partial_values_o[c*32+:32]));
 end
endmodule
""")
    print('Generated exact 11x11 DSP product specialization and unchanged-order dot wrappers.')

if __name__=='__main__':main()
