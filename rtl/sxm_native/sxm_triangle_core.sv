`timescale 1ns/1ps
// Typed module-level batch interface; not an ICU encoding. Existing ABI cores
// remain available until their full compatibility migration is verified.
// mode: 0 matrix ROW->BLOCK8; 1 vector ROW->ROW; 2 broadcast ROW->BLOCK8;
// 3 typed BLOCK8->BLOCK8. dtype: 0 BF16, 1 FP32, 2/3 rejected.
module sxm_triangle_core #(
 parameter integer T=4, TIMER_BITS=16, COMPAT_STORAGE=0, SHARED_ROW=0,
 localparam integer TW=$clog2(T), SLOTS=T*(T+1)/2
)(
 input wire clk_i,rst_ni,
 input wire job_valid_i,
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
 output reg [T-1:0] block_valid_o,block_fp32_o,block_vector_o,
 output reg [T*2048-1:0] block_data_o,
 output reg [T*16-1:0] block_matrix_o,
 output reg [T*TW-1:0] block_column_o,
 output wire busy_o,
 output wire fault_o,
 // Exclusive legacy view; slot zero of each source, no extra payload array.
 input wire [T*8-1:0] compat_write_rows_i,
 input wire [T*1024-1:0] compat_write_data_i,
 output wire [T*1024-1:0] compat_read_data_o,
 input wire [SLOTS*8-1:0] pool_write_rows_i,
 input wire [SLOTS*2048-1:0] pool_write_data_i,
 output wire [SLOTS*2048-1:0] pool_read_o
);
 reg active_q,fault_q,fp32_q;
 reg [1:0] mode_q;
 reg [15:0] count_q;
 reg [T*24-1:0] lane_q;
 reg [T*TW-1:0] tile_q;
 reg [TIMER_BITS-1:0] timer_q;
 reg [31:0] sent_q;
 wire [T-1:0] source_valid,source_fp32,source_vector,source_fault,source_busy;
 wire [T*TW-1:0] source_dest,source_column;
 wire [T*16-1:0] source_matrix;
 wire [T*2048-1:0] source_data;
 reg config_ok,collision_now;
 integer i,j,nfire,ci,cj;
 assign fault_o=fault_q || (|source_fault) || collision_now;
 assign busy_o=active_q || (|source_busy);
 assign job_ready_o=!busy_o && !fault_o;
 always @* begin
   collision_now=0;
   for(ci=0;ci<T;ci=ci+1)for(cj=ci+1;cj<T;cj=cj+1)
     if(source_valid[ci] && source_valid[cj] && source_dest[ci*TW+:TW]==source_dest[cj*TW+:TW])collision_now=1;
 end
 always @* begin
   config_ok=(dtype_i<=1 && count_i!=0);
   for(i=0;i<T;i=i+1) begin
     if(int'(tile_map_i[i*TW+:TW])>=T)config_ok=0;
     for(j=0;j<i;j=j+1)if(tile_map_i[i*TW+:TW]==tile_map_i[j*TW+:TW])config_ok=0;
   end
   nfire=0;
   for(i=0;i<T;i=i+1)if(block_valid_o[i] && block_ready_i[i])nfire=nfire+1;
 end
 always @(posedge clk_i) begin
   if(!rst_ni) begin active_q<=0;fault_q<=0;fp32_q<=0;mode_q<=0;count_q<=0;lane_q<=0;tile_q<=0;timer_q<=0;sent_q<=0;end
   else begin
     if(collision_now)fault_q<=1;
     timer_q<=timer_q+1'b1;
     if(job_valid_i) begin
       if(!job_ready_o || !config_ok)fault_q<=1;
       else begin active_q<=1;fp32_q<=dtype_i[0];mode_q<=mode_i;count_q<=count_i;lane_q<=lane_map_i;tile_q<=tile_map_i;sent_q<=0;end
     end
     if(active_q && nfire!=0)begin
       sent_q<=sent_q+32'(nfire);
       if(sent_q+32'(nfire)==((mode_q==0)?32'(count_q)*(T*T):32'(count_q)*T))active_q<=0;
     end
   end
 end
 for(genvar s=0;s<T;s=s+1)begin:g_source
   localparam integer D=s+1, PW=(D<2)?1:$clog2(D);
   reg [31:0] data_q[0:D-1][0:7][0:7]; // [slot][input row][lane]
   for(genvar ps=0;ps<D;ps=ps+1)for(genvar pr=0;pr<8;pr=pr+1)for(genvar pl=0;pl<8;pl=pl+1)begin:g_pool_view
     assign pool_read_o[(s*(s+1)/2+ps)*2048+(pr*8+pl)*32+:32]=(SHARED_ROW!=0)?data_q[ps][pr][pl]:32'b0;
   end
   for(genvar cq=0;cq<8;cq=cq+1)for(genvar cl=0;cl<8;cl=cl+1)for(genvar cb=0;cb<2;cb=cb+1)begin:g_compat
     assign compat_read_data_o[s*1024+(cq*2+cb)*64+cl*8+:8]=(COMPAT_STORAGE!=0)?data_q[0][cl][cq][cb*8+:8]:8'b0;
   end
   reg [D-1:0] occupied_q,complete_q;
   reg [TIMER_BITS-1:0] due_q[0:D-1];
   reg [TW-1:0] dest_q[0:D-1];
   reg [15:0] matrix_q[0:D-1];
   reg [PW-1:0] wr_q,rd_q;
   reg [31:0] received_q;
   reg bad_q;
   wire [2:0] row_now=(mode_q==0)?received_q[2:0]:3'd0;
   wire [TW-1:0] a_now=(mode_q==0)?TW'(received_q>>3):TW'(s);
   wire [15:0] matrix_now=(mode_q==0)?16'(received_q/(8*T)):16'(received_q);
   wire [TW-1:0] dest_now=tile_q[int'(a_now)*TW+:TW];
   wire fire=active_q && complete_q[rd_q] && due_q[rd_q]==timer_q;
   wire take=fire && !fault_o && block_ready_i[dest_q[rd_q]];
   wire legal_cap=active_q && !fault_o && cap_lane_valid_i[s*8+:8]==8'hff &&
     received_q<((mode_q==0)?32'(count_q)*(8*T):32'(count_q)) &&
     ((row_now==0)?(!occupied_q[wr_q] || (take && rd_q==wr_q)):(occupied_q[wr_q] && !complete_q[wr_q]));
   assign cap_accept_o[s]=cap_valid_i[s] && legal_cap;
   assign source_valid[s]=fire;
   assign source_fp32[s]=fp32_q;
   assign source_vector[s]=(mode_q==1);
   assign source_dest[s*TW+:TW]=dest_q[rd_q];
   assign source_column[s*TW+:TW]=TW'(s);
   assign source_matrix[s*16+:16]=matrix_q[rd_q];
   assign source_fault[s]=bad_q;
   assign source_busy[s]=|occupied_q;
   for(genvar q=0;q<8;q=q+1)begin:g_row
     for(genvar l=0;l<8;l=l+1)begin:g_lane
       wire [2:0] g=lane_q[int'(dest_q[rd_q])*24+l*3+:3];
       assign source_data[s*2048+(q*8+l)*32+:32]=
         (mode_q==1)?((q==0)?data_q[rd_q][0][g]:32'b0):
         (mode_q==2)?data_q[rd_q][0][q]:data_q[rd_q][g][q];
     end
   end
   integer k,r,l;
   reg [31:0] word_in;
   always @(posedge clk_i)begin
     if(!rst_ni)begin
       occupied_q<=0;complete_q<=0;wr_q<=0;rd_q<=0;received_q<=0;bad_q<=0;
       for(k=0;k<D;k=k+1)begin due_q[k]<=0;dest_q[k]<=0;matrix_q[k]<=0;end
     end else begin
       if(SHARED_ROW!=0 && !active_q)begin
         for(k=0;k<D;k=k+1)for(r=0;r<8;r=r+1)if(pool_write_rows_i[(s*(s+1)/2+k)*8+r])begin
           for(l=0;l<8;l=l+1)data_q[k][r][l]<=pool_write_data_i[(s*(s+1)/2+k)*2048+(r*8+l)*32+:32];
         end
       end
       if(COMPAT_STORAGE!=0 && !active_q)begin
         for(r=0;r<8;r=r+1)if(compat_write_rows_i[s*8+r])begin
           for(l=0;l<8;l=l+1)data_q[0][r][l]<={16'b0,compat_write_data_i[s*1024+(r*2+1)*64+l*8+:8],compat_write_data_i[s*1024+r*2*64+l*8+:8]};
         end
       end
       if(job_valid_i && job_ready_o && config_ok)begin wr_q<=0;rd_q<=0;received_q<=0;end
       if(cap_valid_i[s] && !legal_cap)bad_q<=1;
       if(fire && !take)bad_q<=1;
       if(take)begin occupied_q[rd_q]<=0;complete_q[rd_q]<=0;rd_q<=(int'(rd_q)==D-1)?PW'(0):rd_q+PW'(1);end
       if(cap_accept_o[s])begin
         received_q<=received_q+1;
         if(row_now==0)begin occupied_q[wr_q]<=1;dest_q[wr_q]<=dest_now;matrix_q[wr_q]<=matrix_now;end
         for(r=0;r<8;r=r+1)if(mode_q==3 || r==int'(row_now))begin
           for(l=0;l<8;l=l+1)begin
             word_in=cap_data_i[s*2048+((mode_q==3)?r*8+l:l)*32+:32];
             data_q[wr_q][r][l]<=fp32_q?word_in:{16'b0,word_in[15:0]};
           end
         end
         if(mode_q!=0 || row_now==7)begin
           complete_q[wr_q]<=1;due_q[wr_q]<=timer_q+TIMER_BITS'(1+((mode_q==0)?7*s:0));
           wr_q<=(int'(wr_q)==D-1)?PW'(0):wr_q+PW'(1);
         end
       end
     end
   end
 end
 integer d,s;
 always @* begin
   block_valid_o=0;block_fp32_o=0;block_vector_o=0;block_data_o=0;block_matrix_o=0;block_column_o=0;
   for(d=0;d<T;d=d+1)for(s=0;s<T;s=s+1)if(!fault_o && source_valid[s] && source_dest[s*TW+:TW]==TW'(d))begin
     block_valid_o[d]=1;block_fp32_o[d]=source_fp32[s];block_vector_o[d]=source_vector[s];
     block_data_o[d*2048+:2048]=source_data[s*2048+:2048];
     block_matrix_o[d*16+:16]=source_matrix[s*16+:16];block_column_o[d*TW+:TW]=source_column[s*TW+:TW];
   end
 end
`ifndef SYNTHESIS
 initial if((T!=2 && T!=4 && T!=8) || TIMER_BITS<8)$fatal(1,"triangle profile");
`endif
endmodule
