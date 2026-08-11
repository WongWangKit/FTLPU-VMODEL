module lpu_vxm_alu #(
  parameter integer COUNT = 1
) (
  input  logic [COUNT-1:0]      request_valid_i,
  input  logic [COUNT-1:0]      floating_i,
  input  logic [COUNT*5-1:0]    opcode_i,
  input  logic [COUNT*2-1:0]    cast_target_i,
  input  logic [COUNT*32-1:0]   lhs_i,
  input  logic [COUNT*32-1:0]   rhs_i,
  output logic [COUNT*32-1:0]   result_o,
  output logic [COUNT-1:0]      result_valid_o,
  output logic [COUNT-1:0]      fault_o
);
  import lpu_vxm_math_pkg::*;

  function automatic logic fp32_is_nan(input logic [31:0] value);
    fp32_is_nan = (value[30:23] == 8'hff) && (value[22:0] != 0);
  endfunction

  function automatic logic fp32_is_normal_or_zero(input logic [31:0] value);
    fp32_is_normal_or_zero = (value[30:0] == 0) ||
      ((value[30:23] != 0) && (value[30:23] != 8'hff));
  endfunction

  function automatic logic fp32_less(
    input logic [31:0] lhs,
    input logic [31:0] rhs
  );
    begin
      if ((lhs[30:0] == 0) && (rhs[30:0] == 0))
        fp32_less = 1'b0;
      else if (lhs[31] != rhs[31])
        fp32_less = lhs[31];
      else if (lhs[31])
        fp32_less = lhs[30:0] > rhs[30:0];
      else
        fp32_less = lhs[30:0] < rhs[30:0];
    end
  endfunction

  function automatic logic [26:0] fp32_shift_right_sticky(
    input logic [26:0] value,
    input integer distance
  );
    logic [26:0] shifted;
    logic sticky;
    begin
      sticky = 1'b0;
      for (integer bit_index = 0; bit_index < 27; bit_index++)
        if (bit_index < distance)
          sticky = sticky | value[bit_index];
      if (distance >= 27)
        shifted = '0;
      else
        shifted = value >> distance;
      shifted[0] = shifted[0] | sticky;
      fp32_shift_right_sticky = shifted;
    end
  endfunction

  function automatic logic [31:0] fp32_add_rne(
    input logic [31:0] lhs,
    input logic [31:0] rhs
  );
    logic sign_big;
    logic sign_small;
    logic [7:0] exponent_big;
    logic [7:0] exponent_small;
    logic [26:0] significand_big;
    logic [26:0] significand_small;
    logic [26:0] aligned_small;
    logic [27:0] sum;
    logic [26:0] normalized;
    logic [24:0] rounded;
    logic [23:0] final_significand;
    integer exponent;
    integer distance;
    begin
      if (lhs[30:0] == 0 && rhs[30:0] == 0)
        fp32_add_rne = {lhs[31] & rhs[31], 31'b0};
      else if (lhs[30:0] == 0)
        fp32_add_rne = rhs;
      else if (rhs[30:0] == 0)
        fp32_add_rne = lhs;
      else begin
        if (lhs[30:0] >= rhs[30:0]) begin
          sign_big = lhs[31];
          sign_small = rhs[31];
          exponent_big = lhs[30:23];
          exponent_small = rhs[30:23];
          significand_big = {1'b1, lhs[22:0], 3'b0};
          significand_small = {1'b1, rhs[22:0], 3'b0};
        end else begin
          sign_big = rhs[31];
          sign_small = lhs[31];
          exponent_big = rhs[30:23];
          exponent_small = lhs[30:23];
          significand_big = {1'b1, rhs[22:0], 3'b0};
          significand_small = {1'b1, lhs[22:0], 3'b0};
        end
        exponent = exponent_big;
        distance = exponent_big - exponent_small;
        aligned_small = fp32_shift_right_sticky(
          significand_small, distance);
        if (sign_big == sign_small) begin
          sum = {1'b0, significand_big} + {1'b0, aligned_small};
          if (sum[27]) begin
            normalized = sum[27:1];
            normalized[0] = normalized[0] | sum[0];
            exponent = exponent + 1;
          end else
            normalized = sum[26:0];
        end else begin
          normalized = significand_big - aligned_small;
          if (normalized == 0) begin
            fp32_add_rne = 32'b0;
            normalized = '0;
          end else begin
            for (integer normalize_step = 0;
                 normalize_step < 26; normalize_step++)
              if (!normalized[26] && (exponent > 1)) begin
                normalized = normalized << 1;
                exponent = exponent - 1;
              end
          end
        end

        if (normalized != 0) begin
          if ((exponent == 1) && !normalized[26])
            fp32_add_rne = 32'h7fc00001;
          else begin
            rounded = {1'b0, normalized[26:3]};
            if (normalized[2] &&
                (normalized[1] || normalized[0] || normalized[3]))
              rounded = rounded + 1'b1;
            if (rounded[24]) begin
              final_significand = rounded[24:1];
              exponent = exponent + 1;
            end else
              final_significand = rounded[23:0];
            if (exponent >= 255)
              fp32_add_rne = {sign_big, 8'hff, 23'b0};
            else
              fp32_add_rne = {
                sign_big, exponent[7:0], final_significand[22:0]};
          end
        end
      end
    end
  endfunction

  function automatic logic [31:0] fp32_multiply_rne(
    input logic [31:0] lhs,
    input logic [31:0] rhs
  );
    logic sign;
    logic [23:0] lhs_significand;
    logic [23:0] rhs_significand;
    logic [47:0] product;
    logic [23:0] significand;
    logic guard_bit;
    logic round_bit;
    logic sticky_bit;
    logic [24:0] rounded;
    integer exponent;
    begin
      sign = lhs[31] ^ rhs[31];
      if ((lhs[30:0] == 0) || (rhs[30:0] == 0))
        fp32_multiply_rne = {sign, 31'b0};
      else begin
        lhs_significand = {1'b1, lhs[22:0]};
        rhs_significand = {1'b1, rhs[22:0]};
        product = lhs_significand * rhs_significand;
        exponent = lhs[30:23] + rhs[30:23] - 127;
        if (product[47]) begin
          significand = product[47:24];
          guard_bit = product[23];
          round_bit = product[22];
          sticky_bit = |product[21:0];
          exponent = exponent + 1;
        end else begin
          significand = product[46:23];
          guard_bit = product[22];
          round_bit = product[21];
          sticky_bit = |product[20:0];
        end
        rounded = {1'b0, significand};
        if (guard_bit && (round_bit || sticky_bit || significand[0]))
          rounded = rounded + 1'b1;
        if (rounded[24]) begin
          significand = rounded[24:1];
          exponent = exponent + 1;
        end else
          significand = rounded[23:0];
        if (exponent <= 0)
          fp32_multiply_rne = 32'h7fc00001;
        else if (exponent >= 255)
          fp32_multiply_rne = {sign, 8'hff, 23'b0};
        else
          fp32_multiply_rne = {
            sign, exponent[7:0], significand[22:0]};
      end
    end
  endfunction

  always_comb begin
    result_o = '0;
    result_valid_o = '0;
    fault_o = '0;

    for (integer execution = 0; execution < COUNT; execution++) begin
      logic signed [31:0] lhs;
      logic signed [31:0] rhs;
      logic signed [31:0] result;
      logic [4:0] opcode;
      logic [1:0] cast_target;
      logic operation_fault;

      lhs = $signed(lhs_i[execution*32 +: 32]);
      rhs = $signed(rhs_i[execution*32 +: 32]);
      opcode = opcode_i[execution*5 +: 5];
      cast_target = cast_target_i[execution*2 +: 2];
      result = '0;
      operation_fault = 1'b0;

      if (request_valid_i[execution]) begin
        if (floating_i[execution]) begin
          if (fp32_is_nan(lhs) || fp32_is_nan(rhs)) begin
            operation_fault = 1'b1;
          end else if (((opcode == 5'd1) || (opcode == 5'd2) ||
                        (opcode == 5'd3)) &&
                       (!fp32_is_normal_or_zero(lhs) ||
                        !fp32_is_normal_or_zero(rhs))) begin
            operation_fault = 1'b1;
          end else begin
            case (opcode)
              5'd0: result = lhs;
              5'd1: result = fp32_add_rne(lhs, rhs);
              5'd2: result = fp32_add_rne(
                lhs, {~rhs[31], rhs[30:0]});
              5'd3: result = fp32_multiply_rne(lhs, rhs);
              5'd4: result = fp32_divide_rne(lhs, rhs);
              5'd5: result = {~lhs[31], lhs[30:0]};
              5'd6: result = {1'b0, lhs[30:0]};
              5'd7: result = fp32_less(rhs, lhs) ? rhs : lhs;
              5'd8: result = fp32_less(lhs, rhs) ? rhs : lhs;
              5'd12: result = fp32_exp_approx(lhs);
              5'd14: result = lhs[31] ? 32'b0 : lhs;
              5'd15: begin
                if (cast_target == 2'd3)
                  result = {fp32_to_bf16(lhs), 16'b0};
                else
                  result = lhs;
              end
              default: operation_fault = 1'b1;
            endcase
            if (fp32_is_nan(result))
              operation_fault = 1'b1;
          end
        end else begin
          case (opcode)
            5'd0, 5'd15: result = lhs;
            5'd1: result = lhs + rhs;
            5'd2: result = lhs - rhs;
            5'd3: result = lhs * rhs;
            5'd4: begin
              if (rhs == 0)
                operation_fault = 1'b1;
              else
                result = lhs / rhs;
            end
            5'd5: result = -lhs;
            5'd6: result = (lhs < 0) ? -lhs : lhs;
            5'd7: result = (lhs < rhs) ? lhs : rhs;
            5'd8: result = (lhs > rhs) ? lhs : rhs;
            5'd10: result = lhs * lhs;
            5'd14: result = (lhs < 0) ? 0 : lhs;
            default: operation_fault = 1'b1;
          endcase
        end

        result_o[execution*32 +: 32] = result;
        fault_o[execution] = operation_fault;
        result_valid_o[execution] = !operation_fault;
      end
    end
  end
endmodule
