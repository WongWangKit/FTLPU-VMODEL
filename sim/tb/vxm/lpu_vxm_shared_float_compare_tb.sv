`timescale 1ns/1ps

module lpu_vxm_shared_float_compare_tb;
  import lpu_pkg::*;

  logic [1:0]  data_format;
  logic [31:0] lhs;
  logic [31:0] rhs;
  wire [31:0] lhs_sanitized;
  wire [31:0] rhs_sanitized;
  wire        lhs_magnitude_ge;
  wire        magnitude_equal;
  wire        lhs_less;
  wire [31:0] max_result;

  lpu_vxm_shared_float_compare dut (
    .data_format_i(data_format),
    .lhs_i(lhs),
    .rhs_i(rhs),
    .lhs_sanitized_o(lhs_sanitized),
    .rhs_sanitized_o(rhs_sanitized),
    .lhs_magnitude_ge_o(lhs_magnitude_ge),
    .magnitude_equal_o(magnitude_equal),
    .lhs_less_o(lhs_less),
    .max_result_o(max_result)
  );

  task automatic check_compare(
    input logic [1:0]  format,
    input logic [31:0] lhs_value,
    input logic [31:0] rhs_value,
    input logic [31:0] expected_lhs_sanitized,
    input logic [31:0] expected_rhs_sanitized,
    input logic        expected_magnitude_ge,
    input logic        expected_magnitude_equal,
    input logic        expected_lhs_less,
    input logic [31:0] expected_max
  );
    begin
      data_format = format;
      lhs = lhs_value;
      rhs = rhs_value;
      #1;
      if (lhs_sanitized !== expected_lhs_sanitized ||
          rhs_sanitized !== expected_rhs_sanitized)
        $fatal(1,
          "format=%0d sanitized lhs/rhs %h/%h expected %h/%h",
          format, lhs_sanitized, rhs_sanitized,
          expected_lhs_sanitized, expected_rhs_sanitized);
      if (lhs_magnitude_ge !== expected_magnitude_ge ||
          magnitude_equal !== expected_magnitude_equal ||
          lhs_less !== expected_lhs_less)
        $fatal(1,
          "format=%0d compare ge/eq/less %b/%b/%b expected %b/%b/%b",
          format, lhs_magnitude_ge, magnitude_equal, lhs_less,
          expected_magnitude_ge, expected_magnitude_equal,
          expected_lhs_less);
      if (max_result !== expected_max)
        $fatal(1, "format=%0d max %h expected %h",
          format, max_result, expected_max);
    end
  endtask

  initial begin
    data_format = VXM_FORMAT_FP16;
    lhs = '0;
    rhs = '0;
    #1;

    // FP16 and BF16 both use the complete shared low-15-bit comparator.
    check_compare(VXM_FORMAT_FP16, 32'h0000c000, 32'h00003e00,
                  32'h0000c000, 32'h00003e00,
                  1'b1, 1'b0, 1'b1, 32'h00003e00);
    check_compare(VXM_FORMAT_FP16, 32'h00003c01, 32'h00003c02,
                  32'h00003c01, 32'h00003c02,
                  1'b0, 1'b0, 1'b1, 32'h00003c02);
    check_compare(VXM_FORMAT_BF16, 32'h0000c000, 32'h00003fc0,
                  32'h0000c000, 32'h00003fc0,
                  1'b1, 1'b0, 1'b1, 32'h00003fc0);

    // FP32 first compares [30:15], then reuses the low-15-bit comparator
    // when the high portions match.
    check_compare(VXM_FORMAT_FP32, 32'h3f800000, 32'h40000000,
                  32'h3f800000, 32'h40000000,
                  1'b0, 1'b0, 1'b1, 32'h40000000);
    check_compare(VXM_FORMAT_FP32, 32'h3f800001, 32'h3f800002,
                  32'h3f800001, 32'h3f800002,
                  1'b0, 1'b0, 1'b1, 32'h3f800002);
    check_compare(VXM_FORMAT_FP32, 32'hbf800002, 32'hbf800001,
                  32'hbf800002, 32'hbf800001,
                  1'b1, 1'b0, 1'b1, 32'hbf800001);

    // Preserve the established MAX policy and FTZ behavior.
    check_compare(VXM_FORMAT_FP16, 32'h00007e01, 32'h00003c00,
                  32'h00007e00, 32'h00003c00,
                  1'b1, 1'b0, 1'b0, 32'h00007e00);
    check_compare(VXM_FORMAT_BF16, 32'h00003f80, 32'h00007fc1,
                  32'h00003f80, 32'h00007fc0,
                  1'b0, 1'b0, 1'b1, 32'h00003f80);
    check_compare(VXM_FORMAT_FP32, 32'h80000000, 32'h00000000,
                  32'h80000000, 32'h00000000,
                  1'b1, 1'b1, 1'b0, 32'h80000000);
    check_compare(VXM_FORMAT_FP16, 32'h00000001, 32'h00003c00,
                  32'h00000000, 32'h00003c00,
                  1'b0, 1'b0, 1'b1, 32'h00003c00);

    check_compare(VXM_FORMAT_RESERVED, 32'hffffffff, 32'h12345678,
                  32'h00000000, 32'h00000000,
                  1'b1, 1'b1, 1'b0, 32'h00000000);

    $display("LPU_VXM_SHARED_FLOAT_COMPARE_TB_PASS");
    $finish;
  end
endmodule
