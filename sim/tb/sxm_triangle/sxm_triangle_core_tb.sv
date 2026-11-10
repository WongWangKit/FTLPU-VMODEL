`timescale 1ns/1ps
module sxm_triangle_core_tb #(parameter integer T=4);
 localparam integer TW=$clog2(T);
 reg clk_i=0,rst_ni=0;always #5 clk_i=~clk_i;
 reg job_valid_i=0;
 reg [1:0] mode_i=0,dtype_i=0;
 reg [15:0] count_i=0;
 reg [T*24-1:0] lane_map_i=0;
 reg [T*TW-1:0] tile_map_i=0;
 wire job_ready_o,busy_o,fault_o;
 reg [T-1:0] cap_valid_i=0,block_ready_i={T{1'b1}};
 reg [T*8-1:0] cap_lane_valid_i={T*8{1'b1}};
 reg [T*2048-1:0] cap_data_i=0;
 wire [T-1:0] cap_accept_o,block_valid_o,block_fp32_o,block_vector_o;
 wire [T*2048-1:0] block_data_o;
 wire [T*16-1:0] block_matrix_o;
 wire [T*TW-1:0] block_column_o;
 wire [T*(T+1)/2*2048-1:0] pool_zero;
 for(genvar pz=0;pz<T*(T+1)/2*32;pz++)assign pool_zero[pz*64+:64]=64'b0;
 sxm_triangle_core #(.T(T),.TIMER_BITS(8)) dut(
 .clk_i,.rst_ni,.job_valid_i,.mode_i,.dtype_i,.count_i,.lane_map_i,.tile_map_i,.job_ready_o,
 .cap_valid_i,.cap_lane_valid_i,.cap_data_i,.cap_accept_o,.block_ready_i,
 .block_valid_o,.block_fp32_o,.block_vector_o,.block_data_o,.block_matrix_o,.block_column_o,.busy_o,.fault_o,
 .compat_write_rows_i('0),.compat_write_data_i('0),.compat_read_data_o(),.pool_write_rows_i('0),.pool_write_data_i(pool_zero),.pool_read_o());
 integer MODE=0,FP=1,N=32,NEG=0,c,s,d,l,q,r,a,m,ix,limit,seen=0;
 reg [T-1:0] ev;
 reg [31:0] want;
 function automatic [31:0] value(input integer mm,rr,cc);
   value=32'h3f812345+32'(((mm*8*T+rr)*8*T+cc)*257);
 endfunction
 function automatic [31:0] typed_value(input integer mm,rr,cc);
   typed_value=value(mm,rr,cc);if(FP==0)typed_value=typed_value&32'hffff;
 endfunction
 initial begin
   if($value$plusargs("MODE=%d",MODE))begin end
   if($value$plusargs("FP=%d",FP))begin end
   if($value$plusargs("N=%d",N))begin end
   if($value$plusargs("NEG=%d",NEG))begin end
   mode_i=2'(MODE);dtype_i=2'(FP);count_i=16'(N);
   for(d=0;d<T;d=d+1)begin
     tile_map_i[d*TW+:TW]=TW'(T-1-d);
     for(l=0;l<8;l=l+1)lane_map_i[d*24+l*3+:3]=3'(7-l);
   end
   if(NEG==1)dtype_i=2'd2;
   if(NEG==2)tile_map_i=0;
   if(NEG==3)count_i=0;
   if(NEG==4)block_ready_i=0;
   if(NEG==5)cap_lane_valid_i=0;
   limit=(MODE==0)?N*8*T+8*T+8:N*4+10;
   repeat(2)@(negedge clk_i);rst_ni=1;
   for(c=0;c<limit;c=c+1)begin
     job_valid_i=(c==0);cap_valid_i=0;cap_data_i=0;ev=0;
     if(NEG<=3 && NEG!=0 && c==2)begin
       if(!fault_o || busy_o)$fatal(1,"invalid config did not reject");
       $display("PASS CORE NEG=%0d T=%0d",NEG,T);$finish;
     end
     for(s=0;s<T;s=s+1)begin
       ix=c-1-((MODE==0)?s:0);
       if(ix>=0)begin
         if(MODE==0)begin m=ix/(8*T);a=(ix%(8*T))/8;r=ix%8;end
         else begin m=ix/4;a=s;r=0;end
         if(m<N && (MODE==0 || ix%4==0))begin
           cap_valid_i[s]=1;
           for(q=0;q<8;q=q+1)for(l=0;l<8;l=l+1)
             if(MODE==3 || q==0)cap_data_i[s*2048+(q*8+l)*32+:32]=value(m,8*a+((MODE==3)?q:r),8*s+l);
         end
       end
     end
     if(NEG==1 || NEG==2 || NEG==3)cap_valid_i=0;
     // Test metadata isolation: externally changing maps after accepted job
     // must not alter the stored private configuration.
     if(c>0)begin lane_map_i=0;tile_map_i=0;mode_i=0;dtype_i=0;end
     #1;
     if(NEG==4 || NEG==5)begin
       if(fault_o)begin $display("PASS CORE NEG=%0d T=%0d",NEG,T);$finish;end
     end else if(NEG==0)begin
       if(fault_o || cap_accept_o!==cap_valid_i)$fatal(1,"capture/fault C%0d",c);
       for(s=0;s<T;s=s+1)begin
         ix=c-((MODE==0)?9+8*s:2);
         if(ix>=0 && ix%((MODE==0)?8:4)==0)begin
           if(MODE==0)begin m=ix/(8*T);a=(ix/8)%T;end else begin m=ix/4;a=s;end
           d=T-1-a;
           if(m<N)begin
             ev[d]=1;seen++;
             if(!block_valid_o[d] || block_fp32_o[d]!=(FP!=0) || block_vector_o[d]!=(MODE==1) || block_matrix_o[d*16+:16]!=16'(m) || block_column_o[d*TW+:TW]!=TW'(s))$fatal(1,"tag C%0d d%0d",c,d);
             for(q=0;q<8;q=q+1)for(l=0;l<8;l=l+1)begin
               if(MODE==1)want=(q==0)?typed_value(m,8*a,8*s+7-l):0;
               else if(MODE==2)want=typed_value(m,8*a,8*s+q);
               else want=typed_value(m,8*a+7-l,8*s+q);
               if(block_data_o[d*2048+(q*8+l)*32+:32]!==want)$fatal(1,"data C%0d d%0d q%0d l%0d actual%h want%h",c,d,q,l,block_data_o[d*2048+(q*8+l)*32+:32],want);
             end
           end
         end
       end
       if(block_valid_o!==ev)$fatal(1,"valid calendar C%0d actual%h expected%h",c,block_valid_o,ev);
     end
     @(posedge clk_i);#1;@(negedge clk_i);
   end
   if(NEG!=0 || busy_o || !job_ready_o || seen!=N*((MODE==0)?T*T:T))$fatal(1,"drain/count");
   $display("PASS CORE T=%0d FP=%0d MODE=%0d N=%0d blocks=%0d timer_bits=8",T,FP,MODE,N,seen);$finish;
 end
endmodule
