module lpu_mxm_load_macro_decoder (
	input  logic        clk_i,
	input  logic        rst_ni,
	input  logic        word_valid_i,
	output logic        word_ready_o,
	input  logic [127:0] word_i,
	input  logic        word_last_i,
	output logic        context_valid_o,
	input  logic        context_ready_i,
	output logic [28:0] context_instruction_o,
	output logic [31:0] context_start_cycle_o,
	output logic [31:0] context_inner_count_o,
	output logic [31:0] context_inner_interval_o,
	output logic signed [31:0] context_inner_stride_o,
	output logic [31:0] context_outer_count_o,
	output logic [31:0] context_outer_interval_o,
	output logic signed [31:0] context_outer_stride_o,
	output logic [1:0]  context_induction_target_o,
	output logic [1:0]  context_operand_o,
	output logic        done_o,
	output logic        fault_o,
	output logic [3:0]  fault_code_o
);
	logic [48:0] core_instruction;
	logic [12:0] core_operand;

	assign context_instruction_o = core_instruction[28:0];
	assign context_operand_o = core_operand[1:0];

	lpu_mxm_macro_decoder_core #(
		.QUEUE_KIND(0)
	) u_core (
		.clk_i,
		.rst_ni,
		.word_valid_i,
		.word_ready_o,
		.word_i,
		.word_last_i,
		.context_valid_o,
		.context_ready_i,
		.context_instruction_o(core_instruction),
		.context_start_cycle_o,
		.context_inner_count_o,
		.context_inner_interval_o,
		.context_inner_stride_o,
		.context_outer_count_o,
		.context_outer_interval_o,
		.context_outer_stride_o,
		.context_induction_target_o,
		.context_operand_o(core_operand),
		.done_o,
		.fault_o,
		.fault_code_o
	);
endmodule
