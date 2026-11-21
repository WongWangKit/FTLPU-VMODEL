module lpu_instruction_dma #(
	parameter integer DMA_DATA_WIDTH = 256,
	parameter integer DMA_ID_WIDTH = 8,
	parameter integer OUTSTANDING_DEPTH = 16,
	parameter integer RX_FIFO_DEPTH = 16
) (
	input logic clk_i,
	input logic rst_ni,

	input logic command_valid_i,
	output logic command_ready_o,
	input logic [63:0] command_address_i,
	input logic [31:0] command_length_i,
	input logic [DMA_ID_WIDTH-1:0] command_id_i,

	output logic dma_cmd_valid_o,
	input logic dma_cmd_ready_i,
	output logic [63:0] dma_cmd_address_o,
	output logic [31:0] dma_cmd_length_o,
	output logic [DMA_ID_WIDTH-1:0] dma_cmd_id_o,

	input logic dma_rsp_valid_i,
	output logic dma_rsp_ready_o,
	input logic [DMA_DATA_WIDTH-1:0] dma_rsp_data_i,
	input logic [DMA_DATA_WIDTH/8-1:0] dma_rsp_keep_i,
	input logic dma_rsp_last_i,
	input logic [DMA_ID_WIDTH-1:0] dma_rsp_id_i,
	input logic dma_rsp_error_i,

	output logic response_valid_o,
	input logic response_ready_i,
	output logic [DMA_DATA_WIDTH-1:0] response_data_o,
	output logic [DMA_DATA_WIDTH/8-1:0] response_keep_o,
	output logic response_last_o,
	output logic [DMA_ID_WIDTH-1:0] response_id_o,
	output logic response_error_o,

	output logic [$clog2(OUTSTANDING_DEPTH+1)-1:0] outstanding_o,
	output logic idle_o,
	output logic fault_o,
	output logic [5:0] fault_code_o
);
	import lpu_program_load_pkg::*;

	localparam integer DMA_KEEP_WIDTH = DMA_DATA_WIDTH / 8;
	localparam integer RESPONSE_WIDTH = DMA_DATA_WIDTH + DMA_KEEP_WIDTH + DMA_ID_WIDTH + 2;

	logic command_fire;
	logic response_input_fire;
	logic outstanding_enqueue_ready;
	logic outstanding_dequeue_valid;
	logic outstanding_dequeue_ready;
	logic [DMA_ID_WIDTH-1:0] outstanding_head_id;
	logic [$clog2(OUTSTANDING_DEPTH+1)-1:0] outstanding_level;

	logic response_enqueue_ready;
	logic [RESPONSE_WIDTH-1:0] response_enqueue_data;
	logic [RESPONSE_WIDTH-1:0] response_dequeue_data;
	logic [$clog2(RX_FIFO_DEPTH+1)-1:0] response_level;
	logic response_id_invalid_w;
	logic response_error_w;
	logic fault_q;
	logic [5:0] fault_code_q;

	initial begin
		if((DMA_DATA_WIDTH < 8) || ((DMA_DATA_WIDTH % 8) != 0))begin
			$error("DMA_DATA_WIDTH must contain a whole number of bytes");
		end
		if((OUTSTANDING_DEPTH < 1) || (RX_FIFO_DEPTH < 1))begin
			$error("Instruction DMA requires positive command and response depths");
		end
	end

	// Command acceptance reserves an ordered outstanding slot before the external DMA sees valid.
	assign dma_cmd_valid_o = command_valid_i && outstanding_enqueue_ready && !fault_q;
	assign dma_cmd_address_o = command_address_i;
	assign dma_cmd_length_o = command_length_i;
	assign dma_cmd_id_o = command_id_i;
	assign command_ready_o = dma_cmd_ready_i && outstanding_enqueue_ready && !fault_q;
	assign command_fire = command_valid_i && command_ready_o;

	assign response_enqueue_data = {
		dma_rsp_error_i,
		dma_rsp_id_i,
		dma_rsp_last_i,
		dma_rsp_keep_i,
		dma_rsp_data_i
	};
	assign dma_rsp_ready_o = response_enqueue_ready && !fault_q;
	assign response_input_fire = dma_rsp_valid_i && dma_rsp_ready_o;
	assign outstanding_dequeue_ready = response_input_fire && dma_rsp_last_i;

	assign {
		response_error_o,
		response_id_o,
		response_last_o,
		response_keep_o,
		response_data_o
	} = response_dequeue_data;

	assign response_id_invalid_w = response_input_fire &&
		(!outstanding_dequeue_valid || (dma_rsp_id_i != outstanding_head_id));
	assign response_error_w = response_input_fire && dma_rsp_error_i;
	assign outstanding_o = outstanding_level;
	assign idle_o = (outstanding_level == '0) && (response_level == '0);
	assign fault_o = fault_q || response_id_invalid_w || response_error_w;
	assign fault_code_o = fault_q ? fault_code_q :
		(response_id_invalid_w ? PROGRAM_FAULT_DMA_ID :
		(response_error_w ? PROGRAM_FAULT_DMA_RESPONSE : PROGRAM_FAULT_NONE));

	lpu_queue_fifo #(
		.DATA_WIDTH(DMA_ID_WIDTH),
		.DEPTH(OUTSTANDING_DEPTH)
	) u_outstanding_id_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i(command_fire),
		.enqueue_ready_o(outstanding_enqueue_ready),
		.enqueue_data_i(command_id_i),
		.dequeue_valid_o(outstanding_dequeue_valid),
		.dequeue_ready_i(outstanding_dequeue_ready),
		.dequeue_data_o(outstanding_head_id),
		.level_o(outstanding_level)
	);

	lpu_queue_fifo #(
		.DATA_WIDTH(RESPONSE_WIDTH),
		.DEPTH(RX_FIFO_DEPTH)
	) u_response_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i(dma_rsp_valid_i && !fault_q),
		.enqueue_ready_o(response_enqueue_ready),
		.enqueue_data_i(response_enqueue_data),
		.dequeue_valid_o(response_valid_o),
		.dequeue_ready_i(response_ready_i),
		.dequeue_data_o(response_dequeue_data),
		.level_o(response_level)
	);

	// DMA ordering and response errors are terminal until reset.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= PROGRAM_FAULT_NONE;
		end
		else if(!fault_q)begin
			if(response_id_invalid_w)begin
				fault_q <= 1'b1;
				fault_code_q <= PROGRAM_FAULT_DMA_ID;
			end
			else if(response_error_w)begin
				fault_q <= 1'b1;
				fault_code_q <= PROGRAM_FAULT_DMA_RESPONSE;
			end
		end
	end
endmodule
