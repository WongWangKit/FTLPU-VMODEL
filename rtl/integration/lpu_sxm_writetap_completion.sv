`timescale 1ns/1ps
// Metadata-only native command monitor and commit/drain accounting.
// Command taps mirror the unchanged MEM hop; payload valid is observed at SRF.
module lpu_sxm_writetap_completion #(parameter integer T=4,DEPTH=4096)(
 input wire clk_i,rst_ni,job_valid_i,fp32_i,
 input wire [15:0] matrices_i,
 input wire core_ready,writer_ready,core_busy,writer_busy,core_fault,writer_fault,
 input wire [3:0] mem_busy,mem_fault,
 input wire transport_fault,input wire [31:0] read_issue_valid_i,
 input wire [31:0] wi,input wire [1023:0] wc,
 input wire [4*T-1:0] target,input wire [4*T*15-1:0] target_addr,
 input wire [32*T-1:0] tap_data_valid_i,
 output wire job_ready_o,start,busy_o,fault_o,
 output reg pending_q,bad_q,monitor_bad,
 output wire [32*T-1:0] tap_sample_o,
 output reg [31:0] committed_segments_o,output reg done_o
);
 reg [31:0] expected_q;
 wire [4*T-1:0] monitor_valid;wire [4*T*32-1:0] monitor_word;
 assign job_ready_o=core_ready && writer_ready && !pending_q && !(|mem_busy) && !fault_o;
 assign start=job_valid_i && job_ready_o;
 assign busy_o=pending_q || core_busy || writer_busy || (|mem_busy);
 assign fault_o=bad_q || core_fault || writer_fault || (|mem_fault) || transport_fault;
 for(genvar g=0;g<4;g=g+1)begin:g_monitor
   for(genvar t=0;t<T;t=t+1)begin:g_tile
     if(t==0)begin
       assign monitor_valid[g*T+t]=wi[g*8];assign monitor_word[(g*T+t)*32+:32]=wc[g*256+:32];
     end else begin
       reg valid_q;reg [31:0] word_q;
       always @(posedge clk_i)begin
         if(!rst_ni)begin valid_q<=0;word_q<=0;end
         else begin valid_q<=monitor_valid[g*T+t-1];word_q<=monitor_word[(g*T+t-1)*32+:32];end
       end
       assign monitor_valid[g*T+t]=valid_q;assign monitor_word[(g*T+t)*32+:32]=word_q;
     end
     for(genvar b=0;b<8;b=b+1)begin:g_tap
       wire [31:0] command=monitor_word[(g*T+t)*32+:32];
       assign tap_sample_o[(g*8+b)*T+t]=pending_q && monitor_valid[g*T+t] && command[31] && command[2:0]==1 &&
           command[8] && int'(command[29:15])<DEPTH && tap_data_valid_i[(g*8+b)*T+t];
     end
   end
 end
 // Balanced combinational population count: no extra sampling edge or state.
 // A serial integer += 1 chain makes T8 completion the critical timing path.
 localparam integer TAP_COUNT=32*T,COUNT_BITS=$clog2(TAP_COUNT+1);
 for(genvar level=0;level<COUNT_BITS;level=level+1)begin:g_count_level
   wire [level:0] sum [0:(TAP_COUNT>>level)-1];
   for(genvar i=0;i<(TAP_COUNT>>level);i=i+1)begin:g_node
     if(level==0)assign sum[i]=tap_sample_o[i];
     else assign sum[i]={1'b0,g_count_level[level-1].sum[2*i]}+{1'b0,g_count_level[level-1].sum[2*i+1]};
   end
 end
 wire [COUNT_BITS-1:0] ncommit=g_count_level[COUNT_BITS-1].sum[0];
 integer g,t,b;reg [31:0] command;
 always @* begin
   monitor_bad=0;command=0;
   for(g=0;g<4;g=g+1)for(t=0;t<T;t=t+1)begin
     command=monitor_word[(g*T+t)*32+:32];
     for(b=0;b<8;b=b+1)begin
       if(pending_q && (tap_sample_o[(g*8+b)*T+t]!=target[g*T+t]))monitor_bad=1;
       if(target[g*T+t] && (command[29:15]!=target_addr[(g*T+t)*15+:15] || command[7:3]!=5'(g*8)))monitor_bad=1;
     end
   end
 end
 always @(posedge clk_i)begin
   if(!rst_ni)begin pending_q<=0;bad_q<=0;expected_q<=0;committed_segments_o<=0;done_o<=0;end
   else begin
     done_o<=0;
     if((job_valid_i && !job_ready_o) || ((|read_issue_valid_i) && pending_q) || monitor_bad)bad_q<=1;
     if(start)begin pending_q<=1;expected_q<=32'(matrices_i)*32'(8*T*T)*(fp32_i?32'd4:32'd2);committed_segments_o<=0;end
     else if(pending_q)begin
       committed_segments_o<=committed_segments_o+32'(ncommit);
       if(!core_busy && !writer_busy && !(|mem_busy) && !(|monitor_valid) && !fault_o && !monitor_bad)begin
         if(committed_segments_o==expected_q)begin done_o<=1;pending_q<=0;end
         else bad_q<=1;
       end
     end
   end
 end
endmodule
