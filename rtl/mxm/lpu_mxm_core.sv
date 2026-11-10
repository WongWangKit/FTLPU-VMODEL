// Complete new BF16 array + independently scheduled FP32 accumulator/storage
// backend. Top results return down/left to local Superlane accumulators.
// Raw top and returned-left buses are exposed separately; no stream formatter.
module lpu_mxm_core #(
  parameter integer ROWS=lpu_mxm_config_pkg::SC_ROWS,
  parameter integer COLS=lpu_mxm_config_pkg::SC_COLS,
  parameter integer TERMS=lpu_mxm_config_pkg::CELL_K,
  parameter integer OUTPUTS=lpu_mxm_config_pkg::CELL_N,
  parameter integer QUEUE_DEPTH=lpu_mxm_config_pkg::INSTRUCTION_QUEUE_DEPTH,
  localparam integer BANK_ROW_BITS=lpu_mxm_config_pkg::ACCUMULATOR_DEPTH/2>1?$clog2(lpu_mxm_config_pkg::ACCUMULATOR_DEPTH/2):1
) (
  input logic clk_i,rst_ni,run_i,
  input logic compute_enqueue_valid_i,compute_launch_i,
  input lpu_mxm_isa_pkg::compute_instruction_t compute_instruction_i,
  output wire compute_enqueue_ready_o,compute_launch_ready_o,
  input logic load_enqueue_valid_i,load_launch_i,
  input lpu_mxm_isa_pkg::load_instruction_t load_instruction_i,
  output wire load_enqueue_ready_o,load_launch_ready_o,
  input logic backend_enqueue_valid_i,backend_launch_i,
  input lpu_mxm_backend_isa_pkg::backend_instruction_t backend_instruction_i,
  output wire backend_enqueue_ready_o,backend_launch_ready_o,
  input logic [ROWS-1:0] activation_valid_i,weight_valid_i,
  input logic [ROWS*TERMS*16-1:0] activation_i,weight_i,
  output wire [ROWS-1:0] compute_row_valid_o,load_row_valid_o,
  output wire [ROWS*lpu_mxm_isa_pkg::COMPUTE_INSTRUCTION_BITS-1:0] compute_row_instruction_o,
  output wire [ROWS*lpu_mxm_isa_pkg::LOAD_INSTRUCTION_BITS-1:0] load_row_instruction_o,
  output wire [ROWS*16-1:0] compute_row_tag_o,load_row_index_o,
  output wire [COLS-1:0] partial_valid_o,result_valid_o,
  output wire [COLS-1:0] result_bf16_o,
  output wire [COLS*OUTPUTS*32-1:0] partial_o,result_o,
  output wire [COLS*16-1:0] partial_tag_o,result_address_o,result_tag_o,
  output wire [ROWS-1:0] returned_valid_o,
  output wire [ROWS*OUTPUTS*32-1:0] returned_o,
  output wire [ROWS*16-1:0] returned_tag_o,
  // Actual backend control/bank interfaces for cycle-level integration checks.
  output wire [COLS-1:0] backend_slot_valid_o,
  output wire [COLS-1:0] backend_slot_bf16_o,
  output wire [COLS*2-1:0] backend_slot_operation_o,
  output wire [COLS*16-1:0] backend_slot_address_o,
  output wire [COLS-1:0] backend_issue_valid_o,backend_issue_bf16_o,
  output wire [COLS*16-1:0] backend_issue_address_o,
  output wire [COLS*2-1:0] backend_issue_operation_o,
  output wire [COLS-1:0] alu_valid_o,
  output wire [COLS*OUTPUTS*32-1:0] operand_a_o,operand_b_o,
  output wire [COLS*16-1:0] alu_address_o,alu_tag_o,
  output wire [ROWS*COLS-1:0] cell_weight_valid_o,cell_weight_buffer_o,
  output wire [ROWS*COLS-1:0] cell_activation_valid_o,cell_activation_buffer_o,
  output wire [COLS*2-1:0] bank_request_valid_o,bank_write_o,
  output wire [COLS*2*BANK_ROW_BITS-1:0] bank_address_o,
  output wire frontend_fault_o,backend_fault_o,
  output wire fault_o
);
  wire front_fault,backend_fault;
  lpu_mxm_frontend #(.ROWS(ROWS),.COLS(COLS),.TERMS(TERMS),.OUTPUTS(OUTPUTS),.QUEUE_DEPTH(QUEUE_DEPTH)) u_frontend (
    .clk_i,.rst_ni,.run_i,.compute_enqueue_valid_i,.compute_launch_i,.compute_instruction_i,
    .compute_enqueue_ready_o,.compute_launch_ready_o,.load_enqueue_valid_i,.load_launch_i,.load_instruction_i,
    .load_enqueue_ready_o,.load_launch_ready_o,.activation_valid_i,.weight_valid_i,.activation_i,.weight_i,
    .compute_row_valid_o,.load_row_valid_o,.compute_row_instruction_o,.load_row_instruction_o,
    .compute_row_tag_o,.load_row_index_o,.result_valid_o(partial_valid_o),.result_o(partial_o),
    .result_tag_o(partial_tag_o),.result_instruction_o(),.activation_forward_valid_o(),.activation_forward_o(),
    .cell_weight_valid_o,.cell_weight_buffer_o,.cell_activation_valid_o,.cell_activation_buffer_o,.fault_o(front_fault));
  lpu_mxm_result_return #(.ROWS(ROWS),.COLS(COLS),.LANES(OUTPUTS)) u_result_return (
    .clk_i,.rst_ni,.run_i,.top_valid_i(partial_valid_o),.top_i(partial_o),.top_tag_i(partial_tag_o),
    .left_valid_o(returned_valid_o),.left_o(returned_o),.left_tag_o(returned_tag_o),
    .down_valid_o(),.left_link_valid_o(),.down_o(),.left_link_o(),.down_tag_o(),.left_link_tag_o());
  // Index c is now physical Superlane c at the left edge. The existing
  // accumulator datapath, banks, ISA and one-cycle command relay are unchanged.
  lpu_mxm_backend #(.COLS(COLS),.LANES(OUTPUTS),.QUEUE_DEPTH(QUEUE_DEPTH)) u_backend (
    .clk_i,.rst_ni,.run_i,.enqueue_valid_i(backend_enqueue_valid_i),.enqueue_ready_o(backend_enqueue_ready_o),
    .instruction_i(backend_instruction_i),.launch_i(backend_launch_i),.launch_ready_o(backend_launch_ready_o),
    .partial_valid_i(returned_valid_o),.partial_i(returned_o),.partial_tag_i(returned_tag_o),
    .issue_valid_o(backend_issue_valid_o),.issue_bf16_o(backend_issue_bf16_o),
    .issue_address_o(backend_issue_address_o),.issue_operation_o(backend_issue_operation_o),
    .slot_valid_o(backend_slot_valid_o),.slot_address_o(backend_slot_address_o),.slot_operation_o(backend_slot_operation_o),.slot_bf16_o(backend_slot_bf16_o),
    .result_valid_o,.result_bf16_o,.result_o,.result_address_o,.result_tag_o,
    .bank_request_valid_o,.bank_write_o,.bank_address_o,.bank_write_data_o(),.alu_valid_o,
    .operand_a_o,.operand_b_o,.alu_address_o,.alu_tag_o,.fault_o(backend_fault));
  assign fault_o=front_fault || backend_fault;
  assign frontend_fault_o=front_fault;
  assign backend_fault_o=backend_fault;
endmodule
