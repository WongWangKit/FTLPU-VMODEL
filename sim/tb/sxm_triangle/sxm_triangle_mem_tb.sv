`timescale 1ns/1ps
module sxm_triangle_mem_tb #(parameter integer T=4,FABRIC_COLUMNS=16,MEM_LEFT=12);
 reg clk_i=0,rst_ni=0;always #5 clk_i=~clk_i;
 reg job_valid_i=0,fp32_i=1;
 reg [15:0] matrices_i=1;
 wire job_ready_o;
 reg [T-1:0] cap_valid_i=0;
 reg [T*256-1:0] cap_data_i=0;
 wire [T-1:0] cap_accept_o;
 reg [3:0] read_issue_valid_i=0;
 reg [127:0] read_issue_i=0;
 wire [T*4-1:0] read_valid_o;
 wire [T*256-1:0] read_data_o;
 wire [31:0] committed_segments_o;
 wire done_o,busy_o,fault_o;
 lpu_sxm_triangle_mem_integration #(.T(T),.DEPTH(8192),.FABRIC_COLUMNS(FABRIC_COLUMNS),.MEM_LEFT(MEM_LEFT)) dut(
 .clk_i,.rst_ni,.job_valid_i,.fp32_i,.matrices_i,.base_i(15'd16),.job_ready_o,
 .cap_valid_i,.cap_data_i,.cap_accept_o,.read_issue_valid_i,.read_issue_i,
 .read_valid_o,.read_data_o,.committed_segments_o,.done_o,.busy_o,.fault_o);
 integer N=1,FP=1,c,t,s,m,a,r,l,b,index_now,readstart,cycles,seen=0,done_count=0,last_commit=-1;
 reg [T*4-1:0] expected;
 reg [31:0] v;
 function automatic [31:0] value(input integer mm,rr,cc);
   if(FP!=0)value=32'h3f000001+32'((mm*(8*T)*(8*T)+rr*(8*T)+cc)*259);
   else value=32'hdead0000 | (32'h4000+32'((mm*(8*T)*(8*T)+rr*(8*T)+cc)*13))&32'hffff;
 endfunction
 initial begin
   if($value$plusargs("N=%d",N))begin end
   if($value$plusargs("FP=%d",FP))begin end
   matrices_i=16'(N);fp32_i=(FP!=0);readstart=(N+1)*8*T+20;cycles=readstart+N*8*T+T+8;
   repeat(2)@(negedge clk_i);rst_ni=1;
   for(c=0;c<cycles;c=c+1)begin
     job_valid_i=(c==0);cap_valid_i=0;cap_data_i=0;read_issue_valid_i=0;read_issue_i=0;expected=0;
     for(s=0;s<T;s=s+1)if(c>=1+s)begin
       t=c-1-s;m=t/(8*T);a=(t%(8*T))/8;r=t%8;
       if(m<N)begin cap_valid_i[s]=1;for(l=0;l<8;l=l+1)cap_data_i[s*256+l*32+:32]=value(m,8*a+r,8*s+l);end
     end
     if(c>=readstart && c<readstart+N*8*T)begin
       for(b=0;b<4;b=b+1)if(FP!=0 || b<2)begin
         read_issue_valid_i[b]=1;read_issue_i[b*32+:32]=(32'(16+c-readstart)<<15)|32'h100|(32'(b)<<3);
       end
     end
     for(s=0;s<T;s=s+1)begin
       index_now=c-readstart-s-2;
       if(index_now>=0 && index_now<N*8*T)for(b=0;b<4;b=b+1)if(FP!=0 || b<2)expected[s*4+b]=1;
     end
     #1;
     if(fault_o)$fatal(1,"T%0d N%0d FP%0d C%0d fault core%0b writer%0b mem%0b bad%0b",T,N,FP,c,dut.core_fault,dut.writer_fault,dut.mem_fault,dut.bad_q);
     if(cap_accept_o!==cap_valid_i)$fatal(1,"capture C%0d",c);
     if(read_valid_o!==expected)$fatal(1,"read valid C%0d actual%h expected%h",c,read_valid_o,expected);
     if(done_o)begin done_count++;last_commit=c;end
     for(s=0;s<T;s=s+1)for(b=0;b<4;b=b+1)if(expected[s*4+b])begin
       index_now=c-readstart-s-2;m=index_now/(8*T);r=index_now%(8*T);
       for(l=0;l<8;l=l+1)begin
         v=value(m,8*s+l,r);
         if(read_data_o[(s*4+b)*64+l*8+:8]!==v[b*8+:8])$fatal(1,"read data C%0d tile%0d row%0d lane%0d byte%0d actual%h expected%h",c,s,r,l,b,read_data_o[(s*4+b)*64+l*8+:8],v[b*8+:8]);
       end
       seen++;
     end
     @(posedge clk_i);#1;@(negedge clk_i);
   end
   if(busy_o || done_count!=1 || committed_segments_o!=32'(N*8*T*T*((FP!=0)?4:2)) || seen!=N*8*T*T*((FP!=0)?4:2))$fatal(1,"count/drain %0d %0d",committed_segments_o,seen);
   $display("PASS MEM T=%0d FP=%0d N=%0d elements=%0d commits=%0d reads=%0d done_observed=%0d",T,FP,N,N*64*T*T,committed_segments_o,seen,last_commit);$finish;
 end
endmodule
