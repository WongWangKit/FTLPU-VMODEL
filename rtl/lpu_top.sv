module lpu_top #(
	// 0 selects the native target depth. Explicit smaller simulation depths
	// remain possible without changing packed instruction geometry.
	parameter integer MEM_DEPTH_ROWS = 0,
    parameter integer T = lpu_pkg::TILE_ROWS,
	parameter integer ACTIVE_MEM_COLUMNS = lpu_pkg::mem_slices_per_side_for_tiles(T),
	parameter integer MXM_ACCUMULATOR_BLOCK_COUNT = lpu_pkg::MXM_ACCUMULATOR_BLOCK_COUNT,
	parameter integer PROGRAM_COMMAND_DEPTH = 32,
	parameter integer PROGRAM_DMA_DATA_WIDTH = 256,
    localparam integer DMA_VECTOR_BYTES = lpu_pkg::vector_bytes_for_tiles(T),
    localparam integer PROGRAM_MXMS_PER_HEMISPHERE=lpu_pkg::mxms_per_hemisphere(T),
	// Packed image ABI is independent of reduced physical test SRAM depth.
	parameter integer PACKED_MEM_ROW_BITS=$clog2(lpu_pkg::bank_rows_for_tiles(T)),
	parameter integer DMA_RT=lpu_pkg::dma_mixed_rt(DMA_VECTOR_BYTES),
	parameter integer DMA_Q=lpu_pkg::dma_mixed_q(DMA_VECTOR_BYTES),
	// Number of entries on the ordered program-response interface, not AXI beats.
	parameter integer PROGRAM_DMA_RX_FIFO_DEPTH = lpu_pkg::dma_mixed_program_response(DMA_VECTOR_BYTES),
	parameter integer PROGRAM_DMA_OUTSTANDING_DEPTH = 16,
	parameter integer PROGRAM_MEM_IMEM_DEPTH = lpu_pkg::dma_mixed_mem_imem_depth(DMA_VECTOR_BYTES),
	parameter integer PROGRAM_MXM_IMEM_DEPTH = lpu_pkg::dma_mixed_mxm_imem_depth(DMA_VECTOR_BYTES),
	parameter integer PROGRAM_ACTIVE_CONTEXTS = 4,
	parameter bit ENABLE_QCTL = 1'b0,
	parameter bit ENABLE_STATIC_WEIGHTS = 1'b0,
	parameter bit ENABLE_SXM_VXM_EXECUTION = 1'b1,
	parameter bit LEGACY_MXM = 1'b0,
	parameter bit LEGACY_VECTOR_ARRAY = 1'b1, // legacy images only
	parameter integer QCTL_QUEUE_COUNT = 220,
	parameter integer PROGRAM_COMMAND_ADDRESS_WIDTH = PROGRAM_COMMAND_DEPTH <= 1 ? 1 : $clog2(PROGRAM_COMMAND_DEPTH)
) (
	input logic clk_i,
	input logic rst_ni,
	// A reload request may be queued while running. ACK follows segment end
	// and physical drain; clk_i/rst_ni are shared with the AXI controller port.
	input logic program_reset_i,
	input logic program_cancel_valid_i,
	output logic program_cancel_ready_o,
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
    // Page metadata belongs to the last LOAD descriptor of an ordered group.
    // Configure QCTL partitions for the generation before marking the descriptor.
    input logic dma_page_last_i,
    input logic [31:0] dma_page_event_tag_i,
    input logic [63:0] dma_page_generation_i,
    input logic [QCTL_QUEUE_COUNT-1:0] dma_page_mask_i,
    // Static layout supplied by the linker. A wave grant reserves ALL tiles
    // on the bound bank/SR path; it need not stay high after wave_fire.
    input logic dma_bg_load_i,dma_bg_cancel_i,
    input logic [543:0] dma_bg_command_i,
    output logic dma_bg_reject_o,
    output logic [63:0] dma_bg_cycle_o,dma_bg_image_o,
    input logic [63:0] dma_bg_epoch_i,
    input logic [4*ACTIVE_MEM_COLUMNS-1:0] dma_bg_bank_mask_i,
    output logic dma_bg_wave_valid_o,dma_bg_wave_fire_o,
    output logic [1:0] dma_bg_resident_o,
    // Retirement from the scheduler after last consumer use, not load-done.
    input logic dma_bg_retire_i,dma_bg_retire_slot_i,
    input logic [63:0] dma_bg_retire_page_i,
    input logic [63:0] dma_bg_retire_epoch_i,
    output logic dma_bg_retire_ready_o,
    // Optional resident weight dependency, sampled with START (not a new ISA).
    input logic dma_start_needs_page_i,dma_start_slot_i,
    input logic [63:0] dma_start_generation_i,dma_start_page_i,
	input logic dma_desc_valid_i,output logic dma_desc_ready_o,input logic dma_store_i,dma_hem_i,
	input logic [6:0] dma_bank_i,input logic [2:0] dma_lane_i,input logic [14:0] dma_row_i,
	input logic [63:0] dma_addr_i,input logic [31:0] dma_count_i,dma_stride_i,dma_tag_i,
    input tri0 dma_indexed_i,input logic [63:0] dma_index_addr_i,input logic [31:0] dma_row_limit_i,
    // Expert table is installed by the trusted scheduler before the first lease.
    // On task handshake latch the existing calendar template, whole-page mask
    // and allowed SR streams; DMA obtains all payload addresses from table RAM.
    input tri0 expert_clear_i,expert_word_valid_i,expert_valid_i,expert_done_ready_i,
    input logic [31:0] expert_word_i,expert_stream_mask_i,input logic [10:0] expert_count_i,
    input logic [8:0] expert_segment_count_i,input logic [9:0] expert_id_i,input logic expert_bank_xor_i,
    output logic expert_config_ready_o,expert_ready_o,expert_done_o,expert_error_o,
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

	input logic [2*T*32-1:0] mem_east_edge_valid_i,
	input logic [2*T*32*64-1:0] mem_east_edge_data_i,
	output logic [2*T*32-1:0] mem_east_edge_valid_o,
	output logic [2*T*32*64-1:0] mem_east_edge_data_o,
	input logic [2*T*32-1:0] mem_west_edge_valid_i,
	input logic [2*T*32*64-1:0] mem_west_edge_data_i,
	output logic [2*T*32-1:0] mem_west_edge_valid_o,
	output logic [2*T*32*64-1:0] mem_west_edge_data_o,
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
	// Native interfaces currently implement the two 8-lane project profiles.
    if (T != 2 && T != 4) begin : g_unsupported_profile
      initial $fatal(1, "lpu_top: T=%0d has no executable native profile; see Groq reference geometry", T);
    end
    localparam W=DMA_VECTOR_BYTES*8;
	logic pv,pr,prv,prr,pidle;logic [63:0] pa;logic [7:0] pid;
	logic [PROGRAM_DMA_DATA_WIDTH-1:0] pd;logic [1:0] pe;
	logic dv,dr,drv,drr,dlast,re,le,be,dav,dar,dwv,dwr,dwl,dbv;
	logic [63:0] da,dwa;logic [7:0] dl,dwlens;logic [1:0] de,dbe;logic [W-1:0] dd,dwd;
	logic mem_req,mem_ready,mem_write,mem_hem,mem_ret,mem_err;
	logic [6:0] mem_bank;logic [2:0] mem_lane;logic [14:0] mem_row;logic [W-1:0] mem_data,mem_q;
	logic start_wait,desc_failed,dep_valid,dep_slot;
    logic [63:0] dep_gen,dep_page;
    logic page_pending, page_armed, fabric_ready, pick_page, lock_valid, lock_page;
    logic [QCTL_QUEUE_COUNT-1:0] page_mask;
    logic [31:0] page_tag;
    logic [63:0] page_generation;
    localparam BG_BANKS=4*ACTIVE_MEM_COLUMNS;
    wire ex_busy,ex_valid,ex_partial,raw_reject,result_v;
    wire ex_abort_request=ex_busy && (program_reset_i || (program_cancel_valid_i && program_cancel_ready_o));
    logic ex_cancel_latched,index_work;
    always_ff @(posedge clk_i or negedge rst_ni)
      if(!rst_ni) ex_cancel_latched<=0;
      else if(!ex_busy) ex_cancel_latched<=0;
      else if(ex_abort_request) ex_cancel_latched<=1;
    wire weight_cancel=dma_bg_cancel_i || (ex_busy && (ex_abort_request || ex_cancel_latched));
    logic [QCTL_QUEUE_COUNT-1:0] ex_notify_mask;
    logic [31:0] ex_notify_tag;
    wire [QCTL_QUEUE_COUNT-1:0] notify_mask=ex_busy?ex_notify_mask:dma_page_mask_i;
    wire [543:0] ex_cmd;
    wire [BG_BANKS-1:0] ex_mask;
    wire [543:0] issue_cmd=ex_busy?ex_cmd:dma_bg_command_i;
    wire [BG_BANKS-1:0] issue_mask=ex_busy?ex_mask:dma_bg_bank_mask_i;
    wire issue_valid=ex_busy?ex_valid:dma_desc_valid_i;
    wire result_ack=ex_busy || dma_result_ready_i;
    assign dma_result_valid_o=result_v && !ex_busy;
    assign dma_bg_reject_o=raw_reject && !ex_busy;
    wire bg=ENABLE_STATIC_WEIGHTS && (ex_busy || dma_bg_load_i);
    logic [1:0] leased,resident;
    logic [BG_BANKS-1:0] lease_mask[2];
    logic [63:0] lease_page[2];
    logic [63:0] lease_gen[2];
    logic [63:0] aborted_generation;
    logic bg_active,bg_slot,bg_last,bg_abort;
    // One issuer, one shared data channel. Only the sideband consumer route
    // and whole-page allocation bitmap accompany an already scheduled LOAD.
    wire slot_in=issue_cmd[432],first_in=issue_cmd[433];
    wire last_in=bg?issue_cmd[434]:dma_page_last_i;
    wire [63:0] page_in=issue_cmd[127:64];
    wire [63:0] gen_in=bg?issue_cmd[63:0]:dma_page_generation_i;
    wire sc_valid,sc_ready,sc_cancel,sc_bind_ready,sc_req,sc_mem_ready;
    wire sc_hem;wire [6:0] sc_bank;wire [2:0] sc_lane;wire [4:0] sc_stream,active_stream;
    wire [14:0] sc_row,sc_step;wire [31:0] sc_count,sc_stride,sc_tag;wire [63:0] sc_addr;
    wire ch_ready;
    wire dh=bg?sc_hem:dma_hem_i;
    wire [6:0] db=bg?sc_bank:dma_bank_i;
    wire [31:0] dest_bank=(dh ? BG_BANKS/2 : 0)+db;
    wire same_page=lease_page[slot_in]==page_in && lease_gen[slot_in]==gen_in;
    wire bg_legal=gen_in>aborted_generation && db<BG_BANKS/2 &&
        issue_mask[dest_bank] &&
        (first_in ? (!leased[slot_in] && (gen_in>lease_gen[slot_in] ||
          (gen_in==lease_gen[slot_in] && page_in>lease_page[slot_in])) &&
          !(|(issue_mask & lease_mask[!slot_in]))) :
          (leased[slot_in] && !resident[slot_in] && same_page && issue_mask==lease_mask[slot_in]));
    wire ordinary_ok=!ENABLE_STATIC_WEIGHTS || dma_bank_i>=BG_BANKS/2 ||
        ((!lease_mask[0][dest_bank] || (dma_store_i && resident[0])) &&
         (!lease_mask[1][dest_bank] || (dma_store_i && resident[1])));
    logic native_mem_ready;
    assign mem_ready=bg_active?sc_mem_ready:native_mem_ready;
    wire native_req=bg_active?sc_req:mem_req;
    wire desc_fire=bg?(sc_valid && ch_ready):(dma_desc_valid_i && ch_ready);
    assign dma_desc_ready_o=!ex_busy && (bg?sc_ready:ch_ready);
    logic [63:0] bound_generation;
    logic last_was_bg;
    // Ordinary tensor loads do not borrow an execution calendar. A stalled
    // ordinary R must NOT prevent the program AR from using the shared master.
    wire bind_boundary=!ex_busy && !program_running_o && endpoint_execution_drained && !bg_active &&
        !(last_was_bg && (dma_result_valid_o || page_armed || page_pending));
    wire bind_fire=ENABLE_STATIC_WEIGHTS && program_load_start_valid_i && program_load_start_ready_o;
    always_ff @(posedge clk_i or negedge rst_ni)
      if(!rst_ni)begin bound_generation<=0;dma_bg_cycle_o<=0;last_was_bg<=0;end
      else begin dma_bg_cycle_o<=dma_bg_cycle_o+1'b1;
        if(desc_fire)last_was_bg<=bg;
        if(program_reload_ack_o)bound_generation<=0;
        else if(bind_fire)bound_generation<=dma_bg_epoch_i;
      end
    lpu_dma_weight_schedule_port #(.T(T),.F(ACTIVE_MEM_COLUMNS)) u_weight_schedule(
      .clk_i,.rst_ni,.generation_i(bound_generation),.image_generation_i(dma_bg_epoch_i),.cycle_i(dma_bg_cycle_o),
      // A cancelled program-only read still changes image serial on rearm;
      // it has no weight lease whose generation must be invalidated.
      .cancel_i(((bg_active || (|leased)) && (cancel_transport || program_fault_o)) ||
                ((bg || bg_active) && weight_cancel)),
      .image_activate_i(bind_fire),.image_activate_ready_o(sc_bind_ready),.image_id_o(dma_bg_image_o),
      .valid_i(bg && issue_valid),.cmd_i(issue_cmd),.ready_o(sc_ready),.reject_o(raw_reject),
      .desc_valid_o(sc_valid),.desc_ready_i(bg && ch_ready),.hem_o(sc_hem),.bank_o(sc_bank),.lane_o(sc_lane),
      .stream_o(sc_stream),.row_o(sc_row),.row_stride_o(sc_step),.count_o(sc_count),.ddr_stride_o(sc_stride),
      .tag_o(sc_tag),.addr_o(sc_addr),.mem_req_i(mem_req && bg_active),.mem_bank_i(mem_bank),.mem_lane_i(mem_lane),
      .mem_hem_i(mem_hem),.mem_stream_i(active_stream),.native_ready_i(native_mem_ready),.native_req_o(sc_req),
      .mem_ready_o(sc_mem_ready),.channel_cancel_o(sc_cancel),.result_valid_i(result_v && !dma_isolated_o),
      .result_ready_i(result_ack));
    assign dma_bg_wave_valid_o=bg_active && mem_req;
    assign dma_bg_wave_fire_o=dma_bg_wave_valid_o && mem_ready;
    assign dma_bg_resident_o=resident;
    wire demand=start_wait?dep_valid:dma_start_needs_page_i;
    wire demand_slot=start_wait?dep_slot:dma_start_slot_i;
    wire [63:0] demand_gen=start_wait?dep_gen:dma_start_generation_i;
    wire [63:0] demand_page=start_wait?dep_page:dma_start_page_i;
    wire start_page_ready=!ENABLE_STATIC_WEIGHTS || !demand ||
        (resident[demand_slot] && bound_generation==demand_gen && lease_gen[demand_slot]==demand_gen &&
         lease_page[demand_slot]==demand_page);
    assign dma_bg_retire_ready_o=ENABLE_STATIC_WEIGHTS && !ex_busy && resident[dma_bg_retire_slot_i] &&
        lease_gen[dma_bg_retire_slot_i]==dma_bg_retire_epoch_i &&
        lease_page[dma_bg_retire_slot_i]==dma_bg_retire_page_i && !dma_busy_o && !page_pending &&
        !((start_wait || program_start_request_i) && demand && demand_slot==dma_bg_retire_slot_i) &&
        !(program_running_o && dep_valid && dep_slot==dma_bg_retire_slot_i);
    // A drained failed task cannot be resurrected by replaying its descriptor.
    // A successful program segment re-arm does not retire the entire generation.
    always_ff @(posedge clk_i or negedge rst_ni)
      if(!rst_ni) aborted_generation<='0;
      else if(program_reload_ack_o && bg_abort)
        aborted_generation<=lease_gen[0]>lease_gen[1]?lease_gen[0]:lease_gen[1];
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if(!rst_ni) begin
        leased<=0;resident<=0;bg_active<=0;bg_slot<=0;bg_last<=0;bg_abort<=0;
        for(int i=0;i<2;i++)begin lease_mask[i]<='0;lease_gen[i]<=0;lease_page[i]<=0;end
      end else if(program_reload_ack_o) begin
        // Clean single-iMEM rearm does not erase successfully prefetched
        // SRAM. Drop incomplete/failed leases; keep full page identity.
        for(int i=0;i<2;i++)if(!resident[i] || bg_abort || program_fault_o || cancel_transport)begin
          leased[i]<=0;resident[i]<=0;lease_mask[i]<='0;
        end
        bg_active<=0;bg_slot<=0;bg_last<=0;bg_abort<=0;
      end else begin
        if(bind_fire)for(int i=0;i<2;i++)if(lease_gen[i]!=dma_bg_epoch_i)begin
          leased[i]<=0;resident[i]<=0;lease_mask[i]<='0;
        end
        if(dma_bg_retire_i && dma_bg_retire_ready_o)begin
          leased[dma_bg_retire_slot_i]<=0;resident[dma_bg_retire_slot_i]<=0;lease_mask[dma_bg_retire_slot_i]<='0;
        end
        if(desc_fire)begin
          bg_active<=bg; bg_slot<=slot_in;bg_last<=last_in;
          if(bg && first_in)begin
          leased[slot_in]<=1;lease_mask[slot_in]<=issue_mask;
            lease_gen[slot_in]<=gen_in;lease_page[slot_in]<=page_in;
          end
        end
        if(ex_partial)bg_abort<=1;
        if(bg_active && result_v)begin
          bg_active<=0;
          if(dma_result_error_o || weight_cancel) bg_abort<=1;
          if(bg_last && !dma_result_error_o && !weight_cancel && !program_fault_o && !cancel_transport && !dma_isolated_o)
            resident[bg_slot]<=1;
        end
        if(cancel_transport || program_fault_o || dma_isolated_o) resident<=0;
      end
    end
    // Both sources obey VALID/READY; hold the selected source until accepted.
    assign pick_page=ENABLE_QCTL && (lock_valid ? lock_page : page_pending);
    assign qctl_event_ready_o=fabric_ready && !pick_page;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if(!rst_ni)begin page_pending<=0;page_armed<=0;lock_valid<=0;lock_page<=0;
        page_mask<='0;page_tag<='0;page_generation<='0;end
      else if(program_reload_ack_o)begin page_pending<=0;page_armed<=0;lock_valid<=0;end
      else begin
        if((pick_page || qctl_event_valid_i) && !fabric_ready)begin
          lock_valid<=1;lock_page<=pick_page;
        end else lock_valid<=0;
        if(pick_page && fabric_ready)page_pending<=0;
        if(desc_fire)begin
          page_armed<=ENABLE_QCTL && last_in && (bg || !dma_store_i) && (!bg || (|notify_mask));
          page_mask<=notify_mask;page_tag<=ex_busy?ex_notify_tag:dma_page_event_tag_i;
          page_generation<=gen_in;
        end
        // Result VALID follows the final mem_ret (not RLAST or descriptor issue).
        // Disarm on first observation, independently of the host result READY.
        if(page_armed && result_v)begin
          page_armed<=0;
          if(!dma_result_error_o && !(bg_active && weight_cancel) && !desc_failed && !dma_isolated_o && !program_fault_o && !cancel_transport)
            page_pending<=1;
        end
      end
    end
	assign axi_idle=pidle && !ex_busy && !ex_partial && !dma_busy_o && !dma_isolated_o &&
        !(last_was_bg && (dma_result_valid_o || (!cancel_transport && (page_pending || page_armed))));
	always_ff @(posedge clk_i or negedge rst_ni)
	  if(!rst_ni)begin start_wait<=0;desc_failed<=0;dep_valid<=0;dep_slot<=0;dep_gen<=0;dep_page<=0;end
	  else if(program_reload_ack_o)begin start_wait<=0;desc_failed<=0;dep_valid<=0;end
	  else begin
	    if(program_start_request_i && !start_wait && admit_epoch && !program_done_o)begin
          start_wait<=1;dep_valid<=dma_start_needs_page_i;dep_slot<=dma_start_slot_i;
          dep_gen<=dma_start_generation_i;dep_page<=dma_start_page_i;
        end
	    if(program_start_ack_o)start_wait<=0;
	    if(result_v && dma_result_error_o)desc_failed<=1;
	  end
	localparam integer NATIVE_MEM_ROWS = MEM_DEPTH_ROWS==0 ? lpu_pkg::bank_rows_for_tiles(T) : MEM_DEPTH_ROWS;
    always_ff @(posedge clk_i or negedge rst_ni)
      if(!rst_ni) index_work<=0;
      else if(desc_fire) index_work<=!bg && dma_indexed_i;
      else if(!dma_busy_o) index_work<=0;
	lpu_dma_data_channel #(.W(W),.Q(DMA_Q),.RT(DMA_RT),.ROWS(NATIVE_MEM_ROWS),.BANKS(2*ACTIVE_MEM_COLUMNS),.EXPLICIT_MEM_LAYOUT(1)) u_data (
	  .clk_i,.rst_ni,.isolated_i(dma_isolated_o),
	  .cancel_i((bg_active && sc_cancel) || (index_work && (cancel_transport || (program_cancel_valid_i && program_cancel_ready_o)))),
	  .enable_i(admit_epoch && !ex_partial && !page_pending && !page_armed &&
              (bg || (!start_wait && !program_start_request_i)) && !program_fault_o &&
	            (bg ? bg_legal && (program_running_o || endpoint_execution_drained) :
	                  ordinary_ok && !program_running_o && endpoint_execution_drained)),
	  .desc_valid_i(bg?sc_valid:dma_desc_valid_i),.desc_ready_o(ch_ready),.store_i(!bg && dma_store_i),.hem_i(dh),
      .indexed_i(!bg && dma_indexed_i),.index_addr_i(dma_index_addr_i),.row_limit_i(dma_row_limit_i),
	  .bank_i(db),.lane_i(bg?sc_lane:dma_lane_i),.row_i(bg?sc_row:dma_row_i),.addr_i(bg?sc_addr:dma_addr_i),
	  .count_i(bg?sc_count:dma_count_i),.stride_i(bg?sc_stride:dma_stride_i),.tag_i(bg?sc_tag:dma_tag_i),
      .row_stride_i(bg?sc_step:15'd1),.fabric_stream_i(bg?sc_stream:(dma_store_i?5'(dma_lane_i):5'd24+dma_lane_i)),
      .mem_stream(active_stream),
	  .busy_o(dma_busy_o),.result_valid_o(result_v),.result_ready_i(result_ack),.result_error_o(dma_result_error_o),.result_tag_o(dma_result_tag_o),
	  .mem_req,.mem_ready,.mem_write,.mem_hem,.mem_bank,.mem_lane,.mem_row,.mem_data,.mem_q,.mem_ret,.mem_err,
	  .arvalid(dv),.arready(dr),.araddr(da),.arlen(dl),.rvalid(drv),.rready(drr),.rdata(dd),.rresp(de),.rlast(dlast),
	  .r_expected(re),.last_expected(le),.b_expected(be),.awvalid(dav),.awready(dar),.awaddr(dwa),.awlen(dwlens),
	  .wvalid(dwv),.wready(dwr),.wdata(dwd),.wlast(dwl),.bvalid(dbv),.bresp(dbe));
    always_ff @(posedge clk_i) if(expert_valid_i && expert_ready_o)begin
      ex_notify_mask<=dma_page_mask_i;ex_notify_tag<=dma_page_event_tag_i;end
    lpu_dma_expert_loader #(.F(ACTIVE_MEM_COLUMNS),.V(DMA_VECTOR_BYTES),.ROWS(NATIVE_MEM_ROWS)) u_expert(
      .clk_i,.rst_ni,.clear_i(expert_clear_i),.word_valid_i(expert_word_valid_i),.word_i(expert_word_i),
      .experts_i(expert_count_i),.segments_i(expert_segment_count_i),.config_ready_o(expert_config_ready_o),
      .task_valid_i(expert_valid_i),.task_ready_o(expert_ready_o),.expert_i(expert_id_i),.xor_i(expert_bank_xor_i),
      .template_i(dma_bg_command_i),.banks_i(dma_bg_bank_mask_i),.streams_i(expert_stream_mask_i),
      .available_i(ENABLE_STATIC_WEIGHTS && admit_epoch && !ex_partial && !dma_desc_valid_i && !dma_busy_o && !result_v &&
        !page_armed && !page_pending && !program_load_start_valid_i && !dma_bg_retire_i && !program_reset_i),
      .config_safe_i(ENABLE_STATIC_WEIGHTS && !dma_desc_valid_i && !dma_busy_o && !result_v),
      .cancel_i(cancel_transport || program_fault_o || dma_isolated_o || weight_cancel),
      .resident_i(resident),.leased_i(leased),.generation_i(bound_generation),.image_i(dma_bg_image_o),.cycle_i(dma_bg_cycle_o),
      .busy_o(ex_busy),.valid_o(ex_valid),.command_o(ex_cmd),.mask_o(ex_mask),.accepted_i(ex_busy && desc_fire),
      .rejected_i(raw_reject || (ex_valid && !bg_legal)),.result_i(result_v || dma_isolated_o),.error_i(dma_result_error_o || dma_isolated_o),
      .failed_partial_o(ex_partial),.done_o(expert_done_o),.error_o(expert_error_o),.done_ready_i(expert_done_ready_i));
	lpu_dma_shared_axi #(.W(W),.PW(PROGRAM_DMA_DATA_WIDTH),.RT(DMA_RT),.Q(DMA_Q)) u_shared (
	  .clk_i,.rst_ni,.pv,.pr,.pa,.prv,.prr,.pd,.pe,.dv,.dr,.da,.dl,.drv,.drr,.dd,.de,.dlast,
	  .data_r_expected(re),.data_last_expected(le),.data_b_expected(be),.isolated_o(dma_isolated_o),
	  .d_awvalid(dav),.d_awready(dar),.d_awaddr(dwa),.d_awlen(dwlens),.d_wvalid(dwv),.d_wready(dwr),.d_wdata(dwd),
	  .d_wlast(dwl),.d_bvalid(dbv),.d_bresp(dbe),.*);

	assign program_command_write_ready_o = admit_epoch && control_write_ready;
	wire load_permitted=admit_epoch && (!ENABLE_STATIC_WEIGHTS || (bind_boundary && sc_bind_ready));
	assign program_load_start_ready_o = load_permitted && control_load_ready;
	assign data_fault = endpoint_started &&
	      ((|mem_fault_o) || (|mxm_fault_o) || (|sxm_fault_o) || vxm_fault_o || (|stream_conflict_o));
	assign program_fault_o = control_fault || axi_protocol_error || axi_fault_q || dma_isolated_o || desc_failed || bg_abort;
	assign program_fault_code_o = (axi_protocol_error || axi_fault_q || dma_isolated_o || desc_failed) ? lpu_program_load_pkg::PROGRAM_FAULT_DMA_RESPONSE
	                                                 : control_fault_code;

	lpu_program_epoch_control u_epoch (
		.clk_i, .rst_ni, .reload_valid_i(program_reset_i),
		.cancel_valid_i(program_cancel_valid_i),.cancel_ready_o(program_cancel_ready_o),
		.reload_ready_o(program_reload_ready_o), .reload_ack_o(program_reload_ack_o),
		.load_fire_i(program_load_start_valid_i && program_load_start_ready_o),
		.start_fire_i(program_start_ack_o), .load_complete_i(program_load_complete_o),
		.segment_done_i(program_done_o), .fault_i(program_fault_o),
		// An attributable tensor BRESP fails the descriptor, but never
		// sets bg_abort. Unknown-ID / protocol faults stay isolated.
		.drained_bg_abort_i((bg_abort || desc_failed) && !dma_isolated_o && !axi_protocol_error && !axi_fault_q),
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
        .MXMS_PER_HEMISPHERE(PROGRAM_MXMS_PER_HEMISPHERE),
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
		.load_start_valid_i(program_load_start_valid_i && load_permitted), .load_start_ready_o(control_load_ready),
		.load_start_command_count_i(program_load_start_command_count_i), .dma_cmd_valid_o(command_valid),
		.dma_cmd_ready_i(command_ready), .dma_cmd_address_o(command_address),
		.dma_cmd_length_o(command_length), .dma_cmd_id_o(command_id),
		.dma_rsp_valid_i(rsp_valid), .dma_rsp_ready_o(rsp_ready),
		.dma_rsp_data_i(rsp_data), .dma_rsp_keep_i(rsp_keep),
		.dma_rsp_last_i(rsp_last), .dma_rsp_id_i(rsp_id), .dma_rsp_error_i(rsp_error),
		.program_start_request_i(program_start_request_i && admit_epoch),
		.dependencies_ready_i(program_dependencies_ready_i && start_page_ready && admit_epoch && !dma_busy_o && !program_fault_o &&
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
		.endpoint_fault_i(endpoint_fault || data_fault || data_fault_q || bg_abort),
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
		.PACKED_MEM_ROW_BITS(PACKED_MEM_ROW_BITS),
		.DMA_TILES(T),
		.MEM_IMEM_DEPTH(PROGRAM_MEM_IMEM_DEPTH), .MXM_IMEM_DEPTH(PROGRAM_MXM_IMEM_DEPTH),
		.ACTIVE_CONTEXTS(PROGRAM_ACTIVE_CONTEXTS), .MEM_DEPTH_ROWS(NATIVE_MEM_ROWS),
		.ACTIVE_MEM_COLUMNS(ACTIVE_MEM_COLUMNS), .MXM_ACCUMULATOR_BLOCK_COUNT(MXM_ACCUMULATOR_BLOCK_COUNT),
		.ENABLE_QCTL(ENABLE_QCTL),
		.ENABLE_SXM_VXM_EXECUTION(ENABLE_SXM_VXM_EXECUTION),.LEGACY_MXM(LEGACY_MXM),
		.LEGACY_VECTOR_ARRAY(LEGACY_VECTOR_ARRAY),
		.QCTL_QUEUE_COUNT(QCTL_QUEUE_COUNT)
	) u_fu_subsystems (
		.dma_req_i(native_req),.dma_ready_o(native_mem_ready),.dma_write_i(mem_write),.dma_hem_i(mem_hem),.dma_bank_i(mem_bank),
		.dma_stream_i(active_stream),.dma_row_i(mem_row),.dma_wdata_i(mem_data),.dma_ret_o(mem_ret),.dma_err_o(mem_err),.dma_rdata_o(mem_q),
		.clk_i, .rst_ni, .program_reset_i(program_reload_ack_o),
		.discard_partial_sums_i(program_reload_ack_o && (desc_failed || bg_abort)),
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
		.qctl_event_valid_i(pick_page || qctl_event_valid_i), .qctl_event_ready_o(fabric_ready),
        .qctl_event_tag_i(pick_page?page_tag:qctl_event_tag_i),.qctl_event_mask_i(pick_page?page_mask:qctl_event_mask_i),
        .qctl_event_generation_i(pick_page?page_generation:qctl_event_generation_i),.qctl_event_phase_i(pick_page || qctl_event_phase_i),.qctl_receipt_valid_o,.qctl_receipt_ready_i,.qctl_receipt_tag_o,.qctl_receipt_generation_o,.qctl_receipt_cycle_o, .qctl_sync_valid_i, .qctl_sync_ready_o,
		.qctl_notify_valid_o, .qctl_notify_ready_i, .qctl_mem_packet_valid_o, .qctl_mem_packet_ordinal_o,
		.qctl_mem_packet_retired_i, .qctl_queue_active_o, .qctl_wait_event_blocked_o, .qctl_wait_event_tag_o,
		.qctl_primed_o, .qctl_done_o, .qctl_fault_o, .qctl_fault_code_o,

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
