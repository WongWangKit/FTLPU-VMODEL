module lpu_qctl_queue_controller #(
	parameter integer QUEUE_ENTRY_LIMIT = 16,
	parameter integer CACHE_DEPTH = 4,
	parameter integer EVENT_TOKEN_DEPTH = 8,
	parameter integer SYNC_TOKEN_DEPTH = 8,
	parameter integer GENERATION_WIDTH = 64,
	parameter integer ENTRY_INDEX_WIDTH = QUEUE_ENTRY_LIMIT <= 1 ? 1 : $clog2(QUEUE_ENTRY_LIMIT),
	parameter integer ENTRY_COUNT_WIDTH = $clog2(QUEUE_ENTRY_LIMIT + 1),
	parameter integer CACHE_COUNT_WIDTH = $clog2(CACHE_DEPTH + 1),
	parameter integer TOKEN_COUNT_WIDTH = $clog2(SYNC_TOKEN_DEPTH + 1)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic clear_i,

	// A new program binds this Controller to one Shared Pool partition.
	input logic configure_valid_i,
	input logic [ENTRY_COUNT_WIDTH-1:0] configure_count_i,
	input logic [GENERATION_WIDTH-1:0] configure_generation_i,

	// The Controller reserves cache credit before issuing each indexed Pool read.
	output logic pool_request_valid_o,
	input logic pool_request_ready_i,
	output logic [ENTRY_INDEX_WIDTH-1:0] pool_request_index_o,
	output logic [GENERATION_WIDTH-1:0] pool_request_generation_o,
	input logic pool_response_valid_i,
	input logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] pool_response_data_i,
	input logic pool_response_error_i,

	// Tagged notifications are consumable tokens. Repeated tags remain distinct tokens.
	input logic event_valid_i,
	output logic event_ready_o,
	input logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] event_tag_i,
	input logic sync_valid_i,
	output logic sync_ready_o,

	// NOTIFY occupies one physical cycle and retires only after the receiver accepts it.
	output logic notify_valid_o,
	input logic notify_ready_i,

	// MEM_PACKET owns the Queue boundary until the external transport reports retirement.
	output logic mem_packet_valid_o,
	output logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] mem_packet_ordinal_o,
	input logic mem_packet_retired_i,

	input logic run_i,
	output logic scheduler_enable_o,
	output logic [lpu_qctl_pkg::QCTL_CYCLE_WIDTH-1:0] queue_cycle_o,
	output logic wait_event_blocked_o,
	output logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] wait_event_tag_o,
	output logic primed_o,
	output logic done_o,
	output logic fault_o,
	output logic [3:0] fault_code_o
);
	localparam logic [3:0] FAULT_NONE = 4'd0;
	localparam logic [3:0] FAULT_CONFIGURATION = 4'd1;
	localparam logic [3:0] FAULT_NOT_PRIMED = 4'd2;
	localparam logic [3:0] FAULT_POOL_RESPONSE = 4'd3;
	localparam logic [3:0] FAULT_CACHE_OVERFLOW = 4'd4;
	localparam logic [3:0] FAULT_CACHE_UNDERFLOW = 4'd5;
	localparam logic [3:0] FAULT_BOUNDARY_MISSED = 4'd6;
	localparam logic [3:0] FAULT_RECORD = 4'd7;

	logic configured_q;
	logic prime_complete_q;
	logic [ENTRY_COUNT_WIDTH-1:0] control_count_q;
	logic [GENERATION_WIDTH-1:0] generation_q;
	logic [ENTRY_COUNT_WIDTH-1:0] fetch_index_q;
	logic [ENTRY_COUNT_WIDTH-1:0] retired_count_q;
	logic [CACHE_COUNT_WIDTH-1:0] cache_level_q;
	logic [CACHE_COUNT_WIDTH-1:0] inflight_count_q;
	logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] cache_q [0:CACHE_DEPTH-1];

	logic event_token_valid_q [0:EVENT_TOKEN_DEPTH-1];
	logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] event_token_tag_q [0:EVENT_TOKEN_DEPTH-1];
	logic [EVENT_TOKEN_DEPTH-1:0] event_token_consume_w;
	logic event_insert_valid_w;
	logic [((EVENT_TOKEN_DEPTH <= 1) ? 1 : $clog2(EVENT_TOKEN_DEPTH))-1:0] event_insert_index_w;

	logic [TOKEN_COUNT_WIDTH-1:0] sync_token_count_q;
	logic sync_token_consume_w;

	logic [lpu_qctl_pkg::QCTL_CYCLE_WIDTH-1:0] queue_cycle_q;
	logic [CACHE_COUNT_WIDTH-1:0] retire_count_w;
	logic scheduler_block_w;
	logic cache_underflow_w;
	logic boundary_missed_w;
	logic invalid_record_w;
	logic request_fire;
	logic response_accept_w;
	logic event_fire;
	logic sync_fire;
	logic fault_q;
	logic [3:0] fault_code_q;
	logic set_fault_w;
	logic [3:0] set_fault_code_w;

	initial begin
		if(QUEUE_ENTRY_LIMIT < 1)begin
			$error("QUEUE_ENTRY_LIMIT must be at least one");
		end
		if(CACHE_DEPTH < 1 || CACHE_DEPTH > QUEUE_ENTRY_LIMIT)begin
			$error("CACHE_DEPTH must be between one and QUEUE_ENTRY_LIMIT");
		end
		if(EVENT_TOKEN_DEPTH < 1 || SYNC_TOKEN_DEPTH < 1)begin
			$error("QCTL token depths must be at least one");
		end
	end

	assign pool_request_valid_o = configured_q && !fault_q &&
		(fetch_index_q < control_count_q) &&
		((cache_level_q + inflight_count_q) < CACHE_DEPTH);
	assign pool_request_index_o = fetch_index_q[ENTRY_INDEX_WIDTH-1:0];
	assign pool_request_generation_o = generation_q;
	assign request_fire = pool_request_valid_o && pool_request_ready_i;
	assign response_accept_w = pool_response_valid_i && !pool_response_error_i && !fault_q;
	assign event_fire = event_valid_i && event_ready_o;
	assign sync_fire = sync_valid_i && sync_ready_o;

	assign queue_cycle_o = queue_cycle_q;
	assign done_o = configured_q && (retired_count_q == control_count_q);
	assign fault_o = fault_q;
	assign fault_code_o = fault_code_q;

	// Priming requires actual cache residency; once execution starts, runtime refill may
	// legitimately leave fewer than CACHE_DEPTH entries resident without de-priming.
	always_comb begin
		if(control_count_q < CACHE_DEPTH)begin
			primed_o = configured_q && (prime_complete_q ||
				(cache_level_q == control_count_q[CACHE_COUNT_WIDTH-1:0]));
		end
		else begin
			primed_o = configured_q && (prime_complete_q || (cache_level_q == CACHE_DEPTH));
		end
	end

	// Consecutive ready WAIT_EVENT records may retire in one physical cycle.
	// SYNC, NOTIFY and MEM_PACKET consume the boundary cycle and stop the scan.
	always_comb begin
		retire_count_w = '0;
		event_token_consume_w = '0;
		sync_token_consume_w = 1'b0;
		notify_valid_o = 1'b0;
		mem_packet_valid_o = 1'b0;
		mem_packet_ordinal_o = '0;
		wait_event_blocked_o = 1'b0;
		wait_event_tag_o = '0;
		scheduler_block_w = 1'b0;
		cache_underflow_w = 1'b0;
		boundary_missed_w = 1'b0;
		invalid_record_w = 1'b0;

		if(run_i && configured_q && primed_o && !fault_q && !done_o)begin
			logic scan_active;
			scan_active = 1'b1;
			for(integer control_index = 0; control_index < CACHE_DEPTH; control_index++)begin
				if(scan_active && control_index < cache_level_q)begin
					logic [lpu_qctl_pkg::QCTL_CYCLE_WIDTH-1:0] control_cycle;
					logic [lpu_qctl_pkg::QCTL_OPCODE_WIDTH-1:0] control_opcode;
					logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] control_operand;
					control_cycle = lpu_qctl_pkg::qctl_record_cycle(cache_q[control_index]);
					control_opcode = lpu_qctl_pkg::qctl_record_opcode(cache_q[control_index]);
					control_operand = lpu_qctl_pkg::qctl_record_operand(cache_q[control_index]);

					if(control_cycle < queue_cycle_q)begin
						boundary_missed_w = 1'b1;
						scheduler_block_w = 1'b1;
						scan_active = 1'b0;
					end
					else if(control_cycle > queue_cycle_q)begin
						scan_active = 1'b0;
					end
					else begin
						case(control_opcode)
							lpu_qctl_pkg::QCTL_OPCODE_WAIT_EVENT: begin
								logic token_found;
								token_found = 1'b0;
								for(integer token_index = 0; token_index < EVENT_TOKEN_DEPTH; token_index++)begin
									if(!token_found && event_token_valid_q[token_index] &&
										!event_token_consume_w[token_index] &&
										event_token_tag_q[token_index] == control_operand)begin
										token_found = 1'b1;
										event_token_consume_w[token_index] = 1'b1;
									end
								end
								if(token_found)begin
									retire_count_w = retire_count_w + 1'b1;
								end
								else begin
									wait_event_blocked_o = 1'b1;
									wait_event_tag_o = control_operand;
									scheduler_block_w = 1'b1;
									scan_active = 1'b0;
								end
							end
							lpu_qctl_pkg::QCTL_OPCODE_SYNC: begin
								if(control_operand != 0)begin
									invalid_record_w = 1'b1;
								end
								else if(sync_token_count_q != 0)begin
									sync_token_consume_w = 1'b1;
									retire_count_w = retire_count_w + 1'b1;
								end
								scheduler_block_w = 1'b1;
								scan_active = 1'b0;
							end
							lpu_qctl_pkg::QCTL_OPCODE_NOTIFY: begin
								if(control_operand != 0)begin
									invalid_record_w = 1'b1;
								end
								else begin
									notify_valid_o = 1'b1;
									if(notify_ready_i)begin
										retire_count_w = retire_count_w + 1'b1;
									end
								end
								scheduler_block_w = 1'b1;
								scan_active = 1'b0;
							end
							lpu_qctl_pkg::QCTL_OPCODE_MEM_PACKET: begin
								if(control_operand == 0)begin
									invalid_record_w = 1'b1;
								end
								else begin
									mem_packet_valid_o = 1'b1;
									mem_packet_ordinal_o = control_operand;
									if(mem_packet_retired_i)begin
										retire_count_w = retire_count_w + 1'b1;
									end
								end
								scheduler_block_w = 1'b1;
								scan_active = 1'b0;
							end
							default: begin
								invalid_record_w = 1'b1;
								scheduler_block_w = 1'b1;
								scan_active = 1'b0;
							end
						endcase
					end
				end
			end
			if(scan_active && (retire_count_w == cache_level_q) &&
				((retired_count_q + retire_count_w) < control_count_q))begin
				cache_underflow_w = 1'b1;
				scheduler_block_w = 1'b1;
			end
		end
	end

	assign scheduler_enable_o = run_i && configured_q && primed_o && !fault_q &&
		!scheduler_block_w && !cache_underflow_w && !boundary_missed_w && !invalid_record_w;

	// A consumed token slot may accept a replacement token on the same edge.
	always_comb begin
		event_insert_valid_w = 1'b0;
		event_insert_index_w = '0;
		for(integer token_index = 0; token_index < EVENT_TOKEN_DEPTH; token_index++)begin
			if(!event_insert_valid_w && (!event_token_valid_q[token_index] ||
				event_token_consume_w[token_index]))begin
				event_insert_valid_w = 1'b1;
				event_insert_index_w = token_index;
			end
		end
	end
	assign event_ready_o = configured_q && !fault_q && event_insert_valid_w;
	assign sync_ready_o = configured_q && !fault_q &&
		((sync_token_count_q < SYNC_TOKEN_DEPTH) || sync_token_consume_w);

	// Protocol errors are sticky because continuing would silently move a static boundary.
	always_comb begin
		set_fault_w = 1'b0;
		set_fault_code_w = FAULT_NONE;
		if(configure_valid_i && (configure_generation_i == 0 ||
			configure_count_i > QUEUE_ENTRY_LIMIT))begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_CONFIGURATION;
		end
		else if(run_i && configured_q && !primed_o)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_NOT_PRIMED;
		end
		else if(pool_response_valid_i && (pool_response_error_i || inflight_count_q == 0))begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_POOL_RESPONSE;
		end
		else if(response_accept_w && ((cache_level_q - retire_count_w) >= CACHE_DEPTH))begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_CACHE_OVERFLOW;
		end
		else if(cache_underflow_w || (run_i && configured_q && primed_o && !done_o && cache_level_q == 0))begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_CACHE_UNDERFLOW;
		end
		else if(boundary_missed_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_BOUNDARY_MISSED;
		end
		else if(invalid_record_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_RECORD;
		end
	end

	// Configuration and Pool bookkeeping are independent of Queue wait state.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			configured_q <= 1'b0;
			prime_complete_q <= 1'b0;
			control_count_q <= '0;
			generation_q <= '0;
			fetch_index_q <= '0;
			retired_count_q <= '0;
			inflight_count_q <= '0;
		end
		else if(clear_i)begin
			configured_q <= 1'b0;
			prime_complete_q <= 1'b0;
			control_count_q <= '0;
			generation_q <= '0;
			fetch_index_q <= '0;
			retired_count_q <= '0;
			inflight_count_q <= '0;
		end
		else if(configure_valid_i)begin
			configured_q <= configure_generation_i != 0 && configure_count_i <= QUEUE_ENTRY_LIMIT;
			prime_complete_q <= configure_count_i == 0;
			control_count_q <= configure_count_i;
			generation_q <= configure_generation_i;
			fetch_index_q <= '0;
			retired_count_q <= '0;
			inflight_count_q <= '0;
		end
		else begin
			if(primed_o)begin
				prime_complete_q <= 1'b1;
			end
			if(request_fire)begin
				fetch_index_q <= fetch_index_q + 1'b1;
			end
			if(request_fire && !pool_response_valid_i)begin
				inflight_count_q <= inflight_count_q + 1'b1;
			end
			else if(!request_fire && pool_response_valid_i && inflight_count_q != 0)begin
				inflight_count_q <= inflight_count_q - 1'b1;
			end
			if(retire_count_w != 0)begin
				retired_count_q <= retired_count_q + retire_count_w;
			end
		end
	end

	// The four-entry cache shifts only on retirement; responses append behind retained entries.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			cache_level_q <= '0;
			for(integer cache_index = 0; cache_index < CACHE_DEPTH; cache_index++)begin
				cache_q[cache_index] <= '0;
			end
		end
		else if(clear_i || configure_valid_i)begin
			cache_level_q <= '0;
			for(integer cache_index = 0; cache_index < CACHE_DEPTH; cache_index++)begin
				cache_q[cache_index] <= '0;
			end
		end
		else begin
			for(integer cache_index = 0; cache_index < CACHE_DEPTH; cache_index++)begin
				if((cache_index + retire_count_w) < cache_level_q)begin
					cache_q[cache_index] <= cache_q[cache_index + retire_count_w];
				end
				else begin
					cache_q[cache_index] <= '0;
				end
			end
			if(response_accept_w && ((cache_level_q - retire_count_w) < CACHE_DEPTH))begin
				cache_q[cache_level_q - retire_count_w] <= pool_response_data_i;
			end
			case({response_accept_w, retire_count_w != 0})
				2'b10: cache_level_q <= cache_level_q + 1'b1;
				2'b01: cache_level_q <= cache_level_q - retire_count_w;
				2'b11: cache_level_q <= cache_level_q - retire_count_w + 1'b1;
				default: cache_level_q <= cache_level_q;
			endcase
		end
	end

	// Tagged event tokens remain distinct; WAIT_EVENT consumes one matching token.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			for(integer token_index = 0; token_index < EVENT_TOKEN_DEPTH; token_index++)begin
				event_token_valid_q[token_index] <= 1'b0;
				event_token_tag_q[token_index] <= '0;
			end
		end
		else if(clear_i || configure_valid_i)begin
			for(integer token_index = 0; token_index < EVENT_TOKEN_DEPTH; token_index++)begin
				event_token_valid_q[token_index] <= 1'b0;
				event_token_tag_q[token_index] <= '0;
			end
		end
		else begin
			for(integer token_index = 0; token_index < EVENT_TOKEN_DEPTH; token_index++)begin
				if(event_token_consume_w[token_index])begin
					event_token_valid_q[token_index] <= 1'b0;
				end
			end
			if(event_fire)begin
				event_token_valid_q[event_insert_index_w] <= 1'b1;
				event_token_tag_q[event_insert_index_w] <= event_tag_i;
			end
		end
	end

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			sync_token_count_q <= '0;
		end
		else if(clear_i || configure_valid_i)begin
			sync_token_count_q <= '0;
		end
		else begin
			case({sync_fire, sync_token_consume_w})
				2'b10: sync_token_count_q <= sync_token_count_q + 1'b1;
				2'b01: sync_token_count_q <= sync_token_count_q - 1'b1;
				default: sync_token_count_q <= sync_token_count_q;
			endcase
		end
	end

	// Queue-local time freezes on QCTL boundaries while the physical clock continues.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			queue_cycle_q <= '0;
		end
		else if(clear_i || configure_valid_i)begin
			queue_cycle_q <= '0;
		end
		else if(scheduler_enable_o)begin
			queue_cycle_q <= queue_cycle_q + 1'b1;
		end
	end

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else if(clear_i || configure_valid_i)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else if(set_fault_w && !fault_q)begin
			fault_q <= 1'b1;
			fault_code_q <= set_fault_code_w;
		end
	end
endmodule
