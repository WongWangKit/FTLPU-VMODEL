// QCTL load manager preserves the external logical Pool-address contract while
// converting accepted partitions and records into explicit Relay packets.
module lpu_qctl_load_manager #(
	parameter integer TOTAL_CAPACITY = 512,
	parameter integer QUEUE_COUNT = lpu_qctl_pkg::QCTL_QUEUE_COUNT,
	parameter integer QUEUE_ENTRY_LIMIT = 16,
	parameter integer GENERATION_WIDTH = 64,
	parameter integer ADDRESS_WIDTH = TOTAL_CAPACITY <= 1 ? 1 : $clog2(TOTAL_CAPACITY),
	parameter integer QUEUE_ID_WIDTH = QUEUE_COUNT <= 1 ? 1 : $clog2(QUEUE_COUNT),
	parameter integer ENTRY_INDEX_WIDTH = QUEUE_ENTRY_LIMIT <= 1 ? 1 : $clog2(QUEUE_ENTRY_LIMIT),
	parameter integer ENTRY_COUNT_WIDTH = $clog2(QUEUE_ENTRY_LIMIT + 1)
) (
	input logic clk_i,
	input logic rst_ni,
	input logic clear_i,
	input logic load_mode_i,

	input logic partition_valid_i,
	output logic partition_ready_o,
	input logic [QUEUE_ID_WIDTH-1:0] partition_queue_i,
	input logic [ADDRESS_WIDTH-1:0] partition_base_i,
	input logic [ENTRY_COUNT_WIDTH-1:0] partition_count_i,
	input logic [GENERATION_WIDTH-1:0] partition_generation_i,

	input logic load_valid_i,
	output logic load_ready_o,
	input logic [ADDRESS_WIDTH-1:0] load_address_i,
	input logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] load_data_i,

	output logic relay_packet_valid_o,
	input logic relay_packet_ready_i,
	output logic relay_packet_kind_o,
	output logic [QUEUE_ID_WIDTH-1:0] relay_packet_queue_o,
	output logic [ENTRY_INDEX_WIDTH-1:0] relay_packet_offset_o,
	output logic [ENTRY_COUNT_WIDTH-1:0] relay_packet_count_o,
	output logic [GENERATION_WIDTH-1:0] relay_packet_generation_o,
	output logic [lpu_qctl_pkg::QCTL_RECORD_WIDTH-1:0] relay_packet_record_o,

	output logic idle_o,
	output logic fault_o,
	output logic [3:0] fault_code_o
);
	localparam logic [3:0] FAULT_NONE = 4'd0;
	localparam logic [3:0] FAULT_PARTITION = 4'd1;
	localparam logic [3:0] FAULT_PARTITION_OVERLAP = 4'd2;
	localparam logic [3:0] FAULT_GLOBAL_CAPACITY = 4'd3;
	localparam logic [3:0] FAULT_LOAD_ADDRESS = 4'd4;
	localparam logic [3:0] FAULT_LOAD_AMBIGUOUS = 4'd5;

	logic directory_valid_q [0:QUEUE_COUNT-1];
	logic [ADDRESS_WIDTH-1:0] directory_base_q [0:QUEUE_COUNT-1];
	logic [ENTRY_COUNT_WIDTH-1:0] directory_count_q [0:QUEUE_COUNT-1];
	logic [GENERATION_WIDTH-1:0] directory_generation_q [0:QUEUE_COUNT-1];
	logic [ADDRESS_WIDTH:0] allocated_count_q;

	logic partition_fire_w;
	logic load_fire_w;
	logic partition_invalid_w;
	logic partition_overlap_w;
	logic partition_capacity_error_w;
	logic [ADDRESS_WIDTH:0] partition_end_w;
	logic [ADDRESS_WIDTH:0] allocated_count_next_w;
	logic load_owner_found_w;
	logic load_owner_multiple_w;
	logic [QUEUE_ID_WIDTH-1:0] load_owner_queue_w;
	logic [ENTRY_INDEX_WIDTH-1:0] load_owner_offset_w;
	logic partition_selected_w;
	logic load_selected_w;
	logic set_fault_w;
	logic [3:0] set_fault_code_w;
	logic fault_q;
	logic [3:0] fault_code_q;

	initial begin
		if(TOTAL_CAPACITY < 1 || QUEUE_COUNT < 1 || QUEUE_ENTRY_LIMIT < 1)begin
			$error("QCTL Load Manager parameters must be positive");
		end
	end

	assign partition_end_w = {1'b0, partition_base_i} + partition_count_i;
	assign allocated_count_next_w = allocated_count_q + partition_count_i;
	assign partition_selected_w = partition_valid_i;
	assign load_selected_w = !partition_valid_i && load_valid_i;
	assign partition_ready_o = load_mode_i && !fault_q &&
		(partition_invalid_w || partition_overlap_w || partition_capacity_error_w ||
		 relay_packet_ready_i);
	assign load_ready_o = load_mode_i && !fault_q && !partition_valid_i &&
		((!load_owner_found_w || load_owner_multiple_w) || relay_packet_ready_i);
	assign partition_fire_w = partition_valid_i && partition_ready_o;
	assign load_fire_w = load_valid_i && load_ready_o;
	assign idle_o = !partition_valid_i && !load_valid_i && !relay_packet_valid_o;
	assign fault_o = fault_q;
	assign fault_code_o = fault_code_q;

	// Validate queue ownership, generation, entry count and logical address range.
	always_comb begin
		partition_invalid_w = (partition_queue_i >= QUEUE_COUNT) ||
			(partition_generation_i == 0) ||
			(partition_count_i > QUEUE_ENTRY_LIMIT) ||
			(partition_end_w > TOTAL_CAPACITY);
		if(partition_queue_i < QUEUE_COUNT)begin
			partition_invalid_w = partition_invalid_w || directory_valid_q[partition_queue_i];
		end
	end

	// Reject overlapping logical address ranges even though records are stored regionally.
	always_comb begin
		partition_overlap_w = 1'b0;
		if(partition_count_i != 0)begin
			for(integer queue_index = 0; queue_index < QUEUE_COUNT; queue_index++)begin
				if(directory_valid_q[queue_index] && (directory_count_q[queue_index] != 0) &&
					({1'b0, partition_base_i} <
					 ({1'b0, directory_base_q[queue_index]} + directory_count_q[queue_index])) &&
					({1'b0, directory_base_q[queue_index]} < partition_end_w))begin
					partition_overlap_w = 1'b1;
				end
			end
		end
	end

	// Enforce the global 512-entry logical capacity independently of regional limits.
	always_comb begin
		partition_capacity_error_w = allocated_count_next_w > TOTAL_CAPACITY;
	end

	// Resolve a legacy physical load address to exactly one configured Queue and Offset.
	always_comb begin
		load_owner_found_w = 1'b0;
		load_owner_multiple_w = 1'b0;
		load_owner_queue_w = '0;
		load_owner_offset_w = '0;
		for(integer queue_index = 0; queue_index < QUEUE_COUNT; queue_index++)begin
			if(directory_valid_q[queue_index] &&
				({1'b0, load_address_i} >= {1'b0, directory_base_q[queue_index]}) &&
				({1'b0, load_address_i} <
				 ({1'b0, directory_base_q[queue_index]} + directory_count_q[queue_index])))begin
				if(load_owner_found_w)begin
					load_owner_multiple_w = 1'b1;
				end
				else begin
					load_owner_found_w = 1'b1;
					load_owner_queue_w = queue_index[QUEUE_ID_WIDTH-1:0];
					load_owner_offset_w = load_address_i - directory_base_q[queue_index];
				end
			end
		end
	end

	// Partition packets have priority so their directory commit always precedes records.
	always_comb begin
		relay_packet_valid_o = 1'b0;
		relay_packet_kind_o = lpu_qctl_pkg::QCTL_RELAY_PARTITION;
		relay_packet_queue_o = '0;
		relay_packet_offset_o = '0;
		relay_packet_count_o = '0;
		relay_packet_generation_o = '0;
		relay_packet_record_o = '0;
		if(load_mode_i && !fault_q && partition_selected_w &&
			!partition_invalid_w && !partition_overlap_w && !partition_capacity_error_w)begin
			relay_packet_valid_o = partition_valid_i;
			relay_packet_kind_o = lpu_qctl_pkg::QCTL_RELAY_PARTITION;
			relay_packet_queue_o = partition_queue_i;
			relay_packet_count_o = partition_count_i;
			relay_packet_generation_o = partition_generation_i;
		end
		else if(load_mode_i && !fault_q && load_selected_w &&
			load_owner_found_w && !load_owner_multiple_w)begin
			relay_packet_valid_o = load_valid_i;
			relay_packet_kind_o = lpu_qctl_pkg::QCTL_RELAY_RECORD;
			relay_packet_queue_o = load_owner_queue_w;
			relay_packet_offset_o = load_owner_offset_w;
			relay_packet_generation_o = directory_generation_q[load_owner_queue_w];
			relay_packet_record_o = load_data_i;
		end
	end

	// Retain the first load-contract violation; an invalid transfer is consumed once.
	always_comb begin
		set_fault_w = 1'b0;
		set_fault_code_w = FAULT_NONE;
		if(partition_fire_w && partition_invalid_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_PARTITION;
		end
		else if(partition_fire_w && partition_overlap_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_PARTITION_OVERLAP;
		end
		else if(partition_fire_w && partition_capacity_error_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_GLOBAL_CAPACITY;
		end
		else if(load_fire_w && !load_owner_found_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_LOAD_ADDRESS;
		end
		else if(load_fire_w && load_owner_multiple_w)begin
			set_fault_w = 1'b1;
			set_fault_code_w = FAULT_LOAD_AMBIGUOUS;
		end
	end

	// Store only logical partition metadata; QCTL Records never reside here.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			allocated_count_q <= '0;
			for(integer queue_index = 0; queue_index < QUEUE_COUNT; queue_index++)begin
				directory_valid_q[queue_index] <= 1'b0;
				directory_base_q[queue_index] <= '0;
				directory_count_q[queue_index] <= '0;
				directory_generation_q[queue_index] <= '0;
			end
		end
		else if(clear_i)begin
			allocated_count_q <= '0;
			for(integer queue_index = 0; queue_index < QUEUE_COUNT; queue_index++)begin
				directory_valid_q[queue_index] <= 1'b0;
				directory_base_q[queue_index] <= '0;
				directory_count_q[queue_index] <= '0;
				directory_generation_q[queue_index] <= '0;
			end
		end
		else if(partition_fire_w && !partition_invalid_w &&
			!partition_overlap_w && !partition_capacity_error_w)begin
			directory_valid_q[partition_queue_i] <= 1'b1;
			directory_base_q[partition_queue_i] <= partition_base_i;
			directory_count_q[partition_queue_i] <= partition_count_i;
			directory_generation_q[partition_queue_i] <= partition_generation_i;
			allocated_count_q <= allocated_count_next_w;
		end
	end

	// Load-manager faults clear only with reset or Program Clear.
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
