`timescale 1ns/1ps
// One BF16 vector from the east-going boundary to west-going streams via the full core.
module sxm_boundary_vector_tb;
  localparam T=4,P=16;
  bit clk_i, rst_ni, ctrl, cap, perm;
  always #5 clk_i=~clk_i;
  logic [127:0] cfg;
  logic [1:0] op;
  logic [2:0] idx;
  logic [T-1:0] run;
  wire [3:0] fault,compat_fault;
  wire batch_fault,clash,busy;
  wire [T*P*6-1:0] rs,ws;
  wire [T*P-1:0] rv,consume,wv;
  wire [T*P*64-1:0] rd,wd;
  logic [127:0] ev;
  logic [8191:0] ed;
  wire [127:0] east_out,west_out;
  wire [8191:0] west_data;
  lpu_sxm_stream_boundary #(.T(T),.PORTS(P)) boundary(
    .clk_i,.rst_ni,.run_i(1'b1),.east_valid_i(ev),.east_data_i(ed),.west_valid_i('0),.west_data_i('0),
    .east_valid_o(east_out),.east_data_o(),.west_valid_o(west_out),.west_data_o(west_data),
    .read_sel_i(rs),.write_sel_i(ws),.read_valid_o(rv),.read_data_o(rd),.consume_i(consume),
    .write_valid_i(wv),.write_data_i(wd),.conflict_o(clash));
  sxm_triangle_full_core #(.T(T),.PORT_STREAMS(P)) core(
    .clk_i,.rst_ni,.ctrl_valid_i(ctrl),.ctrl_op_i(op),.ctrl_ctx_i(1'b0),.ctrl_index_i(idx),.ctrl_data_i(cfg),
    .cap_valid_i(cap),.cap_ctx_i(1'b0),.cap_tile_i(3'd1),.cap_group_i(3'd2),.cap_row_i('0),
    .p_valid_i(perm),.p_ctx_i(1'b0),.p_dest_i(3'd2),.p_source_i(3'd1),.p_row_i('0),
    .p_paired_i(1'b0),.p_branch_i(1'b0),.p_sequence_i('0),
    .run_valid_i(run),.run_ctx_i(1'b0),.run_delay_i('0),.run_interval_i(16'd2),.run_count_i(6'd1),.run_sequence_i('0),
    .sr_read_req_o(rs),.sr_read_valid_i(rv),.sr_read_data_i(rd),.sr_consume_o(consume),
    .sr_write_valid_o(wv),.sr_write_sel_o(ws),.sr_write_data_o(wd),.fault_o(fault),.busy_o(busy),
    .compat_t_valid_i(1'b0),.compat_p_valid_i(1'b0),.compat_t_family_i('0),.compat_p_family_i('0),
    .compat_t_raw_i('0),.compat_p_raw_i('0),.compat_fault_o(compat_fault),
    .batch_job_i(1'b0),.batch_mode_i('0),.batch_dtype_i('0),.batch_count_i('0),.batch_lane_map_i('0),.batch_tile_map_i('0),
    .batch_ready_o(),.batch_fault_o(batch_fault),.batch_cap_valid_i('0),.batch_lane_valid_i('0),.batch_cap_data_i('0),
    .batch_cap_accept_o(),.batch_block_ready_i('0),.batch_block_valid_o(),.batch_block_fp32_o(),.batch_block_vector_o(),
    .batch_block_data_o(),.batch_block_matrix_o(),.batch_block_column_o());
  always @(posedge clk_i) if(rst_ni && (|{fault,compat_fault,batch_fault,clash})) $fatal(1,"fault on active edge");
  task automatic tick; @(posedge clk_i); #1; endtask
  initial begin
    ev=0; ed=0; run=0; op=0; idx=0; cfg=0; tick(); rst_ni=1;
    ctrl=1; op=1; cfg[113:112]=1; for(int i=0;i<16;i++)cfg[6*i+:6]=6'(32+i); tick();
    op=2;
    for(int t=0;t<T;t++)begin
      idx=3'(t);cfg=0;cfg[122:120]=idx;
      for(int i=0;i<16;i++)cfg[i*6+:6]=6'(i+4);
      for(int l=0;l<8;l++)cfg[96+l*3+:3]=3'(7-l);
      tick();
    end
    op=3;idx=2;cfg=2;tick();ctrl=0;
    cap=1;ev[32+:2]=3;
    ed[32*64+:64]=64'h0706050403020100; ed[33*64+:64]=64'h8786858483828180;
    #1; if(consume!==(64'd3<<16)) $fatal(1,"wrong CAP");
    tick();cap=0;ev=0;
    if(east_out!=='0) $fatal(1,"consumed vector leaked");
    perm=1;tick();perm=0;tick();run=4'b0100;tick();
    if(west_out!==(128'd3<<68) || west_data[68*64+:64]!==64'h0001020304050607 ||
       west_data[69*64+:64]!==64'h8081828384858687) $fatal(1,"wrong output tile, lane, byte plane or cycle");
    run=0;tick();if(busy || (|west_out)) $fatal(1,"did not drain");
    $display("SXM_BOUNDARY_VECTOR_PASS");$finish;
  end
endmodule
