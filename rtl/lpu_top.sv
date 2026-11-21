module lpu_top #(
	parameter integer MEM_DEPTH_ROWS = 2048,
	parameter integer ACTIVE_MEM_COLUMNS = 52,
	parameter integer MXM_ACCUMULATOR_BLOCK_COUNT = lpu_pkg::MXM_ACCUMULATOR_BLOCK_COUNT,
	parameter integer PROGRAM_COMMAND_DEPTH = 32,
	parameter integer PROGRAM_DMA_DATA_WIDTH = 256,
	parameter integer DMA_VECTOR_BYTES=32,
	parameter integer DMA_RT=128,
	parameter integer DMA_Q=(DMA_VECTOR_BYTES==16?832:384),
	// Number of entries on the ordered program-response interface, not AXI beats.
	parameter integer PROGRAM_DMA_RX_FIFO_DEPTH = (DMA_VECTOR_BYTES==16?112:192),
	parameter integer PROGRAM_DMA_OUTSTANDING_DEPTH = 16,
	parameter integer PROGRAM_MEM_IMEM_DEPTH = 131072,
	parameter integer PROGRAM_MXM_IMEM_DEPTH = 65536,
	parameter integer PROGRAM_ACTIVE_CONTEXTS = 4,
	parameter bit ENABLE_QCTL = 1'b0,
	parameter bit ENABLE_SXM_VXM_EXECUTION = 1'b1,
	parameter integer QCTL_QUEUE_COUNT = 220,
	parameter integer PROGRAM_COMMAND_ADDRESS_WIDTH = PROGRAM_COMMAND_DEPTH <= 1 ? 1 : $clog2(PROGRAM_COMMAND_DEPTH)
) (
	input logic clk_i,
	input logic rst_ni,
	// A reload request may be queued while running. ACK follows segment end
	// and physical drain; clk_i/rst_ni are shared with the AXI controller port.
	input logic program_reset_i,
	output logic program_reload_ready_o,
	output logic program_reload_ack_o,
	input logic program_command_write_valid_i,
	output logic program_command_write_ready_o,
	input logic [PROGRAM_COMMAND_ADDRESS_WIDTH-1:0] program_command_write_address_i,
	input logic [2:0] program_command_write_opcode_i,
	input logic [63:0] program_command_write_source_address_i,
	input logic [31:0] program_command_write_byte_count_i,
	input logic [3:0] program_command_write_target_kind_i,
	input logic [7:0] program_command_write_global_queue_id_i,
	input logic [1:0] program_command_write_format_i,
	input logic [1:0] program_command_write_encoding_mode_i,
	input logic [16:0] program_command_write_imem_base_address_i,
	input logic program_command_write_image_first_i,
	input logic program_command_write_image_last_i,
	input logic [15:0] program_command_write_expected_word_count_i,
	input logic [PROGRAM_COMMAND_ADDRESS_WIDTH-1:0] program_command_write_jump_address_i,
	input logic program_load_start_valid_i,
	output logic program_load_start_ready_o,
	input logic [PROGRAM_COMMAND_ADDRESS_WIDTH:0] program_load_start_command_count_i,
	// One transport descriptor owns the MEM window; accepted results are tagged.
	input logic dma_desc_valid_i,output logic dma_desc_ready_o,input logic dma_store_i,dma_hem_i,
	input logic [6:0] dma_bank_i,input logic [2:0] dma_lane_i,input logic [14:0] dma_row_i,
	input logic [63:0] dma_addr_i,input logic [31:0] dma_count_i,dma_stride_i,dma_tag_i,
	output logic dma_busy_o,dma_result_valid_o,dma_result_error_o,dma_isolated_o,
	input logic dma_result_ready_i,output logic [31:0] dma_result_tag_o,
	// Shared five-channel AXI4 manager, physical width selected by target.
	output logic [63:0] m_axi_awaddr_o,output logic [7:0] m_axi_awid_o,m_axi_awlen_o,
	output logic [2:0] m_axi_awsize_o,output logic [1:0] m_axi_awburst_o,
	output logic m_axi_awvalid_o,m_axi_wvalid_o,m_axi_wlast_o,m_axi_bready_o,
	input logic m_axi_awready_i,m_axi_wready_i,m_axi_bvalid_i,input logic [7:0] m_axi_bid_i,
	input logic [1:0] m_axi_bresp_i,output logic [DMA_VECTOR_BYTES*8-1:0] m_axi_wdata_o,
	output logic [DMA_VECTOR_BYTES-1:0] m_axi_wstrb_o,
	output logic [63:0] m_axi_araddr_o,
	output logic [7:0] m_axi_arid_o,
	output logic [7:0] m_axi_arlen_o,
	output logic [2:0] m_axi_arsize_o,
	output logic [1:0] m_axi_arburst_o,
	output logic m_axi_arvalid_o,
	input logic m_axi_arready_i,
	input logic [DMA_VECTOR_BYTES*8-1:0] m_axi_rdata_i,
	input logic [7:0] m_axi_rid_i,
	input logic [1:0] m_axi_rresp_i,
	input logic m_axi_rlast_i, m_axi_rvalid_i,
	output logic m_axi_rready_o,
	input logic program_start_request_i,
	input logic program_dependencies_ready_i,
	output logic program_start_ack_o,
	output logic program_load_complete_o,
	output logic program_ready_o,
	output logic program_running_o,
	output logic program_done_o,
	output logic program_fault_o,
	output logic [5:0] program_fault_code_o,
	output logic [31:0] program_schedule_cycle_o,

	// Shared QCTL storage serves one Queue-local Controller per supported MEM/MXM stream.
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
	input logic [QCTL_QUEUE_COUNT-1:0] qctl_event_valid_i,
	output logic [QCTL_QUEUE_COUNT-1:0] qctl_event_ready_o,
	input logic [QCTL_QUEUE_COUNT*32-1:0] qctl_event_tag_i,
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

	input logic [2*4*32-1:0] mem_east_edge_valid_i,
	input logic [2*4*32*64-1:0] mem_east_edge_data_i,
	output logic [2*4*32-1:0] mem_east_edge_valid_o,
	output logic [2*4*32*64-1:0] mem_east_edge_data_o,
	input logic [2*4*32-1:0] mem_west_edge_valid_i,
	input logic [2*4*32*64-1:0] mem_west_edge_data_i,
	output logic [2*4*32-1:0] mem_west_edge_valid_o,
	output logic [2*4*32*64-1:0] mem_west_edge_data_o,
	output logic [lpu_pkg::MEM_BANK_COUNT-1:0] mem_fault_o,
	output logic [1:0] mxm_fault_o,
	output logic [1:0] sxm_fault_o,
	output logic vxm_fault_o,
	output logic [1:0] stream_conflict_o
);

	logic [lpu_pkg::MEM_BANK_COUNT-1:0] local_mem_issue_valid;
	logic [lpu_pkg::MEM_BANK_COUNT*lpu_pkg::MEM_INSTRUCTION_WIDTH-1:0] local_mem_issue_instruction;
	logic [lpu_pkg::MEM_BANK_COUNT*32-1:0] local_mem_issue_cycle;
	logic [3:0] local_mxm_load_issue_valid;
	logic [4*29-1:0] local_mxm_load_issue_instruction;
	logic [4*32-1:0] local_mxm_load_issue_cycle;
	logic [3:0] local_mxm_dequant_issue_valid;
	logic [4*16-1:0] local_mxm_dequant_issue_instruction;
	logic [4*32-1:0] local_mxm_dequant_issue_cycle;
	logic [3:0] local_mxm_compute_issue_valid;
	logic [4*49-1:0] local_mxm_compute_issue_instruction;
	logic [4*32-1:0] local_mxm_compute_issue_cycle;

	logic [1:0] endpoint_load_valid;
	logic [1:0] endpoint_load_ready;
	logic [5:0] endpoint_load_control;
	logic [255:0] endpoint_load_data;
	logic [7:0] endpoint_load_strb;
	logic [7:0] endpoint_load_target_kind;
	logic [15:0] endpoint_load_queue_id;
	logic [33:0] endpoint_load_imem_address;
	logic [1:0] endpoint_load_last;
	logic [1:0] endpoint_commit_valid;
	logic [1:0] endpoint_commit_ready;
	logic [1:0] endpoint_commit_error;
	logic endpoint_program_start;
	logic endpoint_program_start_ready;
	logic endpoint_started;
	logic endpoint_frontends_ready;
	logic endpoint_frontends_idle;
	logic endpoint_execution_drained;
	logic endpoint_fault;
	logic [5:0] endpoint_fault_code;
	logic [31:0] endpoint_schedule_cycle;
	logic command_valid, command_ready, rsp_valid, rsp_ready, rsp_last, rsp_error;
	logic [63:0] command_address;
	logic [31:0] command_length;
	logic [7:0] command_id, rsp_id;
	logic [PROGRAM_DMA_DATA_WIDTH-1:0] rsp_data;
	logic [PROGRAM_DMA_DATA_WIDTH/8-1:0] rsp_keep;
	logic admit_epoch, axi_idle, cancel_transport, axi_protocol_error;
	logic control_write_ready, control_load_ready, control_fault, data_fault;
	logic data_fault_q, axi_fault_q;
	logic [5:0] control_fault_code;
	localparam W=DMA_VECTOR_BYTES*8;
	logic pv,pr,prv,prr,pidle;logic [63:0] pa;logic [7:0] pid;
	logic [PROGRAM_DMA_DATA_WIDTH-1:0] pd;logic [1:0] pe;
	logic dv,dr,drv,drr,dlast,re,le,be,dav,dar,dwv,dwr,dwl,dbv;
	logic [63:0] da,dwa;logic [7:0] dl,dwlens;logic [1:0] de,dbe;logic [W-1:0] dd,dwd;
	logic mem_req,mem_ready,mem_write,mem_hem,mem_ret,mem_err;
	logic [6:0] mem_bank;logic [2:0] mem_lane;logic [14:0] mem_row;logic [W-1:0] mem_data,mem_q;
	logic start_wait,desc_failed;
	assign axi_idle=pidle && !dma_busy_o && !dma_isolated_o;
	always_ff @(posedge clk_i or negedge rst_ni)
	  if(!rst_ni)begin start_wait<=0;desc_failed<=0;end
	  else if(program_reload_ack_o)begin start_wait<=0;desc_failed<=0;end
	  else begin
	    if(program_start_request_i && admit_epoch && !program_done_o)start_wait<=1;
	    if(program_start_ack_o)start_wait<=0;
	    if(dma_result_valid_o && dma_result_error_o)desc_failed<=1;
	  end
	lpu_dma_data_channel #(.W(W),.Q(DMA_Q),.RT(DMA_RT),.ROWS(MEM_DEPTH_ROWS),.BANKS(2*ACTIVE_MEM_COLUMNS)) u_data (
	  .clk_i,.rst_ni,.isolated_i(dma_isolated_o),
	  .enable_i(admit_epoch && !start_wait && !program_start_request_i && !program_running_o && endpoint_execution_drained && !program_fault_o),
	  .desc_valid_i(dma_desc_valid_i),.desc_ready_o(dma_desc_ready_o),.store_i(dma_store_i),.hem_i(dma_hem_i),
	  .bank_i(dma_bank_i),.lane_i(dma_lane_i),.row_i(dma_row_i),.addr_i(dma_addr_i),.count_i(dma_count_i),.stride_i(dma_stride_i),.tag_i(dma_tag_i),
	  .busy_o(dma_busy_o),.result_valid_o(dma_result_valid_o),.result_ready_i(dma_result_ready_i),.result_error_o(dma_result_error_o),.result_tag_o(dma_result_tag_o),
	  .mem_req,.mem_ready,.mem_write,.mem_hem,.mem_bank,.mem_lane,.mem_row,.mem_data,.mem_q,.mem_ret,.mem_err,
	  .arvalid(dv),.arready(dr),.araddr(da),.arlen(dl),.rvalid(drv),.rready(drr),.rdata(dd),.rresp(de),.rlast(dlast),
	  .r_expected(re),.last_expected(le),.b_expected(be),.awvalid(dav),.awready(dar),.awaddr(dwa),.awlen(dwlens),
	  .wvalid(dwv),.wready(dwr),.wdata(dwd),.wlast(dwl),.bvalid(dbv),.bresp(dbe));
	lpu_dma_shared_axi #(.W(W),.PW(PROGRAM_DMA_DATA_WIDTH),.RT(DMA_RT),.Q(DMA_Q)) u_shared (
	  .clk_i,.rst_ni,.pv,.pr,.pa,.prv,.prr,.pd,.pe,.dv,.dr,.da,.dl,.drv,.drr,.dd,.de,.dlast,
	  .data_r_expected(re),.data_last_expected(le),.data_b_expected(be),.isolated_o(dma_isolated_o),
	  .d_awvalid(dav),.d_awready(dar),.d_awaddr(dwa),.d_awlen(dwlens),.d_wvalid(dwv),.d_wready(dwr),.d_wdata(dwd),
	  .d_wlast(dwl),.d_bvalid(dbv),.d_bresp(dbe),.*);

	assign program_command_write_ready_o = admit_epoch && control_write_ready;
	assign program_load_start_ready_o = admit_epoch && control_load_ready;
	assign data_fault = endpoint_started &&
	      ((|mem_fault_o) || (|mxm_fault_o) || (|sxm_fault_o) || vxm_fault_o || (|stream_conflict_o));
	assign program_fault_o = control_fault || axi_protocol_error || axi_fault_q || dma_isolated_o || desc_failed;
	assign program_fault_code_o = (axi_protocol_error || axi_fault_q || dma_isolated_o || desc_failed) ? lpu_program_load_pkg::PROGRAM_FAULT_DMA_RESPONSE
	                                                 : control_fault_code;

	lpu_program_epoch_control u_epoch (
		.clk_i, .rst_ni, .reload_valid_i(program_reset_i),
		.reload_ready_o(program_reload_ready_o), .reload_ack_o(program_reload_ack_o),
		.load_fire_i(program_load_start_valid_i && program_load_start_ready_o),
		.start_fire_i(program_start_ack_o), .load_complete_i(program_load_complete_o),
		.segment_done_i(program_done_o), .fault_i(program_fault_o),
		.axi_idle_i(axi_idle), .execution_drained_i(endpoint_execution_drained),
		.admit_o(admit_epoch), .cancel_transport_o(cancel_transport)
	);
	lpu_program_axi_read #(.DATA_WIDTH(PROGRAM_DMA_DATA_WIDTH)) u_program_axi_read (
		.clk_i, .rst_ni, .cancel_i(cancel_transport),
		.command_valid_i(command_valid), .command_ready_o(command_ready),
		.command_address_i(command_address), .command_length_i(command_length), .command_id_i(command_id),
		.response_valid_o(rsp_valid), .response_ready_i(rsp_ready), .response_data_o(rsp_data),
		.response_keep_o(rsp_keep), .response_last_o(rsp_last), .response_id_o(rsp_id),
		.response_error_o(rsp_error), .idle_o(pidle), .protocol_error_o(axi_protocol_error),
		.araddr_o(pa), .arid_o(pid), .arlen_o(),.arsize_o(),.arburst_o(),
		.arvalid_o(pv), .arready_i(pr),.rdata_i(pd), .rid_i(pid), .rresp_i(pe), .rlast_i(1'b1),
		.rvalid_i(prv), .rready_o(prr)
	);

	lpu_program_control_system #(
		.COMMAND_DEPTH(PROGRAM_COMMAND_DEPTH), .DMA_DATA_WIDTH(PROGRAM_DMA_DATA_WIDTH),
		.DMA_RX_FIFO_DEPTH(PROGRAM_DMA_RX_FIFO_DEPTH),
		.DMA_OUTSTANDING_DEPTH(PROGRAM_DMA_OUTSTANDING_DEPTH),
		.MEM_IMEM_DEPTH(PROGRAM_MEM_IMEM_DEPTH), .MXM_IMEM_DEPTH(PROGRAM_MXM_IMEM_DEPTH),
		.ACTIVE_CONTEXTS(PROGRAM_ACTIVE_CONTEXTS), .COMMAND_ADDRESS_WIDTH(PROGRAM_COMMAND_ADDRESS_WIDTH)
	) u_program_control (
		.clk_i, .rst_ni, .program_reset_i(program_reload_ack_o),
		.command_write_valid_i(program_command_write_valid_i && admit_epoch), .command_write_ready_o(control_write_ready),
		.command_write_address_i(program_command_write_address_i), .command_write_opcode_i(program_command_write_opcode_i),
		.command_write_source_address_i(program_command_write_source_address_i), .command_write_byte_count_i(program_command_write_byte_count_i),
		.command_write_target_kind_i(program_command_write_target_kind_i), .command_write_global_queue_id_i(program_command_write_global_queue_id_i),
		.command_write_format_i(program_command_write_format_i), .command_write_encoding_mode_i(program_command_write_encoding_mode_i),
		.command_write_imem_base_address_i(program_command_write_imem_base_address_i), .command_write_image_first_i(program_command_write_image_first_i),
		.command_write_image_last_i(program_command_write_image_last_i), .command_write_expected_word_count_i(program_command_write_expected_word_count_i),
		.command_write_jump_address_i(program_command_write_jump_address_i),
		.load_start_valid_i(program_load_start_valid_i && admit_epoch), .load_start_ready_o(control_load_ready),
		.load_start_command_count_i(program_load_start_command_count_i), .dma_cmd_valid_o(command_valid),
		.dma_cmd_ready_i(command_ready), .dma_cmd_address_o(command_address),
		.dma_cmd_length_o(command_length), .dma_cmd_id_o(command_id),
		.dma_rsp_valid_i(rsp_valid), .dma_rsp_ready_o(rsp_ready),
		.dma_rsp_data_i(rsp_data), .dma_rsp_keep_i(rsp_keep),
		.dma_rsp_last_i(rsp_last), .dma_rsp_id_i(rsp_id), .dma_rsp_error_i(rsp_error),
		.program_start_request_i(program_start_request_i && admit_epoch),
		.dependencies_ready_i(program_dependencies_ready_i && admit_epoch && !dma_busy_o && !program_fault_o &&
		   !(dma_result_valid_o && dma_result_error_o)), .program_start_ack_o,
		.program_load_complete_o, .program_ready_o, .program_running_o, .program_done_o,
		.program_fault_o(control_fault), .program_fault_code_o(control_fault_code), .schedule_cycle_o(program_schedule_cycle_o),
		.endpoint_load_valid_o(endpoint_load_valid), .endpoint_load_ready_i(endpoint_load_ready),
		.endpoint_load_control_o(endpoint_load_control), .endpoint_load_data_o(endpoint_load_data),
		.endpoint_load_strb_o(endpoint_load_strb), .endpoint_load_target_kind_o(endpoint_load_target_kind),
		.endpoint_load_queue_id_o(endpoint_load_queue_id), .endpoint_load_imem_address_o(endpoint_load_imem_address),
		.endpoint_load_last_o(endpoint_load_last),
		.endpoint_commit_valid_i(endpoint_commit_valid), .endpoint_commit_ready_o(endpoint_commit_ready),
		.endpoint_commit_error_i(endpoint_commit_error),
		.endpoint_program_start_o(endpoint_program_start), .endpoint_program_start_ready_i(endpoint_program_start_ready),
		.endpoint_started_i(endpoint_started), .endpoint_frontends_ready_i(endpoint_frontends_ready),
		.endpoint_frontends_idle_i(endpoint_frontends_idle), .endpoint_execution_drained_i(endpoint_execution_drained && axi_idle),
		.endpoint_fault_i(endpoint_fault || data_fault || data_fault_q),
		.endpoint_fault_code_i(endpoint_fault ? endpoint_fault_code : 6'd4),
		.endpoint_schedule_cycle_i(endpoint_schedule_cycle)
	);

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if (!rst_ni) begin
			data_fault_q <= 1'b0;
			axi_fault_q <= 1'b0;
		end else if (program_reload_ack_o) begin
			data_fault_q <= 1'b0;
			axi_fault_q <= 1'b0;
		end else begin
			if (data_fault) data_fault_q <= 1'b1;
			if (axi_protocol_error) axi_fault_q <= 1'b1;
		end
	end
	lpu_fu_subsystem_cluster #(
		.DMA_TILES(DMA_VECTOR_BYTES/8),
		.MEM_IMEM_DEPTH(PROGRAM_MEM_IMEM_DEPTH), .MXM_IMEM_DEPTH(PROGRAM_MXM_IMEM_DEPTH),
		.ACTIVE_CONTEXTS(PROGRAM_ACTIVE_CONTEXTS), .MEM_DEPTH_ROWS(MEM_DEPTH_ROWS),
		.ACTIVE_MEM_COLUMNS(ACTIVE_MEM_COLUMNS), .MXM_ACCUMULATOR_BLOCK_COUNT(MXM_ACCUMULATOR_BLOCK_COUNT),
		.ENABLE_QCTL(ENABLE_QCTL),
		.ENABLE_SXM_VXM_EXECUTION(ENABLE_SXM_VXM_EXECUTION),
		.QCTL_QUEUE_COUNT(QCTL_QUEUE_COUNT)
	) u_fu_subsystems (
		.dma_req_i(mem_req),.dma_ready_o(mem_ready),.dma_write_i(mem_write),.dma_hem_i(mem_hem),.dma_bank_i(mem_bank),
		.dma_lane_i(mem_lane),.dma_row_i(mem_row),.dma_wdata_i(mem_data),.dma_ret_o(mem_ret),.dma_err_o(mem_err),.dma_rdata_o(mem_q),
		.clk_i, .rst_ni, .program_reset_i(program_reload_ack_o),
		.segment_retired_i(program_done_o),
		 .endpoint_load_valid_i(endpoint_load_valid), .endpoint_load_ready_o(endpoint_load_ready),
		.endpoint_load_control_i(endpoint_load_control), .endpoint_load_data_i(endpoint_load_data),
		.endpoint_load_strb_i(endpoint_load_strb), .endpoint_load_target_kind_i(endpoint_load_target_kind),
		.endpoint_load_queue_id_i(endpoint_load_queue_id), .endpoint_load_imem_address_i(endpoint_load_imem_address),
		.endpoint_load_last_i(endpoint_load_last),
		.endpoint_commit_valid_o(endpoint_commit_valid), .endpoint_commit_ready_i(endpoint_commit_ready),
		.endpoint_commit_error_o(endpoint_commit_error),
		.program_start_i(endpoint_program_start), .program_start_ready_o(endpoint_program_start_ready),
		.started_o(endpoint_started), .all_frontends_ready_o(endpoint_frontends_ready),
		.all_frontends_idle_o(endpoint_frontends_idle), .schedule_cycle_o(endpoint_schedule_cycle),
		.execution_drained_o(endpoint_execution_drained),
		.frontend_fault_o(endpoint_fault), .frontend_fault_code_o(endpoint_fault_code),
		.qctl_load_mode_i, .qctl_partition_valid_i, .qctl_partition_ready_o, .qctl_partition_queue_i,
		.qctl_partition_base_i, .qctl_partition_count_i, .qctl_partition_generation_i,
		.qctl_load_valid_i, .qctl_load_ready_o, .qctl_load_address_i, .qctl_load_data_i,
		.qctl_event_valid_i, .qctl_event_ready_o, .qctl_event_tag_i, .qctl_sync_valid_i, .qctl_sync_ready_o,
		.qctl_notify_valid_o, .qctl_notify_ready_i, .qctl_mem_packet_valid_o, .qctl_mem_packet_ordinal_o,
		.qctl_mem_packet_retired_i, .qctl_queue_active_o, .qctl_wait_event_blocked_o, .qctl_wait_event_tag_o,
		.qctl_primed_o, .qctl_done_o, .qctl_fault_o, .qctl_fault_code_o,






		.external_sxm_transpose_issue_valid_i('0), .external_sxm_transpose_issue_instruction_i('0),
		.external_sxm_permute_issue_valid_i('0), .external_sxm_permute_issue_instruction_i('0),
		.external_vxm_local_issue_valid_i('0), .external_vxm_local_issue_instruction_i('0),
		.external_vxm_global_issue_valid_i('0), .external_vxm_global_issue_instruction_i('0),
		.local_mem_issue_valid_o(local_mem_issue_valid), .local_mem_issue_instruction_o(local_mem_issue_instruction),
		.local_mem_issue_cycle_o(local_mem_issue_cycle), .local_mxm_load_issue_valid_o(local_mxm_load_issue_valid),
		.local_mxm_load_issue_instruction_o(local_mxm_load_issue_instruction), .local_mxm_load_issue_cycle_o(local_mxm_load_issue_cycle),
		.local_mxm_dequant_issue_valid_o(local_mxm_dequant_issue_valid), .local_mxm_dequant_issue_instruction_o(local_mxm_dequant_issue_instruction),
		.local_mxm_dequant_issue_cycle_o(local_mxm_dequant_issue_cycle), .local_mxm_compute_issue_valid_o(local_mxm_compute_issue_valid),
		.local_mxm_compute_issue_instruction_o(local_mxm_compute_issue_instruction), .local_mxm_compute_issue_cycle_o(local_mxm_compute_issue_cycle),
		.mem_east_edge_valid_i, .mem_east_edge_data_i,
		.mem_east_edge_valid_o, .mem_east_edge_data_o, .mem_west_edge_valid_i, .mem_west_edge_data_i,
		.mem_west_edge_valid_o, .mem_west_edge_data_o, .mem_fault_o, .mxm_fault_o, .sxm_fault_o,
		.vxm_fault_o, .stream_conflict_o
	);

endmodule
