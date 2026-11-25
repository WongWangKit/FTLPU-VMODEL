// One Hemisphere QCTL Relay chain. Its seven stages mirror Program Distribution
// and terminate all Queue traffic locally before RUN begins.
module lpu_qctl_relay_chain #(
	parameter integer HEMISPHERE_ID = 0,
	parameter integer RELAY_COUNT = 7,
	parameter integer QUEUE_COUNT = lpu_qctl_pkg::QCTL_QUEUE_COUNT,
	parameter integer LOCAL_QUEUE_COUNT = 18,
	parameter integer REGION_DEPTH = 64,
	parameter integer BUFFER_DEPTH = 2,
	parameter integer QUEUE_ENTRY_LIMIT = 16,
	parameter integer GENERATION_WIDTH = 64,
	parameter integer QUEUE_ID_WIDTH = QUEUE_COUNT <= 1 ? 1 : $clog2(QUEUE_COUNT),
	parameter integer ENTRY_INDEX_WIDTH = QUEUE_ENTRY_LIMIT <= 1 ? 1 : $clog2(QUEUE_ENTRY_LIMIT),
	parameter integer ENTRY_COUNT_WIDTH = $clog2(QUEUE_ENTRY_LIMIT + 1)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic clear_i,

	input logic packet_valid_i,
	output logic packet_ready_o,
	input logic packet_kind_i,
	input logic [QUEUE_ID_WIDTH-1:0] packet_queue_i,
	input logic [ENTRY_INDEX_WIDTH-1:0] packet_offset_i,
	input logic [ENTRY_COUNT_WIDTH-1:0] packet_count_i,
	input logic [GENERATION_WIDTH-1:0] packet_generation_i,
	input logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] packet_record_i,

	input logic [QUEUE_COUNT*ENTRY_INDEX_WIDTH-1:0] queue_head_index_i,
	input logic [QUEUE_COUNT*GENERATION_WIDTH-1:0] queue_head_generation_i,
	output logic [QUEUE_COUNT-1:0] queue_configured_o,
	output logic [QUEUE_COUNT-1:0] queue_loaded_o,
	output logic [QUEUE_COUNT-1:0] queue_head_valid_o,
	output logic [QUEUE_COUNT*lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] queue_head_record_o,
	output logic [QUEUE_COUNT-1:0] queue_head_error_o,

	output logic [QUEUE_COUNT-1:0] configure_valid_o,
	output logic [QUEUE_COUNT*ENTRY_COUNT_WIDTH-1:0] configure_count_o,
	output logic [QUEUE_COUNT*GENERATION_WIDTH-1:0] configure_generation_o,

	output logic idle_o,
	output logic fault_o,
	output logic [3:0] fault_code_o
);
	logic [RELAY_COUNT-1:0] relay_input_valid;
	logic [RELAY_COUNT-1:0] relay_input_ready;
	logic [RELAY_COUNT-1:0] relay_input_kind;
	logic [RELAY_COUNT*QUEUE_ID_WIDTH-1:0] relay_input_queue;
	logic [RELAY_COUNT*ENTRY_INDEX_WIDTH-1:0] relay_input_offset;
	logic [RELAY_COUNT*ENTRY_COUNT_WIDTH-1:0] relay_input_count;
	logic [RELAY_COUNT*GENERATION_WIDTH-1:0] relay_input_generation;
	logic [RELAY_COUNT*lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] relay_input_record;

	logic [RELAY_COUNT-1:0] relay_output_valid;
	logic [RELAY_COUNT-1:0] relay_output_ready;
	logic [RELAY_COUNT-1:0] relay_output_kind;
	logic [RELAY_COUNT*QUEUE_ID_WIDTH-1:0] relay_output_queue;
	logic [RELAY_COUNT*ENTRY_INDEX_WIDTH-1:0] relay_output_offset;
	logic [RELAY_COUNT*ENTRY_COUNT_WIDTH-1:0] relay_output_count;
	logic [RELAY_COUNT*GENERATION_WIDTH-1:0] relay_output_generation;
	logic [RELAY_COUNT*lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] relay_output_record;

	logic [RELAY_COUNT*QUEUE_COUNT-1:0] relay_queue_configured;
	logic [RELAY_COUNT*QUEUE_COUNT-1:0] relay_queue_loaded;
	logic [RELAY_COUNT*QUEUE_COUNT-1:0] relay_head_valid;
	logic [RELAY_COUNT*QUEUE_COUNT*lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] relay_head_record;
	logic [RELAY_COUNT*QUEUE_COUNT-1:0] relay_head_error;
	logic [RELAY_COUNT*QUEUE_COUNT-1:0] relay_configure_valid;
	logic [RELAY_COUNT*QUEUE_COUNT*ENTRY_COUNT_WIDTH-1:0] relay_configure_count;
	logic [RELAY_COUNT*QUEUE_COUNT*GENERATION_WIDTH-1:0] relay_configure_generation;
	logic [RELAY_COUNT-1:0] relay_idle;
	logic [RELAY_COUNT-1:0] relay_fault;
	logic [RELAY_COUNT*4-1:0] relay_fault_code;
	logic entry_hemisphere_valid_w;
	logic entry_route_fault_q;

	assign entry_hemisphere_valid_w = lpu_qctl_pkg::qctl_queue_valid(packet_queue_i) &&
		(lpu_qctl_pkg::qctl_queue_hemisphere(packet_queue_i) == HEMISPHERE_ID);
	assign relay_input_valid[0] = packet_valid_i && entry_hemisphere_valid_w && !entry_route_fault_q;
	assign packet_ready_o = entry_hemisphere_valid_w ? relay_input_ready[0] : 1'b1;
	assign relay_input_kind[0] = packet_kind_i;
	assign relay_input_queue[0+:QUEUE_ID_WIDTH] = packet_queue_i;
	assign relay_input_offset[0+:ENTRY_INDEX_WIDTH] = packet_offset_i;
	assign relay_input_count[0+:ENTRY_COUNT_WIDTH] = packet_count_i;
	assign relay_input_generation[0+:GENERATION_WIDTH] = packet_generation_i;
	assign relay_input_record[0+:lpu_qctl_pkg::QCTL_RECORD_WIDTH] = packet_record_i;
	assign relay_output_ready[RELAY_COUNT-1] = 1'b1;
	assign idle_o = (&relay_idle) && !packet_valid_i;
	assign fault_o = entry_route_fault_q || (|relay_fault);

	// Preserve the first physical Relay fault code in chain order.
	always_comb begin
		fault_code_o = entry_route_fault_q ? 4'd7 : 4'd0;
		for(integer relay_index = 0; relay_index < RELAY_COUNT; relay_index++)begin
			if((fault_code_o == 0) && relay_fault[relay_index])begin
				fault_code_o = relay_fault_code[relay_index*4+:4];
			end
		end
	end

	// Merge disjoint per-Relay Queue ports into one Hemisphere-wide Queue interface.
	always_comb begin
		queue_configured_o = '0;
		queue_loaded_o = '0;
		queue_head_valid_o = '0;
		queue_head_record_o = '0;
		queue_head_error_o = '0;
		configure_valid_o = '0;
		configure_count_o = '0;
		configure_generation_o = '0;
		for(integer relay_index = 0; relay_index < RELAY_COUNT; relay_index++)begin
			queue_configured_o = queue_configured_o |
				relay_queue_configured[relay_index*QUEUE_COUNT+:QUEUE_COUNT];
			queue_loaded_o = queue_loaded_o |
				relay_queue_loaded[relay_index*QUEUE_COUNT+:QUEUE_COUNT];
			queue_head_valid_o = queue_head_valid_o |
				relay_head_valid[relay_index*QUEUE_COUNT+:QUEUE_COUNT];
			queue_head_record_o = queue_head_record_o |
				relay_head_record[relay_index*QUEUE_COUNT*lpu_qctl_pkg::QCTL_RECORD_WIDTH+:
				 QUEUE_COUNT*lpu_qctl_pkg::QCTL_RECORD_WIDTH];
			queue_head_error_o = queue_head_error_o |
				relay_head_error[relay_index*QUEUE_COUNT+:QUEUE_COUNT];
			configure_valid_o = configure_valid_o |
				relay_configure_valid[relay_index*QUEUE_COUNT+:QUEUE_COUNT];
			configure_count_o = configure_count_o |
				relay_configure_count[relay_index*QUEUE_COUNT*ENTRY_COUNT_WIDTH+:
				 QUEUE_COUNT*ENTRY_COUNT_WIDTH];
			configure_generation_o = configure_generation_o |
				relay_configure_generation[relay_index*QUEUE_COUNT*GENERATION_WIDTH+:
				 QUEUE_COUNT*GENERATION_WIDTH];
		end
	end

	// Instantiate the same ordered seven-stage physical topology as Program Distribution.
	generate
		for(genvar relay_gen = 0; relay_gen < RELAY_COUNT; relay_gen++)begin : gen_relay
			if(relay_gen > 0)begin : gen_chain_link
				assign relay_input_valid[relay_gen] = relay_output_valid[relay_gen-1];
				assign relay_output_ready[relay_gen-1] = relay_input_ready[relay_gen];
				assign relay_input_kind[relay_gen] = relay_output_kind[relay_gen-1];
				assign relay_input_queue[relay_gen*QUEUE_ID_WIDTH+:QUEUE_ID_WIDTH] =
					relay_output_queue[(relay_gen-1)*QUEUE_ID_WIDTH+:QUEUE_ID_WIDTH];
				assign relay_input_offset[relay_gen*ENTRY_INDEX_WIDTH+:ENTRY_INDEX_WIDTH] =
					relay_output_offset[(relay_gen-1)*ENTRY_INDEX_WIDTH+:ENTRY_INDEX_WIDTH];
				assign relay_input_count[relay_gen*ENTRY_COUNT_WIDTH+:ENTRY_COUNT_WIDTH] =
					relay_output_count[(relay_gen-1)*ENTRY_COUNT_WIDTH+:ENTRY_COUNT_WIDTH];
				assign relay_input_generation[relay_gen*GENERATION_WIDTH+:GENERATION_WIDTH] =
					relay_output_generation[(relay_gen-1)*GENERATION_WIDTH+:GENERATION_WIDTH];
				assign relay_input_record[
					relay_gen*lpu_qctl_pkg::QCTL_RECORD_WIDTH+:lpu_qctl_pkg::QCTL_RECORD_WIDTH] =
					relay_output_record[(relay_gen-1)*lpu_qctl_pkg::QCTL_RECORD_WIDTH+:
					 lpu_qctl_pkg::QCTL_RECORD_WIDTH];
			end

			lpu_qctl_relay #(
				.HEMISPHERE_ID(HEMISPHERE_ID), .RELAY_INDEX(relay_gen),
				.LAST_RELAY(relay_gen == RELAY_COUNT - 1),
				.QUEUE_COUNT(QUEUE_COUNT), .LOCAL_QUEUE_COUNT(LOCAL_QUEUE_COUNT),
				.REGION_DEPTH(REGION_DEPTH), .BUFFER_DEPTH(BUFFER_DEPTH),
				.QUEUE_ENTRY_LIMIT(QUEUE_ENTRY_LIMIT), .GENERATION_WIDTH(GENERATION_WIDTH)
			) u_relay (
				.clk_i, .rst_ni, .clear_i,
				.chain_packet_valid_i(relay_input_valid[relay_gen]),
				.chain_packet_ready_o(relay_input_ready[relay_gen]),
				.chain_packet_kind_i(relay_input_kind[relay_gen]),
				.chain_packet_queue_i(relay_input_queue[relay_gen*QUEUE_ID_WIDTH+:QUEUE_ID_WIDTH]),
				.chain_packet_offset_i(relay_input_offset[
					relay_gen*ENTRY_INDEX_WIDTH+:ENTRY_INDEX_WIDTH]),
				.chain_packet_count_i(relay_input_count[
					relay_gen*ENTRY_COUNT_WIDTH+:ENTRY_COUNT_WIDTH]),
				.chain_packet_generation_i(relay_input_generation[
					relay_gen*GENERATION_WIDTH+:GENERATION_WIDTH]),
				.chain_packet_record_i(relay_input_record[
					relay_gen*lpu_qctl_pkg::QCTL_RECORD_WIDTH+:lpu_qctl_pkg::QCTL_RECORD_WIDTH]),
				.next_packet_valid_o(relay_output_valid[relay_gen]),
				.next_packet_ready_i(relay_output_ready[relay_gen]),
				.next_packet_kind_o(relay_output_kind[relay_gen]),
				.next_packet_queue_o(relay_output_queue[relay_gen*QUEUE_ID_WIDTH+:QUEUE_ID_WIDTH]),
				.next_packet_offset_o(relay_output_offset[
					relay_gen*ENTRY_INDEX_WIDTH+:ENTRY_INDEX_WIDTH]),
				.next_packet_count_o(relay_output_count[
					relay_gen*ENTRY_COUNT_WIDTH+:ENTRY_COUNT_WIDTH]),
				.next_packet_generation_o(relay_output_generation[
					relay_gen*GENERATION_WIDTH+:GENERATION_WIDTH]),
				.next_packet_record_o(relay_output_record[
					relay_gen*lpu_qctl_pkg::QCTL_RECORD_WIDTH+:lpu_qctl_pkg::QCTL_RECORD_WIDTH]),
				.queue_head_index_i, .queue_head_generation_i,
				.queue_configured_o(relay_queue_configured[relay_gen*QUEUE_COUNT+:QUEUE_COUNT]),
				.queue_loaded_o(relay_queue_loaded[relay_gen*QUEUE_COUNT+:QUEUE_COUNT]),
				.queue_head_valid_o(relay_head_valid[relay_gen*QUEUE_COUNT+:QUEUE_COUNT]),
				.queue_head_record_o(relay_head_record[
					relay_gen*QUEUE_COUNT*lpu_qctl_pkg::QCTL_RECORD_WIDTH+:
					 QUEUE_COUNT*lpu_qctl_pkg::QCTL_RECORD_WIDTH]),
				.queue_head_error_o(relay_head_error[relay_gen*QUEUE_COUNT+:QUEUE_COUNT]),
				.configure_valid_o(relay_configure_valid[relay_gen*QUEUE_COUNT+:QUEUE_COUNT]),
				.configure_count_o(relay_configure_count[
					relay_gen*QUEUE_COUNT*ENTRY_COUNT_WIDTH+:QUEUE_COUNT*ENTRY_COUNT_WIDTH]),
				.configure_generation_o(relay_configure_generation[
					relay_gen*QUEUE_COUNT*GENERATION_WIDTH+:QUEUE_COUNT*GENERATION_WIDTH]),
				.idle_o(relay_idle[relay_gen]), .fault_o(relay_fault[relay_gen]),
				.fault_code_o(relay_fault_code[relay_gen*4+:4])
			);
		end
	endgenerate

	// Reject packets sent to the wrong Hemisphere before they enter the chain.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			entry_route_fault_q <= 1'b0;
		end
		else if(clear_i)begin
			entry_route_fault_q <= 1'b0;
		end
		else if(packet_valid_i && packet_ready_o && !entry_hemisphere_valid_w)begin
			entry_route_fault_q <= 1'b1;
		end
	end
endmodule
