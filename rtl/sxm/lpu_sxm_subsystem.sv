module lpu_sxm_subsystem (
	input logic clk_i,
	input logic rst_ni,
	input logic run_i,
	input logic transpose_issue_valid_i,
	input logic [415:0] transpose_issue_instruction_i,
	input logic permute_issue_valid_i,
	input logic [415:0] permute_issue_instruction_i,
	input logic [4*32-1:0] east_inner_valid_i,
	input logic [4*32*64-1:0] east_inner_data_i,
	output logic [4*32-1:0] east_outer_valid_o,
	output logic [4*32*64-1:0] east_outer_data_o,
	input logic [4*32-1:0] west_outer_valid_i,
	input logic [4*32*64-1:0] west_outer_data_i,
	output logic [4*32-1:0] west_inner_valid_o,
	output logic [4*32*64-1:0] west_inner_data_o,
	output logic fault_o,
	output logic conflict_o
);

	// Program Load integration remains blocked until the SXM local-iMEM transport is fixed.
	lpu_sxm_slice u_execution (
		.clk_i,
		.rst_ni,
		.run_i,
		.transpose_issue_valid_i,
		.transpose_issue_instruction_i,
		.permute_issue_valid_i,
		.permute_issue_instruction_i,
		.east_inner_valid_i,
		.east_inner_data_i,
		.east_outer_valid_o,
		.east_outer_data_o,
		.west_outer_valid_i,
		.west_outer_data_i,
		.west_inner_valid_o,
		.west_inner_data_o,
		.fault_o,
		.conflict_o
	);
endmodule
