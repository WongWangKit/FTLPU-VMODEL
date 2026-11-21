module lpu_mem_macro_frontend #(
	parameter integer ACTIVE_CONTEXTS = 4,
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
	input  logic [95:0] word_i,
	input  logic        word_last_i,

	output logic        issue_valid_o,
	input  logic        issue_ready_i,
	output logic [lpu_pkg::MEM_INSTRUCTION_WIDTH-1:0] issue_instruction_o,
	output logic [31:0] issue_cycle_o,

	output logic        decoder_done_o,
	output logic [$clog2(WORD_FIFO_DEPTH+1)-1:0] word_fifo_level_o,
	output logic [$clog2(CONTEXT_FIFO_DEPTH+1)-1:0] context_fifo_level_o,
	output logic [$clog2(ISSUE_FIFO_DEPTH+1)-1:0] issue_fifo_level_o,
	output logic [$clog2(ACTIVE_CONTEXTS+1)-1:0] active_count_o,
	output logic        idle_o,
	output logic        prime_ready_o,
	output logic        fault_o,
	output logic [4:0]  fault_code_o
);
	localparam integer CONTEXT_WIDTH = 271;

	logic word_fifo_valid;
	logic word_fifo_ready;
	logic [96:0] word_fifo_data;
	logic word_fifo_enqueue_valid;
	logic word_fifo_enqueue_ready;

	logic decoder_context_valid;
	logic decoder_context_ready;
	logic [31:0] decoder_instruction;
	logic [31:0] decoder_start_cycle;
	logic [31:0] decoder_inner_count;
	logic [31:0] decoder_inner_interval;
	logic signed [31:0] decoder_inner_stride;
	logic [31:0] decoder_outer_count;
	logic [31:0] decoder_outer_interval;
	logic signed [31:0] decoder_outer_stride;
	logic [1:0] decoder_induction_target;
	logic [12:0] decoder_address;
	logic decoder_fault;
	logic [3:0] decoder_fault_code;

	logic [CONTEXT_WIDTH-1:0] context_fifo_input_data;
	logic [CONTEXT_WIDTH-1:0] context_fifo_output_data;
	logic context_fifo_valid;
	logic context_fifo_ready;

	logic [31:0] scheduler_instruction;
	logic [31:0] scheduler_start_cycle;
	logic [31:0] scheduler_inner_count;
	logic [31:0] scheduler_inner_interval;
	logic signed [31:0] scheduler_inner_stride;
	logic [31:0] scheduler_outer_count;
	logic [31:0] scheduler_outer_interval;
	logic signed [31:0] scheduler_outer_stride;
	logic [1:0] scheduler_induction_target;
	logic [12:0] scheduler_address;
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
	assign fault_code_o = prime_fault ? 5'd31 : (decoder_fault ? {1'b0, decoder_fault_code} : {1'b1, scheduler_fault_code});
	assign word_fifo_enqueue_valid = word_valid_i && !fault_o;
	assign word_ready_o = word_fifo_enqueue_ready && !fault_o;
	assign idle_o = (word_fifo_level_o == '0) && (context_fifo_level_o == '0) && scheduler_idle;

	// Word FIFO absorbs iMEM latency and allows fetch to run ahead of the variable-rate Decoder.
	lpu_queue_fifo #(
		.DATA_WIDTH(97),
		.DEPTH(WORD_FIFO_DEPTH)
	) u_word_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i(word_fifo_enqueue_valid),
		.enqueue_ready_o(word_fifo_enqueue_ready),
		.enqueue_data_i({word_last_i, word_i}),
		.dequeue_valid_o(word_fifo_valid),
		.dequeue_ready_i(word_fifo_ready),
		.dequeue_data_o(word_fifo_data),
		.level_o(word_fifo_level_o)
	);

	lpu_mem_macro_decoder u_decoder (
		.clk_i,
		.rst_ni,
		.word_valid_i(word_fifo_valid),
		.word_ready_o(word_fifo_ready),
		.word_i(word_fifo_data[95:0]),
		.word_last_i(word_fifo_data[96]),
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
		.context_address_o(decoder_address),
		.done_o(decoder_done_o),
		.fault_o(decoder_fault),
		.fault_code_o(decoder_fault_code)
	);

	assign context_fifo_input_data = {decoder_induction_target, decoder_address, decoder_outer_stride,
		decoder_outer_interval, decoder_outer_count, decoder_inner_stride, decoder_inner_interval,
		decoder_inner_count, decoder_start_cycle, decoder_instruction};
	assign {scheduler_induction_target, scheduler_address, scheduler_outer_stride,
		scheduler_outer_interval, scheduler_outer_count, scheduler_inner_stride, scheduler_inner_interval,
		scheduler_inner_count, scheduler_start_cycle, scheduler_instruction} = context_fifo_output_data;

	// Context FIFO decouples variable-length parsing from Active Context admission.
	lpu_queue_fifo #(
		.DATA_WIDTH(CONTEXT_WIDTH),
		.DEPTH(CONTEXT_FIFO_DEPTH)
	) u_context_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i(decoder_context_valid && !fault_o),
		.enqueue_ready_o(decoder_context_ready),
		.enqueue_data_i(context_fifo_input_data),
		.dequeue_valid_o(context_fifo_valid),
		.dequeue_ready_i(context_fifo_ready && !prime_fault),
		.dequeue_data_o(context_fifo_output_data),
		.level_o(context_fifo_level_o)
	);

	// The Scheduler computes future base instructions; its downstream Timed Queue owns storage.
	lpu_mem_macro_scheduler #(
		.ACTIVE_CONTEXTS(ACTIVE_CONTEXTS),
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
		.context_induction_target_i(scheduler_induction_target),
		.context_address_i(scheduler_address),
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
