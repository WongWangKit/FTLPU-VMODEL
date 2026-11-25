// Program Distribute System owns the input elastic stage, East/West expansion,
// both physical seven-Relay chains and all FU-local iMEM routing.
module lpu_program_distribute_system (
	input logic clk_i,
	input logic rst_ni,
	input logic program_reset_i,

	input logic load_distribute_valid_i,
	output logic load_distribute_ready_o,
	input logic [lpu_program_load_pkg::PROGRAM_LOAD_CONTROL_WIDTH-1:0] load_distribute_control_i,
	input logic [127:0] load_distribute_data_i,
	input logic [3:0] load_distribute_strb_i,
	input logic [1:0] load_distribute_scope_i,
	input logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		load_distribute_destination_i,
	input logic [16:0] load_distribute_imem_address_i,
	input logic load_distribute_last_i,

	output logic [lpu_program_load_pkg::PROGRAM_RELAY_PORT_COUNT-1:0] mem_program_valid_o,
	input logic [lpu_program_load_pkg::PROGRAM_RELAY_PORT_COUNT-1:0] mem_program_ready_i,
	output logic [lpu_program_load_pkg::PROGRAM_RELAY_PORT_COUNT*
		lpu_program_load_pkg::PROGRAM_LOAD_CONTROL_WIDTH-1:0] mem_program_control_o,
	output logic [lpu_program_load_pkg::PROGRAM_RELAY_PORT_COUNT*
		lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		mem_program_destination_o,
	output logic [lpu_program_load_pkg::PROGRAM_RELAY_PORT_COUNT*17-1:0]
		mem_program_imem_address_o,
	output logic [lpu_program_load_pkg::PROGRAM_RELAY_PORT_COUNT*128-1:0]
		mem_program_data_o,
	output logic [lpu_program_load_pkg::PROGRAM_RELAY_PORT_COUNT*4-1:0] mem_program_strb_o,
	output logic [lpu_program_load_pkg::PROGRAM_RELAY_PORT_COUNT-1:0] mem_program_last_o,
	input logic [lpu_program_load_pkg::PROGRAM_RELAY_PORT_COUNT-1:0] mem_program_error_i,

	output logic [3:0] mxm_program_valid_o,
	input logic [3:0] mxm_program_ready_i,
	input logic [3:0] mxm_program_error_i,
	output logic [1:0] sxm_program_valid_o,
	input logic [1:0] sxm_program_ready_i,
	input logic [1:0] sxm_program_error_i,
	output logic [2*lpu_program_load_pkg::PROGRAM_LOAD_CONTROL_WIDTH-1:0] outer_program_control_o,
	output logic [2*lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		outer_program_destination_o,
	output logic [33:0] outer_program_address_o,
	output logic [255:0] outer_program_data_o,
	output logic [7:0] outer_program_strb_o,
	output logic [1:0] outer_program_last_o,

	output logic vxm_program_valid_o,
	input logic vxm_program_ready_i,
	input logic vxm_program_error_i,
	output logic [lpu_program_load_pkg::PROGRAM_LOAD_CONTROL_WIDTH-1:0] vxm_program_control_o,
	output logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0] vxm_program_destination_o,
	output logic [16:0] vxm_program_address_o,
	output logic [127:0] vxm_program_data_o,
	output logic [3:0] vxm_program_strb_o,
	output logic vxm_program_last_o,

	output logic idle_o,
	output logic fault_o,
	output logic [5:0] fault_code_o
);
	import lpu_program_load_pkg::*;

	localparam logic [5:0] FAULT_NONE = 6'd0;
	localparam logic [5:0] FAULT_ROUTE = 6'd1;
	localparam integer PROGRAM_COMPLETION_SOURCE_COUNT = PROGRAM_RELAY_PORT_COUNT + 3;

	logic program_transport_rst_ni;
	logic route_fault_q;
	logic [1:0] destination_hemisphere_match_w;
	logic [2*PROGRAM_TARGET_KIND_WIDTH-1:0] destination_target_kind_w;
	logic [15:0] destination_target_index_w;
	logic [PROGRAM_RELAY_PORT_COUNT-1:0] mem_write_fire_w;
	logic [PROGRAM_RELAY_PORT_COUNT-1:0] mem_write_error_w;
	logic [1:0] outer_write_fire_w;
	logic [1:0] outer_write_error_w;
	logic vxm_write_fire_w;
	logic vxm_write_error_w;
	logic [1:0] illegal_write_error_w;
	logic [1:0] route_error_fire_w;
	logic [PROGRAM_COMPLETION_SOURCE_COUNT-1:0] commit_valid_q;
	logic distributor_idle;
	logic distributor_fault;
	logic [5:0] distributor_fault_code;

	logic [1:0] endpoint_load_valid;
	logic [1:0] endpoint_load_ready;
	logic [2*PROGRAM_LOAD_CONTROL_WIDTH-1:0] endpoint_load_control;
	logic [255:0] endpoint_load_data;
	logic [7:0] endpoint_load_strb;
	logic [2*PROGRAM_DESTINATION_WIDTH-1:0] endpoint_load_destination;
	logic [33:0] endpoint_load_imem_address;
	logic [1:0] endpoint_load_last;

	logic [PROGRAM_RELAY_PORT_COUNT-1:0] mem_program_valid;
	logic [PROGRAM_RELAY_PORT_COUNT-1:0] mem_program_ready;
	logic [PROGRAM_RELAY_PORT_COUNT-1:0] mem_program_error;
	logic [PROGRAM_RELAY_PORT_COUNT*PROGRAM_LOAD_CONTROL_WIDTH-1:0] mem_program_control;
	logic [PROGRAM_RELAY_PORT_COUNT*PROGRAM_DESTINATION_WIDTH-1:0] mem_program_destination;
	logic [PROGRAM_RELAY_PORT_COUNT*17-1:0] mem_program_imem_address;
	logic [PROGRAM_RELAY_PORT_COUNT*128-1:0] mem_program_data;
	logic [PROGRAM_RELAY_PORT_COUNT*4-1:0] mem_program_strb;
	logic [PROGRAM_RELAY_PORT_COUNT-1:0] mem_program_last;
	logic [3:0] mxm_program_valid;
	logic [3:0] mxm_program_ready;
	logic [3:0] mxm_program_error;
	logic [2*PROGRAM_LOAD_CONTROL_WIDTH-1:0] outer_program_control;
	logic [2*PROGRAM_DESTINATION_WIDTH-1:0] outer_program_destination;
	logic [33:0] outer_program_address;
	logic [255:0] outer_program_data;
	logic [7:0] outer_program_strb;
	logic [1:0] outer_program_last;
	logic [1:0] sxm_program_valid;
	logic [1:0] sxm_program_ready;
	logic [1:0] sxm_program_error;
	logic vxm_program_valid;
	logic vxm_program_ready;
	logic vxm_program_error;
	logic [PROGRAM_LOAD_CONTROL_WIDTH-1:0] vxm_program_control;
	logic [PROGRAM_DESTINATION_WIDTH-1:0] vxm_program_destination;
	logic [16:0] vxm_program_address;
	logic [127:0] vxm_program_data;
	logic [3:0] vxm_program_strb;
	logic vxm_program_last;

	logic [1:0] relay_chain_input_valid;
	logic [1:0] relay_chain_input_ready;
	logic [2*lpu_pkg::MEM_BANKS_PER_HEMISPHERE-1:0] relay_mem_valid;
	logic [2*lpu_pkg::MEM_BANKS_PER_HEMISPHERE-1:0] relay_mem_ready;
	logic [2*PROGRAM_RELAY_COUNT*PROGRAM_LOAD_CONTROL_WIDTH-1:0] relay_mem_control;
	logic [2*PROGRAM_RELAY_COUNT*128-1:0] relay_mem_data;
	logic [2*PROGRAM_RELAY_COUNT*4-1:0] relay_mem_strb;
	logic [2*PROGRAM_RELAY_COUNT*2-1:0] relay_mem_scope;
	logic [2*PROGRAM_RELAY_COUNT*PROGRAM_DESTINATION_WIDTH-1:0] relay_mem_destination;
	logic [2*PROGRAM_RELAY_COUNT*17-1:0] relay_mem_imem_address;
	logic [2*PROGRAM_RELAY_COUNT-1:0] relay_mem_last;
	logic [1:0] relay_outer_valid;
	logic [1:0] relay_outer_ready;
	logic [2*PROGRAM_LOAD_CONTROL_WIDTH-1:0] relay_outer_control;
	logic [255:0] relay_outer_data;
	logic [7:0] relay_outer_strb;
	logic [3:0] relay_outer_scope;
	logic [2*PROGRAM_DESTINATION_WIDTH-1:0] relay_outer_destination;
	logic [33:0] relay_outer_address;
	logic [1:0] relay_outer_last;
	logic [1:0] relay_chain_idle;
	logic [1:0] relay_chain_fault;
	logic [11:0] relay_chain_fault_code;
	logic [1:0] endpoint_route_legal_w;
	logic [1:0] endpoint_vxm_route_w;
	logic [1:0] endpoint_chain_route_w;
	logic [1:0] outer_endpoint_fire_w;
	logic [2*PROGRAM_TARGET_KIND_WIDTH-1:0] outer_target_kind_w;
	logic [15:0] outer_target_index_w;
	logic [1:0] outer_mxm_route_w;
	logic [1:0] outer_sxm_route_w;

	assign program_transport_rst_ni = rst_ni && !program_reset_i;
	assign mem_program_ready = mem_program_ready_i;
	assign mem_program_error = mem_program_error_i;
	assign mxm_program_ready = mxm_program_ready_i;
	assign mxm_program_error = mxm_program_error_i;
	assign sxm_program_ready = sxm_program_ready_i;
	assign sxm_program_error = sxm_program_error_i;
	assign vxm_program_ready = vxm_program_ready_i;
	assign vxm_program_error = vxm_program_error_i;

	assign mem_program_valid_o = mem_program_valid;
	assign mem_program_control_o = mem_program_control;
	assign mem_program_destination_o = mem_program_destination;
	assign mem_program_imem_address_o = mem_program_imem_address;
	assign mem_program_data_o = mem_program_data;
	assign mem_program_strb_o = mem_program_strb;
	assign mem_program_last_o = mem_program_last;
	assign mxm_program_valid_o = mxm_program_valid;
	assign sxm_program_valid_o = sxm_program_valid;
	assign outer_program_control_o = outer_program_control;
	assign outer_program_destination_o = outer_program_destination;
	assign outer_program_address_o = outer_program_address;
	assign outer_program_data_o = outer_program_data;
	assign outer_program_strb_o = outer_program_strb;
	assign outer_program_last_o = outer_program_last;
	assign vxm_program_valid_o = vxm_program_valid;
	assign vxm_program_control_o = vxm_program_control;
	assign vxm_program_destination_o = vxm_program_destination;
	assign vxm_program_address_o = vxm_program_address;
	assign vxm_program_data_o = vxm_program_data;
	assign vxm_program_strb_o = vxm_program_strb;
	assign vxm_program_last_o = vxm_program_last;
	assign idle_o = distributor_idle && (&relay_chain_idle) && !(|commit_valid_q);
	assign fault_o = distributor_fault || route_fault_q || (|relay_chain_fault);
	assign fault_code_o = distributor_fault ? distributor_fault_code :
		((route_fault_q || (|relay_chain_fault)) ? FAULT_ROUTE : FAULT_NONE);

	// The Distributor contains the only input elastic stage. It expands one
	// scoped Record into independently backpressured East and West transfers.
	lpu_program_distributor u_distributor (
		.clk_i,
		.rst_ni(program_transport_rst_ni),
		.load_record_valid_i(load_distribute_valid_i),
		.load_record_ready_o(load_distribute_ready_o),
		.load_record_control_i(load_distribute_control_i),
		.load_record_data_i(load_distribute_data_i),
		.load_record_strb_i(load_distribute_strb_i),
		.load_record_scope_i(load_distribute_scope_i),
		.load_record_destination_i(load_distribute_destination_i),
		.load_record_imem_address_i(load_distribute_imem_address_i),
		.load_record_last_i(load_distribute_last_i),
		.west_relay_valid_o(endpoint_load_valid[1]),
		.west_relay_ready_i(endpoint_load_ready[1]),
		.west_relay_control_o(endpoint_load_control[PROGRAM_LOAD_CONTROL_WIDTH+:PROGRAM_LOAD_CONTROL_WIDTH]),
		.west_relay_data_o(endpoint_load_data[128+:128]),
		.west_relay_strb_o(endpoint_load_strb[4+:4]),
		.west_relay_destination_o(endpoint_load_destination[
			PROGRAM_DESTINATION_WIDTH+:PROGRAM_DESTINATION_WIDTH]),
		.west_relay_imem_address_o(endpoint_load_imem_address[17+:17]),
		.west_relay_last_o(endpoint_load_last[1]),
		.east_relay_valid_o(endpoint_load_valid[0]),
		.east_relay_ready_i(endpoint_load_ready[0]),
		.east_relay_control_o(endpoint_load_control[0+:PROGRAM_LOAD_CONTROL_WIDTH]),
		.east_relay_data_o(endpoint_load_data[0+:128]),
		.east_relay_strb_o(endpoint_load_strb[0+:4]),
		.east_relay_destination_o(endpoint_load_destination[0+:PROGRAM_DESTINATION_WIDTH]),
		.east_relay_imem_address_o(endpoint_load_imem_address[0+:17]),
		.east_relay_last_o(endpoint_load_last[0]),
		.idle_o(distributor_idle),
		.fault_o(distributor_fault),
		.fault_code_o(distributor_fault_code)
	);

	// Decode the Hemisphere, FU class and local endpoint index carried by each Distributor branch.
	generate
		for(genvar destination_gen = 0; destination_gen < 2; destination_gen = destination_gen + 1)begin : gen_destination_fields
			assign destination_hemisphere_match_w[destination_gen] =
				endpoint_load_destination[destination_gen*PROGRAM_DESTINATION_WIDTH+
					PROGRAM_DESTINATION_HEMISPHERE_BIT] ==
					(destination_gen == 0 ? PROGRAM_HEMISPHERE_EAST : PROGRAM_HEMISPHERE_WEST);
			assign destination_target_kind_w[destination_gen*PROGRAM_TARGET_KIND_WIDTH+:
				PROGRAM_TARGET_KIND_WIDTH] = endpoint_load_destination[
				destination_gen*PROGRAM_DESTINATION_WIDTH+PROGRAM_DESTINATION_KIND_LSB+:
				PROGRAM_TARGET_KIND_WIDTH];
			assign destination_target_index_w[destination_gen*PROGRAM_TARGET_INDEX_WIDTH+:
				PROGRAM_TARGET_INDEX_WIDTH] = endpoint_load_destination[
				destination_gen*PROGRAM_DESTINATION_WIDTH+PROGRAM_DESTINATION_INDEX_LSB+:
				PROGRAM_TARGET_INDEX_WIDTH];
		end
	endgenerate

	// One physical chain is placed beside each Hemisphere. VXM requests are
	// filtered before this boundary and therefore never enter either chain.
	generate
		for(genvar chain_gen = 0; chain_gen < 2; chain_gen = chain_gen + 1)begin : gen_program_relay_chain
			lpu_program_distribute_relay_chain #(
				.HEMISPHERE_ID(chain_gen),
				.MEM_SLICES_PER_HEMISPHERE(lpu_pkg::MEM_SLICES_PER_HEMISPHERE),
				.MEM_SLICES_PER_GROUP(PROGRAM_RELAY_MEM_SLICES_PER_GROUP),
				.BANKS_PER_SLICE(lpu_pkg::MEM_BANKS_PER_SLICE),
				.MEM_GROUPS_PER_RELAY(PROGRAM_RELAY_MEM_GROUPS_PER_STAGE),
				.MXM_INSTANCES_PER_HEMISPHERE(2),
				.SXM_INSTANCES_PER_HEMISPHERE(1)
			) u_program_relay_chain (
				.clk_i,
				.rst_ni(program_transport_rst_ni),
				.distributor_record_valid_i(relay_chain_input_valid[chain_gen]),
				.distributor_record_ready_o(relay_chain_input_ready[chain_gen]),
				.distributor_record_control_i(endpoint_load_control[
					chain_gen*PROGRAM_LOAD_CONTROL_WIDTH+:PROGRAM_LOAD_CONTROL_WIDTH]),
				.distributor_record_data_i(endpoint_load_data[chain_gen*128+:128]),
				.distributor_record_strb_i(endpoint_load_strb[chain_gen*4+:4]),
				.distributor_record_scope_i(chain_gen == 0 ? PROGRAM_SCOPE_EAST : PROGRAM_SCOPE_WEST),
				.distributor_record_destination_i(endpoint_load_destination[
					chain_gen*PROGRAM_DESTINATION_WIDTH+:PROGRAM_DESTINATION_WIDTH]),
				.distributor_record_imem_address_i(endpoint_load_imem_address[chain_gen*17+:17]),
				.distributor_record_last_i(endpoint_load_last[chain_gen]),
				.mem_endpoint_valid_o(relay_mem_valid[
					chain_gen*lpu_pkg::MEM_BANKS_PER_HEMISPHERE+:
					lpu_pkg::MEM_BANKS_PER_HEMISPHERE]),
				.mem_endpoint_ready_i(relay_mem_ready[
					chain_gen*lpu_pkg::MEM_BANKS_PER_HEMISPHERE+:
					lpu_pkg::MEM_BANKS_PER_HEMISPHERE]),
				.mem_endpoint_control_o(relay_mem_control[
					chain_gen*PROGRAM_RELAY_COUNT*PROGRAM_LOAD_CONTROL_WIDTH+:
					PROGRAM_RELAY_COUNT*PROGRAM_LOAD_CONTROL_WIDTH]),
				.mem_endpoint_data_o(relay_mem_data[
					chain_gen*PROGRAM_RELAY_COUNT*128+:PROGRAM_RELAY_COUNT*128]),
				.mem_endpoint_strb_o(relay_mem_strb[
					chain_gen*PROGRAM_RELAY_COUNT*4+:PROGRAM_RELAY_COUNT*4]),
				.mem_endpoint_scope_o(relay_mem_scope[
					chain_gen*PROGRAM_RELAY_COUNT*2+:PROGRAM_RELAY_COUNT*2]),
				.mem_endpoint_destination_o(relay_mem_destination[
					chain_gen*PROGRAM_RELAY_COUNT*PROGRAM_DESTINATION_WIDTH+:
					PROGRAM_RELAY_COUNT*PROGRAM_DESTINATION_WIDTH]),
				.mem_endpoint_imem_address_o(relay_mem_imem_address[
					chain_gen*PROGRAM_RELAY_COUNT*17+:PROGRAM_RELAY_COUNT*17]),
				.mem_endpoint_last_o(relay_mem_last[
					chain_gen*PROGRAM_RELAY_COUNT+:PROGRAM_RELAY_COUNT]),
				.outer_endpoint_valid_o(relay_outer_valid[chain_gen]),
				.outer_endpoint_ready_i(relay_outer_ready[chain_gen]),
				.outer_endpoint_control_o(relay_outer_control[
					chain_gen*PROGRAM_LOAD_CONTROL_WIDTH+:PROGRAM_LOAD_CONTROL_WIDTH]),
				.outer_endpoint_data_o(relay_outer_data[chain_gen*128+:128]),
				.outer_endpoint_strb_o(relay_outer_strb[chain_gen*4+:4]),
				.outer_endpoint_scope_o(relay_outer_scope[chain_gen*2+:2]),
				.outer_endpoint_destination_o(relay_outer_destination[
					chain_gen*PROGRAM_DESTINATION_WIDTH+:PROGRAM_DESTINATION_WIDTH]),
				.outer_endpoint_imem_address_o(relay_outer_address[chain_gen*17+:17]),
				.outer_endpoint_last_o(relay_outer_last[chain_gen]),
				.relay_level_o(),
				.idle_o(relay_chain_idle[chain_gen]),
				.fault_o(relay_chain_fault[chain_gen]),
				.fault_code_o(relay_chain_fault_code[chain_gen*6+:6])
			);
		end
	endgenerate

	// Decode the destination class once. Bank ownership is checked again at the
	// Relay and MEM Subsystem boundaries.
	always_comb begin
		endpoint_route_legal_w = '0;
		for(integer hemisphere = 0; hemisphere < 2; hemisphere = hemisphere + 1)begin
			case(destination_target_kind_w[
				hemisphere*PROGRAM_TARGET_KIND_WIDTH+:PROGRAM_TARGET_KIND_WIDTH])
				PROGRAM_TARGET_MEM: endpoint_route_legal_w[hemisphere] =
					destination_hemisphere_match_w[hemisphere] &&
					(destination_target_index_w[
					 hemisphere*PROGRAM_TARGET_INDEX_WIDTH+:PROGRAM_TARGET_INDEX_WIDTH] <
					 lpu_pkg::MEM_BANKS_PER_HEMISPHERE);
				PROGRAM_TARGET_MXM_LOAD,
				PROGRAM_TARGET_MXM_DEQUANT,
				PROGRAM_TARGET_MXM_COMPUTE,
				PROGRAM_TARGET_MXM_PARAM_LOAD,
				PROGRAM_TARGET_MXM_BACKEND: endpoint_route_legal_w[hemisphere] =
					destination_hemisphere_match_w[hemisphere] &&
					(destination_target_index_w[
					 hemisphere*PROGRAM_TARGET_INDEX_WIDTH+:PROGRAM_TARGET_INDEX_WIDTH] < 2);
				PROGRAM_TARGET_SXM_TRANSPOSE,
				PROGRAM_TARGET_SXM_PERMUTE: endpoint_route_legal_w[hemisphere] =
					destination_hemisphere_match_w[hemisphere] &&
					(destination_target_index_w[
					 hemisphere*PROGRAM_TARGET_INDEX_WIDTH+:PROGRAM_TARGET_INDEX_WIDTH] == 0);
				PROGRAM_TARGET_VXM: endpoint_route_legal_w[hemisphere] =
					(hemisphere == 0) && destination_hemisphere_match_w[hemisphere] &&
					(destination_target_index_w[
					 hemisphere*PROGRAM_TARGET_INDEX_WIDTH+:PROGRAM_TARGET_INDEX_WIDTH] <= 8);
				default: endpoint_route_legal_w[hemisphere] = 1'b0;
			endcase
		end
	end

	// The direct VXM bypass and the two Relay-chain inputs have independent
	// backpressure. Invalid destinations are consumed and converted into faults.
	generate
		for(genvar route_gen = 0; route_gen < 2; route_gen = route_gen + 1)begin : gen_endpoint_route
			assign endpoint_vxm_route_w[route_gen] = endpoint_route_legal_w[route_gen] &&
				(destination_target_kind_w[route_gen*PROGRAM_TARGET_KIND_WIDTH+:
				 PROGRAM_TARGET_KIND_WIDTH] == PROGRAM_TARGET_VXM);
			assign endpoint_chain_route_w[route_gen] = endpoint_route_legal_w[route_gen] &&
				!endpoint_vxm_route_w[route_gen];
			assign relay_chain_input_valid[route_gen] =
				endpoint_load_valid[route_gen] && endpoint_chain_route_w[route_gen];
			assign endpoint_load_ready[route_gen] = !endpoint_route_legal_w[route_gen] ?
				1'b1 : (endpoint_vxm_route_w[route_gen] ?
				vxm_program_ready : relay_chain_input_ready[route_gen]);
			assign illegal_write_error_w[route_gen] = endpoint_load_valid[route_gen] &&
				endpoint_load_ready[route_gen] && !endpoint_route_legal_w[route_gen] &&
				(endpoint_load_control[route_gen*PROGRAM_LOAD_CONTROL_WIDTH+:
				 PROGRAM_LOAD_CONTROL_WIDTH] == PROGRAM_LOAD_WRITE);
			assign route_error_fire_w[route_gen] = endpoint_load_valid[route_gen] &&
				endpoint_load_ready[route_gen] &&
				((!endpoint_route_legal_w[route_gen] &&
				  (endpoint_load_control[route_gen*PROGRAM_LOAD_CONTROL_WIDTH+:
				   PROGRAM_LOAD_CONTROL_WIDTH] != PROGRAM_LOAD_WRITE)) ||
				 ((endpoint_load_control[route_gen*PROGRAM_LOAD_CONTROL_WIDTH+:
				   PROGRAM_LOAD_CONTROL_WIDTH] == PROGRAM_LOAD_PRIME) &&
				  ((endpoint_load_data[route_gen*128+:128] != '0) ||
				   (endpoint_load_strb[route_gen*4+:4] != '0))));
		end
	endgenerate

	assign vxm_program_valid = endpoint_load_valid[0] && endpoint_vxm_route_w[0];
	assign vxm_program_control = endpoint_load_control[0+:PROGRAM_LOAD_CONTROL_WIDTH];
	assign vxm_program_destination = endpoint_load_destination[0+:PROGRAM_DESTINATION_WIDTH];
	assign vxm_program_address = endpoint_load_imem_address[0+:17];
	assign vxm_program_data = endpoint_load_data[0+:128];
	assign vxm_program_strb = endpoint_load_strb[0+:4];
	assign vxm_program_last = endpoint_load_last[0];
	assign vxm_write_fire_w = vxm_program_valid && vxm_program_ready &&
		(vxm_program_control == PROGRAM_LOAD_WRITE);
	assign vxm_write_error_w = vxm_write_fire_w && vxm_program_error;

	// Every Relay owns one Program port. Ready is replicated only inside that
	// Relay's disjoint Bank range, whose local valid vector is one-hot.
	generate
		for(genvar mem_hemi_gen = 0; mem_hemi_gen < 2; mem_hemi_gen = mem_hemi_gen + 1)begin : gen_mem_hemisphere_ports
			for(genvar relay_gen = 0; relay_gen < PROGRAM_RELAY_COUNT; relay_gen = relay_gen + 1)begin : gen_mem_relay_port
				localparam integer PORT_INDEX = mem_hemi_gen * PROGRAM_RELAY_COUNT + relay_gen;
				localparam integer LOCAL_BANK_BASE = relay_gen * PROGRAM_RELAY_BANKS_PER_STAGE;
				localparam integer LOCAL_BANK_COUNT =
					((lpu_pkg::MEM_BANKS_PER_HEMISPHERE - LOCAL_BANK_BASE) >
					 PROGRAM_RELAY_BANKS_PER_STAGE) ? PROGRAM_RELAY_BANKS_PER_STAGE :
					(lpu_pkg::MEM_BANKS_PER_HEMISPHERE - LOCAL_BANK_BASE);

				assign mem_program_valid[PORT_INDEX] = |relay_mem_valid[
					mem_hemi_gen*lpu_pkg::MEM_BANKS_PER_HEMISPHERE+LOCAL_BANK_BASE+:
					LOCAL_BANK_COUNT];
				assign relay_mem_ready[
					mem_hemi_gen*lpu_pkg::MEM_BANKS_PER_HEMISPHERE+LOCAL_BANK_BASE+:
					LOCAL_BANK_COUNT] = {LOCAL_BANK_COUNT{mem_program_ready[PORT_INDEX]}};
				assign mem_program_control[PORT_INDEX*PROGRAM_LOAD_CONTROL_WIDTH+:
					PROGRAM_LOAD_CONTROL_WIDTH] = relay_mem_control[
					PORT_INDEX*PROGRAM_LOAD_CONTROL_WIDTH+:PROGRAM_LOAD_CONTROL_WIDTH];
				assign mem_program_destination[PORT_INDEX*PROGRAM_DESTINATION_WIDTH+:
					PROGRAM_DESTINATION_WIDTH] = relay_mem_destination[
					PORT_INDEX*PROGRAM_DESTINATION_WIDTH+:PROGRAM_DESTINATION_WIDTH];
				assign mem_program_imem_address[PORT_INDEX*17+:17] =
					relay_mem_imem_address[PORT_INDEX*17+:17];
				assign mem_program_data[PORT_INDEX*128+:128] = relay_mem_data[PORT_INDEX*128+:128];
				assign mem_program_strb[PORT_INDEX*4+:4] = relay_mem_strb[PORT_INDEX*4+:4];
				assign mem_program_last[PORT_INDEX] = relay_mem_last[PORT_INDEX];
				assign mem_write_fire_w[PORT_INDEX] = mem_program_valid[PORT_INDEX] &&
					mem_program_ready[PORT_INDEX] &&
					(mem_program_control[PORT_INDEX*PROGRAM_LOAD_CONTROL_WIDTH+:
					 PROGRAM_LOAD_CONTROL_WIDTH] == PROGRAM_LOAD_WRITE);
				assign mem_write_error_w[PORT_INDEX] = mem_write_fire_w[PORT_INDEX] &&
					mem_program_error[PORT_INDEX];
			end
		end
	endgenerate

	// The terminal Outer port remains separate from all MEM local ports. Only
	// the addressed MXM or SXM endpoint controls its Ready and Error.
	generate
		for(genvar outer_gen = 0; outer_gen < 2; outer_gen = outer_gen + 1)begin : gen_outer_route
			assign outer_target_kind_w[outer_gen*PROGRAM_TARGET_KIND_WIDTH+:
				PROGRAM_TARGET_KIND_WIDTH] = relay_outer_destination[
				outer_gen*PROGRAM_DESTINATION_WIDTH+PROGRAM_DESTINATION_KIND_LSB+:
				PROGRAM_TARGET_KIND_WIDTH];
			assign outer_target_index_w[outer_gen*PROGRAM_TARGET_INDEX_WIDTH+:
				PROGRAM_TARGET_INDEX_WIDTH] = relay_outer_destination[
				outer_gen*PROGRAM_DESTINATION_WIDTH+PROGRAM_DESTINATION_INDEX_LSB+:
				PROGRAM_TARGET_INDEX_WIDTH];
			assign outer_mxm_route_w[outer_gen] =
				((outer_target_kind_w[outer_gen*PROGRAM_TARGET_KIND_WIDTH+:
				  PROGRAM_TARGET_KIND_WIDTH] == PROGRAM_TARGET_MXM_LOAD) ||
				 (outer_target_kind_w[outer_gen*PROGRAM_TARGET_KIND_WIDTH+:
				  PROGRAM_TARGET_KIND_WIDTH] == PROGRAM_TARGET_MXM_DEQUANT) ||
				 (outer_target_kind_w[outer_gen*PROGRAM_TARGET_KIND_WIDTH+:
				  PROGRAM_TARGET_KIND_WIDTH] == PROGRAM_TARGET_MXM_COMPUTE) ||
				 (outer_target_kind_w[outer_gen*PROGRAM_TARGET_KIND_WIDTH+:
				  PROGRAM_TARGET_KIND_WIDTH] == PROGRAM_TARGET_MXM_PARAM_LOAD) ||
				 (outer_target_kind_w[outer_gen*PROGRAM_TARGET_KIND_WIDTH+:
				  PROGRAM_TARGET_KIND_WIDTH] == PROGRAM_TARGET_MXM_BACKEND)) &&
				(outer_target_index_w[outer_gen*PROGRAM_TARGET_INDEX_WIDTH+:
				 PROGRAM_TARGET_INDEX_WIDTH] < 2);
			assign outer_sxm_route_w[outer_gen] =
				((outer_target_kind_w[outer_gen*PROGRAM_TARGET_KIND_WIDTH+:
				  PROGRAM_TARGET_KIND_WIDTH] == PROGRAM_TARGET_SXM_TRANSPOSE) ||
				 (outer_target_kind_w[outer_gen*PROGRAM_TARGET_KIND_WIDTH+:
				  PROGRAM_TARGET_KIND_WIDTH] == PROGRAM_TARGET_SXM_PERMUTE)) &&
				(outer_target_index_w[outer_gen*PROGRAM_TARGET_INDEX_WIDTH+:
				 PROGRAM_TARGET_INDEX_WIDTH] == 0);
			assign mxm_program_valid[outer_gen*2] = relay_outer_valid[outer_gen] &&
				outer_mxm_route_w[outer_gen] &&
				(outer_target_index_w[outer_gen*PROGRAM_TARGET_INDEX_WIDTH+:
				 PROGRAM_TARGET_INDEX_WIDTH] == 0);
			assign mxm_program_valid[outer_gen*2+1] = relay_outer_valid[outer_gen] &&
				outer_mxm_route_w[outer_gen] &&
				(outer_target_index_w[outer_gen*PROGRAM_TARGET_INDEX_WIDTH+:
				 PROGRAM_TARGET_INDEX_WIDTH] == 1);
			assign sxm_program_valid[outer_gen] = relay_outer_valid[outer_gen] &&
				outer_sxm_route_w[outer_gen];
			assign relay_outer_ready[outer_gen] = outer_mxm_route_w[outer_gen] ?
				((outer_target_index_w[outer_gen*PROGRAM_TARGET_INDEX_WIDTH+:
				  PROGRAM_TARGET_INDEX_WIDTH] == 0) ? mxm_program_ready[outer_gen*2] :
				 mxm_program_ready[outer_gen*2+1]) :
				(outer_sxm_route_w[outer_gen] ? sxm_program_ready[outer_gen] : 1'b0);
			assign outer_program_control[outer_gen*PROGRAM_LOAD_CONTROL_WIDTH+:
				PROGRAM_LOAD_CONTROL_WIDTH] = relay_outer_control[
				outer_gen*PROGRAM_LOAD_CONTROL_WIDTH+:PROGRAM_LOAD_CONTROL_WIDTH];
			assign outer_program_destination[outer_gen*PROGRAM_DESTINATION_WIDTH+:
				PROGRAM_DESTINATION_WIDTH] = relay_outer_destination[
				outer_gen*PROGRAM_DESTINATION_WIDTH+:PROGRAM_DESTINATION_WIDTH];
			assign outer_program_address[outer_gen*17+:17] = relay_outer_address[outer_gen*17+:17];
			assign outer_program_data[outer_gen*128+:128] = relay_outer_data[outer_gen*128+:128];
			assign outer_program_strb[outer_gen*4+:4] = relay_outer_strb[outer_gen*4+:4];
			assign outer_program_last[outer_gen] = relay_outer_last[outer_gen];
			assign outer_endpoint_fire_w[outer_gen] = relay_outer_valid[outer_gen] &&
				relay_outer_ready[outer_gen];
			assign outer_write_fire_w[outer_gen] = outer_endpoint_fire_w[outer_gen] &&
				(relay_outer_control[outer_gen*PROGRAM_LOAD_CONTROL_WIDTH+:
				 PROGRAM_LOAD_CONTROL_WIDTH] == PROGRAM_LOAD_WRITE);
			assign outer_write_error_w[outer_gen] = outer_write_fire_w[outer_gen] &&
				(outer_mxm_route_w[outer_gen] ?
				 ((outer_target_index_w[outer_gen*PROGRAM_TARGET_INDEX_WIDTH+:
				   PROGRAM_TARGET_INDEX_WIDTH] == 0) ? mxm_program_error[outer_gen*2] :
				  mxm_program_error[outer_gen*2+1]) : sxm_program_error[outer_gen]);
		end
	endgenerate

	// Each accepted WRITE source receives its own one-cycle completion token, so
	// simultaneous Relay completions cannot collapse into one Hemisphere bit.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			commit_valid_q <= '0;
		end
		else if(program_reset_i)begin
			commit_valid_q <= '0;
		end
		else begin
			commit_valid_q <= {vxm_write_fire_w, outer_write_fire_w, mem_write_fire_w};
		end
	end

	// Route faults remain sticky until reset so an invalid destination cannot be acknowledged later.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			route_fault_q <= 1'b0;
		end
		else if(program_reset_i)begin
			route_fault_q <= 1'b0;
		end
		else if(!route_fault_q && ((|illegal_write_error_w) || (|route_error_fire_w) ||
			(|mem_write_error_w) || (|outer_write_error_w) || vxm_write_error_w ||
			(|relay_chain_fault)))begin
			route_fault_q <= 1'b1;
		end
	end

endmodule
