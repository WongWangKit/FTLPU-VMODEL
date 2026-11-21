module lpu_qctl_shared_pool #(
	parameter integer POOL_DEPTH = 512,
	// Current LPU32 CModel allocates QCTL partitions for 208 MEM Queues and three streams of four MXMs.
	parameter integer QUEUE_COUNT = 220,
	parameter integer QUEUE_ENTRY_LIMIT = 16,
	parameter integer READ_LATENCY = 2,
	parameter integer GENERATION_WIDTH = 64,
	parameter integer POOL_ADDRESS_WIDTH = POOL_DEPTH <= 1 ? 1 : $clog2(POOL_DEPTH),
	parameter integer QUEUE_ID_WIDTH = QUEUE_COUNT <= 1 ? 1 : $clog2(QUEUE_COUNT),
	parameter integer ENTRY_INDEX_WIDTH = QUEUE_ENTRY_LIMIT <= 1 ? 1 : $clog2(QUEUE_ENTRY_LIMIT),
	parameter integer ENTRY_COUNT_WIDTH = $clog2(QUEUE_ENTRY_LIMIT + 1)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic clear_i,
	input logic load_mode_i,

	// Program loading configures one non-overlapping partition per logical Queue.
	input logic partition_valid_i,
	output logic partition_ready_o,
	input logic [QUEUE_ID_WIDTH-1:0] partition_queue_i,
	input logic [POOL_ADDRESS_WIDTH-1:0] partition_base_i,
	input logic [ENTRY_COUNT_WIDTH-1:0] partition_count_i,
	input logic [GENERATION_WIDTH-1:0] partition_generation_i,

	// QCTL records are physical 12-byte words: Cycle, 32-bit Opcode word and Operand.
	input logic load_valid_i,
	output logic load_ready_o,
	input logic [POOL_ADDRESS_WIDTH-1:0] load_address_i,
	input logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] load_data_i,

	// All local Controllers hold their request until this single-port arbiter grants it.
	input logic [QUEUE_COUNT-1:0] request_valid_i,
	output logic [QUEUE_COUNT-1:0] request_ready_o,
	input logic [QUEUE_COUNT*ENTRY_INDEX_WIDTH-1:0] request_index_i,
	input logic [QUEUE_COUNT*GENERATION_WIDTH-1:0] request_generation_i,

	// The response is tagged instead of broadcasting a full data bus to every Queue.
	output logic response_valid_o,
	output logic [QUEUE_ID_WIDTH-1:0] response_queue_o,
	output logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] response_data_o,
	output logic response_error_o,

	output logic fault_o,
	output logic [3:0] fault_code_o
);
	localparam logic [3:0] FAULT_NONE = 4'd0;
	localparam logic [3:0] FAULT_PARTITION = 4'd1;
	localparam logic [3:0] FAULT_PARTITION_OVERLAP = 4'd2;
	localparam logic [3:0] FAULT_LOAD = 4'd3;
	localparam logic [3:0] FAULT_REQUEST = 4'd4;

	logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] record_mem [0:POOL_DEPTH-1];

	// The directory is configuration state; QCTL records exist only in record_mem.
	logic partition_valid_q [0:QUEUE_COUNT-1];
	logic [POOL_ADDRESS_WIDTH-1:0] partition_base_q [0:QUEUE_COUNT-1];
	logic [ENTRY_COUNT_WIDTH-1:0] partition_count_q [0:QUEUE_COUNT-1];
	logic [GENERATION_WIDTH-1:0] partition_generation_q [0:QUEUE_COUNT-1];

	logic [QUEUE_ID_WIDTH-1:0] round_robin_q;
	logic grant_valid_w;
	logic [QUEUE_ID_WIDTH-1:0] grant_queue_w;
	logic [ENTRY_INDEX_WIDTH-1:0] grant_index_w;
	logic [GENERATION_WIDTH-1:0] grant_generation_w;
	logic [POOL_ADDRESS_WIDTH:0] grant_address_w;
	logic grant_error_w;

	logic partition_fire;
	logic partition_invalid_w;
	logic partition_overlap_w;
	logic [POOL_ADDRESS_WIDTH:0] partition_end_w;

	// Stage zero captures the synchronous SRAM read. READ_LATENCY further stages model the configured response latency.
	logic response_pipe_valid_q [0:READ_LATENCY];
	logic [QUEUE_ID_WIDTH-1:0] response_pipe_queue_q [0:READ_LATENCY];
	logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] response_pipe_data_q [0:READ_LATENCY];
	logic response_pipe_error_q [0:READ_LATENCY];

	logic fault_q;
	logic [3:0] fault_code_q;
	logic set_fault_w;
	logic [3:0] set_fault_code_w;

	initial begin
		if(POOL_DEPTH < 1)begin
			$error("POOL_DEPTH must be at least one");
		end
		if(QUEUE_COUNT < 1)begin
			$error("QUEUE_COUNT must be at least one");
		end
		if(QUEUE_ENTRY_LIMIT < 1)begin
			$error("QUEUE_ENTRY_LIMIT must be at least one");
		end
		if(READ_LATENCY < 1)begin
			$error("READ_LATENCY must be at least one");
		end
	end

	assign partition_ready_o = load_mode_i && !fault_q;
	assign partition_fire = partition_valid_i && partition_ready_o;
	assign load_ready_o = load_mode_i && !fault_q;
	assign response_valid_o = response_pipe_valid_q[READ_LATENCY];
	assign response_queue_o = response_pipe_queue_q[READ_LATENCY];
	assign response_data_o = response_pipe_data_q[READ_LATENCY];
	assign response_error_o = response_pipe_error_q[READ_LATENCY];
	assign fault_o = fault_q;
	assign fault_code_o = fault_code_q;

	// Partition validation is outside the runtime read path and may scan the small directory.
	always_comb begin
		partition_end_w = {1'b0, partition_base_i} + partition_count_i;
		partition_invalid_w = (partition_queue_i >= QUEUE_COUNT) || (partition_generation_i == 0) ||
			(partition_count_i > QUEUE_ENTRY_LIMIT) || (partition_end_w > POOL_DEPTH);
		if(partition_queue_i < QUEUE_COUNT)begin
			partition_invalid_w = partition_invalid_w || partition_valid_q[partition_queue_i];
		end
		partition_overlap_w = 1'b0;
		if(partition_count_i != 0)begin
			for(integer queue_index = 0; queue_index < QUEUE_COUNT; queue_index++)begin
				if(partition_valid_q[queue_index] && partition_count_q[queue_index] != 0 &&
					({1'b0, partition_base_i} < ({1'b0, partition_base_q[queue_index]} + partition_count_q[queue_index])) &&
					({1'b0, partition_base_q[queue_index]} < partition_end_w))begin
					partition_overlap_w = 1'b1;
				end
			end
		end
	end

	// Round-robin arbitration grants at most one local Controller in each physical cycle.
	always_comb begin
		request_ready_o = '0;
		grant_valid_w = 1'b0;
		grant_queue_w = '0;
		grant_index_w = '0;
		grant_generation_w = '0;
		if(!load_mode_i && !fault_q)begin
			for(integer request_offset = 0; request_offset < QUEUE_COUNT; request_offset++)begin
				integer candidate_queue;
				candidate_queue = round_robin_q + request_offset;
				if(candidate_queue >= QUEUE_COUNT)begin
					candidate_queue = candidate_queue - QUEUE_COUNT;
				end
				if(!grant_valid_w && request_valid_i[candidate_queue])begin
					grant_valid_w = 1'b1;
					grant_queue_w = candidate_queue[QUEUE_ID_WIDTH-1:0];
					grant_index_w = request_index_i[candidate_queue*ENTRY_INDEX_WIDTH+:ENTRY_INDEX_WIDTH];
					grant_generation_w = request_generation_i[candidate_queue*GENERATION_WIDTH+:GENERATION_WIDTH];
					request_ready_o[candidate_queue] = 1'b1;
				end
			end
		end
	end

	// A stale generation or an index outside its Queue partition returns an explicit error response.
	always_comb begin
		grant_address_w = '0;
		grant_error_w = 1'b0;
		if(grant_valid_w)begin
			grant_error_w = !partition_valid_q[grant_queue_w] ||
				(grant_generation_w != partition_generation_q[grant_queue_w]) ||
				(grant_index_w >= partition_count_q[grant_queue_w]);
			if(!grant_error_w)begin
				grant_address_w = {1'b0, partition_base_q[grant_queue_w]} + grant_index_w;
			end
		end
	end

	// The first detected protocol violation is retained until reset or program clear.
	always_comb begin
		set_fault_w = 1'b0;
		set_fault_code_w = FAULT_NONE;
		if(partition_fire && partition_invalid_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_PARTITION;
		end
		else if(partition_fire && partition_overlap_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_PARTITION_OVERLAP;
		end
		else if(load_valid_i && load_ready_o && load_address_i >= POOL_DEPTH)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_LOAD;
		end
		else if(grant_valid_w && grant_error_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_REQUEST;
		end
	end

	always_ff @(posedge clk_i) begin
		if(load_valid_i && load_ready_o && load_address_i < POOL_DEPTH)begin
			record_mem[load_address_i] <= load_data_i;
		end
	end

	// Partition state is cleared between programs; the record SRAM itself need not be reset.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			for(integer queue_index = 0; queue_index < QUEUE_COUNT; queue_index++)begin
				partition_valid_q[queue_index] <= 1'b0;
				partition_base_q[queue_index] <= '0;
				partition_count_q[queue_index] <= '0;
				partition_generation_q[queue_index] <= '0;
			end
		end
		else if(clear_i)begin
			for(integer queue_index = 0; queue_index < QUEUE_COUNT; queue_index++)begin
				partition_valid_q[queue_index] <= 1'b0;
				partition_base_q[queue_index] <= '0;
				partition_count_q[queue_index] <= '0;
				partition_generation_q[queue_index] <= '0;
			end
		end
		else if(partition_fire && !partition_invalid_w && !partition_overlap_w)begin
			partition_valid_q[partition_queue_i] <= 1'b1;
			partition_base_q[partition_queue_i] <= partition_base_i;
			partition_count_q[partition_queue_i] <= partition_count_i;
			partition_generation_q[partition_queue_i] <= partition_generation_i;
		end
	end

	// The response pipeline preserves request order and the configured two-cycle default latency.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			round_robin_q <= '0;
			for(integer stage = 0; stage <= READ_LATENCY; stage++)begin
				response_pipe_valid_q[stage] <= 1'b0;
				response_pipe_queue_q[stage] <= '0;
				response_pipe_data_q[stage] <= '0;
				response_pipe_error_q[stage] <= 1'b0;
			end
		end
		else if(clear_i)begin
			round_robin_q <= '0;
			for(integer stage = 0; stage <= READ_LATENCY; stage++)begin
				response_pipe_valid_q[stage] <= 1'b0;
				response_pipe_queue_q[stage] <= '0;
				response_pipe_data_q[stage] <= '0;
				response_pipe_error_q[stage] <= 1'b0;
			end
		end
		else begin
			for(integer stage = READ_LATENCY; stage > 0; stage--)begin
				response_pipe_valid_q[stage] <= response_pipe_valid_q[stage-1];
				response_pipe_queue_q[stage] <= response_pipe_queue_q[stage-1];
				response_pipe_data_q[stage] <= response_pipe_data_q[stage-1];
				response_pipe_error_q[stage] <= response_pipe_error_q[stage-1];
			end
			response_pipe_valid_q[0] <= grant_valid_w;
			response_pipe_queue_q[0] <= grant_queue_w;
			response_pipe_data_q[0] <= grant_error_w ? '0 : record_mem[grant_address_w[POOL_ADDRESS_WIDTH-1:0]];
			response_pipe_error_q[0] <= grant_error_w;
			if(grant_valid_w)begin
				if(grant_queue_w == QUEUE_COUNT - 1)begin
					round_robin_q <= '0;
				end
				else begin
					round_robin_q <= grant_queue_w + 1'b1;
				end
			end
		end
	end

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else if(clear_i)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else if(set_fault_w && !fault_q)begin
			fault_q <= 1'b1;
			fault_code_q <= set_fault_code_w;
		end
	end
endmodule
