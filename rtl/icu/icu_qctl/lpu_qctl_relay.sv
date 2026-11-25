// One physical QCTL Relay stage. Non-local packets cross a registered Transit
// FIFO; local partitions and records terminate in the shared regional store.
module lpu_qctl_relay #(
	parameter integer HEMISPHERE_ID = 0,
	parameter integer RELAY_INDEX = 0,
	parameter bit LAST_RELAY = 1'b0,
	parameter integer QUEUE_COUNT = lpu_qctl_pkg::QCTL_QUEUE_COUNT,
	parameter integer LOCAL_QUEUE_COUNT = 18,
	parameter integer REGION_DEPTH = 64,
	parameter integer BUFFER_DEPTH = 2,
	parameter integer QUEUE_ENTRY_LIMIT = 16,
	parameter integer GENERATION_WIDTH = 64,
	parameter integer QUEUE_ID_WIDTH = QUEUE_COUNT <= 1 ? 1 : $clog2(QUEUE_COUNT),
	parameter integer ENTRY_INDEX_WIDTH = QUEUE_ENTRY_LIMIT <= 1 ? 1 : $clog2(QUEUE_ENTRY_LIMIT),
	parameter integer ENTRY_COUNT_WIDTH = $clog2(QUEUE_ENTRY_LIMIT + 1),
	parameter integer LOCAL_ADDR_WIDTH = REGION_DEPTH <= 1 ? 1 : $clog2(REGION_DEPTH),
	parameter integer FIFO_PTR_WIDTH = BUFFER_DEPTH <= 1 ? 1 : $clog2(BUFFER_DEPTH),
	parameter integer FIFO_LEVEL_WIDTH = $clog2(BUFFER_DEPTH + 1)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic clear_i,

	input logic chain_packet_valid_i,
	output logic chain_packet_ready_o,
	input logic chain_packet_kind_i,
	input logic [QUEUE_ID_WIDTH-1:0] chain_packet_queue_i,
	input logic [ENTRY_INDEX_WIDTH-1:0] chain_packet_offset_i,
	input logic [ENTRY_COUNT_WIDTH-1:0] chain_packet_count_i,
	input logic [GENERATION_WIDTH-1:0] chain_packet_generation_i,
	input logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] chain_packet_record_i,

	output logic next_packet_valid_o,
	input logic next_packet_ready_i,
	output logic next_packet_kind_o,
	output logic [QUEUE_ID_WIDTH-1:0] next_packet_queue_o,
	output logic [ENTRY_INDEX_WIDTH-1:0] next_packet_offset_o,
	output logic [ENTRY_COUNT_WIDTH-1:0] next_packet_count_o,
	output logic [GENERATION_WIDTH-1:0] next_packet_generation_o,
	output logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] next_packet_record_o,

	input logic [QUEUE_COUNT*ENTRY_INDEX_WIDTH-1:0] queue_head_index_i,
	input logic [QUEUE_COUNT*GENERATION_WIDTH-1:0] queue_head_generation_i,
	output logic [QUEUE_COUNT-1:0] queue_configured_o,
	output logic [QUEUE_COUNT-1:0] queue_loaded_o,
	output logic [QUEUE_COUNT-1:0] queue_head_valid_o,
	output logic [QUEUE_COUNT*lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] queue_head_record_o,
	output logic [QUEUE_COUNT-1:0] queue_head_error_o,

	output logic [QUEUE_COUNT-1:0] configure_valid_o,
	output logic [QUEUE_COUNT*ENTRY_COUNT_WIDTH-1:0] configure_count_o,
	output logic [QUEUE_COUNT*GENERATION_WIDTH-1:0] configure_generation_o,

	output logic idle_o,
	output logic fault_o,
	output logic [3:0] fault_code_o
);
	localparam logic [3:0] FAULT_NONE = 4'd0;
	localparam logic [3:0] FAULT_PARTITION = 4'd1;
	localparam logic [3:0] FAULT_REGION_CAPACITY = 4'd2;
	localparam logic [3:0] FAULT_RECORD_QUEUE = 4'd3;
	localparam logic [3:0] FAULT_RECORD_GENERATION = 4'd4;
	localparam logic [3:0] FAULT_RECORD_OFFSET = 4'd5;
	localparam logic [3:0] FAULT_RECORD_DUPLICATE = 4'd6;
	localparam logic [3:0] FAULT_ROUTE = 4'd7;

	logic directory_valid_q [0:LOCAL_QUEUE_COUNT-1];
	logic [LOCAL_ADDR_WIDTH-1:0] directory_base_q [0:LOCAL_QUEUE_COUNT-1];
	logic [ENTRY_COUNT_WIDTH-1:0] directory_count_q [0:LOCAL_QUEUE_COUNT-1];
	logic [GENERATION_WIDTH-1:0] directory_generation_q [0:LOCAL_QUEUE_COUNT-1];
	logic [LOCAL_ADDR_WIDTH:0] used_entries_q;
	logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] qctl_record_mem [0:REGION_DEPTH-1];
	logic [REGION_DEPTH-1:0] record_valid_q;

	logic fifo_kind_q [0:BUFFER_DEPTH-1];
	logic [QUEUE_ID_WIDTH-1:0] fifo_queue_q [0:BUFFER_DEPTH-1];
	logic [ENTRY_INDEX_WIDTH-1:0] fifo_offset_q [0:BUFFER_DEPTH-1];
	logic [ENTRY_COUNT_WIDTH-1:0] fifo_count_q [0:BUFFER_DEPTH-1];
	logic [GENERATION_WIDTH-1:0] fifo_generation_q [0:BUFFER_DEPTH-1];
	logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] fifo_record_q [0:BUFFER_DEPTH-1];
	logic [FIFO_PTR_WIDTH-1:0] fifo_write_ptr_q;
	logic [FIFO_PTR_WIDTH-1:0] fifo_read_ptr_q;
	logic [FIFO_LEVEL_WIDTH-1:0] fifo_level_q;

	logic queue_valid_w;
	logic local_target_w;
	logic [lpu_qctl_pkg::QCTL_LOCAL_QUEUE_ID_WIDTH-1:0] local_queue_w;
	logic input_fire_w;
	logic local_fire_w;
	logic forward_enqueue_w;
	logic forward_dequeue_w;
	logic partition_fire_w;
	logic record_fire_w;
	logic partition_invalid_w;
	logic region_capacity_error_w;
	logic record_queue_error_w;
	logic record_generation_error_w;
	logic record_offset_error_w;
	logic record_duplicate_error_w;
	logic [LOCAL_ADDR_WIDTH:0] partition_end_w;
	logic [LOCAL_ADDR_WIDTH:0] record_address_w;
	logic set_fault_w;
	logic [3:0] set_fault_code_w;
	logic fault_q;
	logic [3:0] fault_code_q;

	initial begin
		if(LOCAL_QUEUE_COUNT < 1 || REGION_DEPTH < 1 || BUFFER_DEPTH < 1)begin
			$error("QCTL Relay storage and buffering parameters must be positive");
		end
		if(RELAY_INDEX < 0 || RELAY_INDEX >= lpu_qctl_pkg::QCTL_RELAY_COUNT_PER_HEMISPHERE)begin
			$error("QCTL Relay index is outside the Program Distribution topology");
		end
	end

	assign queue_valid_w = lpu_qctl_pkg::qctl_queue_valid(chain_packet_queue_i);
	assign local_target_w = queue_valid_w &&
		(lpu_qctl_pkg::qctl_queue_hemisphere(chain_packet_queue_i) == HEMISPHERE_ID) &&
		(lpu_qctl_pkg::qctl_queue_relay_index(chain_packet_queue_i) == RELAY_INDEX);
	assign local_queue_w = lpu_qctl_pkg::qctl_queue_local_index(chain_packet_queue_i);
	assign chain_packet_ready_o = !fault_q &&
		(local_target_w || LAST_RELAY || (fifo_level_q < BUFFER_DEPTH));
	assign input_fire_w = chain_packet_valid_i && chain_packet_ready_o;
	assign local_fire_w = input_fire_w && local_target_w;
	assign forward_enqueue_w = input_fire_w && !local_target_w && !LAST_RELAY;
	assign forward_dequeue_w = next_packet_valid_o && next_packet_ready_i;
	assign partition_fire_w = local_fire_w &&
		(chain_packet_kind_i == lpu_qctl_pkg::QCTL_RELAY_PARTITION);
	assign record_fire_w = local_fire_w &&
		(chain_packet_kind_i == lpu_qctl_pkg::QCTL_RELAY_RECORD);
	assign partition_end_w = used_entries_q + chain_packet_count_i;
	assign record_address_w = {1'b0, directory_base_q[local_queue_w]} + chain_packet_offset_i;
	assign next_packet_valid_o = fifo_level_q != 0;
	assign next_packet_kind_o = fifo_kind_q[fifo_read_ptr_q];
	assign next_packet_queue_o = fifo_queue_q[fifo_read_ptr_q];
	assign next_packet_offset_o = fifo_offset_q[fifo_read_ptr_q];
	assign next_packet_count_o = fifo_count_q[fifo_read_ptr_q];
	assign next_packet_generation_o = fifo_generation_q[fifo_read_ptr_q];
	assign next_packet_record_o = fifo_record_q[fifo_read_ptr_q];
	assign idle_o = (fifo_level_q == 0) && !chain_packet_valid_i;
	assign fault_o = fault_q;
	assign fault_code_o = fault_code_q;

	// Partition validation protects fixed Queue ownership and regional capacity.
	always_comb begin
		partition_invalid_w = (local_queue_w >= LOCAL_QUEUE_COUNT) ||
			(chain_packet_generation_i == 0) ||
			(chain_packet_count_i > QUEUE_ENTRY_LIMIT);
		if(local_queue_w < LOCAL_QUEUE_COUNT)begin
			partition_invalid_w = partition_invalid_w || directory_valid_q[local_queue_w];
		end
		region_capacity_error_w = partition_end_w > REGION_DEPTH;
	end

	// Record validation rejects stale, out-of-range and duplicate Queue offsets.
	always_comb begin
		record_queue_error_w = local_queue_w >= LOCAL_QUEUE_COUNT;
		record_generation_error_w = 1'b0;
		record_offset_error_w = 1'b0;
		record_duplicate_error_w = 1'b0;
		if(local_queue_w < LOCAL_QUEUE_COUNT)begin
			record_queue_error_w = !directory_valid_q[local_queue_w];
			if(directory_valid_q[local_queue_w])begin
				record_generation_error_w =
					chain_packet_generation_i != directory_generation_q[local_queue_w];
				record_offset_error_w = (chain_packet_offset_i >= directory_count_q[local_queue_w]) ||
					(record_address_w >= REGION_DEPTH);
				if(!record_offset_error_w)begin
					record_duplicate_error_w = record_valid_q[record_address_w[LOCAL_ADDR_WIDTH-1:0]];
				end
			end
		end
	end

	// A partition commit configures exactly one matching FU-local Queue endpoint.
	always_comb begin
		configure_valid_o = '0;
		configure_count_o = '0;
		configure_generation_o = '0;
		if(partition_fire_w && !partition_invalid_w && !region_capacity_error_w)begin
			configure_valid_o[chain_packet_queue_i] = 1'b1;
			configure_count_o[chain_packet_queue_i*ENTRY_COUNT_WIDTH+:ENTRY_COUNT_WIDTH] =
				chain_packet_count_i;
			configure_generation_o[chain_packet_queue_i*GENERATION_WIDTH+:GENERATION_WIDTH] =
				chain_packet_generation_i;
		end
	end

	// Independent combinational read ports validate configuration, bounds, generation and data freshness.
	always_comb begin
		queue_configured_o = '0;
		queue_loaded_o = '0;
		queue_head_valid_o = '0;
		queue_head_record_o = '0;
		queue_head_error_o = '0;
		for(integer queue_index = 0; queue_index < QUEUE_COUNT; queue_index++)begin
			integer local_index;
			integer head_index;
			integer physical_address;
			logic all_records_valid;
			if(lpu_qctl_pkg::qctl_queue_valid(queue_index[QUEUE_ID_WIDTH-1:0]) &&
				(lpu_qctl_pkg::qctl_queue_hemisphere(queue_index[QUEUE_ID_WIDTH-1:0]) == HEMISPHERE_ID) &&
				(lpu_qctl_pkg::qctl_queue_relay_index(queue_index[QUEUE_ID_WIDTH-1:0]) == RELAY_INDEX))begin
				local_index = lpu_qctl_pkg::qctl_queue_local_index(queue_index[QUEUE_ID_WIDTH-1:0]);
				if(local_index < LOCAL_QUEUE_COUNT && directory_valid_q[local_index])begin
					queue_configured_o[queue_index] = 1'b1;
					all_records_valid = 1'b1;
					for(integer entry_index = 0; entry_index < QUEUE_ENTRY_LIMIT; entry_index++)begin
						if(entry_index < directory_count_q[local_index])begin
							physical_address = directory_base_q[local_index] + entry_index;
							if(physical_address >= REGION_DEPTH)begin
								all_records_valid = 1'b0;
							end
							else if(!record_valid_q[physical_address])begin
								all_records_valid = 1'b0;
							end
						end
					end
					queue_loaded_o[queue_index] = all_records_valid;
					head_index = queue_head_index_i[queue_index*ENTRY_INDEX_WIDTH+:ENTRY_INDEX_WIDTH];
					physical_address = directory_base_q[local_index] + head_index;
					queue_head_error_o[queue_index] =
						(queue_head_generation_i[queue_index*GENERATION_WIDTH+:GENERATION_WIDTH] !=
						 directory_generation_q[local_index]) ||
						(head_index >= directory_count_q[local_index]) ||
						(physical_address >= REGION_DEPTH);
					if((directory_count_q[local_index] != 0) && !queue_head_error_o[queue_index])begin
						queue_head_error_o[queue_index] = !record_valid_q[physical_address];
						if(record_valid_q[physical_address])begin
							queue_head_valid_o[queue_index] = 1'b1;
							queue_head_record_o[queue_index*lpu_qctl_pkg::QCTL_RECORD_WIDTH+:
								lpu_qctl_pkg::QCTL_RECORD_WIDTH] = qctl_record_mem[physical_address];
						end
					end
				end
			end
		end
	end

	// Select a precise sticky fault for route, partition or Record contract violations.
	always_comb begin
		set_fault_w = 1'b0;
		set_fault_code_w = FAULT_NONE;
		if(input_fire_w && !local_target_w && LAST_RELAY)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_ROUTE;
		end
		else if(partition_fire_w && partition_invalid_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_PARTITION;
		end
		else if(partition_fire_w && region_capacity_error_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_REGION_CAPACITY;
		end
		else if(record_fire_w && record_queue_error_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_RECORD_QUEUE;
		end
		else if(record_fire_w && record_generation_error_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_RECORD_GENERATION;
		end
		else if(record_fire_w && record_offset_error_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_RECORD_OFFSET;
		end
		else if(record_fire_w && record_duplicate_error_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_RECORD_DUPLICATE;
		end
	end

	// Successful partition commits allocate contiguous local addresses without touching Record storage.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			used_entries_q <= '0;
			for(integer local_index = 0; local_index < LOCAL_QUEUE_COUNT; local_index++)begin
				directory_valid_q[local_index] <= 1'b0;
				directory_base_q[local_index] <= '0;
				directory_count_q[local_index] <= '0;
				directory_generation_q[local_index] <= '0;
			end
		end
		else if(clear_i)begin
			used_entries_q <= '0;
			for(integer local_index = 0; local_index < LOCAL_QUEUE_COUNT; local_index++)begin
				directory_valid_q[local_index] <= 1'b0;
				directory_base_q[local_index] <= '0;
				directory_count_q[local_index] <= '0;
				directory_generation_q[local_index] <= '0;
			end
		end
		else if(partition_fire_w && !partition_invalid_w && !region_capacity_error_w)begin
			directory_valid_q[local_queue_w] <= 1'b1;
			directory_base_q[local_queue_w] <= used_entries_q[LOCAL_ADDR_WIDTH-1:0];
			directory_count_q[local_queue_w] <= chain_packet_count_i;
			directory_generation_q[local_queue_w] <= chain_packet_generation_i;
			used_entries_q <= partition_end_w;
		end
	end

	// Only a legal, handshaken Record write updates storage and its validity bit.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			record_valid_q <= '0;
		end
		else if(clear_i)begin
			record_valid_q <= '0;
		end
		else if(record_fire_w && !record_queue_error_w && !record_generation_error_w &&
			!record_offset_error_w && !record_duplicate_error_w)begin
			qctl_record_mem[record_address_w[LOCAL_ADDR_WIDTH-1:0]] <= chain_packet_record_i;
			record_valid_q[record_address_w[LOCAL_ADDR_WIDTH-1:0]] <= 1'b1;
		end
	end

	// Transit FIFO registers every non-local packet and preserves backpressure ordering.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fifo_write_ptr_q <= '0;
			fifo_read_ptr_q <= '0;
			fifo_level_q <= '0;
		end
		else if(clear_i)begin
			fifo_write_ptr_q <= '0;
			fifo_read_ptr_q <= '0;
			fifo_level_q <= '0;
		end
		else begin
			if(forward_enqueue_w)begin
				fifo_kind_q[fifo_write_ptr_q] <= chain_packet_kind_i;
				fifo_queue_q[fifo_write_ptr_q] <= chain_packet_queue_i;
				fifo_offset_q[fifo_write_ptr_q] <= chain_packet_offset_i;
				fifo_count_q[fifo_write_ptr_q] <= chain_packet_count_i;
				fifo_generation_q[fifo_write_ptr_q] <= chain_packet_generation_i;
				fifo_record_q[fifo_write_ptr_q] <= chain_packet_record_i;
				fifo_write_ptr_q <= fifo_write_ptr_q == BUFFER_DEPTH - 1 ?
					'0 : fifo_write_ptr_q + 1'b1;
			end
			if(forward_dequeue_w)begin
				fifo_read_ptr_q <= fifo_read_ptr_q == BUFFER_DEPTH - 1 ?
					'0 : fifo_read_ptr_q + 1'b1;
			end
			case({forward_enqueue_w, forward_dequeue_w})
				2'b10: fifo_level_q <= fifo_level_q + 1'b1;
				2'b01: fifo_level_q <= fifo_level_q - 1'b1;
				default: fifo_level_q <= fifo_level_q;
			endcase
		end
	end

	// Relay faults are sticky until Program Clear because continuing could corrupt ownership.
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
