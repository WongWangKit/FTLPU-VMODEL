module lpu_mem_bank_queue #(
	parameter integer DEPTH = 16
) (
	input logic clk_i,
	input logic rst_ni,
	input logic run_i,
	input logic [31:0] schedule_cycle_i,
	input logic enqueue_valid_i,
	output logic enqueue_ready_o,
	input logic [lpu_pkg::MEM_INSTRUCTION_WIDTH-1:0] enqueue_instruction_i,
	input logic [31:0] enqueue_cycle_i,
	output logic issue_valid_o,
	input logic issue_ready_i,
	output logic [lpu_pkg::MEM_INSTRUCTION_WIDTH-1:0] issue_instruction_o,
	output logic [31:0] issue_cycle_o,
	output logic [$clog2(DEPTH+1)-1:0] level_o,
	output logic fault_o
);
	localparam integer ENTRY_WIDTH = 32 + lpu_pkg::MEM_INSTRUCTION_WIDTH;
	logic fifo_enqueue_valid;
	logic fifo_enqueue_ready;
	logic [ENTRY_WIDTH-1:0] fifo_enqueue_data;
	logic fifo_dequeue_valid;
	logic fifo_dequeue_ready;
	logic [ENTRY_WIDTH-1:0] fifo_dequeue_data;
	logic [lpu_pkg::MEM_INSTRUCTION_WIDTH-1:0] head_instruction;
	logic [31:0] head_cycle;
	logic issue_fire;
	logic enqueue_fire;
	logic enqueue_deadline_fault_w;
	logic deadline_fault_w;
	logic late_fault_w;
	logic fault_q;

	// The Timed Queue is the only sequential buffer between the Scheduler and MEM Bank.
	// A newly enqueued instruction becomes visible after the write edge; no empty bypass exists.
	assign head_instruction = fifo_dequeue_data[0+:lpu_pkg::MEM_INSTRUCTION_WIDTH];
	assign head_cycle = fifo_dequeue_data[lpu_pkg::MEM_INSTRUCTION_WIDTH+:32];
	assign issue_valid_o = run_i && fifo_dequeue_valid && (head_cycle == schedule_cycle_i) && !fault_q;
	assign issue_instruction_o = head_instruction;
	assign issue_cycle_o = head_cycle;
	assign issue_fire = issue_valid_o && issue_ready_i;
	assign enqueue_ready_o = fifo_enqueue_ready && !fault_q;
	assign enqueue_fire = enqueue_valid_i && enqueue_ready_o;
	assign fifo_enqueue_valid = enqueue_valid_i && !fault_q;
	assign fifo_enqueue_data = {enqueue_cycle_i, enqueue_instruction_i};
	assign fifo_dequeue_ready = fifo_dequeue_valid && issue_fire;
	assign enqueue_deadline_fault_w = enqueue_fire && run_i && (enqueue_cycle_i <= schedule_cycle_i);
	assign late_fault_w = run_i && fifo_dequeue_valid && (head_cycle < schedule_cycle_i);
	assign deadline_fault_w = run_i && fifo_dequeue_valid && (head_cycle == schedule_cycle_i) && !issue_ready_i;
	assign fault_o = fault_q || enqueue_deadline_fault_w || late_fault_w || deadline_fault_w;

	lpu_queue_fifo #(.DATA_WIDTH(ENTRY_WIDTH), .DEPTH(DEPTH)) u_storage (
		.clk_i, .rst_ni,
		.enqueue_valid_i(fifo_enqueue_valid), .enqueue_ready_o(fifo_enqueue_ready),
		.enqueue_data_i(fifo_enqueue_data), .dequeue_valid_o(fifo_dequeue_valid),
		.dequeue_ready_i(fifo_dequeue_ready), .dequeue_data_o(fifo_dequeue_data), .level_o
	);

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
		end
		else if(!fault_q && (enqueue_deadline_fault_w || late_fault_w || deadline_fault_w))begin
			fault_q <= 1'b1;
		end
	end
endmodule
