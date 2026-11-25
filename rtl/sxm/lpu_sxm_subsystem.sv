module lpu_sxm_subsystem #(parameter integer T=4) (
	input logic clk_i,
	input logic rst_ni,
	input logic run_i,
	input logic ctrl_issue_i, exec_issue_i,
	input logic [127:0] ctrl_word_i, exec_word_i,
	input logic [31:0] ctrl_aux_i,
	output wire busy_o,
	input logic [T*32-1:0] east_inner_valid_i,
	input logic [T*32*64-1:0] east_inner_data_i,
	output logic [T*32-1:0] east_outer_valid_o,
	output logic [T*32*64-1:0] east_outer_data_o,
	input logic [T*32-1:0] west_outer_valid_i,
	input logic [T*32*64-1:0] west_outer_data_i,
	output logic [T*32-1:0] west_inner_valid_o,
	output logic [T*32*64-1:0] west_inner_data_o,
	output logic fault_o,
	output logic conflict_o
);

	localparam P=32;
	wire [T*P*6-1:0] rs,ws;
	wire [T*P-1:0] rv,take,wv;
	wire [T*P*64-1:0] rd,wd;
	wire [3:0] fault,compat_fault;
	wire clash,batch_fault;
	lpu_sxm_stream_boundary #(.T(T),.PORTS(P)) boundary(
	  .clk_i,.rst_ni,.run_i,.east_valid_i(east_inner_valid_i),.east_data_i(east_inner_data_i),
	  .west_valid_i(west_outer_valid_i),.west_data_i(west_outer_data_i),
	  .east_valid_o(east_outer_valid_o),.east_data_o(east_outer_data_o),
	  .west_valid_o(west_inner_valid_o),.west_data_o(west_inner_data_o),
	  .read_sel_i(rs),.read_valid_o(rv),.read_data_o(rd),.consume_i(take),
	  .write_valid_i(wv),.write_sel_i(ws),.write_data_i(wd),.conflict_o(clash));
	sxm_triangle_full_core #(.T(T),.PORT_STREAMS(P)) u_execution(
	  .clk_i,.rst_ni,.ctrl_valid_i(ctrl_issue_i),.ctrl_op_i(ctrl_aux_i[1:0]),.ctrl_ctx_i(ctrl_aux_i[2]),
	  .ctrl_index_i(ctrl_aux_i[5:3]),.ctrl_data_i(ctrl_word_i),
	  .cap_valid_i(exec_issue_i && exec_word_i[0]),.cap_ctx_i(exec_word_i[1]),.cap_tile_i(exec_word_i[4:2]),
	  .cap_group_i(exec_word_i[7:5]),.cap_row_i(exec_word_i[11:8]),
	  .p_valid_i(exec_issue_i && exec_word_i[12]),.p_ctx_i(exec_word_i[13]),.p_dest_i(exec_word_i[16:14]),
	  .p_source_i(exec_word_i[19:17]),.p_row_i(exec_word_i[23:20]),.p_paired_i(exec_word_i[24]),.p_branch_i(exec_word_i[25]),
	  .p_sequence_i(exec_word_i[31:26]),.run_valid_i(exec_word_i[32+:T]&{T{exec_issue_i}}),.run_ctx_i(exec_word_i[36]),
	  .run_delay_i(exec_word_i[52:37]),.run_interval_i(exec_word_i[68:53]),.run_count_i(exec_word_i[74:69]),
	  .run_sequence_i(exec_word_i[80:75]),.sr_read_req_o(rs),.sr_read_valid_i(rv),.sr_read_data_i(rd),
	  .sr_consume_o(take),.sr_write_valid_o(wv),.sr_write_sel_o(ws),.sr_write_data_o(wd),.fault_o(fault),.busy_o,
	  .compat_t_valid_i(1'b0),.compat_p_valid_i(1'b0),.compat_t_family_i('0),.compat_p_family_i('0),
	  .compat_t_raw_i('0),.compat_p_raw_i('0),.compat_fault_o(compat_fault),
	  .batch_job_i(1'b0),.batch_mode_i('0),.batch_dtype_i('0),.batch_count_i('0),.batch_lane_map_i('0),
	  .batch_tile_map_i('0),.batch_ready_o(),.batch_fault_o(batch_fault),.batch_cap_valid_i('0),.batch_lane_valid_i('0),
	  .batch_cap_data_i('0),.batch_cap_accept_o(),.batch_block_ready_i('0),.batch_block_valid_o(),.batch_block_fp32_o(),
	  .batch_block_vector_o(),.batch_block_data_o(),.batch_block_matrix_o(),.batch_block_column_o());
	always_ff @(posedge clk_i or negedge rst_ni)
	  if(!rst_ni)begin fault_o<=0; conflict_o<=0;end
	  else begin fault_o<=fault_o || (|fault) || (|compat_fault) || batch_fault
        || (exec_issue_i && (|(exec_word_i[35:32] >> T))); conflict_o<=conflict_o || clash;end
endmodule
