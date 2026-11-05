// New control: independent queues and compiler-timed fixed-phase launches.
module lpu_mxm_control #(
  parameter integer ROWS=lpu_mxm_config_pkg::SC_ROWS,
  parameter integer QUEUE_DEPTH=lpu_mxm_config_pkg::INSTRUCTION_QUEUE_DEPTH,
  parameter integer INTERVAL=lpu_mxm_config_pkg::SUPERLANE_INSTRUCTION_INTERVAL
) (
  input logic clk_i,rst_ni,run_i,
  input logic compute_enqueue_valid_i,
  output wire compute_enqueue_ready_o,
  input logic [63:0] compute_instruction_i,
  input logic compute_launch_i,
  output wire compute_launch_ready_o,
  input logic load_enqueue_valid_i,
  output wire load_enqueue_ready_o,
  input logic [63:0] load_instruction_i,
  input logic load_launch_i,
  output wire load_launch_ready_o,
  output wire [ROWS-1:0] compute_row_valid_o,compute_row_update_o,
  output wire [ROWS*64-1:0] compute_row_instruction_o,
  output wire [ROWS*16-1:0] compute_row_index_o,compute_row_tag_o,
  output wire [ROWS-1:0] load_row_valid_o,load_row_update_o,
  output wire [ROWS*64-1:0] load_row_instruction_o,
  output wire [ROWS*16-1:0] load_row_index_o,
  output logic fault_o
);
  import lpu_mxm_config_pkg::*;
  import lpu_mxm_isa_pkg::*;
  wire compute_head_valid,load_head_valid,compute_can_launch,load_can_launch;
  wire [63:0] compute_head,load_head;
  wire compute_legal_head=compute_legal(compute_head);
  wire load_legal_head=load_legal(load_head);
  wire compute_pop=run_i && compute_launch_i && compute_head_valid && compute_can_launch;
  wire load_pop=run_i && load_launch_i && load_head_valid && load_can_launch;
  wire [15:0] compute_count=compute_head[18:3];
  wire [15:0] load_count=load_head[1:0]==LOAD_MATRIX?16'(WEIGHT_LOAD_MATRIX_CYCLES):16'd1;
  logic [15:0] next_tag_q;
  wire [ROWS*80-1:0] compute_payload;
  assign compute_launch_ready_o=compute_head_valid && compute_can_launch;
  assign load_launch_ready_o=load_head_valid && load_can_launch;
  lpu_mxm_command_queue #(.DEPTH(QUEUE_DEPTH)) u_compute_queue (
    .clk_i,.rst_ni,.enqueue_valid_i(compute_enqueue_valid_i),.enqueue_ready_o(compute_enqueue_ready_o),
    .enqueue_data_i(compute_instruction_i),.pop_i(compute_pop),.valid_o(compute_head_valid),.data_o(compute_head));
  lpu_mxm_command_queue #(.DEPTH(QUEUE_DEPTH)) u_load_queue (
    .clk_i,.rst_ni,.enqueue_valid_i(load_enqueue_valid_i),.enqueue_ready_o(load_enqueue_ready_o),
    .enqueue_data_i(load_instruction_i),.pop_i(load_pop),.valid_o(load_head_valid),.data_o(load_head));
  lpu_mxm_instruction_wave #(.WIDTH(80),.ROWS(ROWS),.INTERVAL(INTERVAL)) u_compute_wave (
    .clk_i,.rst_ni,.run_i,.launch_i(compute_pop && compute_legal_head),
    .instruction_i({next_tag_q,compute_head}),.duration_i(compute_count),.launch_ready_o(compute_can_launch),
    .row_valid_o(compute_row_valid_o),.row_update_o(compute_row_update_o),
    .row_instruction_o(compute_payload),.row_index_o(compute_row_index_o));
  lpu_mxm_instruction_wave #(.ROWS(ROWS),.INTERVAL(INTERVAL)) u_load_wave (
    .clk_i,.rst_ni,.run_i,.launch_i(load_pop && load_legal_head),
    .instruction_i(load_head),.duration_i(load_count),.launch_ready_o(load_can_launch),
    .row_valid_o(load_row_valid_o),.row_update_o(load_row_update_o),
    .row_instruction_o(load_row_instruction_o),.row_index_o(load_row_index_o));
  for(genvar r=0;r<ROWS;r++) begin : g_payload
    assign compute_row_instruction_o[r*64+:64]=compute_payload[r*80+:64];
    assign compute_row_tag_o[r*16+:16]=compute_payload[r*80+64+:16]+compute_row_index_o[r*16+:16];
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin fault_o<=0;next_tag_q<=0;end
    else if(!run_i) begin fault_o<=0;next_tag_q<=0;end
    else begin
      if(compute_pop && compute_legal_head) next_tag_q<=next_tag_q+compute_count;
      if((compute_launch_i && (!compute_launch_ready_o || !compute_legal_head)) ||
         (load_launch_i && (!load_launch_ready_o || !load_legal_head))) fault_o<=1;
    end
  end
  initial if(!CONFIG_VALID || MATRIX_N>64 || ACCUMULATOR_DEPTH>65536)
    $fatal(1,"Configuration not representable by new MXM ISA");
endmodule
