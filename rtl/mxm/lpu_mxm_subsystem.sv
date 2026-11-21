module lpu_mxm_subsystem #(
	parameter integer LOCAL_MXM_INDEX = 0,
	parameter integer IMEM_DEPTH = 65536,
	parameter integer ACTIVE_CONTEXTS = 4,
	parameter integer FU_QUEUE_DEPTH = 16,
	parameter integer ACCUMULATOR_BLOCK_COUNT = lpu_pkg::MXM_ACCUMULATOR_BLOCK_COUNT,
	parameter bit PAIR_LOAD_DEQUANT = 1'b0
) (
	input logic clk_i,
	input logic rst_ni,
	input logic program_reset_i,
	// Keep the legacy datapath powered between program segments: run_i here
	// is the issue epoch, not an instruction to clear resident weights.
	input logic execution_enable_i,
	input logic run_i,
	input logic [31:0] schedule_cycle_i,
	input logic [2:0] qctl_active_i,
	input logic [2:0] qctl_scheduler_enable_i,
	input logic [3*32-1:0] qctl_schedule_cycle_i,

	input logic program_valid_i,
	output logic program_ready_o,
	input logic [2:0] program_control_i,
	input logic [3:0] program_target_kind_i,
	input logic [16:0] program_address_i,
	input logic [127:0] program_data_i,
	input logic [3:0] program_strb_i,
	input logic program_last_i,
	output logic program_error_o,

	output logic local_load_issue_valid_o,
	output logic [28:0] local_load_issue_instruction_o,
	output logic [31:0] local_load_issue_cycle_o,
	output logic local_dequant_issue_valid_o,
	output logic [15:0] local_dequant_issue_instruction_o,
	output logic [31:0] local_dequant_issue_cycle_o,
	output logic local_compute_issue_valid_o,
	output logic [48:0] local_compute_issue_instruction_o,
	output logic [31:0] local_compute_issue_cycle_o,

	output logic frontends_ready_o,
	output logic frontends_idle_o,
	output logic execution_busy_o,
	output logic frontend_fault_o,
	output logic [5:0] frontend_fault_code_o,

	input logic [4*32-1:0] east_from_sxm_valid_i,
	input logic [4*32*64-1:0] east_from_sxm_data_i,
	input logic [4*32-1:0] external_west_valid_i,
	input logic [4*32*64-1:0] external_west_data_i,
	output logic [4*32-1:0] east_external_valid_o,
	output logic [4*32*64-1:0] east_external_data_o,
	output logic [4*32-1:0] west_to_sxm_valid_o,
	output logic [4*32*64-1:0] west_to_sxm_data_o,
	output logic fault_o,
	output logic conflict_o
);
    /* verilator hier_block */
	import lpu_program_load_pkg::*;

	logic clear_fire_w;
	logic write_fire_w;
	logic prime_fire_w;
	logic load_load_ready;
	logic load_prime_ready;
	logic dequant_load_ready;
	logic dequant_prime_ready;
	logic compute_load_ready;
	logic compute_prime_ready;
	logic load_ready;
	logic load_idle;
	logic load_fault;
	logic [5:0] load_fault_code;
	logic dequant_ready;
	logic dequant_idle;
	logic dequant_fault;
	logic [5:0] dequant_fault_code;
	logic compute_ready;
	logic compute_idle;
	logic compute_fault;
	logic [5:0] compute_fault_code;
	logic load_frontend_valid;
	logic load_frontend_ready;
	logic [48:0] load_frontend_instruction;
	logic [31:0] load_frontend_cycle;
	logic dequant_frontend_valid;
	logic dequant_frontend_ready;
	logic [48:0] dequant_frontend_instruction;
	logic [31:0] dequant_frontend_cycle;
	logic compute_frontend_valid;
	logic compute_frontend_ready;
	logic [48:0] compute_frontend_instruction;
	logic [31:0] compute_frontend_cycle;
	logic load_source_valid;
	logic load_source_ready;
	logic [48:0] load_source_instruction;
	logic [31:0] load_source_cycle;
	logic dequant_source_valid;
	logic dequant_source_ready;
	logic [48:0] dequant_source_instruction;
	logic [31:0] dequant_source_cycle;
	logic compute_source_valid;
	logic compute_source_ready;
	logic [48:0] compute_source_instruction;
	logic [31:0] compute_source_cycle;
	logic load_queue_fault;
	logic dequant_queue_fault;
	logic compute_queue_fault;
	logic [$clog2(FU_QUEUE_DEPTH+1)-1:0] load_queue_level;
	logic [$clog2(FU_QUEUE_DEPTH+1)-1:0] dequant_queue_level;
	logic [$clog2(FU_QUEUE_DEPTH+1)-1:0] compute_queue_level;
	logic coordinator_fault;
	logic [2:0] coordinator_fault_code;
	logic compute_width_invalid_w;
	logic execution_load_valid;
	logic [47:0] execution_load_instruction;
	logic execution_dequant_valid;
	logic [15:0] execution_dequant_instruction;
	logic execution_compute_valid;
	logic [47:0] execution_compute_instruction;
	logic frontend_rst_ni;
	logic [2:0] frontend_run;
	logic [3*32-1:0] frontend_schedule_cycle;

	assign clear_fire_w = program_valid_i && program_ready_o &&
		((program_control_i == PROGRAM_LOAD_CLEAR) || (program_control_i == PROGRAM_LOAD_ABORT));
	assign write_fire_w = program_valid_i && program_ready_o &&
		(program_control_i == PROGRAM_LOAD_WRITE) &&
		(program_strb_i == 4'b1111) && (program_address_i < IMEM_DEPTH);
	assign prime_fire_w = program_valid_i && program_ready_o &&
		(program_control_i == PROGRAM_LOAD_PRIME);
	assign frontend_rst_ni = rst_ni && !program_reset_i && !clear_fire_w;
	// Stream order is Load, Dequant, Compute. Each stream may independently
	// freeze its Queue-local time at a QCTL boundary.
	generate
		for(genvar stream_index = 0; stream_index < 3; stream_index++)begin : gen_qctl_stream_select
			assign frontend_run[stream_index] = 				(qctl_active_i[stream_index] ? qctl_scheduler_enable_i[stream_index] : run_i);
			assign frontend_schedule_cycle[stream_index*32+:32] = qctl_active_i[stream_index] ?
				qctl_schedule_cycle_i[stream_index*32+:32] : schedule_cycle_i;
		end
	endgenerate
	assign frontends_ready_o = load_ready && dequant_ready && compute_ready;
	assign frontends_idle_o = load_idle && dequant_idle && compute_idle &&
		(load_queue_level == '0) && (dequant_queue_level == '0) && (compute_queue_level == '0);
	assign frontend_fault_o = load_fault || dequant_fault || compute_fault ||
		load_queue_fault || dequant_queue_fault || compute_queue_fault || coordinator_fault;
	assign frontend_fault_code_o = load_fault ? load_fault_code :
		(dequant_fault ? dequant_fault_code :
		(compute_fault ? compute_fault_code :
		((load_queue_fault || dequant_queue_fault || compute_queue_fault) ? 6'd5 :
		(coordinator_fault ? {3'd0, coordinator_fault_code} : 6'd0))));

	// Program writes target one of the three instruction streams owned by this MXM.
	always_comb begin
		case(program_target_kind_i)
			PROGRAM_TARGET_MXM_LOAD: program_ready_o = program_control_i == PROGRAM_LOAD_PRIME ?
				load_prime_ready : load_load_ready;
			PROGRAM_TARGET_MXM_DEQUANT: program_ready_o = program_control_i == PROGRAM_LOAD_PRIME ?
				dequant_prime_ready : dequant_load_ready;
			PROGRAM_TARGET_MXM_COMPUTE: program_ready_o = program_control_i == PROGRAM_LOAD_PRIME ?
				compute_prime_ready : compute_load_ready;
			default: program_ready_o = (program_control_i == PROGRAM_LOAD_CLEAR) ||
				(program_control_i == PROGRAM_LOAD_ABORT);
		endcase
		if((program_control_i == PROGRAM_LOAD_CLEAR) || (program_control_i == PROGRAM_LOAD_ABORT))begin
			program_ready_o = 1'b1;
		end
		program_error_o = program_valid_i && program_ready_o &&
			(((program_target_kind_i < PROGRAM_TARGET_MXM_LOAD) ||
			  (program_target_kind_i > PROGRAM_TARGET_MXM_COMPUTE)) ||
			 ((program_control_i == PROGRAM_LOAD_WRITE) &&
			  ((program_strb_i != 4'b1111) || (program_address_i >= IMEM_DEPTH))) ||
			 (program_control_i > PROGRAM_LOAD_ABORT));
	end

	lpu_mxm_local_imem_frontend #(
		.TARGET_KIND(PROGRAM_TARGET_MXM_LOAD),
		.IMEM_DEPTH(IMEM_DEPTH),
		.ACTIVE_CONTEXTS(ACTIVE_CONTEXTS)
	) u_load_frontend (
		.clk_i, .rst_ni, .program_reset_i, .clear_i(clear_fire_w),
		.load_valid_i(write_fire_w && (program_target_kind_i == PROGRAM_TARGET_MXM_LOAD)),
		.load_ready_o(load_load_ready), .load_address_i(program_address_i),
		.load_data_i(program_data_i), .load_strb_i(program_strb_i), .load_last_i(program_last_i),
		.prime_valid_i(prime_fire_w && (program_target_kind_i == PROGRAM_TARGET_MXM_LOAD)),
		.prime_ready_o(load_prime_ready), .run_i(frontend_run[0]),
		.schedule_cycle_i(frontend_schedule_cycle[0*32+:32]), .issue_valid_o(load_frontend_valid), .issue_ready_i(load_frontend_ready),
		.issue_instruction_o(load_frontend_instruction), .issue_cycle_o(load_frontend_cycle),
		.configured_o(), .frontend_ready_o(load_ready), .frontend_idle_o(load_idle),
		.fault_o(load_fault), .fault_code_o(load_fault_code)
	);

	lpu_mxm_local_imem_frontend #(
		.TARGET_KIND(PROGRAM_TARGET_MXM_DEQUANT),
		.IMEM_DEPTH(IMEM_DEPTH),
		.ACTIVE_CONTEXTS(ACTIVE_CONTEXTS)
	) u_dequant_frontend (
		.clk_i, .rst_ni, .program_reset_i, .clear_i(clear_fire_w),
		.load_valid_i(write_fire_w && (program_target_kind_i == PROGRAM_TARGET_MXM_DEQUANT)),
		.load_ready_o(dequant_load_ready), .load_address_i(program_address_i),
		.load_data_i(program_data_i), .load_strb_i(program_strb_i), .load_last_i(program_last_i),
		.prime_valid_i(prime_fire_w && (program_target_kind_i == PROGRAM_TARGET_MXM_DEQUANT)),
		.prime_ready_o(dequant_prime_ready), .run_i(frontend_run[1]),
		.schedule_cycle_i(frontend_schedule_cycle[1*32+:32]), .issue_valid_o(dequant_frontend_valid), .issue_ready_i(dequant_frontend_ready),
		.issue_instruction_o(dequant_frontend_instruction), .issue_cycle_o(dequant_frontend_cycle),
		.configured_o(), .frontend_ready_o(dequant_ready), .frontend_idle_o(dequant_idle),
		.fault_o(dequant_fault), .fault_code_o(dequant_fault_code)
	);

	lpu_mxm_local_imem_frontend #(
		.TARGET_KIND(PROGRAM_TARGET_MXM_COMPUTE),
		.IMEM_DEPTH(IMEM_DEPTH),
		.ACTIVE_CONTEXTS(ACTIVE_CONTEXTS)
	) u_compute_frontend (
		.clk_i, .rst_ni, .program_reset_i, .clear_i(clear_fire_w),
		.load_valid_i(write_fire_w && (program_target_kind_i == PROGRAM_TARGET_MXM_COMPUTE)),
		.load_ready_o(compute_load_ready), .load_address_i(program_address_i),
		.load_data_i(program_data_i), .load_strb_i(program_strb_i), .load_last_i(program_last_i),
		.prime_valid_i(prime_fire_w && (program_target_kind_i == PROGRAM_TARGET_MXM_COMPUTE)),
		.prime_ready_o(compute_prime_ready), .run_i(frontend_run[2]),
		.schedule_cycle_i(frontend_schedule_cycle[2*32+:32]), .issue_valid_o(compute_frontend_valid), .issue_ready_i(compute_frontend_ready),
		.issue_instruction_o(compute_frontend_instruction), .issue_cycle_o(compute_frontend_cycle),
		.configured_o(), .frontend_ready_o(compute_ready), .frontend_idle_o(compute_idle),
		.fault_o(compute_fault), .fault_code_o(compute_fault_code)
	);

	// Each MXM stream owns an independent Timed Queue at the Subsystem boundary.
	lpu_mxm_issue_queue #(.INSTRUCTION_WIDTH(49), .DEPTH(FU_QUEUE_DEPTH)) u_load_timed_queue (
		.clk_i, .rst_ni(frontend_rst_ni), .run_i(frontend_run[0]),
		.schedule_cycle_i(frontend_schedule_cycle[0*32+:32]),
		.enqueue_valid_i(load_frontend_valid), .enqueue_ready_o(load_frontend_ready),
		.enqueue_instruction_i(load_frontend_instruction), .enqueue_cycle_i(load_frontend_cycle),
		.issue_valid_o(load_source_valid), .issue_ready_i(load_source_ready),
		.issue_instruction_o(load_source_instruction), .issue_cycle_o(load_source_cycle),
		.level_o(load_queue_level), .fault_o(load_queue_fault)
	);

	lpu_mxm_issue_queue #(.INSTRUCTION_WIDTH(49), .DEPTH(FU_QUEUE_DEPTH)) u_dequant_timed_queue (
		.clk_i, .rst_ni(frontend_rst_ni), .run_i(frontend_run[1]),
		.schedule_cycle_i(frontend_schedule_cycle[1*32+:32]),
		.enqueue_valid_i(dequant_frontend_valid), .enqueue_ready_o(dequant_frontend_ready),
		.enqueue_instruction_i(dequant_frontend_instruction), .enqueue_cycle_i(dequant_frontend_cycle),
		.issue_valid_o(dequant_source_valid), .issue_ready_i(dequant_source_ready),
		.issue_instruction_o(dequant_source_instruction), .issue_cycle_o(dequant_source_cycle),
		.level_o(dequant_queue_level), .fault_o(dequant_queue_fault)
	);

	lpu_mxm_issue_queue #(.INSTRUCTION_WIDTH(49), .DEPTH(FU_QUEUE_DEPTH)) u_compute_timed_queue (
		.clk_i, .rst_ni(frontend_rst_ni), .run_i(frontend_run[2]),
		.schedule_cycle_i(frontend_schedule_cycle[2*32+:32]),
		.enqueue_valid_i(compute_frontend_valid), .enqueue_ready_o(compute_frontend_ready),
		.enqueue_instruction_i(compute_frontend_instruction), .enqueue_cycle_i(compute_frontend_cycle),
		.issue_valid_o(compute_source_valid), .issue_ready_i(compute_source_ready),
		.issue_instruction_o(compute_source_instruction), .issue_cycle_o(compute_source_cycle),
		.level_o(compute_queue_level), .fault_o(compute_queue_fault)
	);

	assign compute_width_invalid_w = local_compute_issue_valid_o && local_compute_issue_instruction_o[48];

	lpu_mxm_local_coordinator u_coordinator (
		.clk_i, .rst_ni, .run_i(run_i),
		.pair_load_dequant_i(PAIR_LOAD_DEQUANT),
		.load_schedule_cycle_i(frontend_schedule_cycle[0*32+:32]),
		.dequant_schedule_cycle_i(frontend_schedule_cycle[1*32+:32]),
		.compute_schedule_cycle_i(frontend_schedule_cycle[2*32+:32]),
		.load_valid_i(load_source_valid), .load_ready_o(load_source_ready),
		.load_instruction_i(load_source_instruction[28:0]), .load_cycle_i(load_source_cycle),
		.dequant_valid_i(dequant_source_valid), .dequant_ready_o(dequant_source_ready),
		.dequant_instruction_i(dequant_source_instruction[15:0]), .dequant_cycle_i(dequant_source_cycle),
		.compute_valid_i(compute_source_valid), .compute_ready_o(compute_source_ready),
		.compute_instruction_i(compute_source_instruction), .compute_cycle_i(compute_source_cycle),
		.load_issue_valid_o(local_load_issue_valid_o), .load_issue_ready_i(1'b1),
		.load_issue_instruction_o(local_load_issue_instruction_o), .load_issue_cycle_o(local_load_issue_cycle_o),
		.dequant_issue_valid_o(local_dequant_issue_valid_o), .dequant_issue_ready_i(1'b1),
		.dequant_issue_instruction_o(local_dequant_issue_instruction_o), .dequant_issue_cycle_o(local_dequant_issue_cycle_o),
		.compute_issue_valid_o(local_compute_issue_valid_o), .compute_issue_ready_i(!compute_width_invalid_w),
		.compute_issue_instruction_o(local_compute_issue_instruction_o), .compute_issue_cycle_o(local_compute_issue_cycle_o),
		.fault_o(coordinator_fault), .fault_code_o(coordinator_fault_code)
	);

	assign execution_load_valid = local_load_issue_valid_o;
	assign execution_load_instruction = {{19{1'b0}}, local_load_issue_instruction_o};
	assign execution_dequant_valid = local_dequant_issue_valid_o;
	assign execution_dequant_instruction = local_dequant_issue_instruction_o;
	assign execution_compute_valid = local_compute_issue_valid_o && !compute_width_invalid_w;
	assign execution_compute_instruction = local_compute_issue_instruction_o[47:0];

	lpu_mxm_slice #(
		.LOCAL_MXM_INDEX(LOCAL_MXM_INDEX),
		.ACCUMULATOR_BLOCK_COUNT(ACCUMULATOR_BLOCK_COUNT)
	) u_execution (
		.clk_i, .rst_ni, .run_i(execution_enable_i),
		.load_issue_valid_i(execution_load_valid), .load_issue_instruction_i(execution_load_instruction),
		.dequant_issue_valid_i(execution_dequant_valid), .dequant_issue_instruction_i(execution_dequant_instruction),
		.compute_issue_valid_i(execution_compute_valid), .compute_issue_instruction_i(execution_compute_instruction),
		.east_from_sxm_valid_i, .east_from_sxm_data_i, .external_west_valid_i, .external_west_data_i,
		.east_external_valid_o, .east_external_data_o, .west_to_sxm_valid_o, .west_to_sxm_data_o,
		.fault_o, .conflict_o, .execution_busy_o
	);
endmodule
