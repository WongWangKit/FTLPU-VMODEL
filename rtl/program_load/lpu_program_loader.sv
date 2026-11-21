module lpu_program_loader #(
	parameter integer COMMAND_DEPTH = 32,
	parameter integer COMMAND_ADDRESS_WIDTH = COMMAND_DEPTH <= 1 ? 1 : $clog2(COMMAND_DEPTH)
) (
	input logic clk_i,
	input logic rst_ni,

	input logic command_write_valid_i,
	output logic command_write_ready_o,
	input logic [COMMAND_ADDRESS_WIDTH-1:0] command_write_address_i,
	input logic [2:0] command_write_opcode_i,
	input logic [63:0] command_write_source_address_i,
	input logic [31:0] command_write_byte_count_i,
	input logic [1:0] command_write_hemisphere_i,
	input logic [3:0] command_write_target_kind_i,
	input logic [7:0] command_write_queue_id_i,
	input logic [1:0] command_write_format_i,
	input logic [16:0] command_write_imem_base_address_i,
	input logic command_write_image_first_i,
	input logic command_write_image_last_i,
	input logic [15:0] command_write_expected_word_count_i,
	input logic [COMMAND_ADDRESS_WIDTH-1:0] command_write_jump_address_i,

	input logic start_valid_i,
	output logic start_ready_o,
	input logic [COMMAND_ADDRESS_WIDTH:0] start_command_count_i,

	output logic transaction_valid_o,
	input logic transaction_ready_i,
	output logic [63:0] transaction_source_address_o,
	output logic [31:0] transaction_byte_count_o,
	output logic [1:0] transaction_hemisphere_o,
	output logic [3:0] transaction_target_kind_o,
	output logic [7:0] transaction_queue_id_o,
	output logic [1:0] transaction_format_o,
	output logic [16:0] transaction_imem_base_address_o,
	output logic transaction_image_first_o,
	output logic transaction_image_last_o,
	output logic [15:0] transaction_expected_word_count_o,
	output logic [7:0] transaction_dma_id_o,

	output logic commit_valid_o,
	input logic commit_ready_i,
	output logic [1:0] commit_hemisphere_o,
	output logic [3:0] commit_target_kind_o,
	output logic [7:0] commit_queue_id_o,

	input logic load_pipeline_idle_i,

	output logic [COMMAND_ADDRESS_WIDTH-1:0] command_pc_o,
	output logic busy_o,
	output logic done_o,
	output logic fault_o,
	output logic [5:0] fault_code_o
);
	import lpu_program_load_pkg::*;

	localparam integer COMMAND_RECORD_WIDTH = 150 + COMMAND_ADDRESS_WIDTH;

	logic [COMMAND_RECORD_WIDTH-1:0] command_mem_q [0:COMMAND_DEPTH-1];
	logic [COMMAND_RECORD_WIDTH-1:0] command_write_record_w;
	logic [COMMAND_RECORD_WIDTH-1:0] active_record_q;

	logic [2:0] active_opcode_w;
	logic [63:0] active_source_address_w;
	logic [31:0] active_byte_count_w;
	logic [1:0] active_hemisphere_w;
	logic [3:0] active_target_kind_w;
	logic [7:0] active_queue_id_w;
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

	logic command_write_fire;
	logic start_fire;
	logic fetch_command_w;
	logic transaction_fire;
	logic commit_fire;
	logic active_complete_w;
	logic active_invalid_w;
	logic start_invalid_w;
	logic jump_invalid_w;
	logic [COMMAND_DEPTH-1:0] command_valid_q;
	logic start_range_written_w;
	logic command_write_invalid_w;

	initial begin
		if(COMMAND_DEPTH < 1)begin
			$error("COMMAND_DEPTH must be at least one");
		end
	end

	assign command_write_record_w = {
		command_write_opcode_i,
		command_write_source_address_i,
		command_write_byte_count_i,
		command_write_hemisphere_i,
		command_write_target_kind_i,
		command_write_queue_id_i,
		command_write_format_i,
		command_write_imem_base_address_i,
		command_write_image_first_i,
		command_write_image_last_i,
		command_write_expected_word_count_i,
		command_write_jump_address_i
	};

	assign {
		active_opcode_w,
		active_source_address_w,
		active_byte_count_w,
		active_hemisphere_w,
		active_target_kind_w,
		active_queue_id_w,
		active_format_w,
		active_imem_base_address_w,
		active_image_first_w,
		active_image_last_w,
		active_expected_word_count_w,
		active_jump_address_w
	} = active_record_q;

	assign command_write_ready_o = !busy_q;
	assign command_write_fire = command_write_valid_i && command_write_ready_o;
	assign command_write_invalid_w = command_write_fire &&
		(int'(command_write_address_i) >= COMMAND_DEPTH);
	assign start_ready_o = !busy_q;
	assign start_fire = start_valid_i && start_ready_o;
	assign start_invalid_w = start_fire &&
		((start_command_count_i == '0) || (start_command_count_i > COMMAND_DEPTH) ||
		!start_range_written_w || fault_q || command_write_invalid_w);
	always_comb begin
		start_range_written_w = 1'b1;
		for (integer entry=0;entry<COMMAND_DEPTH;entry++) begin
			if (entry < int'(start_command_count_i) && !command_valid_q[entry])
				start_range_written_w = 1'b0;
		end
	end
	assign fetch_command_w = busy_q && !active_valid_q &&
		(command_pc_q < command_count_q);

	assign transaction_valid_o = active_valid_q &&
		(active_opcode_w == PROGRAM_LOADER_LOAD_IMEM) && !fault_q;
	assign transaction_fire = transaction_valid_o && transaction_ready_i;
	assign transaction_source_address_o = active_source_address_w;
	assign transaction_byte_count_o = active_byte_count_w;
	assign transaction_hemisphere_o = active_hemisphere_w;
	assign transaction_target_kind_o = active_target_kind_w;
	assign transaction_queue_id_o = active_queue_id_w;
	assign transaction_format_o = active_format_w;
	assign transaction_imem_base_address_o = active_imem_base_address_w;
	assign transaction_image_first_o = active_image_first_w;
	assign transaction_image_last_o = active_image_last_w;
	assign transaction_expected_word_count_o = active_expected_word_count_w;
	assign transaction_dma_id_o = next_dma_id_q;

	assign commit_valid_o = active_valid_q &&
		(active_opcode_w == PROGRAM_LOADER_COMMIT_QUEUE) && !fault_q;
	assign commit_fire = commit_valid_o && commit_ready_i;
	assign commit_hemisphere_o = active_hemisphere_w;
	assign commit_target_kind_o = active_target_kind_w;
	assign commit_queue_id_o = active_queue_id_w;

	assign jump_invalid_w = active_valid_q &&
		(active_opcode_w == PROGRAM_LOADER_JUMP) &&
		(active_jump_address_w >= command_count_q);
	assign active_invalid_w = active_valid_q &&
		((active_opcode_w > PROGRAM_LOADER_END) || jump_invalid_w);
	assign active_complete_w = active_valid_q && (
		((active_opcode_w == PROGRAM_LOADER_LOAD_IMEM) && transaction_fire) ||
		((active_opcode_w == PROGRAM_LOADER_WAIT_DMA) && load_pipeline_idle_i) ||
		((active_opcode_w == PROGRAM_LOADER_COMMIT_QUEUE) && commit_fire) ||
		(active_opcode_w == PROGRAM_LOADER_NEXT) ||
		((active_opcode_w == PROGRAM_LOADER_JUMP) && !jump_invalid_w) ||
		(active_opcode_w == PROGRAM_LOADER_END));

	assign command_pc_o = command_pc_q;
	assign busy_o = busy_q;
	assign done_o = done_q;
	assign fault_o = fault_q || start_invalid_w || active_invalid_w || command_write_invalid_w ||
		(busy_q && !active_valid_q && (command_pc_q >= command_count_q));
	assign fault_code_o = fault_q ? fault_code_q :
		(fault_o ? PROGRAM_FAULT_COMMAND : PROGRAM_FAULT_NONE);

	// Host programming is disabled while the sequencer owns the command RAM.
	always_ff @(posedge clk_i) begin
		if(rst_ni)begin
			if(command_write_fire && !command_write_invalid_w)begin
				command_mem_q[command_write_address_i] <= command_write_record_w;
			end
		end
	end
	// Data RAM contents are deliberately retained, but no old command from a
	// previous program segment can be executed without a new host write.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if (!rst_ni) command_valid_q <= '0;
		else if (command_write_fire && !command_write_invalid_w)
			command_valid_q[command_write_address_i] <= 1'b1;
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
			if(start_fire)begin
				command_pc_q <= '0;
				command_count_q <= start_command_count_i;
				active_valid_q <= 1'b0;
				busy_q <= !start_invalid_w;
				done_q <= 1'b0;
				next_dma_id_q <= '0;
			end
			else if(busy_q)begin
				if(fetch_command_w)begin
					active_valid_q <= 1'b1;
				end
				if(active_invalid_w ||
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
			if(start_invalid_w || active_invalid_w || command_write_invalid_w ||
				(busy_q && !active_valid_q && (command_pc_q >= command_count_q)))begin
				fault_q <= 1'b1;
				fault_code_q <= PROGRAM_FAULT_COMMAND;
			end
		end
	end
endmodule
