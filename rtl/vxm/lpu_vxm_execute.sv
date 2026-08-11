module lpu_vxm_execute #(
  parameter integer HEMISPHERES = 2,
  parameter integer TILES       = 4,
  parameter integer LANES       = 8,
  parameter integer ALUS        = 16,
  parameter integer STREAMS     = 32
) (
  input  logic run_i,
  input  logic [TILES*ALUS-1:0] tile_valid_i,
  input  logic [TILES*ALUS*128-1:0] tile_instruction_i,

  input  logic [HEMISPHERES*TILES*STREAMS-1:0]
    west_from_mem_valid_i,
  input  logic [HEMISPHERES*TILES*STREAMS*LANES*8-1:0]
    west_from_mem_data_i,
  input  logic [HEMISPHERES*TILES*STREAMS-1:0]
    external_east_valid_i,
  input  logic [HEMISPHERES*TILES*STREAMS*LANES*8-1:0]
    external_east_data_i,

  input  logic [TILES*ALUS*LANES*32-1:0] feedback_value_i,
  input  logic [TILES*ALUS*LANES-1:0] feedback_valid_i,
  input  logic [TILES*ALUS*LANES-1:0] feedback_float_i,

  output logic [TILES*ALUS*LANES*32-1:0] result_o,
  output logic [TILES*ALUS*LANES-1:0] result_valid_o,
  output logic [TILES*ALUS*LANES-1:0] result_float_o,

  output logic [TILES*ALUS-1:0] operation_success_o,
  output logic [TILES*ALUS*2-1:0] cast_target_o,
  output logic [TILES*ALUS-1:0] output_valid_o,
  output logic [TILES*ALUS*6-1:0] output_stream_o,
  output logic [TILES*ALUS-1:0] output_hemisphere_o,

  output logic [HEMISPHERES*TILES*STREAMS-1:0] west_consumed_o,
  output logic fault_o
);
  import lpu_vxm_math_pkg::*;

  localparam integer OPERATIONS = TILES * ALUS;
  localparam integer EXECUTIONS = OPERATIONS * LANES;

  logic [EXECUTIONS-1:0] execute_request;
  logic [EXECUTIONS-1:0] execute_float;
  logic [EXECUTIONS*5-1:0] execute_opcode;
  logic [EXECUTIONS*2-1:0] execute_cast_target;
  logic [EXECUTIONS*32-1:0] execute_lhs;
  logic [EXECUTIONS*32-1:0] execute_rhs;
  wire [EXECUTIONS*32-1:0] execute_result;
  wire [EXECUTIONS-1:0] execute_result_valid;
  wire [EXECUTIONS-1:0] execute_fault;

  function automatic logic stream_valid(
    input integer hemisphere,
    input integer tile,
    input integer stream
  );
    begin
      if ((stream < 0) || (stream >= 2*STREAMS))
        stream_valid = 1'b0;
      else if (stream < STREAMS)
        stream_valid = external_east_valid_i[
          (hemisphere*TILES+tile)*STREAMS+stream];
      else
        stream_valid = west_from_mem_valid_i[
          (hemisphere*TILES+tile)*STREAMS+stream-STREAMS];
    end
  endfunction

  function automatic logic [7:0] stream_byte(
    input integer hemisphere,
    input integer tile,
    input integer stream,
    input integer lane
  );
    begin
      if ((stream < 0) || (stream >= 2*STREAMS))
        stream_byte = 8'b0;
      else if (stream < STREAMS)
        stream_byte = external_east_data_i[
          ((hemisphere*TILES+tile)*STREAMS+stream)*LANES*8+
          lane*8 +: 8];
      else
        stream_byte = west_from_mem_data_i[
          ((hemisphere*TILES+tile)*STREAMS+stream-STREAMS)*LANES*8+
          lane*8 +: 8];
    end
  endfunction

  function automatic integer operand_bytes(input logic [2:0] kind);
    begin
      case (kind)
        3'd1, 3'd3: operand_bytes = 4;
        3'd5, 3'd6: operand_bytes = 2;
        3'd4:       operand_bytes = 1;
        default:    operand_bytes = 0;
      endcase
    end
  endfunction

  lpu_vxm_alu #(
    .COUNT(EXECUTIONS)
  ) u_alu_bank (
    .request_valid_i(execute_request),
    .floating_i(execute_float),
    .opcode_i(execute_opcode),
    .cast_target_i(execute_cast_target),
    .lhs_i(execute_lhs),
    .rhs_i(execute_rhs),
    .result_o(execute_result),
    .result_valid_o(execute_result_valid),
    .fault_o(execute_fault)
  );

  always_comb begin
    execute_request = '0;
    execute_float = '0;
    execute_opcode = '0;
    execute_cast_target = '0;
    execute_lhs = '0;
    execute_rhs = '0;
    result_o = '0;
    result_valid_o = '0;
    result_float_o = '0;
    operation_success_o = '0;
    cast_target_o = '0;
    output_valid_o = '0;
    output_stream_o = '0;
    output_hemisphere_o = '0;
    west_consumed_o = '0;
    fault_o = 1'b0;

    if (run_i) begin
      for (integer tile = 0; tile < TILES; tile++) begin
        for (integer alu = 0; alu < ALUS; alu++) begin
          integer operation_index;
          operation_index = tile*ALUS+alu;

          if (tile_valid_i[operation_index]) begin
            logic [127:0] instruction;
            logic [4:0] opcode;
            logic [2:0] lhs_kind;
            logic [5:0] lhs_index;
            logic [2:0] rhs_kind;
            logic [5:0] rhs_index;
            logic [1:0] cast_target;
            logic output_valid;
            logic [5:0] output_stream;
            logic input_hemisphere;
            logic output_hemisphere;
            logic instruction_ok;
            logic floating_instruction;
            logic execution_ok;
            integer output_bytes;

            instruction = tile_instruction_i[
              operation_index*128 +: 128];
            opcode = instruction[4:0];
            lhs_kind = instruction[7:5];
            lhs_index = instruction[13:8];
            rhs_kind = instruction[16:14];
            rhs_index = instruction[22:17];
            cast_target = instruction[24:23];
            output_valid = instruction[25];
            output_stream = instruction[31:26];
            input_hemisphere = instruction[96];
            output_hemisphere = instruction[97];
            instruction_ok = (instruction[127:98] == '0) &&
                             (opcode <= 5'd15) &&
                             (lhs_kind <= 3'd6) &&
                             (rhs_kind <= 3'd6);
            floating_instruction =
              (lhs_kind == 3'd3) || (lhs_kind == 3'd5) ||
              (lhs_kind == 3'd6) || (rhs_kind == 3'd3) ||
              (rhs_kind == 3'd5) || (rhs_kind == 3'd6) ||
              (cast_target != 2'd2) ||
              ((lhs_kind == 3'd2) &&
               !fp32_is_integral(instruction[63:32])) ||
              ((rhs_kind == 3'd2) &&
               !fp32_is_integral(instruction[95:64]));

            case (cast_target)
              2'd0: output_bytes = 4;
              2'd1, 2'd3: output_bytes = 2;
              default: output_bytes = 1;
            endcase

            if (floating_instruction) begin
              if (!((lhs_kind == 3'd0) || (lhs_kind == 3'd2) ||
                    (lhs_kind == 3'd3) || (lhs_kind == 3'd5) ||
                    (lhs_kind == 3'd6)))
                instruction_ok = 1'b0;
              if (!((rhs_kind == 3'd0) || (rhs_kind == 3'd2) ||
                    (rhs_kind == 3'd3) || (rhs_kind == 3'd5) ||
                    (rhs_kind == 3'd6)))
                instruction_ok = 1'b0;
              if (!((opcode == 5'd0) || (opcode == 5'd1) ||
                    (opcode == 5'd2) || (opcode == 5'd3) ||
                    (opcode == 5'd4) ||
                    (opcode == 5'd5) || (opcode == 5'd6) ||
                    (opcode == 5'd7) || (opcode == 5'd8) ||
                    (opcode == 5'd12) ||
                    (opcode == 5'd14) || (opcode == 5'd15)))
                instruction_ok = 1'b0;
              if (cast_target == 2'd2)
                instruction_ok = 1'b0;
            end else begin
              if (!((lhs_kind == 3'd0) || (lhs_kind == 3'd2) ||
                    (lhs_kind == 3'd4)))
                instruction_ok = 1'b0;
              if (!((rhs_kind == 3'd0) || (rhs_kind == 3'd2) ||
                    (rhs_kind == 3'd4)))
                instruction_ok = 1'b0;
              if ((lhs_kind == 3'd2) &&
                  !fp32_is_integral(instruction[63:32]))
                instruction_ok = 1'b0;
              if ((rhs_kind == 3'd2) &&
                  !fp32_is_integral(instruction[95:64]))
                instruction_ok = 1'b0;
              if (!((opcode == 5'd0) || (opcode == 5'd1) ||
                    (opcode == 5'd2) || (opcode == 5'd3) ||
                    (opcode == 5'd4) || (opcode == 5'd5) ||
                    (opcode == 5'd6) || (opcode == 5'd7) ||
                    (opcode == 5'd8) || (opcode == 5'd10) ||
                    (opcode == 5'd14) || (opcode == 5'd15)))
                instruction_ok = 1'b0;
            end

            if (output_valid &&
                ((output_stream + output_bytes) > STREAMS))
              instruction_ok = 1'b0;
            if ((operand_bytes(lhs_kind) != 0) &&
                ((lhs_index + operand_bytes(lhs_kind)) > 2*STREAMS))
              instruction_ok = 1'b0;
            if ((operand_bytes(rhs_kind) != 0) &&
                ((rhs_index + operand_bytes(rhs_kind)) > 2*STREAMS))
              instruction_ok = 1'b0;
            execution_ok = instruction_ok;

            cast_target_o[operation_index*2 +: 2] = cast_target;
            output_valid_o[operation_index] = output_valid;
            output_stream_o[operation_index*6 +: 6] = output_stream;
            output_hemisphere_o[operation_index] = output_hemisphere;

            for (integer lane = 0; lane < LANES; lane++) begin
              logic signed [31:0] lhs;
              logic signed [31:0] rhs;
              logic lhs_valid;
              logic rhs_valid;
              logic [31:0] lhs_raw;
              logic [31:0] rhs_raw;
              logic [15:0] packed16;
              integer execute_index;
              integer feedback_index;

              lhs = '0;
              rhs = '0;
              lhs_valid = 1'b1;
              rhs_valid = 1'b1;
              lhs_raw = '0;
              rhs_raw = '0;
              packed16 = '0;
              execute_index = operation_index*LANES+lane;

              case (lhs_kind)
                3'd0: begin
                  if (lhs_index < ALUS)
                    feedback_index =
                      (tile*ALUS+lhs_index)*LANES+lane;
                  else
                    feedback_index = 0;
                  lhs_valid = (lhs_index < ALUS) &&
                    feedback_valid_i[feedback_index] &&
                    (feedback_float_i[feedback_index] ==
                     floating_instruction);
                  if (lhs_index < ALUS)
                    lhs = feedback_value_i[
                      feedback_index*32 +: 32];
                end
                3'd2: begin
                  if (floating_instruction)
                    lhs = $signed(instruction[63:32]);
                  else
                    lhs = fp32_to_sint(instruction[63:32]);
                end
                3'd3: begin
                  for (integer byte_index = 0;
                       byte_index < 4; byte_index++) begin
                    lhs_valid = lhs_valid && stream_valid(
                      input_hemisphere, tile, lhs_index+byte_index);
                    lhs_raw[byte_index*8 +: 8] = stream_byte(
                      input_hemisphere, tile, lhs_index+byte_index, lane);
                  end
                  lhs = $signed(lhs_raw);
                end
                3'd4: begin
                  lhs_valid = stream_valid(
                    input_hemisphere, tile, lhs_index);
                  lhs = $signed(stream_byte(
                    input_hemisphere, tile, lhs_index, lane));
                end
                3'd5, 3'd6: begin
                  lhs_valid = stream_valid(
                    input_hemisphere, tile, lhs_index) && stream_valid(
                    input_hemisphere, tile, lhs_index+1);
                  packed16[7:0] = stream_byte(
                    input_hemisphere, tile, lhs_index, lane);
                  packed16[15:8] = stream_byte(
                    input_hemisphere, tile, lhs_index+1, lane);
                  if (lhs_kind == 3'd5)
                    lhs = $signed(fp16_to_fp32(packed16));
                  else
                    lhs = $signed({packed16, 16'b0});
                end
                default: lhs_valid = 1'b0;
              endcase

              packed16 = '0;
              case (rhs_kind)
                3'd0: begin
                  if (rhs_index < ALUS)
                    feedback_index =
                      (tile*ALUS+rhs_index)*LANES+lane;
                  else
                    feedback_index = 0;
                  rhs_valid = (rhs_index < ALUS) &&
                    feedback_valid_i[feedback_index] &&
                    (feedback_float_i[feedback_index] ==
                     floating_instruction);
                  if (rhs_index < ALUS)
                    rhs = feedback_value_i[
                      feedback_index*32 +: 32];
                end
                3'd2: begin
                  if (floating_instruction)
                    rhs = $signed(instruction[95:64]);
                  else
                    rhs = fp32_to_sint(instruction[95:64]);
                end
                3'd3: begin
                  for (integer byte_index = 0;
                       byte_index < 4; byte_index++) begin
                    rhs_valid = rhs_valid && stream_valid(
                      input_hemisphere, tile, rhs_index+byte_index);
                    rhs_raw[byte_index*8 +: 8] = stream_byte(
                      input_hemisphere, tile, rhs_index+byte_index, lane);
                  end
                  rhs = $signed(rhs_raw);
                end
                3'd4: begin
                  rhs_valid = stream_valid(
                    input_hemisphere, tile, rhs_index);
                  rhs = $signed(stream_byte(
                    input_hemisphere, tile, rhs_index, lane));
                end
                3'd5, 3'd6: begin
                  rhs_valid = stream_valid(
                    input_hemisphere, tile, rhs_index) && stream_valid(
                    input_hemisphere, tile, rhs_index+1);
                  packed16[7:0] = stream_byte(
                    input_hemisphere, tile, rhs_index, lane);
                  packed16[15:8] = stream_byte(
                    input_hemisphere, tile, rhs_index+1, lane);
                  if (rhs_kind == 3'd5)
                    rhs = $signed(fp16_to_fp32(packed16));
                  else
                    rhs = $signed({packed16, 16'b0});
                end
                default: rhs_valid = 1'b0;
              endcase

              execute_request[execute_index] =
                instruction_ok && lhs_valid && rhs_valid;
              execute_float[execute_index] = floating_instruction;
              execute_opcode[execute_index*5 +: 5] = opcode;
              execute_cast_target[execute_index*2 +: 2] = cast_target;
              execute_lhs[execute_index*32 +: 32] = lhs;
              execute_rhs[execute_index*32 +: 32] = rhs;
              result_o[execute_index*32 +: 32] =
                execute_result[execute_index*32 +: 32];
              result_valid_o[execute_index] =
                execute_result_valid[execute_index];
              result_float_o[execute_index] = floating_instruction;
              execution_ok = execution_ok &&
                execute_result_valid[execute_index] &&
                !execute_fault[execute_index];
            end

            operation_success_o[operation_index] = execution_ok;
            if (!execution_ok)
              fault_o = 1'b1;

            if (execution_ok) begin
              for (integer byte_index = 0;
                   byte_index < 4; byte_index++)
                if ((byte_index < operand_bytes(lhs_kind)) &&
                    ((lhs_index + byte_index) >= STREAMS))
                  west_consumed_o[
                    (input_hemisphere*TILES+tile)*STREAMS+
                    lhs_index+byte_index-STREAMS] = 1'b1;
              for (integer byte_index = 0;
                   byte_index < 4; byte_index++)
                if ((byte_index < operand_bytes(rhs_kind)) &&
                    ((rhs_index + byte_index) >= STREAMS))
                  west_consumed_o[
                    (input_hemisphere*TILES+tile)*STREAMS+
                    rhs_index+byte_index-STREAMS] = 1'b1;
            end
          end
        end
      end
    end
  end
endmodule
