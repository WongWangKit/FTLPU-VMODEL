module lpu_mxm_local_coordinator (
	input logic clk_i,
	input logic rst_ni,
	input logic run_i,
	input logic pair_load_dequant_i,
	input logic [31:0] load_schedule_cycle_i,
	input logic [31:0] dequant_schedule_cycle_i,
	input logic [31:0] compute_schedule_cycle_i,

	// Scheduler source ports.
	input  logic        load_valid_i,
	output logic        load_ready_o,
	input  logic [28:0] load_instruction_i,
	input  logic [31:0] load_cycle_i,
	input  logic        dequant_valid_i,
	output logic        dequant_ready_o,
	input  logic [15:0] dequant_instruction_i,
	input  logic [31:0] dequant_cycle_i,
	input  logic        compute_valid_i,
	output logic        compute_ready_o,
	input  logic [48:0] compute_instruction_i,
	input  logic [31:0] compute_cycle_i,

	// MXM-local issue ports retain the three native instruction widths.
	output logic        load_issue_valid_o,
	input  logic        load_issue_ready_i,
	output logic [28:0] load_issue_instruction_o,
	output logic [31:0] load_issue_cycle_o,
	output logic        dequant_issue_valid_o,
	input  logic        dequant_issue_ready_i,
	output logic [15:0] dequant_issue_instruction_o,
	output logic [31:0] dequant_issue_cycle_o,
	output logic        compute_issue_valid_o,
	input  logic        compute_issue_ready_i,
	output logic [48:0] compute_issue_instruction_o,
	output logic [31:0] compute_issue_cycle_o,

	output logic fault_o,
	output logic [2:0] fault_code_o
);
	localparam logic [2:0] FAULT_NONE = 3'd0;
	localparam logic [2:0] FAULT_PAIR_MISSING = 3'd1;
	localparam logic [2:0] FAULT_PAIR_CYCLE = 3'd2;
	localparam logic [2:0] FAULT_SOURCE_CYCLE = 3'd3;

	logic pair_present_w;
	logic pair_cycle_match_w;
	logic pair_ready_w;
	logic pair_missing_w;
	logic pair_cycle_fault_w;
	logic source_cycle_fault_w;
	logic dynamic_fault_w;
	logic [2:0] dynamic_fault_code_w;
	logic fault_q;
	logic [2:0] fault_code_q;

	assign load_issue_instruction_o = load_instruction_i;
	assign load_issue_cycle_o = load_cycle_i;
	assign dequant_issue_instruction_o = dequant_instruction_i;
	assign dequant_issue_cycle_o = dequant_cycle_i;
	assign compute_issue_instruction_o = compute_instruction_i;
	assign compute_issue_cycle_o = compute_cycle_i;

	assign pair_present_w = load_valid_i && dequant_valid_i;
	assign pair_cycle_match_w = load_cycle_i == dequant_cycle_i;
	assign pair_ready_w = load_issue_ready_i && dequant_issue_ready_i;
	assign pair_missing_w = run_i && pair_load_dequant_i && (load_valid_i != dequant_valid_i);
	assign pair_cycle_fault_w = run_i && pair_load_dequant_i && pair_present_w && !pair_cycle_match_w;
	assign source_cycle_fault_w = run_i &&
		((load_valid_i && (load_cycle_i != load_schedule_cycle_i)) ||
		(dequant_valid_i && (dequant_cycle_i != dequant_schedule_cycle_i)) ||
		(compute_valid_i && (compute_cycle_i != compute_schedule_cycle_i)));

	// Paired mode makes Load and Dequant one atomic transfer; independent mode is a direct pass-through.
	always_comb begin
		load_issue_valid_o = 1'b0;
		dequant_issue_valid_o = 1'b0;
		load_ready_o = 1'b0;
		dequant_ready_o = 1'b0;
		if(!fault_q && !dynamic_fault_w)begin
			if(pair_load_dequant_i)begin
				load_issue_valid_o = pair_present_w && pair_cycle_match_w && dequant_issue_ready_i;
				dequant_issue_valid_o = pair_present_w && pair_cycle_match_w && load_issue_ready_i;
				load_ready_o = pair_present_w && pair_cycle_match_w && pair_ready_w;
				dequant_ready_o = pair_present_w && pair_cycle_match_w && pair_ready_w;
			end
			else begin
				load_issue_valid_o = load_valid_i;
				dequant_issue_valid_o = dequant_valid_i;
				load_ready_o = load_issue_ready_i;
				dequant_ready_o = dequant_issue_ready_i;
			end
		end
	end

	// Compute has an independent native stream and is checked against its Queue-local cycle.
	assign compute_issue_valid_o = compute_valid_i && !fault_q && !dynamic_fault_w;
	assign compute_ready_o = compute_issue_ready_i && !fault_q && !dynamic_fault_w;

	always_comb begin
		dynamic_fault_w = 1'b0;
		dynamic_fault_code_w = FAULT_NONE;
		if(source_cycle_fault_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_SOURCE_CYCLE;
		end
		else if(pair_cycle_fault_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_PAIR_CYCLE;
		end
		else if(pair_missing_w)begin
			dynamic_fault_w = 1'b1;
			dynamic_fault_code_w = FAULT_PAIR_MISSING;
		end
	end

	assign fault_o = fault_q || dynamic_fault_w;
	assign fault_code_o = fault_q ? fault_code_q : dynamic_fault_code_w;

	// Coordination faults are sticky because Scheduler sources cannot replay a missed absolute cycle.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else if(!fault_q && dynamic_fault_w)begin
			fault_q <= 1'b1;
			fault_code_q <= dynamic_fault_code_w;
		end
	end
endmodule
