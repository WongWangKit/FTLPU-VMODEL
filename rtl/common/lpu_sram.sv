module lpu_sram #(
	parameter integer DATA_WIDTH = 1,
	parameter integer DEPTH = 16,
	parameter integer ADDRESS_WIDTH = DEPTH <= 1 ? 1 : $clog2(DEPTH)
) (
	input logic clk_i,
	input logic rst_ni,

	// cen_i and wen_i are active high. A write owns the single port for the cycle.
	input logic cen_i,
	input logic wen_i,
	input logic [ADDRESS_WIDTH-1:0] address_i,
	input logic [DATA_WIDTH-1:0] wdata_i,

	// A read produces rvalid_o and rdata_o after the accepting rising edge.
	output logic rvalid_o,
	output logic [DATA_WIDTH-1:0] rdata_o
);
	logic [DATA_WIDTH-1:0] memory_q[0:DEPTH-1];
	logic rvalid_q;
	logic [DATA_WIDTH-1:0] rdata_q;

	initial begin
		if(DATA_WIDTH < 1 || DEPTH < 1)begin
			$error("DATA_WIDTH and DEPTH must be positive");
		end
	end

	assign rvalid_o = rvalid_q;
	assign rdata_o = rdata_q;

	// The 1RW port writes when wen_i is high; otherwise it performs a synchronous read.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			rvalid_q <= 1'b0;
			rdata_q <= '0;
		end
		else begin
			rvalid_q <= cen_i && !wen_i;
			if(cen_i)begin
				if(wen_i)begin
					memory_q[address_i] <= wdata_i;
				end
				else begin
					rdata_q <= memory_q[address_i];
				end
			end
		end
	end
endmodule
