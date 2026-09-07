module lpu_vxm_alu #(
  // 0: C0/C2 basic-only, 1: C1 with Exp, 2: C3 with Reciprocal/Rsqrt.
  parameter integer SPECIAL_KIND = lpu_pkg::VXM_SPECIAL_NONE,
  parameter integer LUT_BANK_COUNT = 3,
  parameter integer LUT_ENTRY_COUNT = 64,
  parameter integer LUT_BANK_WIDTH =
    LUT_BANK_COUNT <= 1 ? 1 : $clog2(LUT_BANK_COUNT),
  parameter integer LUT_ADDRESS_WIDTH =
    LUT_ENTRY_COUNT <= 1 ? 1 : $clog2(LUT_ENTRY_COUNT)
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        input_valid_i,
  input  logic [1:0]  data_format_i,
  input  logic [2:0]  opcode_i,
  input  logic [31:0] lhs_i,
  input  logic [31:0] rhs_i,

  input  logic [LUT_BANK_COUNT-1:0]    lut_configured_i,
  input  logic [LUT_BANK_COUNT*16-1:0] lut_input_min_i,
  input  logic [LUT_BANK_COUNT*16-1:0] lut_segment_width_i,
  output logic                         lut_read_valid_o,
  output logic [LUT_BANK_WIDTH-1:0]    lut_read_bank_o,
  output logic [LUT_ADDRESS_WIDTH-1:0] lut_read_address_o,
  input  logic                         lut_read_valid_i,
  input  logic [15:0]                  lut_read_k_i,
  input  logic [15:0]                  lut_read_b_i,

  output logic        input_ready_o,
  output logic        output_valid_o,
  output logic [31:0] result_o,
  output logic        illegal_opcode_o,
  output logic        unsupported_format_o,
  output logic        result_collision_o,
  output logic        lut_fault_o
);
  import lpu_pkg::*;

  logic supported_request;
  logic basic_request;
  logic special_request;
  logic opcode_supported;
  logic special_opcode_supported;
  logic basic_ready;
  logic basic_valid;
  logic [31:0] basic_result;
  logic basic_collision;
  logic special_ready;
  logic special_valid;
  logic [31:0] special_result;

  always_comb begin
    special_opcode_supported =
      ((SPECIAL_KIND == VXM_SPECIAL_EXP) &&
       (opcode_i == VXM_LOCAL_SPECIAL0)) ||
      ((SPECIAL_KIND == VXM_SPECIAL_RECIP_RSQRT) &&
       ((opcode_i == VXM_LOCAL_SPECIAL0) ||
        (opcode_i == VXM_LOCAL_SPECIAL1)));
    opcode_supported = (opcode_i <= VXM_LOCAL_MAX) ||
      special_opcode_supported;
    unsupported_format_o = input_valid_i &&
      (data_format_i != VXM_FORMAT_FP16 &&
       data_format_i != VXM_FORMAT_BF16 &&
       data_format_i != VXM_FORMAT_FP32);
    illegal_opcode_o = input_valid_i &&
      ((data_format_i == VXM_FORMAT_FP16) ||
       (data_format_i == VXM_FORMAT_BF16) ||
       (data_format_i == VXM_FORMAT_FP32)) && !opcode_supported;
    supported_request = input_valid_i && !unsupported_format_o &&
      !illegal_opcode_o;
    basic_request = supported_request && (opcode_i <= VXM_LOCAL_MAX);
    special_request = supported_request && special_opcode_supported;
    if (basic_request)
      input_ready_o = basic_ready;
    else if (special_request)
      input_ready_o = special_ready;
    else
      input_ready_o = 1'b1;

    output_valid_o = basic_valid || special_valid;
    result_o = 32'b0;
    if (special_valid)
      result_o = special_result;
    if (basic_valid)
      result_o = basic_result;
    result_collision_o = basic_collision || (basic_valid && special_valid);
  end

  lpu_vxm_basic_alu u_basic (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .valid_i(basic_request),
    .data_format_i(data_format_i),
    .opcode_i(opcode_i),
    .lhs_i(lhs_i),
    .rhs_i(rhs_i),
    .ready_o(basic_ready),
    .valid_o(basic_valid),
    .result_o(basic_result),
    .illegal_opcode_o(),
    .result_collision_o(basic_collision)
  );

  lpu_vxm_special_alu #(
    .SPECIAL_KIND(SPECIAL_KIND),
    .LUT_BANK_COUNT(LUT_BANK_COUNT),
    .LUT_ENTRY_COUNT(LUT_ENTRY_COUNT),
    .LUT_BANK_WIDTH(LUT_BANK_WIDTH),
    .LUT_ADDRESS_WIDTH(LUT_ADDRESS_WIDTH)
  ) u_special (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .valid_i(special_request),
    .data_format_i(data_format_i),
    .opcode_i(opcode_i),
    .operand_i(lhs_i),
    .lut_configured_i,
    .lut_input_min_i,
    .lut_segment_width_i,
    .lut_read_valid_o,
    .lut_read_bank_o,
    .lut_read_address_o,
    .lut_read_valid_i,
    .lut_read_k_i,
    .lut_read_b_i,
    .ready_o(special_ready),
    .valid_o(special_valid),
    .result_o(special_result),
    .illegal_opcode_o(),
    .lut_fault_o
  );
endmodule
