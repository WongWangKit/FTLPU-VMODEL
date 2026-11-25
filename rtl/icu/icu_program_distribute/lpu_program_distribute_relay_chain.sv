module lpu_program_distribute_relay_chain #(
	parameter integer BUFFER_DEPTH = 2,
	parameter integer HEMISPHERE_ID = lpu_program_load_pkg::PROGRAM_HEMISPHERE_EAST,
	parameter integer MEM_SLICES_PER_HEMISPHERE = 52,
	parameter integer MEM_SLICES_PER_GROUP = 4,
	parameter integer BANKS_PER_SLICE = 2,
	parameter integer MEM_GROUPS_PER_RELAY = 2,
	parameter integer MXM_INSTANCES_PER_HEMISPHERE = 2,
	parameter integer SXM_INSTANCES_PER_HEMISPHERE = 1,
	parameter integer MEM_GROUP_COUNT =
		(MEM_SLICES_PER_HEMISPHERE + MEM_SLICES_PER_GROUP - 1) / MEM_SLICES_PER_GROUP,
	parameter integer MEM_BANKS_PER_GROUP = MEM_SLICES_PER_GROUP * BANKS_PER_SLICE,
	parameter integer RELAY_COUNT =
		(MEM_GROUP_COUNT + MEM_GROUPS_PER_RELAY - 1) / MEM_GROUPS_PER_RELAY,
	parameter integer MEM_BANK_COUNT = MEM_SLICES_PER_HEMISPHERE * BANKS_PER_SLICE
) (
	input logic clk_i,
	input logic rst_ni,

	input logic distributor_record_valid_i,
	output logic distributor_record_ready_o,
	input logic [lpu_program_load_pkg::PROGRAM_LOAD_CONTROL_WIDTH-1:0] distributor_record_control_i,
	input logic [127:0] distributor_record_data_i,
	input logic [3:0] distributor_record_strb_i,
	input logic [1:0] distributor_record_scope_i,
	input logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		distributor_record_destination_i,
	input logic [16:0] distributor_record_imem_address_i,
	input logic distributor_record_last_i,

	// Every Relay owns one independent local MEM region. The one-hot valid and
	// ready vectors select a Bank, while each Relay exports one shared Record.
	output logic [MEM_BANK_COUNT-1:0] mem_endpoint_valid_o,
	input logic [MEM_BANK_COUNT-1:0] mem_endpoint_ready_i,
	output logic [RELAY_COUNT*lpu_program_load_pkg::PROGRAM_LOAD_CONTROL_WIDTH-1:0]
		mem_endpoint_control_o,
	output logic [RELAY_COUNT*128-1:0] mem_endpoint_data_o,
	output logic [RELAY_COUNT*4-1:0] mem_endpoint_strb_o,
	output logic [RELAY_COUNT*2-1:0] mem_endpoint_scope_o,
	output logic [RELAY_COUNT*lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		mem_endpoint_destination_o,
	output logic [RELAY_COUNT*17-1:0] mem_endpoint_imem_address_o,
	output logic [RELAY_COUNT-1:0] mem_endpoint_last_o,

	// R6 terminates MXM/SXM traffic on this unified boundary. The destination
	// remains intact so the owning FU Subsystem performs its local decode.
	output logic outer_endpoint_valid_o,
	input logic outer_endpoint_ready_i,
	output logic [lpu_program_load_pkg::PROGRAM_LOAD_CONTROL_WIDTH-1:0]
		outer_endpoint_control_o,
	output logic [127:0] outer_endpoint_data_o,
	output logic [3:0] outer_endpoint_strb_o,
	output logic [1:0] outer_endpoint_scope_o,
	output logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		outer_endpoint_destination_o,
	output logic [16:0] outer_endpoint_imem_address_o,
	output logic outer_endpoint_last_o,

	output logic [RELAY_COUNT*$clog2(BUFFER_DEPTH+1)-1:0] relay_level_o,
	output logic idle_o,
	output logic fault_o,
	output logic [5:0] fault_code_o
);
	import lpu_program_load_pkg::*;

	localparam integer LEVEL_WIDTH = $clog2(BUFFER_DEPTH + 1);

	logic [RELAY_COUNT-1:0] relay_input_valid;
	logic [RELAY_COUNT-1:0] relay_input_ready;
	logic [RELAY_COUNT*PROGRAM_LOAD_CONTROL_WIDTH-1:0] relay_input_control;
	logic [RELAY_COUNT*128-1:0] relay_input_data;
	logic [RELAY_COUNT*4-1:0] relay_input_strb;
	logic [RELAY_COUNT*2-1:0] relay_input_scope;
	logic [RELAY_COUNT*PROGRAM_DESTINATION_WIDTH-1:0] relay_input_destination;
	logic [RELAY_COUNT*17-1:0] relay_input_imem_address;
	logic [RELAY_COUNT-1:0] relay_input_last;

	logic [RELAY_COUNT-1:0] relay_forward_valid;
	logic [RELAY_COUNT-1:0] relay_forward_ready;
	logic [RELAY_COUNT*PROGRAM_LOAD_CONTROL_WIDTH-1:0] relay_forward_control;
	logic [RELAY_COUNT*128-1:0] relay_forward_data;
	logic [RELAY_COUNT*4-1:0] relay_forward_strb;
	logic [RELAY_COUNT*2-1:0] relay_forward_scope;
	logic [RELAY_COUNT*PROGRAM_DESTINATION_WIDTH-1:0] relay_forward_destination;
	logic [RELAY_COUNT*17-1:0] relay_forward_imem_address;
	logic [RELAY_COUNT-1:0] relay_forward_last;
	logic [RELAY_COUNT-1:0] relay_idle;
	logic [RELAY_COUNT-1:0] relay_fault;
	logic [RELAY_COUNT*6-1:0] relay_fault_code;

	logic [PROGRAM_TARGET_KIND_WIDTH-1:0] tail_target_kind_w;
	logic [7:0] tail_target_index_w;
	logic tail_target_legal_w;
	logic tail_target_illegal_w;
	logic tail_fault_q;

	initial begin
		if(RELAY_COUNT < 1 || MEM_BANK_COUNT < 1)begin
			$error("Relay Chain organization must contain at least one Relay and one MEM Bank");
		end
		if(HEMISPHERE_ID != PROGRAM_HEMISPHERE_EAST &&
			HEMISPHERE_ID != PROGRAM_HEMISPHERE_WEST)begin
			$error("Relay Chain Hemisphere must be East or West");
		end
		if(MXM_INSTANCES_PER_HEMISPHERE < 1 || SXM_INSTANCES_PER_HEMISPHERE < 1)begin
			$error("Relay Chain outer FU counts must be positive");
		end
	end

	assign relay_input_valid[0] = distributor_record_valid_i && !fault_o;
	assign distributor_record_ready_o = relay_input_ready[0] && !fault_o;
	assign relay_input_control[0+:PROGRAM_LOAD_CONTROL_WIDTH] = distributor_record_control_i;
	assign relay_input_data[0+:128] = distributor_record_data_i;
	assign relay_input_strb[0+:4] = distributor_record_strb_i;
	assign relay_input_scope[0+:2] = distributor_record_scope_i;
	assign relay_input_destination[0+:PROGRAM_DESTINATION_WIDTH] = distributor_record_destination_i;
	assign relay_input_imem_address[0+:17] = distributor_record_imem_address_i;
	assign relay_input_last[0] = distributor_record_last_i;

	// Build the ordered Relay chain and connect each stage to its disjoint
	// local MEM Bank range while forwarding non-local Records downstream.
	generate
		for(genvar relay_gen = 0; relay_gen < RELAY_COUNT; relay_gen = relay_gen + 1)begin : gen_relay
			localparam integer LOCAL_GROUP_COUNT =
				((MEM_GROUP_COUNT - relay_gen * MEM_GROUPS_PER_RELAY) > MEM_GROUPS_PER_RELAY) ?
				MEM_GROUPS_PER_RELAY : (MEM_GROUP_COUNT - relay_gen * MEM_GROUPS_PER_RELAY);
			localparam integer LOCAL_BANK_COUNT = LOCAL_GROUP_COUNT * MEM_BANKS_PER_GROUP;
			localparam integer LOCAL_BANK_BASE =
				relay_gen * MEM_GROUPS_PER_RELAY * MEM_BANKS_PER_GROUP;

			logic [LOCAL_BANK_COUNT-1:0] local_valid;
			logic [LOCAL_BANK_COUNT-1:0] local_ready;

			assign local_ready = mem_endpoint_ready_i[LOCAL_BANK_BASE+:LOCAL_BANK_COUNT];
			assign mem_endpoint_valid_o[LOCAL_BANK_BASE+:LOCAL_BANK_COUNT] = local_valid;

			if(relay_gen > 0)begin : gen_relay_input
				assign relay_input_valid[relay_gen] = relay_forward_valid[relay_gen-1];
				assign relay_forward_ready[relay_gen-1] = relay_input_ready[relay_gen];
				assign relay_input_control[relay_gen*PROGRAM_LOAD_CONTROL_WIDTH+:
					PROGRAM_LOAD_CONTROL_WIDTH] = relay_forward_control[
					(relay_gen-1)*PROGRAM_LOAD_CONTROL_WIDTH+:PROGRAM_LOAD_CONTROL_WIDTH];
				assign relay_input_data[relay_gen*128+:128] =
					relay_forward_data[(relay_gen-1)*128+:128];
				assign relay_input_strb[relay_gen*4+:4] =
					relay_forward_strb[(relay_gen-1)*4+:4];
				assign relay_input_scope[relay_gen*2+:2] =
					relay_forward_scope[(relay_gen-1)*2+:2];
				assign relay_input_destination[relay_gen*PROGRAM_DESTINATION_WIDTH+:
					PROGRAM_DESTINATION_WIDTH] = relay_forward_destination[
					(relay_gen-1)*PROGRAM_DESTINATION_WIDTH+:PROGRAM_DESTINATION_WIDTH];
				assign relay_input_imem_address[relay_gen*17+:17] =
					relay_forward_imem_address[(relay_gen-1)*17+:17];
				assign relay_input_last[relay_gen] = relay_forward_last[relay_gen-1];
			end

		lpu_program_distribute_relay #(
				.BUFFER_DEPTH(BUFFER_DEPTH),
				.MEM_SLICES_PER_HEMISPHERE(MEM_SLICES_PER_HEMISPHERE),
				.MEM_SLICES_PER_GROUP(MEM_SLICES_PER_GROUP),
				.BANKS_PER_SLICE(BANKS_PER_SLICE),
				.MEM_GROUPS_PER_RELAY(MEM_GROUPS_PER_RELAY),
				.RELAY_INDEX(relay_gen),
				.RELAY_HEMISPHERE(HEMISPHERE_ID),
				.LAST_RELAY(1'b0)
			) u_relay (
				.clk_i,
				.rst_ni,
				.chain_record_valid_i(relay_input_valid[relay_gen]),
				.chain_record_ready_o(relay_input_ready[relay_gen]),
				.chain_record_control_i(relay_input_control[
					relay_gen*PROGRAM_LOAD_CONTROL_WIDTH+:PROGRAM_LOAD_CONTROL_WIDTH]),
				.chain_record_data_i(relay_input_data[relay_gen*128+:128]),
				.chain_record_strb_i(relay_input_strb[relay_gen*4+:4]),
				.chain_record_scope_i(relay_input_scope[relay_gen*2+:2]),
				.chain_record_destination_i(relay_input_destination[
					relay_gen*PROGRAM_DESTINATION_WIDTH+:PROGRAM_DESTINATION_WIDTH]),
				.chain_record_imem_address_i(relay_input_imem_address[relay_gen*17+:17]),
				.chain_record_last_i(relay_input_last[relay_gen]),
				.local_endpoint_valid_o(local_valid),
				.local_endpoint_ready_i(local_ready),
				.local_endpoint_control_o(mem_endpoint_control_o[
					relay_gen*PROGRAM_LOAD_CONTROL_WIDTH+:PROGRAM_LOAD_CONTROL_WIDTH]),
				.local_endpoint_data_o(mem_endpoint_data_o[relay_gen*128+:128]),
				.local_endpoint_strb_o(mem_endpoint_strb_o[relay_gen*4+:4]),
				.local_endpoint_scope_o(mem_endpoint_scope_o[relay_gen*2+:2]),
				.local_endpoint_destination_o(mem_endpoint_destination_o[
					relay_gen*PROGRAM_DESTINATION_WIDTH+:PROGRAM_DESTINATION_WIDTH]),
				.local_endpoint_imem_address_o(mem_endpoint_imem_address_o[relay_gen*17+:17]),
				.local_endpoint_last_o(mem_endpoint_last_o[relay_gen]),
				.next_relay_valid_o(relay_forward_valid[relay_gen]),
				.next_relay_ready_i(relay_forward_ready[relay_gen]),
				.next_relay_control_o(relay_forward_control[
					relay_gen*PROGRAM_LOAD_CONTROL_WIDTH+:PROGRAM_LOAD_CONTROL_WIDTH]),
				.next_relay_data_o(relay_forward_data[relay_gen*128+:128]),
				.next_relay_strb_o(relay_forward_strb[relay_gen*4+:4]),
				.next_relay_scope_o(relay_forward_scope[relay_gen*2+:2]),
				.next_relay_destination_o(relay_forward_destination[
					relay_gen*PROGRAM_DESTINATION_WIDTH+:PROGRAM_DESTINATION_WIDTH]),
				.next_relay_imem_address_o(relay_forward_imem_address[relay_gen*17+:17]),
				.next_relay_last_o(relay_forward_last[relay_gen]),
				.level_o(relay_level_o[relay_gen*LEVEL_WIDTH+:LEVEL_WIDTH]),
				.idle_o(relay_idle[relay_gen]),
				.fault_o(relay_fault[relay_gen]),
				.fault_code_o(relay_fault_code[relay_gen*6+:6])
			);
		end
	endgenerate

	assign tail_target_kind_w = relay_forward_destination[
		(RELAY_COUNT-1)*PROGRAM_DESTINATION_WIDTH+PROGRAM_DESTINATION_KIND_LSB+:
		PROGRAM_TARGET_KIND_WIDTH];
	assign tail_target_index_w = relay_forward_destination[
		(RELAY_COUNT-1)*PROGRAM_DESTINATION_WIDTH+PROGRAM_DESTINATION_INDEX_LSB+:
		PROGRAM_TARGET_INDEX_WIDTH];
	assign tail_target_legal_w =
		(((tail_target_kind_w == PROGRAM_TARGET_MXM_LOAD) ||
		  (tail_target_kind_w == PROGRAM_TARGET_MXM_DEQUANT) ||
		  (tail_target_kind_w == PROGRAM_TARGET_MXM_COMPUTE) ||
		  (tail_target_kind_w == PROGRAM_TARGET_MXM_PARAM_LOAD) ||
		  (tail_target_kind_w == PROGRAM_TARGET_MXM_BACKEND)) &&
		 (tail_target_index_w < MXM_INSTANCES_PER_HEMISPHERE)) ||
		(((tail_target_kind_w == PROGRAM_TARGET_SXM_TRANSPOSE) ||
		  (tail_target_kind_w == PROGRAM_TARGET_SXM_PERMUTE)) &&
		 (tail_target_index_w < SXM_INSTANCES_PER_HEMISPHERE));
	assign tail_target_illegal_w = relay_forward_valid[RELAY_COUNT-1] && !tail_target_legal_w;
	assign relay_forward_ready[RELAY_COUNT-1] = tail_target_legal_w ?
		outer_endpoint_ready_i : 1'b1;

	assign outer_endpoint_valid_o = relay_forward_valid[RELAY_COUNT-1] &&
		tail_target_legal_w && !tail_fault_q;
	assign outer_endpoint_control_o = relay_forward_control[
		(RELAY_COUNT-1)*PROGRAM_LOAD_CONTROL_WIDTH+:PROGRAM_LOAD_CONTROL_WIDTH];
	assign outer_endpoint_data_o = relay_forward_data[(RELAY_COUNT-1)*128+:128];
	assign outer_endpoint_strb_o = relay_forward_strb[(RELAY_COUNT-1)*4+:4];
	assign outer_endpoint_scope_o = relay_forward_scope[(RELAY_COUNT-1)*2+:2];
	assign outer_endpoint_destination_o = relay_forward_destination[
		(RELAY_COUNT-1)*PROGRAM_DESTINATION_WIDTH+:PROGRAM_DESTINATION_WIDTH];
	assign outer_endpoint_imem_address_o = relay_forward_imem_address[(RELAY_COUNT-1)*17+:17];
	assign outer_endpoint_last_o = relay_forward_last[RELAY_COUNT-1];

	assign idle_o = (&relay_idle) && !outer_endpoint_valid_o;
	assign fault_o = (|relay_fault) || tail_fault_q || tail_target_illegal_w;
	assign fault_code_o = fault_o ? PROGRAM_FAULT_ROUTE : PROGRAM_FAULT_NONE;

	// Invalid MXM/SXM indices are consumed at the terminal boundary and latched
	// as a fault; they are never acknowledged by a nonexistent FU Frontend.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			tail_fault_q <= 1'b0;
		end
		else if(tail_target_illegal_w)begin
			tail_fault_q <= 1'b1;
		end
	end
endmodule
