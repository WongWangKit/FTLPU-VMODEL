module lpu_qctl_global_subsystem #(
	parameter integer TOTAL_CAPACITY = 512,
	parameter integer QUEUE_COUNT = lpu_qctl_pkg::QCTL_QUEUE_COUNT,
	parameter integer QUEUE_ENTRY_LIMIT = 16,
	parameter integer EVENT_DEPTH = 8,
	parameter integer REGION_DEPTH = 64,
	parameter integer RELAY_BUFFER_DEPTH = 2,
	parameter integer GENERATION_WIDTH = 64,
	parameter integer ADDRESS_WIDTH = TOTAL_CAPACITY <= 1 ? 1 : $clog2(TOTAL_CAPACITY),
	parameter integer QUEUE_ID_WIDTH = QUEUE_COUNT <= 1 ? 1 : $clog2(QUEUE_COUNT),
	parameter integer ENTRY_INDEX_WIDTH = QUEUE_ENTRY_LIMIT <= 1 ? 1 : $clog2(QUEUE_ENTRY_LIMIT),
	parameter integer ENTRY_COUNT_WIDTH = $clog2(QUEUE_ENTRY_LIMIT + 1)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic clear_i,
	input logic load_mode_i,
	input logic partition_valid_i,
	output logic partition_ready_o,
	input logic [QUEUE_ID_WIDTH-1:0] partition_queue_i,
	input logic [ADDRESS_WIDTH-1:0] partition_base_i,
	input logic [ENTRY_COUNT_WIDTH-1:0] partition_count_i,
	input logic [GENERATION_WIDTH-1:0] partition_generation_i,
	input logic load_valid_i,
	output logic load_ready_o,
	input logic [ADDRESS_WIDTH-1:0] load_address_i,
	input logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] load_data_i,

	output logic [QUEUE_COUNT-1:0] endpoint_configure_valid_o,
	output logic [QUEUE_COUNT*ENTRY_COUNT_WIDTH-1:0] endpoint_configure_count_o,
	output logic [QUEUE_COUNT*GENERATION_WIDTH-1:0] endpoint_configure_generation_o,
	input logic [QUEUE_COUNT*ENTRY_INDEX_WIDTH-1:0] endpoint_head_index_i,
	input logic [QUEUE_COUNT*GENERATION_WIDTH-1:0] endpoint_head_generation_i,
	output logic [QUEUE_COUNT-1:0] endpoint_store_loaded_o,
	output logic [QUEUE_COUNT-1:0] endpoint_head_valid_o,
	output logic [QUEUE_COUNT*lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] endpoint_head_record_o,
	output logic [QUEUE_COUNT-1:0] endpoint_head_error_o,

	input logic event_in_valid_i,
	output logic event_in_ready_o,
	input logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] event_in_tag_i,
	input logic [QUEUE_COUNT-1:0] event_in_target_mask_i,
	output logic event_backpressure_o,
	input logic [QUEUE_COUNT-1:0] endpoint_event_wait_i,
	input logic [QUEUE_COUNT-1:0] endpoint_event_consume_i,
	output logic [QUEUE_COUNT-1:0] endpoint_event_valid_o,
	output logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] endpoint_event_tag_o,

	input logic [QUEUE_COUNT-1:0] sync_participant_mask_i,
	input logic [QUEUE_COUNT-1:0] endpoint_sync_arrive_valid_i,
	input logic [QUEUE_COUNT-1:0] endpoint_notify_valid_i,
	output logic [QUEUE_COUNT-1:0] endpoint_notify_ready_o,
	output logic [QUEUE_COUNT-1:0] endpoint_sync_release_valid_o,
	input logic [QUEUE_COUNT-1:0] endpoint_mem_packet_valid_i,
	input logic [QUEUE_COUNT*lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] endpoint_mem_packet_ordinal_i,
	output logic [QUEUE_COUNT-1:0] mem_packet_valid_o,
	output logic [QUEUE_COUNT*lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] mem_packet_ordinal_o,
	input logic [QUEUE_COUNT-1:0] mem_packet_retired_i,
	output logic [QUEUE_COUNT-1:0] endpoint_mem_packet_retired_o,

	input logic [QUEUE_COUNT-1:0] endpoint_configured_i,
	input logic [QUEUE_COUNT-1:0] endpoint_primed_i,
	input logic [QUEUE_COUNT-1:0] endpoint_done_i,
	input logic [QUEUE_COUNT-1:0] endpoint_fault_i,
	input logic [QUEUE_COUNT*4-1:0] endpoint_fault_code_i,
	output logic [QUEUE_COUNT-1:0] queue_active_o,
	output logic load_complete_o,
	output logic all_primed_o,
	output logic all_done_o,
	output logic fault_o,
	output logic [7:0] fault_code_o
);
	logic relay_packet_valid;
	logic relay_packet_ready;
	logic relay_packet_kind;
	logic [QUEUE_ID_WIDTH-1:0] relay_packet_queue;
	logic [ENTRY_INDEX_WIDTH-1:0] relay_packet_offset;
	logic [ENTRY_COUNT_WIDTH-1:0] relay_packet_count;
	logic [GENERATION_WIDTH-1:0] relay_packet_generation;
	logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] relay_packet_record;
	logic packet_hemisphere_w;
	logic east_packet_ready;
	logic west_packet_ready;
	logic manager_idle;
	logic manager_fault;
	logic [3:0] manager_fault_code;

	logic [QUEUE_COUNT-1:0] east_queue_configured;
	logic [QUEUE_COUNT-1:0] west_queue_configured;
	logic [QUEUE_COUNT-1:0] east_queue_loaded;
	logic [QUEUE_COUNT-1:0] west_queue_loaded;
	logic [QUEUE_COUNT-1:0] east_head_valid;
	logic [QUEUE_COUNT-1:0] west_head_valid;
	logic [QUEUE_COUNT*lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] east_head_record;
	logic [QUEUE_COUNT*lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] west_head_record;
	logic [QUEUE_COUNT-1:0] east_head_error;
	logic [QUEUE_COUNT-1:0] west_head_error;
	logic [QUEUE_COUNT-1:0] east_configure_valid;
	logic [QUEUE_COUNT-1:0] west_configure_valid;
	logic [QUEUE_COUNT*ENTRY_COUNT_WIDTH-1:0] east_configure_count;
	logic [QUEUE_COUNT*ENTRY_COUNT_WIDTH-1:0] west_configure_count;
	logic [QUEUE_COUNT*GENERATION_WIDTH-1:0] east_configure_generation;
	logic [QUEUE_COUNT*GENERATION_WIDTH-1:0] west_configure_generation;
	logic east_chain_idle;
	logic west_chain_idle;
	logic east_chain_fault;
	logic west_chain_fault;
	logic [3:0] east_chain_fault_code;
	logic [3:0] west_chain_fault_code;

	logic [QUEUE_COUNT-1:0] store_queue_configured;
	logic [QUEUE_COUNT-1:0] store_queue_loaded;
	logic [QUEUE_COUNT-1:0] event_wait;
	logic [QUEUE_COUNT-1:0] event_consume;
	logic [QUEUE_COUNT-1:0] event_buffer_valid;
	logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] event_buffer_tag;
	logic event_fault;
	logic [3:0] event_fault_code;
	logic fabric_fault;
	logic [3:0] fabric_fault_code;
	logic local_fault_found_w;
	logic [3:0] first_local_fault_code_w;

	initial begin
		if(QUEUE_COUNT != lpu_qctl_pkg::QCTL_QUEUE_COUNT)begin
			$error("Formal distributed QCTL mapping requires exactly %0d Queues",
				lpu_qctl_pkg::QCTL_QUEUE_COUNT);
		end
	end

	assign packet_hemisphere_w = lpu_qctl_pkg::qctl_queue_hemisphere(relay_packet_queue);
	assign relay_packet_ready = packet_hemisphere_w ? west_packet_ready : east_packet_ready;
	assign store_queue_configured = east_queue_configured | west_queue_configured;
	assign store_queue_loaded = east_queue_loaded | west_queue_loaded;
	assign endpoint_configure_valid_o = east_configure_valid | west_configure_valid;
	assign endpoint_configure_count_o = east_configure_count | west_configure_count;
	assign endpoint_configure_generation_o = east_configure_generation | west_configure_generation;
	assign endpoint_store_loaded_o = store_queue_loaded;
	assign endpoint_head_valid_o = east_head_valid | west_head_valid;
	assign endpoint_head_record_o = east_head_record | west_head_record;
	assign endpoint_head_error_o = east_head_error | west_head_error;
	assign queue_active_o = endpoint_configured_i;
	assign load_complete_o = manager_idle && east_chain_idle && west_chain_idle &&
		&(store_queue_loaded | ~store_queue_configured) &&
		!manager_fault && !east_chain_fault && !west_chain_fault;
	assign all_primed_o = load_complete_o && &(endpoint_primed_i | ~endpoint_configured_i);
	assign all_done_o = &(endpoint_done_i | ~endpoint_configured_i);
	assign fault_o = manager_fault || east_chain_fault || west_chain_fault ||
		event_fault || fabric_fault || (|endpoint_fault_i);
	assign fault_code_o = manager_fault ? {4'h1, manager_fault_code} :
		(east_chain_fault ? {4'h4, east_chain_fault_code} :
		(west_chain_fault ? {4'h5, west_chain_fault_code} :
		(event_fault ? {4'h2, event_fault_code} :
		(fabric_fault ? {4'h3, fabric_fault_code} :
		(local_fault_found_w ? {4'h6, first_local_fault_code_w} : 8'h00)))));

	// Preserve the first FU-local endpoint fault for top-level diagnosis.
	always_comb begin
		local_fault_found_w = 1'b0;
		first_local_fault_code_w = '0;
		for(integer queue_index = 0; queue_index < QUEUE_COUNT; queue_index++)begin
			if(!local_fault_found_w && endpoint_fault_i[queue_index])begin
				local_fault_found_w = 1'b1;
				first_local_fault_code_w = endpoint_fault_code_i[queue_index*4+:4];
			end
		end
	end

	lpu_qctl_load_manager #(
		.TOTAL_CAPACITY(TOTAL_CAPACITY), .QUEUE_COUNT(QUEUE_COUNT),
		.QUEUE_ENTRY_LIMIT(QUEUE_ENTRY_LIMIT), .GENERATION_WIDTH(GENERATION_WIDTH)
	) u_load_manager (
		.clk_i, .rst_ni, .clear_i, .load_mode_i,
		.partition_valid_i, .partition_ready_o, .partition_queue_i,
		.partition_base_i, .partition_count_i, .partition_generation_i,
		.load_valid_i, .load_ready_o, .load_address_i, .load_data_i,
		.relay_packet_valid_o(relay_packet_valid), .relay_packet_ready_i(relay_packet_ready),
		.relay_packet_kind_o(relay_packet_kind), .relay_packet_queue_o(relay_packet_queue),
		.relay_packet_offset_o(relay_packet_offset), .relay_packet_count_o(relay_packet_count),
		.relay_packet_generation_o(relay_packet_generation),
		.relay_packet_record_o(relay_packet_record),
		.idle_o(manager_idle), .fault_o(manager_fault), .fault_code_o(manager_fault_code)
	);

	lpu_qctl_relay_chain #(
		.HEMISPHERE_ID(0), .QUEUE_COUNT(QUEUE_COUNT), .REGION_DEPTH(REGION_DEPTH),
		.BUFFER_DEPTH(RELAY_BUFFER_DEPTH), .QUEUE_ENTRY_LIMIT(QUEUE_ENTRY_LIMIT),
		.GENERATION_WIDTH(GENERATION_WIDTH)
	) u_east_relay_chain (
		.clk_i, .rst_ni, .clear_i,
		.packet_valid_i(relay_packet_valid && !packet_hemisphere_w),
		.packet_ready_o(east_packet_ready), .packet_kind_i(relay_packet_kind),
		.packet_queue_i(relay_packet_queue), .packet_offset_i(relay_packet_offset),
		.packet_count_i(relay_packet_count), .packet_generation_i(relay_packet_generation),
		.packet_record_i(relay_packet_record),
		.queue_head_index_i(endpoint_head_index_i),
		.queue_head_generation_i(endpoint_head_generation_i),
		.queue_configured_o(east_queue_configured), .queue_loaded_o(east_queue_loaded),
		.queue_head_valid_o(east_head_valid), .queue_head_record_o(east_head_record),
		.queue_head_error_o(east_head_error),
		.configure_valid_o(east_configure_valid), .configure_count_o(east_configure_count),
		.configure_generation_o(east_configure_generation),
		.idle_o(east_chain_idle), .fault_o(east_chain_fault),
		.fault_code_o(east_chain_fault_code)
	);

	lpu_qctl_relay_chain #(
		.HEMISPHERE_ID(1), .QUEUE_COUNT(QUEUE_COUNT), .REGION_DEPTH(REGION_DEPTH),
		.BUFFER_DEPTH(RELAY_BUFFER_DEPTH), .QUEUE_ENTRY_LIMIT(QUEUE_ENTRY_LIMIT),
		.GENERATION_WIDTH(GENERATION_WIDTH)
	) u_west_relay_chain (
		.clk_i, .rst_ni, .clear_i,
		.packet_valid_i(relay_packet_valid && packet_hemisphere_w),
		.packet_ready_o(west_packet_ready), .packet_kind_i(relay_packet_kind),
		.packet_queue_i(relay_packet_queue), .packet_offset_i(relay_packet_offset),
		.packet_count_i(relay_packet_count), .packet_generation_i(relay_packet_generation),
		.packet_record_i(relay_packet_record),
		.queue_head_index_i(endpoint_head_index_i),
		.queue_head_generation_i(endpoint_head_generation_i),
		.queue_configured_o(west_queue_configured), .queue_loaded_o(west_queue_loaded),
		.queue_head_valid_o(west_head_valid), .queue_head_record_o(west_head_record),
		.queue_head_error_o(west_head_error),
		.configure_valid_o(west_configure_valid), .configure_count_o(west_configure_count),
		.configure_generation_o(west_configure_generation),
		.idle_o(west_chain_idle), .fault_o(west_chain_fault),
		.fault_code_o(west_chain_fault_code)
	);

	lpu_qctl_event_buffer #(
		.QUEUE_COUNT(QUEUE_COUNT), .EVENT_DEPTH(EVENT_DEPTH)
	) u_event_buffer (
		.clk_i, .rst_ni, .clear_i,
		.event_in_valid_i, .event_in_ready_o, .event_in_tag_i, .event_in_target_mask_i,
		.event_wait_i(event_wait), .event_consume_i(event_consume),
		.event_valid_o(event_buffer_valid), .event_tag_o(event_buffer_tag),
		.fault_o(event_fault), .fault_code_o(event_fault_code)
	);

	lpu_qctl_fabric #(.QUEUE_COUNT(QUEUE_COUNT)) u_fabric (
		.clk_i, .rst_ni, .clear_i,
		.event_in_valid_i, .event_in_ready_i(event_in_ready_o), .event_backpressure_o,
		.endpoint_event_wait_i, .endpoint_event_consume_i,
		.event_wait_o(event_wait), .event_consume_o(event_consume),
		.event_buffer_valid_i(event_buffer_valid), .event_buffer_tag_i(event_buffer_tag),
		.endpoint_event_valid_o, .endpoint_event_tag_o,
		.sync_participant_mask_i, .endpoint_sync_arrive_valid_i,
		.endpoint_notify_valid_i, .endpoint_notify_ready_o,
		.endpoint_sync_release_valid_o,
		.endpoint_mem_packet_valid_i, .endpoint_mem_packet_ordinal_i,
		.mem_packet_valid_o, .mem_packet_ordinal_o, .mem_packet_retired_i,
		.endpoint_mem_packet_retired_o,
		.fault_o(fabric_fault), .fault_code_o(fabric_fault_code)
	);
endmodule
