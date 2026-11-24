module lpu_qctl_fabric #(
	parameter integer POOL_DEPTH = 512,
	parameter integer QUEUE_COUNT = 220,
	parameter integer QUEUE_ENTRY_LIMIT = 16,
	parameter integer CACHE_DEPTH = 4,
	parameter integer EVENT_TOKEN_DEPTH = 8,
	parameter integer SYNC_TOKEN_DEPTH = 8,
	parameter integer READ_LATENCY = 2,
	parameter integer GENERATION_WIDTH = 64,
	parameter integer POOL_ADDRESS_WIDTH = POOL_DEPTH <= 1 ? 1 : $clog2(POOL_DEPTH),
	parameter integer QUEUE_ID_WIDTH = QUEUE_COUNT <= 1 ? 1 : $clog2(QUEUE_COUNT),
	parameter integer ENTRY_INDEX_WIDTH = QUEUE_ENTRY_LIMIT <= 1 ? 1 : $clog2(QUEUE_ENTRY_LIMIT),
	parameter integer ENTRY_COUNT_WIDTH = $clog2(QUEUE_ENTRY_LIMIT + 1)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic clear_i,
	input logic run_i,

	// QCTL images use a dedicated 96-bit physical record path. Program Loader
	// routing is intentionally outside this execution fabric.
	input logic load_mode_i,
	input logic partition_valid_i,
	output logic partition_ready_o,
	input logic [QUEUE_ID_WIDTH-1:0] partition_queue_i,
	input logic [POOL_ADDRESS_WIDTH-1:0] partition_base_i,
	input logic [ENTRY_COUNT_WIDTH-1:0] partition_count_i,
	input logic [GENERATION_WIDTH-1:0] partition_generation_i,
	input logic load_valid_i,
	output logic load_ready_o,
	input logic [POOL_ADDRESS_WIDTH-1:0] load_address_i,
	input logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] load_data_i,

	// Each vector lane is owned by the Scheduler with the same logical Queue ID.
	input logic event_valid_i,
	output logic event_ready_o,
	input logic [31:0] event_tag_i,
	input logic [QUEUE_COUNT-1:0] event_mask_i,
	input logic [GENERATION_WIDTH-1:0] event_generation_i,
	input logic event_phase_i,
	output logic receipt_valid_o,
	input logic receipt_ready_i,
	output logic [31:0] receipt_tag_o,
	output logic [GENERATION_WIDTH-1:0] receipt_generation_o,
	output logic [63:0] receipt_cycle_o,
	input logic [QUEUE_COUNT-1:0] sync_valid_i,
	output logic [QUEUE_COUNT-1:0] sync_ready_o,
	output logic [QUEUE_COUNT-1:0] notify_valid_o,
	input logic [QUEUE_COUNT-1:0] notify_ready_i,
	output logic [QUEUE_COUNT-1:0] mem_packet_valid_o,
	output logic [QUEUE_COUNT*lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] mem_packet_ordinal_o,
	input logic [QUEUE_COUNT-1:0] mem_packet_retired_i,

	output logic [QUEUE_COUNT-1:0] queue_active_o,
	output logic [QUEUE_COUNT-1:0] scheduler_enable_o,
	output logic [QUEUE_COUNT*lpu_qctl_pkg::QCTL_CYCLE_WIDTH-1:0] queue_cycle_o,
	output logic [QUEUE_COUNT-1:0] wait_event_blocked_o,
	output logic [QUEUE_COUNT*lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] wait_event_tag_o,
	output logic [QUEUE_COUNT-1:0] primed_o,
	output logic [QUEUE_COUNT-1:0] done_o,
	output logic all_primed_o,
	output logic all_done_o,
	output logic fault_o,
	output logic [7:0] fault_code_o
);
	logic partition_fire;
	logic partition_basic_valid_w;
	logic [QUEUE_COUNT-1:0] queue_active_q;
	logic [QUEUE_COUNT-1:0] configure_valid;
	logic [QUEUE_COUNT*ENTRY_COUNT_WIDTH-1:0] configure_count;
	logic [QUEUE_COUNT*GENERATION_WIDTH-1:0] configure_generation;

	logic [QUEUE_COUNT-1:0] request_valid;
	logic [QUEUE_COUNT-1:0] request_ready;
	logic [QUEUE_COUNT*ENTRY_INDEX_WIDTH-1:0] request_index;
	logic [QUEUE_COUNT*GENERATION_WIDTH-1:0] request_generation;
	logic response_valid;
	logic [QUEUE_ID_WIDTH-1:0] response_queue;
	logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] response_data;
	logic response_error;
	logic pool_fault;
	logic [3:0] pool_fault_code;
	logic [QUEUE_COUNT-1:0] controller_fault;
	logic [QUEUE_COUNT*4-1:0] controller_fault_code;
	logic controller_fault_found_w;
	logic [3:0] first_controller_fault_code_w;

	logic [QUEUE_COUNT-1:0] selected_fire;
	logic [GENERATION_WIDTH-1:0] generation_q;
	logic event_fault, epoch_fault,event_idle;
	always_ff @(posedge clk_i or negedge rst_ni)
		if(!rst_ni)begin generation_q<='0;epoch_fault<=0;end
		else if(clear_i)begin generation_q<='0;epoch_fault<=0;end
		else if(partition_fire && partition_basic_valid_w)begin
			if(generation_q!='0 && generation_q!=partition_generation_i)epoch_fault<=1;
			else generation_q<=partition_generation_i;
		end
	lpu_qctl_event_buffer #(.N(QUEUE_COUNT),.DEPTH(EVENT_TOKEN_DEPTH),.G(GENERATION_WIDTH)) u_events (
		.clk_i,.rst_ni,.clear_i,.generation_i(generation_q),.event_valid_i,.event_ready_o,
		.event_tag_i,.event_generation_i,.event_mask_i,.event_phase_i,
		.idle_o(event_idle),.active_i(queue_active_q),.wait_i(wait_event_blocked_o),.wait_tag_i(wait_event_tag_o),.fire_o(selected_fire),
		.receipt_valid_o,.receipt_ready_i,.receipt_tag_o,.receipt_generation_o,.receipt_cycle_o,.fault_o(event_fault));
	assign partition_fire = partition_valid_i && partition_ready_o;
	assign partition_basic_valid_w = (partition_queue_i < QUEUE_COUNT) &&
		(partition_count_i <= QUEUE_ENTRY_LIMIT) && (partition_generation_i != 0) &&
		(({1'b0, partition_base_i} + partition_count_i) <= POOL_DEPTH);
	assign queue_active_o = queue_active_q;
	assign all_primed_o = &(primed_o | ~queue_active_q);
	assign all_done_o = event_idle && &(done_o | ~queue_active_q);
	assign fault_o = epoch_fault || event_fault || pool_fault || (|controller_fault);
	assign fault_code_o = epoch_fault ? 8'h21 : event_fault ? 8'h20 : pool_fault ? {4'd0, pool_fault_code} :
		(controller_fault_found_w ? {4'd1, first_controller_fault_code_w} : 8'd0);

	// Partition acceptance configures exactly one matching local Controller.
	always_comb begin
		configure_valid = '0;
		configure_count = '0;
		configure_generation = '0;
		if(partition_fire && partition_basic_valid_w)begin
			configure_valid[partition_queue_i] = 1'b1;
			configure_count[partition_queue_i*ENTRY_COUNT_WIDTH+:ENTRY_COUNT_WIDTH] = partition_count_i;
			configure_generation[partition_queue_i*GENERATION_WIDTH+:GENERATION_WIDTH] = partition_generation_i;
		end
	end

	// Return the first local fault code for compact top-level diagnosis. The
	// per-Queue fault location remains visible in hierarchy and assertions.
	always_comb begin
		controller_fault_found_w = 1'b0;
		first_controller_fault_code_w = '0;
		for(integer queue_index = 0; queue_index < QUEUE_COUNT; queue_index++)begin
			if(!controller_fault_found_w && controller_fault[queue_index])begin
				controller_fault_found_w = 1'b1;
				first_controller_fault_code_w = controller_fault_code[queue_index*4+:4];
			end
		end
	end

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			queue_active_q <= '0;
		end
		else if(clear_i)begin
			queue_active_q <= '0;
		end
		else begin
			queue_active_q <= queue_active_q | configure_valid;
		end
	end

	lpu_qctl_shared_pool #(
		.POOL_DEPTH(POOL_DEPTH),
		.QUEUE_COUNT(QUEUE_COUNT),
		.QUEUE_ENTRY_LIMIT(QUEUE_ENTRY_LIMIT),
		.READ_LATENCY(READ_LATENCY),
		.GENERATION_WIDTH(GENERATION_WIDTH)
	) u_shared_pool (
		.clk_i,
		.rst_ni,
		.clear_i,
		.load_mode_i,
		.partition_valid_i,
		.partition_ready_o,
		.partition_queue_i,
		.partition_base_i,
		.partition_count_i,
		.partition_generation_i,
		.load_valid_i,
		.load_ready_o,
		.load_address_i,
		.load_data_i,
		.request_valid_i(request_valid),
		.request_ready_o(request_ready),
		.request_index_i(request_index),
		.request_generation_i(request_generation),
		.response_valid_o(response_valid),
		.response_queue_o(response_queue),
		.response_data_o(response_data),
		.response_error_o(response_error),
		.fault_o(pool_fault),
		.fault_code_o(pool_fault_code)
	);

	generate
		for(genvar queue_index = 0; queue_index < QUEUE_COUNT; queue_index++)begin : gen_queue_controller
			lpu_qctl_queue_controller #(
				.QUEUE_ENTRY_LIMIT(QUEUE_ENTRY_LIMIT),
				.CACHE_DEPTH(CACHE_DEPTH),
				.EVENT_TOKEN_DEPTH(EVENT_TOKEN_DEPTH),
				.SYNC_TOKEN_DEPTH(SYNC_TOKEN_DEPTH),
				.GENERATION_WIDTH(GENERATION_WIDTH)
			) u_queue_controller (
				.clk_i,
				.rst_ni,
				.clear_i,
				.configure_valid_i(configure_valid[queue_index]),
				.configure_count_i(configure_count[queue_index*ENTRY_COUNT_WIDTH+:ENTRY_COUNT_WIDTH]),
				.configure_generation_i(configure_generation[queue_index*GENERATION_WIDTH+:GENERATION_WIDTH]),
				.pool_request_valid_o(request_valid[queue_index]),
				.pool_request_ready_i(request_ready[queue_index]),
				.pool_request_index_o(request_index[queue_index*ENTRY_INDEX_WIDTH+:ENTRY_INDEX_WIDTH]),
				.pool_request_generation_o(request_generation[queue_index*GENERATION_WIDTH+:GENERATION_WIDTH]),
				.pool_response_valid_i(response_valid && (response_queue == queue_index)),
				.pool_response_data_i(response_data),
				.pool_response_error_i(response_error),
				.event_valid_i(selected_fire[queue_index]),
				.event_ready_o(),
				.event_tag_i(wait_event_tag_o[queue_index*lpu_qctl_pkg::QCTL_OPERAND_WIDTH+:lpu_qctl_pkg::QCTL_OPERAND_WIDTH]),
				.sync_valid_i(sync_valid_i[queue_index]),
				.sync_ready_o(sync_ready_o[queue_index]),
				.notify_valid_o(notify_valid_o[queue_index]),
				.notify_ready_i(notify_ready_i[queue_index]),
				.mem_packet_valid_o(mem_packet_valid_o[queue_index]),
				.mem_packet_ordinal_o(mem_packet_ordinal_o[queue_index*lpu_qctl_pkg::QCTL_OPERAND_WIDTH+:lpu_qctl_pkg::QCTL_OPERAND_WIDTH]),
				.mem_packet_retired_i(mem_packet_retired_i[queue_index]),
				.run_i(run_i),
				.scheduler_enable_o(scheduler_enable_o[queue_index]),
				.queue_cycle_o(queue_cycle_o[queue_index*lpu_qctl_pkg::QCTL_CYCLE_WIDTH+:lpu_qctl_pkg::QCTL_CYCLE_WIDTH]),
				.wait_event_blocked_o(wait_event_blocked_o[queue_index]),
				.wait_event_tag_o(wait_event_tag_o[queue_index*lpu_qctl_pkg::QCTL_OPERAND_WIDTH+:lpu_qctl_pkg::QCTL_OPERAND_WIDTH]),
				.primed_o(primed_o[queue_index]),
				.done_o(done_o[queue_index]),
				.fault_o(controller_fault[queue_index]),
				.fault_code_o(controller_fault_code[queue_index*4+:4])
			);
		end
	endgenerate
endmodule
