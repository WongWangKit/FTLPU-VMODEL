module lpu_mxm_dot_bank(
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
