// Program-facing ROW path. Target 5 stores CTRL; target 6 stores EXEC.
// Batch WriteTap remains in lpu_sxm_subsystem; raw 416-bit compatibility is
// retained at sxm_triangle_full_core, not interpreted as native Program payload.
module lpu_sxm_native_subsystem #(
	parameter integer T = 4,
	parameter integer EVENT_DEPTH = 64
) (
	input logic clk_i,
	input logic rst_ni,
	input logic program_reset_i,
	input logic program_valid_i,
	output logic program_ready_o,
	output logic program_error_o,
	input logic program_control_i,
	input logic [lpu_program_load_pkg::PROGRAM_DESTINATION_WIDTH-1:0] program_destination_i,
	input logic [16:0] program_address_i,
	input logic [127:0] program_data_i,
	input logic [3:0] program_strb_i,
	input logic program_last_i,
	input logic run_i,
	input logic [31:0] schedule_cycle_i,
	output logic frontend_ready_o,
	output logic frontend_idle_o,
	input logic [T*32-1:0] east_inner_valid_i,
	input logic [T*32-1:0] west_outer_valid_i,
	input logic [T*32*64-1:0] east_inner_data_i,
	input logic [T*32*64-1:0] west_outer_data_i,
	output logic [T*32-1:0] east_outer_valid_o,
	output logic [T*32-1:0] west_inner_valid_o,
	output logic [T*32*64-1:0] east_outer_data_o,
	output logic [T*32*64-1:0] west_inner_data_o,
	output logic fault_o,
	output logic conflict_o
);
	import lpu_program_load_pkg::*;
	localparam integer PORTS = 32;
	logic local_rst_ni, target_ctrl_w, target_exec_w, target_legal_w;
	logic program_fire_w, write_fire_w, prime_fire_w;
	logic ctrl_issue, exec_issue;
	logic [127:0] ctrl_word, exec_word;
	logic [31:0] ctrl_aux, exec_aux;
	logic [1:0] calendar_ready, calendar_idle, calendar_fault;
	logic [T*PORTS*6-1:0] read_selector, write_selector;
	logic [T*PORTS-1:0] read_valid, consume, write_valid;
	logic [T*PORTS*64-1:0] read_data, write_data;
	logic [3:0] row_fault, compat_fault;
	logic row_busy, batch_fault, boundary_conflict, execution_fault_q;
	logic protocol_fault_w;

	assign local_rst_ni = rst_ni && !program_reset_i;
	assign target_ctrl_w = program_destination_i[11:8] == PROGRAM_TARGET_SXM_TRANSPOSE;
	assign target_exec_w = program_destination_i[11:8] == PROGRAM_TARGET_SXM_PERMUTE;
	assign target_legal_w = (target_ctrl_w || target_exec_w) && program_destination_i[7:0] == 0;
	assign program_ready_o = !run_i && !fault_o;
	assign program_fire_w = program_valid_i && program_ready_o;
	assign write_fire_w = program_fire_w && target_legal_w && program_control_i == PROGRAM_LOAD_WRITE;
	assign prime_fire_w = program_fire_w && target_legal_w && program_control_i == PROGRAM_LOAD_PRIME;
	assign program_error_o = fault_o || (program_valid_i && !target_legal_w);
	assign frontend_ready_o = (&calendar_ready) && !fault_o;
	// Completion includes the P pipeline and finite RUN, not just consumed tables.
	assign frontend_idle_o = (&calendar_idle) && !row_busy;
	assign fault_o = (|calendar_fault) || execution_fault_q;
	assign conflict_o = boundary_conflict;
	assign protocol_fault_w = (program_fire_w && !target_legal_w) ||
		(exec_issue && ((exec_word[127:81] != 0) || ((exec_word[35:32] >> T) != 0)));

	lpu_sxm_native_issue_calendar #(
		.DEPTH(EVENT_DEPTH),
		.PAYLOAD_BITS(128),
		.AUX_BITS(6)
	) u_ctrl_calendar (
		.clk_i,
		.rst_ni(local_rst_ni),
		.write_i(write_fire_w && target_ctrl_w),
		.prime_i(prime_fire_w && target_ctrl_w),
		.run_i(run_i && !fault_o),
		.address_i(program_address_i),
		.data_i(program_data_i),
		.strb_i(program_strb_i),
		.last_i(program_last_i),
		.cycle_i(schedule_cycle_i),
		.payload_o(ctrl_word),
		.auxiliary_o(ctrl_aux),
		.issue_o(ctrl_issue),
		.ready_o(calendar_ready[0]),
		.idle_o(calendar_idle[0]),
		.fault_o(calendar_fault[0])
	);
	lpu_sxm_native_issue_calendar #(
		.DEPTH(EVENT_DEPTH),
		.PAYLOAD_BITS(81),
		.AUX_BITS(0)
	) u_exec_calendar (
		.clk_i,
		.rst_ni(local_rst_ni),
		.write_i(write_fire_w && target_exec_w),
		.prime_i(prime_fire_w && target_exec_w),
		.run_i(run_i && !fault_o),
		.address_i(program_address_i),
		.data_i(program_data_i),
		.strb_i(program_strb_i),
		.last_i(program_last_i),
		.cycle_i(schedule_cycle_i),
		.payload_o(exec_word),
		.auxiliary_o(exec_aux),
		.issue_o(exec_issue),
		.ready_o(calendar_ready[1]),
		.idle_o(calendar_idle[1]),
		.fault_o(calendar_fault[1])
	);

	lpu_sxm_stream_boundary #(
		.T(T),
		.PORTS(PORTS)
	) u_stream_boundary (
		.clk_i,
		.rst_ni(local_rst_ni),
		.run_i(run_i && !fault_o),
		.east_valid_i(east_inner_valid_i),
		.east_data_i(east_inner_data_i),
		.west_valid_i(west_outer_valid_i),
		.west_data_i(west_outer_data_i),
		.east_valid_o(east_outer_valid_o),
		.east_data_o(east_outer_data_o),
		.west_valid_o(west_inner_valid_o),
		.west_data_o(west_inner_data_o),
		.read_sel_i(read_selector),
		.read_valid_o(read_valid),
		.read_data_o(read_data),
		.consume_i(consume),
		.write_valid_i(write_valid),
		.write_sel_i(write_selector),
		.write_data_i(write_data),
		.conflict_o(boundary_conflict)
	);

	// Native payload fields are wired once; CTRL and EXEC may issue together.
	sxm_triangle_full_core #(
		.T(T),
		.PORT_STREAMS(PORTS)
	) u_execution (
		.clk_i,
		.rst_ni(local_rst_ni),
		.ctrl_valid_i(ctrl_issue),
		.ctrl_op_i(ctrl_aux[1:0]),
		.ctrl_ctx_i(ctrl_aux[2]),
		.ctrl_index_i(ctrl_aux[5:3]),
		.ctrl_data_i(ctrl_word),
		.cap_valid_i(exec_issue && exec_word[0]),
		.cap_ctx_i(exec_word[1]),
		.cap_tile_i(exec_word[4:2]),
		.cap_group_i(exec_word[7:5]),
		.cap_row_i(exec_word[11:8]),
		.p_valid_i(exec_issue && exec_word[12]),
		.p_ctx_i(exec_word[13]),
		.p_dest_i(exec_word[16:14]),
		.p_source_i(exec_word[19:17]),
		.p_row_i(exec_word[23:20]),
		.p_paired_i(exec_word[24]),
		.p_branch_i(exec_word[25]),
		.p_sequence_i(exec_word[31:26]),
		.run_valid_i(exec_word[32+:T] & {T{exec_issue}}),
		.run_ctx_i(exec_word[36]),
		.run_delay_i(exec_word[52:37]),
		.run_interval_i(exec_word[68:53]),
		.run_count_i(exec_word[74:69]),
		.run_sequence_i(exec_word[80:75]),
		.sr_read_req_o(read_selector),
		.sr_read_valid_i(read_valid),
		.sr_read_data_i(read_data),
		.sr_consume_o(consume),
		.sr_write_valid_o(write_valid),
		.sr_write_sel_o(write_selector),
		.sr_write_data_o(write_data),
		.fault_o(row_fault),
		.busy_o(row_busy),
		.compat_t_valid_i(1'b0),
		.compat_p_valid_i(1'b0),
		.compat_t_family_i('0),
		.compat_p_family_i('0),
		.compat_t_raw_i('0),
		.compat_p_raw_i('0),
		.compat_fault_o(compat_fault),
		.batch_job_i(1'b0),
		.batch_mode_i('0),
		.batch_dtype_i('0),
		.batch_count_i('0),
		.batch_lane_map_i('0),
		.batch_tile_map_i('0),
		.batch_ready_o(),
		.batch_fault_o(batch_fault),
		.batch_cap_valid_i('0),
		.batch_lane_valid_i('0),
		.batch_cap_data_i('0),
		.batch_cap_accept_o(),
		.batch_block_ready_i('0),
		.batch_block_valid_o(),
		.batch_block_fp32_o(),
		.batch_block_vector_o(),
		.batch_block_data_o(),
		.batch_block_matrix_o(),
		.batch_block_column_o()
	);

	// Keep the first execution/protocol failure until Program Reset; never replay it.
	always_ff @(posedge clk_i or negedge local_rst_ni)begin
		if(!local_rst_ni)begin
			execution_fault_q <= 1'b0;
		end
		else begin
			if((|row_fault) || (|compat_fault) || batch_fault || protocol_fault_w || boundary_conflict)begin
				execution_fault_q <= 1'b1;
			end
		end
	end
endmodule
