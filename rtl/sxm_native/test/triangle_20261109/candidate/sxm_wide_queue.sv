`timescale 1ns/1ps
// Experimental replacement MATRIX/VECTOR data path derived from row_core's
// data_q[column][slot][row] transpose indexing. Not a drop-in command ABI.
// TRI=0: 16 fixed slots. TRI=1: per-source depths 1,2,3,4 (10 slots).
// No payload reset, no payload shift/copy, no extra output payload register.
module sxm_wide_queue #(parameter integer TRI=1)(
 input wire clk_i,rst_ni,
 input wire [3:0] cap_valid_i, cap_vector_i,
 input wire [11:0] cap_row_i,
 input wire [7:0] cap_dest_i,
 input wire [1023:0] cap_data_i,
 input wire [3:0] ready_i,
 output reg [3:0] valid_o,vector_o,
 output reg [8191:0] data_o,
 output wire fault_o,busy_o
);
 reg [15:0] cycle_q;
 wire [3:0] local_fault,local_busy;
 wire [3:0] src_valid,src_vector;
 wire [7:0] src_dest;
 wire [8191:0] src_data;
 assign fault_o=|local_fault;
 assign busy_o=|local_busy;
 always @(posedge clk_i) if(!rst_ni) cycle_q<=0; else cycle_q<=cycle_q+16'd1;
 for(genvar s=0;s<4;s=s+1) begin:source
   localparam integer DEPTH=(TRI!=0) ? s+1:4;
   localparam integer PW=(DEPTH<=2)?1:2;
   reg [31:0] data_q[0:7][0:DEPTH-1][0:7];
   reg [7:0] rows_q[0:DEPTH-1];
   reg [15:0] due_q[0:DEPTH-1];
   reg [1:0] dest_q[0:DEPTH-1];
   reg [DEPTH-1:0] occupied_q,complete_q,vector_q;
   reg [PW-1:0] wp_q,rp_q;
   reg fault_q;
   wire fire=complete_q[rp_q] && due_q[rp_q]==cycle_q;
   wire take=fire && ready_i[dest_q[rp_q]];
   assign src_valid[s]=fire;
   assign src_vector[s]=vector_q[rp_q];
   assign src_dest[s*2+:2]=dest_q[rp_q];
   assign local_busy[s]=|occupied_q;
   assign local_fault[s]=fault_q;
   for(genvar q=0;q<8;q=q+1) begin:column
     for(genvar l=0;l<8;l=l+1) begin:lane
       assign src_data[s*2048+(q*8+l)*32+:32]=vector_q[rp_q] ?
         ((q==0)?data_q[l][rp_q][0]:32'b0) : data_q[q][rp_q][l];
     end
   end
   integer k,l;
   always @(posedge clk_i) begin
     if(!rst_ni) begin
       wp_q<=0;rp_q<=0;occupied_q<=0;complete_q<=0;vector_q<=0;fault_q<=0;
       for(k=0;k<DEPTH;k=k+1) begin rows_q[k]<=0;due_q[k]<=0;dest_q[k]<=0;end
     end else begin
       if(fire && !take) fault_q<=1; // fixed schedule, no hidden retry
       if(take) begin
         occupied_q[rp_q]<=0;complete_q[rp_q]<=0;rows_q[rp_q]<=0;
         rp_q <= (int'(rp_q)==DEPTH-1)?PW'(0):rp_q+PW'(1);
       end
       if(cap_valid_i[s]) begin
         if(cap_row_i[s*3+:3]==0) begin
           if(occupied_q[wp_q] && !(take && rp_q==wp_q)) fault_q<=1;
           occupied_q[wp_q]<=1;rows_q[wp_q]<=8'd1;
           dest_q[wp_q]<=cap_dest_i[s*2+:2];vector_q[wp_q]<=cap_vector_i[s];
         end else begin
           if(!occupied_q[wp_q] || complete_q[wp_q] || rows_q[wp_q][cap_row_i[s*3+:3]]) fault_q<=1;
           rows_q[wp_q]<=rows_q[wp_q] | (8'd1<<cap_row_i[s*3+:3]);
         end
         for(l=0;l<8;l=l+1) data_q[l][wp_q][cap_row_i[s*3+:3]]<=cap_data_i[s*256+l*32+:32];
         if(cap_vector_i[s] || cap_row_i[s*3+:3]==7) begin
           if(!cap_vector_i[s] && rows_q[wp_q]!=8'h7f) fault_q<=1;
           if(cap_vector_i[s] && cap_row_i[s*3+:3]!=0) fault_q<=1;
           complete_q[wp_q]<=1;
           due_q[wp_q]<=cycle_q+16'd1+(cap_vector_i[s]?16'd0:16'(7*s));
           wp_q <= (int'(wp_q)==DEPTH-1)?PW'(0):wp_q+PW'(1);
         end
       end
     end
   end
 end
 integer d,s;
 always @* begin
   valid_o=0;vector_o=0;data_o=0;
   for(d=0;d<4;d=d+1) for(s=0;s<4;s=s+1)
     if(src_valid[s] && src_dest[s*2+:2]==2'(d)) begin
       valid_o[d]=1;vector_o[d]=src_vector[s];data_o[d*2048+:2048]=src_data[s*2048+:2048];
     end
 end
`ifndef SYNTHESIS
 always @(posedge clk_i) if(rst_ni) begin
   for(integer x=0;x<4;x=x+1) for(integer y=x+1;y<4;y=y+1)
     if(src_valid[x] && src_valid[y] && src_dest[x*2+:2]==src_dest[y*2+:2]) $fatal(1,"destination collision");
 end
`endif
endmodule
