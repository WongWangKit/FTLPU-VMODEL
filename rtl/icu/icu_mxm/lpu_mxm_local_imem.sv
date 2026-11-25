module lpu_mxm_local_imem #(
	parameter integer WORD_WIDTH = 96,
	parameter integer DEPTH = 256,
	parameter integer ADDRESS_WIDTH = DEPTH <= 1 ? 1 : $clog2(DEPTH),
	parameter integer RESPONSE_DEPTH = 4
) (
	input logic clk_i,
	input logic rst_ni,

	// Program loading owns the single SRAM port until this Queue is primed.
	input  logic                      load_mode_i,
	input  logic                      load_valid_i,
	output logic                      load_ready_o,
	input  logic [ADDRESS_WIDTH-1:0]  load_address_i,
	input  logic [WORD_WIDTH-1:0]     load_data_i,

	// Fetch requests are in order, have a two-cycle SRAM latency and II=1.
	input  logic                      request_valid_i,
	output logic                      request_ready_o,
	input  logic [ADDRESS_WIDTH-1:0]  request_address_i,
	input  logic                      request_last_i,

	output logic                      response_valid_o,
	input  logic                      response_ready_i,
	output logic [WORD_WIDTH-1:0]     response_data_o,
	output logic                      response_last_o,

	output logic [$clog2(RESPONSE_DEPTH+1)-1:0] outstanding_o,
	output logic                      idle_o,
	output logic                      fault_o
);
	localparam integer OUTSTANDING_WIDTH = $clog2(RESPONSE_DEPTH + 1);
	localparam integer RESPONSE_WIDTH = WORD_WIDTH + 1;

	logic request_stage_valid_q;
	logic request_stage_last_q;
	logic response_stage_valid_q;
	logic [RESPONSE_WIDTH-1:0] response_stage_data_q;
	logic sram_cen;
	logic sram_wen;
	logic [ADDRESS_WIDTH-1:0] sram_address;
	logic [WORD_WIDTH-1:0] sram_wdata;
	logic sram_read_valid;
	logic [WORD_WIDTH-1:0] sram_read_data;
	logic [OUTSTANDING_WIDTH-1:0] outstanding_q;
	logic [RESPONSE_WIDTH-1:0] response_fifo_data;
	logic response_fifo_ready;
	logic [$clog2(RESPONSE_DEPTH+1)-1:0] response_fifo_level;
	logic load_fire;
	logic request_fire;
	logic response_fire;
	logic protocol_fault_w;
	logic fault_q;

	initial begin
		if(WORD_WIDTH < 1 || DEPTH < 1)begin
			$error("WORD_WIDTH and DEPTH must be positive");
		end
		if(RESPONSE_DEPTH < 2)begin
			$error("RESPONSE_DEPTH must cover the two-cycle SRAM pipeline");
		end
	end

	assign response_valid_o = response_fifo_level != '0;
	assign response_data_o = response_fifo_data[WORD_WIDTH-1:0];
	assign response_last_o = response_fifo_data[WORD_WIDTH];
	assign response_fire = response_valid_o && response_ready_i;
	assign outstanding_o = outstanding_q;
	assign idle_o = (outstanding_q == '0) && !request_stage_valid_q && !response_stage_valid_q;

	assign load_ready_o = load_mode_i && idle_o && !fault_q;
	assign load_fire = load_valid_i && load_ready_o;
	assign request_ready_o = !load_mode_i && !fault_q &&
		((outstanding_q < RESPONSE_DEPTH) || response_fire);
	assign request_fire = request_valid_i && request_ready_o;
	assign sram_cen = load_fire || request_fire;
	assign sram_wen = load_fire;
	assign sram_address = load_fire ? load_address_i : request_address_i;
	assign sram_wdata = load_data_i;
	assign protocol_fault_w = (response_stage_valid_q && !response_fifo_ready) ||
		(load_mode_i && (outstanding_q != '0));
	assign fault_o = fault_q || protocol_fault_w;

	lpu_sram #(
		.DATA_WIDTH(WORD_WIDTH),
		.DEPTH(DEPTH),
		.ADDRESS_WIDTH(ADDRESS_WIDTH)
	) u_storage (
		.clk_i,
		.rst_ni,
		.cen_i(sram_cen),
		.wen_i(sram_wen),
		.address_i(sram_address),
		.wdata_i(sram_wdata),
		.rvalid_o(sram_read_valid),
		.rdata_o(sram_read_data)
	);

	lpu_fifo #(
		.DATA_WIDTH(RESPONSE_WIDTH),
		.DEPTH(RESPONSE_DEPTH)
	) u_response_fifo (
		.clk_i,
		.rst_ni,
		.enqueue_valid_i(response_stage_valid_q),
		.enqueue_ready_o(response_fifo_ready),
		.enqueue_data_i(response_stage_data_q),
		.dequeue_valid_o(),
		.dequeue_ready_i(response_ready_i),
		.dequeue_data_o(response_fifo_data),
		.level_o(response_fifo_level)
	);

	// Preserve the two-stage local-iMEM response pipeline around the synchronous SRAM read.
	//why???
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			request_stage_valid_q <= 1'b0;
			request_stage_last_q <= 1'b0;
			response_stage_valid_q <= 1'b0;
			response_stage_data_q <= '0;
		end
		else begin
			request_stage_valid_q <= request_fire;
			if(request_fire)begin
				request_stage_last_q <= request_last_i;
			end
			response_stage_valid_q <= sram_read_valid;
			if(sram_read_valid)begin
				response_stage_data_q <= {request_stage_last_q, sram_read_data};
			end
		end
	end

	// Track accepted requests that have not yet retired from the response FIFO.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			outstanding_q <= '0;
		end
		else begin
			case({request_fire, response_fire})
				2'b10: outstanding_q <= outstanding_q + 1'b1;
				2'b01: outstanding_q <= outstanding_q - 1'b1;
				default: outstanding_q <= outstanding_q;
			endcase
		end
	end

	// Request ordering and outstanding-count violations remain sticky until reset.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
		end
		else if(protocol_fault_w)begin
			fault_q <= 1'b1;
		end
	end
endmodule
