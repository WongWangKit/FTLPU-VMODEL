module lpu_mxm_local_imem_frontend #(
	parameter integer TARGET_KIND = 1,
	parameter integer IMEM_DEPTH = 65536,
	parameter integer ADDRESS_WIDTH = IMEM_DEPTH <= 1 ? 1 : $clog2(IMEM_DEPTH),
	parameter integer ACTIVE_CONTEXTS = 4,
	parameter integer ACCUMULATOR_ROWS = 8192,
	parameter integer WORD_FIFO_DEPTH = 4,
	parameter integer CONTEXT_FIFO_DEPTH = 4
) (
	input logic clk_i,
	input logic rst_ni,
	input logic program_reset_i,
	input logic clear_i,

	input  logic         load_valid_i,
	output logic         load_ready_o,
	input  logic [16:0]  load_address_i,
	input  logic [127:0] load_data_i,
	input  logic [3:0]   load_strb_i,
	input  logic         load_last_i,
	input  logic         prime_valid_i,
	output logic         prime_ready_o,

	input logic run_i,
	input logic [31:0] schedule_cycle_i,
	output logic issue_valid_o,
	input logic issue_ready_i,
	output logic [48:0] issue_instruction_o,
	output logic [31:0] issue_cycle_o,

	output logic configured_o,
	output logic frontend_ready_o,
	output logic frontend_idle_o,
	output logic fault_o,
	output logic [5:0] fault_code_o
);
	localparam integer WORD_COUNT_WIDTH = $clog2(IMEM_DEPTH + 1);
	localparam integer QUEUE_KIND = TARGET_KIND == lpu_program_load_pkg::PROGRAM_TARGET_MXM_LOAD ?
		lpu_mxm_isa_pkg::MXM_QUEUE_LOAD :
		(TARGET_KIND == lpu_program_load_pkg::PROGRAM_TARGET_MXM_DEQUANT ?
		lpu_mxm_isa_pkg::MXM_QUEUE_DEQUANT :
		(TARGET_KIND == lpu_program_load_pkg::PROGRAM_TARGET_MXM_COMPUTE ?
		lpu_mxm_isa_pkg::MXM_QUEUE_COMPUTE :
		(TARGET_KIND == lpu_program_load_pkg::PROGRAM_TARGET_MXM_PARAM_LOAD ?
		lpu_mxm_isa_pkg::MXM_QUEUE_PARAM_LOAD : lpu_mxm_isa_pkg::MXM_QUEUE_BACKEND)));
	localparam logic [5:0] FAULT_NONE = 6'd0;
	localparam logic [5:0] FAULT_LOAD = 6'd1;
	localparam logic [5:0] FAULT_PRIME = 6'd2;
	localparam logic [5:0] FAULT_IMEM = 6'd3;
	localparam logic [5:0] FAULT_FETCH = 6'd4;
	localparam logic [5:0] FAULT_FRONTEND = 6'd5;

	logic queue_rst_ni;
	logic configured_q;
	logic prime_started_q;
	logic fetch_started_q;
	logic fetch_complete_q;
	logic load_last_seen_q;
	logic [ADDRESS_WIDTH-1:0] load_base_q;
	logic [ADDRESS_WIDTH:0] next_load_address_q;
	logic [WORD_COUNT_WIDTH-1:0] load_word_count_q;
	logic load_fire;
	logic load_record_illegal_w;
	logic prime_fire;
	logic prime_request_illegal_w;
	logic fault_q;
	logic [5:0] fault_code_q;

	logic imem_load_ready;
	logic imem_request_valid;
	logic imem_request_ready;
	logic [ADDRESS_WIDTH-1:0] imem_request_address;
	logic imem_request_last;
	logic imem_response_valid;
	logic imem_response_ready;
	logic [127:0] imem_response_data;
	logic imem_response_last;
	logic imem_idle;
	logic imem_fault;

	logic fetch_start_ready;
	logic fetch_word_valid;
	logic fetch_word_ready;
	logic [127:0] fetch_word;
	logic fetch_word_last;
	logic fetch_done;
	logic fetch_fault;
	logic [1:0] fetch_fault_code;

	logic decoder_done;
	logic scheduler_prime_ready;
	logic frontend_fault;
	logic [4:0] frontend_fault_code;
	logic macro_frontend_idle;

	initial begin
		if(!((TARGET_KIND == lpu_program_load_pkg::PROGRAM_TARGET_MXM_LOAD) ||
			(TARGET_KIND == lpu_program_load_pkg::PROGRAM_TARGET_MXM_DEQUANT) ||
			(TARGET_KIND == lpu_program_load_pkg::PROGRAM_TARGET_MXM_COMPUTE) ||
			(TARGET_KIND == lpu_program_load_pkg::PROGRAM_TARGET_MXM_PARAM_LOAD) ||
			(TARGET_KIND == lpu_program_load_pkg::PROGRAM_TARGET_MXM_BACKEND)))begin
			$error("TARGET_KIND must select one of the five MXM instruction streams");
		end
		if(IMEM_DEPTH > 65536)begin
			$error("MXM local iMEM exceeds the CMODEL 65536-word capacity");
		end
	end

	assign queue_rst_ni = rst_ni && !program_reset_i && !clear_i;
	assign configured_o = configured_q;
	assign load_ready_o = !prime_started_q && imem_load_ready && !fault_q;
	assign load_fire = load_valid_i && load_ready_o;
	assign load_record_illegal_w = load_fire && ((load_strb_i != 4'b1111) ||
		(load_address_i >= IMEM_DEPTH) || load_last_seen_q ||
		(configured_q && (load_address_i != next_load_address_q)));
	assign prime_ready_o = !prime_started_q && imem_idle && !fault_q;
	assign prime_fire = prime_valid_i && prime_ready_o;
	assign prime_request_illegal_w = prime_fire && (!configured_q || !load_last_seen_q ||
		(load_word_count_q == '0));
	assign frontend_ready_o = !configured_q || (prime_started_q && fetch_complete_q &&
		decoder_done && scheduler_prime_ready && !fault_o);
	assign frontend_idle_o = !configured_q || macro_frontend_idle;

	assign fault_o = fault_q || imem_fault || fetch_fault || frontend_fault;
	assign fault_code_o = fault_q ? fault_code_q :
		(imem_fault ? FAULT_IMEM :
		(fetch_fault ? FAULT_FETCH :
		(frontend_fault ? FAULT_FRONTEND : FAULT_NONE)));

	lpu_mxm_local_imem #(
		.WORD_WIDTH(128),
		.DEPTH(IMEM_DEPTH),
		.ADDRESS_WIDTH(ADDRESS_WIDTH)
	) u_imem (
		.clk_i,
		.rst_ni(queue_rst_ni),
		.load_mode_i(!prime_started_q),
		.load_valid_i(load_valid_i && load_ready_o && !load_record_illegal_w),
		.load_ready_o(imem_load_ready),
		.load_address_i(load_address_i[ADDRESS_WIDTH-1:0]),
		.load_data_i,
		.request_valid_i(imem_request_valid),
		.request_ready_o(imem_request_ready),
		.request_address_i(imem_request_address),
		.request_last_i(imem_request_last),
		.response_valid_o(imem_response_valid),
		.response_ready_i(imem_response_ready),
		.response_data_o(imem_response_data),
		.response_last_o(imem_response_last),
		.outstanding_o(),
		.idle_o(imem_idle),
		.fault_o(imem_fault)
	);

	lpu_mxm_imem_fetch #(
		.IMEM_DEPTH(IMEM_DEPTH),
		.ADDRESS_WIDTH(ADDRESS_WIDTH),
		.WORD_WIDTH(128)
	) u_fetch (
		.clk_i,
		.rst_ni(queue_rst_ni),
		.start_valid_i(prime_started_q && !fetch_started_q),
		.start_ready_o(fetch_start_ready),
		.start_base_address_i(load_base_q),
		.start_word_count_i(load_word_count_q),
		.request_valid_o(imem_request_valid),
		.request_ready_i(imem_request_ready),
		.request_address_o(imem_request_address),
		.request_last_o(imem_request_last),
		.response_valid_i(imem_response_valid),
		.response_ready_o(imem_response_ready),
		.response_data_i(imem_response_data),
		.response_last_i(imem_response_last),
		.word_valid_o(fetch_word_valid),
		.word_ready_i(fetch_word_ready),
		.word_o(fetch_word),
		.word_last_o(fetch_word_last),
		.busy_o(),
		.done_o(fetch_done),
		.fault_o(fetch_fault),
		.fault_code_o(fetch_fault_code)
	);

	// TARGET_KIND selects one independent parser/scheduler state instance while sharing one RTL implementation.
	lpu_mxm_macro_frontend #(
		.QUEUE_KIND(QUEUE_KIND),
		.ACTIVE_CONTEXTS(ACTIVE_CONTEXTS),
		.ACCUMULATOR_ROWS(ACCUMULATOR_ROWS),
		.WORD_FIFO_DEPTH(WORD_FIFO_DEPTH),
		.CONTEXT_FIFO_DEPTH(CONTEXT_FIFO_DEPTH)
	) u_frontend (
		.clk_i,
		.rst_ni(queue_rst_ni),
		.run_i,
		.prime_i(prime_started_q && !run_i),
		.schedule_cycle_i,
		.fetch_word_valid_i(fetch_word_valid),
		.fetch_word_ready_o(fetch_word_ready),
		.fetch_word_i(fetch_word),
		.fetch_word_last_i(fetch_word_last),
		.issue_valid_o,
		.issue_ready_i,
		.issue_instruction_o,
		.issue_cycle_o,
		.decoder_done_o(decoder_done),
		.word_fifo_level_o(),
		.context_fifo_level_o(),
		.active_count_o(),
		.idle_o(macro_frontend_idle),
		.prime_ready_o(scheduler_prime_ready),
		.fault_o(frontend_fault),
		.fault_code_o(frontend_fault_code)
	);

	// Track the loaded image extent and start Fetch only after a valid PRIME.
	// Fetch completion remains sticky until the Queue-local reset is asserted.
	always_ff @(posedge clk_i or negedge queue_rst_ni) begin
		if(!queue_rst_ni)begin
			configured_q <= 1'b0;
			load_last_seen_q <= 1'b0;
			load_base_q <= '0;
			next_load_address_q <= '0;
			load_word_count_q <= '0;
			prime_started_q <= 1'b0;
			fetch_started_q <= 1'b0;
			fetch_complete_q <= 1'b0;
		end
		else begin
			if(load_fire && !load_record_illegal_w)begin
				if(!configured_q)begin
					configured_q <= 1'b1;
					load_base_q <= load_address_i[ADDRESS_WIDTH-1:0];
				end
				next_load_address_q <= {1'b0, load_address_i[ADDRESS_WIDTH-1:0]} + 1'b1;
				load_word_count_q <= load_word_count_q + 1'b1;
				if(load_last_i)begin
					load_last_seen_q <= 1'b1;
				end
			end
			if(prime_fire && !prime_request_illegal_w)begin
				prime_started_q <= 1'b1;
			end
			if(prime_started_q && !fetch_started_q && fetch_start_ready)begin
				fetch_started_q <= 1'b1;
			end
			if(fetch_done)begin
				fetch_complete_q <= 1'b1;
			end
		end
	end

	// Local load and PRIME protocol violations remain sticky until the Queue-local reset.
	always_ff @(posedge clk_i or negedge queue_rst_ni) begin
		if(!queue_rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else if(!fault_q)begin
			if(load_record_illegal_w)begin
				fault_q <= 1'b1;
				fault_code_q <= FAULT_LOAD;
			end
			else if(prime_request_illegal_w)begin
				fault_q <= 1'b1;
				fault_code_q <= FAULT_PRIME;
			end
		end
	end
endmodule
