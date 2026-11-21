module lpu_program_config_fifo #(
	parameter integer DEPTH = 16
) (
	input logic clk_i,
	input logic rst_ni,

	input logic enqueue_valid_i,
	output logic enqueue_ready_o,
	input logic [63:0] enqueue_source_address_i,
	input logic [31:0] enqueue_byte_count_i,
	input logic [1:0] enqueue_hemisphere_i,
	input logic [3:0] enqueue_target_kind_i,
	input logic [7:0] enqueue_queue_id_i,
	input logic [1:0] enqueue_format_i,
	input logic [16:0] enqueue_imem_base_address_i,
	input logic enqueue_image_first_i,
	input logic enqueue_image_last_i,
	input logic [15:0] enqueue_expected_word_count_i,
	input logic [7:0] enqueue_dma_id_i,

	output logic dequeue_valid_o,
	input logic dequeue_ready_i,
	output logic [63:0] dequeue_source_address_o,
	output logic [31:0] dequeue_byte_count_o,
	output logic [1:0] dequeue_hemisphere_o,
	output logic [3:0] dequeue_target_kind_o,
	output logic [7:0] dequeue_queue_id_o,
	output logic [1:0] dequeue_format_o,
	output logic [16:0] dequeue_imem_base_address_o,
	output logic dequeue_image_first_o,
	output logic dequeue_image_last_o,
	output logic [15:0] dequeue_expected_word_count_o,
	output logic [7:0] dequeue_dma_id_o,

	output logic [$clog2(DEPTH+1)-1:0] level_o,
	output logic empty_o,
	output logic full_o
);
	localparam integer CONFIG_WIDTH = 155;

	logic [CONFIG_WIDTH-1:0] enqueue_data;
	logic [CONFIG_WIDTH-1:0] dequeue_data;

	// A FIFO entry is one complete DMA transaction descriptor, not one response beat.
	assign enqueue_data = {
		enqueue_source_address_i,
		enqueue_byte_count_i,
		enqueue_hemisphere_i,
		enqueue_target_kind_i,
		enqueue_queue_id_i,
		enqueue_format_i,
		enqueue_imem_base_address_i,
		enqueue_image_first_i,
		enqueue_image_last_i,
		enqueue_expected_word_count_i,
		enqueue_dma_id_i
	};

	assign {
		dequeue_source_address_o,
		dequeue_byte_count_o,
		dequeue_hemisphere_o,
		dequeue_target_kind_o,
		dequeue_queue_id_o,
		dequeue_format_o,
		dequeue_imem_base_address_o,
		dequeue_image_first_o,
		dequeue_image_last_o,
		dequeue_expected_word_count_o,
		dequeue_dma_id_o
	} = dequeue_data;

	assign empty_o = level_o == '0;
	assign full_o = level_o == DEPTH;

	lpu_queue_fifo #(
		.DATA_WIDTH(CONFIG_WIDTH),
		.DEPTH(DEPTH)
	) u_config_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i,
		.enqueue_ready_o,
		.enqueue_data_i(enqueue_data),
		.dequeue_valid_o,
		.dequeue_ready_i,
		.dequeue_data_o(dequeue_data),
		.level_o
	);
endmodule
