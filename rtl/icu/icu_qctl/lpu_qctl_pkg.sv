package lpu_qctl_pkg;
	localparam integer QCTL_RECORD_WIDTH = 96;
	localparam integer QCTL_CYCLE_WIDTH = 32;
	localparam integer QCTL_OPCODE_WIDTH = 4;
	localparam integer QCTL_OPERAND_WIDTH = 32;
	localparam integer QCTL_QUEUE_COUNT = 228;
	localparam integer QCTL_MEM_QUEUE_COUNT = 208;
	localparam integer QCTL_MEM_QUEUES_PER_HEMISPHERE = 104;
	localparam integer QCTL_RELAY_COUNT_PER_HEMISPHERE = 7;
	localparam integer QCTL_RELAY_COUNT = 14;
	localparam integer QCTL_MEM_QUEUES_PER_RELAY = 16;
	localparam integer QCTL_MXM_LOAD_BASE = 208;
	localparam integer QCTL_MXM_DEQUANT_BASE = 212;
	localparam integer QCTL_MXM_COMPUTE_BASE = 216;
	localparam integer QCTL_MXM_PARAM_LOAD_BASE = 220;
	localparam integer QCTL_MXM_BACKEND_BASE = 224;
	localparam integer QCTL_QUEUE_ID_WIDTH = 8;
	localparam integer QCTL_RELAY_ID_WIDTH = 4;
	localparam integer QCTL_LOCAL_QUEUE_ID_WIDTH = 5;

	// Runtime messages remain independent from the load-time Record Relay path.
	typedef enum logic [3:0] {
		QCTL_MSG_EVENT = 4'd0,
		QCTL_MSG_SYNC_ARRIVE = 4'd1,
		QCTL_MSG_NOTIFY_REQ = 4'd2,
		QCTL_MSG_SYNC_RELEASE = 4'd3,
		QCTL_MSG_MEM_PACKET = 4'd4
	} lpu_qctl_msg_type_e;

	typedef enum logic {
		QCTL_RELAY_PARTITION = 1'b0,
		QCTL_RELAY_RECORD = 1'b1
	} lpu_qctl_relay_kind_e;

	typedef enum logic [QCTL_OPCODE_WIDTH-1:0] {
		QCTL_OPCODE_SYNC = 4'd3,
		QCTL_OPCODE_NOTIFY = 4'd4,
		QCTL_OPCODE_WAIT_EVENT = 4'd7,
		QCTL_OPCODE_MEM_PACKET = 4'd8
	} lpu_qctl_opcode_e;

	function automatic logic [QCTL_RECORD_WIDTH-1:0] qctl_pack_record(
		input logic [QCTL_CYCLE_WIDTH-1:0] cycle,
		input logic [QCTL_OPCODE_WIDTH-1:0] opcode,
		input logic [QCTL_OPERAND_WIDTH-1:0] operand
	);
		qctl_pack_record = {operand, 28'd0, opcode, cycle};
	endfunction

	function automatic logic [QCTL_CYCLE_WIDTH-1:0] qctl_record_cycle(input logic [QCTL_RECORD_WIDTH-1:0] record);
		qctl_record_cycle = record[31:0];
	endfunction

	function automatic logic [QCTL_OPCODE_WIDTH-1:0] qctl_record_opcode(input logic [QCTL_RECORD_WIDTH-1:0] record);
		qctl_record_opcode = record[35:32];
	endfunction

	function automatic logic [QCTL_OPERAND_WIDTH-1:0] qctl_record_operand(input logic [QCTL_RECORD_WIDTH-1:0] record);
		qctl_record_operand = record[95:64];
	endfunction

	// Queue IDs 0..207 are MEM Banks; the five four-entry MXM ranges follow.
	function automatic logic qctl_queue_valid(input logic [QCTL_QUEUE_ID_WIDTH-1:0] queue_id);
		qctl_queue_valid = queue_id < QCTL_QUEUE_COUNT;
	endfunction

	// Queue ownership follows the Program Distribution East/West split.
	function automatic logic qctl_queue_hemisphere(input logic [QCTL_QUEUE_ID_WIDTH-1:0] queue_id);
		integer mxm_index;
		begin
			if(queue_id < QCTL_MEM_QUEUE_COUNT)begin
				qctl_queue_hemisphere = queue_id >= QCTL_MEM_QUEUES_PER_HEMISPHERE;
			end
			else begin
				if(queue_id < QCTL_MXM_DEQUANT_BASE)begin
					mxm_index = queue_id - QCTL_MXM_LOAD_BASE;
				end
				else if(queue_id < QCTL_MXM_COMPUTE_BASE)begin
					mxm_index = queue_id - QCTL_MXM_DEQUANT_BASE;
				end
				else if(queue_id < QCTL_MXM_PARAM_LOAD_BASE)begin
					mxm_index = queue_id - QCTL_MXM_COMPUTE_BASE;
				end
				else if(queue_id < QCTL_MXM_BACKEND_BASE)begin
					mxm_index = queue_id - QCTL_MXM_PARAM_LOAD_BASE;
				end
				else begin
					mxm_index = queue_id - QCTL_MXM_BACKEND_BASE;
				end
				qctl_queue_hemisphere = mxm_index >= 2;
			end
		end
	endfunction

	// Every Hemisphere uses the same seven-stage Relay order as Program Distribution.
	function automatic logic [2:0] qctl_queue_relay_index(input logic [QCTL_QUEUE_ID_WIDTH-1:0] queue_id);
		integer local_mem_queue;
		begin
			if(queue_id < QCTL_MEM_QUEUE_COUNT)begin
				local_mem_queue = queue_id % QCTL_MEM_QUEUES_PER_HEMISPHERE;
				qctl_queue_relay_index = local_mem_queue / QCTL_MEM_QUEUES_PER_RELAY;
			end
			else begin
				qctl_queue_relay_index = QCTL_RELAY_COUNT_PER_HEMISPHERE - 1;
			end
		end
	endfunction

	// R0..R5 own sixteen MEM Queues; R6 owns eight MEM Queues and ten MXM streams.
	function automatic logic [QCTL_LOCAL_QUEUE_ID_WIDTH-1:0] qctl_queue_local_index(
		input logic [QCTL_QUEUE_ID_WIDTH-1:0] queue_id
	);
		integer local_mem_queue;
		integer mxm_index;
		integer stream_index;
		begin
			if(queue_id < QCTL_MEM_QUEUE_COUNT)begin
				local_mem_queue = queue_id % QCTL_MEM_QUEUES_PER_HEMISPHERE;
				qctl_queue_local_index = local_mem_queue % QCTL_MEM_QUEUES_PER_RELAY;
			end
			else begin
				if(queue_id < QCTL_MXM_DEQUANT_BASE)begin
					mxm_index = queue_id - QCTL_MXM_LOAD_BASE;
					stream_index = 0;
				end
				else if(queue_id < QCTL_MXM_COMPUTE_BASE)begin
					mxm_index = queue_id - QCTL_MXM_DEQUANT_BASE;
					stream_index = 1;
				end
				else if(queue_id < QCTL_MXM_PARAM_LOAD_BASE)begin
					mxm_index = queue_id - QCTL_MXM_COMPUTE_BASE;
					stream_index = 2;
				end
				else if(queue_id < QCTL_MXM_BACKEND_BASE)begin
					mxm_index = queue_id - QCTL_MXM_PARAM_LOAD_BASE;
					stream_index = 3;
				end
				else begin
					mxm_index = queue_id - QCTL_MXM_BACKEND_BASE;
					stream_index = 4;
				end
				qctl_queue_local_index = 8 + (mxm_index % 2) * 5 + stream_index;
			end
		end
	endfunction
endpackage
