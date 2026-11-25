// Central VXM: eight sequential iMEM queues feeding one resident execution Slice.
module lpu_vxm_subsystem #(
	parameter integer IMEM_DEPTH = 256,
	parameter integer CONFIG_FIFO_DEPTH = 3
) (
	input logic clk_i,
	input logic rst_ni,
	input logic program_reset_i,
	input logic run_i,
	input logic [31:0] schedule_cycle_i,
	input logic program_valid_i,
	output logic program_ready_o,
	input logic [lpu_program_load_pkg::PROGRAM_LOAD_CONTROL_WIDTH-1:0] program_control_i,
	input logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0] program_destination_i,
	input logic [16:0] program_address_i,
	input logic [127:0] program_data_i,
	input logic [3:0] program_strb_i,
	input logic program_last_i,
	output logic program_error_o,
	output logic frontend_ready_o,
	output logic frontend_idle_o,
	output logic done_o,
	input logic [2*4*32-1:0] west_from_mem_valid_i,
	input logic [2*4*32*64-1:0] west_from_mem_data_i,
	input logic [2*4*32-1:0] external_east_valid_i,
	input logic [2*4*32*64-1:0] external_east_data_i,
	output logic [2*4*32-1:0] east_to_mem_valid_o,
	output logic [2*4*32*64-1:0] east_to_mem_data_o,
	output logic fault_o,
	output logic conflict_o
);
	import lpu_program_load_pkg::*;
	logic local_rst_n;
	logic [7:0] configured, queue_ready, queue_idle, queue_fault;
	logic [7:0] load_ready, prime_ready, dispatch_valid, dispatch_ready;
	logic [7:0] config_valid, config_pop;
	logic [95:0] dispatch_word[8], config_word[8];
	logic [31:0] dispatch_cycle[8];
	logic [6:0] native_local[8];
	logic [14:0] native_global[8];
	logic [31:0] native_count[8], native_immediate[8];
	logic [3:0] native_phase[8];
	logic [7:0] native_immediate_valid;
	logic route_legal, route_fault_q, bundle_fault_q;
	logic [7:0] queue_index;
	logic [55:0] bundle_local;
	logic [255:0] bundle_immediate, command_immediate_q;
	logic [7:0] command_immediate_valid_q;
	logic [14:0] bundle_global;
	logic [31:0] bundle_count;
	logic [3:0] bundle_phase;
	logic bundle_valid, bundle_legal, command_ready, command_fire;
	logic have_reference, have_tail;
	logic headers_match;
	integer chain_size;
	logic config_load, config_ready;
	logic [7:0] config_active;
	logic [55:0] config_local;
	logic [14:0] config_global;
	logic execute_valid, execute_ready;
	logic [3:0] repeat_phase;
	logic controller_busy, controller_done, controller_fault;
	logic execution_idle, execution_fault, completed_q;

	assign local_rst_n = rst_ni && !program_reset_i;
	assign queue_index = program_destination_i[7:0];
	assign route_legal = program_destination_i[11:8] == PROGRAM_TARGET_VXM && queue_index < 8;
	// Central routing is canonicalized by the Distributor; Hemisphere does not
	// select another VXM or encode the data-flow direction.
	assign program_ready_o = !run_i && !fault_o && (!route_legal ||
		(program_control_i == PROGRAM_LOAD_WRITE ? load_ready[queue_index[2:0]] : prime_ready[queue_index[2:0]]));
	assign program_error_o = route_fault_q || (program_valid_i && program_ready_o && !route_legal) || (|queue_fault);
	assign frontend_ready_o = (&queue_ready) && !fault_o;
	assign frontend_idle_o = (&queue_idle) && !(|config_valid) && !controller_busy && execution_idle;
	assign done_o = completed_q;
	assign fault_o = route_fault_q || bundle_fault_q || (|queue_fault) || controller_fault || execution_fault;
	assign command_fire = bundle_valid && bundle_legal && command_ready && run_i && !fault_o;
	assign config_pop = command_fire ? configured : 8'b0;

	// Every queue owns SRAM, prefetch, NOP cursor and absolute dispatch checks.
	for(genvar queue = 0; queue < 8; queue++)begin : gen_queue
		lpu_vxm_local_imem_frontend #(
			.QUEUE_ID(queue),
			.IMEM_DEPTH(IMEM_DEPTH)
		) u_frontend (
			.clk_i,
			.rst_ni(local_rst_n),
			.load_valid_i(program_valid_i && program_ready_o && route_legal &&
				queue_index == queue && program_control_i == PROGRAM_LOAD_WRITE),
			.load_ready_o(load_ready[queue]),
			.load_address_i(program_address_i),
			.load_data_i(program_data_i),
			.load_strb_i(program_strb_i),
			.load_last_i(program_last_i),
			.prime_valid_i(program_valid_i && program_ready_o && route_legal &&
				queue_index == queue && program_control_i == PROGRAM_LOAD_PRIME),
			.prime_ready_o(prime_ready[queue]),
			.run_i(run_i && !fault_o),
			.schedule_cycle_i,
			.issue_valid_o(dispatch_valid[queue]),
			.issue_ready_i(dispatch_ready[queue]),
			.issue_word_o(dispatch_word[queue]),
			.issue_cycle_o(dispatch_cycle[queue]),
			.configured_o(configured[queue]),
			.ready_o(queue_ready[queue]),
			.idle_o(queue_idle[queue]),
			.fault_o(queue_fault[queue])
		);

		// FU configuration buffering precedes execution, with no post-Scheduler
		// Timed Queue and no combinational issue bypass.
		lpu_fifo #(
			.DATA_WIDTH(96),
			.DEPTH(CONFIG_FIFO_DEPTH)
		) u_config_fifo (
			.clk_i,
			.rst_ni(local_rst_n),
			.enqueue_valid_i(dispatch_valid[queue]),
			.enqueue_ready_o(dispatch_ready[queue]),
			.enqueue_data_i(dispatch_word[queue]),
			.dequeue_valid_o(config_valid[queue]),
			.dequeue_ready_i(config_pop[queue]),
			.dequeue_data_o(config_word[queue]),
			.level_o()
		);

		lpu_vxm_sequential_decoder #(
			.QUEUE_ID(queue)
		) u_adapter (
			.word_i(config_word[queue]),
			.legal_o(),
			.supported_o(),
			.nop_o(),
			.nop_cycles_o(),
			.local_o(native_local[queue]),
			.global_o(native_global[queue]),
			.repeat_count_o(native_count[queue]),
			.repeat_phase_o(native_phase[queue]),
			.immediate_valid_o(native_immediate_valid[queue]),
			.immediate_o(native_immediate[queue])
		);
	end

	// ConfigLocal[q]/ConfigImmediate[q] view the flattened bundle vectors.
	// Queues dispatch independently. The scalar native ABI requires complete
	// chains, uniform Global/repeat count and matching tail phase flags.
	always_comb begin
		bundle_local = '0;
		bundle_immediate = '0;
		bundle_global = '0;
		bundle_count = '0;
		bundle_valid = (configured != 0) && ((config_valid & configured) == configured);
		have_reference = 1'b0;
		headers_match = 1'b1;
		for(integer queue = 0; queue < 8; queue++)begin
			if(configured[queue] && config_valid[queue])begin
				bundle_local[queue*7+:7] = native_local[queue];
				bundle_immediate[queue*32+:32] = native_immediate[queue];
				if(!have_reference)begin
					bundle_global = native_global[queue];
					bundle_count = native_count[queue];
					have_reference = 1'b1;
				end
				else if(native_global[queue] != bundle_global || native_count[queue] != bundle_count)begin
					headers_match = 1'b0;
				end
			end
		end
	end

	// Reject incomplete chains and incompatible shared phase flags before any
	// native configuration is committed. No consumed Local is silently reused.
	always_comb begin
		bundle_legal = headers_match;
		bundle_phase = '0;
		have_tail = 1'b0;
		chain_size = (bundle_global[13:12] == 0) ? 2 : ((bundle_global[13:12] == 1) ? 4 : 8);
		for(integer queue = 0; queue < 8; queue++)begin
			if(configured[queue])begin
				for(integer member = 0; member < 8; member++)begin
					if(member / chain_size == queue / chain_size && !configured[member])begin
						bundle_legal = 1'b0;
					end
				end
				if(queue % chain_size == chain_size-1)begin
					if(!have_tail)begin
						bundle_phase = native_phase[queue];
						have_tail = 1'b1;
					end
					else if(native_phase[queue] != bundle_phase)begin
						bundle_legal = 1'b0;
					end
				end
			end
		end
	end

	lpu_vxm_instruction_controller #(
		.REPEAT_COUNT_WIDTH(32),
		.SEQUENTIAL_PHASE(1'b1)
	) u_instruction_controller (
		.clk_i,
		.rst_ni(local_rst_n),
		.command_valid_i(command_fire),
		.command_ready_o(command_ready),
		.command_local_active_i(configured),
		.command_local_instruction_i(bundle_local),
		.command_global_config_i(bundle_global),
		.command_repeat_count_i(bundle_count),
		.command_repeat_interval_i(8'd1),
		.command_accumulator_enable_i(bundle_phase[2]),
		.command_output_enable_i(bundle_phase[3]),
		.command_repeat_phase_i(bundle_phase),
		.local_config_load_o(config_load),
		.local_config_ready_i(config_ready),
		.local_config_active_o(config_active),
		.local_config_instruction_o(config_local),
		.global_config_valid_o(),
		.global_config_o(config_global),
		.execute_valid_o(execute_valid),
		.execute_ready_i(execute_ready),
		.repeat_control_o(repeat_phase),
		.config_done_i(execution_idle),
		.busy_o(controller_busy),
		.done_o(controller_done),
		.fault_o(controller_fault)
	);

	// Only the controller creates Execute; a configuration load has no implicit
	// execution side effect. All four rows must drain before command retirement.
	lpu_vxm_slice u_execution (
		.clk_i,
		.rst_ni(local_rst_n),
		.run_i(run_i && !fault_o),
		.local_issue_valid_i(config_active),
		.local_issue_instruction_i(config_local),
		.global_issue_valid_i(config_load && config_ready),
		.global_issue_instruction_i(config_global),
		.config_ready_o(config_ready),
		.execute_valid_i(execute_valid && run_i && !fault_o),
		.execute_ready_o(execute_ready),
		.repeat_control_i(repeat_phase),
		.immediate_valid_i(command_immediate_valid_q),
		.immediate_data_i(command_immediate_q),
		.idle_o(execution_idle),
		.lut_config_valid_i(1'b0),
		.lut_config_bank_i('0),
		.lut_config_input_min_i('0),
		.lut_config_segment_width_i('0),
		.lut_write_valid_i(1'b0),
		.lut_write_bank_i('0),
		.lut_write_address_i('0),
		.lut_write_k_i('0),
		.lut_write_b_i('0),
		.lut_write_log_i('0),
		.west_from_mem_valid_i,
		.west_from_mem_data_i,
		.external_east_valid_i,
		.external_east_data_i,
		.east_to_mem_valid_o,
		.east_to_mem_data_o,
		.fault_o(execution_fault),
		.conflict_o
	);

	// Capture only accepted immediates; failures require reset/reload. An empty
	// or exhausted partner queue cannot silently reuse its previous Local word.
	always_ff @(posedge clk_i or negedge local_rst_n) begin
		if(!local_rst_n)begin
			route_fault_q <= 0;
			bundle_fault_q <= 0;
			command_immediate_q <= 0;
			command_immediate_valid_q <= 0;
			completed_q <= 0;
		end
		else begin
			if(execution_fault || controller_fault)begin
				bundle_fault_q <= 1;
			end
			if(program_valid_i && program_ready_o && !route_legal)begin
				route_fault_q <= 1;
			end
			if(run_i && bundle_valid && !bundle_legal)begin
				bundle_fault_q <= 1;
			end
			if(run_i && |config_valid)begin
				for(integer queue = 0; queue < 8; queue++)begin
					if(configured[queue] && queue_idle[queue] && !config_valid[queue])begin
						bundle_fault_q <= 1;
					end
				end
			end
			if(command_fire)begin
				command_immediate_q <= bundle_immediate;
				command_immediate_valid_q <= native_immediate_valid & configured;
			end
			if(run_i && frontend_idle_o && !fault_o)begin
				completed_q <= 1;
			end
		end
	end
endmodule
