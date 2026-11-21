module lpu_program_load_elastic_stage #(
	parameter integer DEPTH = 2
) (
	input logic clk_i,
	input logic rst_ni,

	input logic input_valid_i,
	output logic input_ready_o,
	input logic [2:0] input_control_i,
	input logic [127:0] input_data_i,
	input logic [3:0] input_strb_i,
	input logic [1:0] input_hemisphere_i,
	input logic [3:0] input_target_kind_i,
	input logic [7:0] input_queue_id_i,
	input logic [16:0] input_imem_address_i,
	input logic input_last_i,

	output logic output_valid_o,
	input logic output_ready_i,
	output logic [2:0] output_control_o,
	output logic [127:0] output_data_o,
	output logic [3:0] output_strb_o,
	output logic [1:0] output_hemisphere_o,
	output logic [3:0] output_target_kind_o,
	output logic [7:0] output_queue_id_o,
	output logic [16:0] output_imem_address_o,
	output logic output_last_o,

	output logic [$clog2(DEPTH+1)-1:0] level_o,
	output logic idle_o
);
	localparam integer RECORD_WIDTH = 167;

	logic [RECORD_WIDTH-1:0] input_record;
	logic [RECORD_WIDTH-1:0] output_record;
	logic empty_w;

	assign input_record = {
		input_control_i,
		input_data_i,
		input_strb_i,
		input_hemisphere_i,
		input_target_kind_i,
		input_queue_id_i,
		input_imem_address_i,
		input_last_i
	};
	assign {
		output_control_o,
		output_data_o,
		output_strb_o,
		output_hemisphere_o,
		output_target_kind_o,
		output_queue_id_o,
		output_imem_address_o,
		output_last_o
	} = output_record;

	// A two-entry FIFO breaks the long data path and absorbs one cycle of local target backpressure.
	lpu_queue_fifo #(
		.DATA_WIDTH(RECORD_WIDTH),
		.DEPTH(DEPTH)
	) u_elastic_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i(input_valid_i),
		.enqueue_ready_o(input_ready_o),
		.enqueue_data_i(input_record),
		.dequeue_valid_o(output_valid_o),
		.dequeue_ready_i(output_ready_i),
		.dequeue_data_o(output_record),
		.level_o
	);

	assign empty_w = level_o == '0;
	assign idle_o = empty_w;
endmodule
