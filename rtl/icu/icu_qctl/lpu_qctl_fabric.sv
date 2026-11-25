// Runtime-only QCTL Fabric. Static Record distribution uses the independent
// load-time Relay chains and never enters this module.
module lpu_qctl_fabric #(
	parameter integer QUEUE_COUNT = lpu_qctl_pkg::QCTL_QUEUE_COUNT,
	parameter integer QUEUE_ID_WIDTH = QUEUE_COUNT <= 1 ? 1 : $clog2(QUEUE_COUNT)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic clear_i,

	input logic event_in_valid_i,
	input logic event_in_ready_i,
	output logic event_backpressure_o,
	input logic [QUEUE_COUNT-1:0] endpoint_event_wait_i,
	input logic [QUEUE_COUNT-1:0] endpoint_event_consume_i,
	output logic [QUEUE_COUNT-1:0] event_wait_o,
	output logic [QUEUE_COUNT-1:0] event_consume_o,
	input logic [QUEUE_COUNT-1:0] event_buffer_valid_i,
	input logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] event_buffer_tag_i,
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

	output logic fault_o,
	output logic [3:0] fault_code_o
);
	localparam logic [3:0] FAULT_NONE = 4'd0;
	localparam logic [3:0] FAULT_NOTIFIER_PARTICIPANT = 4'd1;

	logic [QUEUE_COUNT-1:0] sync_arrive_mask_q;
	logic [QUEUE_COUNT-1:0] sync_arrive_mask_w;
	logic [QUEUE_COUNT-1:0] release_mask_q;
	logic [QUEUE_ID_WIDTH-1:0] notify_round_robin_q;
	logic all_arrived_w;
	logic notify_selected_w;
	logic [QUEUE_ID_WIDTH-1:0] notify_queue_w;
	logic notify_fire_w;
	logic notifier_is_participant_w;
	logic fault_q;
	logic [3:0] fault_code_q;

	assign event_backpressure_o = event_in_valid_i && !event_in_ready_i;
	assign event_wait_o = endpoint_event_wait_i;
	assign event_consume_o = endpoint_event_consume_i;
	assign endpoint_event_valid_o = event_buffer_valid_i;
	assign endpoint_event_tag_o = event_buffer_tag_i;
	assign mem_packet_valid_o = endpoint_mem_packet_valid_i;
	assign mem_packet_ordinal_o = endpoint_mem_packet_ordinal_i;
	assign endpoint_mem_packet_retired_o = mem_packet_retired_i;
	assign sync_arrive_mask_w = sync_arrive_mask_q |
		(endpoint_sync_arrive_valid_i & sync_participant_mask_i);
	assign all_arrived_w = ((sync_arrive_mask_w & sync_participant_mask_i) ==
		sync_participant_mask_i);
	assign notifier_is_participant_w = notify_selected_w &&
		sync_participant_mask_i[notify_queue_w];
	assign notify_fire_w = notify_selected_w && all_arrived_w &&
		(release_mask_q == '0) && !notifier_is_participant_w;
	assign endpoint_sync_release_valid_o = release_mask_q;
	assign fault_o = fault_q;
	assign fault_code_o = fault_code_q;

	// Round-robin arbitration accepts at most one NOTIFY after all configured
	// participants have reached the current SYNC round.
	always_comb begin
		notify_selected_w = 1'b0;
		notify_queue_w = '0;
		for(integer request_offset = 0; request_offset < QUEUE_COUNT; request_offset++)begin
			integer candidate_queue;
			candidate_queue = notify_round_robin_q + request_offset;
			if(candidate_queue >= QUEUE_COUNT)begin
				candidate_queue = candidate_queue - QUEUE_COUNT;
			end
			if(!notify_selected_w && endpoint_notify_valid_i[candidate_queue])begin
				notify_selected_w = 1'b1;
				notify_queue_w = candidate_queue[QUEUE_ID_WIDTH-1:0];
			end
		end
	end

	// Only the selected legal NOTIFY requester observes Ready in this cycle.
	always_comb begin
		endpoint_notify_ready_o = '0;
		if(notify_fire_w)begin
			endpoint_notify_ready_o[notify_queue_w] = 1'b1;
		end
	end

	// Arrival bits are idempotent within one barrier round. A successful NOTIFY
	// creates a one-cycle Release and clears all history before the next round.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			sync_arrive_mask_q <= '0;
			release_mask_q <= '0;
			notify_round_robin_q <= '0;
		end
		else if(clear_i)begin
			sync_arrive_mask_q <= '0;
			release_mask_q <= '0;
			notify_round_robin_q <= '0;
		end
		else begin
			release_mask_q <= '0;
			if(notify_fire_w)begin
				sync_arrive_mask_q <= '0;
				release_mask_q <= sync_participant_mask_i;
				notify_round_robin_q <= notify_queue_w == QUEUE_COUNT - 1 ?
					'0 : notify_queue_w + 1'b1;
			end
			else if(release_mask_q != '0)begin
				sync_arrive_mask_q <= '0;
			end
			else begin
				sync_arrive_mask_q <= sync_arrive_mask_w;
			end
		end
	end

	// A NOTIFY requester included in the participant mask would self-lock the
	// fixed protocol and is therefore reported as a sticky configuration fault.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else if(clear_i)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else if(!fault_q && notifier_is_participant_w)begin
			fault_q <= 1'b1;
			fault_code_q <= FAULT_NOTIFIER_PARTICIPANT;
		end
	end
endmodule
