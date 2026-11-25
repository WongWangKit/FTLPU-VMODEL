// Each native event occupies two 128-bit words: payload, then {reserved, aux, cycle}.
// Only sequential, complete event pairs become visible after PRIME. Payload RAM
// is intentionally not reset; count/half/primed delimit the current program.
module lpu_sxm_native_issue_calendar #(
	parameter integer DEPTH = 64,
	parameter integer PAYLOAD_BITS = 128,
	parameter integer AUX_BITS = 6,
	localparam integer AW = DEPTH <= 1 ? 1 : $clog2(DEPTH)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic write_i,
	input logic prime_i,
	input logic run_i,
	input logic [16:0] address_i,
	input logic [127:0] data_i,
	input logic [3:0] strb_i,
	input logic last_i,
	input logic [31:0] cycle_i,
	output logic [127:0] payload_o,
	output logic [31:0] auxiliary_o,
	output logic issue_o,
	output logic ready_o,
	output logic idle_o,
	output logic fault_o
);
	logic [127:0] payload_q [0:DEPTH-1];
	logic [ 63:0] schedule_q[0:DEPTH-1];
	logic [AW:0] count_q, head_q;
	logic half_q, sealed_q, primed_q;
	logic [31:0] previous_cycle_q;
	logic write_legal_w, prime_legal_w, head_present_w;
	logic [31:0] head_cycle_w;

	// Guard the array index before exposing the next event of this program.
	always_comb begin
		head_present_w = primed_q && (head_q < count_q) && (head_q < DEPTH);
		payload_o = '0;
		auxiliary_o = '0;
		head_cycle_w = '0;
		if(head_present_w)begin
			payload_o = payload_q[head_q[AW-1:0]];
			auxiliary_o = schedule_q[head_q[AW-1:0]][63:32];
			head_cycle_w = schedule_q[head_q[AW-1:0]][31:0];
		end
	end

	// WRITE commits exactly one word. Timing words must be strictly ordered;
	// last marks only a timing word, so a truncated payload can never be primed.
	always_comb begin
		write_legal_w = !run_i && !primed_q && !sealed_q && (count_q < DEPTH) &&
			(strb_i == 4'hf) && (address_i == (32'(count_q)*2 + 32'(half_q)));
		if(half_q)begin
			write_legal_w = write_legal_w && ((data_i >> (32+AUX_BITS)) == 0) &&
				((count_q == 0) || (data_i[31:0] > previous_cycle_q));
		end
		else begin
			write_legal_w = write_legal_w && !last_i && ((data_i >> PAYLOAD_BITS) == 0);
		end
		prime_legal_w = !run_i && sealed_q && !half_q && !primed_q && (count_q != 0);
	end

	assign ready_o = !fault_o && ((count_q == 0 && !half_q) || primed_q);
	assign idle_o  = !half_q && (head_q == count_q);
	// An event is a fixed-cycle pulse. A missed deadline faults; it never retries.
	assign issue_o = run_i && head_present_w && (cycle_i == head_cycle_w) && !fault_o;

	// Own event visibility, load progress and the runtime head in one register block.
	always_ff @(posedge clk_i or negedge rst_ni)begin
		if(!rst_ni)begin
			count_q <= '0;
			head_q <= '0;
			half_q <= 1'b0;
			sealed_q <= 1'b0;
			primed_q <= 1'b0;
			previous_cycle_q <= '0;
			fault_o <= 1'b0;
		end
		else begin
			if(write_i)begin
				if(!write_legal_w)begin
					fault_o <= 1'b1;
				end
				else begin
					if(!half_q)begin
						payload_q[count_q[AW-1:0]] <= data_i;
						half_q <= 1'b1;
					end
					else begin
						schedule_q[count_q[AW-1:0]] <= data_i[63:0];
						count_q <= count_q + 1'b1;
						half_q <= 1'b0;
						sealed_q <= last_i;
						previous_cycle_q <= data_i[31:0];
					end
				end
			end
			if(prime_i)begin
				if(prime_legal_w)begin
					primed_q <= 1'b1;
				end
				else begin
					fault_o <= 1'b1;
				end
			end
			if(run_i && head_present_w && cycle_i > head_cycle_w)begin
				fault_o <= 1'b1;
			end
			if(issue_o)begin
				head_q <= head_q + 1'b1;
			end
		end
	end
endmodule
