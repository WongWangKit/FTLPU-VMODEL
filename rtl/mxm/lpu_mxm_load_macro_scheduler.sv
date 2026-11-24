module lpu_mxm_load_macro_scheduler #(
	parameter integer ACTIVE_CONTEXTS = 4,
    parameter integer WEIGHT_BLOCKS = 4,
	// Compatibility parameter; base instructions are stored only in the FU-local Timed Queue.
	parameter integer ISSUE_FIFO_DEPTH = 4,
	parameter integer ISSUE_LOOKAHEAD = 2
) (
	input  logic        clk_i,
	input  logic        rst_ni,
	input  logic        run_i,
	input  logic        prime_i,
	input  logic        prime_tail_i,
	input  logic [31:0] schedule_cycle_i,

	input  logic        context_valid_i,
	output logic        context_ready_o,
	input  logic [28:0] context_instruction_i,
	input  logic [31:0] context_start_cycle_i,
	input  logic [31:0] context_inner_count_i,
	input  logic [31:0] context_inner_interval_i,
	input  logic signed [31:0] context_inner_stride_i,
	input  logic [31:0] context_outer_count_i,
	input  logic [31:0] context_outer_interval_i,
	input  logic signed [31:0] context_outer_stride_i,
	input  logic [1:0]  context_induction_target_i,
	input  logic [1:0]  context_operand_i,

	output logic        issue_valid_o,
	input  logic        issue_ready_i,
	output logic [28:0] issue_instruction_o,
	output logic [31:0] issue_cycle_o,

	output logic [$clog2(ACTIVE_CONTEXTS+1)-1:0] active_count_o,
	output logic [$clog2(ISSUE_FIFO_DEPTH+1)-1:0] issue_fifo_level_o,
	output logic        idle_o,
	output logic        prime_ready_o,
	output logic        prime_blocked_o,
	output logic        prime_stream_o,
	output logic        conflict_o,
	output logic        fault_o,
	output logic [3:0]  fault_code_o
);
	localparam logic [1:0] TARGET_NONE = 2'd0;
	localparam logic [1:0] TARGET_WEIGHT_COLUMN = 2'd2;
	localparam logic [3:0] FAULT_NONE = 4'd0;
	localparam logic [3:0] FAULT_CONTEXT = 4'd1;
	localparam logic [3:0] FAULT_OPERAND = 4'd2;
	localparam logic [3:0] FAULT_LATE = 4'd3;
	localparam logic [3:0] FAULT_MISSED = 4'd4;
	localparam logic [3:0] FAULT_CONFLICT = 4'd5;
	localparam logic [3:0] FAULT_TIMED_QUEUE = 4'd6;
	localparam logic [3:0] FAULT_TIMEBASE = 4'd8;
	localparam logic [3:0] FAULT_OVERFLOW = 4'd9;

	// One-entry ingress keeps Decoder output stable while validation and slot allocation complete.
	logic ingress_valid_q;
	logic [28:0] ingress_instruction_q;
	logic [31:0] ingress_start_cycle_q;
	logic [31:0] ingress_inner_count_q;
	logic [31:0] ingress_inner_interval_q;
	logic signed [31:0] ingress_inner_stride_q;
	logic [31:0] ingress_outer_count_q;
	logic [31:0] ingress_outer_interval_q;
	logic signed [31:0] ingress_outer_stride_q;
	logic [1:0] ingress_induction_target_q;
	logic [1:0] ingress_operand_q;

	// Active slots retain the immutable Load template and current induced Weight Column.
	logic active_valid_q [0:ACTIVE_CONTEXTS-1];
	logic [28:0] active_instruction_q [0:ACTIVE_CONTEXTS-1];
	logic [4:0] active_operand_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_inner_count_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_inner_remaining_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_outer_remaining_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_inner_interval_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_outer_residual_q [0:ACTIVE_CONTEXTS-1];
	logic signed [5:0] active_inner_step_q [0:ACTIVE_CONTEXTS-1];
	logic signed [5:0] active_row_transition_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_next_cycle_q [0:ACTIVE_CONTEXTS-1];

	logic context_fire;
	logic ingress_admit_fire;
	logic free_slot_valid_w;
	integer free_slot_index_w;
	logic [63:0] inner_steps_w;
	logic [63:0] outer_steps_w;
	logic [64:0] inner_cycle_span_w;
	logic [64:0] final_cycle_w;
	logic [31:0] effective_inner_interval_w;
	logic signed [64:0] effective_inner_step_w;
	logic signed [64:0] inner_operand_span_w;
	logic signed [64:0] row_transition_w;
	logic [31:0] outer_residual_w;
	logic signed [64:0] operand_corner_w [0:3];
	logic context_invalid_w;
	logic operand_invalid_w;
    // The physical dictionary stores the block. Vector IW induction spans
    // (block, inner lane), while full-block IW walks blocks only.
    wire linear_iw_w=(ingress_instruction_q[1:0]==0 && ingress_instruction_q[5]);
    wire [4:0] first_column_w=linear_iw_w ?
        {ingress_operand_q,ingress_instruction_q[8:6]} : {3'b0,ingress_operand_q};
    wire signed [64:0] column_limit_w=linear_iw_w ? 65'(WEIGHT_BLOCKS*8-1) : 65'(WEIGHT_BLOCKS-1);
	logic ingress_late_w;
	logic [32:0] ingress_min_start_w;

	logic [32:0] lookahead_sum_w;
	logic [31:0] lookahead_cycle_w;
	logic selected_valid_w;
	integer selected_index_w;
	integer due_count_w;
	logic missed_generation_w;
	logic schedule_select_fire;
	logic [28:0] selected_instruction_w;

	logic timed_queue_blocked_w;
	logic timebase_invalid_w;
	logic run_seen_q;
	logic [31:0] previous_cycle_q;
	logic dynamic_fault_w;
	logic [3:0] dynamic_fault_code_w;
	logic fault_q;
	logic [3:0] fault_code_q;
	logic prime_mode_w;
	logic scheduler_active_w;

	initial begin
		if(ACTIVE_CONTEXTS < 1)begin
			$error("ACTIVE_CONTEXTS must be at least one");
		end
		if(ISSUE_FIFO_DEPTH < 1)begin
			$error("ISSUE_FIFO_DEPTH must be at least one");
		end
		if(ISSUE_LOOKAHEAD < 2)begin
			$error("ISSUE_LOOKAHEAD must cover Timed Queue write and deadline Issue stages");
		end
	end

	function automatic [28:0] apply_weight_column(input logic [28:0] instruction, input logic [4:0] operand);
		apply_weight_column = instruction;
		if(instruction[1:0] == 2'd0)begin
			if (instruction[5]) begin
                apply_weight_column[4:3] = operand[4:3];
                apply_weight_column[8:6] = operand[2:0];
            end else apply_weight_column[4:3] = operand[1:0];
		end
	endfunction

	assign context_fire = context_valid_i && context_ready_o;
	assign prime_mode_w = (prime_i === 1'b1) && !run_i;
	assign scheduler_active_w = run_i || prime_mode_w;
	assign issue_valid_o = scheduler_active_w && selected_valid_w && (due_count_w == 1) &&
		!missed_generation_w && !fault_q;
	assign issue_instruction_o = selected_instruction_w;
	assign issue_cycle_o = selected_valid_w ? lookahead_cycle_w : '0;
	assign issue_fifo_level_o = '0;
	assign timed_queue_blocked_w = issue_valid_o && !issue_ready_i;
	assign idle_o = !ingress_valid_q && (active_count_o == '0);
	assign conflict_o = fault_q ? (fault_code_q == FAULT_CONFLICT) : (scheduler_active_w && (due_count_w > 1));

	// Count, interval and stride fields are converted once at admission.
	always_comb begin
		inner_steps_w = ingress_inner_count_q == 0 ? 64'd0 : ({32'd0, ingress_inner_count_q} - 64'd1);
		outer_steps_w = ingress_outer_count_q == 0 ? 64'd0 : ({32'd0, ingress_outer_count_q} - 64'd1);
		effective_inner_interval_w = ingress_inner_count_q == 1 ? 32'd1 : ingress_inner_interval_q;
		effective_inner_step_w = ingress_inner_count_q == 1 ? 65'sd0 : $signed(ingress_inner_stride_q);
		inner_cycle_span_w = {1'b0, inner_steps_w} * {33'd0, effective_inner_interval_w};
		final_cycle_w = {33'd0, ingress_start_cycle_q} + inner_cycle_span_w +
			({1'b0, outer_steps_w} * {33'd0, ingress_outer_interval_q});
		inner_operand_span_w = $signed({1'b0, inner_steps_w}) * effective_inner_step_w;
		row_transition_w = ingress_outer_count_q == 1 ? 65'sd0 :
			$signed(ingress_outer_stride_q) - inner_operand_span_w;
		outer_residual_w = ingress_outer_count_q == 1 ? 32'd1 :
			ingress_outer_interval_q - inner_cycle_span_w[31:0];
	end

	// Four affine corners prove that every generated Weight Column remains in [0,3].
	always_comb begin
		operand_corner_w[0] = $signed({60'd0, first_column_w});
		operand_corner_w[1] = operand_corner_w[0] + inner_operand_span_w;
		operand_corner_w[2] = operand_corner_w[0] +
			($signed({1'b0, outer_steps_w}) * $signed(ingress_outer_stride_q));
		operand_corner_w[3] = operand_corner_w[1] +
			($signed({1'b0, outer_steps_w}) * $signed(ingress_outer_stride_q));
		operand_invalid_w = (operand_corner_w[0] < 0) || (operand_corner_w[0] > column_limit_w) ||
			(operand_corner_w[1] < 0) || (operand_corner_w[1] > column_limit_w) ||
			(operand_corner_w[2] < 0) || (operand_corner_w[2] > column_limit_w) ||
			(operand_corner_w[3] < 0) || (operand_corner_w[3] > column_limit_w);
	end

	// Runtime admission reserves enough lead for admission, Select and Issue FIFO visibility.
	always_comb begin
		ingress_min_start_w = {1'b0, schedule_cycle_i} + ISSUE_LOOKAHEAD + 1;
		ingress_late_w = run_i && (ingress_min_start_w[32] ||
			({1'b0, ingress_start_cycle_q} < ingress_min_start_w));
		context_invalid_w = (ingress_inner_count_q == 0) || (ingress_outer_count_q == 0) ||
			(ingress_inner_interval_q == 0) || (ingress_outer_interval_q == 0) ||
			((ingress_outer_count_q > 1) && ({33'd0, ingress_outer_interval_q} <= inner_cycle_span_w)) ||
			(final_cycle_w[64:32] != 0) ||
			((ingress_induction_target_q != TARGET_NONE) &&
			(ingress_induction_target_q != TARGET_WEIGHT_COLUMN)) ||
			((ingress_induction_target_q == TARGET_NONE) &&
			((ingress_inner_stride_q != 0) || (ingress_outer_stride_q != 0))) ||
			(effective_inner_step_w < -column_limit_w) || (effective_inner_step_w > column_limit_w) ||
			(row_transition_w < -column_limit_w) || (row_transition_w > column_limit_w);
	end

	// The lowest invalid slot wins Context admission.
	always_comb begin
		free_slot_valid_w = 1'b0;
		free_slot_index_w = 0;
		for(integer slot = 0; slot < ACTIVE_CONTEXTS; slot = slot + 1)begin
			if(!free_slot_valid_w && !active_valid_q[slot])begin
				free_slot_valid_w = 1'b1;
				free_slot_index_w = slot;
			end
		end
	end

	// Active Contexts are scanned ISSUE_LOOKAHEAD cycles before their absolute deadline.
	always_comb begin
		lookahead_sum_w = prime_mode_w ? {32'd0, (prime_tail_i === 1'b1)} :
			({1'b0, schedule_cycle_i} + ISSUE_LOOKAHEAD);
		lookahead_cycle_w = lookahead_sum_w[31:0];
		selected_valid_w = 1'b0;
		selected_index_w = 0;
		due_count_w = 0;
		missed_generation_w = 1'b0;
		active_count_o = '0;
		for(integer slot = 0; slot < ACTIVE_CONTEXTS; slot = slot + 1)begin
			if(active_valid_q[slot])begin
				active_count_o = active_count_o + 1'b1;
				if(active_next_cycle_q[slot] < lookahead_cycle_w)begin
					missed_generation_w = 1'b1;
				end
				else if(active_next_cycle_q[slot] == lookahead_cycle_w)begin
					due_count_w = due_count_w + 1;
					if(!selected_valid_w)begin
						selected_valid_w = 1'b1;
						selected_index_w = slot;
					end
				end
			end
		end
	end

	assign selected_instruction_w = selected_valid_w ?
		apply_weight_column(active_instruction_q[selected_index_w], active_operand_q[selected_index_w]) : '0;
	assign schedule_select_fire = issue_valid_o && issue_ready_i && !dynamic_fault_w;
	assign ingress_admit_fire = ingress_valid_q && free_slot_valid_w && !context_invalid_w &&
		!operand_invalid_w && !ingress_late_w && !fault_q && !dynamic_fault_w;
	assign timebase_invalid_w = run_i && run_seen_q &&
		((previous_cycle_q == 32'hffff_ffff) || (schedule_cycle_i != previous_cycle_q + 1'b1));

	// Deadline violations are terminal; the Schedule clock never pauses for Issue backpressure.
	always_comb begin
		dynamic_fault_w = 1'b0;
		dynamic_fault_code_w = FAULT_NONE;
		if(timebase_invalid_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_TIMEBASE;
		end
		else if(run_i && lookahead_sum_w[32])begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_OVERFLOW;
		end
		else if(timed_queue_blocked_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_TIMED_QUEUE;
		end
		else if(scheduler_active_w && due_count_w > 1)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_CONFLICT;
		end
		else if(scheduler_active_w && missed_generation_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_MISSED;
		end
		else if(ingress_valid_q && free_slot_valid_w && context_invalid_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_CONTEXT;
		end
		else if(ingress_valid_q && free_slot_valid_w && operand_invalid_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_OPERAND;
		end
		else if(ingress_valid_q && free_slot_valid_w && ingress_late_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_LATE;
		end
	end

	assign context_ready_o = !ingress_valid_q && !fault_q && !dynamic_fault_w;
	assign prime_ready_o = prime_mode_w && !ingress_valid_q &&
		(due_count_w == 0) && !fault_q && !dynamic_fault_w;
	assign prime_blocked_o = prime_mode_w && ingress_valid_q && !free_slot_valid_w &&
		(due_count_w == 0) && !fault_q && !dynamic_fault_w;
	assign prime_stream_o = prime_mode_w && ingress_valid_q &&
		(ingress_start_cycle_q >= ISSUE_LOOKAHEAD + 2) &&
		(due_count_w == 0) && !fault_q && !dynamic_fault_w;
	assign fault_o = fault_q || dynamic_fault_w;
	assign fault_code_o = fault_q ? fault_code_q : dynamic_fault_code_w;

	// Context input ownership transfers to the ingress slot on valid/ready.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			ingress_valid_q <= 1'b0;
		end
		else begin
			if(ingress_admit_fire)begin
				ingress_valid_q <= 1'b0;
			end
			else if(context_fire)begin
				ingress_valid_q <= 1'b1;
				ingress_instruction_q <= context_instruction_i;
				ingress_start_cycle_q <= context_start_cycle_i;
				ingress_inner_count_q <= context_inner_count_i;
				ingress_inner_interval_q <= context_inner_interval_i;
				ingress_inner_stride_q <= context_inner_stride_i;
				ingress_outer_count_q <= context_outer_count_i;
				ingress_outer_interval_q <= context_outer_interval_i;
				ingress_outer_stride_q <= context_outer_stride_i;
				ingress_induction_target_q <= context_induction_target_i;
				ingress_operand_q <= context_operand_i;
			end
		end
	end

	// Selected Context state advances only when the FU-local Timed Queue accepts the instruction.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			for(integer slot = 0; slot < ACTIVE_CONTEXTS; slot = slot + 1)begin
				active_valid_q[slot] <= 1'b0;
			end
		end
		else begin
			if(schedule_select_fire)begin
				if(active_inner_remaining_q[selected_index_w] > 1)begin
					active_inner_remaining_q[selected_index_w] <= active_inner_remaining_q[selected_index_w] - 1'b1;
					active_operand_q[selected_index_w] <= active_operand_q[selected_index_w] + active_inner_step_q[selected_index_w];
					active_next_cycle_q[selected_index_w] <= active_next_cycle_q[selected_index_w] +
						active_inner_interval_q[selected_index_w];
				end
				else if(active_outer_remaining_q[selected_index_w] > 1)begin
					active_inner_remaining_q[selected_index_w] <= active_inner_count_q[selected_index_w];
					active_outer_remaining_q[selected_index_w] <= active_outer_remaining_q[selected_index_w] - 1'b1;
					active_operand_q[selected_index_w] <= active_operand_q[selected_index_w] +
						active_row_transition_q[selected_index_w];
					active_next_cycle_q[selected_index_w] <= active_next_cycle_q[selected_index_w] +
						active_outer_residual_q[selected_index_w];
				end
				else begin
					active_valid_q[selected_index_w] <= 1'b0;
				end
			end
			if(ingress_admit_fire)begin
				active_valid_q[free_slot_index_w] <= 1'b1;
				active_instruction_q[free_slot_index_w] <= ingress_instruction_q;
				active_operand_q[free_slot_index_w] <= first_column_w;
				active_inner_count_q[free_slot_index_w] <= ingress_inner_count_q;
				active_inner_remaining_q[free_slot_index_w] <= ingress_inner_count_q;
				active_outer_remaining_q[free_slot_index_w] <= ingress_outer_count_q;
				active_inner_interval_q[free_slot_index_w] <= effective_inner_interval_w;
				active_outer_residual_q[free_slot_index_w] <= outer_residual_w;
				active_inner_step_q[free_slot_index_w] <= effective_inner_step_w[5:0];
				active_row_transition_q[free_slot_index_w] <= row_transition_w[5:0];
				active_next_cycle_q[free_slot_index_w] <= ingress_start_cycle_q;
			end
		end
	end

	// Timebase continuity is checked only across consecutive run cycles.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			run_seen_q <= 1'b0;
			previous_cycle_q <= '0;
		end
		else if(run_i)begin
			run_seen_q <= 1'b1;
			previous_cycle_q <= schedule_cycle_i;
		end
		else begin
			run_seen_q <= 1'b0;
		end
	end

	// First contract violation is retained until reset.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else if(!fault_q && dynamic_fault_w)begin
			fault_q <= 1'b1;
			fault_code_q <= dynamic_fault_code_w;
		end
	end
endmodule
