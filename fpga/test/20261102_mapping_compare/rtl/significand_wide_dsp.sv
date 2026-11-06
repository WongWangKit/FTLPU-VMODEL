// FPGA-only equivalent of nine chunk multiplies and CSA reconstruction.
module lpu_vxm_significand_multiplier(
  input logic enable_i,
  input logic [1:0] data_format_i,
  input logic [23:0] lhs_significand_i,rhs_significand_i,
  output logic [47:0] product_o,
  output logic [8:0] active_blocks_o
);
  import lpu_pkg::*;
  logic [23:0] lhs_masked,rhs_masked;
  (* use_dsp = "yes" *) logic [47:0] product;
  assign product=lhs_masked*rhs_masked;
  always_comb begin
    lhs_masked=0;rhs_masked=0;active_blocks_o=0;
    if(enable_i) begin
      case(data_format_i)
        VXM_FORMAT_BF16:begin lhs_masked={lhs_significand_i[23:16],16'b0};rhs_masked={rhs_significand_i[23:16],16'b0};end
        VXM_FORMAT_FP16:begin lhs_masked={lhs_significand_i[23:8],8'b0};rhs_masked={rhs_significand_i[23:8],8'b0};end
        VXM_FORMAT_FP32:begin lhs_masked=lhs_significand_i;rhs_masked=rhs_significand_i;end
        default:begin end
      endcase
    end
    for(integer a=0;a<3;a++) for(integer b=0;b<3;b++)
      active_blocks_o[a*3+b]=enable_i &&
        ((data_format_i==VXM_FORMAT_FP32)||
         ((data_format_i==VXM_FORMAT_FP16)&&(a>=1)&&(b>=1))||
         ((data_format_i==VXM_FORMAT_BF16)&&(a==2)&&(b==2))) &&
        (|lhs_significand_i[a*8+:8]) && (|rhs_significand_i[b*8+:8]);
    case(data_format_i)
      VXM_FORMAT_FP16:product_o={product[47:26],26'b0};
      VXM_FORMAT_FP32,VXM_FORMAT_BF16:product_o=product;
      default:product_o=0;
    endcase
  end
endmodule
