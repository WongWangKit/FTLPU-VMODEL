module lpu_program_distributor #(
	parameter integer ELASTIC_DEPTH = 2
) (
	input logic clk_i,
	input logic rst_ni,

	input logic load_record_valid_i,
	output logic load_record_ready_o,
	input logic [lpu_program_load_pkg::PROGRAM_LOAD_CONTROL_WIDTH-1:0] load_record_control_i,
	input logic [127:0] load_record_data_i,
	input logic [3:0] load_record_strb_i,
	input logic [1:0] load_record_scope_i,
	input logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		load_record_destination_i,
	input logic [16:0] load_record_imem_address_i,
	input logic load_record_last_i,

	output logic west_relay_valid_o,
	input logic west_relay_ready_i,
	output logic [lpu_program_load_pkg::PROGRAM_LOAD_CONTROL_WIDTH-1:0] west_relay_control_o,
	output logic [127:0] west_relay_data_o,
	output logic [3:0] west_relay_strb_o,
	output logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		west_relay_destination_o,
	output logic [16:0] west_relay_imem_address_o,
	output logic west_relay_last_o,

	output logic east_relay_valid_o,
	input logic east_relay_ready_i,
	output logic [lpu_program_load_pkg::PROGRAM_LOAD_CONTROL_WIDTH-1:0] east_relay_control_o,
	output logic [127:0] east_relay_data_o,
	output logic [3:0] east_relay_strb_o,
	output logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		east_relay_destination_o,
	output logic [16:0] east_relay_imem_address_o,
	output logic east_relay_last_o,

	output logic idle_o,
	output logic fault_o,
	output logic [5:0] fault_code_o
);
	import lpu_program_load_pkg::*;

	logic head_valid;
	logic head_ready;
	logic [PROGRAM_LOAD_CONTROL_WIDTH-1:0] head_control;
	logic [127:0] head_data;
	logic [3:0] head_strb;
	logic [1:0] head_scope;
	logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0] head_destination;
	logic [16:0] head_imem_address;
	logic head_last;
	logic elastic_idle;
	logic [lpu_program_load_pkg::PROGRAM_TARGET_KIND_WIDTH-1:0] head_target_kind_w;
	logic vxm_target_w;

	logic west_relay_required_w;
	logic east_relay_required_w;
	logic west_relay_done_q;
	logic east_relay_done_q;
	logic west_relay_fire;
	logic east_relay_fire;
	logic west_relay_complete_w;
	logic east_relay_complete_w;
	logic scope_illegal_w;
	logic scope_mismatch_w;
	logic route_illegal_w;
	logic fault_q;

	lpu_program_distribute_elastic_stage #(
		.DEPTH(ELASTIC_DEPTH)
	) u_load_record_elastic (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i(load_record_valid_i),
		.enqueue_ready_o(load_record_ready_o),
		.enqueue_control_i(load_record_control_i),
		.enqueue_data_i(load_record_data_i),
		.enqueue_strb_i(load_record_strb_i),
		.enqueue_scope_i(load_record_scope_i),
		.enqueue_destination_i(load_record_destination_i),
		.enqueue_imem_address_i(load_record_imem_address_i),
		.enqueue_last_i(load_record_last_i),
		.dequeue_valid_o(head_valid),
		.dequeue_ready_i(head_ready),
		.dequeue_control_o(head_control),
		.dequeue_data_o(head_data),
		.dequeue_strb_o(head_strb),
		.dequeue_scope_o(head_scope),
		.dequeue_destination_o(head_destination),
		.dequeue_imem_address_o(head_imem_address),
		.dequeue_last_o(head_last),
		.level_o(),
		.idle_o(elastic_idle)
	);

	assign head_target_kind_w = head_destination[
		PROGRAM_DESTINATION_KIND_MSB:PROGRAM_DESTINATION_KIND_LSB];
	assign vxm_target_w = head_target_kind_w == PROGRAM_TARGET_VXM;
	// The central VXM uses the East output as its canonical direct branch. BOTH
	// never duplicates a VXM Program Load request into both Hemisphere chains.
	assign west_relay_required_w = !vxm_target_w && ((head_scope == PROGRAM_SCOPE_WEST) ||
		(head_scope == PROGRAM_SCOPE_BOTH));
	assign east_relay_required_w = vxm_target_w || (head_scope == PROGRAM_SCOPE_EAST) ||
		(head_scope == PROGRAM_SCOPE_BOTH);
	assign scope_illegal_w = (head_scope != PROGRAM_SCOPE_EAST) &&
		(head_scope != PROGRAM_SCOPE_WEST) && (head_scope != PROGRAM_SCOPE_BOTH);
	assign scope_mismatch_w = ((!vxm_target_w && (head_scope == PROGRAM_SCOPE_EAST)) &&
		(head_destination[PROGRAM_DESTINATION_HEMISPHERE_BIT] != PROGRAM_HEMISPHERE_EAST)) ||
		((!vxm_target_w && (head_scope == PROGRAM_SCOPE_WEST)) &&
		 (head_destination[PROGRAM_DESTINATION_HEMISPHERE_BIT] != PROGRAM_HEMISPHERE_WEST));
	assign route_illegal_w = head_valid && (scope_illegal_w || scope_mismatch_w);

	assign west_relay_valid_o = head_valid && west_relay_required_w && !west_relay_done_q && !fault_q;
	assign east_relay_valid_o = head_valid && east_relay_required_w && !east_relay_done_q && !fault_q;
	assign west_relay_fire = west_relay_valid_o && west_relay_ready_i;
	assign east_relay_fire = east_relay_valid_o && east_relay_ready_i;
	assign west_relay_complete_w = !west_relay_required_w || west_relay_done_q || west_relay_fire;
	assign east_relay_complete_w = !east_relay_required_w || east_relay_done_q || east_relay_fire;
	assign head_ready = head_valid && (route_illegal_w ||
		(west_relay_complete_w && east_relay_complete_w && !fault_q));

	assign west_relay_control_o = head_control;
	assign west_relay_data_o = head_data;
	assign west_relay_strb_o = head_strb;
	assign west_relay_destination_o = {PROGRAM_HEMISPHERE_WEST,
		head_destination[PROGRAM_DESTINATION_KIND_MSB:PROGRAM_DESTINATION_INDEX_LSB]};
	assign west_relay_imem_address_o = head_imem_address;
	assign west_relay_last_o = head_last;

	assign east_relay_control_o = head_control;
	assign east_relay_data_o = head_data;
	assign east_relay_strb_o = head_strb;
	assign east_relay_destination_o = {PROGRAM_HEMISPHERE_EAST,
		head_destination[PROGRAM_DESTINATION_KIND_MSB:PROGRAM_DESTINATION_INDEX_LSB]};
	assign east_relay_imem_address_o = head_imem_address;
	assign east_relay_last_o = head_last;

	assign idle_o = elastic_idle && !west_relay_done_q && !east_relay_done_q;
	assign fault_o = fault_q || route_illegal_w;
	assign fault_code_o = fault_o ? PROGRAM_FAULT_ROUTE : PROGRAM_FAULT_NONE;

	// West and East are independent ready/valid branches; a BOTH command is retired after both handshakes.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			west_relay_done_q <= 1'b0;
			east_relay_done_q <= 1'b0;
		end
		else begin
			if(head_ready)begin
				west_relay_done_q <= 1'b0;
				east_relay_done_q <= 1'b0;
			end
			else begin
				if(west_relay_fire)begin
					west_relay_done_q <= 1'b1;
				end
				if(east_relay_fire)begin
					east_relay_done_q <= 1'b1;
				end
			end
		end
	end

	// Invalid scope or destination routing remains sticky until reset.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
		end
		else if(route_illegal_w)begin
			fault_q <= 1'b1;
		end
	end
endmodule
