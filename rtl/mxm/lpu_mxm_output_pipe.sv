// One common registered output stage for FP32 passthrough and BF16 RNE.
// A 32-bit lane carries either FP32 or zero-extended BF16 in bits [15:0].
// This is the core interface, not final stream packing or destination routing.
module lpu_mxm_output_pipe #(
  parameter integer LANES=8,META_BITS=32
) (
  input logic clk_i,rst_ni,valid_i,bf16_i,
  input logic [LANES*32-1:0] data_i,
  input logic [META_BITS-1:0] meta_i,
  output logic valid_o,bf16_o,
  output logic [LANES*32-1:0] data_o,
  output logic [META_BITS-1:0] meta_o
);
  function automatic logic [15:0] to_bf16(input logic [31:0] value);
    logic increment;
    begin
      if(value[30:23]==8'hff) begin
        // Preserve infinity; force a quiet NaN even for a low-only payload.
        to_bf16=value[31:16] | ((|value[22:0])?16'h0040:16'h0000);
      end else begin
        // Round-to-nearest, ties-to-even. Includes subnormals, signed zero,
        // carry into the exponent and finite overflow to signed infinity.
        increment=value[15] && ((|value[14:0]) || value[16]);
        to_bf16=value[31:16]+{15'b0,increment};
      end
    end
  endfunction
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin valid_o<=0;bf16_o<=0;data_o<=0;meta_o<=0;end
    else begin
      valid_o<=valid_i;bf16_o<=valid_i && bf16_i;
      if(valid_i) begin
        meta_o<=meta_i;
        for(integer lane=0;lane<LANES;lane++)
          data_o[lane*32+:32]<=bf16_i?{16'b0,to_bf16(data_i[lane*32+:32])}:data_i[lane*32+:32];
      end
    end
  end
  initial if(LANES<1 || META_BITS<1) $fatal(1,"Invalid MXM output pipe configuration");
endmodule
