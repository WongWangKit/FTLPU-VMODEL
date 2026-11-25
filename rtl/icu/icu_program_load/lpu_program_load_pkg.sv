package lpu_program_load_pkg;
	parameter integer PROGRAM_DDR_ADDRESS_WIDTH = 64;
	parameter integer PROGRAM_BYTE_COUNT_WIDTH = 32;
	parameter integer PROGRAM_HEMISPHERE_WIDTH = 1;
	parameter integer PROGRAM_HEMISPHERE_SCOPE_WIDTH = 2;
	parameter integer PROGRAM_TARGET_KIND_WIDTH = 4;
	parameter integer PROGRAM_TARGET_INDEX_WIDTH = 8;
	parameter integer PROGRAM_DESTINATION_WIDTH = 13;
	parameter integer PROGRAM_FORMAT_WIDTH = 2;
	parameter integer PROGRAM_IMEM_ADDRESS_WIDTH = 17;
	parameter integer PROGRAM_WORD_COUNT_WIDTH = 16;
	parameter integer PROGRAM_DMA_ID_WIDTH = 8;
	parameter integer PROGRAM_WORD_STRB_WIDTH = 4;
	parameter integer PROGRAM_LOAD_CONTROL_WIDTH = 1;
	parameter integer PROGRAM_LOADER_OPCODE_WIDTH = 3;
	parameter integer PROGRAM_FAULT_CODE_WIDTH = 6;

	// Program Distribution maps two MEM Groups to one physical Relay stage.
	// The final Relay may own fewer Banks when the Hemisphere has a partial Group.
	parameter integer PROGRAM_RELAY_MEM_SLICES_PER_GROUP = 4;
	parameter integer PROGRAM_RELAY_MEM_GROUPS_PER_STAGE = 2;
	parameter integer PROGRAM_RELAY_MEM_GROUP_COUNT =
		(lpu_pkg::MEM_SLICES_PER_HEMISPHERE + PROGRAM_RELAY_MEM_SLICES_PER_GROUP - 1) /
		PROGRAM_RELAY_MEM_SLICES_PER_GROUP;
	parameter integer PROGRAM_RELAY_BANKS_PER_STAGE = PROGRAM_RELAY_MEM_SLICES_PER_GROUP *
		lpu_pkg::MEM_BANKS_PER_SLICE * PROGRAM_RELAY_MEM_GROUPS_PER_STAGE;
	parameter integer PROGRAM_RELAY_COUNT =
		(PROGRAM_RELAY_MEM_GROUP_COUNT + PROGRAM_RELAY_MEM_GROUPS_PER_STAGE - 1) /
		PROGRAM_RELAY_MEM_GROUPS_PER_STAGE;
	parameter integer PROGRAM_RELAY_PORT_COUNT = lpu_pkg::HEMISPHERES * PROGRAM_RELAY_COUNT;

	// Program Word transport is always 128 bits. Each strobe bit enables one 32-bit segment.
	typedef enum logic [PROGRAM_FORMAT_WIDTH-1:0] {
		PROGRAM_FORMAT_96 = 2'd0,
		PROGRAM_FORMAT_128 = 2'd1
	} lpu_program_format_e;

	// A Destination names exactly one physical target. Broadcast remains a separate loader scope.
	typedef enum logic [PROGRAM_HEMISPHERE_WIDTH-1:0] {
		PROGRAM_HEMISPHERE_EAST = 1'b0,
		PROGRAM_HEMISPHERE_WEST = 1'b1
	} lpu_program_hemisphere_e;

	typedef enum logic [PROGRAM_HEMISPHERE_SCOPE_WIDTH-1:0] {
		PROGRAM_SCOPE_EAST = 2'd0,
		PROGRAM_SCOPE_WEST = 2'd1,
		PROGRAM_SCOPE_BOTH = 2'd2
	} lpu_program_hemisphere_scope_e;

	typedef enum logic [PROGRAM_TARGET_KIND_WIDTH-1:0] {
		PROGRAM_TARGET_MEM = 4'd0,
		PROGRAM_TARGET_MXM_LOAD = 4'd1,
		PROGRAM_TARGET_MXM_DEQUANT = 4'd2,
		PROGRAM_TARGET_MXM_COMPUTE = 4'd3,
		PROGRAM_TARGET_VXM = 4'd4,
		PROGRAM_TARGET_SXM_TRANSPOSE = 4'd5,
		PROGRAM_TARGET_SXM_PERMUTE = 4'd6,
		PROGRAM_TARGET_MXM_PARAM_LOAD = 4'd7,
		PROGRAM_TARGET_MXM_BACKEND = 4'd8,
		PROGRAM_TARGET_RESERVED = 4'd15
	} lpu_program_target_kind_e;

	localparam integer PROGRAM_DESTINATION_HEMISPHERE_BIT = 12;
	localparam integer PROGRAM_DESTINATION_KIND_MSB = 11;
	localparam integer PROGRAM_DESTINATION_KIND_LSB = 8;
	localparam integer PROGRAM_DESTINATION_INDEX_MSB = 7;
	localparam integer PROGRAM_DESTINATION_INDEX_LSB = 0;

	function automatic logic [PROGRAM_DESTINATION_WIDTH-1:0] program_destination_pack(
		input logic hemisphere,
		input logic [PROGRAM_TARGET_KIND_WIDTH-1:0] target_kind,
		input logic [PROGRAM_TARGET_INDEX_WIDTH-1:0] target_index
	);
		program_destination_pack = {hemisphere, target_kind, target_index};
	endfunction

	// Program Load carries only an iMEM write or a queue-local prime command.
	typedef enum logic [PROGRAM_LOAD_CONTROL_WIDTH-1:0] {
		PROGRAM_LOAD_WRITE = 1'b0,
		PROGRAM_LOAD_PRIME = 1'b1
	} lpu_program_load_control_e;

	typedef enum logic [PROGRAM_LOADER_OPCODE_WIDTH-1:0] {
		PROGRAM_LOADER_LOAD_IMEM = 3'd0,
		PROGRAM_LOADER_WAIT_DMA = 3'd1,
		PROGRAM_LOADER_COMMIT_QUEUE = 3'd2,
		PROGRAM_LOADER_NEXT = 3'd3,
		PROGRAM_LOADER_JUMP = 3'd4,
		PROGRAM_LOADER_END = 3'd5
	} lpu_program_command_opcode_e;

	typedef enum logic [PROGRAM_FAULT_CODE_WIDTH-1:0] {
		PROGRAM_FAULT_NONE = 6'd0,
		PROGRAM_FAULT_DESCRIPTOR = 6'd1,
		PROGRAM_FAULT_DMA_ID = 6'd2,
		PROGRAM_FAULT_DMA_RESPONSE = 6'd3,
		PROGRAM_FAULT_BURST_LENGTH = 6'd4,
		PROGRAM_FAULT_KEEP = 6'd5,
		PROGRAM_FAULT_IMAGE_LENGTH = 6'd6,
		PROGRAM_FAULT_IMAGE_ORDER = 6'd7,
		PROGRAM_FAULT_ROUTE = 6'd8,
		PROGRAM_FAULT_COMMIT = 6'd9,
		PROGRAM_FAULT_COMMAND = 6'd10,
		PROGRAM_FAULT_ABORT_STALE = 6'd11
	} lpu_program_fault_e;
endpackage
