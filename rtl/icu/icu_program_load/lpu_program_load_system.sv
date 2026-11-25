// Program Load System owns command sequencing, DMA response reassembly and
// Program Word/PRIME ordering. Physical destination routing belongs to the
// downstream Program Distribute System.
module lpu_program_load_system #(
	parameter integer COMMAND_DEPTH = 32,
	parameter integer DMA_DATA_WIDTH = 256,
	parameter integer MEM_IMEM_DEPTH = 131072,
	parameter integer MXM_IMEM_DEPTH = 65536,
	parameter integer VXM_IMEM_DEPTH = 256,
	parameter integer COMMAND_ADDRESS_WIDTH = COMMAND_DEPTH <= 1 ? 1 : $clog2(COMMAND_DEPTH)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic program_reset_i,

	// A LOAD_IMEM command carries the ProgramImage descriptor. Other opcodes sequence the request.
	input logic program_cmd_write_valid_i,
	output logic program_cmd_write_ready_o,
	input logic [COMMAND_ADDRESS_WIDTH-1:0] program_cmd_write_address_i,
	input logic [2:0] program_cmd_write_opcode_i,
	input logic [63:0] program_cmd_write_source_address_i,
	input logic [31:0] program_cmd_write_byte_count_i,
	input logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		program_cmd_write_destination_i,
	input logic [1:0] program_cmd_write_format_i,
	input logic [1:0] program_cmd_write_encoding_mode_i,
	input logic [16:0] program_cmd_write_imem_base_address_i,
	input logic program_cmd_write_image_first_i,
	input logic program_cmd_write_image_last_i,
	input logic [15:0] program_cmd_write_expected_word_count_i,
	input logic [COMMAND_ADDRESS_WIDTH-1:0] program_cmd_write_jump_address_i,

	input logic program_load_start_valid_i,
	output logic program_load_start_ready_o,
	input logic [COMMAND_ADDRESS_WIDTH:0] program_load_start_command_count_i,

	// External DDR/C2C fabric boundary. The RTL owns request ordering and response reassembly.
	output logic ddr_read_req_valid_o,
	input logic ddr_read_req_ready_i,
	output logic [63:0] ddr_read_req_address_o,
	output logic [31:0] ddr_read_req_length_o,
	output logic [7:0] ddr_read_req_id_o,
	input logic ddr_read_rsp_valid_i,
	output logic ddr_read_rsp_ready_o,
	input logic [DMA_DATA_WIDTH-1:0] ddr_read_rsp_data_i,
	input logic [DMA_DATA_WIDTH/8-1:0] ddr_read_rsp_keep_i,
	input logic ddr_read_rsp_last_i,
	input logic [7:0] ddr_read_rsp_id_i,
	input logic ddr_read_rsp_error_i,

	input logic program_start_request_i,
	input logic dependencies_ready_i,
	output logic program_start_ack_o,
	output logic program_load_complete_o,
	output logic program_ready_o,
	output logic program_running_o,
	output logic program_done_o,
	output logic program_fault_o,
	output logic [5:0] program_fault_code_o,
	output logic [31:0] schedule_cycle_o,

	// One normalized Record crosses the Load/Distribute architectural boundary.
	output logic load_distribute_valid_o,
	input logic load_distribute_ready_i,
	output logic [lpu_program_load_pkg::PROGRAM_LOAD_CONTROL_WIDTH-1:0] load_distribute_control_o,
	output logic [127:0] load_distribute_data_o,
	output logic [3:0] load_distribute_strb_o,
	output logic [1:0] load_distribute_scope_o,
	output logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		load_distribute_destination_o,
	output logic [16:0] load_distribute_imem_address_o,
	output logic load_distribute_last_o,
	input logic load_distribute_idle_i,
	input logic load_distribute_fault_i,
	input logic [5:0] load_distribute_fault_code_i,
	output logic fu_cluster_program_start_o,
	input logic fu_cluster_program_start_ready_i,
	input logic fu_cluster_started_i,
	input logic fu_cluster_frontends_ready_i,
	input logic fu_cluster_frontends_idle_i,
	input logic fu_cluster_fault_i,
	input logic [5:0] fu_cluster_fault_code_i,
	input logic [31:0] fu_cluster_schedule_cycle_i
);
	import lpu_program_load_pkg::*;

	// MEM/MXM use Macro images; SXM CTRL/EXEC use native two-word events.
	localparam logic [1:0] PROGRAM_ENCODING_MACRO = 2'd0;
	localparam logic [1:0] PROGRAM_ENCODING_NATIVE = 2'd1;
	localparam logic [5:0] FRONTEND_FAULT_OFFSET = 6'd16;

	logic [1:0] command_scope_w;
	logic [PROGRAM_TARGET_KIND_WIDTH-1:0] command_target_kind_w;
	logic [7:0] command_target_index_w;
	logic [7:0] command_global_target_w;
	logic command_target_legal_w;
	logic program_cmd_write_fire;
	logic descriptor_illegal_w;
	logic command_is_sxm_w;
	logic [1:0] sxm_ctrl_target_seen_q, sxm_exec_target_seen_q;
	logic [7:0] vxm_target_seen_q;
	logic descriptor_duplicate_w;
	logic descriptor_fault_q;

	logic [lpu_pkg::MEM_BANK_COUNT-1:0] mem_target_seen_q;
	logic [3:0] mxm_load_target_seen_q;
	logic [3:0] mxm_dequant_target_seen_q;
	logic [3:0] mxm_compute_target_seen_q;
	logic [3:0] mxm_param_load_target_seen_q;
	logic [3:0] mxm_backend_target_seen_q;

	logic instruction_load_done;
	logic loader_program_start;
	logic loader_program_cmd_write_ready;
	logic loader_start_ready;
	logic loader_error;
	logic [5:0] loader_error_code;
	logic cluster_start_ready;
	logic cluster_started;
	logic cluster_frontends_ready;
	logic cluster_frontends_idle;
	logic cluster_fault;
	logic [5:0] cluster_fault_code;
	logic start_pending_q;
	logic load_request_active_q;
	logic program_done_q;
	logic internal_rst_ni;

	// Command Sequencer transaction and control-command outputs.
	logic ctrl_load_txn_valid;
	logic ctrl_load_txn_ready;
	logic [63:0] ctrl_load_txn_source_address;
	logic [31:0] ctrl_load_txn_byte_count;
	logic [1:0] ctrl_load_txn_scope;
	logic [PROGRAM_DESTINATION_WIDTH-1:0] ctrl_load_txn_destination;
	logic [1:0] ctrl_load_txn_format;
	logic [16:0] ctrl_load_txn_imem_base_address;
	logic ctrl_load_txn_image_first;
	logic ctrl_load_txn_image_last;
	logic [15:0] ctrl_load_txn_expected_word_count;
	logic [7:0] ctrl_load_txn_dma_id;
	logic ctrl_prime_valid;
	logic ctrl_prime_ready;
	logic [1:0] ctrl_prime_scope;
	logic [PROGRAM_DESTINATION_WIDTH-1:0] ctrl_prime_destination;
	logic command_done;
	logic command_fault;
	logic [5:0] command_fault_code;

	// Program Load Path emits complete Words for the unified Distribution boundary.
	logic load_word_valid;
	logic load_word_ready;
	logic [127:0] load_word_data;
	logic [3:0] load_word_strb;
	logic [1:0] load_word_scope;
	logic [PROGRAM_DESTINATION_WIDTH-1:0] load_word_destination;
	logic [16:0] load_word_imem_address;
	logic load_word_last;
	logic load_path_idle;
	logic load_path_fault;
	logic [5:0] load_path_fault_code;

	// PRIME descriptors are retained by the lifecycle controller until all
	// Program Words and matching WRITE acknowledgements have retired.
	logic prime_enqueue_valid;
	logic prime_enqueue_ready;
	logic [13:0] prime_enqueue_data;
	logic prime_dequeue_valid;
	logic prime_dequeue_ready;
	logic [13:0] prime_dequeue_data;
	logic [1:0] prime_dequeue_scope;
	logic [PROGRAM_DESTINATION_WIDTH-1:0] prime_dequeue_destination;
	logic [$clog2(32+1)-1:0] prime_fifo_level;
	logic prime_select_w;

	logic load_pipeline_idle_w;
	logic instruction_load_done_q;
	logic controller_fault_q;
	logic [5:0] controller_fault_code_q;

	initial begin
		if(MEM_IMEM_DEPTH > 131072)begin
			$error("MEM subsystem iMEM exceeds the 17-bit Program Load address contract");
		end
		if(MXM_IMEM_DEPTH > 65536)begin
			$error("MXM subsystem iMEM exceeds the CMODEL capacity");
		end
	end

	assign internal_rst_ni = rst_ni && !program_reset_i;

	// Extract the physical endpoint namespace before validating and mapping the target.
	assign command_scope_w = program_cmd_write_destination_i[PROGRAM_DESTINATION_HEMISPHERE_BIT] ?
		PROGRAM_SCOPE_WEST : PROGRAM_SCOPE_EAST;
	assign command_target_kind_w = program_cmd_write_destination_i[
		PROGRAM_DESTINATION_KIND_MSB:PROGRAM_DESTINATION_KIND_LSB];
	assign command_target_index_w = program_cmd_write_destination_i[
		PROGRAM_DESTINATION_INDEX_MSB:PROGRAM_DESTINATION_INDEX_LSB];

	// Target validation checks the Queue-local index against the selected FU class.
	always_comb begin
		command_target_legal_w = 1'b0;
		case(command_target_kind_w)
			PROGRAM_TARGET_MEM: command_target_legal_w =
				command_target_index_w < lpu_pkg::MEM_BANKS_PER_HEMISPHERE;
			PROGRAM_TARGET_MXM_LOAD,
			PROGRAM_TARGET_MXM_DEQUANT,
			PROGRAM_TARGET_MXM_COMPUTE,
			PROGRAM_TARGET_MXM_PARAM_LOAD,
			PROGRAM_TARGET_MXM_BACKEND: command_target_legal_w = command_target_index_w < 8'd2;
			PROGRAM_TARGET_VXM: command_target_legal_w = command_target_index_w < 8;
			PROGRAM_TARGET_SXM_TRANSPOSE,
			PROGRAM_TARGET_SXM_PERMUTE: command_target_legal_w = command_target_index_w == 0;
			default: command_target_legal_w = 1'b0;
		endcase
	end

	// Global target mapping adds the West offset only for a legal MEM or MXM endpoint.
	always_comb begin
		command_global_target_w = command_target_index_w;
		case(command_target_kind_w)
			PROGRAM_TARGET_MEM: begin
				if(command_target_legal_w &&
					program_cmd_write_destination_i[PROGRAM_DESTINATION_HEMISPHERE_BIT] == PROGRAM_HEMISPHERE_WEST)begin
					command_global_target_w = command_target_index_w + lpu_pkg::MEM_BANKS_PER_HEMISPHERE;
				end
			end
			PROGRAM_TARGET_MXM_LOAD,
			PROGRAM_TARGET_MXM_DEQUANT,
			PROGRAM_TARGET_MXM_COMPUTE,
			PROGRAM_TARGET_MXM_PARAM_LOAD,
			PROGRAM_TARGET_MXM_BACKEND: begin
				if(command_target_legal_w &&
					program_cmd_write_destination_i[PROGRAM_DESTINATION_HEMISPHERE_BIT] == PROGRAM_HEMISPHERE_WEST)begin
					command_global_target_w = command_target_index_w + 8'd2;
				end
			end
			default: command_global_target_w = command_target_index_w;
		endcase
	end

	assign program_cmd_write_ready_o = loader_program_cmd_write_ready && !load_request_active_q &&
		!descriptor_fault_q;
	assign program_cmd_write_fire = program_cmd_write_valid_i && program_cmd_write_ready_o;
	assign command_is_sxm_w = (command_target_kind_w == PROGRAM_TARGET_SXM_TRANSPOSE) ||
		(command_target_kind_w == PROGRAM_TARGET_SXM_PERMUTE);
	assign descriptor_illegal_w = program_cmd_write_fire &&
		(program_cmd_write_opcode_i == PROGRAM_LOADER_LOAD_IMEM) &&
		(!command_target_legal_w || (program_cmd_write_encoding_mode_i !=
		 ((command_is_sxm_w || command_target_kind_w == PROGRAM_TARGET_VXM) ? PROGRAM_ENCODING_NATIVE : PROGRAM_ENCODING_MACRO)) ||
		 (program_cmd_write_byte_count_i == 0) ||
		 (command_is_sxm_w &&
		  ((program_cmd_write_format_i != PROGRAM_FORMAT_128) ||
		   (program_cmd_write_byte_count_i % 32 != 0) ||
		   (program_cmd_write_byte_count_i > 64*32) ||
		   (program_cmd_write_imem_base_address_i != 0) ||
		   !program_cmd_write_image_first_i || !program_cmd_write_image_last_i ||
		   (program_cmd_write_expected_word_count_i != program_cmd_write_byte_count_i / 16))) ||
		 ((command_target_kind_w == PROGRAM_TARGET_VXM) &&
		  ((program_cmd_write_format_i != PROGRAM_FORMAT_96) ||
		   (program_cmd_write_byte_count_i % 12 != 0) ||
		   (program_cmd_write_expected_word_count_i != program_cmd_write_byte_count_i / 12) ||
		   ({1'b0, program_cmd_write_imem_base_address_i} + program_cmd_write_expected_word_count_i > VXM_IMEM_DEPTH) ||
		   !program_cmd_write_image_first_i || !program_cmd_write_image_last_i)) ||
		 ((command_target_kind_w == PROGRAM_TARGET_MEM) &&
		  ((program_cmd_write_format_i != PROGRAM_FORMAT_96) ||
		   ((program_cmd_write_byte_count_i % 12) != 0) ||
		   (program_cmd_write_expected_word_count_i != program_cmd_write_byte_count_i / 12) ||
		   ({1'b0, program_cmd_write_imem_base_address_i} + program_cmd_write_expected_word_count_i > MEM_IMEM_DEPTH))) ||
		 (((command_target_kind_w == PROGRAM_TARGET_MXM_LOAD) ||
		   (command_target_kind_w == PROGRAM_TARGET_MXM_DEQUANT) ||
		   (command_target_kind_w == PROGRAM_TARGET_MXM_COMPUTE) ||
		   (command_target_kind_w == PROGRAM_TARGET_MXM_PARAM_LOAD) ||
		   (command_target_kind_w == PROGRAM_TARGET_MXM_BACKEND)) &&
		  ((program_cmd_write_format_i != PROGRAM_FORMAT_128) ||
		   ((program_cmd_write_byte_count_i % 16) != 0) ||
		   (program_cmd_write_expected_word_count_i != program_cmd_write_byte_count_i / 16) ||
		   ({1'b0, program_cmd_write_imem_base_address_i} + program_cmd_write_expected_word_count_i > MXM_IMEM_DEPTH))));

	// Detect a repeated Program descriptor for the selected MEM or MXM destination.
	always_comb begin
		descriptor_duplicate_w = 1'b0;
		if(program_cmd_write_fire && (program_cmd_write_opcode_i == PROGRAM_LOADER_LOAD_IMEM) && command_target_legal_w)begin
			case(command_target_kind_w)
				PROGRAM_TARGET_VXM: descriptor_duplicate_w = vxm_target_seen_q[command_target_index_w[2:0]];
				PROGRAM_TARGET_MEM: descriptor_duplicate_w = mem_target_seen_q[command_global_target_w];
				PROGRAM_TARGET_MXM_LOAD: descriptor_duplicate_w = mxm_load_target_seen_q[command_global_target_w[1:0]];
				PROGRAM_TARGET_MXM_DEQUANT: descriptor_duplicate_w = mxm_dequant_target_seen_q[command_global_target_w[1:0]];
				PROGRAM_TARGET_MXM_COMPUTE: descriptor_duplicate_w = mxm_compute_target_seen_q[command_global_target_w[1:0]];
				PROGRAM_TARGET_MXM_PARAM_LOAD: descriptor_duplicate_w = mxm_param_load_target_seen_q[command_global_target_w[1:0]];
				PROGRAM_TARGET_MXM_BACKEND: descriptor_duplicate_w = mxm_backend_target_seen_q[command_global_target_w[1:0]];
				PROGRAM_TARGET_SXM_TRANSPOSE: descriptor_duplicate_w =
					sxm_ctrl_target_seen_q[program_cmd_write_destination_i[PROGRAM_DESTINATION_HEMISPHERE_BIT]];
				PROGRAM_TARGET_SXM_PERMUTE: descriptor_duplicate_w =
					sxm_exec_target_seen_q[program_cmd_write_destination_i[PROGRAM_DESTINATION_HEMISPHERE_BIT]];
				default: descriptor_duplicate_w = 1'b0;
			endcase
		end
	end


	assign fu_cluster_program_start_o = loader_program_start;

	assign cluster_start_ready = fu_cluster_program_start_ready_i;
	assign cluster_started = fu_cluster_started_i;
	assign cluster_frontends_ready = fu_cluster_frontends_ready_i;
	assign cluster_frontends_idle = fu_cluster_frontends_idle_i;
	assign cluster_fault = fu_cluster_fault_i;
	assign cluster_fault_code = fu_cluster_fault_code_i;
	assign schedule_cycle_o = fu_cluster_schedule_cycle_i;

	assign program_start_ack_o = loader_program_start && cluster_start_ready;
	assign program_load_start_ready_o = loader_start_ready && !load_request_active_q && !descriptor_fault_q;
	assign program_load_complete_o = instruction_load_done;
	assign program_ready_o = instruction_load_done && cluster_frontends_ready && !program_fault_o;
	assign program_running_o = cluster_started && !program_done_q && !program_fault_o;
	assign program_done_o = program_done_q;
	assign program_fault_o = descriptor_fault_q || loader_error || cluster_fault;
	assign program_fault_code_o = descriptor_fault_q ? PROGRAM_FAULT_DESCRIPTOR :
		(loader_error ? loader_error_code :
		(cluster_fault ? FRONTEND_FAULT_OFFSET + cluster_fault_code : PROGRAM_FAULT_NONE));

	lpu_program_load_controller #(
		.COMMAND_DEPTH(COMMAND_DEPTH),
		.COMMAND_ADDRESS_WIDTH(COMMAND_ADDRESS_WIDTH)
	) u_program_load_controller (
		.clk_i,
		.rst_ni(internal_rst_ni),
		.program_cmd_write_valid_i,
		.program_cmd_write_ready_o(loader_program_cmd_write_ready),
		.program_cmd_write_address_i,
		.program_cmd_write_opcode_i,
		.program_cmd_write_source_address_i,
		.program_cmd_write_byte_count_i,
		.program_cmd_write_scope_i(command_scope_w),
		.program_cmd_write_destination_i,
		.program_cmd_write_format_i,
		.program_cmd_write_imem_base_address_i,
		.program_cmd_write_image_first_i,
		.program_cmd_write_image_last_i,
		.program_cmd_write_expected_word_count_i,
		.program_cmd_write_jump_address_i,
		.program_load_start_valid_i(program_load_start_valid_i && program_load_start_ready_o),
		.program_load_start_ready_o(loader_start_ready),
		.program_load_start_command_count_i(program_load_start_command_count_i),
		.ctrl_load_txn_valid_o(ctrl_load_txn_valid),
		.ctrl_load_txn_ready_i(ctrl_load_txn_ready),
		.ctrl_load_txn_source_address_o(ctrl_load_txn_source_address),
		.ctrl_load_txn_byte_count_o(ctrl_load_txn_byte_count),
		.ctrl_load_txn_scope_o(ctrl_load_txn_scope),
		.ctrl_load_txn_destination_o(ctrl_load_txn_destination),
		.ctrl_load_txn_format_o(ctrl_load_txn_format),
		.ctrl_load_txn_imem_base_address_o(ctrl_load_txn_imem_base_address),
		.ctrl_load_txn_image_first_o(ctrl_load_txn_image_first),
		.ctrl_load_txn_image_last_o(ctrl_load_txn_image_last),
		.ctrl_load_txn_expected_word_count_o(ctrl_load_txn_expected_word_count),
		.ctrl_load_txn_dma_id_o(ctrl_load_txn_dma_id),
		.ctrl_prime_valid_o(ctrl_prime_valid),
		.ctrl_prime_ready_i(ctrl_prime_ready),
		.ctrl_prime_scope_o(ctrl_prime_scope),
		.ctrl_prime_destination_o(ctrl_prime_destination),
		.load_pipeline_idle_i(load_pipeline_idle_w),
		.command_pc_o(),
		.busy_o(),
		.done_o(command_done),
		.fault_o(command_fault),
		.fault_code_o(command_fault_code)
	);

	lpu_program_load_path #(
		.DMA_DATA_WIDTH(DMA_DATA_WIDTH),
		.IMEM_DEPTH(MEM_IMEM_DEPTH)
	) u_program_load_path (
		.clk_i,
		.rst_ni,
		.clear_i(program_reset_i),
		.ctrl_load_txn_valid_i(ctrl_load_txn_valid),
		.ctrl_load_txn_ready_o(ctrl_load_txn_ready),
		.ctrl_load_txn_source_address_i(ctrl_load_txn_source_address),
		.ctrl_load_txn_byte_count_i(ctrl_load_txn_byte_count),
		.ctrl_load_txn_scope_i(ctrl_load_txn_scope),
		.ctrl_load_txn_destination_i(ctrl_load_txn_destination),
		.ctrl_load_txn_format_i(ctrl_load_txn_format),
		.ctrl_load_txn_imem_base_address_i(ctrl_load_txn_imem_base_address),
		.ctrl_load_txn_image_first_i(ctrl_load_txn_image_first),
		.ctrl_load_txn_image_last_i(ctrl_load_txn_image_last),
		.ctrl_load_txn_expected_word_count_i(ctrl_load_txn_expected_word_count),
		.ctrl_load_txn_dma_id_i(ctrl_load_txn_dma_id),
		.ddr_read_req_valid_o,
		.ddr_read_req_ready_i,
		.ddr_read_req_address_o,
		.ddr_read_req_length_o,
		.ddr_read_req_id_o,
		.ddr_read_rsp_valid_i,
		.ddr_read_rsp_ready_o,
		.ddr_read_rsp_data_i,
		.ddr_read_rsp_keep_i,
		.ddr_read_rsp_last_i,
		.ddr_read_rsp_id_i,
		.ddr_read_rsp_error_i,
		.load_word_valid_o(load_word_valid),
		.load_word_ready_i(load_word_ready),
		.load_word_data_o(load_word_data),
		.load_word_strb_o(load_word_strb),
		.load_word_scope_o(load_word_scope),
		.load_word_destination_o(load_word_destination),
		.load_word_imem_address_o(load_word_imem_address),
		.load_word_last_o(load_word_last),
		.idle_o(load_path_idle),
		.generated_word_count_o(),
		.fault_o(load_path_fault),
		.fault_code_o(load_path_fault_code)
	);

	assign prime_enqueue_valid = ctrl_prime_valid && load_pipeline_idle_w;
	assign ctrl_prime_ready = prime_enqueue_valid && prime_enqueue_ready;
	assign prime_enqueue_data = {ctrl_prime_scope, ctrl_prime_destination};

	lpu_fifo #(
		.DATA_WIDTH(14),
		.DEPTH(32)
	) u_prime_fifo (
		.clk_i,
		.rst_ni(internal_rst_ni),
		.enqueue_valid_i(prime_enqueue_valid),
		.enqueue_ready_o(prime_enqueue_ready),
		.enqueue_data_i(prime_enqueue_data),
		.dequeue_valid_o(prime_dequeue_valid),
		.dequeue_ready_i(prime_dequeue_ready),
		.dequeue_data_o(prime_dequeue_data),
		.level_o(prime_fifo_level)
	);

	assign {prime_dequeue_scope, prime_dequeue_destination} = prime_dequeue_data;
	assign prime_select_w = instruction_load_done_q && prime_dequeue_valid;

	// PRIME records are emitted only after all Program Words have retired. Both
	// sources use the same stable valid/ready Record interface to Distribution.
	assign load_distribute_valid_o = prime_select_w ? prime_dequeue_valid : load_word_valid;
	assign load_distribute_control_o = prime_select_w ? PROGRAM_LOAD_PRIME : PROGRAM_LOAD_WRITE;
	assign load_distribute_data_o = prime_select_w ? '0 : load_word_data;
	assign load_distribute_strb_o = prime_select_w ? '0 : load_word_strb;
	assign load_distribute_scope_o = prime_select_w ? prime_dequeue_scope : load_word_scope;
	assign load_distribute_destination_o = prime_select_w ? prime_dequeue_destination :
		load_word_destination;
	assign load_distribute_imem_address_o = prime_select_w ? '0 : load_word_imem_address;
	assign load_distribute_last_o = prime_select_w ? 1'b1 : load_word_last;
	assign prime_dequeue_ready = prime_select_w && load_distribute_ready_i;
	assign load_word_ready = !prime_select_w && load_distribute_ready_i;

	assign load_pipeline_idle_w = load_path_idle && load_distribute_idle_i;
	assign instruction_load_done = instruction_load_done_q;
	assign loader_program_start = instruction_load_done_q &&
		(start_pending_q && dependencies_ready_i) && cluster_frontends_ready && !loader_error;
	assign loader_error = controller_fault_q || command_fault || load_path_fault ||
		load_distribute_fault_i;
	assign loader_error_code = controller_fault_q ? controller_fault_code_q :
		(command_fault ? command_fault_code :
		(load_path_fault ? load_path_fault_code :
		(load_distribute_fault_i ? load_distribute_fault_code_i : PROGRAM_FAULT_NONE)));

	// Completion is reached only after END and every buffered WRITE/acknowledgement retires.
	always_ff @(posedge clk_i or negedge internal_rst_ni) begin
		if(!internal_rst_ni)begin
			instruction_load_done_q <= 1'b0;
		end
		else if(command_done && load_pipeline_idle_w && !loader_error)begin
			instruction_load_done_q <= 1'b1;
		end
	end

	// Retain the first lifecycle fault so a later ready transition cannot hide it.
	always_ff @(posedge clk_i or negedge internal_rst_ni) begin
		if(!internal_rst_ni)begin
			controller_fault_q <= 1'b0;
			controller_fault_code_q <= PROGRAM_FAULT_NONE;
		end
		else if(!controller_fault_q)begin
			if(command_fault)begin
				controller_fault_q <= 1'b1;
				controller_fault_code_q <= command_fault_code;
			end
			else if(load_path_fault)begin
				controller_fault_q <= 1'b1;
				controller_fault_code_q <= load_path_fault_code;
			end
			else if(load_distribute_fault_i)begin
				controller_fault_q <= 1'b1;
				controller_fault_code_q <= load_distribute_fault_code_i;
			end
		end
	end

	// Early START is sticky, matching CMODEL; dependencies must still be high on the acceptance cycle.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			start_pending_q <= 1'b0;
			load_request_active_q <= 1'b0;
			program_done_q <= 1'b0;
		end
		else if(program_reset_i)begin
			start_pending_q <= 1'b0;
			load_request_active_q <= 1'b0;
			program_done_q <= 1'b0;
		end
		else begin
			if(program_load_start_valid_i && program_load_start_ready_o)begin
				load_request_active_q <= 1'b1;
			end
			if(program_start_request_i && !program_done_q)begin
				start_pending_q <= 1'b1;
			end
			if(program_start_ack_o)begin
				start_pending_q <= 1'b0;
			end
			if(cluster_started && cluster_frontends_idle)begin
				program_done_q <= 1'b1;
			end
		end
	end

	// Reject duplicate or malformed Program descriptors and remember each
	// accepted MEM or MXM target for the current load lifecycle.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			descriptor_fault_q <= 1'b0;
			mem_target_seen_q <= '0;
			mxm_load_target_seen_q <= '0;
			mxm_dequant_target_seen_q <= '0;
			mxm_compute_target_seen_q <= '0;
			mxm_param_load_target_seen_q <= '0;
			mxm_backend_target_seen_q <= '0;
			sxm_ctrl_target_seen_q <= '0;
			sxm_exec_target_seen_q <= '0;
			vxm_target_seen_q <= '0;
		end
		else if(program_reset_i)begin
			descriptor_fault_q <= 1'b0;
			mem_target_seen_q <= '0;
			mxm_load_target_seen_q <= '0;
			mxm_dequant_target_seen_q <= '0;
			mxm_compute_target_seen_q <= '0;
			mxm_param_load_target_seen_q <= '0;
			mxm_backend_target_seen_q <= '0;
			sxm_ctrl_target_seen_q <= '0;
			sxm_exec_target_seen_q <= '0;
			vxm_target_seen_q <= '0;
		end
		else begin
			if(descriptor_illegal_w || descriptor_duplicate_w)begin
				descriptor_fault_q <= 1'b1;
			end
			if(program_cmd_write_fire && (program_cmd_write_opcode_i == PROGRAM_LOADER_LOAD_IMEM) &&
				command_target_legal_w && !descriptor_illegal_w && !descriptor_duplicate_w)begin
				case(command_target_kind_w)
					PROGRAM_TARGET_VXM: vxm_target_seen_q[command_target_index_w[2:0]] <= 1'b1;
					PROGRAM_TARGET_MEM: mem_target_seen_q[command_global_target_w] <= 1'b1;
					PROGRAM_TARGET_MXM_LOAD: mxm_load_target_seen_q[command_global_target_w[1:0]] <= 1'b1;
					PROGRAM_TARGET_MXM_DEQUANT: mxm_dequant_target_seen_q[command_global_target_w[1:0]] <= 1'b1;
					PROGRAM_TARGET_MXM_COMPUTE: mxm_compute_target_seen_q[command_global_target_w[1:0]] <= 1'b1;
					PROGRAM_TARGET_MXM_PARAM_LOAD: mxm_param_load_target_seen_q[command_global_target_w[1:0]] <= 1'b1;
					PROGRAM_TARGET_MXM_BACKEND: mxm_backend_target_seen_q[command_global_target_w[1:0]] <= 1'b1;
					PROGRAM_TARGET_SXM_TRANSPOSE: sxm_ctrl_target_seen_q[
						program_cmd_write_destination_i[PROGRAM_DESTINATION_HEMISPHERE_BIT]] <= 1'b1;
					PROGRAM_TARGET_SXM_PERMUTE: sxm_exec_target_seen_q[
						program_cmd_write_destination_i[PROGRAM_DESTINATION_HEMISPHERE_BIT]] <= 1'b1;
					default: mem_target_seen_q <= mem_target_seen_q;
				endcase
			end
		end
	end
endmodule
