module lpu_vxm_slice (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic run_i,

  input  logic [15:0] issue_valid_i,
  input  logic [16*128-1:0] issue_instruction_i,

  // VXM sits between the boundary-0 ends of the two MEM hemispheres.
  input  logic [2*4*32-1:0]    west_from_mem_valid_i,
  input  logic [2*4*32*64-1:0] west_from_mem_data_i,
  input  logic [2*4*32-1:0]    external_east_valid_i,
  input  logic [2*4*32*64-1:0] external_east_data_i,
  output wire [2*4*32-1:0]     east_to_mem_valid_o,
  output wire [2*4*32*64-1:0]  east_to_mem_data_o,

  output logic fault_o,
  output logic conflict_o
);
  localparam integer HEMISPHERES = 2;
  localparam integer TILES       = 4;
  localparam integer LANES       = 8;
  localparam integer ALUS        = 16;
  localparam integer STREAMS     = 32;
  localparam integer OPERATIONS  = TILES * ALUS;
  localparam integer EXECUTIONS  = OPERATIONS * LANES;

  logic [OPERATIONS-1:0] tile_valid;
  logic [OPERATIONS*128-1:0] tile_instruction;

  logic [EXECUTIONS*32-1:0] feedback_value_q;
  logic [EXECUTIONS-1:0] feedback_valid_q;
  logic [EXECUTIONS-1:0] feedback_float_q;

  wire [EXECUTIONS*32-1:0] result;
  wire [EXECUTIONS-1:0] result_valid;
  wire [EXECUTIONS-1:0] result_float;
  wire [OPERATIONS-1:0] operation_success;
  wire [OPERATIONS*2-1:0] cast_target;
  wire [OPERATIONS-1:0] output_valid;
  wire [OPERATIONS*6-1:0] output_stream;
  wire [OPERATIONS-1:0] output_hemisphere;
  wire [HEMISPHERES*TILES*STREAMS-1:0] west_consumed;
  wire execute_fault;

  wire [HEMISPHERES*TILES*STREAMS-1:0] produced_valid;
  wire [HEMISPHERES*TILES*STREAMS*LANES*8-1:0] produced_data;
  wire packer_conflict;

  wire [HEMISPHERES*TILES*STREAMS-1:0] bridge_east_valid;
  wire [HEMISPHERES*TILES*STREAMS*LANES*8-1:0] bridge_east_data;
  wire bridge_conflict;

  lpu_vxm_control u_control (
    .clk_i,
    .rst_ni,
    .issue_valid_i,
    .issue_instruction_i,
    .tile_valid_o(tile_valid),
    .tile_instruction_o(tile_instruction)
  );

  lpu_vxm_execute #(
    .HEMISPHERES(HEMISPHERES),
    .TILES(TILES),
    .LANES(LANES),
    .ALUS(ALUS),
    .STREAMS(STREAMS)
  ) u_execute (
    .run_i,
    .tile_valid_i(tile_valid),
    .tile_instruction_i(tile_instruction),
    .west_from_mem_valid_i,
    .west_from_mem_data_i,
    .external_east_valid_i,
    .external_east_data_i,
    .feedback_value_i(feedback_value_q),
    .feedback_valid_i(feedback_valid_q),
    .feedback_float_i(feedback_float_q),
    .result_o(result),
    .result_valid_o(result_valid),
    .result_float_o(result_float),
    .operation_success_o(operation_success),
    .cast_target_o(cast_target),
    .output_valid_o(output_valid),
    .output_stream_o(output_stream),
    .output_hemisphere_o(output_hemisphere),
    .west_consumed_o(west_consumed),
    .fault_o(execute_fault)
  );

  lpu_vxm_result_packer #(
    .HEMISPHERES(HEMISPHERES),
    .TILES(TILES),
    .LANES(LANES),
    .ALUS(ALUS),
    .STREAMS(STREAMS)
  ) u_result_packer (
    .operation_success_i(operation_success),
    .cast_target_i(cast_target),
    .output_valid_i(output_valid),
    .output_stream_i(output_stream),
    .output_hemisphere_i(output_hemisphere),
    .result_i(result),
    .produced_valid_o(produced_valid),
    .produced_data_o(produced_data),
    .conflict_o(packer_conflict)
  );

  lpu_vxm_stream_bridge #(
    .HEMISPHERES(HEMISPHERES),
    .TILES(TILES),
    .STREAMS(STREAMS),
    .WORD_WIDTH(LANES*8)
  ) u_stream_bridge (
    .west_from_mem_valid_i,
    .west_from_mem_data_i,
    .external_east_valid_i,
    .external_east_data_i,
    .west_consumed_i(west_consumed),
    .produced_valid_i(produced_valid),
    .produced_data_i(produced_data),
    .east_to_mem_valid_o(bridge_east_valid),
    .east_to_mem_data_o(bridge_east_data),
    .conflict_o(bridge_conflict)
  );

  assign east_to_mem_valid_o = bridge_east_valid;
  assign east_to_mem_data_o = bridge_east_data;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      feedback_value_q <= '0;
      feedback_valid_q <= '0;
      feedback_float_q <= '0;
      fault_o <= 1'b0;
      conflict_o <= 1'b0;
    end else if (!run_i) begin
      feedback_value_q <= '0;
      feedback_valid_q <= '0;
      feedback_float_q <= '0;
      fault_o <= 1'b0;
      conflict_o <= 1'b0;
    end else begin
      fault_o <= fault_o | execute_fault;
      conflict_o <= conflict_o | packer_conflict | bridge_conflict;
      for (integer execution = 0;
           execution < EXECUTIONS; execution++) begin
        if (result_valid[execution]) begin
          feedback_value_q[execution*32 +: 32] <=
            result[execution*32 +: 32];
          feedback_valid_q[execution] <= 1'b1;
          feedback_float_q[execution] <= result_float[execution];
        end
      end
    end
  end
endmodule
