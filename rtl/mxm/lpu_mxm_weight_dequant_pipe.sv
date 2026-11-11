// Load-only INT8 -> BF16 conversion. D1 subtract/decode, D2 exact 8x8
// product and normalization-shift detection. D3 shift/RNE feeds the Supercell
// weight register, the third register boundary (no extra output register).
// Parameter commands load paired scale/zero buffers; D1 snapshots their values.
// Weight and parameter commands consume separate fixed byte streams. No general
// FP32 multiplier, integer-to-BF16 intermediate, LUT or division is used.
module lpu_mxm_weight_dequant_pipe #(
  parameter integer LANES=lpu_mxm_config_pkg::CELL_K,
  parameter integer STREAMS=lpu_mxm_config_pkg::WEIGHT_STREAM_COUNT,
  parameter integer Q_STREAM=lpu_mxm_config_pkg::WEIGHT_Q_STREAM,
  parameter integer SCALE_LO_STREAM=lpu_mxm_config_pkg::WEIGHT_SCALE_LO_STREAM,
  parameter integer SCALE_HI_STREAM=lpu_mxm_config_pkg::WEIGHT_SCALE_HI_STREAM,
  parameter integer ZERO_STREAM=lpu_mxm_config_pkg::WEIGHT_ZERO_STREAM,
  parameter bit ZERO_ENABLE=lpu_mxm_config_pkg::WEIGHT_ZERO_POINT_ENABLE
) (
  input logic clk_i,rst_ni,run_i,request_i,buffer_i,
  input logic param_write_i,param_write_buffer_i,param_buffer_i,
  input logic [STREAMS*LANES-1:0] stream_valid_i,
  input logic [STREAMS*LANES*8-1:0] stream_i,
  output logic [STREAMS*LANES-1:0] consume_o,
  output wire accepted_o,valid_o,buffer_o,
  output wire param_accepted_o,
  output wire [1:0] param_ready_o,
  output logic [LANES*16-1:0] weight_bf16_o,
  output logic fault_o
);
  logic weight_available,param_available;
  logic [1:0] param_ready_q;
  logic [15:0] param_scale_q[0:1][0:LANES-1];
  logic [7:0] param_zero_q[0:1][0:LANES-1];
  // Parameter loads and D1 reads of the SAME buffer on one edge are illegal.
  // D1 snapshots the selected pair; that buffer is reusable from the next
  // edge even while its old scale is still used by D2/D3.
  wire collision=request_i && param_write_i && param_buffer_i==param_write_buffer_i;
  logic [1:0] valid_q,buffer_q;
  logic [7:0] d1_magnitude_q[0:LANES-1],d1_scale_q[0:LANES-1];
  logic [7:0] d1_exponent_q[0:LANES-1],d2_exponent_q[0:LANES-1];
  logic [15:0] d2_product_q[0:LANES-1];
  logic [3:0] d2_shift_q[0:LANES-1];
  logic [15:0] product_d[0:LANES-1];
  logic [3:0] shift_d[0:LANES-1];
  logic [LANES-1:0] d1_sign_q,d2_sign_q,d1_direct_q,d2_direct_q;
  logic [15:0] d1_value_q[0:LANES-1],d2_value_q[0:LANES-1];

  // A normal result has product >= 128, so only bits 15:7 determine
  // its 0..8 right shift. The smaller products are exact BF16 subnormals.
  // Hierarchical detection is performed after multiplication, before D2.
  function automatic logic [3:0] normalization_shift(input logic [8:0] high_product);
    logic [7:0] candidate;
    logic [3:0] distance;
    begin
      candidate=high_product[7:0];distance=0;
      if(high_product[8]) distance=4'd8;
      else begin
        if(|candidate[7:4]) begin distance=distance+4'd4;candidate=candidate>>4;end
        if(|candidate[3:2]) begin distance=distance+4'd2;candidate=candidate>>2;end
        if(candidate[1]) distance=distance+4'd1;
      end
      normalization_shift=distance;
    end
  endfunction

  function automatic logic [15:0] pack_product(
    input logic sign,input logic [15:0] product,
    input logic [7:0] scale_exponent,input logic [3:0] distance
  );
    logic [8:0] exponent;
    logic [8:0] rounded;
    logic sticky;
    begin
      // Exponent correction runs in parallel with the bounded right shift.
      // 9 bits also cover exponent overflow and a subsequent rounding carry.
      exponent={1'b0,scale_exponent}+{5'b0,distance};
      rounded=0;sticky=0;
      if(!(|product[15:7])) begin
        // Only a subnormal scale (or zero) can produce a product < 128.
        // Its quantum is exactly 2^-133; no shift or rounding is needed.
        pack_product={sign,8'b0,product[6:0]};
      end else begin
        rounded={1'b0,8'(product>>distance)};
        // With a maximum shift of eight, sticky uses only bits 6:0.
        for(integer b=0;b<7;b++) if(b+1<int'(distance)) sticky=sticky || product[b];
        if(distance!=0 && product[distance-1'b1] && (sticky || rounded[0])) rounded=rounded+1'b1;
        if(rounded[8]) begin rounded=rounded>>1;exponent=exponent+9'd1;end
        pack_product=(exponent>=9'd255) ? {sign,8'hff,7'b0} : {sign,exponent[7:0],rounded[6:0]};
      end
    end
  endfunction

  always_comb begin
    for(integer lane=0;lane<LANES;lane++) begin
      product_d[lane]=d1_magnitude_q[lane]*d1_scale_q[lane];
      shift_d[lane]=normalization_shift(product_d[lane][15:7]);
    end
  end

  always_comb begin
    weight_available=1'b1;param_available=1'b1;consume_o='0;
    for(integer lane=0;lane<LANES;lane++) begin
      weight_available=weight_available && stream_valid_i[Q_STREAM*LANES+lane];
      param_available=param_available && stream_valid_i[SCALE_LO_STREAM*LANES+lane] && stream_valid_i[SCALE_HI_STREAM*LANES+lane] &&
        (!ZERO_ENABLE || stream_valid_i[ZERO_STREAM*LANES+lane]);
    end
    if(accepted_o) for(integer lane=0;lane<LANES;lane++)
      consume_o[Q_STREAM*LANES+lane]=1'b1;
    if(param_accepted_o) for(integer lane=0;lane<LANES;lane++) begin
      consume_o[SCALE_LO_STREAM*LANES+lane]=1'b1;
      consume_o[SCALE_HI_STREAM*LANES+lane]=1'b1;
      if(ZERO_ENABLE) consume_o[ZERO_STREAM*LANES+lane]=1'b1;
    end
    for(integer lane=0;lane<LANES;lane++)
      weight_bf16_o[lane*16+:16]=d2_direct_q[lane]?d2_value_q[lane]:
        pack_product(d2_sign_q[lane],d2_product_q[lane],d2_exponent_q[lane],d2_shift_q[lane]);
  end
  assign accepted_o=run_i && request_i && weight_available && param_ready_q[param_buffer_i] && !collision;
  assign param_accepted_o=run_i && param_write_i && param_available && !collision;
  assign param_ready_o=param_ready_q;
  assign valid_o=valid_q[1];
  assign buffer_o=buffer_q[1];
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      param_ready_q<=0;
      for(integer bank=0;bank<2;bank++) for(integer lane=0;lane<LANES;lane++) begin
        param_scale_q[bank][lane]<=0;param_zero_q[bank][lane]<=0;
      end
    end else if(param_accepted_o) begin
      param_ready_q[param_write_buffer_i]<=1'b1;
      for(integer lane=0;lane<LANES;lane++) begin
        param_scale_q[param_write_buffer_i][lane]<=
          {stream_i[(SCALE_HI_STREAM*LANES+lane)*8+:8],stream_i[(SCALE_LO_STREAM*LANES+lane)*8+:8]};
        param_zero_q[param_write_buffer_i][lane]<=ZERO_ENABLE?stream_i[(ZERO_STREAM*LANES+lane)*8+:8]:8'b0;
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      valid_q<=0;buffer_q<=0;fault_o<=0;
      d1_sign_q<=0;d2_sign_q<=0;d1_direct_q<=0;d2_direct_q<=0;
      for(integer lane=0;lane<LANES;lane++) begin
        d1_magnitude_q[lane]<=0;d1_scale_q[lane]<=0;d1_exponent_q[lane]<=0;d2_exponent_q[lane]<=0;
        d2_product_q[lane]<=0;d2_shift_q[lane]<=0;d1_value_q[lane]<=0;d2_value_q[lane]<=0;
      end
    end else if(!run_i) begin
      valid_q<=0;buffer_q<=0;fault_o<=0;
    end else begin
      valid_q<={valid_q[0],accepted_o};buffer_q<={buffer_q[0],buffer_i};
      if((request_i && !accepted_o) || (param_write_i && !param_accepted_o)) fault_o<=1'b1;
      if(accepted_o) for(integer lane=0;lane<LANES;lane++) begin : d1
        logic [7:0] q,z;
        logic [15:0] scale;
        logic signed [8:0] difference;
        logic sign;
        q=stream_i[(Q_STREAM*LANES+lane)*8+:8];
        z=param_zero_q[param_buffer_i][lane];
        scale=param_scale_q[param_buffer_i][lane];
        difference=$signed({q[7],q})-$signed({z[7],z});
        sign=difference[8]^scale[15];
        d1_magnitude_q[lane]<=difference[8]?8'(-difference):8'(difference);
        d1_scale_q[lane]<={(|scale[14:7]),scale[6:0]};
        d1_exponent_q[lane]<=scale[14:7]==0?8'd1:scale[14:7];
        d1_sign_q[lane]<=sign;
        d1_direct_q[lane]<=difference==0 || scale[14:0]==0 || (&scale[14:7]);
        if((&scale[14:7]) && ((|scale[6:0]) || difference==0)) d1_value_q[lane]<=16'h7fc0;
        else if(&scale[14:7]) d1_value_q[lane]<={sign,8'hff,7'b0};
        else d1_value_q[lane]<={sign,15'b0};
      end
      if(valid_q[0]) for(integer lane=0;lane<LANES;lane++) begin
        d2_product_q[lane]<=product_d[lane];d2_shift_q[lane]<=shift_d[lane];
        d2_exponent_q[lane]<=d1_exponent_q[lane];d2_sign_q[lane]<=d1_sign_q[lane];
        d2_direct_q[lane]<=d1_direct_q[lane];d2_value_q[lane]<=d1_value_q[lane];
      end
    end
  end
  initial begin
    if(lpu_mxm_config_pkg::WEIGHT_PARAMETER_BUFFER_COUNT!=2 || LANES<1 || STREAMS<4 || Q_STREAM<0 || SCALE_LO_STREAM<0 || SCALE_HI_STREAM<0 || ZERO_STREAM<0 ||
       Q_STREAM>=STREAMS || SCALE_LO_STREAM>=STREAMS || SCALE_HI_STREAM>=STREAMS || ZERO_STREAM>=STREAMS ||
       Q_STREAM==SCALE_LO_STREAM || Q_STREAM==SCALE_HI_STREAM || SCALE_LO_STREAM==SCALE_HI_STREAM ||
       (ZERO_ENABLE && (ZERO_STREAM==Q_STREAM || ZERO_STREAM==SCALE_LO_STREAM || ZERO_STREAM==SCALE_HI_STREAM)))
      $fatal(1,"Invalid MXM weight stream binding");
  end
endmodule
