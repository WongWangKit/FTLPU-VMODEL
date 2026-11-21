module lpu_program_word_fifo #(
	parameter integer DEPTH = 8
) (
	input logic clk_i,
	input logic rst_ni,

	input logic enqueue_valid_i,
	output logic enqueue_ready_o,
	input logic [127:0] enqueue_data_i,
	input logic [3:0] enqueue_strb_i,
	input logic [1:0] enqueue_hemisphere_i,
	input logic [3:0] enqueue_target_kind_i,
	input logic [7:0] enqueue_queue_id_i,
	input logic [16:0] enqueue_imem_address_i,
	input logic enqueue_last_i,

	output logic dequeue_valid_o,
	input logic dequeue_ready_i,
	output logic [127:0] dequeue_data_o,
	output logic [3:0] dequeue_strb_o,
	output logic [1:0] dequeue_hemisphere_o,
	output logic [3:0] dequeue_target_kind_o,
	output logic [7:0] dequeue_queue_id_o,
	output logic [16:0] dequeue_imem_address_o,
	output logic dequeue_last_o,

	output logic [$clog2(DEPTH+1)-1:0] level_o,
	output logic empty_o,
	output logic full_o
);
	localparam integer WORD_RECORD_WIDTH = 164;

	logic [WORD_RECORD_WIDTH-1:0] enqueue_record;
	logic [WORD_RECORD_WIDTH-1:0] dequeue_record;

	assign enqueue_record = {
		enqueue_data_i,
		enqueue_strb_i,
		enqueue_hemisphere_i,
		enqueue_target_kind_i,
		enqueue_queue_id_i,
		enqueue_imem_address_i,
		enqueue_last_i
	};
	assign {
		dequeue_data_o,
		dequeue_strb_o,
		dequeue_hemisphere_o,
		dequeue_target_kind_o,
		dequeue_queue_id_o,
		dequeue_imem_address_o,
		dequeue_last_o
	} = dequeue_record;

	assign empty_o = level_o == '0;
	assign full_o = level_o == DEPTH;

	lpu_queue_fifo #(
		.DATA_WIDTH(WORD_RECORD_WIDTH),
		.DEPTH(DEPTH)
	) u_word_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i,
		.enqueue_ready_o,
		.enqueue_data_i(enqueue_record),
		.dequeue_valid_o,
		.dequeue_ready_i,
		.dequeue_data_o(dequeue_record),
		.level_o
	);
endmodule
