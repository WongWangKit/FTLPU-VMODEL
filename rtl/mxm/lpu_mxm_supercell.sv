// Weight-stationary Supercell. No dynamic scheduling or backpressure.
// One activation vector broadcasts to every output group on the same edge.
// Group n computes sum_k activation[k]*weight[buffer][n][k], with TERMS
// multipliers per group. All groups have the same dot/partial output phase.
// Activation, buffer ID, tag and valid forward right through ONE register;
// the compiler arranges lower-partial inputs at simultaneous dot-valid.
module lpu_mxm_supercell #(
  parameter integer TERMS = lpu_mxm_config_pkg::CELL_K,
  parameter integer OUTPUTS = lpu_mxm_config_pkg::CELL_N,
  parameter integer TAG_WIDTH = 16,
  parameter bit BOTTOM = 1'b0,
  parameter bit LAST_COLUMN = 1'b0
) (
  input logic clk_i, rst_ni,
  input logic activation_valid_i,
  input logic [TERMS*16-1:0] activation_i,
  input logic weight_buffer_i,
  input logic [TAG_WIDTH-1:0] tag_i,
  // Shift one TERMS-weight group into group 0 of the selected buffer.
  // Its other groups advance right; register the old tail, valid and buffer ID
  // together for the next cell. This matches activation's one-edge cell link,
  // allowing the retiring buffer to be reloaded immediately at the left edge.
  input logic weight_write_valid_i,
  input logic weight_write_buffer_i,
  input logic [TERMS*16-1:0] weight_write_data_i,
  // COLUMN mode selectively replaces one group; the shift chain holds.
  input logic weight_column_mode_i,
  input logic [(OUTPUTS>1?$clog2(OUTPUTS):1)-1:0] weight_column_index_i,
  output logic weight_write_accepted_o,
  output logic weight_forward_valid_o,
  output logic weight_forward_buffer_o,
  output logic [TERMS*16-1:0] weight_forward_data_o,
  output logic [1:0] weight_buffer_ready_o,
  output logic [1:0] weight_buffer_busy_o,
  output logic activation_valid_o,
  output logic [TERMS*16-1:0] activation_o,
  output logic weight_buffer_o,
  output logic [TAG_WIDTH-1:0] activation_tag_o,
  input logic [OUTPUTS-1:0] below_valid_i,
  input logic [OUTPUTS*32-1:0] below_partial_i,
  input logic [OUTPUTS*TAG_WIDTH-1:0] below_tag_i,
  output wire [OUTPUTS-1:0] dot_valid_o,
  output wire [OUTPUTS*32-1:0] dot_result_o,
  output wire [OUTPUTS*TAG_WIDTH-1:0] dot_tag_o,
  output wire [OUTPUTS-1:0] alignment_lost_o,
  output wire [OUTPUTS-1:0] partial_valid_o,
  output wire [OUTPUTS*32-1:0] partial_o,
  output wire [OUTPUTS*TAG_WIDTH-1:0] partial_tag_o,
  output logic fault_o
);
  logic [TERMS*16-1:0] weights_q [0:1][0:OUTPUTS-1];
  logic [OUTPUTS-1:0] weight_valid_q [0:1];
  logic activation_valid_q, activation_buffer_q;
  logic [TERMS*16-1:0] activation_q;
  logic [TAG_WIDTH-1:0] tag_q;
  wire [OUTPUTS-1:0] group_valid;
  wire [OUTPUTS-1:0] group_buffer;
  wire [OUTPUTS*TERMS*16-1:0] group_activation;
  wire [OUTPUTS*TAG_WIDTH-1:0] group_tag;
  wire [OUTPUTS-1:0] input_weight_fault, partial_protocol_fault;

  always_comb begin
    weight_buffer_ready_o[0]=&weight_valid_q[0];
    weight_buffer_ready_o[1]=&weight_valid_q[1];
    weight_buffer_busy_o='0;
    // All groups capture their weights in M1 on the input acceptance edge.
    // Later arithmetic and the outgoing link register no longer read them.
    if (activation_valid_i) weight_buffer_busy_o[weight_buffer_i]=1'b1;
    weight_write_accepted_o=weight_write_valid_i &&
      !weight_buffer_busy_o[weight_write_buffer_i] &&
      (!weight_column_mode_i || int'(weight_column_index_i)<OUTPUTS);
  end

  assign activation_valid_o=activation_valid_q;
  assign activation_o=activation_q;
  assign weight_buffer_o=activation_buffer_q;
  assign activation_tag_o=tag_q;

  for (genvar group=0; group<OUTPUTS; group++) begin : g_output
    assign group_valid[group]=activation_valid_i;
    assign group_buffer[group]=weight_buffer_i;
    assign group_activation[group*TERMS*16 +: TERMS*16]=activation_i;
    assign group_tag[group*TAG_WIDTH +: TAG_WIDTH]=tag_i;
    assign input_weight_fault[group]=group_valid[group] &&
      !weight_valid_q[group_buffer[group]][group];

    lpu_mxm_bf16_dot_csa #(.TERMS(TERMS),.TAG_WIDTH(TAG_WIDTH)) u_dot (
      .clk_i, .rst_ni,
      .valid_i(group_valid[group] && !input_weight_fault[group]),
      .activation_i(group_activation[group*TERMS*16 +: TERMS*16]),
      .weight_i(weights_q[group_buffer[group]][group]),
      .tag_i(group_tag[group*TAG_WIDTH +: TAG_WIDTH]),
      .valid_o(dot_valid_o[group]),
      .result_o(dot_result_o[group*32 +: 32]),
      .tag_o(dot_tag_o[group*TAG_WIDTH +: TAG_WIDTH]),
      .alignment_lost_o(alignment_lost_o[group])
    );
    if (BOTTOM) begin : g_bottom
      assign partial_protocol_fault[group]=1'b0;
    end else begin : g_upper
      assign partial_protocol_fault[group]=
        (dot_valid_o[group] != below_valid_i[group]) ||
        (dot_valid_o[group] && below_valid_i[group] &&
         (dot_tag_o[group*TAG_WIDTH +: TAG_WIDTH] !=
          below_tag_i[group*TAG_WIDTH +: TAG_WIDTH]));
    end
    // The bottom also crosses the same three adder registers with +0.
    lpu_mxm_fp32_add_pipe #(.TAG_WIDTH(TAG_WIDTH)) u_partial_add (
      .clk_i, .rst_ni,
      .valid_i(dot_valid_o[group] && !partial_protocol_fault[group]),
      .lhs_i(dot_result_o[group*32 +: 32]),
      .rhs_i(BOTTOM ? 32'b0 : below_partial_i[group*32 +: 32]),
      .tag_i(dot_tag_o[group*TAG_WIDTH +: TAG_WIDTH]),
      .valid_o(partial_valid_o[group]),
      .result_o(partial_o[group*32 +: 32]),
      .tag_o(partial_tag_o[group*TAG_WIDTH +: TAG_WIDTH])
    );
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      activation_valid_q<='0; activation_buffer_q<='0;
      activation_q<='0; tag_q<='0;
      weight_valid_q[0]<='0; weight_valid_q[1]<='0;
      weight_forward_valid_o<=0;weight_forward_buffer_o<=0;weight_forward_data_o<=0;
      fault_o<=0;
      // Weight data is deliberately not reset; validity gates all reads.
    end else begin
      weight_forward_valid_o<=!LAST_COLUMN && !weight_column_mode_i && weight_write_accepted_o &&
        weight_valid_q[weight_write_buffer_i][OUTPUTS-1];
      if(!LAST_COLUMN && !weight_column_mode_i && weight_write_accepted_o && weight_valid_q[weight_write_buffer_i][OUTPUTS-1]) begin
        weight_forward_buffer_o<=weight_write_buffer_i;
        weight_forward_data_o<=weights_q[weight_write_buffer_i][OUTPUTS-1];
      end
      activation_valid_q<=activation_valid_i;
      if (activation_valid_i) begin
        activation_buffer_q<=weight_buffer_i;
        activation_q<=activation_i;
        tag_q<=tag_i;
      end
      if (weight_write_accepted_o) begin
        if(weight_column_mode_i) begin
          weights_q[weight_write_buffer_i][weight_column_index_i]<=weight_write_data_i;
          weight_valid_q[weight_write_buffer_i][weight_column_index_i]<=1'b1;
        end else begin
          weights_q[weight_write_buffer_i][0]<=weight_write_data_i;
          weight_valid_q[weight_write_buffer_i][0]<=1'b1;
          for (integer group=1; group<OUTPUTS; group++) begin
            weights_q[weight_write_buffer_i][group]<=weights_q[weight_write_buffer_i][group-1];
            weight_valid_q[weight_write_buffer_i][group]<=weight_valid_q[weight_write_buffer_i][group-1];
          end
        end
      end
      if ((weight_write_valid_i && !weight_write_accepted_o) ||
          (|input_weight_fault) || (|partial_protocol_fault)) fault_o<=1'b1;
    end
  end

  initial begin
    if (TERMS<1 || OUTPUTS<1 || TAG_WIDTH<1)
      $fatal(1,"Unsupported Supercell interface configuration");
    if (lpu_mxm_config_pkg::DATA_TYPE != lpu_mxm_config_pkg::MXM_DTYPE_BF16 ||
        lpu_mxm_config_pkg::WEIGHT_BUFFER_COUNT != 2)
      $fatal(1,"Supercell currently requires BF16 and two weight buffers");
  end
endmodule
