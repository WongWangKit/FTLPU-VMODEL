// BF16 DAZ dot product, two multiply stages plus seven reduction stages.
// Fixed nine register stages, II=1. No FP32 conversion before reduction.
// Alignment truncates magnitudes toward zero before two's-complement sign.
module lpu_mxm_bf16_dot_csa #(
  parameter integer TERMS = lpu_mxm_config_pkg::CELL_K,
  parameter integer TAG_WIDTH = 16
) (
  input logic clk_i, rst_ni,
  input logic valid_i,
  input logic [TERMS*16-1:0] activation_i, weight_i,
  input logic [TAG_WIDTH-1:0] tag_i,
  output logic valid_o,
  output logic [31:0] result_o,
  output logic [TAG_WIDTH-1:0] tag_o,
  output logic alignment_lost_o
);
  import lpu_mxm_supercell_math_pkg::*;
  localparam integer WIDTH = lpu_mxm_config_pkg::DOT_INTERNAL_BITS;
  localparam integer GROWTH = TERMS > 1 ? $clog2(TERMS) : 0;
  localparam integer ALIGNED_BITS = WIDTH - 1 - GROWTH;
  localparam integer LEVELS = csa_levels(TERMS);
  localparam integer FIRST_LEVELS = (LEVELS+1)/2;
  localparam integer SECOND_LEVELS = LEVELS-FIRST_LEVELS;
  localparam integer FIRST_COUNT = csa_count_after(TERMS,FIRST_LEVELS);
  typedef logic [TERMS*64-1:0] words_t;
  typedef logic [TERMS*16-1:0] products_t;
  typedef logic [TERMS*11-1:0] exponents_t;

  // Carry words are already shifted. Arithmetic is modulo 2^64; the sign
  // and ceil(log2(TERMS)) growth budget make the true signed sum fit.
  function automatic words_t compress_levels(
    input words_t words, input integer initial_count, input integer levels
  );
    words_t current_words, next_words;
    logic [63:0] a,b,c;
    integer count, destination;
    begin
      current_words = words;
      count = initial_count;
      for (integer level=0; level<levels; level++) begin
        next_words = '0;
        destination = 0;
        for (integer group=0; group<TERMS/3; group++) begin
          if (group < count/3) begin
            a = current_words[(group*3)*64 +: 64];
            b = current_words[(group*3+1)*64 +: 64];
            c = current_words[(group*3+2)*64 +: 64];
            next_words[destination*64 +: 64] = a ^ b ^ c;
            next_words[(destination+1)*64 +: 64] = ((a&b)|(a&c)|(b&c)) << 1;
            destination = destination+2;
          end
        end
        for (integer remainder=0; remainder<2; remainder++) begin
          if (remainder < count%3) begin
            next_words[destination*64 +: 64] =
              current_words[((count/3)*3+remainder)*64 +: 64];
            destination = destination+1;
          end
        end
        // No compression is needed once only one/two words remain.
        if (count > 2) begin
          current_words = next_words;
          count = destination;
        end
      end
      compress_levels = current_words;
    end
  endfunction

  logic [8:0] valid_q;
  logic [TAG_WIDTH-1:0] tag_q [0:8];
  logic [8:0] nan_q, pos_inf_q, neg_inf_q;
  products_t m1_product_q, m2_product_q, r1_product_q;
  exponents_t m1_exponent_q, m2_exponent_q, r1_exponent_q;
  logic [TERMS-1:0] m1_sign_q, m2_sign_q, r1_sign_q;
  logic signed [10:0] r1_common_q, r2_common_q, r3_common_q, r4_common_q, r5_common_q;
  words_t r2_words_q, r3_words_q, r4_words_q;
  logic r2_lost_q, r3_lost_q, r4_lost_q, r5_lost_q, r6_lost_q;
  logic signed [63:0] r5_sum_q;
  logic r6_sign_q;
  logic [63:0] r6_normalized_q;
  logic signed [10:0] r6_exponent_q;

  products_t product_d, normalized_product_d;
  exponents_t exponent_d, normalized_exponent_d;
  logic [TERMS-1:0] sign_d;
  logic nan_d, pos_inf_d, neg_inf_d;
  logic signed [10:0] common_d;
  words_t aligned_d, first_compressed_d, second_compressed_d;
  logic lost_d;
  logic [63:0] final_sum_d, magnitude_d, normalized_sum_d;
  integer leading_d;

  always_comb begin : multiply_inputs
    logic [15:0] a,b;
    logic [7:0] ma,mb;
    logic az,bz,ai,bi,an,bn,sign_product;
    product_d='0; exponent_d='0; sign_d='0;
    nan_d=0; pos_inf_d=0; neg_inf_d=0;
    for (integer term=0; term<TERMS; term++) begin
      a=activation_i[term*16 +: 16]; b=weight_i[term*16 +: 16];
      az=a[14:7]==0; bz=b[14:7]==0; // BF16 input DAZ, signed zero.
      ai=(&a[14:7]) && !(|a[6:0]); bi=(&b[14:7]) && !(|b[6:0]);
      an=(&a[14:7]) && (|a[6:0]); bn=(&b[14:7]) && (|b[6:0]);
      sign_product=a[15]^b[15];
      ma={1'b1,a[6:0]}; mb={1'b1,b[6:0]};
      if (az || bz || ai || bi || an || bn) begin ma=0; mb=0; end
      product_d[term*16 +: 16]=ma*mb;
      exponent_d[term*11 +: 11]=11'(int'(a[14:7])+int'(b[14:7])-254);
      sign_d[term]=sign_product;
      nan_d=nan_d || an || bn || (az&&bi) || (bz&&ai);
      if (!an && !bn && !(az||bz) && (ai||bi)) begin
        pos_inf_d=pos_inf_d || !sign_product;
        neg_inf_d=neg_inf_d || sign_product;
      end
    end
  end

  always_comb begin : normalize_products
    normalized_product_d='0; normalized_exponent_d='0;
    for (integer term=0; term<TERMS; term++) begin
      if (m1_product_q[term*16+15]) begin
        normalized_product_d[term*16 +: 16]=m1_product_q[term*16 +: 16];
        normalized_exponent_d[term*11 +: 11]=
          $signed(m1_exponent_q[term*11 +: 11])+11'sd1;
      end else begin
        normalized_product_d[term*16 +: 16]=m1_product_q[term*16 +: 16]<<1;
        normalized_exponent_d[term*11 +: 11]=m1_exponent_q[term*11 +: 11];
      end
    end
  end

  always_comb begin : common_exponent
    common_d=-11'sd1023;
    for (integer term=0; term<TERMS; term++)
      if ((|m2_product_q[term*16 +: 16]) &&
          $signed(m2_exponent_q[term*11 +: 11]) > common_d)
        common_d=$signed(m2_exponent_q[term*11 +: 11]);
    if (common_d == -11'sd1023) common_d=0;
  end

  always_comb begin : align_products
    logic [63:0] unshifted, magnitude;
    integer distance;
    aligned_d='0; lost_d=0;
    for (integer term=0; term<TERMS; term++) begin
      distance=int'(r1_common_q)-int'($signed(r1_exponent_q[term*11 +: 11]));
      unshifted={48'b0,r1_product_q[term*16 +: 16]} << (ALIGNED_BITS-16);
      magnitude=distance >= 64 ? 64'b0 : unshifted >> distance;
      for (integer bit_index=0; bit_index<64; bit_index++)
        if (bit_index < distance) lost_d=lost_d || unshifted[bit_index];
      aligned_d[term*64 +: 64]=r1_sign_q[term] ? (~magnitude+64'd1) : magnitude;
    end
  end

  always_comb begin
    first_compressed_d=compress_levels(r2_words_q,TERMS,FIRST_LEVELS);
    second_compressed_d=compress_levels(r3_words_q,FIRST_COUNT,SECOND_LEVELS);
    final_sum_d=r4_words_q[0 +: 64];
    // Shifting avoids an out-of-range part select for TERMS=1.
    if (TERMS > 1) final_sum_d=final_sum_d+64'(r4_words_q >> 64);
    magnitude_d=r5_sum_q[63] ? (~$unsigned(r5_sum_q)+64'd1) : $unsigned(r5_sum_q);
    leading_d=0;
    for (integer bit_index=0; bit_index<64; bit_index++)
      if (magnitude_d[bit_index]) leading_d=bit_index;
    normalized_sum_d=magnitude_d << (63-leading_d);
  end

  assign valid_o=valid_q[8];
  assign tag_o=tag_q[8];
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q<=0; nan_q<=0; pos_inf_q<=0; neg_inf_q<=0;
      for (integer stage=0; stage<9; stage++) tag_q[stage]<='0;
      m1_product_q<=0; m2_product_q<=0; r1_product_q<=0;
      m1_exponent_q<=0; m2_exponent_q<=0; r1_exponent_q<=0;
      m1_sign_q<=0; m2_sign_q<=0; r1_sign_q<=0;
      r1_common_q<=0; r2_common_q<=0; r3_common_q<=0; r4_common_q<=0; r5_common_q<=0;
      r2_words_q<=0; r3_words_q<=0; r4_words_q<=0; r5_sum_q<=0;
      r2_lost_q<=0; r3_lost_q<=0; r4_lost_q<=0; r5_lost_q<=0; r6_lost_q<=0;
      r6_normalized_q<=0; r6_exponent_q<=0; r6_sign_q<=0;
      result_o<=0; alignment_lost_o<=0;
    end else begin
      valid_q<={valid_q[7:0],valid_i};
      nan_q<={nan_q[7:0],nan_d};
      pos_inf_q<={pos_inf_q[7:0],pos_inf_d};
      neg_inf_q<={neg_inf_q[7:0],neg_inf_d};
      tag_q[0]<=tag_i;
      for (integer stage=1; stage<9; stage++) tag_q[stage]<=tag_q[stage-1];
      // M1: 8x8 significand multiplication with extended exponents.
      if (valid_i) begin
        m1_product_q<=product_d; m1_exponent_q<=exponent_d; m1_sign_q<=sign_d;
      end
      // M2: normalize the complete product, without FP32 range clipping.
      if (valid_q[0]) begin
        m2_product_q<=normalized_product_d;
        m2_exponent_q<=normalized_exponent_d; m2_sign_q<=m1_sign_q;
      end
      // R1: common exponent; R2: align/truncate magnitudes, then apply sign.
      if (valid_q[1]) begin
        r1_common_q<=common_d; r1_product_q<=m2_product_q;
        r1_exponent_q<=m2_exponent_q; r1_sign_q<=m2_sign_q;
      end
      if (valid_q[2]) begin
        r2_words_q<=aligned_d; r2_common_q<=r1_common_q; r2_lost_q<=lost_d;
      end
      // R3/R4: four compressor levels split 2+2 for the default eight terms.
      if (valid_q[3]) begin
        r3_words_q<=first_compressed_d; r3_common_q<=r2_common_q; r3_lost_q<=r2_lost_q;
      end
      if (valid_q[4]) begin
        r4_words_q<=second_compressed_d; r4_common_q<=r3_common_q; r4_lost_q<=r3_lost_q;
      end
      // R5: final carry propagation. R6: sign, leading zero count, normalize.
      if (valid_q[5]) begin
        r5_sum_q<=$signed(final_sum_d); r5_common_q<=r4_common_q; r5_lost_q<=r4_lost_q;
      end
      if (valid_q[6]) begin
        r6_normalized_q<=normalized_sum_d; r6_sign_q<=r5_sum_q[63];
        r6_exponent_q<=r5_common_q+11'(leading_d-(ALIGNED_BITS-1));
        r6_lost_q<=r5_lost_q;
      end
      // R7: one FP32 RNE boundary, including gradual underflow.
      if (valid_q[7]) begin
        alignment_lost_o<=r6_lost_q;
        if (nan_q[7] || (pos_inf_q[7] && neg_inf_q[7])) result_o<=FP32_QNAN;
        else if (pos_inf_q[7] || neg_inf_q[7]) result_o<={neg_inf_q[7],8'hff,23'b0};
        else result_o<=pack_fp32_rne(r6_sign_q,int'(r6_exponent_q),r6_normalized_q);
      end
    end
  end

  initial begin
    if (TERMS < 1 || ALIGNED_BITS < 16 || WIDTH != 64 || TAG_WIDTH < 1)
      $fatal(1,"Unsupported Supercell dot-product configuration");
  end
endmodule
