// Independent instruction queue for the accumulator/storage result positions.
// In lpu_mxm_core, position c is Superlane c at the left array edge.
// No automatic launch, operand feedback, destination routing or dynamic stalls.
module lpu_mxm_backend #(
  parameter integer COLS=lpu_mxm_config_pkg::SC_COLS,
  parameter integer LANES=lpu_mxm_config_pkg::CELL_N,
  parameter integer DEPTH=lpu_mxm_config_pkg::ACCUMULATOR_DEPTH,
  parameter integer QUEUE_DEPTH=lpu_mxm_config_pkg::INSTRUCTION_QUEUE_DEPTH,
  localparam integer ROW_BITS=DEPTH/2>1?$clog2(DEPTH/2):1,
  localparam integer ADDRESS_BITS=lpu_mxm_backend_isa_pkg::backend_address_bits(DEPTH),
  localparam integer INSTRUCTION_BITS=lpu_mxm_backend_isa_pkg::backend_instruction_bits(DEPTH)
) (
  input logic clk_i,rst_ni,run_i,
  input logic enqueue_valid_i,
  output wire enqueue_ready_o,
  input logic [INSTRUCTION_BITS-1:0] instruction_i,
  input logic launch_i,
  output wire launch_ready_o,
  input logic [COLS-1:0] partial_valid_i,
  input logic [COLS*LANES*32-1:0] partial_i,
  input logic [COLS*16-1:0] partial_tag_i,
  output wire [COLS-1:0] issue_valid_o,issue_bf16_o,
  output wire [COLS*16-1:0] issue_address_o,
  output wire [COLS*2-1:0] issue_operation_o,
  output wire [COLS-1:0] slot_valid_o,
  output wire [COLS*16-1:0] slot_address_o,
  output wire [COLS*2-1:0] slot_operation_o,
  output wire [COLS-1:0] slot_bf16_o,
  output wire [COLS-1:0] result_valid_o,
  output wire [COLS-1:0] result_bf16_o,
  output wire [COLS*LANES*32-1:0] result_o,
  output wire [COLS*16-1:0] result_address_o,result_tag_o,
  output wire [COLS*2-1:0] bank_request_valid_o,bank_write_o,
  output wire [COLS*2*ROW_BITS-1:0] bank_address_o,
  output wire [COLS*2*LANES*32-1:0] bank_write_data_o,
  output wire [COLS-1:0] alu_valid_o,
  output wire [COLS*LANES*32-1:0] operand_a_o,operand_b_o,
  output wire [COLS*16-1:0] alu_address_o,alu_tag_o,
  output wire fault_o
);
  import lpu_mxm_backend_isa_pkg::*;
  wire head_valid;
  wire [INSTRUCTION_BITS-1:0] head;
  wire legal_head=backend_fields_legal(DEPTH,int'(head[2+:ADDRESS_BITS]),head[1:0],head[INSTRUCTION_BITS-1]);
  wire pop=run_i && launch_i && head_valid;
  wire [COLS*INSTRUCTION_BITS-1:0] column_command;
  wire [COLS-1:0] column_fault;
  logic control_fault_q;
  assign launch_ready_o=run_i && head_valid;
  lpu_mxm_command_queue #(.WIDTH(INSTRUCTION_BITS),.DEPTH(QUEUE_DEPTH)) u_queue (
    .clk_i,.rst_ni,.enqueue_valid_i,.enqueue_ready_o,.enqueue_data_i(instruction_i),.pop_i(pop),.valid_o(head_valid),.data_o(head));
  // Returned data and backend commands advance between Superlanes one cycle
  // apart, independently of the three-cycle frontend compute instruction wave.
  lpu_mxm_instruction_wave #(.WIDTH(INSTRUCTION_BITS),.ROWS(COLS),.INTERVAL(lpu_mxm_config_pkg::RESULT_SUPERLANE_INTERVAL)) u_wave (
    .clk_i,.rst_ni,.run_i,.launch_i(pop && legal_head),.instruction_i(head),
    .launch_ready_o(),.row_valid_o(issue_valid_o),.row_update_o(),
    .row_instruction_o(column_command));
  for(genvar c=0;c<COLS;c++) begin : g_column
    assign issue_address_o[c*16+:16]=16'(column_command[c*INSTRUCTION_BITS+2+:ADDRESS_BITS]);
    assign issue_operation_o[c*2+:2]=column_command[c*INSTRUCTION_BITS+:2];
    assign issue_bf16_o[c]=column_command[c*INSTRUCTION_BITS+INSTRUCTION_BITS-1];
    lpu_mxm_backend_column #(.LANES(LANES),.DEPTH(DEPTH)) u_column (
      .clk_i,.rst_ni,.run_i,.slot_valid_i(issue_valid_o[c]),.operation_i(issue_operation_o[c*2+:2]),
      .output_bf16_i(issue_bf16_o[c]),
      .address_i(issue_address_o[c*16+:16]),.partial_valid_i(partial_valid_i[c]),
      .partial_i(partial_i[c*LANES*32+:LANES*32]),.partial_tag_i(partial_tag_i[c*16+:16]),
      .slot_valid_o(slot_valid_o[c]),.slot_address_o(slot_address_o[c*16+:16]),
      .slot_operation_o(slot_operation_o[c*2+:2]),.slot_bf16_o(slot_bf16_o[c]),
      .result_valid_o(result_valid_o[c]),.result_o(result_o[c*LANES*32+:LANES*32]),
      .result_bf16_o(result_bf16_o[c]),
      .result_address_o(result_address_o[c*16+:16]),.result_tag_o(result_tag_o[c*16+:16]),
      .bank_request_valid_o(bank_request_valid_o[c*2+:2]),.bank_write_o(bank_write_o[c*2+:2]),
      .bank_address_o(bank_address_o[c*2*ROW_BITS+:2*ROW_BITS]),
      .bank_write_data_o(bank_write_data_o[c*2*LANES*32+:2*LANES*32]),
      .alu_valid_o(alu_valid_o[c]),.operand_a_o(operand_a_o[c*LANES*32+:LANES*32]),
      .operand_b_o(operand_b_o[c*LANES*32+:LANES*32]),
      .alu_address_o(alu_address_o[c*16+:16]),.alu_tag_o(alu_tag_o[c*16+:16]),.fault_o(column_fault[c]));
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) control_fault_q<=0;
    else if(!run_i) control_fault_q<=0;
    else if(launch_i && (!launch_ready_o || !legal_head)) control_fault_q<=1;
  end
  assign fault_o=control_fault_q || (|column_fault);
  initial if(DEPTH<2 || DEPTH%2!=0 || DEPTH>65536)
    $fatal(1,"Invalid backend storage depth");
endmodule
