module lpu_mem_subsystem #(
	parameter integer PACKED_MEM_ROW_BITS = 13,
	parameter integer DMA_TILES = 4,
	parameter integer IMEM_DEPTH = 131072,
	parameter integer ACTIVE_CONTEXTS = 4,
	parameter integer FU_QUEUE_DEPTH = 16,
	parameter integer DEPTH_ROWS = 2048,
	parameter integer ACTIVE_COLUMNS = 52
) (
	input logic clk_i,
	input logic rst_ni,
	input logic dma_req_i,dma_write_i,input logic [6:0] dma_bank_i,input logic [2:0] dma_lane_i,
	input logic [14:0] dma_row_i,input logic [64*DMA_TILES-1:0] dma_wdata_i,
	output logic dma_ready_o,dma_ret_o,dma_err_o,output logic [64*DMA_TILES-1:0] dma_rdata_o,
	input logic program_reset_i,
	input logic run_i,
	input logic [31:0] schedule_cycle_i,
	input logic [lpu_pkg::MEM_BANKS_PER_HEMISPHERE-1:0] qctl_active_i,
	input logic [lpu_pkg::MEM_BANKS_PER_HEMISPHERE-1:0] qctl_scheduler_enable_i,
	input logic [lpu_pkg::MEM_BANKS_PER_HEMISPHERE*32-1:0] qctl_schedule_cycle_i,

	input logic program_valid_i,
	output logic program_ready_o,
	input logic [2:0] program_control_i,
	input logic [7:0] program_queue_id_i,
	input logic [16:0] program_address_i,
	input logic [127:0] program_data_i,
	input logic [3:0] program_strb_i,
	input logic program_last_i,
	output logic program_error_o,

	output logic [lpu_pkg::MEM_BANKS_PER_HEMISPHERE-1:0] local_issue_valid_o,
	output logic [lpu_pkg::MEM_BANKS_PER_HEMISPHERE*lpu_pkg::MEM_INSTRUCTION_WIDTH-1:0] local_issue_instruction_o,
	output logic [lpu_pkg::MEM_BANKS_PER_HEMISPHERE*32-1:0] local_issue_cycle_o,

	output logic frontends_ready_o,
	output logic frontends_idle_o,
	output logic execution_busy_o,
	output logic frontend_fault_o,
	output logic [5:0] frontend_fault_code_o,

	input logic [4*32-1:0] east_edge_valid_i,
	input logic [4*32*64-1:0] east_edge_data_i,
	output logic [4*32-1:0] east_edge_valid_o,
	output logic [4*32*64-1:0] east_edge_data_o,
	input logic [4*32-1:0] west_edge_valid_i,
	input logic [4*32*64-1:0] west_edge_data_i,
	output logic [4*32-1:0] west_edge_valid_o,
	output logic [4*32*64-1:0] west_edge_data_o,

	output logic [lpu_pkg::MEM_BANKS_PER_HEMISPHERE-1:0] mem_fault_o,
	output logic conflict_o
);
    /* verilator hier_block */
	import lpu_program_load_pkg::*;
	localparam integer QUEUE_COUNT = lpu_pkg::MEM_BANKS_PER_HEMISPHERE;
	localparam integer ACTIVE_BANKS = ACTIVE_COLUMNS * 2;

	logic clear_fire_w;
	logic write_fire_w;
	logic prime_fire_w;
	logic selected_load_ready_w;
	logic selected_prime_ready_w;
	logic [QUEUE_COUNT-1:0] load_ready;
	logic [QUEUE_COUNT-1:0] prime_ready;
	logic [QUEUE_COUNT-1:0] frontend_ready;
	logic [QUEUE_COUNT-1:0] frontend_idle;
	logic [QUEUE_COUNT-1:0] frontend_fault;
	logic [QUEUE_COUNT*6-1:0] frontend_fault_code;
	logic [QUEUE_COUNT-1:0] frontend_issue_valid;
	logic [QUEUE_COUNT*lpu_pkg::MEM_INSTRUCTION_WIDTH-1:0] frontend_issue_instruction;
	logic [QUEUE_COUNT*32-1:0] frontend_issue_cycle;
	logic [QUEUE_COUNT-1:0] timed_queue_ready;
	logic [QUEUE_COUNT-1:0] timed_queue_idle;
	logic [QUEUE_COUNT-1:0] timed_queue_fault;
	logic [QUEUE_COUNT-1:0] execution_issue_valid;
	logic [QUEUE_COUNT-1:0] execution_issue_ready;
	logic [QUEUE_COUNT*lpu_pkg::MEM_INSTRUCTION_WIDTH-1:0] execution_issue_instruction;
	logic frontend_rst_ni;

	assign clear_fire_w = program_valid_i && program_ready_o &&
		((program_control_i == PROGRAM_LOAD_CLEAR) || (program_control_i == PROGRAM_LOAD_ABORT));
	assign write_fire_w = program_valid_i && program_ready_o &&
		(program_control_i == PROGRAM_LOAD_WRITE) && (program_strb_i == 4'b0111) &&
		(program_address_i < IMEM_DEPTH);
	assign prime_fire_w = program_valid_i && program_ready_o &&
		(program_control_i == PROGRAM_LOAD_PRIME);
	assign frontend_rst_ni = rst_ni && !program_reset_i && !clear_fire_w;
	assign frontends_ready_o = &frontend_ready;
	assign frontends_idle_o = (&frontend_idle) && (&timed_queue_idle);
	assign frontend_fault_o = (|frontend_fault) || (|timed_queue_fault) || (|mem_fault_o);
	assign frontend_fault_code_o = (|mem_fault_o) ? 6'd3 :
		(((|frontend_fault) || (|timed_queue_fault)) ? 6'd2 : 6'd0);
	assign execution_issue_valid = local_issue_valid_o;
	assign execution_issue_instruction = local_issue_instruction_o;

	// Queue ID is bank-local within one Hemisphere: slice*2+bank, 0..103.
	always_comb begin
		selected_load_ready_w = 1'b0;
		selected_prime_ready_w = 1'b0;
		if(program_queue_id_i < ACTIVE_BANKS)begin
			selected_load_ready_w = load_ready[program_queue_id_i];
			selected_prime_ready_w = prime_ready[program_queue_id_i];
		end
		else begin
			// Invalid destinations are consumed and reported instead of holding
			// Program Load in permanent backpressure.
			selected_load_ready_w = 1'b1;
			selected_prime_ready_w = 1'b1;
		end
		case(program_control_i)
			PROGRAM_LOAD_WRITE: program_ready_o = selected_load_ready_w;
			PROGRAM_LOAD_PRIME: program_ready_o = selected_prime_ready_w;
			PROGRAM_LOAD_CLEAR,
			PROGRAM_LOAD_ABORT: program_ready_o = 1'b1;
			default: program_ready_o = 1'b1;
		endcase
		program_error_o = program_valid_i && program_ready_o &&
			((program_queue_id_i >= ACTIVE_BANKS) ||
			 ((program_control_i == PROGRAM_LOAD_WRITE) &&
			  ((program_strb_i != 4'b0111) || (program_address_i >= IMEM_DEPTH))) ||
			 (program_control_i > PROGRAM_LOAD_ABORT));
	end

	generate
		for(genvar queue_gen = 0; queue_gen < ACTIVE_BANKS; queue_gen++)begin : gen_bank_frontend
			logic [$clog2(FU_QUEUE_DEPTH+1)-1:0] timed_queue_level;
			logic frontend_run;
			logic [31:0] frontend_schedule_cycle;

			// QCTL controls only the selected Bank. The adjacent Bank retains its
			// own local time and can continue independently.
			assign frontend_run = 				(qctl_active_i[queue_gen] ? qctl_scheduler_enable_i[queue_gen] : run_i);
			assign frontend_schedule_cycle = qctl_active_i[queue_gen] ?
				qctl_schedule_cycle_i[queue_gen*32+:32] : schedule_cycle_i;

			lpu_mem_local_imem_frontend #(
		.PACKED_MEM_ROW_BITS(PACKED_MEM_ROW_BITS),
				.IMEM_DEPTH(IMEM_DEPTH),
				.ACTIVE_CONTEXTS(ACTIVE_CONTEXTS)
			) u_frontend (
				.clk_i, .rst_ni, .program_reset_i, .clear_i(clear_fire_w),
				.load_valid_i(write_fire_w && (program_queue_id_i == queue_gen)),
				.load_ready_o(load_ready[queue_gen]), .load_address_i(program_address_i),
				.load_data_i(program_data_i), .load_strb_i(program_strb_i),
				.load_last_i(program_last_i),
				.prime_valid_i(prime_fire_w && (program_queue_id_i == queue_gen)),
				.prime_ready_o(prime_ready[queue_gen]), .run_i(frontend_run),
				.schedule_cycle_i(frontend_schedule_cycle),
				.issue_valid_o(frontend_issue_valid[queue_gen]),
				.issue_ready_i(timed_queue_ready[queue_gen]),
				.issue_instruction_o(frontend_issue_instruction[
					queue_gen*lpu_pkg::MEM_INSTRUCTION_WIDTH+:lpu_pkg::MEM_INSTRUCTION_WIDTH]),
				.issue_cycle_o(frontend_issue_cycle[queue_gen*32+:32]),
				.configured_o(), .frontend_ready_o(frontend_ready[queue_gen]),
				.frontend_idle_o(frontend_idle[queue_gen]),
				.fault_o(frontend_fault[queue_gen]),
				.fault_code_o(frontend_fault_code[queue_gen*6+:6])
			);

			// Timed Queue is the sequential ownership boundary between Macro
			// scheduling and the selected MEM implementation.
			lpu_mem_bank_queue #(.DEPTH(FU_QUEUE_DEPTH)) u_timed_queue (
				.clk_i, .rst_ni(frontend_rst_ni), .run_i(frontend_run),
				.schedule_cycle_i(frontend_schedule_cycle),
				.enqueue_valid_i(frontend_issue_valid[queue_gen]),
				.enqueue_ready_o(timed_queue_ready[queue_gen]),
				.enqueue_instruction_i(frontend_issue_instruction[
					queue_gen*lpu_pkg::MEM_INSTRUCTION_WIDTH+:lpu_pkg::MEM_INSTRUCTION_WIDTH]),
				.enqueue_cycle_i(frontend_issue_cycle[queue_gen*32+:32]),
				.issue_valid_o(local_issue_valid_o[queue_gen]),
				.issue_ready_i(execution_issue_ready[queue_gen]),
				.issue_instruction_o(local_issue_instruction_o[
					queue_gen*lpu_pkg::MEM_INSTRUCTION_WIDTH+:lpu_pkg::MEM_INSTRUCTION_WIDTH]),
				.issue_cycle_o(local_issue_cycle_o[queue_gen*32+:32]),
				.level_o(timed_queue_level), .fault_o(timed_queue_fault[queue_gen])
			);

			assign timed_queue_idle[queue_gen] = timed_queue_level == '0;
		end
		// Reduced physical profiles do not instantiate phantom instruction RAMs.
		// Their global IDs remain reserved and Program Load rejects them above.
		for(genvar q = ACTIVE_BANKS; q < QUEUE_COUNT; q++)begin : gen_inactive_bank
			assign load_ready[q] = 1'b1;
			assign prime_ready[q] = 1'b1;
			assign frontend_ready[q] = 1'b1;
			assign frontend_idle[q] = 1'b1;
			assign frontend_fault[q] = 1'b0;
			assign frontend_fault_code[q*6+:6] = '0;
			assign frontend_issue_valid[q] = 1'b0;
			assign frontend_issue_instruction[q*32+:32] = '0;
			assign frontend_issue_cycle[q*32+:32] = '0;
			assign timed_queue_ready[q] = 1'b1;
			assign timed_queue_idle[q] = 1'b1;
			assign timed_queue_fault[q] = 1'b0;
			assign local_issue_valid_o[q] = 1'b0;
			assign local_issue_instruction_o[q*32+:32] = '0;
			assign local_issue_cycle_o[q*32+:32] = '0;
		end
	endgenerate

    // The local native interface is authoritative: no 47/64-bit translator.
    logic [ACTIVE_BANKS-1:0] native_bank_fault;
    localparam T=DMA_TILES;
    logic [2*16*T-1:0] srf_collision;
    logic [ACTIVE_COLUMNS*2*T-1:0] internal_collision;
    logic [2*16*T*32-1:0] sr_valid;
    logic [(ACTIVE_COLUMNS/4+1)*2*32*T-1:0] consumed;
    logic [ACTIVE_BANKS-1:0] wave_cmd;
    logic [31:0] wave_inst;
    logic [ACTIVE_BANKS*32-1:0] bank_inst;
    logic [T*32-1:0] wave_valid,ev,wv;
    logic [T*32*64-1:0] wave_data,ed,wd,w_in;
    for(genvar k=0;k<ACTIVE_BANKS;k++)
        assign bank_inst[k*32+:32]=wave_cmd[k]?wave_inst:execution_issue_instruction[k*32+:32];
    for(genvar k=0;k<T*32;k++)
        assign w_in[k*64+:64]=wave_valid[k]?wave_data[k*64+:64]:west_edge_data_i[k*64+:64];
    assign east_edge_valid_o=(4*32)'(ev);assign west_edge_valid_o=(4*32)'(wv);
    assign east_edge_data_o=(4*32*64)'(ed);assign west_edge_data_o=(4*32*64)'(wd);
    lpu_dma_mem_wave #(.T(T),.F(ACTIVE_COLUMNS)) u_mem_wave(
      .clk_i,.rst_ni,.req(dma_req_i),.write_i(dma_write_i),.bank_i(dma_bank_i),.lane_i(dma_lane_i),
      .row_i(dma_row_i),.vector_i(dma_wdata_i),.ready(dma_ready_o),.ret(dma_ret_o),.err(dma_err_o),
      .vector_o(dma_rdata_o),.cmd_valid(wave_cmd),.cmd(wave_inst),.sr_valid,.consumed,
      .east_valid(ev),.east_data(ed),.west_valid(wave_valid),.west_data(wave_data),
      .native_fault(|native_bank_fault),.collision(conflict_o));
    logic native_busy;
    assign execution_busy_o = native_busy || (|execution_issue_valid) ||
        (|sr_valid) || (|east_edge_valid_i) || (|west_edge_valid_i);
    initial begin
        if (ACTIVE_COLUMNS < 4 || ACTIVE_COLUMNS > 52 || ACTIVE_COLUMNS % 4 != 0)
            $fatal(1, "ACTIVE_COLUMNS must be a multiple of four in [4,52]");
    end
    assign execution_issue_ready = '1;
    always_comb begin
        mem_fault_o = '0;
        mem_fault_o[ACTIVE_BANKS-1:0] = native_bank_fault;
        for (integer b=ACTIVE_BANKS;b<QUEUE_COUNT;b++)
            mem_fault_o[b] = execution_issue_valid[b];
    end
    assign conflict_o = (|srf_collision) || (|internal_collision) ||
        (|(wave_valid & west_edge_valid_i[T*32-1:0])) || (|(wave_cmd & execution_issue_valid[ACTIVE_BANKS-1:0]));
    lpu_mem_srf_integration #(
        .MEM_SLICES(ACTIVE_COLUMNS), .MEM_DEPTH_ROWS(DEPTH_ROWS),.SUPERLANES(T)
    ) u_native_mem (
        .clk_i, .rst_ni,
        .bank_issue_valid_i(execution_issue_valid[ACTIVE_BANKS-1:0]|wave_cmd),
        .bank_issue_i(bank_inst),
        .boundary_valid_i({west_edge_valid_i[T*32-1:0]|wave_valid,east_edge_valid_i[T*32-1:0]}),
        .boundary_data_i({w_in,east_edge_data_i[T*32*64-1:0]}),
        .boundary_valid_o({wv,ev}),.boundary_data_o({wd,ed}),
        .state_valid_o(sr_valid), .state_data_o(), .mem_boundary_consume_o(consumed),
        .mem_producer_valid_o(), .mem_producer_data_o(), .mem_producer_direction_o(),
        .mem_producer_stream_o(), .mem_producer_boundary_o(),
        .srf_collision_o(srf_collision), .srf_invalid_consume_o(),
        .mem_internal_collision_o(internal_collision),
        .mem_bank_fault_valid_o(native_bank_fault), .mem_fault_valid_o(), .mem_busy_o(native_busy)
    );
endmodule
