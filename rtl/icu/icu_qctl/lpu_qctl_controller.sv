module lpu_qctl_controller (
	input logic clk_i,
	input logic rst_ni,
	input logic clear_i,
	input logic configure_valid_i,
	input logic run_i,
	input logic configured_i,
	input logic primed_i,
	input logic done_i,
	input logic [lpu_qctl_pkg::QCTL_CYCLE_WIDTH-1:0] scheduler_cycle_i,
	output logic scheduler_counter_ce_o,
	input logic head_valid_i,
	input logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] head_record_i,
	output logic head_retire_o,
	output logic sync_arrive_valid_o,
	input logic sync_release_valid_i,
	output logic notify_valid_o,
	input logic notify_ready_i,
	input logic event_valid_i,
	input logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] event_tag_i,
	output logic event_wait_o,
	output logic event_consume_o,
	output logic mem_packet_valid_o,
	output logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] mem_packet_ordinal_o,
	input logic mem_packet_retired_i,
	output logic fault_o,
	output logic [3:0] fault_code_o
);
	localparam logic [3:0] FAULT_NONE = 4'd0;
	localparam logic [3:0] FAULT_NOT_PRIMED = 4'd1;
	localparam logic [3:0] FAULT_BOUNDARY_MISSED = 4'd2;
	localparam logic [3:0] FAULT_RECORD = 4'd3;

	typedef enum logic [2:0] {
		ST_IDLE,
		ST_SYNC_WAIT,
		ST_EVENT_WAIT,
		ST_NOTIFY_WAIT,
		ST_MEMPACKET_WAIT
	} qctl_state_e;

	qctl_state_e state_q;
	qctl_state_e state_d;
	logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] wait_operand_q;
	logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] wait_operand_d;
	logic [lpu_qctl_pkg::QCTL_CYCLE_WIDTH-1:0] head_cycle_w;
	logic [lpu_qctl_pkg::QCTL_OPCODE_WIDTH-1:0] head_opcode_w;
	logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] head_operand_w;
	logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] event_compare_operand_w;
	logic boundary_hit_w;
	logic boundary_missed_w;
	logic invalid_record_w;
	logic fault_q;
	logic [3:0] fault_code_q;
	logic set_fault_w;
	logic [3:0] set_fault_code_w;

	assign head_cycle_w = lpu_qctl_pkg::qctl_record_cycle(head_record_i);
	assign head_opcode_w = lpu_qctl_pkg::qctl_record_opcode(head_record_i);
	assign head_operand_w = lpu_qctl_pkg::qctl_record_operand(head_record_i);
	assign boundary_hit_w = run_i && configured_i && primed_i && head_valid_i &&
		(state_q == ST_IDLE) && (head_cycle_w == scheduler_cycle_i);
	assign boundary_missed_w = run_i && configured_i && primed_i && head_valid_i &&
		(state_q == ST_IDLE) && (head_cycle_w < scheduler_cycle_i);
	assign event_compare_operand_w = state_q == ST_EVENT_WAIT ? wait_operand_q : head_operand_w;
	assign event_consume_o = event_wait_o && event_valid_i &&
		(event_tag_i == event_compare_operand_w);
	assign fault_o = fault_q;
	assign fault_code_o = fault_code_q;

	// The semantic FSM holds the regional Queue head until the matching global condition
	// completes. A boundary hit is handled before the local counter can advance.
	always_comb begin
		state_d = state_q;
		wait_operand_d = wait_operand_q;
		head_retire_o = 1'b0;
		sync_arrive_valid_o = 1'b0;
		notify_valid_o = 1'b0;
		event_wait_o = 1'b0;
		mem_packet_valid_o = 1'b0;
		mem_packet_ordinal_o = wait_operand_q;
		invalid_record_w = 1'b0;

		case(state_q)
			ST_IDLE: begin
				if(boundary_hit_w)begin
					case(head_opcode_w)
						lpu_qctl_pkg::QCTL_OPCODE_SYNC: begin
							if(head_operand_w != 0)begin
								invalid_record_w = 1'b1;
							end
							else begin
								sync_arrive_valid_o = 1'b1;
								state_d = ST_SYNC_WAIT;
							end
						end
						lpu_qctl_pkg::QCTL_OPCODE_WAIT_EVENT: begin
							event_wait_o = 1'b1;
							wait_operand_d = head_operand_w;
							if(event_consume_o)begin
								head_retire_o = 1'b1;
							end
							else begin
								state_d = ST_EVENT_WAIT;
							end
						end
						lpu_qctl_pkg::QCTL_OPCODE_NOTIFY: begin
							if(head_operand_w != 0)begin
								invalid_record_w = 1'b1;
							end
							else begin
								notify_valid_o = 1'b1;
								if(notify_ready_i)begin
									head_retire_o = 1'b1;
								end
								else begin
									state_d = ST_NOTIFY_WAIT;
								end
							end
						end
						lpu_qctl_pkg::QCTL_OPCODE_MEM_PACKET: begin
							if(head_operand_w == 0)begin
								invalid_record_w = 1'b1;
							end
							else begin
								mem_packet_valid_o = 1'b1;
								mem_packet_ordinal_o = head_operand_w;
								wait_operand_d = head_operand_w;
								if(mem_packet_retired_i)begin
									head_retire_o = 1'b1;
								end
								else begin
									state_d = ST_MEMPACKET_WAIT;
								end
							end
						end
						default: invalid_record_w = 1'b1;
					endcase
				end
			end
			ST_SYNC_WAIT: begin
				sync_arrive_valid_o = 1'b1;
				if(sync_release_valid_i)begin
					head_retire_o = 1'b1;
					state_d = ST_IDLE;
				end
			end
			ST_EVENT_WAIT: begin
				event_wait_o = 1'b1;
				if(event_consume_o)begin
					head_retire_o = 1'b1;
					state_d = ST_IDLE;
				end
			end
			ST_NOTIFY_WAIT: begin
				notify_valid_o = 1'b1;
				if(notify_ready_i)begin
					head_retire_o = 1'b1;
					state_d = ST_IDLE;
				end
			end
			ST_MEMPACKET_WAIT: begin
				mem_packet_valid_o = 1'b1;
				mem_packet_ordinal_o = wait_operand_q;
				if(mem_packet_retired_i)begin
					head_retire_o = 1'b1;
					state_d = ST_IDLE;
				end
			end
			default: begin
				state_d = ST_IDLE;
				invalid_record_w = 1'b1;
			end
		endcase
	end

	// The Scheduler counter advances only while the next regional control boundary
	// is known to be in the future. Missing-but-not-done head state is a safe stall.
	always_comb begin
		scheduler_counter_ce_o = 1'b0;
		if(run_i && configured_i && primed_i && !fault_q && (state_q == ST_IDLE))begin
			if(done_i)begin
				scheduler_counter_ce_o = 1'b1;
			end
			else if(head_valid_i && (head_cycle_w > scheduler_cycle_i))begin
				scheduler_counter_ce_o = 1'b1;
			end
		end
	end

	// QCTL protocol errors are sticky because continuing could cross an absolute
	// control boundary or reinterpret a malformed control record.
	always_comb begin
		set_fault_w = 1'b0;
		set_fault_code_w = FAULT_NONE;
		if(run_i && configured_i && !primed_i)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_NOT_PRIMED;
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

	// Wait state and operand remain stable until the corresponding completion.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			state_q <= ST_IDLE;
			wait_operand_q <= '0;
		end
		else if(clear_i || configure_valid_i)begin
			state_q <= ST_IDLE;
			wait_operand_q <= '0;
		end
		else begin
			state_q <= state_d;
			wait_operand_q <= wait_operand_d;
		end
	end

	// Retain the first Controller fault until the next Queue configuration.
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
