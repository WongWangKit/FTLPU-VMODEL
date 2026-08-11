module lpu_icu #(
  parameter integer QUEUE_DEPTH = 16
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic run_i,

  input  logic         enqueue_valid_i,
  output logic         enqueue_ready_o,
  input  logic [7:0]   enqueue_queue_i,
  input  logic         enqueue_is_instruction_i,
  input  logic [31:0]  enqueue_command_i,
  input  logic [415:0] enqueue_payload_i,

  output logic [137:0]       issue_valid_o,
  output logic [138*416-1:0] issue_payload_o,
  output logic [137:0]       queue_fault_o
);
  logic [137:0] queue_ready;
  logic [137:0] queue_enqueue_valid;

  always_comb begin
    queue_enqueue_valid = '0;
    enqueue_ready_o = 1'b0;
    if (enqueue_queue_i < 8'd138) begin
      queue_enqueue_valid[enqueue_queue_i] = enqueue_valid_i;
      enqueue_ready_o = queue_ready[enqueue_queue_i];
    end
  end

  generate
    for (genvar queue = 0; queue < 138; queue++) begin : gen_queue
      logic [$clog2(QUEUE_DEPTH+1)-1:0] unused_level;
      lpu_icu_queue #(
        .PAYLOAD_WIDTH(416),
        .DEPTH(QUEUE_DEPTH),
        .APPLY_MEM_STRIDE(queue < 104)
      ) u_queue (
        .clk_i,
        .rst_ni,
        .run_i,
        .enqueue_valid_i(queue_enqueue_valid[queue]),
        .enqueue_ready_o(queue_ready[queue]),
        .enqueue_is_instruction_i,
        .enqueue_command_i,
        .enqueue_payload_i,
        .issue_valid_o(issue_valid_o[queue]),
        .issue_payload_o(issue_payload_o[queue*416 +: 416]),
        .fault_o(queue_fault_o[queue]),
        .level_o(unused_level)
      );
    end
  endgenerate
endmodule
