module lpu_program_load_controller #(
	parameter integer COMMAND_DEPTH = 32,
	parameter integer COMMAND_ADDRESS_WIDTH = COMMAND_DEPTH <= 1 ? 1 : $clog2(COMMAND_DEPTH)
) (
	input logic clk_i,
	input logic rst_ni,

	input logic program_cmd_write_valid_i,
	output logic program_cmd_write_ready_o,
	input logic [COMMAND_ADDRESS_WIDTH-1:0] program_cmd_write_address_i,
	input logic [2:0] program_cmd_write_opcode_i,
	input logic [63:0] program_cmd_write_source_address_i,
	input logic [31:0] program_cmd_write_byte_count_i,
	input logic [1:0] program_cmd_write_scope_i,
	input logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		program_cmd_write_destination_i,
	input logic [1:0] program_cmd_write_format_i,
	input logic [16:0] program_cmd_write_imem_base_address_i,
	input logic program_cmd_write_image_first_i,
	input logic program_cmd_write_image_last_i,
	input logic [15:0] program_cmd_write_expected_word_count_i,
	input logic [COMMAND_ADDRESS_WIDTH-1:0] program_cmd_write_jump_address_i,

	input logic program_load_start_valid_i,
	output logic program_load_start_ready_o,
	input logic [COMMAND_ADDRESS_WIDTH:0] program_load_start_command_count_i,

	output logic ctrl_load_txn_valid_o,
	input logic ctrl_load_txn_ready_i,
	output logic [63:0] ctrl_load_txn_source_address_o,
	output logic [31:0] ctrl_load_txn_byte_count_o,
	output logic [1:0] ctrl_load_txn_scope_o,
	output logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		ctrl_load_txn_destination_o,
	output logic [1:0] ctrl_load_txn_format_o,
	output logic [16:0] ctrl_load_txn_imem_base_address_o,
	output logic ctrl_load_txn_image_first_o,
	output logic ctrl_load_txn_image_last_o,
	output logic [15:0] ctrl_load_txn_expected_word_count_o,
	output logic [7:0] ctrl_load_txn_dma_id_o,

	output logic ctrl_prime_valid_o,
	input logic ctrl_prime_ready_i,
	output logic [1:0] ctrl_prime_scope_o,
	output logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0]
		ctrl_prime_destination_o,

	input logic load_pipeline_idle_i,

	output logic [COMMAND_ADDRESS_WIDTH-1:0] command_pc_o,
	output logic busy_o,
	output logic done_o,
	output logic fault_o,
	output logic [5:0] fault_code_o
);
	import lpu_program_load_pkg::*;

	localparam integer COMMAND_RECORD_WIDTH = 138 +
		lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH + COMMAND_ADDRESS_WIDTH;

	logic [COMMAND_RECORD_WIDTH-1:0] command_mem_q [0:COMMAND_DEPTH-1];
	logic [COMMAND_RECORD_WIDTH-1:0] program_cmd_write_record_w;
	logic [COMMAND_RECORD_WIDTH-1:0] active_record_q;

	logic [2:0] active_opcode_w;
	logic [63:0] active_source_address_w;
	logic [31:0] active_byte_count_w;
	logic [1:0] active_scope_w;
	logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0] active_destination_w;
	logic [1:0] active_format_w;
	logic [16:0] active_imem_base_address_w;
	logic active_image_first_w;
	logic active_image_last_w;
	logic [15:0] active_expected_word_count_w;
	logic [COMMAND_ADDRESS_WIDTH-1:0] active_jump_address_w;

	logic [COMMAND_ADDRESS_WIDTH-1:0] command_pc_q;
	logic [COMMAND_ADDRESS_WIDTH:0] command_count_q;
	logic active_valid_q;
	logic busy_q;
	logic done_q;
	logic [7:0] next_dma_id_q;
	logic fault_q;
	logic [5:0] fault_code_q;

	logic program_cmd_write_fire;
	logic program_load_start_fire;
	logic fetch_command_w;
	logic ctrl_load_txn_fire;
	logic ctrl_prime_fire;
	logic active_complete_w;
	logic active_command_illegal_w;
	logic program_load_start_illegal_w;
	logic jump_target_illegal_w;

	initial begin
		if(COMMAND_DEPTH < 1)begin
			$error("COMMAND_DEPTH must be at least one");
		end
	end

	assign program_cmd_write_record_w = {
		program_cmd_write_opcode_i,
		program_cmd_write_source_address_i,
		program_cmd_write_byte_count_i,
		program_cmd_write_scope_i,
		program_cmd_write_destination_i,
		program_cmd_write_format_i,
		program_cmd_write_imem_base_address_i,
		program_cmd_write_image_first_i,
		program_cmd_write_image_last_i,
		program_cmd_write_expected_word_count_i,
		program_cmd_write_jump_address_i
	};

	assign {
		active_opcode_w,
		active_source_address_w,
		active_byte_count_w,
		active_scope_w,
		active_destination_w,
		active_format_w,
		active_imem_base_address_w,
		active_image_first_w,
		active_image_last_w,
		active_expected_word_count_w,
		active_jump_address_w
	} = active_record_q;

	assign program_cmd_write_ready_o = !busy_q;
	assign program_cmd_write_fire = program_cmd_write_valid_i && program_cmd_write_ready_o;
	assign program_load_start_ready_o = !busy_q;
	assign program_load_start_fire = program_load_start_valid_i && program_load_start_ready_o;
	assign program_load_start_illegal_w = program_load_start_fire &&
		((program_load_start_command_count_i == '0) || (program_load_start_command_count_i > COMMAND_DEPTH));
	assign fetch_command_w = busy_q && !active_valid_q &&
		(command_pc_q < command_count_q);

	assign ctrl_load_txn_valid_o = active_valid_q &&
		(active_opcode_w == PROGRAM_LOADER_LOAD_IMEM) && !fault_q;
	assign ctrl_load_txn_fire = ctrl_load_txn_valid_o && ctrl_load_txn_ready_i;
	assign ctrl_load_txn_source_address_o = active_source_address_w;
	assign ctrl_load_txn_byte_count_o = active_byte_count_w;
	assign ctrl_load_txn_scope_o = active_scope_w;
	assign ctrl_load_txn_destination_o = active_destination_w;
	assign ctrl_load_txn_format_o = active_format_w;
	assign ctrl_load_txn_imem_base_address_o = active_imem_base_address_w;
	assign ctrl_load_txn_image_first_o = active_image_first_w;
	assign ctrl_load_txn_image_last_o = active_image_last_w;
	assign ctrl_load_txn_expected_word_count_o = active_expected_word_count_w;
	assign ctrl_load_txn_dma_id_o = next_dma_id_q;

	assign ctrl_prime_valid_o = active_valid_q &&
		(active_opcode_w == PROGRAM_LOADER_COMMIT_QUEUE) && !fault_q;
	assign ctrl_prime_fire = ctrl_prime_valid_o && ctrl_prime_ready_i;
	assign ctrl_prime_scope_o = active_scope_w;
	assign ctrl_prime_destination_o = active_destination_w;

	assign jump_target_illegal_w = active_valid_q &&
		(active_opcode_w == PROGRAM_LOADER_JUMP) &&
		(active_jump_address_w >= command_count_q);
	assign active_command_illegal_w = active_valid_q &&
		((active_opcode_w > PROGRAM_LOADER_END) || jump_target_illegal_w);
	assign active_complete_w = active_valid_q && (
		((active_opcode_w == PROGRAM_LOADER_LOAD_IMEM) && ctrl_load_txn_fire) ||
		((active_opcode_w == PROGRAM_LOADER_WAIT_DMA) && load_pipeline_idle_i) ||
		((active_opcode_w == PROGRAM_LOADER_COMMIT_QUEUE) && ctrl_prime_fire) ||
		(active_opcode_w == PROGRAM_LOADER_NEXT) ||
		((active_opcode_w == PROGRAM_LOADER_JUMP) && !jump_target_illegal_w) ||
		(active_opcode_w == PROGRAM_LOADER_END));

	assign command_pc_o = command_pc_q;
	assign busy_o = busy_q;
	assign done_o = done_q;
	assign fault_o = fault_q || program_load_start_illegal_w || active_command_illegal_w ||
		(busy_q && !active_valid_q && (command_pc_q >= command_count_q));
	assign fault_code_o = fault_q ? fault_code_q :
		(fault_o ? PROGRAM_FAULT_COMMAND : PROGRAM_FAULT_NONE);

	// Host programming is disabled while the sequencer owns the command RAM.
	always_ff @(posedge clk_i) begin
		if(rst_ni)begin
			if(program_cmd_write_fire)begin
				command_mem_q[program_cmd_write_address_i] <= program_cmd_write_record_w;
			end
		end
	end

	// Command payload is captured as one record before any external valid can assert.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			active_record_q <= '0;
		end
		else if(fetch_command_w)begin
			active_record_q <= command_mem_q[command_pc_q];
		end
	end

	// PC and active-valid state advance only when the current command action completes.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			command_pc_q <= '0;
			command_count_q <= '0;
			active_valid_q <= 1'b0;
			busy_q <= 1'b0;
			done_q <= 1'b0;
			next_dma_id_q <= '0;
		end
		else begin
			if(program_load_start_fire)begin
				command_pc_q <= '0;
				command_count_q <= program_load_start_command_count_i;
				active_valid_q <= 1'b0;
				busy_q <= !program_load_start_illegal_w;
				done_q <= 1'b0;
				next_dma_id_q <= '0;
			end
			else if(busy_q)begin
				if(fetch_command_w)begin
					active_valid_q <= 1'b1;
				end
				if(active_command_illegal_w ||
					(!active_valid_q && (command_pc_q >= command_count_q)))begin
					active_valid_q <= 1'b0;
					busy_q <= 1'b0;
				end
				else if(active_complete_w)begin
					active_valid_q <= 1'b0;
					case(active_opcode_w)
						PROGRAM_LOADER_JUMP: command_pc_q <= active_jump_address_w;
						PROGRAM_LOADER_END: begin
							busy_q <= 1'b0;
							done_q <= 1'b1;
						end
						default: command_pc_q <= command_pc_q + 1'b1;
					endcase
					if(active_opcode_w == PROGRAM_LOADER_LOAD_IMEM)begin
						next_dma_id_q <= next_dma_id_q + 1'b1;
					end
				end
			end
		end
	end

	// Command stream errors are sticky and require reset or subsystem abort.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= PROGRAM_FAULT_NONE;
		end
		else if(!fault_q)begin
			if(program_load_start_illegal_w || active_command_illegal_w ||
				(busy_q && !active_valid_q && (command_pc_q >= command_count_q)))begin
				fault_q <= 1'b1;
				fault_code_q <= PROGRAM_FAULT_COMMAND;
			end
		end
	end
endmodule
