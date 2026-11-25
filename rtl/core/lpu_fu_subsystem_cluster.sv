module lpu_fu_subsystem_cluster #(
	parameter integer PACKED_MEM_ROW_BITS = 13,
	parameter integer DMA_TILES=4,
	localparam integer ACTIVE_MXMS=lpu_pkg::mxms_per_hemisphere(DMA_TILES),
	parameter integer MEM_IMEM_DEPTH = 131072,
	parameter integer MXM_IMEM_DEPTH = 65536,
	parameter integer ACTIVE_CONTEXTS = 4,
	parameter integer MEM_DEPTH_ROWS = lpu_pkg::SRAM_DEPTH_ROWS,
	parameter integer ACTIVE_MEM_COLUMNS = 52,
	parameter integer MXM_ACCUMULATOR_BLOCK_COUNT = lpu_pkg::MXM_ACCUMULATOR_BLOCK_COUNT,
	parameter bit LEGACY_MXM=0, LEGACY_VECTOR_ARRAY=1,
	parameter bit ENABLE_QCTL = 1'b0,
	parameter bit ENABLE_SXM_VXM_EXECUTION = 1'b1,
	parameter integer QCTL_QUEUE_COUNT = 220,
	parameter integer QCTL_POOL_DEPTH = 512,
	parameter integer QCTL_QUEUE_ENTRY_LIMIT = 16,
	parameter integer QCTL_CACHE_DEPTH = 4
) (
	input logic clk_i,
	input logic rst_ni,
	input logic dma_req_i,dma_write_i,dma_hem_i,input logic [6:0] dma_bank_i,input logic [4:0] dma_stream_i,
	input logic [14:0] dma_row_i,input logic [DMA_TILES*64-1:0] dma_wdata_i,
	output logic dma_ready_o,dma_ret_o,dma_err_o,output logic [DMA_TILES*64-1:0] dma_rdata_o,
	input logic program_reset_i,
	input logic discard_partial_sums_i,
	input logic segment_retired_i,
	input logic [1:0] endpoint_load_valid_i,
	output logic [1:0] endpoint_load_ready_o,
	input logic [5:0] endpoint_load_control_i,
	input logic [255:0] endpoint_load_data_i,
	input logic [7:0] endpoint_load_strb_i,
	input logic [7:0] endpoint_load_target_kind_i,
	input logic [15:0] endpoint_load_queue_id_i,
	input logic [33:0] endpoint_load_imem_address_i,
	input logic [1:0] endpoint_load_last_i,
	output logic [1:0] endpoint_commit_valid_o,
	input logic [1:0] endpoint_commit_ready_i,
	output logic [1:0] endpoint_commit_error_o,

	input logic program_start_i,
	output logic program_start_ready_o,
	output logic started_o,
	output logic all_frontends_ready_o,
	output logic all_frontends_idle_o,
	output logic execution_drained_o,
	output logic [31:0] schedule_cycle_o,
	output logic frontend_fault_o,
	output logic [5:0] frontend_fault_code_o,

	// QCTL has 208 MEM Bank lanes followed by four MXM Load, four Dequant and
	// four Compute lanes. VXM/SXM Queue IDs remain reserved for later closure.
	input logic qctl_load_mode_i,
	input logic qctl_partition_valid_i,
	output logic qctl_partition_ready_o,
	input logic [$clog2(QCTL_QUEUE_COUNT)-1:0] qctl_partition_queue_i,
	input logic [8:0] qctl_partition_base_i,
	input logic [4:0] qctl_partition_count_i,
	input logic [63:0] qctl_partition_generation_i,
	input logic qctl_load_valid_i,
	output logic qctl_load_ready_o,
	input logic [8:0] qctl_load_address_i,
	input logic [95:0] qctl_load_data_i,
	input logic qctl_event_valid_i,
	output logic qctl_event_ready_o,
	input logic [31:0] qctl_event_tag_i,
	input logic [QCTL_QUEUE_COUNT-1:0] qctl_event_mask_i,
	input logic [64-1:0] qctl_event_generation_i,
	input logic qctl_event_phase_i,
	output logic qctl_receipt_valid_o,
	input logic qctl_receipt_ready_i,
	output logic [31:0] qctl_receipt_tag_o,
	output logic [64-1:0] qctl_receipt_generation_o,
	output logic [63:0] qctl_receipt_cycle_o,
	input logic [QCTL_QUEUE_COUNT-1:0] qctl_sync_valid_i,
	output logic [QCTL_QUEUE_COUNT-1:0] qctl_sync_ready_o,
	output logic [QCTL_QUEUE_COUNT-1:0] qctl_notify_valid_o,
	input logic [QCTL_QUEUE_COUNT-1:0] qctl_notify_ready_i,
	output logic [QCTL_QUEUE_COUNT-1:0] qctl_mem_packet_valid_o,
	output logic [QCTL_QUEUE_COUNT*32-1:0] qctl_mem_packet_ordinal_o,
	input logic [QCTL_QUEUE_COUNT-1:0] qctl_mem_packet_retired_i,
	output logic [QCTL_QUEUE_COUNT-1:0] qctl_queue_active_o,
	output logic [QCTL_QUEUE_COUNT-1:0] qctl_wait_event_blocked_o,
	output logic [QCTL_QUEUE_COUNT*32-1:0] qctl_wait_event_tag_o,
	output logic [QCTL_QUEUE_COUNT-1:0] qctl_primed_o,
	output logic [QCTL_QUEUE_COUNT-1:0] qctl_done_o,
	output logic qctl_fault_o,
	output logic [7:0] qctl_fault_code_o,



	output logic [lpu_pkg::MEM_BANK_COUNT-1:0] local_mem_issue_valid_o,
	output logic [lpu_pkg::MEM_BANK_COUNT*lpu_pkg::MEM_INSTRUCTION_WIDTH-1:0] local_mem_issue_instruction_o,
	output logic [lpu_pkg::MEM_BANK_COUNT*32-1:0] local_mem_issue_cycle_o,
	output logic [3:0] local_mxm_load_issue_valid_o,
	output logic [4*29-1:0] local_mxm_load_issue_instruction_o,
	output logic [4*32-1:0] local_mxm_load_issue_cycle_o,
	output logic [3:0] local_mxm_dequant_issue_valid_o,
	output logic [4*16-1:0] local_mxm_dequant_issue_instruction_o,
	output logic [4*32-1:0] local_mxm_dequant_issue_cycle_o,
	output logic [3:0] local_mxm_compute_issue_valid_o,
	output logic [4*49-1:0] local_mxm_compute_issue_instruction_o,
	output logic [4*32-1:0] local_mxm_compute_issue_cycle_o,

	input logic [2*DMA_TILES*32-1:0] mem_east_edge_valid_i,
	input logic [2*DMA_TILES*32*64-1:0] mem_east_edge_data_i,
	output logic [2*DMA_TILES*32-1:0] mem_east_edge_valid_o,
	output logic [2*DMA_TILES*32*64-1:0] mem_east_edge_data_o,
	input logic [2*DMA_TILES*32-1:0] mem_west_edge_valid_i,
	input logic [2*DMA_TILES*32*64-1:0] mem_west_edge_data_i,
	output logic [2*DMA_TILES*32-1:0] mem_west_edge_valid_o,
	output logic [2*DMA_TILES*32*64-1:0] mem_west_edge_data_o,
	output logic [lpu_pkg::MEM_BANK_COUNT-1:0] mem_fault_o,
	output logic [1:0] mxm_fault_o,
	output logic [1:0] sxm_fault_o,
	output logic vxm_fault_o,
	output logic [1:0] stream_conflict_o
);
	import lpu_program_load_pkg::*;

	localparam logic [5:0] FAULT_NONE = 6'd0;
	localparam logic [5:0] FAULT_ROUTE = 6'd1;
	localparam logic [5:0] FAULT_FRONTEND = 6'd2;
	localparam logic [5:0] FAULT_QCTL = 6'd3;
	localparam integer QCTL_MXM_LOAD_BASE = lpu_pkg::MEM_BANK_COUNT;
	localparam integer QCTL_MXM_DEQUANT_BASE = QCTL_MXM_LOAD_BASE + 4;
	localparam integer QCTL_MXM_COMPUTE_BASE = QCTL_MXM_DEQUANT_BASE + 4;

	logic started_q;
	logic [1:0] dm_ready,dm_ret,dm_err;
	logic [DMA_TILES*64-1:0] dm_data[2];
	assign dma_ready_o=dm_ready[dma_hem_i];assign dma_ret_o=dm_ret[dma_hem_i];
	assign dma_err_o=dm_err[dma_hem_i];assign dma_rdata_o=dm_data[dma_hem_i];
	logic [31:0] schedule_cycle_q;
	logic execution_run;
	logic datapath_enabled_q;
	logic route_fault_q;
	logic [1:0] selected_ready_w;
	logic [1:0] selected_valid_w;
	logic [1:0] write_fire_w;
	logic [1:0] write_error_w;
	logic [1:0] route_error_fire_w;
	logic [1:0] commit_valid_q;
	logic [1:0] commit_error_q;

	logic [1:0] mem_program_valid;
	logic [1:0] mem_program_ready;
	logic [1:0] mem_program_error;
	logic [1:0] mem_frontends_ready;
	logic [1:0] mem_frontends_idle;
	logic [1:0] mem_execution_busy;
	logic [1:0] edge_execution_busy;
	logic [1:0] mem_frontend_fault;
	logic [11:0] mem_frontend_fault_code;

	logic [3:0] mxm_program_valid;
	logic [3:0] mxm_program_ready;
	logic [3:0] mxm_program_error;
	logic [3:0] mxm_frontends_ready;
	logic [3:0] mxm_frontends_idle;
	logic [3:0] mxm_execution_busy;
	logic [3:0] mxm_frontend_fault;
	logic [23:0] mxm_frontend_fault_code;

	logic [2*DMA_TILES*32-1:0] mem_to_vxm_west_valid;
	logic [2*DMA_TILES*32*64-1:0] mem_to_vxm_west_data;
	logic [2*DMA_TILES*32-1:0] vxm_to_mem_east_valid;
	logic [2*DMA_TILES*32*64-1:0] vxm_to_mem_east_data;
	logic vxm_stream_conflict;
	wire [12:0] launch[2],enqueue[2],lr[2],er[2],cal_ready[2],cal_idle[2],cal_fault[2];
	wire [127:0] word_q[2][13]; wire [31:0] aux_q[2][13];
	wire [1:0] sxm_busy; wire vxm_busy;
	for(genvar h=0;h<2;h++)begin:g_native_sched
	  for(genvar q=0;q<13;q++)begin:g_queue
	    localparam K=q==0?5:q==1?6:q==2?4:7+(q-3)%5;
	    localparam ID=q<3?0:(q-3)/5;
	    wire addressed=endpoint_load_target_kind_i[h*4+:4]==K && endpoint_load_queue_id_i[h*8+:8]==ID;
	    wire fire=endpoint_load_valid_i[h] && endpoint_load_ready_o[h];
	    wire [2:0] ctl=endpoint_load_control_i[h*3+:3];
	    if(q<3)begin assign lr[h][q]=1;assign er[h][q]=1;end
	    localparam WIDTH=q==0?128:q==1?81:q==2?80:
	        K==PROGRAM_NATIVE_WEIGHT?lpu_mxm_isa_pkg::LOAD_INSTRUCTION_BITS:
	        K==PROGRAM_NATIVE_PARAM?lpu_mxm_isa_pkg::PARAM_LOAD_INSTRUCTION_BITS:
	        K==PROGRAM_NATIVE_DEQUANT?lpu_mxm_isa_pkg::DEQUANT_INSTRUCTION_BITS:
	        K==PROGRAM_NATIVE_COMPUTE?lpu_mxm_isa_pkg::COMPUTE_INSTRUCTION_BITS:
	        lpu_mxm_backend_isa_pkg::BACKEND_INSTRUCTION_BITS;
	    lpu_native_issue_calendar #(.QUEUED(q>=3),.PAYLOAD_BITS(WIDTH),.AUX_BITS(q==0?6:0)) u_calendar(
	      .clk_i,.rst_ni,.clear_i(program_reset_i || (fire && (ctl==PROGRAM_LOAD_CLEAR || ctl==PROGRAM_LOAD_ABORT))),
	      .write_i(fire && addressed && ctl==PROGRAM_LOAD_WRITE),.prime_i(fire && addressed && ctl==PROGRAM_LOAD_PRIME),
	      .addr_i(endpoint_load_imem_address_i[h*17+:17]),.data_i(endpoint_load_data_i[h*128+:128]),
	      .strb_i(endpoint_load_strb_i[h*4+:4]),.last_i(endpoint_load_last_i[h]),
	      .start_i(program_start_i && program_start_ready_o),.run_i(execution_run),
	      .cycle_i(schedule_cycle_q),.enqueue_ready_i(er[h][q]),.launch_ready_i(lr[h][q]),
	      .payload_o(word_q[h][q]),.aux_o(aux_q[h][q]),.enqueue_o(enqueue[h][q]),.launch_o(launch[h][q]),
	      .ready_o(cal_ready[h][q]),.idle_o(cal_idle[h][q]),.fault_o(cal_fault[h][q]));
	  end
	end
	logic [QCTL_QUEUE_COUNT-1:0] qctl_scheduler_enable;
	logic [QCTL_QUEUE_COUNT*32-1:0] qctl_queue_cycle;
	logic qctl_all_primed;
	logic qctl_all_done;

	assign execution_run = started_q && !segment_retired_i;
	assign started_o = started_q;
	assign schedule_cycle_o = schedule_cycle_q;
	assign endpoint_commit_valid_o = commit_valid_q;
	assign endpoint_commit_error_o = commit_error_q;
	assign all_frontends_ready_o = (&mem_frontends_ready) && (&mxm_frontends_ready) && (&cal_ready[0]) && (&cal_ready[1]) &&
		(!ENABLE_QCTL || qctl_all_primed) && !(|commit_valid_q) && !frontend_fault_o;
	assign all_frontends_idle_o = (&mem_frontends_idle) && (&mxm_frontends_idle) && (&cal_idle[0]) && (&cal_idle[1]) &&
		(!ENABLE_QCTL || qctl_all_done) && !(|commit_valid_q);
	assign execution_drained_o = !(|sxm_busy) && !vxm_busy && !(|mem_execution_busy) && !(|mxm_execution_busy) &&
		!(|edge_execution_busy) && !(|mem_east_edge_valid_i) && !(|mem_west_edge_valid_i);
	assign program_start_ready_o = all_frontends_ready_o && !started_q;
	assign frontend_fault_o = (|cal_fault[0]) || (|cal_fault[1]) || route_fault_q || (|mem_frontend_fault) ||
		(|mxm_frontend_fault) || (ENABLE_QCTL && qctl_fault_o);
	assign frontend_fault_code_o = route_fault_q ? FAULT_ROUTE :
		(((|cal_fault[0]) || (|cal_fault[1]) || (|mem_frontend_fault) || (|mxm_frontend_fault)) ? FAULT_FRONTEND :
		((ENABLE_QCTL && qctl_fault_o) ? FAULT_QCTL : FAULT_NONE));

	// Shared storage is global, while every generated Controller owns exactly one
	// Queue-local Scheduler clock. Inactive lanes bypass QCTL in the FU subsystem.
	generate
		if(ENABLE_QCTL)begin : gen_qctl
			lpu_qctl_fabric #(
				.POOL_DEPTH(QCTL_POOL_DEPTH),
				.QUEUE_COUNT(QCTL_QUEUE_COUNT),
				.QUEUE_ENTRY_LIMIT(QCTL_QUEUE_ENTRY_LIMIT),
				.CACHE_DEPTH(QCTL_CACHE_DEPTH)
			) u_qctl_fabric (
				.clk_i,
				.rst_ni,
				.clear_i(program_reset_i),
				.run_i(execution_run),
				.load_mode_i(qctl_load_mode_i),
				.partition_valid_i(qctl_partition_valid_i),
				.partition_ready_o(qctl_partition_ready_o),
				.partition_queue_i(qctl_partition_queue_i),
				.partition_base_i(qctl_partition_base_i),
				.partition_count_i(qctl_partition_count_i),
				.partition_generation_i(qctl_partition_generation_i),
				.load_valid_i(qctl_load_valid_i),
				.load_ready_o(qctl_load_ready_o),
				.load_address_i(qctl_load_address_i),
				.load_data_i(qctl_load_data_i),
				.event_valid_i(qctl_event_valid_i),
				.event_mask_i(qctl_event_mask_i),
				.event_generation_i(qctl_event_generation_i),
				.event_phase_i(qctl_event_phase_i),
				.receipt_valid_o(qctl_receipt_valid_o),
				.receipt_ready_i(qctl_receipt_ready_i),
				.receipt_tag_o(qctl_receipt_tag_o),
				.receipt_generation_o(qctl_receipt_generation_o),
				.receipt_cycle_o(qctl_receipt_cycle_o),

				.event_ready_o(qctl_event_ready_o),
				.event_tag_i(qctl_event_tag_i),
				.sync_valid_i(qctl_sync_valid_i),
				.sync_ready_o(qctl_sync_ready_o),
				.notify_valid_o(qctl_notify_valid_o),
				.notify_ready_i(qctl_notify_ready_i),
				.mem_packet_valid_o(qctl_mem_packet_valid_o),
				.mem_packet_ordinal_o(qctl_mem_packet_ordinal_o),
				.mem_packet_retired_i(qctl_mem_packet_retired_i),
				.queue_active_o(qctl_queue_active_o),
				.scheduler_enable_o(qctl_scheduler_enable),
				.queue_cycle_o(qctl_queue_cycle),
				.wait_event_blocked_o(qctl_wait_event_blocked_o),
				.wait_event_tag_o(qctl_wait_event_tag_o),
				.primed_o(qctl_primed_o),
				.done_o(qctl_done_o),
				.all_primed_o(qctl_all_primed),
				.all_done_o(qctl_all_done),
				.fault_o(qctl_fault_o),
				.fault_code_o(qctl_fault_code_o)
			);
		end
		else begin : gen_no_qctl
			assign qctl_partition_ready_o = 1'b0;
			assign qctl_load_ready_o = 1'b0;
			assign qctl_event_ready_o = '0;
			assign qctl_receipt_valid_o='0;
			assign qctl_receipt_tag_o='0;
			assign qctl_receipt_generation_o='0;
			assign qctl_receipt_cycle_o='0;

			assign qctl_sync_ready_o = '0;
			assign qctl_notify_valid_o = '0;
			assign qctl_mem_packet_valid_o = '0;
			assign qctl_mem_packet_ordinal_o = '0;
			assign qctl_queue_active_o = '0;
			assign qctl_scheduler_enable = '0;
			assign qctl_queue_cycle = '0;
			assign qctl_wait_event_blocked_o = '0;
			assign qctl_wait_event_tag_o = '0;
			assign qctl_primed_o = '1;
			assign qctl_done_o = '1;
			assign qctl_all_primed = 1'b1;
			assign qctl_all_done = 1'b1;
			assign qctl_fault_o = 1'b0;
			assign qctl_fault_code_o = '0;
		end
	endgenerate

	// The cluster only routes Program Load traffic; all instruction state lives inside FU subsystems.
	always_comb begin
		endpoint_load_ready_o = '0;
		selected_ready_w = '0;
		selected_valid_w = '0;
		write_fire_w = '0;
		write_error_w = '0;
		route_error_fire_w = '0;
		mem_program_valid = '0;
		mxm_program_valid = '0;

		for(integer hemisphere = 0; hemisphere < 2; hemisphere = hemisphere + 1)begin
			selected_ready_w[hemisphere] = 1'b1;
			case(endpoint_load_target_kind_i[hemisphere*4+:4])
				PROGRAM_TARGET_MEM: begin
					selected_valid_w[hemisphere] =
						endpoint_load_queue_id_i[hemisphere*8+:8] < lpu_pkg::MEM_BANKS_PER_HEMISPHERE;
					selected_ready_w[hemisphere] = selected_valid_w[hemisphere] ?
						mem_program_ready[hemisphere] : 1'b1;
				end
				PROGRAM_TARGET_MXM_LOAD,
				PROGRAM_TARGET_MXM_DEQUANT,
				PROGRAM_TARGET_MXM_COMPUTE: begin
					if(LEGACY_MXM && endpoint_load_queue_id_i[hemisphere*8+:8] < 2)begin
						selected_valid_w[hemisphere] = 1'b1;
						selected_ready_w[hemisphere] = mxm_program_ready[
							hemisphere*2 + endpoint_load_queue_id_i[hemisphere*8+:8]];
					end
				end
				PROGRAM_TARGET_VXM: selected_valid_w[hemisphere]=ENABLE_SXM_VXM_EXECUTION && hemisphere==0 && endpoint_load_queue_id_i[hemisphere*8+:8]==0;
				PROGRAM_TARGET_SXM_TRANSPOSE,PROGRAM_TARGET_SXM_PERMUTE:
				  selected_valid_w[hemisphere]=ENABLE_SXM_VXM_EXECUTION && endpoint_load_queue_id_i[hemisphere*8+:8]==0;
				PROGRAM_NATIVE_WEIGHT,PROGRAM_NATIVE_PARAM,PROGRAM_NATIVE_DEQUANT,PROGRAM_NATIVE_COMPUTE,PROGRAM_NATIVE_BACKEND:
				  selected_valid_w[hemisphere]=!LEGACY_MXM && endpoint_load_queue_id_i[hemisphere*8+:8]<ACTIVE_MXMS;
				default: selected_valid_w[hemisphere] = 1'b0;
			endcase

			if((endpoint_load_control_i[hemisphere*3+:3] == PROGRAM_LOAD_CLEAR) ||
				(endpoint_load_control_i[hemisphere*3+:3] == PROGRAM_LOAD_ABORT))begin
				selected_valid_w[hemisphere] = 1'b1;
				selected_ready_w[hemisphere] = 1'b1;
			end

			endpoint_load_ready_o[hemisphere] = selected_ready_w[hemisphere] &&
				((endpoint_load_control_i[hemisphere*3+:3] != PROGRAM_LOAD_WRITE) ||
				 !commit_valid_q[hemisphere] || endpoint_commit_ready_i[hemisphere]);
			write_fire_w[hemisphere] = endpoint_load_valid_i[hemisphere] &&
				endpoint_load_ready_o[hemisphere] &&
				(endpoint_load_control_i[hemisphere*3+:3] == PROGRAM_LOAD_WRITE);

			mem_program_valid[hemisphere] = endpoint_load_valid_i[hemisphere] &&
				endpoint_load_ready_o[hemisphere] &&
				(((endpoint_load_target_kind_i[hemisphere*4+:4] == PROGRAM_TARGET_MEM) &&
				  selected_valid_w[hemisphere]) ||
				 (endpoint_load_control_i[hemisphere*3+:3] == PROGRAM_LOAD_CLEAR) ||
				 (endpoint_load_control_i[hemisphere*3+:3] == PROGRAM_LOAD_ABORT));

			for(integer local_mxm = 0; local_mxm < 2; local_mxm = local_mxm + 1)begin
				mxm_program_valid[hemisphere*2+local_mxm] = endpoint_load_valid_i[hemisphere] &&
					endpoint_load_ready_o[hemisphere] &&
					(((endpoint_load_target_kind_i[hemisphere*4+:4] >= PROGRAM_TARGET_MXM_LOAD) &&
					  (endpoint_load_target_kind_i[hemisphere*4+:4] <= PROGRAM_TARGET_MXM_COMPUTE) &&
					  (endpoint_load_queue_id_i[hemisphere*8+:8] == local_mxm)) ||
					 (endpoint_load_control_i[hemisphere*3+:3] == PROGRAM_LOAD_CLEAR) ||
					 (endpoint_load_control_i[hemisphere*3+:3] == PROGRAM_LOAD_ABORT));
			end

			write_error_w[hemisphere] = write_fire_w[hemisphere] &&
				(!selected_valid_w[hemisphere] ||
				 ((endpoint_load_target_kind_i[hemisphere*4+:4] == PROGRAM_TARGET_MEM) &&
				  ((endpoint_load_strb_i[hemisphere*4+:4] != 4'b0111) ||
				   (endpoint_load_imem_address_i[hemisphere*17+:17] >= MEM_IMEM_DEPTH))) ||
				 (((endpoint_load_target_kind_i[hemisphere*4+:4] >= PROGRAM_TARGET_MXM_LOAD) &&
				   (endpoint_load_target_kind_i[hemisphere*4+:4] <= PROGRAM_TARGET_MXM_COMPUTE)) &&
				  ((endpoint_load_strb_i[hemisphere*4+:4] != 4'b1111) ||
				   (endpoint_load_imem_address_i[hemisphere*17+:17] >= MXM_IMEM_DEPTH))));
			route_error_fire_w[hemisphere] = endpoint_load_valid_i[hemisphere] &&
				endpoint_load_ready_o[hemisphere] &&
				(((endpoint_load_control_i[hemisphere*3+:3] == PROGRAM_LOAD_PRIME) &&
				  !selected_valid_w[hemisphere]) ||
				 (endpoint_load_control_i[hemisphere*3+:3] > PROGRAM_LOAD_ABORT) ||
				 ((endpoint_load_control_i[hemisphere*3+:3] != PROGRAM_LOAD_WRITE) &&
				  ((endpoint_load_data_i[hemisphere*128+:128] != '0) ||
				   (endpoint_load_strb_i[hemisphere*4+:4] != '0))));
		end
	end

	// One-cycle elastic commit response preserves the Program Loader write contract.
	generate
		for(genvar commit_gen = 0; commit_gen < 2; commit_gen = commit_gen + 1)begin : gen_commit
			always_ff @(posedge clk_i or negedge rst_ni) begin
				if(!rst_ni)begin
					commit_valid_q[commit_gen] <= 1'b0;
					commit_error_q[commit_gen] <= 1'b0;
				end
				else if(program_reset_i)begin
					commit_valid_q[commit_gen] <= 1'b0;
					commit_error_q[commit_gen] <= 1'b0;
				end
				else begin
					if(commit_valid_q[commit_gen] && endpoint_commit_ready_i[commit_gen])begin
						commit_valid_q[commit_gen] <= 1'b0;
					end
					if(write_fire_w[commit_gen])begin
						commit_valid_q[commit_gen] <= 1'b1;
						commit_error_q[commit_gen] <= write_error_w[commit_gen];
					end
				end
			end
		end
	endgenerate

	// Schedule Cycle 0 becomes visible on the accepted START edge.
	// Segment re-arm clears issue state, but keeps datapath SRAM/weights live.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if (!rst_ni) datapath_enabled_q <= 1'b0;
		else if (program_start_i && program_start_ready_o) datapath_enabled_q <= 1'b1;
	end

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			started_q <= 1'b0;
			schedule_cycle_q <= '0;
		end
		else if(program_reset_i)begin
			started_q <= 1'b0;
			schedule_cycle_q <= '0;
		end
		else begin
			if(program_start_i && program_start_ready_o)begin
				started_q <= 1'b1;
			end
			if(execution_run)begin
				schedule_cycle_q <= schedule_cycle_q + 1'b1;
			end
		end
	end

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			route_fault_q <= 1'b0;
		end
		else if(program_reset_i)begin
			route_fault_q <= 1'b0;
		end
		else if(!route_fault_q && ((|write_error_w) || (|route_error_fire_w)))begin
			route_fault_q <= 1'b1;
		end
	end

	generate
		for(genvar hemisphere_gen = 0; hemisphere_gen < 2; hemisphere_gen = hemisphere_gen + 1)begin : gen_hemisphere
			localparam integer HEMISPHERE_INDEX = hemisphere_gen;
			logic [DMA_TILES*32-1:0] mem_east_valid;
			logic [DMA_TILES*32*64-1:0] mem_east_data;
			logic [DMA_TILES*32-1:0] mem_west_valid;
			logic [DMA_TILES*32*64-1:0] mem_west_data;
			logic [DMA_TILES*32-1:0] sxm_east_valid;
			logic [DMA_TILES*32*64-1:0] sxm_east_data;
			logic [DMA_TILES*32-1:0] sxm_west_valid;
			logic [DMA_TILES*32*64-1:0] sxm_west_data;
			logic [DMA_TILES*32-1:0] mxm_west_valid;
			logic [DMA_TILES*32*64-1:0] mxm_west_data;
			logic [DMA_TILES*32-1:0] mxm_east_valid;
			logic [DMA_TILES*32*64-1:0] mxm_east_data;
			logic [2*DMA_TILES*32-1:0] local_mxm_west_valid;
			logic [2*DMA_TILES*32*64-1:0] local_mxm_west_data;
			logic [2*DMA_TILES*32-1:0] local_mxm_east_valid;
			logic [2*DMA_TILES*32*64-1:0] local_mxm_east_data;
			logic [1:0] local_mxm_fault;
			logic [1:0] local_mxm_conflict;
			logic mem_stream_conflict;
			logic sxm_stream_conflict;
			logic sxm_fault;
			logic mxm_stream_conflict;
			logic mxm_fault;

			lpu_mem_subsystem #(
		.PACKED_MEM_ROW_BITS(PACKED_MEM_ROW_BITS),
				.DMA_TILES(DMA_TILES),
				.IMEM_DEPTH(MEM_IMEM_DEPTH),
				.ACTIVE_CONTEXTS(ACTIVE_CONTEXTS),
				.DEPTH_ROWS(MEM_DEPTH_ROWS),
				.ACTIVE_COLUMNS(ACTIVE_MEM_COLUMNS)
			) u_mem_subsystem (
				.dma_req_i(dma_req_i && dma_hem_i==HEMISPHERE_INDEX),.dma_write_i,.dma_stream_i,.dma_bank_i,
				.dma_row_i,.dma_wdata_i,.dma_ready_o(dm_ready[HEMISPHERE_INDEX]),.dma_ret_o(dm_ret[HEMISPHERE_INDEX]),
				.dma_err_o(dm_err[HEMISPHERE_INDEX]),.dma_rdata_o(dm_data[HEMISPHERE_INDEX]),
                .clk_i, .rst_ni, .program_reset_i,
				.run_i(execution_run), .schedule_cycle_i(schedule_cycle_q),
				.qctl_active_i(qctl_queue_active_o[
					HEMISPHERE_INDEX*lpu_pkg::MEM_BANKS_PER_HEMISPHERE+:lpu_pkg::MEM_BANKS_PER_HEMISPHERE]),
				.qctl_scheduler_enable_i(qctl_scheduler_enable[
					HEMISPHERE_INDEX*lpu_pkg::MEM_BANKS_PER_HEMISPHERE+:lpu_pkg::MEM_BANKS_PER_HEMISPHERE]),
				.qctl_schedule_cycle_i(qctl_queue_cycle[
					HEMISPHERE_INDEX*lpu_pkg::MEM_BANKS_PER_HEMISPHERE*32+:
					lpu_pkg::MEM_BANKS_PER_HEMISPHERE*32]),
				.program_valid_i(mem_program_valid[HEMISPHERE_INDEX]),
				.program_ready_o(mem_program_ready[HEMISPHERE_INDEX]),
				.program_control_i(endpoint_load_control_i[HEMISPHERE_INDEX*3+:3]),
				.program_queue_id_i(endpoint_load_queue_id_i[HEMISPHERE_INDEX*8+:8]),
				.program_address_i(endpoint_load_imem_address_i[HEMISPHERE_INDEX*17+:17]),
				.program_data_i(endpoint_load_data_i[HEMISPHERE_INDEX*128+:128]),
				.program_strb_i(endpoint_load_strb_i[HEMISPHERE_INDEX*4+:4]),
				.program_last_i(endpoint_load_last_i[HEMISPHERE_INDEX]),
				.program_error_o(mem_program_error[HEMISPHERE_INDEX]),



				.local_issue_valid_o(local_mem_issue_valid_o[
					HEMISPHERE_INDEX*lpu_pkg::MEM_BANKS_PER_HEMISPHERE+:lpu_pkg::MEM_BANKS_PER_HEMISPHERE]),
				.local_issue_instruction_o(local_mem_issue_instruction_o[
					HEMISPHERE_INDEX*lpu_pkg::MEM_BANKS_PER_HEMISPHERE*lpu_pkg::MEM_INSTRUCTION_WIDTH+:
					lpu_pkg::MEM_BANKS_PER_HEMISPHERE*lpu_pkg::MEM_INSTRUCTION_WIDTH]),
				.local_issue_cycle_o(local_mem_issue_cycle_o[
					HEMISPHERE_INDEX*lpu_pkg::MEM_BANKS_PER_HEMISPHERE*32+:
					lpu_pkg::MEM_BANKS_PER_HEMISPHERE*32]),
				.frontends_ready_o(mem_frontends_ready[HEMISPHERE_INDEX]),
				.frontends_idle_o(mem_frontends_idle[HEMISPHERE_INDEX]),
				.execution_busy_o(mem_execution_busy[HEMISPHERE_INDEX]),
				.frontend_fault_o(mem_frontend_fault[HEMISPHERE_INDEX]),
				.frontend_fault_code_o(mem_frontend_fault_code[HEMISPHERE_INDEX*6+:6]),
				.east_edge_valid_i(vxm_to_mem_east_valid[HEMISPHERE_INDEX*DMA_TILES*32+:DMA_TILES*32]),
				.east_edge_data_i(vxm_to_mem_east_data[HEMISPHERE_INDEX*DMA_TILES*32*64+:DMA_TILES*32*64]),
				.east_edge_valid_o(mem_east_valid), .east_edge_data_o(mem_east_data),
				.west_edge_valid_i(sxm_west_valid), .west_edge_data_i(sxm_west_data),
				.west_edge_valid_o(mem_west_valid), .west_edge_data_o(mem_west_data),
				.mem_fault_o(mem_fault_o[
					HEMISPHERE_INDEX*lpu_pkg::MEM_BANKS_PER_HEMISPHERE+:
					lpu_pkg::MEM_BANKS_PER_HEMISPHERE]),
				.conflict_o(mem_stream_conflict)
			);

			if (ENABLE_SXM_VXM_EXECUTION) begin : gen_sxm_execution
			lpu_sxm_subsystem #(.T(DMA_TILES)) u_sxm_subsystem (
				.clk_i, .rst_ni(rst_ni && !program_reset_i), .run_i(execution_run),
				.ctrl_issue_i(launch[HEMISPHERE_INDEX][0]),.exec_issue_i(launch[HEMISPHERE_INDEX][1]),
				.ctrl_word_i(word_q[HEMISPHERE_INDEX][0]),.ctrl_aux_i(aux_q[HEMISPHERE_INDEX][0]),
				.exec_word_i(word_q[HEMISPHERE_INDEX][1]),.busy_o(sxm_busy[HEMISPHERE_INDEX]),
				.east_inner_valid_i(mem_east_valid), .east_inner_data_i(mem_east_data),
				.east_outer_valid_o(sxm_east_valid), .east_outer_data_o(sxm_east_data),
				.west_outer_valid_i(mxm_west_valid), .west_outer_data_i(mxm_west_data),
				.west_inner_valid_o(sxm_west_valid), .west_inner_data_o(sxm_west_data),
				.fault_o(sxm_fault), .conflict_o(sxm_stream_conflict)
			);
			end else begin : gen_sxm_passive
				assign sxm_busy[HEMISPHERE_INDEX]=0;
				// Match the one-cycle pass-through of SXM with no issued work.
				always_ff @(posedge clk_i or negedge rst_ni) begin
					if (!rst_ni) begin
						sxm_east_valid <= '0;
						sxm_west_valid <= '0;
					end else if (!execution_run) begin
						sxm_east_valid <= '0;
						sxm_west_valid <= '0;
					end else begin
						sxm_east_valid <= mem_east_valid;
						sxm_west_valid <= mxm_west_valid;
					end
				end
				always_ff @(posedge clk_i) begin
					sxm_east_data <= mem_east_data;
					sxm_west_data <= mxm_west_data;
				end
				assign sxm_fault = 1'b0;
				assign sxm_stream_conflict = 1'b0;
			end
			for(genvar local_mxm_gen = 0; local_mxm_gen < 2; local_mxm_gen = local_mxm_gen + 1)begin : gen_mxm
				localparam integer MXM_INDEX = HEMISPHERE_INDEX*2 + local_mxm_gen;
				localparam Q=3+5*local_mxm_gen;
				  if (!LEGACY_MXM && local_mxm_gen >= ACTIVE_MXMS) begin : g_unused
                    assign er[HEMISPHERE_INDEX][Q+:5]='0;
                    assign lr[HEMISPHERE_INDEX][Q+:5]='0;
                    assign local_mxm_east_valid[local_mxm_gen*DMA_TILES*32+:DMA_TILES*32]=sxm_east_valid;
                    assign {local_mxm_west_valid[local_mxm_gen*DMA_TILES*32+:DMA_TILES*32],
                            local_mxm_west_data[local_mxm_gen*DMA_TILES*2048+:DMA_TILES*2048],
                            local_mxm_east_data[local_mxm_gen*DMA_TILES*2048+:DMA_TILES*2048],
                            local_mxm_fault[local_mxm_gen],local_mxm_conflict[local_mxm_gen],mxm_execution_busy[MXM_INDEX]}='0;
                  end
                  if (!LEGACY_MXM && local_mxm_gen < ACTIVE_MXMS) begin : g_native
                    wire [639:0] payload;
				  for(genvar j=0;j<5;j++)assign payload[j*128+:128]=word_q[HEMISPHERE_INDEX][Q+j];
				  
                    lpu_mxm_native_stream #(.T(DMA_TILES)) u_execution(
				    .clk_i,.rst_ni(rst_ni && !discard_partial_sums_i),.run_i(datapath_enabled_q),
				    .enqueue_i(enqueue[HEMISPHERE_INDEX][Q+:5]),.launch_i(launch[HEMISPHERE_INDEX][Q+:5]),
				    .payload_i(payload),.enqueue_ready_o(er[HEMISPHERE_INDEX][Q+:5]),.launch_ready_o(lr[HEMISPHERE_INDEX][Q+:5]),
				    .east_valid_i(sxm_east_valid),.east_data_i(sxm_east_data),
				    .west_valid_i(local_mxm_gen==0?mem_west_edge_valid_i[HEMISPHERE_INDEX*DMA_TILES*32+:DMA_TILES*32]:'0),
				    .west_data_i(mem_west_edge_data_i[HEMISPHERE_INDEX*DMA_TILES*32*64+:DMA_TILES*32*64]),
				    .east_valid_o(local_mxm_east_valid[local_mxm_gen*DMA_TILES*32+:DMA_TILES*32]),.east_data_o(local_mxm_east_data[local_mxm_gen*DMA_TILES*32*64+:DMA_TILES*32*64]),
				    .west_valid_o(local_mxm_west_valid[local_mxm_gen*DMA_TILES*32+:DMA_TILES*32]),.west_data_o(local_mxm_west_data[local_mxm_gen*DMA_TILES*32*64+:DMA_TILES*32*64]),
				    .fault_o(local_mxm_fault[local_mxm_gen]),.conflict_o(local_mxm_conflict[local_mxm_gen]),.busy_o(mxm_execution_busy[MXM_INDEX]));
				  end
				  if (!LEGACY_MXM) begin : g_native_status
				  assign {mxm_program_ready[MXM_INDEX],mxm_frontends_ready[MXM_INDEX],mxm_frontends_idle[MXM_INDEX]}=3'b111;
				  assign {mxm_program_error[MXM_INDEX],mxm_frontend_fault[MXM_INDEX],mxm_frontend_fault_code[MXM_INDEX*6+:6]}='0;
				  assign {local_mxm_load_issue_valid_o[MXM_INDEX],local_mxm_load_issue_instruction_o[MXM_INDEX*29+:29],local_mxm_load_issue_cycle_o[MXM_INDEX*32+:32],
				  local_mxm_dequant_issue_valid_o[MXM_INDEX],local_mxm_dequant_issue_instruction_o[MXM_INDEX*16+:16],local_mxm_dequant_issue_cycle_o[MXM_INDEX*32+:32],
				  local_mxm_compute_issue_valid_o[MXM_INDEX],local_mxm_compute_issue_instruction_o[MXM_INDEX*49+:49],local_mxm_compute_issue_cycle_o[MXM_INDEX*32+:32]}='0;
				end else begin:g_legacy
				assign er[HEMISPHERE_INDEX][Q+:5]=0; assign lr[HEMISPHERE_INDEX][Q+:5]=0;
				lpu_mxm_subsystem #(
					.STREAMING_VECTOR(LEGACY_VECTOR_ARRAY),
                    .WEIGHT_BLOCKS(DMA_TILES),
					.LOCAL_MXM_INDEX(local_mxm_gen),
					.IMEM_DEPTH(MXM_IMEM_DEPTH),
					.ACTIVE_CONTEXTS(ACTIVE_CONTEXTS),
					.ACCUMULATOR_BLOCK_COUNT(MXM_ACCUMULATOR_BLOCK_COUNT)
				) u_mxm_subsystem (
                    .clk_i, .rst_ni, .program_reset_i, .discard_partial_sums_i,
					.execution_enable_i(datapath_enabled_q),
					.run_i(execution_run), .schedule_cycle_i(schedule_cycle_q),
					.qctl_active_i({
						qctl_queue_active_o[QCTL_MXM_COMPUTE_BASE+MXM_INDEX],
						qctl_queue_active_o[QCTL_MXM_DEQUANT_BASE+MXM_INDEX],
						qctl_queue_active_o[QCTL_MXM_LOAD_BASE+MXM_INDEX]}),
					.qctl_scheduler_enable_i({
						qctl_scheduler_enable[QCTL_MXM_COMPUTE_BASE+MXM_INDEX],
						qctl_scheduler_enable[QCTL_MXM_DEQUANT_BASE+MXM_INDEX],
						qctl_scheduler_enable[QCTL_MXM_LOAD_BASE+MXM_INDEX]}),
					.qctl_schedule_cycle_i({
						qctl_queue_cycle[(QCTL_MXM_COMPUTE_BASE+MXM_INDEX)*32+:32],
						qctl_queue_cycle[(QCTL_MXM_DEQUANT_BASE+MXM_INDEX)*32+:32],
						qctl_queue_cycle[(QCTL_MXM_LOAD_BASE+MXM_INDEX)*32+:32]}),
					.program_valid_i(mxm_program_valid[MXM_INDEX]),
					.program_ready_o(mxm_program_ready[MXM_INDEX]),
					.program_control_i(endpoint_load_control_i[HEMISPHERE_INDEX*3+:3]),
					.program_target_kind_i(endpoint_load_target_kind_i[HEMISPHERE_INDEX*4+:4]),
					.program_address_i(endpoint_load_imem_address_i[HEMISPHERE_INDEX*17+:17]),
					.program_data_i(endpoint_load_data_i[HEMISPHERE_INDEX*128+:128]),
					.program_strb_i(endpoint_load_strb_i[HEMISPHERE_INDEX*4+:4]),
					.program_last_i(endpoint_load_last_i[HEMISPHERE_INDEX]),
					.program_error_o(mxm_program_error[MXM_INDEX]),






					.local_load_issue_valid_o(local_mxm_load_issue_valid_o[MXM_INDEX]),
					.local_load_issue_instruction_o(local_mxm_load_issue_instruction_o[MXM_INDEX*29+:29]),
					.local_load_issue_cycle_o(local_mxm_load_issue_cycle_o[MXM_INDEX*32+:32]),
					.local_dequant_issue_valid_o(local_mxm_dequant_issue_valid_o[MXM_INDEX]),
					.local_dequant_issue_instruction_o(local_mxm_dequant_issue_instruction_o[MXM_INDEX*16+:16]),
					.local_dequant_issue_cycle_o(local_mxm_dequant_issue_cycle_o[MXM_INDEX*32+:32]),
					.local_compute_issue_valid_o(local_mxm_compute_issue_valid_o[MXM_INDEX]),
					.local_compute_issue_instruction_o(local_mxm_compute_issue_instruction_o[MXM_INDEX*49+:49]),
					.local_compute_issue_cycle_o(local_mxm_compute_issue_cycle_o[MXM_INDEX*32+:32]),
					.frontends_ready_o(mxm_frontends_ready[MXM_INDEX]),
					.frontends_idle_o(mxm_frontends_idle[MXM_INDEX]),
					.execution_busy_o(mxm_execution_busy[MXM_INDEX]),
					.frontend_fault_o(mxm_frontend_fault[MXM_INDEX]),
					.frontend_fault_code_o(mxm_frontend_fault_code[MXM_INDEX*6+:6]),
					.east_from_sxm_valid_i(sxm_east_valid), .east_from_sxm_data_i(sxm_east_data),
					.external_west_valid_i(local_mxm_gen == 0 ?
						mem_west_edge_valid_i[HEMISPHERE_INDEX*DMA_TILES*32+:DMA_TILES*32] : '0),
					.external_west_data_i(mem_west_edge_data_i[HEMISPHERE_INDEX*DMA_TILES*32*64+:DMA_TILES*32*64]),
					.east_external_valid_o(local_mxm_east_valid[local_mxm_gen*DMA_TILES*32+:DMA_TILES*32]),
					.east_external_data_o(local_mxm_east_data[local_mxm_gen*DMA_TILES*32*64+:DMA_TILES*32*64]),
					.west_to_sxm_valid_o(local_mxm_west_valid[local_mxm_gen*DMA_TILES*32+:DMA_TILES*32]),
					.west_to_sxm_data_o(local_mxm_west_data[local_mxm_gen*DMA_TILES*32*64+:DMA_TILES*32*64]),
					.fault_o(local_mxm_fault[local_mxm_gen]),
					.conflict_o(local_mxm_conflict[local_mxm_gen])
				);
				end
			end

			always_comb begin
				mxm_east_valid = local_mxm_east_valid[0+:DMA_TILES*32] & local_mxm_east_valid[DMA_TILES*32+:DMA_TILES*32];
				mxm_east_data = local_mxm_east_data[0+:DMA_TILES*32*64];
				mxm_west_valid = local_mxm_west_valid[0+:DMA_TILES*32];
				mxm_west_data = local_mxm_west_data[0+:DMA_TILES*32*64];
				mxm_stream_conflict = |local_mxm_conflict;
				for(integer stream_cell = 0; stream_cell < DMA_TILES*32; stream_cell = stream_cell + 1)begin
					if(local_mxm_west_valid[DMA_TILES*32+stream_cell])begin
						if(mxm_west_valid[stream_cell])begin
							mxm_stream_conflict = 1'b1;
						end
						else begin
							mxm_west_valid[stream_cell] = 1'b1;
							mxm_west_data[stream_cell*64+:64] =
								local_mxm_west_data[(DMA_TILES*32+stream_cell)*64+:64];
						end
					end
				end
				mxm_fault = |local_mxm_fault;
			end

			assign mem_east_edge_valid_o[HEMISPHERE_INDEX*DMA_TILES*32+:DMA_TILES*32] = mxm_east_valid;
			assign mem_east_edge_data_o[HEMISPHERE_INDEX*DMA_TILES*32*64+:DMA_TILES*32*64] = mxm_east_data;
			assign mem_west_edge_valid_o[HEMISPHERE_INDEX*DMA_TILES*32+:DMA_TILES*32] = mem_west_valid;
			assign mem_west_edge_data_o[HEMISPHERE_INDEX*DMA_TILES*32*64+:DMA_TILES*32*64] = mem_west_data;
			assign mem_to_vxm_west_valid[HEMISPHERE_INDEX*DMA_TILES*32+:DMA_TILES*32] = mem_west_valid;
			assign mem_to_vxm_west_data[HEMISPHERE_INDEX*DMA_TILES*32*64+:DMA_TILES*32*64] = mem_west_data;
			assign sxm_fault_o[HEMISPHERE_INDEX] = sxm_fault;
			assign mxm_fault_o[HEMISPHERE_INDEX] = mxm_fault;
			// Wait for values still travelling between units, as well as each unit’s busy signal.
			assign edge_execution_busy[HEMISPHERE_INDEX] = (|mem_east_valid) ||
				(|mem_west_valid) || (|sxm_east_valid) || (|sxm_west_valid) ||
				(|local_mxm_east_valid) || (|local_mxm_west_valid);
			assign stream_conflict_o[HEMISPHERE_INDEX] = mem_stream_conflict |
				sxm_stream_conflict | mxm_stream_conflict | vxm_stream_conflict;
		end
	endgenerate

	generate if (ENABLE_SXM_VXM_EXECUTION) begin : gen_vxm_execution
	lpu_vxm_subsystem #(.TILES(DMA_TILES)) u_vxm_subsystem (
		.clk_i, .rst_ni(rst_ni && !program_reset_i), .run_i(execution_run),
		.local_issue_valid_i({8{launch[0][2]}} & word_q[0][2][7:0]),
		.local_issue_instruction_i(word_q[0][2][63:8]),
		.global_issue_valid_i(launch[0][2] && word_q[0][2][64]),
		.global_issue_instruction_i(word_q[0][2][79:65]),.busy_o(vxm_busy),
		.west_from_mem_valid_i(mem_to_vxm_west_valid),
		.west_from_mem_data_i(mem_to_vxm_west_data),
		.external_east_valid_i(mem_east_edge_valid_i),
		.external_east_data_i(mem_east_edge_data_i),
		.east_to_mem_valid_o(vxm_to_mem_east_valid),
		.east_to_mem_data_o(vxm_to_mem_east_data),
		.fault_o(vxm_fault_o),
		.conflict_o(vxm_stream_conflict)
	);
	end else begin : gen_vxm_passive
		assign vxm_busy=0;
		// MEM/MXM-only build: keep the real VXM boundary routing, with
		// no VXM consumer/producer. No issue queue or ALUs are synthesized.
		lpu_vxm_stream_bridge #(.TILES(DMA_TILES)) u_stream_bridge (
			.west_from_mem_valid_i(mem_to_vxm_west_valid),
			.west_from_mem_data_i(mem_to_vxm_west_data),
			.external_east_valid_i(mem_east_edge_valid_i),
			.external_east_data_i(mem_east_edge_data_i),
			.west_consumed_i('0), .produced_valid_i('0), .produced_data_i('0),
			.east_to_mem_valid_o(vxm_to_mem_east_valid),
			.east_to_mem_data_o(vxm_to_mem_east_data), .conflict_o(vxm_stream_conflict)
		);
		assign vxm_fault_o = 1'b0;
	end endgenerate
endmodule
