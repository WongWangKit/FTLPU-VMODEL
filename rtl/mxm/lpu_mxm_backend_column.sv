// One output column: LANES FP32 adders, two 1RW banks, no operand feedback.
// Compiler works backwards from the operand capture edge T:
// command launch T-3, read service T-2, B and array A available after T-1,
// A1/T A2/T+1 A3/T+2, writeback or common output register T+3.
// NO array-A registers precede A1. STORE uses the existing three-stage
// passthrough, giving all writes the same phase and preserving read->write D=5.
module lpu_mxm_backend_column #(
  parameter integer LANES=lpu_mxm_config_pkg::CELL_N,
  parameter integer DEPTH=lpu_mxm_config_pkg::ACCUMULATOR_DEPTH,
  localparam integer ROW_BITS=DEPTH/2>1?$clog2(DEPTH/2):1,
  localparam integer BITS=LANES*32,
  localparam integer META_BITS=35
) (
  input logic clk_i,rst_ni,run_i,
  // Early issue slot; slot_valid_o below is the matching A-capture slot.
  input logic slot_valid_i,
  input logic [1:0] operation_i,
  input logic output_bf16_i,
  input logic [15:0] address_i,
  input logic partial_valid_i,
  input logic [BITS-1:0] partial_i,
  input logic [15:0] partial_tag_i,
  output wire slot_valid_o,slot_bf16_o,
  output wire [1:0] slot_operation_o,
  output wire [15:0] slot_address_o,
  output wire result_valid_o,
  output wire result_bf16_o,
  output wire [BITS-1:0] result_o,
  output wire [15:0] result_address_o,result_tag_o,
  // Public monitors are also the actual bank and ALU interfaces, not models.
  output wire [1:0] bank_request_valid_o,bank_write_o,
  output wire [2*ROW_BITS-1:0] bank_address_o,
  output wire [2*BITS-1:0] bank_write_data_o,
  output wire alu_valid_o,
  output wire [BITS-1:0] operand_a_o,operand_b_o,
  output wire [15:0] alu_address_o,alu_tag_o,
  output logic fault_o
);
  import lpu_mxm_backend_isa_pkg::*;
  // Only narrow control travels through the two prefetch alignment stages.
  // The wide new-partial bus connects directly to the adder/passthrough input.
  logic [1:0] context_valid_q,context_ok_q;
  logic [18:0] context_q[0:1];
  wire [15:0] address=address_i;
  wire first_read=slot_valid_i && operation_i[1];
  wire scheduled_write=slot_valid_i && (operation_i==STORE || operation_i==ACC_STORE);
  wire [LANES-1:0] sum_valid;
  wire [BITS-1:0] sum_data;
  wire [LANES*META_BITS-1:0] sum_tags;
  wire [META_BITS-1:0] sum_meta=sum_tags[0+:META_BITS];
  logic [2:0] bypass_valid_q;
  logic [BITS-1:0] bypass_data_q[0:2];
  logic [META_BITS-1:0] bypass_meta_q[0:2];
  wire acc_write=run_i && (&sum_valid) && sum_meta[33:32]==ACC_STORE;
  wire direct_write=run_i && bypass_valid_q[2] && bypass_meta_q[2][33:32]==STORE;
  wire writeback=acc_write || direct_write;
  wire [META_BITS-1:0] writeback_meta=acc_write?sum_meta:bypass_meta_q[2];
  wire [BITS-1:0] writeback_data=acc_write?sum_data:bypass_data_q[2];
  wire [15:0] writeback_address=writeback_meta[31:16];
  wire bank_collision=first_read && writeback && address[0]==writeback_address[0];
  // Detect stale-data and overwritten-context hazards, in addition to ports.
  logic [4:0] pending_valid_q;
  logic [15:0] pending_address_q[0:4];
  logic address_hazard;
  always_comb begin
    address_hazard=0;
    for(integer p=0;p<5;p++)
      if(pending_valid_q[p] && pending_address_q[p]==address && (first_read || scheduled_write)) address_hazard=1;
  end
  wire first_ok=run_i && !bank_collision && !address_hazard && int'(address)<DEPTH;
  wire wb_ok=run_i && !bank_collision;
  wire [1:0] bank_read_valid,invalid_read;
  wire [BITS-1:0] bank_read_data[0:1];
  wire [ROW_BITS-1:0] bank_read_address[0:1];
  for(genvar b=0;b<2;b++) begin : g_bank
    wire first_here=first_read && first_ok && address[0]==1'(b);
    wire wb_here=writeback && wb_ok && writeback_address[0]==1'(b);
    assign bank_request_valid_o[b]=first_here || wb_here;
    assign bank_write_o[b]=wb_here;
    assign bank_address_o[b*ROW_BITS+:ROW_BITS]=wb_here?ROW_BITS'(writeback_address>>1):ROW_BITS'(address>>1);
    assign bank_write_data_o[b*BITS+:BITS]=writeback_data;
    lpu_mxm_accumulator_bank #(.WIDTH(BITS),.DEPTH(DEPTH/2)) u_bank (
      .clk_i,.rst_ni,.run_i,.request_valid_i(bank_request_valid_o[b]),.write_i(bank_write_o[b]),
      .address_i(bank_address_o[b*ROW_BITS+:ROW_BITS]),.write_data_i(bank_write_data_o[b*BITS+:BITS]),
      .read_valid_o(bank_read_valid[b]),.read_data_o(bank_read_data[b]),
      .read_address_o(bank_read_address[b]),.invalid_read_o(invalid_read[b]));
  end
  wire accepted_read=first_read && first_ok && !invalid_read[address[0]];
  assign slot_valid_o=run_i && context_valid_q[1];
  assign slot_bf16_o=context_q[1][18];
  assign slot_operation_o=context_q[1][17:16];
  assign slot_address_o=context_q[1][15:0];
  wire operand_bank=slot_address_o[0];
  wire response_mismatch=slot_valid_o && context_ok_q[1] && slot_operation_o[1] &&
    (!bank_read_valid[operand_bank] || bank_read_address[operand_bank]!=ROW_BITS'(slot_address_o>>1));
  assign operand_a_o=partial_i;
  assign operand_b_o=bank_read_data[operand_bank];
  assign alu_address_o=slot_address_o;
  assign alu_tag_o=partial_tag_i;
  assign alu_valid_o=slot_valid_o && context_ok_q[1] && partial_valid_i && slot_operation_o[1] && !response_mismatch;
  wire [META_BITS-1:0] operand_meta={context_q[1],partial_tag_i};
  for(genvar lane=0;lane<LANES;lane++) begin : g_add
    lpu_mxm_fp32_add_pipe #(.TAG_WIDTH(META_BITS)) u_add (
      .clk_i,.rst_ni(rst_ni && run_i),.valid_i(alu_valid_o),
      .lhs_i(operand_a_o[lane*32+:32]),.rhs_i(operand_b_o[lane*32+:32]),.tag_i(operand_meta),
      .valid_o(sum_valid[lane]),.result_o(sum_data[lane*32+:32]),.tag_o(sum_tags[lane*META_BITS+:META_BITS]));
  end
  wire acc_output=run_i && (&sum_valid) && sum_meta[33:32]==ACC_OUT;
  wire direct_output=run_i && bypass_valid_q[2] && bypass_meta_q[2][33:32]==DIRECT_OUT;
  wire [META_BITS-1:0] output_meta=acc_output?sum_meta:bypass_meta_q[2];
  lpu_mxm_output_pipe #(.LANES(LANES),.META_BITS(32)) u_output (
    .clk_i,.rst_ni(rst_ni && run_i),.valid_i(acc_output || direct_output),
    .bf16_i(output_meta[34]),.data_i(acc_output?sum_data:bypass_data_q[2]),.meta_i(output_meta[31:0]),
    .valid_o(result_valid_o),.bf16_o(result_bf16_o),.data_o(result_o),.meta_o({result_address_o,result_tag_o}));
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      context_valid_q<=0;context_ok_q<=0;bypass_valid_q<=0;
      context_q[0]<=0;context_q[1]<=0;
      pending_valid_q<=0;fault_o<=0;
      for(integer p=0;p<5;p++) pending_address_q[p]<=0;
      for(integer p=0;p<3;p++) begin bypass_data_q[p]<=0;bypass_meta_q[p]<=0;end
    end else if(!run_i) begin
      context_valid_q<=0;context_ok_q<=0;bypass_valid_q<=0;
      pending_valid_q<=0;fault_o<=0;
    end else begin
      context_valid_q<={context_valid_q[0],slot_valid_i};
      context_ok_q<={context_ok_q[0],slot_valid_i &&
        (operation_i==DIRECT_OUT || (operation_i==STORE && first_ok) || accepted_read)};
      context_q[0]<={output_bf16_i,operation_i,address_i};context_q[1]<=context_q[0];
      pending_valid_q<={pending_valid_q[3:0],scheduled_write && first_ok && (operation_i==STORE || accepted_read)};
      pending_address_q[0]<=address;
      for(integer p=1;p<5;p++) pending_address_q[p]<=pending_address_q[p-1];
      bypass_valid_q<={bypass_valid_q[1:0],slot_valid_o && context_ok_q[1] && partial_valid_i && !slot_operation_o[1]};
      bypass_data_q[0]<=partial_i;bypass_meta_q[0]<=operand_meta;
      for(integer p=1;p<3;p++) begin bypass_data_q[p]<=bypass_data_q[p-1];bypass_meta_q[p]<=bypass_meta_q[p-1];end
      if((slot_valid_o!=partial_valid_i) || bank_collision || address_hazard || (|invalid_read) ||
         (slot_valid_i && output_bf16_i && operation_i!=DIRECT_OUT && operation_i!=ACC_OUT) ||
         ((first_read || scheduled_write) && int'(address)>=DEPTH) || response_mismatch ||
         (acc_output && direct_output) || (acc_write && direct_write) || ((|sum_valid) && !(&sum_valid))) fault_o<=1;
    end
  end
  initial if(LANES<1 || DEPTH<2 || DEPTH%2!=0 || DEPTH>65536)
    $fatal(1,"Invalid backend column configuration");
endmodule
