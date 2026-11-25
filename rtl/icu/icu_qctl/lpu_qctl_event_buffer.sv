module lpu_qctl_event_buffer #(
	parameter integer QUEUE_COUNT = lpu_qctl_pkg::QCTL_QUEUE_COUNT,
	parameter integer EVENT_DEPTH = 8,
	parameter integer TAG_WIDTH = lpu_qctl_pkg::QCTL_OPERAND_WIDTH,
	parameter integer EVENT_COUNT_WIDTH = $clog2(EVENT_DEPTH + 1),
	parameter integer EVENT_INDEX_WIDTH = EVENT_DEPTH <= 1 ? 1 : $clog2(EVENT_DEPTH)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic clear_i,
	input logic event_in_valid_i,
	output logic event_in_ready_o,
	input logic [TAG_WIDTH-1:0] event_in_tag_i,
	input logic [QUEUE_COUNT-1:0] event_in_target_mask_i,
	input logic [QUEUE_COUNT-1:0] event_wait_i,
	input logic [QUEUE_COUNT-1:0] event_consume_i,
	output logic [QUEUE_COUNT-1:0] event_valid_o,
	output logic [TAG_WIDTH-1:0] event_tag_o,
	output logic fault_o,
	output logic [3:0] fault_code_o
);
	localparam logic [3:0] FAULT_NONE = 4'd0;
	localparam logic [3:0] FAULT_EMPTY_TARGET = 4'd1;
	localparam logic [3:0] FAULT_CONSUME_PROTOCOL = 4'd2;

	logic [EVENT_COUNT_WIDTH-1:0] event_count_q;
	logic [TAG_WIDTH-1:0] event_tag_q [0:EVENT_DEPTH-1];
	logic [QUEUE_COUNT-1:0] event_pending_q [0:EVENT_DEPTH-1];
	logic selected_found_w;
	logic [EVENT_INDEX_WIDTH-1:0] selected_index_w;
	logic [QUEUE_COUNT-1:0] selected_visible_mask_w;
	logic [QUEUE_COUNT-1:0] selected_consume_mask_w;
	logic [QUEUE_COUNT-1:0] selected_pending_after_consume_w;
	logic selected_retire_w;
	logic event_fire_w;
	logic event_store_w;
	logic consume_protocol_error_w;
	logic [EVENT_COUNT_WIDTH-1:0] compact_count_w;
	logic [TAG_WIDTH-1:0] event_tag_d [0:EVENT_DEPTH-1];
	logic [QUEUE_COUNT-1:0] event_pending_d [0:EVENT_DEPTH-1];
	logic fault_q;
	logic [3:0] fault_code_q;

	assign event_valid_o = selected_visible_mask_w;
	assign event_tag_o = selected_found_w ? event_tag_q[selected_index_w] : '0;
	assign selected_consume_mask_w = event_consume_i & selected_visible_mask_w;
	assign selected_pending_after_consume_w = selected_found_w ?
		(event_pending_q[selected_index_w] & ~selected_consume_mask_w) : '0;
	assign selected_retire_w = selected_found_w && (selected_consume_mask_w != '0) &&
		(selected_pending_after_consume_w == '0);
	assign event_in_ready_o = (event_count_q < EVENT_DEPTH) || selected_retire_w;
	assign event_fire_w = event_in_valid_i && event_in_ready_o;
	assign event_store_w = event_fire_w && (event_in_target_mask_i != '0);
	assign consume_protocol_error_w = |(event_consume_i & ~selected_visible_mask_w);
	assign fault_o = fault_q;
	assign fault_code_o = fault_code_q;

	// Select the oldest buffered event that has at least one pending Controller
	// currently waiting. Compact storage preserves repeated same-TAG order.
	always_comb begin
		selected_found_w = 1'b0;
		selected_index_w = '0;
		selected_visible_mask_w = '0;
		for(integer slot = 0; slot < EVENT_DEPTH; slot++)begin
			if(!selected_found_w && (slot < event_count_q) &&
				|(event_pending_q[slot] & event_wait_i))begin
				selected_found_w = 1'b1;
				selected_index_w = slot[EVENT_INDEX_WIDTH-1:0];
				selected_visible_mask_w = event_pending_q[slot] & event_wait_i;
			end
		end
	end

	// Apply independent consumer acknowledgements, compact a retired entry, and
	// append a newly accepted event without merging repeated TAG values.
	always_comb begin
		compact_count_w = '0;
		for(integer slot = 0; slot < EVENT_DEPTH; slot++)begin
			event_tag_d[slot] = '0;
			event_pending_d[slot] = '0;
		end
		for(integer slot = 0; slot < EVENT_DEPTH; slot++)begin
			if(slot < event_count_q)begin
				if(selected_found_w && (slot == selected_index_w))begin
					if(!selected_retire_w)begin
						event_tag_d[compact_count_w] = event_tag_q[slot];
						event_pending_d[compact_count_w] = selected_pending_after_consume_w;
						compact_count_w = compact_count_w + 1'b1;
					end
				end
				else begin
					event_tag_d[compact_count_w] = event_tag_q[slot];
					event_pending_d[compact_count_w] = event_pending_q[slot];
					compact_count_w = compact_count_w + 1'b1;
				end
			end
		end
		if(event_store_w)begin
			event_tag_d[compact_count_w] = event_in_tag_i;
			event_pending_d[compact_count_w] = event_in_target_mask_i;
			compact_count_w = compact_count_w + 1'b1;
		end
	end

	// Event entries are ordered records; only the pending consumer mask changes
	// in place before the entry is removed after its final acknowledgement.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			event_count_q <= '0;
			for(integer slot = 0; slot < EVENT_DEPTH; slot++)begin
				event_tag_q[slot] <= '0;
				event_pending_q[slot] <= '0;
			end
		end
		else if(clear_i)begin
			event_count_q <= '0;
			for(integer slot = 0; slot < EVENT_DEPTH; slot++)begin
				event_tag_q[slot] <= '0;
				event_pending_q[slot] <= '0;
			end
		end
		else begin
			event_count_q <= compact_count_w;
			for(integer slot = 0; slot < EVENT_DEPTH; slot++)begin
				event_tag_q[slot] <= event_tag_d[slot];
				event_pending_q[slot] <= event_pending_d[slot];
			end
		end
	end

	// Empty target masks and acknowledgements outside the selected event are
	// sticky protocol errors; the offending empty event is consumed but not stored.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else if(clear_i)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else if(!fault_q && event_fire_w && (event_in_target_mask_i == '0))begin
			fault_q <= 1'b1;
			fault_code_q <= FAULT_EMPTY_TARGET;
		end
		else if(!fault_q && consume_protocol_error_w)begin
			fault_q <= 1'b1;
			fault_code_q <= FAULT_CONSUME_PROTOCOL;
		end
	end
endmodule
