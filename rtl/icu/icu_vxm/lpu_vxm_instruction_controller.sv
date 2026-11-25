// Own one resident configuration and all accepted Execute iterations.
module lpu_vxm_instruction_controller #(
	parameter integer REPEAT_COUNT_WIDTH = 10,
	parameter integer REPEAT_INTERVAL_WIDTH = 8,
	parameter bit SEQUENTIAL_PHASE = 1'b0
) (
	input logic clk_i,
	input logic rst_ni,

	// One command describes one complete resident VXM configuration.
	input logic command_valid_i,
	output logic command_ready_o,
	input logic [lpu_pkg::VXM_LOCAL_QUEUE_COUNT-1:0] command_local_active_i,
	input logic [lpu_pkg::VXM_LOCAL_QUEUE_COUNT* lpu_pkg::VXM_LOCAL_MAX_INSTRUCTION_WIDTH-1:0] command_local_instruction_i,
	input logic [lpu_pkg::VXM_GLOBAL_CONFIG_WIDTH-1:0] command_global_config_i,
	// Total Execute iterations, including the first; zero is rejected rather than interpreted as an empty command.
	input logic [REPEAT_COUNT_WIDTH-1:0] command_repeat_count_i,
	// Minimum clock-cycle spacing between accepted Execute tokens; 0/1 allow consecutive-cycle acceptance.
	input logic [REPEAT_INTERVAL_WIDTH-1:0] command_repeat_interval_i,
	input logic command_accumulator_enable_i,
	input logic command_output_enable_i,
	// Sequential compact flags describe every repeated operation. They are not
	// automatically changed into one reduction's first/final-iteration flags.
	input logic [3:0] command_repeat_phase_i,

	// Configuration load is held until the Tile is completely quiescent.
	output logic local_config_load_o,
	input logic local_config_ready_i,
	output logic [lpu_pkg::VXM_LOCAL_QUEUE_COUNT-1:0] local_config_active_o,
	output logic [lpu_pkg::VXM_LOCAL_QUEUE_COUNT* lpu_pkg::VXM_LOCAL_MAX_INSTRUCTION_WIDTH-1:0] local_config_instruction_o,
	output logic global_config_valid_o,
	output logic [lpu_pkg::VXM_GLOBAL_CONFIG_WIDTH-1:0] global_config_o,

	// Every accepted execute pulse represents one execution of the unchanged
	// configuration. The four-bit word is phase metadata, not an instruction.
	output logic execute_valid_o,
	input logic execute_ready_i,
	output logic [lpu_pkg::VXM_REPEAT_CONTROL_WIDTH-1:0] repeat_control_o,

	// config_done_i is the single final marker returned from a chain tail.
	input logic config_done_i,
	output logic busy_o,
	output logic done_o,
	output logic fault_o
);
	import lpu_pkg::*;

	typedef enum logic [1:0] {
		STATE_IDLE,
		STATE_LOAD,
		STATE_RUN,
		STATE_WAIT_DONE
	} state_t;

	state_t state_q;
	logic [VXM_LOCAL_QUEUE_COUNT-1:0] local_active_q;
	logic [VXM_LOCAL_QUEUE_COUNT*VXM_LOCAL_MAX_INSTRUCTION_WIDTH-1:0] local_instruction_q;
	logic [VXM_GLOBAL_CONFIG_WIDTH-1:0] global_config_q;
	// remaining_q includes the next accepted Execute; cooldown_q counts clock cycles before another may be offered.
	logic [REPEAT_COUNT_WIDTH-1:0] remaining_q;
	// Retained requested spacing in clock cycles; ready backpressure can lengthen the actual acceptance interval.
	logic [REPEAT_INTERVAL_WIDTH-1:0] interval_q;
	logic [REPEAT_INTERVAL_WIDTH-1:0] cooldown_q;
	logic accumulator_enable_q;
	logic output_enable_q;
	// True until the first Execute token is accepted, so only that iteration requests accumulator initialization.
	logic first_iteration_q;
	logic [3:0] sequential_phase_q;

	// Drive resident configuration, Execute-token status and repeat metadata from the controller state.
	always_comb begin
		command_ready_o = (state_q == STATE_IDLE);
		local_config_load_o = (state_q == STATE_LOAD);
		local_config_active_o = local_active_q;
		local_config_instruction_o = local_instruction_q;
		global_config_valid_o = (state_q != STATE_IDLE);
		global_config_o = global_config_q;
		execute_valid_o = (state_q == STATE_RUN) && (cooldown_q == 0);
		busy_o = (state_q != STATE_IDLE);

		repeat_control_o = '0;
		repeat_control_o[VXM_REPEAT_LAST_ITERATION_BIT] = (remaining_q == REPEAT_COUNT_WIDTH'(1));
		repeat_control_o[VXM_REPEAT_FIRST_ITERATION_BIT] = first_iteration_q;
		repeat_control_o[VXM_REPEAT_ACCUMULATOR_BIT] = accumulator_enable_q;
		repeat_control_o[VXM_REPEAT_OUTPUT_ENABLE_BIT] = output_enable_q;
		if(SEQUENTIAL_PHASE)begin
			repeat_control_o = sequential_phase_q;
		end
	end

	// Run the resident-configuration lifecycle atomically: capture one command,
	// load the configuration, emit spaced Execute tokens, and wait for tail Done.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			state_q <= STATE_IDLE;
			local_active_q <= '0;
			local_instruction_q <= '0;
			global_config_q <= '0;
			remaining_q <= '0;
			interval_q <= '0;
			cooldown_q <= '0;
			accumulator_enable_q <= 1'b0;
			output_enable_q <= 1'b0;
			first_iteration_q <= 1'b0;
			sequential_phase_q <= '0;
			done_o <= 1'b0;
			fault_o <= 1'b0;
		end
		else begin
			done_o <= 1'b0;

			case (state_q)
				STATE_IDLE: begin
					cooldown_q <= '0;
					if(command_valid_i && command_ready_o)begin
						if(command_repeat_count_i == 0)begin
							fault_o <= 1'b1;
						end
						else begin
							local_active_q <= command_local_active_i;
							local_instruction_q <= command_local_instruction_i;
							global_config_q <= command_global_config_i;
							remaining_q <= command_repeat_count_i;
							interval_q <= command_repeat_interval_i;
							accumulator_enable_q <= command_accumulator_enable_i;
							output_enable_q <= command_output_enable_i;
							first_iteration_q <= 1'b1;
							sequential_phase_q <= command_repeat_phase_i;
							state_q <= STATE_LOAD;
						end
					end
				end

				STATE_LOAD: begin
					if(local_config_load_o && local_config_ready_i)begin
						state_q <= STATE_RUN;
					end
				end

				STATE_RUN: begin
					if(cooldown_q != 0)begin
						cooldown_q <= cooldown_q - 1'b1;
					end
					else if(execute_valid_o && execute_ready_i)begin
						if(remaining_q == 1)begin
							remaining_q <= '0;
							state_q <= STATE_WAIT_DONE;
						end
						else begin
							remaining_q <= remaining_q - 1'b1;
							first_iteration_q <= 1'b0;
							cooldown_q <= (interval_q > 1) ? interval_q - 1'b1 : '0;
						end
					end
				end

				STATE_WAIT_DONE: begin
					if(config_done_i)begin
						done_o <= 1'b1;
						state_q <= STATE_IDLE;
					end
				end

				default: begin
					state_q <= STATE_IDLE;
					fault_o <= 1'b1;
				end
			endcase
		end
	end

	initial begin
		if((REPEAT_COUNT_WIDTH < 1) || (REPEAT_INTERVAL_WIDTH < 1))begin
			$error("VXM instruction-controller counter widths must be positive");
		end
	end
endmodule
