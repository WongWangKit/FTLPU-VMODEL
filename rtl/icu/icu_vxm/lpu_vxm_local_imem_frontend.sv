// Queue-local 96-bit sequential program storage, prefetch and absolute dispatch.
module lpu_vxm_local_imem_frontend #(
	parameter integer QUEUE_ID = 0,
	parameter integer IMEM_DEPTH = 256,
	parameter integer CONTEXT_DEPTH = 4,
	parameter integer AW = IMEM_DEPTH <= 1 ? 1 : $clog2(IMEM_DEPTH)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic load_valid_i,
	output logic load_ready_o,
	input logic [16:0] load_address_i,
	input logic [127:0] load_data_i,
	input logic [3:0] load_strb_i,
	input logic load_last_i,
	input logic prime_valid_i,
	output logic prime_ready_o,
	input logic run_i,
	input logic [31:0] schedule_cycle_i,
	output logic issue_valid_o,
	input logic issue_ready_i,
	output logic [95:0] issue_word_o,
	output logic [31:0] issue_cycle_o,
	output logic configured_o,
	output logic ready_o,
	output logic idle_o,
	output logic fault_o
);
	localparam integer CW = $clog2(IMEM_DEPTH+1);
	logic configured_q, sealed_q, primed_q, fetch_started_q, decoded_q;
	logic [AW-1:0] base_q;
	logic [17:0] next_address_q;
	logic [CW-1:0] count_q;
	logic [31:0] cursor_q;
	logic [32:0] next_cursor;
	logic imem_load_ready, imem_idle, imem_fault;
	logic req_valid, req_ready, req_last, rsp_valid, rsp_ready, rsp_last;
	logic [AW-1:0] req_address;
	logic [95:0] rsp_data, fetch_word;
	logic fetch_start_ready, fetch_valid, fetch_ready, fetch_last, fetch_fault;
	logic word_valid, word_ready, word_last;
	logic [95:0] word_data;
	logic legal, supported, nop;
	logic [29:0] nop_cycles;
	logic context_ready, context_valid;
	logic [127:0] context_data;
	logic load_fire, prime_fire, load_bad, prime_bad, decode_fire;
	logic protocol_fault_q;

	assign configured_o = configured_q;
	assign fault_o = protocol_fault_q || imem_fault || fetch_fault;
	assign load_ready_o = !primed_q && imem_load_ready && !fault_o;
	assign load_fire = load_valid_i && load_ready_o;
	assign load_bad = load_fire && ((load_strb_i != 4'b0111) ||
		(load_address_i >= IMEM_DEPTH) || sealed_q ||
		(configured_q && {1'b0, load_address_i} != next_address_q));
	assign prime_ready_o = !primed_q && imem_idle && !fault_o;
	assign prime_fire = prime_valid_i && prime_ready_o;
	assign prime_bad = prime_fire && (!configured_q || !sealed_q || count_q == 0);
	assign ready_o = !configured_q || (primed_q && (context_valid || decoded_q) && !fault_o);
	assign idle_o = !configured_q || (decoded_q && !context_valid);
	assign next_cursor = {1'b0, cursor_q} + (nop ? {3'b0, nop_cycles} : 33'd1);
	assign word_ready = !fault_o && (nop || context_ready);
	assign decode_fire = word_valid && word_ready;
	assign {issue_cycle_o, issue_word_o} = context_data;
	assign issue_valid_o = context_valid && run_i && !fault_o && (issue_cycle_o == schedule_cycle_i);

	// Reuse the proven MEM two-cycle SRAM response/credit and Fetch mechanisms.
	lpu_mem_local_imem #(
		.WORD_WIDTH(96),
		.DEPTH(IMEM_DEPTH),
		.ADDRESS_WIDTH(AW)
	) u_imem (
		.clk_i,
		.rst_ni,
		.load_mode_i(!primed_q),
		.load_valid_i(load_fire && !load_bad),
		.load_ready_o(imem_load_ready),
		.load_address_i(load_address_i[AW-1:0]),
		.load_data_i(load_data_i[95:0]),
		.imem_read_req_valid_i(req_valid),
		.imem_read_req_ready_o(req_ready),
		.imem_read_req_address_i(req_address),
		.imem_read_req_last_i(req_last),
		.imem_read_rsp_valid_o(rsp_valid),
		.imem_read_rsp_ready_i(rsp_ready),
		.imem_read_rsp_data_o(rsp_data),
		.imem_read_rsp_last_o(rsp_last),
		.outstanding_o(),
		.idle_o(imem_idle),
		.fault_o(imem_fault)
	);

	lpu_mem_imem_fetch #(
		.IMEM_DEPTH(IMEM_DEPTH),
		.ADDRESS_WIDTH(AW),
		.WORD_WIDTH(96)
	) u_fetch (
		.clk_i,
		.rst_ni,
		.start_valid_i(primed_q && !fetch_started_q),
		.start_ready_o(fetch_start_ready),
		.start_base_address_i(base_q),
		.start_word_count_i(count_q),
		.imem_read_req_valid_o(req_valid),
		.imem_read_req_ready_i(req_ready),
		.imem_read_req_address_o(req_address),
		.imem_read_req_last_o(req_last),
		.imem_read_rsp_valid_i(rsp_valid),
		.imem_read_rsp_ready_o(rsp_ready),
		.imem_read_rsp_data_i(rsp_data),
		.imem_read_rsp_last_i(rsp_last),
		.word_valid_o(fetch_valid),
		.word_ready_i(fetch_ready),
		.word_o(fetch_word),
		.word_last_o(fetch_last),
		.busy_o(),
		.done_o(),
		.fault_o(fetch_fault),
		.fault_code_o()
	);

	lpu_fifo #(
		.DATA_WIDTH(97),
		.DEPTH(4)
	) u_word_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i(fetch_valid),
		.enqueue_ready_o(fetch_ready),
		.enqueue_data_i({fetch_last, fetch_word}),
		.dequeue_valid_o(word_valid),
		.dequeue_ready_i(word_ready),
		.dequeue_data_o({word_last, word_data}),
		.level_o()
	);

	lpu_vxm_sequential_decoder #(
		.QUEUE_ID(QUEUE_ID)
	) u_decoder (
		.word_i(word_data),
		.legal_o(legal),
		.supported_o(supported),
		.nop_o(nop),
		.nop_cycles_o(nop_cycles),
		.local_o(),
		.global_o(),
		.repeat_count_o(),
		.repeat_phase_o(),
		.immediate_valid_o(),
		.immediate_o()
	);

	// A sequential Context is one unchanged configuration plus its dispatch
	// cycle. NOP advances this queue's cursor; repeat is owned by the FU.
	lpu_fifo #(
		.DATA_WIDTH(128),
		.DEPTH(CONTEXT_DEPTH)
	) u_context_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i(word_valid && !nop && legal && supported && !fault_o),
		.enqueue_ready_o(context_ready),
		.enqueue_data_i({cursor_q, word_data}),
		.dequeue_valid_o(context_valid),
		.dequeue_ready_i(issue_valid_o && issue_ready_i),
		.dequeue_data_o(context_data),
		.level_o()
	);

	// Commit image metadata only on accepted writes; reset invalidates storage
	// ownership without resetting the SRAM contents or exposing an old image.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			configured_q <= 0;
			sealed_q <= 0;
			primed_q <= 0;
			fetch_started_q <= 0;
			decoded_q <= 0;
			base_q <= 0;
			next_address_q <= 0;
			count_q <= 0;
			cursor_q <= 0;
			protocol_fault_q <= 0;
		end
		else begin
			if(load_fire && !load_bad)begin
				configured_q <= 1;
				if(!configured_q)begin
					base_q <= load_address_i[AW-1:0];
				end
				next_address_q <= {1'b0, load_address_i} + 1'b1;
				count_q <= count_q + 1'b1;
				sealed_q <= load_last_i;
			end
			if(prime_fire && !prime_bad)begin
				primed_q <= 1;
			end
			if(primed_q && fetch_start_ready)begin
				fetch_started_q <= 1;
			end
			if(decode_fire)begin
				cursor_q <= next_cursor[31:0];
				decoded_q <= word_last;
			end
			if(load_bad || prime_bad || (decode_fire && (!legal || !supported || next_cursor[32])) ||
				(run_i && context_valid && ((issue_cycle_o < schedule_cycle_i) ||
				((issue_cycle_o == schedule_cycle_i) && !issue_ready_i))))begin
				protocol_fault_q <= 1;
			end
		end
	end
endmodule
