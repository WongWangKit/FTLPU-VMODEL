`timescale 1ns/1ps
// Four existing MEM groups, West at MEM_LEFT..MEM_LEFT-3; no new data queue.
// Command observation pipeline carries metadata only, mirroring native hops.
// Completion counts valid Tap samples, with target/address checks and fault gate.
module lpu_sxm_triangle_mem_integration #(
 parameter integer T=4,DEPTH=4096,FABRIC_COLUMNS=16,MEM_LEFT=12,
 localparam integer TW=$clog2(T)
)(
 input wire clk_i,rst_ni,job_valid_i,fp32_i,resources_ready_i,
 input wire [15:0] matrices_i,input wire [14:0] base_i,
 input wire [T*TW-1:0] tile_map_i,input wire [T*24-1:0] lane_map_i,
 output wire job_ready_o,
 input wire [T-1:0] cap_valid_i,input wire [T*256-1:0] cap_data_i,
 output wire [T-1:0] cap_accept_o,
 input wire [31:0] read_issue_valid_i,input wire [1023:0] read_issue_i,
 output wire [T*32-1:0] read_valid_o,output wire [T*2048-1:0] read_data_o,
 output wire [31:0] committed_segments_o,output wire done_o,
 output wire busy_o,fault_o,
 output wire [32*T-1:0] tap_sample_o
);
 localparam integer SC=2*FABRIC_COLUMNS*T*32,IC=SC*2,MC=64*T;
 wire core_ready,writer_ready,core_busy,writer_busy,core_fault,writer_fault;
 wire [T-1:0] bv,bf,br;wire [T*2048-1:0] bd,cap_wide;
 wire [T*16-1:0] bm;wire [T*TW-1:0] bc;
 wire [31:0] wi;wire [1023:0] wc;
 wire [T*32-1:0] sv;wire [T*2048-1:0] sd;
 wire [4*T-1:0] target;wire [4*T*15-1:0] target_addr;
 wire pending_q,bad_q;
 wire [SC-1:0] state_v;wire [SC*64-1:0] state_d;
 wire [2*T*32*64-1:0] boundary_zero;
 for(genvar z=0;z<2*T*32;z=z+1)assign boundary_zero[z*64+:64]=64'b0;
 reg [IC-1:0] inject_v,consume;reg [IC*64-1:0] inject_d;
 wire [2*FABRIC_COLUMNS*T-1:0] collision,invalid_consume;
 wire [4*MC-1:0] mlv,mrv,mlc,mrc;
 wire [4*MC*64-1:0] mld,mrd;
 wire [32*T-1:0] mli,mri,mid,mc_internal;
 wire [32*T*64-1:0] md;wire [32*T*5-1:0] mis;
 wire [3:0] mem_busy,mem_fault;
 wire [31:0] mi=writer_busy?wi:read_issue_valid_i;
 wire [1023:0] mcmd=writer_busy?wc:read_issue_i;
 wire monitor_bad,start;wire [32*T-1:0] tap_data_valid;
 for(genvar t=0;t<T;t=t+1)begin:g_tiles
   assign cap_wide[t*2048+:2048]={1792'b0,cap_data_i[t*256+:256]};
   for(genvar b=0;b<32;b=b+1)begin:g_read
     assign read_valid_o[t*32+b]=state_v[((FABRIC_COLUMNS+MEM_LEFT-3)*T+t)*32+b];
     assign read_data_o[(t*32+b)*64+:64]=state_d[(((FABRIC_COLUMNS+MEM_LEFT-3)*T+t)*32+b)*64+:64];
   end
 end
 for(genvar g=0;g<4;g=g+1)begin:g_mem
   for(genvar t=0;t<T;t=t+1)begin:g_tile
     for(genvar st=0;st<32;st=st+1)for(genvar dir=0;dir<2;dir=dir+1)begin:g_state
       assign mlv[g*MC+(dir*32+st)*T+t]=state_v[((dir*FABRIC_COLUMNS+MEM_LEFT-g)*T+t)*32+st];
       assign mrv[g*MC+(dir*32+st)*T+t]=state_v[((dir*FABRIC_COLUMNS+MEM_LEFT-g+1)*T+t)*32+st];
       assign mld[(g*MC+(dir*32+st)*T+t)*64+:64]=state_d[(((dir*FABRIC_COLUMNS+MEM_LEFT-g)*T+t)*32+st)*64+:64];
       assign mrd[(g*MC+(dir*32+st)*T+t)*64+:64]=state_d[(((dir*FABRIC_COLUMNS+MEM_LEFT-g+1)*T+t)*32+st)*64+:64];
     end
     for(genvar b=0;b<8;b=b+1)begin:g_tap
       assign tap_data_valid[(g*8+b)*T+t]=mrv[g*MC+(32+g*8+b)*T+t];
     end
   end
   mem_group #(.P_TILE_ROWS(T),.P_MEM_BANK_DEPTH_ROWS(DEPTH)) u_mem(
     .clk_i,.rst_ni,.group_issue_valid_i(mi[g*8+:8]),.group_issue_i(mcmd[g*256+:256]),
     .left_boundary_state_valid_i(mlv[g*MC+:MC]),.left_boundary_state_data_i(mld[g*MC*64+:MC*64]),
     .right_boundary_state_valid_i(mrv[g*MC+:MC]),.right_boundary_state_data_i(mrd[g*MC*64+:MC*64]),
     .external_producer_collision_i({8*T{1'b0}}),.left_boundary_consume_o(mlc[g*MC+:MC]),.right_boundary_consume_o(mrc[g*MC+:MC]),
     .left_boundary_inject_valid_o(mli[g*8*T+:8*T]),.right_boundary_inject_valid_o(mri[g*8*T+:8*T]),
     .boundary_inject_data_o(md[g*8*T*64+:8*T*64]),.boundary_inject_stream_dir_o(mid[g*8*T+:8*T]),.boundary_inject_stream_idx_o(mis[g*8*T*5+:8*T*5]),
     .internal_mem_collision_o(mc_internal[g*8*T+:8*T]),.slice_fault_valid_o(),.slice_fault_code_o(),.slice_fault_bank_id_o(),.slice_fault_tile_valid_o(),.slice_fault_tile_id_o(),.slice_fault_row_o(),
     .group_fault_valid_o(mem_fault[g]),.slice_busy_o(),.group_busy_o(mem_busy[g]));
 end
 wire [T*32*64-1:0] sr_zero;
 for(genvar zf=0;zf<T*32;zf++)assign sr_zero[zf*64+:64]=64'b0;
 sxm_triangle_writetap_core #(.T(T),.DEPTH(DEPTH),.PORT_STREAMS(32)) u_sxm(
   .clk_i,.rst_ni,.ctrl_valid_i(1'b0),.ctrl_op_i('0),.ctrl_ctx_i(1'b0),.ctrl_index_i('0),.ctrl_data_i('0),
   .cap_valid_i(1'b0),.cap_ctx_i(1'b0),.cap_tile_i('0),.cap_group_i('0),.cap_row_i('0),
   .p_valid_i(1'b0),.p_ctx_i(1'b0),.p_dest_i('0),.p_source_i('0),.p_row_i('0),.p_paired_i(1'b0),.p_branch_i(1'b0),.p_sequence_i('0),
   .run_valid_i('0),.run_ctx_i(1'b0),.run_delay_i('0),.run_interval_i('0),.run_count_i('0),.run_sequence_i('0),
   .sr_read_req_o(),.sr_read_valid_i('0),.sr_read_data_i(sr_zero),.sr_consume_o(),.sr_write_valid_o(),.sr_write_sel_o(),.sr_write_data_o(),.fault_o(),
   .compat_t_valid_i(1'b0),.compat_p_valid_i(1'b0),.compat_t_family_i('0),.compat_p_family_i('0),.compat_t_raw_i('0),.compat_p_raw_i('0),.compat_fault_o(),
   .batch_job_i(job_valid_i),.batch_mode_i(2'd0),.batch_dtype_i({1'b0,fp32_i}),.batch_count_i(matrices_i),
   .batch_lane_map_i(lane_map_i),.batch_tile_map_i(tile_map_i),.batch_ready_o(job_ready_o),.batch_fault_o(core_fault),
   .batch_cap_valid_i(cap_valid_i),.batch_lane_valid_i({T*8{1'b1}}),.batch_cap_data_i(cap_wide),.batch_cap_accept_o(cap_accept_o),
   .batch_block_valid_o(bv),.batch_block_fp32_o(bf),.batch_block_vector_o(),.batch_block_data_o(bd),.batch_block_matrix_o(bm),.batch_block_column_o(bc),
   .resources_ready_i,.base_i,.mem_busy_i(mem_busy),.mem_fault_i(mem_fault),.transport_fault_i((|collision) || (|invalid_consume) || (|mc_internal)),
   .read_issue_valid_i,.tap_data_valid_i(tap_data_valid),.stream_valid_o(sv),.stream_data_o(sd),.mem_issue_valid_o(wi),.mem_issue_o(wc),
   .target_tap_o(target),.target_address_o(target_addr),.tap_sample_o,.committed_segments_o,.done_o,.busy_o,.completion_fault_o(fault_o),
   .pending_o(pending_q),.writer_busy_o(writer_busy),.writer_fault_o(writer_fault),.bad_o(bad_q),.monitor_bad_o(monitor_bad));
 integer t,b,dir,st,cell_index,slot,p,g;
 always @* begin
   inject_v=0;inject_d=0;consume=0;
   cell_index=0;slot=0;t=0;dir=0;st=0;
   for(t=0;t<T;t=t+1)begin
     for(st=0;st<32;st=st+1)begin
       slot=(((FABRIC_COLUMNS+MEM_LEFT+2)*T+t)*2)*32+st;
       inject_v[slot]=sv[t*32+st];inject_d[slot*64+:64]=sd[(t*32+st)*64+:64];
     end
     for(b=0;b<32;b=b+1)begin
       slot=(((FABRIC_COLUMNS+MEM_LEFT-3)*T+t)*2)*32+b;consume[slot]=read_valid_o[t*32+b];
     end
   end
   for(g=0;g<4;g=g+1)begin
     for(t=0;t<T;t=t+1)begin
       for(b=0;b<8;b=b+1)begin
         st=g*8+b;
         // Tap itself preserves. Consume only at this stream's assigned group.
         slot=(((FABRIC_COLUMNS+MEM_LEFT-g+1)*T+t)*2)*32+st;
         consume[slot]=pending_q && mrv[g*MC+(32+st)*T+t];
       end
       for(st=0;st<32;st=st+1)for(dir=0;dir<2;dir=dir+1)begin
         cell_index=(dir*32+st)*T+t;
         slot=(((dir*FABRIC_COLUMNS+MEM_LEFT-g)*T+t)*2+1)*32+st;consume[slot]=consume[slot] | mlc[g*MC+cell_index];
         slot=(((dir*FABRIC_COLUMNS+MEM_LEFT-g+1)*T+t)*2+1)*32+st;consume[slot]=consume[slot] | mrc[g*MC+cell_index];
       end
     end
     for(p=0;p<8*T;p=p+1)if(mli[g*8*T+p] || mri[g*8*T+p])begin
       t=p%T;dir=int'(mid[g*8*T+p]);st=int'(mis[(g*8*T+p)*5+:5]);
       slot=(((dir*FABRIC_COLUMNS+MEM_LEFT-g+(mli[g*8*T+p]?0:1))*T+t)*2)*32+st;
       inject_v[slot]=1;inject_d[slot*64+:64]=md[(g*8*T+p)*64+:64];
     end
   end
 end
 ftlpu_sr_hemisphere_fabric #(.SUPERLANES(T),.COLUMNS(FABRIC_COLUMNS)) u_srf(
   .clk_i,.rst_ni,.boundary_valid_i('0),.boundary_data_i(boundary_zero),.boundary_valid_o(),.boundary_data_o(),
   .inject_valid_i(inject_v),.inject_data_i(inject_d),.consume_i(consume),.collision_o(collision),.invalid_consume_o(invalid_consume),.state_valid_o(state_v),.state_data_o(state_d));
`ifndef SYNTHESIS
 initial if(MEM_LEFT<3 || MEM_LEFT+2>=FABRIC_COLUMNS)$fatal(1,"WriteTap four-group SRF geometry");
`endif
endmodule
