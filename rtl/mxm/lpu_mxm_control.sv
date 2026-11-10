// Independent queues; count-free compute beats and fixed-mode weight loads.
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
  output wire [ROWS*16-1:0] compute_row_tag_o,
  output wire [ROWS-1:0] load_row_valid_o,load_row_update_o,
  output wire [ROWS*lpu_mxm_isa_pkg::LOAD_INSTRUCTION_BITS-1:0] load_row_instruction_o,
  output wire [ROWS*16-1:0] load_row_index_o,
  output logic fault_o
);
  import lpu_mxm_config_pkg::*;
  import lpu_mxm_isa_pkg::*;
  wire compute_head_valid,load_head_valid;
  wire [COMPUTE_INSTRUCTION_BITS-1:0] compute_head;
  wire [LOAD_INSTRUCTION_BITS-1:0] load_head;
  wire [ROWS-1:0] load_arrival;
  logic [LOAD_CYCLE_BITS-1:0] load_remaining_q[0:ROWS-1],load_index_q[0:ROWS-1];
  // A mode load arriving after launch is already valid for its first shift.
  // These counters belong ONLY to fixed MATRIX/COLUMN loading, never compute.
  wire load_busy=load_arrival[0] ? (!load_row_instruction_o[0] && MATRIX_N>1) : load_remaining_q[0]>1;
  assign compute_launch_ready_o=run_i && compute_head_valid;
  assign load_launch_ready_o=run_i && load_head_valid && !load_busy;
  wire compute_pop=compute_launch_i && compute_launch_ready_o;
  wire load_pop=load_launch_i && load_launch_ready_o;
  logic [15:0] next_tag_q;
  localparam integer PAYLOAD_BITS=16+COMPUTE_INSTRUCTION_BITS;
  wire [ROWS*PAYLOAD_BITS-1:0] compute_payload;
  lpu_mxm_command_queue #(.WIDTH(COMPUTE_INSTRUCTION_BITS),.DEPTH(QUEUE_DEPTH)) u_compute_queue (
    .clk_i,.rst_ni,.enqueue_valid_i(compute_enqueue_valid_i),.enqueue_ready_o(compute_enqueue_ready_o),
    .enqueue_data_i(compute_instruction_i),.pop_i(compute_pop),.valid_o(compute_head_valid),.data_o(compute_head));
  lpu_mxm_command_queue #(.WIDTH(LOAD_INSTRUCTION_BITS),.DEPTH(QUEUE_DEPTH)) u_load_queue (
    .clk_i,.rst_ni,.enqueue_valid_i(load_enqueue_valid_i),.enqueue_ready_o(load_enqueue_ready_o),
    .enqueue_data_i(load_instruction_i),.pop_i(load_pop),.valid_o(load_head_valid),.data_o(load_head));
  lpu_mxm_instruction_wave #(.WIDTH(PAYLOAD_BITS),.ROWS(ROWS),.INTERVAL(INTERVAL)) u_compute_wave (
    .clk_i,.rst_ni,.run_i,.launch_i(compute_pop),.instruction_i({next_tag_q,compute_head}),
    .launch_ready_o(),.row_valid_o(compute_row_valid_o),.row_update_o(compute_row_update_o),
    .row_instruction_o(compute_payload));
  lpu_mxm_instruction_wave #(.WIDTH(LOAD_INSTRUCTION_BITS),.ROWS(ROWS),.INTERVAL(INTERVAL)) u_load_wave (
    .clk_i,.rst_ni,.run_i,.launch_i(load_pop),.instruction_i(load_head),.launch_ready_o(),
    .row_valid_o(load_arrival),.row_update_o(),.row_instruction_o(load_row_instruction_o));
  for(genvar r=0;r<ROWS;r++) begin : g_payload
    assign compute_row_instruction_o[r*COMPUTE_INSTRUCTION_BITS+:COMPUTE_INSTRUCTION_BITS]=compute_payload[r*PAYLOAD_BITS+:COMPUTE_INSTRUCTION_BITS];
    assign compute_row_tag_o[r*16+:16]=compute_payload[r*PAYLOAD_BITS+COMPUTE_INSTRUCTION_BITS+:16];
    assign load_row_valid_o[r]=run_i && (load_arrival[r] || load_remaining_q[r]!=0);
    assign load_row_update_o[r]=load_arrival[r];
    assign load_row_index_o[r*16+:16]=load_arrival[r]?16'b0:16'(load_index_q[r]);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if(!rst_ni) begin load_remaining_q[r]<=0;load_index_q[r]<=0;end
      else if(!run_i) begin load_remaining_q[r]<=0;load_index_q[r]<=0;end
      else if(load_arrival[r]) begin
        load_remaining_q[r]<=load_row_instruction_o[r*LOAD_INSTRUCTION_BITS]?0:LOAD_CYCLE_BITS'(MATRIX_N-1);
        load_index_q[r]<=1;
      end else if(load_remaining_q[r]!=0) begin
        load_remaining_q[r]<=load_remaining_q[r]-1'b1;
        load_index_q[r]<=load_index_q[r]+1'b1;
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin fault_o<=0;next_tag_q<=0;end
    else if(!run_i) begin fault_o<=0;next_tag_q<=0;end
    else begin
      if(compute_pop) next_tag_q<=next_tag_q+1'b1;
      if((compute_launch_i && !compute_launch_ready_o) || (load_launch_i && !load_launch_ready_o)) fault_o<=1;
    end
  end
  initial if(!CONFIG_VALID || LOAD_CYCLE_BITS>16)
    $fatal(1,"Configuration not representable by new MXM ISA");
endmodule
