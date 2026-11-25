module lpu_slice_imem_fetch #(
	parameter integer IMEM_DEPTH = 256,
	parameter integer ADDRESS_WIDTH = IMEM_DEPTH <= 1 ? 1 : $clog2(IMEM_DEPTH),
	parameter integer WORD_WIDTH = 96
) (
	input logic clk_i,
	input logic rst_ni,

	// A descriptor defines one contiguous queue image in the shared physical iMEM.
	input  logic                       start_valid_i,
	output logic                       start_ready_o,
	input  logic [ADDRESS_WIDTH-1:0]   start_base_address_i,
	input  logic [$clog2(IMEM_DEPTH+1)-1:0] start_word_count_i,

	output logic                       request_valid_o,
	input  logic                       request_ready_i,
	output logic [ADDRESS_WIDTH-1:0]   request_address_o,
	output logic                       request_last_o,

	input  logic                       response_valid_i,
	output logic                       response_ready_o,
	input  logic [WORD_WIDTH-1:0]      response_data_i,
	input  logic                       response_last_i,

	output logic                       word_valid_o,
	input  logic                       word_ready_i,
	output logic [WORD_WIDTH-1:0]      word_o,
	output logic                       word_last_o,

	output logic                       busy_o,
	output logic                       done_o,
	output logic                       fault_o,
	output logic [1:0]                 fault_code_o
);
	localparam integer COUNT_WIDTH = $clog2(IMEM_DEPTH + 1);
	localparam logic [1:0] FAULT_NONE = 2'd0;
	localparam logic [1:0] FAULT_DESCRIPTOR = 2'd1;
	localparam logic [1:0] FAULT_RESPONSE = 2'd2;

	logic busy_q;
	logic done_q;
	logic fault_q;
	logic [1:0] fault_code_q;
	logic [ADDRESS_WIDTH-1:0] next_address_q;
	logic [COUNT_WIDTH-1:0] requests_remaining_q;
	logic [COUNT_WIDTH-1:0] responses_remaining_q;

	logic start_fire;
	logic request_fire;
	logic response_fire;
	logic [ADDRESS_WIDTH:0] descriptor_end_w;
	logic descriptor_illegal_w;
	logic response_protocol_error_w;

	assign descriptor_end_w = {1'b0, start_base_address_i} + start_word_count_i;
	assign descriptor_illegal_w = (start_word_count_i == '0) || (descriptor_end_w > IMEM_DEPTH);
	assign response_protocol_error_w = response_fire && (!busy_q ||
		(response_last_i != (responses_remaining_q == 1)));

	assign start_ready_o = !busy_q && !fault_q;
	assign start_fire = start_valid_i && start_ready_o;
	assign request_valid_o = busy_q && (requests_remaining_q != '0) && !fault_q;
	assign request_address_o = next_address_q;
	assign request_last_o = requests_remaining_q == 1;
	assign request_fire = request_valid_o && request_ready_i;

	assign word_valid_o = response_valid_i && !fault_q;
	assign word_o = response_data_i;
	assign word_last_o = response_last_i;
	assign response_ready_o = word_ready_i && !fault_q;
	assign response_fire = response_valid_i && response_ready_o;

	assign busy_o = busy_q;
	assign done_o = done_q;
	assign fault_o = fault_q || (start_fire && descriptor_illegal_w) || response_protocol_error_w;
	assign fault_code_o = fault_q ? fault_code_q :
		((start_fire && descriptor_illegal_w) ? FAULT_DESCRIPTOR :
		(response_protocol_error_w ? FAULT_RESPONSE : FAULT_NONE));

	// Descriptor state is independent from Decoder backpressure; responses remain buffered in iMEM.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			busy_q <= 1'b0;
			done_q <= 1'b0;
			next_address_q <= '0;
			requests_remaining_q <= '0;
			responses_remaining_q <= '0;
		end
		else begin
			done_q <= 1'b0;
			if(start_fire && !descriptor_illegal_w)begin
				busy_q <= 1'b1;
				next_address_q <= start_base_address_i;
				requests_remaining_q <= start_word_count_i;
				responses_remaining_q <= start_word_count_i;
			end
			if(request_fire)begin
				next_address_q <= next_address_q + 1'b1;
				requests_remaining_q <= requests_remaining_q - 1'b1;
			end
			if(response_fire)begin
				responses_remaining_q <= responses_remaining_q - 1'b1;
				if(response_last_i)begin
					busy_q <= 1'b0;
					done_q <= 1'b1;
				end
			end
		end
	end

	// Descriptor and response-order violations are sticky.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else begin
			if(!fault_q)begin
				if(start_fire && descriptor_illegal_w)begin
					fault_q <= 1'b1;
					fault_code_q <= FAULT_DESCRIPTOR;
				end
				else if(response_protocol_error_w)begin
					fault_q <= 1'b1;
					fault_code_q <= FAULT_RESPONSE;
				end
			end
		end
	end
endmodule
