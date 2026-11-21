module lpu_mxm_compute_macro_frontend #(
	parameter integer ACTIVE_CONTEXTS = 4,
	parameter integer ACCUMULATOR_ROWS = 8192,
	parameter integer WORD_FIFO_DEPTH = 4,
	parameter integer CONTEXT_FIFO_DEPTH = 4,
	parameter integer ISSUE_FIFO_DEPTH = 4
) (
	input logic clk_i,
	input logic rst_ni,
	input logic run_i,
	input logic prime_i,
	input logic [31:0] schedule_cycle_i,

	input  logic        word_valid_i,
	output logic        word_ready_o,
	input  logic [127:0] word_i,
	input  logic        word_last_i,

	output logic        issue_valid_o,
	input  logic        issue_ready_i,
	output logic [48:0] issue_instruction_o,
	output logic [31:0] issue_cycle_o,

	output logic        decoder_done_o,
	output logic [$clog2(WORD_FIFO_DEPTH+1)-1:0] word_fifo_level_o,
	output logic [$clog2(CONTEXT_FIFO_DEPTH+1)-1:0] context_fifo_level_o,
	output logic [$clog2(ISSUE_FIFO_DEPTH+1)-1:0] issue_fifo_level_o,
	output logic [$clog2(ACTIVE_CONTEXTS+1)-1:0] active_count_o,
	output logic        idle_o,
	output logic        prime_ready_o,
	output logic        fault_o,
	output logic [5:0]  fault_code_o
);
	localparam integer CONTEXT_WIDTH = 288;

	logic word_fifo_enqueue_ready;
	logic word_fifo_valid;
	logic word_fifo_ready;
	logic [128:0] word_fifo_data;
	logic logical_word_valid;
	logic logical_word_ready;
	logic [127:0] logical_word;
	logic logical_word_last;
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
	logic [1:0] decoder_target;
	logic [12:0] decoder_operand;
	logic decoder_fault;
	logic [3:0] decoder_fault_code;

	logic context_fifo_enqueue_ready;
	logic context_fifo_valid;
	logic context_fifo_ready;
	logic [CONTEXT_WIDTH-1:0] context_fifo_input_data;
	logic [CONTEXT_WIDTH-1:0] context_fifo_output_data;
	logic [48:0] scheduler_instruction;
	logic [31:0] scheduler_start_cycle;
	logic [31:0] scheduler_inner_count;
	logic [31:0] scheduler_inner_interval;
	logic signed [31:0] scheduler_inner_stride;
	logic [31:0] scheduler_outer_count;
	logic [31:0] scheduler_outer_interval;
	logic signed [31:0] scheduler_outer_stride;
	logic [1:0] scheduler_target;
	logic [12:0] scheduler_operand;
	logic scheduler_prime_ready;
	logic prime_tail, prime_blocked, prime_stream, prime_fault;
	logic scheduler_idle;
	logic scheduler_conflict;
	logic scheduler_fault;
	logic [3:0] scheduler_fault_code;

	lpu_program_prime_window u_prime_window (
		.clk_i, .rst_ni, .prime_i(prime_i && !run_i),
		.decoder_drained_i(decoder_done_o && !decoder_context_valid &&
			!context_fifo_valid && !word_fifo_valid),
		.context_fire_i(decoder_context_valid && decoder_context_ready),
		.context_cycle_i(decoder_start_cycle), .scheduler_ready_i(scheduler_prime_ready),
		.scheduler_blocked_i(prime_blocked), .stream_prefix_i(prime_stream),
		.tail_o(prime_tail), .ready_o(prime_ready_o), .fault_o(prime_fault)
	);

	assign fault_o = decoder_fault || scheduler_fault || prime_fault;
	assign fault_code_o = prime_fault ? 6'd31 : (decoder_fault ? {2'd1, decoder_fault_code} :
		{2'd2, scheduler_fault_code});
	assign word_ready_o = word_fifo_enqueue_ready && !fault_o;
	assign idle_o = (word_fifo_level_o == '0) && (context_fifo_level_o == '0) && scheduler_idle;

	// MXM local iMEM supplies native 128-bit words directly to the Decoder.
	lpu_queue_fifo #(
		.DATA_WIDTH(129),
		.DEPTH(WORD_FIFO_DEPTH)
	) u_word_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i(word_valid_i && !fault_o),
		.enqueue_ready_o(word_fifo_enqueue_ready),
		.enqueue_data_i({word_last_i, word_i}),
		.dequeue_valid_o(word_fifo_valid),
		.dequeue_ready_i(word_fifo_ready),
		.dequeue_data_o(word_fifo_data),
		.level_o(word_fifo_level_o)
	);

	assign logical_word_valid = word_fifo_valid;
	assign word_fifo_ready = logical_word_ready;
	assign logical_word = word_fifo_data[127:0];
	assign logical_word_last = word_fifo_data[128];

	lpu_mxm_compute_macro_decoder #(
		.ACCUMULATOR_ROWS(ACCUMULATOR_ROWS)
	) u_decoder (
		.clk_i,
		.rst_ni,
		.word_valid_i(logical_word_valid),
		.word_ready_o(logical_word_ready),
		.word_i(logical_word),
		.word_last_i(logical_word_last),
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
		.context_induction_target_o(decoder_target),
		.context_operand_o(decoder_operand),
		.done_o(decoder_done_o),
		.fault_o(decoder_fault),
		.fault_code_o(decoder_fault_code)
	);

	assign context_fifo_input_data = {decoder_operand, decoder_target, decoder_outer_stride,
		decoder_outer_interval, decoder_outer_count, decoder_inner_stride, decoder_inner_interval,
		decoder_inner_count, decoder_start_cycle, decoder_instruction};
	assign {scheduler_operand, scheduler_target, scheduler_outer_stride, scheduler_outer_interval,
		scheduler_outer_count, scheduler_inner_stride, scheduler_inner_interval,
		scheduler_inner_count, scheduler_start_cycle, scheduler_instruction} = context_fifo_output_data;
	assign decoder_context_ready = context_fifo_enqueue_ready && !fault_o;

	// Context FIFO absorbs variable Decoder latency and Active-slot admission latency.
	lpu_queue_fifo #(
		.DATA_WIDTH(CONTEXT_WIDTH),
		.DEPTH(CONTEXT_FIFO_DEPTH)
	) u_context_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i(decoder_context_valid && !fault_o),
		.enqueue_ready_o(context_fifo_enqueue_ready),
		.enqueue_data_i(context_fifo_input_data),
		.dequeue_valid_o(context_fifo_valid),
		.dequeue_ready_i(context_fifo_ready && !prime_fault),
		.dequeue_data_o(context_fifo_output_data),
		.level_o(context_fifo_level_o)
	);

	lpu_mxm_compute_macro_scheduler #(
		.ACTIVE_CONTEXTS(ACTIVE_CONTEXTS),
		.ACCUMULATOR_ROWS(ACCUMULATOR_ROWS),
		.ISSUE_FIFO_DEPTH(ISSUE_FIFO_DEPTH),
		.ISSUE_LOOKAHEAD(2)
	) u_scheduler (
		.clk_i,
		.rst_ni,
		.run_i,
		.prime_i,
		.prime_tail_i(prime_tail),
		.schedule_cycle_i,
		.context_valid_i(context_fifo_valid && !prime_fault),
		.context_ready_o(context_fifo_ready),
		.context_instruction_i(scheduler_instruction),
		.context_start_cycle_i(scheduler_start_cycle),
		.context_inner_count_i(scheduler_inner_count),
		.context_inner_interval_i(scheduler_inner_interval),
		.context_inner_stride_i(scheduler_inner_stride),
		.context_outer_count_i(scheduler_outer_count),
		.context_outer_interval_i(scheduler_outer_interval),
		.context_outer_stride_i(scheduler_outer_stride),
		.context_induction_target_i(scheduler_target),
		.context_operand_i(scheduler_operand),
		.issue_valid_o,
		.issue_ready_i,
		.issue_instruction_o,
		.issue_cycle_o,
		.active_count_o,
		.issue_fifo_level_o,
		.idle_o(scheduler_idle),
		.prime_ready_o(scheduler_prime_ready),
		.prime_blocked_o(prime_blocked), .prime_stream_o(prime_stream),
		.conflict_o(scheduler_conflict),
		.fault_o(scheduler_fault),
		.fault_code_o(scheduler_fault_code)
	);
endmodule
