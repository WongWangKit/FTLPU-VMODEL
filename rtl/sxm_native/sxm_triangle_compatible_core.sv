`timescale 1ns/1ps
// Mutually exclusive typed batch and unchanged legacy raw/API engine.
// Legacy storage aliases slot zero in each triangle source; no second pool.
module sxm_triangle_compatible_core #(
 parameter integer T=4,TIMER_BITS=16,
 localparam integer TW=$clog2(T),
 localparam integer RAW_BITS=((240+8*T*(T<4?5:TW+3)+8+(T<4?3:TW+1)+31)/32)*32
)(
 input wire clk_i,rst_ni,job_valid_i,
 input wire [1:0] mode_i,dtype_i,
 input wire [15:0] count_i,
 input wire [T*24-1:0] lane_map_i,
 input wire [T*TW-1:0] tile_map_i,
 output wire job_ready_o,
 input wire [T-1:0] cap_valid_i,
 input wire [T*8-1:0] cap_lane_valid_i,
 input wire [T*2048-1:0] cap_data_i,
 output wire [T-1:0] cap_accept_o,
 input wire [T-1:0] block_ready_i,
 output wire [T-1:0] block_valid_o,block_fp32_o,block_vector_o,
 output wire [T*2048-1:0] block_data_o,
 output wire [T*16-1:0] block_matrix_o,
 output wire [T*TW-1:0] block_column_o,
 output wire busy_o,fault_o,
 input wire compat_t_valid_i,compat_p_valid_i,
 input wire [1:0] compat_t_family_i,compat_p_family_i,
 input wire [RAW_BITS-1:0] compat_t_raw_i,compat_p_raw_i,
 output wire [T*96-1:0] sr_read_req_o,sr_write_sel_o,
 input wire [T*16-1:0] sr_read_valid_i,
 input wire [T*1024-1:0] sr_read_data_i,
 output wire [T*16-1:0] sr_consume_o,sr_write_valid_o,
 output wire [T*1024-1:0] sr_write_data_o,
 output wire [3:0] compat_fault_o
);
 wire typed_busy,typed_ready,legacy_busy;
 wire legacy_any=compat_t_valid_i || compat_p_valid_i;
 wire typed_any=job_valid_i || (|cap_valid_i);
 wire legacy_accept=!typed_busy && !(typed_any && !legacy_busy);
 wire typed_accept=!legacy_busy && (!legacy_any || typed_busy);
 wire [T*8-1:0] wr;
 wire [T*1024-1:0] wd,rd;
 wire [2:0] lf;
 assign job_ready_o=typed_ready && !legacy_busy && !legacy_any;
 assign busy_o=typed_busy || legacy_busy;
 assign compat_fault_o={((legacy_any && !legacy_accept)||(typed_any && !typed_accept)),lf};
 sxm_triangle_core #(.T(T),.TIMER_BITS(TIMER_BITS),.COMPAT_STORAGE(1)) u_core(
   .clk_i,.rst_ni,.job_valid_i(job_valid_i && typed_accept),.mode_i,.dtype_i,.count_i,.lane_map_i,.tile_map_i,
   .job_ready_o(typed_ready),.cap_valid_i(cap_valid_i & {T{typed_accept}}),.cap_lane_valid_i,.cap_data_i,.cap_accept_o,
   .block_ready_i,.block_valid_o,.block_fp32_o,.block_vector_o,.block_data_o,.block_matrix_o,.block_column_o,
   .busy_o(typed_busy),.fault_o,.compat_write_rows_i(wr),.compat_write_data_i(wd),.compat_read_data_o(rd),.pool_write_rows_i('0),.pool_write_data_i('0),.pool_read_o());
 sxm_compat_engine #(.T(T)) u_legacy(
   .clk_i,.rst_ni,.t_valid_i(compat_t_valid_i && legacy_accept),.p_valid_i(compat_p_valid_i && legacy_accept),
   .t_family_i(compat_t_family_i),.p_family_i(compat_p_family_i),.t_raw_i(compat_t_raw_i),.p_raw_i(compat_p_raw_i),
   .read_req_o(sr_read_req_o),.read_valid_i(sr_read_valid_i),.read_data_i(sr_read_data_i),.consume_o(sr_consume_o),
   .write_valid_o(sr_write_valid_o),.write_sel_o(sr_write_sel_o),.write_data_o(sr_write_data_o),
   .bank_write_rows_o(wr),.bank_write_data_o(wd),.bank_read_data_i(rd),.fault_o(lf),.busy_o(legacy_busy));
`ifndef SYNTHESIS
 always @(posedge clk_i)if(rst_ni && typed_busy && legacy_busy)$fatal(1,"triangle payload ownership overlap");
`endif
endmodule
