// New control: independent queues and compiler-timed fixed-phase launches.
module lpu_mxm_control #(
  parameter integer ROWS=lpu_mxm_config_pkg::SC_ROWS,
  parameter integer QUEUE_DEPTH=lpu_mxm_config_pkg::INSTRUCTION_QUEUE_DEPTH,
  parameter integer INTERVAL=lpu_mxm_config_pkg::SUPERLANE_INSTRUCTION_INTERVAL
) (
  input logic clk_i,rst_ni,run_i,
  input logic compute_enqueue_valid_i,
  output wire compute_enqueue_ready_o,
  input lpu_mxm_isa_pkg::compute_instruction_t compute_instruction_i,
  input logic compute_launch_i,
  output wire compute_launch_ready_o,
  input logic load_enqueue_valid_i,
  output wire load_enqueue_ready_o,
  input lpu_mxm_isa_pkg::load_instruction_t load_instruction_i,
  input logic load_launch_i,
  output wire load_launch_ready_o,
  output wire [ROWS-1:0] compute_row_valid_o,compute_row_update_o,
  output wire [ROWS*lpu_mxm_isa_pkg::COMPUTE_INSTRUCTION_BITS-1:0] compute_row_instruction_o,
  output wire [ROWS*16-1:0] compute_row_index_o,compute_row_tag_o,
  output wire [ROWS-1:0] load_row_valid_o,load_row_update_o,
  output wire [ROWS*lpu_mxm_isa_pkg::LOAD_INSTRUCTION_BITS-1:0] load_row_instruction_o,
  output wire [ROWS*16-1:0] load_row_index_o,
  output logic fault_o
);
  import lpu_mxm_config_pkg::*;
  import lpu_mxm_isa_pkg::*;
  wire compute_head_valid,load_head_valid,compute_can_launch,load_can_launch;
  wire [COMPUTE_INSTRUCTION_BITS-1:0] compute_head;
  wire [LOAD_INSTRUCTION_BITS-1:0] load_head;
  load_instruction_t load_cmd;
  assign load_cmd=load_head;
  wire compute_legal_head=compute_legal(compute_head);
  wire compute_pop=run_i && compute_launch_i && compute_head_valid && compute_can_launch;
  wire load_pop=run_i && load_launch_i && load_head_valid && load_can_launch;
  wire [COMPUTE_DURATION_BITS-1:0] compute_count=compute_duration(compute_head);
  wire [LOAD_DURATION_BITS-1:0] load_count=load_cmd.column_mode==LOAD_MATRIX?
    LOAD_DURATION_BITS'(WEIGHT_LOAD_MATRIX_CYCLES):LOAD_DURATION_BITS'(1);
  logic [15:0] next_tag_q;
  localparam integer PAYLOAD_BITS=16+COMPUTE_INSTRUCTION_BITS;
  wire [ROWS*PAYLOAD_BITS-1:0] compute_payload;
  wire [ROWS*COMPUTE_DURATION_BITS-1:0] compute_index;
  wire [ROWS*LOAD_DURATION_BITS-1:0] load_index;
  assign compute_launch_ready_o=compute_head_valid && compute_can_launch;
  assign load_launch_ready_o=load_head_valid && load_can_launch;
  lpu_mxm_command_queue #(.WIDTH(COMPUTE_INSTRUCTION_BITS),.DEPTH(QUEUE_DEPTH)) u_compute_queue (
    .clk_i,.rst_ni,.enqueue_valid_i(compute_enqueue_valid_i),.enqueue_ready_o(compute_enqueue_ready_o),
    .enqueue_data_i(compute_instruction_i),.pop_i(compute_pop),.valid_o(compute_head_valid),.data_o(compute_head));
  lpu_mxm_command_queue #(.WIDTH(LOAD_INSTRUCTION_BITS),.DEPTH(QUEUE_DEPTH)) u_load_queue (
    .clk_i,.rst_ni,.enqueue_valid_i(load_enqueue_valid_i),.enqueue_ready_o(load_enqueue_ready_o),
    .enqueue_data_i(load_instruction_i),.pop_i(load_pop),.valid_o(load_head_valid),.data_o(load_head));
  lpu_mxm_instruction_wave #(.WIDTH(PAYLOAD_BITS),.ROWS(ROWS),.INTERVAL(INTERVAL),.COUNT_BITS(COMPUTE_DURATION_BITS)) u_compute_wave (
    .clk_i,.rst_ni,.run_i,.launch_i(compute_pop && compute_legal_head),
    .instruction_i({next_tag_q,compute_head}),.duration_i(compute_count),.launch_ready_o(compute_can_launch),
    .row_valid_o(compute_row_valid_o),.row_update_o(compute_row_update_o),
    .row_instruction_o(compute_payload),.row_index_o(compute_index));
  lpu_mxm_instruction_wave #(.WIDTH(LOAD_INSTRUCTION_BITS),.ROWS(ROWS),.INTERVAL(INTERVAL),.COUNT_BITS(LOAD_DURATION_BITS)) u_load_wave (
    .clk_i,.rst_ni,.run_i,.launch_i(load_pop),
    .instruction_i(load_head),.duration_i(load_count),.launch_ready_o(load_can_launch),
    .row_valid_o(load_row_valid_o),.row_update_o(load_row_update_o),
    .row_instruction_o(load_row_instruction_o),.row_index_o(load_index));
  for(genvar r=0;r<ROWS;r++) begin : g_payload
    assign compute_row_instruction_o[r*COMPUTE_INSTRUCTION_BITS+:COMPUTE_INSTRUCTION_BITS]=compute_payload[r*PAYLOAD_BITS+:COMPUTE_INSTRUCTION_BITS];
    assign compute_row_index_o[r*16+:16]=16'(compute_index[r*COMPUTE_DURATION_BITS+:COMPUTE_DURATION_BITS]);
    assign load_row_index_o[r*16+:16]=16'(load_index[r*LOAD_DURATION_BITS+:LOAD_DURATION_BITS]);
    assign compute_row_tag_o[r*16+:16]=compute_payload[r*PAYLOAD_BITS+COMPUTE_INSTRUCTION_BITS+:16]+compute_row_index_o[r*16+:16];
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin fault_o<=0;next_tag_q<=0;end
    else if(!run_i) begin fault_o<=0;next_tag_q<=0;end
    else begin
      if(compute_pop && compute_legal_head) next_tag_q<=next_tag_q+compute_count;
      if((compute_launch_i && (!compute_launch_ready_o || !compute_legal_head)) ||
         (load_launch_i && !load_launch_ready_o)) fault_o<=1;
    end
  end
  initial if(!CONFIG_VALID || LOAD_DURATION_BITS>16 || ACCUMULATOR_DEPTH>65536)
    $fatal(1,"Configuration not representable by new MXM ISA");
endmodule
