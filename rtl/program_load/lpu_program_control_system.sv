module lpu_program_control_system #(
	parameter integer COMMAND_DEPTH = 32,
	parameter integer DMA_DATA_WIDTH = 256,
	parameter integer DMA_RX_FIFO_DEPTH = 16,
	parameter integer DMA_OUTSTANDING_DEPTH = 16,
	parameter integer MEM_IMEM_DEPTH = 131072,
	parameter integer MXM_IMEM_DEPTH = 65536,
	parameter integer VXM_IMEM_DEPTH = 1536,
	parameter integer ACTIVE_CONTEXTS = 4,
    parameter integer MXMS_PER_HEMISPHERE = 2,
	parameter integer COMMAND_ADDRESS_WIDTH = COMMAND_DEPTH <= 1 ? 1 : $clog2(COMMAND_DEPTH)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic program_reset_i,

	// A LOAD_IMEM command carries the ProgramImage descriptor. Other opcodes sequence the request.
	input logic command_write_valid_i,
	output logic command_write_ready_o,
	input logic [COMMAND_ADDRESS_WIDTH-1:0] command_write_address_i,
	input logic [2:0] command_write_opcode_i,
	input logic [63:0] command_write_source_address_i,
	input logic [31:0] command_write_byte_count_i,
	input logic [3:0] command_write_target_kind_i,
	input logic [7:0] command_write_global_queue_id_i,
	input logic [1:0] command_write_format_i,
	input logic [1:0] command_write_encoding_mode_i,
	input logic [16:0] command_write_imem_base_address_i,
	input logic command_write_image_first_i,
	input logic command_write_image_last_i,
	input logic [15:0] command_write_expected_word_count_i,
	input logic [COMMAND_ADDRESS_WIDTH-1:0] command_write_jump_address_i,

	input logic load_start_valid_i,
	output logic load_start_ready_o,
	input logic [COMMAND_ADDRESS_WIDTH:0] load_start_command_count_i,

	// External DDR/C2C fabric boundary. The RTL owns request ordering and response reassembly.
	output logic dma_cmd_valid_o,
	input logic dma_cmd_ready_i,
	output logic [63:0] dma_cmd_address_o,
	output logic [31:0] dma_cmd_length_o,
	output logic [7:0] dma_cmd_id_o,
	input logic dma_rsp_valid_i,
	output logic dma_rsp_ready_o,
	input logic [DMA_DATA_WIDTH-1:0] dma_rsp_data_i,
	input logic [DMA_DATA_WIDTH/8-1:0] dma_rsp_keep_i,
	input logic dma_rsp_last_i,
	input logic [7:0] dma_rsp_id_i,
	input logic dma_rsp_error_i,

	input logic program_start_request_i,
	input logic dependencies_ready_i,
	output logic program_start_ack_o,
	output logic program_load_complete_o,
	output logic program_ready_o,
	output logic program_running_o,
	output logic program_done_o,
	output logic program_fault_o,
	output logic [5:0] program_fault_code_o,
	output logic [31:0] schedule_cycle_o,

	// ICU owns DMA/reassembly/routing; FU subsystems own every local iMEM and execution frontend.
	output logic [1:0] endpoint_load_valid_o,
	input logic [1:0] endpoint_load_ready_i,
	output logic [5:0] endpoint_load_control_o,
	output logic [255:0] endpoint_load_data_o,
	output logic [7:0] endpoint_load_strb_o,
	output logic [7:0] endpoint_load_target_kind_o,
	output logic [15:0] endpoint_load_queue_id_o,
	output logic [33:0] endpoint_load_imem_address_o,
	output logic [1:0] endpoint_load_last_o,
	input logic [1:0] endpoint_commit_valid_i,
	output logic [1:0] endpoint_commit_ready_o,
	input logic [1:0] endpoint_commit_error_i,
	output logic endpoint_program_start_o,
	input logic endpoint_program_start_ready_i,
	input logic endpoint_started_i,
	input logic endpoint_frontends_ready_i,
	input logic endpoint_frontends_idle_i,
	input logic endpoint_execution_drained_i,
	input logic endpoint_fault_i,
	input logic [5:0] endpoint_fault_code_i,
	input logic [31:0] endpoint_schedule_cycle_i
);
	import lpu_program_load_pkg::*;

	// The integrated RTL frontend accepts Macro-packed Program Images only.
	localparam logic [1:0] PROGRAM_ENCODING_MACRO = 2'd0;
	localparam logic [5:0] FRONTEND_FAULT_OFFSET = 6'd16;
	// Descriptor admission checks each destination independently. The common
	// reassembler must not re-apply the MEM depth to an admitted MXM image.
	localparam integer MACRO_DEPTH = MEM_IMEM_DEPTH > MXM_IMEM_DEPTH ? MEM_IMEM_DEPTH : MXM_IMEM_DEPTH;
	localparam integer NATIVE_WORDS = 2*NATIVE_EVENT_DEPTH;
	localparam integer OLD_DEPTH = MACRO_DEPTH > NATIVE_WORDS ? MACRO_DEPTH : NATIVE_WORDS;
	localparam integer TRANSPORT_IMEM_DEPTH = OLD_DEPTH > VXM_IMEM_DEPTH ? OLD_DEPTH : VXM_IMEM_DEPTH;

	logic [1:0] command_hemisphere_w;
	logic [7:0] command_local_queue_w;
	logic command_target_valid_w;
	logic command_write_fire;
	logic descriptor_invalid_w;
	logic descriptor_duplicate_w;
	logic descriptor_fault_q;

	logic [lpu_pkg::MEM_BANK_COUNT-1:0] mem_target_seen_q;
	logic [3:0] mxm_load_target_seen_q;
	logic [3:0] mxm_dequant_target_seen_q;
	logic [3:0] mxm_compute_target_seen_q;
	// Remote macro kind 7/8 shares pins with the v1 event namespace.
    wire raw_vxm=command_write_target_kind_i==PROGRAM_TARGET_VXM && command_write_encoding_mode_i==0;
    logic [7:0] raw_seen;
    wire [3:0] route_kind=raw_vxm?PROGRAM_VXM_RAW96:
                          (command_write_encoding_mode_i==PROGRAM_ENCODING_MACRO && command_write_target_kind_i==7)?PROGRAM_MACRO_PARAM:
                          (command_write_encoding_mode_i==PROGRAM_ENCODING_MACRO && command_write_target_kind_i==8)?PROGRAM_MACRO_BACKEND:
                          command_write_target_kind_i;
    wire mxm_macro=route_kind inside {PROGRAM_TARGET_MXM_LOAD,PROGRAM_TARGET_MXM_COMPUTE,PROGRAM_TARGET_MXM_DEQUANT,PROGRAM_MACRO_PARAM,PROGRAM_MACRO_BACKEND};
    logic [63:0] native_target_seen_q;
	wire [5:0] native_target_index={route_kind, command_write_global_queue_id_i[1:0]};

	logic west_load_valid;
	logic west_load_ready;
	logic [2:0] west_load_control;
	logic [127:0] west_load_data;
	logic [3:0] west_load_strb;
	logic [3:0] west_load_target_kind;
	logic [7:0] west_load_queue_id;
	logic [16:0] west_load_imem_address;
	logic west_load_last;
	logic east_load_valid;
	logic east_load_ready;
	logic [2:0] east_load_control;
	logic [127:0] east_load_data;
	logic [3:0] east_load_strb;
	logic [3:0] east_load_target_kind;
	logic [7:0] east_load_queue_id;
	logic [16:0] east_load_imem_address;
	logic east_load_last;

	logic [1:0] cluster_load_valid;
	logic [1:0] cluster_load_ready;
	logic [5:0] cluster_load_control;
	logic [255:0] cluster_load_data;
	logic [7:0] cluster_load_strb;
	logic [7:0] cluster_load_target_kind;
	logic [15:0] cluster_load_queue_id;
	logic [33:0] cluster_load_imem_address;
	logic [1:0] cluster_load_last;
	logic [1:0] cluster_commit_valid;
	logic [1:0] cluster_commit_ready;
	logic [1:0] cluster_commit_error;

	logic instruction_load_done;
	logic loader_program_start;
	logic loader_command_write_ready;
	logic loader_start_ready;
	logic loader_busy;
	logic loader_error;
	logic [5:0] loader_error_code;
	logic cluster_start_ready;
	logic cluster_started;
	logic cluster_frontends_ready;
	logic cluster_frontends_idle;
	logic cluster_fault;
	logic [5:0] cluster_fault_code;
	logic start_pending_q;
	logic load_request_active_q;
	logic program_done_q;
	logic west_commit_ready;
	logic east_commit_ready;

	initial begin
		if((MEM_IMEM_DEPTH < 1) || (MEM_IMEM_DEPTH > 131072))begin
			$error("MEM subsystem iMEM exceeds the 17-bit Program Load address contract");
		end
		if((MXM_IMEM_DEPTH < 1) || (MXM_IMEM_DEPTH > 65536))begin
			$error("MXM subsystem iMEM exceeds the CMODEL capacity");
		end
	end

	// Translate CMODEL global Queue indices into the physical endpoint namespace.
	// Hemisphere index 0 is East and index 1 is West throughout the load and execution paths.
	always_comb begin
		command_hemisphere_w = PROGRAM_HEMISPHERE_EAST;
		command_local_queue_w = command_write_global_queue_id_i;
		command_target_valid_w = 1'b0;
		case(route_kind)
			PROGRAM_TARGET_MEM: begin
				if(command_write_global_queue_id_i < lpu_pkg::MEM_BANK_COUNT) begin
					command_target_valid_w = 1'b1;
					if(command_write_global_queue_id_i < lpu_pkg::MEM_BANKS_PER_HEMISPHERE) begin
						command_hemisphere_w = PROGRAM_HEMISPHERE_EAST;
						command_local_queue_w = command_write_global_queue_id_i;
					end
					else begin
						command_hemisphere_w = PROGRAM_HEMISPHERE_WEST;
						command_local_queue_w = command_write_global_queue_id_i -
							lpu_pkg::MEM_BANKS_PER_HEMISPHERE;
					end
				end
			end
			PROGRAM_TARGET_SXM_TRANSPOSE, PROGRAM_TARGET_SXM_PERMUTE: begin
				command_target_valid_w = command_write_global_queue_id_i < 2;
				command_hemisphere_w = command_write_global_queue_id_i[0] ? PROGRAM_HEMISPHERE_WEST : PROGRAM_HEMISPHERE_EAST;
				command_local_queue_w = 0;
			end
			PROGRAM_TARGET_VXM: command_target_valid_w = command_write_global_queue_id_i == 0;
			PROGRAM_VXM_RAW96: command_target_valid_w = command_write_global_queue_id_i < 8;
			PROGRAM_NATIVE_WEIGHT, PROGRAM_NATIVE_PARAM, PROGRAM_NATIVE_DEQUANT,
			PROGRAM_NATIVE_COMPUTE, PROGRAM_NATIVE_BACKEND, PROGRAM_MACRO_PARAM, PROGRAM_MACRO_BACKEND,
			PROGRAM_TARGET_MXM_LOAD, PROGRAM_TARGET_MXM_DEQUANT,
			PROGRAM_TARGET_MXM_COMPUTE: begin
				if(command_write_global_queue_id_i < 2*MXMS_PER_HEMISPHERE)begin
					command_target_valid_w = 1'b1;
					command_hemisphere_w = command_write_global_queue_id_i < MXMS_PER_HEMISPHERE ?
						PROGRAM_HEMISPHERE_EAST : PROGRAM_HEMISPHERE_WEST;
					command_local_queue_w = command_write_global_queue_id_i[1:0];
					if(command_write_global_queue_id_i >= MXMS_PER_HEMISPHERE)begin
						command_local_queue_w = command_write_global_queue_id_i - MXMS_PER_HEMISPHERE;
					end
				end
			end
			default: command_target_valid_w = 1'b0;
		endcase
	end

	logic command_refill;
	assign command_write_ready_o = loader_command_write_ready && (!load_request_active_q || command_refill) &&
		!descriptor_fault_q;
	assign command_write_fire = command_write_valid_i && command_write_ready_o;
	assign descriptor_invalid_w = command_write_fire &&
		(command_write_opcode_i == PROGRAM_LOADER_LOAD_IMEM) &&
		(!command_target_valid_w || command_write_target_kind_i>PROGRAM_NATIVE_BACKEND ||
		 (raw_vxm ? (command_write_format_i != PROGRAM_FORMAT_96 || command_write_byte_count_i%12!=0 ||
		    command_write_expected_word_count_i != command_write_byte_count_i/12 ||
		    {1'b0,command_write_imem_base_address_i}+command_write_expected_word_count_i>VXM_IMEM_DEPTH) :
		  !mxm_macro && route_kind >= PROGRAM_TARGET_VXM ?
		   (command_write_encoding_mode_i != PROGRAM_ENCODING_NATIVE || command_write_format_i != PROGRAM_FORMAT_128 ||
		    command_write_imem_base_address_i != 0 || command_write_byte_count_i[4:0]!=0 ||
		    command_write_byte_count_i > 32*NATIVE_EVENT_DEPTH || command_write_expected_word_count_i != command_write_byte_count_i/16) :
		   (command_write_encoding_mode_i != PROGRAM_ENCODING_MACRO)) ||
		 (command_write_byte_count_i == 0) ||
		 ((route_kind == PROGRAM_TARGET_MEM) &&
		  ((command_write_format_i != PROGRAM_FORMAT_96) ||
		   ((command_write_byte_count_i % 12) != 0) ||
		   (command_write_expected_word_count_i != command_write_byte_count_i / 12) ||
		   ({1'b0, command_write_imem_base_address_i} + command_write_expected_word_count_i > MEM_IMEM_DEPTH))) ||
		 (mxm_macro &&
		  ((command_write_format_i != PROGRAM_FORMAT_128) ||
		   ((command_write_byte_count_i % 16) != 0) ||
		   (command_write_expected_word_count_i != command_write_byte_count_i / 16) ||
		   ({1'b0, command_write_imem_base_address_i} + command_write_expected_word_count_i > MXM_IMEM_DEPTH))));

	always_comb begin
		descriptor_duplicate_w = 1'b0;
		if(command_write_fire && (command_write_opcode_i == PROGRAM_LOADER_LOAD_IMEM) && command_target_valid_w)begin
			case(route_kind)
				PROGRAM_VXM_RAW96: descriptor_duplicate_w=raw_seen[command_write_global_queue_id_i[2:0]] || native_target_seen_q[{PROGRAM_TARGET_VXM,2'b0}];
				PROGRAM_TARGET_VXM: descriptor_duplicate_w=(|raw_seen) || native_target_seen_q[native_target_index];
				PROGRAM_TARGET_MEM: descriptor_duplicate_w = mem_target_seen_q[command_write_global_queue_id_i];
				PROGRAM_TARGET_MXM_LOAD: descriptor_duplicate_w = mxm_load_target_seen_q[command_write_global_queue_id_i[1:0]];
				PROGRAM_TARGET_MXM_DEQUANT: descriptor_duplicate_w = mxm_dequant_target_seen_q[command_write_global_queue_id_i[1:0]];
				PROGRAM_TARGET_MXM_COMPUTE: descriptor_duplicate_w = mxm_compute_target_seen_q[command_write_global_queue_id_i[1:0]];
				default: descriptor_duplicate_w = native_target_seen_q[native_target_index];
			endcase
		end
	end

	assign cluster_load_valid = {west_load_valid, east_load_valid};
	assign {west_load_ready, east_load_ready} = cluster_load_ready;
	assign cluster_load_control = {west_load_control, east_load_control};
	assign cluster_load_data = {west_load_data, east_load_data};
	assign cluster_load_strb = {west_load_strb, east_load_strb};
	assign cluster_load_target_kind = {west_load_target_kind, east_load_target_kind};
	assign cluster_load_queue_id = {west_load_queue_id, east_load_queue_id};
	assign cluster_load_imem_address = {west_load_imem_address, east_load_imem_address};
	assign cluster_load_last = {west_load_last, east_load_last};
	assign cluster_commit_ready = {west_commit_ready, east_commit_ready};
	assign endpoint_load_valid_o = cluster_load_valid;
	assign cluster_load_ready = endpoint_load_ready_i;
	assign endpoint_load_control_o = cluster_load_control;
	assign endpoint_load_data_o = cluster_load_data;
	assign endpoint_load_strb_o = cluster_load_strb;
	assign endpoint_load_target_kind_o = cluster_load_target_kind;
	assign endpoint_load_queue_id_o = cluster_load_queue_id;
	assign endpoint_load_imem_address_o = cluster_load_imem_address;
	assign endpoint_load_last_o = cluster_load_last;
	assign cluster_commit_valid = endpoint_commit_valid_i;
	assign endpoint_commit_ready_o = cluster_commit_ready;
	assign cluster_commit_error = endpoint_commit_error_i;
	assign endpoint_program_start_o = loader_program_start;
	assign cluster_start_ready = endpoint_program_start_ready_i;
	assign cluster_started = endpoint_started_i;
	assign cluster_frontends_ready = endpoint_frontends_ready_i;
	assign cluster_frontends_idle = endpoint_frontends_idle_i;
	assign cluster_fault = endpoint_fault_i;
	assign cluster_fault_code = endpoint_fault_code_i;
	assign schedule_cycle_o = endpoint_schedule_cycle_i;

	assign program_start_ack_o = loader_program_start && cluster_start_ready;
	assign load_start_ready_o = loader_start_ready && !load_request_active_q && !descriptor_fault_q;
	assign program_load_complete_o = instruction_load_done;
	assign program_ready_o = instruction_load_done && cluster_frontends_ready && !program_fault_o;
	assign program_running_o = cluster_started && !program_done_q && !program_fault_o;
	assign program_done_o = program_done_q;
	assign program_fault_o = descriptor_fault_q || loader_error || cluster_fault;
	assign program_fault_code_o = descriptor_fault_q ? PROGRAM_FAULT_DESCRIPTOR :
		(loader_error ? loader_error_code :
		(cluster_fault ? FRONTEND_FAULT_OFFSET + cluster_fault_code : PROGRAM_FAULT_NONE));

	lpu_program_load_subsystem #(
		.COMMAND_DEPTH(COMMAND_DEPTH),
		.DMA_DATA_WIDTH(DMA_DATA_WIDTH),
		.DMA_RX_FIFO_DEPTH(DMA_RX_FIFO_DEPTH),
		.DMA_OUTSTANDING_DEPTH(DMA_OUTSTANDING_DEPTH),
		.REASSEMBLY_BUFFER_BYTES(DMA_DATA_WIDTH/8 + 16 > 64 ? DMA_DATA_WIDTH/8 + 16 : 64),
		.PRIME_FIFO_DEPTH(COMMAND_DEPTH),
		.IMEM_DEPTH(TRANSPORT_IMEM_DEPTH),
		.COMMAND_ADDRESS_WIDTH(COMMAND_ADDRESS_WIDTH)
	) u_program_loader (
		.clk_i,
		.rst_ni,
		.abort_i(program_reset_i),
		.command_write_valid_i(command_write_fire),
		.command_write_ready_o(loader_command_write_ready),
		.command_refill_o(command_refill),
		.command_write_address_i,
		.command_write_opcode_i,
		.command_write_source_address_i,
		.command_write_byte_count_i,
		.command_write_hemisphere_i(command_hemisphere_w),
		.command_write_target_kind_i(route_kind),
		.command_write_queue_id_i(command_local_queue_w),
		.command_write_format_i,
		.command_write_imem_base_address_i,
		.command_write_image_first_i,
		.command_write_image_last_i,
		.command_write_expected_word_count_i,
		.command_write_jump_address_i,
		.start_valid_i(load_start_valid_i && load_start_ready_o),
		.start_ready_o(loader_start_ready),
		.start_command_count_i(load_start_command_count_i),
		.dma_cmd_valid_o,
		.dma_cmd_ready_i,
		.dma_cmd_address_o,
		.dma_cmd_length_o,
		.dma_cmd_id_o,
		.dma_rsp_valid_i,
		.dma_rsp_ready_o,
		.dma_rsp_data_i,
		.dma_rsp_keep_i,
		.dma_rsp_last_i,
		.dma_rsp_id_i,
		.dma_rsp_error_i,
		.west_load_valid_o(west_load_valid),
		.west_load_ready_i(west_load_ready),
		.west_load_control_o(west_load_control),
		.west_load_data_o(west_load_data),
		.west_load_strb_o(west_load_strb),
		.west_load_target_kind_o(west_load_target_kind),
		.west_load_queue_id_o(west_load_queue_id),
		.west_load_imem_address_o(west_load_imem_address),
		.west_load_last_o(west_load_last),
		.east_load_valid_o(east_load_valid),
		.east_load_ready_i(east_load_ready),
		.east_load_control_o(east_load_control),
		.east_load_data_o(east_load_data),
		.east_load_strb_o(east_load_strb),
		.east_load_target_kind_o(east_load_target_kind),
		.east_load_queue_id_o(east_load_queue_id),
		.east_load_imem_address_o(east_load_imem_address),
		.east_load_last_o(east_load_last),
		.west_commit_valid_i(cluster_commit_valid[1]),
		.west_commit_ready_o(west_commit_ready),
		.west_commit_error_i(cluster_commit_error[1]),
		.east_commit_valid_i(cluster_commit_valid[0]),
		.east_commit_ready_o(east_commit_ready),
		.east_commit_error_i(cluster_commit_error[0]),
		.weight_load_done_i(start_pending_q && dependencies_ready_i),
		.all_frontends_ready_i(cluster_frontends_ready),
		.instruction_load_done_o(instruction_load_done),
		.program_start_o(loader_program_start),
		.busy_o(loader_busy),
		.generated_word_count_o(),
		.committed_word_count_o(),
		.error_o(loader_error),
		.error_code_o(loader_error_code)
	);

	// Early START is sticky, matching CMODEL; dependencies must still be high on the acceptance cycle.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			start_pending_q <= 1'b0;
			load_request_active_q <= 1'b0;
			program_done_q <= 1'b0;
		end
		else if(program_reset_i)begin
			start_pending_q <= 1'b0;
			load_request_active_q <= 1'b0;
			program_done_q <= 1'b0;
		end
		else begin
			if(load_start_valid_i && load_start_ready_o)begin
				load_request_active_q <= 1'b1;
			end
			if(program_start_request_i && !program_done_q)begin
				start_pending_q <= 1'b1;
			end
			if(program_start_ack_o)begin
				start_pending_q <= 1'b0;
			end
			if(cluster_started && cluster_frontends_idle && endpoint_execution_drained_i && !program_fault_o)begin
				program_done_q <= 1'b1;
			end
		end
	end

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			descriptor_fault_q <= 1'b0;
			raw_seen <= 0;
			mem_target_seen_q <= '0;
			mxm_load_target_seen_q <= '0;
			mxm_dequant_target_seen_q <= '0;
			mxm_compute_target_seen_q <= '0;
			native_target_seen_q <= '0;
		end
		else if(program_reset_i)begin
			descriptor_fault_q <= 1'b0;
			raw_seen <= 0;
			mem_target_seen_q <= '0;
			mxm_load_target_seen_q <= '0;
			mxm_dequant_target_seen_q <= '0;
			mxm_compute_target_seen_q <= '0;
			native_target_seen_q <= '0;
		end
		else begin
			if(descriptor_invalid_w || descriptor_duplicate_w)begin
				descriptor_fault_q <= 1'b1;
			end
			if(command_write_fire && (command_write_opcode_i == PROGRAM_LOADER_LOAD_IMEM) &&
				command_target_valid_w && !descriptor_invalid_w && !descriptor_duplicate_w)begin
				case(route_kind)
					PROGRAM_VXM_RAW96: raw_seen[command_write_global_queue_id_i[2:0]] <= 1'b1;
					PROGRAM_TARGET_MEM: mem_target_seen_q[command_write_global_queue_id_i] <= 1'b1;
					PROGRAM_TARGET_MXM_LOAD: mxm_load_target_seen_q[command_write_global_queue_id_i[1:0]] <= 1'b1;
					PROGRAM_TARGET_MXM_DEQUANT: mxm_dequant_target_seen_q[command_write_global_queue_id_i[1:0]] <= 1'b1;
					PROGRAM_TARGET_MXM_COMPUTE: mxm_compute_target_seen_q[command_write_global_queue_id_i[1:0]] <= 1'b1;
					default: native_target_seen_q[native_target_index] <= 1'b1;
				endcase
			end
		end
	end
endmodule
