// Independent, compiler-launched parameter-load and dequantization queues.
// Both streams propagate at the same row interval as weight-load commands.
// One dequant command must meet every actual INT8 input beat, including all
// MATRIX beats. No count expansion, automatic launch, stall or retry.
module lpu_mxm_dequant_control #(
  parameter integer ROWS=lpu_mxm_config_pkg::SC_ROWS,
  parameter integer QUEUE_DEPTH=lpu_mxm_config_pkg::INSTRUCTION_QUEUE_DEPTH,
  parameter integer INTERVAL=lpu_mxm_config_pkg::SUPERLANE_INSTRUCTION_INTERVAL
) (
  input logic clk_i,rst_ni,run_i,
  input logic param_load_enqueue_valid_i,param_load_launch_i,
  input lpu_mxm_isa_pkg::param_load_instruction_t param_load_instruction_i,
  output wire param_load_enqueue_ready_o,param_load_launch_ready_o,
  input logic dequant_enqueue_valid_i,dequant_launch_i,
  input lpu_mxm_isa_pkg::dequant_instruction_t dequant_instruction_i,
  output wire dequant_enqueue_ready_o,dequant_launch_ready_o,
  output wire [ROWS-1:0] param_load_row_valid_o,dequant_row_valid_o,
  output wire [ROWS*lpu_mxm_isa_pkg::PARAM_LOAD_INSTRUCTION_BITS-1:0] param_load_row_instruction_o,
  output wire [ROWS*lpu_mxm_isa_pkg::DEQUANT_INSTRUCTION_BITS-1:0] dequant_row_instruction_o,
  output logic fault_o
);
  import lpu_mxm_isa_pkg::*;
  wire param_head_valid,dequant_head_valid;
  wire [PARAM_LOAD_INSTRUCTION_BITS-1:0] param_head;
  wire [DEQUANT_INSTRUCTION_BITS-1:0] dequant_head;
  assign param_load_launch_ready_o=run_i && param_head_valid;
  assign dequant_launch_ready_o=run_i && dequant_head_valid;
  wire param_pop=param_load_launch_i && param_load_launch_ready_o;
  wire dequant_pop=dequant_launch_i && dequant_launch_ready_o;
  lpu_mxm_command_queue #(.WIDTH(PARAM_LOAD_INSTRUCTION_BITS),.DEPTH(QUEUE_DEPTH)) u_param_queue (
    .clk_i,.rst_ni,.enqueue_valid_i(param_load_enqueue_valid_i),.enqueue_ready_o(param_load_enqueue_ready_o),
    .enqueue_data_i(param_load_instruction_i),.pop_i(param_pop),.valid_o(param_head_valid),.data_o(param_head));
  lpu_mxm_command_queue #(.WIDTH(DEQUANT_INSTRUCTION_BITS),.DEPTH(QUEUE_DEPTH)) u_dequant_queue (
    .clk_i,.rst_ni,.enqueue_valid_i(dequant_enqueue_valid_i),.enqueue_ready_o(dequant_enqueue_ready_o),
    .enqueue_data_i(dequant_instruction_i),.pop_i(dequant_pop),.valid_o(dequant_head_valid),.data_o(dequant_head));
  lpu_mxm_instruction_wave #(.WIDTH(PARAM_LOAD_INSTRUCTION_BITS),.ROWS(ROWS),.INTERVAL(INTERVAL)) u_param_wave (
    .clk_i,.rst_ni,.run_i,.launch_i(param_pop),.instruction_i(param_head),.launch_ready_o(),
    .row_valid_o(param_load_row_valid_o),.row_update_o(),.row_instruction_o(param_load_row_instruction_o));
  lpu_mxm_instruction_wave #(.WIDTH(DEQUANT_INSTRUCTION_BITS),.ROWS(ROWS),.INTERVAL(INTERVAL)) u_dequant_wave (
    .clk_i,.rst_ni,.run_i,.launch_i(dequant_pop),.instruction_i(dequant_head),.launch_ready_o(),
    .row_valid_o(dequant_row_valid_o),.row_update_o(),.row_instruction_o(dequant_row_instruction_o));
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) fault_o<=0;
    else if(!run_i) fault_o<=0;
    else if((param_load_launch_i && !param_load_launch_ready_o) ||
            (dequant_launch_i && !dequant_launch_ready_o)) fault_o<=1;
  end
endmodule
