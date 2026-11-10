// New MXM boundary: queued control + physical Supercell array. FP32 column
// outputs connect to the independently instructed two-bank backend.
// Row zero is bottom. Stream selection occurs upstream using row commands.
module lpu_mxm_frontend #(
  parameter integer ROWS=lpu_mxm_config_pkg::SC_ROWS,
  parameter integer COLS=lpu_mxm_config_pkg::SC_COLS,
  parameter integer TERMS=lpu_mxm_config_pkg::CELL_K,
  parameter integer OUTPUTS=lpu_mxm_config_pkg::CELL_N,
  parameter integer QUEUE_DEPTH=lpu_mxm_config_pkg::INSTRUCTION_QUEUE_DEPTH
) (
  input logic clk_i,rst_ni,run_i,
  input logic compute_enqueue_valid_i,compute_launch_i,
  input lpu_mxm_isa_pkg::compute_instruction_t compute_instruction_i,
  output wire compute_enqueue_ready_o,compute_launch_ready_o,
  input logic load_enqueue_valid_i,load_launch_i,
  input lpu_mxm_isa_pkg::load_instruction_t load_instruction_i,
  output wire load_enqueue_ready_o,load_launch_ready_o,
  input logic [ROWS-1:0] activation_valid_i,weight_valid_i,
  input logic [ROWS*TERMS*16-1:0] activation_i,weight_i,
  output wire [ROWS-1:0] compute_row_valid_o,load_row_valid_o,
  output wire [ROWS*lpu_mxm_isa_pkg::COMPUTE_INSTRUCTION_BITS-1:0] compute_row_instruction_o,
  output wire [ROWS*lpu_mxm_isa_pkg::LOAD_INSTRUCTION_BITS-1:0] load_row_instruction_o,
  output wire [ROWS*16-1:0] compute_row_tag_o,load_row_index_o,
  output wire [COLS-1:0] result_valid_o,
  output wire [COLS*OUTPUTS*32-1:0] result_o,
  output wire [COLS*16-1:0] result_tag_o,
  output wire [COLS*lpu_mxm_isa_pkg::COMPUTE_INSTRUCTION_BITS-1:0] result_instruction_o,
  output wire [ROWS-1:0] activation_forward_valid_o,
  output wire [ROWS*TERMS*16-1:0] activation_forward_o,
  output wire [ROWS*COLS-1:0] cell_weight_valid_o,cell_weight_buffer_o,
  output wire [ROWS*COLS-1:0] cell_activation_valid_o,cell_activation_buffer_o,
  output wire fault_o
);
  import lpu_mxm_config_pkg::*;
  import lpu_mxm_isa_pkg::*;
  wire [ROWS*16-1:0] row_tags=compute_row_tag_o;
  wire control_fault;
  wire [ROWS*COLS-1:0] cell_fault;
  logic input_fault_q;
  lpu_mxm_control #(.ROWS(ROWS),.QUEUE_DEPTH(QUEUE_DEPTH)) u_control (
    .clk_i,.rst_ni,.run_i,.compute_enqueue_valid_i,.compute_enqueue_ready_o,.compute_instruction_i,
    .compute_launch_i,.compute_launch_ready_o,.load_enqueue_valid_i,.load_enqueue_ready_o,.load_instruction_i,
    .load_launch_i,.load_launch_ready_o,.compute_row_valid_o,.compute_row_update_o(),
    .compute_row_instruction_o,.compute_row_tag_o,
    .load_row_valid_o,.load_row_update_o(),.load_row_instruction_o,.load_row_index_o,.fault_o(control_fault));
  // Stopping run flushes the arithmetic/link validity, not SRAM data.
  wire cell_reset_n=rst_ni && run_i;
  wire [OUTPUTS-1:0] partial_valid[0:ROWS-1][0:COLS-1];
  wire [OUTPUTS*32-1:0] partial_data[0:ROWS-1][0:COLS-1];
  wire [OUTPUTS*16-1:0] partial_tags[0:ROWS-1][0:COLS-1];
  for(genvar r=0;r<ROWS;r++) begin : g_row
    wire [COLS:0] a_valid,a_buffer,w_valid,w_buffer;
    wire [TERMS*16-1:0] a_data[0:COLS],w_data[0:COLS];
    wire [15:0] a_tag[0:COLS];
    load_instruction_t load_cmd;
    assign load_cmd=load_row_instruction_o[r*LOAD_INSTRUCTION_BITS+:LOAD_INSTRUCTION_BITS];
    assign a_valid[0]=compute_row_valid_o[r] && activation_valid_i[r];
    assign a_data[0]=activation_i[r*TERMS*16+:TERMS*16];
    assign a_buffer[0]=compute_row_instruction_o[r*COMPUTE_INSTRUCTION_BITS];
    assign a_tag[0]=row_tags[r*16+:16];
    assign w_valid[0]=load_row_valid_o[r] && weight_valid_i[r];
    assign w_buffer[0]=load_cmd.weight_buffer;
    assign w_data[0]=weight_i[r*TERMS*16+:TERMS*16];
    assign activation_forward_valid_o[r]=a_valid[COLS];
    assign activation_forward_o[r*TERMS*16+:TERMS*16]=a_data[COLS];
    for(genvar c=0;c<COLS;c++) begin : g_column
      // Both load modes inject into the same registered shift chain. Mode
      // only selects the fixed local shift duration; it never travels as a data route.
      assign cell_weight_buffer_o[r*COLS+c]=w_buffer[c];
      assign cell_activation_valid_o[r*COLS+c]=a_valid[c];
      assign cell_activation_buffer_o[r*COLS+c]=a_buffer[c];
      wire [OUTPUTS-1:0] below_valid;
      wire [OUTPUTS*32-1:0] below_data;
      wire [OUTPUTS*16-1:0] below_tags;
      if(r==0) begin : g_bottom
        assign below_valid='0;assign below_data='0;assign below_tags='0;
      end else begin : g_upper
        assign below_valid=partial_valid[r-1][c];
        assign below_data=partial_data[r-1][c];
        assign below_tags=partial_tags[r-1][c];
      end
      lpu_mxm_supercell #(.TERMS(TERMS),.OUTPUTS(OUTPUTS),.BOTTOM(r==0),.LAST_COLUMN(c==COLS-1)) u_cell (
        .clk_i,.rst_ni(cell_reset_n),.activation_valid_i(a_valid[c]),.activation_i(a_data[c]),
        .weight_buffer_i(a_buffer[c]),.tag_i(a_tag[c]),
        .activation_valid_o(a_valid[c+1]),.activation_o(a_data[c+1]),
        .weight_buffer_o(a_buffer[c+1]),.activation_tag_o(a_tag[c+1]),
        .weight_write_valid_i(w_valid[c]),
        .weight_write_buffer_i(cell_weight_buffer_o[r*COLS+c]),
        .weight_write_data_i(w_data[c]),
        .weight_write_accepted_o(cell_weight_valid_o[r*COLS+c]),.weight_forward_valid_o(w_valid[c+1]),
        .weight_forward_buffer_o(w_buffer[c+1]),.weight_forward_data_o(w_data[c+1]),
        .weight_buffer_ready_o(),.weight_buffer_busy_o(),.below_valid_i(below_valid),
        .below_partial_i(below_data),.below_tag_i(below_tags),
        .dot_valid_o(),.dot_result_o(),.dot_tag_o(),.alignment_lost_o(),
        .partial_valid_o(partial_valid[r][c]),.partial_o(partial_data[r][c]),
        .partial_tag_o(partial_tags[r][c]),.fault_o(cell_fault[r*COLS+c]));
    end
  end
  // Hold transaction metadata through horizontal transit and all 12 local
  // stages. Changing an executing command cannot corrupt results in flight.
  wire [COLS-1:0] metadata_fault;
  for(genvar c=0;c<COLS;c++) begin : g_result
    localparam integer STAGES=DOT_PIPELINE_CYCLES+PARTIAL_ADD_CYCLES+c;
    logic [STAGES-1:0] valid_q;
    logic [COMPUTE_INSTRUCTION_BITS-1:0] command_q[0:STAGES-1];
    logic [15:0] tag_q[0:STAGES-1];
    always_ff @(posedge clk_i or negedge cell_reset_n) begin
      if(!cell_reset_n) begin
        valid_q<=0;
        for(integer s=0;s<STAGES;s++) begin command_q[s]<=0;tag_q[s]<=0;end
      end else begin
        valid_q<={valid_q[STAGES-2:0],compute_row_valid_o[ROWS-1] && activation_valid_i[ROWS-1]};
        command_q[0]<=compute_row_instruction_o[(ROWS-1)*COMPUTE_INSTRUCTION_BITS+:COMPUTE_INSTRUCTION_BITS];tag_q[0]<=row_tags[(ROWS-1)*16+:16];
        for(integer s=1;s<STAGES;s++) begin command_q[s]<=command_q[s-1];tag_q[s]<=tag_q[s-1];end
      end
    end
    assign result_valid_o[c]=&partial_valid[ROWS-1][c];
    assign result_o[c*OUTPUTS*32+:OUTPUTS*32]=partial_data[ROWS-1][c];
    assign result_tag_o[c*16+:16]=partial_tags[ROWS-1][c][0+:16];
    assign result_instruction_o[c*COMPUTE_INSTRUCTION_BITS+:COMPUTE_INSTRUCTION_BITS]=command_q[STAGES-1];
    assign metadata_fault[c]=(valid_q[STAGES-1]!=result_valid_o[c]) ||
      (result_valid_o[c] && tag_q[STAGES-1]!=result_tag_o[c*16+:16]);
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) input_fault_q<=0;
    else if(!run_i) input_fault_q<=0;
    else if((|(compute_row_valid_o & ~activation_valid_i)) ||
            (|(load_row_valid_o & ~weight_valid_i)) || (|metadata_fault)) input_fault_q<=1;
  end
  assign fault_o=control_fault || input_fault_q || (|cell_fault);
  initial if(ROWS<1 || COLS*OUTPUTS!=MATRIX_N || ROWS*TERMS!=MATRIX_K)
    $fatal(1,"Frontend dimensions must match the configured instruction shape");
endmodule
