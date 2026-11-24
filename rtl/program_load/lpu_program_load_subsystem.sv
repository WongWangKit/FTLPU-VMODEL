module lpu_program_load_subsystem #(
	parameter integer COMMAND_DEPTH = 32,
	parameter integer DMA_DATA_WIDTH = 256,
	parameter integer CONFIG_FIFO_DEPTH = 16,
	parameter integer DMA_OUTSTANDING_DEPTH = 16,
	parameter integer DMA_RX_FIFO_DEPTH = 16,
	parameter integer REASSEMBLY_BUFFER_BYTES = 64,
	parameter integer WORD_FIFO_DEPTH = 8,
	parameter integer COMMIT_FIFO_DEPTH = 16,
	parameter integer PRIME_FIFO_DEPTH = 32,
	parameter integer IMEM_DEPTH = 65536,
	parameter integer COMMAND_ADDRESS_WIDTH = COMMAND_DEPTH <= 1 ? 1 : $clog2(COMMAND_DEPTH)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic abort_i,

	input logic command_write_valid_i,
	output logic command_write_ready_o,
	input logic [COMMAND_ADDRESS_WIDTH-1:0] command_write_address_i,
	input logic [2:0] command_write_opcode_i,
	input logic [63:0] command_write_source_address_i,
	input logic [31:0] command_write_byte_count_i,
	input logic [1:0] command_write_hemisphere_i,
	input logic [3:0] command_write_target_kind_i,
	input logic [7:0] command_write_queue_id_i,
	input logic [1:0] command_write_format_i,
	input logic [16:0] command_write_imem_base_address_i,
	input logic command_write_image_first_i,
	input logic command_write_image_last_i,
	input logic [15:0] command_write_expected_word_count_i,
	input logic [COMMAND_ADDRESS_WIDTH-1:0] command_write_jump_address_i,

	input logic start_valid_i,
	output logic start_ready_o,
	input logic [COMMAND_ADDRESS_WIDTH:0] start_command_count_i,

	output logic dma_cmd_valid_o,
	input logic dma_cmd_ready_i,
	output logic [63:0] dma_cmd_address_o,
	output logic [31:0] dma_cmd_length_o,
	output logic [7:0] dma_cmd_id_o,

	input logic dma_rsp_valid_i,
	output logic dma_rsp_ready_o,
	input logic [DMA_DATA_WIDTH-1:0] dma_rsp_data_i,
	input logic [DMA_DATA_WIDTH/8-1:0] dma_rsp_keep_i,
	input logic dma_rsp_last_i,
	input logic [7:0] dma_rsp_id_i,
	input logic dma_rsp_error_i,

	output logic west_load_valid_o,
	input logic west_load_ready_i,
	output logic [2:0] west_load_control_o,
	output logic [127:0] west_load_data_o,
	output logic [3:0] west_load_strb_o,
	output logic [3:0] west_load_target_kind_o,
	output logic [7:0] west_load_queue_id_o,
	output logic [16:0] west_load_imem_address_o,
	output logic west_load_last_o,

	output logic east_load_valid_o,
	input logic east_load_ready_i,
	output logic [2:0] east_load_control_o,
	output logic [127:0] east_load_data_o,
	output logic [3:0] east_load_strb_o,
	output logic [3:0] east_load_target_kind_o,
	output logic [7:0] east_load_queue_id_o,
	output logic [16:0] east_load_imem_address_o,
	output logic east_load_last_o,

	input logic west_commit_valid_i,
	output logic west_commit_ready_o,
	input logic west_commit_error_i,
	input logic east_commit_valid_i,
	output logic east_commit_ready_o,
	input logic east_commit_error_i,

	input logic weight_load_done_i,
	input logic all_frontends_ready_i,

	output logic instruction_load_done_o,
	output logic program_start_o,
	output logic busy_o,
	output logic [31:0] generated_word_count_o,
	output logic [31:0] committed_word_count_o,
	output logic error_o,
	output logic [5:0] error_code_o
);
	import lpu_program_load_pkg::*;

	logic internal_rst_ni;

	// Loader transaction and control command signals.
	logic loader_transaction_valid;
	logic loader_transaction_ready;
	logic [63:0] loader_source_address;
	logic [31:0] loader_byte_count;
	logic [1:0] loader_hemisphere;
	logic [3:0] loader_target_kind;
	logic [7:0] loader_queue_id;
	logic [1:0] loader_format;
	logic [16:0] loader_imem_base_address;
	logic loader_image_first;
	logic loader_image_last;
	logic [15:0] loader_expected_word_count;
	logic [7:0] loader_dma_id;
	logic loader_commit_valid;
	logic loader_commit_ready;
	logic [1:0] loader_commit_hemisphere;
	logic [3:0] loader_commit_target_kind;
	logic [7:0] loader_commit_queue_id;
	logic loader_busy;
	logic loader_done;
	logic loader_fault;
	logic [5:0] loader_fault_code;

	// Config FIFO head remains stable until the reassembler accepts burst last.
	logic config_enqueue_valid;
	logic config_enqueue_ready;
	logic config_dequeue_valid;
	logic config_dequeue_ready;
	logic [63:0] config_source_address;
	logic [31:0] config_byte_count;
	logic [1:0] config_hemisphere;
	logic [3:0] config_target_kind;
	logic [7:0] config_queue_id;
	logic [1:0] config_format;
	logic [16:0] config_imem_base_address;
	logic config_image_first;
	logic config_image_last;
	logic [15:0] config_expected_word_count;
	logic [7:0] config_dma_id;
	logic [$clog2(CONFIG_FIFO_DEPTH+1)-1:0] config_level;
	logic config_empty;

	// Instruction DMA response stream.
	logic instruction_dma_command_valid;
	logic instruction_dma_command_ready;
	logic dma_response_valid;
	logic dma_response_ready;
	logic [DMA_DATA_WIDTH-1:0] dma_response_data;
	logic [DMA_DATA_WIDTH/8-1:0] dma_response_keep;
	logic dma_response_last;
	logic [7:0] dma_response_id;
	logic dma_response_error;
	logic instruction_dma_idle;
	logic instruction_dma_fault;
	logic [5:0] instruction_dma_fault_code;

	// Reassembled word stream and buffer state.
	logic reassembler_word_valid;
	logic reassembler_word_ready;
	logic [127:0] reassembler_word_data;
	logic [3:0] reassembler_word_strb;
	logic [1:0] reassembler_word_hemisphere;
	logic [3:0] reassembler_word_target_kind;
	logic [7:0] reassembler_word_queue_id;
	logic [16:0] reassembler_word_imem_address;
	logic reassembler_word_last;
	logic reassembler_idle;
	logic reassembler_fault;
	logic [5:0] reassembler_fault_code;

	// Word FIFO to distributor mux.
	logic word_dequeue_valid;
	logic word_dequeue_ready;
	logic [127:0] word_dequeue_data;
	logic [3:0] word_dequeue_strb;
	logic [1:0] word_dequeue_hemisphere;
	logic [3:0] word_dequeue_target_kind;
	logic [7:0] word_dequeue_queue_id;
	logic [16:0] word_dequeue_imem_address;
	logic word_dequeue_last;
	logic word_fifo_empty;
	logic distributor_input_valid;
	logic distributor_input_ready;
	logic [2:0] distributor_input_control;
	logic [127:0] distributor_input_data;
	logic [3:0] distributor_input_strb;
	logic [1:0] distributor_input_hemisphere;
	logic [3:0] distributor_input_target_kind;
	logic [7:0] distributor_input_queue_id;
	logic [16:0] distributor_input_imem_address;
	logic distributor_input_last;
	logic commit_select_w;
	logic prime_select_w;

	// Queue descriptors are retained until every Program Image has committed.
	logic prime_enqueue_valid;
	logic prime_enqueue_ready;
	logic [13:0] prime_enqueue_data;
	logic prime_dequeue_valid;
	logic prime_dequeue_ready;
	logic [13:0] prime_dequeue_data;
	logic [1:0] prime_dequeue_hemisphere;
	logic [3:0] prime_dequeue_target_kind;
	logic [7:0] prime_dequeue_queue_id;
	logic [$clog2(PRIME_FIFO_DEPTH+1)-1:0] prime_fifo_level;

	// Distributor internal branches are gated by commit-scoreboard capacity before reaching targets.
	logic distributor_west_valid;
	logic distributor_west_ready;
	logic [2:0] distributor_west_control;
	logic [127:0] distributor_west_data;
	logic [3:0] distributor_west_strb;
	logic [1:0] distributor_west_hemisphere;
	logic [3:0] distributor_west_target_kind;
	logic [7:0] distributor_west_queue_id;
	logic [16:0] distributor_west_imem_address;
	logic distributor_west_last;
	logic distributor_east_valid;
	logic distributor_east_ready;
	logic [2:0] distributor_east_control;
	logic [127:0] distributor_east_data;
	logic [3:0] distributor_east_strb;
	logic [1:0] distributor_east_hemisphere;
	logic [3:0] distributor_east_target_kind;
	logic [7:0] distributor_east_queue_id;
	logic [16:0] distributor_east_imem_address;
	logic distributor_east_last;
	logic distributor_idle;
	logic distributor_fault;
	logic [5:0] distributor_fault_code;

	// Per-hemisphere token FIFOs retain the number of accepted WRITE operations awaiting a response.
	logic west_commit_enqueue_ready;
	logic west_commit_expected_valid;
	logic west_commit_expected_pop;
	logic [$clog2(COMMIT_FIFO_DEPTH+1)-1:0] west_commit_level;
	logic east_commit_enqueue_ready;
	logic east_commit_expected_valid;
	logic east_commit_expected_pop;
	logic [$clog2(COMMIT_FIFO_DEPTH+1)-1:0] east_commit_level;
	logic west_bus_fire;
	logic east_bus_fire;
	logic west_commit_fire;
	logic east_commit_fire;
	logic west_commit_good_w;
	logic east_commit_good_w;
	logic commit_fault_w;

	logic load_pipeline_idle_w;
	logic instruction_load_done_q;
	logic [31:0] generated_word_count_q;
	logic [31:0] committed_word_count_q;
	logic system_fault_q;
	logic [5:0] system_fault_code_q;

	assign internal_rst_ni = rst_ni && !abort_i;

	lpu_program_loader #(
		.COMMAND_DEPTH(COMMAND_DEPTH),
		.COMMAND_ADDRESS_WIDTH(COMMAND_ADDRESS_WIDTH)
	) u_loader (
		.clk_i,
		.rst_ni(internal_rst_ni),
		.command_write_valid_i,
		.command_write_ready_o,
		.command_write_address_i,
		.command_write_opcode_i,
		.command_write_source_address_i,
		.command_write_byte_count_i,
		.command_write_hemisphere_i,
		.command_write_target_kind_i,
		.command_write_queue_id_i,
		.command_write_format_i,
		.command_write_imem_base_address_i,
		.command_write_image_first_i,
		.command_write_image_last_i,
		.command_write_expected_word_count_i,
		.command_write_jump_address_i,
		.start_valid_i,
		.start_ready_o,
		.start_command_count_i,
		.transaction_valid_o(loader_transaction_valid),
		.transaction_ready_i(loader_transaction_ready),
		.transaction_source_address_o(loader_source_address),
		.transaction_byte_count_o(loader_byte_count),
		.transaction_hemisphere_o(loader_hemisphere),
		.transaction_target_kind_o(loader_target_kind),
		.transaction_queue_id_o(loader_queue_id),
		.transaction_format_o(loader_format),
		.transaction_imem_base_address_o(loader_imem_base_address),
		.transaction_image_first_o(loader_image_first),
		.transaction_image_last_o(loader_image_last),
		.transaction_expected_word_count_o(loader_expected_word_count),
		.transaction_dma_id_o(loader_dma_id),
		.commit_valid_o(loader_commit_valid),
		.commit_ready_i(loader_commit_ready),
		.commit_hemisphere_o(loader_commit_hemisphere),
		.commit_target_kind_o(loader_commit_target_kind),
		.commit_queue_id_o(loader_commit_queue_id),
		.load_pipeline_idle_i(load_pipeline_idle_w),
		.command_pc_o(),
		.busy_o(loader_busy),
		.done_o(loader_done),
		.fault_o(loader_fault),
		.fault_code_o(loader_fault_code)
	);

	// Both valid signals are cross-gated so a DMA command and its config entry fire atomically.
	assign loader_transaction_ready = instruction_dma_command_ready && config_enqueue_ready;
	assign instruction_dma_command_valid = loader_transaction_valid && config_enqueue_ready;
	assign config_enqueue_valid = loader_transaction_valid && instruction_dma_command_ready;

	lpu_program_config_fifo #(
		.DEPTH(CONFIG_FIFO_DEPTH)
	) u_config_fifo (
		.clk_i,
		.rst_ni(internal_rst_ni),
		.enqueue_valid_i(config_enqueue_valid),
		.enqueue_ready_o(config_enqueue_ready),
		.enqueue_source_address_i(loader_source_address),
		.enqueue_byte_count_i(loader_byte_count),
		.enqueue_hemisphere_i(loader_hemisphere),
		.enqueue_target_kind_i(loader_target_kind),
		.enqueue_queue_id_i(loader_queue_id),
		.enqueue_format_i(loader_format),
		.enqueue_imem_base_address_i(loader_imem_base_address),
		.enqueue_image_first_i(loader_image_first),
		.enqueue_image_last_i(loader_image_last),
		.enqueue_expected_word_count_i(loader_expected_word_count),
		.enqueue_dma_id_i(loader_dma_id),
		.dequeue_valid_o(config_dequeue_valid),
		.dequeue_ready_i(config_dequeue_ready),
		.dequeue_source_address_o(config_source_address),
		.dequeue_byte_count_o(config_byte_count),
		.dequeue_hemisphere_o(config_hemisphere),
		.dequeue_target_kind_o(config_target_kind),
		.dequeue_queue_id_o(config_queue_id),
		.dequeue_format_o(config_format),
		.dequeue_imem_base_address_o(config_imem_base_address),
		.dequeue_image_first_o(config_image_first),
		.dequeue_image_last_o(config_image_last),
		.dequeue_expected_word_count_o(config_expected_word_count),
		.dequeue_dma_id_o(config_dma_id),
		.level_o(config_level),
		.empty_o(config_empty),
		.full_o()
	);

	lpu_instruction_dma #(
		.DMA_DATA_WIDTH(DMA_DATA_WIDTH),
		.DMA_ID_WIDTH(8),
		.OUTSTANDING_DEPTH(DMA_OUTSTANDING_DEPTH),
		.RX_FIFO_DEPTH(DMA_RX_FIFO_DEPTH)
	) u_instruction_dma (
		.clk_i,
		.rst_ni(internal_rst_ni),
		.ctrl_dma_cmd_valid_i(instruction_dma_command_valid),
		.ctrl_dma_cmd_ready_o(instruction_dma_command_ready),
		.ctrl_dma_cmd_address_i(loader_source_address),
		.ctrl_dma_cmd_length_i(loader_byte_count),
		.ctrl_dma_cmd_id_i(loader_dma_id),
		.ddr_read_req_valid_o(dma_cmd_valid_o),
		.ddr_read_req_ready_i(dma_cmd_ready_i),
		.ddr_read_req_address_o(dma_cmd_address_o),
		.ddr_read_req_length_o(dma_cmd_length_o),
		.ddr_read_req_id_o(dma_cmd_id_o),
		.ddr_read_rsp_valid_i(dma_rsp_valid_i),
		.ddr_read_rsp_ready_o(dma_rsp_ready_o),
		.ddr_read_rsp_data_i(dma_rsp_data_i),
		.ddr_read_rsp_keep_i(dma_rsp_keep_i),
		.ddr_read_rsp_last_i(dma_rsp_last_i),
		.ddr_read_rsp_id_i(dma_rsp_id_i),
		.ddr_read_rsp_error_i(dma_rsp_error_i),
		.reasm_rsp_valid_o(dma_response_valid),
		.reasm_rsp_ready_i(dma_response_ready),
		.reasm_rsp_data_o(dma_response_data),
		.reasm_rsp_keep_o(dma_response_keep),
		.reasm_rsp_last_o(dma_response_last),
		.reasm_rsp_id_o(dma_response_id),
		.reasm_rsp_error_o(dma_response_error),
		.outstanding_o(),
		.idle_o(instruction_dma_idle),
		.fault_o(instruction_dma_fault),
		.fault_code_o(instruction_dma_fault_code)
	);

	lpu_program_reassembler #(
		.DMA_DATA_WIDTH(DMA_DATA_WIDTH),
		.BUFFER_BYTES(REASSEMBLY_BUFFER_BYTES),
		.IMEM_DEPTH(IMEM_DEPTH)
	) u_reassembler (
		.clk_i,
		.rst_ni(internal_rst_ni),
		.config_valid_i(config_dequeue_valid),
		.config_ready_o(config_dequeue_ready),
		.config_byte_count_i(config_byte_count),
		.config_hemisphere_i(config_hemisphere),
		.config_target_kind_i(config_target_kind),
		.config_queue_id_i(config_queue_id),
		.config_format_i(config_format),
		.config_imem_base_address_i(config_imem_base_address),
		.config_image_first_i(config_image_first),
		.config_image_last_i(config_image_last),
		.config_expected_word_count_i(config_expected_word_count),
		.config_dma_id_i(config_dma_id),
		.response_valid_i(dma_response_valid),
		.response_ready_o(dma_response_ready),
		.response_data_i(dma_response_data),
		.response_keep_i(dma_response_keep),
		.response_last_i(dma_response_last),
		.response_id_i(dma_response_id),
		.response_error_i(dma_response_error),
		.word_valid_o(reassembler_word_valid),
		.word_ready_i(reassembler_word_ready),
		.word_data_o(reassembler_word_data),
		.word_strb_o(reassembler_word_strb),
		.word_hemisphere_o(reassembler_word_hemisphere),
		.word_target_kind_o(reassembler_word_target_kind),
		.word_queue_id_o(reassembler_word_queue_id),
		.word_imem_address_o(reassembler_word_imem_address),
		.word_image_last_o(reassembler_word_last),
		.received_byte_count_o(),
		.generated_word_count_o(),
		.idle_o(reassembler_idle),
		.fault_o(reassembler_fault),
		.fault_code_o(reassembler_fault_code)
	);

	lpu_program_word_fifo #(
		.DEPTH(WORD_FIFO_DEPTH)
	) u_word_fifo (
		.clk_i,
		.rst_ni(internal_rst_ni),
		.enqueue_valid_i(reassembler_word_valid),
		.enqueue_ready_o(reassembler_word_ready),
		.enqueue_data_i(reassembler_word_data),
		.enqueue_strb_i(reassembler_word_strb),
		.enqueue_hemisphere_i(reassembler_word_hemisphere),
		.enqueue_target_kind_i(reassembler_word_target_kind),
		.enqueue_queue_id_i(reassembler_word_queue_id),
		.enqueue_imem_address_i(reassembler_word_imem_address),
		.enqueue_last_i(reassembler_word_last),
		.dequeue_valid_o(word_dequeue_valid),
		.dequeue_ready_i(word_dequeue_ready),
		.dequeue_data_o(word_dequeue_data),
		.dequeue_strb_o(word_dequeue_strb),
		.dequeue_hemisphere_o(word_dequeue_hemisphere),
		.dequeue_target_kind_o(word_dequeue_target_kind),
		.dequeue_queue_id_o(word_dequeue_queue_id),
		.dequeue_imem_address_o(word_dequeue_imem_address),
		.dequeue_last_o(word_dequeue_last),
		.level_o(),
		.empty_o(word_fifo_empty),
		.full_o()
	);

	// COMMIT_QUEUE records its target only after all prior writes and acknowledgements retire.
	// PRIME is deliberately deferred until loader END so no Frontend observes a partial Program.
	assign commit_select_w = loader_commit_valid && load_pipeline_idle_w;
	assign loader_commit_ready = commit_select_w && prime_enqueue_ready;
	assign prime_enqueue_valid = commit_select_w;
	assign prime_enqueue_data = {loader_commit_hemisphere, loader_commit_target_kind,
		loader_commit_queue_id};

	lpu_queue_fifo #(
		.DATA_WIDTH(14),
		.DEPTH(PRIME_FIFO_DEPTH)
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

	assign {prime_dequeue_hemisphere, prime_dequeue_target_kind,
		prime_dequeue_queue_id} = prime_dequeue_data;
	assign prime_select_w = instruction_load_done_q && prime_dequeue_valid;
	assign distributor_input_valid = prime_select_w ? prime_dequeue_valid : word_dequeue_valid;
	assign distributor_input_control = prime_select_w ? PROGRAM_LOAD_PRIME : PROGRAM_LOAD_WRITE;
	assign distributor_input_data = prime_select_w ? 128'd0 : word_dequeue_data;
	assign distributor_input_strb = prime_select_w ? 4'd0 : word_dequeue_strb;
	assign distributor_input_hemisphere = prime_select_w ? prime_dequeue_hemisphere : word_dequeue_hemisphere;
	assign distributor_input_target_kind = prime_select_w ? prime_dequeue_target_kind : word_dequeue_target_kind;
	assign distributor_input_queue_id = prime_select_w ? prime_dequeue_queue_id : word_dequeue_queue_id;
	assign distributor_input_imem_address = prime_select_w ? 17'd0 : word_dequeue_imem_address;
	assign distributor_input_last = prime_select_w ? 1'b1 : word_dequeue_last;
	assign prime_dequeue_ready = prime_select_w && distributor_input_ready;
	assign word_dequeue_ready = !prime_select_w && distributor_input_ready;

	lpu_program_load_distributor u_distributor (
		.clk_i,
		.rst_ni(internal_rst_ni),
		.input_valid_i(distributor_input_valid),
		.input_ready_o(distributor_input_ready),
		.input_control_i(distributor_input_control),
		.input_data_i(distributor_input_data),
		.input_strb_i(distributor_input_strb),
		.input_hemisphere_i(distributor_input_hemisphere),
		.input_target_kind_i(distributor_input_target_kind),
		.input_queue_id_i(distributor_input_queue_id),
		.input_imem_address_i(distributor_input_imem_address),
		.input_last_i(distributor_input_last),
		.west_valid_o(distributor_west_valid),
		.west_ready_i(distributor_west_ready),
		.west_control_o(distributor_west_control),
		.west_data_o(distributor_west_data),
		.west_strb_o(distributor_west_strb),
		.west_hemisphere_o(distributor_west_hemisphere),
		.west_target_kind_o(distributor_west_target_kind),
		.west_queue_id_o(distributor_west_queue_id),
		.west_imem_address_o(distributor_west_imem_address),
		.west_last_o(distributor_west_last),
		.east_valid_o(distributor_east_valid),
		.east_ready_i(distributor_east_ready),
		.east_control_o(distributor_east_control),
		.east_data_o(distributor_east_data),
		.east_strb_o(distributor_east_strb),
		.east_hemisphere_o(distributor_east_hemisphere),
		.east_target_kind_o(distributor_east_target_kind),
		.east_queue_id_o(distributor_east_queue_id),
		.east_imem_address_o(distributor_east_imem_address),
		.east_last_o(distributor_east_last),
		.idle_o(distributor_idle),
		.fault_o(distributor_fault),
		.fault_code_o(distributor_fault_code)
	);

	assign west_load_valid_o = distributor_west_valid &&
		((distributor_west_control != PROGRAM_LOAD_WRITE) || west_commit_enqueue_ready);
	assign distributor_west_ready = west_load_ready_i &&
		((distributor_west_control != PROGRAM_LOAD_WRITE) || west_commit_enqueue_ready);
	assign west_load_control_o = distributor_west_control;
	assign west_load_data_o = distributor_west_data;
	assign west_load_strb_o = distributor_west_strb;
	assign west_load_target_kind_o = distributor_west_target_kind;
	assign west_load_queue_id_o = distributor_west_queue_id;
	assign west_load_imem_address_o = distributor_west_imem_address;
	assign west_load_last_o = distributor_west_last;
	assign west_bus_fire = west_load_valid_o && west_load_ready_i;

	assign east_load_valid_o = distributor_east_valid &&
		((distributor_east_control != PROGRAM_LOAD_WRITE) || east_commit_enqueue_ready);
	assign distributor_east_ready = east_load_ready_i &&
		((distributor_east_control != PROGRAM_LOAD_WRITE) || east_commit_enqueue_ready);
	assign east_load_control_o = distributor_east_control;
	assign east_load_data_o = distributor_east_data;
	assign east_load_strb_o = distributor_east_strb;
	assign east_load_target_kind_o = distributor_east_target_kind;
	assign east_load_queue_id_o = distributor_east_queue_id;
	assign east_load_imem_address_o = distributor_east_imem_address;
	assign east_load_last_o = distributor_east_last;
	assign east_bus_fire = east_load_valid_o && east_load_ready_i;

	lpu_queue_fifo #(
		.DATA_WIDTH(1),
		.DEPTH(COMMIT_FIFO_DEPTH)
	) u_west_commit_fifo (
		.clk_i,
		.rst_ni(internal_rst_ni),
		.enqueue_valid_i(west_bus_fire && (west_load_control_o == PROGRAM_LOAD_WRITE)),
		.enqueue_ready_o(west_commit_enqueue_ready),
		.enqueue_data_i(1'b1),
		.dequeue_valid_o(west_commit_expected_valid),
		.dequeue_ready_i(west_commit_expected_pop),
		.dequeue_data_o(),
		.level_o(west_commit_level)
	);

	lpu_queue_fifo #(
		.DATA_WIDTH(1),
		.DEPTH(COMMIT_FIFO_DEPTH)
	) u_east_commit_fifo (
		.clk_i,
		.rst_ni(internal_rst_ni),
		.enqueue_valid_i(east_bus_fire && (east_load_control_o == PROGRAM_LOAD_WRITE)),
		.enqueue_ready_o(east_commit_enqueue_ready),
		.enqueue_data_i(1'b1),
		.dequeue_valid_o(east_commit_expected_valid),
		.dequeue_ready_i(east_commit_expected_pop),
		.dequeue_data_o(),
		.level_o(east_commit_level)
	);

	assign west_commit_ready_o = internal_rst_ni && !system_fault_q;
	assign east_commit_ready_o = internal_rst_ni && !system_fault_q;
	assign west_commit_fire = west_commit_valid_i && west_commit_ready_o;
	assign east_commit_fire = east_commit_valid_i && east_commit_ready_o;
	assign west_commit_good_w = west_commit_fire && west_commit_expected_valid && !west_commit_error_i;
	assign east_commit_good_w = east_commit_fire && east_commit_expected_valid && !east_commit_error_i;
	assign west_commit_expected_pop = west_commit_good_w;
	assign east_commit_expected_pop = east_commit_good_w;
	assign commit_fault_w = (west_commit_fire && !west_commit_good_w) ||
		(east_commit_fire && !east_commit_good_w);

	assign load_pipeline_idle_w = instruction_dma_idle && config_empty &&
		reassembler_idle && word_fifo_empty && distributor_idle &&
		(west_commit_level == '0) && (east_commit_level == '0);
	assign instruction_load_done_o = instruction_load_done_q;
	assign program_start_o = instruction_load_done_q && weight_load_done_i &&
		all_frontends_ready_i && !error_o;
	assign busy_o = loader_busy || !load_pipeline_idle_w ||
		(prime_fifo_level != '0) || !distributor_idle;
	assign generated_word_count_o = generated_word_count_q;
	assign committed_word_count_o = committed_word_count_q;
	assign error_o = system_fault_q || loader_fault || instruction_dma_fault ||
		reassembler_fault || distributor_fault || commit_fault_w;
	assign error_code_o = system_fault_q ? system_fault_code_q :
		(loader_fault ? loader_fault_code :
		(instruction_dma_fault ? instruction_dma_fault_code :
		(reassembler_fault ? reassembler_fault_code :
		(distributor_fault ? distributor_fault_code :
		(commit_fault_w ? PROGRAM_FAULT_COMMIT : PROGRAM_FAULT_NONE)))));

	// Completion counts are based on accepted words and matching target acknowledgements.
	always_ff @(posedge clk_i or negedge internal_rst_ni) begin
		if(!internal_rst_ni)begin
			generated_word_count_q <= '0;
			committed_word_count_q <= '0;
		end
		else begin
			if(reassembler_word_valid && reassembler_word_ready)begin
				generated_word_count_q <= generated_word_count_q + 1'b1;
			end
			case({west_commit_good_w, east_commit_good_w})
				2'b10, 2'b01: committed_word_count_q <= committed_word_count_q + 1'b1;
				2'b11: committed_word_count_q <= committed_word_count_q + 2'd2;
				default: committed_word_count_q <= committed_word_count_q;
			endcase
		end
	end

	// Loader END is not enough; every buffered word and expected commit must also retire.
	always_ff @(posedge clk_i or negedge internal_rst_ni) begin
		if(!internal_rst_ni)begin
			instruction_load_done_q <= 1'b0;
		end
		else if(loader_done && load_pipeline_idle_w && !error_o)begin
			instruction_load_done_q <= 1'b1;
		end
	end

	// The first subsystem error is retained to block program start and preserve diagnosis.
	always_ff @(posedge clk_i or negedge internal_rst_ni) begin
		if(!internal_rst_ni)begin
			system_fault_q <= 1'b0;
			system_fault_code_q <= PROGRAM_FAULT_NONE;
		end
		else if(!system_fault_q)begin
			if(loader_fault)begin
				system_fault_q <= 1'b1;
				system_fault_code_q <= loader_fault_code;
			end
			else if(instruction_dma_fault)begin
				system_fault_q <= 1'b1;
				system_fault_code_q <= instruction_dma_fault_code;
			end
			else if(reassembler_fault)begin
				system_fault_q <= 1'b1;
				system_fault_code_q <= reassembler_fault_code;
			end
			else if(distributor_fault)begin
				system_fault_q <= 1'b1;
				system_fault_code_q <= distributor_fault_code;
			end
			else if(commit_fault_w)begin
				system_fault_q <= 1'b1;
				system_fault_code_q <= PROGRAM_FAULT_COMMIT;
			end
		end
	end
endmodule
