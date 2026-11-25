module lpu_mem_macro_scheduler #(
	parameter integer ACTIVE_CONTEXTS = 4
) (
	input  logic        clk_i,
	input  logic        rst_ni,
	input  logic        run_i,
	input  logic        prime_i,
	input  logic [31:0] schedule_cycle_i,

	// Context FIFO Head is admitted directly into Active Context storage.
	input  logic        context_valid_i,
	output logic        context_ready_o,
	input  logic [31:0] context_instruction_i,
	input  logic [31:0] context_start_cycle_i,
	input  logic [31:0] context_inner_count_i,
	input  logic [31:0] context_inner_interval_i,
	input  logic signed [31:0] context_inner_stride_i,
	input  logic [31:0] context_outer_count_i,
	input  logic [31:0] context_outer_interval_i,
	input  logic signed [31:0] context_outer_stride_i,
	input  logic [1:0]  context_induction_target_i,
	input  logic [12:0] context_address_i,

	// The due instruction is presented directly to the MEM execution boundary.
	output logic        mem_issue_valid_o,
	input  logic        mem_issue_ready_i,
	output logic [lpu_pkg::MEM_INSTRUCTION_WIDTH-1:0] mem_issue_instruction_o,
	output logic [31:0] mem_issue_cycle_o,

	// Production observability and terminal status.
	output logic [$clog2(ACTIVE_CONTEXTS+1)-1:0] active_count_o,
	output logic        idle_o,
	output logic        prime_ready_o,
	output logic        conflict_o,
	output logic        fault_o,
	output logic [3:0]  fault_code_o
);
	localparam logic [1:0] MEM_ADDRESS_TARGET = 2'd1;
	localparam logic [31:0] MAX_CONTEXT_COUNT = 32'd65536;
	localparam logic signed [64:0] MIN_CONTEXT_STEP = -65'sd8192;
	localparam logic signed [64:0] MAX_CONTEXT_STEP = 65'sd8191;
	localparam logic signed [64:0] MIN_MEM_ADDRESS = 65'sd0;
	localparam logic signed [64:0] MAX_MEM_ADDRESS = 65'sd8191;

	localparam logic [3:0] FAULT_NONE = 4'd0;
	localparam logic [3:0] FAULT_ITERATION = 4'd1;
	localparam logic [3:0] FAULT_NATIVE = 4'd2;
	localparam logic [3:0] FAULT_TARGET = 4'd3;
	localparam logic [3:0] FAULT_ADDRESS = 4'd4;
	localparam logic [3:0] FAULT_STEP = 4'd5;
	localparam logic [3:0] FAULT_CYCLE = 4'd6;
	localparam logic [3:0] FAULT_LATE_CONTEXT = 4'd7;
	localparam logic [3:0] FAULT_MISSED_ISSUE = 4'd8;
	localparam logic [3:0] FAULT_CONFLICT = 4'd9;
	localparam logic [3:0] FAULT_COUNTER_OVERFLOW = 4'd10;
	localparam logic [3:0] FAULT_ISSUE_BACKPRESSURE = 4'd11;
	localparam logic [3:0] FAULT_TIMEBASE = 4'd13;

	// Active Context storage contains only state needed after admission-time conversion.
	logic active_valid_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_instruction_q [0:ACTIVE_CONTEXTS-1];
	logic [12:0] active_address_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_inner_count_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_inner_remaining_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_outer_remaining_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_inner_interval_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_outer_cycle_transition_q [0:ACTIVE_CONTEXTS-1];
	logic signed [13:0] active_inner_step_q [0:ACTIVE_CONTEXTS-1];
	logic signed [13:0] active_outer_spatial_transition_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_next_issue_cycle_q [0:ACTIVE_CONTEXTS-1];

	// Shared Schedule time must advance by one on every consecutive run cycle.
	logic run_seen_q;
	logic [31:0] previous_schedule_cycle_q;

	// Sticky terminal fault state.
	logic fault_q;
	logic [3:0] fault_code_q;

	// A valid Context is captured into the first free Active Context slot when no fault blocks admission.
	logic context_admit_fire;
	logic free_slot_valid_w;
	integer free_slot_index_w;

	// Admission-time cycle and spatial transition conversion.
	logic [63:0] schedule_inner_steps_w;
	logic [63:0] schedule_outer_steps_w;
	logic [64:0] schedule_inner_cycle_span_w;
	logic [64:0] schedule_outer_cycle_span_w;
	logic [64:0] schedule_final_cycle_w;
	logic [31:0] schedule_effective_inner_interval_w;
	logic signed [64:0] schedule_effective_inner_step_w;
	logic signed [64:0] schedule_inner_operand_span_w;
	logic signed [64:0] schedule_outer_spatial_transition_w;
	logic [31:0] schedule_outer_cycle_transition_w;
	logic signed [64:0] address_base_w;
	logic signed [64:0] address_inner_corner_w;
	logic signed [64:0] address_outer_corner_w;
	logic signed [64:0] address_inner_outer_corner_w;
	logic address_range_violation_w;
	logic native_instruction_illegal_w;
	logic iteration_parameters_illegal_w;
	logic step_parameters_illegal_w;
	logic cycle_range_violation_w;
	logic context_late_w;
	logic context_illegal_w;
	logic [3:0] context_fault_code_w;
	logic [32:0] context_min_start_cycle_w;

	// Current-cycle compare and selected Active Context.
	logic [31:0] mem_issue_cycle_w;
	// High when the due scan finds at least one Active Context for the current Schedule Cycle.
	logic selected_context_found_w;
	integer selected_index_w;
	integer due_count_w;
	// High when any Active Context deadline is earlier than the current Schedule Cycle.
	logic missed_generation_w;
	// High when exactly one due instruction is accepted by the MEM execution boundary without a fault.
	logic schedule_select_fire;
	// High after Issue acceptance when inner iterations remain; advances address, count and next issue cycle once.
	logic active_context_inner_advance_w;
	// High after Issue acceptance on the last inner iteration while outer rows remain; starts the next row once.
	logic active_context_outer_advance_w;
	// High after Issue acceptance on the final inner and outer iteration; releases the selected Active Context slot.
	logic active_context_retire_w;

	// Backpressure at the absolute Issue Cycle is terminal; timed work is never retried late.
	logic mem_issue_blocked_w;
	// High when a fault known before Issue transfer must suppress the current instruction.
	logic issue_precondition_fault_w;
	// Fault arbitration is explicit so the first hardware contract violation is retained.
	logic timebase_violation_w;
	// High when fault arbitration finds an input or runtime contract violation; blocks transfers and latches terminal fault state.
	logic dynamic_fault_w;
	logic [3:0] dynamic_fault_code_w;
	logic prime_mode_w;
	logic scheduler_active_w;

	initial begin
		if(ACTIVE_CONTEXTS < 1)begin
			$error("ACTIVE_CONTEXTS must be at least one");
		end
	end

	// Decoder Context carries the formal MEM low word; restore the 64-bit
	// transport container and replace only the affine bank-local row field.
	function automatic logic [lpu_pkg::MEM_INSTRUCTION_WIDTH-1:0] context_to_mem_instruction(
		input logic [31:0] native_instruction,
		input logic [12:0] address
	);
		begin
			context_to_mem_instruction = '0;
			context_to_mem_instruction[31:0] = native_instruction;
			context_to_mem_instruction[27:15] = address;
		end
	endfunction

	function automatic logic [12:0] add_mem_address_step(
		input logic [12:0] address,
		input logic signed [13:0] step
	);
		logic signed [14:0] sum;
		begin
			sum = $signed({2'b00, address}) + $signed({step[13], step});
			add_mem_address_step = sum[12:0];
		end
	endfunction

	// Unconnected legacy instances are treated as non-priming until their wrappers are migrated.
	assign prime_mode_w = (prime_i === 1'b1) && !run_i;
	assign scheduler_active_w = run_i;
	assign conflict_o = fault_q ? (fault_code_q == FAULT_CONFLICT) : (scheduler_active_w && due_count_w > 1);
	assign idle_o = active_count_o == '0;

	// Normalize iteration counts and the degenerate one-entry inner-loop parameters before admission.
	always_comb begin
		schedule_inner_steps_w = '0;
		schedule_outer_steps_w = '0;
		if(context_inner_count_i != 0)begin
			schedule_inner_steps_w = {32'd0, context_inner_count_i} - 64'd1;
		end
		if(context_outer_count_i != 0)begin
			schedule_outer_steps_w = {32'd0, context_outer_count_i} - 64'd1;
		end
		schedule_effective_inner_interval_w = (context_inner_count_i == 32'd1) ? 32'd1 : context_inner_interval_i;
		schedule_effective_inner_step_w = (context_inner_count_i == 32'd1) ? 65'sd0 : $signed(context_inner_stride_i);
	end

	// Calculate the final deadline and cycle transition from one row end to the next row start.
	always_comb begin
		schedule_inner_cycle_span_w = {1'b0, schedule_inner_steps_w} * {33'd0, schedule_effective_inner_interval_w};
		schedule_outer_cycle_span_w = {1'b0, schedule_outer_steps_w} * {33'd0, context_outer_interval_i};
		schedule_final_cycle_w = {33'd0, context_start_cycle_i} + schedule_inner_cycle_span_w + schedule_outer_cycle_span_w;
		schedule_outer_cycle_transition_w = (context_outer_count_i == 32'd1) ? 32'd1 : context_outer_interval_i - schedule_inner_cycle_span_w[31:0];
	end

	// Convert the affine inner and outer strides into per-issue address update steps.
	always_comb begin
		schedule_inner_operand_span_w = $signed({1'b0, schedule_inner_steps_w}) * schedule_effective_inner_step_w;
		schedule_outer_spatial_transition_w = (context_outer_count_i == 32'd1) ? 65'sd0 : $signed(context_outer_stride_i) - schedule_inner_operand_span_w;
	end

	// Affine address extrema occur at the four two-dimensional loop corners.
	always_comb begin
		address_base_w = $signed({52'd0, context_address_i});
		address_inner_corner_w = address_base_w + schedule_inner_operand_span_w;
		address_outer_corner_w = address_base_w + ($signed({1'b0, schedule_outer_steps_w}) * $signed(context_outer_stride_i));
		address_inner_outer_corner_w = address_inner_corner_w + ($signed({1'b0, schedule_outer_steps_w}) * $signed(context_outer_stride_i));
		address_range_violation_w = (address_base_w < MIN_MEM_ADDRESS) || (address_base_w > MAX_MEM_ADDRESS) ||
			(address_inner_corner_w < MIN_MEM_ADDRESS) || (address_inner_corner_w > MAX_MEM_ADDRESS) ||
			(address_outer_corner_w < MIN_MEM_ADDRESS) || (address_outer_corner_w > MAX_MEM_ADDRESS) ||
			(address_inner_outer_corner_w < MIN_MEM_ADDRESS) || (address_inner_outer_corner_w > MAX_MEM_ADDRESS);
	end

	// Validate the restored native MEM instruction and its address field before admission.
	always_comb begin
		native_instruction_illegal_w = (context_instruction_i[30:28] != 3'd0) ||
			!((context_instruction_i[2:0] == 3'd0) || (context_instruction_i[2:0] == 3'd1) ||
			(context_instruction_i[2:0] == 3'd3) || (context_instruction_i[2:0] == 3'd4)) ||
			(context_instruction_i[31] && (context_instruction_i[2:0] != 3'd1)) ||
			(context_instruction_i[27:15] != context_address_i);
	end

	// Validate loop counts, intervals and the representable final absolute issue cycle.
	always_comb begin
		iteration_parameters_illegal_w = (context_inner_count_i == 0) || (context_inner_count_i > MAX_CONTEXT_COUNT) ||
			(context_outer_count_i == 0) || (context_outer_count_i > MAX_CONTEXT_COUNT) ||
			(context_inner_interval_i == 0) || (context_outer_interval_i == 0) ||
			((context_outer_count_i > 1) && ({33'd0, context_outer_interval_i} <= schedule_inner_cycle_span_w));
		cycle_range_violation_w = schedule_final_cycle_w[64:32] != 0;
	end

	// Validate the converted inner step and row transition against Active Context storage widths.
	always_comb begin
		step_parameters_illegal_w = (schedule_effective_inner_step_w < MIN_CONTEXT_STEP) || (schedule_effective_inner_step_w > MAX_CONTEXT_STEP) ||
			(schedule_outer_spatial_transition_w < MIN_CONTEXT_STEP) || (schedule_outer_spatial_transition_w > MAX_CONTEXT_STEP);
	end

	// A runtime Context admitted on this edge becomes selectable on the next Schedule Cycle.
	always_comb begin
		context_min_start_cycle_w = {1'b0, schedule_cycle_i} + 1'b1;
		context_late_w = run_i && (context_min_start_cycle_w[32] || ({1'b0, context_start_cycle_i} < context_min_start_cycle_w));
	end

	// Select the highest-priority admission fault without changing the established fault-code ordering.
	always_comb begin
		context_illegal_w = 1'b0;
		context_fault_code_w = FAULT_NONE;
		if(context_induction_target_i != MEM_ADDRESS_TARGET)begin
			context_illegal_w = 1'b1;
			context_fault_code_w = FAULT_TARGET;
		end
		else if(native_instruction_illegal_w)begin
			context_illegal_w = 1'b1;
			context_fault_code_w = FAULT_NATIVE;
		end
		else if(iteration_parameters_illegal_w)begin
			context_illegal_w = 1'b1;
			context_fault_code_w = FAULT_ITERATION;
		end
		else if(step_parameters_illegal_w)begin
			context_illegal_w = 1'b1;
			context_fault_code_w = FAULT_STEP;
		end
		else if(address_range_violation_w)begin
			context_illegal_w = 1'b1;
			context_fault_code_w = FAULT_ADDRESS;
		end
		else if(cycle_range_violation_w)begin
			context_illegal_w = 1'b1;
			context_fault_code_w = FAULT_CYCLE;
		end
		else if(context_late_w)begin
			context_illegal_w = 1'b1;
			context_fault_code_w = FAULT_LATE_CONTEXT;
		end
	end

	// The first free Active Context slot accepts the next validated Context.
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

	// Without a downstream timed queue, the Scheduler owns the final absolute Issue Cycle.
	assign mem_issue_cycle_w = schedule_cycle_i;

	// Count occupied Active Context slots independently from deadline selection.
	always_comb begin
		active_count_o = '0;
		for(integer slot = 0; slot < ACTIVE_CONTEXTS; slot = slot + 1)begin
			if(active_valid_q[slot])begin
				active_count_o = active_count_o + 1'b1;
			end
		end
	end

	// Select the first Context due now and detect conflicts or missed deadlines.
	always_comb begin
		selected_context_found_w = 1'b0;
		selected_index_w = 0;
		due_count_w = 0;
		missed_generation_w = 1'b0;
		for(integer slot = 0; slot < ACTIVE_CONTEXTS; slot = slot + 1)begin
			if(active_valid_q[slot])begin
				if(active_next_issue_cycle_q[slot] < mem_issue_cycle_w)begin
					missed_generation_w = 1'b1;
				end
				else if(active_next_issue_cycle_q[slot] == mem_issue_cycle_w)begin
					if(!selected_context_found_w)begin
						selected_context_found_w = 1'b1;
						selected_index_w = slot;
					end
					due_count_w = due_count_w + 1;
				end
			end
		end
	end

	// Pre-transfer faults suppress Issue so the execution boundary cannot accept uncommitted work.
	assign issue_precondition_fault_w = timebase_violation_w ||
		(scheduler_active_w && due_count_w > 1) ||
		(scheduler_active_w && missed_generation_w) ||
		(context_valid_i && context_illegal_w) ||
		(run_i && schedule_cycle_i == 32'hffff_ffff);

	// The Scheduler presents the instruction only on its absolute Issue Cycle.
	assign mem_issue_valid_o = scheduler_active_w && selected_context_found_w && (due_count_w == 1) &&
		!fault_q && !issue_precondition_fault_w;
	assign mem_issue_instruction_o = selected_context_found_w ?
		context_to_mem_instruction(active_instruction_q[selected_index_w], active_address_q[selected_index_w]) : '0;
	assign mem_issue_cycle_o = selected_context_found_w ? mem_issue_cycle_w : '0;
	assign mem_issue_blocked_w = mem_issue_valid_o && !mem_issue_ready_i;
	assign timebase_violation_w = run_i && run_seen_q &&
		((previous_schedule_cycle_q == 32'hffff_ffff) || (schedule_cycle_i != previous_schedule_cycle_q + 1'b1));

	// Deadline and timebase violations have priority over future scheduling work.
	always_comb begin
		dynamic_fault_w = 1'b0;
		dynamic_fault_code_w = FAULT_NONE;
		if(timebase_violation_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_TIMEBASE;
		end
		else if(mem_issue_blocked_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_ISSUE_BACKPRESSURE;
		end
		else if(scheduler_active_w && due_count_w > 1)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_CONFLICT;
		end
		else if(scheduler_active_w && missed_generation_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_MISSED_ISSUE;
		end
		else if(context_valid_i && context_illegal_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = context_fault_code_w;
		end
		else if(run_i && schedule_cycle_i == 32'hffff_ffff)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_COUNTER_OVERFLOW;
		end
	end

	assign context_ready_o = free_slot_valid_w && !fault_q && !dynamic_fault_w;
	assign context_admit_fire = context_valid_i && context_ready_o;
	assign schedule_select_fire = mem_issue_valid_o && mem_issue_ready_i && !dynamic_fault_w;
	assign active_context_inner_advance_w = schedule_select_fire &&
		(active_inner_remaining_q[selected_index_w] > 32'd1);
	assign active_context_outer_advance_w = schedule_select_fire &&
		(active_inner_remaining_q[selected_index_w] <= 32'd1) &&
		(active_outer_remaining_q[selected_index_w] > 32'd1);
	assign active_context_retire_w = schedule_select_fire &&
		(active_inner_remaining_q[selected_index_w] <= 32'd1) &&
		(active_outer_remaining_q[selected_index_w] <= 32'd1);
	// PRIME completes once every decoded Context has entered Active Context storage.
	// Instructions remain untouched until run_i asserts, including Cycle 0 work.
	assign prime_ready_o = prime_mode_w && !context_valid_i && !fault_q && !dynamic_fault_w;
	assign fault_o = fault_q || dynamic_fault_w;
	assign fault_code_o = fault_q ? fault_code_q : dynamic_fault_code_w;

	// Active Context state advances atomically on Issue acceptance, while admission uses a free slot.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			for(integer slot = 0; slot < ACTIVE_CONTEXTS; slot = slot + 1)begin
				active_valid_q[slot] <= 1'b0;
			end
		end
		else begin
			// Existing Active Context Advance / Retirement
			if(active_context_inner_advance_w)begin
				active_inner_remaining_q[selected_index_w] <= active_inner_remaining_q[selected_index_w] - 1'b1;
				active_next_issue_cycle_q[selected_index_w] <= active_next_issue_cycle_q[selected_index_w] + active_inner_interval_q[selected_index_w];
				active_address_q[selected_index_w] <= add_mem_address_step(active_address_q[selected_index_w], active_inner_step_q[selected_index_w]);
			end
			else if(active_context_outer_advance_w)begin
				active_outer_remaining_q[selected_index_w] <= active_outer_remaining_q[selected_index_w] - 1'b1;
				active_inner_remaining_q[selected_index_w] <= active_inner_count_q[selected_index_w];
				active_next_issue_cycle_q[selected_index_w] <= active_next_issue_cycle_q[selected_index_w] + active_outer_cycle_transition_q[selected_index_w];
				active_address_q[selected_index_w] <= add_mem_address_step(active_address_q[selected_index_w], active_outer_spatial_transition_q[selected_index_w]);
			end
			else if(active_context_retire_w)begin
				active_valid_q[selected_index_w] <= 1'b0;
			end

			// New Active Context Admission
			if(context_admit_fire)begin
				active_valid_q[free_slot_index_w] <= 1'b1;
				active_instruction_q[free_slot_index_w] <= context_instruction_i;
				active_address_q[free_slot_index_w] <= context_address_i;
				active_inner_count_q[free_slot_index_w] <= context_inner_count_i;
				active_inner_remaining_q[free_slot_index_w] <= context_inner_count_i;
				active_outer_remaining_q[free_slot_index_w] <= context_outer_count_i;
				active_inner_interval_q[free_slot_index_w] <= schedule_effective_inner_interval_w;
				active_outer_cycle_transition_q[free_slot_index_w] <= schedule_outer_cycle_transition_w;
				active_inner_step_q[free_slot_index_w] <= schedule_effective_inner_step_w[13:0];
				active_outer_spatial_transition_q[free_slot_index_w] <= schedule_outer_spatial_transition_w[13:0];
				active_next_issue_cycle_q[free_slot_index_w] <= context_start_cycle_i;
			end
		end
	end

	// Timebase continuity is checked only across consecutive run cycles.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			run_seen_q <= 1'b0;
			previous_schedule_cycle_q <= '0;
		end
		else begin
			if(run_i)begin
				run_seen_q <= 1'b1;
				previous_schedule_cycle_q <= schedule_cycle_i;
			end
			else begin
				run_seen_q <= 1'b0;
			end
		end
	end

	// Fault remains sticky until reset so no later traffic can hide a missed absolute deadline.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else begin
			if(!fault_q && dynamic_fault_w)begin
				fault_q <= 1'b1;
				fault_code_q <= dynamic_fault_code_w;
			end
		end
	end
endmodule
