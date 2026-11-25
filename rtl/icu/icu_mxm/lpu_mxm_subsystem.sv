module lpu_mxm_subsystem #(
	parameter integer HEMISPHERE_INDEX = lpu_program_load_pkg::PROGRAM_HEMISPHERE_EAST,
	parameter integer LOCAL_MXM_INDEX = 0,
	parameter integer IMEM_DEPTH = 65536,
	parameter integer ACTIVE_CONTEXTS = 4,
	parameter bit PAIR_LOAD_DEQUANT = 1'b0,
	parameter integer QCTL_QUEUE_ENTRY_LIMIT = 16,
	parameter integer QCTL_GENERATION_WIDTH = 64,
	parameter integer QCTL_ENTRY_INDEX_WIDTH = QCTL_QUEUE_ENTRY_LIMIT <= 1 ? 1 : $clog2(QCTL_QUEUE_ENTRY_LIMIT),
	parameter integer QCTL_ENTRY_COUNT_WIDTH = $clog2(QCTL_QUEUE_ENTRY_LIMIT + 1)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic program_reset_i,
	input logic local_frontend_enable_i,
	input logic run_i,
	input logic [31:0] schedule_cycle_i,
	input logic [4:0] qctl_configure_valid_i,
	input logic [5*QCTL_ENTRY_COUNT_WIDTH-1:0] qctl_configure_count_i,
	input logic [5*QCTL_GENERATION_WIDTH-1:0] qctl_configure_generation_i,
	output logic [5*QCTL_ENTRY_INDEX_WIDTH-1:0] qctl_head_index_o,
	output logic [5*QCTL_GENERATION_WIDTH-1:0] qctl_head_generation_o,
	input logic [4:0] qctl_store_loaded_i,
	input logic [4:0] qctl_head_valid_i,
	input logic [5*lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] qctl_head_record_i,
	input logic [4:0] qctl_head_error_i,
	input logic [4:0] qctl_event_valid_i,
	input logic [lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] qctl_event_tag_i,
	output logic [4:0] qctl_event_wait_o,
	output logic [4:0] qctl_event_consume_o,
	output logic [4:0] qctl_sync_arrive_valid_o,
	input logic [4:0] qctl_sync_release_valid_i,
	output logic [4:0] qctl_notify_valid_o,
	input logic [4:0] qctl_notify_ready_i,
	output logic [4:0] qctl_mem_packet_valid_o,
	output logic [5*lpu_qctl_pkg::QCTL_OPERAND_WIDTH-1:0] qctl_mem_packet_ordinal_o,
	input logic [4:0] qctl_mem_packet_retired_i,
	output logic [4:0] qctl_configured_o,
	output logic [4:0] qctl_primed_o,
	output logic [4:0] qctl_done_o,
	output logic [4:0] qctl_fault_o,
	output logic [5*4-1:0] qctl_fault_code_o,
	input logic program_valid_i,
	output logic program_ready_o,
	input logic [lpu_program_load_pkg::PROGRAM_LOAD_CONTROL_WIDTH-1:0] program_control_i,
	input logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0] program_destination_i,
	input logic [16:0] program_address_i,
	input logic [127:0] program_data_i,
	input logic [3:0] program_strb_i,
	input logic program_last_i,
	output logic program_error_o,
	input logic external_load_valid_i,
	input logic [47:0] external_load_instruction_i,
	input logic external_dequant_valid_i,
	input logic [15:0] external_dequant_instruction_i,
	input logic external_compute_valid_i,
	input logic [47:0] external_compute_instruction_i,
	output logic local_load_issue_valid_o,
	output logic [lpu_mxm_isa_pkg::LOAD_INSTRUCTION_BITS-1:0] local_load_issue_instruction_o,
	output logic [31:0] local_load_issue_cycle_o,
	output logic local_dequant_issue_valid_o,
	output logic [lpu_mxm_isa_pkg::DEQUANT_INSTRUCTION_BITS-1:0] local_dequant_issue_instruction_o,
	output logic [31:0] local_dequant_issue_cycle_o,
	output logic local_compute_issue_valid_o,
	output logic [lpu_mxm_isa_pkg::COMPUTE_INSTRUCTION_BITS-1:0] local_compute_issue_instruction_o,
	output logic [31:0] local_compute_issue_cycle_o,
	output logic local_param_load_issue_valid_o,
	output logic [lpu_mxm_isa_pkg::PARAM_LOAD_INSTRUCTION_BITS-1:0] local_param_load_issue_instruction_o,
	output logic [31:0] local_param_load_issue_cycle_o,
	output logic local_backend_issue_valid_o,
	output logic [lpu_mxm_backend_isa_pkg::BACKEND_INSTRUCTION_BITS-1:0] local_backend_issue_instruction_o,
	output logic [31:0] local_backend_issue_cycle_o,
	output logic frontends_ready_o,
	output logic frontends_idle_o,
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
	import lpu_program_load_pkg::*;
	import lpu_mxm_isa_pkg::*;
	localparam integer STREAM_COUNT = MXM_QUEUE_COUNT;
	localparam integer ROWS = lpu_mxm_config_pkg::SC_ROWS;
	localparam integer TERMS = lpu_mxm_config_pkg::CELL_K;
	localparam integer OUTPUTS = lpu_mxm_config_pkg::CELL_N;
	localparam integer WEIGHT_STREAMS = lpu_mxm_config_pkg::WEIGHT_STREAM_COUNT;
	logic [PROGRAM_TARGET_KIND_WIDTH-1:0] program_target_kind_w;
	logic [7:0] program_target_index_w;
	logic destination_legal_w,write_fire_w,prime_fire_w,frontend_rst_ni;
	logic [STREAM_COUNT-1:0] frontend_run,frontend_load_ready,frontend_prime_ready;
	logic [STREAM_COUNT-1:0] frontend_ready,frontend_idle,frontend_fault;
	logic [STREAM_COUNT-1:0] frontend_issue_valid,frontend_issue_ready;
	logic [STREAM_COUNT*32-1:0] frontend_schedule_cycle,frontend_issue_cycle,qctl_scheduler_cycle_q;
	logic [STREAM_COUNT*6-1:0] frontend_fault_code;
	logic [STREAM_COUNT*49-1:0] frontend_issue_instruction;
	logic [STREAM_COUNT-1:0] qctl_scheduler_counter_ce;
	logic load_core_ready,dequant_core_ready,compute_core_ready,param_core_ready,backend_core_ready;
	logic pair_mismatch_w;
	logic [ROWS-1:0] activation_valid,returned_valid;
	logic [ROWS*TERMS*16-1:0] activation_data;
	logic [ROWS*WEIGHT_STREAMS*TERMS-1:0] weight_valid;
	logic [ROWS*WEIGHT_STREAMS*TERMS*8-1:0] weight_data;
	logic [ROWS*OUTPUTS*32-1:0] returned_data;
	logic core_fault;
	logic unused_external;
	integer program_stream_index;
	integer fault_stream_index;
	integer data_row_index,data_stream_index,data_term_index;
	integer output_row_index,output_stream_index;

	function automatic integer stream_target_kind(input integer stream);
		case(stream)
			MXM_QUEUE_LOAD: stream_target_kind = PROGRAM_TARGET_MXM_LOAD;
			MXM_QUEUE_COMPUTE: stream_target_kind = PROGRAM_TARGET_MXM_COMPUTE;
			MXM_QUEUE_DEQUANT: stream_target_kind = PROGRAM_TARGET_MXM_DEQUANT;
			MXM_QUEUE_PARAM_LOAD: stream_target_kind = PROGRAM_TARGET_MXM_PARAM_LOAD;
			default: stream_target_kind = PROGRAM_TARGET_MXM_BACKEND;
		endcase
	endfunction

	assign program_target_kind_w = program_destination_i[PROGRAM_DESTINATION_KIND_MSB:PROGRAM_DESTINATION_KIND_LSB];
	assign program_target_index_w = program_destination_i[PROGRAM_DESTINATION_INDEX_MSB:PROGRAM_DESTINATION_INDEX_LSB];
	assign destination_legal_w =
		(program_destination_i[PROGRAM_DESTINATION_HEMISPHERE_BIT] == HEMISPHERE_INDEX) &&
		(program_target_index_w == LOCAL_MXM_INDEX) &&
		((program_target_kind_w == PROGRAM_TARGET_MXM_LOAD) ||
		 (program_target_kind_w == PROGRAM_TARGET_MXM_DEQUANT) ||
		 (program_target_kind_w == PROGRAM_TARGET_MXM_COMPUTE) ||
		 (program_target_kind_w == PROGRAM_TARGET_MXM_PARAM_LOAD) ||
		 (program_target_kind_w == PROGRAM_TARGET_MXM_BACKEND));
	assign write_fire_w = program_valid_i && program_ready_o &&
		(program_control_i == PROGRAM_LOAD_WRITE) && destination_legal_w &&
		(program_strb_i == 4'b1111) && (program_address_i < IMEM_DEPTH);
	assign prime_fire_w = program_valid_i && program_ready_o &&
		(program_control_i == PROGRAM_LOAD_PRIME) && destination_legal_w;
	assign frontend_rst_ni = rst_ni && !program_reset_i;

	// Each Stream owns one QCTL endpoint and one pauseable local Schedule Cycle.
	generate
		for(genvar qctl_stream = 0; qctl_stream < STREAM_COUNT; qctl_stream++)begin : gen_qctl_stream
			assign frontend_run[qctl_stream] = local_frontend_enable_i &&
				(qctl_configured_o[qctl_stream] ? qctl_scheduler_counter_ce[qctl_stream] : run_i);
			assign frontend_schedule_cycle[qctl_stream*32+:32] = qctl_configured_o[qctl_stream] ?
				qctl_scheduler_cycle_q[qctl_stream*32+:32] : schedule_cycle_i;
			lpu_qctl_endpoint #(
				.QUEUE_ENTRY_LIMIT(QCTL_QUEUE_ENTRY_LIMIT), .GENERATION_WIDTH(QCTL_GENERATION_WIDTH)
			) u_qctl_endpoint (
				.clk_i, .rst_ni, .clear_i(program_reset_i), .run_i(run_i),
				.configure_valid_i(qctl_configure_valid_i[qctl_stream]),
				.configure_count_i(qctl_configure_count_i[qctl_stream*QCTL_ENTRY_COUNT_WIDTH+:QCTL_ENTRY_COUNT_WIDTH]),
				.configure_generation_i(qctl_configure_generation_i[qctl_stream*QCTL_GENERATION_WIDTH+:QCTL_GENERATION_WIDTH]),
				.store_head_index_o(qctl_head_index_o[qctl_stream*QCTL_ENTRY_INDEX_WIDTH+:QCTL_ENTRY_INDEX_WIDTH]),
				.store_head_generation_o(qctl_head_generation_o[qctl_stream*QCTL_GENERATION_WIDTH+:QCTL_GENERATION_WIDTH]),
				.store_loaded_i(qctl_store_loaded_i[qctl_stream]), .store_head_valid_i(qctl_head_valid_i[qctl_stream]),
				.store_head_record_i(qctl_head_record_i[qctl_stream*lpu_qctl_pkg::QCTL_RECORD_WIDTH+:lpu_qctl_pkg::QCTL_RECORD_WIDTH]),
				.store_head_error_i(qctl_head_error_i[qctl_stream]),
				.scheduler_cycle_i(qctl_scheduler_cycle_q[qctl_stream*32+:32]),
				.scheduler_counter_ce_o(qctl_scheduler_counter_ce[qctl_stream]),
				.event_valid_i(qctl_event_valid_i[qctl_stream]), .event_tag_i(qctl_event_tag_i),
				.event_wait_o(qctl_event_wait_o[qctl_stream]), .event_consume_o(qctl_event_consume_o[qctl_stream]),
				.sync_arrive_valid_o(qctl_sync_arrive_valid_o[qctl_stream]),
				.sync_release_valid_i(qctl_sync_release_valid_i[qctl_stream]),
				.notify_valid_o(qctl_notify_valid_o[qctl_stream]), .notify_ready_i(qctl_notify_ready_i[qctl_stream]),
				.mem_packet_valid_o(qctl_mem_packet_valid_o[qctl_stream]),
				.mem_packet_ordinal_o(qctl_mem_packet_ordinal_o[qctl_stream*lpu_qctl_pkg::QCTL_OPERAND_WIDTH+:lpu_qctl_pkg::QCTL_OPERAND_WIDTH]),
				.mem_packet_retired_i(qctl_mem_packet_retired_i[qctl_stream]),
				.configured_o(qctl_configured_o[qctl_stream]), .primed_o(qctl_primed_o[qctl_stream]),
				.done_o(qctl_done_o[qctl_stream]), .fault_o(qctl_fault_o[qctl_stream]),
				.fault_code_o(qctl_fault_code_o[qctl_stream*4+:4])
			);
			always_ff @(posedge clk_i or negedge rst_ni) begin
				if(!rst_ni) qctl_scheduler_cycle_q[qctl_stream*32+:32] <= '0;
				else if(program_reset_i || qctl_configure_valid_i[qctl_stream])begin
					qctl_scheduler_cycle_q[qctl_stream*32+:32] <= '0;
				end
				else if(qctl_configured_o[qctl_stream] && qctl_scheduler_counter_ce[qctl_stream])begin
					qctl_scheduler_cycle_q[qctl_stream*32+:32] <=
						qctl_scheduler_cycle_q[qctl_stream*32+:32] + 1'b1;
				end
			end
		end
	endgenerate

	// Five Local iMEM Frontends share implementation, not storage or parser state.
	generate
		for(genvar frontend_stream = 0; frontend_stream < STREAM_COUNT; frontend_stream++)begin : gen_frontend
			localparam integer TARGET_KIND = stream_target_kind(frontend_stream);
			lpu_mxm_local_imem_frontend #(
				.TARGET_KIND(TARGET_KIND), .IMEM_DEPTH(IMEM_DEPTH), .ACTIVE_CONTEXTS(ACTIVE_CONTEXTS)
			) u_frontend (
				.clk_i, .rst_ni, .program_reset_i, .clear_i(1'b0),
				.load_valid_i(write_fire_w && (program_target_kind_w == TARGET_KIND)),
				.load_ready_o(frontend_load_ready[frontend_stream]), .load_address_i(program_address_i),
				.load_data_i(program_data_i), .load_strb_i(program_strb_i), .load_last_i(program_last_i),
				.prime_valid_i(prime_fire_w && (program_target_kind_w == TARGET_KIND)),
				.prime_ready_o(frontend_prime_ready[frontend_stream]),
				.run_i(frontend_run[frontend_stream]),
				.schedule_cycle_i(frontend_schedule_cycle[frontend_stream*32+:32]),
				.issue_valid_o(frontend_issue_valid[frontend_stream]),
				.issue_ready_i(frontend_issue_ready[frontend_stream]),
				.issue_instruction_o(frontend_issue_instruction[frontend_stream*49+:49]),
				.issue_cycle_o(frontend_issue_cycle[frontend_stream*32+:32]),
				.configured_o(), .frontend_ready_o(frontend_ready[frontend_stream]),
				.frontend_idle_o(frontend_idle[frontend_stream]),
				.fault_o(frontend_fault[frontend_stream]),
				.fault_code_o(frontend_fault_code[frontend_stream*6+:6])
			);
		end
	endgenerate

	// Program writes and PRIME commands terminate at exactly one selected Stream.
	always_comb begin
		program_ready_o = 1'b1;
		program_stream_index = MXM_QUEUE_LOAD;
		if(destination_legal_w)begin
			case(program_target_kind_w)
				PROGRAM_TARGET_MXM_LOAD: program_stream_index = MXM_QUEUE_LOAD;
				PROGRAM_TARGET_MXM_COMPUTE: program_stream_index = MXM_QUEUE_COMPUTE;
				PROGRAM_TARGET_MXM_DEQUANT: program_stream_index = MXM_QUEUE_DEQUANT;
				PROGRAM_TARGET_MXM_PARAM_LOAD: program_stream_index = MXM_QUEUE_PARAM_LOAD;
				default: program_stream_index = MXM_QUEUE_BACKEND;
			endcase
			program_ready_o = program_control_i == PROGRAM_LOAD_PRIME ?
				frontend_prime_ready[program_stream_index] : frontend_load_ready[program_stream_index];
		end
		program_error_o = program_valid_i && program_ready_o &&
			(!destination_legal_w || ((program_control_i == PROGRAM_LOAD_WRITE) &&
			((program_strb_i != 4'b1111) || (program_address_i >= IMEM_DEPTH))));
	end

	assign frontends_ready_o = &frontend_ready;
	assign frontends_idle_o = &frontend_idle;
	assign frontend_fault_o = |frontend_fault;
	always_comb begin
		frontend_fault_code_o = '0;
		for(fault_stream_index = 0; fault_stream_index < STREAM_COUNT; fault_stream_index = fault_stream_index + 1)begin
			if(frontend_fault[fault_stream_index] && (frontend_fault_code_o == '0))begin
				frontend_fault_code_o = frontend_fault_code[fault_stream_index*6+:6];
			end
		end
	end

	assign local_load_issue_valid_o = frontend_issue_valid[MXM_QUEUE_LOAD];
	assign local_load_issue_instruction_o = frontend_issue_instruction[MXM_QUEUE_LOAD*49+:LOAD_INSTRUCTION_BITS];
	assign local_load_issue_cycle_o = frontend_issue_cycle[MXM_QUEUE_LOAD*32+:32];
	assign local_compute_issue_valid_o = frontend_issue_valid[MXM_QUEUE_COMPUTE];
	assign local_compute_issue_instruction_o = frontend_issue_instruction[MXM_QUEUE_COMPUTE*49+:COMPUTE_INSTRUCTION_BITS];
	assign local_compute_issue_cycle_o = frontend_issue_cycle[MXM_QUEUE_COMPUTE*32+:32];
	assign local_dequant_issue_valid_o = frontend_issue_valid[MXM_QUEUE_DEQUANT];
	assign local_dequant_issue_instruction_o = frontend_issue_instruction[MXM_QUEUE_DEQUANT*49+:DEQUANT_INSTRUCTION_BITS];
	assign local_dequant_issue_cycle_o = frontend_issue_cycle[MXM_QUEUE_DEQUANT*32+:32];
	assign local_param_load_issue_valid_o = frontend_issue_valid[MXM_QUEUE_PARAM_LOAD];
	assign local_param_load_issue_instruction_o = frontend_issue_instruction[MXM_QUEUE_PARAM_LOAD*49+:PARAM_LOAD_INSTRUCTION_BITS];
	assign local_param_load_issue_cycle_o = frontend_issue_cycle[MXM_QUEUE_PARAM_LOAD*32+:32];
	assign local_backend_issue_valid_o = frontend_issue_valid[MXM_QUEUE_BACKEND];
	assign local_backend_issue_instruction_o = frontend_issue_instruction[MXM_QUEUE_BACKEND*49+:lpu_mxm_backend_isa_pkg::BACKEND_INSTRUCTION_BITS];
	assign local_backend_issue_cycle_o = frontend_issue_cycle[MXM_QUEUE_BACKEND*32+:32];

	// Optional Load/Dequant pairing is atomic; unmatched deadlines raise Scheduler faults.
	assign pair_mismatch_w = PAIR_LOAD_DEQUANT &&
		(frontend_issue_valid[MXM_QUEUE_LOAD] ^ frontend_issue_valid[MXM_QUEUE_DEQUANT]);
	assign frontend_issue_ready[MXM_QUEUE_LOAD] = PAIR_LOAD_DEQUANT ?
		(frontend_issue_valid[MXM_QUEUE_DEQUANT] && load_core_ready && dequant_core_ready) : load_core_ready;
	assign frontend_issue_ready[MXM_QUEUE_DEQUANT] = PAIR_LOAD_DEQUANT ?
		(frontend_issue_valid[MXM_QUEUE_LOAD] && load_core_ready && dequant_core_ready) : dequant_core_ready;
	assign frontend_issue_ready[MXM_QUEUE_COMPUTE] = compute_core_ready;
	assign frontend_issue_ready[MXM_QUEUE_PARAM_LOAD] = param_core_ready;
	assign frontend_issue_ready[MXM_QUEUE_BACKEND] = backend_core_ready;

	// Existing 64-bit byte Streams feed the new Core without changing the network width.
	always_comb begin
		activation_valid = '0;
		activation_data = '0;
		weight_valid = '0;
		weight_data = east_from_sxm_data_i;
		for(data_row_index = 0; data_row_index < ROWS; data_row_index = data_row_index + 1)begin
			activation_valid[data_row_index] = external_west_valid_i[data_row_index*32] &&
				external_west_valid_i[data_row_index*32+1];
			activation_data[data_row_index*TERMS*16+:TERMS*16] = {
				external_west_data_i[(data_row_index*32+1)*64+:64],
				external_west_data_i[(data_row_index*32)*64+:64]};
			for(data_stream_index = 0; data_stream_index < WEIGHT_STREAMS; data_stream_index = data_stream_index + 1)begin
				for(data_term_index = 0; data_term_index < TERMS; data_term_index = data_term_index + 1)begin
					weight_valid[(data_row_index*WEIGHT_STREAMS+data_stream_index)*TERMS+data_term_index] =
						east_from_sxm_valid_i[data_row_index*32+data_stream_index];
				end
			end
		end
	end

	// Scheduler outputs enter the existing Instruction Waves through same-cycle bypasses.
	lpu_mxm_core u_execution (
		.clk_i, .rst_ni(frontend_rst_ni), .run_i(run_i),
		.compute_enqueue_valid_i(frontend_issue_valid[MXM_QUEUE_COMPUTE]),
		.compute_launch_i(frontend_issue_valid[MXM_QUEUE_COMPUTE]),
		.compute_instruction_i(compute_instruction_t'(local_compute_issue_instruction_o)),
		.compute_enqueue_ready_o(), .compute_launch_ready_o(compute_core_ready),
		.load_enqueue_valid_i(frontend_issue_valid[MXM_QUEUE_LOAD]),
		.load_launch_i(frontend_issue_valid[MXM_QUEUE_LOAD]),
		.load_instruction_i(load_instruction_t'(local_load_issue_instruction_o)),
		.load_enqueue_ready_o(), .load_launch_ready_o(load_core_ready),
		.param_load_enqueue_valid_i(frontend_issue_valid[MXM_QUEUE_PARAM_LOAD]),
		.param_load_launch_i(frontend_issue_valid[MXM_QUEUE_PARAM_LOAD]),
		.param_load_instruction_i(param_load_instruction_t'(local_param_load_issue_instruction_o)),
		.param_load_enqueue_ready_o(), .param_load_launch_ready_o(param_core_ready),
		.dequant_enqueue_valid_i(frontend_issue_valid[MXM_QUEUE_DEQUANT]),
		.dequant_launch_i(frontend_issue_valid[MXM_QUEUE_DEQUANT]),
		.dequant_instruction_i(dequant_instruction_t'(local_dequant_issue_instruction_o)),
		.dequant_enqueue_ready_o(), .dequant_launch_ready_o(dequant_core_ready),
		.backend_enqueue_valid_i(frontend_issue_valid[MXM_QUEUE_BACKEND]),
		.backend_launch_i(frontend_issue_valid[MXM_QUEUE_BACKEND]),
		.backend_instruction_i(lpu_mxm_backend_isa_pkg::backend_instruction_t'(local_backend_issue_instruction_o)),
		.backend_enqueue_ready_o(), .backend_launch_ready_o(backend_core_ready),
		.activation_valid_i(activation_valid), .activation_i(activation_data),
		.weight_stream_valid_i(weight_valid), .weight_stream_i(weight_data), .weight_stream_consume_o(),
		.returned_valid_o(returned_valid), .returned_o(returned_data), .returned_tag_o(),
		.param_load_row_valid_o(), .dequant_row_valid_o(), .param_load_row_instruction_o(),
		.dequant_row_instruction_o(), .compute_row_valid_o(), .load_row_valid_o(),
		.compute_row_instruction_o(), .load_row_instruction_o(), .compute_row_tag_o(), .load_row_index_o(),
		.partial_valid_o(), .result_valid_o(), .result_bf16_o(), .partial_o(), .result_o(),
		.partial_tag_o(), .result_address_o(), .result_tag_o(), .backend_slot_valid_o(),
		.backend_slot_bf16_o(), .backend_slot_operation_o(), .backend_slot_address_o(),
		.backend_issue_valid_o(), .backend_issue_bf16_o(), .backend_issue_address_o(),
		.backend_issue_operation_o(), .alu_valid_o(), .operand_a_o(), .operand_b_o(),
		.alu_address_o(), .alu_tag_o(), .cell_weight_valid_o(), .cell_weight_buffer_o(),
		.cell_activation_valid_o(), .cell_activation_buffer_o(), .bank_request_valid_o(),
		.bank_write_o(), .bank_address_o(), .frontend_fault_o(), .backend_fault_o(), .fault_o(core_fault)
	);

	// Returned FP32 vectors occupy four 64-bit westbound Streams per Superlane.
	always_comb begin
		east_external_valid_o = '0;
		east_external_data_o = '0;
		west_to_sxm_valid_o = '0;
		west_to_sxm_data_o = '0;
		for(output_row_index = 0; output_row_index < ROWS; output_row_index = output_row_index + 1)begin
			for(output_stream_index = 0; output_stream_index < 4; output_stream_index = output_stream_index + 1)begin
				west_to_sxm_valid_o[output_row_index*32+output_stream_index] = returned_valid[output_row_index];
				west_to_sxm_data_o[(output_row_index*32+output_stream_index)*64+:64] =
					returned_data[output_row_index*OUTPUTS*32+output_stream_index*64+:64];
			end
		end
	end

	assign fault_o = core_fault || frontend_fault_o || (|qctl_fault_o) || pair_mismatch_w;
	assign conflict_o = pair_mismatch_w;
	assign unused_external = external_load_valid_i ^ external_dequant_valid_i ^ external_compute_valid_i ^
		(^external_load_instruction_i) ^ (^external_dequant_instruction_i) ^ (^external_compute_instruction_i);
endmodule
