module lpu_program_load_word_fifo #(
	parameter integer DEPTH = 8
) (
	input logic clk_i,
	input logic rst_ni,

	input logic enqueue_valid_i,
	output logic enqueue_ready_o,
	input logic [127:0] enqueue_data_i,
	input logic [3:0] enqueue_strb_i,
	input logic [1:0] enqueue_scope_i,
	input logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		enqueue_destination_i,
	input logic [16:0] enqueue_imem_address_i,
	input logic enqueue_last_i,

	output logic dequeue_valid_o,
	input logic dequeue_ready_i,
	output logic [127:0] dequeue_data_o,
	output logic [3:0] dequeue_strb_o,
	output logic [1:0] dequeue_scope_o,
	output logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		dequeue_destination_o,
	output logic [16:0] dequeue_imem_address_o,
	output logic dequeue_last_o,

	output logic [$clog2(DEPTH+1)-1:0] level_o,
	output logic empty_o,
	output logic full_o
);
	localparam integer WORD_RECORD_WIDTH = 128 + 4 + 2 +
		lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH + 17 + 1;

	logic [WORD_RECORD_WIDTH-1:0] enqueue_record;
	logic [WORD_RECORD_WIDTH-1:0] dequeue_record;

	assign enqueue_record = {
		enqueue_data_i,
		enqueue_strb_i,
		enqueue_scope_i,
		enqueue_destination_i,
		enqueue_imem_address_i,
		enqueue_last_i
	};
	assign {
		dequeue_data_o,
		dequeue_strb_o,
		dequeue_scope_o,
		dequeue_destination_o,
		dequeue_imem_address_o,
		dequeue_last_o
	} = dequeue_record;

	assign empty_o = level_o == '0;
	assign full_o = level_o == DEPTH;

	lpu_fifo #(
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
