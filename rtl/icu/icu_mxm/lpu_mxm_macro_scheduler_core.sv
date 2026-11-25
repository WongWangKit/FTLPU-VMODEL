module lpu_mxm_macro_scheduler_core #(
	parameter integer QUEUE_KIND = lpu_mxm_isa_pkg::MXM_QUEUE_LOAD,
	parameter integer ACTIVE_CONTEXTS = 4,
	parameter integer ACCUMULATOR_ROWS = lpu_mxm_config_pkg::ACCUMULATOR_DEPTH
) (
	input  logic clk_i,
	input  logic rst_ni,
	input  logic run_i,
	input  logic [31:0] schedule_cycle_i,

	input  logic context_valid_i,
	output logic context_ready_o,
	input  logic [48:0] context_instruction_i,
	input  logic [31:0] context_start_cycle_i,
	input  logic [31:0] context_inner_count_i,
	input  logic [31:0] context_inner_interval_i,
	input  logic signed [31:0] context_inner_stride_i,
	input  logic [31:0] context_outer_count_i,
	input  logic [31:0] context_outer_interval_i,
	input  logic signed [31:0] context_outer_stride_i,
	input  logic [1:0] context_induction_target_i,
	input  logic [12:0] context_operand_i,

	output logic issue_valid_o,
	input  logic issue_ready_i,
	output logic [48:0] issue_instruction_o,
	output logic [31:0] issue_cycle_o,

	output logic conflict_o,
	output logic fault_o,
	output logic [3:0] fault_code_o,
	output logic [$clog2(ACTIVE_CONTEXTS+1)-1:0] active_count_o
);
	localparam integer SLOT_BITS = ACTIVE_CONTEXTS > 1 ? $clog2(ACTIVE_CONTEXTS) : 1;
	localparam logic [1:0] TARGET_NONE = lpu_mxm_isa_pkg::MXM_INDUCTION_NONE;
	localparam logic [1:0] TARGET_OPERAND0 = lpu_mxm_isa_pkg::MXM_INDUCTION_OPERAND0;
	localparam logic [1:0] TARGET_OPERAND1 = lpu_mxm_isa_pkg::MXM_INDUCTION_OPERAND1;
	localparam logic [3:0] FAULT_NONE = 4'd0;
	localparam logic [3:0] FAULT_CONTEXT = 4'd1;
	localparam logic [3:0] FAULT_CONFLICT = 4'd2;
	localparam logic [3:0] FAULT_MISSED = 4'd3;
	localparam logic [3:0] FAULT_DEADLINE = 4'd4;
	localparam logic [3:0] FAULT_TIMEBASE = 4'd5;

	logic active_valid_q [0:ACTIVE_CONTEXTS-1];
	logic [48:0] active_instruction_q [0:ACTIVE_CONTEXTS-1];
	logic [1:0] active_target_q [0:ACTIVE_CONTEXTS-1];
	logic [12:0] active_operand_q [0:ACTIVE_CONTEXTS-1];
	logic [12:0] active_outer_operand_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_inner_count_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_inner_remaining_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_outer_remaining_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_inner_interval_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_outer_interval_q [0:ACTIVE_CONTEXTS-1];
	logic signed [31:0] active_inner_stride_q [0:ACTIVE_CONTEXTS-1];
	logic signed [31:0] active_outer_stride_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_outer_start_cycle_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_next_cycle_q [0:ACTIVE_CONTEXTS-1];

	logic free_context_found_w;
	logic [SLOT_BITS-1:0] free_context_slot_w;
	logic selected_context_found_w;
	logic [SLOT_BITS-1:0] selected_context_slot_w;
	logic multiple_due_w;
	logic missed_generation_w;
	logic context_illegal_w;
	logic context_accept_fire;
	logic context_admit_fire;
	logic schedule_select_fire;
	logic active_context_inner_advance_w;
	logic active_context_outer_advance_w;
	logic active_context_retire_w;
	logic dynamic_fault_w;
	logic [3:0] dynamic_fault_code_w;
	logic signed [63:0] inner_last_operand_w;
	logic signed [63:0] outer_first_operand_w;
	logic signed [63:0] final_operand_w;
	logic [63:0] inner_span_cycle_w;
	logic [63:0] final_issue_cycle_w;
	logic run_seen_q;
	logic [31:0] previous_schedule_cycle_q;
	logic fault_q;
	logic [3:0] fault_code_q;
	integer free_slot_index;
	integer due_slot_index;
	integer reset_slot_index;

	initial begin
		if(ACTIVE_CONTEXTS < 1)begin
			$error("ACTIVE_CONTEXTS must be at least one");
		end
	end

	// Rewrite only the induction-selected field; all opcode and mode bits remain fixed.
	function automatic logic [48:0] instruction_with_operand(
		input logic [48:0] instruction,
		input logic [1:0] target,
		input logic [12:0] operand
	);
		begin
			instruction_with_operand = instruction;
			case(QUEUE_KIND)
				lpu_mxm_isa_pkg::MXM_QUEUE_LOAD: begin
					if(target == TARGET_OPERAND0) instruction_with_operand[1] = operand[0];
				end
				lpu_mxm_isa_pkg::MXM_QUEUE_COMPUTE: begin
					if(target == TARGET_OPERAND0) instruction_with_operand[6:1] = operand[5:0];
					else if(target == TARGET_OPERAND1) instruction_with_operand[0] = operand[0];
				end
				lpu_mxm_isa_pkg::MXM_QUEUE_DEQUANT,
				lpu_mxm_isa_pkg::MXM_QUEUE_PARAM_LOAD: begin
					if(target == TARGET_OPERAND0) instruction_with_operand[0] = operand[0];
				end
				lpu_mxm_isa_pkg::MXM_QUEUE_BACKEND: begin
					if(target == TARGET_OPERAND0)begin
						instruction_with_operand[2+:lpu_mxm_backend_isa_pkg::BACKEND_ADDRESS_BITS] =
							operand[lpu_mxm_backend_isa_pkg::BACKEND_ADDRESS_BITS-1:0];
					end
				end
				default: begin
				end
			endcase
		end
	endfunction

	// Check the full signed induction result against the selected Stream operand range.
	function automatic logic operand_legal(input logic [1:0] target, input logic signed [63:0] operand);
		begin
			operand_legal = 1'b0;
			if(target == TARGET_NONE)begin
				operand_legal = operand == 0;
			end
			else begin
				case(QUEUE_KIND)
					lpu_mxm_isa_pkg::MXM_QUEUE_COMPUTE: begin
						if(target == TARGET_OPERAND0) operand_legal = (operand >= 0) && (operand <= 30);
						else if(target == TARGET_OPERAND1) operand_legal = (operand >= 0) && (operand <= 1);
					end
					lpu_mxm_isa_pkg::MXM_QUEUE_BACKEND: begin
						operand_legal = (target == TARGET_OPERAND0) && (operand >= 0) && (operand < ACCUMULATOR_ROWS);
					end
					default: begin
						operand_legal = (target == TARGET_OPERAND0) && (operand >= 0) && (operand <= 1);
					end
				endcase
			end
		end
	endfunction

	// Select the lowest numbered free Active Context slot for deterministic admission.
	always_comb begin
		free_context_found_w = 1'b0;
		free_context_slot_w = '0;
		active_count_o = '0;
		for(free_slot_index = 0; free_slot_index < ACTIVE_CONTEXTS; free_slot_index = free_slot_index + 1)begin
			if(active_valid_q[free_slot_index]) active_count_o = active_count_o + 1'b1;
			else if(!free_context_found_w)begin
				free_context_found_w = 1'b1;
				free_context_slot_w = free_slot_index[SLOT_BITS-1:0];
			end
		end
	end

	// Validate all affine operand corners and the final absolute issue cycle before admission.
	always_comb begin
		inner_span_cycle_w = {32'd0, context_inner_count_i - 1'b1} * {32'd0, context_inner_interval_i};
		final_issue_cycle_w = {32'd0, context_start_cycle_i} +
			({32'd0, context_outer_count_i - 1'b1} * {32'd0, context_outer_interval_i}) + inner_span_cycle_w;
		inner_last_operand_w = $signed({1'b0, context_operand_i}) +
			($signed(context_inner_stride_i) * $signed({1'b0, context_inner_count_i - 1'b1}));
		outer_first_operand_w = $signed({1'b0, context_operand_i}) +
			($signed(context_outer_stride_i) * $signed({1'b0, context_outer_count_i - 1'b1}));
		final_operand_w = outer_first_operand_w +
			($signed(context_inner_stride_i) * $signed({1'b0, context_inner_count_i - 1'b1}));
		context_illegal_w = (context_inner_count_i == 0) || (context_outer_count_i == 0) ||
			(context_inner_interval_i == 0) || (context_outer_interval_i == 0) || final_issue_cycle_w[63:32] ||
			((context_outer_count_i > 1) && ({32'd0, context_outer_interval_i} <= inner_span_cycle_w)) ||
			!operand_legal(context_induction_target_i, $signed({1'b0, context_operand_i})) ||
			!operand_legal(context_induction_target_i, inner_last_operand_w) ||
			!operand_legal(context_induction_target_i, outer_first_operand_w) ||
			!operand_legal(context_induction_target_i, final_operand_w);
		if(context_induction_target_i == TARGET_NONE)begin
			context_illegal_w = context_illegal_w || (context_inner_stride_i != 0) || (context_outer_stride_i != 0);
		end
	end

	assign context_ready_o = free_context_found_w && !fault_q;
	assign context_accept_fire = context_valid_i && context_ready_o;
	// A legal Context is committed exactly once; an illegal accepted Context raises a terminal fault instead.
	assign context_admit_fire = context_accept_fire && !context_illegal_w;

	// Select the unique Context due on this local QCTL-controlled Schedule Cycle.
	always_comb begin
		selected_context_found_w = 1'b0;
		selected_context_slot_w = '0;
		multiple_due_w = 1'b0;
		missed_generation_w = 1'b0;
		for(due_slot_index = 0; due_slot_index < ACTIVE_CONTEXTS; due_slot_index = due_slot_index + 1)begin
			if(active_valid_q[due_slot_index] && (active_next_cycle_q[due_slot_index] < schedule_cycle_i))begin
				missed_generation_w = 1'b1;
			end
			if(active_valid_q[due_slot_index] && (active_next_cycle_q[due_slot_index] == schedule_cycle_i))begin
				if(selected_context_found_w) multiple_due_w = 1'b1;
				else begin
					selected_context_found_w = 1'b1;
					selected_context_slot_w = due_slot_index[SLOT_BITS-1:0];
				end
			end
		end
	end

	assign issue_valid_o = run_i && selected_context_found_w && !multiple_due_w && !missed_generation_w && !fault_q;
	assign issue_instruction_o = selected_context_found_w ? instruction_with_operand(
		active_instruction_q[selected_context_slot_w], active_target_q[selected_context_slot_w],
		active_operand_q[selected_context_slot_w]) : '0;
	assign issue_cycle_o = selected_context_found_w ? active_next_cycle_q[selected_context_slot_w] : '0;
	// The Active Context advances only when the target Instruction Wave actually accepts the due instruction.
	assign schedule_select_fire = issue_valid_o && issue_ready_i;
	assign active_context_inner_advance_w = schedule_select_fire &&
		(active_inner_remaining_q[selected_context_slot_w] > 1);
	assign active_context_outer_advance_w = schedule_select_fire &&
		(active_inner_remaining_q[selected_context_slot_w] == 1) &&
		(active_outer_remaining_q[selected_context_slot_w] > 1);
	assign active_context_retire_w = schedule_select_fire &&
		(active_inner_remaining_q[selected_context_slot_w] == 1) &&
		(active_outer_remaining_q[selected_context_slot_w] == 1);

	// Convert schedule conflicts, missed cycles, deadline rejection and timebase jumps into sticky faults.
	always_comb begin
		dynamic_fault_w = 1'b0;
		dynamic_fault_code_w = FAULT_NONE;
		if(context_accept_fire && context_illegal_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_CONTEXT;
		end
		else if(run_i && multiple_due_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_CONFLICT;
		end
		else if(run_i && missed_generation_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_MISSED;
		end
		else if(issue_valid_o && !issue_ready_i)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_DEADLINE;
		end
		else if(run_i && run_seen_q && (schedule_cycle_i != (previous_schedule_cycle_q + 1'b1)))begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_TIMEBASE;
		end
	end

	assign conflict_o = run_i && multiple_due_w;
	assign fault_o = fault_q;
	assign fault_code_o = fault_code_q;

	// Existing Active Context Advance / Retirement and New Active Context Admission.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			for(reset_slot_index = 0; reset_slot_index < ACTIVE_CONTEXTS; reset_slot_index = reset_slot_index + 1)begin
				active_valid_q[reset_slot_index] <= 1'b0;
				active_instruction_q[reset_slot_index] <= '0;
				active_target_q[reset_slot_index] <= '0;
				active_operand_q[reset_slot_index] <= '0;
				active_outer_operand_q[reset_slot_index] <= '0;
				active_inner_count_q[reset_slot_index] <= '0;
				active_inner_remaining_q[reset_slot_index] <= '0;
				active_outer_remaining_q[reset_slot_index] <= '0;
				active_inner_interval_q[reset_slot_index] <= '0;
				active_outer_interval_q[reset_slot_index] <= '0;
				active_inner_stride_q[reset_slot_index] <= '0;
				active_outer_stride_q[reset_slot_index] <= '0;
				active_outer_start_cycle_q[reset_slot_index] <= '0;
				active_next_cycle_q[reset_slot_index] <= '0;
			end
		end
		else begin
			// Existing Active Context Advance / Retirement.
			if(active_context_inner_advance_w)begin
				active_inner_remaining_q[selected_context_slot_w] <=
					active_inner_remaining_q[selected_context_slot_w] - 1'b1;
				active_operand_q[selected_context_slot_w] <=
					active_operand_q[selected_context_slot_w] + active_inner_stride_q[selected_context_slot_w];
				active_next_cycle_q[selected_context_slot_w] <=
					active_next_cycle_q[selected_context_slot_w] + active_inner_interval_q[selected_context_slot_w];
			end
			else if(active_context_outer_advance_w)begin
				active_inner_remaining_q[selected_context_slot_w] <= active_inner_count_q[selected_context_slot_w];
				active_outer_remaining_q[selected_context_slot_w] <=
					active_outer_remaining_q[selected_context_slot_w] - 1'b1;
				active_outer_operand_q[selected_context_slot_w] <=
					active_outer_operand_q[selected_context_slot_w] + active_outer_stride_q[selected_context_slot_w];
				active_operand_q[selected_context_slot_w] <=
					active_outer_operand_q[selected_context_slot_w] + active_outer_stride_q[selected_context_slot_w];
				active_outer_start_cycle_q[selected_context_slot_w] <=
					active_outer_start_cycle_q[selected_context_slot_w] + active_outer_interval_q[selected_context_slot_w];
				active_next_cycle_q[selected_context_slot_w] <=
					active_outer_start_cycle_q[selected_context_slot_w] + active_outer_interval_q[selected_context_slot_w];
			end
			else if(active_context_retire_w)begin
				active_valid_q[selected_context_slot_w] <= 1'b0;
			end

			// New Active Context Admission. A retiring slot may be reused on the following cycle.
			if(context_admit_fire)begin
				active_valid_q[free_context_slot_w] <= 1'b1;
				active_instruction_q[free_context_slot_w] <= context_instruction_i;
				active_target_q[free_context_slot_w] <= context_induction_target_i;
				active_operand_q[free_context_slot_w] <= context_operand_i;
				active_outer_operand_q[free_context_slot_w] <= context_operand_i;
				active_inner_count_q[free_context_slot_w] <= context_inner_count_i;
				active_inner_remaining_q[free_context_slot_w] <= context_inner_count_i;
				active_outer_remaining_q[free_context_slot_w] <= context_outer_count_i;
				active_inner_interval_q[free_context_slot_w] <= context_inner_interval_i;
				active_outer_interval_q[free_context_slot_w] <= context_outer_interval_i;
				active_inner_stride_q[free_context_slot_w] <= context_inner_stride_i;
				active_outer_stride_q[free_context_slot_w] <= context_outer_stride_i;
				active_outer_start_cycle_q[free_context_slot_w] <= context_start_cycle_i;
				active_next_cycle_q[free_context_slot_w] <= context_start_cycle_i;
			end
		end
	end

	// Timebase continuity is checked only across consecutive enabled QCTL cycles.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			run_seen_q <= 1'b0;
			previous_schedule_cycle_q <= '0;
		end
		else begin
			run_seen_q <= run_i;
			if(run_i) previous_schedule_cycle_q <= schedule_cycle_i;
		end
	end

	// Faults are terminal until reset so a missed absolute issue cannot be retried silently.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else if(dynamic_fault_w)begin
			fault_q <= 1'b1;
			fault_code_q <= dynamic_fault_code_w;
		end
	end
endmodule
