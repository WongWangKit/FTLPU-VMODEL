module lpu_vxm_special_alu #(
  parameter integer SPECIAL_KIND = lpu_pkg::VXM_SPECIAL_NONE,
  parameter integer LUT_BANK_COUNT = 3,
  parameter integer LUT_ENTRY_COUNT = 64,
  parameter integer LUT_BANK_WIDTH =
    LUT_BANK_COUNT <= 1 ? 1 : $clog2(LUT_BANK_COUNT),
  parameter integer LUT_ADDRESS_WIDTH =
    LUT_ENTRY_COUNT <= 1 ? 1 : $clog2(LUT_ENTRY_COUNT)
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  input  logic                         valid_i,
  input  logic [1:0]                   data_format_i,
  input  logic [2:0]                   opcode_i,
  input  logic [31:0]                  operand_i,

  // LUT storage remains compact FP16. BF16 and FP32 execution widen
  // configuration and k/b values before FP32 address/interpolation arithmetic.
  input  logic [LUT_BANK_COUNT-1:0]    lut_configured_i,
  input  logic [LUT_BANK_COUNT*16-1:0] lut_input_min_i,
  input  logic [LUT_BANK_COUNT*16-1:0] lut_segment_width_i,
  output logic                         lut_read_valid_o,
  output logic [LUT_BANK_WIDTH-1:0]    lut_read_bank_o,
  output logic [LUT_ADDRESS_WIDTH-1:0] lut_read_address_o,
  input  logic                         lut_read_valid_i,
  input  logic [15:0]                  lut_read_k_i,
  input  logic [15:0]                  lut_read_b_i,

  output logic                         ready_o,
  output logic                         valid_o,
  output logic [31:0]                  result_o,
  output logic                         illegal_opcode_o,
  output logic                         lut_fault_o
);
  import lpu_pkg::*;
  import lpu_vxm_fp16_pkg::*;
  import lpu_vxm_math_pkg::*;

  localparam logic [15:0] FP16_INV_LN2 = 16'h3dc5;
  localparam logic [15:0] FP16_LN2     = 16'h398c;
  localparam logic [31:0] FP32_INV_LN2 = 32'h3fb8aa3b;
  localparam logic [31:0] FP32_LN2     = 32'h3f317218;
  localparam logic [31:0] FP32_CANONICAL_NAN = 32'h7fc00000;

  function automatic logic fp32_is_nan_local(input logic [31:0] value);
    fp32_is_nan_local =
      (value[30:23] == 8'hff) && (value[22:0] != 0);
  endfunction

  function automatic logic fp32_is_inf_local(input logic [31:0] value);
    fp32_is_inf_local =
      (value[30:23] == 8'hff) && (value[22:0] == 0);
  endfunction

  function automatic logic [31:0] fp32_sanitize_ftz_local(
    input logic [31:0] value
  );
    begin
      if (fp32_is_nan_local(value))
        fp32_sanitize_ftz_local = {value[31], 8'hff, 1'b1, 22'b0};
      else if (value[30:23] == 0)
        fp32_sanitize_ftz_local = {value[31], 31'b0};
      else
        fp32_sanitize_ftz_local = value;
    end
  endfunction

  function automatic signed [31:0] fp32_to_sint_rne_local(
    input logic [31:0] value
  );
    logic [23:0] significand;
    logic [31:0] magnitude;
    logic [31:0] remainder;
    logic [31:0] halfway;
    integer exponent;
    integer shift;
    begin
      significand = {1'b1, value[22:0]};
      magnitude = 0;
      remainder = 0;
      halfway = 0;
      exponent = value[30:23];
      exponent = exponent - 127;
      shift = 0;
      if ((value[30:23] == 0) || (exponent < -1))
        magnitude = 0;
      else if (exponent == -1)
        magnitude = value[22:0] == 0 ? 0 : 1;
      else if (exponent >= 31)
        magnitude = 32'h7fffffff;
      else if (exponent >= 23)
        magnitude = {8'b0, significand} << (exponent-23);
      else begin
        shift = 23-exponent;
        magnitude = significand >> shift;
        remainder = significand & ((32'b1 << shift)-1'b1);
        halfway = 32'b1 << (shift-1);
        if ((remainder > halfway) ||
            ((remainder == halfway) && magnitude[0]))
          magnitude = magnitude + 1'b1;
      end
      fp32_to_sint_rne_local = value[31] ?
        -$signed(magnitude) : $signed(magnitude);
    end
  endfunction

  function automatic logic [31:0] uint_to_fp32_exact_local(
    input integer value
  );
    logic [31:0] magnitude;
    logic [31:0] normalized;
    logic [7:0] exponent;
    integer most_significant_bit;
    begin
      magnitude = value;
      normalized = 0;
      exponent = 0;
      most_significant_bit = 0;
      if (value <= 0)
        uint_to_fp32_exact_local = 32'b0;
      else begin
        for (integer bit_index = 0; bit_index < 31; bit_index++)
          if (magnitude[bit_index])
            most_significant_bit = bit_index;
        exponent = 127 + most_significant_bit;
        if (most_significant_bit <= 23)
          normalized = magnitude << (23-most_significant_bit);
        else
          normalized = magnitude >> (most_significant_bit-23);
        uint_to_fp32_exact_local =
          {1'b0, exponent, normalized[22:0]};
      end
    end
  endfunction

  function automatic logic [31:0] fp32_scale_pow2_ftz_local(
    input logic [31:0] value_in,
    input integer scale
  );
    logic [31:0] value;
    integer exponent;
    begin
      value = fp32_sanitize_ftz_local(value_in);
      exponent = value[30:23];
      exponent = exponent + scale;
      if (fp32_is_nan_local(value) || fp32_is_inf_local(value) ||
          (value[30:0] == 0))
        fp32_scale_pow2_ftz_local = value;
      else if (exponent <= 0)
        fp32_scale_pow2_ftz_local = {value[31], 31'b0};
      else if (exponent >= 255)
        fp32_scale_pow2_ftz_local = {value[31], 8'hff, 23'b0};
      else
        fp32_scale_pow2_ftz_local =
          {value[31], exponent[7:0], value[22:0]};
    end
  endfunction

  logic supported_opcode;
  logic [15:0] sanitized_operand16;
  logic [15:0] sanitized_operand_bf16;
  logic [31:0] sanitized_operand32;
  logic [31:0] working_operand32;
  logic request_lookup;
  logic [LUT_BANK_WIDTH-1:0] request_bank;
  logic [31:0] request_local_input;
  logic [31:0] request_direct_result;
  logic request_multiplier_sign;
  integer request_result_exponent;
  logic request_configured;
  logic [31:0] request_input_min;
  logic [31:0] request_segment_width;

  logic stage0_valid_q;
  logic stage0_lookup_q;
  logic [1:0] stage0_format_q;
  logic [LUT_BANK_WIDTH-1:0] stage0_bank_q;
  logic [31:0] stage0_local_input_q;
  logic [31:0] stage0_direct_result_q;
  logic stage0_multiplier_sign_q;
  logic signed [7:0] stage0_result_exponent_q;
  logic [31:0] stage0_input_min_q;
  logic [31:0] stage0_segment_width_q;

  logic [31:0] lookup_position;
  logic [15:0] lookup_index_fp16;
  logic [31:0] lookup_index_fp32;
  logic [31:0] lookup_x0;
  logic [31:0] lookup_dx;
  integer lookup_index;

  logic read_meta_valid_q;
  logic read_meta_lookup_q;
  logic [1:0] read_meta_format_q;
  logic [31:0] read_meta_dx_q;
  logic [31:0] read_meta_direct_result_q;
  logic read_meta_multiplier_sign_q;
  logic signed [7:0] read_meta_result_exponent_q;

  logic multiply_valid_q;
  logic multiply_lookup_q;
  logic [1:0] multiply_format_q;
  logic [31:0] multiply_product_q;
  logic [31:0] multiply_b_q;
  logic [31:0] multiply_direct_result_q;
  logic multiply_multiplier_sign_q;
  logic signed [7:0] multiply_result_exponent_q;

  logic add_valid_q;
  logic [1:0] add_format_q;
  logic [31:0] add_result_q;
  logic add_multiplier_sign_q;
  logic signed [7:0] add_result_exponent_q;
  logic [31:0] restored_result;
  logic [31:0] restored_wide;

  always_comb begin
    // One request per physical ALU may be outstanding. A lookup can remain
    // in read_meta_valid_q for an arbitrary number of arbitration cycles.
    ready_o = !(stage0_valid_q || read_meta_valid_q ||
                multiply_valid_q || add_valid_q);
  end

  always_comb begin
    integer normalized_exponent;
    integer rounded_exponent;
    integer exponent_magnitude;
    logic [15:0] exponent_fp16;
    logic [15:0] exponent_times_ln2_fp16;
    logic [31:0] exponent_fp32;
    logic [31:0] exponent_times_ln2_fp32;
    logic [15:0] selected_input_min;
    logic [15:0] selected_segment_width;

    supported_opcode =
      ((SPECIAL_KIND == VXM_SPECIAL_EXP) &&
       (opcode_i == VXM_LOCAL_SPECIAL0)) ||
      ((SPECIAL_KIND == VXM_SPECIAL_RECIP_RSQRT) &&
       ((opcode_i == VXM_LOCAL_SPECIAL0) ||
        (opcode_i == VXM_LOCAL_SPECIAL1)));
    illegal_opcode_o = valid_i && !supported_opcode;
    sanitized_operand16 = fp16_sanitize_ftz(operand_i[15:0]);
    sanitized_operand_bf16 = bf16_sanitize_ftz(operand_i[15:0]);
    sanitized_operand32 = fp32_sanitize_ftz_local(operand_i);
    working_operand32 = data_format_i == VXM_FORMAT_BF16 ?
      bf16_to_fp32(sanitized_operand_bf16) : sanitized_operand32;
    request_lookup = 1'b0;
    request_bank = '0;
    request_local_input = 32'b0;
    request_direct_result = data_format_i == VXM_FORMAT_FP16 ?
      {16'b0, FP16_CANONICAL_NAN} : FP32_CANONICAL_NAN;
    request_multiplier_sign = 1'b0;
    request_result_exponent = 0;
    normalized_exponent = 0;
    rounded_exponent = 0;
    exponent_magnitude = 0;
    exponent_fp16 = 16'b0;
    exponent_times_ln2_fp16 = 16'b0;
    exponent_fp32 = 32'b0;
    exponent_times_ln2_fp32 = 32'b0;

    if ((SPECIAL_KIND == VXM_SPECIAL_EXP) &&
        (opcode_i == VXM_LOCAL_SPECIAL0)) begin
      request_bank = 0;
      if (data_format_i != VXM_FORMAT_FP16) begin
        if (fp32_is_nan_local(working_operand32))
          request_direct_result = FP32_CANONICAL_NAN;
        else if (fp32_is_inf_local(working_operand32))
          request_direct_result = working_operand32[31] ?
            32'b0 : 32'h7f800000;
        else begin
          request_lookup = 1'b1;
          rounded_exponent = fp32_to_sint_rne_local(fp32_multiply_rne(
            working_operand32, FP32_INV_LN2));
          if (rounded_exponent > 127)
            rounded_exponent = 127;
          else if (rounded_exponent < -127)
            rounded_exponent = -127;
          exponent_magnitude = rounded_exponent < 0 ?
            -rounded_exponent : rounded_exponent;
          exponent_fp32 = uint_to_fp32_exact_local(exponent_magnitude);
          if (rounded_exponent < 0)
            exponent_fp32[31] = 1'b1;
          exponent_times_ln2_fp32 = fp32_multiply_rne(
            exponent_fp32, FP32_LN2);
          request_local_input = fp32_add_rne(
            working_operand32,
            {~exponent_times_ln2_fp32[31],
             exponent_times_ln2_fp32[30:0]});
          request_result_exponent = rounded_exponent;
        end
      end else begin
        if (fp16_is_nan(sanitized_operand16))
          request_direct_result[15:0] = FP16_CANONICAL_NAN;
        else if (fp16_is_inf(sanitized_operand16))
          request_direct_result[15:0] = sanitized_operand16[15] ?
            16'b0 : 16'h7c00;
        else begin
          request_lookup = 1'b1;
          rounded_exponent = fp16_to_sint_rne(fp16_multiply_rne_ftz(
            sanitized_operand16, FP16_INV_LN2));
          if (rounded_exponent > 31)
            rounded_exponent = 31;
          else if (rounded_exponent < -31)
            rounded_exponent = -31;
          exponent_magnitude = rounded_exponent < 0 ?
            -rounded_exponent : rounded_exponent;
          exponent_fp16 = uint_to_fp16_rne_ftz(exponent_magnitude);
          if (rounded_exponent < 0)
            exponent_fp16[15] = 1'b1;
          exponent_times_ln2_fp16 = fp16_multiply_rne_ftz(
            exponent_fp16, FP16_LN2);
          request_local_input[15:0] = fp16_sub_rne_ftz(
            sanitized_operand16, exponent_times_ln2_fp16);
          request_result_exponent = rounded_exponent;
        end
      end
    end else if ((SPECIAL_KIND == VXM_SPECIAL_RECIP_RSQRT) &&
                 (opcode_i == VXM_LOCAL_SPECIAL0)) begin
      request_bank = 1;
      if (data_format_i != VXM_FORMAT_FP16) begin
        if (fp32_is_nan_local(working_operand32))
          request_direct_result = FP32_CANONICAL_NAN;
        else if (working_operand32[30:0] == 0)
          request_direct_result =
            {working_operand32[31], 8'hff, 23'b0};
        else if (fp32_is_inf_local(working_operand32))
          request_direct_result = {working_operand32[31], 31'b0};
        else begin
          request_lookup = 1'b1;
          normalized_exponent = working_operand32[30:23];
          normalized_exponent = normalized_exponent - 127;
          request_local_input =
            {1'b0, 8'd127, working_operand32[22:0]};
          request_multiplier_sign = working_operand32[31];
          request_result_exponent = -normalized_exponent;
        end
      end else begin
        if (fp16_is_nan(sanitized_operand16))
          request_direct_result[15:0] = FP16_CANONICAL_NAN;
        else if (sanitized_operand16[14:0] == 0)
          request_direct_result[15:0] =
            {sanitized_operand16[15], 5'h1f, 10'b0};
        else if (fp16_is_inf(sanitized_operand16))
          request_direct_result[15:0] = {sanitized_operand16[15], 15'b0};
        else begin
          request_lookup = 1'b1;
          normalized_exponent = sanitized_operand16[14:10] - 15;
          request_local_input[15:0] =
            {1'b0, 5'd15, sanitized_operand16[9:0]};
          request_multiplier_sign = sanitized_operand16[15];
          request_result_exponent = -normalized_exponent;
        end
      end
    end else if ((SPECIAL_KIND == VXM_SPECIAL_RECIP_RSQRT) &&
                 (opcode_i == VXM_LOCAL_SPECIAL1)) begin
      request_bank = 2;
      if (data_format_i != VXM_FORMAT_FP16) begin
        if (fp32_is_nan_local(working_operand32) ||
            (working_operand32[31] &&
             (working_operand32[30:0] != 0)))
          request_direct_result = FP32_CANONICAL_NAN;
        else if (working_operand32[30:0] == 0)
          request_direct_result = 32'h7f800000;
        else if (fp32_is_inf_local(working_operand32))
          request_direct_result = 32'b0;
        else begin
          request_lookup = 1'b1;
          normalized_exponent = working_operand32[30:23];
          normalized_exponent = normalized_exponent - 127;
          request_local_input =
            {1'b0, 8'd127, working_operand32[22:0]};
          if ((normalized_exponent % 2) != 0) begin
            request_local_input[30:23] = 8'd128;
            normalized_exponent = normalized_exponent - 1;
          end
          request_result_exponent = -(normalized_exponent / 2);
        end
      end else begin
        if (fp16_is_nan(sanitized_operand16) ||
            (sanitized_operand16[15] && sanitized_operand16[14:0] != 0))
          request_direct_result[15:0] = FP16_CANONICAL_NAN;
        else if (sanitized_operand16[14:0] == 0)
          request_direct_result[15:0] = 16'h7c00;
        else if (fp16_is_inf(sanitized_operand16))
          request_direct_result[15:0] = 16'b0;
        else begin
          request_lookup = 1'b1;
          normalized_exponent = sanitized_operand16[14:10] - 15;
          request_local_input[15:0] =
            {1'b0, 5'd15, sanitized_operand16[9:0]};
          if ((normalized_exponent % 2) != 0) begin
            request_local_input[14:10] = 5'd16;
            normalized_exponent = normalized_exponent - 1;
          end
          request_result_exponent = -(normalized_exponent / 2);
        end
      end
    end

    request_configured = 1'b0;
    selected_input_min = 16'b0;
    selected_segment_width = FP16_ONE;
    for (integer bank = 0; bank < LUT_BANK_COUNT; bank++) begin
      if (request_bank == bank) begin
        request_configured = lut_configured_i[bank];
        selected_input_min = lut_input_min_i[bank*16 +: 16];
        selected_segment_width =
          lut_segment_width_i[bank*16 +: 16];
      end
    end
    if (data_format_i != VXM_FORMAT_FP16) begin
      request_input_min = fp16_to_fp32(selected_input_min);
      request_segment_width = fp16_to_fp32(selected_segment_width);
    end else begin
      request_input_min = {16'b0, selected_input_min};
      request_segment_width = {16'b0, selected_segment_width};
    end
  end

  always_comb begin
    if (stage0_format_q != VXM_FORMAT_FP16) begin
      lookup_position = fp32_divide_rne(
        fp32_add_rne(stage0_local_input_q,
          {~stage0_input_min_q[31], stage0_input_min_q[30:0]}),
        stage0_segment_width_q);
      lookup_index = fp32_to_sint(lookup_position);
      if (lookup_position[31])
        lookup_index = 0;
      else if (lookup_index >= LUT_ENTRY_COUNT)
        lookup_index = LUT_ENTRY_COUNT - 1;
      lookup_index_fp32 = uint_to_fp32_exact_local(lookup_index);
      lookup_x0 = fp32_add_rne(
        stage0_input_min_q,
        fp32_multiply_rne(lookup_index_fp32,
                          stage0_segment_width_q));
      lookup_dx = fp32_add_rne(
        stage0_local_input_q, {~lookup_x0[31], lookup_x0[30:0]});
      lookup_index_fp16 = 16'b0;
    end else begin
      lookup_position = 32'b0;
      lookup_position[15:0] = fp16_divide_rne_ftz(
        fp16_sub_rne_ftz(stage0_local_input_q[15:0],
                         stage0_input_min_q[15:0]),
        stage0_segment_width_q[15:0]);
      lookup_index = fp16_to_uint_floor(lookup_position[15:0]);
      if (lookup_position[15])
        lookup_index = 0;
      else if (lookup_index >= LUT_ENTRY_COUNT)
        lookup_index = LUT_ENTRY_COUNT - 1;
      lookup_index_fp16 = uint_to_fp16_rne_ftz(lookup_index);
      lookup_index_fp32 = 32'b0;
      lookup_x0 = 32'b0;
      lookup_x0[15:0] = fp16_add_rne_ftz(
        stage0_input_min_q[15:0],
        fp16_multiply_rne_ftz(lookup_index_fp16,
                              stage0_segment_width_q[15:0]));
      lookup_dx = 32'b0;
      lookup_dx[15:0] = fp16_sub_rne_ftz(
        stage0_local_input_q[15:0], lookup_x0[15:0]);
    end

    lut_read_valid_o = stage0_valid_q && stage0_lookup_q;
    lut_read_bank_o = stage0_bank_q;
    lut_read_address_o = lookup_index[LUT_ADDRESS_WIDTH-1:0];
  end

  always_comb begin
    restored_wide = 32'b0;
    if (add_format_q != VXM_FORMAT_FP16) begin
      restored_wide = fp32_scale_pow2_ftz_local(
        add_result_q, add_result_exponent_q);
      if (add_multiplier_sign_q)
        restored_wide[31] = ~restored_wide[31];
      restored_result = add_format_q == VXM_FORMAT_BF16 ?
        {16'b0, fp32_to_bf16_ftz(restored_wide)} : restored_wide;
    end else begin
      restored_result = 32'b0;
      restored_result[15:0] = fp16_scale_pow2_ftz(
        add_result_q[15:0], add_result_exponent_q);
      if (add_multiplier_sign_q)
        restored_result[15] = ~restored_result[15];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stage0_valid_q <= 1'b0;
      stage0_lookup_q <= 1'b0;
      stage0_format_q <= VXM_FORMAT_FP16;
      stage0_bank_q <= '0;
      stage0_local_input_q <= 32'b0;
      stage0_direct_result_q <= 32'b0;
      stage0_multiplier_sign_q <= 1'b0;
      stage0_result_exponent_q <= '0;
      stage0_input_min_q <= 32'b0;
      stage0_segment_width_q <= {16'b0, FP16_ONE};
      read_meta_valid_q <= 1'b0;
      read_meta_lookup_q <= 1'b0;
      read_meta_format_q <= VXM_FORMAT_FP16;
      read_meta_dx_q <= 32'b0;
      read_meta_direct_result_q <= 32'b0;
      read_meta_multiplier_sign_q <= 1'b0;
      read_meta_result_exponent_q <= '0;
      multiply_valid_q <= 1'b0;
      multiply_lookup_q <= 1'b0;
      multiply_format_q <= VXM_FORMAT_FP16;
      multiply_product_q <= 32'b0;
      multiply_b_q <= 32'b0;
      multiply_direct_result_q <= 32'b0;
      multiply_multiplier_sign_q <= 1'b0;
      multiply_result_exponent_q <= '0;
      add_valid_q <= 1'b0;
      add_format_q <= VXM_FORMAT_FP16;
      add_result_q <= 32'b0;
      add_multiplier_sign_q <= 1'b0;
      add_result_exponent_q <= '0;
      valid_o <= 1'b0;
      result_o <= 32'b0;
      lut_fault_o <= 1'b0;
    end else begin
      lut_fault_o <= 1'b0;

      valid_o <= add_valid_q;
      if (add_valid_q)
        result_o <= restored_result;

      add_valid_q <= multiply_valid_q;
      add_format_q <= multiply_format_q;
      if (multiply_lookup_q) begin
        if (multiply_format_q != VXM_FORMAT_FP16)
          add_result_q <= fp32_add_rne(
            multiply_product_q, multiply_b_q);
        else
          add_result_q <= {16'b0, fp16_add_rne_ftz(
            multiply_product_q[15:0], multiply_b_q[15:0])};
      end else
        add_result_q <= multiply_direct_result_q;
      add_multiplier_sign_q <= multiply_multiplier_sign_q;
      add_result_exponent_q <= multiply_result_exponent_q;

      multiply_valid_q <= read_meta_valid_q &&
        (!read_meta_lookup_q || lut_read_valid_i);
      multiply_lookup_q <= read_meta_lookup_q;
      multiply_format_q <= read_meta_format_q;
      if (read_meta_format_q != VXM_FORMAT_FP16) begin
        multiply_product_q <= fp32_multiply_rne(
          fp16_to_fp32(lut_read_k_i), read_meta_dx_q);
        multiply_b_q <= fp16_to_fp32(lut_read_b_i);
      end else begin
        multiply_product_q <= {16'b0, fp16_multiply_rne_ftz(
          lut_read_k_i, read_meta_dx_q[15:0])};
        multiply_b_q <= {16'b0, lut_read_b_i};
      end
      multiply_direct_result_q <= read_meta_direct_result_q;
      multiply_multiplier_sign_q <= read_meta_multiplier_sign_q;
      multiply_result_exponent_q <= read_meta_result_exponent_q;
      // Direct results advance immediately. LUT results hold their metadata
      // until the one-cycle Lane SRAM service returns the tagged response.
      if (read_meta_valid_q &&
          (!read_meta_lookup_q || lut_read_valid_i))
        read_meta_valid_q <= 1'b0;

      if (stage0_valid_q) begin
        read_meta_valid_q <= 1'b1;
        read_meta_lookup_q <= stage0_lookup_q;
        read_meta_format_q <= stage0_format_q;
        read_meta_dx_q <= lookup_dx;
        read_meta_direct_result_q <= stage0_direct_result_q;
        read_meta_multiplier_sign_q <= stage0_multiplier_sign_q;
        read_meta_result_exponent_q <= stage0_result_exponent_q;
        stage0_valid_q <= 1'b0;
      end

      if (valid_i && supported_opcode && ready_o) begin
        stage0_valid_q <= 1'b1;
        stage0_lookup_q <= request_lookup && request_configured;
        stage0_format_q <= data_format_i;
        stage0_bank_q <= request_bank;
        stage0_local_input_q <= request_local_input;
        stage0_direct_result_q <= request_lookup && !request_configured ?
          (data_format_i == VXM_FORMAT_FP16 ?
            {16'b0, FP16_CANONICAL_NAN} : FP32_CANONICAL_NAN) :
          request_direct_result;
        stage0_multiplier_sign_q <= request_multiplier_sign;
        stage0_result_exponent_q <= request_result_exponent;
        stage0_input_min_q <= request_input_min;
        stage0_segment_width_q <= request_segment_width;
        if (request_lookup && !request_configured)
          lut_fault_o <= 1'b1;
      end
    end
  end
endmodule
