module lpu_vxm_result_packer #(
  parameter integer HEMISPHERES = 2,
  parameter integer TILES       = 4,
  parameter integer LANES       = 8,
  parameter integer ALUS        = 16,
  parameter integer STREAMS     = 32
) (
  input  logic [TILES*ALUS-1:0] operation_success_i,
  input  logic [TILES*ALUS*2-1:0] cast_target_i,
  input  logic [TILES*ALUS-1:0] output_valid_i,
  input  logic [TILES*ALUS*6-1:0] output_stream_i,
  input  logic [TILES*ALUS-1:0] output_hemisphere_i,
  input  logic [TILES*ALUS*LANES*32-1:0] result_i,

  output logic [HEMISPHERES*TILES*STREAMS-1:0] produced_valid_o,
  output logic [HEMISPHERES*TILES*STREAMS*LANES*8-1:0]
    produced_data_o,
  output logic conflict_o
);
  import lpu_vxm_math_pkg::*;

  always_comb begin
    produced_valid_o = '0;
    produced_data_o = '0;
    conflict_o = 1'b0;

    for (integer tile = 0; tile < TILES; tile++) begin
      for (integer alu = 0; alu < ALUS; alu++) begin
        integer operation_index;
        integer output_bytes;
        logic [1:0] cast_target;
        logic [5:0] output_stream;
        logic output_hemisphere;

        operation_index = tile*ALUS+alu;
        cast_target = cast_target_i[operation_index*2 +: 2];
        output_stream = output_stream_i[operation_index*6 +: 6];
        output_hemisphere = output_hemisphere_i[operation_index];

        case (cast_target)
          2'd0: output_bytes = 4;
          2'd1, 2'd3: output_bytes = 2;
          default: output_bytes = 1;
        endcase

        if (operation_success_i[operation_index] &&
            output_valid_i[operation_index]) begin
          for (integer byte_index = 0;
               byte_index < 4; byte_index++) begin
            if ((byte_index < output_bytes) && produced_valid_o[
                  (output_hemisphere*TILES+tile)*STREAMS+
                  output_stream+byte_index]) begin
              conflict_o = 1'b1;
            end else if (byte_index < output_bytes) begin
              produced_valid_o[
                (output_hemisphere*TILES+tile)*STREAMS+
                output_stream+byte_index] = 1'b1;
              for (integer lane = 0; lane < LANES; lane++) begin
                logic signed [31:0] result;
                logic [31:0] output_bits;
                integer execute_index;

                execute_index = operation_index*LANES+lane;
                result = result_i[execute_index*32 +: 32];
                output_bits = result;
                case (cast_target)
                  2'd1: output_bits = {
                    16'b0, fp32_to_fp16(result)};
                  2'd2: output_bits = {
                    24'b0, saturate_int8(result)};
                  2'd3: output_bits = {
                    16'b0, fp32_to_bf16(result)};
                  default: output_bits = result;
                endcase
                produced_data_o[
                  ((output_hemisphere*TILES+tile)*STREAMS+
                   output_stream+byte_index)*LANES*8+
                  lane*8 +: 8] = output_bits[byte_index*8 +: 8];
              end
            end
          end
        end
      end
    end
  end
endmodule
