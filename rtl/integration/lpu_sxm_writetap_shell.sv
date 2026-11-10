`timescale 1ns/1ps
// Native WriteTap scheduler. No payload registers; existing SRF captures wide P.
module lpu_sxm_writetap_shell #(
 parameter integer T=4,H=2,DEPTH=4096, localparam integer TW=$clog2(T)
)(
 input wire clk_i,rst_ni,job_valid_i,fp32_i,resources_ready_i,
 input wire [15:0] matrices_i, input wire [14:0] base_i,
 input wire [T*TW-1:0] tile_map_i,
 output wire job_ready_o,
 input wire [T-1:0] block_valid_i,block_fp32_i,
 input wire [T*2048-1:0] block_data_i,
 input wire [T*16-1:0] block_matrix_i,
 input wire [T*TW-1:0] block_column_i,
 output wire [T-1:0] block_ready_o,
 output wire [T*32-1:0] stream_valid_o,
 output wire [T*2048-1:0] stream_data_o,
 output wire [31:0] mem_issue_valid_o,
 output wire [1023:0] mem_issue_o,
 output wire [4*T-1:0] target_tap_o,
 output wire [4*T*15-1:0] target_address_o,
 output wire busy_o,fault_o,
 input wire core_ready_i,core_busy_i,core_fault_i,
 input wire [3:0] mem_busy_i,mem_fault_i,input wire transport_fault_i,
 input wire [31:0] read_issue_valid_i,input wire [32*T-1:0] tap_data_valid_i,
 output wire start_o,output wire [32*T-1:0] tap_sample_o,
 output wire [31:0] committed_segments_o,output wire done_o
);
 wire writer_ready,writer_busy,writer_fault,pending,bad,monitor_bad;
 lpu_sxm_triangle_mem_adapter #(.T(T),.H(H),.DEPTH(DEPTH)) u_writer(
 .clk_i,.rst_ni,.job_valid_i(start_o),.fp32_i,.resources_ready_i,.matrices_i,.base_i,.tile_map_i,.job_ready_o(writer_ready),
 .block_valid_i,.block_fp32_i,.block_data_i,.block_matrix_i,.block_column_i,.block_ready_o,
 .stream_valid_o,.stream_data_o,.mem_issue_valid_o,.mem_issue_o,.target_tap_o,.target_address_o,.busy_o(writer_busy),.fault_o(writer_fault));
 lpu_sxm_writetap_completion #(.T(T),.DEPTH(DEPTH)) u_completion(
 .clk_i,.rst_ni,.job_valid_i,.fp32_i,.matrices_i,
 .core_ready(core_ready_i),.writer_ready,.core_busy(core_busy_i),.writer_busy,.core_fault(core_fault_i),.writer_fault,
 .mem_busy(mem_busy_i),.mem_fault(mem_fault_i),.transport_fault(transport_fault_i),.read_issue_valid_i,
 .wi(mem_issue_valid_o),.wc(mem_issue_o),.target(target_tap_o),.target_addr(target_address_o),.tap_data_valid_i,
 .job_ready_o,.start(start_o),.busy_o,.fault_o,.pending_q(pending),.bad_q(bad),.monitor_bad,
 .tap_sample_o,.committed_segments_o,.done_o);
endmodule
