module lpu_fifo #(
	parameter integer DATA_WIDTH = 1,
	parameter integer DEPTH = 16
) (
	input logic clk_i,
	input logic rst_ni,

	input logic enqueue_valid_i,
	output logic enqueue_ready_o,
	input logic [DATA_WIDTH-1:0] enqueue_data_i,

	output logic dequeue_valid_o,
	input logic dequeue_ready_i,
	output logic [DATA_WIDTH-1:0] dequeue_data_o,

	output logic [$clog2(DEPTH+1)-1:0] level_o
);
	localparam integer PTR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
	localparam integer LEVEL_WIDTH = $clog2(DEPTH + 1);

	logic [DATA_WIDTH-1:0] data_mem[0:DEPTH-1];
	logic [PTR_WIDTH-1:0] write_ptr_q;
	logic [PTR_WIDTH-1:0] read_ptr_q;
	logic [LEVEL_WIDTH-1:0] level_q;
	logic enqueue_fire;
	logic dequeue_fire;

	function automatic [PTR_WIDTH-1:0] increment_ptr(input logic [PTR_WIDTH-1:0] ptr);
		if(ptr == DEPTH - 1)begin
			increment_ptr = '0;
		end
		else begin
			increment_ptr = ptr + 1'b1;
		end
	endfunction

	assign dequeue_valid_o = (level_q != 0);
	assign dequeue_data_o = data_mem[read_ptr_q];
	assign dequeue_fire = dequeue_valid_o && dequeue_ready_i;
	assign enqueue_ready_o = (level_q < DEPTH) || dequeue_fire;
	assign enqueue_fire = enqueue_valid_i && enqueue_ready_o;
	assign level_o = level_q;

	// Write accepted entries without resetting the storage array.
	always_ff @(posedge clk_i) begin
		if(rst_ni)begin
			if(enqueue_fire)begin
				data_mem[write_ptr_q] <= enqueue_data_i;
			end
		end
	end

	// Advance read and write pointers independently on completed transfers.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			write_ptr_q <= '0;
			read_ptr_q <= '0;
		end
		else begin
			if(enqueue_fire)begin
				write_ptr_q <= increment_ptr(write_ptr_q);
			end
			if(dequeue_fire)begin
				read_ptr_q <= increment_ptr(read_ptr_q);
			end
		end
	end

	// Update occupancy once for each enqueue/dequeue combination.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			level_q <= '0;
		end
		else begin
			case ({enqueue_fire, dequeue_fire})
				2'b10: level_q <= level_q + 1'b1;
				2'b01: level_q <= level_q - 1'b1;
				default: level_q <= level_q;
			endcase
		end
	end
endmodule
