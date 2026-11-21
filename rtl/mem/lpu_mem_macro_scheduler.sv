module lpu_mem_macro_scheduler #(
	parameter integer ACTIVE_CONTEXTS = 4,
	// Kept for interface compatibility. The Scheduler no longer owns an Issue FIFO.
	parameter integer ISSUE_FIFO_DEPTH = 4,
	parameter integer ISSUE_LOOKAHEAD = 2
) (
	input  logic        clk_i,
	input  logic        rst_ni,
	input  logic        run_i,
	input  logic        prime_i,
	input  logic        prime_tail_i,
	input  logic [31:0] schedule_cycle_i,

	// Decoder Context input. A one-entry ingress slot isolates validation from the Decoder.
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

	// Look-ahead output is accepted directly by the FU-local Timed Queue.
	output logic        issue_valid_o,
	input  logic        issue_ready_i,
	output logic [lpu_pkg::MEM_INSTRUCTION_WIDTH-1:0] issue_instruction_o,
	output logic [31:0] issue_cycle_o,

	// Production observability and terminal status.
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
	localparam logic [3:0] FAULT_TIMED_QUEUE_BACKPRESSURE = 4'd11;
	localparam logic [3:0] FAULT_TIMEBASE = 4'd13;
	localparam logic [3:0] FAULT_LOOKAHEAD = 4'd14;

	// Ingress Context slot. Data remains stable until validation and Active Context admission finish.
	logic ingress_valid_q;
	logic [31:0] ingress_instruction_q;
	logic [31:0] ingress_start_cycle_q;
	logic [31:0] ingress_inner_count_q;
	logic [31:0] ingress_inner_interval_q;
	logic signed [31:0] ingress_inner_stride_q;
	logic [31:0] ingress_outer_count_q;
	logic [31:0] ingress_outer_interval_q;
	logic signed [31:0] ingress_outer_stride_q;
	logic [1:0] ingress_induction_target_q;
	logic [12:0] ingress_address_q;

	// Active Context storage contains only state needed after admission-time conversion.
	logic active_valid_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_instruction_q [0:ACTIVE_CONTEXTS-1];
	logic [12:0] active_address_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_inner_count_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_inner_remaining_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_outer_remaining_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_inner_interval_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_outer_residual_q [0:ACTIVE_CONTEXTS-1];
	logic signed [13:0] active_inner_step_q [0:ACTIVE_CONTEXTS-1];
	logic signed [13:0] active_row_transition_q [0:ACTIVE_CONTEXTS-1];
	logic [31:0] active_next_issue_cycle_q [0:ACTIVE_CONTEXTS-1];

	// Shared Schedule time must advance by one on every consecutive run cycle.
	logic run_seen_q;
	logic [31:0] previous_schedule_cycle_q;

	// Sticky terminal fault state.
	logic fault_q;
	logic [3:0] fault_code_q;

	// Input and storage control.
	logic context_fire;
	logic ingress_admit_fire;
	logic free_slot_valid_w;
	integer free_slot_index_w;

	// Admission-time residual conversion and validation.
	logic [63:0] schedule_inner_steps_w;
	logic [63:0] schedule_outer_steps_w;
	logic [64:0] schedule_inner_cycle_span_w;
	logic [64:0] schedule_outer_cycle_span_w;
	logic [64:0] schedule_final_cycle_w;
	logic [31:0] schedule_effective_inner_interval_w;
	logic signed [64:0] schedule_effective_inner_step_w;
	logic signed [64:0] schedule_inner_operand_span_w;
	logic signed [64:0] schedule_row_transition_w;
	logic [31:0] schedule_outer_residual_w;
	logic signed [64:0] address_base_w;
	logic signed [64:0] address_inner_corner_w;
	logic signed [64:0] address_outer_corner_w;
	logic signed [64:0] address_inner_outer_corner_w;
	logic address_range_invalid_w;
	logic native_invalid_w;
	logic iteration_invalid_w;
	logic step_invalid_w;
	logic cycle_invalid_w;
	logic ingress_late_w;
	logic ingress_context_invalid_w;
	logic [3:0] ingress_context_fault_code_w;
	logic [32:0] ingress_min_start_cycle_w;

	// Lookahead compare and selected Active Context.
	logic [32:0] lookahead_cycle_sum_w;
	logic [31:0] lookahead_cycle_w;
	logic lookahead_overflow_w;
	logic selected_valid_w;
	integer selected_index_w;
	integer due_count_w;
	logic missed_generation_w;
	logic schedule_select_fire;

	// Timed Queue handoff. Backpressure at the look-ahead cycle is terminal.
	logic timed_queue_blocked_w;
	logic ingress_capacity_deadline_w;

	// Fault arbitration is explicit so the first hardware contract violation is retained.
	logic timebase_invalid_w;
	logic dynamic_fault_w;
	logic [3:0] dynamic_fault_code_w;
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

	// Decoder Context carries the formal MEM low word; use the native 32-bit
	// command and replace only the affine bank-local row field.
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

	assign context_fire = context_valid_i && context_ready_o;
	// Compatibility status: zero confirms that no base instruction is retained inside the Scheduler.
	assign issue_fifo_level_o = '0;
	// Unconnected legacy instances are treated as non-priming until their wrappers are migrated.
	assign prime_mode_w = (prime_i === 1'b1) && !run_i;
	assign scheduler_active_w = run_i || prime_mode_w;
	assign conflict_o = fault_q ? (fault_code_q == FAULT_CONFLICT) : (scheduler_active_w && due_count_w > 1);
	assign idle_o = !ingress_valid_q && (active_count_o == '0);

	// Convert Count/Interval/Stride once before the Context enters active storage.
	always_comb begin
		schedule_inner_steps_w = '0;
		schedule_outer_steps_w = '0;
		if(ingress_inner_count_q != 0)begin
			schedule_inner_steps_w = {32'd0, ingress_inner_count_q} - 64'd1;
		end
		if(ingress_outer_count_q != 0)begin
			schedule_outer_steps_w = {32'd0, ingress_outer_count_q} - 64'd1;
		end
		schedule_effective_inner_interval_w = (ingress_inner_count_q == 32'd1) ? 32'd1 : ingress_inner_interval_q;
		schedule_effective_inner_step_w = (ingress_inner_count_q == 32'd1) ? 65'sd0 : $signed(ingress_inner_stride_q);
		schedule_inner_cycle_span_w = {1'b0, schedule_inner_steps_w} * {33'd0, schedule_effective_inner_interval_w};
		schedule_outer_cycle_span_w = {1'b0, schedule_outer_steps_w} * {33'd0, ingress_outer_interval_q};
		schedule_final_cycle_w = {33'd0, ingress_start_cycle_q} + schedule_inner_cycle_span_w + schedule_outer_cycle_span_w;
		schedule_inner_operand_span_w = $signed({1'b0, schedule_inner_steps_w}) * schedule_effective_inner_step_w;
		schedule_row_transition_w = (ingress_outer_count_q == 32'd1) ? 65'sd0 : $signed(ingress_outer_stride_q) - schedule_inner_operand_span_w;
		schedule_outer_residual_w = (ingress_outer_count_q == 32'd1) ? 32'd1 : ingress_outer_interval_q - schedule_inner_cycle_span_w[31:0];
	end

	// Affine address extrema occur at the four two-dimensional loop corners.
	always_comb begin
		address_base_w = $signed({52'd0, ingress_address_q});
		address_inner_corner_w = address_base_w + schedule_inner_operand_span_w;
		address_outer_corner_w = address_base_w + ($signed({1'b0, schedule_outer_steps_w}) * $signed(ingress_outer_stride_q));
		address_inner_outer_corner_w = address_inner_corner_w + ($signed({1'b0, schedule_outer_steps_w}) * $signed(ingress_outer_stride_q));
		address_range_invalid_w = (address_base_w < MIN_MEM_ADDRESS) || (address_base_w > MAX_MEM_ADDRESS) ||
			(address_inner_corner_w < MIN_MEM_ADDRESS) || (address_inner_corner_w > MAX_MEM_ADDRESS) ||
			(address_outer_corner_w < MIN_MEM_ADDRESS) || (address_outer_corner_w > MAX_MEM_ADDRESS) ||
			(address_inner_outer_corner_w < MIN_MEM_ADDRESS) || (address_inner_outer_corner_w > MAX_MEM_ADDRESS);
	end

	// Runtime admission needs enough lead for Active RAM visibility, Select and Issue FIFO stages.
	always_comb begin
		ingress_min_start_cycle_w = {1'b0, schedule_cycle_i} + ISSUE_LOOKAHEAD + 1;
		native_invalid_w = (ingress_instruction_q[29:28] != 2'd0) ||
			(ingress_instruction_q[14:9] != 6'd0) ||
			!((ingress_instruction_q[2:0] == 3'd0) || (ingress_instruction_q[2:0] == 3'd1)) ||
			(ingress_instruction_q[31] && (ingress_instruction_q[2:0] != 3'd1)) ||
			(ingress_instruction_q[27:15] != ingress_address_q);
		iteration_invalid_w = (ingress_inner_count_q == 0) || (ingress_inner_count_q > MAX_CONTEXT_COUNT) ||
			(ingress_outer_count_q == 0) || (ingress_outer_count_q > MAX_CONTEXT_COUNT) ||
			(ingress_inner_interval_q == 0) || (ingress_outer_interval_q == 0) ||
			((ingress_outer_count_q > 1) && ({33'd0, ingress_outer_interval_q} <= schedule_inner_cycle_span_w));
		step_invalid_w = (schedule_effective_inner_step_w < MIN_CONTEXT_STEP) || (schedule_effective_inner_step_w > MAX_CONTEXT_STEP) ||
			(schedule_row_transition_w < MIN_CONTEXT_STEP) || (schedule_row_transition_w > MAX_CONTEXT_STEP);
		cycle_invalid_w = schedule_final_cycle_w[64:32] != 0;
		ingress_late_w = run_i && (ingress_min_start_cycle_w[32] || ({1'b0, ingress_start_cycle_q} < ingress_min_start_cycle_w));

		ingress_context_invalid_w = 1'b0;
		ingress_context_fault_code_w = FAULT_NONE;
		if(ingress_induction_target_q != MEM_ADDRESS_TARGET)begin
			ingress_context_invalid_w = 1'b1;
			ingress_context_fault_code_w = FAULT_TARGET;
		end
		else if(native_invalid_w)begin
			ingress_context_invalid_w = 1'b1;
			ingress_context_fault_code_w = FAULT_NATIVE;
		end
		else if(iteration_invalid_w)begin
			ingress_context_invalid_w = 1'b1;
			ingress_context_fault_code_w = FAULT_ITERATION;
		end
		else if(step_invalid_w)begin
			ingress_context_invalid_w = 1'b1;
			ingress_context_fault_code_w = FAULT_STEP;
		end
		else if(address_range_invalid_w)begin
			ingress_context_invalid_w = 1'b1;
			ingress_context_fault_code_w = FAULT_ADDRESS;
		end
		else if(cycle_invalid_w)begin
			ingress_context_invalid_w = 1'b1;
			ingress_context_fault_code_w = FAULT_CYCLE;
		end
		else if(ingress_late_w)begin
			ingress_context_invalid_w = 1'b1;
			ingress_context_fault_code_w = FAULT_LATE_CONTEXT;
		end
	end

	// The first invalid Active Context slot accepts the next validated Context.
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

	// Due scan is performed ISSUE_LOOKAHEAD cycles ahead so Issue output is registered before its deadline.
	always_comb begin
		lookahead_cycle_sum_w = prime_mode_w ? {32'd0, (prime_tail_i === 1'b1)} :
			({1'b0, schedule_cycle_i} + ISSUE_LOOKAHEAD);
		lookahead_cycle_w = lookahead_cycle_sum_w[31:0];
		lookahead_overflow_w = lookahead_cycle_sum_w[32];
		selected_valid_w = 1'b0;
		selected_index_w = 0;
		due_count_w = 0;
		missed_generation_w = 1'b0;
		active_count_o = '0;
		for(integer slot = 0; slot < ACTIVE_CONTEXTS; slot = slot + 1)begin
			if(active_valid_q[slot])begin
				active_count_o = active_count_o + 1'b1;
				if(active_next_issue_cycle_q[slot] < lookahead_cycle_w)begin
					missed_generation_w = 1'b1;
				end
				else if(active_next_issue_cycle_q[slot] == lookahead_cycle_w)begin
					if(!selected_valid_w)begin
						selected_valid_w = 1'b1;
						selected_index_w = slot;
					end
					due_count_w = due_count_w + 1;
				end
			end
		end
	end

	// The Scheduler computes one future base instruction; the Timed Queue is the register boundary.
	assign issue_valid_o = scheduler_active_w && selected_valid_w && (due_count_w == 1) &&
		!missed_generation_w && !fault_q;
	assign issue_instruction_o = selected_valid_w ?
		context_to_mem_instruction(active_instruction_q[selected_index_w], active_address_q[selected_index_w]) : '0;
	assign issue_cycle_o = selected_valid_w ? lookahead_cycle_w : '0;
	assign timed_queue_blocked_w = issue_valid_o && !issue_ready_i;
	assign ingress_capacity_deadline_w = run_i && ingress_valid_q && !free_slot_valid_w &&
		(ingress_min_start_cycle_w[32] || ({1'b0, ingress_start_cycle_q} < ingress_min_start_cycle_w));

	assign timebase_invalid_w = run_i && run_seen_q &&
		((previous_schedule_cycle_q == 32'hffff_ffff) || (schedule_cycle_i != previous_schedule_cycle_q + 1'b1));

	// Deadline and timebase violations have priority over future scheduling work.
	always_comb begin
		dynamic_fault_w = 1'b0;
		dynamic_fault_code_w = FAULT_NONE;
		if(timebase_invalid_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_TIMEBASE;
		end
		else if(run_i && lookahead_overflow_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_LOOKAHEAD;
		end
		else if(timed_queue_blocked_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_TIMED_QUEUE_BACKPRESSURE;
		end
		else if(scheduler_active_w && due_count_w > 1)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_CONFLICT;
		end
		else if(scheduler_active_w && missed_generation_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_MISSED_ISSUE;
		end
		else if(ingress_capacity_deadline_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_LATE_CONTEXT;
		end
		else if(ingress_valid_q && free_slot_valid_w && ingress_context_invalid_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = ingress_context_fault_code_w;
		end
		else if(run_i && schedule_cycle_i == 32'hffff_ffff)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_COUNTER_OVERFLOW;
		end
	end

	assign context_ready_o = !ingress_valid_q && !fault_q && !dynamic_fault_w;
	assign ingress_admit_fire = ingress_valid_q && free_slot_valid_w && !ingress_context_invalid_w && !fault_q && !dynamic_fault_w;
	assign schedule_select_fire = issue_valid_o && issue_ready_i && !dynamic_fault_w;
	assign prime_ready_o = prime_mode_w && !ingress_valid_q &&
		(due_count_w == 0) && !fault_q && !dynamic_fault_w;
	assign prime_blocked_o = prime_mode_w && ingress_valid_q && !free_slot_valid_w &&
		(due_count_w == 0) && !fault_q && !dynamic_fault_w;
	assign prime_stream_o = prime_mode_w && ingress_valid_q &&
		(ingress_start_cycle_q >= ISSUE_LOOKAHEAD + 2) &&
		(due_count_w == 0) && !fault_q && !dynamic_fault_w;
	assign fault_o = fault_q || dynamic_fault_w;
	assign fault_code_o = fault_q ? fault_code_q : dynamic_fault_code_w;

	// Capture one Context without exposing Active Context storage latency to the Decoder.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			ingress_valid_q <= 1'b0;
			ingress_instruction_q <= '0;
			ingress_start_cycle_q <= '0;
			ingress_inner_count_q <= '0;
			ingress_inner_interval_q <= '0;
			ingress_inner_stride_q <= '0;
			ingress_outer_count_q <= '0;
			ingress_outer_interval_q <= '0;
			ingress_outer_stride_q <= '0;
			ingress_induction_target_q <= '0;
			ingress_address_q <= '0;
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
				ingress_address_q <= context_address_i;
			end
		end
	end

	// Context state advances only when the FU-local Timed Queue accepts the generated instruction.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			for(integer slot = 0; slot < ACTIVE_CONTEXTS; slot = slot + 1)begin
				active_valid_q[slot] <= 1'b0;
			end
		end
		else begin
			if(schedule_select_fire)begin
				if(active_inner_remaining_q[selected_index_w] > 32'd1)begin
					active_inner_remaining_q[selected_index_w] <= active_inner_remaining_q[selected_index_w] - 1'b1;
					active_next_issue_cycle_q[selected_index_w] <= active_next_issue_cycle_q[selected_index_w] + active_inner_interval_q[selected_index_w];
					active_address_q[selected_index_w] <= add_mem_address_step(active_address_q[selected_index_w], active_inner_step_q[selected_index_w]);
				end
				else if(active_outer_remaining_q[selected_index_w] > 32'd1)begin
					active_outer_remaining_q[selected_index_w] <= active_outer_remaining_q[selected_index_w] - 1'b1;
					active_inner_remaining_q[selected_index_w] <= active_inner_count_q[selected_index_w];
					active_next_issue_cycle_q[selected_index_w] <= active_next_issue_cycle_q[selected_index_w] + active_outer_residual_q[selected_index_w];
					active_address_q[selected_index_w] <= add_mem_address_step(active_address_q[selected_index_w], active_row_transition_q[selected_index_w]);
				end
				else begin
					active_valid_q[selected_index_w] <= 1'b0;
				end
			end

			if(ingress_admit_fire)begin
				active_valid_q[free_slot_index_w] <= 1'b1;
				active_instruction_q[free_slot_index_w] <= ingress_instruction_q;
				active_address_q[free_slot_index_w] <= ingress_address_q;
				active_inner_count_q[free_slot_index_w] <= ingress_inner_count_q;
				active_inner_remaining_q[free_slot_index_w] <= ingress_inner_count_q;
				active_outer_remaining_q[free_slot_index_w] <= ingress_outer_count_q;
				active_inner_interval_q[free_slot_index_w] <= schedule_effective_inner_interval_w;
				active_outer_residual_q[free_slot_index_w] <= schedule_outer_residual_w;
				active_inner_step_q[free_slot_index_w] <= schedule_effective_inner_step_w[13:0];
				active_row_transition_q[free_slot_index_w] <= schedule_row_transition_w[13:0];
				active_next_issue_cycle_q[free_slot_index_w] <= ingress_start_cycle_q;
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
