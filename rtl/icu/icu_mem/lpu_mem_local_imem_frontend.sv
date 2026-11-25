module lpu_mem_local_imem_frontend #(
	parameter integer IMEM_DEPTH = 131072,
	parameter integer ADDRESS_WIDTH = IMEM_DEPTH <= 1 ? 1 : $clog2(IMEM_DEPTH),
	parameter integer ACTIVE_CONTEXTS = 4,
	parameter integer WORD_FIFO_DEPTH = 4,
	parameter integer CONTEXT_FIFO_DEPTH = 4
) (
	input logic clk_i,
	input logic rst_ni,
	input logic program_reset_i,
	input logic clear_i,

	input  logic         load_valid_i,
	output logic         load_ready_o,
	input  logic [16:0]  load_imem_address_i,
	input  logic [127:0] load_data_i,
	input  logic [3:0]   load_strb_i,
	input  logic         load_last_i,
	input  logic         prime_valid_i,
	output logic         prime_ready_o,

	input logic run_i,
	input logic [31:0] schedule_cycle_i,
	output logic mem_issue_valid_o,
	input logic mem_issue_ready_i,
	output logic [lpu_pkg::MEM_INSTRUCTION_WIDTH-1:0] mem_issue_instruction_o,
	output logic [31:0] mem_issue_cycle_o,

	output logic configured_o,
	output logic frontend_ready_o,
	output logic frontend_idle_o,
	output logic fault_o,
	output logic [5:0] fault_code_o
);
	localparam integer WORD_COUNT_WIDTH = $clog2(IMEM_DEPTH + 1);
	localparam logic [5:0] FAULT_NONE = 6'd0;
	localparam logic [5:0] FAULT_LOAD = 6'd1;
	localparam logic [5:0] FAULT_PRIME = 6'd2;
	localparam logic [5:0] FAULT_IMEM = 6'd3;
	localparam logic [5:0] FAULT_FETCH = 6'd4;
	localparam logic [5:0] FAULT_FRONTEND = 6'd5;

	logic frontend_rst_ni;
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
	logic imem_read_req_valid;
	logic imem_read_req_ready;
	logic [ADDRESS_WIDTH-1:0] imem_read_req_address;
	logic imem_read_req_last;
	logic imem_read_rsp_valid;
	logic imem_read_rsp_ready;
	logic [95:0] imem_read_rsp_data;
	logic imem_read_rsp_last;
	logic imem_idle;
	logic imem_fault;

	logic fetch_start_ready;
	logic fetch_word_valid;
	logic fetch_word_ready;
	logic [95:0] fetch_word;
	logic fetch_word_last;
	logic fetch_done;
	logic fetch_fault;
	logic [1:0] fetch_fault_code;

	logic decoder_done;
	logic scheduler_prime_ready;
	logic macro_frontend_fault;
	logic [4:0] macro_frontend_fault_code;
	logic macro_frontend_idle;
	logic frontend_pipeline_fault;

	initial begin
		if(IMEM_DEPTH > 131072)begin
			$error("MEM local iMEM address port supports at most 131072 words");
		end
	end

	assign frontend_rst_ni = rst_ni && !program_reset_i && !clear_i;
	assign configured_o = configured_q;
	assign load_ready_o = !prime_started_q && imem_load_ready && !fault_q;
	assign load_fire = load_valid_i && load_ready_o;
	assign load_record_illegal_w = load_fire && ((load_strb_i != 4'b0111) ||
		(load_imem_address_i >= IMEM_DEPTH) || load_last_seen_q ||
		(configured_q && (load_imem_address_i != next_load_address_q)));

	assign prime_ready_o = !prime_started_q && imem_idle && !fault_q;
	assign prime_fire = prime_valid_i && prime_ready_o;
	assign prime_request_illegal_w = prime_fire && (!configured_q || !load_last_seen_q ||
		(load_word_count_q == '0));
	assign frontend_pipeline_fault = fault_q || imem_fault || fetch_fault || macro_frontend_fault;
	assign frontend_ready_o = !configured_q || (prime_started_q && fetch_complete_q &&
		decoder_done && scheduler_prime_ready && !frontend_pipeline_fault);
	assign frontend_idle_o = !configured_q || macro_frontend_idle;

	assign fault_o = frontend_pipeline_fault;
	assign fault_code_o = fault_q ? fault_code_q :
		(imem_fault ? FAULT_IMEM :
		(fetch_fault ? {4'd0, fetch_fault_code} + FAULT_FETCH :
		(macro_frontend_fault ? FAULT_FRONTEND : FAULT_NONE)));

	lpu_mem_local_imem #(
		.WORD_WIDTH(96),
		.DEPTH(IMEM_DEPTH),
		.ADDRESS_WIDTH(ADDRESS_WIDTH)
	) u_imem (
		.clk_i,
		.rst_ni(frontend_rst_ni),
		.load_mode_i(!prime_started_q),
		.load_valid_i(load_valid_i && load_ready_o && !load_record_illegal_w),
		.load_ready_o(imem_load_ready),
		.load_address_i(load_imem_address_i[ADDRESS_WIDTH-1:0]),
		.load_data_i(load_data_i[95:0]),
		.imem_read_req_valid_i(imem_read_req_valid),
		.imem_read_req_ready_o(imem_read_req_ready),
		.imem_read_req_address_i(imem_read_req_address),
		.imem_read_req_last_i(imem_read_req_last),
		.imem_read_rsp_valid_o(imem_read_rsp_valid),
		.imem_read_rsp_ready_i(imem_read_rsp_ready),
		.imem_read_rsp_data_o(imem_read_rsp_data),
		.imem_read_rsp_last_o(imem_read_rsp_last),
		.outstanding_o(),
		.idle_o(imem_idle),
		.fault_o(imem_fault)
	);

	lpu_mem_imem_fetch #(
		.IMEM_DEPTH(IMEM_DEPTH),
		.ADDRESS_WIDTH(ADDRESS_WIDTH),
		.WORD_WIDTH(96)
	) u_fetch (
		.clk_i,
		.rst_ni(frontend_rst_ni),
		.start_valid_i(prime_started_q && !fetch_started_q),
		.start_ready_o(fetch_start_ready),
		.start_base_address_i(load_base_q),
		.start_word_count_i(load_word_count_q),
		.imem_read_req_valid_o(imem_read_req_valid),
		.imem_read_req_ready_i(imem_read_req_ready),
		.imem_read_req_address_o(imem_read_req_address),
		.imem_read_req_last_o(imem_read_req_last),
		.imem_read_rsp_valid_i(imem_read_rsp_valid),
		.imem_read_rsp_ready_o(imem_read_rsp_ready),
		.imem_read_rsp_data_i(imem_read_rsp_data),
		.imem_read_rsp_last_i(imem_read_rsp_last),
		.word_valid_o(fetch_word_valid),
		.word_ready_i(fetch_word_ready),
		.word_o(fetch_word),
		.word_last_o(fetch_word_last),
		.busy_o(),
		.done_o(fetch_done),
		.fault_o(fetch_fault),
		.fault_code_o(fetch_fault_code)
	);

	lpu_mem_macro_frontend #(
		.ACTIVE_CONTEXTS(ACTIVE_CONTEXTS),
		.WORD_FIFO_DEPTH(WORD_FIFO_DEPTH),
		.CONTEXT_FIFO_DEPTH(CONTEXT_FIFO_DEPTH)
	) u_macro_frontend (
		.clk_i,
		.rst_ni(frontend_rst_ni),
		.run_i,
		.prime_i(prime_started_q && !run_i),
		.schedule_cycle_i,
		.fetch_word_valid_i(fetch_word_valid),
		.fetch_word_ready_o(fetch_word_ready),
		.fetch_word_i(fetch_word),
		.fetch_word_last_i(fetch_word_last),
		.mem_issue_valid_o,
		.mem_issue_ready_i,
		.mem_issue_instruction_o,
		.mem_issue_cycle_o,
		.decoder_done_o(decoder_done),
		.word_fifo_level_o(),
		.context_fifo_level_o(),
		.active_count_o(),
		.idle_o(macro_frontend_idle),
		.prime_ready_o(scheduler_prime_ready),
		.fault_o(macro_frontend_fault),
		.fault_code_o(macro_frontend_fault_code)
	);

	// The descriptor is local to this Frontend; only contiguous committed words are visible.
	always_ff @(posedge clk_i or negedge frontend_rst_ni) begin
		if(!frontend_rst_ni)begin
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
					load_base_q <= load_imem_address_i[ADDRESS_WIDTH-1:0];
				end
				next_load_address_q <= {1'b0, load_imem_address_i[ADDRESS_WIDTH-1:0]} + 1'b1;
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

	// Local load and PRIME protocol violations remain sticky until the Frontend is reset.
	always_ff @(posedge clk_i or negedge frontend_rst_ni) begin
		if(!frontend_rst_ni)begin
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
