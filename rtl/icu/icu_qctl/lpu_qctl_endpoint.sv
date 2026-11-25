// FU-local QCTL endpoint. It owns only Queue-reader state and one semantic
// Controller; QCTL Records remain in the owning Relay's regional store.
module lpu_qctl_endpoint #(
	parameter integer QUEUE_ENTRY_LIMIT = 16,
	parameter integer GENERATION_WIDTH = 64,
	parameter integer ENTRY_INDEX_WIDTH = QUEUE_ENTRY_LIMIT <= 1 ? 1 : $clog2(QUEUE_ENTRY_LIMIT),
	parameter integer ENTRY_COUNT_WIDTH = $clog2(QUEUE_ENTRY_LIMIT + 1)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic clear_i,
	input logic run_i,

	input logic configure_valid_i,
	input logic [ENTRY_COUNT_WIDTH-1:0] configure_count_i,
	input logic [GENERATION_WIDTH-1:0] configure_generation_i,

	output logic [ENTRY_INDEX_WIDTH-1:0] store_head_index_o,
	output logic [GENERATION_WIDTH-1:0] store_head_generation_o,
	input logic store_loaded_i,
	input logic store_head_valid_i,
	input logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] store_head_record_i,
	input logic store_head_error_i,

	input logic [lpu_qctl_pkg::QCTL_CYCLE_WIDTH-1:0] scheduler_cycle_i,
	output logic scheduler_counter_ce_o,
	input logic event_valid_i,
	input logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] event_tag_i,
	output logic event_wait_o,
	output logic event_consume_o,
	output logic sync_arrive_valid_o,
	input logic sync_release_valid_i,
	output logic notify_valid_o,
	input logic notify_ready_i,
	output logic mem_packet_valid_o,
	output logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] mem_packet_ordinal_o,
	input logic mem_packet_retired_i,
	output logic configured_o,
	output logic primed_o,
	output logic done_o,
	output logic fault_o,
	output logic [3:0] fault_code_o
);
	localparam logic [3:0] FAULT_NONE = 4'd0;
	localparam logic [3:0] FAULT_CONFIGURATION = 4'd1;
	localparam logic [3:0] FAULT_STORE_READ = 4'd2;
	localparam logic [3:0] FAULT_RETIRE = 4'd3;

	logic configured_q;
	logic [ENTRY_COUNT_WIDTH-1:0] control_count_q;
	logic [GENERATION_WIDTH-1:0] generation_q;
	logic [ENTRY_COUNT_WIDTH-1:0] retire_offset_q;
	logic head_valid;
	logic head_retire;
	logic endpoint_fault_q;
	logic [3:0] endpoint_fault_code_q;
	logic controller_fault;
	logic [3:0] controller_fault_code;
	logic set_endpoint_fault_w;
	logic [3:0] set_endpoint_fault_code_w;

	assign store_head_index_o = retire_offset_q[ENTRY_INDEX_WIDTH-1:0];
	assign store_head_generation_o = generation_q;
	assign configured_o = configured_q;
	assign primed_o = configured_q && store_loaded_i;
	assign done_o = configured_q && (retire_offset_q == control_count_q);
	assign head_valid = configured_q && primed_o && !done_o &&
		store_head_valid_i && !store_head_error_i && !endpoint_fault_q;
	assign fault_o = endpoint_fault_q || controller_fault;
	assign fault_code_o = endpoint_fault_q ? endpoint_fault_code_q : controller_fault_code;

	// Detect malformed configuration, invalid regional reads and illegal retire requests.
	always_comb begin
		set_endpoint_fault_w = 1'b0;
		set_endpoint_fault_code_w = FAULT_NONE;
		if(configure_valid_i && ((configure_generation_i == 0) ||
			(configure_count_i > QUEUE_ENTRY_LIMIT)))begin
			set_endpoint_fault_w = 1'b1;
			set_endpoint_fault_code_w = FAULT_CONFIGURATION;
		end
		else if(run_i && configured_q && !done_o && store_head_error_i)begin
			set_endpoint_fault_w = 1'b1;
			set_endpoint_fault_code_w = FAULT_STORE_READ;
		end
		else if(head_retire && !head_valid)begin
			set_endpoint_fault_w = 1'b1;
			set_endpoint_fault_code_w = FAULT_RETIRE;
		end
	end

	// Queue-reader state advances only when the local Controller retires one valid Head.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			configured_q <= 1'b0;
			control_count_q <= '0;
			generation_q <= '0;
			retire_offset_q <= '0;
		end
		else if(clear_i)begin
			configured_q <= 1'b0;
			control_count_q <= '0;
			generation_q <= '0;
			retire_offset_q <= '0;
		end
		else if(configure_valid_i)begin
			configured_q <= (configure_generation_i != 0) &&
				(configure_count_i <= QUEUE_ENTRY_LIMIT);
			control_count_q <= configure_count_i;
			generation_q <= configure_generation_i;
			retire_offset_q <= '0;
		end
		else if(head_retire && head_valid)begin
			retire_offset_q <= retire_offset_q + 1'b1;
		end
	end

	// Retain the first Queue-reader fault until the next program or configuration.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			endpoint_fault_q <= 1'b0;
			endpoint_fault_code_q <= FAULT_NONE;
		end
		else if(clear_i || configure_valid_i)begin
			endpoint_fault_q <= 1'b0;
			endpoint_fault_code_q <= FAULT_NONE;
		end
		else if(set_endpoint_fault_w && !endpoint_fault_q)begin
			endpoint_fault_q <= 1'b1;
			endpoint_fault_code_q <= set_endpoint_fault_code_w;
		end
	end

	lpu_qctl_controller u_controller (
		.clk_i, .rst_ni, .clear_i, .configure_valid_i, .run_i,
		.configured_i(configured_o), .primed_i(primed_o), .done_i(done_o),
		.scheduler_cycle_i, .scheduler_counter_ce_o,
		.head_valid_i(head_valid), .head_record_i(store_head_record_i),
		.head_retire_o(head_retire),
		.sync_arrive_valid_o, .sync_release_valid_i,
		.notify_valid_o, .notify_ready_i,
		.event_valid_i, .event_tag_i, .event_wait_o, .event_consume_o,
		.mem_packet_valid_o, .mem_packet_ordinal_o, .mem_packet_retired_i,
		.fault_o(controller_fault), .fault_code_o(controller_fault_code)
	);
endmodule
