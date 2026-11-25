module lpu_mxm_macro_frontend #(
	parameter integer QUEUE_KIND = lpu_mxm_isa_pkg::MXM_QUEUE_LOAD,
	parameter integer ACTIVE_CONTEXTS = 4,
	parameter integer ACCUMULATOR_ROWS = lpu_mxm_config_pkg::ACCUMULATOR_DEPTH,
	parameter integer WORD_FIFO_DEPTH = 4,
	parameter integer CONTEXT_FIFO_DEPTH = 4
) (
	input logic clk_i,
	input logic rst_ni,
	input logic run_i,
	input logic prime_i,
	input logic [31:0] schedule_cycle_i,

	input  logic fetch_word_valid_i,
	output logic fetch_word_ready_o,
	input  logic [127:0] fetch_word_i,
	input  logic fetch_word_last_i,

	output logic issue_valid_o,
	input  logic issue_ready_i,
	output logic [48:0] issue_instruction_o,
	output logic [31:0] issue_cycle_o,

	output logic decoder_done_o,
	output logic [$clog2(WORD_FIFO_DEPTH+1)-1:0] word_fifo_level_o,
	output logic [$clog2(CONTEXT_FIFO_DEPTH+1)-1:0] context_fifo_level_o,
	output logic [$clog2(ACTIVE_CONTEXTS+1)-1:0] active_count_o,
	output logic idle_o,
	output logic prime_ready_o,
	output logic fault_o,
	output logic [4:0] fault_code_o
);
	localparam integer CONTEXT_WIDTH = 288;

	logic word_fifo_valid;
	logic word_fifo_ready;
	logic [128:0] word_fifo_data;
	logic word_fifo_enqueue_ready;
	logic decoder_context_valid;
	logic decoder_context_ready;
	logic [48:0] decoder_instruction;
	logic [31:0] decoder_start_cycle;
	logic [31:0] decoder_inner_count;
	logic [31:0] decoder_inner_interval;
	logic signed [31:0] decoder_inner_stride;
	logic [31:0] decoder_outer_count;
	logic [31:0] decoder_outer_interval;
	logic signed [31:0] decoder_outer_stride;
	logic [1:0] decoder_induction_target;
	logic [12:0] decoder_operand;
	logic decoder_fault;
	logic [3:0] decoder_fault_code;
	logic [CONTEXT_WIDTH-1:0] context_fifo_input_data;
	logic [CONTEXT_WIDTH-1:0] context_fifo_output_data;
	logic context_fifo_valid;
	logic context_fifo_ready;
	logic [48:0] scheduler_instruction;
	logic [31:0] scheduler_start_cycle;
	logic [31:0] scheduler_inner_count;
	logic [31:0] scheduler_inner_interval;
	logic signed [31:0] scheduler_inner_stride;
	logic [31:0] scheduler_outer_count;
	logic [31:0] scheduler_outer_interval;
	logic signed [31:0] scheduler_outer_stride;
	logic [1:0] scheduler_induction_target;
	logic [12:0] scheduler_operand;
	logic scheduler_conflict;
	logic scheduler_fault;
	logic [3:0] scheduler_fault_code;

	assign fault_o = decoder_fault || scheduler_fault;
	assign fault_code_o = decoder_fault ? {1'b0, decoder_fault_code} : {1'b1, scheduler_fault_code};
	assign fetch_word_ready_o = word_fifo_enqueue_ready && !fault_o;
	assign idle_o = (word_fifo_level_o == '0) && (context_fifo_level_o == '0) && (active_count_o == '0);
	assign prime_ready_o = prime_i && decoder_done_o && (context_fifo_level_o == '0) && !fault_o;

	// The Word FIFO decouples fixed-latency Local-iMEM Fetch from variable-rate bit parsing.
	lpu_fifo #(
		.DATA_WIDTH(129),
		.DEPTH(WORD_FIFO_DEPTH)
	) u_word_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i(fetch_word_valid_i && !fault_o),
		.enqueue_ready_o(word_fifo_enqueue_ready),
		.enqueue_data_i({fetch_word_last_i, fetch_word_i}),
		.dequeue_valid_o(word_fifo_valid),
		.dequeue_ready_i(word_fifo_ready),
		.dequeue_data_o(word_fifo_data),
		.level_o(word_fifo_level_o)
	);

	// One shared parser implementation is elaborated independently for each MXM Stream.
	lpu_mxm_macro_decoder_core #(
		.QUEUE_KIND(QUEUE_KIND),
		.ACCUMULATOR_ROWS(ACCUMULATOR_ROWS)
	) u_decoder (
		.clk_i,
		.rst_ni,
		.word_valid_i(word_fifo_valid),
		.word_ready_o(word_fifo_ready),
		.word_i(word_fifo_data[127:0]),
		.word_last_i(word_fifo_data[128]),
		.context_valid_o(decoder_context_valid),
		.context_ready_i(decoder_context_ready),
		.context_instruction_o(decoder_instruction),
		.context_start_cycle_o(decoder_start_cycle),
		.context_inner_count_o(decoder_inner_count),
		.context_inner_interval_o(decoder_inner_interval),
		.context_inner_stride_o(decoder_inner_stride),
		.context_outer_count_o(decoder_outer_count),
		.context_outer_interval_o(decoder_outer_interval),
		.context_outer_stride_o(decoder_outer_stride),
		.context_induction_target_o(decoder_induction_target),
		.context_operand_o(decoder_operand),
		.done_o(decoder_done_o),
		.fault_o(decoder_fault),
		.fault_code_o(decoder_fault_code)
	);

	assign context_fifo_input_data = {decoder_induction_target, decoder_operand,
		decoder_outer_stride, decoder_outer_interval, decoder_outer_count,
		decoder_inner_stride, decoder_inner_interval, decoder_inner_count,
		decoder_start_cycle, decoder_instruction};
	assign {scheduler_induction_target, scheduler_operand,
		scheduler_outer_stride, scheduler_outer_interval, scheduler_outer_count,
		scheduler_inner_stride, scheduler_inner_interval, scheduler_inner_count,
		scheduler_start_cycle, scheduler_instruction} = context_fifo_output_data;

	// The Context FIFO isolates bitstream backpressure from Active Context admission.
	lpu_fifo #(
		.DATA_WIDTH(CONTEXT_WIDTH),
		.DEPTH(CONTEXT_FIFO_DEPTH)
	) u_context_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i(decoder_context_valid && !fault_o),
		.enqueue_ready_o(decoder_context_ready),
		.enqueue_data_i(context_fifo_input_data),
		.dequeue_valid_o(context_fifo_valid),
		.dequeue_ready_i(context_fifo_ready),
		.dequeue_data_o(context_fifo_output_data),
		.level_o(context_fifo_level_o)
	);

	// The Scheduler is the final absolute-cycle owner and directly handshakes with Instruction Wave.
	lpu_mxm_macro_scheduler_core #(
		.QUEUE_KIND(QUEUE_KIND),
		.ACTIVE_CONTEXTS(ACTIVE_CONTEXTS),
		.ACCUMULATOR_ROWS(ACCUMULATOR_ROWS)
	) u_scheduler (
		.clk_i,
		.rst_ni,
		.run_i,
		.schedule_cycle_i,
		.context_valid_i(context_fifo_valid),
		.context_ready_o(context_fifo_ready),
		.context_instruction_i(scheduler_instruction),
		.context_start_cycle_i(scheduler_start_cycle),
		.context_inner_count_i(scheduler_inner_count),
		.context_inner_interval_i(scheduler_inner_interval),
		.context_inner_stride_i(scheduler_inner_stride),
		.context_outer_count_i(scheduler_outer_count),
		.context_outer_interval_i(scheduler_outer_interval),
		.context_outer_stride_i(scheduler_outer_stride),
		.context_induction_target_i(scheduler_induction_target),
		.context_operand_i(scheduler_operand),
		.issue_valid_o,
		.issue_ready_i,
		.issue_instruction_o,
		.issue_cycle_o,
		.conflict_o(scheduler_conflict),
		.fault_o(scheduler_fault),
		.fault_code_o(scheduler_fault_code),
		.active_count_o
	);
endmodule
