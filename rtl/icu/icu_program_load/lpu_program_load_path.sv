// Program Transfer accepts one command-sequencer transaction atomically, receives
// the corresponding DMA response stream, rebuilds Program Words and buffers them
// until Program Distribution is ready.
module lpu_program_load_path #(
	parameter integer DMA_DATA_WIDTH = 256,
	parameter integer CONFIG_FIFO_DEPTH = 16,
	parameter integer DMA_OUTSTANDING_DEPTH = 16,
	parameter integer DMA_RX_FIFO_DEPTH = 16,
	parameter integer REASSEMBLY_BUFFER_BYTES = 64,
	parameter integer WORD_FIFO_DEPTH = 8,
	parameter integer IMEM_DEPTH = 65536
) (
	input logic clk_i,
	input logic rst_ni,
	input logic clear_i,

	input logic ctrl_load_txn_valid_i,
	output logic ctrl_load_txn_ready_o,
	input logic [63:0] ctrl_load_txn_source_address_i,
	input logic [31:0] ctrl_load_txn_byte_count_i,
	input logic [1:0] ctrl_load_txn_scope_i,
	input logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		ctrl_load_txn_destination_i,
	input logic [1:0] ctrl_load_txn_format_i,
	input logic [16:0] ctrl_load_txn_imem_base_address_i,
	input logic ctrl_load_txn_image_first_i,
	input logic ctrl_load_txn_image_last_i,
	input logic [15:0] ctrl_load_txn_expected_word_count_i,
	input logic [7:0] ctrl_load_txn_dma_id_i,

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

	output logic load_word_valid_o,
	input logic load_word_ready_i,
	output logic [127:0] load_word_data_o,
	output logic [3:0] load_word_strb_o,
	output logic [1:0] load_word_scope_o,
	output logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		load_word_destination_o,
	output logic [16:0] load_word_imem_address_o,
	output logic load_word_last_o,

	output logic idle_o,
	output logic [31:0] generated_word_count_o,
	output logic fault_o,
	output logic [5:0] fault_code_o
);
	import lpu_program_load_pkg::*;

	logic internal_rst_ni;
	logic config_enqueue_valid;
	logic config_enqueue_ready;
	logic config_dequeue_valid;
	logic config_dequeue_ready;
	logic [31:0] config_byte_count;
	logic [1:0] config_scope;
	logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0] config_destination;
	logic [1:0] config_format;
	logic [16:0] config_imem_base_address;
	logic config_image_first;
	logic config_image_last;
	logic [15:0] config_expected_word_count;
	logic [7:0] config_dma_id;
	logic config_empty;

	logic ctrl_dma_cmd_valid;
	logic ctrl_dma_cmd_ready;
	logic reasm_rsp_valid;
	logic reasm_rsp_ready;
	logic [DMA_DATA_WIDTH-1:0] reasm_rsp_data;
	logic [DMA_DATA_WIDTH/8-1:0] reasm_rsp_keep;
	logic reasm_rsp_last;
	logic [7:0] reasm_rsp_id;
	logic reasm_rsp_error;
	logic dma_idle;
	logic dma_fault;
	logic [5:0] dma_fault_code;

	logic word_fifo_enqueue_valid;
	logic word_fifo_enqueue_ready;
	logic [127:0] word_fifo_enqueue_data;
	logic [3:0] word_fifo_enqueue_strb;
	logic [1:0] word_fifo_enqueue_scope;
	logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		word_fifo_enqueue_destination;
	logic [16:0] word_fifo_enqueue_imem_address;
	logic word_fifo_enqueue_last;
	logic reassembler_idle;
	logic reassembler_fault;
	logic [5:0] reassembler_fault_code;
	logic word_fifo_empty;
	logic [31:0] generated_word_count_q;

	assign internal_rst_ni = rst_ni && !clear_i;

	// The DMA command and matching reassembly metadata are accepted together.
	assign ctrl_load_txn_ready_o = ctrl_dma_cmd_ready && config_enqueue_ready;
	assign ctrl_dma_cmd_valid = ctrl_load_txn_valid_i && config_enqueue_ready;
	assign config_enqueue_valid = ctrl_load_txn_valid_i && ctrl_dma_cmd_ready;

	lpu_program_load_config_fifo #(
		.DEPTH(CONFIG_FIFO_DEPTH)
	) u_config_fifo (
		.clk_i,
		.rst_ni(internal_rst_ni),
		.enqueue_valid_i(config_enqueue_valid),
		.enqueue_ready_o(config_enqueue_ready),
		.enqueue_source_address_i(ctrl_load_txn_source_address_i),
		.enqueue_byte_count_i(ctrl_load_txn_byte_count_i),
		.enqueue_scope_i(ctrl_load_txn_scope_i),
		.enqueue_destination_i(ctrl_load_txn_destination_i),
		.enqueue_format_i(ctrl_load_txn_format_i),
		.enqueue_imem_base_address_i(ctrl_load_txn_imem_base_address_i),
		.enqueue_image_first_i(ctrl_load_txn_image_first_i),
		.enqueue_image_last_i(ctrl_load_txn_image_last_i),
		.enqueue_expected_word_count_i(ctrl_load_txn_expected_word_count_i),
		.enqueue_dma_id_i(ctrl_load_txn_dma_id_i),
		.dequeue_valid_o(config_dequeue_valid),
		.dequeue_ready_i(config_dequeue_ready),
		.dequeue_source_address_o(),
		.dequeue_byte_count_o(config_byte_count),
		.dequeue_scope_o(config_scope),
		.dequeue_destination_o(config_destination),
		.dequeue_format_o(config_format),
		.dequeue_imem_base_address_o(config_imem_base_address),
		.dequeue_image_first_o(config_image_first),
		.dequeue_image_last_o(config_image_last),
		.dequeue_expected_word_count_o(config_expected_word_count),
		.dequeue_dma_id_o(config_dma_id),
		.level_o(),
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
		.ctrl_dma_cmd_valid_i(ctrl_dma_cmd_valid),
		.ctrl_dma_cmd_ready_o(ctrl_dma_cmd_ready),
		.ctrl_dma_cmd_address_i(ctrl_load_txn_source_address_i),
		.ctrl_dma_cmd_length_i(ctrl_load_txn_byte_count_i),
		.ctrl_dma_cmd_id_i(ctrl_load_txn_dma_id_i),
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
		.reasm_rsp_valid_o(reasm_rsp_valid),
		.reasm_rsp_ready_i(reasm_rsp_ready),
		.reasm_rsp_data_o(reasm_rsp_data),
		.reasm_rsp_keep_o(reasm_rsp_keep),
		.reasm_rsp_last_o(reasm_rsp_last),
		.reasm_rsp_id_o(reasm_rsp_id),
		.reasm_rsp_error_o(reasm_rsp_error),
		.outstanding_o(),
		.idle_o(dma_idle),
		.fault_o(dma_fault),
		.fault_code_o(dma_fault_code)
	);

	lpu_program_load_reassembler #(
		.DMA_DATA_WIDTH(DMA_DATA_WIDTH),
		.BUFFER_BYTES(REASSEMBLY_BUFFER_BYTES),
		.IMEM_DEPTH(IMEM_DEPTH)
	) u_reassembler (
		.clk_i,
		.rst_ni(internal_rst_ni),
		.config_fifo_dequeue_valid_i(config_dequeue_valid),
		.config_fifo_dequeue_ready_o(config_dequeue_ready),
		.config_fifo_dequeue_byte_count_i(config_byte_count),
		.config_fifo_dequeue_scope_i(config_scope),
		.config_fifo_dequeue_destination_i(config_destination),
		.config_fifo_dequeue_format_i(config_format),
		.config_fifo_dequeue_imem_base_address_i(config_imem_base_address),
		.config_fifo_dequeue_image_first_i(config_image_first),
		.config_fifo_dequeue_image_last_i(config_image_last),
		.config_fifo_dequeue_expected_word_count_i(config_expected_word_count),
		.config_fifo_dequeue_dma_id_i(config_dma_id),
		.reasm_rsp_valid_i(reasm_rsp_valid),
		.reasm_rsp_ready_o(reasm_rsp_ready),
		.reasm_rsp_data_i(reasm_rsp_data),
		.reasm_rsp_keep_i(reasm_rsp_keep),
		.reasm_rsp_last_i(reasm_rsp_last),
		.reasm_rsp_id_i(reasm_rsp_id),
		.reasm_rsp_error_i(reasm_rsp_error),
		.reasm_word_valid_o(word_fifo_enqueue_valid),
		.reasm_word_ready_i(word_fifo_enqueue_ready),
		.reasm_word_data_o(word_fifo_enqueue_data),
		.reasm_word_strb_o(word_fifo_enqueue_strb),
		.reasm_word_scope_o(word_fifo_enqueue_scope),
		.reasm_word_destination_o(word_fifo_enqueue_destination),
		.reasm_word_imem_address_o(word_fifo_enqueue_imem_address),
		.reasm_word_image_last_o(word_fifo_enqueue_last),
		.received_byte_count_o(),
		.generated_word_count_o(),
		.idle_o(reassembler_idle),
		.fault_o(reassembler_fault),
		.fault_code_o(reassembler_fault_code)
	);

	lpu_program_load_word_fifo #(
		.DEPTH(WORD_FIFO_DEPTH)
	) u_word_fifo (
		.clk_i,
		.rst_ni(internal_rst_ni),
		.enqueue_valid_i(word_fifo_enqueue_valid),
		.enqueue_ready_o(word_fifo_enqueue_ready),
		.enqueue_data_i(word_fifo_enqueue_data),
		.enqueue_strb_i(word_fifo_enqueue_strb),
		.enqueue_scope_i(word_fifo_enqueue_scope),
		.enqueue_destination_i(word_fifo_enqueue_destination),
		.enqueue_imem_address_i(word_fifo_enqueue_imem_address),
		.enqueue_last_i(word_fifo_enqueue_last),
		.dequeue_valid_o(load_word_valid_o),
		.dequeue_ready_i(load_word_ready_i),
		.dequeue_data_o(load_word_data_o),
		.dequeue_strb_o(load_word_strb_o),
		.dequeue_scope_o(load_word_scope_o),
		.dequeue_destination_o(load_word_destination_o),
		.dequeue_imem_address_o(load_word_imem_address_o),
		.dequeue_last_o(load_word_last_o),
		.level_o(),
		.empty_o(word_fifo_empty),
		.full_o()
	);

	assign idle_o = dma_idle && config_empty && reassembler_idle && word_fifo_empty;
	assign generated_word_count_o = generated_word_count_q;
	assign fault_o = dma_fault || reassembler_fault;
	assign fault_code_o = dma_fault ? dma_fault_code :
		(reassembler_fault ? reassembler_fault_code : PROGRAM_FAULT_NONE);

	// Count each reconstructed Program Word accepted by the downstream Word FIFO.
	always_ff @(posedge clk_i or negedge internal_rst_ni) begin
		if(!internal_rst_ni)begin
			generated_word_count_q <= '0;
		end
		else if(word_fifo_enqueue_valid && word_fifo_enqueue_ready)begin
			generated_word_count_q <= generated_word_count_q + 1'b1;
		end
	end
endmodule
